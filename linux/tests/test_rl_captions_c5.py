"""C5 captions: shared golden, hostile text and real reader presentation. Offline."""

if __package__:
    from . import _isolate  # noqa: F401
else:
    import _isolate  # noqa: F401

import argparse
import copy
import io
import json
from pathlib import Path
import unittest
from contextlib import redirect_stdout
from types import SimpleNamespace
from unittest import mock

from ccl import accounts, cli, common, limits, sync

FIXTURE = Path(__file__).resolve().parents[2] / "fixtures/remote-limits/captions-c5.json"
GOLDEN = json.loads(FIXTURE.read_text(encoding="utf-8"))
LABEL = GOLDEN["label"]
NOW = common.parse_iso(GOLDEN["now"])


def contents(machines):
    return {"machine-%s.json" % m["machine"]["id"]: json.dumps(m) for m in machines}


class CaptionsC5(unittest.TestCase):
    def setUp(self):
        clock = mock.patch.object(accounts.time, "time", return_value=NOW)
        clock.start()
        self.addCleanup(clock.stop)

    def test_c5_01_shared_golden_latest_and_reset_both_orders(self):
        for case in GOLDEN["cases"]:
            for machines in (case["machines"], list(reversed(case["machines"]))):
                with self.subTest(case=case["id"], first=machines[0]["machine"]["id"]):
                    remote = sync.merge(contents(machines), "other-linux", now=NOW)
                    expected = case["expected"]
                    self.assertEqual(remote.get("captions"), {LABEL: {k: expected[k] for k in ("text", "setAt")}})
                    self.assertEqual(accounts.caption_text(remote["captions"], LABEL, "Claude Code"), expected["display"])

    def test_c5_02_own_file_caption_participates_without_own_usage(self):
        case = copy.deepcopy(GOLDEN["cases"][1])
        case["machines"][1]["days"] = {"claude": {"2026-10-31": {"fixture": {"input": 7}}}}
        remote = sync.merge(contents(case["machines"]), "c5-linux", now=NOW)
        self.assertEqual([m["id"] for m in remote["machines"]], ["c5-mac"])
        self.assertEqual(remote.get("captions", {}).get(LABEL, {}).get("text"), "")
        self.assertEqual(remote["days"], {})

    def test_c5_03_reader_writer_share_cleanup_and_privacy(self):
        vectors = [("Cafe\u0301\n\u202e\x00\u2028\u2029", "Café"), ("x" * 40, "x" * 32),
                   ("e\u0301" * 32, "é" * 32), ("", "")]
        for source, expected in vectors:
            with self.subTest(source=repr(source)):
                value = {LABEL: {"text": source, "setAt": "2026-10-31T12:00:00Z"}}
                self.assertEqual(accounts.parse_block({"captions": value})["captions"][LABEL]["text"], expected)
                built = accounts.build(gist_id="synthetic", entries=[], unattributed_days={}, captions=value)
                self.assertEqual(built["captions"][LABEL]["text"], expected)
        for marker in ("@", "/", "\\", "＠", "／", "＼", "\ud800"):
            with self.subTest(marker=repr(marker)):
                # Marker beyond the limit must reject the WHOLE value before truncation.
                value = {LABEL: {"text": "x" * 40 + marker, "setAt": "2026-10-31T12:00:00Z"}}
                self.assertEqual(accounts.parse_block({"captions": value})["captions"], {})
                self.assertEqual(accounts.build(gist_id="synthetic", entries=[], unattributed_days={}, captions=value)["captions"], {})

    def test_c5_04_merge_ties_missing_times_invalid_values_and_no_mutation(self):
        values = [{"captions": {LABEL: {"text": text, **time}}} for text, time in (
            ("undated", {}), ("Я", {"setAt": "bad"}),
            ("A", {"setAt": "2026-10-31T12:00:00Z"}),
            ("Z", {"setAt": "2026-10-31T12:00:00Z"}),
            ("bad/path", {"setAt": "2026-10-31T13:00:00Z"}))]
        original = copy.deepcopy(values)
        expected = {LABEL: {"text": "Z", "setAt": "2026-10-31T12:00:00Z"}}
        self.assertEqual(accounts.merge_captions(values, now=NOW), expected)
        self.assertEqual(accounts.merge_captions(list(reversed(values)), now=NOW), expected)
        self.assertEqual(values, original)
        self.assertEqual(accounts.merge_captions([None, {"captions": []}]), {})
        # Unicode scalar order differs from UTF-16 order for these two values.
        scalar_tie = [{"captions": {LABEL: {"text": text}}} for text in ("\ufffd", "🚀")]
        self.assertEqual(accounts.merge_captions(scalar_tie)[LABEL]["text"], "🚀")

    def test_c5_08_future_caption_cannot_override_latest_valid(self):
        valid = {"captions": {LABEL: {"text": "valid", "setAt": "2026-10-31T14:01:00Z"}}}
        future = {"captions": {LABEL: {"text": "future", "setAt": "2026-10-31T14:01:01Z"}}}
        self.assertEqual(accounts.merge_captions([valid, future], now=NOW), valid["captions"])

    def test_c5_09_open_cycle_reads_own_caption_inline_raw_and_capped(self):
        case = GOLDEN["cases"][1]
        for mode in ("inline", "raw", "oversized"):
            with self.subTest(mode=mode):
                data = {"login": "synthetic", "gistId": "synthetic", "discoveredAt": NOW}
                st = mock.Mock()
                st.get.side_effect = lambda k, default=None: data.get(k, default)
                st.update.side_effect = lambda **kwargs: data.update(kwargs)
                files = {name: {"content": text} for name, text in contents(case["machines"]).items()}
                own = files["machine-c5-linux.json"]
                raw_body = own["content"].encode("utf-8")
                if mode != "inline":
                    own.update(content=None, truncated=True, raw_url="https://gist.githubusercontent.com/synthetic/raw/own")
                raw_response = (common.Resp(0, error=common.BODY_TOO_LARGE) if mode == "oversized"
                                else common.Resp(200, raw_body))
                gist_response = common.Resp(200, json.dumps({"public": False, "files": files}).encode("utf-8"))
                with mock.patch.object(sync, "sync_state", return_value=st), \
                     mock.patch.object(sync.auth.LinuxManifest, "read", return_value={}), \
                     mock.patch.object(sync, "ensure_access", return_value=SimpleNamespace(kind="ready", access="synthetic")), \
                     mock.patch.object(sync.vault, "active", return_value=("synthetic", "file")), \
                     mock.patch.object(sync, "gh", return_value=gist_response), \
                     mock.patch.object(sync, "_raw", return_value=raw_response) as raw, \
                     mock.patch.object(sync, "machine_file", return_value="{}"), \
                     mock.patch.object(common, "machine_id", return_value="c5-linux"), \
                     mock.patch.object(common, "write_json") as saved:
                    session = sync.open_cycle(auto=True)
                self.assertIsNotNone(session)
                expected = "Команда" if mode == "oversized" else ""
                self.assertEqual(session.remote.get("captions", {}).get(LABEL, {}).get("text"), expected)
                self.assertEqual([m["id"] for m in session.remote["machines"]], ["c5-mac"])
                self.assertEqual(session.remote["days"], {})
                saved.assert_called_once()
                if mode == "inline":
                    raw.assert_not_called()
                else:
                    raw.assert_called_once_with(own["raw_url"], cap=sync.MAX_MACHINE_BODY)
                self.assertEqual(session.result.partial, mode == "oversized")

    def test_c5_10_mac_caption_for_own_linux_account_without_mac_claude(self):
        machines = copy.deepcopy(GOLDEN["cases"][0]["machines"])
        machines[1]["accounts"] = [{"product": "codex", "label": None, "status": "signed_out", "days": {}}]
        remote = sync.merge(contents(machines), "c5-linux", now=NOW)
        self.assertEqual(remote.get("captionAccounts"), [{"product": "claude", "label": LABEL}])
        self.assertEqual(accounts.caption_lines(remote), ["Команда · " + LABEL])
        # Internal presentation metadata must never be put on the wire by the builder.
        self.assertNotIn("captionAccounts", accounts.build(gist_id="synthetic", entries=[], unattributed_days={}, captions={}))

    def test_c5_11_merged_cache_does_not_inherit_one_file_caption_cap(self):
        labels = ["%016x" % n for n in range(65)]
        remote = {"captionAccounts": [{"product": "claude", "label": label} for label in labels],
                  "captions": {label: {"text": "caption%d" % n} for n, label in enumerate(labels)}}
        lines = accounts.caption_lines(remote)
        self.assertEqual(len(lines), 65)
        self.assertIn("caption64 · " + labels[-1], lines)

    def test_c5_07_presentation_revalidates_cached_values_and_deduplicates(self):
        for case in GOLDEN["cases"]:
            with self.subTest(case=case["id"]):
                remote = sync.merge(contents(case["machines"]), "other-linux", now=NOW)
                self.assertEqual(accounts.caption_lines(remote), [case["expected"]["display"] + " · " + LABEL])
        hostile = {"machines": [{"accounts": [None, {"product": "bad", "label": LABEL},
                                               {"product": "claude", "label": "bad"},
                                               {"product": "claude", "label": LABEL}],
                                  "captions": {LABEL: {"text": "private/path"}}}]}
        self.assertEqual(accounts.caption_lines(hostile), ["Claude Code · " + LABEL])

    def test_c5_05_status_cached_and_online_uses_merged_caption(self):
        for case in GOLDEN["cases"]:
            remote = sync.merge(contents(case["machines"]), "other-linux", now=NOW)
            for online in (False, True, "truncated-latest", "all-truncated"):
                with self.subTest(case=case["id"], online=online):
                    # Status must not touch credential adapters, timers, systemctl or real files.
                    st = mock.Mock()
                    data = {"login": "synthetic", "gistId": "synthetic"}
                    st.get.side_effect = lambda k, default=None: data.get(k, default)
                    files = {name: {"content": value} for name, value in contents(case["machines"]).items()}
                    for machine in case["machines"]:
                        latest = machine["captions"][LABEL]["setAt"] == case["expected"]["setAt"]
                        if online == "all-truncated" or (online == "truncated-latest" and latest):
                            files["machine-%s.json" % machine["machine"]["id"]] = {
                                "content": None, "truncated": True,
                                "raw_url": "https://gist.githubusercontent.com/synthetic/raw/caption"}
                    response = SimpleNamespace(status=200, json=lambda: {"files": files})
                    with mock.patch.object(sync, "sync_state", return_value=st), \
                         mock.patch.object(sync, "ensure_access", return_value=SimpleNamespace(kind="ready", access="synthetic", ref={}, reason=None)), \
                         mock.patch.object(sync, "gh", return_value=response if online else SimpleNamespace(status=0)), \
                         mock.patch.object(sync, "load_remote", return_value=remote), \
                         mock.patch.object(sync, "sign_out_incomplete", return_value=False), \
                         mock.patch.object(sync, "warning", return_value=None), \
                         mock.patch.object(cli.vault, "publisher_secret_service", return_value=False), \
                         mock.patch.object(cli.vault, "publisher_leftover_copy", return_value=False), \
                         mock.patch.object(cli, "_say_o2"), mock.patch.object(cli, "_timer_status", return_value="off"), \
                         mock.patch.object(common, "machine_id", return_value="other-linux"), \
                         mock.patch.object(common, "machine_name", return_value="synthetic"), \
                         mock.patch.object(common, "os_name", return_value="Linux fixture"), \
                         mock.patch.object(cli.usage, "load_index", return_value={"files": {}}), \
                         mock.patch.object(sync.time, "time", return_value=NOW), redirect_stdout(io.StringIO()) as output:
                        self.assertEqual(cli.cmd_status(argparse.Namespace()), 0)
                    self.assertIn("  • " + case["expected"]["display"] + " · " + LABEL, output.getvalue())
                    if case["id"] == "reset":
                        self.assertNotIn("Команда", output.getvalue())

    def test_c5_06_tray_tooltip_uses_merged_caption_and_reset(self):
        try:
            from ccl.gui import trayicon
        except ModuleNotFoundError as error:
            if error.name == "PyQt5" or error.name.startswith("PyQt5."):
                self.skipTest("PyQt5 not installed")
            raise
        for case in GOLDEN["cases"]:
            remote = sync.merge(contents(case["machines"]), "other-linux", now=NOW)
            tooltip = trayicon.tooltip(limits.LimitData(), limits.LimitData(), remote=remote)
            self.assertIn(case["expected"]["display"] + " · " + LABEL, tooltip)
            if case["id"] == "reset":
                self.assertNotIn("Команда", tooltip)


if __name__ == "__main__":
    unittest.main()
