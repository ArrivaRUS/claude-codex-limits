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

func accountLabelKey(gistId: String) -> String? {
    guard !gistId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return SHA256.hash(data: Data(("ccl-label-key-v1|" + gistId).utf8))
        .map { String(format: "%02x", $0) }.joined()
}

func accountLabel(product: String, localId: String, gistId: String) -> String? {
    guard let key = accountLabelKey(gistId: gistId) else { return nil }
    return accountLabel(product: product, localId: localId, labelKey: key)
}

// A persisted cache needs only this derived key, never the gist identity itself.
func accountLabel(product: String, localId: String, labelKey: String) -> String? {
    guard ["claude", "codex"].contains(product), labelKey.utf8.count == 64,
          labelKey.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
    let id = localId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard (8...64).contains(id.utf8.count), id.utf8.allSatisfy({
        (48...57).contains($0) || (97...122).contains($0) || $0 == 45
    }) else { return nil }
    let hex = Array(labelKey.utf8)
    func nibble(_ byte: UInt8) -> UInt8 { byte <= 57 ? byte - 48 : byte - 87 }
    var key = Data()
    for i in stride(from: 0, to: hex.count, by: 2) { key.append(nibble(hex[i]) * 16 + nibble(hex[i + 1])) }
    let message = Data(("ccl-account-v1|" + product + "|" + id).utf8)
    let digest = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key))
    return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
}

