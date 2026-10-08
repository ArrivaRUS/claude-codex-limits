# COMPACT-REFRESH 3.2.7 — acceptance

Status: final source a60319 accepted by independent production/isolation, packaged QA and design review. Published and installed as macOS3.2.7; public/installed checks passed. Earlier candidates below are historical. User rejected 3.2.6 composition. Accepted layout: [UX](compact-refresh-ux.md).

- HEAD at freeze: 9fb6738f4ceed711d9c3c2f632830fa1ff748c4a, uncommitted UI/docs.
- Snapshot: /private/tmp/ccl-compact-review-sg_4o6_v.
- main SHA256: 620a3c7a6bb973caccc77c64992cced64fd2e74a061fa9bf179014ad4e27ebd5.
- Pure QuotaRefresh unchanged: b118084f80c26a4c86fe24417b3c5dd229ff14f686906b974feeea8af717e41b. GitHub auth/selftest also byte-identical. Previous pure test result applies to those unchanged inputs, no new run claimed.
- arm64/macOS13 compilation exit0; ad-hoc codesign PASS. Default compiler cache sandbox denial fixed by temporary module-cache configuration; hdiutil required approved external execution. No source change for either environment issue.
- DMG SHA256: 4e44fed30171859ee94349b597356b8f4d635805a45111df43c4096e83409491.
- Packaged executable SHA256: 8c30d72bf7704085e737438b04dd1a8cb1c90d8700c005dba22cb0d7cd63bbd0.
- Runtime not yet approved. 52 synthetic UI fixtures are expected, not yet executed. CodeReviewer will review exact single --subscriptions-selftest before QA.
- Native ACL/liveAPI/user logs/credentials are excluded from tests. DesignReviewer separately compares actual PNGs to the accepted reference; passing geometry alone is insufficient.
- Publication and installation pending; installed app remains3.2.6.

Secret scan: one known false positive at LimitsMonitor.swift:535, a function call to codexAccessToken (not a literal secret). Verified exact unchanged line; no other matches. Scanner rules remain unchanged.

## First packaged QA (620a)

CodeReviewer isolation PASS for the exact single --subscriptions-selftest. QA executed that packaged binary once: exit1 after3162 OK at legacy Auth-hints recovery-card boundary assertion. All52 new manual-refresh PNGs were generated beforehand. Log/images: /private/tmp/ccl-qa-compact-sj4iir47. Existing assertion still subtracts removed38pt header; DesignEngineer assigned to verify and repair the oracle without dropping the assertion. This candidate is not accepted for release.

Package verification:17/17files identical, strict codesign PASS, version3.2.7, arm64/minOS13, read-only mount CRC343D2A23; detached. These checks do not imply full runtime PASS. DesignReviewer examines the52 authentic images of620a while the legacy assertion is repaired.

## Review findings on620a

CodeReviewer P2: Simple local-cooldown fallback repeats old retry/error under rings plus new footer; fix presentation only. Legacy Auth boundary oracle still subtracts38pt; Simple test/UX rectangle typo152/192 corrected to original158/186.

Independent DesignReviewer viewed all52 actual PNGs: no new P1; two further P2: enabled-but-missing Claude silently disappears in Simple; fresh-success Advanced snapshot notice incorrectly uses warning amber. Author assigned bounded UI corrections before next freeze. Overall design acceptance pending.

## Latest user-approved scope and freeze a60319

User additionally requested a manual4h option, simultaneous Auto+effective-interval highlighting, removal of the separate frequency label, and removal of the snapshot annotation and its empty height. No Auto algorithm, network or auth changes. UX and code tests updated.

Final compiled candidate main a60319d3ab89a90b53bdb1c68e0503a8febac54b8e4c36713a1fa919d4f518d9; snapshot /private/tmp/ccl-compact-review-3_q3bq64. Previous P2 and old-oracle fixes retained. Compile/strict sign PASS; no runtime yet. DMG4b5a8ca3403bcc9d3e06b592d4270a441c817f2702c4f5a86ab897afa64c79ac, binary978f1aece62a8e1c8b5bfd9ad1d2d04e2420d2840711e9e415b3c5823c7d8a81.

## Final isolation review a60319

