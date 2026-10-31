import Foundation

// C5 — written RED before implementation, 2026-10-31.
// Requirements: test-plan C5-01/02; plans C5; UX §2/§9.3; protocol captions,
// latest-setAt and text safety; C5 scope D4b/D5/D6 agreed with coordinator.
// Isolation 006/011/013: pure models only, explicit clocks and fake waits. The
// sole file read is the shared golden fixture. Only RAM-backed test defaults; no credentials,
// Keychain helpers, network, real timers, AppKit initialization or user logs.
// The settings-height vectors have lastError=nil, avoiding CoreText measuring.
// These checks do not establish actual system-prompt lifetime or native UI fit.
// New contracts (no production stand-ins are defined here):
// remoteCaptionValidatedInput(_:english:) -> { value:String, error:String? }
// remoteCaptionRecord(_:at:english:) -> RemoteCaption? (empty = reset tombstone)
// remoteCaptionMerge(local:remote:now:) -> [String:RemoteCaption]
// githubKeychainTimeoutSeconds(interactive:) -> Double (120 / 15)
// githubKeychainWait(timeout:now:waits:[(Double)->Bool]) -> Bool
// syncShowsKeychainRetry(_ issue:String?) -> Bool
// remoteSimpleHeaderLayout(availableWidth:measuredLabelWidth:measuredValueWidth:)
//   -> (labelWidth:Double,valueWidth:Double,gap:Double,wrapsValue:Bool)

private typealias C5Check = (Bool, String) -> Void
private let C5_NOW = Date(timeIntervalSince1970: 1_793_462_400) // 2026-10-31 16:00 UTC
private let C5_LABEL = "3f9a0c71b2d4e5f6"
private func c5ISO(_ text: String) -> Date? { ISO8601DateFormatter().date(from: text) }
private func c5CaptionEqual(_ a: RemoteCaption?, _ b: RemoteCaption?) -> Bool {
    a?.text == b?.text && a?.setAt == b?.setAt
}
private func c5MapEqual(_ a: [String: RemoteCaption], _ b: [String: RemoteCaption]) -> Bool {
    Set(a.keys) == Set(b.keys) && a.allSatisfy { c5CaptionEqual($0.value, b[$0.key]) }
}

