#!/bin/sh
# Builds the Debian package of the Linux port: dist/claude-codex-limits_<version>_all.deb.
# Needs only dpkg-deb — no root, no debhelper. The package installs system-wide:
#   /usr/share/claude-codex-limits        the program (ccl/, the two entry scripts, Resources/)
#   /usr/bin/claude-codex-limits, ccl-sync
#   menu entry + icon, and the systemd user timer ccl-sync.timer, enabled for every user —
#   for anyone who never ran `ccl-sync login` it exits at once and touches nothing.
# Autostart of the tray icon is per user: the app turns it on at its first launch.
#
#   sh linux/packaging/build-deb.sh [output-dir]     # default: dist/ in the repository
set -eu

LINUX=$(cd "$(dirname "$0")/.." && pwd)
REPO=$(dirname "$LINUX")
OUT=${1:-$REPO/dist}
PKG=claude-codex-limits
PY=/usr/bin/python3
VER=$(sed -n 's/^APP_VERSION = "\([0-9.]*\)"$/\1/p' "$LINUX/ccl/__init__.py")
[ -n "$VER" ] || { echo "APP_VERSION not found in linux/ccl/__init__.py" >&2; exit 1; }
command -v dpkg-deb >/dev/null 2>&1 || { echo "dpkg-deb not found" >&2; exit 1; }

umask 022
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
APP=$ROOT/usr/share/$PKG
mkdir -p "$APP/Resources" "$ROOT/usr/bin" "$ROOT/usr/share/applications" \
         "$ROOT/usr/share/icons/hicolor/256x256/apps" "$ROOT/usr/lib/systemd/user" \
         "$ROOT/usr/share/doc/$PKG" "$ROOT/DEBIAN"

cp -r "$LINUX/ccl" "$APP/"
find "$APP" -name __pycache__ -type d -prune -exec rm -rf {} +
cp "$LINUX/ccl-sync" "$LINUX/claude-codex-limits" "$APP/"
cp "$REPO"/Resources/*.png "$REPO"/Resources/*.wav "$APP/Resources/"
cp "$REPO/Resources/appicon.png" "$ROOT/usr/share/icons/hicolor/256x256/apps/$PKG.png"
cp "$REPO/LICENSE" "$ROOT/usr/share/doc/$PKG/copyright"

# Wrappers run the scripts through the system interpreter explicitly, as install.sh does —
# the variant that works under Astra's interpreter control.
for name in claude-codex-limits ccl-sync; do
    printf '#!/bin/sh\nexec %s /usr/share/%s/%s "$@"\n' "$PY" "$PKG" "$name" > "$ROOT/usr/bin/$name"
done

cat > "$ROOT/usr/share/applications/$PKG.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Claude Codex Limits
Comment=Claude Code and Codex limits in the tray
Comment[ru]=Лимиты Claude Code и Codex в трее
Exec=claude-codex-limits
TryExec=claude-codex-limits
Icon=$PKG
Terminal=false
Categories=Utility;
EOF

cat > "$ROOT/usr/lib/systemd/user/ccl-sync.service" <<EOF
[Unit]
Description=Claude Codex Limits — index local usage logs and sync through the GitHub gist

[Service]
Type=oneshot
ExecStart=/usr/bin/ccl-sync push --auto --quiet
Nice=10
IOSchedulingClass=idle
EOF
cat > "$ROOT/usr/lib/systemd/user/ccl-sync.timer" <<EOF
[Unit]
Description=Claude Codex Limits sync every 10 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=10min
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF

cat > "$ROOT/DEBIAN/postinst" <<EOF
#!/bin/sh
set -e
if [ "\$1" = configure ]; then
    $PY -m compileall -q /usr/share/$PKG/ccl >/dev/null 2>&1 || true
    # for every user, from their next login (running sessions: the tray icon syncs meanwhile)
    if command -v systemctl >/dev/null 2>&1; then
        systemctl --global enable ccl-sync.timer >/dev/null 2>&1 || true
    fi
fi
exit 0
EOF
cat > "$ROOT/DEBIAN/prerm" <<EOF
#!/bin/sh
set -e
if [ "\$1" = remove ] && command -v systemctl >/dev/null 2>&1; then
    systemctl --global disable ccl-sync.timer >/dev/null 2>&1 || true
fi
find /usr/share/$PKG -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null || true
exit 0
EOF

find "$ROOT" -type d -exec chmod 755 {} +
find "$ROOT" -type f -exec chmod 644 {} +
chmod 755 "$ROOT"/usr/bin/* "$APP/ccl-sync" "$APP/claude-codex-limits" "$ROOT/DEBIAN/postinst" "$ROOT/DEBIAN/prerm"

SIZE=$(du -sk "$ROOT/usr" | cut -f1)
cat > "$ROOT/DEBIAN/control" <<EOF
Package: $PKG
Version: $VER
Architecture: all
Maintainer: Alex Kovalev <arrivarus@gmail.com>
Installed-Size: $SIZE
Depends: python3 (>= 3.7), python3-pyqt5, python3-dbus
Recommends: pulseaudio-utils | pipewire-bin | alsa-utils
Section: utils
Priority: optional
Homepage: https://github.com/ArrivaRUS/claude-codex-limits
Description: Claude Code and Codex usage limits in the system tray
 Shows the 5-hour and weekly limits of Claude Code and Codex in the tray,
 usage history by day and model with its API-price equivalent, and syncs
 per-machine usage with the macOS app through a private GitHub gist
 (ccl-sync). Linux port of Claude Codex Limits for Astra Linux SE.
EOF

mkdir -p "$OUT"
DEB="$OUT/${PKG}_${VER}_all.deb"
# xz, not zstd: dpkg on Astra 1.7 doesn't read zstd
dpkg-deb --root-owner-group -Zxz --build "$ROOT" "$DEB" >/dev/null
echo "$DEB"
