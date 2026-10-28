import Foundation

// C3-B value models. No preferences, singleton history, AppKit, or runtime effects.
enum RemotePanelStyle { case simple, advanced }
struct RemotePanelLayout {
    var cards: [CGRect]
    var intervalRect: CGRect
    var authorRect: CGRect
    var windowHeight: Double
    var historySelectorRect: CGRect?
    var moneyRows: [CGRect]
}

func remotePanelLayout(views: [AccountView], style: RemotePanelStyle, now: Date,
                       historyHeight: Double = 35) -> RemotePanelLayout {
    let visible = views.filter { !$0.historyKey.hasPrefix("u:") }
    if style == .simple {
        if visible.isEmpty {
            return RemotePanelLayout(cards: [], intervalRect: CGRect(x: 16, y: 224, width: 328, height: 24),
                authorRect: CGRect(x: 16, y: 265, width: 328, height: 16), windowHeight: 286,
                historySelectorRect: nil, moneyRows: [])
        }
        let extra = visible.contains { remoteSimpleShowsScopedRow($0, now: now) } ? 15.0 : 0
        let cardH = 184 + extra, rows = max(1, (visible.count + 1) / 2)
        let height = 318 + extra + Double(rows - 1) * (cardH + 12)
        let cards = visible.indices.map { i -> CGRect in
            let wide = visible.count == 1 || (visible.count % 2 == 1 && i == visible.count - 1)
            return CGRect(x: wide || i % 2 == 0 ? 16 : 186,
                          y: 58 + Double(i / 2) * (cardH + 12), width: wide ? 328 : 158, height: cardH)
        }
        return RemotePanelLayout(cards: cards, intervalRect: CGRect(x: 16, y: height - 62, width: 328, height: 24),
            authorRect: CGRect(x: 16, y: height - 21, width: 328, height: 16), windowHeight: height,
            historySelectorRect: nil, moneyRows: [])
    }
    var top = 58.0
    let cards = visible.map { view -> CGRect in
        let metrics = remoteAdvancedMetrics(view)
        let heights = metrics.map { remoteAdvancedRowHeight(remoteAdvancedRowKind(view, metric: $0, now: now)) }
            + (view.product == "codex" ? [24.0] : [])
        let height = 38 + heights.reduce(0, +) + Double(max(0, heights.count - 1))
            + Double(remoteAdvancedNoticeLines(view, now: now)) * 19 + 32
        let rect = CGRect(x: 15, y: top, width: 330, height: height)
        top += height + 5
        return rect
    }
    // Unassigned usage has no quota card, but keeps its history segment and money
    // row (UX §10). Callers have already removed hidden history accounts.
    let historyVisible = views
    let expanded = historyHeight >= 187
    let selector = expanded && historyVisible.count >= 3 ? CGRect(x: 26, y: top + 28, width: 308, height: 22) : nil
    let selectorExtra = expanded && historyVisible.count >= 3 ? 22.0 : 0
    // historyHeight is the base history height (187 + optional 44pt empty note).
    let historyH = historyHeight + selectorExtra + (expanded ? Double(max(0, historyVisible.count - 2)) * 19 : 0)
    let emptyExtra = historyHeight >= 231 ? 44.0 : 0
    let moneyTop = top + 8 + 18 + 4 + selectorExtra + 82 + emptyExtra + 23
    let money = expanded ? historyVisible.indices.map { CGRect(x: 26, y: moneyTop + Double($0) * 19, width: 308, height: 13) } : []
    let interval = CGRect(x: 16, y: top + historyH + 6, width: 328, height: 24)
    let author = CGRect(x: 16, y: interval.minY + 37, width: 328, height: 12)
    return RemotePanelLayout(cards: cards, intervalRect: interval, authorRect: author,
        windowHeight: Double(interval.minY) + 59, historySelectorRect: selector, moneyRows: money)

}

