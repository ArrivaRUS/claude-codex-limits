# Independent MANUAL-REFRESH fixtures — 78 scenarios passed

Only `Sources/QuotaRefresh.swift` and `ManualRefreshIndependent.swift` are compiled.
No application, embedded author selftests, API, Keychain, credentials, user logs,
production defaults, transport, processes, or threads are invoked by Swift code.
Foundation date constructors use fixed epoch values; DateFormatter parses synthetic
strings with an explicit reference time. There is no wall-clock `Date()` call.
Recording dependencies are memory-only and call actual admission/completion APIs.

## Frozen inputs submitted for isolation review

- Git HEAD: `189a60d19edfbd9fb2ace659d392ca9258ab541a` (uncommitted shared-tree changes).
- Production pure source SHA-256:
  `b118084f80c26a4c86fe24417b3c5dd229ff14f686906b974feeea8af717e41b`.
- Independent harness SHA-256:
  `8aea790e19f539c07cccf2faa6526dbf1fedbfaaf22a040f0f03361bb4566350`.
- The coordinator must also review/fingerprint `run.sh`; no execution approval for
  an earlier source SHA is represented as approval for these inputs.

Command from the repository root with the durable runner:

```sh
sh fixtures/manual-refresh-independent/run.sh
```

After exact source/harness/runner isolation approval, the current batch passed:
**78 scenarios / 1089 assertions / 0 failures**, exit 0, on 2026-10-07.
Runner SHA: `6e5c67f6cf8a7054cc0f280f227bfa1c529b2c090511de4ec0a1e01f0b3d5e0d`.
Artifacts: `/private/tmp/ccl-manual-refresh-independent-run.5qrJeA`.
The historical **65/875/0** and **43/454/0** results below belong to earlier inputs.

The runner derives an absolute repository root from its own directory via `../..`,
with quoted paths, CDPATH disabled for that cd, and physical pwd. It copies those
two inputs to a new `/private/tmp` directory and verifies
their exact SHA before invoking the compiler. A changed input aborts before compile.
It supplies temporary HOME/TMPDIR/module-cache paths to the compiler and temporary
HOME/TMPDIR to the binary. It does not use application build scripts or link any
production entry point. HOME is supplementary containment; isolation relies on the
reviewed sources having no credential/network/store/log/app execution paths.
The runner launches the system compiler and the standalone harness only; outputs
remain in its printed temporary directory. Runtime dependencies are Foundation and
the Swift standard library, without credential values or external dependencies.

## Contract checks

- Manual before 900 s, manual past local/error schedule, exact 30 s guard,
  scheduled not-due and deduplication while in-flight.
- Independent provider state, busy/free/disabled, partial completion acceptance,
  target-only dependency request recording.
- Server Retry-After exact boundaries, full long waits, invalid/unknown values,
  finite arithmetic overflow, all HTTP-date formats, case-insensitive headers.
- Request identity, foreign/duplicate/late callbacks, disable/re-enable fencing.
  Confirmed T2 P2 regression: selection invalidates UI publication but a valid
  server deadline survives, blocking manual before expiry, including completion
  while disabled. A duplicate cannot clear a newer accepted request's restriction.
- `quotaFallback`: fresh response with unchanged percentages/reset preserves fresh
  success/new asOf; failure keeps old percentages/reset/scoped/plan/credits and
  original/nil asOf while carrying current auth/error/server restriction.
- RU/EN feedback dataAt vs nextAutomaticAt, pending/local/server/unknown wait,
  explicit recovery vs network/stale/missing, auth recovery alongside server ban,
  countdown huge bounds and subsecond rounding.
- HTTP 401 and token endpoint invalid_grant retain Retry-After in the pure
  metadata/state chain. Real Claude adapter forwarding remains untested.
- Incremental P2 calls `quotaSelectSnapshot` itself: known zero/partial readings
  survive empty failure even with two nil dates; apiFresh wins; populated snapshots
  prefer known times, and two populated undated snapshots keep candidate values/nil.
- Incremental P1 calls the real pure permit/parser/policy: one-shot admission,
  cancellation, fixed expiry, failed launch consumption; interactive-write parsing
  rejection and independent policy rejection even with a read permit; UI-off before
  any synthetic RPC and zero RPC on failed configuration. Recording closures only
  mutate memory; no native helper is invoked. NSLock synchronizes the pure permit,
  without threads or reentrant calls from closures.
- RU/EN credential issues distinguish explicit allow/cancel permission from
  ordinary refresh and write recovery. Real credential adapter and permit creation
  context, actual cancellation/kill, pipes, and native policy remain review/QA gaps.
- New pending credential batch calls `quotaReconcilePendingCredential` with only
  memory closures and synthetic JSON. It covers rotation/write failure → read
  permission required → explicit permitted read finds new CLI login, retirement
  without stale overwrite, already-candidate, repeated reads, unknown/corrupt/missing/
  timeout retention, pre/post-read cancellation, and independently quiet writes.
- Semantic identity checks vary JSON ordering and unrelated metadata while keeping
  access+refresh constant. Same-old identity retries retained candidate, preserving
  current metadata and exact-current compare bytes; write failure retains pending
  and does not return old credentials. Same-candidate identity needs no update.
  A changed access or refresh component is separately checked as a distinct login.
