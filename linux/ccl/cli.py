"""`ccl-sync` — usage collector + GitHub gist sync, one command, no GUI.

    ccl-sync login      sign in to GitHub (Device Flow: prints a code and a link, waits)
    ccl-sync logout     forget the token (the gist stays)
    ccl-sync status     who is signed in, the gist, which machines are in it and when they reported
    ccl-sync push       one pass: index the local logs, write this machine's file, read the others
    ccl-sync dump       per-day, per-model summary of the local logs (to check the numbers)
    ccl-sync update     install the newest Linux version from the repository's main branch
"""

import argparse
import os
import shlex
import subprocess
import sys
import time

from . import APP_VERSION, common, sync, update, vault, usage


def _say(*a):
    print(*a)
    sys.stdout.flush()


def _fmt_time(t):
    if not t:
        return common.tr("никогда", "never")
    lt = time.localtime(t)
    if time.strftime("%Y-%m-%d", lt) == common.today_key():
        return time.strftime("%H:%M", lt)
    return time.strftime("%d.%m %H:%M", lt)


def _progress_printer():
    if not sys.stderr.isatty():
        return None
    last = [0.0]

    def cb(n, total, _path):
        now = time.time()
        if now - last[0] > 0.3 or n + 1 == total:
            last[0] = now
            sys.stderr.write("\r" + common.tr("Индексирую логи: ", "Indexing logs: ") + "%d/%d" % (n + 1, total))
            sys.stderr.flush()
    return cb


def _end_progress(cb):
    if cb:
        sys.stderr.write("\r" + " " * 60 + "\r")
        sys.stderr.flush()


# ---- commands -----------------------------------------------------------------------------

