"""REMOTE-LIMITS A5 — incident 2026-10-18: on a headless publisher the GitHub token went to the Secret Service.
Sources: decisions/log.md «2026-10-18 — A5: токен GitHub ушёл в Secret Service вопреки S4»; docs/prd-remote-limits.md
F3 P1 («токен GitHub хранится в существующем файловом бэкенде 0600 (S4)») and S4 («только в файловом бэкенде 0600»).
Test-plan IDs A5-01…A5-18 (docs/test-plan-remote-limits.md §A5). Written BEFORE the fix (red): every red test fails on
a missing behaviour, never on its harness. Tests marked GUARD are green now on purpose and must stay green.

Where the token is chosen today (both paths are pinned, the incident went through the second one):
  * legacy explicit login (a plain string token): `vault.store` (vault.py `def store`) tries the Secret Service first;
  * the real `ccl-sync login` (Device Flow returns a dict → `sync.login_finish` → `AuthOwner.accept_login`) takes the
    backend from `vault.CredentialStore.login_backend()` — «secret-service» whenever the default collection is
    unlocked. That is what happened on the VPS desktop terminal (XFCE, unlocked keyring).

IDs:
  A5-01  `publisher: true` + reachable, UNLOCKED Secret Service (fake that can set/get): `vault.write` (= store +
         publish) → backend «file», `common.TOKEN_FILE_PATH` mode 0600 holds the token, no Secret Service item, the
         fake's `set` (= CreateItem) never called.
  A5-02  the same through legacy `sync.login_finish(<str>)`: `tokenBackend` = «file», file 0600, no `set`.
  A5-03  `publisher: true`: `CredentialStore.login_backend()` → «file» although the collection is unlocked.
  A5-04  `publisher: true`: `ccl-sync login --force --no-browser` (Device Flow, V2) → active ref backend «file»,
         `github-credentials/<generation>` mode 0600 with the envelope, no V2 Secret Service item, `set` never called;
         the «Done» line says «token in file …» (en) / «токен в файле …» (ru), never the Secret Service.
  A5-05  GUARD `publisher: false` (and key absent): previous behaviour — `vault.write` and `ccl-sync login` choose the
         Secret Service when it is unlocked; the «Done» line says «token in the Secret Service».
  A5-06  publisher whose token already lives in the Secret Service (legacy of the incident), `ccl-sync status`
         (lang en and ru), variants: V2 ref locked (what the systemd timer sees), V2 ref unlocked (desktop terminal),
         legacy ref (`tokenBackend: secret-service`) locked and unlocked → rc 0, no traceback, a «GitHub: …» line with
         the re-login hint (contract below); the «unlock KWallet» advice is not printed (under the timer it never
         unlocks).
  A5-07  GUARD publisher with the token in the file: `status` prints the usual «GitHub: me  (token: <path>)», no hint.
  A5-11  (decision of Yurka 2026-10-18) the same pass with the token in an UNLOCKED Secret Service: the fake's
         `get` is never called, no request, `lastError` = the A5-08 hint. Automatic SS → file migration: NOT done.
  A5-08  publisher pass with the token in a LOCKED Secret Service (`sync.open_cycle(auto=True)` — the pass's read
         step): no exception, no request, `lastError` carries the re-login hint instead of «sync resumes after
         unlocking».
  A5-09  `ccl-sync publisher --enable` while the token is in the Secret Service (V2 and legacy) → rc 0, publisher
         enabled, warning (contract below); nothing is moved: the Secret Service item stays, no token file appears,
         `sync-state.json` sign-in fields unchanged, the Secret Service is not even contacted (decision from the
         nonsecret state only — P1 headless). GUARD: token in the file → no warning.
  A5-10  `sh install.sh --publisher --no-tray --name vps` over a `sync-state.json` that points at the Secret Service
         (real state produced by a login in this sandbox, V2 and legacy) → rc 0, settings as A4-01, warning (Russian,
         install.sh speaks Russian only), `sync-state.json` byte-for-byte unchanged, no credential file. GUARD: token
         in the file → no warning.

Fix cycle A5 №1 (docs/review-remote-limits-a5-s4.md M1; docs/security-remote-limits-a5-s4-t2.md M1–M5, m6–m8, §6):
  A5-12  M1  publisher + pre-0.3.1 state ({login}, no tokenGeneration/tokenBackend), an UNLOCKED legacy SS item:
         `ensure_access`, the pass (`open_cycle`) and `status` never construct/read the SS (`_ss` factory and `get`
         = 0), no request, the re-login hint. A legacy FILE on a publisher: SS untouched, outcome either read from the
         file or `publisher_file_required` (both keep S4).
  A5-13  M2  settings.json present but not JSON / not a dict / empty / unreadable (EACCES) → fail-closed (contract
         below): `login_backend()` and `vault.store` → file with no CreateItem; a pass over an SS token reads nothing.
         GUARD: a MISSING settings.json keeps the previous choice (SS when unlocked).
  A5-14  M3  publisher, old V2 token in a LOCKED SS, `login` again without `logout` (the locked item cannot be
         deleted): the new token is in the file and `status` prints ONE line about the leftover (contract below);
         `get` = 0.
  A5-15  M4  `publisher --enable` races a login — strict: the token never reaches the SS once `publisher: true` is
         on disk: (a) V2 backend chosen as SS, then enable, then accept_login → no CreateItem, no SS item (login
         may fail or land in the file); (b) `CredentialStore.stage_refresh` with an SS ref on a publisher → not
         `ready`, no CreateItem; (c) legacy `vault.store` re-checks the policy right before CreateItem.
  A5-16  M5/m8  `_real_guard` hardening — `test_zz_isolation.TestGuardSelfTest` (synthetic home in the sandbox).
  A5-17  m6  publisher + V2 ref with backend `keychain` → `publisher_file_required`, `get` = 0, no request, hint.
  A5-18  m7  `publisher --enable` (en/ru) and install.sh warnings carry «where the keyring is unlocked» /
         «там, где хранилище разблокировано».

  M2 contract (tester): `publisher_requires_file()` is fail-closed — settings.json that EXISTS but cannot be read,
  parsed, or is not a JSON object counts as a publisher for the token (file only, Secret Service never read or
  written). Only an ABSENT settings.json means «not a publisher». No unit/marker heuristics: stricter, no D-Bus, no
  dependence on systemd being reachable. (Optional for the developer, not tested: a status line «settings.json is
  unreadable — the GitHub token is kept in a file only».)
  M3 contract: `status` line (en) `Note: an old copy of the token is left in the Secret Service — run ccl-sync logout
  where the keyring is unlocked, then ccl-sync login`; ru `… старая копия токена осталась в хранилище секретов —
  выполните ccl-sync logout там, где хранилище разблокировано, затем ccl-sync login`. Checked: exactly one line with
  «old copy»/«старая копия», containing «Secret Service»/«хранилищ», «unlocked»/«разблокирован», logout → login.
  m7 contract: enable/install warnings end «… run ccl-sync logout where the keyring is unlocked, then ccl-sync
  login» / «… выполните ccl-sync logout там, где хранилище разблокировано, затем ccl-sync login».

Text contract chosen by the tester (developer: implement exactly this, or ask Yurka). Tests check the marked parts:
  * login «Done» line (existing format): en `Done. GitHub: <login>  (token in file <path>)`,
    ru `Готово. GitHub: <login>  (токен в файле <path>)` — checked: «token in file»/«токен в файле», no
    «Secret Service»/«хранилище секретов» on that line.
  * re-login hint (status line and `lastError` of the pass), one line:
      en `GitHub: <login> — the token is in the Secret Service, a publisher keeps it only in a file: run ccl-sync logout
         (where the keyring is unlocked), then ccl-sync login`
      ru `GitHub: <login> — токен в хранилище секретов, а издатель хранит его только в файле: выполните ccl-sync logout
         (там, где хранилище разблокировано), затем ccl-sync login`
    checked: status line starts with «GitHub:»; it contains «Secret Service» (en) / «хранилищ» (ru), «ccl-sync logout»
    and, after it, «ccl-sync login»; `lastError` contains «ccl-sync logout» then «ccl-sync login».
  * enable warning (`publisher --enable`, after «Publisher enabled.»):
      en `Warning: the GitHub token is in the Secret Service; a publisher keeps it only in a file. Nothing was moved:
         run ccl-sync logout, then ccl-sync login`
      ru `Внимание: токен GitHub в хранилище секретов, а издатель хранит его только в файле. Ничего не перенесено:
         выполните ccl-sync logout, затем ccl-sync login`
    install.sh prints the ru text. Checked: a line with «Warning»/«Внимание», «Secret Service»/«хранилищ»,
    «ccl-sync logout» then «ccl-sync login».
  NOT done (decision of Yurka 2026-10-18): automatic migration of an existing Secret Service token into the file.

Run: cd linux && python3 -m unittest tests.test_rl_a5_publisher_token -v   (≈ 5 s, no network, no D-Bus, no systemctl)
"""

