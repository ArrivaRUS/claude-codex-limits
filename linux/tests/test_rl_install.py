"""REMOTE-LIMITS A4 — installation and `status` (docs/plans.md §A4; docs/test-plan-remote-limits.md §A4 A4-01…A4-08).
Sources: arch/plan-synth.md §C «Установка (P2)», «ccl-sync status (O2)», §E; T1 docs/security-remote-limits.md П3-б.3,
П3-в, П6-б/в, П8-б; decisions/log.md (tags vps/macbook/alse; S6/N5: unit limit ≥ 15 min, not 300 s; `--products`/
`--mode` moved to A4; A1 N7: `--name` mandatory for `--publisher`, fallback tag without the owner's name).
Written BEFORE the code (red): every test fails on a missing behaviour, never on its harness. GUARD = green on purpose.

IDs:
  A4-01  `sh linux/install.sh --publisher --no-tray --name vps` in a temp HOME, fake `systemctl`/`pgrep`/`crontab` first
         in PATH: ccl-sync.service + ccl-sync.timer in ~/.config/systemd/user; timer `OnUnitActiveSec=5min`,
         `OnBootSec=2min`; service limit `TimeoutStartSec`/`RuntimeMaxSec` finite and ≥ 15 min (S6); ExecStart without
         env assignments or tokens; `systemctl --user enable … ccl-sync.timer`; no `.desktop`/autostart (П6-в);
         settings.json ⊇ {publisher: true, autoPoll: true, credential_write: "never", machineName: "vps"}, other user keys
         kept; XDG_RUNTIME_DIR in the environment of `systemctl --user` = /run/user/<uid> only when that directory exists,
         a preset XDG_RUNTIME_DIR is kept.
  A4-02  tray process of this user running (fake `pgrep` finds it) → refusal rc ≠ 0, a stop command printed (`pkill …`/
         `kill …`), installer does not stop/restart anything itself; no unit, settings.json byte-for-byte unchanged.
  A4-03  `ccl-sync status` (O2): state directory and effective policy; 24 h counters from the O1 journal (requests, 429,
         failed publications); clockSkew; the timer line says 5 min; works without GitHub sign-in, with `sync` busy and
         on a full disk; no token, e-mail/name sentinels, exception texts or ESC in the output.
  A4-04  Т28: two processes with different XDG_STATE_HOME print different state directories; the detector reports
         «два state-каталога».
  A4-05  GUARD (P1): publisher pass via `ccl-sync push --auto` with PyQt5/dbus/secretstorage blocked; `python3 -I` import
         of the headless modules imports none of them.
  A4-06  CLI `publisher --products …`, `publisher --mode auto|fixed <s>`, `publisher --status`; settings change only
         while `quota` is held (busy `quota` → refusal, nothing changed); `--mode fixed` accepts only 900/1800/3600/14400.
  A4-07  `test_deb.py` stays green (existing module, not duplicated here).
  A4-08  N7 (A1): `--publisher` without `--name` → refusal, nothing installed; `--name` value ends up as a tag
         `[a-z0-9-]{1,16}` (or is refused); `machine_tag()` fallback from hostname `alex-ThinkPad-X1` for user alex
         carries no `alex` (A1-22 vector).

Contract chosen by the tester where the sources are silent (developer: implement exactly this, or ask Yurka):
  * install.sh flags: `--publisher`, `--no-tray`, `--name <tag>` (separate argument). Tray check with `pgrep -u <uid|user>
    -f <pattern containing claude-codex-limits>` from PATH; exit 0 = running. UID from `id -u` (sh has no $UID).
    The tray/`--name` checks run before anything is written. Units go to ${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user.
  * `ccl-sync status` lines (checked with `lang: en`; the Russian text is free):
        State directory: <common.STATE_DIR>
        Token policy: never …                      (existing line)
        Auto sync: systemd --user, every 5 min     (when the timer is active)
        Claude · last 24 h: requests <n>, 429 <n>
        Codex · last 24 h: requests <n>, 429 <n>
        Publications · last 24 h: failed <n>
        Clock skew vs GitHub: <int> s              (sync-state.json `clockSkew`, rounded; printed whenever known)
    Counters come from publisher.jsonl events with ts in (now − 24 h, now]: requests = `poll_attempt` of the product,
    429 = `poll_result` with httpStatus 429, failed publications = `publish` with result `failed`.
    `lastError` is never printed verbatim (it may hold exception text) — print a class or a fixed text.
  * CLI: `ccl-sync publisher --products claude[,codex]` (monitor_claude/monitor_codex); `--mode auto` (autoPoll true) /
    `--mode fixed <s>` (autoPoll false, interval s; s ∈ {900, 1800, 3600, 14400}, else rc ≠ 0 and nothing written);
    `publisher --status` prints `Mode: auto` or `Mode: fixed, <s> s`. Each change is written under file_lock("quota")
    in the calling thread; if quota stays busy the command fails (rc ≠ 0) without writing.
Run: cd linux && python3 -m unittest tests.test_rl_install -v
"""

