import Foundation

// Independent issuer and in-memory dependency oracle. This file creates no
// production singleton, URLSession, Keychain, AppDelegate, preferences or paths.
// A thrown checkpoint models a stopped owner; it is NOT an OS-fsync/process test.
private enum GHFixtureError: Error { case stopped, unavailable, busy }
private enum GHResponseFault {
    case notSent, lost, status(Int, [String: String]), partial(String)
}
private struct GHIssuance {
    var access: String
    var refresh: String?
    var userID: String = "1001"
    var login: String = "fixture-user"
    var issuedAt: Double
    var accessUntil: Double?
    var refreshUntil: Double?
    var validAccess = true
    var validRefresh = true
    var wire: [String: Any] {
        var value: [String: Any] = ["access_token": access, "token_type": "bearer", "scope": "gist"]
        if let r = refresh { value["refresh_token"] = r }
        if let t = accessUntil { value["expires_in"] = t - issuedAt }
        if let t = refreshUntil { value["refresh_token_expires_in"] = t - issuedAt }
        return value
    }
}
private final class GHAuthFixture {
    var now: Double = 1_800_000_000
    var monotonicNow: Double? // optional independent clock for retry-specific regressions
    var manifest: GitHubAuthManifest?
    var items: [GitHubAuthRef: GitHubCredentialV2] = [:]
    var issuances: [GHIssuance] = []
    var counts: [String: Int] = [:]
    var marker = 0
    var accessTTL: Double = 8 * 3600
    var refreshTTL: Double = 180 * 86400
    var responseFaults: [GHResponseFault] = []
    var identityFault: GitHubAuthIdentity?
    var readOverride: GitHubAuthRead?
    var stageFault: ((GitHubAuthRef, GitHubCredentialV2) -> GitHubAuthStoreStatus?)?
    var deleteFault: GitHubAuthStoreStatus?
    var persistentDeleteFault: GitHubAuthStoreStatus?
    var lateWrites: [(GitHubAuthRef, GitHubCredentialV2)] = []
    var checkpointAction: [String: () throws -> Void] = [:]
    var failLoad = false
    var failSave = false
    var lockHeld = false
    var legacyRead: GitHubAuthRead = .signedOut
    var jitter: Double = 0
    var settlementOverride: Bool?
    // These facts belong to the independent adapter, not credential readability.
    // A journaled permit with no stage invocation proves no-send; all other
    // refs need an explicit completed writer and no unresolved late operation.
    var startedWriterRefs: Set<GitHubAuthRef> = []
    var settledWriterRefs: Set<GitHubAuthRef> = []
    var deleteAttempts: [GitHubAuthRef] = []
    private let namespace = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

    func record(_ name: String) { counts[name, default: 0] += 1 }
    func issue(legacy: Bool = false, explicit: Bool = false, userID: String = "1001", login: String = "fixture-user") -> GHIssuance {
        if explicit { record("device_flow") }
        let suffix = namespace + String(issuances.count + 1, radix: 16)
        let item = GHIssuance(access: "ccl-test-access-" + suffix,
            refresh: legacy ? nil : "ccl-test-refresh-" + suffix, userID: userID, login: login, issuedAt: now,
            accessUntil: legacy ? nil : now + accessTTL,
            refreshUntil: legacy ? nil : now + refreshTTL)
        issuances.append(item); record("issuer_issue"); return item
    }
    func authorized(_ token: String) -> GHIssuance? {
        issuances.first { $0.access == token && $0.validAccess && ($0.accessUntil == nil || now < $0.accessUntil!) }
    }
    func consume(_ refresh: String) -> GHIssuance? {
        guard let index = issuances.firstIndex(where: { $0.refresh == refresh && $0.validRefresh && now < ($0.refreshUntil ?? 0) }) else {
            record("refresh_rejected"); return nil
        }
        issuances[index].validAccess = false; issuances[index].validRefresh = false
        record("refresh_consumed")
        var next = issue(); next.userID = issuances[index].userID; next.login = issuances[index].login
        issuances[issuances.count - 1] = next; return next
    }
    func transport(_ fields: [String: String]) -> GitHubAuthHTTP {
        precondition(fields["grant_type"] == "refresh_token" && fields["client_id"] == "fixture-client",
                     "unexpected synthetic OAuth request")
        precondition(fields["client_secret"] == nil && fields["Authorization"] == nil,
                     "prohibited OAuth field")
        record("refresh_attempt")
        let fault = responseFaults.isEmpty ? nil : responseFaults.removeFirst()
        if case .notSent? = fault { record("not_sent"); return GitHubAuthHTTP(status: 0, json: nil, knownNotSent: true) }
        record("refresh_request")
        if case .status(let status, let headers)? = fault { return GitHubAuthHTTP(status: status, json: [:], headers: headers) }
        guard let fresh = consume(fields["refresh_token"] ?? "") else {
            return GitHubAuthHTTP(status: 400, json: ["error": "bad_refresh_token"])
        }
        if case .lost? = fault { record("response_lost"); return GitHubAuthHTTP(status: 0, json: nil) }
        var body = fresh.wire
        if case .partial(let missing)? = fault { body.removeValue(forKey: missing) }
        return GitHubAuthHTTP(status: 200, json: body)
    }
    func identity(_ token: String) -> GitHubAuthIdentity {
        record("user_request")
        guard let fresh = authorized(token) else { return .unauthorized }
        if let fault = identityFault { identityFault = nil; return fault }
        record("user_authorized"); return .ready(userID: fresh.userID, login: fresh.login)
    }
    func stage(_ ref: GitHubAuthRef, _ credential: GitHubCredentialV2) -> GitHubAuthStoreStatus {
        record("store_stage"); startedWriterRefs.insert(ref); settledWriterRefs.remove(ref)
        precondition(ref.generation == credential.generation, "fixture ref binding changed")
        if let old = items[ref] {
            precondition(old.epoch == credential.epoch && old.accessToken == credential.accessToken && old.refreshToken == credential.refreshToken,
                         "immutable generation credential pair changed")
        }
        if let status = stageFault?(ref, credential) {
            if status == .timeout { lateWrites.append((ref, credential)) }
            else { settledWriterRefs.insert(ref) }
            return status
        }
        items[ref] = credential; settledWriterRefs.insert(ref); record("store_durable"); return .success
    }
    func owner() -> GitHubAuthOwner {
        let deps = GitHubAuthDependencies(
            clock: { self.now },
            loadManifest: {
                self.record("manifest_read")
                if self.failLoad { self.failLoad = false; throw GHFixtureError.unavailable }
                return self.manifest
            },
            saveManifest: { value in
                self.record("manifest_save_attempt")
                if self.failSave { self.failSave = false; throw GHFixtureError.unavailable }
                self.manifest = value; self.record("manifest_saved")
            },
            readStore: { ref in
                self.record("store_read")
                if let fault = self.readOverride { return fault }
                return self.items[ref].map { .ready($0) } ?? .missing
            },
            stageStore: { self.stage($0, $1) },
            deleteStore: { ref in
                self.record("store_delete_attempt"); self.deleteAttempts.append(ref)
                if let fault = self.persistentDeleteFault { return fault }
                if let fault = self.deleteFault { self.deleteFault = nil; return fault }
                self.items.removeValue(forKey: ref); self.record("store_deleted"); return .success
            },
            transport: { self.transport($0) }, identity: { self.identity($0) },
            withLock: { operation in
                self.record("lock_attempt")
                guard !self.lockHeld else { throw GHFixtureError.busy }
                self.lockHeld = true; defer { self.lockHeld = false }; try operation()
            },
            checkpoint: { point, epoch, generation in
                precondition(!epoch.contains("ccl-test-") && !generation.contains("ccl-test-"), "secret checkpoint metadata")
                self.record("checkpoint_" + point)
                if let action = self.checkpointAction.removeValue(forKey: point) { try action() }
            }, jitter: { self.jitter }, legacy: { self.legacyRead },
            settled: { ref in
                if let override = self.settlementOverride { return override }
                guard !self.lateWrites.contains(where: { $0.0 == ref }) else { return false }
                let noSend = (self.manifest?.permitWriterRefs ?? []).contains(ref) && !self.startedWriterRefs.contains(ref)
                return self.settledWriterRefs.contains(ref) || noSend
            }, monotonicClock: { self.monotonicNow ?? self.now })
        return GitHubAuthOwner(dependencies: deps, clientID: "fixture-client")
    }
    func login(_ owner: GitHubAuthOwner, legacy: Bool = false) -> GitHubAuthResult {
        guard let epoch = owner.beginLogin() else { return .temporary("fixture_login") }
        let issued = issue(legacy: legacy, explicit: true)
        return owner.completeLogin(response: issued.wire, epoch: epoch)
    }
    func due() { now = issuances.last!.accessUntil! }
    func releaseLateWrites() {
        for (ref, value) in lateWrites { items[ref] = value; settledWriterRefs.insert(ref); record("late_write_completed") }
        lateWrites.removeAll()
    }
    func protectedRead(_ result: GitHubAuthResult, userID: String = "1001") -> Bool {
        record("gist_request")
        guard case .ready(let access) = result, let issued = authorized(access.token), issued.userID == userID else { return false }
        marker += 1; record("gist_authorized"); return true
    }
    func publicStateIsNonsecret(_ owner: GitHubAuthOwner) -> Bool {
        guard let encoded = try? JSONEncoder().encode(manifest), let string = String(data: encoded, encoding: .utf8) else { return false }
        let snapshot = owner.snapshot()
        return !string.contains("ccl-test-access-") && !string.contains("ccl-test-refresh-") &&
            !string.contains("accessToken") && !string.contains("refreshToken") &&
            !(snapshot.login ?? "").contains("ccl-test-") && !(snapshot.reason ?? "").contains("ccl-test-") &&
            !(snapshot.epoch ?? "").contains("ccl-test-") && !(snapshot.userID ?? "").contains("ccl-test-")
    }
}

