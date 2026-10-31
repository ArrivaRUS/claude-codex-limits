import Foundation

// MARK: - REMOTE-LIMITS C2 selftests (tester, 2026-10-21; written red before the code, P13)
//
// Sources of truth: docs/plans.md «C2 — macOS: настройки, деньги, история», docs/test-plan-remote-limits.md §C2 (C2-01…C2-09)
// and its trace rows (F7, F8, G3/G4 + PRD §5 `reader_card_state`, RL-16/V8, U1–U3, N1–N3), arch/plan-synth.md §F («История
// темпа (№13)», «Настройки, деньги, UI»), arch/plan-claude.md §F (N1/N2, U3, V8), docs/prd-remote-limits.md U1–U3, N1–N3, V8,
// §5; design/remote-limits-ux.md §4 (V5), §6, §9 (N3: no dialogs). Lessons 006/011/012/013.
//
// Isolation (006/011/013): every clock under test is an injected `now`; the only HTTP is SelfTestHTTP / OFFLINE_SYNC_HTTP and the
// injected ClaudeQuotaIO trap; no Keychain (ScriptedSyncKeychain / OfflineSyncKeychain / the trap); defaults are the memory
// adapter installed by `--subscriptions-selftest` plus fresh MemorySelfTestDefaults per sync; every file (history, poll log,
// sync-remote cache) lives in a fresh NSTemporaryDirectory() folder removed at the end. Golden fixtures are read-only
// (fixtures/remote-limits/, located by remoteLimitsFixturesDir() from RemoteLimitsSelfTests.swift).
//
// Registered at the end of the `--subscriptions-selftest` block in LimitsMonitor.swift (plan: C2 is validated by it). Each
// check prints `OK …` / `FAIL C2-…`; the block exits 1 when any C2 check failed (after all of them ran).
//
// Contract these tests compile against (developer: LimitsMonitor.swift / RemoteLimits.swift). Names from synth §F and
// plans.md where they exist (`UsageSample.acct`, `record(d, product:, acct:)`, `recordRemote(product:, label:, sample)`,
// `hiddenAccounts`, `menuAccount`, `mergedUsageIndex`, `subscriptionUSD(tier:)`, `reader_card_state`, poll-log.jsonl); the rest
// chosen by the tester and listed in the C2 report (C2-09: docs/review-remote-limits-c2.md, major identity transfer):
//
//   func readerQuotaCompletion(_ response: LimitData, previous: LimitData, previousId: String?, readingId: String?,
//                              cached: LimitData? = nil) -> (data: LimitData, id: String?)
//       // Runtime selection and identity travel together: fresh → readingId; retained previous → previousId;
//       // a new fallback or disk cache → nil. ReaderLocalSnapshot.update publishes this result for sampleProducts.
//
//   // 013 trap: every Claude Keychain helper launch and provider request of fetchClaude goes through `io`.
//   struct ClaudeQuotaIO {                                   // stored properties exactly in this order (memberwise init)
//       var keychain: (_ operation: String, _ input: String?) -> (status: SyncKeychainStatus, out: String)  // quiet helper: "read" | "update"
//       var permissionRead: (_ permit: QuotaKeychainReadPermit) -> (status: SyncKeychainStatus, out: String)  // explicit interactive read
//       var http: (_ url: String, _ method: String, _ headers: [String: String], _ body: Data?, _ timeout: Double,
//                  _ noRedirects: Bool) -> SyncHTTPResult                                                  // oauth/token + api/oauth/usage
//       static let live: ClaudeQuotaIO    // today's adapters; under --sync-selftest / --subscriptions-selftest its keychain and
//   }                                     // permissionRead closures preconditionFailure (a half-wired `io` can never reach Keychain)
//   func fetchClaude(readPermit: QuotaKeychainReadPermit? = nil, io: ClaudeQuotaIO = .live) -> LimitData
//
//   // History by account (synth §F №13). Local key "l:" + hex(sha256(product + "|" + localId))[:16] (= AccountView.historyKey of
//   // a local view, already in C1); a remote key is the label; lines without `a` load as "l:legacy".
//   struct UsageSample += var acct: String = "l:legacy"      // declared LAST (memberwise init order); file line key "a"
//   final class UsageHistory {
//       init(path: String)                                    // shared = UsageHistory(path: HISTORY_PATH)
//       func load(now: Date = Date())                         // retention cut from `now`
//       func record(_ d: LimitData, product: String, acct: String, now: Date = Date())   // local; productEnabled guard stays (013)
//       func recordRemote(product: String, label: String, _ s: UsageSample)               // NO productEnabled; dedup by (acct, t)
//       func samples(_ product: String, acct: String, since: Date) -> [UsageSample]       // a remote acct is not gated by productEnabled
//       func recentRate(_ product: String, acct: String, metric: (UsageSample) -> Double?, minutes: Double, now: Date) -> Double?
//   }
//
//   // Settings (N1–N3, V8). Keys: "hiddenAccounts" = [String] labels; "menuAccount" = [String: String] product → label.
//   func hiddenAccounts(defaults: UserDefaults = .standard) -> Set<String>     // absent / not an array → []; reading never writes
//   func menuAccountSelection(defaults: UserDefaults = .standard) -> [String: String]
//   func menuAccount(_ product: String, views: [AccountView], selected: [String: String]) -> AccountView?
//       // selected label present among `views` → it; else the local view of the product; else its first view in V2 order; else nil
//   func mergedUsageIndex(_ sync: GitHubSync = .shared, hidden: Set<String> = hiddenAccounts()) -> UsageIndex
//       // remote part = Σ accounts[].days of labels not in `hidden` + unattributedDays (V7); NOT filtered by productEnabled (U2)
//
//   // Money (U1, U3)
//   func subscriptionUSD(_ product: String, plan: String?, tier: String?, isLocal: Bool) -> (usd: Double, estimated: Bool)
//       // local: today's rules (subClaude/subCodex, then claudeTier); remote: tier/plan of the snapshot only — local claudeTier
//       // and subClaude/subCodex never apply; nothing known → fallback with estimated = true. The 2-arg overload = local.
//   func dailyUsage(_ product: String, days: Int, index: UsageIndex, now: Date = Date()) -> [DayUsage]   // `now` replaces Date()
//   func accountUsageIndex(_ view: AccountView, local: UsageIndex) -> UsageIndex
//       // days[view.product] = view.usageDays (+ local.days[view.product] when view.isLocal); nothing of other accounts
//   func moneySummary(_ view: AccountView, local: UsageIndex, days: Int = 35, now: Date) -> MoneySummary
//       // usage = accountUsageIndex; price = subscriptionUSD(view.product, plan: view.data.plan, tier: view.tier, isLocal: view.isLocal)
//
//   // Reader journal (PRD §5, G3/G4). One JSON object per line, keys exactly ev, ts, product, label, state, age:
//   //   {"ev":"reader_card_state","ts":"<ISO-8601 UTC of now>","product":"claude|codex","label":"<16 hex>"|null,
//   //    "state":<RemoteCardState.rawValue 1…7>,"age":<whole seconds now − data.asOf, ≥ 0>|null}
//   let POLL_LOG_PATH = DATA_DIR + "/poll-log.jsonl"
//   func readerCardStateEvents(_ views: [AccountView], now: Date) -> [[String: Any]]           // pure, one per view
//   @discardableResult func appendPollLog(_ events: [[String: Any]], path: String = POLL_LOG_PATH) -> Bool  // file 0600 (also an existing one)
//   GitHubSync += var onRead: ((SyncRemoteCache, Date) -> Void)?
//       // called synchronously on the thread running syncBody, once per successful read, after `_remote` and syncLastOkAt are
//       // published, with the merged cache and the cycle's read time (clock()); never on a failed or skipped cycle
//   func readerDidSync(_ cache: SyncRemoteCache, at now: Date, local: (LimitData, LimitData), localIds: [String: String],
//                      hidden: Set<String>, sync: ReaderSyncState, history: UsageHistory, pollLog: String)
//       // what the app's onRead does: recordRemote for every labelled remote record with asOf ≤ now + 300 s and a window, then
//       // one reader_card_state line per visible AccountView (resolveAccounts(…, hidden: hidden, …)) appended to `pollLog`
//
// Not provable here (lesson 013 boundary, test plan §4): «no system dialog» after the N3 migration — the selftest proves 0 helper
// launches and 0 defaults writes; the absence of a window is checked by a person on the Mac.

