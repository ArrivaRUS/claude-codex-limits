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
    for (caption, expected) in [("Team", "Team"), ("Codex · vps", "Codex · vps"),
        ("e\u{301}\n\u{0001}\u{202E}🚀", "é🚀"),
        ("Mac＠a／b＼c@d/e\\f", "Macabcdef"),
        (String(repeating: "Ж", count: 33), String(repeating: "Ж", count: 32)),
        ("", "")] {
        let seed = remoteCaptionEditorSeed(caption)
        check(seed.text == expected && seed.count == expected.unicodeScalars.count
              && seed.selection == NSRange(location: 0, length: expected.utf16.count),
              "C5-02 editor opens current L cleaned/bounded with full UTF-16 selection and scalar counter")
        check(remoteCaptionValidatedInput(seed.text).error == nil,
              "C5-02 editor seed is safe even for a default label with forbidden separators")
    }
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
            let visible = phase != .awaitingCode
            check(failed.canRetryKeychain == visible && setSyncCardH(failed) - setSyncCardH(plain) == (visible ? 36 : 0),
                  "C5-04 \(issue): retry row exists only in an actionable settings phase")
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
    for language in ["ru", "en"] {
        for issue in ["locked", "unreachable", "timeout"] {
            var restored = SyncUIState(phase: .on, authState: "healthy", login: "fixture")
            restored.lastError = githubAuthMessage(issue, language: language)
            check(restored.keychainIssue == issue && restored.canRetryKeychain,
                  "C5-14 persisted Keychain error retains its action after authReason clears or language changes")
        }
    }
    var unrelated = SyncUIState(phase: .on, authState: "healthy", lastError: "HTTP 500")
    unrelated.keychainRetryAvailable = true
    check(unrelated.keychainIssue == nil && !unrelated.canRetryKeychain,
          "C5-14 unrelated network error and stale scheduling flag cannot create Keychain action")
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
        check(remoteQuotaFooterHeight(advanced: false) == 18 && remoteQuotaFooterHeight(advanced: true) == 0
              && remoteQuotaFooterHeight(advanced: true, statusLine: "status") == 18,
              "C5-09 shared footer geometry reserves Advanced space only for a status row")
    }
    let view = c5DateView(C5_NOW.addingTimeInterval(-86400))
    for narrow in [true, false] {
        let p = remotePresentationCard(view, sync: ReaderSyncState(phase: .on), language: "en", narrow: narrow,
            now: C5_NOW, timeZone: TimeZone(secondsFromGMT: 0)!)
        check(remoteVisibleSourceLine(p, advanced: false).isEmpty
              && remoteVisibleSourceLine(p, advanced: true).isEmpty && !p.statusLine.isEmpty,
              "C5-09 source is hidden in both modes; action/status survive")
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

private func c5C513(_ check: C5Check) {
    let generation = "01234567-89ab-cdef-0123-456789abcdef"
    let ref = GitHubAuthRef(generation: generation)
    let secret = "c5-private-access", refresh = "c5-private-refresh"
    let credential = GitHubCredentialV2(epoch: generation, generation: generation,
        accessToken: secret, refreshToken: refresh, obtainedAt: 1000)
    let encoded = try! JSONEncoder().encode(credential).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    for interactive in [false, true] {
        var calls: [GitHubAuthReadCommand] = [], logs: [String] = []
        let result = githubAuthReadWithCommand(ref, interactive: interactive, probe: { _ in .success }, run: { command in
            calls.append(command); return (.success, encoded + "\n")
        }, log: { logs.append($0) })
        if case .ready(let value) = result { check(value == credential, "C5-13 private system-tool output decodes complete credential pair") }
        else { check(false, "C5-13 successful system-tool read is ready") }
        check(calls.count == 1 && calls[0].systemTool
              && calls[0].arguments == ["find-generic-password", "-s", "Claude Codex Limits GitHub Credential V2", "-a", generation, "-w"]
              && calls[0].timeout == (interactive ? 120 : 15), "C5-13 exact service/generation argv and background/manual budget; no second native read")
        let publicText = calls.flatMap { $0.arguments }.joined() + logs.joined()
        check(![secret, refresh, encoded].contains(where: { publicText.contains($0) }),
              "C5-13 access/refresh/envelope stay out of argv and diagnostics")
        let legacy = githubAuthReadCommand(GitHubAuthRef(generation: "legacy", backend: "legacy-keychain"), interactive: interactive)
        check(legacy?.systemTool == false && legacy?.arguments == ["--github-auth-keychain-helper", "read", "legacy", interactive ? "interactive" : "quiet"],
              "C5-13 legacy without guaranteed system-tool ACL keeps explicit native permission policy")
    }
    let cases: [(Int32?, Bool, SyncKeychainStatus)] = [(0, false, .success), (44, false, .failure(44)),
        (51, false, .failure(36)), (128, false, .failure(36)), (36, false, .failure(36)), (29, false, .failure(36)),
        (1, false, .failure(1)), (nil, false, .failure(-1)), (0, true, .timedOut)]
    for (code, timedOut, expected) in cases {
        let status = githubSecurityReadStatus(exitCode: code, timedOut: timedOut)
        check(status == expected, "C5-13 security exit classification preserves missing/denial/timeout distinctions")
        if status != .success {
            var logs: [String] = [], calls = 0
            let result = githubAuthReadWithCommand(ref, interactive: false, probe: { _ in .success }, run: { _ in
                calls += 1; return (status, secret)
            }, log: { logs.append($0) })
            let matches: Bool
            switch (status, result) {
            case (.missing, .missing), (.timedOut, .timeout), (.failure(36), .locked): matches = true
            case (.failure(44), .locked): matches = true // Native attributes found it: tool's 44 is not absence.
            case (.failure(let value), .unreachable): matches = ![36, 44, 65].contains(value)
            default: matches = false
            }
            check(matches && calls == 1 && !logs.joined().contains(secret), "C5-13 failure does not downgrade to success, expose stdout or launch fallback")
        }
    }
    for invalid in [GitHubAuthRef(generation: "legacy"), GitHubAuthRef(generation: "../escape"), GitHubAuthRef(generation: generation, backend: "file")] {
        var ran = false
        let result = githubAuthReadWithCommand(invalid, interactive: false, probe: { _ in .success }, run: { _ in ran = true; return (.success, encoded) })
        if case .corrupt = result { check(!ran, "C5-13 invalid reference rejected before process creation") }
        else { check(false, "C5-13 invalid reference is corrupt") }
    }
    for malformed in ["", secret, String(repeating: "A", count: 128 * 1024 + 1)] {
        let result = githubAuthReadWithCommand(ref, interactive: false, probe: { _ in .success }, run: { _ in (.success, malformed) })
        if case .corrupt = result { check(true, "C5-13 empty/malformed/oversized successful output fails closed") }
        else { check(false, "C5-13 malformed envelope cannot become a credential") }
    }
}

private func c5C515(_ check: C5Check) {
    let ref = GitHubAuthRef(generation: "01234567-89ab-cdef-0123-456789abcdef")
    for interactive in [false, true] {
        for status in [SyncKeychainStatus.success, .missing, .failure(36), .failure(1), .failure(65)] {
            var probes: [Bool] = [], executions = 0
            let result = githubAuthReadWithCommand(ref, interactive: interactive, probe: { unlocked in
                probes.append(unlocked)
                return unlocked ? .success : status
            }, run: { _ in executions += 1; return (githubSecurityReadStatus(exitCode: 44), "") })
            let matches: Bool
            switch (status, result) {
            case (.missing, .missing), (.success, .locked), (.failure(36), .locked), (.failure(1), .unreachable), (.failure(65), .unreachable): matches = true
            default: matches = false
            }
            check(matches && executions == 1 && probes == (interactive ? [false] : [true, false]),
                  "C5-15 S1 tool44 becomes missing only after native attributes confirms absence")
        }
    }
    for status in [SyncKeychainStatus.failure(36), .failure(1), .missing, .timedOut] {
        var ran = false
        let result = githubAuthReadWithCommand(ref, interactive: false, probe: { _ in status }, run: { _ in ran = true; return (.success, "") })
        let blocked: Bool
        switch result { case .locked, .unreachable, .missing, .timeout: blocked = true; default: blocked = false }
        check(!ran && blocked, "C5-15 S2 quiet locked/unavailable/missing preflight never launches security")
    }
    for operation in ["attributes", "preflight"] {
        let quiet = githubAuthKeychainArguments(operation: operation, ref: ref)
        check(quiet != nil && githubAuthKeychainArguments(operation: operation, ref: ref, interactive: true) == nil,
              "C5-15 metadata helper is exact-ref, quiet-only and cannot request secret data")
    }
}

private func c5C516(_ check: @escaping C5Check) {
    let generation = "01234567-89ab-cdef-0123-456789abcdef", ref = GitHubAuthRef(generation: "01234567-89ab-cdef-0123-456789abcdef")
    let credential = GitHubCredentialV2(epoch: generation, generation: generation, accessToken: "c5-action-token",
        obtainedAt: 1000, userID: "1001", login: "fixture")
    var manifest = GitHubAuthManifest(epoch: generation, active: ref, userID: "1001", login: "fixture")
    let encoded = try! JSONEncoder().encode(credential).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    var quiet = 0, probes = 0, deadlines: [Double] = []
    let deps = GitHubAuthDependencies(clock: { 1000 }, loadManifest: { manifest }, saveManifest: { manifest = $0 },
        readStore: { _ in quiet += 1; return .timeout }, stageStore: { _, _ in .failed }, deleteStore: { _ in .success },
        transport: { _ in check(false, "C5-16 no issuer request"); return GitHubAuthHTTP(status: 0, json: nil) },
        identity: { _ in .ready(userID: "1001", login: "fixture") }, withLock: { try $0() },
        checkpoint: { _, _, _ in }, jitter: { 0 }, legacy: { .signedOut }, settled: { _ in true },
        interactiveReadStore: { requested, action in
            githubAuthReadWithCommand(requested, interactive: true, probe: { _ in probes += 1; return .success }, run: { _ in
                let deadline = githubKeychainProcessTimeout(action: action)
                guard action.admit({ deadlines.append(deadline) }) else { return (.failure(36), "") }
                // A human takes 16s; this would fail under the old quiet-first 15s path.
                return 16 < deadline ? (.success, encoded) : (.timedOut, "")
            })
        })
    let owner = GitHubAuthOwner(dependencies: deps, clientID: "fixture")
    let result = owner.retryKeychainAccess()
    if case .ready = result {
        check(quiet == 0 && probes == 0 && deadlines == [120], "C5-16 S3 owner retry -> interactive adapter -> child timeout120, no prior quiet read")
    } else { check(false, "C5-16 owner retry survives simulated16s password entry") }
    _ = owner.ensureAccess(reason: "background")
    check(quiet == 1 && deadlines == [120] && githubKeychainProcessTimeout(action: nil) == 15,
          "C5-16 successful manual permission does not turn later background reads interactive")
    let remainingAction = GitHubAuthUserAction()
    check(githubKeychainProcessTimeout(action: remainingAction, remaining: 7) == 7
          && githubKeychainProcessTimeout(action: nil, remaining: 7) == 7
          && githubKeychainProcessTimeout(action: remainingAction, remaining: -1) == 0,
          "C5-16 metadata/tool confirmation share remaining budget instead of restarting15/120")
    for attributes in [SyncKeychainStatus.success, .failure(36), .failure(1), .missing] {
        var confirming = deps
        confirming.readStore = { requested in
            githubAuthReadWithCommand(requested, interactive: false, probe: { unlocked in unlocked ? .success : attributes },
                run: { _ in (githubSecurityReadStatus(exitCode: 44), "") })
        }
        let checkingOwner = GitHubAuthOwner(dependencies: confirming, clientID: "fixture")
        let result = checkingOwner.ensureAccess(reason: "background")
        let confirmed: Bool
        switch (attributes, result) {
        case (.missing, .actionRequired("missing")): confirmed = true
        case (.success, .temporary), (.failure, .temporary): confirmed = true
        default: confirmed = false
        }
        check(confirmed && !manifest.signedOut && manifest.active == ref,
              "C5-16 S1 owner requests sign-in only for native-confirmed absence, never for ambiguous tool44")
    }
}

private func c5C517(_ check: C5Check) {
    for size in [128 * 1024 - 1, 128 * 1024, 128 * 1024 + 1, 256 * 1024] {
        var offset = 0, stops = 0, requests: [Int] = []
        let result = githubBoundedReadOutput(read: { count in
            requests.append(count)
            let length = min(count, size - offset); offset += length
            return Data(repeating: 65, count: length)
        }, stop: { stops += 1 })
        check(result.corrupt == (size > 128 * 1024) && result.data.count == (result.corrupt ? 0 : size)
              && stops == (result.corrupt ? 1 : 0) && requests.allSatisfy { $0 <= 8192 }
              && offset <= 128 * 1024 + 1, "C5-17 S4 stdout is bounded during accumulation; overflow stops child immediately")
    }
    let ref = GitHubAuthRef(generation: "01234567-89ab-cdef-0123-456789abcdef")
    let result = githubAuthReadWithCommand(ref, interactive: true, probe: { _ in .success }, run: { _ in (.failure(65), "") })
    if case .corrupt = result { check(true, "C5-17 oversized child output reaches auth as corrupt") }
    else { check(false, "C5-17 oversized output cannot become timeout/success") }
}

private func c5C518(_ check: C5Check) {
    for language in ["ru", "en"] {
        var pending = SyncUIState(phase: .awaitingCode, authReason: "locked")
        pending.lastError = githubAuthMessage("locked", language: language)
        pending.keychainRetryAvailable = true
        var plain = pending; plain.lastError = nil; plain.authReason = nil; plain.keychainRetryAvailable = false
        check(!pending.canRetryKeychain && pending.keychainIssue == nil && setSyncCardH(pending) == setSyncCardH(plain),
              "C5-18 S5 awaiting-code hides stale recovery action and its height")
        pending.phase = .on; pending.lastErrorAt = Date(); pending.prepareForGitHubLogin()
        check(pending.phase == .awaitingCode && pending.lastError == nil && pending.lastErrorAt == nil
              && pending.authReason == nil && !pending.keychainRetryAvailable,
              "C5-18 startLogin transition clears stale Keychain UI state")
    }
}

// C5-19: restart with account-bound cache, then the exact frame/presentation
// consumed by the panel. Supplying localIds directly would hide the live bug.
private func c5C519(_ check: C5Check) {
    let id = "c519-codex-account", gist = "c519-fixture-gist"
    let label = accountLabel(product: "codex", localId: id, gistId: gist)!
    let otherLabel = accountLabel(product: "codex", localId: "c519-other-account", gistId: gist)!
    let ownAt = C5_NOW.addingTimeInterval(-9000), peerAt = C5_NOW.addingTimeInterval(-300)
    let reset = C5_NOW.addingTimeInterval(4 * 86400)
    let sync = ReaderSyncState(phase: .on), zone = TimeZone(secondsFromGMT: 0)!
    let own = LimitData(weekly: 49, weeklyReset: reset, plan: "pro", asOf: ownAt, apiFresh: true)
    // c4CacheQuotaCompletion persists accountId beside ld2dict's values.
    var entry = ld2dict(own); entry["accountId"] = id
    let disk: [String: Any] = ["codex": entry]
    let store = ReaderLocalSnapshot()
    store.restore(cache: disk)
    let restored = store.snapshot()
    check(restored.local.1.fromCache && restored.local.1.asOf == ownAt && restored.ids["codex"] == id,
          "C5-19 startup retains the cached reading's identity without a provider request")

    func frame(_ peerLabel: String, local: (LimitData, LimitData)? = nil) -> RemoteAccountFrame {
        var peer = RemoteAccount(product: "codex", label: peerLabel, status: "ok")
        peer.machineId = "c519-vps"; peer.machineName = "vps"; peer.machineLastSeenAt = C5_NOW
        peer.plan = "pro"; peer.asOf = peerAt; peer.attemptAt = peerAt; peer.resetCredits = 1
        peer.windows = RemoteWindows(weekly: RemoteWindow(pct: 57, resetAt: reset))
        peer.schedule = RemoteSchedule(mode: "fixed", interval: 900)
        var cache = SyncRemoteCache(); cache.labelKey = accountLabelKey(gistId: gist); cache.accounts = [peer]
        return remoteAccountFrame(local: local ?? restored.local, localIds: restored.ids, remote: cache,
            hidden: [], menu: [:], sync: sync, now: C5_NOW,
            localMachineName: "macbook", localMachineId: "c519-mac", localIntervals: ["codex": 1800])
    }
    let merged = frame(label)
    check(merged.allViews.count == 1 && merged.visibleViews.count == 1 && merged.displayedViews.count == 1,
          "C5-19 same account after restart produces one canonical, visible and menu card")
    // Do not return early on a split: print the values/header failures as well.
    if let view = merged.visibleViews.first {
        check(view.label == label && view.isLocal && view.machines == ["macbook", "vps"],
              "C5-19 one account retains the local login and both machine names, local first")
        check(view.data.weekly == 57 && view.data.resetCredits == 1 && view.data.session == nil
              && view.data.weeklyReset == reset && view.data.asOf == peerAt && view.data.source?.machineName == "vps",
              "C5-19 V3 uses the freshest asOf for all values, including reset credits and missing session")
        for language in ["ru", "en"] {
            let presentation = remotePresentationCard(view, sync: sync, language: language, narrow: true,
                now: C5_NOW, timeZone: zone)
            check(presentation.simpleMachines == "● macbook, ● vps"
                  && presentation.sourceHeader?.sources.map { $0.tone } == [.late, .fresh],
                  "C5-19 \(language) panel has orange macbook and green vps dots with independent asOf")
            let titles = merged.visibleViews.map { card in
                remotePresentationCard(card, sync: sync, language: language, narrow: true,
                    now: C5_NOW, timeZone: zone,
                    productAccountCount: merged.visibleViews.filter { $0.product == card.product }.count).simpleTitle
            }
            check(remoteSimplePanelSubtitle(titles, paused: false, language: language) == "Codex",
                  "C5-19 \(language) actual Simple subtitle has one Codex title after restart")
        }
    } else { check(false, "C5-19 merged panel card exists") }
    let distinct = frame(otherLabel)
    check(distinct.visibleViews.count == 2 && Set(distinct.visibleViews.compactMap { $0.label }) == Set([label, otherLabel])
          && distinct.visibleViews.first?.machines == ["macbook"] && distinct.visibleViews.last?.machines == ["vps"],
          "C5-19 distinct labels remain two cards even with identical plan and reset")

    var tied = restored.local.1; tied.asOf = peerAt
    let tiedFrame = frame(label, local: (restored.local.0, tied))
    check(tiedFrame.visibleViews.count == 1 && tiedFrame.visibleViews.first?.data.weekly == 49
          && tiedFrame.visibleViews.first?.data.source == nil,
          "C5-19 V3 equal asOf keeps local values")
    for badID in [nil, "bad/id", "", "tiny"] as [String?] {
        var legacy = entry; legacy["accountId"] = badID
        let unbound = ReaderLocalSnapshot(); unbound.restore(cache: ["codex": legacy])
        check(unbound.snapshot().ids.isEmpty && unbound.snapshot().local.1.weekly == 49,
              "C5-19 legacy/malformed identity stays unlabelled without discarding cached values")
    }
}

// C5-20: the production Simple views/body/footer must not attach an old local
// failure to a newer successful peer reading. Written before the V3 status fix.
private func c5C520(_ check: C5Check) {
    let id = "c520-codex-account", gist = "c520-fixture-gist"
    let label = accountLabel(product: "codex", localId: id, gistId: gist)!
    let ownAt = C5_NOW.addingTimeInterval(-4 * 3600), peerAt = C5_NOW.addingTimeInterval(-360)
    let reset = C5_NOW.addingTimeInterval(4 * 86400)
    let sync = ReaderSyncState(phase: .on), zone = TimeZone(secondsFromGMT: 0)!
    let own = LimitData(weekly: 65, weeklyReset: reset, plan: "pro", asOf: ownAt, apiFresh: true)
    var entry = ld2dict(own); entry["accountId"] = id
    let store = ReaderLocalSnapshot(); store.restore(cache: ["codex": entry])
    let restored = store.snapshot()

    func frame(attempt: Date?, peer: Bool = true, local: Bool = true,
               hasPoll: Bool = true, failed: Bool = true) -> RemoteAccountFrame {
        var poll = AutoPollState(); poll.lastAttempt = attempt?.timeIntervalSince1970 ?? 0; poll.failed = failed
        // Same Codable round trip as autoPollState; no real defaults or disk.
        let restoredPoll = try! JSONDecoder().decode(AutoPollState.self, from: JSONEncoder().encode(poll))
        var data = withPollStatus(restored.local.1, state: hasPoll ? restoredPoll : nil, next: C5_NOW)
        data.error = "synthetic local failure"
        var account = RemoteAccount(product: "codex", label: label, status: "ok")
        account.machineId = "c520-vps"; account.machineName = "vps"; account.machineLastSeenAt = C5_NOW
        account.asOf = peerAt; account.attemptAt = peerAt; account.resetCredits = 1
        account.windows = RemoteWindows(weekly: RemoteWindow(pct: 65, resetAt: reset))
        account.schedule = RemoteSchedule(mode: "fixed", interval: 900)
        var cache = SyncRemoteCache(); cache.labelKey = accountLabelKey(gistId: gist)
        cache.accounts = peer ? [account] : []
        return remoteAccountFrame(local: (LimitData(present: false), local ? data : LimitData(present: false)),
            localIds: local ? restored.ids : [:], remote: cache, hidden: [], menu: [:], sync: sync, now: C5_NOW,
            localMachineName: "macbook", localMachineId: "c520-mac", localIntervals: ["codex": 14400])
    }
    for language in ["ru", "en"] {
        for (name, attempt, peer, failure) in [
            ("older failure", C5_NOW.addingTimeInterval(-2.7 * 3600), true, false),
            ("newer failure", C5_NOW.addingTimeInterval(-60), true, true),
            ("equal attempt", peerAt, true, false),
            ("local only", C5_NOW.addingTimeInterval(-2.7 * 3600), false, true)
        ] {
            withRemoteRenderScene(frame: frame(attempt: attempt, peer: peer), timeZone: zone, manual: .idle) {
                // This is the very projection drawPanelSimple uses, not raw resolver output.
                let views = simpleCardViews(restored.local.0, restored.local.1)
                check(views.count == 1, "C5-20 \(language)/\(name): one Simple account card")
                guard let view = views.first else { return }
                let presentation = remotePresentationCard(view, sync: sync, language: language, narrow: true,
                    now: C5_NOW, timeZone: zone)
                let status = simpleCardStatus(view, now: C5_NOW, language: language)
                check(limitPollFailed(view.data) == failure && (view.data.error != nil) == failure,
                      "C5-20 \(language)/\(name): Simple data compares the known failed attempt with the selected success")
                check(status.showsSnapshotWarning == failure && status.showsResetRows == !failure,
                      "C5-20 \(language)/\(name): actual Simple body decision preserves reset rows after newer success")
                check(status.feedback.action == (failure ? .retry : .none)
                      && status.feedback.actionTitle == (failure ? (language == "en" ? "Retry" : "Повторить") : ""),
                      "C5-20 \(language)/\(name): actual quota footer decision and localized Retry")
                check(view.data.asOf == (peer ? peerAt : ownAt) && view.data.weeklyReset == reset
                      && view.data.weekly == 65 && view.data.session == nil
                      && presentation.simpleMachines == (peer ? "● macbook, ● vps" : "● macbook"),
                      "C5-20 \(language)/\(name): selected reading/reset and source header remain intact")
            }
        }
        for (name, attempt, hasPoll, failed) in [
            ("missing Auto", nil as Date?, false, false),
            ("zero attempt", nil as Date?, true, true),
            ("error without pollFailed", C5_NOW.addingTimeInterval(-2.7 * 3600) as Date?, true, false)
        ] {
            withRemoteRenderScene(frame: frame(attempt: attempt, hasPoll: hasPoll, failed: failed),
                                  timeZone: zone, manual: .idle) {
                let views = simpleCardViews(restored.local.0, restored.local.1)
                check(views.count == 1, "C5-20 \(language)/\(name): one merged Simple card")
                guard let view = views.first else { return }
                let status = simpleCardStatus(view, now: C5_NOW, language: language)
                check(view.data.error != nil && view.data.pollFailed == failed && limitPollFailed(view.data)
                      && view.data.asOf == peerAt
                      && (attempt == nil ? view.data.pollAttemptAt == nil : view.data.pollAttemptAt == attempt),
                      "C5-20 \(language)/\(name): fresh VPS cannot clear an error without a known failed attempt")
                check(status.showsSnapshotWarning && !status.showsResetRows
                      && status.feedback.action == .retry
                      && status.feedback.actionTitle == (language == "en" ? "Retry" : "Повторить"),
                      "C5-20 \(language)/\(name): actual Simple body/footer retain warning and localized Retry")
            }
        }
        withRemoteRenderScene(frame: frame(attempt: C5_NOW, local: false), timeZone: zone, manual: .idle) {
            let foreign = simpleCardViews(LimitData(present: false), LimitData(present: false))
            check(foreign.count == 1 && foreign.first?.isLocal == false
                  && foreign.first.map { !limitPollFailed($0.data)
                      && !simpleCardStatus($0, now: C5_NOW, language: language).showsSnapshotWarning } == true,
                  "C5-20 \(language): card without a local login keeps its existing state")
        }
    }
}

// C5-21…23: owner decisions 2026-11-01. Production row/height/money models,
// explicit language, clock and in-memory usage only; registered before AppKit.
private func c5C521(_ check: C5Check) {
    for language in ["ru", "en"] {
        var view = c5DateView(C5_NOW)
        view.product = "codex"; view.data.session = nil; view.data.sessionReset = nil
        let sync = ReaderSyncState(phase: .on)
        let frame = RemoteAccountFrame(now: C5_NOW, sync: sync, allViews: [view], visibleViews: [view], displayedViews: [view])
        withRemoteRenderScene(frame: frame, timeZone: TimeZone(secondsFromGMT: 0)!, manual: .idle) {
            let cards = advCards(LimitData(present: false), view.data)
            let layout = remotePanelLayout(views: [view], style: .advanced, now: C5_NOW)
            check(cards.first?.rows.contains { $0.limit?.id == "session" && $0.limit?.used == nil } == true,
                  "C5-21 \(language): Advanced keeps the empty Codex session shown in Simple")
            check(cards.first?.height == layout.cards.first?.height,
                  "C5-21 \(language): real Advanced card and shared geometry use the same footer/rows")
            let p = remotePresentationCard(view, sync: sync, language: language, narrow: false,
                now: C5_NOW, timeZone: TimeZone(secondsFromGMT: 0)!)
            check(remoteVisibleSourceLine(p, advanced: true).isEmpty && remoteVisibleSourceLine(p, advanced: false).isEmpty
                  && remoteQuotaFooterHeight(advanced: true, statusLine: p.statusLine) == remoteQuotaFooterHeight(advanced: false)
                  && p.sourceHeader?.tooltip.isEmpty == false && !p.statusLine.isEmpty && !p.advancedBadge.isEmpty,
                  "C5-21 \(language): both modes hide source ink, retaining source tooltip/AX model")
            if let row = cards.first?.rows.first(where: { $0.limit?.id == "session" }) {
                check(remoteAdvancedVerdict(row, data: view.data, now: C5_NOW, language: language,
                    timeZone: TimeZone(secondsFromGMT: 0)!) == "—",
                      "C5-21 \(language): foreign empty window says dash, never inactive instruction")
            }
        }
        var own = view; own.isLocal = true; own.data.source = nil
        let ownFrame = RemoteAccountFrame(now: C5_NOW, sync: sync, allViews: [own], visibleViews: [own], displayedViews: [own])
        withRemoteRenderScene(frame: ownFrame, timeZone: TimeZone(secondsFromGMT: 0)!, manual: .idle) {
            let row = advCards(LimitData(present: false), own.data).first?.rows.first { $0.limit?.id == "session" }
            check(row?.kind == .inactive && row?.limit?.used == nil,
                  "C5-21 \(language): own empty session retains the local inactive row")
        }
    }
}
private func c5C522(_ check: C5Check) {
    let id = "c522-only-codex", key = accountLabelKey(gistId: "c522-gist")!
    let label = accountLabel(product: "codex", localId: id, labelKey: key)!
    let day = "2026-10-30", model = "gpt-6.1-sol"
    var u = DayModelUsage(); u.input = 1_000_000; u.turns = 1
    let days: RemoteDays = [day: [model: u]]
    for count in [0, 1, 2] {
        let records: [[String: Any]] = (0..<count).map { n in
            ["product": "codex", "label": n == 0 ? label : "abcdef0123456789", "status": "signed_out", "days": [String: Any]()]
        }
        let body: [String: Any] = ["schema": 1, "machine": ["id": "c522-peer", "name": "vps"],
            "updated": ISO8601DateFormatter().string(from: C5_NOW), "accounts": records,
            "days": ["codex": [day: [model: ["input": 1_000_000, "turns": 1]]]],
            "unattributedDays": ["codex": [day: [model: ["input": 1_000_000, "turns": 1]]]]]
        let json = String(decoding: try! JSONSerialization.data(withJSONObject: body), as: UTF8.self)
        let cache = mergeV11(["machine-c522-peer.json": json], excluding: "mac", now: C5_NOW)
        check((cache.unattributedDays?["codex"]?.isEmpty ?? true) == (count == 1),
              "C5-22 reader: \(count) same-product accounts, only singleton absorbs unlabelled days")
        check((cache.accounts ?? []).reduce(0) { $0 + ($1.days[day]?[model]?.input ?? 0) }
              + (cache.unattributedDays?["codex"]?[day]?[model]?.input ?? 0) == 1_000_000,
              "C5-22 reader projection conserves usage without root double counting")
    }
    // Account-split history/F3 tests retired: the product model is covered by C5-24.
    // Publisher R4 remains part of the wire contract and is intentionally unchanged.
    let wireDays: [String: Any] = ["codex": [day: [model: ["input": 1_000_000, "turns": 1]]]]
    for count in [0, 1, 2] {
        var attribution = [day: ""]
        if count == 2 { attribution["2026-10-01"] = "c522-other-codex" }
        let file = c4MachineFile(days: wireDays, accountByDay: ["codex": attribution], localId: count == 0 ? nil : id,
            codex: LimitData(plan: "pro"), poll: AutoPollState(), gistId: "c522-gist", machineId: "mac",
            machineName: "macbook", osName: "fixture", now: C5_NOW)
        let records = file["accounts"] as? [[String: Any]] ?? []
        let byDay = records.first { $0["label"] as? String == label }?["days"] as? [String: Any]
        let other = (file["unattributedDays"] as? [String: Any])?["codex"] as? [String: Any]
        check(count == 1 ? byDay?[day] != nil && other?[day] == nil : other?[day] != nil,
              "C5-22 publisher R4 empty marker, \(count) known IDs: wire attribution remains unchanged")
    }

}
private func c5C523(_ check: C5Check) {
    let price = modelPrice("gpt-6.1-sol-2026-09-29")
    check(price?.input == 2 && price?.output == 10 && price?.cacheRead == 0.10 && price?.cacheWrite == 2.50,
          "C5-23 6.1 Sol price covers all token classes")
    var u = DayModelUsage(); u.input = 1_000_000
    check(apiCost("unknown-c523", u) == nil, "C5-23 unknown model stays unpriced")
    for language in ["ru", "en"] {
        for model in ["gpt-5.6-sol", "gpt-6-sol", "gpt-6.1-sol"] {
            check(advModelFamily(model, product: "codex").name == "Sol", "C5-23 all Sol IDs share a bar family")
        }
        check(remoteMoneyDaily(6.6667, language: language) == (language == "ru" ? "$6,67" : "$6.67")
              && remoteMoneyDaily(44.88, language: language) == "$45"
              && remoteMoneyDaily(10, language: language) == "$10"
              && remoteMoneyValue(29.7, language: language) == (language == "ru" ? "×29,7" : "×29.7")
              && remoteMoneyValue(16, language: language) == (language == "ru" ? "×16,0" : "×16.0")
              && remoteMoneyValue(101.2, language: language) == "×101", "C5-23 \(language): daily money and value precision")
        check(remoteModelLegend(product: "codex", language: language) == ["Astra", "Sol", language == "ru" ? "прочие" : "other"]
              && remoteMoneyValueHeading(language: language) == (language == "ru" ? "ВЫГОДА" : "VALUE"),
              "C5-23 \(language): actual legend/heading omit old Sol versions and machine count")
        // Note wrapping and section geometry now follow the accepted C5-26 model.

    }
}

private func c5C524Fixture() -> (UsageIndex, SyncRemoteCache, [AccountView]) {
    let day = "2026-10-30", stamp = ISO8601DateFormatter().string(from: C5_NOW)
    let codexLabel = accountLabel(product: "codex", localId: "c524-own-codex", gistId: "c524-gist")!
    let claudeLabel = accountLabel(product: "claude", localId: "c524-vps-claude", gistId: "c524-gist")!
    func days(_ product: String, _ count: Int) -> [String: Any] {
        [day: [product == "codex" ? "gpt-6.1-sol" : "claude-opus": ["input": count * 1_000_000, "turns": 1]]]
    }
    func file(_ id: String, _ body: [String: Any]) -> String {
        var object = body; object["schema"] = 1; object["machine"] = ["id": id, "name": id]; object["updated"] = stamp
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
    let weekly: [String: Any] = ["pct": 40, "resetAt": ISO8601DateFormatter().string(from: C5_NOW.addingTimeInterval(100 * 3600))]
    func record(_ product: String, _ label: String, _ plan: String, _ count: Int) -> [String: Any] {
        ["product": product, "label": label, "status": "ok", "plan": plan, "asOf": stamp,
         "windows": ["weekly": weekly], "days": days(product, count)]
    }
    let macAccounts: [[String: Any]] = [record("codex", codexLabel, "pro", 1)]
    let vpsAccounts: [[String: Any]] = [record("claude", claudeLabel, "max", 2), record("codex", codexLabel, "pro", 3)]
    let mac = file("mac", ["days": ["codex": days("codex", 1)], "accounts": macAccounts])
    let vps = file("vps", ["days": ["claude": days("claude", 2), "codex": days("codex", 3)], "accounts": vpsAccounts])
    let thinkpad = file("thinkpad", ["days": ["claude": days("claude", 4), "codex": days("codex", 5)]])
    var cache = mergeV11(["machine-mac.json": mac, "machine-vps.json": vps, "machine-thinkpad.json": thinkpad], excluding: "mac", now: C5_NOW)
    cache.labelKey = accountLabelKey(gistId: "c524-gist")
    var local = UsageIndex(); var usage = DayModelUsage(); usage.input = 1_000_000; usage.turns = 1
    local.add("codex", day, "gpt-6.1-sol", usage); local.accountByDay = ["codex": [day: ""]]
    let views = resolveAccounts(local: (LimitData(present: false), LimitData(plan: "pro", asOf: C5_NOW)),
        localIds: ["codex": "c524-own-codex"], remote: cache, hidden: [], menu: [:], sync: ReaderSyncState(phase: .on), now: C5_NOW)
    return (local, cache, views)
}
private func c5C524(_ check: C5Check) {
    let (local, cache, views) = c5C524Fixture()
    let index = historyUsageIndex(local: local, remote: cache)
    for language in ["ru", "en"] {
        let subscriptions = historySubscriptions(views: views, index: index, now: C5_NOW, language: language)
        check(subscriptions.map { $0.title } == ["Claude Max", "Codex Pro"] && subscriptions.count == 2,
              "C5-24 \(language): three machines, empty old marker and legacy file produce exactly two product tabs")
        check(subscriptions.allSatisfy { !$0.title.contains("mac") && !$0.title.contains("vps") && !$0.title.contains("thinkpad") },
              "C5-24 \(language): subscription names never include machine names")
        for subscription in subscriptions {
            let summary = subscriptionMoneySummary(subscription, price: (200, false), now: C5_NOW)
            check(summary.usdApi == (subscription.product == "codex" ? 18 : 30),
                  "C5-24 \(language)/\(subscription.product): sum root totals of peers plus own history once, excluding own gist file")
        }
        let codex = historySubscriptions(views: views.filter { $0.product == "codex" }, index: local, now: C5_NOW, language: language)
        check(codex.count == 1 && codex[0].title == "Codex Pro", "C5-24 \(language): Codex-only has one tab")
        let usageOnly = historySubscriptions(views: [], index: local, now: C5_NOW, language: language)
        let unknown = subscriptionMoneySummary(usageOnly[0], price: (100, true), now: C5_NOW)
        let row = remoteMoneyRow(usageOnly[0], summary: unknown, language: language)
        check(usageOnly.count == 1 && row.title == "Codex" && row.monthly.isEmpty && row.value.isEmpty && !row.editable && unknown.usdApi == 2,
              "C5-24 \(language): usage without plan keeps API spending, without subscription price/pencil/value")
        let explicit = historySubscriptionPrice(codex[0], overrides: [remoteAccountID(codex[0].accounts[0]): 150], fallback: (200, true))
        check(explicit.usd == 150 && !explicit.estimated, "C5-24 \(language): owner subscription price takes precedence")
        var named = views.first { $0.product == "codex" }!; named.customCaption = "Работа"; named.isLocal = true
        var peer = named; peer.historyKey = "c524-peer"; peer.isLocal = false; peer.customCaption = "Personal"
        let tied = historySubscriptions(views: [peer, named], index: local, now: C5_NOW, language: language)
        check(tied.first?.title == "Работа", "C5-24 \(language): L wins over plan, own L wins equal asOf")
        peer.data.asOf = C5_NOW.addingTimeInterval(1)
        check(historySubscriptions(views: [named, peer], index: local, now: C5_NOW, language: language).first?.title == "Personal",
              "C5-24 \(language): freshest asOf selects between historical captions")
        let accountOnly = historySubscriptions(views: views.filter { $0.product == "codex" }, index: UsageIndex(), now: C5_NOW, language: language)
        check(accountOnly.count == 1, "C5-24 \(language): an account without recent spending still has its tab")
        var metadataOnly = views.first { $0.product == "codex" }!; metadataOnly.data.plan = nil
        metadataOnly.caption = remoteDefaultCaption(metadataOnly)
        var record = RemoteAccount(product: "codex", label: metadataOnly.label, status: "signed_out")
        record.plan = "pro"; record.asOf = C5_NOW
        let planned = historySubscriptions(views: [metadataOnly], index: UsageIndex(), now: C5_NOW,
            language: language, remoteAccounts: [record])
        check(planned.first?.title == "Codex Pro" && metadataOnly.data.plan == nil,
              "C5-24 \(language): account plan metadata without quota windows names the subscription without changing a limit card")
        let empty = historySubscriptions(views: [], index: UsageIndex(), now: C5_NOW, language: language)
        check(empty.isEmpty, "C5-24 \(language): no account and no recent usage means no tab")
    }
}
private func c5C525Views() -> [AccountView] {
    var claude = c5DateView(C5_NOW, state: .fresh); claude.isLocal = true; claude.data.source = nil
    claude.caption = ""; claude.data.plan = "max"; claude.data.sessionReset = C5_NOW.addingTimeInterval(4 * 3600)
    claude.data.weeklyReset = C5_NOW.addingTimeInterval(100 * 3600)
    claude.data.scoped = ScopedLimit(name: "Fable", percent: 43, reset: C5_NOW.addingTimeInterval(100 * 3600), severity: nil)
    var codex = claude; codex.product = "codex"; codex.historyKey = "c525-codex"; codex.data.plan = "pro"
    codex.data.session = nil; codex.data.sessionReset = nil; codex.data.scoped = nil; codex.data.resetCredits = 1
    return [claude, codex]
}
private func c5C525(_ check: C5Check) {
    for language in ["ru", "en"] {
        let views = c5C525Views()
        let frame = RemoteAccountFrame(now: C5_NOW, sync: ReaderSyncState(phase: .on), allViews: views, visibleViews: views, displayedViews: views)
        withRemoteRenderScene(frame: frame, timeZone: TimeZone(secondsFromGMT: 0)!, manual: .idle) {
            let cards = advCards(views[0].data, views[1].data)
            check(cards.map { $0.height } == [226, 176] && cards.allSatisfy { $0.footerHeight == 0 },
                  "C5-25 \(language): real cards match mockup 226/176 without a blank footer")
        }
        var offline = views
        for i in offline.indices {
            offline[i].isLocal = false; offline[i].state = .offline
            var source = RemoteSource(machineId: "c525-vps", machineName: "vps")
            source.asOf = C5_NOW; source.lastSeenAt = C5_NOW.addingTimeInterval(-3600); source.freshUntil = C5_NOW.addingTimeInterval(3600)
            offline[i].data.source = source
        }
        let failed = RemoteAccountFrame(now: C5_NOW, sync: ReaderSyncState(phase: .on), allViews: offline, visibleViews: offline, displayedViews: offline)
        withRemoteRenderScene(frame: failed, timeZone: TimeZone(secondsFromGMT: 0)!, manual: .idle) {
            check(advCards(offline[0].data, offline[1].data).map { $0.height } == [244, 194],
                  "C5-25 \(language): nonempty state line adds exactly 18pt to each real card")
        }
    }
}
private func c5C526(_ check: C5Check) {
    for language in ["ru", "en"] {
        let rows = [RemoteMoneyRow(product: "claude", title: "Claude Max", monthly: "$200", apiDaily: "$200", value: "×30", editable: false, activeAmount: "$350"),
                    RemoteMoneyRow(product: "codex", title: "Codex Pro", monthly: "$200", apiDaily: "$179", value: "×26", editable: false, activeAmount: "$190")]
        let selector = remoteHistorySelectorLayout(titles: rows.map { $0.title }, measuredWidths: [57, 52], headingWidth: 130,
            availableWidth: 308, expanded: true)
        let notes = remoteMoneyNoteLines(rows, language: language, width: 308, measure: { Double($0.count) * 3.5 })
        let history = remoteHistoryLayout(rowCount: 2, selectorExtra: Double(selector.extraHeight), noteLines: notes, expanded: true)
        let window = remoteAdvancedLayout(cardHeights: [226, 176], historyHeight: history.height)
        check(!selector.ownRow && selector.container?.minY == 0 && notes.count == 1 && notes[0].contains("Claude Max") && notes[0].contains("Codex Pro"),
              "C5-26 \(language): selector top is hy; active-day line retains full subscription names")
        check(history.height == 187 && window.height == 722 && window.footer.maxY <= window.height && window.credit.maxY <= window.height,
              "C5-26 \(language): shared draw/window geometry is history 187 and window 722, including complete footer")
        check(history.columnRightEdges == [190, 283, 334] && history.rowTops[1] - history.rowTops[0] == 15,
              "C5-26 \(language): real table model has right edges 190/283/334 and 15pt rows")
        check(remoteHistoryLayout(rowCount: 1, selectorExtra: 0, noteLines: ["one"], expanded: true).height == 172,
              "C5-26 \(language): one subscription history is 172pt")
        let long = rows.map { row -> RemoteMoneyRow in var row = row; row.title = String(repeating: "Ж", count: 32); return row }
        let own = remoteHistorySelectorLayout(titles: long.map { $0.title }, measuredWidths: [256, 256], headingWidth: 130,
            availableWidth: 308, expanded: true)
        let fitted = remoteHistoryFittedTitle(long[0].title, width: Double(own.rects[0].width - 10), measure: { Double($0.count) * 8 })
        let short = remoteMoneyNoteLines(long, language: language, width: 308, measure: { Double($0.count) * 5 })
        check(own.ownRow && own.extraHeight == 22 && own.fontSize == 10.5 && Set(own.rects.map { $0.minY }).count == 1 && fitted.hasSuffix("…")
              && own.titles[0].count == 32, "C5-26 \(language): long labels use one extra selector row, ellipsis and full tooltip title")
        check(short.joined().contains("Claude ≈") && short.joined().contains("Codex ≈") && !short.joined().contains("Ж") && !short.joined().contains("…"),
              "C5-26 \(language): long L shortens to product names before wrapping")
        let wrapped = remoteMoneyNoteLines(long, language: language, width: 170, measure: { Double($0.count) * 5 })
        check(wrapped.count > 1 && wrapped.contains { $0.contains("Codex ≈ $190") },
              "C5-26 \(language): final compression moves complete items at the middle-dot separator")
        let grown = remoteHistoryLayout(rowCount: 2, selectorExtra: 22, noteLines: wrapped, expanded: true)
        let enlarged = remoteAdvancedLayout(cardHeights: [226, 176], historyHeight: grown.height)
        check(enlarged.height == 722 + 22 + Double(wrapped.count - 1) * 12 && enlarged.credit.maxY <= enlarged.height,
              "C5-26 \(language): selector and note rows grow window with its footer through the shared draw model")
    }
}

func runRemoteLimitsC5SelfTests(check: (Bool, String) -> Void) {
    c5C501(check); c5C501Sanitization(check); c5C502(check); c5C503(check)
    c5C504(check); c5C505(check); c5C506(check)
    c5C507(check); c5C508(check); c5C509(check); c5C510(check); c5C511(check)
    c5C513(check)
    c5C515(check); withoutActuallyEscaping(check) { c5C516($0) }; c5C517(check); c5C518(check)
    c5C519(check)
    c5C520(check)
    c5C521(check); c5C522(check); c5C523(check)
    c5C524(check); c5C525(check); c5C526(check)
}
