// Captain Blinkheart
// Copyright (C) 2026 Josh Hanson
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

public enum SceneAction: String, CaseIterable, Codable, Identifiable {
    case reset
    case low
    case medium
    case high
    case critical
    case baseline

    public var id: String { rawValue }

    /// The order actions appear in on the MIDI Out tab and the pedal.
    public static let displayOrder: [SceneAction] = [.reset, .baseline, .low, .medium, .high, .critical]

    public var title: String {
        switch self {
        case .reset: "Reset"
        case .low: "Random Low"
        case .medium: "Random Medium"
        case .high: "Random High"
        case .critical: "Random Frenzy"
        case .baseline: "Intro"
        }
    }

    public var energy: String {
        switch self {
        case .reset: "Reset"
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        case .critical: "Frenzy"
        case .baseline: "Intro"
        }
    }
}

public enum MIDIInputKind: String, Codable, CaseIterable, Identifiable {
    case noteOn
    case noteOff
    case controlChange

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .noteOn: "Note On"
        case .noteOff: "Note Off"
        case .controlChange: "CC"
        }
    }
}

public struct MIDIInputMessage: Codable, Equatable, Identifiable {
    public var kind: MIDIInputKind
    public var channel: Int
    public var number: Int
    public var value: Int
    public var id: String { "\(kind.rawValue)-\(channel)-\(number)-\(value)" }

    public init(kind: MIDIInputKind, channel: Int, number: Int, value: Int) {
        self.kind = kind
        self.channel = channel
        self.number = number
        self.value = value
    }

    public var summary: String {
        switch kind {
        case .noteOn: "Note \(number) on ch \(channel), vel \(value)"
        case .noteOff: "Note \(number) off ch \(channel), vel \(value)"
        case .controlChange: "CC \(number) = \(value) on ch \(channel)"
        }
    }
}

public struct PedalRule: Codable, Equatable, Identifiable {
    public var button: Int
    public var label: String
    public var messages: [MIDIInputMessage]
    public var action: SceneAction
    /// What the key does in playback mode.
    public var playbackAction: TransportAction
    public var id: Int { button }

    public init(
        button: Int,
        label: String,
        messages: [MIDIInputMessage],
        action: SceneAction,
        playbackAction: TransportAction? = nil
    ) {
        self.button = button
        self.label = label
        self.messages = messages
        self.action = action
        self.playbackAction = playbackAction ?? TransportAction.defaultAction(for: action)
    }

    private enum CodingKeys: String, CodingKey {
        case button, label, messages, action, playbackAction, ccNumber, triggerValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        button = try container.decode(Int.self, forKey: .button)
        action = try container.decode(SceneAction.self, forKey: .action)
        playbackAction = try container.decodeIfPresent(TransportAction.self, forKey: .playbackAction)
            ?? TransportAction.defaultAction(for: action)
        if let configuredMessages = try container.decodeIfPresent([MIDIInputMessage].self, forKey: .messages) {
            messages = configuredMessages
            label = try container.decodeIfPresent(String.self, forKey: .label) ?? "Button \(button)"
        } else {
            let ccNumber = try container.decode(Int.self, forKey: .ccNumber)
            let triggerValue = try container.decodeIfPresent(Int.self, forKey: .triggerValue) ?? 127
            messages = [
                MIDIInputMessage(kind: .controlChange, channel: 1, number: ccNumber, value: triggerValue)
            ]
            label = "Button \(button)"
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(button, forKey: .button)
        try container.encode(label, forKey: .label)
        try container.encode(messages, forKey: .messages)
        try container.encode(action, forKey: .action)
        try container.encode(playbackAction, forKey: .playbackAction)
    }
}

public enum MIDICaptainProfileParser {
    public enum ParseError: LocalizedError {
        case noButtonsFound
        case missingPressMessages(Int)
        case invalidMessage(String)

        public var errorDescription: String? {
            switch self {
            case .noButtonsFound:
                "No MIDI Captain key sections with short_dw1 messages were found."
            case .missingPressMessages(let button):
                "MIDI Captain key\(button) does not contain any short_dw1 messages."
            case .invalidMessage(let text):
                "Invalid MIDI message in the MIDI Captain profile: \(text)"
            }
        }
    }

