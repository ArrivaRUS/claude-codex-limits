import Foundation

// Standalone synthetic regression. Compile ONLY with Sources/QuotaRefresh.swift.
// No AppKit, Process, files, UserDefaults, network, Keychain, or production startup.
@main
struct PendingRecoveryRegression {
    static func main() {
        var checks = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            precondition(value, label) // labels never include credential payloads
        }
        func blob(_ value: String) -> Data {
            // Deliberately fake, fixed values. No user-derived input.
            Data("{\"claudeAiOauth\":{\"accessToken\":\"fixture-\(value)\"}}".utf8)
        }
        let old = blob("old"), rotated = blob("rotated"), newLogin = blob("new-cli")
        let candidate = ClaudeQuotaUpdate(expected: old, replacement: rotated)
        var pending: ClaudeQuotaUpdate?
        var current = old
        var requiresPermission = true
        var writeSucceeds = false
        var trace: [String] = []
        var renewals = 0
        func quietWrite(_ value: ClaudeQuotaUpdate) -> Bool {
            trace.append("write:quiet")
            guard writeSucceeds, current == value.expected else { return false }
            current = value.replacement; return true
        }
        func resolve(_ permit: QuotaKeychainReadPermit? = nil, now: Double = 1000) -> QuotaPendingResolution {
            let outcome = quotaReconcilePendingCredential(pending, read: {
                if let permit = permit {
                    guard permit.admit(now: now, launch: { trace.append("read:interactive") }) else {
                        return .failed(.cancelled)
                    }
                } else {
                    trace.append("read:quiet")
                    if requiresPermission { return .failed(.readInteractionRequired) }
                }
                return .credentials(current)
            }, quietUpdate: quietWrite, cancelled: { permit?.isCancelled == true })
            if outcome.retirePending { pending = nil }
            return outcome
        }

        // Explicit read -> synthetic renewal -> quiet write denied. The candidate is retained.
        let first = resolve(QuotaKeychainReadPermit(now: 1000))
        check(first.read == .credentials(old), "explicit read feeds current credentials directly")
        renewals += 1; pending = candidate
        check(!quietWrite(candidate), "quiet update denial is observed")
        check(trace == ["read:interactive", "write:quiet"] && pending == candidate, "no second read or interactive write after permission")

        // CLI sign-in replaced the record but the next quiet READ needs permission.
        current = newLogin; trace = []
        let denied = resolve()
        check(denied.read == .failed(.readInteractionRequired), "read failure must not collapse to write unavailable")
        check(!denied.retirePending && pending == candidate && trace == ["read:quiet"], "read denial keeps pending without attempting old write")
        let feedback = quotaRefreshFeedback(inFlight: false, serverUntil: nil, localUntil: 0, failed: true,
            authenticationRequired: true, dataAt: nil, nextAutomaticAt: nil, now: 1000, english: true,
            credentialIssue: .readInteractionRequired)
        check(feedback.action == .allowKeychain, "explicit read gate is reachable after CLI login")

        // Explicit read of that distinct login recovers; the old pending pair is never written.
        trace = []
        let secondPermit = QuotaKeychainReadPermit(now: 1100)
        let recovered = resolve(secondPermit, now: 1101)
        check(recovered.read == .credentials(newLogin) && recovered.retirePending && pending == nil, "new CLI login supersedes pending candidate")
        check(current == newLogin && trace == ["read:interactive"] && renewals == 1, "recovery neither overwrites CLI login nor renews old pair again")
        check(!secondPermit.admit(now: 1102, launch: { trace.append("unexpected") }), "read permit remains one-shot after recovery")

        // Same original record: read first, then quiet retry; failure retains the rotated pair.
        pending = candidate; current = old; requiresPermission = false; trace = []
        let writeFailed = resolve()
        check(writeFailed.read == .failed(.writeUnavailable) && pending == candidate, "write origin is retained separately from read origin")
        check(trace == ["read:quiet", "write:quiet"] && renewals == 1, "old record retry never enters renewal")
        writeSucceeds = true; trace = []
        let persisted = resolve()
        if case .credentials(let saved) = persisted.read {
            check(quotaClaudeCredentialIdentity(saved) == quotaClaudeCredentialIdentity(rotated)
                  && pending == nil && current == saved, "successful retry returns persisted rotated credentials")
        } else { check(false, "successful retry must return credentials") }
        check(trace == ["read:quiet", "write:quiet"], "successful retry uses only quiet write")

        // A prior timed-out writer already committed: readback clears without rewriting.
        pending = candidate; current = rotated; trace = []
        let committed = resolve()
        check(committed.retirePending && committed.read == .credentials(rotated) && pending == nil, "already committed candidate is recognized")
        check(trace == ["read:quiet"], "already committed candidate requires no write")

