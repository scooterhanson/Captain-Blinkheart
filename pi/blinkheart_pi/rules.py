# Captain Blinkheart Pi
# Copyright (C) 2026 Josh Hanson
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Matches incoming MIDI to pedal switches, like the Mac app's MIDIRuleMatcher."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Dict, List, Optional, Sequence


@dataclass(frozen=True)
class MIDIMessage:
    kind: str  # "noteOn", "noteOff" or "controlChange"
    channel: int  # 1-16
    number: int
    value: int

    @classmethod
    def from_json(cls, data: dict) -> "MIDIMessage":
        return cls(str(data["kind"]), int(data["channel"]), int(data["number"]), int(data["value"]))

    def __str__(self) -> str:
        names = {"noteOn": "Note On", "noteOff": "Note Off", "controlChange": "CC"}
        return f"{names.get(self.kind, self.kind)} {self.number}={self.value} ch {self.channel}"


def decode(raw: Sequence[int]) -> Optional[MIDIMessage]:
    """Decodes a MIDI 1.0 channel message into the app's message kinds."""
    if len(raw) < 3:
        return None
    status, data1, data2 = raw[0], raw[1], raw[2]
    kind_bits, channel = status & 0xF0, (status & 0x0F) + 1
    if kind_bits == 0x90:
        return MIDIMessage("noteOn" if data2 > 0 else "noteOff", channel, data1, data2)
    if kind_bits == 0x80:
        return MIDIMessage("noteOff", channel, data1, data2)
    if kind_bits == 0xB0:
        return MIDIMessage("controlChange", channel, data1, data2)
    return None


@dataclass
class Rule:
    switch: int
    messages: List[MIDIMessage]


class RuleMatcher:
    """Fires a rule when its messages arrive in order within the timeout."""

    def __init__(self, timeout: float = 1.5):
        self.timeout = timeout
        self.progress: Dict[int, int] = {}
        self.last_match: Dict[int, float] = {}

    def receive(self, message: MIDIMessage, rules: List[Rule], now: float) -> Optional[Rule]:
        for rule in rules:
            if not rule.messages:
                continue
            index = self.progress.get(rule.switch, 0)
            last = self.last_match.get(rule.switch)
            if last is not None and now - last > self.timeout:
                index = 0
            if index >= len(rule.messages):
                index = 0
            if rule.messages[index] == message:
                index += 1
                if index == len(rule.messages):
                    self.progress[rule.switch] = 0
                    self.last_match[rule.switch] = now
                    return rule
                self.progress[rule.switch] = index
                self.last_match[rule.switch] = now
            elif rule.messages[0] == message:
                self.progress[rule.switch] = 1
                self.last_match[rule.switch] = now
                if len(rule.messages) == 1:
                    return rule
            else:
                self.progress[rule.switch] = 0
        return None
