// LimitsMonitor.swift
// Standalone macOS menu-bar app: shows remaining Claude Code + Codex usage limits
// as "session%(5h) / weekly%(7d)" with each brand icon to its left.
// No SwiftBar, no third-party deps — Foundation + AppKit + CoreText + ImageIO.

import Foundation
import AppKit
import CoreText
import ImageIO
import Darwin

// MARK: - Constants

let HOME       = NSHomeDirectory()
let DATA_DIR   = HOME + "/.claude-limits-monitor"
let CACHE_PATH = DATA_DIR + "/cache.json"
let LOCK_PATH  = DATA_DIR + "/app.lock"
let CLIENT_ID  = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
let UA         = "claude-cli/2.1.81 (external, cli)"
let KC_SERVICE = "Claude Code-credentials"
let BUNDLE_ID  = "com.arrivarus.claudecodexlimits"
let AGENT_PLIST = HOME + "/Library/LaunchAgents/\(BUNDLE_ID).plist"

func assetPath(_ name: String) -> String {
    if let res = Bundle.main.resourcePath {
        let p = res + "/" + name
        if FileManager.default.fileExists(atPath: p) { return p }
    }
    return DATA_DIR + "/assets/" + name
}

// MARK: - Shell

@discardableResult
func shell(_ path: String, _ args: [String]) -> (code: Int32, out: String, err: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let o = Pipe(); let e = Pipe()
    p.standardOutput = o; p.standardError = e
    do { try p.run() } catch { return (-1, "", "\(error)") }
    let od = o.fileHandleForReading.readDataToEndOfFile()
    let ed = e.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus,
            String(data: od, encoding: .utf8) ?? "",
            String(data: ed, encoding: .utf8) ?? "")
}

// MARK: - HTTP (synchronous; call off the main thread)

func http(_ url: String, method: String, headers: [String: String], body: Data?) -> (status: Int, data: Data?, err: String?) {
    guard let u = URL(string: url) else { return (0, nil, "bad url") }
    var r = URLRequest(url: u, timeoutInterval: 15)
    r.httpMethod = method
    for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
    r.httpBody = body
    let sem = DispatchSemaphore(value: 0)
    var st = 0; var dat: Data?; var er: String?
    URLSession.shared.dataTask(with: r) { d, resp, e in
        if let e = e { er = e.localizedDescription }
        if let h = resp as? HTTPURLResponse { st = h.statusCode }
        dat = d
        sem.signal()
    }.resume()
    if sem.wait(timeout: .now() + 20) == .timedOut { return (0, nil, "timeout") }
    return (st, dat, er)
}

// MARK: - Model

struct LimitData {
    var session: Double?
    var weekly: Double?
    var sessionReset: Date?
    var weeklyReset: Date?
    var plan: String?
    var asOf: Date?
    var error: String?
    var stale = false
    var fromCache = false
    var present = true         // false → product not set up on this Mac (hide its row/card)
}

// MARK: - Date helpers

func parseISOmicroOffset(_ s: String) -> Date? {
    let cleaned = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
    return f.date(from: cleaned)
}

func parseISOmillisZ(_ s: String) -> Date? {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: s) ?? {
        let g = ISO8601DateFormatter(); g.formatOptions = [.withInternetDateTime]
        return g.date(from: s)
    }()
}

// MARK: - Claude Code

func fetchClaude() -> LimitData {
    var d = LimitData()
    let kc = shell("/usr/bin/security", ["find-generic-password", "-s", KC_SERVICE, "-w"])
    if kc.code == 44 { d.present = false; return d }   // keychain item not found → Claude Code not set up
    guard kc.code == 0,
          let data = kc.out.data(using: .utf8),
          var creds = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          var oauth = creds["claudeAiOauth"] as? [String: Any]
    else { d.error = "нет доступа к keychain Claude"; return d }

    d.plan = oauth["subscriptionType"] as? String
    var at = oauth["accessToken"] as? String ?? ""
    let exp = (oauth["expiresAt"] as? Double) ?? 0
    let nowMs = Date().timeIntervalSince1970 * 1000

    if at.isEmpty || exp - nowMs < 120_000 {
        if let rt = oauth["refreshToken"] as? String, !rt.isEmpty {
            let bodyObj: [String: Any] = ["grant_type": "refresh_token",
                                          "refresh_token": rt, "client_id": CLIENT_ID]
            let body = try? JSONSerialization.data(withJSONObject: bodyObj)
            let resp = http("https://api.anthropic.com/v1/oauth/token", method: "POST",
                            headers: ["Content-Type": "application/json",
                                      "User-Agent": UA, "Accept": "application/json"], body: body)
            if resp.status == 200, let rd = resp.data,
               let tok = (try? JSONSerialization.jsonObject(with: rd)) as? [String: Any],
               let newAt = tok["access_token"] as? String {
                at = newAt
                oauth["accessToken"] = newAt
                if let newRt = tok["refresh_token"] as? String { oauth["refreshToken"] = newRt }
                let ein = (tok["expires_in"] as? Double) ?? 28800
                oauth["expiresAt"] = (Date().timeIntervalSince1970 + ein) * 1000
                creds["claudeAiOauth"] = oauth
                if let outData = try? JSONSerialization.data(withJSONObject: creds),
                   let outStr = String(data: outData, encoding: .utf8) {
                    _ = shell("/usr/bin/security",
                              ["add-generic-password", "-U", "-a", NSUserName(),
                               "-s", KC_SERVICE, "-w", outStr])
                }
            } else if at.isEmpty {
                d.error = "refresh не удался (HTTP \(resp.status))"; return d
            }
        } else if at.isEmpty {
            d.error = "нет refresh-токена"; return d
        }
    }

    let resp = http("https://api.anthropic.com/api/oauth/usage", method: "GET",
                    headers: ["Authorization": "Bearer \(at)", "User-Agent": UA,
                              "Accept": "application/json",
                              "anthropic-beta": "oauth-2025-04-20",
                              "anthropic-version": "2023-06-01"], body: nil)
    guard resp.status == 200, let ud = resp.data,
          let j = (try? JSONSerialization.jsonObject(with: ud)) as? [String: Any]
    else { d.error = "usage HTTP \(resp.status)"; return d }

    if let fh = j["five_hour"] as? [String: Any] {
        d.session = fh["utilization"] as? Double
        if let rs = fh["resets_at"] as? String { d.sessionReset = parseISOmicroOffset(rs) }
    }
    if let sd = j["seven_day"] as? [String: Any] {
        d.weekly = sd["utilization"] as? Double
        if let rs = sd["resets_at"] as? String { d.weeklyReset = parseISOmicroOffset(rs) }
    }
    d.asOf = Date()
    return d
}

