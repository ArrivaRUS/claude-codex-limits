"""REMOTE-LIMITS C1, fix cycle 1 — Linux side of the C1 review (docs/review-remote-limits-c1.md, decisions 2026-10-18 M1/M2/m7).

Test-plan IDs (docs/test-plan-remote-limits.md §C1): C1-10 (M2, Linux port `sync.py`), C1-12 / C1-15 / C1-16 (Linux reference
for the Swift parity checks — the Linux reader is the source of truth here, so those are GUARDS and must stay green),
C1-18 (T2 S1, docs/security-remote-limits-c1-t2.md: binary body — guard; EMPTY 200 body — red, Linux has the same defect).

Written BEFORE the fix ("red first"):
  * «Red now» — TestC110BudgetRemainderNotCached: `sync.py` caches a raw_url refusal (`rejectedRaw`, 24 h) whenever the body
    exceeds `cap = min(8 MiB, 64 MiB − already read)`. sync-protocol.md «Reader limits» puts only the own 8 MiB excess into the
    refused-raw cache; an exhausted total budget belongs to the current cycle only. Fix: cache only when cap == MAX_MACHINE_BODY.
  * «Red now» — TestC118UnreadableRawReference.test_empty_body_skips_only_that_file: an empty 200 raw body aborts the read.
  * «Green guard» — everything else: the 8 MiB + 1 refusal IS cached; the 4 KiB metadata measure; `updated` parsing; integers.

Sandbox: `_rl_env` (temp HOME/XDG before imports, audit hook on the real ~/.claude*/~/.codex, network refused), FakeGist on
sync.transport, FakeClock on time.time. No real sleeps, no network, no systemctl.

Run: cd linux && python3 -m unittest tests.test_rl_contract_fixes3 -v
"""

if __package__:
    from . import _rl_env as rl
    from . import test_rl_publisher as pub
else:
    import _rl_env as rl
    import test_rl_publisher as pub

import hashlib
import json
import unittest

from ccl import accounts, common, sync

NOW = rl.NOW
MiB = 1024 * 1024
REF_NOW = common.parse_iso("2026-10-12T10:20:00Z")
UPDATED = "2026-10-12T10:00:00Z"
UPDATED_TS = common.parse_iso(UPDATED)


def tearDownModule():
    rl.assert_real_files_untouched()


def padded_machine(mid, size):
    """A valid v1 machine file of exactly `size` UTF-8 bytes (ASCII padding) — same shape as rlPadded() in Swift."""
    head = '{"schema":1,"machine":{"id":"%s","name":"pc-%s","os":"T"},"days":{},"pad":"' % (mid, mid)
    tail = '"}'
    return (head + "x" * (size - len(head) - len(tail)) + tail).encode("utf-8")


