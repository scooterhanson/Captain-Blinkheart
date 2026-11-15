// Captain Blinkheart
// Copyright (C) 2026 Josh Hanson
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import SceneBridgeCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            header
            routing
            TabView(selection: $model.selectedTab) {
                mainTab
                    .tabItem {
                        Label("Main", systemImage: "rectangle.3.group")
                    }
                    .tag(AppTab.main)
                midiCaptainTab
                    .tabItem {
                        Label("MIDI Captain", systemImage: "pedalboard")
                    }
                    .tag(AppTab.midiCaptain)
                midiOutTab
                    .tabItem {
                        Label("MIDI Out", systemImage: "pianokeys")
                    }
                    .tag(AppTab.midiOut)
                PluginTab(model: model, plugin: model.plugin)
                    .tabItem {
                        Label("Show Buddy", systemImage: "lightbulb.2")
                    }
                    .tag(AppTab.plugin)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let status = model.statusMessage {
                Label(status, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(18)
        .frame(minWidth: 850, minHeight: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .fileImporter(
            isPresented: $model.isImportingProfile,
            allowedContentTypes: [.json, .plainText],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { model.importConfiguration(from: url) }
            case .failure(let error):
                model.statusMessage = "Configuration import failed: \(error.localizedDescription)"
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("Captain Blinkheart")
                    .font(.title.bold())
                Text("MIDI pedal control for ShowBuddy Active")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Refresh MIDI", action: model.refreshDevices)
        }
    }

    private var mainTab: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text(model.energy.uppercased())
                    .font(.system(size: 64, weight: .heavy, design: .rounded))
                    .foregroundStyle(energyColor)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(height: 230)
                    .background(Color.black, in: RoundedRectangle(cornerRadius: 12))

                logPanel
            }
            .padding(.vertical, 8)
        }
    }

    private var midiCaptainTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Button("Load Configuration…", action: loadConfiguration)
                    Button("Save Configuration") {
                        if model.hasConfigurationFile {
                            model.saveConfiguration()
                        } else {
                            saveConfigurationAs()
                        }
                    }
                    Button("Save As…", action: saveConfigurationAs)
                }
                HStack {
                    Button("Import MIDI Captain Profile…") { model.isImportingProfile = true }
                    Spacer()
                    settingsTransferButtons
                }
                rulesPanel
            }
            .padding(.vertical, 8)
        }
    }

    private var midiOutTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Spacer()
                    settingsTransferButtons
                }
                scenesPanel
            }
            .padding(.vertical, 8)
        }
    }

    /// Export/import of the pedal rules and MIDI output settings as a portable file.
    private var settingsTransferButtons: some View {
        HStack {
            Button("Import Settings…", action: model.presentImportSettings)
            Button("Export Settings…", action: model.presentExportSettings)
        }
        .help("Import or export pedal button rules and MIDI output settings (excludes the hosted plugin's state)")
    }

    private var routing: some View {
        GroupBox("MIDI Routing") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 16) {
                    endpointPicker(
                        label: "Pedal input",
                        devices: model.midi.sources,
                        selectedID: $model.configuration.inputUniqueID
                    )
                    Picker("Send to", selection: outputTargetBinding) {
                        ForEach(OutputTarget.allCases) { target in
                            Text(target.title).tag(target)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 260)
                    channelPicker(label: "Output channel", selection: $model.configuration.outputChannel)
                }
                switch model.configuration.outputTarget {
                case .midiPort:
                    endpointPicker(
                        label: "ShowBuddy output",
                        devices: model.midi.destinations,
                        selectedID: $model.configuration.outputUniqueID
                    )
                case .hostedPlugin:
                    PluginControls(model: model, plugin: model.plugin) {
                        model.selectedTab = .plugin
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var outputTargetBinding: Binding<OutputTarget> {
        Binding(
            get: { model.configuration.outputTarget },
            set: { model.setOutputTarget($0) }
        )
    }

    private var rulesPanel: some View {
        GroupBox("Pedal Buttons") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(model.configuration.rules.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Key \(model.configuration.rules[index].button)")
                                .font(.subheadline.weight(.semibold))
                            TextField("Key label", text: $model.configuration.rules[index].label)
                                .textFieldStyle(.roundedBorder)
                            Picker(
                                "Action",
                                selection: $model.configuration.rules[index].action
                            ) {
                                ForEach(SceneAction.allCases) { action in
                                    Text(action.title).tag(action)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 145)
                        }
                        ForEach(model.configuration.rules[index].messages.indices, id: \.self) { messageIndex in
                            inputMessageEditor(ruleIndex: index, messageIndex: messageIndex)
                        }
                        Button("Add MIDI message") {
                            addInputMessage(to: index)
                        }
                        .font(.caption)
                    }
                    .padding(8)
                    .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }
                Text("A key fires when its messages arrive in order within 1.5 seconds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 4)
        }
    }

    private var scenesPanel: some View {
        GroupBox("MIDI Output Note Mapping") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Each action picks one of its notes at random, avoiding the note it sent last time when it has more than one.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(SceneAction.displayOrder) { action in
                    let group = action.rawValue
                    let indices = model.configuration.scenes[group]?.indices ?? 0..<0
                    VStack(alignment: .leading, spacing: 5) {
                        Text(action.energy)
                            .font(.headline)
                            .foregroundStyle(color(for: action))
                        ForEach(Array(indices), id: \.self) { index in
                            HStack(spacing: 6) {
                                cueEditor(
                                    title: model.configuration.scenes[group]?[index].name ?? "Scene",
                                    cue: cueBinding(group: group, index: index)
                                )
                                Button(role: .destructive) {
                                    removeCue(from: group, at: index)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.plain)
                                .help("Remove this note")
                            }
                        }
                        Button("Add \(action.energy) Note") {
                            addCue(to: action)
                        }
                        .font(.caption)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var logPanel: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Command Log")
                        .font(.headline)
                    Spacer()
                    Button("Clear", action: model.clearLog)
                        .font(.caption)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 5) {
                        ForEach(model.logs.reversed()) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Text(entry.timestamp, format: .dateTime.hour().minute().second())
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                Text(entry.direction)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(logColor(entry.direction))
                                    .frame(width: 38, alignment: .leading)
                                Text(entry.message)
                                    .textSelection(.enabled)
                            }
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(height: 320)
            }
            .padding(.vertical, 4)
        }
    }

    private func endpointPicker(
        label: String,
        devices: [MIDIEndpoint],
        selectedID: Binding<Int32?>
    ) -> some View {
        Picker(label, selection: selectedID) {
            Text("Select…").tag(Int32?.none)
            ForEach(devices) { device in
                Text(device.name).tag(Optional(device.uniqueID))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func inputMessageEditor(ruleIndex: Int, messageIndex: Int) -> some View {
        let message = inputMessageBinding(ruleIndex: ruleIndex, messageIndex: messageIndex)
        return HStack(spacing: 5) {
            Picker("Type", selection: message.kind) {
                Text("Note On").tag(MIDIInputKind.noteOn)
                Text("Note Off").tag(MIDIInputKind.noteOff)
                Text("CC").tag(MIDIInputKind.controlChange)
            }
            .labelsHidden()
            .frame(width: 86)
            Text("Ch")
                .font(.caption)
            TextField("Ch", value: message.channel, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 42)
            Text(message.wrappedValue.kind == .controlChange ? "CC" : "Note")
                .font(.caption)
            TextField("No.", value: message.number, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 48)
            Text("Val")
                .font(.caption)
            TextField("Val", value: message.value, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 48)
            Button(role: .destructive) {
                removeInputMessage(ruleIndex: ruleIndex, messageIndex: messageIndex)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .disabled(model.configuration.rules[ruleIndex].messages.count <= 1)
        }
    }

    private func channelPicker(label: String, selection: Binding<Int>) -> some View {
        Picker(label, selection: selection) {
            ForEach(1...16, id: \.self) { channel in
                Text("\(channel)").tag(channel)
            }
        }
        .frame(width: 100)
    }

    private func inputMessageBinding(ruleIndex: Int, messageIndex: Int) -> Binding<MIDIInputMessage> {
        Binding(
            get: { model.configuration.rules[ruleIndex].messages[messageIndex] },
            set: { updatedMessage in
                var configuration = model.configuration
                guard configuration.rules.indices.contains(ruleIndex),
                      configuration.rules[ruleIndex].messages.indices.contains(messageIndex)
                else { return }
                configuration.rules[ruleIndex].messages[messageIndex] = updatedMessage
                model.configuration = configuration
            }
        )
    }

    private func addInputMessage(to ruleIndex: Int) {
        var configuration = model.configuration
        guard configuration.rules.indices.contains(ruleIndex) else { return }
        configuration.rules[ruleIndex].messages.append(
            MIDIInputMessage(kind: .controlChange, channel: 1, number: 0, value: 127)
        )
        model.configuration = configuration
    }

    private func removeInputMessage(ruleIndex: Int, messageIndex: Int) {
        var configuration = model.configuration
        guard configuration.rules.indices.contains(ruleIndex),
              configuration.rules[ruleIndex].messages.indices.contains(messageIndex),
              configuration.rules[ruleIndex].messages.count > 1
        else { return }
        configuration.rules[ruleIndex].messages.remove(at: messageIndex)
        model.configuration = configuration
    }

    private func cueEditor(title: String, cue: Binding<MIDICue>) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .lineLimit(1)
                .frame(width: 95, alignment: .leading)
            TextField("Cue name", text: cue.name)
                .textFieldStyle(.roundedBorder)
            Text("Note")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Note", value: cue.note, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 58)
            Text("Vel")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Velocity", value: cue.velocity, format: .number)
                .textFieldStyle(.roundedBorder)
                .frame(width: 58)
        }
    }

    private var energyColor: Color {
        switch model.energy {
        case "Reset": .white
        case "Intro": .purple
        case "Low": .green
        case "Medium": .yellow
        case "High": .orange
        case "Frenzy": .red
        default: .gray
        }
    }

    private func color(for action: SceneAction) -> Color {
        switch action {
        case .reset: .primary
        case .baseline: .purple
        case .low: .green
        case .medium: .yellow
        case .high: .orange
        case .critical: .red
        }
    }

    private func logColor(_ direction: String) -> Color {
        switch direction {
        case "IN": .blue
        case "OUT": .green
        default: .secondary
        }
    }

    private func addCue(to action: SceneAction) {
        var cues = model.configuration.cues(for: action)
        let note = min((cues.last?.note ?? 47) + 1, 127)
        cues.append(MIDICue(id: UUID().uuidString, name: "\(action.energy) \(cues.count + 1)", note: note, velocity: 100))
        model.configuration.scenes[action.rawValue] = cues
    }

    private func removeCue(from group: String, at index: Int) {
        guard var cues = model.configuration.scenes[group], cues.indices.contains(index) else { return }
        cues.remove(at: index)
        model.configuration.scenes[group] = cues
    }

    private func cueBinding(group: String, index: Int) -> Binding<MIDICue> {
        Binding(
            get: {
                guard let cues = model.configuration.scenes[group], cues.indices.contains(index) else {
                    return MIDICue(id: "missing", name: "", note: 0, velocity: 100)
                }
                return cues[index]
            },
            set: { updatedCue in
                var configuration = model.configuration
                guard var cues = configuration.scenes[group], cues.indices.contains(index) else { return }
                cues[index] = updatedCue
                configuration.scenes[group] = cues
                model.configuration = configuration
            }
        )
    }

    private func loadConfiguration() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            model.loadConfiguration(from: url)
        }
    }

    private func saveConfigurationAs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ConfigurationStore.fileName
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            model.saveConfiguration(to: url)
        }
    }

}

