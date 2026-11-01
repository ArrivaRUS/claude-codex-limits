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
    let watchdog = AppKitSelfTestWatchdog.shared
    watchdog.begin("C3-10 preview fixture setup")
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
                hidden: Set<String> = [], expanded: Bool = false, settingsState: SyncUIState? = nil,
                subscriptions: [HistorySubscription]? = nil) {
        watchdog.begin("C3-10 scene " + name)
        let advanced = view == "advanced"
        let accounts = remoteSortedPresentationViews(views: accounts.map {
            remotePresentationView($0, sync: sync, now: now)
        }, language: language)
        configure(language, advanced: advanced, views: accounts, sync: sync, hidden: hidden, expanded: expanded)
        if let settingsState = settingsState { SYNC_PREVIEW = settingsState }
        let visible = accounts.filter { !remoteAccountIsHidden($0, hidden: hidden) }
        if sync.phase != .on || sync.warning != nil {
            check(accounts.filter { !$0.isLocal }.allSatisfy {
                sync.phase == .on ? $0.state == .syncStalled
                    : ($0.state == .signedOut && $0.data.session == nil && $0.data.weekly == nil && $0.data.scoped == nil)
            }, "C3-10 reader state governs every foreign account " + name)
        }
        var frame = RemoteAccountFrame(now: now, sync: sync, allViews: accounts, visibleViews: visible, displayedViews: visible)
        frame.subscriptions = subscriptions ?? historySubscriptions(views: accounts, index: historyPreviewIndex(accounts), now: now, language: language)
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
            if !settings {
                for account in visible where account.data.present && !account.caption.isEmpty && account.caption != remoteDefaultCaption(account) {
                    guard let hit = hits.first(where: { $0.id == "sourceheader:" + account.product + ":" + account.historyKey }) else {
                        check(false, "C5-08 actual header hit exists for custom caption " + name); continue
                    }
                    let actual = panelTooltip(at: CGPoint(x: hit.rect.midX, y: hit.rect.midY), hits: hits) ?? ""
                    let titleHover = panelTooltip(at: CGPoint(x: hit.rect.minX + 30, y: hit.rect.maxY - 3), hits: hits)
                    check(actual.components(separatedBy: "\n").first == account.caption
                          && actual.contains(" — ") && actual == hit.tooltip && titleHover == actual,
                          "C5-08 actual Simple/Advanced hover and AX hit keep the complete caption then machine status " + name)
                }
            }
            if name.hasPrefix("c5-freshness-") {
                let headerHits = hits.filter { $0.id.hasPrefix("sourceheader:") }
                check(headerHits.count == visible.count && headerHits.allSatisfy {
                    ($0.tooltip ?? "").contains(language == "ru" ? "в срок" : "on time")
                }, "C5-08 actual header hit/AX exposes per-machine times and status " + name)
                for account in visible {
                    let p = cardPresentation(account, narrow: !advanced && visible.count > 1)
                    check(remoteVisibleSourceLine(p, advanced: advanced).isEmpty,
                          "C5-09 source/time row is absent in both panel modes " + name)
                    if !advanced, let header = p.sourceHeader {
                        let budget = visible.count > 1 ? 94.0 : 264.0
                        let font = NSFont.systemFont(ofSize: 10.5, weight: .regular, width: .condensed)
                        let layout = remoteSourceHeaderLayout(header, availableWidth: budget, measure: {
                            Double(lineWidth(CTLineCreateWithAttributedString(ctAttr($0, font as CTFont, cg(.white)))))
                        })
                        check(layout.width <= budget && layout.runs.count == min(2, header.sources.count),
                              "C5-08 actual condensed widths retain every source dot " + name)
                    }
                }
            }
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
                    let minimumSources = p.sourceHeader.map {
                        textWidth("· ", 11, .regular) + remoteSourceHeaderMinimumWidth($0, measure: { textWidth($0, 11, .regular) })
                    } ?? 0
                    let protectedTitle = p.advancedTitle == productName ? title : minimumTitle
                    let badgeGaps = 7.0 + (plan > 0 ? 5.0 : 0) + (p.machineSuffix.isEmpty ? 0 : 5.0)
                    let badge = warning.isEmpty ? 0 : min(max(14, available - protectedTitle - plan - badgeGaps - minimumSources),
                        textWidth(warning, 9.5, .semibold, kern: 0.19) + 14)
                    let allocation = remoteAdvancedHeaderWidths(availableWidth: available, titleWidth: title,
                        badgeWidth: badge, planWidth: plan, machineWidth: suffix,
                        isCustomTitle: p.advancedTitle != productName, minimumTitleWidth: minimumTitle, minimumMachineWidth: minimumSources)
                    let gaps = (badge > 0 || plan > 0 || suffix > 0 ? 7.0 : 0)
                        + (badge > 0 && (plan > 0 || suffix > 0) ? 5.0 : 0) + (plan > 0 && suffix > 0 ? 5.0 : 0)
                    check(allocation.title + allocation.badge + allocation.plan + allocation.machines + gaps <= available,
                          "C3-10 measured Advanced header stays before317pt, clear of arrow " + name)
                    if language == "en", (name == "c3-3a-en-advanced.png" || name == "c3-3b-en-advanced.png") {
                        if let header = p.sourceHeader {
                            let prefix = textWidth("· ", 11, .regular)
                            let dots = remoteSourceHeaderLayout(header, availableWidth: allocation.machines - prefix,
                                measure: { textWidth($0, 11, .regular) })
                            check(p.machineSuffix == "· ● vps" && dots.runs.count == 1
                                  && dots.runs[0].dotWidth == 6 && dots.width + prefix <= allocation.machines,
                                  "C3-10 EN3a/3b preserve the source dot before317pt; names may shorten " + name)
                        }
                    }
                }
                let toggles = hits.filter { $0.id == "hist:toggle" }
                let accounts = hits.filter { $0.id.hasPrefix("histsubscription:") }
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
                    let expected = ["Codex Pro"]
                    check(accounts.compactMap { $0.tooltip } == expected && accounts.count == 1,
                          "C3-10 both Codex account cards share one product history tab " + name)
                }
                if name.hasPrefix("c3-long-names-"), expanded {
                    let caption = frame.allViews.first?.caption ?? ""
                    check(caption.unicodeScalars.count == 32 && accounts.count == 1
                          && accounts.first?.tooltip == caption,
                          "C3-10 expanded long-caption history exposes the complete 32-scalar selector label " + name)
                    check(accounts.first.map { $0.rect.width <= 308 && $0.rect.height > 0
                          && !remoteHistoryFittedTitle(caption, width: Double($0.rect.width - 10), measure: { textWidth($0, 10.5, .semibold) }).isEmpty } == true,
                          "C3-10 fixed-size long-caption selector uses measured ellipsis and full tooltip " + name)
                }
                if expanded && visible.isEmpty && frame.subscriptions?.isEmpty == false {
                    check(!toggles.isEmpty && hits.contains { $0.id == "moneysubscription:codex" }
                          && !hits.contains { $0.id.hasPrefix("quotafeedback:") }
                          && accounts.count == 1 && accounts.first?.tooltip == "Codex",
                          "C3-10 usage-only product has one history tab and no synthetic quota card " + name)
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
                        watchdog.begin("C3-10 tray \(name) \(language) dark=\(dark)")
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
    let usageOnly = HistorySubscription(product: "codex", title: "Codex",
        usageDays: ["2026-10-12": ["gpt-6.1-sol": DayModelUsage(input: 10000, output: 2000, turns: 3)]], accounts: [])
    for language in ["ru", "en"] {
        render("c5-history-only-product-\(language)-advanced.png", language: language, view: "advanced",
            accounts: [], sync: ReaderSyncState(phase: .on), expanded: true, subscriptions: [usageOnly])
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
            check(remoteVisibleSourceLine(p, advanced: false).isEmpty
                  && p.sourceLine == (language == "ru" ? "С vps от 28.10" : "From vps on 28.10")
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
        let accounts = [hiddenClaude, localCodex, remoteCodex]
        let hidden: Set<String> = [hiddenClaude.historyKey]
        for view in ["simple", "advanced"] {
            let model = remoteSettingsModel(views: accounts, hidden: hidden, polling: ["claude": false, "codex": true],
                sync: ReaderSyncState(phase: .on), advanced: view == "advanced", language: language)
            check(model.accounts.contains { $0.historyKey == hiddenClaude.historyKey && !$0.visible }
                  && model.menuProducts.contains("codex"), "C3-10 settings hidden accounts and chooser fixture")
            render("c3-settings-accounts-\(language)-\(view).png", language: language, view: view,
                accounts: accounts, sync: ReaderSyncState(phase: .on), settings: true, hidden: hidden)
        }
    }
    // D5 regression: both rows in each narrow card show the longest reset value.
    for language in ["ru", "en"] {
        var accounts = [c3PreviewView(), c3PreviewView(product: "codex", identity: 2)]
        for index in accounts.indices {
            accounts[index].data.sessionReset = c3PreviewDate("2026-10-12T15:55:00Z")
            accounts[index].data.weeklyReset = c3PreviewDate("2026-10-12T15:55:00Z")
            check(["session", "weekly"].allSatisfy { metricIsStale(accounts[index].data, metric: $0, now: C3_PREVIEW_NOW) },
                  "C5/D5 both windows reset in narrow " + language)
        }
        render("c5-both-reset-\(language)-simple-narrow.png", language: language, view: "simple-narrow",
            accounts: accounts, sync: ReaderSyncState(phase: .on))
    }
    // C5 freshness: every card has exactly two source dots. Two wide variants
    // cover all three age colors without inventing a third source.
    func freshnessAccount(product: String, identity: Int, ages: [Double]) -> AccountView {
        var account = c3PreviewView(product: product, identity: identity, machines: ["macbook", "vps"])
        account.sourceReadings = zip(["macbook", "vps"], ages).map { name, age in
            RemoteMachineReading(machineId: "c5-" + name, name: name,
                asOf: C3_PREVIEW_NOW.addingTimeInterval(-age), interval: 1800, isLocal: false)
        }
        let winner = account.sourceReadings.max { $0.asOf! < $1.asOf! }!
        account.data.asOf = winner.asOf; account.data.source?.asOf = winner.asOf
        account.data.source?.machineId = winner.machineId; account.data.source?.machineName = winner.name
        account.data.source?.status = "ok"; account.data.source?.interval = 1800
        account.data.source?.nextAt = winner.asOf?.addingTimeInterval(1800)
        account.data.source?.lastSeenAt = C3_PREVIEW_NOW
        return account
    }
    for language in ["ru", "en"] {
        let timely = freshnessAccount(product: "claude", identity: 91, ages: [60, 2701])
        let old = freshnessAccount(product: "codex", identity: 92, ages: [86401, 60])
        for view in ["simple-narrow", "advanced"] {
            render("c5-freshness-\(language)-\(view).png", language: language, view: view,
                accounts: [timely, old], sync: ReaderSyncState(phase: .on))
        }
        for (variant, account) in [("late", timely), ("old", old)] {
            render("c5-freshness-\(variant)-\(language)-simple-wide.png", language: language, view: "simple-wide",
                accounts: [account], sync: ReaderSyncState(phase: .on))
        }
        let header = remoteSourceHeader(timely, now: C3_PREVIEW_NOW, language: language, timeZone: C3_PREVIEW_ZONE)
        check(header.sources.map { $0.tone } == [.fresh, .late], "C5-08 preview has independent green/orange sources")
        check(remoteSourceHeader(old, now: C3_PREVIEW_NOW, language: language, timeZone: C3_PREVIEW_ZONE)
            .sources.map { $0.tone } == [.old, .fresh], "C5-08 preview includes red and retains two sources")
    }
    var solo = c3PreviewView(product: "codex", identity: 93, machines: ["macbook"])
    solo.isLocal = true; solo.data.source = nil
    solo.sourceReadings = [RemoteMachineReading(machineId: "mac", name: "macbook",
        asOf: solo.data.asOf, interval: 1800, isLocal: true)]
    render("c5-freshness-solo-ru-simple-wide.png", language: "ru", view: "simple-wide", accounts: [solo], sync: ReaderSyncState(phase: .off))
    check(written == 209, "C3-10 209 actual AppKit matrix PNGs saved")
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
        expected.insert("c5-both-reset-\(language)-simple-narrow.png")
        for state in [5, 6] { expected.insert("c3-date-\(state)-\(language)-simple-narrow.png") }
        expected.insert("c3-date-5-longname-\(language)-simple-narrow.png")
        expected.insert("c3-settings-long-error-\(language)-simple.png")
        for view in views { expected.insert("c3-long-names-\(language)-\(view).png") }
        for view in ["simple", "advanced"] { expected.insert("c3-settings-accounts-\(language)-\(view).png") }
        expected.insert("c5-history-only-product-\(language)-advanced.png")
        for view in ["simple", "advanced"] { expected.insert("c3-actions-two-codex-\(language)-\(view).png") }
    }
    expected.insert("c5-freshness-solo-ru-simple-wide.png")
    for language in languages {
        for view in ["simple-narrow", "advanced"] { expected.insert("c5-freshness-\(language)-\(view).png") }
        for variant in ["late", "old"] { expected.insert("c5-freshness-\(variant)-\(language)-simple-wide.png") }
    }
    expected.formUnion(["c5-26-advanced-ru.png", "c5-26-advanced-en.png",
        "c5-26-one-subscription-ru.png", "c5-26-long-labels-ru.png"])
    let registered = Set(files)
    expect(expected.count == 213, "matrix has 213 specified scenes")
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

/// C5-25/26 run only after NSApplication registration. Every rectangle/text width
/// below is reported by the real drawAdvanced bitmap pass, never a layout replica.
@discardableResult
func runRemoteLimitsC5AppKitTests(previewDir: URL, files: inout [String], check: (Bool, String) -> Void) -> Int {
    guard CommandLine.arguments.contains("--subscriptions-selftest"), UserDefaults.standard is MemorySelfTestDefaults else {
        check(false, "C5-25/26 require isolated AppKit selftest defaults"); return 0
    }
    let defaults = UserDefaults.standard, saved = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
    let savedProductPrice = defaults.object(forKey: "productSubscriptionUSD")
    defer {
        defaults.set(savedProductPrice, forKey: "productSubscriptionUSD")
        defaults.setVolatileDomain(saved, forName: UserDefaults.argumentDomain)
    }
    let now = c3PreviewDate("2026-11-01T09:34:00Z"), zone = TimeZone(secondsFromGMT: 3 * 3600)!
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
    func fixture() -> [AccountView] {
        // Limits and the final seven bars come from the accepted mockup. The
        // preceding days complete its monthly totals ($7000 / $6270) and active-day amounts.
        var claude = c3PreviewView(product: "claude", identity: 94, machines: ["vps"])
        claude.caption = ""; claude.tier = nil; claude.data.plan = "max"
        claude.data.session = 2; claude.data.weekly = 29
        claude.data.sessionReset = now.addingTimeInterval(5 * 3600 * (1 - 0.203))
        claude.data.weeklyReset = now.addingTimeInterval(168 * 3600 * (1 - 0.285))
        claude.data.scoped = ScopedLimit(name: "Fable", percent: 43, reset: claude.data.weeklyReset, severity: nil)
        var codex = c3PreviewView(product: "codex", identity: 95, machines: ["macbook", "vps"])
        codex.caption = ""; codex.data.session = nil; codex.data.sessionReset = nil
        codex.data.weekly = 77; codex.data.resetCredits = 1
        codex.data.weeklyReset = now.addingTimeInterval(168 * 3600 * (1 - 0.613))
        let last7: [Double] = [26, 23, 213, 152, 113, 317, 153]
        let astra7: [Double] = [25, 22, 180, 120, 85, 210, 108]
        func usage(_ usd: Double, model: String, turns: Int = 1) -> DayModelUsage {
            var unit = DayModelUsage(); unit.input = 1_000_000
            var value = DayModelUsage(); value.input = Int((usd / (apiCost(model, unit) ?? 1) * 1_000_000).rounded())
            value.turns = turns; return value
        }
        for i in 0..<35 {
            let date = calendar.date(byAdding: .day, value: i - 34, to: now)!
            let f = DateFormatter(); f.timeZone = zone; f.dateFormat = "yyyy-MM-dd"
            let key = f.string(from: date)
            if i >= 15 { claude.usageDays[key] = ["claude-opus": usage(350, model: "claude-opus")] }
            if i >= 28 {
                codex.usageDays[key] = ["gpt-6-astra": usage(astra7[i - 28], model: "gpt-6-astra"),
                    "gpt-6.1-sol": usage(last7[i - 28] - astra7[i - 28], model: "gpt-6.1-sol", turns: 0)]
            } else if i != 5 && i != 24 {
                codex.usageDays[key] = ["gpt-6.1-sol": usage((6270 - last7.reduce(0, +)) / 26, model: "gpt-6.1-sol")]
            }
        }
        for view in [claude, codex] { check(view.usageDays.count > 0, "C5-26 mockup has actual usage") }
        for viewIndex in 0..<2 {
            if viewIndex == 0 {
                claude.data.asOf = now; claude.data.source?.asOf = now; claude.data.source?.attemptAt = now
                claude.data.source?.lastSeenAt = now; claude.data.source?.freshUntil = now.addingTimeInterval(3600)
            } else {
                codex.data.asOf = now; codex.data.source?.asOf = now; codex.data.source?.attemptAt = now
                codex.data.source?.lastSeenAt = now; codex.data.source?.freshUntil = now.addingTimeInterval(3600)
            }
        }
        claude.data.source?.nextAt = now.addingTimeInterval(1800); claude.data.source?.interval = 1800
        claude.sourceReadings = [RemoteMachineReading(machineId: "c5-vps", name: "vps", asOf: now, interval: 1800, isLocal: false)]
        codex.isLocal = true; codex.data.source = nil
        codex.sourceReadings = [RemoteMachineReading(machineId: "c5-macbook", name: "macbook", asOf: now, interval: 1800, isLocal: true),
            RemoteMachineReading(machineId: "c5-vps", name: "vps", asOf: now.addingTimeInterval(-2701), interval: 1800, isLocal: false)]
        return [claude, codex]
    }
    var written = 0
    struct Rendered {
        var height: CGFloat
        var elements: [AdvancedDrawElement]
        var hits: [Hit]
        func element(_ id: String) -> AdvancedDrawElement? { elements.first { $0.id == id } }
    }
    func render(_ views: [AccountView], language: String, expanded: Bool = true, name: String? = nil,
                extra: [String: Any] = [:]) -> Rendered? {
        AppKitSelfTestWatchdog.shared.begin("C5-25/26 " + (name ?? language))
        var preferences = saved
        preferences["lang"] = language; preferences["advanced"] = true
        preferences["advHistExpanded"] = expanded; preferences["advHistProduct"] = "codex"
        preferences["autoPoll"] = true; preferences["interval"] = 1800
        preferences["subClaude"] = 200.0; preferences["subCodex"] = 200.0
        preferences["monitor_claude"] = views.contains { $0.product == "claude" }
        preferences["monitor_codex"] = views.contains { $0.product == "codex" }
        preferences["productSubscriptionUSD"] = [String: Double](); preferences["accountSubscriptionUSD"] = [String: Double]()
        preferences["hiddenAccounts"] = [String](); preferences["localAccountCaptions"] = [String: String]()
        for (key, value) in extra { preferences[key] = value }
        defaults.setVolatileDomain(preferences, forName: UserDefaults.argumentDomain)
        var frame = RemoteAccountFrame(now: now, sync: ReaderSyncState(phase: .on),
            allViews: views, visibleViews: views, displayedViews: views)
        frame.subscriptions = historySubscriptions(views: views, index: historyPreviewIndex(views), now: now, language: language)
        return withRemoteRenderScene(frame: frame, timeZone: zone, manual: .idle) {
            let empty = LimitData(present: false), height = advancedHeight(empty, empty)
            guard let ctx = bitmapContext(720, Int(ceil(height * 2))) else {
                check(false, "C5-26 bitmap allocation"); return nil
            }
            ctx.scaleBy(x: 2, y: 2)
            var elements: [AdvancedDrawElement] = []
            let hits = drawAdvanced(ctx, size: CGSize(width: 360, height: height), claude: empty, codex: empty,
                interval: 1800, updated: now, record: { elements.append($0) })
            check(hits.allSatisfy { $0.rect.minY >= 0 && $0.rect.maxY <= height }, "C5-26 actual hits inside bitmap \(language)")
            if let name = name, let image = ctx.makeImage(),
               let destination = CGImageDestinationCreateWithURL(previewDir.appendingPathComponent(name) as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, nil)
                let ok = CGImageDestinationFinalize(destination)
                check(ok && image.width == 720 && image.height == Int(ceil(height * 2)), "C5-26 @2x PNG " + name)
                if ok { files.append(name); written += 1 }
            } else if name != nil { check(false, "C5-26 cannot save preview") }
            return Rendered(height: height, elements: elements, hits: hits)
        }
    }
    func close(_ a: CGFloat?, _ b: CGFloat) -> Bool { a.map { abs($0 - b) <= 0.5 } ?? false }
    func validate(_ result: Rendered, language: String, long: Bool = false, one: Bool = false) {
        let rows = one ? ["codex"] : ["claude", "codex"]
        let history = result.element("history"), selector = result.element("selector"), heading = result.element("history:heading")
        check(close(history?.rect.height, (one ? 172 : 187) + (long ? 22 : 0)), "C5-26 \(language): actual history height")
        check(close(selector?.rect.maxY, (heading?.rect.maxY ?? 0) - (long ? 22 : 0)), "C5-26 \(language): actual selector top == hy (+22 for long L)")
        let segments = result.hits.filter { $0.id.hasPrefix("histsubscription:") }
        check(segments.count == rows.count && Set(segments.map { $0.rect.minY }).count == 1,
              "C5-26 \(language): actual selector has exactly one row of product tabs")
        for product in rows {
            let segment = result.element("segment:" + product)
            check(segment?.fontSize == 10.5 && (long ? segment?.text?.hasSuffix("…") == true : segment?.text == (product == "claude" ? "Claude Max" : "Codex Pro")),
                  "C5-26 \(language): actual segment text, fixed 10.5pt font and ellipsis")
            if long { check(segments.first { $0.id == "histsubscription:" + product }?.tooltip?.count == 32, "C5-26 full L in real tooltip/AX hit") }
            for (column, edge) in [CGFloat(190), 283, 334].enumerated() {
                check(close(result.element("money:\(product):\(column)")?.rect.maxX, edge), "C5-26 \(language): actual table right edge \(edge)")
            }
            check(result.element("moneytitle:" + product)?.fontSize == 10.5, "C5-26 actual table title font")
        }
        if !one {
            let a = result.element("money:claude:0"), b = result.element("money:codex:0")
            check(close(a.map { $0.rect.maxY - (b?.rect.maxY ?? 0) }, 15), "C5-26 \(language): drawn table rows are 15pt apart")
        }
        let notes = result.elements.filter { $0.id.hasPrefix("note:") }
        check(notes.count == 1 && notes.allSatisfy { $0.rect.maxX <= 334.5 && $0.rect.minY >= 0 && !($0.text ?? "").contains("…") },
              "C5-26 \(language): actual active-day note fits fully")
        let note = notes.first?.text ?? ""
        let full = (language == "en" ? "on an active day at API price: " : "в активный день по API: ") + (one ? "" : "Claude Max ≈ $350 · ") + "Codex Pro ≈ $190"
        let fits = lineWidth(CTLineCreateWithAttributedString(ctAttr(full, ctFont(9.5, .regular), cg(.white)))) <= 308
        check(long || !fits ? ((one || note.contains("Claude ≈")) && note.contains("Codex ≈") && !note.contains("Ж"))
                            : note == full, "C5-26 \(language): full names before product-name compression")
        for id in ["footer", "credit"] {
            check(result.element(id).map { $0.rect.minY >= 0 && $0.rect.maxY <= result.height } == true,
                  "C5-26 \(language): actual \(id) entirely inside window")
        }
        check(result.element("segment:codex")?.selected == true, "C5-26 actual draw selects Codex Pro")
    }
    for language in ["ru", "en"] {
        let views = fixture()
        if let main = render(views, language: language, name: "c5-26-advanced-\(language).png") {
            check(close(main.height, 722), "C5-26 \(language): advancedHeight → drawAdvanced window is 722pt")
            check(close(main.element("card:0")?.rect.height, 226) && close(main.element("card:1")?.rect.height, 176),
                  "C5-25 \(language): actual drawn cards are 226/176 without blank footer")
            validate(main, language: language)
            var long = views
            for i in long.indices { long[i].customCaption = String(repeating: "Ж", count: 32); long[i].caption = long[i].customCaption! }
            if let drawn = render(long, language: language, name: language == "ru" ? "c5-26-long-labels-ru.png" : nil) {
                check(close(drawn.height - main.height, 22), "C5-26 \(language): real long selector grows whole window by22")
                validate(drawn, language: language, long: true)
            }
        }
        if let one = render([views[1]], language: language, name: language == "ru" ? "c5-26-one-subscription-ru.png" : nil) {
            validate(one, language: language, one: true)
        }
        var costly = views
        for i in costly.indices {
            costly[i].customCaption = String(repeating: "Ж", count: 32)
            for day in Array(costly[i].usageDays.keys) {
                for model in Array(costly[i].usageDays[day]!.keys) { costly[i].usageDays[day]![model]!.input *= 1_000_000_000 }
            }
        }
        if let drawn = render(costly, language: language) {
            let notes = drawn.elements.filter { $0.id.hasPrefix("note:") }
            check(notes.count > 1 && notes.allSatisfy { $0.rect.maxX <= 334.5 && !($0.text ?? "").contains("…") }
                  && notes.contains { ($0.text ?? "").hasPrefix("Codex ≈ $") }, "C5-26 actual CoreText overflow moves the whole product item")
            for i in notes.indices.dropFirst() { check(close(notes[i - 1].rect.maxY - notes[i].rect.maxY, 12), "C5-26 actual wrapped note step12") }
            check(close(drawn.height, 722 + 22 + CGFloat(notes.count - 1) * 12)
                  && (drawn.element("credit")?.rect.minY ?? -1) >= 0, "C5-26 wrapped text grows real window with footer")
        }
        var offline = views
        for i in offline.indices {
            offline[i].isLocal = false; offline[i].state = .offline
            var source = RemoteSource(machineId: "c5-vps", machineName: "vps")
            source.asOf = now; source.lastSeenAt = now.addingTimeInterval(-3600); source.freshUntil = now.addingTimeInterval(3600)
            offline[i].data.source = source
        }
        if let drawn = render(offline, language: language) {
            check(close(drawn.element("card:0")?.rect.height, 244) && close(drawn.element("card:1")?.rect.height, 194)
                  && drawn.hits.filter { $0.id.hasPrefix("quotafeedback:") }.count == 2,
                  "C5-25 \(language): real status footer adds exactly18pt")
        }
        for count in 2...4 {
            var stack = views
            while stack.count < count {
                var other = views[1]; other.historyKey += "-\(stack.count)"; other.label = other.historyKey; other.usageDays = [:]
                stack.append(other)
            }
            if let drawn = render(stack, language: language, expanded: false) {
                let cards = drawn.elements.filter { $0.id.hasPrefix("card:") }
                check(cards.count == count && cards.allSatisfy { $0.rect.minX == 15 && $0.rect.width == 330 }, "C3-06 actual Advanced stack count/width")
                for i in cards.indices.dropFirst() { check(close(cards[i - 1].rect.minY - cards[i].rect.maxY, 5), "C3-06 actual5pt gap") }
                check(!drawn.hits.contains { $0.id.hasPrefix("histsubscription:") || $0.id.hasPrefix("moneysubscription:") }
                      && drawn.element("history")?.rect.height == 35, "C3-20 actual collapsed history has no tabs/table")
            }
        }
    }
    // P1: two saved account prices are exposed as one product price/settings row.
    for language in ["ru", "en"] {
        var local = fixture()[1]; local.isLocal = true; local.data.source = nil
        local.customCaption = language == "ru" ? "Работа" : "Work"; local.caption = local.customCaption!
        var older = local; older.isLocal = false; older.historyKey += "-old"; older.label = older.historyKey
        older.data.asOf = now.addingTimeInterval(-60); older.customCaption = nil; older.caption = ""
        let accounts = [older, local], legacy = [remoteAccountID(older): 200.0, remoteAccountID(local): 100.0]
        _ = render(accounts, language: language, extra: ["accountSubscriptionUSD": legacy])
        // Allow the real setter to change the RAM value rather than shadowing it
        // with the renderer fixture's argument-domain reset.
        var arguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments.removeValue(forKey: "productSubscriptionUSD")
        defaults.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defaults.removeObject(forKey: "productSubscriptionUSD")
        var frame = RemoteAccountFrame(now: now, sync: ReaderSyncState(phase: .on),
            allViews: accounts, visibleViews: accounts, displayedViews: accounts)
        frame.subscriptions = historySubscriptions(views: accounts, index: historyPreviewIndex(accounts), now: now, language: language)
        withRemoteRenderScene(frame: frame, timeZone: zone, manual: .idle) {
            migrateProductSubscriptionPrices(frame.subscriptions!)
            let row = historyMoneyRows(frame.subscriptions!)[0]
            let height = settingsTotalHeight(AboutState())
            guard let ctx = bitmapContext(720, Int(ceil(height * 2))) else { check(false, "C5-24 settings bitmap"); return }
            ctx.scaleBy(x: 2, y: 2)
            let hits = drawSettings(ctx, size: CGSize(width: 360, height: height), about: AboutState())
                .filter { $0.id.hasPrefix("productsub:") }
            check(hits.count == 4 && Set(hits.map { $0.rect.minY }).count == 1
                  && hits.allSatisfy { ($0.tooltip ?? "").hasPrefix(row.title + " · " + row.monthly)
                      && !($0.tooltip ?? "").contains("unlabelled") && !($0.tooltip ?? "").contains("не указан") },
                  "C5-24 P1 actual settings: one product row has history's complete title and price")
            check(row.monthly.contains("$100") && hits.allSatisfy { ($0.tooltip ?? "").contains("$200") },
                  "C5-24 P1 migrated price wins and retained conflicting price is disclosed")
            setProductSubscriptionPrice("codex", usd: 200)
            check(historyMoneyRows(frame.subscriptions!)[0].monthly.contains("$200"), "C5-24 P1 settings selection immediately changes history")
        }
    }
    check(written == 4, "C5-26 four actual Advanced @2x PNGs saved")
    return written
}
