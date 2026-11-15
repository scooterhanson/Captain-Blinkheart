// Captain Blinkheart
// Copyright (C) 2026 Josh Hanson
// SPDX-License-Identifier: AGPL-3.0-or-later

import AppKit
import AudioToolbox
import AudioToolbox.AUCocoaUIView
import AVFoundation
import Combine
import CoreAudioKit
import SceneBridgeCore

/// Hosts a MIDI-controlled Audio Unit (Show Buddy Active by default) inside the
/// app so cues can be delivered without an IAC bus or a separate DAW.
///
/// The unit runs in an `AVAudioEngine`. A music effect (`aumf`) is fed silence
/// from a source node so it renders, and therefore processes MIDI, without
/// requesting microphone access.
@MainActor
final class PluginHost: ObservableObject {
    struct Component: Identifiable, Hashable {
        let id: PluginComponentID
        let description: AudioComponentDescription
        var name: String { id.name }

        static func == (lhs: Component, rhs: Component) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    @Published private(set) var components: [Component] = []
    @Published private(set) var loadedComponent: PluginComponentID?
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    /// The loaded plugin's own editor, shown in the Plugin tab.
    @Published private(set) var editorView: NSView?

    /// Called on the main actor when a scheduled note-off has been delivered.
    var onTransmission: ((Int, Int, String?) -> Void)?

    private let engine = AVAudioEngine()
    private var unit: AVAudioUnit?
    private var silence: AVAudioSourceNode?
    private var configurationObserver: NSObjectProtocol?

    var isLoaded: Bool { unit != nil }

    init() {
        refreshComponents()
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartEngine() }
        }
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    // MARK: - Discovery

    /// Lists installed music effects and instruments, with Show Buddy first.
    func refreshComponents() {
        let manager = AVAudioUnitComponentManager.shared()
        let found = manager.components { component, _ in
            let type = component.audioComponentDescription.componentType
            return type == kAudioUnitType_MusicEffect || type == kAudioUnitType_MusicDevice
        }
        components = found
            .map { component in
                let description = component.audioComponentDescription
                return Component(
                    id: PluginComponentID(
                        type: FourCharCode.string(description.componentType),
                        subtype: FourCharCode.string(description.componentSubType),
                        manufacturer: FourCharCode.string(description.componentManufacturer),
                        name: "\(component.manufacturerName): \(component.name)"
                    ),
                    description: description
                )
            }
            .sorted { lhs, rhs in
                let lhsBuddy = lhs.name.localizedCaseInsensitiveContains("Show Buddy")
                let rhsBuddy = rhs.name.localizedCaseInsensitiveContains("Show Buddy")
                if lhsBuddy != rhsBuddy { return lhsBuddy }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    func component(matching id: PluginComponentID?) -> Component? {
        guard let id else { return nil }
        return components.first {
            id.matches(
                type: $0.description.componentType,
                subtype: $0.description.componentSubType,
                manufacturer: $0.description.componentManufacturer
            )
        }
    }

    // MARK: - Loading

    /// Instantiates the component, restores its saved state, and starts audio.
    func load(_ id: PluginComponentID, state: Data?, completion: ((String?) -> Void)? = nil) {
        guard let component = component(matching: id) else {
            let message = "\(id.name) (\(id.type) \(id.subtype) \(id.manufacturer)) is not installed."
            lastError = message
            completion?(message)
            return
        }
        unload()
        isLoading = true
        lastError = nil

        AVAudioUnit.instantiate(with: component.description, options: []) { [weak self] audioUnit, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLoading = false
                guard let audioUnit else {
                    let message = "Could not load \(id.name): \(error?.localizedDescription ?? "unknown error")."
                    self.lastError = message
                    completion?(message)
                    return
                }
                let message = self.install(audioUnit, id: id, state: state)
                self.lastError = message
                self.loadEditorView(for: audioUnit) { [weak self] view in
                    guard let self, self.unit === audioUnit else { return }
                    self.editorView = view
                }
                completion?(message)
            }
        }
    }

    private func install(_ audioUnit: AVAudioUnit, id: PluginComponentID, state: Data?) -> String? {
        if let state, let restored = Self.decodeState(state) {
            audioUnit.auAudioUnit.fullState = restored
        }

        let outputFormat = engine.outputNode.outputFormat(forBus: 0)
        let sampleRate = outputFormat.sampleRate > 0 ? outputFormat.sampleRate : 48_000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            return "Could not create an audio format for the plugin."
        }

        engine.attach(audioUnit)
        if audioUnit.audioComponentDescription.componentType == kAudioUnitType_MusicEffect {
            let source = AVAudioSourceNode(format: format) { isSilence, _, _, bufferList in
                isSilence.pointee = true
                for buffer in UnsafeMutableAudioBufferListPointer(bufferList) {
                    if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
                }
                return noErr
            }
            engine.attach(source)
            engine.connect(source, to: audioUnit, format: format)
            silence = source
        }
        engine.connect(audioUnit, to: engine.mainMixerNode, format: format)

        unit = audioUnit
        loadedComponent = id
        do {
            engine.prepare()
            try engine.start()
        } catch {
            return "\(id.name) loaded, but audio could not start: \(error.localizedDescription)"
        }
        return nil
    }

