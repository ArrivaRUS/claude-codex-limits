"""REMOTE-LIMITS A1 — fix cycle after code review + security review T2 (docs/test-plan-remote-limits.md A1-16…A1-24).

Sources: docs/review-remote-limits-a1.md (M1, M2, m1, m2) and docs/security-remote-limits-a1-t2.md (N1–N6, N12).
Written BEFORE the fixes ("red first"): every test here fails on the A1 code as reviewed, for the reason named in
its docstring; the regression guard `test_authorized_api_never_follows_redirects` is green and must stay green.
A1-22 (N7, machine tag from hostname) belongs to A4 and is not here.

Offline, same sandbox as test_rl_contract.py (`_rl_env`: temp HOME/XDG before imports, audit hook on the real
~/.claude*/~/.codex, `common.http`/`sync.transport` forbidden, sockets refused). HTTP-level tests run the real
`common.http` from a fresh copy of ccl/common.py with urllib's HTTP(S) handlers replaced by an in-memory server
that counts every body byte it hands out — no socket is ever opened.

Run: python3 -m unittest linux/tests/test_rl_contract_fixes.py -v   (from PROJECT_ROOT)
"""

if __package__:
    from . import _rl_env as rl
    from . import test_rl_contract as c1
else:
    import _rl_env as rl
    import test_rl_contract as c1

import contextlib
import http.client
import importlib.util
import io
import json
import os
import re
import time
import unicodedata
import unittest
import urllib.request
from types import SimpleNamespace
from unittest import mock

from ccl import cli, common, sync, usage

accounts = c1.accounts
MiB = c1.MiB
RAW = "https://gist.githubusercontent.com/u/g1/raw/abc/machine-%s.json"
RAW_HOST = "https://gist.githubusercontent.com/"
SIZE_ERROR = re.compile(r"(?i)слишком больш|too large")


def tearDownModule():
    rl.assert_real_files_untouched()


def lone_surrogates(value):
    return [s for s in c1.all_strings(value) if any(0xD800 <= ord(ch) <= 0xDFFF for ch in s)]


def terminal_unsafe(text):
    """Characters a terminal may interpret: Cc (ESC, C1 CSI, BEL…) except newline, and Cf (bidi, zero-width)."""
    return sorted({repr(ch) for ch in text if ch != "\n" and unicodedata.category(ch) in ("Cc", "Cf")})


def machine_obj(mid, model="claude-opus-5-5", n=1, day=None, **machine):
    m = {"id": mid, "name": "pc-" + mid, "os": "Test OS", "app": "linux 0"}
    m.update(machine)
    return {"schema": 1, "machine": m, "updated": common.iso_utc(), "tz": "UTC",
            "days": {"claude": {day or common.today_key(): {model: c1.counts(n)}}}}


def dumps(obj):
    # ensure_ascii=True keeps a lone surrogate as the six ASCII characters \ud800 — exactly what a hostile writer sends.
    return json.dumps(obj)


def load_common_probe():
    """A fresh copy of ccl/common.py: `_isolate` replaced the imported module's `http` with a network guard."""
    spec = importlib.util.spec_from_file_location("ccl_common_probe_fixes", os.path.join(rl.ROOT, "linux", "ccl", "common.py"))
    probe = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(probe)
    return probe


class FakeBody(object):
    """One HTTP response of the in-memory server. `size=None` is an endless body."""
    ENDLESS_CHUNK = 24 * MiB  # what an unbounded read() of an endless body gets before we stop feeding it

    def __init__(self, server, url, code, headers, data=b"", size=None):
        self.server, self.url, self.code, self.status = server, url, code, code
        self.msg = self.reason = http.client.responses.get(code, "X")
        self.headers = http.client.HTTPMessage()
        for k, v in (headers or {}).items():
            self.headers[k] = v
        self.data, self.size, self.pos, self.closed = data, size, 0, False

    def info(self):
        return self.headers

    def geturl(self):
        return self.url

    def getcode(self):
        return self.code

    def read(self, n=-1):
        if n is None or n < 0:
            self.server.unbounded.append(self.url)
            n = self.ENDLESS_CHUNK if self.size is None else max(0, self.size - self.pos)
        if self.size is not None:
            n = min(n, self.size - self.pos)
        chunk = self.data[self.pos:self.pos + n] if self.data else b""
        chunk = chunk + b"x" * (n - len(chunk))
        self.pos += n
        self.server.bytes_read += n
        self.server.bytes_by_url[self.url] = self.server.bytes_by_url.get(self.url, 0) + n
        return chunk

    def close(self):
        self.closed = True

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()


