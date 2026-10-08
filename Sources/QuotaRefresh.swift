import Foundation

/// Authentication state of the provider, independent of snapshot freshness.
///   • ok            — signed in, data is (or can be) live
///   • loggedOut     — no Claude Code CLI login: keychain item absent, or present
///                     but without a `claudeAiOauth` block (e.g. only the desktop app
///                     is signed in). Recoverable by signing into the CLI.
///   • expired       — a saved CLI login whose token expired and could not be refreshed.
///   • keychainError — a genuine keychain read failure (errSec other than 0 / 44).
enum AuthState { case ok, loggedOut, expired, keychainError }

/// A weekly limit scoped to one model (Anthropic's `limits[].kind == "weekly_scoped"`),
/// e.g. Fable's own 7-day allowance, which can run out while the overall weekly still has
/// room. `name` is the backend's own `scope.model.display_name`, so a future model shows up
/// correctly without a code change.
struct ScopedLimit {
    var name: String
    var percent: Double
    var reset: Date?
    var severity: String?      // backend's own "normal" | "warning" | "critical"
}

struct LimitData {
    var session: Double?
    var weekly: Double?
    var sessionReset: Date?
    var weeklyReset: Date?
    var scoped: ScopedLimit?   // Claude: the binding per-model weekly limit, when the API reports one
    var plan: String?
    var resetCredits: Int?     // Codex "reset banking" — banked rate-limit resets available
    var asOf: Date?
    var error: String?
    var stale = false
    var fromCache = false
    var apiFresh = false      // true only for a successful live usage response
    var present = true         // false → product not set up on this Mac (hide its row/card)
    // Transient presentation state of the last request, never serialized with a snapshot.
    var pollFailed = false
    var nextPollAt: Date?
    var serverRetryAt: Double?
    var refreshInFlight = false
    var localRetryAt: Double = 0
    var credentialIssue: QuotaCredentialIssue?
    var permissionRequestInFlight = false
    var auth: AuthState = .ok  // Confirmed provider auth/storage state, never inferred from snapshot age.
}

/// Snapshot fields and their original asOf travel together; failures/auth belong to this attempt.
func quotaFallback(_ result: LimitData, previous: LimitData) -> LimitData {
    guard !result.apiFresh else { return result }
    var merged = previous
    merged.present = true; merged.apiFresh = false; merged.fromCache = true
    merged.error = result.error; merged.auth = result.auth; merged.serverRetryAt = result.serverRetryAt
    merged.credentialIssue = result.credentialIssue
    merged.permissionRequestInFlight = result.permissionRequestInFlight
    merged.pollFailed = true
    return merged
}


// Pure scheduling seam: callers supply the clock, schedule and result. No I/O or globals.
enum QuotaRefreshIntent { case manual, scheduled }
enum QuotaRefreshAdmission: Equatable {
    case start(UInt64), disabled, inFlight, localWait(until: Double), serverWait(until: Double), notDue
}
struct QuotaRefreshTicket: Equatable {
    let serial: UInt64
    let generation: UInt64
}
struct QuotaRefreshState {
    private(set) var enabled = true
    private(set) var generation: UInt64 = 0
    private(set) var serial: UInt64 = 0
    private(set) var flight: QuotaRefreshTicket?
    private(set) var localUntil: Double = 0
    var serverUntil: Double?

    init(lastAttempt: Double = 0, serverUntil: Double? = nil) {
        localUntil = lastAttempt > 0 ? lastAttempt + 30 : 0
        self.serverUntil = serverUntil.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }
    mutating func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value; generation &+= 1
        // Keep the old flight reserved until its worker finishes, even across re-enable.
    }
    func nextAttempt(schedule: Double) -> Double {
        max(localUntil, serverUntil ?? schedule)
    }
    mutating func admit(_ intent: QuotaRefreshIntent, now: Double, scheduledAt: Double) -> QuotaRefreshAdmission {
        guard enabled else { return .disabled }
        guard flight == nil else { return .inFlight }
        if let deadline = serverUntil, now < deadline { return .serverWait(until: deadline) }
        if now < localUntil { return .localWait(until: localUntil) }
        if intent == .scheduled, now < nextAttempt(schedule: scheduledAt) { return .notDue }
        serial &+= 1
        flight = QuotaRefreshTicket(serial: serial, generation: generation)
        localUntil = now + 30
        return .start(serial)
    }
    // Returns false for obsolete selections; still retires precisely that worker's flight.
    mutating func complete(_ ticket: QuotaRefreshTicket, retryAfter: Double?) -> Bool {
        guard flight == ticket else { return false }
        flight = nil
        let deadline = retryAfter.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        guard enabled, ticket.generation == generation else {
            // Selection invalidates presentation, not a server restriction on this provider.
            if let deadline = deadline { serverUntil = max(serverUntil ?? 0, deadline) }
            return false
        }
        serverUntil = deadline
        return true
    }
}

