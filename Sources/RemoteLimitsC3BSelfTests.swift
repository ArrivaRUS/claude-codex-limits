import Foundation

// C3 part B: independent RED model tests, 2026-10-28.
// Sources: plans C3, test-plan C3-06/08/09, UX §§6/7/9/10/11,
// sync-protocol writer sanitization (T14), lessons 004/006/013/014.
// Entry must run BEFORE NSApplication.shared. No AppKit, filesystem,
// credentials, history singleton, refresh or network. The D7 legacy notice
// reads localization from the caller's pre-installed in-memory defaults.
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

// C4 UI debt RED contracts (2026-10-30), layered over the C3-A legacy model:
// RemoteCardPresentation adds simpleMachines: String. C3-B simpleTitle contains
// only the short product/custom L; Advanced title/suffix remain unchanged.
// func remoteFittedSimpleMachines(_ text: String, availableWidth: Double,
//   measureCondensed: (String) -> Double) -> String
// struct RemoteSettingsErrorPresentation {
//   var text: String; var lines: [String]; var height: Double; var accessibilityValue: String
// }
// func remoteSettingsErrorPresentation(_ text: String, availableWidth: Double,
//   lineHeight: Double = 14, measureWidth: (String) -> Double) -> RemoteSettingsErrorPresentation
// Wrapping preserves full text/AX, displays at most three measured lines, and
// reports 14pt per visible line (empty text = 0). Runtime grows its existing
// short-error block by height - 14, preserving its existing padding.
// func remoteAdvancedHeaderRightBoundary(cardMaxX: Double) -> Double
// Right inset 28pt: Advanced card x15/w330 ends at345, header text ends317.
// Review repairs R1/R2, RED before implementation:
// func remoteHistorySelectorTitle(_ raw: AccountView, language: String) -> String
// Actual historySelectorLayout.titles and segment tooltips share this helper;
// default short product + machines, custom L unchanged, u: localized.
// func remoteFittedStatusLine(_ view: AccountView, presentation: RemoteCardPresentation,
//   language: String, narrow: Bool = true, now: Date, timeZone: TimeZone,
//   availableWidth: Double, measure: (String) -> Double) -> String
// Preserve presented manual/sync state. Narrow offline fitting shortens only the
// machine first (8 + ellipsis, then fewer characters if needed), preserving its
// date/time and chevron; final tail fallback is allowed only if that cannot fit.
// These tests do not define production stand-ins and are RED before helpers exist.

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
        (1, false, 183, 317, [CGRect(x: 16, y: 58, width: 328, height: 183)]),
        (2, false, 183, 317, [CGRect(x: 16, y: 58, width: 158, height: 183), CGRect(x: 186, y: 58, width: 158, height: 183)]),
        (3, false, 183, 512, [CGRect(x: 16, y: 58, width: 158, height: 183), CGRect(x: 186, y: 58, width: 158, height: 183), CGRect(x: 16, y: 253, width: 328, height: 183)]),
        (4, false, 183, 512, [CGRect(x: 16, y: 58, width: 158, height: 183), CGRect(x: 186, y: 58, width: 158, height: 183), CGRect(x: 16, y: 253, width: 158, height: 183), CGRect(x: 186, y: 253, width: 158, height: 183)]),
        (1, true, 198, 332, [CGRect(x: 16, y: 58, width: 328, height: 198)]),
        (2, true, 198, 332, [CGRect(x: 16, y: 58, width: 158, height: 198), CGRect(x: 186, y: 58, width: 158, height: 198)]),
        (3, true, 198, 542, [CGRect(x: 16, y: 58, width: 158, height: 198), CGRect(x: 186, y: 58, width: 158, height: 198), CGRect(x: 16, y: 268, width: 328, height: 198)]),
        (4, true, 198, 542, [CGRect(x: 16, y: 58, width: 158, height: 198), CGRect(x: 186, y: 58, width: 158, height: 198), CGRect(x: 16, y: 268, width: 158, height: 198), CGRect(x: 186, y: 268, width: 158, height: 198)])
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
                var local = c3bView(product: product, local: true, model: model)
                local.data.auth = .loggedOut
                var remote = c3bView(product: product, model: model)
                remote.data.auth = .loggedOut // local auth must not suppress snapshot rows
                let a = remotePanelLayout(views: [local], style: style, now: c3bNow())
                let b = remotePanelLayout(views: [remote], style: style, now: c3bNow())
                expect(a.cards.count == 1 && b.cards.count == 1 && local.data.auth == .loggedOut && remote.data.auth == .loggedOut,
                       "C3-06 \(product)/\(style)/model=\(model): both loggedOut fixtures retain a card")
                if style == .advanced {
                    expect(remoteAdvancedRowKind(local, metric: "weekly", now: c3bNow()) == .stale
                           && remoteAdvancedRowKind(remote, metric: "weekly", now: c3bNow()) == .full,
                           "C3-06 loggedOut: local sign-in problem pauses pace; remote last snapshot remains usable")
                }
            }
        }
    }
    for count in 1...4 {
        let views = (0..<count).map { c3bView($0, product: $0 == 0 ? "claude" : "codex") }
        let collapsed = remotePanelLayout(views: views, style: .advanced, now: c3bNow())
        expect(collapsed.moneyRows.isEmpty && collapsed.historySelectorRect == nil, "C3-06 Advanced \(count): collapsed history has no money rows or selector")
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
    for state in [RemoteCardState.stale, .signInRequired, .offline, .syncStalled, .serviceWait, .fresh] {
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
        var labelled = remote; labelled.caption = "Работа %d %s %n {0} $(x) %%"
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

// C3-B review regressions C3-15…26. Every input is synthetic and every clock
// explicit. These contracts run before AppKit; no runtime callbacks are invoked.
private func c3bReviewRegressions(_ expect: C3BExpect) {
    let now = c3bNow(), zone = TimeZone(secondsFromGMT: 0)!
    var historical = c3bView(local: true)
    historical.data.asOf = now.addingTimeInterval(-5 * 3600)
    historical.data.weekly = 41
    historical.data.weeklyReset = historical.data.asOf!.addingTimeInterval(84 * 3600)
    let historicalKind = remoteAdvancedRowKind(historical, metric: "weekly", now: now)
    let historicalPace = snapshotWindowPace(used: 41, reset: historical.data.weeklyReset, windowH: 168, asOf: historical.data.asOf)
    expect(metricIsStale(historical.data, metric: "weekly", now: now) && historicalKind == .full,
           "C3-15/A1: local five-hour-old snapshot dims without losing full 62pt weekly row")
    expect(remoteAdvancedRowHeight(historicalKind) == 62 && historicalPace?.projectedPct == 82,
           "C3-15/A1: 41% at half-week projects 82% from asOf despite current age")
    let historicalRow = AdvRow(limit: PacedLimit(id: "weekly", name: "", pace: historicalPace, color: 0, used: 41), kind: historicalKind, credits: nil)
    expect(advVerdict(historicalRow, data: historical.data, now: now, language: "en") == "Snapshot forecast: 82%",
           "C3-15/A1: historical local verdict retains snapshot forecast")

    var legacyClaude = c3bView(local: true), legacyCodex = c3bView(1, product: "codex", local: true)
    legacyClaude.label = nil; legacyCodex.label = nil
    legacyClaude.historyKey = "l:legacy"; legacyCodex.historyKey = "l:legacy"
    let claudeID = remoteAccountID(legacyClaude), codexID = remoteAccountID(legacyCodex)
    var accountsByID: [String: AccountView] = [:]
    accountsByID[claudeID] = legacyClaude; accountsByID[codexID] = legacyCodex
    var pricesByID: [String: Double] = [:]
    pricesByID[claudeID] = 200; pricesByID[codexID] = 20
    expect(claudeID != codexID && accountsByID[codexID]?.product == "codex" && accountsByID[claudeID]?.product == "claude",
           "C3-16/A2: product-scoped l:legacy IDs select independent cached local accounts")
    expect(pricesByID[claudeID] == 200 && pricesByID[codexID] == 20,
           "C3-16/A2: legacy products do not share subscription price overrides")
    let legacyViews = [legacyClaude, legacyCodex]
    expect(selectedHistoryAccount(views: legacyViews, selectedID: codexID, product: "claude")?.product == "codex",
           "C3-16/A2: live history selection adapter resolves compound Codex legacy ID")
    expect(selectedHistoryAccount(views: legacyViews, selectedID: "l:legacy", product: "codex")?.product == "codex",
           "C3-16/A2: ambiguous persisted legacy selection falls back within selected product")
    let claudePrice = accountSubscriptionPrice(legacyClaude, overrides: pricesByID, localFallback: (999, true))
    let codexPrice = accountSubscriptionPrice(legacyCodex, overrides: pricesByID, localFallback: (999, true))
    expect(claudePrice.usd == 200 && codexPrice.usd == 20 && !claudePrice.estimated && !codexPrice.estimated,
           "C3-16/A2: live pricing adapter keeps compound overrides independent across products")

    var remote = c3bView()
    remote.data.source?.freshUntil = now.addingTimeInterval(60)
    remote.data.sessionReset = now.addingTimeInterval(30)
    expect(remoteMenuRefreshDeadline(views: [remote], now: now) == now.addingTimeInterval(30),
           "C3-17/A3: tray refresh deadline chooses reset before source freshness boundary")
    remote.data.sessionReset = now.addingTimeInterval(600)
    expect(remoteMenuRefreshDeadline(views: [remote], now: now).map { abs($0.timeIntervalSince(now) - 60.001) < 0.00001 } == true,
           "C3-17/A3: tray refresh deadline follows source horizon without a local poll")
    expect(remoteMenuRefreshDeadline(views: [], now: now) == nil,
           "C3-17/A3: no accounts require no freshness timer")
    var noValues = c3bView(); noValues.data = LimitData(present: false)
    expect(remoteMenuRefreshDeadline(views: [noValues], now: now) == nil,
           "C3-17/A3: account without values or timestamps needs no freshness timer")
    let exactBoundary = now.addingTimeInterval(60)
    expect(!metricIsStale(remote.data, metric: "weekly", now: exactBoundary)
           && metricIsStale(remote.data, metric: "weekly", now: exactBoundary.addingTimeInterval(0.001)),
           "C3-17/A3: strict source horizon changes menu freshness immediately after its deadline")

    let hostile = "A\u{1B}\u{202E}\u{200B}\u{2028}\u{2029}" + String(repeating: "Z", count: 500)
    // First pass through the real wire reader: captions have the C5 exception.
    let captionLabel = "c318000000000000"
    let object: [String: Any] = ["schema": 1, "machine": ["id": "c318-vps", "name": "vps"],
        "updated": "2026-10-12T16:00:00Z", "days": [String: Any](),
        "captions": [captionLabel: ["text": hostile]],
        "accounts": [["product": "claude", "label": captionLabel, "status": "ok", "asOf": "2026-10-12T15:43:00Z"]]]
    if let bytes = try? JSONSerialization.data(withJSONObject: object) {
        let cache = mergeV11(["machine-c318-vps.json": String(decoding: bytes, as: UTF8.self)], excluding: "c318-mac", now: now)
        let wireViews = resolveAccounts(local: (LimitData(present: false), LimitData(present: false)), localIds: [:],
            remote: cache, hidden: [], menu: [:], sync: ReaderSyncState(phase: .on), now: now)
        let expected = "A" + String(repeating: "Z", count: 31)
        expect(cache.captions?[captionLabel]?.text == expected && wireViews.first?.caption == expected
               && c3bMenu(wireViews).lines.first?.caption == expected && c3bSettings(wireViews).accounts.first?.title == expected,
               "C3-18/D1: wire caption cleaned to 32 scalars by C5 before menu/settings presentation")
    } else { expect(false, "C3-18/D1: valid wire-caption JSON") }
    // A hand-built legacy/cache view can bypass the reader. Preserve the wider
    // presentation guard (also used for generated default captions), without
    // treating this bypass as wire acceptance of a 128-scalar custom caption.
    var unsafe = c3bView()
    unsafe.caption = hostile; unsafe.machines = [hostile]
    unsafe.data.plan = hostile; unsafe.tier = nil
    unsafe.data.source?.machineName = hostile; unsafe.data.source?.statusMachineName = hostile
    let menu = c3bMenu([unsafe]), settings = c3bSettings([unsafe])
    let strings = [menu.tooltip, menu.lines.first?.caption ?? "", menu.lines.first?.sourceLine ?? "",
                   settings.accounts.first?.title ?? "", settings.accounts.first?.subtitle ?? "", remoteDefaultCaption(unsafe)]
    expect(strings.allSatisfy { value in !value.unicodeScalars.contains { scalar in
        [.control, .format, .surrogate, .lineSeparator, .paragraphSeparator].contains(scalar.properties.generalCategory)
    } }, "C3-18/D1: snapshot caption/machines/plan/source never leak controls or separators into presentation")
    expect(strings.allSatisfy { $0.unicodeScalars.count < 400 }
           && (menu.lines.first?.caption.unicodeScalars.count ?? 0) <= 128,
           "C3-18/D1: bypassed legacy/cache strings remain bounded in menu/settings/default captions")
    let safe = remoteSanitizedView(unsafe)
    expect(remoteSanitizedView(safe).caption == safe.caption && remoteSanitizedView(safe).machines == safe.machines,
           "C3-18/D1: sanitizing presentation strings twice is stable")

    var unknown = c3bView(8, product: "codex")
    unknown.label = nil; unknown.historyKey = "u:codex"; unknown.data = LimitData(present: false)
    let two = [c3bView(), c3bView(1, product: "codex")]
    let base = remotePanelLayout(views: two, style: .advanced, now: now)
    let withUnknown = remotePanelLayout(views: two + [unknown], style: .advanced, now: now)
    expect(withUnknown.cards == base.cards && withUnknown.windowHeight == base.windowHeight && withUnknown.historySelectorRect == nil,
           "C3-19/D2: unassigned group adds no quota card or collapsed history space")
    let unknownOnly = remotePanelLayout(views: [unknown], style: .advanced, now: now, historyHeight: 231)
    expect(unknownOnly.cards.isEmpty && unknownOnly.moneyRows.count == 1,
           "C3-19/D2/V10: unassigned group retains required expanded history money row")
    for count in [3, 4] {
        let views = (0..<count).map { c3bView($0) }
        let collapsed = remotePanelLayout(views: views, style: .advanced, now: now, historyHeight: 35)
        expect(collapsed.historySelectorRect == nil && collapsed.moneyRows.isEmpty,
               "C3-20/D3: collapsed history for \(count) accounts has no selector or money rows")
    }
    for state in [RemoteCardState.stale, .signInRequired, .offline, .syncStalled] {
        var view = c3bView(state: state)
        expect(remoteAdvancedRowKind(view, metric: "weekly", now: now) == .full,
               "C3-21/N3: foreign state \(state.rawValue) keeps full Advanced row while the snapshot is within V4")
        view.isLocal = true; view.data.source = nil
        expect(remoteAdvancedRowKind(view, metric: "weekly", now: now) == .full,
               "C3-21/A1: remote fixture state \(state.rawValue) does not override healthy local row classification")
    }
    expect(remoteAdvancedRowKind(c3bView(state: .serviceWait), metric: "weekly", now: now) == .full,
           "C3-21/D4: fresh source service wait preserves full pace row")

    var localScoped = c3bView(local: true, model: true)
    expect(remoteSimpleShowsScopedRow(localScoped, now: now), "C3-22/A5: healthy local scoped row reserves 15pt")
    localScoped.data.auth = .loggedOut
    expect(!remoteSimpleShowsScopedRow(localScoped, now: now)
           && remotePanelLayout(views: [localScoped], style: .simple, now: now).cards.first?.height == 183,
           "C3-22/A5: local sign-in problem hides model row and removes its 15pt")
    localScoped.data.auth = .ok; localScoped.data.asOf = now.addingTimeInterval(-5 * 3600)
    expect(!remoteSimpleShowsScopedRow(localScoped, now: now), "C3-22/A5: stale local card does not reserve hidden scoped row")
    var remoteScoped = c3bView(model: true, state: .stale)
    remoteScoped.data.source?.freshUntil = now.addingTimeInterval(-1)
    expect(remoteSimpleShowsScopedRow(remoteScoped, now: now), "C3-22/V13: stale foreign model row remains visible and grey")

    expect(remoteCaptionInput("A\u{2028}B\u{2029}C") == "ABC",
           "C3-23/A6: line and paragraph separators are stripped from one-line caption input")
    let edit = remoteCaptionEdit(original: "Old", draft: "A\u{2028}B\u{2029}C", command: .enter)
    expect(edit.committed && edit.value == "ABC" && edit.count == 3,
           "C3-23/A6: separator-free committed caption and counter agree")
    var labelled = c3bView(2, product: "codex")
    labelled.label = "label-identity"; labelled.historyKey = "different-history-key"
    let hidden = c3bSettings([two[1], labelled], hidden: ["label-identity"])
    expect(hidden.accounts.last?.visible == false && hidden.menuProducts.isEmpty,
           "C3-24/D6: hiddenAccounts uses C2 label when label differs from historyKey")
    expect(!remoteAccountIsHidden(labelled, hidden: ["different-history-key"])
           && remoteAccountIsHidden(legacyClaude, hidden: ["l:legacy"]),
           "C3-24/D6: historyKey fallback applies to legacy identity, not labelled account")
    expect(remoteAccountIsHidden(legacyClaude, hidden: [claudeID])
           && !remoteAccountIsHidden(legacyCodex, hidden: [claudeID]),
           "C3-24/A2: hiding product-scoped legacy Claude leaves legacy Codex visible")
    expect(remoteAccountIsHidden(unknown, hidden: ["codex|u:codex"])
           && !remoteAccountIsHidden(unknown, hidden: ["claude|u:codex"]),
           "C3-24/A2: unassigned group honors product-scoped hidden identity")
    var noTime = c3bView(local: true); noTime.data.asOf = nil
    expect(remoteAdvancedNoticeLines(noTime, now: now) == 1 && !limitSnapshotNotice(noTime.data, now: now).isEmpty,
           "C3-25/D7: local nil asOf preserves existing paused notice, with no fabricated timestamp")

    for phase in [SyncPhase.off, .revoked, .awaitingCode] {
        for view in [c3bView(), c3bView(1, product: "codex")] {
            let sync = ReaderSyncState(phase: phase)
            let presented = remotePresentationView(view, sync: sync, now: now)
            expect(presented.state == .signedOut && presented.data.session == nil && presented.data.weekly == nil && presented.data.scoped == nil,
                   "C3-26/V4: reader \(phase) clears values on every foreign account")
            expect(remoteAdvancedNoticeLines(presented, now: now) == 0,
                   "C3-26/V3: foreign state7 has no invalid-time amber notice")
            for language in ["ru", "en"] {
                let p = remotePresentationCard(view, sync: sync, language: language, narrow: true, now: now, timeZone: zone)
                expect(p.sourceLine == (language == "ru" ? "Нет данных с vps" : "No data from vps") && !p.showsValues,
                       "C3-26/V1: state7 keeps no-data source line separate from GitHub action")
                if phase == .revoked {
                    expect(p.statusLine == (language == "ru" ? "Войдите заново ›" : "Sign in again ›"),
                           "C3-26/V2: revoked narrow action uses approved complete short text")
                }
            }
        }
    }
    let disconnected = ReaderSyncState(phase: .off)
    let noNumbers = c3bMenu([c3bView(), c3bView(1, product: "codex")].map {
        remotePresentationView($0, sync: disconnected, now: now)
    })
    expect(noNumbers.lines.count == 2 && noNumbers.lines.allSatisfy { $0.session == nil && $0.weekly == nil && $0.scoped == nil },
           "C3-26/Q3: reader state7 menu retains product icons without cached numbers")
    let connectedLocal = remotePresentationView(c3bView(local: true), sync: disconnected, now: now)
    expect(connectedLocal.state == .fresh && connectedLocal.data.session == 20 && connectedLocal.data.weekly == 40,
           "C3-26/V4: GitHub reader sign-out preserves this-machine signed-in values")
    let warning = ReaderSyncState(phase: .on, warning: "Fixture warning")
    expect([c3bView(), c3bView(1, product: "codex")].allSatisfy {
        remotePresentationView($0, sync: warning, now: now).state == .syncStalled
    }, "C3-26/V4: sync warning governs every foreign account, including fresh neighbouring fixtures")
    let poll = RemoteManualPhase.pollAllowed(now.addingTimeInterval(900))
    let foreignPoll = remotePresentationCard(c3bView(), sync: ReaderSyncState(phase: .on), language: "en", narrow: true, now: now, timeZone: zone, manual: poll)
    expect(!foreignPoll.statusLine.contains("Poll allowed"), "C3-26/V8: provider pollAllowed status never appears on foreign account")
    var local = c3bView(local: true)
    let localSource = remotePresentationCard(local, sync: ReaderSyncState(phase: .on), language: "ru", narrow: false, now: now, timeZone: zone)
    expect(localSource.sourceLine == "Данные 15:50", "C3-26/V7: this-machine snapshot source omits remote machine phrase")
    local.isLocal = false; local.data.source = c3bView().data.source
    let short = remotePresentationSourceLine(local, language: "ru", narrow: true, now: now, timeZone: zone)
    expect(short == "Данные с vps от 15:50", "C3-26/Q1: narrow today retains full form until measured width requires shortening")
    local.data.source?.machineName = "build-machine-with-a-long-name"
    let shortened = remotePresentationSourceLine(local, language: "ru", narrow: true, now: now, timeZone: zone, compact: true, machineLimit: 8)
    expect(shortened == "С build-ma… от 15:50", "C3-26/V5/Q1: measured-overflow steps preserve time and shorten machine to eight characters plus ellipsis")
    let fittedShort = remoteFittedSourceLine(c3bView(), language: "ru", now: now, timeZone: zone, availableWidth: 130,
        measure: { $0 == "Данные с vps от 15:50" ? 129 : 200 })
    expect(fittedShort == "Данные с vps от 15:50", "C3-26/Q1: measured full today form fits 130pt and remains full")
    let fittedLong = remoteFittedSourceLine(local, language: "ru", now: now, timeZone: zone, availableWidth: 130,
        measure: { $0.hasPrefix("Данные ") ? 150 : 120 })
    expect(fittedLong == "С build-ma… от 15:50", "C3-26/Q1: measured long full form overflows 130pt and uses complete short form")
    // Distinguish every step: measuring an already-shortened full form first
    // would incorrectly keep "Данные с" because that form is only 120pt here.
    var measuredView = local; measuredView.data.source?.machineName = "build-machine"
    for compactWidth in [120.0, 150.0] {
        var measurements: [String] = []
        let fitted = remoteFittedSourceLine(measuredView, language: "ru", now: now, timeZone: zone, availableWidth: 130) { text in
            measurements.append(text)
            switch text {
            case "Данные с build-machine от 15:50": return 150
            case "С build-machine от 15:50": return compactWidth
            case "Данные с build-ma… от 15:50", "С build-ma… от 15:50": return 120
            default: return 1000
            }
        }
        expect(Array(measurements.prefix(2)) == ["Данные с build-machine от 15:50", "С build-machine от 15:50"]
               && measurements.contains("С build-ma… от 15:50") && fitted == "С build-ma… от 15:50",
               "C3-26/Q1: original full and compact precede measured machine fitting (\(compactWidth)pt)")
    }
    var pro = c3bView(product: "codex"); pro.data.plan = "Pro"
    let snapshotPrice = accountSubscriptionPrice(pro, overrides: [:], localFallback: (200, true))
    expect(snapshotPrice.usd == 200 && !snapshotPrice.estimated,
           "C3-26/V17/V23: known Pro snapshot keeps exact price without approximation across plan capitalization")
    pro.data.plan = nil
    expect(accountSubscriptionPrice(pro, overrides: [:], localFallback: (200, true)).estimated,
           "C3-26/V17: missing snapshot plan retains estimated fallback")
    for state in [RemoteCardState.signInRequired, .offline, .syncStalled] {
        var view = c3bView(state: state)
        expect(!metricIsStale(view.data, metric: "weekly", now: now),
               "C3-26/V12: source state \(state.rawValue) alone does not dim in-horizon body")
        view.data.source?.freshUntil = now.addingTimeInterval(-1)
        expect(metricIsStale(view.data, metric: "weekly", now: now),
               "C3-26/V12: source state \(state.rawValue) dims body after freshness horizon")
    }
    var desktop = c3bView(4); desktop.caption = "Claude Max 20x · desktop"
    var vps = c3bView(3); vps.caption = "Claude Max 20x · vps"
    let localCodex = c3bView(2, product: "codex", local: true)
    let remoteCodex = c3bView(1, product: "codex")
    expect(remoteMissingSetupProduct(visible: [localCodex], all: [localCodex], polling: ["claude": true, "codex": true]) == "claude",
           "C3-26/A4: single local Codex restores enabled missing Claude setup slot")
    expect(remoteMissingSetupProduct(visible: [localCodex], all: [localCodex], polling: ["claude": false, "codex": true]) == nil,
           "C3-26/A4: disabled missing product receives no setup slot")
    let localClaudeForSetup = c3bView(local: true)
    expect(remoteMissingSetupProduct(visible: [localCodex], all: [localClaudeForSetup, localCodex], polling: ["claude": true, "codex": true]) == nil,
           "C3-26/A4: hidden existing Claude stays hidden instead of reappearing as setup slot")
    expect(remoteMissingSetupProduct(visible: [remoteCodex], all: [remoteCodex], polling: ["claude": true, "codex": true]) == nil,
           "C3-26/A4: foreign-only scene creates no local missing-product placeholder")
    for language in ["ru", "en"] {
        let sorted = remoteSortedPresentationViews(views: [remoteCodex, vps, localCodex, desktop], language: language)
        expect(sorted.map(remoteAccountID) == [desktop, vps, localCodex, remoteCodex].map(remoteAccountID),
               "C3-26/V20: \(language) order is product, local sign-in, caption, identity")
    }
}


// C3-27: the native Auto tooltip keeps its full accessible interval wording.
// Both products intentionally share the legacy history key: participation and
// display names are product-scoped and independent of account labels/visibility.
private func c3bC327(_ expect: C3BExpect) {
    var claude = c3bView(local: true), codex = c3bView(1, product: "codex", local: true)
    claude.label = nil; codex.label = nil
    claude.historyKey = "l:legacy"; codex.historyKey = "l:legacy"
    let local = [claude, codex], both: Set<String> = ["claude", "codex"]
    let intervals: [String: TimeInterval] = ["claude": 900, "codex": 14400]
    let foreign = c3bView(2, product: "claude")
    for language in ["ru", "en"] {
        let en = language == "en", autoTitle = en ? "Auto" : "Авто"
        let first = en ? "15 minutes" : "15 минут", second = en ? "4 hours" : "4 часа"
        let footer = remoteAutoFooter(views: local, enabled: both, intervals: intervals, language: language)
        expect(footer.products == ["claude", "codex"] && !footer.noSubscriptions,
               "C3-27 \(language): both enabled local legacy products participate in Auto")
        let tooltip = remotePollTooltip(0, views: local, enabled: both, intervals: intervals, auto: true, language: language)
        expect(tooltip == autoTitle + ": Claude Code → " + first + "; Codex → " + second,
               "C3-27 \(language): native Auto tooltip preserves full titles for Claude 900 and Codex 14400")
        expect(remotePollTooltip(900, views: local, enabled: both, intervals: intervals, auto: true, language: language)
               == first + "\n" + autoTitle + ": Claude Code",
               "C3-27 \(language): 15-minute segment names only its enabled Claude poll")
        expect(remotePollTooltip(14400, views: local, enabled: both, intervals: intervals, auto: true, language: language)
               == second + "\n" + autoTitle + ": Codex",
               "C3-27 \(language): four-hour segment names only its enabled Codex poll")

        let titles: [(TimeInterval, String)] = en
            ? [(900, "15 minutes"), (1800, "30 minutes"), (3600, "1 hour"), (14400, "4 hours")]
            : [(900, "15 минут"), (1800, "30 минут"), (3600, "1 час"), (14400, "4 часа")]
        for (seconds, title) in titles {
            let shared = ["claude": seconds, "codex": seconds]
            expect(remotePollTooltip(0, views: local, enabled: both, intervals: shared, auto: true, language: language)
                   == autoTitle + ": Claude Code → " + title + "; Codex → " + title,
                   "C3-27 \(language)/\(Int(seconds)): equal effective intervals list both providers")
            expect(remotePollTooltip(seconds, views: local, enabled: both, intervals: shared, auto: true, language: language)
                   == title + "\n" + autoTitle + ": Claude Code; Codex",
                   "C3-27 \(language)/\(Int(seconds)): shared interval segment lists both providers")
            expect(remotePollTooltip(seconds, views: local, enabled: both, intervals: shared, auto: false, language: language) == title,
                   "C3-27 \(language)/\(Int(seconds)): manual tooltip is the existing accessible interval title")
        }
        expect(remotePollTooltip(0, views: local, enabled: both, intervals: intervals, auto: false, language: language) == autoTitle,
               "C3-27 \(language): manual Auto button has no effective-interval mappings")
        for (product, name, seconds, title) in [("claude", "Claude Code", 900.0, first), ("codex", "Codex", 14400.0, second)] {
            let enabled: Set<String> = [product]
            expect(remoteAutoFooter(views: local, enabled: enabled, intervals: intervals, language: language).products == [product],
                   "C3-27 \(language)/\(product): disabled local neighbour does not participate")
            expect(remotePollTooltip(0, views: local, enabled: enabled, intervals: intervals, auto: true, language: language)
                   == autoTitle + ": " + name + " → " + title,
                   "C3-27 \(language)/\(product): single enabled provider keeps full Auto title")
            expect(remotePollTooltip(seconds, views: local, enabled: enabled, intervals: intervals, auto: true, language: language)
                   == title + "\n" + autoTitle + ": " + name,
                   "C3-27 \(language)/\(product): single-provider interval tooltip excludes disabled neighbour")
        }
        let allFrame = RemoteAccountFrame(now: c3bNow(), sync: ReaderSyncState(phase: .off),
            allViews: local, visibleViews: [codex], displayedViews: [codex])
        expect(remotePollTooltip(0, views: allFrame.allViews, enabled: both, intervals: intervals, auto: true, language: language) == tooltip,
               "C3-27 \(language): hidden local Claude continues participating through allViews")
        expect(remotePollTooltip(0, views: local + [foreign], enabled: both, intervals: intervals, auto: true, language: language) == tooltip,
               "C3-27 \(language): foreign same-product account never duplicates local Auto mapping")
        expect(remotePollTooltip(0, views: [foreign, codex], enabled: both, intervals: intervals, auto: true, language: language)
               == autoTitle + ": Codex → " + second,
               "C3-27 \(language): remote Claude does not replace the missing local Claude poll")
        let none = remoteAutoFooter(views: [foreign], enabled: both, intervals: intervals, language: language)
        expect(none.noSubscriptions && none.products.isEmpty,
               "C3-27 \(language): foreign-only account never participates in local Auto")
        for seconds in [0.0, 900, 1800, 3600, 14400] {
            for auto in [true, false] {
                expect(remotePollTooltip(seconds, views: [], enabled: [], intervals: intervals, auto: auto, language: language)
                       == (en ? "No subscriptions enabled" : "Нет включённых подписок"),
                       "C3-27 \(language)/\(Int(seconds))/auto=\(auto): local-only Off retains existing native tooltip")
            }
            expect(remotePollTooltip(seconds, views: [foreign], enabled: both, intervals: intervals, auto: true, language: language) == none.tooltip,
                   "C3-27 \(language)/\(Int(seconds)): foreign-only footer keeps V9 schedule explanation")
        }
        expect(remotePollTooltip(0, views: local, enabled: both, intervals: [:], auto: true, language: language) == autoTitle,
               "C3-27 \(language): missing Auto interval snapshot never invents a default mapping")
        expect(remotePollTooltip(0, views: local, enabled: both, intervals: ["claude": 2700, "codex": 900], auto: true, language: language)
               == autoTitle + ": Codex → " + first,
               "C3-27 \(language): unsupported interval is omitted without losing valid neighbour")
    }
}

// C3-28...33: visual round 2, owner decisions N1/N2/N3/16/Q5/Q6.
// Measured widths are injected numbers; clocks and zones are explicit. Actual
// CoreText glyph fitting stays in the 190 AppKit previews, including long L.
private func c3bC328(_ expect: C3BExpect) {
    let constrained = remoteAdvancedHeaderWidths(availableWidth: 263, titleWidth: 82,
        badgeWidth: 95, planWidth: 59, machineWidth: 31, isCustomTitle: false, minimumTitleWidth: 64)
    expect(constrained.title == 82 && constrained.badge == 95 && constrained.plan == 59,
           "C3-28/N1: complete Claude Code title, warning badge and plan are reserved before machines")
    expect(constrained.machines == 10 && constrained.title + constrained.badge + constrained.plan + constrained.machines + 17 == 263,
           "C3-28/N1: machine suffix gives up width first and all measured gaps fit 263pt")
    let ample = remoteAdvancedHeaderWidths(availableWidth: 300, titleWidth: 82,
        badgeWidth: 95, planWidth: 59, machineWidth: 31, isCustomTitle: false, minimumTitleWidth: 64)
    expect(ample.title == 82 && ample.machines == 31,
           "C3-28/N1: available width is not wasted by a fixed machine reservation")
    let custom = remoteAdvancedHeaderWidths(availableWidth: 263, titleWidth: 220,
        badgeWidth: 95, planWidth: 59, machineWidth: 31, isCustomTitle: true, minimumTitleWidth: 64)
    expect(custom.title >= 64 && custom.title < 220 && custom.machines == 0
           && custom.badge == 95 && custom.plan == 59,
           "C3-28/N1: custom account title can shrink to its eight-character minimum after dropping machines")
}

private func c3bC329(_ expect: C3BExpect) {
    let now = c3bNow(), zone = TimeZone(secondsFromGMT: 0)!, sync = ReaderSyncState(phase: .on)
    let local = c3bView(product: "codex", local: true)
    for language in ["ru", "en"] {
        let single = remotePresentationCard(local, sync: ReaderSyncState(phase: .off), language: language, narrow: true,
            now: now, timeZone: zone, productAccountCount: 1)
        let multiple = remotePresentationCard(local, sync: sync, language: language, narrow: true,
            now: now, timeZone: zone, productAccountCount: 2)
        expect(single.simpleTitle == "Codex" && single.simpleMachines == "● mac"
               && multiple.simpleTitle == "Codex" && multiple.simpleMachines == "● mac",
               "C3-29/N2: sole local account keeps its source dot and machine name; multiple accounts use the second line")
        expect(multiple.advancedTitle == "Codex" && multiple.machineSuffix == "· ● mac"
               && local.data.source == nil && multiple.sourceLine == (language == "ru" ? "Данные 15:50" : "Data 15:50"),
               "C3-29/N2: multi-account header uses machines while local footer remains this-machine Data time")
        let other = c3bView(2, product: "codex")
        let remote = remotePresentationCard(other, sync: sync, language: language, narrow: true,
            now: now, timeZone: zone, productAccountCount: 2)
        expect([multiple.simpleTitle, remote.simpleTitle] == ["Codex", "Codex"]
               && [multiple.simpleMachines, remote.simpleMachines] == ["● mac", "● vps"],
               "C3-29/N2: second header lines distinguish both Codex accounts")
        let selectorTitles = [local, other].map { remoteHistorySelectorTitle($0, language: language) }
        expect(selectorTitles == ["Codex · mac", "Codex · vps"] && Set(selectorTitles).count == 2,
               "C3-29/R1: actual history selector titles and their tooltip strings distinguish both Codex accounts")
        var custom = local; custom.caption = "Work Codex"
        let named = remotePresentationCard(custom, sync: sync, language: language, narrow: true,
            now: now, timeZone: zone, productAccountCount: 2)
        expect(named.simpleTitle == custom.caption && named.machineSuffix == "· ● mac"
               && remoteHistorySelectorTitle(custom, language: language) == custom.caption,
               "C3-29/R1: explicit account caption remains intact in Simple and history selector without duplicate machines")
        var unlabelled = other; unlabelled.historyKey = "u:codex"; unlabelled.label = nil
        expect(remoteHistorySelectorTitle(unlabelled, language: language)
               == (language == "ru" ? "Codex · не указан" : "Codex · unlabelled"),
               "C3-29/R1: unlabelled history segment keeps its localized distinct title")
    }
}

private func c3bC330(_ expect: C3BExpect) {
    let now = c3bNow(), zone = TimeZone(secondsFromGMT: 0)!, moscow = TimeZone(secondsFromGMT: 3 * 3600)!
    var healthy = c3bView(model: true)
    healthy.data.weekly = 39
    healthy.data.weeklyReset = healthy.data.asOf!.addingTimeInterval(84 * 3600)
    let freshHeight = remotePanelLayout(views: [healthy], style: .advanced, now: now).cards.first?.height
    expect(freshHeight == 258, "C3-30/N3: baseline full three-window Claude card retains existing 258pt model geometry")
    for state in [RemoteCardState.signInRequired, .offline, .syncStalled, .serviceWait] {
        var view = healthy; view.state = state
        let kinds = remoteAdvancedMetrics(view).map { remoteAdvancedRowKind(view, metric: $0, now: now) }
        expect(kinds.allSatisfy { $0 == .full } && kinds.allSatisfy { remoteAdvancedRowHeight($0) == 62 },
               "C3-30/N3: in-horizon \(state.rawValue) keeps complete 62pt forecast and metadata rows")
        expect(remotePanelLayout(views: [view], style: .advanced, now: now).cards.first?.height == freshHeight,
               "C3-30/N3: in-horizon \(state.rawValue) card has exactly the fresh card height")
        let pace = snapshotWindowPace(used: view.data.weekly, reset: view.data.weeklyReset,
            windowH: 168, asOf: view.data.asOf, now: now)
        let row = AdvRow(limit: PacedLimit(id: "weekly", name: "", pace: pace, color: 0, used: 39), kind: kinds.last!, credits: nil)
        for language in ["ru", "en"] {
            expect(remoteAdvancedVerdict(row, data: view.data, now: now, language: language, timeZone: zone)
                   == (language == "ru" ? "Хватит до сброса (прогноз 78%)" : "Lasts until reset (forecast 78%)"),
                   "C3-30/N3: \(language) \(state.rawValue) retains asOf forecast rather than an as-of-only line")
        }
        view.data.source?.freshUntil = now.addingTimeInterval(-1)
        expect(remoteAdvancedMetrics(view).allSatisfy { remoteAdvancedRowKind(view, metric: $0, now: now) == .stale },
               "C3-30/N3: \(state.rawValue) becomes stale only beyond the V4 horizon")
    }
    var noReader = healthy; noReader.state = .signedOut
    expect(remoteAdvancedMetrics(noReader).allSatisfy { remoteAdvancedRowKind(noReader, metric: $0, now: now) == .inactive },
           "C3-30/N3: reader state7 still has inactive windows rather than fabricated forecasts")
    let pace = snapshotWindowPace(used: healthy.data.weekly, reset: healthy.data.weeklyReset,
        windowH: 168, asOf: healthy.data.asOf, now: now)
    let staleRow = AdvRow(limit: PacedLimit(id: "weekly", name: "", pace: pace, color: 0, used: 39), kind: .stale, credits: nil)
    for language in ["ru", "en"] {
        expect(remoteAdvancedVerdict(staleRow, data: healthy.data, now: now, language: language, timeZone: zone)
               == (language == "ru" ? "по данным на 15:50" : "as of 15:50"),
               "C3-30/N3: explicit UTC verdict observation time matches the footer instead of the host timezone")
        expect(remoteAdvancedVerdict(staleRow, data: healthy.data, now: now, language: language, timeZone: moscow)
               == (language == "ru" ? "по данным на 18:50" : "as of 18:50"),
               "C3-30/N3: changing only injected timezone shifts verdict and footer together")
        let resetRow = AdvRow(limit: staleRow.limit, kind: .exhausted, credits: nil)
        let utcReset = remoteCardTimestamp(healthy.data.weeklyReset, now: now, timeZone: zone)
        let shiftedReset = remoteCardTimestamp(healthy.data.weeklyReset, now: now, timeZone: moscow)
        expect(remoteAdvancedVerdict(resetRow, data: healthy.data, now: now, language: language, timeZone: zone).hasSuffix(utcReset)
               && remoteAdvancedVerdict(resetRow, data: healthy.data, now: now, language: language, timeZone: moscow).hasSuffix(shiftedReset)
               && utcReset != shiftedReset,
               "C3-30/N3: reset verdict timestamps use the same injected scene formatter as the footer")
    }
    var fast = healthy
    fast.data.session = 80; fast.data.sessionReset = now.addingTimeInterval(3 * 3600)
    let fastPace = snapshotWindowPace(used: fast.data.session, reset: fast.data.sessionReset,
        windowH: 5, asOf: fast.data.asOf, now: now)
    let fastRow = AdvRow(limit: PacedLimit(id: "session", name: "", pace: fastPace, color: 0, used: 80), kind: .full, credits: nil)
    for language in ["ru", "en"] {
        expect(fastPace?.runsOutAt != nil
               && remoteAdvancedVerdict(fastRow, data: fast.data, now: now, language: language, timeZone: zone).contains("16:17")
               && remoteAdvancedVerdict(fastRow, data: fast.data, now: now, language: language, timeZone: moscow).contains("19:17"),
               "C3-30/N3: runs-out forecast uses the injected scene timezone, independently of the host")
    }
}

private func c3bC331(_ expect: C3BExpect) {
    let now = c3bNow(), zone = TimeZone(secondsFromGMT: 0)!
    for language in ["ru", "en"] {
        var view = c3bView()
        let raw = language == "ru" ? "Рабочая подписка для больших задач" : "Work subscription for large tasks"
        view.caption = String(raw.prefix(32))
        let card = remotePresentationCard(view, sync: ReaderSyncState(phase: .on), language: language,
            narrow: false, now: now, timeZone: zone)
        expect(view.caption.unicodeScalars.count == 32 && card.simpleTitle == view.caption
               && card.advancedTitle == view.caption && card.accessibilityLabel == view.caption,
               "C3-31/16: 32-character custom caption is passed in full to the history segment and accessibility label")
    }
}

private func c3bC332(_ expect: C3BExpect) {
    let now = c3bNow(), zone = TimeZone(secondsFromGMT: 0)!
    var view = c3bView(); view.data.source?.machineName = "build-machine"
    for language in ["ru", "en"] {
        let full = language == "ru" ? "Данные с build-machine от 15:50" : "Data from build-machine at 15:50"
        let compact = language == "ru" ? "С build-machine от 15:50" : "From build-machine at 15:50"
        let fullShortName = language == "ru" ? "Данные с build-ma… от 15:50" : "Data from build-ma… at 15:50"
        let compactShortName = language == "ru" ? "С build-ma… от 15:50" : "From build-ma… at 15:50"
        var narrowMeasures: [String] = []
        let narrow = remoteFittedSourceLine(view, language: language, now: now, timeZone: zone, narrow: true,
            availableWidth: 130) { text in
                narrowMeasures.append(text)
                return text == full || text == compact ? 150 : 120
            }
        expect(narrow == compactShortName && Array(narrowMeasures.prefix(2)) == [full, compact]
               && narrowMeasures.contains(compactShortName),
               "C3-32/Q5: narrow card shortens source prefix before returning a measured shortened machine")
        for width in [300.0, 308.0] {
            var wideMeasures: [String] = []
            let wide = remoteFittedSourceLine(view, language: language, now: now, timeZone: zone, narrow: false,
                availableWidth: width) { text in
                    wideMeasures.append(text)
                    return text == full ? 400 : 120
                }
            expect(wide == fullShortName && !wideMeasures.contains(compact),
                   "C3-32/Q5: wide Simple/Advanced \(Int(width))pt keeps full prefix and shortens only machine")
        }
    }
}

private func c3bC333(_ expect: C3BExpect) {
    let checkedAt = c3bNow().addingTimeInterval(-15 * 60), zone = TimeZone(secondsFromGMT: 0)!
    var clock = checkedAt
    var completion: ((Bool) -> Void)?
    var reads = 0
    let reader = RemoteManualRefreshController(clock: { clock }, read: { callback in reads += 1; completion = callback })
    expect(reader.request() && reads == 1, "C3-33/Q6: injected manual click performs one reader request without a provider effect")
    completion?(true)
    let pollAllowed = RemoteManualPhase.pollAllowed(c3bNow().addingTimeInterval(-120)) // 15:58
    var local = c3bView(local: true), foreign = c3bView(1, product: "codex")
    local.data.asOf = checkedAt.addingTimeInterval(-120); foreign.data.asOf = local.data.asOf
    foreign.data.source?.asOf = foreign.data.asOf
    for age in [0.0, 59, 60] {
        clock = checkedAt.addingTimeInterval(age)
        let readerPhase = reader.phase(now: clock)
        for language in ["ru", "en"] {
            let localCard = remotePresentationCard(local, sync: ReaderSyncState(phase: .on), language: language,
                narrow: true, now: clock, timeZone: zone, manual: pollAllowed, readerManual: readerPhase)
            let foreignCard = remotePresentationCard(foreign, sync: ReaderSyncState(phase: .on), language: language,
                narrow: true, now: clock, timeZone: zone, manual: pollAllowed, readerManual: readerPhase)
            expect(localCard.statusLine == (language == "ru" ? "Опрос можно с 15:58" : "Poll allowed at 15:58"),
                   "C3-33/Q6: \(language) local provider cooldown remains independent at reader age \(Int(age))s")
            expect(foreignCard.statusLine == (age < 60 ? (language == "ru" ? "GitHub проверен 15:45" : "GitHub checked 15:45") : ""),
                   "C3-33/Q6: \(language) every foreign card shows successful read for exactly 60 seconds")
        }
    }
    let orphan = remotePresentationCard(foreign, sync: ReaderSyncState(phase: .on), language: "en", narrow: true,
        now: checkedAt, timeZone: zone, manual: pollAllowed)
    expect(orphan.statusLine.isEmpty, "C3-33/Q6: provider cooldown without a reader result never fabricates GitHub checked")
}

// C3-34...38 were written before the C4 UI implementation. Fixed in-memory
// fixtures only; actual condensed glyphs, tooltip hits, AX and wrapping in the
// native renderer still require the new AppKit PNG scenes and macOS selftest.
private func c3bC334(_ expect: C3BExpect) {
    let now = c3bNow(), zone = TimeZone(secondsFromGMT: 0)!
    for product in ["claude", "codex"] {
        let local = c3bView(product: product, local: true)
        let solo = remotePresentationCard(local, sync: ReaderSyncState(phase: .off), language: "ru",
            narrow: false, now: now, timeZone: zone)
        let layout = remotePanelLayout(views: [local], style: .simple, now: now)
        expect(solo.simpleTitle == (product == "claude" ? "Claude" : "Codex")
               && solo.simpleMachines == "● mac" && layout.cards.first?.height == 183 && layout.windowHeight == 317,
               "C3-34/D2: sole local \(product) without sync retains the dotted 13pt second header line")
        let pair = remotePanelLayout(views: [local, c3bView(1, product: product)], style: .simple, now: now)
        expect(pair.cards.map { $0.height } == [183, 183] && pair.windowHeight == 317,
               "C3-34/D2: local and remote cards have equal heights in a mixed row")
    }
    let empty = remotePanelLayout(views: [], style: .simple, now: now)
    expect(empty.cards.isEmpty && empty.windowHeight == 286,
           "C3-34/D2: empty Simple panel does not reserve a nonexistent header")
    let local = c3bView(local: true)
    expect(remotePanelLayout(views: [local], style: .advanced, now: now).cards.first?.height == 195,
           "C3-34/D2: 13pt Simple header does not enlarge Advanced cards")
}

private func c3bC335(_ expect: C3BExpect) {
    let now = c3bNow(), zone = TimeZone(secondsFromGMT: 0)!, sync = ReaderSyncState(phase: .on)
    let localID = "c3350000-1111-4222-8333-444455556666"
    guard let key = accountLabelKey(gistId: "c335-synthetic-gist"),
          let label = accountLabel(product: "codex", localId: localID, labelKey: key) else {
        expect(false, "C3-35/D2: synthetic resolver identity is valid"); return
    }
    var cache = SyncRemoteCache(); cache.labelKey = key
    cache.accounts = ["zulu", "alpha", "beta"].enumerated().map { index, name in
        var account = RemoteAccount(product: "codex", label: label, status: "ok")
        account.plan = "pro"; account.asOf = now.addingTimeInterval(-600)
        account.machineId = "c335-\(index)"; account.machineName = name; account.machineLastSeenAt = now
        account.windows = RemoteWindows(weekly: RemoteWindow(pct: 40, resetAt: now.addingTimeInterval(86400)))
        account.schedule = RemoteSchedule(mode: "auto", interval: 3600)
        return account
    }
    let frame = remoteAccountFrame(local: (LimitData(present: false), c3bView(product: "codex", local: true).data),
        localIds: ["codex": localID], remote: cache, hidden: [], menu: [:], sync: sync, now: now,
        localMachineName: "macbook")
    guard let merged = frame.allViews.first(where: { $0.product == "codex" }) else {
        expect(false, "C3-35/D2: resolver returns merged local Codex fixture"); return
    }
    expect(frame.allViews.count == 1 && merged.machines == ["macbook", "alpha", "beta", "zulu"],
           "C3-35/D2: merged account orders this computer first, remaining names alphabetically")
    for language in ["ru", "en"] {
        let header = remotePresentationCard(merged, sync: sync, language: language, narrow: true,
            now: now, timeZone: zone)
        expect(header.simpleTitle == "Codex" && header.simpleMachines == "● macbook, ● alpha +2",
               "C3-35/D2: short product first; at most two machine names and +N on second line")
        expect(header.accessibilityLabel == merged.caption && !header.accessibilityLabel.contains("…"),
               "C3-35/D2: full default caption remains available for header tooltip and card AX")
        var custom = merged; custom.caption = language == "ru" ? "Рабочая подписка для больших задач" : "Work subscription for large tasks"
        custom.caption = String(custom.caption.prefix(32))
        let named = remotePresentationCard(custom, sync: sync, language: language, narrow: true,
            now: now, timeZone: zone)
        expect(named.simpleTitle == custom.caption && named.simpleMachines == header.simpleMachines
               && named.accessibilityLabel == custom.caption && named.advancedTitle == custom.caption && named.machineSuffix == "· " + header.simpleMachines,
               "C3-35/D2: complete custom L and machines stay on separate Simple lines; Advanced keeps its custom title and dotted sources")
    }
    var measured: [String] = []
    let text = "macbook, vps"
    let fitted = remoteFittedSimpleMachines(text, availableWidth: 80) { candidate in
        measured.append(candidate); return candidate == text ? 80 : 100
    }
    expect(fitted == text && measured == [text],
           "C3-35/D2: exact fit in condensed preserves both machine names without premature ellipsis")
    let clipped = remoteFittedSimpleMachines(text, availableWidth: 50) { Double($0.count) * 5 }
    expect(clipped.hasSuffix("…") && !clipped.contains("\n") && Double(clipped.count) * 5 <= 50
           && text.hasPrefix(String(clipped.dropLast())),
           "C3-35/D2: measured condensed overflow shortens only the tail of the machine line")
    expect(remoteFittedSimpleMachines("", availableWidth: 80, measureCondensed: { _ in 0 }).isEmpty,
           "C3-35/D2: blank reserved machine line stays blank")
}

private func c3bC336(_ expect: C3BExpect) {
    let now = c3bNow(), zone = TimeZone(secondsFromGMT: 0)!
    let seen = now.addingTimeInterval(-25 * 3600) // 11.10 15:00, unlike today's fixture
    for language in ["ru", "en"] {
        for state in [RemoteCardState.offline, .syncStalled] {
            var view = c3bView(state: state)
            view.data.asOf = seen; view.data.source?.asOf = seen; view.data.source?.lastSeenAt = seen
            let warning = language == "ru" ? "Синхронизация стоит с 11.10 15:00: тестовая ошибка" : "Sync stalled since 11.10 15:00: synthetic error"
            let sync = ReaderSyncState(phase: .on, warning: state == .syncStalled ? warning : nil)
            let narrow = remotePresentationCard(view, sync: sync, language: language, narrow: true, now: now, timeZone: zone)
            let wide = remotePresentationCard(view, sync: sync, language: language, narrow: false, now: now, timeZone: zone)
            expect(remoteVisibleSourceLine(narrow, advanced: false).isEmpty
                   && remoteVisibleSourceLine(wide, advanced: false).isEmpty,
                   "C5-09/D6: narrow and wide Simple no longer paint the source formatter")
            expect(narrow.sourceLine == (language == "ru" ? "С vps от 11.10" : "From vps on 11.10"),
                   "C3-36/D1: narrow \(state.rawValue) source keeps other-day date without HH:mm")
            expect(wide.sourceLine == (language == "ru" ? "Данные с vps от 11.10 15:00" : "Data from vps on 11.10 15:00"),
                   "C3-36/D1: Advanced source model retains full date and time")
            if state == .offline {
                expect(narrow.statusLine == (language == "ru" ? "vps не на связи с 11.10 ›" : "vps offline since 11.10 ›"),
                       "C3-36/D1: narrow offline status preserves its chevron after the date")
                expect(wide.statusLine.contains("11.10 15:00"),
                       "C3-36/D1: wide Simple and Advanced offline status retain date and time")
            } else {
                expect(narrow.statusLine == (language == "ru" ? "Синхронизация стоит ›" : "Sync stalled ›")
                       && narrow.action == "syncsettings" && narrow.tooltip.contains(warning),
                       "C3-36/D1: state6 retains full sync warning and recovery action")
            }
            expect(narrow.tooltip.contains("11.10 15:00") && narrow.accessibilityValue == narrow.tooltip,
                   "C3-36/D1: compact date never replaces full other-day timestamp in tooltip/AX")
            for measuredWidth in [0.0, 120.0] {
                let fitted = remoteFittedSourceLine(view, language: language, now: now, timeZone: zone,
                    narrow: true, availableWidth: 130, measure: { _ in measuredWidth })
                expect(fitted == narrow.sourceLine,
                       "C3-36/D1: actual fitted narrow source preserves date-only policy when the complete short source fits")
            }
            let advanced = remoteFittedSourceLine(view, language: language, now: now, timeZone: zone,
                narrow: false, availableWidth: 308, measure: { _ in 100 })
            expect(advanced == wide.sourceLine, "C3-36/D1: fitted Advanced source retains HH:mm")
        }
        let today = c3bView(state: .offline)
        let card = remotePresentationCard(today, sync: ReaderSyncState(phase: .on), language: language,
            narrow: true, now: now, timeZone: zone)
        expect(card.sourceLine == (language == "ru" ? "Данные с vps от 15:50" : "Data from vps at 15:50")
               && card.statusLine == (language == "ru" ? "vps не на связи с 16:00" : "vps offline since 16:00"),
               "C3-36/D1: today's compact source/status copy stays unchanged")
    }
    var independent = c3bView(state: .offline)
    independent.data.asOf = seen.addingTimeInterval(-86400)
    independent.data.source?.asOf = independent.data.asOf; independent.data.source?.lastSeenAt = seen
    let distinct = remotePresentationCard(independent, sync: ReaderSyncState(phase: .on), language: "en",
        narrow: true, now: now, timeZone: zone)
    expect(distinct.sourceLine == "From vps on 10.10" && distinct.statusLine == "vps offline since 11.10 ›"
           && distinct.tooltip.contains("10.10 15:00") && distinct.tooltip.contains("11.10 15:00"),
           "C3-36/D1: observation date and last-seen date remain independent in compact and full copy")
    // Same instant is yesterday in UTC, today in UTC+3: use the scene calendar.
    let midnight = now.addingTimeInterval(-15.5 * 3600), late = midnight.addingTimeInterval(-90 * 60)
    var boundary = c3bView(state: .offline)
    boundary.data.asOf = late; boundary.data.source?.asOf = late; boundary.data.source?.lastSeenAt = late
    let shifted = remotePresentationCard(boundary, sync: ReaderSyncState(phase: .on), language: "en", narrow: true,
        now: midnight, timeZone: TimeZone(secondsFromGMT: 3 * 3600)!)
    expect(shifted.sourceLine == "Data from vps at 02:00" && shifted.statusLine == "vps offline since 02:00",
           "C3-36/D1: 'today' follows injected timezone rather than UTC/host day")
}

private func c3bC337(_ expect: C3BExpect) {
    for text in ["Error alpha beta gamma delta", "Ошибка альфа бета гамма дельта"] {
        for (width, count) in [(300.0, 1), (90.0, 2), (60.0, 3)] {
            let model = remoteSettingsErrorPresentation(text, availableWidth: width, lineHeight: 14,
                measureWidth: { Double($0.count) * 5 })
            expect(model.text == text && model.accessibilityValue == text && model.lines.joined(separator: " ") == text,
                   "C3-37/D3: wrapping preserves the complete model text and AX in either language")
            expect(model.lines.count == count && model.height == Double(count) * 14
                   && model.lines.allSatisfy { Double($0.count) * 5 <= width },
                   "C3-37/D3: measured \(count)-line error grows by exactly \(count - 1) lines without overflow")
        }
    }
    let long = "Ошибка 20:38: Не удалось восстановить результат предыдущего запроса. " + String(repeating: "Проверьте подключение к GitHub. ", count: 12)
    let capped = remoteSettingsErrorPresentation(long, availableWidth: 300, lineHeight: 14,
        measureWidth: { Double($0.count) * 5 })
    expect(long.count > 256 && capped.text == long && capped.accessibilityValue == long,
           "C3-37/D3: long real-world error remains complete beyond the card-warning 256-character limit")
    expect(capped.lines.count == 3 && capped.height == 42
           && capped.lines.allSatisfy { Double($0.count) * 5 <= 300 },
           "C3-37/D3: visible long error is capped at three wrapped lines, extra block height 28pt")
    let token = String(repeating: "X", count: 70)
    let broken = remoteSettingsErrorPresentation(token, availableWidth: 60, lineHeight: 14,
        measureWidth: { Double($0.count) * 5 })
    expect(broken.text == token && broken.accessibilityValue == token && broken.lines.count == 3
           && broken.lines.allSatisfy { Double($0.count) * 5 <= 60 },
           "C3-37/D3: an unbroken error token cannot overflow the three-line block")
    let empty = remoteSettingsErrorPresentation("", availableWidth: 300, lineHeight: 14, measureWidth: { _ in 0 })
    expect(empty.text.isEmpty && empty.accessibilityValue.isEmpty && empty.lines.isEmpty && empty.height == 0,
           "C3-37/D3: absent error reserves no wrapped error height")
}

private func c3bC338(_ expect: C3BExpect) {
    let right = remoteAdvancedHeaderRightBoundary(cardMaxX: 345)
    expect(right == 317 && remoteAdvancedHeaderRightBoundary(cardMaxX: 355) == 327,
           "C3-38: Advanced header boundary is 317pt in the real 330pt card, with a 28pt inset")
    let widths = remoteAdvancedHeaderWidths(availableWidth: right - 49, titleWidth: 82,
        badgeWidth: 79, planWidth: 59, machineWidth: 31, isCustomTitle: false, minimumTitleWidth: 64)
    expect(widths.title == 82 && widths.badge == 79 && widths.plan == 59 && widths.machines == 31,
           "C3-38: corrected 268pt header budget fits complete product, status, plan and vps suffix")
    expect(APP_VERSION == "3.3.1", "C3-38: C-slice application version is 3.3.1")
}

// R2: real CoreText widths are covered by c3-...-longname-... PNG scenes. This
// injected metric makes each w wider than the ordinary text, so eight w glyphs
// can still exceed 130pt and the machine must yield further before the date.
private func c3bC339(_ expect: C3BExpect) {
    let now = c3bNow(), zone = TimeZone(secondsFromGMT: 0)!, machine = String(repeating: "w", count: 16)
    let seen = now.addingTimeInterval(-25 * 3600)
    func measure(_ text: String) -> Double { text.reduce(0.0) { $0 + ($1 == "w" ? 8 : 4) } }
    for language in ["ru", "en"] {
        for state in [RemoteCardState.offline, .syncStalled] {
            var view = c3bView(state: state)
            view.machines = [machine]; view.data.source?.machineName = machine
            view.data.source?.statusMachineName = machine
            view.data.asOf = seen; view.data.source?.asOf = seen; view.data.source?.lastSeenAt = seen
            let warning = language == "ru" ? "Синхронизация стоит с 11.10 15:00" : "Sync stalled since 11.10 15:00"
            let sync = ReaderSyncState(phase: .on, warning: state == .syncStalled ? warning : nil)
            let card = remotePresentationCard(view, sync: sync, language: language, narrow: true, now: now, timeZone: zone)
            let status = remoteFittedStatusLine(view, presentation: card, language: language, narrow: true,
                now: now, timeZone: zone, availableWidth: 130, measure: measure)
            let source = remoteFittedSourceLine(view, language: language, now: now, timeZone: zone, narrow: true,
                availableWidth: 130, measure: measure)
            expect(source.hasSuffix("11.10") && source.contains(language == "ru" ? " от " : " on ")
                   && source.contains("…") && !source.contains(machine) && measure(source) <= 130,
                   "C3-39/R2: \(language) state\(state.rawValue) source shortens machine before the complete date")
            if state == .offline {
                expect(status.hasSuffix("11.10 ›") && status.contains("…") && !status.contains(machine)
                       && status.hasPrefix("w") && measure(status) <= 130,
                       "C3-39/R2: \(language) offline status preserves complete date and chevron after measured machine fitting")
                let tail = language == "ru" ? " не на связи с 11.10 ›" : " offline since 11.10 ›"
                expect(measure(String(repeating: "w", count: 8) + "…" + tail) > 130
                       && !status.hasPrefix(String(repeating: "w", count: 8)),
                       "C3-39/R2: eight wide machine glyphs still overflow; the machine yields further before any date character")
                let wideCard = remotePresentationCard(view, sync: sync, language: language, narrow: false, now: now, timeZone: zone)
                expect(remoteFittedStatusLine(view, presentation: wideCard, language: language, narrow: false,
                    now: now, timeZone: zone, availableWidth: 300, measure: measure) == wideCard.statusLine
                       && wideCard.statusLine.contains(machine) && wideCard.statusLine.contains("11.10 15:00"),
                       "C3-39/R2: wide Simple and Advanced status retain the previous full timestamp and machine")
                var today = view
                today.data.asOf = now.addingTimeInterval(-600); today.data.source?.asOf = today.data.asOf
                today.data.source?.lastSeenAt = today.data.asOf
                let todayCard = remotePresentationCard(today, sync: sync, language: language, narrow: true, now: now, timeZone: zone)
                let todayStatus = remoteFittedStatusLine(today, presentation: todayCard, language: language, narrow: true,
                    now: now, timeZone: zone, availableWidth: 130, measure: measure)
                let todaySource = remoteFittedSourceLine(today, language: language, now: now, timeZone: zone, narrow: true,
                    availableWidth: 130, measure: measure)
                expect(todayStatus.hasSuffix("15:50") && todaySource.hasSuffix("15:50")
                       && todayStatus.contains("…") && todaySource.contains("…")
                       && measure(todayStatus) <= 130 && measure(todaySource) <= 130,
                       "C3-39/R2: today's HH:mm also survives measured machine fitting in status and source")
                let reading = remotePresentationCard(view, sync: sync, language: language, narrow: true,
                    now: now, timeZone: zone, manual: .reading)
                expect(remoteFittedStatusLine(view, presentation: reading, language: language, narrow: true,
                    now: now, timeZone: zone, availableWidth: 130, measure: measure) == reading.statusLine,
                       "C3-39/R2: machine fitting never replaces an active reader phase with the offline status")
                let fallback = remoteFittedStatusLine(view, presentation: card, language: language, narrow: true,
                    now: now, timeZone: zone, availableWidth: 12, measure: measure)
                expect(measure(fallback) <= 12 && fallback.hasSuffix("…"),
                       "C3-39/R2: only an impossible timestamp budget permits the final whole-line tail fallback")
            } else {
                expect(status == card.statusLine && status.hasSuffix("›") && measure(status) <= 130,
                       "C3-39/R2: sync-stalled recovery copy retains its chevron and does not acquire the source machine")
            }
            expect(card.tooltip.contains(machine) && card.tooltip.contains("11.10 15:00") && card.accessibilityValue == card.tooltip,
                   "C3-39/R2: fitting leaves the complete source name and timestamp in tooltip/AX")
        }
    }
}

func runRemoteLimitsC3BSelfTests() -> Int {
    var checks = 0, failures = 0
    func expect(_ ok: Bool, _ message: String) {
        checks += 1; if !ok { failures += 1 }
        print("\(ok ? "OK" : "FAIL") \(message)")
    }
    c3bC306(expect); c3bC306Edges(expect); c3bC308(expect); c3bC309(expect)
    c3bReviewRegressions(expect); c3bC327(expect)
    c3bC328(expect); c3bC329(expect); c3bC330(expect); c3bC331(expect); c3bC332(expect); c3bC333(expect)
    c3bC334(expect); c3bC335(expect); c3bC336(expect); c3bC337(expect); c3bC338(expect); c3bC339(expect)
    print("\(failures == 0 ? "OK" : "FAIL") C3B model tests: \(checks) checks; \(failures) failures")
    return failures
}