class FakeServer(object):
    """Replaces urllib's HTTP and HTTPS handlers: url → scripted response; logs every opened URL and body byte."""

    def __init__(self):
        self.routes, self.opened, self.unbounded, self.bytes_by_url = {}, [], [], {}
        self.bytes_read = 0

    def ok(self, url, data):
        self.routes[url] = (200, {"Content-Length": str(len(data))}, data, len(data))

    def redirect(self, url, location, size=0):
        self.routes[url] = (302, {"Location": location}, b"", size)

    def _open(self, handler, req):
        url = req.full_url
        self.opened.append(url)
        if url not in self.routes:
            return FakeBody(self, url, 404, {}, b"not found", 9)
        code, headers, data, size = self.routes[url]
        return FakeBody(self, url, code, headers, data, size)

    @contextlib.contextmanager
    def installed(self):
        server = self

        def http_open(handler, req):
            return server._open(handler, req)

        with mock.patch.object(urllib.request.HTTPHandler, "http_open", http_open), \
                mock.patch.object(urllib.request.HTTPSHandler, "https_open", http_open):
            yield self


class Base(c1.Base):
    def cycle_with(self, others, raws=()):
        """One sync cycle; raw_url bodies come from the scripted FakeGitHub (A1-14 style)."""
        self.sign_in()
        self.mark_pushed()
        self.gh.on("GET", "/gists/g1", self.ok_gist(others))
        for url, body in raws:
            self.gh.on("GET", url, rl._sync_env.resp(200, raw=body))
        return self.cycle()

    def machine_ids(self, res):
        return [m["id"] for m in ((res.remote or {}).get("machines") or [])]

    def wire_http(self):
        """Real transport + real http() for gist raw URLs (through FakeServer); API calls stay on FakeGitHub."""
        probe = load_common_probe()
        common.http = probe.http  # restored by RLEnv.tearDown
        scripted = self.gh

        def transport(url, method, headers, body, timeout, **kw):
            if url.startswith(RAW_HOST):
                return sync._transport(url, method, headers, body, timeout, **kw)
            return scripted(url, method, headers, body, timeout)

        sync.transport = transport  # restored by SyncEnv.tearDown
        return FakeServer()

    def run_cycle(self, what):
        try:
            return self.cycle()
        except Exception as e:  # the defect itself: one hostile file must never stop the cycle
            self.fail("%s: sync_cycle raised %r — one hostile file stopped the whole cycle (C7)" % (what, e))

    def strict_stdout(self, fn, *args):
        """Run a CLI command with a strict UTF-8 stdout, like a real terminal (StringIO would accept lone surrogates)."""
        buf = io.BytesIO()
        w = io.TextIOWrapper(buf, encoding="utf-8", errors="strict", newline="\n", write_through=True)
        try:
            with contextlib.redirect_stdout(w), mock.patch.object(cli, "_timer_status", return_value="test timer"):
                code = fn(*args)
            w.flush()
        except Exception as e:
            self.fail("%s raised %r" % (getattr(fn, "__name__", fn), e))
        return code, buf.getvalue().decode("utf-8")