// Shared by the Foundation-only geometry and the real Advanced rows. History can
// change recent-rate text, but cannot change the row kind or its measured height.
func remoteAdvancedMetrics(_ view: AccountView) -> [String] {
    (view.product == "claude" || view.data.session != nil ? ["session"] : [])
        + (view.data.scoped != nil ? ["scoped"] : []) + ["weekly"]
}
func remoteAdvancedRowHeight(_ kind: AdvRowKind) -> Double {
    switch kind {
    case .full, .tooEarly, .exhausted: return 62
    case .inactive, .stale: return 50
    case .credits: return 24
    }
}
func remoteAdvancedRowKind(_ view: AccountView, metric: String, now: Date) -> AdvRowKind {
    let d = view.data
    if !view.isLocal {
        if view.state == .signedOut { return .inactive }
        if view.state != .fresh && view.state != .serviceWait { return .stale }
    }
    let used: Double?, reset: Date?, hours: Double
    switch metric {
    case "session": (used, reset, hours) = (d.session, d.sessionReset, 5)
    case "scoped": (used, reset, hours) = (d.scoped?.percent, d.scoped?.reset, 168)
    default: (used, reset, hours) = (d.weekly, d.weeklyReset, 168)
    }
    let invalidTime = !remotePaceTimeValid(d, now: now)
    guard let pace = snapshotWindowPace(used: used, reset: reset, windowH: hours, asOf: d.asOf,
                                       now: d.source == nil ? nil : now) else {
        return d.source != nil && invalidTime ? .stale : .inactive
    }
    if (view.isLocal && d.auth != .ok) || invalidTime || pace.reset <= now
        || (!view.isLocal && metricIsStale(d, metric: metric == "scoped" ? "model" : metric, now: now)) { return .stale }
    if pace.used >= 100 { return .exhausted }
    if pace.elapsedH < 10.0 / 60 || pace.used < 2 { return .tooEarly }
    return .full
}
func remoteAdvancedNoticeLines(_ view: AccountView, now: Date) -> Int {
    let d = view.data
    if !view.isLocal && view.state == .signedOut { return 0 }
    let valid: Bool
    if d.source != nil { valid = remotePaceTimeValid(d, now: now) }
    else {
        valid = d.auth == .ok && d.asOf.map { $0.isFiniteDate && $0 <= now } == true
            && [(d.session, d.sessionReset, 5.0), (d.weekly, d.weeklyReset, 168.0),
                (d.scoped?.percent, d.scoped?.reset, 168.0)].contains {
                snapshotWindowPace(used: $0.0, reset: $0.1, windowH: $0.2, asOf: d.asOf) != nil
            }
    }
    let recover = view.isLocal && view.product == "claude" && (d.auth == .loggedOut || d.auth == .expired)
    return (valid ? 0 : 1) + (recover ? 1 : 0)
}
private extension Date { var isFiniteDate: Bool { timeIntervalSince1970.isFinite } }

struct RemoteMenuLine {
    var product: String, historyKey: String, caption: String, sourceLine: String
    var session: Double?, weekly: Double?
    var sessionAlpha: Double, weeklyAlpha: Double, punctuationAlpha: Double
    var scoped: Double? = nil
    var scopedAlpha: Double = 1
}
struct RemoteMenuPresentation { var lines: [RemoteMenuLine]; var tooltip: String; var dark: Bool }

func remoteMenuPresentation(views: [AccountView], selected: [String: String], language: String,
                            dark: Bool, now: Date, timeZone: TimeZone, metrics: [String] = ["session", "weekly", "model"]) -> RemoteMenuPresentation {
    let accounts = views.map(remoteSanitizedView).filter { !$0.historyKey.hasPrefix("u:") }
    let lines = ["claude", "codex"].compactMap { product -> RemoteMenuLine? in
        guard let view = menuAccount(product, views: accounts, selected: selected) else { return nil }
        var data = view.data
        if !view.isLocal && view.state == .signedOut {
            data.session = nil; data.weekly = nil; data.scoped = nil
        }
        let dim = !view.isLocal && view.state != .fresh && view.state != .serviceWait
        func alpha(_ metric: String) -> Double { dim || metricIsStale(data, metric: metric, now: now) ? 0.4 : 1 }
        let sa = alpha("session"), wa = alpha("weekly"), ma = alpha("model")
        let allMetrics: [String: (Double?, Double)] = ["session": (data.session, sa), "weekly": (data.weekly, wa), "model": (data.scoped?.percent, ma)]
        var available = metrics.compactMap { allMetrics[$0] }.filter { $0.0 != nil }
        if available.isEmpty { available = [(data.session, sa), (data.weekly, wa)].filter { $0.0 != nil } }
        let punctuation = !available.isEmpty && available.allSatisfy { $0.1 == 0.4 } ? 0.4 : 1
        let source = remotePresentationSourceLine(view, language: language, narrow: false, now: now, timeZone: timeZone)
        return RemoteMenuLine(product: product, historyKey: view.historyKey, caption: view.caption,
            sourceLine: source, session: data.session, weekly: data.weekly, sessionAlpha: sa,
            weeklyAlpha: wa, punctuationAlpha: punctuation, scoped: data.scoped?.percent, scopedAlpha: ma)
    }
    return RemoteMenuPresentation(lines: lines, tooltip: lines.map {
        $0.caption + ($0.sourceLine.isEmpty ? "" : " — " + $0.sourceLine.prefix(1).lowercased() + $0.sourceLine.dropFirst())
    }.joined(separator: "\n"), dark: dark)
}

