import Foundation

// C3 part B: independent RED model tests, 2026-10-28.
// Sources: plans C3, test-plan C3-06/08/09, UX §§6/7/9/10/11,
// sync-protocol writer sanitization (T14), lessons 004/006/013/014.
// Entry must run BEFORE NSApplication.shared. No AppKit, runtime globals,
// defaults, filesystem, credentials, history singleton, refresh or network.
// Fixed clock/timezone/theme and all settings are explicit arguments.
// RED means written before models; no Swift compilation/run claimed on Linux.
// Geometry is top-left coordinates. Geometry/model checks do not accept C3-10:
// deterministic PNG generation, independent reference comparison, native editing,
// actual statusItem appearance and real-screen checks remain macOS work.
//
// Foundation-only contract (production definitions: RemoteLimitsC3B.swift):
// enum RemotePanelStyle { case simple, advanced }
// struct RemotePanelLayout {
//   var cards: [CGRect]; var intervalRect, authorRect: CGRect
//   var windowHeight: Double; var historySelectorRect: CGRect?; var moneyRows: [CGRect]
// }
// func remotePanelLayout(views: [AccountView], style: RemotePanelStyle, now: Date,
//                        historyHeight: Double = 35) -> RemotePanelLayout
// struct RemoteMenuLine {
//   var product, historyKey, caption, sourceLine: String
//   var session, weekly: Double?; var sessionAlpha, weeklyAlpha, punctuationAlpha: Double
// }
// struct RemoteMenuPresentation { var lines: [RemoteMenuLine]; var tooltip: String; var dark: Bool }
// func remoteMenuPresentation(views: [AccountView], selected: [String: String],
//   language: String, dark: Bool, now: Date, timeZone: TimeZone,
//   metrics: [String] = ["session", "weekly", "model"]) -> RemoteMenuPresentation
// struct RemoteSettingsAccount { var historyKey, title, subtitle: String; var visible, editable: Bool }
// struct RemoteSettingsModel {
//   var pollingTitle: String; var pollingEnabled: [String: Bool]; var accounts: [RemoteSettingsAccount]
//   var menuProducts: [String]; var showsAccounts, showsGitHub, showsV10: Bool; var v10Text: String
// }
// func remoteSettingsModel(views: [AccountView], hidden: Set<String>, polling: [String: Bool],
//   sync: ReaderSyncState, advanced: Bool, language: String) -> RemoteSettingsModel
// enum RemoteCaptionCommand { case enter, escape, reset }
// struct RemoteCaptionEdit { var text: String; var count: Int; var value: String?; var committed: Bool }
// func remoteCaptionInput(_ raw: String) -> String
// func remoteCaptionEdit(original: String?, draft: String, command: RemoteCaptionCommand) -> RemoteCaptionEdit
// Caption: reject WHOLE string containing @ / backslash after NFKC, before
// truncation; drop Cc/Cf, NFC-normalize; at most 32 Unicode scalars. Empty/reset
// commits nil (default label); Escape preserves original and does not commit.
// Unsafe nonempty draft is rejection, NOT empty/reset: original is retained,
// committed=false. A sanitizer's empty result must not erase an existing label.

private typealias C3BExpect = (Bool, String) -> Void