# ---- C1-10 (M2): budget remainder ≠ the 8 MiB cap — only the latter goes to rejectedRaw -----------------------------------
class TestC110BudgetRemainderNotCached(pub.BigFiles):
    """8 raw files of 7.875 MiB (63 MiB read), then a valid 2 MiB file: its cap is the remaining 1 MiB, so it is skipped in
    THIS cycle, but it is not «too large» by the protocol and must be read in the next cycle with a free budget."""

    BIG_PART = 8 * MiB - MiB // 8          # 7.875 MiB; 8 of them = 63 MiB
    TWO = "machine-c-two.json"

    def setUp(self):
        super().setUp()
        self.write_settings(publisher=False)

    @staticmethod
    def key(url):
        return hashlib.sha256(url.encode("utf-8")).hexdigest()[:16]

    def rejected(self):
        st = sync.sync_state()
        st.reload()
        value = st.get("rejectedRaw")
        return value if isinstance(value, dict) else {}

    def new_process_cycle(self):
        common._state = common._settings = None
        sync._first_attempt_at = None
        return sync.sync_cycle({}, auto=False)

    def raw_file(self, name, data, sha="aaaaaaaaaaaa"):
        url = rl.RAW_ROOT + "owner/g1/raw/" + sha + "/" + name
        self.gist.put(name, "{}")
        self.gist.truncated[name] = url
        self.gist.raw[url] = data
        return url

    def drop_file(self, name):
        self.gist.revs.pop(name, None)
        self.gist.truncated.pop(name, None)

    def machines(self, res):
        return [m["id"] for m in (res.remote or {}).get("machines", [])]

    def test_budget_remainder_refusal_is_not_cached(self):
        """Red now: sync.py:1146 calls _reject_raw for any body > cap, including cap = the remaining total budget."""
        bigs = ["machine-b%d.json" % i for i in range(8)]
        for i, name in enumerate(bigs):
            self.raw_file(name, padded_machine("b%d" % i, self.BIG_PART))
        url = self.raw_file(self.TWO, padded_machine("c-two", 2 * MiB))
        res = self.new_process_cycle()
        self.assertEqual(len(self.ledger.of("RAW", url=url)), 1, "предусловие: 2 МиБ-файл запрошен с остатком бюджета 1 МиБ")
        self.assertNotIn("c-two", self.machines(res), "в этом цикле файл пропущен — бюджет 64 МиБ исчерпан")
        self.assertIn("b0", self.machines(res), "уже прочитанные файлы слиты")
        self.assertNotIn(self.key(url), self.rejected(),
                         "M2: превышен только остаток общего бюджета (cap < 8 МиБ) — raw_url не попадает в rejectedRaw "
                         "(sync-protocol.md «Reader limits»: в кэш идёт только превышение 8 МиБ)")

    def test_next_cycle_with_free_budget_reads_the_file(self):
        """Red now: the 24 h cache entry makes the next process skip the file without a download."""
        bigs = ["machine-b%d.json" % i for i in range(8)]
        for i, name in enumerate(bigs):
            self.raw_file(name, padded_machine("b%d" % i, self.BIG_PART))
        url = self.raw_file(self.TWO, padded_machine("c-two", 2 * MiB))
        self.new_process_cycle()
        for name in bigs:
            self.drop_file(name)
        self.clock.advance(600)
        res = self.new_process_cycle()
        self.assertEqual(len(self.ledger.of("RAW", url=url)), 2, "следующий цикл со свободным бюджетом качает файл снова")
        self.assertIn("c-two", self.machines(res), "и сливает его (2 МиБ < 8 МиБ — допустимый файл)")

    def test_over_8_mib_is_cached(self):
        """Green guard: a body over the own 8 MiB cap is refused for 24 h — the next process does not download it."""
        url = self.raw_file("machine-zzzz-big.json", b"x" * (8 * MiB + 1))
        self.new_process_cycle()
        self.assertEqual(self.rejected().get(self.key(url)), NOW, "превышение 8 МиБ — в rejectedRaw")
        self.clock.advance(600)
        self.new_process_cycle()
        self.assertEqual(len(self.ledger.of("RAW", url=url)), 1, "отвергнутый (> 8 МиБ) raw_url не качается повторно")


# ---- C1-18 (T2 S1): an unreadable / empty raw body skips that file only; its bytes count in the 64 MiB budget ---------------
class TestC118UnreadableRawReference(TestC110BudgetRemainderNotCached):
    """Linux reference for the Swift C1-18 (decision 2026-10-18 «C1 T2: S1–S3»).
    Binary body: green guard — `text = r.data` (bytes) is counted, merge decodes with errors="replace" and skips the file.
    Empty 200 body: «Red now» — sync.py:1158-1167 (`r.status != 200 or not r.data` → _fail + return) aborts the cycle, the
    same defect as S1 in Swift; sync-protocol.md: «one bad record never stops the merge»."""

    # Inherited C1-10 tests would run twice; keep only this class's own.
    test_budget_remainder_refusal_is_not_cached = None
    test_next_cycle_with_free_budget_reads_the_file = None
    test_over_8_mib_is_cached = None

    def new_process_cycle(self):
        sync.sync_state().update(lastOkAt=None)               # the cycle under test must set it itself
        return super().new_process_cycle()

    def last_ok(self):
        st = sync.sync_state()
        st.reload()
        return st.get("lastOkAt")

    def test_binary_body_skips_only_that_file(self):
        self.raw_file("machine-aa.json", padded_machine("aa", 200))
        self.raw_file("machine-bin.json", b"\xff\xfe" + b"\xff" * (2 * MiB - 2))
        self.raw_file("machine-zz.json", padded_machine("zz", 200))
        res = self.new_process_cycle()
        self.assertEqual(sorted(self.machines(res)), ["aa", "zz"], "бинарное тело — пропущен только этот файл")
        self.assertEqual(self.last_ok(), NOW, "lastOkAt сдвинулся")

    def test_empty_body_skips_only_that_file(self):
        """Red now: an empty 200 raw body aborts the whole read (sync.py:1158)."""
        self.raw_file("machine-aa.json", padded_machine("aa", 200))
        self.raw_file("machine-empty.json", b"")
        self.raw_file("machine-zz.json", padded_machine("zz", 200))
        res = self.new_process_cycle()
        self.assertEqual(sorted(self.machines(res)), ["aa", "zz"], "пустое тело 200 — пропущен только этот файл")
        self.assertEqual(self.last_ok(), NOW, "lastOkAt сдвинулся")

    def test_binary_bytes_count_in_the_budget(self):
        for i in range(8):
            self.raw_file("machine-b%d.json" % i, padded_machine("b%d" % i, self.BIG_PART))
        self.raw_file("machine-c-bin.json", b"\xff" * MiB)                     # 63 + 1 = 64 MiB spent
        url = self.raw_file("machine-d-next.json", padded_machine("d-next", 200))
        res = self.new_process_cycle()
        self.assertEqual(self.ledger.of("RAW", url=url), [], "бюджет исчерпан бинарным телом — следующий файл не запрошен")
        self.assertIn("b0", self.machines(res))
        self.assertNotIn("d-next", self.machines(res))


