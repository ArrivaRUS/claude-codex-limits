import Foundation

func remoteSimplePanelSubtitle(_ titles: [String], paused: Bool, language: String) -> String {
    if !titles.isEmpty { return titles.joined(separator: " · ") }
    if paused { return language == "en" ? "monitoring paused" : "сбор выключен" }
    return language == "en" ? "not found" : "не найдено"
}

// Per-machine observations stay separate from the winning account values.
struct RemoteMachineReading {
    var machineId: String
    var name: String
    var asOf: Date?
    var interval: TimeInterval?
    var isLocal: Bool
}
enum RemoteFreshnessTone: Equatable { case fresh, late, old, unknown }
func remoteSourceFreshness(asOf: Date?, interval: TimeInterval?, now: Date) -> RemoteFreshnessTone {
    guard let at = asOf, at.timeIntervalSince1970.isFinite, now.timeIntervalSince1970.isFinite else { return .unknown }
    // A peer clock ahead of ours is still a reading: display its time verbatim
    // and clamp only the age, as in the protocol's future-asOf rule.
    let age = max(0, now.timeIntervalSince(at))
    let cadence = interval.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 14400
    // A reading older than a day is always red, even for a malformed long schedule.
    if age > 86400 { return .old }
    return age <= cadence + 900 ? .fresh : .late
}
struct RemoteHeaderSource {
    var name: String
    var tone: RemoteFreshnessTone
    var reading: RemoteMachineReading
}
struct RemoteSourceHeader {
    var sources: [RemoteHeaderSource]
    var tooltip: String
    var overflow: Int { max(0, sources.count - 2) }
    var plainText: String {
        sources.prefix(2).map { "● " + $0.name }.joined(separator: ", ") + (overflow > 0 ? " +\(overflow)" : "")
    }
}
func remoteSourceHeader(_ raw: AccountView, now: Date, language: String, timeZone: TimeZone) -> RemoteSourceHeader {
    let view = remoteSanitizedView(raw), en = language == "en"
    var records = view.sourceReadings
    if records.isEmpty {
        var names = view.machines
        if names.isEmpty { names = [en ? "this computer" : "этот компьютер"] }
        records = names.enumerated().map { index, name in
            let ownsValues = view.data.source.map { $0.machineName == name } ?? (view.isLocal && index == 0)
            return RemoteMachineReading(machineId: name, name: name, asOf: ownsValues ? view.data.asOf : nil,
                interval: ownsValues ? view.data.source?.interval.map(Double.init) : nil, isLocal: view.isLocal && index == 0)
        }
    }
    // The header hit covers the title as well as the source names. Keep the
    // complete custom caption first even when drawing truncates that title.
    var lines: [String] = view.caption.isEmpty || view.caption == remoteDefaultCaption(view) ? [] : [view.caption]
    let sources = records.map { record -> RemoteHeaderSource in
        let cleanName = remoteSnapshotText(record.name, limit: 32)
        let name = cleanName.isEmpty ? (record.isLocal ? (en ? "this computer" : "этот компьютер") : "?") : cleanName
        let tone = remoteSourceFreshness(asOf: record.asOf, interval: record.interval, now: now)
        let status: String
        switch tone {
        case .fresh: status = en ? "on time" : "в срок"
        case .late: status = en ? "late" : "давно"
        case .old: status = en ? "over a day" : "больше суток"
        case .unknown: status = en ? "no readings" : "нет показаний"
        }
        let moment = tone == .unknown ? "—" : remoteCardTimestamp(record.asOf, now: now, timeZone: timeZone,
            compactOtherDay: tone == .old)
        lines.append(name + " — " + moment + ", " + status)
        return RemoteHeaderSource(name: name, tone: tone, reading: record)
    }
    return RemoteSourceHeader(sources: sources, tooltip: lines.joined(separator: "\n"))
}
struct RemoteHeaderSourceRun {
    var name: String
    var tone: RemoteFreshnessTone
    var x: Double
    var dotWidth: Double = 6
    var nameGap: Double = 3
}
struct RemoteSourceHeaderLayout {
    var runs: [RemoteHeaderSourceRun]
    var width: Double
    var overflow: Int
    var overflowX: Double
}
func remoteSourceHeaderMinimumWidth(_ header: RemoteSourceHeader, measure: (String) -> Double) -> Double {
    let count = min(2, header.sources.count)
    return Double(count) * 9 + Double(max(0, count - 1)) * measure(", ")
        + (header.overflow > 0 ? measure(" +\(header.overflow)") : 0)
}
func remoteSourceHeaderLayout(_ header: RemoteSourceHeader, availableWidth: Double,
                              measure: (String) -> Double) -> RemoteSourceHeaderLayout {
    let shown = Array(header.sources.prefix(2)), budget = max(0, availableWidth)
    var names = shown.map { $0.name }
    let fixed = remoteSourceHeaderMinimumWidth(header, measure: measure)
    func total() -> Double { fixed + names.reduce(0) { $0 + measure($1) } }
    if total() > budget {
        names = names.map { $0.count > 8 ? String($0.prefix(8)) + "…" : $0 }
        while total() > budget, let index = names.indices.filter({ !names[$0].isEmpty })
            .max(by: { measure(names[$0]) < measure(names[$1]) }) {
            let base = names[index].hasSuffix("…") ? String(names[index].dropLast()) : names[index]
            names[index] = base.count > 1 ? String(base.dropLast()) + "…" : ""
        }
    }
    var x = 0.0, runs: [RemoteHeaderSourceRun] = []
    for i in shown.indices {
        runs.append(RemoteHeaderSourceRun(name: names[i], tone: shown[i].tone, x: x))
        x += 9 + measure(names[i])
        if i + 1 < shown.count { x += measure(", ") }
    }
    let overflowX = x
    if header.overflow > 0 { x += measure(" +\(header.overflow)") }
    return RemoteSourceHeaderLayout(runs: runs, width: x, overflow: header.overflow, overflowX: overflowX)
}
func remoteQuotaFooterHeight(advanced: Bool, statusLine: String = "") -> Double { advanced && statusLine.isEmpty ? 0 : 18 }
func remoteVisibleSourceLine(_ text: String, advanced: Bool) -> String { "" }
func remoteVisibleSourceLine(_ card: RemoteCardPresentation, advanced: Bool) -> String {
    remoteVisibleSourceLine(card.sourceLine, advanced: advanced)
}

