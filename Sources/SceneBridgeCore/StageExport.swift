// Captain Blinkheart
// Copyright (C) 2026 Josh Hanson
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

// MARK: - Settings

/// The type of USB-DMX interface used for the light preview on the Mac.
public enum DMXInterfaceType: String, Codable, CaseIterable, Identifiable {
    /// Enttec DMX USB Pro and compatibles: the box handles DMX timing.
    case enttecPro
    /// Enttec Open DMX USB and compatibles: the computer generates DMX timing.
    case openDMX

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .enttecPro: "DMX USB Pro"
        case .openDMX: "Open DMX USB"
        }
    }
}

/// Settings for exporting a show to the stage Raspberry Pi.
public struct StagePiSettings: Codable, Equatable {
    /// Listen for Art-Net from Show Buddy on 127.0.0.1.
    public var artNetEnabled: Bool
    /// The Art-Net universe (0-based) to capture.
    public var artNetUniverse: Int
    /// The serial device that mirrors the received DMX to lights, e.g. /dev/cu.usbserial-EN123456.
    public var previewDevicePath: String?
    public var previewDeviceType: DMXInterfaceType
    /// The fade used by switch groups without their own fade, in seconds.
    public var defaultFade: Double
    /// Fade time in seconds per action (`SceneAction.rawValue`). Missing means `defaultFade`.
    public var fades: [String: Double]
    /// How long each scene is recorded, in seconds.
    public var captureSeconds: Double
    /// How long to wait after firing a scene before recording, so Show Buddy's
    /// own transition from the previous scene isn't recorded.
    public var settleSeconds: Double
    /// How long the loop's seam is blended, in seconds.
    public var seamSeconds: Double

    public init(
        artNetEnabled: Bool = false,
        artNetUniverse: Int = 0,
        previewDevicePath: String? = nil,
        previewDeviceType: DMXInterfaceType = .enttecPro,
        defaultFade: Double = 1.0,
        fades: [String: Double] = StagePiSettings.defaultFades,
        captureSeconds: Double = 20,
        settleSeconds: Double = 1.5,
        seamSeconds: Double = 1.0
    ) {
        self.artNetEnabled = artNetEnabled
        self.artNetUniverse = artNetUniverse
        self.previewDevicePath = previewDevicePath
        self.previewDeviceType = previewDeviceType
        self.defaultFade = defaultFade
        self.fades = fades
        self.captureSeconds = captureSeconds
        self.settleSeconds = settleSeconds
        self.seamSeconds = seamSeconds
    }

    /// Slower fades for calmer groups: Intro and Low 2.5 s, Medium 1.5 s,
    /// High 0.6 s, Frenzy 0.2 s, Reset instant.
    public static let defaultFades: [String: Double] = [
        SceneAction.reset.rawValue: 0,
        SceneAction.baseline.rawValue: 2.5,
        SceneAction.low.rawValue: 2.5,
        SceneAction.medium.rawValue: 1.5,
        SceneAction.high.rawValue: 0.6,
        SceneAction.critical.rawValue: 0.2
    ]

    public func fade(for action: SceneAction) -> Double {
        fades[action.rawValue] ?? defaultFade
    }

    public init(from decoder: Decoder) throws {
        let defaults = StagePiSettings()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        artNetEnabled = try container.decodeIfPresent(Bool.self, forKey: .artNetEnabled) ?? defaults.artNetEnabled
        artNetUniverse = try container.decodeIfPresent(Int.self, forKey: .artNetUniverse) ?? defaults.artNetUniverse
        previewDevicePath = try container.decodeIfPresent(String.self, forKey: .previewDevicePath)
        previewDeviceType = try container.decodeIfPresent(DMXInterfaceType.self, forKey: .previewDeviceType) ?? defaults.previewDeviceType
        defaultFade = try container.decodeIfPresent(Double.self, forKey: .defaultFade) ?? defaults.defaultFade
        fades = try container.decodeIfPresent([String: Double].self, forKey: .fades) ?? defaults.fades
        captureSeconds = try container.decodeIfPresent(Double.self, forKey: .captureSeconds) ?? defaults.captureSeconds
        settleSeconds = try container.decodeIfPresent(Double.self, forKey: .settleSeconds) ?? defaults.settleSeconds
        seamSeconds = try container.decodeIfPresent(Double.self, forKey: .seamSeconds) ?? defaults.seamSeconds
    }
}

