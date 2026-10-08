import Foundation

// Compiled only with Sources/QuotaRefresh.swift. This entry point never loads the app.
// No wall clock, transport, credentials, stores, processes, threads, or callbacks to production.
private struct FakeClock {
    var now: Double = 10_000
    mutating func advance(_ seconds: Double) { now += seconds }
}

private enum SyntheticLaunchFailure: Error { case rejected }

// Synthetic dependency store; it records effects without native credentials or OAuth.
private final class PendingCredentialMemory {
    var pending: ClaudeQuotaUpdate?
    var current: QuotaCredentialRead
    var updateSucceeds = false
    private(set) var reads = 0
    private(set) var updates: [ClaudeQuotaUpdate] = []
    private(set) var events: [String] = []

    init(pending: ClaudeQuotaUpdate?, current: QuotaCredentialRead) {
        self.pending = pending; self.current = current
    }
    func resolve(readOverride: (() -> QuotaCredentialRead)? = nil,
                 cancelled: () -> Bool = { false }) -> QuotaPendingResolution {
        let result = quotaReconcilePendingCredential(pending, read: {
            self.reads += 1; self.events.append("read")
            return readOverride?() ?? self.current
        }, quietUpdate: { candidate in
            self.updates.append(candidate); self.events.append("quiet-update")
            if self.updateSucceeds { self.current = .credentials(candidate.replacement) }
            return self.updateSucceeds
        }, cancelled: cancelled)
        // Model only the caller's explicit retirement decision, not reconciliation rules.
        if result.retirePending { pending = nil }
        return result
    }
}

private final class Checks {
    private(set) var assertions = 0
    private(set) var failures = 0
    private(set) var scenarios = 0
    private var scenario = ""

    func run(_ name: String, _ body: (Checks) -> Void) {
        scenarios += 1
        scenario = name
        body(self)
    }
    func expect(_ condition: Bool, _ label: String) {
        assertions += 1
        if !condition {
            failures += 1
            print("FAIL \(scenario): \(label)")
        }
    }
    func equal<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
        expect(actual == expected, label)
    }
    func begin(_ state: inout QuotaRefreshState, _ intent: QuotaRefreshIntent,
               now: Double, schedule: Double) -> QuotaRefreshTicket? {
        let admission = state.admit(intent, now: now, scheduledAt: schedule)
        guard case .start(let serial) = admission, let ticket = state.flight else {
            expect(false, "request must start and reserve a ticket")
            return nil
        }
        equal(ticket.serial, serial, "admission identifies the reserved request")
        return ticket
    }
}

// A recording dependency: it invokes the real admission/completion API directly.
// It does not calculate eligibility, emulate responses, or publish quota values.
private final class ControlledProvider {
    var state = QuotaRefreshState()
    var scheduledAt: Double
    private(set) var requests: [QuotaRefreshTicket] = []
    private(set) var acceptedCompletions: [QuotaRefreshTicket] = []

    init(scheduledAt: Double) { self.scheduledAt = scheduledAt }
    @discardableResult
    func request(_ intent: QuotaRefreshIntent, clock: FakeClock) -> QuotaRefreshAdmission {
        let admission = state.admit(intent, now: clock.now, scheduledAt: scheduledAt)
        if case .start = admission, let ticket = state.flight { requests.append(ticket) }
        return admission
    }
    @discardableResult
    func deliver(_ ticket: QuotaRefreshTicket, retryAt: Double? = nil) -> Bool {
        let accepted = state.complete(ticket, retryAfter: retryAt)
        if accepted { acceptedCompletions.append(ticket) }
        return accepted
    }
}