// C3-B value models. No preferences, singleton history, AppKit, or runtime effects.
// A reserved second header line keeps every Simple card at the same height.
let REMOTE_SIMPLE_HEADER_EXTRA = 13.0
struct RemoteSimplePanelHeights {
    var rows: Int
    var scopedExtra: Double
    var headerExtra: Double
    var footerHeight: Double
    var baseCardHeight: Double { 152 }
    var baseWindowHeight: Double { 286 }
    var rowGap: Double { 12 }
    var cardHeight: Double { baseCardHeight + scopedExtra + headerExtra + footerHeight }
    // The first row's reserved header/footer remain explicit; following rows
    // contribute their whole card, including those same components.
    var windowBaselineHeight: Double {
        baseWindowHeight + scopedExtra + Double(max(0, rows - 1)) * (cardHeight + rowGap)
    }
    var windowHeight: Double { windowBaselineHeight + headerExtra + footerHeight }
}
func remoteSimplePanelHeights(views: [AccountView], now: Date) -> RemoteSimplePanelHeights {
    let visible = views
    return RemoteSimplePanelHeights(rows: (visible.count + 1) / 2,
        scopedExtra: visible.contains { remoteSimpleShowsScopedRow($0, now: now) } ? 15 : 0,
        headerExtra: visible.isEmpty ? 0 : REMOTE_SIMPLE_HEADER_EXTRA,
        footerHeight: visible.isEmpty ? 0 : remoteQuotaFooterHeight(advanced: false))
}
struct RemotePanelLayout {
    var cards: [CGRect]
    var intervalRect: CGRect
    var authorRect: CGRect
    var windowHeight: Double
}

