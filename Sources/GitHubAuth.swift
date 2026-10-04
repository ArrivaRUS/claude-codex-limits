import Foundation
import CoreFoundation

// Auth core has no production defaults, singleton, filesystem, network or Keychain I/O.
// All operations (including recovery) are serialized by the injected process lock.
struct GitHubAuthRef: Codable, Equatable, Hashable {
    var generation: String
    var backend: String = "keychain"
}
struct GitHubCredentialV2: Codable, Equatable {
    var schema: Int = 2
    var kind: String = "credential"
    var epoch: String
    var generation: String
    var accessToken: String?
    var refreshToken: String?
    var obtainedAt: Double
    var accessExpiresAt: Double?
    var refreshExpiresAt: Double?
    var tokenType: String = "bearer"
    var userID: String?
    var login: String?
}
struct GitHubAuthTransition: Codable, Equatable {
    var from: GitHubAuthRef?
    var to: GitHubAuthRef
    var phase: String
    var recoveryAttempts: Int = 0
    var kind: String = "refresh"
    var probe: GitHubAuthRef?
}
struct GitHubAuthManifest: Codable, Equatable {
    var formatVersion: Int = 2
    var epoch: String
    var active: GitHubAuthRef?
    var transition: GitHubAuthTransition?
    var cleanupRefs: [GitHubAuthRef] = []
    var retryAt: Double?
    var failureReason: String?
    var signedOut: Bool = false
    var failureCount: Int = 0
    var uncertainRefs: [GitHubAuthRef] = []
    var permitWriterRefs: [GitHubAuthRef]? = nil
    // Nonsecret, authoritative identity bound atomically to the active epoch/ref.
    var userID: String?
    var login: String?
}
enum GitHubAuthRead {
    case ready(GitHubCredentialV2), missing, locked, unreachable, timeout, corrupt, changed, signedOut, revoked
}
enum GitHubAuthStoreStatus: Equatable { case success, locked, unreachable, timeout, failed }
struct GitHubAuthAccess {
    let token: String
    let epoch: String
    let generation: String
    let refreshable: Bool
    var userID: String? = nil
}
enum GitHubAuthResult {
    case ready(GitHubAuthAccess), temporary(String), actionRequired(String), signedOut
}
struct GitHubAuthHTTP {
    var status: Int
    var json: [String: Any]?
    var headers: [String: String] = [:]
    var knownNotSent: Bool = false
}
enum GitHubAuthIdentity { case ready(userID: String, login: String), temporary, unauthorized }
struct GitHubAuthLogoutResult {
    var accessDisabled: Bool
    var cleanupPending: Bool
}
struct GitHubAuthSnapshot: Equatable {
    var state: String = "signedOut"
    var login: String?
    var reason: String?
    var retryAt: Double?
    var hasCredential: Bool = false
    var cleanupPending: Bool = false
    var epoch: String?
    var userID: String?
}
struct GitHubAuthDependencies {
    var clock: () -> Double
    var loadManifest: () throws -> GitHubAuthManifest?
    var saveManifest: (GitHubAuthManifest) throws -> Void
    var readStore: (GitHubAuthRef) -> GitHubAuthRead
    var stageStore: (GitHubAuthRef, GitHubCredentialV2) -> GitHubAuthStoreStatus
    var deleteStore: (GitHubAuthRef) -> GitHubAuthStoreStatus
    var transport: ([String: String]) -> GitHubAuthHTTP
    var identity: (String) -> GitHubAuthIdentity
    var withLock: (() throws -> Void) throws -> Void
    var checkpoint: (String, String, String) throws -> Void
    var jitter: () -> Double
    var legacy: () -> GitHubAuthRead
    // True only after all writes to this generation have definitely completed.
    var settled: (GitHubAuthRef) -> Bool = { _ in false }
}

final class GitHubAuthOwner {
    let dependencies: GitHubAuthDependencies
    let clientID: String
    private var pending: [GitHubAuthRef: GitHubCredentialV2] = [:]
    private var cleanupRetryAt: Double = 0
    private var issuerPostsInOperation = 0
    private var pendingLoginResponses: [String: [String: Any]] = [:]
    private var legacyCacheSession: (token: String, epoch: String)?
    private let snapshotLock = NSLock()
    private var presentation = GitHubAuthSnapshot()