private typealias C2Expect = (Bool, String) -> Void
private typealias C2Days = [String: [String: DayModelUsage]]           // day → model → usage

// Synthetic identities (fixtures/remote-limits/label-vectors.json + machine-v11-c2.json; no real account).
private let C2_G1 = "fixturegist0000000000000000000001"
private let C2_G2 = "fixturegist0000000000000000000002"
private let C2_UUID_A = "3b9d6c1e-8f42-4a7b-9c05-2e6f1d8a4b70"
private let C2_UUID_C = "c0dex000-1111-4222-8333-444455556666"
private let C2_CLAUDE = "f4b718320ee15b3a"          // label(G1, claude, UUID_A) — Claude Max 20x on vps (V5 1 at C2_NOW)
private let C2_CODEX_A = "f683db167afc0b47"         // label(G1, codex, UUID_C) — Codex A, expired (V5 3)
private let C2_CODEX_A_G2 = "76b5edc112555730"      // label(G2, codex, UUID_C) — the same account after a gist change
private let C2_CODEX_B = "c2b0000000000b02"         // Codex B, rate_limited until 11:14 (V5 4)
private let C2_CODEX_C = "c2c0000000000c03"         // Codex C, fresh; the one the reader hides
private let C2_LOCAL_CODEX_KEY = "l:daa6569e7d095f5c" // "l:" + sha256("codex|" + UUID_C)[:16] (synth §F, survives a gist change)
private let C2_VPS_ID = "5a1e0c2d-7b3f-4e8a-9d61-0f2c4b8e6a13"
private let C2_VPS_FILE = "machine-5a1e0c2d-7b3f-4e8a-9d61-0f2c4b8e6a13.json"
private let C2_NOW = "2026-10-12T10:20:00Z"
private let C2_GIST = "c2-fix-gist"
private let C2_MAC = "c2-mac"

// MARK: helpers (pure)

private struct C2Checks {
    var failed: [String] = []
    mutating func add(_ name: String, _ ok: Bool) { if !ok { failed.append(name) } }
    var suffix: String { failed.isEmpty ? "" : " — failed: " + failed.joined(separator: "; ") }
}

private let c2ISO: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()
private func c2Date(_ s: String) -> Date { c2ISO.date(from: s) ?? Date(timeIntervalSince1970: 0) }
private func c2Str(_ d: Date) -> String { c2ISO.string(from: d) }
private func c2JSON(_ obj: [String: Any]) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
}
private func c2Object(_ text: String) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
}
private func c2Fixture(_ name: String) -> String? {
    guard let dir = remoteLimitsFixturesDir() else { return nil }
    return try? String(contentsOfFile: dir + "/" + name, encoding: .utf8)
}

private func c2Counts(_ input: Int, _ output: Int, turns: Int) -> [String: Any] {
    ["input": input, "output": output, "cacheRead": 0, "cacheWrite5m": 0, "cacheWrite1h": 0, "turns": turns]
}
/// day → model → usage of a fixture JSON object (the golden side of a comparison).
private func c2JSONDays(_ any: Any?) -> C2Days {
    var out = C2Days()
    for (day, models) in (any as? [String: Any]) ?? [:] {
        for (model, raw) in (models as? [String: Any]) ?? [:] {
            guard let v = raw as? [String: Any] else { continue }
            func n(_ key: String) -> Int { (v[key] as? NSNumber)?.intValue ?? 0 }
            out[day, default: [:]][model] = DayModelUsage(input: n("input"), output: n("output"), cacheRead: n("cacheRead"),
                cacheWrite5m: n("cacheWrite5m"), cacheWrite1h: n("cacheWrite1h"), turns: n("turns"))
        }
    }
    return out
}
private func c2Canon(_ days: C2Days) -> String {
    var out: [String] = []
    for d in days.keys.sorted() {
        let byModel = days[d] ?? [:]
        for m in byModel.keys.sorted() {
            guard let u = byModel[m] else { continue }
            out.append("\(d)|\(m)=\(u.input),\(u.output),\(u.cacheRead),\(u.cacheWrite5m),\(u.cacheWrite1h),\(u.turns)")
        }
    }
    return out.joined(separator: ";")
}
private func c2Cost(_ days: C2Days) -> Double {
    var usd = 0.0
    for (_, models) in days { for (m, u) in models { usd += apiCost(m, u) ?? 0 } }
    return usd
}
private func c2Turns(_ ix: UsageIndex, _ product: String, _ day: String, _ model: String) -> Int {
    ix.days[product]?[day]?[model]?.turns ?? 0
}
/// The days of one account record of machine-v11-c2.json.
private func c2RecordDays(_ fixture: String, _ label: String) -> C2Days {
    let records = (c2Object(fixture)?["accounts"] as? [[String: Any]]) ?? []
    return c2JSONDays(records.first(where: { ($0["label"] as? String) == label })?["days"])
}

