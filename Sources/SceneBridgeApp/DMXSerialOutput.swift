// Captain Blinkheart
// Copyright (C) 2026 Josh Hanson
// SPDX-License-Identifier: AGPL-3.0-or-later

import Combine
import Darwin
import Foundation
import SceneBridgeCore

/// Sends DMX to an Enttec USB interface so the lights preview what Show Buddy
/// sends over Art-Net while it isn't driving the interface itself.
///
/// - DMX USB Pro: frames are wrapped in the Pro's "Output Only Send DMX"
///   message (label 6); the box generates DMX timing.
/// - Open DMX USB: the computer generates each DMX packet: a break, a
///   mark-after-break, then the start code and channels at 250 kbaud, 8N2.
final class DMXSerialOutput: ObservableObject {
    @Published private(set) var devicePath: String?
    @Published private(set) var error: String?

    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var type: DMXInterfaceType = .enttecPro
    private var frame = [UInt8](repeating: 0, count: 512)
    private var frameChanged = true
    private var thread: Thread?

    deinit { close() }

    /// USB serial devices that could be DMX interfaces.
    static func availableDevices() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/dev")) ?? []
        return names
            .filter { $0.hasPrefix("cu.usbserial") }
            .sorted()
            .map { "/dev/\($0)" }
    }

    func open(path: String, type: DMXInterfaceType) {
        close()
        let fd = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            error = "Could not open \(path) (\(String(cString: strerror(errno))))."
            return
        }
        _ = fcntl(fd, F_SETFL, 0) // back to blocking writes

        var options = termios()
        tcgetattr(fd, &options)
        cfmakeraw(&options)
        options.c_cflag |= tcflag_t(CLOCAL | CREAD)
        options.c_cflag &= ~tcflag_t(PARENB | CSIZE)
        options.c_cflag |= tcflag_t(CS8)
        if type == .openDMX {
            options.c_cflag |= tcflag_t(CSTOPB) // two stop bits
        }
        cfsetspeed(&options, speed_t(B57600))
        tcsetattr(fd, TCSANOW, &options)

        if type == .openDMX {
            // 250 kbaud isn't a standard rate; set it with IOSSIOSPEED.
            var speed = speed_t(250_000)
            let iossiospeed: UInt = 0x8008_5402 // _IOW('T', 2, speed_t)
            if ioctl(fd, iossiospeed, &speed) != 0 {
                error = "Could not set 250 kbaud on \(path) (\(String(cString: strerror(errno))))."
                Darwin.close(fd)
                return
            }
        }

        lock.lock()
        descriptor = fd
        self.type = type
        frameChanged = true
        lock.unlock()
        devicePath = path
        error = nil

        let thread = Thread { [weak self] in self?.outputLoop() }
        thread.name = "DMX output"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    func close() {
        thread?.cancel()
        thread = nil
        lock.lock()
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
        lock.unlock()
        devicePath = nil
    }

    /// Sets the frame to send. Safe to call from any thread.
    func send(_ channels: [UInt8]) {
        lock.lock()
        if channels != frame {
            frame = channels
            frameChanged = true
        }
        lock.unlock()
    }

    // MARK: Output

    private func outputLoop() {
        var lastSend = 0.0
        while !Thread.current.isCancelled {
            lock.lock()
            let fd = descriptor
            let outputType = type
            let changed = frameChanged
            let channels = frame
            frameChanged = false
            lock.unlock()
            guard fd >= 0 else { return }

            let now = AppModel.now()
            var failed = false
            switch outputType {
            case .enttecPro:
                // The Pro keeps repeating the last frame, so only send changes
                // (and a refresh each second).
                if changed || now - lastSend > 1 {
                    failed = !write(fd, Self.proPacket(channels))
                    lastSend = now
                }
                usleep(10_000)
            case .openDMX:
                // Open DMX needs every packet sent continuously, ~30 per second.
                ioctl(fd, 0x2000_747B) // TIOCSBRK: start the break
                usleep(110)
                ioctl(fd, 0x2000_747A) // TIOCCBRK: mark after break
                usleep(16)
                failed = !write(fd, [0] + channels)
                tcdrain(fd)
                usleep(8_000)
            }
            if failed {
                let message = "DMX output stopped: \(String(cString: strerror(errno)))."
                DispatchQueue.main.async { [weak self] in
                    self?.error = message
                    self?.close()
                }
                return
            }
        }
    }

    private func write(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if written < 0 {
                if errno == EINTR { continue }
                return false
            }
            offset += written
        }
        return true
    }

    /// An Enttec Pro "Output Only Send DMX" message: start code 0 plus channels.
    static func proPacket(_ channels: [UInt8]) -> [UInt8] {
        let payload = [UInt8(0)] + channels
        let length = payload.count
        return [0x7E, 6, UInt8(length & 0xFF), UInt8(length >> 8)] + payload + [0xE7]
    }
}
