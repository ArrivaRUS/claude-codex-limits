import Foundation

// C3 part A — model tests written RED before implementation (2026-10-23).
// Sources: plans C3; test-plan C3-01/02/03/04/05/07/11/12/13/14; UX §§2–5,8,11;
// synth §F/F.1; PRD RL13–16, П5-а, Т13/14/16; lessons 004/006/011/012/013.
// No AppKit/font/application creation. No persistent preferences/credentials, runtime refresh,
// singleton history or live transport. C3-14 uses only injected HTTP/keychain/defaults.
// Every tested clock/locale/timezone is explicit.
// Only writes: a unique temporary directory, removed after the history queue drains.
// C3-14 exercises Controller + injected GitHubSync read seam, never AppDelegate.doRefresh
// (lesson 011). Its HTTP trap proves provider/mutation exclusion for that seam;
// runtime provider filtering/wiring requires independent source review.
// Fixtures + optional production source are read from the explicit fixture directory.
// Entry: runRemoteLimitsC3SelfTests() -> failed check count, BEFORE AppKit in subscriptions selftest.
// Contract agreed with coordinator: RemoteManualPhase, RemoteCardPresentation,
// remoteCardPresentation(_:sync:language:narrow:now:timeZone:manual:),
// remoteCardLine2(_:state:phase:lang:wide:now:timeZone:), limitCanFix(remote: AccountView),
// snapshotHorizon(_:), advVerdict(_:data:now:language:), RemoteAutoFooter and
// remoteAutoFooter(views:enabled:intervals:language:), snapshotWindowPace(..., now: Date?).
// final class RemoteManualRefreshController {
//   init(clock: @escaping () -> Date, read: @escaping (@escaping (Bool) -> Void) -> Void,
//        onChange: @escaping () -> Void = {})
//   func request() -> Bool; func phase(now: Date) -> RemoteManualPhase
// }
// GitHubSync.readSynchronously() -> Bool: injected read-only seam, no queued overlap/retry.
// enum RemoteManualPhase { case idle, reading, checked(Date), cooldown(Int), failed, pollAllowed(Date) }
// struct RemoteCardPresentation {
//   var simpleTitle, advancedTitle, planBadge, machineSuffix: String
//   var sourceLine, statusLine, statusTone, advancedBadge: String
//   var action: String?  // nil or "syncsettings"; statusTone: none/textMid/amber/ADV_LINK
//   var tooltip, accessibilityLabel, accessibilityValue, cardHit: String
//   var paceNotice: String?; var sessionResetText: String
//   var sessionDimmed, showsValues: Bool
// }
// struct RemoteAutoFooter { var products: [String]; var noSubscriptions: Bool; var tooltip: String }
// struct RemoteAccountFrame {
//   var now: Date; var sync: ReaderSyncState
//   var allViews, visibleViews, displayedViews: [AccountView]
// }
// func remoteAccountFrame(local: (LimitData, LimitData), localIds: [String: String], remote: SyncRemoteCache,
//                         hidden: Set<String>, menu: [String: String], sync: ReaderSyncState,
//                         now: Date, localMachineName: String = "mac") -> RemoteAccountFrame
//   // Shared with actual draw: frame captures one clock/state for displayed cards and their journal events.
// func snapshotWindowPace(used: Double?, reset: Date?, windowH: Double, asOf: Date?,
//                        recentRate: Double? = nil, now: Date? = nil) -> WindowPace?
//   // Explicit now rejects asOf > now + 300 seconds; nil preserves existing local callers.
// V5 text vectors explicitly set AccountView.state; resolver coverage is separate.
// They intentionally preserve the literal UX example times, independently of state age.
// State 7 is an explanatory presentation, without source/values; runtime resolver
// must return NO remote cards for off/revoked/awaitingCode (auth-bound cache).
// No claim of compiled/green status: Swift is deliberately not run on Linux.

private typealias C3Expect = (Bool, String) -> Void
private let C3_LABEL = "c300000000000001"
private let C3_OTHER = "c300000000000002"
private let C3_FILE = "machine-c3-vps.json"
private let C3_ZONE = TimeZone(secondsFromGMT: 0)!
private func c3Date(_ text: String) -> Date {
    ISO8601DateFormatter().date(from: text) ?? Date(timeIntervalSince1970: 0)
}
private let C3_NOW = c3Date("2026-10-12T16:00:00Z")
private func c3Fixture<T: Decodable>(_ name: String, as type: T.Type) -> T? {
    guard let dir = remoteLimitsFixturesDir(), let data = FileManager.default.contents(atPath: dir + "/" + name) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
}
private func c3Absent() -> LimitData { LimitData(present: false) }
private func c3View(state: RemoteCardState = .fresh, status: String = "ok", product: String = "claude") -> AccountView {
    var source = RemoteSource(machineId: "c3-vps", machineName: "vps")
    source.asOf = c3Date("2026-10-12T15:43:00Z")
    source.nextAt = c3Date("2026-10-12T16:43:00Z")
    source.interval = 3600; source.mode = "auto"; source.status = status
    source.lastSeenAt = c3Date("2026-10-12T15:52:00Z")
    source.freshUntil = c3Date("2026-10-12T17:03:00Z")
    source.attemptAt = source.asOf
    if status == "rate_limited" { source.retryUntil = c3Date("2026-10-12T16:30:00Z") }
    let d = LimitData(session: 42.5, weekly: 61,
                      sessionReset: c3Date("2026-10-12T18:00:00Z"), weeklyReset: c3Date("2026-10-15T07:00:00Z"),
                      scoped: ScopedLimit(name: "Fable", percent: 30, reset: c3Date("2026-10-16T07:00:00Z"), severity: nil),
                      plan: "max", asOf: source.asOf, fromCache: true, source: source)
    return AccountView(product: product, label: C3_LABEL, historyKey: C3_LABEL,
                       caption: product == "claude" ? "Claude Max 20x · vps" : "Codex Pro · vps",
                       data: d, isLocal: false, tier: "default_claude_max_20x", usageDays: [:], machines: ["vps"], state: state)
}
private func c3Presentation(_ view: AccountView, language: String = "ru", narrow: Bool = true,
                            now: Date = C3_NOW, sync: ReaderSyncState = ReaderSyncState(phase: .on),
                            manual: RemoteManualPhase = .idle) -> RemoteCardPresentation {
    remoteCardPresentation(view, sync: sync, language: language, narrow: narrow, now: now, timeZone: C3_ZONE, manual: manual)
}
private func c3Cache(_ view: AccountView) -> SyncRemoteCache {
    var a = RemoteAccount(product: view.product, label: view.label, status: view.data.source?.status ?? "ok")
    a.plan = view.data.plan; a.tier = view.tier; a.asOf = view.data.asOf
    a.attemptAt = view.data.asOf; a.machineId = "c3-vps"; a.machineName = "vps"
    a.machineLastSeenAt = C3_NOW
    a.windows = RemoteWindows(session: RemoteWindow(pct: view.data.session ?? 0, resetAt: view.data.sessionReset),
                              weekly: RemoteWindow(pct: view.data.weekly ?? 0, resetAt: view.data.weeklyReset))
    a.schedule = RemoteSchedule(mode: "auto", interval: view.data.source?.interval ?? 900, nextAt: view.data.source?.nextAt)
    var cache = SyncRemoteCache(); cache.accounts = [a]; return cache
}
private func c3Resolve(_ cache: SyncRemoteCache, now: Date, phase: SyncPhase = .on) -> [AccountView] {
    resolveAccounts(local: (c3Absent(), c3Absent()), localIds: [:], remote: cache, hidden: [], menu: [:],
                    sync: ReaderSyncState(phase: phase), now: now)
}