// MARK: - Codex

func fetchCodex() -> LimitData {
    var d = LimitData()
    let base = HOME + "/.codex/sessions"
    let fm = FileManager.default
    guard let en = fm.enumerator(atPath: base) else { d.present = false; return d }   // no ~/.codex → Codex not set up
    var files: [(String, Date)] = []
    for case let rel as String in en {
        if rel.hasSuffix(".jsonl"), rel.contains("rollout-") {
            let full = base + "/" + rel
            if let attr = try? fm.attributesOfItem(atPath: full),
               let m = attr[.modificationDate] as? Date { files.append((full, m)) }
        }
    }
    if files.isEmpty { d.error = "нет rollout-файлов Codex"; return d }
    files.sort { $0.1 > $1.1 }

    var bestTs = ""
    var bestRL: [String: Any]?
    var lastPlan: String?
    var lastPlanTs = ""
    for (path, _) in files.prefix(6) {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
        content.enumerateLines { line, _ in
            guard line.contains("\"rate_limits\"") else { return }
            guard let ld = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: ld)) as? [String: Any],
                  let ts = obj["timestamp"] as? String,
                  let payload = obj["payload"] as? [String: Any],
                  let rl = payload["rate_limits"] as? [String: Any] else { return }
            if ts > bestTs { bestTs = ts; bestRL = rl }
            if let p = rl["plan_type"] as? String, ts > lastPlanTs { lastPlanTs = ts; lastPlan = p }
        }
    }
    guard let rl = bestRL else { d.error = "нет данных лимитов в rollout"; return d }
    if let p = rl["primary"] as? [String: Any] {
        d.session = p["used_percent"] as? Double
        if let r = p["resets_at"] as? Double { d.sessionReset = Date(timeIntervalSince1970: r) }
    }
    if let s = rl["secondary"] as? [String: Any] {
        d.weekly = s["used_percent"] as? Double
        if let r = s["resets_at"] as? Double { d.weeklyReset = Date(timeIntervalSince1970: r) }
    }
    d.plan = (rl["plan_type"] as? String) ?? lastPlan
    d.asOf = parseISOmillisZ(bestTs)
    if let a = d.asOf, Date().timeIntervalSince(a) > 2 * 3600 { d.stale = true }
    return d
}

// MARK: - Cache

func ld2dict(_ d: LimitData) -> [String: Any] {
    var m = [String: Any]()
    if let v = d.session { m["session"] = v }
    if let v = d.weekly { m["weekly"] = v }
    if let v = d.sessionReset { m["sReset"] = v.timeIntervalSince1970 }
    if let v = d.weeklyReset { m["wReset"] = v.timeIntervalSince1970 }
    if let v = d.plan { m["plan"] = v }
    if let v = d.asOf { m["asOf"] = v.timeIntervalSince1970 }
    return m
}

func dict2ld(_ m: [String: Any]) -> LimitData {
    var d = LimitData()
    d.session = m["session"] as? Double
    d.weekly = m["weekly"] as? Double
    if let v = m["sReset"] as? Double { d.sessionReset = Date(timeIntervalSince1970: v) }
    if let v = m["wReset"] as? Double { d.weeklyReset = Date(timeIntervalSince1970: v) }
    d.plan = m["plan"] as? String
    if let v = m["asOf"] as? Double { d.asOf = Date(timeIntervalSince1970: v) }
    d.fromCache = true
    return d
}