func machineTag(setting: String, hostname: String) -> String {
    let raw = setting.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? String(hostname.split(separator: ".", omittingEmptySubsequences: false).first ?? "") : setting
    // Writer sanitization differs deliberately from the reader's whole-field rejection.
    let clean = String(String.UnicodeScalarView(raw.unicodeScalars.filter { !RemoteLimitsWire.isUnsafe($0) }))
    let ascii = clean.decomposedStringWithCompatibilityMapping.unicodeScalars.filter { $0.value < 128 }
    let lower = String(String.UnicodeScalarView(ascii)).lowercased()
    let tag = lower.replacingOccurrences(of: "[^a-z0-9-]+", with: "-", options: .regularExpression)
        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    let short = String(tag.prefix(16)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    return short.isEmpty ? "mac" : short
}

private enum RemoteLimitsWire {
    static let counters = ["input", "output", "cacheRead", "cacheWrite5m", "cacheWrite1h", "turns"]

    // NSNumber may erase whether the sender wrote 1, 1.0 or 1e0. Before
    // Foundation parses the object, reject decimal/exponent tokens for fields
    // whose wire contract requires an integer. All other bytes stay unchanged.
    static func strictIntegerJSON(_ content: String) -> Data {
        let bytes = Array(content.utf8)
        let fields = Set(counters + ["schema", "resetCredits", "interval"])
        var i = 0, copied = 0
        var integerValue = false
        var result = Data()
        func whitespace(_ byte: UInt8) -> Bool { byte == 32 || byte == 9 || byte == 10 || byte == 13 }
        func delimiter(_ byte: UInt8) -> Bool {
            switch byte {
            case 9, 10, 13, 32, 44, 58, 91, 93, 123, 125: return true
            default: return false
            }
        }
        while i < bytes.count {
            let byte = bytes[i]
            if byte == 34 { // Read a complete JSON string; an escaped quote is not its end.
                let start = i
                i += 1
                while i < bytes.count {
                    if bytes[i] == 92 { i = min(i + 2, bytes.count) }
                    else if bytes[i] == 34 { i += 1; break }
                    else { i += 1 }
                }
                var next = i
                while next < bytes.count && whitespace(bytes[next]) { next += 1 }
                integerValue = false
                if next < bytes.count, bytes[next] == 58 {
                    // Decode escapes in property names exactly as the object parser does.
                    let key = (try? JSONSerialization.jsonObject(with: Data(bytes[start..<i]),
                                                                 options: [.fragmentsAllowed])) as? String
                    integerValue = key.map { fields.contains($0) } ?? false
                }
            } else if byte == 45 || (48...57).contains(byte) {
                let start = i
                while i < bytes.count && !delimiter(bytes[i]) { i += 1 }
                if integerValue && nonIntegerToken(bytes[start..<i]) {
                    result.append(contentsOf: bytes[copied..<start])
                    result.append(contentsOf: [110, 117, 108, 108]) // null is present, so counters do not default to zero.
                    copied = i
                }
                integerValue = false
            } else {
                if !whitespace(byte) && byte != 58 { integerValue = false }
                i += 1
            }
        }
        result.append(contentsOf: bytes[copied..<bytes.count])
        return result
    }

    // Only a complete, valid JSON number may be replaced. Replacing a malformed
    // token could otherwise turn invalid JSON into a valid, accepted document.
    static func nonIntegerToken(_ bytes: ArraySlice<UInt8>) -> Bool {
        var i = bytes.startIndex
        let end = bytes.endIndex
        func digit(_ byte: UInt8) -> Bool { (48...57).contains(byte) }
        if i < end && bytes[i] == 45 { i += 1 }
        guard i < end else { return false }
        if bytes[i] == 48 { i += 1 }
        else {
            guard (49...57).contains(bytes[i]) else { return false }
            while i < end && digit(bytes[i]) { i += 1 }
        }
        var nonInteger = false
        if i < end && bytes[i] == 46 {
            nonInteger = true; i += 1
            let start = i
            while i < end && digit(bytes[i]) { i += 1 }
            guard i > start else { return false }
        }
        if i < end && (bytes[i] == 69 || bytes[i] == 101) {
            nonInteger = true; i += 1
            if i < end && (bytes[i] == 43 || bytes[i] == 45) { i += 1 }
            let start = i
            while i < end && digit(bytes[i]) { i += 1 }
            guard i > start else { return false }
        }
        return i == end && nonInteger
    }

    static func isUnsafe(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .surrogate: return true
        default: return false
        }
    }

    static func text(_ value: Any?, limit: Int? = nil, nfc: Bool = false) -> String? {
        guard let value = value as? String,
              !value.unicodeScalars.contains(where: isUnsafe),
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

    // Usage and envelope fields have the same strict JSON-integer contract as v1.1.
    static func legacyInteger(_ value: Any?, maximum: Int) -> Int? {
        integer(value, maximum: maximum)
    }

    static func percent(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite, (0...100).contains(n.doubleValue) else { return nil }
        return n.doubleValue
    }

    // Account metadata and lastSeenAt reject controls before parsing (Linux _epoch).
    static func date(_ value: Any?) -> Date? {
        guard let safe = text(value, limit: 4096) else { return nil }
        return isoDate(safe)
    }

    /// The envelope's updated uses unrestricted ISO parsing (Linux parse_iso).
    /// Gregorian validation prevents Foundation from normalizing month 13.
    static func isoDate(_ value: Any?) -> Date? {
        guard let raw = value as? String else { return nil }
        let stripCharacters = CharacterSet(charactersIn:
            "\u{0009}\u{000A}\u{000B}\u{000C}\u{000D}\u{001C}\u{001D}\u{001E}\u{001F}\u{0020}\u{0085}\u{00A0}\u{1680}"
            + "\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}"
            + "\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}")
        let s = raw.trimmingCharacters(in: stripCharacters)
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
        // Dates retain their original ISO strings for the wire-size contract.
        let wire = metadata(a, original: v)
        guard let bytes = try? JSONSerialization.data(withJSONObject: wire, options: [.withoutEscapingSlashes]),
              bytes.count <= 4096 else { return nil }
        a.days = days(v["days"])
        return a
    }

    static func windowMetadata(_ value: Any?) -> [String: Any]? {
        guard let raw = value as? [String: Any], let clean = window(raw) else { return nil }
        var out: [String: Any] = ["pct": raw["pct"]!]
        if clean.resetAt != nil { out["resetAt"] = raw["resetAt"] }
        return out
    }

    // Recreate the allow-listed wire dictionary, including explicit nulls and
    // empty containers; Codable's Date representation is not the wire format.
    static func metadata(_ account: RemoteAccount, original: [String: Any]) -> [String: Any] {
        var out: [String: Any] = ["product": account.product, "status": account.status,
                                  "label": account.label.map { $0 as Any } ?? NSNull()]
        for (key, value) in [("plan", account.plan), ("tier", account.tier),
                             ("expiredReason", account.expiredReason), ("labelReason", account.labelReason),
                             ("attemptKind", account.attemptKind)] {
            if let value = value { out[key] = value }
        }
        for (key, value) in [("asOf", account.asOf), ("attemptAt", account.attemptAt), ("retryUntil", account.retryUntil)] {
            if value != nil { out[key] = original[key] }
        }
        if original["retryUntil"] is NSNull { out["retryUntil"] = NSNull() }
        if let raw = original["windows"] as? [String: Any] {
            var windows: [String: Any] = [:]
            for key in ["session", "weekly"] {
                if let clean = windowMetadata(raw[key]) { windows[key] = clean }
            }
            out["windows"] = windows
        }
        if let raw = original["models"] as? [Any] {
            out["models"] = raw.prefix(8).compactMap { value -> [String: Any]? in
                guard let model = value as? [String: Any], var clean = windowMetadata(model),
                      let name = text(model["name"], limit: 48, nfc: true) else { return nil }
                clean["name"] = name
                return clean
            }
        }
        if let credits = account.resetCredits { out["resetCredits"] = credits }
        if let schedule = account.schedule, let raw = original["schedule"] as? [String: Any] {
            var clean: [String: Any] = ["mode": schedule.mode, "interval": schedule.interval]
            if schedule.nextAt != nil { clean["nextAt"] = raw["nextAt"] }
            if let backoff = schedule.backoff { clean["backoff"] = backoff }
            out["schedule"] = clean
        }
        return out
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
              let obj = (try? JSONSerialization.jsonObject(with: RemoteLimitsWire.strictIntegerJSON(content))) as? [String: Any],
              RemoteLimitsWire.legacyInteger(obj["schema"], maximum: 1) == 1,
              let machine = obj["machine"] as? [String: Any], let id = RemoteLimitsWire.text(machine["id"]), !id.isEmpty,
              id != myId, !seen.contains(id), name == "machine-\(id).json" else { continue }
        let updated = RemoteLimitsWire.isoDate(obj["updated"])
        if obj["updated"] != nil && updated == nil { continue }
        if let updated = updated, updated < now.addingTimeInterval(-45 * 86400) { continue }
        seen.insert(id)
        let tag = String(String.UnicodeScalarView((RemoteLimitsWire.text(machine["name"]) ?? "").unicodeScalars.prefix(16)))
        let machineName = tag.isEmpty ? "?" : tag
        let os = RemoteLimitsWire.text(machine["os"], limit: 64) ?? ""
        let lastSeen = RemoteLimitsWire.date(obj["lastSeenAt"])
        let displayCeiling = now.addingTimeInterval(60)
        let displayUpdated = updated.flatMap { $0 <= displayCeiling ? $0 : nil }
        let displayLastSeen = lastSeen.flatMap { $0 <= displayCeiling ? $0 : nil }
        var cached = SyncCachedMachine(id: id, name: machineName, os: os, updated: displayUpdated)
        cached.lastSeenAt = displayLastSeen
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
            a.machineId = id; a.machineName = machineName
            a.machineLastSeenAt = displayLastSeen ?? displayUpdated
            if a.machineLastSeenAt == nil && (lastSeen != nil || updated != nil) {
                // Future provenance is not evidence that this machine is online.
                a.machineLastSeenAt = .distantPast
            }
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
                let setAt = RemoteLimitsWire.date(raw["setAt"])
                if let setAt = setAt, setAt > now.addingTimeInterval(60) { continue }
                let caption = RemoteCaption(text: text, setAt: setAt)
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
                     hidden: Set<String>, menu: [String: String], sync: ReaderSyncState, now: Date,
                     localMachineName: String = "mac") -> [AccountView] {
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
        let labelKey = remote.labelKey ?? remote.gistId.flatMap { accountLabelKey(gistId: $0) }
        let localLabel = localId.flatMap { id in
            labelKey.flatMap { accountLabel(product: product, localId: id, labelKey: $0) }
        }
        var groups: [String: [RemoteAccount]] = [:]
        if enabled {
            for var a in remote.accounts ?? [] where a.product == product {
                guard let label = RemoteLimitsWire.label(a.label), !hidden.contains(label) else { continue }
                if let last = a.machineLastSeenAt, last > now.addingTimeInterval(60) {
                    let updated = remote.machines.first { $0.id == a.machineId }?.updated
                    a.machineLastSeenAt = updated.flatMap { $0 <= now.addingTimeInterval(60) ? $0 : nil } ?? .distantPast
                }
                groups[label, default: []].append(a)
            }
        }
        // A logged-out fetch is a present UI placeholder, not a local account.
        // Keep the login prompt only when there is no remote account to display.
        let hasLocal = own.present && (own.auth != .loggedOut || localId != nil || groups.isEmpty)
        var labels = Set(groups.keys)
        if hasLocal, let label = localLabel, !hidden.contains(label) { labels.insert(label) }

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
                    values = RemoteLimitsWire.limitData(best, onto: values)
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
            let machines = (isLocal ? [localMachineName] : []) + names.sorted().filter { !isLocal || $0 != localMachineName }
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
                caption: label.flatMap { key -> String? in
                    guard enabled, let caption = remote.captions?[key],
                          caption.setAt.map({ $0 <= now.addingTimeInterval(60) }) ?? true else { return nil }
                    return caption.text
                }
                    ?? RemoteLimitsWire.caption(product: product, plan: values.plan, tier: tier, machines: machines),
                data: values, isLocal: isLocal, tier: tier,
                usageDays: usage, machines: machines, state: state)
        }
        if hasLocal && (localLabel == nil || !hidden.contains(localLabel!)) {
            views.append(make(localLabel, accounts: localLabel.flatMap { groups[$0] } ?? [], isLocal: true))
        }
        for label in labels.sorted() where !(hasLocal && label == localLabel) {
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

    static func limitData(_ account: RemoteAccount, onto original: LimitData) -> LimitData {
        var data = original
        data.session = account.windows?.session?.pct; data.sessionReset = account.windows?.session?.resetAt
        data.weekly = account.windows?.weekly?.pct; data.weeklyReset = account.windows?.weekly?.resetAt
        data.scoped = nil
        if let model = account.models?.max(by: { $0.pct < $1.pct }) {
            data.scoped = ScopedLimit(name: model.name, percent: model.pct, reset: model.resetAt, severity: nil)
        }
        data.plan = account.plan; data.resetCredits = account.resetCredits; data.asOf = account.asOf
        data.apiFresh = false; data.fromCache = true
        return data
    }

    static func source(_ snapshot: RemoteAccount, status: RemoteAccount, now: Date) -> RemoteSource {
        let interval = Double(snapshot.schedule?.interval ?? 900)
        let nextAt = snapshot.schedule?.nextAt.flatMap { $0 <= now.addingTimeInterval(interval + 60) ? $0 : nil }
        let next = nextAt ?? snapshot.asOf.map { $0.addingTimeInterval(interval) }
        var result = RemoteSource(machineId: snapshot.machineId, machineName: snapshot.machineName)
        result.asOf = snapshot.asOf; result.attemptAt = status.attemptAt; result.nextAt = nextAt
        result.interval = snapshot.schedule?.interval; result.mode = snapshot.schedule?.mode; result.status = status.status
        let attempt = (status.attemptAt ?? status.asOf).flatMap { $0 <= now.addingTimeInterval(60) ? $0 : nil }
        let retryCeiling = attempt.map { $0.addingTimeInterval(86400) }
        if let retry = status.retryUntil {
            if let ceiling = retryCeiling {
                result.retryUntil = min(retry, ceiling)
            } else if retry <= now.addingTimeInterval(60) {
                result.retryUntil = retry
            }
        }
        result.lastSeenAt = status.machineLastSeenAt
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

// MARK: - Account settings, history import and money (C2)

func hiddenAccounts(defaults: UserDefaults = .standard) -> Set<String> {
    Set(defaults.object(forKey: "hiddenAccounts") as? [String] ?? [])
}

func menuAccountSelection(defaults: UserDefaults = .standard) -> [String: String] {
    defaults.object(forKey: "menuAccount") as? [String: String] ?? [:]
}

func menuAccount(_ product: String, views: [AccountView], selected: [String: String]) -> AccountView? {
    let accounts = views.filter { $0.product == product }
    if let label = selected[product], let chosen = accounts.first(where: { $0.label == label }) { return chosen }
    return accounts.first(where: { $0.isLocal }) ?? accounts.first
}

func accountUsageIndex(_ view: AccountView, local: UsageIndex) -> UsageIndex {
    var index = UsageIndex()
    index.days[view.product] = view.usageDays
    if view.isLocal {
        for (day, models) in local.days[view.product] ?? [:] {
            for (model, usage) in models { index.add(view.product, day, model, usage) }
        }
    }
    return index
}

func moneySummary(_ view: AccountView, local: UsageIndex, days: Int = 35, now: Date) -> MoneySummary {
    let rows = dailyUsage(view.product, days: days, index: accountUsageIndex(view, local: local), now: now)
    let active = rows.filter { $0.turns > 0 }
    let total = rows.reduce(0) { $0 + $1.usd }
    let price = subscriptionUSD(view.product, plan: view.data.plan, tier: view.tier, isLocal: view.isLocal)
    return MoneySummary(days: days, activeDays: active.count, usdApi: total,
                        perCalendarDay: days > 0 ? total / Double(days) : 0,
                        perActiveDay: active.isEmpty ? 0 : total / Double(active.count),
                        subMonthly: price.usd, subEstimated: price.estimated)
}

func readerCardStateEvents(_ views: [AccountView], now: Date) -> [[String: Any]] {
    let iso = ISO8601DateFormatter()
    iso.timeZone = TimeZone(secondsFromGMT: 0)
    return views.map { view in
        let age: Any
        if let asOf = view.data.asOf {
            let elapsed = now.timeIntervalSince(asOf)
            let seconds = max(0, elapsed.rounded(.down))
            if elapsed.isFinite && seconds < Double(Int.max) { age = Int(seconds) }
            else { age = NSNull() }
        } else { age = NSNull() }
        let label: Any
        if let valid = RemoteLimitsWire.label(view.label) { label = valid } else { label = NSNull() }
        return ["ev": "reader_card_state", "ts": iso.string(from: now), "product": view.product,
                "label": label, "state": view.state.rawValue, "age": age]
    }
}

func readerDidSync(_ cache: SyncRemoteCache, at now: Date, local: (LimitData, LimitData), localIds: [String: String],
                   hidden: Set<String>, sync: ReaderSyncState, history: UsageHistory, pollLog: String) {
    for account in cache.accounts ?? [] {
        guard let label = RemoteLimitsWire.label(account.label), let asOf = account.asOf,
              asOf.timeIntervalSince1970.isFinite, asOf <= now.addingTimeInterval(300),
              asOf >= now.addingTimeInterval(-HISTORY_KEEP_DAYS * 86400),
              account.windows?.session != nil || account.windows?.weekly != nil || !(account.models ?? []).isEmpty else { continue }
        let scoped = account.models?.max { $0.pct < $1.pct }
        history.recordRemote(product: account.product, label: label,
            UsageSample(t: asOf.timeIntervalSince1970, product: account.product, session: account.windows?.session?.pct,
                        weekly: account.windows?.weekly?.pct, scoped: scoped?.pct, scopedName: scoped?.name,
                        sessionReset: account.windows?.session?.resetAt?.timeIntervalSince1970,
                        weeklyReset: account.windows?.weekly?.resetAt?.timeIntervalSince1970, acct: label))
    }
    let views = resolveAccounts(local: local, localIds: localIds, remote: cache, hidden: hidden, menu: [:], sync: sync, now: now)
    appendPollLog(readerCardStateEvents(views, now: now), path: pollLog)
}

// MARK: - Remote card presentation (C3)
// No preferences, credentials, runtime clocks or renderer calls in this model.
enum RemoteManualPhase {
    case idle, reading, checked(Date), cooldown(Int), failed, pollAllowed(Date)
}
// The caller owns this controller on one serial executor (main in production).
// Both the clock and the read are injected; it cannot call a quota provider.
final class RemoteManualRefreshController {
    private let clock: () -> Date
    private let read: (@escaping (Bool) -> Void) -> Void
    private let onChange: () -> Void
    private var flight: UUID?
    private var startedAt: Date?
    private var result: RemoteManualPhase = .idle
    private var showCooldown = false

    init(clock: @escaping () -> Date, read: @escaping (@escaping (Bool) -> Void) -> Void,
         onChange: @escaping () -> Void = {}) {
        self.clock = clock; self.read = read; self.onChange = onChange
    }
    func phase(now: Date) -> RemoteManualPhase {
        if showCooldown, let at = startedAt {
            let remaining = 30 - now.timeIntervalSince(at)
            if remaining > 0 { return .cooldown(Int(ceil(min(30, remaining)))) }
        }
        if flight != nil { return .reading }
        if case .checked(let at) = result, !(0..<60).contains(now.timeIntervalSince(at)) { return .idle }
        return result
    }
    @discardableResult func request() -> Bool {
        let now = clock()
        if let at = startedAt, now.timeIntervalSince(at) < 30 {
            showCooldown = true; onChange(); return false
        }
        guard flight == nil else { onChange(); return false }
        let id = UUID()
        flight = id; startedAt = now; showCooldown = false; result = .idle
        onChange()
        read { [weak self] success in
            guard let self = self, self.flight == id else { return }
            self.flight = nil; self.showCooldown = false
            self.result = success ? .checked(self.clock()) : .failed
            self.onChange()
        }
        return true
    }
}

func remoteManualProviderProducts(views: [AccountView], localIds: [String: String], enabled: Set<String>) -> Set<String> {
    Set(enabled.filter { product in
        localIds[product] != nil || !views.contains { $0.product == product && !$0.isLocal }
    })
}

struct RemoteCardPresentation {
    var simpleTitle: String, advancedTitle: String, planBadge: String, machineSuffix: String
    var sourceLine: String, statusLine: String, statusTone: String, advancedBadge: String
    var action: String?
    var tooltip: String, accessibilityLabel: String, accessibilityValue: String, cardHit: String
    var paceNotice: String?
    var sessionResetText: String
    var sessionDimmed: Bool, showsValues: Bool
}
struct RemoteAutoFooter {
    var products: [String]
    var noSubscriptions: Bool
    var tooltip: String
}

// One immutable scene feeds the card draw, Auto, accessibility and display event.
// Visibility never alters the polling set; the current two-slot projection is
// explicit so logging describes exactly the cards part A can display.
struct RemoteAccountFrame {
    let now: Date
    let sync: ReaderSyncState
    let allViews: [AccountView]
    let visibleViews: [AccountView]
    let displayedViews: [AccountView]
}
func remoteAccountFrame(local: (LimitData, LimitData), localIds: [String: String], remote: SyncRemoteCache,
                        hidden: Set<String>, menu: [String: String], sync: ReaderSyncState, now: Date,
                        localMachineName: String = "mac") -> RemoteAccountFrame {
    let all = resolveAccounts(local: local, localIds: localIds, remote: remote, hidden: [], menu: menu,
                              sync: sync, now: now, localMachineName: localMachineName)
    let visible = all.filter { view in view.label.map { !hidden.contains($0) } ?? true }
    let displayed = ["claude", "codex"].compactMap { menuAccount($0, views: visible, selected: menu) }
    return RemoteAccountFrame(now: now, sync: sync, allViews: all, visibleViews: visible, displayedViews: displayed)
}

private func remoteManualIsActive(_ phase: RemoteManualPhase, now: Date) -> Bool {
    switch phase {
    case .idle: return false
    case .checked(let at): return (0..<60).contains(now.timeIntervalSince(at))
    default: return true
    }
}

func remoteCardActionURL(product: String) -> String {
    product == "claude" ? "https://claude.ai/settings/usage" : "https://chatgpt.com/codex/cloud/settings/analytics#usage"
}
func limitCanFix(remote view: AccountView) -> Bool {
    view.isLocal && limitCanFix(product: view.product, auth: view.data.auth)
}
func snapshotHorizon(_ d: LimitData) -> TimeInterval {
    guard let source = d.source else { return SNAPSHOT_MAX_AGE }
    if let end = source.freshUntil, let at = d.asOf ?? source.asOf,
       end.timeIntervalSince1970.isFinite, at.timeIntervalSince1970.isFinite {
        return max(0, end.timeIntervalSince(at))
    }
    return Double(max(0, source.interval ?? 900)) + 1200
}
func remotePaceTimeValid(_ d: LimitData, now: Date) -> Bool {
    guard let at = d.asOf, at.timeIntervalSince1970.isFinite else { return false }
    return at <= now.addingTimeInterval(d.source == nil ? 0 : 300)
}
func remoteCardTimestamp(_ date: Date?, now: Date, timeZone: TimeZone) -> String {
    guard let date = date, date.timeIntervalSince1970.isFinite,
          (0..<253402300800).contains(date.timeIntervalSince1970) else { return "—" }
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = timeZone
    f.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "HH:mm" : "dd.MM HH:mm"
    return f.string(from: date)
}
private func remoteDisplayText(_ text: String, limit: Int) -> String {
    let scalars = text.precomposedStringWithCanonicalMapping.unicodeScalars.filter { !RemoteLimitsWire.isUnsafe($0) }
    return String(String.UnicodeScalarView(scalars.prefix(limit)))
}
private func remoteStatusMachine(_ view: AccountView) -> String {
    remoteDisplayText(view.data.source?.statusMachineName ?? view.data.source?.machineName ?? view.machines.first ?? "?", limit: 16)
}
func remoteCardLine2(_ view: AccountView, state: RemoteCardState, phase: RemoteManualPhase,
                     lang: String, wide: Bool, now: Date, timeZone: TimeZone) -> String {
    let en = lang == "en", source = view.data.source
    func t(_ ru: String, _ english: String) -> String { en ? english : ru }
    func time(_ date: Date?) -> String { remoteCardTimestamp(date, now: now, timeZone: timeZone) }
    switch phase {
    case .reading: return t("Читаем GitHub…", "Reading GitHub…")
    case .checked(let at):
        if (0..<60).contains(now.timeIntervalSince(at)) { return t("GitHub проверен ", "GitHub checked ") + time(at) }
    case .cooldown(let seconds): return t("Повтор через \(max(0, seconds)) с", "Retry in \(max(0, seconds)) s")
    case .failed: return t("GitHub не ответил", "GitHub didn't respond")
    case .pollAllowed(let at): return t("Опрос можно с ", "Poll allowed at ") + time(at)
    case .idle: break
    }
    let machine = remoteStatusMachine(view), product = view.product == "claude" ? "Claude Code" : "Codex"
    switch state {
    case .fresh: return ""
    case .stale: return t("Данные устарели", "Data is stale")
    case .signInRequired:
        if source?.status == "signed_out" {
            return wide ? t("На машине \(machine) нет входа в \(product)", "\(product) isn't signed in on \(machine)")
                : t("На \(machine) нет входа", "Not signed in on \(machine)")
        }
        return wide ? t("На машине \(machine) нужно обновить вход \(product)", "\(product) sign-in needs renewing on \(machine)")
            : t("Обновите вход на \(machine)", "Renew sign-in on \(machine)")
    case .serviceWait:
        return source?.retryUntil.map { t("Пауза сервиса до ", "Service wait until ") + time($0) }
            ?? t("Пауза сервиса", "Service wait")
    case .offline:
        return wide ? t("Машина \(machine) не на связи с \(time(source?.lastSeenAt))", "\(machine) has been offline since \(time(source?.lastSeenAt))")
            : t("\(machine) не на связи с \(time(source?.lastSeenAt))", "\(machine) offline since \(time(source?.lastSeenAt))")
    case .syncStalled: return t("Синхронизация стоит ›", "Sync stalled ›")
    case .signedOut: return t("Войдите в GitHub ›", "Sign in to GitHub ›")
    }
}

func remoteCardSourceLine(_ view: AccountView, language: String, narrow: Bool, now: Date,
                          timeZone: TimeZone, compact: Bool = false, machineLimit: Int? = nil) -> String {
    guard view.state != .signedOut else { return "" }
    let en = language == "en"
    var machine = remoteDisplayText(view.data.source?.machineName ?? view.machines.first ?? "?", limit: 16)
    if let limit = machineLimit, machine.count > limit { machine = String(machine.prefix(limit)) + "…" }
    guard let at = view.data.asOf else { return (en ? "No data from " : "Нет данных с ") + machine }
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
    let short = compact || (narrow && !calendar.isDate(at, inSameDayAs: now))
    return (short ? (en ? "From " : "С ") : (en ? "Data from " : "Данные с ")) + machine
        + (en ? " at " : " от ") + remoteCardTimestamp(at, now: now, timeZone: timeZone)
}

func remoteCardPresentation(_ view: AccountView, sync: ReaderSyncState, language: String, narrow: Bool,
                            now: Date, timeZone: TimeZone, manual: RemoteManualPhase = .idle) -> RemoteCardPresentation {
    let en = language == "en", source = view.data.source, state = view.state
    func t(_ ru: String, _ english: String) -> String { en ? english : ru }
    func time(_ date: Date?) -> String { remoteCardTimestamp(date, now: now, timeZone: timeZone) }
    let product = view.product == "claude" ? "Claude Code" : "Codex"
    let machine = remoteDisplayText(source?.machineName ?? view.machines.first ?? "?", limit: 16)
    let statusMachine = remoteStatusMachine(view)
    let machines = view.machines.map { remoteDisplayText($0, limit: 16) }
    let tags = machines.prefix(2).joined(separator: ", ") + (machines.count > 2 ? " +\(machines.count - 2)" : "")
    let defaultCaption = RemoteLimitsWire.caption(product: view.product, plan: view.data.plan, tier: view.tier, machines: machines)
    let caption = remoteDisplayText(view.caption, limit: 128)
    let custom = !caption.isEmpty && caption != defaultCaption
    let plainLocal = view.isLocal && source == nil && machines.count <= 1
    let shortProduct = view.product == "claude" ? "Claude" : "Codex"
    let simple = custom ? caption : (plainLocal ? product : shortProduct + (tags.isEmpty ? "" : " · " + tags))
    let plan: String
    if view.tier?.contains("20x") == true { plan = "Max 20x" }
    else if view.tier?.contains("5x") == true { plan = "Max 5x" }
    else { plan = remoteDisplayText(view.data.plan?.capitalized ?? "", limit: 48) }
    let line1 = remoteCardSourceLine(view, language: language, narrow: narrow, now: now, timeZone: timeZone)
    // Once sync is stalled, its recovery action supersedes a previous failed click.
    let phase: RemoteManualPhase
    if case .failed = manual, state == .syncStalled || state == .signedOut { phase = .idle }
    else { phase = manual }
    var line2 = remoteCardLine2(view, state: state, phase: phase, lang: language, wide: !narrow, now: now, timeZone: timeZone)
    let activeManual = remoteManualIsActive(phase, now: now)
    if state == .signedOut, sync.phase == .revoked, !activeManual { line2 = t("Войдите в GitHub заново ›", "Sign in to GitHub again ›") }
    let tone: String, badge: String
    switch state {
    case .fresh: tone = "none"; badge = ""
    case .stale: tone = "textMid"; badge = t("устарело", "stale")
    case .signInRequired: tone = "amber"; badge = t("вход на ", "sign-in on ") + statusMachine
    case .serviceWait: tone = "amber"; badge = t("пауза", "wait")
    case .offline: tone = "amber"; badge = t("нет связи", "offline")
    case .syncStalled, .signedOut: tone = "ADV_LINK"; badge = t("нет синка", "no sync")
    }
    var lines: [String] = activeManual && !line2.isEmpty ? [line2] : []
    switch state {
    case .fresh: break
    case .stale: lines.append(t("\(statusMachine) на связи, но новых данных нет с \(time(view.data.asOf)).", "\(statusMachine) is online but has no newer data since \(time(view.data.asOf))."))
    case .signInRequired:
        if source?.status == "signed_out" {
            lines.append(t("На машине \(statusMachine) не выполнен вход в \(product). Войдите там. На этом Mac ничего делать не нужно.", "\(product) isn't signed in on \(statusMachine). Sign in there. Nothing to do on this Mac."))
        } else {
            lines.append(t("Вход \(product) истёк на машине \(statusMachine). Откройте \(product) на \(statusMachine) (CLI обновит вход сам) или войдите там заново. На этом Mac ничего делать не нужно.", "The \(product) sign-in expired on \(statusMachine). Open \(product) on \(statusMachine) (the CLI renews it itself) or sign in there again. Nothing to do on this Mac."))
        }
    case .serviceWait:
        if let until = source?.retryUntil {
            lines.append(t("Сервис попросил \(statusMachine) подождать до \(time(until)). До этого времени этот аккаунт не опрашивает ни один компьютер.", "The service asked \(statusMachine) to wait until \(time(until)). No computer polls this account before then."))
        } else { lines.append(t("Сервис попросил \(statusMachine) подождать.", "The service asked \(statusMachine) to wait.")) }
    case .offline: lines.append(t("Файл машины \(statusMachine) в GitHub не обновлялся с \(time(source?.lastSeenAt)).", "The \(statusMachine) file in GitHub hasn't been updated since \(time(source?.lastSeenAt))."))
    case .syncStalled: if let warning = sync.warning { lines.append(warning) }
    case .signedOut: lines.append(t("Аккаунты без входа на этом компьютере видны только через GitHub. Войдите в GitHub в настройках.", "Accounts not signed in on this computer are visible only via GitHub. Sign in to GitHub in Settings."))
    }
    if case .pollAllowed = manual {
        lines.append(t("Последний запрос по аккаунту — \(time(source?.attemptAt)) (\(statusMachine)). Не чаще раза в 15 минут со всех компьютеров; GitHub перечитан, сервис не опрашивали.", "Last request for this account: \(time(source?.attemptAt)) (\(statusMachine)). At most once per 15 minutes across all computers; GitHub re-read, provider not polled."))
    }
    if state != .signedOut {
        if view.data.asOf != nil { lines.append(t("Данные: ", "Data: ") + time(view.data.asOf) + " (\(machine))") }
        if let seconds = source?.interval {
            let duration = seconds % 3600 == 0 ? t("\(seconds / 3600) ч", "\(seconds / 3600) h") : t("\(seconds / 60) мин", "\(seconds / 60) min")
            let schedule = source?.mode == "auto" ? t("Авто · ", "Auto · ") + duration : t("каждые ", "every ") + duration
            lines.append(t("Расписание \(machine): ", "\(machine) schedule: ") + schedule + (source?.backoff == true ? t(", пауза после ошибки", ", paused after an error") : ""))
        }
        if let next = source?.nextAt { lines.append(t("Следующая попытка \(machine): ", "Next attempt on \(machine): ") + time(next)) }
        if let seen = source?.lastSeenAt { lines.append(t("\(statusMachine) на связи: ", "\(statusMachine) last seen: ") + time(seen)) }
        if [.offline, .syncStalled].contains(state) || source?.status == "error" {
            let last: String
            switch source?.status {
            case "expired", "signed_out": last = t("нужен вход \(product)", "\(product) sign-in needed")
            case "rate_limited": last = source?.retryUntil.map { t("пауза сервиса до ", "service wait until ") + time($0) } ?? t("пауза сервиса", "service wait")
            case "error": last = t("ошибка обновления", "update failed")
            default: last = ""
            }
            if !last.isEmpty { lines.append(t("Последний статус \(statusMachine): ", "Last \(statusMachine) status: ") + last) }
        }
        if remotePaceTimeValid(view.data, now: now) { lines.append(t("Темп и прогноз — от данных ", "Pace and forecast from data at ") + time(view.data.asOf)) }
        else if let at = view.data.asOf, at > now.addingTimeInterval(300) {
            lines.append(t("Время данных \(machine) в будущем — темп не считаем", "\(machine) data time is in the future — pace paused"))
        }
    }
    let tooltip = lines.filter { !$0.isEmpty }.joined(separator: "\n")
    let reset = view.data.sessionReset.map { $0 <= now ? t("окно сброшено", "window reset") : time($0) } ?? "—"
    return RemoteCardPresentation(simpleTitle: simple, advancedTitle: custom ? caption : product, planBadge: plan,
        machineSuffix: custom || plainLocal || tags.isEmpty ? "" : "· " + tags, sourceLine: line1,
        statusLine: line2, statusTone: line2.isEmpty ? "none" : (tone == "none" ? "textMid" : tone), advancedBadge: badge,
        action: state == .syncStalled || state == .signedOut ? "syncsettings" : nil,
        tooltip: tooltip, accessibilityLabel: caption, accessibilityValue: tooltip,
        cardHit: "open:" + remoteCardActionURL(product: view.product),
        paceNotice: remotePaceTimeValid(view.data, now: now) ? nil : t("Нет свежих данных · темп не считаем", "No fresh data · pace paused"),
        sessionResetText: reset, sessionDimmed: metricIsStale(view.data, metric: "session", now: now), showsValues: state != .signedOut)
}

func remoteAutoFooter(views: [AccountView], enabled: Set<String>, intervals: [String: TimeInterval], language: String) -> RemoteAutoFooter {
    let products = ["claude", "codex"].filter { product in
        enabled.contains(product) && views.contains { $0.product == product && $0.isLocal && $0.data.present && $0.data.auth != .loggedOut }
    }
    let en = language == "en"
    guard !products.isEmpty else {
        return RemoteAutoFooter(products: [], noSubscriptions: true, tooltip: en
            ? "This computer polls nothing. Accounts from other computers update on their own schedule, shown in the card tooltip."
            : "Этот компьютер ничего не опрашивает. Аккаунты с других компьютеров обновляются по их расписанию — оно в подсказке карточки.")
    }
    let rows = products.map { product -> String in
        let seconds = intervals[product] ?? 1800
        let duration = seconds >= 3600 ? "\(Int(seconds / 3600))" + (en ? " h" : " ч") : "\(Int(seconds / 60))" + (en ? " min" : " мин")
        return (product == "claude" ? "Claude Code" : "Codex") + " → " + duration
    }
    return RemoteAutoFooter(products: products, noSubscriptions: false, tooltip: (en ? "Auto: " : "Авто: ") + rows.joined(separator: "; "))
}

// Deterministic verdict for remote snapshots. The existing local formatter stays
// in LimitsMonitor.swift so its localized month/day wording does not change.
func advVerdict(_ row: AdvRow, data: LimitData, now: Date, language: String) -> String {
    let en = language == "en"
    func t(_ ru: String, _ english: String) -> String { en ? english : ru }
    func moment(_ at: Date) -> String { remoteCardTimestamp(at, now: now, timeZone: .current) }
    guard remotePaceTimeValid(data, now: now) else { return t("Нет свежих данных · темп не считаем", "No fresh data · pace paused") }
    func percent(_ value: Double) -> String { String(Int(value.rounded())) + "%" }
    if let at = data.asOf, now.timeIntervalSince(at) > snapshotHorizon(data) {
        return row.limit?.pace?.projectedPct.map { t("Прогноз на снимке: ", "Snapshot forecast: ") + percent($0) }
            ?? t("На снимке мало данных для темпа", "Not enough pace data in snapshot")
    }
    if row.kind == .stale {
        let reset = row.limit?.pace.map { $0.reset <= now } == true
        return data.asOf.map { t(reset ? "Окно сброшено · снимок " : "по данным на ", reset ? "Window reset · snapshot " : "as of ") + moment($0) }
            ?? t("Нет свежих данных · темп не считаем", "No fresh data · pace paused")
    }
    guard let p = row.limit?.pace else {
        return row.limit?.used != nil ? t("Нет времени окна · темп не считаем", "Window timing unknown · pace paused")
            : t("Окно не активно · откроется с первым запросом", "Window inactive · opens with the first request")
    }
    switch row.kind {
    case .exhausted: return t("Лимит исчерпан · сброс в ", "Limit reached · resets at ") + moment(p.reset)
    case .tooEarly: return t("Мало данных для темпа · сброс в ", "Not enough data for pace · resets at ") + moment(p.reset)
    default: break
    }
    if let at = p.runsOutAt {
        let minutes = max(0, Int(p.reset.timeIntervalSince(at) / 60))
        let span = minutes >= 60 ? t("\(minutes / 60) ч", "\(minutes / 60) h") : t("\(minutes) мин", "\(minutes) min")
        return t("Кончится в ", "Runs out at ") + moment(at) + t(", за ", ", ") + span + t(" до сброса", " before reset")
    }
    if let projected = p.projectedPct {
        return t(projected.rounded() >= 85 ? "Хватит впритык (прогноз " : "Хватит до сброса (прогноз ",
                 projected.rounded() >= 85 ? "Barely lasts (forecast " : "Lasts until reset (forecast ") + percent(projected) + ")"
    }
    return t("Хватит до сброса", "Lasts until reset")
}