if __package__:
    from . import _rl_env as rl
    from . import _sync_env as env
    from .test_rl_install import run_install, settings_of, EXPECTED
else:
    import _rl_env as rl
    import _sync_env as env
    from test_rl_install import run_install, settings_of, EXPECTED

import contextlib
import io
import json
import os
import re
import shutil
import stat
import tempfile
import unittest
from unittest.mock import patch

from ccl import cli, common, sync, vault


def tearDownModule():
    rl.assert_real_files_untouched()


def mode_of(path):
    return stat.S_IMODE(os.stat(path).st_mode)


def hint_ok(text):
    """«ccl-sync logout» first, then «ccl-sync login» (the order the owner must follow)."""
    return bool(re.search(r"ccl-sync logout\b.*\bccl-sync login\b", text or "", re.S))


class Base(env.SyncEnv):
    def setUp(self):
        super().setUp()
        self._timer = patch.object(cli, "_timer_status", return_value="test timer")
        self._timer.start()
        self.addCleanup(self._timer.stop)
        common.settings().update(lang="en")

    # ---- helpers -----------------------------------------------------------------------------------------------
    def publisher(self, on=True):
        common.settings().update(publisher=on)

    def lang(self, value):
        common.settings().update(lang=value)

    def run_cli(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = cli.main(list(argv))
        return rc, out.getvalue() + err.getvalue()

    def credential_files(self):
        names = []
        if os.path.isdir(common.CONFIG_DIR):
            base = os.path.basename(common.TOKEN_FILE_PATH)
            names = [n for n in os.listdir(common.CONFIG_DIR) if base in n]
        directory = os.path.join(common.CONFIG_DIR, "github-credentials")
        if os.path.isdir(directory):
            names.extend("github-credentials/" + n for n in os.listdir(directory))
        return sorted(names)

    def script_device_login(self, token, login="me"):
        self.gh.on("POST", "https://github.com/login/device/code", env.resp(200, {
            "device_code": "dc", "user_code": "UC-T", "interval": 0.01, "expires_in": 60,
            "verification_uri": "https://github.com/login/device"}))
        self.gh.on("POST", "https://github.com/login/oauth/access_token",
                   env.resp(200, dict(access_token=token, refresh_token=env.make_token())))
        self.gh.on("GET", "/user", env.resp(200, {"id": 7, "login": login}))

    def cli_login(self, token=None):
        """The real `ccl-sync login` (Device Flow → V2 owner → CredentialStore); the push after it is skipped."""
        self.enable_v2_login()
        self.script_device_login(token or self.token)
        with patch.object(cli, "cmd_push", return_value=0):
            return self.run_cli("login", "--force", "--no-browser")

    def done_line(self, out):
        lines = [ln for ln in out.splitlines() if ln.startswith(("Done. GitHub:", "Готово. GitHub:"))]
        self.assertEqual(len(lines), 1, out)
        return lines[0]

    def v2_login_in_secret_service(self):
        """Reproduce the incident: login on an unlocked desktop keyring (publisher off, as before the fix)."""
        self.publisher(False)
        rc, out = self.cli_login()
        self.assertEqual(rc, 0, out)
        _credential, ref = self.credential()
        self.assertEqual(ref["backend"], "secret-service", "стенд: вход до фикса — в хранилище секретов")
        self.publisher(True)
        return ref

    def lock_v2(self, ref):
        """What the systemd timer sees: the item exists, but only in a locked collection."""
        self.v2ss.items.pop(ref["generation"], None)
        self.v2ss.locked.add(ref["generation"])

    def legacy_login_in_secret_service(self):
        self.publisher(False)
        generation, backend = self.sign_in(gist=None)
        self.assertEqual(backend, "secret-service")
        self.publisher(True)
        return generation

    def lock_legacy(self, generation):
        self.ss.items.pop(generation, None)
        self.ss.locked.add(generation)

    def status(self):
        rc, out = self.run_cli("status")
        self.assertEqual(rc, 0, out)
        self.assertNotIn("Traceback", out)
        return out

    def github_line(self, out):
        lines = [ln for ln in out.splitlines() if ln.startswith("GitHub:")]
        self.assertEqual(len(lines), 1, out)
        return lines[0]


# ==== A5-01 / A5-02 — legacy store ===================================================================================
class TestA501VaultStorePublisherFileOnly(Base):
    def test_write_goes_to_file_0600_and_never_to_secret_service(self):
        self.publisher(True)
        with patch.object(self.ss, "set", wraps=self.ss.set) as create_item, \
                common.file_lock("sync") as held:
            self.assertTrue(held)
            backend = vault.write(self.token)
        self.assertEqual(create_item.call_count, 0, "S4: у издателя CreateItem в хранилище секретов не вызывается")
        self.assertEqual(self.ss.items, {}, "S4: в хранилище секретов токена нет")
        self.assertEqual(backend, "file")
        self.assertEqual(vault.active(self.st())[1], "file")
        self.assertEqual(mode_of(common.TOKEN_FILE_PATH), 0o600)
        self.assertEqual(vault.read(), (self.token, "file"))

    def test_store_reference_is_file(self):
        self.publisher(True)
        with patch.object(self.ss, "set", wraps=self.ss.set) as create_item, \
                common.file_lock("sync") as held:
            self.assertTrue(held)
            generation, backend = vault.store(self.token)
            vault.delete_ref(generation, backend)
        self.assertEqual((backend, create_item.call_count), ("file", 0))


class TestA502LegacyLoginFinish(Base):
    def test_login_finish_with_plain_token_stores_file(self):
        self.publisher(True)
        self.gh.on("GET", "/user", env.resp(200, {"id": 7, "login": "me"}))
        with patch.object(self.ss, "set", wraps=self.ss.set) as create_item:
            self.assertEqual(sync.login_finish(self.token), "me")
        self.assertEqual(create_item.call_count, 0)
        self.assertEqual(self.ss.items, {})
        self.assertEqual(self.st().get("tokenBackend"), "file")
        self.assertEqual(mode_of(common.TOKEN_FILE_PATH), 0o600)


# ==== A5-03 / A5-04 — the real `ccl-sync login` (V2) =================================================================
class TestA503LoginBackend(Base):
    def test_publisher_login_backend_is_file_with_unlocked_keyring(self):
        self.enable_v2_login()
        self.publisher(True)
        self.assertEqual(self.auth_owner.store.login_backend(), "file")


class TestA504CliLoginPublisher(Base):
    def test_cli_login_stores_envelope_in_file_0600(self):
        for lang, phrase in (("en", "token in file"), ("ru", "токен в файле")):
            with self.subTest(lang=lang):
                self.publisher(True)
                self.lang(lang)
                self.st().update(tokenGeneration="")
                self.enable_v2_login()
                with patch.object(self.v2ss, "set", wraps=self.v2ss.set) as create_item:
                    rc, out = self.cli_login(env.make_token())
                self.assertEqual(rc, 0, out)
                self.assertEqual(create_item.call_count, 0, "S4: CreateItem у издателя не вызывается")
                self.assertEqual(self.v2ss.items, {}, "S4: конверта входа в хранилище секретов нет")
                _credential, ref = self.credential()
                self.assertEqual(ref["backend"], "file")
                files = [n for n in self.credential_files() if n.startswith("github-credentials/")]
                self.assertEqual(files, ["github-credentials/" + ref["generation"]])
                self.assertEqual(mode_of(os.path.join(common.CONFIG_DIR, files[0])), 0o600)
                line = self.done_line(out)
                self.assertIn(phrase, line)
                self.assertNotIn("Secret Service", line)
                self.assertNotIn("хранилище секретов", line)
                rc, out = self.run_cli("logout")
                self.assertEqual(rc, 0, out)


# ==== A5-05 GUARD — publisher off: unchanged =========================================================================
class TestA505GuardNotPublisher(Base):
    def test_vault_write_prefers_unlocked_secret_service(self):
        for value in (False, None):
            with self.subTest(publisher=value):
                if value is None:
                    common.settings().update(publisher=None)
                else:
                    self.publisher(value)
                with common.file_lock("sync") as held:
                    self.assertTrue(held)
                    self.assertEqual(vault.write(env.make_token()), "secret-service")

    def test_cli_login_prefers_unlocked_secret_service(self):
        self.publisher(False)
        rc, out = self.cli_login()
        self.assertEqual(rc, 0, out)
        _credential, ref = self.credential()
        self.assertEqual(ref["backend"], "secret-service")
        self.assertEqual(len(self.v2ss.items), 1)
        self.assertIn("token in the Secret Service", self.done_line(out))


# ==== A5-06 / A5-07 — status of a publisher whose token is in the Secret Service =====================================
class TestA506StatusHint(Base):
    def check(self, out, lang):
        line = self.github_line(out)
        self.assertTrue(hint_ok(line), "подсказка: ccl-sync logout, затем ccl-sync login — " + line)
        self.assertIn("Secret Service" if lang == "en" else "хранилищ", line)
        self.assertNotIn("unlock KWallet", out, "под таймером хранилище не разблокируется — совет вводит в заблуждение")
        self.assertNotIn("разблокируйте KWallet", out)

    def test_v2_locked(self):
        ref = self.v2_login_in_secret_service()
        self.lock_v2(ref)
        for lang in ("en", "ru"):
            with self.subTest(lang=lang):
                self.lang(lang)
                self.check(self.status(), lang)

    def test_v2_unlocked(self):
        self.v2_login_in_secret_service()
        for lang in ("en", "ru"):
            with self.subTest(lang=lang):
                self.lang(lang)
                self.check(self.status(), lang)

    def test_legacy_locked(self):
        self.lock_legacy(self.legacy_login_in_secret_service())
        self.check(self.status(), "en")

    def test_legacy_unlocked(self):
        self.legacy_login_in_secret_service()
        self.check(self.status(), "en")


class TestA507GuardStatusFileToken(Base):
    def test_file_token_no_hint(self):
        self.publisher(False)
        self.enable_v2_login()
        with patch.object(self.v2ss, "_unlocked", return_value=[]):    # keyring unusable → file, today too
            rc, out = self.cli_login()
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.credential()[1]["backend"], "file")
        self.publisher(True)
        line = self.github_line(self.status())
        self.assertTrue(line.startswith("GitHub: me  (token: "), line)
        self.assertNotIn("ccl-sync logout", line)


