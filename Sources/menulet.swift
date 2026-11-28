// ============================================================
//  合盖不休眠 v1.7 — 菜单栏版（纯 Swift）
//
//  功能：
//    - 菜单栏常驻图标，不占 Dock 位置
//    - 一键开/关合盖不休眠（pmset disablesleep）
//    - 合盖自动关屏幕背光，开盖秒亮
//    - 定时关闭（30 分钟 / 1h / 2h / 4h / 8h）；App 意外退出后重新打开会继续计时
//    - 低电量保护：用电池时电量降到设定值自动关闭
//    - 开机自动启动（macOS 13+）
//    - 一键卸载（删除免密配置 + 恢复休眠 + 删除 App 自己的文件）
//
//  v1.7 相对 v1.6 的主要变化：
//    - 合盖监听改为 IOKit 事件通知（原来每 0.1 秒启动 5 个子进程）
//    - 背光控制直接调用 DisplayServices，不再依赖 Python3
//    - 免密配置只允许当前账户执行两条固定命令，每个账户一个文件
//    - 不再改动用户自己的显示器/硬盘睡眠时间
//
//  编译：见 scripts/build.sh
//
//  作者：龙皇
// ============================================================

import Cocoa
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import ServiceManagement
import UserNotifications

// ============================================================
// MARK: - 日志（~/Library/Logs/合盖不休眠.log，超过 512KB 轮换）
// ============================================================

enum Log {
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("合盖不休眠.log")
    }()
    private static let queue = DispatchQueue(label: "nosleep.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
    static var disabled = false

    static func write(_ message: String) {
        let now = Date()
        queue.async {
            guard !disabled else { return }
            let line = "[\(formatter.string(from: now))] \(message)\n"
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 512 * 1024 {
                let old = url.appendingPathExtension("old")
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            let data = Data(line.utf8)
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// 同步等待日志写完（退出前调用）
    static func flush() { queue.sync {} }

    /// 卸载时删除日志并停止写入
    static func removeAll() {
        queue.sync {
            disabled = true
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("old"))
        }
    }
}

// ============================================================
// MARK: - 运行外部命令
// ============================================================

@discardableResult
func run(_ path: String, _ args: [String]) -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    process.standardInput = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return (-1, "\(error)")
    }
    // 先读完输出再等待退出，避免输出较多时管道写满导致互相等待
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

// ============================================================
// MARK: - 电源状态（直接读 IOPMrootDomain，不启动子进程）
// ============================================================

enum Power {
    static let rootDomain: io_service_t = IOServiceGetMatchingService(0, IOServiceMatching("IOPMrootDomain"))

    private static func boolProperty(_ key: String) -> Bool? {
        guard rootDomain != 0,
              let value = IORegistryEntryCreateCFProperty(rootDomain, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        else { return nil }
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        return nil
    }

    /// 合盖状态；台式机没有这个属性，返回 nil
    static var lidClosed: Bool? { boolProperty("AppleClamshellState") }

    /// 合盖是否会让系统睡眠（接外接显示器的「合盖模式」下为 false，此时系统自己会关内建屏）
    static var clamshellCausesSleep: Bool { boolProperty("AppleClamshellCausesSleep") ?? true }

    /// 系统级 SleepDisabled（即 pmset disablesleep）。两种方式都读不到时为 nil。
    static var sleepDisabledReading: Bool? {
        if let value = boolProperty("SleepDisabled") { return value }
        // 兜底：解析 pmset -g
        let out = run("/usr/bin/pmset", ["-g"]).output
        for line in out.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2, parts[0] == "SleepDisabled" { return parts[1] == "1" }
        }
        return nil
    }

    static var sleepDisabled: Bool { sleepDisabledReading ?? false }

    /// 确认已经关闭（读不到时不算）
    static var sleepConfirmedEnabled: Bool { sleepDisabledReading == false }

    /// 读取 `pmset -g custom`，返回 [电源名: [键: 值]]
    static func customSettings() -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        var section = ""
        for raw in run("/usr/bin/pmset", ["-g", "custom"]).output.split(separator: "\n") {
            let line = String(raw)
            if line.hasSuffix(":") && !line.hasPrefix(" ") {
                section = String(line.dropLast())
                result[section] = [:]
                continue
            }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2, !section.isEmpty {
                result[section]?[String(parts[0])] = String(parts[1])
            }
        }
        return result
    }

    enum LegacyTimers { case none, allNever, v16Off }

    /// 旧版（≤1.6）开启时把 sleep/displaysleep/disksleep 全部设成 0（永不），
    /// 关闭时又在所有电源下统一设成 1/10/10。识别这两种痕迹。
    static func legacyTimers() -> LegacyTimers {
        let settings = customSettings()
        guard !settings.isEmpty else { return .none }
        func all(_ sleep: String, _ display: String, _ disk: String) -> Bool {
            settings.values.allSatisfy { $0["sleep"] == sleep && $0["displaysleep"] == display && $0["disksleep"] == disk }
        }
        if all("0", "0", "0") { return .allNever }
        // 接电源时 1/10/10 本来就是默认值，只有电池下也是 1/10/10 才算旧版痕迹
        if settings["Battery Power"] != nil && all("1", "10", "10") { return .v16Off }
        return .none
    }

    /// 电池状态：是否在用电池、电量百分比
    static func battery() -> (onBattery: Bool, percent: Int)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  desc[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            return (providing == kIOPSBatteryPowerValue, current * 100 / max)
        }
        return nil
    }
}

// ============================================================
// MARK: - 免密配置（sudoers）
// ============================================================

enum Privileged {
    /// 旧版（≤1.6）的配置：任何账户都能免密执行任意 pmset
    static let legacyPath = "/etc/sudoers.d/nosleep"
    static let legacyRule = "ALL ALL=NOPASSWD: /usr/bin/pmset"

    /// 每个账户一个文件，多账户的 Mac 上互不覆盖。文件名不能带「.」，否则 sudo 不读。
    static var rulePath: String { "/etc/sudoers.d/nosleep-\(getuid())" }
    private static var tempPath: String { "/etc/sudoers.d/.nosleep-\(getuid()).tmp" }

    /// 只允许当前账户（按 UID）以 root 执行这两条固定命令
    static var expectedRule: String {
        "#\(getuid()) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
    }

