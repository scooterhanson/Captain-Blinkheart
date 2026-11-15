// Captain Blinkheart
// Copyright (C) 2026 Josh Hanson
// SPDX-License-Identifier: AGPL-3.0-or-later

import CoreMIDI
import Combine
import Foundation
import SceneBridgeCore

struct MIDIEndpoint: Identifiable, Equatable {
    let uniqueID: Int32
    let name: String
    var id: Int32 { uniqueID }
}

final class MIDIService: ObservableObject {
    private let midi1Protocol = MIDIProtocolID(rawValue: 1)!

    @Published private(set) var sources: [MIDIEndpoint] = []
    @Published private(set) var destinations: [MIDIEndpoint] = []
    @Published private(set) var setupError: String?

    var onMIDIMessage: ((MIDIInputMessage) -> Void)?
    var onTransmission: ((Int, Int, String?) -> Void)?

    private var client = MIDIClientRef()
    private var inputPort = MIDIPortRef()
    private var outputPort = MIDIPortRef()
    private var connectedSource: MIDIEndpointRef?
    private(set) var selectedOutputUniqueID: Int32?

    init() {
        var status = MIDIClientCreate("Captain Blinkheart" as CFString, nil, nil, &client)
        guard status == noErr else {
            setupError = "Could not create MIDI client (CoreMIDI error \(status))."
            return
        }

        status = MIDIInputPortCreateWithProtocol(
            client,
            "Captain Blinkheart Input" as CFString,
            midi1Protocol,
            &inputPort
        ) { [weak self] eventList, _ in
            self?.receive(eventList)
        }
        guard status == noErr else {
            setupError = "Could not create MIDI input port (CoreMIDI error \(status))."
            return
        }

        status = MIDIOutputPortCreate(client, "Captain Blinkheart Output" as CFString, &outputPort)
        guard status == noErr else {
            setupError = "Could not create MIDI output port (CoreMIDI error \(status))."
            return
        }
        refreshEndpoints()
    }

    deinit {
        if let connectedSource {
            MIDIPortDisconnectSource(inputPort, connectedSource)
        }
        if inputPort != 0 { MIDIPortDispose(inputPort) }
        if outputPort != 0 { MIDIPortDispose(outputPort) }
        if client != 0 { MIDIClientDispose(client) }
    }

    func refreshEndpoints() {
        sources = endpoints(count: MIDIGetNumberOfSources, endpoint: MIDIGetSource)
        destinations = endpoints(count: MIDIGetNumberOfDestinations, endpoint: MIDIGetDestination)
    }

    func connectInput(uniqueID: Int32?) {
        if let connectedSource {
            MIDIPortDisconnectSource(inputPort, connectedSource)
            self.connectedSource = nil
        }
        guard let uniqueID,
              let source = findEndpoint(uniqueID: uniqueID, count: MIDIGetNumberOfSources, endpoint: MIDIGetSource)
        else { return }

        let status = MIDIPortConnectSource(inputPort, source, nil)
        if status == noErr {
            connectedSource = source
            setupError = nil
        } else {
            setupError = "Could not connect MIDI input (CoreMIDI error \(status))."
        }
    }

    func selectOutput(uniqueID: Int32?) {
        selectedOutputUniqueID = uniqueID
    }

    func sendNoteOn(note: Int, velocity: Int, channel: Int) -> String? {
        guard (0...127).contains(note), (1...127).contains(velocity), (1...16).contains(channel) else {
            return "MIDI note, velocity, or channel is outside its valid range."
        }
        guard let uniqueID = selectedOutputUniqueID,
              let destination = findEndpoint(
                uniqueID: uniqueID,
                count: MIDIGetNumberOfDestinations,
                endpoint: MIDIGetDestination
              )
        else {
            return "No MIDI output destination is selected or available."
        }

        let safeChannel = channel - 1
        let safeNote = note
        let safeVelocity = velocity
        let status = send(
            [UInt8(0x90 | safeChannel), UInt8(safeNote), UInt8(safeVelocity)],
            to: destination
        )
        guard status == noErr else {
            return "Could not send MIDI note-on (CoreMIDI error \(status))."
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            let noteOffStatus = self?.send(
                [UInt8(0x80 | safeChannel), UInt8(safeNote), 0],
                to: destination
            ) ?? -1
            self?.onTransmission?(safeNote, 0, noteOffStatus == noErr ? nil : "CoreMIDI error \(noteOffStatus)")
        }
        return nil
    }

