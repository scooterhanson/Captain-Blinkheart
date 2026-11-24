// Captain Blinkheart
// Copyright (C) 2026 Josh Hanson
// SPDX-License-Identifier: AGPL-3.0-or-later

import Combine
import Foundation
import SceneBridgeCore

/// Records every scene from Show Buddy's Art-Net output and writes a show
/// folder for the stage Pi: `blinkheart/show.json` plus `switch-N/*.fseq`.
@MainActor
final class StageExporter: ObservableObject {
    struct Progress: Equatable {
        var completed: Int
        var total: Int
        var sceneName: String
        var phase: String
        var startedAt: TimeInterval
        var secondsPerScene: Double

        var estimatedSecondsLeft: Double {
            Double(total - completed) * secondsPerScene
        }
    }

    enum ExportError: LocalizedError {
        case noArtNet, nothingToExport, cueFailed(String, String), allDark(Int)

        var errorDescription: String? {
            switch self {
            case .noArtNet:
                "No Art-Net is arriving from Show Buddy. In Show Buddy's DMX output settings, choose Art-Net, set the IP address to 127.0.0.1 and turn broadcast off, then try again."
            case .nothingToExport:
                "There are no pedal keys with output notes to export."
            case .cueFailed(let name, let error):
                "Could not fire \(name): \(error)"
            case .allDark(let count):
                "The first \(count) scenes recorded every channel at zero, so Show Buddy isn't sending any light levels over Art-Net. Make sure the cues reach Show Buddy (the lights or its editor should change when you fire one) and that the Stage Pi tab shows channels lit, then export again. Nothing was changed on the stick."
            }
        }
    }

    @Published private(set) var progress: Progress?
    @Published var lastResult: String?
    private var task: Task<Void, Never>?

    var isRunning: Bool { task != nil }

    /// Total scenes and approximate minutes for an export of `configuration`.
    static func estimate(for configuration: AppConfiguration) -> (scenes: Int, minutes: Double) {
        let scenes = uniqueActions(in: StageExportPlan.entries(for: configuration))
            .reduce(0) { $0 + configuration.cues(for: $1).count }
        let settings = configuration.stagePi
        let seconds = Double(scenes) * (settings.captureSeconds + settings.settleSeconds + 0.3)
        return (scenes, seconds / 60)
    }

    func cancel() {
        task?.cancel()
    }

