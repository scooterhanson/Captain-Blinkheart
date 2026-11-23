#!/bin/bash
# Captain Blinkheart Pi
# Copyright (C) 2026 Josh Hanson
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Shows what the screen tells the Pi about itself, then draws a test pattern
# straight to the screen for 10 seconds (with the player stopped).
# Usage: sudo ./scripts/screen-check.sh
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "Run with sudo" >&2; exit 1; }
BOOT=/boot/firmware; [[ -d $BOOT ]] || BOOT=/boot

echo "== cmdline.txt video option"
grep -o 'video=[^ ]*' "$BOOT/cmdline.txt" || echo "(none: resolution is automatic)"
echo "== Display overlay in config.txt"
grep -E '^[[:space:]]*(dtoverlay=vc4|hdmi_)' "$BOOT/config.txt" || echo "(none)"

for c in /sys/class/drm/card*-HDMI-A-*; do
    [[ -e $c ]] || continue
    echo "== $(basename "$c"): $(cat "$c/status"), $(cat "$c/enabled")"
    echo "Modes offered: $(tr '\n' ' ' < "$c/modes")"
    python3 - "$c/edid" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
if len(data) < 128:
    print("EDID: none (the screen doesn't describe itself)")
    sys.exit()
maker = data[8] << 8 | data[9]
name = "".join(chr(((maker >> s) & 31) + 64) for s in (10, 5, 0))
print(f"EDID: maker {name}, product {data[10] | data[11] << 8:04x}")
for i in range(4):
    d = data[54 + 18 * i: 72 + 18 * i]
    clock = (d[0] | d[1] << 8) * 10  # kHz
    if clock == 0:
        if d[3] == 0xFC:
            print("Name:", d[5:18].decode("ascii", "replace").strip())
        continue
    ha = d[2] | (d[4] & 0xF0) << 4; hb = d[3] | (d[4] & 0x0F) << 8
    va = d[5] | (d[7] & 0xF0) << 4; vb = d[6] | (d[7] & 0x0F) << 8
    hfp = d[8] | (d[11] & 0xC0) << 2; hs = d[9] | (d[11] & 0x30) << 4
    vfp = d[10] >> 4 | (d[11] & 0x0C) << 2; vs = d[10] & 0x0F | (d[11] & 0x03) << 4
    hz = clock * 1000 / ((ha + hb) * (va + vb))
    print(f"Timing {i + 1}{' (preferred)' if i == 0 else ''}: {ha}x{va} @ {hz:.1f} Hz, "
          f"clock {clock / 1000:.2f} MHz, h {ha} {hfp} {hs} {hb - hfp - hs}, v {va} {vfp} {vs} {vb - vfp - vs}")
PY
done

echo "== Player"
journalctl -u blinkheart -b --no-pager | grep -E "Display|display" | tail -2

echo "== Test pattern: stopping the player and filling the screen for 10 s"
systemctl stop blinkheart
if [[ -e /dev/fb0 ]]; then
    cat /sys/class/graphics/fb0/virtual_size 2>/dev/null | sed 's/^/Framebuffer size: /'
    ( head -c 20000000 /dev/urandom > /dev/fb0 ) 2>/dev/null
    echo "Do you see coloured noise on the screen?"
    sleep 10
else
    echo "No /dev/fb0, so no test pattern."
fi
systemctl start blinkheart
echo "== Player restarted"
