#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
BUILD_DIR="$ROOT_DIR/build"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="XG27UCG Input Switcher"
APP_PATH="$BUILD_DIR/$APP_NAME.app"
DMG_PATH="$DIST_DIR/XG27UCG-Input-Switcher-1.1.1.dmg"
M1DDC_BIN="${M1DDC_BIN:-/opt/homebrew/bin/m1ddc}"

[[ -x "$M1DDC_BIN" ]] || { print -u2 "m1ddc not found: $M1DDC_BIN"; exit 1; }

rm -rf "$BUILD_DIR"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources/bin" "$DIST_DIR"

swiftc "$ROOT_DIR/Sources/XG27UCGSwitcher.swift" \
  -o "$APP_PATH/Contents/MacOS/XG27UCGSwitcher" \
  -framework AppKit -framework Carbon -framework CoreAudio
cp "$ROOT_DIR/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
cp "$M1DDC_BIN" "$APP_PATH/Contents/Resources/bin/m1ddc"
cp "$ROOT_DIR/THIRD_PARTY_LICENSES/m1ddc-LICENSE" "$APP_PATH/Contents/Resources/m1ddc-LICENSE"
chmod +x "$APP_PATH/Contents/Resources/bin/m1ddc"
codesign --force --deep --sign - "$APP_PATH"

STAGE_DIR="$BUILD_DIR/dmg"
mkdir -p "$STAGE_DIR"
cp -R "$APP_PATH" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"
cp "$ROOT_DIR/README.md" "$STAGE_DIR/README.txt"
rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE_DIR" -ov -format UDZO "$DMG_PATH"

print "$DMG_PATH"