/// HTTP Retry-After is a server deadline, never a fabricated local backoff. No one-hour cap.
func quotaRetryAfter(_ raw: String?, now: Double) -> Double? {
    guard now.isFinite, let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
    if raw.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let seconds = Double(raw), seconds.isFinite {
        let deadline = now + seconds
        return deadline.isFinite ? deadline : nil
    }
    let parser = DateFormatter()
    parser.locale = Locale(identifier: "en_US_POSIX")
    parser.timeZone = TimeZone(secondsFromGMT: 0)
    parser.isLenient = false
    for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
        parser.dateFormat = format
        if let date = parser.date(from: raw) { return max(now, date.timeIntervalSince1970) }
    }
    return nil
}

struct QuotaHTTPFailure: Equatable {
    let status: Int
    let retryAt: Double?
    let authenticationRequired: Bool
    init(status: Int, headers: [String: String], now: Double, tokenEndpoint: Bool = false, oauthError: String? = nil) {
        self.status = status
        retryAt = quotaRetryAfter(headers.first { $0.key.lowercased() == "retry-after" }?.value, now: now)
        authenticationRequired = status == 401 || (tokenEndpoint && oauthError == "invalid_grant")
    }
}

// Pure feedback seam. A local guard is never described as a provider restriction.
enum QuotaRefreshAction: Equatable { case none, retry, restoreAccess, allowKeychain, cancelKeychain }
struct QuotaRefreshFeedback: Equatable {
    let status: String
    let action: QuotaRefreshAction
    let actionTitle: String
    let dataAt: Double?
    let nextAutomaticAt: Double?
}
func quotaCountdown(until: Double, now: Double, english: Bool) -> String {
    let seconds = max(0, until - now)
    guard seconds.isFinite, seconds < 86400 * 100000 else { return english ? "a long time" : "долгое время" }
    if seconds >= 86400 { return String(format: "%.0f", ceil(seconds / 86400)) + (english ? " d" : " д") }
    if seconds >= 3600 { return String(format: "%.0f", ceil(seconds / 3600)) + (english ? " h" : " ч") }
    if seconds >= 60 { return String(format: "%.0f", ceil(seconds / 60)) + (english ? " min" : " мин") }
    return String(format: "%.0f", ceil(seconds)) + (english ? " s" : " с")
}
func quotaRefreshFeedback(inFlight: Bool, serverUntil: Double?, localUntil: Double,
                          failed: Bool, authenticationRequired: Bool, dataAt: Double?,
                          nextAutomaticAt: Double?, now: Double, english: Bool,
                          credentialIssue: QuotaCredentialIssue? = nil, permissionPending: Bool = false) -> QuotaRefreshFeedback {
    func result(_ status: String, _ action: QuotaRefreshAction = .none, _ title: String = "") -> QuotaRefreshFeedback {
        QuotaRefreshFeedback(status: status, action: action, actionTitle: title, dataAt: dataAt, nextAutomaticAt: nextAutomaticAt)
    }
    if inFlight {
        return result(permissionPending ? (english ? "Waiting for Keychain permission…" : "Ожидаем разрешения Связки ключей…") : (english ? "Refreshing…" : "Обновляем…"),
                      permissionPending ? .cancelKeychain : .none, permissionPending ? (english ? "Cancel" : "Отменить") : "")
    }
    if credentialIssue == .readInteractionRequired {
        if now < localUntil {
            return result((english ? "Keychain permission needed · retry in " : "Нужно разрешение · повтор через ") + quotaCountdown(until: localUntil, now: now, english: english))
        }
        return result(english ? "Keychain read needs permission" : "Для чтения Связки ключей нужно разрешение", .allowKeychain,
                      english ? "Allow Keychain access" : "Разрешить доступ к Связке ключей")
    }
    if credentialIssue == .writeUnavailable {
        return result(english ? "Could not save renewed sign-in" : "Не удалось сохранить обновлённый вход", .restoreAccess,
                      english ? "Restore access" : "Восстановить доступ")
    }
    if let deadline = serverUntil, deadline > now {
        return result((english ? "Service allows retry in " : "Сервис разрешит повтор через ") + quotaCountdown(until: deadline, now: now, english: english),
                      authenticationRequired ? .restoreAccess : .none,
                      authenticationRequired ? (english ? "Restore access" : "Восстановить доступ") : "")
    }
    if authenticationRequired {
        return result(english ? "Access needs attention" : "Нужно восстановить доступ", .restoreAccess,
                      english ? "Restore access" : "Восстановить доступ")
    }
    let status = failed ? (english ? "Could not refresh" : "Не удалось обновить")
        : (dataAt == nil ? (english ? "No successful reading yet" : "Успешных ответов пока нет")
           : (english ? "Last reading received" : "Последний ответ получен"))
    if now < localUntil {
        return result(status, .none, (english ? "Retry in " : "Повтор через ") + quotaCountdown(until: localUntil, now: now, english: english))
    }
    return result(status, failed ? .retry : .none, failed ? (english ? "Retry" : "Повторить") : "")
}