    public static func parse(_ text: String) throws -> [PedalRule] {
        let actions: [Int: SceneAction] = [
            0: .reset,
            1: .baseline,
            2: .low,
            3: .medium,
            4: .high,
            5: .critical
        ]
        var currentButton: Int?
        var rulesByButton: [Int: PedalRule] = [:]
        let messagePattern = #"\[(\d+)\]\[(NT|CC)\]\[(\d+)\]\[(\d+)\]"#

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[key"), line.hasSuffix("]"),
               let button = Int(line.dropFirst(4).dropLast()) {
                currentButton = button
                continue
            }
            guard let button = currentButton,
                  line.lowercased().hasPrefix("short_dw1"),
                  let action = actions[button]
            else { continue }

            let lineRange = NSRange(line.startIndex..<line.endIndex, in: line)
            let regex = try NSRegularExpression(pattern: messagePattern)
            let matches = regex.matches(in: line, range: lineRange)
            guard !matches.isEmpty else { throw ParseError.missingPressMessages(button) }

            var messages: [MIDIInputMessage] = []
            for match in matches {
                guard let channelRange = Range(match.range(at: 1), in: line),
                      let kindRange = Range(match.range(at: 2), in: line),
                      let numberRange = Range(match.range(at: 3), in: line),
                      let valueRange = Range(match.range(at: 4), in: line),
                      let channel = Int(line[channelRange]),
                      let number = Int(line[numberRange]),
                      let value = Int(line[valueRange])
                else {
                    throw ParseError.invalidMessage(line)
                }
                guard (1...16).contains(channel),
                      (0...127).contains(number),
                      (0...127).contains(value)
                else {
                    throw ParseError.invalidMessage(line)
                }

                let kind: MIDIInputKind
                switch line[kindRange] {
                case "NT":
                    kind = value == 0 ? .noteOff : .noteOn
                case "CC":
                    kind = .controlChange
                default:
                    throw ParseError.invalidMessage(line)
                }
                messages.append(
                    MIDIInputMessage(kind: kind, channel: channel, number: number, value: value)
                )
            }

            rulesByButton[button] = PedalRule(
                button: button,
                label: "Key \(button)",
                messages: messages,
                action: action
            )
        }

        guard !rulesByButton.isEmpty else { throw ParseError.noButtonsFound }
        return rulesByButton.values.sorted { $0.button < $1.button }
    }
}

public struct MIDIRuleMatcher {
    private let sequenceTimeout: TimeInterval
    private var progress: [Int: Int] = [:]
    private var lastMatchTime: [Int: TimeInterval] = [:]

    public init(sequenceTimeout: TimeInterval = 1.5) {
        self.sequenceTimeout = sequenceTimeout
    }

    public mutating func receive(
        _ message: MIDIInputMessage,
        rules: [PedalRule],
        at time: TimeInterval
    ) -> PedalRule? {
        for rule in rules where !rule.messages.isEmpty {
            var nextIndex = progress[rule.button, default: 0]
            if let lastTime = lastMatchTime[rule.button], time - lastTime > sequenceTimeout {
                nextIndex = 0
            }
            if !rule.messages.indices.contains(nextIndex) { nextIndex = 0 }

            if rule.messages[nextIndex] == message {
                nextIndex += 1
                if nextIndex == rule.messages.count {
                    progress[rule.button] = 0
                    lastMatchTime[rule.button] = time
                    return rule
                }
                progress[rule.button] = nextIndex
                lastMatchTime[rule.button] = time
            } else if let firstMessage = rule.messages.first, firstMessage == message {
                progress[rule.button] = 1
                lastMatchTime[rule.button] = time
                if rule.messages.count == 1 { return rule }
            } else {
                progress[rule.button] = 0
            }
        }
        return nil
    }
}

public struct MIDICue: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var note: Int
    public var velocity: Int

    public init(id: String, name: String, note: Int, velocity: Int) {
        self.id = id
        self.name = name
        self.note = note
        self.velocity = velocity
    }
}

/// Where triggered cues are delivered.
public enum OutputTarget: String, Codable, CaseIterable, Identifiable {
    /// A CoreMIDI destination such as an IAC bus that ShowBuddy listens to.
    case midiPort
    /// A ShowBuddy Active Audio Unit hosted inside this application.
    case hostedPlugin

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .midiPort: "MIDI Port"
        case .hostedPlugin: "Hosted Plugin"
        }
    }
}

/// Identifies an Audio Unit by its four-character type, subtype, and manufacturer codes.
public struct PluginComponentID: Codable, Equatable, Hashable, Sendable {
    public var type: String
    public var subtype: String
    public var manufacturer: String
    public var name: String

    public init(type: String, subtype: String, manufacturer: String, name: String) {
        self.type = type
        self.subtype = subtype
        self.manufacturer = manufacturer
        self.name = name
    }

