import Foundation

// Independent contract fixture: no native store, app, filesystem or network adapters.
let activeRef = GitHubAuthRef(generation: "11111111-1111-4111-8111-111111111111")
let secondRef = GitHubAuthRef(generation: "22222222-2222-4222-8222-222222222222")
let thirdRef = GitHubAuthRef(generation: "33333333-3333-4333-8333-333333333333")
let legacyRef = GitHubAuthRef(generation: "legacy", backend: "legacy-keychain")
let fixtureEpoch = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
let canaryAccess = "INDEPENDENT_SYNTHETIC_ACCESS_QUIET"
let canaryRefresh = "INDEPENDENT_SYNTHETIC_REFRESH_QUIET"
struct Event { let operation: String; let ref: GitHubAuthRef; let interactive: Bool }
struct TestFailure: Error { let message: String }
func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw TestFailure(message: message) }
}
func isReady(_ value: GitHubAuthResult) -> Bool { if case .ready = value { return true }; return false }
func isTemporary(_ value: GitHubAuthResult) -> Bool { if case .temporary = value { return true }; return false }
func credential(_ ref: GitHubAuthRef = activeRef, expires: Double? = nil) -> GitHubCredentialV2 {
    GitHubCredentialV2(epoch: fixtureEpoch, generation: ref.generation, accessToken: canaryAccess,
        refreshToken: canaryRefresh, obtainedAt: 0, accessExpiresAt: expires, userID: "42", login: "fixture")
}
final class Fixture {
    var now: Double = 10_000
    var mono: Double = 0
    var manifest: GitHubAuthManifest? = GitHubAuthManifest(epoch: fixtureEpoch, active: activeRef, userID: "42", login: "fixture")
    var items: [GitHubAuthRef: GitHubCredentialV2] = [activeRef: credential()]
    var events: [Event] = []
    var saves: [GitHubAuthManifest] = []
    var violations: [String] = []
    var posts = 0
    var identities = 0
    var allowHTTP = false
    var allowIdentity = false
    var idle = true
    var actionCurrent = true
    var interactiveAfterCancel = 0
    var interactiveDispatches = 0
    var cancelAction: (() -> Void)?
    func cancelUserAction() { actionCurrent = false; cancelAction?() }
#if SNAPSHOT2
    var beforeAdmission: ((GitHubAuthUserAction) -> Void)?
    var lastAction: GitHubAuthUserAction?
    func admitRead(_ ref: GitHubAuthRef, _ action: GitHubAuthUserAction) -> GitHubAuthRead {
        interactiveDispatches += 1; lastAction = action; beforeAdmission?(action)
        var result: GitHubAuthRead = .locked
        _ = action.admit { result = read(ref, true) }
        return result
    }
    func admitStage(_ ref: GitHubAuthRef, _ c: GitHubCredentialV2, _ action: GitHubAuthUserAction) -> GitHubAuthStoreStatus {
        interactiveDispatches += 1; lastAction = action; beforeAdmission?(action)
        var result: GitHubAuthStoreStatus = .locked
        _ = action.admit { result = stage(ref, c, true) }
        return result
    }
    func admitDelete(_ ref: GitHubAuthRef, _ action: GitHubAuthUserAction) -> GitHubAuthStoreStatus {
        interactiveDispatches += 1; lastAction = action; beforeAdmission?(action)
        var result: GitHubAuthStoreStatus = .locked
        _ = action.admit { result = delete(ref, true) }
        return result
    }
    func admitLegacy(_ action: GitHubAuthUserAction) -> GitHubAuthRead {
        interactiveDispatches += 1; lastAction = action; beforeAdmission?(action)
        var result: GitHubAuthRead = .locked
        _ = action.admit { result = legacy(true) }
        return result
    }
#endif
    var readHook: ((GitHubAuthRef, Bool) -> GitHubAuthRead?)?
    var stageHook: ((GitHubAuthRef, GitHubCredentialV2, Bool) -> GitHubAuthStoreStatus?)?
    var deleteHook: ((GitHubAuthRef, Bool) -> GitHubAuthStoreStatus?)?
    var settledHook: ((GitHubAuthRef) -> Bool)?
    var checkpointHook: ((String) -> Void)?
    var legacyValue: GitHubAuthRead = .missing
    var legacyHook: ((Bool) -> GitHubAuthRead)?
    func record(_ operation: String, _ ref: GitHubAuthRef, _ interactive: Bool) {
        events.append(Event(operation: operation, ref: ref, interactive: interactive))
        if interactive && !actionCurrent { interactiveAfterCancel += 1 }
    }
    func read(_ ref: GitHubAuthRef, _ interactive: Bool) -> GitHubAuthRead {
        record("read", ref, interactive)
        return readHook?(ref, interactive) ?? items[ref].map { .ready($0) } ?? .missing
    }
    func stage(_ ref: GitHubAuthRef, _ c: GitHubCredentialV2, _ interactive: Bool) -> GitHubAuthStoreStatus {
        record("stage", ref, interactive)
        if let r = stageHook?(ref, c, interactive) { return r }
        items[ref] = c; return .success
    }
    func delete(_ ref: GitHubAuthRef, _ interactive: Bool) -> GitHubAuthStoreStatus {
        record("delete", ref, interactive)
        if let r = deleteHook?(ref, interactive) { return r }
        items.removeValue(forKey: ref); return .success
    }
    func legacy(_ interactive: Bool) -> GitHubAuthRead {
        record("legacy", legacyRef, interactive)
        return legacyHook?(interactive) ?? legacyValue
    }
    func owner() -> GitHubAuthOwner {
        var d = GitHubAuthDependencies(clock: { self.now }, loadManifest: { self.manifest },
            saveManifest: { self.manifest = $0; self.saves.append($0) },
            readStore: { self.read($0, false) }, stageStore: { self.stage($0, $1, false) },
            deleteStore: { self.delete($0, false) }, transport: { _ in
                self.posts += 1
                if !self.allowHTTP { self.violations.append("unexpected fake issuer call") }
                return GitHubAuthHTTP(status: 200, json: ["access_token": canaryAccess,
                    "refresh_token": canaryRefresh, "expires_in": 7200])
            }, identity: { _ in
                self.identities += 1
                if !self.allowIdentity { self.violations.append("unexpected fake identity call") }
                return .ready(userID: "42", login: "fixture")
            }, withLock: { try $0() }, checkpoint: { name, _, _ in self.checkpointHook?(name) },
            jitter: { 0 }, legacy: { self.legacy(false) }, settled: { self.settledHook?($0) ?? true },
            monotonicClock: { self.mono }, storeIdle: { self.idle })
#if SNAPSHOT2
        d.interactiveReadStore = { self.admitRead($0, $1) }
        d.interactiveStageStore = { self.admitStage($0, $1, $2) }
        d.interactiveDeleteStore = { self.admitDelete($0, $1) }
        d.interactiveLegacy = { self.admitLegacy($0) }
#else
        d.interactiveReadStore = { self.interactiveDispatches += 1; return self.read($0, true) }
        d.interactiveStageStore = { self.interactiveDispatches += 1; return self.stage($0, $1, true) }
        d.interactiveDeleteStore = { self.interactiveDispatches += 1; return self.delete($0, true) }
        d.interactiveLegacy = { self.interactiveDispatches += 1; return self.legacy(true) }
#endif
        return GitHubAuthOwner(dependencies: d, clientID: "independent-fixture-only")
    }
    var interactiveEvents: [Event] { events.filter { $0.interactive } }
    func advance(_ seconds: Double = 601) { mono += seconds; now += seconds }
    func safety() throws { try expect(violations.isEmpty, violations.first ?? "unexpected fake effect") }
}
var passed = 0
var failed = 0
func test(_ name: String, _ body: () throws -> Void) {
    do { try body(); passed += 1; print("PASS \(name)") }
    catch let error as TestFailure { failed += 1; print("FAIL \(name): \(error.message)") }
    catch { failed += 1; print("FAIL \(name): unexpected error (redacted)") }
}