// C3-01 / Т16, 012: untrusted captions never select an action or destination.
private func c3C301(_ expect: C3Expect) {
    for product in ["claude", "codex"] {
        let target = product == "claude" ? "open:https://claude.ai/settings/usage" : "open:https://chatgpt.com/codex/cloud/settings/analytics#usage"
        for (state, status) in [(RemoteCardState.fresh, "error"), (.stale, "ok"), (.signInRequired, "expired"),
                                (.signInRequired, "signed_out"), (.stale, "error"), (.serviceWait, "rate_limited"), (.offline, "error")] {
            // Raw cached views deliberately bypass caption validation here:
            // this tests action isolation, not acceptance of wire captions.
            for caption in ["javascript:alert(1)", "file:///synthetic", "%@%n"] {
                var view = c3View(state: state, status: status, product: product); view.caption = caption
                expect(!limitCanFix(remote: view), "C3-01 \(product)/\(status): remote recovery is never local CLI recovery")
                for lang in ["ru", "en"] {
                    let p = c3Presentation(view, language: lang)
                    let copy = [p.simpleTitle, p.advancedTitle, p.planBadge, p.machineSuffix, p.sourceLine,
                                p.statusLine, p.advancedBadge, p.tooltip, p.accessibilityLabel, p.accessibilityValue,
                                p.cardHit, p.action ?? "", p.paceNotice ?? "", p.sessionResetText].joined(separator: "\n")
                    expect(p.cardHit == target && !["claude login", "claude → /login", "Как починить?", "claudefix"].contains(where: { copy.contains($0) }) && !p.advancedBadge.contains("вход истёк"),
                           "C3-01 \(product)/\(status)/\(lang): constant usage destination and no local recovery copy")
                }
            }
        }
    }
    var local = c3View(state: .signInRequired, status: "expired"); local.isLocal = true; local.data.auth = .expired
    expect(limitCanFix(remote: local), "C3-01 control: confirmed local Claude auth still permits existing recovery")
    local.product = "codex"
    expect(!limitCanFix(remote: local), "C3-01 control: Codex never enters Claude recovery")
}

private struct C3Golden: Decodable {
    var `case`: String; var state: Int; var status: String; var language: String; var narrow: Bool
    var statusLine: String; var tone: String; var badge: String; var tooltip: String; var action: String?
}
private struct C3ManualGolden: Decodable { var language: String; var phase: String; var text: String }

