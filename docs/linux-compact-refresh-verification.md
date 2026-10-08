# Linux0.4.5 — приёмка

Status: implementation and independent tests in progress. Base53bb5bfa8004876b9baf5bcb3766875a6d539302; plan a1bfb05 committed before code.

## Baseline evidence

Existing Linux CI [37723616264](https://github.com/ArrivaRUS/claude-codex-limits/actions/runs/37723616264) succeeded at1078ddbe058196204265a0bc565ff591cb8ca45c (Linux0.4.4). Its192PNG downloaded for visual reference to /private/tmp/ccl-linux-baseline-57m2zmw1. This is not validation of new0.4.5 code. Prior release linux-v0.4.4 has a DEB asset with SHA2565dc4a6b95e1780e36ee16fa7f4bc4eda21d4a4eaaf83a0f212527a00fc9c1ca5.

## Boundaries

Scope includes existing accepted manual-refresh contract; DeveloperComplex handles provider admission/results and retry metadata, with CodeReviewer and SecurityAnalyst before runtime. Underlying Auto progression/endpoints/credential stores remain. CodeReviewer must confirm no security surface and exactCI isolation before execution. ExistingCI uses dedicated synthetic home, no network exceptloopback, nohostmounts/sessionbus/credentials, offscreenPyQt; fullsuite must have0skips. CI evidence/DEB will be downloaded for QA and independent design review. LiveALSE/KDE/Fly, userkeyring and actual remoteinstallation are not established by container tests. No realusercredentials/logs/API during tests.

Publication: linux-v0.4.5 with verifiedDEB, --latest=false. LatestmacOS remainsv3.2.7. No packageinstallation on thisMac is intended.