struct RemoteSettingsAccount {
    var historyKey: String, title: String, subtitle: String
    var visible: Bool, editable: Bool
}
struct RemoteSettingsModel {
    var pollingTitle: String
    var pollingEnabled: [String: Bool]
    var accounts: [RemoteSettingsAccount]
    var menuProducts: [String]
    var showsAccounts: Bool, showsGitHub: Bool, showsV10: Bool
    var v10Text: String
}
func remoteSettingsModel(views: [AccountView], hidden: Set<String>, polling: [String: Bool],
                         sync: ReaderSyncState, advanced: Bool, language: String) -> RemoteSettingsModel {
    let en = language == "en"
    let views = views.map(remoteSanitizedView)
    let accounts = views.map { view -> RemoteSettingsAccount in
        let unassigned = view.historyKey.hasPrefix("u:")
        let plan = view.tier?.contains("20x") == true ? "Max 20x" : view.tier?.contains("5x") == true ? "Max 5x" : view.data.plan?.capitalized ?? ""
        let title = unassigned ? (view.product == "claude" ? "Claude" : "Codex") + (en ? " · unlabelled account" : " · аккаунт не указан") : view.caption
        let detail = unassigned ? view.machines.joined(separator: ", ")
            : ([plan, view.machines.joined(separator: ", "), view.isLocal ? (en ? "signed in here" : "вход здесь") : (en ? "not signed in here" : "без входа здесь")].filter { !$0.isEmpty }.joined(separator: " · "))
        return RemoteSettingsAccount(historyKey: view.historyKey, title: title, subtitle: detail,
            visible: !remoteAccountIsHidden(view, hidden: hidden), editable: !unassigned && view.label != nil)
    }
    let products = ["claude", "codex"].filter { product in
        views.filter { $0.product == product && $0.label != nil && !$0.historyKey.hasPrefix("u:") && !remoteAccountIsHidden($0, hidden: hidden) }.count >= 2
    }
    return RemoteSettingsModel(pollingTitle: en ? "POLL ON THIS COMPUTER" : "ОПРАШИВАТЬ НА ЭТОМ КОМПЬЮТЕРЕ",
        pollingEnabled: polling, accounts: accounts, menuProducts: products,
        showsAccounts: sync.phase == .on || views.contains { !$0.isLocal }, showsGitHub: true,
        showsV10: sync.phase != .on, v10Text: en ? "Accounts from other computers appear after GitHub sign-in ›" : "Аккаунты с других компьютеров — после входа в GitHub ›")
}

func remoteDefaultCaption(_ rawView: AccountView) -> String {
    let view = remoteSanitizedView(rawView)
    let name = view.product == "claude" ? "Claude" : "Codex"
    let plan = view.tier?.contains("20x") == true ? "Max 20x" : view.tier?.contains("5x") == true ? "Max 5x" : view.data.plan?.capitalized ?? ""
    let head = plan.isEmpty ? name : name + " " + plan
    let machines = view.machines.prefix(2).joined(separator: ", ") + (view.machines.count > 2 ? " +\(view.machines.count - 2)" : "")
    return machines.isEmpty ? head : head + " · " + machines
}