# ==== A5-08 — the publisher pass =====================================================================================
class TestA508PassLockedSecretService(Base):
    def test_open_cycle_records_relogin_hint(self):
        self.lock_v2(self.v2_login_in_secret_service())
        before = len(self.gh.calls)
        self.assertIsNone(sync.open_cycle(auto=True))
        self.assertEqual(len(self.gh.calls), before, "без токена — ни одного запроса")
        error = self.st().get("lastError")
        self.assertTrue(hint_ok(error), "lastError прохода — подсказка перелогиниться, а не «ждём разблокировки»: %r"
                        % (error,))
        self.assertNotIn("after unlocking", error or "")


class TestA511PassUnlockedSecretService(Base):
    """Decision of Yurka 2026-10-18: with `publisher: true` the pass never reads the token from the Secret Service,
    even an unlocked one (cron/desktop session with a live D-Bus) — same hint as A5-08."""

    def test_open_cycle_refuses_unlocked_secret_service_token(self):
        ref = self.v2_login_in_secret_service()
        self.assertIn(ref["generation"], self.v2ss.items, "стенд: токен в разблокированном хранилище")
        requests = []

        def any_request(url, method, headers, body, timeout):
            requests.append((method, url))
            return env.resp(503, {"message": "fixture"})
        sync.transport = any_request          # restored by SyncEnv.tearDown; a request must not crash the pass
        with patch.object(self.v2ss, "get", wraps=self.v2ss.get) as read_secret:
            self.assertIsNone(sync.open_cycle(auto=True))
        self.assertEqual(read_secret.call_count, 0, "S4: издатель не читает токен из хранилища секретов")
        self.assertEqual(requests, [], "без токена из файла — ни одного запроса")
        error = self.st().get("lastError")
        self.assertTrue(hint_ok(error), "lastError — подсказка перелогиниться: %r" % (error,))


