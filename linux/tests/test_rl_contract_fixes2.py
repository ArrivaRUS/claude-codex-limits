"""REMOTE-LIMITS A1 — fix cycle 2 after code review 2 + security review T2-r2 (docs/test-plan-remote-limits.md A1-25…A1-32).

Sources: docs/review-remote-limits-a1-r2.md (r2-m2, r2-m3, r2-m4, n1, n3, n4) and docs/security-remote-limits-a1-t2-r2.md
(R2, R3, R4, recommendations §6 (1)/(2), mandatory checks §4). Scope: docs/plans.md §A1, line «Ревью 2».
Written BEFORE the fixes ("red first"): every test marked «Red now» fails on HEAD f292ef2 for the reason named in its
docstring; tests marked «Green guard» pass now and must stay green after the fixes.

A1-18 is extended here as A1-25 (a superset of `test_refused_redirect_skips_the_file_not_the_cycle`); the original test
in test_rl_contract_fixes.py is left untouched and green, none of its assertions is weakened.

Offline, same sandbox as test_rl_contract_fixes.py (`_rl_env`: temp HOME/XDG before imports, audit hook on the real
~/.claude*/~/.codex, `common.http`/`sync.transport` forbidden, sockets refused). HTTP-level tests run the real
`common.http` from a fresh copy of ccl/common.py with urllib's HTTP(S) handlers replaced by an in-memory server.

Run: python3 -m unittest linux/tests/test_rl_contract_fixes2.py -v   (from PROJECT_ROOT)
"""

if __package__:
    from . import _rl_env as rl
    from . import test_rl_contract as c1
    from . import test_rl_contract_fixes as f1
else:
    import _rl_env as rl
    import test_rl_contract as c1
    import test_rl_contract_fixes as f1

import contextlib
import errno
import json
import os
import re
import time
import unicodedata
import unittest
from types import SimpleNamespace
from unittest import mock

from ccl import cli, common, sync, usage

accounts = c1.accounts
MiB = c1.MiB
dumps, machine_obj, terminal_unsafe, lone_surrogates = f1.dumps, f1.machine_obj, f1.terminal_unsafe, f1.lone_surrogates
SIZE_ERROR = f1.SIZE_ERROR
# A distinctive secret raw path: none of its pieces may reach lastError / sync-state.json.
SECRET_GIST = "SECRETGISTID0001"
SECRET_SHA = "f00dfeedcafe"
RAW_S = "https://gist.githubusercontent.com/u/" + SECRET_GIST + "/raw/" + SECRET_SHA + "/machine-%s.json"
REFUSAL = re.compile(r"(?i)redirect|редирект|raw.?url|отклон|refused|недопустим|invalid")
LITERAL_TOO_LARGE = "response body too large"


def tearDownModule():
    rl.assert_real_files_untouched()


class RecordingServer(f1.FakeServer):
    """FakeServer that also logs the headers of every request and serves any status code."""

    def __init__(self):
        super().__init__()
        self.requests = []  # (url, all headers incl. unredirected, normal headers only)

    def status(self, url, code, size=None, data=b""):
        self.routes[url] = (code, {}, data, size)

    def _open(self, handler, req):
        self.requests.append((req.full_url, dict(req.header_items()), dict(req.headers)))
        return super()._open(handler, req)


def lower_keys(headers):
    return {k.lower(): v for k, v in headers.items()}


class Base(f1.Base):
    def wire_recording(self):
        f1.Base.wire_http(self)
        return RecordingServer()

    def assert_no_raw_leak(self, text, where, extra=()):
        for needle in ("gist.githubusercontent.com", SECRET_GIST, SECRET_SHA, "/raw/", "g1") + tuple(extra):
            self.assertNotIn(needle, text, "%s leaks %r (the raw path is secret)" % (where, needle))