    func unload() {
        editorView?.removeFromSuperview()
        editorView = nil
        engine.stop()
        if let silence {
            engine.detach(silence)
            self.silence = nil
        }
        if let unit {
            engine.detach(unit)
            self.unit = nil
        }
        loadedComponent = nil
    }

    private func restartEngine() {
        guard unit != nil, !engine.isRunning else { return }
        do {
            try engine.start()
        } catch {
            lastError = "Audio restart failed: \(error.localizedDescription)"
        }
    }

    // MARK: - State

    /// The plugin's current state as a binary property list, for saving with the configuration.
    func captureState() -> Data? {
        guard let state = unit?.auAudioUnit.fullState else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: state, format: .binary, options: 0)
    }

    private static func decodeState(_ data: Data) -> [String: Any]? {
        (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    // MARK: - MIDI

    /// Sends a note-on to the hosted plugin, followed by a note-off 150 ms later.
    func sendNoteOn(note: Int, velocity: Int, channel: Int) -> String? {
        guard (0...127).contains(note), (1...127).contains(velocity), (1...16).contains(channel) else {
            return "MIDI note, velocity, or channel is outside its valid range."
        }
        guard unit != nil else { return "The ShowBuddy plugin is not loaded." }
        if !engine.isRunning {
            do { try engine.start() } catch {
                return "Plugin audio is not running: \(error.localizedDescription)"
            }
        }

        let status = UInt8(0x90 | (channel - 1))
        if let error = send(status: status, data1: UInt8(note), data2: UInt8(velocity)) {
            return error
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            let error = self.send(status: UInt8(0x80 | (channel - 1)), data1: UInt8(note), data2: 0)
            self.onTransmission?(note, 0, error)
        }
        return nil
    }

    private func send(status: UInt8, data1: UInt8, data2: UInt8) -> String? {
        guard let unit else { return "The ShowBuddy plugin is not loaded." }
        if let scheduleMIDI = unit.auAudioUnit.scheduleMIDIEventBlock {
            var bytes = [status, data1, data2]
            scheduleMIDI(AUEventSampleTimeImmediate, 0, bytes.count, &bytes)
            return nil
        }
        let result = MusicDeviceMIDIEvent(unit.audioUnit, UInt32(status), UInt32(data1), UInt32(data2), 0)
        return result == noErr ? nil : "Plugin rejected MIDI (error \(result))."
    }

    // MARK: - Editor view

    /// Loads the plugin's own editor: the AUv3 view controller when available,
    /// then the AUv2 Cocoa view, then a generic parameter view.
    private func loadEditorView(for unit: AVAudioUnit, completion: @escaping (NSView) -> Void) {
        let isV3 = unit.audioComponentDescription.componentFlags
            & AudioComponentFlags.isV3AudioUnit.rawValue != 0
        if isV3 {
            unit.auAudioUnit.requestViewController { controller in
                DispatchQueue.main.async {
                    if let view = controller?.view {
                        if view.frame.size == .zero {
                            view.setFrameSize(controller?.preferredContentSize ?? NSSize(width: 800, height: 600))
                        }
                        completion(view)
                    } else {
                        completion(Self.genericView(for: unit))
                    }
                }
            }
            return
        }
        completion(Self.cocoaView(for: unit.audioUnit) ?? Self.genericView(for: unit))
    }

    private static func genericView(for unit: AVAudioUnit) -> NSView {
        let view = AUGenericView(audioUnit: unit.audioUnit)
        view.showsExpertParameters = true
        if view.frame.size == .zero { view.setFrameSize(NSSize(width: 480, height: 320)) }
        return view
    }

    private static func cocoaView(for audioUnit: AudioUnit) -> NSView? {
        var dataSize: UInt32 = 0
        var writable: DarwinBoolean = false
        guard AudioUnitGetPropertyInfo(
            audioUnit, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, &dataSize, &writable
        ) == noErr, dataSize >= UInt32(MemoryLayout<AudioUnitCocoaViewInfo>.size) else { return nil }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioUnitCocoaViewInfo>.alignment
        )
        defer { raw.deallocate() }
        guard AudioUnitGetProperty(
            audioUnit, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, raw, &dataSize
        ) == noErr else { return nil }

        let info = raw.load(as: AudioUnitCocoaViewInfo.self)
        let bundleURL = info.mCocoaAUViewBundleLocation.takeRetainedValue() as URL
        let className = info.mCocoaAUViewClass.takeRetainedValue() as String
        // Release any additional class names the unit returned.
        let extraCount = (Int(dataSize) - MemoryLayout<AudioUnitCocoaViewInfo>.size)
            / MemoryLayout<Unmanaged<CFString>>.stride
        if extraCount > 0 {
            let extras = (raw + MemoryLayout<AudioUnitCocoaViewInfo>.size)
                .bindMemory(to: Unmanaged<CFString>.self, capacity: extraCount)
            for index in 0..<extraCount { extras[index].release() }
        }

        guard let bundle = Bundle(url: bundleURL), bundle.load(),
              let viewClass = bundle.classNamed(className) as? NSObject.Type,
              let factory = viewClass.init() as? AUCocoaUIBase
        else { return nil }
        return factory.uiView(forAudioUnit: audioUnit, with: NSSize(width: 800, height: 600))
    }
}
