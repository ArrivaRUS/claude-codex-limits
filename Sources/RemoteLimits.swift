import Foundation
import CoreFoundation
import CryptoKit

// The wire reader and resolver are pure: every clock and all account identities
// come from their caller. Nothing here reads credentials, preferences or files.
typealias RemoteDays = [String: [String: DayModelUsage]]
typealias RemoteProductDays = [String: RemoteDays]

struct RemoteWindow: Codable {
    var pct: Double
    var resetAt: Date? = nil
}

struct RemoteWindows: Codable {
    var session: RemoteWindow? = nil
    var weekly: RemoteWindow? = nil
}

struct RemoteModel: Codable {
    var name: String
    var pct: Double
    var resetAt: Date? = nil
}

struct RemoteSchedule: Codable {
    var mode: String
    var interval: Int
    var nextAt: Date? = nil
    var backoff: Bool? = nil
}

struct RemoteCaption: Codable {
    var text: String
    var setAt: Date? = nil
}

struct RemoteAccount: Codable {
    var product: String
    var label: String? = nil
    var status: String
    var plan: String? = nil
    var tier: String? = nil
    var expiredReason: String? = nil
    var labelReason: String? = nil
    var attemptKind: String? = nil
    var asOf: Date? = nil
    var attemptAt: Date? = nil
    var retryUntil: Date? = nil
    var windows: RemoteWindows? = nil
    var models: [RemoteModel]? = nil
    var resetCredits: Int? = nil
    var schedule: RemoteSchedule? = nil
    var days: RemoteDays = [:]
    var machineId: String = ""
    var machineName: String = ""
    var machineLastSeenAt: Date? = nil
}

struct RemoteSource: Codable {
    var machineId: String
    var machineName: String
    var asOf: Date? = nil
    var attemptAt: Date? = nil
    var nextAt: Date? = nil
    var interval: Int? = nil
    var mode: String? = nil
    var status: String = "error"
    var retryUntil: Date? = nil
    var lastSeenAt: Date? = nil
    var freshUntil: Date? = nil
    // A newer failed attempt may belong to a different machine from the values.
    var statusMachineId: String? = nil
    var statusMachineName: String? = nil
    var expiredReason: String? = nil
    var backoff: Bool? = nil
    var futureAsOf: Bool = false
}

struct ReaderSyncState {
    var phase: SyncPhase
    var warning: String? = nil
}

enum RemoteCardState: Int {
    case fresh = 1, stale = 2, signInRequired = 3, serviceWait = 4
    case offline = 5, syncStalled = 6, signedOut = 7
}

struct AccountView {
    var product: String
    var label: String?
    var historyKey: String
    var caption: String
    var data: LimitData
    var isLocal: Bool
    var tier: String?
    var usageDays: RemoteDays
    var machines: [String]
    var state: RemoteCardState
}

func accountLabel(product: String, localId: String, gistId: String) -> String? {
    guard ["claude", "codex"].contains(product),
          !gistId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    let id = localId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard (8...64).contains(id.utf8.count), id.utf8.allSatisfy({
        (48...57).contains($0) || (97...122).contains($0) || $0 == 45
    }) else { return nil }
    let key = SHA256.hash(data: Data(("ccl-label-key-v1|" + gistId).utf8))
    let message = Data(("ccl-account-v1|" + product + "|" + id).utf8)
    let digest = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: Data(key)))
    return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
}