func remoteSimplePanelLayout(views: [AccountView], now: Date) -> RemotePanelLayout {
    let visible = views
    let heights = remoteSimplePanelHeights(views: visible, now: now)
    if visible.isEmpty {
        return RemotePanelLayout(cards: [], intervalRect: CGRect(x: 16, y: 224, width: 328, height: 24),
            authorRect: CGRect(x: 16, y: 265, width: 328, height: 16), windowHeight: heights.windowHeight)
    }
    let cardH = heights.cardHeight, height = heights.windowHeight
    let cards = visible.indices.map { i -> CGRect in
        let wide = visible.count == 1 || (visible.count % 2 == 1 && i == visible.count - 1)
        return CGRect(x: wide || i % 2 == 0 ? 16 : 186,
                      y: 58 + Double(i / 2) * (cardH + heights.rowGap), width: wide ? 328 : 158, height: cardH)
    }
    return RemotePanelLayout(cards: cards, intervalRect: CGRect(x: 16, y: height - 62, width: 328, height: 24),
        authorRect: CGRect(x: 16, y: height - 21, width: 328, height: 16), windowHeight: height)
}

func remoteAdvancedCardHeight(rowHeights: [Double], noticeHeight: Double, footerHeight: Double) -> Double {
    38 + rowHeights.reduce(0, +) + Double(max(0, rowHeights.count - 1)) + noticeHeight + footerHeight
}

