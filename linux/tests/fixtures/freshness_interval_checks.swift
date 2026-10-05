func owner(auto: Bool) -> ReplayOwner {
    UserDefaults.standard.set(auto, forKey: "autoPoll")
    let o = ReplayOwner()
    var failed = AutoPollState(); failed.interval = 14400; failed.lastAttempt = fixedNow; failed.failed = true
    o.autoStates = ["codex": failed]
    o.startTimer()
    o.render(LimitData(present: false), reading(60, weeklyOnly: true))
    return o
}
for (initialAuto, selection, delay) in [(true, 900.0, 900.0), (false, 3600.0, 3600.0), (false, 0.0, 14400.0)] {
    let o = owner(auto: initialAuto)
    o.setInterval(selection)
    check(o.panelCtrl.view.codex.nextPollAt == date(fixedNow + delay), "actual handler retry deadline Auto/Fixed transition")
    check(o.last?.1.nextPollAt == date(fixedNow + delay), "canonical last synchronized with new schedule")
    check(o.panelCtrl.view.codex.asOf == date(fixedNow - 60) && o.panelCtrl.view.codex.weekly == 47, "interval change preserves observation")
    check(o.panelCtrl.view.codex.pollFailed, "interval change preserves failure")
    o.statusClicked() // actual reopen body reads canonical last
    check(o.panelCtrl.isVisible, "actual reopen branch reached")
    check(o.panelCtrl.view.codex.nextPollAt == date(fixedNow + delay), "reopen preserves current retry deadline")
    o.statusClicked(); o.statusClicked()
    check(o.panelCtrl.view.codex.nextPollAt == date(fixedNow + delay), "second reopen cannot resurrect old deadline")
}
