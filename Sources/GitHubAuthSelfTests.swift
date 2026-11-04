import Foundation
#if os(macOS)
import Security
import Darwin
#endif

// Independent issuer and in-memory dependency oracle: core tests create no
// production singleton, URLSession, Keychain, AppDelegate or preferences.
// The opt-in offline sync harness writes only a UUID-named temporary cache.
// The separately invoked K341 adapter suite has one macOS integration probe;
// every real security/native query there is scoped to its fresh temporary keychain.
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
    var readForRef: ((GitHubAuthRef) -> GitHubAuthRead?)?
    var readOverride: GitHubAuthRead?
    var interactiveRead: ((GitHubAuthRef) -> GitHubAuthRead)?
    var interactiveStage: ((GitHubAuthRef, GitHubCredentialV2) -> GitHubAuthStoreStatus)?
    var interactiveDelete: ((GitHubAuthRef) -> GitHubAuthStoreStatus)?
    var interactiveLegacyRead: (() -> GitHubAuthRead)?
    var storeTrace: [(operation: String, ref: GitHubAuthRef, interactive: Bool)] = []
    var idle = true
    var stageFault: ((GitHubAuthRef, GitHubCredentialV2) -> GitHubAuthStoreStatus?)?
    var deleteFault: GitHubAuthStoreStatus?
    var persistentDeleteFault: GitHubAuthStoreStatus?
    var deleteAdapter: ((GitHubAuthRef) -> GitHubAuthStoreStatus)?
    var cleanupPreflightFault: ((GitHubAuthRef) -> GitHubAuthStoreStatus?)?
    var usesSecurityWriter = false
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
                self.storeTrace.append(("read", ref, false))
                self.record("store_read")
                if let fault = self.readForRef?(ref) { return fault }
                if let fault = self.readOverride { return fault }
                return self.items[ref].map { .ready($0) } ?? .missing
            },
            stageStore: {
                self.storeTrace.append(("stage", $0, false))
                return self.stage($0, $1)
            },
            deleteStore: { ref in
                self.storeTrace.append(("delete", ref, false))
                self.record("store_delete_attempt"); self.deleteAttempts.append(ref)
                if let fault = self.persistentDeleteFault { return fault }
                if let fault = self.deleteFault { self.deleteFault = nil; return fault }
                if let adapter = self.deleteAdapter { return adapter(ref) }
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
            }, jitter: { self.jitter }, legacy: {
                self.storeTrace.append(("read", GitHubAuthRef(generation: "legacy", backend: "legacy-keychain"), false))
                return self.legacyRead
            },
            settled: { ref in
                if let override = self.settlementOverride { return override }
                guard !self.lateWrites.contains(where: { $0.0 == ref }) else { return false }
                let noSend = (self.manifest?.permitWriterRefs ?? []).contains(ref) && !self.startedWriterRefs.contains(ref)
                return self.settledWriterRefs.contains(ref) || noSend
            }, monotonicClock: { self.monotonicNow ?? self.now },
            interactiveReadStore: { ref, action in
                guard action.admit({ self.storeTrace.append(("read", ref, true)) }) else { return .locked }
                if let result = self.interactiveRead?(ref) { return result }
                if let fault = self.readForRef?(ref) { return fault }
                if let fault = self.readOverride { return fault }
                return self.items[ref].map { .ready($0) } ?? .missing
            }, interactiveStageStore: { ref, credential, action in
                guard action.admit({ self.storeTrace.append(("stage", ref, true)) }) else { return .locked }
                return self.interactiveStage?(ref, credential) ?? .locked
            }, interactiveDeleteStore: { ref, action in
                guard action.admit({ self.storeTrace.append(("delete", ref, true)) }) else { return .locked }
                return self.interactiveDelete?(ref) ?? .locked
            }, interactiveLegacy: { action in
                guard action.admit({ self.storeTrace.append(("read", GitHubAuthRef(generation: "legacy", backend: "legacy-keychain"), true)) }) else { return .locked }
                return self.interactiveLegacyRead?() ?? self.legacyRead
            }, storeIdle: { self.idle }, cleanupPreflight: { ref in
                self.storeTrace.append(("attributes", ref, false)); self.record("store_attributes")
                return self.cleanupPreflightFault?(ref) ?? .success
            }, usesSecurityWriter: usesSecurityWriter)
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
    func checkPermissionGate(_ fixture: GHAuthFixture, _ owner: GitHubAuthOwner, _ label: String) {
        let operations = fixture.storeTrace.count
        check(isTemporary(owner.ensureAccess(reason: "restart")), label + " still requires explicit permission")
        check(fixture.storeTrace.count == operations && owner.snapshot().reason == "permission_required"
              && owner.keychainRetryDelay() == .infinity && fixture.manifest?.keychainPermissionRequired == true,
              label + " persisted permission gate suppresses all credential adapters")
    }
    // 3.4.1 review B: only a background READ timeout means a hidden permission prompt.
    func checkWriteTimeoutBounded(_ fixture: GHAuthFixture, _ owner: GitHubAuthOwner, _ label: String) {
        check(owner.snapshot().reason != "permission_required" && owner.keychainRetryDelay() != .infinity
              && fixture.manifest?.keychainPermissionRequired != true,
              label + " write timeout keeps bounded self-healing gate, never the permission latch")
    }

    // KEYCHAIN-QUIET: actual helper bootstrap policy with fake native/configure
    // closures. No compiled test path here contains Security, Process or app startup.
    for interactive in [false, true] {
        for failAt in [0, 1, 2] {
            var trace: [String] = [], configureCalls = 0
            let status = githubAuthHelperInteraction(interactive: interactive, setAllowed: { allowed in
                configureCalls += 1; trace.append(allowed ? "allow" : "forbid")
                return configureCalls != failAt
            }, operation: { trace.append("native"); return 36 })
            let failedSetup = failAt == 1 || (interactive && failAt == 2)
            check(status == (failedSetup ? 70 : 36), "helper setup fails closed, native denial stays denial")
            check(trace.first == "forbid" && trace.filter { $0 == "native" }.count == (failedSetup ? 0 : 1),
                  "helper forbids UI before any native operation, failed setup reaches zero RPCs")
            check(interactive || !trace.contains("allow"), "quiet helper never enables UI")
        }
    }
    do {
        let v2 = GitHubAuthRef(generation: "11223344-5566-7788-99aa-bbccddeeff00")
        let legacy = GitHubAuthRef(generation: "legacy", backend: "legacy-keychain")
        for ref in [v2, legacy] {
            for operation in ["read", "delete"] {
                let args = githubAuthKeychainArguments(operation: operation, ref: ref)!
                let request = GitHubKeychainHelperRequest.parse(["fixture"] + args)
                check(request?.interactive == false && request?.generation == ref.generation,
                      "actual invocation constructor defaults quiet and binds generation")
                check(request?.service == (ref == legacy ? "Claude Codex Limits GitHub" : "Claude Codex Limits GitHub Credential V2"),
                      "helper cannot select an arbitrary service")
                check(!args.joined().contains("ccl-test-access-"), "argv has only nonsecret operation metadata")
            }
        }
        for generation in ["", "../escape", "not-a-uuid", "legacy", v2.generation.uppercased()] {
            check(githubAuthKeychainArguments(operation: "read", ref: GitHubAuthRef(generation: generation)) == nil,
                  "invalid V2 account rejected before process creation")
        }
        check(githubAuthKeychainArguments(operation: "legacy-write", ref: legacy, interactive: true) == nil,
              "legacy compatibility writer cannot request interaction")
        check(GitHubKeychainHelperRequest.parse(["fixture", "--github-auth-keychain-helper", "read", v2.generation]) == nil,
              "missing policy cannot default to interactive")
        check(GitHubKeychainHelperRequest.parse(["fixture", "--github-auth-keychain-helper", "read", v2.generation, "quiet", "--auth-selftest"]) == nil,
              "mixed helper flags fail closed")
    }
    // Successful background accesses, time passage and fresh owners do not grant UI.
    do {
        let f = GHAuthFixture(); let owner = f.owner()
        check(isReady(f.login(owner)), "quiet successful fixture login")
        f.storeTrace.removeAll()
        for reason in ["startup", "wake", "background_sync", "maintenance"] {
            f.now += 601
            check(isReady(owner.ensureAccess(reason: reason)), "successful background access stays usable")
        }
        check(f.storeTrace.count >= 4 && !f.storeTrace.contains { $0.interactive },
              "successful reads reach quiet boundary on every tick")
        f.readOverride = .locked
        let epoch = f.manifest?.epoch, active = f.manifest?.active
        for _ in 0..<3 {
            f.now += 601
            check(isTemporary(f.owner().ensureAccess(reason: "startup")), "fresh process remains unavailable without prompting")
        }
        check(!f.storeTrace.contains { $0.interactive } && f.manifest?.epoch == epoch && f.manifest?.active == active,
              "restart and expired cooldown preserve credentials with no interactive fallback")
    }
    for interactiveResult in [GitHubAuthRead.locked, .timeout, .unreachable] {
        let f = GHAuthFixture(); let owner = f.owner()
        check(isReady(f.login(owner)), "explicit denial fixture login")
        let saved = f.manifest
        f.readOverride = .locked
        var nested: GitHubAuthResult?
        f.interactiveRead = { _ in nested = owner.retryKeychainAccess(); return interactiveResult }
        f.storeTrace.removeAll()
        check(isTemporary(owner.retryKeychainAccess()), "deny/cancel/timeout remain temporary")
        check(nested.map(isTemporary) == true && f.storeTrace.filter { $0.interactive }.count == 1,
              "contending manual action coalesced while one prompt is active")
        check(f.manifest == saved, "denial preserves active epoch and complete pair metadata")
        for _ in 0..<3 { f.now += 601; _ = owner.ensureAccess(reason: "wake") }
        check(f.storeTrace.filter { $0.interactive }.count == 1, "denial never schedules interactive retries")
    }
    // One interactive source read cannot authorize a later quiet candidate
    // timeout in the same manual pass to schedule more background reads.
    do {
        let f = GHAuthFixture(); let owner = f.owner()
        check(isReady(f.login(owner)), "K341-manual quiet read initial login")
        if let active = f.manifest?.active, let existing = f.items[active] {
            let candidate = GitHubAuthRef(generation: UUID().uuidString.lowercased())
            f.manifest!.transition = GitHubAuthTransition(from: active, to: candidate, phase: "prepared")
            f.manifest!.keychainPermissionRequired = true
            f.interactiveRead = { ref in ref == active ? .ready(existing) : .locked }
            f.readForRef = { ref in ref == candidate ? .timeout : nil }
            f.storeTrace.removeAll()
            check(isTemporary(owner.retryKeychainAccess()) && owner.snapshot().reason == "permission_required"
                  && owner.keychainRetryDelay() == .infinity && f.manifest?.keychainPermissionRequired == true,
                  "K341-manual quiet candidate timeout restores permission latch after successful interactive source")
            check(f.storeTrace.count == 2 && f.storeTrace[0].ref == active && f.storeTrace[0].interactive
                  && f.storeTrace[1].ref == candidate && !f.storeTrace[1].interactive,
                  "K341-manual source uses user permission; candidate timeout is a separate quiet read")
            f.now += 601
            checkPermissionGate(f, owner, "K341-manual quiet read after 601 seconds")
            let restarted = f.owner()
            checkPermissionGate(f, restarted, "K341-manual quiet read after restart")
            check(f.counts["refresh_request", default: 0] == 0 && f.counts["device_flow", default: 0] == 1,
                  "K341-manual quiet read timeout and suppressed retries spend no issuer grant")
            f.readForRef = nil
            check(f.protectedRead(restarted.retryKeychainAccess()) && f.manifest?.active == candidate,
                  "K341-manual quiet read recovers original prepared candidate through explicit retry")
            check(f.counts["refresh_request", default: 0] == 1 && f.counts["refresh_consumed", default: 0] == 1
                  && f.counts["device_flow", default: 0] == 1 && f.manifest?.keychainPermissionRequired != true,
                  "K341-manual quiet read recovery spends exactly one refresh and clears permission latch")
        } else { check(false, "K341-manual quiet read active fixture missing") }
    }
    // A requestStarted transition cannot silently become missing/revoked or issue
    // another OAuth POST merely because the candidate/source needs permission.
    do {
        let f = GHAuthFixture(); let owner = f.owner()
        check(isReady(f.login(owner)), "requestStarted fixture login")
        let candidate = GitHubAuthRef(generation: UUID().uuidString.lowercased())
        f.manifest!.transition = GitHubAuthTransition(from: f.manifest!.active, to: candidate, phase: "requestStarted")
        let before = f.manifest, grants = f.counts["refresh_request", default: 0]
        f.readForRef = { ref in ref == candidate ? .missing : .locked }
        f.storeTrace.removeAll()
        check(isTemporary(owner.ensureAccess(reason: "startup")), "in-flight source blocked in background")
        check(isTemporary(owner.retryKeychainAccess()), "manual in-flight denial remains pending")
        check(f.manifest == before && f.counts["refresh_request", default: 0] == grants,
              "interaction failure preserves transition and issuer budget")
        check(f.storeTrace.filter { $0.interactive }.count == 1
              && f.storeTrace.first { $0.interactive }?.ref == before?.active,
              "missing candidate does not waste permit needed by source generation")
    }
    // Signed-out cleanup never borrows a manual read permit: metadata and delete
    // remain quiet for every generation, including an explicit retry.
    do {
        let f = GHAuthFixture(); let owner = f.owner()
        check(isReady(f.login(owner)), "GC permit fixture login")
        f.cleanupPreflightFault = { _ in .locked }
        _ = owner.logoutDetailed()
        let refs = f.manifest!.cleanupRefs, epoch = f.manifest!.epoch
        f.persistentDeleteFault = .locked
        f.storeTrace.removeAll()
        check(isSignedOut(owner.retryKeychainAccess()), "manual cleanup keeps tombstone")
        check(!f.storeTrace.contains { $0.interactive || $0.operation == "read" }
              && f.storeTrace.contains { $0.operation == "attributes" },
              "manual cleanup reaches only quiet metadata, never a secret read or prompt")
        check(Set(f.manifest!.cleanupRefs) == Set(refs) && f.manifest?.epoch == epoch,
              "blocked delete retains every pending ref and tombstone")
        f.now += 601; _ = f.owner().ensureAccess(reason: "startup")
        check(!f.storeTrace.contains { $0.interactive || $0.operation == "read" }, "cleanup stays quiet across restart")
    }
    // beginLogin is manual, but its first probe write is still quiet. A write
    // timeout is the bounded timeout class (600 s), never the permission latch.
    do {
        let f = GHAuthFixture(); let owner = f.owner()
        f.stageFault = { _, credential in credential.kind == "probe" ? .timeout : nil }
        check(owner.beginLogin() == nil && owner.snapshot().reason == "timeout"
              && owner.keychainRetryDelay() == 600 && f.manifest?.keychainPermissionRequired != true,
              "K341-login quiet probe write timeout keeps bounded timeout gate despite manual pass")
        check(f.storeTrace.map { $0.operation } == ["read", "stage"]
              && !f.storeTrace.contains { $0.interactive } && f.lateWrites.count == 1,
              "K341-login quiet timed-out probe never launches interactive fallback or readback")
        f.now += 601
        checkWriteTimeoutBounded(f, owner, "K341-login quiet probe after 601 seconds")
        check(owner.keychainRetryDelay() == 0, "K341-login probe write-timeout cooldown elapses after 600 seconds")
        let restarted = f.owner()
        checkWriteTimeoutBounded(f, restarted, "K341-login quiet probe after restart")
        check(restarted.keychainRetryDelay() == nil, "K341-login write timeout persists no gate across restart")
        check(f.counts["device_flow", default: 0] == 0 && f.counts["refresh_request", default: 0] == 0,
              "K341-login timed-out probe consumes no issuer grant")

        f.stageFault = nil; f.releaseLateWrites(); f.storeTrace.removeAll()
        if let epoch = restarted.beginLogin() {
            check(restarted.snapshot().state == "loginPending" && restarted.keychainRetryDelay() == nil
                  && f.manifest?.keychainPermissionRequired != true,
                  "K341-login successful quiet probe leaves no persisted or runtime gate")
            check(f.storeTrace.map { $0.operation } == ["read", "stage", "read"]
                  && !f.storeTrace.contains { $0.interactive },
                  "K341-login recovery probe succeeds quietly without spending user interaction")
            let issued = f.issue(explicit: true)
            check(f.protectedRead(restarted.completeLogin(response: issued.wire, epoch: epoch))
                  && f.manifest?.epoch == epoch && f.manifest?.transition == nil
                  && f.manifest?.active != nil && f.manifest?.keychainPermissionRequired != true,
                  "K341-login recovered probe preserves completeLogin and usable credential publication")
            check(f.counts["device_flow", default: 0] == 1 && f.counts["refresh_request", default: 0] == 0
                  && !f.storeTrace.contains { $0.interactive },
                  "K341-login recovery spends exactly one explicit grant and persists issued tokens quietly")
        } else { check(false, "K341-login successful quiet probe failed to begin recovery login") }
    }
    // A timeout returned by the actual interactive probe retains its bounded
    // cooldown instead of being reclassified as a quiet permission timeout.
    do {
        let f = GHAuthFixture(); let owner = f.owner()
        f.stageFault = { _, _ in .locked }
        f.interactiveStage = { _, _ in .timeout }
        check(owner.beginLogin() == nil && owner.snapshot().reason == "timeout"
              && owner.keychainRetryDelay() == 600 && f.manifest?.keychainPermissionRequired != true,
              "K341-login interactive probe timeout retains bounded timeout gate")
        check(f.storeTrace.map { $0.operation } == ["read", "stage", "stage"]
              && f.storeTrace.filter { $0.interactive }.count == 1 && f.storeTrace.last?.interactive == true,
              "K341-login interactive timeout follows one settled quiet denial with no readback")
        let operations = f.storeTrace.count
        f.now += 599
        check(isTemporary(owner.ensureAccess(reason: "wake")) && f.storeTrace.count == operations
              && owner.keychainRetryDelay() == 1 && owner.snapshot().reason == "timeout",
              "K341-login interactive timeout suppresses background adapters until bounded deadline")
        check(f.counts["device_flow", default: 0] == 0 && f.counts["refresh_request", default: 0] == 0,
              "K341-login interactive timed-out probe consumes no issuer grant")
    }
    // Only the explicit probe may interact during beginLogin. Denial and delayed
    // completeLogin cannot transfer that permission to issued-token persistence.
    do {
        let f = GHAuthFixture(); let owner = f.owner()
        f.stageFault = { _, _ in .locked }
        f.interactiveStage = { _, _ in .locked }
        check(owner.beginLogin() == nil, "denied explicit probe cannot begin device flow")
        check(f.storeTrace.filter { $0.interactive }.count == 1
              && f.storeTrace.first { $0.interactive }?.operation == "stage", "explicit probe has one native permission")
        f.now += 601; _ = owner.ensureAccess(reason: "wake")
        check(f.storeTrace.filter { $0.interactive }.count == 1, "failed probe cannot interact on wake")
    }
    // Legacy manual retry also starts interactive; background remains quiet.
    do {
        let f = GHAuthFixture(); let owner = f.owner()
        f.legacyRead = .locked
        check(isTemporary(owner.ensureAccess(reason: "startup")), "legacy background denial")
        check(isTemporary(owner.retryKeychainAccess()), "legacy explicit denial")
        f.now += 601; _ = f.owner().ensureAccess(reason: "wake")
        check(f.storeTrace.filter { $0.interactive }.count == 1
              && f.storeTrace.filter { !$0.interactive }.count == 2, "legacy permit is neither global nor persisted; manual retry has no preliminary quiet read")
    }

    // Snapshot2 P2: A passed its current-ID check, then UI cancels A and
    // starts B before A resumes. The queued operation owns the immutable A pair.
    do {
        let f = GHAuthFixture(), owner = f.owner()
        let attemptA = GitHubAuthLoginAttempt()
        var currentAttempt = attemptA
        check(currentAttempt.id == attemptA.id, "A passes current-ID check before barrier")
        let resumeA = { owner.beginLogin(action: attemptA.action) }
        // Deterministic barrier interleaving; no real UI, scheduler, native or network.
        currentAttempt.action.cancel()
        let attemptB = GitHubAuthLoginAttempt()
        currentAttempt = attemptB
        check(resumeA() == nil && f.storeTrace.isEmpty && f.manifest == nil,
              "resumed cancelled A cannot borrow B permission or reach storage")
        check(!attemptB.action.isCancelled && currentAttempt.id == attemptB.id,
              "A's deferred permit cleanup leaves B alive")
        f.stageFault = { _, _ in .locked }
        f.interactiveStage = { ref, credential in
            f.stageFault = nil
            return f.stage(ref, credential)
        }
        check(owner.beginLogin(action: attemptB.action) != nil,
              "B's own captured permission still completes its explicit probe")
        check(f.storeTrace.filter { $0.interactive }.count == 1,
              "only B, never stale A, launches one interactive operation")
    }

    // Review P2: cancellation while quiet probe I/O is suspended cannot admit
    // an interactive child when that I/O finally reports permission required.
    for duringStage in [false, true] {
        let f = GHAuthFixture(), action = GitHubAuthUserAction()
        let owner = f.owner()
        if duringStage { f.stageFault = { _, _ in action.cancel(); return .locked } }
        else { f.readForRef = { _ in action.cancel(); return .locked } }
        check(owner.beginLogin(action: action) == nil, "cancelled delayed probe does not start login")
        check(!f.storeTrace.contains { $0.interactive }, "cancelled quiet operation never launches interactive helper")
        check(f.counts["device_flow", default: 0] == 0 && f.counts["refresh_request", default: 0] == 0,
              "cancelled probe cannot consume issuer grants")
    }
    do {
        let cancelled = GitHubAuthUserAction(); cancelled.cancel()
        var launches = 0
        check(!cancelled.admit { launches += 1 } && launches == 0, "cancellation wins actual launch admission")
        let action = GitHubAuthUserAction()
        check(action.admit { launches += 1 }, "current action admits one launch")
        check(!action.admit { launches += 1 }, "same action cannot admit a second native launch")
        action.cancel()
        check(!action.admit { launches += 1 } && launches == 1, "ended permission cannot be reused")
    }
    // Review P2: a dead writer's rpcStarted record is NOT settlement. Only a
    // pre-issuer nonsecret probe can move to a fresh address; keep its old uncertainty.
    for oldProbeExists in [false, true] {
        let f = GHAuthFixture(); let initial = f.owner()
        check(isReady(f.login(initial)), "dead probe fixture login")
        f.due()
        let oldProbe = GitHubAuthRef(generation: UUID().uuidString.lowercased())
        let target = GitHubAuthRef(generation: UUID().uuidString.lowercased())
        let active = f.manifest!.active, epoch = f.manifest!.epoch
        f.manifest!.transition = GitHubAuthTransition(from: active, to: target, phase: "prepared", probe: oldProbe)
        f.manifest!.uncertainRefs.append(oldProbe)
        f.manifest!.cleanupRefs.append(oldProbe)
        f.manifest!.permitWriterRefs = (f.manifest!.permitWriterRefs ?? []) + [oldProbe]
        f.startedWriterRefs.insert(oldProbe) // process died without a completion receipt
        if oldProbeExists { f.items[oldProbe] = GitHubCredentialV2(kind: "probe", epoch: epoch,
            generation: oldProbe.generation, obtainedAt: f.now) }
        let restarted = f.owner()
        check(isTemporary(restarted.ensureAccess(reason: "startup")), "unknown probe gets a bounded deferred repair")
        let replacement = f.manifest!.transition!.probe
        check(replacement != oldProbe && f.manifest?.transition?.to == target && f.manifest?.active == active
              && f.manifest?.epoch == epoch, "repair replaces only probe, preserves active/candidate/epoch")
        check(f.manifest!.uncertainRefs.contains(oldProbe) && f.manifest!.cleanupRefs.contains(oldProbe)
              && !f.settledWriterRefs.contains(oldProbe), "probe kill never fabricated as completion/no-send")
        check(f.counts["refresh_request", default: 0] == 0, "probe repair cannot POST to issuer")
        f.now += 601
        check(f.protectedRead(f.owner().ensureAccess(reason: "maintenance")), "new probe resumes renewal after restart")
        check(f.manifest?.active == target && f.counts["refresh_request", default: 0] == 1,
              "repair uses original candidate and exactly one normal refresh grant")
        check(f.manifest!.uncertainRefs.contains(oldProbe) && !f.storeTrace.contains { $0.interactive },
              "unknown old probe remains tracked and all recovery is quiet")
    }
    do {
        let f = GHAuthFixture(); let owner = f.owner()
        check(isReady(f.login(owner)), "unknown secret writer fixture login")
        let target = GitHubAuthRef(generation: UUID().uuidString.lowercased())
        let probe = GitHubAuthRef(generation: UUID().uuidString.lowercased())
        f.manifest!.transition = GitHubAuthTransition(from: f.manifest!.active, to: target, phase: "requestStarted", probe: probe)
        f.manifest!.uncertainRefs += [target, probe]
        f.startedWriterRefs.formUnion([target, probe])
        let transition = f.manifest!.transition
        _ = owner.ensureAccess(reason: "startup")
        check(f.manifest!.transition == transition && f.counts["refresh_request", default: 0] == 0,
              "uncertain credential writer cannot use nonsecret probe repair or resend refresh")
    }

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
        owner.cleanupRetiredCredentials()
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
        checkWriteTimeoutBounded(f, owner, "late target after 600 seconds")
        check(owner.keychainRetryDelay() == 0, "late target bounded write-timeout cooldown elapsed at 600 seconds")
        check(f.protectedRead(owner.ensureAccess(reason: "maintenance")), "late target recovered automatically after write timeout")
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
        checkWriteTimeoutBounded(f, owner, "probe after 600 seconds")
        check(f.counts["refresh_request", default: 0] == 0, "probe write timeout keeps issuer unspent")
        check(f.protectedRead(owner.ensureAccess(reason: "maintenance")), "probe recovery after bounded write timeout")
        check(f.counts["refresh_request", default: 0] == 1, "automatic probe recovery spends one refresh")
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
        let f = GHAuthFixture(); let owner = f.owner(); check(isReady(f.login(owner)), "cleanup initial login"); owner.cleanupRetiredCredentials(); f.due()
        f.checkpointAction["before_retire"] = { f.deleteFault = .locked }
        check(f.protectedRead(owner.ensureAccess(reason: "maintenance")), "cleanup locked active still usable")
        owner.cleanupRetiredCredentials()
        check(f.manifest?.cleanupRefs.isEmpty == false, "cleanup pending retained")
        let next = f.owner()
        check(f.protectedRead(next.ensureAccess(reason: "maintenance")), "cleanup pending next read")
        next.cleanupRetiredCredentials()
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
        check(isTemporary(owner.ensureAccess(reason: "maintenance")), "uncertain candidate remains suppressed at 599 seconds")
        check(f.counts["store_read", default: 0] == readsAfterTimeout, "no protected-store re-read at 599 seconds")
        check(f.counts["refresh_request", default: 0] == postsAfterTimeout && f.manifest?.retryAt == retryBefore,
              "suppressed candidate leaves issuer budget and durable retry unchanged")
        f.now += 1
        checkWriteTimeoutBounded(f, owner, "readable uncertain writer at 600 seconds")
        check(f.protectedRead(owner.ensureAccess(reason: "maintenance")), "readable uncertain pair can publish validated identity at 600 seconds")
        check(f.counts["refresh_request", default: 0] == postsAfterTimeout,
              "readable candidate recovery cannot spend refresh again")
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
            let fresh = f.owner()
            check(isTemporary(fresh.ensureAccess(reason: "restart")), "fresh owner waits for unsettled helper")
            checkWriteTimeoutBounded(f, fresh, "fresh owner waiting for unsettled helper")
            check(f.manifest?.transition?.to == target, "unsettled helper durable address preserved")
            check(f.counts["refresh_request", default: 0] == 1 && f.counts["refresh_consumed", default: 0] == 1, "missing toRef cannot spend refresh while helper unsettled")
        }
        check(isTemporary(f.owner().retryKeychainAccess()), "explicit permission still waits for missing unsettled candidate")
        check(f.manifest?.transition?.to == target && target.map { f.manifest?.uncertainRefs.contains($0) == true } == true
              && f.counts["refresh_request", default: 0] == 1 && f.counts["refresh_consumed", default: 0] == 1,
              "manual retry preserves uncertain target and never spends a second grant")
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
            if origin == "refresh" { check(isReady(f.login(owner)), "candidate successor refresh initial login"); owner.cleanupRetiredCredentials(); f.due() }
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
            restarted.cleanupRetiredCredentials()
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
            let fresh = f.owner()
            check(isTemporary(fresh.ensureAccess(reason: "restart")), "readable unsettled probe restart still waits")
            checkWriteTimeoutBounded(f, fresh, "readable unsettled probe restart")
            check(f.counts["refresh_request", default: 0] == 0, "readable unsettled probe zero OAuth")
        }
        check(isTemporary(f.owner().retryKeychainAccess()), "explicit permission cannot treat readable unsettled probe as completed")
        check(probe.map { f.manifest?.uncertainRefs.contains($0) == true } == true && f.counts["refresh_request", default: 0] == 0,
              "manual probe retry retains uncertain address and zero OAuth before acknowledgement")
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
        let needsPermission: Bool
        if case .timeout = fault { needsPermission = true } else { needsPermission = false }
        check(owner.keychainRetryDelay() == (needsPermission ? .infinity : 600),
              "background read timeout requires permission; other failures have bounded cooldown")
        f.now += 86400 // advancing wall clock must not admit a Keychain request
        check(isTemporary(owner.ensureAccess(reason: "startup")), "wall forward does not bypass monotonic cooldown")
        f.now -= 172800 // nor may rollback extend it indefinitely
        check(isTemporary(owner.ensureAccess(reason: "maintenance")), "wall rollback does not bypass cooldown")
        f.monotonicNow = 1599
        check(isTemporary(owner.ensureAccess(reason: "background_sync")), "multiple background callers suppressed at 599")
        check(owner.keychainRetryDelay() == (needsPermission ? .infinity : 1),
              "permission gate and bounded monotonic delay are independent of wall clock")
        check(f.counts["store_read", default: 0] == reads && f.counts["store_stage", default: 0] == stages
              && f.counts["store_delete_attempt", default: 0] == deletes, "suppressed operation never touches any protected-store adapter")
        check(f.counts["refresh_request", default: 0] == posts && f.counts["device_flow", default: 0] == 1,
              "suppression never starts OAuth or new login")
        check(f.manifest?.epoch == epoch && f.manifest?.retryAt == retry && f.manifest?.signedOut == false,
              "access cooldown does not rewrite issuer backoff or sign out")
        f.monotonicNow = 1600; f.readOverride = nil
        if needsPermission {
            f.monotonicNow = 1_000_000
            check(isTemporary(owner.ensureAccess(reason: "maintenance")) && f.counts["store_read", default: 0] == reads,
                  "elapsed time never launches another background reader after timeout")
            check(owner.snapshot().reason == "permission_required", "background timeout names permission recovery")
            check(f.protectedRead(owner.retryKeychainAccess()), "successful explicit read releases timeout permission gate")
        } else {
            check(f.protectedRead(owner.ensureAccess(reason: "maintenance")), "automatic access recovers at exact monotonic boundary")
        }
        check((needsPermission || f.counts["store_read", default: 0] > reads) && owner.keychainRetryDelay() == nil,
              "successful permitted protected-store access clears runtime gate")
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
    // Explicit signed-out retry bypasses the separate GC throttle without
    // reading credentials or opening a device flow.
    for wallShift: Double in [1, -3600] {
        let f = GHAuthFixture(); f.monotonicNow = 1000
        let owner = f.owner(); check(isReady(f.login(owner)), "signed-out retry initial login")
        f.cleanupPreflightFault = { _ in .locked }
        let result = owner.logoutDetailed()
        check(result.accessDisabled && f.manifest?.cleanupRefs.isEmpty == false, "signed-out retry preserves pending cleanup")
        let epoch = f.manifest?.epoch, reads = f.counts["store_read", default: 0]
        let attributes = f.counts["store_attributes", default: 0]
        f.now += wallShift; f.monotonicNow = 1001; f.cleanupPreflightFault = nil
        check(isSignedOut(owner.ensureAccess(reason: "background_sync")), "signed-out background remains disabled")
        check(f.counts["store_read", default: 0] == reads, "signed-out background respects gate")
        check(isSignedOut(owner.retryKeychainAccess()), "explicit signed-out retry remains disabled")
        check(f.counts["store_read", default: 0] == reads && f.counts["store_attributes", default: 0] > attributes
              && f.manifest?.cleanupRefs.isEmpty == true,
              "manual cleanup bypasses recent or rolled-back clock using metadata only")
        check(f.manifest?.epoch == epoch && f.manifest?.active == nil && f.items.isEmpty,
              "manual cleanup retains tombstone and removes stored fixture items")
        check(f.counts["device_flow", default: 0] == 1 && f.counts["refresh_request", default: 0] == 0,
              "signed-out retry never logs in or refreshes")
    }