/// One v1.1 account record (synth §A).
private func c2Acct(_ product: String, _ label: String, status: String = "ok", asOf: Date, pct: Double,
                    plan: String? = nil, tier: String? = nil, days: [String: Any] = [:]) -> [String: Any] {
    var a: [String: Any] = ["product": product, "label": label, "status": status, "days": days,
                            "asOf": c2Str(asOf), "attemptAt": c2Str(asOf), "attemptKind": "auto", "retryUntil": NSNull(),
                            "windows": ["session": ["pct": pct], "weekly": ["pct": pct]] as [String: Any],
                            "schedule": ["mode": "auto", "interval": 900, "nextAt": c2Str(asOf.addingTimeInterval(900)),
                                         "backoff": false] as [String: Any]]
    if let p = plan { a["plan"] = p }
    if let t = tier { a["tier"] = t }
    return a
}
/// One machine file v1.1 whose root `days` equal Σ accounts[].days (here: all empty), seen at `seen`.
private func c2MachineFile(_ id: String, name: String, seen: Date, accounts: [Any]) -> String {
    c2JSON(["schema": 1, "tz": "Etc/UTC", "days": [String: Any](), "accounts": accounts, "unattributedDays": [String: Any](),
            "updated": c2Str(seen), "lastSeenAt": c2Str(seen),
            "machine": ["id": id, "name": name, "os": "Ubuntu 26.04", "app": "linux 0.5.0"] as [String: Any]])
}
private func c2Cache(_ files: [String: String], now: Date, gist: String = C2_G1) -> SyncRemoteCache {
    var cache = mergeV11(files, excluding: C2_MAC, now: now)
    cache.gistId = gist
    return cache
}
private func c2Absent() -> LimitData { var d = LimitData(); d.present = false; return d }
private func c2Local(_ pct: Double, asOf: Date) -> LimitData {
    var d = LimitData(); d.session = pct; d.weekly = pct; d.asOf = asOf; d.apiFresh = true
    return d
}
private func c2Resolve(_ cache: SyncRemoteCache, claude: LimitData = c2Absent(), codex: LimitData = c2Absent(),
                       ids: [String: String] = [:], hidden: Set<String> = [], phase: SyncPhase = .on, now: Date) -> [AccountView] {
    resolveAccounts(local: (claude, codex), localIds: ids, remote: cache, hidden: hidden, menu: [:],
                    sync: ReaderSyncState(phase: phase), now: now)
}
private func c2Key(_ v: AccountView?) -> String {
    guard let v = v else { return "none" }
    return v.product + ":" + (v.isLocal ? "local" : (v.label ?? "nil"))
}
private func c2Lines(_ path: String) -> [[String: Any]] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").compactMap { c2Object(String($0)) }
}
private func c2Mode(_ path: String) -> Int? {
    ((try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? NSNumber).map { $0.intValue & 0o777 }
}

// MARK: traps

/// Recording ClaudeQuotaIO: no helper process, no Keychain, no network. Every call is counted (lesson 013).
private final class C2QuotaTrap {
    var keychain: [String] = []
    var permission = 0
    var http: [String] = []
    var io: ClaudeQuotaIO {
        ClaudeQuotaIO(keychain: { operation, _ in self.keychain.append(operation); return (.missing, "") },
                      permissionRead: { _ in self.permission += 1; return (.missing, "") },
                      http: { url, _, _, _, _, _ in self.http.append(url); return (599, nil, "selftest: provider trap", [:]) })
    }
}

/// One sync cycle through GitHubSync with an in-memory gist (no network, no Keychain, fresh memory defaults, fixed clock).
/// `gistStatus` ≠ 200 makes the read fail (a `.failed` cycle). Returns the sync and the recorded transport.
private func c2SyncOnce(root: String, files: [String: String], now: Date, gistStatus: Int = 200, hidden: [String]? = nil,
                        onRead: ((SyncRemoteCache, Date) -> Void)? = nil) -> (sync: GitHubSync, http: SelfTestHTTP) {
    let defaults = MemorySelfTestDefaults()
    defaults.set("selftest-login", forKey: "syncLogin")
    defaults.set(C2_GIST, forKey: "syncGistId")
    defaults.set(Date(), forKey: "syncDiscoveredAt")       // same as rlSyncOnce: discovery age is not the clock under test
    if let h = hidden { defaults.set(h, forKey: "hiddenAccounts") }
    var all: [String: Any] = [:]
    for (name, content) in files { all[name] = ["content": content] }
    all[SYNC_MANIFEST] = ["content": "{}"]
    all["machine-\(C2_MAC).json"] = ["content": "{}"]
    let gist: [String: Any] = ["id": C2_GIST, "public": false, "created_at": "2026-01-01T00:00:00Z", "files": all]
    let body = (try? JSONSerialization.data(withJSONObject: gist)) ?? Data()
    let gistURL = "https://api.github.com/gists/" + C2_GIST
    let http = SelfTestHTTP { c in
        if c.url == gistURL && c.method == "GET" {
            if gistStatus == 200 { return (200, body, nil, [:]) }
            return (gistStatus, nil, nil, [:])
        }
        if c.url == gistURL && c.method == "PATCH" { return (200, Data("{}".utf8), nil, [:]) }
        return (599, nil, nil, [:])
    }
    let sync = GitHubSync(transport: http.transport, keychain: ScriptedSyncKeychain(store: SelfTestKeychainStore("c2-selftest-token")),
                          defaults: defaults, remotePath: root + "/c2-remote-" + UUID().uuidString + ".json", machineId: C2_MAC,
                          revokeRecheckDelay: 0, clock: { now })
    sync.onRead = onRead
    sync.syncSynchronously()
    return (sync, http)
}
/// The machine file this Mac PATCHed, without its time fields (`updated`, `lastSeenAt`), as canonical JSON. nil = no PATCH.
private func c2PatchedFile(_ http: SelfTestHTTP) -> String? {
    guard let call = http.calls.last(where: { $0.method == "PATCH" }), let body = call.body,
          let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
          let files = obj["files"] as? [String: Any], let mine = files["machine-\(C2_MAC).json"] as? [String: Any],
          let content = mine["content"] as? String, var file = c2Object(content) else { return nil }
    file.removeValue(forKey: "updated"); file.removeValue(forKey: "lastSeenAt")
    return c2JSON(file)
}

// MARK: A1-10 scanner (Swift twin of linux/tests/test_rl_contract.py TestA110Minimisation.assert_clean)

private func c2Sentinels() -> [String] {
    guard let raw = c2Fixture("pii-sentinels.json").flatMap(c2Object) else { return [] }
    var out: [String] = []
    for (key, value) in raw where !key.hasPrefix("_") { if let s = value as? String { out.append(s) } }
    for (_, parts) in (raw["token_parts"] as? [String: Any]) ?? [:] {
        out.append(((parts as? [String]) ?? []).joined())
    }
    return out
}
private func c2Matches(_ pattern: String, _ text: String) -> [String] {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return ["<bad pattern>"] }
    let ns = text as NSString
    return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
}
/// Findings: sentinels, e-mail, UUIDs other than `allowUUIDs` (machine.id), token/path markers. Empty = clean.
private func c2PIIFindings(_ text: String, sentinels: [String], allowUUIDs: Set<String> = []) -> [String] {
    var found: [String] = []
    for s in sentinels where !s.isEmpty && text.contains(s) { found.append("sentinel") }
    found += c2Matches("[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}", text).map { _ in "email" }
    found += c2Matches("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", text)
        .filter { !allowUUIDs.contains($0.lowercased()) }.map { _ in "uuid" }
    for marker in ["eyJ", "sk-", "Bearer", "/home/", "/Users/"] where text.contains(marker) { found.append(marker) }
    return found
}

// MARK: C2-01 disabled local Claude poll: 0 Keychain/API, remote pace and history by acct, rewritten selftest ~7108

private func c2C201(_ root: String, _ fixture: String?, _ select: (Bool, Bool) -> Void, _ expect: C2Expect) {
    let now = c2Date(C2_NOW)
    select(false, true)
    let trap = C2QuotaTrap()
    let off = fetchClaude(io: trap.io)
    let offManual = fetchClaude(readPermit: QuotaKeychainReadPermit(now: ProcessInfo.processInfo.systemUptime), io: trap.io)
    var a = C2Checks()
    a.add("no local Claude data", !off.present && !offManual.present)
    a.add("0 quiet Keychain helper calls (got \(trap.keychain))", trap.keychain.isEmpty)
    a.add("0 interactive Keychain reads (got \(trap.permission))", trap.permission == 0)
    a.add("0 provider requests (got \(trap.http))", trap.http.isEmpty)
    expect(a.failed.isEmpty, "C2-01 monitor_claude = false: fetchClaude (auto and manual permit) touches no Keychain/helper/API (013)" + a.suffix)

    // Control: the same trap does see a read when the local poll is on — the zero above is not vacuous.
    select(true, true)
    let control = C2QuotaTrap()
    let on = fetchClaude(io: control.io)
    _ = fetchClaude(readPermit: QuotaKeychainReadPermit(now: ProcessInfo.processInfo.systemUptime), io: control.io)
    select(false, true)
    var c = C2Checks()
    c.add("quiet read through io (got \(control.keychain))", control.keychain == ["read"])
    c.add("interactive read through io (got \(control.permission))", control.permission == 1)
    c.add("missing item → signed out, no provider request (got \(control.http))", on.auth == .loggedOut && control.http.isEmpty)
    expect(c.failed.isEmpty, "C2-01 control: with the poll on, fetchClaude reaches Keychain only through the injected io" + c.suffix)

    // Remote pace: two VPS readings of the same Claude account arrive by sync while the local poll stays off.
    let history = UsageHistory(path: root + "/c2-01-history.jsonl")
    let pollLog = root + "/c2-01-poll.jsonl"
    let t1 = c2Date("2026-10-12T10:00:00Z"), t2 = c2Date("2026-10-12T10:15:00Z")
    func vps(_ asOf: Date, _ pct: Double) -> SyncRemoteCache {
        let seen = asOf.addingTimeInterval(5)
        return c2Cache([C2_VPS_FILE: c2MachineFile(C2_VPS_ID, name: "vps", seen: seen, accounts: [
            c2Acct("claude", C2_CLAUDE, asOf: asOf, pct: pct, plan: "max", tier: "default_claude_max_20x")])], now: seen)
    }
    let local = (off, c2Absent())
    readerDidSync(vps(t1, 40), at: t1.addingTimeInterval(300), local: local, localIds: [:], hidden: [],
                  sync: ReaderSyncState(phase: .on), history: history, pollLog: pollLog)
    readerDidSync(vps(t2, 42.5), at: now, local: local, localIds: [:], hidden: [],
                  sync: ReaderSyncState(phase: .on), history: history, pollLog: pollLog)
    readerDidSync(vps(t2, 42.5), at: now, local: local, localIds: [:], hidden: [],
                  sync: ReaderSyncState(phase: .on), history: history, pollLog: pollLog)   // the same reading again
    let samples = history.samples("claude", acct: C2_CLAUDE, since: c2Date("2026-10-12T09:00:00Z"))
    let rate = history.recentRate("claude", acct: C2_CLAUDE, metric: { $0.session }, minutes: 60, now: now)
    var h = C2Checks()
    h.add("2 samples under the label (got \(samples.count))", samples.count == 2)
    h.add("t = asOf of each reading", samples.map { $0.t }.sorted() == [t1.timeIntervalSince1970, t2.timeIntervalSince1970])
    h.add("acct = label", samples.allSatisfy { $0.acct == C2_CLAUDE })
    h.add("session values 40 → 42.5", samples.sorted { $0.t < $1.t }.map { $0.session ?? -1 } == [40, 42.5])
    h.add("pace 10 %/h (got \(rate.map { String($0) } ?? "nil"))", rate.map { abs($0 - 10) < 0.01 } ?? false)
    h.add("still 0 Keychain/API", trap.keychain.isEmpty && trap.permission == 0 && trap.http.isEmpty)
    expect(h.failed.isEmpty, "C2-01 local Claude poll off + foreign asOf from the gist → history by acct (label) and pace are computed (F8, synth №13)" + h.suffix)

    // The local guard stays (013 list: record keeps productEnabled): a local reading of a disabled poll is not written.
    var reading = LimitData(); reading.session = 5; reading.weekly = 5; reading.asOf = t1; reading.apiFresh = true
    history.record(reading, product: "claude", acct: "l:0000000000000000", now: now)
    _ = history.samples("claude", acct: C2_CLAUDE, since: .distantPast)          // drains the history queue
    let localLines = c2Lines(root + "/c2-01-history.jsonl").filter { ($0["a"] as? String) == "l:0000000000000000" }
    expect(localLines.isEmpty, "C2-01 record() of a LOCAL Claude reading with the poll off writes nothing (guard kept, 013)")

    // Rewritten selftest ~7108 (LimitsMonitor.swift «remote history cannot restore disabled subscription», retired by U2).
    guard let file = fixture else { expect(false, "C2-01 machine-v11-c2.json readable"); return }
    let legacy = "{\"schema\":1,\"machine\":{\"id\":\"c2legacy\",\"name\":\"thinkpad\",\"os\":\"ALSE\",\"app\":\"linux 0.4.5\"},"
        + "\"updated\":\"2026-10-12T09:00:00Z\",\"tz\":\"UTC\",\"days\":{\"claude\":{\"2026-10-11\":{\"claude-haiku-c2\":"
        + "{\"input\":40,\"output\":4,\"cacheRead\":0,\"cacheWrite5m\":0,\"cacheWrite1h\":0,\"turns\":4}}}}}"
    let sync = GitHubSync(transport: OFFLINE_SYNC_HTTP, keychain: OfflineSyncKeychain(), defaults: MemorySelfTestDefaults(),
                          remotePath: root + "/c2-7108-remote.json", machineId: C2_MAC)
    sync.setRemoteForPreview(mergeV11([C2_VPS_FILE: file, "machine-c2legacy.json": legacy], excluding: C2_MAC, now: now))
    let merged = mergedUsageIndex(sync)
    var r = C2Checks()
    r.add("labelled Claude account days (got \(c2Turns(merged, "claude", "2026-10-12", "claude-fable-5-1")) turns)",
          c2Turns(merged, "claude", "2026-10-12", "claude-fable-5-1") >= 12)
    r.add("unlabelled legacy Claude days (V7) (got \(c2Turns(merged, "claude", "2026-10-11", "claude-haiku-c2")))",
          c2Turns(merged, "claude", "2026-10-11", "claude-haiku-c2") == 4)
    expect(r.failed.isEmpty, "C2-01 (rewritten selftest ~7108) remote usage of a visible account survives a disabled local poll (U2)" + r.suffix)
}

