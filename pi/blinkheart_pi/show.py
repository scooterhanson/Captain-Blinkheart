# Captain Blinkheart Pi
# Copyright (C) 2026 Josh Hanson
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Loads a show folder: show.json plus one folder of .fseq scenes per switch.

The scene files in each folder are what play, so scenes can be added or
removed by copying files; show.json supplies the switch labels, MIDI, and fades.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import List, Optional

from . import fseq
from .rules import MIDIMessage, Rule

FORMAT = "captain-blinkheart-show"
MANIFEST = "show.json"
FOLDER = "blinkheart"

ACTION_COLORS = {
    "reset": (235, 235, 235),
    "baseline": (176, 92, 255),
    "low": (60, 200, 90),
    "medium": (245, 205, 40),
    "high": (255, 140, 30),
    "critical": (240, 50, 50),
}
ACTION_NAMES = {
    "reset": "Reset", "baseline": "Intro", "low": "Low",
    "medium": "Medium", "high": "High", "critical": "Frenzy",
}


class ShowError(ValueError):
    pass


@dataclass
class Scene:
    name: str
    path: Path
    frames: List[bytes]
    step_ms: int

    @property
    def duration(self) -> float:
        return len(self.frames) * self.step_ms / 1000


@dataclass
class Switch:
    number: int
    label: str
    action: str
    folder: str
    mode: str
    fade: float
    midi: List[MIDIMessage]
    scenes: List[Scene] = field(default_factory=list)

    @property
    def color(self):
        return ACTION_COLORS.get(self.action, (160, 160, 160))


@dataclass
class Show:
    name: str
    exported: str
    channels: int
    default_fade: float
    sequence_timeout: float
    switches: List[Switch]
    path: Path

    @property
    def scene_count(self) -> int:
        return sum(len(s.scenes) for s in self.switches)

    @property
    def rules(self) -> List[Rule]:
        return [Rule(s.number, s.midi) for s in self.switches]

    def switch(self, number: int) -> Optional[Switch]:
        return next((s for s in self.switches if s.number == number), None)


def _natural_key(path: Path):
    return [int(part) if part.isdigit() else part.lower() for part in re.split(r"(\d+)", path.stem)]


def read_manifest(show_dir: Path) -> dict:
    path = Path(show_dir) / MANIFEST
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise ShowError(f"{path} is missing") from None
    except (OSError, ValueError) as error:
        raise ShowError(f"{path} could not be read: {error}") from None
    if data.get("format") != FORMAT:
        raise ShowError(f"{path} is not a Captain Blinkheart show")
    if int(data.get("version", 0)) > 1:
        raise ShowError("this show was exported by a newer Captain Blinkheart; update the Pi")
    return data


def load(show_dir: Path, channels: int = 512) -> Show:
    show_dir = Path(show_dir)
    data = read_manifest(show_dir)
    default_fade = float(data.get("defaultFade", 1.0))
    switches = []
    for item in data.get("switches", []):
        folder = show_dir / str(item["folder"])
        scenes = []
        if folder.is_dir():
            for file in sorted(folder.glob("*.fseq"), key=_natural_key):
                if file.name.startswith("."):
                    continue
                try:
                    sequence = fseq.read(file)
                except (OSError, fseq.FSEQError) as error:
                    raise ShowError(f"{item['folder']}/{file.name}: {error}") from None
                frames = [frame[:channels].ljust(channels, b"\x00") for frame in sequence.frames]
                scenes.append(Scene(file.stem, file, frames, sequence.step_ms))
        switches.append(Switch(
            number=int(item["number"]),
            label=str(item.get("label") or ACTION_NAMES.get(item.get("action", ""), "Switch")),
            action=str(item.get("action", "")),
            folder=str(item["folder"]),
            mode=str(item.get("mode", "random")),
            fade=float(item.get("fade", default_fade)),
            midi=[MIDIMessage.from_json(m) for m in item.get("midi", [])],
            scenes=scenes,
        ))
    if not switches:
        raise ShowError("the show has no switches")
    return Show(
        name=str(data.get("name", "Show")),
        exported=str(data.get("exported", "")),
        channels=channels,
        default_fade=default_fade,
        sequence_timeout=float(data.get("sequenceTimeout", 1.5)),
        switches=sorted(switches, key=lambda s: s.number),
        path=show_dir,
    )