    init(dependencies: GitHubAuthDependencies, clientID: String) {
        self.dependencies = dependencies; self.clientID = clientID
    }
    func snapshot() -> GitHubAuthSnapshot {
        snapshotLock.lock(); defer { snapshotLock.unlock() }; return presentation
    }
    private func present(_ state: String, _ reason: String? = nil, credential: GitHubCredentialV2? = nil,
                         manifest: GitHubAuthManifest? = nil) {
        snapshotLock.lock(); defer { snapshotLock.unlock() }
        presentation = GitHubAuthSnapshot(state: state, login: manifest?.login ?? credential?.login ?? presentation.login,
            reason: reason, retryAt: manifest?.retryAt,
            hasCredential: credential != nil || manifest?.active != nil || manifest?.transition != nil,
            cleanupPending: !(manifest?.cleanupRefs.isEmpty ?? true),
            epoch: manifest?.epoch ?? (credential?.epoch == "legacy" ? legacyCacheSession?.epoch : credential?.epoch),
            userID: manifest?.userID ?? credential?.userID)
        if state == "signedOut" { presentation.login = nil }
    }
    private func checkpoint(_ name: String, _ m: GitHubAuthManifest, _ ref: GitHubAuthRef? = nil) throws {
        try dependencies.checkpoint(name, m.epoch, ref?.generation ?? m.transition?.to.generation ?? "")
    }
    private func isCurrent(_ m: GitHubAuthManifest) throws -> Bool {
        guard let current = try dependencies.loadManifest() else { return false }
        return !current.signedOut && current.epoch == m.epoch && current.transition == m.transition && current.active == m.active
    }
    static func lifetime(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let v = n.doubleValue
        return v.isFinite && v > 0 && v <= 10 * 366 * 86400 ? v : nil
    }
    private static func token(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty, s.utf8.count <= 16384,
              s.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 32 && $0.value < 127 }) else { return nil }
        return s
    }
    static func parse(_ response: [String: Any], epoch: String, generation: String, now: Double,
                      previousIdentity: GitHubCredentialV2? = nil, rotating: Bool = false) -> GitHubCredentialV2 {
        let access = token(response["access_token"]), refresh = token(response["refresh_token"])
        let suppliedType = response["token_type"] == nil ? "bearer" : (response["token_type"] as? String)?.lowercased() ?? "invalid"
        let type = suppliedType == "bearer" ? "bearer" : "invalid"
        let complete = access != nil && (!rotating || refresh != nil) && type == "bearer"
        return GitHubCredentialV2(kind: complete ? "credential" : "incomplete", epoch: epoch,
            generation: generation, accessToken: access, refreshToken: refresh, obtainedAt: now,
            accessExpiresAt: lifetime(response["expires_in"]).map { now + $0 },
            refreshExpiresAt: lifetime(response["refresh_token_expires_in"]).map { now + $0 },
            tokenType: type, userID: previousIdentity?.userID, login: previousIdentity?.login)
    }
    private func read(_ m: GitHubAuthManifest) -> GitHubAuthRead {
        guard m.formatVersion == 2 else { return .corrupt }
        if m.signedOut { return .signedOut }
        guard let ref = m.active else { return .missing }
        let result = dependencies.readStore(ref)
        if case .ready(var c) = result {
            guard c.schema == 2, c.kind == "credential", c.epoch == m.epoch,
                  c.generation == ref.generation, c.accessToken != nil, c.tokenType == "bearer" else { return .corrupt }
            // A late first write may lack identity metadata. The published manifest is
            // authoritative; no later envelope writer can erase or switch this identity.
            c.userID = m.userID ?? c.userID; c.login = m.login ?? c.login
            guard c.userID?.isEmpty == false, c.login?.isEmpty == false,
                  (c.userID?.utf8.count ?? 0) <= 1024, (c.login?.utf8.count ?? 0) <= 1024 else { return .corrupt }
            return .ready(c)
        }
        return result
    }
    func readCredential() -> GitHubAuthRead {
        var result: GitHubAuthRead = .unreachable
        do {
            try dependencies.withLock {
                if let m = try self.dependencies.loadManifest() { result = self.read(m) }
                else { result = self.dependencies.legacy() }
            }
        } catch { result = .unreachable }
        return result
    }
    private func ready(_ c: GitHubCredentialV2, manifest: GitHubAuthManifest? = nil) -> GitHubAuthResult {
        guard let token = c.accessToken else { return .actionRequired("missing") }
        if c.epoch == "legacy", legacyCacheSession?.token != token {
            legacyCacheSession = (token: token, epoch: "legacy-cache-" + UUID().uuidString.lowercased())
        }
        present(manifest?.failureReason == nil ? "healthy" : "renewalUnavailable", manifest?.failureReason, credential: c, manifest: manifest)
        return .ready(GitHubAuthAccess(token: token, epoch: c.epoch, generation: c.generation, refreshable: c.refreshToken != nil, userID: c.userID))
    }
    private func unavailable(_ read: GitHubAuthRead, manifest: GitHubAuthManifest? = nil) -> GitHubAuthResult {
        let reason: String
        switch read {
        case .missing: reason = "missing"
        case .locked: reason = "locked"
        case .timeout: reason = "timeout"
        case .corrupt: reason = "corrupt"
        case .changed: reason = "changed"
        case .revoked: reason = "revoked"
        case .signedOut: present("signedOut"); return .signedOut
        default: reason = "unreachable"
        }
        let terminal = reason == "missing" || reason == "corrupt" || reason == "revoked"
        present(terminal ? "actionRequired" : "unavailable", reason, manifest: manifest)
        return terminal ? .actionRequired(reason) : .temporary(reason)
    }
    private func due(_ c: GitHubCredentialV2, now: Double) -> Bool {
        guard let expires = c.accessExpiresAt else { return false }
        let lead = min(900, max(0, expires - c.obtainedAt) / 4)
        return now >= expires - lead
    }
    private func usable(_ c: GitHubCredentialV2, now: Double, reason: String) -> Bool {
        reason != "unauthorized" && c.accessToken != nil && (c.accessExpiresAt == nil || now < c.accessExpiresAt!)
    }
    private func fail(_ m: inout GitHubAuthManifest, _ reason: String, now: Double, retryAfter: Double? = nil) throws -> GitHubAuthResult {
        guard try isCurrent(m) else { return .temporary("changed") }
        m.failureCount += 1
        let delay: Double = m.failureCount == 1 ? 60 : m.failureCount == 2 ? 300 : 600
        let jitter = min(30, max(0, dependencies.jitter()))
        m.retryAt = now + max(min(600, delay + jitter), retryAfter ?? 0); m.failureReason = reason
        try dependencies.saveManifest(m)
        present(m.transition == nil ? "unavailable" : "candidatePending", reason, manifest: m)
        return .temporary(reason)
    }
    private func terminal(_ m: inout GitHubAuthManifest, _ reason: String, canPublish: () -> Bool) throws -> GitHubAuthResult {
        if try cancelIfRequested(&m, canPublish: canPublish) { return .signedOut }
        guard try isCurrent(m) else { return .temporary("changed") }
        // Keep both the active pointer and durable transition: later secure-store recovery
        // can still discover a late candidate. Terminal is never credential deletion.
        m.failureReason = reason; m.retryAt = nil
        try dependencies.saveManifest(m)
        present("actionRequired", reason, manifest: m)
        return .actionRequired(reason)
    }
    private func retire(_ m: inout GitHubAuthManifest, force: Bool = false) throws {
        let now = dependencies.clock()
        guard force || now >= cleanupRetryAt else { return }
        // Bounded cleanup also runs during healthy access-only maintenance, not just
        // after rotations. Rotate uncompleted refs so one locked item cannot starve GC.
        let eligible = m.cleanupRefs.filter { $0 != m.active && $0 != m.transition?.from && $0 != m.transition?.to && $0 != m.transition?.probe }
        guard !eligible.isEmpty else { return }
        cleanupRetryAt = now + 60
        for ref in eligible.prefix(3) {
            try checkpoint("before_retire", m, ref)
            guard try dependencies.loadManifest() == m else { return }
            if m.uncertainRefs.contains(ref), dependencies.settled(ref) {
                m.uncertainRefs.removeAll { $0 == ref }; try dependencies.saveManifest(m)
            }
            let read = dependencies.readStore(ref)
            let canDelete: Bool
            switch read { case .ready, .missing, .corrupt: canDelete = true; default: canDelete = false }
            let deleted = canDelete && dependencies.deleteStore(ref) == .success
            guard try dependencies.loadManifest() == m else { return }
            m.cleanupRefs.removeAll { $0 == ref }
            if !deleted || m.uncertainRefs.contains(ref) { m.cleanupRefs.append(ref) }
            try dependencies.saveManifest(m)
            try checkpoint("after_retire", m, ref)
        }
    }
    private func presentSignedOut(_ m: GitHubAuthManifest) {
        present("signedOut", m.cleanupRefs.isEmpty ? nil : "cleanup_pending", manifest: m)
    }
    private func tombstone(_ m: inout GitHubAuthManifest) throws {
        if let ref = m.active { remember(ref, in: &m) }
        if let t = m.transition { remember(t.to, in: &m); if let source = t.from { remember(source, in: &m) }; if let p = t.probe { remember(p, in: &m) } }
        remember(GitHubAuthRef(generation: "legacy", backend: "legacy-keychain"), in: &m)
        m.epoch = UUID().uuidString.lowercased(); m.signedOut = true
        m.active = nil; m.transition = nil; m.userID = nil; m.login = nil
        m.failureReason = nil; m.retryAt = nil
        try dependencies.saveManifest(m); pending.removeAll(); pendingLoginResponses.removeAll()
        presentSignedOut(m)
    }
    // Carry the original device-attempt fence through every successor operation.
    // Cancellation must be durable before returning or publishing: an outer cleanup
    // after completeLogin returns cannot protect a crash during nested renewal.
    private func cancelIfRequested(_ m: inout GitHubAuthManifest, canPublish: () -> Bool) throws -> Bool {
        guard !canPublish() else { return false }
        guard try isCurrent(m) else { return true }
        try tombstone(&m)
        try retire(&m, force: true)
        presentSignedOut(m)
        return true
    }
    private func remember(_ ref: GitHubAuthRef, in m: inout GitHubAuthManifest) {
        if !m.cleanupRefs.contains(ref) { m.cleanupRefs.append(ref) }
    }
    private func durableStage(_ ref: GitHubAuthRef, _ credential: GitHubCredentialV2,
                              manifest m: inout GitHubAuthManifest) throws -> GitHubAuthStoreStatus {
        guard try isCurrent(m) else { return .failed }
        var wasUncertain = m.uncertainRefs.contains(ref)
        if wasUncertain {
            // Never start a second writer until the preceding operation acknowledged
            // completion. A ready read alone does not establish writer settlement.
            guard dependencies.settled(ref) else { return .timeout }
            m.uncertainRefs.removeAll { $0 == ref }; try dependencies.saveManifest(m)
            wasUncertain = false
        }
        if !wasUncertain {
            // Journal a potentially still-running writer before starting it. A later
            // successful write/read never proves that an earlier timed-out writer ended.
            m.uncertainRefs.append(ref)
            if !(m.permitWriterRefs ?? []).contains(ref) {
                if m.permitWriterRefs == nil { m.permitWriterRefs = [] }; m.permitWriterRefs!.append(ref)
            }
            try dependencies.saveManifest(m)
        }
        let status = dependencies.stageStore(ref, credential)
        // All non-timeout results mean the adapter returned synchronously with no
        // worker outstanding. Timeout alone is explicitly indeterminate.
        if status != .timeout && !wasUncertain {
            guard try isCurrent(m) else { return status }
            m.uncertainRefs.removeAll { $0 == ref }; try dependencies.saveManifest(m)
        }
        return status
    }
    private func renewCandidate(_ candidate: GitHubCredentialV2, manifest m: inout GitHubAuthManifest,
                                now: Double, canPublish: () -> Bool) throws -> GitHubAuthResult {
        if try cancelIfRequested(&m, canPublish: canPublish) { return .signedOut }
        guard let previous = m.transition, try isCurrent(m) else { return .temporary("changed") }
        guard candidate.refreshToken != nil else { return try terminal(&m, "access_expired", canPublish: canPublish) }
        if let expires = candidate.refreshExpiresAt, now >= expires { return try terminal(&m, "refresh_expired", canPublish: canPublish) }
        let next = GitHubAuthRef(generation: UUID().uuidString.lowercased(), backend: previous.to.backend)
        let probe = GitHubAuthRef(generation: UUID().uuidString.lowercased(), backend: previous.to.backend)
        try checkpoint("before_intent", m, next)
        if try cancelIfRequested(&m, canPublish: canPublish) { return .signedOut }
        guard try isCurrent(m) else { return .temporary("changed") }
        if let source = previous.from { remember(source, in: &m) }
        if let oldProbe = previous.probe { remember(oldProbe, in: &m) }
        remember(previous.to, in: &m); remember(probe, in: &m)
        // The unpublished candidate is now the only refresh source. The committed
        // active pointer remains unchanged until its successor validates and publishes.
        m.transition = GitHubAuthTransition(from: previous.to, to: next, phase: "prepared", kind: "refresh", probe: probe)
        m.failureReason = issuerPostsInOperation == 0 ? nil : "candidate_renewal"
        m.retryAt = issuerPostsInOperation == 0 ? nil : now + 60
        m.failureCount = 0
        try dependencies.saveManifest(m); try checkpoint("after_intent", m, next)
        if try cancelIfRequested(&m, canPublish: canPublish) { return .signedOut }
        present("renewing", "candidate_renewal", manifest: m)
        // At most one actual issuer POST per outer operation, even if a newly issued
        // access is rejected too. The next durable prepared step runs on maintenance.
        guard issuerPostsInOperation == 0 else { return .temporary("candidate_renewal") }
        return try recover(&m, now: now, canPublish: canPublish) ?? .temporary("candidate_renewal")
    }
    private func refreshSource(_ m: GitHubAuthManifest) -> GitHubAuthRead {
        guard let source = m.transition?.from else { return .missing }
        if source == m.active { return read(m) }
        let result = dependencies.readStore(source)
        guard case .ready(var candidate) = result else { return result }
        guard candidate.schema == 2, candidate.kind == "credential", candidate.epoch == m.epoch,
              candidate.generation == source.generation, candidate.tokenType == "bearer",
              candidate.accessToken != nil, candidate.refreshToken != nil else { return .corrupt }
        candidate.userID = m.userID ?? candidate.userID; candidate.login = m.login ?? candidate.login
        return .ready(candidate)
    }
    private func validateCandidate(_ candidate: GitHubCredentialV2, manifest m: inout GitHubAuthManifest,
                                   now: Double, canPublish: () -> Bool) throws -> GitHubAuthResult {
        if try cancelIfRequested(&m, canPublish: canPublish) { return .signedOut }
        guard let t = m.transition, candidate.schema == 2, candidate.epoch == m.epoch,
              candidate.generation == t.to.generation else { return try fail(&m, "corrupt", now: now) }
        guard candidate.kind == "credential", candidate.tokenType == "bearer", let token = candidate.accessToken else {
            return try terminal(&m, "incomplete_candidate", canPublish: canPublish)
        }
        guard try isCurrent(m) else { return .temporary("changed") }
        if let expires = candidate.accessExpiresAt, now >= expires {
            return try renewCandidate(candidate, manifest: &m, now: now, canPublish: canPublish)
        }
        m.transition?.phase = "validationPending"; try dependencies.saveManifest(m)
        try checkpoint("before_identity", m)
        if try cancelIfRequested(&m, canPublish: canPublish) { return .signedOut }
        let identity = dependencies.identity(token)
        try checkpoint("after_identity", m)
        if try cancelIfRequested(&m, canPublish: canPublish) { return .signedOut }
        guard try isCurrent(m) else { return .temporary("changed") }
        switch identity {
        case .temporary: return try fail(&m, "identity_unavailable", now: now)
        case .unauthorized:
            if candidate.refreshToken != nil { return try renewCandidate(candidate, manifest: &m, now: now, canPublish: canPublish) }
            return try fail(&m, "candidate_unauthorized", now: now)
        case .ready(let userID, let login):
            guard !userID.isEmpty, !login.isEmpty, userID.utf8.count <= 1024, login.utf8.count <= 1024 else {
                return try fail(&m, "identity_unavailable", now: now)
            }
            if let oldID = m.userID ?? candidate.userID, oldID != userID { return try terminal(&m, "identity_changed", canPublish: canPublish) }
            var verified = candidate; verified.userID = userID; verified.login = login
            // Publish identity in the same atomic manifest update as active. The secure
            // payload remains immutable, so a late writer can only replay the same pair.
            try checkpoint("before_publish", m)
            guard try isCurrent(m) else { return .temporary("changed") }
            if try cancelIfRequested(&m, canPublish: canPublish) { return .signedOut }
            if let old = t.from { remember(old, in: &m) }
            if let active = m.active { remember(active, in: &m) }
            if let probe = t.probe { remember(probe, in: &m) }
            m.active = t.to; m.userID = userID; m.login = login
            m.transition = nil; m.failureReason = nil; m.retryAt = nil; m.failureCount = 0
            try dependencies.saveManifest(m)
            pending.removeValue(forKey: t.to); pendingLoginResponses.removeValue(forKey: m.epoch)
            try checkpoint("after_publish", m, t.to)
            try retire(&m, force: true)
            return ready(verified, manifest: m)
        }
    }
    private func stage(_ candidate: GitHubCredentialV2, manifest m: inout GitHubAuthManifest, now: Double, canPublish: () -> Bool) throws -> GitHubAuthResult {
        if try cancelIfRequested(&m, canPublish: canPublish) { return .signedOut }
        guard let ref = m.transition?.to, try isCurrent(m) else { return .temporary("changed") }
        pending[ref] = candidate
        let status = try durableStage(ref, candidate, manifest: &m)
        try checkpoint("after_stage", m)
        if try cancelIfRequested(&m, canPublish: canPublish) { return .signedOut }
        guard try isCurrent(m) else { return .temporary("changed") }
        // Readback even on timeout: the bounded adapter may have completed the durable write.
        let readback = dependencies.readStore(ref)
        try checkpoint("after_readback", m)
        if try cancelIfRequested(&m, canPublish: canPublish) { return .signedOut }
        guard case .ready(let stored) = readback, stored == candidate else {
            return try fail(&m, status == .timeout ? "storage_timeout" : "storage_unavailable", now: now)
        }
        m.transition?.phase = "ready"; try dependencies.saveManifest(m)
        pending.removeValue(forKey: ref)
        return try validateCandidate(stored, manifest: &m, now: now, canPublish: canPublish)
    }
    private func request(_ credential: GitHubCredentialV2, manifest m: inout GitHubAuthManifest,
                         now: Double, recovery: Bool, canPublish: () -> Bool) throws -> GitHubAuthResult {
        if try cancelIfRequested(&m, canPublish: canPublish) { return .signedOut }
        guard try isCurrent(m) else { return .temporary("changed") }
        guard let refresh = credential.refreshToken, m.transition != nil else { return try terminal(&m, "missing_refresh", canPublish: canPublish) }
        guard issuerPostsInOperation == 0 else { return .temporary("candidate_renewal") }
        let previousPhase = m.transition!.phase
        let previousAttempts = m.transition!.recoveryAttempts
        if recovery {
            guard m.transition!.recoveryAttempts < 1 else { return try terminal(&m, "lost_result", canPublish: canPublish) }
            m.transition!.recoveryAttempts += 1
        }
        m.transition!.phase = "requestStarted"; try dependencies.saveManifest(m)
        try checkpoint("after_request_started", m)
        if try cancelIfRequested(&m, canPublish: canPublish) { return .signedOut }
        guard try isCurrent(m) else { return .temporary("changed") }
        let capturedEpoch = m.epoch, capturedRef = m.transition!.to
        issuerPostsInOperation += 1
        let response = dependencies.transport(["client_id": clientID, "grant_type": "refresh_token", "refresh_token": refresh])
        // Capture the complete known response before ANY fallible checkpoint, manifest
        // reload or storage operation. Metadata failure must never lose a live pair.
        var capturedCandidate: GitHubCredentialV2?
        if let json = response.json, (200..<300).contains(response.status),
           json["access_token"] != nil || json["refresh_token"] != nil {
            let candidate = Self.parse(json, epoch: capturedEpoch, generation: capturedRef.generation,
                                       now: now, previousIdentity: credential, rotating: true)
            pending[capturedRef] = candidate; capturedCandidate = candidate
        }
        try checkpoint("after_response", m)
        if try cancelIfRequested(&m, canPublish: canPublish) { return .signedOut }
        guard try isCurrent(m) else { return .temporary("changed") }
        if (response.knownNotSent && response.status == 0) || [403, 429].contains(response.status) {
            m.transition!.phase = previousPhase
            // A proven unsent attempt spends no issuer budget. A delivered 403/429
            // following an earlier unknown result still spends its single recovery POST.
            if response.knownNotSent && response.status == 0 {
                m.transition!.recoveryAttempts = previousAttempts
            }
            try dependencies.saveManifest(m)
            let retry = response.headers.first { $0.key.lowercased() == "retry-after" }.flatMap { Double($0.value) }
            return try fail(&m, "network_unavailable", now: now, retryAfter: retry?.isFinite == true ? retry : nil)
        }
        if let c = capturedCandidate {
            try checkpoint("after_parse", m)
            return try stage(c, manifest: &m, now: now, canPublish: canPublish)
        }
        // Always recover durable evidence again before declaring a one-use refresh lost.
        if let ref = m.transition?.to, case .ready(let c) = dependencies.readStore(ref) {
            return try validateCandidate(c, manifest: &m, now: now, canPublish: canPublish)
        }
        if [200, 400].contains(response.status), response.json?["error"] as? String == "bad_refresh_token" {
            return try terminal(&m, recovery ? "lost_result" : "bad_refresh_token", canPublish: canPublish)
        }
        let retryAfter = response.headers.first { $0.key.lowercased() == "retry-after" }.flatMap { Double($0.value) }
        return try fail(&m, "response_unknown", now: now, retryAfter: retryAfter?.isFinite == true ? retryAfter : nil)
    }
    private func probeSettled(_ ref: GitHubAuthRef, manifest m: inout GitHubAuthManifest, now: Double) throws -> Bool {
        if m.uncertainRefs.contains(ref) {
            guard dependencies.settled(ref) else { _ = try fail(&m, "probe_pending", now: now); return false }
            m.uncertainRefs.removeAll { $0 == ref }; try dependencies.saveManifest(m)
        }
        return true
    }
    private func probe(_ m: inout GitHubAuthManifest, now: Double) throws -> Bool {
        guard let ref = m.transition?.probe else { return true }
        switch dependencies.readStore(ref) {
        case .ready(let stored):
            if stored.kind == "probe", stored.epoch == m.epoch, stored.generation == ref.generation {
                return try probeSettled(ref, manifest: &m, now: now)
            }
            _ = try fail(&m, "storage_corrupt", now: now); return false
        case .missing:
            let c = GitHubCredentialV2(kind: "probe", epoch: m.epoch, generation: ref.generation,
                accessToken: nil, refreshToken: nil, obtainedAt: now)
            let status = try durableStage(ref, c, manifest: &m)
            if case .ready(let stored) = dependencies.readStore(ref), stored == c {
                return try probeSettled(ref, manifest: &m, now: now)
            }
            _ = try fail(&m, status == .timeout ? "probe_timeout" : "storage_unavailable", now: now); return false
        default: _ = try fail(&m, "storage_unavailable", now: now); return false
        }
    }
    private func recover(_ m: inout GitHubAuthManifest, now: Double, canPublish: () -> Bool) throws -> GitHubAuthResult? {
        if try cancelIfRequested(&m, canPublish: canPublish) { return .signedOut }
        guard let t = m.transition else { return nil }
        // A login response can also survive a transient manifest failure before the
        // caller learned the target ref. Bind it only after the original epoch reloads.
        if t.kind == "login", let response = pendingLoginResponses[m.epoch], pending[t.to] == nil {
            pending[t.to] = Self.parse(response, epoch: m.epoch, generation: t.to.generation, now: now)
        }
        // Every phase must consult toRef before budgets, retry gates or another POST.
        let readback = dependencies.readStore(t.to)
        if case .ready(let c) = readback {
            if let retryAt = m.retryAt, now < retryAt {
                present("candidatePending", m.failureReason, manifest: m)
                return .temporary(m.failureReason ?? "backoff")
            }
            return try validateCandidate(c, manifest: &m, now: now, canPublish: canPublish)
        }
        if let c = pending[t.to] {
            if let retryAt = m.retryAt, now < retryAt {
                present("candidatePending", m.failureReason, manifest: m)
                return .temporary(m.failureReason ?? "backoff")
            }
            return try stage(c, manifest: &m, now: now, canPublish: canPublish)
        }
        // A helper can still be staging the consumed grant after this process
        // restarted. Missing at this instant is not permission to spend recovery budget.
        let unresolved = [t.to, t.probe].compactMap { $0 }.filter { m.uncertainRefs.contains($0) }
        for ref in unresolved {
            guard dependencies.settled(ref) else { return try fail(&m, "storage_pending", now: now) }
            m.uncertainRefs.removeAll { $0 == ref }; try dependencies.saveManifest(m)
        }
        if !unresolved.isEmpty {
            // Settlement and our earlier missing read can race; consult toRef again.
            switch dependencies.readStore(t.to) {
            case .ready(let c): return try validateCandidate(c, manifest: &m, now: now, canPublish: canPublish)
            case .missing: break
            default: return try fail(&m, "storage_unavailable", now: now)
            }
        }
        if t.kind == "login", t.phase == "prepared", !m.uncertainRefs.contains(t.to) {
            // No candidate was ever durably staged: this is an interrupted device flow,
            // not a saved sign-in awaiting validation. Keep the explicit login available.
            present("actionRequired", "login_incomplete", manifest: m)
            return .actionRequired("login_incomplete")
        }
        guard case .missing = readback else { return try fail(&m, "storage_unavailable", now: now) }
        if let retryAt = m.retryAt, now < retryAt {
            present("candidatePending", m.failureReason, manifest: m)
            return .temporary(m.failureReason ?? "backoff")
        }
        if ["bad_refresh_token", "lost_result", "incomplete_candidate", "identity_changed"].contains(m.failureReason ?? "") {
            present("actionRequired", m.failureReason, manifest: m)
            return .actionRequired(m.failureReason!)
        }
        guard t.kind == "refresh" else { present("candidatePending", "login_pending", manifest: m); return .temporary("login_pending") }
        let source = refreshSource(m)
        guard case .ready(let c) = source else { return unavailable(source, manifest: m) }
        if t.phase == "prepared" {
            guard try probe(&m, now: now) else { return .temporary(m.failureReason ?? "storage_unavailable") }
            return try request(c, manifest: &m, now: now, recovery: false, canPublish: canPublish)
        }
        return try request(c, manifest: &m, now: now, recovery: true, canPublish: canPublish)
    }
    func ensureAccess(reason: String, now suppliedNow: Double? = nil) -> GitHubAuthResult {
        var result: GitHubAuthResult = .temporary("storage_unavailable")
        do {
            try dependencies.withLock {
                self.issuerPostsInOperation = 0
                let now = suppliedNow ?? self.dependencies.clock()
                guard var m = try self.dependencies.loadManifest() else {
                    let legacy = self.dependencies.legacy()
                    if case .ready(let c) = legacy { result = self.ready(c) } else { result = self.unavailable(legacy) }
                    return
                }
                guard m.formatVersion == 2 else { result = self.unavailable(.corrupt, manifest: m); return }
                if m.signedOut { try? self.retire(&m); self.presentSignedOut(m); result = .signedOut; return }
                try? self.retire(&m)
                if m.failureReason == "revoked" { result = .actionRequired("revoked"); self.present("actionRequired", "revoked", manifest: m); return }
                if let recovered = try self.recover(&m, now: now, canPublish: { true }) {
                    if case .ready = recovered { result = recovered; return }
                    // An issuer has potentially invalidated the old access in requestStarted.
                    // Only a positively rejected refresh permits continuing a known usable access.
                    if m.failureReason == "bad_refresh_token", m.transition?.from == m.active, case .ready(let c) = self.read(m), self.usable(c, now: now, reason: reason) {
                        result = self.ready(c, manifest: m)
                    } else { result = recovered }
                    return
                }
                let read = self.read(m)
                guard case .ready(let c) = read else { result = self.unavailable(read, manifest: m); return }
                if !self.due(c, now: now) && reason != "unauthorized" { result = self.ready(c, manifest: m); return }
                guard c.refreshToken != nil else {
                    if c.accessExpiresAt == nil || now < c.accessExpiresAt! { result = self.ready(c, manifest: m) }
                    else { result = try self.terminal(&m, "access_expired", canPublish: { true }) }
                    return
                }
                if let expires = c.refreshExpiresAt, now >= expires {
                    if self.usable(c, now: now, reason: reason) { result = self.ready(c, manifest: m) }
                    else { result = try self.terminal(&m, "refresh_expired", canPublish: { true }) }; return
                }
                if let retryAt = m.retryAt, now < retryAt {
                    result = self.usable(c, now: now, reason: reason) ? self.ready(c, manifest: m) : .temporary("backoff"); return
                }
                let to = GitHubAuthRef(generation: UUID().uuidString.lowercased(), backend: m.active!.backend)
                let probe = GitHubAuthRef(generation: UUID().uuidString.lowercased(), backend: m.active!.backend)
                try self.checkpoint("before_intent", m, to)
                guard try self.isCurrent(m) else { result = .temporary("changed"); return }
                m.transition = GitHubAuthTransition(from: m.active, to: to, phase: "prepared", probe: probe)
                self.remember(probe, in: &m)
                try self.dependencies.saveManifest(m); try self.checkpoint("after_intent", m)
                self.present("renewing", credential: c, manifest: m)
                result = try self.recover(&m, now: now, canPublish: { true }) ?? .temporary("storage_unavailable")
                if m.failureReason == "bad_refresh_token", m.transition?.from == m.active, self.usable(c, now: now, reason: reason) {
                    result = self.ready(c, manifest: m)
                }
            }
        } catch { present("unavailable", "storage_unavailable"); result = .temporary("storage_unavailable") }
        return result
    }
    /// Explicit login owns a fresh durable epoch before the device request is sent.
    func beginLogin() -> String? {
        var epoch: String?
        do { try dependencies.withLock {
            let old = try self.dependencies.loadManifest()
            var m = GitHubAuthManifest(epoch: UUID().uuidString.lowercased())
            m.cleanupRefs = old?.cleanupRefs ?? []
            m.uncertainRefs = old?.uncertainRefs ?? []
            m.permitWriterRefs = old?.permitWriterRefs
            self.remember(GitHubAuthRef(generation: "legacy", backend: "legacy-keychain"), in: &m)
            if let active = old?.active { self.remember(active, in: &m) }
            if let t = old?.transition { self.remember(t.to, in: &m); if let source = t.from { self.remember(source, in: &m) }; if let p = t.probe { self.remember(p, in: &m) } }
            let ref = GitHubAuthRef(generation: UUID().uuidString.lowercased())
            let probe = GitHubAuthRef(generation: UUID().uuidString.lowercased())
            m.transition = GitHubAuthTransition(to: ref, phase: "prepared", kind: "login", probe: probe)
            self.remember(probe, in: &m)
            try self.dependencies.saveManifest(m)
            guard try self.probe(&m, now: self.dependencies.clock()) else { return }
            epoch = m.epoch
            self.present("loginPending", manifest: m)
        } } catch { present("unavailable", "storage_unavailable") }
        return epoch
    }
    func completeLogin(response: [String: Any], epoch: String, isCurrent: () -> Bool = { true }) -> GitHubAuthResult {
        // Secrets remain in this owner's memory even if the very first lock/manifest
        // operation fails. Recovery binds them to this exact explicit-login epoch.
        pendingLoginResponses[epoch] = response
        issuerPostsInOperation = 0
        var result: GitHubAuthResult = .temporary("changed")
        do { try dependencies.withLock {
            guard var m = try self.dependencies.loadManifest(), !m.signedOut, m.epoch == epoch,
                  let t = m.transition, t.kind == "login" else { return }
            let now = self.dependencies.clock()
            let c = Self.parse(response, epoch: epoch, generation: t.to.generation, now: now)
            self.pending[t.to] = c
            try self.checkpoint("after_parse", m)
            result = try self.stage(c, manifest: &m, now: now, canPublish: isCurrent)
        } } catch { result = .temporary("storage_unavailable") }
        // This check covers timeout/storage failure returns too, not only /user/publish.
        if !isCurrent(), cancelLogin(epoch: epoch) { return .signedOut }
        return result
    }
    /// Abort only a device flow with no issued/staged candidate. Never abandon a pair
    /// whose first write timed out: cancelLogin performs a fenced tombstone for that case.
    @discardableResult func abortLogin(epoch: String) -> Bool {
        var aborted = false
        do { try dependencies.withLock {
            guard var m = try self.dependencies.loadManifest(), !m.signedOut, m.epoch == epoch,
                  let t = m.transition, t.kind == "login", t.phase == "prepared",
                  !m.uncertainRefs.contains(t.to), self.pending[t.to] == nil,
                  case .missing = self.dependencies.readStore(t.to) else { return }
            try self.tombstone(&m); aborted = true
            try? self.retire(&m, force: true); self.presentSignedOut(m)
        } } catch { }
        return aborted
    }
    @discardableResult func cancelLogin(epoch: String) -> Bool {
        var cancelled = false
        do { try dependencies.withLock {
            guard var m = try self.dependencies.loadManifest(), !m.signedOut, m.epoch == epoch else { return }
            try self.tombstone(&m); cancelled = true
            try? self.retire(&m, force: true); self.presentSignedOut(m)
        } } catch { }
        return cancelled
    }
    /// Fence publication of account-scoped derived data under the same process lock
    /// as login/logout/refresh. The callback must not call this owner recursively.
    func withCurrentAccess(_ access: GitHubAuthAccess, _ body: () throws -> Void) -> Bool {
        var published = false
        do { try dependencies.withLock {
            if let m = try self.dependencies.loadManifest() {
                guard !m.signedOut, m.epoch == access.epoch,
                      m.active?.generation == access.generation,
                      (m.transition == nil || m.failureReason == "bad_refresh_token"),
                      m.failureReason != "revoked",
                      case .ready(let c) = self.read(m), c.userID == access.userID, c.accessToken == access.token else { return }
            } else {
                guard access.epoch == "legacy", case .ready(let c) = self.dependencies.legacy(),
                      c.accessToken == access.token else { return }
            }
            try body(); published = true
        } } catch { }
        return published
    }
    /// Only an independently confirmed access-only 401 chain reaches this method.
    @discardableResult func confirmedUnauthorized(_ access: GitHubAuthAccess) -> Bool {
        var changed = false
        do { try dependencies.withLock {
            guard var m = try self.dependencies.loadManifest(), !m.signedOut,
                  m.epoch == access.epoch, m.active?.generation == access.generation,
                  m.transition == nil, case .ready(let c) = self.read(m),
                  c.refreshToken == nil, c.accessToken == access.token else { return }
            m.failureReason = "revoked"; m.retryAt = nil
            try self.dependencies.saveManifest(m)
            changed = true; self.present("actionRequired", "revoked", manifest: m)
            if let ref = m.active { _ = self.dependencies.deleteStore(ref) }
        } } catch { }
        return changed
    }
    @discardableResult func logoutDetailed() -> GitHubAuthLogoutResult {
        var result = GitHubAuthLogoutResult(accessDisabled: false, cleanupPending: true)
        do { try dependencies.withLock {
            var m = try self.dependencies.loadManifest() ?? GitHubAuthManifest(epoch: UUID().uuidString.lowercased())
            try self.tombstone(&m)
            result.accessDisabled = true
            try self.checkpoint("after_logout_tombstone", m)
            try? self.retire(&m, force: true)
            result.cleanupPending = !m.cleanupRefs.isEmpty
            self.presentSignedOut(m)
        } } catch { if !result.accessDisabled { present("unavailable", "storage_unavailable") } }
        return result
    }
    /// Compatibility API: success means both disabled and physically cleaned up.
    @discardableResult func logout() -> Bool {
        let result = logoutDetailed()
        return result.accessDisabled && !result.cleanupPending
    }
}