// MARK: - Recorded DMX

/// One received DMX frame and when it arrived, in seconds.
public struct TimedDMXFrame: Equatable {
    public var time: TimeInterval
    public var channels: [UInt8]

    public init(time: TimeInterval, channels: [UInt8]) {
        self.time = time
        self.channels = channels
    }
}

/// A scene ready to loop: frames at a fixed interval.
public struct DMXLoop: Equatable {
    public var frames: [[UInt8]]
    public var stepMilliseconds: Int
    /// True when the scene doesn't move and is stored as a single frame.
    public var isStatic: Bool
    /// How different the loop's end was from its start before blending (0–255).
    public var seamDifference: Double

    public var duration: TimeInterval { Double(frames.count * stepMilliseconds) / 1000 }
}

public enum DMXLoopBuilder {
    public enum BuildError: LocalizedError, Equatable {
        case noFrames

        public var errorDescription: String? {
            "No DMX was received. Check that Show Buddy sends Art-Net to 127.0.0.1."
        }
    }

    /// Turns a recording into a seamless loop.
    ///
    /// Show Buddy's chases rarely repeat exactly, so instead of looking for a
    /// repeat, this picks the end point (in the last `searchSeconds` of the
    /// recording) that best matches the start, then blends the frames that
    /// follow that end point into the loop's first `seamSeconds`, so the
    /// restart is a smooth continuation.
    public static func build(
        from recording: [TimedDMXFrame],
        channelCount: Int = 512,
        seamSeconds: Double = 1.0,
        searchSeconds: Double = 10.0
    ) throws -> DMXLoop {
        guard !recording.isEmpty else { throw BuildError.noFrames }
        let step = stepMilliseconds(for: recording)
        let frames = resample(recording, stepMilliseconds: step, channelCount: channelCount)

        if isStatic(frames) {
            return DMXLoop(frames: [frames[0]], stepMilliseconds: step, isStatic: true, seamDifference: 0)
        }

        let seam = max(1, Int((seamSeconds * 1000 / Double(step)).rounded()))
        let search = max(1, Int((searchSeconds * 1000 / Double(step)).rounded()))
        let count = frames.count
        guard count >= 2 * seam + 2 else {
            return DMXLoop(frames: frames, stepMilliseconds: step, isStatic: false,
                           seamDifference: meanDifference(frames[count - 1], frames[0]))
        }

        let window = min(5, seam)
        let latestEnd = count - seam
        let earliestEnd = max(seam + 1, latestEnd - search)
        var bestEnd = latestEnd
        var bestCost = Double.greatestFiniteMagnitude
        for end in earliestEnd...latestEnd {
            var cost = 0.0
            for offset in 0..<window {
                cost += meanDifference(frames[end + offset], frames[offset])
            }
            cost /= Double(window)
            if cost < bestCost {
                bestCost = cost
                bestEnd = end
            }
        }

        var loop = Array(frames[0..<bestEnd])
        for index in 0..<seam {
            let weight = Double(index + 1) / Double(seam + 1)
            loop[index] = blend(frames[bestEnd + index], frames[index], weight: weight)
        }
        return DMXLoop(frames: loop, stepMilliseconds: step, isStatic: false, seamDifference: bestCost)
    }

    /// The median spacing between frames, in whole milliseconds.
    public static func stepMilliseconds(for recording: [TimedDMXFrame]) -> Int {
        guard recording.count > 1 else { return 25 }
        let gaps = zip(recording.dropFirst(), recording).map { ($0.time - $1.time) * 1000 }.sorted()
        let median = gaps[gaps.count / 2]
        return min(max(Int(median.rounded()), 10), 100)
    }