private func c3bNow() -> Date { Date(timeIntervalSince1970: 1_791_820_800) } // 2026-10-12 16:00 UTC
private func c3bView(_ index: Int = 0, product: String = "claude", local: Bool = false,
                     model: Bool = false, state: RemoteCardState = .fresh) -> AccountView {
    let now = c3bNow(), at = now.addingTimeInterval(-600)
    let machine = local ? "mac" : "vps"
    var source = RemoteSource(machineId: "c3b-" + machine, machineName: machine)
    source.asOf = at; source.lastSeenAt = now; source.interval = 3600
    source.mode = "auto"; source.status = "ok"; source.freshUntil = now.addingTimeInterval(3600)
    let data = LimitData(session: 20 + Double(index), weekly: 40 + Double(index),
                         sessionReset: now.addingTimeInterval(7200), weeklyReset: now.addingTimeInterval(86400),
                         scoped: model ? ScopedLimit(name: "Fable", percent: 30, reset: now.addingTimeInterval(86400), severity: nil) : nil,
                         plan: product == "claude" ? "max" : "pro", asOf: at, source: local ? nil : source)
    let label = "c3b000000000000" + String(index)
    return AccountView(product: product, label: label, historyKey: label,
                       caption: product == "claude" ? "Claude Max 20x · " + machine : "Codex Pro · " + machine,
                       data: data, isLocal: local, tier: product == "claude" ? "default_claude_max_20x" : nil,
                       usageDays: [:], machines: [machine], state: state)
}

private func c3bValidRects(_ layout: RemotePanelLayout, _ expect: C3BExpect, _ context: String) {
    let all = layout.cards + layout.moneyRows + (layout.historySelectorRect.map { [$0] } ?? [])
        + [layout.intervalRect, layout.authorRect]
    expect(all.allSatisfy { $0.minX.isFinite && $0.minY.isFinite && $0.width > 0 && $0.height > 0
        && $0.minX >= 0 && $0.maxX <= 360 && $0.minY >= 0 && Double($0.maxY) <= layout.windowHeight },
           "C3-06 \(context): positive finite rectangles stay inside 360pt window")
    for i in all.indices {
        for j in all.indices where j > i {
            expect(!all[i].intersects(all[j]), "C3-06 \(context): rectangles \(i)/\(j) do not overlap")
        }
    }
    expect((layout.cards.map { $0.maxY }.max() ?? 0) <= layout.intervalRect.minY
           && layout.intervalRect.maxY <= layout.authorRect.minY,
           "C3-06 \(context): intervals below last card, authorship below intervals")
}

