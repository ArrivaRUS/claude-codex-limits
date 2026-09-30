"""Unit tests for the log index and the sync protocol. Run: python3 -m unittest discover linux/tests"""

if __package__:
    from . import _isolate  # noqa: F401
else:
    import _isolate  # noqa: F401


import json
import os
import shutil
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from ccl import common, sync, usage  # noqa: E402

T0 = "2026-09-24T10:00:00.000Z"
T1 = "2026-09-24T11:00:00.123Z"


def claude_line(mid, model="claude-opus-5-5", ts=T0, inp=1, out=10, cr=100, c5=0, c1=0, legacy_cc=None, typ="assistant"):
    usage_ = {"input_tokens": inp, "output_tokens": out, "cache_read_input_tokens": cr}
    if legacy_cc is None:
        usage_["cache_creation"] = {"ephemeral_5m_input_tokens": c5, "ephemeral_1h_input_tokens": c1}
    else:
        usage_["cache_creation_input_tokens"] = legacy_cc
    return json.dumps({"type": typ, "timestamp": ts, "message": {"id": mid, "model": model, "usage": usage_}})


def codex_ctx(model):
    return json.dumps({"timestamp": T0, "type": "turn_context", "payload": {"model": model, "cwd": "/x"}})


def codex_tc(inp, cached, out, ts=T1, cw=None, info=True):
    lu = {"input_tokens": inp, "cached_input_tokens": cached, "output_tokens": out}
    if cw is not None:
        lu["cache_write_input_tokens"] = cw
    payload = {"type": "token_count", "info": {"last_token_usage": lu} if info else None}
    return json.dumps({"timestamp": ts, "type": "event_msg", "payload": payload})


