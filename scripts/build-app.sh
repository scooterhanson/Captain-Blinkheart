#!/bin/bash
# Captain Blinkheart
# Copyright (C) 2026 Josh Hanson
# SPDX-License-Identifier: AGPL-3.0-or-later
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Captain Blinkheart"
APP_DIR="$ROOT/dist/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"
BUILD_ROOT="$ROOT/.build/universal"

cd "$ROOT"
mkdir -p "$BUILD_ROOT"
for ARCH in arm64 x86_64; do
    TRIPLE="$ARCH-apple-macosx12.0"
    SCRATCH="$BUILD_ROOT/$ARCH"
    swift build \
        --package-path "$ROOT" \
        --scratch-path "$SCRATCH" \
        --triple "$TRIPLE" \
        -c release \
        -Xswiftc -runtime-compatibility-version \
        -Xswiftc none
    BIN_PATH="$(swift build \
        --package-path "$ROOT" \
        --scratch-path "$SCRATCH" \
        --triple "$TRIPLE" \
        -c release \
        -Xswiftc -runtime-compatibility-version \
        -Xswiftc none \
        --show-bin-path)"
    cp "$BIN_PATH/$APP_NAME" "$BUILD_ROOT/$APP_NAME-$ARCH"
done

mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

# App icon: mask the source art onto Apple's icon grid, then build an .icns
# containing every size macOS asks for.
ICON_SOURCE="$ROOT/captain_blinkheart_icon.png"
ICONSET="$BUILD_ROOT/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
swift "$ROOT/scripts/make-icon.swift" "$ICON_SOURCE" "$BUILD_ROOT/AppIcon-1024.png"
for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" "$BUILD_ROOT/AppIcon-1024.png" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$((SIZE * 2))
    sips -z "$DOUBLE" "$DOUBLE" "$BUILD_ROOT/AppIcon-1024.png" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/AppIcon.icns"
lipo -create \
    "$BUILD_ROOT/$APP_NAME-arm64" \
    "$BUILD_ROOT/$APP_NAME-x86_64" \
    -output "$CONTENTS/MacOS/$APP_NAME"
lipo -verify_arch arm64 "$CONTENTS/MacOS/$APP_NAME"
lipo -verify_arch x86_64 "$CONTENTS/MacOS/$APP_NAME"
cp -R "$BUILD_ROOT/arm64/out/Products/Release/CaptainBlinkheart_SceneBridgeCore.bundle" "$CONTENTS/Resources/"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.scenebridge.app</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.1</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Code signing. Uses APP_SIGN_IDENTITY if set, otherwise the first
# "Developer ID Application" certificate in the keychain, otherwise ad-hoc.
# Developer ID signing enables the hardened runtime (required for
# notarization); the entitlements allow in-process loading of third-party
# Audio Units such as Show Buddy Active.
APP_SIGN_IDENTITY="${APP_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -n 1)}"
if [ -n "$APP_SIGN_IDENTITY" ] && [ "$APP_SIGN_IDENTITY" != "-" ]; then
    codesign --force --timestamp --options runtime \
        --entitlements "$ROOT/scripts/CaptainBlinkheart.entitlements" \
        --sign "$APP_SIGN_IDENTITY" "$APP_DIR"
    echo "Signed with: $APP_SIGN_IDENTITY"
else
    codesign --force --sign - "$APP_DIR"
    echo "Signed ad-hoc (no Developer ID Application certificate found)"
fi
codesign --verify --strict --verbose=2 "$APP_DIR"

echo "Built $APP_DIR"