# ---- A1-16 (N1 / M2) lone surrogate in an old-reader field of another machine's file -------------------------
class TestA116LoneSurrogate(Base):
    def hostile_files(self):
        """The golden fixture (all fields at once) + one file per field, so a fix of only some fields stays red."""
        fx = rl.fixture("machine-v11-surrogate.json")
        fx["updated"] = common.iso_utc()  # the fixture's date would age out of the 45-day window in a real-clock cycle
        files = {"machine-fixturesurrogate.json": dumps(fx)}
        s = "\ud800"
        per_field = {"sn": dict(name=s + "ab"), "so": dict(os="OS" + s), "sa": dict(app="linux" + s)}
        for mid, fields in per_field.items():
            files["machine-%s.json" % mid] = dumps(machine_obj(mid, **fields))
        tz = machine_obj("st")
        tz["tz"] = s
        files["machine-st.json"] = dumps(tz)
        files["machine-sd.json"] = dumps(machine_obj("sd", day="2026-10-" + s))
        files["machine-sm.json"] = dumps(machine_obj("sm", model="model" + s))
        files["machine-sp.json"] = dumps(dict(machine_obj("sp"), days={"codex" + s: {common.today_key(): {"m": c1.counts(1)}}}))
        for name, text in files.items():
            self.assertTrue(text.isascii() and "\\ud800" in text, name + ": hostile file must carry the JSON escape")
        return files

    def test_fixture_is_valid_utf8_with_escaped_surrogates(self):
        # Self-check of the golden: ASCII on disk, lone surrogates only after json.loads (green; guards the fixture).
        with open(os.path.join(rl.FIXTURES, "machine-v11-surrogate.json"), "rb") as f:
            raw = f.read()
        self.assertTrue(raw.decode("utf-8").isascii())
        self.assertTrue(lone_surrogates(json.loads(raw)))

    def test_merge_output_is_encodable(self):
        """Red now: `_machine_text`, `tz` and the root `days` keys let the lone surrogate through → write_json would raise."""
        merged = sync.merge(self.hostile_files(), "me")
        self.assertEqual(lone_surrogates(merged), [], "lone surrogates must be dropped by the reader")
        json.dumps(merged, ensure_ascii=False).encode("utf-8")

    def test_cycle_survives_and_merges_the_good_machine(self):
        """Red now: sync_cycle raises UnicodeEncodeError in common.write_json(SYNC_REMOTE_PATH)."""
        others = self.hostile_files()
        others["machine-good.json"] = dumps(machine_obj("good", model="good-model", n=1000))
        self.sign_in()
        self.mark_pushed()
        self.gh.on("GET", "/gists/g1", self.ok_gist(others))
        started = time.time()
        res = self.run_cycle("lone surrogate in another machine's file")
        st = self.st()
        self.assertIsNotNone(st.get("lastOkAt"), "lastOkAt must move: the gist was read")
        self.assertGreaterEqual(st.get("lastOkAt"), started - 1)
        self.assertIn("good", self.machine_ids(res))
        self.assertEqual(res.remote["days"]["claude"][common.today_key()]["good-model"]["input"], 1000)
        self.assertEqual(lone_surrogates(res.remote), [])
        with open(common.SYNC_REMOTE_PATH, "rb") as f:
            cached = json.loads(f.read().decode("utf-8"))  # strict UTF-8: the cache is a valid file
        self.assertIn("good", [m["id"] for m in cached["machines"]])
        self.assertEqual(lone_surrogates(cached), [])


