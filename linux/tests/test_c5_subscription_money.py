"""C5-22/23: offline reader ownership and agreed 6.1 price; no publisher/account IO."""
if __package__:
    from . import _isolate  # noqa: F401
else:
    import _isolate  # noqa: F401

import copy
import unittest
from ccl import accounts, usage


class SubscriptionMoneyTests(unittest.TestCase):
    def test_sol_61_all_prices_and_unknown(self):
        self.assertEqual(usage.model_price("gpt-6.1-sol-2026-09-29"), (2, 10, .1, 2.5))
        for field, price in (("input", 2), ("output", 10), ("cacheRead", .1), ("cacheWrite5m", 2.5)):
            self.assertAlmostEqual(usage.api_cost("gpt-6.1-sol", {field: 1_000_000}), price)
        self.assertIsNone(usage.api_cost("unknown-c523", {"input": 1_000_000}))

    def test_reader_attributes_per_machine_and_product_all_statuses(self):
        days = {"2026-10-30": {"gpt-6.1-sol": {"input": 1_000_000, "turns": 1}}}
        for status in ("ok", "signed_out", "expired", "error", "rate_limited"):
            for count in (0, 1, 2):
                with self.subTest(status=status, count=count):
                    entries = [{"product": "codex", "label": str(n + 1) * 16, "status": status, "days": {}}
                               for n in range(count)]
                    # Another product must not make a singleton Codex ambiguous.
                    entries.append({"product": "claude", "label": "a" * 16, "status": "signed_out", "days": {}})
                    obj = {"accounts": entries, "days": {"codex": days}, "unattributedDays": {"codex": days}}
                    original = copy.deepcopy(obj)
                    block = accounts.parse_block(obj)
                    self.assertEqual(obj, original)
                    other = block["unattributedDays"].get("codex", {})
                    self.assertEqual(bool(other), count != 1)
                    sources = [{"codex": other}] + [{a["product"]: a["days"]} for a in block["accounts"]]
                    merged = usage.merge_days(*sources)
                    self.assertEqual(merged["codex"]["2026-10-30"]["gpt-6.1-sol"]["input"], 1_000_000)

    def test_null_label_cannot_claim_subscription(self):
        days = {"2026-10-30": {"unknown": {"input": 5}}}
        block = accounts.parse_block({"accounts": [{"product": "codex", "label": None,
            "labelReason": "no_login", "status": "signed_out", "days": {}}],
            "days": {"codex": days}, "unattributedDays": {"codex": days}})
        self.assertTrue(block["unattributedDays"]["codex"])

    def test_truncated_account_list_never_proves_singleton(self):
        entries = [{"product": "claude", "label": format(n, "016x"), "status": "signed_out", "days": {}}
                   for n in range(7)]
        entries += [{"product": "codex", "label": label, "status": "signed_out", "days": {}}
                    for label in ("a" * 16, "b" * 16)]
        days = {"2026-10-30": {"gpt-6.1-sol": {"input": 5}}}
        block = accounts.parse_block({"accounts": entries, "days": {"codex": days},
                                      "unattributedDays": {"codex": days}})
        self.assertTrue(block["unattributedDays"]["codex"])
        self.assertFalse(any(a["days"] for a in block["accounts"]))
