#!/bin/bash
# Build "Claude Codex Limits.app" into ./dist (no install). Pure system tooling.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Claude Codex Limits"
EXE_NAME="ClaudeCodexLimits"
BUNDLE_ID="com.arrivarus.claudecodexlimits"
VERSION="2.7.2"
APP="$DIR/dist/$APP_NAME.app"

echo "==> building $APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

/usr/bin/swiftc -O "$DIR/Sources/LimitsMonitor.swift" -o "$APP/Contents/MacOS/$EXE_NAME"
cp -R "$DIR/Resources/"* "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$EXE_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSUIElement</key><true/>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticTermination</key><false/>
    <key>NSSupportsSuddenTermination</key><false/>
</dict>
</plist>
PLIST

# --- Code signing (ad-hoc) ---------------------------------------------------
# No Apple Developer account, so we sign ad-hoc (identity "-"). This is still
# required: an unsigned / linker-signed-only bundle fails `codesign -v` with
# "code has no resources but signature indicates they must be present" and
# Gatekeeper treats it as damaged.
echo "==> code-signing (ad-hoc)"
# Clear extended attributes first. Files copied from Resources carry FinderInfo /
# resource forks; without this codesign aborts with "resource fork, Finder
# information, or similar detritus not allowed".
#
# When dist/ lives on a cloud file-provider volume (iCloud Drive / Dropbox / etc.,
# marked by a com.apple.fileprovider.fpfs xattr) the provider ASYNCHRONOUSLY
# re-injects com.apple.FinderInfo onto the freshly-created .app bundle root a
# moment after we clear it — so a single clear+sign can lose the race and fail
# intermittently with the "detritus not allowed" error. Retry the clear+sign+verify
# until codesign wins on a settled tree (it converges within a couple of attempts).
signed=0
for attempt in 1 2 3 4 5 6 7 8; do
    xattr -cr "$APP"
    if codesign --force --deep -s - "$APP" 2>/tmp/ccl_codesign.err \
       && codesign -v "$APP" 2>>/tmp/ccl_codesign.err; then
        signed=1; break
    fi
    echo "   sign/verify attempt $attempt lost the FinderInfo race, retrying…" >&2
done
if [ "$signed" != 1 ]; then
    echo "!! codesign FAILED for $APP after 8 attempts" >&2
    cat /tmp/ccl_codesign.err >&2 || true
    exit 1
fi
echo "==> signed & verified"

echo "==> built: $APP"