// C3-02: independent golden rows, full tooltip/AX strings, explicit locale and clock.
private func c3C302(_ expect: C3Expect) {
    guard let rows = c3Fixture("c3-v5-golden.json", as: [C3Golden].self), rows.count == 32 else {
        expect(false, "C3-02 32 V5 golden rows readable"); return
    }
    for g in rows {
        guard let state = RemoteCardState(rawValue: g.state) else { expect(false, "C3-02 valid golden state"); continue }
        var v = c3View(state: state, status: g.status)
        let sync = ReaderSyncState(phase: state == .signedOut ? .off : .on,
                                   warning: state == .syncStalled ? (g.language == "ru" ? "Нет связи с GitHub." : "GitHub is unreachable.") : nil)
        if state == .signedOut { v.data = LimitData(present: true) }
        let p = c3Presentation(v, language: g.language, narrow: g.narrow, sync: sync)
        let key = "C3-02 V5 \(g.case)/\(g.language)/\(g.narrow ? "narrow" : "wide")"
        expect(p.statusLine == g.statusLine && p.statusTone == g.tone && p.advancedBadge == g.badge && p.action == g.action, key + ": exact line/tone/badge/action")
        expect(p.tooltip == g.tooltip && p.accessibilityValue == g.tooltip && p.accessibilityLabel == v.caption, key + ": complete tooltip and AX")
        expect(p.showsValues == (state != .signedOut), key + ": state7 has no cached values")
        expect(remoteCardLine2(v, state: state, phase: .idle, lang: g.language, wide: !g.narrow, now: C3_NOW, timeZone: C3_ZONE) == g.statusLine,
               key + ": shared line2 seam")
        if state != .signedOut {
            expect(p.sourceLine == (g.language == "ru" ? "Данные с vps от 15:43" : "Data from vps at 15:43"), key + ": unchanged asOf source")
        } else { expect(p.sourceLine.isEmpty, key + ": no fabricated timestamp") }
    }
    guard let manual = c3Fixture("c3-manual-golden.json", as: [C3ManualGolden].self), manual.count == 10 else {
        expect(false, "C3-02 ten B8 golden rows readable"); return
    }
    for g in manual {
        var v = c3View()
        let phase: RemoteManualPhase
        let now = c3Date("2026-10-12T15:45:59Z")
        switch g.phase {
        case "reading": phase = .reading
        case "checked": phase = .checked(c3Date("2026-10-12T15:45:00Z"))
        case "cooldown": phase = .cooldown(12)
        case "failed": phase = .failed
        default: phase = .pollAllowed(c3Date("2026-10-12T15:58:00Z")); v.isLocal = true
        }
        let floorExplanation = g.language == "ru"
            ? "Последний запрос по аккаунту — 15:43 (vps). Не чаще раза в 15 минут со всех компьютеров; GitHub перечитан, сервис не опрашивали."
            : "Last request for this account: 15:43 (vps). At most once per 15 minutes across all computers; GitHub re-read, provider not polled."
        for narrow in [true, false] {
            guard let base = rows.first(where: { $0.case == "1" && $0.language == g.language && $0.narrow == narrow }) else {
                expect(false, "C3-02 B8 fresh golden tooltip exists"); continue
            }
            let p = c3Presentation(v, language: g.language, narrow: narrow, now: now, manual: phase)
            let expectedTooltip = ([g.text] + (g.phase == "pollAllowed" ? [floorExplanation] : []) + [base.tooltip]).joined(separator: "\n")
            expect(p.statusLine == g.text && p.sourceLine.contains("15:43"), "C3-02 B8 \(g.phase)/\(g.language)/\(narrow): exact phase; asOf unchanged")
            expect(p.tooltip == expectedTooltip && p.tooltip.contains(g.text) && p.accessibilityValue == expectedTooltip,
                   "C3-02 B8 \(g.phase)/\(g.language)/\(narrow): exact complete tooltip/AX, manual phase first")
            if g.phase == "checked" {
                for age in [60.0, 61.0] {
                    let expiredAt = c3Date("2026-10-12T15:45:00Z").addingTimeInterval(age)
                    let expired = c3Presentation(v, language: g.language, narrow: narrow, now: expiredAt, manual: phase)
                    expect(expired.statusLine.isEmpty && expired.tooltip == base.tooltip && expired.accessibilityValue == base.tooltip
                           && !expired.tooltip.contains(g.text),
                           "C3-02 checked expires from line/tooltip/AX at \(Int(age)) seconds, \(g.language)/\(narrow)")
                }
            }
        }
    }
    for lang in ["ru", "en"] {
        var old = c3View(); old.data.asOf = c3Date("2026-10-11T15:43:00Z"); old.data.source?.asOf = old.data.asOf
        for narrow in [true, false] {
            let expected = lang == "ru" ? (narrow ? "С vps от 11.10 15:43" : "Данные с vps от 11.10 15:43")
                                       : (narrow ? "From vps on 11.10 15:43" : "Data from vps on 11.10 15:43")
            expect(c3Presentation(old, language: lang, narrow: narrow).sourceLine == expected, "C3-02 previous day retains complete date/time \(lang)/\(narrow)")
        }
        var absent = c3View(); absent.data.asOf = nil; absent.data.source?.asOf = nil
        expect(c3Presentation(absent, language: lang).sourceLine == (lang == "ru" ? "Нет данных с vps" : "No data from vps"), "C3-02 nil asOf never becomes now")
        var revoked = c3View(state: .signedOut); revoked.data = LimitData(present: true)
        expect(c3Presentation(revoked, language: lang, sync: ReaderSyncState(phase: .revoked)).statusLine == (lang == "ru" ? "Войдите в GitHub заново ›" : "Sign in to GitHub again ›"), "C3-02 revoked differs from signed out")
        for state in [RemoteCardState.fresh, .stale] {
            let error = c3Presentation(c3View(state: state, status: "error"), language: lang)
            let last = lang == "ru" ? "Последний статус vps: ошибка обновления" : "Last vps status: update failed"
            expect(error.tooltip.contains(last) && error.advancedBadge != (lang == "ru" ? "вход на vps" : "sign-in on vps"), "C3-02 error retains last status without auth diagnosis")
        }
        var wait = c3View(state: .serviceWait, status: "rate_limited"); wait.data.source?.retryUntil = nil
        expect(c3Presentation(wait, language: lang).statusLine == (lang == "ru" ? "Пауза сервиса" : "Service wait"), "C3-02 unknown service deadline")
    }
    // Status provenance is independent of snapshot provenance (C1 retained values).
    for lang in ["ru", "en"] {
        var split = c3View(state: .signInRequired, status: "expired", product: "codex")
        split.data.source?.statusMachineName = "alse"; split.data.source?.statusMachineId = "c3-alse"
        let model = c3Presentation(split, language: lang, narrow: false)
        let line = lang == "ru" ? "На машине alse нужно обновить вход Codex" : "Codex sign-in needs renewing on alse"
        let full = lang == "ru"
            ? "Вход Codex истёк на машине alse. Откройте Codex на alse (CLI обновит вход сам) или войдите там заново. На этом Mac ничего делать не нужно."
            : "The Codex sign-in expired on alse. Open Codex on alse (the CLI renews it itself) or sign in there again. Nothing to do on this Mac."
        expect(model.statusLine == line && model.tooltip.hasPrefix(full + "\n") && model.sourceLine.contains("vps") && model.sourceLine.contains("15:43"),
               "C3-02 status attempt names alse; retained snapshot names vps; product-specific Codex copy")
        var manualSchedule = c3View(); manualSchedule.data.source?.mode = "fixed"; manualSchedule.data.source?.interval = 1800
        let fixed = c3Presentation(manualSchedule, language: lang)
        expect(fixed.tooltip.contains(lang == "ru" ? "Расписание vps: каждые 30 мин" : "vps schedule: every 30 min"), "C3-02 fixed schedule full tooltip line")
        var backoff = c3View(); backoff.data.source?.interval = 7200; backoff.data.source?.backoff = true
        expect(c3Presentation(backoff, language: lang).tooltip.contains(lang == "ru" ? "Расписание vps: Авто · 2 ч, пауза после ошибки" : "vps schedule: Auto · 2 h, paused after an error"), "C3-02 backoff schedule full tooltip line")
    }
    // Review minor: a valid machine tag may equal the formatted snapshot date.
    // Compact only the machine field; replacing text in a completed line corrupts both.
    var collision = c3View()
    collision.data.source?.machineName = "11.10 15:43"
    collision.data.asOf = c3Date("2026-10-11T15:43:00Z")
    collision.data.source?.asOf = collision.data.asOf
    for lang in ["ru", "en"] {
        let line = remoteCardSourceLine(collision, language: lang, narrow: true, now: C3_NOW,
                                        timeZone: C3_ZONE, compact: true, machineLimit: 8)
        expect(line == (lang == "ru" ? "С 11.10 15… от 11.10 15:43" : "From 11.10 15… on 11.10 15:43"),
               "C3-02 \(lang): machine/date collision truncates only machine, preserves complete snapshot timestamp")
    }
    for phase in [SyncPhase.off, .revoked, .awaitingCode] {
        expect(c3Resolve(c3Cache(c3View()), now: C3_NOW, phase: phase).isEmpty, "C3-02 state7 resolver discards remote cards for auth phase \(phase)")
    }
}

// C3-03: one remote account, subscription from its own tier, pace from its asOf.
private func c3C303(_ root: String, _ expect: C3Expect) {
    var v = c3View(); v.data.asOf = C3_NOW.addingTimeInterval(-600); v.data.source?.asOf = v.data.asOf
    v.usageDays = ["2026-10-12": ["claude-fable-5-1": DayModelUsage(input: 2000, output: 500, cacheRead: 100000, cacheWrite5m: 0, cacheWrite1h: 0, turns: 12)]]
    let p = c3Presentation(v)
    expect(p.simpleTitle == "Claude · vps" && p.advancedTitle == "Claude Code" && p.planBadge == "Max 20x" && p.machineSuffix == "· vps" && p.sourceLine == "Данные с vps от 15:50", "C3-03 remote Claude header/source/plan exactly")
    let money = moneySummary(v, local: UsageIndex(), now: C3_NOW)
    expect(money.subMonthly == 200 && !money.subEstimated && money.usdApi > 0, "C3-03 existing account money seam: $200 without estimate and positive usage")
    let history = UsageHistory(path: root + "/c3-history.jsonl")
    let t1 = C3_NOW.addingTimeInterval(-1500), t2 = v.data.asOf!
    history.recordRemote(product: "claude", label: C3_LABEL, UsageSample(t: t1.timeIntervalSince1970, product: "claude", session: 40, weekly: nil, scoped: nil, scopedName: nil, sessionReset: nil, weeklyReset: nil, acct: C3_LABEL))
    history.recordRemote(product: "claude", label: C3_LABEL, UsageSample(t: t2.timeIntervalSince1970, product: "claude", session: 42.5, weekly: nil, scoped: nil, scopedName: nil, sessionReset: nil, weeklyReset: nil, acct: C3_LABEL))
    history.recordRemote(product: "claude", label: C3_OTHER, UsageSample(t: t2.timeIntervalSince1970, product: "claude", session: 99, weekly: nil, scoped: nil, scopedName: nil, sessionReset: nil, weeklyReset: nil, acct: C3_OTHER))
    let rate = history.recentRate("claude", acct: C3_LABEL, metric: { $0.session }, minutes: 60, now: C3_NOW)
    expect(rate.map { abs($0 - 10) < 0.001 } ?? false, "C3-03 existing recentRate: 10 points/hour; foreign account excluded")
    let pace = snapshotWindowPace(used: v.data.session, reset: v.data.sessionReset, windowH: 5, asOf: v.data.asOf, recentRate: rate)
    expect(pace?.projectedPct != nil && pace?.recentRatePerH == rate && pace.map { abs($0.remainingH - v.data.sessionReset!.timeIntervalSince(t2) / 3600) < 1e-9 } == true,
           "C3-03 forecast/pace anchored to asOf, not the reader clock")
    let row = AdvRow(limit: PacedLimit(id: "session", name: "Session", pace: pace, color: 0, used: v.data.session), kind: .full, credits: nil)
    expect(advVerdict(row, data: v.data, now: C3_NOW, language: "en").hasPrefix("Lasts until reset"), "C3-03 advanced forecast is available")
}

