import Foundation

// MARK: - REMOTE-LIMITS C1 selftests (tester, 2026-10-18; written red before the code, P13)
//
// Sources of truth: docs/test-plan-remote-limits.md §C1 (C1-01…C1-08, T15/T19/T30/T36), arch/plan-synth.md §A/§B/§F (№12),
// docs/sync-protocol.md v1.1 («Read rules», «Reader limits»), design/remote-limits-ux.md §4 (V5), review A1 (N10, own-file slot).
// Linux reference behaviour (same golden fixtures, same `days`): linux/ccl/accounts.py (label, _text, parse_block),
// linux/ccl/sync.py (merge, MAX_* limits), linux/tests/test_rl_contract*.py.
//
// Isolation (lessons 006/011/012/013): every clock under test is an injected `now`; no network (SelfTestHTTP only), no Keychain
// (ScriptedSyncKeychain in memory), no real defaults (MemorySelfTestDefaults), no HOME. The only file reads are the read-only
// golden fixtures in fixtures/remote-limits/ (see remoteLimitsFixturesDir()).
//
// Registered at the end of the `--sync-selftest` block in LimitsMonitor.swift. Each check prints `OK …` / `FAIL C1-…`; the
// block exits non-zero when any check failed.
//
// Contract these tests compile against (developer: Sources/RemoteLimits.swift + LimitsMonitor.swift; names from synth §F,
// the rest chosen by the tester and listed in the C1 report):
//   func accountLabel(product: String, localId: String, gistId: String) -> String?      // nil: bad product / empty or malformed id / no gist
//   func machineTag(setting: String, hostname: String) -> String                        // [a-z0-9-]{1,16}, default "mac"
//   func mergeV11(_ contents: [String: String], excluding myId: String, now: Date) -> SyncRemoteCache
//   SyncRemoteCache += gistId: String?, accounts: [RemoteAccount]?, captions: [String: RemoteCaption]?,
//                      unattributedDays: [String: [String: [String: DayModelUsage]]]?   (all optional → old caches decode)
//   SyncCachedMachine += lastSeenAt: Date?
//   struct RemoteAccount: Codable { product: String; label: String?; status: String; plan, tier, expiredReason: String?;
//       asOf, attemptAt, retryUntil: Date?; windows: RemoteWindows?; models: [RemoteModel]?; resetCredits: Int?;
//       schedule: RemoteSchedule?; days: [String: [String: DayModelUsage]]; machineId: String; machineName: String;
//       machineLastSeenAt: Date? }
//   struct RemoteWindows { session, weekly: RemoteWindow? }   struct RemoteWindow { pct: Double; resetAt: Date? }
//   struct RemoteModel { name: String; pct: Double; resetAt: Date? }
//   struct RemoteSchedule { mode: String; interval: Int; nextAt: Date?; backoff: Bool? }
//   struct RemoteCaption { text: String; setAt: Date? }
//   struct ReaderSyncState { phase: SyncPhase; warning: String? }
//   func resolveAccounts(local: (LimitData, LimitData), localIds: [String: String], remote: SyncRemoteCache,
//                        hidden: Set<String>, menu: [String: String], sync: ReaderSyncState, now: Date) -> [AccountView]
//   struct AccountView { product: String; label: String?; historyKey: String; caption: String; data: LimitData;
//       isLocal: Bool; tier: String?; usageDays: [String: [String: DayModelUsage]]; machines: [String]; state: RemoteCardState }
//   enum RemoteCardState: Int { 1…7 = UX §4 V5 rows (3a/3b share 3) }
//   LimitData += source: RemoteSource?   struct RemoteSource { machineId, machineName: String; freshUntil: Date?; … synth §F }

private typealias RLExpect = (Bool, String) -> Void
private typealias RLDays = [String: [String: DayModelUsage]]          // day → model → usage
private typealias RLProductDays = [String: RLDays]                     // product → day → model → usage

// Golden identities (fixtures/remote-limits/label-vectors.json; synthetic, no real account).
private let RL_G1 = "fixturegist0000000000000000000001"
private let RL_UUID_A = "3b9d6c1e-8f42-4a7b-9c05-2e6f1d8a4b70"
private let RL_UUID_C = "c0dex000-1111-4222-8333-444455556666"
private let RL_CLAUDE_V11 = "f4b718320ee15b3a"   // label(G1, claude, UUID_A) — the Claude record of machine-v11.json
private let RL_CODEX_V11 = "f683db167afc0b47"    // label(G1, codex, UUID_C) — the Codex record of machine-v11.json
private let RL_CODEX_A = "bed169a4dc4b1b00"      // label(G1, codex, UUID_A) — a second, different Codex account

// MARK: fixtures

/// Where the shared golden fixtures live: `--rl-fixtures <dir>`, else env `CCL_RL_FIXTURES`, else the repository next to the
/// built bundle (`<repo>/dist/<App>.app/Contents/MacOS/<exe>` → `<repo>/fixtures/remote-limits`), else
/// `./fixtures/remote-limits`. Nothing usable → nil, which the runner reports as FAIL (never a silent skip).
func remoteLimitsFixturesDir() -> String? {
    let fm = FileManager.default
    func usable(_ dir: String) -> Bool { fm.fileExists(atPath: dir + "/label-vectors.json") }
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--rl-fixtures") {
        return i + 1 < args.count && usable(args[i + 1]) ? args[i + 1] : nil
    }
    if let env = ProcessInfo.processInfo.environment["CCL_RL_FIXTURES"], !env.isEmpty {
        return usable(env) ? env : nil
    }
    var candidates: [String] = []
    if let exe = Bundle.main.executablePath {
        var url = URL(fileURLWithPath: exe).resolvingSymlinksInPath().deletingLastPathComponent()   // …/Contents/MacOS
        for _ in 0..<4 { url = url.deletingLastPathComponent() }                                     // Contents, .app, dist, repo
        candidates.append(url.path + "/fixtures/remote-limits")
    }
    candidates.append(fm.currentDirectoryPath + "/fixtures/remote-limits")
    return candidates.first(where: usable)
}

private struct RLFixtures {
    let dir: String
    func text(_ name: String) -> String? { try? String(contentsOfFile: dir + "/" + name, encoding: .utf8) }
    func object(_ name: String) -> [String: Any]? {
        guard let t = text(name) else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(t.utf8))) as? [String: Any]
    }
}

// MARK: helpers (pure)

/// Collects sub-check names so one printed line says exactly which part failed.
private struct RLChecks {
    var failed: [String] = []
    mutating func add(_ name: String, _ ok: Bool) { if !ok { failed.append(name) } }
    var suffix: String { failed.isEmpty ? "" : " — failed: " + failed.joined(separator: "; ") }
}

private let rlISOFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()
private func rlDate(_ s: String) -> Date { rlISOFormatter.date(from: s) ?? Date(timeIntervalSince1970: 0) }
private func rlStr(_ d: Date) -> String { rlISOFormatter.string(from: d) }
private func rlPad(_ i: Int, _ width: Int) -> String {
    let s = String(i)
    return String(repeating: "0", count: max(0, width - s.count)) + s
}

private func rlJSON(_ obj: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
}

/// Canonical text of product → day → model counters (order-free comparison; DayModelUsage is not Equatable).
private func rlCanon(_ days: RLProductDays) -> String {
    var out: [String] = []
    for p in days.keys.sorted() {
        let byDay = days[p] ?? [:]
        for d in byDay.keys.sorted() {
            let byModel = byDay[d] ?? [:]
            for m in byModel.keys.sorted() {
                guard let u = byModel[m] else { continue }
                out.append("\(p)|\(d)|\(m)=\(u.input),\(u.output),\(u.cacheRead),\(u.cacheWrite5m),\(u.cacheWrite1h),\(u.turns)")
            }
        }
    }
    return out.joined(separator: ";")
}
private func rlUsage(_ any: Any?) -> DayModelUsage? {
    guard let v = any as? [String: Any] else { return nil }
    func n(_ key: String) -> Int { (v[key] as? NSNumber)?.intValue ?? 0 }
    return DayModelUsage(input: n("input"), output: n("output"), cacheRead: n("cacheRead"),
                         cacheWrite5m: n("cacheWrite5m"), cacheWrite1h: n("cacheWrite1h"), turns: n("turns"))
}
/// Fixture JSON (day → model → counters) parsed by the test itself — the golden side of a comparison.
private func rlJSONDays(_ any: Any?) -> RLDays {
    var out = RLDays()
    for (day, models) in (any as? [String: Any]) ?? [:] {
        for (model, counts) in (models as? [String: Any]) ?? [:] {
            if let u = rlUsage(counts) { out[day, default: [:]][model] = u }
        }
    }
    return out
}
private func rlJSONProductDays(_ any: Any?) -> RLProductDays {
    var out = RLProductDays()
    for (product, days) in (any as? [String: Any]) ?? [:] {
        let clean = rlJSONDays(days)
        if !clean.isEmpty { out[product] = clean }
    }
    return out
}
private func rlAdd(_ target: inout RLProductDays, _ product: String, _ days: RLDays) {
    for (day, models) in days {
        for (model, u) in models {
            var cur = target[product, default: [:]][day, default: [:]][model, default: DayModelUsage()]
            cur.add(u)
            target[product, default: [:]][day, default: [:]][model] = cur
        }
    }
}

/// No Cc/Cf/Cs scalar (control, format incl. bidi/zero-width, lone surrogate).
private func rlControlFree(_ s: String) -> Bool {
    for u in s.unicodeScalars {
        switch u.properties.generalCategory {
        case .control, .format, .surrogate: return false
        default: continue
        }
    }
    return true
}
private func rlHex16(_ s: String?) -> Bool {
    guard let s = s, s.utf8.count == 16 else { return false }
    return s.utf8.allSatisfy(rlHexByte)
}
private func rlHexByte(_ b: UInt8) -> Bool { (b >= 48 && b <= 57) || (b >= 97 && b <= 102) }
private func rlTagByte(_ b: UInt8) -> Bool { (b >= 48 && b <= 57) || (b >= 97 && b <= 122) || b == 45 }

/// One v1.1 account record (synth §A). `label: nil` → JSON null with `labelReason`.
private func rlAcct(_ product: String, _ label: String?, status: String = "ok", asOf: Date? = nil,
                    attemptAt: Date? = nil, pct: Double? = nil, interval: Int? = 900, nextAt: Date? = nil,
                    retryUntil: Date? = nil, tier: String? = nil, days: [String: Any] = [:]) -> [String: Any] {
    var a: [String: Any] = ["product": product, "status": status, "days": days]
    if let l = label { a["label"] = l } else { a["label"] = NSNull(); a["labelReason"] = "no_account_uuid" }
    if let t = asOf { a["asOf"] = rlStr(t) }
    if let t = attemptAt ?? asOf { a["attemptAt"] = rlStr(t); a["attemptKind"] = "auto" }
    if let p = pct { a["windows"] = ["session": ["pct": p], "weekly": ["pct": p]] }
    if let i = interval {
        var s: [String: Any] = ["mode": "auto", "interval": i, "backoff": false]
        if let n = nextAt { s["nextAt"] = rlStr(n) }
        a["schedule"] = s
    }
    if let r = retryUntil { a["retryUntil"] = rlStr(r) } else { a["retryUntil"] = NSNull() }
    if let t = tier { a["plan"] = "max"; a["tier"] = t }
    if status == "expired" { a["expiredReason"] = "cli_refresh_pending" }
    return a
}

/// One machine file. `lastSeenAt`: Date, raw String, or nil (key absent).
private func rlMachineFile(_ id: String, name: String, updated: Date?, lastSeenAt: Any?, accounts: [Any],
                           days: [String: Any] = [:], captions: [String: Any]? = nil) -> String {
    var obj: [String: Any] = ["schema": 1, "tz": "Etc/UTC", "days": days, "accounts": accounts,
                              "machine": ["id": id, "name": name, "os": "Ubuntu 26.04", "app": "linux 0.5.0"]]
    if let u = updated { obj["updated"] = rlStr(u) }
    if let d = lastSeenAt as? Date { obj["lastSeenAt"] = rlStr(d) } else if let s = lastSeenAt as? String { obj["lastSeenAt"] = s }
    if let c = captions { obj["captions"] = c }
    return rlJSON(obj)
}

/// Minimal valid v1 file without `updated` (never ages out against the real clock — lesson 011).
private func rlSmall(_ id: String) -> String {
    "{\"schema\":1,\"machine\":{\"id\":\"\(id)\",\"name\":\"pc-\(id)\",\"os\":\"T\"},\"days\":{}}"
}
/// A valid machine file of exactly `bytes` UTF-8 bytes (ASCII padding).
private func rlPadded(_ id: String, bytes: Int) -> String {
    let head = "{\"schema\":1,\"machine\":{\"id\":\"\(id)\",\"name\":\"pc-\(id)\",\"os\":\"T\"},\"days\":{},\"pad\":\""
    let tail = "\"}"
    return head + String(repeating: "x", count: max(0, bytes - head.utf8.count - tail.utf8.count)) + tail
}

private func rlAbsent() -> LimitData { var d = LimitData(); d.present = false; return d }
private func rlLocal(_ pct: Double, asOf: Date) -> LimitData {
    var d = LimitData(); d.session = pct; d.weekly = pct; d.asOf = asOf; d.apiFresh = true
    return d
}
private func rlCache(_ files: [String: String], now: Date, gist: String? = RL_G1) -> SyncRemoteCache {
    var cache = mergeV11(files, excluding: "selftest-mac", now: now)
    cache.gistId = gist
    return cache
}
private func rlResolve(_ cache: SyncRemoteCache, claude: LimitData = rlAbsent(), codex: LimitData = rlAbsent(),
                       ids: [String: String] = [:], hidden: Set<String> = [], phase: SyncPhase = .on,
                       warning: String? = nil, now: Date) -> [AccountView] {
    resolveAccounts(local: (claude, codex), localIds: ids, remote: cache, hidden: hidden, menu: [:],
                    sync: ReaderSyncState(phase: phase, warning: warning), now: now)
}
private func rlKey(_ v: AccountView) -> String { v.product + ":" + (v.isLocal ? "local" : (v.label ?? "nil")) }

// MARK: C1-01 labels (parity with A1-01)