# ==== A5-09 — `ccl-sync publisher --enable` ==========================================================================
class TestA509EnableWarns(Base):
    SIGN_IN_KEYS = ("login", "tokenGeneration", "tokenBackend", "authV2", "tokenDeletePending")

    def enable(self):
        self.publisher(False)
        before = {k: self.st().get(k) for k in self.SIGN_IN_KEYS}
        items = (dict(self.v2ss.items) if self.v2ss else None, dict(self.ss.items))
        files = self.credential_files()
        calls = []
        real_v2, real_v1 = vault._ss_v2, vault._ss
        with patch.object(vault, "_ss_v2", side_effect=lambda: calls.append("v2") or real_v2()), \
                patch.object(vault, "_ss", side_effect=lambda: calls.append("v1") or real_v1()):
            rc, out = self.run_cli("publisher", "--enable")
        self.assertEqual(rc, 0, out)
        self.assertIs(common.settings().get("publisher"), True)
        self.st().reload()
        self.assertEqual({k: self.st().get(k) for k in self.SIGN_IN_KEYS}, before, "вход не переносится")
        self.assertEqual((dict(self.v2ss.items) if self.v2ss else None, dict(self.ss.items)), items)
        self.assertEqual(self.credential_files(), files, "файла токена не появилось")
        self.assertEqual(calls, [], "решение — по несекретному состоянию, без D-Bus (P1)")
        return out

    def warning(self, out):
        return [ln for ln in out.splitlines() if ln.startswith(("Warning", "Внимание"))]

    def test_v2_secret_service(self):
        for lang, word in (("en", "Secret Service"), ("ru", "хранилищ")):
            with self.subTest(lang=lang):
                self.v2_login_in_secret_service()
                self.lang(lang)
                lines = self.warning(self.enable())
                self.assertEqual(len(lines), 1, "одно предупреждение")
                self.assertIn(word, lines[0])
                self.assertTrue(hint_ok(lines[0]), lines[0])

    def test_legacy_secret_service(self):
        self.legacy_login_in_secret_service()
        lines = self.warning(self.enable())
        self.assertEqual(len(lines), 1)
        self.assertTrue(hint_ok(lines[0]), lines[0])

    def test_guard_file_token_no_warning(self):
        self.enable_v2_login()
        with patch.object(self.v2ss, "_unlocked", return_value=[]):
            rc, out = self.cli_login()
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.warning(self.enable()), [])

    def test_guard_not_signed_in_no_warning(self):
        self.assertEqual(self.warning(self.enable()), [])


