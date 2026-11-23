# Captain Blinkheart Pi
# Copyright (C) 2026 Josh Hanson
# SPDX-License-Identifier: AGPL-3.0-or-later
"""DMX output through an Enttec DMX USB Pro or Open DMX USB.

The port reconnects by itself if the box is unplugged and plugged back in.
"""

from __future__ import annotations

import glob
import logging
import os
import threading
import time
from typing import Optional

log = logging.getLogger(__name__)


def pro_packet(frame: bytes) -> bytes:
    """An Enttec Pro "Output Only Send DMX" message (label 6): start code 0 + channels."""
    payload = b"\x00" + frame
    return bytes([0x7E, 6, len(payload) & 0xFF, len(payload) >> 8]) + payload + b"\xE7"


def find_devices() -> list:
    """USB serial devices that could be DMX interfaces, most likely first."""
    by_id = sorted(glob.glob("/dev/serial/by-id/*"))
    likely = [p for p in by_id if any(k in p.lower() for k in ("enttec", "ftdi", "dmx"))]
    others = [p for p in by_id if p not in likely]
    plain = sorted(glob.glob("/dev/ttyUSB*")) + sorted(glob.glob("/dev/cu.usbserial*"))
    seen, result = set(), []
    for path in likely + others + plain:
        real = os.path.realpath(path)
        if real not in seen:
            seen.add(real)
            result.append(path)
    return result


class NullOutput:
    """Keeps the last frame; used when no box is connected and for tests."""

    name = "No DMX output"
    connected = False

    def __init__(self):
        self.last: Optional[bytes] = None
        self.count = 0

    def send(self, frame: bytes) -> None:
        self.last = frame
        self.count += 1

    def close(self) -> None:
        pass


class SerialDMX:
    """Drives an Enttec box. `kind` is "pro", "open", or "auto"."""

    def __init__(self, device: str = "auto", kind: str = "auto"):
        self.device_setting = device
        self.kind_setting = kind
        self.kind: Optional[str] = None
        self.port = None
        self.path: Optional[str] = None
        self.last_frame: Optional[bytes] = None
        self.last_write = 0.0
        self.next_attempt = 0.0
        self.error: Optional[str] = None
        self.lock = threading.Lock()
        self.timeouts = 0

    @property
    def connected(self) -> bool:
        return self.port is not None

    @property
    def name(self) -> str:
        if not self.connected:
            return "DMX box not found" if not self.error else f"DMX: {self.error}"
        return {"pro": "DMX USB Pro", "open": "Open DMX USB"}.get(self.kind, "DMX")

    def _open(self) -> None:
        import serial  # pyserial

        candidates = find_devices() if self.device_setting == "auto" else [self.device_setting]
        for path in candidates:
            try:
                port = serial.Serial(path, baudrate=250000, bytesize=8, parity="N", stopbits=2,
                                     timeout=0.3, write_timeout=1)
            except (OSError, serial.SerialException) as error:
                self.error = str(error)
                continue
            kind = self.kind_setting if self.kind_setting in ("pro", "open") else self._detect(port)
            self.port, self.path, self.kind, self.error = port, path, kind, None
            self.last_frame = None
            log.info("DMX output on %s (%s)", path, self.name)
            return
        if not candidates:
            self.error = None

    @staticmethod
    def _detect(port) -> str:
        """Asks for the Pro's widget parameters (label 3); an Open DMX box doesn't answer."""
        try:
            port.reset_input_buffer()
            port.write(bytes([0x7E, 3, 2, 0, 0, 0, 0xE7]))
            reply = port.read(5)
            return "pro" if len(reply) >= 2 and reply[0] == 0x7E and reply[1] == 3 else "open"
        except Exception:
            return "open"

    def send(self, frame: bytes) -> None:
        with self.lock:
            now = time.monotonic()
            if self.port is None:
                if now < self.next_attempt:
                    return
                self.next_attempt = now + 2
                self._open()
                if self.port is None:
                    return
            try:
                if self.kind == "pro":
                    # The Pro repeats the last frame by itself: send changes,
                    # plus a refresh each second.
                    if frame != self.last_frame or now - self.last_write > 1:
                        self.port.write(pro_packet(frame))
                        self.last_write = now
                else:
                    self.port.break_condition = True
                    time.sleep(0.00011)
                    self.port.break_condition = False
                    time.sleep(0.000016)
                    self.port.write(b"\x00" + frame)
                    self.port.flush()
                self.last_frame = frame
                self.timeouts = 0
            except Exception as error:  # unplugged, or USB briefly stalled
                if "timeout" in str(error).lower() and self.timeouts < 3:
                    self.timeouts += 1
                    return  # the Pro keeps showing the last frame; try again next frame
                log.warning("DMX output lost: %s", error)
                self.error = "disconnected"
                self.close()

    def close(self) -> None:
        if self.port is not None:
            try:
                self.port.close()
            except Exception:
                pass
        self.port = None