// MARK: C2-02 price from the snapshot tier, local claudeTier never applied to a foreign account (U3, F7, G4)

private func c2C202(_ fixture: String?, _ defaults: MemorySelfTestDefaults, _ select: (Bool, Bool) -> Void, _ expect: C2Expect) {
    let now = c2Date(C2_NOW)
    guard let file = fixture else { expect(false, "C2-02 machine-v11-c2.json readable"); return }
    select(false, true)                                  // the owner's Mac: no local Claude
    defaults.set("default_claude_max_5x", forKey: "claudeTier")
    defer { defaults.removeObject(forKey: "claudeTier"); defaults.removeObject(forKey: "subClaude") }
    let claude = c2Resolve(c2Cache([C2_VPS_FILE: file], now: now), now: now).first { $0.product == "claude" }
    func same(_ got: (usd: Double, estimated: Bool), _ usd: Double, _ estimated: Bool) -> Bool {
        abs(got.usd - usd) < 0.001 && got.estimated == estimated
    }
    var a = C2Checks()
    a.add("precondition: remote Claude card with tier from vps (got \(claude?.tier ?? "nil"))",
          claude?.isLocal == false && claude?.tier == "default_claude_max_20x")
    if let v = claude {
        let price = subscriptionUSD(v.product, plan: v.data.plan, tier: v.tier, isLocal: v.isLocal)
        a.add("max_20x from vps → $200 without estimate (got \(price))", same(price, 200, false))
        let money = moneySummary(v, local: UsageIndex(), now: now)
        a.add("money table: $200, not estimated (got \(money.subMonthly), \(money.subEstimated))",
              abs(money.subMonthly - 200) < 0.001 && !money.subEstimated)
    }
    let max5 = subscriptionUSD("claude", plan: "max", tier: "default_claude_max_5x", isLocal: false)
    a.add("remote max_5x → $100 (got \(max5))", same(max5, 100, false))
    let pro = subscriptionUSD("claude", plan: "pro", tier: nil, isLocal: false)
    a.add("remote pro → $20 (got \(pro))", same(pro, 20, false))
    let unknown = subscriptionUSD("claude", plan: nil, tier: nil, isLocal: false)
    a.add("remote without tier → fallback marked estimated, not the local max_5x $100 (got \(unknown))",
          unknown.estimated && abs(unknown.usd - 100) > 0.001)
    expect(a.failed.isEmpty, "C2-02 U3: price from the account snapshot; local claudeTier = max_5x is not applied to it" + a.suffix)

    var g = C2Checks()
    g.add("local keeps claudeTier max_5x → $100", same(subscriptionUSD("claude", plan: "max", tier: nil, isLocal: true), 100, false))
    g.add("2-arg overload = local", same(subscriptionUSD("claude", plan: "max"), 100, false))
    defaults.set(50.0, forKey: "subClaude")
    g.add("owner price subClaude applies to the local account", same(subscriptionUSD("claude", plan: "max", tier: nil, isLocal: true), 50, false))
    g.add("subClaude never applies to a foreign account (plan-claude §F U3)",
          same(subscriptionUSD("claude", plan: "max", tier: "default_claude_max_20x", isLocal: false), 200, false))
    expect(g.failed.isEmpty, "C2-02 (guard) local price rules unchanged; product-wide owner price only for the local account" + g.suffix)
}

// MARK: C2-03 two Codex accounts: separate days, calendar and money (U1, F7)

