#!/bin/bash
# Build the app and package it into a distributable .dmg (drag-to-Applications).
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Claude Codex Limits"
VERSION="1.0"
APP="$DIR/dist/$APP_NAME.app"
DMG="$DIR/dist/ClaudeCodexLimits-$VERSION.dmg"
STAGE="$(mktemp -d)/dmg"

bash "$DIR/build.sh"

echo "==> staging"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

echo "==> creating dmg"
rm -f "$DMG"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGE" \
    -fs HFS+ \
    -format UDZO \
    -ov \
    "$DMG" >/dev/null

rm -rf "$STAGE"
echo "==> built: $DMG"
ls -lh "$DMG"