    private func receive(_ eventList: UnsafePointer<MIDIEventList>) {
        guard let packetOffset = MemoryLayout<MIDIEventList>.offset(of: \.packet) else { return }
        let packetCount = Int(eventList.pointee.numPackets)
        let packetStride = MemoryLayout<MIDIEventPacket>.stride
        let rawEventList = UnsafeRawPointer(eventList)

        for packetIndex in 0..<packetCount {
            let packet = rawEventList
                .advanced(by: packetOffset + packetIndex * packetStride)
                .assumingMemoryBound(to: MIDIEventPacket.self)
            let wordCount = Int(packet.pointee.wordCount)
            guard wordCount <= 64 else { continue }

            for wordIndex in 0..<wordCount {
                let word = withUnsafeBytes(of: packet.pointee.words) { rawBuffer in
                    rawBuffer.load(fromByteOffset: wordIndex * MemoryLayout<UInt32>.size, as: UInt32.self)
                }
                guard (word >> 28) & 0x0F == 0x02 else { continue }
                let status = UInt8((word >> 16) & 0xFF)
                let command = status & 0xF0
                let channel = Int(status & 0x0F) + 1
                let number = Int((word >> 8) & 0x7F)
                let value = Int(word & 0x7F)
                let kind: MIDIInputKind
                switch command {
                case 0x80:
                    kind = .noteOff
                case 0x90:
                    kind = value == 0 ? .noteOff : .noteOn
                case 0xB0:
                    kind = .controlChange
                default:
                    continue
                }
                let message = MIDIInputMessage(kind: kind, channel: channel, number: number, value: value)
                DispatchQueue.main.async { [weak self] in
                    self?.onMIDIMessage?(message)
                }
            }
        }
    }

    private func send(_ bytes: [UInt8], to destination: MIDIEndpointRef) -> OSStatus {
        guard outputPort != 0 else { return -1 }
        guard bytes.count == 3 else { return -1 }
        let word = (UInt32(0x02) << 28)
            | (UInt32(bytes[0]) << 16)
            | (UInt32(bytes[1]) << 8)
            | UInt32(bytes[2])
        let eventList = MIDIEventList.Builder(inProtocol: midi1Protocol, wordSize: MemoryLayout<UInt32>.size)
        guard eventList.append(timestamp: 0, words: [word]) != nil else { return -1 }
        return eventList.withUnsafePointer { MIDISendEventList(outputPort, destination, $0) }
    }

    private func endpoints(
        count: () -> Int,
        endpoint: (Int) -> MIDIEndpointRef
    ) -> [MIDIEndpoint] {
        (0..<count()).compactMap { index in
            let ref = endpoint(index)
            guard ref != 0, let uniqueID = uniqueID(for: ref) else { return nil }
            return MIDIEndpoint(uniqueID: uniqueID, name: name(for: ref))
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func findEndpoint(
        uniqueID: Int32,
        count: () -> Int,
        endpoint: (Int) -> MIDIEndpointRef
    ) -> MIDIEndpointRef? {
        (0..<count()).map(endpoint).first { self.uniqueID(for: $0) == uniqueID }
    }

    private func uniqueID(for endpoint: MIDIEndpointRef) -> Int32? {
        var value: Int32 = 0
        guard MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &value) == noErr else {
            return nil
        }
        return value
    }

    private func name(for endpoint: MIDIEndpointRef) -> String {
        var value: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(endpoint, kMIDIPropertyName, &value) == noErr,
              let value
        else { return "Unnamed MIDI device" }
        return value.takeRetainedValue() as String
    }
}