private func rlC101(_ fx: RLFixtures, _ expect: RLExpect) {
    guard let vectors = fx.object("label-vectors.json")?["vectors"] as? [[String: Any]], !vectors.isEmpty else {
        expect(false, "C1-01 label-vectors.json readable"); return
    }
    var c = RLChecks()
    for (i, v) in vectors.enumerated() {
        guard let gist = v["gist_id"] as? String, let product = v["product"] as? String,
              let local = v["local_id"] as? String, let label = v["label"] as? String else {
            c.add("vector \(i) shape", false); continue
        }
        let got = accountLabel(product: product, localId: local, gistId: gist)
        c.add("vector \(i) \(product) → \(label) (got \(got ?? "nil"))", got == label)
    }
    expect(c.failed.isEmpty, "C1-01 \(vectors.count) label vectors = Linux A1-01 (HMAC-SHA256, strip+lower, key per gist id)" + c.suffix)
    var n = RLChecks()
    n.add("unknown product", accountLabel(product: "gemini", localId: RL_UUID_A, gistId: RL_G1) == nil)
    n.add("blank localId", accountLabel(product: "claude", localId: "  \n", gistId: RL_G1) == nil)
    n.add("no gist id", accountLabel(product: "claude", localId: RL_UUID_A, gistId: "") == nil)
    n.add("localId shorter than 8 (N12)", accountLabel(product: "codex", localId: "abc-123", gistId: RL_G1) == nil)
    n.add("localId outside [0-9a-z-] (N12)", accountLabel(product: "codex", localId: "алекс-0000-1111", gistId: RL_G1) == nil)
    expect(n.failed.isEmpty, "C1-01 no label without a valid product, localId ^[0-9a-z-]{8,64}$ and gist id (sync-protocol «Account label»)" + n.suffix)
}

// MARK: C1-02 reader validation C7, limits, T36

/// Positive control: a valid v1.1 file keeps every contract field (so the hostile checks cannot pass by dropping everything).
private func rlC102Control(_ fx: RLFixtures, _ expect: RLExpect) {
    let now = rlDate("2026-10-12T10:20:00Z")
    guard let v11 = fx.text("machine-v11.json") else { expect(false, "C1-02 machine-v11.json readable"); return }
    let r = mergeV11(["machine-fixturevps.json": v11], excluding: "selftest-mac", now: now)
    let accounts = r.accounts ?? []
    let cl = accounts.first { $0.label == RL_CLAUDE_V11 }
    let cx = accounts.first { $0.label == RL_CODEX_V11 }
    var c = RLChecks()
    c.add("two records", accounts.count == 2)
    c.add("claude product/status", cl?.product == "claude" && cl?.status == "ok")
    c.add("plan/tier", cl?.plan == "max" && cl?.tier == "default_claude_max_20x")
    c.add("asOf", cl?.asOf == rlDate("2026-10-12T10:15:02Z"))
    c.add("attemptAt", cl?.attemptAt == rlDate("2026-10-12T10:15:00Z"))
    c.add("retryUntil null", cl?.retryUntil == nil)
    c.add("session 42.5", cl?.windows?.session?.pct == 42.5)
    c.add("session resetAt", cl?.windows?.session?.resetAt == rlDate("2026-10-12T13:00:00Z"))
    c.add("weekly 61", cl?.windows?.weekly?.pct == 61)
    c.add("models", (cl?.models ?? []).map { $0.name } == ["Fable 5.1"])
    c.add("model pct", cl?.models?.first?.pct == 70.2)
    c.add("schedule", cl?.schedule?.mode == "auto" && cl?.schedule?.interval == 900)
    c.add("schedule nextAt/backoff", cl?.schedule?.nextAt == rlDate("2026-10-12T10:30:00Z") && cl?.schedule?.backoff == false)
    c.add("source machine", cl?.machineId == "fixturevps" && cl?.machineName == "vps")
    c.add("machineLastSeenAt", cl?.machineLastSeenAt == rlDate("2026-10-12T10:15:03Z"))
    c.add("codex expired + reason", cx?.status == "expired" && cx?.expiredReason == "cli_refresh_pending")
    c.add("codex resetCredits 2", cx?.resetCredits == 2)
    c.add("codex schedule 3600 backoff", cx?.schedule?.interval == 3600 && cx?.schedule?.backoff == true)
    c.add("caption", r.captions?[RL_CLAUDE_V11]?.text == "команда")
    c.add("caption setAt", r.captions?[RL_CLAUDE_V11]?.setAt == rlDate("2026-10-12T09:00:00Z"))
    c.add("machine lastSeenAt", r.machines.first?.lastSeenAt == rlDate("2026-10-12T10:15:03Z"))
    c.add("machine name", r.machines.first?.name == "vps")
    expect(c.failed.isEmpty, "C1-02 (control) valid machine-v11.json: every v1.1 field parsed" + c.suffix)
}

/// (a) pct types, (b) times, (d) projection — machine-v11-hostile.json, same expectations as Linux A1-13 (7 records, 64 captions).
private func rlC102Hostile(_ fx: RLFixtures, _ expect: RLExpect) {
    let now = rlDate("2026-10-12T10:20:00Z")
    guard let text = fx.text("machine-v11-hostile.json"), let obj = fx.object("machine-v11-hostile.json") else {
        expect(false, "C1-02 machine-v11-hostile.json readable"); return
    }
    let r = mergeV11(["machine-fixturehostile.json": text], excluding: "selftest-mac", now: now)
    expect(r.machines.map { $0.id } == ["fixturehostile"], "C1-02 hostile file accepted: a broken accounts block never drops the file")
    let accounts = r.accounts ?? []
    func by(_ label: String) -> [RemoteAccount] { accounts.filter { $0.label == label } }
    var c = RLChecks()
    c.add("7 valid records like Linux (got \(accounts.count))", accounts.count == 7)
    let dup = by("3f3cddd81d01cbc1")
    c.add("duplicate (product,label) collapses", dup.count == 1)
    c.add("latest asOf wins the duplicate", dup.first?.asOf == rlDate("2026-10-12T09:00:00Z"))
    c.add("pct \"80\" (string) drops session", dup.first?.windows?.session == nil)
    c.add("pct true drops weekly", dup.first?.windows?.weekly == nil)
    c.add("pct 140 / -1 drop models, 50 kept", (dup.first?.models ?? []).map { $0.name } == ["good"])
    c.add("unknown status → error", by("096a000501ef4d26").map { $0.status } == ["error"])
    c.add("no product → dropped", by("b2b80a9a754a3504").isEmpty)
    c.add("no status → dropped", by("1baf291a0b06bec3").isEmpty)
    c.add("label not 16 hex → nil, record kept", accounts.contains { $0.product == "codex" && $0.label == nil })
    c.add("every label nil or 16 hex", accounts.allSatisfy { $0.label == nil || rlHex16($0.label) })
    let times = by("0c6a3278daa4d3c7")
    c.add("broken times drop fields, not the record", times.count == 1)
    c.add("asOf year 99999 → nil (T36)", times.first?.asOf == nil)
    c.add("attemptAt month 13 → nil", times.first?.attemptAt == nil)
    c.add("retryUntil +99:00 → nil (T36)", times.first?.retryUntil == nil)
    c.add("resetAt «yesterday» → nil, pct 5 kept", times.first?.windows?.session?.pct == 5 && times.first?.windows?.session?.resetAt == nil)
    c.add("models > 8 → tail dropped", (by("0e76decc35b4f8e5").first?.models ?? []).map { $0.name } == ["m0", "m1", "m2", "m3", "m4", "m5", "m6", "m7"])
    let long = by("b0664b3aae9d0ba6")
    c.add("long/control record kept", long.count == 1)
    c.add("plan > 64 → dropped", long.first?.plan == nil)
    c.add("tier with U+202E → dropped", long.first?.tier == nil)
    c.add("expiredReason outside enum → dropped", long.first?.expiredReason == nil)
    c.add("model names: ESC and > 48 dropped, plain text kept", (long.first?.models ?? []).count == 1)
    let misc = by("29c63ba48d6b4610")
    c.add("resetCredits 5000 → dropped", misc.first?.resetCredits == nil)
    c.add("schedule turbo/1234/never/\"yes\" → dropped", misc.first?.schedule == nil)
    for a in accounts {
        var strings = [a.product, a.status]
        if let s = a.plan { strings.append(s) }
        if let s = a.tier { strings.append(s) }
        if let s = a.expiredReason { strings.append(s) }
        for m in a.models ?? [] { strings.append(m.name) }
        c.add("strings clean in \(a.label ?? "nil")", strings.allSatisfy { rlControlFree($0) && $0.unicodeScalars.count <= 64 })
        var pcts: [Double] = []
        if let p = a.windows?.session?.pct { pcts.append(p) }
        if let p = a.windows?.weekly?.pct { pcts.append(p) }
        for m in a.models ?? [] { pcts.append(m.pct) }
        c.add("pct finite 0…100 in \(a.label ?? "nil")", pcts.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 100 })
        c.add("models ≤ 8 in \(a.label ?? "nil")", (a.models ?? []).count <= 8)
        if let i = a.schedule?.interval { c.add("interval in contract set", [900, 1800, 3600, 14400].contains(i)) }
        if let n = a.resetCredits { c.add("resetCredits 0…1000", (0...1000).contains(n)) }
    }
    let m = r.machines.first
    c.add("machine.name with ESC/OSC → dropped («?»)", m?.name == "?")
    c.add("machine.os with U+202E → dropped", m?.os == "")
    c.add("file lastSeenAt «garbage» → nil", m?.lastSeenAt == nil)
    let caps = r.captions ?? [:]
    c.add("captions capped at 64 (got \(caps.count))", caps.count == 64)
    c.add("caption keys 16 hex (NOTHEX dropped)", caps.keys.allSatisfy { rlHex16($0) })
    c.add("caption with NUL/U+202E dropped whole", caps["3f3cddd81d01cbc1"] == nil)
    c.add("caption texts clean ≤ 32", caps.values.allSatisfy { rlControlFree($0.text) && $0.text.unicodeScalars.count <= 32 })
    let root = rlJSONProductDays(obj["days"])
    var split = RLProductDays()
    for a in accounts { rlAdd(&split, a.product, a.days) }
    for (p, d) in r.unattributedDays ?? [:] { rlAdd(&split, p, d) }
    c.add("T19 Σ accounts[].days + unattributedDays == root, per product", rlCanon(split) == rlCanon(root))
    c.add("T19 projection mismatch → whole root usage «не указан», account days not added",
          accounts.allSatisfy { $0.days.isEmpty } && rlCanon(r.unattributedDays ?? [:]) == rlCanon(root))
    c.add("root days intact (v1 rules)", rlCanon(r.days) == rlCanon(root))
    expect(c.failed.isEmpty, "C1-02(a,b,d) hostile v1.1 block validated record by record (C7, T15, T19, П5-е)" + c.suffix)
    var cache = r
    cache.gistId = RL_G1
    let views = rlResolve(cache, now: now)
    expect(views.allSatisfy { !$0.isLocal && $0.label != nil } && views.count <= 7,
           "C1-02 hostile cache → resolver draws only labelled cards, no crash (got \(views.count))")
}

/// Not strict JSON (NaN/Infinity/1e400) and lone surrogates (README: Swift JSONSerialization may reject the whole file).
private func rlC102NonStrict(_ fx: RLFixtures, _ expect: RLExpect) {
    let now = rlDate("2026-10-12T10:20:00Z")
    if let text = fx.text("machine-v11-nonfinite.json") {
        let r = mergeV11(["machine-fixturenonfinite.json": text], excluding: "selftest-mac", now: now)
        let accounts = (r.accounts ?? []).filter { $0.machineId == "fixturenonfinite" }
        let clean = accounts.allSatisfy { $0.windows?.session == nil && $0.windows?.weekly == nil && ($0.models ?? []).isEmpty }
        let accepted = r.machines.contains { $0.id == "fixturenonfinite" }
        expect(clean, "C1-02(a) NaN/Infinity/1e400: " + (accepted ? "file merged, every non-finite pct dropped" : "non-strict JSON rejected whole, no crash"))
    } else {
        expect(false, "C1-02 machine-v11-nonfinite.json readable")
    }
    if let text = fx.text("machine-v11-surrogate.json") {
        let r = mergeV11(["machine-fixturesurrogate.json": text], excluding: "selftest-mac", now: now)
        let only7 = rlCanon(["claude": ["2026-10-12": ["claude-fable-5-1": DayModelUsage(input: 7, output: 1, turns: 1)]]])
        var c = RLChecks()
        if let m = r.machines.first(where: { $0.id == "fixturesurrogate" }) {
            c.add("only the clean entry counted (no 100/200/300 from surrogate keys)", rlCanon(r.days) == only7)
            c.add("name/os without U+FFFD or Cs", rlControlFree(m.name + m.os) && !(m.name + m.os).contains("\u{FFFD}"))
        } else {
            c.add("file rejected whole → nothing merged", rlCanon(r.days).isEmpty)
        }
        expect(c.failed.isEmpty, "C1-02 lone surrogates (A1-16 parity): never merged as text or keys" + c.suffix)
    } else {
        expect(false, "C1-02 machine-v11-surrogate.json readable")
    }
}

/// (e) T36: year 99999, `+99:00`, 10⁶ fraction digits are dropped; ordinary fraction and offset are parsed (Linux parse_iso).
private func rlC102T36(_ expect: RLExpect) {
    let now = rlDate("2026-10-12T10:20:00Z")
    let longFraction = "2026-10-12T10:00:00." + String(repeating: "1", count: 1_000_000) + "Z"
    let session: [String: Any] = ["pct": 5, "resetAt": longFraction]
    let weekly: [String: Any] = ["pct": 6, "resetAt": "2026-10-15T07:00:00.123Z"]
    let schedule: [String: Any] = ["mode": "auto", "interval": 900, "nextAt": "2026-10-12T13:15:00+03:00", "backoff": false]
    let record: [String: Any] = ["product": "codex", "label": "1234567890abcdef", "status": "ok",
                                 "asOf": "99999-01-01T00:00:00Z", "attemptAt": "2026-10-12T10:00:00+99:00",
                                 "retryUntil": longFraction, "windows": ["session": session, "weekly": weekly],
                                 "schedule": schedule, "days": [String: Any]()]
    let file = rlMachineFile("fixturet36", name: "t36", updated: rlDate("2026-10-12T10:00:00Z"),
                             lastSeenAt: "99999-01-01T00:00:00Z", accounts: [record])
    let r = mergeV11(["machine-fixturet36.json": file], excluding: "selftest-mac", now: now)
    let a = (r.accounts ?? []).first { $0.label == "1234567890abcdef" }
    var c = RLChecks()
    c.add("record kept (4 KB metadata cap applies after dropping bad fields)", a != nil)
    c.add("asOf year 99999 → nil", a?.asOf == nil)
    c.add("attemptAt +99:00 → nil", a?.attemptAt == nil)
    c.add("retryUntil with 10^6 fraction digits → nil", a?.retryUntil == nil)
    c.add("resetAt with 10^6 fraction digits → nil, pct kept", a?.windows?.session?.pct == 5 && a?.windows?.session?.resetAt == nil)
    let weeklyReset: Date? = a?.windows?.weekly?.resetAt
    let fractionOK = weeklyReset.map { abs($0.timeIntervalSince(rlDate("2026-10-15T07:00:00Z")) - 0.123) < 0.002 } ?? false
    c.add("control: .123Z fraction parsed", fractionOK)
    c.add("control: +03:00 offset parsed", a?.schedule?.nextAt == rlDate("2026-10-12T10:15:00Z"))
    c.add("file lastSeenAt year 99999 → nil", r.machines.first?.lastSeenAt == nil)
    c.add("file still merged", r.machines.map { $0.id } == ["fixturet36"])
    expect(c.failed.isEmpty, "C1-02(e) T36: dates with year 99999 / +99:00 / 10^6 fraction digits dropped as fields" + c.suffix)
}