private func c5C501(_ check: C5Check) {
    guard let dir = remoteLimitsFixturesDir(),
          let data = FileManager.default.contents(atPath: dir + "/captions-c5.json"),
          let fixture = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let nowISO = fixture["now"] as? String, let now = c5ISO(nowISO),
          let label = fixture["label"] as? String,
          let cases = fixture["cases"] as? [[String: Any]], !cases.isEmpty else {
        check(false, "C5-01 shared captions-c5.json is readable and contains cases"); return
    }
    var ids = Set<String>()
    for vector in cases {
        let id = vector["id"] as? String ?? "missing-id"; ids.insert(id)
        guard let machines = vector["machines"] as? [[String: Any]], machines.count == 2,
              let expected = vector["expected"] as? [String: Any],
              let text = expected["text"] as? String, let iso = expected["setAt"] as? String,
              let at = c5ISO(iso) else {
            check(false, "C5-01 \(id): two machines and explicit golden text/setAt"); continue
        }
        var contents: [String: String] = [:], maps: [[String: RemoteCaption]] = []
        for (index, machine) in machines.enumerated() {
            guard let body = try? JSONSerialization.data(withJSONObject: machine, options: [.sortedKeys]),
                  let raw = (machine["captions"] as? [String: [String: Any]])?[label],
                  let rawText = raw["text"] as? String, let rawISO = raw["setAt"] as? String,
                  let rawAt = c5ISO(rawISO) else {
                check(false, "C5-01 \(id)/\(index): valid golden machine envelope"); continue
            }
            let identity = (machine["machine"] as? [String: Any])?["id"] as? String ?? String(index)
            contents["machine-\(identity).json"] = String(decoding: body, as: UTF8.self)
            maps.append([label: RemoteCaption(text: rawText, setAt: rawAt)])
        }
        guard maps.count == 2 else { continue }
        let want = RemoteCaption(text: text, setAt: at)
        for (left, right) in [(maps[0], maps[1]), (maps[1], maps[0])] {
            let merged = remoteCaptionMerge(local: left, remote: right, now: now)
            check(c5CaptionEqual(merged[label], want), "C5-01 \(id): latest setAt wins in both machine directions")
            check(c5MapEqual(remoteCaptionMerge(local: merged, remote: right, now: now), merged),
                  "C5-01 \(id): replaying an older record is idempotent, including reset")
        }
        let cache = mergeV11(contents, excluding: "not-a-fixture-machine", now: now)
        check(c5CaptionEqual(cache.captions?[label], want), "C5-01 \(id): real wire reader agrees with golden merge")
        for own in machines {
            guard let ownID = (own["machine"] as? [String: Any])?["id"] as? String,
                  var accounts = own["accounts"] as? [[String: Any]], !accounts.isEmpty else {
                check(false, "C5-01 \(id): own-file parity fixture has an identity and account"); continue
            }
            var ownEnvelope = own, withOwnUsage = contents
            let usage: [String: Any] = ["2026-10-31": ["fixture": ["input": 7]]]
            accounts[0]["days"] = usage; ownEnvelope["accounts"] = accounts
            ownEnvelope["days"] = ["claude": usage]
            guard let bytes = try? JSONSerialization.data(withJSONObject: ownEnvelope, options: [.sortedKeys]) else {
                check(false, "C5-01 \(id): own-file parity envelope encodes"); continue
            }
            withOwnUsage["machine-\(ownID).json"] = String(decoding: bytes, as: UTF8.self)
            let withoutOwn = mergeV11(withOwnUsage, excluding: ownID, now: now)
            check(c5CaptionEqual(withoutOwn.captions?[label], want),
                  "C5-01 \(id)/\(ownID): own-file caption still participates in latest-setAt merge")
            check(withoutOwn.days.isEmpty && !withoutOwn.machines.contains { $0.id == ownID }
                  && !(withoutOwn.accounts ?? []).contains { $0.machineId == ownID },
                  "C5-01 own-file caption participation does not import own usage, account or machine")
        }
        let views = resolveAccounts(local: (LimitData(), LimitData()), localIds: [:], remote: cache,
            hidden: [], menu: [:], sync: ReaderSyncState(phase: .on), now: now)
        guard let view = views.first(where: { $0.label == label }) else {
            check(false, "C5-01 \(id): golden account reaches resolver"); continue
        }
        check(text.isEmpty ? view.caption == remoteDefaultCaption(view) && !view.caption.isEmpty : view.caption == text,
              "C5-01 \(id): custom text displays; newer empty tombstone restores default")
    }
    check(ids.contains("latest-mac") && ids.contains("reset"), "C5-01 golden covers latest Mac caption and Linux reset")

    let old = now.addingTimeInterval(-60), newer = now.addingTimeInterval(-30)
    let a = [C5_LABEL: RemoteCaption(text: "А", setAt: old)]
    let b = [C5_LABEL: RemoteCaption(text: "Б", setAt: old)]
    let ab = remoteCaptionMerge(local: a, remote: b, now: now)
    check(c5MapEqual(ab, remoteCaptionMerge(local: b, remote: a, now: now)) && ab[C5_LABEL]?.text == "Б",
          "C5-01 equal timestamps converge by Unicode-scalar lexical max, independent of read order")
    let legacy = [C5_LABEL: RemoteCaption(text: "Я legacy", setAt: nil)]
    check(remoteCaptionMerge(local: legacy, remote: a, now: now)[C5_LABEL]?.text == "А"
          && remoteCaptionMerge(local: a, remote: legacy, now: now)[C5_LABEL]?.text == "А",
          "C5-01 valid setAt outranks a legacy nil timestamp in both directions")
    let unrelated = "0000000000000001"
    let combined = remoteCaptionMerge(local: a, remote: [unrelated: RemoteCaption(text: "Other", setAt: newer)], now: now)
    check(combined.count == 2 && combined[C5_LABEL]?.text == "А" && combined[unrelated]?.text == "Other",
          "C5-01 merging captions preserves unrelated labels")
    let bmp = [label: RemoteCaption(text: "\u{FFFD}", setAt: old)]
    let astral = [label: RemoteCaption(text: "🚀", setAt: old)]
    check(remoteCaptionMerge(local: bmp, remote: astral, now: now)[label]?.text == "🚀"
          && remoteCaptionMerge(local: astral, remote: bmp, now: now)[label]?.text == "🚀",
          "C5-01 same-time convergence uses Unicode scalar order, not UTF-16 order")
    let ceiling = [label: RemoteCaption(text: "accepted", setAt: now.addingTimeInterval(60))]
    let future = [label: RemoteCaption(text: "future", setAt: now.addingTimeInterval(61))]
    check(remoteCaptionMerge(local: ceiling, remote: future, now: now)[label]?.text == "accepted",
          "C5-01 future setAt beyond the 60-second allowance cannot win")
    c5C501Publication(check)
}