    /// Samples the recording on a fixed grid, holding the latest frame.
    public static func resample(
        _ recording: [TimedDMXFrame],
        stepMilliseconds step: Int,
        channelCount: Int
    ) -> [[UInt8]] {
        guard let first = recording.first, let last = recording.last else { return [] }
        let stepSeconds = Double(step) / 1000
        let count = max(1, Int(((last.time - first.time) / stepSeconds).rounded(.down)) + 1)
        var result: [[UInt8]] = []
        result.reserveCapacity(count)
        var source = 0
        for index in 0..<count {
            let time = first.time + Double(index) * stepSeconds + stepSeconds / 2
            while source + 1 < recording.count, recording[source + 1].time <= time { source += 1 }
            result.append(fit(recording[source].channels, to: channelCount))
        }
        return result
    }

    static func isStatic(_ frames: [[UInt8]]) -> Bool {
        guard let first = frames.first else { return true }
        return frames.allSatisfy { frame in
            zip(frame, first).allSatisfy { abs(Int($0) - Int($1)) <= 1 }
        }
    }

    static func meanDifference(_ lhs: [UInt8], _ rhs: [UInt8]) -> Double {
        guard !lhs.isEmpty else { return 0 }
        var total = 0
        for index in lhs.indices { total += abs(Int(lhs[index]) - Int(rhs[index])) }
        return Double(total) / Double(lhs.count)
    }

    /// `from` weighted by `1 - weight` plus `to` weighted by `weight`.
    static func blend(_ from: [UInt8], _ to: [UInt8], weight: Double) -> [UInt8] {
        zip(from, to).map { UInt8((Double($0) * (1 - weight) + Double($1) * weight).rounded()) }
    }

    static func fit(_ channels: [UInt8], to count: Int) -> [UInt8] {
        if channels.count == count { return channels }
        if channels.count > count { return Array(channels.prefix(count)) }
        return channels + Array(repeating: 0, count: count - channels.count)
    }
}

// MARK: - FSEQ files

/// Writes and reads FSEQ v2 files (uncompressed), the sequence format used by
/// Falcon Player and xLights.
public enum FSEQFile {
    public enum ReadError: LocalizedError {
        case notFSEQ, unsupportedVersion(Int), compressed, truncated

        public var errorDescription: String? {
            switch self {
            case .notFSEQ: "Not an FSEQ file."
            case .unsupportedVersion(let major): "FSEQ version \(major) isn't supported."
            case .compressed: "Compressed FSEQ files aren't supported."
            case .truncated: "The FSEQ file is incomplete."
            }
        }
    }

    public static func encode(_ loop: DMXLoop, producer: String = "Captain Blinkheart") -> Data {
        let channelCount = loop.frames.first?.count ?? 0
        var variableHeader = Data()
        let producerBytes = Array(producer.utf8) + [0]
        appendUInt16(&variableHeader, UInt16(producerBytes.count + 4))
        variableHeader.append(contentsOf: Array("sp".utf8))
        variableHeader.append(contentsOf: producerBytes)

        let headerLength = 32
        var dataOffset = headerLength + variableHeader.count
        dataOffset = (dataOffset + 3) / 4 * 4

        var data = Data()
        data.append(contentsOf: Array("PSEQ".utf8))
        appendUInt16(&data, UInt16(dataOffset))
        data.append(0) // minor version
        data.append(2) // major version
        appendUInt16(&data, UInt16(headerLength))
        appendUInt32(&data, UInt32(channelCount))
        appendUInt32(&data, UInt32(loop.frames.count))
        data.append(UInt8(clamping: loop.stepMilliseconds))
        data.append(0) // flags
        data.append(0) // compression: none, no blocks
        data.append(0) // compression block count
        data.append(0) // sparse range count
        data.append(0) // flags
        appendUInt64(&data, UInt64(Date().timeIntervalSince1970 * 1_000_000))
        data.append(variableHeader)
        data.append(contentsOf: Array(repeating: 0, count: dataOffset - data.count))
        for frame in loop.frames { data.append(contentsOf: frame) }
        return data
    }

