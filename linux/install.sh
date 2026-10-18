#!/bin/sh
# Claude Codex Limits — Linux port installer (Astra Linux SE and other desktop Linux).
# Installs for the current user only: nothing outside $HOME, no sudo.
#
#   sh linux/install.sh                 # everything: ccl-sync, tray app, 10-minute timer, autostart
#   sh linux/install.sh --no-autostart  # don't start the tray app at login
#   sh linux/install.sh --no-timer      # don't install the systemd/cron timer
#   sh linux/install.sh --publisher --no-tray --name vps
#                                       # headless limits publisher: 5-minute timer, token policy `never`,
#                                       # machine tag <name> ([a-z0-9-], 1-16 chars, required); refuses while
#                                       # this user's tray app runs; --no-tray: no menu entry, no autostart
set -eu

AUTOSTART=1
TIMER=1
TRAY=1
PUBLISHER=0
NAME=
NAME_SET=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --no-autostart) AUTOSTART=0 ;;
        --no-timer) TIMER=0 ;;
        --no-tray) TRAY=0; AUTOSTART=0 ;;
        --publisher) PUBLISHER=1 ;;
        --name)
            [ "$#" -ge 2 ] || { echo "--name: нужен тег машины, например --name vps" >&2; exit 2; }
            NAME=$2; NAME_SET=1; shift ;;
        --name=*) NAME=${1#--name=}; NAME_SET=1 ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

SRC=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$SRC")
PY=/usr/bin/python3
DEST="${XDG_DATA_HOME:-$HOME/.local/share}/claude-codex-limits"
BIN="$HOME/.local/bin"
CONF="${XDG_CONFIG_HOME:-$HOME/.config}"

say() { printf '%s\n' "$*"; }

# ---- checks that come before any write: --name, a running tray (A4) ----
if [ "$NAME_SET" = 1 ] && [ "$PUBLISHER" = 0 ]; then
    say "--name задаёт тег издателя и используется только вместе с --publisher."
    exit 2
fi
if [ "$PUBLISHER" = 1 ]; then
    if [ "$NAME_SET" = 0 ]; then
        # A desktop hostname is often <user>-<model>: the public tag in the gist is chosen explicitly (A1 N7).
        say "Для --publisher нужен --name <тег> — короткое имя машины в gist (например --name vps)."
        exit 2
    fi
    case "$NAME" in
        ""|-*|*-|*[!abcdefghijklmnopqrstuvwxyz0123456789-]*) NAME_OK=0 ;;
        *) NAME_OK=1 ;;
    esac
    if [ "$NAME_OK" = 0 ] || [ "${#NAME}" -gt 16 ]; then
        say "--name: тег из строчных латинских букв, цифр и дефиса, 1–16 символов (например vps, macbook, alse)."
        exit 2
    fi
fi
UID_NUM=$(id -u)
if [ "$PUBLISHER" = 1 ]; then
    # A tray of this user (0.4.x included) polls on its own and may hold an unfinished token rotation.
    # Refuse instead of stopping or restarting it: the owner stops it first (T1 П3-б.3).
    # The process running this installer and its ancestors are not "another tray": the tray's own
    # update (gui/app.py → update.apply → sh install.sh) runs it from inside the tray process.
    TRAY_PATTERN='(^|[/ ])claude-codex-limits( |$)'
    SELF_PIDS=" "
    p=$$
    n=0
    while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null && [ "$n" -lt 64 ]; do
        SELF_PIDS="$SELF_PIDS$p "
        p=$(sed -n 's/^PPid:[[:space:]]*//p' "/proc/$p/status" 2>/dev/null || true)
        n=$((n + 1))
    done
    set +e
    TRAY_PIDS=$(pgrep -u "$UID_NUM" -f "$TRAY_PATTERN" 2>/dev/null)
    TRAY_RC=$?
    set -e
    OTHER_TRAY=0
    for pid in $TRAY_PIDS; do
        case "$SELF_PIDS" in *" $pid "*) ;; *) OTHER_TRAY=1 ;; esac
    done
    if [ "$TRAY_RC" = 127 ]; then
        say "Не найдена программа pgrep — не могу проверить, запущен ли значок в трее. Установите procps"
        say "(sudo apt install procps) и запустите установку снова."
        exit 3
    elif [ "$TRAY_RC" != 0 ] && [ "$TRAY_RC" != 1 ]; then
        say "Не удалось проверить, запущен ли значок в трее (pgrep, код $TRAY_RC). Если он запущен, остановите его:"
        say "  pkill -u $UID_NUM -f '$TRAY_PATTERN'"
        exit 3
    elif [ "$OTHER_TRAY" = 1 ]; then
        say "Запущен значок в трее Claude Codex Limits этого пользователя — с ним издатель включать нельзя."
        say "Остановите значок и запустите установку снова. Команда остановки:"
        say "  pkill -u $UID_NUM -f '$TRAY_PATTERN'"
        exit 3
    fi