// Shared by the Foundation-only geometry and the real Advanced rows. History can
// change recent-rate text, but cannot change the row kind or its measured height.
// 3.4.1 (owner 2026-11-02), as linux/ccl/limits.py paced_limits: Claude always
// keeps its session row; Codex shows one only while the service reports a
// session value, so a returning 5-hour window brings the row back by itself.
func limitShowsSessionRow(product: String, session: Double?) -> Bool {
    product == "claude" || session != nil
}
func remoteAdvancedMetrics(_ view: AccountView) -> [String] {
    (limitShowsSessionRow(product: view.product, session: view.data.session) ? ["session"] : [])
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
    // Reader/source status lives in the header and footer. Within V4 the
    // snapshot still owns its complete forecast row, regardless of that status.
    if !view.isLocal && view.state == .signedOut { return .inactive }
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
    let accounts = views.map(remoteSanitizedView)
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
        let plan = view.tier?.contains("20x") == true ? "Max 20x" : view.tier?.contains("5x") == true ? "Max 5x" : view.data.plan?.capitalized ?? ""
        let title = view.caption
        let detail = ([plan, view.machines.joined(separator: ", "), view.isLocal ? (en ? "signed in here" : "вход здесь") : (en ? "not signed in here" : "без входа здесь")].filter { !$0.isEmpty }.joined(separator: " · "))
        return RemoteSettingsAccount(historyKey: view.historyKey, title: title, subtitle: detail,
            visible: !remoteAccountIsHidden(view, hidden: hidden), editable: view.label != nil)
    }
    let products = ["claude", "codex"].filter { product in
        views.filter { $0.product == product && $0.label != nil && !remoteAccountIsHidden($0, hidden: hidden) }.count >= 2
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

// History keeps the single-line account identity from before Simple's D2 split.
// The same title is drawn in its segment and exposed as the segment tooltip.
func remoteHistorySelectorTitle(_ raw: AccountView, language: String) -> String {
    let view = remoteSanitizedView(raw)
    if let custom = view.customCaption, !custom.isEmpty { return custom }
    if !view.caption.isEmpty && view.caption != remoteDefaultCaption(view) { return view.caption }
    var subscription = view; subscription.machines = []
    if subscription.tier == nil {
        if subscription.data.plan?.lowercased() == "max_20x" { subscription.tier = "max_20x" }
        if subscription.data.plan?.lowercased() == "max_5x" { subscription.tier = "max_5x" }
    }
    return remoteDefaultCaption(subscription)
}

struct HistorySelectorLayout {
    var fontSize: CGFloat { 10.5 }
    var titles: [String]
    var rects: [CGRect] // segments, relative to hy
    var container: CGRect?
    var ownRow: Bool
    var extraHeight: CGFloat
}
func remoteHistorySelectorLayout(titles: [String], measuredWidths: [CGFloat], headingWidth: CGFloat,
                                 availableWidth: CGFloat, expanded: Bool) -> HistorySelectorLayout {
    guard expanded, !titles.isEmpty else {
        return HistorySelectorLayout(titles: titles, rects: [], container: nil, ownRow: false, extraHeight: 0)
    }
    let natural = measuredWidths.map { $0 + 16 }, count = natural.count
    let total = natural.reduce(0, +) + CGFloat(count - 1) + 4
    let own = total + headingWidth + 22 > availableWidth
    var widths = natural
    if own {
        let available = availableWidth - 4 - CGFloat(count - 1), equal = available / CGFloat(count)
        if natural.allSatisfy({ $0 <= equal }) { widths = natural.map { _ in equal } }
        else if natural.reduce(0, +) <= available {
            let extra = (available - natural.reduce(0, +)) / CGFloat(count); widths = natural.map { $0 + extra }
        } else {
            let cap = max(equal, available - (natural.min() ?? 0))
            widths = natural.map { min($0, cap) }
            let extra = (available - widths.reduce(0, +)) / CGFloat(count); widths = widths.map { $0 + extra }
        }
    }
    let container = CGRect(x: own ? 0 : availableWidth - total, y: own ? 22 : 0,
                           width: own ? availableWidth : total, height: 18)
    var x = container.minX + 2
    let rects = widths.map { width -> CGRect in
        defer { x += width + 1 }
        return CGRect(x: x, y: container.minY + 2, width: width, height: 14)
    }
    return HistorySelectorLayout(titles: titles, rects: rects, container: container, ownRow: own, extraHeight: own ? 22 : 0)
}
func remoteHistoryFittedTitle(_ title: String, width: Double, measure: (String) -> Double) -> String {
    if measure(title) <= width { return title }
    var value = title
    while !value.isEmpty && measure(value.trimmingCharacters(in: .whitespaces) + "…") > width { value.removeLast() }
    return value.trimmingCharacters(in: .whitespaces) + "…"
}
struct RemoteHistoryLayout {
    var height: Double
    var bodyTop: Double
    var tableTop: Double
    var rowTops: [Double]
    var notesTop: Double
    var columnRightEdges: [Double] { [190, 283, 334] }
}
func remoteHistoryLayout(rowCount: Int, selectorExtra: Double, noteLines: [String], expanded: Bool,
                         warningHeight: Double = 0, emptyHeight: Double = 0) -> RemoteHistoryLayout {
    let body = 8 + 22 + selectorExtra + warningHeight, table = body + 82 + emptyHeight
    let notes = table + 23 + 15 * Double(rowCount) + 2
    let height = expanded ? notes + remoteMoneyNotesHeight(noteLines) - 1 + 9 : 35 + warningHeight
    return RemoteHistoryLayout(height: height, bodyTop: body, tableTop: table,
        rowTops: expanded ? (0..<rowCount).map { table + 23 + 15 * Double($0) } : [], notesTop: notes)
}
struct RemoteAdvancedLayout {
    var cards: [CGRect]
    var history: CGRect
    var footer: CGRect
    var credit: CGRect
    var height: Double
}
func remoteAdvancedLayout(cardHeights: [Double], historyHeight: Double, placeholderHeight: Double = 0) -> RemoteAdvancedLayout {
    var top = 58.0
    let cards = cardHeights.map { height -> CGRect in
        defer { top += height + 5 }
        return CGRect(x: 15, y: top, width: 330, height: height)
    }
    if placeholderHeight > 0 { top += placeholderHeight + 5 }
    let history = CGRect(x: 15, y: top, width: 330, height: historyHeight)
    let height = top + historyHeight + 6 + 59
    return RemoteAdvancedLayout(cards: cards, history: history,
        footer: CGRect(x: 16, y: height - 59, width: 328, height: 24),
        credit: CGRect(x: 16, y: height - 22, width: 328, height: 12), height: height)
}

enum RemoteCaptionCommand { case enter, escape, reset }
struct RemoteCaptionEdit { var text: String; var count: Int; var value: String?; var committed: Bool }
func remoteCaptionInput(_ raw: String) -> String {
    remoteCaptionValidatedInput(raw).value
}
struct RemoteCaptionEditorSeed {
    var text: String
    var count: Int
    var selection: NSRange
}
/// Initial display text only: machine-derived defaults can contain separators.
/// Typed/pasted input still rejects the whole string through the normal validator.
func remoteCaptionEditorSeed(_ caption: String) -> RemoteCaptionEditorSeed {
    let safe = caption.unicodeScalars.filter { scalar in
        !String(scalar).precomposedStringWithCompatibilityMapping.unicodeScalars.contains {
            $0.value == 0x40 || $0.value == 0x2F || $0.value == 0x5C
        }
    }
    let text = remoteCaptionInput(String(String.UnicodeScalarView(safe)))
    return RemoteCaptionEditorSeed(text: text, count: text.unicodeScalars.count,
        selection: NSRange(location: 0, length: text.utf16.count))
}
func remoteCaptionEdit(original: String?, draft: String, command: RemoteCaptionCommand) -> RemoteCaptionEdit {
    if command == .escape {
        let text = original ?? ""
        return RemoteCaptionEdit(text: text, count: text.unicodeScalars.count, value: original, committed: false)
    }
    if command == .enter, remoteCaptionValidatedInput(draft).error != nil {
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
    view.customCaption = raw.customCaption.map { remoteSnapshotText($0, limit: 128) }
    view.machines = Array(raw.machines.prefix(32)).map { remoteSnapshotText($0, limit: 16) }
    view.sourceReadings = Array(raw.sourceReadings.prefix(64)).map { record in
        var copy = record; copy.name = remoteSnapshotText(record.name, limit: 32); return copy
    }
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
                                compact: compact, machineLimit: machineLimit, compactOtherDay: narrow)
}
func remotePresentationManualPhase(isLocal: Bool, manual: RemoteManualPhase,
                                   readerManual: RemoteManualPhase?, now: Date) -> RemoteManualPhase {
    guard !isLocal else { return manual }
    let phase: RemoteManualPhase
    if case .pollAllowed = manual { phase = readerManual ?? .idle }
    else { phase = readerManual ?? manual }
    if case .pollAllowed = phase { return .idle }
    if case .checked(let at) = phase, !(0..<60).contains(now.timeIntervalSince(at)) { return .idle }
    return phase
}

func remotePresentationCard(_ raw: AccountView, sync: ReaderSyncState, language: String, narrow: Bool,
                            now: Date, timeZone: TimeZone, manual: RemoteManualPhase = .idle,
                            productAccountCount: Int = 1, readerManual: RemoteManualPhase? = nil) -> RemoteCardPresentation {
    let view = remotePresentationView(raw, sync: sync, now: now)
    // Provider cooldown belongs to the local card; the reader's result belongs
    // to every foreign card and retains the same 60-second lifetime.
    let phase = remotePresentationManualPhase(isLocal: view.isLocal, manual: manual,
        readerManual: readerManual, now: now)
    var safeSync = sync
    safeSync.warning = sync.warning.map { remoteSnapshotText($0, limit: 256) }
    var card = remoteCardPresentation(view, sync: safeSync, language: language, narrow: narrow,
                                      now: now, timeZone: timeZone, manual: phase)
    let defaultCaption = view.caption.isEmpty || view.caption == remoteDefaultCaption(view)
    if productAccountCount >= 2 && view.isLocal && defaultCaption {
        let machines = view.machines.prefix(2).joined(separator: ", ")
            + (view.machines.count > 2 ? " +\(view.machines.count - 2)" : "")
        card.simpleTitle = (view.product == "claude" ? "Claude" : "Codex")
            + (machines.isEmpty ? "" : " · " + machines)
        card.machineSuffix = machines.isEmpty ? "" : "· " + machines
    }
    // The account resolver already orders this computer first, then peers.
    // Keep the legacy C3-A presentation and Advanced header contracts intact.
    card.simpleTitle = defaultCaption ? (view.product == "claude" ? "Claude" : "Codex") : view.caption
    let header = remoteSourceHeader(view, now: now, language: language, timeZone: timeZone)
    card.sourceHeader = header
    card.simpleMachines = header.plainText
    card.machineSuffix = "· " + header.plainText
    // Keep the historical source tooltip verbatim; expose the new per-machine
    // status on its own header hit/AX element, including sources hidden by +N.
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

// Last-resort end truncation is a model decision, after a source machine has
// surrendered its width. The renderer draws this measured result unchanged.
func remoteFittedLineEnd(_ text: String, availableWidth: Double, measure: (String) -> Double) -> String {
    let width = max(0, availableWidth)
    if measure(text) <= width { return text }
    guard measure("…") <= width else { return "" }
    var tail = text
    while !tail.isEmpty {
        tail.removeLast()
        let candidate = tail.trimmingCharacters(in: .whitespaces) + "…"
        if measure(candidate) <= width { return candidate }
    }
    return "…"
}

func remoteFittedStatusLine(_ raw: AccountView, presentation: RemoteCardPresentation, language: String,
                            narrow: Bool = true, now: Date, timeZone: TimeZone,
                            availableWidth: Double, measure: (String) -> Double) -> String {
    let line = presentation.statusLine, width = max(0, availableWidth)
    guard narrow && !line.isEmpty else { return line }
    if measure(line) <= width { return line }
    let view = remoteSanitizedView(raw)
    let offline = remoteCardLine2(view, state: .offline, phase: .idle, lang: language, wide: false,
        now: now, timeZone: timeZone)
    // A reader phase or a projected sync-stalled state must retain its own copy.
    if view.state == .offline && line == offline {
        var shortest = line
        for limit in stride(from: 8, through: 0, by: -1) {
            let candidate = remoteCardLine2(view, state: .offline, phase: .idle, lang: language, wide: false,
                now: now, timeZone: timeZone, machineLimit: limit)
            shortest = candidate
            if measure(candidate) <= width { return candidate }
        }
        return remoteFittedLineEnd(shortest, availableWidth: width, measure: measure)
    }
    return remoteFittedLineEnd(line, availableWidth: width, measure: measure)
}

// Only the condensed measurement decides whether a machine line needs ellipsis.
func remoteFittedSimpleMachines(_ text: String, availableWidth: Double,
                                measureCondensed: (String) -> Double) -> String {
    guard !text.isEmpty else { return "" }
    let width = max(0, availableWidth)
    if measureCondensed(text) <= width { return text }
    guard measureCondensed("…") <= width else { return "" }
    var tail = text
    while !tail.isEmpty {
        tail.removeLast()
        let candidate = tail.trimmingCharacters(in: .whitespaces) + "…"
        if measureCondensed(candidate) <= width { return candidate }
    }
    return "…"
}

struct RemoteSettingsErrorPresentation {
    var text: String
    var lines: [String]
    var height: Double
    var accessibilityValue: String
}
func remoteSettingsErrorPresentation(_ text: String, availableWidth: Double, lineHeight: Double = 14,
                                     measureWidth: (String) -> Double) -> RemoteSettingsErrorPresentation {
    let width = max(0, availableWidth)
    var lines: [String] = [], line = ""
    // Word wrapping also splits a single oversized token, so service messages
    // and identifiers cannot cross the right edge of the settings card.
    for word in text.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
        let candidate = line.isEmpty ? word : line + " " + word
        if measureWidth(candidate) <= width { line = candidate; continue }
        if !line.isEmpty { lines.append(line); line = "" }
        for character in word {
            let next = line + String(character)
            if !line.isEmpty && measureWidth(next) > width { lines.append(line); line = "" }
            if measureWidth(String(character)) <= width { line.append(character) }
        }
    }
    if !line.isEmpty { lines.append(line) }
    if lines.count > 3 {
        lines = Array(lines.prefix(3))
        var last = lines[2]
        while !last.isEmpty && measureWidth(last + "…") > width { last.removeLast() }
        lines[2] = measureWidth("…") <= width ? last.trimmingCharacters(in: .whitespaces) + "…" : last
    }
    return RemoteSettingsErrorPresentation(text: text, lines: lines,
        height: Double(lines.count) * max(0, lineHeight), accessibilityValue: text)
}

func remoteAdvancedHeaderRightBoundary(cardMaxX: Double) -> Double { cardMaxX - 28 }

// The renderer passes measured widths including each pill's padding. Machines
// receive the remaining width only after the complete product title and pills.
struct RemoteAdvancedHeaderWidths {
    var title: Double
    var badge: Double
    var plan: Double
    var machines: Double
}
func remoteAdvancedHeaderWidths(availableWidth: Double, titleWidth: Double,
                                 badgeWidth: Double, planWidth: Double, machineWidth: Double,
                                 isCustomTitle: Bool, minimumTitleWidth: Double, minimumMachineWidth: Double = 0) -> RemoteAdvancedHeaderWidths {
    let available = max(0, availableWidth), naturalTitle = max(0, titleWidth)
    let badge = max(0, badgeWidth), plan = max(0, planWidth), machines = max(0, machineWidth)
    let titleGap = badge > 0 || plan > 0 || machines > 0 ? 7.0 : 0
    let badgeGap = badge > 0 && (plan > 0 || machines > 0) ? 5.0 : 0
    let planGap = plan > 0 && machines > 0 ? 5.0 : 0
    let fixed = badge + plan + titleGap + badgeGap + planGap
    let titleBudget = max(0, available - fixed)
    // Custom L can shrink, while a product name keeps its natural measured
    // width. The normal 263pt row has room for both fixed pills and the product.
    let originalTitle = isCustomTitle ? min(naturalTitle, max(minimumTitleWidth, titleBudget)) : naturalTitle
    let minimum = max(0, minimumMachineWidth)
    let title = minimum > 0 ? min(originalTitle, max(0, available - fixed - minimum)) : originalTitle
    return RemoteAdvancedHeaderWidths(title: title, badge: badge, plan: plan,
        machines: min(machines, max(minimum, available - fixed - title)))
}

// C3-A's formatter remains unchanged for its public contract. Actual C3-B scene
// rendering uses the explicit scene timezone for every timestamp in a verdict.
func remoteAdvancedVerdict(_ row: AdvRow, data: LimitData, now: Date, language: String,
                            timeZone: TimeZone) -> String {
    let en = language == "en"
    func t(_ ru: String, _ english: String) -> String { en ? english : ru }
    func moment(_ at: Date) -> String { remoteCardTimestamp(at, now: now, timeZone: timeZone) }
    // A missing foreign window is unknown; do not instruct the reader to open it.
    if row.limit?.used == nil && row.limit?.pace == nil { return "—" }
    guard remotePaceTimeValid(data, now: now) else { return t("Нет свежих данных · темп не считаем", "No fresh data · pace paused") }
    func percent(_ value: Double) -> String { String(Int(value.rounded())) + "%" }
    if let at = data.asOf, now.timeIntervalSince(at) > snapshotHorizon(data) {
        return row.limit?.pace?.projectedPct.map { t("Прогноз на снимке: ", "Snapshot forecast: ") + percent($0) }
            ?? t("На снимке мало данных для темпа", "Not enough pace data in snapshot")
    }
    if row.kind == .stale {
        let reset = row.limit?.pace.map { $0.reset <= now } == true
        return data.asOf.map { t(reset ? "Окно сброшено · снимок " : "по данным на ", reset ? "Window reset · snapshot " : "as of ") + moment($0) }
            ?? t("Нет свежих данных · темп не считаем", "No fresh data · pace paused")
    }
    guard let pace = row.limit?.pace else {
        return row.limit?.used != nil ? t("Нет времени окна · темп не считаем", "Window timing unknown · pace paused")
            : t("Окно не активно · откроется с первым запросом", "Window inactive · opens with the first request")
    }
    switch row.kind {
    case .exhausted: return t("Лимит исчерпан · сброс в ", "Limit reached · resets at ") + moment(pace.reset)
    case .tooEarly: return t("Мало данных для темпа · сброс в ", "Not enough data for pace · resets at ") + moment(pace.reset)
    default: break
    }
    if let at = pace.runsOutAt {
        let minutes = max(0, Int(pace.reset.timeIntervalSince(at) / 60))
        let span = minutes >= 60 ? t("\(minutes / 60) ч", "\(minutes / 60) h") : t("\(minutes) мин", "\(minutes) min")
        return t("Кончится в ", "Runs out at ") + moment(at) + t(", за ", ", ") + span + t(" до сброса", " before reset")
    }
    if let projected = pace.projectedPct {
        return t(projected.rounded() >= 85 ? "Хватит впритык (прогноз " : "Хватит до сброса (прогноз ",
                 projected.rounded() >= 85 ? "Barely lasts (forecast " : "Lasts until reset (forecast ") + percent(projected) + ")"
    }
    return t("Хватит до сброса", "Lasts until reset")
}

func remotePollAccessibleTitle(_ sec: TimeInterval, language: String) -> String {
    let en = language == "en"
    switch sec {
    case 900: return en ? "15 minutes" : "15 минут"
    case 1800: return en ? "30 minutes" : "30 минут"
    case 3600: return en ? "1 hour" : "1 час"
    case 14400: return en ? "4 hours" : "4 часа"
    default: return en ? "Auto" : "Авто"
    }
}

func remotePollDurationText(_ seconds: Int, language: String) -> String {
    let hours = seconds % 3600 == 0
    let count = max(1, seconds / (hours ? 3600 : 60))
    let unit: String
    if language == "en" {
        unit = hours ? (count == 1 ? "hour" : "hours") : (count == 1 ? "minute" : "minutes")
    } else if (11...14).contains(count % 100) {
        unit = hours ? "часов" : "минут"
    } else if count % 10 == 1 {
        unit = hours ? "час" : "минута"
    } else if (2...4).contains(count % 10) {
        unit = hours ? "часа" : "минуты"
    } else {
        unit = hours ? "часов" : "минут"
    }
    return "\(count) \(unit)"
}

// Auto participation comes from C3-A; the native interval control retains its
// existing accessible duration wording instead of the compact schedule copy.
func remotePollTooltip(_ sec: TimeInterval, views: [AccountView], enabled: Set<String>,
                       intervals: [String: TimeInterval], auto: Bool, language: String,
                       now: Date = Date(), timeZone: TimeZone = .current) -> String {
    let model = remoteAutoFooter(views: views, enabled: enabled, intervals: intervals, language: language,
                                 now: now, timeZone: timeZone)
    let en = language == "en"
    if model.noSubscriptions {
        // A local-only Off panel keeps the established explanation. With foreign
        // accounts, explain that their schedules belong to the publishing machines.
        if enabled.isEmpty && !views.contains(where: { !$0.isLocal }) {
            return en ? "No subscriptions enabled" : "Нет включённых подписок"
        }
        return model.tooltip
    }
    let label = remotePollAccessibleTitle(sec, language: language)
    guard auto else { return label }
    let providers = model.products.compactMap { product -> String? in
        guard let interval = intervals[product], [900.0, 1800, 3600, 14400].contains(interval),
              sec == 0 || sec == interval else { return nil }
        let name = product == "claude" ? "Claude Code" : "Codex"
        return sec == 0 ? name + " → " + remotePollAccessibleTitle(interval, language: language) : name
    }
    guard !providers.isEmpty else { return label }
    let summary = label + (sec == 0 ? ": " : (en ? "\nAuto: " : "\nАвто: ")) + providers.joined(separator: "; ")
    guard sec == 0 else { return summary }
    let foreign = model.legend.filter { $0.machine != nil }
    guard !foreign.isEmpty else { return summary }
    let details = foreign.compactMap { row -> String? in
        guard let machine = row.machine else { return nil }
        let name = row.product == "claude" ? "Claude Code" : "Codex"
        let value: String
        if row.tone == .fresh, !row.valueIsTime, let seconds = row.intervalSeconds {
            value = remotePollDurationText(seconds, language: language)
        } else if row.asOf == nil {
            value = en ? "no data yet" : "данных пока нет"
        } else if row.tone == .fresh {
            value = en ? "interval unknown" : "интервал неизвестен"
        } else {
            let since = remoteCardTimestamp(row.asOf, now: now, timeZone: timeZone)
            value = (en ? "no new data since " : "нет новых данных с ") + since
        }
        return "\(name) → \(value) (\(machine))."
    }
    return summary + (en ? " (this Mac)." : " (этот Mac).") + "\n" + details.joined(separator: "\n")
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
    for view in views {
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