// Reviewer P1: grapheme-cluster iteration missed decorated separators. Every
// scalar below remains forbidden, including compatibility forms and suffixes
// beyond the 32-scalar limit. Exercise input and own/foreign wire paths.
private func c5DecoratedSeparators() -> [String] {
    var values: [String] = []
    for separator in ["@", "/", "\\", "＠", "／", "＼"] {
        for mark in ["\u{301}", "\u{FE0F}"] {
            for prefix in ["x", String(repeating: "a", count: 33)] {
                values.append(prefix + separator + mark + "suffix")
            }
        }
    }
    return values
}

private func c5C501Sanitization(_ check: C5Check) {
    var vectors: [(String, String?)] = [
        ("A\nB\r\tC", "ABC"), ("A\u{0}\u{202E}\u{200B}B", "AB"),
        ("A\u{2028}B\u{2029}C", "ABC"), ("e\u{301}", "é"),
        (String(repeating: "e\u{301}", count: 33), String(repeating: "é", count: 32)),
        (String(repeating: "🙂", count: 33), String(repeating: "🙂", count: 32)),
        ("user@example.invalid", nil), ("path/name", nil), ("path\\name", nil),
        ("user＠host", nil), ("path／name", nil), ("path＼name", nil),
        (String(repeating: "a", count: 33) + "@suffix", nil), ("", "")
    ]
    for raw in c5DecoratedSeparators() { vectors.append((raw, nil)) }
    let stamp = ISO8601DateFormatter().string(from: C5_NOW)
    for (index, vector) in vectors.enumerated() {
        let object: [String: Any] = ["schema": 1, "machine": ["id": "c5-hostile", "name": "fixture"],
            "updated": stamp, "days": [String: Any](),
            "captions": [C5_LABEL: ["text": vector.0, "setAt": stamp]]]
        guard let bytes = try? JSONSerialization.data(withJSONObject: object) else {
            check(false, "C5-01 hostile wire fixture encodes"); continue
        }
        let contents = ["machine-c5-hostile.json": String(decoding: bytes, as: UTF8.self)]
        for excluding in ["other", "c5-hostile"] {
            let cache = mergeV11(contents, excluding: excluding, now: C5_NOW)
            check(cache.captions?[C5_LABEL]?.text == vector.1,
                  "C5-01 hostile wire \(index): own/foreign reader cleans NFC/Cc/Cf/length and rejects separators whole")
        }
    }
}

private final class C5KeychainTrap: SyncKeychain {
    var calls = 0
    func read() -> SyncKeychainRead { calls += 1; return .failure(-1) }
    func write(_ token: String) -> SyncKeychainStatus { calls += 1; return .failure(-1) }
    func delete() -> SyncKeychainStatus { calls += 1; return .failure(-1) }
}

