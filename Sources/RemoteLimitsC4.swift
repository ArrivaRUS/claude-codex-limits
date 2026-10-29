import Foundation
import CoreFoundation
import CryptoKit
import Darwin

// B2 mirrors linux/ccl/coordination.py. No clocks, preferences or I/O are hidden here.
private let c4Steps: [Double] = [900, 1800, 3600, 14400]
func c4Number(_ value: Any?) -> Double? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.isFinite else { return nil }
    return number.doubleValue
}
private func c4Interval(_ value: Any?) -> Double {
    let number: Double?
    if let text = value as? String { number = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)).map(Double.init) }
    else { number = c4Number(value) }
    return number.flatMap { c4Steps.contains($0) ? $0 : nil } ?? 1800
}
private func c4MachineID(_ value: String) -> Bool {
    (1...64).contains(value.utf8.count) && value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
}
func coordinationRecords(now: Double, remote: [[String: Any]], myId: String) -> [[String: Any]] {
    remote.compactMap { record in
        guard let machine = record["machineId"] as? String, !machine.isEmpty, machine != myId,
              let seen = c4Number(record["lastSeenAt"]), seen >= now - 1800, seen <= now + 60 else { return nil }
        let asOf = c4Number(record["asOf"]), attempt = c4Number(record["attemptAt"]), next = c4Number(record["nextAt"])
        let proposed = c4Number(record["interval"])
        let interval = proposed.flatMap { c4Steps.contains($0) ? $0 : nil } ?? 14400
        if let value = asOf, value > now + 60 { return nil }
        if let value = attempt, value > now + 60 { return nil }
        if let value = asOf, let attempt = attempt, value > attempt + 60 { return nil }
        if let value = next, value > now + interval + 60 { return nil }
        var result: [String: Any] = ["machineId": machine, "lastSeenAt": seen]
        result["status"] = record["status"]
        result["asOf"] = asOf; result["attemptAt"] = attempt; result["nextAt"] = next
        result["retryUntil"] = c4Number(record["retryUntil"])
        return result
    }
}
private func c4RemoteRetry(now: Double, saved: Any?, records: [[String: Any]], lastAttempt: Double?) -> ([String: Double]?, [String]) {
    var retry: [String: Double]?
    if let saved = saved as? [String: Any], let until = c4Number(saved["until"]),
       let first = c4Number(saved["firstSeenAt"]), first <= now {
        retry = ["until": until, "firstSeenAt": first]
    }
    if let r = retry, now - min(r["until"]!, r["firstSeenAt"]! + 86400) > 900 { retry = nil }
    if var r = retry {
        let cap = r["firstSeenAt"]! + 86400, until = r["until"]!
        if until >= cap {
            if until == cap, let last = lastAttempt, last >= cap { retry = nil }
            else {
                if now >= cap && until > cap { r["until"] = cap; return (r, ["remote_retry_capped"]) }
                return (r, [])
            }
        } else if now < until { return (r, []) }
    }
    let deadlines = records.compactMap { c4Number($0["retryUntil"]) }.filter { $0 > now }
    if let until = deadlines.max() {
        var first = now
        if let r = retry, lastAttempt == nil || lastAttempt! < r["until"]! { first = r["firstSeenAt"]! }
        retry = ["until": until, "firstSeenAt": first]
        if now >= first + 86400 { retry?["until"] = first + 86400; return (retry, ["remote_retry_capped"]) }
    }
    return (retry, [])
}
func coordinationDecide(now suppliedNow: Double, mine: [String: Any], remote: [[String: Any]], myId: String,
                        tieWait: [Any]? = nil) -> [String: Any] {
    let now = suppliedNow.isFinite ? suppliedNow : 0, interval = c4Interval(mine["interval"])
    let records = coordinationRecords(now: now, remote: remote, myId: myId)
    let last = c4Number(mine["last_attempt"])
    let (retry, events) = c4RemoteRetry(now: now, saved: mine["remote_retry"], records: records, lastAttempt: last)
    var remembered: [Any]?
    if let pair = tieWait, pair.count == 2, let id = pair[0] as? String, c4MachineID(id), let time = c4Number(pair[1]) {
        remembered = [id, time]
    }
    func result(_ reason: String?, _ tie: [Any]?) -> [String: Any] {
        ["action": reason == nil ? "poll" : "skip", "reason": reason as Any? ?? NSNull(),
         "tie_wait": tie as Any? ?? NSNull(), "remote_retry": retry as Any? ?? NSNull(), "events": events]
    }
    let server = c4Number(mine["server_until"])
    let remoteUntil = retry.map { min($0["until"]!, $0["firstSeenAt"]! + 86400) }
    if server.map({ now < $0 }) == true || remoteUntil.map({ now < $0 }) == true { return result("retry_after", remembered) }
    if records.contains(where: { c4Number($0["attemptAt"]).map { now - $0 < 960 } == true }) { return result("remote_attempt", remembered) }
    let manual = (mine["manual"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } ?? false
    if !manual {
        if records.contains(where: { ($0["status"] as? String) == "ok" && c4Number($0["asOf"]).map { now - $0 < interval + 60 } == true }) {
            return result("fresh_remote", remembered)
        }
        if let last = last {
            let candidates: [(String, Double)] = records.compactMap { record in
                guard let id = record["machineId"] as? String, c4MachineID(id), id < myId,
                      let next = c4Number(record["nextAt"]), abs(next - (last + interval)) <= 60,
                      let seen = c4Number(record["lastSeenAt"]), seen >= now - 900 else { return nil }
                return (id, next)
            }
            if let winner = candidates.sorted(by: { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }).first {
                if remembered == nil || remembered![0] as? String != winner.0 || c4Number(remembered![1]) != winner.1 {
                    return result("tie_break", [winner.0, winner.1])
                }
            }
        }
    }
    return result(nil, nil)
}

func c4CoordinationRemote(_ cache: SyncRemoteCache, localId: String) -> [[String: Any]] {
    let key = cache.labelKey ?? cache.gistId.flatMap { accountLabelKey(gistId: $0) }
    guard let key = key, let label = accountLabel(product: "codex", localId: localId, labelKey: key) else { return [] }
    return (cache.accounts ?? []).filter { $0.product == "codex" && $0.label == label }.map { account in
        var r: [String: Any] = ["machineId": account.machineId, "status": account.status]
        r["lastSeenAt"] = cache.machines.first(where: { $0.id == account.machineId })?.lastSeenAt?.timeIntervalSince1970
        r["asOf"] = account.asOf?.timeIntervalSince1970; r["attemptAt"] = account.attemptAt?.timeIntervalSince1970
        r["retryUntil"] = account.retryUntil?.timeIntervalSince1970; r["nextAt"] = account.schedule?.nextAt?.timeIntervalSince1970
        r["interval"] = account.schedule?.interval
        return r
    }
}

struct C4PublisherSnapshot {
    var days: [String: Any]
    var accountByDay: [String: [String: String]]
    var localId: String?
    var codex: LimitData
    var poll: AutoPollState
    var attemptKind: String = "auto"
    var automatic: Bool = true
}
private func c4Text(_ text: String?, limit: Int) -> String? {
    guard let text = text else { return nil }
    let normalized = text.precomposedStringWithCompatibilityMapping
    guard !normalized.contains(where: { "@/\\".contains($0) }) else { return nil }
    let scalars = normalized.unicodeScalars.filter { ![Unicode.GeneralCategory.control, .format, .surrogate].contains($0.properties.generalCategory) }
    let result = String(String.UnicodeScalarView(scalars)).precomposedStringWithCanonicalMapping
    return String(result.prefix(limit))
}
private func c4ISOTime(_ value: Double?) -> String? {
    guard let value = value, value.isFinite, value >= 0, value < 253402300800 else { return nil }
    return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: value))
}
func c4MachineFile(days: [String: Any], accountByDay: [String: [String: String]], localId: String?, codex: LimitData,
                   poll: AutoPollState, gistId: String?, machineId: String, machineName: String, osName: String,
                   now: Date, attemptKind: String = "auto", automatic: Bool = true) -> [String: Any] {
    // The local usage index is untrusted text too (CLI model/day identifiers).
    var cleanDays: [String: Any] = [:]
    for product in ["claude", "codex"] {
        guard let productDays = days[product] as? [String: Any] else { continue }
        var acceptedDays: [String: Any] = [:]
        for (day, rawModels) in productDays {
            guard day.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}$", options: .regularExpression) != nil,
                  let models = rawModels as? [String: Any] else { continue }
            var acceptedModels: [String: Any] = [:]
            for (model, rawCounts) in models {
                guard let name = c4Text(model, limit: 128), !name.isEmpty, let counts = rawCounts as? [String: Any] else { continue }
                var acceptedCounts: [String: Any] = [:]
                for key in ["input", "output", "cacheRead", "cacheWrite5m", "cacheWrite1h", "turns"] {
                    if let value = c4Number(counts[key]), value >= 0, value <= 1e15, value.rounded() == value { acceptedCounts[key] = Int64(value) }
                    else { acceptedCounts[key] = 0 }
                }
                acceptedModels[name] = acceptedCounts
            }
            if !acceptedModels.isEmpty { acceptedDays[day] = acceptedModels }
        }
        if !acceptedDays.isEmpty { cleanDays[product] = acceptedDays }
    }
    let days = cleanDays
    let stamp = c4ISOTime(now.timeIntervalSince1970) ?? "1970-01-01T00:00:00Z"
    var accounts: [[String: Any]] = [], unattributed: [String: Any] = [:]
    let key = gistId.flatMap { accountLabelKey(gistId: $0) }
    let label = localId.flatMap { id in key.flatMap { accountLabel(product: "codex", localId: id, labelKey: $0) } }
    var record: [String: Any] = ["product": "codex", "label": label as Any? ?? NSNull(), "days": [String: Any]()]
    if label == nil {
        record["status"] = localId == nil ? "signed_out" : "error"
        record["labelReason"] = localId == nil ? "no_login" : (key == nil ? "no_gist" : "no_account_uuid")
    } else {
        let deadline = poll.serverRetryAt.flatMap { $0.isFinite ? $0 : nil }
        record["status"] = !codex.present || codex.auth == .loggedOut ? "signed_out"
            : codex.auth == .expired ? "expired"
            : deadline.map { $0 > now.timeIntervalSince1970 } == true ? "rate_limited"
            : codex.error != nil ? "error" : codex.asOf != nil ? "ok" : "error"
        if codex.auth == .expired { record["expiredReason"] = codex.expiredReason ?? "cli_refresh_pending" }
        if record["status"] as? String != "signed_out", let asOf = c4ISOTime(codex.asOf?.timeIntervalSince1970) {
            record["asOf"] = asOf
            var windows: [String: Any] = [:]
            for (name, pct, reset) in [("session", codex.session, codex.sessionReset), ("weekly", codex.weekly, codex.weeklyReset)] {
                if let pct = pct, pct.isFinite, (0...100).contains(pct) {
                    var w: [String: Any] = ["pct": pct]; w["resetAt"] = c4ISOTime(reset?.timeIntervalSince1970); windows[name] = w
                }
            }
            if !windows.isEmpty { record["windows"] = windows }
            record["plan"] = c4Text(codex.plan, limit: 64)
            if let credits = codex.resetCredits, (0...1000).contains(credits) { record["resetCredits"] = credits }
        }
        if poll.lastAttempt > 0, let attempt = c4ISOTime(poll.lastAttempt) {
            record["attemptAt"] = attempt; record["attemptKind"] = ["auto", "activity", "manual", "initial"].contains(attemptKind) ? attemptKind : "auto"
        }
        let interval = c4Interval(poll.interval)
        var schedule: [String: Any] = ["mode": automatic ? "auto" : "fixed", "interval": Int(interval), "backoff": poll.failed]
        if poll.lastAttempt > 0 { schedule["nextAt"] = c4ISOTime(poll.lastAttempt + interval) }
        record["schedule"] = schedule; record["retryUntil"] = c4ISOTime(deadline) as Any? ?? NSNull()
    }
    accounts.append(record)
    var historyIndices: [String: Int] = [:]
    if let id = localId, label != nil { historyIndices[id] = 0 }
    for product in days.keys.sorted() {
        guard let productDays = days[product] as? [String: Any] else { continue }
        var missing: [String: Any] = [:]
        for day in productDays.keys.sorted() {
            let value = productDays[day]!
            guard product == "codex", let id = accountByDay[product]?[day], !id.isEmpty,
                  let key = key, let historicalLabel = accountLabel(product: "codex", localId: id, labelKey: key) else { missing[day] = value; continue }
            var slot = historyIndices[id]
            if slot == nil, accounts.count < 8 {
                slot = accounts.count; historyIndices[id] = slot
                accounts.append(["product": "codex", "label": historicalLabel, "status": "signed_out", "days": [String: Any]()])
            }
            guard let slot = slot else { missing[day] = value; continue }
            var byDay = accounts[slot]["days"] as? [String: Any] ?? [:]; byDay[day] = value; accounts[slot]["days"] = byDay
        }
        if !missing.isEmpty { unattributed[product] = missing }
    }
    var machine: [String: Any] = ["id": machineId, "name": machineTag(setting: c4Text(machineName, limit: 64) ?? "mac", hostname: "mac"), "app": "macos " + APP_VERSION]
    machine["os"] = c4Text(osName, limit: 64)
    return ["schema": 1, "machine": machine, "updated": stamp, "lastSeenAt": stamp, "tz": TimeZone.current.identifier,
            "days": days, "accounts": accounts, "unattributedDays": unattributed, "captions": [String: Any]()]
}
func c4Fingerprints(_ file: [String: Any]) -> (push: String, meta: String) {
    func hash(_ value: Any) -> String {
        let bytes = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return Insecure.SHA1.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    let accounts = (file["accounts"] as? [[String: Any]] ?? []).map { value -> [String: Any] in var copy = value; copy.removeValue(forKey: "days"); return copy }
    return (hash(file["days"] ?? [:]), hash(["accounts": accounts, "captions": file["captions"] ?? [:]]))
}

func c4ManualPhase(_ phase: RemoteManualPhase?, startedAt: Date?, now: Date) -> RemoteManualPhase? {
    guard let phase = phase else { return nil }
    switch phase {
    case .cooldown:
        guard let start = startedAt else { return nil }
        let remaining = 30 - now.timeIntervalSince(start)
        return remaining > 0 ? .cooldown(Int(ceil(min(30, remaining)))) : nil
    case .checked(let at): return (0..<60).contains(now.timeIntervalSince(at)) ? phase : nil
    case .pollAllowed(let at): return at > now ? phase : nil
    default: return phase
    }
}

enum SyncMode { case full, readOnly, writeOnly }
enum SyncOutcome {
    case success(SyncRemoteCache), partial(SyncRemoteCache), failed
    var readable: Bool { if case .failed = self { return false }; return true }
}

struct C4TickState: Codable {
    var poll: AutoPollState = AutoPollState()
    var remoteRetry: [String: Double]? = nil
    var tieMachine: String? = nil
    var tieNextAt: Double? = nil
    var publishFailures: Int = 0
    var rollbackLastAttempt: Double? = nil
    var snapshot: Data? = nil
    var status: String = "error"
    var expiredReason: String? = nil
    var attemptKind: String = "auto"
    var pendingAttempt: Bool = false
}
struct C4TickDependencies {
    var clock: () -> Date
    var read: (@escaping (SyncOutcome) -> Void) -> Void
    var writeOnly: (@escaping (SyncOutcome) -> Void) -> Void
    var save: (C4TickState) -> Bool
    var fetch: () -> LimitData
    var emit: ([String: Any]) -> Void
    var armTimeout: (TimeInterval, @escaping () -> Void) -> Void
    var apply: (LimitData) -> Void = { _ in }
    var retryableWriteFailure: () -> Bool = { false }
    var currentLocalId: (() -> String?)? = nil
    var onDecision: ([String: Any], Date?) -> Void = { _, _ in }
    var fixedInterval: Double? = nil
    var canPollWithoutRead: () -> Bool = { true }
    var syncPhase: () -> SyncPhase = { .on }
}

/// All methods and dependency callbacks use one caller-owned executor. Tests execute
/// inline; AppDelegate uses a dedicated serial utility queue, never the main queue.
final class C4TickController {
    private(set) var state: C4TickState
    let myId: String, localId: String
    private let io: C4TickDependencies
    private var flight: UUID?
    private var phase: UUID?
    private var manualReadAt: Date?
    private var originalPoll: AutoPollState?
    var remoteRetry: [String: Double]? { state.remoteRetry }
    var tieWait: [Any]? { if let m = state.tieMachine, let t = state.tieNextAt { return [m, t] }; return nil }
    var publishFailures: Int { state.publishFailures }
    init(state: C4TickState, myId: String, localId: String, dependencies: C4TickDependencies) {
        self.state = state; self.myId = myId; self.localId = localId; self.io = dependencies
    }
    private func event(_ name: String, _ values: [String: Any] = [:]) {
        var line = values; line["ev"] = name; line["ts"] = io.clock().timeIntervalSince1970
        io.emit(line)
    }
    private func skip(_ reason: String) { event("poll_skipped", ["product": "codex", "reason": reason]) }
    private func finish(_ id: UUID, _ completion: () -> Void) {
        guard flight == id else { return }; phase = nil; flight = nil; completion()
    }
    private func phaseCall(_ operation: (@escaping (SyncOutcome) -> Void) -> Void, _ body: @escaping (SyncOutcome) -> Void) {
        let phaseID = UUID(); phase = phaseID
        io.armTimeout(60) { [weak self] in
            guard let self = self, self.flight != nil, self.phase == phaseID else { return }
            self.phase = nil; body(.failed)
        }
        operation { [weak self] outcome in
            guard let self = self, self.flight != nil, self.phase == phaseID else { return }
            self.phase = nil; body(outcome)
        }
    }
    func tick(manual: Bool = false, completion: @escaping () -> Void = {}) {
        guard flight == nil else { skip("busy"); completion(); return }
        let id = UUID(); flight = id
        if let rollback = state.rollbackLastAttempt {
            state.poll.lastAttempt = rollback; state.rollbackLastAttempt = nil; state.pendingAttempt = false
            guard io.save(state) else { skip("state_unsaved"); finish(id, completion); return }
        }
        let now = io.clock().timeIntervalSince1970
        if state.poll.lastAttempt > now {
            state.poll.lastAttempt = now
            guard io.save(state) else { skip("state_unsaved"); finish(id, completion); return }
        }
        originalPoll = state.poll
        if io.syncPhase() != .on {
            localPoll(id, manual: manual, coordinated: false, completion: completion); return
        }
        if manual, let readAt = manualReadAt, io.clock().timeIntervalSince(readAt) < 30 {
            skip("not_due"); finish(id, completion); return
        }
        if manual { manualReadAt = io.clock() }
        let interval = manual && !state.poll.failed ? 900 : state.poll.interval
        let due = (state.poll.lastAttempt == 0 || now - state.poll.lastAttempt >= interval) && now >= (state.poll.serverRetryAt ?? 0)
        let previousFailures = state.publishFailures
        let interruptedDay = (previousFailures >= 1 || state.pendingAttempt) && state.poll.lastAttempt > 0
            && now - state.poll.lastAttempt >= max(state.poll.interval, 86400)
        if due && io.canPollWithoutRead() && (previousFailures >= 3 || (previousFailures + 1 >= 3 && state.pendingAttempt) || interruptedDay) {
            let decision = decide(now: now, manual: manual, remote: [])
            if decision["action"] as? String == "poll" {
                state.poll.begin(now); state.pendingAttempt = true; state.attemptKind = manual ? "manual" : "auto"
                guard io.save(state) else { skip("state_unsaved"); finish(id, completion); return }
                poll(id, manual: manual, publishResult: false, recoverRead: true, completion: completion); return
            }
        }
        readAndDecide(id, manual: manual, due: due, previousFailures: previousFailures, reopened: false, completion: completion)
    }
    private func readAndDecide(_ id: UUID, manual: Bool, due: Bool, previousFailures: Int, reopened: Bool,
                               completion: @escaping () -> Void) {
        phaseCall(io.read) { [weak self] outcome in
            guard let self = self, self.flight == id else { return }
            guard self.io.syncPhase() == .on else {
                self.localPoll(id, manual: manual, coordinated: false, completion: completion); return
            }
            let cache: SyncRemoteCache
            switch outcome {
            case .success(let value), .partial(let value): cache = value
            case .failed:
                // GET failure has no announcement and consumes no PATCH failure budget.
                self.localPoll(id, manual: manual, coordinated: true, eligible: due, completion: completion); return
            }
            let now = self.io.clock().timeIntervalSince1970
            let remote = c4CoordinationRemote(cache, localId: self.localId)
            let decision: [String: Any] = due ? self.decide(now: now, manual: manual, remote: remote) : ["action": "skip", "reason": "not_due"]
            let next = self.nextAt(now: now, manual: manual, remote: remote)
            self.io.onDecision(decision, Date(timeIntervalSince1970: next))
            guard self.io.syncPhase() == .on else {
                self.localPoll(id, manual: manual, coordinated: false, completion: completion); return
            }
            if !due || decision["action"] as? String != "poll" {
                self.state.publishFailures = previousFailures
                guard self.io.save(self.state) else { self.skip("state_unsaved"); self.finish(id, completion); return }
                self.skip(!due ? "not_due" : decision["reason"] as? String ?? "not_due")
                self.finish(id, completion); return
            }
            guard (cache.labelKey ?? cache.gistId.flatMap { accountLabelKey(gistId: $0) }) != nil else {
                self.state.publishFailures = previousFailures; _ = self.io.save(self.state)
                self.skip("no_label"); self.finish(id, completion); return
            }
            let previous = self.state.poll.lastAttempt
            self.state.poll.begin(now); self.state.attemptKind = manual ? "manual" : "auto"; self.state.pendingAttempt = true
            guard self.io.save(self.state) else {
                self.state.poll.lastAttempt = previous; self.state.pendingAttempt = false
                self.skip("state_unsaved"); self.finish(id, completion); return
            }
            if previousFailures == 0 && previous > 0 && now - previous >= max(self.state.poll.interval, 86400) {
                // The day-cap request must survive a repeatedly killed PATCH.
                // Linux applies the same escape only AFTER this GET's decision.
                self.poll(id, manual: manual, publishResult: true, completion: completion); return
            }
            guard self.io.syncPhase() == .on else {
                self.state.poll.lastAttempt = previous; self.state.pendingAttempt = false
                self.localPoll(id, manual: manual, coordinated: false, completion: completion); return
            }
            // Journal only an announcement attempt, before its blocking PATCH.
            self.state.publishFailures = min(3, max(0, previousFailures) + 1)
            guard self.io.save(self.state) else { self.skip("state_unsaved"); self.finish(id, completion); return }
            self.phaseCall(self.io.writeOnly) { [weak self] write in
                guard let self = self, self.flight == id else { return }
                guard self.io.syncPhase() == .on else {
                    self.state.poll.lastAttempt = previous; self.state.pendingAttempt = false
                    self.state.publishFailures = previousFailures
                    self.localPoll(id, manual: manual, coordinated: false, completion: completion); return
                }
                switch write {
                case .success, .partial:
                    self.state.publishFailures = 0
                    guard self.io.save(self.state) else { self.skip("state_unsaved"); self.finish(id, completion); return }
                    self.poll(id, manual: manual, publishResult: true, completion: completion)
                case .failed:
                    // The rollback marker is durable before the restored attempt. A killed
                    // rollback cannot authorize a second provider request after restart.
                    self.state.rollbackLastAttempt = previous
                    guard self.io.save(self.state) else { self.skip("state_unsaved"); self.finish(id, completion); return }
                    self.state.poll.lastAttempt = previous; self.state.rollbackLastAttempt = nil; self.state.pendingAttempt = false
                    guard self.io.save(self.state) else { self.skip("state_unsaved"); self.finish(id, completion); return }
                    self.failedPublication(id, manual: manual, due: due, previousFailures: previousFailures,
                                           reopened: reopened, announced: true, completion: completion)
                }
            }
        }
    }
    private func decide(now: Double, manual: Bool, remote: [[String: Any]]) -> [String: Any] {
        var mine: [String: Any] = ["interval": state.poll.interval, "last_attempt": state.poll.lastAttempt, "manual": manual]
        mine["server_until"] = state.poll.serverRetryAt; mine["remote_retry"] = state.remoteRetry
        let value = coordinationDecide(now: now, mine: mine, remote: remote, myId: myId, tieWait: tieWait)
        state.remoteRetry = value["remote_retry"] as? [String: Double]
        let pair = value["tie_wait"] as? [Any]
        state.tieMachine = pair?.first as? String; state.tieNextAt = pair.flatMap { $0.count == 2 ? c4Number($0[1]) : nil }
        for name in value["events"] as? [String] ?? [] { event(name, ["product": "codex"]) }
        return value
    }
    private func nextAt(now: Double, manual: Bool, remote: [[String: Any]]) -> Double {
        let interval = manual && !state.poll.failed ? 900 : state.poll.interval
        var next = state.poll.lastAttempt == 0 ? now : state.poll.lastAttempt + interval
        next = max(next, state.poll.serverRetryAt ?? 0)
        if let r = state.remoteRetry, let until = r["until"], let first = r["firstSeenAt"] { next = max(next, min(until, first + 86400)) }
        for r in coordinationRecords(now: now, remote: remote, myId: myId) {
            if let attempt = c4Number(r["attemptAt"]) { next = max(next, attempt + 960) }
        }
        return next
    }
    private func failedPublication(_ id: UUID, manual: Bool, due: Bool, previousFailures: Int, reopened: Bool,
                                   announced: Bool, completion: @escaping () -> Void) {
        guard due else { skip(io.canPollWithoutRead() ? "publish_failed" : "no_label"); finish(id, completion); return }
        let now = io.clock().timeIntervalSince1970
        let decision = decide(now: now, manual: manual, remote: [])
        guard io.save(state) else { skip("state_unsaved"); finish(id, completion); return }
        guard io.canPollWithoutRead() else { skip("no_label"); finish(id, completion); return }
        let dayDue = state.poll.lastAttempt > 0 && now - state.poll.lastAttempt >= max(state.poll.interval, 86400)
        let fallback = due && io.canPollWithoutRead() && (state.publishFailures >= 3 || dayDue) && decision["action"] as? String == "poll"
        if fallback {
            state.poll.begin(now); state.attemptKind = manual ? "manual" : "auto"; state.pendingAttempt = true
            guard io.save(state) else { skip("state_unsaved"); finish(id, completion); return }
            poll(id, manual: manual, publishResult: false, completion: completion)
        } else if announced && !reopened && io.retryableWriteFailure() {
            readAndDecide(id, manual: manual, due: due, previousFailures: previousFailures, reopened: true, completion: completion)
        } else { skip("publish_failed"); finish(id, completion) }
    }
    private func recoverPublication(_ id: UUID, completion: @escaping () -> Void) {
        guard io.syncPhase() == .on else { finish(id, completion); return }
        // Exhausted failure series moves this request ahead of a potentially
        // hanging GET, but still attempts one read/result publication afterward.
        phaseCall(io.read) { [weak self] outcome in
            guard let self = self, self.flight == id else { return }
            guard self.io.syncPhase() == .on else { self.finish(id, completion); return }
            guard outcome.readable else { self.finish(id, completion); return }
            self.phaseCall(self.io.writeOnly) { [weak self] write in
                guard let self = self, self.flight == id else { return }
                if case .success = write {
                    self.state.publishFailures = 0
                    if !self.io.save(self.state) { self.skip("state_unsaved") }
                } else { self.skip("publish_failed") }
                self.finish(id, completion)
            }
        }
    }

    /// GET outage retains already accepted B2 retry; standalone macOS uses only its own B1.
    private func localPoll(_ id: UUID, manual: Bool, coordinated: Bool, eligible: Bool = true,
                           completion: @escaping () -> Void) {
        let now = io.clock().timeIntervalSince1970
        let interval = manual && !state.poll.failed ? 900 : state.poll.interval
        let ownNext = max(state.poll.lastAttempt == 0 ? now : state.poll.lastAttempt + interval, state.poll.serverRetryAt ?? 0)
        let ownEligible = eligible && now >= ownNext
        let decision = coordinated && ownEligible ? decide(now: now, manual: manual, remote: []) : [:]
        if !ownEligible || (coordinated && decision["action"] as? String != "poll") {
            guard io.save(state) else { skip("state_unsaved"); finish(id, completion); return }
            let reason = now < (state.poll.serverRetryAt ?? 0) ? "retry_after"
                : !eligible || now < ownNext ? "not_due" : decision["reason"] as? String ?? "not_due"
            skip(reason); finish(id, completion); return
        }
        state.pendingAttempt = true; state.attemptKind = manual ? "manual" : "auto"
        poll(id, manual: manual, publishResult: false, completion: completion)
    }
    private func rejectIdentity(_ id: UUID, completion: () -> Void) {
        // Persist the rollback marker before restoring; restart cannot retain B's attempt under A.
        state.rollbackLastAttempt = originalPoll?.lastAttempt ?? state.poll.lastAttempt
        guard io.save(state) else { skip("state_unsaved"); finish(id, completion); return }
        if let previous = originalPoll { state.poll = previous }
        state.rollbackLastAttempt = nil; state.pendingAttempt = false
        if !io.save(state) { skip("state_unsaved") }
        event("identity_changed", ["product": "codex"]); finish(id, completion)
    }
    private func poll(_ id: UUID, manual: Bool, publishResult: Bool, recoverRead: Bool = false, completion: @escaping () -> Void) {
        if let identity = io.currentLocalId, identity() != localId {
            rejectIdentity(id, completion: completion); return
        }
        // Record the actual provider start, too: a slow announcement must not
        // shorten the restart floor relative to the HTTP request.
        state.poll.begin(io.clock().timeIntervalSince1970)
        guard io.save(state) else { skip("state_unsaved"); finish(id, completion); return }
        event("poll_attempt", ["product": "codex", "kind": manual ? "manual" : "auto", "attemptAt": state.poll.lastAttempt])
        let result = io.fetch()
        guard result.localAccountId == localId,
              io.currentLocalId.map({ $0() == localId }) ?? true else {
            rejectIdentity(id, completion: completion); return
        }
        let now = io.clock().timeIntervalSince1970
        state.poll.observe(result, now: now); state.poll.serverRetryAt = result.serverRetryAt
        if let fixed = io.fixedInterval { state.poll.interval = c4Interval(fixed) }
        state.pendingAttempt = false
        let fresh = result.apiFresh && result.error == nil && result.auth == .ok && !result.fromCache && !result.stale && result.asOf != nil
        if fresh { state.snapshot = try? JSONSerialization.data(withJSONObject: ld2dict(result)) }
        state.status = !result.present || result.auth == .loggedOut ? "signed_out" : result.auth == .expired ? "expired"
            : result.serverRetryAt.map { $0 > now } == true ? "rate_limited" : fresh ? "ok" : "error"
        state.expiredReason = result.expiredReason
        if state.status == "signed_out" { state.snapshot = nil }
        guard io.save(state) else { skip("state_unsaved"); finish(id, completion); return }
        io.apply(result)
        event("poll_result", ["product": "codex", "httpStatus": result.httpStatus as Any? ?? NSNull(), "result": fresh ? "ok" : "failed"])
        guard io.syncPhase() == .on else { finish(id, completion); return }
        guard publishResult else {
            if recoverRead { recoverPublication(id, completion: completion) } else { finish(id, completion) }
            return
        }
        phaseCall(io.writeOnly) { [weak self] outcome in
            guard let self = self, self.flight == id else { return }
            if case .failed = outcome { self.skip("publish_failed") }
            self.finish(id, completion)
        }
    }
}

/// One atomic local-file writer shared by credential CAS and account-bound state.
/// The optional check is evaluated after fsync immediately before rename.
@discardableResult func c4AtomicWrite(_ data: Data, path: String, beforeRename: () -> Bool = { true }) -> Bool {
    let directory = (path as NSString).deletingLastPathComponent
    let temporary = directory + "/.ccl-" + UUID().uuidString
    let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard fd >= 0 else { return false }
    var closed = false
    defer { if !closed { close(fd) }; unlink(temporary) }
    let written: Bool = data.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            let n = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
            if n < 0 && errno == EINTR { continue }; if n <= 0 { return false }; offset += n
        }
        return true
    }
    guard written, fsync(fd) == 0 else { return false }
    close(fd); closed = true
    guard beforeRename(), rename(temporary, path) == 0 else { return false }
    let directoryFD = open(directory, O_RDONLY)
    if directoryFD >= 0 { _ = fsync(directoryFD); close(directoryFD) }
    return true
}

