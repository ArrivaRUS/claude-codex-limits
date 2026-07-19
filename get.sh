#!/bin/bash
# get.sh — one-command installer for "Claude Codex Limits".
#
# Downloads the latest signed .dmg from GitHub Releases and installs it into
# /Applications WITHOUT triggering the Gatekeeper "damaged / unidentified
# developer" dialogs: files fetched with curl by this script are not flagged
# with the com.apple.quarantine attribute (and we strip it defensively anyway).
#
#   curl -fsSL https://raw.githubusercontent.com/ArrivaRUS/claude-codex-limits/main/get.sh | bash
#
set -euo pipefail

REPO="ArrivaRUS/claude-codex-limits"
APP_NAME="Claude Codex Limits"
EXE_NAME="ClaudeCodexLimits"
DEST="/Applications/$APP_NAME.app"
API="https://api.github.com/repos/$REPO/releases/latest"

# --- cleanup (runs on any exit: success, error, or Ctrl-C) -------------------
TMP=""
MNT=""
cleanup() {
    if [ -n "$MNT" ] && [ -d "$MNT" ]; then
        hdiutil detach "$MNT" -quiet 2>/dev/null || true
    fi
    if [ -n "$TMP" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# --- 1. find the latest release ---------------------------------------------
echo "==> Finding the latest release…"
if ! META="$(curl -fsSL "$API")"; then
    echo "Error: could not reach GitHub. Check your internet connection and try again." >&2
    exit 1
fi

# Pull the first *.dmg asset URL out of the JSON without depending on jq.
DMG_URL="$(printf '%s' "$META" \
    | grep -o '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]*\.dmg"' \
    | head -n1 \
    | sed -E 's/^.*"(https[^"]+)".*$/\1/')"

if [ -z "$DMG_URL" ]; then
    echo "Error: no .dmg asset found in the latest release of $REPO." >&2
    echo "Download it manually from: https://github.com/$REPO/releases/latest" >&2
    exit 1
fi

# --- 2. download -------------------------------------------------------------
echo "==> Downloading: $DMG_URL"
TMP="$(mktemp -d)"
DMG="$TMP/app.dmg"
if ! curl -fsSL "$DMG_URL" -o "$DMG"; then
    echo "Error: download failed. Try again, or download manually from:" >&2
    echo "https://github.com/$REPO/releases/latest" >&2
    exit 1
fi

# --- 3. mount ----------------------------------------------------------------
echo "==> Mounting disk image…"
MNT="$TMP/mnt"
mkdir -p "$MNT"
hdiutil attach "$DMG" -nobrowse -quiet -mountpoint "$MNT"

SRC="$MNT/$APP_NAME.app"
if [ ! -d "$SRC" ]; then
    SRC="$(/usr/bin/find "$MNT" -maxdepth 1 -name '*.app' -print -quit)"
fi
if [ -z "$SRC" ] || [ ! -d "$SRC" ]; then
    echo "Error: could not find the app inside the disk image." >&2
    exit 1
fi

# --- 4. install --------------------------------------------------------------
echo "==> Installing to $DEST…"
# Stop any running instance so we can overwrite the bundle (mirrors install.sh).
pkill -f "$DEST/Contents/MacOS/$EXE_NAME" 2>/dev/null || true
sleep 0.4
rm -rf "$DEST"
cp -R "$SRC" "$DEST"

echo "==> Detaching disk image…"
hdiutil detach "$MNT" -quiet
MNT=""

# Belt-and-suspenders: remove the quarantine attribute if it somehow got set.
/usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

# --- 5. launch ---------------------------------------------------------------
echo "==> Launching…"
open "$DEST"

echo ""
echo "Installed: $DEST"
echo "Look for the icon in the top-right of your menu bar."
echo ""
echo "Note: launch-at-login is OFF by default. To start the app automatically,"
echo "      open its menu-bar menu and enable \"Launch at login\" in settings."
