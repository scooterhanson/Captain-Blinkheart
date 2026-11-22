// Captain Blinkheart
// Copyright (C) 2026 Josh Hanson
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import Combine
import Foundation
import SceneBridgeCore
import UniformTypeIdentifiers

struct LogEntry: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let direction: String
    let message: String
}

enum AppTab: Hashable {
    case main, songs, midiCaptain, midiOut, plugin, stagePi
}

/// A song being played back, timed from when Start was pressed.
struct ActivePlayback {
    let song: Song
    /// The playlist entry being played, or nil for a preview from the Songs tab.
    let playlistIndex: Int?
    let startTime: TimeInterval
    var cursor: PlaybackCursor
}

/// A song being recorded from live pedal actions.
struct ActiveRecording {
    let songID: UUID
    var recorder = SongRecorder()
}

@MainActor
final class AppModel: ObservableObject {
    private static let lastConfigurationURLKey = "LastConfigurationFileURL"

    @Published var configuration: AppConfiguration {
        didSet {
            persistConfiguration()
            midi.connectInput(uniqueID: configuration.inputUniqueID)
            midi.selectOutput(uniqueID: configuration.outputUniqueID)
            applyStagePiSettings()
        }
    }
    @Published private(set) var logs: [LogEntry] = []
    @Published private(set) var energy = "Ready"
    @Published var statusMessage: String?
    @Published var isImportingProfile = false
    @Published var selectedTab: AppTab = .main
    @Published var selectedSongID: UUID?
    /// The playlist entry that Start plays.
    @Published private(set) var playlistIndex = 0
    @Published private(set) var playback: ActivePlayback?
    @Published private(set) var recording: ActiveRecording?
    /// The song that most recently played to its last cue.
    @Published private(set) var lastFinishedSongName: String?
    private var playbackTimer: DispatchSourceTimer?
    /// Keeps macOS from throttling timers (App Nap) while timing matters.
    private var timingActivity: NSObjectProtocol?
    private var currentConfigurationURL: URL?
    var hasConfigurationFile: Bool { currentConfigurationURL != nil }

    let midi = MIDIService()
    let plugin = PluginHost()
    let artNet = ArtNetReceiver()
    let dmxPreview = DMXSerialOutput()
    let stageExporter = StageExporter()
    private var appliedPreview: (path: String, type: DMXInterfaceType)?
    private var lastSelectedCue: [SceneAction: String] = [:]
    private var ruleMatcher = MIDIRuleMatcher()