private func c2C203(_ fixture: String?, _ expect: C2Expect) {
    let now = c2Date(C2_NOW)
    guard let file = fixture else { expect(false, "C2-03 machine-v11-c2.json readable"); return }
    let views = c2Resolve(c2Cache([C2_VPS_FILE: file], now: now), now: now)
    let aDays = c2RecordDays(file, C2_CODEX_A), bDays = c2RecordDays(file, C2_CODEX_B), cDays = c2RecordDays(file, C2_CODEX_C)
    guard let a = views.first(where: { $0.label == C2_CODEX_A }), let b = views.first(where: { $0.label == C2_CODEX_B }) else {
        expect(false, "C2-03 precondition: two remote Codex cards (got \(views.map { c2Key($0) }))"); return
    }
    let ia = accountUsageIndex(a, local: UsageIndex()), ib = accountUsageIndex(b, local: UsageIndex())
    var c = C2Checks()
    c.add("A index = A days only", c2Canon(ia.days["codex"] ?? [:]) == c2Canon(aDays))
    c.add("B index = B days only", c2Canon(ib.days["codex"] ?? [:]) == c2Canon(bDays))
    c.add("no other product leaks in", ia.days["claude"] == nil && ib.days["claude"] == nil)
    let weekA = dailyUsage("codex", days: 7, index: ia, now: now), weekB = dailyUsage("codex", days: 7, index: ib, now: now)
    let turnsA = weekA.reduce(0) { $0 + $1.turns }, turnsB = weekB.reduce(0) { $0 + $1.turns }
    c.add("7-day bars A = 3 turns (got \(turnsA))", turnsA == 3)
    c.add("7-day bars B = 5 turns (got \(turnsB))", turnsB == 5)
    let calA = dailyUsage("codex", days: 35, index: ia, now: now).filter { $0.turns > 0 }.map { $0.day }
    let calB = dailyUsage("codex", days: 35, index: ib, now: now).filter { $0.turns > 0 }.map { $0.day }
    c.add("calendar A = [2026-10-10] (got \(calA))", calA == ["2026-10-10"])
    c.add("calendar B = [2026-10-11] (got \(calB))", calB == ["2026-10-11"])
    let ma = moneySummary(a, local: UsageIndex(), now: now), mb = moneySummary(b, local: UsageIndex(), now: now)
    let total = c2Cost(aDays) + c2Cost(bDays) + c2Cost(cDays)
    c.add("money A = cost of A days (got \(ma.usdApi), want \(c2Cost(aDays)))", abs(ma.usdApi - c2Cost(aDays)) < 1e-9)
    c.add("money B = cost of B days (got \(mb.usdApi), want \(c2Cost(bDays)))", abs(mb.usdApi - c2Cost(bDays)) < 1e-9)
    c.add("the product total is not shown as one account", abs(ma.usdApi - total) > 1e-6 && abs(mb.usdApi - total) > 1e-6)
    c.add("active days 1 / 1", ma.activeDays == 1 && mb.activeDays == 1)
    c.add("price per account from its plan (Codex table → estimated)",
          ma.subEstimated == subscriptionUSD("codex", plan: "pro", tier: nil, isLocal: false).estimated
          && abs(mb.subMonthly - subscriptionUSD("codex", plan: "plus", tier: nil, isLocal: false).usd) < 0.001)
    expect(c.failed.isEmpty, "C2-03 two Codex accounts → separate days, calendar and money; the sum is never one account's (U1)" + c.suffix)

    // The local account = its remote days + this Mac's own logs; another account's days never join it.
    var localIx = UsageIndex()
    localIx.add("codex", "2026-10-12", "gpt-6-sol", DayModelUsage(input: 10, output: 1, cacheRead: 0, cacheWrite5m: 0, cacheWrite1h: 0, turns: 2))
    let withLocal = c2Resolve(c2Cache([C2_VPS_FILE: file], now: now), codex: c2Local(10, asOf: now.addingTimeInterval(-60)),
                              ids: ["codex": C2_UUID_C], now: now)
    var l = C2Checks()
    if let mine = withLocal.first(where: { $0.product == "codex" && $0.isLocal }) {
        let ix = accountUsageIndex(mine, local: localIx)
        l.add("local logs included", c2Turns(ix, "codex", "2026-10-12", "gpt-6-sol") == 2)
        l.add("its vps days included", c2Turns(ix, "codex", "2026-10-10", "gpt-6-astra") == 3)
        l.add("account B days excluded", c2Turns(ix, "codex", "2026-10-11", "gpt-6-astra") == 0)
        if let other = withLocal.first(where: { $0.label == C2_CODEX_B }) {
            l.add("B index has no local logs", c2Turns(accountUsageIndex(other, local: localIx), "codex", "2026-10-12", "gpt-6-sol") == 0)
        } else { l.add("B card present", false) }
    } else { l.add("local Codex card present (got \(withLocal.map { c2Key($0) }))", false) }
    expect(l.failed.isEmpty, "C2-03 local Codex account = its vps days + local logs; account B stays apart" + l.suffix)
}

// MARK: C2-04 history file: legacy lines, dedup (acct, t), local key survives a gist change

private func c2C204(_ root: String, _ select: (Bool, Bool) -> Void, _ expect: C2Expect) {
    let now = c2Date(C2_NOW)
    let t = c2Date("2026-10-12T10:00:00Z").timeIntervalSince1970
    let path = root + "/c2-04-history.jsonl"
    let lines = c2JSON(["t": t - 600, "p": "claude", "s": 10.0]) + "\n"
        + c2JSON(["t": t, "p": "claude", "s": 12.0, "a": C2_CLAUDE]) + "\n"
    try? lines.write(toFile: path, atomically: true, encoding: .utf8)
    select(true, true)
    let history = UsageHistory(path: path)
    history.load(now: now)
    let legacy = history.samples("claude", acct: "l:legacy", since: .distantPast)
    let labelled = history.samples("claude", acct: C2_CLAUDE, since: .distantPast)
    var a = C2Checks()
    a.add("line without `a` → l:legacy (got \(legacy.map { $0.acct }))", legacy.count == 1 && legacy.first?.session == 10)
    a.add("line with `a` keeps its acct", labelled.count == 1 && labelled.first?.session == 12 && labelled.first?.acct == C2_CLAUDE)
    expect(a.failed.isEmpty, "C2-04 history: an old line without `a` loads as acct \"l:legacy\" (synth №13)" + a.suffix)

    func sample(_ at: Double, _ pct: Double, _ acct: String) -> UsageSample {
        UsageSample(t: at, product: "codex", session: pct, weekly: pct, scoped: nil, scopedName: nil, sessionReset: nil,
                    weeklyReset: nil, acct: acct)
    }
    history.recordRemote(product: "codex", label: C2_CODEX_B, sample(t, 30, C2_CODEX_B))
    history.recordRemote(product: "codex", label: C2_CODEX_B, sample(t, 30, C2_CODEX_B))      // the same (acct, t)
    history.recordRemote(product: "codex", label: C2_CODEX_C, sample(t, 5, C2_CODEX_C))       // another account, same t
    let b = history.samples("codex", acct: C2_CODEX_B, since: .distantPast)
    let c = history.samples("codex", acct: C2_CODEX_C, since: .distantPast)
    let written = c2Lines(path).filter { ($0["a"] as? String) == C2_CODEX_B && ($0["t"] as? NSNumber)?.doubleValue == t }
    var d = C2Checks()
    d.add("one sample for (B, t) (got \(b.count))", b.count == 1)
    d.add("one line for (B, t) in the file (got \(written.count))", written.count == 1)
    d.add("same t of another account kept (got \(c.count))", c.count == 1)
    d.add("acct field `a` written", c2Lines(path).contains { ($0["a"] as? String) == C2_CODEX_C })
    expect(d.failed.isEmpty, "C2-04 recordRemote dedups by (acct, t): a repeat is not written, another account is" + d.suffix)

    // record() of a local reading writes its local key into the line.
    var reading = c2Local(20, asOf: c2Date("2026-10-12T10:05:00Z"))
    reading.fromCache = false
    history.record(reading, product: "codex", acct: C2_LOCAL_CODEX_KEY, now: now)
    let local = history.samples("codex", acct: C2_LOCAL_CODEX_KEY, since: .distantPast)
    expect(local.count == 1 && c2Lines(path).contains { ($0["a"] as? String) == C2_LOCAL_CODEX_KEY },
           "C2-04 record(d, product:, acct:) of a local reading stores acct = the local \"l:\" key (got \(local.count))")

    // The local key does not depend on the gist (the label does).
    guard let mine = c2Fixture("machine-v11-c2.json") else { expect(false, "C2-04 machine-v11-c2.json readable"); return }
    func localView(_ gist: String) -> AccountView? {
        c2Resolve(c2Cache([C2_VPS_FILE: mine], now: now, gist: gist), codex: c2Local(10, asOf: now.addingTimeInterval(-60)),
                  ids: ["codex": C2_UUID_C], now: now).first { $0.product == "codex" && $0.isLocal }
    }
    let g1 = localView(C2_G1), g2 = localView(C2_G2)
    var k = C2Checks()
    k.add("historyKey under G1 = \(C2_LOCAL_CODEX_KEY) (got \(g1?.historyKey ?? "nil"))", g1?.historyKey == C2_LOCAL_CODEX_KEY)
    k.add("historyKey under G2 unchanged (got \(g2?.historyKey ?? "nil"))", g2?.historyKey == C2_LOCAL_CODEX_KEY)
    k.add("the label changes with the gist", g1?.label == C2_CODEX_A && g2?.label == C2_CODEX_A_G2)
    expect(k.failed.isEmpty, "C2-04 the local \"l:\" history key survives a gist change; the label does not (B, №13)" + k.suffix)
}

// MARK: C2-05 migration N3: «product off» → «local poll off», all accounts visible, the VPS card appears after GitHub sign-in