    /// 文件是 0444，普通用户可读，不用 sudo 就能比对内容
    private static func read(_ path: String) -> String? {
        (try? String(contentsOfFile: path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static var ownRuleInstalled: Bool { read(rulePath) == expectedRule }
    static var legacyRulePresent: Bool { read(legacyPath) == legacyRule }

    /// 设置 SleepDisabled（免密 sudo）。
    /// 开启与关闭均需核对读回值：读不到时开启按命令退出码成功、关闭按失败处理；
    /// 若明确读到相反的值，说明系统未生效，返回 false 由调用方重试。
    static func setSleepDisabled(_ on: Bool) -> Bool {
        let r = run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"])
        guard r.status == 0 else {
            Log.write("pmset disablesleep \(on ? 1 : 0) 失败 (\(r.status)): \(r.output)")
            return false
        }
        // 系统属性可能稍晚才更新：开启最多等 2 秒，关闭最多等 3 秒
        for _ in 0..<(on ? 40 : 60) where Power.sleepDisabledReading != on { Thread.sleep(forTimeInterval: 0.05) }
        if let reading = Power.sleepDisabledReading {
            if reading == on { return true }
            Log.write("⚠️ pmset 已执行，但 SleepDisabled 仍为 \(reading)（期望 \(on)）")
            return false
        }
        Log.write("⚠️ pmset 已执行，但无法读回 SleepDisabled 状态")
        return on
    }

    /// 用系统的管理员授权窗口执行一段 shell。返回 nil 表示成功；用户点取消返回 "cancel"。
    /// 只能在主线程调用。
    static func runAsAdmin(_ script: String, prompt: String) -> String? {
        guard let appleScript = NSAppleScript(source: appleScriptSource(script, prompt: prompt)) else {
            return "无法创建授权脚本"
        }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
        guard let error = error else { return nil }
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { return "cancel" }
        return (error[NSAppleScript.errorMessage] as? String) ?? "未知错误"
    }

    static func appleScriptSource(_ script: String, prompt: String) -> String {
        func quote(_ s: String) -> String {
            "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        // 多行脚本合成一行，避免 AppleScript 改写换行符
        let oneLine = script.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: "; ")
        return "do shell script \(quote(oneLine)) with prompt \(quote(prompt)) with administrator privileges"
    }

    /// macOS 笔记本默认值：电池 2 分钟关显示器，接电源 10 分钟；系统睡眠 1；硬盘 10
    private static let restoreDefaultTimers = """
        /usr/bin/pmset -b sleep 1 displaysleep 2 disksleep 10 || true
        /usr/bin/pmset -c sleep 1 displaysleep 10 disksleep 10 || true
        """

    /// 仅当旧文件内容正是旧版规则时才删除（别人手写的同名文件不动）
    private static var removeLegacyRule: String {
        "if [ \"$(/bin/cat \(legacyPath) 2>/dev/null)\" = '\(legacyRule)' ]; then /bin/rm -f \(legacyPath); fi"
    }

    /// 安装/升级免密配置。先写临时文件，visudo 校验通过才替换，避免写坏 sudo。
    static func installScript(restoreTimers: Bool) -> String {
        var script = """
        set -e
        T=\(tempPath)
        /bin/rm -f "$T"
        /usr/bin/printf '%s\\n' '\(expectedRule)' > "$T"
        /usr/sbin/chown root:wheel "$T"
        /bin/chmod 0444 "$T"
        if /usr/sbin/visudo -cf "$T" >/dev/null 2>&1; then /bin/mv -f "$T" \(rulePath); else /bin/rm -f "$T"; exit 1; fi
        \(removeLegacyRule)
        """
        if restoreTimers { script += "\n" + restoreDefaultTimers }
        return script
    }

    /// 卸载：恢复休眠 + 删除本账户的免密配置（以及旧版遗留的配置）
    static func uninstallScript(restoreTimers: Bool) -> String {
        var script = "/usr/bin/pmset -a disablesleep 0 || true"
        if restoreTimers { script += "\n" + restoreDefaultTimers }
        script += "\n/bin/rm -f \(rulePath) \(tempPath)\n\(removeLegacyRule)"
        return script
    }

    /// 安装，并确认文件确实装好了
    static func install(restoreTimers: Bool, prompt: String) -> String? {
        if let err = runAsAdmin(installScript(restoreTimers: restoreTimers), prompt: prompt) { return err }
        return ownRuleInstalled ? nil : "配置文件没有写入成功"
    }
}

// ============================================================
// MARK: - 背光控制（DisplayServices 私有框架，Intel / Apple 芯片通用）
// ============================================================

final class Backlight {
    private typealias GetFn = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetFn = @convention(c) (UInt32, Float) -> Int32
    private let getFn: GetFn?
    private let setFn: SetFn?
    private let defaults = UserDefaults.standard
    private var cachedBuiltin: CGDirectDisplayID?
    private var restoreFailing = false
    private var lastRestore: (display: CGDirectDisplayID, value: Float)?

    // 关屏前的亮度存进偏好设置，App 意外退出后下次启动也能恢复
    static let savedKey = "dimmedBrightness"
    static let savedDisplayKey = "dimmedDisplay"

    init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
        if let handle = handle,
           let g = dlsym(handle, "DisplayServicesGetBrightness"),
           let s = dlsym(handle, "DisplayServicesSetBrightness") {
            getFn = unsafeBitCast(g, to: GetFn.self)
            setFn = unsafeBitCast(s, to: SetFn.self)
        } else {
            getFn = nil
            setFn = nil
            Log.write("⚠️ 无法加载 DisplayServices，合盖关屏不可用")
        }
    }

    var available: Bool { getFn != nil && setFn != nil }
    var isDimmed: Bool { defaults.object(forKey: Self.savedKey) != nil }

    /// 找内建屏幕（合盖时外接显示器可能是主屏，不能用主屏 ID）
    @discardableResult
    func builtinDisplay() -> CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        if CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count) == .success {
            for id in ids.prefix(Int(count)) where CGDisplayIsBuiltin(id) != 0 {
                cachedBuiltin = id
                return id
            }
        }
        return cachedBuiltin
    }

    func brightness(_ display: CGDirectDisplayID) -> Float? {
        guard let getFn = getFn else { return nil }
        var value: Float = 0
        return getFn(display, &value) == 0 ? value : nil
    }

    /// 记下要恢复的亮度（迁移旧版缓存时用）
    func markDimmed(saved: Float, display: CGDirectDisplayID) {
        defaults.set(Double(saved), forKey: Self.savedKey)
        defaults.set(Int(display), forKey: Self.savedDisplayKey)
    }

    /// 关背光。已经关了返回 true。
    @discardableResult
    func dim() -> Bool {
        if isDimmed { return true }
        guard let setFn = setFn else { return false }
        guard let display = builtinDisplay(), let current = brightness(display) else {
            Log.write("合盖 → 找不到内建屏幕或读不到亮度，暂不关背光")
            return false
        }
        markDimmed(saved: current, display: display)
        guard setFn(display, 0) == 0 else {
            Log.write("合盖 → 关背光失败")
            clearSaved()
            return false
        }
        Log.write("合盖 → 关背光（原亮度 \(String(format: "%.2f", current))）")
        return true
    }

    /// 恢复背光。只有读回的亮度确实不为 0 才算成功、才清除记录；失败时保留记录，由调用方稍后重试。
    /// 盖子合着时不要唤醒显示器（wakeDisplay = false），免得屏幕在合着的盖子里亮着。
    @discardableResult
    func restore(wakeDisplay: Bool = true) -> Bool {
        guard isDimmed else { return true }
        guard let setFn = setFn else { clearSaved(); return true }
        let saved = Float(defaults.double(forKey: Self.savedKey))
        let target = saved.isFinite && saved > 0.02 ? min(saved, 1) : 0.5
        let display = builtinDisplay() ?? CGDirectDisplayID(defaults.integer(forKey: Self.savedDisplayKey))
        let setOK = setFn(display, target) == 0
        let readBack = brightness(display) ?? 0
        guard setOK && readBack > 0.01 else {
            if !restoreFailing { Log.write("恢复背光失败（显示器可能还没准备好），稍后重试") }
            restoreFailing = true
            return false
        }
        restoreFailing = false
        clearSaved()
        lastRestore = (display, target)
        Log.write("恢复背光 \(String(format: "%.2f", target))")
        guard wakeDisplay else { return true }
        // 相当于 caffeinate -u：唤醒可能已经睡眠的显示器
        var assertion: IOPMAssertionID = 0
        if IOPMAssertionDeclareUserActivity("合盖不休眠：开盖" as CFString, kIOPMUserActiveLocal, &assertion) == kIOReturnSuccess {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { IOPMAssertionRelease(assertion) }
        }
        return true
    }

    /// 恢复后过一会儿再确认一次：如果系统又把亮度改回了 0，重新设置
    func reassertLastRestore() {
        guard !isDimmed, let last = lastRestore, let setFn = setFn else { return }
        lastRestore = nil
        if let now = brightness(last.display), now < 0.01 {
            Log.write("恢复后亮度又变成 0，重新设置")
            _ = setFn(last.display, last.value)
        }
    }

    private func clearSaved() {
        defaults.removeObject(forKey: Self.savedKey)
        defaults.removeObject(forKey: Self.savedDisplayKey)
    }
}

// ============================================================
// MARK: - 合盖监听（IOKit 事件 + 1 秒兜底检查，都在进程内）
// ============================================================

/// kIOPMMessageClamshellStateChange = iokit_family_msg(sub_iokit_powermanagement, 0x100)
private let kClamshellStateChangeMessage: UInt32 = 0xE003_4100

final class LidWatcher {
    var onChange: ((_ closed: Bool) -> Void)?
    /// 每秒调用一次，用于重试失败的关/开背光
    var onTick: (() -> Void)?
    private(set) var lastClosed: Bool?
    private var port: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private var pollTimer: Timer?

    var isRunning: Bool { pollTimer != nil }