# ---- A1-17 (N2 / M1) terminal output of `ccl-sync status` (live gist path) and `dump --merged` ----------------
class TestA117TerminalOutput(Base):
    def status_with(self, others):
        self.sign_in()
        self.gh.on("GET", "/gists/g1", self.ok_gist(others))
        return self.strict_stdout(cli.cmd_status, None)

    def test_status_live_gist_strips_control_and_overlong_fields(self):
        """Red now: cmd_status parses gist files itself and prints raw machine.name/os/app (ESC, bidi, ZWSP, os×100)."""
        others = {
            "machine-fixturehostile.json": rl.fixture_text("machine-v11-hostile.json"),
            "machine-r.json": dumps(machine_obj("r", name="\x1b[2Jattack", os="x" * 100, app="linux\u200b9")),
            "machine-b.json": dumps(machine_obj("b", name="ab\u202ecd", os="OS\u009b31m", app="linux 1")),
            "machine-n.json": dumps(machine_obj("n", name="n" * 40, os="Test OS", app="a" * 100)),
        }
        code, out = self.status_with(others)
        self.assertEqual(code, 0)
        self.assertIn("Машины в gist", out, "the live gist path must be exercised")
        self.assertEqual(terminal_unsafe(out), [], "no ESC/C1/bidi/zero-width may reach the terminal")
        for bad in ("\x1b", "\u202e", "\u200b", "\u009b"):
            self.assertNotIn(bad, out)
        self.assertNotIn("x" * 65, out, "os/app over 64 are dropped (protocol: reader limits)")
        self.assertNotIn("a" * 65, out)
        self.assertNotIn("n" * 17, out, "machine.name is cut to 16 by the reader")

    def test_status_lone_surrogate_does_not_crash(self):
        """Red now: print() of a lone surrogate on a UTF-8 terminal raises UnicodeEncodeError."""
        code, out = self.status_with({"machine-s.json": dumps(machine_obj("s", name="\ud800ab", os="OS\ud800"))})
        self.assertEqual(code, 0)
        self.assertIn("Машины в gist", out)

    def test_status_enumerates_at_most_64_machine_files(self):
        """Red now: the live path iterates every machine-* file of the gist (no 64 cap)."""
        others = {"machine-f%02d.json" % i: dumps(machine_obj("f%02d" % i)) for i in range(70)}
        code, out = self.status_with(others)
        self.assertEqual(code, 0)
        listed = [line for line in out.splitlines() if line.startswith("  • ")]
        self.assertGreater(len(listed), 0)
        self.assertLessEqual(len(listed), 64)

    def test_dump_merged_strips_hostile_model_keys(self):
        """Red now: model keys of other machines' root `days` pass merge unchecked and `dump --merged` prints them."""
        day = common.today_key()
        hostile = machine_obj("h", model="\x1b[2Jevil")
        hostile["days"]["claude"][day].update({"bi\u202edi": c1.counts(2), "zw\u200bsp": c1.counts(3),
                                               "c1\u009bm": c1.counts(4)})
        merged = sync.merge({"machine-h.json": dumps(hostile)}, "me")
        common.write_json(common.SYNC_REMOTE_PATH, merged)
        args = SimpleNamespace(no_scan=True, merged=True, product=None, days=7, json=False)
        code, out = self.strict_stdout(cli.cmd_dump, args)
        self.assertEqual(code, 0)
        self.assertIn("== claude ==", out)
        self.assertEqual(terminal_unsafe(out), [])
        for bad in ("\x1b", "\u202e", "\u200b", "\u009b"):
            self.assertNotIn(bad, out)


