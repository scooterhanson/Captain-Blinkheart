// Captain Blinkheart
// Copyright (C) 2026 Josh Hanson
// SPDX-License-Identifier: AGPL-3.0-or-later

import SceneBridgeCore
import SwiftUI

extension SceneAction {
    /// The indicator color for each action.
    var displayColor: Color {
        switch self {
        case .reset: .white
        case .baseline: .purple
        case .low: .green
        case .medium: .yellow
        case .high: .orange
        case .critical: .red
        }
    }
}

// MARK: - Performance display

/// The large stage display for playback mode: what's playing, how far in, and
/// what's next.
struct PlaybackDisplay: View {
    @ObservedObject var model: AppModel
    var energyColor: Color

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            content
        }
    }

    private var content: some View {
        let songs = model.playlistSongs
        let playing = model.playback
        let song = playing?.song ?? model.currentSong
        let position = playing?.playlistIndex ?? model.playlistIndex

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                statusBadge(isPlaying: playing != nil)
                Spacer()
                if !songs.isEmpty, playing == nil || playing?.playlistIndex != nil {
                    Text("Song \(position + 1) of \(songs.count)")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(.gray)
                }
            }

            Text(song?.name ?? "No songs in the playlist")
                .font(.system(size: 76, weight: .heavy, design: .rounded))
                .foregroundStyle(song == nil ? .gray : .white)
                .lineLimit(1)
                .minimumScaleFactor(0.4)

            if let song {
                timing(for: song)
            }

            Divider().background(Color.gray)

            HStack(alignment: .firstTextBaseline, spacing: 18) {
                Text("NEXT UP")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(.gray)
                Text(nextUpTitle(playing: playing))
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(Color(white: 0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                Spacer()
                Text(model.energy.uppercased())
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundStyle(energyColor)
                    .lineLimit(1)
                    .help("Last lighting cue")
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 12))
    }

    private func statusBadge(isPlaying: Bool) -> some View {
        let text: String
        let color: Color
        if isPlaying {
            text = "▶ NOW PLAYING"
            color = .green
        } else if let finished = model.lastFinishedSongName {
            text = "READY · finished \(finished)"
            color = .yellow
        } else {
            text = "READY"
            color = .yellow
        }
        return Text(text)
            .font(.system(size: 26, weight: .heavy, design: .rounded))
            .foregroundStyle(color)
            .lineLimit(1)
    }

    private func timing(for song: Song) -> some View {
        let elapsed = model.playbackElapsed() ?? 0
        let duration = song.duration
        return HStack(spacing: 16) {
            Text(SongTimeFormatter.string(elapsed))
                .font(.system(size: 34, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
            ProgressView(value: duration > 0 ? min(elapsed / duration, 1) : 0)
                .tint(.green)
            Text(SongTimeFormatter.string(duration))
                .font(.system(size: 22, weight: .medium, design: .monospaced))
                .foregroundStyle(.gray)
            Text("\(song.events.count) cues")
                .font(.system(size: 18, weight: .medium, design: .rounded))
                .foregroundStyle(.gray)
        }
    }

    private func nextUpTitle(playing: ActivePlayback?) -> String {
        if let playing {
            guard let index = playing.playlistIndex else { return "— preview —" }
            let songs = model.playlistSongs
            return PlaylistNavigator.next(after: index, count: songs.count).map { songs[$0].name } ?? "End of playlist"
        }
        return model.nextSong?.name ?? "End of playlist"
    }
}

/// Mouse-driven transport buttons, mirroring the pedal's playback commands.
struct TransportButtons: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 10) {
            button("Reset", "arrow.counterclockwise", .reset)
            button("Previous", "backward.end.fill", .previous)
            button("Start", "play.fill", .start)
                .disabled(model.playback != nil || model.currentSong == nil)
            button("Stop", "stop.fill", .stop)
                .disabled(model.playback == nil)
            button("Next", "forward.end.fill", .next)
        }
        .controlSize(.large)
    }

    private func button(_ title: String, _ symbol: String, _ action: TransportAction) -> some View {
        Button {
            model.perform(action)
        } label: {
            Label(title, systemImage: symbol)
                .frame(minWidth: 90)
        }
    }
}