private func c3bC306(_ expect: C3BExpect) {
    // Literal UX vectors, including a model row ONLY in the last visible card.
    // This catches sizing that still consults only the first two/product cards.
    let vectors: [(Int, Bool, Double, Double, [CGRect])] = [
        (1, false, 184, 318, [CGRect(x: 16, y: 58, width: 328, height: 184)]),
        (2, false, 184, 318, [CGRect(x: 16, y: 58, width: 158, height: 184), CGRect(x: 186, y: 58, width: 158, height: 184)]),
        (3, false, 184, 514, [CGRect(x: 16, y: 58, width: 158, height: 184), CGRect(x: 186, y: 58, width: 158, height: 184), CGRect(x: 16, y: 254, width: 328, height: 184)]),
        (4, false, 184, 514, [CGRect(x: 16, y: 58, width: 158, height: 184), CGRect(x: 186, y: 58, width: 158, height: 184), CGRect(x: 16, y: 254, width: 158, height: 184), CGRect(x: 186, y: 254, width: 158, height: 184)]),
        (1, true, 199, 333, [CGRect(x: 16, y: 58, width: 328, height: 199)]),
        (2, true, 199, 333, [CGRect(x: 16, y: 58, width: 158, height: 199), CGRect(x: 186, y: 58, width: 158, height: 199)]),
        (3, true, 199, 544, [CGRect(x: 16, y: 58, width: 158, height: 199), CGRect(x: 186, y: 58, width: 158, height: 199), CGRect(x: 16, y: 269, width: 328, height: 199)]),
        (4, true, 199, 544, [CGRect(x: 16, y: 58, width: 158, height: 199), CGRect(x: 186, y: 58, width: 158, height: 199), CGRect(x: 16, y: 269, width: 158, height: 199), CGRect(x: 186, y: 269, width: 158, height: 199)])
    ]
    for (count, model, height, window, rects) in vectors {
        let views = (0..<count).map { c3bView($0, product: $0 == 0 ? "claude" : "codex", model: model && $0 == count - 1) }
        let layout = remotePanelLayout(views: views, style: .simple, now: c3bNow())
        expect(layout.cards == rects && layout.windowHeight == window,
               "C3-06 Simple \(count)/model=\(model): exact UX grid and window height")
        expect(layout.cards.allSatisfy { Double($0.height) == height }, "C3-06 Simple: all cards share scoped row height")
        c3bValidRects(layout, expect, "Simple \(count)/\(model)")
    }
    for product in ["claude", "codex"] {
        for style in [RemotePanelStyle.simple, .advanced] {
            for model in [false, true] {
                let local = c3bView(product: product, local: true, model: model)
                var remote = c3bView(product: product, model: model)
                remote.data.auth = .loggedOut // local auth must not suppress snapshot rows
                let a = remotePanelLayout(views: [local], style: style, now: c3bNow())
                let b = remotePanelLayout(views: [remote], style: style, now: c3bNow())
                expect(a.cards.count == 1 && b.cards.count == 1 && a.cards.first?.height == b.cards.first?.height,
                       "C3-06 \(product)/\(style)/model=\(model): local and remote loggedOut card heights equal")
            }
        }
    }
    for count in 1...4 {
        let views = (0..<count).map { c3bView($0, product: $0 == 0 ? "claude" : "codex") }
        let collapsed = remotePanelLayout(views: views, style: .advanced, now: c3bNow())
        expect(collapsed.moneyRows.isEmpty, "C3-06 Advanced \(count): collapsed history has no drawn money rows")
        c3bValidRects(collapsed, expect, "Advanced collapsed \(count)")
        let layout = remotePanelLayout(views: views, style: .advanced, now: c3bNow(), historyHeight: 231)
        expect(layout.cards.count == count && layout.cards.allSatisfy { $0.minX == 15 && $0.width == 330 },
               "C3-06 Advanced \(count): complete 330pt stack")
        for i in layout.cards.indices.dropFirst() {
            expect(layout.cards[i].minY - layout.cards[i - 1].maxY == 5, "C3-06 Advanced: 5pt inter-card gap")
        }
        expect(layout.moneyRows.count == count, "C3-06 Advanced: separate money row per account")
        if count >= 3 {
            expect(layout.historySelectorRect?.width == 308 && layout.historySelectorRect?.height == 22,
                   "C3-06 Advanced: three/four accounts get own 308pt selector row")
            if let selector = layout.historySelectorRect, let firstMoney = layout.moneyRows.first {
                expect(!selector.intersects(firstMoney), "C3-06 Advanced: selector and money rows do not overlap")
            }
        }
        for i in layout.moneyRows.indices.dropFirst() {
            expect(layout.moneyRows[i].minY - layout.moneyRows[i - 1].minY == 19,
                   "C3-06 Advanced: 19pt per additional money row")
        }
        c3bValidRects(layout, expect, "Advanced \(count)")
    }
    let four = (0..<4).map { c3bView($0, product: $0 == 0 ? "claude" : "codex") }
    let twoLayout = remotePanelLayout(views: Array(four.prefix(2)), style: .advanced, now: c3bNow(), historyHeight: 231)
    let threeLayout = remotePanelLayout(views: Array(four.prefix(3)), style: .advanced, now: c3bNow(), historyHeight: 231)
    let fourLayout = remotePanelLayout(views: four, style: .advanced, now: c3bNow(), historyHeight: 231)
    if threeLayout.cards.count == 3 && fourLayout.cards.count == 4 {
        expect(threeLayout.windowHeight - twoLayout.windowHeight == Double(threeLayout.cards[2].height) + 5 + 22 + 19,
               "C3-06 Advanced: third account grows window by card + gap + selector row + money row")
        expect(fourLayout.windowHeight - threeLayout.windowHeight == Double(fourLayout.cards[3].height) + 5 + 19,
               "C3-06 Advanced: fourth account adds card + gap + money row without second selector row")
    } else { expect(false, "C3-06 Advanced: three/four card layouts available for growth checks") }
}