# ---- A1-25 (R3 / r2-m2, extends A1-18) a refused raw transition is skipped VISIBLY ------------------------------
class TestA125RawRefusalVisible(Base):
    def run_refusal_cycle(self, server, others, what):
        self.sign_in()
        self.mark_pushed()
        self.gh.on("GET", "/gists/g1", self.ok_gist(others))
        started = time.time()
        with server.installed():
            res = self.run_cycle(what)
        return res, started

    def check(self, res, started, extra=()):
        st = self.st()
        self.assertIn("good", self.machine_ids(res), "one refused file must not stop reading the others")
        self.assertEqual(res.remote["days"]["claude"][common.today_key()]["good-model"]["input"], 5)
        self.assertNotIn("bad", self.machine_ids(res))
        self.assertGreaterEqual(st.get("lastOkAt") or 0, started - 1, "R1 semantics: the gist was read, lastOkAt moves")
        self.assertTrue(os.path.exists(common.SYNC_REMOTE_PATH))
        self.assertFalse(res.ok, "a skipped file is a visible error, like a too-large file (R1)")
        err = str(st.get("lastError") or "")
        self.assertRegex(err, REFUSAL, "lastError names the refused redirect / raw_url")
        self.assertIsNotNone(st.get("lastErrorAt"))
        self.assert_no_raw_leak(err, "lastError", extra)
        self.assert_no_raw_leak(str(res.error or ""), "res.error", extra)
        state = self.state_text()
        for needle in ("gist.githubusercontent.com", SECRET_GIST, SECRET_SHA) + tuple(extra):
            self.assertNotIn(needle, state, "sync-state.json leaks %r" % needle)

    def test_refused_redirect_is_skipped_with_a_visible_error(self):
        """Red now: `sync.py` `continue`s on RAW_REDIRECT_REFUSED — res.ok=True, lastError=None (machine vanishes silently)."""
        server = self.wire_recording()
        bad_dst = "http://gist.githubusercontent.com/u/" + SECRET_GIST + "/raw/" + SECRET_SHA + "/machine-bad.json"
        server.redirect(RAW_S % "bad", bad_dst)
        server.ok(bad_dst, dumps(machine_obj("bad")).encode())
        server.ok(RAW_S % "good", dumps(machine_obj("good", model="good-model", n=5)).encode())
        others = {"machine-%s.json" % m: {"truncated": True, "raw_url": RAW_S % m, "content": ""} for m in ("bad", "good")}
        res, started = self.run_refusal_cycle(server, others, "refused redirect on raw_url")
        self.assertNotIn(bad_dst, server.opened)
        self.check(res, started)

    def test_foreign_raw_url_from_api_is_refused_before_transport_with_a_visible_error(self):
        """Red now: a raw_url outside gist.githubusercontent.com is refused (0 requests) but silently: res.ok=True, no lastError."""
        server = self.wire_recording()
        cases = {
            "foreign host": "https://evil.example/u/" + SECRET_GIST + "/raw/" + SECRET_SHA + "/machine-bad.json",
            "plain http": "http://gist.githubusercontent.com/u/" + SECRET_GIST + "/raw/" + SECRET_SHA + "/machine-bad.json",
        }
        server.ok(RAW_S % "good", dumps(machine_obj("good", model="good-model", n=5)).encode())
        for what, bad_url in cases.items():
            with self.subTest(what):
                server.ok(bad_url, dumps(machine_obj("bad")).encode())
                others = {"machine-bad.json": {"truncated": True, "raw_url": bad_url, "content": ""},
                          "machine-good.json": {"truncated": True, "raw_url": RAW_S % "good", "content": ""}}
                self.st().update(lastError=None, lastErrorAt=None)
                res, started = self.run_refusal_cycle(server, others, what)
                self.assertNotIn(bad_url, server.opened, "refused before any request")
                self.check(res, started, extra=("evil.example",))


