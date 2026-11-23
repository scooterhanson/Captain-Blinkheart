# Captain Blinkheart Pi
# Copyright (C) 2026 Josh Hanson
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Draws straight to the Linux framebuffer (/dev/fb0) and reads touches
straight from the touchscreen's input device.

This avoids SDL's KMS/EGL path, which opens without error on some Pi 3B+
set-ups yet leaves the screen black. The framebuffer is what the console
uses, so if boot text would show, this shows too."""

from __future__ import annotations

import fcntl
import glob
import logging
import mmap
import os
import struct
import threading
import time
from collections import deque
from pathlib import Path
from typing import Deque, List, Optional, Tuple

import pygame

log = logging.getLogger(__name__)

FB_DEVICE = "/dev/fb0"
KDSETMODE, KD_TEXT, KD_GRAPHICS = 0x4B3A, 0, 1


def available() -> bool:
    return Path(FB_DEVICE).exists()


def _sysfs(name: str) -> str:
    return Path(f"/sys/class/graphics/fb0/{name}").read_text().strip()


class Framebuffer:
    def __init__(self):
        try:
            width, height = (int(v) for v in _sysfs("virtual_size").split(","))
            bits = int(_sysfs("bits_per_pixel"))
            stride = int(_sysfs("stride"))
        except (OSError, ValueError) as error:
            raise pygame.error(f"Framebuffer not usable: {error}")
        if bits == 16:
            masks = (0xF800, 0x07E0, 0x001F, 0)
        elif bits == 32:
            masks = (0xFF0000, 0x00FF00, 0x0000FF, 0)
        else:
            raise pygame.error(f"Framebuffer uses {bits} bits per pixel, which isn't supported")
        self.size = (width, height)
        self.stride = stride
        self.surface = pygame.Surface(self.size, 0, bits, masks)
        try:
            self.fd = os.open(FB_DEVICE, os.O_RDWR)
        except OSError as error:
            raise pygame.error(f"Could not open {FB_DEVICE}: {error}")
        self.map = mmap.mmap(self.fd, stride * height, mmap.MAP_SHARED, mmap.PROT_WRITE | mmap.PROT_READ)
        self.tty = self._graphics_mode()
        log.info("Display: framebuffer %dx%d, %d bits", width, height, bits)

    @staticmethod
    def _graphics_mode() -> Optional[int]:
        """Stops the text console from drawing over the picture."""
        for path in ("/dev/tty1", "/dev/tty0"):
            try:
                fd = os.open(path, os.O_RDWR)
                fcntl.ioctl(fd, KDSETMODE, KD_GRAPHICS)
                return fd
            except OSError:
                continue
        return None

    def present(self) -> None:
        pitch = self.surface.get_pitch()
        data = self.surface.get_buffer().raw
        height = self.size[1]
        if pitch == self.stride:
            self.map[: pitch * height] = data[: pitch * height]
        else:
            row = min(pitch, self.stride)
            for y in range(height):
                self.map[y * self.stride: y * self.stride + row] = data[y * pitch: y * pitch + row]

    def close(self) -> None:
        if self.tty is not None:
            try:
                fcntl.ioctl(self.tty, KDSETMODE, KD_TEXT)
                os.close(self.tty)
            except OSError:
                pass
            self.tty = None
        try:
            self.map.close()
            os.close(self.fd)
        except (OSError, ValueError):
            pass


# Touch input (Linux evdev)

EV_SYN, EV_KEY, EV_ABS = 0, 1, 3
ABS_X, ABS_Y, ABS_MT_POSITION_X, ABS_MT_POSITION_Y, ABS_MT_TRACKING_ID = 0x00, 0x01, 0x35, 0x36, 0x39
BTN_TOUCH = 0x14A
EVENT = struct.Struct("LLHHi")  # struct input_event: time, type, code, value


def _abs_range(fd: int, axis: int) -> Optional[Tuple[int, int]]:
    """EVIOCGABS: the axis's minimum and maximum, or None if it has none."""
    request = 0x80184540 + axis  # _IOR('E', 0x40 + axis, struct input_absinfo)
    try:
        info = fcntl.ioctl(fd, request, bytes(24))
    except OSError:
        return None
    _value, low, high = struct.unpack("6i", info)[:3]
    return (low, high) if high > low else None


class TouchInput:
    """Turns touches into taps at screen coordinates."""

    def __init__(self, screen_size: Tuple[int, int]):
        self.screen_size = screen_size
        self.taps: Deque[Tuple[int, int]] = deque()
        self.running = True
        self.thread = threading.Thread(target=self._run, name="touch", daemon=True)
        self.thread.start()

    def take(self) -> List[Tuple[int, int]]:
        taps = []
        while self.taps:
            taps.append(self.taps.popleft())
        return taps

    def stop(self) -> None:
        self.running = False

    def _find(self):
        for path in sorted(glob.glob("/dev/input/event*")):
            try:
                fd = os.open(path, os.O_RDONLY)
            except OSError:
                continue
            for x_axis, y_axis in ((ABS_MT_POSITION_X, ABS_MT_POSITION_Y), (ABS_X, ABS_Y)):
                x_range, y_range = _abs_range(fd, x_axis), _abs_range(fd, y_axis)
                if x_range and y_range:
                    log.info("Touch input: %s", path)
                    return fd, x_axis, y_axis, x_range, y_range
            os.close(fd)
        return None

    def _run(self) -> None:
        while self.running:
            found = self._find()
            if not found:
                time.sleep(2)
                continue
            fd, x_axis, y_axis, x_range, y_range = found
            try:
                self._read(fd, x_axis, y_axis, x_range, y_range)
            except OSError:
                log.info("Touch input disconnected")
            finally:
                os.close(fd)

    def _read(self, fd, x_axis, y_axis, x_range, y_range) -> None:
        x = y = None
        touching = pending = False
        width, height = self.screen_size
        while self.running:
            data = os.read(fd, EVENT.size * 64)
            if not data:
                return
            for offset in range(0, len(data) - EVENT.size + 1, EVENT.size):
                _sec, _usec, kind, code, value = EVENT.unpack_from(data, offset)
                if kind == EV_ABS:
                    if code == x_axis:
                        x = value
                    elif code == y_axis:
                        y = value
                    elif code == ABS_MT_TRACKING_ID:
                        if value >= 0 and not touching:
                            touching = pending = True
                        elif value < 0:
                            touching = False
                elif kind == EV_KEY and code == BTN_TOUCH:
                    if value and not touching:
                        touching = pending = True
                    elif not value:
                        touching = False
                elif kind == EV_SYN and code == 0 and pending and x is not None and y is not None:
                    pending = False
                    sx = (x - x_range[0]) * (width - 1) / (x_range[1] - x_range[0])
                    sy = (y - y_range[0]) * (height - 1) / (y_range[1] - y_range[0])
                    self.taps.append((int(sx), int(sy)))
