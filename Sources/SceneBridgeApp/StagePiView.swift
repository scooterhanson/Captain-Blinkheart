// Captain Blinkheart
// Copyright (C) 2026 Josh Hanson
// SPDX-License-Identifier: AGPL-3.0-or-later

import SceneBridgeCore
import SwiftUI

/// Capture Show Buddy's scenes over Art-Net and export them for the stage Pi.
struct StagePiTab: View {
    @ObservedObject var model: AppModel
    @ObservedObject var artNet: ArtNetReceiver
    @ObservedObject var preview: DMXSerialOutput
    @ObservedObject var exporter: StageExporter

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Export your Show Buddy scenes to the stage Raspberry Pi. Each pedal key becomes a folder of recorded scenes (switch-1, switch-2, …) plus a show.json with the key's MIDI, label, and fade. Copy the exported \"blinkheart\" folder to the Pi on a USB stick.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                artNetPanel
                previewPanel
                fadePanel
                capturePanel
                exportPanel
            }
            .padding(.vertical, 8)
        }
    }

    private var settings: Binding<StagePiSettings> { $model.configuration.stagePi }

    // MARK: Art-Net

    private var artNetPanel: some View {
        GroupBox("1. Show Buddy → Art-Net") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Receive Art-Net from Show Buddy on 127.0.0.1", isOn: settings.artNetEnabled)
                HStack {
                    Stepper(value: settings.artNetUniverse, in: 0...32767) {
                        Text("Universe \(model.configuration.stagePi.artNetUniverse)")
                    }
                    .frame(width: 180)
                    Spacer()
                    artNetStatus
                }
                Text("In Show Buddy's DMX output settings, choose **Art-Net**, set the IP address to **127.0.0.1**, and turn **broadcast off**. While Show Buddy sends Art-Net it doesn't drive your USB-DMX box directly; turn on the light preview below to keep seeing your lights.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(4)
        }
    }

    @ViewBuilder
    private var artNetStatus: some View {
        if let error = artNet.status.error {
            Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else if !artNet.status.isListening {
            Label("Off", systemImage: "circle").foregroundStyle(.secondary)
        } else if artNet.status.framesPerSecond > 0 {
            Label(String(format: "Receiving %.1f frames/s", artNet.status.framesPerSecond), systemImage: "dot.radiowaves.left.and.right")
                .foregroundStyle(.green)
        } else {
            Label("Listening — no Art-Net from Show Buddy yet", systemImage: "ear")
                .foregroundStyle(.yellow)
        }
    }

    // MARK: Preview

    private var previewPanel: some View {
        GroupBox("2. Light preview (USB-DMX box)") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Device", selection: settings.previewDevicePath) {
                        Text("None").tag(String?.none)
                        ForEach(deviceChoices, id: \.self) { path in
                            Text(path.replacingOccurrences(of: "/dev/", with: "")).tag(Optional(path))
                        }
                    }
                    .frame(maxWidth: 360)
                    Picker("Type", selection: settings.previewDeviceType) {
                        ForEach(DMXInterfaceType.allCases) { type in
                            Text(type.title).tag(type)
                        }
                    }
                    .frame(width: 220)
                    Button {
                        model.reconnectPreview()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Rescan and reconnect the USB-DMX box")
                    Spacer()
                    if let error = preview.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    } else if preview.devicePath != nil {
                        Label("Sending", systemImage: "lightbulb.fill").foregroundStyle(.green)
                    }
                }
                Text("Mirrors the Art-Net from Show Buddy to your Enttec box so you see the lights while you design scenes and export.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(4)
        }
    }

    private var deviceChoices: [String] {
        var devices = DMXSerialOutput.availableDevices()
        if let saved = model.configuration.stagePi.previewDevicePath, !devices.contains(saved) {
            devices.append(saved)
        }
        return devices
    }

    // MARK: Fades

    private var fadePanel: some View {
        GroupBox("3. Fades on the Pi") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Default fade").frame(width: 120, alignment: .leading)
                    secondsField(settings.defaultFade)
                    Text("Used by groups without their own fade.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(SceneAction.displayOrder) { action in
                    fadeRow(action)
                }
            }
            .padding(4)
        }
    }

    private func fadeRow(_ action: SceneAction) -> some View {
        let key = action.rawValue
        let custom = Binding<Bool>(
            get: { model.configuration.stagePi.fades[key] != nil },
            set: { isCustom in
                model.configuration.stagePi.fades[key] = isCustom
                    ? (StagePiSettings.defaultFades[key] ?? model.configuration.stagePi.defaultFade)
                    : nil
            }
        )
        let value = Binding<Double>(
            get: { model.configuration.stagePi.fade(for: action) },
            set: { model.configuration.stagePi.fades[key] = max(0, $0) }
        )
        return HStack {
            Text(action.energy)
                .foregroundStyle(action.displayColor == .white ? Color.primary : action.displayColor)
                .frame(width: 120, alignment: .leading)
            Toggle("Own fade", isOn: custom)
            if custom.wrappedValue {
                secondsField(value)
            } else {
                Text(String(format: "%.1f s (default)", model.configuration.stagePi.defaultFade))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func secondsField(_ value: Binding<Double>) -> some View {
        HStack(spacing: 4) {
            TextField("Seconds", value: value, format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 70)
            Text("s").foregroundStyle(.secondary)
        }
    }

    // MARK: Capture

    private var capturePanel: some View {
        GroupBox("4. Recording") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 18) {
                    labeled("Record each scene for", settings.captureSeconds)
                    labeled("Wait before recording", settings.settleSeconds)
                    labeled("Blend loop seam over", settings.seamSeconds)
                }
                Text("Show Buddy's chases rarely repeat exactly, so each scene is recorded for a while and the loop's end is blended into its start. Waiting first skips Show Buddy's own transition from the previous scene. Scenes that don't move are saved as a single look.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(4)
        }
    }

    private func labeled(_ title: String, _ value: Binding<Double>) -> some View {
        HStack(spacing: 6) {
            Text(title)
            secondsField(value)
        }
    }

    // MARK: Export

    private var exportPanel: some View {
        let estimate = StageExporter.estimate(for: model.configuration)
        let entries = StageExportPlan.entries(for: model.configuration)
        return GroupBox("5. Export") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(entries, id: \.number) { entry in
                    HStack {
                        Text(entry.folder)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 90, alignment: .leading)
                        Text(entry.rule.label).frame(width: 140, alignment: .leading)
                        Text(entry.rule.action.energy)
                            .foregroundStyle(entry.rule.action.displayColor == .white ? Color.primary : entry.rule.action.displayColor)
                            .frame(width: 80, alignment: .leading)
                        Text("\(entry.cues.count) scene\(entry.cues.count == 1 ? "" : "s") · \(StageExportPlan.mode(for: entry.rule.action)) · fade \(String(format: "%.1f", model.configuration.stagePi.fade(for: entry.rule.action))) s")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
                Divider()
                if let progress = exporter.progress {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                        HStack {
                            Text(progress.sceneName.isEmpty
                                 ? progress.phase
                                 : "\(progress.phase) \(progress.sceneName) (\(progress.completed + 1) of \(progress.total))")
                            Spacer()
                            Text("about \(Int((progress.estimatedSecondsLeft / 60).rounded(.up))) min left")
                                .foregroundStyle(.secondary)
                            Button("Cancel", role: .destructive, action: exporter.cancel)
                        }
                    }
                } else {
                    HStack {
                        Button {
                            model.presentStageExport()
                        } label: {
                            Label("Export to Pi…", systemImage: "square.and.arrow.up")
                        }
                        .controlSize(.large)
                        .disabled(!model.configuration.stagePi.artNetEnabled || estimate.scenes == 0)
                        Button("Update Settings Only…", action: model.presentStageSettingsUpdate)
                            .controlSize(.large)
                            .help("Rewrite labels, MIDI, and fades on a stick that already has an export, without recording scenes again")
                        Text("\(estimate.scenes) scenes · about \(Int(estimate.minutes.rounded(.up))) min to record.")
                            .foregroundStyle(.secondary)
                    }
                }
                if let result = exporter.lastResult {
                    Text(result)
                        .font(.callout)
                        .foregroundStyle(result.hasPrefix("Exported") ? .green : .orange)
                        .textSelection(.enabled)
                }
            }
            .padding(4)
        }
    }
}