// Edge vectors use literal expected row/card sizes from UX and the existing
// Advanced contract: Claude 2 quota rows; Codex may have week only + 24pt credits.
// No AdvCard instance: its notice clock is runtime-owned. AdvRow.height itself is
// a pure value property, so these checks also cover the real draw row adapter.
private func c3bC306Edges(_ expect: C3BExpect) {
    let now = c3bNow()
    var onlyWeek = c3bView(product: "codex")
    onlyWeek.data.session = nil; onlyWeek.data.sessionReset = nil
    expect(remoteAdvancedMetrics(onlyWeek) == ["weekly"],
           "C3-06 edge: Codex week-only has no blank session metric")
    let weekKind = remoteAdvancedRowKind(onlyWeek, metric: "weekly", now: now)
    if case .full = weekKind { expect(true, "C3-06 edge: Codex reported week is a full row") }
    else { expect(false, "C3-06 edge: Codex reported week is a full row") }
    expect(remoteAdvancedRowHeight(weekKind) == 62
           && Double(AdvRow(limit: nil, kind: weekKind, credits: nil).height) == 62,
           "C3-06 edge: week row is 62pt in model and real AdvRow")
    expect(remotePanelLayout(views: [onlyWeek], style: .advanced, now: now).cards.first?.height == 157,
           "C3-06 edge: week-only Codex card 157pt including 24pt credits, no blank row")

    // Each expected card includes the unaffected 62pt weekly row. For missing or
    // future asOf both quota rows are 50pt and the 19pt paused notice is present.
    let vectors: [(String, Double, Double?, Date?, Double, Int, Double)] = [
        ("used1", 1, nil, now.addingTimeInterval(-600), 62, 0, 195),
        ("used100", 100, nil, now.addingTimeInterval(-600), 62, 0, 195),
        ("elapsed9min", 20, 5 * 3600 - 9 * 60, now.addingTimeInterval(-600), 62, 0, 195),
        ("elapsed10min", 20, 5 * 3600 - 10 * 60, now.addingTimeInterval(-600), 62, 0, 195),
        ("resetCrossed", 20, nil, now.addingTimeInterval(-600), 50, 0, 183),
        ("missingAsOf", 20, nil, nil, 50, 1, 190),
        ("futureAsOf", 20, nil, now.addingTimeInterval(301), 50, 1, 190)
    ]
    for (name, used, resetAfterSnapshot, asOf, rowHeight, noticeLines, cardHeight) in vectors {
        var remote = c3bView()
        remote.data.session = used; remote.data.asOf = asOf; remote.data.source?.asOf = asOf
        if let interval = resetAfterSnapshot, let asOf = asOf { remote.data.sessionReset = asOf.addingTimeInterval(interval) }
        if name == "resetCrossed" { remote.data.sessionReset = now.addingTimeInterval(-1) }
        var local = remote; local.isLocal = true; local.data.source = nil
        for view in [local, remote] {
            let kind = remoteAdvancedRowKind(view, metric: "session", now: now)
            let expectedKind: Bool
            switch (name, kind) {
            case ("used1", .tooEarly), ("used100", .exhausted), ("elapsed9min", .tooEarly),
                 ("elapsed10min", .full), ("resetCrossed", .stale),
                 ("futureAsOf", .stale): expectedKind = true
            case ("missingAsOf", .inactive): expectedKind = view.isLocal
            case ("missingAsOf", .stale): expectedKind = !view.isLocal
            default: expectedKind = false
            }
            expect(expectedKind, "C3-06 edge \(name)/local=\(view.isLocal): semantic row kind")
            expect(remoteAdvancedRowHeight(kind) == rowHeight
                   && Double(AdvRow(limit: nil, kind: kind, credits: nil).height) == rowHeight,
                   "C3-06 edge \(name): expected \(rowHeight)pt row in model and actual AdvRow")
            expect(remoteAdvancedNoticeLines(view, now: now) == noticeLines,
                   "C3-06 edge \(name): expected paused notice count \(noticeLines)")
            expect(remotePanelLayout(views: [view], style: .advanced, now: now).cards.first?.height == CGFloat(cardHeight),
                   "C3-06 edge \(name)/local=\(view.isLocal): exact \(cardHeight)pt card")
        }
        let a = remotePanelLayout(views: [local], style: .advanced, now: now)
        let b = remotePanelLayout(views: [remote], style: .advanced, now: now)
        expect(a.cards == b.cards && a.windowHeight == b.windowHeight,
               "C3-06 edge \(name): zero geometry difference between same local/remote metrics")
    }
}