# ---- A1-26 (N1 second line, rec. 1 of T2-r2) a failed write of sync-remote.json is an error, not a crash --------
class TestA126CacheWriteFailure(Base):
    HOSTILE_NAME = "evilname7"  # a gist-controlled string: must never reach lastError

    def failing_writes(self, exc, also_state_after=False):
        """common.write_json raises `exc` for sync-remote.json; optionally every later state write fails too (disk full)."""
        real = common.write_json
        broken = {"remote": False}

        def write_json(path, obj, *a, **kw):
            if path == common.SYNC_REMOTE_PATH:
                broken["remote"] = True
                raise exc
            if also_state_after and broken["remote"] and path == common.SYNC_STATE_PATH:
                raise OSError(errno.ENOSPC, "No space left on device: SECRET-/home/alice/.state")
            return real(path, obj, *a, **kw)

        return mock.patch.object(common, "write_json", write_json)

    def prepare(self):
        self.sign_in()
        self.mark_pushed()
        self.st().update(lastOkAt=1000.0)

    def cycle_once(self, what):
        """One cycle against a gist with one good machine (the scripted GET is consumed per cycle)."""
        others = {"machine-good.json": dumps(machine_obj("good", name=self.HOSTILE_NAME, model="good-model", n=5))}
        self.gh.on("GET", "/gists/g1", self.ok_gist(others))
        try:
            return self.cycle()
        except Exception as e:  # the defect itself: a local disk failure must become an error, not a traceback
            self.fail("%s: sync_cycle raised %r — the failed cache write escaped the cycle" % (what, e))

    def test_oserror_on_cache_write_is_a_fixed_error_and_lastOkAt_stays(self):
        """Red now: OSError from common.write_json(SYNC_REMOTE_PATH) escapes sync_cycle (traceback under the timer)."""
        self.prepare()
        errors = []
        for exc in (OSError(errno.ENOSPC, "No space left on device: SECRET-/home/alice/x"),
                    PermissionError(errno.EACCES, "Permission denied: SECRET-/home/alice/y")):
            with self.subTest(exc=exc.__class__.__name__):
                self.st().update(lastOkAt=1000.0, lastError=None, lastErrorAt=None)
                with self.failing_writes(exc):
                    res = self.cycle_once("write of sync-remote.json failed")
                st = self.st()
                self.assertFalse(res.ok)
                self.assertEqual(st.get("lastOkAt"), 1000.0, "the cache was not written: lastOkAt must not move")
                err = str(st.get("lastError") or "")
                self.assertTrue(err, "the failure is visible in lastError")
                self.assertEqual(str(res.error or ""), err)
                for needle in ("SECRET", "/home/alice", "No space", "Permission denied", str(errno.ENOSPC),
                               str(errno.EACCES), "Errno", self.HOSTILE_NAME, "good-model"):
                    self.assertNotIn(needle, err, "lastError carries exception text or gist strings: %r" % needle)
                errors.append(err)
        # Compared only between the cases that got this far (the subtests above already report the escape itself).
        self.assertLessEqual(len(set(errors)), 1, "lastError is a fixed text, independent of the exception: %r" % errors)
        # The next cycle recovers once the disk is fine again.
        res = self.cycle_once("recovery after the disk was fixed")
        self.assertTrue(res.ok)
        self.assertGreater(self.st().get("lastOkAt"), 1000.0)
        self.assertIsNone(self.st().get("lastError"))
        self.assertIn("good", [m["id"] for m in common.read_json(common.SYNC_REMOTE_PATH)["machines"]])

    def test_result_survives_when_recording_the_error_fails_too(self):
        """Red now (T2-r2 §6 (1), last sentence): the cache write fails and so does every later state write (disk full);
        sync_cycle must still return a result in memory, not raise from `_fail()`."""
        self.prepare()
        with self.failing_writes(OSError(errno.ENOSPC, "No space left on device"), also_state_after=True):
            res = self.cycle_once("disk full during the cache write and the error record")
        self.assertFalse(res.ok)
        self.assertTrue(res.error, "the error lives in the result even if sync-state.json could not record it")
        self.assertNotIn("No space", str(res.error))


