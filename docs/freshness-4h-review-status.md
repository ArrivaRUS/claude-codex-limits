# FRESH-4H review status - 2026-10-05

Base d65df2dda14e09312e87b4d61b00417acda5a00f. Patch /private/tmp/ccl-freshness-0plsr745/freshness-4h.patch. Initial SHA256 8a87e8598463b1040dab66940551ddbcd3e9ae9b8a11a1cc9350045c700ef08c. Not integrated, installed or released.

Independent CodeReviewer Astra/high found three P2 issues:
1. Simple/tray treat expired session as active if weekly is still valid. Need per-metric validity.
2. Codex live failure disappears during fallback; UI cannot report failure/next attempt.
3. History.record timestamps after asOf, so recent_rate cutoff excludes newest observation.
DeveloperComplex Astra/high received all findings and regression scenarios for revision. Author 12 Python/63 Swift checks do not establish acceptance. Reviewer independently ran 12 Python tests and reproduced all three defects.

Separate Keychain diagnosis: SecurityAnalyst Astra/high confirmed V2 ensureAccess occurs before backoff, and timeout/denial permits repeated startup/sync/600s reads. This explains repeated prompts, not the first prompt. Expected ACL trusts /usr/bin/security, not all applications. Credentials are not recreated on every poll; different generations share the same service label. Actual user ACL/actions were not inspected. No credentials/keyring/API accessed. A separate fix should limit background interactive retries and provide explicit user recovery; do not mix auth changes into FRESH-4H.