#if KEYCHAIN_SYNC_REGRESSION
    // Compile only with the offline extracted GitHubSync harness: its preferences
    // and usage-log boundaries are in-memory, native/network adapters trap.
    // syncBody, gh (including reason: api), projectAuth and withCurrentAccess
    // are the unchanged production implementations, not a hand-written sequence.
    do {
        let f = GHAuthFixture(); f.monotonicNow = 1000
        let owner = f.owner(); check(isReady(f.login(owner)), "sync cleanup fixture login")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ccl-sync-cleanup-" + UUID().uuidString)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let remote = directory.appendingPathComponent("remote.json")
        let defaults = makeOfflineSyncDefaults()
        defaults.set("fixture-gist", forKey: "syncGistId")
        defaults.set(Date(), forKey: "syncDiscoveredAt")
        var events: [String] = [], activeReads = 0
        f.readForRef = { ref in
            if ref == f.manifest?.active { activeReads += 1 }
            return nil
        }
        f.cleanupPreflightFault = { ref in
            guard f.manifest?.cleanupRefs.contains(ref) == true else { return nil }
            events.append("cleanup")
            check(defaults.object(forKey: "syncLastOkAt") != nil && FileManager.default.fileExists(atPath: remote.path),
                  "cleanup starts only after successful fenced publication")
            return .locked
        }
        let sync = GitHubSync(transport: { url, method, headers, _, _ in
            check(url == "https://api.github.com/gists/fixture-gist" && ["GET", "PATCH"].contains(method),
                  "sync reaches only expected fake gist transport")
            let bearer = headers["Authorization"] ?? ""
            check(bearer.hasPrefix("Bearer ") && f.authorized(String(bearer.dropFirst(7))) != nil,
                  "actual api path supplies currently valid synthetic credential")
            events.append(method)
            let body: [String: Any] = ["public": false, "files": [String: Any]()]
            return (200, try! JSONSerialization.data(withJSONObject: body), nil, [:])
        }, defaults: defaults, remotePath: remote.path, machineId: "fixture-local", authOwner: owner)
        sync.machineName = "fixture-host"
        for cycle in 0..<3 {
            if cycle > 0 { f.now += 600; f.monotonicNow! += 600 }
            events.removeAll(); activeReads = 0
            defaults.removeObject(forKey: "syncLastOkAt")
            try? FileManager.default.removeItem(at: remote)
            sync.syncSynchronously(force: true)
            check(events == ["GET", "PATCH", "cleanup"], "whole sync publishes before failing optional GC on every cooldown cycle")
            check(activeReads == 4, "sync admission, two api calls and publication each really read active credential")
            let cache = (try? Data(contentsOf: remote)).flatMap { try? JSONDecoder().decode(SyncRemoteCache.self, from: $0) }
            check(cache?.authEpoch == f.manifest?.epoch && cache?.authUserID == "1001", "published cache bound to current account")
            check(sync.ui.phase == .on && sync.ui.lastSync != nil && sync.ui.lastError == nil,
                  "optional GC failure cannot erase healthy sync publication")
            check(owner.keychainRetryDelay() == nil && !sync.ui.keychainRetryAvailable,
                  "post-publication GC failure never arms the credential gate or recovery action")
            let reads = f.counts["store_read", default: 0]
            let attributes = f.counts["store_attributes", default: 0]
            events.removeAll(); sync.syncSynchronously(force: true)
            check(events == ["GET", "PATCH"] && f.counts["store_read", default: 0] > reads
                  && f.counts["store_attributes", default: 0] == attributes,
                  "next sync remains healthy while only optional cleanup respects its own timer")
        }
        check(f.counts["device_flow", default: 0] == 1 && f.counts["refresh_request", default: 0] == 0,
              "three healthy syncs with GC faults never replace login or consume grants")
    }