    func start() {
        guard pollTimer == nil else { return }
        lastClosed = nil
        if let port = IONotificationPortCreate(0) {
            self.port = port
            IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            let kr = IOServiceAddInterestNotification(port, Power.rootDomain, kIOGeneralInterest, { refcon, _, messageType, _ in
                guard messageType == kClamshellStateChangeMessage, let refcon = refcon else { return }
                Unmanaged<LidWatcher>.fromOpaque(refcon).takeUnretainedValue().check()
            }, refcon, &notifier)
            if kr != KERN_SUCCESS { Log.write("⚠️ 合盖事件注册失败 (\(kr))，仅使用轮询") }
        }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.check()
            self?.onTick?()
        }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        check()
    }

    /// 可能在自己的回调里被调用，所以推迟到下一轮再真正释放 IOKit 对象
    func stop() {
        guard pollTimer != nil else { return }
        pollTimer?.invalidate()
        pollTimer = nil
        lastClosed = nil
        let oldNotifier = notifier, oldPort = port
        notifier = 0
        port = nil
        DispatchQueue.main.async { [self] in
            if oldNotifier != 0 { IOObjectRelease(oldNotifier) }
            if let p = oldPort { IONotificationPortDestroy(p) }
            withExtendedLifetime(self) {}
        }
    }

    deinit {
        pollTimer?.invalidate()
        if notifier != 0 { IOObjectRelease(notifier) }
        if let p = port { IONotificationPortDestroy(p) }
    }

    func check() {
        guard pollTimer != nil, let closed = Power.lidClosed, closed != lastClosed else { return }
        lastClosed = closed
        onChange?(closed)
    }
}

// ============================================================
// MARK: - 电源变化监听（插拔电源、电量变化时由系统回调）
// ============================================================

final class PowerSourceWatcher {
    var onChange: (() -> Void)?
    private var source: CFRunLoopSource?

    var isRunning: Bool { source != nil }

    func start() {
        guard source == nil else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let src = IOPSNotificationCreateRunLoopSource({ refcon in
            guard let refcon = refcon else { return }
            Unmanaged<PowerSourceWatcher>.fromOpaque(refcon).takeUnretainedValue().onChange?()
        }, refcon)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        source = src
    }

    func stop() {
        if let src = source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            CFRunLoopSourceInvalidate(src)
        }
        source = nil
    }

    deinit {
        stop()
    }
}

// ============================================================
// MARK: - 菜单栏控制器
// ============================================================