/// Caption vectors at the reader (sanitize-vectors.json) and П5-е root `days` keys.
private func rlC102Strings(_ fx: RLFixtures, _ expect: RLExpect) {
    let now = rlDate("2026-10-12T10:20:00Z")
    guard let vectors = fx.object("sanitize-vectors.json")?["caption"] as? [[String: Any]], !vectors.isEmpty else {
        expect(false, "C1-02 sanitize-vectors.json readable"); return
    }
    var captions: [String: Any] = [:]
    var expected: [(label: String, text: String, ok: Bool?)] = []
    for (i, v) in vectors.enumerated() where i < 16 {
        guard let text = v["text"] as? String else { continue }
        let label = "ccccccccccccccc" + String(i, radix: 16)
        captions[label] = ["text": text, "setAt": "2026-10-12T09:00:00Z"]
        expected.append((label: label, text: text, ok: v["ok"] as? Bool))
    }
    let counts: [String: Int] = ["input": 1, "output": 0, "cacheRead": 0, "cacheWrite5m": 0, "cacheWrite1h": 0, "turns": 1]
    let claudeDays: [String: [String: [String: Int]]] = [
        "2026-10-12": ["claude-fable-5-1": counts, "\u{1B}[2Jevil": counts, "bi\u{202E}di": counts, "zw\u{200B}sp": counts],
        "2026-10-\u{200B}11": ["claude-fable-5-1": counts]]
    let codexDays: [String: [String: [String: Int]]] = ["2026-10-12": ["gpt-6-astra": counts]]
    let days: [String: Any] = ["claude": claudeDays, "codex\u{200B}": codexDays]
    let file = rlMachineFile("fixturestrings", name: "strings", updated: now, lastSeenAt: now, accounts: [],
                             days: days, captions: captions)
    let r = mergeV11(["machine-fixturestrings.json": file], excluding: "selftest-mac", now: now)
    let caps = r.captions ?? [:]
    var c = RLChecks()
    for e in expected {
        let got = caps[e.label]?.text
        let safe = rlControlFree(e.text) && e.text.unicodeScalars.count <= 32
        if e.ok == true { c.add("caption kept: \(e.label)", got == e.text.precomposedStringWithCanonicalMapping) }
        if !safe { c.add("unsafe caption dropped whole (never cleaned): \(e.label)", got == nil) }
        if let g = got { c.add("kept caption clean: \(e.label)", rlControlFree(g) && g.unicodeScalars.count <= 32) }
    }
    let want = rlCanon(["claude": ["2026-10-12": ["claude-fable-5-1": DayModelUsage(input: 1, turns: 1)]]])
    c.add("П5-е: Cc/Cf in a product/day/model key of root days → that entry skipped", rlCanon(r.days) == want)
    expect(c.failed.isEmpty, "C1-02 strings: caption vectors at the reader (Cc/Cf/> 32 dropped whole), root-days keys (П4-в, П5-е)" + c.suffix)
}

/// (c) reader limits on contents — pure. Own file takes one of 64 slots (review A1 p. 1), 8 MiB per file, 64 MiB total,
/// first 64 raw `accounts` elements, ≤ 8 records.
private func rlC102Limits(_ expect: RLExpect) {
    let now = rlDate("2026-10-12T10:20:00Z")
    let mib = 1024 * 1024
    var slot: [String: String] = ["machine-0000-self.json": rlSmall("0000-self")]
    for i in 0..<64 { let id = "m" + rlPad(i, 2); slot["machine-\(id).json"] = rlSmall(id) }
    let s = mergeV11(slot, excluding: "0000-self", now: now)
    expect(s.machines.map { $0.id }.sorted() == (0..<63).map { "m" + rlPad($0, 2) },
           "C1-02(c) 65 files, own sorts first: own file takes 1 of 64 slots → m00…m62 merged (got \(s.machines.count))")
    var hundred: [String: String] = [:]
    for i in 0..<100 { let id = "n" + rlPad(i, 3); hundred["machine-\(id).json"] = rlSmall(id) }
    let h = mergeV11(hundred, excluding: "selftest-mac", now: now)
    expect(h.machines.map { $0.id }.sorted() == (0..<64).map { "n" + rlPad($0, 3) },
           "C1-02(c) 100 machine files → the first 64 by file name merged (got \(h.machines.count))")
    let sized = mergeV11(["machine-big.json": rlPadded("big", bytes: 8 * mib),
                          "machine-over.json": rlPadded("over", bytes: 8 * mib + 1),
                          "machine-aa.json": rlSmall("aa")], excluding: "selftest-mac", now: now)
    expect(Set(sized.machines.map { $0.id }) == ["aa", "big"],
           "C1-02(c) file of exactly 8 MiB accepted, 8 MiB + 1 byte skipped, the rest merged")
    var heavy: [String: String] = [:]
    for i in 0..<9 { heavy["machine-r\(i).json"] = rlPadded("r\(i)", bytes: 7 * mib + mib / 2) }
    let budget = mergeV11(heavy, excluding: "selftest-mac", now: now)
    expect(budget.machines.map { $0.id }.sorted() == (0..<8).map { "r\($0)" },
           "C1-02(c) 9 × 7.5 MiB: total budget 64 MiB → r0…r7 merged, r8 not read (got \(budget.machines.count))")
    var junk: [Any] = Array(repeating: 42, count: 64)
    junk.append(rlAcct("claude", RL_CLAUDE_V11, asOf: now, pct: 10))
    let late = mergeV11(["machine-late.json": rlMachineFile("late", name: "late", updated: now, lastSeenAt: now, accounts: junk)],
                        excluding: "selftest-mac", now: now)
    expect((late.accounts ?? []).isEmpty && late.machines.count == 1,
           "C1-02(c) only the first 64 raw accounts elements are examined: a valid 65th is ignored, the file is kept")
    let twelve: [Any] = (0..<12).map { rlAcct("codex", "ddddddddddddddd" + String($0, radix: 16), asOf: now, pct: 1) }
    let capped = mergeV11(["machine-twelve.json": rlMachineFile("twelve", name: "twelve", updated: now, lastSeenAt: now,
                                                                accounts: twelve)], excluding: "selftest-mac", now: now)
    expect((capped.accounts ?? []).count == 8, "C1-02(c) 12 valid records in one file → 8 kept (got \((capped.accounts ?? []).count))")
}

/// (c) the same limits through the real sync cycle (SelfTestHTTP gist, in-memory Keychain/defaults). The fake transport hands
/// over whole bodies, so «read stops at cap + 1 from the socket» is NOT proven here (gap in the C1 report).
private func rlC102SyncLimits(_ defaults: MemorySelfTestDefaults, _ root: String, _ expect: RLExpect) {
    let gid = "rl-gist"
    let gistURL = "https://api.github.com/gists/" + gid
    let rawBase = "https://gist.githubusercontent.com/u/rl-gist/raw/abc/"
    let mib = 1024 * 1024
    func run(_ myId: String, _ files: [String: Any], raw: [String: Data] = [:]) -> GitHubSync {
        defaults.clear()
        defaults.set("selftest-login", forKey: "syncLogin")
        defaults.set(gid, forKey: "syncGistId")
        defaults.set(Date(), forKey: "syncDiscoveredAt")
        var all = files
        all[SYNC_MANIFEST] = ["content": "{}"]
        all["machine-\(myId).json"] = ["content": "{}"]
        let gist: [String: Any] = ["id": gid, "public": false, "created_at": "2026-01-01T00:00:00Z", "files": all]
        let body = (try? JSONSerialization.data(withJSONObject: gist)) ?? Data()
        let http = SelfTestHTTP { c in
            if c.url == gistURL && c.method == "GET" { return (200, body, nil, [:]) }
            if c.url == gistURL && c.method == "PATCH" { return (200, Data("{}".utf8), nil, [:]) }
            if c.method == "GET", let data = raw[c.url] { return (200, data, nil, [:]) }
            return (599, nil, nil, [:])
        }
        let sync = GitHubSync(transport: http.transport, keychain: ScriptedSyncKeychain(store: SelfTestKeychainStore("rl-selftest-token")),
                              defaults: defaults, remotePath: root + "/rl-remote-\(myId).json", machineId: myId,
                              revokeRecheckDelay: 0)
        sync.syncSynchronously()
        return sync
    }
    func others(_ s: GitHubSync) -> [String] { s.ui.machines.filter { !$0.isSelf }.map { $0.name }.sorted() }
    let aa: [String: Any] = ["content": rlSmall("aa")]
    let big: [String: Any] = ["truncated": true, "raw_url": rawBase + "machine-big.json", "content": ""]

    let exact = run("selftest-mac", ["machine-aa.json": aa, "machine-big.json": big],
                    raw: [rawBase + "machine-big.json": Data(rlPadded("big", bytes: 8 * mib).utf8)])
    expect(others(exact) == ["pc-aa", "pc-big"] && exact.ui.lastError == nil, "C1-02(c) sync: raw_url body of exactly 8 MiB accepted")

    let over = run("selftest-mac", ["machine-aa.json": aa, "machine-big.json": big],
                   raw: [rawBase + "machine-big.json": Data(rlPadded("big", bytes: 8 * mib + 1).utf8)])
    var c = RLChecks()
    c.add("over-cap file skipped", !others(over).contains("pc-big"))
    c.add("other files still merged", others(over).contains("pc-aa"))
    c.add("visible error «слишком большой…»", over.ui.lastError != nil)
    c.add("last success time advances", defaults.object(forKey: "syncLastOkAt") != nil)
    expect(c.failed.isEmpty, "C1-02(c) sync: raw_url body of 8 MiB + 1 → that file skipped like invalid JSON, rest merged, error visible" + c.suffix)

    let huge = run("selftest-mac", ["machine-aa.json": aa, "machine-huge.json": ["content": rlPadded("huge", bytes: 20 * mib)]])
    expect(!others(huge).contains("pc-huge") && huge.ui.lastError != nil,
           "C1-02(c) sync: GET /gists/{id} body of 20 MiB (> 16 MiB) never merged, error visible, no crash")

    var hundred: [String: Any] = [:]
    for i in 0..<100 { let id = "m" + rlPad(i, 3); hundred["machine-\(id).json"] = ["content": rlSmall(id)] }
    let many = run("0000-self", hundred)
    expect(others(many) == (0..<63).map { "pc-m" + rlPad($0, 3) },
           "C1-02(c) sync: 100 files, own file first by name → it takes 1 of 64 slots, 63 others merged (got \(others(many).count))")

    defaults.clear()
    for id in ["selftest-mac", "0000-self"] { try? FileManager.default.removeItem(atPath: root + "/rl-remote-\(id).json") }
}

// MARK: C1-03 old file vs new file → same days (C1 compatibility, golden)

private func rlC103(_ fx: RLFixtures, _ expect: RLExpect) {
    let now = rlDate("2026-10-12T10:20:00Z")
    guard let v11 = fx.text("machine-v11.json"), let v10 = fx.text("machine-v10.json"),
          let obj = fx.object("machine-v11.json") else { expect(false, "C1-03 machine-v10/v11.json readable"); return }
    let golden = rlCanon(rlJSONProductDays(obj["days"]))
    let oldA = GitHubSync.merge(["machine-fixturevps.json": v11], excluding: "selftest-mac", now: now)
    let oldB = GitHubSync.merge(["machine-fixturevps.json": v10], excluding: "selftest-mac", now: now)
    expect(!golden.isEmpty && rlCanon(oldA.days) == golden && rlCanon(oldB.days) == golden,
           "C1-03 existing GitHubSync.merge (3.2.7 reader): v1.1 file == v1.0 file == golden root days")
    let newA = mergeV11(["machine-fixturevps.json": v11], excluding: "selftest-mac", now: now)
    let newB = mergeV11(["machine-fixturevps.json": v10], excluding: "selftest-mac", now: now)
    var c = RLChecks()
    c.add("v1.1 days == golden", rlCanon(newA.days) == golden)
    c.add("v1.0 days == golden", rlCanon(newB.days) == golden)
    c.add("both files merged as one machine", newA.machines.map { $0.id } == ["fixturevps"] && newB.machines.map { $0.id } == ["fixturevps"])
    var split = RLProductDays()
    for a in newA.accounts ?? [] { rlAdd(&split, a.product, a.days) }
    for (p, d) in newA.unattributedDays ?? [:] { rlAdd(&split, p, d) }
    c.add("v1.1 split Σ accounts[].days + unattributedDays == root (either split or root, never both)", rlCanon(split) == golden)
    c.add("v1.0 file has no accounts", (newB.accounts ?? []).isEmpty)
    c.add("v1.0 file: no lastSeenAt", newB.machines.first?.lastSeenAt == nil)
    expect(c.failed.isEmpty, "C1-03 mergeV11: machine-v11.json and machine-v10.json give the same days (F2, golden = Linux A1-09)" + c.suffix)
}

// MARK: C1-04 resolver: grouping, V3, N10, V2