#endif
    runGitHubKeychain341OwnerSelfTests(check: { condition, label in check(condition, label) })
    print("AUTH SELFTEST: \(checks) checks, \(failed) failures (synthetic dependencies only)")
    if failed > 0 { exit(1) }
}

// 3.4.1 contract checks use only the independent in-memory issuer/store oracle.
// No adapter in this group can touch a real Keychain, account, log or API.
func runGitHubKeychain341OwnerSelfTests(check: (Bool, String) -> Void) {
    func ready(_ value: GitHubAuthResult) -> Bool { if case .ready = value { return true }; return false }
    func temporary(_ value: GitHubAuthResult) -> Bool { if case .temporary = value { return true }; return false }

    for status in [GitHubAuthStoreStatus.locked, .timeout, .unreachable, .failed, .inputTooLarge] {
        let f = GHAuthFixture(); let initial = f.owner()
        check(ready(f.login(initial)), "K341-GC initial synthetic login")
        initial.cleanupRetiredCredentials()
        guard let active = f.manifest?.active, var old = f.items[active] else {
            check(false, "K341-GC active fixture missing"); continue
        }
        let retired = GitHubAuthRef(generation: UUID().uuidString.lowercased())
        old.generation = retired.generation; f.items[retired] = old
        f.manifest!.cleanupRefs = [retired]; f.monotonicNow = 1000
        f.cleanupPreflightFault = { ref in ref == retired ? status : nil }
        let owner = f.owner(); f.storeTrace.removeAll()
        owner.cleanupRetiredCredentials()
        check(f.storeTrace.count == 1 && f.storeTrace[0].operation == "attributes"
              && !f.storeTrace[0].interactive && f.storeTrace[0].ref == retired,
              "K341-GC failed preflight performs only exact-ref quiet metadata")
        check(owner.keychainRetryDelay() == nil && f.manifest?.active == active
              && f.manifest?.cleanupRefs.contains(retired) == true,
              "K341-GC metadata failure retains retired address without blocking active")
        check(ready(owner.ensureAccess(reason: "background_sync")), "K341-GC healthy active remains readable immediately")
        let attrs = f.counts["store_attributes", default: 0]
        f.now += 86400; f.monotonicNow = 1059
        owner.cleanupRetiredCredentials()
        check(f.counts["store_attributes", default: 0] == attrs, "K341-GC separate monotonic timer ignores wall jump")
        f.cleanupPreflightFault = nil; f.monotonicNow = 1060
        f.storeTrace.removeAll(); owner.cleanupRetiredCredentials()
        check(f.storeTrace.map { $0.operation } == ["attributes", "delete"]
              && !f.storeTrace.contains { $0.interactive }, "K341-GC exact timer permits quiet metadata and delete, zero secret reads")
        check(f.manifest?.cleanupRefs.isEmpty == true && f.items[retired] == nil
              && owner.keychainRetryDelay() == nil, "K341-GC successful retry clears only cleanup")
    }
    for status in [GitHubAuthStoreStatus.locked, .timeout, .unreachable, .failed] {
        let f = GHAuthFixture(); let initial = f.owner()
        check(ready(f.login(initial)), "K341-delete initial synthetic login")
        initial.cleanupRetiredCredentials()
        guard let active = f.manifest?.active, var old = f.items[active] else {
            check(false, "K341-delete active fixture missing"); continue
        }
        let retired = GitHubAuthRef(generation: UUID().uuidString.lowercased())
        old.generation = retired.generation; f.items[retired] = old; f.manifest!.cleanupRefs = [retired]
        f.persistentDeleteFault = status
        let owner = f.owner(); f.storeTrace.removeAll(); owner.cleanupRetiredCredentials()
        check(f.storeTrace.map { $0.operation } == ["attributes", "delete"]
              && !f.storeTrace.contains { $0.interactive }, "K341-delete failure uses quiet metadata/delete without secret read")
        check(owner.keychainRetryDelay() == nil && ready(owner.ensureAccess(reason: "background_sync")),
              "K341-delete failure never poisons credential gate")
        f.due()
        check(ready(owner.ensureAccess(reason: "maintenance")) && f.counts["refresh_request", default: 0] == 1,
              "K341-delete optional cleanup failure cannot prevent due renewal")
    }
    do {
        let f = GHAuthFixture(); let initial = f.owner()
        check(ready(f.login(initial)), "K341-permission initial synthetic login")
        let owner = f.owner(); let original = f.manifest
        f.readOverride = .timeout
        check(temporary(owner.ensureAccess(reason: "background")) && owner.snapshot().reason == "permission_required"
              && owner.keychainRetryDelay() == .infinity, "K341-permission background timeout requests manual permission")
        f.readOverride = .locked
        check(temporary(owner.retryKeychainAccess()), "K341-permission failed manual attempt stays temporary")
        let attempts = f.storeTrace.count
        f.now += 86400; f.monotonicNow = 1_000_000
        check(temporary(owner.ensureAccess(reason: "wake")) && f.storeTrace.count == attempts
              && owner.keychainRetryDelay() == .infinity, "K341-permission failed manual retry cannot rearm background readers")
        var denied = f.manifest; denied?.keychainPermissionRequired = original?.keychainPermissionRequired
        check(denied == original && f.manifest?.keychainPermissionRequired == true,
              "K341-permission denial changes only persisted permission latch")
        let restarted = f.owner(); let beforeRestart = f.storeTrace.count
        check(temporary(restarted.ensureAccess(reason: "startup")) && f.storeTrace.count == beforeRestart
              && restarted.keychainRetryDelay() == .infinity,
              "K341-permission restart restores latch before any background credential adapter")
        f.readOverride = nil
        check(ready(owner.retryKeychainAccess()) && owner.keychainRetryDelay() == nil
              && f.manifest?.keychainPermissionRequired != true,
              "K341-permission only successful manual read clears runtime and persisted permission gate")
        check(ready(owner.ensureAccess(reason: "background")) && !f.storeTrace.last!.interactive,
              "K341-permission later background read remains quiet")
    }
    for interrupted in [false, true] {
        let f = GHAuthFixture(); let initial = f.owner()
        check(ready(f.login(initial)), "K341-migrate initial unmarked synthetic generation")
        initial.cleanupRetiredCredentials()
        guard let source = f.manifest?.active, let original = f.items[source] else {
            check(false, "K341-migrate source fixture missing"); continue
        }
        f.usesSecurityWriter = true
        var observedIntent = false
        f.checkpointAction["after_intent"] = {
            observedIntent = f.manifest?.transition?.kind == "securityMigration"
                && f.manifest?.transition?.from == source && f.manifest?.active == source
            if interrupted { throw GHFixtureError.stopped }
        }
        let owner = f.owner(); let first = owner.ensureAccess(reason: "startup")
        check(observedIntent, "K341-migrate journals migration transition before writer, preserves active pointer")
        if interrupted {
            check(!ready(first) && f.manifest?.active == source && f.items[source] == original,
                  "K341-migrate stopped intent preserves original complete credential")
            check(ready(f.owner().ensureAccess(reason: "restart")), "K341-migrate durable transition resumes after restart")
        } else { check(ready(first), "K341-migrate unmarked generation moves through successful writer/readback") }
        guard let migrated = f.manifest?.active, let value = f.items[migrated] else {
            check(false, "K341-migrate published candidate missing"); continue
        }
        check(migrated != source && value.epoch == original.epoch && value.accessToken == original.accessToken
              && value.refreshToken == original.refreshToken && value.userID == f.manifest?.userID
              && f.manifest?.userID == "1001",
              "K341-migrate fresh generation preserves epoch, identity and credential pair")
        check(f.manifest?.transition == nil && f.manifest?.securityWriterRefs?.contains(migrated) == true
              && f.manifest?.securityWriterRefs?.contains(source) != true,
              "K341-migrate published security writer marker is per generation")
        if let encoded = try? JSONEncoder().encode(f.manifest),
           let decoded = try? JSONDecoder().decode(GitHubAuthManifest.self, from: encoded) { f.manifest = decoded }
        else { check(false, "K341-migrate manifest marker roundtrip") }
        let stages = f.counts["store_stage", default: 0]
        check(ready(f.owner().ensureAccess(reason: "restart")) && f.counts["store_stage", default: 0] == stages,
              "K341-migrate persisted marked generation never migrates again after restart")
        check(f.counts["refresh_request", default: 0] == 0 && f.counts["device_flow", default: 0] == 1
              && f.publicStateIsNonsecret(owner), "K341-migrate uses no OAuth grant, new login or secret journal")
    }
    // Review A: migration is optional. A permanent writer rejection (oversized
    // 3.4.0 envelope, deterministic adapter failure) declines this generation for good.
    for status in [GitHubAuthStoreStatus.inputTooLarge, .failed] {
        let f = GHAuthFixture(); let initial = f.owner()
        check(ready(f.login(initial)), "K341-migrate permanent failure initial synthetic login")
        initial.cleanupRetiredCredentials()
        guard let source = f.manifest?.active, let original = f.items[source] else {
            check(false, "K341-migrate permanent failure source missing"); continue
        }
        f.usesSecurityWriter = true; f.stageFault = { _, c in c.kind == "credential" ? status : nil }
        let owner = f.owner(), stagesBefore = f.counts["store_stage", default: 0]
        check(f.protectedRead(owner.ensureAccess(reason: "startup")) && f.manifest?.active == source
              && f.items[source] == original,
              "K341-migrate permanent writer failure still syncs on the readable active generation")
        check(f.manifest?.transition == nil && f.manifest?.securityMigrationDeclinedRefs == [source]
              && f.manifest?.securityWriterRefs?.contains(source) != true,
              "K341-migrate permanent failure drops the transition and remembers the declined generation")
        check(owner.keychainRetryDelay() == nil && f.manifest?.keychainPermissionRequired != true
              && owner.snapshot().state == "healthy",
              "K341-migrate optional writer failure arms no store gate or permission latch")
        if case .ready(let access) = owner.ensureAccess(reason: "background_sync") {
            check(owner.withCurrentAccess(access) {}, "K341-migrate declined generation still admits sync publication")
        } else { check(false, "K341-migrate declined generation lost access") }
        for reason in ["background_sync", "maintenance", "wake"] {
            f.now += 3601
            check(f.protectedRead(owner.ensureAccess(reason: reason)), "K341-migrate declined generation keeps syncing")
        }
        check(f.protectedRead(f.owner().ensureAccess(reason: "restart"))
              && f.counts["store_stage", default: 0] == stagesBefore + 1 && f.manifest?.transition == nil,
              "K341-migrate declined generation is never retried, including after restart")
        check(f.counts["refresh_request", default: 0] == 0 && f.counts["device_flow", default: 0] == 1
              && f.publicStateIsNonsecret(owner), "K341-migrate permanent failure requests no OAuth or new login")
    }
    // Temporary writer failures never stop sync; retries are spaced by the
    // migration interval and bounded to three attempts, then migration is declined.
    for status in [GitHubAuthStoreStatus.timeout, .locked, .unreachable] {
        let f = GHAuthFixture(); f.monotonicNow = 1000
        let initial = f.owner()
        check(ready(f.login(initial)), "K341-migrate temporary failure initial synthetic login")
        initial.cleanupRetiredCredentials()
        guard let source = f.manifest?.active, let original = f.items[source] else {
            check(false, "K341-migrate temporary failure source missing"); continue
        }
        f.usesSecurityWriter = true; f.stageFault = { _, c in c.kind == "credential" ? status : nil }
        let owner = f.owner(), stagesBefore = f.counts["store_stage", default: 0]
        check(f.protectedRead(owner.ensureAccess(reason: "startup")) && f.manifest?.active == source
              && f.items[source] == original,
              "K341-migrate temporary writer failure still syncs on the readable active generation")
        let target = f.manifest?.transition?.to
        check(f.manifest?.transition?.kind == "securityMigration" && f.manifest?.transition?.recoveryAttempts == 1
              && owner.keychainRetryDelay() == nil && f.manifest?.keychainPermissionRequired != true
              && owner.snapshot().reason != "permission_required",
              "K341-migrate temporary failure keeps a counted retry without store gate or permission latch")
        if case .ready(let access) = owner.ensureAccess(reason: "background_sync") {
            check(owner.withCurrentAccess(access) {}, "K341-migrate pending optional migration does not fence sync publication")
        } else { check(false, "K341-migrate pending migration lost access") }
        check(f.manifest?.transition?.recoveryAttempts == 1 && f.counts["store_stage", default: 0] == stagesBefore + 1,
              "K341-migrate no second attempt before the retry interval")
        for _ in 0..<5 {
            f.now += 3601; f.monotonicNow! += 3601
            check(f.protectedRead(owner.ensureAccess(reason: "background_sync")), "K341-migrate sync continues during bounded retries")
            check(owner.keychainRetryDelay() == nil, "K341-migrate retries never arm the store gate")
        }
        // A timed-out writer stays unsettled, so later attempts cannot start a second writer.
        let expectedStages = stagesBefore + (status == .timeout ? 1 : 3)
        check(f.manifest?.transition == nil && f.manifest?.securityMigrationDeclinedRefs == [source]
              && f.manifest?.active == source && target.map { f.manifest?.cleanupRefs.contains($0) == true } == true,
              "K341-migrate gives up after three attempts and keeps candidate address for cleanup")
        check(f.counts["store_stage", default: 0] == expectedStages,
              "K341-migrate at most three writer launches, none while a timed-out writer is unsettled")
        check(f.protectedRead(f.owner().ensureAccess(reason: "restart"))
              && f.counts["store_stage", default: 0] == expectedStages && f.manifest?.transition == nil,
              "K341-migrate abandoned migration is not retried after restart")
        check(f.counts["refresh_request", default: 0] == 0 && f.counts["device_flow", default: 0] == 1,
              "K341-migrate bounded retries request no OAuth or new login")
    }
    // Optional candidate readbacks cannot poison the readable active generation,
    // either immediately after staging or when resuming an earlier timed-out write.
    for readFault in [GitHubAuthRead.timeout, .locked] {
        for resumed in [false, true] {
            let f = GHAuthFixture(); f.monotonicNow = 1000
            let initial = f.owner()
            check(ready(f.login(initial)), "K341-migrate-readback initial synthetic login")
            initial.cleanupRetiredCredentials()
            guard let source = f.manifest?.active, let original = f.items[source] else {
                check(false, "K341-migrate-readback source missing"); continue
            }
            f.usesSecurityWriter = true
            let owner = f.owner()
            if resumed {
                f.stageFault = { _, c in c.kind == "credential" ? .timeout : nil }
                check(f.protectedRead(owner.ensureAccess(reason: "startup")),
                      "K341-migrate-readback timed-out writer still serves source")
                f.stageFault = nil; f.releaseLateWrites()
                f.now += 3601; f.monotonicNow! += 3601
            }
            var candidateReads = 0
            f.readForRef = { ref in
                guard let target = f.manifest?.transition?.to, ref == target else { return nil }
                candidateReads += 1; return readFault
            }
            let first = owner.ensureAccess(reason: "background_sync")
            let sourceUnchanged = f.manifest?.active == source && f.items[source] == original
            let noGate = owner.keychainRetryDelay() == nil && f.manifest?.keychainPermissionRequired == nil
            let firstHealthy = f.protectedRead(first) && sourceUnchanged && noGate && candidateReads == 1
            check(firstHealthy,
                  "K341-migrate-readback timeout/locked keeps active token and arms no permission latch or cooldown")
            guard let target = f.manifest?.transition?.to, let notBefore = f.manifest?.transition?.notBefore else {
                check(false, "K341-migrate-readback retains deferred migration"); continue
            }
            let attempts = f.manifest?.transition?.recoveryAttempts
            let stages = f.counts["store_stage", default: 0]
            f.storeTrace.removeAll()
            let next = owner.ensureAccess(reason: "background_sync")
            let readActive = f.storeTrace.contains { $0.operation == "read" && $0.ref == source && !$0.interactive }
            let deferred = f.manifest?.transition?.recoveryAttempts == attempts && candidateReads == 1
            let nextHealthy = f.protectedRead(next) && readActive && deferred && owner.keychainRetryDelay() == nil
            check(nextHealthy,
                  "K341-migrate-readback next background pass reads active while only migration waits")
            if let encoded = try? JSONEncoder().encode(f.manifest),
               let decoded = try? JSONDecoder().decode(GitHubAuthManifest.self, from: encoded) { f.manifest = decoded }
            else { check(false, "K341-migrate-readback manifest roundtrip") }
            let restarted = f.owner(); f.storeTrace.removeAll()
            let afterRestart = restarted.ensureAccess(reason: "background_sync")
            let restartReadActive = f.storeTrace.contains { $0.operation == "read" && $0.ref == source && !$0.interactive }
            let restartNoGate = restarted.keychainRetryDelay() == nil && f.manifest?.keychainPermissionRequired == nil
            let restartHealthy = f.protectedRead(afterRestart) && restartReadActive && restartNoGate && candidateReads == 1
            check(restartHealthy,
                  "K341-migrate-readback restart retains healthy background access and deferred migration")
            f.readForRef = nil; f.now = notBefore + 1; f.monotonicNow! += 3601
            let retried = restarted.ensureAccess(reason: "background_sync")
            let published = f.manifest?.active == target && f.manifest?.transition == nil
            let noExtraWrite = f.counts["store_stage", default: 0] == stages
            let retryHealthy = f.protectedRead(retried) && published && noExtraWrite && restarted.keychainRetryDelay() == nil
            check(retryHealthy,
                  "K341-migrate-readback later retry publishes existing copy without another writer")
        }
    }
    // A late copy found on a later attempt is published without another writer.
    do {
        let f = GHAuthFixture(); let initial = f.owner()
        check(ready(f.login(initial)), "K341-migrate late copy initial synthetic login")
        initial.cleanupRetiredCredentials()
        let source = f.manifest?.active
        f.usesSecurityWriter = true; f.stageFault = { _, c in c.kind == "credential" ? .timeout : nil }
        let owner = f.owner()
        check(source != nil && f.protectedRead(owner.ensureAccess(reason: "startup")) && f.manifest?.active == source,
              "K341-migrate timed-out writer still syncs on source")
        let stages = f.counts["store_stage", default: 0]
        f.stageFault = nil; f.releaseLateWrites(); f.now += 3601
        let target = f.manifest?.transition?.to
        check(target != nil && f.protectedRead(owner.ensureAccess(reason: "background_sync")) && f.manifest?.active == target
              && f.manifest?.transition == nil && f.counts["store_stage", default: 0] == stages,
              "K341-migrate later attempt publishes the settled late copy without a second writer")
    }
    // Review B: a background WRITE timeout is the bounded timeout class with
    // self-recovery; only a background READ timeout requires manual permission.
    do {
        let f = GHAuthFixture(); f.monotonicNow = 1000
        let owner = f.owner(); check(ready(f.login(owner)), "K341-write-timeout initial synthetic login"); f.due()
        f.stageFault = { _, c in c.kind == "credential" ? .timeout : nil }
        check(temporary(owner.ensureAccess(reason: "background_sync")), "K341-write-timeout renewal write timeout is temporary")
        check(owner.snapshot().reason == "timeout" && owner.keychainRetryDelay() == 600
              && f.manifest?.keychainPermissionRequired != true,
              "K341-write-timeout background write timeout is bounded, not permission_required, no manifest latch")
        check(f.owner().keychainRetryDelay() == nil, "K341-write-timeout restart restores no permission gate")
        f.stageFault = nil; f.releaseLateWrites(); f.monotonicNow = 1599
        let reads = f.counts["store_read", default: 0]
        check(temporary(owner.ensureAccess(reason: "background_sync")) && owner.keychainRetryDelay() == 1
              && f.counts["store_read", default: 0] == reads,
              "K341-write-timeout cooldown suppresses background adapters until its finite deadline")
        f.monotonicNow = 1600
        check(f.protectedRead(owner.ensureAccess(reason: "background_sync")) && owner.keychainRetryDelay() == nil
              && f.counts["refresh_request", default: 0] == 1,
              "K341-write-timeout background self-recovers after 600 seconds without manual retry")
        f.readOverride = .timeout
        check(temporary(owner.ensureAccess(reason: "background_sync")) && owner.snapshot().reason == "permission_required"
              && owner.keychainRetryDelay() == .infinity && f.manifest?.keychainPermissionRequired == true,
              "K341-write-timeout background read timeout still requires manual permission")
    }
}