if __package__:
    from . import _rl_env as rl
else:
    import _rl_env as rl

import builtins
import contextlib
import fcntl
import io
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from collections import namedtuple
from unittest import mock

from ccl import cli, common, sync

NOW = rl.NOW
DAY = 86400
LINUX = os.path.join(rl.ROOT, "linux")
INSTALL = os.path.join(LINUX, "install.sh")
TAG = re.compile(r"^[a-z0-9-]{1,16}$")
BLOCKED = ("PyQt5", "dbus", "secretstorage")

STATE_LINE = re.compile(r"(?m)^\s*State directory: (.+?)\s*$")
POLICY_LINE = re.compile(r"(?m)^\s*Token policy: never\b")
TIMER_LINE = re.compile(r"(?m)^\s*Auto sync: .*\bevery 5 min\b")
COUNT_LINE = r"(?m)^\s*%s · last 24 h: requests (\d+), 429 (\d+)\s*$"
PUBLISH_LINE = re.compile(r"(?m)^\s*Publications · last 24 h: failed (\d+)\s*$")
SKEW_LINE = re.compile(r"(?m)^\s*Clock skew vs GitHub: (-?\d+) s\s*$")


def tearDownModule():
    rl.assert_real_files_untouched()


# ==== fake binaries ===================================================================================================
def make_fakebin(root, uid=None):
    """systemctl / pgrep / pkill / crontab (+ optional id -u) that only log. `root/tray-running` = tray is running."""
    fb, log = os.path.join(root, "fakebin"), os.path.join(root, "log")
    os.makedirs(fb, exist_ok=True)
    os.makedirs(log, exist_ok=True)
    scripts = {
        "systemctl": ('printf \'%%s|%%s\\n\' "${XDG_RUNTIME_DIR-UNSET}" "$*" >> "%s/systemctl.log"\n'
                      'case "$*" in *is-active*) echo active ;; *is-enabled*) echo enabled ;; esac\nexit 0\n' % log),
        "pgrep": ('printf \'%%s\\n\' "$*" >> "%s/pgrep.log"\n'
                  'if [ -e "%s/tray-running" ]; then echo 4242; exit 0; fi\nexit 1\n' % (log, root)),
        "pkill": 'printf \'%%s\\n\' "$*" >> "%s/pkill.log"\nexit 0\n' % log,
        "crontab": ('printf \'%%s\\n\' "$*" >> "%s/crontab.log"\n'
                    'if [ "$1" = "-l" ]; then exit 1; fi\ncat >/dev/null\nexit 0\n' % log),
    }
    if uid is not None:
        scripts["id"] = 'if [ "$#" -eq 1 ] && [ "$1" = "-u" ]; then echo %s; exit 0; fi\nexec /usr/bin/id "$@"\n' % uid
    for name, body in scripts.items():
        path = os.path.join(fb, name)
        with open(path, "w") as f:
            f.write("#!/bin/sh\n" + body)
        os.chmod(path, 0o755)
    return fb, log


def read_log(log, name):
    try:
        with open(os.path.join(log, name + ".log")) as f:
            return [ln for ln in f.read().splitlines() if ln.strip()]
    except FileNotFoundError:
        return []


Install = namedtuple("Install", "rc out home root log conf")


def run_install(root, args, tray=False, uid=None, runtime=None, settings=None):
    """One installer run in `root/home`; the environment is built from scratch (no XDG_* of the test process)."""
    home = os.path.join(root, "home")
    os.makedirs(home, exist_ok=True)
    fb, log = make_fakebin(root, uid)
    if tray:
        open(os.path.join(root, "tray-running"), "w").close()
    conf = os.path.join(home, ".config")
    if settings is not None:
        os.makedirs(os.path.join(conf, "claude-codex-limits"), exist_ok=True)
        with open(os.path.join(conf, "claude-codex-limits", "settings.json"), "wb") as f:
            f.write(settings)
    dead_proxy = "http://127.0.0.1:9"
    env = {"HOME": home, "PATH": fb + ":/usr/bin:/bin", "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8",
           "USER": "ccltest", "LOGNAME": "ccltest", "DBUS_SESSION_BUS_ADDRESS": "disabled:",
           "http_proxy": dead_proxy, "https_proxy": dead_proxy, "HTTP_PROXY": dead_proxy, "HTTPS_PROXY": dead_proxy,
           "PYTHONDONTWRITEBYTECODE": "1"}
    if runtime is not None:
        env["XDG_RUNTIME_DIR"] = runtime
    p = subprocess.run(["sh", INSTALL] + list(args), env=env, cwd=root, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, timeout=120)
    return Install(p.returncode, p.stdout.decode("utf-8", "replace"), home, root, log, conf)