func machineTag(setting: String, hostname: String) -> String {
    let raw = setting.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? String(hostname.split(separator: ".", omittingEmptySubsequences: false).first ?? "") : setting
    // Writer sanitization differs deliberately from the reader's whole-field rejection.
    let clean = String(String.UnicodeScalarView(raw.unicodeScalars.filter { !RemoteLimitsWire.unsafe($0) }))
    let ascii = clean.decomposedStringWithCompatibilityMapping.unicodeScalars.filter { $0.value < 128 }
    let lower = String(String.UnicodeScalarView(ascii)).lowercased()
    let tag = lower.replacingOccurrences(of: "[^a-z0-9-]+", with: "-", options: .regularExpression)
        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    let short = String(tag.prefix(16)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return short.isEmpty ? "mac" : short
}

private enum RemoteLimitsWire {
    static let counters = ["input", "output", "cacheRead", "cacheWrite5m", "cacheWrite1h", "turns"]

    static func unsafe(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .surrogate: return true
        default: return false
        }
    }

    static func text(_ value: Any?, limit: Int? = nil, nfc: Bool = false) -> String? {
        guard let value = value as? String,
              !value.unicodeScalars.contains(where: unsafe),
              limit.map({ value.unicodeScalars.count <= $0 }) ?? true else { return nil }
        let result = nfc ? value.precomposedStringWithCanonicalMapping : value
        guard limit.map({ result.unicodeScalars.count <= $0 }) ?? true else { return nil }
        return result
    }

    static func label(_ value: Any?) -> String? {
        guard let s = value as? String, s.utf8.count == 16,
              s.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return s
    }

    static func integer(_ value: Any?, maximum: Int) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: n.objCType)),
              n.doubleValue.isFinite, n.doubleValue >= 0, n.doubleValue <= Double(maximum) else { return nil }
        return n.intValue
    }

    // The established macOS v1 reader accepts an exactly bridgeable JSON 1.0.
    // Keep that compatibility for the envelope and all v1 usage counters, while v1.1
    // schedule/resetCredits retain their stricter JSON-integer contract.
    static func legacyInteger(_ value: Any?, maximum: Int) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              let n = value as? Int, (0...maximum).contains(n) else { return nil }
        return n
    }

    static func percent(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite, (0...100).contains(n.doubleValue) else { return nil }
        return n.doubleValue
    }

    /// Bounded, Gregorian ISO parsing, including fractions and numeric offsets.
    /// Foundation's permissive date normalization must not turn month 13 into a date.
    static func date(_ value: Any?) -> Date? {
        guard let raw = value as? String, raw.utf8.count <= 4096,
              let safe = text(raw, limit: 4096) else { return nil }
        let s = safe.trimmingCharacters(in: .whitespaces)
        let pattern = "^([0-9]{4})-([0-9]{2})-([0-9]{2})[T ]([0-9]{2}):([0-9]{2}):([0-9]{2})(\\.[0-9]+)?(Z|[+-][0-9]{2}:?[0-9]{2})?$"
        guard let re = try? NSRegularExpression(pattern: pattern),
              let match = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              match.range.length == s.utf16.count else { return nil }
        func group(_ index: Int) -> String? {
            guard let r = Range(match.range(at: index), in: s) else { return nil }
            return String(s[r])
        }
        guard let year = group(1).flatMap({ Int($0) }), (1...9999).contains(year),
              let month = group(2).flatMap({ Int($0) }), (1...12).contains(month),
              let day = group(3).flatMap({ Int($0) }),
              let hour = group(4).flatMap({ Int($0) }), (0...23).contains(hour),
              let minute = group(5).flatMap({ Int($0) }), (0...59).contains(minute),
              let second = group(6).flatMap({ Int($0) }), (0...59).contains(second) else { return nil }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        guard (1...lengths[month - 1]).contains(day) else { return nil }
        var offset = 0
        if let zone = group(8), zone != "Z" {
            let digits = zone.dropFirst().replacingOccurrences(of: ":", with: "")
            guard let h = Int(digits.prefix(2)), h < 24, let m = Int(digits.suffix(2)), m < 60 else { return nil }
            offset = (zone.first == "-" ? -1 : 1) * (h * 3600 + m * 60)
        }
        let fraction = group(7).flatMap { Double($0) } ?? 0
        guard fraction.isFinite else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let base = calendar.date(from: parts) else { return nil }
        return base.addingTimeInterval(fraction - Double(offset))
    }

    static func window(_ value: Any?) -> RemoteWindow? {
        guard let v = value as? [String: Any], let pct = percent(v["pct"]) else { return nil }
        return RemoteWindow(pct: pct, resetAt: date(v["resetAt"]))
    }

    static func days(_ value: Any?) -> RemoteDays {
        guard let byDay = value as? [String: Any] else { return [:] }
        var result: RemoteDays = [:]
        for (day, rawModels) in byDay {
            guard text(day) != nil, let models = rawModels as? [String: Any] else { continue }
            for (model, rawCounts) in models {
                guard text(model) != nil, let counts = rawCounts as? [String: Any] else { continue }
                let values: [Int?] = counters.map { legacyInteger(counts[$0] ?? 0, maximum: 1_000_000_000_000_000) }
                guard values.allSatisfy({ $0 != nil }) else { continue }
                result[day, default: [:]][model] = DayModelUsage(input: values[0]!, output: values[1]!, cacheRead: values[2]!,
                    cacheWrite5m: values[3]!, cacheWrite1h: values[4]!, turns: values[5]!)
            }
        }
        return result
    }

    static func productDays(_ value: Any?) -> RemoteProductDays {
        guard let products = value as? [String: Any] else { return [:] }
        var result: RemoteProductDays = [:]
        for (product, raw) in products where text(product) != nil {
            let clean = days(raw)
            if !clean.isEmpty { result[product] = clean }
        }
        return result
    }

    static func account(_ value: Any?) -> RemoteAccount? {
        guard let v = value as? [String: Any], let product = v["product"] as? String,
              ["claude", "codex"].contains(product), v["status"] != nil else { return nil }
        let statuses = ["ok", "stale", "signed_out", "expired", "rate_limited", "error"]
        let status = v["status"] as? String ?? "error"
        var a = RemoteAccount(product: product, label: label(v["label"]), status: statuses.contains(status) ? status : "error")
        a.plan = text(v["plan"], limit: 64); a.tier = text(v["tier"], limit: 64)
        if let reason = v["expiredReason"] as? String, ["cli_refresh_pending", "signin_required"].contains(reason) { a.expiredReason = reason }
        if let reason = v["labelReason"] as? String, ["no_login", "no_account_uuid", "unreadable", "no_gist"].contains(reason) { a.labelReason = reason }
        if let kind = v["attemptKind"] as? String, ["auto", "activity", "manual", "initial"].contains(kind) { a.attemptKind = kind }
        a.asOf = date(v["asOf"]); a.attemptAt = date(v["attemptAt"]); a.retryUntil = date(v["retryUntil"])
        if let windows = v["windows"] as? [String: Any] {
            a.windows = RemoteWindows(session: window(windows["session"]), weekly: window(windows["weekly"]))
        }
        if let models = v["models"] as? [Any] {
            a.models = models.prefix(8).compactMap { raw -> RemoteModel? in
                guard let m = raw as? [String: Any], let w = window(raw), let name = text(m["name"], limit: 48, nfc: true) else { return nil }
                return RemoteModel(name: name, pct: w.pct, resetAt: w.resetAt)
            }
        }
        a.resetCredits = integer(v["resetCredits"], maximum: 1000)
        if let s = v["schedule"] as? [String: Any], let mode = s["mode"] as? String, ["auto", "fixed"].contains(mode),
           let interval = integer(s["interval"], maximum: 14400), [900, 1800, 3600, 14400].contains(interval) {
            var backoff: Bool? = nil
            if let n = s["backoff"] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { backoff = n.boolValue }
            a.schedule = RemoteSchedule(mode: mode, interval: interval, nextAt: date(s["nextAt"]), backoff: backoff)
        }
        // Bound sanitized metadata, before copying usage and machine provenance.
        guard let metadata = try? JSONEncoder().encode(a), metadata.count <= 4096 else { return nil }
        a.days = days(v["days"])
        return a
    }

    static func add(_ source: RemoteDays, to target: inout RemoteDays) {
        for (day, models) in source {
            for (model, counts) in models {
                var current = target[day, default: [:]][model] ?? DayModelUsage()
                current.add(counts)
                target[day, default: [:]][model] = current
            }
        }
    }

    // Projection checks use exact sums, not DayModelUsage.add's display cap.
    // At most eight validated accounts + one unattributed record contribute to
    // each counter, so these sums are at most 9 * 10^15 and fit in Int64.
    static func exactAdd(_ source: RemoteDays, to target: inout RemoteDays) {
        for (day, models) in source {
            for (model, u) in models {
                var c = target[day, default: [:]][model] ?? DayModelUsage()
                c.input += u.input; c.output += u.output; c.cacheRead += u.cacheRead
                c.cacheWrite5m += u.cacheWrite5m; c.cacheWrite1h += u.cacheWrite1h; c.turns += u.turns
                target[day, default: [:]][model] = c
            }
        }
    }

    static func equal(_ lhs: RemoteDays, _ rhs: RemoteDays) -> Bool {
        guard Set(lhs.keys) == Set(rhs.keys) else { return false }
        for (day, models) in lhs {
            guard let other = rhs[day], Set(models.keys) == Set(other.keys) else { return false }
            for (name, a) in models {
                guard let b = other[name], a.input == b.input, a.output == b.output, a.cacheRead == b.cacheRead,
                      a.cacheWrite5m == b.cacheWrite5m, a.cacheWrite1h == b.cacheWrite1h, a.turns == b.turns else { return false }
            }
        }
        return true
    }
}