/// Plugin selection, load/unload, and editor controls shown when cues are sent
/// to the hosted Audio Unit.
private struct PluginControls: View {
    @ObservedObject var model: AppModel
    @ObservedObject var plugin: PluginHost
    var showEditor: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Picker("Plugin", selection: componentBinding) {
                if plugin.component(matching: model.selectedPluginComponent) == nil {
                    Text("\(model.selectedPluginComponent.name) (not installed)")
                        .tag(model.selectedPluginComponent)
                }
                ForEach(plugin.components) { component in
                    Text(component.name).tag(component.id)
                }
            }
            .frame(maxWidth: .infinity)

            if plugin.isLoading {
                ProgressView().controlSize(.small)
            } else if plugin.loadedComponent != nil {
                Label("Loaded", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
                Button("Show Plugin", action: showEditor)
                Button("Unload", action: model.unloadPlugin)
            } else {
                Button("Load Plugin") {
                    model.loadPlugin(model.selectedPluginComponent, restoringState: true)
                }
            }
            Button {
                plugin.refreshComponents()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("Rescan installed Audio Units")
        }
    }

    private var componentBinding: Binding<PluginComponentID> {
        Binding(
            get: { model.selectedPluginComponent },
            set: { model.loadPlugin($0, restoringState: true) }
        )
    }
}