private func rlC104(_ fx: RLFixtures, _ expect: RLExpect) {
    let now = rlDate("2026-10-12T10:20:00Z")
    guard let v11 = fx.text("machine-v11.json"), let obj = fx.object("machine-v11.json") else {
        expect(false, "C1-04 machine-v11.json readable"); return
    }
    let records = (obj["accounts"] as? [[String: Any]]) ?? []
    let claudeDays = rlJSONDays(records.first(where: { ($0["product"] as? String) == "claude" })?["days"])
    let vps = ["machine-fixturevps.json": v11]
    let base = rlCache(vps, now: now)
    let mine = rlLocal(10, asOf: now.addingTimeInterval(-60))

    let one = rlResolve(base, codex: mine, ids: ["codex": RL_UUID_C], now: now).filter { $0.product == "codex" }
    var a = RLChecks()
    a.add("one card (got \(one.count))", one.count == 1)
    a.add("it is the local account", one.first?.isLocal == true)
    a.add("label = the VPS label", one.first?.label == RL_CODEX_V11)
    a.add("machines include vps", one.first?.machines.contains("vps") == true)
    a.add("newer local reading shown (V3)", one.first?.data.session == 10 && one.first?.data.source == nil)
    expect(a.failed.isEmpty, "C1-04 one Codex account on the Mac and on vps → one card «Codex · mac, vps» (F1, G4)" + a.suffix)

    let two = rlResolve(base, codex: mine, ids: ["codex": RL_UUID_A], now: now).filter { $0.product == "codex" }
    var b = RLChecks()
    b.add("two cards, local first (got \(two.map(rlKey)))", two.map(rlKey) == ["codex:local", "codex:" + RL_CODEX_V11])
    b.add("local label = HMAC(localId) under remote.gistId", two.first?.label == RL_CODEX_A)
    b.add("vps card keeps its own data", two.last?.data.source?.machineName == "vps")
    b.add("vps card state 3 (source expired)", two.last?.state.rawValue == 3)
    expect(b.failed.isEmpty, "C1-04 two different Codex accounts → two cards (F1, RL-18)" + b.suffix)

    let cl = rlResolve(base, now: now).filter { $0.product == "claude" }
    var c = RLChecks()
    c.add("one remote card", cl.count == 1 && cl.first?.isLocal == false)
    c.add("label", cl.first?.label == RL_CLAUDE_V11)
    c.add("historyKey = label", cl.first?.historyKey == RL_CLAUDE_V11)
    c.add("values from vps", cl.first?.data.session == 42.5 && cl.first?.data.weekly == 61)
    c.add("sessionReset", cl.first?.data.sessionReset == rlDate("2026-10-12T13:00:00Z"))
    c.add("asOf", cl.first?.data.asOf == rlDate("2026-10-12T10:15:02Z"))
    c.add("tier from the snapshot (not local claudeTier)", cl.first?.tier == "default_claude_max_20x")
    c.add("source vps", cl.first?.data.source?.machineName == "vps" && cl.first?.data.source?.machineId == "fixturevps")
    c.add("caption from captions", cl.first?.caption == "команда")
    c.add("state 1 fresh", cl.first?.state.rawValue == 1)
    c.add("usage = its account days", rlCanon(["claude": cl.first?.usageDays ?? [:]]) == rlCanon(["claude": claudeDays]))
    expect(c.failed.isEmpty, "C1-04 Claude only on vps → its card on the Mac without a local Claude (RL-13)" + c.suffix)

    func merged(_ extra: [String: String]) -> SyncRemoteCache { rlCache(vps.merging(extra) { first, _ in first }, now: now) }
    func alse(_ record: [String: Any]) -> [String: String] {
        let seen = now.addingTimeInterval(-60)
        return ["machine-fixturealse.json": rlMachineFile("fixturealse", name: "alse", updated: seen, lastSeenAt: seen, accounts: [record])]
    }
    func claudeCard(_ cache: SyncRemoteCache, local: LimitData = rlAbsent(), ids: [String: String] = [:]) -> [AccountView] {
        rlResolve(cache, claude: local, ids: ids, now: now).filter { $0.product == "claude" }
    }
    let newer = claudeCard(merged(alse(rlAcct("claude", RL_CLAUDE_V11, asOf: rlDate("2026-10-12T10:18:00Z"), pct: 55,
                                              nextAt: rlDate("2026-10-12T10:33:00Z")))))
    var d = RLChecks()
    d.add("one card", newer.count == 1)
    d.add("latest asOf (alse) wins", newer.first?.data.session == 55 && newer.first?.data.source?.machineName == "alse")
    d.add("both machines listed", Set(newer.first?.machines ?? []) == ["vps", "alse"])
    let older = claudeCard(merged(alse(rlAcct("claude", RL_CLAUDE_V11, asOf: rlDate("2026-10-12T10:00:00Z"), pct: 55,
                                              nextAt: rlDate("2026-10-12T10:15:00Z")))))
    d.add("older alse reading loses to vps", older.first?.data.session == 42.5 && older.first?.data.source?.machineName == "vps")
    expect(d.failed.isEmpty, "C1-04 V3: one account on two machines → one card, latest successful asOf wins" + d.suffix)

    let failed = claudeCard(merged(alse(rlAcct("claude", RL_CLAUDE_V11, status: "error", attemptAt: rlDate("2026-10-12T10:19:00Z")))))
    expect(failed.count == 1 && failed.first?.data.session == 42.5 && failed.first?.data.source?.machineName == "vps",
           "C1-04 a failed attempt newer than a success never replaces the successful values (C3/C4)")
    let expired = claudeCard(merged(alse(rlAcct("claude", RL_CLAUDE_V11, status: "expired", asOf: rlDate("2026-10-12T08:00:00Z"),
                                                attemptAt: rlDate("2026-10-12T10:19:00Z"), pct: 99))))
    expect(expired.first?.data.session == 42.5, "C1-04 an expired source with an older asOf keeps the vps values")
    expect(expired.first?.state.rawValue == 3,
           "C1-04 …but the newer failure's status shows in V5 (test plan C1-04; got \(expired.first.map { String($0.state.rawValue) } ?? "no card"))")

    let tieAt = now.addingTimeInterval(-120)
    let tieFile = ["machine-fixturevps.json": rlMachineFile("fixturevps", name: "vps", updated: now.addingTimeInterval(-60),
        lastSeenAt: now.addingTimeInterval(-60), accounts: [rlAcct("codex", RL_CODEX_V11, asOf: tieAt, pct: 77)])]
    let tie = rlResolve(rlCache(tieFile, now: now), codex: rlLocal(10, asOf: tieAt), ids: ["codex": RL_UUID_C], now: now)
        .filter { $0.product == "codex" }
    expect(tie.count == 1 && tie.first?.data.session == 10 && tie.first?.data.source == nil,
           "C1-04 V3 tie: equal asOf → the local reading wins")

    let farFuture = rlDate("2099-01-01T00:00:00Z")
    let n10File = ["machine-fixturevps.json": rlMachineFile("fixturevps", name: "vps", updated: now.addingTimeInterval(-60),
        lastSeenAt: now.addingTimeInterval(-60), accounts: [rlAcct("codex", RL_CODEX_V11, asOf: farFuture, pct: 99)])]
    let n10 = rlResolve(rlCache(n10File, now: now), codex: mine, ids: ["codex": RL_UUID_C], now: now).filter { $0.product == "codex" }
    expect(n10.count == 1 && n10.first?.data.session == 10 && n10.first?.data.source == nil,
           "C1-04 N10: a foreign record with asOf 2099 never wins the card over the local fresh reading")
    let n10Remote = claudeCard(merged(alse(rlAcct("claude", RL_CLAUDE_V11, asOf: farFuture, pct: 99))))
    expect(n10Remote.first?.data.session == 42.5 && n10Remote.first?.data.source?.machineName == "vps",
           "C1-04 N10: asOf > now + 5 min never wins over a record with a correct asOf (security A1 T2)")

    let seen = now.addingTimeInterval(-60)
    let order: [Any] = [rlAcct("codex", "aaaaaaaaaaaaaaa1", asOf: seen, pct: 1), rlAcct("claude", RL_CLAUDE_V11, asOf: seen, pct: 1),
                        rlAcct("codex", "bbbbbbbbbbbbbbb2", asOf: seen, pct: 1), rlAcct("codex", "aaaaaaaaaaaaaaa2", asOf: seen, pct: 1),
                        rlAcct("codex", "bbbbbbbbbbbbbbb1", asOf: seen, pct: 1)]
    let orderCaptions: [String: Any] = [RL_CLAUDE_V11: ["text": "zeta"], "aaaaaaaaaaaaaaa1": ["text": "beta"],
                                        "aaaaaaaaaaaaaaa2": ["text": "Alpha"], "bbbbbbbbbbbbbbb1": ["text": "gamma"],
                                        "bbbbbbbbbbbbbbb2": ["text": "gamma"]]
    let orderCache = rlCache(["machine-fixturevps.json": rlMachineFile("fixturevps", name: "vps", updated: seen, lastSeenAt: seen,
                                                                       accounts: order, captions: orderCaptions)], now: now)
    let local = rlLocal(10, asOf: seen)
    let ordered = rlResolve(orderCache, codex: local, ids: ["codex": RL_UUID_A], now: now).map(rlKey)
    let wantOrder = ["claude:" + RL_CLAUDE_V11, "codex:local", "codex:aaaaaaaaaaaaaaa2", "codex:aaaaaaaaaaaaaaa1",
                     "codex:bbbbbbbbbbbbbbb1", "codex:bbbbbbbbbbbbbbb2"]
    expect(ordered == wantOrder, "C1-04 V2 order: Claude, then Codex; local first, then caption case-insensitive, tie by label (got \(ordered))")
    let hidden = rlResolve(orderCache, codex: local, ids: ["codex": RL_UUID_A], hidden: ["aaaaaaaaaaaaaaa1"], now: now).map(rlKey)
    expect(hidden == wantOrder.filter { $0 != "codex:aaaaaaaaaaaaaaa1" }, "C1-04 hidden label has no card (N1); the rest keep V2 order")
}

// MARK: C1-05 V7: usage without a label has no card

private func rlC105(_ fx: RLFixtures, _ expect: RLExpect) {
    let now = rlDate("2026-10-12T10:20:00Z")
    guard let v11 = fx.text("machine-v11.json"), let obj = fx.object("machine-v11.json") else {
        expect(false, "C1-05 machine-v11.json readable"); return
    }
    let records = (obj["accounts"] as? [[String: Any]]) ?? []
    let codexDays = rlJSONDays(records.first(where: { ($0["product"] as? String) == "codex" })?["days"])
    let legacy = "{\"schema\":1,\"machine\":{\"id\":\"fixturethinkpad\",\"name\":\"thinkpad\",\"os\":\"ALSE\",\"app\":\"linux 0.4.5\"},"
        + "\"updated\":\"2026-10-12T10:00:00Z\",\"tz\":\"UTC\",\"days\":{\"codex\":{\"2026-10-11\":{\"gpt-x\":{\"input\":500,"
        + "\"output\":5,\"cacheRead\":0,\"cacheWrite5m\":0,\"cacheWrite1h\":0,\"turns\":2}}}}}"
    let counts: [String: Int] = ["input": 300, "output": 0, "cacheRead": 0, "cacheWrite5m": 0, "cacheWrite1h": 0, "turns": 1]
    let nullDays: [String: [String: [String: Int]]] = ["2026-10-11": ["gpt-y": counts]]
    let seen = now.addingTimeInterval(-60)
    let unlabelled = rlMachineFile("fixturealse", name: "alse", updated: seen, lastSeenAt: seen,
                                   accounts: [rlAcct("codex", nil, status: "error", interval: nil, days: nullDays)],
                                   days: ["codex": nullDays])
    let cache = rlCache(["machine-fixturevps.json": v11, "machine-fixturethinkpad.json": legacy,
                         "machine-fixturealse.json": unlabelled], now: now)
    let views = rlResolve(cache, now: now)
    var c = RLChecks()
    c.add("no card without a label (V7)", views.allSatisfy { $0.isLocal || $0.label != nil })
    let codex = views.filter { $0.product == "codex" }
    c.add("one labelled Codex card (got \(codex.map(rlKey)))", codex.count == 1 && codex.first?.label == RL_CODEX_V11)
    c.add("its usage = its account days only", rlCanon(["codex": codex.first?.usageDays ?? [:]]) == rlCanon(["codex": codexDays]))
    let root = cache.days["codex"] ?? [:]
    c.add("history totals keep the 0.4.5 usage", root["2026-10-11"]?["gpt-x"]?.input == 500)
    c.add("history totals keep the null-label usage", root["2026-10-11"]?["gpt-y"]?.input == 300)
    expect(c.failed.isEmpty, "C1-05 old 0.4.5 / null-label Codex usage → group «аккаунт не указан» without a card; known accounts unchanged (RL-17)" + c.suffix)
}

// MARK: C1-06 V5 states with injected now