    public static func decode(_ data: Data) throws -> DMXLoop {
        let bytes = [UInt8](data)
        guard bytes.count >= 32, Array(bytes[0..<4]) == Array("PSEQ".utf8) else { throw ReadError.notFSEQ }
        guard bytes[7] == 2 else { throw ReadError.unsupportedVersion(Int(bytes[7])) }
        guard bytes[20] & 0x0F == 0 else { throw ReadError.compressed }
        let dataOffset = Int(readUInt16(bytes, 4))
        let channelCount = Int(readUInt32(bytes, 10))
        let frameCount = Int(readUInt32(bytes, 14))
        let step = Int(bytes[18])
        guard bytes.count >= dataOffset + channelCount * frameCount else { throw ReadError.truncated }
        let frames = (0..<frameCount).map { index -> [UInt8] in
            let start = dataOffset + index * channelCount
            return Array(bytes[start..<(start + channelCount)])
        }
        return DMXLoop(frames: frames, stepMilliseconds: step, isStatic: frameCount == 1, seamDifference: 0)
    }

    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(value & 0xFF)); data.append(UInt8(value >> 8))
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8((value >> UInt32(shift)) & 0xFF)) }
    }

    private static func appendUInt64(_ data: inout Data, _ value: UInt64) {
        for shift in stride(from: 0, to: 64, by: 8) { data.append(UInt8((value >> UInt64(shift)) & 0xFF)) }
    }

    private static func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << UInt32(8 * $1) }
    }
}

// MARK: - Show manifest

/// `show.json`: what the stage Pi needs to run the show. Scene files live in
/// each switch's folder next to it.
public struct StageShowManifest: Codable, Equatable {
    public struct Scene: Codable, Equatable {
        public var file: String
        public var name: String
        public var frames: Int
        public var seconds: Double

        public init(file: String, name: String, frames: Int, seconds: Double) {
            self.file = file
            self.name = name
            self.frames = frames
            self.seconds = seconds
        }
    }

    public struct Switch: Codable, Equatable {
        /// 1-based, in pedal order.
        public var number: Int
        public var label: String
        /// The lighting action (`SceneAction.rawValue`), used for colors on the Pi.
        public var action: String
        public var folder: String
        /// "random" picks a different scene each press; "single" always plays the first.
        public var mode: String
        /// Fade into this switch's scenes, in seconds.
        public var fade: Double
        /// The MIDI messages that press this switch, in order.
        public var midi: [MIDIInputMessage]
        public var scenes: [Scene]

        public init(number: Int, label: String, action: String, folder: String, mode: String,
                    fade: Double, midi: [MIDIInputMessage], scenes: [Scene]) {
            self.number = number
            self.label = label
            self.action = action
            self.folder = folder
            self.mode = mode
            self.fade = fade
            self.midi = midi
            self.scenes = scenes
        }
    }

    public var format: String
    public var version: Int
    public var name: String
    public var exported: Date
    public var channels: Int
    public var defaultFade: Double
    /// How long a multi-message switch has to finish, in seconds.
    public var sequenceTimeout: Double
    public var switches: [Switch]

    public static let formatName = "captain-blinkheart-show"
    public static let folderName = "blinkheart"
    public static let fileName = "show.json"

    public init(name: String, exported: Date, channels: Int, defaultFade: Double,
                sequenceTimeout: Double = 1.5, switches: [Switch]) {
        format = Self.formatName
        version = 1
        self.name = name
        self.exported = exported
        self.channels = channels
        self.defaultFade = defaultFade
        self.sequenceTimeout = sequenceTimeout
        self.switches = switches
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> StageShowManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(StageShowManifest.self, from: data)
    }
}

/// Plans which scenes go into which switch folder.
public enum StageExportPlan {
    public struct Entry: Equatable {
        public var number: Int
        public var rule: PedalRule
        public var folder: String
        public var cues: [MIDICue]
    }