# ---- A1-18 (N3) redirects on the unauthenticated raw path ------------------------------------------------------
class TestA118RawRedirects(Base):
    def raw(self, server, url):
        with server.installed():
            try:
                return sync._raw(url)
            except Exception as e:
                self.fail("sync._raw raised %r" % e)

    def test_redirect_body_is_never_drained(self):
        """Red now: urllib's HTTPRedirectHandler does fp.read() of the 302 body with no limit."""
        server = self.wire_http()
        src, dst = RAW % "a", "https://gist.githubusercontent.com/u/g1/raw/def/machine-a.json"
        server.redirect(src, dst, size=None)  # endless 302 body
        server.ok(dst, dumps(machine_obj("a")).encode())
        self.raw(server, src)
        self.assertEqual(server.unbounded, [], "a response body was read without a limit")
        self.assertLessEqual(server.bytes_read, sync.MAX_MACHINE_BODY + 1, "total body bytes for one raw file")

    def test_redirect_to_plain_http_is_not_followed(self):
        """Red now: urllib follows 302 → http:// (allowed schemes: http/https/ftp)."""
        server = self.wire_http()
        server.redirect(RAW % "a", "http://gist.githubusercontent.com/u/g1/raw/abc/machine-a.json")
        server.ok("http://gist.githubusercontent.com/u/g1/raw/abc/machine-a.json", dumps(machine_obj("a")).encode())
        r = self.raw(server, RAW % "a")
        self.assertFalse(any(u.startswith("http://") for u in server.opened), server.opened)
        self.assertFalse(r.status == 200 and r.data, "a refused redirect is not a successful read")

    def test_redirect_to_foreign_host_is_not_followed(self):
        """Red now: any https host is followed."""
        server = self.wire_http()
        server.redirect(RAW % "a", "https://evil.example/machine-a.json")
        server.ok("https://evil.example/machine-a.json", dumps(machine_obj("a")).encode())
        r = self.raw(server, RAW % "a")
        self.assertNotIn("https://evil.example/machine-a.json", server.opened)
        self.assertFalse(r.status == 200 and r.data)

    def test_more_than_three_redirects_is_refused(self):
        """Red now: urllib follows up to 10 redirects."""
        server = self.wire_http()
        hops = [RAW % "a"] + ["https://gist.githubusercontent.com/u/g1/raw/hop%d/machine-a.json" % i for i in range(5)]
        for a, b in zip(hops, hops[1:]):
            server.redirect(a, b)
        server.ok(hops[-1], dumps(machine_obj("a")).encode())
        r = self.raw(server, hops[0])
        self.assertLessEqual(len(server.opened), 4, "the original request + at most 3 redirects: %s" % server.opened)
        self.assertFalse(r.status == 200 and r.data)

    def test_refused_redirect_skips_the_file_not_the_cycle(self):
        """Red now: the redirect to http:// is followed and its content is merged as a machine."""
        server = self.wire_http()
        bad_dst = "http://gist.githubusercontent.com/u/g1/raw/abc/machine-bad.json"
        server.redirect(RAW % "bad", bad_dst)
        server.ok(bad_dst, dumps(machine_obj("bad")).encode())
        server.ok(RAW % "good", dumps(machine_obj("good", model="good-model", n=5)).encode())
        others = {"machine-%s.json" % m: {"truncated": True, "raw_url": RAW % m, "content": ""} for m in ("bad", "good")}
        self.sign_in()
        self.mark_pushed()
        self.gh.on("GET", "/gists/g1", self.ok_gist(others))
        started = time.time()
        with server.installed():
            res = self.run_cycle("redirect on raw_url")
        self.assertNotIn(bad_dst, server.opened)
        self.assertNotIn("bad", self.machine_ids(res))
        self.assertIn("good", self.machine_ids(res), "one refused file must not stop reading the others")
        self.assertGreaterEqual(self.st().get("lastOkAt") or 0, started - 1)
        self.assertTrue(os.path.exists(common.SYNC_REMOTE_PATH))

    def test_authorized_api_never_follows_redirects(self):
        """Regression guard (green now, must stay green): bearer requests to api.github.com never follow 3xx."""
        server = self.wire_http()
        sync.transport = sync._transport  # the API call goes through the real transport too
        server.redirect("https://api.github.com/gists/g1", "https://api.github.com/gists/other")
        server.ok("https://api.github.com/gists/other", b"{}")
        with server.installed():
            r = sync.gh("/gists/g1", "fixture-token")
        self.assertEqual(server.opened, ["https://api.github.com/gists/g1"])
        self.assertNotEqual(r.status, 200)
        self.assertEqual(server.unbounded, [])


# ---- A1-19 (N4 / m2) total read budget and the 64-file cap are errors, counted on the wire ----------------------
class TestA119TotalBudget(Base):
    def test_nine_raw_files_of_7_5_mib_read_at_most_64_mib_plus_one(self):
        """Red now: the 64 MiB budget is checked after the 9th file was downloaded (67.5 MiB read), and ok=True/no error."""
        server = self.wire_http()
        size = int(7.5 * MiB)
        others = {}
        for i in range(9):
            mid = "r%d" % i
            others["machine-%s.json" % mid] = {"truncated": True, "raw_url": RAW % mid, "content": ""}
            server.ok(RAW % mid, c1.padded_machine(mid, size).encode())
        self.sign_in()
        self.mark_pushed()
        self.gh.on("GET", "/gists/g1", self.ok_gist(others))
        started = time.time()
        with server.installed():
            res = self.run_cycle("total budget")
        self.assertEqual(server.unbounded, [])
        self.assertLessEqual(server.bytes_read, sync.MAX_TOTAL_BODY + 1, "bytes read from the wire, not bytes kept")
        merged = self.machine_ids(res)
        self.assertTrue(1 <= len(merged) <= 8, merged)
        st = self.st()
        self.assertFalse(res.ok, "over the total budget is an error (R1), not a silent cut")
        self.assertRegex(str(st.get("lastError") or ""), SIZE_ERROR)
        self.assertGreaterEqual(st.get("lastOkAt") or 0, started - 1, "R1: the file is skipped, lastOkAt still moves")

    def test_more_than_64_machine_files_is_an_error(self):
        """Red now: files beyond 64 are dropped silently (ok=True, no lastError)."""
        others = {"machine-m%02d.json" % i: rl._sync_env.machine_json("m%02d" % i) for i in range(65)}
        started = time.time()
        res = self.cycle_with(others)
        self.assertLessEqual(len(self.machine_ids(res)), 64)
        self.assertGreater(len(self.machine_ids(res)), 0)
        st = self.st()
        self.assertFalse(res.ok)
        self.assertRegex(str(st.get("lastError") or ""), SIZE_ERROR)
        self.assertGreaterEqual(st.get("lastOkAt") or 0, started - 1)


