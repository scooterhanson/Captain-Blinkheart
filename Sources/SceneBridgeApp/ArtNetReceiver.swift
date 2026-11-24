// Captain Blinkheart
// Copyright (C) 2026 Josh Hanson
// SPDX-License-Identifier: AGPL-3.0-or-later

import Combine
import Darwin
import Foundation
import SceneBridgeCore

/// Receives Art-Net DMX from Show Buddy on 127.0.0.1 and records it for scene
/// capture.
///
/// Only the loopback address is used, so macOS never asks for firewall or
/// local network permission: set Show Buddy's Art-Net output to 127.0.0.1.
final class ArtNetReceiver: ObservableObject {
    struct Status: Equatable {
        var isListening = false
        var framesPerSecond = 0.0
        var lastFrameTime: TimeInterval?
        /// Channels above zero in the latest frame: 0 means Show Buddy is sending darkness.
        var litChannels = 0
        var error: String?
    }

    static let port: UInt16 = 6454

    @Published private(set) var status = Status()

    /// Called on the receiver's thread for every frame of the selected universe.
    var onFrame: (([UInt8]) -> Void)?

    private let lock = NSLock()
    private var socketDescriptor: Int32 = -1
    private var thread: Thread?
    private var universe = 0
    private var recording: [TimedDMXFrame]?
    private var latest: [UInt8]?
    private var frameTimes: [TimeInterval] = []
    private var statusTimer: Timer?

    deinit { stop() }

    var isReceiving: Bool {
        guard let last = status.lastFrameTime else { return false }
        return AppModel.now() - last < 1.0
    }

    func start(universe: Int) {
        lock.lock(); self.universe = universe; lock.unlock()
        guard socketDescriptor < 0 else { return }

        let descriptor = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else {
            status.error = "Could not open a network socket (\(String(cString: strerror(errno))))."
            return
        }
        var yes: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = Self.port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            status.error = "Could not listen for Art-Net on port 6454 (\(String(cString: strerror(errno))))."
            close(descriptor)
            return
        }

        socketDescriptor = descriptor
        status = Status(isListening: true)
        let thread = Thread { [weak self] in self?.receiveLoop(descriptor) }
        thread.name = "Art-Net receiver"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()

        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.publishStatus()
        }
    }

    func stop() {
        statusTimer?.invalidate()
        statusTimer = nil
        thread?.cancel()
        thread = nil
        if socketDescriptor >= 0 {
            close(socketDescriptor)
            socketDescriptor = -1
        }
        status = Status()
    }

    func setUniverse(_ universe: Int) {
        lock.lock(); self.universe = universe; lock.unlock()
    }

    // MARK: Recording

    func startRecording() {
        lock.lock(); recording = []; lock.unlock()
    }

    func stopRecording() -> [TimedDMXFrame] {
        lock.lock(); defer { lock.unlock() }
        let frames = recording ?? []
        recording = nil
        return frames
    }

    var latestFrame: [UInt8]? {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    // MARK: Receiving

    private func receiveLoop(_ descriptor: Int32) {
        var buffer = [UInt8](repeating: 0, count: 1024)
        while !Thread.current.isCancelled {
            let count = recv(descriptor, &buffer, buffer.count, 0)
            guard count > 0 else { continue }
            guard let channels = Self.parseArtDmx(Array(buffer[0..<count]), universe: currentUniverse) else { continue }
            let now = AppModel.now()
            lock.lock()
            latest = channels
            recording?.append(TimedDMXFrame(time: now, channels: channels))
            frameTimes.append(now)
            if frameTimes.count > 120 { frameTimes.removeFirst(frameTimes.count - 120) }
            lock.unlock()
            onFrame?(channels)
        }
    }

    private var currentUniverse: Int {
        lock.lock(); defer { lock.unlock() }
        return universe
    }

    /// Returns the DMX channels of an ArtDmx packet for `universe`, padded to 512.
    static func parseArtDmx(_ packet: [UInt8], universe: Int) -> [UInt8]? {
        guard packet.count >= 18,
              packet[0..<8].elementsEqual(Array("Art-Net".utf8) + [0]),
              packet[8] == 0x00, packet[9] == 0x50 // OpDmx, little-endian 0x5000
        else { return nil }
        let packetUniverse = Int(packet[14]) | Int(packet[15]) << 8
        guard packetUniverse == universe else { return nil }
        let length = min(Int(packet[16]) << 8 | Int(packet[17]), packet.count - 18, 512)
        var channels = Array(packet[18..<(18 + length)])
        if channels.count < 512 { channels += Array(repeating: 0, count: 512 - channels.count) }
        return channels
    }

    private func publishStatus() {
        lock.lock()
        let times = frameTimes
        let lit = latest?.reduce(0) { $0 + ($1 > 0 ? 1 : 0) } ?? 0
        lock.unlock()
        let now = AppModel.now()
        let recent = times.filter { now - $0 < 2 }
        var updated = status
        updated.lastFrameTime = times.last
        updated.litChannels = lit
        if recent.count > 1, let first = recent.first, let last = recent.last, last > first {
            updated.framesPerSecond = Double(recent.count - 1) / (last - first)
        } else {
            updated.framesPerSecond = 0
        }
        if updated != status { status = updated }
    }
}