    init() {
        let loaded = Self.loadInitialConfiguration()
        currentConfigurationURL = loaded.url
        configuration = Self.updateLegacyCueNames(in: loaded.configuration)
        statusMessage = loaded.message ?? midi.setupError
        midi.onMIDIMessage = { [weak self] message in
            self?.receiveMIDIMessage(message)
        }
        midi.onTransmission = { [weak self] note, velocity, error in
            guard let self else { return }
            if let error {
                self.appendLog("OUT", "Note Off \(note) failed: \(error)")
                self.statusMessage = error
            } else {
                self.appendLog("OUT", "Note Off \(note) (velocity \(velocity))")
            }
        }
        plugin.onTransmission = { [weak self] note, velocity, error in
            guard let self else { return }
            if let error {
                self.appendLog("OUT", "Plugin Note Off \(note) failed: \(error)")
                self.statusMessage = error
            } else {
                self.appendLog("OUT", "Plugin Note Off \(note) (velocity \(velocity))")
            }
        }
        midi.connectInput(uniqueID: configuration.inputUniqueID)
        midi.selectOutput(uniqueID: configuration.outputUniqueID)
        persistConfiguration()
        if let setupError = midi.setupError { statusMessage = setupError }
        applyPluginConfiguration()
        updateTimingActivity()
        let preview = dmxPreview
        artNet.onFrame = { frame in preview.send(frame) }
        applyStagePiSettings()
        // Runs synchronously on the main thread (queue: nil) before the process
        // exits. The plugin must be torn down here: Show Buddy's JUCE OpenGL
        // context crashes in its static destructor during exit() if its editor
        // view is still attached to our window.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutDownPlugin() }
        }
    }

    // MARK: - Hosted plugin

    var selectedPluginComponent: PluginComponentID {
        configuration.pluginComponent ?? .showBuddyActive
    }

    /// Loads the configured plugin when the output target is the hosted plugin.
    private func applyPluginConfiguration() {
        guard configuration.outputTarget == .hostedPlugin else { return }
        loadPlugin(selectedPluginComponent, restoringState: true)
    }

    func setOutputTarget(_ target: OutputTarget) {
        guard target != configuration.outputTarget else { return }
        if target == .midiPort { storePluginState() }
        configuration.outputTarget = target
        if target == .hostedPlugin, !plugin.isLoaded {
            loadPlugin(selectedPluginComponent, restoringState: true)
        }
    }

    func loadPlugin(_ component: PluginComponentID, restoringState: Bool) {
        if plugin.loadedComponent != nil { storePluginState() }
        let isSameComponent = component == configuration.pluginComponent
            || (configuration.pluginComponent == nil && component == .showBuddyActive)
        let state = restoringState && isSameComponent ? configuration.pluginState : nil
        if !isSameComponent {
            configuration.pluginComponent = component
            configuration.pluginState = nil
        }
        appendLog("APP", "Loading plugin \(component.name)…")
        plugin.load(component, state: state) { [weak self] error in
            guard let self else { return }
            if let error {
                self.statusMessage = error
                self.appendLog("APP", error)
            } else {
                if self.configuration.pluginComponent == nil {
                    self.configuration.pluginComponent = component
                }
                self.appendLog("APP", "Plugin \(component.name) loaded")
            }
        }
    }

    /// Saves the plugin's settings, then detaches its editor and disposes of it
    /// so its own cleanup runs before the process exits.
    private func shutDownPlugin() {
        stageExporter.cancel()
        artNet.stop()
        dmxPreview.close()
        storePluginState()
        plugin.unload()
    }

    func unloadPlugin() {
        storePluginState()
        plugin.unload()
        appendLog("APP", "Plugin unloaded")
    }

    /// Copies the hosted plugin's current settings into the configuration.
    func storePluginState() {
        guard let state = plugin.captureState(), state != configuration.pluginState else { return }
        configuration.pluginState = state
    }

    func refreshDevices() {
        midi.refreshEndpoints()
        midi.connectInput(uniqueID: configuration.inputUniqueID)
    }

    func clearLog() {
        logs.removeAll()
    }

    func revealConfiguration() {
        NSWorkspace.shared.activateFileViewerSelecting([ConfigurationStore.applicationSupportURL])
    }

    func importConfiguration(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            if url.pathExtension.lowercased() == "json" {
                let imported = try ConfigurationStore.decode(data)
                stopTransportForConfigurationChange()
                configuration = Self.updateLegacyCueNames(in: imported)
                rememberConfigurationURL(url)
                reloadPluginAfterConfigurationChange()
                statusMessage = "Configuration loaded from \(url.lastPathComponent)."
            } else {
                let text = try String(contentsOf: url, encoding: .utf8)
                configuration = Self.updateLegacyCueNames(
                    in: try ConfigurationStore.importMIDICaptainProfile(
                        text,
                        into: configuration
                    )
                )
                statusMessage = "MIDI Captain profile imported."
            }
            appendLog("APP", "Imported configuration from \(url.lastPathComponent)")
        } catch {
            statusMessage = "Configuration import failed: \(error.localizedDescription)"
        }
    }

    func loadConfiguration(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let loaded = try ConfigurationStore.decode(data)
            stopTransportForConfigurationChange()
            configuration = Self.updateLegacyCueNames(in: loaded)
            rememberConfigurationURL(url)
            reloadPluginAfterConfigurationChange()
            statusMessage = "Configuration loaded from \(url.lastPathComponent)."
            appendLog("APP", "Loaded configuration from \(url.lastPathComponent)")
        } catch {
            statusMessage = "Could not load configuration: \(error.localizedDescription)"
        }
    }

    func saveConfiguration() {
        guard let currentConfigurationURL else {
            statusMessage = "Choose a file location with Save As before saving."
            return
        }
        saveConfiguration(to: currentConfigurationURL)
    }

    func saveConfiguration(to url: URL) {
        storePluginState()
        do {
            try ConfigurationStore.encode(configuration).write(to: url, options: .atomic)
            rememberConfigurationURL(url)
            statusMessage = "Configuration saved to \(url.lastPathComponent)."
            appendLog("APP", "Saved configuration to \(url.lastPathComponent)")
        } catch {
            statusMessage = "Could not save configuration: \(error.localizedDescription)"
        }
    }

    // MARK: - Settings export/import

    /// Asks for a location and writes the pedal and MIDI settings there.
    func presentExportSettings() {
        let panel = NSSavePanel()
        panel.title = "Export Pedal & MIDI Settings"
        panel.nameFieldStringValue = ConfigurationStore.settingsFileName
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exportSettings(to: url)
    }

    /// Asks for a settings file and applies its pedal and MIDI settings.
    func presentImportSettings() {
        let panel = NSOpenPanel()
        panel.title = "Import Pedal & MIDI Settings"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importSettings(from: url)
    }

    func exportSettings(to url: URL) {
        do {
            try ConfigurationStore.exportSettings(configuration).write(to: url, options: .atomic)
            statusMessage = "Pedal and MIDI settings exported to \(url.lastPathComponent)."
            appendLog("APP", "Exported pedal and MIDI settings to \(url.lastPathComponent)")
        } catch {
            statusMessage = "Could not export settings: \(error.localizedDescription)"
        }
    }

    func importSettings(from url: URL) {
        do {
            storePluginState()
            let data = try Data(contentsOf: url)
            let previousTarget = configuration.outputTarget
            let imported = try ConfigurationStore.importSettings(data, into: configuration)
            stopTransportForConfigurationChange()
            configuration = Self.updateLegacyCueNames(in: imported)
            lastSelectedCue.removeAll()
            ruleMatcher = MIDIRuleMatcher()
            if configuration.outputTarget == .hostedPlugin, !plugin.isLoaded, !plugin.isLoading {
                loadPlugin(selectedPluginComponent, restoringState: true)
            } else if previousTarget == .hostedPlugin, configuration.outputTarget == .midiPort {
                appendLog("APP", "Imported settings send to a MIDI port; the hosted plugin stays loaded")
            }
            statusMessage = "Pedal and MIDI settings imported from \(url.lastPathComponent)."
            appendLog("APP", "Imported pedal and MIDI settings from \(url.lastPathComponent)")
        } catch {
            statusMessage = "Could not import settings: \(error.localizedDescription)"
        }
    }

    private func reloadPluginAfterConfigurationChange() {
        if configuration.outputTarget == .hostedPlugin {
            loadPlugin(selectedPluginComponent, restoringState: true)
        } else if plugin.isLoaded {
            plugin.unload()
        }
    }

    private func persistConfiguration() {
        do {
            try ConfigurationStore.save(configuration)
            if statusMessage?.hasPrefix("Could not read saved configuration") == true {
                statusMessage = "Configuration saved."
            }
        } catch {
            statusMessage = "Could not save configuration: \(error.localizedDescription)"
        }
    }

    private func rememberConfigurationURL(_ url: URL) {
        currentConfigurationURL = url
        UserDefaults.standard.set(url.path, forKey: Self.lastConfigurationURLKey)
    }

    private static func loadInitialConfiguration() -> (
        configuration: AppConfiguration,
        message: String?,
        url: URL?
    ) {
        if let path = UserDefaults.standard.string(forKey: lastConfigurationURLKey) {
            let url = URL(fileURLWithPath: path)
            do {
                let data = try Data(contentsOf: url)
                return (try ConfigurationStore.decode(data), nil, url)
            } catch {
                let savedState = ConfigurationStore.load()
                let fallbackMessage = savedState.message.map { " \($0)" } ?? ""
                return (
                    savedState.configuration,
                    "Could not load the last configuration file; restored the last saved state. \(error.localizedDescription)\(fallbackMessage)",
                    url
                )
            }
        }

        let savedState = ConfigurationStore.load()
        return (savedState.configuration, savedState.message, nil)
    }

    private func receiveMIDIMessage(_ message: MIDIInputMessage) {
        appendLog("IN", message.summary)
        guard let rule = ruleMatcher.receive(
            message,
            rules: configuration.rules,
            at: ProcessInfo.processInfo.systemUptime
        ) else { return }
        switch configuration.performanceMode {
        case .live:
            appendLog("APP", "\(rule.label): \(rule.action.title)")
            fire(rule.action)
        case .playback:
            appendLog("APP", "\(rule.label): \(rule.playbackAction.title)")
            perform(rule.playbackAction, liveAction: rule.action)
        }
    }

    /// Fires a live lighting action and records it if a recording is running.
    private func fire(_ action: SceneAction) {
        if recording != nil {
            let wasStarted = recording?.recorder.hasStarted == true
            recording?.recorder.record(action, at: Self.now())
            if !wasStarted { appendLog("REC", "Recording started on \(action.energy)") }
        }
        trigger(action)
    }

    private func trigger(_ action: SceneAction) {
        energy = action.energy
        let cue = SceneSelector.select(
            from: configuration.cues(for: action),
            avoiding: lastSelectedCue[action]
        )

        guard let cue else {
            statusMessage = "No MIDI notes are configured for \(action.title)."
            appendLog("APP", statusMessage ?? "Scene selection failed.")
            return
        }
        lastSelectedCue[action] = cue.id
        if let error = sendCue(cue) {
            statusMessage = error
        } else {
            statusMessage = nil
        }
    }

    /// Sends one cue's note to the current output and logs it. Returns an error message on failure.
    @discardableResult
    func sendCue(_ cue: MIDICue) -> String? {
        let destination: String
        let error: String?
        switch configuration.outputTarget {
        case .midiPort:
            destination = ""
            error = midi.sendNoteOn(
                note: cue.note,
                velocity: cue.velocity,
                channel: configuration.outputChannel
            )
        case .hostedPlugin:
            destination = "Plugin "
            error = plugin.sendNoteOn(
                note: cue.note,
                velocity: cue.velocity,
                channel: configuration.outputChannel
            )
        }
        if let error {
            appendLog("OUT", "\(destination)Note On \(cue.note) failed: \(error)")
        } else {
            appendLog(
                "OUT",
                "\(destination)Note On \(cue.note) / velocity \(cue.velocity) / channel \(configuration.outputChannel) — \(cue.name)"
            )
        }
        return error
    }

    // MARK: - Stage Pi

    /// Starts or stops the Art-Net receiver and light preview to match the settings.
    private func applyStagePiSettings() {
        let settings = configuration.stagePi
        if settings.artNetEnabled {
            artNet.start(universe: settings.artNetUniverse)
            artNet.setUniverse(settings.artNetUniverse)
        } else if artNet.status.isListening {
            artNet.stop()
        }

        let wanted = settings.previewDevicePath.map { ($0, settings.previewDeviceType) }
        if let wanted, settings.artNetEnabled {
            if appliedPreview?.path != wanted.0 || appliedPreview?.type != wanted.1 || dmxPreview.devicePath == nil {
                guard FileManager.default.fileExists(atPath: wanted.0) else {
                    if appliedPreview != nil { dmxPreview.close(); appliedPreview = nil }
                    return
                }
                dmxPreview.open(path: wanted.0, type: wanted.1)
                appliedPreview = (wanted.0, wanted.1)
                if let error = dmxPreview.error { appendLog("APP", error) }
            }
        } else if appliedPreview != nil {
            dmxPreview.close()
            appliedPreview = nil
        }
    }

    /// Re-opens the preview device, e.g. after it was plugged back in.
    func reconnectPreview() {
        appliedPreview = nil
        dmxPreview.close()
        applyStagePiSettings()
    }

    /// Asks for a destination (usually a USB stick) and exports the show there.
    func presentStageExport() {
        let panel = NSOpenPanel()
        panel.title = "Export to Pi"
        panel.message = "Choose the USB stick (or folder). Captain Blinkheart writes a \"\(StageShowManifest.folderName)\" folder there."
        panel.prompt = "Export Here"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if FileManager.default.fileExists(atPath: "/Volumes") {
            panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let existing = url.appendingPathComponent(StageShowManifest.folderName)
        if FileManager.default.fileExists(atPath: existing.path) {
            let alert = NSAlert()
            alert.messageText = "Replace the show on \(url.lastPathComponent)?"
            alert.informativeText = "The existing \"\(StageShowManifest.folderName)\" folder is replaced once the new export finishes."
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        exportStage(to: url)
    }

    /// Rewrites only the show settings on a stick that already has an export.
    func presentStageSettingsUpdate() {
        let panel = NSOpenPanel()
        panel.title = "Update Settings on the Stick"
        panel.message = "Choose the USB stick (or folder) that holds the exported \"\(StageShowManifest.folderName)\" folder."
        panel.prompt = "Update"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if FileManager.default.fileExists(atPath: "/Volumes") {
            panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        }
        guard panel.runModal() == .OK, var url = panel.url else { return }
        // Accept the blinkheart folder itself as well as the folder holding it.
        if url.lastPathComponent == StageShowManifest.folderName { url.deleteLastPathComponent() }
        do {
            let message = try StageExportPlan.updateSettings(
                configuration: configuration,
                showName: stageShowName,
                destination: url
            )
            stageExporter.lastResult = message
            appendLog("APP", message)
        } catch {
            stageExporter.lastResult = "Update failed: \(error.localizedDescription)"
        }
    }

    private var stageShowName: String {
        currentConfigurationURL?.deletingPathExtension().lastPathComponent ?? "Captain Blinkheart"
    }

    func exportStage(to url: URL) {
        if configuration.performanceMode == .playback { setPerformanceMode(.live) }
        if playback != nil { stopPlayback(log: "Playback stopped (stage export)") }
        if recording != nil { cancelRecording() }
        stageExporter.export(
            configuration: configuration,
            showName: stageShowName,
            to: url,
            artNet: artNet,
            sendCue: { [weak self] cue in
                // sendCue returns nil on success, so don't fold it into `?? error`.
                guard let self else { return "The app is closing." }
                return self.sendCue(cue)
            },
            log: { [weak self] message in self?.appendLog("APP", message) }
        )
    }

    // MARK: - Performance mode

    func setPerformanceMode(_ mode: PerformanceMode) {
        guard mode != configuration.performanceMode else { return }
        if mode == .playback, recording != nil { stopRecording() }
        if mode == .live, playback != nil { stopPlayback(log: "Playback stopped (live mode)") }
        configuration.performanceMode = mode
        appendLog("APP", "\(mode.title) mode")
        updateTimingActivity()
    }

    /// Runs a playback-mode pedal command.
    func perform(_ transport: TransportAction, liveAction: SceneAction? = nil) {
        switch transport {
        case .reset:
            if playback != nil { stopPlayback(log: "Playback stopped (reset)") }
            trigger(.reset)
        case .start:
            startCurrentSong()
        case .stop:
            if playback != nil { stopPlayback(log: "Playback stopped") }
        case .previous:
            movePlaylist(by: -1)
        case .next:
            movePlaylist(by: 1)
        case .liveCue:
            if let liveAction { trigger(liveAction) }
        case .none:
            break
        }
    }

    // MARK: - Playlist

    /// The playlist resolved to songs, in order.
    var playlistSongs: [Song] { configuration.playlistSongs }

    var currentSong: Song? {
        let songs = playlistSongs
        return songs.indices.contains(playlistIndex) ? songs[playlistIndex] : nil
    }

    var nextSong: Song? {
        let songs = playlistSongs
        guard let next = PlaylistNavigator.next(after: playlistIndex, count: songs.count) else { return nil }
        return songs[next]
    }

    func selectPlaylistEntry(_ index: Int) {
        guard playlistSongs.indices.contains(index) else { return }
        if playback?.playlistIndex != nil { stopPlayback(log: "Playback stopped") }
        playlistIndex = index
    }

    private func movePlaylist(by offset: Int) {
        let count = playlistSongs.count
        guard count > 0 else {
            statusMessage = "The playlist is empty. Add songs to it in the Songs tab."
            return
        }
        let target = offset > 0
            ? PlaylistNavigator.next(after: playlistIndex, count: count)
            : PlaylistNavigator.previous(before: playlistIndex)
        guard let target else {
            appendLog("APP", offset > 0 ? "Already at the last song" : "Already at the first song")
            return
        }
        if playback != nil { stopPlayback(log: "Playback stopped") }
        playlistIndex = target
        lastFinishedSongName = nil
        appendLog("APP", "Song \(target + 1): \(playlistSongs[target].name)")
    }

    func addToPlaylist(_ songID: UUID) {
        configuration.playlist.append(songID)
    }

    func removePlaylistEntry(at index: Int) {
        guard configuration.playlist.indices.contains(index) else { return }
        if playback?.playlistIndex != nil { stopPlayback(log: "Playback stopped") }
        configuration.playlist.remove(at: index)
        if index < playlistIndex { playlistIndex -= 1 }
        clampPlaylistIndex()
    }

    func movePlaylistEntry(at index: Int, by offset: Int) {
        let target = index + offset
        guard configuration.playlist.indices.contains(index),
              configuration.playlist.indices.contains(target) else { return }
        if playback?.playlistIndex != nil { stopPlayback(log: "Playback stopped") }
        configuration.playlist.swapAt(index, target)
        if playlistIndex == index {
            playlistIndex = target
        } else if playlistIndex == target {
            playlistIndex = index
        }
    }

    private func clampPlaylistIndex() {
        playlistIndex = PlaylistNavigator.clamp(playlistIndex, count: playlistSongs.count)
    }

    // MARK: - Songs

    func addSong() {
        let song = Song(name: "Song \(configuration.songs.count + 1)")
        configuration.songs.append(song)
        selectedSongID = song.id
    }

    func deleteSong(_ id: UUID) {
        if playback?.song.id == id { stopPlayback(log: "Playback stopped (song deleted)") }
        if recording?.songID == id { cancelRecording() }
        let current = currentSong?.id
        configuration.songs.removeAll { $0.id == id }
        configuration.playlist.removeAll { $0 == id }
        if let current, let index = playlistSongs.firstIndex(where: { $0.id == current }) {
            playlistIndex = index
        }
        clampPlaylistIndex()
        if selectedSongID == id { selectedSongID = configuration.songs.first?.id }
    }

    // MARK: - Recording

    /// Arms recording for a song. The first pedal action becomes time zero.
    func startRecording(songID: UUID) {
        guard configuration.song(withID: songID) != nil else { return }
        if playback != nil { stopPlayback(log: "Playback stopped (recording)") }
        if configuration.performanceMode == .playback { setPerformanceMode(.live) }
        recording = ActiveRecording(songID: songID)
        lastFinishedSongName = nil
        appendLog("REC", "Armed \(configuration.song(withID: songID)?.name ?? "song"): waiting for the first cue")
        updateTimingActivity()
    }

    /// Saves the recorded actions into the song, replacing its previous events.
    func stopRecording() {
        guard let active = recording else { return }
        recording = nil
        updateTimingActivity()
        guard let index = configuration.songs.firstIndex(where: { $0.id == active.songID }) else { return }
        let name = configuration.songs[index].name
        guard !active.recorder.events.isEmpty else {
            statusMessage = "Nothing was recorded, so \(name) was left unchanged."
            appendLog("REC", "Recording cancelled: no cues")
            return
        }
        configuration.songs[index].events = active.recorder.events
        let count = active.recorder.events.count
        appendLog("REC", "Saved \(name): \(count) cue\(count == 1 ? "" : "s"), \(SongTimeFormatter.string(configuration.songs[index].duration))")
    }

    func cancelRecording() {
        guard recording != nil else { return }
        recording = nil
        updateTimingActivity()
        appendLog("REC", "Recording discarded")
    }

    // MARK: - Playback

    func startCurrentSong() {
        if playback != nil {
            appendLog("APP", "Already playing \(playback?.song.name ?? "a song")")
            return
        }
        guard let song = currentSong else {
            statusMessage = "The playlist is empty. Add songs to it in the Songs tab."
            return
        }
        play(song, playlistIndex: playlistIndex)
    }

    /// Plays a song. Its first cue fires immediately and the rest follow on
    /// their recorded times.
    func play(_ song: Song, playlistIndex: Int? = nil) {
        if recording != nil {
            statusMessage = "Stop recording before playing a song."
            return
        }
        if playback != nil { stopPlayback(log: nil) }
        guard !song.events.isEmpty else {
            statusMessage = "\(song.name) has no recorded cues."
            appendLog("APP", statusMessage ?? "")
            return
        }
        lastFinishedSongName = nil
        playback = ActivePlayback(
            song: song,
            playlistIndex: playlistIndex,
            startTime: Self.now(),
            cursor: PlaybackCursor(song: song)
        )
        appendLog("PLAY", "Started \(song.name) (\(SongTimeFormatter.string(song.duration)))")
        updateTimingActivity()
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.playbackTick() }
        }
        playbackTimer = timer
        timer.resume()
        playbackTick()
    }

    func stopPlayback(log message: String? = "Playback stopped") {
        guard playback != nil else { return }
        playbackTimer?.cancel()
        playbackTimer = nil
        playback = nil
        if let message { appendLog("PLAY", message) }
        updateTimingActivity()
    }

    /// Seconds since the playing song started.
    func playbackElapsed(at time: TimeInterval = AppModel.now()) -> TimeInterval? {
        playback.map { max(0, time - $0.startTime) }
    }

    func recordingElapsed(at time: TimeInterval = AppModel.now()) -> TimeInterval? {
        recording?.recorder.elapsed(at: time)
    }

    /// Fires every cue that is due, then schedules the timer for the next one.
    /// Cue times are measured from the fixed start time, so late wake-ups never
    /// accumulate into drift.
    private func playbackTick() {
        guard var active = playback else { return }
        let elapsed = Self.now() - active.startTime
        let due = active.cursor.due(at: elapsed)
        playback = active
        for event in due {
            let lateness = max(0, elapsed - event.time)
            appendLog("PLAY", "\(SongTimeFormatter.string(event.time)) \(event.action.energy)\(lateness > 0.02 ? String(format: " (+%.0f ms)", lateness * 1000) : "")")
            trigger(event.action)
        }
        guard let nextTime = active.cursor.nextEventTime else {
            finishPlayback(active)
            return
        }
        let delay = max(0, nextTime - (Self.now() - active.startTime))
        playbackTimer?.schedule(
            deadline: .now() + .nanoseconds(Int(delay * 1_000_000_000)),
            leeway: .milliseconds(1)
        )
    }

    /// After the last cue, moves to the next playlist song so Start plays it.
    private func finishPlayback(_ active: ActivePlayback) {
        playbackTimer?.cancel()
        playbackTimer = nil
        playback = nil
        lastFinishedSongName = active.song.name
        appendLog("PLAY", "Finished \(active.song.name)")
        if let index = active.playlistIndex,
           let next = PlaylistNavigator.next(after: index, count: playlistSongs.count) {
            playlistIndex = next
            appendLog("APP", "Next up: \(playlistSongs[next].name)")
        }
        updateTimingActivity()
    }

    private func stopTransportForConfigurationChange() {
        stopPlayback(log: nil)
        cancelRecording()
        playlistIndex = 0
        lastFinishedSongName = nil
    }

    /// Opts out of App Nap and timer coalescing while playback mode is on or a
    /// song is recording or playing, so cues stay on time with the window in
    /// the background.
    private func updateTimingActivity() {
        let needed = configuration.performanceMode == .playback || playback != nil || recording != nil
        if needed, timingActivity == nil {
            timingActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
                reason: "Timing lighting cues for a live performance"
            )
        } else if !needed, let activity = timingActivity {
            ProcessInfo.processInfo.endActivity(activity)
            timingActivity = nil
        }
    }

    /// A monotonic clock in seconds, shared by recording and playback.
    nonisolated static func now() -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    private static func updateLegacyCueNames(
        in configuration: AppConfiguration
    ) -> AppConfiguration {
        var updated = configuration
        if var introCues = updated.scenes[SceneAction.baseline.rawValue] {
            for index in introCues.indices where introCues[index].name == "Baseline" {
                introCues[index].name = "Intro"
            }
            updated.scenes[SceneAction.baseline.rawValue] = introCues
        }
        if var frenzyCues = updated.scenes["critical"] {
            for index in frenzyCues.indices {
                if frenzyCues[index].name == "Critical \(index + 1)" {
                    frenzyCues[index].name = "Frenzy \(index + 1)"
                }
            }
            updated.scenes["critical"] = frenzyCues
        }
        return updated
    }

    private func appendLog(_ direction: String, _ message: String) {
        logs.append(LogEntry(direction: direction, message: message))
        if logs.count > 300 { logs.removeFirst(logs.count - 300) }
    }
}