/// Shown on the Main tab while a song is recording.
struct RecordingBanner: View {
    @ObservedObject var model: AppModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            if let recording = model.recording {
                let name = model.configuration.song(withID: recording.songID)?.name ?? "Song"
                HStack(spacing: 16) {
                    Image(systemName: "record.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("RECORDING \(name.uppercased())")
                            .font(.system(size: 26, weight: .heavy, design: .rounded))
                            .foregroundStyle(.red)
                            .lineLimit(1)
                        Text(recordingDetail(recording))
                            .font(.system(size: 18, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    Button("Stop & Save", action: model.stopRecording)
                        .controlSize(.large)
                    Button("Discard", role: .destructive, action: model.cancelRecording)
                        .controlSize(.large)
                }
                .padding(18)
                .background(Color.black, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.red, lineWidth: 2))
            }
        }
    }

    private func recordingDetail(_ recording: ActiveRecording) -> String {
        guard let elapsed = model.recordingElapsed() else {
            return "Waiting for the first cue: it becomes time 0:00"
        }
        let count = recording.recorder.events.count
        return "\(SongTimeFormatter.string(elapsed)) · \(count) cue\(count == 1 ? "" : "s")"
    }
}

// MARK: - Songs tab

/// Set up songs, record their cues, and arrange the playlist.
struct SongsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Record a song by arming it, then playing it with the pedal in live mode. The first cue you press is time 0:00. In playback mode, Start fires that first cue and the rest follow on their recorded times, choosing fresh random notes from the MIDI Out lists. Songs and the playlist are saved with the configuration.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 16) {
                    libraryPanel
                    playlistPanel
                }
                if let id = model.selectedSongID, model.configuration.song(withID: id) != nil {
                    songDetail(id)
                }
            }
            .padding(.vertical, 8)
        }
    }

    // Library

    private var libraryPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Songs").font(.headline)
                    Spacer()
                    Button {
                        model.addSong()
                    } label: {
                        Label("New Song", systemImage: "plus")
                    }
                }
                if model.configuration.songs.isEmpty {
                    Text("No songs yet.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
                ForEach(model.configuration.songs) { song in
                    libraryRow(song)
                }
            }
            .padding(4)
        }
        .frame(maxWidth: .infinity)
    }

    private func libraryRow(_ song: Song) -> some View {
        let isSelected = model.selectedSongID == song.id
        let isRecording = model.recording?.songID == song.id
        return HStack(spacing: 8) {
            Button {
                model.selectedSongID = song.id
            } label: {
                HStack {
                    if isRecording {
                        Image(systemName: "record.circle.fill").foregroundStyle(.red)
                    } else if model.playback?.song.id == song.id {
                        Image(systemName: "play.fill").foregroundStyle(.green)
                    }
                    Text(song.name).lineLimit(1)
                    Spacer()
                    Text(song.events.isEmpty ? "not recorded" : "\(song.events.count) cues · \(SongTimeFormatter.string(song.duration, tenths: false))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button {
                model.addToPlaylist(song.id)
            } label: {
                Image(systemName: "text.badge.plus")
            }
            .buttonStyle(.borderless)
            .help("Add to the end of the playlist")
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(
            isSelected ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 6)
        )
    }

    // Playlist

    private var playlistPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text("Playlist").font(.headline)
                let entries = Array(model.configuration.playlist.enumerated())
                if entries.isEmpty {
                    Text("Add songs with \(Image(systemName: "text.badge.plus")).")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
                ForEach(entries, id: \.offset) { index, songID in
                    playlistRow(index: index, songID: songID, count: entries.count)
                }
            }
            .padding(4)
        }
        .frame(maxWidth: .infinity)
    }

    private func playlistRow(index: Int, songID: UUID, count: Int) -> some View {
        let song = model.configuration.song(withID: songID)
        let isCurrent = model.playlistIndex == index
        return HStack(spacing: 8) {
            Text("\(index + 1)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .trailing)
            Button {
                model.selectPlaylistEntry(index)
            } label: {
                HStack {
                    Text(song?.name ?? "Missing song").lineLimit(1)
                    Spacer()
                    if isCurrent {
                        Text(model.playback?.playlistIndex == index ? "playing" : "up next")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(model.playback?.playlistIndex == index ? .green : .yellow)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Make this the song Start plays")
            Button { model.movePlaylistEntry(at: index, by: -1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(index == 0)
            Button { model.movePlaylistEntry(at: index, by: 1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(index == count - 1)
            Button(role: .destructive) { model.removePlaylistEntry(at: index) } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
                .help("Remove from the playlist")
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(
            isCurrent ? Color.yellow.opacity(0.15) : Color.secondary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 6)
        )
    }

    // Song detail

    private func songDetail(_ id: UUID) -> some View {
        let song = model.configuration.song(withID: id) ?? Song(name: "")
        let isRecording = model.recording?.songID == id
        let isPlaying = model.playback?.song.id == id
        return GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    TextField("Song name", text: songNameBinding(id))
                        .textFieldStyle(.roundedBorder)
                        .font(.title3)
                    if isRecording {
                        Button("Stop & Save", action: model.stopRecording)
                        Button("Discard", role: .destructive, action: model.cancelRecording)
                    } else {
                        Button {
                            model.startRecording(songID: id)
                        } label: {
                            Label(song.events.isEmpty ? "Record" : "Re-record", systemImage: "record.circle")
                                .foregroundStyle(.red)
                        }
                        .disabled(model.recording != nil)
                        .help("Arm recording. Switches to live mode; the first pedal cue starts the clock.")
                    }
                    if isPlaying {
                        Button {
                            model.stopPlayback()
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                    } else {
                        Button {
                            model.play(song)
                        } label: {
                            Label("Preview", systemImage: "play.fill")
                        }
                        .disabled(song.events.isEmpty || model.recording != nil)
                        .help("Play this song now to check its timing")
                    }
                    Button(role: .destructive) {
                        model.deleteSong(id)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
                if isRecording {
                    RecordingBanner(model: model)
                }
                if song.events.isEmpty {
                    Text("No cues recorded yet.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(song.events.count) cues over \(SongTimeFormatter.string(song.duration)). Edit a time (in seconds) or action to fine-tune.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(song.sortedEvents) { event in
                        eventRow(songID: id, event: event)
                    }
                }
            }
            .padding(4)
        }
    }

    private func eventRow(songID: UUID, event: SongEvent) -> some View {
        HStack(spacing: 8) {
            Text(SongTimeFormatter.string(event.time))
                .font(.system(.body, design: .monospaced))
                .frame(width: 72, alignment: .trailing)
            TextField(
                "Seconds",
                value: eventBinding(songID: songID, eventID: event.id).time,
                format: .number.precision(.fractionLength(0...3))
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 90)
            Text("s").foregroundStyle(.secondary)
            Picker("Action", selection: eventBinding(songID: songID, eventID: event.id).action) {
                ForEach(SceneAction.displayOrder) { action in
                    Text(action.energy).tag(action)
                }
            }
            .labelsHidden()
            .frame(width: 130)
            Circle()
                .fill(event.action.displayColor)
                .frame(width: 10, height: 10)
            Spacer()
            Button(role: .destructive) {
                removeEvent(songID: songID, eventID: event.id)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
        }
    }

    // Bindings

    private func songNameBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { model.configuration.song(withID: id)?.name ?? "" },
            set: { name in
                guard let index = model.configuration.songs.firstIndex(where: { $0.id == id }) else { return }
                model.configuration.songs[index].name = name
            }
        )
    }

    private func eventBinding(songID: UUID, eventID: UUID) -> Binding<SongEvent> {
        Binding(
            get: {
                model.configuration.song(withID: songID)?.events.first { $0.id == eventID }
                    ?? SongEvent(id: eventID, time: 0, action: .reset)
            },
            set: { updated in
                var configuration = model.configuration
                guard let songIndex = configuration.songs.firstIndex(where: { $0.id == songID }),
                      let eventIndex = configuration.songs[songIndex].events.firstIndex(where: { $0.id == eventID })
                else { return }
                var event = updated
                event.time = max(0, event.time)
                configuration.songs[songIndex].events[eventIndex] = event
                model.configuration = configuration
            }
        )
    }

    private func removeEvent(songID: UUID, eventID: UUID) {
        guard let songIndex = model.configuration.songs.firstIndex(where: { $0.id == songID }) else { return }
        model.configuration.songs[songIndex].events.removeAll { $0.id == eventID }
    }
}