# ==== A5-10 — install.sh --publisher ==================================================================================
class TestA510InstallWarns(Base):
    def install_over(self, state_bytes):
        tmp = tempfile.mkdtemp(prefix="ccl-a5-install-", dir="/tmp")
        self.addCleanup(shutil.rmtree, tmp, True)
        state_dir = os.path.join(tmp, "home", ".local", "state", "claude-codex-limits")
        os.makedirs(state_dir, mode=0o700)
        state_path = os.path.join(state_dir, "sync-state.json")
        with open(state_path, "wb") as f:
            f.write(state_bytes)
        r = run_install(tmp, ["--publisher", "--no-tray", "--name", "vps"])
        self.assertEqual(r.rc, 0, r.out[-1500:])
        obj = json.loads(settings_of(r))
        self.assertEqual({k: obj.get(k) for k in EXPECTED}, EXPECTED)
        with open(state_path, "rb") as f:
            self.assertEqual(f.read(), state_bytes, "sync-state.json не меняется: переноса нет")
        conf = os.path.join(r.conf, "claude-codex-limits")
        leftovers = [n for n in os.listdir(conf) if n.startswith("github-")] if os.path.isdir(conf) else []
        self.assertEqual(leftovers, [], "файла токена не появилось")
        return r.out

    def state_bytes(self):
        with open(common.SYNC_STATE_PATH, "rb") as f:
            return f.read()

    def warning(self, out):
        # install.sh already prints «Внимание: … нет в PATH» in this sandbox: only the keyring warning counts.
        return [ln for ln in out.splitlines() if "Внимание" in ln and "хранилищ" in ln]

    def test_v2_secret_service_state(self):
        self.v2_login_in_secret_service()
        lines = self.warning(self.install_over(self.state_bytes()))
        self.assertEqual(len(lines), 1, "одно предупреждение в выводе install.sh")
        self.assertIn("хранилищ", lines[0])
        self.assertTrue(hint_ok(lines[0]), lines[0])

    def test_legacy_secret_service_state(self):
        self.legacy_login_in_secret_service()
        lines = self.warning(self.install_over(self.state_bytes()))
        self.assertEqual(len(lines), 1)
        self.assertTrue(hint_ok(lines[0]), lines[0])

    def test_guard_file_state_no_warning(self):
        self.enable_v2_login()
        with patch.object(self.v2ss, "_unlocked", return_value=[]):
            rc, out = self.cli_login()
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.warning(self.install_over(self.state_bytes())), [])


