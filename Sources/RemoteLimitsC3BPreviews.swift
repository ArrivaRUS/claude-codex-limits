import AppKit
import CryptoKit
import ImageIO

// C3-10 assertions were written before the renderer (2026-10-28).
// AppKit-only: invoke AFTER NSApplication registration in --subscriptions-selftest.
// Input defaults must already be MemorySelfTestDefaults. No app delegate, callback,
// provider, credential, runtime history or live sync is created by these fixtures.
// Render clocks/timezone/manual phase are scoped by withRemoteRenderScene.
// Expanded history is used only inside the isolated scene: the production seam
// substitutes an empty UsageIndex and RAM history before touching any singleton.
// Naming covers V5 1...7, both 3a/3b, and both explanatory 7 off/revoked scenes.
// Actual presentation strings come from the C3-A golden JSON files, never new copies.

private struct C3PreviewManifest: Decodable {
    struct File: Decodable { var filename: String; var sha256: String }
    var files: [File]
}

/// Shared output directory for both the legacy and C3 subscription bitmap fixtures.
func c3PreviewDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
    let base = [environment["CCL_PREVIEW_DIR"], environment["TMPDIR"]]
        .compactMap { $0 }.first { !$0.isEmpty } ?? NSTemporaryDirectory()
    let directory = URL(fileURLWithPath: (base as NSString).expandingTildeInPath, isDirectory: true)
        .appendingPathComponent("ccl-c3-previews", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// Call once, AFTER every legacy and C3 save. Never includes leftovers from an older run.
@discardableResult
func c3WritePreviewManifest(previewDir: URL, files: [String]) throws -> Int {
    let names = Set(files).sorted()
    var entries: [[String: String]] = []
    for name in names {
        guard !name.isEmpty, URL(fileURLWithPath: name).lastPathComponent == name, name.hasSuffix(".png") else {
            throw NSError(domain: "C3Preview", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid preview filename"])
        }
        let png = try Data(contentsOf: previewDir.appendingPathComponent(name))
        let digest = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        entries.append(["filename": name, "sha256": digest])
    }
    let data = try JSONSerialization.data(withJSONObject: ["files": entries], options: [.prettyPrinted, .sortedKeys])
    try data.write(to: previewDir.appendingPathComponent("manifest.json"), options: .atomic)
    return entries.count
}

private struct C3PreviewGolden: Decodable {
    var `case`: String; var state: Int; var status: String; var language: String; var narrow: Bool
    var statusLine: String; var tone: String; var badge: String; var tooltip: String; var action: String?
}
private struct C3PreviewManualGolden: Decodable { var language: String; var phase: String; var text: String }
private let C3_PREVIEW_ZONE = TimeZone(secondsFromGMT: 0)!
private func c3PreviewDate(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
private let C3_PREVIEW_NOW = c3PreviewDate("2026-10-12T16:00:00Z")

private func c3PreviewView(state: RemoteCardState = .fresh, status: String = "ok", product: String = "claude",
                           identity: Int = 1, machines: [String] = ["vps"]) -> AccountView {
    var source = RemoteSource(machineId: "c3-vps", machineName: machines.last ?? "vps")
    source.asOf = c3PreviewDate("2026-10-12T15:43:00Z")
    source.nextAt = c3PreviewDate("2026-10-12T16:43:00Z")
    source.interval = 3600; source.mode = "auto"; source.status = status
    source.lastSeenAt = c3PreviewDate("2026-10-12T15:52:00Z")
    source.freshUntil = c3PreviewDate("2026-10-12T17:03:00Z")
    source.attemptAt = source.asOf
    if status == "rate_limited" { source.retryUntil = c3PreviewDate("2026-10-12T16:30:00Z") }
    var data = LimitData(session: product == "claude" ? 42.5 : 28, weekly: product == "claude" ? 61 : 47,
                         sessionReset: c3PreviewDate("2026-10-12T18:00:00Z"), weeklyReset: c3PreviewDate("2026-10-15T07:00:00Z"),
                         plan: product == "claude" ? "max" : "pro", asOf: source.asOf, fromCache: true, source: source)
    if product == "claude" {
        data.scoped = ScopedLimit(name: "Fable", percent: 30, reset: c3PreviewDate("2026-10-16T07:00:00Z"), severity: nil)
    }
    if state == .stale {
        // State 2 is beyond V4 while its publishing machine is still online.
        let at = c3PreviewDate("2026-10-12T15:00:00Z")
        data.asOf = at; data.source?.asOf = at; data.source?.attemptAt = at
        data.source?.interval = 1800; data.source?.nextAt = c3PreviewDate("2026-10-12T15:30:00Z")
        data.source?.freshUntil = c3PreviewDate("2026-10-12T15:50:00Z")
        data.source?.lastSeenAt = c3PreviewDate("2026-10-12T15:59:00Z")
    }
    // Keep provenance for the mandatory no-data footer in state 7. The reader
    // frame clears all snapshot values uniformly for every foreign account.
    let label = "c3000000000000" + String(format: "%02x", identity)
    return AccountView(product: product, label: label, historyKey: label,
        caption: (product == "claude" ? "Claude Max 20x" : "Codex Pro") + " · " + machines.joined(separator: ", "),
        data: data, isLocal: false, tier: product == "claude" ? "default_claude_max_20x" : nil,
        usageDays: [:], machines: machines, state: state)
}

/// Returns the number of successfully written C3 PNGs. A shared registry is also
/// filled by the caller's legacy save helper, then passed to the final manifest.
@discardableResult
func runRemoteLimitsC3BPreviews(previewDir: URL, files: inout [String], check: (Bool, String) -> Void) -> Int {
    guard CommandLine.arguments.contains("--subscriptions-selftest"), UserDefaults.standard is MemorySelfTestDefaults else {
        check(false, "C3-10 requires isolated subscription selftest defaults"); return 0
    }
    guard let fixtures = remoteLimitsFixturesDir() else {
        check(false, "C3-10 explicit C3 golden fixture directory missing"); return 0
    }
    let golden: [C3PreviewGolden], manual: [C3PreviewManualGolden]
    do {
        golden = try JSONDecoder().decode([C3PreviewGolden].self,
            from: Data(contentsOf: URL(fileURLWithPath: fixtures).appendingPathComponent("c3-v5-golden.json")))
        manual = try JSONDecoder().decode([C3PreviewManualGolden].self,
            from: Data(contentsOf: URL(fileURLWithPath: fixtures).appendingPathComponent("c3-manual-golden.json")))
        try FileManager.default.createDirectory(at: previewDir, withIntermediateDirectories: true)
    } catch { check(false, "C3-10 fixture/output preparation: " + error.localizedDescription); return 0 }
    check(golden.count == 32 && manual.count == 10, "C3-10 C3-A golden fixtures readable (32 + 10 rows)")
    guard golden.count == 32, manual.count == 10 else { return 0 }

    let defaults = UserDefaults.standard
    let savedArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    let savedSync = SYNC_PREVIEW, savedViews = REMOTE_ACCOUNT_VIEWS_PREVIEW
    let savedManual = REMOTE_MANUAL_PHASE, savedZone = NSTimeZone.default
    defer {
        defaults.setVolatileDomain(savedArguments, forName: UserDefaults.argumentDomain)
        SYNC_PREVIEW = savedSync; REMOTE_ACCOUNT_VIEWS_PREVIEW = savedViews
        REMOTE_MANUAL_PHASE = savedManual; NSTimeZone.default = savedZone
    }
    NSTimeZone.default = C3_PREVIEW_ZONE
    var written = 0
    func save(_ image: CGImage?, _ name: String) {
        guard let image = image,
              let destination = CGImageDestinationCreateWithURL(previewDir.appendingPathComponent(name) as CFURL,
                  "public.png" as CFString, 1, nil) else {
            check(false, "C3-10 cannot create PNG " + name); return
        }
        CGImageDestinationAddImage(destination, image, nil)
        let ok = CGImageDestinationFinalize(destination)
        check(ok, "C3-10 PNG " + name)
        if ok { files.append(name); written += 1 }
    }
    func configure(_ language: String, advanced: Bool, views: [AccountView], sync: ReaderSyncState,
                   hidden: Set<String> = [], expanded: Bool = false) {
        var preferences = savedArguments
        preferences["lang"] = language; preferences["advanced"] = advanced
        preferences["advHistExpanded"] = expanded; preferences["autoPoll"] = true
        preferences["advHistProduct"] = "claude"; preferences["trayMetrics"] = "session,weekly"
        preferences["scopedName"] = "Fable"; preferences["localAccountCaptions"] = [String: String]()
        preferences["accountSubscriptionUSD"] = [String: Double]()
        preferences["claudeTier"] = "default_claude_max_20x"; preferences["codexPlan"] = "pro"
        preferences["subClaude"] = 200.0; preferences["subCodex"] = 200.0
        preferences["sound5h"] = false; preferences["sound7d"] = false; preferences["reachedOn"] = false
        preferences["sound5hChoice"] = "rise"; preferences["sound7dChoice"] = "celebrate"; preferences["reachedChoice"] = "outage"
        preferences["interval"] = 1800; preferences["hiddenAccounts"] = hidden.sorted()
        preferences["menuAccount"] = [String: String]()
        preferences["monitor_claude"] = views.contains { $0.product == "claude" && $0.isLocal }
        preferences["monitor_codex"] = views.contains { $0.product == "codex" && $0.isLocal }
        preferences["machineName"] = "mac"; preferences["autoPollState"] = try! JSONEncoder().encode([String: AutoPollState]())
        defaults.setVolatileDomain(preferences, forName: UserDefaults.argumentDomain)
        SYNC_PREVIEW = SyncUIState(phase: sync.phase, login: sync.phase == .on ? "fixture-account" : nil,
            machines: [SyncMachine(name: "mac", os: "macOS", updated: C3_PREVIEW_NOW, isSelf: true),
                       SyncMachine(name: "vps", os: "Linux", updated: C3_PREVIEW_NOW, isSelf: false)], lastSync: C3_PREVIEW_NOW)
        REMOTE_ACCOUNT_VIEWS_PREVIEW = views
    }
    func render(_ name: String, language: String, view: String, accounts: [AccountView], sync: ReaderSyncState,
                now: Date = C3_PREVIEW_NOW, phase: RemoteManualPhase = .idle, readerManual: RemoteManualPhase? = nil, settings: Bool = false,
                hidden: Set<String> = [], expanded: Bool = false, settingsState: SyncUIState? = nil) {
        let advanced = view == "advanced"
        let accounts = remoteSortedPresentationViews(views: accounts.map {
            remotePresentationView($0, sync: sync, now: now)
        }, language: language)
        configure(language, advanced: advanced, views: accounts, sync: sync, hidden: hidden, expanded: expanded)
        if let settingsState = settingsState { SYNC_PREVIEW = settingsState }
        let visible = accounts.filter { !remoteAccountIsHidden($0, hidden: hidden) && !$0.historyKey.hasPrefix("u:") }
        if sync.phase != .on || sync.warning != nil {
            check(accounts.filter { !$0.isLocal && !$0.historyKey.hasPrefix("u:") }.allSatisfy {
                sync.phase == .on ? $0.state == .syncStalled
                    : ($0.state == .signedOut && $0.data.session == nil && $0.data.weekly == nil && $0.data.scoped == nil)
            }, "C3-10 reader state governs every foreign account " + name)
        }
        let frame = RemoteAccountFrame(now: now, sync: sync, allViews: accounts, visibleViews: visible, displayedViews: visible)
        withRemoteRenderScene(frame: frame, timeZone: C3_PREVIEW_ZONE, manual: phase, readerManual: readerManual) {
            let empty = LimitData(present: false)
            let height = settings ? settingsTotalHeight(AboutState()) : mainPanelHeight(empty, empty)
            guard height.isFinite, height > 0, let context = bitmapContext(Int(PANEL_W * 2), Int(ceil(height * 2))) else {
                check(false, "C3-10 bitmap size " + name); return
            }
            context.scaleBy(x: 2, y: 2)
            let size = CGSize(width: PANEL_W, height: height)
            let hits: [Hit]
            if settings { hits = drawSettings(context, size: size, about: AboutState()) }
            else if advanced { hits = drawAdvanced(context, size: size, claude: empty, codex: empty, interval: 1800, updated: nil, about: AboutState()) }
            else { hits = drawPanel(context, size: size, claude: empty, codex: empty, interval: 1800, updated: nil, about: AboutState()) }
            check(hits.allSatisfy { $0.rect.minY >= 0 && $0.rect.maxY <= height }, "C3-10 actual draw hit bounds " + name)
            if name.hasPrefix("c3-date-5-longname-"), let account = visible.first(where: { $0.state == .offline }) {
                let p = cardPresentation(account, narrow: true, now: now)
                func measure(_ value: String) -> Double {
                    Double(lineWidth(CTLineCreateWithAttributedString(ctAttr(value, ctFont(10, .regular), cg(.white)))))
                }
                let status = remoteFittedStatusLine(account, presentation: p, language: language, narrow: true,
                    now: now, timeZone: C3_PREVIEW_ZONE, availableWidth: 130, measure: measure)
                let source = remoteFittedSourceLine(account, language: language, now: now, timeZone: C3_PREVIEW_ZONE,
                    narrow: true, availableWidth: 130, measure: measure)
                let machine = String(repeating: "w", count: 16)
                check(measure(p.statusLine) > 130 && measure(status) <= 130
                      && status.hasSuffix("28.10 ›") && status.hasPrefix("w")
                      && status.contains("…") && !status.contains(machine),
                      "C3-10 measured long machine yields before the complete offline date and chevron " + name)
                check(measure(source) <= 130 && source.hasSuffix("28.10")
                      && source.contains("…") && !source.contains(machine)
                      && p.tooltip.contains(machine) && p.tooltip.contains("28.10 19:30")
                      && p.accessibilityValue == p.tooltip,
                      "C3-10 fitted source preserves date and complete long machine/time remain in tooltip/AX " + name)
            }
            if settings, let state = settingsState {
                let error = remoteSyncErrorPresentation(state)
                var short = state; short.lastError = language == "ru" ? "Тест" : "Test"
                let shortError = remoteSyncErrorPresentation(short)
                let errorHits = hits.filter { $0.id == "syncerror:github" }
                check(error.lines.count == 3 && error.text == error.accessibilityValue
                      && error.text.contains(state.lastError ?? "") && shortError.lines.count == 1,
                      "C3-10 long GitHub error wraps to three lines with complete model/AX text " + name)
                check(remoteSyncCardHeight(state) - remoteSyncCardHeight(short) == 28
                      && errorHits.count == 1 && errorHits.first?.tooltip == error.accessibilityValue
                      && errorHits.first?.rect.height == CGFloat(error.height),
                      "C3-10 actual GitHub block grows28pt and exposes complete passive error hit " + name)
            }
            if name.hasPrefix("c3-manual-pollAllowed-"), let foreign = visible.first(where: { !$0.isLocal }) {
                let foreignCard = cardPresentation(foreign, narrow: view == "simple-narrow", now: now)
                check(foreignCard.statusLine == (language == "ru" ? "GitHub проверен 15:45" : "GitHub checked 15:45"),
                      "C3-10 provider cooldown and successful reader result coexist on separate cards " + name)
            }

            if !settings && accounts.filter({ $0.product == "codex" && $0.state == .syncStalled }).count == 2 {
                let actions = hits.filter { $0.id.hasPrefix("syncsettings:") }
                check(actions.count == 2 && Set(actions.map { $0.id }).count == 2,
                      "C3-10 two Codex sync actions have distinct native button identities " + name)
            }
            if advanced && !settings {
                func textWidth(_ value: String, _ size: CGFloat, _ weight: NSFont.Weight, kern: CGFloat = 0) -> Double {
                    let a = NSMutableAttributedString(attributedString: ctAttr(value, ctFont(size, weight), cg(.white)))
                    if kern != 0 { a.addAttribute(NSAttributedString.Key(kCTKernAttributeName as String), value: kern,
                        range: NSRange(location: 0, length: a.length)) }
                    return Double(ceil(lineWidth(CTLineCreateWithAttributedString(a))))
                }
                for account in visible {
                    let p = cardPresentation(account, narrow: false)
                    let productName = account.product == "claude" ? "Claude Code" : "Codex"
                    let title = textWidth(p.advancedTitle, 13, .semibold)
                    let minimumTitle = textWidth(String(p.advancedTitle.prefix(8)), 13, .semibold)
                    let plan = p.planBadge.isEmpty ? 0 : textWidth(p.planBadge, 9.5, .semibold, kern: 0.19) + 14
                    let suffix = textWidth(p.machineSuffix, 11, .regular)
                    let warning = account.isLocal ? "" : p.advancedBadge
                    let available = remoteAdvancedHeaderRightBoundary(cardMaxX: 345) - Double(ADV_IX) - 23
                    let protectedTitle = p.advancedTitle == productName ? title : minimumTitle
                    let badgeGaps = 7.0 + (plan > 0 ? 5.0 : 0) + (p.machineSuffix.isEmpty ? 0 : 5.0)
                    let badge = warning.isEmpty ? 0 : min(max(14, available - protectedTitle - plan - badgeGaps),
                        textWidth(warning, 9.5, .semibold, kern: 0.19) + 14)
                    let allocation = remoteAdvancedHeaderWidths(availableWidth: available, titleWidth: title,
                        badgeWidth: badge, planWidth: plan, machineWidth: suffix,
                        isCustomTitle: p.advancedTitle != productName, minimumTitleWidth: minimumTitle)
                    let gaps = (badge > 0 || plan > 0 || suffix > 0 ? 7.0 : 0)
                        + (badge > 0 && (plan > 0 || suffix > 0) ? 5.0 : 0) + (plan > 0 && suffix > 0 ? 5.0 : 0)
                    check(allocation.title + allocation.badge + allocation.plan + allocation.machines + gaps <= available,
                          "C3-10 measured Advanced header stays before317pt, clear of arrow " + name)
                    if language == "en", (name == "c3-3a-en-advanced.png" || name == "c3-3b-en-advanced.png") {
                        check(p.machineSuffix == "· vps" && allocation.machines >= suffix,
                              "C3-10 EN3a/3b retain complete vps suffix at317pt " + name)
                    }
                }
                let toggles = hits.filter { $0.id == "hist:toggle" }
                let accounts = hits.filter { $0.id.hasPrefix("histaccount:") }
                check(toggles.allSatisfy { toggle in accounts.allSatisfy { !toggle.rect.intersects($0.rect) } },
                      "C3-10 actual history toggle does not intercept account selection " + name)
                var separateAccounts = true
                for i in accounts.indices {
                    for j in accounts.indices where j > i {
                        if accounts[i].rect.intersects(accounts[j].rect) { separateAccounts = false }
                    }
                }
                check(separateAccounts, "C3-10 actual history account selection hits do not overlap " + name)
                if name.hasPrefix("c3-history-two-codex-"), expanded {
                    let expected = ["Codex · mac", "Codex · vps"]
                    let titles = frame.allViews.map { remoteHistorySelectorTitle($0, language: language) }
                    check(titles == expected && accounts.compactMap { $0.tooltip } == expected
                          && Set(accounts.compactMap { $0.tooltip }).count == 2,
                          "C3-10 actual history selector text and tooltip distinguish both Codex accounts " + name)
                    check(accounts.count == expected.count && zip(expected, accounts).allSatisfy { pair in
                        textWidth(pair.0, 10.5, .semibold) <= Double(pair.1.rect.width - 10)
                    }, "C3-10 complete Codex machine titles fit their rendered history segments " + name)
                }
                if name.hasPrefix("c3-long-names-"), expanded {
                    let caption = frame.allViews.first?.caption ?? ""
                    check(caption.unicodeScalars.count == 32 && accounts.count == 1
                          && accounts.first?.tooltip == caption,
                          "C3-10 expanded long-caption history exposes the complete 32-scalar selector label " + name)
                    let captionWidth = lineWidth(CTLineCreateWithAttributedString(ctAttr(caption, ctFont(10.5, .semibold), cg(.white))))
                    check(accounts.first.map { $0.rect.width <= 308 && $0.rect.height > 0
                          && captionWidth <= $0.rect.width - 10 } == true,
                          "C3-10 complete long-caption selector text fits its measured native hit width " + name)
                }
                if expanded && visible.isEmpty && frame.allViews.contains(where: { $0.historyKey == "u:codex" }) {
                    check(!toggles.isEmpty && hits.contains { $0.id == "moneyaccount:codex|u:codex" }
                          && !hits.contains { $0.id.hasPrefix("quotafeedback:") }
                          && accounts.count == 1
                          && accounts.first?.tooltip == (language == "ru" ? "Codex · не указан" : "Codex · unlabelled"),
                          "C3-10 unlabelled-only group renders its distinct localized history title/money without quota cards " + name)
                }
            }
            save(context.makeImage(), name)
        }
    }
    func sceneAccounts(_ primary: AccountView, view: String) -> [AccountView] {
        view == "simple-narrow" ? [primary, c3PreviewView(product: "codex", identity: 2)] : [primary]
    }
    let stateNames = ["1", "2", "3a", "3b", "4", "5", "6", "7-off", "7-revoked"]
    for name in stateNames {
        for language in ["ru", "en"] {
            for view in ["simple-narrow", "simple-wide", "advanced"] {
                let goldenCase = name.hasPrefix("7-") ? "7" : name
                guard let row = golden.first(where: { $0.case == goldenCase && $0.language == language && $0.narrow == (view == "simple-narrow") }),
                      let state = RemoteCardState(rawValue: row.state) else {
                    check(false, "C3-10 missing state golden " + name); continue
                }
                let account = c3PreviewView(state: state, status: row.status)
                let sync = ReaderSyncState(phase: name == "7-revoked" ? .revoked : (state == .signedOut ? .off : .on),
                    warning: state == .syncStalled ? (language == "ru" ? "Нет связи с GitHub." : "GitHub is unreachable.") : nil)
                let presentation = remotePresentationCard(account, sync: sync, language: language, narrow: row.narrow,
                    now: C3_PREVIEW_NOW, timeZone: C3_PREVIEW_ZONE, manual: .idle)
                if name != "7-revoked" {
                    check(presentation.statusLine == row.statusLine && presentation.statusTone == row.tone
                          && presentation.advancedBadge == row.badge && presentation.action == row.action
                          && (state == .stale || presentation.tooltip == row.tooltip)
                          && presentation.accessibilityValue == presentation.tooltip,
                          "C3-10 actual scene agrees with C3-A golden " + name + "/" + language + "/" + view)
                } else {
                    check(!presentation.showsValues && presentation.action == row.action && presentation.statusTone == row.tone,
                          "C3-10 revoked explanatory scene has no cached values")
                }
                if state == .stale {
                    check(["session", "weekly", "model"].allSatisfy { metricIsStale(account.data, metric: $0, now: C3_PREVIEW_NOW) },
                          "C3-10 state2 values exceed V4 horizon; body is dim")
                    check(presentation.sourceLine.contains("15:00")
                          && presentation.tooltip.contains(language == "ru" ? "Авто · 30 мин" : "Auto · 30 min"),
                          "C3-10 state2 tooltip describes coherent snapshot and source schedule")
                }
                render("c3-\(name)-\(language)-\(view).png", language: language, view: view,
                    accounts: sceneAccounts(account, view: view), sync: sync)
                if view == "simple-wide" {
                    configure(language, advanced: false, views: [account], sync: sync)
                    let trayAccount = remotePresentationView(account, sync: sync, now: C3_PREVIEW_NOW)
                    let frame = RemoteAccountFrame(now: C3_PREVIEW_NOW, sync: sync, allViews: [trayAccount], visibleViews: [trayAccount], displayedViews: [trayAccount])
                    for dark in [true, false] {
                        withRemoteRenderScene(frame: frame, timeZone: C3_PREVIEW_ZONE, manual: .idle) {
                            let model = remoteMenuPresentation(views: [trayAccount], selected: [:], language: language,
                                dark: dark, now: C3_PREVIEW_NOW, timeZone: C3_PREVIEW_ZONE)
                            check(model.tooltip.contains(account.caption), "C3-10 tray tooltip includes account caption")
                            save(renderStrip([(trayAccount.data, "claude_128.png")], dark: dark),
                                 "c3-tray-\(name)-\(language)-\(dark ? "dark" : "light").png")
                        }
                    }
                }
            }
        }
    }
    for row in manual {
        let phase: RemoteManualPhase
        var account = c3PreviewView()
        switch row.phase {
        case "reading": phase = .reading
        case "checked": phase = .checked(c3PreviewDate("2026-10-12T15:45:00Z"))
        case "cooldown": phase = .cooldown(12)
        case "failed": phase = .failed
        case "pollAllowed":
            phase = .pollAllowed(c3PreviewDate("2026-10-12T15:58:00Z"))
            account.isLocal = true; account.machines = ["mac", "vps"]
            account.caption = "Claude Max 20x · mac, vps"
        default: check(false, "C3-10 unknown manual golden phase"); continue
        }
        let now = c3PreviewDate("2026-10-12T15:45:59Z"), sync = ReaderSyncState(phase: .on)
        let readerManual: RemoteManualPhase? = row.phase == "pollAllowed"
            ? .checked(c3PreviewDate("2026-10-12T15:45:00Z")) : nil
        for view in ["simple-narrow", "simple-wide", "advanced"] {
            let presentation = remotePresentationCard(account, sync: sync, language: row.language, narrow: view == "simple-narrow",
                now: now, timeZone: C3_PREVIEW_ZONE, manual: phase, readerManual: readerManual)
            check(presentation.statusLine == row.text && presentation.tooltip.contains(row.text) && presentation.sourceLine.contains("15:43"),
                  "C3-10 manual scene agrees with C3-A golden " + row.phase + "/" + row.language + "/" + view)
            render("c3-manual-\(row.phase)-\(row.language)-\(view).png", language: row.language, view: view,
                accounts: sceneAccounts(account, view: view), sync: sync, now: now, phase: phase, readerManual: readerManual)
        }
    }
    var localCodex = c3PreviewView(product: "codex", identity: 2, machines: ["mac"])
    localCodex.isLocal = true; localCodex.data.source = nil
    var otherClaude = c3PreviewView(identity: 4, machines: ["desktop"]); otherClaude.data.session = 18
    let remoteCodex = c3PreviewView(product: "codex", identity: 3)
    var sharedCodex = c3PreviewView(product: "codex", identity: 2, machines: ["mac", "vps"])
    sharedCodex.isLocal = true // this Mac is signed in, newest observation is from VPS
    let layouts: [(String, [AccountView])] = [
        ("three", [c3PreviewView(), localCodex, remoteCodex]),
        ("four", [c3PreviewView(), otherClaude, localCodex, remoteCodex]),
        ("two-codex", [localCodex, remoteCodex]),
        ("shared-codex", [sharedCodex])
    ]
    for (name, accounts) in layouts {
        for language in ["ru", "en"] {
            for view in ["simple", "advanced"] {
                render("c3-layout-\(name)-\(language)-\(view).png", language: language, view: view,
                    accounts: accounts, sync: ReaderSyncState(phase: .on))
            }
            render("c3-history-\(name)-\(language)-advanced.png", language: language, view: "advanced",
                accounts: accounts, sync: ReaderSyncState(phase: .on), expanded: true)
        }
    }
    let onlyUnassigned = AccountView(product: "codex", label: nil, historyKey: "u:codex", caption: "",
        data: LimitData(present: false), isLocal: false, tier: nil,
        usageDays: ["2026-10-12": ["gpt-5": DayModelUsage(input: 10000, output: 2000, turns: 3)]],
        machines: ["desktop"], state: .fresh)
    let onlyUnassignedLayout = remotePanelLayout(views: [onlyUnassigned], style: .advanced,
        now: C3_PREVIEW_NOW, historyHeight: 231)
    check(onlyUnassignedLayout.cards.isEmpty && onlyUnassignedLayout.moneyRows.count == 1,
          "C3-10 unlabelled-only group has history money row and no quota card")
    for language in ["ru", "en"] {
        render("c3-history-only-unassigned-\(language)-advanced.png", language: language, view: "advanced",
            accounts: [onlyUnassigned], sync: ReaderSyncState(phase: .on), expanded: true)
        let accounts = [c3PreviewView(state: .syncStalled, product: "codex", identity: 11),
                        c3PreviewView(state: .syncStalled, product: "codex", identity: 12, machines: ["desktop"])]
        let sync = ReaderSyncState(phase: .on, warning: language == "ru" ? "Нет связи с GitHub." : "GitHub is unreachable.")
        for view in ["simple", "advanced"] {
            render("c3-actions-two-codex-\(language)-\(view).png", language: language, view: view, accounts: accounts, sync: sync)
        }
    }
    // Additional edge scenes keep source freshness and metric validity aligned
    // with the fixed clock. States 3/5/6 deliberately retain values within V4:
    // §5 dims their body by horizon, independently of the remote state badge.
    for condition in ["stale", "reset", "future-asOf"] {
        var account = c3PreviewView()
        let timestamp: String
        switch condition {
        case "stale":
            let asOf = c3PreviewDate("2026-10-12T15:00:00Z")
            account.state = .stale; account.data.asOf = asOf; account.data.source?.asOf = asOf
            account.data.source?.attemptAt = asOf; account.data.source?.interval = 1800
            account.data.source?.nextAt = c3PreviewDate("2026-10-12T15:30:00Z")
            account.data.source?.freshUntil = c3PreviewDate("2026-10-12T15:50:00Z")
            account.data.source?.lastSeenAt = c3PreviewDate("2026-10-12T15:59:00Z")
            account.data.sessionReset = c3PreviewDate("2026-10-12T19:30:00Z")
            timestamp = "15:00"
            check(C3_PREVIEW_NOW.timeIntervalSince(asOf) > snapshotHorizon(account.data)
                  && ["session", "weekly", "model"].allSatisfy { metricIsStale(account.data, metric: $0, now: C3_PREVIEW_NOW) },
                  "C3-10 coherent stale source exceeds freshness horizon; all gauges dim")
            let kind = remoteAdvancedRowKind(account, metric: "session", now: C3_PREVIEW_NOW)
            check(kind == .stale && remoteAdvancedRowHeight(kind) == 50,
                  "C3-10 coherent stale snapshot uses dimmed 50pt Advanced row")
        case "reset":
            account.data.sessionReset = c3PreviewDate("2026-10-12T15:55:00Z")
            timestamp = "15:43"
            check(account.data.sessionReset! > account.data.asOf! && account.data.sessionReset! <= C3_PREVIEW_NOW
                  && metricIsStale(account.data, metric: "session", now: C3_PREVIEW_NOW)
                  && !metricIsStale(account.data, metric: "weekly", now: C3_PREVIEW_NOW),
                  "C3-10 coherent reset occurred after snapshot; session alone dims")
            check(remoteAdvancedRowKind(account, metric: "session", now: C3_PREVIEW_NOW) == .stale
                  && remoteAdvancedRowKind(account, metric: "weekly", now: C3_PREVIEW_NOW) == .full,
                  "C3-10 coherent reset pauses session row, keeps valid week")
        default:
            let asOf = C3_PREVIEW_NOW.addingTimeInterval(301)
            account.data.asOf = asOf; account.data.source?.asOf = asOf
            account.data.source?.attemptAt = asOf; account.data.source?.futureAsOf = true
            account.data.source?.nextAt = asOf.addingTimeInterval(3600)
            account.data.source?.freshUntil = asOf.addingTimeInterval(4800)
            account.data.source?.lastSeenAt = c3PreviewDate("2026-10-12T15:59:00Z")
            timestamp = "16:05"
            check(!remotePaceTimeValid(account.data, now: C3_PREVIEW_NOW)
                  && ["session", "weekly", "model"].allSatisfy { metricIsStale(account.data, metric: $0, now: C3_PREVIEW_NOW) }
                  && remoteAdvancedRowKind(account, metric: "session", now: C3_PREVIEW_NOW) == .stale,
                  "C3-10 coherent future snapshot exceeds five-minute allowance; pace paused")
        }
        for language in ["ru", "en"] {
            for view in ["simple-narrow", "simple-wide", "advanced"] {
                let p = remotePresentationCard(account, sync: ReaderSyncState(phase: .on), language: language,
                    narrow: view == "simple-narrow", now: C3_PREVIEW_NOW, timeZone: C3_PREVIEW_ZONE, manual: .idle)
                check(p.sourceLine.contains(timestamp), "C3-10 coherent " + condition + " preserves source timestamp")
                if condition == "stale" {
                    let pace = snapshotWindowPace(used: account.data.session, reset: account.data.sessionReset,
                        windowH: 5, asOf: account.data.asOf, now: C3_PREVIEW_NOW)
                    let limit = PacedLimit(id: "session", name: "", pace: pace, color: 0, used: account.data.session)
                    let row = AdvRow(limit: limit, kind: .stale, credits: nil)
                    let verdict = advVerdict(row, data: account.data, now: C3_PREVIEW_NOW, language: language)
                    check(verdict.hasPrefix(language == "ru" ? "Прогноз на снимке: " : "Snapshot forecast: "),
                          "C3-10 coherent stale Advanced row retains snapshot forecast")
                }
                if condition == "reset" { check(p.sessionDimmed, "C3-10 coherent reset presentation dims session") }
                if condition == "future-asOf" { check(p.paceNotice != nil, "C3-10 coherent future presentation has pace notice") }
                render("c3-data-\(condition)-\(language)-\(view).png", language: language, view: view,
                    accounts: sceneAccounts(account, view: view), sync: ReaderSyncState(phase: .on))
            }
        }
    }
    for name in ["on", "off", "revoked"] {
        for language in ["ru", "en"] {
            for view in ["simple", "advanced"] {
                let accounts = name == "on" ? [c3PreviewView(), localCodex, remoteCodex] : []
                render("c3-settings-\(name)-\(language)-\(view).png", language: language, view: view,
                    accounts: accounts, sync: ReaderSyncState(phase: name == "on" ? .on : (name == "off" ? .off : .revoked)), settings: true)
            }
        }
    }
    // D1 live-run regression: a different calendar day must leave room for the
    // complete date and offline chevron in the158pt Simple card.
    let datedNow = c3PreviewDate("2026-10-29T16:00:00Z")
    let datedSeen = c3PreviewDate("2026-10-28T19:30:00Z")
    for state in [RemoteCardState.offline, .syncStalled] {
        for language in ["ru", "en"] {
            var account = c3PreviewView(state: state)
            account.data.asOf = datedSeen; account.data.source?.asOf = datedSeen
            account.data.source?.attemptAt = datedSeen; account.data.source?.lastSeenAt = datedSeen
            account.data.source?.nextAt = datedSeen.addingTimeInterval(3600)
            account.data.source?.freshUntil = datedSeen.addingTimeInterval(4800)
            account.data.sessionReset = c3PreviewDate("2026-10-29T18:00:00Z")
            account.data.weeklyReset = c3PreviewDate("2026-11-01T07:00:00Z")
            account.data.scoped?.reset = c3PreviewDate("2026-11-02T07:00:00Z")
            let warning = language == "ru" ? "Синхронизация стоит с 28.10 19:30: нет связи с GitHub."
                : "Sync stalled since 28.10 19:30: GitHub is unreachable."
            let sync = ReaderSyncState(phase: .on, warning: state == .syncStalled ? warning : nil)
            let p = remotePresentationCard(account, sync: sync, language: language, narrow: true,
                now: datedNow, timeZone: C3_PREVIEW_ZONE)
            check(p.sourceLine == (language == "ru" ? "С vps от 28.10" : "From vps at 28.10")
                  && p.tooltip.contains("28.10 19:30") && p.accessibilityValue == p.tooltip,
                  "C3-10 dated narrow source is compact and full timestamp remains in tooltip/AX")
            if state == .offline {
                check(p.statusLine == (language == "ru" ? "vps не на связи с 28.10 ›" : "vps offline since 28.10 ›"),
                      "C3-10 dated offline action retains complete date and chevron")
            }
            render("c3-date-\(state.rawValue)-\(language)-simple-narrow.png", language: language, view: "simple-narrow",
                accounts: sceneAccounts(account, view: "simple-narrow"), sync: sync, now: datedNow)
            if state == .offline {
                var longName = account
                let machine = String(repeating: "w", count: 16)
                longName.machines = [machine]; longName.data.source?.machineName = machine
                longName.data.source?.statusMachineName = machine
                longName.caption = remoteDefaultCaption(longName)
                render("c3-date-5-longname-\(language)-simple-narrow.png", language: language, view: "simple-narrow",
                    accounts: sceneAccounts(longName, view: "simple-narrow"), sync: sync, now: datedNow)
            }
        }
    }
    // D3 uses only the isolated SyncUIState preview; no live sync is constructed.
    for language in ["ru", "en"] {
        let error = language == "ru"
            ? "Не удалось восстановить результат предыдущего запроса к GitHub. Проверьте подключение к сети и повторите вход в настройках синхронизации. Последние полученные данные сохранены на этом компьютере."
            : "Could not recover the result of the previous GitHub request. Check your network connection and sign in again in sync settings. The last received data remains saved on this computer."
        let state = SyncUIState(phase: .on, login: "fixture-account",
            machines: [SyncMachine(name: "mac", os: "macOS", updated: C3_PREVIEW_NOW, isSelf: true),
                       SyncMachine(name: "vps", os: "Linux", updated: C3_PREVIEW_NOW, isSelf: false)],
            lastSync: C3_PREVIEW_NOW, lastError: error, lastErrorAt: c3PreviewDate("2026-10-12T15:38:00Z"))
        render("c3-settings-long-error-\(language)-simple.png", language: language, view: "simple",
            accounts: [c3PreviewView(), localCodex], sync: ReaderSyncState(phase: .on), settings: true, settingsState: state)
    }
    // §11.13: 32-scalar custom title and a long source name share the real card
    // layout. Only the source name may shorten; the HH:mm source time must survive.
    for language in ["ru", "en"] {
        var account = c3PreviewView()
        account.caption = String((language == "ru" ? "Рабочая подписка для больших задач" : "Work subscription for large tasks").prefix(32))
        let machine = "build-machine-with-an-intentionally-long-source-name"
        account.machines = [machine]; account.data.source?.machineName = machine
        for view in ["simple-narrow", "simple-wide", "advanced"] {
            let p = remotePresentationCard(account, sync: ReaderSyncState(phase: .on), language: language,
                narrow: view == "simple-narrow", now: C3_PREVIEW_NOW, timeZone: C3_PREVIEW_ZONE, manual: .idle)
            check(p.accessibilityLabel == account.caption && p.sourceLine.contains("15:43"),
                  "C3-10 long caption/source retains full AX label and source time")
            render("c3-long-names-\(language)-\(view).png", language: language, view: view,
                accounts: sceneAccounts(account, view: view), sync: ReaderSyncState(phase: .on), expanded: view == "advanced")
        }
        let hiddenClaude = c3PreviewView()
        let unassigned = AccountView(product: "codex", label: nil, historyKey: "u:codex", caption: "",
            data: LimitData(present: false), isLocal: false, tier: nil, usageDays: [:], machines: ["desktop"], state: .fresh)
        let accounts = [hiddenClaude, localCodex, remoteCodex, unassigned]
        let hidden: Set<String> = [hiddenClaude.historyKey]
        for view in ["simple", "advanced"] {
            let model = remoteSettingsModel(views: accounts, hidden: hidden, polling: ["claude": false, "codex": true],
                sync: ReaderSyncState(phase: .on), advanced: view == "advanced", language: language)
            check(model.accounts.contains { $0.historyKey == hiddenClaude.historyKey && !$0.visible }
                  && model.accounts.contains { $0.historyKey == "u:codex" && !$0.editable }
                  && model.menuProducts.contains("codex"), "C3-10 settings hidden/unlabelled/chooser fixture")
            render("c3-settings-accounts-\(language)-\(view).png", language: language, view: view,
                accounts: accounts, sync: ReaderSyncState(phase: .on), settings: true, hidden: hidden)
        }
    }
    check(written == 198, "C3-10 198 actual AppKit matrix PNGs saved")
    return written
}

/// Independent output checks, called after legacy and C3 renders and final manifest.
/// Returns failed checks; the callback also integrates into the subscription checks.
func c3VerifyPreviewManifest(previewDir: URL, files: [String], check: (Bool, String) -> Void) -> Int {
    var failures = 0
    func expect(_ condition: Bool, _ message: String) {
        if !condition { failures += 1 }
        check(condition, "C3-10 " + message)
    }
    let states = ["1", "2", "3a", "3b", "4", "5", "6", "7-off", "7-revoked"]
    let languages = ["ru", "en"]
    let views = ["simple-narrow", "simple-wide", "advanced"]
    var expected = Set<String>()
    for state in states {
        for language in languages {
            for view in views { expected.insert("c3-\(state)-\(language)-\(view).png") }
            for theme in ["dark", "light"] { expected.insert("c3-tray-\(state)-\(language)-\(theme).png") }
        }
    }
    for phase in ["reading", "checked", "cooldown", "failed", "pollAllowed"] {
        for language in languages {
            for view in views { expected.insert("c3-manual-\(phase)-\(language)-\(view).png") }
        }
    }
    for layout in ["three", "four", "two-codex", "shared-codex"] {
        for language in languages {
            for view in ["simple", "advanced"] { expected.insert("c3-layout-\(layout)-\(language)-\(view).png") }
            expected.insert("c3-history-\(layout)-\(language)-advanced.png")
        }
    }
    for condition in ["stale", "reset", "future-asOf"] {
        for language in languages {
            for view in views { expected.insert("c3-data-\(condition)-\(language)-\(view).png") }
        }
    }
    for phase in ["on", "off", "revoked"] {
        for language in languages {
            for view in ["simple", "advanced"] { expected.insert("c3-settings-\(phase)-\(language)-\(view).png") }
        }
    }
    for language in languages {
        for state in [5, 6] { expected.insert("c3-date-\(state)-\(language)-simple-narrow.png") }
        expected.insert("c3-date-5-longname-\(language)-simple-narrow.png")
        expected.insert("c3-settings-long-error-\(language)-simple.png")
        for view in views { expected.insert("c3-long-names-\(language)-\(view).png") }
        for view in ["simple", "advanced"] { expected.insert("c3-settings-accounts-\(language)-\(view).png") }
        expected.insert("c3-history-only-unassigned-\(language)-advanced.png")
        for view in ["simple", "advanced"] { expected.insert("c3-actions-two-codex-\(language)-\(view).png") }
    }
    let registered = Set(files)
    expect(expected.count == 198, "matrix has 198 specified scenes")
    expect(expected.isSubset(of: registered), "complete V5/manual/layout/history/data/tray/settings matrix")
    expect(files.count == registered.count, "registered filenames are unique")
    expect(files.allSatisfy { !$0.isEmpty && URL(fileURLWithPath: $0).lastPathComponent == $0 && $0.hasSuffix(".png") },
           "registered PNG paths remain inside previewDir")
    do {
        let data = try Data(contentsOf: previewDir.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(C3PreviewManifest.self, from: data)
        let names = manifest.files.map { $0.filename }
        expect(names == registered.sorted(), "manifest contains only this run, sorted with no duplicates")
        for entry in manifest.files {
            guard registered.contains(entry.filename), URL(fileURLWithPath: entry.filename).lastPathComponent == entry.filename else {
                expect(false, "manifest contains an unregistered or unsafe filename"); continue
            }
            let png = try Data(contentsOf: previewDir.appendingPathComponent(entry.filename))
            expect(Array(png.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10], "PNG signature " + entry.filename)
            let sha = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
            expect(entry.sha256 == sha, "SHA256 " + entry.filename)
            let source = CGImageSourceCreateWithData(png as CFData, nil)
            let image = source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
            expect(image.map { $0.width > 0 && $0.height > 0 } ?? false, "readable nonempty PNG " + entry.filename)
        }
    } catch {
        expect(false, "manifest/PNG verification: " + error.localizedDescription)
    }
    return failures
}