fi

[ -x "$PY" ] || { say "Нужен системный Python 3 ($PY)."; exit 1; }
"$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 7) else 1)' || { say "Нужен Python 3.7 или новее."; exit 1; }
if [ "$TRAY" = 0 ]; then
    GUI=0
elif "$PY" -c 'import PyQt5.QtWidgets' 2>/dev/null; then
    GUI=1
else
    GUI=0
    say "PyQt5 не найден — ставлю только ccl-sync. Для значка в трее: sudo apt install python3-pyqt5"
fi

if [ -d /usr/share/claude-codex-limits ]; then
    say "Внимание: уже установлен пакет claude-codex-limits (.deb). Эта копия в домашнем каталоге будет его"
    say "перекрывать; обычно достаточно пакета. Удалить эту копию потом: sh linux/uninstall.sh"
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
shell_quote() {
    "$PY" -I -B -c 'import shlex, sys; print(shlex.quote(sys.argv[1]))' "$1"
}
for name in ccl-sync claude-codex-limits; do
    SCRIPT=$(shell_quote "$DEST/$name")
    printf '#!/bin/sh\nexec %s %s "$@"\n' "$PY" "$SCRIPT" > "$BIN/$name"
    chmod 755 "$BIN/$name" 2>/dev/null || say "Не удалось сделать $BIN/$name исполняемым — запускайте: $PY $DEST/$name"
done

# Keep the tray choice for ordinary installations too, so updates preserve --no-tray.
# Settings through the installed code: under the `quota` lock; publisher policy changes
# also use the rotation guard, like `ccl-sync publisher --enable`. Other keys are kept.
if ! "$PY" -I -B - "$DEST" "$NAME" "$TRAY" "$PUBLISHER" <<'PYEOF'
import sys
sys.path.insert(0, sys.argv[1])
from ccl import common, vault
try:
    with common.file_lock("quota", timeout=60) as held:
        if not held:
            print("Значок или издатель сейчас заняты попыткой (замок quota) — повторите установку позже.")
            sys.exit(1)
        from contextlib import nullcontext
        with vault.token_policy_guard() if sys.argv[4] == "1" else nullcontext():
            settings = common.settings()
            settings.reload()
            changes = dict(tray=sys.argv[3] == "1")
            if sys.argv[4] == "1":
                first = settings.get("publisher") is not True
                common.set_credential_write("never")
                changes.update(publisher=True, credential_write="never", machineName=sys.argv[2])
                if first:
                    # Auto mode only on first enable; reinstall/update keeps publisher --mode.
                    changes["autoPoll"] = True
            settings.update(**changes)
        if sys.argv[4] == "1" and vault.publisher_secret_service(common.Store(common.SYNC_STATE_PATH)):
            # Installer output is always Russian, regardless of the saved UI language.
            print("Внимание: токен GitHub в хранилище секретов, а издатель хранит его только в файле. Ничего не перенесено: "
                  "выполните ccl-sync logout там, где хранилище разблокировано, затем ccl-sync login")
except common.CredentialPolicyRefused as e:
    print("Политику токенов сейчас сменить нельзя: %s" % e)
    sys.exit(1)
except OSError:
    print("Не удалось сохранить настройки; проверьте права на ~/.config/claude-codex-limits и каталог состояния.")
    sys.exit(1)
PYEOF
then
    if [ "$PUBLISHER" = 1 ]; then
        say "Настройки не записаны — таймер не устанавливаю."
        exit 1
    fi
    say "Выбор «без значка» может не сохраниться для ccl-sync update — повторите установку позже."
fi
if [ "$PUBLISHER" = 1 ]; then
    say "Издатель: включён, тег машины $NAME, политика токенов never"