Independent CodeReviewer (Astra/high) returned ISOLATION PASS for the sole `--subscriptions-selftest` argument and exact binary978f1aec. RAM preferences and synthetic fixtures; native interval callbacks are not invoked; exit precedes normal app startup. Permitted I/O: app resources, synthetic temporary files/PNGs. No reachable API/Keychain/helper/credentials/user-log effects found. QA authorized for one packaged run. Previous QA agent403 was an infrastructure interruption; resumed with the same approved role and model after laptop wake.

## Final production review a60319

Independent CodeReviewer (Astra/high): PASS, no P1/P2; previous duplicate-status/missing-card and geometric oracle findings closed. Manual14400 round-trip, actual enabled-provider Auto highlighting, removed snapshot line/height, action target priority and existing callbacks confirmed statically. Transport/auth/QuotaRefresh/Auto algorithm/AppDelegate unchanged; no new security surface. Minor: for readInteractionRequired during local cooldown the countdown appears only in the tooltip, not the card; admission is unaffected. Keyboard/VoiceOver and visuals are not claimed by this static review.

## Final packaged QA a60319

Independent QA (Sol6.1/high) executed the approved packaged binary once: exit0, 5089 OK, no failed assertions. New images:314 total, including52 manual-refresh,88 Auto/fixed/off and120 auth fixtures. Log, image manifest and package evidence: `/private/tmp/ccl-qa-final-bse2hhmw/REPORT.md`. No separate footer-only PNGs were generated; full-panel actual PNGs contain the schedule row.

Package PASS: all17 regular files identical across mounted/frozen/copied bundles, version/build3.2.7, arm64, plist/LC_BUILD_VERSION minimum macOS13.0, strict codesign. Read-only mount detached. DMG4b5a8ca3403bcc9d3e06b592d4270a441c817f2702c4f5a86ab897afa64c79ac; executable978f1aece62a8e1c8b5bfd9ad1d2d04e2420d2840711e9e415b3c5823c7d8a81. No real credentials/API/Keychain/user logs, ordinary startup or actual native click callbacks were used during tests. Native keyboard/VoiceOver/live-account behavior not tested.

Representative actual synthetic images saved in this repository: [Auto4h](compact-refresh-auto4h-ru.png), [manual success](compact-refresh-success-ru.png). These are fixtures, not the user's account data. Independent visual acceptance remains separate from geometry/package assertions.

Independent CodeReviewer doc consistency PASS for README RU/EN, project guide, release notes and prepared release body. Clarified plural enabled-provider intervals in the release body as suggested. No P1/P2.

## Final independent design acceptance a60319

DesignReviewer (Sol6.1/high): FINAL PASS, no P1/P2. Viewed all52 Manual and88 Auto/Fixed/Off plus8 affected Auth PNGs; all314 hashes match QA manifest. Unified gradient/radii, header refresh and compact card feedback accepted against reference/UX; no external strips/list, clipping or overlaps. Previous missing-provider/duplicate-error P2 closed; snapshot line and excess height absent. RU/EN, Simple/Advanced, one/two/off, manual4h and Auto A+actual15/30/60/240 accepted. Full frames reviewed (no footer-only crops); tooltip/native focus/hit targets not proven by PNGs. Unchanged full Auth120 not re-reviewed. Source hash still a60319.

## Publication and installation · 2026-10-08

Released [v3.2.7](https://github.com/ArrivaRUS/claude-codex-limits/releases/tag/v3.2.7) from source commit `1078ddbe058196204265a0bc565ff591cb8ca45c`; GitHub Latest=v3.2.7. Public DMG downloaded independently and SHA256 matches accepted4b5a8ca3403bcc9d3e06b592d4270a441c817f2702c4f5a86ab897afa64c79ac; API asset digest agrees and state=uploaded. Linux remains0.4.4.

Installed `/Applications/Claude Codex Limits.app`, version/build3.2.7, binary978f1aece62a8e1c8b5bfd9ad1d2d04e2420d2840711e9e415b3c5823c7d8a81, strict codesign PASS. Previous canonical PID96073 stopped normally; new canonical PID15393 verified running. Normal launch was the authorized installation step, not part of synthetic tests. Previous3.2.6 bundle retained at `/private/tmp/ccl-install-backup-rvyytyw6/Claude Codex Limits.app`.

Receipts: `/private/tmp/ccl-installed-3.2.7-verified.json`, `/private/tmp/ccl-public-3.2.7-verified.json`, `/private/tmp/ccl-install-3.2.7-receipt.json`. No app credentials or account files read for installation verification. Coordinator performed integration/docs/package/release/install; substantial implementation and independent reviews stayed with approved roles.