@main
private enum ManualRefreshIndependent {
    static func main() {
        let checks = Checks()

        // Contract: manual bypasses auto intervals/local error backoff, after 30 s.
        // Intervals are inputs, not a reimplementation of the Auto algorithm.
        for interval in [900.0, 1_800.0, 3_600.0, 14_400.0] {
            for initialIntent in [QuotaRefreshIntent.manual, .scheduled] {
                checks.run("M01/M02 interval \(Int(interval)), prior \(initialIntent)") { c in
                    var clock = FakeClock()
                    var state = QuotaRefreshState()
                    guard let first = c.begin(&state, initialIntent, now: clock.now,
                                              schedule: clock.now) else { return }
                    c.expect(state.complete(first, retryAfter: nil), "complete without a server restriction")
                    // A caller may supply a later schedule because of either interval or local failure.
                    let automaticDeadline = clock.now + interval
                    clock.advance(30)
                    c.equal(state.admit(.scheduled, now: clock.now, scheduledAt: automaticDeadline),
                            .notDue, "automatic attempt still follows its supplied schedule")
                    guard let manual = c.begin(&state, .manual, now: clock.now,
                                               schedule: automaticDeadline) else { return }
                    c.equal(state.admit(.scheduled, now: clock.now, scheduledAt: clock.now),
                            .inFlight, "immediate timer cannot duplicate a manual request")
                    c.expect(state.complete(manual, retryAfter: nil), "manual result accepted")
                    c.equal(state.admit(.scheduled, now: clock.now, scheduledAt: clock.now),
                            .localWait(until: clock.now + 30), "completion does not remove the short guard")
                    c.equal(state.serverUntil, nil, "local scheduling delay is not server wait")
                }
            }
        }

        checks.run("M06 double click and exact 30-second boundary") { c in
            var clock = FakeClock()
            var state = QuotaRefreshState()
            guard let first = c.begin(&state, .manual, now: clock.now, schedule: 50_000) else { return }
            c.equal(state.admit(.manual, now: clock.now, scheduledAt: 50_000), .inFlight,
                    "double click is deduplicated")
            clock.advance(300)
            c.equal(state.admit(.manual, now: clock.now, scheduledAt: 50_000), .inFlight,
                    "long-running request stays reserved beyond cooldown")
            c.expect(state.complete(first, retryAfter: nil), "first request completes")
            guard let next = c.begin(&state, .manual, now: clock.now, schedule: 50_000) else { return }
            c.expect(state.complete(next, retryAfter: nil), "second request completes")
            for offset in [0.0, 0.001, 29.0, 29.999] {
                for intent in [QuotaRefreshIntent.manual, .scheduled] {
                    c.equal(state.admit(intent, now: clock.now + offset, scheduledAt: clock.now),
                            .localWait(until: clock.now + 30), "30-second local guard before boundary")
                }
            }
            clock.advance(30)
            _ = c.begin(&state, .manual, now: clock.now, schedule: 50_000)
        }

        for intent in [QuotaRefreshIntent.manual, .scheduled] {
            for boundaryOffset in [0.0, 0.001] {
                checks.run("M03 server deadline \(intent), offset \(boundaryOffset)") { c in
                    var clock = FakeClock()
                    var state = QuotaRefreshState()
                    guard let ticket = c.begin(&state, .manual, now: clock.now, schedule: clock.now) else { return }
                    let serverDeadline = clock.now + 120
                    c.expect(state.complete(ticket, retryAfter: serverDeadline), "server deadline accepted")
                    // Both the short cooldown and server restriction exist, but the latter is explicit.
                    for offset in [0.0, 29.999, 30.0, 119.999] {
                        c.equal(state.admit(intent, now: clock.now + offset, scheduledAt: clock.now),
                                .serverWait(until: serverDeadline), "server ban cannot be bypassed")
                    }
                    c.equal(state.nextAttempt(schedule: clock.now), serverDeadline,
                            "next attempt accounts for the server deadline")
                    clock.advance(120 + boundaryOffset)
                    guard let second = c.begin(&state, intent, now: clock.now, schedule: 10_000) else { return }
                    c.expect(state.complete(second, retryAfter: nil), "response after expiry accepted")
                    c.equal(state.serverUntil, nil, "new unrestricted response clears previous restriction")
                }
            }
        }

        checks.run("M03 short server restriction retains local guard") { c in
            var state = QuotaRefreshState()
            guard let ticket = c.begin(&state, .manual, now: 10_000, schedule: 10_000) else { return }
            c.expect(state.complete(ticket, retryAfter: 10_005), "short server restriction accepted")
            c.equal(state.admit(.manual, now: 10_004, scheduledAt: 10_000),
                    .serverWait(until: 10_005), "server reason before expiry")
            c.equal(state.admit(.manual, now: 10_005, scheduledAt: 10_000),
                    .localWait(until: 10_030), "expired server ban does not remove local guard")
            c.equal(state.nextAttempt(schedule: 10_000), 10_030, "combined next attempt is safe")
            _ = c.begin(&state, .manual, now: 10_030, schedule: 10_000)
        }

        for busyName in ["Codex", "Claude"] {
            checks.run("M04 \(busyName) busy, other free") { c in
                var clock = FakeClock()
                let busy = ControlledProvider(scheduledAt: 50_000)
                let free = ControlledProvider(scheduledAt: 50_000)
                busy.request(.manual, clock: clock)
                c.equal(busy.requests.count, 1, "busy service starts once")
                c.equal(busy.request(.manual, clock: clock), .inFlight, "busy service rejects duplicate")
                free.request(.manual, clock: clock)
                c.equal(free.requests.count, 1, "other provider is independently admitted")
                c.equal(busy.requests.count, 1, "other request leaves busy count unchanged")
                guard let freeTicket = free.requests.first else { return }
                c.expect(free.deliver(freeTicket), "free service completion accepted")
                clock.advance(30)
                free.request(.manual, clock: clock)
                c.equal(free.requests.count, 2, "free provider can retry while other remains pending")
                c.equal(busy.request(.manual, clock: clock), .inFlight, "pending provider still reserved")
            }
            checks.run("M04 \(busyName) server blocked, other free/disabled") { c in
                let clock = FakeClock()
                let blocked = ControlledProvider(scheduledAt: 50_000)
                let free = ControlledProvider(scheduledAt: 50_000)
                blocked.state.serverUntil = clock.now + 120
                c.equal(blocked.request(.manual, clock: clock), .serverWait(until: clock.now + 120),
                        "blocked provider makes no request")
                free.request(.manual, clock: clock)
                c.equal(blocked.requests.count, 0, "server wait records zero requests")
                c.equal(free.requests.count, 1, "other provider is unaffected")
                let disabled = ControlledProvider(scheduledAt: clock.now)
                disabled.state.setEnabled(false)
                c.equal(disabled.request(.manual, clock: clock), .disabled, "disabled manual")
                c.equal(disabled.request(.scheduled, clock: clock), .disabled, "disabled automatic")
                c.equal(disabled.requests.count, 0, "disabled provider makes no requests")
            }
        }

        for firstName in ["Codex", "Claude"] {
            checks.run("M05 partial completion seam, first \(firstName)") { c in
                var clock = FakeClock()
                let first = ControlledProvider(scheduledAt: 50_000)
                let second = ControlledProvider(scheduledAt: 50_000)
                first.request(.manual, clock: clock)
                second.request(.manual, clock: clock)
                guard let firstTicket = first.requests.first, let secondTicket = second.requests.first else {
                    c.expect(false, "both requests started"); return
                }
                c.expect(first.deliver(firstTicket), "completion accepted immediately while other is pending")
                c.equal(first.acceptedCompletions, [firstTicket], "first completion observed now")
                c.equal(second.state.flight, secondTicket, "other provider stays pending")
                c.equal(second.acceptedCompletions.count, 0, "other provider has not completed")
                c.expect(second.deliver(secondTicket), "second completion without known server deadline")
                clock.advance(30)
                second.request(.manual, clock: clock)
                c.equal(second.requests.count, 2, "targeted provider retry starts")
                c.equal(first.requests.count, 1, "targeted retry does not request successful provider")
                // This seam accepts a completion; it cannot prove UI/data publication or success vs fallback.
            }
        }

        checks.run("M10 duplicate/foreign completion cannot retire a current worker") { c in
            var state = QuotaRefreshState()
            guard let a = c.begin(&state, .manual, now: 10_000, schedule: 10_000) else { return }
            let foreign = QuotaRefreshTicket(serial: a.serial + 99, generation: a.generation)
            c.expect(!state.complete(foreign, retryAfter: 99_999), "foreign completion rejected")
            c.equal(state.flight, a, "foreign completion retains flight")
            c.equal(state.serverUntil, nil, "foreign completion cannot inject server deadline")
            c.expect(state.complete(a, retryAfter: nil), "A accepted once")
            guard let b = c.begin(&state, .manual, now: 10_030, schedule: 10_000) else { return }
            c.expect(a != b, "distinct requests have distinct identities")
            c.expect(!state.complete(a, retryAfter: 99_999), "late A rejected while B pending")
            c.equal(state.flight, b, "late A cannot release B")
            c.equal(state.serverUntil, nil, "late A cannot alter deadlines")
            c.expect(state.complete(b, retryAfter: 10_150), "B accepted")
            c.expect(!state.complete(a, retryAfter: nil), "late A rejected after B completion")
            c.expect(!state.complete(b, retryAfter: nil), "duplicate B rejected")
            c.equal(state.serverUntil, 10_150, "duplicates do not clear B restriction")
        }

        checks.run("M10 disable/re-enable invalidates response without overlapping workers") { c in
            var state = QuotaRefreshState()
            guard let old = c.begin(&state, .manual, now: 10_000, schedule: 10_000) else { return }
            state.setEnabled(false)
            c.equal(state.admit(.manual, now: 10_100, scheduledAt: 10_000), .disabled,
                    "deselected provider cannot start")
            state.setEnabled(true)
            c.equal(state.admit(.manual, now: 10_100, scheduledAt: 10_000), .inFlight,
                    "re-enable cannot overlap still-running old worker")
            c.expect(!state.complete(old, retryAfter: 10_120), "obsolete selection cannot publish")
            c.equal(state.flight, nil, "finished obsolete worker releases only its reservation")
            c.equal(state.serverUntil, 10_120, "same-provider server restriction survives re-selection")
            c.equal(state.admit(.manual, now: 10_100, scheduledAt: 10_000), .serverWait(until: 10_120),
                    "P2 regression: re-selection cannot bypass server deadline")
            guard let current = c.begin(&state, .manual, now: 10_120, schedule: 10_000) else { return }
            c.expect(current.generation != old.generation, "selection generation distinguishes new worker")
            c.expect(!state.complete(old, retryAfter: 99_999), "late obsolete duplicate rejected")
            c.equal(state.flight, current, "late obsolete duplicate cannot release new worker")
            c.expect(state.complete(current, retryAfter: nil), "current selection completion accepted")
            c.equal(state.serverUntil, nil, "obsolete duplicate cannot inject a new deadline into current generation")
        }

        checks.run("M10 completion while disabled and idempotent selection") { c in
            var state = QuotaRefreshState()
            guard let ticket = c.begin(&state, .manual, now: 10_000, schedule: 10_000) else { return }
            state.setEnabled(true)
            c.expect(state.complete(ticket, retryAfter: nil), "same enabled selection does not invalidate response")
            guard let disabledTicket = c.begin(&state, .manual, now: 10_030, schedule: 10_000) else { return }
            state.setEnabled(false)
            state.setEnabled(false)
            c.expect(!state.complete(disabledTicket, retryAfter: 99_999), "disabled completion not publishable")
            c.equal(state.flight, nil, "disabled worker retired")
            c.equal(state.serverUntil, 99_999, "server deadline retained even if completion arrives while disabled")
            c.equal(state.admit(.scheduled, now: 10_100, scheduledAt: 10_000), .disabled,
                    "completion does not re-enable provider")
            state.setEnabled(true)
            c.equal(state.admit(.manual, now: 10_100, scheduledAt: 10_000), .serverWait(until: 99_999),
                    "server ban persists when enabling after disabled completion")
        }

        checks.run("M06 restored previous attempt retains 30-second guard") { c in
            var restored = QuotaRefreshState(lastAttempt: 10_000)
            c.equal(restored.admit(.manual, now: 10_029.999, scheduledAt: 50_000),
                    .localWait(until: 10_030), "restored manual cooldown before boundary")
            _ = c.begin(&restored, .manual, now: 10_030, schedule: 50_000)
            var serverBlocked = QuotaRefreshState(lastAttempt: 10_000, serverUntil: 10_120)
            c.equal(serverBlocked.admit(.manual, now: 10_030, scheduledAt: 50_000),
                    .serverWait(until: 10_120), "restored server deadline is not bypassed")
            for invalidDeadline in [Double.nan, .infinity, -.infinity, -1] {
                var invalid = QuotaRefreshState(lastAttempt: 0, serverUntil: invalidDeadline)
                c.equal(invalid.serverUntil, nil, "invalid persisted server deadline discarded")
                _ = c.begin(&invalid, .manual, now: 10_000, schedule: 50_000)
            }
        }

        checks.run("M09 delta-seconds, unknown values, no one-hour cap") { c in
            let now: Double = 10_000
            let valid: [(String, Double)] = [
                ("0", 10_000), ("1", 10_001), ("30", 10_030),
                ("3601", 13_601), ("86400", 96_400), ("999999", 1_009_999),
                (" 120\r\n", 10_120), ("000120", 10_120)
            ]
            for (raw, expected) in valid {
                c.equal(quotaRetryAfter(raw, now: now), expected, "valid delta deadline, including long wait")
            }
            let invalid: [String?] = [nil, "", " \t\n", "soon", "-1", "+1", "1.5", "NaN", "Infinity",
                                     "1e3", "120 seconds", "12 0", "１２０", String(repeating: "9", count: 400)]
            for raw in invalid {
                c.equal(quotaRetryAfter(raw, now: now), nil, "invalid/unknown Retry-After has no fabricated deadline")
            }
            for invalidNow in [Double.nan, .infinity, -.infinity] {
                c.equal(quotaRetryAfter("120", now: invalidNow), nil, "nonfinite reference time rejected")
            }
            c.equal(quotaRetryAfter(String(repeating: "9", count: 308), now: Double.greatestFiniteMagnitude),
                    nil, "finite operands with overflowing sum produce no infinite deadline")
        }

        checks.run("M09 HTTP-date formats, past deadline and invalid date") { c in
            // RFC example date; fixed UTC epoch oracle, not Date() or parser-derived expectation.
            let epoch: Double = 784_111_777
            for raw in ["Sun, 06 Nov 1994 08:49:37 GMT", "Sunday, 06-Nov-94 08:49:37 GMT",
                        "Sun Nov  6 08:49:37 1994"] {
                c.equal(quotaRetryAfter(raw, now: epoch - 60), epoch, "future HTTP-date preserved")
                c.equal(quotaRetryAfter(raw, now: epoch), epoch, "exact HTTP-date boundary")
                c.equal(quotaRetryAfter(raw, now: epoch + 60), epoch + 60, "past HTTP-date permits current time")
            }
            for raw in ["Sun, 32 Nov 1994 08:49:37 GMT", "not a date", "Sun, 06 Nov 1994 08:49:37 GMT garbage"] {
                c.equal(quotaRetryAfter(raw, now: epoch - 60), nil, "malformed date must not create server wait")
            }
        }

        checks.run("M09 parser deadline enforced by scheduler") { c in
            var state = QuotaRefreshState()
            guard let ticket = c.begin(&state, .manual, now: 10_000, schedule: 10_000) else { return }
            let failure = QuotaHTTPFailure(status: 429, headers: ["rEtRy-AfTeR": "86400"], now: 10_000)
            c.equal(failure.retryAt, 96_400, "case-insensitive HTTP header preserves full day")
            c.expect(!failure.authenticationRequired, "rate limiting is not auth failure")
            c.expect(state.complete(ticket, retryAfter: failure.retryAt), "HTTP metadata passed to scheduler")
            c.equal(state.admit(.manual, now: 13_601, scheduledAt: 10_000), .serverWait(until: 96_400),
                    "manual cannot bypass a long server ban after one hour")
            c.equal(state.admit(.scheduled, now: 96_399.999, scheduledAt: 10_000), .serverWait(until: 96_400),
                    "automatic cannot bypass long ban before boundary")
            _ = c.begin(&state, .manual, now: 96_400, schedule: 10_000)
        }

        checks.run("M11 HTTP auth classification, no invented expiry") { c in
            let cases: [(Int, Bool, String?, Bool)] = [
                (401, false, nil, true), (401, true, nil, true),
                (400, true, "invalid_grant", true), (400, false, "invalid_grant", false),
                (400, true, "invalid_request", false), (400, true, nil, false),
                (403, false, nil, false), (429, false, nil, false),
                (500, false, nil, false), (503, false, nil, false), (0, false, nil, false)
            ]
            for (status, tokenEndpoint, oauthError, expected) in cases {
                let failure = QuotaHTTPFailure(status: status, headers: [:], now: 10_000,
                                               tokenEndpoint: tokenEndpoint, oauthError: oauthError)
                c.equal(failure.status, status, "HTTP status preserved")
                c.equal(failure.authenticationRequired, expected, "auth requires HTTP/OAuth evidence")
                c.equal(failure.retryAt, nil, "no header means no invented server countdown")
            }
            let authWithWait = QuotaHTTPFailure(status: 401, headers: ["Retry-After": "120"], now: 10_000)
            c.expect(authWithWait.authenticationRequired, "auth classification survives retry metadata")
            c.equal(authWithWait.retryAt, 10_120, "auth and server wait can coexist")
            let unknownWait = QuotaHTTPFailure(status: 429, headers: ["Retry-After": "soon"], now: 10_000)
            c.equal(unknownWait.retryAt, nil, "unknown server duration remains unknown")
            c.expect(!unknownWait.authenticationRequired, "unknown wait is not auth expiry")
        }

        checks.run("M07 unchanged quota values with a fresh response are successful") { c in
            var previous = LimitData()
            previous.session = 25; previous.weekly = 50
            previous.sessionReset = Date(timeIntervalSince1970: 20_000)
            previous.weeklyReset = Date(timeIntervalSince1970: 30_000)
            previous.asOf = Date(timeIntervalSince1970: 9_000)
            previous.pollFailed = true; previous.error = "synthetic previous failure"
            var fresh = LimitData()
            fresh.session = 25; fresh.weekly = 50
            fresh.sessionReset = Date(timeIntervalSince1970: 20_000)
            fresh.weeklyReset = Date(timeIntervalSince1970: 30_000)
            fresh.asOf = Date(timeIntervalSince1970: 10_000)
            fresh.apiFresh = true; fresh.fromCache = false; fresh.pollFailed = false
            let accepted = quotaFallback(fresh, previous: previous)
            c.equal(accepted.session, 25, "same session percentage preserved")
            c.equal(accepted.weekly, 50, "same weekly percentage preserved")
            c.equal(accepted.sessionReset, Date(timeIntervalSince1970: 20_000), "unchanged session reset preserved")
            c.equal(accepted.weeklyReset, Date(timeIntervalSince1970: 30_000), "unchanged weekly reset preserved")
            c.equal(accepted.asOf, Date(timeIntervalSince1970: 10_000), "unchanged fresh response advances reading time")
            c.expect(accepted.apiFresh && !accepted.fromCache && !accepted.pollFailed,
                     "fresh unchanged response is not downgraded to fallback/error")
            c.equal(accepted.error, nil, "old failure does not survive a successful response")
        }

        for knownDate in [true, false] {
            checks.run("M08 fallback keeps snapshot and its known/nil asOf, known=\(knownDate)") { c in
                var previous = LimitData()
                previous.session = 25; previous.weekly = 50
                previous.sessionReset = Date(timeIntervalSince1970: 20_000)
                previous.weeklyReset = Date(timeIntervalSince1970: 30_000)
                previous.scoped = ScopedLimit(name: "synthetic model", percent: 75,
                    reset: Date(timeIntervalSince1970: 40_000), severity: "warning")
                previous.plan = "synthetic plan"; previous.resetCredits = 2
                previous.asOf = knownDate ? Date(timeIntervalSince1970: 9_000) : nil
                var failed = LimitData()
                failed.session = 99; failed.weekly = 98
                failed.sessionReset = Date(timeIntervalSince1970: 90_000)
                failed.weeklyReset = Date(timeIntervalSince1970: 99_000)
                failed.plan = "untrusted fallback"; failed.resetCredits = 99
                failed.asOf = Date(timeIntervalSince1970: 10_000)
                failed.error = "synthetic network/auth failure"; failed.auth = .expired
                failed.serverRetryAt = 10_120; failed.apiFresh = false
                let fallback = quotaFallback(failed, previous: previous)
                c.equal(fallback.session, 25, "fallback keeps last successful session value")
                c.equal(fallback.weekly, 50, "fallback keeps last successful weekly value")
                c.equal(fallback.sessionReset, Date(timeIntervalSince1970: 20_000), "session reset stays with old snapshot")
                c.equal(fallback.weeklyReset, Date(timeIntervalSince1970: 30_000), "weekly reset stays with old snapshot")
                c.equal(fallback.scoped?.name, "synthetic model", "scoped name stays with old snapshot")
                c.equal(fallback.scoped?.percent, 75, "scoped quota stays with old snapshot")
                c.equal(fallback.scoped?.reset, Date(timeIntervalSince1970: 40_000), "scoped reset stays with old snapshot")
                c.equal(fallback.plan, "synthetic plan", "plan stays with old snapshot")
                c.equal(fallback.resetCredits, 2, "credits stay with old snapshot")
                c.equal(fallback.asOf, knownDate ? Date(timeIntervalSince1970: 9_000) : nil,
                        "fallback never substitutes new attempt time for old/nil asOf")
                c.expect(!fallback.apiFresh && fallback.fromCache && fallback.pollFailed,
                         "fallback is marked as failed cached data")
                c.equal(fallback.error, "synthetic network/auth failure", "current error is visible")
                c.expect(fallback.auth == .expired, "current auth evidence stays separate from old snapshot")
                c.equal(fallback.serverRetryAt, 10_120, "current attempt's server restriction not lost")
                c.equal(previous.asOf, knownDate ? Date(timeIntervalSince1970: 9_000) : nil,
                        "input snapshot remains unchanged")
                let feedback = quotaRefreshFeedback(inFlight: false, serverUntil: fallback.serverRetryAt,
                    localUntil: 10_030, failed: fallback.pollFailed, authenticationRequired: true,
                    dataAt: fallback.asOf?.timeIntervalSince1970, nextAutomaticAt: 10_120,
                    now: 10_030, english: false)
                c.equal(feedback.dataAt, knownDate ? 9_000 : nil, "fallback-to-feedback preserves timestamp")
                c.equal(feedback.nextAutomaticAt, 10_120, "server next attempt remains separately visible")
            }
        }

        for status in [401, 400] {
            checks.run("M03/M11 auth retains independent HTTP deadline, status=\(status)") { c in
                var state = QuotaRefreshState()
                guard let ticket = c.begin(&state, .manual, now: 10_000, schedule: 10_000) else { return }
                let failure = QuotaHTTPFailure(status: status, headers: ["Retry-After": "120"], now: 10_000,
                    tokenEndpoint: status == 400, oauthError: status == 400 ? "invalid_grant" : nil)
                c.expect(failure.authenticationRequired, "both auth evidence classes are recognized")
                c.equal(failure.retryAt, 10_120, "auth evidence does not discard Retry-After")
                c.expect(state.complete(ticket, retryAfter: failure.retryAt), "HTTP metadata accepted alongside auth")
                c.equal(state.admit(.manual, now: 10_030, scheduledAt: 10_000), .serverWait(until: 10_120),
                        "manual cannot bypass auth response's independent server restriction")
                // This tests the metadata/state seam, not the production Claude response adapter.
            }
        }

        for english in [false, true] {
            checks.run("M07 fresh success projection clears failure, english=\(english)") { c in
                let oldFailure = quotaRefreshFeedback(inFlight: false, serverUntil: nil, localUntil: 0,
                    failed: true, authenticationRequired: false, dataAt: 9_000,
                    nextAutomaticAt: 14_000, now: 10_000, english: english)
                let freshSuccess = quotaRefreshFeedback(inFlight: false, serverUntil: nil, localUntil: 0,
                    failed: false, authenticationRequired: false, dataAt: 10_000,
                    nextAutomaticAt: 14_000, now: 10_000, english: english)
                c.equal(freshSuccess.dataAt, 10_000, "fresh successful receipt time appears in feedback")
                c.equal(freshSuccess.nextAutomaticAt, 14_000, "fresh data time differs from next schedule")
                c.equal(freshSuccess.action, .none, "successful response does not offer error recovery")
                c.expect(!freshSuccess.status.isEmpty && freshSuccess.status != oldFailure.status,
                         "success is distinguishable from previous failure")
                // Percentages/receipt application are absent from this API; unchanged values require a further seam.
            }
            checks.run("M08/M12 projection preserves old/nil dataAt, english=\(english)") { c in
                for dataAt in [Optional<Double>(9_000), nil] {
                    let pending = quotaRefreshFeedback(inFlight: true, serverUntil: nil, localUntil: 10_030,
                        failed: false, authenticationRequired: false, dataAt: dataAt,
                        nextAutomaticAt: 14_000, now: 10_000, english: english)
                    c.equal(pending.dataAt, dataAt, "pending does not invent a new reading time")
                    c.equal(pending.nextAutomaticAt, 14_000, "next auto time remains distinct from data time")
                    c.equal(pending.action, .none, "pending has no second request action")
                    c.equal(pending.status, english ? "Refreshing…" : "Обновляем…", "immediate pending feedback")
                    let fallback = quotaRefreshFeedback(inFlight: false, serverUntil: nil, localUntil: 10_030,
                        failed: true, authenticationRequired: false, dataAt: dataAt,
                        nextAutomaticAt: 14_000, now: 10_030, english: english)
                    c.equal(fallback.dataAt, dataAt, "failed projection preserves known/nil asOf")
                    c.equal(fallback.nextAutomaticAt, 14_000, "failure does not substitute an attempt time")
                    c.equal(fallback.action, .retry, "failed provider offers retry after short guard")
                    c.expect(!fallback.actionTitle.isEmpty, "retry has a localized title")
                    c.expect(!fallback.status.isEmpty, "failure has a localized status")
                }
            }

            checks.run("M09 projection local pause vs real/unknown server wait, english=\(english)") { c in
                let local = quotaRefreshFeedback(inFlight: false, serverUntil: nil, localUntil: 10_030,
                    failed: true, authenticationRequired: false, dataAt: 9_000,
                    nextAutomaticAt: 14_000, now: 10_000, english: english)
                c.equal(local.action, .none, "local guard prevents immediate retry")
                c.expect(!local.status.contains(english ? "Service" : "Сервис"),
                         "local guard is not attributed to service")
                c.expect(!local.actionTitle.isEmpty, "local guard exposes wait feedback")
                let server = quotaRefreshFeedback(inFlight: false, serverUntil: 10_120, localUntil: 10_030,
                    failed: true, authenticationRequired: false, dataAt: 9_000,
                    nextAutomaticAt: 10_120, now: 10_030, english: english)
                c.equal(server.action, .none, "known server ban has no early retry action")
                c.expect(server.status.hasPrefix(english ? "Service allows retry in " : "Сервис разрешит повтор через "),
                         "server restriction clearly attributed to provider")
                c.equal(server.dataAt, 9_000, "server wait preserves old reading time")
                c.equal(server.nextAutomaticAt, 10_120, "server retry time is separate from reading time")
                let unknown = QuotaHTTPFailure(status: 429, headers: ["Retry-After": "unknown"], now: 10_000)
                let noDeadline = quotaRefreshFeedback(inFlight: false, serverUntil: unknown.retryAt, localUntil: 10_030,
                    failed: true, authenticationRequired: unknown.authenticationRequired, dataAt: 9_000,
                    nextAutomaticAt: nil, now: 10_030, english: english)
                c.expect(!noDeadline.status.contains(english ? "Service allows retry in" : "Сервис разрешит повтор через"),
                         "unknown server deadline does not fabricate a countdown")
                c.equal(noDeadline.nextAutomaticAt, nil, "unknown next attempt is not invented by projection")
                let expired = quotaRefreshFeedback(inFlight: false, serverUntil: 10_120, localUntil: 10_030,
                    failed: true, authenticationRequired: false, dataAt: 9_000,
                    nextAutomaticAt: 10_120, now: 10_120, english: english)
                c.equal(expired.action, .retry, "server retry action available at exact deadline")
            }

            checks.run("M11 restore action vs network/stale/missing, english=\(english)") { c in
                let auth = quotaRefreshFeedback(inFlight: false, serverUntil: nil, localUntil: 10_030,
                    failed: true, authenticationRequired: true, dataAt: 9_000,
                    nextAutomaticAt: 14_000, now: 10_000, english: english)
                c.equal(auth.action, .restoreAccess, "confirmed auth problem offers explicit recovery action")
                c.equal(auth.actionTitle, english ? "Restore access" : "Восстановить доступ", "localized recovery title")
                c.equal(auth.dataAt, 9_000, "auth problem does not erase reading date")
                let authAndWait = quotaRefreshFeedback(inFlight: false, serverUntil: 10_120, localUntil: 10_030,
                    failed: true, authenticationRequired: true, dataAt: 9_000,
                    nextAutomaticAt: 10_120, now: 10_030, english: english)
                c.equal(authAndWait.action, .restoreAccess, "server ban does not hide explicit auth recovery action")
                c.equal(authAndWait.actionTitle, english ? "Restore access" : "Восстановить доступ",
                        "auth recovery remains named alongside wait")
                c.expect(authAndWait.status.hasPrefix(english ? "Service allows retry in " : "Сервис разрешит повтор через "),
                         "auth recovery does not erase server restriction feedback")
                c.equal(authAndWait.nextAutomaticAt, 10_120, "auth recovery does not change server retry time")
                let pendingAuth = quotaRefreshFeedback(inFlight: true, serverUntil: nil, localUntil: 10_030,
                    failed: true, authenticationRequired: true, dataAt: 9_000,
                    nextAutomaticAt: 14_000, now: 10_000, english: english)
                c.equal(pendingAuth.action, .none, "ordinary refresh pending does not invoke recovery")
                let network = quotaRefreshFeedback(inFlight: false, serverUntil: nil, localUntil: 10_030,
                    failed: true, authenticationRequired: false, dataAt: 9_000,
                    nextAutomaticAt: 14_000, now: 10_030, english: english)
                c.equal(network.action, .retry, "network failure offers refresh rather than invented auth recovery")
                for dataAt in [Optional<Double>(1), nil] {
                    let staleOrMissing = quotaRefreshFeedback(inFlight: false, serverUntil: nil, localUntil: 0,
                        failed: false, authenticationRequired: false, dataAt: dataAt,
                        nextAutomaticAt: nil, now: 10_000, english: english)
                    c.equal(staleOrMissing.action, .none, "stale/missing alone is not auth evidence")
                    c.equal(staleOrMissing.dataAt, dataAt, "stale/missing date is not replaced by now")
                    c.expect(!staleOrMissing.status.isEmpty, "stale/missing has visible feedback")
                }
                // RestoreAccess is a projection value. Native UI policy/click routing require independent review/QA.
            }

            checks.run("M09 countdown upper bounds, english=\(english)") { c in
                let longWait = quotaRefreshFeedback(inFlight: false, serverUntil: 1_009_999, localUntil: 0,
                    failed: true, authenticationRequired: false, dataAt: 9_000,
                    nextAutomaticAt: 1_009_999, now: 10_000, english: english)
                c.equal(longWait.nextAutomaticAt, 1_009_999, "countdown formatting does not cap actual deadline")
                c.expect(!longWait.status.isEmpty, "long wait has bounded visible feedback")
                for until in [Double.greatestFiniteMagnitude, .infinity] {
                    let text = quotaCountdown(until: until, now: 10_000, english: english)
                    c.expect(!text.isEmpty, "huge wait formats without integer conversion overflow")
                    c.expect(!text.lowercased().contains("nan") && !text.lowercased().contains("inf"),
                             "huge wait does not expose nonfinite numeric text")
                }
                c.equal(quotaCountdown(until: 10_000.001, now: 10_000, english: english),
                        english ? "1 s" : "1 с", "nonexpired subsecond wait is rounded up")
                c.equal(quotaCountdown(until: 10_000, now: 10_000, english: english),
                        english ? "0 s" : "0 с", "exact countdown boundary")
            }
        }

        selectionAndPermissionChecks(checks)
        pendingCredentialChecks(checks)
        print("MANUAL_REFRESH_INDEPENDENT scenarios=\(checks.scenarios) assertions=\(checks.assertions) failures=\(checks.failures)")
        if checks.failures != 0 { exit(1) }
    }

