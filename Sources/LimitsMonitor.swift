// LimitsMonitor.swift
// Standalone macOS menu-bar app: shows remaining Claude Code + Codex usage limits
// as "session%(5h) / weekly%(7d)" with each brand icon to its left.
// No SwiftBar, no third-party deps — Foundation + AppKit + CoreText + ImageIO.

import Foundation
import AppKit
import CoreText
import ImageIO
import Darwin
import Security

// Dispatch before defaults, data-directory creation or production auth construction.
if CommandLine.arguments.contains("--auth-selftest") {
    runGitHubAuthSelfTests()
    exit(0)
}
if CommandLine.arguments.contains("--github-auth-store-helper") {
    exit(githubAuthNativeStoreHelper())
}

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

// Set only by an isolated selftest before drawing; nil preserves production I/O.
private var isolatedSelfTestAssets: String? = nil

func assetPath(_ name: String) -> String {
    if let res = Bundle.main.resourcePath {
        let p = res + "/" + name
        if FileManager.default.fileExists(atPath: p) { return p }
    }
    if let fixtures = isolatedSelfTestAssets { return fixtures + "/" + name }
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

func http(_ url: String, method: String, headers: [String: String], body: Data?, timeout: Double = 15) -> (status: Int, data: Data?, err: String?) {
    let r = requestHTTP(url, method: method, headers: headers, body: body, timeout: timeout)
    return (r.status, r.data, r.err)
}

private final class SyncNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private func requestHTTP(_ url: String, method: String, headers: [String: String], body: Data?,
                         timeout: Double, noRedirects: Bool = false) -> SyncHTTPResult {
    guard let u = URL(string: url) else { return (0, nil, "bad url", [:]) }
    var r = URLRequest(url: u, timeoutInterval: timeout)
    r.httpMethod = method
    for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
    r.httpBody = body
    let sem = DispatchSemaphore(value: 0)
    var st = 0; var dat: Data?; var er: String?; var responseHeaders: [String: String] = [:]
    let session = noRedirects ? URLSession(configuration: .ephemeral, delegate: SyncNoRedirects(), delegateQueue: nil) : URLSession.shared
    defer { if noRedirects { session.invalidateAndCancel() } }
    let task = session.dataTask(with: r) { d, resp, e in
        if let e = e { er = e.localizedDescription }
        if let h = resp as? HTTPURLResponse {
            st = h.statusCode
            for (key, value) in h.allHeaderFields { responseHeaders[String(describing: key).lowercased()] = String(describing: value) }
        }
        dat = d
        sem.signal()
    }
    task.resume()
    if sem.wait(timeout: .now() + timeout + 5) == .timedOut { task.cancel(); return (0, nil, "timeout", [:]) }
    return (st, dat, er, responseHeaders)
}

// MARK: - Model

/// Authentication state of a product (only Claude Code uses anything but `.ok`).
///   • ok            — signed in, data is (or can be) live
///   • loggedOut     — no Claude Code CLI login: keychain item absent, or present
///                     but without a `claudeAiOauth` block (e.g. only the desktop app
///                     is signed in). Recoverable by signing into the CLI.
///   • expired       — a saved CLI login whose token expired and could not be refreshed.
///   • keychainError — a genuine keychain read failure (errSec other than 0 / 44).
enum AuthState { case ok, loggedOut, expired, keychainError }

/// A weekly limit scoped to one model (Anthropic's `limits[].kind == "weekly_scoped"`),
/// e.g. Fable's own 7-day allowance, which can run out while the overall weekly still has
/// room. `name` is the backend's own `scope.model.display_name`, so a future model shows up
/// correctly without a code change.
struct ScopedLimit {
    var name: String
    var percent: Double
    var reset: Date?
    var severity: String?      // backend's own "normal" | "warning" | "critical"
}

struct LimitData {
    var session: Double?
    var weekly: Double?
    var sessionReset: Date?
    var weeklyReset: Date?
    var scoped: ScopedLimit?   // Claude: the binding per-model weekly limit, when the API reports one
    var plan: String?
    var resetCredits: Int?     // Codex "reset banking" — banked rate-limit resets available
    var asOf: Date?
    var error: String?
    var stale = false
    var fromCache = false
    var apiFresh = false      // true only for a successful live usage response
    var present = true         // false → product not set up on this Mac (hide its row/card)
    // Transient presentation state of the last request, never serialized with a snapshot.
    var pollFailed = false
    var nextPollAt: Date?
    var auth: AuthState = .ok  // Claude Code sign-in state (drives the "how to fix" card)
}

// A missing preference keeps existing installations monitoring both products.
func productEnabled(_ product: String, defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: "monitor_" + product) as? Bool ?? true
}
func selectedLimits(_ data: LimitData, product: String) -> LimitData {
    productEnabled(product) ? data : LimitData(present: false)
}
func monitoringPaused() -> Bool { !productEnabled("claude") && !productEnabled("codex") }

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

/// Key under which the fingerprint of an already-rejected refresh token is remembered.
let DEAD_REFRESH_KEY = "deadRefresh"

/// A stable, one-way fingerprint of a token. `String.hashValue` is seeded per process and
/// would differ every launch; this (FNV-1a) is the same every time. It only ever answers
/// "is this the same token the server already refused?" — it is never stored anywhere it
/// could be read back as a credential, and never leaves the machine.
func fnv64(_ s: String) -> UInt64 {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
    return h
}
func tokenFingerprint(_ s: String) -> String { String(fnv64(s), radix: 16) }

func fetchClaude() -> LimitData {
    guard productEnabled("claude") else { return LimitData(present: false) }
    var d = LimitData()
    let kc = shell("/usr/bin/security", ["find-generic-password", "-s", KC_SERVICE, "-w"])
    // State (1) "not signed in", half A: the keychain item is absent (errSec 44 =
    // errSecItemNotFound). Keep the card visible with a "sign in" prompt rather than
    // hiding the product — the user still wants Claude Code limits, they just need to log in.
    if kc.code == 44 { d.auth = .loggedOut; return d }
    // State (3) a genuine keychain read failure (any errSec other than 0 / 44).
    guard kc.code == 0,
          let data = kc.out.data(using: .utf8),
          var creds = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { d.auth = .keychainError; d.error = "keychain read failed (errSec \(kc.code))"; return d }
    // State (1) "not signed in", half B: the item exists but has NO Claude Code login
    // block (only e.g. mcpOAuth, or credentials written by the desktop app, which the
    // monitor can't use). Same user-facing state as a missing item: "sign in via the CLI".
    guard var oauth = creds["claudeAiOauth"] as? [String: Any] else { d.auth = .loggedOut; return d }

    d.plan = oauth["subscriptionType"] as? String
    if let tier = oauth["rateLimitTier"] as? String { UserDefaults.standard.set(tier, forKey: "claudeTier") }
    var at = oauth["accessToken"] as? String ?? ""
    let exp = (oauth["expiresAt"] as? Double) ?? 0
    let nowMs = Date().timeIntervalSince1970 * 1000

    // A token that expires in under two minutes is treated as spent — a reading started now
    // could outlive it. `usable` is the honest question: is there still something to ask with
    // if the refresh doesn't work out?
    if at.isEmpty || exp - nowMs < 120_000 {
        let usable = !at.isEmpty && exp > nowMs
        let rt = (oauth["refreshToken"] as? String) ?? ""
        if rt.isEmpty {
            if !usable { d.auth = .expired; d.error = "no refresh token"; return d }
        } else {
            let fp = tokenFingerprint(rt)
            // A refresh token the server has already refused never recovers. Asking again every
            // five minutes is how a dead login earned a 429 after one night, so once refused we
            // stop asking. A fresh CLI login rewrites the keychain, which changes the
            // fingerprint and re-arms the check on its own — no manual reset needed.
            var refused = UserDefaults.standard.string(forKey: DEAD_REFRESH_KEY) == fp
            if !refused {
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
                    UserDefaults.standard.removeObject(forKey: DEAD_REFRESH_KEY)
                } else {
                    // `invalid_grant` is the server saying this login is finished — unlike a
                    // timeout or a 5xx, which is worth retrying on the next tick.
                    let err = resp.data
                        .flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }?["error"] as? String
                    if err == "invalid_grant" || resp.status == 400 || resp.status == 401 {
                        UserDefaults.standard.set(fp, forKey: DEAD_REFRESH_KEY)
                        refused = true
                    } else if !usable {
                        d.auth = .expired; d.error = "refresh failed (HTTP \(resp.status))"; return d
                    }
                }
            }
            // Nothing left to ask with. Say the login expired instead of quietly serving
            // yesterday's numbers behind a grey card — and don't spend the call on a token
            // that is already known to be dead.
            if refused, !usable { d.auth = .expired; d.error = "sign-in expired"; return d }
        }
    }

    let resp = http("https://api.anthropic.com/api/oauth/usage", method: "GET",
                    headers: ["Authorization": "Bearer \(at)", "User-Agent": UA,
                              "Accept": "application/json",
                              "anthropic-beta": "oauth-2025-04-20",
                              "anthropic-version": "2023-06-01"], body: nil)
    guard resp.status == 200, let ud = resp.data,
          let j = (try? JSONSerialization.jsonObject(with: ud)) as? [String: Any]
    else {
        // 401 here means the token we just refreshed (or were still holding) isn't accepted —
        // that's a dead sign-in, not a hiccup, and the card should say so.
        if resp.status == 401 { d.auth = .expired }
        d.error = "usage HTTP \(resp.status)"
        return d
    }

    if let fh = j["five_hour"] as? [String: Any] {
        d.session = fh["utilization"] as? Double
        if let rs = fh["resets_at"] as? String { d.sessionReset = parseISOmicroOffset(rs) }
    }
    if let sd = j["seven_day"] as? [String: Any] {
        d.weekly = sd["utilization"] as? Double
        if let rs = sd["resets_at"] as? String { d.weeklyReset = parseISOmicroOffset(rs) }
    }

    // `limits[]` is the newer, structured view of the same quotas. It carries something the
    // flat fields can't express: per-model weekly limits (`weekly_scoped`), which is how a
    // model like Fable can sit at 100% while the overall weekly is still at 84%. The old
    // per-model fields (`seven_day_opus`/`seven_day_sonnet`) now come back null, so this
    // array is the only source for that. Also used to backfill session/weekly if Anthropic
    // ever drops the flat fields the way they dropped the per-model ones.
    if let limits = j["limits"] as? [[String: Any]] {
        func pct(_ e: [String: Any]) -> Double? {
            (e["percent"] as? Double) ?? (e["percent"] as? Int).map(Double.init)
        }
        func reset(_ e: [String: Any]) -> Date? {
            (e["resets_at"] as? String).flatMap(parseISOmicroOffset)
        }
        for e in limits where e["kind"] as? String == "session" {
            if d.session == nil { d.session = pct(e) }
            if d.sessionReset == nil { d.sessionReset = reset(e) }
        }
        for e in limits where e["kind"] as? String == "weekly_all" {
            if d.weekly == nil { d.weekly = pct(e) }
            if d.weeklyReset == nil { d.weeklyReset = reset(e) }
        }
        // Pick the one that actually constrains you: the backend's own `is_active` flag wins,
        // otherwise the highest percentage. (There may be several scoped limits in play.)
        let scopedEntries = limits.filter { $0["kind"] as? String == "weekly_scoped" }
        let chosen = scopedEntries.first { $0["is_active"] as? Bool == true }
            ?? scopedEntries.max { (pct($0) ?? 0) < (pct($1) ?? 0) }
        if let e = chosen,
           let name = ((e["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String,
           let p = pct(e) {
            d.scoped = ScopedLimit(name: name, percent: p, reset: reset(e),
                                   severity: e["severity"] as? String)
            // Remembered so Settings can name the option ("Fable") on the next launch too.
            UserDefaults.standard.set(name, forKey: "scopedName")
        }
    }
    d.asOf = Date(); d.apiFresh = true
    return d
}

// MARK: - Codex

/// Assign a Codex usage window to Session or Week by its DURATION — the ~5-hour window
/// feeds Session, the ~7-day window feeds Week — so the labels stay correct no matter
/// which slot (primary/secondary) the backend put it in, or if it returned only one.
/// Falls back to the positional guess when the duration field is absent. Handles both
/// shapes: live (`limit_window_seconds`, `reset_at`) and rollout (`window_minutes`, `resets_at`).
func codexApplyWindow(_ win: [String: Any], _ d: inout LimitData, positionalWeekly: Bool) {
    let used = win["used_percent"] as? Double
    let resetTs = (win["reset_at"] as? Double) ?? (win["resets_at"] as? Double)
    let reset = resetTs.map { Date(timeIntervalSince1970: $0) }
    let durSec = (win["limit_window_seconds"] as? Double) ?? (win["window_minutes"] as? Double).map { $0 * 60 }
    let isWeekly = durSec.map { $0 >= 2 * 86400 } ?? positionalWeekly   // ≥ 2 days ⇒ the weekly window
    if isWeekly {
        if let u = used { d.weekly = u }
        if let r = reset { d.weeklyReset = r }
    } else {
        if let u = used { d.session = u }
        if let r = reset { d.sessionReset = r }
    }
}

func codexFromRollout() -> LimitData {
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
    if let p = rl["primary"] as? [String: Any] { codexApplyWindow(p, &d, positionalWeekly: false) }
    if let s = rl["secondary"] as? [String: Any] { codexApplyWindow(s, &d, positionalWeekly: true) }
    d.plan = (rl["plan_type"] as? String) ?? lastPlan
    d.asOf = parseISOmillisZ(bestTs)
    if let a = d.asOf, Date().timeIntervalSince(a) > 2 * 3600 { d.stale = true }
    return d
}

// MARK: - Codex live usage (same backend the Codex CLI uses)

let CODEX_CLIENT_ID = "app_EMoamEEZ73f0CkXaXp7hrann"   // openai/codex login::CLIENT_ID
let CODEX_AUTH_PATH = HOME + "/.codex/auth.json"

func jwtExp(_ jwt: String) -> Double? {
    let parts = jwt.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var p = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while p.count % 4 != 0 { p += "=" }
    guard let data = Data(base64Encoded: p),
          let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    return j["exp"] as? Double
}

/// Reads a valid Codex access token from ~/.codex/auth.json, refreshing it via
/// the official OpenAI token endpoint (and persisting back) if it has expired.
func codexAccessToken() -> (token: String, account: String)? {
    guard let data = FileManager.default.contents(atPath: CODEX_AUTH_PATH),
          var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          var tokens = root["tokens"] as? [String: Any],
          let acc = tokens["account_id"] as? String,
          let at = tokens["access_token"] as? String else { return nil }

    if let exp = jwtExp(at), exp > Date().timeIntervalSince1970 + 60 {
        return (at, acc)                         // still valid
    }
    guard let rt = tokens["refresh_token"] as? String, !rt.isEmpty else { return nil }
    let body = try? JSONSerialization.data(withJSONObject: [
        "client_id": CODEX_CLIENT_ID, "grant_type": "refresh_token", "refresh_token": rt])
    let resp = http("https://auth.openai.com/oauth/token", method: "POST",
                    headers: ["Content-Type": "application/json", "Accept": "application/json",
                              "User-Agent": "codex_cli_rs/0.20.0 (Mac OS 26.0.0; arm64) Apple_Terminal"],
                    body: body)
    guard resp.status == 200, let rd = resp.data,
          let tok = (try? JSONSerialization.jsonObject(with: rd)) as? [String: Any],
          let newAt = tok["access_token"] as? String else { return nil }
    tokens["access_token"] = newAt
    if let v = tok["id_token"] as? String { tokens["id_token"] = v }
    if let v = tok["refresh_token"] as? String { tokens["refresh_token"] = v }
    root["tokens"] = tokens
    root["last_refresh"] = ISO8601DateFormatter().string(from: Date())
    if let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted]) {
        try? out.write(to: URL(fileURLWithPath: CODEX_AUTH_PATH))
    }
    return (newAt, acc)
}

/// Live Codex usage from `GET /backend-api/wham/usage` (nil on any failure → fall back to local).
func codexUsageLive() -> LimitData? {
    guard let (at, acc) = codexAccessToken() else { return nil }
    let resp = http("https://chatgpt.com/backend-api/wham/usage", method: "GET",
                    headers: ["Authorization": "Bearer \(at)", "chatgpt-account-id": acc,
                              "User-Agent": "codex_cli_rs/0.20.0 (Mac OS 26.0.0; arm64) Apple_Terminal",
                              "originator": "codex_cli_rs", "Accept": "application/json"], body: nil)
    guard resp.status == 200, let rd = resp.data,
          let obj = (try? JSONSerialization.jsonObject(with: rd)) as? [String: Any],
          let rl = obj["rate_limit"] as? [String: Any] else { return nil }
    var d = LimitData(); d.present = true
    if let p = rl["primary_window"] as? [String: Any] { codexApplyWindow(p, &d, positionalWeekly: false) }
    if let s = rl["secondary_window"] as? [String: Any] { codexApplyWindow(s, &d, positionalWeekly: true) }
    d.plan = obj["plan_type"] as? String
    if let pl = d.plan { UserDefaults.standard.set(pl, forKey: "codexPlan") }
    if let rc = (obj["rate_limit_reset_credits"] as? [String: Any])?["available_count"] as? Int { d.resetCredits = rc }
    d.asOf = Date(); d.apiFresh = true
    return d
}

func loadCodexCache() -> LimitData? {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: CACHE_PATH)),
          let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let cm = j["codex"] as? [String: Any] else { return nil }
    return dict2ld(cm)
}

/// Codex limits. `live` (panel-open / manual refresh) hits the ChatGPT backend;
/// otherwise uses the freshest of the local rollout files and the last cached reading.
func fetchCodex(live: Bool) -> LimitData {
    guard productEnabled("codex") else { return LimitData(present: false) }
    let rollout = codexFromRollout()
    if !rollout.present { return rollout }              // Codex not set up
    if live, let liveD = codexUsageLive() { return liveD }
    var best = rollout
    if let cached = loadCodexCache() {
        let b = best.asOf?.timeIntervalSince1970 ?? 0
        let c = cached.asOf?.timeIntervalSince1970 ?? 0
        if c > b { best = cached; best.present = true; best.fromCache = false }
    }
    if let a = best.asOf, Date().timeIntervalSince(a) > 2 * 3600 { best.stale = true }
    return best
}

// MARK: - Cache

func ld2dict(_ d: LimitData) -> [String: Any] {
    var m = [String: Any]()
    if let v = d.session { m["session"] = v }
    if let v = d.weekly { m["weekly"] = v }
    if let v = d.sessionReset { m["sReset"] = v.timeIntervalSince1970 }
    if let v = d.weeklyReset { m["wReset"] = v.timeIntervalSince1970 }
    if let v = d.plan { m["plan"] = v }
    if let v = d.resetCredits { m["resetCredits"] = v }
    if let s = d.scoped {
        var sm: [String: Any] = ["name": s.name, "percent": s.percent]
        if let r = s.reset { sm["reset"] = r.timeIntervalSince1970 }
        if let sev = s.severity { sm["severity"] = sev }
        m["scoped"] = sm
    }
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
    d.resetCredits = m["resetCredits"] as? Int
    if let sm = m["scoped"] as? [String: Any],
       let name = sm["name"] as? String, let p = sm["percent"] as? Double {
        d.scoped = ScopedLimit(name: name, percent: p,
                               reset: (sm["reset"] as? Double).map { Date(timeIntervalSince1970: $0) },
                               severity: sm["severity"] as? String)
    }
    if let v = m["asOf"] as? Double { d.asOf = Date(timeIntervalSince1970: v) }
    d.fromCache = true
    return d
}

func applyCache(_ claude: inout LimitData, _ codex: inout LimitData) {
    var cache: [String: Any] = [:]
    if let cd = try? Data(contentsOf: URL(fileURLWithPath: CACHE_PATH)),
       let cj = (try? JSONSerialization.jsonObject(with: cd)) as? [String: Any] { cache = cj }
    if claude.present, claude.error != nil, let cm = cache["claude"] as? [String: Any] {
        // Restore last-known numbers behind the error flag — but keep the auth state
        // (dict2ld resets it to .ok) so an "expired" card still reads as expired.
        let e = claude.error; let a = claude.auth; claude = dict2ld(cm); claude.error = e; claude.auth = a
    }
    if codex.present, codex.error != nil, let cm = cache["codex"] as? [String: Any] {
        let e = codex.error; codex = dict2ld(cm); codex.error = e
    }
    // Only persist genuinely-good live readings. A "not signed in" / expired Claude has no
    // fresh data, so it must never overwrite the cache with blanks.
    if claude.present, claude.error == nil, claude.auth == .ok { cache["claude"] = ld2dict(claude) }
    if codex.present, codex.error == nil { cache["codex"] = ld2dict(codex) }
    if let outD = try? JSONSerialization.data(withJSONObject: cache) {
        try? outD.write(to: URL(fileURLWithPath: CACHE_PATH))
    }
}

// MARK: - Advanced mode: data layer (history samples, local usage logs, pace, money)
//
// The API only ever answers "how much of each window is used RIGHT NOW". Everything the
// Advanced view adds — pace against a linear plan, when a window runs out, per-day and
// per-model consumption, what the same tokens would cost on the API — comes from two local
// sources this layer maintains:
//   1. `UsageHistory`  — one utilization sample per product per poll, appended to a JSONL
//      file and kept for 35 days. Feeds the "recent pace" figure and, later, real curves.
//   2. `UsageLogs`     — an incremental index over the CLIs' own transcripts: Claude Code's
//      `~/.claude/projects/*/*.jsonl` and Codex's `~/.codex/sessions/**/rollout-*.jsonl`,
//      which carry every turn's token counts and model. Files are append-only, so each
//      rescan reads only the bytes added since the last mark.

let HISTORY_PATH = DATA_DIR + "/history.jsonl"
let USAGE_INDEX_PATH = DATA_DIR + "/usage-index.json"
let HISTORY_KEEP_DAYS: Double = 35

func advancedEnabled() -> Bool { UserDefaults.standard.bool(forKey: "advanced") }

/// Local-calendar day key ("2026-09-24") — the day boundaries the user actually lives in.
let dayKeyFormatter: DateFormatter = {
    let f = DateFormatter(); f.calendar = Calendar.current; f.timeZone = TimeZone.current
    f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f
}()
func dayKey(_ d: Date) -> String { dayKeyFormatter.string(from: d) }

struct UsageSample {
    let t: Double                 // epoch seconds
    let product: String           // "claude" | "codex"
    let session: Double?, weekly: Double?, scoped: Double?
    let scopedName: String?
    let sessionReset: Double?, weeklyReset: Double?
}

final class UsageHistory {
    static let shared = UsageHistory()
    private let q = DispatchQueue(label: "ccl.history")
    private var all: [UsageSample] = []

    /// Read the file once at launch; drop anything older than the retention window and
    /// rewrite the file compacted so it can't grow without bound.
    func load() {
        q.sync {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: HISTORY_PATH)) else { return }
            let cutoff = Date().timeIntervalSince1970 - HISTORY_KEEP_DAYS * 86400
            var out: [UsageSample] = []
            for line in data.split(separator: 0x0A) {
                guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      let t = o["t"] as? Double, t >= cutoff, let p = o["p"] as? String else { continue }
                out.append(UsageSample(t: t, product: p, session: o["s"] as? Double, weekly: o["w"] as? Double,
                                       scoped: o["m"] as? Double, scopedName: o["mn"] as? String,
                                       sessionReset: o["sr"] as? Double, weeklyReset: o["wr"] as? Double))
            }
            all = out
            let compact = out.map { UsageHistory.line($0) }.joined()
            try? compact.data(using: .utf8)?.write(to: URL(fileURLWithPath: HISTORY_PATH))
        }
    }

    private static func line(_ s: UsageSample) -> String {
        var o: [String: Any] = ["t": s.t, "p": s.product]
        if let v = s.session { o["s"] = v }; if let v = s.weekly { o["w"] = v }
        if let v = s.scoped { o["m"] = v }; if let v = s.scopedName { o["mn"] = v }
        if let v = s.sessionReset { o["sr"] = v }; if let v = s.weeklyReset { o["wr"] = v }
        guard let d = try? JSONSerialization.data(withJSONObject: o), let str = String(data: d, encoding: .utf8) else { return "" }
        return str + "\n"
    }

    /// Record one live reading. Cached/errored/expired readings are skipped — a sample must
    /// be a real observation of the backend, or the pace math would see a flat line.
    func record(_ d: LimitData, product: String) {
        guard productEnabled(product), d.present, d.error == nil, d.auth == .ok, !d.fromCache, d.session != nil || d.weekly != nil else { return }
        guard !d.pollFailed, let at = d.asOf, at.timeIntervalSince1970.isFinite, at <= Date() else { return }
        let s = UsageSample(t: at.timeIntervalSince1970, product: product, session: d.session, weekly: d.weekly,
                            scoped: d.scoped?.percent, scopedName: d.scoped?.name,
                            sessionReset: d.sessionReset?.timeIntervalSince1970, weeklyReset: d.weeklyReset?.timeIntervalSince1970)
        q.async {
            guard productEnabled(product), self.all.last(where: { $0.product == product }).map({ $0.t < s.t }) ?? true else { return }
            self.all.append(s)
            let str = UsageHistory.line(s)
            if let fh = FileHandle(forWritingAtPath: HISTORY_PATH) {
                fh.seekToEndOfFile(); fh.write(str.data(using: .utf8)!); fh.closeFile()
            } else {
                try? str.data(using: .utf8)?.write(to: URL(fileURLWithPath: HISTORY_PATH))
            }
        }
    }

    /// Docs screenshots only: in-memory samples, nothing written.
    func useForPreview(_ s: [UsageSample]) { q.sync { all = s } }

    func samples(_ product: String, since: Date) -> [UsageSample] {
        guard productEnabled(product) else { return [] }
        let c = since.timeIntervalSince1970
        return q.sync { all.filter { $0.product == product && $0.t >= c } }
    }

    /// Pace over the last `minutes` for one metric, in % per hour — the "current" pace as
    /// opposed to the average since the window opened. Nil until there are two samples that
    /// far apart inside the same window (a reset in between would read as a huge negative).
    func recentRate(_ product: String, metric: (UsageSample) -> Double?, minutes: Double, now: Date = Date()) -> Double? {
        let pts = samples(product, since: now.addingTimeInterval(-minutes * 60)).filter { $0.t <= now.timeIntervalSince1970 }.compactMap { s in metric(s).map { (s.t, $0) } }
        guard let first = pts.first, let last = pts.last, last.0 - first.0 >= 600 else { return nil }
        let dv = last.1 - first.1
        if dv < 0 { return nil }                                 // a reset happened inside the span
        return dv / ((last.0 - first.0) / 3600)
    }
}

// ---- Local usage logs → per-day, per-model token counts ----------------------------------

/// Ignore an overflowing contribution, including when combining a previously cached total.
private func usageSum(_ a: Int, _ b: Int) -> Int {
    let (sum, overflow) = a.addingReportingOverflow(b)
    return min(overflow ? a : sum, 1_000_000_000_000_000)
}

struct DayModelUsage: Codable {
    var input = 0, output = 0, cacheRead = 0, cacheWrite5m = 0, cacheWrite1h = 0, turns = 0
    mutating func add(_ o: DayModelUsage) {
        input = usageSum(input, o.input); output = usageSum(output, o.output); cacheRead = usageSum(cacheRead, o.cacheRead)
        cacheWrite5m = usageSum(cacheWrite5m, o.cacheWrite5m); cacheWrite1h = usageSum(cacheWrite1h, o.cacheWrite1h); turns = usageSum(turns, o.turns)
    }
    var totalTokens: Int { [input, output, cacheRead, cacheWrite5m, cacheWrite1h].reduce(0, usageSum) }
}

struct FileMark: Codable { var size: Int; var lastId: String?; var model: String? }

struct UsageIndex: Codable {
    var activity: [String: [Double]]? = nil  // optional for compatibility with existing indexes
    var files: [String: FileMark] = [:]
    /// product → day → model → usage
    var days: [String: [String: [String: DayModelUsage]]] = [:]
    /// day → hashes of Claude message ids already counted. A transcript repeats a message
    /// (same id, same usage) far from its first copy after a resume or compaction, so the
    /// check has to reach across the whole day, not just the previous line.
    var seen: [String: [UInt64]] = [:]
    mutating func add(_ product: String, _ day: String, _ model: String, _ u: DayModelUsage) {
        var cur = days[product, default: [:]][day, default: [:]][model, default: DayModelUsage()]
        cur.add(u)
        days[product, default: [:]][day, default: [:]][model] = cur
    }
}

final class UsageLogs {
    static let shared = UsageLogs()
    private let lock = NSLock()
    private var index = UsageIndex()
    private var scanning = false
    private(set) var lastScan: Date?

    func snapshot() -> UsageIndex { lock.lock(); defer { lock.unlock() }; return index }
    /// Docs screenshots only: an in-memory index that never touches the file on disk.
    func useForPreview(_ ix: UsageIndex) { lock.lock(); index = ix; lock.unlock() }

    func load() {
        if let d = try? Data(contentsOf: URL(fileURLWithPath: USAGE_INDEX_PATH)),
           let ix = try? JSONDecoder().decode(UsageIndex.self, from: d) {
            lock.lock(); index = ix; lock.unlock()
        }
    }

    /// Same as `scanAsync`, on the calling thread — for command-line hooks with no run loop.
    @discardableResult
    func scanSync(persist: Bool = true) -> Bool {
        lock.lock(); var ix = index; lock.unlock()
        let changed = UsageLogs.scan(&ix)
        lock.lock(); index = ix; lastScan = Date(); lock.unlock()
        if persist && changed, let d = try? JSONEncoder().encode(ix) { try? d.write(to: URL(fileURLWithPath: USAGE_INDEX_PATH)) }
        return changed
    }

    /// Completion always runs on main; an already-running scan reports no new change.
    func scanAsync(done: ((Bool) -> Void)? = nil) {
        lock.lock()
        if scanning { lock.unlock(); DispatchQueue.main.async { done?(false) }; return }
        scanning = true
        var ix = index
        lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            let changed = UsageLogs.scan(&ix)
            // Forget days beyond the retention window so the index can't grow forever.
            let cutoff = dayKey(Date().addingTimeInterval(-45 * 86400))
            for p in ix.days.keys { ix.days[p] = ix.days[p]?.filter { $0.key >= cutoff } }
            ix.seen = ix.seen.filter { $0.key >= cutoff }
            self.lock.lock(); self.index = ix; self.scanning = false; self.lastScan = Date(); self.lock.unlock()
            if changed, let d = try? JSONEncoder().encode(ix) { try? d.write(to: URL(fileURLWithPath: USAGE_INDEX_PATH)) }
            DispatchQueue.main.async { done?(changed) }
        }
    }

    static func scan(_ ix: inout UsageIndex, home: String = HOME,
                     isEnabled: (String) -> Bool = { productEnabled($0) }) -> Bool {
        var changed = false
        var seen: [String: Set<UInt64>] = ix.seen.mapValues { Set($0) }
        defer { ix.seen = seen.mapValues { Array($0) } }
        let fm = FileManager.default
        let cutoff = Date().addingTimeInterval(-45 * 86400)
        func recent(_ path: String) -> Bool {
            ((try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date).map { $0 >= cutoff } ?? false
        }
        // Claude Code: ~/.claude/projects/<project>/<session>.jsonl — PLUS the subagent
        // transcripts under <project>/<session>/subagents/agent-*.jsonl. Subagents are where
        // a different model often runs (an Opus reviewer under a Fable session), and they
        // burn the same quota; skipping them hid a whole model from the per-model bars.
        let cRoot = home + "/.claude/projects"
        if isEnabled("claude"), let e = fm.enumerator(atPath: cRoot) {
            while let rel = e.nextObject() as? String {
                guard isEnabled("claude") else { break }
                guard rel.hasSuffix(".jsonl") else { continue }
                let path = cRoot + "/" + rel
                if recent(path), scanFile(path, product: "claude", &ix, &seen) { changed = true }
            }
        }
        // Codex: ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl
        let xRoot = home + "/.codex/sessions"
        if isEnabled("codex"), let e = fm.enumerator(atPath: xRoot) {
            while let rel = e.nextObject() as? String {
                guard isEnabled("codex") else { break }
                guard rel.hasSuffix(".jsonl"), rel.contains("rollout-") else { continue }
                let path = xRoot + "/" + rel
                if recent(path), scanFile(path, product: "codex", &ix, &seen) { changed = true }
            }
        }
        return changed
    }

    /// Read whatever was appended since the last mark; parse only the lines that matter.
    /// Files are tens of MB, so the hot path is a C `memmem` for the needle, then a parse
    /// of just the enclosing line — not a per-line split and search.
    private static func scanFile(_ path: String, product: String, _ ix: inout UsageIndex, _ seen: inout [String: Set<UInt64>]) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int else { return false }
        var mark = ix.files[path] ?? FileMark(size: 0)
        if size < mark.size { mark = FileMark(size: 0) }               // truncated/rewritten → start over
        guard size > mark.size, let fh = FileHandle(forReadingAtPath: path) else { return false }
        fh.seek(toFileOffset: UInt64(mark.size))
        let data = fh.readDataToEndOfFile(); fh.closeFile()
        // Only consume complete lines — the CLI may be mid-write on the last one.
        var end = data.count
        if data.last != 0x0A { end = data.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0 }
        guard end > 0 else { return false }
        let bytes = [UInt8](data.prefix(end))
        var lastId = mark.lastId, model = mark.model
        let needles: [(String, Bool)] = product == "claude" ? [("\"usage\"", false)] : [("\"token_count\"", false), ("\"turn_context\"", true)]
        // Collect every needle hit as (offset, isContext), then walk them in file order so a
        // Codex turn_context (which names the model) is applied before the token_count it precedes.
        var hits: [(Int, Bool)] = []
        bytes.withUnsafeBufferPointer { buf in
            for (needle, isCtx) in needles {
                let n = Array(needle.utf8)
                var pos = 0
                while pos < buf.count, let found = memmem(buf.baseAddress! + pos, buf.count - pos, n, n.count) {
                    let off = UnsafeRawPointer(found) - UnsafeRawPointer(buf.baseAddress!)
                    hits.append((off, isCtx)); pos = off + n.count
                }
            }
        }
        hits.sort { $0.0 < $1.0 }
        var lineEndSeen = -1                                             // skip a second hit inside the same line
        for (off, isCtx) in hits {
            if off < lineEndSeen { continue }
            var ls = off; while ls > 0 && bytes[ls - 1] != 0x0A { ls -= 1 }
            var le = off; while le < bytes.count && bytes[le] != 0x0A { le += 1 }
            lineEndSeen = le
            let line = Data(bytes[ls..<le])
            guard let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            if isCtx {
                if let m = (o["payload"] as? [String: Any])?["model"] as? String { model = m }
                continue
            }
            guard let ts = o["timestamp"] as? String, let when = parseISOmillisZ(ts) ?? parseISOmicroOffset(ts) else { continue }
            var u = DayModelUsage(); var m = model ?? "?"
            if product == "claude" {
                guard o["type"] as? String == "assistant", let msg = o["message"] as? [String: Any],
                      let usage = msg["usage"] as? [String: Any] else { continue }
                // A message with several content blocks is written as several lines that
                // repeat the same id and the same usage — count each message once.
                let id = msg["id"] as? String
                if id != nil, id == lastId { continue }
                lastId = id
                if let id = id {
                    let day = dayKey(when), h = fnv64(id)
                    if seen[day, default: []].contains(h) { continue }
                    seen[day, default: []].insert(h)
                }
                m = msg["model"] as? String ?? "?"
                if m == "<synthetic>" { continue }
                u.input = usage["input_tokens"] as? Int ?? 0; u.output = usage["output_tokens"] as? Int ?? 0
                u.cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
                if let cc = usage["cache_creation"] as? [String: Any] {
                    u.cacheWrite5m = cc["ephemeral_5m_input_tokens"] as? Int ?? 0
                    u.cacheWrite1h = cc["ephemeral_1h_input_tokens"] as? Int ?? 0
                } else { u.cacheWrite5m = usage["cache_creation_input_tokens"] as? Int ?? 0 }
            } else {
                guard let p = o["payload"] as? [String: Any], p["type"] as? String == "token_count",
                      let lu = (p["info"] as? [String: Any])?["last_token_usage"] as? [String: Any] else { continue }
                // OpenAI's input_tokens INCLUDES the cached part — split it out for pricing.
                let inp = lu["input_tokens"] as? Int ?? 0, cached = lu["cached_input_tokens"] as? Int ?? 0
                u.input = max(0, inp - cached); u.cacheRead = cached
                u.cacheWrite5m = lu["cache_write_input_tokens"] as? Int ?? 0
                u.output = lu["output_tokens"] as? Int ?? 0        // reasoning tokens are included in output_tokens
            }
            u.turns = 1
            ix.add(product, dayKey(when), m, u)
            let timestamp = when.timeIntervalSince1970, now = Date().timeIntervalSince1970
            if u.totalTokens > 0, timestamp >= now - 900, timestamp <= now {
                var recent = Set((ix.activity?[product] ?? []).filter { $0 >= now - 900 && $0 <= now })
                recent.insert(timestamp)
                if ix.activity == nil { ix.activity = [:] }
                ix.activity?[product] = Array(recent.sorted().suffix(128))
            }
        }
        ix.files[path] = FileMark(size: mark.size + end, lastId: lastId, model: model)
        return true
    }
}

// ---- Prices & money -----------------------------------------------------------------------

/// USD per 1M tokens. Cache-write prices are per the provider's 5-minute tier; Anthropic's
/// 1-hour writes are billed at 2× input and handled in `apiCost`.
struct ModelPrice { let input, output, cacheRead, cacheWrite: Double }

/// Matched by prefix, most specific first. Unknown models cost nothing and are reported as
/// "unpriced" so the money figures never silently include a guess.
let MODEL_PRICES: [(prefix: String, price: ModelPrice)] = [
    ("claude-fable-5-1", ModelPrice(input: 10, output: 50, cacheRead: 0.25, cacheWrite: 12.5)),
    ("claude-fable",     ModelPrice(input: 10, output: 50, cacheRead: 1.0,  cacheWrite: 12.5)),
    ("claude-opus",      ModelPrice(input: 5,  output: 25, cacheRead: 0.5,  cacheWrite: 6.25)),
    ("claude-sonnet",    ModelPrice(input: 2,  output: 10, cacheRead: 0.2,  cacheWrite: 2.5)),
    ("claude-haiku",     ModelPrice(input: 1,  output: 5,  cacheRead: 0.1,  cacheWrite: 1.25)),
    ("gpt-6-astra",      ModelPrice(input: 10, output: 50, cacheRead: 1.0,  cacheWrite: 12.5)),
    ("gpt-6-luna",       ModelPrice(input: 1,  output: 5,  cacheRead: 0.1,  cacheWrite: 1.25)),
    ("gpt-5.6",          ModelPrice(input: 4,  output: 20, cacheRead: 0.4,  cacheWrite: 5.0)),
    ("gpt-6-sol",        ModelPrice(input: 4,  output: 20, cacheRead: 0.4,  cacheWrite: 5.0)),
    ("gpt-reserve",      ModelPrice(input: 4,  output: 20, cacheRead: 0.4,  cacheWrite: 5.0)),
    ("codex-auto-review", ModelPrice(input: 4, output: 20, cacheRead: 0.4,  cacheWrite: 5.0)),
]
func modelPrice(_ model: String) -> ModelPrice? {
    MODEL_PRICES.first { model.hasPrefix($0.prefix) }?.price
}
func apiCost(_ model: String, _ u: DayModelUsage) -> Double? {
    guard let p = modelPrice(model) else { return nil }
    return (Double(u.input) * p.input + Double(u.output) * p.output + Double(u.cacheRead) * p.cacheRead
            + Double(u.cacheWrite5m) * p.cacheWrite + Double(u.cacheWrite1h) * p.input * 2) / 1e6
}

/// Short human name for a model id ("claude-fable-5-1" → "Fable 5.1", "gpt-6-astra" → "Astra 6").
func modelDisplayName(_ id: String) -> String {
    var s = id
    for pre in ["claude-", "gpt-"] where s.hasPrefix(pre) { s = String(s.dropFirst(pre.count)) }
    var parts = s.split(separator: "-").map(String.init)
    if parts.first == "codex" { return parts.dropFirst().joined(separator: "-") }
    // move a leading version ("6", "5.6") behind the family name: "6-astra" → "Astra 6"
    if let first = parts.first, first.first?.isNumber == true, parts.count >= 2 {
        let ver = parts.removeFirst()
        let name = parts.removeFirst()
        return name.capitalized + " " + ([ver] + parts).joined(separator: ".")
    }
    let name = parts.removeFirst()
    return parts.isEmpty ? name.capitalized : name.capitalized + " " + parts.joined(separator: ".")
}

/// Monthly subscription price in USD — the user's own setting first, else an inference
/// from what the backends tell us about the plan. Codex plan names aren't public pricing,
/// so that side is an estimate until the user sets it (`flag` says which).
func subscriptionUSD(_ product: String, plan: String?) -> (usd: Double, estimated: Bool) {
    let d = UserDefaults.standard
    let key = product == "claude" ? "subClaude" : "subCodex"
    if d.object(forKey: key) != nil { return (d.double(forKey: key), false) }
    if product == "claude" {
        let tier = d.string(forKey: "claudeTier") ?? ""
        if tier.contains("max_20x") { return (200, false) }
        if tier.contains("max_5x") { return (100, false) }
        if tier.contains("pro") || plan == "pro" { return (20, false) }
        return (200, true)
    }
    switch plan ?? "" {
    case "free": return (0, false)
    case "go": return (8, false)
    case "plus": return (20, false)
    case "pro": return (200, true)
    default: return (100, true)      // "prolite" and anything else: Pro 5x-shaped guess
    }
}

struct DayUsage { let day: String; let byModel: [(model: String, tokens: Int, usd: Double)]; let usd: Double; let tokens: Int; let turns: Int }

/// Per-day rollup for the last `days` calendar days (oldest first), with per-model splits
/// sorted by cost so the biggest consumer sits at the bottom of a stacked bar.
func dailyUsage(_ product: String, days: Int, index: UsageIndex) -> [DayUsage] {
    let today = Calendar.current.startOfDay(for: Date())
    return (0..<days).reversed().map { back -> DayUsage in
        let d = Calendar.current.date(byAdding: .day, value: -back, to: today)!
        let key = dayKey(d)
        let models = index.days[product]?[key] ?? [:]
        var rows: [(String, Int, Double)] = []
        var usd = 0.0, tokens = 0, turns = 0
        for (m, u) in models where m != "?" {
            let c = apiCost(m, u) ?? 0
            rows.append((m, u.totalTokens, c)); usd += c; tokens = usageSum(tokens, u.totalTokens); turns = usageSum(turns, u.turns)
        }
        rows.sort { $0.2 > $1.2 }
        return DayUsage(day: key, byModel: rows.map { (model: $0.0, tokens: $0.1, usd: $0.2) }, usd: usd, tokens: tokens, turns: turns)
    }
}

struct MoneySummary {
    let days: Int, activeDays: Int
    let usdApi: Double, perCalendarDay: Double, perActiveDay: Double
    let subMonthly: Double, subEstimated: Bool
    var subPerDay: Double { subMonthly / 30 }
    var subPerWeek: Double { subMonthly * 12 / 52 }
    var ratio: Double { subMonthly > 0 ? usdApi / (subMonthly * Double(days) / 30) : 0 }
}
func moneySummary(_ product: String, plan: String?, index: UsageIndex, days: Int = 35) -> MoneySummary {
    let rows = dailyUsage(product, days: days, index: index)
    let active = rows.filter { $0.turns > 0 }
    let total = rows.reduce(0) { $0 + $1.usd }
    let sub = subscriptionUSD(product, plan: plan)
    return MoneySummary(days: days, activeDays: active.count, usdApi: total,
                        perCalendarDay: total / Double(days), perActiveDay: active.isEmpty ? 0 : total / Double(active.count),
                        subMonthly: sub.usd, subEstimated: sub.estimated)
}

// ---- Text formatting for the Advanced screen ----------------------------------------------

/// "13,4" in Russian, "13.4" in English — one decimal, no trailing zero for whole numbers.
func fmtNum(_ v: Double, decimals: Int = 1) -> String {
    let rounded = (v * pow(10, Double(decimals))).rounded() / pow(10, Double(decimals))
    var str = rounded == rounded.rounded() && decimals <= 1 ? String(format: "%.0f", rounded) : String(format: "%.\(decimals)f", rounded)
    if appLang() == "ru" { str = str.replacingOccurrences(of: ".", with: ",") }
    return str
}
func fmtPct(_ v: Double, decimals: Int = 1) -> String { fmtNum(v, decimals: decimals) + "%" }
func fmtSignedPts(_ v: Double) -> String { (v >= 0 ? "+" : "−") + fmtNum(abs(v)) + tr(" п.", " pts") }
func fmtUSD(_ v: Double) -> String {
    if v >= 100 { return "$" + String(format: "%.0f", v.rounded()) }
    return "$" + fmtNum(v, decimals: 2)
}

/// "2 ч 13 мин" / "3,7 дня" / "45 мин" — the way you'd say a remaining span out loud.
func fmtSpan(_ hours: Double) -> String {
    if hours >= 24 {
        let days = (hours / 24 * 10).rounded() / 10
        if days == days.rounded() {
            let n = Int(days)
            if appLang() == "ru" { return "\(n) " + (n == 1 ? "день" : (2...4).contains(n) ? "дня" : "дней") }
            return "\(n) " + (n == 1 ? "day" : "days")
        }
        return fmtNum(days) + tr(" дня", " days")
    }
    if hours >= 1 {
        let h = Int(hours), m = Int(((hours - Double(h)) * 60).rounded())
        return m == 0 ? "\(h)" + tr(" ч", " h") : "\(h)" + tr(" ч ", " h ") + "\(m)" + tr(" мин", " min")
    }
    return "\(max(1, Int((hours * 60).rounded())))" + tr(" мин", " min")
}
/// "3 д 19 ч" — the compact form for a "time left" column.
func fmtSpanShort(_ hours: Double) -> String {
    if hours >= 24 { return "\(Int(hours / 24))" + tr(" д ", " d ") + "\(Int(hours.truncatingRemainder(dividingBy: 24)))" + tr(" ч", " h") }
    if hours >= 1 { return "\(Int(hours))" + tr(" ч ", " h ") + "\(Int(((hours - Double(Int(hours))) * 60).rounded()))" + tr(" мин", " min") }
    return "\(max(1, Int((hours * 60).rounded())))" + tr(" мин", " min")
}

/// A moment as people say it: "09:37" today, "сб 15:33" within the week, else "26 сен, 15:33".
func fmtMoment(_ d: Date) -> String {
    let cal = Calendar.current
    let f = DateFormatter(); f.locale = Locale(identifier: appLang() == "ru" ? "ru_RU" : "en_US")
    if cal.isDateInToday(d) { f.dateFormat = "HH:mm"; return f.string(from: d) }
    if let week = cal.date(byAdding: .day, value: 6, to: Date()), d < week {
        f.dateFormat = "EEE HH:mm"; return f.string(from: d).replacingOccurrences(of: ".", with: "")
    }
    f.dateFormat = "d MMM, HH:mm"; return f.string(from: d).replacingOccurrences(of: ".", with: "")
}

/// Burn rate in the unit that reads naturally for the window: %/hour for a 5-hour
/// window, %/day for a weekly one.
func fmtRate(_ pace: WindowPace) -> String {
    pace.windowH <= 24 ? fmtNum(pace.avgRatePerH) + tr("%/ч", "%/h")
                       : fmtNum(pace.avgRatePerH * 24) + tr("%/день", "%/day")
}

/// The verdict line: what actually happens to this window if you keep going like this.
func paceVerdict(_ p: WindowPace) -> String {
    if p.used >= 100 { return tr("Лимит исчерпан", "Limit reached") }
    if let at = p.runsOutAt {
        let before = p.reset.timeIntervalSince(at) / 3600
        return tr("Кончится в ", "Runs out at ") + fmtMoment(at) + tr(", за ", ", ") + fmtSpan(before) + tr(" до сброса", " before reset")
    }
    if let proj = p.projectedPct { return tr("Хватит до сброса (прогноз ", "Lasts to reset (projected ") + fmtPct(proj, decimals: 0) + ")" }
    return tr("Хватит до сброса", "Lasts to reset")
}

// ---- View model for the Advanced screen ---------------------------------------------------

/// One day of a stacked bar: the per-model split (biggest first), with models under 3% of
/// the day folded into "other" so the stack never has a sliver you can't read.
struct StackedDay {
    let day: String, weekday: Int          // weekday: 1 = Monday … 7 = Sunday
    let usd: Double, turns: Int
    let parts: [(model: String, usd: Double)]
    let isToday: Bool
}

struct AdvancedProduct {
    let product: String
    let limits: [PacedLimit]
    let resetCredits: Int?
    let days7: [StackedDay]
    let legend: [String]                   // models by 7-day spend, "other" last when present
    let calendar: [DayUsage]               // last 42 calendar days, oldest first
    let calendarMax: Double
    let money: MoneySummary
    let firstSample: Date?                 // when utilization sampling began (nil = never)
}

func advancedProduct(_ d: LimitData, product: String, index: UsageIndex) -> AdvancedProduct {
    let days = dailyUsage(product, days: 42, index: index)
    let last7 = Array(days.suffix(7))
    let todayKey = dayKey(Date())
    // legend: models ranked by spend across the 7 days; anything under 3% of a day → "other"
    var spend: [String: Double] = [:]
    for dd in last7 { for r in dd.byModel { spend[r.model, default: 0] += r.usd } }
    let ranked = spend.sorted { $0.value > $1.value }.map { $0.key }
    let top = Array(ranked.prefix(3))
    var hasOther = false
    let stacked: [StackedDay] = last7.map { dd in
        var parts: [(String, Double)] = []
        var other = 0.0
        for r in dd.byModel {
            if top.contains(r.model), dd.usd > 0, r.usd / dd.usd >= 0.03 { parts.append((r.model, r.usd)) }
            else { other += r.usd }
        }
        if other > 0 { parts.append(("other", other)); hasOther = true }
        let wd = Calendar.current.component(.weekday, from: dayKeyFormatter.date(from: dd.day) ?? Date())
        return StackedDay(day: dd.day, weekday: wd == 1 ? 7 : wd - 1, usd: dd.usd, turns: dd.turns,
                          parts: parts.map { (model: $0.0, usd: $0.1) }, isToday: dd.day == todayKey)
    }
    let first = UsageHistory.shared.samples(product, since: Date(timeIntervalSince1970: 0)).first.map { Date(timeIntervalSince1970: $0.t) }
    return AdvancedProduct(product: product, limits: pacedLimits(d, product: product), resetCredits: d.resetCredits,
                           days7: stacked, legend: top + (hasOther ? ["other"] : []),
                           calendar: days, calendarMax: days.map { $0.usd }.max() ?? 0,
                           money: moneySummary(product, plan: d.plan, index: index), firstSample: first)
}

/// Calendar cell brightness 0…1 on a square-root scale, so a couple of heavy days don't
/// turn every other day black.
func calendarIntensity(_ usd: Double, max: Double) -> Double {
    guard max > 0, usd > 0 else { return 0 }
    return Swift.max(0.12, (usd / max).squareRoot())
}

// ---- Pace ---------------------------------------------------------------------------------

/// Everything the Advanced view says about one rate-limit window, derived from a single
/// reading: where a linear plan (0% at open → 100% at reset) says you should be, how far
/// off it you are, the average burn since the window opened, and — extrapolating that —
/// whether the window lasts to its reset or when it runs out.
struct WindowPace {
    let used: Double
    let start: Date, reset: Date, windowH: Double
    let elapsedH: Double, remainingH: Double
    let planPct: Double            // where the linear plan is right now
    let deltaPts: Double           // used − plan; positive = burning faster than plan
    let avgRatePerH: Double        // % per hour since the window opened
    let projectedPct: Double?      // used ÷ elapsed fraction — where you'd land at reset
    let runsOutAt: Date?           // when 100% is reached at the average rate, if before reset
    let recentRatePerH: Double?    // % per hour over the last hour of samples, when known
    var lasts: Bool { runsOutAt == nil }
    /// Severity for colour: 2 = runs out before reset, 1 = projected 85–100% ("впритык"), 0 = fine.
    var severity: Int {
        if runsOutAt != nil { return 2 }
        if let p = projectedPct, p >= 85 { return 1 }
        return 0
    }
}

func windowPace(used: Double?, reset: Date?, windowH: Double, recentRate: Double? = nil, now: Date = Date()) -> WindowPace? {
    guard let used = used, let reset = reset else { return nil }
    let start = reset.addingTimeInterval(-windowH * 3600)
    let elapsedH = max(0, min(windowH, now.timeIntervalSince(start) / 3600))
    let frac = elapsedH / windowH
    let plan = frac * 100
    // Ten minutes into a window the average is noise; hold off on projecting until then.
    let rate = elapsedH >= 10.0 / 60 ? used / elapsedH : 0
    let projected: Double? = elapsedH >= 10.0 / 60 && frac > 0 ? used / frac : nil
    var runsOut: Date? = nil
    if rate > 0 {
        let at = start.addingTimeInterval(100 / rate * 3600)
        if at < reset { runsOut = at }
    }
    if used >= 100 { runsOut = now }
    return WindowPace(used: used, start: start, reset: reset, windowH: windowH, elapsedH: elapsedH,
                      remainingH: windowH - elapsedH, planPct: plan, deltaPts: used - plan, avgRatePerH: rate,
                      projectedPct: projected, runsOutAt: runsOut, recentRatePerH: recentRate)
}

/// The windows the Advanced view lists for a product, in display order.
struct PacedLimit { let id: String; let name: String; let pace: WindowPace?; let color: Int; var used: Double? = nil }   // color: 0 session, 1 weekly, 2 scoped
func pacedLimits(_ d: LimitData, product: String) -> [PacedLimit] {
    let h = UsageHistory.shared
    var out: [PacedLimit] = []
    // Codex no longer has a 5-hour window (Alex, 2026-09-24): show its session row only if the
    // backend actually reports one, never as a permanent "inactive" placeholder. Claude's
    // session row is always there — that window is the one you hit most.
    if product == "claude" || d.session != nil {
        out.append(PacedLimit(id: "session", name: tr("Сессия · 5 ч", "Session · 5 h"),
                              pace: snapshotWindowPace(used: d.session, reset: d.sessionReset, windowH: 5,
                                               asOf: d.asOf, recentRate: d.asOf.flatMap { h.recentRate(product, metric: { $0.session }, minutes: 60, now: $0) }), color: 0, used: d.session))
    }
    // Order (Alex, 2026-09-24): session → per-model week (Fable) → all-models week. The
    // per-model limit is the one that actually bites first, so it sits right under the session.
    if let s = d.scoped {
        out.append(PacedLimit(id: "scoped", name: tr("Неделя · ", "Week · ") + s.name,
                              pace: snapshotWindowPace(used: s.percent, reset: s.reset, windowH: 168,
                                               asOf: d.asOf, recentRate: d.asOf.flatMap { h.recentRate(product, metric: { $0.scoped }, minutes: 180, now: $0) }), color: 2, used: s.percent))
    }
    out.append(PacedLimit(id: "weekly", name: product == "claude" ? tr("Неделя · все модели", "Week · all models") : tr("Неделя", "Week"),
                          pace: snapshotWindowPace(used: d.weekly, reset: d.weeklyReset, windowH: 168,
                                           asOf: d.asOf, recentRate: d.asOf.flatMap { h.recentRate(product, metric: { $0.weekly }, minutes: 180, now: $0) }), color: 1, used: d.weekly))
    return out
}

// MARK: - Cross-machine sync through a GitHub gist (docs/sync-protocol.md)
//
// Each computer writes one whole-snapshot file of daily per-model token totals into a secret
// gist and reads everyone else's. Only aggregates travel; the token never leaves the Keychain
// except in the Authorization header, and is never logged.

let GITHUB_CLIENT_ID = "Ov23lipk8voUWUAr59qS"
let SYNC_KC_SERVICE = "Claude Codex Limits GitHub"
let SYNC_REMOTE_PATH = DATA_DIR + "/sync-remote.json"
let MACHINE_ID_PATH = DATA_DIR + "/machine-id"
let SYNC_KEEP_DAYS: Double = 45
let SYNC_MANIFEST = "ccl-sync.json"
let SYNC_KEYCHAIN_BACKOFF: TimeInterval = 30 * 60

private func syncAPIOrigin(_ url: String) -> Bool {
    guard let c = URLComponents(string: url), c.scheme == "https",
          let host = c.host, host.unicodeScalars.allSatisfy({ $0.isASCII }),
          host.lowercased() == "api.github.com", !host.contains("%"),
          let encodedHost = c.percentEncodedHost, !encodedHost.contains("%"),
          c.port == nil || c.port == 443, c.user == nil, c.password == nil else { return false }
    return true
}

/// JSONSerialization bridges 0/1 to Bool too; only CFBoolean is a JSON boolean.
private func syncIsPrivate(_ value: Any?) -> Bool {
    guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return false }
    return n.boolValue == false
}

private func syncCount(_ value: Any?) -> Int? {
    guard let value = value else { return 0 }
    if let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
    guard let n = value as? Int, (0...1_000_000_000_000_000).contains(n) else { return nil }
    return n
}

/// Keychain through /usr/bin/security (like the Claude credentials): an ad-hoc-signed app
/// would get an access prompt after every update if it owned the item itself. The secret is
/// written through `security -i` on stdin so it never appears in a process's arguments.
enum SyncKeychainRead {
    case token(String), missing, timedOut, failure(Int32)
}
enum SyncKeychainStatus: Equatable {
    case success, missing, timedOut, failure(Int32)
}
protocol SyncKeychain {
    func read() -> SyncKeychainRead
    func write(_ token: String) -> SyncKeychainStatus
    func delete() -> SyncKeychainStatus
}

/// One /usr/bin/security call with a hard 15 s deadline. A locked Keychain (or its unlock
/// prompt) must not hang the serial ccl.sync queue forever: pipes are pumped on helper
/// threads. SIGTERM is followed by SIGKILL after 2 s if the process is still alive.
private final class SyncSecurityOutput {
    private let lock = NSLock()
    private var data = Data()
    func store(_ value: Data) { lock.lock(); data = value; lock.unlock() }
    func string() -> String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}
private func syncSecurity(_ args: [String], input: String? = nil, lifetime: GitHubAuthProcessFence? = nil) -> (status: SyncKeychainStatus, out: String) {
    guard lifetime?.begin() != false else { return (.timedOut, "") }
    let p = Process(), output = Pipe(), stdin = Pipe()
    let ended = DispatchSemaphore(value: 0), drained = DispatchSemaphore(value: 0)
    let result = SyncSecurityOutput()
    let deadline = DispatchTime.now() + 15
    p.executableURL = URL(fileURLWithPath: "/usr/bin/security"); p.arguments = args
    p.standardOutput = output; p.standardError = FileHandle.nullDevice
    if input == nil { p.standardInput = FileHandle.nullDevice } else { p.standardInput = stdin }
    p.terminationHandler = { _ in lifetime?.ended(); ended.signal() }
    do { try p.run() } catch { lifetime?.ended(); return (.failure(-1), "") }
    DispatchQueue.global(qos: .utility).async {
        result.store(output.fileHandleForReading.readDataToEndOfFile())
        try? output.fileHandleForReading.close()
        drained.signal()
    }
    if let input = input {
        // A child that already died must not SIGPIPE the whole app: EPIPE is just an error here.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        DispatchQueue.global(qos: .utility).async {
            try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
    }
    guard ended.wait(timeout: deadline) == .success,
          drained.wait(timeout: deadline) == .success else {
        if p.isRunning { p.terminate() }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            if p.isRunning { _ = kill(p.processIdentifier, SIGKILL) }
        }
        return (.timedOut, "")
    }
    let code = p.terminationStatus
    return (code == 0 ? .success : code == 44 ? .missing : .failure(code), result.string())
}
struct SecuritySyncKeychain: SyncKeychain {
    var lifetime: GitHubAuthProcessFence? = nil
    func read() -> SyncKeychainRead {
        let r = syncSecurity(["find-generic-password", "-s", SYNC_KC_SERVICE, "-w"], lifetime: lifetime)
        switch r.status {
        case .success:
            let token = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
            return token.isEmpty ? .failure(-1) : .token(token)
        case .missing: return .missing
        case .timedOut: return .timedOut
        case .failure(let code): return .failure(code)
        }
    }
    func write(_ token: String) -> SyncKeychainStatus {
        guard !token.isEmpty, token.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { return .failure(-1) }
        let command = "add-generic-password -U -a \"\(NSUserName())\" -s \"\(SYNC_KC_SERVICE)\" -w \(token)\n"
        return syncSecurity(["-i"], input: command).status
    }
    func delete() -> SyncKeychainStatus {
        syncSecurity(["delete-generic-password", "-s", SYNC_KC_SERVICE], lifetime: lifetime).status
    }
}
typealias SyncHTTPResult = (status: Int, data: Data?, err: String?, headers: [String: String])
typealias SyncHTTP = (String, String, [String: String], Data?, Double) -> SyncHTTPResult

private func syncHTTP(_ url: String, _ method: String, _ headers: [String: String], _ body: Data?, _ timeout: Double) -> SyncHTTPResult {
    let authenticated = headers.keys.contains { $0.lowercased() == "authorization" }
    guard !authenticated || syncAPIOrigin(url) else { return (0, nil, "GitHub API origin required", [:]) }
    let oauth = method == "POST" && syncOAuthEndpoint(url)
    if method == "POST", body != nil, !authenticated, !oauth { return (0, nil, "OAuth endpoint required", [:]) }
    return requestHTTP(url, method: method, headers: headers, body: body, timeout: timeout, noRedirects: authenticated || oauth)
}

func syncKeychainTimeout() -> String { tr("Связка ключей не ответила за 15 с", "Keychain didn't answer in 15 s") }
func syncKeychainReadError(_ result: SyncKeychainRead) -> String {
    switch result {
    case .timedOut: return syncKeychainTimeout()
    case .missing: return tr("Вход не найден в Связке ключей", "Sign-in not found in Keychain")
    case .failure(let code): return tr("Ошибка Связки ключей: \(code)", "Keychain error: \(code)")
    case .token: return tr("Вход в Связке ключей изменился; повторим синхронизацию", "Keychain sign-in changed; sync will retry")
    }
}

struct SyncCachedMachine: Codable { var id: String; var name: String; var os: String; var updated: Date? }
struct SyncRemoteCache: Codable {
    var authEpoch: String?
    var authUserID: String?
    var machines: [SyncCachedMachine] = []
    var days: [String: [String: [String: DayModelUsage]]] = [:]
}

/// Pure account-binding check shared by loading, cached render reads and fixtures.
func syncCacheMatches(_ cache: SyncRemoteCache, snapshot: GitHubAuthSnapshot?) -> Bool {
    guard let snapshot = snapshot else { return true } // Explicit ownerless legacy test adapter.
    guard let epoch = snapshot.epoch, cache.authEpoch == epoch,
          cache.authUserID == snapshot.userID else { return false }
    // Legacy sessions have no stable user ID. Their per-process nonce is never restored
    // after restart; only a captured-token-fenced in-memory cache may match it.
    return epoch.hasPrefix("legacy-cache-") || snapshot.userID?.isEmpty == false
}

// Exact OAuth endpoints; redirects are disabled for all secret-bearing POSTs.
func syncOAuthEndpoint(_ url: String) -> Bool {
    guard let c = URLComponents(string: url), c.scheme == "https", c.host == "github.com",
          c.percentEncodedHost == "github.com", c.user == nil, c.password == nil,
          c.port == nil || c.port == 443, c.query == nil, c.fragment == nil else { return false }
    return ["/login/device/code", "/login/oauth/access_token"].contains(c.percentEncodedPath)
}
private enum GitHubAuthPersistenceError: Error { case unavailable, corrupt }
private let githubAuthProcessFence = GitHubAuthProcessFence()
private let GITHUB_AUTH_SERVICE = "Claude Codex Limits GitHub Credential V2"

private func githubAuthRefSafe(_ ref: GitHubAuthRef) -> Bool {
    ref.backend == "keychain" && !ref.generation.isEmpty && ref.generation.utf8.count <= 128
        && ref.generation.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }
}
private func githubAuthRead(_ ref: GitHubAuthRef) -> GitHubAuthRead {
    if ref == GitHubAuthRef(generation: "legacy", backend: "legacy-keychain") {
        switch SecuritySyncKeychain(lifetime: githubAuthProcessFence).read() {
        case .token(let token): return .ready(GitHubCredentialV2(epoch: "legacy", generation: "legacy", accessToken: token, refreshToken: nil, obtainedAt: 0))
        case .missing: return .missing
        case .timedOut: return .timeout
        case .failure: return .unreachable
        }
    }
    guard githubAuthRefSafe(ref) else { return .corrupt }
    let result = syncSecurity(["find-generic-password", "-s", GITHUB_AUTH_SERVICE, "-a", ref.generation, "-w"], lifetime: githubAuthProcessFence)
    switch result.status {
    case .missing: return .missing
    case .timedOut: return .timeout
    case .failure(let code): return code == 36 ? .locked : .unreachable
    case .success:
        var encoded = result.out.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
              let c = try? JSONDecoder().decode(GitHubCredentialV2.self, from: data), c.schema == 2,
              c.generation == ref.generation else { return .corrupt }
        return .ready(c)
    }
}
private func githubAuthStatus(_ status: SyncKeychainStatus) -> GitHubAuthStoreStatus {
    switch status {
    case .success, .missing: return .success
    case .timedOut: return .timeout
    case .failure(let code): return code == 36 ? .locked : .unreachable
    }
}
/// Pure validation shared by the private native writer and offline fixtures.
func githubAuthHelperEnvelope(_ input: Data, generation: String) -> GitHubCredentialV2? {
    guard UUID(uuidString: generation)?.uuidString.lowercased() == generation,
          input.count <= 128 * 1024, let encoded = String(data: input, encoding: .ascii),
          !encoded.isEmpty, encoded.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" }) else { return nil }
    var base64 = encoded.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    guard let data = Data(base64Encoded: base64), let credential = try? JSONDecoder().decode(GitHubCredentialV2.self, from: data),
          credential.schema == 2, credential.generation == generation,
          UUID(uuidString: credential.epoch) != nil,
          ["probe", "credential", "incomplete"].contains(credential.kind) else { return nil }
    for token in [credential.accessToken, credential.refreshToken].compactMap({ $0 }) {
        guard !token.isEmpty, token.utf8.count <= 16384,
              token.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 32 && $0.value < 127 }) else { return nil }
    }
    return credential
}
enum GitHubAuthWriterPhase: String, Codable { case prepared, rpcStarted, completed, notStarted }
struct GitHubAuthWriterRecord: Codable {
    var schema: Int = 1
    var generation: String
    var operation: String
    var phase: GitHubAuthWriterPhase
    var epoch: String?
    var status: Int32?
}
/// Strict pure protocol parser for offline fixtures. Unknown/old records never prove no RPC.
func githubAuthWriterRecord(_ data: Data, generation: String) -> GitHubAuthWriterRecord? {
    guard let record = try? JSONDecoder().decode(GitHubAuthWriterRecord.self, from: data),
          record.schema == 1, record.generation == generation,
          UUID(uuidString: record.operation)?.uuidString.lowercased() == record.operation else { return nil }
    switch record.phase {
    case .prepared, .rpcStarted:
        guard record.status == nil, record.epoch.flatMap({ UUID(uuidString: $0) }) != nil else { return nil }
    case .completed:
        guard record.status != nil, record.epoch.flatMap({ UUID(uuidString: $0) }) != nil else { return nil }
    case .notStarted:
        guard record.status == nil, record.epoch == nil || record.epoch.flatMap({ UUID(uuidString: $0) }) != nil else { return nil }
    }
    return record
}
func githubAuthWriterPermitAllows(_ record: GitHubAuthWriterRecord, generation: String, operation: String, epoch: String) -> Bool {
    record.schema == 1 && record.generation == generation && record.operation == operation
        && record.epoch == epoch && record.phase == .prepared && record.status == nil
}
private func githubAuthWriterDirectory() -> String { NSHomeDirectory() + "/.claude-limits-monitor/github-auth-writers" }
private func githubAuthWriterLock(_ generation: String) -> Int32? {
    guard UUID(uuidString: generation)?.uuidString.lowercased() == generation else { return nil }
    let directory = githubAuthWriterDirectory()
    do { try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
    catch { return nil }
    let fd = open(directory + "/" + generation + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard fd >= 0 else { return nil }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return nil }
    return fd
}
private func githubAuthWriterLoad(_ generation: String) throws -> GitHubAuthWriterRecord? {
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: githubAuthWriterDirectory() + "/" + generation + ".json"))
        guard let record = githubAuthWriterRecord(data, generation: generation) else { throw GitHubAuthPersistenceError.corrupt }
        return record
    } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
}
private func githubAuthWriterSave(_ record: GitHubAuthWriterRecord) throws {
    // This helper is also reachable before main globals initialize. Every path is
    // derived from the fixed private directory and a validated generation UUID.
    guard UUID(uuidString: record.generation)?.uuidString.lowercased() == record.generation else { throw GitHubAuthPersistenceError.corrupt }
    let directory = githubAuthWriterDirectory()
    let path = directory + "/" + record.generation + ".json"
    let temporary = directory + "/." + UUID().uuidString.lowercased() + ".tmp"
    let data = try JSONEncoder().encode(record)
    let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard fd >= 0 else { throw GitHubAuthPersistenceError.unavailable }
    defer { close(fd); unlink(temporary) }
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw GitHubAuthPersistenceError.unavailable }; offset += count
        }
    }
    guard fsync(fd) == 0, rename(temporary, path) == 0 else { throw GitHubAuthPersistenceError.unavailable }
    let dirFD = open(directory, O_RDONLY)
    guard dirFD >= 0 else { throw GitHubAuthPersistenceError.unavailable }
    defer { close(dirFD) }
    guard fsync(dirFD) == 0 else { throw GitHubAuthPersistenceError.unavailable }
}

private func githubAuthNativeStoreHelper() -> Int32 {
    // This private entry point cannot choose a service, account other than a UUID,
    // marker path or credential file. It runs before all ordinary application globals.
    guard CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--github-auth-store-helper" else { return 64 }
    let generation = CommandLine.arguments[2], operation = CommandLine.arguments[3]
    guard UUID(uuidString: operation)?.uuidString.lowercased() == operation else { return 64 }
    var input = Data()
    do {
        while let chunk = try FileHandle.standardInput.read(upToCount: min(8192, 128 * 1024 + 1 - input.count)), !chunk.isEmpty {
            input.append(chunk)
            guard input.count <= 128 * 1024 else { return 65 }
        }
    } catch { return 65 }
    guard let credential = githubAuthHelperEnvelope(input, generation: generation) else { return 65 }
    let service = "Claude Codex Limits GitHub Credential V2"
    var trusted: SecTrustedApplication?
    guard SecTrustedApplicationCreateFromPath("/usr/bin/security", &trusted) == errSecSuccess, let trusted = trusted else { return 70 }
    var access: SecAccess?
    // Preserve the stable system security tool's access across ad-hoc app updates.
    // This is an explicit trusted-app ACL, never an allow-all (-A) ACL.
    guard SecAccessCreate(service as CFString, [trusted] as CFArray, &access) == errSecSuccess,
          let access = access else { return 70 }
    let attributes: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: generation,
        kSecAttrAccess as String: access,
        kSecValueData as String: input,
    ]
    // The permit lock is held across the native RPC. Recovery can close an absent or
    // prepared permit before any delayed helper gets here; operation UUIDs prevent ABA.
    guard let writerFD = githubAuthWriterLock(generation) else { return 69 }
    defer { flock(writerFD, LOCK_UN); close(writerFD) }
    var record: GitHubAuthWriterRecord
    do {
        guard let value = try githubAuthWriterLoad(generation),
              githubAuthWriterPermitAllows(value, generation: generation, operation: operation, epoch: credential.epoch) else { return 78 }
        record = value; record.phase = .rpcStarted
        try githubAuthWriterSave(record)
    } catch { return 75 }
    // Add only. A retry cannot overwrite any previously stored immutable generation.
    let status = SecItemAdd(attributes as CFDictionary, nil)
    record.phase = .completed; record.status = status
    do { try githubAuthWriterSave(record) } catch { return 75 }

    if status == errSecSuccess || status == errSecDuplicateItem { return 0 }
    return status == errSecInteractionNotAllowed ? 36 : 1
}

private final class GitHubAuthWriters: @unchecked Sendable {
    static let shared = GitHubAuthWriters()
    private let lock = NSLock()
    private var running: [String: Process] = [:]
    private var completed: [String: Int32] = [:]
    func completion(operation: String) -> Int32? { lock.lock(); defer { lock.unlock() }; return completed[operation] }
    func completed(operation: String, status: Int32) { lock.lock(); completed[operation] = status; lock.unlock() }
    func retain(_ process: Process, generation: String) { lock.lock(); running[generation] = process; lock.unlock() }
    func release(generation: String) { lock.lock(); running.removeValue(forKey: generation); lock.unlock() }
}
private func githubAuthWriterMarker(_ ref: GitHubAuthRef) -> String {
    DATA_DIR + "/github-auth-writers/" + ref.generation + ".done"
}
private func githubAuthSettled(_ ref: GitHubAuthRef) -> Bool {
    guard githubAuthRefSafe(ref) else { return false }
    // Only the journal flag written BEFORE stage opts a ref into the permit protocol.
    // Older helpers without a permit must still supply their original completion proof.
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: DATA_DIR + "/github-auth-state.json")),
          let manifest = try? JSONDecoder().decode(GitHubAuthManifest.self, from: data) else { return false }
    if !(manifest.permitWriterRefs ?? []).contains(ref) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: githubAuthWriterMarker(ref))),
              let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let complete = value["completed"] as? NSNumber, CFGetTypeID(complete) == CFBooleanGetTypeID(), complete.boolValue,
              let status = value["status"] as? NSNumber, CFGetTypeID(status) != CFBooleanGetTypeID() else { return false }
        return Int32(exactly: status.int64Value) != nil
    }
    guard let fd = githubAuthWriterLock(ref.generation) else { return false }
    defer { flock(fd, LOCK_UN); close(fd) }
    do {
        if var record = try githubAuthWriterLoad(ref.generation) {
            switch record.phase {
            case .rpcStarted:
                // A normally returned helper proves the synchronous RPC is over even
                // if its final record write failed. A signal/kill never supplies this.
                guard let status = GitHubAuthWriters.shared.completion(operation: record.operation) else { return false }
                record.phase = .completed; record.status = status
                try githubAuthWriterSave(record); return true
            case .completed, .notStarted: return true
            case .prepared:
                // Closing this exact operation while holding the same lock as the helper
                // proves no RPC and prevents it from being started after this return.
                record.phase = .notStarted; try githubAuthWriterSave(record); return true
            }
        }
        // Crash in auth journal -> stage handoff. No permit was ever published, so no
        // protocol-aware helper could issue an RPC; close the slot before releasing it.
        let closed = GitHubAuthWriterRecord(generation: ref.generation, operation: UUID().uuidString.lowercased(), phase: .notStarted)
        try githubAuthWriterSave(closed); return true
    } catch { return false }
}
private func githubAuthStage(_ ref: GitHubAuthRef, _ c: GitHubCredentialV2) -> GitHubAuthStoreStatus {
    guard githubAuthRefSafe(ref), c.generation == ref.generation,
          let data = try? JSONEncoder().encode(c) else { return .failed }
    let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    // 16 KiB tokens plus bounded identity/metadata fit this 128 KiB native envelope;
    // no CLI command-line/interactive-line size participates in the write path.
    guard githubAuthHelperEnvelope(Data(encoded.utf8), generation: ref.generation) != nil else { return .failed }
    let operation = UUID().uuidString.lowercased()
    guard let fd = githubAuthWriterLock(ref.generation) else { return .timeout }
    do {
        if let previous = try githubAuthWriterLoad(ref.generation), previous.phase == .rpcStarted {
            flock(fd, LOCK_UN); close(fd); return .timeout
        }
        let record = GitHubAuthWriterRecord(generation: ref.generation, operation: operation, phase: .prepared, epoch: c.epoch)
        try githubAuthWriterSave(record)
    } catch { flock(fd, LOCK_UN); close(fd); return .unreachable }
    flock(fd, LOCK_UN); close(fd)
    let process = Process(), input = Pipe(), ended = DispatchSemaphore(value: 0)
    // No security -i line parser: native SecItemAdd receives the complete envelope.
    // Secrets are stdin only; argv contains a private operation and immutable UUID.
    guard let executable = Bundle.main.executableURL else { return .failed }
    process.executableURL = executable
    process.arguments = ["--github-auth-store-helper", ref.generation, operation]
    process.standardInput = input; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    let writers = GitHubAuthWriters.shared
    let jobID = UUID().uuidString
    writers.retain(process, generation: jobID)
    process.terminationHandler = { process in
        if process.terminationReason == .exit, (0..<128).contains(process.terminationStatus) {
            writers.completed(operation: operation, status: process.terminationStatus)
        }
        writers.release(generation: jobID); ended.signal()
    }
    do { try process.run() } catch { writers.release(generation: jobID); return .unreachable }
    _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
    DispatchQueue.global(qos: .utility).async {
        try? input.fileHandleForWriting.write(contentsOf: Data(encoded.utf8))
        try? input.fileHandleForWriting.close()
    }
    guard ended.wait(timeout: .now() + 15) == .success else { return .timeout }
    guard process.terminationReason == .exit, (0..<128).contains(process.terminationStatus),
          githubAuthSettled(ref) else { return .timeout }
    if process.terminationStatus == 36 { return .locked }
    return process.terminationStatus == 0 ? .success : .unreachable
}
private func githubAuthDelete(_ ref: GitHubAuthRef) -> GitHubAuthStoreStatus {
    if ref == GitHubAuthRef(generation: "legacy", backend: "legacy-keychain") { return githubAuthStatus(SecuritySyncKeychain(lifetime: githubAuthProcessFence).delete()) }
    guard githubAuthRefSafe(ref) else { return .failed }
    return githubAuthStatus(syncSecurity(["delete-generic-password", "-s", GITHUB_AUTH_SERVICE, "-a", ref.generation], lifetime: githubAuthProcessFence).status)
}
private func githubAuthAtomicSave(_ manifest: GitHubAuthManifest, path: String) throws {
    let directory = (path as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let temporary = directory + "/.github-auth-" + UUID().uuidString
    let data = try JSONEncoder().encode(manifest)
    let fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard fd >= 0 else { throw GitHubAuthPersistenceError.unavailable }
    var closed = false
    defer { if !closed { close(fd) }; unlink(temporary) }
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw GitHubAuthPersistenceError.unavailable }; offset += count
        }
    }
    guard fsync(fd) == 0 else { throw GitHubAuthPersistenceError.unavailable }
    close(fd); closed = true
    guard rename(temporary, path) == 0 else { throw GitHubAuthPersistenceError.unavailable }
    let dirFD = open(directory, O_RDONLY)
    guard dirFD >= 0 else { throw GitHubAuthPersistenceError.unavailable }
    defer { close(dirFD) }
    guard fsync(dirFD) == 0 else { throw GitHubAuthPersistenceError.unavailable }
}
private final class GitHubAuthTransportReply: @unchecked Sendable {
    let lock = NSLock()
    var value = GitHubAuthHTTP(status: 0, json: nil)
    func set(_ response: GitHubAuthHTTP) { lock.lock(); value = response; lock.unlock() }
    func get() -> GitHubAuthHTTP { lock.lock(); defer { lock.unlock() }; return value }
}
private func githubAuthOAuthTransport(_ fields: [String: String]) -> GitHubAuthHTTP {
    let endpoint = "https://github.com/login/oauth/access_token"
    guard syncOAuthEndpoint(endpoint), let url = URL(string: endpoint) else { return GitHubAuthHTTP(status: 0, json: nil, knownNotSent: true) }
    var request = URLRequest(url: url, timeoutInterval: 15)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.setValue("ClaudeCodexLimits", forHTTPHeaderField: "User-Agent")
    request.httpBody = Data(fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }.joined(separator: "&").utf8)
    let response = GitHubAuthTransportReply(), semaphore = DispatchSemaphore(value: 0)
    let session = URLSession(configuration: .ephemeral, delegate: SyncNoRedirects(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let task = session.dataTask(with: request) { data, reply, error in
        let http = reply as? HTTPURLResponse
        let e = error as NSError?
        // These transport failures prove there was no connection on which to send the
        // grant. Read timeouts, connection loss and cancellation are deliberately unknown.
        let notSent = http == nil && e?.domain == NSURLErrorDomain &&
            [NSURLErrorNotConnectedToInternet, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed,
             NSURLErrorCannotConnectToHost].contains(e?.code ?? 0)
        var headers: [String: String] = [:]
        for (key, value) in http?.allHeaderFields ?? [:] { headers[String(describing: key).lowercased()] = String(describing: value) }
        response.set(GitHubAuthHTTP(status: http?.statusCode ?? 0,
            json: data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] },
            headers: headers, knownNotSent: notSent))
        semaphore.signal()
    }
    task.resume()
    guard semaphore.wait(timeout: .now() + 20) == .success else { task.cancel(); return GitHubAuthHTTP(status: 0, json: nil) }
    return response.get()
}
private func makeProductionGitHubAuth() -> GitHubAuthOwner {
    let path = DATA_DIR + "/github-auth-state.json"
    let dependencies = GitHubAuthDependencies(
        clock: { Date().timeIntervalSince1970 },
        loadManifest: {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: path))
                let value = try JSONDecoder().decode(GitHubAuthManifest.self, from: data)
                guard value.formatVersion == 2 else { throw GitHubAuthPersistenceError.corrupt }; return value
            } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return nil }
        },
        saveManifest: { try githubAuthAtomicSave($0, path: path) },
        readStore: githubAuthRead, stageStore: githubAuthStage, deleteStore: githubAuthDelete,
        transport: githubAuthOAuthTransport, identity: { token in
            let r = syncHTTP("https://api.github.com/user", "GET",
                ["Authorization": "Bearer \(token)", "Accept": "application/vnd.github+json", "User-Agent": "ClaudeCodexLimits"], nil, 20)
            if r.status == 401 { return .unauthorized }
            guard r.status == 200, let data = r.data,
                  let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let id = j["id"] as? NSNumber, CFGetTypeID(id) != CFBooleanGetTypeID(),
                  id.doubleValue.isFinite, id.doubleValue > 0,
                  let login = j["login"] as? String, !login.isEmpty else { return .temporary }
            return .ready(userID: id.stringValue, login: login)
        }, withLock: { body in
            try FileManager.default.createDirectory(atPath: DATA_DIR, withIntermediateDirectories: true)
            let fd = open(DATA_DIR + "/github-auth.lock", O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { throw GitHubAuthPersistenceError.unavailable }
            defer { close(fd) }
            // A crashed process releases flock. Bound contention without ever proceeding unlocked.
            let deadline = Date().addingTimeInterval(60)
            while flock(fd, LOCK_EX | LOCK_NB) != 0 {
                guard (errno == EWOULDBLOCK || errno == EINTR), Date() < deadline else { throw GitHubAuthPersistenceError.unavailable }
                Thread.sleep(forTimeInterval: 0.05)
            }
            defer { flock(fd, LOCK_UN) }; try body()
        }, checkpoint: { _, _, _ in }, jitter: { Double.random(in: 0...15) }, legacy: {
            let d = UserDefaults.standard
            if d.bool(forKey: "syncRevoked") { return .revoked }
            guard let login = d.string(forKey: "syncLogin") else { return .signedOut }
            switch SecuritySyncKeychain(lifetime: githubAuthProcessFence).read() {
            case .token(let token): return .ready(GitHubCredentialV2(epoch: "legacy", generation: "legacy", accessToken: token,
                refreshToken: nil, obtainedAt: 0, login: login))
            case .missing: return .missing
            case .timedOut: return .timeout
            case .failure(let code): return code == 36 ? .locked : .unreachable
            }
        }, settled: githubAuthSettled, storeIdle: { githubAuthProcessFence.isIdle })
    return GitHubAuthOwner(dependencies: dependencies, clientID: GITHUB_CLIENT_ID)
}

func githubAuthMessage(_ reason: String, language: String) -> String {
    let english = language == "en"
    switch reason {
    case "cleanup_pending": return english ? "Signed out here; secure-storage cleanup is pending. Retrying automatically." : "Вход на этом компьютере отключён; очистка хранилища ещё не завершена. Повторим автоматически."
    case "login_incomplete": return english ? "Sign-in was not completed. Try signing in again." : "Вход не завершён. Попробуйте войти заново."
    case "renewing": return english ? "Renewing GitHub sign-in automatically…" : "Автоматически продлеваем вход в GitHub…"
    case "missing": return english ? "Sign-in is missing from secure storage. Sign in again." : "Вход не найден в защищённом хранилище. Войдите заново."
    case "lost_result": return english ? "Couldn't recover the renewal result. Sign in again." : "Не удалось восстановить результат продления. Войдите заново."
    case "bad_refresh_token", "refresh_expired", "access_expired", "revoked": return english ? "GitHub sign-in needs renewal. Sign in again." : "Необходимо обновить вход в GitHub. Войдите заново."
    case "incomplete_candidate", "identity_changed", "corrupt": return english ? "Couldn't verify the saved sign-in. Sign in again." : "Не удалось проверить сохранённый вход. Войдите заново."
    case "locked": return english ? "Unlock Keychain; sign-in will recover automatically." : "Разблокируйте Связку ключей; вход восстановится автоматически."
    case "unreachable": return english ? "No access to Keychain. Retrying automatically." : "Нет доступа к Связке ключей. Повторим автоматически."
    case "timeout": return english ? "Keychain did not respond. Retrying automatically." : "Связка ключей не ответила. Повторим автоматически."
    case "response_unknown": return english ? "Renewal response is unavailable; checking saved sign-in." : "Ответ продления недоступен; проверяем сохранённый вход."
    case "identity_unavailable", "candidate_unauthorized", "login_pending": return english ? "Sign-in is saved; waiting for GitHub verification." : "Вход сохранён; ждём проверки GitHub."
    default: return english ? "Sign-in is temporarily unavailable; retrying automatically." : "Вход временно недоступен; повторим автоматически."
    }
}

// Pure deadline admission; all runtime state is owned by GitHubSync.q.
// The short retry floor handles a still-terminating child or an owner-busy pass;
// it never replaces or extends the owner's monotonic storage cooldown.
enum KeychainRetryDecision: Equatable { case cancel, keep, arm(Double), retry }
struct KeychainRetryDeadline {
    private var deadline: Double?
    private var retryNotBefore: Double = 0
    static let busyRecheck: Double = 30

    mutating func update(remaining: Double?, now: Double, fired: Bool = false,
                         force: Bool = false, storeIdle: Bool = true) -> KeychainRetryDecision {
        guard let remaining = remaining, remaining.isFinite, now.isFinite else {
            deadline = nil; retryNotBefore = 0
            return .cancel
        }
        if fired && remaining <= 0 && now >= retryNotBefore {
            retryNotBefore = now + Self.busyRecheck
            deadline = nil
            if storeIdle { return .retry }
            deadline = retryNotBefore
            return .arm(Self.busyRecheck)
        }
        let target = max(now + max(0, remaining), retryNotBefore)
        if !fired && !force, let deadline = deadline, abs(deadline - target) < 0.05 { return .keep }
        deadline = target
        return .arm(max(0.01, target - now))
    }
}

final class GitHubSync {
    static let shared = GitHubSync(authOwner: makeProductionGitHubAuth())
    private let q = DispatchQueue(label: "ccl.sync", qos: .utility)
    private let lock = NSLock()
    private var _ui = SyncUIState()
    private var _remote = SyncRemoteCache()
    private var loginID: UUID?
    private var loginEpoch: (id: UUID, epoch: String)?
    private(set) var verifyURL = "https://github.com/login/device"
    private var backoffUntil = Date.distantPast
    private var keychainBackoffUntil = Date.distantPast
    private var retryWork: DispatchWorkItem?
    private var transientFailure = false
    private var keychainRetryDeadline = KeychainRetryDeadline()
    private var keychainRetryWork: DispatchWorkItem?
    private var keychainRetryID: UUID?
    var onChange: (() -> Void)?
    // Offline race tests only; checkpoints run on q, outside the UI lock.
    var selfTestLoginCheckpoint: ((String) -> Void)?
    private func loginCheckpoint(_ point: String) {
        if CommandLine.arguments.contains("--sync-selftest") { selfTestLoginCheckpoint?(point) }
    }

    private let authOwner: GitHubAuthOwner?
    private var keychainManualRetryPending = false // guarded by UI lock, including queue wait
    // Scheduler owner consumes this delay and rechecks it after wake; no wall-clock conversion.
    var keychainRetryDelay: Double? { authOwner?.keychainRetryDelay() }
    func retryKeychainAccess() {
        guard let owner = authOwner else { return }
        lock.lock()
        guard !keychainManualRetryPending else { lock.unlock(); return }
        keychainManualRetryPending = true; lock.unlock()
        q.async {
            defer { self.lock.lock(); self.keychainManualRetryPending = false; self.lock.unlock() }
            _ = self.projectAuth(owner.retryKeychainAccess())
        }
    }
    private var capturedAccess: GitHubAuthAccess?
    private let transport: SyncHTTP
    private let keychain: SyncKeychain
    private let defaults: UserDefaults
    private let remotePath: String
    private let suppliedMachineId: String?
    private let revokeRecheckDelay: TimeInterval
    private var machineIdNeedsSave = false

    init(transport: @escaping SyncHTTP = syncHTTP,
         keychain: SyncKeychain = SecuritySyncKeychain(), defaults: UserDefaults = .standard,
         remotePath: String = SYNC_REMOTE_PATH, machineId: String? = nil, revokeRecheckDelay: TimeInterval = 4,
         authOwner: GitHubAuthOwner? = nil) {
        self.authOwner = authOwner
        self.transport = transport; self.keychain = keychain; self.defaults = defaults
        self.remotePath = remotePath; self.suppliedMachineId = machineId
        self.revokeRecheckDelay = revokeRecheckDelay
        _ui.login = defaults.string(forKey: "syncLogin")
        _ui.phase = defaults.bool(forKey: "syncRevoked") ? .revoked : (_ui.login == nil ? .off : .on)
        _ui.lastSync = defaults.object(forKey: "syncLastOkAt") as? Date
        _ui.lastAttemptAt = defaults.object(forKey: "syncLastAttemptAt") as? Date
        _ui.lastUploadAt = defaults.object(forKey: "syncPushedAt") as? Date
        _ui.lastError = defaults.string(forKey: "syncLastError")
        _ui.lastErrorAt = defaults.object(forKey: "syncLastErrorAt") as? Date
    }

    var ui: SyncUIState { lock.lock(); defer { lock.unlock() }; return _ui }
    func remoteDays() -> [String: [String: [String: DayModelUsage]]] {
        let snapshot = authOwner?.snapshot() // Nonsecret memory snapshot; no credential I/O.
        lock.lock(); defer { lock.unlock() }
        return _ui.phase == .on && syncCacheMatches(_remote, snapshot: snapshot) ? _remote.days : [:]
    }
    /// `f` runs under the lock — it must not call anything that takes the lock again
    /// (machineList(), ui, remoteDays()); compute those first and capture the values.
    private func setUI(_ f: (inout SyncUIState) -> Void) {
        lock.lock(); f(&_ui); lock.unlock()
        DispatchQueue.main.async { self.onChange?() }
    }

    lazy var machineId: String = {
        if let id = suppliedMachineId { return id }
        if let s = try? String(contentsOfFile: MACHINE_ID_PATH, encoding: .utf8) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        let id = UUID().uuidString.lowercased()
        machineIdNeedsSave = true   // Persist only in a real sync cycle; selftest stays read-only.
        return id
    }()
    lazy var machineName: String = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    var osName: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion)"
    }

    /// Restore the last known state at launch, so the history shows other machines offline.
    func load() { q.async { self.loadSynchronously() } }

    /// For isolated callers without a run loop; do not overlap with queued operations.
    func loadSynchronously() {
        let d = defaults
        if let owner = authOwner {
            let result = owner.ensureAccess(reason: "startup")
            var cache = SyncRemoteCache()
            if let data = try? Data(contentsOf: URL(fileURLWithPath: remotePath)),
               let loaded = try? JSONDecoder().decode(SyncRemoteCache.self, from: data),
               syncCacheMatches(loaded, snapshot: owner.snapshot()) { cache = loaded }
            lock.lock(); _remote = cache; lock.unlock()
            _ = projectAuth(result)
            return
        }
        if let data = try? Data(contentsOf: URL(fileURLWithPath: remotePath)),
           let c = try? JSONDecoder().decode(SyncRemoteCache.self, from: data) {
            lock.lock(); _remote = c; lock.unlock()
        }
        // «Revoked» wins over a token still in the Keychain: a confirmed-dead token may stay
        // there when its deletion timed out. Only a new sign-in clears the flag.
        // A missing token with a known login needs a new sign-in; transient Keychain
        // failures stay «on» so the next cycle can retry.
        let phase: SyncPhase
        var keychainError: String? = nil
        let result = readKeychain()
        let itemLeft: Bool
        if case .missing = result { itemLeft = false } else { itemLeft = true }
        if d.bool(forKey: "syncRevoked") { phase = .revoked }
        else {
            if d.string(forKey: "syncLogin") == nil { phase = .off }
            else if case .token = result { phase = .on }
            else {
                if case .missing = result { phase = .revoked } else { phase = .on }
                keychainError = syncKeychainReadError(result)
            }
        }
        let ms = machineList()
        setUI {
            if $0.phase != .awaitingCode { $0.phase = phase }
            $0.login = d.string(forKey: "syncLogin"); $0.machines = ms
            $0.keychainItemLeft = itemLeft
        }
        if let e = keychainError { recordError(e) }
    }

    /// Only nonsecret snapshots reach rendering. All owner/store I/O runs on the sync queue.
    @discardableResult private func projectAuth(_ result: GitHubAuthResult) -> String? {
        guard let owner = authOwner else { return nil }
        let snapshot = owner.snapshot()
        setUI { $0.keychainRetryAvailable = owner.keychainRetryDelay() != nil }
        let ms = machineList()
        switch result {
        case .ready(let access):
            capturedAccess = access
            if let login = snapshot.login { defaults.set(login, forKey: "syncLogin") }
            defaults.set(false, forKey: "syncRevoked")
            setUI { state in
                if state.phase != .awaitingCode { state.phase = .on }
                state.login = snapshot.login; state.authState = snapshot.state
                state.authReason = snapshot.reason; state.keychainItemLeft = true; state.machines = ms
            }
            return access.token
        case .signedOut:
            capturedAccess = nil
            setUI {
                if $0.phase != .awaitingCode { $0.phase = .off }
                $0.authState = "signedOut"; $0.authReason = snapshot.reason
                $0.keychainItemLeft = snapshot.cleanupPending; $0.login = nil
                $0.error = snapshot.cleanupPending ? githubAuthMessage("cleanup_pending", language: appLang()) : nil
            }
        case .temporary(let reason), .actionRequired(let reason):
            capturedAccess = nil
            let action: Bool
            if case .actionRequired = result { action = true } else { action = false }
            setUI {
                if $0.phase != .awaitingCode { $0.phase = action ? .revoked : .on }
                $0.login = snapshot.login ?? $0.login; $0.authState = snapshot.state
                $0.authReason = reason; $0.keychainItemLeft = snapshot.hasCredential; $0.machines = ms
            }
            recordError(githubAuthMessage(reason, language: appLang()))
        }
        return nil
    }

    private func machineList() -> [SyncMachine] {
        let snapshot = authOwner?.snapshot()
        lock.lock(); let r = syncCacheMatches(_remote, snapshot: snapshot) ? _remote : SyncRemoteCache(); lock.unlock()
        let pushed = defaults.object(forKey: "syncPushedAt") as? Date
        var out = [SyncMachine(name: machineName, os: osName, updated: pushed, isSelf: true)]
        out += r.machines.sorted { $0.name < $1.name }.map { SyncMachine(name: $0.name, os: $0.os, updated: $0.updated, isSelf: false) }
        return out
    }

    private func gh(_ path: String, _ method: String = "GET", token: String, body: Any? = nil) -> (status: Int, json: Any?, headers: [String: String], err: String?) {
        let c = URLComponents(string: path)
        let url = c?.scheme == nil && c?.host == nil && path.first == "/" ? "https://api.github.com" + path : path
        guard syncAPIOrigin(url) else { return (0, nil, [:], "GitHub API origin required") }
        let currentToken: String
        if let owner = authOwner {
            guard let value = projectAuth(owner.ensureAccess(reason: "api")) else { return (0, nil, [:], "Sign-in unavailable") }
            currentToken = value
        } else { currentToken = token }
        var h = ["Authorization": "Bearer \(currentToken)", "Accept": "application/vnd.github+json",
                 "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "ClaudeCodexLimits"]
        var data: Data? = nil
        if let b = body { data = try? JSONSerialization.data(withJSONObject: b); h["Content-Type"] = "application/json" }
        let r = transport(url, method, h, data, 20)
        return (r.status, r.data.flatMap { try? JSONSerialization.jsonObject(with: $0) }, r.headers, r.err)
    }

    // MARK: sign-in (OAuth Device Flow)

    func startLogin() {
        let id = UUID()
        setUI { loginID = id; $0.phase = .awaitingCode; $0.userCode = nil; $0.error = nil }
        q.async { self.runLogin(id) }
    }
    private var cancelledLoginPhase: SyncPhase {
        defaults.bool(forKey: "syncRevoked") || defaults.string(forKey: "syncLogin") != nil ? .revoked : .off
    }
    func cancelLogin() {
        let hadLogin = ui.phase == .awaitingCode
        setUI {
            guard loginID != nil else { return }
            let phase = cancelledLoginPhase
            loginID = nil; $0.phase = phase; $0.userCode = nil
        }
        if hadLogin, let owner = authOwner { q.async {
            if let captured = self.loginEpoch { _ = owner.cancelLogin(epoch: captured.epoch) }
            _ = self.projectAuth(owner.ensureAccess(reason: "cancel"))
        } }
    }
    private func loginIsCurrent(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }; return loginID == id
    }
    private func loginFailed(_ id: UUID, _ error: String) {
        if let owner = authOwner, let captured = loginEpoch, captured.id == id {
            _ = owner.abortLogin(epoch: captured.epoch)
        }
        let phase = cancelledLoginPhase
        let keychainPaused = authOwner?.keychainRetryDelay() != nil
        let snapshot = authOwner?.snapshot()
        setUI {
            guard loginID == id else { return }
            loginID = nil; $0.phase = phase; $0.userCode = nil; $0.error = error
            if keychainPaused {
                $0.keychainRetryAvailable = true; $0.authReason = snapshot?.reason
                $0.keychainItemLeft = snapshot?.hasCredential ?? $0.keychainItemLeft
                $0.error = githubAuthMessage(snapshot?.reason ?? "unreachable", language: appLang())
            }
        }
    }
    private func form(_ url: String, _ fields: [String: String]) -> [String: Any]? {
        guard syncOAuthEndpoint(url) else { return nil }
        let body = fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0.value)" }.joined(separator: "&")
        let r = transport(url, "POST", ["Accept": "application/json", "User-Agent": "ClaudeCodexLimits",
                                                  "Content-Type": "application/x-www-form-urlencoded"], Data(body.utf8), 15)
        guard (200..<300).contains(r.status) else { return nil }
        return r.data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }
    private func runLogin(_ id: UUID) {
        guard loginIsCurrent(id) else { return }
        let authEpoch = authOwner?.beginLogin()
        loginEpoch = authEpoch.map { (id: id, epoch: $0) }
        if authOwner != nil && authEpoch == nil {
            loginFailed(id, githubAuthMessage("storage_unavailable", language: appLang())); return
        }
        if authEpoch != nil {
            // An explicit account change cannot reuse another account's gist or totals,
            // including while a durably saved candidate waits for identity validation.
            for key in ["syncLogin", "syncGistId", "syncPushHash", "syncDiscoveredAt", "syncPushedAt", "syncLastOkAt", "syncRevoked"] { defaults.removeObject(forKey: key) }
            lock.lock(); _remote = SyncRemoteCache(); lock.unlock()
            try? FileManager.default.removeItem(atPath: remotePath)
            setUI { $0.login = nil; $0.machines = []; $0.lastSync = nil; $0.lastUploadAt = nil }
        }
        guard let j = form("https://github.com/login/device/code", ["client_id": GITHUB_CLIENT_ID, "scope": "gist offline_access"]),
              let deviceCode = j["device_code"] as? String, let userCode = j["user_code"] as? String else {
            loginFailed(id, tr("GitHub не ответил. Попробуйте ещё раз.", "GitHub didn't answer. Try again."))
            return
        }
        guard loginIsCurrent(id) else { return }
        // Do not open an issuer-supplied arbitrary URL.
        verifyURL = "https://github.com/login/device"
        var interval = (j["interval"] as? Double) ?? 5
        let deadline = Date().addingTimeInterval((j["expires_in"] as? Double) ?? 900)
        setUI { if loginID == id { $0.userCode = userCode } }
        while loginIsCurrent(id), Date() < deadline {
            Thread.sleep(forTimeInterval: interval)
            guard loginIsCurrent(id) else { return }
            guard let t = form("https://github.com/login/oauth/access_token",
                               ["client_id": GITHUB_CLIENT_ID, "device_code": deviceCode,
                                "grant_type": "urn:ietf:params:oauth:grant-type:device_code"]) else { continue }
            guard loginIsCurrent(id) else { return }
            if let owner = authOwner, let epoch = authEpoch, t["access_token"] != nil || t["refresh_token"] != nil {
                let result = owner.completeLogin(response: t, epoch: epoch, isCurrent: { self.loginIsCurrent(id) })
                guard loginIsCurrent(id) else { _ = owner.cancelLogin(epoch: epoch); return }
                setUI { loginID = nil; $0.userCode = nil; $0.error = nil; $0.phase = .on }
                if projectAuth(result) != nil { syncBody(force: true) }
                return
            }
            if let token = t["access_token"] as? String {
                let me = gh("/user", token: token)
                // Cancellation while /user was in flight must never save the issued token.
                guard loginIsCurrent(id) else { return }
                guard me.status == 200, let login = (me.json as? [String: Any])?["login"] as? String, !login.isEmpty else {
                    loginFailed(id, tr("GitHub не ответил. Попробуйте ещё раз.", "GitHub didn't answer. Try again."))
                    return
                }
                guard loginIsCurrent(id) else { return }
                let saved = writeKeychain(token, userInitiated: true)
                // A cancelled login may have written a token without publishing syncLogin.
                // Never delete a newer login's token, and never do Keychain work in setUI.
                func removeUnpublishedToken() {
                    // Without a published login, the serial queue owns any leftover item.
                    if defaults.string(forKey: "syncLogin") != nil {
                        switch readKeychain(userInitiated: true) {
                        case .token(let s) where s == token: break
                        case .missing:
                            setUI { $0.keychainItemLeft = false }; return
                        case .token, .timedOut, .failure:
                            setUI { $0.keychainItemLeft = true }; return
                        }
                    }
                    let result = deleteKeychain(userInitiated: true)
                    setUI { $0.keychainItemLeft = result != .success && result != .missing }
                }
                loginCheckpoint("afterWrite")
                guard loginIsCurrent(id) else { removeUnpublishedToken(); return }
                let verified = saved == .success ? readKeychain(userInitiated: true) : .missing
                loginCheckpoint("afterRead")
                guard loginIsCurrent(id) else { removeUnpublishedToken(); return }
                guard saved == .success, case .token(let stored) = verified, stored == token else {
                    loginFailed(id, saved == .timedOut ? syncKeychainTimeout() : tr("Не удалось сохранить вход в Связку ключей.", "Couldn't save the sign-in to the Keychain."))
                    return
                }
                let d = defaults
                let ms = machineList()
                var published = false
                loginCheckpoint("beforePublish")
                setUI {
                    guard loginID == id else { return }
                    d.set(login, forKey: "syncLogin"); d.set(false, forKey: "syncRevoked")
                    loginID = nil; $0.phase = .on; $0.login = login; $0.userCode = nil; $0.error = nil; $0.machines = ms
                    $0.keychainItemLeft = true; published = true
                }
                guard published else { removeUnpublishedToken(); return }
                syncBody(force: true)
                return
            }
            switch t["error"] as? String {
            case "authorization_pending": continue
            case "slow_down": interval += 5
            case "access_denied":
                loginFailed(id, tr("Вход отклонён в GitHub.", "Sign-in was declined on GitHub."))
                return
            default:
                loginFailed(id, tr("Код устарел. Попробуйте ещё раз.", "The code expired. Try again."))
                return
            }
        }
        loginFailed(id, tr("Код устарел. Попробуйте ещё раз.", "The code expired. Try again."))
    }

    func logout() {
        setUI { _ in loginID = nil }
        q.async {
            if let owner = self.authOwner {
                let result = owner.logoutDetailed()
                guard result.accessDisabled else { self.recordError(githubAuthMessage("storage_unavailable", language: appLang())); return }
                // Physical deletion can remain pending while the durable tombstone already
                // disables every old ref. A fresh explicit login uses a new epoch/ref.
            }
            let result = self.authOwner == nil ? self.deleteKeychain(userInitiated: true) : .success
            guard result == .success || result == .missing else {
                self.recordError(result == .timedOut ? syncKeychainTimeout() : tr("Не удалось удалить вход из Связки ключей", "Couldn't delete the sign-in from Keychain"))
                return
            }
            let d = self.defaults
            for k in ["syncLogin", "syncGistId", "syncPushHash", "syncPushedAt", "syncRevoked", "syncDiscoveredAt", "syncLastOkAt", "syncLastAttemptAt", "syncLastError", "syncLastErrorAt"] { d.removeObject(forKey: k) }
            self.lock.lock(); self._remote = SyncRemoteCache(); self.lock.unlock()
            try? FileManager.default.removeItem(atPath: self.remotePath)
            self.setUI { $0 = SyncUIState() }
            if self.authOwner != nil { _ = self.projectAuth(.signedOut) }
        }
    }

    private func recordError(_ message: String) {
        let now = Date()
        defaults.set(message, forKey: "syncLastError"); defaults.set(now, forKey: "syncLastErrorAt")
        let pushed = defaults.object(forKey: "syncPushedAt") as? Date
        setUI { $0.lastError = message; $0.lastErrorAt = now; $0.lastUploadAt = pushed }
    }

    private func keychainTimedOut() {
        keychainBackoffUntil = Date().addingTimeInterval(SYNC_KEYCHAIN_BACKOFF)
        recordError(syncKeychainTimeout())
    }

    private func readKeychain(userInitiated: Bool = false) -> SyncKeychainRead {
        guard userInitiated || Date() >= keychainBackoffUntil else { return .timedOut }
        let result = keychain.read()
        if userInitiated {
            switch result {
            case .token, .missing: keychainBackoffUntil = .distantPast
            default: break
            }
        }
        if case .timedOut = result { keychainTimedOut() }
        return result
    }

    private func writeKeychain(_ token: String, userInitiated: Bool = false) -> SyncKeychainStatus {
        guard userInitiated || Date() >= keychainBackoffUntil else { return .timedOut }
        let result = keychain.write(token)
        if userInitiated && result == .success { keychainBackoffUntil = .distantPast }
        if result == .timedOut { keychainTimedOut() }
        return result
    }

    private func deleteKeychain(userInitiated: Bool = false) -> SyncKeychainStatus {
        guard userInitiated || Date() >= keychainBackoffUntil else { return .timedOut }
        let result = keychain.delete()
        if userInitiated && (result == .success || result == .missing) { keychainBackoffUntil = .distantPast }
        if result == .timedOut { keychainTimedOut() }
        return result
    }

    /// Two `GET /user` calls answered 401 with `token`. The Keychain item is
    /// deleted only when it still holds exactly that token; a different token there means a
    /// newer sign-in, so nothing is revoked and the next cycle uses it.
    private func revoked(token: String) {
        let current = readKeychain()
        if case .token(let stored) = current, stored != token {
            recordError(syncKeychainReadError(current)); return
        }
        // Persist the revoked state and publish the phase before a potentially slow delete.
        let d = defaults
        d.set(true, forKey: "syncRevoked"); d.removeObject(forKey: "syncGistId"); d.removeObject(forKey: "syncPushHash")
        d.removeObject(forKey: "syncDiscoveredAt")
        setUI { $0.phase = .revoked; $0.keychainItemLeft = true }
        var note = tr("Вход в GitHub отозван", "GitHub sign-in revoked")
        recordError(note)
        var itemLeft = true
        switch current {
        case .token:
            let result = deleteKeychain()
            itemLeft = result != .success && result != .missing
            if result != .success && result != .missing {
                note += " · " + (result == .timedOut ? syncKeychainTimeout() : tr("не удалось удалить вход из Связки ключей", "couldn't delete the sign-in from Keychain"))
            }
        case .missing:
            itemLeft = false
        case .timedOut, .failure:
            // Can't tell which token is stored, so it stays; syncRevoked keeps it unused.
            note += " · " + syncKeychainReadError(current)
        }
        setUI { $0.keychainItemLeft = itemLeft }
        recordError(note)
    }

    /// true = stop this cycle. A gist 401 alone never proves token revocation.
    private func handle(_ status: Int, headers: [String: String] = [:], request: String, token: String?) -> Bool {
        if status == 0 || (500...599).contains(status) { transientFailure = true }
        if status == 401, let token = token {
            if let owner = authOwner, let access = capturedAccess, access.refreshable {
                let result = owner.ensureAccess(reason: "unauthorized")
                if projectAuth(result) != nil { transientFailure = true }
                return true
            }
            var me = gh("/user", token: token)
            if me.status == 401 {
                Thread.sleep(forTimeInterval: revokeRecheckDelay)
                me = gh("/user", token: token)
            }
            switch me.status {
            case 200: recordError(tr("401 на \(request), вход подтверждён", "401 on \(request), sign-in confirmed"))
            case 401:
                if let owner = authOwner, let access = capturedAccess, access.epoch != "legacy" {
                    _ = owner.confirmedUnauthorized(access)
                    _ = projectAuth(.actionRequired("revoked"))
                } else { revoked(token: token) }
            default:
                // Couldn't confirm either way (network, 5xx, rate limit): keep the token, retry.
                if me.status == 0 || (500...599).contains(me.status) { transientFailure = true }
                applyBackoff(me.status, headers: me.headers)
                recordError(tr("401 на \(request), проверка входа не прошла (\(GitHubSync.statusText(me.status, headers: me.headers)))",
                               "401 on \(request), sign-in check failed (\(GitHubSync.statusText(me.status, headers: me.headers)))"))
            }
            return true
        }
        applyBackoff(status, headers: headers)
        guard status == 200 || status == 201 else {
            let detail = GitHubSync.statusText(status, headers: headers)
            recordError("\(request): \(detail)"); return true
        }
        return false
    }

    /// Status for a human: 0 is a transport failure (no network, timeout), not an HTTP code.
    static func statusText(_ status: Int, headers: [String: String] = [:]) -> String {
        if status == 403 && !rateLimited(status, headers: headers) { return tr("доступ запрещён (403)", "access denied (403)") }
        return status == 0 ? tr("нет связи с GitHub", "no connection to GitHub") : tr("ответ \(status)", "HTTP \(status)")
    }

    private static func normalizedHeaders(_ headers: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in headers { result[key.lowercased()] = value.trimmingCharacters(in: .whitespacesAndNewlines) }
        return result
    }

    private static func rateLimited(_ status: Int, headers: [String: String]) -> Bool {
        let h = normalizedHeaders(headers)
        return status == 429 || (status == 403 && (h["retry-after"] != nil || h["x-ratelimit-remaining"] == "0"))
    }

    private func applyBackoff(_ status: Int, headers: [String: String]) {
        guard GitHubSync.rateLimited(status, headers: headers) else { return }
        let h = GitHubSync.normalizedHeaders(headers), now = Date()
        var delay: TimeInterval = 15 * 60
        if let raw = h["retry-after"], let seconds = Double(raw), seconds.isFinite, seconds >= 0 {
            delay = seconds
        } else if h["x-ratelimit-remaining"] == "0", let raw = h["x-ratelimit-reset"],
                  let reset = Double(raw), reset.isFinite, reset >= 0 {
            delay = max(0, reset - now.timeIntervalSince1970)
        }
        backoffUntil = now.addingTimeInterval(min(delay, 60 * 60))
    }

    // One relative deadline on the existing serial sync queue; UI changes only
    // request a recheck. Stale/cancelled callbacks cannot admit another pass.
    func recheckKeychainRetry(afterWake: Bool = false) {
        q.async { self.updateKeychainRetry(force: afterWake) }
    }

    private func updateKeychainRetry(fired: Bool = false, force: Bool = false) {
        let decision = keychainRetryDeadline.update(
            remaining: keychainRetryDelay,
            now: authOwner?.dependencies.monotonicClock() ?? 0,
            fired: fired, force: force,
            storeIdle: authOwner?.dependencies.storeIdle() ?? true)
        if decision == .keep { return }
        keychainRetryWork?.cancel(); keychainRetryWork = nil; keychainRetryID = nil
        switch decision {
        case .cancel, .keep: break
        case .arm(let delay):
            let id = UUID()
            keychainRetryID = id
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, self.keychainRetryID == id else { return }
                self.keychainRetryWork = nil; self.keychainRetryID = nil
                self.updateKeychainRetry(fired: true)
            }
            keychainRetryWork = work
            q.asyncAfter(deadline: .now() + delay, execute: work)
        case .retry:
            // Existing recovery/sync path owns single flight and network backoff.
            // No manual bypass. A still-zero owner delay gets a bounded recheck.
            syncBody(force: false)
            updateKeychainRetry()
        }
    }

    // MARK: push + pull

    func syncNow(force: Bool = false) { q.async { self.syncBody(force: force) } }

    /// Synchronous test seam; use injected dependencies and do not overlap with q work.
    func syncSynchronously(force: Bool = false) { syncBody(force: force, allowRetry: false) }

    private func snapshotJSON() -> (days: [String: Any], hash: String) {
        let ix = UsageLogs.shared.snapshot()
        let cutoff = dayKey(Date().addingTimeInterval(-SYNC_KEEP_DAYS * 86400))
        var days: [String: Any] = [:]
        for (p, byDay) in ix.days where productEnabled(p, defaults: defaults) {
            var pd: [String: Any] = [:]
            for (day, byModel) in byDay where day >= cutoff {
                var md: [String: Any] = [:]
                for (m, u) in byModel {
                    md[m] = ["input": u.input, "output": u.output, "cacheRead": u.cacheRead,
                             "cacheWrite5m": u.cacheWrite5m, "cacheWrite1h": u.cacheWrite1h, "turns": u.turns]
                }
                pd[day] = md
            }
            days[p] = pd
        }
        let data = (try? JSONSerialization.data(withJSONObject: days, options: [.sortedKeys])) ?? Data()
        return (days, String(fnv64(String(decoding: data, as: UTF8.self)), radix: 16))
    }
    private func machineFile(_ days: [String: Any]) -> String {
        let iso = ISO8601DateFormatter()
        let obj: [String: Any] = [
            "schema": 1,
            "machine": ["id": machineId, "name": machineName, "os": osName, "app": "macos " + APP_VERSION],
            "updated": iso.string(from: Date()),
            "tz": TimeZone.current.identifier,
            "days": days,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Oldest gist holding the manifest, or nil. Errors are recorded here; `failed` = stop the cycle.
    private func findGist(_ token: String) -> (id: String?, failed: Bool) {
        var best: (id: String, created: String)?
        for page in 1...10 {
            let r = gh("/gists?per_page=100&page=\(page)", token: token)
            if handle(r.status, headers: r.headers, request: "GET /gists?page=\(page)", token: token) { return (nil, true) }
            guard let arr = r.json as? [[String: Any]] else {
                recordError(tr("Некорректный ответ GET /gists", "Invalid GET /gists response")); return (nil, true)
            }
            for g in arr {
                guard syncIsPrivate(g["public"]), let files = g["files"] as? [String: Any], files[SYNC_MANIFEST] != nil,
                      let id = g["id"] as? String else { continue }
                let created = g["created_at"] as? String ?? ""
                if best == nil || created < best!.created { best = (id, created) }
            }
            if arr.count < 100 { break }
        }
        return (best?.id, false)
    }

    private func syncBody(force: Bool, allowRetry: Bool = true) {
        let ownedToken: String?
        if let owner = authOwner {
            ownedToken = projectAuth(owner.ensureAccess(reason: "sync"))
            guard ownedToken != nil, ui.phase != .awaitingCode, Date() >= backoffUntil else { return }
        } else {
            ownedToken = nil
            guard ui.phase == .on, Date() >= backoffUntil, Date() >= keychainBackoffUntil else { return }
        }
        let cycleAccess = capturedAccess
        let cycleBinding = authOwner?.snapshot()
        retryWork?.cancel(); retryWork = nil
        transientFailure = false
        defer {
            if allowRetry && transientFailure {
                let retry = DispatchWorkItem { [weak self] in self?.syncBody(force: force, allowRetry: false) }
                retryWork = retry
                q.asyncAfter(deadline: .now() + 60, execute: retry)
            }
        }
        let d = defaults, attempt = Date()
        d.set(attempt, forKey: "syncLastAttemptAt")
        setUI { $0.lastAttemptAt = attempt; if $0.firstAttemptAt == nil { $0.firstAttemptAt = attempt } }
        let credential: SyncKeychainRead = ownedToken.map { .token($0) } ?? readKeychain()
        guard case .token(let token) = credential else {
            if case .missing = credential, d.string(forKey: "syncLogin") != nil { setUI { $0.phase = .revoked } }
            recordError(syncKeychainReadError(credential)); return
        }
        let snap = snapshotJSON()
        let myFile = "machine-\(machineId).json"
        if machineIdNeedsSave {
            do {
                try FileManager.default.createDirectory(atPath: DATA_DIR, withIntermediateDirectories: true)
                try (machineId + "\n").write(toFile: MACHINE_ID_PATH, atomically: true, encoding: .utf8)
                machineIdNeedsSave = false
            } catch { /* Keep machineIdNeedsSave set for the next cycle. */ }
        }

        var gistId = d.string(forKey: "syncGistId")
        // Earliest-created wins must keep being applied, not only on first discovery: two
        // machines that each created a gist would otherwise never see each other's files
        // (issue #3). Re-check once a day; on a switch, forget the push hash so our file is
        // written into the gist we moved to.
        if let cur = gistId {
            let last = d.object(forKey: "syncDiscoveredAt") as? Date ?? .distantPast
            if Date().timeIntervalSince(last) > 86400 {
                let f = findGist(token)
                if f.failed { return }
                d.set(Date(), forKey: "syncDiscoveredAt")
                if let id = f.id, id != cur {
                    gistId = id
                    d.set(id, forKey: "syncGistId")
                    d.removeObject(forKey: "syncPushHash")
                }
            }
        }
        if gistId == nil {
            d.removeObject(forKey: "syncPushHash")
            let f = findGist(token)
            if f.failed { return }
            if let id = f.id { gistId = id }
            else {
                let manifest = "{\"about\":\"https://github.com/ArrivaRUS/claude-codex-limits/blob/main/docs/sync-protocol.md\",\"created\":\"\(ISO8601DateFormatter().string(from: Date()))\",\"schema\":1}"
                let c = gh("/gists", "POST", token: token, body: [
                    "description": "Claude Codex Limits — usage sync (do not edit)", "public": false,
                    "files": [SYNC_MANIFEST: ["content": manifest], myFile: ["content": machineFile(snap.days)]]])
                if handle(c.status, headers: c.headers, request: "POST /gists", token: token) { return }
                guard let id = (c.json as? [String: Any])?["id"] as? String else {
                    recordError(tr("Некорректный ответ POST /gists", "Invalid POST /gists response")); return
                }
                gistId = id
                d.set(snap.hash, forKey: "syncPushHash"); d.set(Date(), forKey: "syncPushedAt")
                // Did another machine create one at the same moment? Converge on the earliest.
                let again = findGist(token)
                if again.failed { return }
                if let a = again.id, a != id {
                    gistId = a
                    d.removeObject(forKey: "syncPushHash")
                }
            }
            d.set(Date(), forKey: "syncDiscoveredAt")
            d.set(gistId, forKey: "syncGistId")
        }
        guard let gid = gistId else { return }

        let g = gh("/gists/\(gid)", token: token)
        if g.status == 404 {
            for key in ["syncGistId", "syncPushHash", "syncDiscoveredAt"] { d.removeObject(forKey: key) }
        }
        if handle(g.status, headers: g.headers, request: "GET /gists/{id}", token: token) { return }
        guard let gist = g.json as? [String: Any], syncIsPrivate(gist["public"]) else {
            // Rediscover on the next cycle; never write into a public/unknown-visibility gist.
            for key in ["syncGistId", "syncPushHash", "syncDiscoveredAt"] { d.removeObject(forKey: key) }
            recordError(tr("Некорректный ответ GET /gists/{id}", "Invalid GET /gists/{id} response"))
            return
        }
        guard let files = gist["files"] as? [String: [String: Any]] else {
            recordError(tr("Некорректный ответ GET /gists/{id}", "Invalid GET /gists/{id} response")); return
        }

        if force || d.string(forKey: "syncPushHash") != snap.hash {
            let p = gh("/gists/\(gid)", "PATCH", token: token, body: ["files": [myFile: ["content": machineFile(snap.days)]]])
            if p.status == 404 {
                for key in ["syncGistId", "syncPushHash", "syncDiscoveredAt"] { d.removeObject(forKey: key) }
            }
            if handle(p.status, headers: p.headers, request: "PATCH /gists/{id}", token: token) { return }
            d.set(snap.hash, forKey: "syncPushHash"); d.set(Date(), forKey: "syncPushedAt")
        }

        var contents: [String: String] = [:]
        for (name, f) in files where name.hasPrefix("machine-") && name.hasSuffix(".json") && name != myFile {
            var content = f["content"] as? String
            if (f["truncated"] as? Bool) == true {
                guard let raw = f["raw_url"] as? String else {
                    recordError(tr("Нет raw_url у усечённого файла", "Truncated file has no raw_url")); return
                }
                let r = transport(raw, "GET", ["User-Agent": "ClaudeCodexLimits"], nil, 20)
                if handle(r.status, headers: r.headers, request: "GET raw_url", token: nil) { return }
                guard r.status == 200, let data = r.data, !data.isEmpty,
                      let text = String(data: data, encoding: .utf8) else {
                    recordError(tr("Пустой или нечитаемый ответ GET raw_url", "Empty or unreadable GET raw_url response")); return
                }
                content = text
            }
            if let c = content { contents[name] = c }
        }
        var cache = GitHubSync.merge(contents, excluding: machineId)
        cache.authEpoch = cycleBinding?.epoch; cache.authUserID = cycleBinding?.userID
        let publish = {
            // Both file and memory publication are fenced. A stale callback may neither
            // replace B's durable cache with A's data nor expose A's cached totals in UI.
            if self.authOwner == nil || cycleAccess?.epoch != "legacy" {
                let data = try JSONEncoder().encode(cache)
                try data.write(to: URL(fileURLWithPath: self.remotePath), options: .atomic)
            }
            self.lock.lock(); self._remote = cache; self.lock.unlock()
            let ms = self.machineList()
            let ok = Date(), pushed = d.object(forKey: "syncPushedAt") as? Date
            d.set(ok, forKey: "syncLastOkAt")
            d.removeObject(forKey: "syncLastError"); d.removeObject(forKey: "syncLastErrorAt")
            self.setUI { $0.machines = ms; $0.lastSync = ok; $0.lastUploadAt = pushed; $0.lastError = nil; $0.lastErrorAt = nil }
        }
        if let owner = authOwner {
            guard let access = cycleAccess, owner.withCurrentAccess(access, publish) else {
                recordError(tr("Вход изменился или кеш недоступен; повторим синхронизацию", "Sign-in changed or cache is unavailable; sync will retry")); return
            }
            // No more authenticated work follows: optional GC cannot close the store
            // gate between this cycle's access check, API calls and publication.
            owner.cleanupRetiredCredentials()
            setUI { $0.keychainRetryAvailable = owner.keychainRetryDelay() != nil }
        } else { try? publish() }

    }

    /// Parse other machines' files (name → JSON text) into one summed cache. Pure — no network.
    static func merge(_ contents: [String: String], excluding myId: String, now: Date = Date()) -> SyncRemoteCache {
        var cache = SyncRemoteCache()
        var seen = Set<String>()
        let iso = ISO8601DateFormatter(), fractionalISO = ISO8601DateFormatter()
        fractionalISO.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let oldest = now.addingTimeInterval(-SYNC_KEEP_DAYS * 86400)
        for name in contents.keys.sorted() {
            guard let c = contents[name] else { continue }
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(c.utf8))) as? [String: Any],
                  syncCount(obj["schema"]) == 1,
                  let m = obj["machine"] as? [String: Any], let id = m["id"] as? String, !id.isEmpty,
                  id != myId, name == "machine-\(id).json", !seen.contains(id) else { continue }
            let updated = (obj["updated"] as? String).flatMap { iso.date(from: $0) ?? fractionalISO.date(from: $0) }
            if obj["updated"] != nil && updated == nil { continue }
            if let u = updated, u < oldest { continue }
            seen.insert(id)
            cache.machines.append(SyncCachedMachine(id: id, name: m["name"] as? String ?? "?", os: m["os"] as? String ?? "", updated: updated))
            guard let days = obj["days"] as? [String: [String: [String: [String: Any]]]] else { continue }
            for (p, byDay) in days {
                for (day, byModel) in byDay {
                    for (model, v) in byModel {
                        guard let input = syncCount(v["input"]), let output = syncCount(v["output"]),
                              let cacheRead = syncCount(v["cacheRead"]), let cacheWrite5m = syncCount(v["cacheWrite5m"]),
                              let cacheWrite1h = syncCount(v["cacheWrite1h"]), let turns = syncCount(v["turns"]) else { continue }
                        let u = DayModelUsage(input: input, output: output, cacheRead: cacheRead,
                                              cacheWrite5m: cacheWrite5m, cacheWrite1h: cacheWrite1h, turns: turns)
                        var cur = cache.days[p, default: [:]][day, default: [:]][model, default: DayModelUsage()]
                        cur.add(u)
                        cache.days[p, default: [:]][day, default: [:]][model] = cur
                    }
                }
            }
        }
        return cache
    }
    /// Test seam: the file this machine would write, and the merge of arbitrary files.
    func selfTestFile() -> String { machineFile(snapshotJSON().days) }
    func setRemoteForPreview(_ c: SyncRemoteCache) { lock.lock(); _remote = c; _ui.phase = .on; lock.unlock() }
}

/// Local index plus every other machine's days from the gist — what the history draws from.
func mergedUsageIndex(_ sync: GitHubSync = .shared) -> UsageIndex {
    var ix = UsageLogs.shared.snapshot()
    ix.days = ix.days.filter { productEnabled($0.key) }
    for (p, byDay) in sync.remoteDays() where productEnabled(p) {
        for (day, byModel) in byDay { for (m, u) in byModel { ix.add(p, day, m, u) } }
    }
    return ix
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

/// The per-model metric keeps its own ramp in the menu bar too (teal → coral → magenta), the
/// same way it does on the card, so a model at its limit can never be read as the weekly one.
/// Teal goes dark on a light menu bar, where the bright variant would be unreadable.
func trayScopedColor(_ pct: Double, dark: Bool) -> NSColor {
    if pct >= 80 { return NSColor(srgbRed: 0.90, green: 0.18, blue: 0.50, alpha: 1) }
    if pct >= 50 { return NSColor(srgbRed: 0.93, green: 0.42, blue: 0.28, alpha: 1) }
    return dark ? NSColor(srgbRed: 0.30, green: 0.88, blue: 0.76, alpha: 1)
                : NSColor(srgbRed: 0.00, green: 0.45, blue: 0.38, alpha: 1)
}

// MARK: - What the menu bar shows

/// Which percentages make it into the menu-bar strip. The popover always shows everything —
/// the tray is narrow, so the user picks what earns the space (Settings → «В строке меню»).
enum TrayMetric: String, CaseIterable { case session, weekly, model }

let TRAY_METRICS_DEFAULT: [TrayMetric] = [.session, .weekly]

/// The picked metrics **in the user's own order** — the stored order is the left-to-right
/// order in the tray, so "Fable / week" and "week / Fable" are different settings.
func trayMetrics() -> [TrayMetric] {
    guard let raw = UserDefaults.standard.string(forKey: "trayMetrics") else { return TRAY_METRICS_DEFAULT }
    var out: [TrayMetric] = []
    for p in raw.split(separator: ",") {
        if let m = TrayMetric(rawValue: String(p)), !out.contains(m) { out.append(m) }
    }
    return out.isEmpty ? TRAY_METRICS_DEFAULT : out              // never leave the tray blank
}

func setTrayMetrics(_ m: [TrayMetric]) {
    var out: [TrayMetric] = []
    for x in m where !out.contains(x) { out.append(x) }
    guard !out.isEmpty else { return }
    UserDefaults.standard.set(out.map { $0.rawValue }.joined(separator: ","), forKey: "trayMetrics")
}

/// Assign one side of the strip. The left side always carries a value; the right may be
/// cleared ("—") to show a single number. Picking the metric that already sits on the other
/// side swaps the two rather than showing it twice.
func trayApplySlot(_ slot: Int, _ pick: TrayMetric?) {
    let cur = Array(trayMetrics().prefix(2))
    let left = cur.first, right = cur.count > 1 ? cur[1] : nil
    var out: [TrayMetric?]
    if slot == 0 {
        guard let v = pick else { return }
        out = (right == v) ? [v, left] : [v, right]
    } else {
        guard let v = pick else { setTrayMetrics([left].compactMap { $0 }); return }
        if left == v {
            guard let r = right else { return }                 // nothing to swap with → ignore
            out = [r, v]
        } else {
            out = [left, v]
        }
    }
    setTrayMetrics(out.compactMap { $0 })
}

/// Short tray-strip name of a metric, for the settings segments.
func trayMetricShort(_ m: TrayMetric?) -> String {
    switch m {
    case .session: return tr("5ч", "5h")
    case .weekly:  return tr("нед", "wk")
    case .model:
        let n = trayModelLabel()                                // a long display_name would
        return n.count > 7 ? String(n.prefix(6)) + "…" : n      // overflow its segment
    case nil:      return "—"
    }
}

// MARK: - Rendering (CoreGraphics + CoreText)

func numText(_ v: Double?) -> String {
    guard let v = v else { return "–" }
    return String(Int(v.rounded()))
}

// MARK: - Localization (RU default, EN optional)

func appLang() -> String {
    if CommandLine.arguments.contains("--sync-selftest") { return "ru" } // No real defaults in isolated tests.
    return UserDefaults.standard.string(forKey: "lang") == "en" ? "en" : "ru"
}
/// Pick the string for the current UI language. Default is Russian.
func tr(_ ru: String, _ en: String) -> String { appLang() == "en" ? en : ru }

/// Name of the per-model limit ("Fable"), remembered from the last successful fetch so the
/// settings screen can label the option even before the first refresh of this launch.
func trayModelLabel() -> String {
    UserDefaults.standard.string(forKey: "scopedName") ?? tr("Модель", "Model")
}

func cg(_ c: NSColor) -> CGColor {
    let r = c.usingColorSpace(.sRGB) ?? c
    return CGColor(srgbRed: r.redComponent, green: r.greenComponent, blue: r.blueComponent, alpha: r.alphaComponent)
}

func ctFont(_ size: CGFloat, _ weight: NSFont.Weight) -> CTFont {
    let ns = NSFont.systemFont(ofSize: size, weight: weight)
    return CTFontCreateWithFontDescriptor(ns.fontDescriptor as CTFontDescriptor, size, nil)
}

func ctMono(_ size: CGFloat, _ weight: NSFont.Weight) -> CTFont {
    let ns = NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    return CTFontCreateWithFontDescriptor(ns.fontDescriptor as CTFontDescriptor, size, nil)
}

/// Height a paragraph occupies when wrapped to `width` (CoreText measurement).
func wrappedHeight(_ a: NSAttributedString, width: CGFloat) -> CGFloat {
    let fs = CTFramesetterCreateWithAttributedString(a)
    let sz = CTFramesetterSuggestFrameSizeWithConstraints(
        fs, CFRangeMake(0, 0), nil, CGSize(width: width, height: .greatestFiniteMagnitude), nil)
    return ceil(sz.height)
}

func ctAttr(_ s: String, _ font: CTFont, _ color: CGColor) -> NSAttributedString {
    NSAttributedString(string: s, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ])
}

/// The tray number for a product, or nil when there is nothing meaningful to show
/// (a "not signed in" product, or one carrying none of the picked metrics) — the caller
/// then draws just a faint icon. Only the metrics the user picked are drawn, and only
/// those this product actually has, so a Codex row never shows a "–" for a per-model
/// limit that exists on the Claude side alone.
func groupString(_ d: LimitData, dark: Bool, font: CTFont) -> NSAttributedString? {
    if d.auth == .loggedOut { return nil }                       // "sign in" → faint icon, no number
    let base = dark ? NSColor.white : NSColor.black
    // Fade each invalid/reset window independently; keep a valid weekly reading visible.
    let stale = isStale(d)
    let dim = cg(base.withAlphaComponent(stale ? 0.4 : 0.95))
    let faint = cg(base.withAlphaComponent(0.4))
    let sessionStale = metricIsStale(d, metric: "session")
    let weeklyStale = metricIsStale(d, metric: "weekly")
    let modelStale = metricIsStale(d, metric: "model")
    var parts: [(value: Double, color: CGColor)] = []
    for metric in trayMetrics() {
        switch metric {
        case .session:
            if let v = d.session { parts.append((v, sessionStale ? faint : cg(sevColor(severity(v), dark: dark)))) }
        case .weekly:
            if let v = d.weekly { parts.append((v, weeklyStale ? faint : cg(sevColor(severity(v), dark: dark)))) }
        case .model:
            if let s = d.scoped { parts.append((s.percent, modelStale ? faint : cg(trayScopedColor(s.percent, dark: dark)))) }
        }
    }
    // Codex has no per-model limit, so a "weekly + model" pick would leave its row numberless.
    // Fall back to whatever that product does have rather than showing a bare icon.
    if parts.isEmpty {
        if let v = d.session { parts.append((v, sessionStale ? faint : cg(sevColor(severity(v), dark: dark)))) }
        if let v = d.weekly { parts.append((v, weeklyStale ? faint : cg(sevColor(severity(v), dark: dark)))) }
    }
    if parts.isEmpty { return nil }                              // genuinely no data → icon only
    let m = NSMutableAttributedString()
    for (i, p) in parts.enumerated() {
        if i > 0 { m.append(ctAttr("/", font, dim)) }
        m.append(ctAttr(numText(p.value), font, p.color))
    }
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
func renderStrip(_ products: [(LimitData, String)], dark: Bool, s: CGFloat = 2, badge: Bool = false) -> CGImage? {
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

    // A nil line = "no number for this product" (not signed in / no data) → icon only.
    let lines: [CTLine?] = products.map { p in
        groupString(p.0, dark: dark, font: font).map { CTLineCreateWithAttributedString($0) }
    }
    let textW = lines.compactMap { $0.map { ceil(lineWidth($0)) } }.max() ?? 0
    let textX = padX + iconSz + gapIcon
    let dotR: CGFloat = 2.4 * s
    let dotZone: CGFloat = badge ? (dotR * 2 + 5 * s) : 0   // "update available" dot to the right
    let W = ceil(textX + textW + padX + dotZone)

    guard let ctx = bitmapContext(Int(W), Int(H)) else { return nil }
    ctx.interpolationQuality = .high
    ctx.textMatrix = .identity
    // Vertical metrics come from the font (a reference glyph), not lines[0] — which may be nil.
    var asc: CGFloat = 0, desc: CGFloat = 0
    _ = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(ctAttr("0%", font, fg)), &asc, &desc, nil)

    // CG origin is bottom-left → first product on top.
    for (i, prod) in products.enumerated() {
        let y0 = two ? (i == 0 ? rowH : 0) : 0
        let iconY = (y0 + (rowH - iconSz) / 2).rounded()
        if let img = loadCGImage(assetPath(prod.1)) {
            // A "not signed in" product shows a faint icon so the row reads as inactive.
            let dimIcon = prod.0.auth == .loggedOut
            if dimIcon { ctx.saveGState(); ctx.setAlpha(0.4) }
            ctx.draw(img, in: CGRect(x: padX, y: iconY, width: iconSz, height: iconSz))
            if dimIcon { ctx.restoreGState() }
        }
        if let line = lines[i] {
            let baseY = (y0 + (rowH - asc - desc) / 2 + desc).rounded()
            ctx.textPosition = CGPoint(x: textX, y: baseY)
            CTLineDraw(line, ctx)
        }
    }
    if badge {
        let cxd = W - padX - dotR
        ctx.setFillColor(cg(NSColor(srgbRed: 1, green: 0.62, blue: 0.18, alpha: 1)))
        ctx.fillEllipse(in: CGRect(x: cxd - dotR, y: H / 2 - dotR, width: dotR * 2, height: dotR * 2))
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
    let df = DateFormatter(); df.locale = Locale(identifier: appLang() == "en" ? "en_US" : "ru_RU")
    if Calendar.current.isDateInToday(d) { df.setLocalizedDateFormatFromTemplate("HH:mm") }
    else { df.setLocalizedDateFormatFromTemplate("d MMM HH:mm") }
    return df.string(from: d)
}

/// True when a card is showing a frozen / aged snapshot instead of live data — so the UI
/// can say so plainly instead of passing off old numbers (and a past reset time) as current.
/// Freshness is the age of the observation, independent of a later failed request.
let SNAPSHOT_MAX_AGE: TimeInterval = 14400
func snapshotWindowPace(used: Double?, reset: Date?, windowH: Double, asOf: Date?, recentRate: Double? = nil) -> WindowPace? {
    guard let at = asOf, at.timeIntervalSince1970.isFinite,
          let used = used, used.isFinite, used >= 0,
          let reset = reset, reset.timeIntervalSince1970.isFinite,
          reset > at, reset.timeIntervalSince(at) <= windowH * 3600 else { return nil }
    return windowPace(used: used, reset: reset, windowH: windowH, recentRate: recentRate, now: at)
}
func metricIsStale(_ d: LimitData, metric: String, now: Date = Date()) -> Bool {
    guard let at = d.asOf, at.timeIntervalSince1970.isFinite,
          (0...SNAPSHOT_MAX_AGE).contains(now.timeIntervalSince(at)) else { return true }
    let used: Double?, reset: Date?, hours: Double
    switch metric {
    case "session": (used, reset, hours) = (d.session, d.sessionReset, 5)
    case "model": (used, reset, hours) = (d.scoped?.percent, d.scoped?.reset, 168)
    default: (used, reset, hours) = (d.weekly, d.weeklyReset, 168)
    }
    guard let reset = reset, reset > now else { return true }
    return snapshotWindowPace(used: used, reset: reset, windowH: hours, asOf: at) == nil
}
func isStale(_ d: LimitData, _ now: Date = Date()) -> Bool {
    d.present && ["session", "weekly", "model"].allSatisfy { metricIsStale(d, metric: $0, now: now) }
}
func limitResetText(_ reset: Date?) -> String {
    if let reset = reset, reset <= Date() { return tr("окно сброшено", "window reset") }
    return fmtReset(reset)
}

func pctText(_ v: Double?) -> String {
    guard let v = v else { return "—" }
    return "\(Int(v.rounded()))%"
}

func clockText(_ d: Date) -> String {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: d)
}

// MARK: - Login item (LaunchAgent)

func loginEnabled() -> Bool {
    if isolatedSelfTestAssets != nil { return false }
    return FileManager.default.fileExists(atPath: AGENT_PLIST)
}

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

/// Identity colour of a per-model weekly limit — a third hue alongside session-blue and
/// weekly-purple.
let SCOPED_COLOR = NSColor(srgbRed: 0.20, green: 0.85, blue: 0.70, alpha: 1)

/// Severity ramp for a per-model limit — deliberately NOT the shared amber/red ramp.
/// The weekly limit goes amber then red as well, and two identically coloured readings on
/// one card can't be told apart: a red pill next to a red ring leaves you guessing whether
/// it's the model that ran out or the week. Coral and magenta stay unmistakably "hot" while
/// remaining distinct from the weekly's amber and red at every level.
func scopedColor(_ pct: Double) -> NSColor {
    if pct >= 80 { return NSColor(srgbRed: 0.98, green: 0.22, blue: 0.56, alpha: 1) }
    if pct >= 50 { return NSColor(srgbRed: 0.99, green: 0.47, blue: 0.38, alpha: 1) }
    return SCOPED_COLOR
}
/// Height of the extra card row a per-model limit adds.
let SCOPED_ROW_H: CGFloat = 15

// Settings layout. Both drawSettings() and settingsTotalHeight() derive their positions from
// these, so adding a row can't leave the two out of step (the way the footer divider once
// kept a hardcoded offset after the card grew).
let SET_ROW_H: CGFloat = 36              // language / toggle rows
let SET_SOUND_ROW_H: CGFloat = 29        // sound-picker rows
let SET_GAP: CGFloat = 14                // card bottom → next section caption
let SET_CAP_H: CGFloat = 16              // caption → its card
let SET_GEN_TOP: CGFloat = 66
let SET_GEN_H = SET_ROW_H * 3            // language · launch at login · panel view
let SET_PRODUCTS_CAP = SET_GEN_TOP + SET_GEN_H + SET_GAP
let SET_PRODUCTS_TOP = SET_PRODUCTS_CAP + SET_CAP_H
let SET_PRODUCTS_H = SET_ROW_H
let SET_TRAY_CAP = SET_PRODUCTS_TOP + SET_PRODUCTS_H + SET_GAP
let SET_TRAY_TOP = SET_TRAY_CAP + SET_CAP_H
let SET_TRAY_H: CGFloat = 44             // the menu-bar picker card
let SET_SUB_CAP = SET_TRAY_TOP + SET_TRAY_H + SET_GAP     // «ПОДПИСКИ» caption (Advanced only)
let SET_SUB_TOP = SET_SUB_CAP + SET_CAP_H
let SET_SUB_H = SET_ROW_H * 2
/// Height the subscriptions block adds — zero in the Simple view, where money isn't shown.
func setSubBlock() -> CGFloat { advancedEnabled() ? SET_CAP_H + SET_SUB_H + SET_GAP : 0 }

// Cross-machine sync through a GitHub gist (docs/sync-protocol.md). UI state only here; the
// transport lives in GitHubSync. Advanced view only — it feeds the history & money figures.
enum SyncPhase { case off, awaitingCode, on, revoked }
struct SyncMachine { var name: String; var os: String; var updated: Date?; var isSelf: Bool }
struct SyncUIState {
    var phase: SyncPhase = .off
    var authState: String? = nil
    var authReason: String? = nil
    var keychainItemLeft = false          // unknown after a timeout also allows a manual cleanup
    var login: String? = nil
    var userCode: String? = nil
    var machines: [SyncMachine] = []
    var lastSync: Date? = nil              // last full cycle that read the gist (syncLastOkAt)
    var error: String? = nil               // sign-in flow only
    var lastAttemptAt: Date? = nil         // syncLastAttemptAt
    var firstAttemptAt: Date? = nil        // this process only; never restored from defaults
    var lastUploadAt: Date? = nil          // last PATCH of this machine's file (syncPushedAt)
    var lastError: String? = nil           // syncLastError — cleared by a good cycle
    var lastErrorAt: Date? = nil
    var keychainRetryAvailable = false
    var canRetryKeychain: Bool { keychainRetryAvailable || ["locked", "timeout", "unreachable"].contains(authReason ?? "") }
    var canSignOut: Bool {
        phase == .on || ((phase == .off || phase == .revoked) && keychainItemLeft)
    }
}
var SYNC_PREVIEW: SyncUIState? = nil
/// No good cycle for this long while signed in → say so on the main screen (sync-protocol.md → Errors).
let SYNC_STALE_AFTER: TimeInterval = 30 * 60
/// The orange line for the main screen, or nil when sync is fine / off. Revoked always shows:
/// the totals silently lose the other computers otherwise.
func syncWarning(_ s: SyncUIState = syncUIState(), now: Date = Date()) -> String? {
    if let reason = s.authReason { return githubAuthMessage(reason, language: appLang()) }
    switch s.phase {
    case .revoked:
        return tr("Войдите в GitHub заново — суммы без других компьютеров", "Sign in to GitHub again — totals exclude other computers")
    case .on:
        guard let firstAttempt = s.firstAttemptAt, let errorAt = s.lastErrorAt,
              errorAt >= firstAttempt else { return nil }
        let cause = s.lastError ?? tr("ждём ответа GitHub", "waiting for GitHub")
        guard let since = s.lastSync ?? s.lastUploadAt else {
            return s.lastError.map { tr("Синхронизация не работает: ", "Sync isn't working: ") + $0 }
        }
        guard now.timeIntervalSince(since) > SYNC_STALE_AFTER,
              errorAt > since.addingTimeInterval(SYNC_STALE_AFTER) else { return nil }
        return tr("Синхронизация стоит с \(fmtMoment(since)): \(cause)", "Sync stalled since \(fmtMoment(since)): \(cause)")
    case .off, .awaitingCode:
        return nil
    }
}
/// `s` in one line no wider than `maxW`, cut with «…» when it doesn't fit.
/// `make` is the caller's own `attr` (each drawing routine styles text its own way).
func fitAttr(_ s: String, maxW: CGFloat, _ make: (String) -> NSAttributedString) -> NSAttributedString {
    func w(_ a: NSAttributedString) -> CGFloat { ceil(lineWidth(CTLineCreateWithAttributedString(a))) }
    var a = make(s)
    guard w(a) > maxW else { return a }
    var t = s
    while t.count > 1 {
        t.removeLast()
        a = make(t.trimmingCharacters(in: .whitespaces) + "…")
        if w(a) <= maxW { break }
    }
    return a
}
/// The settings block stays hidden until the GitHub transport is built — no dead buttons.
let SYNC_READY = true
func syncBlockShown() -> Bool { advancedEnabled() && (SYNC_READY || SYNC_PREVIEW != nil) }
func syncUIState() -> SyncUIState { SYNC_PREVIEW ?? GitHubSync.shared.ui }
/// Other machines currently merged into the history (0 when sync is off).
func syncOtherMachines() -> Int {
    let s = syncUIState(); return s.phase == .on ? s.machines.filter { !$0.isSelf }.count : 0
}
let SET_SYNC_MROW_H: CGFloat = 30
let SET_SYNC_NOTE_H: CGFloat = 60
let SET_SYNC_SIGNOUT_HINT_H: CGFloat = 28
func syncSignOutHint(_ lang: String = appLang()) -> String {
    // Two lines at cardW - 28; keep the applications address whole.
    lang == "en"
        ? "Signs out only this computer. Revoke app access:\ngithub.com/settings/applications"
        : "Выход только на этом компьютере. Отзыв доступа:\ngithub.com/settings/applications"
}
func setSyncCardH(_ s: SyncUIState = syncUIState()) -> CGFloat {
    let retryH: CGFloat = s.canRetryKeychain ? SET_ROW_H : 0
    switch s.phase {
    case .off:          return retryH + SET_ROW_H + SET_SYNC_NOTE_H + (s.canSignOut ? SET_SYNC_SIGNOUT_HINT_H : 0)
    case .revoked:      return retryH + SET_ROW_H + SET_SYNC_NOTE_H + (s.lastError != nil ? SET_SYNC_STATUS_H : 0)
                                + (s.canSignOut ? SET_SYNC_SIGNOUT_HINT_H : 0)
    case .awaitingCode:  return retryH + SET_ROW_H + 44 + 26
    case .on:            return retryH + SET_ROW_H + CGFloat(max(1, s.machines.count)) * SET_SYNC_MROW_H + 4
                                + SET_SYNC_STATUS_H + (s.lastError != nil ? SET_SYNC_STATUS_H - 4 : 0)
                                + SET_SYNC_SIGNOUT_HINT_H
    }
}
let SET_SYNC_STATUS_H: CGFloat = 20      // «Последняя отправка · чтение» (+ the last error) under the machines
let SET_SYNC_CAP = SET_SUB_TOP + SET_SUB_H + SET_GAP
let SET_SYNC_TOP = SET_SYNC_CAP + SET_CAP_H
func setSyncBlock() -> CGFloat { syncBlockShown() ? SET_CAP_H + setSyncCardH() + SET_GAP : 0 }
/// Sounds are set once and forgotten, so in Settings they are one summary row «Звуки ›» that
/// opens their own screen (PanelMode.sounds) — unfolded in place they didn't fit the screen.
func setSndTop() -> CGFloat { SET_TRAY_TOP + SET_TRAY_H + SET_GAP + setSubBlock() + setSyncBlock() }
/// Top of the «О ПРИЛОЖЕНИИ» caption, right under the sounds row.
func setAboutCap() -> CGFloat { setSndTop() + SET_ROW_H + SET_GAP }
/// On the sounds screen the first caption sits where «ОБЩИЕ» sits in Settings.
func setCap1() -> CGFloat { 50 }
func soundsPageHeight() -> CGFloat {
    let c2top = setC1Top() + SET_ROW_H * 2 + SET_GAP + SET_CAP_H
    let cardBbottom = c2top + SET_SOUND_ROW_H * CGFloat(RESET_SOUNDS.count)
    let c3top = cardBbottom + SET_GAP + SET_CAP_H
    return c3top + SET_ROW_H + SET_SOUND_ROW_H * CGFloat(REACHED_SOUNDS.count) + 16
}
func soundsSummary() -> String {
    let d = UserDefaults.standard
    var parts: [String] = []
    switch (d.bool(forKey: "sound5h"), d.bool(forKey: "sound7d")) {
    case (true, true):  parts.append(tr("сброс 5 ч и недели", "5 h & week reset"))
    case (true, false): parts.append(tr("сброс 5 ч", "5 h reset"))
    case (false, true): parts.append(tr("сброс недели", "week reset"))
    default: break
    }
    if d.bool(forKey: "reachedOn") { parts.append(tr("лимит", "limit reached")) }
    return parts.isEmpty ? tr("выключены", "off") : parts.joined(separator: " · ")
}
func setC1Top() -> CGFloat { setCap1() + SET_CAP_H }

/// Does this card render the per-model row? Only a healthy, live card does — the
/// sign-in-problem and stale layouts replace the reset rows with a status message.
func showsScopedRow(_ d: LimitData) -> Bool {
    d.present && d.scoped != nil && d.auth == .ok && !isStale(d)
}
/// Extra height the cards (and so the panel) need for the per-model row.
func scopedRowExtra(_ claude: LimitData, _ codex: LimitData) -> CGFloat {
    (showsScopedRow(claude) || showsScopedRow(codex)) ? SCOPED_ROW_H : 0
}
/// Height of the main panel for the given data — grows when a per-model limit is shown.
func panelMainHeight(_ claude: LimitData, _ codex: LimitData) -> CGFloat {
    PANEL_H + scopedRowExtra(claude, codex)
}
enum PanelMode { case main, settings, sounds, whatsnew, claudeFix }
let APP_VERSION = "3.2.3"
let APP_AUTHOR = "Alex Kovalev"
/// Poll only at one of the offered intervals. Old 1/5-minute settings migrate to 30 minutes.
let POLL_DEFAULT: TimeInterval = 1800
let POLL_CHOICES: [(ru: String, en: String, sec: TimeInterval)] = [
    ("15м", "15m", 900), ("30м", "30m", 1800), ("1ч", "1h", 3600)
]
func normalizedPollInterval(_ value: TimeInterval) -> TimeInterval {
    POLL_CHOICES.contains { $0.sec == value } ? value : POLL_DEFAULT
}
func storedPollInterval() -> TimeInterval {
    let d = UserDefaults.standard, old = d.double(forKey: "interval")
    let value = normalizedPollInterval(old)
    if old != value { d.set(value, forKey: "interval") }
    return value
}
// Adaptive schedules are per product and persist across launches. Local log activity never
// performs networking; it only shortens the next eligible API poll (15-minute minimum).
func autoPollEnabled() -> Bool { UserDefaults.standard.bool(forKey: "autoPoll") }
let AUTO_STEPS: [TimeInterval] = [900, 1800, 3600, 14400]
struct AutoReading: Codable { var used: Double; var reset: Double? }
struct AutoPollState: Codable {
    var interval: TimeInterval = 1800
    var lastAttempt: Double = 0
    var observedAt: Double = 0
    var readings: [String: AutoReading] = [:]
    var failed = false

    mutating func due(_ now: Double, manual: Bool = false) -> Bool {
        if lastAttempt > now { lastAttempt = now } // clock moved backwards: restart the minimum wait
        return lastAttempt == 0 || now - lastAttempt >= (manual && !failed ? 900 : interval)
    }
    func nextDelay(_ now: Double) -> TimeInterval {
        if lastAttempt == 0 { return 0.01 }
        if lastAttempt > now { return 60 }
        return max(0.01, min(60, lastAttempt + interval - now))
    }
    mutating func begin(_ now: Double) { lastAttempt = now }
    mutating func slowDown() {
        let i = AUTO_STEPS.firstIndex(of: interval) ?? 1
        interval = AUTO_STEPS[min(i + 1, AUTO_STEPS.count - 1)]
    }
    mutating func observe(_ data: LimitData, now: Double) {
        let fresh = data.apiFresh && data.present && data.error == nil && data.auth == .ok && !data.fromCache && !data.stale
            && (data.asOf?.timeIntervalSince1970 ?? 0) >= lastAttempt - 60
        var current: [String: AutoReading] = [:]
        if let v = data.session, v.isFinite { current["session"] = AutoReading(used: v, reset: data.sessionReset?.timeIntervalSince1970) }
        if let v = data.weekly, v.isFinite { current["weekly"] = AutoReading(used: v, reset: data.weeklyReset?.timeIntervalSince1970) }
        if let s = data.scoped, s.percent.isFinite { current["model:" + s.name] = AutoReading(used: s.percent, reset: s.reset?.timeIntervalSince1970) }
        lastAttempt = max(lastAttempt, now)  // the floor also covers time spent waiting for the response
        guard fresh, !current.isEmpty else { failed = true; slowDown(); return }
        failed = false
        let elapsed = now - observedAt
        var comparable = false, active = false
        if observedAt > 0, elapsed > 0 {
            for (key, value) in current {
                guard let old = readings[key], old.reset == value.reset else { continue }
                comparable = true
                if (value.used - old.used) * 900 >= elapsed { active = true }
            }
        }
        if active { interval = 900 } else if comparable { slowDown() }
        readings = current; observedAt = now
    }
    @discardableResult
    mutating func localActivity(_ timestamps: [Double], now: Double) -> Bool {
        guard !failed else { return false }
        let recent = Set(timestamps.filter { $0.isFinite && $0 >= now - 900 && $0 <= now })
        guard recent.count >= 3, (recent.max() ?? 0) > lastAttempt, interval != 900 else { return false }
        interval = 900; return true
    }
}
func loadAutoPollStates() -> [String: AutoPollState] {
    guard let data = UserDefaults.standard.data(forKey: "autoPollState"),
          let states = try? JSONDecoder().decode([String: AutoPollState].self, from: data) else { return [:] }
    return states.filter { AUTO_STEPS.contains($0.value.interval) && $0.value.lastAttempt >= 0 }
}
func pollSegments() -> [(ru: String, en: String, sec: TimeInterval)] { POLL_CHOICES + [("А", "A", 0)] }
func pollSelected(_ sec: TimeInterval, manual: TimeInterval) -> Bool {
    autoPollEnabled() ? sec == 0 : sec != 0 && abs(manual - sec) < 1
}

/// Display-only values from the owner's snapshot, independent of the saved manual choice.
func autoPollLabelParts(auto: Bool, enabled: [String: Bool], intervals: [String: TimeInterval], lang: String) -> [String] {
    guard auto else { return [] }
    let products = ["claude", "codex"].filter { enabled[$0] == true }
    guard !products.isEmpty else { return [lang == "en" ? "no subscriptions" : "нет подписок"] }
    let values = products.map { intervals[$0] ?? POLL_DEFAULT }
    func label(_ sec: TimeInterval) -> String {
        switch sec {
        case 900: return lang == "en" ? "15m" : "15м"
        case 3600: return lang == "en" ? "1h" : "1ч"
        case 14400: return lang == "en" ? "4h" : "4ч"
        default: return lang == "en" ? "30m" : "30м"
        }
    }
    if values.count == 1 || values[0] == values[1] { return [label(values[0])] }
    return ["Claude " + label(values[0]), "Codex " + label(values[1])]
}

let REPO_URL = "https://github.com/ArrivaRUS/claude-codex-limits"
let CLAUDE_INSTALL_CMD = "curl -fsSL https://claude.ai/install.sh | bash"
// The installer drops the binary in ~/.local/bin but doesn't always add it to PATH
// (a real lesson from a user's Mac). This one line fixes it; the user then opens a new
// Terminal window so the updated PATH takes effect.
let CLAUDE_PATH_CMD = "echo 'export PATH=\"$HOME/.local/bin:$PATH\"' >> ~/.zshrc"

/// Localized copy for the "Connect Claude Code" walkthrough — a single source shared by
/// both the drawing pass (`drawClaudeFix`) and the height pass (`claudeFixHeight`).
struct ClaudeFixCopy {
    let title: String        // panel title
    let intro: String        // why the CLI login (not the desktop app)
    let s1: String           // step 1 + its command box
    let cmd1: String
    let s2: String           // step 2 + its command box
    let cmd2: String
    let s3: String           // step 3 — sign in
    let s4: String           // step 4 — come back and refresh
    let note: String         // the "desktop app won't do" reminder
    let copy: String         // copy-button label
    let copied: String       // copied-confirmation label
}

/// Two different problems reach this screen and they need different instructions. A login
/// that has *expired* means the CLI is already installed and working — walking that user
/// through `curl … install.sh` and a PATH fix is noise; they need `claude` → `/login` and
/// an explanation of why a working Claude Code session didn't keep the monitor alive.
func claudeFixStrings(expired: Bool = false) -> ClaudeFixCopy {
    if expired {
        return ClaudeFixCopy(
            title: tr("Вход устарел", "Sign-in expired"),
            intro: tr("Токен входа Claude Code CLI истёк, и обновить его больше нечем — такой токен живёт ограниченное время. Нужно войти заново, это займёт полминуты.",
                      "The Claude Code CLI sign-in has expired and can no longer be refreshed — that token has a limited lifetime. Signing in again takes half a minute."),
            s1: tr("1. Запустите Claude Code в Терминале:", "1. Start Claude Code in Terminal:"),
            cmd1: "claude",
            s2: tr("2. Внутри выполните команду входа:", "2. Inside, run the sign-in command:"),
            cmd2: "/login",
            s3: tr("3. Войдите через браузер — Claude Code перезапишет токен.",
                   "3. Sign in through the browser — Claude Code rewrites the token."),
            s4: tr("4. Вернитесь сюда и нажмите «Обновить».",
                   "4. Come back here and tap “Refresh”."),
            note: tr("Работающая сессия в настольном приложении Claude монитору не поможет: у него свой вход, а читается именно токен Claude Code CLI. Пока вы не войдёте заново, монитор не запрашивает лимиты — старые цифры остаются на карточке как есть.",
                     "An active session in the Claude desktop app won't help: it has its own sign-in, while the monitor reads the Claude Code CLI token. Until you sign in again the monitor stops asking for limits — the old numbers just stay on the card."),
            copy: tr("Скопировать", "Copy"),
            copied: tr("Скопировано", "Copied"))
    }
    return ClaudeFixCopy(
        title: tr("Подключить Claude Code", "Connect Claude Code"),
        intro: tr("Монитор читает лимиты из входа Claude Code CLI — не из настольного приложения Claude.",
                  "The monitor reads limits from the Claude Code CLI login — not the Claude desktop app."),
        s1: tr("1. Установите Claude Code CLI (если ещё не установлен):",
               "1. Install the Claude Code CLI (if you don’t have it yet):"),
        cmd1: CLAUDE_INSTALL_CMD,
        s2: tr("2. Если после установки команда claude не находится — добавьте её в PATH и откройте новое окно Терминала:",
               "2. If claude isn’t found afterward, add it to your PATH and open a new Terminal window:"),
        cmd2: CLAUDE_PATH_CMD,
        s3: tr("3. Запустите claude и войдите через браузер (или командой /login).",
               "3. Run claude and sign in through the browser (or the /login command)."),
        s4: tr("4. Вернитесь сюда и нажмите «Обновить».",
               "4. Come back here and tap “Refresh”."),
        note: tr("Вход в настольное приложение Claude не подходит: нужен именно вход Claude Code CLI — он создаёт токен, который читает монитор.",
                 "Signing into the Claude desktop app won’t work — you need the Claude Code CLI login, which creates the token the monitor reads."),
        copy: tr("Скопировать", "Copy"),
        copied: tr("Скопировано", "Copied"))
}

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

/// Shared 360-point footer; Auto paint only consumes an interval snapshot.
func drawPollFooter(_ ctx: CGContext, size: CGSize, top: CGFloat, interval: TimeInterval,
                    updated: Date?, autoIntervals: [String: TimeInterval], advanced: Bool = false) -> [Hit] {
    let H = size.height, auto = autoPollEnabled()
    var hits: [Hit] = []
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: H - y - h, width: w, height: h)
    }
    func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: alpha)
    }
    func attr(_ s: String, _ sz: CGFloat, _ weight: NSFont.Weight, _ color: NSColor) -> NSAttributedString {
        ctAttr(s, ctFont(sz, weight), cg(color))
    }
    func textC(_ a: NSAttributedString, x: CGFloat, y: CGFloat, h: CGFloat, align: Int = 0) {
        let line = CTLineCreateWithAttributedString(a)
        var asc: CGFloat = 0, desc: CGFloat = 0
        let w = CGFloat(CTLineGetTypographicBounds(line, &asc, &desc, nil))
        let dx = align == 1 ? x - w / 2 : align == 2 ? x - w : x
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: dx, y: H - y - (h - asc - desc) / 2 - desc * 0.15 - asc)
        CTLineDraw(line, ctx)
    }
    func fill(_ r: CGRect, radius: CGFloat, color: NSColor) {
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(cg(color)); ctx.fillPath()
    }
    fill(rect(16, top, 120, 24), radius: 8, color: gray(1, 0.06))
    for (i, seg) in POLL_CHOICES.enumerated() {
        let r = rect(16 + CGFloat(i) * 40, top, 40, 24)
        let selected = !auto && abs(interval - seg.sec) < 1
        if selected { fill(r.insetBy(dx: 2, dy: 2), radius: 6, color: gray(1, advanced ? 0.18 : 0.13)) }
        textC(attr(tr(seg.ru, seg.en), advanced ? 12 : 11, selected ? .semibold : advanced ? .medium : .regular,
                   gray(1, selected ? 0.95 : 0.5)), x: r.midX, y: top, h: 24, align: 1)
        hits.append(Hit(id: "iv\(Int(seg.sec))", rect: r))
    }
    let autoHit = rect(136, top, 40, 24), capsule = rect(141, top + 2, 30, 20)
    let path = CGPath(roundedRect: capsule, cornerWidth: 10, cornerHeight: 10, transform: nil)
    if auto {
        ctx.saveGState(); ctx.addPath(path); ctx.clip()
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                    colors: [cg(color(52, 121, 239)), cg(color(121, 104, 232))] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(gradient, start: CGPoint(x: capsule.minX, y: capsule.maxY),
                                   end: CGPoint(x: capsule.maxX, y: capsule.minY), options: [])
        }
        ctx.restoreGState()
    } else { fill(capsule, radius: 10, color: color(38, 50, 74)) }
    ctx.addPath(CGPath(roundedRect: capsule.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 9.5, cornerHeight: 9.5, transform: nil))
    ctx.setStrokeColor(cg(auto ? color(184, 207, 255, 0.35) : color(130, 154, 213)))
    ctx.setLineWidth(1); ctx.strokePath()
    let labelColor = color(217, 229, 255)
    textC(attr(tr("А", "A"), 12, .semibold, auto ? gray(1, 1) : labelColor), x: autoHit.midX, y: top, h: 24, align: 1)
    hits.append(Hit(id: "iv0", rect: autoHit))
    let enabled = ["claude": productEnabled("claude"), "codex": productEnabled("codex")]
    let parts = autoPollLabelParts(auto: auto, enabled: enabled, intervals: autoIntervals, lang: appLang())
    if !parts.isEmpty {
        let ink = enabled.values.contains(true) ? labelColor : color(168, 179, 201)
        let joined = attr(parts.joined(separator: " · "), 10, .medium, ink)
        if parts.count == 2 && lineWidth(CTLineCreateWithAttributedString(joined)) > 128 {
            for (i, part) in parts.enumerated() {
                textC(attr(part, 10, .medium, ink), x: 184, y: top + CGFloat(i) * 12, h: 12)
            }
        } else { textC(joined, x: 184, y: top, h: 24) }
    }
    let power = rect(320, top, 24, 24)
    drawPower(ctx, power.insetBy(dx: 4, dy: 4), gray(1, advanced ? 0.5 : 0.6))
    hits.append(Hit(id: "quit", rect: power))
    if !auto, let u = updated {
        textC(attr(tr("обновлено ", "updated ") + clockText(u), advanced ? 11 : 10, .regular, gray(1, advanced ? 0.5 : 0.34)),
              x: advanced ? 315 : 312, y: advanced ? top + 3 : top, h: advanced ? 18 : 24, align: 2)
    }
    return hits
}

@discardableResult
func drawPanel(_ ctx: CGContext, size: CGSize, claude: LimitData, codex: LimitData,
               interval: TimeInterval, updated: Date?, about: AboutState, autoIntervals: [String: TimeInterval] = [:]) -> [Hit] {
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
    var prods: [(LimitData, String, String, String, String)] = []   // (data, name, icon, url, product)
    if productEnabled("claude"), claude.present {
        prods.append((claude, "Claude Code", "claude_128.png", "https://claude.ai/settings/usage", "claude"))
    }
    if productEnabled("codex"), codex.present {
        prods.append((codex, "Codex", "codex_128.png", "https://chatgpt.com/codex/cloud/settings/analytics#usage", "codex"))
    }

    // header — the app's OWN icon + subtitle of present products
    let subtitle = prods.isEmpty ? (monitoringPaused() ? tr("сбор выключен", "monitoring paused") : tr("не найдено", "not found")) : prods.map { $0.1 }.joined(separator: " · ")
    if let img = loadCGImage(assetPath("appicon.png")) { ctx.draw(img, in: rectTL(pad, pad - 1, 30, 30)) }
    text(attr(tr("Лимиты", "Limits"), 15, .semibold, textHi), x: pad + 40, topY: pad - 1)
    text(attr(subtitle, 11, .regular, textLo), x: pad + 40, topY: pad + 17)
    let rfRect = rectTL(W - pad - 24, pad - 2, 24, 24)
    drawSF(ctx, "arrow.clockwise", in: rfRect.insetBy(dx: 4, dy: 4), textMid, weight: .semibold)
    hits.append(Hit(id: "refresh", rect: rfRect))
    let gearRect = rectTL(W - pad - 24 - 26, pad - 2, 24, 24)
    drawSF(ctx, "gearshape", in: gearRect.insetBy(dx: 3, dy: 3), textMid)
    hits.append(Hit(id: "settings", rect: gearRect))
    // badge: an update is available / downloading / ready → flag the gear
    if about.availVersion != nil || about.phase != .idle {
        let badge = CGRect(x: gearRect.maxX - 6, y: gearRect.maxY - 6, width: 7, height: 7)
        ctx.setFillColor(cg(gray(0.10, 1))); ctx.fillEllipse(in: badge.insetBy(dx: -1.5, dy: -1.5))   // dark halo for contrast
        ctx.setFillColor(cg(NSColor(srgbRed: 1, green: 0.62, blue: 0.18, alpha: 1))); ctx.fillEllipse(in: badge)
    }

    // cards
    let cardsTop: CGFloat = 58, cardH: CGFloat = 152 + scopedRowExtra(claude, codex), gap: CGFloat = 12
    let cardW = (W - pad * 2 - gap) / 2

    func drawCard(_ x: CGFloat, _ w: CGFloat, _ d: LimitData, name: String, icon: String, url: String, product: String) {
        let r = rectTL(x, cardsTop, w, cardH)
        roundFill(r, 14, gray(1, 0.04)); roundStroke(r, 14, gray(1, 0.06), 1)
        // Claude sign-in problems (states 1 & 2) make the whole card tap-to-fix; everything
        // else opens the product's usage page in the browser.
        let canFix = limitCanFix(product: product, auth: d.auth)
        hits.append(Hit(id: canFix ? "claudefix" : "open:\(url)", rect: r))
        if let img = loadCGImage(assetPath(icon)) { ctx.draw(img, in: rectTL(x + 14, cardsTop + 13, 18, 18)) }
        text(attr(name, 12.5, .semibold, gray(1, 0.9)), x: x + 39, topY: cardsTop + 15)

        let amber = NSColor(srgbRed: 1, green: 0.62, blue: 0.18, alpha: 1)

        // A sign-in problem replaces the gauges with an honest status + (when recoverable)
        // a "How to fix?" affordance. The whole card is already the tap target.
        func problemBody(_ title: String, _ subtitle: String?, showFix: Bool) {
            let cxp = x + w / 2
            drawSF(ctx, "exclamationmark.triangle.fill", in: rectTL(cxp - 11, cardsTop + 46, 22, 22), amber)
            text(attr(title, 12.5, .semibold, gray(1, 0.92)), x: cxp, topY: cardsTop + 78, align: 1)
            if let s = subtitle { text(attr(s, 9.5, .regular, textLo), x: cxp, topY: cardsTop + 97, align: 1) }
            if showFix {
                let label = tr("Как починить?", "How to fix?")
                let lw = ceil(lineWidth(CTLineCreateWithAttributedString(ctAttr(label, ctFont(11, .semibold), cg(amber)))))
                let pw = lw + 26, ph: CGFloat = 24, pTop = cardsTop + 116
                let pr = rectTL(cxp - pw / 2, pTop, pw, ph)
                roundFill(pr, ph / 2, amber.withAlphaComponent(0.16))
                roundStroke(pr, ph / 2, amber.withAlphaComponent(0.5), 1)
                text(attr(label, 11, .semibold, amber), x: cxp, topY: pTop + 6, align: 1)
            }
        }
        switch d.auth {
        case .loggedOut:
            problemBody(tr("Вход не выполнен", "Not signed in"),
                        canFix ? tr("нужен вход Claude Code CLI", "sign in via Claude Code CLI") : nil, showFix: canFix)
            return
        case .keychainError:
            drawSF(ctx, "arrow.up.forward", in: rectTL(x + w - 21, cardsTop + 11, 11, 11), gray(1, 0.22), weight: .semibold)
            problemBody(tr("Нет доступа к keychain", "Keychain access failed"),
                        tr("проверьте доступ к «Связке ключей»", "check Keychain access"), showFix: false)
            return
        case .expired where d.session == nil && d.weekly == nil:
            problemBody(tr("Вход устарел", "Sign-in expired"),
                        d.asOf.map { tr("данные от ", "as of ") + fmtReset($0) }, showFix: canFix)
            return
        default: break
        }
        // Normal / stale-with-data card — the ring gauges.
        if d.auth == .ok {
            drawSF(ctx, "arrow.up.forward", in: rectTL(x + w - 21, cardsTop + 11, 11, 11), gray(1, 0.22), weight: .semibold)
        }
        let cx = x + w / 2, cyTop = cardsTop + 84
        // A frozen snapshot shouldn't masquerade as live: grey the ring + numbers and, below,
        // swap the reset times (which would otherwise show an impossible past moment) for a note.
        let stale = isStale(d)
        let sCol = metricIsStale(d, metric: "session") ? gray(1, 0.3) : metricColor(blue, d.session)
        let wCol = metricIsStale(d, metric: "weekly") ? gray(1, 0.3) : metricColor(purple, d.weekly)
        gauge(cx: cx, cyTop: cyTop, r: 38, th: 6, pct: d.weekly, color: wCol)
        gauge(cx: cx, cyTop: cyTop, r: 26, th: 6, pct: d.session, color: sCol)
        let sTxt = d.session == nil ? "—" : numText(d.session) + "%"
        let wTxt = d.weekly == nil ? "—" : numText(d.weekly) + "%"
        text(attr(sTxt, 15, .semibold, sCol), x: cx, topY: cyTop - 18, align: 1)
        text(attr(wTxt, 15, .semibold, wCol), x: cx, topY: cyTop + 1, align: 1)
        // The ring's lower opening carries one supplementary metric: Codex's banked resets
        // (⟳N), or — for Claude — the per-model weekly limit's own percentage (✦NN%), the
        // number that actually runs out first when you lean on a single model.
        // `symbol` is optional: the model pill is text-only so it stays narrow enough to sit
        // inside the ring's lower opening without touching the arc, and it carries a tinted
        // fill so a red 100% reads as its own object rather than a second bare red number.
        func pill(_ symbol: String?, _ label: String, _ color: NSColor, tinted: Bool = false) {
            let lw = ceil(lineWidth(CTLineCreateWithAttributedString(ctAttr(label, ctFont(10, .semibold), cg(color)))))
            let icoW: CGFloat = symbol == nil ? 0 : 9, midGap: CGFloat = symbol == nil ? 0 : 2.5
            let padL: CGFloat = symbol == nil ? 8 : 6, padR: CGFloat = symbol == nil ? 8 : 7, pillH: CGFloat = 16
            let pillW = padL + icoW + midGap + lw + padR
            let pillTop = cyTop + 22
            let pillR = rectTL(cx - pillW / 2, pillTop, pillW, pillH)
            roundFill(pillR, pillH / 2, tinted ? color.withAlphaComponent(0.16) : gray(1, 0.09))
            if tinted { roundStroke(pillR, pillH / 2, color.withAlphaComponent(0.42), 1) }
            if let sym = symbol {
                drawSF(ctx, sym, in: CGRect(x: pillR.minX + padL, y: pillR.midY - icoW / 2, width: icoW, height: icoW), color, weight: .semibold)
            }
            text(attr(label, 10, .semibold, color), x: pillR.minX + padL + icoW + midGap, topY: pillTop + (pillH - 10) / 2 - 0.5)
        }
        let scopedCol = metricIsStale(d, metric: "model") ? gray(1, 0.3) : (d.scoped.map { scopedColor($0.percent) } ?? SCOPED_COLOR)
        if !stale, let rc = d.resetCredits, rc >= 1 {
            pill("arrow.clockwise", "\(rc)", amber)
        } else if !stale, let s = d.scoped {
            pill(nil, numText(s.percent) + "%", scopedCol, tinted: true)
        }
        let l1 = cardsTop + 124, l2 = cardsTop + 139
        if stale || limitPollFailed(d) {
            // Keep the last good read distinct from the CLI's sign-in state.
            let copy = limitSimpleStaleCopy(d, product: product)
            let msg1 = copy.snapshot
            let icoW: CGFloat = 9, g: CGFloat = 4
            let tw = ceil(lineWidth(CTLineCreateWithAttributedString(ctAttr(msg1, ctFont(9.5, .regular), cg(amber)))))
            let bx = cx - (icoW + g + tw) / 2
            drawSF(ctx, "exclamationmark.triangle.fill", in: rectTL(bx, l1 + 1, icoW, icoW), amber)
            text(attr(msg1, 9.5, .regular, amber), x: bx + icoW + g, topY: l1)
            text(attr(copy.action, 9.5, canFix ? .semibold : .regular, canFix ? blue : textLo), x: cx, topY: l2, align: 1)
        } else {
            let lx = x + 16
            dot(lx, centerTopY: l1 + 5, sCol)
            text(attr(tr("Сессия", "Session"), 10.5, .regular, textMid), x: lx + 11, topY: l1)
            text(attr(limitResetText(d.sessionReset), 10, .regular, textLo), x: x + w - 14, topY: l1, align: 2)
            dot(lx, centerTopY: l2 + 5, wCol)
            text(attr(tr("Неделя", "Week"), 10.5, .regular, textMid), x: lx + 11, topY: l2)
            text(attr(limitResetText(d.weeklyReset), 10, .regular, textLo), x: x + w - 14, topY: l2, align: 2)
            // Per-model weekly limit — named by the backend, so a future model needs no code change.
            if showsScopedRow(d), let s = d.scoped {
                let l3 = l2 + SCOPED_ROW_H
                dot(lx, centerTopY: l3 + 5, scopedCol)
                text(attr(s.name, 10.5, .regular, textMid), x: lx + 11, topY: l3)
                text(attr(limitResetText(s.reset), 10, .regular, textLo), x: x + w - 14, topY: l3, align: 2)
            }
        }
    }

    if prods.count >= 2 {
        drawCard(pad, cardW, prods[0].0, name: prods[0].1, icon: prods[0].2, url: prods[0].3, product: prods[0].4)
        drawCard(pad + cardW + gap, cardW, prods[1].0, name: prods[1].1, icon: prods[1].2, url: prods[1].3, product: prods[1].4)
    } else if prods.count == 1 {
        drawCard(pad, W - pad * 2, prods[0].0, name: prods[0].1, icon: prods[0].2, url: prods[0].3, product: prods[0].4)
    } else {
        let empty = monitoringPaused() ? tr("Сбор статистики выключен", "Statistics collection is off")
            : tr("Выбранные подписки не найдены", "Selected subscriptions not found")
        text(attr(empty, 12, .regular, textMid), x: W / 2, topY: cardsTop + 62, align: 1)
        let r = rectTL(pad, cardsTop + 90, W - pad * 2, 26)
        text(attr(tr("Выбрать подписки в настройках ›", "Choose subscriptions in Settings ›"), 11, .medium, ADV_LINK), x: W / 2, topY: cardsTop + 95, align: 1)
        hits.append(Hit(id: "settings", rect: r))
    }

    // footer
    let footTop = cardsTop + cardH + 14
    hits += drawPollFooter(ctx, size: size, top: footTop, interval: interval, updated: updated, autoIntervals: autoIntervals)

    // credit line (authorship + version + clickable GitHub), like the reference app.
    // Anchored BELOW the interval row rather than at a fixed offset from the top: the cards
    // can grow (a per-model limit adds a row), and a hardcoded position would slide up into
    // the pills and strike through them.
    let divTopY = footTop + 24 + 8
    let divY = H - divTopY
    ctx.setStrokeColor(cg(gray(1, 0.06))); ctx.setLineWidth(1)
    ctx.beginPath(); ctx.move(to: CGPoint(x: pad, y: divY)); ctx.addLine(to: CGPoint(x: W - pad, y: divY)); ctx.strokePath()
    let creditPre = attr("Claude Codex Limits \(APP_VERSION) · by \(APP_AUTHOR) · ", 9.5, .regular, gray(1, 0.32))
    let creditLink = attr("GitHub", 9.5, .semibold, NSColor(srgbRed: 0.42, green: 0.62, blue: 0.96, alpha: 0.95))
    let preW = lineWidth(CTLineCreateWithAttributedString(creditPre))
    let linkW = lineWidth(CTLineCreateWithAttributedString(creditLink))
    let creditX = (W - preW - linkW) / 2
    let creditTop = divTopY + 9
    text(creditPre, x: creditX, topY: creditTop)
    text(creditLink, x: creditX + preW, topY: creditTop)
    hits.append(Hit(id: "open:\(REPO_URL)",
                    rect: CGRect(x: creditX + preW - 3, y: H - creditTop - 13, width: linkW + 6, height: 16)))

    return hits
}

// MARK: - Settings screen (same panel, same design language)

// MARK: - Advanced panel («Темп») — pace per window, history, money
//
// Geometry follows design/SPEC.md for direction A (all sizes in pt, top-left origin):
// header 40 · product cards (rows of 62 / 50 / 24) · collapsible "history & money" card
// (187 expanded, 35 collapsed) · footer 24. Height is derived from the same row model the
// draw pass uses, so the two can't disagree.

let ADV_W: CGFloat = 360
let ADV_CX: CGFloat = 15, ADV_CW: CGFloat = 330          // card x / width
let ADV_IX: CGFloat = 26, ADV_IW: CGFloat = 308          // card content x / width
let ADV_ROW_FULL: CGFloat = 62, ADV_ROW_SHORT: CGFloat = 50, ADV_ROW_CREDITS: CGFloat = 24
let ADV_NOTICE: CGFloat = 19, ADV_PLACEHOLDER: CGFloat = 40
let ADV_HIST_EXPANDED: CGFloat = 187, ADV_HIST_COLLAPSED: CGFloat = 35, ADV_HIST_EMPTY_EXTRA: CGFloat = 44

let ADV_SESSION = NSColor(srgbRed: 0.22, green: 0.55, blue: 1.00, alpha: 1)      // #388CFF
let ADV_WEEK    = NSColor(srgbRed: 0.78, green: 0.42, blue: 0.98, alpha: 1)      // #C76BFA
let ADV_WARN    = NSColor(srgbRed: 1.00, green: 0.63, blue: 0.04, alpha: 1)      // #FFA00A
let ADV_CRIT    = NSColor(srgbRed: 1.00, green: 0.27, blue: 0.23, alpha: 1)      // #FF453B
let ADV_ACCENT  = NSColor(srgbRed: 1.00, green: 0.62, blue: 0.18, alpha: 1)      // #FF9E2E
let ADV_LINK    = NSColor(srgbRed: 0.42, green: 0.62, blue: 0.96, alpha: 1)      // #6B9EF5
let ADV_MODEL   = [NSColor(srgbRed: 0.20, green: 0.85, blue: 0.70, alpha: 1),    // #33D9B3
                   NSColor(srgbRed: 0.99, green: 0.47, blue: 0.38, alpha: 1),    // #FC7861
                   NSColor(srgbRed: 0.98, green: 0.22, blue: 0.56, alpha: 1)]    // #FA388F

func advHistExpanded() -> Bool { UserDefaults.standard.bool(forKey: "advHistExpanded") }
func advHistProduct(_ present: [String]) -> String {
    let p = UserDefaults.standard.string(forKey: "advHistProduct") ?? ""
    return present.contains(p) ? p : (present.first ?? "claude")
}

/// Window colour by usage (spec §7.1): the window's own hue, amber from 50%, red from 80%.
func advWindowColor(_ kind: Int, _ used: Double?) -> NSColor {
    let u = used ?? 0
    if kind == 2 { return u >= 80 ? ADV_MODEL[2] : u >= 50 ? ADV_MODEL[1] : ADV_MODEL[0] }
    if u >= 80 { return ADV_CRIT }
    if u >= 50 { return ADV_WARN }
    return kind == 0 ? ADV_SESSION : ADV_WEEK
}

/// Stacked-bar colour family for a model id (spec §4.1) — models in one family merge into
/// one segment so Fable 5 and Fable 5.1 read as "Fable".
func advModelFamily(_ id: String, product: String) -> (name: String, color: NSColor) {
    if product == "claude" {
        if id.hasPrefix("claude-fable") { return ("Fable", ADV_MODEL[0]) }
        if id.hasPrefix("claude-opus") { return ("Opus", ADV_WEEK) }
        if id == "other" { return (tr("прочие", "other"), ADV_SESSION) }
        return (modelDisplayName(id).split(separator: " ").first.map(String.init) ?? id, ADV_SESSION)
    }
    if id.hasPrefix("gpt-6-astra") { return ("Astra", ADV_MODEL[1]) }
    if id.hasPrefix("gpt-5.6") { return ("Sol 5.6", ADV_LINK) }
    if id.hasPrefix("gpt-6-sol") { return ("Sol 6", ADV_MODEL[2]) }
    return (tr("прочие", "other"), gray(1, 0.28))
}

/// How one limit row is drawn — resolved once from the pace so the height pass and the
/// draw pass see the same thing.
enum AdvRowKind { case full, inactive, stale, tooEarly, exhausted, credits }
struct AdvRow {
    let limit: PacedLimit?
    let kind: AdvRowKind
    let credits: Int?
    var height: CGFloat {
        switch kind {
        case .full, .tooEarly, .exhausted: return ADV_ROW_FULL
        case .inactive, .stale: return ADV_ROW_SHORT
        case .credits: return ADV_ROW_CREDITS
        }
    }
}
/// Auth recovery belongs to the CLI whose confirmed sign-in state we can classify.
func limitCanFix(product: String, auth: AuthState) -> Bool {
    product == "claude" && (auth == .loggedOut || auth == .expired)
}

/// A paused snapshot alone says nothing about whether a CLI sign-in has expired.
func limitAuthBadge(_ auth: AuthState) -> String {
    switch auth {
    case .ok: return tr("данные устарели", "stale data")
    case .loggedOut: return tr("нет входа", "signed out")
    case .expired: return tr("вход истёк", "sign-in expired")
    case .keychainError: return tr("нет доступа", "read failed")
    }
}

func limitPausedNotice(asOf: Date?) -> String {
    guard let asOf = asOf, asOf.timeIntervalSince1970.isFinite, asOf <= Date() else { return tr("Нет свежих данных · темп не считаем", "No fresh data · pace paused") }
    return tr("Данные от ", "Data as of ") + advMomentLower(asOf) + tr(" · темп не считаем", " · pace paused")
}

func limitSimpleStaleCopy(_ d: LimitData, product: String) -> (snapshot: String, action: String) {
    let snapshot = d.asOf.map { tr("данные от ", "as of ") + fmtReset($0) } ?? tr("Нет свежих данных", "No fresh data")
    let action: String
    if limitCanFix(product: product, auth: d.auth) {
        action = tr("Вход устарел · Как починить?", "Sign-in expired · How to fix?")
    } else {
        action = limitPollFailed(d) ? limitRetryNotice(d, compact: true)
            : (d.asOf == nil ? tr("темп не считаем", "pace paused") : tr("обновите данные", "refresh data"))
    }
    return (snapshot, action)
}

func snapshotMoment(_ at: Date) -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.string(from: at)
}
func limitPollFailed(_ d: LimitData) -> Bool { d.pollFailed || d.error != nil }
func limitRetryNotice(_ d: LimitData, compact: Bool = false) -> String {
    let prefix = compact ? tr("Сбой · ", "Failed · ") : ""
    guard let at = d.nextPollAt else { return prefix + tr("повтор по расписанию", "scheduled retry") }
    guard at > Date() else { return prefix + tr("повтор ожидается", "retry due") }
    let f = DateFormatter(); f.dateFormat = "HH:mm"
    return prefix + tr("повтор в ", "retry at ") + f.string(from: at)
}
func withPollStatus(_ data: LimitData, state: AutoPollState?, next: Date?) -> LimitData {
    var data = data
    data.pollFailed = state?.failed == true
    data.nextPollAt = data.pollFailed ? next : nil
    return data
}
func limitSnapshotNotice(_ d: LimitData) -> String {
    guard d.auth == .ok, let at = d.asOf, at.timeIntervalSince1970.isFinite,
          at <= Date(), [(d.session, d.sessionReset, 5.0), (d.weekly, d.weeklyReset, 168.0),
                        (d.scoped?.percent, d.scoped?.reset, 168.0)].contains(where: {
              snapshotWindowPace(used: $0.0, reset: $0.1, windowH: $0.2, asOf: at) != nil
          })
    else { return limitPausedNotice(asOf: d.asOf) }
    return tr("Темп по снимку от ", "Pace from snapshot at ") + snapshotMoment(at)
}
func limitDataBadge(_ d: LimitData) -> String {
    if d.auth == .ok, limitPollFailed(d) { return tr("сбой обновления", "update failed") }
    return limitAuthBadge(d.auth)
}

struct AdvCard {
    let product: String, data: LimitData, name: String, icon: String, url: String
    let paused: Bool
    let rows: [AdvRow]
    var noticeHeight: CGFloat { ADV_NOTICE * ((limitCanFix(product: product, auth: data.auth) ? 2 : 1) + (limitPollFailed(data) ? 1 : 0)) }
    var height: CGFloat { 38 + rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) + noticeHeight }
}

func advCards(_ claude: LimitData, _ codex: LimitData) -> [AdvCard] {
    func card(_ d: LimitData, _ product: String) -> AdvCard {
        let paused = d.auth != .ok || isStale(d)
        let invalidTime = d.asOf.map { !$0.timeIntervalSince1970.isFinite || $0 > Date() } ?? true
        var limits = pacedLimits(d, product: product)
        if product == "codex" { limits.sort { a, _ in a.id == "weekly" } }        // Codex: week first
        var rows: [AdvRow] = limits.map { l in
            guard let p = l.pace else { return AdvRow(limit: l, kind: .inactive, credits: nil) }
            if d.auth != .ok || invalidTime || p.reset <= Date() { return AdvRow(limit: l, kind: .stale, credits: nil) }
            if p.used >= 100 { return AdvRow(limit: l, kind: .exhausted, credits: nil) }
            if p.elapsedH < 10.0 / 60 || p.used < 2 { return AdvRow(limit: l, kind: .tooEarly, credits: nil) }
            return AdvRow(limit: l, kind: .full, credits: nil)
        }
        if product == "codex" { rows.append(AdvRow(limit: nil, kind: .credits, credits: d.resetCredits ?? 0)) }
        return AdvCard(product: product, data: d,
                       name: product == "claude" ? "Claude Code" : "Codex",
                       icon: product == "claude" ? "claude_128.png" : "codex_128.png",
                       url: product == "claude" ? "https://claude.ai/settings/usage" : "https://chatgpt.com/codex/cloud/settings/analytics#usage",
                       paused: paused, rows: rows)
    }
    var out: [AdvCard] = []
    if productEnabled("claude"), claude.present { out.append(card(claude, "claude")) }
    if productEnabled("codex"), codex.present { out.append(card(codex, "codex")) }
    return out
}

func advHistoryHeight(_ cards: [AdvCard]) -> CGFloat {
    let warn: CGFloat = syncWarning() != nil ? ADV_NOTICE : 0      // orange sync line under the header
    guard advHistExpanded() else { return ADV_HIST_COLLAPSED + warn }
    let present = cards.map { $0.product }
    let p = advHistProduct(present)
    let noHistory = UsageHistory.shared.samples(p, since: Date(timeIntervalSince1970: 0)).isEmpty
    return ADV_HIST_EXPANDED + (noHistory ? ADV_HIST_EMPTY_EXTRA : 0) + warn
}

func showMissingProduct(_ cards: [AdvCard]) -> Bool {
    cards.count == 1 && productEnabled(cards[0].product == "claude" ? "codex" : "claude")
}

func advancedHeight(_ claude: LimitData, _ codex: LimitData) -> CGFloat {
    let cards = advCards(claude, codex)
    if cards.isEmpty { return panelMainHeight(LimitData(present: false), LimitData(present: false)) }
    var h: CGFloat = 94
    for c in cards { h += 5 + c.height }
    if showMissingProduct(cards) { h += 5 + ADV_PLACEHOLDER }
    h += 5 + advHistoryHeight(cards)
    return h + ADV_CREDIT_H
}
/// Credit line under the footer (author · version · GitHub), same as in the Simple view —
/// the first Advanced build dropped it and the repo link went missing (Alex, 2026-09-27).
let ADV_CREDIT_H: CGFloat = 24

/// Main-panel height for whichever view is on.
func mainPanelHeight(_ claude: LimitData, _ codex: LimitData) -> CGFloat {
    advancedEnabled() ? advancedHeight(claude, codex) : panelMainHeight(claude, codex)
}

// Spec §6.4 — reset moment for the metrics line: "11:50" today, else "пн, 03:00".
func advResetShort(_ d: Date) -> String {
    let f = DateFormatter(); f.locale = Locale(identifier: appLang() == "ru" ? "ru_RU" : "en_US")
    if Calendar.current.isDateInToday(d) { f.dateFormat = "HH:mm"; return f.string(from: d) }
    f.dateFormat = "EEE, HH:mm"
    let s = f.string(from: d).replacingOccurrences(of: ".", with: "")
    return appLang() == "ru" ? s.lowercased() : s
}
func advMomentLower(_ d: Date) -> String {
    let s = fmtMoment(d)
    return appLang() == "ru" ? s.prefix(1).lowercased() + s.dropFirst() : s
}
func advVerdict(_ row: AdvRow, asOf: Date?) -> String {
    if row.kind == .stale {
        let prefix = row.limit?.pace.map { $0.reset <= Date() } == true
            ? tr("Окно сброшено · снимок ", "Window reset · snapshot ") : tr("по данным на ", "as of ")
        return asOf.map { prefix + advMomentLower($0) } ?? limitPausedNotice(asOf: nil)
    }
    guard let p = row.limit?.pace else {
        return row.limit?.used != nil ? tr("Нет времени окна · темп не считаем", "Window timing unknown · pace paused")
            : tr("Окно не активно · откроется с первым запросом", "Window inactive · opens with the first request")
    }
    if let at = asOf, Date().timeIntervalSince(at) > SNAPSHOT_MAX_AGE {
        return p.projectedPct.map { tr("Прогноз на снимке: ", "Snapshot forecast: ") + fmtPct($0, decimals: 0) }
            ?? tr("На снимке мало данных для темпа", "Not enough pace data in snapshot")
    }
    switch row.kind {
    case .exhausted: return tr("Лимит исчерпан · сброс в ", "Limit reached · resets at ") + advMomentLower(p.reset)
    case .tooEarly: return tr("Мало данных для темпа · сброс в ", "Not enough data for pace · resets at ") + advMomentLower(p.reset)
    default: break
    }
    if let at = p.runsOutAt {
        let before = p.reset.timeIntervalSince(at) / 3600
        return tr("Кончится в ", "Runs out at ") + advMomentLower(at) + tr(", за ", ", ") + fmtSpan(before) + tr(" до сброса", " before reset")
    }
    if let proj = p.projectedPct {
        if proj.rounded() >= 85 { return tr("Хватит впритык (прогноз ", "Barely lasts (forecast ") + fmtPct(proj, decimals: 0) + ")" }
        return tr("Хватит до сброса (прогноз ", "Lasts until reset (forecast ") + fmtPct(proj, decimals: 0) + ")"
    }
    return tr("Хватит до сброса", "Lasts until reset")
}

@discardableResult
func drawAdvanced(_ ctx: CGContext, size: CGSize, claude: LimitData, codex: LimitData,
                  interval: TimeInterval, updated: Date?, about: AboutState, autoIntervals: [String: TimeInterval] = [:]) -> [Hit] {
    if advCards(claude, codex).isEmpty {
        return drawPanel(ctx, size: size, claude: LimitData(present: false), codex: LimitData(present: false),
                         interval: interval, updated: updated, about: about, autoIntervals: autoIntervals)
    }
    let W = size.width, H = size.height
    var hits: [Hit] = []
    let cs = CGColorSpaceCreateDeviceRGB()
    let textHi = gray(1, 0.95), textMid = gray(1, 0.5), textLo = gray(1, 0.34)

    func rectTL(_ x: CGFloat, _ topY: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: H - topY - h, width: w, height: h)
    }
    func attr(_ s: String, _ sz: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, kern: CGFloat = 0) -> NSAttributedString {
        let a = NSMutableAttributedString(attributedString: ctAttr(s, ctFont(sz, weight), cg(color)))
        if kern != 0 { a.addAttribute(NSAttributedString.Key(kCTKernAttributeName as String), value: kern, range: NSRange(location: 0, length: a.length)) }
        return a
    }
    func caps(_ s: String, _ sz: CGFloat, _ color: NSColor) -> NSAttributedString { attr(s.uppercased(), sz, .semibold, color, kern: sz * 0.06) }
    func width(_ a: NSAttributedString) -> CGFloat { ceil(lineWidth(CTLineCreateWithAttributedString(a))) }
    /// Draw with the text's cap-top at `topY` (approximated by the ascender) — the same
    /// convention as the other screens.
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
    /// Draw with the baseline at `baseY` — for chart labels the spec positions by baseline.
    func textB(_ s: NSAttributedString, x: CGFloat, baseY: CGFloat, align: Int = 0) {
        let line = CTLineCreateWithAttributedString(s)
        let w = lineWidth(line)
        var dx = x
        if align == 1 { dx = x - w / 2 } else if align == 2 { dx = x - w }
        ctx.textMatrix = .identity
        ctx.textPosition = CGPoint(x: dx, y: H - baseY)
        CTLineDraw(line, ctx)
    }
    /// Vertically centre a single line in a box of height `h` whose top is `topY`.
    func textC(_ s: NSAttributedString, x: CGFloat, topY: CGFloat, h: CGFloat, align: Int = 0) {
        let line = CTLineCreateWithAttributedString(s)
        var asc: CGFloat = 0, desc: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &asc, &desc, nil)
        text(s, x: x, topY: topY + (h - asc - desc) / 2 + desc * 0.15, align: align)
    }
    func roundFill(_ r: CGRect, _ rad: CGFloat, _ color: NSColor) {
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: min(rad, r.height / 2, r.width / 2), cornerHeight: min(rad, r.height / 2, r.width / 2), transform: nil))
        ctx.setFillColor(cg(color)); ctx.fillPath()
    }
    func roundStroke(_ r: CGRect, _ rad: CGFloat, _ color: NSColor, _ lw: CGFloat) {
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: min(rad, r.height / 2), cornerHeight: min(rad, r.height / 2), transform: nil))
        ctx.setStrokeColor(cg(color)); ctx.setLineWidth(lw); ctx.strokePath()
    }
    func hline(_ x0: CGFloat, _ x1: CGFloat, _ topY: CGFloat, _ color: NSColor) {
        ctx.setStrokeColor(cg(color)); ctx.setLineWidth(1)
        ctx.beginPath(); ctx.move(to: CGPoint(x: x0, y: H - topY - 0.5)); ctx.addLine(to: CGPoint(x: x1, y: H - topY - 0.5)); ctx.strokePath()
    }
    func dot(_ cx: CGFloat, _ cyTop: CGFloat, _ color: NSColor, r: CGFloat = 3) {
        ctx.setFillColor(cg(color)); ctx.fillEllipse(in: CGRect(x: cx - r, y: H - cyTop - r, width: 2 * r, height: 2 * r))
    }
    /// A rounded pill with a label; returns its rect.
    @discardableResult
    func pill(_ label: NSAttributedString, x: CGFloat, topY: CGFloat, h: CGFloat, padX: CGFloat, fill: NSColor, stroke: NSColor? = nil, rightAligned: Bool = false) -> CGRect {
        let w = width(label) + padX * 2
        let r = rectTL(rightAligned ? x - w : x, topY, w, h)
        roundFill(r, h / 2, fill)
        if let s = stroke { roundStroke(r.insetBy(dx: 0.5, dy: 0.5), h / 2, s, 1) }
        textC(label, x: r.midX, topY: topY, h: h, align: 1)
        return r
    }

    // ---- background (same as the simple panel) ----
    let bgPath = CGPath(roundedRect: CGRect(x: 0.5, y: 0.5, width: W - 1, height: H - 1), cornerWidth: 18, cornerHeight: 18, transform: nil)
    ctx.saveGState(); ctx.addPath(bgPath); ctx.clip()
    if let g = CGGradient(colorsSpace: cs, colors: [cg(gray(0.16, 1)), cg(gray(0.075, 1))] as CFArray, locations: [0, 1]) {
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])
    }
    if let glow = CGGradient(colorsSpace: cs, colors: [cg(NSColor(srgbRed: 1, green: 0.5, blue: 0.2, alpha: 0.10)), cg(NSColor(srgbRed: 1, green: 0.5, blue: 0.2, alpha: 0))] as CFArray, locations: [0, 1]) {
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 30, y: H - 20), startRadius: 0, endCenter: CGPoint(x: 30, y: H - 20), endRadius: 170, options: [])
    }
    ctx.restoreGState()
    ctx.addPath(bgPath); ctx.setStrokeColor(cg(gray(1, 0.08))); ctx.setLineWidth(1); ctx.strokePath()

    // ---- header (y 13…53) ----
    if let img = loadCGImage(assetPath("appicon.png")) { ctx.draw(img, in: rectTL(15, 13, 40, 40)) }
    let title = attr(tr("Лимиты", "Limits"), 16, .semibold, textHi)
    textC(title, x: 65, topY: 15.5, h: 20)
    pill(caps("Advanced", 9, gray(1, 0.55)), x: 65 + width(title) + 7, topY: 15.5 + 2.5, h: 15, padX: 7, fill: gray(1, 0.09))
    // legend: ▍план сейчас · ▬ прогноз к сбросу
    do {
        var x: CGFloat = 65
        let ly: CGFloat = 37.5, lh: CGFloat = 13
        roundFill(rectTL(x + 2, ly + 1.5, 2, 10), 1, gray(1, 0.55)); x += 6 + 4
        let a = attr(tr("план сейчас", "plan now"), 10.5, .regular, textMid); textC(a, x: x, topY: ly, h: lh); x += width(a) + 4
        let d = attr("·", 10.5, .regular, textMid); textC(d, x: x + 2, topY: ly, h: lh); x += width(d) + 4 + 4
        roundFill(rectTL(x, ly + 4, 16, 5), 2.5, gray(1, 0.30)   /* neutral: the tail takes each row's own colour */); x += 16 + 4
        textC(attr(tr("прогноз к сбросу", "forecast to reset"), 10.5, .regular, textMid), x: x, topY: ly, h: lh)
    }
    let gearRect = rectTL(297, 24, 18, 18), rfRect = rectTL(327, 24, 18, 18)
    drawSF(ctx, "gearshape", in: gearRect, textMid)
    drawSF(ctx, "arrow.clockwise", in: rfRect.insetBy(dx: 1, dy: 1), textMid, weight: .semibold)
    hits.append(Hit(id: "settings", rect: gearRect.insetBy(dx: -6, dy: -6)))
    hits.append(Hit(id: "refresh", rect: rfRect.insetBy(dx: -6, dy: -6)))
    if about.availVersion != nil || about.phase != .idle {
        let badge = CGRect(x: gearRect.maxX - 5, y: gearRect.maxY - 5, width: 7, height: 7)
        ctx.setFillColor(cg(gray(0.10, 1))); ctx.fillEllipse(in: badge.insetBy(dx: -1.5, dy: -1.5))
        ctx.setFillColor(cg(ADV_ACCENT)); ctx.fillEllipse(in: badge)
    }

    // ---- product cards ----
    let cards = advCards(claude, codex)
    var y: CGFloat = 58

    func drawRow(_ row: AdvRow, topY yr: CGFloat, dimmed: Bool, rowAsOf: Date?) {
        if row.kind == .credits {
            let n = row.credits ?? 0
            let on = n > 0
            dot(ADV_IX + 3, yr + 14.5, on ? ADV_ACCENT : gray(1, 0.22))
            textC(caps(tr("Сбросы в запасе", "Resets in reserve"), 9.5, on ? textMid : textLo), x: ADV_IX + 12, topY: yr + 6, h: 17)
            let num = attr("\(n)", 11, .semibold, on ? ADV_ACCENT : textLo)
            let pw = 6 + 11 + 4 + width(num) + 7
            let pr = rectTL(ADV_IX + ADV_IW - pw, yr + 6, pw, 17)
            roundFill(pr, 8.5, on ? ADV_ACCENT.withAlphaComponent(0.16) : gray(1, 0.09))
            if on { roundStroke(pr.insetBy(dx: 0.5, dy: 0.5), 8.5, ADV_ACCENT.withAlphaComponent(0.42), 1) }
            drawSF(ctx, "arrow.clockwise", in: CGRect(x: pr.minX + 6, y: pr.midY - 5.5, width: 11, height: 11), on ? ADV_ACCENT : textLo, weight: .semibold)
            textC(num, x: pr.minX + 6 + 11 + 4, topY: yr + 6, h: 17)
            return
        }
        guard let l = row.limit else { return }
        let pace = l.pace
        let live = row.kind == .full || row.kind == .exhausted || row.kind == .tooEarly || row.kind == .stale
        let col = live ? advWindowColor(l.color, pace?.used) : gray(1, 0.22)
        if dimmed { ctx.saveGState(); ctx.setAlpha(0.42) }
        // L1: dot · label · percent
        dot(ADV_IX + 3, yr + 11, live ? col : gray(1, 0.22))
        textC(caps(l.name, 9.5, row.kind == .inactive ? textLo : textMid), x: ADV_IX + 12, topY: yr + 4, h: 14)
        if let used = pace?.used ?? l.used, used.isFinite {
            textC(attr(fmtPct(used, decimals: 0), 14, .semibold, col, kern: -0.14), x: ADV_IX + ADV_IW, topY: yr + 4, h: 14, align: 2)
        } else {
            textC(attr("—", 14, .semibold, textLo), x: ADV_IX + ADV_IW, topY: yr + 4, h: 14, align: 2)
        }
        // L2: verdict
        let verdictColor: NSColor, verdictWeight: NSFont.Weight
        switch row.kind {
        case .full:
            if let p = pace, p.runsOutAt != nil { verdictColor = ADV_CRIT; verdictWeight = .semibold }
            else if let p = pace, let pr = p.projectedPct, pr.rounded() >= 85 { verdictColor = ADV_WARN; verdictWeight = .semibold }
            else { verdictColor = textHi; verdictWeight = .semibold }
        case .exhausted: verdictColor = ADV_CRIT; verdictWeight = .semibold
        default: verdictColor = textMid; verdictWeight = .regular
        }
        var verdict = advVerdict(row, asOf: rowAsOf)
        var va = attr(verdict, 12.5, verdictWeight, verdictColor)
        if width(va) > ADV_IW {                                   // spec §3.2 truncation ladder
            var s = verdict.replacingOccurrences(of: tr(" до сброса", " before reset"), with: "")
            va = attr(s, 12.5, verdictWeight, verdictColor)
            while width(va) > ADV_IW, s.count > 8 { s = String(s.dropLast(2)) + "…"; va = attr(s, 12.5, verdictWeight, verdictColor) }
        }
        textC(va, x: ADV_IX, topY: yr + 19, h: 16)
        // bar
        let barTop = yr + 38
        roundFill(rectTL(ADV_IX, barTop, ADV_IW, 5), 2.5, gray(1, 0.08))
        if let p = pace, live {
            let usedW = CGFloat(min(100, max(0, p.used))) / 100 * ADV_IW
            if row.kind == .full || row.kind == .exhausted {
                if p.runsOutAt != nil, row.kind == .full {
                    roundFill(rectTL(ADV_IX, barTop, ADV_IW, 5), 2.5, ADV_CRIT.withAlphaComponent(0.22))
                } else if row.kind == .full, let pr = p.projectedPct, pr > p.used {
                    let ghostW = CGFloat(min(100, pr)) / 100 * ADV_IW
                    roundFill(rectTL(ADV_IX, barTop, ghostW, 5), 2.5, col.withAlphaComponent(0.30))   // same hue as the fill (Alex, 2026-09-27)
                }
            }
            if usedW >= 1 { roundFill(rectTL(ADV_IX, barTop, max(5, usedW), 5), 2.5, col) }
            if row.kind != .stale {
                let tx = ADV_IX + CGFloat(p.planPct) / 100 * ADV_IW - 1
                roundFill(rectTL(tx, barTop - 3, 2, 11), 1, gray(1, 0.55))
            }
        }
        // L3: metrics
        if row.kind == .full || row.kind == .exhausted || row.kind == .tooEarly, let p = pace {
            let m = NSMutableAttributedString()
            m.append(attr(tr("план ", "plan ") + fmtPct(p.planPct) + " · ", 10.5, .regular, textMid))
            m.append(attr(fmtSignedPts(p.deltaPts), 10.5, .regular, p.deltaPts >= 0 ? ADV_WARN : textMid))
            let rate = row.kind == .tooEarly ? "—" : fmtRate(p)
            m.append(attr(" · " + rate + " · " + tr("сброс ", "reset ") + advResetShort(p.reset), 10.5, .regular, textMid))
            textC(m, x: ADV_IX, topY: yr + 46, h: 12)
        }
        if dimmed { ctx.restoreGState() }
    }

    for c in cards {
        let ch = c.height
        let card = rectTL(ADV_CX, y, ADV_CW, ch)
        roundFill(card, 14, gray(1, 0.04)); roundStroke(card.insetBy(dx: 0.5, dy: 0.5), 14, gray(1, 0.06), 1)
        let canFix = limitCanFix(product: c.product, auth: c.data.auth)
        // header
        let y0 = y + 9
        if let img = loadCGImage(assetPath(c.icon)) { ctx.draw(img, in: rectTL(ADV_IX, y0 + 1, 16, 16)) }
        let name = attr(c.name, 13, .semibold, textHi)
        textC(name, x: ADV_IX + 23, topY: y0, h: 18)
        var px = ADV_IX + 23 + width(name) + 7
        if c.paused || limitPollFailed(c.data) {
            let r = pill(attr(limitDataBadge(c.data), 9.5, .semibold, ADV_WARN, kern: 0.19), x: px, topY: y0 + 1, h: 16, padX: 7, fill: ADV_WARN.withAlphaComponent(0.16), stroke: ADV_WARN.withAlphaComponent(0.42))
            px = r.maxX + 5
        }
        if let plan = c.data.plan {
            let label = c.product == "claude" ? (plan == "max" ? (UserDefaults.standard.string(forKey: "claudeTier")?.contains("20x") == true ? "Max 20x" : "Max") : plan.capitalized) : plan
            pill(attr(label, 9.5, .semibold, gray(1, 0.60), kern: 0.19), x: px, topY: y0 + 1, h: 16, padX: 7, fill: gray(1, 0.09))
        }
        let arrow = rectTL(322, y0 + 3, 12, 12)
        drawSF(ctx, "arrow.up.forward", in: arrow, gray(1, 0.34), weight: .semibold)
        hits.append(Hit(id: canFix ? "claudefix" : "open:\(c.url)", rect: canFix ? card : arrow.insetBy(dx: -8, dy: -8)))
        var ry = y + 29
        do {
            textC(attr(limitSnapshotNotice(c.data), 10.5, .regular, ADV_WARN), x: ADV_IX, topY: ry, h: 14)
            if canFix {
                let code = ctAttr("claude → /login", ctMono(10, .regular), cg(gray(1, 0.8)))
                let codeR = rectTL(ADV_IX, ry + ADV_NOTICE + 0.5, width(code) + 8, 14)
                roundFill(codeR, 4, gray(1, 0.08))
                textC(code, x: codeR.minX + 4, topY: ry + ADV_NOTICE, h: 14)
            }
            if limitPollFailed(c.data) {
                let offset = ADV_NOTICE * (canFix ? 2 : 1)
                textC(attr(limitRetryNotice(c.data), 10.5, .regular, ADV_WARN), x: ADV_IX, topY: ry + offset, h: 14)
            }
            ry += c.noticeHeight
        }
        for (i, row) in c.rows.enumerated() {
            drawRow(row, topY: ry, dimmed: (c.paused || row.kind == .stale) && row.kind != .credits, rowAsOf: c.data.asOf)
            ry += row.height
            if i < c.rows.count - 1 { hline(ADV_IX, ADV_IX + ADV_IW, ry, gray(1, 0.06)); ry += 1 }
        }
        y += ch + 5
    }
    if showMissingProduct(cards) {
        // the other product isn't set up — a dashed invitation instead of an empty card
        let r = rectTL(ADV_CX, y, ADV_CW, ADV_PLACEHOLDER)
        ctx.saveGState(); ctx.setLineDash(phase: 0, lengths: [4, 3])
        roundStroke(r.insetBy(dx: 0.5, dy: 0.5), 14, gray(1, 0.14), 1)
        roundStroke(rectTL(ADV_IX, y + 12, 16, 16).insetBy(dx: 0.5, dy: 0.5), 4, gray(1, 0.28), 1)
        ctx.restoreGState()
        let missing = cards[0].product == "claude" ? "Codex" : "Claude Code"
        textC(attr(missing + tr(" не настроен", " not set up"), 13, .medium, textMid), x: ADV_IX + 23, topY: y, h: ADV_PLACEHOLDER)
        textC(attr(tr("Настройки ›", "Settings ›"), 13, .regular, ADV_LINK), x: ADV_IX + ADV_IW, topY: y, h: ADV_PLACEHOLDER, align: 2)
        hits.append(Hit(id: cards[0].product == "codex" ? "claudefix" : "settings", rect: r))
        y += ADV_PLACEHOLDER + 5
    }

    // ---- history & money ----
    let present = cards.map { $0.product }
    let hp = advHistProduct(present)
    let expanded = advHistExpanded()
    let hh = advHistoryHeight(cards)
    let hcard = rectTL(ADV_CX, y, ADV_CW, hh)
    roundFill(hcard, 14, gray(1, 0.04)); roundStroke(hcard.insetBy(dx: 0.5, dy: 0.5), 14, gray(1, 0.06), 1)
    let hy = y + 8                                  // border 1 + padding 7
    drawSF(ctx, expanded ? "chevron.down" : "chevron.right", in: rectTL(ADV_IX, hy + 4.5, 8, 9), textLo, weight: .semibold)
    let others = syncOtherMachines()
    let histCap = tr("История и деньги", "History & money") + (others > 0 ? tr(" · \(others + 1) ПК", " · \(others + 1) PCs") : "")
    textC(caps(histCap, 9.5, textLo), x: ADV_IX + 14, topY: hy, h: 18)
    // Stops above the orange sync line when there is one (hit-test takes the first match).
    hits.append(Hit(id: "hist:toggle", rect: rectTL(ADV_CX, y, 200, syncWarning() != nil ? hy + 18 - y : 35)))
    do {   // Claude | Codex segmented, right-aligned
        let items = present.map { ($0, $0 == "claude" ? "Claude" : "Codex") }
        let widths = items.map { width(attr($0.1, 10.5, .semibold, textHi)) + 16 }
        let total = widths.reduce(0, +) + CGFloat(items.count - 1) + 4
        let tx = ADV_IX + ADV_IW - total
        roundFill(rectTL(tx, hy, total, 18), 9, gray(1, 0.07))
        var sx = tx + 2
        for (i, it) in items.enumerated() {
            let r = rectTL(sx, hy + 2, widths[i], 14)
            let on = it.0 == hp
            if on { roundFill(r, 7, gray(1, 0.18)) }
            textC(attr(it.1, 10.5, on ? .semibold : .medium, on ? textHi : textMid), x: r.midX, topY: hy + 2, h: 14, align: 1)
            hits.append(Hit(id: "hist:\(it.0)", rect: r.insetBy(dx: -2, dy: -4)))
            sx += widths[i] + 1
        }
    }
    // Sync stalled / revoked: one orange line under the header, in both collapsed and expanded
    // states — the totals below silently miss the other computers otherwise. Tap → Settings.
    var warnH: CGFloat = 0
    if let w = syncWarning() {
        let a = fitAttr(w, maxW: ADV_IW) { attr($0, 10.5, .regular, ADV_WARN) }
        textC(a, x: ADV_IX, topY: hy + 18 + 1, h: ADV_NOTICE - 2)
        hits.append(Hit(id: "settings", rect: rectTL(ADV_IX, hy + 18, ADV_IW, ADV_NOTICE)))
        warnH = ADV_NOTICE
    }
    if expanded {
        let ix = mergedUsageIndex()
        let d = hp == "claude" ? claude : codex
        let ap = advancedProduct(d, product: hp, index: ix)
        let by = hy + 18 + 4 + warnH                // body top
        // -- 7-day stacked bars (x 26…216) --
        let cx0 = ADV_IX, cy0 = by
        textC(caps(tr("7 дней · $ по API", "7 days · $ at API"), 8.5, textLo), x: cx0, topY: cy0, h: 12)
        do {
            let lg = attr(tr("окно недели", "week window"), 8.5, .regular, textMid)
            textC(lg, x: cx0 + 190, topY: cy0, h: 12, align: 2)
            roundFill(rectTL(cx0 + 190 - width(lg) - 4 - 10, cy0 + 5, 10, 2), 1, ADV_WEEK.withAlphaComponent(0.7))
        }
        let gx = cx0, gy = cy0 + 12                 // chart local origin
        hline(gx + 2, gx + 188, gy + 40, gray(1, 0.08))
        let maxUsd = ap.days7.map { $0.usd }.max() ?? 0
        let weekStart = d.weeklyReset.map { $0.addingTimeInterval(-168 * 3600) }
        var underlineFrom: CGFloat? = nil
        var families: [String: NSColor] = [:]; var familyOrder: [String] = []
        for (i, day) in ap.days7.enumerated() {
            let bx = gx + 6 + 26 * CGFloat(i)
            if day.usd > 0, maxUsd > 0 {
                let h = max(2, 28 * CGFloat(day.usd / maxUsd))
                // merge parts into colour families, biggest at the bottom
                var fam: [(String, NSColor, Double)] = []
                for part in day.parts {
                    let f = advModelFamily(part.model, product: hp)
                    if let j = fam.firstIndex(where: { $0.0 == f.name }) { fam[j].2 += part.usd } else { fam.append((f.name, f.color, part.usd)) }
                }
                fam.sort { $0.2 > $1.2 }
                var top = gy + 40
                ctx.saveGState()
                ctx.addPath(CGPath(roundedRect: rectTL(bx, gy + 40 - h, 18, h), cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)); ctx.clip()
                for f in fam {
                    let sh = max(0.6, h * CGFloat(f.2 / day.usd))
                    ctx.setFillColor(cg(f.1)); ctx.fill(rectTL(bx, top - sh, 18, sh)); top -= sh
                    if families[f.0] == nil { families[f.0] = f.1; familyOrder.append(f.0) }
                }
                ctx.restoreGState()
                textB(attr("$" + String(Int(day.usd.rounded())), 8.5, .semibold, gray(1, 0.7)), x: bx + 9, baseY: gy + 40 - h - 3, align: 1)
            } else {
                roundFill(rectTL(bx, gy + 38.5, 18, 1.5), 0.75, gray(1, 0.12))
            }
            let dayDate = dayKeyFormatter.date(from: day.day) ?? Date()
            let f = DateFormatter(); f.locale = Locale(identifier: appLang() == "ru" ? "ru_RU" : "en_US"); f.dateFormat = "EEE"
            let dn = f.string(from: dayDate).replacingOccurrences(of: ".", with: "")
            textB(attr(appLang() == "ru" ? dn.lowercased() : dn, 9, day.isToday ? .semibold : .regular, day.isToday ? ADV_ACCENT : textMid), x: bx + 9, baseY: gy + 50, align: 1)
            if let ws = weekStart, underlineFrom == nil, dayDate.addingTimeInterval(86400) > ws { underlineFrom = bx }
        }
        if let uf = underlineFrom { roundFill(rectTL(uf, gy + 53.5, gx + 6 + 26 * 6 + 18 - uf, 1.5), 0.75, ADV_WEEK.withAlphaComponent(0.55)) }
        // legend (fixed family order per product)
        do {
            let order = hp == "claude" ? ["Fable", "Opus", tr("прочие", "other")] : ["Astra", "Sol 5.6", "Sol 6", tr("прочие", "other")]
            var lx = cx0
            for name in order {
                let color = families[name] ?? (hp == "claude" ? advModelFamily(name == "Fable" ? "claude-fable" : name == "Opus" ? "claude-opus" : "other", product: hp).color
                                                              : advModelFamily(name == "Astra" ? "gpt-6-astra" : name == "Sol 5.6" ? "gpt-5.6-sol" : name == "Sol 6" ? "gpt-6-sol" : "other", product: hp).color)
                let seen = families[name] != nil
                roundFill(rectTL(lx, cy0 + 71 + 2, 7, 7), 2, seen ? color : color.withAlphaComponent(0.25))
                let a = attr(name, 8.5, .regular, seen ? textMid : textLo)
                textC(a, x: lx + 11, topY: cy0 + 71, h: 11)
                lx += 11 + width(a) + 7
            }
        }
        // -- 35-day calendar (x 230…326) --
        let kx = ADV_IX + 204, ky = cy0
        let cal = Array(ap.calendar.suffix(35))
        let total35 = cal.reduce(0) { $0 + $1.usd }
        textC(caps(tr("35 дней · ", "35 days · ") + fmtUSD(total35), 8.5, textLo), x: kx, topY: ky, h: 12)
        let letters = appLang() == "ru" ? ["п", "в", "с", "ч", "п", "с", "в"] : ["M", "T", "W", "T", "F", "S", "S"]
        for (c, l) in letters.enumerated() { textB(attr(l, 7, .regular, textLo), x: kx + 9.5 * CGFloat(c) + 4, baseY: ky + 12 + 7, align: 1) }
        let levels: [Double] = hp == "claude" ? [10, 30, 60] : [5, 30, 100]
        let calCal = Calendar.current
        var row = 0, col = 0
        if let first = cal.first, let fd = dayKeyFormatter.date(from: first.day) {
            let wd = calCal.component(.weekday, from: fd); col = wd == 1 ? 6 : wd - 2
        }
        var labelledRows = Set<Int>()
        for (i, dd) in cal.enumerated() {
            let cellX = kx + 9.5 * CGFloat(col), cellY = ky + 12 + 10 + 9.5 * CGFloat(row)
            let color: NSColor
            if dd.usd <= 0 { color = gray(1, 0.06) }
            else { let a: CGFloat = dd.usd <= levels[0] ? 0.28 : dd.usd <= levels[1] ? 0.50 : dd.usd <= levels[2] ? 0.75 : 1.0; color = ADV_ACCENT.withAlphaComponent(a) }
            roundFill(rectTL(cellX, cellY, 7.5, 7.5), 2, color)
            if dd.day == dayKey(Date()) { roundStroke(rectTL(cellX, cellY, 7.5, 7.5).insetBy(dx: 0.5, dy: 0.5), 2, gray(1, 0.7), 1) }
            if let dt = dayKeyFormatter.date(from: dd.day), (i == 0 || calCal.component(.day, from: dt) == 1), !labelledRows.contains(row) {
                labelledRows.insert(row)
                let mi = calCal.component(.month, from: dt) - 1
                let names = appLang() == "ru" ? ["янв", "фев", "мар", "апр", "мая", "июн", "июл", "авг", "сен", "окт", "ноя", "дек"]
                                              : ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
                textB(attr(names[mi], 7, .regular, textLo), x: kx + 71, baseY: cellY + 7)
            }
            col += 1; if col == 7 { col = 0; row += 1 }
        }
        // -- money table --
        var my = by + 82
        if ap.firstSample == nil {
            // first day: no sampled history yet — say so instead of showing empty charts as data
            let bx = rectTL(ADV_IX, my + 2, ADV_IW, ADV_HIST_EMPTY_EXTRA - 6)
            roundFill(bx, 8, gray(1, 0.04))
            let msg = tr("Истории пока нет — копим с сегодняшнего дня. Столбики появятся завтра, календарь заполнится за неделю. Темп выше уже работает: ему история не нужна.",
                         "No history yet — collecting from today. Bars appear tomorrow, the calendar fills over a week. Pace above already works: it needs no history.")
            let para = NSMutableAttributedString(attributedString: attr(msg, 10.5, .regular, textMid))
            let ps = NSMutableParagraphStyle(); ps.lineSpacing = 1.5
            let fs = CTFramesetterCreateWithAttributedString(para)
            let path = CGPath(rect: bx.insetBy(dx: 8, dy: 5), transform: nil)
            ctx.saveGState(); ctx.textMatrix = .identity
            CTFrameDraw(CTFramesetterCreateFrame(fs, CFRangeMake(0, 0), path, nil), ctx)
            ctx.restoreGState()
            my += ADV_HIST_EMPTY_EXTRA
        }
        hline(ADV_IX, ADV_IX + ADV_IW, my + 4, gray(1, 0.06))
        let colX: [CGFloat] = [ADV_IX, ADV_IX + 120, ADV_IX + 203, ADV_IX + ADV_IW]
        textC(caps(tr("по подписке", "on subscription"), 8.5, textLo), x: colX[1], topY: my + 10, h: 11)
        textC(caps(tr("по API было бы", "at API price"), 8.5, textLo), x: colX[2], topY: my + 10, h: 11)
        textC(caps("×", 8.5, textLo), x: colX[3], topY: my + 10, h: 11, align: 2)
        var ry = my + 23
        var notes: [String] = []
        for c in cards {
            let m = moneySummary(c.product, plan: c.data.plan, index: ix)
            let nm = NSMutableAttributedString(attributedString: attr(c.product == "claude" ? "Claude" : "Codex", 10.5, .semibold, textHi))
            nm.append(attr(" · " + (m.subEstimated ? "≈" : "") + "$" + String(Int(m.subMonthly)) + tr("/мес", "/mo"), 10.5, .regular, textMid))
            textC(nm, x: colX[0], topY: ry, h: 13)
            if m.subEstimated {
                drawSF(ctx, "pencil", in: rectTL(colX[0] + width(nm) + 4, ry + 1.5, 10, 10), ADV_LINK)
                hits.append(Hit(id: "settings", rect: rectTL(colX[0], ry - 1, 120, 15)))
            }
            textC(attr("≈ " + fmtUSD(m.subPerDay) + tr("/день", "/day"), 10.5, .regular, textHi), x: colX[1], topY: ry, h: 13)
            if m.usdApi > 0 {
                textC(attr("≈ " + fmtUSD(m.perCalendarDay) + tr("/день", "/day"), 10.5, .regular, textHi), x: colX[2], topY: ry, h: 13)
                textC(attr(fmtNum(m.ratio), 10.5, .regular, textHi), x: colX[3], topY: ry, h: 13, align: 2)
                notes.append((c.product == "claude" ? "Claude" : "Codex") + " ≈ " + fmtUSD(m.perActiveDay))
            } else {
                textC(attr(tr("пока нет", "none yet"), 10.5, .regular, textLo), x: colX[2], topY: ry, h: 13)
                textC(attr("—", 10.5, .regular, textLo), x: colX[3], topY: ry, h: 13, align: 2)
            }
            ry += 15
        }
        if !notes.isEmpty {
            textC(attr(tr("в активный день по API: ", "on an active day at API price: ") + notes.joined(separator: " · "), 9.5, .regular, textLo), x: colX[0], topY: my + 55, h: 11)
        }
    }
    y += hh + 6

    // ---- footer ----
    let footTop = H - 35 - ADV_CREDIT_H
    hits += drawPollFooter(ctx, size: size, top: footTop, interval: interval, updated: updated,
                           autoIntervals: autoIntervals, advanced: true)
    // credit line: author · version · GitHub
    do {
        let divTop = footTop + 22 + 8
        ctx.setStrokeColor(cg(gray(1, 0.06))); ctx.setLineWidth(1)
        ctx.beginPath(); ctx.move(to: CGPoint(x: ADV_CX, y: H - divTop)); ctx.addLine(to: CGPoint(x: ADV_CX + ADV_CW, y: H - divTop)); ctx.strokePath()
        let pre = attr("Claude Codex Limits \(APP_VERSION) · by \(APP_AUTHOR) · ", 9.5, .regular, gray(1, 0.32))
        let link = attr("GitHub", 9.5, .semibold, ADV_LINK)
        let preW = width(pre), linkW = width(link)
        let cx = (W - preW - linkW) / 2, ct = divTop + 7
        textC(pre, x: cx, topY: ct, h: 12)
        textC(link, x: cx + preW, topY: ct, h: 12)
        hits.append(Hit(id: "open:\(REPO_URL)", rect: rectTL(cx + preW - 3, ct - 2, linkW + 6, 16)))
    }
    return hits
}

func drawSettings(_ ctx: CGContext, size: CGSize, about: AboutState, soundsPage: Bool = false, copied: String? = nil) -> [Hit] {
    let W = size.width, H = size.height
    var hits: [Hit] = []
    let cs = CGColorSpaceCreateDeviceRGB()
    let textHi = gray(1, 0.95), textMid = gray(1, 0.5), textLo = gray(1, 0.34)
    let orange = NSColor(srgbRed: 1.0, green: 0.62, blue: 0.18, alpha: 1)
    let d = UserDefaults.standard

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
    func hdiv(_ x0: CGFloat, _ x1: CGFloat, _ topY: CGFloat) {
        ctx.setStrokeColor(cg(gray(1, 0.06))); ctx.setLineWidth(1)
        ctx.beginPath(); ctx.move(to: CGPoint(x: x0, y: H - topY)); ctx.addLine(to: CGPoint(x: x1, y: H - topY)); ctx.strokePath()
    }
    func drawToggle(_ r: CGRect, _ on: Bool) {
        let rad = r.height / 2
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil))
        ctx.setFillColor(cg(on ? orange : gray(1, 0.18))); ctx.fillPath()
        let kd = r.height - 4
        let kx = on ? (r.maxX - 2 - kd) : (r.minX + 2)
        ctx.setFillColor(cg(.white)); ctx.fillEllipse(in: CGRect(x: kx, y: r.minY + 2, width: kd, height: kd))
    }

    // background — identical to the main panel
    let bgPath = CGPath(roundedRect: CGRect(x: 0.5, y: 0.5, width: W - 1, height: H - 1), cornerWidth: 18, cornerHeight: 18, transform: nil)
    ctx.saveGState(); ctx.addPath(bgPath); ctx.clip()
    if let g = CGGradient(colorsSpace: cs, colors: [cg(gray(0.16, 1)), cg(gray(0.075, 1))] as CFArray, locations: [0, 1]) {
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])
    }
    if let glow = CGGradient(colorsSpace: cs, colors: [cg(NSColor(srgbRed: 1, green: 0.5, blue: 0.2, alpha: 0.10)), cg(NSColor(srgbRed: 1, green: 0.5, blue: 0.2, alpha: 0))] as CFArray, locations: [0, 1]) {
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 54, y: H - 26), startRadius: 0, endCenter: CGPoint(x: 54, y: H - 26), endRadius: 170, options: [])
    }
    ctx.restoreGState()
    ctx.addPath(bgPath); ctx.setStrokeColor(cg(gray(1, 0.08))); ctx.setLineWidth(1); ctx.strokePath()

    let pad: CGFloat = 16, cardX: CGFloat = 16, cardW = W - 32

    // header: back + title
    let backRect = rectTL(pad - 4, pad - 4, 28, 28)
    drawSF(ctx, "chevron.left", in: backRect.insetBy(dx: 7, dy: 6), textMid, weight: .semibold)
    hits.append(Hit(id: soundsPage ? "backsettings" : "back", rect: backRect))
    text(attr(soundsPage ? tr("Звуки", "Sounds") : tr("Настройки", "Settings"), 16, .semibold, textHi), x: pad + 24, topY: pad)
    if soundsPage {
    // section 2 — reset-sound master toggles
    text(attr(tr("ВКЛЮЧИТЬ ЗВУК ПРИ СБРОСЕ", "PLAY A SOUND ON RESET"), 9.5, .semibold, textLo), x: pad + 2, topY: setCap1())
    let c1top: CGFloat = setC1Top(), rowH: CGFloat = SET_ROW_H, c1H = rowH * 2
    roundFill(rectTL(cardX, c1top, cardW, c1H), 12, gray(1, 0.04)); roundStroke(rectTL(cardX, c1top, cardW, c1H), 12, gray(1, 0.06), 1)
    func toggleRow(_ rowTop: CGFloat, _ icon: String, _ label: String, _ key: String) {
        drawSF(ctx, icon, in: rectTL(cardX + 15, rowTop + (rowH - 16) / 2, 16, 16), textMid)
        text(attr(label, 13, .regular, textHi), x: cardX + 42, topY: rowTop + (rowH - 13) / 2 - 1)
        let tw: CGFloat = 34, th: CGFloat = 16
        let tRect = rectTL(cardX + cardW - 14 - tw, rowTop + (rowH - th) / 2, tw, th)
        drawToggle(tRect, d.bool(forKey: key))
        hits.append(Hit(id: "toggle:\(key)", rect: rectTL(cardX, rowTop, cardW, rowH)))
    }
    toggleRow(c1top, "clock", tr("5-часовой лимит (сессия)", "5-hour limit (session)"), "sound5h")
    hdiv(cardX + 42, cardX + cardW, c1top + rowH)
    toggleRow(c1top + rowH, "calendar", tr("Недельный лимит", "Weekly limit"), "sound7d")

    // section 3 — per-event sound choice (two radio columns: 5h | weekly)
    let cap2 = c1top + c1H + 14
    text(attr(tr("ЗВУК", "SOUND"), 9.5, .semibold, textLo), x: pad + 2, topY: cap2)
    let dot7cx = cardX + cardW - 22, dot5cx = cardX + cardW - 54, playcx = cardX + cardW - 86
    text(attr(tr("5ч", "5h"), 9.5, .regular, textLo), x: dot5cx, topY: cap2, align: 1)
    text(attr(tr("нед", "wk"), 9.5, .regular, textLo), x: dot7cx, topY: cap2, align: 1)
    let c2top = cap2 + 16, sRowH: CGFloat = 29, c2H = sRowH * CGFloat(RESET_SOUNDS.count)
    roundFill(rectTL(cardX, c2top, cardW, c2H), 12, gray(1, 0.04)); roundStroke(rectTL(cardX, c2top, cardW, c2H), 12, gray(1, 0.06), 1)
    func dot(_ cx: CGFloat, _ centerTop: CGFloat, _ on: Bool) {
        let r: CGFloat = 7, rect = CGRect(x: cx - r, y: H - centerTop - r, width: 2 * r, height: 2 * r)
        if on { ctx.setFillColor(cg(orange)); ctx.fillEllipse(in: rect) }
        else { ctx.setStrokeColor(cg(gray(1, 0.32))); ctx.setLineWidth(1.5); ctx.strokeEllipse(in: rect.insetBy(dx: 0.75, dy: 0.75)) }
    }
    let cur5 = sound5hId(), cur7 = sound7dId()
    for (i, s) in RESET_SOUNDS.enumerated() {
        let rt = c2top + CGFloat(i) * sRowH, cTop = rt + sRowH / 2
        drawSF(ctx, "music.note", in: rectTL(cardX + 15, rt + (sRowH - 14) / 2, 12, 14), textMid)
        text(attr(s.name, 13, .regular, textHi), x: cardX + 38, topY: rt + (sRowH - 13) / 2 - 1)
        drawSF(ctx, "play.fill", in: CGRect(x: playcx - 6, y: H - cTop - 6, width: 12, height: 12), textLo)
        hits.append(Hit(id: "preview:\(s.id)", rect: rectTL(cardX, rt, playcx + 8 - cardX, sRowH)))
        dot(dot5cx, cTop, s.id == cur5)
        hits.append(Hit(id: "set5:\(s.id)", rect: CGRect(x: dot5cx - 13, y: H - cTop - 13, width: 26, height: 26)))
        dot(dot7cx, cTop, s.id == cur7)
        hits.append(Hit(id: "set7:\(s.id)", rect: CGRect(x: dot7cx - 13, y: H - cTop - 13, width: 26, height: 26)))
        if i < RESET_SOUNDS.count - 1 { hdiv(cardX + 38, cardX + cardW, rt + sRowH) }
    }

    // section 4 — limit-reached sound (any 5h/weekly/per-model limit hit)
    let capC = c2top + c2H + 14
    text(attr(tr("ПРИ ДОСТИЖЕНИИ ЛЮБОГО ЛИМИТА", "WHEN ANY LIMIT IS REACHED"), 9.5, .semibold, textLo), x: pad + 2, topY: capC)
    let c3top = capC + 16, toggleH: CGFloat = 36, c3H = toggleH + sRowH * CGFloat(REACHED_SOUNDS.count)
    roundFill(rectTL(cardX, c3top, cardW, c3H), 12, gray(1, 0.04)); roundStroke(rectTL(cardX, c3top, cardW, c3H), 12, gray(1, 0.06), 1)
    drawSF(ctx, "exclamationmark.triangle", in: rectTL(cardX + 15, c3top + (toggleH - 16) / 2, 16, 16), textMid)
    text(attr(tr("Звук при достижении лимита", "Sound when a limit is reached"), 13, .regular, textHi), x: cardX + 42, topY: c3top + (toggleH - 13) / 2 - 1)
    do {
        let tw: CGFloat = 34, th: CGFloat = 16
        drawToggle(rectTL(cardX + cardW - 14 - tw, c3top + (toggleH - th) / 2, tw, th), d.bool(forKey: "reachedOn"))
        hits.append(Hit(id: "toggle:reachedOn", rect: rectTL(cardX, c3top, cardW, toggleH)))
    }
    hdiv(cardX + 14, cardX + cardW, c3top + toggleH)
    let curR = reachedId(), rDotcx = cardX + cardW - 22, rPlaycx = cardX + cardW - 52
    for (i, s) in REACHED_SOUNDS.enumerated() {
        let rt = c3top + toggleH + CGFloat(i) * sRowH, cTop = rt + sRowH / 2
        drawSF(ctx, "music.note", in: rectTL(cardX + 15, rt + (sRowH - 14) / 2, 12, 14), textMid)
        text(attr(s.name, 13, .regular, textHi), x: cardX + 38, topY: rt + (sRowH - 13) / 2 - 1)
        drawSF(ctx, "play.fill", in: CGRect(x: rPlaycx - 6, y: H - cTop - 6, width: 12, height: 12), textLo)
        hits.append(Hit(id: "preview:\(s.id)", rect: rectTL(cardX, rt, rPlaycx + 8 - cardX, sRowH)))
        dot(rDotcx, cTop, s.id == curR)
        hits.append(Hit(id: "setR:\(s.id)", rect: CGRect(x: rDotcx - 13, y: H - cTop - 13, width: 26, height: 26)))
        if i < REACHED_SOUNDS.count - 1 { hdiv(cardX + 38, cardX + cardW, rt + sRowH) }
    }

        return hits
    }

    // section 0 — general: interface language + launch at login
    text(attr(tr("ОБЩИЕ", "GENERAL"), 9.5, .semibold, textLo), x: pad + 2, topY: 50)
    let genTop: CGFloat = SET_GEN_TOP, genRowH: CGFloat = SET_ROW_H, genH = SET_GEN_H
    roundFill(rectTL(cardX, genTop, cardW, genH), 12, gray(1, 0.04)); roundStroke(rectTL(cardX, genTop, cardW, genH), 12, gray(1, 0.06), 1)
    // language row — globe + label + a compact EN | RU segmented control
    drawSF(ctx, "globe", in: rectTL(cardX + 15, genTop + (genRowH - 16) / 2, 16, 16), textMid)
    text(attr(tr("Язык", "Language"), 13, .regular, textHi), x: cardX + 42, topY: genTop + (genRowH - 13) / 2 - 1)
    do {
        let cur = appLang()
        let ctrlW: CGFloat = 66, segH: CGFloat = 24
        let trackX = cardX + cardW - 14 - ctrlW, trackTop = genTop + (genRowH - segH) / 2
        roundFill(rectTL(trackX, trackTop, ctrlW, segH), 7, gray(1, 0.08))
        let segW = (ctrlW - 9) / 2
        for (i, o) in [("en", "EN"), ("ru", "RU")].enumerated() {
            let sRect = rectTL(trackX + 3 + CGFloat(i) * (segW + 3), trackTop + 3, segW, segH - 6)
            let active = cur == o.0
            if active { roundFill(sRect, 5, gray(1, 0.18)) }
            text(attr(o.1, 11, active ? .semibold : .medium, active ? textHi : textMid), x: sRect.midX, topY: genTop + (genRowH - 11) / 2 - 0.5, align: 1)
            hits.append(Hit(id: "lang:\(o.0)", rect: sRect))
        }
    }
    hdiv(cardX + 42, cardX + cardW, genTop + genRowH)
    // panel-view row — the Simple | Advanced switch
    do {
        let rowTop = genTop + genRowH
        drawSF(ctx, "chart.bar.xaxis", in: rectTL(cardX + 15, rowTop + (genRowH - 16) / 2, 16, 16), textMid)
        text(attr(tr("Вид панели", "Panel view"), 13, .regular, textHi), x: cardX + 42, topY: rowTop + (genRowH - 13) / 2 - 1)
        let adv = advancedEnabled()
        let labels = [(false, tr("Простой", "Simple")), (true, tr("Расширенный", "Advanced"))]
        let f = ctFont(11, .medium)
        let widths = labels.map { ceil(lineWidth(CTLineCreateWithAttributedString(ctAttr($0.1, f, cg(.white))))) + 16 }
        let segH: CGFloat = 24, ctrlW = widths.reduce(0, +) + 9
        let trackX = cardX + cardW - 14 - ctrlW, trackTop = rowTop + (genRowH - segH) / 2
        roundFill(rectTL(trackX, trackTop, ctrlW, segH), 7, gray(1, 0.08))
        var sx = trackX + 3
        for (i, o) in labels.enumerated() {
            let sRect = rectTL(sx, trackTop + 3, widths[i], segH - 6)
            let active = adv == o.0
            if active { roundFill(sRect, 5, gray(1, 0.18)) }
            text(attr(o.1, 11, active ? .semibold : .medium, active ? textHi : textMid), x: sRect.midX, topY: rowTop + (genRowH - 11) / 2 - 0.5, align: 1)
            hits.append(Hit(id: "view:\(o.0 ? "advanced" : "simple")", rect: sRect))
            sx += widths[i] + 3
        }
    }
    hdiv(cardX + 42, cardX + cardW, genTop + genRowH * 2)
    // launch-at-login row — sparkles + label + toggle
    drawSF(ctx, "sparkles", in: rectTL(cardX + 15, genTop + genRowH * 2 + (genRowH - 16) / 2, 16, 16), textMid)
    text(attr(tr("Запускать при входе", "Launch at login"), 13, .regular, textHi), x: cardX + 42, topY: genTop + genRowH * 2 + (genRowH - 13) / 2 - 1)
    do {
        let tw: CGFloat = 34, th: CGFloat = 16
        drawToggle(rectTL(cardX + cardW - 14 - tw, genTop + genRowH * 2 + (genRowH - th) / 2, tw, th), loginEnabled())
        hits.append(Hit(id: "togglelogin", rect: rectTL(cardX, genTop + genRowH * 2, cardW, genRowH)))
    }

    // Subscription selection is available in both panel modes.
    text(attr(tr("СОБИРАТЬ И ПОКАЗЫВАТЬ", "COLLECT AND SHOW"), 9.5, .semibold, textLo), x: pad + 2, topY: SET_PRODUCTS_CAP)
    roundFill(rectTL(cardX, SET_PRODUCTS_TOP, cardW, SET_PRODUCTS_H), 12, gray(1, 0.04))
    roundStroke(rectTL(cardX, SET_PRODUCTS_TOP, cardW, SET_PRODUCTS_H), 12, gray(1, 0.06), 1)
    for (i, item) in [("claude", "Claude Code"), ("codex", "Codex")].enumerated() {
        let x = cardX + CGFloat(i) * cardW / 2
        text(attr(item.1, 12, .regular, textHi), x: x + 14, topY: SET_PRODUCTS_TOP + 11)
        drawToggle(rectTL(x + cardW / 2 - 46, SET_PRODUCTS_TOP + 10, 34, 16), productEnabled(item.0))
        hits.append(Hit(id: "monitor:" + item.0, rect: rectTL(x, SET_PRODUCTS_TOP, cardW / 2, SET_PRODUCTS_H)))
    }

    // section 1 — which percentages go into the menu-bar strip
    text(attr(tr("В СТРОКЕ МЕНЮ", "IN THE MENU BAR"), 9.5, .semibold, textLo), x: pad + 2, topY: SET_TRAY_CAP)
    roundFill(rectTL(cardX, SET_TRAY_TOP, cardW, SET_TRAY_H), 12, gray(1, 0.04))
    roundStroke(rectTL(cardX, SET_TRAY_TOP, cardW, SET_TRAY_H), 12, gray(1, 0.06), 1)
    do {
        let cur = Array(trayMetrics().prefix(2))
        // Both sides on one row, split by the same slash the strip itself draws, so the
        // control reads like its own result: «Fable / нед» → "100/86%" in the menu bar.
        func segGroup(_ x: CGFloat, _ w: CGFloat, _ slot: Int, _ options: [TrayMetric?]) {
            let segH: CGFloat = 24, trackTop = SET_TRAY_TOP + (SET_TRAY_H - segH) / 2
            roundFill(rectTL(x, trackTop, w, segH), 7, gray(1, 0.08))
            let n = CGFloat(options.count), segW = (w - 6 - (n - 1) * 2) / n
            let picked: TrayMetric? = slot < cur.count ? cur[slot] : nil
            for (i, o) in options.enumerated() {
                let r = rectTL(x + 3 + CGFloat(i) * (segW + 2), trackTop + 3, segW, segH - 6)
                let active = picked == o
                if active { roundFill(r, 5, gray(1, 0.18)) }
                text(attr(trayMetricShort(o), 11, active ? .semibold : .medium, active ? textHi : textMid),
                     x: r.midX, topY: trackTop + 6.5, align: 1)
                hits.append(Hit(id: "trayslot:\(slot):\(o?.rawValue ?? "none")", rect: r))
            }
        }
        let lw: CGFloat = 124, rw: CGFloat = 152      // left side has 3 options, right also "—"
        segGroup(cardX + 14, lw, 0, [.session, .weekly, .model])
        text(attr("/", 13, .regular, textMid), x: cardX + 14 + lw + 10, topY: SET_TRAY_TOP + (SET_TRAY_H - 13) / 2 - 1)
        segGroup(cardX + 14 + lw + 20, rw, 1, [nil, .session, .weekly, .model])
    }

    // section 1b — subscription prices (feed the Advanced view's money figures)
    if advancedEnabled() {
        text(attr(tr("ПОДПИСКИ · ДЛЯ ОЦЕНКИ В ДЕНЬГАХ", "SUBSCRIPTIONS · FOR THE MONEY ESTIMATE"), 9.5, .semibold, textLo), x: pad + 2, topY: SET_SUB_CAP)
        roundFill(rectTL(cardX, SET_SUB_TOP, cardW, SET_SUB_H), 12, gray(1, 0.04))
        roundStroke(rectTL(cardX, SET_SUB_TOP, cardW, SET_SUB_H), 12, gray(1, 0.06), 1)
        func subRow(_ i: Int, _ product: String, _ label: String, _ plan: String?, _ choices: [Double]) {
            let rowTop = SET_SUB_TOP + CGFloat(i) * SET_ROW_H
            let cur = subscriptionUSD(product, plan: plan)
            text(attr(label, 13, .regular, textHi), x: cardX + 14, topY: rowTop + (SET_ROW_H - 13) / 2 - 1)
            if cur.estimated {
                text(attr(tr("оценка", "estimate"), 9.5, .regular, textLo), x: cardX + 14 + ceil(lineWidth(CTLineCreateWithAttributedString(ctAttr(label, ctFont(13, .regular), cg(.white))))) + 6, topY: rowTop + (SET_ROW_H - 9.5) / 2)
            }
            let f = ctFont(11, .medium)
            let widths = choices.map { ceil(lineWidth(CTLineCreateWithAttributedString(ctAttr("$\(Int($0))", f, cg(.white))))) + 14 }
            var x = cardX + cardW - 14 - widths.reduce(0, +) - CGFloat(choices.count - 1) * 4
            let pillH: CGFloat = 22, top = rowTop + (SET_ROW_H - pillH) / 2
            for (j, c) in choices.enumerated() {
                let r = rectTL(x, top, widths[j], pillH)
                let on = abs(cur.usd - c) < 0.5
                roundFill(r, 6, on ? (cur.estimated ? gray(1, 0.12) : gray(1, 0.18)) : gray(1, 0.06))
                if on, cur.estimated { roundStroke(r, 6, gray(1, 0.25), 1) }
                text(attr("$\(Int(c))", 11, on ? .semibold : .medium, on ? textHi : textMid), x: r.midX, topY: top + 5, align: 1)
                hits.append(Hit(id: "sub:\(product):\(Int(c))", rect: r))
                x += widths[j] + 4
            }
        }
        subRow(0, "claude", "Claude", nil, [20, 100, 200])
        hdiv(cardX + 14, cardX + cardW, SET_SUB_TOP + SET_ROW_H)
        subRow(1, "codex", "Codex", UserDefaults.standard.string(forKey: "codexPlan"), [8, 20, 100, 200])

        // section 1c — cross-machine sync through GitHub
        if syncBlockShown() {
        let sy = syncUIState(), syTop = SET_SYNC_TOP, syH = setSyncCardH()
        text(attr(tr("ДРУГИЕ КОМПЬЮТЕРЫ · ЧЕРЕЗ GITHUB", "OTHER COMPUTERS · VIA GITHUB"), 9.5, .semibold, textLo), x: pad + 2, topY: SET_SYNC_CAP)
        roundFill(rectTL(cardX, syTop, cardW, syH), 12, gray(1, 0.04))
        roundStroke(rectTL(cardX, syTop, cardW, syH), 12, gray(1, 0.06), 1)
        func button(_ label: String, right: CGFloat, rowTop: CGFloat, id: String, primary: Bool, tint: NSColor? = nil) -> CGFloat {
            let a = attr(label, 11, .semibold, tint ?? (primary ? NSColor(srgbRed: 0.1, green: 0.07, blue: 0.03, alpha: 1) : textHi))
            let w = ceil(lineWidth(CTLineCreateWithAttributedString(a))) + 20, h: CGFloat = 22
            let r = rectTL(right - w, rowTop + (SET_ROW_H - h) / 2, w, h)
            roundFill(r, 6, primary ? orange : gray(1, 0.12))
            text(a, x: r.midX, topY: rowTop + (SET_ROW_H - h) / 2 + 5, align: 1)
            hits.append(Hit(id: id, rect: r)); return w
        }
        func link(_ label: String, right: CGFloat, topY: CGFloat, id: String) {
            let a = attr(label, 11, .medium, ADV_LINK)
            let w = ceil(lineWidth(CTLineCreateWithAttributedString(a)))
            text(a, x: right - w, topY: topY)
            hits.append(Hit(id: id, rect: rectTL(right - w - 4, topY - 4, w + 8, 20)))
        }
        func note(_ s: String, _ top: CGFloat, height: CGFloat = SET_SYNC_NOTE_H - 6) {
            let a = attr(s, 10.5, .regular, textMid)
            let fs = CTFramesetterCreateWithAttributedString(a)
            let r = rectTL(cardX + 14, top, cardW - 28, height)
            let fr = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), CGPath(rect: r, transform: nil), nil)
            ctx.textMatrix = .identity; CTFrameDraw(fr, ctx)
        }
        let rowMid = syTop + (SET_ROW_H - 13) / 2 - 1
        switch sy.phase {
        case .off, .revoked:
            let revoked = sy.phase == .revoked
            drawSF(ctx, revoked ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath", in: rectTL(cardX + 15, syTop + (SET_ROW_H - 16) / 2, 16, 16), revoked ? ADV_WARN : textMid)
            let loginW = button(revoked ? tr("Войти заново", "Sign in again") : tr("Войти через GitHub", "Sign in with GitHub"), right: cardX + cardW - 12, rowTop: syTop, id: "sync:login", primary: true)
            var titleRight = cardX + cardW - 12 - loginW - 10
            if sy.canSignOut {
                let label = tr("Выйти", "Sign out")
                link(label, right: titleRight, topY: rowMid + 1, id: "sync:logout")
                titleRight -= ceil(lineWidth(CTLineCreateWithAttributedString(attr(label, 11, .medium, ADV_LINK)))) + 10
            }
            text(fitAttr(revoked ? tr("Нужно проверить вход в GitHub", "GitHub sign-in needs attention") : tr("Сводить расход", "Combine usage"),
                         maxW: titleRight - cardX - 42) { attr($0, 13, .regular, textHi) }, x: cardX + 42, topY: rowMid)
            if let err = sy.error, !revoked {
                note(err, syTop + SET_ROW_H - 2)
            } else {
            note(revoked
                 ? tr("Расход других компьютеров не обновляется. Последние полученные данные остаются в истории.",
                      "Other computers' usage isn't updating. The last data received stays in the history.")
                 : tr("Столбики и деньги учтут компьютеры, вошедшие в тот же GitHub. Функция позволяет организовывать сводную статистику с нескольких компьютеров, на которых применяется один и тот же аккаунт.",
                      "Bars and money will include every computer signed in to the same GitHub. It combines statistics from several computers that use the same account."),
                 syTop + SET_ROW_H - 4)
            }
            if revoked, let err = sy.lastError {
                let at = sy.lastErrorAt.map { fmtMoment($0) + ": " } ?? ""
                text(fitAttr(tr("Ошибка ", "Error ") + at + err, maxW: cardW - 28) { attr($0, 10.5, .regular, ADV_WARN) },
                     x: cardX + 14, topY: syTop + SET_ROW_H + SET_SYNC_NOTE_H)
            }
            if sy.canSignOut {
                note(syncSignOutHint(), syTop + syH - (sy.canRetryKeychain ? SET_ROW_H : 0) - SET_SYNC_SIGNOUT_HINT_H, height: SET_SYNC_SIGNOUT_HINT_H)
            }
        case .awaitingCode:
            text(attr(tr("Введите код на github.com/login/device", "Enter the code at github.com/login/device"), 12, .regular, textHi), x: cardX + 14, topY: rowMid + 1)
            let codeTop = syTop + SET_ROW_H - 2
            text(ctAttr(sy.userCode ?? "····-····", (NSFont.monospacedSystemFont(ofSize: 22, weight: .semibold) as CTFont), cg(textHi)), x: cardX + 14, topY: codeTop + 8)
            var right = cardX + cardW - 12
            right -= button(tr("Открыть", "Open"), right: right, rowTop: codeTop + 4, id: "sync:open", primary: true) + 6
            // Copy flips to a teal «Скопировано» for a moment (copyToClipboard clears it) — both buttons
            // put the code on the clipboard, so either one lights it up.
            let justCopied = copied != nil && copied == sy.userCode
            _ = button(justCopied ? tr("Скопировано", "Copied!") : tr("Скопировать", "Copy"), right: right, rowTop: codeTop + 4, id: "sync:copy", primary: false,
                       tint: justCopied ? ADV_MODEL[0] : nil)
            hdiv(cardX + 14, cardX + cardW - 14, codeTop + 44)
            text(attr(tr("Ждём подтверждения в браузере…", "Waiting for approval in the browser…"), 10.5, .regular, textMid), x: cardX + 14, topY: codeTop + 51)
            link(tr("Отмена", "Cancel"), right: cardX + cardW - 14, topY: codeTop + 51, id: "sync:cancel")
        case .on:
            let authHealthy = sy.authState == nil || sy.authState == "healthy"
            drawSF(ctx, authHealthy ? "checkmark.circle.fill" : "arrow.clockwise.circle", in: rectTL(cardX + 15, syTop + (SET_ROW_H - 16) / 2, 16, 16), authHealthy ? NSColor(srgbRed: 0.2, green: 0.85, blue: 0.7, alpha: 1) : ADV_WARN)
            let who = NSMutableAttributedString(attributedString: attr("GitHub · ", 13, .regular, textMid))
            who.append(attr(sy.login ?? "—", 13, .semibold, textHi))
            text(who, x: cardX + 42, topY: rowMid)
            link(tr("Выйти", "Sign out"), right: cardX + cardW - 14, topY: rowMid + 1, id: "sync:logout")
            for (i, m) in sy.machines.enumerated() {
                let rt = syTop + SET_ROW_H + CGFloat(i) * SET_SYNC_MROW_H
                hdiv(cardX + 42, cardX + cardW, rt)
                let isMac = m.os.lowercased().hasPrefix("mac")
                drawSF(ctx, isMac ? "laptopcomputer" : "desktopcomputer", in: rectTL(cardX + 14, rt + (SET_SYNC_MROW_H - 16) / 2, 19, 16), textMid)
                let stale = m.updated.map { Date().timeIntervalSince($0) > 86400 } ?? false
                let when = m.isSelf ? tr("этот компьютер", "this computer")
                    : m.updated.map { tr("данные от ", "data from ") + fmtMoment($0).lowercased() } ?? tr("ещё не присылал", "no data yet")
                let whenA = attr(when, 10.5, .regular, stale ? ADV_WARN : textMid)
                text(whenA, x: cardX + cardW - 14, topY: rt + (SET_SYNC_MROW_H - 10.5) / 2 - 1, align: 2)
                // Name (+ OS when it fits) must stop short of the right-hand status.
                let room = cardW - 14 - 42 - ceil(lineWidth(CTLineCreateWithAttributedString(whenA))) - 12
                func wd(_ a: NSAttributedString) -> CGFloat { ceil(lineWidth(CTLineCreateWithAttributedString(a))) }
                var name = m.name
                var nm = NSMutableAttributedString(attributedString: attr(name, 12, .medium, textHi))
                let withOS = NSMutableAttributedString(attributedString: nm); withOS.append(attr("  " + m.os, 10.5, .regular, textLo))
                if wd(withOS) <= room { nm = withOS }
                else {
                    while wd(nm) > room, name.count > 3 {
                        name.removeLast(); nm = NSMutableAttributedString(attributedString: attr(name.trimmingCharacters(in: .whitespaces) + "…", 12, .medium, textHi))
                    }
                }
                text(nm, x: cardX + 42, topY: rt + (SET_SYNC_MROW_H - 12) / 2 - 1)
            }
            // When sync last actually worked, and why it didn't since (docs/sync-protocol.md → Errors).
            let st = syTop + SET_ROW_H + CGFloat(max(1, sy.machines.count)) * SET_SYNC_MROW_H
            hdiv(cardX + 14, cardX + cardW - 14, st)
            let upl = sy.lastUploadAt.map { fmtMoment($0) } ?? "—", rd = sy.lastSync.map { fmtMoment($0) } ?? "—"
            text(fitAttr(tr("Последняя отправка: \(upl) · чтение: \(rd)", "Last upload: \(upl) · read: \(rd)"), maxW: cardW - 28) { attr($0, 10.5, .regular, textMid) },
                 x: cardX + 14, topY: st + (SET_SYNC_STATUS_H - 10.5) / 2)
            if let err = sy.lastError {
                let at = sy.lastErrorAt.map { fmtMoment($0) + ": " } ?? ""
                text(fitAttr(tr("Ошибка ", "Error ") + at + err, maxW: cardW - 28) { attr($0, 10.5, .regular, ADV_WARN) },
                     x: cardX + 14, topY: st + SET_SYNC_STATUS_H - 4 + (SET_SYNC_STATUS_H - 10.5) / 2 - 2)
            }
            note(syncSignOutHint(), syTop + syH - (sy.canRetryKeychain ? SET_ROW_H : 0) - SET_SYNC_SIGNOUT_HINT_H, height: SET_SYNC_SIGNOUT_HINT_H)
        }
        if sy.canRetryKeychain {
            _ = button(tr("Повторить доступ к Связке ключей", "Retry Keychain access"),
                right: cardX + cardW - 12, rowTop: syTop + syH - SET_ROW_H,
                id: "sync:keychain-retry", primary: false)
        }
        }
    }

    // sounds group — one summary row; the three cards below only when unfolded
    do {
        let top = setSndTop()
        roundFill(rectTL(cardX, top, cardW, SET_ROW_H), 12, gray(1, 0.04)); roundStroke(rectTL(cardX, top, cardW, SET_ROW_H), 12, gray(1, 0.06), 1)
        drawSF(ctx, "speaker.wave.2", in: rectTL(cardX + 14, top + (SET_ROW_H - 16) / 2, 18, 16), textMid)
        text(attr(tr("Звуки", "Sounds"), 13, .regular, textHi), x: cardX + 42, topY: top + (SET_ROW_H - 13) / 2 - 1)
        drawSF(ctx, "chevron.right", in: rectTL(cardX + cardW - 14 - 7, top + (SET_ROW_H - 11) / 2, 7, 11), textMid, weight: .semibold)
        text(attr(soundsSummary(), 11, .regular, textMid), x: cardX + cardW - 14 - 7 - 10, topY: top + (SET_ROW_H - 11) / 2 - 1, align: 2)
        hits.append(Hit(id: "sounds:open", rect: rectTL(cardX, top, cardW, SET_ROW_H)))
    }
    // section 5 — about / check for updates
    let capD = setAboutCap()
    text(attr(tr("О ПРИЛОЖЕНИИ", "ABOUT"), 9.5, .semibold, textLo), x: pad + 2, topY: capD)
    let c4top = capD + 16, c4H: CGFloat = 44
    roundFill(rectTL(cardX, c4top, cardW, c4H), 12, gray(1, 0.04)); roundStroke(rectTL(cardX, c4top, cardW, c4H), 12, gray(1, 0.06), 1)
    drawSF(ctx, "info.circle", in: rectTL(cardX + 15, c4top + (44 - 16) / 2, 16, 16), textMid)
    text(attr(tr("Версия", "Version") + " \(about.version)", 13, .regular, textHi), x: cardX + 42, topY: c4top + (44 - 13) / 2 - 1)
    func pill(_ label: String, _ id: String, _ accent: Bool) {
        let f = ctFont(11.5, .medium)
        let lw = ceil(lineWidth(CTLineCreateWithAttributedString(ctAttr(label, f, cg(.white)))))
        let w = lw + 24, h: CGFloat = 26
        let r = rectTL(cardX + cardW - 14 - w, c4top + (44 - h) / 2, w, h)
        roundFill(r, 8, accent ? orange : gray(1, 0.14))
        text(attr(label, 11.5, .medium, accent ? gray(0.10, 1) : textHi), x: r.midX, topY: c4top + 16, align: 1)
        hits.append(Hit(id: id, rect: r))
    }
    // a pill whose right edge sits at `rightX`; returns its width (for chaining two pills)
    func pillR(_ rightX: CGFloat, _ label: String, _ id: String, _ accent: Bool) -> CGFloat {
        let f = ctFont(11.5, .medium)
        let lw = ceil(lineWidth(CTLineCreateWithAttributedString(ctAttr(label, f, cg(.white)))))
        let w = lw + 22, h: CGFloat = 26
        let r = rectTL(rightX - w, c4top + (44 - h) / 2, w, h)
        roundFill(r, 8, accent ? orange : gray(1, 0.14))
        text(attr(label, 11.5, .medium, accent ? gray(0.10, 1) : textHi), x: r.midX, topY: c4top + 16, align: 1)
        hits.append(Hit(id: id, rect: r))
        return w
    }
    switch about.phase {
    case .downloading:
        // progress bar where the action pill normally sits
        let bw: CGFloat = 150, bh: CGFloat = 7
        let track = rectTL(cardX + cardW - 14 - bw, c4top + (44 - bh) / 2, bw, bh)
        roundFill(track, bh / 2, gray(1, 0.16))
        let fw = max(bh, bw * CGFloat(max(0, min(1, about.progress))))
        roundFill(CGRect(x: track.minX, y: track.minY, width: fw, height: bh), bh / 2, orange)
    case .ready:
        pill(tr("Установить и перезапустить", "Install & Relaunch"), "install", true)
    case .idle:
        if about.checking {
            text(attr(tr("Проверка…", "Checking…"), 12, .regular, textMid), x: cardX + cardW - 16, topY: c4top + 15, align: 2)
        } else if about.availVersion != nil {
            let wDl = pillR(cardX + cardW - 14, tr("Скачать", "Download"), "update", true)
            _ = pillR(cardX + cardW - 14 - wDl - 8, tr("Что нового", "What's new"), "whatsnew", false)
        } else {
            pill(tr("Проверить обновление", "Check for updates"), "checkupdate", false)
        }
    }
    // status line below the card (only when there is something to say)
    let lineY = c4top + c4H + 7
    if about.phase == .ready {
        text(attr(tr("Готово — нажмите «Установить и перезапустить»", "Ready — tap «Install & Relaunch»"), 11.5, .regular, orange), x: cardX + 4, topY: lineY)
    } else if about.phase == .downloading {
        text(attr(tr("Загрузка…", "Downloading…") + " \(Int(about.progress * 100))%", 11.5, .regular, textMid), x: cardX + 4, topY: lineY)
    } else if let av = about.availVersion {
        text(attr(tr("Доступна версия \(av) — нажмите «Скачать»", "Version \(av) available — tap «Download»"), 11.5, .regular, orange), x: cardX + 4, topY: lineY)
    } else if about.msg != .none {
        let m: String
        switch about.msg {
        case .upToDate:       m = tr("Установлена последняя версия (\(about.version))", "You're on the latest version (\(about.version))")
        case .checkFailed:    m = tr("Не удалось проверить обновление", "Couldn't check for updates")
        case .downloadFailed: m = tr("Ошибка загрузки", "Download failed")
        case .none:           m = ""
        }
        text(attr(m, 11.5, .regular, textLo), x: cardX + 4, topY: lineY)
    }

    return hits
}

// MARK: - "What's new" screen (accumulated release notes + update action)

func drawWhatsNew(_ ctx: CGContext, size: CGSize, notes: [ReleaseNote], loading: Bool,
                  error: String, scroll: CGFloat, contentH: CGFloat, viewportH: CGFloat,
                  about: AboutState) -> [Hit] {
    let W = size.width, H = size.height
    var hits: [Hit] = []
    let cs = CGColorSpaceCreateDeviceRGB()
    let textHi = gray(1, 0.95), textMid = gray(1, 0.5), textLo = gray(1, 0.34)
    let orange = NSColor(srgbRed: 1.0, green: 0.62, blue: 0.18, alpha: 1)

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
    func hdiv(_ x0: CGFloat, _ x1: CGFloat, _ topY: CGFloat) {
        ctx.setStrokeColor(cg(gray(1, 0.06))); ctx.setLineWidth(1)
        ctx.beginPath(); ctx.move(to: CGPoint(x: x0, y: H - topY)); ctx.addLine(to: CGPoint(x: x1, y: H - topY)); ctx.strokePath()
    }

    // background — identical to the panel/settings
    let bgPath = CGPath(roundedRect: CGRect(x: 0.5, y: 0.5, width: W - 1, height: H - 1), cornerWidth: 18, cornerHeight: 18, transform: nil)
    ctx.saveGState(); ctx.addPath(bgPath); ctx.clip()
    if let g = CGGradient(colorsSpace: cs, colors: [cg(gray(0.16, 1)), cg(gray(0.075, 1))] as CFArray, locations: [0, 1]) {
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])
    }
    if let glow = CGGradient(colorsSpace: cs, colors: [cg(NSColor(srgbRed: 1, green: 0.5, blue: 0.2, alpha: 0.10)), cg(NSColor(srgbRed: 1, green: 0.5, blue: 0.2, alpha: 0))] as CFArray, locations: [0, 1]) {
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 54, y: H - 26), startRadius: 0, endCenter: CGPoint(x: 54, y: H - 26), endRadius: 170, options: [])
    }
    ctx.restoreGState()
    ctx.addPath(bgPath); ctx.setStrokeColor(cg(gray(1, 0.08))); ctx.setLineWidth(1); ctx.strokePath()

    let pad: CGFloat = 16
    // header: back + title (+ count)
    let backRect = rectTL(pad - 4, pad - 4, 28, 28)
    drawSF(ctx, "chevron.left", in: backRect.insetBy(dx: 7, dy: 6), textMid, weight: .semibold)
    hits.append(Hit(id: "backsettings", rect: backRect))
    text(attr(tr("Что нового", "What's new"), 16, .semibold, textHi), x: pad + 24, topY: pad)
    if !notes.isEmpty {
        let n = notes.count
        let sub = appLang() == "en"
            ? (n == 1 ? "1 version" : "\(n) versions")
            : (n == 1 ? "1 версия" : (n < 5 ? "\(n) версии" : "\(n) версий"))
        text(attr(sub, 11, .regular, textLo), x: W - pad, topY: pad + 3, align: 2)
    }

    // scrollable notes viewport
    let vp = CGRect(x: WN_PAD, y: WN_FOOTER, width: W - WN_PAD * 2 - 8, height: max(0, H - WN_HEADER - WN_FOOTER))
    if loading {
        text(attr(tr("Загрузка заметок…", "Loading notes…"), 12.5, .regular, textMid), x: W / 2, topY: WN_HEADER + 22, align: 1)
    } else if notes.isEmpty {
        _ = error   // (kept for signature symmetry; the message is localized live below)
        text(attr(tr("Пока нет заметок о новых версиях", "No notes for newer versions yet"), 12.5, .regular, textMid), x: W / 2, topY: WN_HEADER + 22, align: 1)
    } else {
        let maxScroll = max(0, contentH - vp.height)
        let sc = max(0, min(scroll, maxScroll))             // defensive clamp
        let a = notesAttributedString(notes)
        ctx.saveGState(); ctx.clip(to: vp)
        let fs = CTFramesetterCreateWithAttributedString(a)
        let pathRect = CGRect(x: vp.minX, y: (vp.maxY + sc) - contentH, width: WN_CONTENT_W, height: contentH)
        let frame = CTFramesetterCreateFrame(fs, CFRangeMake(0, 0), CGPath(rect: pathRect, transform: nil), nil)
        ctx.textMatrix = .identity
        CTFrameDraw(frame, ctx)
        ctx.restoreGState()
        if maxScroll > 0 {                                  // scrollbar thumb
            let thumbH = max(28, vp.height * vp.height / contentH)
            let frac = sc / maxScroll
            let thumbTop = vp.maxY - frac * (vp.height - thumbH)
            roundFill(CGRect(x: W - WN_PAD + 2, y: thumbTop - thumbH, width: 3, height: thumbH), 1.5, gray(1, 0.20))
        }
    }

    // footer: divider + phase-based action
    hdiv(WN_PAD, W - WN_PAD, H - WN_FOOTER + 8)
    let pillH: CGFloat = 28
    let pillTopY = (H - WN_FOOTER + 8) + (WN_FOOTER - 8 - pillH) / 2
    func footPill(_ rightX: CGFloat, _ label: String, _ id: String, _ accent: Bool) {
        let f = ctFont(12, .medium)
        let lw = ceil(lineWidth(CTLineCreateWithAttributedString(ctAttr(label, f, cg(.white)))))
        let w = lw + 26
        let r = rectTL(rightX - w, pillTopY, w, pillH)
        roundFill(r, 8, accent ? orange : gray(1, 0.14))
        text(attr(label, 12, .medium, accent ? gray(0.10, 1) : textHi), x: r.midX, topY: pillTopY + 7, align: 1)
        hits.append(Hit(id: id, rect: r))
    }
    switch about.phase {
    case .downloading:
        let bw: CGFloat = 180, bh: CGFloat = 8
        let track = rectTL(W - WN_PAD - bw, pillTopY + (pillH - bh) / 2, bw, bh)
        roundFill(track, bh / 2, gray(1, 0.16))
        let fw = max(bh, bw * CGFloat(min(1, max(0, about.progress))))
        roundFill(CGRect(x: track.minX, y: track.minY, width: fw, height: bh), bh / 2, orange)
        text(attr(tr("Загрузка…", "Downloading…") + " \(Int(about.progress * 100))%", 11.5, .regular, textMid), x: WN_PAD, topY: pillTopY + 8)
    case .ready:
        footPill(W - WN_PAD, tr("Установить и перезапустить", "Install & Relaunch"), "install", true)
        text(attr(tr("Готово", "Ready"), 11.5, .regular, orange), x: WN_PAD, topY: pillTopY + 8)
    case .idle:
        footPill(W - WN_PAD, about.availVersion.map { tr("Обновить до", "Update to") + " \($0)" } ?? tr("Скачать", "Download"), "update", true)
    }

    return hits
}

// MARK: - "Connect Claude Code" walkthrough

let CFIX_PAD: CGFloat = 18
let CFIX_HEADER: CGFloat = 50          // back + title band
let CFIX_FOOTER: CGFloat = 54          // divider + refresh row
let CFIX_BOX_PADX: CGFloat = 11
let CFIX_BOX_PADTOP: CGFloat = 9
let CFIX_BOX_PADBOT: CGFloat = 9
let CFIX_BOX_GAP: CGFloat = 7           // mono command → copy label
let CFIX_LABEL_H: CGFloat = 15          // copy-label row

/// Every wrapped block height + the panel total, computed once and shared by the height
/// pass (`claudeFixHeight`) and the draw pass (`drawClaudeFix`) so they can never drift.
struct CFixMetrics { let introH, s1H, box1H, s2H, box2H, s3H, noteH, s4H, total: CGFloat }
func claudeFixMetrics(expired: Bool = false) -> CFixMetrics {
    let c = claudeFixStrings(expired: expired)
    let contentW = PANEL_W - CFIX_PAD * 2
    let monoW = contentW - CFIX_BOX_PADX * 2
    let white = cg(gray(1, 0.9))
    func wtitle(_ s: String) -> CGFloat { wrappedHeight(ctAttr(s, ctFont(12, .medium), white), width: contentW) }
    func wbody(_ s: String, _ sz: CGFloat) -> CGFloat { wrappedHeight(ctAttr(s, ctFont(sz, .regular), white), width: contentW) }
    func box(_ cmd: String) -> CGFloat {
        CFIX_BOX_PADTOP + wrappedHeight(ctAttr(cmd, ctMono(11, .regular), white), width: monoW)
            + CFIX_BOX_GAP + CFIX_LABEL_H + CFIX_BOX_PADBOT
    }
    let introH = wbody(c.intro, 11.5)
    let s1H = wtitle(c.s1), box1H = box(c.cmd1)
    let s2H = wtitle(c.s2), box2H = box(c.cmd2)
    let s3H = wtitle(c.s3)
    let noteH = wbody(c.note, 11)
    let s4H = wtitle(c.s4)
    var y = CFIX_HEADER + 6
    y += introH + 14
    y += s1H + 8 + box1H + 16
    y += s2H + 8 + box2H + 16
    y += s3H + 14
    y += noteH + 12
    y += s4H + 10
    return CFixMetrics(introH: introH, s1H: s1H, box1H: box1H, s2H: s2H, box2H: box2H,
                       s3H: s3H, noteH: noteH, s4H: s4H, total: y + CFIX_FOOTER)
}
func claudeFixHeight(expired: Bool = false) -> CGFloat { claudeFixMetrics(expired: expired).total }

@discardableResult
func drawClaudeFix(_ ctx: CGContext, size: CGSize, copiedCmd: String?, expired: Bool = false) -> [Hit] {
    let W = size.width, H = size.height
    var hits: [Hit] = []
    let cs = CGColorSpaceCreateDeviceRGB()
    let textHi = gray(1, 0.95), textMid = gray(1, 0.5), textLo = gray(1, 0.4)
    let blue = NSColor(srgbRed: 0.34, green: 0.62, blue: 1.0, alpha: 1)
    let green = NSColor(srgbRed: 0.3, green: 0.8, blue: 0.45, alpha: 1)
    let orange = NSColor(srgbRed: 1.0, green: 0.62, blue: 0.18, alpha: 1)
    let mono = gray(1, 0.9)
    let m = claudeFixMetrics(expired: expired)
    let c = claudeFixStrings(expired: expired)
    let contentW = PANEL_W - CFIX_PAD * 2
    let monoW = contentW - CFIX_BOX_PADX * 2

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
    func wrapped(_ a: NSAttributedString, x: CGFloat, topY: CGFloat, width: CGFloat, height: CGFloat) {
        let fs = CTFramesetterCreateWithAttributedString(a)
        let path = CGPath(rect: CGRect(x: x, y: H - topY - height, width: width, height: height), transform: nil)
        let frame = CTFramesetterCreateFrame(fs, CFRangeMake(0, 0), path, nil)
        ctx.textMatrix = .identity
        CTFrameDraw(frame, ctx)
    }
    func roundFill(_ r: CGRect, _ rad: CGFloat, _ color: NSColor) {
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil))
        ctx.setFillColor(cg(color)); ctx.fillPath()
    }
    func roundStroke(_ r: CGRect, _ rad: CGFloat, _ color: NSColor, _ lw: CGFloat) {
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil))
        ctx.setStrokeColor(cg(color)); ctx.setLineWidth(lw); ctx.strokePath()
    }
    func hdiv(_ x0: CGFloat, _ x1: CGFloat, _ topY: CGFloat) {
        ctx.setStrokeColor(cg(gray(1, 0.06))); ctx.setLineWidth(1)
        ctx.beginPath(); ctx.move(to: CGPoint(x: x0, y: H - topY)); ctx.addLine(to: CGPoint(x: x1, y: H - topY)); ctx.strokePath()
    }

    // background — identical to the other panels
    let bgPath = CGPath(roundedRect: CGRect(x: 0.5, y: 0.5, width: W - 1, height: H - 1), cornerWidth: 18, cornerHeight: 18, transform: nil)
    ctx.saveGState(); ctx.addPath(bgPath); ctx.clip()
    if let g = CGGradient(colorsSpace: cs, colors: [cg(gray(0.16, 1)), cg(gray(0.075, 1))] as CFArray, locations: [0, 1]) {
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: H), end: CGPoint(x: 0, y: 0), options: [])
    }
    if let glow = CGGradient(colorsSpace: cs, colors: [cg(NSColor(srgbRed: 1, green: 0.5, blue: 0.2, alpha: 0.10)), cg(NSColor(srgbRed: 1, green: 0.5, blue: 0.2, alpha: 0))] as CFArray, locations: [0, 1]) {
        ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 54, y: H - 26), startRadius: 0, endCenter: CGPoint(x: 54, y: H - 26), endRadius: 170, options: [])
    }
    ctx.restoreGState()
    ctx.addPath(bgPath); ctx.setStrokeColor(cg(gray(1, 0.08))); ctx.setLineWidth(1); ctx.strokePath()

    // header: back + title
    let backRect = rectTL(CFIX_PAD - 4, CFIX_PAD - 6, 28, 28)
    drawSF(ctx, "chevron.left", in: backRect.insetBy(dx: 7, dy: 6), textMid, weight: .semibold)
    hits.append(Hit(id: "back", rect: backRect))
    text(attr(c.title, 16, .semibold, textHi), x: CFIX_PAD + 24, topY: CFIX_PAD - 2)

    // a command box: mono command (wrapping) + a "copy" label; the whole box copies on tap
    func cmdBox(_ topY: CGFloat, _ boxH: CGFloat, _ cmd: String) {
        let r = rectTL(CFIX_PAD, topY, contentW, boxH)
        roundFill(r, 8, gray(1, 0.05)); roundStroke(r, 8, gray(1, 0.09), 1)
        let monoA = ctAttr(cmd, ctMono(11, .regular), cg(mono))
        let monoH = boxH - CFIX_BOX_PADTOP - CFIX_BOX_GAP - CFIX_LABEL_H - CFIX_BOX_PADBOT
        wrapped(monoA, x: CFIX_PAD + CFIX_BOX_PADX, topY: topY + CFIX_BOX_PADTOP, width: monoW, height: monoH)
        // copy label, bottom-right
        let copied = (copiedCmd == cmd)
        let label = copied ? c.copied : c.copy
        let accent = copied ? green : blue
        let lblFont = ctFont(11, .medium)
        let lw = ceil(lineWidth(CTLineCreateWithAttributedString(ctAttr(label, lblFont, cg(accent)))))
        let icoW: CGFloat = 11, g: CGFloat = 5
        let labelTop = topY + boxH - CFIX_BOX_PADBOT - CFIX_LABEL_H
        let rightX = CFIX_PAD + contentW - CFIX_BOX_PADX
        let icoX = rightX - lw - g - icoW
        drawSF(ctx, copied ? "checkmark" : "doc.on.doc",
               in: rectTL(icoX, labelTop + 1.5, icoW, icoW), accent, weight: .semibold)
        text(attr(label, 11, .medium, accent), x: rightX, topY: labelTop, align: 2)
        hits.append(Hit(id: "copy:\(cmd)", rect: r))
    }

    // body — top-down cursor
    var y = CFIX_HEADER + 6
    wrapped(attr(c.intro, 11.5, .regular, textMid), x: CFIX_PAD, topY: y, width: contentW, height: m.introH); y += m.introH + 14
    wrapped(attr(c.s1, 12, .medium, textHi), x: CFIX_PAD, topY: y, width: contentW, height: m.s1H); y += m.s1H + 8
    cmdBox(y, m.box1H, c.cmd1); y += m.box1H + 16
    wrapped(attr(c.s2, 12, .medium, textHi), x: CFIX_PAD, topY: y, width: contentW, height: m.s2H); y += m.s2H + 8
    cmdBox(y, m.box2H, c.cmd2); y += m.box2H + 16
    wrapped(attr(c.s3, 12, .medium, textHi), x: CFIX_PAD, topY: y, width: contentW, height: m.s3H); y += m.s3H + 14
    wrapped(attr(c.note, 11, .regular, textLo), x: CFIX_PAD, topY: y, width: contentW, height: m.noteH); y += m.noteH + 12
    wrapped(attr(c.s4, 12, .medium, textHi), x: CFIX_PAD, topY: y, width: contentW, height: m.s4H)

    // footer: divider + Refresh
    hdiv(CFIX_PAD, W - CFIX_PAD, H - CFIX_FOOTER + 8)
    let pillH: CGFloat = 30
    let pillTopY = (H - CFIX_FOOTER + 8) + (CFIX_FOOTER - 8 - pillH) / 2
    let label = tr("Обновить", "Refresh")
    let lw = ceil(lineWidth(CTLineCreateWithAttributedString(ctAttr(label, ctFont(12.5, .semibold), cg(.white)))))
    let icoW: CGFloat = 12, g: CGFloat = 6, pw = lw + icoW + g + 30
    let pr = rectTL(W - CFIX_PAD - pw, pillTopY, pw, pillH)
    roundFill(pr, 9, orange)
    drawSF(ctx, "arrow.clockwise", in: rectTL(W - CFIX_PAD - pw + 15, pillTopY + (pillH - icoW) / 2, icoW, icoW), gray(0.1, 1), weight: .bold)
    text(attr(label, 12.5, .semibold, gray(0.1, 1)), x: W - CFIX_PAD - pw + 15 + icoW + g, topY: pillTopY + (pillH - 15) / 2)
    hits.append(Hit(id: "fixrefresh", rect: pr))

    return hits
}

// MARK: - Panel view + window

final class LimitsPanelView: NSView {
    var claude = LimitData(); var codex = LimitData()
    var interval: TimeInterval = POLL_DEFAULT
    var autoIntervals: [String: TimeInterval] = [:]
    var updated: Date?
    var hits: [Hit] = []
    var onInterval: ((TimeInterval) -> Void)?
    var onRefresh: (() -> Void)?
    var onQuit: (() -> Void)?
    var onOpenURL: ((String) -> Void)?
    var onPreview: ((String) -> Void)?
    var about = AboutState()
    var onCheckUpdate: (() -> Void)?
    var onUpdate: ((String) -> Void)?
    var onInstall: (() -> Void)?
    var onWhatsNew: (() -> Void)?
    var onTrayChanged: (() -> Void)?     // the menu-bar picker changed → redraw the strip now
    var onAutoSummary: (() -> String)?
    var onProductsChanged: (() -> Void)?
    var onViewChanged: (() -> Void)?     // Simple ↔ Advanced switched
    var mode: PanelMode = .main
    // "Connect Claude Code" walkthrough: which command was just copied (transient tick)
    var copiedCmd: String?
    var copiedTimer: Timer?
    // "What's new" screen state
    var notes: [ReleaseNote] = []
    var notesLoading = false
    var notesError = ""
    var scroll: CGFloat = 0
    var notesContentH: CGFloat = 0
    var notesViewportH: CGFloat = 0
    override var isFlipped: Bool { false }

    func setMode(_ m: PanelMode) {
        mode = m
        resizeToContent()
    }

    /// Resize the panel (anchored at its top edge) to fit the current mode/state.
    func resizeToContent() {
        var targetH = mainPanelHeight(claude, codex)
        if mode == .settings {
            targetH = settingsTotalHeight(about)
        } else if mode == .sounds {
            targetH = soundsPageHeight()
        } else if mode == .whatsnew {
            notesContentH = (notesLoading || notes.isEmpty) ? 0 : notesContentHeight(notesAttributedString(notes), width: WN_CONTENT_W)
            let bodyH = (notesLoading || notes.isEmpty) ? 64 : notesContentH
            let screenMax = (window?.screen?.visibleFrame.height ?? 800) - 40
            let maxH = min(screenMax, 540)
            targetH = min(maxH, WN_HEADER + WN_FOOTER + bodyH)
            notesViewportH = targetH - WN_HEADER - WN_FOOTER
        } else if mode == .claudeFix {
            let screenMax = (window?.screen?.visibleFrame.height ?? 800) - 40
            targetH = min(screenMax, claudeFixHeight(expired: claude.auth == .expired))
        }
        if let win = window {
            let f = win.frame
            var ny = f.maxY - targetH
            if let scr = win.screen { ny = max(scr.visibleFrame.minY + 8, ny) }
            win.setFrame(NSRect(x: f.minX, y: ny, width: PANEL_W, height: targetH), display: true)
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if mode == .settings || mode == .sounds {
            hits = drawSettings(ctx, size: bounds.size, about: about, soundsPage: mode == .sounds, copied: copiedCmd)
        } else if mode == .whatsnew {
            hits = drawWhatsNew(ctx, size: bounds.size, notes: notes, loading: notesLoading,
                                error: notesError, scroll: scroll, contentH: notesContentH,
                                viewportH: notesViewportH, about: about)
        } else if mode == .claudeFix {
            hits = drawClaudeFix(ctx, size: bounds.size, copiedCmd: copiedCmd,
                                 expired: claude.auth == .expired)
        } else {
            hits = advancedEnabled()
                ? drawAdvanced(ctx, size: bounds.size, claude: claude, codex: codex, interval: interval, updated: updated, about: about, autoIntervals: autoIntervals)
                : drawPanel(ctx, size: bounds.size, claude: claude, codex: codex, interval: interval, updated: updated, about: about, autoIntervals: autoIntervals)
        }
        removeAllToolTips()
        for h in hits where h.id == "iv0" { addToolTip(h.rect, owner: self, userData: nil) }
    }

    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
                       userData data: UnsafeMutableRawPointer?) -> String {
        onAutoSummary?() ?? tr("Авто: 15 мин → 30 мин → 1 ч → 4 ч", "Auto: 15 min → 30 min → 1 h → 4 h")
    }

    override func scrollWheel(with event: NSEvent) {
        guard mode == .whatsnew else { super.scrollWheel(with: event); return }
        let maxScroll = max(0, notesContentH - notesViewportH)
        scroll = min(maxScroll, max(0, scroll - event.scrollingDeltaY))
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for h in hits where h.rect.contains(p) {
            switch h.id {
            case "refresh": onRefresh?()
            case "quit": onQuit?()
            case "settings": setMode(.settings)
            case "back": setMode(.main)
            case "backsettings": setMode(.settings)
            case "whatsnew": onWhatsNew?()
            case "checkupdate": onCheckUpdate?()
            case "update": if let u = about.availURL { onUpdate?(u) }
            case "install": onInstall?()
            case "togglelogin": setLoginEnabled(!loginEnabled()); needsDisplay = true
            case "claudefix": setMode(.claudeFix)
            case "fixrefresh": onRefresh?(); setMode(.main)
            default:
                if h.id.hasPrefix("copy:") {
                    copyToClipboard(String(h.id.dropFirst(5)))
                } else if h.id.hasPrefix("lang:") {
                    UserDefaults.standard.set(String(h.id.dropFirst(5)), forKey: "lang")
                    resizeToContent()        // relayout + redraw in the chosen language
                } else if h.id.hasPrefix("monitor:") {
                    let product = String(h.id.dropFirst(8))
                    UserDefaults.standard.set(!productEnabled(product), forKey: "monitor_" + product)
                    onProductsChanged?()
                    resizeToContent()
                } else if h.id.hasPrefix("toggle:") {
                    let key = String(h.id.dropFirst(7))
                    let d = UserDefaults.standard; d.set(!d.bool(forKey: key), forKey: key)
                    needsDisplay = true
                } else if h.id == "sync:login" {
                    GitHubSync.shared.startLogin()
                } else if h.id == "sync:keychain-retry" {
                    GitHubSync.shared.retryKeychainAccess()
                } else if h.id == "sync:cancel" {
                    GitHubSync.shared.cancelLogin()
                } else if h.id == "sync:logout" {
                    GitHubSync.shared.logout()
                } else if h.id == "sync:copy" || h.id == "sync:open" {
                    // The device page asks for the code — put it on the clipboard either way.
                    if let code = GitHubSync.shared.ui.userCode { copyToClipboard(code) }
                    if h.id == "sync:open", let u = URL(string: GitHubSync.shared.verifyURL) { NSWorkspace.shared.open(u) }
                } else if h.id == "sounds:open" {
                    setMode(.sounds)
                } else if h.id == "hist:toggle" {
                    UserDefaults.standard.set(!advHistExpanded(), forKey: "advHistExpanded")
                    resizeToContent()
                } else if h.id.hasPrefix("hist:") {
                    UserDefaults.standard.set(String(h.id.dropFirst(5)), forKey: "advHistProduct")
                    resizeToContent()
                } else if h.id.hasPrefix("sub:") {
                    let parts = h.id.dropFirst(4).split(separator: ":")
                    if parts.count == 2, let v = Double(parts[1]) {
                        UserDefaults.standard.set(v, forKey: parts[0] == "claude" ? "subClaude" : "subCodex")
                        needsDisplay = true
                    }
                } else if h.id.hasPrefix("view:") {
                    UserDefaults.standard.set(h.id == "view:advanced", forKey: "advanced")
                    onViewChanged?()
                    resizeToContent()
                } else if h.id.hasPrefix("trayslot:") {
                    let parts = h.id.dropFirst(9).split(separator: ":")
                    if parts.count == 2, let slot = Int(parts[0]) {
                        trayApplySlot(slot, TrayMetric(rawValue: String(parts[1])))
                        onTrayChanged?()         // the menu bar reflects the tap immediately
                        needsDisplay = true
                    }
                } else if h.id.hasPrefix("preview:") {
                    onPreview?(String(h.id.dropFirst(8)))
                } else if h.id.hasPrefix("set5:") {
                    let id = String(h.id.dropFirst(5))
                    UserDefaults.standard.set(id, forKey: "sound5hChoice")
                    onPreview?(id); needsDisplay = true
                } else if h.id.hasPrefix("set7:") {
                    let id = String(h.id.dropFirst(5))
                    UserDefaults.standard.set(id, forKey: "sound7dChoice")
                    onPreview?(id); needsDisplay = true
                } else if h.id.hasPrefix("setR:") {
                    let id = String(h.id.dropFirst(5))
                    UserDefaults.standard.set(id, forKey: "reachedChoice")
                    onPreview?(id); needsDisplay = true
                } else if h.id.hasPrefix("iv"), let v = Double(h.id.dropFirst(2)) {
                    onInterval?(v)
                } else if h.id.hasPrefix("open:") {
                    onOpenURL?(String(h.id.dropFirst(5)))
                }
            }
            return
        }
    }

    /// Put a shell command on the clipboard and flash a "Copied" tick on its box.
    func copyToClipboard(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
        copiedCmd = s
        needsDisplay = true
        copiedTimer?.invalidate()
        copiedTimer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: false) { [weak self] _ in
            self?.copiedCmd = nil
            self?.needsDisplay = true
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
        guard panel.isVisible else { return }
        // Opening the panel triggers a refresh, and that refresh can add or drop the per-model
        // row — i.e. change the height the content needs. The frame was sized for the data at
        // click time, so without this the taller layout draws past the bottom edge and the
        // footer line gets clipped. Resize whenever the needed height no longer matches.
        if view.mode == .main, abs(panel.frame.height - mainPanelHeight(claude, codex)) > 0.5 {
            view.resizeToContent()
        } else {
            view.needsDisplay = true
        }
    }

    func show(below button: NSStatusBarButton) {
        view.mode = .main   // always open on the main screen
        let mainH = mainPanelHeight(view.claude, view.codex)
        var origin = NSPoint(x: 200, y: 200)
        if let win = button.window {
            let bf = button.frame
            let pt = win.convertPoint(toScreen: NSPoint(x: bf.midX, y: bf.minY))
            origin = NSPoint(x: pt.x - PANEL_W / 2, y: pt.y - mainH - 6)
            if let scr = win.screen ?? NSScreen.main {
                let v = scr.visibleFrame
                origin.x = max(v.minX + 8, min(origin.x, v.maxX - PANEL_W - 8))
                origin.y = max(v.minY + 8, origin.y)
            }
        }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: PANEL_W, height: mainH)), display: false)
        view.needsDisplay = true
        panel.orderFrontRegardless()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hide()
        }
    }

    func hide() {
        panel.orderOut(nil)
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        view.mode = .main; view.scroll = 0   // forget any sub-screen: next open starts on the main screen
    }
}

// MARK: - Reset sounds

struct ResetSound { let id: String; let ru: String; let en: String; let file: String
    var name: String { tr(ru, en) } }
let RESET_SOUNDS: [ResetSound] = [
    ResetSound(id: "rise",      ru: "Восход",   en: "Sunrise",   file: "snd-rise"),
    ResetSound(id: "drop",      ru: "Капля",    en: "Droplet",   file: "snd-drop"),
    ResetSound(id: "celebrate", ru: "Праздник", en: "Celebrate", file: "snd-celebrate"),
    ResetSound(id: "coin",      ru: "Монетка",  en: "Coin",      file: "snd-coin"),
    ResetSound(id: "victory",   ru: "Победа",   en: "Victory",   file: "snd-victory"),
    ResetSound(id: "chime",     ru: "Перезвон", en: "Chime",     file: "snd-chime"),
    ResetSound(id: "hop",       ru: "Прыжок",   en: "Hop",       file: "snd-hop"),
]
let REACHED_SOUNDS: [ResetSound] = [
    ResetSound(id: "outage",  ru: "Отбой",    en: "Lights out", file: "snd-outage"),
    ResetSound(id: "sunset",  ru: "Закат",    en: "Sunset",     file: "snd-sunset"),
    ResetSound(id: "fadeout", ru: "Угасание", en: "Fade out",   file: "snd-fadeout"),
]
func validSound(_ v: String?, _ pool: [ResetSound], _ fallback: String) -> String {
    let id = v ?? fallback
    return pool.contains { $0.id == id } ? id : fallback
}
func sound5hId() -> String { validSound(UserDefaults.standard.string(forKey: "sound5hChoice"), RESET_SOUNDS, "rise") }
func sound7dId() -> String { validSound(UserDefaults.standard.string(forKey: "sound7dChoice"), RESET_SOUNDS, "celebrate") }
func reachedId() -> String { validSound(UserDefaults.standard.string(forKey: "reachedChoice"), REACHED_SOUNDS, "outage") }
func settingsTotalHeight(_ about: AboutState, aboutCap: CGFloat? = nil) -> CGFloat {
    // An explicit caption position lets offline layout tests avoid the real preferences.
    let c4top = (aboutCap ?? setAboutCap()) + SET_CAP_H
    let needsLine = about.availVersion != nil || about.msg != .none || about.phase != .idle
    return c4top + 44 + (needsLine ? 22 : 0) + 16
}
func soundURL(_ file: String) -> URL? {
    if let u = Bundle.main.url(forResource: file, withExtension: "wav") { return u }
    let p = DATA_DIR + "/assets/\(file).wav"
    return FileManager.default.fileExists(atPath: p) ? URL(fileURLWithPath: p) : nil
}

// MARK: - Update check / self-update

enum UpdatePhase { case idle, downloading, ready }
enum AboutMsg { case none, upToDate, checkFailed, downloadFailed }   // stored as a kind, localized at draw time

struct AboutState {
    var version: String = APP_VERSION
    var checking = false
    var msg: AboutMsg = .none        // result of a manual check / a failed download
    var availVersion: String?
    var availURL: String?
    var phase: UpdatePhase = .idle   // idle → downloading → ready (downloaded, awaiting install)
    var progress: Double = 0         // 0…1 while downloading
    var dmgPath: String?             // local path of the downloaded .dmg when ready
}

func versionGreater(_ a: String, _ b: String) -> Bool {
    let pa = a.split(separator: ".").map { Int($0) ?? 0 }
    let pb = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0 ..< max(pa.count, pb.count) {
        let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
        if x != y { return x > y }
    }
    return false
}

/// Latest GitHub release as (version, dmgURL), or nil on failure.
func latestRelease() -> (version: String, dmgURL: String)? {
    let resp = http("https://api.github.com/repos/ArrivaRUS/claude-codex-limits/releases/latest",
                    method: "GET",
                    headers: ["User-Agent": "ClaudeCodexLimits", "Accept": "application/vnd.github+json"],
                    body: nil)
    guard resp.status == 200, let d = resp.data,
          let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
          let tag = j["tag_name"] as? String else { return nil }
    let ver = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    var dmg: String?
    if let assets = j["assets"] as? [[String: Any]] {
        for a in assets where (a["name"] as? String)?.hasSuffix(".dmg") == true {
            dmg = a["browser_download_url"] as? String; break
        }
    }
    guard let u = dmg else { return nil }
    return (ver, u)
}

// MARK: - Release notes ("What's new")

let WN_HEADER: CGFloat = 52                                  // back + title band
let WN_FOOTER: CGFloat = 60                                  // divider + action row
let WN_PAD: CGFloat = 18
let WN_CONTENT_W: CGFloat = PANEL_W - WN_PAD * 2 - 10        // text column (leaves a scrollbar gutter)

struct ReleaseNote { let version: String; let date: String; let body: String }

/// Every published release newer than `current`, newest first, with its notes —
/// so a user who skipped several versions sees the whole accumulated changelog.
func releaseNotesSince(_ current: String) -> [ReleaseNote] {
    let resp = http("https://api.github.com/repos/ArrivaRUS/claude-codex-limits/releases?per_page=30",
                    method: "GET",
                    headers: ["User-Agent": "ClaudeCodexLimits", "Accept": "application/vnd.github+json"],
                    body: nil)
    guard resp.status == 200, let d = resp.data,
          let arr = (try? JSONSerialization.jsonObject(with: d)) as? [[String: Any]] else { return [] }
    var out: [ReleaseNote] = []
    for r in arr {
        guard let tag = r["tag_name"] as? String else { continue }
        if (r["draft"] as? Bool) == true || (r["prerelease"] as? Bool) == true { continue }
        let ver = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard versionGreater(ver, current) else { continue }
        let body = (r["body"] as? String) ?? ""
        let date = String((r["published_at"] as? String)?.prefix(10) ?? "")
        out.append(ReleaseNote(version: ver, date: date, body: body))
    }
    out.sort { versionGreater($0.version, $1.version) }
    return out
}

/// A release body may carry both languages, delimited by `<!--RU-->` / `<!--EN-->`.
/// Returns the section for `lang`; falls back to the whole body if it isn't marked.
func localizedBody(_ body: String, _ lang: String) -> String {
    guard let en = body.range(of: "<!--EN-->") else { return body }   // single-language release
    let enPart = String(body[en.upperBound...])
    var ruPart = String(body[..<en.lowerBound])
    if let ru = ruPart.range(of: "<!--RU-->") { ruPart = String(ruPart[ru.upperBound...]) }
    return (lang == "en" ? enPart : ruPart).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Light markdown tidy for display (strip headings/bold/code, normalize bullets, collapse blanks).
func tidyNotes(_ s: String) -> String {
    var lines: [String] = []
    for raw in s.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
        var l = raw.trimmingCharacters(in: .whitespaces)
        while l.hasPrefix("#") { l.removeFirst() }
        l = l.trimmingCharacters(in: .whitespaces)
        if l.hasPrefix("- ") || l.hasPrefix("* ") { l = "•  " + l.dropFirst(2) }
        l = l.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        lines.append(l)
    }
    var res: [String] = []
    for l in lines { if l.isEmpty && (res.last?.isEmpty ?? true) { continue }; res.append(l) }
    return res.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

func notesAttributedString(_ notes: [ReleaseNote]) -> NSAttributedString {
    let accent = NSColor(srgbRed: 1.0, green: 0.62, blue: 0.18, alpha: 1)
    let bodyColor = NSColor(white: 1, alpha: 0.66)
    let m = NSMutableAttributedString()
    for (i, n) in notes.enumerated() {
        if i > 0 { m.append(ctAttr("\n\n", ctFont(7, .regular), cg(.white))) }
        let head = tr("Версия", "Version") + " \(n.version)" + (n.date.isEmpty ? "" : "    \(n.date)") + "\n"
        m.append(ctAttr(head, ctFont(13.5, .semibold), cg(accent)))
        let t = tidyNotes(localizedBody(n.body, appLang()))
        m.append(ctAttr(t.isEmpty ? "—" : t, ctFont(12, .regular), cg(bodyColor)))
    }
    return m
}

/// Lay-out height of the notes column at the given width.
func notesContentHeight(_ attr: NSAttributedString, width: CGFloat) -> CGFloat {
    guard attr.length > 0 else { return 0 }
    let fs = CTFramesetterCreateWithAttributedString(attr)
    let sz = CTFramesetterSuggestFrameSizeWithConstraints(
        fs, CFRangeMake(0, attr.length), nil,
        CGSize(width: width, height: .greatestFiniteMagnitude), nil)
    return ceil(sz.height) + 6
}

/// Downloads a file with progress callbacks. Keep a strong reference until `onDone` fires.
final class UpdateDownloader: NSObject, URLSessionDownloadDelegate {
    var onProgress: ((Double) -> Void)?
    var onDone: ((URL?) -> Void)?
    private var session: URLSession?

    func start(_ url: URL) {
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        var req = URLRequest(url: url)
        req.setValue("ClaudeCodexLimits", forHTTPHeaderField: "User-Agent")
        session?.downloadTask(with: req).resume()
    }
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten written: Int64, totalBytesExpectedToWrite total: Int64) {
        guard total > 0 else { return }
        let p = Double(written) / Double(total)
        DispatchQueue.main.async { self.onProgress?(p) }
    }
    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // `location` is deleted when this returns — move it to a stable path now.
        let dest = URL(fileURLWithPath: NSTemporaryDirectory() + "ccl-update.dmg")
        try? FileManager.default.removeItem(at: dest)
        let ok = (try? FileManager.default.moveItem(at: location, to: dest)) != nil
        let result: URL? = ok ? dest : nil
        DispatchQueue.main.async { self.onDone?(result) }
    }
    func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error != nil { DispatchQueue.main.async { self.onDone?(nil) } }
        s.finishTasksAndInvalidate()
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var timer: Timer?
    var interval: TimeInterval = storedPollInterval()
    var last: (LimitData, LimitData)?
    var panelCtrl: PanelController!
    var resetSound: NSSound?
    var soundBaseline = false
    var selectionGeneration = 0
    var fetchingLimits = false
    var autoStates = loadAutoPollStates()
    var activityTimer: Timer?
    var availableUpdate: (version: String, url: String)?   // set by auto/manual checks
    var updateTimer: Timer?
    var downloader: UpdateDownloader?
    /// KVO on the status-item button's effectiveAppearance: the menu bar can flip
    /// dark↔light with no system-theme change (dark wallpaper / Space switch), and
    /// that's exactly when the tray numbers would otherwise render in the wrong color.
    var trayAppearanceObs: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "…"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        panelCtrl = PanelController()
        publishAutoIntervals()
        panelCtrl.onInterval = { [weak self] sec in self?.setInterval(sec) }
        panelCtrl.onRefresh = { [weak self] in self?.doRefresh(live: true) }
        panelCtrl.onQuit = { NSApp.terminate(nil) }
        panelCtrl.onOpenURL = { [weak self] url in
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
            self?.panelCtrl.hide()
        }
        panelCtrl.view.onPreview = { [weak self] id in self?.playSound(id) }
        panelCtrl.view.onCheckUpdate = { [weak self] in self?.checkForUpdate() }
        panelCtrl.view.onUpdate = { [weak self] url in self?.startDownload(url) }
        panelCtrl.view.onInstall = { [weak self] in self?.installAndRelaunch() }
        panelCtrl.view.onWhatsNew = { [weak self] in self?.showWhatsNew() }
        panelCtrl.view.onViewChanged = { [weak self] in
            // Switching to Advanced needs the local-log index; scan right away.
            // Sync too: the timer skips cycles while Advanced is off, so the gist may be stale.
            if advancedEnabled() {
                UsageLogs.shared.scanAsync { changed in
                    if changed { self?.panelCtrl.view.needsDisplay = true }
                    GitHubSync.shared.syncNow()
                }
            }
        }
        panelCtrl.view.onAutoSummary = { [weak self] in self?.autoSummary() ?? "" }
        panelCtrl.view.onProductsChanged = { [weak self] in
            guard let self = self else { return }
            self.selectionGeneration += 1
            self.soundBaseline = false
            let c = selectedLimits(self.last?.0 ?? LimitData(present: false), product: "claude")
            let x = selectedLimits(self.last?.1 ?? LimitData(present: false), product: "codex")
            self.last = (c, x)
            self.applyTrayImage(c, x)
            self.panelCtrl.update(claude: c, codex: x, interval: self.interval, updated: self.panelCtrl.view.updated)
            self.doRefresh(live: true, scheduled: true)
            if advancedEnabled() {
                UsageLogs.shared.scanAsync { _ in
                    self.panelCtrl.view.needsDisplay = true
                    GitHubSync.shared.syncNow(force: true)
                }
            }
        }
        panelCtrl.view.onTrayChanged = { [weak self] in
            guard let self = self, let l = self.last else { return }
            self.applyTrayImage(l.0, l.1)
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(workspaceDidWake), name: NSWorkspace.didWakeNotification, object: nil)

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(themeChanged),
            name: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil)

        // The menu bar's look can change WITHOUT a system-theme notification (e.g. the
        // wallpaper behind the bar goes dark, or you switch to a Space with a dark one),
        // so also watch the button's own appearance and repaint the tray when it flips.
        trayAppearanceObs = statusItem.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            if let (c, x) = self?.last { self?.applyTrayImage(c, x) }
        }

        UsageHistory.shared.load()
        UsageLogs.shared.load()
        if let data = try? Data(contentsOf: URL(fileURLWithPath: CACHE_PATH)),
           let cache = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            let c = (cache["claude"] as? [String: Any]).map(dict2ld) ?? LimitData(present: false)
            let x = (cache["codex"] as? [String: Any]).map(dict2ld) ?? LimitData(present: false)
            render(c, x)
        }
        GitHubSync.shared.onChange = { [weak self] in
            GitHubSync.shared.recheckKeychainRetry()
            // Main and Settings heights both depend on sync state (orange line, status rows).
            guard let v = self?.panelCtrl.view else { return }
            if v.mode == .settings || v.mode == .main { v.resizeToContent() } else { v.needsDisplay = true }
        }
        GitHubSync.shared.load()
        GitHubSync.shared.syncNow()
        if advancedEnabled() {
            UsageLogs.shared.scanAsync { [weak self] changed in
                if changed { self?.panelCtrl.view.needsDisplay = true }
                GitHubSync.shared.syncNow()
            }
        }
        startTimer()
        startLogsTimer()
        startActivityTimer()
        doRefresh(live: true, scheduled: true)
        startUpdateChecks()     // background update check shortly after launch + every 6h
    }

    func applicationWillTerminate(_ note: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        trayAppearanceObs?.invalidate()
        trayAppearanceObs = nil
    }

    @objc func workspaceDidWake() {
        // Dispatch deadlines may lag sleep; the owner's remaining time includes it.
        GitHubSync.shared.recheckKeychainRetry(afterWake: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak self] in
            if autoPollEnabled() { self?.scanActivity(); self?.doRefresh(live: true, scheduled: true) }
            GitHubSync.shared.syncNow()
        }
    }

    var logsTimer: Timer?
    func startLogsTimer() {
        logsTimer?.invalidate()
        let t = Timer(timeInterval: 600, repeats: true) { [weak self] _ in
            GitHubSync.shared.syncNow()
            guard advancedEnabled() else { return }
            UsageLogs.shared.scanAsync { changed in
                if changed { self?.panelCtrl.view.needsDisplay = true }
                GitHubSync.shared.syncNow()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        logsTimer = t
    }

    func startTimer() {
        timer?.invalidate()
        let auto = autoPollEnabled()
        let now = Date().timeIntervalSince1970
        let delays = ["claude", "codex"].filter { productEnabled($0) }.map {
            (autoStates[$0] ?? AutoPollState()).nextDelay(now)
        }
        let delay = auto ? (fetchingLimits ? 60 : delays.min() ?? 60) : interval
        let t = Timer(timeInterval: delay, repeats: !auto) { [weak self] _ in
            self?.doRefresh(live: true, scheduled: true)
            if autoPollEnabled() { self?.startTimer() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        publishAutoIntervals()
    }

    @objc func themeChanged() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            if let (c, x) = self?.last { self?.render(c, x) }
        }
    }

    func publishAutoIntervals() {
        if let (claude, codex) = last {
            last = (limitsWithPollStatus(claude, product: "claude"), limitsWithPollStatus(codex, product: "codex"))
        }
        guard let panelCtrl = panelCtrl else { return }
        panelCtrl.view.autoIntervals = autoStates.mapValues { $0.interval }
        panelCtrl.view.claude = limitsWithPollStatus(panelCtrl.view.claude, product: "claude")
        panelCtrl.view.codex = limitsWithPollStatus(panelCtrl.view.codex, product: "codex")
        panelCtrl.view.needsDisplay = true
    }

    func saveAutoStates() {
        publishAutoIntervals()
        if autoPollEnabled() { startTimer() }
        if let data = try? JSONEncoder().encode(autoStates) { UserDefaults.standard.set(data, forKey: "autoPollState") }
    }

    func autoSummary() -> String {
        var lines = [tr("Авто: 15 мин → 30 мин → 1 ч → 4 ч. Частота зависит от расхода.",
                        "Auto: 15 min → 30 min → 1 h → 4 h, depending on usage.")]
        if autoPollEnabled() {
            for (p, name) in [("claude", "Claude Code"), ("codex", "Codex")] where productEnabled(p) {
                let state = autoStates[p] ?? AutoPollState()
                lines.append(name + ": " + fmtSpan(state.interval / 3600)
                             + (state.failed ? tr(" · пауза после ошибки", " · backing off after an error") : ""))
            }
            if let updated = panelCtrl?.view.updated {
                lines.append(tr("обновлено ", "updated ") + clockText(updated))
            }
        }
        return lines.joined(separator: "\n")
    }

    func scanActivity() {
        guard autoPollEnabled(), productEnabled("claude") || productEnabled("codex") else { return }
        UsageLogs.shared.scanAsync { [weak self] _ in
            guard let self = self, autoPollEnabled() else { return }
            let activity = UsageLogs.shared.snapshot().activity ?? [:]
            for p in ["claude", "codex"] where productEnabled(p) {
                var state = self.autoStates[p] ?? AutoPollState()
                state.localActivity(activity[p] ?? [], now: Date().timeIntervalSince1970)
                self.autoStates[p] = state
            }
            self.saveAutoStates()
            self.doRefresh(live: true, scheduled: true)
            self.panelCtrl.view.needsDisplay = true
        }
    }

    func startActivityTimer() {
        let t = Timer(timeInterval: 120, repeats: true) { [weak self] _ in self?.scanActivity() }
        RunLoop.main.add(t, forMode: .common); activityTimer = t
        scanActivity()
    }

    /// Auto polls are independent per product. Explicit refresh also respects the 15-minute
    /// floor; opening the panel respects the full schedule. Fixed intervals retain manual refresh.
    func doRefresh(live: Bool, scheduled: Bool = false) {
        guard !fetchingLimits else { return }
        let now = Date().timeIntervalSince1970
        var products = Set<String>()
        for p in ["claude", "codex"] where productEnabled(p) {
            var state = autoStates[p] ?? AutoPollState()
            if !autoPollEnabled() || state.due(now, manual: !scheduled) {
                products.insert(p); state.begin(now)
            }
            autoStates[p] = state
        }
        guard !products.isEmpty else {
            if last == nil { render(LimitData(present: false), LimitData(present: false)) }
            return
        }
        fetchingLimits = true; saveAutoStates()
        let generation = selectionGeneration
        let previous = last ?? (LimitData(present: false), LimitData(present: false))
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var claude = products.contains("claude") ? fetchClaude() : previous.0
            var codex = products.contains("codex") ? fetchCodex(live: live) : previous.1
            claude = selectedLimits(claude, product: "claude")
            codex = selectedLimits(codex, product: "codex")
            applyCache(&claude, &codex)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.fetchingLimits = false
                guard self.selectionGeneration == generation else {
                    for p in products { self.autoStates[p]?.begin(Date().timeIntervalSince1970) }
                    self.saveAutoStates()
                    self.doRefresh(live: true, scheduled: true); return
                }
                for (p, data) in [("claude", claude), ("codex", codex)] where products.contains(p) {
                    var state = self.autoStates[p] ?? AutoPollState()
                    state.observe(data, now: Date().timeIntervalSince1970)
                    self.autoStates[p] = state
                }
                self.saveAutoStates()
                self.render(claude, codex, sampleProducts: products)
            }
        }
    }

    @objc func refreshNow() { doRefresh(live: true) }   // user-initiated → live Codex

    func isDark() -> Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// Theme for the MENU-BAR strip specifically. The status-item button inherits the
    /// menu bar's *actual* appearance, which can be dark even under a Light system theme
    /// (a dark wallpaper turns the bar dark via vibrancy). Reading the button's own
    /// effectiveAppearance — not NSApp's — is what keeps the tray numbers legible.
    func isTrayDark() -> Bool {
        guard let a = statusItem?.button?.effectiveAppearance else { return isDark() }
        return a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    func limitsWithPollStatus(_ data: LimitData, product: String) -> LimitData {
        let state = autoStates[product]
        let next = autoPollEnabled() ? state.map { Date(timeIntervalSince1970: $0.lastAttempt + $0.interval) } : timer?.fireDate
        return withPollStatus(data, state: state, next: next)
    }
    func render(_ claude: LimitData, _ codex: LimitData, sampleProducts: Set<String> = []) {
        let claude = limitsWithPollStatus(selectedLimits(claude, product: "claude"), product: "claude")
        let codex = limitsWithPollStatus(selectedLimits(codex, product: "codex"), product: "codex")
        last = (claude, codex)
        applyTrayImage(claude, codex)
        if sampleProducts.contains("claude") { UsageHistory.shared.record(claude, product: "claude") }
        if sampleProducts.contains("codex") { UsageHistory.shared.record(codex, product: "codex") }
        let updated = [claude.asOf, codex.asOf].compactMap { $0 }.max()
        panelCtrl.update(claude: claude, codex: codex, interval: interval, updated: updated)
        if !sampleProducts.isEmpty { checkAlarms(claude, codex) }
    }

    /// (Re)build just the menu-bar image — used by render() and by the update badge refresh.
    func applyTrayImage(_ claude: LimitData, _ codex: LimitData) {
        var products: [(LimitData, String)] = []
        if productEnabled("claude"), claude.present { products.append((claude, "claude_128.png")) }
        if productEnabled("codex"), codex.present { products.append((codex, "codex_128.png")) }
        if let cgImg = renderStrip(products, dark: isTrayDark(), s: 2, badge: availableUpdate != nil), let btn = statusItem.button {
            let img = NSImage(cgImage: cgImg, size: NSSize(width: CGFloat(cgImg.width) / 2,
                                                           height: CGFloat(cgImg.height) / 2))
            img.isTemplate = false
            btn.image = img
            btn.title = ""
        }
    }

    // MARK: Reset sounds

    func playSound(_ id: String) {
        guard let s = (RESET_SOUNDS + REACHED_SOUNDS).first(where: { $0.id == id }),
              let u = soundURL(s.file), let snd = NSSound(contentsOf: u, byReference: true) else { return }
        resetSound = snd
        snd.play()
    }

    /// Fires chimes on window rollover (reset) and a sad sound when a limit is first reached.
    func checkAlarms(_ claude: LimitData, _ codex: LimitData) {
        let d = UserDefaults.standard
        // A reset is the moment a window rolls over — NOT merely "usage is 0". We require all of:
        //   • resets_at jumped forward (a new window boundary appeared),
        //   • we had actually used something in the old window (oldUsed > 0),
        //   • usage did not climb (newUsed <= oldUsed) — it drops to ~0 at a real reset.
        // So sitting at a constant level (including 0% while idle) never chimes, a slowly
        // creeping resets_at can't false-fire, and a genuine rollover chimes exactly once.
        var resetWins: [(rkey: String, ukey: String, date: Date?, used: Double?, is5h: Bool)] = [
            ("rst_c5", "use_c5", claude.sessionReset, claude.session, true),
            ("rst_x5", "use_x5", codex.sessionReset,  codex.session,  true),
            ("rst_c7", "use_c7", claude.weeklyReset,  claude.weekly,  false),
            ("rst_x7", "use_x7", codex.weeklyReset,   codex.weekly,   false),
        ]
        // A per-model weekly limit (e.g. Fable) is a weekly window too, so its rollover —
        // the moment that model becomes usable again — chimes with the weekly sound.
        // Keyed by model name so each model tracks its own window independently.
        if let s = claude.scoped {
            let k = s.name.lowercased()
            resetWins.append(("rst_cs_" + k, "use_cs_" + k, s.reset, s.percent, false))
        }
        var fired5 = false, fired7 = false
        for w in resetWins {
            guard let date = w.date else { continue }
            let newR = date.timeIntervalSince1970
            let oldR = d.double(forKey: w.rkey)
            let rolled = oldR > 0 && newR > oldR + 60
            if let newU = w.used {
                let oldU = d.double(forKey: w.ukey)          // 0 if never stored yet
                if soundBaseline, rolled, oldU > 0, newU <= oldU + 0.5 {
                    if w.is5h { fired5 = true } else { fired7 = true }
                }
                d.set(newU, forKey: w.ukey)
            }
            d.set(newR, forKey: w.rkey)
        }
        // A limit is "reached" when usage rounds to 100% (≥ 99.5, matching the shown %).
        // This is tracked via PERSISTED state (rch_*), so the alert survives app restarts
        // and fires once per crossing — including when the very first reading after launch
        // is already at the limit (e.g. it was hit while the app was closed). It never
        // re-alerts a state already recorded as reached. Crucially it does NOT depend on the
        // in-memory `soundBaseline`, so a restart can't silently swallow the alert.
        var reachWins: [(key: String, used: Double?)] = [
            ("rch_c5", claude.session), ("rch_x5", codex.session),
            ("rch_c7", claude.weekly), ("rch_x7", codex.weekly),
        ]
        // ...including a per-model weekly limit, which is the one you actually hit first
        // when you lean on a single model — so running out of Fable chimes like any other.
        if let s = claude.scoped { reachWins.append(("rch_cs_" + s.name.lowercased(), s.percent)) }
        var firedReached = false
        for w in reachWins {
            // No reading (failed fetch) must not erase the recorded state — otherwise the
            // next successful reading would re-announce a limit that was already reached.
            guard let used = w.used else { continue }
            let nowR = used >= 99.5
            let wasR = d.bool(forKey: w.key)
            if nowR, !wasR { firedReached = true }
            d.set(nowR, forKey: w.key)
        }
        let firstReading = !soundBaseline
        soundBaseline = true
        if !firstReading {                                   // reset chimes need the in-memory baseline
            if fired5, d.bool(forKey: "sound5h") { playSound(sound5hId()) }
            else if fired7, d.bool(forKey: "sound7d") { playSound(sound7dId()) }
        }
        if firedReached, d.bool(forKey: "reachedOn") { playSound(reachedId()) }
    }

    // MARK: Updates

    @objc func checkForUpdate() {
        let v = panelCtrl.view
        // a manual check resets any prior download state
        v.about.checking = true; v.about.msg = .none; v.about.availVersion = nil; v.about.availURL = nil
        v.about.phase = .idle; v.about.dmgPath = nil; v.about.progress = 0
        v.resizeToContent()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let r = latestRelease()
            DispatchQueue.main.async {
                guard let self = self else { return }
                let v = self.panelCtrl.view
                v.about.checking = false
                if let (ver, url) = r {
                    if versionGreater(ver, APP_VERSION) {
                        v.about.availVersion = ver; v.about.availURL = url; v.about.msg = .none
                        self.availableUpdate = (ver, url)
                    } else {
                        v.about.msg = .upToDate
                        self.availableUpdate = nil
                    }
                } else {
                    v.about.msg = .checkFailed
                }
                self.refreshTray()
                v.resizeToContent()
            }
        }
    }

    /// Open the "What's new" screen, lazily loading the accumulated release notes.
    func showWhatsNew() {
        let v = panelCtrl.view
        v.scroll = 0
        if v.notes.isEmpty { v.notesLoading = true; v.notesError = "" }
        v.setMode(.whatsnew)
        v.needsDisplay = true
        if v.notes.isEmpty {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let ns = releaseNotesSince(APP_VERSION)
                DispatchQueue.main.async {
                    guard let v = self?.panelCtrl.view else { return }
                    v.notes = ns; v.notesLoading = false
                    v.resizeToContent(); v.needsDisplay = true
                }
            }
        }
    }

    /// Re-render the tray so the "update available" badge appears/clears promptly.
    func refreshTray() { if let (c, x) = last { applyTrayImage(c, x) } }

    /// Background update checking: once shortly after launch, then every 6 hours.
    func startUpdateChecks() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in self?.autoCheck() }
        let t = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.autoCheck() }
        RunLoop.main.add(t, forMode: .common)
        updateTimer = t
    }

    /// Silent check; if a newer release exists, surface the tray badge + settings prompt.
    func autoCheck() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let r = latestRelease(), versionGreater(r.version, APP_VERSION) else { return }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.availableUpdate = (r.version, r.dmgURL)
                let v = self.panelCtrl.view
                if v.about.phase == .idle {        // don't disturb an in-progress download
                    v.about.availVersion = r.version; v.about.availURL = r.dmgURL
                    if v.mode == .settings { v.resizeToContent() }
                }
                self.refreshTray()
                if self.panelCtrl.isVisible { v.needsDisplay = true }
            }
        }
    }

    /// Step 1 — download the release .dmg with a live progress bar (does not install yet).
    func startDownload(_ urlStr: String) {
        guard let url = URL(string: urlStr) else { return }
        let v = panelCtrl.view
        v.about.phase = .downloading; v.about.progress = 0
        v.about.msg = .none; v.about.availVersion = nil
        v.resizeToContent(); v.needsDisplay = true
        let dl = UpdateDownloader()
        dl.onProgress = { [weak self] p in
            guard let self = self else { return }
            let v = self.panelCtrl.view
            v.about.progress = p
            if self.panelCtrl.isVisible { v.needsDisplay = true }
        }
        dl.onDone = { [weak self] fileURL in
            guard let self = self else { return }
            let v = self.panelCtrl.view
            var sizeOK = false
            if let f = fileURL, let attrs = try? FileManager.default.attributesOfItem(atPath: f.path),
               let sz = attrs[.size] as? Int, sz > 100_000 { sizeOK = true }
            if sizeOK, let f = fileURL {
                v.about.phase = .ready; v.about.dmgPath = f.path; v.about.progress = 1
                v.about.msg = .none
            } else {
                v.about.phase = .idle; v.about.msg = .downloadFailed
                if let u = self.availableUpdate { v.about.availVersion = u.version; v.about.availURL = u.url }
            }
            v.resizeToContent(); if self.panelCtrl.isVisible { v.needsDisplay = true }
            self.downloader = nil
        }
        downloader = dl
        dl.start(url)
    }

    /// Step 2 — swap the bundle from the downloaded .dmg via a detached helper, then relaunch.
    func installAndRelaunch() {
        let v = panelCtrl.view
        guard let dmg = v.about.dmgPath else { return }
        v.needsDisplay = true
        let appPath = Bundle.main.bundlePath
        let sp = NSTemporaryDirectory() + "ccl-update.sh"
        let script = """
        #!/bin/bash
        sleep 1.5
        DMG="\(dmg)"
        APP="\(appPath)"
        MP=$(/usr/bin/hdiutil attach "$DMG" -nobrowse -noverify 2>/dev/null | grep '/Volumes/' | sed -n 's/.*\\(\\/Volumes\\/.*\\)/\\1/p' | tail -1)
        SRC="$MP/Claude Codex Limits.app"
        if [ -n "$MP" ] && [ -d "$SRC" ]; then
          /bin/rm -rf "$APP"
          /bin/cp -R "$SRC" "$APP"
          /usr/bin/xattr -dr com.apple.quarantine "$APP" 2>/dev/null
          /usr/bin/hdiutil detach "$MP" >/dev/null 2>&1
          /usr/bin/open "$APP"
        fi
        /bin/rm -f "$DMG" "\(sp)"
        """
        try? script.write(toFile: sp, atomically: true, encoding: .utf8)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/bash"); p.arguments = [sp]
        try? p.run()
        NSApp.terminate(nil)
    }

    func setInterval(_ sec: TimeInterval) {
        UserDefaults.standard.set(sec == 0, forKey: "autoPoll")
        if sec != 0 {
            interval = normalizedPollInterval(sec)
            UserDefaults.standard.set(interval, forKey: "interval")
        }
        startTimer()
        panelCtrl.view.interval = interval
        publishAutoIntervals()
        if sec == 0 { scanActivity(); doRefresh(live: true, scheduled: true) }
        if let (c, x) = last { panelCtrl.update(claude: c, codex: x, interval: interval, updated: panelCtrl.view.updated) }
    }

    @objc func statusClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp { showContextMenu(); return }
        guard let btn = statusItem.button else { return }
        if panelCtrl.isVisible { panelCtrl.hide() }
        else {
            if let (c, x) = last { panelCtrl.update(claude: c, codex: x, interval: interval, updated: panelCtrl.view.updated) }
            panelCtrl.show(below: btn)
            doRefresh(live: true, scheduled: autoPollEnabled())   // Auto: opening the panel respects its schedule
        }
    }

    func showContextMenu() {
        let m = NSMenu()
        let r = m.addItem(withTitle: tr("Обновить", "Refresh"), action: #selector(refreshNow), keyEquivalent: ""); r.target = self
        m.addItem(.separator())
        let li = m.addItem(withTitle: tr("Запускать при входе", "Launch at login"), action: #selector(toggleLogin), keyEquivalent: "")
        li.target = self; li.state = loginEnabled() ? .on : .off
        m.addItem(.separator())
        let q = m.addItem(withTitle: tr("Выйти", "Quit"), action: #selector(quit), keyEquivalent: "q"); q.target = self
        if let btn = statusItem.button {
            m.popUp(positioning: nil, at: NSPoint(x: 0, y: btn.bounds.height + 4), in: btn)
        }
    }

    @objc func toggleLogin() { setLoginEnabled(!loginEnabled()) }
    @objc func quit() { NSApp.terminate(nil) }
}

// MARK: - Single instance (flock) + launch

// Ensure the data directory exists before ANY code path touches it. The lock
// file (LOCK_PATH), the cache (CACHE_PATH) and downloaded assets all live under
// DATA_DIR. Without this, on a clean Mac open(LOCK_PATH, O_CREAT, …) returns -1
// because the parent dir is missing → the app mistakes it for "another instance
// already running" and silently exit(0)'s. A single mkdir up front fixes both
// the silent-exit bug and the (previously failing) cache persistence.
if !CommandLine.arguments.contains("--sync-selftest") && !CommandLine.arguments.contains("--subscriptions-selftest") {
    try? FileManager.default.createDirectory(atPath: DATA_DIR, withIntermediateDirectories: true)
}

if CommandLine.arguments.contains("--preview") {
    var c = fetchClaude(); var x = fetchCodex(live: false); applyCache(&c, &x)
    let cP = (c, "claude_128.png"), xP = (x, "codex_128.png")
    writePreview([cP, xP], dark: true,  to: "/tmp/limits_preview_dark.png")
    writePreview([cP, xP], dark: false, to: "/tmp/limits_preview_light.png")
    writePreview([cP], dark: true, to: "/tmp/limits_preview_claude.png")   // single-product look
    writePreview([xP], dark: true, to: "/tmp/limits_preview_codex.png")
    // Synthetic tray demo for the v2.7 review: Codex has only a weekly reading (4%) → "4%"
    // on its own; Claude is not signed in → faint icon, no number.
    var cOut = LimitData(); cOut.present = true; cOut.auth = .loggedOut
    var xWeekly = LimitData(); xWeekly.present = true; xWeekly.weekly = 4   // weekly only, no session
    let demo = [(cOut, "claude_128.png"), (xWeekly, "codex_128.png")]
    writePreview(demo, dark: true,  to: "/tmp/limits_preview_demo_dark.png")
    writePreview(demo, dark: false, to: "/tmp/limits_preview_demo_light.png")
    print("preview written"); exit(0)
}

if CommandLine.arguments.contains("--panel-preview") {
    var c = fetchClaude(); var x = fetchCodex(live: false); applyCache(&c, &x)
    let s: CGFloat = 2
    func renderPanel(_ cl: LimitData, _ cx: LimitData, _ path: String) {
        let ph = panelMainHeight(cl, cx)
        guard let ctx = bitmapContext(Int(PANEL_W * s), Int(ph * s)) else { return }
        ctx.scaleBy(x: s, y: s)
        _ = drawPanel(ctx, size: CGSize(width: PANEL_W, height: ph),
                      claude: cl, codex: cx, interval: POLL_DEFAULT, updated: Date(), about: AboutState())
        guard let img = ctx.makeImage() else { return }
        let data = NSMutableData()
        if let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, img, nil)
            if CGImageDestinationFinalize(dest) { try? (data as Data).write(to: URL(fileURLWithPath: path)) }
        }
    }
    func savePNG(_ img: CGImage, _ path: String) {
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
    // v2.7: the main panel with Claude "not signed in" (the tap-to-fix card)…
    var cOut = LimitData(); cOut.present = true; cOut.auth = .loggedOut
    renderPanel(cOut, x, "/tmp/panel_claude_loggedout.png")
    // …and the expanded "Connect Claude Code" walkthrough itself.
    let fixH = claudeFixHeight()
    if let ctx = bitmapContext(Int(PANEL_W * s), Int(fixH * s)) {
        ctx.scaleBy(x: s, y: s)
        _ = drawClaudeFix(ctx, size: CGSize(width: PANEL_W, height: fixH), copiedCmd: nil)
        if let img = ctx.makeImage() { savePNG(img, "/tmp/panel_claude_fix.png") }
    }
    // and the same walkthrough with the install command showing its "copied" tick
    if let ctx = bitmapContext(Int(PANEL_W * s), Int(fixH * s)) {
        ctx.scaleBy(x: s, y: s)
        _ = drawClaudeFix(ctx, size: CGSize(width: PANEL_W, height: fixH), copiedCmd: CLAUDE_INSTALL_CMD)
        if let img = ctx.makeImage() { savePNG(img, "/tmp/panel_claude_fix_copied.png") }
    }
    print("panel preview written"); exit(0)
}

if CommandLine.arguments.contains("--settings-preview") {
    let d = UserDefaults.standard
    let s5 = d.bool(forKey: "sound5h"); d.set(true, forKey: "sound5h")   // show one toggle on
    let about = AboutState()
    let s: CGFloat = 2, sh = settingsTotalHeight(about)
    if let ctx = bitmapContext(Int(PANEL_W * s), Int(sh * s)) {
        ctx.scaleBy(x: s, y: s)
        _ = drawSettings(ctx, size: CGSize(width: PANEL_W, height: sh), about: about)
        if let img = ctx.makeImage() {
            let data = NSMutableData()
            if let dest = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(dest, img, nil)
                if CGImageDestinationFinalize(dest) { try? (data as Data).write(to: URL(fileURLWithPath: "/tmp/settings_preview.png")) }
            }
        }
    }
    d.set(s5, forKey: "sound5h")
    print("settings preview written"); exit(0)
}


/// Selftest stand-ins: no network, no Keychain. Everything the sync touches is injected.
struct OfflineSyncKeychain: SyncKeychain {
    func read() -> SyncKeychainRead { .missing }
    func write(_ token: String) -> SyncKeychainStatus { .failure(-1) }
    func delete() -> SyncKeychainStatus { .failure(-1) }
}
/// Reference storage lets a protocol value and the selftest observe the same in-memory token.
struct MemorySyncKeychain: SyncKeychain {
    private final class Storage {
        var token: String?
        init(_ token: String?) { self.token = token }
    }
    private let storage: Storage
    init(token: String?) { storage = Storage(token) }
    func read() -> SyncKeychainRead { storage.token.map { .token($0) } ?? .missing }
    func write(_ token: String) -> SyncKeychainStatus { storage.token = token; return .success }
    func delete() -> SyncKeychainStatus { storage.token = nil; return .success }
}
let OFFLINE_SYNC_HTTP: SyncHTTP = { _, _, _, _, _ in (0, nil, "selftest: network disabled", [:]) }

/// Selftest only: a scripted GitHub that records every request (never touches the network).
final class SelfTestHTTP {
    struct Call { let url: String; let method: String; let headers: [String: String]; var body: Data? = nil }
    private let lock = NSLock()
    private var _calls: [Call] = []
    var handler: (Call) -> SyncHTTPResult
    init(_ handler: @escaping (Call) -> SyncHTTPResult) { self.handler = handler }
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return _calls }
    func reset() { lock.lock(); _calls = []; lock.unlock() }
    var transport: SyncHTTP {
        return { url, method, headers, body, _ in
            let c = Call(url: url, method: method, headers: headers, body: body)
            self.lock.lock(); self._calls.append(c); self.lock.unlock()
            return self.handler(c)
        }
    }
}
/// Selftest only: an in-memory Keychain whose next reads can be scripted (e.g. `.timedOut`).
final class SelfTestKeychainStore {
    var token: String?
    var reads: [SyncKeychainRead] = []
    var readCount = 0, writes = 0, deletes = 0
    var deleteStatus: SyncKeychainStatus = .success
    init(_ token: String?) { self.token = token }
}
struct ScriptedSyncKeychain: SyncKeychain {
    let store: SelfTestKeychainStore
    func read() -> SyncKeychainRead {
        store.readCount += 1
        if !store.reads.isEmpty { return store.reads.removeFirst() }
        return store.token.map { .token($0) } ?? .missing
    }
    func write(_ token: String) -> SyncKeychainStatus { store.writes += 1; store.token = token; return .success }
    func delete() -> SyncKeychainStatus {
        store.deletes += 1
        if store.deleteStatus == .success || store.deleteStatus == .missing { store.token = nil }
        return store.deleteStatus
    }
}
extension GitHubSync {
    /// Selftest seam: the private URL gate of `gh` and the in-memory HTTP backoff.
    func selfTestGHStatus(_ path: String, token: String) -> Int { gh(path, token: token).status }
    var selfTestBackoffUntil: Date { backoffUntil }
    func selfTestWaitForQueue() -> Bool {
        let done = DispatchSemaphore(value: 0)
        q.async { done.signal() }
        return done.wait(timeout: .now() + 5) == .success
    }
}

// Selftest-only adapter: override every preferences operation reached by the
// actual AppKit draw/callback fixtures. No domain can fall through to disk.
import ObjectiveC
final class MemorySelfTestDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    private var registered: [String: Any] = [:]
    private var arguments: [String: Any] = [:]
    init() { super.init(suiteName: "ccl-memory-only-" + UUID().uuidString)! }
    func clear() { values = [:]; registered = [:]; arguments = [:] }
    override func object(forKey key: String) -> Any? { arguments[key] ?? values[key] ?? registered[key] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func set(_ value: Bool, forKey key: String) { values[key] = value }
    override func set(_ value: Int, forKey key: String) { values[key] = value }
    override func set(_ value: Double, forKey key: String) { values[key] = value }
    override func set(_ value: Float, forKey key: String) { values[key] = value }
    override func set(_ value: URL?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    override func string(forKey key: String) -> String? { object(forKey: key) as? String }
    override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    override func array(forKey key: String) -> [Any]? { object(forKey: key) as? [Any] }
    override func dictionary(forKey key: String) -> [String: Any]? { object(forKey: key) as? [String: Any] }
    override func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
    override func bool(forKey key: String) -> Bool { (object(forKey: key) as? NSNumber)?.boolValue ?? false }
    override func integer(forKey key: String) -> Int { (object(forKey: key) as? NSNumber)?.intValue ?? 0 }
    override func double(forKey key: String) -> Double { (object(forKey: key) as? NSNumber)?.doubleValue ?? 0 }
    override func float(forKey key: String) -> Float { (object(forKey: key) as? NSNumber)?.floatValue ?? 0 }
    override func url(forKey key: String) -> URL? { object(forKey: key) as? URL }
    override func register(defaults: [String: Any]) { registered.merge(defaults) { _, new in new } }
    override func dictionaryRepresentation() -> [String: Any] {
        registered.merging(values) { _, new in new }.merging(arguments) { _, new in new }
    }
    override func volatileDomain(forName name: String) -> [String: Any] {
        precondition(name == UserDefaults.argumentDomain, "selftest requested a real defaults domain")
        return arguments
    }
    override func setVolatileDomain(_ domain: [String: Any], forName name: String) {
        precondition(name == UserDefaults.argumentDomain, "selftest requested a real defaults domain")
        arguments = domain
    }
    override func persistentDomain(forName name: String) -> [String: Any]? {
        // AppKit queries the global domain while creating NSApplication. This
        // fixture has no persistent domains: every name resolves to RAM-only
        // emptiness, without super/CFPreferences or any disk fallback.
        return [:]
    }
    override func removePersistentDomain(forName name: String) {
        preconditionFailure("selftest persistent defaults mutation forbidden")
    }
    override func synchronize() -> Bool { true }
}
func installMemorySelfTestDefaults() -> MemorySelfTestDefaults {
    precondition(CommandLine.arguments.contains("--sync-selftest") || CommandLine.arguments.contains("--subscriptions-selftest"))
    let memory = MemorySelfTestDefaults()
    guard let getter = class_getClassMethod(UserDefaults.self, NSSelectorFromString("standardUserDefaults")) else {
        preconditionFailure("selftest cannot isolate UserDefaults.standard")
    }
    let replacement: @convention(block) (AnyObject) -> UserDefaults = { _ in memory }
    method_setImplementation(getter, imp_implementationWithBlock(replacement))
    precondition(UserDefaults.standard === memory, "standard preferences escaped the memory adapter")
    return memory
}

// Offline regression tests and fixture previews: no real credentials, logs, or settings writes.
if CommandLine.arguments.contains("--subscriptions-selftest") {
    let defaults = installMemorySelfTestDefaults()
    var prefs: [String: Any] = ["advanced": true, "advHistExpanded": false, "lang": "ru",
                               "monitor_claude": true, "monitor_codex": true, "autoPoll": false,
                               "interval": 1800, "autoPollState": try! JSONEncoder().encode([String: AutoPollState]())]
    func select(_ claude: Bool, _ codex: Bool) {
        prefs["monitor_claude"] = claude; prefs["monitor_codex"] = codex
        defaults.setVolatileDomain(prefs, forName: UserDefaults.argumentDomain)
    }
    func check(_ ok: Bool, _ message: String) {
        if !ok { print("FAIL " + message); exit(1) }
        print("OK " + message)
    }
    func reading(_ value: Double, _ at: Double, reset: Double = 1000000) -> LimitData {
        var d = LimitData(session: value, sessionReset: Date(timeIntervalSince1970: reset), asOf: Date(timeIntervalSince1970: at))
        d.apiFresh = true; return d
    }
    func observe(_ state: inout AutoPollState, _ value: Double, _ at: Double, reset: Double = 1000000) {
        state.begin(at); state.observe(reading(value, at, reset: reset), now: at)
    }
    var labelCases = 0
    for (lang, labels) in [("ru", ["15м", "30м", "1ч", "4ч"]), ("en", ["15m", "30m", "1h", "4h"])] {
        let enabled = ["claude": true, "codex": true]
        for (i, ci) in AUTO_STEPS.enumerated() {
            for (j, xi) in AUTO_STEPS.enumerated() {
                let expected = ci == xi ? [labels[i]] : ["Claude " + labels[i], "Codex " + labels[j]]
                check(autoPollLabelParts(auto: true, enabled: enabled, intervals: ["claude": ci, "codex": xi], lang: lang) == expected,
                      "Auto label \(lang): Claude=\(Int(ci)), Codex=\(Int(xi))")
                labelCases += 1
            }
            for product in ["claude", "codex"] {
                check(autoPollLabelParts(auto: true, enabled: [product: true], intervals: [product: ci], lang: lang) == [labels[i]],
                      "Auto label \(lang): \(product)-only \(Int(ci))")
                labelCases += 1
            }
        }
        check(autoPollLabelParts(auto: true, enabled: [:], intervals: [:], lang: lang) == [lang == "en" ? "no subscriptions" : "нет подписок"],
              "Auto label \(lang): both subscriptions off")
        check(autoPollLabelParts(auto: false, enabled: enabled, intervals: ["claude": 900, "codex": 14400], lang: lang).isEmpty,
              "Auto label \(lang): manual hides snapshot")
        check(autoPollLabelParts(auto: true, enabled: enabled, intervals: [:], lang: lang) == [labels[1]],
              "Auto label \(lang): missing states use 30 minutes")
        labelCases += 3
    }
    check(labelCases == 54, "54 independent RU/EN label fixtures")
    var auto = AutoPollState()
    observe(&auto, 10, 100000)
    check(auto.interval == 1800, "Auto first reading establishes a baseline at 30 minutes")
    observe(&auto, 12, 101800)
    check(auto.interval == 900, "Auto: ≥1 percentage point per 15 minutes switches to 15 minutes")
    observe(&auto, 12, 102700)
    check(auto.interval == 1800, "Auto first quiet window: 30 minutes")
    observe(&auto, 12.5, 104500)
    check(auto.interval == 3600, "Auto continued low usage: 1 hour")
    observe(&auto, 12.5, 108100)
    check(auto.interval == 14400, "Auto quiet for another hour: 4 hours")
    observe(&auto, 12.5, 122500)
    check(auto.interval == 14400, "Auto does not exceed 4 hours")
    var asleep = auto
    check(!asleep.localActivity([122501, 122501, 122501], now: 122600), "duplicate local events cannot wake Auto")
    check(!asleep.localActivity([120000, 120010, 120020], now: 122600), "old log history cannot wake Auto")
    check(asleep.localActivity([122510, 122520, 122530], now: 122600), "fresh local token events wake Auto")
    check(!asleep.due(123399) && asleep.due(123400), "local activity still respects the 15-minute floor")
    check(!auto.due(123400) && asleep.due(123400), "Claude and Codex schedules are independent")
    var restored = try! JSONDecoder().decode(AutoPollState.self, from: JSONEncoder().encode(auto))
    check(!restored.due(123399, manual: true) && !restored.due(123500) && restored.due(123400, manual: true),
          "restart, panel open and repeated refresh preserve persisted schedule")
    observe(&auto, 30, 136900)
    check(auto.interval == 900, "active consumption restores 15-minute polling")
    observe(&auto, 2, 137800, reset: 1100000)
    check(auto.interval == 900, "limit reset establishes a new baseline without false activity")
    var cached = reading(50, 138700); cached.apiFresh = false
    auto.begin(138700); auto.observe(cached, now: 138730)
    check(auto.failed && auto.interval == 1800, "cached/rollout fallback backs off instead of posing as fresh API data")
    check(!auto.localActivity([138740, 138750, 138760], now: 138800) && !auto.due(139630, manual: true),
          "local activity and manual refresh cannot override error backoff")
    check(!restored.due(120000) && restored.due(120900, manual: true), "clock rollback restarts a bounded minimum wait")
    check(POLL_CHOICES.map { $0.sec } == [900, 1800, 3600], "refresh choices: 15 minutes, 30 minutes, 1 hour")
    check([0.0, 60, 300, -1, 1200, .infinity, .nan].allSatisfy { normalizedPollInterval($0) == 1800 },
          "legacy and invalid intervals migrate to 30 minutes")
    check([900.0, 1800, 3600].allSatisfy { normalizedPollInterval($0) == $0 }, "valid intervals survive restart")
    let isolated = MemorySelfTestDefaults()
    check(productEnabled("claude", defaults: isolated) && productEnabled("codex", defaults: isolated),
          "missing preferences keep both products enabled")
    let root = NSTemporaryDirectory() + "ccl-subscriptions-" + UUID().uuidString
    isolatedSelfTestAssets = root + "/assets"
    let fm = FileManager.default
    let cp = root + "/.claude/projects/test/session.jsonl"
    let xp = root + "/.codex/sessions/test/rollout-test.jsonl"
    for path in [cp, xp] { try! fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true) }
    let stamp = ISO8601DateFormatter().string(from: Date())
    let cl = "{\"timestamp\":\"\(stamp)\",\"type\":\"assistant\",\"message\":{\"id\":\"m1\",\"model\":\"claude-opus-4-6\",\"usage\":{\"input_tokens\":100,\"output_tokens\":20}}}\n"
    let cx = "{\"timestamp\":\"\(stamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":50,\"output_tokens\":10}}}}\n"
    try! cl.write(toFile: cp, atomically: true, encoding: .utf8)
    try! cx.write(toFile: xp, atomically: true, encoding: .utf8)
    var ix = UsageIndex()
    select(false, true)
    check(UsageLogs.scan(&ix, home: root) && ix.files[cp] == nil && ix.files[xp] != nil && ix.days["claude"] == nil,
          "Codex-only scan never indexes Claude logs")
    select(true, true)
    check(UsageLogs.scan(&ix, home: root) && ix.files[cp] != nil && ix.days["claude"] != nil,
          "re-enabling Claude resumes indexing")
    let oldOffset = ix.files[cp]!.size
    try! (cl + cl.replacingOccurrences(of: "m1", with: "m2")).write(toFile: cp, atomically: true, encoding: .utf8)
    select(false, true)
    check(!UsageLogs.scan(&ix, home: root) && ix.files[cp]!.size == oldOffset && ix.days["claude"] != nil,
          "disabled logs stop advancing; existing history is retained")
    select(true, false)
    check(UsageLogs.scan(&ix, home: root) && ix.files[cp]!.size > oldOffset,
          "re-enabled logs catch up from the retained offset")
    let c = LimitData(session: 25, weekly: 40, sessionReset: Date().addingTimeInterval(7200), weeklyReset: Date().addingTimeInterval(86400), asOf: Date())
    let x = LimitData(session: 15, weekly: 30, sessionReset: Date().addingTimeInterval(7200), weeklyReset: Date().addingTimeInterval(86400), asOf: Date())
    UsageLogs.shared.useForPreview(ix)
    let sync = GitHubSync(transport: OFFLINE_SYNC_HTTP, keychain: OfflineSyncKeychain(), defaults: defaults,
                          remotePath: root + "/remote.json", machineId: "subscription-test")
    select(true, true)
    var remote = (try! JSONSerialization.jsonObject(with: Data(sync.selfTestFile().utf8))) as! [String: Any]
    var machine = remote["machine"] as! [String: Any]
    machine["id"] = "another-machine"; remote["machine"] = machine
    let remoteFile = String(decoding: try! JSONSerialization.data(withJSONObject: remote), as: UTF8.self)
    sync.setRemoteForPreview(GitHubSync.merge(["machine-another-machine.json": remoteFile], excluding: sync.machineId))
    select(false, true)
    let payload = (try! JSONSerialization.jsonObject(with: Data(sync.selfTestFile().utf8))) as! [String: Any]
    let days = payload["days"] as! [String: Any]
    check(days["claude"] == nil && days["codex"] != nil, "sync upload excludes disabled subscription")
    let merged = mergedUsageIndex(sync)
    check(merged.days["claude"] == nil && merged.days["codex"] != nil, "remote history cannot restore disabled subscription")
    check(!selectedLimits(c, product: "claude").present && advCards(c, x).map { $0.product } == ["codex"],
          "cached readings cannot restore disabled cards")
    check(!showMissingProduct(advCards(c, x)), "disabled Claude has no setup invitation")
    check(!fetchClaude().present, "disabled Claude returns before reading Keychain or API")
    select(true, false)
    check(!fetchCodex(live: true).present, "disabled Codex returns before reading credentials, logs or API")
    select(false, false)
    check(!UsageLogs.scan(&ix, home: root) && monitoringPaused() && advCards(c, x).isEmpty,
          "both subscriptions can be disabled")
    select(true, true)
    let enabledHeight = advancedHeight(c, x)
    select(false, true)
    check(advancedHeight(c, x) < enabledHeight, "single-subscription panel shrinks")
    SYNC_PREVIEW = SyncUIState()
    func save(_ context: CGContext, _ path: String) {
        let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dst, context.makeImage()!, nil)
        check(CGImageDestinationFinalize(dst), "preview " + path)
    }
    for lang in ["ru", "en"] {
        prefs["lang"] = lang
        for advanced in [false, true] {
            prefs["advanced"] = advanced; select(false, true)
            let h = settingsTotalHeight(AboutState())
            let ctx = bitmapContext(Int(PANEL_W * 2), Int(h * 2))!; ctx.scaleBy(x: 2, y: 2)
            let hits = drawSettings(ctx, size: CGSize(width: PANEL_W, height: h), about: AboutState())
            let toggles = hits.filter { $0.id.hasPrefix("monitor:") }
            check(toggles.count == 2 && !toggles[0].rect.intersects(toggles[1].rect)
                  && hits.allSatisfy { $0.rect.minY >= 0 && $0.rect.maxY <= h },
                  "\(lang) advanced=\(advanced): both toggles and all controls fit")
            save(ctx, "/tmp/ccl-subscriptions-settings-\(lang)-\(advanced).png")
            for bothOff in [false, true] {
                prefs["autoPoll"] = true
                select(false, !bothOff)
                let cl = selectedLimits(c, product: "claude"), cx = selectedLimits(x, product: "codex")
                let ph = mainPanelHeight(cl, cx)
                let pc = bitmapContext(Int(PANEL_W * 2), Int(ph * 2))!; pc.scaleBy(x: 2, y: 2)
                let phits = advanced
                    ? drawAdvanced(pc, size: CGSize(width: PANEL_W, height: ph), claude: cl, codex: cx, interval: POLL_DEFAULT, updated: nil, about: AboutState())
                    : drawPanel(pc, size: CGSize(width: PANEL_W, height: ph), claude: cl, codex: cx, interval: POLL_DEFAULT, updated: nil, about: AboutState())
                check(phits.filter { $0.id.hasPrefix("iv") }.map { $0.id } == ["iv900", "iv1800", "iv3600", "iv0"],
                      "\(lang) advanced=\(advanced): all fixed intervals and Auto are clickable")
                check(phits.contains { $0.id == "settings" } && !phits.contains { $0.id == "claudefix" || $0.id.contains("claude.ai") },
                      "\(lang) advanced=\(advanced) paused=\(bothOff): Settings reachable; no Claude links")
                save(pc, "/tmp/ccl-subscriptions-panel-\(lang)-\(advanced)-paused-\(bothOff).png")
            }
        }
    }
    // AppDelegate init reads only synthetic volatile interval/state. Never launch it,
    // call saveAutoStates (persistent defaults), scanActivity (real logs), or start timers.
    var startupClaude = AutoPollState(), startupCodex = AutoPollState()
    let runtimeNow = Date().timeIntervalSince1970
    startupClaude.interval = 14400; startupClaude.lastAttempt = runtimeNow - 400
    startupCodex.interval = 900; startupCodex.lastAttempt = runtimeNow - 400
    prefs["interval"] = 1800
    prefs["autoPollState"] = try! JSONEncoder().encode(["claude": startupClaude, "codex": startupCodex])
    prefs["autoPoll"] = true; prefs["lang"] = "ru"; select(true, true)
    let delegate = AppDelegate()
    _ = NSApplication.shared  // AppKit-only fixture panel; applicationDidFinishLaunching is never called.
    delegate.panelCtrl = PanelController()
    delegate.publishAutoIntervals()
    check(delegate.panelCtrl.view.autoIntervals == ["claude": 14400, "codex": 900]
          && delegate.panelCtrl.view.needsDisplay && delegate.interval == 1800,
          "startup restored states publish a repaint independently of manual interval")
    let oldCodex = delegate.autoStates["codex"]!
    delegate.panelCtrl.view.needsDisplay = false
    var activeClaude = delegate.autoStates["claude"]!
    check(activeClaude.localActivity([runtimeNow - 300, runtimeNow - 200, runtimeNow - 100], now: runtimeNow),
          "local fixture activity changes sleeping Claude")
    delegate.autoStates["claude"] = activeClaude
    delegate.publishAutoIntervals()
    var dueClaude = delegate.autoStates["claude"]!, dueCodex = delegate.autoStates["codex"]!
    check(!dueClaude.due(runtimeNow) && !dueCodex.due(runtimeNow),
          "synthetic local activity remains not-due at the fixed fixture clock")
    check(delegate.panelCtrl.view.autoIntervals == ["claude": 900, "codex": 900]
          && delegate.panelCtrl.view.needsDisplay && !delegate.fetchingLimits
          && delegate.autoStates["codex"]!.interval == oldCodex.interval,
          "local activity publishes a repaint without invoking any refresh path")
    // Swift not-due wiring is reviewed statically only: doRefresh uses the real clock
    // and could fetch after a long pause/clock jump. The observe->save and scanActivity
    // callbacks use persistent defaults/real logs. Linux tests mock the real runtime paths.
    var failedClaude = delegate.autoStates["claude"]!
    failedClaude.begin(runtimeNow)
    var badReading = reading(50, runtimeNow); badReading.apiFresh = false
    failedClaude.observe(badReading, now: runtimeNow)
    delegate.autoStates["claude"] = failedClaude
    delegate.publishAutoIntervals()
    check(delegate.panelCtrl.view.autoIntervals == ["claude": 1800, "codex": 900],
          "observed backoff publishes its own interval while Codex stays unchanged")
    let fixtureUpdated = Date(timeIntervalSince1970: 100000)
    for lang in ["ru", "en"] {
        prefs["lang"] = lang; select(true, true)
        let prefix = lang == "en" ? "updated " : "обновлено "
        let error = lang == "en" ? "backing off after an error" : "пауза после ошибки"
        delegate.panelCtrl.view.updated = fixtureUpdated
        let summary = delegate.autoSummary()
        check(summary.contains(prefix + clockText(fixtureUpdated))
              && summary.components(separatedBy: "\n").contains { $0.hasPrefix("Claude Code:") && $0.contains(error) }
              && !summary.components(separatedBy: "\n").contains { $0.hasPrefix("Codex:") && $0.contains(error) },
              "\(lang) tooltip keeps timestamp and product-specific error")
        delegate.panelCtrl.view.updated = nil
        check(!delegate.autoSummary().contains(prefix), "\(lang) tooltip omits missing timestamp")
        select(false, true)
        check(!delegate.autoSummary().contains("Claude Code:"), "\(lang) tooltip filters disabled subscription")
        select(true, true)
        for advanced in [false, true] {
            func footer(_ updated: Date?, intervals: [String: TimeInterval] = ["claude": 900, "codex": 14400]) -> (Data, [Hit]) {
                let ctx = bitmapContext(360, 40)!
                ctx.clear(CGRect(x: 0, y: 0, width: 360, height: 40))
                let hits = drawPollFooter(ctx, size: CGSize(width: 360, height: 40), top: 8,
                                          interval: 3600, updated: updated,
                                          autoIntervals: intervals, advanced: advanced)
                return (Data(bytes: ctx.data!, count: ctx.bytesPerRow * ctx.height), hits)
            }
            let (withTime, hits) = footer(fixtureUpdated)
            let (withoutTime, _) = footer(nil)
            check(withTime == withoutTime, "\(lang) advanced=\(advanced): actual Auto footer has no timestamp ink")
            for (id, x, w) in [("iv900", 16.0, 40.0), ("iv1800", 56, 40), ("iv3600", 96, 40), ("iv0", 136, 40), ("quit", 320, 24)] {
                check(hits.contains { $0.id == id && $0.rect == CGRect(x: x, y: 8, width: w, height: 24) },
                      "\(lang) advanced=\(advanced): \(id) footer hit geometry")
            }
            check(!hits.first { $0.id == "iv0" }!.rect.intersects(hits.first { $0.id == "quit" }!.rect),
                  "\(lang) advanced=\(advanced): Auto and power never overlap")
            prefs["autoPoll"] = false; select(true, true)
            let (manualTime, _) = footer(fixtureUpdated)
            let (manualNoTime, _) = footer(nil)
            check(manualTime != manualNoTime && pollSelected(3600, manual: 3600) && !pollSelected(0, manual: 3600),
                  "\(lang) advanced=\(advanced): manual keeps timestamp and selected fixed interval")
            check(!delegate.autoSummary().contains(prefix), "\(lang) manual tooltip retains prior timestamp behavior")
            prefs["autoPoll"] = true; select(true, true)
            for (fixture, ci, xi, claudeOn, codexOn, autoOn) in [
                ("different", 900.0, 14400.0, true, true, true), ("equal", 1800, 1800, true, true, true),
                ("backoff", 3600, 900, true, true, true), ("paused", 900, 14400, false, false, true),
                ("single-codex-15", 1800, 900, false, true, true), ("single-codex-30", 1800, 1800, false, true, true),
                ("single-codex-60", 1800, 3600, false, true, true), ("single-codex-240", 1800, 14400, false, true, true),
                ("manual-60", 900, 14400, true, true, false), ("long", 1800, 900, true, true, true)
            ] {
                prefs["advanced"] = advanced; prefs["autoPoll"] = autoOn; select(claudeOn, codexOn)
                let cl = selectedLimits(c, product: "claude"), cx = selectedLimits(x, product: "codex")
                let height = mainPanelHeight(cl, cx)
                func panelImage(_ intervals: [String: TimeInterval]) -> (CGContext, [Hit]) {
                    let ctx = bitmapContext(720, Int(height * 2))!; ctx.scaleBy(x: 2, y: 2)
                    let size = CGSize(width: PANEL_W, height: height)
                    let hits = advanced
                        ? drawAdvanced(ctx, size: size, claude: cl, codex: cx, interval: 3600,
                                       updated: fixtureUpdated, about: AboutState(), autoIntervals: intervals)
                        : drawPanel(ctx, size: size, claude: cl, codex: cx, interval: 3600,
                                    updated: fixtureUpdated, about: AboutState(), autoIntervals: intervals)
                    return (ctx, hits)
                }
                let (image, panelHits) = panelImage(["claude": ci, "codex": xi])
                // Full cards include live countdown/pace calculations. Compare the actual
                // shared footer in isolation; keep the full-panel image for visual QA.
                let (bytes, _) = footer(fixtureUpdated, intervals: ["claude": ci, "codex": xi])
                let (changedBytes, _) = footer(fixtureUpdated, intervals: ["claude": ci == 14400 ? 900 : 14400,
                                                                         "codex": xi == 14400 ? 900 : 14400])
                check(autoOn && (claudeOn || codexOn) ? bytes != changedBytes : bytes == changedBytes,
                      "\(lang) advanced=\(advanced) \(fixture): shared footer consumes only enabled Auto snapshot")
                let autoHit = panelHits.first { $0.id == "iv0" }!.rect
                let powerHit = panelHits.first { $0.id == "quit" }!.rect
                check(autoHit.minX == 136 && autoHit.width == 40 && powerHit.minX == 320
                      && !autoHit.intersects(powerHit) && autoHit.minY >= 0 && autoHit.maxY <= height,
                      "\(lang) advanced=\(advanced) \(fixture): full-panel footer bounds and fallback")
                save(image, "/tmp/ccl-auto-ui-\(fixture)-\(lang)-advanced-\(advanced).png")
            }
            prefs["autoPoll"] = true; select(true, true)
        }
    }
    // Auth-copy regressions (tester): synthetic LimitData and pure bitmap draw only.
    // Never call AppDelegate refresh/scan/timers or infer I/O safety from not-due.
    let authNow = Date()
    var authChecks = 0, authImages = 0
    func authCheck(_ ok: Bool, _ message: String) {
        authChecks += 1; check(ok, "Auth hints: " + message)
    }
    func authReading(_ fixture: String) -> LimitData {
        var d = LimitData(session: 31, weekly: 47, sessionReset: authNow.addingTimeInterval(7200),
                          weeklyReset: authNow.addingTimeInterval(86400), asOf: authNow.addingTimeInterval(-60))
        switch fixture {
        case "age":
            d.asOf = authNow.addingTimeInterval(-14401)
            d.sessionReset = authNow.addingTimeInterval(1800) // valid at observation; stale solely by age
        case "network": d.asOf = authNow.addingTimeInterval(-1800); d.error = "offline fixture"
        case "reset":
            d.asOf = authNow.addingTimeInterval(-7200)
            d.sessionReset = authNow.addingTimeInterval(-3600)
            d.weeklyReset = authNow.addingTimeInterval(-3600) // both observed windows have ended
        case "weekly-only", "historical", "session-reset", "poll-failed":
            d.asOf = authNow.addingTimeInterval(fixture == "historical" ? -14401 : -7200)
            d.session = nil; d.sessionReset = nil
            d.weekly = 41; d.weeklyReset = d.asOf!.addingTimeInterval(84 * 3600)
            if fixture == "session-reset" {
                d.session = 100; d.sessionReset = authNow.addingTimeInterval(-3600)
            }
            if fixture == "poll-failed" {
                d.pollFailed = true; d.nextPollAt = authNow.addingTimeInterval(900)
                // No error string: a fallback snapshot still carries the failed poll fact.
            }
        case "no-asof": d.asOf = nil
        case "empty": d.session = nil; d.weekly = nil; d.asOf = nil
        case "expired": d.auth = .expired; d.asOf = authNow.addingTimeInterval(-7200)
        case "logout": d.auth = .loggedOut; d.asOf = authNow.addingTimeInterval(-7200)
        case "read-error": d.auth = .keychainError; d.asOf = authNow.addingTimeInterval(-7200)
        case "read-error-empty": d.auth = .keychainError; d.session = nil; d.weekly = nil; d.asOf = nil
        default: break
        }
        return d
    }
    // Fixed observation/time inputs: age and reset are independent of live failure/auth.
    var boundary = authReading("age")
    boundary.asOf = authNow.addingTimeInterval(-14400)
    authCheck(!isStale(boundary, authNow), "exactly four hours remains fresh")
    authCheck(isStale(authReading("age"), authNow), "four hours plus one second is stale")
    var oneReset = authReading("reset")
    oneReset.weeklyReset = authNow.addingTimeInterval(86400)
    authCheck(metricIsStale(oneReset, metric: "session", now: authNow)
              && !metricIsStale(oneReset, metric: "weekly", now: authNow) && !isStale(oneReset, authNow),
              "ended session does not pause valid weekly window")
    authCheck(isStale(authReading("reset"), authNow), "both ended windows pause the card")
    let historical = authReading("age")
    authCheck(snapshotWindowPace(used: historical.weekly, reset: historical.weeklyReset,
                                windowH: 168, asOf: historical.asOf) != nil,
              "age-stale valid observation still supports timestamped historical pace")
    let codexTarget = "open:https://chatgpt.com/codex/cloud/settings/analytics#usage"
    let claudeTarget = "open:https://claude.ai/settings/usage"
    for lang in ["ru", "en"] {
        prefs["lang"] = lang; select(true, true)
        let authStates: [AuthState] = [.ok, .loggedOut, .expired, .keychainError]
        let badges = lang == "ru" ? ["данные устарели", "нет входа", "вход истёк", "нет доступа"]
                                  : ["stale data", "signed out", "sign-in expired", "read failed"]
        for (i, auth) in authStates.enumerated() {
            authCheck(limitAuthBadge(auth) == badges[i], "\(lang) classified badge \(i)")
            for product in ["claude", "codex"] {
                authCheck(limitCanFix(product: product, auth: auth) ==
                          (product == "claude" && (auth == .loggedOut || auth == .expired)),
                          "\(lang) \(product) recovery guard \(i)")
            }
        }
        let missingNotice = lang == "ru" ? "Нет свежих данных · темп не считаем" : "No fresh data · pace paused"
        authCheck(limitPausedNotice(asOf: nil) == missingNotice, "\(lang) missing timestamp is explicit")
        let missingRow = AdvRow(limit: nil, kind: .stale, credits: nil)
        authCheck(advVerdict(missingRow, asOf: nil) == missingNotice, "\(lang) stale row never invents Date()")
        for advanced in [false, true] {
            for both in [false, true] {
                let fixtures = [("codex", "age"), ("codex", "network"), ("codex", "reset"),
                                ("codex", "no-asof"), ("codex", "empty"), ("claude", "expired"),
                                ("claude", "logout"), ("claude", "read-error"), ("claude", "age"),
                                ("claude", "read-error-empty"), ("codex", "both-expired"), ("codex", "both-logout"),
                                ("codex", "weekly-only"), ("codex", "historical"),
                                ("codex", "session-reset"), ("codex", "poll-failed")]
                for (product, fixture) in fixtures {
                    let combined = fixture.hasPrefix("both-")
                    if combined && !both { continue }
                    prefs["advanced"] = advanced; prefs["autoPoll"] = false
                    select(both || product == "claude", both || product == "codex")
                    let sample = authReading(combined ? "age" : fixture)
                    let companion = authReading(combined ? String(fixture.dropFirst(5)) : "fresh")
                    let cl = selectedLimits(product == "claude" ? sample : companion, product: "claude")
                    let cx = selectedLimits(product == "codex" ? sample : authReading("fresh"), product: "codex")
                    let cachedBeforeDraw = [String(reflecting: cl), String(reflecting: cx)]
                    let cards = advCards(cl, cx)
                    let card = cards.first { $0.product == product }!
                    let recover = product == "claude" && (fixture == "expired" || fixture == "logout")
                    let label = "\(lang) advanced=\(advanced) both=\(both) \(product)/\(fixture)"
                    let failedFresh = fixture == "network" || fixture == "poll-failed"
                    let snapshotFresh = failedFresh || fixture == "weekly-only" || fixture == "session-reset"
                    authCheck(card.paused == !snapshotFresh && card.noticeHeight == (recover || failedFresh ? 38 : 19),
                              label + " freshness, recovery and failure have independent notice height")
                    if failedFresh {
                        authCheck(card.rows.filter { $0.limit != nil }.allSatisfy { $0.kind == .full },
                                  label + " fresh failed fetch retains snapshot pace rows")
                    }
                    if ["weekly-only", "historical", "session-reset", "poll-failed"].contains(fixture) {
                        let weeklyRow = card.rows.first { $0.limit?.id == "weekly" }!
                        let pace = weeklyRow.limit?.pace
                        authCheck(weeklyRow.kind == .full && pace?.used == 41 && pace?.planPct == 50
                                  && pace?.projectedPct == 82 && pace?.elapsedH == 84,
                                  label + " 41% at half-week projects 82% from asOf, independent of current age")
                        authCheck(limitSnapshotNotice(sample).hasPrefix(
                            lang == "ru" ? "Темп по снимку от " : "Pace from snapshot at "),
                                  label + " historical/current forecast retains explicit timestamp")
                        if fixture == "session-reset" {
                            authCheck(card.rows.first { $0.limit?.id == "session" }?.kind == .stale
                                      && metricIsStale(sample, metric: "session", now: authNow)
                                      && !metricIsStale(sample, metric: "weekly", now: authNow),
                                      label + " 100% ended session is muted without muting the week")
                        } else {
                            authCheck(card.rows.allSatisfy { $0.limit?.id != "session" } && sample.session == nil,
                                      label + " missing session never blocks weekly forecast")
                        }
                    }
                    let nextClock = DateFormatter(); nextClock.dateFormat = "HH:mm"
                    let failedAction = fixture == "poll-failed"
                        ? (lang == "ru" ? "Сбой · повтор в " : "Failed · retry at ") + nextClock.string(from: sample.nextPollAt!)
                        : (lang == "ru" ? "Сбой · повтор по расписанию" : "Failed · scheduled retry")
                    if fixture == "poll-failed" {
                        authCheck(sample.error == nil && sample.pollFailed && sample.auth == .ok
                                  && limitRetryNotice(sample) == (lang == "ru" ? "повтор в " : "retry at ")
                                      + nextClock.string(from: sample.nextPollAt!),
                                  label + " failed state without invented reason includes next attempt")
                    }
                    let copy = limitSimpleStaleCopy(sample, product: product)
                    let expectedAction = recover ? (lang == "ru" ? "Вход устарел · Как починить?" : "Sign-in expired · How to fix?")
                        : (failedFresh ? failedAction
                           : (sample.asOf == nil ? (lang == "ru" ? "темп не считаем" : "pace paused")
                                                : (lang == "ru" ? "обновите данные" : "refresh data")))
                    authCheck(copy.action == expectedAction, label + " recovery versus refresh copy")
                    if sample.asOf == nil {
                        authCheck(copy.snapshot == (lang == "ru" ? "Нет свежих данных" : "No fresh data")
                                  && limitPausedNotice(asOf: sample.asOf) == missingNotice,
                                  label + " nil date stays nil")
                    }
                    if sample.session == nil && sample.weekly == nil {
                        authCheck(pctText(sample.session) == "—" && pctText(sample.weekly) == "—",
                                  label + " missing percentages are dashes, never invented 0%")
                    }
                    if product == "codex" {
                        authCheck(sample.auth == .ok && isStale(sample, authNow) == !snapshotFresh
                                  && (snapshotFresh && !failedFresh || limitDataBadge(sample) == (failedFresh
                                      ? (lang == "ru" ? "сбой обновления" : "update failed")
                                      : (lang == "ru" ? "данные устарели" : "stale data"))),
                                  label + " Codex freshness/failure never invents expired auth")
                    }
                    let height = mainPanelHeight(cl, cx)
                    let image = bitmapContext(720, Int(height * 2))!; image.scaleBy(x: 2, y: 2)
                    let size = CGSize(width: PANEL_W, height: height)
                    let hits = advanced
                        ? drawAdvanced(image, size: size, claude: cl, codex: cx, interval: 1800, updated: nil, about: AboutState())
                        : drawPanel(image, size: size, claude: cl, codex: cx, interval: 1800, updated: nil, about: AboutState())
                    let afterDraw = advCards(cl, cx).first { $0.product == product }!
                    authCheck([String(reflecting: cl), String(reflecting: cx)] == cachedBeforeDraw
                              && afterDraw.data.session == sample.session && afterDraw.data.weekly == sample.weekly
                              && afterDraw.data.asOf == sample.asOf && afterDraw.data.auth == sample.auth,
                              label + " cached model values retained after actual draw")
                    authCheck(hits.contains { $0.id == "claudefix" } == (recover || combined),
                              label + " actual draw recovery target")
                    if product == "codex" || both {
                        authCheck(hits.contains { $0.id == codexTarget }, label + " actual Codex URL retained")
                    }
                    if product == "claude" && !recover || product == "codex" && both && !combined {
                        authCheck(hits.contains { $0.id == claudeTarget }, label + " ordinary Claude URL retained")
                    }
                    if combined {
                        let fixRect = hits.first { $0.id == "claudefix" }!.rect
                        let codexRect = hits.first { $0.id == codexTarget }!.rect
                        if advanced {
                            let claudeCard = cards.first { $0.product == "claude" }!
                            let boundary = height - (58 + claudeCard.height + 5)
                            authCheck(fixRect.minY > boundary && codexRect.midY <= boundary
                                      && claudeCard.noticeHeight == 38,
                                      label + " recovery hit belongs only to Claude card")
                        } else {
                            authCheck(fixRect.maxX <= PANEL_W / 2 && codexRect.minX >= PANEL_W / 2,
                                      label + " recovery hit belongs only to Claude card")
                        }
                        authCheck(limitSimpleStaleCopy(companion, product: "claude").action ==
                                  (lang == "ru" ? "Вход устарел · Как починить?" : "Sign-in expired · How to fix?"),
                                  label + " both paused cards keep separate product copy")
                    }
                    authCheck(hits.allSatisfy { $0.rect.minY >= 0 && $0.rect.maxY <= height },
                              label + " actual hit bounds")
                    // Keep full panels as PNG for QA; do not compare time-dependent card bitmaps.
                    save(image, "/tmp/ccl-auth-hints-\(product)-\(fixture)-\(lang)-advanced-\(advanced)-both-\(both).png")
                    authImages += 1
                }
            }
        }
        select(true, true)
        authCheck(advCards(authReading("fresh"), authReading("fresh")).allSatisfy {
            !$0.paused && $0.noticeHeight == 19 && limitSnapshotNotice($0.data).hasPrefix(
                lang == "ru" ? "Темп по снимку от " : "Pace from snapshot at ")
        }, "\(lang) fresh cards have one timestamped snapshot notice")
    }
    authCheck(authImages == 120, "120 RU/EN Simple/Advanced actual bitmap fixtures, including 32 FRESH-4H panels")
    print("Auth hint fixtures: \(authChecks) checks, \(authImages) PNG")
    // Actual Settings/main auth draw matrix. History remains collapsed because
    // expanded draw uses the production shared sync; the explicit merge regression
    // above covers synthetic history through its injected GitHubSync instance.
    var githubImages = 0
    let cachedIndexEncoder = JSONEncoder(); cachedIndexEncoder.outputFormatting = [.sortedKeys]
    for lang in ["ru", "en"] {
        let en = lang == "en"
        prefs["lang"] = lang; prefs["advHistExpanded"] = false
        let cases: [(String, SyncUIState, String?)] = [
            ("healthy", SyncUIState(phase: .on, authState: "healthy", login: "fixture-account"), nil),
            ("legacy-healthy", SyncUIState(phase: .on, login: "fixture-legacy"), nil),
            ("renewing", SyncUIState(phase: .on, authState: "renewing", authReason: "renewing", keychainItemLeft: true, login: "fixture-account"),
             en ? "Renewing GitHub sign-in automatically…" : "Автоматически продлеваем вход в GitHub…"),
            ("storage-locked", SyncUIState(phase: .on, authState: "temporarilyUnavailable", authReason: "locked", keychainItemLeft: true, login: "fixture-account"),
             en ? "Unlock Keychain; sign-in will recover automatically." : "Разблокируйте Связку ключей; вход восстановится автоматически."),
            ("identity-pending", SyncUIState(phase: .on, authState: "temporarilyUnavailable", authReason: "identity_unavailable", keychainItemLeft: true, login: "fixture-account"),
             en ? "Sign-in is saved; waiting for GitHub verification." : "Вход сохранён; ждём проверки GitHub."),
            ("cleanup-pending", SyncUIState(phase: .off, authState: "signedOut", authReason: "cleanup_pending", keychainItemLeft: true),
             en ? "Signed out here; secure-storage cleanup is pending. Retrying automatically." : "Вход на этом компьютере отключён; очистка хранилища ещё не завершена. Повторим автоматически."),
            ("terminal", SyncUIState(phase: .revoked, authState: "actionRequired", authReason: "lost_result", keychainItemLeft: true, login: "fixture-account"),
             en ? "Couldn't recover the renewal result. Sign in again." : "Не удалось восстановить результат продления. Войдите заново.")
        ]
        for (name, inputState, expectedCopy) in cases {
            var state = inputState
            if state.phase == .off { state.error = expectedCopy }
            else { state.lastError = expectedCopy }
            SYNC_PREVIEW = state
            check(syncWarning(state) == expectedCopy, "GitHub \(lang) \(name) exact truthful localized notice")
            for advanced in [false, true] {
                prefs["advanced"] = advanced; select(true, true)
                let beforePreferences = defaults.dictionaryRepresentation() as NSDictionary
                let beforeIndex = try! cachedIndexEncoder.encode(UsageLogs.shared.snapshot())
                let size = CGSize(width: PANEL_W, height: mainPanelHeight(c, x))
                let image = bitmapContext(Int(size.width * 2), Int(size.height * 2))!; image.scaleBy(x: 2, y: 2)
                let hits = advanced
                    ? drawAdvanced(image, size: size, claude: c, codex: x, interval: 1800, updated: nil, about: AboutState())
                    : drawPanel(image, size: size, claude: c, codex: x, interval: 1800, updated: nil, about: AboutState())
                check(hits.contains { $0.id == "settings" } && hits.allSatisfy { $0.rect.minY >= 0 && $0.rect.maxY <= size.height },
                      "GitHub \(lang) \(name) actual main controls fit and Settings reachable")
                if advanced {
                    let sh = settingsTotalHeight(AboutState())
                    let settingsImage = bitmapContext(Int(PANEL_W * 2), Int(sh * 2))!; settingsImage.scaleBy(x: 2, y: 2)
                    let settingsHits = drawSettings(settingsImage, size: CGSize(width: PANEL_W, height: sh), about: AboutState())
                    let expectLogin = state.phase == .off || state.phase == .revoked
                    check(settingsHits.filter { $0.id == "sync:login" }.count == (expectLogin ? 1 : 0),
                          "GitHub \(lang) \(name) actual login affordance matches state")
                    check(settingsHits.contains { $0.id == "sync:logout" }, "GitHub \(lang) \(name) actual local cleanup control")
                    check(settingsHits.allSatisfy { $0.rect.minY >= 0 && $0.rect.maxY <= sh }, "GitHub settings control bounds")
                    save(settingsImage, "/tmp/ccl-github-auth-settings-\(name)-\(lang).png"); githubImages += 1
                }
                check(beforePreferences.isEqual(to: defaults.dictionaryRepresentation())
                      && beforeIndex == (try! cachedIndexEncoder.encode(UsageLogs.shared.snapshot())), "GitHub actual draw leaves preferences and cached usage unchanged")
                save(image, "/tmp/ccl-github-auth-main-\(name)-\(lang)-advanced-\(advanced).png"); githubImages += 1
            }
        }
    }
    check(githubImages == 42, "42 isolated RU/EN GitHub auth actual Settings/main PNG fixtures")
    SYNC_PREVIEW = SyncUIState()
    prefs["autoPoll"] = true; select(true, true)
    delegate.panelCtrl.panel.close()
    try! fm.removeItem(atPath: root)
    check(pollSelected(0, manual: 1800) && !pollSelected(1800, manual: 1800), "Auto button selected independently of saved fixed interval")
    print("Subscription selection and adaptive polling selftest passed")
    exit(0)
}

if CommandLine.arguments.contains("--sync-selftest") {
    // Offline (lesson 006): no GitHub or real Keychain/defaults. Normal startup creates
    // ~/.claude-limits-monitor earlier, before CLI dispatch; that mkdir is skipped for this
    // mode. The selftest reads/writes nothing there. CLI transcripts rebuild only RAM.
    let selfTestDefaults = installMemorySelfTestDefaults()
    let selfTestRoot = NSTemporaryDirectory() + "ccl-sync-test-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: selfTestRoot, withIntermediateDirectories: true)
    func check(_ ok: Bool, _ label: String) {
        print("\(ok ? "OK" : "FAIL") \(label)")
        if !ok { selfTestDefaults.clear(); exit(1) }
    }
    // Native writer permit protocol: pure data parsing only, never spawn helper.
    let permitGeneration = UUID().uuidString.lowercased(), permitOperation = UUID().uuidString.lowercased()
    let permitEpoch = UUID().uuidString.lowercased()
    for phase in [GitHubAuthWriterPhase.prepared, .rpcStarted, .completed, .notStarted] {
        let record = GitHubAuthWriterRecord(generation: permitGeneration, operation: permitOperation, phase: phase,
            epoch: permitEpoch, status: phase == .completed ? 0 : nil)
        let parsed = githubAuthWriterRecord(try! JSONEncoder().encode(record), generation: permitGeneration)
        check(parsed != nil, "pure writer protocol parses \(phase.rawValue)")
        check(githubAuthWriterPermitAllows(record, generation: permitGeneration, operation: permitOperation, epoch: permitEpoch) == (phase == .prepared),
              "only exact prepared permit may start native RPC")
        check(!githubAuthWriterPermitAllows(record, generation: permitGeneration, operation: UUID().uuidString.lowercased(), epoch: permitEpoch), "superseded operation cannot start RPC")
        check(!githubAuthWriterPermitAllows(record, generation: UUID().uuidString.lowercased(), operation: permitOperation, epoch: permitEpoch), "permit generation binding")
        check(!githubAuthWriterPermitAllows(record, generation: permitGeneration, operation: permitOperation, epoch: UUID().uuidString.lowercased()), "permit account epoch binding")
    }
    for payload in ["{}", "{broken", "{\"schema\":true}", "{\"completed\":true,\"status\":0}"] {
        check(githubAuthWriterRecord(Data(payload.utf8), generation: permitGeneration) == nil, "corrupt/old permit cannot prove no-send")
    }
    let sync = GitHubSync(transport: OFFLINE_SYNC_HTTP, keychain: OfflineSyncKeychain(), defaults: selfTestDefaults,
                          remotePath: selfTestRoot + "/remote.json", machineId: "selftest-self")
    // Explicit temporary home with synthetic logs; no default-HOME scan/load.
    let syntheticHome = selfTestRoot + "/home"
    let fixtureStamp = ISO8601DateFormatter().string(from: Date())
    let fixtureClaude = syntheticHome + "/.claude/projects/fixture/session.jsonl"
    let fixtureCodex = syntheticHome + "/.codex/sessions/fixture/rollout.jsonl"
    for path in [fixtureClaude, fixtureCodex] {
        try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    }
    let fixtureClaudeLine = "{\"timestamp\":\"\(fixtureStamp)\",\"type\":\"assistant\",\"message\":{\"id\":\"fixture-message\",\"model\":\"fixture-model\",\"usage\":{\"input_tokens\":100,\"output_tokens\":20}}}\n"
    let fixtureCodexLine = "{\"timestamp\":\"\(fixtureStamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"input_tokens\":50,\"output_tokens\":10}}}}\n"
    try! fixtureClaudeLine.write(toFile: fixtureClaude, atomically: true, encoding: .utf8)
    try! fixtureCodexLine.write(toFile: fixtureCodex, atomically: true, encoding: .utf8)
    var syntheticIndex = UsageIndex()
    check(UsageLogs.scan(&syntheticIndex, home: syntheticHome, isEnabled: { _ in true }), "synthetic temporary logs indexed")
    UsageLogs.shared.useForPreview(syntheticIndex)
    let mine = sync.selfTestFile()
    // Pretend the same data came from another machine: swap the id, keep everything else.
    guard var obj = (try? JSONSerialization.jsonObject(with: Data(mine.utf8))) as? [String: Any],
          var m = obj["machine"] as? [String: Any] else { check(false, "own file unparsable"); exit(1) }
    m["id"] = "00000000-test"; m["name"] = "astra-test"; m["os"] = "Astra Linux SE"; obj["machine"] = m
    let other = String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
    let stale = other.replacingOccurrences(of: "00000000-test", with: "11111111-old")
        .replacingOccurrences(of: "\"updated\":\"", with: "\"updated\":\"2020-01-01T00:00:00Z\",\"x\":\"")
    let cache = GitHubSync.merge(["machine-00000000-test.json": other, "machine-\(sync.machineId).json": mine, "machine-11111111-old.json": stale, "machine-bad.json": "{"],
                                 excluding: sync.machineId)
    check(cache.machines.count == 1 && cache.machines.first?.id == "00000000-test",
          "machines merged: \(cache.machines.map { $0.name })")
    sync.setRemoteForPreview(cache)
    for p in ["claude", "codex"] {
        let local = dailyUsage(p, days: 7, index: UsageLogs.shared.snapshot()).reduce(0) { $0 + $1.turns }
        let merged = dailyUsage(p, days: 7, index: mergedUsageIndex(sync)).reduce(0) { $0 + $1.turns }
        check(merged == 2 * local, "\(p): turns 7d local=\(local) merged=\(merged) (doubled)")
    }
    print("OK file bytes:", mine.utf8.count, "machine id:", sync.machineId.prefix(8) + "…")

    for (statuses, shouldRevoke) in [([401, 401, 200], false), ([401, 401, 401], true)] {
        selfTestDefaults.clear()
        selfTestDefaults.set("selftest-login", forKey: "syncLogin")
        selfTestDefaults.set("selftest-gist", forKey: "syncGistId")
        selfTestDefaults.set(Date(), forKey: "syncDiscoveredAt")
        let token = "selftest-mem"
        let keychain = MemorySyncKeychain(token: token)
        var replies = Array(zip(["/gists/selftest-gist", "/user", "/user"], statuses))
        let scripted: SyncHTTP = { url, method, headers, _, _ in
            check(!replies.isEmpty, "scripted HTTP has a queued response")
            let (path, status) = replies.removeFirst()
            check(url == "https://api.github.com" + path && method == "GET" && headers["Authorization"] == "Bearer " + token,
                  "scripted GET \(path) -> \(status)")
            let data = status == 200 ? Data("{\"login\":\"selftest-login\"}".utf8) : nil
            return (status, data, nil, [:])
        }
        let subject = GitHubSync(transport: scripted, keychain: keychain, defaults: selfTestDefaults,
                                 remotePath: selfTestRoot + "/unused-remote.json",
                                 machineId: "selftest-self", revokeRecheckDelay: 0)
        subject.syncSynchronously()
        let tokenMatches: Bool
        switch keychain.read() {
        case .token(let stored): tokenMatches = !shouldRevoke && stored == token
        case .missing: tokenMatches = shouldRevoke
        default: tokenMatches = false
        }
        check(replies.isEmpty && tokenMatches && selfTestDefaults.bool(forKey: "syncRevoked") == shouldRevoke
              && subject.ui.phase == (shouldRevoke ? .revoked : .on),
              "401 -> 401 -> \(statuses[2]): \(shouldRevoke ? "revoked, token deleted" : "not revoked, token retained")")
        selfTestDefaults.clear()
    }

    selfTestDefaults.clear()
    let now = Date(), day = dayKey(now), fractionalISO = ISO8601DateFormatter()
    fractionalISO.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var oversized: [String: String] = [:]
    for id in ["selftest-large-1", "selftest-large-2"] {
        let file: [String: Any] = ["schema": 1, "machine": ["id": id, "name": id, "os": "selftest"],
                                   "updated": fractionalISO.string(from: now),
                                   "days": ["claude": [day: ["selftest-model": ["input": Int.max]]]]]
        guard let data = try? JSONSerialization.data(withJSONObject: file) else {
            check(false, "A2 fixture serialization"); exit(1)
        }
        oversized["machine-\(id).json"] = String(decoding: data, as: UTF8.self)
    }
    let large = GitHubSync.merge(oversized, excluding: "selftest-self", now: now)
    let sum = large.days["claude"]?[day]?["selftest-model"]?.input ?? 0
    check(large.machines.count == 2 && (0...1_000_000_000_000_000).contains(sum),
          "A2 two Int.max fields: merge survived, sum=\(sum) <= 1e15")
    selfTestDefaults.clear()

    // ---- Regression cases for the 401 / token-boundary / merge fix (tester, 2026-09-30).
    // Each prints OK/FAIL and keeps going; the exit code is non-zero if any FAIL.
    var failures = 0
    func expect(_ ok: Bool, _ label: String) {
        print("\(ok ? "OK" : "FAIL") \(label)")
        if !ok { failures += 1 }
    }
    let api = "https://api.github.com"
    let gistURL = api + "/gists/selftest-gist"
    let rawURL = "https://gist.githubusercontent.com/u/selftest-gist/raw/abc/machine-aa.json"
    let tokA = "st-tok-a", tokB = "st-tok-b", tokNew = "st-tok-new"
    let remoteFile = selfTestRoot + "/remote-cases.json"
    func json(_ obj: Any) -> Data { (try? JSONSerialization.data(withJSONObject: obj)) ?? Data() }
    func reply(_ status: Int, _ obj: Any? = nil, _ headers: [String: String] = [:]) -> SyncHTTPResult {
        (status, obj.map(json), nil, headers)
    }
    func freshDefaults(gist: String? = "selftest-gist") {
        selfTestDefaults.clear()
        selfTestDefaults.set("selftest-login", forKey: "syncLogin")
        if let g = gist {
            selfTestDefaults.set(g, forKey: "syncGistId"); selfTestDefaults.set(Date(), forKey: "syncDiscoveredAt")
        }
    }
    func makeSync(_ http: SelfTestHTTP, _ store: SelfTestKeychainStore) -> GitHubSync {
        GitHubSync(transport: http.transport, keychain: ScriptedSyncKeychain(store: store), defaults: selfTestDefaults,
                   remotePath: remoteFile, machineId: "selftest-self", revokeRecheckDelay: 0)
    }
    func gistBody(_ id: String = "selftest-gist", pub: Any? = false, extra: [String: Any] = [:]) -> [String: Any] {
        var files: [String: Any] = [SYNC_MANIFEST: ["content": "{}"], "machine-selftest-self.json": ["content": "{}"]]
        for (k, v) in extra { files[k] = v }
        var g: [String: Any] = ["id": id, "created_at": "2026-01-01T00:00:00Z", "files": files]
        if let p = pub { g["public"] = p }
        return g
    }
    func hasAuth(_ c: SelfTestHTTP.Call) -> Bool { c.headers.keys.contains { $0.lowercased() == "authorization" } }
    func paths(_ http: SelfTestHTTP) -> [String] { http.calls.map { $0.method + " " + $0.url.replacingOccurrences(of: api, with: "") } }
    func waitUntil(_ seconds: Double, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if cond() { return true }; Thread.sleep(forTimeInterval: 0.02) }
        return cond()
    }

    // 1. 401 -> 401 -> 403/429/5xx/0: token kept, lastError, backoff only on rate limits.
    let now0 = Date().timeIntervalSince1970
    let thirds: [(String, SyncHTTPResult, Bool)] = [
        ("403", reply(403), false), ("403 x-ratelimit", reply(403, nil, ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": String(Int(now0 + 600))]), true),
        ("429", reply(429, nil, ["Retry-After": "120"]), true), ("500", reply(500), false), ("503", reply(503), false),
        ("0", (0, nil, "offline", [:]), false)]
    for (label, third, limited) in thirds {
        freshDefaults()
        let store = SelfTestKeychainStore(tokA)
        var users = [reply(401), third]
        let http = SelfTestHTTP { c in
            if c.url == gistURL { return reply(401) }
            if c.url == api + "/user", !users.isEmpty { return users.removeFirst() }
            return (599, nil, "unexpected \(c.url)", [:])
        }
        let s = makeSync(http, store)
        s.syncSynchronously()
        let err = s.ui.lastError ?? ""
        expect(paths(http) == ["GET /gists/selftest-gist", "GET /user", "GET /user"] && store.token == tokA && store.deletes == 0
               && !selfTestDefaults.bool(forKey: "syncRevoked") && s.ui.phase == .on && err.contains("проверка входа не прошла"),
               "M1 401 -> 401 -> \(label): token kept, lastError «\(err)»")
        if label == "403" { expect(err.contains("доступ запрещён (403)"), "M1 403 without limit headers = access error") }
        let paused = s.selfTestBackoffUntil > Date().addingTimeInterval(60)
        expect(paused == limited, "M1 \(label): backoff \(limited ? "applied" : "not applied")")
        if limited {
            http.reset(); s.syncSynchronously()
            expect(http.calls.isEmpty, "M1 \(label): next cycle skipped during backoff")
        }
    }

    // 2. 401 -> 401 -> 401 but the Keychain now holds another token: no revocation.
    do {
        freshDefaults()
        let store = SelfTestKeychainStore(tokA)
        var n = 0
        let http = SelfTestHTTP { c in
            n += 1
            if n == 3 { store.token = tokB }       // a new sign-in landed during the recheck
            return reply(401)
        }
        let s = makeSync(http, store)
        s.syncSynchronously()
        expect(http.calls.count == 3 && http.calls.allSatisfy { $0.headers["Authorization"] == "Bearer " + tokA },
               "M2 three 401 with the captured token")
        expect(!selfTestDefaults.bool(forKey: "syncRevoked") && s.ui.phase == .on && store.token == tokB && store.deletes == 0,
               "M2 Keychain holds another token -> not revoked, new token kept")
        expect((s.ui.lastError ?? "").contains("изменился"), "M2 lastError says the sign-in changed: \(s.ui.lastError ?? "nil")")
    }

    // 3. Keychain times out at revocation: flag set, token stays, background paused, sign-in/out work.
    do {
        freshDefaults()
        let store = SelfTestKeychainStore(tokA)
        store.reads = [.token(tokA), .timedOut]
        var phase = "cycle"
        let http = SelfTestHTTP { c in
            if phase == "cycle" { return reply(401) }
            switch c.url {
            case "https://github.com/login/device/code":
                return reply(200, ["device_code": "dc", "user_code": "UC-1", "interval": 0, "expires_in": 60])
            case "https://github.com/login/oauth/access_token": return reply(200, ["access_token": tokNew])
            case api + "/user": return reply(200, ["login": "selftest-login"])
            default: return reply(403)
            }
        }
        let s = makeSync(http, store)
        s.syncSynchronously()
        expect(selfTestDefaults.bool(forKey: "syncRevoked") && s.ui.phase == .revoked && store.token == tokA && store.deletes == 0,
               "M3 Keychain .timedOut at revocation: flag set, token left in place")
        expect((s.ui.lastError ?? "").contains("Связка ключей не ответила"), "M3 lastError names the Keychain timeout: \(s.ui.lastError ?? "nil")")
        http.reset(); let reads = store.readCount
        s.syncSynchronously()
        expect(http.calls.isEmpty && store.readCount == reads, "M3 background cycle paused (no HTTP, no Keychain read)")
        phase = "login"
        s.startLogin()
        let loggedIn = waitUntil(5) { s.ui.phase == .on && s.ui.login == "selftest-login" }
        expect(loggedIn && store.token == tokNew && store.writes == 1 && !selfTestDefaults.bool(forKey: "syncRevoked"),
               "M3 sign-in works despite the Keychain backoff")
        _ = waitUntil(5) { http.calls.contains { $0.url.hasPrefix(api + "/gists") } }
        Thread.sleep(forTimeInterval: 0.2)
        s.logout()
        let out = waitUntil(5) { selfTestDefaults.string(forKey: "syncLogin") == nil && s.ui.phase == .off }
        expect(out && store.deletes == 1 && store.token == nil, "M3 sign-out works despite the Keychain backoff")
    }

    // 4. Token boundary: Bearer only to https://api.github.com; raw_url without Authorization.
    do {
        let rejected = ["https://evil.example/user", "https://api.github.com@evil.example/user",
                        "https://evil.example@api.github.com/user", "https://user:pw@api.github.com/user",
                        "https://api.github.com:8443/user", "https://api.github.com:80/user",
                        "https://api.github.com%2eevil.example/user", "https://api%2egithub.com/user",
                        "https://api.github.com./user", "https://api.github.com.evil.example/user",
                        "https://\u{0430}pi.github.com/user", "https://xn--pi-7kc.github.com/user",
                        "http://api.github.com/user", "//evil.example/user", "https://api.github.com /user",
                        "ftp://api.github.com/user"]
        let http = SelfTestHTTP { _ in reply(200, [String: Any]()) }
        let s = makeSync(http, SelfTestKeychainStore(tokA))
        for url in rejected {
            let status = s.selfTestGHStatus(url, token: tokA)
            expect(!syncAPIOrigin(url) && status == 0 && http.calls.isEmpty, "M4 rejected, not sent: \(url)")
            http.reset()
        }
        for url in ["/user", api + "/user", api + ":443/user"] {
            _ = s.selfTestGHStatus(url, token: tokA)
            let sent = http.calls.last
            expect(http.calls.count == 1 && sent?.headers["Authorization"] == "Bearer " + tokA
                   && (sent?.url.hasPrefix(api) ?? false), "M4 allowed with Bearer: \(url)")
            http.reset()
        }
        let guarded = syncHTTP("https://127.0.0.1:9/x", "GET", ["Authorization": "Bearer st"], nil, 2)
        expect(guarded.status == 0 && guarded.err == "GitHub API origin required", "M4 syncHTTP refuses Authorization off the API origin")

        freshDefaults()
        let truncated: [String: Any] = ["machine-aa.json": ["truncated": true, "raw_url": rawURL, "content": ""]]
        let file = "{\"schema\":1,\"machine\":{\"id\":\"aa\",\"name\":\"pc-aa\",\"os\":\"T\"},\"days\":{}}"
        let rawHTTP = SelfTestHTTP { c in
            if c.url == gistURL && c.method == "GET" { return reply(200, gistBody(extra: truncated)) }
            if c.url == gistURL && c.method == "PATCH" { return reply(200, [String: Any]()) }
            if c.url == rawURL { return (200, Data(file.utf8), nil, [:]) }
            return reply(599)
        }
        let rs = makeSync(rawHTTP, SelfTestKeychainStore(tokA))
        rs.syncSynchronously()
        let raw = rawHTTP.calls.first { $0.url == rawURL }
        expect(raw != nil && !hasAuth(raw!) && rs.ui.lastError == nil && rs.ui.machines.contains { $0.name == "pc-aa" },
               "M4 raw_url fetched without Authorization, file merged")

        freshDefaults()
        let redirect = SelfTestHTTP { _ in reply(302, nil, ["Location": "https://evil.example/"]) }
        let rd = makeSync(redirect, SelfTestKeychainStore(tokA))
        rd.syncSynchronously()
        expect(redirect.calls.count == 1 && (rd.ui.lastError ?? "").contains("302"), "M4 302 on an authorized request ends the cycle")
    }

    // 5. raw_url 200 with an empty / invalid UTF-8 body (and other raw errors): cycle fails, last success kept.
    do {
        let okAt = Date(timeIntervalSince1970: 1_790_000_000)
        let sentinel = Data("{\"machines\":[],\"days\":{}}".utf8)
        let truncated: [String: Any] = ["machine-aa.json": ["truncated": true, "raw_url": rawURL]]
        let cases: [(String, SyncHTTPResult, String)] = [
            ("200 empty", (200, Data(), nil, [:]), "Пустой или нечитаемый"),
            ("200 nil body", (200, nil, nil, [:]), "Пустой или нечитаемый"),
            ("200 invalid UTF-8", (200, Data([0xff, 0xfe, 0xc3, 0x28]), nil, [:]), "Пустой или нечитаемый"),
            ("401", reply(401), "GET raw_url"), ("403", reply(403), "GET raw_url"), ("500", reply(500), "GET raw_url")]
        for (label, rawReply, text) in cases {
            freshDefaults()
            selfTestDefaults.set(okAt, forKey: "syncLastOkAt")
            try? sentinel.write(to: URL(fileURLWithPath: remoteFile))
            let http = SelfTestHTTP { c in
                if c.url == gistURL && c.method == "GET" { return reply(200, gistBody(extra: truncated)) }
                if c.url == gistURL && c.method == "PATCH" { return reply(200, [String: Any]()) }
                if c.url == rawURL { return rawReply }
                return reply(599)
            }
            let s = makeSync(http, SelfTestKeychainStore(tokA))
            s.syncSynchronously()
            let kept = (selfTestDefaults.object(forKey: "syncLastOkAt") as? Date) == okAt
            let remoteKept = (try? Data(contentsOf: URL(fileURLWithPath: remoteFile))) == sentinel
            expect(kept && remoteKept && (s.ui.lastError ?? "").contains(text) && !http.calls.contains { $0.url == api + "/user" }
                   && !selfTestDefaults.bool(forKey: "syncRevoked"),
                   "M5 raw_url \(label): cycle failed, syncLastOkAt and cache kept, no /user check")
        }
    }

    // 6. Merge of hostile files: bad records/files dropped, the rest merged, no trap.
    do {
        let now = Date(), day = dayKey(now), frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func mf(_ id: String, _ models: String, updated: String? = nil) -> String {
            let upd = updated.map { "\"updated\":\($0)," } ?? ""
            return "{\"schema\":1,\(upd)\"machine\":{\"id\":\"\(id)\",\"name\":\"pc-\(id)\",\"os\":\"T\"},\"days\":{\"claude\":{\"\(day)\":\(models)}}}"
        }
        let ok7 = "\"m-ok\":{\"input\":7}"
        let files: [String: String] = [
            "machine-good.json": mf("good", "{\"m\":{\"input\":10}}"),
            "machine-bool.json": mf("bool", "{\"m\":{\"turns\":true},\(ok7)}"),
            "machine-neg.json": mf("neg", "{\"m\":{\"output\":-1},\(ok7)}"),
            "machine-big.json": mf("big", "{\"m\":{\"input\":1000000000000001},\"m-max\":{\"input\":1000000000000000}}"),
            "machine-intmax1.json": mf("intmax1", "{\"m\":{\"input\":9223372036854775807},\(ok7)}"),
            "machine-intmax2.json": mf("intmax2", "{\"m\":{\"cacheRead\":9223372036854775807},\(ok7)}"),
            "machine-twointmax.json": mf("twointmax", "{\"m\":{\"input\":18446744073709551614},\(ok7)}"),
            "machine-float.json": mf("float", "{\"m\":{\"input\":1.5},\(ok7)}"),
            "machine-frac.json": mf("frac", "{\(ok7)}", updated: "\"\(frac.string(from: now))\""),
            "machine-aa.json": mf("bb", "{\"m\":{\"input\":1000}}"),
            "machine-badupd.json": mf("badupd", "{\"m\":{\"input\":1000}}", updated: "\"2026-99-01T00:00:00Z\""),
            "machine-nullupd.json": mf("nullupd", "{\"m\":{\"input\":1000}}", updated: "null"),
            "machine-numupd.json": mf("numupd", "{\"m\":{\"input\":1000}}", updated: "12345"),
            "machine-schemabool.json": mf("schemabool", "{\"m\":{\"input\":1000}}").replacingOccurrences(of: "\"schema\":1", with: "\"schema\":true"),
            "machine-notdict.json": "{\"schema\":1,\"machine\":[\"notdict\"],\"days\":{}}",
            "machine-huge.json": mf("huge", "{\"m\":{\"input\":1" + String(repeating: "0", count: 400) + "}}"),
            "machine-list.json": "[1,2]",
        ]
        let r = GitHubSync.merge(files, excluding: "selftest-self", now: now)
        let ids = Set(r.machines.map { $0.id }).subtracting(["huge"])
        let d = r.days["claude"]?[day] ?? [:]
        expect(ids == ["good", "bool", "neg", "big", "intmax1", "intmax2", "twointmax", "float", "frac"],
               "M6 accepted machines: \(ids.sorted())")
        expect(d["m"]?.input == 10 && d["m"]?.output == 0 && d["m"]?.turns == 0 && d["m"]?.cacheRead == 0,
               "M6 bool / negative / >1e15 / Int.max / 2*Int.max / float records dropped (m.input=\(d["m"]?.input ?? -1))")
        expect(d["m-ok"]?.input == 49 && d["m-max"]?.input == 1_000_000_000_000_000,
               "M6 the valid records of those files merged (m-ok=\(d["m-ok"]?.input ?? -1))")
        expect(r.machines.contains { $0.id == "frac" }, "M6 fractional seconds in updated accepted")
        expect(!ids.contains("bb") && !ids.contains("badupd") && !ids.contains("nullupd") && !ids.contains("numupd")
               && !ids.contains("schemabool") && !ids.contains("notdict"),
               "M6 id != file name, broken/null/number updated, schema true, machine not object: file skipped")
        let dup = GitHubSync.merge(["machine-good.json": mf("good", "{\"m\":{\"input\":10}}"),
                                    "machine-GOOD.json": mf("good", "{\"m\":{\"input\":10}}")], excluding: "selftest-self", now: now)
        expect(dup.machines.count == 1 && dup.days["claude"]?[day]?["m"]?.input == 10, "M6 same id under another name counted once")
    }

    // 7. Visibility: public true / missing / non-boolean → never written, gist id and push hash reset.
    let visibilities: [(String, Any?)] = [("true", true), ("missing", nil), ("0", 0), ("\"false\"", "false")]
    for (label, pub) in visibilities {
        freshDefaults(gist: "pub-gist")
        selfTestDefaults.set("stale-hash", forKey: "syncPushHash")
        let http = SelfTestHTTP { c in
            if c.url == api + "/gists/pub-gist" && c.method == "GET" { return reply(200, gistBody("pub-gist", pub: pub)) }
            return reply(599)
        }
        let s = makeSync(http, SelfTestKeychainStore(tokA))
        s.syncSynchronously()
        expect(http.calls.count == 1 && !http.calls.contains { $0.method != "GET" }
               && selfTestDefaults.string(forKey: "syncGistId") == nil && selfTestDefaults.string(forKey: "syncPushHash") == nil,
               "M7 public=\(label): not written, gistId and pushHash cleared")
    }
    do {
        freshDefaults(gist: nil)
        let list: [[String: Any]] = [
            ["id": "pub-gist", "public": true, "created_at": "2020-01-01T00:00:00Z", "files": [SYNC_MANIFEST: [String: Any]()]],
            ["id": "nofield", "created_at": "2020-01-02T00:00:00Z", "files": [SYNC_MANIFEST: [String: Any]()]],
            ["id": "sec", "public": false, "created_at": "2026-01-01T00:00:00Z", "files": [SYNC_MANIFEST: [String: Any]()]]]
        let http = SelfTestHTTP { c in
            if c.url.hasPrefix(api + "/gists?per_page=100&page=1") { return reply(200, list) }
            if c.url == api + "/gists/sec" { return reply(200, gistBody("sec")) }
            return reply(599)
        }
        let s = makeSync(http, SelfTestKeychainStore(tokA))
        s.syncSynchronously()
        expect(selfTestDefaults.string(forKey: "syncGistId") == "sec" && !http.calls.contains { $0.url.contains("pub-gist") || $0.url.contains("nofield") }
               && http.calls.filter { $0.method == "PATCH" }.map { $0.url } == [api + "/gists/sec"],
               "M7 discovery picks the secret gist, public/unknown never touched: \(paths(http))")
    }

    // 8. Backoff from Retry-After / x-ratelimit-reset, capped at 1 h; 403 without signals = no pause.
    do {
        let t = Date().timeIntervalSince1970
        let cases: [(String, SyncHTTPResult, ClosedRange<Double>?)] = [
            ("429 Retry-After 120", reply(429, nil, ["Retry-After": "120"]), 100...125),
            ("429 Retry-After huge", reply(429, nil, ["Retry-After": "999999"]), 3500...3601),
            ("403 reset +600", reply(403, nil, ["x-ratelimit-remaining": "0", "x-ratelimit-reset": String(Int(t + 600))]), 580...605),
            ("403 reset +1 day", reply(403, nil, ["x-ratelimit-remaining": "0", "x-ratelimit-reset": String(Int(t + 86400))]), 3500...3601),
            ("403 reset in the past", reply(403, nil, ["x-ratelimit-remaining": "0", "x-ratelimit-reset": String(Int(t - 600))]), -5...2),
            ("403 bad Retry-After + reset", reply(403, nil, ["Retry-After": "soon", "x-ratelimit-remaining": "0", "x-ratelimit-reset": String(Int(t + 300))]), 280...305),
            ("429 no headers", reply(429), 890...901),
            ("403 no limit signals", reply(403, nil, ["x-ratelimit-remaining": "12"]), nil)]
        for (label, r, range) in cases {
            freshDefaults()
            let http = SelfTestHTTP { _ in r }
            let s = makeSync(http, SelfTestKeychainStore(tokA))
            s.syncSynchronously()
            let delay = s.selfTestBackoffUntil.timeIntervalSinceNow
            if let range = range {
                expect(range.contains(delay), "M8 \(label): pause \(Int(delay)) s in \(Int(range.lowerBound))…\(Int(range.upperBound))")
            } else {
                http.reset(); s.syncSynchronously()
                expect(delay <= 0 && http.calls.count == 1 && (s.ui.lastError ?? "").contains("доступ запрещён (403)"),
                       "M8 \(label): access error, no pause")
            }
        }
    }

    // 9. syncWarning: nothing before this process's first attempt; the 30-minute threshold.
    do {
        let now = Date(), m: TimeInterval = 60
        var st = SyncUIState(phase: .on, login: "selftest-login")
        st.lastSync = now.addingTimeInterval(-120 * m); st.lastError = "ответ 500"; st.lastErrorAt = now.addingTimeInterval(-m)
        expect(syncWarning(st, now: now) == nil, "M9 persisted error, no attempt in this process -> no warning")
        st.firstAttemptAt = now.addingTimeInterval(-5 * m)
        expect(syncWarning(st, now: now)?.hasPrefix("Синхронизация стоит с") == true, "M9 error after 2 h idle -> «стоит»")
        var early = st
        early.lastSync = now.addingTimeInterval(-40 * m); early.firstAttemptAt = now.addingTimeInterval(-39 * m)
        early.lastErrorAt = now.addingTimeInterval(-30 * m)
        expect(syncWarning(early, now: now) == nil, "M9 error 10 min after success (before the threshold) -> no warning")
        early.lastErrorAt = now.addingTimeInterval(-8 * m)
        expect(syncWarning(early, now: now) != nil, "M9 error 32 min after success (after the threshold) -> warning")
        var before = st
        before.lastErrorAt = now.addingTimeInterval(-10 * m)
        expect(syncWarning(before, now: now) == nil, "M9 error older than this process's first attempt -> no warning")
        var never = SyncUIState(phase: .on, login: "selftest-login")
        never.firstAttemptAt = now.addingTimeInterval(-m); never.lastError = "нет связи с GitHub"; never.lastErrorAt = now
        expect(syncWarning(never, now: now)?.hasPrefix("Синхронизация не работает") == true, "M9 never synced + error -> «не работает»")
        expect(syncWarning(SyncUIState(phase: .revoked), now: now) != nil, "M9 revoked always warns")
        // Live: a fresh instance restores the persisted error but not firstAttemptAt.
        freshDefaults()
        selfTestDefaults.set(now.addingTimeInterval(-120 * m), forKey: "syncLastOkAt")
        selfTestDefaults.set("старая ошибка", forKey: "syncLastError"); selfTestDefaults.set(now.addingTimeInterval(-m), forKey: "syncLastErrorAt")
        let http = SelfTestHTTP { _ in reply(500) }
        let s = makeSync(http, SelfTestKeychainStore(tokA))
        expect(syncWarning(s.ui) == nil, "M9 live: restored state before the first attempt -> no warning")
        s.syncSynchronously()
        expect(syncWarning(s.ui)?.contains("ответ 500") == true, "M9 live: after a failed attempt -> «\(syncWarning(s.ui) ?? "nil")»")
    }

    // 10. The token never leaves the Keychain except in Authorization: not in the gist file,
    // URLs, other headers, defaults, lastError or the remote cache (built at run time, no literal).
    do {
        let secret = "gho" + "_" + "TESTTOKEN" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let others: [String: Any] = ["machine-aa.json": ["content": "{\"schema\":1,\"machine\":{\"id\":\"aa\",\"name\":\"pc-aa\"},\"days\":{}}"]]
        var texts: [String] = []
        for step in ["ok", "inconclusive", "revoked"] {
            freshDefaults()
            var users = step == "revoked" ? [reply(401), reply(401)] : [reply(401), reply(500)]
            let http = SelfTestHTTP { c in
                if step == "ok" { return c.method == "GET" ? reply(200, gistBody(extra: others)) : reply(200, [String: Any]()) }
                if c.url == api + "/user", !users.isEmpty { return users.removeFirst() }
                return reply(401)
            }
            let s = makeSync(http, SelfTestKeychainStore(secret))
            s.syncSynchronously()
            texts.append(s.ui.lastError ?? "")
            texts.append(String(describing: selfTestDefaults.dictionaryRepresentation()))
            texts.append((try? String(contentsOfFile: remoteFile, encoding: .utf8)) ?? "")
            for c in http.calls {
                texts.append(c.url)
                texts.append(c.body.map { String(decoding: $0, as: UTF8.self) } ?? "")
                texts.append(c.headers.filter { $0.key.lowercased() != "authorization" }.description)
                if c.url.hasPrefix(api) && c.headers["Authorization"] != "Bearer " + secret { texts.append("missing bearer") }
            }
            if step == "ok" { expect(http.calls.contains { $0.method == "PATCH" && $0.body != nil }, "M10 ok cycle wrote the gist file") }
        }
        let leaked = texts.contains { $0.contains(secret) || $0.contains(String(secret.suffix(16))) || $0 == "missing bearer" }
        expect(!leaked, "M10 token substring absent from gist body, URLs, other headers, defaults, lastError, remote cache")
    }

    // 13. Cancellation after a Keychain write/read and just before publishing the login.
    for point in ["afterWrite", "afterRead", "beforePublish"] {
        for (replacement, wasRevoked) in [(false, false), (true, false), (false, true), (true, true)] {
            selfTestDefaults.clear()
            selfTestDefaults.set(wasRevoked, forKey: "syncRevoked")
            let store = SelfTestKeychainStore(wasRevoked ? tokA : nil)
            let http = SelfTestHTTP { c in
                switch c.url {
                case "https://github.com/login/device/code":
                    return reply(200, ["device_code": "dc", "user_code": "UC-13", "interval": 0, "expires_in": 60])
                case "https://github.com/login/oauth/access_token": return reply(200, ["access_token": tokA])
                case api + "/user": return reply(200, ["login": "selftest-login"])
                default: return reply(599)
                }
            }
            let s = makeSync(http, store)
            if wasRevoked { s.loadSynchronously() }
            s.selfTestLoginCheckpoint = { [weak s] checkpoint in
                if checkpoint == point {
                    s?.cancelLogin()
                    if replacement {
                        store.token = tokB
                        selfTestDefaults.set("replacement-login", forKey: "syncLogin")
                    }
                }
            }
            s.startLogin()
            check(s.selfTestWaitForQueue(), "13 \(point): queue finished, no UI-lock deadlock")
            expect(store.writes == 1 && store.deletes == (replacement ? 0 : 1)
                   && store.token == (replacement ? tokB : nil) && s.ui.phase == (wasRevoked ? .revoked : .off)
                   && (!wasRevoked || s.ui.keychainItemLeft == replacement)
                   && selfTestDefaults.string(forKey: "syncLogin") == (replacement ? "replacement-login" : nil)
                   && http.calls.count == 3,
                   "13 \(point), revoked=\(wasRevoked): cancelled login unpublished, \(replacement ? "token B retained" : "token A deleted"), no sync")
            // A restart sees only the replacement sign-in, if one was published.
            let reloadHTTP = SelfTestHTTP { _ in reply(599) }
            let reloaded = makeSync(reloadHTTP, store)
            reloaded.loadSynchronously()
            expect(reloaded.ui.phase == (wasRevoked ? .revoked : replacement ? .on : .off)
                   && reloaded.ui.login == (replacement ? "replacement-login" : nil)
                   && reloadHTTP.calls.isEmpty && store.writes == 1,
                   "13 \(point), revoked=\(wasRevoked), B=\(replacement): reload preserves only the published replacement")
        }
    }
    do {
        selfTestDefaults.clear()
        let store = SelfTestKeychainStore(tokA)
        let http = SelfTestHTTP { _ in reply(599) }
        let s = makeSync(http, store)
        s.loadSynchronously()
        expect(s.ui.phase == .off && s.ui.login == nil && store.token == tokA && http.calls.isEmpty,
               "13 token without syncLogin loads as off")
    }

    // 14. Missing credentials with a known login stay revoked after cancel/failure.
    for (knownLogin, flagged) in [(false, false), (true, false), (false, true), (true, true)] {
        selfTestDefaults.clear()
        if knownLogin { selfTestDefaults.set("selftest-login", forKey: "syncLogin") }
        selfTestDefaults.set(flagged, forKey: "syncRevoked")
        let s = GitHubSync(transport: OFFLINE_SYNC_HTTP, keychain: OfflineSyncKeychain(), defaults: selfTestDefaults,
                           remotePath: remoteFile, machineId: "selftest-self")
        let phase: SyncPhase = knownLogin || flagged ? .revoked : .off
        s.loadSynchronously(); s.cancelLogin()
        expect(s.ui.phase == phase, "14 cancel: login=\(knownLogin), revoked flag=\(flagged)")
        s.startLogin()
        check(s.selfTestWaitForQueue(), "14 failed login queue finished")
        expect(s.ui.phase == phase && s.ui.error != nil, "14 failure: login=\(knownLogin), revoked flag=\(flagged)")
    }

    // 15. Restore the manual-cleanup affordance without reading Keychain in drawSettings.
    for result in [SyncKeychainRead.token(tokA), .missing, .timedOut, .failure(-1)] {
        freshDefaults(); selfTestDefaults.set(true, forKey: "syncRevoked")
        let store = SelfTestKeychainStore(tokA); store.reads = [result]
        let http = SelfTestHTTP { _ in reply(599) }
        let s = makeSync(http, store)
        s.loadSynchronously()
        let left: Bool
        if case .missing = result { left = false } else { left = true }
        expect(s.ui.phase == .revoked && s.ui.keychainItemLeft == left && store.readCount == 1 && http.calls.isEmpty,
               "15 revoked load reads Keychain once, cleanup available=\(left)")
    }
    for status in [SyncKeychainStatus.success, .missing, .timedOut, .failure(-1)] {
        freshDefaults()
        let store = SelfTestKeychainStore(tokA); store.deleteStatus = status
        let http = SelfTestHTTP { _ in reply(401) }
        let s = makeSync(http, store)
        s.syncSynchronously()
        let left = status != .success && status != .missing
        expect(s.ui.phase == .revoked && s.ui.keychainItemLeft == left && store.deletes == 1,
               "15 revocation deletion \(status): cleanup available=\(left)")
        s.logout()
        check(s.selfTestWaitForQueue(), "15 revoked logout queue finished")
        expect(left ? (s.ui.phase == .revoked && s.ui.keychainItemLeft && s.ui.lastError != nil
                       && selfTestDefaults.bool(forKey: "syncRevoked") && store.token == tokA)
                    : (s.ui.phase == .off && !s.ui.keychainItemLeft && s.ui.lastError == nil
                       && selfTestDefaults.string(forKey: "syncLogin") == nil && !selfTestDefaults.bool(forKey: "syncRevoked")),
               "15 revoked logout \(status): \(left ? "error recorded, revoked retained" : "local state cleared")")
        if left {
            store.deleteStatus = .success
            s.logout()
            check(s.selfTestWaitForQueue(), "15 retry logout queue finished")
            expect(s.ui.phase == .off && !s.ui.keychainItemLeft && store.token == nil
                   && selfTestDefaults.string(forKey: "syncLogin") == nil,
                   "15 manual logout retries cleanup despite timeout/backoff")
        }
    }

    // M-1/M-2. Cancelled first sign-in cleanup and cancellation after publication.
    do {
        func loginHTTP() -> SelfTestHTTP {
            SelfTestHTTP { c in
                switch c.url {
                case "https://github.com/login/device/code":
                    return reply(200, ["device_code": "dc", "user_code": "UC-M1", "interval": 0, "expires_in": 60])
                case "https://github.com/login/oauth/access_token": return reply(200, ["access_token": tokA])
                case api + "/user": return reply(200, ["login": "selftest-login"])
                default: return reply(599)
                }
            }
        }
        for point in ["afterWrite", "afterRead", "beforePublish"] {
            for status in [SyncKeychainStatus.failure(-1), .timedOut] {
                selfTestDefaults.clear()
                let store = SelfTestKeychainStore(nil); store.deleteStatus = status
                let http = loginHTTP(), s = makeSync(http, store)
                s.selfTestLoginCheckpoint = { [weak s] checkpoint in
                    if checkpoint == point { s?.cancelLogin() }
                }
                s.startLogin()
                check(s.selfTestWaitForQueue(), "M-1 \(point), \(status): cancellation queue finished")
                expect(s.ui.phase == .off && s.ui.keychainItemLeft && s.ui.canSignOut
                       && store.token == tokA && store.writes == 1 && store.deletes == 1
                       && selfTestDefaults.string(forKey: "syncLogin") == nil && http.calls.count == 3,
                       "M-1 \(point), \(status): first login cancelled, off with Sign out available")
                store.deleteStatus = .success
                s.logout()
                check(s.selfTestWaitForQueue(), "M-1 retry logout queue finished")
                expect(s.ui.phase == .off && !s.ui.keychainItemLeft && !s.ui.canSignOut
                       && store.token == nil && store.deletes == 2 && s.ui.lastError == nil
                       && selfTestDefaults.string(forKey: "syncLogin") == nil && http.calls.count == 3,
                       "M-1 \(point), \(status): manual Sign out clears token and cleanup flag")
            }
        }
        for knownLogin in [false, true] {
            for result in [SyncKeychainRead.token(tokB), .missing, .timedOut, .failure(-1)] {
                selfTestDefaults.clear()
                if knownLogin { selfTestDefaults.set("selftest-login", forKey: "syncLogin") }
                let store = SelfTestKeychainStore(nil), http = loginHTTP()
                let s = makeSync(http, store)
                s.selfTestLoginCheckpoint = { [weak s] point in
                    if point == "afterWrite" {
                        s?.cancelLogin()
                        store.token = tokB; store.reads = [result]
                    }
                }
                s.startLogin()
                check(s.selfTestWaitForQueue(), "M-1 cleanup read queue finished")
                let left: Bool
                if case .missing = result { left = false } else { left = knownLogin }
                expect(s.ui.phase == (knownLogin ? .revoked : .off) && s.ui.keychainItemLeft == left
                       && s.ui.canSignOut == left && store.readCount == (knownLogin ? 1 : 0)
                       && store.deletes == (knownLogin ? 0 : 1) && store.token == (knownLogin ? tokB : nil)
                       && selfTestDefaults.string(forKey: "syncLogin") == (knownLogin ? "selftest-login" : nil)
                       && http.calls.count == 3,
                       "M-1 knownLogin=\(knownLogin), read=\(result): protect published token; otherwise delete without reading")
            }
        }
        selfTestDefaults.clear()
        let store = SelfTestKeychainStore(nil), http = loginHTTP()
        let s = makeSync(http, store)
        s.startLogin()
        check(s.selfTestWaitForQueue(), "M-2 publication queue finished")
        expect(s.ui.phase == .on && s.ui.login == "selftest-login"
               && selfTestDefaults.string(forKey: "syncLogin") == "selftest-login", "M-2 sign-in published")
        let calls = http.calls.count, reads = store.readCount
        s.cancelLogin()
        expect(s.ui.phase == .on && s.ui.login == "selftest-login" && s.ui.keychainItemLeft
               && selfTestDefaults.string(forKey: "syncLogin") == "selftest-login"
               && !selfTestDefaults.bool(forKey: "syncRevoked") && store.token == tokA
               && store.writes == 1 && store.deletes == 0 && store.readCount == reads && http.calls.count == calls,
               "M-2 cancel after publication is a no-op: live sign-in and token retained")
    }

    // 16. Clamp both a valid large sum and the accumulator returned after overflow.
    expect(usageSum(900_000_000_000_000, 900_000_000_000_000) == 1_000_000_000_000_000,
           "16 two 9e14 contributions sum to 1e15")
    expect(usageSum(7, Int.max) == 7 && usageSum(Int.max, 1) == 1_000_000_000_000_000,
           "16 overflow keeps the old accumulator, capped at 1e15")

    // 17. CoreText measurement only: no app/window, screenshot or real defaults.
    for lang in ["ru", "en"] {
        let hint = syncSignOutHint(lang)
        let a = ctAttr(hint, ctFont(10.5, .regular), cg(gray(1, 0.5)))
        let fs = CTFramesetterCreateWithAttributedString(a)
        let rect = CGRect(x: 0, y: 0, width: PANEL_W - 32 - 28, height: SET_SYNC_SIGNOUT_HINT_H)
        let frame = CTFramesetterCreateFrame(fs, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
        let lines = CTFrameGetLines(frame) as! [CTLine]
        expect(CTFrameGetVisibleStringRange(frame).length == a.length && lines.count == 2
               && hint.components(separatedBy: "\n").last == "github.com/settings/applications",
               "17 \(lang) sign-out hint fits two lines; applications address intact")
    }
    for phase in [SyncPhase.on, .revoked, .off] {
        var st = SyncUIState(phase: phase, keychainItemLeft: true)
        st.machines = (1...3).map { SyncMachine(name: "selftest-\($0)", os: "macOS", updated: nil, isSelf: $0 == 1) }
        st.lastError = "selftest error"
        let cardH = setSyncCardH(st)
        let beforeCardH = phase == .on
            ? SET_ROW_H + 3 * SET_SYNC_MROW_H + 4 + SET_SYNC_STATUS_H + SET_SYNC_STATUS_H - 4
            : SET_ROW_H + SET_SYNC_NOTE_H + (phase == .revoked ? SET_SYNC_STATUS_H : 0)
        // Advanced settings: sync card -> gap -> sounds row -> gap -> About caption.
        let caption = SET_SYNC_TOP + cardH + SET_GAP + SET_ROW_H + SET_GAP
        let beforeCaption = SET_SYNC_TOP + beforeCardH + SET_GAP + SET_ROW_H + SET_GAP
        for extraAboutLine in [false, true] {
            var about = AboutState(); about.msg = extraAboutLine ? .checkFailed : .none
            let before = settingsTotalHeight(about, aboutCap: beforeCaption)
            let after = settingsTotalHeight(about, aboutCap: caption)
            expect(after <= 860 && after - before == SET_SYNC_SIGNOUT_HINT_H,
                   "17 settings \(phase), 3 machines, lastError, About line=\(extraAboutLine): \(Int(before)) -> \(Int(after)) pt <= 860")
        }
        if phase == .revoked || phase == .off {
            st.keychainItemLeft = false
            expect(setSyncCardH(st) == beforeCardH && !st.canSignOut,
                   "17 \(phase) without Keychain item: no sign-out link or hint height")
        }
    }

    selfTestDefaults.clear()
    try? FileManager.default.removeItem(atPath: remoteFile)
    try? FileManager.default.removeItem(atPath: selfTestRoot)
    print(failures == 0 ? "OK regression cases: all passed" : "FAIL regression cases: \(failures) failed")
    exit(failures == 0 ? 0 : 1)
}

if CommandLine.arguments.contains("--advanced-dump") {
    let t0 = Date()
    UsageHistory.shared.load(); UsageLogs.shared.load()
    let changed = UsageLogs.shared.scanSync()
    let ix = UsageLogs.shared.snapshot()
    print(String(format: "scan: %.1fs, changed=%@, files=%d", Date().timeIntervalSince(t0), changed ? "yes" : "no", ix.files.count))
    for product in ["claude", "codex"] {
        print("== \(product)")
        for d in dailyUsage(product, days: 10, index: ix) where d.turns > 0 {
            let models = d.byModel.map { "\(modelDisplayName($0.model)) $\(String(format: "%.2f", $0.usd))" }.joined(separator: ", ")
            print(String(format: "  %@ turns=%4d tokens=%12d usd=%7.2f  [%@]", d.day, d.turns, d.tokens, d.usd, models))
        }
        let m = moneySummary(product, plan: nil, index: ix)
        print(String(format: "  money: api35=$%.2f perDay=$%.2f perActive=$%.2f sub=$%.0f/mo%@ ratio=x%.1f", m.usdApi, m.perCalendarDay, m.perActiveDay, m.subMonthly, m.subEstimated ? " (est)" : "", m.ratio))
    }
    var c = LimitData(), x = LimitData()
    if let cd = try? Data(contentsOf: URL(fileURLWithPath: CACHE_PATH)), let cj = (try? JSONSerialization.jsonObject(with: cd)) as? [String: Any] {
        if let m = cj["claude"] as? [String: Any] { c = dict2ld(m) }
        if let m = cj["codex"] as? [String: Any] { x = dict2ld(m) }
    }
    for (name, d) in [("claude", c), ("codex", x)] {
        for l in pacedLimits(d, product: name) {
            guard let p = l.pace else { print("  \(name) \(l.name): no window"); continue }
            let f = DateFormatter(); f.dateFormat = "EEE dd.MM HH:mm"
            print(String(format: "  %@ %@: used=%.0f%% plan=%.1f%% delta=%+.1f rate=%.2f%%/h proj=%@ runsOut=%@ recent=%@", name, l.name, p.used, p.planPct, p.deltaPts, p.avgRatePerH,
                         p.projectedPct.map { String(format: "%.0f%%", $0) } ?? "—", p.runsOutAt.map { f.string(from: $0) } ?? "lasts", p.recentRatePerH.map { String(format: "%.2f", $0) } ?? "n/a"))
        }
    }
    print("history samples:", UsageHistory.shared.samples("claude", since: Date(timeIntervalSince1970: 0)).count, "/", UsageHistory.shared.samples("codex", since: Date(timeIntervalSince1970: 0)).count)
    exit(0)
}


if CommandLine.arguments.contains("--advanced-preview") {
    UsageHistory.shared.load(); UsageLogs.shared.load(); UsageLogs.shared.scanSync()
    var c = LimitData(), x = LimitData()
    if let cd = try? Data(contentsOf: URL(fileURLWithPath: CACHE_PATH)), let cj = (try? JSONSerialization.jsonObject(with: cd)) as? [String: Any] {
        if let m = cj["claude"] as? [String: Any] { c = dict2ld(m); c.fromCache = false }
        if let m = cj["codex"] as? [String: Any] { x = dict2ld(m); x.fromCache = false }
    }
    let dd = UserDefaults.standard
    let s: CGFloat = 2
    func save(_ ctx: CGContext, _ path: String) {
        guard let img = ctx.makeImage() else { return }
        let data = NSMutableData()
        if let dst = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dst, img, nil)
            if CGImageDestinationFinalize(dst) { try? (data as Data).write(to: URL(fileURLWithPath: path)) }
        }
    }
    func render(_ cl: LimitData, _ cx: LimitData, _ path: String) {
        let h = advancedHeight(cl, cx)
        guard let ctx = bitmapContext(Int(PANEL_W * s), Int(h * s)) else { return }
        ctx.scaleBy(x: s, y: s)
        _ = drawAdvanced(ctx, size: CGSize(width: PANEL_W, height: h), claude: cl, codex: cx, interval: POLL_DEFAULT, updated: Date(), about: AboutState())
        save(ctx, path); print(path, Int(h), "pt")
    }
    let out = CommandLine.arguments.last ?? "/tmp"
    // The preview shares the app's defaults domain — snapshot the user's settings and put them
    // back afterwards instead of wiping them (it once switched a user's panel back to Simple).
    let keep = ["lang", "advanced", "advHistExpanded", "advHistProduct"].map { ($0, dd.object(forKey: $0)) }
    dd.set(true, forKey: "advanced")
    for lang in ["ru", "en"] {
        dd.set(lang, forKey: "lang")
        dd.set(true, forKey: "advHistExpanded"); dd.set("claude", forKey: "advHistProduct"); render(c, x, "\(out)/adv-\(lang)-expanded.png")
        dd.set("codex", forKey: "advHistProduct"); render(c, x, "\(out)/adv-\(lang)-codex.png")
        dd.set(false, forKey: "advHistExpanded"); render(c, x, "\(out)/adv-\(lang)-collapsed.png")
    }
    dd.set("ru", forKey: "lang"); dd.set(true, forKey: "advHistExpanded"); dd.set("claude", forKey: "advHistProduct")
    var ex = c; ex.auth = .expired; ex.error = "sign-in expired"; ex.asOf = Date().addingTimeInterval(-22 * 3600)
    render(ex, x, "\(out)/adv-expired.png")
    var noCodex = x; noCodex.present = false
    render(c, noCodex, "\(out)/adv-claude-only.png")
    // Sync states: settings block (off / code / on / revoked) + the history header with 2 PCs.
    func renderSettings(_ path: String) {
        let about = AboutState(), sh = settingsTotalHeight(about)
        guard let ctx = bitmapContext(Int(PANEL_W * s), Int(sh * s)) else { return }
        ctx.scaleBy(x: s, y: s)
        _ = drawSettings(ctx, size: CGSize(width: PANEL_W, height: sh), about: about)
        save(ctx, path); print(path, Int(sh), "pt")
    }
    let mac = SyncMachine(name: Host.current().localizedName ?? "Mac", os: "macOS", updated: Date(), isSelf: true)
    let astra = SyncMachine(name: "astra-desktop", os: "Astra Linux SE", updated: Date().addingTimeInterval(-7 * 60), isSelf: false)
    for lang in ["ru", "en"] {
        dd.set(lang, forKey: "lang")
        SYNC_PREVIEW = SyncUIState(); renderSettings("\(out)/sync-\(lang)-off.png")
        SYNC_PREVIEW = SyncUIState(phase: .awaitingCode, userCode: "WDJB-MJHT"); renderSettings("\(out)/sync-\(lang)-code.png")
        do {
            let sh = settingsTotalHeight(AboutState())
            if let ctx = bitmapContext(Int(PANEL_W * s), Int(sh * s)) {
                ctx.scaleBy(x: s, y: s)
                _ = drawSettings(ctx, size: CGSize(width: PANEL_W, height: sh), about: AboutState(), copied: "WDJB-MJHT")
                save(ctx, "\(out)/sync-\(lang)-code-copied.png")
            }
        }
        SYNC_PREVIEW = SyncUIState(phase: .on, login: "ArrivaRUS", machines: [mac, astra], lastSync: Date()); renderSettings("\(out)/sync-\(lang)-on.png")
        render(c, x, "\(out)/sync-\(lang)-panel.png")
        SYNC_PREVIEW = SyncUIState(phase: .revoked, login: "ArrivaRUS"); renderSettings("\(out)/sync-\(lang)-revoked.png")
    }
    dd.set("ru", forKey: "lang")
    SYNC_PREVIEW = SyncUIState(phase: .on, login: "ArrivaRUS", machines: [mac, astra], lastSync: Date())
    renderSettings("\(out)/settings-sounds-closed.png")
    do {
        let sh = soundsPageHeight()
        if let ctx = bitmapContext(Int(PANEL_W * s), Int(sh * s)) {
            ctx.scaleBy(x: s, y: s)
            _ = drawSettings(ctx, size: CGSize(width: PANEL_W, height: sh), about: AboutState(), soundsPage: true)
            save(ctx, "\(out)/settings-sounds-page.png"); print("\(out)/settings-sounds-page.png", Int(sh), "pt")
        }
    }
    dd.set(false, forKey: "advanced"); SYNC_PREVIEW = nil
    renderSettings("\(out)/settings-simple-closed.png")
    SYNC_PREVIEW = nil
    for (k, v) in keep { if let v = v { dd.set(v, forKey: k) } else { dd.removeObject(forKey: k) } }
    exit(0)
}

// Regenerate all docs/ screenshots (RU + EN) from the live draw code. Run from the repo root.
if CommandLine.arguments.contains("--screenshots") {
    let s2: CGFloat = 2
    func savePNG(_ ctx: CGContext, _ path: String) {
        guard let img = ctx.makeImage() else { return }
        let data = NSMutableData()
        if let dst = CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dst, img, nil)
            if CGImageDestinationFinalize(dst) { try? (data as Data).write(to: URL(fileURLWithPath: path)) }
        }
    }
    func demo(_ sess: Double, _ wk: Double, _ srOff: TimeInterval, _ wrOff: TimeInterval) -> LimitData {
        var d = LimitData(); d.present = true; d.session = sess; d.weekly = wk
        d.sessionReset = Date().addingTimeInterval(srOff); d.weeklyReset = Date().addingTimeInterval(wrOff); d.asOf = Date()
        return d
    }
    var claude = demo(24, 58, 2 * 3600, 4 * 86400)        // blue / amber
    claude.scoped = ScopedLimit(name: "Fable", percent: 46,
                                reset: Date().addingTimeInterval(4 * 86400), severity: "normal")
    var codex  = demo(76, 43, 3 * 3600 + 1800, 2 * 86400) // amber / blue
    codex.resetCredits = 2                                 // show the banked-resets badge
    let claudeOnly = claude; var noCodex = codex; noCodex.present = false

    // menu-bar strips (language-neutral)
    writePreview([(claude, "claude_128.png"), (codex, "codex_128.png")], dark: true,  to: "docs/menubar-dark.png")
    writePreview([(claude, "claude_128.png"), (codex, "codex_128.png")], dark: false, to: "docs/menubar-light.png")
    writePreview([(claudeOnly, "claude_128.png")], dark: true, to: "docs/menubar-single.png")

    let notes = [
        ReleaseNote(version: "2.2", date: "2026-06-28", body: "<!--RU-->\n**Язык интерфейса.**\n- Русский и английский, по умолчанию русский\n- Релиз-ноуты на выбранном языке\n<!--EN-->\n**Interface language.**\n- Russian and English, Russian by default\n- Release notes in the chosen language"),
        ReleaseNote(version: "2.1", date: "2026-06-28", body: "<!--RU-->\n**Экран «Что нового».**\nЗаметки за все пропущенные версии, с прокруткой.\n<!--EN-->\n**\"What's new\" screen.**\nNotes for every version you skipped, scrollable."),
        ReleaseNote(version: "2.0", date: "2026-06-28", body: "<!--RU-->\n**Автообновления.**\nФоновая проверка, скачивание с прогрессом, установка с перезапуском.\n<!--EN-->\n**Automatic updates.**\nBackground checks, download with progress, install & relaunch."),
    ]
    func renderPanel(_ c: LimitData, _ x: LimitData, _ about: AboutState, _ path: String) {
        let ph = panelMainHeight(c, x)
        guard let ctx = bitmapContext(Int(PANEL_W * s2), Int(ph * s2)) else { return }
        ctx.scaleBy(x: s2, y: s2)
        _ = drawPanel(ctx, size: CGSize(width: PANEL_W, height: ph), claude: c, codex: x, interval: POLL_DEFAULT, updated: Date(), about: about)
        savePNG(ctx, path)
    }
    func renderSettings(_ about: AboutState, _ path: String) {
        let sh = settingsTotalHeight(about)
        guard let ctx = bitmapContext(Int(PANEL_W * s2), Int(sh * s2)) else { return }
        ctx.scaleBy(x: s2, y: s2)
        _ = drawSettings(ctx, size: CGSize(width: PANEL_W, height: sh), about: about)
        savePNG(ctx, path)
    }
    func renderWhatsNew(_ about: AboutState, _ path: String) {
        let ch = notesContentHeight(notesAttributedString(notes), width: WN_CONTENT_W)
        let th = min(540, WN_HEADER + WN_FOOTER + ch), vpH = th - WN_HEADER - WN_FOOTER
        guard let ctx = bitmapContext(Int(PANEL_W * s2), Int(th * s2)) else { return }
        ctx.scaleBy(x: s2, y: s2)
        _ = drawWhatsNew(ctx, size: CGSize(width: PANEL_W, height: th), notes: notes, loading: false, error: "", scroll: 0, contentH: ch, viewportH: vpH, about: about)
        savePNG(ctx, path)
    }
    let dd = UserDefaults.standard, savedLang = dd.string(forKey: "lang")
    var wnAbout = AboutState(); wnAbout.availVersion = "2.2.2"; wnAbout.availURL = "x"
    // Advanced view on demo data: a deterministic month of usage across a few models.
    var demoIx = UsageIndex()
    let today = Calendar.current.startOfDay(for: Date())
    for back in 0..<42 {
        let day = dayKey(Calendar.current.date(byAdding: .day, value: -back, to: today)!)
        let wave = [1.0, 0.2, 0.0, 0.6, 1.4, 0.9, 0.3][back % 7] * (back < 7 ? 1.0 : 0.7)
        if wave == 0 { continue }
        var f = DayModelUsage(); f.input = Int(wave * 3_800_000); f.output = Int(wave * 40_000); f.turns = Int(wave * 60)
        var o = DayModelUsage(); o.input = Int(wave * 1_500_000); o.output = Int(wave * 20_000); o.turns = Int(wave * 20)
        demoIx.add("claude", day, "claude-fable-5-1", f); demoIx.add("claude", day, "claude-opus-5", o)
        var a = DayModelUsage(); a.input = Int(wave * 900_000); a.output = Int(wave * 12_000); a.turns = Int(wave * 25)
        var sl = DayModelUsage(); sl.input = Int(wave * 1_200_000); sl.output = Int(wave * 8_000); sl.turns = Int(wave * 15)
        demoIx.add("codex", day, "gpt-6-astra", a); demoIx.add("codex", day, "gpt-5.6-sol", sl)
    }
    UsageLogs.shared.useForPreview(demoIx)
    UsageHistory.shared.useForPreview([UsageSample(t: Date().timeIntervalSince1970 - 86400 * 3, product: "claude", session: 10, weekly: 30, scoped: nil, scopedName: nil, sessionReset: nil, weeklyReset: nil),
                                       UsageSample(t: Date().timeIntervalSince1970 - 86400 * 3, product: "codex", session: nil, weekly: 20, scoped: nil, scopedName: nil, sessionReset: nil, weeklyReset: nil)])
    var advClaude = claude; advClaude.weekly = 58; advClaude.weeklyReset = Date().addingTimeInterval(4 * 86400); advClaude.plan = "max"
    var advCodex = codex; advCodex.session = nil; advCodex.sessionReset = nil; advCodex.plan = "pro"
    let savedTier = dd.string(forKey: "claudeTier"), savedSubC = dd.object(forKey: "subClaude"), savedSubX = dd.object(forKey: "subCodex")
    dd.set("default_claude_max_20x", forKey: "claudeTier"); dd.set(200.0, forKey: "subClaude"); dd.set(200.0, forKey: "subCodex")
    let savedAdv = dd.bool(forKey: "advanced"), savedExp = dd.bool(forKey: "advHistExpanded"), savedHP = dd.string(forKey: "advHistProduct")
    dd.set(true, forKey: "advanced"); dd.set(true, forKey: "advHistExpanded"); dd.set("claude", forKey: "advHistProduct")
    func renderAdvanced(_ c: LimitData, _ x: LimitData, _ path: String) {
        let h = advancedHeight(c, x)
        guard let ctx = bitmapContext(Int(PANEL_W * s2), Int(h * s2)) else { return }
        ctx.scaleBy(x: s2, y: s2)
        _ = drawAdvanced(ctx, size: CGSize(width: PANEL_W, height: h), claude: c, codex: x, interval: POLL_DEFAULT, updated: Date(), about: AboutState())
        savePNG(ctx, path)
    }
    for lang in ["ru", "en"] {
        dd.set(lang, forKey: "lang")
        let sfx = lang == "en" ? "-en" : ""
        renderAdvanced(advClaude, advCodex, "docs/advanced\(sfx).png")
        renderPanel(claude, codex, AboutState(), "docs/panel\(sfx).png")
        renderPanel(claudeOnly, noCodex, AboutState(), "docs/panel-single\(sfx).png")
        renderSettings(AboutState(), "docs/settings\(sfx).png")
        renderWhatsNew(wnAbout, "docs/whatsnew\(sfx).png")
    }
    dd.set(savedLang, forKey: "lang")
    dd.set(savedAdv, forKey: "advanced"); dd.set(savedExp, forKey: "advHistExpanded")
    if let v = savedHP { dd.set(v, forKey: "advHistProduct") } else { dd.removeObject(forKey: "advHistProduct") }
    if let v = savedTier { dd.set(v, forKey: "claudeTier") } else { dd.removeObject(forKey: "claudeTier") }
    if let v = savedSubC { dd.set(v, forKey: "subClaude") } else { dd.removeObject(forKey: "subClaude") }
    if let v = savedSubX { dd.set(v, forKey: "subCodex") } else { dd.removeObject(forKey: "subCodex") }
    print("screenshots written to docs/"); exit(0)
}

if CommandLine.arguments.contains("--check-update") {
    if let (ver, url) = latestRelease() {
        print("latest=\(ver) current=\(APP_VERSION) newer=\(versionGreater(ver, APP_VERSION))")
        print("dmg=\(url)")
    } else { print("check failed") }
    exit(0)
}

if CommandLine.arguments.contains("--codex-live") {
    let local = fetchCodex(live: false)
    let live = fetchCodex(live: true)
    print("local : session=\(local.session.map{Int($0)} ?? -1)% weekly=\(local.weekly.map{Int($0)} ?? -1)% asOf=\(local.asOf?.description ?? "nil")")
    print("live  : session=\(live.session.map{Int($0)} ?? -1)% weekly=\(live.weekly.map{Int($0)} ?? -1)% plan=\(live.plan ?? "nil")")
    exit(0)
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