func applyCache(_ claude: inout LimitData, _ codex: inout LimitData) {
    var cache: [String: Any] = [:]
    if let cd = try? Data(contentsOf: URL(fileURLWithPath: CACHE_PATH)),
       let cj = (try? JSONSerialization.jsonObject(with: cd)) as? [String: Any] { cache = cj }
    if claude.present, claude.error != nil, let cm = cache["claude"] as? [String: Any] {
        let e = claude.error; claude = dict2ld(cm); claude.error = e
    }
    if codex.present, codex.error != nil, let cm = cache["codex"] as? [String: Any] {
        let e = codex.error; codex = dict2ld(cm); codex.error = e
    }
    if claude.present, claude.error == nil { cache["claude"] = ld2dict(claude) }
    if codex.present, codex.error == nil { cache["codex"] = ld2dict(codex) }
    if let outD = try? JSONSerialization.data(withJSONObject: cache) {
        try? outD.write(to: URL(fileURLWithPath: CACHE_PATH))
    }
}

// MARK: - Severity & colors

func severity(_ v: Double?) -> Int {
    guard let v = v else { return 0 }
    if v >= 80 { return 2 }; if v >= 50 { return 1 }; return 0
}

func sevColor(_ s: Int, dark: Bool) -> NSColor {
    switch s {
    case 2:  return NSColor(srgbRed: 0.91, green: 0.27, blue: 0.30, alpha: 1)
    case 1:  return NSColor(srgbRed: 0.89, green: 0.62, blue: 0.04, alpha: 1)
    default: return dark ? .white : .black
    }
}

// MARK: - Rendering (CoreGraphics + CoreText)

func numText(_ v: Double?) -> String {
    guard let v = v else { return "–" }
    return String(Int(v.rounded()))
}

func cg(_ c: NSColor) -> CGColor {
    let r = c.usingColorSpace(.sRGB) ?? c
    return CGColor(srgbRed: r.redComponent, green: r.greenComponent, blue: r.blueComponent, alpha: r.alphaComponent)
}

func ctFont(_ size: CGFloat, _ weight: NSFont.Weight) -> CTFont {
    let ns = NSFont.systemFont(ofSize: size, weight: weight)
    return CTFontCreateWithFontDescriptor(ns.fontDescriptor as CTFontDescriptor, size, nil)
}

func ctAttr(_ s: String, _ font: CTFont, _ color: CGColor) -> NSAttributedString {
    NSAttributedString(string: s, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ])
}

func groupString(_ d: LimitData, dark: Bool, font: CTFont) -> NSAttributedString {
    let neutral = cg(dark ? .white : .black)
    let dim = cg((dark ? NSColor.white : NSColor.black).withAlphaComponent(0.95))
    let isErr = d.error != nil
    let sCol = isErr ? neutral : cg(sevColor(severity(d.session), dark: dark))
    let wCol = isErr ? neutral : cg(sevColor(severity(d.weekly), dark: dark))
    let m = NSMutableAttributedString()
    m.append(ctAttr(numText(d.session), font, sCol))
    m.append(ctAttr("/", font, dim))
    m.append(ctAttr(numText(d.weekly), font, wCol))
    m.append(ctAttr("%", font, dim))
    return m
}

func lineWidth(_ line: CTLine) -> CGFloat { CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) }

func bitmapContext(_ wpx: Int, _ hpx: Int) -> CGContext? {
    CGContext(data: nil, width: wpx, height: hpx, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
}

func loadCGImage(_ path: String) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(src, 0, nil)
}

/// Menu-bar strip for the products that are present — transparent bg, supersample `s` (2 = retina).
/// Two products → two compact stacked rows; one product → a single larger row; none → a dim "—".
func renderStrip(_ products: [(LimitData, String)], dark: Bool, s: CGFloat = 2) -> CGImage? {
    let H: CGFloat = 22 * s            // full menu-bar height
    let padX: CGFloat = 1 * s
    let fg = cg(dark ? .white : .black)

    if products.isEmpty {
        let font = ctFont(12 * s, .regular)
        let line = CTLineCreateWithAttributedString(ctAttr("—", font, fg))
        let W = ceil(lineWidth(line)) + 8 * s
        guard let ctx = bitmapContext(Int(W), Int(H)) else { return nil }
        ctx.textMatrix = .identity
        var a: CGFloat = 0, dd: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &a, &dd, nil)
        ctx.textPosition = CGPoint(x: 4 * s, y: (H - a - dd) / 2 + dd)
        CTLineDraw(line, ctx)
        return ctx.makeImage()
    }

    let two = products.count >= 2
    let rowH = two ? H / 2 : H
    let iconSz: CGFloat = (two ? 12 : 19) * s    // single product → fill the bar
    let gapIcon: CGFloat = (two ? 2.5 : 4) * s
    let font = ctFont((two ? 9 : 14.5) * s, two ? .regular : .medium)

    let lines = products.map { CTLineCreateWithAttributedString(groupString($0.0, dark: dark, font: font)) }
    let textW = lines.map { ceil(lineWidth($0)) }.max() ?? 0
    let textX = padX + iconSz + gapIcon
    let W = ceil(textX + textW + padX)

    guard let ctx = bitmapContext(Int(W), Int(H)) else { return nil }
    ctx.interpolationQuality = .high
    ctx.textMatrix = .identity
    var asc: CGFloat = 0, desc: CGFloat = 0
    _ = CTLineGetTypographicBounds(lines[0], &asc, &desc, nil)

    // CG origin is bottom-left → first product on top.
    for (i, prod) in products.enumerated() {
        let y0 = two ? (i == 0 ? rowH : 0) : 0
        let iconY = (y0 + (rowH - iconSz) / 2).rounded()
        if let img = loadCGImage(assetPath(prod.1)) {
            ctx.draw(img, in: CGRect(x: padX, y: iconY, width: iconSz, height: iconSz))
        }
        let baseY = (y0 + (rowH - asc - desc) / 2 + desc).rounded()
        ctx.textPosition = CGPoint(x: textX, y: baseY)
        CTLineDraw(lines[i], ctx)
    }
    return ctx.makeImage()
}