private func c3bMenu(_ views: [AccountView], selected: [String: String] = [:], language: String = "en", dark: Bool = false,
                     metrics: [String] = ["session", "weekly", "model"]) -> RemoteMenuPresentation {
    remoteMenuPresentation(views: views, selected: selected, language: language, dark: dark,
                           now: c3bNow(), timeZone: TimeZone(secondsFromGMT: 0)!, metrics: metrics)
}

private func c3bC308(_ expect: C3BExpect) {
    let remote = c3bView(), local = c3bView(1, product: "codex", local: true), other = c3bView(2, product: "codex")
    let defaults = c3bMenu([remote, local, other])
    expect(c3bMenu([]).lines.isEmpty && c3bMenu([]).tooltip.isEmpty,
           "C3-08: no visible accounts creates no placeholder product rows")
    expect(defaults.lines.map { $0.product } == ["claude", "codex"]
           && defaults.lines.map { $0.historyKey } == [remote.historyKey, local.historyKey],
           "C3-08: one menu row per product, VPS Claude and local Codex by default")
    let selected = ["codex": other.label!]
    let chosen = c3bMenu([remote, local, other], selected: selected)
    expect(chosen.lines.last?.historyKey == other.historyKey && chosen.lines.last?.session == other.data.session
           && chosen.lines.last?.weekly == other.data.weekly, "C3-08: menuAccount changes identity AND displayed numbers")
    expect(c3bMenu([remote, local], selected: selected).lines.last?.historyKey == local.historyKey,
           "C3-08: hidden/disappeared selected account falls back to local")
    expect(c3bMenu([other], selected: ["codex": "missing"]).lines.first?.historyKey == other.historyKey,
           "C3-08: no local identity falls back to first visible account")
    for state in [RemoteCardState.stale, .signInRequired, .offline, .syncStalled, .signedOut, .serviceWait, .fresh] {
        for status in ["expired", "signed_out"] {
            var view = c3bView(state: state); view.data.source?.status = status; view.data.auth = .loggedOut
            let model = c3bMenu([view])
            let expectedAlpha = state == .fresh || state == .serviceWait ? 1.0 : 0.4
            guard let line = model.lines.first else { expect(false, "C3-08: remote \(state)/\(status) retains last values"); continue }
            expect(line.session == view.data.session && line.weekly == view.data.weekly,
                   "C3-08 \(state)/\(status): remote loggedOut never hides last values")
            expect(line.sessionAlpha == expectedAlpha && line.weeklyAlpha == expectedAlpha && line.punctuationAlpha == expectedAlpha,
                   "C3-08 \(state)/\(status): numeric and punctuation alpha \(expectedAlpha)")
        }
    }
    var reset = c3bView(); reset.data.sessionReset = c3bNow().addingTimeInterval(-1)
    let partial = c3bMenu([reset]).lines.first
    expect(partial?.sessionAlpha == 0.4 && partial?.weeklyAlpha == 1 && partial?.punctuationAlpha == 1,
           "C3-08: a reset session dims alone; punctuation stays bright with fresh week")
    expect(c3bMenu([reset], metrics: ["session"]).lines.first?.punctuationAlpha == 0.4,
           "C3-08: selecting only reset session dims punctuation despite unselected fresh week")
    expect(c3bMenu([reset], metrics: ["weekly"]).lines.first?.punctuationAlpha == 1,
           "C3-08: selecting only fresh week keeps punctuation bright despite unselected reset session")
    var wait = c3bView(state: .serviceWait); wait.data.asOf = c3bNow().addingTimeInterval(-86400)
    expect(c3bMenu([wait]).lines.first?.sessionAlpha == 0.4, "C3-08: state4 stale metric still dims")
    for language in ["ru", "en"] {
        var labelled = remote; labelled.caption = "Работа %@%n"
        for dark in [false, true] {
            let model = c3bMenu([labelled, local], language: language, dark: dark)
            let source = language == "en" ? "data from vps at 15:50" : "данные с vps от 15:50"
            expect(model.dark == dark && model.lines.count == 2 && model.tooltip.components(separatedBy: "\n").count == 2,
                   "C3-08 \(language)/dark=\(dark): explicit button theme and one tooltip line per product")
            expect(model.tooltip.contains(labelled.caption) && model.tooltip.lowercased().contains(source)
                   && model.lines.first?.caption == labelled.caption,
                   "C3-08: tooltip retains literal caption plus complete source/time")
        }
    }
}

