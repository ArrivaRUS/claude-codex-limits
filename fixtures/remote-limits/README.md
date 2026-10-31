# REMOTE-LIMITS — golden fixtures (contract v1.1)

Shared by Linux tests (`linux/tests/test_rl_contract.py`) and the future Swift selftests (C1). Synthetic only: no real
account, token, e-mail or host. Spec: `arch/plan-synth.md` §A/§B, test plan `docs/test-plan-remote-limits.md`.

| File | Purpose |
|---|---|
| `machine-v11.json` | valid machine file v1.1 (example of synth §A; labels = HMAC under `fixturegist…0001`) |
| `machine-v11-c2.json` | C2 selftests (`Sources/RemoteLimitsC2SelfTests.swift`): vps file, `machine.id` is a UUID; at `2026-10-12T10:20:00Z` — Claude `f4b718320ee15b3a` Max 20x fresh (V5 1, asOf 10:15:02), Codex A `f683db167afc0b47` expired (3), Codex B `c2b0000000000b02` rate_limited until 11:14 (4), Codex C `c2c0000000000c03` fresh (hidden by the reader); root `days` = Σ `accounts[].days` |
| `machine-v10.json` | the same file as an old writer would produce (no `accounts`/`unattributedDays`/`captions`/`lastSeenAt`) |
| `machine-v11-hostile.json` | strict JSON; each `accounts[]` record has `_case` naming the C7 rule it breaks |
| `machine-v11-nonfinite.json` | **not strict JSON** (`NaN`, `Infinity`, `1e400`): Python `json` accepts it, so `isfinite` is mandatory. Swift `JSONSerialization` rejects the whole file — C1 must expect that |
| `machine-v11-surrogate.json` | ASCII-only file whose `\ud800` escapes decode to **lone surrogates** in `machine.name/os/app`, `tz`, product/day/model keys of `days` (N1/M2, A1-16). Edit with care: re-saving through a UTF-8 editor that decodes escapes makes the file invalid |
| `label-vectors.json` | HMAC label vectors (normalisation, gist key, product domain) |
| `sanitize-vectors.json` | `machine_tag` and caption vectors |
| `c3-malicious.json` | C3-11 literal/hostile text; safe format markers are accepted literally. C5 caption cleaning/refusal is checked separately from strict model/envelope validation; `%@` is a separate rejected caption vector in the selftest. |
| `decide-vectors.json` | A3-01 golden vectors for `coordination.decide` (synth §D, T1 П7): epoch seconds, non-numbers = absent; shared with Swift C4-04 |
| `pii-sentinels.json` | synthetic PII; token-like sentinels are split into parts and joined at run time (secret scanners stay quiet) |

Regenerate: none — files are hand-reviewed goldens; change only together with the contract.