private func c2C205(_ root: String, _ fixture: String?, _ defaults: MemorySelfTestDefaults, _ select: (Bool, Bool) -> Void,
                    _ expect: C2Expect) {
    let now = c2Date(C2_NOW)
    guard let file = fixture else { expect(false, "C2-05 machine-v11-c2.json readable"); return }
    select(false, true)                                         // the pre-update preference: Claude «off»
    defaults.removeObject(forKey: "hiddenAccounts")
    let before = defaults.dictionaryRepresentation() as NSDictionary
    let hidden = hiddenAccounts(defaults: defaults)
    let trap = C2QuotaTrap()
    let localClaude = fetchClaude(io: trap.io)
    var m = C2Checks()
    m.add("local poll stays off (monitor_claude kept)", !productEnabled("claude", defaults: defaults))
    m.add("hiddenAccounts empty → all visible (got \(hidden))", hidden.isEmpty)
    m.add("no migration write to defaults", before.isEqual(to: defaults.dictionaryRepresentation()))
    expect(m.failed.isEmpty, "C2-05 N3: old «Claude off» = «local poll off», visibility «all», nothing written, no dialog state" + m.suffix)

    let cache = c2Cache([C2_VPS_FILE: file], now: now)
    let signedOut = c2Resolve(cache, claude: localClaude, hidden: hidden, phase: .off, now: now).filter { $0.product == "claude" }
    var got: SyncRemoteCache? = nil
    let cycle = c2SyncOnce(root: root, files: [C2_VPS_FILE: file], now: now, onRead: { remote, _ in got = remote })
    let signedIn = got.map { c2Resolve($0, claude: localClaude, hidden: hidden, phase: cycle.sync.ui.phase, now: now) }?
        .filter { $0.product == "claude" } ?? []
    var v = C2Checks()
    v.add("before GitHub sign-in: no remote Claude card (state 7)", signedOut.isEmpty)
    v.add("sync read delivered", got != nil && cycle.sync.ui.phase == .on)
    v.add("after sign-in: one remote Claude card (got \(signedIn.map { c2Key($0) }))",
          signedIn.count == 1 && signedIn.first?.isLocal == false && signedIn.first?.label == C2_CLAUDE)
    v.add("fresh (state 1)", signedIn.first?.state.rawValue == 1)
    v.add("0 Keychain/helper calls", trap.keychain.isEmpty && trap.permission == 0)
    v.add("0 Anthropic requests (provider trap)", trap.http.isEmpty)
    v.add("0 Anthropic requests on the sync transport", !cycle.http.calls.contains { $0.url.contains("anthropic.com") })
    expect(v.failed.isEmpty, "C2-05 Mac without Claude: the vps Claude card shows after GitHub sign-in, no settings change, "
           + "0 requests to Anthropic and 0 Keychain (F8, RL-19, UX 12)" + v.suffix)
}

// MARK: C2-06 hidden account: no card, no menu bar, no usage; this Mac's PATCH body unchanged (N1)

private func c2C206(_ root: String, _ fixture: String?, _ defaults: MemorySelfTestDefaults, _ select: (Bool, Bool) -> Void,
                    _ expect: C2Expect) {
    let now = c2Date(C2_NOW)
    guard let file = fixture else { expect(false, "C2-06 machine-v11-c2.json readable"); return }
    defer { defaults.removeObject(forKey: "hiddenAccounts") }
    defaults.set("c2c0000000000c03", forKey: "hiddenAccounts")          // wrong type: not an array
    let garbage = hiddenAccounts(defaults: defaults)
    defaults.set([C2_CODEX_C], forKey: "hiddenAccounts")
    let hidden = hiddenAccounts(defaults: defaults)
    var s = C2Checks()
    s.add("non-array value → nothing hidden (got \(garbage))", garbage.isEmpty)
    s.add("stored label read back (got \(hidden))", hidden == [C2_CODEX_C])
    expect(s.failed.isEmpty, "C2-06 hiddenAccounts setting: [String] of labels in defaults" + s.suffix)

    let cache = c2Cache([C2_VPS_FILE: file], now: now)
    let views = c2Resolve(cache, hidden: hidden, now: now)
    let menu = menuAccount("codex", views: views, selected: ["codex": C2_CODEX_C])
    let sync = GitHubSync(transport: OFFLINE_SYNC_HTTP, keychain: OfflineSyncKeychain(), defaults: MemorySelfTestDefaults(),
                          remotePath: root + "/c2-06-remote.json", machineId: C2_MAC)
    sync.setRemoteForPreview(cache)
    select(true, false)                                                   // Codex local poll off: U2 must not matter
    let shown = mergedUsageIndex(sync, hidden: [])
    let hiddenIx = mergedUsageIndex(sync, hidden: hidden)
    let viaDefaults = mergedUsageIndex(sync)                               // default argument reads hiddenAccounts()
    select(true, true)
    let delta = c2Turns(shown, "codex", "2026-10-11", "gpt-6-sol") - c2Turns(hiddenIx, "codex", "2026-10-11", "gpt-6-sol")
    var c = C2Checks()
    c.add("no card for the hidden label", !views.contains { $0.label == C2_CODEX_C })
    c.add("menu bar never selects it (got \(c2Key(menu)))", menu != nil && menu?.label != C2_CODEX_C)
    c.add("visible: its 7 turns counted even with the Codex poll off (got \(c2Turns(shown, "codex", "2026-10-11", "gpt-6-sol")))",
          c2Turns(shown, "codex", "2026-10-11", "gpt-6-sol") >= 7)
    c.add("hidden: its 7 turns removed (delta \(delta))", delta == 7)
    c.add("other accounts stay (B 5 turns)", c2Turns(hiddenIx, "codex", "2026-10-11", "gpt-6-astra") == c2Turns(shown, "codex", "2026-10-11", "gpt-6-astra")
          && c2Turns(hiddenIx, "codex", "2026-10-11", "gpt-6-astra") >= 5)
    c.add("default argument = the setting", c2Turns(viaDefaults, "codex", "2026-10-11", "gpt-6-sol") == c2Turns(hiddenIx, "codex", "2026-10-11", "gpt-6-sol"))
    expect(c.failed.isEmpty, "C2-06 N1: a hidden account leaves the cards, the menu bar and the usage on this Mac" + c.suffix)

    // Gist and other machines unaffected: the body this Mac PATCHes is the same with and without the hidden label.
    let plain = c2SyncOnce(root: root, files: [C2_VPS_FILE: file], now: now)
    let withHidden = c2SyncOnce(root: root, files: [C2_VPS_FILE: file], now: now, hidden: [C2_CODEX_C, C2_CLAUDE])
    let p1 = c2PatchedFile(plain.http), p2 = c2PatchedFile(withHidden.http)
    var p = C2Checks()
    p.add("both cycles PATCHed this Mac's file", p1 != nil && p2 != nil)
    p.add("identical body (time fields aside)", p1 == p2)
    p.add("no hiddenAccounts in the file", !(p2 ?? "").contains("hiddenAccounts") && !(p2 ?? "").contains(C2_CODEX_C))
    expect(p.failed.isEmpty, "C2-06 hiding changes nothing in the gist: this Mac's PATCH body is unchanged (Ledger PATCH)" + p.suffix)
}

// MARK: C2-07 menu bar account (V8, RL-16)

private func c2C207(_ fixture: String?, _ defaults: MemorySelfTestDefaults, _ expect: C2Expect) {
    let now = c2Date(C2_NOW)
    guard let file = fixture else { expect(false, "C2-07 machine-v11-c2.json readable"); return }
    let cache = c2Cache([C2_VPS_FILE: file], now: now)
    let mine = c2Local(10, asOf: now.addingTimeInterval(-60))
    let all = c2Resolve(cache, codex: mine, ids: ["codex": C2_UUID_C], now: now)
    let firstClaude = all.first { $0.product == "claude" }
    var c = C2Checks()
    c.add("default Codex = the local account (got \(c2Key(menuAccount("codex", views: all, selected: [:]))))",
          menuAccount("codex", views: all, selected: [:])?.isLocal == true)
    c.add("default Claude without a local login = first by V2 (vps) (got \(c2Key(menuAccount("claude", views: all, selected: [:]))))",
          c2Key(menuAccount("claude", views: all, selected: [:])) == c2Key(firstClaude) && firstClaude?.label == C2_CLAUDE)
    c.add("owner's choice B is used", menuAccount("codex", views: all, selected: ["codex": C2_CODEX_B])?.label == C2_CODEX_B)
    let withoutB = c2Resolve(cache, codex: mine, ids: ["codex": C2_UUID_C], hidden: [C2_CODEX_B], now: now)
    c.add("chosen B hidden → back to the local account",
          menuAccount("codex", views: withoutB, selected: ["codex": C2_CODEX_B])?.isLocal == true)
    c.add("chosen label vanished → back to the local account",
          menuAccount("codex", views: all, selected: ["codex": "c2d0000000000d04"])?.isLocal == true)
    let remoteOnly = c2Resolve(cache, now: now)
    let firstCodex = remoteOnly.first { $0.product == "codex" }
    c.add("no local Codex: default = first Codex by V2 (got \(c2Key(menuAccount("codex", views: remoteOnly, selected: [:]))))",
          menuAccount("codex", views: remoteOnly, selected: [:]) != nil
          && c2Key(menuAccount("codex", views: remoteOnly, selected: [:])) == c2Key(firstCodex))
    c.add("no local Codex, chosen vanished → the same default",
          c2Key(menuAccount("codex", views: remoteOnly, selected: ["codex": "c2d0000000000d04"])) == c2Key(firstCodex))
    c.add("a product without accounts → nil", menuAccount("claude", views: all.filter { $0.product == "codex" }, selected: [:]) == nil)
    expect(c.failed.isEmpty, "C2-07 menuAccount: local by default, else first by V2; hidden/vanished choice falls back (V8)" + c.suffix)

    defer { defaults.removeObject(forKey: "menuAccount") }
    let empty = menuAccountSelection(defaults: defaults)
    defaults.set(["codex": C2_CODEX_B], forKey: "menuAccount")
    let stored = menuAccountSelection(defaults: defaults)
    expect(empty.isEmpty && stored == ["codex": C2_CODEX_B],
           "C2-07 menuAccount setting: absent → [:], stored product → label read back (got \(empty) / \(stored))")
}

