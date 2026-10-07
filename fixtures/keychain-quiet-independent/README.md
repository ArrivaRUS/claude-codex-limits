# Independent KEYCHAIN-QUIET fixture

Pure core + independently authored fake dependencies; never link LimitsMonitor.swift or native adapters.
`SNAPSHOT2` enables the additional action/probe cases for the final implementation (the historical name is retained to preserve the exact tested fixture).

From the repository root, with a writable temporary output directory:

```sh
swiftc -D SNAPSHOT2 Sources/GitHubAuth.swift fixtures/keychain-quiet-independent/main.swift -o /tmp/ccl-quiet-independent
/tmp/ccl-quiet-independent
```

Final core58d68bea:30 PASS/0FAIL. Snapshot1:21PASS/2FAIL; cancel and unknown-probe regressions changed from FAIL to PASS. Runtime GitHubSync wiring, native helpers/ACL/UI and actual macOS13 are outside this fixture. Full evidence: docs/keychain-quiet-verification.md.