func runGitHubAuthSelfTests() {
    var checks = 0, failed = 0
    func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        checks += 1
        if !condition() { failed += 1; print("AUTH FAIL: " + label) }
    }
    func isReady(_ result: GitHubAuthResult) -> Bool { if case .ready = result { return true }; return false }
    func isTemporary(_ result: GitHubAuthResult) -> Bool { if case .temporary = result { return true }; return false }
    func isAction(_ result: GitHubAuthResult) -> Bool { if case .actionRequired = result { return true }; return false }
    func isSignedOut(_ result: GitHubAuthResult) -> Bool { if case .signedOut = result { return true }; return false }

    // A1/A2: actual protected fake reads every 10 minutes; daily new owners share
    // only durable fake dependencies. Expected renewals are independent constants.
    for (days, renewals) in [(30, 91), (180, 551)] {
        let f = GHAuthFixture(); var owner = f.owner()
        check(f.protectedRead(f.login(owner)), "initial authorized read")
        for tick in 1...(days * 144) {
            f.now += 600
            if tick % 144 == 0 { owner = f.owner() }
            check(f.protectedRead(owner.ensureAccess(reason: "maintenance")), "healthy protected read")
        }
        check(f.counts["refresh_request", default: 0] == renewals, "healthy refresh count")
        check(f.counts["refresh_consumed", default: 0] == renewals, "healthy single-use count")
        check(f.counts["refresh_rejected", default: 0] == 0, "no healthy rejected refresh")
        check(f.counts["device_flow", default: 0] == 1, "one explicit login")
        check(f.counts["gist_authorized", default: 0] == days * 144 + 1, "authorized operation count")
        check(f.counts["user_authorized", default: 0] == renewals + 1, "validated identity count")
        check(f.manifest?.transition == nil, "healthy committed transition")
        check(f.publicStateIsNonsecret(owner), "no public credentials")
    }
    do {
        let f = GHAuthFixture(); let old = f.issue(legacy: true)
        f.legacyRead = .ready(GitHubCredentialV2(epoch: "legacy", generation: "legacy", accessToken: old.access,
            refreshToken: nil, obtainedAt: f.now, userID: "1001", login: old.login))
        for day in 0...180 {
            if day > 0 { f.now += 86400 }
            check(f.protectedRead(f.owner().ensureAccess(reason: "maintenance")), "legacy authorized read")
        }
        check(f.counts["refresh_request", default: 0] == 0, "legacy no refresh")
        check(f.counts["manifest_saved", default: 0] == 0 && f.counts["store_stage", default: 0] == 0, "legacy readonly")
        check(f.counts["device_flow", default: 0] == 0, "legacy no forced login")
    }
    for weeks in [2, 6] {
        let f = GHAuthFixture(); let owner = f.owner()
        check(isReady(f.login(owner)), "sleep initial login")
        let before = f.counts; f.now += Double(weeks * 7 * 86400)
        check(f.counts == before, "no work while asleep")
        check(f.protectedRead(f.owner().ensureAccess(reason: "wake")), "wake protected recovery")
        check(f.counts["refresh_consumed", default: 0] == 1, "one wake refresh")
    }
    // Parser contracts do not call the fixture transition logic.
    do {
        let f = GHAuthFixture(); let issued = f.issue()
        let invalid: [Any] = [true, false, NSNull(), Double.nan, Double.infinity, -1, 0, "28800", 1e30]
        for value in invalid {
            var body = issued.wire; body["expires_in"] = value; body["refresh_token_expires_in"] = value
            let c = GitHubAuthOwner.parse(body, epoch: "fixture-epoch", generation: "fixture-generation", now: f.now, rotating: true)
            check(c.kind == "credential" && c.accessToken == issued.access && c.refreshToken == issued.refresh, "unknown lifetime keeps pair")
            check(c.accessExpiresAt == nil && c.refreshExpiresAt == nil, "invalid lifetime stays unknown")
        }
        for missing in ["access_token", "refresh_token"] {
            var body = issued.wire; body.removeValue(forKey: missing)
            let c = GitHubAuthOwner.parse(body, epoch: "fixture-epoch", generation: "fixture-generation", now: f.now, rotating: true)
            check(c.kind == "incomplete", "partial not publishable")
            check(missing == "access_token" ? c.accessToken == nil : c.refreshToken == nil, "no secret mixing")
        }
    }
    let recoverable = ["before_intent", "after_intent", "after_request_started", "after_stage", "after_readback",
                       "before_identity", "after_identity", "before_publish", "after_publish", "before_retire", "after_retire"]
    for point in recoverable {
        let f = GHAuthFixture(); let owner = f.owner(); check(isReady(f.login(owner)), "checkpoint initial login")
        f.due(); f.checkpointAction[point] = { throw GHFixtureError.stopped }
        _ = owner.ensureAccess(reason: "maintenance")
        check(f.protectedRead(f.owner().ensureAccess(reason: "restart")), "checkpoint durable recovery " + point)
        check(f.counts["refresh_consumed", default: 0] == 1, "checkpoint no duplicate consumption")
        check(f.counts["refresh_request", default: 0] == 1, "checkpoint no duplicate POST")
        check(f.manifest?.transition == nil, "checkpoint committed")
    }
    for point in ["after_response", "after_parse"] {
        let f = GHAuthFixture(); let owner = f.owner(); check(isReady(f.login(owner)), "lost initial login")
        f.due(); f.checkpointAction[point] = { throw GHFixtureError.stopped }
        _ = owner.ensureAccess(reason: "maintenance")
        check(isAction(f.owner().ensureAccess(reason: "restart")), "lost response honest action")
        for _ in 0..<3 { f.now += 600; check(isAction(f.owner().ensureAccess(reason: "maintenance")), "lost no endless retries") }
        check(f.counts["refresh_request", default: 0] == 2, "one persisted unknown retry")
        check(f.counts["device_flow", default: 0] == 1, "no automatic device flow")
    }
    do {
        let f = GHAuthFixture(); var owner = f.owner(); check(isReady(f.login(owner)), "offline initial login"); f.due()
        for _ in 0..<5 {
            f.responseFaults.append(.notSent)
            check(isTemporary(owner.ensureAccess(reason: "maintenance")), "known offline temporary")
            check(f.manifest?.transition?.phase == "prepared", "known offline prepared")
            check(f.manifest?.transition?.recoveryAttempts == 0, "known offline excludes budget")
            f.now += 600; owner = f.owner()
        }
        check(f.counts["refresh_request", default: 0] == 0, "known offline no issuer call")
        check(f.protectedRead(owner.ensureAccess(reason: "maintenance")), "offline healed protected read")
    }
    do {
        let f = GHAuthFixture(); let owner = f.owner(); check(isReady(f.login(owner)), "unknown initial login"); f.due()
        f.responseFaults.append(.lost); check(isTemporary(owner.ensureAccess(reason: "maintenance")), "unknown temporary")
        f.now += 600; f.checkpointAction["after_request_started"] = { throw GHFixtureError.stopped }
        _ = f.owner().ensureAccess(reason: "restart")
        check(f.manifest?.transition?.recoveryAttempts == 1, "unknown budget durable before attempt")
        check(isAction(f.owner().ensureAccess(reason: "restart")), "unknown budget survives second restart")
        check(f.counts["refresh_request", default: 0] == 1, "budget blocks another issuer request")
    }
    do {
        let f = GHAuthFixture(); let owner = f.owner(); check(isReady(f.login(owner)), "identity initial login"); f.due()
        f.identityFault = .temporary
        check(isTemporary(owner.ensureAccess(reason: "maintenance")), "identity pending")
        let target = f.manifest?.transition?.to
        check(target != nil && f.items[target!] != nil, "candidate persists across identity error")
        f.now += 600; check(f.protectedRead(f.owner().ensureAccess(reason: "restart")), "identity healed read")
        check(f.manifest?.active == target, "same recovered target")
        check(f.counts["refresh_request", default: 0] == 1, "identity no repeat issuer")
    }
    for missing in ["access_token", "refresh_token"] {
        let f = GHAuthFixture(); let owner = f.owner(); check(isReady(f.login(owner)), "partial initial login")
        let active = f.manifest?.active; f.due(); f.responseFaults.append(.partial(missing))
        check(isAction(owner.ensureAccess(reason: "maintenance")), "partial action")
        check(f.manifest?.active == active, "partial never active")
        if let ref = f.manifest?.transition?.to, let candidate = f.items[ref] {
            check(candidate.kind == "incomplete", "partial candidate retained")
            check(missing == "access_token" ? candidate.accessToken == nil : candidate.refreshToken == nil, "partial not mixed")
        } else { check(false, "partial durable candidate absent") }
    }
    do {
        let f = GHAuthFixture(); let owner = f.owner(); check(isReady(f.login(owner)), "late initial login"); f.due()
        f.stageFault = { _, c in c.kind == "credential" ? .timeout : nil }
        check(isTemporary(owner.ensureAccess(reason: "maintenance")), "late stage temporary")
        let target = f.manifest?.transition?.to
        check(f.lateWrites.count == 1, "one late candidate writer")
        f.stageFault = nil; f.releaseLateWrites(); f.now += 600
        check(f.protectedRead(f.owner().ensureAccess(reason: "restart")), "late target recovered")
        check(f.manifest?.active == target, "late target published")
        check(f.counts["refresh_request", default: 0] == 1, "late no repeat refresh")
    }
    do {
        let f = GHAuthFixture(); let owner = f.owner(); check(isReady(f.login(owner)), "probe initial login"); f.due()
        let active = f.manifest?.active
        f.stageFault = { _, c in c.kind == "probe" ? .timeout : nil }
        check(isTemporary(owner.ensureAccess(reason: "maintenance")), "probe unavailable")
        if let t = f.manifest?.transition {
            check(t.to != active && t.probe != active && t.to != t.probe, "unique probe target active")
        } else { check(false, "probe intent absent") }
        check(f.counts["refresh_request", default: 0] == 0, "probe blocks issuer")
        f.stageFault = nil; f.releaseLateWrites(); f.now += 600
        check(f.protectedRead(f.owner().ensureAccess(reason: "restart")), "probe recovery")
    }
    do {
        let f = GHAuthFixture(); let owner = f.owner(); check(isReady(f.login(owner)), "logout initial login"); f.due()
        f.stageFault = { _, c in c.kind == "credential" ? .timeout : nil }
        _ = owner.ensureAccess(reason: "maintenance")
        let oldEpoch = f.manifest?.epoch
        let logout = owner.logoutDetailed()
        check(logout.accessDisabled && logout.cleanupPending, "local logout disabled with cleanup pending")
        check(owner.snapshot().cleanupPending, "late candidate logout presentation truthful")
        check(f.manifest?.epoch != oldEpoch && f.manifest?.signedOut == true, "logout new epoch")
        f.stageFault = nil; f.releaseLateWrites()
        check(isSignedOut(f.owner().ensureAccess(reason: "restart")), "late write cannot resurrect")
        check(f.manifest?.active == nil, "logout no active credential")
    }
    do {
        let f = GHAuthFixture(); let owner = f.owner(); check(isReady(f.login(owner)), "epoch initial login"); f.due()
        f.checkpointAction["before_publish"] = {
            f.manifest?.epoch = "new-epoch"; f.manifest?.signedOut = true
        }
        check(!isReady(owner.ensureAccess(reason: "maintenance")), "stale epoch cannot publish")
        check(f.manifest?.signedOut == true, "new tombstone preserved")
        let newer = f.owner(); check(f.protectedRead(f.login(newer)), "explicit replacement login")
        check(f.protectedRead(newer.ensureAccess(reason: "maintenance")), "new epoch healthy")
    }
    do {
        let f = GHAuthFixture(); let owner = f.owner(); check(isReady(f.login(owner)), "publish initial login"); f.due()
        let old = f.manifest?.active
        f.checkpointAction["before_publish"] = { f.failSave = true }
        check(isTemporary(owner.ensureAccess(reason: "maintenance")), "publish failure temporary")
        check(f.manifest?.active == old && f.manifest?.transition != nil, "atomic old pointer plus candidate")
        check(f.protectedRead(f.owner().ensureAccess(reason: "restart")), "publish recovery")
        check(f.counts["refresh_request", default: 0] == 1, "publish no repeat issuer")
    }
    do {
        let f = GHAuthFixture(); let owner = f.owner(); check(isReady(f.login(owner)), "terminal initial login")
        f.issuances[0].validRefresh = false; f.now += 8 * 3600 - 900
        let previous = f.manifest?.active
        let first = owner.ensureAccess(reason: "maintenance")
        check(isReady(first) && f.protectedRead(first), "FIRST bad refresh keeps usable access")
        check(f.manifest?.active == previous, "bad refresh preserves active generation")
        check(owner.snapshot().state == "renewalUnavailable" && owner.snapshot().reason == "bad_refresh_token", "bad refresh truthful usable presentation")
        check(f.counts["refresh_request", default: 0] == 1, "first bad refresh one request")
        check(f.protectedRead(f.owner().ensureAccess(reason: "maintenance")), "bad refresh usable access survives owner restart")
        check(f.counts["refresh_request", default: 0] == 1, "terminal renewal no repeated refresh while access usable")
        f.now += 900; check(isAction(f.owner().ensureAccess(reason: "maintenance")), "expired unusable access needs login")
        check(f.counts["device_flow", default: 0] == 1, "terminal no auto login")
    }
    do {
        let f = GHAuthFixture(); let owner = f.owner(); check(isReady(f.login(owner)), "storage initial login")
        let old = f.items; f.due(); f.readOverride = .unreachable
        check(isTemporary(owner.ensureAccess(reason: "maintenance")), "storage unavailable")
        check(f.items == old, "storage error preserves credentials")
        check(f.counts["refresh_request", default: 0] == 0, "storage error no issuer")
        f.readOverride = nil; f.now += 600
        check(f.protectedRead(f.owner().ensureAccess(reason: "maintenance")), "storage restored read")
        f.failLoad = true; check(isTemporary(owner.ensureAccess(reason: "maintenance")), "manifest unavailable")
        check(f.publicStateIsNonsecret(owner), "storage public state nonsecret")
    }
    do {
        let f = GHAuthFixture(); let owner = f.owner(); check(isReady(f.login(owner)), "lock initial login"); f.due()
        let old = f.items; f.lockHeld = true
        check(isTemporary(owner.ensureAccess(reason: "maintenance")), "busy lock temporary")
        check(f.items == old && f.counts["refresh_request", default: 0] == 0, "busy no writes or issuer")
        f.lockHeld = false
        check(f.protectedRead(owner.ensureAccess(reason: "unauthorized")), "access401 actual protected retry")
    }
    for status in [429, 503] {
        let f = GHAuthFixture(); let owner = f.owner(); check(isReady(f.login(owner)), "budget refusal initial login"); f.due()
        f.responseFaults = [.lost, .status(status, ["Retry-After": "60"])]
        check(isTemporary(owner.ensureAccess(reason: "maintenance")), "budget refusal unknown first")
        f.now += 600
        check(isTemporary(f.owner().ensureAccess(reason: "restart")), "budget refusal second temporary")
        check(f.manifest?.transition?.recoveryAttempts == 1, "refusal persisted consumed budget")
        f.now += 600
        check(isAction(f.owner().ensureAccess(reason: "restart")), "refusal cannot reopen budget")
        check(f.counts["refresh_request", default: 0] == 2, "refusal bounded issuer attempts")
    }
    do {
        let f = GHAuthFixture(); f.accessTTL = 1200
        let owner = f.owner(); check(isReady(f.login(owner)), "short TTL initial login")
        f.now += 899; check(f.protectedRead(owner.ensureAccess(reason: "maintenance")), "short TTL before fraction lead")
        check(f.counts["refresh_request", default: 0] == 0, "short TTL no early refresh")
        f.now += 1; check(f.protectedRead(owner.ensureAccess(reason: "maintenance")), "short TTL at fraction lead")
        check(f.counts["refresh_consumed", default: 0] == 1, "short TTL one refresh")
    }
    for point in ["after_identity", "before_publish"] {
        let f = GHAuthFixture(); let owner = f.owner()
        let epoch = owner.beginLogin(); check(epoch != nil, "cancel initial epoch")
        if let epoch = epoch {
            var current = true
            let issuance = f.issue(explicit: true)
            f.checkpointAction[point] = { current = false }
            check(isSignedOut(owner.completeLogin(response: issuance.wire, epoch: epoch, isCurrent: { current })), "cancel no publish")
            check(f.manifest?.active == nil && f.manifest?.transition == nil, "cancel clears candidate intent")
            check(!isReady(f.owner().ensureAccess(reason: "maintenance")), "cancel no maintenance resurrection")
            check(f.counts["device_flow", default: 0] == 1, "cancel no extra flow")
        }
    }
    do {
        let f = GHAuthFixture(); let owner = f.owner()
        let epoch = owner.beginLogin(); check(epoch != nil, "uncertain login initial epoch")
        if let epoch = epoch {
            let issuance = f.issue(explicit: true)
            f.stageFault = { _, c in c.kind == "credential" ? .timeout : nil }
            check(isTemporary(owner.completeLogin(response: issuance.wire, epoch: epoch)), "uncertain login stage")
            let target = f.manifest?.transition?.to
            let logout = owner.logoutDetailed()
            check(logout.accessDisabled && logout.cleanupPending, "uncertain login disabled with cleanup pending")
            check(!owner.logout(), "compatibility logout false while cleanup pending")
            check(target != nil && f.manifest?.cleanupRefs.contains(target!) == true, "uncertain login keeps late address")
            f.stageFault = nil; f.releaseLateWrites()
            check(isSignedOut(f.owner().ensureAccess(reason: "maintenance")), "uncertain login cannot resurrect")
        }
    }
    do {
        let f = GHAuthFixture(); let owner = f.owner(); check(isReady(f.login(owner)), "cleanup initial login"); f.due()
        f.checkpointAction["before_retire"] = { f.deleteFault = .locked }
        check(f.protectedRead(owner.ensureAccess(reason: "maintenance")), "cleanup locked active still usable")
        check(f.manifest?.cleanupRefs.isEmpty == false, "cleanup pending retained")
        let next = f.owner()
        check(f.protectedRead(next.ensureAccess(reason: "maintenance")), "cleanup pending next read")
        check(f.manifest?.cleanupRefs.isEmpty == true && !next.snapshot().cleanupPending, "healthy maintenance retries and clears settled cleanup")
    }
    // Reviewer C2: cancel during a timed-out first write must fence every owner,
    // including a fresh process with no process-local cancellation closure.
    do {
        let f = GHAuthFixture(); let owner = f.owner()
        if let epoch = owner.beginLogin(), let target = f.manifest?.transition?.to {
            var current = true
            let issuance = f.issue(explicit: true)
            f.stageFault = { _, c in
                if c.kind == "credential" { current = false; return .timeout }; return nil
            }
            check(isSignedOut(owner.completeLogin(response: issuance.wire, epoch: epoch, isCurrent: { current })), "timeout cancel returns signed out")
            check(f.manifest?.signedOut == true && f.manifest?.transition == nil && f.manifest?.active == nil, "timeout cancel durable tombstone")
            check(f.manifest?.cleanupRefs.contains(target) == true && owner.snapshot().cleanupPending, "timeout cancel retains uncertain writer address")
            check(isSignedOut(f.owner().ensureAccess(reason: "restart")), "timeout cancelled grant cannot resurrect across owner")
            f.stageFault = nil; f.releaseLateWrites(); f.now += 600
            let restarted = f.owner()
            check(isSignedOut(restarted.ensureAccess(reason: "maintenance")), "late cancelled write stays signed out")
            check(f.items[target] == nil && f.manifest?.cleanupRefs.isEmpty == true, "settled cancelled writer eventually collected")
            check(!restarted.snapshot().cleanupPending, "cancel cleanup presentation clears only after collection")
            check(f.counts["device_flow", default: 0] == 1 && f.counts["refresh_request", default: 0] == 0, "cancel no automatic grant or refresh")
        } else { check(false, "timeout cancel initial epoch absent") }
    }
    do {
        let f = GHAuthFixture(); let owner = f.owner()
        if let epoch = owner.beginLogin() {
            check(owner.abortLogin(epoch: epoch), "no-issuance device attempt can abort")
            check(f.manifest?.signedOut == true && f.manifest?.transition == nil, "no-issuance abort durable")
            check(isSignedOut(f.owner().ensureAccess(reason: "restart")), "aborted device flow does not become endless candidate")
            check(f.counts["device_flow", default: 0] == 0 && f.counts["refresh_request", default: 0] == 0, "no-issuance abort has no issued grant")
            let newer = f.owner()
            check(f.protectedRead(f.login(newer)), "explicit login available after device abort")
            let committed = f.manifest
            check(!owner.abortLogin(epoch: epoch) && !owner.cancelLogin(epoch: epoch), "old cancellation cannot cancel newer login")
            check(f.manifest == committed, "stale administrative request leaves new identity intact")
        } else { check(false, "no-issuance abort initial epoch absent") }
    }
    do {
        let f = GHAuthFixture(); let owner = f.owner()
        if let epoch = owner.beginLogin(), let target = f.manifest?.transition?.to {
            let issuance = f.issue(explicit: true)
            f.stageFault = { _, c in c.kind == "credential" ? .timeout : nil }
            check(isTemporary(owner.completeLogin(response: issuance.wire, epoch: epoch)), "uncertain candidate initial stage")
            check(!owner.abortLogin(epoch: epoch), "no-issuance abort cannot abandon uncertain issuance")
            check(f.manifest?.transition?.to == target, "uncertain issuance remains recovery eligible before explicit cancel")
            check(owner.cancelLogin(epoch: epoch), "explicit cancel fences pending same epoch candidate")
            f.stageFault = nil; f.releaseLateWrites(); f.now += 600
            check(isSignedOut(f.owner().ensureAccess(reason: "restart")), "explicit uncertain candidate cancel survives restart")
            check(f.items[target] == nil, "explicit cancellation eventually clears settled candidate")
        } else { check(false, "uncertain abort initial epoch absent") }
    }
    // Published identity is manifest-owned. A late raw envelope must neither
    // erase validated metadata nor turn account B into old account A.
    do {
        let f = GHAuthFixture(); let owner = f.owner()
        check(f.protectedRead(f.login(owner)), "identity authority initial read")
        if let active = f.manifest?.active, var late = f.items[active] {
            check(f.manifest?.userID == "1001" && f.manifest?.login == "fixture-user", "manifest atomically owns validated identity")
            late.userID = nil; late.login = nil; f.items[active] = late
            if case .ready(let read) = f.owner().readCredential() {
                check(read.userID == "1001" && read.login == "fixture-user", "late metadata-free payload cannot erase identity")
            } else { check(false, "metadata-free active payload lost access") }
            f.issuances[f.issuances.count - 1].login = "renamed-user"
            f.due(); let renamed = f.owner()
            check(f.protectedRead(renamed.ensureAccess(reason: "maintenance")), "stable user ID rename remains authorized")
            check(f.manifest?.userID == "1001" && f.manifest?.login == "renamed-user", "rename commits authoritative identity")
        } else { check(false, "identity authority active payload missing") }
        let switched = f.owner()
        if let epoch = switched.beginLogin() {
            let issuance = f.issue(explicit: true, userID: "2002", login: "account-b")
            check(f.protectedRead(switched.completeLogin(response: issuance.wire, epoch: epoch), userID: "2002"), "account B authorized commit")
            if let active = f.manifest?.active, var late = f.items[active] {
                late.userID = "1001"; late.login = "account-a"; f.items[active] = late
                let afterLate = f.owner()
                check(f.protectedRead(afterLate.ensureAccess(reason: "maintenance"), userID: "2002"), "late metadata cannot turn B into A")
                check(afterLate.snapshot().login == "account-b" && f.manifest?.userID == "2002", "late identity snapshot stays manifest-owned")
            } else { check(false, "account B active payload missing") }
        } else { check(false, "account B explicit epoch missing") }
    }
    do {
        let f = GHAuthFixture(); let owner = f.owner()
        check(isReady(f.login(owner)), "multi-writer cleanup initial login"); f.due()
        // One timed-out write is already readable, but another replay is still
        // pending. Readability must never stand in for completion of all writers.
        f.stageFault = { ref, c in
            if c.kind == "credential" { f.items[ref] = c; return .timeout }; return nil
        }
        check(!f.protectedRead(owner.ensureAccess(reason: "maintenance")), "uncertain timeout must not immediately re-read accessible pair")
        let readsAfterTimeout = f.counts["store_read", default: 0]
        let postsAfterTimeout = f.counts["refresh_request", default: 0]
        let retryBefore = f.manifest?.retryAt
        f.now += 599
        check(isTemporary(owner.ensureAccess(reason: "maintenance")), "uncertain candidate suppressed before exact cooldown boundary")
        check(f.counts["store_read", default: 0] == readsAfterTimeout, "no protected-store re-read at 599 seconds")
        check(f.counts["refresh_request", default: 0] == postsAfterTimeout && f.manifest?.retryAt == retryBefore,
              "suppressed candidate leaves issuer budget and durable retry unchanged")
        f.now += 1
        check(f.protectedRead(owner.ensureAccess(reason: "maintenance")), "readable uncertain pair can publish validated identity at 600 seconds")
        if let active = f.manifest?.active, let payload = f.items[active] {
            f.lateWrites.append((active, payload))
            _ = f.lateWrites.removeFirst()
            let logout = owner.logoutDetailed()
            check(logout.accessDisabled && logout.cleanupPending, "outstanding replay logout reports cleanup pending")
            check(owner.snapshot().state == "signedOut" && owner.snapshot().cleanupPending, "cleanup pending snapshot truthful")
            check(!owner.logout(), "Boolean logout is not success before physical cleanup")
            check(f.manifest?.cleanupRefs.contains(active) == true && f.manifest?.uncertainRefs.contains(active) == true, "readable generation address retained while another writer pending")
            f.stageFault = nil; f.releaseLateWrites(); f.now += 600
            let restarted = f.owner()
            check(isSignedOut(restarted.ensureAccess(reason: "maintenance")), "signed out maintenance runs eventual cleanup")
            check(f.items[active] == nil && f.manifest?.cleanupRefs.isEmpty == true && f.manifest?.uncertainRefs.isEmpty == true, "all settled generation writers permit final collection")
            check(!restarted.snapshot().cleanupPending && restarted.logout(), "Boolean logout true only after disabled and cleaned")
        } else { check(false, "multi-writer active payload missing") }
    }
    do {
        let f = GHAuthFixture(); f.legacyRead = .revoked
        let owner = f.owner()
        if case .revoked = owner.readCredential() { check(true, "legacy read preserves revoked type") }
        else { check(false, "legacy revoked read was reclassified") }
        check(isAction(owner.ensureAccess(reason: "maintenance")), "legacy revoked sign-in requires explicit action")
        check(owner.snapshot().state == "actionRequired" && owner.snapshot().reason == "revoked", "legacy revoked terminal presentation")
        check(f.counts["refresh_request", default: 0] == 0 && f.counts["device_flow", default: 0] == 0, "legacy revoked no automatic flow")
        check(f.protectedRead(f.login(owner)), "legacy revoked explicit recovery works")
    }
    do {
        let f = GHAuthFixture(); f.jitter = 30
        let owner = f.owner(); check(isReady(f.login(owner)), "positive jitter initial login"); f.due()
        for attempt in 1...4 {
            f.responseFaults.append(.notSent)
            let start = f.now
            check(isTemporary(f.owner().ensureAccess(reason: "maintenance")), "jitter known offline temporary")
            if let retryAt = f.manifest?.retryAt {
                check(retryAt > start && retryAt - start <= 600, "positive jitter automatic retry bounded by ten minutes")
                if attempt >= 3 { check(retryAt - start == 600, "maximum tier includes jitter within 600 cap") }
            } else { check(false, "jitter retry deadline absent") }
            f.now += 600
        }
        check(f.counts["refresh_request", default: 0] == 0, "positive jitter proven unsent no issuer consumption")
        check(f.protectedRead(f.owner().ensureAccess(reason: "maintenance")), "positive jitter automatically heals")
    }
    // Security cycle: a successful issuer response remains owned in memory if
    // manifest access fails before its first durable stage. Retry storage, not OAuth.
    do {
        let f = GHAuthFixture(); let owner = f.owner()
        check(isReady(f.login(owner)), "known-result manifest fault initial login"); f.due()
        f.checkpointAction["after_response"] = { f.failLoad = true }
        check(isTemporary(owner.ensureAccess(reason: "maintenance")), "known issuer result temporary manifest failure")
        let target = f.manifest?.transition?.to
        check(target != nil && f.items[target!] == nil, "known-result fault occurred before durable candidate")
        check(f.counts["refresh_consumed", default: 0] == 1, "known result issuer already consumed once")
        f.now += 600
        check(f.protectedRead(owner.ensureAccess(reason: "storage-retry")), "same owner retries retained result into durable storage")
        check(f.manifest?.active == target, "retained result commits original durable target")
        check(f.counts["refresh_request", default: 0] == 1 && f.counts["refresh_consumed", default: 0] == 1, "known result manifest failure no second OAuth")
    }
    do {
        let f = GHAuthFixture(); let owner = f.owner()
        if let epoch = owner.beginLogin() {
            let issued = f.issue(explicit: true)
            f.failLoad = true
            check(isTemporary(owner.completeLogin(response: issued.wire, epoch: epoch)), "known device result manifest failure is temporary")
            f.now += 600
            check(f.protectedRead(owner.ensureAccess(reason: "storage-retry")), "device result survives manifest retry in original owner")
            check(f.counts["device_flow", default: 0] == 1 && f.counts["refresh_request", default: 0] == 0, "known device result no second grant")
        } else { check(false, "known device result initial epoch absent") }
    }
    do {
        let f = GHAuthFixture(); let owner = f.owner()
        check(isReady(f.login(owner)), "live helper restart initial login"); f.due()
        f.stageFault = { _, c in c.kind == "credential" ? .timeout : nil }
        check(isTemporary(owner.ensureAccess(reason: "maintenance")), "live helper uncertain first stage")
        let target = f.manifest?.transition?.to
        check(target != nil && f.items[target!] == nil && f.lateWrites.count == 1, "helper still live and candidate currently missing")
        for _ in 0..<4 {
            f.now += 600
            check(isTemporary(f.owner().ensureAccess(reason: "restart")), "fresh owner waits for unsettled helper")
            check(f.manifest?.transition?.to == target, "unsettled helper durable address preserved")
            check(f.counts["refresh_request", default: 0] == 1 && f.counts["refresh_consumed", default: 0] == 1, "missing toRef cannot spend refresh while helper unsettled")
        }
        f.stageFault = nil; f.releaseLateWrites(); f.now += 600
        check(f.protectedRead(f.owner().ensureAccess(reason: "maintenance")), "settled helper candidate resumes authorized work")
        check(f.manifest?.active == target && f.counts["refresh_request", default: 0] == 1, "helper recovery publishes same result without OAuth reuse")
    }
    // Publication callback is memory-only and must execute while the injected
    // auth lock holds. Old account/epoch/generation cannot mutate the cache.
    do {
        let f = GHAuthFixture(); let owner = f.owner()
        let first = f.login(owner)
        var cacheMarker = 0, cacheEpoch: String?, cacheUserID: String?
        if case .ready(let oldAccess) = first {
            check(oldAccess.userID == "1001", "captured access has verified account identity")
            check(owner.snapshot().epoch == oldAccess.epoch && owner.snapshot().userID == oldAccess.userID, "public snapshot carries captured binding")
            check(owner.withCurrentAccess(oldAccess) {
                precondition(f.lockHeld, "memory publication escaped injected auth lock")
                cacheMarker = 1; cacheEpoch = oldAccess.epoch; cacheUserID = oldAccess.userID
            }, "current access admits memory cache publication")
            check(cacheMarker == 1 && cacheEpoch == f.manifest?.epoch && cacheUserID == f.manifest?.userID, "published memory cache belongs to current account")
            if let epoch = owner.beginLogin() {
                let issued = f.issue(explicit: true, userID: "2002", login: "account-b")
                let switched = owner.completeLogin(response: issued.wire, epoch: epoch)
                check(!owner.withCurrentAccess(oldAccess) { cacheMarker = 99 }, "old account cannot publish after account switch")
                check(cacheMarker == 1, "rejected old-account callback never runs")
                if case .ready(let current) = switched {
                    let forged = GitHubAuthAccess(token: current.token, epoch: current.epoch, generation: current.generation,
                                                  refreshable: current.refreshable, userID: "1001")
                    check(!owner.withCurrentAccess(forged) { cacheMarker = 99 }, "wrong user ID rejected even at current epoch and generation")
                    check(owner.withCurrentAccess(current) { cacheMarker = 2; cacheEpoch = current.epoch; cacheUserID = current.userID }, "new account publishes under current binding")
                    check(cacheMarker == 2 && cacheUserID == "2002" && cacheEpoch != oldAccess.epoch, "new memory cache binding excludes old account")
                    f.due()
                    let renewed = owner.ensureAccess(reason: "maintenance")
                    check(!owner.withCurrentAccess(current) { cacheMarker = 99 }, "retired generation cannot publish after refresh")
                    if case .ready(let rotated) = renewed {
                        check(owner.withCurrentAccess(rotated) { cacheMarker = 3 }, "new generation publication admitted")
                        _ = owner.logoutDetailed()
                        check(!owner.withCurrentAccess(rotated) { cacheMarker = 99 }, "logout fences captured publication")
                        check(cacheMarker == 3, "late logout callback never mutates cache")
                    } else { check(false, "publication fence renewed access missing") }
                } else { check(false, "publication fence account B access missing") }
            } else { check(false, "publication fence account B epoch missing") }
        } else { check(false, "publication fence initial access missing") }
    }
    do {
        let f = GHAuthFixture(); let issued = f.issue(legacy: true)
        f.legacyRead = .ready(GitHubCredentialV2(epoch: "legacy", generation: "legacy", accessToken: issued.access,
            refreshToken: nil, obtainedAt: f.now, userID: nil, login: "unverified-legacy-name"))
        let first = f.owner(); check(isReady(first.ensureAccess(reason: "maintenance")), "legacy access remains compatible")
        let snapshot = first.snapshot()
        check(snapshot.userID == nil, "legacy login string cannot fabricate verified user ID")
        check(snapshot.epoch?.hasPrefix("legacy-cache-") == true, "unverified legacy memory cache has ephemeral session binding")
        let restarted = f.owner(); check(isReady(restarted.ensureAccess(reason: "maintenance")), "legacy restart access works")
        check(restarted.snapshot().epoch != snapshot.epoch && restarted.snapshot().userID == nil, "legacy restart cannot reuse unbound durable cache identity")
        check(f.counts["refresh_request", default: 0] == 0 && f.counts["device_flow", default: 0] == 0, "legacy cache fence causes no OAuth")
    }
    // A durable identity-pending pair can outlive its access TTL. Recovery
    // consumes that pair's refresh, never the already-spent active predecessor.
    for origin in ["login", "refresh"] {
        for renamed in [false, true] {
            let f = GHAuthFixture(); f.accessTTL = 1200
            let owner = f.owner()
            if origin == "refresh" { check(isReady(f.login(owner)), "candidate successor refresh initial login"); f.due() }
            f.identityFault = .temporary
            let first = origin == "login" ? f.login(owner) : owner.ensureAccess(reason: "maintenance")
            check(isTemporary(first), "candidate successor initial identity transient")
            let source = f.manifest?.transition?.to
            check(source != nil && f.items[source!] != nil, "candidate successor source durably staged")
            if renamed { f.issuances[f.issuances.count - 1].login = "renamed-user" }
            f.now += 7200
            let restarted = f.owner()
            check(f.protectedRead(restarted.ensureAccess(reason: "restart")), "expired candidate successor authorizes protected read")
            check(f.manifest?.transition == nil && f.manifest?.active != source, "successor publishes only validated new generation")
            check(f.manifest?.userID == "1001" && f.manifest?.login == (renamed ? "renamed-user" : "fixture-user"), "successor immutable ID and rename")
            check(f.counts["refresh_request", default: 0] == (origin == "refresh" ? 2 : 1), "successor consumes candidate once")
            check(f.counts["refresh_rejected", default: 0] == 0 && f.counts["device_flow", default: 0] == 1, "successor never spends predecessor or repeats login")
            if let source { check(f.items[source] == nil, "settled unpublished predecessor retired") }
            check(f.publicStateIsNonsecret(restarted), "successor durable state nonsecret")
        }
    }
    do {
        let f = GHAuthFixture(); f.accessTTL = 1200; let owner = f.owner()
        check(isReady(f.login(owner)), "successor mismatch initial login"); f.due(); f.identityFault = .temporary
        check(isTemporary(owner.ensureAccess(reason: "maintenance")), "successor mismatch candidate staged")
        let active = f.manifest?.active; f.now += 7200
        // Model a persistent account change at the issuer, not one bad reply
        // followed by a healthy A identity. Every validation now returns B.
        f.issuances[f.issuances.count - 1].userID = "2002"
        f.issuances[f.issuances.count - 1].login = "account-b"
        let restarted = f.owner()
        check(isAction(restarted.ensureAccess(reason: "restart")), "successor different immutable account terminal")
        check(f.manifest?.active == active && f.manifest?.userID == "1001", "mismatch cannot publish new account")
        let requests = f.counts["refresh_request", default: 0]
        check(isAction(restarted.ensureAccess(reason: "maintenance")), "persistent mismatch remains action required")
        check(f.manifest?.active == active && f.manifest?.userID == "1001", "repeated mismatch preserves committed account fence")
        check(!f.protectedRead(restarted.ensureAccess(reason: "maintenance"), userID: "2002"), "mismatch cannot grant protected read even with valid B bearer")
        check(f.counts["refresh_request", default: 0] == requests, "identity revalidation cannot spend another grant")
        // A later fresh, authorized /user for the original immutable ID may
        // recover this same durable pair; the prior mismatched response alone
        // must never publish B or permit account-scoped cache publication.
        let knownEpoch = f.manifest?.epoch
        let candidate = f.manifest?.transition?.to
        let identities = f.counts["user_authorized", default: 0]
        f.issuances[f.issuances.count - 1].userID = "1001"
        f.issuances[f.issuances.count - 1].login = "verified-account-a"
        let healed = restarted.ensureAccess(reason: "maintenance")
        check(f.protectedRead(healed), "fresh verified original identity heals same durable candidate")
        check(f.counts["user_authorized", default: 0] == identities + 1
              && f.counts["refresh_request", default: 0] == requests,
              "healing requires fresh protected user verification without another OAuth")
        check(f.manifest?.epoch == knownEpoch && f.manifest?.active == candidate
              && f.manifest?.userID == "1001" && f.manifest?.login == "verified-account-a",
              "healed publication retains known epoch and immutable original account")
        if case .ready(let access) = healed {
            var publishedUser: String?, publishedEpoch: String?
            check(restarted.withCurrentAccess(access) {
                precondition(f.lockHeld, "healed cache callback escaped auth lock")
                publishedUser = access.userID; publishedEpoch = access.epoch
            }, "healed same-account access admits fenced memory cache publication")
            check(publishedUser == "1001" && publishedEpoch == knownEpoch, "healed cache cannot acquire mismatched B binding")
        } else { check(false, "healed access unavailable for fenced cache publication") }
    }
    for action in ["cancel", "supersede", "lost"] {
        let f = GHAuthFixture(); f.accessTTL = 1200; let owner = f.owner()
        f.identityFault = .temporary
        check(isTemporary(f.login(owner)), "successor administrative candidate staged")
        let source = f.manifest?.transition?.to; let epoch = f.manifest?.epoch
        f.now += 7200
        if action == "cancel", let epoch {
            check(owner.cancelLogin(epoch: epoch), "cancel expired pending explicit login")
            check(isSignedOut(f.owner().ensureAccess(reason: "restart")), "cancelled successor stays signed out")
            check(f.counts["refresh_request", default: 0] == 0, "cancel before successor spends no refresh")
        } else if action == "supersede", let nextEpoch = owner.beginLogin() {
            let next = f.issue(explicit: true, userID: "2002", login: "account-b")
            check(f.protectedRead(owner.completeLogin(response: next.wire, epoch: nextEpoch), userID: "2002"), "superseding B login owns protected read")
            check(f.manifest?.userID == "2002" && f.manifest?.active != source, "superseding B fenced old pending candidate")
            check(f.counts["refresh_request", default: 0] == 0, "superseding login does not revive old refresh")
        } else if action == "lost" {
            f.responseFaults = [.lost]
            check(isTemporary(f.owner().ensureAccess(reason: "restart")), "successor lost response temporary")
            for _ in 0..<4 { f.now += 600; _ = f.owner().ensureAccess(reason: "restart") }
            let restarted = f.owner()
            check(isAction(restarted.ensureAccess(reason: "maintenance")), "successor unknown budget becomes terminal")
            check(f.counts["refresh_request", default: 0] <= 2 && f.counts["refresh_consumed", default: 0] == 1, "successor durable unknown budget never resets on restart")
            check(f.counts["device_flow", default: 0] == 1, "unknown successor never opens device flow")
        } else { check(false, "successor administrative fixture lacked epoch") }
    }
    // A readable probe with an unacknowledged writer is not proof that a
    // preflight completed. Every restart must wait without spending any grant.
    do {
        let f = GHAuthFixture(); let owner = f.owner()
        check(isReady(f.login(owner)), "readable unsettled probe initial login"); f.due()
        f.stageFault = { ref, value in
            if value.kind == "probe" { f.items[ref] = value; return .timeout }
            return nil
        }
        check(isTemporary(owner.ensureAccess(reason: "maintenance")), "readable unsettled probe pauses OAuth")
        let probe = f.manifest?.transition?.probe
        check(probe != nil && f.items[probe!] != nil && !f.lateWrites.isEmpty, "probe readable before writer acknowledgement")
        for _ in 0..<3 {
            f.now += 600
            check(isTemporary(f.owner().ensureAccess(reason: "restart")), "readable unsettled probe restart still waits")
            check(f.counts["refresh_request", default: 0] == 0, "readable unsettled probe zero OAuth")
        }
        f.stageFault = nil; f.releaseLateWrites(); f.now += 600
        check(f.protectedRead(f.owner().ensureAccess(reason: "maintenance")), "probe acknowledgement resumes protected work")
        check(f.counts["refresh_request", default: 0] == 1, "settled preflight grants one refresh")
    }
    // New permit journals can prove no helper invocation; old uncertain refs
    // cannot acquire that proof merely because our memory store is empty.
    for newProtocol in [false, true] {
        let f = GHAuthFixture(); let ref = GitHubAuthRef(generation: UUID().uuidString.lowercased())
        f.manifest = GitHubAuthManifest(epoch: "fixture-proof-nosend", cleanupRefs: [ref], signedOut: true,
            uncertainRefs: [ref], permitWriterRefs: newProtocol ? [ref] : nil)
        let result = f.owner().logoutDetailed()
        check(result.accessDisabled, "no-send administrative access disabled")
        check(result.cleanupPending == !newProtocol, "only explicit permit plus no invocation proves safe cleanup")
        if newProtocol {
            check(f.deleteAttempts.contains(ref) && f.manifest?.cleanupRefs.contains(ref) == false,
                  "proven no-send ref is physically deleted and retired")
        } else {
            // Deletion is an idempotent cleanup attempt, not evidence that a
            // daemon cannot replay later. The durable address must survive it.
            check(f.manifest?.cleanupRefs.contains(ref) == true && f.manifest?.uncertainRefs.contains(ref) == true,
                  "unknown old journal retains address and uncertainty after cleanup attempts")
            let late = f.issue()
            f.items[ref] = GitHubCredentialV2(epoch: "fixture-old-writer", generation: ref.generation,
                accessToken: late.access, refreshToken: late.refresh, obtainedAt: f.now)
            check(isSignedOut(f.owner().ensureAccess(reason: "restart")), "late old writer cannot revive disabled epoch")
            check(f.manifest?.cleanupRefs.contains(ref) == true && f.manifest?.uncertainRefs.contains(ref) == true,
                  "readable late replay cannot establish helper completion")
            f.settledWriterRefs.insert(ref) // Independent fake backend completion acknowledgement.
            let completed = f.owner().logoutDetailed()
            check(completed.accessDisabled && !completed.cleanupPending && f.items[ref] == nil,
                  "old journal completes GC only after actual helper acknowledgement")
        }
    }
    // Preserve the explicit device-attempt fence through /user401 -> staged
    // candidate successor -> publication. A final outer cleanup cannot undo a
    // forbidden durable publish if the process dies immediately afterwards.
    do {
        let f = GHAuthFixture(); let owner = f.owner()
        if let epoch = owner.beginLogin() {
            let issued = f.issue(explicit: true)
            var current = true, observedForbiddenPublish = false
            var candidateRefs: Set<GitHubAuthRef> = []
            f.identityFault = .unauthorized
            f.checkpointAction["before_publish"] = {
                current = false
                candidateRefs = Set(f.items.filter { $0.value.kind == "credential" }.map { $0.key })
                f.persistentDeleteFault = .timeout
            }
            f.checkpointAction["after_publish"] = { observedForbiddenPublish = f.manifest?.active != nil }
            let result = owner.completeLogin(response: issued.wire, epoch: epoch, isCurrent: { current })
            check(!isReady(result) && !observedForbiddenPublish, "cancelled successor never durably publishes even transiently")
            check(f.manifest?.signedOut == true && f.manifest?.active == nil && f.manifest?.transition == nil, "cancelled successor durable tombstone")
            check(candidateRefs.count == 2 && candidateRefs.isSubset(of: Set(f.manifest?.cleanupRefs ?? [])), "both issued candidate generations retained until cleanup succeeds")
            check(f.counts["refresh_request", default: 0] == 1 && f.counts["device_flow", default: 0] == 1, "cancelled chain one successor grant")
            check(isSignedOut(f.owner().ensureAccess(reason: "restart")), "cancelled successor stays disabled after restart")
            f.persistentDeleteFault = nil
            // GC processes at most three refs per operation. Probe/source/target
            // and legacy refs can require several bounded maintenance cycles.
            let tombstoneEpoch = f.manifest?.epoch
            let grants = f.counts["refresh_request", default: 0]
            let refsToClean = f.manifest?.cleanupRefs.count ?? 0
            let cleaner = f.owner()
            for _ in 0...refsToClean {
                f.now += 60
                check(isSignedOut(cleaner.ensureAccess(reason: "maintenance")), "cancelled successor bounded GC remains disabled")
                check(f.manifest?.epoch == tombstoneEpoch && f.manifest?.active == nil,
                      "cancelled successor GC preserves durable disabled epoch")
                if f.manifest?.cleanupRefs.isEmpty == true { break }
            }
            check(cleaner.snapshot().cleanupPending == false && f.manifest?.cleanupRefs.isEmpty == true
                  && candidateRefs.allSatisfy { f.items[$0] == nil } && f.items.isEmpty,
                  "cancelled successor eventual confirmed cleanup includes every candidate and probe")
            check(f.counts["refresh_request", default: 0] == grants && f.counts["device_flow", default: 0] == 1,
                  "cancelled successor GC cannot renew or reopen device flow")
        } else { check(false, "cancelled successor fixture epoch missing") }
    }
    // KEYCHAIN-RETRY: external call counts and two independent clocks are the oracle.
    for fault in [GitHubAuthRead.locked, .timeout, .unreachable] {
        let f = GHAuthFixture(); f.monotonicNow = 1000
        let owner = f.owner()
        check(isReady(f.login(owner)), "cooldown fixture explicitly signed in")
        f.readOverride = fault
        check(isTemporary(owner.ensureAccess(reason: "maintenance")), "protected-store access failure remains temporary")
        let reads = f.counts["store_read", default: 0]
        let stages = f.counts["store_stage", default: 0]
        let deletes = f.counts["store_delete_attempt", default: 0]
        let posts = f.counts["refresh_request", default: 0]
        let epoch = f.manifest?.epoch
        let retry = f.manifest?.retryAt
        check(owner.keychainRetryDelay() == 600, "cooldown deadline from failure completion")
        f.now += 86400 // advancing wall clock must not admit a Keychain request
        check(isTemporary(owner.ensureAccess(reason: "startup")), "wall forward does not bypass monotonic cooldown")
        f.now -= 172800 // nor may rollback extend it indefinitely
        check(isTemporary(owner.ensureAccess(reason: "maintenance")), "wall rollback does not bypass cooldown")
        f.monotonicNow = 1599
        check(isTemporary(owner.ensureAccess(reason: "background_sync")), "multiple background callers suppressed at 599")
        check(owner.keychainRetryDelay() == 1, "relative monotonic delay independent of wall clock")
        check(f.counts["store_read", default: 0] == reads && f.counts["store_stage", default: 0] == stages
              && f.counts["store_delete_attempt", default: 0] == deletes, "suppressed operation never touches any protected-store adapter")
        check(f.counts["refresh_request", default: 0] == posts && f.counts["device_flow", default: 0] == 1,
              "suppression never starts OAuth or new login")
        check(f.manifest?.epoch == epoch && f.manifest?.retryAt == retry && f.manifest?.signedOut == false,
              "access cooldown does not rewrite issuer backoff or sign out")
        f.monotonicNow = 1600; f.readOverride = nil
        check(f.protectedRead(owner.ensureAccess(reason: "maintenance")), "automatic access recovers at exact monotonic boundary")
        check(f.counts["store_read", default: 0] > reads && owner.keychainRetryDelay() == nil,
              "successful protected-store access clears runtime cooldown")
    }
    do {
        let f = GHAuthFixture(); f.monotonicNow = 1000
        let owner = f.owner(); check(isReady(f.login(owner)), "manual retry fixture signed in")
        f.readOverride = .locked
        check(isTemporary(owner.ensureAccess(reason: "maintenance")), "manual retry begins with actual failed probe")
        f.monotonicNow = 1001
        check(isTemporary(owner.retryKeychainAccess()), "failed explicit retry remains temporary")
        let reads = f.counts["store_read", default: 0]
        check(owner.keychainRetryDelay() == 600, "explicit failure starts bounded cooldown from its completion")
        check(isTemporary(owner.ensureAccess(reason: "background_sync")), "manual permit cannot leak into next background call")
        check(f.counts["store_read", default: 0] == reads, "background never inherits explicit read permit")
        f.readOverride = nil
        check(f.protectedRead(owner.retryKeychainAccess()), "explicit recovery can read before automatic deadline")
        check(owner.keychainRetryDelay() == nil, "successful explicit read clears gate")
        check(f.counts["device_flow", default: 0] == 1 && f.counts["refresh_request", default: 0] == 0,
              "explicit retry does not replace login or consume refresh")
    }
    print("AUTH SELFTEST: \(checks) checks, \(failed) failures (synthetic dependencies only)")
    if failed > 0 { exit(1) }
}