def units_dir(r):
    return os.path.join(r.conf, "systemd", "user")


def unit(r, name):
    path = os.path.join(units_dir(r), name)
    if not os.path.exists(path):
        return None
    out = {}
    with open(path) as f:
        for ln in f:
            ln = ln.strip()
            if ln and not ln.startswith(("#", ";", "[")) and "=" in ln:
                k, v = ln.split("=", 1)
                out.setdefault(k.strip(), []).append(v.strip())
    return out


_UNITS = {"": 1, "s": 1, "sec": 1, "second": 1, "seconds": 1, "m": 60, "min": 60, "minute": 60, "minutes": 60,
          "h": 3600, "hr": 3600, "hour": 3600, "hours": 3600}


def span(value):
    """systemd time span → seconds; None for infinity/0/unparsable (= no limit)."""
    v = value.strip().lower()
    if v in ("", "0", "infinity"):
        return None
    parts = re.findall(r"(\d+(?:\.\d+)?)\s*([a-z]*)", v)
    if not parts or "".join(n + u for n, u in parts) != v.replace(" ", ""):
        return None
    try:
        return sum(float(n) * _UNITS[u] for n, u in parts)
    except KeyError:
        return None


def settings_of(r):
    path = os.path.join(r.conf, "claude-codex-limits", "settings.json")
    try:
        with open(path, "rb") as f:
            return f.read()
    except FileNotFoundError:
        return None


EXPECTED = {"publisher": True, "autoPoll": True, "credential_write": "never", "machineName": "vps"}


