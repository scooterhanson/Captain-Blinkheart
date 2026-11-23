# Captain Blinkheart Pi
# Copyright (C) 2026 Josh Hanson
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Finds a show on a USB stick and copies it into place.

Raspberry Pi OS Lite doesn't mount USB sticks by itself, so when running as
root this mounts new USB partitions read-only under /run/blinkheart.
"""

from __future__ import annotations

import glob
import logging
import os
import shutil
import subprocess
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Dict, List, Optional

from . import show as show_module

log = logging.getLogger(__name__)
MOUNT_ROOT = Path("/run/blinkheart")


@dataclass
class Candidate:
    path: Path          # the "blinkheart" folder on the stick
    name: str
    exported: str
    switches: int
    scenes: int
    mount: Optional[Path] = None  # set when we mounted it ourselves

    @property
    def on_sd_card(self) -> bool:
        return str(self.path).startswith("/boot")

    @property
    def key(self) -> str:
        return f"{self.path}|{self.exported}"


def inspect(folder: Path) -> Optional[Candidate]:
    try:
        data = show_module.read_manifest(folder)
    except show_module.ShowError:
        return None
    switches = data.get("switches", [])
    scenes = sum(len(list((folder / str(s.get("folder", ""))).glob("*.fseq"))) for s in switches)
    return Candidate(folder, str(data.get("name", "Show")), str(data.get("exported", "")), len(switches), scenes)


def mounted_roots() -> List[Path]:
    roots = []
    # The SD card's boot partition counts too, so a show can be copied onto
    # the card from a Mac or PC.
    for pattern in ("/boot/firmware", "/boot", "/media/*/*", "/media/*", "/run/media/*/*",
                    "/Volumes/*", f"{MOUNT_ROOT}/*"):
        roots.extend(Path(p) for p in glob.glob(pattern))
    return [r for r in roots if r.is_dir()]


def install(candidate: Candidate, home: Path) -> Path:
    """Copies the show next to the current one, checks it loads, then swaps it in."""
    home = Path(home)
    target = home / "show"
    incoming = home / "show.incoming"
    outgoing = home / "show.previous"
    shutil.rmtree(incoming, ignore_errors=True)
    shutil.copytree(candidate.path, incoming, ignore=shutil.ignore_patterns(".*"))
    show_module.load(incoming)  # raises ShowError if anything is wrong
    _sync()
    shutil.rmtree(outgoing, ignore_errors=True)
    if target.exists():
        os.replace(target, outgoing)
    os.replace(incoming, target)
    shutil.rmtree(outgoing, ignore_errors=True)
    _sync()
    return target


def _sync() -> None:
    if hasattr(os, "sync"):
        os.sync()


class USBWatcher(threading.Thread):
    """Polls for sticks with a show and reports new ones to `on_found`."""

    def __init__(self, on_found: Callable[[Candidate], None], on_removed: Callable[[], None]):
        super().__init__(name="usb-watcher", daemon=True)
        self.on_found = on_found
        self.on_removed = on_removed
        self.running = True
        self.reported: Dict[str, Candidate] = {}
        self.our_mounts: Dict[str, Path] = {}

    def run(self) -> None:
        while self.running:
            try:
                self._mount_new_partitions()
                found = {}
                for root in mounted_roots():
                    candidate = inspect(root / show_module.FOLDER)
                    if candidate:
                        candidate.mount = root if str(root).startswith(str(MOUNT_ROOT)) else None
                        found[candidate.key] = candidate
                for key, candidate in found.items():
                    if key not in self.reported:
                        log.info("Found show \"%s\" in %s: %d switches, %d scenes",
                                 candidate.name, candidate.path, candidate.switches, candidate.scenes)
                        self.on_found(candidate)
                if self.reported and not found:
                    self.on_removed()
                self.reported = found
                self._unmount_removed()
            except Exception as error:
                log.warning("USB scan failed: %s", error)
            time.sleep(2)

    def _mount_new_partitions(self) -> None:
        if os.name != "posix" or not hasattr(os, "geteuid") or os.geteuid() != 0:
            return
        for device in glob.glob("/dev/disk/by-id/usb-*"):
            real = os.path.realpath(device)
            if real in self.our_mounts or _is_mounted(real):
                continue
            if not device.split("-part")[-1].isdigit() and glob.glob(device + "-part*"):
                continue  # a whole disk with partitions: mount its partitions instead
            point = MOUNT_ROOT / f"usb-{os.path.basename(real)}"
            point.mkdir(parents=True, exist_ok=True)
            result = subprocess.run(["mount", "-o", "ro", real, str(point)], capture_output=True)
            if result.returncode == 0:
                self.our_mounts[real] = point
                log.info("Mounted %s at %s", real, point)
            else:
                point.rmdir()

    def _unmount_removed(self) -> None:
        for real, point in list(self.our_mounts.items()):
            if not os.path.exists(real):
                subprocess.run(["umount", "-l", str(point)], capture_output=True)
                try:
                    point.rmdir()
                except OSError:
                    pass
                del self.our_mounts[real]

    def release(self, candidate: Candidate) -> None:
        """Unmounts a stick we mounted, so it can be pulled out safely."""
        for real, point in list(self.our_mounts.items()):
            if candidate.mount and point == candidate.mount:
                subprocess.run(["umount", str(point)], capture_output=True)
                try:
                    point.rmdir()
                except OSError:
                    pass
                del self.our_mounts[real]

    def stop(self) -> None:
        self.running = False


def _is_mounted(device: str) -> bool:
    try:
        with open("/proc/mounts", encoding="utf-8") as mounts:
            return any(line.split()[0] == device for line in mounts)
    except OSError:
        return False
