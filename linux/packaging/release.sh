#!/bin/sh
# Publishes the .deb of the current linux/ccl version as the GitHub release `linux-v<version>`.
# Run on an up-to-date `main`, after the Linux changes are merged. Needs gh (signed in).
#
# The release is created with --latest=false ON PURPOSE: the Mac app's updater and get.sh read
# `releases/latest` and expect a DMG there. A Linux release marked "Latest" breaks both.
#
#   sh linux/packaging/release.sh [notes-file]
set -eu

LINUX=$(cd "$(dirname "$0")/.." && pwd)
REPO=$(dirname "$LINUX")
VER=$(sed -n 's/^APP_VERSION = "\([0-9.]*\)"$/\1/p' "$LINUX/ccl/__init__.py")
TAG="linux-v$VER"
NOTES=${1:-}

cd "$REPO"
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || { echo "Switch to main first." >&2; exit 1; }
git fetch -q origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo "main is not in sync with origin/main." >&2; exit 1; }
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "Uncommitted changes." >&2; exit 1; }
if gh release view "$TAG" >/dev/null 2>&1; then echo "Release $TAG already exists." >&2; exit 1; fi

DEB=$(sh "$LINUX/packaging/build-deb.sh")
if [ -n "$NOTES" ]; then
    set -- --notes-file "$NOTES"
else
    set -- --notes "Linux (Astra Linux SE) $VER — пакет .deb. Установка: скачайте файл и откройте двойным щелчком, или \`sudo apt install ./$(basename "$DEB")\`."
fi
gh release create "$TAG" "$DEB" --target main --latest=false --title "Linux $VER" "$@"