// Pure writer contract checks and one explicitly isolated temporary-Keychain probe.
// Called only by selftest dispatch, before AppKit or production singletons.
func runGitHubKeychain341AdapterSelfTests(check: (Bool, String) -> Void) {
    let service = "Claude Codex Limits GitHub Credential V2"
    let generation = "01234567-89ab-cdef-0123-456789abcdef"
    let credential = GitHubCredentialV2(epoch: generation, generation: generation,
        accessToken: "ccl-test-writer-access", refreshToken: "ccl-test-writer-refresh", obtainedAt: 1000,
        userID: "1001", login: "fixture")
    guard let data = try? JSONEncoder().encode(credential) else {
        check(false, "K341-writer synthetic envelope encoding"); return
    }
    let envelope = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    do {
        let command = try githubAuthSecurityWriteCommand(service: service, generation: generation, envelope: envelope)
        check(command.arguments == ["-i"] && !command.arguments.joined().contains(envelope),
              "K341-writer only -i is in process argv; all secret data uses stdin")
        check(command.input.hasPrefix("add-generic-password -s ")
              && command.input.contains(" -a " + generation + " -T /usr/bin/security -w " + envelope)
              && command.input.hasSuffix("\n") && command.input.filter { $0 == "\n" }.count == 1
              && !command.input.contains(" -U") && !command.input.contains("quit"),
              "K341-writer one add-only stdin command, trusted security ACL, newline and EOF")
        let minimum = try githubAuthSecurityWriteCommand(service: "x", generation: generation, envelope: envelope)
        for target in [2047, 2048, 2049] {
            let length = target - minimum.input.utf8.count + 1
            var runs = 0, probes = 0
            do {
                let status = try githubAuthSecurityWrite(service: String(repeating: "x", count: length), generation: generation,
                    envelope: envelope, run: { args, line in
                        runs += 1
                        check(args == ["-i"] && line.utf8.count == target, "K341-writer exact UTF8 command-line boundary including newline")
                        return .success
                    }, attributes: { probes += 1; return .success })
                check(target <= 2048 && status == .success && runs == 1 && probes == 1,
                      "K341-writer accepts only bounded lines and confirms attributes")
            } catch {
                check(target == 2049 && runs == 0 && probes == 0,
                      "K341-writer rejects 2049-byte command before any process or Keychain probe")
            }
        }
        // Two-byte scalars ensure the cap counts UTF8 bytes, not Swift characters.
        let budget = 2048 - minimum.input.utf8.count + 1
        let utf8Service = String(repeating: "é", count: budget / 2) + (budget % 2 == 1 ? "x" : "")
        let utf8Command = try githubAuthSecurityWriteCommand(service: utf8Service, generation: generation, envelope: envelope)
        check(utf8Command.input.utf8.count == 2048, "K341-writer multibyte service observes same 2048-byte cap")
        var multibyteRan = false
        do {
            _ = try githubAuthSecurityWrite(service: utf8Service + "é", generation: generation, envelope: envelope,
                run: { _, _ in multibyteRan = true; return .success }, attributes: { .success })
            check(false, "K341-writer rejects multibyte overflow")
        } catch { check(!multibyteRan, "K341-writer multibyte overflow rejected before spawn") }
        for invalid in ["", "bad\nservice", "bad\rservice", "bad\0service"] {
            var ran = false
            do {
                _ = try githubAuthSecurityWrite(service: invalid, generation: generation, envelope: envelope,
                    run: { _, _ in ran = true; return .success }, attributes: { .success })
                check(false, "K341-writer rejects control/empty service")
            } catch { check(!ran, "K341-writer invalid service cannot inject another command") }
        }
        for (code, presence, success) in [(SyncKeychainStatus.success, SyncKeychainStatus.success, true),
                (.success, .missing, false), (.failure(1), .missing, false),
                (.failure(45), .success, true), (.success, .failure(36), false), (.timedOut, .success, false)] {
            var probes = 0, runs = 0
            let status = try githubAuthSecurityWrite(service: service, generation: generation, envelope: envelope,
                run: { _, _ in runs += 1; return code }, attributes: { probes += 1; return presence })
            check(runs == 1 && (status == .success) == success && probes == (code == .timedOut ? 0 : 1),
                  "K341-writer rc0 never certifies missing item; settled duplicate needs attributes; timeout stays uncertain")
        }
        for (candidateGeneration, candidateEnvelope) in [("not-a-uuid", envelope),
                (UUID().uuidString.lowercased(), envelope), (generation, "invalid-envelope"),
                (generation, envelope + "\nadd-generic-password")] {
            var ran = false
            do {
                _ = try githubAuthSecurityWrite(service: service, generation: candidateGeneration, envelope: candidateEnvelope,
                    run: { _, _ in ran = true; return .success }, attributes: { .success })
                check(false, "K341-writer rejects malformed or generation-mismatched envelope")
            } catch { check(!ran, "K341-writer invalid envelope rejected before process launch") }
        }
        let quoted = try githubAuthSecurityWriteCommand(service: "fixture \"quoted\" \\ service", generation: generation,
            envelope: envelope, keychainPath: "/tmp/fixture \"quoted\".keychain-db")
        check(quoted.arguments == ["-i"] && quoted.input.filter { $0 == "\n" }.count == 1
              && quoted.input.contains("\\\"quoted\\\"") && quoted.input.contains("\\\\ service"),
              "K341-writer quotes service and test keychain path using interactive-parser escaping")
    } catch { check(false, "K341-writer valid synthetic command unexpectedly rejected") }
    do {
        let expected = "delete-generic-password -s \"" + service + "\" -a \"" + generation + "\"\n"
        for copies in [0, 1, 2, 4, 5] {
            for exit in [SyncKeychainStatus.success, .failure(1)] {
                var remaining = copies, runs = 0
                let status = try githubAuthSecurityDelete(service: service, generation: generation,
                    run: { args, line in
                        runs += 1
                        check(args == ["-i"] && line == expected,
                              "K341-delete exact nonsecret stdin command; argv contains only -i")
                        remaining -= 1; return exit
                    }, attributes: { remaining == 0 ? .missing : .success })
                let removedAll = copies <= 4 && remaining == 0 && status == .success
                let bounded = copies > 4 && remaining == 1 && status != .success
                check((removedAll || bounded) && runs == min(copies, 4),
                      "K341-delete absent succeeds without a child; all copies removed up to four; further copies stay pending")
            }
        }
        var runs = 0
        let falseSuccess = try githubAuthSecurityDelete(service: service, generation: generation,
            run: { _, _ in runs += 1; return .success }, attributes: { .success })
        check(falseSuccess != .success && runs == 4,
              "K341-delete rc0 cannot certify deletion while attributes still find a copy")
        var timeoutProbes = 0
        let timeout = try githubAuthSecurityDelete(service: service, generation: generation,
            run: { _, _ in .timedOut }, attributes: { timeoutProbes += 1; return .success })
        check(timeout == .timedOut && timeoutProbes == 1,
              "K341-delete timeout never certifies an unsettled child or launches another delete")
        var deniedRuns = 0
        let denied = try githubAuthSecurityDelete(service: service, generation: generation,
            run: { _, _ in deniedRuns += 1; return .success }, attributes: { .failure(36) })
        check(denied == .failure(36) && deniedRuns == 0,
              "K341-delete failed quiet attributes never launch deletion")
        var pathCommand = ""
        let path = "/tmp/fixture \"quoted\".keychain-db"
        var pathProbes = 0
        let scoped = try githubAuthSecurityDelete(service: service, generation: generation, keychainPath: path,
            run: { _, line in pathCommand = line; return .success }, attributes: {
                pathProbes += 1; return pathProbes == 1 ? .success : .missing
            })
        let expectedPath = String(expected.dropLast()) + " \"/tmp/fixture \\\"quoted\\\".keychain-db\"\n"
        check(scoped == .success && pathCommand == expectedPath,
              "K341-delete quotes isolated keychain path with the writer's interactive-parser escaping")
        for invalid in ["legacy", "not-a-uuid", generation.uppercased(), generation + "\nquit"] {
            var ran = false, probed = false
            do {
                _ = try githubAuthSecurityDelete(service: service, generation: invalid,
                    run: { _, _ in ran = true; return .success }, attributes: { probed = true; return .missing })
                check(false, "K341-delete rejects noncanonical generation")
            } catch {
                check(!ran && !probed, "K341-delete validates UUID before any process or attributes query")
            }
        }
    } catch { check(false, "K341-delete valid synthetic command unexpectedly rejected") }
    do {
        for copies in [0, 1, 2, 4] {
            var remaining = copies, nativeRuns = 0, securityRuns = 0
            let status = try githubAuthSecurityDelete(service: service, generation: generation,
                nativeDelete: { nativeRuns += 1; remaining -= 1; return .success },
                run: { _, _ in securityRuns += 1; return .failure(1) },
                attributes: { remaining == 0 ? .missing : .success })
            let nativeOnly = status == .success && nativeRuns == copies && securityRuns == 0 && remaining == 0
            check(nativeOnly, "K341-delete-native all native-owned copies disappear without launching security")
        }
        var remaining = 2, nativeRuns = 0, securityRuns = 0
        let fallback = try githubAuthSecurityDelete(service: service, generation: generation,
            nativeDelete: { nativeRuns += 1; return .failure(36) },
            run: { _, _ in securityRuns += 1; remaining -= 1; return .success },
            attributes: { remaining == 0 ? .missing : .success })
        let fallbackRemoved = fallback == .success && nativeRuns == 1 && securityRuns == 2 && remaining == 0
        check(fallbackRemoved, "K341-delete-fallback native ACL denial falls back to security only while attributes confirm unlocked")

        // The owner must retain the generation when neither adapter removes it,
        // including a misleading native success followed by four misleading rc0s.
        for nativeStatus in [SyncKeychainStatus.success, .failure(36)] {
            let f = GHAuthFixture(); let initial = f.owner()
            let login = f.login(initial)
            let loggedIn: Bool
            if case .ready = login { loggedIn = true } else { loggedIn = false }
            check(loggedIn, "K341-delete-pending initial synthetic login")
            initial.cleanupRetiredCredentials()
            guard let active = f.manifest?.active, var old = f.items[active] else {
                check(false, "K341-delete-pending source missing"); continue
            }
            let retired = GitHubAuthRef(generation: UUID().uuidString.lowercased())
            old.generation = retired.generation; f.items[retired] = old; f.manifest!.cleanupRefs = [retired]
            var nativeAttempts = 0, securityAttempts = 0
            var deletion: SyncKeychainStatus?
            f.deleteAdapter = { ref in
                do {
                    let result = try githubAuthSecurityDelete(service: service, generation: ref.generation,
                        nativeDelete: { nativeAttempts += 1; return nativeStatus },
                        run: { _, _ in securityAttempts += 1; return .success }, attributes: { .success })
                    deletion = result
                    return result == .success ? .success : .unreachable
                } catch { return .failed }
            }
            let owner = f.owner(); owner.cleanupRetiredCredentials()
            let expectedNative = nativeStatus == .success ? 4 : 1
            let bounded = nativeAttempts == expectedNative && securityAttempts == 4
            let retained = f.manifest?.cleanupRefs.contains(retired) == true && f.items[retired] != nil
            let failed = deletion == .failure(1) && owner.snapshot().cleanupPending && owner.keychainRetryDelay() == nil
            check(bounded && retained && failed,
                  "K341-delete-pending both adapters fail within eight attempts; generation remains in cleanupRefs")
        }

        var unlockedCopies = 2, lockedNativeRuns = 0, lockedSecurityRuns = 0
        let lockedNext = try githubAuthSecurityDelete(service: service, generation: generation,
            nativeDelete: { lockedNativeRuns += 1; unlockedCopies -= 1; return .success },
            run: { _, _ in lockedSecurityRuns += 1; return .success },
            attributes: { unlockedCopies == 2 ? .success : .failure(36) })
        let stoppedAtLockedCopy = lockedNext == .failure(36) && lockedNativeRuns == 1 && lockedSecurityRuns == 0
        check(stoppedAtLockedCopy, "K341-delete-locked-next locked second copy stops before any security launch")
        var nativeTimeoutRuns = 0, timeoutSecurityRuns = 0, nativeTimeoutProbes = 0
        let nativeTimeout = try githubAuthSecurityDelete(service: service, generation: generation,
            nativeDelete: { nativeTimeoutRuns += 1; return .timedOut },
            run: { _, _ in timeoutSecurityRuns += 1; return .success },
            attributes: { nativeTimeoutProbes += 1; return .success })
        let stoppedAtTimeout = nativeTimeout == .timedOut && nativeTimeoutRuns == 1
            && timeoutSecurityRuns == 0 && nativeTimeoutProbes == 1
        check(stoppedAtTimeout, "K341-delete-native-timeout exits immediately without probes or security fallback")
    } catch { check(false, "K341-delete native-first synthetic adapter unexpectedly rejected") }
    for language in ["ru", "en"] {
        let permission = language == "en"
            ? "Keychain needs permission. Click Retry Keychain access, then choose “Always Allow” in the “security” prompt"
            : "Связке ключей нужно разрешение. Нажмите «Повторить доступ к Связке ключей» и в окне «security» нажмите «Разрешать всегда»"
        for reason in ["locked", "timeout", "permission_required"] {
            check(githubAuthMessage(reason, language: language) == permission,
                  "K341-copy permission recovery names retry, security prompt and Always Allow exactly")
        }
    }
    runGitHubKeychain341TemporaryKeychainProbe(check: check)
}