    private static func pendingCredentialChecks(_ checks: Checks) {
        // All bytes below are synthetic fixtures, never loaded from a user's environment.
        let expected = Data(#"{"claudeAiOauth":{"accessToken":"fixture-original-not-a-credential"}}"#.utf8)
        let candidate = Data(#"{"claudeAiOauth":{"accessToken":"fixture-rotated-not-a-credential"}}"#.utf8)
        let newLogin = Data(#"{"claudeAiOauth":{"accessToken":"fixture-new-cli-not-a-credential"}}"#.utf8)
        let pending = ClaudeQuotaUpdate(expected: expected, replacement: candidate)

        checks.run("M11C rotation write failure, permission-needed, explicit new CLI login") { c in
            let memory = PendingCredentialMemory(pending: pending, current: .credentials(expected))
            let failedWrite = memory.resolve()
            c.equal(failedWrite.read, .failed(.writeUnavailable), "quiet write failure is explicitly a write failure")
            c.expect(!failedWrite.retirePending, "failed persistence retains rotated RAM candidate")
            c.equal(memory.pending, pending, "RAM candidate and its expected generation remain intact")
            c.equal(memory.events, ["read", "quiet-update"], "read current credentials precedes pending write")

            memory.current = .failed(.readInteractionRequired)
            let needsPermission = memory.resolve()
            c.equal(needsPermission.read, .failed(.readInteractionRequired), "next read permission issue is not masked as write failure")
            c.equal(memory.reads, 2, "one actual read per recovery attempt")
            c.equal(memory.updates.count, 1, "no pending write attempted after a failed read")
            c.equal(memory.pending, pending, "read failure retains only rotated RAM candidate")

            let permit = QuotaKeychainReadPermit(now: 10_000)
            let recovered = memory.resolve(readOverride: {
                var read: QuotaCredentialRead = .failed(.cancelled)
                _ = permit.admit(now: 10_001) { read = .credentials(newLogin) }
                return read
            })
            c.equal(recovered.read, .credentials(newLogin), "explicit read discovers and uses distinct valid CLI login")
            c.expect(recovered.retirePending, "new CLI login retires obsolete pending rotation")
            c.equal(memory.pending, nil, "old pending cleared only on authoritative resolution")
            c.equal(memory.reads, 3, "explicit recovery reads once")
            c.equal(memory.updates, [pending], "new CLI login is never overwritten by old pending candidate")
            c.equal(memory.events, ["read", "quiet-update", "read", "read"], "whole recovery effect sequence")

            memory.current = .credentials(newLogin)
            let repeated = memory.resolve()
            c.equal(repeated.read, .credentials(newLogin), "subsequent ordinary read keeps current login")
            c.equal(memory.reads, 4, "subsequent call still performs exactly one read")
            c.equal(memory.updates.count, 1, "retired rotation never writes again")
        }

        checks.run("M11C already persisted candidate retires without another update") { c in
            let memory = PendingCredentialMemory(pending: pending, current: .credentials(candidate))
            let result = memory.resolve()
            c.equal(result.read, .credentials(candidate), "already persisted candidate used directly")
            c.expect(result.retirePending, "already persisted candidate retires pending RAM copy")
            c.equal(memory.pending, nil, "pending retired after matching candidate")
            c.equal(memory.reads, 1, "current credentials read once")
            c.equal(memory.updates.count, 0, "already persisted candidate requires zero writes")
            _ = memory.resolve()
            c.equal(memory.reads, 2, "repeated recovery remains one read per call")
            c.equal(memory.updates.count, 0, "repeated recovery cannot rewrite candidate")
        }

        checks.run("M11C quiet retry persists same RAM candidate after write failure") { c in
            let memory = PendingCredentialMemory(pending: pending, current: .credentials(expected))
            _ = memory.resolve()
            c.equal(memory.pending, pending, "first failed write preserves rotation")
            memory.updateSucceeds = true
            let retry = memory.resolve()
            c.equal(retry.read, .credentials(candidate), "successful quiet retry returns existing candidate")
            c.expect(retry.retirePending, "successful persistence retires pending")
            c.equal(memory.pending, nil, "RAM pending cleared after persistence")
            c.equal(memory.updates, [pending, pending], "retry uses exact retained pair, not a new rotation")
            c.equal(memory.events, ["read", "quiet-update", "read", "quiet-update"], "every update is preceded by a new read")
        }

        checks.run("M11C missing, corrupt, signed-out and read failures preserve pending") { c in
            let unreadable: [(QuotaCredentialRead, QuotaCredentialRead)] = [
                (.missing, .missing), (.failed(.readInteractionRequired), .failed(.readInteractionRequired)),
                (.failed(.readUnavailable), .failed(.readUnavailable)), (.failed(.readTimedOut), .failed(.readTimedOut)),
                (.failed(.invalidCredentials), .failed(.invalidCredentials)), (.failed(.cancelled), .failed(.cancelled)),
                (.credentials(Data("synthetic corrupt non-JSON".utf8)), .failed(.invalidCredentials)),
                (.credentials(Data(#"{}"#.utf8)), .failed(.invalidCredentials)),
                (.credentials(Data(#"{"claudeAiOauth":{}}"#.utf8)), .failed(.invalidCredentials)),
                (.credentials(Data(#"{"claudeAiOauth":{"accessToken":""}}"#.utf8)), .failed(.invalidCredentials)),
                (.credentials(Data(#"{"claudeAiOauth":{"refreshToken":"fixture-unrelated-refresh-only"}}"#.utf8)), .failed(.invalidCredentials)),
                (.credentials(Data(#"{"claudeAiOauth":{"accessToken":42}}"#.utf8)), .failed(.invalidCredentials))
            ]
            for (read, expectedRead) in unreadable {
                let memory = PendingCredentialMemory(pending: pending, current: read)
                for _ in 0..<2 {
                    let result = memory.resolve()
                    c.equal(result.read, expectedRead, "read outcome keeps its origin without stale write masking")
                    c.expect(!result.retirePending, "unknown/corrupt/missing read cannot discard rotated candidate")
                    c.equal(memory.pending, pending, "entire expected/replacement pair remains in RAM")
                    c.equal(memory.updates.count, 0, "failed or unrecognized read causes zero writes")
                }
                c.equal(memory.reads, 2, "two calls make two bounded reads")
            }
        }

        checks.run("M11C cancel before read and between read and write") { c in
            let beforeRead = PendingCredentialMemory(pending: pending, current: .credentials(expected))
            let first = beforeRead.resolve(cancelled: { true })
            c.equal(first.read, .failed(.cancelled), "pre-cancel is reported")
            c.equal(beforeRead.reads, 0, "pre-cancel does not reach read")
            c.equal(beforeRead.updates.count, 0, "pre-cancel does not reach update")
            c.equal(beforeRead.pending, pending, "pre-cancel retains RAM candidate")

            let afterRead = PendingCredentialMemory(pending: pending, current: .credentials(expected))
            var cancelled = false
            let second = afterRead.resolve(readOverride: {
                cancelled = true
                return .credentials(expected)
            }, cancelled: { cancelled })
            c.equal(second.read, .failed(.cancelled), "cancellation after read overrides pending update")
            c.equal(afterRead.reads, 1, "cancellation point follows exactly one read")
            c.equal(afterRead.updates.count, 0, "cancel between read and update prevents write")
            c.equal(afterRead.pending, pending, "cancel after read retains rotation")
            _ = afterRead.resolve(cancelled: { cancelled })
            c.equal(afterRead.reads, 1, "repeated cancelled attempt performs no additional read")
            c.equal(afterRead.updates.count, 0, "repeated cancellation still performs zero writes")
        }

        checks.run("M11C explicit read permit does not turn pending update interactive") { c in
            let permit = QuotaKeychainReadPermit(now: 10_000)
            var events: [String] = []
            let result = quotaReconcilePendingCredential(pending, read: {
                var read: QuotaCredentialRead = .failed(.cancelled)
                _ = permit.admit(now: 10_001) {
                    let status = quotaHelperInteraction(ClaudeQuotaHelperRequest(operation: "read", interactive: true),
                        setAllowed: { allowed in events.append(allowed ? "read-UI-on" : "read-UI-off"); return true },
                        operation: { events.append("read-RPC"); return 0 })
                    if status == 0 { read = .credentials(expected) }
                }
                return read
            }, quietUpdate: { update in
                c.equal(update, pending, "only the pending expected/candidate pair is submitted")
                let status = quotaHelperInteraction(ClaudeQuotaHelperRequest(operation: "update", interactive: false),
                    setAllowed: { allowed in events.append(allowed ? "write-UI-on" : "write-UI-off"); return true },
                    operation: { events.append("write-RPC"); return 0 })
                return status == 0
            })
            c.equal(events, ["read-UI-off", "read-UI-on", "read-RPC", "write-UI-off", "write-RPC"],
                    "explicit read is followed by independently quiet update")
            c.equal(result.read, .credentials(candidate), "quiet persistence returns retained rotated candidate")
            c.expect(result.retirePending, "successful quiet persistence retires pending")
            var launches = 0
            c.expect(!permit.admit(now: 10_002) { launches += 1 }, "pending recovery does not renew read permit")
            c.equal(launches, 0, "used permit authorizes no second launch")
        }

        checks.run("M11C no pending still reads once and never updates") { c in
            let memory = PendingCredentialMemory(pending: nil, current: .credentials(newLogin))
            let result = memory.resolve()
            c.equal(result.read, .credentials(newLogin), "ordinary current credentials pass through")
            c.equal(memory.reads, 1, "ordinary path reads exactly once")
            c.equal(memory.updates.count, 0, "ordinary path has no pending write")
            c.equal(memory.pending, nil, "no pending pair is invented")
        }

        // Identity is the credential pair, not raw JSON, key order, or unrelated metadata.
        let identityOld = Data(#"{"claudeAiOauth":{"accessToken":"fixture-access-old","refreshToken":"fixture-refresh-old"},"mcpMetadata":{"note":"original"}}"#.utf8)
        let identityCandidate = Data(#"{"claudeAiOauth":{"accessToken":"fixture-access-new","refreshToken":"fixture-refresh-new"},"mcpMetadata":{"note":"original"}}"#.utf8)
        let identityPending = ClaudeQuotaUpdate(expected: identityOld, replacement: identityCandidate)
        let oldVariants: [(String, Data, String)] = [
            ("reordered JSON", Data(#"{ "mcpMetadata": { "note": "original" }, "claudeAiOauth": { "refreshToken": "fixture-refresh-old", "accessToken": "fixture-access-old" } }"#.utf8), "original"),
            ("updated unrelated metadata", Data(#"{"mcpMetadata":{"note":"external edit"},"claudeAiOauth":{"refreshToken":"fixture-refresh-old","accessToken":"fixture-access-old"}}"#.utf8), "external edit")
        ]
        for (name, current, metadata) in oldVariants {
            for updateSucceeds in [false, true] {
                checks.run("M11C same old pair, \(name), quiet update success=\(updateSucceeds)") { c in
                    var reads = 0
                    var writes: [ClaudeQuotaUpdate] = []
                    let result = quotaReconcilePendingCredential(identityPending, read: {
                        reads += 1; return .credentials(current)
                    }, quietUpdate: { update in writes.append(update); return updateSucceeds })
                    c.equal(reads, 1, "semantic identity reconciliation reads exactly once")
                    c.equal(writes.count, 1, "same old pair retries candidate persistence, not new-login retirement")
                    if let write = writes.first {
                        c.equal(write.expected, current, "quiet write compares exact current record to fence concurrent metadata changes")
                        let expectedObject = (try? JSONSerialization.jsonObject(with: write.expected)) as? [String: Any]
                        let replacementObject = (try? JSONSerialization.jsonObject(with: write.replacement)) as? [String: Any]
                        let expectedAuth = expectedObject?["claudeAiOauth"] as? [String: Any]
                        let replacementAuth = replacementObject?["claudeAiOauth"] as? [String: Any]
                        c.equal(expectedAuth?["accessToken"] as? String, "fixture-access-old", "write expects the observed old access token")
                        c.equal(expectedAuth?["refreshToken"] as? String, "fixture-refresh-old", "write expects the observed old refresh token")
                        c.equal(replacementAuth?["accessToken"] as? String, "fixture-access-new", "write preserves retained candidate access token")
                        c.equal(replacementAuth?["refreshToken"] as? String, "fixture-refresh-new", "write preserves retained candidate refresh token")
                        c.equal((replacementObject?["mcpMetadata"] as? [String: Any])?["note"] as? String,
                                metadata, "pending update preserves unrelated current metadata")
                    }
                    if updateSucceeds {
                        c.expect(result.retirePending, "successful semantic reconciliation retires pending")
                        guard case .credentials(let data) = result.read else {
                            c.expect(false, "successful reconciliation yields credentials"); return
                        }
                        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                        let auth = object?["claudeAiOauth"] as? [String: Any]
                        c.equal(auth?["accessToken"] as? String, "fixture-access-new", "success returns candidate access token")
                        c.equal(auth?["refreshToken"] as? String, "fixture-refresh-new", "success returns candidate refresh token")
                        c.equal((object?["mcpMetadata"] as? [String: Any])?["note"] as? String,
                                metadata, "returned credentials retain unrelated current metadata")
                    } else {
                        c.expect(!result.retirePending, "same pair plus metadata change cannot discard RAM on write failure")
                        c.equal(result.read, .failed(.writeUnavailable), "failed persistence never returns old pair for OAuth retry")
                    }
                }
            }
        }

        checks.run("M11C candidate pair with different metadata is already persisted") { c in
            let current = Data(#"{"mcpMetadata":{"note":"external edit"},"claudeAiOauth":{"refreshToken":"fixture-refresh-new","accessToken":"fixture-access-new"}}"#.utf8)
            var reads = 0
            var writes = 0
            let result = quotaReconcilePendingCredential(identityPending, read: {
                reads += 1; return .credentials(current)
            }, quietUpdate: { _ in writes += 1; return true })
            c.equal(result.read, .credentials(current), "current candidate pair and new metadata used intact")
            c.expect(result.retirePending, "semantic candidate identity retires obsolete RAM pending")
            c.equal(reads, 1, "candidate reconciliation reads once")
            c.equal(writes, 0, "candidate metadata difference cannot trigger another write")
        }

        checks.run("M11C different valid access or refresh component identifies a distinct login") { c in
            for current in [
                Data(#"{"claudeAiOauth":{"accessToken":"fixture-access-old","refreshToken":"fixture-different-refresh"}}"#.utf8),
                Data(#"{"claudeAiOauth":{"accessToken":"fixture-different-access","refreshToken":"fixture-refresh-old"}}"#.utf8)
            ] {
                var reads = 0
                var writes = 0
                let result = quotaReconcilePendingCredential(identityPending, read: {
                    reads += 1; return .credentials(current)
                }, quietUpdate: { _ in writes += 1; return true })
                c.equal(result.read, .credentials(current), "distinct current pair used intact")
                c.expect(result.retirePending, "identity includes both access and refresh components")
                c.equal(reads, 1, "distinct pair read once")
                c.equal(writes, 0, "distinct login is not overwritten")
            }
        }
        // The seam offers only read/quietUpdate/cancel closures, no OAuth effect.
        // No assertion here claims the actual fetch caller avoids a second OAuth call.
    }

    private static func selectionAndPermissionChecks(_ checks: Checks) {
        // Presence is independent of observation time. Zero and partial readings are real data.
        let readings: [(String, Double?, Double?, ScopedLimit?, Int?)] = [
            ("session zero", 0, nil, nil, nil), ("weekly zero", nil, 0, nil, nil),
            ("partial session", 25, nil, nil, nil), ("partial weekly", nil, 50, nil, nil),
            ("both percentages", 25, 50, nil, nil),
            ("scoped only", nil, nil, ScopedLimit(name: "synthetic", percent: 0, reset: nil, severity: nil), nil),
            ("credits zero", nil, nil, nil, 0)
        ]
        for (name, session, weekly, scoped, credits) in readings {
            checks.run("M08S P2 empty failure keeps \(name) regardless of timestamps") { c in
                for previousAt in [Optional<Double>(9_000), nil] {
                    for responseAt in [Optional<Double>(10_000), nil] {
                        var previous = LimitData()
                        previous.session = session; previous.weekly = weekly
                        previous.scoped = scoped; previous.resetCredits = credits
                        previous.asOf = previousAt.map { Date(timeIntervalSince1970: $0) }
                        var failed = LimitData()
                        failed.asOf = responseAt.map { Date(timeIntervalSince1970: $0) }
                        failed.error = "synthetic failure"; failed.auth = .keychainError
                        failed.credentialIssue = .readInteractionRequired; failed.serverRetryAt = 10_120
                        let selected = quotaSelectSnapshot(failed, previous: previous)
                        c.equal(selected.session, session, "known session including zero survives empty failure")
                        c.equal(selected.weekly, weekly, "known weekly including zero survives empty failure")
                        c.equal(selected.scoped?.percent, scoped?.percent, "known scoped value survives empty failure")
                        c.equal(selected.resetCredits, credits, "known credits survive empty failure")
                        c.equal(selected.asOf, previousAt.map { Date(timeIntervalSince1970: $0) },
                                "snapshot retains its original known/nil observation time")
                        c.expect(!selected.apiFresh && selected.fromCache && selected.pollFailed,
                                 "empty failed response cannot become fresh success")
                        c.equal(selected.error, "synthetic failure", "current error survives selection")
                        c.expect(selected.auth == .keychainError, "current storage state survives selection")
                        c.equal(selected.credentialIssue, .readInteractionRequired, "current permission issue survives selection")
                        c.equal(selected.serverRetryAt, 10_120, "current server restriction survives selection")
                    }
                }
            }
        }

        checks.run("M08S both nil dates with actual candidate readings preserve candidate") { c in
            var previous = LimitData()
            previous.session = 25; previous.weekly = 0
            var nonfresh = LimitData()
            nonfresh.session = 99; nonfresh.weekly = 98
            nonfresh.error = "synthetic failed cached response"; nonfresh.pollFailed = true
            let selected = quotaSelectSnapshot(nonfresh, previous: previous)
            c.equal(selected.session, 99, "undated candidate readings are not discarded based on invented chronology")
            c.equal(selected.weekly, 98, "both undated populated snapshots preserve candidate values")
            c.equal(selected.asOf, nil, "two unknown dates do not invent an observation time")
            c.equal(selected.error, "synthetic failed cached response", "latest failure still visible")
        }

        checks.run("M08S missing prior readings do not erase response or invent values") { c in
            var previous = LimitData()
            previous.asOf = Date(timeIntervalSince1970: 20_000)
            var failed = LimitData()
            failed.error = "synthetic unavailable"; failed.pollFailed = true
            let empty = quotaSelectSnapshot(failed, previous: previous)
            c.equal(empty.session, nil, "no invented session percentage")
            c.equal(empty.weekly, nil, "no invented weekly percentage")
            c.equal(empty.asOf, nil, "a date-only prior does not create a reading")
            c.equal(empty.error, "synthetic unavailable", "failure retained with empty snapshots")
            failed.session = 0
            let known = quotaSelectSnapshot(failed, previous: previous)
            c.equal(known.session, 0, "empty prior cannot erase a known response zero")
            c.equal(known.asOf, nil, "response without date stays undated")
        }

        checks.run("M07S fresh response wins independent of dates and equal percentages") { c in
            for responseAt in [Optional<Double>(10_000), nil] {
                for percentage in [25.0, 0.0, 99.0] {
                    var previous = LimitData()
                    previous.session = 25; previous.weekly = 50
                    previous.asOf = Date(timeIntervalSince1970: 20_000)
                    previous.credentialIssue = .readInteractionRequired
                    var fresh = LimitData()
                    fresh.session = percentage; fresh.weekly = 50; fresh.apiFresh = true
                    fresh.asOf = responseAt.map { Date(timeIntervalSince1970: $0) }
                    let selected = quotaSelectSnapshot(fresh, previous: previous)
                    c.equal(selected.session, percentage, "apiFresh wins even against later old timestamp")
                    c.equal(selected.weekly, 50, "unchanged fresh percentage accepted")
                    c.equal(selected.asOf, fresh.asOf, "fresh response supplies its own known/nil timestamp")
                    c.expect(selected.apiFresh && !selected.pollFailed, "fresh selection stays successful")
                    c.equal(selected.credentialIssue, nil, "prior permission issue does not taint fresh response")
                }
            }
        }

        checks.run("M08S two known observation times choose newest nonfresh snapshot") { c in
            var previous = LimitData()
            previous.session = 25; previous.asOf = Date(timeIntervalSince1970: 9_000)
            var older = LimitData()
            older.session = 99; older.asOf = Date(timeIntervalSince1970: 8_000)
            older.error = "synthetic latest failure"; older.serverRetryAt = 10_120
            let retained = quotaSelectSnapshot(older, previous: previous)
            c.equal(retained.session, 25, "older reading cannot replace newer known reading")
            c.equal(retained.asOf, Date(timeIntervalSince1970: 9_000), "retained value and time stay together")
            c.equal(retained.error, "synthetic latest failure", "current failure belongs to attempt")
            c.equal(retained.serverRetryAt, 10_120, "current wait belongs to attempt")
            var newer = older
            newer.asOf = Date(timeIntervalSince1970: 10_000)
            let selected = quotaSelectSnapshot(newer, previous: previous)
            c.equal(selected.session, 99, "newer known reading remains available")
            c.equal(selected.asOf, Date(timeIntervalSince1970: 10_000), "newer value and time stay together")
        }

        checks.run("M08S populated snapshots prefer a known observation time over unknown") { c in
            var known = LimitData()
            known.session = 25; known.asOf = Date(timeIntervalSince1970: 9_000)
            var undated = LimitData()
            undated.session = 99; undated.error = "synthetic current failure"
            let retained = quotaSelectSnapshot(undated, previous: known)
            c.equal(retained.session, 25, "known previous timestamp wins over undated candidate")
            c.equal(retained.asOf, Date(timeIntervalSince1970: 9_000), "retained reading keeps its known time")
            c.equal(retained.error, "synthetic current failure", "current failure remains visible")
            let selected = quotaSelectSnapshot(known, previous: undated)
            c.equal(selected.session, 25, "known candidate timestamp wins over undated previous")
            c.equal(selected.asOf, Date(timeIntervalSince1970: 9_000), "candidate reading keeps its own known time")
        }

        checks.run("M11P one-shot permit, repeated admission and cancellation") { c in
            let clock = FakeClock()
            let permit = QuotaKeychainReadPermit(now: clock.now)
            var launches = 0
            c.expect(!permit.isCancelled, "new explicit permit is not cancelled")
            c.expect(permit.admit(now: clock.now) { launches += 1 }, "explicit read permit admits one launch")
            c.expect(!permit.admit(now: clock.now) { launches += 1 }, "repeat admission cannot relaunch")
            c.equal(launches, 1, "one-shot launch count")
            permit.cancel(); permit.cancel()
            c.expect(permit.isCancelled, "cancel is observable and idempotent")
            c.expect(!permit.admit(now: clock.now + 1) { launches += 1 }, "cancel cannot replenish used permit")
            c.equal(launches, 1, "cancelled used permit creates no further launch")

            let cancelled = QuotaKeychainReadPermit(now: clock.now)
            cancelled.cancel()
            c.expect(!cancelled.admit(now: clock.now) { launches += 1 }, "cancel before admission prevents launch")
            c.equal(launches, 1, "cancel-before-admission has zero additional launches")
        }

        checks.run("M11P fixed-clock permit expiry and invalid admission clock") { c in
            for offset in [14.999, 15.0, 15.001] {
                let permit = QuotaKeychainReadPermit(now: 10_000)
                var launches = 0
                let accepted = permit.admit(now: 10_000 + offset) { launches += 1 }
                c.equal(accepted, offset < 15, "permit expiry is exclusive at the 15-second boundary")
                c.equal(launches, offset < 15 ? 1 : 0, "expired permit never reaches launch closure")
            }
            for invalidNow in [Double.nan, .infinity, -.infinity] {
                let permit = QuotaKeychainReadPermit(now: 10_000)
                var launches = 0
                c.expect(!permit.admit(now: invalidNow) { launches += 1 }, "nonfinite admission time fails closed")
                c.equal(launches, 0, "bad clock creates no launch")
            }
        }

        checks.run("M11P throwing launch consumes permit and cancel remains possible") { c in
            let permit = QuotaKeychainReadPermit(now: 10_000)
            var launches = 0
            do {
                _ = try permit.admit(now: 10_000) {
                    launches += 1
                    throw SyntheticLaunchFailure.rejected
                }
                c.expect(false, "synthetic launch error must propagate")
            } catch SyntheticLaunchFailure.rejected {
                c.expect(true, "synthetic launch error propagated")
            } catch {
                c.expect(false, "unexpected error type")
            }
            c.expect(!permit.admit(now: 10_001) { launches += 1 }, "failed launch cannot reuse interactive permit")
            c.equal(launches, 1, "throw does not cause a second launch")
            permit.cancel()
            c.expect(permit.isCancelled, "throw releases lock so later cancel is possible")
        }

        checks.run("M11P helper argument parsing rejects interactive writes and malformed requests") { c in
            let flag = "--claude-quota-keychain-helper"
            for (operation, mode, interactive) in [("read", "quiet", false), ("update", "quiet", false),
                                                  ("read", "interactive", true)] {
                let request = ClaudeQuotaHelperRequest.parse(["fixture", flag, operation, mode])
                c.equal(request?.operation, operation, "accepted operation retained")
                c.equal(request?.interactive, interactive, "accepted interaction mode retained")
            }
            for args in [["fixture", flag, "update", "interactive"],
                         ["fixture", flag, "write", "interactive"],
                         ["fixture", flag, "read", "yes"],
                         ["fixture", flag, "delete", "quiet"],
                         ["fixture", "--other", "read", "quiet"],
                         ["fixture", flag, "read"],
                         ["fixture", flag, "read", "quiet", "extra"], []] {
                c.equal(ClaudeQuotaHelperRequest.parse(args), nil, "invalid or interactive-write request is rejected")
            }
        }

        for operation in ["read", "update"] {
            checks.run("M11P ordinary quiet \(operation) sets UI off before RPC") { c in
                let request = ClaudeQuotaHelperRequest(operation: operation, interactive: false)
                var events: [String] = []
                let result = quotaHelperInteraction(request, setAllowed: { allowed in
                    events.append(allowed ? "UI-on" : "UI-off"); return true
                }, operation: { events.append("RPC"); return 23 })
                c.equal(events, ["UI-off", "RPC"], "ordinary operation is quiet before touching backend")
                c.equal(result, 23, "backend result propagated")

                events = []
                let rejected = quotaHelperInteraction(request, setAllowed: { allowed in
                    events.append(allowed ? "UI-on" : "UI-off"); return false
                }, operation: { events.append("RPC"); return 0 })
                c.equal(events, ["UI-off"], "quiet configuration failure reaches zero RPC")
                c.expect(rejected != 0, "quiet configuration failure is reported")
            }
        }

        checks.run("M11P explicit read uses UI-off first, permission failure reaches zero RPC") { c in
            let request = ClaudeQuotaHelperRequest(operation: "read", interactive: true)
            for failureStage in ["none", "quiet", "interactive"] {
                var events: [String] = []
                let result = quotaHelperInteraction(request, setAllowed: { allowed in
                    events.append(allowed ? "UI-on" : "UI-off")
                    return failureStage != (allowed ? "interactive" : "quiet")
                }, operation: { events.append("RPC"); return 0 })
                let expected = failureStage == "quiet" ? ["UI-off"]
                    : failureStage == "interactive" ? ["UI-off", "UI-on"] : ["UI-off", "UI-on", "RPC"]
                c.equal(events, expected, "explicit read configuration order and fail-closed RPC")
                c.equal(result == 0, failureStage == "none", "configuration failures do not report success")
            }
        }

        checks.run("M11P read permit cannot authorize interactive update even bypassing parser") { c in
            let permit = QuotaKeychainReadPermit(now: 10_000)
            let forgedWrite = ClaudeQuotaHelperRequest(operation: "update", interactive: true)
            var events: [String] = []
            var helperResult: Int32 = 0
            c.expect(permit.admit(now: 10_000) {
                helperResult = quotaHelperInteraction(forgedWrite, setAllowed: { allowed in
                    events.append(allowed ? "UI-on" : "UI-off"); return true
                }, operation: { events.append("RPC"); return 0 })
            }, "permit only controls the injected launch admission")
            c.equal(events, ["UI-off"], "interactive write cannot turn UI on or reach RPC")
            c.expect(helperResult != 0, "write rejected independently of read permit")
            var extraLaunches = 0
            c.expect(!permit.admit(now: 10_001) { extraLaunches += 1 }, "read permit cannot be reused after rejected write")
            c.equal(extraLaunches, 0, "used permit performs no second launch")
        }

        for english in [false, true] {
            checks.run("M11P credential permission feedback and cancel, english=\(english)") { c in
                let needsRead = quotaRefreshFeedback(inFlight: false, serverUntil: nil, localUntil: 0,
                    failed: true, authenticationRequired: false, dataAt: 9_000, nextAutomaticAt: nil,
                    now: 10_000, english: english, credentialIssue: .readInteractionRequired)
                c.equal(needsRead.action, .allowKeychain, "interaction-required offers explicit read permission")
                c.expect(!needsRead.actionTitle.isEmpty, "permission action has a localized label")
                c.equal(needsRead.dataAt, 9_000, "permission issue preserves old reading timestamp")
                let pending = quotaRefreshFeedback(inFlight: true, serverUntil: nil, localUntil: 0,
                    failed: true, authenticationRequired: false, dataAt: 9_000, nextAutomaticAt: nil,
                    now: 10_000, english: english, credentialIssue: .readInteractionRequired, permissionPending: true)
                c.equal(pending.action, .cancelKeychain, "explicit pending permission offers cancellation")
                c.equal(pending.actionTitle, english ? "Cancel" : "Отменить", "cancel action localized")
                let ordinary = quotaRefreshFeedback(inFlight: true, serverUntil: nil, localUntil: 0,
                    failed: false, authenticationRequired: false, dataAt: nil, nextAutomaticAt: nil,
                    now: 10_000, english: english, permissionPending: false)
                c.equal(ordinary.action, .none, "ordinary refresh is not a pending permission request")
                let writeFailed = quotaRefreshFeedback(inFlight: false, serverUntil: nil, localUntil: 0,
                    failed: true, authenticationRequired: false, dataAt: 9_000, nextAutomaticAt: nil,
                    now: 10_000, english: english, credentialIssue: .writeUnavailable)
                c.equal(writeFailed.action, .restoreAccess, "write unavailable uses recovery instead of interactive read permit")
                for issue in [QuotaCredentialIssue.readUnavailable, .readTimedOut, .cancelled] {
                    let feedback = quotaRefreshFeedback(inFlight: false, serverUntil: nil, localUntil: 0,
                        failed: true, authenticationRequired: false, dataAt: nil, nextAutomaticAt: nil,
                        now: 10_000, english: english, credentialIssue: issue)
                    c.expect(feedback.action != .allowKeychain && feedback.action != .cancelKeychain,
                             "other read failures do not invent permission scope")
                    c.expect(feedback.action != .restoreAccess, "storage failure alone does not fabricate expired auth")
                    c.equal(feedback.dataAt, nil, "storage error does not invent observation time")
                }
            }
        }
    }
}
