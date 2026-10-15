"""REMOTE-LIMITS A1 — contract v1.1 and account identity (docs/test-plan-remote-limits.md A1-01…A1-15).

Written BEFORE the code ("red first"). Until A1 lands, tests of the new API fail with AssertionError
("contract: …"); compatibility tests (A1-09) are green and must stay green. Offline (lessons 006/011):
temp HOME/XDG before imports (`_rl_env`), `common.http`/`sync.transport` forbidden, fixed clock.

API contract assumed by these tests (synth v2 §A/§B/§F.1, docs/plans.md A1; names not fixed by v2 were set
by the coordinator):
  ccl.accounts.label(product=, local_id=, gist_id=) -> 16 lowercase hex
  ccl.accounts.read_local_id(product) -> (local_id | None, labelReason | None)   (tuple, or .local_id/.reason)
  ccl.accounts.build(gist_id=, entries=, unattributed_days=, captions=) -> {"accounts", "unattributedDays", "captions", "days"}
      entries: contract records (§A) carrying "localId" instead of "label"; "days" = root projection (§A rule 1)
  ccl.accounts.parse_block(machine_obj) -> {"accounts": [...], "captions": {...}, "unattributedDays": {...}, "lastSeenAt": epoch | None}
  ccl.accounts.validate_entry(entry) -> cleaned entry | None
  ccl.common.machine_tag() -> [a-z0-9-]{1,16};  ccl.common.CLAUDE_JSON (~/.claude.json);  ccl.common.http(..., max_body=)
  usage.scan(...) fills ix["accountByDay"][product][day] = localId (first indexing wins)
Run: python3 -m unittest linux/tests/test_rl_contract.py -v   (from PROJECT_ROOT)
"""

if __package__:
    from . import _rl_env as rl
else:
    import _rl_env as rl

import copy
import hashlib
import hmac
import io
import json
import math
import os
import re
import time
import unicodedata
import unittest
from types import SimpleNamespace
from unittest import mock

from ccl import common, sync, usage

try:
    from ccl import accounts
    ACCOUNTS_IMPORT_ERROR = None
except ImportError as e:  # A1 not implemented yet — every dependent test fails as a contract assertion
    accounts = None
    ACCOUNTS_IMPORT_ERROR = e

MiB = 1024 * 1024
HEX16 = re.compile(r"^[0-9a-f]{16}$")
TAG = re.compile(r"^[a-z0-9-]{1,16}$")
U_A = "3b9d6c1e-8f42-4a7b-9c05-2e6f1d8a4b70"
U_B = "7e1f2a3b-4c5d-4e6f-8a9b-0c1d2e3f4a5b"
G1, G2 = "fixturegist0000000000000000000001", "fixturegist0000000000000000000002"
STATUSES = {"ok", "stale", "signed_out", "expired", "rate_limited", "error"}
REASONS = {"no_login", "no_account_uuid", "unreadable", "no_gist"}
ENTRY_KEYS = {"product", "label", "labelReason", "plan", "tier", "status", "expiredReason", "asOf", "attemptAt", "attemptKind",
              "windows", "models", "resetCredits", "schedule", "retryUntil", "days"}
