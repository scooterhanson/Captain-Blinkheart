# Captain Blinkheart Pi
# Copyright (C) 2026 Josh Hanson
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Listens to USB MIDI devices (the MIDI Captain) and presses switches."""

from __future__ import annotations

import logging
import threading
import time
from typing import Callable, Dict, List

from .rules import MIDIMessage, Rule, RuleMatcher, decode

log = logging.getLogger(__name__)


class MIDIInput(threading.Thread):
    """Opens every MIDI input (optionally filtered by name) and rescans for hot-plugging."""

    def __init__(self, on_switch: Callable[[int], None], rules: Callable[[], List[Rule]],
                 timeout: Callable[[], float], name_filter: str = ""):
        super().__init__(name="midi-input", daemon=True)
        self.on_switch = on_switch
        self.rules = rules
        self.timeout = timeout
        self.name_filter = name_filter.lower()
        self.matcher = RuleMatcher()
        self.ports: Dict[str, object] = {}
        self.lock = threading.Lock()
        self.running = True
        self.available = True
        self.last_message: str = ""

    @property
    def port_names(self) -> List[str]:
        return list(self.ports)

    def run(self) -> None:
        try:
            import rtmidi  # python-rtmidi
        except ImportError:
            log.warning("python-rtmidi is not installed; MIDI input is off")
            self.available = False
            return
        while self.running:
            try:
                probe = rtmidi.MidiIn()
                names = probe.get_ports()
                probe.delete() if hasattr(probe, "delete") else None
                wanted = [n for n in names if "through" not in n.lower() and "midi through" not in n.lower()
                          and (not self.name_filter or self.name_filter in n.lower())]
                for name in wanted:
                    if name not in self.ports:
                        self._open(rtmidi, names.index(name), name)
                for name in list(self.ports):
                    if name not in names:
                        log.info("MIDI input removed: %s", name)
                        port = self.ports.pop(name)
                        try:
                            port.close_port()
                        except Exception:
                            pass
            except Exception as error:
                log.warning("MIDI scan failed: %s", error)
            time.sleep(2)

    def _open(self, rtmidi, index: int, name: str) -> None:
        try:
            port = rtmidi.MidiIn()
            port.open_port(index)
            port.ignore_types(sysex=True, timing=True, active_sense=True)
            port.set_callback(lambda event, data=None: self.receive(event[0]))
            self.ports[name] = port
            log.info("MIDI input: %s", name)
        except Exception as error:
            log.warning("Could not open MIDI input %s: %s", name, error)

    def receive(self, raw) -> None:
        message = decode(raw)
        if message is None:
            return
        self.last_message = str(message)
        with self.lock:
            self.matcher.timeout = self.timeout()
            rule = self.matcher.receive(message, self.rules(), time.monotonic())
        if rule is not None:
            self.on_switch(rule.switch)

    def stop(self) -> None:
        self.running = False
