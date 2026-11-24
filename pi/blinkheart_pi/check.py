# Captain Blinkheart Pi
# Copyright (C) 2026 Josh Hanson
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Checks for when the lights don't respond.

    sudo python3 -m blinkheart_pi.check show   what the installed scenes contain
    sudo python3 -m blinkheart_pi.check dmx    talk to the DMX box and flash every channel

`dmx` stops the player while it runs and starts it again afterwards."""

from __future__ import annotations

import argparse
import subprocess
import sys
import time
from pathlib import Path

from . import settings as settings_module
from . import show as show_module
from .dmx import find_devices, pro_packet


def check_show(home: Path) -> int:
    folder = home / "show"
    try:
        show = show_module.load(folder)
    except show_module.ShowError as error:
        print(f"No usable show in {folder}: {error}")
        return 1
    print(f"Show \"{show.name}\", exported {show.exported}, {show.scene_count} scenes")
    any_light = False
    for switch in show.switches:
        print(f"\nSwitch {switch.number} ({switch.label or switch.action}), fade {switch.fade:.1f} s:")
        for scene in switch.scenes[:8]:
            frames = scene.frames
            used = sorted({ch + 1 for f in frames for ch, v in enumerate(f) if v})
            peak = max((max(f) for f in frames), default=0)
            any_light |= peak > 0
            span = f"channels {used[0]}–{used[-1]} ({len(used)} in use)" if used else "ALL CHANNELS ZERO"
            print(f"  {scene.name}: {len(frames)} frames, {span}, highest level {peak}")
        if len(switch.scenes) > 8:
            print(f"  … and {len(switch.scenes) - 8} more")
    if not any_light:
        print("\nEvery scene checked is dark: the export recorded no light levels. "
              "Check that Show Buddy's lights were visibly working during the export.")
    return 0


def check_dmx(device: str) -> int:
    import serial

    paths = find_devices() if device == "auto" else [device]
    if not paths:
        print("No USB serial device found. Is the DMX box plugged in? (ls /dev/serial/by-id)")
        return 1
    path = paths[0]
    print(f"DMX box: {path}")
    port = serial.Serial(path, baudrate=250000, bytesize=8, parity="N", stopbits=2, timeout=0.5, write_timeout=1)
    port.reset_input_buffer()

    def ask(label: int, data: bytes = b"") -> bytes:
        port.write(bytes([0x7E, label, len(data) & 0xFF, len(data) >> 8]) + data + b"\xE7")
        port.flush()
        return port.read(64)

    params = ask(3, b"\x00\x00")
    if len(params) >= 9 and params[0] == 0x7E and params[1] == 3:
        firmware = params[5] << 8 | params[4]
        print(f"Enttec Pro answered: firmware {firmware >> 8}.{firmware & 0xFF}, "
              f"break {params[6] * 10.67:.0f} µs, mark-after-break {params[7] * 10.67:.0f} µs, "
              f"{params[8]} packets/s")
    else:
        print(f"No answer to the Pro's parameter request (got {params.hex() or 'nothing'}). "
              "If this is an Open DMX box, set \"dmx_type\": \"open\".")
    serial_reply = ask(10)
    if len(serial_reply) >= 9 and serial_reply[1] == 10:
        print("Serial number:", serial_reply[4:8][::-1].hex())

    def hold(level: int, seconds: float, label: str) -> None:
        print(label)
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            port.write(pro_packet(bytes([level]) * 512))
            time.sleep(0.05)

    try:
        for _ in range(2):
            hold(255, 3, "All 512 channels at FULL for 3 s: every light should come on")
            hold(0, 1.5, "All channels off")
        print("Done. If nothing lit up: check the DMX cable from the box's OUT socket to the "
              "first light, the lights' DMX addresses and modes, and any terminator.")
    finally:
        port.write(pro_packet(bytes(512)))
        port.close()
    return 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="blinkheart_pi.check")
    parser.add_argument("what", choices=["show", "dmx"])
    parser.add_argument("--home", type=Path)
    args = parser.parse_args(argv)
    home = args.home or settings_module.home()
    if args.what == "show":
        return check_show(home)
    settings = settings_module.load(home)
    stopped = subprocess.run(["systemctl", "is-active", "--quiet", "blinkheart"]).returncode == 0
    if stopped:
        print("Stopping the player while testing…")
        subprocess.run(["systemctl", "stop", "blinkheart"])
    try:
        return check_dmx(settings.dmx_device)
    finally:
        if stopped:
            subprocess.run(["systemctl", "start", "blinkheart"])
            print("Player started again.")


if __name__ == "__main__":
    sys.exit(main())