enum RemoteCaptionCommand { case enter, escape, reset }
struct RemoteCaptionEdit { var text: String; var count: Int; var value: String?; var committed: Bool }
func remoteCaptionInput(_ raw: String) -> String {
    let compatibility = raw.precomposedStringWithCompatibilityMapping
    guard !compatibility.contains(where: { $0 == "@" || $0 == "/" || $0 == "\\" }) else { return "" }
    let clean = String(String.UnicodeScalarView(raw.unicodeScalars.filter {
        let category = $0.properties.generalCategory
        return category != .control && category != .format && category != .surrogate
            && category != .lineSeparator && category != .paragraphSeparator
    })).precomposedStringWithCanonicalMapping
    return String(String.UnicodeScalarView(clean.unicodeScalars.prefix(32)))
}
func remoteCaptionEdit(original: String?, draft: String, command: RemoteCaptionCommand) -> RemoteCaptionEdit {
    if command == .escape {
        let text = original ?? ""
        return RemoteCaptionEdit(text: text, count: text.unicodeScalars.count, value: original, committed: false)
    }
    if command == .enter, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
       remoteCaptionInput(draft).isEmpty {
        let text = original ?? ""
        return RemoteCaptionEdit(text: text, count: text.unicodeScalars.count, value: original, committed: false)
    }
    let text = command == .reset ? "" : remoteCaptionInput(draft).trimmingCharacters(in: .whitespacesAndNewlines)
    return RemoteCaptionEdit(text: text, count: text.unicodeScalars.count, value: text.isEmpty ? nil : text, committed: true)
}

// C3-B presentation boundary: identities stay intact, display strings are bounded
// and single-line even for a hand-built fixture or an older persisted cache.
func remoteSnapshotText(_ raw: String, limit: Int) -> String {
    let clean = raw.precomposedStringWithCanonicalMapping.unicodeScalars.filter {
        switch $0.properties.generalCategory {
        case .control, .format, .surrogate, .lineSeparator, .paragraphSeparator: return false
        default: return true
        }
    }
    return String(String.UnicodeScalarView(clean.prefix(max(0, limit))))
}
func remoteSanitizedView(_ raw: AccountView) -> AccountView {
    var view = raw
    view.caption = remoteSnapshotText(raw.caption, limit: 128)
    view.machines = Array(raw.machines.prefix(32)).map { remoteSnapshotText($0, limit: 16) }
    view.tier = raw.tier.map { remoteSnapshotText($0, limit: 48) }
    view.data.plan = raw.data.plan.map { remoteSnapshotText($0, limit: 48) }
    if var scoped = view.data.scoped {
        scoped.name = remoteSnapshotText(scoped.name, limit: 32); view.data.scoped = scoped
    }
    if var source = view.data.source {
        source.machineName = remoteSnapshotText(source.machineName, limit: 16)
        source.statusMachineName = source.statusMachineName.map { remoteSnapshotText($0, limit: 16) }
        view.data.source = source
    }
    return view
}

// C2 stores labelled-account visibility by label, not by historyKey. The latter
// is used only for groups/local caches that do not have a label.
func remoteAccountIsHidden(_ view: AccountView, hidden: Set<String>) -> Bool {
    hidden.contains(remoteAccountID(view)) || hidden.contains(view.label ?? view.historyKey)
}
func remoteAccountID(_ view: AccountView) -> String { view.product + "|" + view.historyKey }

func remoteSimpleShowsScopedRow(_ view: AccountView, now: Date) -> Bool {
    let data = view.data
    return data.present && data.scoped != nil
        && (!view.isLocal || (data.auth == .ok && !isStale(data, now)))
}

