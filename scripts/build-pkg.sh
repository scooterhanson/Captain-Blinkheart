#!/bin/bash
# Captain Blinkheart
# Copyright (C) 2026 Josh Hanson
# SPDX-License-Identifier: AGPL-3.0-or-later
# Builds dist/Captain-Blinkheart-<version>.pkg, which installs
# "Captain Blinkheart.app" into /Applications.
#
#   ./scripts/build-pkg.sh             build the app, then the installer
#   SKIP_APP_BUILD=1 ./scripts/build-pkg.sh   package the existing dist app
#
# Signing: PKG_SIGN_IDENTITY, or the first "Developer ID Installer"
# certificate in the keychain; the package is left unsigned if none is found.
# Notarization (uploads the package to Apple) runs only when NOTARY_PROFILE
# names a keychain profile created with `xcrun notarytool store-credentials`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Captain Blinkheart"
APP_DIR="$ROOT/dist/$APP_NAME.app"
WORK="$ROOT/.build/pkg"
IDENTIFIER="com.scenebridge.installer"

if [ -z "${SKIP_APP_BUILD:-}" ]; then
    "$ROOT/scripts/build-app.sh"
fi
[ -d "$APP_DIR" ] || { echo "Missing $APP_DIR" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")"
OUTPUT="$ROOT/dist/Captain-Blinkheart-$VERSION.pkg"

rm -rf "$WORK"
mkdir -p "$WORK/root" "$WORK/packages"
# Copy without resource forks or extended attributes so the payload has no
# AppleDouble (._) files or quarantine flags.
ditto --norsrc --noextattr "$APP_DIR" "$WORK/root/$APP_NAME.app"

# Install exactly into /Applications. With relocation on, Installer would
# instead "upgrade" any other copy with the same bundle ID it finds, such as
# the build output in dist/.
pkgbuild --analyze --root "$WORK/root" "$WORK/component.plist" >/dev/null
INDEX=0
while /usr/libexec/PlistBuddy -c "Print :$INDEX" "$WORK/component.plist" >/dev/null 2>&1; do
    /usr/libexec/PlistBuddy -c "Set :$INDEX:BundleIsRelocatable false" "$WORK/component.plist"
    INDEX=$((INDEX + 1))
done

pkgbuild \
    --root "$WORK/root" \
    --component-plist "$WORK/component.plist" \
    --identifier "$IDENTIFIER" \
    --version "$VERSION" \
    --install-location /Applications \
    "$WORK/packages/CaptainBlinkheart.pkg"

productbuild --synthesize --package "$WORK/packages/CaptainBlinkheart.pkg" "$WORK/distribution.xml"
python3 - "$WORK/distribution.xml" "$APP_NAME" <<'PY'
import re, sys
path, title = sys.argv[1], sys.argv[2]
xml = open(path).read()
extra = (
    f'    <title>{title}</title>\n'
    '    <domains enable_localSystem="true" enable_currentUserHome="false" enable_anywhere="false"/>\n'
    '    <volume-check>\n'
    '        <allowed-os-versions><os-version min="12.0"/></allowed-os-versions>\n'
    '    </volume-check>\n'
)
xml, count = re.subn(r'(<installer-gui-script[^>]*>\n)', lambda m: m.group(1) + extra, xml, count=1)
assert count == 1, "installer-gui-script element not found"
if 'hostArchitectures' not in xml:
    xml = xml.replace('<options customize="never" require-scripts="false"',
                      '<options customize="never" require-scripts="false" hostArchitectures="arm64,x86_64"', 1)
open(path, 'w').write(xml)
PY

PKG_SIGN_IDENTITY="${PKG_SIGN_IDENTITY:-$(security find-identity -v 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Installer: .*\)"/\1/p' | head -n 1)}"
SIGN_ARGS=()
if [ -n "$PKG_SIGN_IDENTITY" ]; then
    SIGN_ARGS=(--sign "$PKG_SIGN_IDENTITY" --timestamp)
fi

rm -f "$OUTPUT"
productbuild \
    --distribution "$WORK/distribution.xml" \
    --package-path "$WORK/packages" \
    "${SIGN_ARGS[@]+"${SIGN_ARGS[@]}"}" \
    "$OUTPUT"

if [ -n "$PKG_SIGN_IDENTITY" ]; then
    pkgutil --check-signature "$OUTPUT"
else
    echo "Package is unsigned (no Developer ID Installer certificate found)"
fi

if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$OUTPUT" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$OUTPUT"
fi

echo "Built $OUTPUT"