# ==== Fix cycle A5 №1 (docs/review-remote-limits-a5-s4.md M1; docs/security-remote-limits-a5-s4-t2.md M1–M4, m6, m7) ====
class FixBase(Base):
    def permissive_transport(self):
        """Every request answers 503 and is recorded: a request must not crash the pass, only be counted."""
        requests = []

        def any_request(url, method, headers, body, timeout):
            requests.append((method, url))
            return env.resp(503, {"message": "fixture"})
        sync.transport = any_request          # restored by SyncEnv.tearDown
        return requests

    def spy(self, fake, name):
        guard = patch.object(fake, name, wraps=getattr(fake, name))
        mock = guard.start()
        self.addCleanup(guard.stop)
        return mock

    def corrupt_settings(self, how):
        path = common.SETTINGS_PATH
        if how == "eacces":
            os.chmod(path, 0)                    # restored by the caller before the next variant
            return
        with open(path, "w") as f:
            f.write({"not-json": "{publisher: true", "not-dict": "[]", "empty": ""}[how])


class TestA512LegacyStateWithoutGeneration(FixBase):
    """M1: a pre-0.3.1 state ({login} without tokenGeneration/tokenBackend) on a publisher never reaches the SS."""

    def setUp(self):
        super().setUp()
        self.ss.items["legacy"] = self.token                  # the old keyring item, UNLOCKED
        self.publisher(True)
        self.st().update(login="me", gistId=env.GIST, discoveredAt=0)
        self.assertFalse(self.st().has("tokenGeneration"))
        self.get = self.spy(self.ss, "get")
        self.factory = patch.object(vault, "_ss", wraps=vault._ss)
        self.ss_factory = self.factory.start()
        self.addCleanup(self.factory.stop)

    def test_ensure_access_and_read(self):
        result = sync.ensure_access(reason="status")
        self.assertNotEqual(result.kind, "ready")
        self.assertEqual((self.get.call_count, self.ss_factory.call_count), (0, 0), "S4: Secret Service не читается")

    def test_pass_records_relogin_hint(self):
        requests = self.permissive_transport()
        self.assertIsNone(sync.open_cycle(auto=True))
        self.assertEqual((self.get.call_count, requests), (0, []))
        self.assertTrue(hint_ok(self.st().get("lastError")), self.st().get("lastError"))

    def test_status_hint(self):
        self.permissive_transport()
        out = self.status()
        self.assertEqual(self.get.call_count, 0)
        self.assertTrue(hint_ok(self.github_line(out)), out)
        self.assertNotIn("unlock KWallet", out)

    def test_legacy_file_still_without_secret_service(self):
        """A legacy FILE on a publisher: S4 holds either way — read from the file or ask to sign in again —
        but the Secret Service is never contacted (contract: no SS discovery on a publisher)."""
        del self.ss.items["legacy"]
        common.ensure_dirs()
        with open(common.TOKEN_FILE_PATH, "w") as f:
            f.write(self.token + "\n")
        result = sync.ensure_access(reason="status")
        self.assertEqual((self.get.call_count, self.ss_factory.call_count), (0, 0))
        self.assertIn((result.kind, result.reason), (("ready", None), ("actionRequired", "publisher_file_required")))