// C3-04: V4 across all three consumers; includes a >4h fresh snapshot to catch hardcoded age.
private func c3C304(_ expect: C3Expect) {
    for age in [13800.0, 14400.0, 15000.0, 15600.0, 15601.0] {
        var v = c3View(); let at = C3_NOW.addingTimeInterval(-age)
        v.data.asOf = at; v.data.source?.asOf = at; v.data.source?.interval = 14400
        v.data.source?.nextAt = at.addingTimeInterval(14400); v.data.source?.freshUntil = at.addingTimeInterval(15600)
        // Thirty minutes of observed window time makes a forecast meaningful;
        // the old reset=asOf+5h fixture was at window opening (no forecast).
        v.data.sessionReset = at.addingTimeInterval(4.5 * 3600)
        v.data.session = 5 // 30 minutes elapsed: projected 50%, safely below warning threshold.
        let fresh = age <= 15600
        expect(snapshotHorizon(v.data) == 15600, "C3-04 Auto4h horizon includes 20min grace")
        expect(metricIsStale(v.data, metric: "session", now: C3_NOW) == !fresh && isStale(v.data, C3_NOW) == !fresh,
               "C3-04 age \(Int(age)): metricIsStale/isStale use source horizon")
        let cache = c3Cache(v)
        expect(c3Resolve(cache, now: C3_NOW).first?.state == (fresh ? .fresh : .stale), "C3-04 resolver same horizon at \(Int(age))")
        let pace = snapshotWindowPace(used: 5, reset: v.data.sessionReset, windowH: 5, asOf: at)
        expect(pace?.projectedPct != nil, "C3-04 forecast fixture has at least ten minutes of window history")
        let row = AdvRow(limit: PacedLimit(id: "session", name: "Session", pace: pace, color: 0, used: 5), kind: .full, credits: nil)
        let verdict = advVerdict(row, data: v.data, now: C3_NOW, language: "en")
        expect(fresh ? verdict.hasPrefix("Lasts until reset") : verdict.hasPrefix("Snapshot forecast:"), "C3-04 advVerdict uses same horizon at \(Int(age))")
        if !fresh {
            let staleForecastRow = AdvRow(limit: row.limit, kind: .stale, credits: nil)
            expect(advVerdict(staleForecastRow, data: v.data, now: C3_NOW, language: "en") == "Snapshot forecast: 50%",
                   "C3-04 beyond horizon: snapshot forecast takes priority over stale row kind")
        }
    }
    // No projection is invented at window opening, even for an old snapshot.
    var opening = c3View().data
    opening.asOf = C3_NOW.addingTimeInterval(-15601)
    opening.source?.asOf = opening.asOf
    opening.source?.freshUntil = opening.asOf!.addingTimeInterval(15600)
    opening.sessionReset = opening.asOf!.addingTimeInterval(5 * 3600)
    let openingPace = snapshotWindowPace(used: 10, reset: opening.sessionReset, windowH: 5, asOf: opening.asOf)
    let openingRow = AdvRow(limit: PacedLimit(id: "session", name: "Session", pace: openingPace, color: 0, used: 10), kind: .full, credits: nil)
    expect(openingPace != nil && openingPace?.projectedPct == nil
           && advVerdict(openingRow, data: opening, now: C3_NOW, language: "en") == "Not enough pace data in snapshot",
           "C3-04 window opening: no fabricated snapshot forecast")
    let staleRow = AdvRow(limit: openingRow.limit, kind: .stale, credits: nil)
    expect(isStale(opening, C3_NOW) && metricIsStale(opening, metric: "session", now: C3_NOW)
           && advVerdict(staleRow, data: opening, now: C3_NOW, language: "en") == "Not enough pace data in snapshot",
           "C3-04 beyond horizon: snapshot no-forecast wording takes priority over stale row kind")
    let noPaceRow = AdvRow(limit: PacedLimit(id: "session", name: "Session", pace: nil, color: 0, used: 10), kind: .full, credits: nil)
    expect(advVerdict(noPaceRow, data: opening, now: C3_NOW, language: "en") == "Not enough pace data in snapshot",
           "C3-04 beyond horizon: absent pace still uses snapshot no-forecast wording")
    var local = c3View().data; local.source = nil
    expect(snapshotHorizon(local) == SNAPSHOT_MAX_AGE, "C3-04 local snapshot retains legacy horizon")
    var negative = c3View().data; negative.source?.freshUntil = negative.asOf!.addingTimeInterval(-1)
    expect(snapshotHorizon(negative) == 0, "C3-04 negative horizon clamps to zero")

    // Time alone can change rendered state; every render's event must use that
    // same newly resolved state. The cache is immutable and no sync/API is called.
    var seed = c3View()
    seed.data.asOf = C3_NOW.addingTimeInterval(-1500); seed.data.source?.asOf = seed.data.asOf
    seed.data.source?.interval = 900; seed.data.source?.nextAt = C3_NOW.addingTimeInterval(-600)
    let frozen = c3Cache(seed) // lastSeenAt = C3_NOW; freshUntil = C3_NOW + 600.
    let transitions: [(TimeInterval, RemoteCardState)] = [(0, .fresh), (600, .fresh), (601, .stale), (1800, .stale), (1801, .offline)]
    for (elapsed, expected) in transitions {
        let tick = C3_NOW.addingTimeInterval(elapsed)
        let frame = remoteAccountFrame(local: (c3Absent(), c3Absent()), localIds: [:], remote: frozen,
                                       hidden: [], menu: [:], sync: ReaderSyncState(phase: .on), now: tick)
        let views = frame.displayedViews
        let events = readerCardStateEvents(frame.displayedViews, now: frame.now)
        expect(frame.now == tick && views.count == 1 && views.first?.state == expected && views.first?.data.session == 42.5,
               "C3-04 unchanged cache + clock \(Int(elapsed)) seconds: correct state; last values retained")
        expect(events.count == 1 && (events.first?["state"] as? Int) == views.first?.state.rawValue
               && (events.first?["state"] as? Int) == expected.rawValue
               && (events.first?["age"] as? Int) == Int(1500 + elapsed)
               && (events.first?["label"] as? String) == C3_LABEL,
               "C3-04 clock-only render event equals resolved state/age/identity at \(Int(elapsed)) seconds")
    }
}