# ---- C1-12 (minor): the 4 KiB metadata cap is measured on the sanitized wire dict with the ORIGINAL ISO strings -------------
def _boundary(wire_head, wire_tail, total):
    """Fraction digits so that len(wire_head + digits + wire_tail) == total (all ASCII)."""
    return total - len(wire_head) - len(wire_tail)


class TestC112MetadataCapMeasure(unittest.TestCase):
    """Green guard (Linux reference for the Swift C1-12): json.dumps(out, ensure_ascii=False, separators=(",", ":")) of the
    sanitized record before `days`; ISO strings as in the file; `"label":null` and `"retryUntil":null` counted; `/` not
    escaped. The Swift selftest builds the same wire string by hand — these tests prove that arithmetic on the reference."""

    DATE_HEAD = "2026-10-12T10:00:00."

    def labelled(self, total):
        head = '{"product":"codex","label":"aaaaaaaaaaaaaaa1","status":"ok","asOf":"' + self.DATE_HEAD
        tail = 'Z"}'
        as_of = self.DATE_HEAD + "1" * _boundary(head, tail, total) + "Z"
        rec = {"product": "codex", "label": "aaaaaaaaaaaaaaa1", "status": "ok", "asOf": as_of}
        wire = head + "1" * _boundary(head, tail, total) + tail
        self.assertEqual(len(wire.encode("utf-8")), total)
        return rec, wire

    def unlabelled(self, total):
        plan = "max/team/x"
        head = '{"product":"codex","label":null,"status":"ok","plan":"' + plan + '","asOf":"' + self.DATE_HEAD
        tail = 'Z","retryUntil":null}'
        digits = "1" * _boundary(head, tail, total)
        rec = {"product": "codex", "label": None, "status": "ok", "plan": plan,
               "asOf": self.DATE_HEAD + digits + "Z", "retryUntil": None}
        return rec, head + digits + tail

    def measured(self, rec):
        out = accounts.validate_entry(rec)
        if out is None:
            return None
        out = dict(out)
        out.pop("days", None)
        return len(json.dumps(out, ensure_ascii=False, separators=(",", ":"), allow_nan=False).encode("utf-8"))

    def test_labelled_boundary(self):
        rec, wire = self.labelled(4096)
        self.assertEqual(self.measured(rec), 4096, "Linux мерит ровно ту строку, что собирает Swift-тест")
        self.assertIsNotNone(accounts.validate_entry(rec), "4096 байт метаданных — запись принята")
        rec, wire = self.labelled(4097)
        self.assertIsNone(accounts.validate_entry(rec), "4097 байт — запись отброшена")

    def test_unlabelled_slash_and_nulls_counted(self):
        rec, wire = self.unlabelled(4096)
        self.assertEqual(len(wire), 4096)
        self.assertEqual(self.measured(rec), 4096, "label:null и retryUntil:null считаются, «/» не экранируется")
        rec, wire = self.unlabelled(4097)
        self.assertIsNone(accounts.validate_entry(rec))

    def test_date_fields_counted_as_iso_strings(self):
        rec, _ = self.labelled(4096)
        out = accounts.validate_entry(rec)
        self.assertEqual(out["asOf"], rec["asOf"], "время хранится исходной ISO-строкой — она и считается")