    /// Show Buddy Active's music-effect Audio Unit (`aumf DmpP dBau`).
    public static let showBuddyActive = PluginComponentID(
        type: "aumf",
        subtype: "DmpP",
        manufacturer: "dBau",
        name: "db audioware: Show Buddy Active"
    )

    public var typeCode: UInt32 { FourCharCode.value(type) }
    public var subtypeCode: UInt32 { FourCharCode.value(subtype) }
    public var manufacturerCode: UInt32 { FourCharCode.value(manufacturer) }

    public func matches(type: UInt32, subtype: UInt32, manufacturer: UInt32) -> Bool {
        typeCode == type && subtypeCode == subtype && manufacturerCode == manufacturer
    }
}

public enum FourCharCode {
    public static func value(_ string: String) -> UInt32 {
        let bytes = Array(string.utf8.prefix(4)) + Array(repeating: UInt8(ascii: " "), count: max(0, 4 - string.utf8.count))
        return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    public static func string(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

public struct AppConfiguration: Codable, Equatable {
    public var inputChannel: Int
    public var outputChannel: Int
    public var inputUniqueID: Int32?
    public var outputUniqueID: Int32?
    public var outputTarget: OutputTarget
    public var pluginComponent: PluginComponentID?
    /// The hosted plugin's saved state (a property list from `AUAudioUnit.fullState`).
    public var pluginState: Data?
    public var rules: [PedalRule]
    /// Output cues for every action, keyed by `SceneAction.rawValue`. A cue is
    /// chosen at random from the action's list each time the action fires.
    public var scenes: [String: [MIDICue]]
    /// Recorded songs, stored in the configuration so no separate files are needed.
    public var songs: [Song]
    /// Song IDs in performance order. A song may appear more than once.
    public var playlist: [UUID]
    public var performanceMode: PerformanceMode
    /// Art-Net capture, light preview, and fades for the stage Pi export.
    public var stagePi: StagePiSettings

    public init(
        inputChannel: Int,
        outputChannel: Int,
        inputUniqueID: Int32?,
        outputUniqueID: Int32?,
        outputTarget: OutputTarget = .midiPort,
        pluginComponent: PluginComponentID? = nil,
        pluginState: Data? = nil,
        rules: [PedalRule],
        scenes: [String: [MIDICue]],
        songs: [Song] = [],
        playlist: [UUID] = [],
        performanceMode: PerformanceMode = .live,
        stagePi: StagePiSettings = StagePiSettings()
    ) {
        self.inputChannel = inputChannel
        self.outputChannel = outputChannel
        self.inputUniqueID = inputUniqueID
        self.outputUniqueID = outputUniqueID
        self.outputTarget = outputTarget
        self.pluginComponent = pluginComponent
        self.pluginState = pluginState
        self.rules = rules
        self.scenes = scenes
        self.songs = songs
        self.playlist = playlist
        self.performanceMode = performanceMode
        self.stagePi = stagePi
    }

    public func song(withID id: UUID) -> Song? {
        songs.first { $0.id == id }
    }

    /// Playlist entries resolved to songs, skipping any that were deleted.
    public var playlistSongs: [Song] {
        playlist.compactMap { song(withID: $0) }
    }

    public func cues(for action: SceneAction) -> [MIDICue] {
        scenes[action.rawValue] ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case inputChannel, outputChannel, inputUniqueID, outputUniqueID
        case outputTarget, pluginComponent, pluginState, rules, scenes
        case songs, playlist, performanceMode, stagePi
        // Legacy single-cue keys from configurations saved before Reset and
        // Intro supported random lists.
        case resetCue, baselineCue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputChannel = try container.decode(Int.self, forKey: .inputChannel)
        outputChannel = try container.decode(Int.self, forKey: .outputChannel)
        inputUniqueID = try container.decodeIfPresent(Int32.self, forKey: .inputUniqueID)
        outputUniqueID = try container.decodeIfPresent(Int32.self, forKey: .outputUniqueID)
        outputTarget = try container.decodeIfPresent(OutputTarget.self, forKey: .outputTarget) ?? .midiPort
        pluginComponent = try container.decodeIfPresent(PluginComponentID.self, forKey: .pluginComponent)
        pluginState = try container.decodeIfPresent(Data.self, forKey: .pluginState)
        rules = try container.decode([PedalRule].self, forKey: .rules)
        scenes = try container.decodeIfPresent([String: [MIDICue]].self, forKey: .scenes) ?? [:]
        songs = try container.decodeIfPresent([Song].self, forKey: .songs) ?? []
        playlist = try container.decodeIfPresent([UUID].self, forKey: .playlist) ?? []
        performanceMode = try container.decodeIfPresent(PerformanceMode.self, forKey: .performanceMode) ?? .live
        stagePi = try container.decodeIfPresent(StagePiSettings.self, forKey: .stagePi) ?? StagePiSettings()

        if scenes[SceneAction.reset.rawValue] == nil,
           let legacyReset = try container.decodeIfPresent(MIDICue.self, forKey: .resetCue) {
            scenes[SceneAction.reset.rawValue] = [legacyReset]
        }
        if scenes[SceneAction.baseline.rawValue] == nil,
           let legacyIntro = try container.decodeIfPresent(MIDICue.self, forKey: .baselineCue) {
            scenes[SceneAction.baseline.rawValue] = [legacyIntro]
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(inputChannel, forKey: .inputChannel)
        try container.encode(outputChannel, forKey: .outputChannel)
        try container.encodeIfPresent(inputUniqueID, forKey: .inputUniqueID)
        try container.encodeIfPresent(outputUniqueID, forKey: .outputUniqueID)
        try container.encode(outputTarget, forKey: .outputTarget)
        try container.encodeIfPresent(pluginComponent, forKey: .pluginComponent)
        try container.encodeIfPresent(pluginState, forKey: .pluginState)
        try container.encode(rules, forKey: .rules)
        try container.encode(scenes, forKey: .scenes)
        try container.encode(songs, forKey: .songs)
        try container.encode(playlist, forKey: .playlist)
        try container.encode(performanceMode, forKey: .performanceMode)
        try container.encode(stagePi, forKey: .stagePi)
    }

    public static let `default` = AppConfiguration(
        inputChannel: 1,
        outputChannel: 1,
        inputUniqueID: nil,
        outputUniqueID: nil,
        rules: [
            PedalRule(button: 0, label: "Key 0", messages: [
                MIDIInputMessage(kind: .noteOn, channel: 16, number: 0, value: 127),
                MIDIInputMessage(kind: .controlChange, channel: 15, number: 35, value: 127),
                MIDIInputMessage(kind: .controlChange, channel: 15, number: 30, value: 3)
            ], action: .reset),
            PedalRule(button: 1, label: "Key 1", messages: [
                MIDIInputMessage(kind: .noteOn, channel: 16, number: 23, value: 127)
            ], action: .baseline),
            PedalRule(button: 2, label: "Key 2", messages: [
                MIDIInputMessage(kind: .noteOn, channel: 16, number: 19, value: 127)
            ], action: .low),
            PedalRule(button: 3, label: "Key 3", messages: [
                MIDIInputMessage(kind: .controlChange, channel: 2, number: 18, value: 127),
                MIDIInputMessage(kind: .controlChange, channel: 2, number: 20, value: 127)
            ], action: .medium),
            PedalRule(button: 4, label: "Key 4", messages: [
                MIDIInputMessage(kind: .controlChange, channel: 2, number: 18, value: 0),
                MIDIInputMessage(kind: .controlChange, channel: 2, number: 20, value: 127)
            ], action: .high),
            PedalRule(button: 5, label: "Key 5", messages: [
                MIDIInputMessage(kind: .controlChange, channel: 2, number: 18, value: 127),
                MIDIInputMessage(kind: .controlChange, channel: 2, number: 20, value: 0)
            ], action: .critical)
        ],
        scenes: [
            "reset": [
                MIDICue(id: "reset", name: "Reset / All Off", note: 36, velocity: 127)
            ],
            "baseline": [
                MIDICue(id: "baseline", name: "Intro", note: 37, velocity: 100)
            ],
            "low": [
                MIDICue(id: "low-1", name: "Low 1", note: 48, velocity: 100),
                MIDICue(id: "low-2", name: "Low 2", note: 50, velocity: 100),
                MIDICue(id: "low-3", name: "Low 3", note: 52, velocity: 100)
            ],
            "medium": [
                MIDICue(id: "medium-1", name: "Medium 1", note: 53, velocity: 100),
                MIDICue(id: "medium-2", name: "Medium 2", note: 55, velocity: 100),
                MIDICue(id: "medium-3", name: "Medium 3", note: 57, velocity: 100)
            ],
            "high": [
                MIDICue(id: "high-1", name: "High 1", note: 58, velocity: 110),
                MIDICue(id: "high-2", name: "High 2", note: 60, velocity: 110),
                MIDICue(id: "high-3", name: "High 3", note: 62, velocity: 110)
            ],
            "critical": [
                MIDICue(id: "critical-1", name: "Frenzy 1", note: 63, velocity: 120),
                MIDICue(id: "critical-2", name: "Frenzy 2", note: 65, velocity: 120),
                MIDICue(id: "critical-3", name: "Frenzy 3", note: 67, velocity: 120)
            ]
        ]
    )
}

public enum ConfigurationStore {
    public static let fileName = "MIDI-Captain-6-Button.json"

    public static var applicationSupportURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SceneBridge", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    public static func encode(_ configuration: AppConfiguration) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(configuration)
    }

    public static func decode(_ data: Data) throws -> AppConfiguration {
        try JSONDecoder().decode(AppConfiguration.self, from: data)
    }

    public static func load() -> (configuration: AppConfiguration, message: String?) {
        let url = applicationSupportURL
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                return (try decode(Data(contentsOf: url)), nil)
            } catch {
                return (.default, "Could not read saved configuration: \(error.localizedDescription)")
            }
        }

        do {
            return (try bundledProfile(), nil)
        } catch {
            return (.default, "Could not read bundled configuration: \(error.localizedDescription)")
        }
    }

    public static func bundledProfile() throws -> AppConfiguration {
        var configuration = AppConfiguration.default
        configuration.rules = try MIDICaptainProfileParser.parse(bundledProfileText)
        return configuration
    }

    public static let settingsFileName = "Captain-Blinkheart-Settings.json"

    /// Encodes the pedal and MIDI settings (button rules, output note lists,
    /// channels, endpoints, output target, songs, and playlist) without the hosted plugin's
    /// identity or state, so the file is small and portable between machines.
    public static func exportSettings(_ configuration: AppConfiguration) throws -> Data {
        var settings = configuration
        settings.pluginComponent = nil
        settings.pluginState = nil
        settings.stagePi.previewDevicePath = nil
        return try encode(settings)
    }

    /// Applies pedal and MIDI settings from an exported settings file (or a
    /// full configuration file) while keeping the current hosted plugin and its
    /// state. MIDI endpoints not recorded in the file keep their current values.
    public static func importSettings(
        _ data: Data,
        into configuration: AppConfiguration
    ) throws -> AppConfiguration {
        var imported = try decode(data)
        imported.pluginComponent = configuration.pluginComponent
        imported.pluginState = configuration.pluginState
        imported.inputUniqueID = imported.inputUniqueID ?? configuration.inputUniqueID
        imported.outputUniqueID = imported.outputUniqueID ?? configuration.outputUniqueID
        imported.stagePi.previewDevicePath = imported.stagePi.previewDevicePath ?? configuration.stagePi.previewDevicePath
        // Settings files from before songs existed keep the current songs.
        if imported.songs.isEmpty, imported.playlist.isEmpty {
            imported.songs = configuration.songs
            imported.playlist = configuration.playlist
        }
        return imported
    }

    public static func importMIDICaptainProfile(
        _ text: String,
        into configuration: AppConfiguration
    ) throws -> AppConfiguration {
        var updated = configuration
        updated.rules = try MIDICaptainProfileParser.parse(text)
        return updated
    }

    private static var bundledProfileText: String {
        if let url = Bundle.main.url(forResource: "MIDI-Captain-MNDL-page0", withExtension: "txt")
            ?? Bundle.module.url(forResource: "MIDI-Captain-MNDL-page0", withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        return ""
    }

    public static func save(_ configuration: AppConfiguration) throws {
        let url = applicationSupportURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encode(configuration).write(to: url, options: .atomic)
    }
}

public enum SceneSelector {
    public static func select(
        from cues: [MIDICue],
        avoiding previousID: String?,
        randomIndex: (Range<Int>) -> Int = { Int.random(in: $0) }
    ) -> MIDICue? {
        guard !cues.isEmpty else { return nil }
        if cues.count > 1, let previousIndex = cues.firstIndex(where: { $0.id == previousID }) {
            let draw = randomIndex(0..<(cues.count - 1))
            let safeDraw = min(max(draw, 0), cues.count - 2)
            let selectedIndex = safeDraw >= previousIndex ? safeDraw + 1 : safeDraw
            return cues[selectedIndex]
        }
        let draw = randomIndex(0..<cues.count)
        let safeIndex = min(max(draw, 0), cues.count - 1)
        return cues[safeIndex]
    }
}
