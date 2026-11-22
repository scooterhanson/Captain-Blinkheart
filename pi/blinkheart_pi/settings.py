# Captain Blinkheart Pi
# Copyright (C) 2026 Josh Hanson
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Pi-only settings, kept apart from the show so importing a show never changes them."""

from __future__ import annotations

import json
import os
from dataclasses import asdict, dataclass, fields
from pathlib import Path

# On the boot partition, so it stays writable with the read-only system on
# and a Mac or PC can open it from the SD card.
BOOT_HOMES = (Path("/boot/firmware/blinkheart-pi"), Path("/boot/blinkheart-pi"))
DEFAULT_HOME = Path("/var/lib/blinkheart")


@dataclass
class Settings:
    dmx_device: str = "auto"      # a serial path, or "auto"
    dmx_type: str = "auto"        # "pro", "open", or "auto"
    midi_filter: str = ""         # only open MIDI inputs whose name contains this
    rotate: str = "auto"          # "auto", "0", "90", "180", "270"
    startup_switch: int = 0       # switch to press at startup (0 = stay dark)


def home() -> Path:
    configured = os.environ.get("BLINKHEART_HOME")
    if configured:
        return Path(configured)
    for candidate in BOOT_HOMES:
        if candidate.exists():
            return candidate
    if os.access(DEFAULT_HOME.parent, os.W_OK) or DEFAULT_HOME.exists():
        return DEFAULT_HOME
    return Path.home() / ".blinkheart"


def load(directory: Path) -> Settings:
    path = Path(directory) / "settings.json"
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return Settings()
    known = {f.name for f in fields(Settings)}
    return Settings(**{k: v for k, v in data.items() if k in known})


def ensure(directory: Path) -> Settings:
    """Loads the settings, writing a default file first if there isn't one."""
    if not (Path(directory) / "settings.json").exists():
        try:
            save(directory, Settings())
        except OSError:
            pass
    return load(directory)


def save(directory: Path, settings: Settings) -> None:
    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    temporary = directory / "settings.json.tmp"
    temporary.write_text(json.dumps(asdict(settings), indent=2), encoding="utf-8")
    os.replace(temporary, directory / "settings.json")
