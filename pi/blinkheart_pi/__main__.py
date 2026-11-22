# Captain Blinkheart Pi
# Copyright (C) 2026 Josh Hanson
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Run with: python3 -m blinkheart_pi"""

from __future__ import annotations

import argparse
import logging
import signal
import sys
import time
from pathlib import Path

from . import __version__
from . import settings as settings_module
from .app import App


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(prog="blinkheart_pi", description="Captain Blinkheart stage player")
    parser.add_argument("--home", type=Path, help="data folder (default /var/lib/blinkheart)")
    parser.add_argument("--no-ui", action="store_true", help="run without the touchscreen")
    parser.add_argument("--windowed", action="store_true", help="show the screen in a window (for testing)")
    parser.add_argument("--size", help="window size, e.g. 1280x400")
    parser.add_argument("--null-dmx", action="store_true", help="don't send DMX (for testing)")
    parser.add_argument("--no-midi", action="store_true")
    parser.add_argument("--no-usb", action="store_true")
    parser.add_argument("--version", action="version", version=__version__)
    args = parser.parse_args(argv)

    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    home = args.home or settings_module.home()
    app = App(home, dmx="null" if args.null_dmx else "serial", midi=not args.no_midi, usb=not args.no_usb)
    app.start()

    stopping = []
    signal.signal(signal.SIGTERM, lambda *_: stopping.append(True))
    try:
        if args.no_ui:
            while not stopping:
                time.sleep(0.2)
        else:
            import pygame
            from .ui import Screen

            size = tuple(int(v) for v in args.size.split("x")) if args.size else None
            screen = Screen(app, size=size, rotate=app.settings.rotate, fullscreen=not args.windowed)
            clock = pygame.time.Clock()
            while not stopping:
                for event in pygame.event.get():
                    if not screen.handle(event):
                        stopping.append(True)
                screen.draw()
                clock.tick(20)
    except KeyboardInterrupt:
        pass
    finally:
        app.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
