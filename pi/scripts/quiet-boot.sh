#!/bin/bash
# Captain Blinkheart Pi
# Copyright (C) 2026 Josh Hanson
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Makes the Pi boot silently: no rainbow screen, logos, boot messages, or
# blinking cursor, so the screen goes from black to the Blinkheart display.
# Usage: quiet-boot.sh <boot folder>   (e.g. /boot/firmware). Safe to run twice.
set -euo pipefail
BOOT="${1:?usage: quiet-boot.sh <boot folder>}"
CMDLINE="$BOOT/cmdline.txt"
CONFIG="$BOOT/config.txt"

[[ -f "$CMDLINE" && -f "$CONFIG" ]] || { echo "No cmdline.txt/config.txt in $BOOT" >&2; exit 1; }
[[ -f "$CMDLINE.blinkheart-backup" ]] || cp "$CMDLINE" "$CMDLINE.blinkheart-backup"
[[ -f "$CONFIG.blinkheart-backup" ]] || cp "$CONFIG" "$CONFIG.blinkheart-backup"

# cmdline.txt is a single line. Send the console to an unused terminal, and
# silence the kernel, systemd, and the cursor.
line="$(tr -d '\n' < "$CMDLINE")"
line="${line//console=tty1/console=tty3}"
for option in quiet loglevel=3 logo.nologo vt.global_cursor_default=0 \
              consoleblank=0 systemd.show_status=false rd.udev.log_level=3 \
              udev.log_priority=3; do
    key="${option%%=*}"
    if ! grep -Eq "(^| )${key//./\\.}(=| |$)" <<< "$line"; then
        line="$line $option"
    fi
done
printf '%s\n' "$line" > "$CMDLINE"

# config.txt: no rainbow splash, no boot delay.
if ! grep -q "^# Captain Blinkheart" "$CONFIG"; then
    cat >> "$CONFIG" <<'CFG'

# Captain Blinkheart: silent boot
[all]
disable_splash=1
boot_delay=0
CFG
fi
echo "Quiet boot configured in $BOOT"