/// Renders the strip onto a menu-bar-like background and saves a PNG (for `--preview`).
func writePreview(_ products: [(LimitData, String)], dark: Bool, to path: String) {
    guard let strip = renderStrip(products, dark: dark, s: 6) else { return }
    let pad = 12 * 6, barH = 24 * 6
    let W = strip.width + pad * 2, H = barH
    guard let ctx = bitmapContext(W, H) else { return }
    let bg = dark ? NSColor(white: 0.14, alpha: 1) : NSColor(white: 0.96, alpha: 1)
    ctx.setFillColor(cg(bg)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    ctx.interpolationQuality = .high
    ctx.draw(strip, in: CGRect(x: pad, y: (H - strip.height) / 2, width: strip.width, height: strip.height))
    guard let out = ctx.makeImage() else { return }
    let data = NSMutableData()
    if let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) {
        CGImageDestinationAddImage(dest, out, nil)
        if CGImageDestinationFinalize(dest) { try? (data as Data).write(to: URL(fileURLWithPath: path)) }
    }
}

func menuIcon(_ name: String, _ pt: CGFloat) -> NSImage? {
    guard let img = NSImage(contentsOfFile: assetPath(name)) else { return nil }
    img.size = NSSize(width: pt, height: pt)
    return img
}

// MARK: - Formatting

func fmtReset(_ d: Date?) -> String {
    guard let d = d else { return "—" }
    let df = DateFormatter(); df.locale = Locale.current
    if Calendar.current.isDateInToday(d) { df.setLocalizedDateFormatFromTemplate("HH:mm") }
    else { df.setLocalizedDateFormatFromTemplate("d MMM HH:mm") }
    return df.string(from: d)
}

func pctText(_ v: Double?) -> String {
    guard let v = v else { return "—" }
    return "\(Int(v.rounded()))%"
}

func clockText(_ d: Date) -> String {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: d)
}

// MARK: - Login item (LaunchAgent)

func loginEnabled() -> Bool { FileManager.default.fileExists(atPath: AGENT_PLIST) }