# ---- A1-27 (r2-m3) lone surrogates in the local accountByDay -----------------------------------------------------
class TestA127AccountByDaySurrogate(Base):
    def write_raw_index(self, abd, recent):
        # ensure_ascii=True: the file stays valid UTF-8 and carries the JSON escape \ud800 (what a corrupt index holds).
        ix = {"v": usage.INDEX_VERSION, "files": {}, "seen": {},
              "days": {"claude": {recent: {"claude-opus-5-5": c1.counts(7)}}}, "accountByDay": abd}
        text = json.dumps(ix)
        self.assertTrue(text.isascii() and "\\ud800" in text)
        os.makedirs(os.path.dirname(common.USAGE_INDEX_PATH), exist_ok=True)
        with open(common.USAGE_INDEX_PATH, "w", encoding="ascii") as f:
            f.write(text)

    def test_refresh_drops_surrogate_records_and_saves_utf8(self):
        """Red now: `_normalize_account_days` checks only `isinstance(str)`; dropping `bad` sets changed=True and
        save_index raises UnicodeEncodeError on every refresh."""
        recent = common.day_key(time.time() - 86400)
        s = "\ud800"
        variants = {
            "owner": {"claude": {"2099-01-01": s, recent: c1.U_A, "bad": None}},
            "day": {"claude": {"2099-01-0" + s: c1.U_A, recent: c1.U_A, "bad": None}},
            "product": {"cl" + s: {recent: c1.U_A}, "claude": {recent: c1.U_A, "bad": None}},
        }
        for what, abd in variants.items():
            with self.subTest(what):
                self.write_raw_index(abd, recent)
                for attempt in (1, 2):
                    try:
                        ix, _changed, _fresh = usage.refresh()
                    except Exception as e:
                        self.fail("%s: refresh #%d raised %r" % (what, attempt, e))
                    self.assertEqual(lone_surrogates(ix.get("accountByDay")), [], (what, attempt))
                with open(common.USAGE_INDEX_PATH, "rb") as f:
                    saved = json.loads(f.read().decode("utf-8"))  # strict UTF-8
                abd_saved = saved.get("accountByDay")
                self.assertEqual(lone_surrogates(abd_saved), [], what)
                self.assertEqual(abd_saved.get("claude", {}).get(recent), c1.U_A,
                                 "a valid record survives (the fix must not drop everything)")
                self.assertEqual(saved["days"]["claude"][recent]["claude-opus-5-5"]["input"], 7, "usage is intact")


# ---- A1-28 (r2-m4 / N5) writer: NFKC look-alikes and backslash paths are refused before truncation --------------
class TestA128WriterNfkc(Base):
    L = ["%016x" % (0xa0 + i) for i in range(6)]

    def test_model_names_with_fullwidth_at_slash_and_backslash_are_dropped(self):
        """Red now: the writer checks only ASCII `@`/`/`; `＠`, `﹫`, `／`, `＼` and `\\` pass, and a look-alike past
        position 48 survives as a truncated clean-looking name."""
        self.need("build")
        bad = ["alice\uff20example.org", "alice\ufe6bexample.org", "\uff0fhome\uff0falice\uff0fx", "C:\\Users\\alice",
               "C:\uff3cUsers\uff3calice", "a" * 50 + "\uff20x.org", "b" * 45 + "\\x"]
        models = [{"name": n, "pct": 10, "resetAt": "2026-10-15T07:00:00Z"} for n in bad + ["ok-model"]]
        block = accounts.build(gist_id=c1.G1, entries=[c1.entry(models=models)], unattributed_days={}, captions={})
        names = [m.get("name") for a in block["accounts"] for m in a.get("models", [])]
        self.assertIn("ok-model", names, "a clean name survives (the test must not pass by dropping everything)")
        for n in names:
            folded = unicodedata.normalize("NFKC", n)
            for ch in ("@", "/", "\\"):
                self.assertNotIn(ch, folded, "model name %r folds to a %r" % (n, ch))
            self.assertFalse(n.startswith("a" * 40) or n.startswith("b" * 40),
                             "decision by NFKC must come before truncation: %r" % n)
        text = unicodedata.normalize("NFKC", json.dumps(block, ensure_ascii=False))
        self.assertIsNone(c1.EMAIL.search(text))
        self.assertNotIn("/home/", text)
        self.assertNotIn("Users", text)

    def test_captions_with_fullwidth_at_slash_and_backslash_are_dropped(self):
        """Red now: `_writer_captions` checks only ASCII `@`/`/`; NFKC look-alikes and `\\` pass."""
        self.need("build")
        captions = {self.L[0]: {"text": "bob\uff20example.org"}, self.L[1]: {"text": "C:\\Users\\bob"},
                    self.L[2]: {"text": "\uff0fhome\uff0fbob"}, self.L[3]: {"text": "c" * 35 + "\uff20"},
                    self.L[4]: {"text": "bob\ufe6bexample.org"}, self.L[5]: {"text": "Рабочий аккаунт"}}
        block = accounts.build(gist_id=c1.G1, entries=[c1.entry()], unattributed_days={}, captions=captions)
        out = block["captions"]
        self.assertEqual(out.get(self.L[5]), {"text": "Рабочий аккаунт"}, "a clean caption survives")
        for key in self.L[:5]:
            self.assertNotIn(key, out, "caption %r must be refused whole, not truncated" % captions[key]["text"])