// MARK: C2-08 reader_card_state in poll-log.jsonl (PRD §5, G3/G4)

private func c2C208(_ root: String, _ fixture: String?, _ expect: C2Expect) {
    let now = c2Date(C2_NOW)
    guard let file = fixture else { expect(false, "C2-08 machine-v11-c2.json readable"); return }
    let sentinels = c2Sentinels()
    let selfCheck = c2PIIFindings("x " + (sentinels.first ?? "alex.fixture@example.invalid"), sentinels: sentinels)
    expect(!sentinels.isEmpty && !selfCheck.isEmpty, "C2-08 scanner self-check: pii-sentinels.json loaded and detected")

    // (a) one successful sync with 3 visible accounts in states 1/3/4 and one hidden.
    let log = root + "/c2-08-poll.jsonl"
    let history = UsageHistory(path: root + "/c2-08-history.jsonl")
    var reads = 0
    let ok = c2SyncOnce(root: root, files: [C2_VPS_FILE: file], now: now, onRead: { cache, at in
        reads += 1
        readerDidSync(cache, at: at, local: (c2Absent(), c2Absent()), localIds: [:], hidden: [C2_CODEX_C],
                      sync: ReaderSyncState(phase: .on), history: history, pollLog: log)
    })
    let lines = c2Lines(log)
    let text = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
    func row(_ label: String) -> [String: Any]? { lines.first { ($0["label"] as? String) == label } }
    func int(_ any: Any?) -> Int? { (any as? NSNumber)?.intValue }
    var a = C2Checks()
    a.add("onRead fired once (got \(reads))", reads == 1 && ok.sync.ui.phase == .on)
    a.add("3 lines, one per visible account (got \(lines.count))", lines.count == 3)
    a.add("all reader_card_state", lines.allSatisfy { ($0["ev"] as? String) == "reader_card_state" })
    a.add("ts = read time", lines.allSatisfy { ($0["ts"] as? String) == c2Str(now) })
    a.add("keys exactly ev/ts/product/label/state/age",
          lines.allSatisfy { Set($0.keys) == ["ev", "ts", "product", "label", "state", "age"] })
    a.add("Claude: state 1, age 298 s (got \(row(C2_CLAUDE).map { "\(int($0["state"]) ?? -1)/\(int($0["age"]) ?? -1)" } ?? "none"))",
          int(row(C2_CLAUDE)?["state"]) == 1 && int(row(C2_CLAUDE)?["age"]) == 298 && (row(C2_CLAUDE)?["product"] as? String) == "claude")
    a.add("Codex A: state 3, age 13189 s", int(row(C2_CODEX_A)?["state"]) == 3 && int(row(C2_CODEX_A)?["age"]) == 13189)
    a.add("Codex B: state 4, age 1200 s", int(row(C2_CODEX_B)?["state"]) == 4 && int(row(C2_CODEX_B)?["age"]) == 1200)
    a.add("hidden Codex C absent", row(C2_CODEX_C) == nil && !text.contains(C2_CODEX_C))
    a.add("file 0600 (got \(c2Mode(log).map { String($0, radix: 8) } ?? "none"))", c2Mode(log) == 0o600)
    let findings = c2PIIFindings(text, sentinels: sentinels)
    a.add("A1-10 scan clean (got \(findings))", findings.isEmpty)
    a.add("no machine id either", !text.contains(C2_VPS_ID))
    expect(a.failed.isEmpty, "C2-08 a successful sync logs reader_card_state per visible account: label, V5 state, age; "
           + "hidden absent; no PII; 0600" + a.suffix)

    // (b) a failed sync (.failed: GET gist 500) adds no line and does not call onRead.
    let sizeBefore = text.utf8.count
    var failedReads = 0
    _ = c2SyncOnce(root: root, files: [C2_VPS_FILE: file], now: now, gistStatus: 500, onRead: { cache, at in
        failedReads += 1
        readerDidSync(cache, at: at, local: (c2Absent(), c2Absent()), localIds: [:], hidden: [],
                      sync: ReaderSyncState(phase: .on), history: history, pollLog: log)
    })
    let after = ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "").utf8.count
    expect(failedReads == 0 && after == sizeBefore,
           "C2-08 a failed sync writes no reader_card_state (onRead \(failedReads)×, log \(sizeBefore) → \(after) bytes)")

    // (c) PII in the inputs never reaches the line; an existing 0644 journal becomes 0600.
    guard var obj = c2Object(file), let email = sentinels.first(where: { $0.contains("@") }) else {
        expect(false, "C2-08 dirty-input fixture"); return
    }
    obj["captions"] = [C2_CODEX_B: ["text": email, "setAt": "2026-10-12T09:00:00Z"]]
    var machine = (obj["machine"] as? [String: Any]) ?? [:]
    machine["os"] = "macOS /Users/alexfixture"; obj["machine"] = machine
    var dirtyLocal = c2Local(15, asOf: now.addingTimeInterval(-30))
    dirtyLocal.error = "Traceback /Users/alexfixture/x.py " + (sentinels.first(where: { $0.hasPrefix("sk-ant-oat") }) ?? "sk-")
    dirtyLocal.plan = sentinels.first(where: { $0 == "AlexFixture" })
    var dirtyViews = c2Resolve(c2Cache([C2_VPS_FILE: c2JSON(obj)], now: now), claude: dirtyLocal, ids: ["claude": C2_UUID_A], now: now)
    // Deliberately bypass wire/input validation: reader_card_state must itself
    // exclude private fields even when handed an unsanitized cached view.
    guard let dirtyIndex = dirtyViews.firstIndex(where: { $0.label == C2_CODEX_B }) else {
        expect(false, "C2-08 raw cached account exists"); return
    }
    dirtyViews[dirtyIndex].caption = email + " /Users/alexfixture "
        + (sentinels.first(where: { $0.hasPrefix("sk-ant-oat") }) ?? "sk-")
    let dirtyLog = root + "/c2-08-dirty.jsonl"
    FileManager.default.createFile(atPath: dirtyLog, contents: Data(), attributes: [.posixPermissions: 0o644])
    let wrote = appendPollLog(readerCardStateEvents(dirtyViews, now: now), path: dirtyLog)
    let dirtyText = (try? String(contentsOfFile: dirtyLog, encoding: .utf8)) ?? ""
    let dirtyFindings = c2PIIFindings(dirtyText, sentinels: sentinels)
    var d = C2Checks()
    d.add("precondition: the input caption carries the e-mail", dirtyViews.contains { $0.caption.contains("@") })
    d.add("written", wrote && c2Lines(dirtyLog).count == dirtyViews.count)
    d.add("A1-10 scan clean (got \(dirtyFindings))", dirtyFindings.isEmpty)
    d.add("no local identity", !dirtyText.lowercased().contains(C2_UUID_A))
    d.add("existing 0644 file → 0600 (got \(c2Mode(dirtyLog).map { String($0, radix: 8) } ?? "none"))", c2Mode(dirtyLog) == 0o600)
    expect(d.failed.isEmpty, "C2-08 reader_card_state carries no caption/e-mail/path/token/local id even when the inputs do" + d.suffix)
}

