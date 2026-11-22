# Captain Blinkheart Pi
# Copyright (C) 2026 Josh Hanson
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Reads uncompressed FSEQ v2 files (the Falcon Player / xLights format)."""

from __future__ import annotations

import struct
from dataclasses import dataclass
from pathlib import Path
from typing import List


class FSEQError(ValueError):
    pass


@dataclass
class Sequence:
    frames: List[bytes]
    step_ms: int
    channel_count: int

    @property
    def duration(self) -> float:
        return len(self.frames) * self.step_ms / 1000


def parse(data: bytes) -> Sequence:
    if len(data) < 32 or data[0:4] != b"PSEQ":
        raise FSEQError("not an FSEQ file")
    if data[7] != 2:
        raise FSEQError(f"FSEQ version {data[7]} is not supported")
    if data[20] & 0x0F != 0:
        raise FSEQError("compressed FSEQ files are not supported; export them uncompressed")
    if data[22] != 0:
        raise FSEQError("sparse FSEQ files are not supported")
    data_offset = struct.unpack_from("<H", data, 4)[0]
    channel_count, frame_count = struct.unpack_from("<II", data, 10)
    step_ms = data[18] or 25
    end = data_offset + channel_count * frame_count
    if channel_count == 0 or frame_count == 0:
        raise FSEQError("the sequence is empty")
    if len(data) < end:
        raise FSEQError("the file is incomplete")
    frames = [bytes(data[data_offset + i * channel_count:data_offset + (i + 1) * channel_count])
              for i in range(frame_count)]
    return Sequence(frames=frames, step_ms=step_ms, channel_count=channel_count)


def read(path: Path) -> Sequence:
    return parse(Path(path).read_bytes())


def encode(frames: List[bytes], step_ms: int) -> bytes:
    """Writes an uncompressed FSEQ v2 file (used by tests and tools)."""
    channel_count = len(frames[0])
    producer = b"sp" + b"Captain Blinkheart Pi\x00"
    variable = struct.pack("<H", len(producer) + 2) + producer
    header_length = 32
    data_offset = (header_length + len(variable) + 3) // 4 * 4
    header = b"PSEQ" + struct.pack("<HBBHIIBBBBBBQ", data_offset, 0, 2, header_length,
                                   channel_count, len(frames), step_ms, 0, 0, 0, 0, 0, 0)
    body = header + variable
    body += b"\x00" * (data_offset - len(body))
    return body + b"".join(frames)
