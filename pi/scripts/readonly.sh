#!/bin/bash
# Captain Blinkheart Pi
# Copyright (C) 2026 Josh Hanson
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Turns the read-only system on or off. With it on, the system drive is never
# written, so pulling the power can't corrupt it. Shows and settings live on
# the boot partition, which stays writable and is only written while a show
# is being loaded.
# Usage: sudo blinkheart-readonly on|off|status   (then reboot)
set -euo pipefail
case "${1:-status}" in
    on)
        raspi-config nonint enable_overlayfs 2>/dev/null || raspi-config nonint do_overlayfs 0
        echo "Read-only system turned on. Reboot to apply: sudo reboot"
        ;;
    off)
        raspi-config nonint disable_overlayfs 2>/dev/null || raspi-config nonint do_overlayfs 1
        echo "Read-only system turned off. Reboot to apply: sudo reboot"
        ;;
    status)
        if grep -q " / overlay" /proc/mounts || grep -q "overlayroot" /proc/cmdline; then
            echo "Read-only system: ON (changes to the system are lost at reboot)"
        else
            echo "Read-only system: OFF"
        fi
        ;;
    *)
        echo "usage: blinkheart-readonly on|off|status" >&2
        exit 1
        ;;
esac