# ---- C1-15 (minor): `updated` parsing — the Linux reference for the Swift parity check ------------------------------------
class TestC115UpdatedReference(unittest.TestCase):
    """Green guard. sync.merge parses `updated` with plain common.parse_iso: str.strip() (all Python whitespace, incl. \\n,
    \\t, \\x85, U+2028, U+3000) and no length limit — unlike account times (_epoch: _text(…, 4096) rejects Cc/Cf first).
    Swift (`RemoteLimitsWire.date` via text(limit: 4096) + trim .whitespaces) drops these files whole."""

    def file(self, mid, updated, **extra):
        obj = {"schema": 1, "machine": {"id": mid, "name": mid, "os": "T"}, "updated": updated, "days": {}}
        obj.update(extra)
        return json.dumps(obj)

    def merged(self, mid, updated, **extra):
        r = sync.merge({"machine-%s.json" % mid: self.file(mid, updated, **extra)}, "me", now=REF_NOW)
        return {m["id"]: m for m in r["machines"]}.get(mid)

    def test_whitespace_around_updated_is_stripped(self):
        for i, s in enumerate([UPDATED + "\n", "\t" + UPDATED, UPDATED + "\r\n", UPDATED + "\x85",
                               UPDATED + " ", "　" + UPDATED]):
            m = self.merged("w%d" % i, s)
            self.assertIsNotNone(m, "файл с updated=%r принят" % s)
            self.assertEqual(m["updated"], UPDATED_TS)

    def test_long_fraction_in_updated_is_parsed(self):
        s = "2026-10-12T10:00:00." + "1" * 5000 + "Z"
        m = self.merged("longfrac", s)
        self.assertIsNotNone(m, "у updated нет предела 4096 — файл принят")
        self.assertAlmostEqual(m["updated"], UPDATED_TS + 0.111, places=2)

    def test_unsafe_or_broken_updated_drops_the_file(self):
        for i, s in enumerate(["​" + UPDATED, UPDATED + "\x00", "2026-13-12T10:00:00Z", "yesterday", 123, None]):
            self.assertIsNone(self.merged("bad%d" % i, s), "updated=%r не разбирается → файл пропущен" % (s,))

    def test_account_and_last_seen_times_stay_strict(self):
        """Account times and lastSeenAt go through _epoch: a Cc char (\\n) drops the field; Zl (U+2028) is stripped."""
        recs = [{"product": "codex", "label": "aaaaaaaaaaaaaaa1", "status": "ok", "asOf": UPDATED + "\n"},
                {"product": "codex", "label": "aaaaaaaaaaaaaaa2", "status": "ok", "asOf": UPDATED + " "}]
        r = sync.merge({"machine-strict.json": self.file("strict", UPDATED, lastSeenAt=UPDATED + "\n", accounts=recs)},
                       "me", now=REF_NOW)
        m = {x["id"]: x for x in r["machines"]}["strict"]
        self.assertIsNone(m.get("lastSeenAt"), "lastSeenAt с \\n → нет (Cc отбрасывает поле целиком)")
        by = {a["label"]: a for a in m.get("accounts", [])}
        self.assertNotIn("asOf", by["aaaaaaaaaaaaaaa1"], "asOf с \\n → поле отброшено, запись жива")
        self.assertEqual(common.parse_iso(by["aaaaaaaaaaaaaaa2"]["asOf"]), UPDATED_TS, "asOf с U+2028 → разобран (strip)")


# ---- C1-16 (minor): integers on the wire — JSON 1.0 / 1e2 are not integers -------------------------------------------------
class TestC116IntegersReference(unittest.TestCase):
    """Green guard (Linux reference for the Swift legacyInteger fix): `type(n) is int` everywhere."""

    def test_schema_float_drops_the_file(self):
        for i, raw in enumerate(['1.0', '1e0']):
            text = '{"schema":%s,"machine":{"id":"f%d","name":"f","os":"T"},"days":{}}' % (raw, i)
            r = sync.merge({"machine-f%d.json" % i: text}, "me", now=REF_NOW)
            self.assertEqual(r["machines"], [], "schema %s — не целое, файл отвергнут" % raw)

    def test_float_counters_drop_the_model_entry(self):
        zeros = '"output":0,"cacheRead":0,"cacheWrite5m":0,"cacheWrite1h":0,"turns":1'
        text = ('{"schema":1,"machine":{"id":"cnt","name":"c","os":"T"},"days":{"claude":{"2026-10-12":{'
                '"m-float":{"input":5.0,' + zeros + '},"m-exp":{"input":1e2,' + zeros + '},'
                '"m-int":{"input":7,' + zeros + '}}}}}')
        r = sync.merge({"machine-cnt.json": text}, "me", now=REF_NOW)
        self.assertEqual(sorted(r["days"]["claude"]["2026-10-12"]), ["m-int"], "5.0 и 1e2 — не целые, модель пропущена")
        self.assertEqual(r["days"]["claude"]["2026-10-12"]["m-int"]["input"], 7)

    def test_float_reset_credits_and_interval_dropped(self):
        out = accounts.validate_entry({"product": "codex", "label": "aaaaaaaaaaaaaaa1", "status": "ok",
                                       "resetCredits": 2.0, "schedule": {"mode": "auto", "interval": 900.0}})
        self.assertNotIn("resetCredits", out)
        self.assertNotIn("schedule", out)


if __name__ == "__main__":
    unittest.main()