final class MenuBarController: NSObject, NSMenuDelegate {
    enum OffReason: String { case user = "手动", timer = "定时", battery = "低电量" }

    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    let timerSubMenu = NSMenu()
    let batterySubMenu = NSMenu()
    let statusMenuItem = NSMenuItem(title: "检测中…", action: nil, keyEquivalent: "")
    let detailMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let toggleMenuItem = NSMenuItem(title: "开启合盖不休眠", action: #selector(toggleFeature), keyEquivalent: "")
    let cancelPauseMenuItem = NSMenuItem(title: "取消自动恢复（保持关闭）", action: #selector(cancelLowBatteryPause), keyEquivalent: "")
    let timerMenuItem = NSMenuItem(title: "定时关闭", action: nil, keyEquivalent: "")
    let cancelTimerMenuItem = NSMenuItem(title: "取消定时", action: #selector(cancelAutoOff), keyEquivalent: "")
    let batteryMenuItem = NSMenuItem(title: "低电量保护", action: nil, keyEquivalent: "")
    let loginMenuItem = NSMenuItem(title: "开机自动启动", action: #selector(toggleLoginItem), keyEquivalent: "")

    let backlight = Backlight()
    let lidWatcher = LidWatcher()
    let powerWatcher = PowerSourceWatcher()
    let defaults = UserDefaults.standard

    private(set) var isOn = false
    private var busy = false
    private var pendingOffReason: OffReason?
    private var terminating = false
    private var uninstalled = false
    var userQuit = false
    private var idleAssertion: IOPMAssertionID = 0
    private var countdownTimer: Timer?
    private var statusTimer: Timer?
    private var pendingDim: DispatchWorkItem?
    private var pendingRestore: DispatchWorkItem?
    private var dimFailures = 0
    private var batteryArmed = true
    private var timerRetryAt: Date?
    private let workQueue = DispatchQueue(label: "nosleep.work")

    static let restoreOnLaunchKey = "restoreOnLaunch"
    static let pausedForLowBatteryKey = "pausedForLowBattery"
    static var restoreRetryDelay: TimeInterval = 2.0

    private let timerOptions: [(String, Int)] = [("30 分钟", 30), ("1 小时", 60), ("2 小时", 120), ("4 小时", 240), ("8 小时", 480)]
    private let batteryOptions: [(String, Int)] = [("电量低于 10% 时自动关闭", 10), ("电量低于 20% 时自动关闭", 20), ("电量低于 30% 时自动关闭", 30), ("不启用", 0)]

    /// 非手动退出（如系统重启/更新/注销/升级替换）后，下次启动是否自动恢复开启
    var shouldRestoreOnLaunch: Bool {
        get { (defaults.object(forKey: Self.restoreOnLaunchKey) as? Bool) ?? false }
        set {
            if newValue { defaults.set(true, forKey: Self.restoreOnLaunchKey) }
            else { defaults.removeObject(forKey: Self.restoreOnLaunchKey) }
        }
    }

    /// 低电量保护临时暂停中：接通电源或电量恢复到阈值以上后自动重新开启
    var pausedForLowBattery: Bool {
        get { (defaults.object(forKey: Self.pausedForLowBatteryKey) as? Bool) ?? false }
        set {
            if newValue { defaults.set(true, forKey: Self.pausedForLowBatteryKey) }
            else { defaults.removeObject(forKey: Self.pausedForLowBatteryKey) }
        }
    }

    var deadline: Date? {
        get {
            let t = defaults.double(forKey: "autoOffDeadline")
            return t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
        set {
            if let d = newValue { defaults.set(d.timeIntervalSince1970, forKey: "autoOffDeadline") }
            else { defaults.removeObject(forKey: "autoOffDeadline") }
        }
    }

    var batteryThreshold: Int {
        get { defaults.object(forKey: "batteryThreshold") as? Int ?? 20 }
        set { defaults.set(newValue, forKey: "batteryThreshold") }
    }

    // ------------------------------------------------------------
    // MARK: 启动
    // ------------------------------------------------------------

    override init() {
        super.init()
        lidWatcher.onChange = { [weak self] closed in self?.lidChanged(closed: closed) }
        lidWatcher.onTick = { [weak self] in self?.lidTick() }
        powerWatcher.onChange = { [weak self] in self?.checkBattery() }
        setupMenu()
        cleanupLegacy()

        // 意外退出后留下的黑屏：开盖状态下立即恢复
        if backlight.isDimmed && Power.lidClosed != true { backlight.restore() }

        // 系统里已经是开启状态（App 崩溃后重新打开、旧版被强制退出等）→ 接管，继续合盖关屏
        isOn = Power.sleepDisabled
        if isOn {
            pausedForLowBattery = false
            shouldRestoreOnLaunch = true
            Log.write("启动时检测到已开启，接管合盖监听")
            startProtection()
            // tick() 会处理已经过期的定时（立即关闭，失败则每 30 秒重试）
            if deadline != nil {
                startCountdown()
                tick()
            }
        } else if shouldRestoreOnLaunch || pausedForLowBattery {
            // 屏幕还是黑的（盖子合着或恢复失败）：先保持监听，等开盖时恢复
            if backlight.isDimmed { lidWatcher.start() }
            if let d = deadline, d.timeIntervalSinceNow <= 0 {
                Log.write("启动时原定时已到期，不再自动恢复")
                deadline = nil
                pausedForLowBattery = false
                shouldRestoreOnLaunch = false
                powerWatcher.stop()
            } else if let b = Power.battery(), b.onBattery, batteryThreshold > 0, b.percent <= batteryThreshold {
                Log.write("启动时电量 \(b.percent)% ≤ \(batteryThreshold)%，保持低电量暂停等待电源恢复")
                pausedForLowBattery = true
                shouldRestoreOnLaunch = true
                powerWatcher.start()
                notify("电量低（已暂停）", "当前电量 \(b.percent)%，合盖不休眠已暂停；接通电源或电量恢复后将自动重新开启")
            } else if !(Privileged.ownRuleInstalled || Privileged.legacyRulePresent) {
                Log.write("启动时缺少免密配置，无法自动恢复")
                deadline = nil
                pausedForLowBattery = false
                shouldRestoreOnLaunch = false
                powerWatcher.stop()
                notify("合盖不休眠未自动恢复", "缺少免密配置，请点击菜单栏重新开启")
            } else {
                let wasPaused = pausedForLowBattery
                Log.write(wasPaused ? "启动时电源/电量已恢复，正在自动恢复合盖不休眠" : "检测到重启/重新打开前曾开启，正在自动恢复合盖不休眠")
                restoreOnLaunch(attempt: 1, fromBatteryPause: wasPaused)
            }
        } else {
            deadline = nil
            // 屏幕还是黑的（盖子合着或恢复失败）：继续监听，等开盖时恢复
            if backlight.isDimmed { lidWatcher.start() }
        }
        updateUI()

        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in self?.syncWithSystem() }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer

        let wsCenter = NSWorkspace.shared.notificationCenter
        wsCenter.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)
        wsCenter.addObserver(self, selector: #selector(displayMayBeBack), name: NSWorkspace.screensDidWakeNotification, object: nil)
        wsCenter.addObserver(self, selector: #selector(systemWillPowerOff), name: NSWorkspace.willPowerOffNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(displayMayBeBack), name: NSApplication.didChangeScreenParametersNotification, object: nil)

        // 从旧版升级：把「所有账户免密执行任意 pmset」收紧
        if Privileged.legacyRulePresent {
            let declined = defaults.double(forKey: "upgradeDeclinedAt")
            if declined == 0 || Date().timeIntervalSince1970 - declined > 7 * 24 * 3600 {
                DispatchQueue.main.async { [weak self] in self?.offerSecurityUpgrade() }
            }
        }
    }

    deinit {
        pendingRestore?.cancel()
        pendingDim?.cancel()
        countdownTimer?.invalidate()
        statusTimer?.invalidate()
        lidWatcher.stop()
        powerWatcher.stop()
        if idleAssertion != 0 { IOPMAssertionRelease(idleAssertion) }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    /// 清理 v1.6 及更早版本留在 /tmp 的脚本、进程和文件（只处理属于自己的）
    private func cleanupLegacy() {
        let fm = FileManager.default
        func ownedByMe(_ path: String) -> Bool {
            ((try? fm.attributesOfItem(atPath: path))?[.ownerAccountID] as? NSNumber)?.uint32Value == getuid()
        }
        if ownedByMe("/tmp/nosleep_lidwatch.sh") || ownedByMe("/tmp/nosleep_lidwatch.pid") {
            run("/usr/bin/pkill", ["-U", "\(getuid())", "-x", "-f", "/bin/bash /tmp/nosleep_lidwatch.sh"])
            Log.write("已停止旧版合盖监听脚本")
        }
        // 旧版把背光关了还没恢复：把旧缓存的亮度接过来，开盖时恢复
        if ownedByMe("/tmp/nosleep_brightness"), ownedByMe("/tmp/nosleep_brightness_cache"),
           (try? String(contentsOfFile: "/tmp/nosleep_brightness", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) == "off",
           let cached = try? String(contentsOfFile: "/tmp/nosleep_brightness_cache", encoding: .utf8),
           let value = Float(cached.trimmingCharacters(in: .whitespacesAndNewlines)), value.isFinite {
            backlight.markDimmed(saved: min(max(value, 0), 1), display: backlight.builtinDisplay() ?? 1)
            Log.write("接管旧版关掉的背光")
        }
        for path in ["/tmp/nosleep_lidwatch.sh", "/tmp/nosleep_lidwatch.pid", "/tmp/nosleep_lidwatch.lock",
                     "/tmp/nosleep_brightness", "/tmp/nosleep_brightness_cache", "/tmp/nosleep_menulet.log", "/tmp/nosleep_debug.log"]
        where ownedByMe(path) {
            try? fm.removeItem(atPath: path)
        }
    }

    func setupMenu() {
        // 自己管理菜单项的可用状态（默认 autoenablesItems 会忽略 isEnabled）
        for m in [menu, timerSubMenu, batterySubMenu] { m.autoenablesItems = false }

        statusItem.button?.toolTip = "合盖不休眠"
        setIcon(on: false)

        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        detailMenuItem.isEnabled = false
        detailMenuItem.isHidden = true
        menu.addItem(detailMenuItem)
        menu.addItem(NSMenuItem.separator())

        toggleMenuItem.target = self
        menu.addItem(toggleMenuItem)

        cancelPauseMenuItem.target = self
        cancelPauseMenuItem.isHidden = true
        menu.addItem(cancelPauseMenuItem)

        for (label, minutes) in timerOptions {
            let item = NSMenuItem(title: label, action: #selector(setAutoOff(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = minutes
            timerSubMenu.addItem(item)
        }
        timerSubMenu.addItem(NSMenuItem.separator())
        cancelTimerMenuItem.target = self
        timerSubMenu.addItem(cancelTimerMenuItem)
        timerMenuItem.submenu = timerSubMenu
        menu.addItem(timerMenuItem)

        for (label, percent) in batteryOptions {
            let item = NSMenuItem(title: label, action: #selector(setBatteryThreshold(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = percent
            batterySubMenu.addItem(item)
        }
        batteryMenuItem.submenu = batterySubMenu
        menu.addItem(batteryMenuItem)

        menu.addItem(NSMenuItem.separator())
        if #available(macOS 13.0, *) {
            loginMenuItem.target = self
            menu.addItem(loginMenuItem)
        }
        let about = NSMenuItem(title: "关于", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        let quit = NSMenuItem(title: "退出（同时关闭合盖不休眠）", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        menu.addItem(NSMenuItem.separator())

        let uninstall = NSMenuItem(title: "卸载并退出", action: #selector(uninstallApp), keyEquivalent: "")
        uninstall.target = self
        uninstall.attributedTitle = NSAttributedString(string: "卸载并退出", attributes: [
            .foregroundColor: NSColor.systemRed,
            .font: NSFont.menuFont(ofSize: 0),
        ])
        menu.addItem(uninstall)

        menu.delegate = self
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        syncWithSystem()
        updateUI()
    }

    // ------------------------------------------------------------
    // MARK: 开 / 关
    // ------------------------------------------------------------

    @objc func toggleFeature() {
        if isOn { turnOff(reason: .user) } else { turnOn() }
    }

    @objc func cancelLowBatteryPause() {
        guard !busy else { return }
        cancelPendingRestore()
        pausedForLowBattery = false
        shouldRestoreOnLaunch = false
        cancelCountdown()
        powerWatcher.stop()
        Log.write("已取消低电量自动恢复（手动）")
        updateUI()
    }

    /// 确保免密配置可用；需要时弹出系统授权窗口。返回 false 表示用户取消或失败。
    private func ensureSetup() -> Bool {
        if Privileged.ownRuleInstalled || Privileged.legacyRulePresent { return true }
        let err = Privileged.install(
            restoreTimers: false,
            prompt: "「合盖不休眠」需要配置一次管理员授权，以后开关不再需要输入密码。授权只允许你的账户执行「开启/关闭合盖不休眠」这两条命令。")
        if err == nil { Log.write("免密配置完成"); return true }
        if err != "cancel" { showAlert("免密配置失败", err ?? "") }
        return false
    }

    func turnOn(then completion: (() -> Void)? = nil) {
        guard !busy, !isOn else { return }
        cancelPendingRestore()
        guard ensureSetup() else { return }
        var lowBatteryConsent = false
        if let b = Power.battery(), b.onBattery, batteryThreshold > 0, b.percent <= batteryThreshold {
            let alert = NSAlert()
            alert.messageText = "电量只剩 \(b.percent)%"
            alert.informativeText = "低电量保护设为 \(batteryThreshold)%。如果仍然开启，这次不会因为电量低而自动关闭，直到接上电源或电量回到 \(batteryThreshold)% 以上。"
            alert.addButton(withTitle: "仍然开启")
            alert.addButton(withTitle: "取消")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() != .alertFirstButtonReturn { return }
            lowBatteryConsent = true
        }
        busy = true
        updateUI()
        workQueue.async { [weak self] in
            let ok = Privileged.setSleepDisabled(true)
            DispatchQueue.main.async {
                guard let self = self, !self.terminating else { return }
                self.busy = false
                if ok {
                    self.isOn = true
                    self.pausedForLowBattery = false
                    self.shouldRestoreOnLaunch = true
                    Log.write("已开启")
                    if completion == nil { self.cancelCountdown() }   // 普通开启不继承旧的定时
                    self.startProtection(lowBatteryConsent: lowBatteryConsent)
                    completion?()
                } else {
                    self.showAlert("开启失败", "无法修改系统休眠设置。请尝试「卸载并退出」后重新打开 App，再授权一次。\n\n日志：\(Log.url.path)")
                }
                self.updateUI()
            }
        }
    }

    /// 重启/注销/升级或低电量暂停恢复后自动开启（最多尝试 3 次，避免开机/唤醒初期 powerd 尚未就绪）
    private func restoreOnLaunch(attempt: Int, fromBatteryPause: Bool = false) {
        guard !terminating, !isOn, (shouldRestoreOnLaunch || pausedForLowBattery) else { return }
        if let d = deadline, d.timeIntervalSinceNow <= 0 {
            Log.write("恢复期间原定时已到期，取消自动恢复")
            deadline = nil
            pausedForLowBattery = false
            shouldRestoreOnLaunch = false
            powerWatcher.stop()
            updateUI()
            return
        }
        if let b = Power.battery(), b.onBattery, batteryThreshold > 0, b.percent <= batteryThreshold {
            Log.write("恢复期间电量 \(b.percent)% ≤ \(batteryThreshold)%，保持低电量暂停等待电源恢复")
            pausedForLowBattery = true
            shouldRestoreOnLaunch = true
            powerWatcher.start()
            notify("电量低（已暂停）", "当前电量 \(b.percent)%，合盖不休眠已暂停；接通电源或电量恢复后将自动重新开启")
            updateUI()
            return
        }
        guard Privileged.ownRuleInstalled || Privileged.legacyRulePresent else {
            Log.write("恢复期间缺少免密配置，无法自动恢复")
            deadline = nil
            pausedForLowBattery = false
            shouldRestoreOnLaunch = false
            powerWatcher.stop()
            notify("合盖不休眠未自动恢复", "缺少免密配置，请点击菜单栏重新开启")
            updateUI()
            return
        }
        busy = true
        updateUI()
        workQueue.async { [weak self] in
            let ok = Privileged.setSleepDisabled(true)
            DispatchQueue.main.async {
                guard let self = self, !self.terminating else { return }
                self.busy = false
                if ok {
                    self.isOn = true
                    self.pausedForLowBattery = false
                    self.shouldRestoreOnLaunch = true
                    if fromBatteryPause {
                        Log.write("电源/电量已恢复，自动重新开启合盖不休眠")
                        self.notify("合盖不休眠已自动恢复", "电源或电量已恢复，合盖不休眠已重新开启")
                    } else {
                        Log.write("重启/重新打开后已自动恢复开启")
                    }
                    self.startProtection()
                    if self.deadline != nil {
                        self.startCountdown()
                        self.tick()
                    }
                } else if attempt < 3 {
                    Log.write("⚠️ 自动恢复开启失败（第 \(attempt) 次），稍后重试")
                    let work = DispatchWorkItem { [weak self] in
                        self?.pendingRestore = nil
                        self?.restoreOnLaunch(attempt: attempt + 1, fromBatteryPause: fromBatteryPause)
                    }
                    self.pendingRestore = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreRetryDelay, execute: work)
                } else {
                    Log.write("⚠️ 自动恢复合盖不休眠失败（已重试 3 次），请手动开启")
                    self.deadline = nil
                    self.pausedForLowBattery = false
                    self.shouldRestoreOnLaunch = false
                    self.powerWatcher.stop()
                    self.notify("合盖不休眠未能自动恢复", fromBatteryPause ? "电源恢复后重新开启失败，请点击菜单栏图标手动开启" : "重启后恢复失败，请点击菜单栏图标重新开启")
                }
                self.updateUI()
            }
        }
    }

    private func cancelPendingRestore() {
        pendingRestore?.cancel()
        pendingRestore = nil
    }

    func turnOff(reason: OffReason) {
        guard !busy, isOn else { return }
        busy = true
        pendingOffReason = reason
        updateUI()
        workQueue.async { [weak self] in
            let ok = Privileged.setSleepDisabled(false)
            DispatchQueue.main.async {
                guard let self = self, !self.terminating else { return }
                self.busy = false
                self.pendingOffReason = nil
                // 再读一次：系统属性更新慢时，命令其实已经生效
                if ok || Power.sleepConfirmedEnabled {
                    self.isOn = false
                    // 盖子合着时自动关闭：让电脑立即睡眠（外接显示器的合盖模式除外）。
                    // 睡眠前先恢复亮度，这样唤醒后不需要再做任何事。
                    let willSleep = reason != .user && Power.lidClosed == true && Power.clamshellCausesSleep
                    if reason == .battery {
                        if let d = self.deadline, d.timeIntervalSinceNow <= 0 {
                            self.cancelCountdown()
                            self.pausedForLowBattery = false
                            self.shouldRestoreOnLaunch = false
                            Log.write("已关闭（低电量，且原定时已到期）")
                            self.stopProtection(restoreWhileClosed: willSleep, keepPowerWatcher: false)
                            self.notify("电量低", "合盖不休眠已自动关闭，避免电池耗尽")
                        } else {
                            self.pauseCountdown()
                            self.pausedForLowBattery = true
                            self.shouldRestoreOnLaunch = true
                            Log.write("已暂停（低电量，电源恢复后自动重新开启）")
                            self.stopProtection(restoreWhileClosed: willSleep, keepPowerWatcher: true)
                            self.notify("电量低（已暂停）", "合盖不休眠已临时暂停以保护电池；接通电源或电量恢复后将自动重新开启")
                        }
                    } else {
                        self.pausedForLowBattery = false
                        self.shouldRestoreOnLaunch = false
                        self.cancelCountdown()
                        Log.write("已关闭（\(reason.rawValue)）")
                        self.stopProtection(restoreWhileClosed: willSleep, keepPowerWatcher: false)
                        if reason == .timer {
                            self.notify("定时到", "合盖不休眠已自动关闭，电脑恢复正常休眠")
                        }
                    }
                    if willSleep {
                        Log.write("盖子合着，让电脑进入睡眠")
                        DispatchQueue.global().async { run("/usr/bin/pmset", ["sleepnow"]) }
                    }
                } else {
                    switch reason {
                    case .user:
                        self.showAlert("关闭失败", "无法恢复系统休眠设置。可以在终端执行：\nsudo pmset -a disablesleep 0")
                    case .timer:
                        if self.timerRetryAt == nil { self.notify("定时关闭失败", "将每 30 秒重试一次") }
                        self.timerRetryAt = Date().addingTimeInterval(30)
                    case .battery:
                        self.batteryArmed = true   // 下次电量变化时重试
                    }
                }
                self.updateUI()
            }
        }
    }

    private func ensureIdleAssertion() {
        guard idleAssertion == 0 else { return }
        var id: IOPMAssertionID = 0
        let kr = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                             IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                             "合盖不休眠" as CFString, &id)
        if kr == kIOReturnSuccess && id != 0 {
            idleAssertion = id
        } else {
            Log.write("⚠️ 创建防空闲睡眠断言失败 (\(kr))")
        }
    }

    /// 开启后的保护：阻止空闲睡眠 + 合盖关屏 + 低电量检查
    private func startProtection(lowBatteryConsent: Bool = false) {
        ensureIdleAssertion()
        backlight.builtinDisplay()   // 开盖时先记下内建屏幕 ID，合盖后可能查不到
        lidWatcher.start()
        powerWatcher.start()
        // 只有用户在低电量提示里点了「仍然开启」才暂停保护；接管已开启的状态时照常检查
        batteryArmed = !lowBatteryConsent
        checkBattery()
    }

    /// restoreWhileClosed：盖子合着也立即恢复亮度（只用于马上要睡眠的情况）。
    /// 否则盖子合着时保持黑屏，等开盖再恢复。
    /// keepPowerWatcher：低电量暂停时保持电源监听，以便插电或充电后自动恢复。
    private func stopProtection(restoreWhileClosed: Bool = false, keepPowerWatcher: Bool = false) {
        if idleAssertion != 0 {
            IOPMAssertionRelease(idleAssertion)
            idleAssertion = 0
        }
        if keepPowerWatcher {
            powerWatcher.start()
        } else {
            powerWatcher.stop()
        }
        pendingDim?.cancel()
        pendingDim = nil
        dimFailures = 0
        if backlight.isDimmed {
            let closed = Power.lidClosed == true
            if (closed && !restoreWhileClosed) || !backlight.restore(wakeDisplay: !closed) {
                // 等开盖，或恢复失败：继续监听，每秒重试，开盖/唤醒时也会再试
                lidWatcher.start()
                return
            }
        }
        afterRestore()
        lidWatcher.stop()
    }

    private func lidChanged(closed: Bool) {
        pendingDim?.cancel()
        pendingDim = nil
        if closed {
            guard isOn else { return }
            dimFailures = 0
            // 合盖稳定 0.5 秒再关背光，避免盖子半合时反复闪
            let work = DispatchWorkItem { [weak self] in self?.tryDim() }
            pendingDim = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
        } else {
            // 开盖立即恢复
            if backlight.isDimmed && backlight.restore() { afterRestore() }
            if !isOn && !backlight.isDimmed { lidWatcher.stop() }
        }
    }

    private func tryDim() {
        // 接外接显示器的合盖模式下系统会自己关内建屏，不用管
        guard isOn, Power.lidClosed == true, Power.clamshellCausesSleep else { return }
        dimFailures = backlight.dim() ? 0 : dimFailures + 1
    }

    /// 每秒一次：重试失败的关背光（最多 5 次）和失败的恢复（直到成功）
    private func lidTick() {
        let closed = Power.lidClosed == true
        if backlight.isDimmed && !closed {
            if backlight.restore() { afterRestore() }
        } else if isOn && closed && !backlight.isDimmed && dimFailures > 0 && dimFailures < 5 {
            tryDim()
        }
        if !isOn && !backlight.isDimmed { lidWatcher.stop() }
    }

    private func afterRestore() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self, Power.lidClosed != true else { return }
            self.backlight.reassertLastRestore()
        }
    }

    /// 系统唤醒：同时检查背光恢复、系统休眠状态与低电量暂停恢复
    @objc private func systemDidWake() {
        displayMayBeBack()
        syncWithSystem()
        if !isOn && pausedForLowBattery { checkBattery() }
    }

    /// 系统即将注销/重启/关机：先清理系统状态，但保留「重启后自动恢复」标记
    @objc private func systemWillPowerOff() {
        Log.write("系统即将注销/重启/关机")
        cleanupForExit(interactive: false)
    }

    /// 唤醒、屏幕唤醒、显示器配置变化：如果屏幕还是黑的，再试一次恢复
    @objc private func displayMayBeBack() {
        guard backlight.isDimmed, Power.lidClosed != true else { return }
        if backlight.restore() { afterRestore() }
        if !isOn && !backlight.isDimmed { lidWatcher.stop() }
    }

    /// 和系统状态对齐（有人在终端里改了 pmset 等情况）
    private func syncWithSystem() {
        guard !busy, !terminating else { return }
        guard let actual = Power.sleepDisabledReading else { return }   // 读不到就不动
        if actual == isOn {
            if isOn {
                ensureIdleAssertion()
                checkBattery()
            } else if pausedForLowBattery {
                checkBattery()
            }
            return
        }
        cancelPendingRestore()
        Log.write("系统状态与 App 不一致，已同步为 \(actual ? "开启" : "关闭")")
        isOn = actual
        shouldRestoreOnLaunch = actual
        pausedForLowBattery = false
        if actual {
            startProtection()
            if deadline != nil {
                startCountdown()
                tick()
            }
        } else {
            cancelCountdown()
            stopProtection()
            notify("合盖不休眠已关闭", "检测到系统休眠设置被外部恢复为正常休眠")
        }
        updateUI()
    }

    // ------------------------------------------------------------
    // MARK: 定时关闭
    // ------------------------------------------------------------

    @objc func setAutoOff(_ sender: NSMenuItem) {
        guard !busy, let minutes = sender.representedObject as? Int else { return }
        let apply = { [weak self] in
            guard let self = self, self.isOn else { return }
            self.deadline = Date().addingTimeInterval(TimeInterval(minutes * 60))
            self.timerRetryAt = nil
            self.startCountdown()
            self.updateUI()
        }
        // 关闭状态下选定时 = 开启并定时
        if isOn { apply() } else { turnOn(then: apply) }
    }

    @objc func cancelAutoOff() {
        cancelCountdown()
        updateUI()
    }

    private func startCountdown() {
        countdownTimer?.invalidate()
        // 加到 common 模式：菜单展开时倒计时也会走
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        countdownTimer = timer
    }

    private func pauseCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        timerRetryAt = nil
    }

    private func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        deadline = nil
        timerRetryAt = nil
    }

    private func tick() {
        guard let d = deadline else { cancelCountdown(); updateUI(); return }
        if d.timeIntervalSinceNow <= 0 {
            if !isOn { cancelCountdown(); updateUI(); return }
            if timerRetryAt.map({ Date() >= $0 }) ?? true { turnOff(reason: .timer) }
        }
        updateCountdown()
    }

    func formatRemaining(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.up)))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    // ------------------------------------------------------------
    // MARK: 低电量保护
    // ------------------------------------------------------------

    @objc func setBatteryThreshold(_ sender: NSMenuItem) {
        guard let percent = sender.representedObject as? Int else { return }
        batteryThreshold = percent
        batteryArmed = true
        checkBattery()
        updateUI()
    }

    private func checkBattery() {
        if isOn {
            guard batteryThreshold > 0, let b = Power.battery() else { return }
            if !b.onBattery || b.percent > batteryThreshold {
                batteryArmed = true
            } else if batteryArmed && !busy {
                Log.write("电量 \(b.percent)% ≤ \(batteryThreshold)%，自动暂停")
                batteryArmed = false
                turnOff(reason: .battery)
            }
            return
        }
        guard pausedForLowBattery, !busy, !terminating, pendingRestore == nil else { return }
        if let d = deadline, d.timeIntervalSinceNow <= 0 {
            Log.write("低电量暂停期间原定时已到期，取消自动恢复")
            cancelCountdown()
            pausedForLowBattery = false
            shouldRestoreOnLaunch = false
            powerWatcher.stop()
            updateUI()
            return
        }
        let recovered: Bool
        if batteryThreshold == 0 {
            recovered = true
        } else if let b = Power.battery() {
            recovered = !b.onBattery || b.percent > batteryThreshold
        } else {
            recovered = true
        }
        guard recovered else { return }
        guard Privileged.ownRuleInstalled || Privileged.legacyRulePresent else {
            Log.write("电源恢复时缺少免密配置，无法自动恢复")
            cancelCountdown()
            pausedForLowBattery = false
            shouldRestoreOnLaunch = false
            powerWatcher.stop()
            notify("合盖不休眠未自动恢复", "缺少免密配置，请点击菜单栏重新开启")
            updateUI()
            return
        }
        Log.write("检测到电源/电量已恢复，正在自动重新开启合盖不休眠")
        restoreOnLaunch(attempt: 1, fromBatteryPause: true)
    }

    // ------------------------------------------------------------
    // MARK: 开机自动启动
    // ------------------------------------------------------------

    @objc func toggleLoginItem() {
        guard #available(macOS 13.0, *) else { return }
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
                if service.status == .requiresApproval {
                    showAlert("需要在系统设置里允许", "请在「系统设置 → 通用 → 登录项」中允许「合盖不休眠」。")
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        } catch {
            showAlert("设置开机启动失败", error.localizedDescription)
        }
        updateUI()
    }

    // ------------------------------------------------------------
    // MARK: 界面
    // ------------------------------------------------------------

    private var iconIsOn: Bool?
    private func setIcon(on: Bool) {
        guard let button = statusItem.button, iconIsOn != on else { return }
        iconIsOn = on
        if let img = NSImage(systemSymbolName: on ? "moon.zzz.fill" : "moon.zzz",
                             accessibilityDescription: on ? "合盖不休眠：已开启" : "合盖不休眠：已关闭") {
            img.size = NSSize(width: 18, height: 18)
            img.isTemplate = true
            button.image = img
            button.title = ""
        } else {
            button.image = nil
            button.title = on ? "🌙" : "☾"
        }
    }

    /// 只更新倒计时相关文字（每秒调用）
    private func updateCountdown() {
        let remaining = deadline?.timeIntervalSinceNow ?? 0
        let hasTimer = isOn && deadline != nil
        let isPaused = !isOn && pausedForLowBattery
        let hasPausedTimer = isPaused && deadline != nil && remaining > 0

        var details: [String] = []
        if hasTimer {
            details.append(remaining > 0 ? "⏱ \(formatRemaining(remaining)) 后自动关闭" : "⏱ 正在自动关闭…")
        } else if hasPausedTimer {
            details.append("⏱ 原定时剩余 \(formatRemaining(remaining))（恢复后继续）")
        }
        if isOn && !backlight.available { details.append("⚠️ 无法控制屏幕亮度，合盖后屏幕可能不灭") }
        detailMenuItem.title = details.joined(separator: "  ·  ")
        detailMenuItem.isHidden = details.isEmpty

        timerMenuItem.title = hasTimer && remaining > 0 ? "定时关闭（剩余 \(formatRemaining(remaining))）" : "定时关闭"
        cancelTimerMenuItem.isEnabled = (hasTimer || hasPausedTimer) && !busy

        var tip: String
        if isOn {
            tip = "合盖不休眠 — 已开启"
            if hasTimer && remaining > 0 { tip += " ⏱ \(formatRemaining(remaining))" }
        } else if isPaused {
            tip = "合盖不休眠 — 低电量暂停（充电后自动恢复）"
        } else {
            tip = "合盖不休眠 — 已关闭"
        }
        if statusItem.button?.toolTip != tip { statusItem.button?.toolTip = tip }
    }

    func updateUI() {
        let isPaused = !isOn && pausedForLowBattery
        if busy {
            statusMenuItem.title = isOn ? "⏳ 正在关闭…" : "⏳ 正在开启…"
        } else if isOn {
            statusMenuItem.title = "✅ 已开启 — 合盖后继续运行，自动关屏"
        } else if isPaused {
            statusMenuItem.title = "⏸ 已因低电量暂停 — 接通电源或充电后自动恢复"
        } else {
            statusMenuItem.title = "❌ 已关闭 — 正常休眠"
        }
        toggleMenuItem.title = isOn ? "关闭合盖不休眠" : (isPaused ? "立即开启合盖不休眠" : "开启合盖不休眠")
        toggleMenuItem.isEnabled = !busy
        cancelPauseMenuItem.isHidden = !isPaused
        cancelPauseMenuItem.isEnabled = isPaused && !busy
        for item in timerSubMenu.items where item.representedObject != nil { item.isEnabled = !busy }

        batteryMenuItem.title = batteryThreshold > 0 ? "低电量保护（\(batteryThreshold)%）" : "低电量保护（未启用）"
        for item in batterySubMenu.items {
            item.state = (item.representedObject as? Int) == batteryThreshold ? .on : .off
        }

        if #available(macOS 13.0, *) {
            loginMenuItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }

        setIcon(on: isOn)
        updateCountdown()
    }

    // ------------------------------------------------------------
    // MARK: 安全升级（旧版 sudoers）
    // ------------------------------------------------------------

    private func offerSecurityUpgrade() {
        guard Privileged.legacyRulePresent else { return }
        let timers = Power.legacyTimers()
        let alert = NSAlert()
        alert.messageText = "升级免密配置（建议）"
        alert.informativeText = "旧版的免密配置允许这台 Mac 上的任何账户不输密码执行 pmset 的所有功能。\n\n新版只允许你的账户执行「开启 / 关闭合盖不休眠」这两条命令。这台 Mac 上其他账户如果也在用旧版，需要各自升级到新版。"
        alert.addButton(withTitle: "升级")
        alert.addButton(withTitle: "以后再说")
        if timers != .none {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "同时恢复 macOS 默认睡眠时间"
            switch timers {
            case .allNever:
                alert.informativeText += "\n\n检测到显示器、系统和硬盘睡眠时间都是「永不」，很可能是旧版留下的。（macOS 默认：用电池 2 分钟、接电源 10 分钟关显示器。）"
                alert.suppressionButton?.state = .on
            case .v16Off:
                alert.informativeText += "\n\n检测到用电池时关显示器的时间是 10 分钟，可能是旧版关闭时统一设置的（macOS 默认 2 分钟）。"
                alert.suppressionButton?.state = .off
            case .none:
                break
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else {
            defaults.set(Date().timeIntervalSince1970, forKey: "upgradeDeclinedAt")
            return
        }
        let restore = timers != .none && alert.suppressionButton?.state == .on
        if let err = Privileged.install(restoreTimers: restore, prompt: "「合盖不休眠」要收紧免密配置，只保留开关需要的两条命令。") {
            if err != "cancel" { showAlert("升级失败", err) }
        } else {
            defaults.removeObject(forKey: "upgradeDeclinedAt")
            Log.write("免密配置已升级\(restore ? "，并恢复了睡眠时间默认值" : "")")
        }
    }

    // ------------------------------------------------------------
    // MARK: 关于 / 退出 / 卸载
    // ------------------------------------------------------------

    @objc func showAbout() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let alert = NSAlert()
        alert.messageText = "合盖不休眠 v\(version)"
        alert.informativeText = """
MacBook 合盖后保持运行，自动关闭屏幕省电。

—— 关注作者 ——
🎵 抖音：ywhhxs1998
📕 小红书：4270972670

点赞关注，私信获取安装包～
"""
        alert.addButton(withTitle: "好的")
        alert.addButton(withTitle: "🔗 打开下载页面")
        alert.addButton(withTitle: "查看日志")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertSecondButtonReturn:
            if let url = URL(string: "https://github.com/1073020318-cell/nosleep-mac/releases") { NSWorkspace.shared.open(url) }
        case .alertThirdButtonReturn:
            Log.flush()
            NSWorkspace.shared.activateFileViewerSelecting([Log.url])
        default:
            break
        }
    }

    @objc func quitApp() {
        userQuit = true
        NSApp.terminate(nil)
    }

    /// 退出 / 注销 / 被 kill 时同步清理。interactive 为 true 表示用户主动点「退出」，
    /// 会清除重启恢复标记并允许弹授权窗口兜底；非手动退出（重启/注销/系统更新/升级替换）
    /// 会先恢复正常休眠以保安全，同时保留恢复标记，下次登录后自动重新开启。
    func cleanupForExit(interactive: Bool) {
        guard !uninstalled, !terminating else { return }
        terminating = true
        cancelPendingRestore()
        if interactive {
            shouldRestoreOnLaunch = false
            pausedForLowBattery = false
            cancelCountdown()
        }
        // 先恢复亮度（最要紧，且很快），注销/关机时系统可能等不了太久
        lidWatcher.stop()
        powerWatcher.stop()
        if backlight.isDimmed && !backlight.restore(wakeDisplay: Power.lidClosed != true) { Log.write("⚠️ 退出时恢复亮度失败") }
        workQueue.sync {}
        let beforeCleanup = Power.sleepDisabledReading
        if !interactive {
            if isOn && beforeCleanup == false {
                if pendingOffReason == .battery {
                    if let d = deadline, d.timeIntervalSinceNow <= 0 {
                        pausedForLowBattery = false
                        shouldRestoreOnLaunch = false
                        cancelCountdown()
                    } else {
                        pausedForLowBattery = true
                        shouldRestoreOnLaunch = true
                    }
                } else {
                    shouldRestoreOnLaunch = false
                    pausedForLowBattery = false
                    cancelCountdown()
                }
            } else if busy && !isOn && beforeCleanup == true {
                shouldRestoreOnLaunch = true
                pausedForLowBattery = false
            }
        }
        if beforeCleanup != false && !Privileged.setSleepDisabled(false) && !Power.sleepConfirmedEnabled {
            Log.write("⚠️ 退出时恢复休眠失败")
            if interactive {
                if let err = Privileged.runAsAdmin("/usr/bin/pmset -a disablesleep 0", prompt: "「合盖不休眠」退出前需要恢复系统的正常休眠。") {
                    Log.write("⚠️ 授权恢复休眠也失败：\(err)")
                    showAlert("电脑仍处于「不休眠」状态", "没能恢复正常休眠。可以重新打开 App 再关闭，或在终端执行：\nsudo pmset -a disablesleep 0")
                }
            }
        }
        isOn = false
        if idleAssertion != 0 { IOPMAssertionRelease(idleAssertion); idleAssertion = 0 }
        let suffix = interactive ? "（手动）" : (shouldRestoreOnLaunch ? "（非手动，下次启动将自动恢复）" : "")
        Log.write("退出\(suffix)")
        Log.flush()
    }

    @objc func uninstallApp() {
        let allNever = Power.legacyTimers() == .allNever
        let alert = NSAlert()
        alert.messageText = "确认卸载？"
        alert.informativeText = "将执行以下操作：\n• 关闭合盖不休眠，恢复系统正常休眠\n• 删除免密配置（需要输入一次管理员密码）\n• 删除本 App 的日志和偏好设置\n• 把本应用移到废纸篓\n\n此操作不可撤销。"
        if allNever {
            alert.informativeText += "\n\n检测到显示器、系统和硬盘睡眠时间都是「永不」，可能是旧版留下的。（macOS 默认：用电池 2 分钟、接电源 10 分钟关显示器。）"
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "同时恢复 macOS 默认睡眠时间"
            alert.suppressionButton?.state = .on
        }
        alert.addButton(withTitle: "确认卸载")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .critical
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let restoreTimers = allNever && alert.suppressionButton?.state == .on

        workQueue.sync {}
        let fm = FileManager.default
        if fm.fileExists(atPath: Privileged.rulePath) || Privileged.legacyRulePresent || Power.sleepDisabled || restoreTimers {
            if let err = Privileged.runAsAdmin(Privileged.uninstallScript(restoreTimers: restoreTimers),
                                               prompt: "「合盖不休眠」要删除免密配置并恢复系统休眠。") {
                if err != "cancel" { showAlert("卸载失败", err) }
                return
            }
            if fm.fileExists(atPath: Privileged.rulePath) {
                showAlert("卸载失败", "免密配置文件没有删除：\(Privileged.rulePath)")
                return
            }
        }
        uninstalled = true
        terminating = true   // 之后到达的开/关回调一律忽略
        cancelPendingRestore()
        pausedForLowBattery = false
        shouldRestoreOnLaunch = false
        cancelCountdown()
        isOn = false
        stopProtection()
        // App 马上就没了，没有机会再重试：这里多试几次
        for attempt in 1...10 where backlight.isDimmed && !backlight.restore(wakeDisplay: Power.lidClosed != true) {
            if attempt < 10 { Thread.sleep(forTimeInterval: 0.3) }
        }
        if backlight.isDimmed {
            showAlert("屏幕亮度没能自动恢复", "如果屏幕很暗或是黑的，请按键盘上的亮度键调亮。")
        }
        lidWatcher.stop()

        if #available(macOS 13.0, *) { try? SMAppService.mainApp.unregister() }
        if let id = Bundle.main.bundleIdentifier { defaults.removePersistentDomain(forName: id) }
        Log.removeAll()

        let appURL = Bundle.main.bundleURL
        NSWorkspace.shared.recycle([appURL]) { _, error in
            DispatchQueue.main.async {
                if error != nil {
                    self.showAlert("已清理完成", "系统设置已恢复。App 本身未能自动移到废纸篓，请手动把它拖到废纸篓：\n\(appURL.path)")
                }
                NSApp.terminate(nil)
            }
        }
    }

    // ------------------------------------------------------------
    // MARK: 工具
    // ------------------------------------------------------------

    func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好的")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error { Log.write("通知未显示：\(error.localizedDescription)") }
        }
    }
}

