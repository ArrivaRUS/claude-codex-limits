// Contract harness: linked only to an audited whitelist, never app entry points.
let fixedNow = 1_700_000_000.0
func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }
var checks = 0, failures = 0
func check(_ value: @autoclosure () -> Bool, _ label: String) {
    checks += 1
    if !value() { failures += 1; print("FAIL: \(label)") }
}
func close(_ a: Double?, _ b: Double) -> Bool { a.map { abs($0 - b) < 0.000001 } ?? false }
func reading(_ age: Double = 60, weeklyOnly: Bool = false) -> LimitData {
    let at = fixedNow - age
    return LimitData(session: weeklyOnly ? nil : 31, weekly: 47,
                     sessionReset: weeklyOnly ? nil : date(at + 4.5 * 3600),
                     weeklyReset: date(at + 84 * 3600), asOf: date(at))
}
for (age, stale) in [(14399.0, false), (14400.0, false), (14401.0, true)] {
    for weeklyOnly in [false, true] {
        var d = reading(age, weeklyOnly: weeklyOnly)
        for error in [nil, "offline fixture"] as [String?] {
            d.error = error
            check(isStale(d, date(fixedNow)) == stale, "inclusive 4h age=\(age) weeklyOnly=\(weeklyOnly) failed=\(error != nil)")
        }
    }
}
for metric in ["session", "weekly", "model"] {
    for (delta, expired) in [(1.0, false), (0.0, true), (-1.0, true)] {
        var d = reading()
        d.scoped = ScopedLimit(name: "fixture-model", percent: 25, reset: d.weeklyReset)
        if metric == "session" { d.sessionReset = date(fixedNow + delta) }
        if metric == "weekly" { d.weeklyReset = date(fixedNow + delta) }
        if metric == "model" { d.scoped?.reset = date(fixedNow + delta) }
        check(metricIsStale(d, metric: metric, now: date(fixedNow)) == expired, "\(metric) reset delta=\(delta)")
        check(!isStale(d, date(fixedNow)), "one reset keeps valid companion visible")
    }
}
let old = reading(3600, weeklyOnly: true)
let pace = pacedLimits(old, product: "codex")
check(pace.map { $0.id } == ["weekly"], "weekly-only no invented session")
check(close(pace.first?.pace?.planPct, 50), "historical plan uses asOf")
check(close(pace.first?.pace?.projectedPct, 94), "historical forecast uses asOf")
for at in [nil, date(Double.nan), date(Double.infinity)] as [Date?] {
    var d = reading(); d.asOf = at
    check(isStale(d, date(fixedNow)), "missing/invalid observation stale")
    check(pacedLimits(d, product: "codex").allSatisfy { $0.pace == nil }, "no fabricated pace")
}
var future = reading(); future.asOf = date(fixedNow + 1)
check(isStale(future, date(fixedNow)), "future observation stale")
for reset in [nil, old.asOf, date(fixedNow - 3601), date(fixedNow - 3600 + 5 * 3600 + 1)] as [Date?] {
    check(snapshotWindowPace(used: 31, reset: reset, windowH: 5, asOf: old.asOf) == nil, "unknown/impossible timing no projection")
}
let history = UsageHistory()
var first = reading(); first.asOf = date(fixedNow - 1800); first.weekly = 40
var second = reading(); second.asOf = date(fixedNow - 900); second.weekly = 47
history.record(first, product: "codex"); history.record(second, product: "codex")
let samples = history.samples("codex", since: date(fixedNow - 2000)) // queue barrier drains writes
check(samples.map { $0.t } == [fixedNow - 1800, fixedNow - 900], "record timestamps exactly asOf")
check(close(history.recentRate("codex", metric: { $0.weekly }, minutes: 180, now: second.asOf!), 28), "newest record included at asOf cutoff")
history.record(second, product: "codex"); history.record(first, product: "codex")
check(history.samples("codex", since: date(fixedNow - 2000)).count == 2, "duplicate/out-of-order records not new observations")
let disk = try! String(contentsOfFile: HISTORY_PATH, encoding: .utf8).split(separator: "\n").map {
    try! JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
}
check(disk.compactMap { $0["t"] as? Double } == [fixedNow - 1800, fixedNow - 900], "disk timestamps exactly asOf")
var failedRecord = reading(); failedRecord.pollFailed = true
history.record(failedRecord, product: "codex")
check(history.samples("codex", since: date(fixedNow - 2000)).count == 2, "failed fallback not recorded")
let late = UsageSample(t: fixedNow, product: "codex", session: nil, weekly: 99, scoped: nil, scopedName: nil, sessionReset: nil, weeklyReset: nil)
let known = UsageSample(t: fixedNow - 900, product: "codex", session: nil, weekly: 47, scoped: nil, scopedName: nil, sessionReset: nil, weeklyReset: nil)
let previous = UsageSample(t: fixedNow - 1800, product: "codex", session: nil, weekly: 40, scoped: nil, scopedName: nil, sessionReset: nil, weeklyReset: nil)
UsageHistory.shared.useForPreview([previous, known, late])
check(close(pacedLimits(second, product: "codex").last?.pace?.recentRatePerH, 28), "historical pace excludes later observation")
var state = AutoPollState(); state.interval = 14400; state.lastAttempt = fixedNow
check(!state.due(fixedNow + 14399), "not due before 4h")
check(state.due(fixedNow + 14400), "due at 4h deadline")
check(state.due(fixedNow + 14401), "due after 4h deadline")
state.failed = true
check(!state.due(fixedNow + 900, manual: true), "manual cannot bypass failed backoff")
check(!state.localActivity([fixedNow+10, fixedNow+20, fixedNow+30], now: fixedNow+40), "activity cannot bypass failed backoff")
var error = reading(); error.error = "offline fixture"
state = AutoPollState(); state.interval = 900
for expected in [1800.0, 3600.0, 14400.0, 14400.0] {
    state.begin(fixedNow); state.observe(error, now: fixedNow + 30)
    check(state.interval == expected && state.failed, "backoff progresses and caps")
    check(!state.due(fixedNow + 30 + expected - 1, manual: true), "response duration included in floor")
    check(state.due(fixedNow + 30 + expected, manual: true), "due exactly after backoff")
}
var liveWeek = reading(0, weeklyOnly: true); liveWeek.apiFresh = true
state.begin(fixedNow); state.observe(liveWeek, now: fixedNow)
check(!state.failed, "weekly-only live recovers backoff")
let restored = try! JSONDecoder().decode(AutoPollState.self, from: JSONEncoder().encode(state))
check(restored.lastAttempt == fixedNow && restored.interval == state.interval, "saved deadline survives restart")
for cached in [false, true] {
    fakeRollout = reading(8000, weeklyOnly: true)
    fakeCache = cached ? reading(7200, weeklyOnly: true) : nil
    fakeLive = nil; liveCalls = 0
    let fallback = fetchCodex(live: true)
    check(liveCalls == 1, "failed live attempt actually made through fake boundary")
    check(fallback.weekly == 47 && fallback.asOf == (cached ? fakeCache?.asOf : fakeRollout.asOf), "fallback preserves newest snapshot")
    var polling = AutoPollState(); polling.interval = 900; polling.begin(fixedNow)
    polling.observe(fallback, now: fixedNow + 10)
    let published = withPollStatus(fallback, state: polling, next: date(polling.lastAttempt + polling.interval))
    check(published.pollFailed && polling.failed && polling.interval == 1800, "failed live survives observe to UI status")
    check(published.nextPollAt == date(fixedNow + 1810), "retry deadline includes request duration")
    check(!isStale(published, date(fixedNow)), "failed attempt does not stale valid snapshot")
    let serialized = ld2dict(published)
    check(serialized["pollFailed"] == nil && serialized["nextPollAt"] == nil, "transient status not stored with snapshot")
    var healthy = reading(0, weeklyOnly: true); healthy.apiFresh = true
    polling.begin(fixedNow); polling.observe(healthy, now: fixedNow)
    let recovered = withPollStatus(healthy, state: polling, next: date(fixedNow + 14400))
    check(!recovered.pollFailed && recovered.nextPollAt == nil, "successful live clears retry status")
}
liveCalls = 0
_ = fetchCodex(live: false)
check(liveCalls == 0, "offline only never invokes live fake boundary")
print("FRESH-4H Swift whitelist harness: \(checks) checks, \(failures) failures")
exit(failures == 0 ? 0 : 1)
