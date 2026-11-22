// Captain Blinkheart
// Copyright (C) 2026 Josh Hanson
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest
import SceneBridgeCore

final class StageExportTests: XCTestCase {
    func testPerfectLoopIsCutAtItsPeriod() throws {
        let recording = (0..<300).map { index -> TimedDMXFrame in
            let value = UInt8((index % 50) * 5)
            return TimedDMXFrame(time: Double(index) * 0.04, channels: [value, 255 - value] + Array(repeating: 0, count: 510))
        }
        let loop = try DMXLoopBuilder.build(from: recording, seamSeconds: 0.4, searchSeconds: 5)
        XCTAssertEqual(loop.stepMilliseconds, 40)
        XCTAssertEqual(loop.frames.count % 50, 0)
        XCTAssertEqual(loop.seamDifference, 0)
    }

    func testStillSceneIsOneFrame() throws {
        let recording = (0..<100).map { TimedDMXFrame(time: Double($0) * 0.041, channels: [10, 20] + Array(repeating: 0, count: 510)) }
        let loop = try DMXLoopBuilder.build(from: recording)
        XCTAssertTrue(loop.isStatic)
        XCTAssertEqual(loop.frames.count, 1)
        XCTAssertThrowsError(try DMXLoopBuilder.build(from: []))
    }

    func testFSEQRoundTrip() throws {
        let frames = (0..<3).map { index in (0..<512).map { UInt8(($0 + index) % 256) } }
        let loop = DMXLoop(frames: frames, stepMilliseconds: 41, isStatic: false, seamDifference: 0)
        let data = FSEQFile.encode(loop)
        XCTAssertEqual(data.prefix(4), Data("PSEQ".utf8))
        let decoded = try FSEQFile.decode(data)
        XCTAssertEqual(decoded.frames, frames)
        XCTAssertEqual(decoded.stepMilliseconds, 41)
    }

    func testPlanFoldersFadesAndFileNames() {
        var configuration = AppConfiguration.default
        configuration.rules = configuration.rules.map { rule in
            var rule = rule
            rule.button += 1
            return rule
        }
        let plan = StageExportPlan.entries(for: configuration)
        XCTAssertEqual(plan.map(\.folder), (1...6).map { "switch-\($0)" })
        XCTAssertEqual(StageExportPlan.mode(for: .reset), "single")
        XCTAssertEqual(configuration.stagePi.fade(for: .baseline), 2.5)
        XCTAssertEqual(configuration.stagePi.fade(for: .low), 2.5)
        XCTAssertEqual(configuration.stagePi.fade(for: .medium), 1.5)
        configuration.stagePi.fades["high"] = nil
        XCTAssertEqual(configuration.stagePi.fade(for: .high), configuration.stagePi.defaultFade)

        let cue = MIDICue(id: "r", name: "Reset / All Off", note: 0, velocity: 127)
        XCTAssertEqual(StageExportPlan.fileName(for: cue, existing: []), "Reset - All Off.fseq")
        XCTAssertEqual(StageExportPlan.fileName(for: cue, existing: ["reset - all off.fseq"]), "Reset - All Off 2.fseq")
    }
}