private func c5C501Publication(_ check: C5Check) {
    let defaults = MemorySelfTestDefaults(), keychain = C5KeychainTrap()
    defaults.set(false, forKey: "monitor_claude"); defaults.set(false, forKey: "monitor_codex")
    defaults.set("fixturegist0000000000000000000001", forKey: "syncGistId")
    defaults.set("fixture-mac", forKey: "machineName")
    let at = "2026-10-31T15:00:00Z", later = "2026-10-31T15:30:00Z"
    defaults.set([C5_LABEL: ["text": "Команда", "setAt": at]], forKey: "localAccountCaptions")
    check(localAccountCaptions(defaults: defaults)[C5_LABEL]?.text == "Команда"
          && localAccountCaptions(defaults: defaults)[C5_LABEL]?.setAt == c5ISO(at),
          "C5-01 persisted dictionary decodes text and ISO setAt from injected defaults")
    var httpCalls = 0, snapshots = 0
    let sync = GitHubSync(transport: { _, _, _, _, _ in
        httpCalls += 1; return (0, nil, "C5 offline transport trap", [:])
    }, keychain: keychain, defaults: defaults,
       remotePath: NSTemporaryDirectory() + "ccl-c5-unused-" + UUID().uuidString + "/remote.json",
       machineId: "c5-publisher", clock: { C5_NOW }, publisherSnapshot: {
        snapshots += 1
        return C4PublisherSnapshot(days: [:], accountByDay: [:], localId: nil,
            codex: LimitData(present: false), poll: AutoPollState())
    })
    func file() -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(sync.selfTestFile().utf8))) as? [String: Any] ?? [:]
    }
    let first = file(), firstHash = c4Fingerprints(first)
    let published = (first["captions"] as? [String: [String: Any]])?[C5_LABEL]
    check(published?["text"] as? String == "Команда" && published?["setAt"] as? String == at,
          "C5-01 actual machineFile publishes persisted caption and its original setAt")
    defaults.set([C5_LABEL: ["text": "Работа", "setAt": later]], forKey: "localAccountCaptions")
    let renamed = file(), renameHash = c4Fingerprints(renamed)
    check(firstHash.push == renameHash.push && firstHash.meta != renameHash.meta,
          "C5-01 rename changes metaHash, never the usage-only pushHash")
    defaults.set([C5_LABEL: ["text": "", "setAt": later]], forKey: "localAccountCaptions")
    let reset = file(), resetHash = c4Fingerprints(reset)
    let tombstone = (reset["captions"] as? [String: [String: Any]])?[C5_LABEL]
    check(tombstone?["text"] as? String == "" && tombstone?["setAt"] as? String == later
          && resetHash.push == renameHash.push && resetHash.meta != renameHash.meta,
          "C5-01 actual publication retains reset tombstone and changes only metadata fingerprint")
    defaults.set([C5_LABEL: "Legacy"], forKey: "localAccountCaptions")
    let legacy = localAccountCaptions(defaults: defaults)[C5_LABEL]
    check(legacy?.text == "Legacy" && legacy?.setAt == Date(timeIntervalSince1970: 0),
          "C5-01 legacy string caption gains a deterministic epoch timestamp in memory")
    check(httpCalls == 0 && keychain.calls == 0 && snapshots == 3,
          "C5-01 actual publication uses injected snapshot with zero HTTP or credential operations")
}

