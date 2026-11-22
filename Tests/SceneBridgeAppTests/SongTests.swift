// Captain Blinkheart
// Copyright (C) 2026 Josh Hanson
// SPDX-License-Identifier: AGPL-3.0-or-later

import XCTest
import SceneBridgeCore

final class SongTests: XCTestCase {
    func testRecorderMakesFirstActionTimeZero() {
        var recorder = SongRecorder()
        XCTAssertNil(recorder.elapsed(at: 5))
        recorder.record(.baseline, at: 100)
        recorder.record(.low, at: 104.5)
        recorder.record(.high, at: 110.25)
        XCTAssertEqual(recorder.events.map(\.time), [0, 4.5, 10.25])
        XCTAssertEqual(recorder.events.map(\.action), [.baseline, .low, .high])
        XCTAssertEqual(recorder.elapsed(at: 112), 12)
    }

    func testCursorFiresEventsInTimeOrder() {
        let song = Song(name: "A", events: [
            SongEvent(time: 5, action: .high),
            SongEvent(time: 0, action: .baseline),
            SongEvent(time: 2, action: .low),
            SongEvent(time: 2, action: .medium)
        ])
        XCTAssertEqual(song.duration, 5)
        var cursor = PlaybackCursor(song: song)
        XCTAssertEqual(cursor.due(at: 0).map(\.action), [.baseline])
        XCTAssertEqual(cursor.nextEventTime, 2)
        XCTAssertTrue(cursor.due(at: 1.9).isEmpty)
        XCTAssertEqual(cursor.due(at: 2).map(\.action), [.low, .medium])
        XCTAssertEqual(cursor.due(at: 99).map(\.action), [.high])
        XCTAssertTrue(cursor.isFinished)
        XCTAssertNil(cursor.nextEventTime)
    }

    func testPlaylistNavigation() {
        XCTAssertEqual(PlaylistNavigator.next(after: 0, count: 3), 1)
        XCTAssertNil(PlaylistNavigator.next(after: 2, count: 3))
        XCTAssertNil(PlaylistNavigator.previous(before: 0))
        XCTAssertEqual(PlaylistNavigator.clamp(5, count: 3), 2)
        XCTAssertEqual(PlaylistNavigator.clamp(1, count: 0), 0)
    }

    func testDefaultPlaybackRolesFollowLiveActions() {
        XCTAssertEqual(
            AppConfiguration.default.rules.map(\.playbackAction),
            [.reset, .start, .stop, .previous, .next, .liveCue]
        )
    }

    func testSongsRoundTripAndLegacyDefaults() throws {
        let song = Song(name: "A", events: [SongEvent(time: 0, action: .baseline)])
        var configuration = AppConfiguration.default
        configuration.songs = [song]
        configuration.playlist = [song.id, song.id]
        configuration.performanceMode = .playback
        configuration.rules[2].playbackAction = .none
        let data = try ConfigurationStore.encode(configuration)
        let decoded = try ConfigurationStore.decode(data)
        XCTAssertEqual(decoded, configuration)
        XCTAssertEqual(decoded.playlistSongs.count, 2)

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy["songs"] = nil
        legacy["playlist"] = nil
        legacy["performanceMode"] = nil
        legacy["rules"] = (legacy["rules"] as? [[String: Any]])?.map { rule in
            var rule = rule
            rule["playbackAction"] = nil
            return rule
        }
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        let old = try ConfigurationStore.decode(legacyData)
        XCTAssertTrue(old.songs.isEmpty)
        XCTAssertEqual(old.performanceMode, .live)
        XCTAssertEqual(old.rules.map(\.playbackAction), [.reset, .start, .stop, .previous, .next, .liveCue])

        let imported = try ConfigurationStore.importSettings(legacyData, into: configuration)
        XCTAssertEqual(imported.songs, configuration.songs)
        XCTAssertEqual(imported.playlist, configuration.playlist)
    }
}