private func c3bSettings(_ views: [AccountView], hidden: Set<String> = [], phase: SyncPhase = .on,
                         advanced: Bool = false, language: String = "en") -> RemoteSettingsModel {
    remoteSettingsModel(views: views, hidden: hidden, polling: ["claude": false, "codex": true],
                        sync: ReaderSyncState(phase: phase), advanced: advanced, language: language)
}

private func c3bC309(_ expect: C3BExpect) {
    let remote = c3bView(), a = c3bView(1, product: "codex", local: true), b = c3bView(2, product: "codex")
    var unassigned = c3bView(3, product: "codex")
    unassigned.label = nil; unassigned.historyKey = "u:codex"; unassigned.caption = ""; unassigned.machines = ["vps", "old"]
    let views = [remote, a, b, unassigned]
    for language in ["ru", "en"] {
        for advanced in [false, true] {
            let model = c3bSettings(views, advanced: advanced, language: language)
            expect(model.pollingTitle == (language == "en" ? "POLL ON THIS COMPUTER" : "ОПРАШИВАТЬ НА ЭТОМ КОМПЬЮТЕРЕ"),
                   "C3-09: N2 exact polling heading")
            expect(model.pollingEnabled == ["claude": false, "codex": true] && model.accounts.first?.visible == true,
                   "C3-09: N3 disabled local polling preserves visible remote Claude, no implicit migration hide")
            expect(model.showsAccounts && model.showsGitHub && !model.showsV10 && model.accounts.count == 4,
                   "C3-09 \(language)/advanced=\(advanced): accounts and GitHub available in both views")
            expect(model.menuProducts == ["codex"], "C3-09: N4 chooser only for product with at least two visible labelled accounts")
            let unknown = model.accounts.first { $0.historyKey == unassigned.historyKey }
            expect(unknown?.editable == false && unknown?.visible == true
                   && unknown?.title == (language == "en" ? "Codex · unlabelled account" : "Codex · аккаунт не указан")
                   && unknown?.subtitle.contains("vps") == true && unknown?.subtitle.contains("old") == true,
                   "C3-09: unassigned group has machines/visibility, no caption editor")
            expect(model.accounts.first?.editable == true
                   && model.accounts.first?.subtitle.contains(language == "en" ? "not signed in here" : "без входа здесь") == true,
                   "C3-09: labelled remote row provides editor and sign-in location")
        }
        let hidden = c3bSettings(views, hidden: [b.historyKey, unassigned.historyKey], language: language)
        expect(hidden.accounts.count == 4 && hidden.accounts.first { $0.historyKey == b.historyKey }?.visible == false
               && !hidden.menuProducts.contains("codex"), "C3-09: N1 hidden rows remain manageable and leave menu choices")
        let newAccount = c3bSettings(views + [c3bView(4)], hidden: [b.historyKey])
        expect(newAccount.accounts.last?.visible == true, "C3-09: N1 newly discovered account defaults visible")
        for phase in [SyncPhase.off, .revoked, .awaitingCode] {
            let signedOut = c3bSettings([], phase: phase, language: language)
            expect(signedOut.showsV10 && signedOut.showsGitHub && !signedOut.showsAccounts
                   && signedOut.v10Text == (language == "en" ? "Accounts from other computers appear after GitHub sign-in ›" : "Аккаунты с других компьютеров — после входа в GitHub ›"),
                   "C3-09: V10 \(phase)/\(language) points to GitHub without empty accounts block")
        }
        expect(c3bSettings([remote], phase: .off, language: language).showsAccounts,
               "C3-09: cached remote accounts keep management block visible without GitHub login")
        expect(c3bSettings([], phase: .on, language: language).showsAccounts,
               "C3-09: signed-in initial read keeps accounts block without invented placeholder rows")
    }
    let original = "Команда"
    let committed = remoteCaptionEdit(original: original, draft: "Работа %n", command: .enter)
    expect(committed.committed && committed.value == "Работа %n" && committed.text == "Работа %n"
           && committed.count == 9, "C3-09: Enter commits literal text and matching counter")
    let cancelled = remoteCaptionEdit(original: original, draft: "Новая подпись", command: .escape)
    expect(!cancelled.committed && cancelled.value == original && cancelled.text == original,
           "C3-09: Escape discards draft and restores original")
    let reset = remoteCaptionEdit(original: original, draft: "draft", command: .reset)
    let empty = remoteCaptionEdit(original: original, draft: "", command: .enter)
    expect(reset.committed && reset.value == nil && empty.committed && empty.value == nil,
           "C3-09: Reset and empty Enter restore default caption")
    for text in [String(repeating: "Я", count: 32), String(repeating: "🙂", count: 32)] {
        expect(remoteCaptionInput(text) == text && remoteCaptionInput(text + "X") == text,
               "C3-09: 32 Unicode scalar limit keeps valid boundary and excludes 33rd")
        let edit = remoteCaptionEdit(original: nil, draft: text + "X", command: .enter)
        expect(edit.value == text && edit.text == text && edit.count == 32 && edit.committed,
               "C3-09: editor counter and committed caption share 32-character boundary")
    }
    expect(remoteCaptionInput("e\u{301}") == "é" && remoteCaptionInput("A\nB\r\t\u{1B}\u{202E}\u{200B}C") == "ABC",
           "C3-09/T14: NFC normalization and Cc/Cf removal")
    for bad in ["user@example.invalid", "folder/name", "folder\\name", "user＠example.invalid", "folder／name", "folder＼name",
                String(repeating: "a", count: 40) + "@blocked"] {
        expect(remoteCaptionInput(bad).isEmpty, "C3-09/T14: unsafe caption rejected whole before truncation")
        let rejected = remoteCaptionEdit(original: original, draft: bad, command: .enter)
        expect(!rejected.committed && rejected.value == original && rejected.text == original,
               "C3-09/T14: rejected nonempty Enter preserves original instead of resetting it")
    }
    expect(remoteCaptionInput("%n") == "%n" && remoteCaptionInput("%@%n").isEmpty,
           "C3-09/T14: safe percent text is literal; at-sign is rejected even inside format marker")
}

func runRemoteLimitsC3BSelfTests() -> Int {
    var checks = 0, failures = 0
    func expect(_ ok: Bool, _ message: String) {
        checks += 1; if !ok { failures += 1 }
        print("\(ok ? "OK" : "FAIL") \(message)")
    }
    c3bC306(expect); c3bC306Edges(expect); c3bC308(expect); c3bC309(expect)
    print("\(failures == 0 ? "OK" : "FAIL") C3B model tests: \(checks) checks; \(failures) failures")
    return failures
}