private func c3C305(_ expect: C3Expect) {
    let now = c3Date("2026-10-12T11:20:00Z")
    var reset = c3View(); reset.data.asOf = c3Date("2026-10-12T10:00:00Z"); reset.data.source?.asOf = reset.data.asOf
    reset.data.sessionReset = c3Date("2026-10-12T11:00:00Z")
    for lang in ["ru", "en"] {
        let p = c3Presentation(reset, language: lang, now: now)
        expect(p.sessionDimmed && p.sessionResetText == (lang == "ru" ? "окно сброшено" : "window reset"), "C3-05 \(lang): past reset grey; exact reset copy")
        for offset in [300.0, 301.0] {
            var future = c3View(); future.data.asOf = now.addingTimeInterval(offset); future.data.source?.asOf = future.data.asOf
            future.data.source?.futureAsOf = offset > 300
            future.data.sessionReset = now.addingTimeInterval(3 * 3600)
            let guarded = snapshotWindowPace(used: future.data.session, reset: future.data.sessionReset,
                                             windowH: 5, asOf: future.data.asOf, now: now)
            expect((guarded != nil) == (offset <= 300), "C3-05 actual pace seam: future \(Int(offset)) seconds \(offset > 300 ? "is nil" : "is valid")")
            let model = c3Presentation(future, language: lang, now: now)
            let notice = lang == "ru" ? "Нет свежих данных · темп не считаем" : "No fresh data · pace paused"
            expect(offset > 300 ? model.paceNotice == notice : model.paceNotice == nil, "C3-05 \(lang): future cutoff \(Int(offset))")
            if offset > 300 {
                let warning = lang == "ru" ? "Время данных vps в будущем — темп не считаем" : "vps data time is in the future — pace paused"
                expect(model.tooltip.contains(warning) && model.accessibilityValue == model.tooltip, "C3-05 \(lang): future warning in complete tooltip/AX")
            }
        }
        var noTime = c3View(); noTime.data.asOf = nil; noTime.data.source?.asOf = nil
        expect(c3Presentation(noTime, language: lang, now: now).paceNotice == (lang == "ru" ? "Нет свежих данных · темп не считаем" : "No fresh data · pace paused"), "C3-05 nil asOf pauses pace")
        expect(snapshotWindowPace(used: 42.5, reset: now.addingTimeInterval(3600), windowH: 5, asOf: nil, now: now) == nil,
               "C3-05 actual pace seam: missing asOf is nil")
    }
}

private func c3C307(_ expect: C3Expect) {
    for lang in ["ru", "en"] {
        let remote = c3View()
        let empty = remoteAutoFooter(views: [remote], enabled: ["claude", "codex"], intervals: ["claude": 14400], language: lang)
        let copy = lang == "ru" ? "Этот компьютер ничего не опрашивает. Аккаунты с других компьютеров обновляются по их расписанию — оно в подсказке карточки." : "This computer polls nothing. Accounts from other computers update on their own schedule, shown in the card tooltip."
        expect(empty.noSubscriptions && empty.products.isEmpty && empty.tooltip == copy, "C3-07 \(lang): remote-only noSubscriptions exact explanation")
        var local = c3View(product: "codex"); local.isLocal = true; local.data.source = nil
        let one = remoteAutoFooter(views: [remote, local], enabled: ["claude", "codex"], intervals: ["claude": 14400, "codex": 900], language: lang)
        expect(!one.noSubscriptions && one.products == ["codex"] && one.tooltip == (lang == "ru" ? "Авто: Codex → 15 мин" : "Auto: Codex → 15 min"), "C3-07 \(lang): only local enabled account highlighted")
        let off = remoteAutoFooter(views: [remote, local], enabled: ["claude"], intervals: ["codex": 900], language: lang)
        expect(off.noSubscriptions && off.products.isEmpty, "C3-07 disabled local poll never lights scale")
        local.data.auth = .loggedOut
        let signedOut = remoteAutoFooter(views: [remote, local], enabled: ["codex"], intervals: ["codex": 900], language: lang)
        expect(signedOut.noSubscriptions && signedOut.products.isEmpty, "C3-07 local account without sign-in never lights scale")

        // Visibility controls cards/history, not the enabled local provider poll.
        // Auto must receive frame.allViews even when frame.visibleViews hides that card.
        // This model regression does not call runtime displayAccountViews or preferences.
        let localId = "c3000000-1111-4222-8333-444455556666"
        let gist = "c3-synthetic-auto-gist"
        guard let key = accountLabelKey(gistId: gist),
              let hiddenLabel = accountLabel(product: "codex", localId: localId, labelKey: key) else {
            expect(false, "C3-07 hidden local label fixture valid"); continue
        }
        var cache = SyncRemoteCache(); cache.gistId = gist; cache.labelKey = key
        let localCodex = LimitData(session: 25, sessionReset: C3_NOW.addingTimeInterval(3600),
                                   asOf: C3_NOW, apiFresh: true)
        let sync = ReaderSyncState(phase: .on)
        let hiddenFrame = remoteAccountFrame(local: (c3Absent(), localCodex), localIds: ["codex": localId],
                                             remote: cache, hidden: [hiddenLabel], menu: [:], sync: sync, now: C3_NOW)
        let unfilteredFrame = remoteAccountFrame(local: (c3Absent(), localCodex), localIds: ["codex": localId],
                                                 remote: cache, hidden: [], menu: [:], sync: sync, now: C3_NOW)
        let visible = hiddenFrame.visibleViews, unfiltered = hiddenFrame.allViews
        expect(!visible.contains { $0.isLocal } && unfiltered.count == 1
               && unfilteredFrame.visibleViews.count == 1 && unfilteredFrame.allViews.count == 1
               && unfiltered.first?.isLocal == true && unfiltered.first?.label == hiddenLabel,
               "C3-07 hidden local Codex: visibility removes card; unfiltered resolver retains its polling identity")
        let hiddenAuto = remoteAutoFooter(views: unfiltered, enabled: ["codex"], intervals: ["codex": 900], language: lang)
        expect(!hiddenAuto.noSubscriptions && hiddenAuto.products == ["codex"]
               && hiddenAuto.tooltip == (lang == "ru" ? "Авто: Codex → 15 мин" : "Auto: Codex → 15 min"),
               "C3-07 \(lang): hidden enabled local Codex still drives Auto interval; never noSubscriptions")
    }
}

// C3-12 / review major 1: retrying local polling still owns its Auto interval.
private func c3C312(_ expect: C3Expect) {
    for product in ["claude", "codex"] {
        for auth in [AuthState.expired, .keychainError] {
            var local = c3View(product: product)
            local.isLocal = true; local.data.source = nil; local.data.auth = auth
            for lang in ["ru", "en"] {
                let footer = remoteAutoFooter(views: [local, c3View()], enabled: [product],
                                              intervals: [product: 14400], language: lang)
                let name = product == "claude" ? "Claude Code" : "Codex"
                let copy = (lang == "ru" ? "Авто: " : "Auto: ") + name + (lang == "ru" ? " → 4 ч" : " → 4 h")
                expect(!footer.noSubscriptions && footer.products == [product] && footer.tooltip == copy,
                       "C3-12 \(product)/\(auth)/\(lang): enabled retrying local account retains selected Auto interval")
                let off = remoteAutoFooter(views: [local], enabled: [], intervals: [product: 14400], language: lang)
                expect(off.noSubscriptions && off.products.isEmpty,
                       "C3-12 \(product)/\(auth)/\(lang): disabled polling remains excluded")
            }
        }
    }
}