# ---- A1-20 (N5) writer: models[].name never carries an email or a path ------------------------------------------
class TestA120WriterModelNames(Base):
    def test_email_and_path_in_model_names_are_dropped(self):
        """Red now: the writer cleans Cc/Cf and truncates, but `@` and `/` pass into the published block."""
        self.need("build")
        models = [{"name": n, "pct": 10, "resetAt": "2026-10-15T07:00:00Z"}
                  for n in ("alice@example.org", "/home/alice/x", "C:/Users/alice", "ok-model")]
        block = accounts.build(gist_id=c1.G1, entries=[c1.entry(models=models)], unattributed_days={}, captions={})
        names = [m.get("name") for a in block["accounts"] for m in a.get("models", [])]
        self.assertIn("ok-model", names, "a clean name survives (the test must not pass by dropping everything)")
        for n in names:
            self.assertTrue(n is None or ("@" not in n and "/" not in n), n)
        text = json.dumps(block, ensure_ascii=False)
        self.assertIsNone(c1.EMAIL.search(text))
        self.assertNotIn("/home/", text)


# ---- A1-21 (N6) broken accountByDay in the local index -----------------------------------------------------------
class TestA121BrokenAccountByDay(Base):
    def transcript(self, ts):
        path = os.path.join(common.CLAUDE_PROJECTS, "proj", "a.jsonl")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(json.dumps({"type": "assistant", "timestamp": common.iso_utc(ts), "message": {
                "id": "m1", "model": "claude-fable-5-1",
                "usage": {"input_tokens": 5, "output_tokens": 1, "cache_read_input_tokens": 0}}}) + "\n")

    def test_refresh_and_prune_survive_garbage(self):
        """Red now: `prune`/`_attribute_day` call .items()/.setdefault on a list or a string → AttributeError."""
        now = time.time()
        ts = now - 120
        new_day, old_day = common.day_key(ts), common.day_key(now - 3 * 86400)
        self.write_claude_json(c1.U_A)
        self.transcript(ts)
        old = {"claude-opus-5-5": c1.counts(7)}
        variants = {
            "list": {"claude": []},
            "string": {"claude": "garbage"},
            "nested": {"claude": {old_day: ["x"], "2026-10-01": {"deep": {"er": 1}}}, "codex": 5},
            "top-level list": [],
        }
        for what, by_day in variants.items():
            with self.subTest(what):
                common.write_json(common.USAGE_INDEX_PATH, {"v": usage.INDEX_VERSION, "files": {}, "seen": {},
                                                             "days": {"claude": {old_day: old}}, "accountByDay": by_day})
                try:
                    ix, _changed, _fresh = usage.refresh()
                    usage.prune(ix)
                except Exception as e:
                    self.fail("%s: refresh/prune raised %r" % (what, e))
                self.assertEqual(ix["days"]["claude"][old_day], old, "existing usage is intact")
                self.assertEqual(ix["days"]["claude"][new_day]["claude-fable-5-1"]["input"], 5, "new usage is counted")
                saved = common.read_json(common.USAGE_INDEX_PATH)
                abd = saved.get("accountByDay")
                self.assertIsInstance(abd, dict)
                for p, days in abd.items():
                    self.assertIsInstance(days, dict, (what, p))
                    for d, owner in days.items():
                        self.assertIsInstance(owner, str, (what, p, d))