func c4CacheQuotaCompletion(product: String, response: LimitData, previous: LimitData, previousId: String?, readingId: String?,
                            path: String) -> (data: LimitData, id: String?) {
    var cache = (FileManager.default.contents(atPath: path).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
    let old = cache[product] as? [String: Any]
    let samePrevious = readingId != nil && previousId == readingId
    let sameCache = readingId != nil && old?["accountId"] as? String == readingId
    let ownedResponse = readingId != nil && response.localAccountId == readingId
    var accepted = ownedResponse ? response : LimitData(error: "identity_changed")
    if samePrevious { accepted = quotaSelectSnapshot(accepted, previous: previous) }
    if sameCache, let old = old { accepted = quotaSelectSnapshot(accepted, previous: dict2ld(old)) }
    let selected: (data: LimitData, id: String?) = (accepted, quotaHasReadings(accepted) ? readingId : nil)
    if ownedResponse && response.apiFresh, let id = readingId, selected.id == id {
        var entry = ld2dict(selected.data); entry["accountId"] = id; cache[product] = entry
        if let data = try? JSONSerialization.data(withJSONObject: cache) { _ = c4AtomicWrite(data, path: path) }
    }
    return selected
}

/// Only local identities key this store; labels are derived afresh for every gist.
final class C4PublisherStore {
    private let lock = NSLock()
    private let path: String
    private var buckets: [String: C4TickState] = [:]
    private var available = true
    init(path: String) {
        self.path = path
        if FileManager.default.fileExists(atPath: path) {
            if let bytes = FileManager.default.contents(atPath: path), let values = try? JSONDecoder().decode([String: C4TickState].self, from: bytes) { buckets = values }
            else { available = false }
        }
    }
    func state(_ id: String, initial: AutoPollState = AutoPollState()) -> C4TickState {
        lock.lock(); defer { lock.unlock() }; return buckets[id] ?? (buckets.isEmpty ? C4TickState(poll: initial) : C4TickState())
    }
    @discardableResult func save(_ state: C4TickState, id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard available else { return false }
        var next = buckets; next[id] = state
        guard let bytes = try? JSONEncoder().encode(next) else { return false }
        do { try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true) } catch { return false }
        guard c4AtomicWrite(bytes, path: path) else { return false }; buckets = next; return true
    }
}
func c4StoredReading(_ state: C4TickState) -> LimitData {
    let object = state.snapshot.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
    var value = object.map(dict2ld) ?? LimitData()
    value.auth = state.status == "expired" ? .expired : state.status == "signed_out" ? .loggedOut : .ok
    value.present = state.status != "signed_out"; value.error = ["error", "expired"].contains(state.status) ? state.status : nil
    value.expiredReason = state.expiredReason; value.serverRetryAt = state.poll.serverRetryAt
    return value
}