// C3-13 / review major 2: a missing CLI login is present=true, not an account identity.
private func c3C313(_ expect: C3Expect) {
    var missingLogin = LimitData(present: true)
    missingLogin.auth = .loggedOut
    let cache = c3Cache(c3View())
    let sync = ReaderSyncState(phase: .on)
    let frame = remoteAccountFrame(local: (missingLogin, c3Absent()), localIds: [:], remote: cache,
                                   hidden: [], menu: [:], sync: sync, now: C3_NOW)
    expect(frame.allViews.count == 1 && frame.visibleViews.count == 1 && frame.displayedViews.count == 1,
           "C3-13 missing login and no local identity: exactly one VPS Claude card across frame projections")
    expect(frame.displayedViews.first?.isLocal == false && frame.displayedViews.first?.label == C3_LABEL
           && frame.displayedViews.first?.state == .fresh && frame.displayedViews.first?.data.session == 42.5,
           "C3-13 missing login never hides fresh VPS values behind local sign-in placeholder")

    // Known local identity remains an account, including its logged-out recovery state.
    let localId = "c3000000-1111-4222-8333-444455556666"
    let known = remoteAccountFrame(local: (missingLogin, c3Absent()), localIds: ["claude": localId], remote: cache,
                                   hidden: [], menu: [:], sync: sync, now: C3_NOW)
    expect(known.allViews.contains { $0.product == "claude" && $0.isLocal && $0.data.auth == .loggedOut }
           && known.displayedViews.count == 1 && known.displayedViews.first?.isLocal == true,
           "C3-13 known local identity retains its local card and default selection")
}

// C3-14 / UX B8: observe transitions through actual requests/completions, not enum fixtures.
private func c3C314(_ root: String, _ expect: C3Expect) {
    var now = C3_NOW
    var completions: [(Bool) -> Void] = []
    var changes = 0
    let controller = RemoteManualRefreshController(clock: { now }, read: { completions.append($0) },
                                                   onChange: { changes += 1 })
    func text(_ lang: String = "en") -> String {
        c3Presentation(c3View(), language: lang, now: now, manual: controller.phase(now: now)).statusLine
    }
    expect(text().isEmpty && controller.request() && completions.count == 1
           && text() == "Reading GitHub…" && text("ru") == "Читаем GitHub…" && changes > 0,
           "C3-14 request starts one injected read and publishes reading before its completion")
    guard completions.count == 1 else { return }
    now = C3_NOW.addingTimeInterval(1)
    completions[0](true)
    expect(text() == "GitHub checked 16:00" && text("ru") == "GitHub проверен 16:00",
           "C3-14 successful completion publishes checked using injected completion clock")
    now = C3_NOW.addingTimeInterval(18)
    expect(!controller.request() && completions.count == 1
           && text() == "Retry in 12 s" && text("ru") == "Повтор через 12 с",
           "C3-14 repeat inside thirty-second protection reads nothing and shows remaining seconds")
    now = C3_NOW.addingTimeInterval(29.1)
    expect(text() == "Retry in 1 s", "C3-14 fractional cooldown rounds remaining time up")
    now = C3_NOW.addingTimeInterval(30)
    expect(text() == "GitHub checked 16:00", "C3-14 thirty-second cooldown ends at its boundary")
    now = C3_NOW.addingTimeInterval(60.999)
    expect(text() == "GitHub checked 16:00", "C3-14 checked survives just under sixty seconds from completion")
    now = C3_NOW.addingTimeInterval(61)
    expect(text().isEmpty && text("ru").isEmpty, "C3-14 checked clears at exactly sixty seconds from completion")

    expect(controller.request() && completions.count == 2 && text() == "Reading GitHub…",
           "C3-14 expired protection permits a new read")
    guard completions.count == 2 else { return }
    // Completion from an older read must not overwrite the newer reading phase.
    completions[0](false)
    expect(text() == "Reading GitHub…", "C3-14 duplicate old completion cannot replace newer in-flight read")
    now = C3_NOW.addingTimeInterval(92)
    expect(!controller.request() && completions.count == 2 && text() == "Reading GitHub…",
           "C3-14 in-flight read blocks another request even after thirty seconds")
    completions[1](false)
    expect(text() == "GitHub didn't respond" && text("ru") == "GitHub не ответил",
           "C3-14 failed read publishes failure without a successful-check timestamp")
    completions[1](true)
    expect(text() == "GitHub didn't respond", "C3-14 read completion is one-shot")

    // Slow success: sixty seconds count from completion, not request start.
    now = C3_NOW.addingTimeInterval(93)
    expect(controller.request() && completions.count == 3, "C3-14 failed read can be retried after protection")
    guard completions.count == 3 else { return }
    now = C3_NOW.addingTimeInterval(183)
    completions[2](true)
    expect(text() == "GitHub checked 16:03", "C3-14 slow read records actual injected completion time")
    now = C3_NOW.addingTimeInterval(242.999)
    expect(text() == "GitHub checked 16:03", "C3-14 slow success retains checked for its full sixty seconds")
    now = C3_NOW.addingTimeInterval(243)
    expect(text().isEmpty, "C3-14 slow success expires at completion plus sixty seconds")
    let unchanged = c3Presentation(c3View(), language: "en", now: C3_NOW.addingTimeInterval(183),
                                   manual: .checked(C3_NOW.addingTimeInterval(183)))
    expect(unchanged.sourceLine == "Data from vps at 15:43",
           "C3-14 manual read result never changes snapshot source time")

    // The model used by the button must filter enabled provider polls by identity.
    let remote = c3View()
    expect(remoteManualProviderProducts(views: [remote], localIds: [:], enabled: ["claude"]).isEmpty,
           "C3-14 enabled remote-only Claude without local identity never enters provider poll set")
    expect(remoteManualProviderProducts(views: [remote], localIds: ["claude": "synthetic-local-id"], enabled: ["claude"]) == ["claude"],
           "C3-14 known local identity keeps its enabled provider poll")
    expect(remoteManualProviderProducts(views: [remote], localIds: ["claude": "synthetic-local-id"], enabled: []).isEmpty,
           "C3-14 known local identity never bypasses disabled polling")

    // Execute the shared read-only GitHub seam under an HTTP trap. No provider IO,
    // real credentials, singleton sync, refresh, UserDefaults.standard or journals.
    for succeeds in [true, false] {
        let gistId = "c3-synthetic-manual-gist"
        let gistURL = "https://api.github.com/gists/" + gistId
        let defaults = MemorySelfTestDefaults()
        defaults.set("selftest-login", forKey: "syncLogin")
        defaults.set(gistId, forKey: "syncGistId")
        // Discovery age must use the injected read clock as well; real Date()
        // would escape this fixture and is caught by the strict HTTP allowlist.
        defaults.set(C3_NOW, forKey: "syncDiscoveredAt")
        let file = """
        {"schema":1,"machine":{"id":"c3-vps","name":"vps","os":"T"},"updated":"2026-10-12T16:00:00Z","lastSeenAt":"2026-10-12T16:00:00Z","days":{},"accounts":[{"product":"claude","label":"c300000000000001","status":"ok","asOf":"2026-10-12T15:43:00Z","windows":{"session":{"pct":42.5,"resetAt":"2026-10-12T18:00:00Z"}},"schedule":{"mode":"auto","interval":3600,"nextAt":"2026-10-12T16:43:00Z"}}]}
        """
        let gist: [String: Any] = ["id": gistId, "public": false,
                                  "files": [SYNC_MANIFEST: ["content": "{}"], C3_FILE: ["content": file]]]
        guard let body = try? JSONSerialization.data(withJSONObject: gist) else {
            expect(false, "C3-14 synthetic gist serialization"); continue
        }
        let http = SelfTestHTTP { call in
            guard call.url == gistURL && call.method == "GET" else {
                return (599, nil, "selftest: unexpected HTTP/provider request blocked", [:])
            }
            return succeeds ? (200, body, nil, [:]) : (503, nil, "selftest: read failed", [:])
        }
        let keychain = SelfTestKeychainStore("c3-selftest-token")
        let sync = GitHubSync(transport: http.transport, keychain: ScriptedSyncKeychain(store: keychain),
                              defaults: defaults, remotePath: root + "/c3-manual-\(succeeds).json", machineId: "c3-mac",
                              revokeRecheckDelay: 0, clock: { C3_NOW })
        var readResult: Bool?
        let connected = RemoteManualRefreshController(clock: { C3_NOW }, read: { done in
            let result = sync.readSynchronously(); readResult = result; done(result)
        })
        let started = connected.request()
        let phase = c3Presentation(c3View(), language: "en", now: C3_NOW, manual: connected.phase(now: C3_NOW)).statusLine
        expect(started && readResult == succeeds
               && phase == (succeeds ? "GitHub checked 16:00" : "GitHub didn't respond"),
               "C3-14 injected GitHub read result drives actual controller phase (success=\(succeeds))")
        expect(http.calls.count == 1 && http.calls.allSatisfy { $0.url == gistURL && $0.method == "GET" },
               "C3-14 HTTP trap: one GitHub GET, zero provider requests and zero POST/PATCH (success=\(succeeds))")
        expect(keychain.writes == 0 && keychain.deletes == 0,
               "C3-14 read-only seam never changes even synthetic credentials (success=\(succeeds))")
        if succeeds {
            let remote = sync.remoteSnapshot()
            let frame = remoteAccountFrame(local: (c3Absent(), c3Absent()), localIds: [:], remote: remote,
                                           hidden: [], menu: [:], sync: ReaderSyncState(phase: .on), now: C3_NOW)
            expect(frame.displayedViews.count == 1 && frame.displayedViews.first?.isLocal == false
                   && frame.displayedViews.first?.data.asOf == c3Date("2026-10-12T15:43:00Z")
                   && frame.displayedViews.first?.data.session == 42.5,
                   "C3-14 successful manual read reaches remote-card resolver with original snapshot time/values")
        }
    }

    // No gist exists yet: a reader may discover it, but must never create/publish one.
    let discoveryURL = "https://api.github.com/gists?per_page=100&page=1"
    let defaults = MemorySelfTestDefaults()
    defaults.set("selftest-login", forKey: "syncLogin")
    let discovery = SelfTestHTTP { call in
        if call.url == discoveryURL && call.method == "GET" { return (200, Data("[]".utf8), nil, [:]) }
        return (599, nil, "selftest: read-only discovery attempted mutation/provider request", [:])
    }
    let keychain = SelfTestKeychainStore("c3-selftest-token")
    let noGist = GitHubSync(transport: discovery.transport, keychain: ScriptedSyncKeychain(store: keychain),
                            defaults: defaults, remotePath: root + "/c3-manual-no-gist.json", machineId: "c3-mac",
                            revokeRecheckDelay: 0, clock: { C3_NOW })
    expect(!noGist.readSynchronously() && defaults.string(forKey: "syncGistId") == nil,
           "C3-14 no gist: read fails without creating or selecting a new gist")
    expect(discovery.calls.count == 1 && discovery.calls.allSatisfy { $0.url == discoveryURL && $0.method == "GET" }
           && keychain.writes == 0 && keychain.deletes == 0,
           "C3-14 no gist: one discovery GET, zero provider/POST/PATCH/credential mutations")
}