- Effect counts describe calls to the injected read/update closures. The pure API
  has no OAuth callback; that fact is not a runtime proof that the actual fetch
  caller avoids a second OAuth request. Actual orchestration wiring remains review-only.

Detailed scope/gaps: [test plan](../../docs/test-plan-manual-refresh.md).
Pure reducer/projection acceptance does not prove immediate UI publication,
UI routing, persisted Auto mode, native prompt policy, full-cycle provider flight,
main-thread cache serialization, or actual adapters. No app/native tests are run.

## Actual verification so far

Incremental run, 2026-10-07: exact command `sh fixtures/manual-refresh-independent/run.sh`
from `/private/tmp/ccl-manual-refresh.qMuRQa`, command exit 0. Both copied inputs
passed SHA guards before compilation. Post-run live source/harness/runner and
copied-input fingerprints matched that run's approved source
`0cb916e6c9f161ba010f34a9dee31acf96c91538427884a2f049db922e87706d`, harness
`5af1e7bd789382cc27bdd01bf90d00e89b0e09bbae11c81e6022737654e3ae83`, runner
`e8ca809ed76ea03731b51fe93f06e2548c1a82f5fce3b5b434515c979f903c9d`. Compared with the
historical run, 22 scenarios and 421 assertions were added; all passed.

```text
MANUAL_REFRESH_INDEPENDENT scenarios=65 assertions=875 failures=0
```

Artifacts: `/private/tmp/ccl-manual-refresh-independent-run.eIeFDq`.
Binary SHA-256: `e83c044159c809e1ced53c94d3daaa568586a5e3e5acbd38ea29ee06e7dd00c5`.
HEAD: `189a60d19edfbd9fb2ace659d392ca9258ab541a`, with uncommitted shared-tree changes.
Toolchain FSEvents/confstr cache warnings appeared again; compile/runtime completed
with exit 0. No application/native helper was launched. After this run, only the
fixture README and test-plan were edited to record evidence; Swift inputs and
runner did not change. Pure tests do not prove native helper/pipes/ACL/click wiring.

Historical standalone run: **43 scenarios / 454 assertions / 0 failures**, command exit 0.
Its source SHA was `76b66aa05e6eb67af057c7a99744e645df1ca665900dfb35f0d75c6e39e3e6af`
and harness SHA was `bb1b1e826fb281d3c66f3684066c7f485ee97d7cf1d4ce706e26239a2ffab2ae`.
The exact command executed on 2026-10-07 was
`/bin/sh /private/tmp/ccl-manual-refresh.qMuRQa/fixtures/manual-refresh-independent/run.sh`,
using runner SHA `eb70330cab4274bcca67c72cb06126d12110bb0a4875bd584f5bae0964af39b1`
before the later root-path change.
Both copied inputs passed the runner's SHA checks before compile. Compilation succeeded;
the resulting standalone binary ran without application code. Post-run live source,
harness, runner and copied-input fingerprints still matched that historical pair.

Artifacts: `/private/tmp/ccl-manual-refresh-independent-run.drtyfP`.
Binary SHA-256: `a6783c38ab867b8341ccdf30891e31f074453b6a6d4cffc3ac6951effd5d544c`.
The compiler's xcrun/xcodebuild setup printed FSEvents/confstr cache warnings and
used its fallback cache location; these did not prevent compile/run or change exit 0.
No application/native runtime was approved or executed. Actual summary:

```text
MANUAL_REFRESH_INDEPENDENT scenarios=43 assertions=454 failures=0
```

An attempted freeze of the before-fix source captured the already fixed source:
`/private/tmp/ccl-manual-refresh-independent-baseline.N8T7rZ/QuotaRefresh.swift`,
SHA `2046d82478ab21c7889d09b36c3d973dd25ae64b2a1e6c4d47bc68aac8ceedde`.
It is not a before-fix baseline; no baseline FAIL is claimed. Current source also
adds the snapshot reducer and auth action projection. Source changed during drafting;
only the full fingerprints above identify the submitted test pair.

After that run, the coordinator requested the durable root-path change in run.sh.
Only root derivation changed; fixed SHA input guards and the Swift sources are
unchanged. `/bin/sh -n fixtures/manual-refresh-independent/run.sh` checked syntax
only; tests were not rerun. The 43/454/0 result belongs to the recorded earlier
runner/input fingerprints, not an execution of the revised runner. README and
test-plan were also updated after the run to record this distinction.

Subsequently, the coordinator assigned the selector P2 and quiet-read P1 regression
increment. Source, harness and runner input guards differ from the historical run;
the incremental 65/875/0 run above followed explicit approval of the full new
fingerprints. No before-fix baseline FAIL or native-policy proof is claimed.

After 65/875/0 the coordinator assigned the pending credential whole-chain batch.
The source changed during preparation from raw-byte comparison to semantic
access+refresh identity and exact-current quiet rebase. The new harness, runner
guards, README and test-plan were edited after that run. The latest batch then received a separate isolation approval and passed
78/1089/0 as recorded above; the two historical PASS results do not cover it.

Координаторская фиксация последнего прогона: команда `sh fixtures/manual-refresh-independent/run.sh`,78scenarios/1089assertions/0fail, exit0. Inputs b118084f/8aea790e/6e5c67f6; артефакты /private/tmp/ccl-manual-refresh-independent-run.5qrJeA. После теста исполняемые входы не менялись. Реальные native/API/credentials не использовались.