private func c5C502(_ check: C5Check) {
    for text in [String(repeating: "Я", count: 32), String(repeating: "🙂", count: 32)] {
        let bounded = remoteCaptionValidatedInput(text + "X")
        check(bounded.value == text && bounded.error == nil && bounded.value.unicodeScalars.count == 32,
              "C5-02 33rd scalar is excluded without rejecting a valid 32-scalar caption")
    }
    let composedBoundary = remoteCaptionValidatedInput(String(repeating: "e\u{301}", count: 33))
    check(composedBoundary.value == String(repeating: "é", count: 32) && composedBoundary.error == nil,
          "C5-02 NFC normalization precedes the 32-scalar limit")
    for (raw, clean) in [("e\u{301}", "é"), ("A\nB\r\tC", "ABC"),
                         ("A\u{0}\u{1B}\u{7F}\u{85}B", "AB"),
                         ("A\u{200B}\u{202E}\u{2066}B", "AB"), ("A\u{2028}B\u{2029}C", "ABC")] {
        let result = remoteCaptionValidatedInput(raw)
        check(result.value == clean && result.error == nil && remoteCaptionInput(raw) == clean,
              "C5-02 newline/Cc/Cf removal and NFC agree with existing editor")
    }
    let forbidden = ["user@example.invalid", "path/name", "path\\name", "user＠host", "path／name", "path＼name",
                     String(repeating: "a", count: 33) + "@suffix"] + c5DecoratedSeparators()
    for raw in forbidden {
        for english in [false, true] {
            let result = remoteCaptionValidatedInput(raw, english: english)
            check(result.value.isEmpty && !(result.error ?? "").isEmpty,
                  "C5-02 forbidden ASCII/fullwidth separators reject whole input before truncation with visible error")
            check(remoteCaptionRecord(raw, at: C5_NOW, english: english) == nil,
                  "C5-02 forbidden input cannot produce a published record or reset")
        }
        let edit = remoteCaptionEdit(original: "Original", draft: raw, command: .enter)
        check(!edit.committed && edit.value == "Original", "C5-02 rejected Enter preserves previous caption")
    }
    for raw in ["", "  "] {
        let result = remoteCaptionValidatedInput(raw)
        let record = remoteCaptionRecord(raw, at: C5_NOW)
        check(result.error == nil && record?.text == "" && record?.setAt == C5_NOW,
              "C5-02 empty/whitespace save publishes a dated reset tombstone")
    }
    let saved = remoteCaptionRecord("e\u{301}", at: C5_NOW)
    check(saved?.text == "é" && saved?.setAt == C5_NOW, "C5-02 committed record stores normalized text and injected time")
    let enter = remoteCaptionEdit(original: "Original", draft: "Команда %n", command: .enter)
    check(enter.committed && enter.value == "Команда %n" && enter.count == 10,
          "C5-02 Enter commits safe literal percent text with matching scalar counter")
    let escape = remoteCaptionEdit(original: "Original", draft: "Changed", command: .escape)
    check(!escape.committed && escape.value == "Original" && escape.text == "Original",
          "C5-02 Escape discards draft without a write")
    for command in [RemoteCaptionCommand.enter, .reset] {
        let reset = remoteCaptionEdit(original: "Original", draft: command == .reset ? "ignored" : "", command: command)
        check(reset.committed && reset.value == nil && reset.text.isEmpty && reset.count == 0,
              "C5-02 Reset and empty Enter restore default and clear counter")
    }
}

