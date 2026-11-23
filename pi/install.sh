#!/bin/bash
# Captain Blinkheart Pi
# Copyright (C) 2026 Josh Hanson
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Installs the stage player on Raspberry Pi OS Lite and makes the Pi boot
# straight into it. Run from this folder:
#
#   sudo ./install.sh              install or update
#   sudo ./install.sh --read-only  also turn on the read-only system
#   sudo ./install.sh --screen 400x1280@60
#                                  set the screen's resolution (bar screens
#                                  that don't report it); without this, an
#                                  hdmi_cvt line in config.txt is used
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo: sudo ./install.sh" >&2
    exit 1
fi
HERE="$(cd "$(dirname "$0")" && pwd)"
READ_ONLY=0
SCREEN=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --read-only) READ_ONLY=1 ;;
        --screen) SCREEN="${2:?--screen needs a size, e.g. 400x1280@60}"; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
    shift
done

if grep -q " / overlay" /proc/mounts; then
    echo "The read-only system is on, so nothing can be installed." >&2
    echo "Run: sudo blinkheart-readonly off && sudo reboot, then install again." >&2
    exit 1
fi

# The boot partition (FAT) holds shows and settings: it stays writable when the
# system is read-only, and a Mac or PC can open it from the SD card.
if [[ -d /boot/firmware ]]; then BOOT=/boot/firmware; else BOOT=/boot; fi
HOME_DIR="$BOOT/blinkheart-pi"

echo "== Installing packages"
apt-get update
apt-get install -y python3 python3-pygame python3-serial python3-rtmidi
# Pi OS Lite leaves out the graphics drivers SDL needs to draw on the screen
# without a desktop (otherwise: "EGL not initialized").
apt-get install -y libegl1 libegl-mesa0 libgles2 libgbm1 libgl1-mesa-dri

echo "== Checking the display driver"
if ! grep -Eq "^[[:space:]]*dtoverlay=vc4-(f)?kms-v3d" "$BOOT/config.txt"; then
    printf '\n[all]\ndtoverlay=vc4-kms-v3d\n' >> "$BOOT/config.txt"
    echo "Turned on the KMS display driver in config.txt (takes effect after a reboot)."
fi
"$HERE/scripts/screen-mode.sh" "$BOOT" "$SCREEN"

echo "== Installing the player in /opt/blinkheart"
rm -rf /opt/blinkheart
mkdir -p /opt/blinkheart
cp -r "$HERE/blinkheart_pi" /opt/blinkheart/
install -m 755 "$HERE/scripts/readonly.sh" /usr/local/bin/blinkheart-readonly

echo "== Shows and settings go in $HOME_DIR"
mkdir -p "$HOME_DIR"
if [[ -d /var/lib/blinkheart/show && ! -d "$HOME_DIR/show" ]]; then
    cp -r /var/lib/blinkheart/show "$HOME_DIR/show"   # from an earlier install
fi

echo "== Starting the player at boot"
sed "s|^Environment=BLINKHEART_HOME=.*|Environment=BLINKHEART_HOME=$HOME_DIR|" \
    "$HERE/systemd/blinkheart.service" > /etc/systemd/system/blinkheart.service
systemctl daemon-reload
systemctl enable blinkheart.service

echo "== Silencing the boot screen"
"$HERE/scripts/quiet-boot.sh" "$BOOT"
# The player owns the screen: no login prompt on it.
systemctl disable getty@tty1.service 2>/dev/null || true
# No package updates or maintenance jobs in the middle of a show.
for timer in apt-daily.timer apt-daily-upgrade.timer man-db.timer; do
    systemctl disable --now "$timer" 2>/dev/null || true
done

if [[ $READ_ONLY == 1 ]]; then
    echo "== Turning on the read-only system"
    /usr/local/bin/blinkheart-readonly on
fi

systemctl restart blinkheart.service
echo
echo "Installed. Reboot to check the silent start-up: sudo reboot"
echo "Load a show by plugging in a USB stick with a \"blinkheart\" folder."
echo "Logs: journalctl -u blinkheart -f"
