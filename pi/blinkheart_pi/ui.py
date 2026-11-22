# Captain Blinkheart Pi
# Copyright (C) 2026 Josh Hanson
# SPDX-License-Identifier: AGPL-3.0-or-later
"""The touchscreen: one tile per switch, lined up with the footswitches, plus
the current scene in large type. Tapping a tile presses that switch."""

from __future__ import annotations

import time
from datetime import datetime
from typing import Callable, List, Optional, Tuple

import pygame

from .show import ACTION_NAMES

BLACK = (0, 0, 0)
WHITE = (240, 240, 240)
GRAY = (120, 120, 120)
DARK = (28, 28, 30)
GREEN = (60, 200, 90)
ORANGE = (255, 150, 40)


def title(switch) -> str:
    """The action's name (LOW, HIGH…); a custom key label is shown as well."""
    return ACTION_NAMES.get(switch.action) or switch.label or f"Switch {switch.number}"


def subtitle(switch) -> str:
    label = switch.label.strip()
    generic = not label or label.lower().startswith(("button", "key ", "switch"))
    return "" if generic or label.lower() == title(switch).lower() else label


def local_time(iso: str) -> str:
    """Formats the export's UTC timestamp in the Pi's local time."""
    try:
        moment = datetime.fromisoformat(iso.replace("Z", "+00:00")).astimezone()
        return moment.strftime("%b %d, %H:%M")
    except ValueError:
        return iso[:16].replace("T", " ")


def dim(color, amount=0.28):
    return tuple(int(c * amount) for c in color)


