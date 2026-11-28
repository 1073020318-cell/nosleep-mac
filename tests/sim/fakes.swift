import Cocoa
import IOKit.pwr_mgt
import UserNotifications

// ---------- shared event log (thread-safe) ----------
let simLock = NSLock()
var simEvents: [String] = []
func ev(_ s: String) { simLock.lock(); simEvents.append(s); simLock.unlock() }
func events() -> [String] { simLock.lock(); defer { simLock.unlock() }; return simEvents }
func resetEvents() { simLock.lock(); simEvents = []; simLock.unlock() }

let simDir = CommandLine.arguments[1]
let simSuite = "nosleep.sim"
/// 只存在内存里的偏好设置，测试不往磁盘写任何东西
final class MemDefaults: UserDefaults {
    var store: [String: Any] = [:]
    override func object(forKey k: String) -> Any? { store[k] }
    override func set(_ v: Any?, forKey k: String) { store[k] = v }
    override func set(_ v: Double, forKey k: String) { store[k] = v }
    override func set(_ v: Int, forKey k: String) { store[k] = v }
    override func set(_ v: Bool, forKey k: String) { store[k] = v }
    override func set(_ v: Float, forKey k: String) { store[k] = v }
    override func removeObject(forKey k: String) { store[k] = nil }
    override func double(forKey k: String) -> Double { (store[k] as? NSNumber)?.doubleValue ?? 0 }
    override func integer(forKey k: String) -> Int { (store[k] as? NSNumber)?.intValue ?? 0 }
    override func bool(forKey k: String) -> Bool { (store[k] as? NSNumber)?.boolValue ?? false }
    override func string(forKey k: String) -> String? { store[k] as? String }
    override func removePersistentDomain(forName domainName: String) { store = [:] }
}
enum SimDefaults { static let d: UserDefaults = MemDefaults(suiteName: nil)! }
enum SimStatusBar {
    static let item: NSStatusItem = {
        let s = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        s.isVisible = false
        return s
    }()
}

// ---------- fake hardware / system ----------
enum Power {
    static let rootDomain: io_service_t = 0          // IOKit subscription fails harmlessly → poll only
    static var lid: Bool? = false
    static var sleepState: Bool? = false             // what `pmset -g` would say
    static var clamshellCausesSleep = true
    static var batteryState: (onBattery: Bool, percent: Int)? = (false, 100)
    static var legacy: RealPower.LegacyTimers = .none
    static var lidClosed: Bool? { lid }
    static var sleepDisabledReading: Bool? { sleepState }
    static var sleepDisabled: Bool { sleepState ?? false }
    static var sleepConfirmedEnabled: Bool { sleepState == false }
    static func battery() -> (onBattery: Bool, percent: Int)? { batteryState }
    static func legacyTimers() -> RealPower.LegacyTimers { legacy }
}

enum Privileged {
    static var failNext = 0
    static var delay: TimeInterval = 0
    static var adminFails = false
    static var ownRuleInstalled = true
    static var legacyRulePresent = false
    static var rulePath: String { simDir + "/fake-sudoers-rule" }
    static func setSleepDisabled(_ on: Bool) -> Bool {
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        if failNext > 0 { failNext -= 1; ev("sudo pmset disablesleep \(on ? 1 : 0) → FAIL"); return false }
        Power.sleepState = on
        ev("sudo pmset disablesleep \(on ? 1 : 0)")
        return true
    }
    static func install(restoreTimers: Bool, prompt: String) -> String? { ev("admin install"); ownRuleInstalled = true; return nil }
    static func runAsAdmin(_ script: String, prompt: String) -> String? {
        ev("admin: \(script)")
        if adminFails { return "simulated failure" }
        if script.contains("disablesleep 0") { Power.sleepState = false }
        return nil
    }
    static func uninstallScript(restoreTimers: Bool) -> String { "uninstall(restoreTimers:\(restoreTimers)) disablesleep 0" }
}

@discardableResult
func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
    ev("run \(path) \(args.joined(separator: " "))"); return (0, "")
}

var assertionsHeld = 0
var failNextAssertion = 0
@discardableResult
func fakeAssertionCreate(_ type: CFString, _ level: IOPMAssertionLevel, _ name: CFString, _ id: UnsafeMutablePointer<IOPMAssertionID>) -> IOReturn {
    if failNextAssertion > 0 { failNextAssertion -= 1; id.pointee = 0; ev("assertion → FAIL"); return kIOReturnError }
    assertionsHeld += 1; id.pointee = 42; ev("assertion +"); return kIOReturnSuccess
}
@discardableResult
func fakeAssertionRelease(_ id: IOPMAssertionID) -> IOReturn { assertionsHeld -= 1; ev("assertion -"); return kIOReturnSuccess }

final class Backlight {
    static var panel: Float = 0.8           // real panel brightness
    static var failRestores = 0
    static var failDims = 0
    var available = true
    var isDimmed: Bool { SimDefaults.d.object(forKey: "dimmedBrightness") != nil }
    @discardableResult func builtinDisplay() -> CGDirectDisplayID? { 1 }
    func brightness(_ d: CGDirectDisplayID) -> Float? { Self.panel }
    func markDimmed(saved: Float, display: CGDirectDisplayID) {
        SimDefaults.d.set(Double(saved), forKey: "dimmedBrightness"); SimDefaults.d.set(Int(display), forKey: "dimmedDisplay")
    }
    @discardableResult func dim() -> Bool {
        if isDimmed { return true }
        if Self.failDims > 0 { Self.failDims -= 1; ev("dim → FAIL"); return false }
        markDimmed(saved: Self.panel, display: 1); Self.panel = 0; ev("dim"); return true
    }
    @discardableResult func restore(wakeDisplay: Bool = true) -> Bool {
        guard isDimmed else { return true }
        if Self.failRestores > 0 { Self.failRestores -= 1; ev("restore → FAIL"); return false }
        Self.panel = Float(SimDefaults.d.double(forKey: "dimmedBrightness"))
        SimDefaults.d.removeObject(forKey: "dimmedBrightness"); SimDefaults.d.removeObject(forKey: "dimmedDisplay")
        ev("restore wake=\(wakeDisplay)"); return true
    }
    func reassertLastRestore() {}
}

final class PowerSourceWatcher {
    var onChange: (() -> Void)?
    private(set) var isRunning = false
    func start() {
        guard !isRunning else { return }
        isRunning = true
        ev("powerWatcher start")
    }
    func stop() {
        guard isRunning else { return }
        isRunning = false
        ev("powerWatcher stop")
    }
    func fire() {
        if isRunning { onChange?() }
    }
}

enum FakeUI {
    static var responses: [NSApplication.ModalResponse] = []
    static var onRespond: ((NSAlert) -> Void)?
    @discardableResult
    static func respond(_ alert: NSAlert) -> NSApplication.ModalResponse {
        ev("ALERT \(alert.messageText)")
        let hook = onRespond
        onRespond = nil
        hook?(alert)
        return responses.isEmpty ? .alertSecondButtonReturn : responses.removeFirst()
    }
    static func activate(ignoringOtherApps: Bool) {}
    static func terminate(_ sender: Any?) { ev("terminate") }
    static func add(_ r: UNNotificationRequest, _ cb: ((Error?) -> Void)? = nil) { ev("NOTIFY \(r.content.title)"); cb?(nil) }
    static func recycle(_ urls: [URL], completionHandler: (([URL: URL], Error?) -> Void)?) { ev("recycle app"); completionHandler?([:], nil) }
}
