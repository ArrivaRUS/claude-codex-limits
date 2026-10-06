# FRESH-4H / KEYCHAIN-RETRY — verification

Date: 2026-10-06. Source commit: `bd16d9c8e3296cd752784e61d9d456071c7bd2a6`.
Released versions: macOS 3.2.4, Linux 0.4.4. Packaging accepted; published and locally installed on2026-10-06. macOS build commit: `4a5c3724ae348b09b01d684d03e75b3876aef251`.

## Accepted source

Independent CodeReviewer and SecurityAnalyst reviewed the final source and closed the reported P1/P2 findings. Freshness, auth and reset are independent; pace uses the observation timestamp. Keychain access failures use a process-local monotonic 600-second cooldown; successful reads cannot prove whether a native prompt was shown. Actual ACL and the first prompt's cause were not diagnosed. Live credentials/API were not used by tests.

Exact SHA256 inputs:
- LimitsMonitor.swift: `f09cb90d973152784882661b209ecd2e0cb48402c0d1455994692f129c31bea9`
- GitHubAuth.swift: `91dcaf5edefd8a3bd206f1b5aad1330b4b07eed48c3e9c8d1868b18bfa1937b2`
- GitHubAuthSelfTests.swift: `ad580772b0ed36cbfc8a0298287a55e20877af5c702acd1c9f99532f56606902`

## Executed checks

- Final pure auth suite: 30,927 checks, 0 failures, synthetic dependencies.
- Final Swift freshness harness: 105 checks, 0 failures.
- Final revoked-cleanup fake regression: 130 checks, 0 failures.
- Deadline fake scheduler: 28 checks, 0 failures; policy unchanged in final candidate.
- Linux CI [37358004109](https://github.com/ArrivaRUS/claude-codex-limits/actions/runs/37358004109): 306 tests PASS, no skips. Disposable container, synthetic account, network disabled except loopback; DEB built only after successful tests.
- Earlier CI 37356154148 failed five tests. Both actual Simple auth-recovery failures were fixed in production; three preview-path failures were fixed in CI. No assertions were removed.
- Swift build/ad-hoc signing passed. DMG created with native disk-image service after the sandbox blocked hdiutil.
- Final source native QA: 1401 checks, 0 failures, 214 PNG; 38 critical images inspected. QA found packaged minos26 while claiming13. Explicit target13 now compiles successfully with no availability errors; actual rebuilt executable reports minos13.0. Independent rebuilt DMG checks PASS: readonly image, integrity, strict ad-hoc signature, version3.2.4/minos13.0; all17 mounted files match dist. Mounted executable --subscriptions-selftest:1401 checks/0 failures,214PNG. Binary SHA256:85343088cc4c71da661aa27cb7c288a376181c38b3501b2ff8fe43d9e2d0508c. QA artifacts: /private/tmp/ccl-qa-package13-fie9g50u; previous final-source visual report: /private/tmp/ccl-qa-final-4nyx2r37/REPORT.md.

## Package hashes

- DMG: `72b6dcbee55eb565fa85a48d827408c96410f6e04dbe3bb8365c1470d206db37`
- DEB: `5dc4a6b95e1780e36ee16fa7f4bc4eda21d4a4eaaf83a0f212527a00fc9c1ca5`

## Limits

No actual macOS13 runtime, live ALSE session, real provider API, real Keychain prompt/ACL, sleep/wake soak or native child termination was exercised. System scheduling and connectivity can delay a successful update. A P3 spacing issue in Russian Simple with two subscriptions is tracked separately; it does not hide values or actions.

## Publication and installation

Выпущено 2026-10-06: [macOS3.2.4](https://github.com/ArrivaRUS/claude-codex-limits/releases/tag/v3.2.4) на4a5c372 и [Linux0.4.4](https://github.com/ArrivaRUS/claude-codex-limits/releases/tag/linux-v0.4.4) наbd16d9c. Публичные DMG/DEB скачаны и SHA совпали; Latest=v3.2.4. На этом Mac установлен3.2.4 в /Applications, подпись и binary SHA проверены, PID29719 запущен. Резервная3.2.3: /private/tmp/ccl-install-backup-_eivvisr/Claude Codex Limits.app.

Native Gatekeeper notarization is not provided: signature remains ad-hoc. This release does not claim removal of the first security prompt. Local normal launch was performed only as the requested installation step, after isolated QA; no live credential contents were inspected.
