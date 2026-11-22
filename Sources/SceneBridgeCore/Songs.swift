// Captain Blinkheart
// Copyright (C) 2026 Josh Hanson
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Whether the pedal fires lighting actions directly (live) or drives the
/// song player (playback).
public enum PerformanceMode: String, Codable, CaseIterable, Identifiable {
    case live
    case playback

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .live: "Live"
        case .playback: "Playback"
        }
    }
}

/// What a pedal key does in playback mode.
public enum TransportAction: String, Codable, CaseIterable, Identifiable {
    /// Stops the song and sends the Reset cue; stays on the current song.
    case reset
    /// Starts the current song from its first cue.
    case start
    /// Stops the song; stays on the current song.
    case stop
    /// Stops the song and moves to the previous song in the playlist.
    case previous
    /// Stops the song and moves to the next song in the playlist.
    case next
    /// Fires the key's normal lighting action, as in live mode.
    case liveCue
    /// Does nothing in playback mode.
    case none

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .reset: "Reset"
        case .start: "Start"
        case .stop: "Stop"
        case .previous: "Previous Song"
        case .next: "Next Song"
        case .liveCue: "Live Cue"
        case .none: "Nothing"
        }
    }

    /// The default playback role for a key, based on its live action so it
    /// works however the keys are numbered: Reset → Reset, Intro → Start,
    /// Low → Stop, Medium → Previous, High → Next, Frenzy → Live Cue.
    public static func defaultAction(for liveAction: SceneAction) -> TransportAction {
        switch liveAction {
        case .reset: .reset
        case .baseline: .start
        case .low: .stop
        case .medium: .previous
        case .high: .next
        case .critical: .liveCue
        }
    }
}

/// One pedal action in a recorded song, timed from the song's first cue.
public struct SongEvent: Codable, Equatable, Identifiable {
    public var id: UUID
    /// Seconds after the song's first cue.
    public var time: TimeInterval
    public var action: SceneAction

    public init(id: UUID = UUID(), time: TimeInterval, action: SceneAction) {
        self.id = id
        self.time = time
        self.action = action
    }
}

/// A recorded song: the lighting actions to fire and when. Each playback picks
/// fresh random notes for each action from the MIDI Out lists.
public struct Song: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var events: [SongEvent]

    public init(id: UUID = UUID(), name: String, events: [SongEvent] = []) {
        self.id = id
        self.name = name
        self.events = events
    }

    /// The time of the last cue.
    public var duration: TimeInterval { events.map(\.time).max() ?? 0 }

    /// Events in the order they play.
    public var sortedEvents: [SongEvent] {
        events.enumerated()
            .sorted { $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time }
            .map(\.element)
    }
}

/// Collects pedal actions into song events. The first action is time zero.
public struct SongRecorder {
    public private(set) var startTime: TimeInterval?
    public private(set) var events: [SongEvent] = []

    public init() {}

    public var hasStarted: Bool { startTime != nil }

    /// Seconds since the first recorded action, or nil before it.
    public func elapsed(at time: TimeInterval) -> TimeInterval? {
        startTime.map { max(0, time - $0) }
    }

    public mutating func record(_ action: SceneAction, at time: TimeInterval) {
        let start = startTime ?? time
        startTime = start
        events.append(SongEvent(time: max(0, time - start), action: action))
    }
}

/// Walks a song's events in time order and reports which are due.
public struct PlaybackCursor {
    public let events: [SongEvent]
    public private(set) var nextIndex = 0

    public init(song: Song) {
        events = song.sortedEvents
    }

    public var isFinished: Bool { nextIndex >= events.count }

    /// The time of the next event still to fire.
    public var nextEventTime: TimeInterval? {
        events.indices.contains(nextIndex) ? events[nextIndex].time : nil
    }

    /// Returns every event whose time has arrived, in order, and advances past them.
    public mutating func due(at elapsed: TimeInterval) -> [SongEvent] {
        var fired: [SongEvent] = []
        while events.indices.contains(nextIndex), events[nextIndex].time <= elapsed {
            fired.append(events[nextIndex])
            nextIndex += 1
        }
        return fired
    }
}

/// Playlist position helpers.
public enum PlaylistNavigator {
    /// The index after `index`, or nil at the end of the playlist.
    public static func next(after index: Int, count: Int) -> Int? {
        index + 1 < count ? index + 1 : nil
    }

    /// The index before `index`, or nil at the start of the playlist.
    public static func previous(before index: Int) -> Int? {
        index > 0 ? index - 1 : nil
    }

    /// Clamps an index into a playlist of `count` entries.
    public static func clamp(_ index: Int, count: Int) -> Int {
        count == 0 ? 0 : min(max(index, 0), count - 1)
    }
}

/// Formats seconds as m:ss.t for song timing displays.
public enum SongTimeFormatter {
    public static func string(_ seconds: TimeInterval, tenths: Bool = true) -> String {
        let clamped = max(0, seconds)
        let minutes = Int(clamped) / 60
        let wholeSeconds = Int(clamped) % 60
        if tenths {
            let tenth = Int((clamped * 10).rounded(.down)) % 10
            return String(format: "%d:%02d.%d", minutes, wholeSeconds, tenth)
        }
        return String(format: "%d:%02d", minutes, wholeSeconds)
    }
}