INTERVALS = {900, 1800, 3600, 14400}
EMAIL = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")
UUID = re.compile(r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
FORBIDDEN = ("eyJ", "sk-", "Bearer", "/home/", "/Users/")


def tearDownModule():
    rl.assert_real_files_untouched()


def oracle_label(gist_id, product, local_id):
    """The spec formula (synth v2 §B), independent of the implementation."""
    key = hashlib.sha256(("ccl-label-key-v1|" + gist_id).encode("utf-8")).digest()
    msg = ("ccl-account-v1|" + product + "|" + local_id.strip().lower()).encode("utf-8")
    return hmac.new(key, msg, hashlib.sha256).hexdigest()[:16]


def control_free(s):
    return isinstance(s, str) and not any(unicodedata.category(ch) in ("Cc", "Cf") for ch in s)


def all_strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for k, v in value.items():
            yield from all_strings(k)
            yield from all_strings(v)
    elif isinstance(value, (list, tuple)):
        for v in value:
            yield from all_strings(v)


def counts(n):
    return {"input": n, "output": 2 * n, "cacheRead": 0, "cacheWrite5m": 0, "cacheWrite1h": 0, "turns": 1}


def sum_by_product(*day_maps_with_product):
    """[(product, {day: {model: counts}}), ...] → {product: total_input} (only `input` is enough to see double counting)."""
    out = {}
    for product, by_day in day_maps_with_product:
        for by_model in (by_day or {}).values():
            for c in by_model.values():
                out[product] = out.get(product, 0) + c.get("input", 0)
    return out


class Base(rl.RLEnv):
    def need(self, *names):
        if accounts is None:
            self.fail("contract: модуль ccl.accounts отсутствует (A1 не реализован): %s" % ACCOUNTS_IMPORT_ERROR)
        for n in names:
            if not callable(getattr(accounts, n, None)):
                self.fail("contract: ccl.accounts.%s отсутствует" % n)

    def ident(self, product):
        self.need("read_local_id")
        r = accounts.read_local_id(product)
        if isinstance(r, tuple):
            self.assertEqual(len(r), 2, "read_local_id → (local_id, reason)")
            return r
        return getattr(r, "local_id"), getattr(r, "reason")

    def label(self, product, local_id, gist_id=G1):
        self.need("label")
        return accounts.label(product=product, local_id=local_id, gist_id=gist_id)

    def need_common(self, name):
        if not hasattr(common, name):
            self.fail("contract: ccl.common.%s отсутствует" % name)


def entry(product="claude", local_id=U_A, **kw):
    e = {"product": product, "localId": local_id, "plan": "max", "tier": "default_claude_max_20x", "status": "ok",
         "asOf": "2026-10-12T10:15:02Z", "attemptAt": "2026-10-12T10:15:00Z", "attemptKind": "auto",
         "windows": {"session": {"pct": 42.5, "resetAt": "2026-10-12T13:00:00Z"}},
         "models": [{"name": "Fable 5.1", "pct": 70.2, "resetAt": "2026-10-15T07:00:00Z"}],
         "schedule": {"mode": "auto", "interval": 900, "nextAt": "2026-10-12T10:30:00Z", "backoff": False},
         "retryUntil": None, "days": {"2026-10-12": {"claude-fable-5-1": counts(10)}}}
    e.update(kw)
    return e


# ---- A1-01 label: golden HMAC vectors (T1) -----------------------------------------------------------
class TestA101Label(Base):
    def test_fixture_vectors_follow_the_spec_formula(self):
        # Self-check of the golden file (shared with Swift C1-01): it encodes the formula, not an implementation.
        for v in rl.fixture("label-vectors.json")["vectors"]:
            self.assertEqual(oracle_label(v["gist_id"], v["product"], v["local_id"]), v["label"], v)

    def test_known_key_vector(self):
        self.assertEqual(oracle_label(G1, "claude", U_A), "f4b718320ee15b3a")
        self.assertEqual(self.label("claude", U_A, G1), "f4b718320ee15b3a")

    def test_golden_vectors(self):
        for v in rl.fixture("label-vectors.json")["vectors"]:
            got = self.label(v["product"], v["local_id"], v["gist_id"])
            self.assertEqual(got, v["label"], v)
            self.assertRegex(got, HEX16)

    def test_normalisation_domain_separation_and_gist_key(self):
        variants = {self.label("codex", u) for u in (U_A, U_A.upper(), "  %s\n" % U_A)}
        self.assertEqual(len(variants), 1, "case/whitespace of the same UUID must give one label")
        self.assertNotEqual(self.label("claude", U_A), self.label("codex", U_A), "product is part of the domain")
        self.assertNotEqual(self.label("claude", U_A, G1), self.label("claude", U_A, G2), "key derives from gist id")
        self.assertNotEqual(self.label("claude", U_A), self.label("claude", U_B))


# ---- A1-02 / A1-04 / A1-05 local identity (T2, T4 in Yurka's wording, T5) -----------------------------
class TestA102LocalIdentity(Base):
    def test_claude_reads_only_account_uuid(self):
        self.write_claude_json(U_A)
        self.write_claude_credentials()
        local_id, reason = self.ident("claude")
        self.assertEqual((local_id or "").strip().lower(), U_A)
        self.assertIsNone(reason)
        self.assert_no_sentinel(repr((local_id, reason)), "read_local_id(claude)")

    def test_missing_account_uuid_never_falls_back_to_organization(self):
        self.write_claude_json(None)  # oauthAccount present, organizationUuid present, accountUuid absent
        local_id, reason = self.ident("claude")
        self.assertIsNone(local_id)
        self.assertEqual(reason, "no_account_uuid")

    def test_no_oauth_block_or_no_file_is_no_login(self):
        local_id, reason = self.ident("claude")
        self.assertEqual((local_id, reason), (None, "no_login"))
        self.write_claude_json(oauth=False)
        self.assertEqual(self.ident("claude"), (None, "no_login"))

    def test_codex_reads_only_account_id(self):  # A1-04
        self.write_codex_auth("acct-fixture-0001")
        local_id, reason = self.ident("codex")
        self.assertEqual(local_id, "acct-fixture-0001")
        self.assertIsNone(reason)
        self.assert_no_sentinel(repr((local_id, reason)), "read_local_id(codex)")
        os.unlink(common.CODEX_AUTH)
        self.assertEqual(self.ident("codex"), (None, "no_login"))

    def test_reader_never_writes_login_files(self):
        self.write_claude_json(U_A)
        self.write_claude_credentials()
        self.write_codex_auth("acct-fixture-0001")
        before = self.snap_cred()
        self.ident("claude")
        self.ident("codex")
        self.assertEqual(self.snap_cred(), before)


class TestA105IdentityChange(Base):
    def test_token_rotation_keeps_label_new_uuid_changes_it_missing_uuid_is_null(self):
        self.write_claude_json(U_A)
        self.write_claude_credentials("fixture-access-1", "fixture-refresh-1")
        first = self.label("claude", self.ident("claude")[0])
        self.write_claude_credentials("fixture-access-2", "fixture-refresh-2")  # CLI rotated tokens, same account
        self.assertEqual(self.label("claude", self.ident("claude")[0]), first)
        self.write_claude_json(U_B)  # re-read every pass: another account
        self.assertNotEqual(self.label("claude", self.ident("claude")[0]), first)
        self.write_claude_json(None)
        self.assertEqual(self.ident("claude"), (None, "no_account_uuid"))


# ---- A1-03 hostile ~/.claude.json (T6) ---------------------------------------------------------------
class TestA103HostileClaudeJson(Base):
    def assert_unreadable(self, raw, what):
        self.need_common("CLAUDE_JSON")
        self.write_claude_json(raw=raw)
        sleeps = []
        started = time.monotonic()
        with mock.patch("time.sleep", sleeps.append):
            local_id, reason = self.ident("claude")
        self.assertLess(time.monotonic() - started, 5.0, what + ": retries must use the injectable sleep")
        self.assertLessEqual(len(sleeps), 5, what)
        self.assertEqual((local_id, reason), (None, "unreadable"), what)

    def test_not_json_empty_and_deep(self):
        self.assert_unreadable("{not json", "not JSON")
        self.assert_unreadable("", "empty (CLI mid-write)")
        self.assert_unreadable("[" * 10000 + "]" * 10000, "depth 10^4")

    def test_over_8_mb_is_not_parsed(self):
        pad = "x" * (20 * MiB)
        self.assert_unreadable(json.dumps({"oauthAccount": {"accountUuid": U_A}, "pad": pad}), "20 MB file")


# ---- A1-06 / A1-07 accountByDay and labels outside local stores (A6, T3) ------------------------------
class TestA106AccountByDay(Base):
    D1, D2 = "2026-10-11", "2026-10-12"

    def transcript(self, name, lines):
        path = os.path.join(common.CLAUDE_PROJECTS, "proj", name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "a") as f:
            for mid, ts in lines:
                f.write(json.dumps({"type": "assistant", "timestamp": ts, "message": {
                    "id": mid, "model": "claude-fable-5-1",
                    "usage": {"input_tokens": 1, "output_tokens": 1, "cache_read_input_tokens": 0}}}) + "\n")
        os.utime(path, (rl.NOW, rl.NOW))

    def scan(self, ix):
        usage.scan(ix, now=rl.NOW, claude_root=common.CLAUDE_PROJECTS, codex_root=common.CODEX_SESSIONS)

    def day(self, ts):
        return common.day_key(common.parse_iso(ts))

    def test_first_indexing_owns_the_day(self):
        t1, t2, t3 = "2026-10-11T09:00:00Z", "2026-10-11T15:00:00Z", "2026-10-12T09:00:00Z"
        self.write_claude_json(U_A)
        self.transcript("a.jsonl", [("m1", t1)])
        ix = usage.new_index()
        self.scan(ix)
        by_day = ix.get("accountByDay", {}).get("claude")
        self.assertIsInstance(by_day, dict, "contract: ix['accountByDay']['claude']")
        self.assertEqual(by_day.get(self.day(t1)), U_A)
        self.write_claude_json(U_B)  # login switched in the middle of the same day
        self.transcript("a.jsonl", [("m2", t2), ("m3", t3)])
        self.scan(ix)
        self.assertEqual(ix["accountByDay"]["claude"][self.day(t1)], U_A, "a day's owner never changes")
        self.assertEqual(ix["accountByDay"]["claude"][self.day(t3)], U_B)
        self.assertEqual(ix["days"]["claude"][self.day(t1)]["claude-fable-5-1"]["turns"], 2)

    def test_day_without_identity_stays_unattributed(self):
        t1 = "2026-10-11T09:00:00Z"
        self.transcript("a.jsonl", [("m1", t1)])
        ix = usage.new_index()
        self.scan(ix)
        self.assertIsNone(ix.get("accountByDay", {}).get("claude", {}).get(self.day(t1)), "no login → unattributed")
        self.write_claude_json(U_A)
        self.transcript("a.jsonl", [("m2", "2026-10-11T10:00:00Z"), ("m3", "2026-10-12T09:00:00Z")])
        self.scan(ix)
        self.assertIn("accountByDay", ix, "contract: ix['accountByDay']")
        self.assertIsNone(ix["accountByDay"].get("claude", {}).get(self.day(t1)), "first indexing (no login) wins")
        self.assertEqual(ix["accountByDay"]["claude"].get(self.day("2026-10-12T09:00:00Z")), U_A)

    def test_index_stores_local_ids_never_labels(self):  # A1-07 (T3)
        self.write_claude_json(U_A)
        self.transcript("a.jsonl", [("m1", "2026-10-11T09:00:00Z")])
        ix = usage.new_index()
        self.scan(ix)
        self.assertIn("accountByDay", ix, "contract: ix['accountByDay']")
        text = json.dumps(ix)
        for g in (G1, G2):
            self.assertNotIn(oracle_label(g, "claude", U_A), text, "labels are computed only when building the block")


class TestA107GistChange(Base):
    def test_new_gist_relabels_every_account_consistently(self):
        self.need("build")
        ents = [entry("claude", U_A), entry("codex", U_B, plan="pro", tier=None,
                                            days={"2026-10-10": {"gpt-6-astra": counts(1)}})]
        b1 = accounts.build(gist_id=G1, entries=copy.deepcopy(ents), unattributed_days={}, captions={})
        b2 = accounts.build(gist_id=G2, entries=copy.deepcopy(ents), unattributed_days={}, captions={})
        l1 = {(a["product"], a["label"]) for a in b1["accounts"]}
        l2 = {(a["product"], a["label"]) for a in b2["accounts"]}
        self.assertEqual(l1, {("claude", oracle_label(G1, "claude", U_A)), ("codex", oracle_label(G1, "codex", U_B))})
        self.assertEqual(l2, {("claude", oracle_label(G2, "claude", U_A)), ("codex", oracle_label(G2, "codex", U_B))})
        self.assertEqual(len(b2["accounts"]), 2, "no orphan second record of a product")
        self.assertEqual(rl.fixture("machine-v11.json")["accounts"][0]["label"], oracle_label(G1, "claude", U_A))


# ---- A1-08 root projection (C1/C5, §A rule 1) ---------------------------------------------------------
class TestA108Projection(Base):
    def test_root_days_are_accounts_plus_unattributed(self):
        self.need("build")
        unattributed = {"claude": {"2026-10-09": {"claude-opus-5-5": counts(7)}}}
        block = accounts.build(gist_id=G1, entries=[entry("claude", U_A), entry("codex", U_B, plan="pro", tier=None,
                               days={"2026-10-10": {"gpt-6-astra": counts(3)}})], unattributed_days=unattributed, captions={})
        self.assertIn("days", block, "contract: build() returns the root projection as 'days'")
        expected = usage.merge_days({"claude": {"2026-10-12": {"claude-fable-5-1": counts(10)}}},
                                    {"codex": {"2026-10-10": {"gpt-6-astra": counts(3)}}}, unattributed)
        self.assertEqual(block["days"], expected)
        self.assertEqual(block["unattributedDays"], unattributed)
        for a in block["accounts"]:
            self.assertIn("days", a, "accounts[*].days is always present")


# ---- A1-09 compatibility: old readers sum v1.1 exactly like v1 (C1, RL-3) — green now, must stay green ----
class TestA109OldReaders(unittest.TestCase):
    def setUp(self):
        self.legacy = rl.load_legacy_merge()

    def check(self, name, text=None):
        text = text if text is not None else rl.fixture_text(name)
        obj = json.loads(text)
        fname = "machine-%s.json" % obj["machine"]["id"]
        old = json.dumps(rl.strip_v11(obj))
        for merge in (self.legacy.merge, sync.merge):
            a = merge({fname: text}, "me", now=rl.NOW)
            b = merge({fname: old}, "me", now=rl.NOW)
            self.assertTrue(a["days"], name + ": fixture must carry usage")
            self.assertEqual(a["days"], b["days"], "%s via %s" % (name, merge.__module__))
            self.assertEqual([m["id"] for m in a["machines"]], [obj["machine"]["id"]])

    def test_v11_equals_v10_for_frozen_045_and_current_merge(self):
        self.check("machine-v11.json")
        v10 = rl.fixture("machine-v10.json")
        a = self.legacy.merge({"machine-fixturevps.json": rl.fixture_text("machine-v11.json")}, "me", now=rl.NOW)
        b = self.legacy.merge({"machine-fixturevps.json": json.dumps(v10)}, "me", now=rl.NOW)
        self.assertEqual(a["days"], b["days"])

    def test_hostile_block_never_affects_days(self):
        self.check("machine-v11-hostile.json")
        self.check("machine-v11-nonfinite.json")


# ---- A1-10 S3 scan of what goes to the gist (T12, F1 acc 3) -------------------------------------------
class TestA110Minimisation(Base):
    def assert_clean(self, text, where):
        self.assert_no_sentinel(text, where)
        self.assertIsNone(EMAIL.search(text), where + ": email pattern")
        self.assertIsNone(UUID.search(text), where + ": UUID pattern (only machine.id may be an id)")
        for f in FORBIDDEN:
            self.assertNotIn(f, text, "%s: %r" % (where, f))

    def test_golden_v11_is_clean(self):
        obj = rl.fixture("machine-v11.json")
        self.assert_clean(json.dumps(obj, ensure_ascii=False), "machine-v11.json")

    def test_build_drops_everything_outside_the_contract(self):
        self.need("build")
        s = rl.sentinels()
        dirty = entry("claude", U_A, email=s["email"], accessToken=s["accessToken"], refreshToken=s["refreshToken"],
                      id_token=s["id_token"], OPENAI_API_KEY=s["OPENAI_API_KEY"], organizationUuid=s["organizationUuid"],
                      fullName=s["fullName"], hostname=s["hostname"], path=s["home"] + "/proj",
                      error="Traceback: %s/x.py Bearer %s" % (s["users"], s["accessToken"]))
        block = accounts.build(gist_id=G1, entries=[dirty], unattributed_days={}, captions={})
        text = json.dumps(block, ensure_ascii=False)
        self.assert_clean(text, "accounts.build")
        self.assertNotIn(U_A, text.lower(), "local identity never leaves the machine")
        for a in block["accounts"]:
            self.assertLessEqual(set(a), ENTRY_KEYS, "allow-list of contract v1.1 keys")
            self.assertLessEqual(set(a.get("windows", {})), {"session", "weekly"})
            for w in a.get("windows", {}).values():
                self.assertLessEqual(set(w), {"pct", "resetAt"})
            for m in a.get("models", []):
                self.assertLessEqual(set(m), {"name", "pct", "resetAt"})
            self.assertLessEqual(set(a.get("schedule", {})), {"mode", "interval", "nextAt", "backoff"})

    def test_machine_file_never_carries_host_or_owner_name(self):
        s = rl.sentinels()
        common.settings().set("machineName", "vps")
        with mock.patch("socket.gethostname", return_value=s["hostname"]):
            text = sync.machine_file({"claude": {"2026-10-12": {"claude-fable-5-1": counts(1)}}})
        obj = json.loads(text)
        self.assertEqual(obj["machine"]["name"], "vps")
        self.assertNotIn(s["hostname"], text)


# ---- A1-11 machine tag (T13, П4-а; tag of the owner's Mac is `macbook`) --------------------------------
class TestA111MachineTag(Base):
    def tag(self, setting, hostname):
        self.need_common("machine_tag")
        common.settings().set("machineName", setting)
        with mock.patch("socket.gethostname", return_value=hostname):
            return common.machine_tag()

    def test_vectors(self):
        for v in rl.fixture("sanitize-vectors.json")["machine_tag"]:
            got = self.tag(v["setting"], v["hostname"])
            self.assertRegex(got, TAG, v)
            if v["expect"] is not None:
                self.assertEqual(got, v["expect"], v)
            for bad in v.get("forbid", []):
                self.assertNotIn(bad, got, v)

    def test_machine_file_publishes_the_tag_not_the_raw_name(self):
        common.settings().set("machineName", "MacBook Pro — Алекс")
        obj = json.loads(sync.machine_file({}))
        self.assertEqual(obj["machine"]["name"], "macbook-pro")


# ---- A1-12 writer-side strings and caps (T14 writer half, П4-в) ----------------------------------------
class TestA112WriterSanitising(Base):
    def test_captions(self):
        self.need("build")
        lbl = oracle_label(G1, "claude", U_A)
        for v in rl.fixture("sanitize-vectors.json")["caption"]:
            block = accounts.build(gist_id=G1, entries=[entry()], unattributed_days={},
                                   captions={lbl: {"text": v["text"], "setAt": "2026-10-12T09:00:00Z"}})
            got = (block.get("captions") or {}).get(lbl, {}).get("text")
            if v["ok"] is True:
                self.assertEqual(got, unicodedata.normalize("NFC", v["text"]), v)
            elif v["ok"] is False:
                self.assertIsNone(got, v)
            if got is not None:
                self.assertTrue(control_free(got), v)
                self.assertLessEqual(len(got), 32, v)
                self.assertNotIn("@", got)
                self.assertNotIn("/", got)

    def test_caps(self):
        self.need("build")
        models = [{"name": "m%d\u0007" % i if i % 2 else "n" * 60, "pct": 1, "resetAt": "2026-10-15T07:00:00Z"} for i in range(12)]
        ents = [entry("claude" if i % 2 else "codex", "%08d-0000-4000-8000-000000000000" % i, plan="p" * 64, tier="t" * 64,
                      models=copy.deepcopy(models)) for i in range(10)]
        block = accounts.build(gist_id=G1, entries=ents, unattributed_days={}, captions={})
        self.assertLessEqual(len(block["accounts"]), 8)
        for a in block["accounts"]:
            self.assertLessEqual(len(a.get("models", [])), 8)
            for m in a.get("models", []):
                self.assertTrue(m.get("name") is None or (control_free(m["name"]) and len(m["name"]) <= 48), m)
            meta = {k: v for k, v in a.items() if k != "days"}
            self.assertLessEqual(len(json.dumps(meta, ensure_ascii=False).encode("utf-8")), 4096)
            for k in ("plan", "tier"):
                self.assertLessEqual(len(a.get(k) or ""), 64)


# ---- A1-13 reader validation C7 on hostile files (T15, T19, T36 Linux part) ------------------------------
class TestA113ReaderValidation(Base):
    def parsed(self, name="machine-v11-hostile.json"):
        self.need("parse_block", "validate_entry")
        return accounts.parse_block(json.loads(rl.fixture_text(name)))

    def by_label(self, block, product, local_id):
        lbl = oracle_label(G1, product, local_id)
        return [a for a in block["accounts"] if a.get("label") == lbl]

    def assert_window(self, w):
        self.assertIsNot(type(w.get("pct")), bool)
        self.assertIsInstance(w.get("pct"), (int, float))
        self.assertTrue(math.isfinite(w["pct"]) and 0 <= w["pct"] <= 100, w)

    def test_every_surviving_field_is_within_the_contract(self):
        block = self.parsed()
        self.assertLessEqual(len(block["accounts"]), 8)
        for a in block["accounts"]:
            self.assertIn(a.get("product"), ("claude", "codex"))
            self.assertIn(a.get("status"), STATUSES)
            self.assertTrue(a.get("label") is None or HEX16.match(a["label"]), a.get("label"))
            for w in (a.get("windows") or {}).values():
                self.assert_window(w)
            self.assertLessEqual(len(a.get("models") or []), 8)
            for m in a.get("models") or []:
                self.assert_window(m)
                self.assertTrue(m.get("name") is None or len(m["name"]) <= 48)
            for k in ("asOf", "attemptAt", "retryUntil"):
                self.assertTrue(a.get(k) is None or common.parse_iso(a[k]) is not None, (k, a.get(k)))
            for k in ("plan", "tier", "expiredReason"):
                self.assertTrue(a.get(k) is None or len(a[k]) <= 64, k)
            if a.get("resetCredits") is not None:
                self.assertTrue(type(a["resetCredits"]) is int and 0 <= a["resetCredits"] <= 1000)
            sched = a.get("schedule") or {}
            self.assertTrue(sched.get("interval") is None or sched["interval"] in INTERVALS, sched)
            self.assertTrue(sched.get("mode") is None or sched["mode"] in ("auto", "fixed"), sched)
            self.assertTrue(sched.get("backoff") is None or type(sched["backoff"]) is bool, sched)
            for s in all_strings({k: v for k, v in a.items() if k != "days"}):
                self.assertTrue(control_free(s), repr(s))

    def test_specific_hostile_cases(self):
        block = self.parsed()
        dup = self.by_label(block, "claude", "hostile-a")
        self.assertEqual(len(dup), 1, "duplicate (product, label) collapses")
        self.assertEqual(common.parse_iso(dup[0]["asOf"]), common.parse_iso("2026-10-12T09:00:00Z"), "max asOf wins")
        self.assertNotIn("session", dup[0].get("windows") or {}, 'pct "80" (string) drops the window')
        self.assertNotIn("weekly", dup[0].get("windows") or {}, "pct true drops the window")
        self.assertEqual([m.get("name") for m in dup[0].get("models") or []], ["good"])
        self.assertEqual([a["status"] for a in self.by_label(block, "codex", "hostile-b")], ["error"], "unknown status → error")
        self.assertEqual(self.by_label(block, "codex", "hostile-c"), [], "no product → dropped")
        self.assertEqual(self.by_label(block, "codex", "hostile-d"), [], "no status → dropped")
        self.assertNotIn("NOT-A-HEX-LABEL!", json.dumps(block))
        times = self.by_label(block, "codex", "hostile-e")
        self.assertEqual(len(times), 1, "broken times drop fields, not the record")
        for k in ("asOf", "attemptAt", "retryUntil"):
            self.assertIsNone(times[0].get(k), k)
        self.assertIsNone(((times[0].get("windows") or {}).get("session") or {}).get("resetAt"))
        self.assertLessEqual(len(self.by_label(block, "codex", "hostile-g")[0].get("models") or []), 8)
        self.assertIsNone(block.get("lastSeenAt"), "garbage lastSeenAt → None (reader falls back to updated)")

    def test_captions_bounds(self):
        block = self.parsed()
        caps = block.get("captions") or {}
        self.assertLessEqual(len(caps), 64)
        for k, v in caps.items():
            self.assertRegex(k, HEX16)
            self.assertTrue(control_free(v.get("text", "")) and len(v.get("text", "")) <= 32, v)

    def test_projection_never_double_counts(self):  # T19
        obj = rl.fixture("machine-v11-hostile.json")
        block = self.parsed()
        root = sum_by_product(*[(p, d) for p, d in obj["days"].items()])
        parts = [(a["product"], a.get("days")) for a in block["accounts"]]
        parts += [(p, d) for p, d in (block.get("unattributedDays") or {}).items()]
        self.assertEqual(sum_by_product(*parts), root, "accounts + 'не указан' == root, per product")

    def test_non_finite_numbers(self):  # Python json accepts NaN/Infinity/1e400 → isfinite is mandatory
        block = self.parsed("machine-v11-nonfinite.json")
        self.assertEqual(len(block["accounts"]), 1)
        a = block["accounts"][0]
        self.assertEqual(a.get("windows") or {}, {})
        self.assertEqual(a.get("models") or [], [])

    def test_validate_entry_direct(self):
        self.need("validate_entry")
        lbl = oracle_label(G1, "claude", U_A)
        base = {"product": "claude", "label": lbl, "status": "ok", "days": {}}
        self.assertIsNone(accounts.validate_entry({k: v for k, v in base.items() if k != "product"}))
        self.assertIsNone(accounts.validate_entry({k: v for k, v in base.items() if k != "status"}))
        for bad in ("80", True, 140, -0.1, float("nan"), float("inf")):
            e = accounts.validate_entry(dict(base, windows={"session": {"pct": bad, "resetAt": "2026-10-12T13:00:00Z"}}))
            self.assertNotIn("session", e.get("windows") or {}, bad)
        ok = accounts.validate_entry(dict(base, windows={"session": {"pct": 0, "resetAt": "2026-10-12T13:00:00Z"}}))
        self.assertEqual(ok["windows"]["session"]["pct"], 0, "0 is a real reading, not 'missing'")

    def test_parse_iso_regression_t36(self):
        self.assertIsNone(common.parse_iso("2026-10-12T10:00:00+99:00"))
        self.assertIsNone(common.parse_iso("99999-01-01T00:00:00Z"))
        v = common.parse_iso("2026-10-12T10:00:00." + "1" * 10 ** 6 + "Z")
        self.assertTrue(v is None or math.isfinite(v))


# ---- A1-14 reader limits (T18, T30; synth v2 §A C7) -------------------------------------------------------
def padded_machine(mid, size):
    head = json.loads(rl._sync_env.machine_json(mid, updated="2026-10-12T10:00:00Z"))
    head["pad"] = ""
    base = len(json.dumps(head, separators=(",", ":")).encode())
    head["pad"] = "x" * (size - base)
    text = json.dumps(head, separators=(",", ":"))
    assert len(text.encode()) == size
    return text


class TestA114ReaderLimits(Base):
    RAW = "https://gist.githubusercontent.com/u/g1/raw/abc/machine-%s.json"

    def cycle_with(self, others, raws=()):
        self.sign_in()
        self.mark_pushed()
        self.gh.on("GET", "/gists/g1", self.ok_gist(others))
        for url, body in raws:
            self.gh.on("GET", url, rl._sync_env.resp(200, raw=body))
        return self.cycle()

    def machine_ids(self, res):
        return [m["id"] for m in ((res.remote or {}).get("machines") or [])]

    def test_raw_url_at_8_mib_accepted(self):
        res = self.cycle_with({"machine-big.json": {"truncated": True, "raw_url": self.RAW % "big", "content": ""}},
                              [(self.RAW % "big", padded_machine("big", 8 * MiB).encode())])
        self.assertTrue(res.ok, res.error)
        self.assertIn("big", self.machine_ids(res))

    def test_raw_url_over_8_mib_rejected(self):
        res = self.cycle_with({"machine-big.json": {"truncated": True, "raw_url": self.RAW % "big", "content": ""}},
                              [(self.RAW % "big", padded_machine("big", 8 * MiB + 1).encode())])
        self.assertNotIn("big", self.machine_ids(res))
        self.assertFalse(res.ok, "an oversized raw file is an error, not a silent skip")

    def test_at_most_64_machine_files(self):
        others = {"machine-m%02d.json" % i: rl._sync_env.machine_json("m%02d" % i) for i in range(65)}
        res = self.cycle_with(others)
        self.assertLessEqual(len(self.machine_ids(res)), 64)

    def test_total_over_64_mib(self):
        size = int(7.5 * MiB)
        others, raws = {}, []
        for i in range(9):
            mid = "r%d" % i
            others["machine-%s.json" % mid] = {"truncated": True, "raw_url": self.RAW % mid, "content": ""}
            raws.append((self.RAW % mid, padded_machine(mid, size).encode()))
        res = self.cycle_with(others, raws)
        self.assertLessEqual(len(self.machine_ids(res)) * size, 64 * MiB)

    def test_gist_body_over_16_mib(self):
        """A GET /gists/{id} body over 16 MiB is never read whole: the real outer transport (sync._transport →
        common.http, socket answer faked) stops at cap+1. Since N8 (A3-30) the gist is then found through the
        listing (`GET /gists?per_page=100`, no inline bodies) and each file is read through its raw_url with
        the 8 MiB cap — the 17 MiB file is cut at 8 MiB+1 as well and its refusal is a visible error."""
        name, raw_url = "machine-huge.json", self.RAW % "huge"
        huge = padded_machine("huge", 17 * MiB)
        gist_bytes = json.dumps(rl._sync_env.gist_json(
            {sync.MANIFEST: "{}", sync.my_file_name(): "{}", name: huge})).encode()
        self.assertGreater(len(gist_bytes), sync.MAX_BODY + 1)
        listing = [
            {"id": "other", "public": False, "files": {}},
            {"id": rl._sync_env.GIST, "public": False, "created_at": "2026-09-01T00:00:00Z", "files": {
                sync.MANIFEST: {"filename": sync.MANIFEST, "size": 2, "raw_url": self.RAW % "manifest"},
                sync.my_file_name(): {"filename": sync.my_file_name(), "size": 2, "raw_url": self.RAW % "mine"},
                name: {"filename": name, "size": len(huge), "raw_url": raw_url}}}]
        reads = {"gist": [], "raw": []}
        # common.http is the isolation guard here; run a fresh copy of the real one (as in the cap+1 test below)
        import importlib.util
        spec = importlib.util.spec_from_file_location("ccl_common_n8", os.path.join(rl.ROOT, "linux", "ccl", "common.py"))
        real_common = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(real_common)

        def socket_answer(kind, data):
            class Body(io.BytesIO):
                status, headers = 200, {}

                def read(self, n=-1):
                    chunk = super().read(n)
                    reads[kind].append((n, len(chunk)))
                    return chunk

            def route(url, method, headers, body):
                opener = SimpleNamespace(open=lambda req, timeout=None: Body(data))
                with mock.patch("urllib.request.build_opener", lambda *a: opener), \
                        mock.patch.object(common, "http", real_common.http):
                    return sync._transport(url, method, headers, body, 20)
            return route

        self.sign_in()
        self.mark_pushed()
        self.gh.on("GET", "/gists/g1", socket_answer("gist", gist_bytes))
        self.gh.on("GET", "/gists?per_page=100", rl._sync_env.resp(200, listing))
        self.gh.on("GET", raw_url, socket_answer("raw", huge.encode()))
        res = self.cycle()

        self.assertEqual(self.gh.urls(), [("GET", "/gists/g1"), ("GET", "/gists?per_page=100"), ("GET", raw_url)])
        for kind, cap in (("gist", sync.MAX_BODY), ("raw", sync.MAX_MACHINE_BODY)):
            self.assertTrue(reads[kind], kind)
            self.assertTrue(all(n is not None and 0 <= n <= cap + 1 for n, _ in reads[kind]), (kind, reads[kind]))
            self.assertLessEqual(sum(got for _, got in reads[kind]), cap + 1, kind)
        self.assertNotIn("huge", self.machine_ids(res))
        self.assertFalse(res.ok)
        self.assertTrue(res.error, "the refused oversized body must be a visible error")

    def test_control_characters_in_old_machine_fields(self):  # П5-е
        obj = rl.fixture("machine-v11-hostile.json")
        merged = sync.merge({"machine-fixturehostile.json": json.dumps(obj)}, "me", now=rl.NOW)
        self.assertEqual([m["id"] for m in merged["machines"]], ["fixturehostile"])
        for k in ("name", "os", "app"):
            v = merged["machines"][0].get(k)
            self.assertTrue(v is None or (control_free(v) and len(v) <= 64), (k, v))

    def test_http_reads_at_most_cap_plus_one(self):
        """common.http(max_body=) stops at cap+1 bytes and refuses with "response body too large".

        Seam: a real HTTP/1.1 server on 127.0.0.1 (as in test_rl_publisher_fixes2), a fresh copy of ccl/common.py
        (the imported one is the isolation guard). The whole real client stack runs — build_opener, the deadline
        handlers, http.client — so no private seam of common.http can be bypassed silently (the old `urlopen` fake
        went dead when http() switched to build_opener). Connects are allowed to 127.0.0.1 only; any other
        target is recorded and fails the test even though common.http swallows the guard's exception."""
        import importlib.util
        import socket
        import _socket
        import http.client
        spec = importlib.util.spec_from_file_location("ccl_common_probe", os.path.join(rl.ROOT, "linux", "ccl", "common.py"))
        probe = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(probe)
        cap = 16 * MiB
        slack = 256 * 1024  # status line + headers + both read-ahead buffers (8 KiB each by default)
        foreign, reads, wire = [], [], [0]

        def loopback_only(address):
            if not (isinstance(address, tuple) and address[:1] == ("127.0.0.1",)):
                foreign.append(address)
                raise AssertionError("сеть в тестах запрещена (не loopback): %r" % (address,))

        def connect(sock, address):
            loopback_only(address)
            return _socket.socket.connect(sock, address)

        def create_connection(address, timeout=socket._GLOBAL_DEFAULT_TIMEOUT, source_address=None, **kw):
            loopback_only(address)
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            if timeout is not socket._GLOBAL_DEFAULT_TIMEOUT:
                sock.settimeout(timeout)
            _socket.socket.connect(sock, address)
            return sock

        real_readinto = socket.SocketIO.readinto

        def counted_readinto(sio, b):  # client side only: the server below uses recv/sendall
            n = real_readinto(sio, b)
            wire[0] += n or 0
            return n

        def spy(name):
            real = getattr(http.client.HTTPResponse, name)

            def call(resp, *a, **kw):
                n = a[0] if a else kw.get("amt", kw.get("n"))
                out = real(resp, *a, **kw)
                reads.append((name, n, len(out) if isinstance(out, (bytes, bytearray)) else 0))
                return out
            return call

        p = mock.patch.dict(os.environ, {"no_proxy": "*", "NO_PROXY": "*"})  # restores the proxy variables too
        p.start()
        self.addCleanup(p.stop)
        for k in ("http_proxy", "HTTP_PROXY", "https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY"):
            os.environ.pop(k, None)
        for target, value in (("socket.socket.connect", connect), ("socket.create_connection", create_connection),
                              ("socket.SocketIO.readinto", counted_readinto),
                              ("http.client.HTTPResponse.read", spy("read")),
                              ("http.client.HTTPResponse.read1", spy("read1"))):
            p = mock.patch(target, value)
            p.start()
            self.addCleanup(p.stop)

        for size, accepted in ((cap, True), (cap + 1, False), (cap + 8 * MiB, False)):
            with self.subTest(size=size):
                reads.clear()
                wire[0] = 0
                server = _CappedBodyServer(size)
                try:
                    r = probe.http(server.url("/gists/g1"), max_body=cap)
                finally:
                    server.close()
                self.assertEqual(foreign, [], "common.http tried a non-loopback connect")
                self.assertEqual(server.errors, [], "loopback server harness")
                self.assertEqual(server.requests, 1, "the request reached the loopback server (the seam is live)")
                self.assertGreater(wire[0], 0, "the body was read from the socket (the seam is live)")
                self.assertTrue(all(isinstance(n, int) and 0 <= n <= cap + 1 for _, n, _ in reads), reads)
                self.assertLessEqual(sum(got for _, _, got in reads), cap + 1, "body bytes returned by HTTPResponse")
                self.assertLessEqual(wire[0], cap + 1 + slack, "bytes taken from the socket: at most cap+1 of the body")
                if accepted:
                    self.assertEqual((r.status, r.error, len(r.data or b"")), (200, None, cap))
                else:
                    self.assertEqual((r.status, r.data, r.error), (0, None, "response body too large"))
                    self.assertEqual(r.original_status, 200)


class _CappedBodyServer(object):
    """One-request HTTP/1.1 server on 127.0.0.1: answers 200 with `size` bytes and Content-Length.
    The client may hang up after cap+1 bytes; the resulting broken pipe is expected, not a harness error."""

    def __init__(self, size):
        import socket
        import threading
        self.size, self.errors, self.requests = size, [], 0
        self.srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.srv.bind(("127.0.0.1", 0))
        self.srv.listen(1)
        self.srv.settimeout(10)
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def url(self, path):
        return "http://127.0.0.1:%d%s" % (self.srv.getsockname()[1], path)

    def _serve(self):
        try:
            c, _ = self.srv.accept()
        except OSError:
            return
        try:
            c.settimeout(10)
            buf = b""
            while b"\r\n\r\n" not in buf:
                got = c.recv(65536)
                if not got:
                    return
                buf += got
            self.requests += 1
            c.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\n"
                      b"Connection: close\r\n\r\n" % self.size)
            piece, left = b"x" * (64 * 1024), self.size
            while left:
                n = min(left, len(piece))
                c.sendall(piece[:n])
                left -= n
        except OSError:
            pass  # the client stopped reading at cap+1 and closed
        except Exception as e:
            self.errors.append(repr(e))
        finally:
            c.close()

    def close(self):
        self.srv.close()
        self.thread.join(15)


# ---- A1-15 protocol document carries a valid v1.1 example (C8) ------------------------------------------
class TestA115ProtocolDoc(Base):
    def test_sync_protocol_has_a_v11_example_that_validates(self):
        with open(os.path.join(rl.ROOT, "docs", "sync-protocol.md"), encoding="utf-8") as f:
            doc = f.read()
        blocks = [b for b in re.findall(r"```json\n(.*?)```", doc, re.S) if '"accounts"' in b]
        self.assertTrue(blocks, "docs/sync-protocol.md: no ```json example of contract v1.1 with \"accounts\"")
        obj = json.loads(blocks[0])
        self.need("parse_block")
        parsed = accounts.parse_block(obj)
        self.assertTrue(parsed["accounts"])
        self.assertEqual(len(parsed["accounts"]), len(obj["accounts"]), "the documented example loses nothing")


if __name__ == "__main__":
    unittest.main()
