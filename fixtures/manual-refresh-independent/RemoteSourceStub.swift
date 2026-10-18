// Test-bench stub (tester, 2026-10-18, C1 fix cycle 1). Since REMOTE-LIMITS C1, Sources/QuotaRefresh.swift has
// `LimitData.source: RemoteSource?`, and RemoteSource lives in Sources/RemoteLimits.swift next to app-only types
// (DayModelUsage, SyncRemoteCache, SyncPhase), which this independent harness must not compile.
// The harness never sets or reads `source`; an empty type is enough. run.sh adds this file ONLY when QuotaRefresh.swift
// does not declare RemoteSource itself (the review proposes moving it there) — never both, so no duplicate declaration.
struct RemoteSource {}
