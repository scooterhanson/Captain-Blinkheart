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
    case main, midiCaptain, midiOut, plugin
}

@MainActor
final class AppModel: ObservableObject {
    private static let lastConfigurationURLKey = "LastConfigurationFileURL"

    @Published var configuration: AppConfiguration {
        didSet {
            persistConfiguration()
            midi.connectInput(uniqueID: configuration.inputUniqueID)
            midi.selectOutput(uniqueID: configuration.outputUniqueID)
        }
    }
    @Published private(set) var logs: [LogEntry] = []
    @Published private(set) var energy = "Ready"
    @Published var statusMessage: String?
    @Published var isImportingProfile = false
    @Published var selectedTab: AppTab = .main
    private var currentConfigurationURL: URL?
    var hasConfigurationFile: Bool { currentConfigurationURL != nil }

    let midi = MIDIService()
    let plugin = PluginHost()
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
            configuration = Self.updateLegacyCueNames(in: try ConfigurationStore.decode(data))
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
            configuration = Self.updateLegacyCueNames(
                in: try ConfigurationStore.importSettings(data, into: configuration)
            )
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
        appendLog("APP", "\(rule.label): \(rule.action.title)")
        trigger(rule.action)
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
            statusMessage = error
            appendLog("OUT", "\(destination)Note On \(cue.note) failed: \(error)")
        } else {
            statusMessage = nil
            appendLog(
                "OUT",
                "\(destination)Note On \(cue.note) / velocity \(cue.velocity) / channel \(configuration.outputChannel) — \(cue.name)"
            )
        }
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