class TestA513CorruptSettingsFailClosed(FixBase):
    """M2: settings.json present but unreadable / not JSON / not a dict → the S4 policy is NOT lifted.
    Contract (tester): `publisher` unknown because settings.json exists but cannot be used → treat as a publisher
    for the token (file only, never read the SS). A MISSING settings.json keeps the previous behaviour."""
    CASES = ("not-json", "not-dict", "empty", "eacces")

    def test_login_backend_and_store_choose_file(self):
        self.enable_v2_login()
        for how in self.CASES:
            with self.subTest(how=how):
                self.publisher(True)
                self.corrupt_settings(how)
                try:
                    self.assertEqual(self.auth_owner.store.login_backend(), "file")
                    create_item = self.spy(self.ss, "set")
                    with common.file_lock("sync") as held:
                        self.assertTrue(held)
                        generation, backend = vault.store(env.make_token())
                        vault.delete_ref(generation, backend)
                    self.assertEqual((backend, create_item.call_count), ("file", 0))
                finally:
                    os.chmod(common.SETTINGS_PATH, 0o600)

    def test_pass_does_not_read_secret_service(self):
        ref = self.v2_login_in_secret_service()
        get = self.spy(self.v2ss, "get")
        requests = self.permissive_transport()
        for how in self.CASES:
            with self.subTest(how=how):
                get.reset_mock()
                del requests[:]
                self.publisher(True)
                self.corrupt_settings(how)
                try:
                    self.assertIsNone(sync.open_cycle(auto=True))
                    self.assertEqual((get.call_count, requests), (0, []), "fail-closed: SS не читается")
                finally:
                    os.chmod(common.SETTINGS_PATH, 0o600)
        self.assertIn(ref["generation"], self.v2ss.items)

    def test_guard_missing_settings_keeps_secret_service(self):
        self.enable_v2_login()
        if os.path.exists(common.SETTINGS_PATH):
            os.unlink(common.SETTINGS_PATH)
        common.settings().reload()
        self.assertEqual(self.auth_owner.store.login_backend(), "secret-service")


class TestA514LeftoverCopyAfterRelogin(FixBase):
    """M3: publisher, the old V2 token in a LOCKED SS, `login` again without `logout` (SSH / timer environment):
    the new token goes to the file, the old copy cannot be deleted — `status` says so (contract: a line with
    «old copy … Secret Service … ccl-sync logout where the keyring is unlocked, then ccl-sync login»)."""

    def test_status_reports_the_leftover(self):
        ref = self.v2_login_in_secret_service()
        self.lock_v2(ref)
        original_delete = self.v2ss.delete
        self.v2ss.delete = lambda generation: False if generation in self.v2ss.locked else original_delete(generation)
        rc, out = self.cli_login(env.make_token())
        self.assertEqual(rc, 0, out)
        self.assertEqual(self.credential()[1]["backend"], "file", "стенд: новый вход — в файл")
        get = self.spy(self.v2ss, "get")
        for lang, words in (("en", ("old copy", "Secret Service", "unlocked")),
                            ("ru", ("старая копия", "хранилищ", "разблокирован"))):
            with self.subTest(lang=lang):
                self.lang(lang)
                out = self.status()
                lines = [ln for ln in out.splitlines() if words[0] in ln]
                self.assertEqual(len(lines), 1, out)
                for word in words[1:]:
                    self.assertIn(word, lines[0])
                self.assertTrue(hint_ok(lines[0]), lines[0])
        self.assertEqual(get.call_count, 0)


