#!/bin/bash
# Captain Blinkheart Pi
# Copyright (C) 2026 Josh Hanson
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Sets the screen's resolution for the KMS display driver.
#
# Bar-shaped screens (400x1280 and similar) often don't tell the Pi their
# resolution, and their makers give config.txt lines like
#     hdmi_cvt 400 1280 60 6 0 0 0
# Those lines only work with the old display driver; with KMS (which the
# player needs) the resolution goes in cmdline.txt as video=HDMI-A-1:...
# This script writes that option, from the size you give or from an
# hdmi_cvt line already in config.txt.
#
# Usage: screen-mode.sh <boot folder> [WIDTHxHEIGHT[@RATE]]   e.g. 400x1280@60
set -euo pipefail
BOOT="${1:?usage: screen-mode.sh <boot folder> [WIDTHxHEIGHT[@RATE]]}"
MODE="${2:-}"
CMDLINE="$BOOT/cmdline.txt"
CONFIG="$BOOT/config.txt"

if [[ -z "$MODE" ]]; then
    cvt="$(grep -E '^[[:space:]]*hdmi_cvt[[:space:]=]' "$CONFIG" | tail -1 | sed -E 's/^[[:space:]]*hdmi_cvt[[:space:]=]+//' || true)"
    if [[ -n "$cvt" ]]; then
        read -r w h r _ <<< "$cvt"
        MODE="${w}x${h}@${r:-60}"
        echo "Found the screen's size in config.txt: hdmi_cvt $cvt"
    fi
fi
if [[ -z "$MODE" ]]; then
    echo "No screen size given or found in config.txt; leaving the resolution automatic."
    exit 0
fi
if ! [[ "$MODE" =~ ^([0-9]+)x([0-9]+)(@([0-9]+))?$ ]]; then
    echo "Screen size should look like 400x1280 or 400x1280@60, not \"$MODE\"." >&2
    exit 1
fi
w="${BASH_REMATCH[1]}"; h="${BASH_REMATCH[2]}"; r="${BASH_REMATCH[4]:-60}"

[[ -f "$CMDLINE.blinkheart-backup" ]] || cp "$CMDLINE" "$CMDLINE.blinkheart-backup"
line="$(tr -d '\n' < "$CMDLINE")"
# Replace any earlier HDMI video= option. "D" turns the output on even if the
# screen is slow to say it's connected.
line="$(sed -E 's/ ?video=HDMI-A-1:[^ ]*//g' <<< "$line")"
line="$line video=HDMI-A-1:${w}x${h}M@${r}D"
printf '%s\n' "$line" > "$CMDLINE"
echo "Screen set to ${w}x${h} at ${r} Hz (cmdline.txt). Reboot to apply."
