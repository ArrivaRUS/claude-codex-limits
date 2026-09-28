#!/bin/sh
# Removes the Linux port. Data (settings, usage index, GitHub token) stays unless --purge.
#
#   sh linux/uninstall.sh           # remove programs, timer, autostart
#   sh linux/uninstall.sh --purge   # …and sign out of GitHub, delete settings and the usage index
set -eu

PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1
PY=/usr/bin/python3
DEST="${XDG_DATA_HOME:-$HOME/.local/share}/claude-codex-limits"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}"

if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    systemctl --user disable --now ccl-sync.timer >/dev/null 2>&1 || true
    rm -f "$CONF/systemd/user/ccl-sync.service" "$CONF/systemd/user/ccl-sync.timer"
    systemctl --user daemon-reload || true
fi
if command -v crontab >/dev/null 2>&1 && crontab -l 2>/dev/null | grep -q 'ccl-sync" push'; then
    crontab -l 2>/dev/null | grep -v 'ccl-sync" push' | crontab -
fi
pkill -f "$DEST/claude-codex-limits" 2>/dev/null || true
if [ "$PURGE" = 1 ] && [ -f "$DEST/ccl-sync" ]; then
    "$PY" "$DEST/ccl-sync" logout || true
fi
rm -f "$CONF/autostart/claude-codex-limits.desktop" \
      "${XDG_DATA_HOME:-$HOME/.local/share}/applications/claude-codex-limits.desktop" \
      "$HOME/.local/bin/ccl-sync" "$HOME/.local/bin/claude-codex-limits"
rm -rf "$DEST"
if [ "$PURGE" = 1 ]; then
    rm -rf "$CONF/claude-codex-limits" "${XDG_STATE_HOME:-$HOME/.local/state}/claude-codex-limits"
    echo "Удалено вместе с данными. Gist в GitHub остался — его можно удалить на gist.github.com."
else
    echo "Удалено. Настройки и индекс остались в $CONF/claude-codex-limits и ~/.local/state/claude-codex-limits (--purge — удалить)."
fi
