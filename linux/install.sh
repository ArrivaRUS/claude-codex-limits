#!/bin/sh
# Claude Codex Limits — Linux port installer (Astra Linux SE and other desktop Linux).
# Installs for the current user only: nothing outside $HOME, no sudo.
#
#   sh linux/install.sh                 # everything: ccl-sync, tray app, 10-minute timer, autostart
#   sh linux/install.sh --no-autostart  # don't start the tray app at login
#   sh linux/install.sh --no-timer      # don't install the systemd/cron timer
set -eu

AUTOSTART=1
TIMER=1
for a in "$@"; do
    case "$a" in
        --no-autostart) AUTOSTART=0 ;;
        --no-timer) TIMER=0 ;;
        -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
        *) echo "unknown option: $a" >&2; exit 2 ;;
    esac
done

SRC=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$SRC")
PY=/usr/bin/python3
DEST="${XDG_DATA_HOME:-$HOME/.local/share}/claude-codex-limits"
BIN="$HOME/.local/bin"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}"

say() { printf '%s\n' "$*"; }

[ -x "$PY" ] || { say "Нужен системный Python 3 ($PY)."; exit 1; }
"$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 7) else 1)' || { say "Нужен Python 3.7 или новее."; exit 1; }
if "$PY" -c 'import PyQt5.QtWidgets' 2>/dev/null; then GUI=1; else
    GUI=0
    say "PyQt5 не найден — ставлю только ccl-sync. Для значка в трее: sudo apt install python3-pyqt5"
fi

say "Копирую в $DEST"
mkdir -p "$DEST/Resources" "$BIN"
rm -rf "$DEST/ccl"
cp -r "$SRC/ccl" "$DEST/"
cp "$SRC/ccl-sync" "$SRC/claude-codex-limits" "$DEST/"
cp "$REPO"/Resources/*.png "$REPO"/Resources/*.wav "$DEST/Resources/"
find "$DEST" -name __pycache__ -type d -prune -exec rm -rf {} +

# Wrappers run the scripts through the system interpreter explicitly — the variant that works
# under Astra's interpreter control, and needs no exec bit on the scripts themselves.
for name in ccl-sync claude-codex-limits; do
    printf '#!/bin/sh\nexec %s "%s/%s" "$@"\n' "$PY" "$DEST" "$name" > "$BIN/$name"
    chmod 755 "$BIN/$name" 2>/dev/null || say "Не удалось сделать $BIN/$name исполняемым — запускайте: $PY $DEST/$name"
done

# application menu entry
mkdir -p "${XDG_DATA_HOME:-$HOME/.local/share}/applications"
DESKTOP_ENTRY="[Desktop Entry]
Type=Application
Name=Claude Codex Limits
Comment=Лимиты Claude Code и Codex в трее
Exec=$PY \"$DEST/claude-codex-limits\"
Icon=$DEST/Resources/appicon.png
Terminal=false
Categories=Utility;Development;
"
printf '%s' "$DESKTOP_ENTRY" > "${XDG_DATA_HOME:-$HOME/.local/share}/applications/claude-codex-limits.desktop"

if [ "$GUI" = 1 ] && [ "$AUTOSTART" = 1 ]; then
    mkdir -p "$CONF/autostart"
    printf '%sX-GNOME-Autostart-enabled=true\nX-KDE-autostart-after=panel\n' "$DESKTOP_ENTRY" > "$CONF/autostart/claude-codex-limits.desktop"
    say "Автозапуск значка: $CONF/autostart/claude-codex-limits.desktop"
fi

if [ "$TIMER" = 1 ]; then
    if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
        UNITS="$CONF/systemd/user"
        mkdir -p "$UNITS"
        cat > "$UNITS/ccl-sync.service" <<EOF
[Unit]
Description=Claude Codex Limits — index local usage logs and sync through the GitHub gist
After=network-online.target

[Service]
Type=oneshot
ExecStart=$PY "$DEST/ccl-sync" push --auto --quiet
Nice=10
IOSchedulingClass=idle
EOF
        cat > "$UNITS/ccl-sync.timer" <<EOF
[Unit]
Description=Claude Codex Limits sync every 10 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=10min
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF
        systemctl --user daemon-reload
        systemctl --user enable --now ccl-sync.timer >/dev/null 2>&1
        say "Таймер: systemd --user (ccl-sync.timer), каждые 10 минут"
    elif command -v crontab >/dev/null 2>&1; then
        # cron has no session bus; point it at the user's one so the keyring stays reachable
        LINE="*/10 * * * * DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\$(id -u)/bus $PY \"$DEST/ccl-sync\" push --auto --quiet >/dev/null 2>&1"
        ( crontab -l 2>/dev/null | grep -v 'ccl-sync" push' ; printf '%s\n' "$LINE" ) | crontab -
        say "Таймер: cron, каждые 10 минут"
    else
        say "Ни systemd --user, ни cron не найдены — синхронизация только пока запущен значок в трее."
    fi
fi

say ""
say "Готово. Дальше:"
say "  ccl-sync login      — войти в GitHub (один раз), затем расход этой машины увидит Mac"
say "  ccl-sync status     — кто вошёл и какие машины в gist"
[ "$GUI" = 1 ] && say "  claude-codex-limits & — значок в трее (или через меню приложений)"
case ":$PATH:" in *":$BIN:"*) ;; *) say "Внимание: $BIN нет в PATH — добавьте его или запускайте $PY $DEST/ccl-sync" ;; esac