private func c5C503(_ check: C5Check) {
    check(githubKeychainTimeoutSeconds(interactive: true) == 120
          && githubKeychainTimeoutSeconds(interactive: false) == 15,
          "C5-03 explicit Keychain action gets 120 seconds; background retains 15")
    for (interactive, elapsed, succeeds) in [(true, 119.0, true), (true, 121.0, false),
                                            (false, 14.0, true), (false, 16.0, false)] {
        var clock = 1000.0, budgets: [Double] = []
        let timeout = githubKeychainTimeoutSeconds(interactive: interactive)
        let result = githubKeychainWait(timeout: timeout, now: { clock }, waits: [{ budget in
            budgets.append(budget); clock += min(elapsed, budget); return elapsed <= budget
        }])
        check(result == succeeds && budgets == [timeout],
              "C5-03 injected timer bounds interactive=\(interactive) elapsed=\(elapsed) without wall-clock waits")
    }
    var clock = 1000.0, budgets: [Double] = []
    let completed = githubKeychainWait(timeout: 120, now: { clock }, waits: [
        { remaining in budgets.append(remaining); clock += 50; return true },
        { remaining in budgets.append(remaining); clock += 69; return true }
    ])
    check(completed && budgets == [120, 70] && clock == 1119,
          "C5-03 process exit and output drain share one 120-second deadline")
    clock = 1000; budgets = []
    var unexpectedStage = 0
    let expired = githubKeychainWait(timeout: 120, now: { clock }, waits: [
        { remaining in budgets.append(remaining); clock += 119; return true },
        { remaining in budgets.append(remaining); clock += remaining; return false },
        { _ in unexpectedStage += 1; return true }
    ])
    check(!expired && budgets == [120, 1] && clock == 1120 && unexpectedStage == 0,
          "C5-03 drain receives only remaining second and timeout prevents later stages")
    clock = 1000
    let lateSuccess = githubKeychainWait(timeout: 120, now: { clock }, waits: [{ _ in clock += 121; return true }])
    check(!lateSuccess, "C5-03 a wait reporting success after the common deadline is still a timeout")
    for timeout in [0.0, -1.0] {
        var calls = 0
        let result = githubKeychainWait(timeout: timeout, now: { 1000 }, waits: [{ _ in calls += 1; return true }])
        check(!result && calls == 0, "C5-03 exhausted deadline cannot start an operation")
    }
}

private func c5C504(_ check: C5Check) {
    for issue in ["locked", "unreachable", "timeout"] {
        check(syncShowsKeychainRetry(issue), "C5-04 retry visible for \(issue)")
        for phase in [SyncPhase.off, .on, .revoked, .awaitingCode] {
            var plain = SyncUIState(); plain.phase = phase
            var failed = plain; failed.authReason = issue
            check(failed.canRetryKeychain && setSyncCardH(failed) - setSyncCardH(plain) == 36,
                  "C5-04 \(issue): retry row reserves exactly 36pt in each settings phase")
            if phase == .on {
                // Production height entry; nil lastError keeps this branch
                // Foundation-only, before NSApplication registration.
                check(remoteSyncCardHeight(failed) - remoteSyncCardHeight(plain) == 36,
                      "C5-04 live settings height reserves the same actionable retry row")
            }
        }
    }
    for issue: String? in [nil, "", "oauth_denied", "cleanup_pending", "revoked", "LOCKED"] {
        check(!syncShowsKeychainRetry(issue), "C5-04 retry hidden without a recognized actionable Keychain issue")
    }
    var staleAvailability = SyncUIState(); staleAvailability.keychainRetryAvailable = true
    check(!staleAvailability.canRetryKeychain && setSyncCardH(staleAvailability) == setSyncCardH(SyncUIState()),
          "C5-04 stale scheduling flag alone cannot expose a dead Retry button or allocate its row")
}

private func c5C505(_ check: C5Check) {
    // Injected dimensions model measured labels; actual system-font PNG checks
    // remain required. Both reset lengths must fit by shrinking only the value.
    let labels: [(String, Double)] = [("Сессия", 38), ("Неделя", 41), ("Session", 43), ("Weekly", 40)]
    let resets: [(String, Double)] = [("через 2 ч 14 мин", 81), ("11.11 15:43", 62),
                                     ("in 2 h 14 min", 69), ("11.11 15:43", 62)]
    for width in [130.0, 300.0] {
        for (label, labelWidth) in labels {
            for (reset, valueWidth) in resets {
                let layout = remoteSimpleHeaderLayout(availableWidth: width,
                    measuredLabelWidth: labelWidth, measuredValueWidth: valueWidth)
                check(layout.labelWidth == labelWidth && layout.gap >= 6 && !layout.wrapsValue,
                      "C5-05 \(label)/\(reset)/\(width): complete measured label and at least 6pt separation on existing row")
                check(layout.valueWidth >= 0 && layout.valueWidth <= valueWidth
                      && layout.labelWidth + layout.gap + layout.valueWidth <= width,
                      "C5-05 reset width yields before label/gap and cannot overlap or escape the card")
                if labelWidth + 6 + valueWidth <= width {
                    check(layout.valueWidth == valueWidth, "C5-05 reset retains natural width when measured text fits")
                }
            }
        }
    }
}