// ============================================================
// MARK: - AppDelegate
// ============================================================

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var controller: MenuBarController?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("=== 启动 v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") / macOS \(ProcessInfo.processInfo.operatingSystemVersionString) ===")

        guard checkLocation(), replaceOtherInstances() else {
            NSApp.terminate(nil)
            return
        }

        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }

        controller = MenuBarController()

        // kill / Ctrl-C 时也恢复系统休眠
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.controller?.cleanupForExit(interactive: false)
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// 从 DMG 里或被系统「随机化路径」运行时，开机启动和卸载都会出问题
    private func checkLocation() -> Bool {
        let path = Bundle.main.bundlePath
        guard path.hasPrefix("/Volumes/") || path.contains("/AppTranslocation/") else { return true }
        // 用户选过「仍然运行」的位置不再提醒（比如确实想从外接硬盘运行）
        let key = "locationWarned"
        if UserDefaults.standard.string(forKey: key) == path { return true }
        let alert = NSAlert()
        alert.messageText = "请先把「合盖不休眠」拖到「应用程序」文件夹"
        alert.informativeText = "现在是直接从安装包（或临时位置）运行的，开机自动启动和卸载功能会不正常。\n\n拖到「应用程序」文件夹后，再从那里打开。"
        alert.addButton(withTitle: "退出")
        alert.addButton(withTitle: "仍然运行")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        UserDefaults.standard.set(path, forKey: key)
        return true
    }

    /// 只允许一个实例。常见情况是升级时旧版还在菜单栏运行。返回 false 表示本实例应退出。
    private func replaceOtherInstances() -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        guard let id = Bundle.main.bundleIdentifier else { return true }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { $0.processIdentifier != me }
        guard !others.isEmpty else { return true }

        // 判断正在运行的是不是旧版本：它在当前程序文件「放到磁盘上」之前就启动了。
        // 用 ctime（inode 变更时间）而不是修改时间：拷贝、从 DMG 拖入都会刷新 ctime，但会保留修改时间。
        // 同一磁盘内 mv 不会改 ctime，所以同时看 App 目录本身的 ctime，取较晚的那个
        //（宁可多问一次，也不要把旧版当成重复启动而默默退出）
        func ctime(_ path: String?) -> Date? {
            guard let path = path else { return nil }
            var st = stat()
            guard stat(path, &st) == 0 else { return nil }
            return Date(timeIntervalSince1970: TimeInterval(st.st_ctimespec.tv_sec) + TimeInterval(st.st_ctimespec.tv_nsec) / 1e9)
        }
        let exeChanged = [ctime(Bundle.main.executablePath), ctime(Bundle.main.bundlePath)].compactMap { $0 }.max()
        let olderRunning = others.contains { other in
            guard other.bundleURL == Bundle.main.bundleURL, let changed = exeChanged, let launched = other.launchDate else { return true }
            return launched < changed
        }
        guard olderRunning else {
            // 同一个版本又被打开了一次（比如开机启动 + 手动打开），直接退出即可
            Log.write("已有实例在运行，退出")
            return false
        }

        let alert = NSAlert()
        alert.messageText = "另一个「合盖不休眠」正在菜单栏运行"
        alert.informativeText = "可能是升级前的旧版本。点「改用这个版本」会先让正在运行的那个退出，再启动当前这个。"
        alert.addButton(withTitle: "改用这个版本")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        let wasSleepDisabled = Power.sleepDisabled
        // 兼容从旧版升级：旧实例收到 terminate 后会把 disablesleep 设为 0 且不会写恢复标记。
        // 在发送 terminate 前就先持久化恢复标记，即使等待超时后旧实例才退出，用户稍后重开新版也能正常恢复。
        if wasSleepDisabled {
            UserDefaults.standard.set(true, forKey: MenuBarController.restoreOnLaunchKey)
        }
        others.forEach { $0.terminate() }
        let until = Date().addingTimeInterval(8)
        while others.contains(where: { !$0.isTerminated }) && Date() < until {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        guard !others.contains(where: { !$0.isTerminated }) else {
            Log.write("旧实例尚未退出，取消接管")
            let timeout = NSAlert()
            timeout.messageText = "旧版尚未退出"
            timeout.informativeText = "请等旧版退出后，再打开这个版本。"
            timeout.addButton(withTitle: "好的")
            timeout.runModal()
            return false
        }
        Log.write("已替换正在运行的旧实例")
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.cleanupForExit(interactive: controller?.userQuit ?? false)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