// MARK: C2-09 a fallback from another login never inherits the previous reading's identity (review major)

private func c2C209(_ root: String, _ expect: C2Expect) {
    let now = c2Date(C2_NOW)
    // Codex reproduces API A → login B → live error → newer rollout B beats cache A.
    // The same identity boundary applies to Claude. All responses and account IDs here are synthetic.
    for (product, idA, labelA) in [("codex", C2_UUID_C, C2_CODEX_A), ("claude", C2_UUID_A, C2_CLAUDE)] {
        let idB = "c2-fixture-" + product + "-account-b"
        let store = ReaderLocalSnapshot()
        func publish(_ completion: (data: LimitData, id: String?)) {
            let current = store.snapshot().local
            let local = product == "claude" ? (completion.data, current.1) : (current.0, completion.data)
            var ids: [String: String] = [:]
            ids[product] = completion.id       // Use the production decision; never manually clear the binding.
            store.update(local: local, ids: ids, identityProducts: [product])
        }
        let apiA = c2Local(20, asOf: now.addingTimeInterval(-900))
        let first = readerQuotaCompletion(apiA, previous: c2Absent(), previousId: nil, readingId: idA)
        publish(first)
        let initial = store.snapshot()
        // An independent, older remote A must remain legal; only the row carrying B's age must be unattributed.
        let remoteA = c2MachineFile(C2_VPS_ID, name: "vps", seen: now, accounts: [
            c2Acct(product, labelA, asOf: now.addingTimeInterval(-1200), pct: 11)
        ])
        let cache = c2Cache([C2_VPS_FILE: remoteA], now: now)
        let initialViews = c2Resolve(cache, claude: initial.local.0, codex: initial.local.1, ids: initial.ids, now: now)
        guard let initialView = initialViews.first(where: { $0.product == product && $0.isLocal }) else {
            expect(false, "C2-09 \(product): initial local A exists"); continue
        }
        let keyA = initialView.historyKey
        let path = root + "/c2-09-" + product + "-history.jsonl"
        let history = UsageHistory(path: path)
        history.record(first.data, product: product, acct: keyA, now: now)
        let before = history.samples(product, acct: keyA, since: .distantPast)  // flush local record
        let beforeLines = c2Lines(path).filter { ($0["a"] as? String) == keyA }.map { c2JSON($0) }
        var start = C2Checks()
        start.add("successful A binds its ID", first.id == idA && initial.ids[product] == idA && initialView.label == labelA)
        start.add("A has a local history key", keyA.hasPrefix("l:") && keyA != "l:legacy"
                  && (product != "codex" || keyA == C2_LOCAL_CODEX_KEY))
        start.add("A history seeded once", before.count == 1 && before.first?.session == 20 && beforeLines.count == 1)
        expect(start.failed.isEmpty, "C2-09 \(product): successful local API A seeds identity and history" + start.suffix)

        var diskA = apiA; diskA.apiFresh = false; diskA.fromCache = true
        var rolloutB = c2Local(73, asOf: now.addingTimeInterval(-60))
        rolloutB.apiFresh = false; rolloutB.fromCache = true
        rolloutB.error = "synthetic live request failed after login B"; rolloutB.pollFailed = true
        let next = readerQuotaCompletion(rolloutB, previous: first.data, previousId: initial.ids[product],
                                         readingId: idB, cached: diskA)
        publish(next)
        let selected = store.snapshot()
        let data = product == "claude" ? selected.local.0 : selected.local.1
        let views = c2Resolve(cache, claude: selected.local.0, codex: selected.local.1, ids: selected.ids, now: now)
        let local = views.first { $0.product == product && $0.isLocal }
        var chosen = C2Checks()
        chosen.add("newer B wins old A memory and disk", data.session == 73 && data.weekly == 73 && data.asOf == rolloutB.asOf)
        chosen.add("live failure retained", !data.apiFresh && data.fromCache && data.error == rolloutB.error && data.pollFailed)
        chosen.add("new fallback has no verified identity", next.id == nil && selected.ids[product] == nil)
        chosen.add("local B never resolves to A", local != nil && local?.label == nil && local?.data.session == 73
                   && local?.historyKey != keyA)
        expect(chosen.failed.isEmpty, "C2-09 \(product): login B + live failure + newer fallback cannot inherit A" + chosen.suffix)

        // Follow the real consumers with the helper's published data/IDs; local history and reader journal are temporary.
        if let local = local { history.record(data, product: product, acct: local.historyKey, now: now) }
        let log = root + "/c2-09-" + product + "-poll.jsonl"
        readerDidSync(cache, at: now, local: selected.local, localIds: selected.ids, hidden: [],
                      sync: ReaderSyncState(phase: .on), history: history, pollLog: log)
        let after = history.samples(product, acct: keyA, since: .distantPast)   // flush both history consumers
        let afterLines = c2Lines(path).filter { ($0["a"] as? String) == keyA }.map { c2JSON($0) }
        let rows = c2Lines(log).filter { ($0["product"] as? String) == product }
        let rowsB = rows.filter { ($0["age"] as? NSNumber)?.intValue == 60 }
        let rowsA = rows.filter { ($0["label"] as? String) == labelA }
        var consumers = C2Checks()
        consumers.add("journal has reader events", rows.count == 2 && rows.allSatisfy { ($0["ev"] as? String) == "reader_card_state" })
        consumers.add("B age row has null label", rowsB.count == 1 && rowsB.first?["label"] is NSNull)
        consumers.add("independent remote A remains distinct", rowsA.count == 1 && (rowsA.first?["age"] as? NSNumber)?.intValue == 1200)
        consumers.add("A history unchanged after consumers", after.count == before.count
                      && after.map { $0.t } == before.map { $0.t } && after.map { $0.session } == before.map { $0.session }
                      && after.map { $0.weekly } == before.map { $0.weekly } && afterLines == beforeLines)
        consumers.add("no B timestamp under A local key", !after.contains { $0.t == rolloutB.asOf?.timeIntervalSince1970 })
        expect(consumers.failed.isEmpty, "C2-09 \(product): reader_card_state never labels B as A; A local history receives nothing new" + consumers.suffix)

        // Control: a failed attempt without a newer reading really retains A and therefore must retain A's ID.
        let held = readerQuotaCompletion(LimitData(error: "synthetic no newer reading"), previous: first.data,
                                         previousId: initial.ids[product], readingId: idB)
        expect(held.id == idA && held.data.session == apiA.session && held.data.asOf == apiA.asOf && held.data.fromCache,
               "C2-09 \(product): retaining the actual previous A snapshot preserves A's identity")
    }
}

// MARK: runner

/// C2 entry point, called at the end of the `--subscriptions-selftest` block. `select(claude, codex)` sets the `monitor_*`
/// preferences of that block (argument domain of the memory defaults). Returns the number of failed checks; restores
/// `select(true, true)` and removes every key it set.
func runRemoteLimitsC2SelfTests(defaults: MemorySelfTestDefaults, select: (Bool, Bool) -> Void) -> Int {
    var failures = 0, checks = 0
    func expect(_ ok: Bool, _ label: String) {
        checks += 1
        print("\(ok ? "OK" : "FAIL") \(label)")
        if !ok { failures += 1 }
    }
    let root = NSTemporaryDirectory() + "ccl-c2-selftest-" + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    let fixture = c2Fixture("machine-v11-c2.json")
    expect(fixture != nil, "C2 fixtures/remote-limits/machine-v11-c2.json found (pass --rl-fixtures <dir> or CCL_RL_FIXTURES)")
    c2C201(root, fixture, select, expect)
    c2C202(fixture, defaults, select, expect)
    c2C203(fixture, expect)
    c2C204(root, select, expect)
    c2C205(root, fixture, defaults, select, expect)
    c2C206(root, fixture, defaults, select, expect)
    c2C207(fixture, defaults, expect)
    c2C208(root, fixture, expect)
    c2C209(root, expect)
    for key in ["claudeTier", "subClaude", "hiddenAccounts", "menuAccount"] { defaults.removeObject(forKey: key) }
    select(true, true)
    try? FileManager.default.removeItem(atPath: root)
    print(failures == 0 ? "OK C2 remote-limits: all \(checks) checks passed" : "FAIL C2 remote-limits: \(failures) of \(checks) checks failed")
    return failures
}
