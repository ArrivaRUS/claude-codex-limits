// Runtime boundaries for copied owner method bodies: no application, timer or defaults I/O.
final class MemoryDefaults {
    private var values: [String: Any] = [:]
    func set(_ value: Any, forKey key: String) { values[key] = value }
    func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
}
enum UserDefaults { static let standard = MemoryDefaults() }
func autoPollEnabled() -> Bool { UserDefaults.standard.bool(forKey: "autoPoll") }
func normalizedPollInterval(_ value: TimeInterval) -> TimeInterval { [900,1800,3600].contains(value) ? value : 1800 }
func selectedLimits(_ data: LimitData, product: String) -> LimitData { data }
final class Timer {
    var fireDate: Date
    init(timeInterval: TimeInterval, repeats: Bool, block: @escaping (Timer) -> Void) {
        fireDate = Date(timeIntervalSince1970: fixedNow + timeInterval)
        // Intentionally never retain or execute callbacks.
    }
    func invalidate() {}
}
enum FakeRunMode { case common }
final class RunLoop {
    static let main = RunLoop()
    func add(_ timer: Timer, forMode mode: FakeRunMode) {}
}
final class FakeView {
    var claude = LimitData(), codex = LimitData()
    var interval: TimeInterval = 900
    var updated: Date? = nil
    var needsDisplay = false
    var autoIntervals: [String: TimeInterval] = [:]
}
final class Button {}
final class FakeStatusItem { var button: Button? = Button() }
enum MouseType { case leftMouseUp, rightMouseUp }
struct MouseEvent { var type = MouseType.leftMouseUp }
let NSApp = FakeApplication()
final class FakeApplication { var currentEvent: MouseEvent? = MouseEvent() }
final class FakePanel {
    var view = FakeView()
    var isVisible = false
    func update(claude: LimitData, codex: LimitData, interval: TimeInterval, updated: Date?) {
        view.claude = claude; view.codex = codex; view.interval = interval; view.updated = updated
    }
    func show(below: Button) { isVisible = true }
    func hide() { isVisible = false }
}
// __OWNER_METHODS__ appended inside this fake owner, exact production handlers.
final class ReplayOwner {
    var timer: Timer?
    var interval: TimeInterval = 900
    var last: (LimitData, LimitData)?
    var panelCtrl: FakePanel! = FakePanel()
    var autoStates: [String: AutoPollState] = [:]
    var fetchingLimits = false
    var statusItem = FakeStatusItem()
    var refreshRequests = 0
    func scanActivity() {} // no logs/index scanning
    func doRefresh(live: Bool, scheduled: Bool = false) { refreshRequests += 1 } // no worker/fetch
    func applyTrayImage(_ c: LimitData, _ x: LimitData) {} // no graphics or status-item mutation
    func checkAlarms(_ c: LimitData, _ x: LimitData) {} // no sounds/notifications
    func showContextMenu() {} // no native menu
