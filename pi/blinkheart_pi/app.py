# Captain Blinkheart Pi
# Copyright (C) 2026 Josh Hanson
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Wires the show, engine, DMX output, MIDI input, USB import, and screen together."""

from __future__ import annotations

import logging
import threading
import time
from pathlib import Path
from typing import List, Optional

from . import settings as settings_module
from . import show as show_module
from . import usb_import
from .dmx import NullOutput, SerialDMX
from .engine import Engine, OutputLoop
from .midi_input import MIDIInput

log = logging.getLogger(__name__)


class App:
    def __init__(self, home: Path, dmx: str = "serial", midi: bool = True, usb: bool = True):
        self.home = Path(home)
        self.home.mkdir(parents=True, exist_ok=True)
        self.settings = settings_module.ensure(self.home)
        self.engine = Engine()
        self.output = NullOutput() if dmx == "null" else SerialDMX(self.settings.dmx_device, self.settings.dmx_type)
        self.output_loop = OutputLoop(self.engine, self.output)
        self.midi: Optional[MIDIInput] = None
        if midi:
            self.midi = MIDIInput(
                on_switch=lambda n: self.press(n, source="pedal"),
                rules=lambda: self.engine.show.rules if self.engine.show else [],
                timeout=lambda: self.engine.show.sequence_timeout if self.engine.show else 1.5,
                name_filter=self.settings.midi_filter,
            )
        self.usb = usb_import.USBWatcher(self._found_show, self._stick_removed) if usb else None
        self.pending_import: Optional[usb_import.Candidate] = None
        self.dismissed: set = set()
        self.message = ""
        self.message_until = 0.0
        self.lock = threading.Lock()

    # Lifecycle

    def start(self) -> None:
        self.load_installed_show()
        self.output_loop.start()
        if self.midi:
            self.midi.start()
        if self.usb:
            self.usb.start()
        if self.settings.startup_switch and self.engine.show:
            self.press(self.settings.startup_switch, source="startup")

    def stop(self) -> None:
        if self.usb:
            self.usb.stop()
        if self.midi:
            self.midi.stop()
        self.engine.blackout_now()
        time.sleep(0.1)
        self.output_loop.stop()
        self.output.close()

    def load_installed_show(self) -> None:
        folder = self.home / "show"
        if not (folder / show_module.MANIFEST).exists():
            log.info("No show installed in %s", folder)
            return
        try:
            show = show_module.load(folder)
        except show_module.ShowError as error:
            self.notify(f"Show could not load: {error}", 15)
            log.error("Show could not load: %s", error)
            return
        self.engine.load(show)
        log.info("Loaded show %s: %d switches, %d scenes", show.name, len(show.switches), show.scene_count)

    # Switches

    def press(self, number: int, source: str = "") -> None:
        scene = self.engine.press(number)
        switch = self.engine.show.switch(number) if self.engine.show else None
        if switch is None:
            return
        if scene is None and switch.action != "reset":
            self.notify(f"{switch.label}: no scenes in {switch.folder}")
        log.info("%s %d (%s): %s", source or "switch", number, switch.label, scene.name if scene else "blackout")

    # USB import

    def _found_show(self, candidate: usb_import.Candidate) -> None:
        show = self.engine.show
        if show and show.exported == candidate.exported and show.name == candidate.name:
            if not candidate.on_sd_card:
                self.notify("This show is already loaded")
            return
        if candidate.key in self.dismissed:
            return
        if show is None and not candidate.on_sd_card:
            # Nothing to replace, so there's no need to ask: load it.
            log.info("No show installed yet, so loading \"%s\" from the stick", candidate.name)
            self.pending_import = candidate
            self.accept_import()
            return
        self.pending_import = candidate

    def _stick_removed(self) -> None:
        self.pending_import = None
        self.dismissed.clear()

    def accept_import(self) -> None:
        candidate = self.pending_import
        if candidate is None:
            return
        self.pending_import = None
        self.notify("Loading show…", 30)
        threading.Thread(target=self._install, args=(candidate,), daemon=True).start()

    def _install(self, candidate) -> None:
        try:
            usb_import.install(candidate, self.home)
            self.load_installed_show()
            if self.usb:
                self.usb.release(candidate)
            log.info("Loaded \"%s\" from the stick; it can be removed", candidate.name)
            self.notify(f"Loaded \"{candidate.name}\" · you can remove the stick", 6)
        except Exception as error:
            log.exception("Import failed")
            self.notify(f"Import failed: {error}", 12)

    def dismiss_import(self) -> None:
        if self.pending_import:
            self.dismissed.add(self.pending_import.key)
        self.pending_import = None

    # Status

    def notify(self, message: str, seconds: float = 4) -> None:
        self.message = message
        self.message_until = time.monotonic() + seconds

    def status_items(self) -> List[str]:
        items = [self.output.name]
        if self.midi is not None:
            if not self.midi.available:
                items.append("MIDI unavailable")
            elif self.midi.port_names:
                items.append("MIDI: " + ", ".join(n.split(":")[0] for n in self.midi.port_names))
            else:
                items.append("No MIDI input")
        return items
