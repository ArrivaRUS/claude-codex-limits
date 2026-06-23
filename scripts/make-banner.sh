#!/bin/bash
# Render the GitHub social-preview banner -> docs/banner.png (1280x640).
# Pure system tooling (iconutil + swiftc), no dependencies.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
ICONSET="$TMP/AppIcon.iconset"

iconutil -c iconset "$DIR/Resources/AppIcon.icns" -o "$ICONSET"
swift "$DIR/scripts/make-banner.swift" "$ICONSET/icon_512x512@2x.png" "$DIR/docs/banner.png"

rm -rf "$TMP"
echo "==> docs/banner.png"
