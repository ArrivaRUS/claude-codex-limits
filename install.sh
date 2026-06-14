#!/bin/bash
# Build, install to /Applications, enable launch-at-login, and start the app.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Claude Codex Limits"
EXE_NAME="ClaudeCodexLimits"
BUNDLE_ID="com.arrivarus.claudecodexlimits"
DEST="/Applications/$APP_NAME.app"
AGENT="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"

bash "$DIR/build.sh"

echo "==> installing to $DEST"
pkill -f "$DEST/Contents/MacOS/$EXE_NAME" 2>/dev/null || true
sleep 0.4
rm -rf "$DEST"
cp -R "$DIR/dist/$APP_NAME.app" "$DEST"

/usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" 2>/dev/null || true

echo "==> launch-at-login agent"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$BUNDLE_ID</string>
    <key>ProgramArguments</key>
    <array><string>$DEST/Contents/MacOS/$EXE_NAME</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><false/>
    <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
PLIST

echo "==> launching"
open "$DEST"
echo "==> done. Look in the top-right of your menu bar."