func setLoginEnabled(_ on: Bool) {
    let fm = FileManager.default
    if on {
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(BUNDLE_ID)</string>
            <key>ProgramArguments</key>
            <array><string>\(exe)</string></array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><false/>
            <key>ProcessType</key><string>Interactive</string>
        </dict>
        </plist>
        """
        try? fm.createDirectory(atPath: HOME + "/Library/LaunchAgents", withIntermediateDirectories: true)
        try? plist.write(toFile: AGENT_PLIST, atomically: true, encoding: .utf8)
    } else {
        try? fm.removeItem(atPath: AGENT_PLIST)
    }
}

// MARK: - Panel rendering (custom dark popover, System-Control style)

struct Hit { let id: String; let rect: CGRect }

let PANEL_W: CGFloat = 360
let PANEL_H: CGFloat = 286
let APP_VERSION = "1.3"
let APP_AUTHOR = "Alex Kovalev"
let REPO_URL = "https://github.com/ArrivaRUS/claude-codex-limits"

func gray(_ w: CGFloat, _ a: CGFloat) -> NSColor { NSColor(white: w, alpha: a) }

func sfCGImage(_ name: String, _ pt: CGFloat, _ weight: NSFont.Weight, _ color: NSColor) -> CGImage? {
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
    let cfg = NSImage.SymbolConfiguration(pointSize: pt, weight: weight)
        .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
    guard let conf = base.withSymbolConfiguration(cfg) else { return nil }
    var r = CGRect(origin: .zero, size: conf.size)
    return conf.cgImage(forProposedRect: &r, context: nil, hints: nil)
}

func drawSF(_ ctx: CGContext, _ name: String, in rect: CGRect, _ color: NSColor, weight: NSFont.Weight = .regular) {
    guard let img = sfCGImage(name, rect.height, weight, color) else { return }
    let iw = CGFloat(img.width), ih = CGFloat(img.height)
    let scale = min(rect.width / iw, rect.height / ih)
    let w = iw * scale, h = ih * scale
    ctx.draw(img, in: CGRect(x: rect.midX - w/2, y: rect.midY - h/2, width: w, height: h))
}

func drawPower(_ ctx: CGContext, _ r: CGRect, _ color: NSColor) {
    let c = CGPoint(x: r.midX, y: r.midY)
    let rad = min(r.width, r.height) * 0.42
    ctx.saveGState()
    ctx.setStrokeColor(cg(color)); ctx.setLineWidth(1.7); ctx.setLineCap(.round)
    ctx.beginPath()
    ctx.addArc(center: c, radius: rad, startAngle: .pi * 110 / 180, endAngle: .pi * 70 / 180, clockwise: false)
    ctx.strokePath()
    ctx.beginPath()
    ctx.move(to: CGPoint(x: c.x, y: c.y + rad * 0.15))
    ctx.addLine(to: CGPoint(x: c.x, y: c.y + rad * 1.15))
    ctx.strokePath()
    ctx.restoreGState()
}

@discardableResult
func drawPanel(_ ctx: CGContext, size: CGSize, claude: LimitData, codex: LimitData,
               interval: TimeInterval, updated: Date?) -> [Hit] {
    let W = size.width, H = size.height
    var hits: [Hit] = []
    let cs = CGColorSpaceCreateDeviceRGB()

    let textHi = gray(1, 0.95), textMid = gray(1, 0.5), textLo = gray(1, 0.34)
    let blue = NSColor(srgbRed: 0.22, green: 0.55, blue: 1.0, alpha: 1)
    let purple = NSColor(srgbRed: 0.78, green: 0.42, blue: 0.98, alpha: 1)

    func rectTL(_ x: CGFloat, _ topY: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: H - topY - h, width: w, height: h)
    }
    func attr(_ s: String, _ sz: CGFloat, _ weight: NSFont.Weight, _ color: NSColor) -> NSAttributedString {
        ctAttr(s, ctFont(sz, weight), cg(color))
    }
    func text(_ s: NSAttributedString, x: CGFloat, topY: CGFloat, align: Int = 0) {
        let line = CTLineCreateWithAttributedString(s)
        var asc: CGFloat = 0, desc: CGFloat = 0
        let w = CGFloat(CTLineGetTypographicBounds(line, &asc, &desc, nil))
        var dx = x
        if align == 1 { dx = x - w / 2 } else if align == 2 { dx = x - w }
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: dx, y: H - topY - asc)
        CTLineDraw(line, ctx)
    }
    func roundFill(_ r: CGRect, _ rad: CGFloat, _ color: NSColor) {
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil))
        ctx.setFillColor(cg(color)); ctx.fillPath()
    }
    func roundStroke(_ r: CGRect, _ rad: CGFloat, _ color: NSColor, _ lw: CGFloat) {
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil))
        ctx.setStrokeColor(cg(color)); ctx.setLineWidth(lw); ctx.strokePath()
    }
    func metricColor(_ base: NSColor, _ v: Double?) -> NSColor {
        switch severity(v) {
        case 2: return NSColor(srgbRed: 1, green: 0.27, blue: 0.23, alpha: 1)
        case 1: return NSColor(srgbRed: 1, green: 0.62, blue: 0.04, alpha: 1)
        default: return base
        }
    }
    func gauge(cx: CGFloat, cyTop: CGFloat, r: CGFloat, th: CGFloat, pct: Double?, color: NSColor) {
        let c = CGPoint(x: cx, y: H - cyTop)
        let startA = CGFloat.pi * 1.25, sweep = CGFloat.pi * 1.5
        ctx.setLineWidth(th); ctx.setLineCap(.round)
        ctx.beginPath()
        ctx.addArc(center: c, radius: r, startAngle: startA, endAngle: startA - sweep, clockwise: true)
        ctx.setStrokeColor(cg(gray(1, 0.08))); ctx.strokePath()
        if let v = pct, v > 0 {
            let p = CGFloat(min(100, max(0, v))) / 100
            ctx.saveGState()
            ctx.setShadow(offset: .zero, blur: 5, color: cg(color.withAlphaComponent(0.55)))
            ctx.beginPath()
            ctx.addArc(center: c, radius: r, startAngle: startA, endAngle: startA - sweep * p, clockwise: true)
            ctx.setStrokeColor(cg(color)); ctx.strokePath()
            ctx.restoreGState()
        }
    }
    func dot(_ x: CGFloat, centerTopY: CGFloat, _ color: NSColor) {
        ctx.setFillColor(cg(color))
        ctx.fillEllipse(in: CGRect(x: x, y: H - centerTopY - 3, width: 6, height: 6))
    }

    // background: gradient + warm glow + hairline border
    let bgPath = CGPath(roundedRect: CGRect(x: 0.5, y: 0.5, width: W - 1, height: H - 1),
                        cornerWidth: 18, cornerHeight: 18, transform: nil)
    ctx.saveGState(); ctx.addPath(bgPath); ctx.clip()
    if let g = CGGradient(colorsSpace: cs, colors: [cg(gray(0.16, 1)), cg(gray(0.075, 1))] as CFArray, locations: [0, 1]) {
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])
    }
    if let glow = CGGradient(colorsSpace: cs,
            colors: [cg(NSColor(srgbRed: 1, green: 0.5, blue: 0.2, alpha: 0.10)),
                     cg(NSColor(srgbRed: 1, green: 0.5, blue: 0.2, alpha: 0))] as CFArray, locations: [0, 1]) {
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 54, y: H - 26), startRadius: 0,
                               endCenter: CGPoint(x: 54, y: H - 26), endRadius: 170, options: [])
    }
    ctx.restoreGState()
    ctx.addPath(bgPath); ctx.setStrokeColor(cg(gray(1, 0.08))); ctx.setLineWidth(1); ctx.strokePath()

    let pad: CGFloat = 16

    // which products are present
    var prods: [(LimitData, String, String, String)] = []   // (data, name, icon, url)
    if claude.present {
        prods.append((claude, "Claude Code", "claude_128.png", "https://claude.ai/settings/usage"))
    }
    if codex.present {
        prods.append((codex, "Codex", "codex_128.png", "https://chatgpt.com/codex/cloud/settings/analytics#usage"))
    }

    // header — the app's OWN icon + subtitle of present products
    let subtitle = prods.isEmpty ? "не найдено" : prods.map { $0.1 }.joined(separator: " · ")
    if let img = loadCGImage(assetPath("appicon.png")) { ctx.draw(img, in: rectTL(pad, pad - 1, 30, 30)) }
    text(attr("Лимиты", 15, .semibold, textHi), x: pad + 40, topY: pad - 1)
    text(attr(subtitle, 11, .regular, textLo), x: pad + 40, topY: pad + 17)
    let rfRect = rectTL(W - pad - 24, pad - 2, 24, 24)
    drawSF(ctx, "arrow.clockwise", in: rfRect.insetBy(dx: 4, dy: 4), textMid, weight: .semibold)
    hits.append(Hit(id: "refresh", rect: rfRect))

    // cards
    let cardsTop: CGFloat = 58, cardH: CGFloat = 152, gap: CGFloat = 12
    let cardW = (W - pad * 2 - gap) / 2

    func drawCard(_ x: CGFloat, _ w: CGFloat, _ d: LimitData, name: String, icon: String, url: String) {
        let r = rectTL(x, cardsTop, w, cardH)
        roundFill(r, 14, gray(1, 0.04)); roundStroke(r, 14, gray(1, 0.06), 1)
        hits.append(Hit(id: "open:\(url)", rect: r))
        if let img = loadCGImage(assetPath(icon)) { ctx.draw(img, in: rectTL(x + 14, cardsTop + 13, 18, 18)) }
        text(attr(name, 12.5, .semibold, gray(1, 0.9)), x: x + 39, topY: cardsTop + 15)
        drawSF(ctx, "arrow.up.forward", in: rectTL(x + w - 21, cardsTop + 11, 11, 11), gray(1, 0.22), weight: .semibold)

        let cx = x + w / 2, cyTop = cardsTop + 84
        let sCol = metricColor(blue, d.session), wCol = metricColor(purple, d.weekly)
        gauge(cx: cx, cyTop: cyTop, r: 38, th: 6, pct: d.weekly, color: wCol)
        gauge(cx: cx, cyTop: cyTop, r: 26, th: 6, pct: d.session, color: sCol)
        let sTxt = d.session == nil ? "—" : numText(d.session) + "%"
        let wTxt = d.weekly == nil ? "—" : numText(d.weekly) + "%"
        text(attr(sTxt, 15, .semibold, sCol), x: cx, topY: cyTop - 18, align: 1)
        text(attr(wTxt, 15, .semibold, wCol), x: cx, topY: cyTop + 1, align: 1)
        let lx = x + 16, l1 = cardsTop + 124, l2 = cardsTop + 139
        dot(lx, centerTopY: l1 + 5, sCol)
        text(attr("Сессия", 10.5, .regular, textMid), x: lx + 11, topY: l1)
        text(attr(fmtReset(d.sessionReset), 10, .regular, textLo), x: x + w - 14, topY: l1, align: 2)
        dot(lx, centerTopY: l2 + 5, wCol)
        text(attr("Неделя", 10.5, .regular, textMid), x: lx + 11, topY: l2)
        text(attr(fmtReset(d.weeklyReset), 10, .regular, textLo), x: x + w - 14, topY: l2, align: 2)
    }

    if prods.count >= 2 {
        drawCard(pad, cardW, prods[0].0, name: prods[0].1, icon: prods[0].2, url: prods[0].3)
        drawCard(pad + cardW + gap, cardW, prods[1].0, name: prods[1].1, icon: prods[1].2, url: prods[1].3)
    } else if prods.count == 1 {
        drawCard(pad, W - pad * 2, prods[0].0, name: prods[0].1, icon: prods[0].2, url: prods[0].3)
    } else {
        text(attr("Claude Code и Codex не найдены", 12, .regular, textMid), x: W / 2, topY: cardsTop + 70, align: 1)
    }

    // footer
    let footTop = cardsTop + cardH + 14
    let segs: [(String, Double)] = [("1м", 60), ("5м", 300), ("15м", 900)]
    let segW: CGFloat = 40, segH: CGFloat = 24
    roundFill(rectTL(pad, footTop, segW * 3, segH), 8, gray(1, 0.06))
    for (i, seg) in segs.enumerated() {
        let segRect = rectTL(pad + CGFloat(i) * segW, footTop, segW, segH)
        let active = abs(interval - seg.1) < 1
        if active { roundFill(segRect.insetBy(dx: 2, dy: 2), 6, gray(1, 0.13)) }
        text(attr(seg.0, 11, active ? .semibold : .regular, active ? textHi : textMid),
             x: segRect.midX, topY: footTop + 6, align: 1)
        hits.append(Hit(id: "iv\(Int(seg.1))", rect: segRect))
    }
    let pwrRect = rectTL(W - pad - 24, footTop, 24, 24)
    drawPower(ctx, pwrRect.insetBy(dx: 4, dy: 4), gray(1, 0.6))
    hits.append(Hit(id: "quit", rect: pwrRect))
    if let u = updated {
        text(attr("обновлено " + clockText(u), 10, .regular, textLo), x: W - pad - 32, topY: footTop + 7, align: 2)
    }

    // credit line (authorship + version + clickable GitHub), like the reference app
    let divY = H - 256
    ctx.setStrokeColor(cg(gray(1, 0.06))); ctx.setLineWidth(1)
    ctx.beginPath(); ctx.move(to: CGPoint(x: pad, y: divY)); ctx.addLine(to: CGPoint(x: W - pad, y: divY)); ctx.strokePath()
    let creditPre = attr("Claude Codex Limits \(APP_VERSION) · by \(APP_AUTHOR) · ", 9.5, .regular, gray(1, 0.32))
    let creditLink = attr("GitHub", 9.5, .semibold, NSColor(srgbRed: 0.42, green: 0.62, blue: 0.96, alpha: 0.95))
    let preW = lineWidth(CTLineCreateWithAttributedString(creditPre))
    let linkW = lineWidth(CTLineCreateWithAttributedString(creditLink))
    let creditX = (W - preW - linkW) / 2
    let creditTop: CGFloat = 265
    text(creditPre, x: creditX, topY: creditTop)
    text(creditLink, x: creditX + preW, topY: creditTop)
    hits.append(Hit(id: "open:\(REPO_URL)",
                    rect: CGRect(x: creditX + preW - 3, y: H - creditTop - 13, width: linkW + 6, height: 16)))

    return hits
}

// MARK: - Panel view + window

final class LimitsPanelView: NSView {
    var claude = LimitData(); var codex = LimitData()
    var interval: TimeInterval = 60
    var updated: Date?
    var hits: [Hit] = []
    var onInterval: ((TimeInterval) -> Void)?
    var onRefresh: (() -> Void)?
    var onQuit: (() -> Void)?
    var onOpenURL: ((String) -> Void)?
    override var isFlipped: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        hits = drawPanel(ctx, size: bounds.size, claude: claude, codex: codex, interval: interval, updated: updated)
    }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for h in hits where h.rect.contains(p) {
            if h.id == "refresh" { onRefresh?() }
            else if h.id == "quit" { onQuit?() }
            else if h.id.hasPrefix("iv"), let v = Double(h.id.dropFirst(2)) { onInterval?(v) }
            else if h.id.hasPrefix("open:") { onOpenURL?(String(h.id.dropFirst(5))) }
            return
        }
    }
}

final class PanelController {
    let panel: NSPanel
    let view: LimitsPanelView
    var monitor: Any?
    var onInterval: ((TimeInterval) -> Void)? { didSet { view.onInterval = onInterval } }
    var onRefresh: (() -> Void)? { didSet { view.onRefresh = onRefresh } }
    var onQuit: (() -> Void)? { didSet { view.onQuit = onQuit } }
    var onOpenURL: ((String) -> Void)? { didSet { view.onOpenURL = onOpenURL } }

    init() {
        let frame = NSRect(x: 0, y: 0, width: PANEL_W, height: PANEL_H)
        view = LimitsPanelView(frame: frame)
        view.wantsLayer = true
        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.contentView = view
    }

    var isVisible: Bool { panel.isVisible }

    func update(claude: LimitData, codex: LimitData, interval: TimeInterval, updated: Date?) {
        view.claude = claude; view.codex = codex; view.interval = interval; view.updated = updated
        if panel.isVisible { view.needsDisplay = true }
    }

    func show(below button: NSStatusBarButton) {
        if let win = button.window {
            let bf = button.frame
            let pt = win.convertPoint(toScreen: NSPoint(x: bf.midX, y: bf.minY))
            var origin = NSPoint(x: pt.x - PANEL_W / 2, y: pt.y - PANEL_H - 6)
            if let scr = win.screen ?? NSScreen.main {
                let v = scr.visibleFrame
                origin.x = max(v.minX + 8, min(origin.x, v.maxX - PANEL_W - 8))
                origin.y = max(v.minY + 8, origin.y)
            }
            panel.setFrameOrigin(origin)
        }
        view.needsDisplay = true
        panel.orderFrontRegardless()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hide()
        }
    }

    func hide() {
        panel.orderOut(nil)
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var interval: TimeInterval = UserDefaults.standard.double(forKey: "interval") > 0
        ? UserDefaults.standard.double(forKey: "interval") : 60
    var last: (LimitData, LimitData)?
    var panelCtrl: PanelController!

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "…"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        panelCtrl = PanelController()
        panelCtrl.onInterval = { [weak self] sec in self?.setInterval(sec) }
        panelCtrl.onRefresh = { [weak self] in self?.refreshNow() }
        panelCtrl.onQuit = { NSApp.terminate(nil) }
        panelCtrl.onOpenURL = { [weak self] url in
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
            self?.panelCtrl.hide()
        }

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(themeChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil)

        startTimer()
        refreshNow()
    }

    func startTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.refreshNow() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    @objc func themeChanged() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            if let (c, x) = self?.last { self?.render(c, x) }
        }
    }

    @objc func refreshNow() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var claude = fetchClaude()
            var codex = fetchCodex()
            applyCache(&claude, &codex)
            DispatchQueue.main.async { self?.render(claude, codex) }
        }
    }

    func isDark() -> Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    func render(_ claude: LimitData, _ codex: LimitData) {
        last = (claude, codex)
        var products: [(LimitData, String)] = []
        if claude.present { products.append((claude, "claude_128.png")) }
        if codex.present { products.append((codex, "codex_128.png")) }
        if let cgImg = renderStrip(products, dark: isDark(), s: 2), let btn = statusItem.button {
            let img = NSImage(cgImage: cgImg, size: NSSize(width: CGFloat(cgImg.width) / 2,
                                                           height: CGFloat(cgImg.height) / 2))
            img.isTemplate = false
            btn.image = img
            btn.title = ""
        }
        panelCtrl.update(claude: claude, codex: codex, interval: interval, updated: Date())
    }

    func setInterval(_ sec: TimeInterval) {
        interval = sec
        UserDefaults.standard.set(sec, forKey: "interval")
        startTimer()
        if let (c, x) = last { panelCtrl.update(claude: c, codex: x, interval: interval, updated: Date()) }
    }

    @objc func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showContextMenu(); return }
        guard let btn = statusItem.button else { return }
        if panelCtrl.isVisible { panelCtrl.hide() }
        else {
            if let (c, x) = last { panelCtrl.update(claude: c, codex: x, interval: interval, updated: Date()) }
            panelCtrl.show(below: btn)
            refreshNow()   // force fresh readings the moment the panel opens
        }
    }

    func showContextMenu() {
        let m = NSMenu()
        let r = m.addItem(withTitle: "Обновить", action: #selector(refreshNow), keyEquivalent: ""); r.target = self
        m.addItem(.separator())
        let li = m.addItem(withTitle: "Запускать при входе", action: #selector(toggleLogin), keyEquivalent: "")
        li.target = self; li.state = loginEnabled() ? .on : .off
        m.addItem(.separator())
        let q = m.addItem(withTitle: "Выйти", action: #selector(quit), keyEquivalent: "q"); q.target = self
        if let btn = statusItem.button {
            m.popUp(positioning: nil, at: NSPoint(x: 0, y: btn.bounds.height + 4), in: btn)
        }
    }

    @objc func toggleLogin() { setLoginEnabled(!loginEnabled()) }
    @objc func quit() { NSApp.terminate(nil) }
}

// MARK: - Single instance (flock) + launch

if CommandLine.arguments.contains("--preview") {
    var c = fetchClaude(); var x = fetchCodex(); applyCache(&c, &x)
    let cP = (c, "claude_128.png"), xP = (x, "codex_128.png")
    writePreview([cP, xP], dark: true,  to: "/tmp/limits_preview_dark.png")
    writePreview([cP, xP], dark: false, to: "/tmp/limits_preview_light.png")
    writePreview([cP], dark: true, to: "/tmp/limits_preview_claude.png")   // single-product look
    writePreview([xP], dark: true, to: "/tmp/limits_preview_codex.png")
    print("preview written"); exit(0)
}

if CommandLine.arguments.contains("--panel-preview") {
    var c = fetchClaude(); var x = fetchCodex(); applyCache(&c, &x)
    let s: CGFloat = 2
    func renderPanel(_ cl: LimitData, _ cx: LimitData, _ path: String) {
        guard let ctx = bitmapContext(Int(PANEL_W * s), Int(PANEL_H * s)) else { return }
        ctx.scaleBy(x: s, y: s)
        _ = drawPanel(ctx, size: CGSize(width: PANEL_W, height: PANEL_H),
                      claude: cl, codex: cx, interval: 60, updated: Date())
        guard let img = ctx.makeImage() else { return }
        let data = NSMutableData()
        if let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, img, nil)
            if CGImageDestinationFinalize(dest) { try? (data as Data).write(to: URL(fileURLWithPath: path)) }
        }
    }
    var xAbsent = x; xAbsent.present = false
    var cAbsent = c; cAbsent.present = false
    renderPanel(c, x, "/tmp/panel_preview.png")
    renderPanel(c, xAbsent, "/tmp/panel_claude_only.png")
    renderPanel(cAbsent, x, "/tmp/panel_codex_only.png")
    print("panel preview written"); exit(0)
}

let lockFD = open(LOCK_PATH, O_CREAT | O_RDWR, 0o644)
if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    // Another instance already owns the lock — exit quietly.
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
app.run()