#if os(macOS)
private final class GH341CapturedOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func store(_ value: Data) { lock.lock(); bytes = value; lock.unlock() }
    func value() -> Data { lock.lock(); defer { lock.unlock() }; return bytes }
}
// Output, including dump-keychain and synthetic secret reads, never reaches stdout.
private func github341TemporarySecurity(_ arguments: [String], input: String? = nil) -> (SyncKeychainStatus, Data) {
    let process = Process(), output = Pipe(), stdin = Pipe()
    let stopped = DispatchSemaphore(value: 0), captured = DispatchSemaphore(value: 0), bytes = GH341CapturedOutput()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/security"); process.arguments = arguments
    process.standardOutput = output; process.standardError = FileHandle.nullDevice
    process.standardInput = input == nil ? FileHandle.nullDevice : stdin.fileHandleForReading
    _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    process.terminationHandler = { _ in stopped.signal() }
    do { try process.run() } catch { return (.failure(1), Data()) }
    DispatchQueue.global().async {
        bytes.store(output.fileHandleForReading.readDataToEndOfFile()); captured.signal()
    }
    if let input = input {
        do { try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8)) }
        catch { process.terminate() }
        try? stdin.fileHandleForWriting.close()
    }
    let timedOut = stopped.wait(timeout: .now() + 15) != .success
    if timedOut {
        process.terminate()
        if stopped.wait(timeout: .now() + 2) != .success { _ = kill(process.processIdentifier, SIGKILL) }
    }
    guard captured.wait(timeout: .now() + 2) == .success else { return (.timedOut, Data()) }
    if timedOut { return (.timedOut, Data()) }
    guard process.terminationReason == .exit else { return (.failure(1), Data()) }
    return (process.terminationStatus == 0 ? .success : .failure(process.terminationStatus), bytes.value())
}
// dump-keychain may print ACL/partition plists as plain text or as hex (0x… or
// "<hex>"). Count the marker in every form at byte level; the dump itself is never printed.
func github341PartitionMarkerCount(_ dump: Data, marker: String = "apple-tool:") -> Int {
    func occurrences(_ pattern: Data, in data: Data) -> Int {
        guard !pattern.isEmpty else { return 0 }
        var count = 0, start = data.startIndex
        while start < data.endIndex, let found = data.range(of: pattern, in: start..<data.endIndex) {
            count += 1; start = found.upperBound
        }
        return count
    }
    let raw = Data(marker.utf8)
    let lower = raw.map { String(format: "%02x", $0) }.joined()
    return occurrences(raw, in: dump) + occurrences(Data(lower.utf8), in: dump)
        + occurrences(Data(lower.uppercased().utf8), in: dump)
}
#endif