def cmd_login(args):
    st = sync.sync_state()
    login = st.get("login")
    if login and not st.get("revoked") and not args.force:
        _say(common.tr("Уже выполнен вход в GitHub", "Already signed in to GitHub") + (": " + login if login else "")
             + common.tr(". Выйти: ccl-sync logout", ". Sign out: ccl-sync logout"))
        return 0
    attempt = sync.begin_login()
    cancelled = lambda: not sync.is_current(attempt)
    try:
        try:
            dev = sync.device_start()
        except sync.LoginError as e:
            _say(str(e))
            return 1
        url = dev["verification_uri"]
        _say(common.tr("Откройте в браузере:  ", "Open in a browser:  ") + url)
        _say(common.tr("и введите код:        ", "and enter the code:  ") + dev["user_code"])
        _say(common.tr("(доступ нужен только к gist — секретный gist для синхронизации расхода)",
                       "(only gist access is requested — one secret gist for the usage sync)"))
        if not args.no_browser and os.environ.get("DISPLAY"):
            try:
                subprocess.Popen(["xdg-open", url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except OSError:
                pass
        _say(common.tr("Жду подтверждения…", "Waiting for confirmation…"))
        try:
            token = sync.device_poll(dev, cancelled=cancelled)
        except sync.LoginError as e:
            _say(str(e))
            return 1
        try:
            login = sync.login_finish(token, cancelled=cancelled, attempt=attempt)
        except (sync.LoginError, OSError, ValueError) as e:
            _say(common.tr("Не удалось сохранить вход: ", "Couldn't save the sign-in: ") + str(e))
            return 1
        backend = sync.sync_state().get("tokenBackend")
        _say(common.tr("Готово. GitHub: ", "Done. GitHub: ") + (login or "?") + "  ("
             + (common.tr("токен в хранилище секретов", "token in the Secret Service") if backend == "secret-service"
                else common.tr("токен в файле ", "token in file ") + common.TOKEN_FILE_PATH) + ")")
        return cmd_push(argparse.Namespace(force=True, auto=False, quiet=False))
    except KeyboardInterrupt:
        sync.cancel_login(attempt)
        _say(common.tr("Отменено.", "Cancelled."))
        return 130


def cmd_logout(_args):
    try:
        deleted = sync.logout()
    except sync.LoginError as e:
        _say(sync._delete_pending_text() if sync.sign_out_incomplete() else str(e))
        return 1
    if not deleted or sync.delete_pending():
        _say(sync._delete_pending_text())
        return 1
    _say(common.tr("Вход в GitHub удалён с этой машины. Gist остался в GitHub.",
                   "GitHub sign-in removed from this machine. The gist stays on GitHub."))
    _say(common.tr(
        "Вход удаляется только на этом компьютере. Отозвать доступ приложения полностью — github.com/settings/applications",
        "This signs out only this computer. To revoke the app's access entirely, visit github.com/settings/applications"))
    return 0


def cmd_push(args):
    common.ensure_dirs()
    cb = None if args.quiet else _progress_printer()
    t0 = time.time()
    ix, changed, _fresh = usage.refresh(blocking=True, progress=cb)
    _end_progress(cb)
    if not args.quiet:
        n = sum(len(v) for v in ix["days"].values())
        _say(common.tr("Индекс: ", "Index: ") + ("%d " % len(ix["files"])) + common.tr("файлов", "files")
             + ", " + ("%d " % n) + common.tr("дней·продуктов", "product-days")
             + (common.tr(", обновлён", ", updated") if changed else common.tr(", без изменений", ", unchanged"))
             + " (%.1f s)" % (time.time() - t0))
    res = sync.sync_cycle(ix["days"], force=getattr(args, "force", False), auto=getattr(args, "auto", False))
    if res.skipped == "signed-out":
        if not args.quiet:
            _say(common.tr("Синхронизация выключена: нет входа в GitHub (ccl-sync login).",
                           "Sync is off: not signed in to GitHub (ccl-sync login)."))
        return 0
    if res.skipped == "timeout":
        _say(common.tr("Ошибка синхронизации: ", "Sync failed: ") + (res.error or vault.timeout_text()))
        return 1
    if res.skipped == "unreachable":
        sys.stderr.write(common.tr("Хранилище секретов недоступно (нет сессии D-Bus) — токен GitHub не прочитать.\n",
                                   "The Secret Service is unreachable (no D-Bus session) — can't read the GitHub token.\n"))
        return 3
    if res.skipped == "locked":
        if not args.quiet:
            _say(common.tr("Хранилище секретов (KWallet) заблокировано — синхронизация подождёт до разблокировки.",
                           "The Secret Service (KWallet) is locked — sync waits until it is unlocked."))
        return 0
    if res.skipped == "revoked":
        _say(common.tr("Войдите в GitHub заново: ccl-sync login", "Sign in to GitHub again: ccl-sync login"))
        return 2
    if res.skipped == "backoff":
        if not args.quiet:
            until = sync.sync_state().get("backoffUntil")
            _say(common.tr("GitHub просил подождать — пропускаю до ", "GitHub asked to back off — skipping until ")
                 + _fmt_time(until))
        return 0
    if res.skipped == "busy":
        if not args.quiet:
            _say(common.tr("Синхронизация уже идёт в другом процессе.", "A sync is already running in another process."))
        return 0
    if not res.ok:
        _say(common.tr("Ошибка синхронизации: ", "Sync failed: ") + str(res.error))
        if sync.sync_state().get("revoked"):
            _say(common.tr("Войдите в GitHub заново: ccl-sync login", "Sign in to GitHub again: ccl-sync login"))
            return 2
        return 1
    if not args.quiet:
        _say((common.tr("Отправлено в gist.", "Written to the gist.") if res.pushed
              else common.tr("В gist без изменений.", "Gist unchanged.")))
        others = res.remote.get("machines", [])
        if others:
            _say(common.tr("Другие машины: ", "Other machines: ") + ", ".join(
                "%s (%s)" % (m["name"], _fmt_time(m.get("updated"))) for m in others))
        else:
            _say(common.tr("Других машин в gist пока нет.", "No other machines in the gist yet."))
    return 0


def _timer_status():
    try:
        r = subprocess.run(["systemctl", "--user", "is-active", "ccl-sync.timer"],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5)
        s = r.stdout.decode().strip()
        if s == "active":
            return common.tr("systemd --user, каждые 10 мин", "systemd --user, every 10 min")
    except (OSError, subprocess.SubprocessError):
        pass
    try:
        r = subprocess.run(["crontab", "-l"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5)
        if b"ccl-sync" in r.stdout:
            return common.tr("cron, каждые 10 мин", "cron, every 10 min")
    except (OSError, subprocess.SubprocessError):
        pass
    return common.tr("не установлен (см. linux/install.sh)", "not installed (see linux/install.sh)")


def cmd_status(_args):
    st = sync.sync_state()
    token, backend, gist = None, None, None
    with common.file_lock("sync", blocking=False) as held:
        if held:
            st.reload()
            if st.get("login") and not st.get("revoked"):
                token, backend = vault.read()
                if token and st.get("gistId"):
                    g = sync.gh("/gists/" + st.get("gistId"), token)
                    if g.status == 200:
                        gist = g.json()
    pending = sync.sign_out_incomplete(st)
    _say("Claude Codex Limits (linux %s)" % APP_VERSION)
    _say(common.tr("Эта машина: ", "This machine: ") + "%s · %s · id %s" % (
        common.machine_name(), common.os_name(), common.machine_id()))
    if pending:
        _say(sync._delete_pending_text())
        _say(common.tr("Повторить выход: ccl-sync logout", "Retry sign-out: ccl-sync logout"))
    elif st.get("revoked"):
        _say("GitHub: " + common.tr("вход отозван — войдите заново (ccl-sync login)",
                                    "sign-in revoked — sign in again (ccl-sync login)"))
    elif token:
        _say("GitHub: %s  (%s)" % (st.get("login") or "?", common.tr("токен: ", "token: ") + (
            common.tr("хранилище секретов", "Secret Service") if backend == "secret-service" else common.TOKEN_FILE_PATH)))
    elif backend == "locked":
        _say("GitHub: " + common.tr("токен в заблокированном хранилище секретов — разблокируйте KWallet",
                                    "token is in a locked Secret Service — unlock KWallet"))
    elif backend in ("timeout", "unreachable"):
        _say("GitHub: " + (vault.timeout_text() if backend == "timeout" else common.tr(
            "Хранилище секретов недоступно", "The Secret Service is unreachable"))
             + common.tr(" — синхронизация повторит попытку сама", " — sync will try again by itself"))
    elif not held and st.get("login"):
        _say("GitHub: " + st.get("login"))
    else:
        _say("GitHub: " + common.tr("вход не выполнен (ccl-sync login)", "not signed in (ccl-sync login)"))
    _say(common.tr("Автосинхронизация: ", "Auto sync: ") + _timer_status())
    gid = st.get("gistId")
    if gid:
        _say("Gist: https://gist.github.com/%s  (%s)" % (gid, common.tr("секретный", "secret")))
    _say(common.tr("Последняя отправка: ", "Last upload: ") + _fmt_time(st.get("pushedAt"))
         + " · " + common.tr("чтение: ", "read: ") + _fmt_time(sync.last_ok_at(st)))
    _say(common.tr("Последняя попытка: ", "Last attempt: ") + _fmt_time(st.get("lastAttemptAt")))
    if st.get("lastError"):
        at = st.get("lastErrorAt")
        _say(common.tr("Последняя ошибка", "Last error") + (" (%s)" % _fmt_time(at) if at else "") + ": "
             + str(st.get("lastError")))
    warn = None if pending else sync.warning(st, moment=_fmt_time, require_attempt=False)
    if warn:
        _say("! " + warn)

    if not held:
        _say(common.tr("Синхронизация идёт в другом процессе — показан кэш",
                       "Sync is running in another process — showing cached machines"))
    machines = None
    if isinstance(gist, dict) and isinstance(gist.get("files"), dict):
        machines = []
        import json
        for name, f in sorted(gist["files"].items()):
            if not (name.startswith("machine-") and name.endswith(".json")) or not isinstance(f, dict):
                continue
            try:
                obj = json.loads(f.get("content") or "")
            except (ValueError, TypeError, RecursionError):
                continue
            if not isinstance(obj, dict) or not isinstance(obj.get("machine"), dict):
                continue
            m = obj["machine"]
            if any(not isinstance(m.get(k, ""), str) for k in ("name", "os", "app")):
                continue
            machines.append((m.get("name") or "?", m.get("os", ""), m.get("app", ""),
                             common.parse_iso(obj.get("updated")), m.get("id") == common.machine_id()))
    if machines is None:
        machines = [(m["name"], m.get("os", ""), m.get("app", ""), m.get("updated"), False)
                    for m in sync.load_remote().get("machines", [])]
        if machines:
            _say(common.tr("Машины (по последней синхронизации):", "Machines (as of the last sync):"))
    else:
        _say(common.tr("Машины в gist:", "Machines in the gist:"))
    for name, osn, app, upd, me in machines:
        _say("  • %s%s — %s%s" % (name, common.tr(" (эта)", " (this one)") if me else "",
                                  (osn + ", " + app + ", ") if osn else "",
                                  common.tr("обновлён ", "updated ") + _fmt_time(upd)))
    ix = usage.load_index()
    _say(common.tr("Индекс: ", "Index: ") + "%d %s · %s" % (
        len(ix["files"]), common.tr("файлов", "files"), common.USAGE_INDEX_PATH))
    return 0


def _n(v):
    return "{:,}".format(v).replace(",", " ")


def cmd_dump(args):
    if not args.no_scan:
        cb = _progress_printer()
        ix, _changed, _fresh = usage.refresh(blocking=True, progress=cb)
        _end_progress(cb)
    else:
        ix = usage.load_index()
    days = ix["days"]
    if args.merged:
        days = usage.merge_days(days, sync.load_remote().get("days", {}))
    products = [args.product] if args.product else ["claude", "codex"]
    keys = usage.last_days(args.days)
    if args.json:
        import json
        out = {p: {d: days.get(p, {}).get(d, {}) for d in keys if days.get(p, {}).get(d)} for p in products}
        print(json.dumps(out, indent=2, sort_keys=True))
        return 0
    hdr = "  %-26s %10s %10s %14s %11s %11s %6s %9s" % (
        "model", "input", "output", "cacheRead", "cacheW5m", "cacheW1h", "turns", "$ API")
    for p in products:
        _say("== %s ==" % p)
        any_day = False
        for d in keys:
            models = days.get(p, {}).get(d)
            if not models:
                continue
            any_day = True
            _say(d)
            _say(hdr)
            tot = usage.empty_usage()
            usd = 0.0
            for m in sorted(models, key=lambda m: -(usage.api_cost(m, models[m]) or 0)):
                u = models[m]
                c = usage.api_cost(m, u)
                usd += c or 0
                for k in usage.FIELDS:
                    tot[k] += u[k]
                _say("  %-26s %10s %10s %14s %11s %11s %6d %9s" % (
                    m[:26], _n(u["input"]), _n(u["output"]), _n(u["cacheRead"]), _n(u["cacheWrite5m"]),
                    _n(u["cacheWrite1h"]), u["turns"], ("%.2f" % c) if c is not None else "—"))
            if len(models) > 1:
                _say("  %-26s %10s %10s %14s %11s %11s %6d %9s" % (
                    common.tr("итого", "total"), _n(tot["input"]), _n(tot["output"]), _n(tot["cacheRead"]),
                    _n(tot["cacheWrite5m"]), _n(tot["cacheWrite1h"]), tot["turns"], "%.2f" % usd))
        if not any_day:
            _say(common.tr("  нет данных за эти дни", "  no data for these days"))
    return 0


def cmd_update(args):
    latest, err = update.check()
    if latest is None:
        _say(common.tr("Проверить обновление не удалось: ", "Couldn't check for updates: ") + str(err))
        return 1
    if not update.is_newer(latest, APP_VERSION):
        _say(common.tr("Установлена последняя версия: ", "Up to date: ") + APP_VERSION)
        return 0
    _say(common.tr("Доступна версия ", "Version available: ") + latest + common.tr(" (установлена ", " (installed ") + APP_VERSION + ")")
    _say(common.tr("Что нового: ", "What's new: ") + update.changes_url())
    if args.check:
        return 0
    if update.is_packaged():
        try:
            _ver, path = update.fetch_deb()
        except RuntimeError as e:
            _say(str(e))
            return 1
        _say(common.tr("Пакет скачан: ", "Package downloaded: ") + path)
        _say(common.tr("Установите его (нужен пароль администратора):", "Install it (needs the administrator password):"))
        _say("  sudo apt install " + shlex.quote(path))
        _say(common.tr("или откройте файл двойным щелчком. Значок в трее перезапустится сам.",
                       "or open the file with a double click. The tray icon restarts by itself."))
        return 0
    try:
        new, _out = update.apply()
    except RuntimeError as e:
        _say(str(e))
        return 1
    _say(common.tr("Обновлено до ", "Updated to ") + new + common.tr(
        ". Значок в трее перезапустится сам при следующем входе — или перезапустите его сейчас.",
        ". The tray icon picks it up at next login — or restart it now."))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(prog="ccl-sync", description=common.tr(
        "Сборщик расхода Claude Code / Codex и синхронизация через GitHub gist.",
        "Claude Code / Codex usage collector and GitHub gist sync."))
    ap.add_argument("--version", action="version", version="ccl-sync (linux) " + APP_VERSION)
    sub = ap.add_subparsers(dest="cmd")
    p = sub.add_parser("login", help=common.tr("войти в GitHub (Device Flow)", "sign in to GitHub (Device Flow)"))
    p.add_argument("--no-browser", action="store_true", help=common.tr("не открывать браузер", "don't open a browser"))
    p.add_argument("--force", action="store_true", help=common.tr("войти заново", "sign in again"))
    sub.add_parser("logout", help=common.tr("выйти из GitHub", "sign out of GitHub"))
    sub.add_parser("status", help=common.tr("состояние синхронизации", "sync status"))
    p = sub.add_parser("push", help=common.tr("один проход: индекс → gist", "one pass: index → gist"))
    p.add_argument("--force", action="store_true", help=common.tr("записать даже без изменений", "write even if unchanged"))
    p.add_argument("--auto", action="store_true", help=common.tr("режим таймера (не чаще раза в 10 мин)",
                                                                  "timer mode (at most every 10 min)"))
    p.add_argument("--quiet", "-q", action="store_true")
    p = sub.add_parser("dump", help=common.tr("сводка по дням и моделям", "per-day, per-model summary"))
    p.add_argument("--days", type=int, default=7)
    p.add_argument("--product", choices=["claude", "codex"])
    p.add_argument("--merged", action="store_true", help=common.tr("вместе с другими машинами из gist",
                                                                    "together with the other machines from the gist"))
    p.add_argument("--no-scan", action="store_true", help=common.tr("без переиндексации", "don't rescan"))
    p.add_argument("--json", action="store_true")
    p = sub.add_parser("update", help=common.tr("обновить Linux-версию из GitHub", "update the Linux port from GitHub"))
    p.add_argument("--check", action="store_true", help=common.tr("только проверить", "only check"))
    args = ap.parse_args(argv)
    if not args.cmd:
        ap.print_help()
        return 0
    if args.cmd == "push" and args.auto and not sync.sync_state().has("login"):
        # The .deb enables the timer for every user of the machine; for those who never signed
        # in to GitHub it has nothing to do — leave their home folder alone.
        return 0
    common.ensure_dirs()
    return {"login": cmd_login, "logout": cmd_logout, "status": cmd_status,
            "push": cmd_push, "dump": cmd_dump, "update": cmd_update}[args.cmd](args)