private func c5DateView(_ at: Date, state: RemoteCardState = .offline, machine: String = "vps") -> AccountView {
    var source = RemoteSource(machineId: "c5-vps", machineName: machine)
    source.asOf = at; source.lastSeenAt = at; source.status = "ok"; source.interval = 900
    let data = LimitData(session: 20, weekly: 40, asOf: at, source: source)
    return AccountView(product: "claude", label: C5_LABEL, historyKey: C5_LABEL,
        caption: "Claude Code · " + machine, data: data, isLocal: false, tier: nil,
        usageDays: [:], machines: [machine], state: state)
}

private func c5C506(_ check: C5Check) {
    let now = c5ISO("2026-10-12T16:00:00Z")!, yesterday = c5ISO("2026-10-11T15:00:00Z")!
    let zone = TimeZone(secondsFromGMT: 0)!, sync = ReaderSyncState(phase: .on)
    let view = c5DateView(yesterday)
    let narrow = remotePresentationCard(view, sync: sync, language: "en", narrow: true, now: now, timeZone: zone)
    let wide = remotePresentationCard(view, sync: sync, language: "en", narrow: false, now: now, timeZone: zone)
    check(narrow.sourceLine == "From vps on 11.10" && !narrow.sourceLine.contains(" at "),
          "C5-06 EN date-only source uses on, never at")
    check(wide.sourceLine == "Data from vps at 11.10 15:00" && narrow.tooltip.contains("11.10 15:00")
          && narrow.accessibilityValue == narrow.tooltip,
          "C5-06 wide/Advanced and tooltip/AX retain full date and time with at")
    let today = c5DateView(now.addingTimeInterval(-600))
    let fresh = remotePresentationCard(today, sync: sync, language: "en", narrow: true, now: now, timeZone: zone)
    check(fresh.sourceLine == "Data from vps at 15:50", "C5-06 time-only source still uses at")
    let ru = remotePresentationCard(view, sync: sync, language: "ru", narrow: true, now: now, timeZone: zone)
    check(ru.sourceLine == "С vps от 11.10" && narrow.statusLine == "vps offline since 11.10 ›",
          "C5-06 RU source and EN offline since/chevron stay unchanged")
    let machine = String(repeating: "w", count: 16), long = c5DateView(yesterday, machine: machine)
    func measure(_ text: String) -> Double { text.reduce(0.0) { $0 + ($1 == "w" ? 8 : 4) } }
    let fitted = remoteFittedSourceLine(long, language: "en", now: now, timeZone: zone,
        narrow: true, availableWidth: 130, measure: measure)
    check(fitted.hasPrefix("From ") && fitted.contains(" on 11.10") && fitted.contains("…") && measure(fitted) <= 130,
          "C5-06 C3-39 measured machine fitting preserves on and the entire date")
    let stalled = c5DateView(yesterday, state: .syncStalled)
    let reading = remotePresentationCard(stalled, sync: ReaderSyncState(phase: .on, warning: "fixture warning"),
        language: "en", narrow: true, now: now, timeZone: zone, manual: .reading)
    check(reading.sourceLine == "From vps on 11.10" && reading.statusLine == "Reading GitHub…",
          "C5-06 C3-36 state6 and active manual phase retain date preposition and reader priority")
}

func runRemoteLimitsC5SelfTests(check: (Bool, String) -> Void) {
    c5C501(check); c5C501Sanitization(check); c5C502(check); c5C503(check)
    c5C504(check); c5C505(check); c5C506(check)
}