// Only an explicit read-permission action can create this one-shot, expiring permit.
// No process/Keychain calls here: the launch closure is injected by the adapter/tests.
final class QuotaKeychainReadPermit {
    private let lock = NSLock()
    private var cancelled = false
    private var admitted = false
    let expiresAt: Double
    init(now: Double) { expiresAt = now + 15 }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func admit(now: Double, launch: () throws -> Void) rethrows -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled, !admitted, now.isFinite, now < expiresAt else { return false }
        admitted = true; try launch(); return true
    }
}
enum QuotaCredentialIssue: Equatable {
    case readInteractionRequired, readUnavailable, readTimedOut, invalidCredentials, writeUnavailable, cancelled
}
struct ClaudeQuotaHelperRequest: Equatable {
    let operation: String
    let interactive: Bool
    static func parse(_ args: [String]) -> Self? {
        guard args.count == 4, args[1] == "--claude-quota-keychain-helper",
              ["read", "update"].contains(args[2]), ["quiet", "interactive"].contains(args[3]),
              args[2] == "read" || args[3] == "quiet" else { return nil }
        return Self(operation: args[2], interactive: args[3] == "interactive")
    }
}
func quotaHelperInteraction(_ request: ClaudeQuotaHelperRequest, setAllowed: (Bool) -> Bool,
                            operation: () -> Int32) -> Int32 {
    guard setAllowed(false) else { return 70 }
    if request.interactive { guard request.operation == "read", setAllowed(true) else { return 70 } }
    return operation()
}

/// Choose a fallback by readings first, then by known observation time. Missing timestamps
/// must never erase known values or be synthesized as now. The current attempt owns auth/error.
func quotaHasReadings(_ data: LimitData) -> Bool {
    data.session != nil || data.weekly != nil || data.scoped != nil || data.resetCredits != nil
}
func quotaSelectSnapshot(_ result: LimitData, previous: LimitData) -> LimitData {
    guard !result.apiFresh, quotaHasReadings(previous) else { return result }
    if !quotaHasReadings(result) { return quotaFallback(result, previous: previous) }
    switch (result.asOf, previous.asOf) {
    case (nil, .some): return quotaFallback(result, previous: previous)
    case let (.some(current), .some(old)) where old > current: return quotaFallback(result, previous: previous)
    default: return result
    }
}