test("policy.configure-false-failure-no-RPC") {
    for interactive in [false, true] {
        var calls = 0; var settings: [Bool] = []
        let r = githubAuthHelperInteraction(interactive: interactive,
            setAllowed: { settings.append($0); return false }, operation: { calls += 1; return 0 })
        try expect(r != 0 && calls == 0 && settings == [false], "configuration failure reached RPC or escalation")
    }
}
test("policy.configure-true-failure-no-RPC") {
    var calls = 0; var settings: [Bool] = []
    let r = githubAuthHelperInteraction(interactive: true,
        setAllowed: { settings.append($0); return !$0 }, operation: { calls += 1; return 0 })
    try expect(r != 0 && calls == 0 && settings == [false, true], "interactive configuration failure reached RPC")
}
test("policy.quiet-and-explicit-allow-order") {
    for interactive in [false, true] {
        var trace: [String] = []
        let r = githubAuthHelperInteraction(interactive: interactive,
            setAllowed: { trace.append($0 ? "allow" : "deny"); return true }, operation: { trace.append("rpc"); return 37 })
        try expect(r == 37 && trace == (interactive ? ["deny", "allow", "rpc"] : ["deny", "rpc"]), "wrong policy order or result")
    }
}
test("boundary.arguments-default-quiet-and-reject-malformed") {
    for ref in [activeRef, legacyRef] {
        for op in ["read", "delete"] {
            guard let args = githubAuthKeychainArguments(operation: op, ref: ref),
                  let request = GitHubKeychainHelperRequest.parse(["fixture"] + args) else { throw TestFailure(message: "valid request rejected") }
            try expect(!request.interactive && request.generation == ref.generation && request.operation == op, "default request not exact and quiet")
            try expect(!args.joined().contains(canaryAccess), "secret in helper argv")
        }
    }
    for args in [
        ["fixture", "--github-auth-keychain-helper", "read", activeRef.generation, "allow-all"],
        ["fixture", "--github-auth-keychain-helper", "read", "../invalid", "quiet"],
        ["fixture", "--github-auth-keychain-helper", "legacy-write", "legacy", "interactive"],
        ["fixture", "--github-auth-keychain-helper", "delete", activeRef.generation, "quiet", "extra"]] {
        try expect(GitHubKeychainHelperRequest.parse(args) == nil, "malformed request accepted")
    }
    try expect(githubAuthKeychainArguments(operation: "read", ref: GitHubAuthRef(generation: activeRef.generation, backend: "arbitrary")) == nil, "untrusted backend accepted")
}
test("owner.background-read-storage-error-preserves-state") {
    for failure: GitHubAuthRead in [.locked, .timeout, .unreachable] {
        let f = Fixture(); let before = f.manifest; let items = f.items
        f.readHook = { _, _ in failure }
        let o = f.owner()
        for reason in ["startup", "wake", "timer"] { _ = o.ensureAccess(reason: reason); f.advance() }
        _ = o.readCredential()
        try expect(f.events.contains { $0.operation == "read" }, "vacuous no-read fixture")
        try expect(f.interactiveEvents.isEmpty && f.manifest == before && f.items == items, "background escalated or credentials/metadata changed")
        try expect(o.snapshot().state == "unavailable", "storage failure became missing/revoked")
        try f.safety()
    }
}
test("owner.legacy-background-and-manual-scope") {
    let f = Fixture(); f.manifest = nil
    f.legacyHook = { interactive in interactive ? .ready(credential()) : .locked }
    let o = f.owner(); _ = o.readCredential(); f.advance(); _ = o.ensureAccess(reason: "startup")
    try expect(f.interactiveEvents.isEmpty && f.events.count >= 2, "legacy background escalated")
    try expect(isReady(o.retryKeychainAccess()) && f.interactiveEvents.count == 1, "legacy explicit retry not bounded")
    _ = o.ensureAccess(reason: "wake")
    try expect(f.interactiveEvents.count == 1, "legacy permit escaped explicit action")
    try f.safety()
}
test("owner.background-probe-stage-locked-no-interactive") {
    let f = Fixture(); f.items[activeRef] = credential(expires: f.now - 1)
    f.stageHook = { _, _, _ in .locked }
    let o = f.owner(); let r = o.ensureAccess(reason: "timer")
    try expect(isTemporary(r) && f.events.contains { $0.operation == "stage" }, "stage path not reached")
    try expect(f.interactiveEvents.isEmpty && f.manifest?.active == activeRef && f.posts == 0, "blocked probe escalated, published, or called issuer")
    try expect(f.manifest?.transition != nil && !(f.manifest?.cleanupRefs.isEmpty ?? true), "probe metadata lost")
    try f.safety()
}
test("owner.background-candidate-stage-and-readback") {
    for failReadback in [false, true] {
        let f = Fixture(); f.items[activeRef] = credential(expires: f.now - 1)
        f.allowHTTP = true
        if failReadback {
            f.readHook = { ref, _ in if ref != activeRef, f.items[ref]?.kind == "credential" { return .locked }; return nil }
        } else {
            f.stageHook = { _, c, _ in c.kind == "credential" ? .locked : nil }
        }
        let o = f.owner(); let r = o.ensureAccess(reason: "timer")
        try expect(f.posts == 1 && isTemporary(r), "candidate stage/readback path not reached")
        try expect(f.interactiveEvents.isEmpty && f.manifest?.active == activeRef && f.manifest?.transition != nil, "candidate failure escalated/published/dropped intent")
        try expect(f.identities == 0, "identity reached after unverified store")
        try f.safety()
    }
}
test("owner.background-delete-GC-preserves-blocked-ref") {
    let f = Fixture(); f.manifest?.cleanupRefs = [secondRef, thirdRef, legacyRef]; f.items[secondRef] = credential(secondRef)
    f.deleteHook = { _, _ in .locked }
    let o = f.owner(); o.cleanupRetiredCredentials()
    try expect(f.events.contains { $0.operation == "delete" && $0.ref == secondRef }, "GC delete not reached")
    try expect(f.interactiveEvents.isEmpty && f.manifest?.cleanupRefs.contains(secondRef) == true && f.items[activeRef] != nil, "GC escalated or lost ref/active")
    try f.safety()
}
test("owner.manual-one-budget-across-read-and-probe") {
    let f = Fixture(); f.items[activeRef] = credential(expires: f.now - 1)
    var quietActiveReads = 0
    f.readHook = { ref, interactive in
        if ref == activeRef && !interactive {
            quietActiveReads += 1
            if quietActiveReads == 1 { return .locked }
        }
        return nil
    }
    f.stageHook = { _, _, _ in .locked }
    let o = f.owner(); _ = o.retryKeychainAccess()
    try expect(f.interactiveEvents.count == 1 && f.interactiveEvents[0].operation == "read", "manual pass spent more than one permit")
    try expect(f.events.contains { $0.operation == "stage" && !$0.interactive }, "second blocked operation not reached")
    try expect(f.posts == 0, "issuer reached after failed probe")
    try f.safety()
}
test("owner.manual-deny-timeout-no-auto-interactive-retry") {
    for response: GitHubAuthRead in [.locked, .timeout, .unreachable] {
        let f = Fixture(); f.readHook = { _, interactive in interactive ? response : .locked }
        let o = f.owner(); _ = o.retryKeychainAccess()
        for _ in 0..<3 { f.advance(); _ = o.ensureAccess(reason: "wake") }
        try expect(f.interactiveEvents.count == 1 && f.manifest?.active == activeRef && f.items[activeRef] != nil, "denial/timeout retried interactively or deleted credential")
        try f.safety()
    }
}
test("owner.timeout-and-unsettled-stage-never-escalate") {
    for status: GitHubAuthStoreStatus in [.timeout, .locked] {
        let f = Fixture(); f.items[activeRef] = credential(expires: f.now - 1)
        f.stageHook = { _, _, _ in status }; f.settledHook = { _ in false }
        _ = f.owner().retryKeychainAccess()
        try expect(f.events.contains { $0.operation == "stage" } && f.interactiveEvents.isEmpty, "unknown writer got interactive retry")
        try f.safety()
    }
}
test("owner.selected-signedout-GC-one-ref-one-permit") {
    let f = Fixture(); f.manifest?.signedOut = true; f.manifest?.active = nil
    f.manifest?.cleanupRefs = [secondRef, thirdRef, legacyRef]
    f.readHook = { _, interactive in interactive ? .missing : .locked }
    let o = f.owner(); _ = o.retryKeychainAccess()
    try expect(f.interactiveEvents.count == 1 && f.interactiveEvents[0].ref == secondRef, "GC permit was not selected ref only")
    try expect(!f.manifest!.cleanupRefs.contains(secondRef) && f.manifest!.cleanupRefs.contains(thirdRef), "GC lost blocked sibling or retained successful selected ref")
    f.advance(); _ = o.ensureAccess(reason: "startup")
    try expect(f.interactiveEvents.count == 1, "GC manual permit leaked to background")
    try f.safety()
}
test("owner.selected-GC-delete-can-spend-single-budget") {
    let f = Fixture(); f.manifest?.signedOut = true; f.manifest?.active = nil; f.manifest?.cleanupRefs = [secondRef, thirdRef]
    f.deleteHook = { _, interactive in interactive ? nil : .locked }
    _ = f.owner().retryKeychainAccess()
    try expect(f.interactiveEvents.count == 1 && f.interactiveEvents[0].operation == "delete" && f.interactiveEvents[0].ref == secondRef, "delete permit escaped selection/budget")
    try expect(f.manifest?.cleanupRefs.contains(thirdRef) == true, "blocked sibling forgotten")
    try f.safety()
}
test("owner.allow-then-restart-and-600-boundaries-stay-quiet") {
    let f = Fixture(); f.readHook = { _, interactive in interactive ? nil : .locked }
    var o = f.owner(); _ = o.retryKeychainAccess()
    try expect(f.interactiveEvents.count == 1, "explicit Allow control not reached")
    for monotonic in [0.0, 599, 600, 601, 1201] {
        f.mono = monotonic; f.now = monotonic == 599 ? -100_000 : 1_000_000
        if monotonic == 601 { o = f.owner() }
        _ = o.ensureAccess(reason: "wake")
    }
    try expect(f.interactiveEvents.count == 1 && f.events.filter { !$0.interactive }.count >= 4, "restart/time gate masked or enabled UI")
    try f.safety()
}
test("owner.reentrant-manual-and-busy-process-blocked") {
    let f = Fixture(); let o = f.owner(); var nested: GitHubAuthResult?
    f.readHook = { _, interactive in if !interactive { nested = o.retryKeychainAccess(); return .locked }; return nil }
    _ = o.retryKeychainAccess()
    try expect(nested.map(isTemporary) == true && f.interactiveEvents.count == 1, "contending action created another permit")
    let before = f.events.count; f.idle = false; _ = o.retryKeychainAccess()
    try expect(f.events.count == before, "busy process admitted store work")
    try f.safety()
}
test("fence.timeout-is-not-process-completion") {
    let f = GitHubAuthProcessFence()
    try expect(f.isIdle && f.begin() && !f.isIdle && !f.begin(), "process fence admitted overlap")
    // A caller timing out performs no ended() acknowledgement.
    try expect(!f.begin(), "timeout implicitly released lease")
    f.ended(); try expect(f.isIdle && f.begin(), "completion failed to release lease"); f.ended()
}
test("owner.epoch-change-before-publish-preserves-new-generation") {
    let f = Fixture(); f.manifest?.transition = GitHubAuthTransition(from: activeRef, to: secondRef, phase: "ready")
    f.items[secondRef] = credential(secondRef); f.allowIdentity = true
    var changed = false
    f.checkpointHook = { name in
        if name == "before_publish" {
            changed = true; f.manifest = GitHubAuthManifest(epoch: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", active: thirdRef)
        }
    }
    _ = f.owner().ensureAccess(reason: "startup")
    try expect(changed && f.manifest?.active == thirdRef && f.manifest?.epoch != fixtureEpoch, "late candidate overwrote newer epoch")
    try expect(f.events.allSatisfy { $0.operation != "delete" }, "late candidate deleted newer state")
    try f.safety()
}
test("owner.unresolved-credential-writer-must-still-block-recovery") {
    let f = Fixture(); f.items[activeRef] = credential(expires: f.now - 1)
    f.manifest?.transition = GitHubAuthTransition(from: activeRef, to: secondRef, phase: "requestStarted")
    f.manifest?.uncertainRefs = [secondRef]; f.manifest?.permitWriterRefs = [secondRef]
    f.settledHook = { _ in false }
    let o = f.owner()
    for _ in 0..<6 { _ = o.ensureAccess(reason: "startup"); f.advance() }
    try expect(f.posts == 0 && f.manifest?.active == activeRef && f.manifest?.transition?.to == secondRef, "unknown credential writer lost its fence")
    try expect(f.manifest?.uncertainRefs.contains(secondRef) == true && f.interactiveEvents.isEmpty, "unknown credential state lost/escalated")
    try f.safety()
}
test("owner.completed-login-cancel-before-publication-tombstones") {
    let f = Fixture(); f.manifest = nil; f.items = [:]
    let o = f.owner()
    guard let epoch = o.beginLogin() else { throw TestFailure(message: "login setup failed") }
    f.allowIdentity = true
    f.checkpointHook = { if $0 == "before_publish" { f.actionCurrent = false } }
    _ = o.completeLogin(response: ["access_token": canaryAccess, "refresh_token": canaryRefresh],
                        epoch: epoch, isCurrent: { f.actionCurrent })
    try expect(!f.actionCurrent && f.manifest?.signedOut == true && f.manifest?.active == nil, "cancelled candidate published or no tombstone")
    try expect(f.interactiveEvents.isEmpty, "complete/cancel obtained interactive permit")
    try f.safety()
}
test("owner.synthetic-secrets-absent-from-manifest-and-trace") {
    let f = Fixture(); f.items[activeRef] = credential(expires: f.now - 1); f.allowHTTP = true; f.allowIdentity = true
    let o = f.owner(); try expect(isReady(o.ensureAccess(reason: "timer")), "healthy positive control did not publish")
    o.cleanupRetiredCredentials()
    for m in f.saves {
        let data = try JSONEncoder().encode(m); let s = String(decoding: data, as: UTF8.self)
        try expect(!s.contains(canaryAccess) && !s.contains(canaryRefresh), "secret leaked to manifest")
    }
    let trace = f.events.map { "\($0.operation) \($0.ref.generation) \($0.interactive)" }.joined(separator: "\n")
    try expect(!trace.contains(canaryAccess) && !trace.contains(canaryRefresh), "secret leaked to diagnostic trace")
    try f.safety()
}
// Regression P2: caller cancels its explicit login while the quiet backend is running.
// Snapshot1 has no current-action callback on beginLogin; the external intent is modeled
// here exactly at the dependency boundary, without starting the real UI/queue.
test("P2.cancel-between-quiet-and-interactive") {
    let f = Fixture(); f.manifest = nil; f.items = [:]
    f.readHook = { _, interactive in
        if !interactive { f.cancelUserAction(); return .locked }
        return .locked
    }
    try expect(f.actionCurrent, "cancel fixture started already cancelled")
#if SNAPSHOT2
    let action = GitHubAuthUserAction(); f.cancelAction = { action.cancel() }
    _ = f.owner().beginLogin(action: action)
#else
    _ = f.owner().beginLogin()
#endif
    try expect(!f.actionCurrent && f.events.contains { !$0.interactive }, "cancel interleaving not reached")
    try expect(f.interactiveAfterCancel == 0 && f.interactiveDispatches == 0, "interactive callback invoked after explicit action was cancelled")
    try f.safety()
}
// Regression P2: an indeterminate *probe*, containing no credentials, must not pin
// all future renewal forever once the helper has ended. Old ref stays tracked;
// credential-bearing unresolved writers must still fence publication/recovery.
test("P2.unknown-probe-liveness-after-restart") {
    let f = Fixture(); f.items[activeRef] = credential(expires: f.now - 1)
    f.allowHTTP = true; f.allowIdentity = true
    var unknownProbe: GitHubAuthRef?
    f.stageHook = { ref, c, _ in
        if c.kind == "probe" && unknownProbe == nil {
            unknownProbe = ref; f.items[ref] = c; return .timeout
        }
        return nil
    }
    f.settledHook = { ref in ref != unknownProbe }
    _ = f.owner().ensureAccess(reason: "timer")
    try expect(unknownProbe != nil && f.posts == 0 && f.manifest?.uncertainRefs.contains(unknownProbe!) == true, "unknown probe setup failed")
    // Restart loses process-local completion proof; simulated adapter is idle, old RPC
    // result remains unknown. Six fully admitted passes cover all existing backoffs.
    let restarted = f.owner(); var recovered = false
    for _ in 0..<6 { f.advance(); if isReady(restarted.ensureAccess(reason: "wake")) { recovered = true; break } }
    let newProbeStaged = f.events.contains { $0.operation == "stage" && $0.ref != unknownProbe && $0.ref != activeRef }
    print("EVIDENCE unknown-probe: recovered=\(recovered) fresh-stage=\(newProbeStaged) fake-issuer-calls=\(f.posts) idle=\(f.idle)")
    try expect(recovered && newProbeStaged && f.posts == 1, "idle restart remained pinned by unresolved noncredential probe through six admitted passes")
    try expect(f.manifest?.cleanupRefs.contains(unknownProbe!) == true && f.manifest?.uncertainRefs.contains(unknownProbe!) == true, "unknown old probe lost from cleanup/uncertainty journal")
    try expect(f.interactiveEvents.isEmpty, "background probe recovery escalated")
    try f.safety()
}
#if SNAPSHOT2
// New API boundary controls, derived independently from action-scoping and fencing.
test("action.cancel-before-admit-and-single-launch") {
    let cancelled = GitHubAuthUserAction(); cancelled.cancel(); var launches = 0
    try expect(!cancelled.admit { launches += 1 } && launches == 0, "cancelled action admitted launch")
    let live = GitHubAuthUserAction()
    try expect(live.admit { launches += 1 }, "fresh action refused first launch")
    try expect(!live.admit { launches += 1 } && launches == 1, "action admitted second launch")
    live.cancel(); try expect(live.isCancelled && !live.admit { launches += 1 }, "cancel resurrected permission")
}
test("action.launch-error-does-not-reset-budget") {
    let action = GitHubAuthUserAction(); var attempts = 0
    do { _ = try action.admit { attempts += 1; throw TestFailure(message: "synthetic launch failure") } }
    catch is TestFailure { }
    try expect(!action.admit { attempts += 1 } && attempts == 1, "throwing launch reset user budget")
}
test("owner.cancel-after-callback-before-launch-no-RPC") {
    let f = Fixture(); f.readHook = { _, _ in .locked }
    f.beforeAdmission = { action in f.actionCurrent = false; action.cancel() }
    _ = f.owner().retryKeychainAccess()
    try expect(f.interactiveDispatches == 1 && f.interactiveEvents.isEmpty, "cancelled callback launched simulated RPC")
    try expect(f.lastAction?.isCancelled == true, "action capability survived cancellation")
    try f.safety()
}
test("owner.action-invalidated-on-success-and-on-failure") {
    for succeeds in [false, true] {
        let f = Fixture(); f.readHook = { _, interactive in interactive && succeeds ? nil : .locked }
        let action = GitHubAuthUserAction(); _ = f.owner().retryKeychainAccess(action: action)
        var escapedLaunch = false
        try expect(action.isCancelled && !action.admit { escapedLaunch = true } && !escapedLaunch, "finished action leaked reusable launch capability")
        try f.safety()
    }
}
test("owner.pre-cancelled-login-has-no-store-or-metadata-effects") {
    let f = Fixture(); let before = f.manifest; let action = GitHubAuthUserAction(); action.cancel()
    let result = f.owner().beginLogin(action: action)
    try expect(result == nil && f.events.isEmpty && f.saves.isEmpty && f.manifest == before, "pre-cancelled login mutated state")
    try f.safety()
}
test("owner.probe-rollover-waits-for-idle-and-retains-old-address") {
    let f = Fixture(); f.items[activeRef] = credential(expires: f.now - 1)
    f.manifest?.transition = GitHubAuthTransition(from: activeRef, to: secondRef, phase: "prepared", probe: thirdRef)
    f.manifest?.uncertainRefs = [thirdRef]; f.manifest?.cleanupRefs = [thirdRef]
    f.settledHook = { $0 != thirdRef }; f.idle = false
    let o = f.owner(); _ = o.ensureAccess(reason: "wake")
    try expect(f.manifest?.transition?.probe == thirdRef && f.events.isEmpty && f.posts == 0, "busy writer allowed probe rollover")
    f.idle = true; f.advance(); _ = o.ensureAccess(reason: "wake")
    try expect(f.manifest?.transition?.probe != thirdRef && f.manifest?.cleanupRefs.contains(thirdRef) == true && f.manifest?.uncertainRefs.contains(thirdRef) == true, "idle probe not safely rolled over")
    try expect(f.posts == 0 && f.interactiveDispatches == 0, "probe rollover itself called issuer/interactive backend")
    try f.safety()
}
test("owner.manual-probe-rollover-does-not-authorize-GC") {
    let f = Fixture(); f.items[activeRef] = credential(expires: f.now - 1)
    f.manifest?.transition = GitHubAuthTransition(from: activeRef, to: secondRef, phase: "prepared", probe: thirdRef)
    f.manifest?.uncertainRefs = [thirdRef]; f.manifest?.cleanupRefs = [thirdRef]
    f.settledHook = { $0 != thirdRef }; f.allowHTTP = true; f.allowIdentity = true
    let o = f.owner(); _ = o.retryKeychainAccess(); f.advance()
    try expect(isReady(o.retryKeychainAccess()), "manual renewal did not recover after rollover")
    f.readHook = { ref, _ in ref == thirdRef ? .locked : nil }
    o.cleanupRetiredCredentials()
    try expect(f.events.contains { $0.operation == "read" && $0.ref == thirdRef }, "old probe cleanup not reached")
    try expect(f.interactiveDispatches == 0 && f.manifest?.cleanupRefs.contains(thirdRef) == true, "GC inherited manual permit or forgot old ref")
    try f.safety()
}
#endif
print("RESULT passed=\(passed) failed=\(failed) total=\(passed + failed)")
exit(failed == 0 ? 0 : 1)
