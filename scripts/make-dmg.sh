#!/bin/bash
# Build the app and package it into a distributable .dmg (drag-to-Applications).
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Claude Codex Limits"
VERSION="2.7.1"
APP="$DIR/dist/$APP_NAME.app"
DMG="$DIR/dist/ClaudeCodexLimits-$VERSION.dmg"
STAGE="$(mktemp -d)/dmg"

bash "$DIR/build.sh"

echo "==> staging"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
# STAGE is a local (non-synced) temp dir. If dist/ sits on a cloud file-provider
# volume it may have re-injected com.apple.FinderInfo onto the signed bundle root
# after build.sh verified it; clear it on the staged copy and re-verify. The ad-hoc
# signature was made without that xattr, so clearing restores a valid bundle — and
# the packaged dmg is then guaranteed to hold a codesign-clean app.
xattr -cr "$STAGE/$APP_NAME.app"
codesign -v --strict "$STAGE/$APP_NAME.app" || { echo "!! staged app fails codesign -v" >&2; exit 1; }
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
