"""`ccl-sync` — usage collector + GitHub gist sync, one command, no GUI.

    ccl-sync login      sign in to GitHub (Device Flow: prints a code and a link, waits)
    ccl-sync logout     forget the token (the gist stays)
    ccl-sync status     who is signed in, the gist, which machines are in it and when they reported
    ccl-sync credentials --write never|guarded   set the token write policy
    ccl-sync publisher --enable|--disable|--now|--status   control the headless publisher
    ccl-sync publisher --products claude[,codex] | --mode auto | --mode fixed <seconds>
    ccl-sync push       one pass: index the local logs, write this machine's file, read the others
    ccl-sync dump       per-day, per-model summary of the local logs (to check the numbers)
    ccl-sync update     install the newest Linux version from the repository's main branch
"""

import argparse
import json
import math
import os
import re
import shlex
import subprocess
import sys
import time

from . import APP_VERSION, common, sync, update, vault, usage, accounts, polling


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
    presentation = sync.auth_snapshot(st)
    needs_login = (presentation.get("kind") in ("actionRequired", "signedOut") or
                   presentation.get("reason") in ("lost_result", "refresh_expired", "refresh_invalid",
                                                   "missing", "incomplete_response", "identity_changed"))
    if login and not st.get("revoked") and not needs_login and not args.force:
        _say(common.tr("Уже выполнен вход в GitHub", "Already signed in to GitHub") + (": " + login if login else "")
             + common.tr(". Выйти: ccl-sync logout", ". Sign out: ccl-sync logout"))
        return 0
    try:
        attempt = sync.begin_login()
    except sync.LoginError as e:
        _say(str(e))
        return 1
    cancelled = lambda: not sync.is_current(attempt)
    try:
        try:
            dev = sync.device_start(attempt=attempt)
        except sync.LoginError as e:
            _say(str(e))
            return 1
        url = dev["verification_uri"]
        _say(common.tr("Откройте в браузере:  ", "Open in a browser:  ") + url)
        _say(common.tr("и введите код:        ", "and enter the code:  ") + dev["user_code"])
        _say(common.tr("(доступ к gist и автоматическое продление входа для синхронизации расхода)",
                       "(gist access and automatic sign-in renewal are requested)"))
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
        backend = sync.auth_snapshot().get("backend") or sync.sync_state().get("tokenBackend")
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
    settings = common.settings()
    settings.reload()
    if settings.get("publisher") is True:
        return _publisher_pass("auto" if getattr(args, "auto", False) else "manual", quiet=args.quiet)
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
    if not res.ok and not getattr(res, "partial", False):
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


_SPAN = re.compile(r"(\d+)\s*(s|sec|m|min)?")


def _timer_minutes():
    """OnUnitActiveSec of the ccl-sync.timer that systemd loads (the user's unit wins), in whole minutes.
    No readable unit: install.sh writes 5 min for a publisher, the .deb ships 10 min."""
    conf = os.environ.get("XDG_CONFIG_HOME") or os.path.join(common.HOME, ".config")
    for d in (os.path.join(conf, "systemd", "user"), "/etc/systemd/user", "/usr/lib/systemd/user",
              "/lib/systemd/user"):
        try:
            with open(os.path.join(d, "ccl-sync.timer"), encoding="utf-8") as f:
                text = f.read(64 * 1024)
        except (OSError, UnicodeDecodeError):
            continue
        for line in text.splitlines():
            key, _, value = line.partition("=")
            m = _SPAN.fullmatch(value.strip()) if key.strip() == "OnUnitActiveSec" else None
            if m:
                seconds = int(m.group(1)) * (60 if m.group(2) in ("m", "min") else 1)
                if seconds >= 60 and seconds % 60 == 0:
                    return seconds // 60
        break
    return 5 if common.settings().get("publisher") is True else 10