# ==== A4-01 ===========================================================================================================
class TestA401Install(unittest.TestCase):
    """One run of `install.sh --publisher --no-tray --name vps`, XDG_RUNTIME_DIR unset, real `id`."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="ccl-a4-install-", dir="/tmp")
        cls.r = run_install(cls.tmp, ["--publisher", "--no-tray", "--name", "vps"])

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def ok(self):
        self.assertEqual(self.r.rc, 0, "install.sh --publisher --no-tray --name vps завершился с ошибкой:\n"
                         + self.r.out[-1500:])

    def test_timer_unit_5min_boot_2min(self):
        self.ok()
        timer = unit(self.r, "ccl-sync.timer")
        self.assertIsNotNone(timer, "нет ~/.config/systemd/user/ccl-sync.timer")
        self.assertEqual([span(v) for v in timer.get("OnUnitActiveSec", [])], [300], "OnUnitActiveSec=5min")
        self.assertEqual([span(v) for v in timer.get("OnBootSec", [])], [120], "OnBootSec=2min")

    def test_service_limit_at_least_15_min(self):
        """S6/N5 (T2-r2, T2-r3): a finite limit, never below the worst pass; 300 s is wrong."""
        self.ok()
        service = unit(self.r, "ccl-sync.service")
        self.assertIsNotNone(service, "нет ~/.config/systemd/user/ccl-sync.service")
        limits = {k: service.get(k, []) for k in ("TimeoutStartSec", "RuntimeMaxSec")}
        present = [(k, v) for k, vs in limits.items() for v in vs]
        self.assertTrue(present, "в юните нет ни TimeoutStartSec, ни RuntimeMaxSec (oneshot без предела)")
        for k, v in present:
            seconds = span(v)
            self.assertIsNotNone(seconds, "%s=%s — предел должен быть конечным" % (k, v))
            self.assertGreaterEqual(seconds, 900, "%s=%s < 15 мин (S6: не 300 с)" % (k, v))

    def test_service_execstart_without_env_or_token(self):
        self.ok()
        service = unit(self.r, "ccl-sync.service")
        self.assertIsNotNone(service)
        execs = service.get("ExecStart", [])
        self.assertEqual(len(execs), 1, execs)
        cmd = execs[0]
        self.assertRegex(cmd, r"ccl-sync[\"']?\s+push\b.*--auto")
        self.assertNotRegex(cmd, r"(^|\s)[A-Za-z_][A-Za-z0-9_]*=", "ExecStart без присваиваний окружения")
        self.assertNotRegex(cmd, r"(^|[\s/])env\s", "ExecStart без env")
        self.assertNotRegex(cmd.lower(), r"token|bearer|gho_|ghp_|secret|password")
        for key in ("Environment", "EnvironmentFile", "PassEnvironment"):
            for v in service.get(key, []):
                self.assertNotRegex(v.lower(), r"token|secret|key|password|gh_|github", "%s=%s" % (key, v))

    def test_timer_enabled_via_systemctl_user(self):
        self.ok()
        calls = [ln.split("|", 1)[1] for ln in read_log(self.r.log, "systemctl")]
        self.assertTrue(any("--user" in c and "enable" in c and "ccl-sync.timer" in c for c in calls), calls)
        self.assertEqual(read_log(self.r.log, "crontab"), [], "при systemd --user cron не трогается")

    def test_no_tray_means_no_desktop_and_no_autostart(self):
        """П6-в: `--no-tray` creates neither the menu entry nor autostart (today install.sh writes both)."""
        self.ok()
        for path in (os.path.join(self.r.home, ".local", "share", "applications", "claude-codex-limits.desktop"),
                     os.path.join(self.r.conf, "autostart", "claude-codex-limits.desktop")):
            self.assertFalse(os.path.exists(path), path)

    def test_settings(self):
        self.ok()
        raw = settings_of(self.r)
        self.assertIsNotNone(raw, "settings.json не создан")
        obj = json.loads(raw)
        self.assertEqual({k: obj.get(k) for k in EXPECTED}, EXPECTED)

    def test_tray_check_uses_pgrep_for_this_user(self):
        self.ok()
        calls = read_log(self.r.log, "pgrep")
        self.assertTrue(any("-u" in c.split() and "claude-codex-limits" in c for c in calls),
                        "проверка трея пользователя: pgrep -u <uid> -f …claude-codex-limits…; вызовы: %r" % calls)
        self.assertEqual(read_log(self.r.log, "pkill"), [], "установщик сам ничего не останавливает")

    def test_runtime_dir_only_when_it_exists(self):
        """XDG_RUNTIME_DIR unset in the session: exported for `systemctl --user` iff /run/user/<uid> exists
        (on a host without it — CI container — the same test checks the other branch; never skipped)."""
        self.ok()
        expected = "/run/user/%d" % os.getuid()
        expected = expected if os.path.isdir(expected) else "UNSET"
        seen = {ln.split("|", 1)[0] for ln in read_log(self.r.log, "systemctl")}
        self.assertTrue(seen, "systemctl --user не вызывался")
        self.assertEqual(seen, {expected})


class TestA401RuntimeVariants(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ccl-a4-rt-", dir="/tmp")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def test_missing_runtime_dir_is_not_exported(self):
        r = run_install(self.tmp, ["--publisher", "--no-tray", "--name", "vps"], uid="4242424")
        self.assertEqual(r.rc, 0, r.out[-1500:])
        seen = {ln.split("|", 1)[0] for ln in read_log(r.log, "systemctl")}
        self.assertEqual(seen, {"UNSET"}, "каталога /run/user/4242424 нет — XDG_RUNTIME_DIR не выставляется")
        for name in ("ccl-sync.service", "ccl-sync.timer"):
            with open(os.path.join(units_dir(r), name)) as f:
                self.assertNotIn("/run/user/4242424", f.read())

    def test_preset_runtime_dir_is_kept(self):
        preset = os.path.join(self.tmp, "runtime")
        os.makedirs(preset, mode=0o700)
        r = run_install(self.tmp, ["--publisher", "--no-tray", "--name", "vps"], runtime=preset)
        self.assertEqual(r.rc, 0, r.out[-1500:])
        self.assertEqual({ln.split("|", 1)[0] for ln in read_log(r.log, "systemctl")}, {preset})

    def test_existing_settings_merged_policy_forced(self):
        before = json.dumps({"lang": "en", "credential_write": "guarded", "publisher": False, "interval": 3600,
                             "machineName": "old"}).encode()
        r = run_install(self.tmp, ["--publisher", "--no-tray", "--name", "vps"], settings=before)
        self.assertEqual(r.rc, 0, r.out[-1500:])
        obj = json.loads(settings_of(r))
        self.assertEqual({k: obj.get(k) for k in EXPECTED}, EXPECTED)
        self.assertEqual(obj.get("lang"), "en", "чужие ключи настроек сохраняются")


# ==== A4-02 ===========================================================================================================
class TestA402RefuseWithRunningTray(unittest.TestCase):
    def test_refuses_prints_stop_command_changes_nothing(self):
        tmp = tempfile.mkdtemp(prefix="ccl-a4-tray-", dir="/tmp")
        self.addCleanup(shutil.rmtree, tmp, True)
        before = json.dumps({"lang": "en", "credential_write": "guarded"}).encode()
        r = run_install(tmp, ["--publisher", "--no-tray", "--name", "vps"], tray=True, settings=before)
        self.assertNotIn("unknown option", r.out, "флаги --publisher/--no-tray/--name не поддерживаются")
        self.assertNotEqual(r.rc, 0, "при запущенном трее установка отказывает (П3-б.3)")
        self.assertTrue(read_log(r.log, "pgrep"), "отказ — по проверке процесса (pgrep), а не случайный")
        self.assertRegex(r.out, r"(?m)\bp?kill\b[^\n]*", "напечатана команда остановки трея")
        self.assertEqual(read_log(r.log, "pkill"), [], "трей не останавливается и не перезапускается установщиком")
        calls = [ln.split("|", 1)[1] for ln in read_log(r.log, "systemctl")]
        self.assertFalse([c for c in calls if re.search(r"\b(enable|start|restart)\b", c)], calls)
        for name in ("ccl-sync.service", "ccl-sync.timer"):
            self.assertFalse(os.path.exists(os.path.join(units_dir(r), name)), name)
        self.assertEqual(settings_of(r), before, "settings.json не изменён")


# ==== A4-08 (N7 of A1) ================================================================================================
class TestA408NameMandatory(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="ccl-a4-name-", dir="/tmp")
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def test_publisher_without_name_refused(self):
        r = run_install(self.tmp, ["--publisher", "--no-tray"])
        self.assertNotIn("unknown option", r.out, "флаг --publisher не поддерживается")
        self.assertNotEqual(r.rc, 0, "--publisher без --name: отказ (N7: тег из hostname может нести имя владельца)")
        self.assertIn("--name", r.out)
        self.assertIsNone(settings_of(r))
        self.assertFalse(os.path.exists(os.path.join(units_dir(r), "ccl-sync.timer")))

    def test_name_becomes_a_tag_or_is_refused(self):
        r = run_install(self.tmp, ["--publisher", "--no-tray", "--name", "Alex PC \x1b[1m"])
        self.assertNotIn("unknown option", r.out, "флаг --name не поддерживается")
        if r.rc == 0:
            name = json.loads(settings_of(r)).get("machineName")
            self.assertRegex(name or "", TAG, "machineName из --name — тег [a-z0-9-]{1,16}")
        else:
            self.assertIn("--name", r.out)


class TestA408FallbackTagWithoutOwnerName(rl.RLEnv):
    """A1-22 (T2 A1 N7): machineName empty, hostname `alex-ThinkPad-X1`, the login user is alex."""

    def test_vector_alex_thinkpad(self):
        common.settings().set("machineName", "")
        pw = mock.Mock(pw_name="alex", pw_gecos="Alex Smith,,,", pw_dir=self.home)
        with mock.patch("socket.gethostname", return_value="alex-ThinkPad-X1"), \
                mock.patch("getpass.getuser", return_value="alex"), \
                mock.patch("pwd.getpwuid", return_value=pw), \
                mock.patch("os.getlogin", return_value="alex"), \
                mock.patch.dict(os.environ, {"USER": "alex", "LOGNAME": "alex"}):
            tag = common.machine_tag()
        self.assertRegex(tag, TAG)
        self.assertNotIn("alex", tag, "запасной тег не несёт имя пользователя (или равен linux)")


# ==== in-process CLI environment ======================================================================================
class A4Env(rl.PubEnv):
    """PubEnv + fake monotonic clock (shares the wall clock; `wall_only()` moves the wall clock alone),
    fake systemctl/crontab first in PATH (no real systemctl from `status`), `lang: en`."""

    def setUp(self):
        super().setUp()
        self.mono_off = 0.0
        self.patch(time, "monotonic", lambda: self.clock.now + self.mono_off)
        fb, self.fakelog = make_fakebin(self.tmp)
        p = mock.patch.dict(os.environ, {"PATH": fb + ":/usr/bin:/bin"})
        p.start()
        self.addCleanup(p.stop)
        self.write_settings(lang="en")

    def wall_only(self, seconds):
        self.clock.advance(seconds)
        self.mono_off -= seconds

    def hold(self, name):
        path = os.path.join(common.STATE_DIR, name + ".lock")
        os.makedirs(common.STATE_DIR, exist_ok=True)
        fd = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)     # flock is per open file: conflicts in-process too

        done = []

        def release():
            if done:
                return
            done.append(True)
            with contextlib.suppress(OSError):
                fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)
        self.addCleanup(release)
        return release

    def run_cli(self, argv):
        out, err = io.StringIO(), io.StringIO()
        try:
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                code = cli.main(argv)
        except SystemExit as e:
            code = e.code if isinstance(e.code, int) else 2
        except Exception as e:                       # a crash is a failed command, reported, not a harness error
            code = "необработанное исключение %s" % type(e).__name__
        return code, out.getvalue() + err.getvalue()

    def settings_raw(self):
        try:
            with open(common.SETTINGS_PATH, "rb") as f:
                return f.read()
        except FileNotFoundError:
            return None

    def settings_obj(self):
        return json.loads(self.settings_raw() or b"{}")


# ==== A4-03 ===========================================================================================================
class TestA403Status(A4Env):
    def seed_journal(self):
        """Real O1 events at fake times: 25 h ago (outside the window) and 23 h ago (inside)."""
        self.clock.now = NOW - 25 * 3600
        for _ in range(2):
            common.o1_event("poll_attempt", product="claude", kind="auto", attemptAt=self.clock.now)
        common.o1_event("poll_result", product="claude", httpStatus=429, result="failed")
        common.o1_event("publish", result="failed")
        self.clock.now = NOW - 23 * 3600
        for _ in range(3):
            common.o1_event("poll_attempt", product="claude", kind="auto", attemptAt=self.clock.now)
        common.o1_event("poll_result", product="claude", httpStatus=429, result="failed")
        for _ in range(2):
            common.o1_event("poll_result", product="claude", httpStatus=200, result="ok")
        common.o1_event("poll_attempt", product="codex", kind="manual", attemptAt=self.clock.now)
        common.o1_event("poll_result", product="codex", httpStatus=429, result="failed")
        for result in ("failed", "failed", "ok"):
            common.o1_event("publish", result=result)
        self.clock.now = NOW
        self.assertGreaterEqual(len(rl.read_o1()), 14, "журнал O1 засеян")
        sync.sync_state().update(clockSkew=-75.0, clockSkewAt=NOW - 60)

    def status(self):
        code, out = self.run_cli(["status"])
        self.assertEqual(code, 0, "ccl-sync status упал:\n" + out[-1500:])
        self.assertNotIn("Traceback", out)
        return out

    def assert_o2(self, out):
        m = STATE_LINE.search(out)
        self.assertIsNotNone(m, "нет строки «State directory: <путь>» (П8-б):\n" + out)
        self.assertEqual(os.path.normpath(m.group(1)), os.path.normpath(common.STATE_DIR))
        self.assertRegex(out, POLICY_LINE, "действующая политика (П3-в)")
        for product, requests, r429 in (("Claude", 3, 1), ("Codex", 1, 1)):
            m = re.search(COUNT_LINE % product, out)
            self.assertIsNotNone(m, "нет счётчиков 24 ч для %s:\n%s" % (product, out))
            self.assertEqual((int(m.group(1)), int(m.group(2))), (requests, r429), product)
        m = PUBLISH_LINE.search(out)
        self.assertIsNotNone(m, "нет счётчика неудачных публикаций за 24 ч:\n" + out)
        self.assertEqual(int(m.group(1)), 2)
        m = SKEW_LINE.search(out)
        self.assertIsNotNone(m, "нет clockSkew:\n" + out)
        self.assertEqual(int(m.group(1)), -75)

    def test_signed_in_live_gist(self):
        self.seed_journal()
        out = self.status()
        self.assert_o2(out)
        self.assertRegex(out, TIMER_LINE, "таймер издателя — 5 мин")

    def test_not_signed_in(self):
        self.seed_journal()
        sync.sync_state().update(login=None, gistId=None)
        out = self.status()
        self.assert_o2(out)
        self.assertEqual(self.ledger.of("GET"), [], "без входа — 0 запросов к GitHub")

    def test_sync_busy(self):
        self.seed_journal()
        self.hold("sync")
        out = self.status()
        self.assert_o2(out)

    def test_disk_full(self):
        self.seed_journal()

        def enospc(*a, **kw):
            raise OSError(28, "No space left on device")
        self.patch(common, "write_atomic", enospc)
        out = self.status()
        self.assert_o2(out)
        self.assertNotIn("No space left", out)
        self.assertNotIn("Errno", out)

    def test_no_token_email_exception_text_or_esc(self):
        self.seed_journal()
        s = rl.sentinels()
        sync.sync_state().update(lastError="<urlopen error [Errno 111] Connection refused> " + s["email"],
                                 lastErrorAt=NOW - 120)
        self.gist.put("machine-esc.json", json.dumps({
            "schema": 1, "machine": {"id": "esc", "name": "\x1b[2Jevil\u202e", "os": "Test OS", "app": "linux 0.5.0"},
            "updated": rl.iso(NOW - 30), "lastSeenAt": rl.iso(NOW - 30), "tz": "UTC", "days": {},
            "accounts": [], "unattributedDays": {}, "captions": {}}))
        out = self.status()
        self.assert_o2(out)
        self.assertNotIn(self.token, out)
        self.assertNotIn(self.token[:8], out)
        self.assert_no_sentinel(out, "status")
        for bad in ("Errno", "urlopen", "Connection refused", "Traceback", "\x1b", "\u202e"):
            self.assertNotIn(bad, out, "в status попал текст исключения/управляющий символ: %r" % bad)


# ==== A4-04 (Т28) =====================================================================================================
def two_state_dirs(outputs):
    """The detector: distinct `State directory:` values across processes → «два state-каталога»."""
    dirs = []
    for out in outputs:
        m = STATE_LINE.search(out)
        dirs.append(m.group(1) if m else None)
    if None in dirs:
        return "state-каталог не напечатан"
    return "два state-каталога" if len(set(dirs)) > 1 else "один state-каталог"


class TestA404TwoStateDirs(unittest.TestCase):
    def test_status_prints_distinct_state_dirs(self):
        tmp = tempfile.mkdtemp(prefix="ccl-a4-t28-", dir="/tmp")
        self.addCleanup(shutil.rmtree, tmp, True)
        fb, _log = make_fakebin(tmp)
        conf = os.path.join(tmp, "config")
        os.makedirs(os.path.join(conf, "claude-codex-limits"))
        with open(os.path.join(conf, "claude-codex-limits", "settings.json"), "w") as f:
            json.dump({"lang": "en"}, f)
        outs, expected = [], []
        for name in ("systemd", "xfce"):
            state = os.path.join(tmp, "state-" + name)
            env = {"HOME": os.path.join(tmp, "home"), "PATH": fb + ":/usr/bin:/bin", "LANG": "C.UTF-8",
                   "XDG_CONFIG_HOME": conf, "XDG_STATE_HOME": state, "XDG_CACHE_HOME": os.path.join(tmp, "cache"),
                   "XDG_DATA_HOME": os.path.join(tmp, "data"), "DBUS_SESSION_BUS_ADDRESS": "disabled:",
                   "http_proxy": "http://127.0.0.1:9", "https_proxy": "http://127.0.0.1:9",
                   "PYTHONDONTWRITEBYTECODE": "1"}
            p = subprocess.run([sys.executable, "-I", os.path.join(LINUX, "ccl-sync"), "status"], env=env,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
            out = p.stdout.decode("utf-8", "replace")
            self.assertEqual(p.returncode, 0, out[-1500:])
            outs.append(out)
            expected.append(os.path.join(state, "claude-codex-limits"))
        self.assertEqual(two_state_dirs(outs), "два state-каталога", outs)
        self.assertEqual([os.path.normpath(STATE_LINE.search(o).group(1)) for o in outs], expected)


# ==== A4-05 (GUARD) ===================================================================================================
class TestA405Headless(A4Env):
    def test_publisher_pass_without_gui_modules(self):
        attempts = []
        real_import = builtins.__import__

        def recording_import(name, *a, **kw):
            if name.split(".")[0] in BLOCKED:
                attempts.append(name)
            return real_import(name, *a, **kw)
        blocked = {m: None for m in sys.modules if m.split(".")[0] in BLOCKED}
        blocked.update({m: None for m in BLOCKED})
        with mock.patch.dict(sys.modules, blocked), mock.patch.object(builtins, "__import__", recording_import):
            code, out = self.run_cli(["push", "--auto", "--quiet"])
        self.assertEqual(code, 0, out)
        self.assertEqual(len(self.providers.calls("claude")), 1, "проход издателя отработал")
        self.assertEqual(attempts, [])

    def test_headless_modules_import_without_gui(self):
        script = ("import sys\n"
                  "for m in %r: sys.modules[m] = None\n"
                  "sys.path.insert(0, %r)\n"
                  "import ccl.cli, ccl.publisher, ccl.sync, ccl.limits, ccl.vault, ccl.accounts, ccl.coordination, "
                  "ccl.polling, ccl.usage\n"
                  "bad = [m for m, v in sys.modules.items() if v is not None and m.split('.')[0] in %r]\n"
                  "print(bad)\nsys.exit(1 if bad else 0)\n") % (BLOCKED, LINUX, BLOCKED)
        env = {"HOME": self.home, "PATH": "/usr/bin:/bin", "LANG": "C.UTF-8"}
        for kind in ("CONFIG", "STATE", "CACHE", "DATA"):
            env["XDG_%s_HOME" % kind] = os.path.join(self.tmp, "sub-" + kind.lower())
        p = subprocess.run([sys.executable, "-I", "-c", script], env=env, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, timeout=60)
        self.assertEqual(p.returncode, 0, p.stdout.decode("utf-8", "replace")[-1500:])


# ==== A4-06 ===========================================================================================================
class TestA406PublisherCli(A4Env):
    def watch_settings_writes(self):
        writes = []
        inner = common.write_atomic

        def spy(path, data, mode=0o600):
            if os.path.abspath(path) == os.path.abspath(common.SETTINGS_PATH):
                writes.append(common.lock_held_by_thread("quota"))
            return inner(path, data, mode)
        self.patch(common, "write_atomic", spy)
        return writes

    def test_products(self):
        writes = self.watch_settings_writes()
        code, out = self.run_cli(["publisher", "--products", "claude"])
        self.assertEqual(code, 0, out)
        obj = self.settings_obj()
        self.assertEqual((obj.get("monitor_claude", True), obj.get("monitor_codex", True)), (True, False))
        code, out = self.run_cli(["publisher", "--products", "codex,claude"])
        self.assertEqual(code, 0, out)
        obj = self.settings_obj()
        self.assertEqual((obj.get("monitor_claude", True), obj.get("monitor_codex", True)), (True, True))
        self.assertTrue(writes and all(writes), "настройки пишутся только под замком quota: %r" % writes)
        before = self.settings_raw()
        code, out = self.run_cli(["publisher", "--products", "gemini"])
        self.assertNotEqual(code, 0)
        self.assertEqual(self.settings_raw(), before)

    def test_mode(self):
        writes = self.watch_settings_writes()
        code, out = self.run_cli(["publisher", "--mode", "fixed", "3600"])
        self.assertEqual(code, 0, out)
        obj = self.settings_obj()
        self.assertEqual((obj.get("autoPoll"), obj.get("interval")), (False, 3600))
        code, out = self.run_cli(["publisher", "--status"])
        self.assertEqual(code, 0, out)
        self.assertRegex(out, r"(?mi)^\s*Mode: fixed, 3600 s\b")
        code, out = self.run_cli(["publisher", "--mode", "auto"])
        self.assertEqual(code, 0, out)
        self.assertIs(self.settings_obj().get("autoPoll"), True)
        code, out = self.run_cli(["publisher", "--status"])
        self.assertRegex(out, r"(?mi)^\s*Mode: auto\b")
        self.assertTrue(writes and all(writes), "настройки пишутся только под замком quota: %r" % writes)

    def test_mode_fixed_only_allowed_intervals(self):
        for seconds in (900, 1800, 3600, 14400):
            code, out = self.run_cli(["publisher", "--mode", "fixed", str(seconds)])
            self.assertEqual(code, 0, (seconds, out))
            self.assertEqual(self.settings_obj().get("interval"), seconds)
        before = self.settings_raw()
        for bad in ("600", "0", "-900", "1801", "86400", "abc"):
            code, out = self.run_cli(["publisher", "--mode", "fixed", bad])
            self.assertNotEqual(code, 0, bad)
            self.assertEqual(self.settings_raw(), before, bad)

    def test_busy_quota_refuses_then_succeeds(self):
        before = self.settings_raw()
        release = self.hold("quota")
        for argv in (["publisher", "--mode", "fixed", "1800"], ["publisher", "--products", "claude"]):
            code, out = self.run_cli(argv)
            self.assertNotEqual(code, 0, (argv, out))
            self.assertEqual(self.settings_raw(), before, argv)
        release()
        code, out = self.run_cli(["publisher", "--mode", "fixed", "1800"])
        self.assertEqual(code, 0, out)
        self.assertEqual(self.settings_obj().get("interval"), 1800)

    def test_credentials_write_under_quota_guard(self):
        """GUARD: `credentials --write` already changes the policy under quota."""
        writes = self.watch_settings_writes()
        code, out = self.run_cli(["credentials", "--write", "guarded"])
        self.assertEqual(code, 0, out)
        self.assertTrue(writes and all(writes), writes)


if __name__ == "__main__":
    unittest.main()