struct ClaudeQuotaUpdate: Codable, Equatable {
    let expected: Data
    let replacement: Data
}
enum QuotaCredentialRead: Equatable {
    case credentials(Data), missing, failed(QuotaCredentialIssue)
}
struct QuotaPendingResolution: Equatable {
    let read: QuotaCredentialRead
    let retirePending: Bool
}
/// Credential identity excludes JSON serialization and unrelated CLI/MCP metadata.
struct QuotaClaudeCredentialIdentity: Equatable {
    let accessToken: String?
    let refreshToken: String?
}
func quotaClaudeCredentialIdentity(_ data: Data) -> QuotaClaudeCredentialIdentity? {
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let oauth = root["claudeAiOauth"] as? [String: Any] else { return nil }
    for key in ["accessToken", "refreshToken"] {
        if let value = oauth[key], !(value is String) { return nil }
    }
    let access = (oauth["accessToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    let refresh = (oauth["refreshToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    guard access != nil || refresh != nil else { return nil }
    return QuotaClaudeCredentialIdentity(accessToken: access, refreshToken: refresh)
}
/// Rebase only renewed credential fields onto the latest observed CLI record. The native
/// update compares exact CURRENT bytes, so concurrent changes still fail closed.
func quotaClaudeRebaseUpdate(_ pending: ClaudeQuotaUpdate, current: Data) -> ClaudeQuotaUpdate? {
    guard let oldIdentity = quotaClaudeCredentialIdentity(pending.expected),
          quotaClaudeCredentialIdentity(current) == oldIdentity,
          let newIdentity = quotaClaudeCredentialIdentity(pending.replacement), newIdentity.accessToken != nil,
          var root = (try? JSONSerialization.jsonObject(with: current)) as? [String: Any],
          var oauth = root["claudeAiOauth"] as? [String: Any],
          let renewed = (try? JSONSerialization.jsonObject(with: pending.replacement)) as? [String: Any],
          let renewedOAuth = renewed["claudeAiOauth"] as? [String: Any] else { return nil }
    for key in ["accessToken", "refreshToken", "expiresAt"] { oauth[key] = renewedOAuth[key] }
    root["claudeAiOauth"] = oauth
    guard let replacement = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]) else { return nil }
    return ClaudeQuotaUpdate(expected: current, replacement: replacement)
}
/// Production orchestration seam: read CURRENT credentials exactly once before any pending
/// write. The caller injects quiet/default or explicitly permitted reading; writes have no
/// interactive argument. Failures retain the candidate and preserve their read/write origin.
func quotaReconcilePendingCredential(_ pending: ClaudeQuotaUpdate?,
                                     read: () -> QuotaCredentialRead,
                                     quietUpdate: (ClaudeQuotaUpdate) -> Bool,
                                     cancelled: () -> Bool = { false }) -> QuotaPendingResolution {
    func retained(_ value: QuotaCredentialRead) -> QuotaPendingResolution {
        QuotaPendingResolution(read: value, retirePending: false)
    }
    guard !cancelled() else { return retained(.failed(.cancelled)) }
    let current = read()
    guard !cancelled() else { return retained(.failed(.cancelled)) }
    guard let pending = pending, case .credentials(let data) = current else { return retained(current) }
    guard let currentIdentity = quotaClaudeCredentialIdentity(data),
          let oldIdentity = quotaClaudeCredentialIdentity(pending.expected),
          let newIdentity = quotaClaudeCredentialIdentity(pending.replacement) else {
        return retained(.failed(.invalidCredentials))
    }
    if currentIdentity == newIdentity {
        return QuotaPendingResolution(read: current, retirePending: true)
    }
    if currentIdentity != oldIdentity {
        // A distinct usable pair proves a different CLI login. Metadata alone does not.
        guard currentIdentity.accessToken != nil else { return retained(.failed(.invalidCredentials)) }
        return QuotaPendingResolution(read: current, retirePending: true)
    }
    guard let rebased = quotaClaudeRebaseUpdate(pending, current: data) else { return retained(.failed(.invalidCredentials)) }
    guard !cancelled() else { return retained(.failed(.cancelled)) }
    guard quietUpdate(rebased) else { return retained(.failed(.writeUnavailable)) }
    return QuotaPendingResolution(read: .credentials(rebased.replacement), retirePending: true)
}