def _timer_status():
    try:
        r = subprocess.run(["systemctl", "--user", "is-active", "ccl-sync.timer"],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5)
        s = r.stdout.decode().strip()
        if s == "active":
            minutes = _timer_minutes()
            return common.tr("systemd --user, каждые %d мин" % minutes, "systemd --user, every %d min" % minutes)
    except (OSError, subprocess.SubprocessError):
        pass
    try:
        r = subprocess.run(["crontab", "-l"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5)
        line = next((ln for ln in r.stdout.decode("utf-8", "replace").splitlines() if "ccl-sync" in ln), None)
        if line is not None:
            m = re.match(r"\s*\*/(\d+)\s", line)
            minutes = int(m.group(1)) if m else 10
            return common.tr("cron, каждые %d мин" % minutes, "cron, every %d min" % minutes)
    except (OSError, subprocess.SubprocessError):
        pass
    return common.tr("не установлен (см. linux/install.sh)", "not installed (see linux/install.sh)")


def _journal_counts(now):
    """24 h counters from the publisher's O1 journal: per product (requests, 429) and failed publications."""
    counts = {"claude": [0, 0], "codex": [0, 0], "failed": 0}
    try:
        with open(os.path.join(common.STATE_DIR, "publisher.jsonl"), "rb") as f:
            data = f.read(2 * 1024 * 1024)       # rotation keeps the journal ≤ 1 MiB
    except OSError:
        return counts
    for line in data.splitlines():
        try:
            rec = json.loads(line)
        except (ValueError, RecursionError):
            continue
        if not isinstance(rec, dict):
            continue
        ts = common.parse_iso(rec.get("ts"))
        if ts is None or not now - 86400 < ts <= now:
            continue
        ev, product = rec.get("ev"), rec.get("product")
        if ev == "poll_attempt" and product in ("claude", "codex"):
            counts[product][0] += 1
        elif (ev == "poll_result" and product in ("claude", "codex") and type(rec.get("httpStatus")) is int
              and rec["httpStatus"] == 429):
            counts[product][1] += 1
        elif ev == "publish" and rec.get("result") == "failed":
            counts["failed"] += 1
    return counts


def _say_o2(st):
    """Publisher diagnostics (O2): state directory, 24 h counters, clock skew. Numbers and paths only."""
    _say(common.tr("Каталог состояния: ", "State directory: ") + common.STATE_DIR)
    counts = _journal_counts(time.time())
    for product, title in (("claude", "Claude"), ("codex", "Codex")):
        _say(title + common.tr(" · за 24 ч: запросов %d, 429 — %d", " · last 24 h: requests %d, 429 %d")
             % tuple(counts[product]))
    _say(common.tr("Публикации · за 24 ч: неудачных %d", "Publications · last 24 h: failed %d") % counts["failed"])
    skew = st.get("clockSkew")
    if polling.number(skew):
        _say(common.tr("Расхождение часов с GitHub: %d с", "Clock skew vs GitHub: %d s") % int(round(skew)))


def cmd_credentials(args):
    try:
        common.set_credential_write(args.write)
    except common.CredentialPolicyRefused as e:
        _say(common.tr("Смена политики токенов отклонена; дождитесь завершения попытки или ротации: ",
                       "Token policy change refused; wait for the attempt or rotation to finish: ") + str(e))
        return 1
    except OSError:
        _say(common.tr("Не удалось сохранить настройку записи токенов; проверьте права доступа к настройкам и каталогу состояния.",
                       "Could not save the token write setting; check access permissions for settings and the state directory."))
        return 1
    policy_note = (common.tr(" (издатель: guarded игнорируется, действует never)",
                             " (publisher: guarded ignored; effective policy: never)")
                   if args.write == "guarded" and common.settings().get("publisher") is True else "")
    _say(common.tr("Настройка записи токенов сохранена: ", "Token write setting saved: ") + args.write + policy_note)
    return 0


def _publisher_pass(kind, quiet=False):
    from . import publisher
    result = publisher.run_pass(kind)
    # A pass may return no summary (e.g. an early exit); it still owns all sync work.
    result = result if isinstance(result, dict) else {}
    if result.get("error"):
        _say(common.tr("Проход издателя не завершён; подробности в журнале издателя.",
                       "Publisher pass failed; see the publisher journal for details."))
        return 1
    if not quiet:
        next_at = result.get("next_at")
        if isinstance(next_at, dict):
            for product in ("claude", "codex"):
                deadline = next_at.get(product)
                if polling.number(deadline) and deadline > time.time():
                    _say(product.capitalize() + common.tr(": опрос можно с ", ": polling available from ")
                         + _fmt_time(deadline))
        _say(common.tr("Проход издателя завершён.", "Publisher pass complete."))
    return 0


def _publisher_changes(args):
    """--products / --mode → settings changes, or None after printing why they are refused."""
    if args.products is not None:
        chosen = [p.strip() for p in args.products.split(",")]
        if not chosen or any(p not in ("claude", "codex") for p in chosen):
            _say(common.tr("--products: claude, codex или claude,codex", "--products: claude, codex or claude,codex"))
            return None
        return {"monitor_claude": "claude" in chosen, "monitor_codex": "codex" in chosen}
    mode = args.mode
    if mode == ["auto"]:
        return {"autoPoll": True}
    if len(mode) == 2 and mode[0] == "fixed" and re.fullmatch(r"[0-9]{1,6}", mode[1]) and int(mode[1]) in polling.STEPS:
        return {"autoPoll": False, "interval": int(mode[1])}
    _say(common.tr("--mode auto или --mode fixed <секунды>, где секунды — ", "--mode auto or --mode fixed <seconds>, seconds one of ")
         + ", ".join(str(v) for v in polling.STEPS))
    return None


def _publisher_mode_text(settings):
    if settings.get("autoPoll") is True:
        return common.tr("Режим: авто", "Mode: auto")
    return common.tr("Режим: фиксированный, %d с", "Mode: fixed, %d s") % polling.normalize_interval(settings.get("interval"))


def cmd_publisher(args):
    settings = common.settings()
    if args.products is not None or args.mode is not None:
        changes = _publisher_changes(args)
        if changes is None:
            return 2
        try:
            # The publisher reads these settings under quota; never change them in the middle of its attempt.
            with common.file_lock("quota", timeout=60) as held:
                if not held:
                    _say(common.tr("Издатель занят попыткой — настройки не изменены, повторите позже.",
                                   "The publisher is busy with an attempt — settings unchanged, retry later."))
                    return 1
                settings.update(**changes)
        except OSError:
            _say(common.tr("Не удалось сохранить настройки издателя; проверьте права доступа к настройкам и состоянию.",
                           "Could not save publisher settings; check access permissions for settings and state."))
            return 1
        settings.reload()
        _say(common.tr("Сохранено. ", "Saved. ") + _publisher_mode_text(settings))
        return 0
    if args.enable or args.disable:
        try:
            with common.file_lock("quota", timeout=60) as held:
                if not held:
                    raise common.CredentialPolicyRefused("quota is busy; retry after the current attempt")
                settings.reload()
                # Both transitions change the effective policy. Reuse the rotation guard
                # while holding quota until the publisher setting has also been saved.
                policy = "never" if args.enable else settings.get("credential_write", "never")
                common.set_credential_write("guarded" if policy == "guarded" else "never")
                changes = {"publisher": bool(args.enable)}
                if args.enable:
                    changes["autoPoll"] = True
                settings.update(**changes)
        except common.CredentialPolicyRefused as e:
            _say(common.tr("Смена режима издателя отклонена: ", "Publisher mode change refused: ") + str(e))
            return 1
        except OSError:
            _say(common.tr("Не удалось сохранить режим издателя; проверьте права доступа к настройкам и состоянию.",
                           "Could not save publisher mode; check access permissions for settings and state."))
            return 1
        _say(common.tr("Издатель включён.", "Publisher enabled.") if args.enable
             else common.tr("Издатель выключен.", "Publisher disabled."))
        return 0
    if args.now:
        settings.reload()
        if settings.get("publisher") is not True:
            _say(common.tr("Сначала включите издатель: ccl-sync publisher --enable",
                           "Enable the publisher first: ccl-sync publisher --enable"))
            return 1
        return _publisher_pass("manual")
    settings.reload()
    enabled = settings.get("publisher") is True
    _say(common.tr("Издатель: ", "Publisher: ") + (
        common.tr("включён", "enabled") if enabled else common.tr("выключен", "disabled")))
    products = [p.capitalize() for p in ("claude", "codex") if common.product_enabled(p)]
    _say(common.tr("Продукты: ", "Products: ") + (", ".join(products) or common.tr("нет", "none")))
    _say(_publisher_mode_text(settings))
    policy = common.credential_write()
    _say(common.tr("Политика токенов: ", "Token policy: ") + policy)
    _say(common.tr("Автосинхронизация: ", "Auto sync: ") + _timer_status())
    return 0


def cmd_status(_args):
    st = sync.sync_state()
    token, backend, gist, degraded = None, None, None, False
    with common.file_lock("sync", blocking=False) as held:
        if held:
            try:
                st.reload()
                if st.get("login") and not st.get("revoked"):
                    access = sync.ensure_access(reason="status", lock_held=True)
                    token = access.access if access.kind == "ready" else None
                    backend = (access.ref or {}).get("backend") if token else access.reason
                    st.reload()
                    if token and st.get("gistId"):
                        g = sync.gh("/gists/" + st.get("gistId"), token)
                        if g.status == 200:
                            gist = g.json()
            except (OSError, ValueError):
                # Full disk / unwritable state: show what is cached, never an exception text.
                token, backend, gist, degraded = None, None, None, True
    pending = sync.sign_out_incomplete(st)
    _say("Claude Codex Limits (linux %s)" % APP_VERSION)
    try:
        mid = common.machine_id()
    except OSError:
        mid = "?"
    _say(common.tr("Эта машина: ", "This machine: ") + "%s · %s · id %s" % (
        common.machine_name(), common.os_name(), mid))
    policy = common.credential_write()
    settings = common.settings()
    settings.reload()
    policy_note = (common.tr(" (издатель: принудительно never)", " (publisher: forced never)")
                   if policy == "never" and settings.get("publisher") is True else "")
    _say(common.tr("Политика токенов: ", "Token policy: ") + policy + policy_note)
    _say_o2(st)
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
    elif sync.auth_snapshot(st).get("kind") in ("temporary", "actionRequired"):
        _say("GitHub: " + sync.auth_reason(sync.auth_snapshot(st).get("reason")))
    elif (not held or degraded) and st.get("login"):
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
    # lastError may hold exception text, a host or an address: status (read by agents, П6) shows a fixed text.
    error_note = common.tr("ошибка синхронизации, подробности — ccl-sync push",
                           "sync failed, details: ccl-sync push")
    if st.get("lastError"):
        at = st.get("lastErrorAt")
        _say(common.tr("Последняя ошибка", "Last error") + (" (%s)" % _fmt_time(at) if polling.number(at) else "")
             + ": " + error_note)
    warn = None if pending else sync.warning(st, moment=_fmt_time, require_attempt=False, error_text=error_note)
    if warn:
        _say("! " + warn)

    if not held:
        _say(common.tr("Синхронизация идёт в другом процессе — показан кэш",
                       "Sync is running in another process — showing cached machines"))
    machines = None
    if isinstance(gist, dict) and isinstance(gist.get("files"), dict):
        machines = []
        for name in sync._machine_files(gist["files"]):
            f = gist["files"][name]
            if not isinstance(f, dict):
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
            machines.append((sync._machine_text(m.get("name"), "name") or "?",
                             sync._machine_text(m.get("os"), "os"), sync._machine_text(m.get("app"), "app"),
                             common.parse_iso(obj.get("updated")), m.get("id") == common.machine_id()))
    if machines is None:
        machines = [(m["name"], m.get("os", ""), m.get("app", ""), m.get("updated"), False)
                    for m in sync.load_remote().get("machines", [])]
        if machines:
            _say(common.tr("Машины (по последней синхронизации):", "Machines (as of the last sync):"))
    else:
        _say(common.tr("Машины в gist:", "Machines in the gist:"))
    for name, osn, app, upd, me in machines:
        name = sync._machine_text(name, "name") or "?"
        osn, app = sync._machine_text(osn, "os"), sync._machine_text(app, "app")
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
    days = common.selected_days(days)
    products = [p for p in ([args.product] if args.product else ["claude", "codex"]) if common.product_enabled(p)]
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
                    (accounts._text(m) or "?")[:26], _n(u["input"]), _n(u["output"]), _n(u["cacheRead"]), _n(u["cacheWrite5m"]),
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
    p = sub.add_parser("credentials", help=common.tr("политика записи токенов", "token write policy"))
    p.add_argument("--write", choices=["never", "guarded"], required=True,
                   help=common.tr("разрешить или запретить запись токенов", "allow or forbid token writes"))
    p = sub.add_parser("publisher", help=common.tr("управление издателем лимитов", "control the limits publisher"))
    actions = p.add_mutually_exclusive_group(required=True)
    actions.add_argument("--enable", action="store_true", help=common.tr("включить издатель", "enable the publisher"))
    actions.add_argument("--disable", action="store_true", help=common.tr("выключить издатель", "disable the publisher"))
    actions.add_argument("--now", action="store_true", help=common.tr("ручной проход с учётом сроков", "manual pass respecting deadlines"))
    actions.add_argument("--status", action="store_true", help=common.tr("состояние издателя", "publisher status"))
    actions.add_argument("--products", metavar="claude[,codex]",
                         help=common.tr("какие продукты опрашивать", "which products to poll"))
    actions.add_argument("--mode", nargs="+", metavar="auto|fixed SECONDS",
                         help=common.tr("авто или фиксированный интервал (900, 1800, 3600, 14400)",
                                        "auto or a fixed interval (900, 1800, 3600, 14400)"))
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
            "credentials": cmd_credentials, "publisher": cmd_publisher,
            "push": cmd_push, "dump": cmd_dump, "update": cmd_update}[args.cmd](args)