class Tmp(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.claude = os.path.join(self.dir, "projects")
        self.codex = os.path.join(self.dir, "sessions")
        os.makedirs(os.path.join(self.claude, "proj", "sess", "subagents"))
        os.makedirs(os.path.join(self.codex, "2026", "09", "24"))
        self.now = common.parse_iso("2026-09-25T12:00:00Z")

    def tearDown(self):
        shutil.rmtree(self.dir)

    def write(self, rel, lines, mode="w", newline=True):
        p = os.path.join(self.dir, rel)
        with open(p, mode) as f:
            f.write("\n".join(lines) + ("\n" if newline else ""))
        os.utime(p, (self.now, self.now))
        return p

    def scan(self, ix):
        return usage.scan(ix, now=self.now, claude_root=self.claude, codex_root=self.codex)


class TestClaude(Tmp):
    def test_counts_dedupes_and_subagents(self):
        day = common.day_key(common.parse_iso(T0))
        self.write("projects/proj/a.jsonl", [
            claude_line("m1", out=10, c5=5, c1=7),
            claude_line("m1", out=10, c5=5, c1=7),                  # same message, second content block
            json.dumps({"type": "user", "timestamp": T0, "message": {"usage": {"x": 1}}}),
            claude_line("m2", out=20, legacy_cc=30),
            claude_line("m3", model="<synthetic>", out=99),
            "not json at all \"usage\"",
        ])
        self.write("projects/proj/b.jsonl", [claude_line("m2", out=20, legacy_cc=30)])  # resumed copy
        self.write("projects/proj/sess/subagents/agent-1.jsonl", [claude_line("s1", model="claude-fable-5-1", out=5)])
        ix = usage.new_index()
        self.assertTrue(self.scan(ix))
        opus = ix["days"]["claude"][day]["claude-opus-5-5"]
        self.assertEqual(opus["turns"], 2)
        self.assertEqual(opus["output"], 30)
        self.assertEqual(opus["cacheWrite5m"], 5 + 30)
        self.assertEqual(opus["cacheWrite1h"], 7)
        self.assertEqual(opus["cacheRead"], 200)
        self.assertEqual(ix["days"]["claude"][day]["claude-fable-5-1"]["turns"], 1)
        self.assertNotIn("<synthetic>", ix["days"]["claude"][day])

    def test_incremental_and_partial_line(self):
        day = common.day_key(common.parse_iso(T0))
        p = self.write("projects/proj/a.jsonl", [claude_line("m1")])
        ix = usage.new_index()
        self.scan(ix)
        self.assertFalse(self.scan(ix))                       # nothing new
        # a half-written line must not be consumed …
        with open(p, "a") as f:
            f.write(claude_line("m2", out=50)[:40])
        os.utime(p, (self.now, self.now))
        self.scan(ix)
        self.assertEqual(ix["days"]["claude"][day]["claude-opus-5-5"]["turns"], 1)
        # … and is counted once it is complete
        with open(p, "a") as f:
            f.write(claude_line("m2", out=50)[40:] + "\n")
        os.utime(p, (self.now, self.now))
        self.assertTrue(self.scan(ix))
        self.assertEqual(ix["days"]["claude"][day]["claude-opus-5-5"]["turns"], 2)
        self.assertEqual(ix["days"]["claude"][day]["claude-opus-5-5"]["output"], 60)

    def test_truncated_file_restarts(self):
        p = self.write("projects/proj/a.jsonl", [claude_line("m1"), claude_line("m2")])
        ix = usage.new_index()
        self.scan(ix)
        self.write("projects/proj/a.jsonl", [claude_line("m3")])
        self.scan(ix)
        self.assertEqual(ix["files"][p]["size"], os.path.getsize(p))

    def test_old_files_skipped(self):
        p = self.write("projects/proj/a.jsonl", [claude_line("m1")])
        old = self.now - 50 * 86400
        os.utime(p, (old, old))
        ix = usage.new_index()
        self.assertFalse(self.scan(ix))


class TestCodex(Tmp):
    def test_token_count(self):
        day = common.day_key(common.parse_iso(T1))
        self.write("sessions/2026/09/24/rollout-1.jsonl", [
            codex_tc(5, 0, 1, info=False),                        # before any usage: info null
            codex_ctx("gpt-6-sol"),
            codex_tc(1000, 800, 50),
            codex_tc(10, 20, 5, cw=7),                            # cached > input → input 0
            codex_ctx("gpt-6-astra"),
            codex_tc(300, 100, 30),
            json.dumps({"timestamp": T1, "type": "response_item", "payload": {"text": "\"turn_context\" \"token_count\""}}),
        ])
        self.write("sessions/2026/09/24/other.jsonl", [codex_tc(1, 1, 1)])   # not a rollout file
        ix = usage.new_index()
        self.scan(ix)
        sol = ix["days"]["codex"][day]["gpt-6-sol"]
        self.assertEqual((sol["input"], sol["cacheRead"], sol["output"], sol["cacheWrite5m"], sol["turns"]),
                         (200, 820, 55, 7, 2))
        astra = ix["days"]["codex"][day]["gpt-6-astra"]
        self.assertEqual((astra["input"], astra["cacheRead"], astra["turns"]), (200, 100, 1))

    def test_model_survives_between_scans(self):
        day = common.day_key(common.parse_iso(T1))
        p = self.write("sessions/2026/09/24/rollout-1.jsonl", [codex_ctx("gpt-6-astra"), codex_tc(10, 0, 1)])
        ix = usage.new_index()
        self.scan(ix)
        with open(p, "a") as f:
            f.write(codex_tc(20, 0, 2) + "\n")
        os.utime(p, (self.now, self.now))
        self.scan(ix)
        self.assertEqual(ix["days"]["codex"][day]["gpt-6-astra"]["turns"], 2)


class TestMoney(unittest.TestCase):
    def test_prices(self):
        u = dict(input=1_000_000, output=1_000_000, cacheRead=1_000_000, cacheWrite5m=1_000_000,
                 cacheWrite1h=1_000_000, turns=1)
        self.assertAlmostEqual(usage.api_cost("claude-opus-5-5", u), 5 + 25 + 0.5 + 6.25 + 10)
        self.assertAlmostEqual(usage.api_cost("claude-fable-5-1", u), 10 + 50 + 0.25 + 12.5 + 20)
        self.assertIsNone(usage.api_cost("mystery-model", u))

    def test_display_names(self):
        self.assertEqual(usage.model_display_name("claude-fable-5-1"), "Fable 5.1")
        self.assertEqual(usage.model_display_name("gpt-6-astra"), "Astra 6")
        self.assertEqual(usage.model_display_name("claude-opus-5-5"), "Opus 5.5")


class TestSync(unittest.TestCase):
    def test_machine_file_is_what_the_mac_reads(self):
        days = {"claude": {"2026-09-24": {"claude-opus-5-5": dict(input=1, output=2, cacheRead=3, cacheWrite5m=4,
                                                                   cacheWrite1h=5, turns=6)}}, "codex": {}}
        obj = json.loads(sync.machine_file(days))
        self.assertIs(type(obj["schema"]), int)
        self.assertEqual(obj["schema"], 1)
        # the Mac parses `updated` with ISO8601DateFormatter's defaults: no fractional seconds
        self.assertRegex(obj["updated"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
        self.assertEqual(set(obj["machine"]), {"id", "name", "os", "app"})
        self.assertTrue(obj["machine"]["app"].startswith("linux "))
        self.assertEqual(obj["days"], days)
        for v in obj["days"]["claude"]["2026-09-24"]["claude-opus-5-5"].values():
            self.assertIs(type(v), int)

    def test_merge(self):
        now = common.parse_iso("2026-09-27T12:00:00Z")
        u = lambda n: dict(input=n, output=n, cacheRead=n, cacheWrite5m=n, cacheWrite1h=n, turns=n)
        mac = {"schema": 1, "machine": {"id": "mac", "name": "MacBook", "os": "macOS 26.0", "app": "macos 3.1.1"},
               "updated": "2026-09-27T10:00:00Z", "tz": "Europe/Moscow",
               "days": {"claude": {"2026-09-24": {"claude-opus-5-5": u(1)}}}}
        mac2 = dict(mac, machine=dict(mac["machine"], id="mac2", name="Mini"),
                    days={"claude": {"2026-09-24": {"claude-opus-5-5": u(2), "claude-fable-5-1": u(3)}}})
        me = dict(mac, machine=dict(mac["machine"], id="me"))
        stale = dict(mac, machine=dict(mac["machine"], id="old"), updated="2026-07-01T00:00:00Z")
        other_schema = dict(mac, schema=2, machine=dict(mac["machine"], id="future"))
        contents = {"machine-mac.json": json.dumps(mac), "machine-mac2.json": json.dumps(mac2),
                    "machine-me.json": json.dumps(me), "machine-old.json": json.dumps(stale),
                    "machine-future.json": json.dumps(other_schema), "machine-bad.json": "{nope"}
        r = sync.merge(contents, "me", now=now)
        self.assertEqual(sorted(m["name"] for m in r["machines"]), ["MacBook", "Mini"])
        day = r["days"]["claude"]["2026-09-24"]
        self.assertEqual(day["claude-opus-5-5"]["turns"], 3)
        self.assertEqual(day["claude-fable-5-1"]["output"], 3)

    def test_snapshot_keeps_45_days(self):
        now = common.parse_iso("2026-09-27T12:00:00Z")
        ix = {"days": {"claude": {"2026-08-01": {"m": usage.empty_usage()}, "2026-09-20": {"m": usage.empty_usage()}}}}
        snap = usage.snapshot_days(ix, now=now)
        self.assertEqual(list(snap["claude"]), ["2026-09-20"])

    def test_parse_iso(self):
        self.assertEqual(common.parse_iso("2026-09-24T10:00:00Z"), common.parse_iso("2026-09-24T13:00:00+03:00"))
        self.assertAlmostEqual(common.parse_iso("2026-09-24T10:00:00.123456+00:00") % 1, 0.123456, places=5)
        self.assertIsNone(common.parse_iso("yesterday"))


if __name__ == "__main__":
    unittest.main()