# ---- A1-23 (m1) bounded work on a huge raw `accounts` array ------------------------------------------------------
class TestA123RawAccountsBound(Base):
    def test_at_most_64_raw_entries_are_examined(self):
        """Red now: parse_block validates every raw element (120 000 calls of validate_entry)."""
        self.need("parse_block", "validate_entry")
        obj = machine_obj("big", model="claude-fable-5-1", n=9, day="2026-10-12")
        obj["accounts"] = [{"product": "claude", "status": "ok"}] * 120000
        text = json.dumps(obj, separators=(",", ":"))
        self.assertLess(len(text.encode()), sync.MAX_MACHINE_BODY, "must stay a readable file, under the 8 MiB cap")
        with mock.patch.object(accounts, "validate_entry", wraps=accounts.validate_entry) as validate:
            merged = sync.merge({"machine-big.json": text}, "me", now=rl.NOW)
        self.assertEqual([m["id"] for m in merged["machines"]], ["big"])
        self.assertLessEqual(validate.call_count, 64, "raw elements examined")
        m = merged["machines"][0]
        self.assertLessEqual(len(m["accounts"]), 8)
        parts = [(a["product"], a.get("days")) for a in m["accounts"]] + list((m.get("unattributedDays") or {}).items())
        self.assertEqual(c1.sum_by_product(*parts), {"claude": 9}, "dropped records' usage goes to 'не указан'")


# ---- A1-24 (N12) shape of the local account id -------------------------------------------------------------------
class TestA124LocalIdShape(Base):
    # Yurka's decision: after strip+lower the id must match ^[0-9a-z-]{8,64}$; any other shape → no_account_uuid.
    BAD = {
        "over 128": "a" * 129,
        "65 characters": "a" * 65,
        "7 characters": "abcdef1",
        "non-ASCII": "3b9d6c1e-8f42-4a7b-9c05-2e6f1d8a4bÄ0",
        "dotted I (lower() differs in Swift)": "İ3b9d6c1e-8f42-4a7b-9c05-2e6f1d8a4b70",
        "inner space": "3b9d6c1e 8f42-4a7b-9c05-2e6f1d8a4b70",
        "inner tab": "3b9d6c1e\t8f42-4a7b-9c05-2e6f1d8a4b70",
        "empty": "",
    }

    def test_bad_ids_are_refused(self):
        """Red now: any non-empty string up to ~8 MB is accepted as an id (strip/lower only); 7 and 65 characters too."""
        for what, bad in self.BAD.items():
            with self.subTest(product="claude", case=what):
                self.write_claude_json(bad)
                self.assertEqual(self.ident("claude"), (None, "no_account_uuid"), what)
            with self.subTest(product="codex", case=what):
                self.write_codex_auth(bad)
                self.assertEqual(self.ident("codex"), (None, "no_account_uuid"), what)

    def test_normal_ids_still_pass_with_strip_and_lower(self):
        """Green now (guard): the fix must not break normal UUIDs / Codex ids, nor the 8 and 64 boundaries."""
        self.write_claude_json("  %s\n" % c1.U_A.upper())
        self.assertEqual(self.ident("claude"), (c1.U_A, None))
        for edge in ("abcdef12", "a" * 64):
            self.write_claude_json(edge.upper())
            self.assertEqual(self.ident("claude"), (edge, None))
        self.write_codex_auth("acct-fixture-0001")
        self.assertEqual(self.ident("codex"), ("acct-fixture-0001", None))

    def test_bad_id_never_owns_a_day(self):
        """Red now: the 200-character id is stored in accountByDay (and would get a label)."""
        bad = "a" * 200
        self.write_claude_json(bad)
        path = os.path.join(common.CLAUDE_PROJECTS, "proj", "a.jsonl")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(json.dumps({"type": "assistant", "timestamp": "2026-10-12T09:00:00Z", "message": {
                "id": "m1", "model": "claude-fable-5-1",
                "usage": {"input_tokens": 1, "output_tokens": 1, "cache_read_input_tokens": 0}}}) + "\n")
        os.utime(path, (rl.NOW, rl.NOW))
        ix = usage.new_index()
        usage.scan(ix, now=rl.NOW, claude_root=common.CLAUDE_PROJECTS, codex_root=common.CODEX_SESSIONS)
        self.assertTrue(ix["days"].get("claude"), "usage is still counted")
        self.assertNotIn(bad, json.dumps(ix.get("accountByDay", {})), "a malformed id never enters the index")


if __name__ == "__main__":
    unittest.main()