        // Same credential pair with changed serialization/MCP/OAuth metadata is not a new login.
        let oldMetadata = Data("{ \"mcpOAuth\": {\"fixture\":\"keep-current\"}, \"claudeAiOauth\": {\"subscriptionType\":\"fixture-new-tier\", \"accessToken\":\"fixture-old\"} }".utf8)
        var rebasedCalls: [ClaudeQuotaUpdate] = []
        let deniedRebase = quotaReconcilePendingCredential(candidate, read: { .credentials(oldMetadata) }, quietUpdate: { value in
            rebasedCalls.append(value); return false
        })
        check(deniedRebase.read == .failed(.writeUnavailable) && !deniedRebase.retirePending && rebasedCalls.count == 1,
              "metadata-only change retains pending and cannot re-enter old OAuth")
        check(rebasedCalls[0].expected == oldMetadata, "native compare uses current exact bytes")
        let merged = try! JSONSerialization.jsonObject(with: rebasedCalls[0].replacement) as! [String: Any]
        check((merged["mcpOAuth"] as? [String: Any])?["fixture"] as? String == "keep-current",
              "rebase keeps current unrelated MCP metadata")
        check((merged["claudeAiOauth"] as? [String: Any])?["subscriptionType"] as? String == "fixture-new-tier",
              "rebase keeps current noncredential OAuth metadata")
        check(quotaClaudeCredentialIdentity(rebasedCalls[0].replacement) == quotaClaudeCredentialIdentity(rotated),
              "rebased update contains the pending rotated pair")
        let semanticCandidate = Data("{\"mcpOAuth\":{},\"claudeAiOauth\":{\"accessToken\":\"fixture-rotated\",\"subscriptionType\":\"changed\"}}".utf8)
        var semanticWrites = 0
        let semantic = quotaReconcilePendingCredential(candidate, read: { .credentials(semanticCandidate) }, quietUpdate: { _ in semanticWrites += 1; return true })
        check(semantic.retirePending && semantic.read == .credentials(semanticCandidate) && semanticWrites == 0,
              "already committed semantic candidate is recognized without rewriting metadata")
        let withRefresh = Data("{\"claudeAiOauth\":{\"accessToken\":\"fixture-same\",\"refreshToken\":\"fixture-refresh-a\"}}".utf8)
        let newRefresh = Data("{\"claudeAiOauth\":{\"refreshToken\":\"fixture-refresh-b\",\"accessToken\":\"fixture-same\"}}".utf8)
        check(quotaClaudeCredentialIdentity(withRefresh) != quotaClaudeCredentialIdentity(newRefresh),
              "identity compares refresh token as well as access token")
        // Every read failure is passed through and prevents writes, independently of timing.
        for failure in [QuotaCredentialRead.missing, .failed(.readInteractionRequired), .failed(.readUnavailable),
                        .failed(.readTimedOut), .failed(.invalidCredentials), .failed(.cancelled)] {
            var calls: [String] = []
            let outcome = quotaReconcilePendingCredential(candidate, read: { calls.append("read"); return failure },
                quietUpdate: { _ in calls.append("write"); return true })
            check(outcome.read == failure && !outcome.retirePending && calls == ["read"], "read failure preserves pending and its original classification")
        }
        for invalid in [Data("invalid-json".utf8), Data("{}".utf8)] {
            var writes = 0
            let outcome = quotaReconcilePendingCredential(candidate, read: { .credentials(invalid) }, quietUpdate: { _ in writes += 1; return true })
            check(outcome.read == .failed(.invalidCredentials) && !outcome.retirePending && writes == 0, "malformed or signed-out replacement cannot discard retained pair or enter renewal")
        }
        var calls = 0
        let cancelled = quotaReconcilePendingCredential(candidate, read: { calls += 1; return .credentials(old) },
            quietUpdate: { _ in calls += 1; return true }, cancelled: { true })
        check(cancelled.read == .failed(.cancelled) && !cancelled.retirePending && calls == 0, "cancel before read performs no backend operation")
        var cancellation = false
        let cancelledAfterRead = quotaReconcilePendingCredential(candidate,
            read: { cancellation = true; return .credentials(old) }, quietUpdate: { _ in calls += 1; return true }, cancelled: { cancellation })
        check(cancelledAfterRead.read == .failed(.cancelled) && !cancelledAfterRead.retirePending && calls == 0, "cancel after read cannot start a pending write")
        print("Pending recovery author regression: \(checks) checks")
    }
}
