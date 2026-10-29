import Foundation
import CryptoKit

// C4 part 1 — RED before implementation, 2026-10-29 (P13).
// Source: plans §C4; test-plan C4-01…11; sync-protocol v1.1; security P3/P7/T11/T23…25/T31…32/T35.
// Isolation 006/011: injected time, SelfTestHTTP and ScriptedSyncKeychain; files only beneath
// the runner's unique temporary root. Never calls AppDelegate.doRefresh, CLI, real Keychain,
// real auth.json/cache/history, NSApplication or network. No wall-clock sleep/timeouts.
// A negative provider assertion always checks the ledger, plus credential/cache stat+sha.
// Entry: runRemoteLimitsC4SelfTests(defaults:root:) before NSApplication.shared in --sync-selftest.

private typealias C4Expect = (Bool, String) -> Void
private let C4_NOW = Date(timeIntervalSince1970: 1_791_800_000)
private let C4_GIST = "fixturegist0000000000000000000001"
private let C4_ID = "c0dex000-1111-4222-8333-444455556666"
private let C4_MACHINE = "selftest-c4-mac"
private let C4_VPS = "selftest-c4-vps"
private let C4_API = "https://api.github.com"
private func c4JSON(_ value: Any) -> Data { (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data() }
private func c4Object(_ data: Data?) -> [String: Any] { guard let data = data else { return [:] }; return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:] }
private func c4Canon(_ value: Any?) -> String {
    let wrapped: [Any] = [value ?? NSNull()]
    return String(decoding: c4JSON(wrapped), as: UTF8.self)
}
private func c4Reply(_ status: Int, _ object: Any? = nil, headers: [String: String] = [:]) -> SyncHTTPResult {
    (status, object.map(c4JSON), nil, headers)
}
private func c4ISO(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
private func c4Fresh(_ date: Date = C4_NOW) -> LimitData {
    var data = LimitData(); data.session = 42.5; data.weekly = 61; data.plan = "pro"
    data.resetCredits = 2; data.asOf = date; data.apiFresh = true
    data.sessionReset = date.addingTimeInterval(3600); data.weeklyReset = date.addingTimeInterval(86400)
    return data
}
private final class C4Ledger {
    var entries: [(seq: Int, event: String)] = []
    func add(_ event: String) { entries.append((entries.count + 1, event)) }
    var names: [String] { entries.map { $0.event } }
    func count(_ event: String) -> Int { names.filter { $0 == event }.count }
}
private struct C4FileStamp: Equatable {
    let sha: String, size: UInt64, inode: UInt64, modified: Date?
    init(_ path: String) {
        let bytes = FileManager.default.contents(atPath: path) ?? Data()
        let attrs = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
        sha = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        inode = (attrs[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        modified = attrs[.modificationDate] as? Date
    }
}
private func c4Write(_ object: Any, _ path: String) {
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try? c4JSON(object).write(to: URL(fileURLWithPath: path), options: .atomic)
}
private func c4Auth(_ path: String, access: String, refresh: String = "synthetic-refresh", id: String = C4_ID) {
    c4Write(["tokens": ["access_token": access, "refresh_token": refresh, "account_id": id],
             "untouched": ["keep": "CLI-owned"]], path)
}
private func c4JWT(expiry: TimeInterval) -> String {
    let payload = c4JSON(["exp": expiry]).base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    return "fixture." + payload + ".unsigned"
}
private func c4Remote(attemptAge: TimeInterval = 10000, asOfAge: TimeInterval = 10000,
                      retry: Date? = nil, status: String = "ok", now: Date = C4_NOW) -> SyncRemoteCache {
    var account = RemoteAccount(product: "codex", label: accountLabel(product: "codex", localId: C4_ID, gistId: C4_GIST), status: status)
    account.machineId = C4_VPS; account.machineName = "vps"; account.machineLastSeenAt = now
    account.attemptAt = now.addingTimeInterval(-attemptAge); account.asOf = now.addingTimeInterval(-asOfAge)
    account.retryUntil = retry
    account.schedule = RemoteSchedule(mode: "auto", interval: 900, nextAt: account.attemptAt?.addingTimeInterval(900))
    var cache = SyncRemoteCache(); cache.gistId = C4_GIST; cache.accounts = [account]
    return cache
}
private func c4Gist(_ extra: [String: Any] = [:]) -> [String: Any] {
    var files: [String: Any] = [SYNC_MANIFEST: ["content": "{}"], "machine-\(C4_MACHINE).json": ["content": "{}"]]
    for (key, value) in extra { files[key] = value }
    return ["id": C4_GIST, "public": false, "created_at": "2026-01-01T00:00:00Z", "files": files]
}
private func c4Prefs(_ defaults: MemorySelfTestDefaults, now: Date = C4_NOW) {
    defaults.clear(); defaults.set("selftest", forKey: "syncLogin"); defaults.set(C4_GIST, forKey: "syncGistId")
    defaults.set(now, forKey: "syncDiscoveredAt"); defaults.set("macbook", forKey: "machineName")
    defaults.set(true, forKey: "monitor_codex"); defaults.set(false, forKey: "monitor_claude")
}

// C4-04: exactly the Linux A3-01 vectors; expect optional keys have presence semantics.
private func c4C404(_ expect: C4Expect) {
    guard let dir = remoteLimitsFixturesDir(), let bytes = FileManager.default.contents(atPath: dir + "/decide-vectors.json"),
          let root = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
          let vectors = root["vectors"] as? [[String: Any]], let defaultNow = root["now"] as? Double, !vectors.isEmpty else {
        expect(false, "C4-04 shared decide-vectors.json readable"); return
    }
    var chainRetry: Any? = nil, chainAttempt: Double? = nil, chainCount = 0
    for vector in vectors {
        let id = vector["id"] as? String ?? "missing-id"
        let now = vector["now"] as? Double ?? defaultNow
        let mine = vector["mine"] as? [String: Any] ?? [:]
        let actual = coordinationDecide(now: now, mine: mine, remote: vector["remote"] as? [[String: Any]] ?? [],
                                        myId: vector["my_id"] as? String ?? "", tieWait: vector["tie_wait"] as? [Any])
        guard let expected = vector["expect"] as? [String: Any] else { expect(false, "C4-04 \(id): expect exists"); continue }
        for key in ["action", "reason", "tie_wait", "remote_retry", "events"] where expected.keys.contains(key) {
            expect(c4Canon(actual[key]) == c4Canon(expected[key]), "C4-04 \(id).\(key): Linux parity")
        }
        if ["chain_1_accept", "chain_2_expired_reaccept_inherits_first", "chain_3_cap_minus_1s_still_waits", "chain_4_cap_reached_polls", "chain_5_own_poll_clears_mark_new_chain"].contains(id) {
            chainCount += 1
            if chainCount > 1 {
                expect(c4Canon(mine["remote_retry"]) == c4Canon(chainRetry), "C4-04 \(id): persisted retry input")
                if let previous = chainAttempt {
                    expect((mine["last_attempt"] as? Double) == previous, "C4-04 \(id): last own attempt persisted")
                }
            }
            chainRetry = actual["remote_retry"]
            chainAttempt = actual["action"] as? String == "poll" ? now : (mine["last_attempt"] as? Double)
        }
    }
    expect(chainCount == 5, "C4-04 chain_1…chain_5 exercised")
    let malformed: [Any] = [true, "1791800000", NSNull(), Double.infinity, Double.nan]
    for value in malformed {
        let result = coordinationDecide(now: C4_NOW.timeIntervalSince1970,
            mine: ["interval": 900, "last_attempt": C4_NOW.timeIntervalSince1970 - 900],
            remote: [["machineId": C4_VPS, "lastSeenAt": value, "attemptAt": C4_NOW.timeIntervalSince1970]],
            myId: C4_MACHINE, tieWait: nil)
        expect(result["action"] as? String == "poll", "C4-04 malformed lastSeenAt cannot suppress")
    }
}

// One ledger across actual GitHubSync GET/PATCH, durable save and the provider trap.
// The saved poll is also the injected publisher snapshot: PATCH bodies come from production.
private final class C4Harness {
    let root: String
    let defaults = MemorySelfTestDefaults()
    let keychain = SelfTestKeychainStore("fixture-token")
    let ledger = C4Ledger()
    var now = C4_NOW
    var saved = C4TickState(poll: AutoPollState())
    var codex = c4Fresh(C4_NOW.addingTimeInterval(-10000))
    var remote = c4Remote()
    var events: [[String: Any]] = []
    var timers: [() -> Void] = []
    var timerDurations: [TimeInterval] = []
    var patchSavedAttempts: [Double] = [], providerSavedAttempts: [Double] = []
    var decisions: [([String: Any], Date?)] = []
    var dropRead = false, failRead = false, failSave = false, failPatch = false
    var canPollWithoutRead = true
    var patchStatuses: [Int] = [], retryable = false
    var patches: [[String: Any]] = []
    var providerCalls = 0, applied = 0, completionCalls = 0
    var localId = C4_ID
    var peerId = C4_VPS
    var omitHeartbeat = false
    var remoteHeartbeat: Date? = nil
    var usageInput = 1
    var mutateAtPatch: (() -> Void)? = nil, mutateAtProvider: (() -> Void)? = nil
    lazy var http = SelfTestHTTP { [unowned self] call in
        if call.url == C4_API + "/gists/" + C4_GIST, call.method == "GET" {
            self.ledger.add("GET")
            if self.failRead { return c4Reply(503) }
            let account = self.remote.accounts?.first
            var record: [String: Any] = ["product": "codex", "label": account?.label ?? "", "status": account?.status ?? "ok", "days": [:]]
            if let value = account?.attemptAt { record["attemptAt"] = c4ISO(value); record["attemptKind"] = "auto" }
            if let value = account?.asOf { record["asOf"] = c4ISO(value) }
            if let value = account?.retryUntil { record["retryUntil"] = c4ISO(value) }
            if let value = account?.schedule {
                var schedule: [String: Any] = ["mode": "auto", "interval": value.interval, "backoff": false]
                if let next = value.nextAt { schedule["nextAt"] = c4ISO(next) }
                record["schedule"] = schedule
            }
            var machine: [String: Any] = ["schema": 1, "machine": ["id": self.peerId, "name": "vps", "os": "fixture", "app": "fixture"],
                "updated": c4ISO(self.now), "lastSeenAt": c4ISO(self.now), "days": [:], "accounts": [record], "unattributedDays": [:]]
            if self.omitHeartbeat { machine.removeValue(forKey: "lastSeenAt") }
            else if let heartbeat = self.remoteHeartbeat { machine["lastSeenAt"] = c4ISO(heartbeat) }
            return c4Reply(200, c4Gist(["machine-\(self.peerId).json": ["content": String(decoding: c4JSON(machine), as: UTF8.self)]]))
        }
        if call.url == C4_API + "/gists/" + C4_GIST, call.method == "PATCH" {
            let body = c4Object(call.body)
            let files = body["files"] as? [String: Any] ?? [:]
            let file = files["machine-\(C4_MACHINE).json"] as? [String: Any] ?? [:]
            let content = file["content"] as? String ?? ""
            self.patches.append(c4Object(Data(content.utf8))); self.patchSavedAttempts.append(self.saved.poll.lastAttempt); self.ledger.add("PATCH")
            let status = !self.patchStatuses.isEmpty ? self.patchStatuses.removeFirst() : (self.failPatch ? 503 : 200)
            self.mutateAtPatch?()
            return c4Reply(status, [:])
        }
        if call.url == "https://chatgpt.com/backend-api/wham/usage" {
            self.providerCalls += 1; self.providerSavedAttempts.append(self.saved.poll.lastAttempt); self.ledger.add("fetchCodex"); self.mutateAtProvider?()
            return c4Reply(200, ["rate_limit": ["primary_window": ["used_percent": 42.5, "limit_window_seconds": 18000,
                "reset_at": Int(self.now.timeIntervalSince1970 + 3600)]], "plan_type": "pro"])
        }
        self.ledger.add("UNEXPECTED " + call.method)
        return c4Reply(599)
    }
    lazy var sync = GitHubSync(transport: http.transport, keychain: ScriptedSyncKeychain(store: keychain),
        defaults: defaults, remotePath: root + "/sync-remote.json", machineId: C4_MACHINE, revokeRecheckDelay: 0,
        clock: { [unowned self] in self.now }, publisherSnapshot: { [unowned self] in
            C4PublisherSnapshot(days: self.days, accountByDay: ["codex": ["2026-10-12": self.localId]],
                localId: self.localId, codex: self.codex, poll: self.saved.poll, attemptKind: "auto")
        }, pollLogPath: root + "/poll-log.jsonl")
    lazy var controller = C4TickController(state: saved, myId: C4_MACHINE, localId: localId,
        dependencies: C4TickDependencies(clock: { [unowned self] in self.now }, read: { [unowned self] completion in
            if self.dropRead { self.ledger.add("READ_NO_COMPLETION"); return }
            completion(self.sync.syncSynchronously(mode: .full, deferWrite: true))
        }, writeOnly: { [unowned self] completion in
            completion(self.sync.syncSynchronously(mode: .writeOnly))
        }, save: { [unowned self] state in
            self.ledger.add("save")
            guard !self.failSave else { return false }
            self.saved = state
            // A real atomic temp-file write proves save occurred before any provider I/O.
            guard let data = try? JSONEncoder().encode(state) else { return false }
            do { try data.write(to: URL(fileURLWithPath: self.root + "/tick-state.json"), options: .atomic); return true } catch { return false }
        }, fetch: { [unowned self] in
            _ = self.http.transport("https://chatgpt.com/backend-api/wham/usage", "GET", [:], nil, 15)
            return c4Fresh(self.now)
        }, emit: { [unowned self] event in
            self.events.append(event); _ = appendPollLog([event], path: self.root + "/poll-log.jsonl")
        }, armTimeout: { [unowned self] delay, action in self.timerDurations.append(delay); self.timers.append(action) },
        apply: { [unowned self] result in self.applied += 1; self.codex = result },
        retryableWriteFailure: { [unowned self] in self.retryable },
        currentLocalId: { [unowned self] in self.localId },
        onDecision: { [unowned self] decision, nextAt in self.decisions.append((decision, nextAt)) },
        canPollWithoutRead: { [unowned self] in self.canPollWithoutRead }))
    var days: [String: Any] {
        ["codex": ["2026-10-12": ["gpt-6-astra": ["input": usageInput, "output": 2, "cacheRead": 3, "cacheWrite5m": 0, "cacheWrite1h": 0, "turns": 1]]]]
    }
    init(_ root: String) {
        self.root = root
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        c4Prefs(defaults); saved.poll.interval = 900; saved.poll.lastAttempt = C4_NOW.timeIntervalSince1970 - 10000
        c4Auth(root + "/auth.json", access: c4JWT(expiry: C4_NOW.timeIntervalSince1970 + 3600))
        c4Write(["codex": ["accountId": C4_ID, "session": 10]], root + "/cache.json")
    }
    func tick(manual: Bool = false) { controller.tick(manual: manual) { [unowned self] in self.completionCalls += 1 } }
    func skipped(_ reason: String) -> Bool { events.contains { $0["ev"] as? String == "poll_skipped" && $0["reason"] as? String == reason } }
    var authStamp: C4FileStamp { C4FileStamp(root + "/auth.json") }
    var cacheStamp: C4FileStamp { C4FileStamp(root + "/cache.json") }
    var journalEvents: [[String: Any]] {
        ((try? String(contentsOfFile: root + "/poll-log.jsonl", encoding: .utf8)) ?? "")
            .split(separator: "\n").map { c4Object(Data($0.utf8)) }
    }

}

private func c4C401(_ root: String, _ expect: C4Expect) {
    let h = C4Harness(root + "/c401")
    let ids = readLocalAccountIds(products: ["codex"], paths: ["codex": h.root + "/auth.json"])
    expect(ids["codex"] == C4_ID, "C4-01 identity comes from synthetic tokens.account_id")
    _ = h.sync.syncSynchronously()
    guard let file = h.patches.first, let records = file["accounts"] as? [[String: Any]], let record = records.first else {
        expect(false, "C4-01 actual machine PATCH contains accounts"); return
    }
    expect(records.count == 1 && record["product"] as? String == "codex", "C4-01 Mac publishes only its own Codex")
    expect(record["label"] as? String == accountLabel(product: "codex", localId: C4_ID, gistId: C4_GIST), "C4-01 current gist HMAC")
    expect(file["schema"] as? Int == 1 && file["lastSeenAt"] as? String == c4ISO(C4_NOW), "C4-01 schema1 + injected heartbeat")
    expect(record["localId"] == nil && record["accountId"] == nil, "C4-01 raw local identity never leaves Mac")
    expect(record["asOf"] as? String == c4ISO(h.codex.asOf!), "C4-01 successful asOf retained")
    expect(record["plan"] as? String == "pro" && record["resetCredits"] as? Int == 2, "C4-01 Codex plan/credits")
    expect(c4Canon(record["days"]) == c4Canon((h.days["codex"] as? [String: Any]) ?? [:]), "C4-01 account days attribution")
    expect((file["captions"] as? [String: Any])?.isEmpty == true && file["unattributedDays"] != nil, "C4-01 additive v1.1 fields")
    let schedule = record["schedule"] as? [String: Any] ?? [:]
    expect(schedule["nextAt"] as? String == c4ISO(Date(timeIntervalSince1970: h.saved.poll.lastAttempt + h.saved.poll.interval)), "C4-01 cadence nextAt excludes provider retry")
    expect(h.http.calls.filter { $0.url.contains("chatgpt.com") }.isEmpty, "C4-01 publishing is not provider polling")
    let cachePath = h.root + "/completed-cache.json"
    _ = c4CacheQuotaCompletion(product: "codex", response: c4Fresh(), previous: LimitData(present: false),
        previousId: nil, readingId: C4_ID, path: cachePath)
    let cache = c4Object(FileManager.default.contents(atPath: cachePath))["codex"] as? [String: Any] ?? [:]
    expect(cache["accountId"] as? String == C4_ID && cache["session"] as? Double == 42.5,
           "C4-01 actual production completion helper stores raw localId locally")
    let unbound = c4MachineFile(days: h.days, accountByDay: [:], localId: C4_ID, codex: h.codex, poll: h.saved.poll,
        gistId: C4_GIST, machineId: C4_MACHINE, machineName: "macbook", osName: "fixture", now: C4_NOW)
    let unboundRecord = (unbound["accounts"] as? [[String: Any]])?.first
    expect((unboundRecord?["days"] as? [String: Any])?.isEmpty == true,
           "C4-01 historical unbound days never attributed to current account")
    expect(c4Canon((unbound["unattributedDays"] as? [String: Any])?["codex"]) == c4Canon(h.days["codex"]),
           "C4-01 unbound days go to unattributed projection")
    let changedId = "cccccccc-1111-4222-8333-444455556666"
    let cacheBefore = C4FileStamp(cachePath)
    let switched = c4CacheQuotaCompletion(product: "codex", response: LimitData(error: "synthetic failure"), previous: c4Fresh(),
        previousId: C4_ID, readingId: changedId, path: cachePath)
    expect(switched.data.session == nil && C4FileStamp(cachePath) == cacheBefore,
           "C4-01 account switch does not reuse A snapshot for B")

}

private func c4C402(_ root: String, _ expect: C4Expect) {
    let h = C4Harness(root + "/c402"), auth = C4FileStamp(root + "/c402/auth.json")
    h.tick()
    let io = h.ledger.names.filter { ["GET", "PATCH", "fetchCodex"].contains($0) }
    expect(io == ["GET", "PATCH", "fetchCodex", "PATCH"], "C4-02 one GET → PATCH attempt → provider → PATCH result")
    let firstPatchIndex = h.ledger.names.firstIndex(of: "PATCH") ?? -1
    let firstSaveIndex = h.ledger.names.firstIndex(of: "save") ?? Int.max
    expect(firstSaveIndex < firstPatchIndex, "C4-02 attempt saved durably before announcement")
    expect(h.patchSavedAttempts.first == C4_NOW.timeIntervalSince1970 && h.providerSavedAttempts == [C4_NOW.timeIntervalSince1970],
           "C4-02 actual reserved timestamp durable at PATCH1 and provider entry")
    let records = h.patches.first?["accounts"] as? [[String: Any]]
    expect(records?.first?["attemptAt"] as? String == c4ISO(C4_NOW), "C4-02 PATCH1 contains reserved attemptAt")
    let final = (h.patches.last?["accounts"] as? [[String: Any]])?.first
    expect(final?["asOf"] as? String == c4ISO(C4_NOW) && final?["status"] as? String == "ok", "C4-02 PATCH2 contains provider result")
    expect(h.providerCalls == 1 && h.applied == 1 && h.completionCalls == 1, "C4-02 one provider/apply/completion")
    expect(h.authStamp == auth && h.keychain.writes == 0 && h.keychain.deletes == 0, "C4-02 credentials untouched")
}

private func c4C403(_ root: String, _ expect: C4Expect) {
    for failure in ["patch", "read", "timeout", "save"] {
        let h = C4Harness(root + "/c403-" + failure)
        h.failPatch = failure == "patch"; h.failRead = failure == "read"; h.dropRead = failure == "timeout"; h.failSave = failure == "save"
        let oldAttempt = h.saved.poll.lastAttempt, auth = h.authStamp, cache = h.cacheStamp
        h.tick()
        if failure == "timeout" {
            expect(h.providerCalls == 0 && h.completionCalls == 0, "C4-03 timeout pending before injected deadline")
            expect(h.timerDurations.first == 60, "C4-03 timeout is exactly60 injected seconds")
            h.timers.forEach { $0() }; h.timers.forEach { $0() }
        }
        expect(h.providerCalls == 0 && !h.ledger.names.contains("fetchCodex"), "C4-03 \(failure): zero provider transport")
        expect(h.controller.state.poll.lastAttempt == oldAttempt, "C4-03 \(failure): reservation rolled back")
        expect(h.authStamp == auth && h.cacheStamp == cache, "C4-03 \(failure): auth/cache sha+mtime+inode unchanged")
        expect(h.completionCalls == 1, "C4-03 \(failure): completion exactly once")
        if failure != "save" { expect(h.skipped("publish_failed"), "C4-03 \(failure): O1 publish_failed reason") }
        if failure == "read" || failure == "timeout" {
            expect(h.patches.isEmpty, "C4-03 \(failure): no PATCH without valid GET")
        }
    }
    let h = C4Harness(root + "/c403-series"); h.failPatch = true
    h.tick(); expect(h.providerCalls == 0, "C4-03 first publication failure skips")
    h.now = h.now.addingTimeInterval(600); h.tick(); expect(h.providerCalls == 0, "C4-03 second publication failure skips")
    h.now = h.now.addingTimeInterval(600); h.tick(); expect(h.providerCalls == 1, "C4-03 third publication failure uses own B1 cadence")
    let day = C4Harness(root + "/c403-day"); day.failPatch = true
    day.saved.poll.lastAttempt = day.now.timeIntervalSince1970 - 86400
    day.tick(); expect(day.providerCalls == 1, "C4-03 24h starvation escape on first failed announcement")
    let reopen = C4Harness(root + "/c403-reopen"); reopen.patchStatuses = [409, 409]; reopen.retryable = true
    reopen.tick()
    expect(reopen.providerCalls == 0 && reopen.ledger.count("GET") == 2, "C4-03 stale/busy write reopens once only")
}

private func c4C405(_ root: String, _ expect: C4Expect) {
    for manual in [false, true] {
        let h = C4Harness(root + "/c405-\(manual)")
        h.remote = c4Remote(retry: C4_NOW.addingTimeInterval(3600), status: "rate_limited")
        let auth = h.authStamp, cache = h.cacheStamp
        h.tick(manual: manual)
        expect(h.providerCalls == 0 && h.patches.isEmpty && h.ledger.count("GET") == 1, "C4-05 \(manual): remote retry +1h suppresses provider")
        expect(h.controller.remoteRetry?["until"] == C4_NOW.timeIntervalSince1970 + 3600, "C4-05 foreign deadline persisted separately")
        expect(h.controller.state.poll.serverRetryAt == nil, "C4-05 foreign retry never enters own serverRetryAt")
        expect(h.authStamp == auth && h.cacheStamp == cache, "C4-05 skipped provider: credentials/cache stat+sha unchanged")
    }
}

private func c4C406(_ root: String, _ expect: C4Expect) {
    for age in [0.0, 300, 899, 900, 959, 960] {
        let h = C4Harness(root + "/c406-\(Int(age))")
        h.remote = c4Remote(attemptAge: age, asOfAge: 10000, status: "error")
        let auth = h.authStamp, cache = h.cacheStamp
        h.tick(manual: true)
        expect(h.providerCalls == (age < 960 ? 0 : 1), "C4-06 manual remote failed attempt age \(Int(age)): 960s gate")
        expect(h.authStamp == auth && h.cacheStamp == cache, "C4-06 manual age \(Int(age)): auth/cache unchanged")
        guard let (decision, nextAt) = h.decisions.last else {
            expect(false, "C4-06 manual decision callback exists"); continue
        }
        let remoteClaude = AccountView(product: "claude", label: "c400000000000001", historyKey: "fixture", caption: "Claude · vps",
            data: LimitData(), isLocal: false, tier: nil, usageDays: [:], machines: ["vps"], state: .fresh)
        let products = remoteManualProviderProducts(views: [remoteClaude], localIds: ["codex": C4_ID], enabled: ["codex", "claude"],
            decisions: ["codex": decision])
        expect(products == (age < 960 ? Set<String>() : Set(["codex"])), "C4-06 provider filter consumes actual decide; remote Claude stays read-only")
        if age < 960 {
            let expected = C4_NOW.addingTimeInterval(960 - age)
            expect(nextAt == expected, "C4-06 remote attempt pollAllowed exact960s deadline")
            if let nextAt = nextAt {
                var local = remoteClaude; local.product = "codex"; local.isLocal = true
                let text = remoteCardLine2(local, state: local.state, phase: .pollAllowed(nextAt), lang: "ru", wide: true,
                    now: C4_NOW, timeZone: TimeZone(secondsFromGMT: 0)!)
                expect(text.hasPrefix("Опрос можно с "), "C4-06 shared decision appears as pollAllowed UX copy")
            }
        }

    }
    let own = C4Harness(root + "/c406-own"); own.saved.poll.lastAttempt = own.now.timeIntervalSince1970 - 899
    own.tick(manual: true); expect(own.providerCalls == 0, "C4-06 manual respects own 900s floor")
    let ownBoundary = C4Harness(root + "/c406-own900"); ownBoundary.saved.poll.lastAttempt = ownBoundary.now.timeIntervalSince1970 - 900
    ownBoundary.tick(manual: true); expect(ownBoundary.providerCalls == 1, "C4-06 own900s allows exactly one manual request")

    let reader = C4Harness(root + "/c406-reader")
    let control = RemoteManualRefreshController(clock: { reader.now }, read: { callback in
        let outcome = reader.sync.syncSynchronously(mode: .readOnly)
        if case .success = outcome { callback(true) } else { callback(false) }
    })
    _ = control.request(); _ = control.request()
    expect(reader.ledger.count("GET") == 1 && reader.patches.isEmpty && reader.providerCalls == 0, "C4-06 remote manual read only; repeated click guarded 30s")
    reader.now = reader.now.addingTimeInterval(30); _ = control.request()
    expect(reader.ledger.count("GET") == 2, "C4-06 read guard expires at injected 30s")
}

private func c4C407(_ root: String, _ defaults: MemorySelfTestDefaults, _ expect: @escaping C4Expect) {
    for policy in ["never", "invalid-policy", ""] {
        let path = root + "/c407-" + (policy.isEmpty ? "unset" : policy) + "/auth.json"
        c4Auth(path, access: c4JWT(expiry: C4_NOW.timeIntervalSince1970 - 1))
        let before = C4FileStamp(path), ledger = C4Ledger()
        let io = CodexCredentialIO(authPath: path, now: { C4_NOW }, policy: { policy }, http: { _, _, _, _, _, _ in
            ledger.add("HTTP"); return c4Reply(599)
        })
        let token = codexAccessToken(io: io)
        expect(token.failure?.expiredReason == "cli_refresh_pending", "C4-07 \(policy): explicit CLI refresh pending reason")
        expect(token.credential == nil && token.failure?.auth == .expired, "C4-07 \(policy): expired token waits for CLI")
        expect(ledger.entries.isEmpty && C4FileStamp(path) == before, "C4-07 \(policy): zero POST, auth sha+mtime+size+inode unchanged")
    }
    for policy in ["guarded", "legacy"] {
        let path = root + "/c407-" + policy + "/auth.json"
        let oldAccess = c4JWT(expiry: C4_NOW.timeIntervalSince1970 - 1)
        c4Auth(path, access: oldAccess)
        let before = C4FileStamp(path), newAccess = c4JWT(expiry: C4_NOW.timeIntervalSince1970 + 3600)
        var calls = 0, noRedirectFlags: [Bool] = []
        let io = CodexCredentialIO(authPath: path, now: { C4_NOW }, policy: { policy }, http: { url, method, _, _, _, noRedirects in
            calls += 1; noRedirectFlags.append(noRedirects)
            expect(url == "https://auth.openai.com/oauth/token" && method == "POST", "C4-07 \(policy): official OAuth endpoint")
            return c4Reply(200, ["access_token": newAccess, "refresh_token": "replacement-refresh"])
        })
        let token = codexAccessToken(io: io)
        let bytes = FileManager.default.contents(atPath: path), parsed = c4Object(bytes)
        let tokens = parsed["tokens"] as? [String: Any] ?? [:]
        expect(calls == 1 && noRedirectFlags == [true] && token.credential?.token == newAccess, "C4-07 \(policy): explicit refresh once")
        expect(tokens["access_token"] as? String == newAccess && tokens["refresh_token"] as? String == "replacement-refresh", "C4-07 \(policy): replacement persisted")
        expect((parsed["untouched"] as? [String: String])?["keep"] == "CLI-owned", "C4-07 \(policy): unrelated CLI fields retained")
        expect(C4FileStamp(path).inode != before.inode, "C4-07 \(policy): atomic rename replaces inode")
        // A concurrent CLI rotation between POST and write must win, byte-for-byte.
        c4Auth(path, access: oldAccess)
        var cliStamp: C4FileStamp?
        let racing = CodexCredentialIO(authPath: path, now: { C4_NOW }, policy: { policy }, http: { _, _, _, _, _, _ in
            c4Auth(path, access: "CLI-new-access", refresh: "CLI-new-refresh")
            cliStamp = C4FileStamp(path)
            return c4Reply(200, ["access_token": newAccess, "refresh_token": "our-late-refresh"])
        })
        let superseded = codexAccessToken(io: racing)
        expect(superseded.credential == nil && superseded.failure?.error?.contains("superseded") == true,
               "C4-07 \(policy): CLI pair change yields superseded")
        expect(cliStamp != nil && C4FileStamp(path) == cliStamp!, "C4-07 \(policy): CLI file exactly preserved")
        // The second policy guard must run inside the writer, after the issuer returned.
        c4Auth(path, access: oldAccess)
        let beforeSwitch = C4FileStamp(path)
        var activePolicy = policy
        let switching = CodexCredentialIO(authPath: path, now: { C4_NOW }, policy: { activePolicy }, http: { _, _, _, _, _, _ in
            activePolicy = "never"; return c4Reply(200, ["access_token": newAccess, "refresh_token": "late-refresh"])
        })
        let switched = codexAccessToken(io: switching)
        expect(switched.credential == nil && C4FileStamp(path) == beforeSwitch, "C4-07 \(policy)→never: inner guard preserves auth")
    }
    defaults.set("never", forKey: "credentialWrite"); defaults.set(true, forKey: "monitor_claude")
    var helperWrites = 0, posts = 0
    let credential = String(decoding: c4JSON(["claudeAiOauth": ["accessToken": "fixture-expired-access", "refreshToken": "fixture-refresh",
        "expiresAt": Int((C4_NOW.timeIntervalSince1970 - 86400) * 1000)]]), as: UTF8.self)
    let claudeIO = ClaudeQuotaIO(keychain: { operation, _ in
        if operation == "update" { helperWrites += 1 }
        return (.success, credential)
    }, permissionRead: { _ in (.failure(37), "") }, http: { _, method, _, _, _, _ in
        if method == "POST" { posts += 1 }; return c4Reply(599)
    }, now: { C4_NOW })
    _ = fetchClaude(io: claudeIO)
    expect(helperWrites == 0 && posts == 0, "C4-07 never: Claude persist/helper and OAuth are not called")
    defaults.removeObject(forKey: "credentialWrite"); defaults.set(false, forKey: "monitor_claude")
}

private func c4C408(_ root: String, _ expect: C4Expect) {
    for age in [120.0, 121] {
        let h = C4Harness(root + "/c408-\(Int(age))")
        let outcome = h.sync.syncSynchronously(mode: .full, deferWrite: true)
        if case .failed = outcome { expect(false, "C4-08 validating GET succeeds") }
        expect(h.patches.isEmpty, "C4-08 deferred full cycle reads without pre-decision PATCH")
        h.now = h.now.addingTimeInterval(age)
        let write = h.sync.syncSynchronously(mode: .writeOnly)
        if age > 120 {
            if case .failed = write { expect(true, "C4-08 stale session failed") } else { expect(false, "C4-08 stale session failed") }
            expect(h.patches.isEmpty && h.ledger.count("GET") == 1, "C4-08 >120s refuses PATCH without hidden GET")
        } else {
            expect(h.patches.count == 1 && h.ledger.count("GET") == 1, "C4-08 exactly120s reuses one GET")
        }
        expect(h.providerCalls == 0, "C4-08 session check never contacts provider")
    }
    let noRead = C4Harness(root + "/c408-no-read")
    _ = noRead.sync.syncSynchronously(mode: .writeOnly)
    expect(noRead.http.calls.isEmpty, "C4-08 no validating GET: zero HTTP")
    for mutation in ["gist", "clock-backwards", "credential-pair"] {
        let h = C4Harness(root + "/c408-" + mutation)
        _ = h.sync.syncSynchronously(mode: .full, deferWrite: true)
        if mutation == "gist" { h.defaults.set("other-fixture-gist", forKey: "syncGistId") }
        else if mutation == "credential-pair" { h.keychain.token = "replacement-fixture-token" }
        else { h.now = C4_NOW.addingTimeInterval(-1) }
        let outcome = h.sync.syncSynchronously(mode: .writeOnly)
        if case .failed = outcome { expect(true, "C4-08 \(mutation): session invalidated") }
        else { expect(false, "C4-08 \(mutation): session invalidated") }
        expect(h.patches.isEmpty && h.ledger.count("GET") == 1, "C4-08 \(mutation): no PATCH/hidden discovery")
    }

}

private func c4C409(_ root: String, _ expect: C4Expect) {
    guard let dir = remoteLimitsFixturesDir(), let bytes = FileManager.default.contents(atPath: dir + "/pii-sentinels.json"),
          let sentinels = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else {
        expect(false, "C4-09 PII sentinels readable"); return
    }
    let h = C4Harness(root + "/c409")
    h.tick()
    // Deliberately supply PII at the builder boundary; merely loading the list is not a scan.
    var hostile = c4Fresh()
    let email = sentinels["email"] as? String ?? "fixture@example.invalid"
    let fullName = sentinels["fullName"] as? String ?? "Fixture Name"
    let host = sentinels["hostname"] as? String ?? "fixture.example.invalid"
    let privateName = sentinels["users"] as? String ?? "/Users/fixture"
    let fullwidth = "fixture＠example.invalid"
    var hostileFiles: [[String: Any]] = []
    for text in [email, privateName, fullwidth, "fixture\\private"] {
        hostile.plan = text; hostile.scoped = ScopedLimit(name: text, percent: 12, reset: C4_NOW, severity: nil)
        hostileFiles.append(c4MachineFile(days: h.days, accountByDay: ["codex": ["2026-10-12": C4_ID]], localId: C4_ID,
            codex: hostile, poll: h.saved.poll, gistId: C4_GIST, machineId: C4_MACHINE,
            machineName: machineTag(setting: fullName, hostname: host), osName: "fixture", now: C4_NOW))
    }
    hostile.plan = fullName
    hostileFiles.append(c4MachineFile(days: h.days, accountByDay: [:], localId: email, codex: hostile, poll: h.saved.poll,
        gistId: C4_GIST, machineId: C4_MACHINE, machineName: "macbook", osName: "fixture", now: C4_NOW))
    let hostilePayload = hostileFiles.map { String(decoding: c4JSON($0), as: UTF8.self) }.joined(separator: "\n")
    expect(![email, fullName, host, privateName, fullwidth, "fixture\\private", C4_ID].contains(where: { hostilePayload.contains($0) }),
           "C4-09 hostile PII name/identity/plan/model strings stripped by production builder")

    let payload = h.patches.map { String(decoding: c4JSON($0), as: UTF8.self) }.joined(separator: "\n")
        + ((try? String(contentsOfFile: h.root + "/poll-log.jsonl", encoding: .utf8)) ?? "")
    var banned = sentinels.values.compactMap { $0 as? String }
    for parts in (sentinels["token_parts"] as? [String: [String]])?.values ?? Dictionary<String, [String]>().values { banned.append(parts.joined()) }
    banned += [C4_ID, "access_token", "refresh_token", "account_id", "accountUuid", "localId", "@", "/home/", "/Users/"]
    expect(!banned.contains(where: { !$0.isEmpty && payload.contains($0) }), "C4-09 real outgoing payload + O1 log contain no identities/PII/token/path")
    let attrs = (try? FileManager.default.attributesOfItem(atPath: h.root + "/poll-log.jsonl")) ?? [:]
    expect((((attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1) & 0o777) == 0o600, "C4-09 journal permissions0600")
    let events = (try? String(contentsOfFile: h.root + "/poll-log.jsonl", encoding: .utf8))?.split(separator: "\n").map { c4Object(Data($0.utf8)) } ?? []
    for name in ["poll_attempt", "poll_result", "publish"] {
        expect(events.contains { $0["ev"] as? String == name }, "C4-09 O1 event \(name)")
    }
    expect(events.allSatisfy { $0["ts"] is NSNumber && $0["ev"] is String }, "C4-09 O1 ts/ev envelope")
    expect(events.filter { $0["ev"] as? String == "publish" }.count == h.patches.count,
           "C4-09 each actual PATCH produces exactly one O1 publish event")
    let failure = C4Harness(root + "/c409-failure"); failure.failPatch = true; failure.tick()
    expect(failure.skipped("publish_failed") && failure.journalEvents.contains { $0["ev"] as? String == "publish" && $0["result"] as? String == "failed" },
           "C4-09 O1 failed publication vocabulary matches Linux")
    let readFailure = C4Harness(root + "/c409-read-failure"); readFailure.failRead = true; readFailure.tick()
    expect(readFailure.patches.isEmpty && readFailure.journalEvents.filter { $0["ev"] as? String == "publish" }.isEmpty,
           "C4-09 failed GET produces no fictitious PATCH publication event")
    expect(readFailure.skipped("publish_failed"), "C4-09 failed GET retains publish_failed skip reason")
}

private func c4C410(_ root: String, _ expect: @escaping C4Expect) {
    for endpoint in ["usage", "oauth"] {
        let path = root + "/c410-" + endpoint + "/auth.json"
        c4Auth(path, access: c4JWT(expiry: C4_NOW.timeIntervalSince1970 + (endpoint == "usage" ? 3600 : -1)))
        let before = C4FileStamp(path), ledger = C4Ledger()
        let io = CodexCredentialIO(authPath: path, now: { C4_NOW }, policy: { "legacy" }, http: { url, method, _, _, _, noRedirects in
            ledger.add(method + " " + url)
            if !noRedirects { ledger.add("REDIRECT https://foreign.fixture.invalid") }
            expect(noRedirects, "C4-10 \(endpoint): noRedirects true")
            return (302, nil, nil, ["Location": "https://foreign.fixture.invalid/steal"])
        })
        let result: LimitData? = endpoint == "usage" ? codexUsageLive(io: io) : codexAccessToken(io: io).failure
        expect(result?.failureKind == "http" && result?.httpStatus == 302, "C4-10 \(endpoint): error/http classification")
        expect(result?.error?.contains("302") == true && result?.apiFresh == false, "C4-10 \(endpoint): attempt records HTTP error")
        expect(ledger.entries.count == 1 && !ledger.names.contains(where: { $0.contains("foreign.fixture.invalid") }), "C4-10 \(endpoint): foreign host never called")
        expect(C4FileStamp(path) == before, "C4-10 \(endpoint): redirect cannot mutate credentials")
    }
}

private func c4C411(_ root: String, _ expect: C4Expect) {
    for skew in [-121.0, -120, 0, 120, 121] {
        let d = MemorySelfTestDefaults(); c4Prefs(d)
        let keychain = SelfTestKeychainStore("fixture-token")
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let header = formatter.string(from: C4_NOW.addingTimeInterval(skew))
        let http = SelfTestHTTP { _ in c4Reply(200, c4Gist(), headers: ["dAtE": header]) }
        let sync = GitHubSync(transport: http.transport, keychain: ScriptedSyncKeychain(store: keychain), defaults: d,
            remotePath: root + "/c411-\(Int(skew)).json", machineId: C4_MACHINE, revokeRecheckDelay: 0, clock: { C4_NOW },
            publisherSnapshot: { C4PublisherSnapshot(days: [:], accountByDay: [:], localId: nil, codex: LimitData(present: false), poll: AutoPollState(), attemptKind: "auto") },
            pollLogPath: root + "/c411-\(Int(skew)).jsonl")
        _ = sync.syncSynchronously(mode: .readOnly)
        expect(sync.ui.clockSkew == skew && sync.ui.clockSkewAt == C4_NOW, "C4-11 \(Int(skew)): signed GitHub-minus-local skew injected")
        expect(d.double(forKey: "clockSkew") == skew && d.object(forKey: "clockSkewAt") as? Date == C4_NOW, "C4-11 \(Int(skew)): skew durable")
        for language in ["ru", "en"] {
            let warning = sync.ui.clockSkewWarning(language: language)
            expect((warning != nil) == (abs(skew) > 120), "C4-11 \(Int(skew))/\(language): warning threshold >120")
            if abs(skew) > 120 { expect(warning?.lowercased().contains(language == "ru" ? "часы" : "clock") == true, "C4-11 localized clock warning") }
        }
        expect(http.calls.count == 1 && keychain.writes == 0 && keychain.deletes == 0, "C4-11 skew observation has no write side effects")
        let errorDefaults = MemorySelfTestDefaults(); c4Prefs(errorDefaults)
        let errorHTTP = SelfTestHTTP { _ in c4Reply(503, headers: ["Date": header]) }
        let errorSync = GitHubSync(transport: errorHTTP.transport, keychain: ScriptedSyncKeychain(store: SelfTestKeychainStore("fixture-token")),
            defaults: errorDefaults, remotePath: root + "/c411-error-\(Int(skew)).json", machineId: C4_MACHINE, revokeRecheckDelay: 0,
            clock: { C4_NOW }, pollLogPath: root + "/c411-error-\(Int(skew)).jsonl")
        _ = errorSync.syncSynchronously(mode: .readOnly)
        expect(errorSync.ui.clockSkew == skew, "C4-11 \(Int(skew)): first error response Date sampled too")
    }
}

// C4-01/08 extra boundaries: three independent fingerprints; GET is never skipped.
private func c4Fingerprints(_ root: String, _ expect: C4Expect) {
    let usage = C4Harness(root + "/c4-fingerprints-usage")
    _ = usage.sync.syncSynchronously()
    usage.usageInput = 2; usage.now = C4_NOW.addingTimeInterval(569); _ = usage.sync.syncSynchronously()
    expect(usage.patches.count == 1 && usage.ledger.count("GET") == 2, "C4-01 pushHash change waits569s, still reads")
    usage.now = C4_NOW.addingTimeInterval(570); _ = usage.sync.syncSynchronously()
    expect(usage.patches.count == 2 && usage.ledger.count("GET") == 3, "C4-01 pushHash floor570s")
    let meta = C4Harness(root + "/c4-fingerprints-meta"); _ = meta.sync.syncSynchronously()
    meta.saved.poll.lastAttempt = C4_NOW.timeIntervalSince1970; meta.now = C4_NOW.addingTimeInterval(1)
    _ = meta.sync.syncSynchronously()
    expect(meta.patches.count == 2, "C4-01 attempt metadata bypasses usage floor")
    let heartbeat = C4Harness(root + "/c4-fingerprints-heartbeat"); _ = heartbeat.sync.syncSynchronously()
    heartbeat.now = C4_NOW.addingTimeInterval(599); _ = heartbeat.sync.syncSynchronously()
    expect(heartbeat.patches.count == 1 && heartbeat.ledger.count("GET") == 2, "C4-01 unchanged heartbeat599s gives no PATCH, still GET")
    heartbeat.now = C4_NOW.addingTimeInterval(600); _ = heartbeat.sync.syncSynchronously()
    expect(heartbeat.patches.count == 2 && heartbeat.ledger.count("GET") == 3, "C4-01 heartbeat due600s")
    if heartbeat.patches.count == 2 {
        expect(c4Canon(heartbeat.patches[0]["accounts"]) == c4Canon(heartbeat.patches[1]["accounts"]), "C4-01 heartbeat does not advance asOf/attempt/schedule")
    }
}

func runRemoteLimitsC4SelfTests(defaults: MemorySelfTestDefaults, root: String) -> Int {
    var failures = 0, checks = 0
    func expect(_ ok: Bool, _ text: String) { checks += 1; if !ok { failures += 1 }; print("\(ok ? "OK" : "FAIL") \(text)") }
    let testRoot = root + "/c4"
    do { try FileManager.default.createDirectory(atPath: testRoot, withIntermediateDirectories: true) } catch {
        expect(false, "C4 temporary fixture directory created"); return failures
    }
    c4C401(testRoot, expect); c4C402(testRoot, expect); c4C403(testRoot, expect); c4ReadFailures(testRoot, expect); c4IdentityChanges(testRoot, expect); c4C404(expect)
    c4C405(testRoot, expect); c4C406(testRoot, expect); c4C407(testRoot, defaults, expect)
    c4C408(testRoot, expect); c4C409(testRoot, expect); c4C410(testRoot, expect); c4C411(testRoot, expect)
    c4Fingerprints(testRoot, expect); c4PersistedRetry(testRoot, expect); c4ExhaustedPublicationBudget(testRoot, expect)
    c4NonDueTie(testRoot, expect); c4IntervalParsing(expect); c4CoordinationHeartbeat(testRoot, expect)
    c4NoLabelFallback(testRoot, expect); c4CoordinationSchedule(expect); c4ManualPhaseExpiry(expect)
    print(failures == 0 ? "OK C4 remote-limits: all \(checks) checks passed" : "FAIL C4 remote-limits: \(failures) of \(checks) checks failed")
    return failures
}

private func c4ReadFailures(_ root: String, _ expect: C4Expect) {
    for kind in ["off", "missing-token", "404", "public", "missing-files", "malformed", "503", "timeout"] {
        let defaults = MemorySelfTestDefaults(); c4Prefs(defaults)
        if kind == "off" { defaults.clear() }
        let store = SelfTestKeychainStore(kind == "missing-token" ? nil : "fixture-token")
        let http = SelfTestHTTP { _ in
            switch kind {
            case "404": return c4Reply(404)
            case "public": return c4Reply(200, ["public": true, "files": [:]])
            case "missing-files": return c4Reply(200, ["public": false])
            case "malformed": return (200, Data("{".utf8), nil, [:])
            case "timeout": return (0, nil, "fixture timeout", [:])
            default: return c4Reply(503)
            }
        }
        let path = root + "/c403-returns-" + kind + ".json"
        c4Write(["fixture": "unchanged"], path)
        let before = C4FileStamp(path)
        let sync = GitHubSync(transport: http.transport, keychain: ScriptedSyncKeychain(store: store), defaults: defaults,
            remotePath: path, machineId: C4_MACHINE, revokeRecheckDelay: 0, clock: { C4_NOW })
        let result = sync.syncSynchronously(mode: .readOnly)
        if case .failed = result { expect(true, "C4-03 \(kind): early return explicitly failed") }
        else { expect(false, "C4-03 \(kind): early return explicitly failed") }
        expect(http.calls.allSatisfy { $0.url.hasPrefix(C4_API + "/") && $0.method == "GET" }, "C4-03 \(kind): no provider/PATCH transport")
        expect(C4FileStamp(path) == before && store.writes == 0 && store.deletes == 0, "C4-03 \(kind): cache stat+sha and credentials unchanged")
    }
    let read = C4Harness(root + "/c403-read-series"); read.failRead = true
    for i in 1...3 {
        read.tick()
        expect(read.providerCalls == (i == 3 ? 1 : 0), "C4-03 failed GET series tick\(i): bounded B1 fallback")
        read.now = read.now.addingTimeInterval(600)
    }
}

private func c4IdentityChanges(_ root: String, _ expect: C4Expect) {
    for phase in ["before-provider", "after-provider"] {
        let h = C4Harness(root + "/c4-identity-" + phase)
        let replacement = "cccccccc-1111-4222-8333-444455556666"
        if phase == "before-provider" { h.mutateAtPatch = { h.localId = replacement } }
        else { h.mutateAtProvider = { h.localId = replacement } }
        let auth = h.authStamp, cache = h.cacheStamp
        h.tick()
        expect(h.providerCalls == (phase == "before-provider" ? 0 : 1), "C4-02 identity \(phase): request fenced")
        expect(h.applied == 0 && h.authStamp == auth && h.cacheStamp == cache, "C4-02 identity \(phase): A cannot apply to B")
        expect(h.events.contains { $0["ev"] as? String == "identity_changed" }, "C4-02 identity \(phase): O1 identity_changed")
    }
}

// T31: actual durable store, repeated hostile deadline, three process restarts and cap marker.
private func c4PersistedRetry(_ root: String, _ expect: C4Expect) {
    let path = root + "/c4-persisted-publisher.json"
    var state = C4TickState(poll: AutoPollState())
    state.poll.interval = 900; state.poll.lastAttempt = C4_NOW.timeIntervalSince1970 - 10000
    let first = C4_NOW.timeIntervalSince1970
    for (index, elapsed) in [0.0, 43200, 86399, 86400].enumerated() {
        let store = C4PublisherStore(path: path) // fresh object = process-local caches are absent
        if index > 0 { state = store.state(C4_ID) }
        let now = first + elapsed
        let mine: [String: Any] = ["interval": state.poll.interval, "last_attempt": state.poll.lastAttempt,
            "server_until": state.poll.serverRetryAt as Any? ?? NSNull(), "remote_retry": state.remoteRetry as Any? ?? NSNull()]
        let decision = coordinationDecide(now: now, mine: mine,
            remote: [["machineId": C4_VPS, "status": "rate_limited", "lastSeenAt": now,
                      "attemptAt": now - 10000, "retryUntil": now + 10 * 365 * 86400]], myId: C4_MACHINE, tieWait: nil)
        state.remoteRetry = decision["remote_retry"] as? [String: Double]
        expect(state.remoteRetry?["firstSeenAt"] == first, "C4-05 restart\(index): heartbeat/replay never moves firstSeenAt")
        expect(state.poll.serverRetryAt == nil, "C4-05 restart\(index): remote deadline cannot become own")
        expect(decision["action"] as? String == (elapsed < 86400 ? "skip" : "poll"), "C4-05 restart\(index): 24h cap from original observation")
        expect(store.save(state, id: C4_ID), "C4-05 restart\(index): state durable")
    }
    let restored = C4PublisherStore(path: path).state(C4_ID)
    expect(restored.remoteRetry?["until"] == first + 86400, "C4-05 consumed cap marker survives restart")
    let otherId = "cccccccc-1111-4222-8333-444455556666"
    var other = C4TickState(poll: AutoPollState()); other.poll.serverRetryAt = first + 48 * 3600
    let store = C4PublisherStore(path: path)
    expect(store.save(other, id: otherId), "C4-05 account B state saved")
    let afterSwitch = C4PublisherStore(path: path)
    expect(afterSwitch.state(C4_ID).remoteRetry?["firstSeenAt"] == first && afterSwitch.state(otherId).poll.serverRetryAt == first + 48 * 3600,
           "C4-05 A→B→A: foreign cap and own48h retry remain bound to respective local identities")
    let bytes = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    let labelA = accountLabel(product: "codex", localId: C4_ID, gistId: C4_GIST) ?? "missing-label"
    let labelB = accountLabel(product: "codex", localId: otherId, gistId: C4_GIST) ?? "missing-label"
    expect(!bytes.isEmpty && !bytes.contains(labelA) && !bytes.contains(labelB), "C4-05 persistent state stores local identities, never gist labels")
}

private func c4ExhaustedPublicationBudget(_ root: String, _ expect: C4Expect) {
    for (previousFailures, elapsed) in [(3, 10000.0), (1, 86400.0)] {
        let label = "failures\(previousFailures)-age\(Int(elapsed))"
        let h = C4Harness(root + "/c403-exhausted-budget-" + label)
        h.saved.publishFailures = previousFailures; h.saved.poll.lastAttempt = C4_NOW.timeIntervalSince1970 - elapsed
        h.dropRead = true
        h.tick()
        expect(h.providerCalls == 1, "C4-03 \(label): exhausted publication budget polls before any new blocking GET")
        let provider = h.ledger.names.firstIndex(of: "fetchCodex") ?? Int.max
        let read = h.ledger.names.firstIndex(of: "READ_NO_COMPLETION") ?? -1
        expect(provider < read, "C4-03 \(label): provider precedes read without completion")
        h.timers.forEach { $0() }
        expect(h.providerCalls == 1 && h.completionCalls == 1, "C4-03 \(label): read timeout after B1 fallback cannot duplicate provider")
    }
}

private func c4NonDueTie(_ root: String, _ expect: C4Expect) {
    let h = C4Harness(root + "/c404-nondue-tie")
    h.peerId = "a-c4-peer"; h.saved.poll.lastAttempt = C4_NOW.timeIntervalSince1970 - 899
    var account = h.remote.accounts![0]
    account.schedule = RemoteSchedule(mode: "auto", interval: 900, nextAt: C4_NOW.addingTimeInterval(1))
    h.remote.accounts = [account]
    h.tick()
    expect(h.providerCalls == 0 && h.controller.state.tieMachine == nil && h.controller.state.tieNextAt == nil,
           "C4-04 non-due read cannot consume future tie-break")
    h.now = C4_NOW.addingTimeInterval(1); h.tick()
    expect(h.providerCalls == 0 && h.controller.state.tieMachine == h.peerId,
           "C4-04 same tie winner waits once at actual due time")
    h.now = C4_NOW.addingTimeInterval(601); h.tick()
    expect(h.providerCalls == 1, "C4-04 remembered same tie pair polls on following due tick")
}

private func c4IntervalParsing(_ expect: C4Expect) {
    for (value, expected) in [("900", "poll"), ("900.0", "skip"), ("9e2", "skip"), (" 900 ", "poll")] {
        let now = C4_NOW.timeIntervalSince1970
        let result = coordinationDecide(now: now, mine: ["interval": value, "last_attempt": now - 10000],
            remote: [["machineId": C4_VPS, "status": "ok", "lastSeenAt": now, "asOf": now - 1000]], myId: C4_MACHINE, tieWait: nil)
        expect(result["action"] as? String == expected, "C4-04 interval string \(value): Python int normalization parity")
    }
}

// Display's updated fallback must never be reused by the B2 adapter.
private func c4CoordinationHeartbeat(_ root: String, _ expect: C4Expect) {
    for mode in ["missing", "future61", "old1801", "future60"] {
        let h = C4Harness(root + "/c405-heartbeat-" + mode)
        h.remote = c4Remote(retry: C4_NOW.addingTimeInterval(3600), status: "rate_limited")
        if mode == "missing" { h.omitHeartbeat = true }
        if mode == "future61" { h.remoteHeartbeat = C4_NOW.addingTimeInterval(61) }
        if mode == "old1801" { h.remoteHeartbeat = C4_NOW.addingTimeInterval(-1801) }
        if mode == "future60" { h.remoteHeartbeat = C4_NOW.addingTimeInterval(60) }
        h.tick()
        expect(h.providerCalls == (mode == "future60" ? 0 : 1), "C4-05 raw heartbeat \(mode): display updated fallback cannot suppress B2")
        expect((h.controller.remoteRetry != nil) == (mode == "future60"), "C4-05 raw heartbeat \(mode): foreign retry admission obeys raw liveness")
        expect(h.controller.state.poll.serverRetryAt == nil, "C4-05 raw heartbeat \(mode): local Retry-After remains local")
    }
}

// A bounded outage fallback needs a previously known gist and a valid local label.
private func c4NoLabelFallback(_ root: String, _ expect: C4Expect) {
    let h = C4Harness(root + "/c403-no-label-fallback")
    h.failRead = true; h.canPollWithoutRead = false
    let auth = h.authStamp, cache = h.cacheStamp, lastAttempt = h.saved.poll.lastAttempt
    for tick in 1...3 {
        h.tick()
        expect(h.providerCalls == 0 && !h.ledger.names.contains("fetchCodex"),
               "C4-03 no cached gist/label tick\(tick): publication failure budget cannot authorize provider")
        expect(h.controller.state.poll.lastAttempt == lastAttempt && h.authStamp == auth && h.cacheStamp == cache,
               "C4-03 no cached gist/label tick\(tick): attempt and files unchanged")
        h.now = h.now.addingTimeInterval(600)
    }
    expect(h.skipped("no_label") || h.skipped("no_github"), "C4-03 no cached gist/label: explicit no_label/no_github skip")
    expect(h.patches.isEmpty && h.journalEvents.filter { $0["ev"] as? String == "publish" }.isEmpty,
           "C4-03 no cached gist/label: zero PATCH/publication events")
}

// A remembered provider deadline may extend, but never replace, the next B2 read tick.
private func c4CoordinationSchedule(_ expect: C4Expect) {
    let now = C4_NOW.timeIntervalSince1970, schedule = C4_NOW.timeIntervalSince1970 + 600
    for (deadline, expected) in [(now - 1, schedule), (now + 100, schedule), (now + 3600, now + 3600)] {
        let state = QuotaRefreshState(lastAttempt: now - 100, serverUntil: deadline)
        expect(state.nextAttempt(schedule: schedule) == expected,
               "C4-05 schedule keeps max(local wait, B2 tick, server retry) for deadline offset\(Int(deadline - now))")
    }
}

private func c4ManualPhaseExpiry(_ expect: C4Expect) {
    for (elapsed, remaining) in [(0.0, 30), (1.0, 29)] {
        let phase = c4ManualPhase(.cooldown(30), startedAt: C4_NOW, now: C4_NOW.addingTimeInterval(elapsed))
        if case .cooldown(let seconds)? = phase {
            expect(seconds == remaining, "C4-06 cooldown age\(Int(elapsed)): remaining\(remaining) from injected start")
        } else { expect(false, "C4-06 cooldown remains active before30s") }
    }
    if case nil = c4ManualPhase(.cooldown(30), startedAt: C4_NOW, now: C4_NOW.addingTimeInterval(30)) {
        expect(true, "C4-06 cooldown expires at30s")
    } else { expect(false, "C4-06 cooldown expires at30s") }
    if case .checked(let at)? = c4ManualPhase(.checked(C4_NOW), startedAt: nil, now: C4_NOW.addingTimeInterval(59)) {
        expect(at == C4_NOW, "C4-06 checked still visible at59s from its result time")
    } else { expect(false, "C4-06 checked still visible at59s") }
    if case nil = c4ManualPhase(.checked(C4_NOW), startedAt: nil, now: C4_NOW.addingTimeInterval(60)) {
        expect(true, "C4-06 checked expires at60s")
    } else { expect(false, "C4-06 checked expires at60s") }
    let allowed = C4_NOW.addingTimeInterval(600)
    if case .pollAllowed(let at)? = c4ManualPhase(.pollAllowed(allowed), startedAt: nil, now: C4_NOW) {
        expect(at == allowed, "C4-06 future pollAllowed deadline retained")
    } else { expect(false, "C4-06 future pollAllowed retained") }
    if case nil = c4ManualPhase(.pollAllowed(allowed), startedAt: nil, now: allowed) {
        expect(true, "C4-06 pollAllowed clears exactly at deadline")
    } else { expect(false, "C4-06 pollAllowed clears exactly at deadline") }
    if case .reading? = c4ManualPhase(.reading, startedAt: C4_NOW, now: C4_NOW.addingTimeInterval(100)) {
        expect(true, "C4-06 reading phase remains controller-owned")
    } else { expect(false, "C4-06 reading phase remains controller-owned") }
    if case .failed? = c4ManualPhase(.failed, startedAt: nil, now: C4_NOW) {
        expect(true, "C4-06 failed phase preserved")
    } else { expect(false, "C4-06 failed phase preserved") }
    if case .idle? = c4ManualPhase(.idle, startedAt: nil, now: C4_NOW) {
        expect(true, "C4-06 idle phase preserved")
    } else { expect(false, "C4-06 idle phase preserved") }
}
