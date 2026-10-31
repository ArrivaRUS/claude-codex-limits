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
    check(remoteVisibleSourceLine(narrow, advanced: false).isEmpty
          && narrow.sourceLine == "From vps on 11.10" && !narrow.sourceLine.contains(" at "),
          "C5-06 EN date-only source uses on, never at")
    check(wide.sourceLine == "Data from vps on 11.10 15:00" && narrow.tooltip.contains("11.10 15:00")
          && narrow.accessibilityValue == narrow.tooltip,
          "C5-06 Advanced and tooltip/AX retain full date and time with on")
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

// C5-07...11 RED before production implementation (2026-10-31).
private func c5C507(_ check: C5Check) {
    let now = C5_NOW
    for (age, expected) in [(0.0, RemoteFreshnessTone.fresh), (2700, .fresh), (2701, .late),
                             (86400, .late), (86401, .old)] {
        check(remoteSourceFreshness(asOf: now.addingTimeInterval(-age), interval: 1800, now: now) == expected,
              "C5-07 exact interval+15min/day boundaries age=\(age)")
    }
    check(remoteSourceFreshness(asOf: now.addingTimeInterval(-2000), interval: 900, now: now) == .late
          && remoteSourceFreshness(asOf: now.addingTimeInterval(-2000), interval: 3600, now: now) == .fresh,
          "C5-07 selected/Auto local cadence changes only its own freshness horizon")
    check(remoteSourceFreshness(asOf: nil, interval: 900, now: now) == .unknown,
          "C5-07 no reading is grey")
    for ahead in [1.0, 300, 301, 86400] {
        let future = now.addingTimeInterval(ahead)
        check(remoteSourceFreshness(asOf: future, interval: 900, now: now) == .fresh,
              "C5-07 future asOf has age zero, including beyond protocol clock tolerance")
        let header = remoteSourceHeader(c5DateView(future), now: now, language: "en", timeZone: TimeZone(secondsFromGMT: 0)!)
        check(header.tooltip.contains(remoteCardTimestamp(future, now: now, timeZone: TimeZone(secondsFromGMT: 0)!, compactOtherDay: false))
              && !header.tooltip.contains("no readings"), "C5-07 future tooltip keeps the actual timestamp")
    }
    let defaults = localAccountIntervals(auto: true, states: [:], manual: 14400)
    check(defaults["claude"] == AutoPollState().interval && defaults["codex"] == AutoPollState().interval,
          "C5-07 missing saved Auto states use the scheduler's initial interval")
    let age = AutoPollState().interval + 901
    check(remoteSourceFreshness(asOf: now.addingTimeInterval(-age), interval: defaults["codex"], now: now) == .late,
          "C5-07 local default Auto dot does not silently fall back to four hours")
    var saved = AutoPollState(); saved.interval = 3600
    check(localAccountIntervals(auto: true, states: ["codex": saved], manual: 14400)["codex"] == 3600
          && localAccountIntervals(auto: false, states: [:], manual: 900)["codex"] == 900,
          "C5-07 saved Auto and selected manual cadence remain authoritative")
    check(remoteSourceFreshness(asOf: now.addingTimeInterval(-15300), interval: nil, now: now) == .fresh,
          "C5-07 absent schedule uses four hours plus fifteen minutes")
    check(remoteSourceFreshness(asOf: now.addingTimeInterval(-15301), interval: nil, now: now) == .late,
          "C5-07 fallback boundary plus one second")
}
private func c5C508(_ check: C5Check) {
    var view = c5DateView(C5_NOW.addingTimeInterval(-120))
    view.machines = ["macbook", "vps", "third"]
    view.caption = remoteDefaultCaption(view)
    view.sourceReadings = [
        RemoteMachineReading(machineId: "mac", name: "macbook", asOf: C5_NOW.addingTimeInterval(-120), interval: 900, isLocal: true),
        RemoteMachineReading(machineId: "vps", name: "vps", asOf: C5_NOW.addingTimeInterval(-86401), interval: 1800, isLocal: false),
        RemoteMachineReading(machineId: "third", name: "third", asOf: nil, interval: nil, isLocal: false)]
    for language in ["ru", "en"] {
        let model = remoteSourceHeader(view, now: C5_NOW, language: language, timeZone: TimeZone(secondsFromGMT: 0)!)
        check(model.sources.map { $0.tone } == [.fresh, .old, .unknown] && model.overflow == 1,
              "C5-08 provenance retains independent times/statuses and undotted +N")
        check(model.tooltip.split(separator: "\n").count == 3
              && model.tooltip.contains(language == "ru" ? "в срок" : "on time")
              && model.tooltip.contains(language == "ru" ? "больше суток" : "over a day")
              && model.tooltip.contains(language == "ru" ? "нет показаний" : "no readings"),
              "C5-08 each machine has its own timestamp/status in RU/EN tooltip and AX")
        let fitted = remoteSourceHeaderLayout(model, availableWidth: 55, measure: { Double($0.count) * 6 })
        check(fitted.runs.count == 2 && fitted.runs.allSatisfy { $0.dotWidth == 6 && $0.nameGap == 3 }
              && fitted.width <= 55 && fitted.overflow == 1,
              "C5-08 narrow fit shortens names without ever truncating either dot")
    }
    view.caption = "Моя полная пользовательская подпись"
    let custom = remoteSourceHeader(view, now: C5_NOW, language: "ru", timeZone: TimeZone(secondsFromGMT: 0)!)
    let rect = CGRect(x: 0, y: 0, width: 100, height: 31)
    let hits = [Hit(id: "open:fixture", rect: rect, tooltip: "card fallback"),
                Hit(id: "sourceheader:claude:fixture", rect: rect, tooltip: custom.tooltip)]
    check(panelTooltip(at: CGPoint(x: 10, y: 10), hits: hits)?.components(separatedBy: "\n").first == view.caption
          && panelTooltip(at: CGPoint(x: 10, y: 10), hits: hits)?.contains("macbook —") == true,
          "C5-08 real tooltip hit resolver prioritizes the complete caption followed by machine lines")
    var local = view; local.isLocal = true; local.machines = []; local.sourceReadings = []
    local.data.source = nil; local.data.asOf = C5_NOW
    let header = remoteSourceHeader(local, now: C5_NOW, language: "ru", timeZone: TimeZone(secondsFromGMT: 0)!)
    check(header.sources.count == 1 && header.sources[0].name == "этот компьютер" && header.sources[0].tone == .fresh,
          "C5-08 solo local account without sync still has its source dot and fallback name")
}
private func c5C509(_ check: C5Check) {
    for count in 1...4 {
        let views = (0..<count).map { index -> AccountView in
            var view = c5DateView(C5_NOW); view.historyKey = "c509-\(index)"; return view
        }
        let layout = remotePanelLayout(views: views, style: .simple, now: C5_NOW)
        check(layout.cards.allSatisfy { $0.height == 183 }
              && layout.windowHeight == (count <= 2 ? 317 : 512),
              "C5-09 Simple \(count) cards remove one 14pt source row per grid row")
        check(remoteQuotaFooterHeight(advanced: false) == 18 && remoteQuotaFooterHeight(advanced: true) == 32,
              "C5-09 shared footer geometry retains the action row and full Advanced footer")
    }
    let view = c5DateView(C5_NOW.addingTimeInterval(-86400))
    for narrow in [true, false] {
        let p = remotePresentationCard(view, sync: ReaderSyncState(phase: .on), language: "en", narrow: narrow,
            now: C5_NOW, timeZone: TimeZone(secondsFromGMT: 0)!)
        check(remoteVisibleSourceLine(p, advanced: false).isEmpty
              && !remoteVisibleSourceLine(p, advanced: true).isEmpty && !p.statusLine.isEmpty,
              "C5-09 source is hidden only in Simple; action/status and Advanced source survive")
    }
}
private func c5C510(_ check: C5Check) {
    let start = 10000.0
    func reading(_ pct: Double, _ at: Double) -> LimitData {
        LimitData(session: pct, sessionReset: Date(timeIntervalSince1970: 100000),
                  asOf: Date(timeIntervalSince1970: at), apiFresh: true)
    }
    var poll = AutoPollState(); poll.interval = 14400; poll.lastAttempt = start - 100
    var tracker = RemoteAutoActivity()
    let before = poll.lastAttempt
    check(!tracker.observe(product: "codex", label: C5_LABEL, data: reading(20, start), state: &poll, now: start),
          "C5-10 first peer reading establishes a baseline")
    check(tracker.observe(product: "codex", label: C5_LABEL, data: reading(21, start + 900), state: &poll, now: start + 900)
          && poll.interval == 900 && poll.lastAttempt == before && poll.observedAt == 0,
          "C5-10 remote 1pp/15min wakes Auto without a local attempt or local observation")
    var overwritten = poll; overwritten.interval = 14400
    var mirrors = ["codex": overwritten]
    tracker.apply(to: &mirrors, now: start + 901)
    check(mirrors["codex"]?.interval == 900 && mirrors["codex"]?.lastAttempt == before,
          "C5-10 a late C4 poll-state save cannot undo a fresh peer wakeup")
    var rolled = tracker
    var rollbackMirrors = mirrors
    rollbackMirrors["codex"]?.interval = 14400
    rolled.apply(to: &rollbackMirrors, now: start + 900)
    check(rollbackMirrors["codex"]?.interval == 14400,
          "C5-10 rollback before expiry clears the wake hint rather than extending fifteen minutes")
    rolled.apply(to: &rollbackMirrors, now: start + 1000)
    check(rollbackMirrors["codex"]?.interval == 14400, "C5-10 cleared rollback hint cannot reappear as clocks recover")
    mirrors["codex"]?.interval = 14400; tracker.apply(to: &mirrors, now: start + 1800)
    check(mirrors["codex"]?.interval == 14400, "C5-10 wake hint expires after fifteen minutes")
    tracker.apply(to: &mirrors, now: start - 1000)
    check(mirrors["codex"]?.interval == 14400, "C5-10 rollback after expiry cannot resurrect a discarded wake hint")
    poll.interval = 14400
    check(!tracker.observe(product: "codex", label: C5_LABEL, data: reading(21, start + 900), state: &poll, now: start + 901)
          && poll.interval == 14400, "C5-10 duplicate cannot wake again")
    check(!tracker.observe(product: "codex", label: C5_LABEL, data: reading(90, start + 899), state: &poll, now: start + 901)
          && poll.interval == 14400, "C5-10 recent but out-of-order data cannot wake Auto")
    check(!tracker.observe(product: "codex", label: C5_LABEL, data: reading(90, start + 1), state: &poll, now: start + 2000),
          "C5-10 old/out-of-order remote reading ignored")
    for kind in 0..<4 {
        var bad = reading(80, start + 1200)
        if kind == 0 { bad.fromCache = true }; if kind == 1 { bad.stale = true }
        if kind == 2 { bad.error = "synthetic" }; if kind == 3 { bad.apiFresh = false }
        check(!tracker.observe(product: "codex", label: C5_LABEL, data: bad, state: &poll, now: start + 1200)
              && poll.interval == 14400, "C5-10 cached/stale/error/nonfresh reading ignored")
    }
    check(!tracker.observe(product: "codex", label: "0000000000000002", data: reading(99, start + 1201), state: &poll, now: start + 1201),
          "C5-10 changed account starts a new baseline, never compares another account")
    var low = RemoteAutoActivity(), lowState = AutoPollState(); lowState.interval = 14400
    _ = low.observe(product: "codex", label: C5_LABEL, data: reading(20, start), state: &lowState, now: start)
    check(!low.observe(product: "codex", label: C5_LABEL, data: reading(20.99, start + 900), state: &lowState, now: start + 900),
          "C5-10 growth below one percentage point per fifteen minutes stays idle")
    var reset = reading(90, start + 901); reset.sessionReset = Date(timeIntervalSince1970: 200000)
    check(!low.observe(product: "codex", label: C5_LABEL, data: reset, state: &lowState, now: start + 901),
          "C5-10 different reset windows cannot manufacture growth")
    var own = AutoPollState(); own.interval = 14400
    own.observe(reading(20, start), now: start); own.observe(reading(21, start + 900), now: start + 900)
    check(own.interval == 900 && own.lastAttempt == start + 900, "C5-10 existing own-growth semantics remain unchanged")
}
private func c5C511(_ check: C5Check) {
    let id = "account-c511", key = accountLabelKey(gistId: "c511")!
    let label = accountLabel(product: "codex", localId: id, labelKey: key)!
    var cache = SyncRemoteCache(); cache.labelKey = key
    var peer = RemoteAccount(product: "codex", label: label, status: "ok")
    peer.machineId = "vps"; peer.machineName = "vps"; peer.asOf = C5_NOW
    peer.windows = RemoteWindows(session: RemoteWindow(pct: 21, resetAt: C5_NOW.addingTimeInterval(3600)))
    peer.schedule = RemoteSchedule(mode: "auto", interval: 900)
    var other = peer; other.label = "0000000000000002"
    cache.accounts = [other, peer]
    let samples = remoteAutoCandidates(cache, localIds: ["codex": id], now: C5_NOW, freshRead: true)
    check(samples.count == 1 && samples["codex"]?.label == label && samples["codex"]?.data.session == 21,
          "C5-11 only the matching localId/HMAC account can wake this product")
    check(remoteAutoCandidates(cache, localIds: ["codex": id], now: C5_NOW, freshRead: false).isEmpty,
          "C5-11 disk-cache projection cannot feed Auto")
    var datedPeer = peer; datedPeer.asOf = C5_NOW.addingTimeInterval(-4000)
    datedPeer.machineLastSeenAt = C5_NOW; datedPeer.schedule?.interval = 1800
    cache.accounts = [datedPeer]
    let own = LimitData(session: 20, asOf: C5_NOW.addingTimeInterval(-800), apiFresh: true)
    let frame = remoteAccountFrame(local: (LimitData(present: false), own), localIds: ["codex": id], remote: cache,
        hidden: [], menu: [:], sync: ReaderSyncState(phase: .on), now: C5_NOW,
        localMachineName: "macbook", localMachineId: "mac", localIntervals: ["codex": 900])
    let resolved = frame.allViews.first { $0.label == label }
    check(resolved?.sourceReadings.map { $0.asOf } == [own.asOf, datedPeer.asOf]
          && resolved?.sourceReadings.map { $0.interval } == [900, 1800],
          "C5-11 resolver preserves own/peer observation times and their independent schedules")
    if let resolved = resolved {
        check(remoteSourceHeader(resolved, now: C5_NOW, language: "en", timeZone: TimeZone(secondsFromGMT: 0)!)
            .sources.map { $0.tone } == [.fresh, .late], "C5-11 file heartbeat cannot make an old account reading green")
    }
    var stale = peer; stale.asOf = C5_NOW.addingTimeInterval(-901); cache.accounts = [stale]
    check(remoteAutoCandidates(cache, localIds: ["codex": id], now: C5_NOW, freshRead: true).isEmpty,
          "C5-11 remote readings older than fifteen minutes do not feed Auto")
    peer.status = "error"; cache.accounts = [peer]
    check(remoteAutoCandidates(cache, localIds: ["codex": id], now: C5_NOW, freshRead: true).isEmpty,
          "C5-11 failed remote account ignored even with retained percentages")
}

func runRemoteLimitsC5SelfTests(check: (Bool, String) -> Void) {
    c5C501(check); c5C501Sanitization(check); c5C502(check); c5C503(check)
    c5C504(check); c5C505(check); c5C506(check)
    c5C507(check); c5C508(check); c5C509(check); c5C510(check); c5C511(check)
}