func mergeV11(_ contents: [String: String], excluding myId: String, now: Date) -> SyncRemoteCache {
    var result = SyncRemoteCache()
    var records: [RemoteAccount] = [], captions: [String: RemoteCaption] = [:], unattributed: RemoteProductDays = [:]
    var seen = Set<String>(), bytes = 0
    let names = contents.keys.filter { $0.hasPrefix("machine-") && $0.hasSuffix(".json") }.sorted().prefix(64)
    for name in names {
        guard let content = contents[name] else { continue }
        let size = content.utf8.count
        bytes += size
        if bytes > 64 * 1024 * 1024 { break }
        guard size <= 8 * 1024 * 1024,
              let obj = (try? JSONSerialization.jsonObject(with: Data(content.utf8))) as? [String: Any],
              RemoteLimitsWire.legacyInteger(obj["schema"], maximum: 1) == 1,
              let machine = obj["machine"] as? [String: Any], let id = RemoteLimitsWire.text(machine["id"]), !id.isEmpty,
              id != myId, !seen.contains(id), name == "machine-\(id).json" else { continue }
        let updated = RemoteLimitsWire.date(obj["updated"])
        if obj["updated"] != nil && updated == nil { continue }
        if let updated = updated, updated < now.addingTimeInterval(-45 * 86400) { continue }
        seen.insert(id)
        let tag = String(String.UnicodeScalarView((RemoteLimitsWire.text(machine["name"]) ?? "").unicodeScalars.prefix(16)))
        let machineName = tag.isEmpty ? "?" : tag
        let os = RemoteLimitsWire.text(machine["os"], limit: 64) ?? ""
        let lastSeen = RemoteLimitsWire.date(obj["lastSeenAt"])
        var cached = SyncCachedMachine(id: id, name: machineName, os: os, updated: updated)
        cached.lastSeenAt = lastSeen
        result.machines.append(cached)

        let root = RemoteLimitsWire.productDays(obj["days"])
        for (product, days) in root {
            var merged = result.days[product] ?? [:]
            RemoteLimitsWire.add(days, to: &merged)
            result.days[product] = merged
        }
        var accounts: [RemoteAccount] = []
        for raw in ((obj["accounts"] as? [Any]) ?? []).prefix(64) {
            guard var a = RemoteLimitsWire.account(raw) else { continue }
            a.machineId = id; a.machineName = machineName; a.machineLastSeenAt = lastSeen ?? updated
            if let index = accounts.firstIndex(where: { $0.product == a.product && $0.label == a.label }) {
                if let date = a.asOf, accounts[index].asOf.map({ date > $0 }) ?? true { accounts[index] = a }
            } else if accounts.count < 8 { accounts.append(a) }
        }
        var other = RemoteLimitsWire.productDays(obj["unattributedDays"])
        var projection = other
        for a in accounts {
            var days = projection[a.product] ?? [:]
            RemoteLimitsWire.exactAdd(a.days, to: &days)
            projection[a.product] = days
        }
        for product in Set(root.keys).union(projection.keys) {
            if !RemoteLimitsWire.equal(root[product] ?? [:], projection[product] ?? [:]) {
                other[product] = root[product]
                for i in accounts.indices where accounts[i].product == product { accounts[i].days = [:] }
            }
        }
        // A null label has usage, but never a card. Move its validated days to V7.
        for a in accounts where a.label == nil {
            var days = other[a.product] ?? [:]
            RemoteLimitsWire.add(a.days, to: &days)
            if !days.isEmpty { other[a.product] = days }
        }
        for i in accounts.indices where accounts[i].label == nil { accounts[i].days = [:] }
        records.append(contentsOf: accounts)
        for (product, days) in other {
            var merged = unattributed[product] ?? [:]
            RemoteLimitsWire.add(days, to: &merged)
            unattributed[product] = merged
        }
        if let rawCaptions = obj["captions"] as? [String: Any] {
            var accepted = 0
            for key in rawCaptions.keys.sorted() {
                guard RemoteLimitsWire.label(key) != nil, let raw = rawCaptions[key] as? [String: Any],
                      let text = RemoteLimitsWire.text(raw["text"], limit: 32, nfc: true) else { continue }
                let caption = RemoteCaption(text: text, setAt: RemoteLimitsWire.date(raw["setAt"]))
                if captions[key] == nil || (caption.setAt.map { new in captions[key]?.setAt.map { new > $0 } ?? true } ?? false) {
                    captions[key] = caption
                }
                accepted += 1
                if accepted == 64 { break }
            }
        }
    }
    result.accounts = records; result.captions = captions; result.unattributedDays = unattributed
    return result
}