class Screen:
    def __init__(self, app, size: Optional[Tuple[int, int]] = None, rotate: str = "auto",
                 fullscreen: bool = True):
        self.app = app
        pygame.display.init()
        pygame.font.init()
        if fullscreen:
            info = pygame.display.Info()
            native = (info.current_w, info.current_h)
            self.window = pygame.display.set_mode(size or native, pygame.FULLSCREEN)
            pygame.mouse.set_visible(False)
        else:
            self.window = pygame.display.set_mode(size or (1280, 400))
        pygame.display.set_caption("Captain Blinkheart")
        width, height = self.window.get_size()
        if rotate == "auto":
            rotate = "90" if height > width else "0"
        self.rotation = int(rotate) % 360
        logical = (height, width) if self.rotation in (90, 270) else (width, height)
        self.canvas = pygame.Surface(logical)
        self.width, self.height = logical
        self.tiles: List[Tuple[pygame.Rect, int]] = []
        self.buttons: List[Tuple[pygame.Rect, Callable[[], None]]] = []
        self.fonts = {}

    def font(self, size: int, bold: bool = True):
        key = (size, bold)
        if key not in self.fonts:
            self.fonts[key] = pygame.font.SysFont("dejavusans,helvetica,arial", size, bold=bold)
        return self.fonts[key]

    # Input

    def to_logical(self, x: float, y: float) -> Tuple[int, int]:
        w, h = self.window.get_size()
        if self.rotation == 90:
            return int(y), int(w - x)
        if self.rotation == 180:
            return int(w - x), int(h - y)
        if self.rotation == 270:
            return int(h - y), int(x)
        return int(x), int(y)

    def handle(self, event) -> bool:
        """Returns False to quit."""
        if event.type == pygame.QUIT:
            return False
        point = None
        if event.type == pygame.MOUSEBUTTONDOWN:
            point = self.to_logical(*event.pos)
        elif event.type == pygame.FINGERDOWN:
            w, h = self.window.get_size()
            point = self.to_logical(event.x * w, event.y * h)
        elif event.type == pygame.KEYDOWN:
            if event.key == pygame.K_ESCAPE:
                return False
            if pygame.K_1 <= event.key <= pygame.K_9:
                self.app.press(event.key - pygame.K_0, source="keyboard")
            elif event.key == pygame.K_b:
                self.app.engine.blackout_now()
        if point:
            for rect, action in self.buttons:
                if rect.collidepoint(point):
                    action()
                    return True
            for rect, number in self.tiles:
                if rect.collidepoint(point):
                    self.app.press(number, source="touch")
                    break
        return True

    # Drawing

    def draw(self) -> None:
        c = self.canvas
        c.fill(BLACK)
        self.tiles, self.buttons = [], []
        w, h = self.width, self.height
        pad = max(6, h // 40)
        tile_h = int(h * 0.36)
        top_h = h - tile_h - pad * 3

        show = self.app.engine.show
        state = self.app.engine.state()

        # Status line
        small = self.font(max(14, h // 22), bold=False)
        left = show.name if show else "No show loaded"
        self.text(left, (pad * 2, pad), small, GRAY)
        status = "   ".join(self.app.status_items())
        surface = small.render(status, True, GRAY)
        c.blit(surface, (w - surface.get_width() - pad * 2, pad))

        # Current scene
        if state.switch is not None:
            group = title(state.switch).upper()
            color = state.switch.color
            name = state.scene.name if state.scene else "Blackout"
        elif show is None:
            group, color, name = "READY", GRAY, "Copy a show to a USB stick and plug it in"
        else:
            group, color, name = "READY", GRAY, "Press a switch"
        big = self.fit(group, int(top_h * 0.55), w // 2 - pad * 3)
        y = pad * 2 + small.get_height()
        c.blit(big.render(group, True, color), (pad * 2, y))
        detail = self.fit(name, int(top_h * 0.3), w // 2 - pad * 2, bold=False)
        surface = detail.render(name, True, WHITE)
        c.blit(surface, (w - surface.get_width() - pad * 2, y + (big.get_height() - surface.get_height())))
        if state.fade_progress < 1:
            bar = pygame.Rect(pad * 2, top_h + pad, int((w - pad * 4) * state.fade_progress), max(4, h // 80))
            pygame.draw.rect(c, color, bar)

        # Tiles
        switches = show.switches if show else []
        count = max(len(switches), 1)
        tile_w = (w - pad * (count + 1)) // count
        y = h - tile_h - pad
        for index, switch in enumerate(switches):
            rect = pygame.Rect(pad + index * (tile_w + pad), y, tile_w, tile_h)
            active = state.switch is not None and state.switch.number == switch.number
            pygame.draw.rect(c, switch.color if active else dim(switch.color), rect, border_radius=pad * 2)
            if active:
                pygame.draw.rect(c, WHITE, rect, width=max(3, h // 100), border_radius=pad * 2)
            label = title(switch).upper()
            font = self.fit(label, int(tile_h * 0.32), tile_w - pad * 2)
            text = font.render(label, True, BLACK if active else switch.color)
            c.blit(text, text.get_rect(center=(rect.centerx, rect.centery - tile_h * 0.1)))
            extra = subtitle(switch)
            info = f"{switch.number} · {extra}" if extra else f"{switch.number} · {len(switch.scenes)} scene{'' if len(switch.scenes) == 1 else 's'}"
            note = self.font(max(12, tile_h // 8), bold=False).render(info, True, BLACK if active else GRAY)
            c.blit(note, note.get_rect(center=(rect.centerx, rect.bottom - tile_h * 0.18)))
            self.tiles.append((rect, switch.number))

        if self.app.pending_import is not None:
            self.import_dialog()
        elif self.app.message and time.monotonic() < self.app.message_until:
            self.banner(self.app.message)

        self.present()

    def import_dialog(self) -> None:
        candidate = self.app.pending_import
        c, w, h = self.canvas, self.width, self.height
        overlay = pygame.Surface((w, h), pygame.SRCALPHA)
        overlay.fill((0, 0, 0, 215))
        c.blit(overlay, (0, 0))
        title = self.fit(f"Load show \"{candidate.name}\"?", h // 7, w - 40)
        c.blit(title.render(f"Load show \"{candidate.name}\"?", True, WHITE), (24, h // 10))
        detail = f"{candidate.switches} switches · {candidate.scenes} scenes · exported {local_time(candidate.exported)}"
        c.blit(self.font(h // 14, bold=False).render(detail, True, GRAY), (24, h // 10 + h // 6))
        bw, bh = w // 4, h // 4
        load = pygame.Rect(w - bw * 2 - 48, h - bh - 24, bw, bh)
        cancel = pygame.Rect(w - bw - 24, h - bh - 24, bw, bh)
        for rect, text, color, action in ((load, "Load", GREEN, self.app.accept_import),
                                          (cancel, "Not now", GRAY, self.app.dismiss_import)):
            pygame.draw.rect(c, color, rect, border_radius=12)
            label = self.font(bh // 3).render(text, True, BLACK)
            c.blit(label, label.get_rect(center=rect.center))
            self.buttons.append((rect, action))

    def banner(self, message: str) -> None:
        c, w, h = self.canvas, self.width, self.height
        font = self.fit(message, h // 10, w - 60, bold=False)
        surface = font.render(message, True, BLACK)
        rect = surface.get_rect(center=(w // 2, h // 2)).inflate(40, 24)
        pygame.draw.rect(c, ORANGE, rect, border_radius=10)
        c.blit(surface, surface.get_rect(center=rect.center))

    def text(self, text, pos, font, color) -> None:
        self.canvas.blit(font.render(text, True, color), pos)

    def fit(self, text: str, size: int, max_width: int, bold: bool = True):
        size = max(10, size)
        font = self.font(size, bold)
        while size > 10 and font.size(text)[0] > max_width:
            size = int(size * 0.9)
            font = self.font(size, bold)
        return font

    def present(self) -> None:
        if self.rotation:
            frame = pygame.transform.rotate(self.canvas, -self.rotation)
        else:
            frame = self.canvas
        self.window.blit(frame, (0, 0))
        pygame.display.flip()

    def save(self, path: str) -> None:
        pygame.image.save(self.canvas, path)