private struct C3Malicious: Decodable { var name: String; var value: String }
// Conservative grep-style allowlist for RemoteLimits.swift: ONLY hash-byte
// String(format: "%02x", $0) / String(format: "%02x", byte) calls are allowed.
// Checking the complete call also rejects snapshot strings passed through "%@".
// This is intentionally stricter than general Swift formatting or taint analysis.
private func c3FormatViolations(_ source: String) -> [String] {
    let pattern = #"String\s*\(\s*format\s*:\s*"#
    let allowed = #"^"%02x"\s*,\s*(?:\$0|byte)\s*\)"#
    guard let re = try? NSRegularExpression(pattern: pattern),
          let whitelist = try? NSRegularExpression(pattern: allowed) else { return ["guard regex invalid"] }
    let ns = source as NSString
    return re.matches(in: source, range: NSRange(location: 0, length: ns.length)).compactMap { match in
        let tail = ns.substring(from: match.range.location + match.range.length) as NSString
        let range = NSRange(location: 0, length: tail.length)
        return whitelist.firstMatch(in: tail as String, range: range) == nil
            ? "String(format:) outside fixed hash-byte allowlist" : nil
    }
}
private func c3C311(_ expect: C3Expect) {
    guard var rows = c3Fixture("c3-malicious.json", as: [C3Malicious].self), rows.count == 6 else {
        expect(false, "C3-11 malicious vectors readable"); return
    }
    rows += [C3Malicious(name: "format-at", value: "%@%n"),
             C3Malicious(name: "email", value: "user@example.invalid"),
             C3Malicious(name: "slash", value: "folder/name"),
             C3Malicious(name: "backslash", value: "folder\\name"),
             C3Malicious(name: "nfkc-at", value: "user＠example.invalid"),
             C3Malicious(name: "nfkc-slash", value: "folder／name"),
             C3Malicious(name: "nfkc-backslash", value: "folder＼name"),
             C3Malicious(name: "marker-after-limit", value: String(repeating: "x", count: 40) + "@"),
             C3Malicious(name: "nfc", value: "e\u{301}quipe")]
    let cleaned = ["control": "helloworld", "bidi": "abcdef", "long": String(repeating: "x", count: 32), "nfc": "équipe"]
    let rejected: Set<String> = ["format-at", "file-url", "email", "slash", "backslash",
                                 "nfkc-at", "nfkc-slash", "nfkc-backslash", "marker-after-limit"]
    for g in rows {
        // A fixed machine name prevents a rejected caption from reappearing as
        // part of the default caption. os independently tests other wire text.
        let object: [String: Any] = ["schema": 1, "machine": ["id": "c3-vps", "name": "vps", "os": g.value], "updated": "2026-10-12T16:00:00Z", "lastSeenAt": "2026-10-12T16:00:00Z", "days": [String: Any](),
            "captions": [C3_LABEL: ["text": g.value]], "accounts": [["product": "claude", "label": C3_LABEL, "status": "ok", "asOf": "2026-10-12T15:43:00Z", "models": [["name": g.value, "pct": 10]], "windows": ["session": ["pct": 42.5, "resetAt": "2026-10-12T18:00:00Z"]]]]]
        guard let bytes = try? JSONSerialization.data(withJSONObject: object), let json = String(data: bytes, encoding: .utf8) else { expect(false, "C3-11 valid vector JSON"); continue }
        let cache = mergeV11([C3_FILE: json], excluding: "c3-mac", now: C3_NOW)
        guard let view = c3Resolve(cache, now: C3_NOW).first else { expect(false, "C3-11 malformed text preserves valid snapshot \(g.name)"); continue }
        let unsafe = g.name == "control" || g.name == "bidi" || g.name == "long"
        let p = c3Presentation(view)
        if rejected.contains(g.name) {
            let fallback = remoteDefaultCaption(view)
            expect(cache.captions?[C3_LABEL] == nil && view.caption == fallback
                   && p.simpleTitle == fallback && p.accessibilityLabel == fallback,
                   "C3-11 \(g.name): forbidden caption rejected whole; default title/AX shown")
        } else {
            let expected = cleaned[g.name] ?? g.value
            expect(cache.captions?[C3_LABEL]?.text == expected && view.caption == expected,
                   "C3-11 \(g.name): caption follows explicit C5 cleaning/NFC/scalar limit")
            expect(view.caption.unicodeScalars.count <= 32
                   && view.caption.unicodeScalars.map { $0.value } == view.caption.precomposedStringWithCanonicalMapping.unicodeScalars.map { $0.value }
                   && !view.caption.unicodeScalars.contains { [.control, .format, .surrogate, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory) },
                   "C3-11 \(g.name): shown caption is safe NFC text, no Cc/Cf/newlines, at most 32 scalars")
            expect(p.simpleTitle == expected && p.advancedTitle == expected && p.accessibilityLabel == expected,
                   "C3-11 \(g.name): accepted caption rendered literally in title/AX")
        }
        let models = cache.accounts?.first?.models ?? []
        expect(unsafe ? models.isEmpty && view.data.scoped == nil
                      : models.map { $0.name } == [g.value.precomposedStringWithCanonicalMapping]
                        && view.data.scoped?.name == g.value.precomposedStringWithCanonicalMapping,
               "C3-11 \(g.name): model names retain whole-field rejection, otherwise literal NFC")
        expect(cache.machines.first?.os == (unsafe ? "" : g.value),
               "C3-11 \(g.name): other wire strings retain whole-field rejection, never caption cleaning")
        expect(p.cardHit == "open:https://claude.ai/settings/usage" && !limitCanFix(remote: view), "C3-11 \(g.name): malicious text never changes hit")
        // Keep the original hostile machine-name coverage independently of
        // caption rejection/default selection. Tags have their own 16-scalar cap.
        var machineObject = object
        machineObject["captions"] = [String: Any]()
        machineObject["machine"] = ["id": "c3-vps", "name": g.value]
        guard let machineBytes = try? JSONSerialization.data(withJSONObject: machineObject) else {
            expect(false, "C3-11 machine-name vector JSON"); continue
        }
        let machineCache = mergeV11([C3_FILE: String(decoding: machineBytes, as: UTF8.self)], excluding: "c3-mac", now: C3_NOW)
        let tag = g.name == "control" || g.name == "bidi" ? "?" : String(String.UnicodeScalarView(g.value.unicodeScalars.prefix(16)))
        expect(machineCache.machines.first?.name == tag,
               "C3-11 \(g.name): machine name rejects controls whole, otherwise retains its existing 16-scalar tag cap")
        expect(c3Resolve(machineCache, now: C3_NOW).first.map { c3Presentation($0).cardHit } == "open:https://claude.ai/settings/usage",
               "C3-11 \(g.name): hostile machine name cannot select a destination")
    }
    let forbiddenArguments = ["String(format: caption, 1)", "String (format : model.name)",
                              "String(format: \"%@\", caption)", "String(format: \"%@\", model.name)",
                              "String(format: \"%02x\", byte, caption)", "String(format: \"%02x\", model.name)"]
    expect(forbiddenArguments.allSatisfy { c3FormatViolations($0).count == 1 },
           "C3-11 grep guard rejects snapshot strings in format AND value arguments")
    expect(c3FormatViolations("String(format: \"%02x\", byte)").isEmpty
           && c3FormatViolations("String(format: \"%02x\", $0)").isEmpty,
           "C3-11 grep guard permits only fixed hash-byte calls")
    let interpolated = "String(format: \"%." + "\\" + "(caption)f\", n)"
    expect(c3FormatViolations(interpolated).count == 1, "C3-11 grep guard rejects interpolated format string")
    if let dir = remoteLimitsFixturesDir(), let source = try? String(contentsOfFile: dir + "/../../Sources/RemoteLimits.swift", encoding: .utf8) {
        expect(c3FormatViolations(source).isEmpty, "C3-11 actual RemoteLimits.swift: every String(format:) is fixed %02x plus scalar byte")
    } else {
        // Installed .app may ship fixtures without repository sources. Explicit finite
        // forbidden list, NOT represented as coverage of the current product source.
        let forbidden = ["String(format: caption)", "String(format: view.caption)", "String(format: model.name)", "String(format: machine.name)", "String(format: source.machineName)", "String(format: \"%@\", caption)", "String(format: \"%@\", model.name)"]
        expect(forbidden.allSatisfy { !c3FormatViolations($0).isEmpty }, "C3-11 source unavailable: ONLY fixed forbidden-list fallback checked; repository scan NOT RUN")
    }
    expect(machineTag(setting: "MacBook Pro — Алекс", hostname: "ignored.synthetic") == "macbook-pro", "C3-11 Т13: machine tag excludes non-ASCII personal suffix")
}

func runRemoteLimitsC3SelfTests() -> Int {
    var failures = 0, checks = 0
    func expect(_ ok: Bool, _ message: String) { checks += 1; if !ok { failures += 1 }; print("\(ok ? "OK" : "FAIL") \(message)") }
    let root = NSTemporaryDirectory() + "ccl-c3-selftest-" + UUID().uuidString
    do { try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true) }
    catch { print("FAIL C3 temp directory creation"); return 1 }
    defer { try? FileManager.default.removeItem(atPath: root) }
    c3C301(expect); c3C302(expect); c3C303(root, expect); c3C304(expect); c3C305(expect); c3C307(expect); c3C311(expect); c3C312(expect); c3C313(expect); c3C314(root, expect)
    print("\(failures == 0 ? "OK" : "FAIL") C3 model tests: \(checks) checks; \(failures) failures")
    return failures
}