// The frame's reader state is authoritative for live accounts and fixtures alike.
// Resolver-produced states already encode the remaining source priorities.
func remotePresentationView(_ raw: AccountView, sync: ReaderSyncState, now: Date) -> AccountView {
    var view = remoteSanitizedView(raw)
    guard !view.isLocal else { return view }
    switch sync.phase {
    case .off, .revoked, .awaitingCode: view.state = .signedOut
    case .on:
        if sync.warning != nil { view.state = .syncStalled }
    }
    if view.state == .signedOut {
        view.data.session = nil; view.data.sessionReset = nil
        view.data.weekly = nil; view.data.weeklyReset = nil; view.data.scoped = nil
        view.data.asOf = nil; view.data.resetCredits = nil
    }
    return view
}
func remoteSortedPresentationViews(views: [AccountView], language: String) -> [AccountView] {
    let locale = Locale(identifier: language == "en" ? "en_US" : "ru_RU")
    return views.map(remoteSanitizedView).sorted { a, b in
        if a.product != b.product { return a.product == "claude" }
        if a.isLocal != b.isLocal { return a.isLocal }
        let compared = a.caption.compare(b.caption, options: [.caseInsensitive], locale: locale)
        if compared != .orderedSame { return compared == .orderedAscending }
        return (a.label ?? a.historyKey) < (b.label ?? b.historyKey)
    }
}

// Keep today's full form until the AppKit caller has measured an overflow.
func remotePresentationSourceLine(_ raw: AccountView, language: String, narrow: Bool, now: Date,
                                  timeZone: TimeZone, compact: Bool = false, machineLimit: Int? = nil) -> String {
    let view = remoteSanitizedView(raw), en = language == "en"
    var machine = view.data.source?.machineName ?? view.machines.first ?? "?"
    if let limit = machineLimit, machine.count > limit { machine = String(machine.prefix(limit)) + "…" }
    guard view.state != .signedOut || view.isLocal else { return (en ? "No data from " : "Нет данных с ") + machine }
    if view.isLocal && view.data.source == nil {
        return (en ? "Data " : "Данные ") + remoteCardTimestamp(view.data.asOf, now: now, timeZone: timeZone)
    }
    return remoteCardSourceLine(view, language: language, narrow: narrow, now: now, timeZone: timeZone,
                                compact: compact, machineLimit: machineLimit)
}
func remotePresentationCard(_ raw: AccountView, sync: ReaderSyncState, language: String, narrow: Bool,
                            now: Date, timeZone: TimeZone, manual: RemoteManualPhase = .idle) -> RemoteCardPresentation {
    let view = remotePresentationView(raw, sync: sync, now: now)
    // Provider cooldown is meaningful only where this machine has a login.
    let phase: RemoteManualPhase
    if case .pollAllowed = manual, !view.isLocal { phase = .idle } else { phase = manual }
    var safeSync = sync
    safeSync.warning = sync.warning.map { remoteSnapshotText($0, limit: 256) }
    var card = remoteCardPresentation(view, sync: safeSync, language: language, narrow: narrow,
                                      now: now, timeZone: timeZone, manual: phase)
    card.sourceLine = remotePresentationSourceLine(view, language: language, narrow: narrow, now: now, timeZone: timeZone)
    if !view.isLocal && view.state == .signedOut {
        card.paceNotice = nil
        let revokedLine = language == "en" ? "Sign in to GitHub again ›" : "Войдите в GitHub заново ›"
        if sync.phase == .revoked && narrow && card.statusLine == revokedLine {
            card.statusLine = language == "en" ? "Sign in again ›" : "Войдите заново ›"
        }
    }
    return card
}

// Time-driven tray redraws do not depend on a local provider poll. Strict `>`
// freshness boundaries get a millisecond so the redraw observes the new state.
func remoteMenuRefreshDeadline(views: [AccountView], now: Date) -> Date? {
    var dates: [Date] = []
    func add(_ date: Date?, after: Bool = false) {
        guard let date = date, date.timeIntervalSince1970.isFinite else { return }
        let boundary = after ? date.addingTimeInterval(0.001) : date
        if boundary > now { dates.append(boundary) }
    }
    for view in views where !view.historyKey.hasPrefix("u:") {
        let data = view.data
        if let at = data.asOf {
            add(at.addingTimeInterval(snapshotHorizon(data)), after: true)
            add(data.source == nil ? at : at.addingTimeInterval(-300))
        }
        add(data.sessionReset); add(data.weeklyReset); add(data.scoped?.reset)
        if let source = data.source {
            add(source.freshUntil, after: true)
            add(source.lastSeenAt?.addingTimeInterval(1800), after: true)
            add(source.retryUntil)
        }
    }
    return dates.min()
}