# ---- A1-29 (R4) foreign tz is bounded ------------------------------------------------------------------------------
class TestA129TzBound(Base):
    def merged_tz(self, tz):
        obj = machine_obj("t")
        obj["tz"] = tz
        merged = sync.merge({"machine-t.json": dumps(obj)}, "me")
        self.assertEqual([m["id"] for m in merged["machines"]], ["t"], "the machine itself is kept")
        return merged["machines"][0].get("tz")

    def test_tz_longer_than_64_is_dropped(self):
        """Red now: `tz` goes through `accounts._text` without a limit (up to 8 MiB lands in sync-remote.json)."""
        for long_tz in ("Z" * 65, "Europe/" + "x" * 200, "y" * (1024 * 1024)):
            with self.subTest(length=len(long_tz)):
                got = self.merged_tz(long_tz) or ""
                self.assertTrue(got == "", "tz over 64 characters is dropped (got %d characters)" % len(got))

    def test_normal_tz_and_the_64_boundary_are_kept(self):
        """Green guard: ordinary zones and exactly 64 characters still pass."""
        self.assertEqual(self.merged_tz("Europe/Moscow"), "Europe/Moscow")
        self.assertEqual(self.merged_tz("Z" * 64), "Z" * 64)


# ---- A1-30 (R2 / n3) the raw redirect handler forwards no credentials and only the request's own headers ----------
class TestA130RedirectHeaders(Base):
    def follow(self):
        probe = f1.load_common_probe()
        server = RecordingServer()
        src = RAW_S % "a"
        dst = "https://gist.githubusercontent.com/u/" + SECRET_GIST + "/raw/hop/machine-a.json"
        server.redirect(src, dst)
        server.ok(dst, dumps(machine_obj("a")).encode())
        headers = {"Authorization": "Bearer fixture-token", "Cookie": "session=fixture",
                   "Proxy-Authorization": "Basic fixture", "User-Agent": sync.UA}
        with server.installed():
            r = probe.http(src, "GET", headers, None, 30, follow_redirects=True, max_body=MiB)
        self.assertEqual([u for u, _all, _normal in server.requests], [src, dst], "the same-host redirect is followed")
        self.assertEqual(r.status, 200)
        self.assertIn("authorization", lower_keys(server.requests[0][1]), "precondition: the first request had it")
        return server

    def test_redirect_drops_authorization_and_cookie_keeps_user_agent(self):
        """Red now: `_GistRawRedirect` copies `dict(req.header_items())` — Authorization/Cookie go to the next hop."""
        server = self.follow()
        hop = lower_keys(server.requests[1][1])
        for name in ("authorization", "cookie", "proxy-authorization"):
            self.assertNotIn(name, hop, "%s forwarded on a redirect" % name)
        self.assertEqual(hop.get("user-agent"), sync.UA, "User-Agent is kept")

    def test_redirect_copies_only_request_headers_not_unredirected(self):
        """Red now (n3): unredirected headers of the first hop (Host added by urllib) are copied as normal headers."""
        server = self.follow()
        self.assertNotIn("host", lower_keys(server.requests[1][2]),
                         "only req.headers are copied, like the stock redirect_request")