class TestA515EnableRacesLogin(FixBase):
    """M4: `publisher --enable` lands while a login is in flight. Strict contract: the token NEVER reaches the SS
    once `publisher: true` is on disk — the write layer re-checks the policy right before CreateItem."""

    def test_v2_login_backend_chosen_before_enable(self):
        self.enable_v2_login()
        self.publisher(False)
        store = self.auth_owner.store
        original = store.login_backend

        def chosen_then_enabled():
            backend = original()
            self.publisher(True)                     # `publisher --enable` wins the race right here
            return backend
        create_item = self.spy(self.v2ss, "set")
        with patch.object(store, "login_backend", side_effect=chosen_then_enabled):
            rc, out = self.cli_login()
        self.assertEqual(create_item.call_count, 0, "S4: после включения издателя CreateItem не вызывается")
        self.assertEqual(self.v2ss.items, {})
        if rc == 0:
            self.assertEqual(self.credential()[1]["backend"], "file")

    def test_v2_refresh_into_secret_service_refused(self):
        self.enable_v2_login()
        self.publisher(True)
        create_item = self.spy(self.v2ss, "set")
        ref = dict(generation="ab" * 16, backend="secret-service", epoch="cd" * 16)
        result = self.auth_owner.store.stage_refresh(ref, "fixture-envelope")
        self.assertNotEqual(result, "ready")
        self.assertEqual((create_item.call_count, self.v2ss.items), (0, {}))

    def test_legacy_store_rechecks_before_create_item(self):
        self.publisher(False)
        real_factory = vault._ss

        def factory_after_enable():
            self.publisher(True)                     # enabled after store() began, before CreateItem
            return real_factory()
        create_item = self.spy(self.ss, "set")
        with patch.object(vault, "_ss", side_effect=factory_after_enable), common.file_lock("sync") as held:
            self.assertTrue(held)
            generation, backend = vault.store(self.token)
            vault.delete_ref(generation, backend)
        self.assertEqual((create_item.call_count, self.ss.items), (0, {}))
        self.assertEqual(backend, "file")


class TestA517KeychainBackend(FixBase):
    """m6: a V2 ref with backend `keychain` (valid_ref accepts it; Linux reads it as SS) on a publisher."""

    def test_keychain_ref_is_not_read(self):
        ref = self.v2_login_in_secret_service()
        st = self.st()
        manifest = json.loads(json.dumps(st.get("authV2")))
        manifest["active"]["backend"] = "keychain"
        st.update(authV2=manifest)
        get = self.spy(self.v2ss, "get")
        requests = self.permissive_transport()
        result = sync.ensure_access(reason="status")
        self.assertEqual((result.kind, result.reason), ("actionRequired", "publisher_file_required"))
        self.assertIsNone(sync.open_cycle(auto=True))
        self.assertEqual((get.call_count, requests), (0, []))
        self.assertTrue(hint_ok(self.github_line(self.status())))
        self.assertIn(ref["generation"], self.v2ss.items)


class TestA518WarningsSayWhereToLogout(FixBase):
    """m7: the `publisher --enable` and install.sh warnings carry «where the keyring is unlocked»
    (ru «там, где хранилище разблокировано»), like the status hint."""

    def enable_warning(self):
        self.publisher(False)
        rc, out = self.run_cli("publisher", "--enable")
        self.assertEqual(rc, 0, out)
        return [ln for ln in out.splitlines() if ln.startswith(("Warning", "Внимание"))]

    def test_enable_warning(self):
        for lang, phrase in (("en", "where the keyring is unlocked"), ("ru", "там, где хранилище разблокировано")):
            with self.subTest(lang=lang):
                self.v2_login_in_secret_service()
                self.lang(lang)
                lines = self.enable_warning()
                self.assertEqual(len(lines), 1)
                self.assertIn(phrase, lines[0])

    def test_install_warning(self):
        self.v2_login_in_secret_service()
        with open(common.SYNC_STATE_PATH, "rb") as f:
            state = f.read()
        lines = [ln for ln in TestA510InstallWarns.install_over(self, state).splitlines()
                 if "Внимание" in ln and "хранилищ" in ln]
        self.assertEqual(len(lines), 1)
        self.assertIn("там, где хранилище разблокировано", lines[0])


if __name__ == "__main__":
    unittest.main()