    func export(
        configuration: AppConfiguration,
        showName: String,
        to destination: URL,
        artNet: ArtNetReceiver,
        sendCue: @escaping (MIDICue) -> String?,
        log: @escaping (String) -> Void
    ) {
        guard task == nil else { return }
        lastResult = nil
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let summary = try await self.run(
                    configuration: configuration,
                    showName: showName,
                    destination: destination,
                    artNet: artNet,
                    sendCue: sendCue,
                    log: log
                )
                self.lastResult = summary
                log(summary)
            } catch is CancellationError {
                self.lastResult = "Export cancelled. Nothing was changed on \(destination.lastPathComponent)."
                log("Stage export cancelled")
            } catch {
                self.lastResult = "Export failed: \(error.localizedDescription)"
                log("Stage export failed: \(error.localizedDescription)")
            }
            _ = artNet.stopRecording()
            self.progress = nil
            self.task = nil
        }
    }

    private static func uniqueActions(in entries: [StageExportPlan.Entry]) -> [SceneAction] {
        var seen = Set<SceneAction>()
        return entries.map(\.rule.action).filter { seen.insert($0).inserted }
    }

    private func run(
        configuration: AppConfiguration,
        showName: String,
        destination: URL,
        artNet: ArtNetReceiver,
        sendCue: @escaping (MIDICue) -> String?,
        log: @escaping (String) -> Void
    ) async throws -> String {
        let settings = configuration.stagePi
        let entries = StageExportPlan.entries(for: configuration)
        let actions = Self.uniqueActions(in: entries)
        let total = actions.reduce(0) { $0 + configuration.cues(for: $1).count }
        guard total > 0 else { throw ExportError.nothingToExport }
        guard artNet.isReceiving else { throw ExportError.noArtNet }

        // Record every scene once per action, even if several keys share it.
        var loops: [String: DMXLoop] = [:] // keyed by cue id within an action
        var completed = 0
        var litScenes = 0
        var darkScenes = 0
        let perScene = settings.captureSeconds + settings.settleSeconds + 0.3
        let started = AppModel.now()
        log("Stage export: recording \(total) scenes")
        for action in actions {
            for cue in configuration.cues(for: action) {
                try Task.checkCancellation()
                progress = Progress(completed: completed, total: total, sceneName: cue.name,
                                    phase: "Starting", startedAt: started, secondsPerScene: perScene)
                if let error = sendCue(cue) { throw ExportError.cueFailed(cue.name, error) }
                try await Task.sleep(nanoseconds: UInt64(settings.settleSeconds * 1_000_000_000))
                progress?.phase = "Recording"
                artNet.startRecording()
                try await Task.sleep(nanoseconds: UInt64(settings.captureSeconds * 1_000_000_000))
                let frames = artNet.stopRecording()
                guard !frames.isEmpty else { throw ExportError.noArtNet }
                let loop = try DMXLoopBuilder.build(from: frames, seamSeconds: settings.seamSeconds)
                loops["\(action.rawValue)/\(cue.id)"] = loop
                completed += 1
                // Reset is meant to be dark; any other scene with no light at
                // all means Show Buddy isn't sending levels.
                if action != .reset {
                    if loop.frames.contains(where: { $0.contains { $0 > 0 } }) {
                        litScenes += 1
                    } else {
                        darkScenes += 1
                        log("Warning: \(cue.name) recorded every channel at zero")
                        if litScenes == 0 && darkScenes >= 3 { throw ExportError.allDark(darkScenes) }
                    }
                }
                log(String(
                    format: "Recorded %@: %@ (%.1f s loop, seam difference %.1f)",
                    cue.name,
                    loop.isStatic ? "still look" : "\(loop.frames.count) frames",
                    loop.duration,
                    loop.seamDifference
                ))
            }
        }
        progress = Progress(completed: total, total: total, sceneName: "", phase: "Writing files",
                            startedAt: started, secondsPerScene: perScene)

        // Write into a staging folder, then swap it in, so a failed export
        // never leaves a half-written show on the stick.
        let fileManager = FileManager.default
        let staging = destination.appendingPathComponent(".\(StageShowManifest.folderName)-export", isDirectory: true)
        let final = destination.appendingPathComponent(StageShowManifest.folderName, isDirectory: true)
        try? fileManager.removeItem(at: staging)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)

        var switches: [StageShowManifest.Switch] = []
        var fileCount = 0
        for entry in entries {
            let folder = staging.appendingPathComponent(entry.folder, isDirectory: true)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            var used = Set<String>()
            var scenes: [StageShowManifest.Scene] = []
            for cue in entry.cues {
                guard let loop = loops["\(entry.rule.action.rawValue)/\(cue.id)"] else { continue }
                let fileName = StageExportPlan.fileName(for: cue, existing: used)
                used.insert(fileName.lowercased())
                try FSEQFile.encode(loop).write(to: folder.appendingPathComponent(fileName), options: .atomic)
                scenes.append(.init(file: fileName, name: cue.name, frames: loop.frames.count, seconds: loop.duration))
                fileCount += 1
            }
            switches.append(.init(
                number: entry.number,
                label: entry.rule.label.isEmpty ? entry.rule.action.energy : entry.rule.label,
                action: entry.rule.action.rawValue,
                folder: entry.folder,
                mode: StageExportPlan.mode(for: entry.rule.action),
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
        try manifest.encoded().write(to: staging.appendingPathComponent(StageShowManifest.fileName), options: .atomic)

        let previous = destination.appendingPathComponent(".\(StageShowManifest.folderName)-previous", isDirectory: true)
        try? fileManager.removeItem(at: previous)
        if fileManager.fileExists(atPath: final.path) {
            try fileManager.moveItem(at: final, to: previous)
        }
        try fileManager.moveItem(at: staging, to: final)
        try? fileManager.removeItem(at: previous)

        let minutes = (AppModel.now() - started) / 60
        return String(
            format: "Exported %d scenes for %d switches to %@ in %.1f min.",
            fileCount, switches.count, final.path, minutes
        )
    }
}