# ---- A1-31 (n4) one shared «body too large» marker; both read paths keep the skip-not-fail branch -----------------
class TestA131BodyTooLargeMarker(Base):
    def source(self, name):
        with open(os.path.join(rl.ROOT, "linux", "ccl", name), encoding="utf-8") as f:
            return f.read()

    def test_marker_is_one_constant_in_common(self):
        """Red now: there is no `common.BODY_TOO_LARGE`; the string is duplicated (sync._BODY_TOO_LARGE + literals in
        common.http), so renaming one silently turns «file too large» into «GET raw_url failed» and fails the cycle."""
        self.assertTrue(hasattr(common, "BODY_TOO_LARGE"), "common.BODY_TOO_LARGE is the single marker")
        self.assertEqual(common.BODY_TOO_LARGE, LITERAL_TOO_LARGE)
        self.assertEqual(self.source("common.py").count('"%s"' % LITERAL_TOO_LARGE), 1, "defined once in common.py")
        # sync.py may keep the same words as human text (status_text), but no own copy of the marker.
        self.assertIsNone(re.search(r'(=|==|!=)\s*"%s"' % LITERAL_TOO_LARGE, self.source("sync.py")),
                          "sync.py assigns/compares its own literal instead of common.BODY_TOO_LARGE")
        if hasattr(sync, "_BODY_TOO_LARGE"):
            self.assertIs(sync._BODY_TOO_LARGE, common.BODY_TOO_LARGE, "an alias, not a second literal")

    def test_oversize_error_body_on_raw_skips_the_file_not_the_cycle(self):
        """Green guard (HTTPError path; the plain 200 path is A1-19): raw_url answers 404 with an endless body →
        bounded read, «too large» branch — the file is skipped with a size error, the cycle is not a failure."""
        server = self.wire_recording()
        server.status(RAW_S % "bad", 404, size=None)
        server.ok(RAW_S % "good", dumps(machine_obj("good", model="good-model", n=5)).encode())
        others = {"machine-%s.json" % m: {"truncated": True, "raw_url": RAW_S % m, "content": ""} for m in ("bad", "good")}
        self.sign_in()
        self.mark_pushed()
        self.gh.on("GET", "/gists/g1", self.ok_gist(others))
        started = time.time()
        with server.installed():
            res = self.run_cycle("endless 404 body on raw_url")
        self.assertEqual(server.unbounded, [])
        self.assertLessEqual(server.bytes_by_url.get(RAW_S % "bad", 0), sync.MAX_MACHINE_BODY + 1)
        self.assertIn("good", self.machine_ids(res))
        err = str(self.st().get("lastError") or "")
        self.assertRegex(err, SIZE_ERROR)
        self.assertNotIn("GET raw_url", err, "not a transport failure of the whole cycle")
        self.assertGreaterEqual(self.st().get("lastOkAt") or 0, started - 1)