private func rlC106(_ expect: RLExpect) {
    let now = rlDate("2026-10-12T12:00:00Z")
    let priority = [6, 5, 3, 4, 2]                     // UX §4: 7 > 6 > 5 > 3 > 4 > 2 > 1
    func file(_ flags: Set<Int>, status statusOverride: String? = nil, retry: Date? = nil) -> String {
        let asOf = now.addingTimeInterval(flags.contains(2) ? -5 * 3600 : -50 * 60)        // Auto 4 h: fresh / stale
        let status = statusOverride ?? (flags.contains(3) ? "expired" : (flags.contains(4) ? "rate_limited" : "ok"))
        let record = rlAcct("claude", RL_CLAUDE_V11, status: status, asOf: status == "signed_out" ? nil : asOf,
                            pct: status == "signed_out" ? nil : 40, interval: 14400, nextAt: asOf.addingTimeInterval(14400),
                            retryUntil: retry ?? (flags.contains(4) ? now.addingTimeInterval(3600) : nil))
        let seen = now.addingTimeInterval(flags.contains(5) ? -40 * 60 : -5 * 60)
        return rlMachineFile("fixturevps", name: "vps", updated: seen, lastSeenAt: seen, accounts: [record])
    }
    func state(_ text: String, at: Date, warning: String? = nil) -> (Int?, RemoteSource?) {
        let views = rlResolve(rlCache(["machine-fixturevps.json": text], now: at), warning: warning, now: at)
        let card = views.filter { $0.product == "claude" && $0.label == RL_CLAUDE_V11 && !$0.isLocal }
        return card.count == 1 ? (card[0].state.rawValue, card[0].data.source) : (nil, nil)
    }
    var cases: [Set<Int>] = [Set<Int>()] + priority.map { Set([$0]) }
    for i in 0..<priority.count {
        for j in (i + 1)..<priority.count { cases.append(Set([priority[i], priority[j]])) }
    }
    cases.append(Set(priority))
    var m = RLChecks()
    for flags in cases {
        let want = priority.first(where: { flags.contains($0) }) ?? 1
        let got = state(file(flags), at: now, warning: flags.contains(6) ? "Синхронизация стоит" : nil).0
        m.add("\(flags.sorted()) → \(want) (got \(got.map { String($0) } ?? "no card"))", got == want)
    }
    expect(m.failed.isEmpty, "C1-06 V5: each condition alone, every pair and all together → priority 6 > 5 > 3 > 4 > 2 > 1" + m.suffix)

    var s = RLChecks()
    s.add("signed_out (3b) → 3", state(file([], status: "signed_out"), at: now).0 == 3)
    s.add("rate_limited with retryUntil in the past → 1", state(file([], status: "rate_limited", retry: now.addingTimeInterval(-60)), at: now).0 == 1)
    s.add("error with a fresh asOf → 1 (age ≠ expired sign-in, lesson 012)", state(file([], status: "error"), at: now).0 == 1)
    expect(s.failed.isEmpty, "C1-06 V5 status edges" + s.suffix)

    let t0 = rlDate("2026-10-12T11:00:00Z")
    let seen = rlDate("2026-10-12T11:15:00Z")
    let edge = rlDate("2026-10-12T11:35:00Z")
    var b = RLChecks()
    let edges: [(String, Date?)] = [("nextAt", t0.addingTimeInterval(900)), ("asOf + interval", nil)]
    for (name, nextAt) in edges {
        let text = rlMachineFile("fixturevps", name: "vps", updated: seen, lastSeenAt: seen,
                                 accounts: [rlAcct("claude", RL_CLAUDE_V11, asOf: t0, pct: 40, interval: 900, nextAt: nextAt)])
        let atEdge = state(text, at: edge)
        b.add("\(name): freshUntil = 11:35:00", atEdge.1?.freshUntil == edge)
        b.add("\(name): now = freshUntil → 1", atEdge.0 == 1)
        b.add("\(name): freshUntil + 1 s → 2", state(text, at: edge.addingTimeInterval(1)).0 == 2)
        b.add("\(name): lastSeenAt exactly 30 min ago → still 2, not offline", state(text, at: seen.addingTimeInterval(1800)).0 == 2)
        b.add("\(name): lastSeenAt 30 min + 1 s ago → 5", state(text, at: seen.addingTimeInterval(1801)).0 == 5)
    }
    expect(b.failed.isEmpty, "C1-06 freshUntil = (nextAt ?? asOf + interval) + 20 min, borders ±1 s; offline after 30 min" + b.suffix)

    let auto4 = now.addingTimeInterval(-(3 * 3600 + 50 * 60))
    func auto(_ seenAgo: TimeInterval?, updatedAgo: TimeInterval, lastSeen raw: String? = nil) -> Int? {
        let record = rlAcct("claude", RL_CLAUDE_V11, asOf: auto4, pct: 40, interval: 14400, nextAt: auto4.addingTimeInterval(14400))
        var lastSeen: Any? = nil
        if let r = raw { lastSeen = r } else if let ago = seenAgo { lastSeen = now.addingTimeInterval(-ago) }
        return state(rlMachineFile("fixturevps", name: "vps", updated: now.addingTimeInterval(-updatedAgo), lastSeenAt: lastSeen,
                                   accounts: [record]), at: now).0
    }
    var f = RLChecks()
    f.add("Auto 4 h, asOf 3 h 50 min, lastSeenAt 5 min → 1", auto(300, updatedAgo: 300) == 1)
    f.add("…lastSeenAt 40 min → 5", auto(2400, updatedAgo: 2400) == 5)
    f.add("no lastSeenAt → by updated 40 min → 5", auto(nil, updatedAgo: 2400) == 5)
    f.add("no lastSeenAt → by updated 5 min → 1", auto(nil, updatedAgo: 300) == 1)
    f.add("lastSeenAt «garbage» → by updated 40 min → 5", auto(nil, updatedAgo: 2400, lastSeen: "garbage") == 5)
    expect(f.failed.isEmpty, "C1-06 F6: Auto 4 h is not stale at 3 h 50 min; source offline by lastSeenAt (fallback updated)" + f.suffix)

    let fresh = now.addingTimeInterval(-10)
    let both: [Any] = [rlAcct("claude", RL_CLAUDE_V11, asOf: fresh, pct: 40, interval: 900, nextAt: fresh.addingTimeInterval(900)),
                       rlAcct("codex", RL_CODEX_A, asOf: fresh, pct: 88, interval: 900, nextAt: fresh.addingTimeInterval(900))]
    let cache = rlCache(["machine-fixturevps.json": rlMachineFile("fixturevps", name: "vps", updated: fresh, lastSeenAt: fresh,
                                                                  accounts: both)], now: now)
    let mine = rlLocal(10, asOf: now.addingTimeInterval(-600))
    let on = rlResolve(cache, codex: mine, ids: ["codex": RL_UUID_A], now: now)
    let onCodex = on.first { $0.product == "codex" }
    expect(on.contains { !$0.isLocal && $0.label == RL_CLAUDE_V11 } && onCodex?.data.session == 88 && onCodex?.isLocal == true,
           "C1-06 (control) signed in to GitHub: remote Claude card shown, newer remote Codex value on the local card (V3)")
    for phase in [SyncPhase.off, .revoked, .awaitingCode] {
        let views = rlResolve(cache, codex: mine, ids: ["codex": RL_UUID_A], phase: phase, now: now)
        let codex = views.first { $0.product == "codex" }
        var p = RLChecks()
        p.add("no remote AccountView", views.allSatisfy { $0.isLocal })
        p.add("local card stays", codex?.isLocal == true)
        p.add("local card shows only local values", codex?.data.session == 10 && codex?.data.source == nil)
        expect(p.failed.isEmpty, "C1-06 state 7 (\(phase)): no remote cards and no remote values until a successful sync (№14)" + p.suffix)
    }
}

// MARK: C1-07 old caches decode; future asOf