/// The fourth tab: the hosted Show Buddy Active plugin's own screen.
private struct PluginTab: View {
    @ObservedObject var model: AppModel
    @ObservedObject var plugin: PluginHost

    var body: some View {
        Group {
            if let editorView = plugin.editorView {
                ScrollView([.horizontal, .vertical]) {
                    PluginEditorView(editorView: editorView)
                }
            } else {
                placeholder
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "lightbulb.2")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            if plugin.isLoading {
                ProgressView("Loading \(model.selectedPluginComponent.name)…")
            } else if plugin.isLoaded {
                ProgressView("Opening the plugin's screen…")
            } else {
                Text("\(model.selectedPluginComponent.name) is not loaded.")
                    .font(.headline)
                if let error = plugin.lastError {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
                Button("Load Plugin") {
                    model.loadPlugin(model.selectedPluginComponent, restoringState: true)
                }
                Text("Loading the plugin here does not change where cues are sent. Choose **Send to: Hosted Plugin** above to drive it from the pedal.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
        }
        .padding()
    }
}

/// Embeds the plugin's AppKit editor view, sized to the view's own frame and
/// following it if the plugin resizes itself.
private struct PluginEditorView: NSViewRepresentable {
    let editorView: NSView

    func makeNSView(context: Context) -> PluginContainerView {
        PluginContainerView()
    }

    func updateNSView(_ container: PluginContainerView, context: Context) {
        container.host(editorView)
    }

    static func dismantleNSView(_ container: PluginContainerView, coordinator: ()) {
        container.release()
    }
}

final class PluginContainerView: NSView {
    private var hosted: NSView?
    private var frameObserver: NSObjectProtocol?

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        hosted?.frame.size ?? NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    func host(_ view: NSView) {
        guard hosted !== view || view.superview !== self else { return }
        release()
        view.removeFromSuperview()
        view.setFrameOrigin(.zero)
        addSubview(view)
        hosted = view
        view.postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: view,
            queue: .main
        ) { [weak self] _ in
            self?.invalidateIntrinsicContentSize()
        }
        invalidateIntrinsicContentSize()
    }

    func release() {
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        frameObserver = nil
        if hosted?.superview === self { hosted?.removeFromSuperview() }
        hosted = nil
    }
}
