# Captain Blinkheart Pi
# Copyright (C) 2026 Josh Hanson
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Plays looping scenes and crossfades between them."""

from __future__ import annotations

import random
import threading
import time
from dataclasses import dataclass
from typing import Callable, Dict, Optional, Union

from .show import Scene, Show, Switch


@dataclass
class Layer:
    scene: Scene
    started: float

    def frame(self, now: float) -> bytes:
        frames = self.scene.frames
        if len(frames) == 1:
            return frames[0]
        index = int((now - self.started) * 1000 / self.scene.step_ms) % len(frames)
        return frames[index]


@dataclass
class Still:
    frame_bytes: bytes

    def frame(self, now: float) -> bytes:
        return self.frame_bytes


def blend(old: bytes, new: bytes, weight: float) -> bytes:
    """Mixes two frames: weight 0 is all `old`, 1 is all `new`."""
    if weight <= 0:
        return old
    if weight >= 1:
        return new
    keep = 1 - weight
    return bytes(int(a * keep + b * weight + 0.5) for a, b in zip(old, new))


@dataclass
class State:
    """What the screen shows."""
    switch: Optional[Switch]
    scene: Optional[Scene]
    fade_progress: float  # 1.0 when no fade is running


class Engine:
    """Owns the current show and computes each output frame."""

    def __init__(self, channels: int = 512, clock: Callable[[], float] = time.monotonic,
                 rng: Optional[random.Random] = None):
        self.channels = channels
        self.clock = clock
        self.rng = rng or random.Random()
        self.lock = threading.RLock()
        self.show: Optional[Show] = None
        self.blackout = bytes(channels)
        self.current: Optional[Union[Layer, Still]] = Still(self.blackout)
        self.previous: Optional[Union[Layer, Still]] = None
        self.fade_start = 0.0
        self.fade_seconds = 0.0
        self.active_switch: Optional[Switch] = None
        self.active_scene: Optional[Scene] = None
        self.last_scene: Dict[int, str] = {}
        self.listeners = []

    # Show

    def load(self, show: Show) -> None:
        with self.lock:
            self.show = show
            self.last_scene.clear()
            self._start(Still(self.blackout), fade=0)
            self.active_switch = None
            self.active_scene = None
        self._notify()

    # Switches

    def press(self, number: int) -> Optional[Scene]:
        """Fires a switch: picks its next scene and fades to it."""
        with self.lock:
            switch = self.show.switch(number) if self.show else None
            if switch is None:
                return None
            scene = self.choose(switch)
            now = self.clock()
            if scene is None:
                if switch.action == "reset":
                    self._start(Still(self.blackout), switch.fade, now)
                    self.active_switch, self.active_scene = switch, None
                else:
                    return None
            else:
                self._start(Layer(scene, now), switch.fade, now)
                self.active_switch, self.active_scene = switch, scene
        self._notify()
        return scene

    def choose(self, switch: Switch) -> Optional[Scene]:
        scenes = switch.scenes
        if not scenes:
            return None
        if switch.mode == "single" or len(scenes) == 1:
            choice = scenes[0]
        else:
            previous = self.last_scene.get(switch.number)
            options = [s for s in scenes if s.name != previous] or scenes
            choice = self.rng.choice(options)
        self.last_scene[switch.number] = choice.name
        return choice

    def blackout_now(self, fade: float = 0) -> None:
        with self.lock:
            self._start(Still(self.blackout), fade)
            self.active_switch, self.active_scene = None, None
        self._notify()

    def _start(self, layer, fade: float, now: Optional[float] = None) -> None:
        now = self.clock() if now is None else now
        if fade > 0 and self.current is not None:
            # Mid-fade, freeze the mix so far as the outgoing look.
            if self.previous is not None and self._fade_weight(now) < 1:
                self.previous = Still(self._mix(now))
            else:
                self.previous = self.current
            self.fade_start, self.fade_seconds = now, fade
        else:
            self.previous, self.fade_seconds = None, 0.0
        self.current = layer

    # Output

    def _fade_weight(self, now: float) -> float:
        if self.previous is None or self.fade_seconds <= 0:
            return 1.0
        return min(1.0, max(0.0, (now - self.fade_start) / self.fade_seconds))

    def _mix(self, now: float) -> bytes:
        current = self.current.frame(now) if self.current else self.blackout
        weight = self._fade_weight(now)
        if weight >= 1 or self.previous is None:
            return current
        return blend(self.previous.frame(now), current, weight)

    def render(self, now: Optional[float] = None) -> bytes:
        with self.lock:
            now = self.clock() if now is None else now
            frame = self._mix(now)
            if self.previous is not None and self._fade_weight(now) >= 1:
                self.previous = None
            return frame

    def state(self) -> State:
        with self.lock:
            return State(self.active_switch, self.active_scene, self._fade_weight(self.clock()))

    def frame_interval(self) -> float:
        """Seconds between output frames: the scenes' own frame rate."""
        with self.lock:
            steps = [s.step_ms for sw in (self.show.switches if self.show else []) for s in sw.scenes]
        return (min(steps) if steps else 25) / 1000

    def add_listener(self, callback) -> None:
        self.listeners.append(callback)

    def _notify(self) -> None:
        for callback in list(self.listeners):
            try:
                callback()
            except Exception:
                pass


class OutputLoop(threading.Thread):
    """Sends the engine's frames to a DMX output at the scenes' frame rate."""

    def __init__(self, engine: Engine, output):
        super().__init__(name="dmx-output", daemon=True)
        self.engine = engine
        self.output = output
        self.running = True

    def run(self) -> None:
        next_time = time.monotonic()
        while self.running:
            interval = self.engine.frame_interval()
            self.output.send(self.engine.render())
            next_time += interval
            delay = next_time - time.monotonic()
            if delay > 0:
                time.sleep(delay)
            else:
                next_time = time.monotonic()

    def stop(self) -> None:
        self.running = False