# ---- A1-32 (T2-r2 §4 regressions) cached status / dump --json, nested 3xx/4xx, ContextVar reset ------------------
class TestA132Regressions(Base):
    def write_hostile_cache(self):
        day = common.today_key()
        cache = {"machines": [{"id": "h", "name": "\x1b[2Jevil\ud800" + "n" * 40, "os": "OS\u202e" + "x" * 100,
                               "app": "linux\u009b\u200b", "updated": time.time()}],
                 "days": {"claude": {day: {"\x1b[31mevil": c1.counts(2), "bi\u202edi\ud800": c1.counts(3),
                                           "ok-model": c1.counts(4)}}}}
        text = json.dumps(cache)  # an old (pre-A1) cache: ASCII file with escapes, never cleaned by load_remote
        self.assertTrue(text.isascii())
        os.makedirs(os.path.dirname(common.SYNC_REMOTE_PATH), exist_ok=True)
        with open(common.SYNC_REMOTE_PATH, "w", encoding="ascii") as f:
            f.write(text)

    def test_cached_status_on_a_hostile_cache(self):
        """Green guard: `ccl-sync status` without a live gist prints the cached machines cleaned (strict UTF-8 stdout)."""
        self.write_hostile_cache()
        code, out = self.strict_stdout(cli.cmd_status, None)
        self.assertEqual(code, 0)
        self.assertRegex(out, r"по последней синхронизации|as of the last sync", "the cached path must be exercised")
        self.assertEqual(terminal_unsafe(out), [])
        self.assertNotIn("n" * 17, out)
        self.assertNotIn("x" * 65, out)

    def test_dump_on_a_hostile_cache_plain_and_json(self):
        """Green guard: `dump --merged` and `dump --merged --json` on a hostile cache — no ESC/bidi, no exception."""
        self.write_hostile_cache()
        for as_json in (True, False):
            with self.subTest(json=as_json):
                args = SimpleNamespace(no_scan=True, merged=True, product=None, days=7, json=as_json)
                code, out = self.strict_stdout(cli.cmd_dump, args)
                self.assertEqual(code, 0)
                self.assertIn("ok-model", out)
                self.assertEqual(terminal_unsafe(out), [])
                for bad in ("\x1b", "\u202e", "\u009b"):
                    self.assertNotIn(bad, out)
                if as_json:
                    json.loads(out)

    def test_nested_3xx_and_4xx_after_a_redirect_are_bounded(self):
        """Green guard: 302 → 300/304/305 (endless body) → 0 body bytes; 302 → 404/410 (endless) → ≤ cap+1; never 200."""
        cap = sync.MAX_MACHINE_BODY
        for code in (300, 304, 305, 404, 410):
            with self.subTest(code=code):
                server = self.wire_recording()
                src = RAW_S % ("n%d" % code)
                dst = "https://gist.githubusercontent.com/u/" + SECRET_GIST + "/raw/hop/machine-n%d.json" % code
                server.redirect(src, dst)
                server.status(dst, code, size=None)
                with server.installed():
                    try:
                        r = sync._raw(src)
                    except Exception as e:
                        self.fail("sync._raw raised %r" % e)
                self.assertEqual(server.unbounded, [])
                self.assertEqual(server.bytes_by_url.get(src, 0), 0, "the 302 body is never read")
                limit = 0 if code < 400 else cap + 1
                self.assertLessEqual(server.bytes_by_url.get(dst, 0), limit)
                self.assertFalse(r.status == 200 and r.data)

    def test_raw_cap_contextvar_is_reset_after_success_and_after_an_exception(self):
        """Green guard: `_raw` resets `_raw_cap` in finally — after success, after a transport exception, and restores
        an outer value."""
        seen = []

        def ok(url, method, headers, body, timeout):
            seen.append(sync._raw_cap.get())
            return rl._sync_env.resp(200, raw=b"{}")

        def boom(url, method, headers, body, timeout):
            seen.append(sync._raw_cap.get())
            raise RuntimeError("transport exploded")

        sync.transport = ok  # restored by SyncEnv.tearDown
        sync._raw(RAW_S % "a", cap=1234)
        self.assertEqual(seen[-1], 1234)
        self.assertIsNone(sync._raw_cap.get(), "reset after success")
        sync.transport = boom
        with contextlib.suppress(RuntimeError):
            sync._raw(RAW_S % "a", cap=99)
        self.assertEqual(seen[-1], 99)
        self.assertIsNone(sync._raw_cap.get(), "reset after an exception of the transport")
        outer = sync._raw_cap.set(4321)
        try:
            with contextlib.suppress(RuntimeError):
                sync._raw(RAW_S % "a", cap=7)
            self.assertEqual(sync._raw_cap.get(), 4321, "the outer value is restored")
        finally:
            sync._raw_cap.reset(outer)


if __name__ == "__main__":
    unittest.main()