private func rlC107(_ fx: RLFixtures?, _ expect: RLExpect) {
    let old = "{\"authEpoch\":\"e1\",\"authUserID\":\"u1\",\"machines\":[{\"id\":\"fixturevps\",\"name\":\"vps\",\"os\":\"Ubuntu\","
        + "\"updated\":781000000}],\"days\":{\"claude\":{\"2026-10-12\":{\"m\":{\"input\":1,\"output\":0,\"cacheRead\":0,"
        + "\"cacheWrite5m\":0,\"cacheWrite1h\":0,\"turns\":1}}}}}"
    let decoded = try? JSONDecoder().decode(SyncRemoteCache.self, from: Data(old.utf8))
    var c = RLChecks()
    c.add("decodes", decoded != nil)
    c.add("accounts nil", decoded?.accounts == nil)
    c.add("captions nil", decoded?.captions == nil)
    c.add("unattributedDays nil", decoded?.unattributedDays == nil)
    c.add("gistId nil", decoded?.gistId == nil)
    c.add("machine kept, lastSeenAt nil", decoded?.machines.count == 1 && decoded?.machines.first?.lastSeenAt == nil)
    c.add("binding kept", decoded?.authEpoch == "e1" && decoded?.authUserID == "u1")
    c.add("days kept", rlCanon(decoded?.days ?? [:]) == rlCanon(["claude": ["2026-10-12": ["m": DayModelUsage(input: 1, turns: 1)]]]))
    expect(c.failed.isEmpty, "C1-07 sync-remote.json of 3.2.7 (no lastSeenAt/accounts) decodes with nil fields" + c.suffix)

    if let text = fx?.text("machine-v11.json") {
        var cache = mergeV11(["machine-fixturevps.json": text], excluding: "selftest-mac", now: rlDate("2026-10-12T10:20:00Z"))
        cache.authEpoch = "e1"
        cache.authUserID = "u1"
        cache.gistId = RL_G1
        let back = (try? JSONEncoder().encode(cache)).flatMap { try? JSONDecoder().decode(SyncRemoteCache.self, from: $0) }
        var r = RLChecks()
        r.add("round trip", back != nil)
        r.add("accounts", (back?.accounts ?? []).count == 2)
        r.add("asOf", back?.accounts?.first(where: { $0.label == RL_CLAUDE_V11 })?.asOf == rlDate("2026-10-12T10:15:02Z"))
        r.add("lastSeenAt", back?.machines.first?.lastSeenAt == rlDate("2026-10-12T10:15:03Z"))
        r.add("captions", back?.captions?[RL_CLAUDE_V11]?.text == "команда")
        // S2 (T2 C1, decision 2026-10-18): the gist id is never written to sync-remote.json, yet labels still resolve after
        // decode (the cache keeps a derived, irreversible label key). `gistId` may stay an in-memory field — tests set it.
        let encoded = (try? JSONEncoder().encode(cache)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        r.add("S2: gist id not in the encoded cache (\(encoded.components(separatedBy: RL_G1).count - 1) occurrences)",
              !encoded.isEmpty && !encoded.contains(RL_G1))
        let reloaded = back.map { rlResolve($0, claude: rlLocal(10, asOf: rlDate("2026-10-12T10:19:00Z")), ids: ["claude": RL_UUID_A],
                                            now: rlDate("2026-10-12T10:20:00Z")).filter { $0.product == "claude" } } ?? []
        r.add("S2: after decode the local Claude still groups with the vps label",
              reloaded.count == 1 && reloaded.first?.isLocal == true && reloaded.first?.label == RL_CLAUDE_V11
              && reloaded.first?.machines.contains("vps") == true)
        expect(r.failed.isEmpty, "C1-07 v1.1 remote cache survives encode → decode (sync-remote.json)" + r.suffix)
    }

    let now = rlDate("2026-10-12T12:00:00Z")
    let seen = now.addingTimeInterval(-60)
    let future = rlAcct("claude", RL_CLAUDE_V11, asOf: now.addingTimeInterval(600), pct: 30, interval: 900,
                        nextAt: now.addingTimeInterval(1500))
    let views = rlResolve(rlCache(["machine-fixturevps.json": rlMachineFile("fixturevps", name: "vps", updated: seen, lastSeenAt: seen,
                                                                            accounts: [future])], now: now), now: now)
    let card = views.first { $0.product == "claude" }
    expect(card?.data.session == 30 && card?.state.rawValue == 1,
           "C1-07 asOf 10 min in the future → card still drawn, age 0 (not stale); «темп не считаем» is checked in C3-05")
}

// MARK: C1-08 machine tag (parity with A1-11)

private func rlC108(_ fx: RLFixtures, _ expect: RLExpect) {
    guard let vectors = fx.object("sanitize-vectors.json")?["machine_tag"] as? [[String: Any]], !vectors.isEmpty else {
        expect(false, "C1-08 sanitize-vectors.json readable"); return
    }
    var c = RLChecks()
    for v in vectors {
        let setting = v["setting"] as? String ?? "", host = v["hostname"] as? String ?? ""
        let got = machineTag(setting: setting, hostname: host)
        let shape = (1...16).contains(got.utf8.count)
            && got.utf8.allSatisfy(rlTagByte)
        c.add("shape [a-z0-9-]{1,16}: «\(got)»", shape)
        if let e = v["expect"] as? String {
            let want = e == "linux" ? "mac" : e                 // the Linux default tag is «linux», the Mac one «mac»
            c.add("«\(setting.prefix(16))» / «\(host.prefix(24))» → \(want) (got \(got))", got == want)
        }
        for bad in v["forbid"] as? [String] ?? [] { c.add("no «\(bad)» in \(got)", !got.contains(bad)) }
    }
    expect(c.failed.isEmpty, "C1-08 machineTag() = Linux A1-11 vectors (owner tag «macbook», default «mac»)" + c.suffix)
}

// MARK: - C1 fix cycle 1 (tester, 2026-10-18; red before the fix)
//
// Sources: docs/review-remote-limits-c1.md (M1, M2, minor), decisions/log.md 2026-10-18 «C1 ревью: M1, M2, m7».
// C1-09 M1 local base kept · C1-10 M2 refused-raw cache only for the 8 MiB cap · C1-11 m7 offline by lastSeenAt, else updated
// (GUARD: the code already does it; the fix is in sync-protocol.md) · C1-12 4 KiB metadata measured like Linux ·
// C1-13 POST/PATCH responses bounded (16 MiB) · C1-14 raw read deadline (injected clock) · C1-15 `updated` parsed like Linux ·
// C1-16 JSON 1.0 / 1e0 is not an integer · C1-17 sign-out clears syncRejectedRaw.
// Linux reference for C1-10/12/15/16 (same vectors): linux/tests/test_rl_contract_fixes3.py.
// New contract for the developer — one addition only:
//   GitHubSync.init(…, authOwner: …, clock: @escaping () -> Date = { Date() })   — LAST parameter; the sync cycle's read clock
//   (the raw-read deadline; may also stamp syncRejectedRaw). Production passes nothing.
// Not a test (review, for the developer): rename `RemoteLimitsWire.unsafe` → `isUnsafe` (contextual keyword in Swift ≥ 6.2).

/// Deadline for reading other machines' raw files in one sync cycle (decision brief 2026-10-18: 30 s). Linux differs:
/// `_read_budget` = 60 s for the whole read phase (GET /gists included), each request ≤ min(30 s, remaining). If Юрка picks the
/// Linux number, change only this constant — every C1-14 expectation is derived from it.
private let RL_RAW_READ_DEADLINE: TimeInterval = 30
private let RL_FIX_GIST = "rl-fix-gist"
private let RL_RAW_BASE = "https://gist.githubusercontent.com/u/rl-fix-gist/raw/abc/"

private func rlRawRef(_ name: String) -> [String: Any] {
    ["truncated": true, "raw_url": RL_RAW_BASE + name, "content": ""]
}
private func rlOthers(_ s: GitHubSync) -> [String] { s.ui.machines.filter { !$0.isSelf }.map { $0.name }.sorted() }

/// One sync cycle through GitHubSync with an in-memory gist (no network, no Keychain, memory defaults). `reset` clears the
/// defaults first; otherwise the previous cycle's defaults (syncRejectedRaw, syncPushHash) carry over — like an app restart.
private func rlSyncOnce(_ defaults: MemorySelfTestDefaults, _ root: String, files: [String: Any], raw: [String: Data],
                        reset: Bool, patchReply: SyncHTTPResult = (200, Data("{}".utf8), nil, [:]))
    -> (sync: GitHubSync, rawGets: [String]) {
    let gistURL = "https://api.github.com/gists/" + RL_FIX_GIST
    if reset {
        defaults.clear()
        defaults.set("selftest-login", forKey: "syncLogin")
        defaults.set(RL_FIX_GIST, forKey: "syncGistId")
        defaults.set(Date(), forKey: "syncDiscoveredAt")
    }
    var all = files
    all[SYNC_MANIFEST] = ["content": "{}"]
    all["machine-selftest-mac.json"] = ["content": "{}"]
    let gist: [String: Any] = ["id": RL_FIX_GIST, "public": false, "created_at": "2026-01-01T00:00:00Z", "files": all]
    let body = (try? JSONSerialization.data(withJSONObject: gist)) ?? Data()
    let http = SelfTestHTTP { c in
        if c.url == gistURL && c.method == "GET" { return (200, body, nil, [:]) }
        if c.url == gistURL && c.method == "PATCH" { return patchReply }
        if c.method == "GET", let data = raw[c.url] { return (200, data, nil, [:]) }
        return (599, nil, nil, [:])
    }
    let sync = GitHubSync(transport: http.transport, keychain: ScriptedSyncKeychain(store: SelfTestKeychainStore("rl-selftest-token")),
                          defaults: defaults, remotePath: root + "/rl-remote-fix.json", machineId: "selftest-mac",
                          revokeRecheckDelay: 0)
    sync.syncSynchronously()
    let gets = http.calls.filter { $0.method == "GET" && $0.url.hasPrefix("https://gist.githubusercontent.com/") }.map { $0.url }
    return (sync, gets)
}

// MARK: C1-09 (M1) a winning remote snapshot rewrites only the reading fields of the local card

private func rlC109(_ fx: RLFixtures, _ expect: RLExpect) {
    let now = rlDate("2026-10-12T10:20:00Z")
    guard let v11 = fx.text("machine-v11.json") else { expect(false, "C1-09 machine-v11.json readable"); return }
    let cache = rlCache(["machine-fixturevps.json": v11], now: now)
    func busyLocal() -> LimitData {
        var d = LimitData()
        d.session = 10; d.weekly = 11
        d.sessionReset = rlDate("2026-10-12T11:00:00Z"); d.weeklyReset = rlDate("2026-10-14T00:00:00Z")
        d.scoped = ScopedLimit(name: "local-model", percent: 12, reset: nil, severity: "normal")
        d.plan = "pro"; d.resetCredits = 7
        d.asOf = rlDate("2026-10-12T10:00:00Z")          // older than the vps Claude snapshot (10:15:02) → vps wins V3
        d.apiFresh = true; d.fromCache = false
        d.auth = .expired                                 // «вход истёк» of THIS Mac
        d.credentialIssue = .readInteractionRequired      // Keychain access request
        d.refreshInFlight = true                          // manual refresh spinner
        d.permissionRequestInFlight = true
        d.pollFailed = true
        d.nextPollAt = rlDate("2026-10-12T10:30:00Z")
        d.localRetryAt = 1_791_800_123
        d.serverRetryAt = 1_791_800_456
        d.error = "HTTP 401"
        return d
    }
    // The local Claude account IS the vps account (label(G1, claude, UUID_A) == RL_CLAUDE_V11).
    let views = rlResolve(cache, claude: busyLocal(), ids: ["claude": RL_UUID_A], now: now).filter { $0.product == "claude" }
    let d = views.first?.data
    var c = RLChecks()
    c.add("one local card (got \(views.map(rlKey)))", views.count == 1 && views.first?.isLocal == true)
    c.add("precondition: the vps snapshot won V3 (source vps)", d?.source?.machineName == "vps")
    c.add("session 42.5 / weekly 61 from vps", d?.session == 42.5 && d?.weekly == 61)
    c.add("sessionReset from vps", d?.sessionReset == rlDate("2026-10-12T13:00:00Z"))
    c.add("asOf from vps", d?.asOf == rlDate("2026-10-12T10:15:02Z"))
    c.add("plan from vps", d?.plan == "max")
    c.add("scoped from the vps models", d?.scoped?.name == "Fable 5.1")
    c.add("resetCredits from vps (absent), not the local 7", d?.resetCredits == nil)
    c.add("apiFresh false (not a live answer to this Mac)", d?.apiFresh == false)
    c.add("present", d?.present == true)
    c.add("auth .expired kept (got \(d.map { "\($0.auth)" } ?? "no card"))", d?.auth == .expired)
    c.add("credentialIssue kept", d?.credentialIssue == .readInteractionRequired)
    c.add("refreshInFlight kept", d?.refreshInFlight == true)
    c.add("permissionRequestInFlight kept", d?.permissionRequestInFlight == true)
    c.add("pollFailed kept", d?.pollFailed == true)
    c.add("nextPollAt kept", d?.nextPollAt == rlDate("2026-10-12T10:30:00Z"))
    c.add("localRetryAt kept", d?.localRetryAt == 1_791_800_123)
    c.add("serverRetryAt kept", d?.serverRetryAt == 1_791_800_456)
    c.add("error kept", d?.error == "HTTP 401")
    expect(c.failed.isEmpty, "C1-09 M1: a remote snapshot winning the LOCAL card rewrites only session/weekly/resets/scoped/plan/"
           + "resetCredits/asOf/apiFresh/fromCache + source; auth, credentialIssue, refreshInFlight, permissionRequestInFlight, "
           + "pollFailed, nextPollAt, localRetryAt, serverRetryAt, error stay local (decision 2026-10-18)" + c.suffix)

    // GUARD: a different local Claude account never lends its local state to the remote vps card.
    let other = rlResolve(cache, claude: busyLocal(), ids: ["claude": RL_UUID_C], now: now)
        .filter { $0.product == "claude" && !$0.isLocal }
    let r = other.first?.data
    var g = RLChecks()
    g.add("one remote card", other.count == 1 && other.first?.label == RL_CLAUDE_V11)
    g.add("auth .ok", r?.auth == .ok)
    g.add("no spinner / prompt", r?.refreshInFlight == false && r?.permissionRequestInFlight == false)
    g.add("no local schedule / error", r?.nextPollAt == nil && r?.credentialIssue == nil && r?.error == nil)
    expect(g.failed.isEmpty, "C1-09 (guard) a remote card of another account carries no local auth/refresh state" + g.suffix)
}

// MARK: C1-10 (M2) only the own 8 MiB excess goes to syncRejectedRaw, not the exhausted total budget

private func rlC110(_ defaults: MemorySelfTestDefaults, _ root: String, _ expect: RLExpect) {
    let mib = 1024 * 1024
    let part = 8 * mib - mib / 8                         // 7.875 MiB; 8 parts = 63 MiB read
    var files: [String: Any] = [:]
    var raw: [String: Data] = [:]
    for i in 0..<8 {
        let name = "machine-b\(i).json"
        files[name] = rlRawRef(name)
        raw[RL_RAW_BASE + name] = Data(rlPadded("b\(i)", bytes: part).utf8)
    }
    let two = "machine-c-two.json", twoURL = RL_RAW_BASE + two
    files[two] = rlRawRef(two)
    raw[twoURL] = Data(rlPadded("c-two", bytes: 2 * mib).utf8)   // a valid 2 MiB file; its cap = 64 − 63 = 1 MiB
    func rejectedCount() -> Int { defaults.dictionary(forKey: "syncRejectedRaw")?.count ?? 0 }

    let first = rlSyncOnce(defaults, root, files: files, raw: raw, reset: true)
    var a = RLChecks()
    a.add("precondition: the 2 MiB file was requested with 1 MiB of budget left", first.rawGets.filter { $0 == twoURL }.count == 1)
    a.add("skipped in this cycle", !rlOthers(first.sync).contains("pc-c-two"))
    a.add("files already read merged", rlOthers(first.sync).contains("pc-b0"))
    a.add("budget error visible", first.sync.ui.lastError != nil)
    a.add("not cached in syncRejectedRaw (got \(rejectedCount()) entries)", rejectedCount() == 0)
    expect(a.failed.isEmpty, "C1-10 M2: a body over the remaining 64 MiB budget (cap < 8 MiB) is skipped in this cycle only, "
           + "never cached for 24 h (sync-protocol.md «Reader limits»)" + a.suffix)

    let second = rlSyncOnce(defaults, root, files: [two: rlRawRef(two)], raw: raw, reset: false)
    var b = RLChecks()
    b.add("downloaded again (got \(second.rawGets.count) raw GETs)", second.rawGets == [twoURL])
    b.add("merged", rlOthers(second.sync).contains("pc-c-two"))
    expect(b.failed.isEmpty, "C1-10 M2: the next cycle with a free budget reads and merges that file" + b.suffix)

    // GUARD: the own 8 MiB excess is cached; the next cycle skips it without a download, visibly.
    let over = "machine-over.json", overURL = RL_RAW_BASE + over
    let overRaw = [overURL: Data(rlPadded("over", bytes: 8 * mib + 1).utf8)]
    let o1 = rlSyncOnce(defaults, root, files: [over: rlRawRef(over)], raw: overRaw, reset: true)
    let cachedAfterFirst = rejectedCount()
    let o2 = rlSyncOnce(defaults, root, files: [over: rlRawRef(over)], raw: overRaw, reset: false)
    var c = RLChecks()
    c.add("first cycle downloads it once", o1.rawGets == [overURL])
    c.add("cached: 1 entry (got \(cachedAfterFirst))", cachedAfterFirst == 1)
    c.add("next cycle: no download", o2.rawGets.isEmpty)
    c.add("next cycle: skip visible", o2.sync.ui.lastError != nil)
    expect(c.failed.isEmpty, "C1-10 (guard) a raw body over 8 MiB is refused for 24 h (N9)" + c.suffix)

    defaults.clear()
    try? FileManager.default.removeItem(atPath: root + "/rl-remote-fix.json")
}

// MARK: C1-11 (m7, GUARD) offline by lastSeenAt; without it — by updated

private func rlC111(_ expect: RLExpect) {
    let now = rlDate("2026-10-12T12:00:00Z")
    let asOf = now.addingTimeInterval(-300)
    func state(updatedAgo: TimeInterval?, lastSeenAgo: TimeInterval?, lastSeenRaw: String? = nil) -> Int? {
        let record = rlAcct("claude", RL_CLAUDE_V11, asOf: asOf, pct: 40, interval: 900, nextAt: asOf.addingTimeInterval(900))
        var seen: Any? = nil
        if let s = lastSeenRaw { seen = s } else if let ago = lastSeenAgo { seen = now.addingTimeInterval(-ago) }
        var updated: Date? = nil
        if let ago = updatedAgo { updated = now.addingTimeInterval(-ago) }
        let file = rlMachineFile("fixturevps", name: "vps", updated: updated, lastSeenAt: seen, accounts: [record])
        let card = rlResolve(rlCache(["machine-fixturevps.json": file], now: now), now: now)
            .filter { $0.product == "claude" && !$0.isLocal }
        return card.count == 1 ? card[0].state.rawValue : nil
    }
    var c = RLChecks()
    c.add("no lastSeenAt (v1-era writer), updated 5 min → 1", state(updatedAgo: 300, lastSeenAgo: nil) == 1)
    c.add("no lastSeenAt, updated 40 min → 5 (offline by updated)", state(updatedAgo: 2400, lastSeenAgo: nil) == 5)
    c.add("lastSeenAt «garbage», updated 5 min → 1", state(updatedAgo: 300, lastSeenAgo: nil, lastSeenRaw: "garbage") == 1)
    c.add("lastSeenAt 5 min wins over updated 2 h → 1", state(updatedAgo: 7200, lastSeenAgo: 300) == 1)
    c.add("lastSeenAt 40 min wins over updated 1 min → 5", state(updatedAgo: 60, lastSeenAgo: 2400) == 5)
    expect(c.failed.isEmpty, "C1-11 m7 (guard): card offline (5) by lastSeenAt, without it by updated (synth §F, decision "
           + "2026-10-18); strict «no lastSeenAt → not alive» is coordination-only (C4)" + c.suffix)
}

// MARK: C1-12 (minor) the 4 KiB metadata cap is measured like Linux

/// Linux `validate_entry`: json.dumps(out, ensure_ascii=False, separators=(",", ":")) of the sanitized record BEFORE `days`,
/// times as the ORIGINAL ISO strings, `"label":null` / `"retryUntil":null` counted, `/` not escaped. The wire string below is
/// built by hand with exactly that shape; linux/tests/test_rl_contract_fixes3.py TestC112 proves the same arithmetic on Linux.
private func rlC112(_ expect: RLExpect) {
    let now = rlDate("2026-10-12T10:20:00Z")
    let dateHead = "2026-10-12T10:00:00."
    func run(_ record: [String: Any]) -> [RemoteAccount] {
        let file = rlMachineFile("fixturemeta", name: "meta", updated: now, lastSeenAt: now, accounts: [record])
        return mergeV11(["machine-fixturemeta.json": file], excluding: "selftest-mac", now: now).accounts ?? []
    }
    func digits(_ total: Int, _ head: String, _ tail: String) -> String {
        String(repeating: "1", count: total - head.utf8.count - tail.utf8.count)
    }
    func labelled(_ total: Int) -> [String: Any] {
        let head = "{\"product\":\"codex\",\"label\":\"aaaaaaaaaaaaaaa1\",\"status\":\"ok\",\"asOf\":\"" + dateHead
        let tail = "Z\"}"
        return ["product": "codex", "label": "aaaaaaaaaaaaaaa1", "status": "ok", "asOf": dateHead + digits(total, head, tail) + "Z"]
    }
    func unlabelled(_ total: Int) -> [String: Any] {
        let plan = "max/team/x"
        let head = "{\"product\":\"codex\",\"label\":null,\"status\":\"ok\",\"plan\":\"" + plan + "\",\"asOf\":\"" + dateHead
        let tail = "Z\",\"retryUntil\":null}"
        return ["product": "codex", "label": NSNull(), "status": "ok", "plan": plan,
                "asOf": dateHead + digits(total, head, tail) + "Z", "retryUntil": NSNull()]
    }
    func hasLabelled(_ a: [RemoteAccount]) -> Bool { a.contains { $0.label == "aaaaaaaaaaaaaaa1" } }
    func hasNull(_ a: [RemoteAccount]) -> Bool { a.contains { $0.product == "codex" && $0.label == nil } }
    let kept = run(labelled(4096))
    var c = RLChecks()
    c.add("labelled, 4096 bytes → kept", hasLabelled(kept))
    c.add("labelled, 4096 bytes → its long-fraction asOf parsed", kept.first { $0.label == "aaaaaaaaaaaaaaa1" }?.asOf != nil)
    c.add("labelled, 4097 bytes → dropped (JSONEncoder counts asOf as a Double)", !hasLabelled(run(labelled(4097))))
    c.add("label null + «/» + retryUntil null, 4096 → kept", hasNull(run(unlabelled(4096))))
    c.add("label null + «/» + retryUntil null, 4097 → dropped", !hasNull(run(unlabelled(4097))))
    expect(c.failed.isEmpty, "C1-12 4 KiB metadata cap measured on the sanitized wire record with original ISO strings "
           + "(Linux accounts.validate_entry)" + c.suffix)
}

// MARK: C1-13 (minor) POST/PATCH responses are bounded like GET (16 MiB)

private func rlC113(_ defaults: MemorySelfTestDefaults, _ root: String, _ expect: RLExpect) {
    let mib = 1024 * 1024
    func padded(_ head: String, _ total: Int) -> Data {
        let tail = "\"}"
        return Data((head + String(repeating: "x", count: total - head.utf8.count - tail.utf8.count) + tail).utf8)
    }
    // GUARD: a confirmed 2xx PATCH with a huge echo stays a successful write (Linux gh(): no response body is needed).
    let echo = padded("{\"id\":\"" + RL_FIX_GIST + "\",\"pad\":\"", 16 * mib + 1)
    let patched = rlSyncOnce(defaults, root, files: [:], raw: [:], reset: true, patchReply: (200, echo, nil, [:]))
    expect(defaults.string(forKey: "syncPushHash") != nil && patched.sync.ui.lastError == nil,
           "C1-13 (guard) PATCH 200 with a 16 MiB + 1 echo: the write is confirmed, no error (Linux gh)")

    // POST /login/device/code answering 16 MiB + 1 bytes of valid JSON → the body is refused, no user code is shown.
    defaults.clear()
    let big = padded("{\"device_code\":\"dc\",\"user_code\":\"UC-BIG\",\"interval\":1,\"expires_in\":2,\"pad\":\"", 16 * mib + 1)
    let http = SelfTestHTTP { c in
        if c.url == "https://github.com/login/device/code" { return (200, big, nil, [:]) }
        return (599, nil, nil, [:])
    }
    let s = GitHubSync(transport: http.transport, keychain: ScriptedSyncKeychain(store: SelfTestKeychainStore(nil)),
                       defaults: defaults, remotePath: root + "/rl-remote-login.json", machineId: "selftest-mac",
                       revokeRecheckDelay: 0)
    s.startLogin()
    let end = Date().addingTimeInterval(5)
    while Date() < end && s.ui.userCode == nil && s.ui.phase == .awaitingCode { Thread.sleep(forTimeInterval: 0.02) }
    let shown = s.ui.userCode, phase = s.ui.phase, error = s.ui.error
    s.cancelLogin()
    _ = s.selfTestWaitForQueue()
    let asked = http.calls.contains { $0.method == "POST" && $0.url == "https://github.com/login/device/code" }
    var c = RLChecks()
    c.add("precondition: the device code was requested", asked)
    c.add("no user code shown (got \(shown ?? "nil"))", shown == nil)
    c.add("sign-in left awaitingCode", phase != .awaitingCode)
    c.add("sign-in error visible", error != nil)
    expect(c.failed.isEmpty, "C1-13 POST answered with 16 MiB + 1 bytes → refused like any over-cap body (Linux _transport "
           + "max_body on every response, review minor LimitsMonitor.swift:1455)" + c.suffix)
    defaults.clear()
    try? FileManager.default.removeItem(atPath: root + "/rl-remote-fix.json")
    try? FileManager.default.removeItem(atPath: root + "/rl-remote-login.json")
}

// MARK: C1-14 (minor) one deadline for reading raw files (injected clock)

private final class RLFakeClock {
    var now: Date
    var raws: [(offset: TimeInterval, timeout: Double)] = []
    init(_ now: Date) { self.now = now }
}

private func rlC114(_ defaults: MemorySelfTestDefaults, _ root: String, _ expect: RLExpect) {
    let gistURL = "https://api.github.com/gists/" + RL_FIX_GIST
    let step: TimeInterval = 25                          // each raw file «takes» 25 s on the injected clock
    let start = Date()                                   // only an origin: every expectation is relative to it
    let clock = RLFakeClock(start)
    defaults.clear()
    defaults.set("selftest-login", forKey: "syncLogin")
    defaults.set(RL_FIX_GIST, forKey: "syncGistId")
    defaults.set(start, forKey: "syncDiscoveredAt")
    var files: [String: Any] = [SYNC_MANIFEST: ["content": "{}"], "machine-selftest-mac.json": ["content": "{}"]]
    var rawFiles: [String: Data] = [:]
    for i in 0..<5 {
        let name = "machine-d\(i).json"
        files[name] = rlRawRef(name)
        rawFiles[RL_RAW_BASE + name] = Data(rlSmall("d\(i)").utf8)
    }
    let raw = rawFiles
    let gist: [String: Any] = ["id": RL_FIX_GIST, "public": false, "created_at": "2026-01-01T00:00:00Z", "files": files]
    let body = (try? JSONSerialization.data(withJSONObject: gist)) ?? Data()
    let transport: SyncHTTP = { url, method, _, _, timeout in
        if url == gistURL && method == "GET" { return (200, body, nil, [:]) }
        if url == gistURL && method == "PATCH" { return (200, Data("{}".utf8), nil, [:]) }
        if method == "GET", let data = raw[url] {
            clock.raws.append((offset: clock.now.timeIntervalSince(start), timeout: timeout))
            clock.now = clock.now.addingTimeInterval(step)
            return (200, data, nil, [:])
        }
        return (599, nil, nil, [:])
    }
    let sync = GitHubSync(transport: transport, keychain: ScriptedSyncKeychain(store: SelfTestKeychainStore("rl-selftest-token")),
                          defaults: defaults, remotePath: root + "/rl-remote-deadline.json", machineId: "selftest-mac",
                          revokeRecheckDelay: 0, clock: { clock.now })
    sync.syncSynchronously()
    let allowed = min(5, Int((RL_RAW_READ_DEADLINE / step).rounded(.up)))   // reads that START before the deadline
    let seen = clock.raws.map { "\(Int($0.offset))s→\($0.timeout)s" }.joined(separator: ", ")
    var c = RLChecks()
    c.add("raw reads started before the deadline only: \(allowed) of 5 (got \(clock.raws.count): \(seen))", clock.raws.count == allowed)
    c.add("each raw request is given at most the remaining time (\(seen))",
          !clock.raws.isEmpty && clock.raws.allSatisfy { $0.timeout > 0 && $0.timeout <= RL_RAW_READ_DEADLINE - $0.offset + 0.001 })
    c.add("files read before the deadline merged (got \(rlOthers(sync)))", rlOthers(sync) == (0..<allowed).map { "pc-d\($0)" })
    c.add("deadline visible", sync.ui.lastError != nil)
    c.add("a partial read still counts as a sync (syncLastOkAt)", defaults.object(forKey: "syncLastOkAt") != nil)
    expect(c.failed.isEmpty, "C1-14 raw files of one cycle share one \(Int(RL_RAW_READ_DEADLINE)) s deadline on the injected "
           + "clock (review minor LimitsMonitor.swift:2836; Linux _read_timeout)" + c.suffix)
    defaults.clear()
    try? FileManager.default.removeItem(atPath: root + "/rl-remote-deadline.json")
}

// MARK: C1-15 (minor) `updated` parsed like Linux sync.merge

/// Linux parses `updated` with plain common.parse_iso: Python str.strip() (\t \n \v \f \r \x1c–\x1f space \x85 \xa0 U+1680
/// U+2000–U+200A U+2028 U+2029 U+202F U+205F U+3000) and NO length cap; account times and lastSeenAt go through _epoch
/// (_text(…, 4096) rejects Cc/Cf first, then the same strip). Swift today: text(limit: 4096) + trim .whitespaces for all of them.
/// Divergence left OUT on purpose (question to Юрка): Python `\d` also matches non-ASCII digits (e.g. U+FF12), Swift does not.
private func rlC115(_ expect: RLExpect) {
    let now = rlDate("2026-10-12T10:20:00Z")
    let iso = "2026-10-12T10:00:00Z", want = rlDate(iso)
    func machineObj(_ id: String, _ updated: Any) -> [String: Any] {
        ["schema": 1, "machine": ["id": id, "name": id, "os": "T"], "updated": updated, "days": [String: Any]()]
    }
    func merged(_ id: String, _ updated: Any) -> SyncCachedMachine? {
        mergeV11(["machine-\(id).json": rlJSON(machineObj(id, updated))], excluding: "selftest-mac", now: now)
            .machines.first { $0.id == id }
    }
    var c = RLChecks()
    let spaced: [(String, String)] = [("\\n after", iso + "\n"), ("\\t before", "\t" + iso), ("\\r\\n after", iso + "\r\n"),
                                      ("U+0085 after", iso + "\u{85}"), ("U+2028 after", iso + "\u{2028}"),
                                      ("U+3000 before", "\u{3000}" + iso)]
    for (i, v) in spaced.enumerated() {
        c.add("updated with \(v.0) → file kept, updated parsed", merged("w\(i)", v.1)?.updated == want)
    }
    let long = "2026-10-12T10:00:00." + String(repeating: "1", count: 5000) + "Z"
    let longUpdated: Date? = merged("longfrac", long)?.updated
    c.add("updated with 5000 fraction digits (> 4096 chars) → file kept",
          longUpdated.map { abs($0.timeIntervalSince(want) - 0.111) < 0.01 } ?? false)
    expect(c.failed.isEmpty, "C1-15 `updated` parsed like Linux sync.merge (common.parse_iso: str.strip(), no length cap); "
           + "today such files are dropped whole" + c.suffix)

    var g = RLChecks()
    let bad: [(String, Any)] = [("ZWSP before", "\u{200B}" + iso), ("NUL after", iso + "\u{0}"),
                                ("month 13", "2026-13-12T10:00:00Z"), ("«yesterday»", "yesterday"), ("a number", 123),
                                ("null", NSNull())]
    for (i, v) in bad.enumerated() { g.add("updated \(v.0) → file skipped", merged("bad\(i)", v.1) == nil) }
    let recs: [[String: Any]] = [["product": "codex", "label": "aaaaaaaaaaaaaaa1", "status": "ok", "asOf": iso + "\n"],
                                 ["product": "codex", "label": "aaaaaaaaaaaaaaa2", "status": "ok", "asOf": iso + "\u{2028}"]]
    var strict = machineObj("strict", iso)
    strict["lastSeenAt"] = iso + "\n"
    strict["accounts"] = recs
    let r = mergeV11(["machine-strict.json": rlJSON(strict)], excluding: "selftest-mac", now: now)
    g.add("lastSeenAt with \\n → nil (Cc drops the field)", r.machines.first?.lastSeenAt == nil && r.machines.count == 1)
    let a1 = (r.accounts ?? []).first { $0.label == "aaaaaaaaaaaaaaa1" }
    g.add("account asOf with \\n → nil, record kept", a1 != nil && a1?.asOf == nil)
    expect(g.failed.isEmpty, "C1-15 (guard) unsafe/broken `updated` still drops the file; account times and lastSeenAt stay "
           + "strict (Linux _epoch)" + g.suffix)
    let a2 = (r.accounts ?? []).first { $0.label == "aaaaaaaaaaaaaaa2" }
    expect(a2?.asOf == want, "C1-15 account asOf with a trailing U+2028 (Zl passes _text, parse_iso strips it) → parsed like Linux")
}

// MARK: C1-16 (minor) JSON 1.0 / 1e0 is not an integer (schema, usage counters)

private func rlC116(_ expect: RLExpect) {
    let now = rlDate("2026-10-12T10:20:00Z")
    var c = RLChecks()
    for (i, raw) in ["1.0", "1e0"].enumerated() {
        let text = "{\"schema\":\(raw),\"machine\":{\"id\":\"f\(i)\",\"name\":\"f\",\"os\":\"T\"},\"days\":{}}"
        c.add("schema \(raw) → file rejected", mergeV11(["machine-f\(i).json": text], excluding: "selftest-mac", now: now).machines.isEmpty)
    }
    let zeros = "\"output\":0,\"cacheRead\":0,\"cacheWrite5m\":0,\"cacheWrite1h\":0,\"turns\":1"
    let text = "{\"schema\":1,\"machine\":{\"id\":\"cnt\",\"name\":\"c\",\"os\":\"T\"},\"days\":{\"claude\":{\"2026-10-12\":{"
        + "\"m-float\":{\"input\":5.0," + zeros + "},\"m-exp\":{\"input\":1e2," + zeros + "},"
        + "\"m-int\":{\"input\":7," + zeros + "}}}}}"
    let r = mergeV11(["machine-cnt.json": text], excluding: "selftest-mac", now: now)
    let models = (r.days["claude"]?["2026-10-12"] ?? [:]).keys.sorted()
    c.add("counters 5.0 / 1e2 → those model entries skipped (got \(models))", models == ["m-int"])
    c.add("control: the integer entry kept", r.days["claude"]?["2026-10-12"]?["m-int"]?.input == 7 && r.machines.count == 1)
    expect(c.failed.isEmpty, "C1-16 legacyInteger: JSON 1.0 / 1e0 / 5.0 / 1e2 are not integers (Linux `type(n) is int`)" + c.suffix)
}

// MARK: C1-17 (minor) sign-out clears syncRejectedRaw

private func rlC117(_ defaults: MemorySelfTestDefaults, _ root: String, _ expect: RLExpect) {
    defaults.clear()
    defaults.set("selftest-login", forKey: "syncLogin")
    defaults.set(["0123456789abcdef": Date().timeIntervalSince1970], forKey: "syncRejectedRaw")
    let s = GitHubSync(transport: OFFLINE_SYNC_HTTP, keychain: ScriptedSyncKeychain(store: SelfTestKeychainStore("rl-selftest-token")),
                       defaults: defaults, remotePath: root + "/rl-remote-logout.json", machineId: "selftest-mac",
                       revokeRecheckDelay: 0)
    s.logout()
    let drained = s.selfTestWaitForQueue()
    expect(drained && defaults.string(forKey: "syncLogin") == nil, "C1-17 (control) sign-out finished")
    expect(defaults.object(forKey: "syncRejectedRaw") == nil,
           "C1-17 sign-out clears syncRejectedRaw (review minor LimitsMonitor.swift:2469)")
    defaults.clear()
}

// MARK: - C1 fix cycle 1, T2 findings (docs/security-remote-limits-c1-t2.md §3/§5; decision 2026-10-18 «C1 T2: S1–S3»)
//
// T2 §5 drafted these as C1-09…C1-11; renumbered C1-18 (S1), C1-19 (S2), C1-20 (S3) after the review IDs C1-09…C1-17.
// S5 (POST/PATCH bound) = C1-13, S4 = M2 = C1-10, S6 = C1-14. S7 (JSON depth) stays a live probe on the Mac (T2 §6 п. 2).

// MARK: C1-18 (S1) an unreadable or empty raw body skips that file only; its bytes count in the 64 MiB budget

private func rlC118(_ defaults: MemorySelfTestDefaults, _ root: String, _ expect: RLExpect) {
    let mib = 1024 * 1024
    var binary = Data([0xFF, 0xFE])                                   // never valid UTF-8
    binary.append(Data(repeating: 0xFF, count: 2 * mib - 2))
    let names = ["machine-aa.json", "machine-bin.json", "machine-empty.json", "machine-zz.json"]
    var files: [String: Any] = [:]
    for n in names { files[n] = rlRawRef(n) }
    let raw: [String: Data] = [RL_RAW_BASE + "machine-aa.json": Data(rlSmall("aa").utf8),
                               RL_RAW_BASE + "machine-bin.json": binary,
                               RL_RAW_BASE + "machine-empty.json": Data(),
                               RL_RAW_BASE + "machine-zz.json": Data(rlSmall("zz").utf8)]
    let r = rlSyncOnce(defaults, root, files: files, raw: raw, reset: true)
    let error = r.sync.ui.lastError ?? ""
    var c = RLChecks()
    c.add("every raw file requested (got \(r.rawGets.count))", r.rawGets.count == 4)
    c.add("the readable files merged (got \(rlOthers(r.sync)))", rlOthers(r.sync) == ["pc-aa", "pc-zz"])
    c.add("syncLastOkAt advanced", defaults.object(forKey: "syncLastOkAt") != nil)
    c.add("skip visible", !error.isEmpty)
    c.add("error text carries no raw URL / gist id", !error.contains("githubusercontent") && !error.contains(RL_FIX_GIST)
          && !error.contains("/raw/"))
    expect(c.failed.isEmpty, "C1-18 S1: invalid UTF-8 (2 MiB FF FE…) and an empty 200 body skip only that file; the cycle merges "
           + "the rest (sync-protocol.md «one bad record never stops the merge»)" + c.suffix)

    // Budget: 63 MiB read, then exactly 1 MiB of binary → 64 MiB spent; the next file is not even requested.
    var budgetFiles: [String: Any] = [:]
    var budgetRaw: [String: Data] = [:]
    for i in 0..<8 {
        let n = "machine-b\(i).json"
        budgetFiles[n] = rlRawRef(n)
        budgetRaw[RL_RAW_BASE + n] = Data(rlPadded("b\(i)", bytes: 8 * mib - mib / 8).utf8)
    }
    budgetFiles["machine-c-bin.json"] = rlRawRef("machine-c-bin.json")
    budgetRaw[RL_RAW_BASE + "machine-c-bin.json"] = Data(repeating: 0xFF, count: mib)
    budgetFiles["machine-d-next.json"] = rlRawRef("machine-d-next.json")
    budgetRaw[RL_RAW_BASE + "machine-d-next.json"] = Data(rlSmall("d-next").utf8)
    let b = rlSyncOnce(defaults, root, files: budgetFiles, raw: budgetRaw, reset: true)
    var g = RLChecks()
    g.add("files before the binary merged", rlOthers(b.sync).contains("pc-b0") && rlOthers(b.sync).contains("pc-b7"))
    g.add("syncLastOkAt advanced", defaults.object(forKey: "syncLastOkAt") != nil)
    g.add("next file not requested (got \(b.rawGets.filter { $0.hasSuffix("machine-d-next.json") }.count))",
          !b.rawGets.contains { $0.hasSuffix("machine-d-next.json") })
    g.add("next file not merged", !rlOthers(b.sync).contains("pc-d-next"))
    expect(g.failed.isEmpty, "C1-18 S1: the skipped binary body is counted in the 64 MiB budget before it is dropped (Sol)" + g.suffix)
    defaults.clear()
    try? FileManager.default.removeItem(atPath: root + "/rl-remote-fix.json")
}

// MARK: C1-19 (S2) the gist id never lands in sync-remote.json

private func rlC119(_ defaults: MemorySelfTestDefaults, _ root: String, _ expect: RLExpect) {
    let now = Date()
    guard let label = accountLabel(product: "claude", localId: RL_UUID_A, gistId: RL_FIX_GIST) else {
        expect(false, "C1-19 precondition: accountLabel for the selftest gist"); return
    }
    let seen = now.addingTimeInterval(-60)
    let vps = rlMachineFile("fixturevps", name: "vps", updated: seen, lastSeenAt: seen,
                            accounts: [rlAcct("claude", label, asOf: seen, pct: 33, nextAt: seen.addingTimeInterval(900))])
    let path = root + "/rl-remote-fix.json"
    try? FileManager.default.removeItem(atPath: path)
    _ = rlSyncOnce(defaults, root, files: ["machine-fixturevps.json": ["content": vps]], raw: [:], reset: true)
    let bytes = FileManager.default.contents(atPath: path)
    let text = bytes.map { String(decoding: $0, as: UTF8.self) } ?? ""
    let occurrences = text.components(separatedBy: RL_FIX_GIST).count - 1         // a count only, never the value
    var c = RLChecks()
    c.add("precondition: the cycle wrote sync-remote.json", bytes != nil && !text.isEmpty)
    c.add("gist id occurrences in the file = 0 (got \(occurrences))", bytes != nil && occurrences == 0)
    let decoded = bytes.flatMap { try? JSONDecoder().decode(SyncRemoteCache.self, from: $0) }
    var mine = LimitData(); mine.session = 10; mine.asOf = now.addingTimeInterval(-30); mine.apiFresh = true
    let views = decoded.map {
        resolveAccounts(local: (mine, rlAbsent()), localIds: ["claude": RL_UUID_A], remote: $0, hidden: [], menu: [:],
                        sync: ReaderSyncState(phase: .on), now: now).filter { $0.product == "claude" }
    } ?? []
    c.add("after a restart (decode) the local Claude still groups with the vps record",
          views.count == 1 && views.first?.isLocal == true && views.first?.label == label && views.first?.machines.contains("vps") == true)
    expect(c.failed.isEmpty, "C1-19 S2: sync-remote.json keeps a derived label key, not the gist id (grep -c = 0)" + c.suffix)
    defaults.clear()
    try? FileManager.default.removeItem(atPath: path)
}

// MARK: C1-20 (S3) future foreign times cannot pin «fresh» / «online» / «service wait» / a caption

private func rlC120(_ expect: RLExpect) {
    let now = rlDate("2026-10-12T12:00:00Z")
    let far = rlDate("2099-01-01T00:00:00Z")
    func card(_ files: [String: String], at: Date) -> AccountView? {
        let views = rlResolve(rlCache(files, now: at), now: at).filter { $0.product == "claude" && !$0.isLocal }
        return views.count == 1 ? views[0] : nil
    }
    func vps(_ record: [String: Any], updated: Date?, lastSeen: Any?) -> [String: String] {
        ["machine-fixturevps.json": rlMachineFile("fixturevps", name: "vps", updated: updated, lastSeenAt: lastSeen, accounts: [record])]
    }
    let asOf = now.addingTimeInterval(-60)
    let seen = now.addingTimeInterval(-60)

    // (a) nextAt: accepted only while ≤ now + interval + 60; beyond — fall back to asOf + interval.
    var a = RLChecks()
    let farNext = vps(rlAcct("claude", RL_CLAUDE_V11, asOf: asOf, pct: 40, interval: 900, nextAt: far), updated: seen, lastSeen: seen)
    let fallback = asOf.addingTimeInterval(900 + 1200)
    let farUntil: Date? = card(farNext, at: now)?.data.source?.freshUntil
    a.add("nextAt 2099 → freshUntil = asOf + I + 20 min (got \(farUntil.map { rlStr($0) } ?? "nil"))", farUntil == fallback)
    let lateSeen = fallback.addingTimeInterval(1 - 60)                 // keep the source online at the check time
    let later = vps(rlAcct("claude", RL_CLAUDE_V11, asOf: asOf, pct: 40, interval: 900, nextAt: far), updated: lateSeen, lastSeen: lateSeen)
    a.add("…and 1 s after it the card is stale (2), not fresh", card(later, at: fallback.addingTimeInterval(1))?.state.rawValue == 2)
    let border = vps(rlAcct("claude", RL_CLAUDE_V11, asOf: asOf, pct: 40, interval: 900, nextAt: now.addingTimeInterval(960)),
                     updated: seen, lastSeen: seen)
    a.add("border: nextAt = now + I + 60 accepted", card(border, at: now)?.data.source?.freshUntil == now.addingTimeInterval(960 + 1200))
    let over = vps(rlAcct("claude", RL_CLAUDE_V11, asOf: asOf, pct: 40, interval: 900, nextAt: now.addingTimeInterval(961)),
                   updated: seen, lastSeen: seen)
    a.add("border: nextAt = now + I + 61 → fallback", card(over, at: now)?.data.source?.freshUntil == fallback)
    expect(a.failed.isEmpty, "C1-20(a) S3: a future nextAt (> now + interval + 60) never extends «fresh» (rule 2026-10-15)" + a.suffix)

    // (b) lastSeenAt > now + 60 → not alive: falls back to updated.
    var b = RLChecks()
    let rec = rlAcct("claude", RL_CLAUDE_V11, asOf: asOf, pct: 40, interval: 900, nextAt: asOf.addingTimeInterval(900))
    let old = now.addingTimeInterval(-2400)
    b.add("lastSeenAt 2099, updated 40 min → offline (5)", card(vps(rec, updated: old, lastSeen: far), at: now)?.state.rawValue == 5)
    b.add("lastSeenAt now + 61, updated 40 min → 5", card(vps(rec, updated: old, lastSeen: now.addingTimeInterval(61)), at: now)?.state.rawValue == 5)
    b.add("border: lastSeenAt now + 60 is alive → 1", card(vps(rec, updated: old, lastSeen: now.addingTimeInterval(60)), at: now)?.state.rawValue == 1)
    expect(b.failed.isEmpty, "C1-20(b) S3: a future lastSeenAt never pins «online»" + b.suffix)

    // (c) retryUntil 2099: «service wait» (4) ends ≤ 24 h after the attempt.
    var c = RLChecks()
    let attempt = now
    func retryCard(at: Date) -> Int? {
        let r = rlAcct("claude", RL_CLAUDE_V11, status: "rate_limited", asOf: attempt, pct: 40, interval: 14400,
                       nextAt: attempt.addingTimeInterval(14400), retryUntil: far)
        let s = at.addingTimeInterval(-60)
        return card(vps(r, updated: s, lastSeen: s), at: at)?.state.rawValue
    }
    c.add("control: 1 h after the attempt → 4", retryCard(at: attempt.addingTimeInterval(3600)) == 4)
    c.add("24 h + 1 s after the attempt → not 4 (got \(retryCard(at: attempt.addingTimeInterval(86401)).map { String($0) } ?? "no card"))",
          retryCard(at: attempt.addingTimeInterval(86401)) != 4)
    expect(c.failed.isEmpty, "C1-20(c) S3: a far-future retryUntil shows «service wait» for ≤ 24 h after attemptAt" + c.suffix)

    // (d) caption with setAt 2099 never beats a normal newer one, whatever the file order.
    var d = RLChecks()
    for (evilFile, goodFile) in [("machine-a-evil.json", "machine-z-good.json"), ("machine-z-evil.json", "machine-a-good.json")] {
        let evilId = String(evilFile.dropFirst(8).dropLast(5)), goodId = String(goodFile.dropFirst(8).dropLast(5))
        let files = [
            evilFile: rlMachineFile(evilId, name: "evil", updated: seen, lastSeenAt: seen, accounts: [rec],
                                    captions: [RL_CLAUDE_V11: ["text": "evil", "setAt": rlStr(far)]]),
            goodFile: rlMachineFile(goodId, name: "good", updated: seen, lastSeenAt: seen, accounts: [],
                                    captions: [RL_CLAUDE_V11: ["text": "good", "setAt": rlStr(now.addingTimeInterval(-60))]])]
        let merged = mergeV11(files, excluding: "selftest-mac", now: now)
        d.add("\(evilFile) first: merged caption = good (got \(merged.captions?[RL_CLAUDE_V11]?.text ?? "nil"))",
              merged.captions?[RL_CLAUDE_V11]?.text == "good")
        d.add("\(evilFile) first: card caption = good", card(files, at: now)?.caption == "good")
    }
    expect(d.failed.isEmpty, "C1-20(d) S3: a caption with setAt > now + 60 loses to a normal one" + d.suffix)

    // (e) updated 2099 without lastSeenAt never pins «online»: the card is absent or offline, never fresh.
    let futureUpdated = card(vps(rec, updated: far, lastSeen: nil), at: now)
    expect(futureUpdated == nil || futureUpdated?.state.rawValue == 5,
           "C1-20(e) S3: updated > now + 60 without lastSeenAt → no «online» card (got \(futureUpdated.map { String($0.state.rawValue) } ?? "no card"))")
}

// MARK: runner

/// C1 entry point, called from the `--sync-selftest` block. Returns the number of failed checks.
func runRemoteLimitsSelfTests(defaults: MemorySelfTestDefaults, root: String) -> Int {
    var failures = 0, checks = 0
    func expect(_ ok: Bool, _ label: String) {
        checks += 1
        print("\(ok ? "OK" : "FAIL") \(label)")
        if !ok { failures += 1 }
    }
    let dir = remoteLimitsFixturesDir()
    expect(dir != nil, "C1 fixtures/remote-limits found at \(dir ?? "— none: pass --rl-fixtures <dir> or CCL_RL_FIXTURES")")
    let fx = dir.map { RLFixtures(dir: $0) }
    if let fx = fx {
        rlC101(fx, expect)
        rlC102Control(fx, expect)
        rlC102Hostile(fx, expect)
        rlC102NonStrict(fx, expect)
        rlC102Strings(fx, expect)
        rlC103(fx, expect)
        rlC104(fx, expect)
        rlC105(fx, expect)
        rlC108(fx, expect)
        rlC109(fx, expect)
    }
    rlC102T36(expect)
    rlC102Limits(expect)
    rlC102SyncLimits(defaults, root, expect)
    rlC106(expect)
    rlC107(fx, expect)
    // C1 fix cycle 1 (2026-10-18)
    rlC110(defaults, root, expect)
    rlC111(expect)
    rlC112(expect)
    rlC113(defaults, root, expect)
    rlC114(defaults, root, expect)
    rlC115(expect)
    rlC116(expect)
    rlC117(defaults, root, expect)
    rlC118(defaults, root, expect)
    rlC119(defaults, root, expect)
    rlC120(expect)
    print(failures == 0 ? "OK C1 remote-limits: all \(checks) checks passed" : "FAIL C1 remote-limits: \(failures) of \(checks) checks failed")
    return failures
}