fi

if [ "$TRAY" = 0 ]; then
    # --no-tray also removes the menu entry and autostart of an earlier install (as uninstall.sh does):
    # a leftover autostart would start the tray again at the next login.
    rm -f "$CONF/autostart/claude-codex-limits.desktop" \
          "${XDG_DATA_HOME:-$HOME/.local/share}/applications/claude-codex-limits.desktop"
else
    # application menu entry
    mkdir -p "${XDG_DATA_HOME:-$HOME/.local/share}/applications"
    DESKTOP_ENTRY="[Desktop Entry]
Type=Application
Name=Claude Codex Limits
Comment=Лимиты Claude Code и Codex в трее
Exec=$PY \"$DEST/claude-codex-limits\"
Icon=$DEST/Resources/appicon.png
Terminal=false
Categories=Utility;
"
    printf '%s' "$DESKTOP_ENTRY" > "${XDG_DATA_HOME:-$HOME/.local/share}/applications/claude-codex-limits.desktop"

    if [ "$GUI" = 1 ] && [ "$AUTOSTART" = 1 ]; then
        mkdir -p "$CONF/autostart"
        printf '%sX-GNOME-Autostart-enabled=true\nX-KDE-autostart-after=panel\n' "$DESKTOP_ENTRY" > "$CONF/autostart/claude-codex-limits.desktop"
        say "Автозапуск значка: $CONF/autostart/claude-codex-limits.desktop"
    fi
fi

# `systemctl --user` needs the user's runtime directory; a session without one (ssh, su) gets it only if it exists.
if [ -z "${XDG_RUNTIME_DIR:-}" ] && [ -d "/run/user/$UID_NUM" ]; then
    XDG_RUNTIME_DIR="/run/user/$UID_NUM"
    export XDG_RUNTIME_DIR
fi
if [ "$PUBLISHER" = 1 ]; then MINUTES=5; else MINUTES=10; fi

if [ "$TIMER" = 1 ]; then
    if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
        UNITS="$CONF/systemd/user"
        mkdir -p "$UNITS"
        # ExecStart has its own C quoting, % specifiers and $ environment expansion;
        # shell quoting is not sufficient. Store the literal path directly in the unit.
        SYSTEMD_SCRIPT=$("$PY" -I -B -c '
import sys
p = sys.argv[1].replace("\\", "\\\\").replace("\"", "\\\"")
p = p.replace("%", "%%").replace("$", "$$")
p = p.replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")
print("\"" + p + "\"")
' "$DEST/ccl-sync")
        cat > "$UNITS/ccl-sync.service" <<EOF
[Unit]
Description=Claude Codex Limits — index local usage logs and sync through the GitHub gist
After=network-online.target

[Service]
Type=oneshot
ExecStart=$PY $SYSTEMD_SCRIPT push --auto --quiet
# Finite, and above the worst pass (lock waits, 60 s of reads, provider requests): a stuck pass is
# stopped and the next tick runs. Not 300 s — that would cut ordinary slow passes.
TimeoutStartSec=20min
Nice=10
IOSchedulingClass=idle
EOF
        cat > "$UNITS/ccl-sync.timer" <<EOF
[Unit]
Description=Claude Codex Limits sync every $MINUTES minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=${MINUTES}min
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF
        systemctl --user daemon-reload || true
        if systemctl --user enable --now ccl-sync.timer >/dev/null 2>&1; then
            say "Таймер: systemd --user (ccl-sync.timer), каждые $MINUTES минут"
        else
            say "Не удалось включить ccl-sync.timer — синхронизация будет идти, пока запущен значок в трее."
        fi
    elif command -v crontab >/dev/null 2>&1; then
        # cron has no session bus; point it at the user's one so the keyring stays reachable
        SCRIPT=$(shell_quote "$DEST/ccl-sync")
        # cron processes % even inside shell quotes. Escape it after shell quoting.
        LINE=$(printf '%s\n' "*/$MINUTES * * * * DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\$(id -u)/bus $PY $SCRIPT push --auto --quiet >/dev/null 2>&1" | sed 's/%/\\%/g')
        ( crontab -l 2>/dev/null | grep -v -E "ccl-sync[\"']? push" || true
          printf '%s\n' "$LINE" ) | crontab -
        say "Таймер: cron, каждые $MINUTES минут"
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