private func runGitHubKeychain341TemporaryKeychainProbe(check: (Bool, String) -> Void) {
#if os(macOS)
    guard FileManager.default.isExecutableFile(atPath: "/usr/bin/security") else {
        print("K341 TEMP KEYCHAIN: SKIP (security tool unavailable)")
        print("K341 TEMP DELETE: SKIP (security tool unavailable)"); return
    }
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("ccl-keychain-341-" + UUID().uuidString, isDirectory: true)
    do { try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
    catch {
        print("K341 TEMP KEYCHAIN: SKIP (temporary directory unavailable)")
        print("K341 TEMP DELETE: SKIP (temporary directory unavailable)"); return
    }
    defer { try? fm.removeItem(at: root) }
    let path = root.appendingPathComponent("fixture.keychain-db").path
    let password = UUID().uuidString + UUID().uuidString
    let created = github341TemporarySecurity(["create-keychain", "-p", password, path]).0
    guard created == .success else {
        print("K341 TEMP KEYCHAIN: SKIP (temporary keychain creation unavailable)")
        print("K341 TEMP DELETE: SKIP (temporary keychain creation unavailable)"); return
    }
    defer {
        check(github341TemporarySecurity(["delete-keychain", path]).0 == .success,
              "K341-integration deletes only its temporary keychain")
    }
    guard github341TemporarySecurity(["unlock-keychain", "-p", password, path]).0 == .success else {
        print("K341 TEMP KEYCHAIN: SKIP (temporary keychain unlock unavailable)")
        print("K341 TEMP DELETE: SKIP (temporary keychain unlock unavailable)"); return
    }
    var opened: SecKeychain?
    let openStatus = path.withCString { SecKeychainOpen($0, &opened) }
    guard openStatus == errSecSuccess, let keychain = opened else {
        print("K341 TEMP DELETE: SKIP (temporary keychain open unavailable)")
        check(false, "K341-integration open created temporary keychain for scoped attributes"); return
    }
    // Match the helper's process-local quiet policy for real native deletion,
    // and restore the caller's policy when this isolated probe finishes.
    var interactionAllowed: DarwinBoolean = false
    let interactionStatus = SecKeychainGetUserInteractionAllowed(&interactionAllowed)
    guard interactionStatus == errSecSuccess else {
        print("K341 TEMP DELETE: SKIP (cannot capture native interaction policy)"); return
    }
    guard SecKeychainSetUserInteractionAllowed(false) == errSecSuccess else {
        print("K341 TEMP DELETE: SKIP (cannot suppress native interaction)"); return
    }
    defer { _ = SecKeychainSetUserInteractionAllowed(interactionAllowed.boolValue) }
    let generation = UUID().uuidString.lowercased(), service = "CCL isolated 3.4.1 probe " + UUID().uuidString
    let credential = GitHubCredentialV2(epoch: generation, generation: generation,
        accessToken: "ccl-test-access-" + UUID().uuidString, refreshToken: "ccl-test-refresh-" + UUID().uuidString,
        obtainedAt: 1000, userID: "1001", login: "fixture")
    guard let encoded = try? JSONEncoder().encode(credential) else { check(false, "K341-integration fixture encoding"); return }
    let envelope = encoded.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    func attributeQuery(all: Bool) -> [String: Any] {
        // Explicit search list and UI-fail: never consult the user's keychains.
        return [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: generation,
            kSecMatchSearchList as String: [keychain], kSecReturnAttributes as String: true,
            kSecMatchLimit as String: all ? kSecMatchLimitAll : kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
    }
    func attributes() -> SyncKeychainStatus {
        var resultAttributes: CFTypeRef?
        let result = SecItemCopyMatching(attributeQuery(all: false) as CFDictionary, &resultAttributes)
        return result == errSecSuccess ? .success : result == errSecItemNotFound ? .missing : .failure(result)
    }
    func copyCount() -> Int? {
        var resultAttributes: CFTypeRef?
        let result = SecItemCopyMatching(attributeQuery(all: true) as CFDictionary, &resultAttributes)
        if result == errSecItemNotFound { return 0 }
        guard result == errSecSuccess, let copies = resultAttributes as? [[String: Any]] else { return nil }
        return copies.count
    }
    func nativePresence(_ account: String, delete: Bool = false) -> SyncKeychainStatus {
        let code = githubAuthNativePresence(service: service, generation: account,
            requireUnlocked: true, delete: delete, keychain: keychain)
        return code == 0 ? .success : code == 44 ? .missing : .failure(code)
    }
    do {
        let status = try githubAuthSecurityWrite(service: service, generation: generation, envelope: envelope, keychainPath: path,
            run: githubAuthRunSecurityWriter, attributes: attributes)
        check(status == .success, "K341-integration production writer creates temporary-keychain item")
        let (dumpStatus, dump) = github341TemporarySecurity(["dump-keychain", "-a", path])
        let aclCount = dumpStatus == .success ? github341PartitionMarkerCount(dump) : 0
        // Diagnostic only: dump format of partition lists varies; the silent readback below is the proof.
        print("K341 TEMP KEYCHAIN: apple-tool partition count=\(aclCount) dump=\(dumpStatus == .success ? "ok" : "failed") bytes=\(dump.count)")
        let (readStatus, readback) = github341TemporarySecurity(["find-generic-password", "-s", service, "-a", generation, "-w", path])
        check(readStatus == .success && (readback == Data(envelope.utf8) || readback == Data((envelope + "\n").utf8)),
              "K341-integration security reads exact synthetic envelope without interaction")
        // Duplicate must preserve the existing immutable item and its readable ACL.
        var replacement = credential
        replacement.accessToken = "ccl-test-replacement-access-" + UUID().uuidString
        replacement.refreshToken = "ccl-test-replacement-refresh-" + UUID().uuidString
        let replacementEnvelope = try JSONEncoder().encode(replacement).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        var duplicateExit: SyncKeychainStatus?
        let duplicate = try githubAuthSecurityWrite(service: service, generation: generation, envelope: replacementEnvelope, keychainPath: path,
            run: { args, line in let result = githubAuthRunSecurityWriter(arguments: args, input: line); duplicateExit = result; return result },
            attributes: attributes)
        check(duplicate == .success && duplicateExit != .timedOut, "K341-integration settled duplicate is confirmed by quiet attributes")
        let (duplicateReadStatus, duplicateReadback) = github341TemporarySecurity(["find-generic-password", "-s", service, "-a", generation, "-w", path])
        check(duplicateReadStatus == .success
              && (duplicateReadback == Data(envelope.utf8) || duplicateReadback == Data((envelope + "\n").utf8)),
              "K341-integration duplicate preserves exact original immutable envelope and readable ACL")
        // Both writes used the same generation. Some file keychains enforce
        // service/account uniqueness; observe the actual number, never assume two.
        let copiesBeforeDelete = copyCount()
        var flags: SecKeychainStatus = 0
        let checked = SecKeychainGetStatus(keychain, &flags)
        let unlocked = checked == errSecSuccess && flags & SecKeychainStatus(kSecUnlockStateStatus) != 0
        if unlocked {
            let existed = attributes() == .success
            let removed = try githubAuthSecurityDelete(service: service, generation: generation, keychainPath: path,
                nativeDelete: { nativePresence(generation, delete: true) },
                run: githubAuthRunSecurityWriter, attributes: { nativePresence(generation) })
            let missing = attributes() == .missing
            check(existed && removed == .success && missing,
                  "K341-delete production writer item is removed by native-first helper path and quiet attributes confirm missing")
            if let count = copiesBeforeDelete, count >= 2 {
                check(removed == .success && missing && copyCount() == 0,
                      "K341-delete all same-generation temporary-keychain copies are removed")
            } else {
                print("K341 TEMP DELETE: duplicate setup unavailable (same-generation add-only writes did not expose two attribute matches)")
            }
            var absentRuns = 0
            let absent = try githubAuthSecurityDelete(service: service, generation: generation, keychainPath: path,
                nativeDelete: { nativePresence(generation, delete: true) },
                run: { args, line in
                    absentRuns += 1; return githubAuthRunSecurityWriter(arguments: args, input: line)
                }, attributes: { nativePresence(generation) })
            check(absent == .success && absentRuns == 0 && attributes() == .missing,
                  "K341-delete absent temporary-keychain generation succeeds without an error or child")
        } else {
            print("K341 TEMP DELETE: SKIP (temporary-keychain unlocked preflight unavailable)")
        }
        // Reproduce 3.4.0 provenance: this binary creates the item natively,
        // with no security trust entry. The query and every delete stay scoped.
        let nativeGeneration = UUID().uuidString.lowercased()
        var nativeCredential = credential; nativeCredential.generation = nativeGeneration
        let nativeEnvelope = try JSONEncoder().encode(nativeCredential).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let nativeItem: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: nativeGeneration,
            kSecValueData as String: Data(nativeEnvelope.utf8), kSecUseKeychain as String: keychain,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
        let added = SecItemAdd(nativeItem as CFDictionary, nil)
        if added == errSecSuccess, nativePresence(nativeGeneration) == .success {
            var nativeRuns = 0, securityRuns = 0
            var nativeResult: SyncKeychainStatus?
            let removed = try githubAuthSecurityDelete(service: service, generation: nativeGeneration, keychainPath: path,
                nativeDelete: {
                    nativeRuns += 1
                    let result = nativePresence(nativeGeneration, delete: true)
                    nativeResult = result; return result
                },
                run: { _, _ in
                    // Fail closed: a native-only fixture must never launch a
                    // potentially prompting security process if its ACL is unsupported.
                    securityRuns += 1; return .failure(36)
                }, attributes: { nativePresence(nativeGeneration) })
            check(nativeRuns > 0, "K341-delete-native-temp present native-created item must reach the native adapter")
            if let result = nativeResult, result != .success && result != .missing {
                print("K341 TEMP DELETE: native-created item could not be deleted by its creator; security fallback suppressed to prevent UI")
            } else {
                let missing = nativePresence(nativeGeneration) == .missing
                let nativeRemoved = removed == .success && missing && nativeRuns == 1 && securityRuns == 0
                check(nativeRemoved, "K341-delete-native-temp SecItemAdd item is removed quietly through the helper's native-first function")
            }
        } else {
            print("K341 TEMP DELETE: native SecItemAdd fixture or unlocked attributes unavailable (add status=\(added))")
        }
        // The real `security -i` exit code against an absent keychain is the evidence here;
        // the stubbed attributes alone would make any outcome look like a failure.
        let missingPath = root.appendingPathComponent("absent.keychain-db").path
        var missingExit: SyncKeychainStatus?
        let failure = try githubAuthSecurityWrite(service: service, generation: generation,
            envelope: envelope, keychainPath: missingPath,
            run: { args, line in let result = githubAuthRunSecurityWriter(arguments: args, input: line); missingExit = result; return result },
            attributes: { .missing })
        let exitLabel: String
        switch missingExit {
        case .success?: exitLabel = "0"
        case .failure(let code)?: exitLabel = String(code)
        case .timedOut?: exitLabel = "timeout"
        case .missing?: exitLabel = "missing"
        case nil: exitLabel = "not-run"
        }
        print("K341 TEMP KEYCHAIN: missing-keychain exit=\(exitLabel)")
        // security -i may exit 0 on a failed subcommand; the writer must still report failure via quiet attributes.
        let writerFailed: Bool
        if case .failure(let code) = failure { writerFailed = code != 0 } else { writerFailed = false }
        check(writerFailed, "K341-integration failed add to an absent keychain is reported by the writer as a nonzero failure")
    } catch { check(false, "K341-integration production writer/delete adapter rejected isolated fixture") }
#else
    print("K341 TEMP KEYCHAIN: SKIP (requires macOS temporary-keychain capability)")
    print("K341 TEMP DELETE: SKIP (requires macOS temporary-keychain capability)")
#endif
}