func resolveAccounts(local: (LimitData, LimitData), localIds: [String: String], remote: SyncRemoteCache,
                     hidden: Set<String>, menu: [String: String], sync: ReaderSyncState, now: Date) -> [AccountView] {
    var views: [AccountView] = []
    let enabled: Bool
    switch sync.phase { case .on: enabled = true; case .off, .revoked, .awaitingCode: enabled = false }
    // Menu selection does not change the canonical card order (V2); its caller
    // uses this same list to select the requested account for each menu product.
    _ = menu
    for product in ["claude", "codex"] {
        var own = product == "claude" ? local.0 : local.1
        own.source = nil
        let localId = localIds[product]
        let localLabel = localId.flatMap { accountLabel(product: product, localId: $0, gistId: remote.gistId ?? "") }
        var groups: [String: [RemoteAccount]] = [:]
        if enabled {
            for a in remote.accounts ?? [] where a.product == product {
                guard let label = RemoteLimitsWire.label(a.label), !hidden.contains(label) else { continue }
                groups[label, default: []].append(a)
            }
        }
        var labels = Set(groups.keys)
        if own.present, let label = localLabel, !hidden.contains(label) { labels.insert(label) }

        func make(_ label: String?, accounts: [RemoteAccount], isLocal: Bool) -> AccountView {
            let ordered = accounts.sorted { $0.machineId < $1.machineId }
            let snapshots = ordered.filter { $0.asOf != nil && ($0.windows?.session != nil || $0.windows?.weekly != nil || !($0.models ?? []).isEmpty) }
            // A bad remote clock cannot defeat a correctly dated source (N10),
            // but a future-only account is still visible with its original asOf.
            let normal = snapshots.filter { $0.asOf! <= now.addingTimeInterval(300) }
            let localNormal = isLocal && own.asOf.map { $0 <= now.addingTimeInterval(300) } == true
            let candidates = normal.isEmpty && !localNormal ? snapshots : normal
            var best: RemoteAccount? = nil
            for a in candidates {
                if best == nil || a.asOf! > best!.asOf! { best = a }
            }
            var values = isLocal ? own : LimitData(present: true)
            var chosen: RemoteAccount? = nil
            if let best = best {
                let remoteNormal = best.asOf! <= now.addingTimeInterval(300)
                let takeRemote = !isLocal || own.asOf == nil || (remoteNormal && !localNormal)
                    || (remoteNormal == localNormal && best.asOf! > own.asOf!)
                if takeRemote {
                    chosen = best
                    values = RemoteLimitsWire.limitData(best)
                }
            }
            // Status is the newest attempt, separate from the winning values.
            let normallyDated = ordered.filter { ($0.attemptAt ?? $0.asOf).map { $0 <= now.addingTimeInterval(300) } ?? true }
            let statuses = normallyDated.isEmpty ? ordered : normallyDated
            var latest: RemoteAccount? = nil
            for a in statuses {
                let time = a.attemptAt ?? a.asOf ?? .distantPast
                if latest == nil || time > (latest!.attemptAt ?? latest!.asOf ?? .distantPast) { latest = a }
            }
            let sourceRecord = chosen ?? (!isLocal ? latest : nil)
            if let snapshot = sourceRecord {
                values.source = RemoteLimitsWire.source(snapshot, status: latest ?? snapshot, now: now)
            }
            var usage: RemoteDays = [:]
            for a in ordered { RemoteLimitsWire.add(a.days, to: &usage) }
            let names = Set(ordered.map { $0.machineName })
            let machines = (isLocal ? ["mac"] : []) + names.sorted().filter { !isLocal || $0 != "mac" }
            let historyKey: String
            if isLocal, let id = localId {
                let normalized = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                historyKey = "l:" + SHA256.hash(data: Data((product + "|" + normalized).utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
            } else { historyKey = label ?? "l:legacy" }
            let state: RemoteCardState
            if let source = values.source {
                state = RemoteLimitsWire.state(source, sync: sync, now: now)
            } else { state = .fresh }
            let tier = chosen?.tier ?? (!isLocal ? latest?.tier : nil)
            return AccountView(product: product, label: label, historyKey: historyKey,
                caption: label.flatMap { remote.captions?[$0]?.text }
                    ?? RemoteLimitsWire.caption(product: product, plan: values.plan, tier: tier, machines: machines),
                data: values, isLocal: isLocal, tier: tier,
                usageDays: usage, machines: machines, state: state)
        }
        if own.present && (localLabel == nil || !hidden.contains(localLabel!)) {
            views.append(make(localLabel, accounts: localLabel.flatMap { groups[$0] } ?? [], isLocal: true))
        }
        for label in labels.sorted() where !(own.present && label == localLabel) {
            views.append(make(label, accounts: groups[label] ?? [], isLocal: false))
        }
    }
    return views.sorted {
        if $0.product != $1.product { return $0.product == "claude" }
        if $0.isLocal != $1.isLocal { return $0.isLocal }
        let order = $0.caption.localizedCaseInsensitiveCompare($1.caption)
        if order != .orderedSame { return order == .orderedAscending }
        return ($0.label ?? "") < ($1.label ?? "")
    }
}

private extension RemoteLimitsWire {
    static func caption(product: String, plan: String?, tier: String?, machines: [String]) -> String {
        let name = product == "claude" ? "Claude" : "Codex"
        let planName: String
        if tier?.contains("20x") == true { planName = "Max 20x" }
        else if tier?.contains("5x") == true { planName = "Max 5x" }
        else { planName = plan?.capitalized ?? "" }
        let head = planName.isEmpty ? name : name + " " + planName
        let tags = machines.prefix(2).joined(separator: ", ") + (machines.count > 2 ? " +\(machines.count - 2)" : "")
        return tags.isEmpty ? head : head + " · " + tags
    }

    static func limitData(_ account: RemoteAccount) -> LimitData {
        var data = LimitData()
        data.session = account.windows?.session?.pct; data.sessionReset = account.windows?.session?.resetAt
        data.weekly = account.windows?.weekly?.pct; data.weeklyReset = account.windows?.weekly?.resetAt
        if let model = account.models?.max(by: { $0.pct < $1.pct }) {
            data.scoped = ScopedLimit(name: model.name, percent: model.pct, reset: model.resetAt, severity: nil)
        }
        data.plan = account.plan; data.resetCredits = account.resetCredits; data.asOf = account.asOf
        data.apiFresh = false; data.fromCache = true
        return data
    }

    static func source(_ snapshot: RemoteAccount, status: RemoteAccount, now: Date) -> RemoteSource {
        let next = snapshot.schedule?.nextAt ?? snapshot.asOf.map { $0.addingTimeInterval(Double(snapshot.schedule?.interval ?? 900)) }
        var result = RemoteSource(machineId: snapshot.machineId, machineName: snapshot.machineName)
        result.asOf = snapshot.asOf; result.attemptAt = status.attemptAt; result.nextAt = snapshot.schedule?.nextAt
        result.interval = snapshot.schedule?.interval; result.mode = snapshot.schedule?.mode; result.status = status.status
        result.retryUntil = status.retryUntil; result.lastSeenAt = status.machineLastSeenAt
        result.freshUntil = next.map { $0.addingTimeInterval(1200) }
        result.statusMachineId = status.machineId; result.statusMachineName = status.machineName
        result.expiredReason = status.expiredReason; result.backoff = snapshot.schedule?.backoff
        result.futureAsOf = snapshot.asOf.map { $0 > now.addingTimeInterval(300) } ?? false
        return result
    }

    static func state(_ source: RemoteSource, sync: ReaderSyncState, now: Date) -> RemoteCardState {
        switch sync.phase { case .off, .revoked, .awaitingCode: return .signedOut; case .on: break }
        if sync.warning != nil { return .syncStalled }
        if let last = source.lastSeenAt, last < now.addingTimeInterval(-1800) { return .offline }
        if ["expired", "signed_out"].contains(source.status) { return .signInRequired }
        if let retry = source.retryUntil, retry > now { return .serviceWait }
        if let freshUntil = source.freshUntil, now > freshUntil { return .stale }
        if source.asOf == nil { return .stale }
        return .fresh
    }
}