    /// One entry per pedal key, in pedal order, numbered from 1.
    public static func entries(for configuration: AppConfiguration) -> [Entry] {
        configuration.rules
            .sorted { $0.button < $1.button }
            .enumerated()
            .map { index, rule in
                Entry(
                    number: index + 1,
                    rule: rule,
                    folder: "switch-\(index + 1)",
                    cues: configuration.cues(for: rule.action)
                )
            }
    }

    /// Reset always plays its one scene; every other action picks at random.
    public static func mode(for action: SceneAction) -> String {
        action == .reset ? "single" : "random"
    }

    /// Rewrites only show.json in an existing export — labels, MIDI, modes, and
    /// fades — and keeps the recorded scenes, so changing a fade doesn't mean
    /// recording every scene again.
    public static func updateSettings(
        configuration: AppConfiguration,
        showName: String,
        destination: URL
    ) throws -> String {
        let fileManager = FileManager.default
        let folder = destination.appendingPathComponent(StageShowManifest.folderName, isDirectory: true)
        let manifestURL = folder.appendingPathComponent(StageShowManifest.fileName)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw UpdateError.noExport(destination.lastPathComponent)
        }
        let settings = configuration.stagePi
        var switches: [StageShowManifest.Switch] = []
        var warnings: [String] = []
        for entry in entries(for: configuration) {
            let sceneFolder = folder.appendingPathComponent(entry.folder, isDirectory: true)
            let files = ((try? fileManager.contentsOfDirectory(atPath: sceneFolder.path)) ?? [])
                .filter { $0.lowercased().hasSuffix(".fseq") && !$0.hasPrefix(".") }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            let scenes = files.compactMap { file -> StageShowManifest.Scene? in
                guard let data = try? Data(contentsOf: sceneFolder.appendingPathComponent(file)),
                      let loop = try? FSEQFile.decode(data) else { return nil }
                return .init(file: file, name: (file as NSString).deletingPathExtension,
                             frames: loop.frames.count, seconds: loop.duration)
            }
            if scenes.count != entry.cues.count {
                warnings.append("\(entry.folder) has \(scenes.count) recorded scene\(scenes.count == 1 ? "" : "s") but \(entry.rule.action.energy) lists \(entry.cues.count) notes")
            }
            switches.append(.init(
                number: entry.number,
                label: entry.rule.label.isEmpty ? entry.rule.action.energy : entry.rule.label,
                action: entry.rule.action.rawValue,
                folder: entry.folder,
                mode: mode(for: entry.rule.action),
                fade: settings.fade(for: entry.rule.action),
                midi: entry.rule.messages,
                scenes: scenes
            ))
        }
        let manifest = StageShowManifest(
            name: showName,
            exported: Date(),
            channels: 512,
            defaultFade: settings.defaultFade,
            switches: switches
        )
        try manifest.encoded().write(to: manifestURL, options: .atomic)
        var message = "Updated settings in \(folder.path); the recorded scenes were kept."
        if !warnings.isEmpty {
            message += " Run a full export to record changed note lists: " + warnings.joined(separator: "; ") + "."
        }
        return message
    }

    public enum UpdateError: LocalizedError {
        case noExport(String)

        public var errorDescription: String? {
            switch self {
            case .noExport(let name):
                "There's no exported show on \(name). Use Export to Pi… first."
            }
        }
    }

    /// A file name for a cue that is safe on FAT-formatted USB sticks.
    public static func fileName(for cue: MIDICue, existing: Set<String>) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        var base = cue.name.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        while base.contains("--") { base = base.replacingOccurrences(of: "--", with: "-") }
        if base.isEmpty { base = "Scene \(cue.note)" }
        var candidate = "\(base).fseq"
        var counter = 2
        while existing.contains(candidate.lowercased()) {
            candidate = "\(base) \(counter).fseq"
            counter += 1
        }
        return candidate
    }
}
