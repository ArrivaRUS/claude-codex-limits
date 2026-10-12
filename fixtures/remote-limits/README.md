# REMOTE-LIMITS — golden fixtures (contract v1.1)

Shared by Linux tests (`linux/tests/test_rl_contract.py`) and the future Swift selftests (C1). Synthetic only: no real
account, token, e-mail or host. Spec: `arch/plan-synth.md` §A/§B, test plan `docs/test-plan-remote-limits.md`.

| File | Purpose |
|---|---|
| `machine-v11.json` | valid machine file v1.1 (example of synth §A; labels = HMAC under `fixturegist…0001`) |
| `machine-v10.json` | the same file as an old writer would produce (no `accounts`/`unattributedDays`/`captions`/`lastSeenAt`) |
| `machine-v11-hostile.json` | strict JSON; each `accounts[]` record has `_case` naming the C7 rule it breaks |
| `machine-v11-nonfinite.json` | **not strict JSON** (`NaN`, `Infinity`, `1e400`): Python `json` accepts it, so `isfinite` is mandatory. Swift `JSONSerialization` rejects the whole file — C1 must expect that |
| `machine-v11-surrogate.json` | ASCII-only file whose `\ud800` escapes decode to **lone surrogates** in `machine.name/os/app`, `tz`, product/day/model keys of `days` (N1/M2, A1-16). Edit with care: re-saving through a UTF-8 editor that decodes escapes makes the file invalid |
| `label-vectors.json` | HMAC label vectors (normalisation, gist key, product domain) |
| `sanitize-vectors.json` | `machine_tag` and caption vectors |
| `pii-sentinels.json` | synthetic PII; token-like sentinels are split into parts and joined at run time (secret scanners stay quiet) |

Regenerate: none — files are hand-reviewed goldens; change only together with the contract.
