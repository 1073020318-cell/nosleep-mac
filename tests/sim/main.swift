// 沙箱场景测试：App 的真实逻辑 + 假的系统层（见 fakes.swift）。不会改动电脑的任何设置。
import Cocoa

_ = NSApplication.shared
NSApp.setActivationPolicy(.prohibited)

var report: [(scenario: String, check: String, ok: Bool)] = []
var scenarioName = ""
func expect(_ what: String, _ ok: Bool) { report.append((scenarioName, what, ok)) }
func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
@discardableResult func waitFor(_ t: Double = 5, _ cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(t)
    while Date() < end { if cond() { return true }; spin(0.05) }
    return cond()
}
func has(_ s: String) -> Bool { events().contains { $0.hasPrefix(s) } }
func idx(_ s: String) -> Int? { events().firstIndex { $0.hasPrefix(s) } }

var current: MenuBarController?
func teardownCurrent() {
    if let c = current {
        c.cancelPendingRestore()
        c.lidWatcher.stop()
        c.powerWatcher.stop()
        c.countdownTimer?.invalidate()
        c.statusTimer?.invalidate()
        c.terminating = true
        c.statusItem.menu = nil
    }
    current = nil
    spin(0.1)
}
func fresh(_ name: String, lid: Bool = false, sleep: Bool? = false, battery: (Bool, Int)? = (false, 100),
           clamshell: Bool = true, threshold: Int? = nil, pre: () -> Void = {}) -> MenuBarController {
    teardownCurrent()
    SimDefaults.d.removePersistentDomain(forName: simSuite)
    Power.lid = lid; Power.sleepState = sleep; Power.clamshellCausesSleep = clamshell
    Power.batteryState = battery.map { (onBattery: $0.0, percent: $0.1) }; Power.legacy = .none
    Privileged.failNext = 0; Privileged.delay = 0; Privileged.adminFails = false
    Privileged.ownRuleInstalled = true; Privileged.legacyRulePresent = false
    Backlight.panel = 0.8; Backlight.failRestores = 0; Backlight.failDims = 0
    FakeUI.responses = []; assertionsHeld = 0; failNextAssertion = 0
    MenuBarController.restoreRetryDelay = 0.1
    if let t = threshold { SimDefaults.d.set(t, forKey: "batteryThreshold") }
    pre()
    resetEvents()
    scenarioName = name
    let c = MenuBarController()
    current = c
    return c
}
/// 模拟系统重启/重新打开 App（保留持久化偏好设置，不清空 SimDefaults）
func relaunch(_ name: String, lid: Bool = false, sleep: Bool? = false, battery: (Bool, Int)? = (false, 100),
              clamshell: Bool = true) -> MenuBarController {
    teardownCurrent()
    Power.lid = lid; Power.sleepState = sleep; Power.clamshellCausesSleep = clamshell
    Power.batteryState = battery.map { (onBattery: $0.0, percent: $0.1) }
    assertionsHeld = 0; failNextAssertion = 0
    resetEvents()
    scenarioName = name
    let c = MenuBarController()
    current = c
    return c
}
func setLid(_ c: MenuBarController, _ closed: Bool) { Power.lid = closed; c.lidWatcher.check() }  // = IOKit lid event
func turnOnAndWait(_ c: MenuBarController) { c.turnOn(); waitFor { c.isOn && !c.busy } }
let timer30 = NSMenuItem(); timer30.representedObject = 30

// 1
var c = fresh("1 开启（开盖）")
turnOnAndWait(c)
expect("系统 disablesleep=1", Power.sleepState == true)
expect("持有一个防空闲睡眠断言", assertionsHeld == 1)
expect("合盖监听在运行", c.lidWatcher.isRunning)
expect("没有关背光", Backlight.panel == 0.8)

// 2
setLid(c, true); scenarioName = "2 合盖 → 0.5 秒后关背光"
expect("合盖瞬间还没关（等 0.5 秒防抖）", Backlight.panel == 0.8)
waitFor(2) { Backlight.panel == 0 }
expect("0.5 秒后背光为 0", Backlight.panel == 0)
expect("记下了原亮度", c.backlight.isDimmed)

// 3
scenarioName = "3 开盖 → 立即恢复"
setLid(c, false)
expect("亮度恢复到 0.8", Backlight.panel == 0.8)
expect("唤醒了显示器", has("restore wake=true"))

// 4
c = fresh("4 盖子半合抖动（合上 0.2 秒又打开）")
turnOnAndWait(c); setLid(c, true); spin(0.2); setLid(c, false); spin(1.0)
expect("没有关背光，不闪屏", !has("dim") && Backlight.panel == 0.8)

// 5
c = fresh("5 开盖时显示器还没准备好（恢复失败 2 次）")
turnOnAndWait(c); setLid(c, true); waitFor { Backlight.panel == 0 }
Backlight.failRestores = 2
setLid(c, false)
expect("第一次恢复失败，仍记着要恢复", c.backlight.isDimmed)
waitFor(5) { Backlight.panel == 0.8 }
expect("每秒重试，最终恢复到 0.8", Backlight.panel == 0.8 && !c.backlight.isDimmed)

// 6
c = fresh("6 合盖时定时到期（最重要）")
turnOnAndWait(c); setLid(c, true); waitFor { Backlight.panel == 0 }
c.deadline = Date().addingTimeInterval(1); c.startCountdown()
waitFor(4) { !c.isOn }; spin(0.5)
expect("系统 disablesleep=0", Power.sleepState == false)
expect("睡眠前先恢复了亮度（开盖不会黑屏）", Backlight.panel == 0.8)
expect("盖子合着时恢复亮度不唤醒显示器", has("restore wake=false") && !has("restore wake=true"))
expect("先恢复亮度、后让电脑睡眠", (idx("restore wake=false") ?? 99) < (idx("run /usr/bin/pmset sleepnow") ?? -1))
expect("发出「定时到」通知", has("NOTIFY 定时到"))
expect("释放了防空闲睡眠断言", assertionsHeld == 0)
expect("定时已清除", c.deadline == nil)

// 7
c = fresh("7 定时到期但 sudo 失败一次")
turnOnAndWait(c); Privileged.failNext = 1
c.deadline = Date().addingTimeInterval(0.5); c.startCountdown()
waitFor(3) { has("NOTIFY 定时关闭失败") }; spin(1.5)
expect("失败后仍开着、定时还在", c.isOn && c.deadline != nil)
expect("通知用户将重试", has("NOTIFY 定时关闭失败"))
expect("安排了约 30 秒后重试", (c.timerRetryAt?.timeIntervalSinceNow ?? 0) > 25)
c.timerRetryAt = Date()   // 快进 30 秒
waitFor(3) { !c.isOn }
expect("重试成功后关闭", !c.isOn && Power.sleepState == false)

// 8
c = fresh("8 开盖时定时到期")
turnOnAndWait(c); c.deadline = Date().addingTimeInterval(0.5); c.startCountdown()
waitFor(3) { !c.isOn }; spin(0.3)
expect("关闭了", Power.sleepState == false)
expect("没有强制睡眠", !has("run /usr/bin/pmset sleepnow"))

// 9
c = fresh("9 外接显示器合盖模式", clamshell: false)
turnOnAndWait(c); setLid(c, true); spin(1.0)
expect("不去关内建屏（系统自己会关）", Backlight.panel == 0.8)
c.deadline = Date().addingTimeInterval(0.3); c.startCountdown(); waitFor(3) { !c.isOn }; spin(0.3)
expect("定时到期不强制睡眠（你可能正在用外接显示器）", !has("run /usr/bin/pmset sleepnow"))

// 10
c = fresh("10 合盖用电池，电量降到 19%", battery: (true, 50), threshold: 20)
turnOnAndWait(c); setLid(c, true); waitFor { Backlight.panel == 0 }
Power.batteryState = (true, 19); c.checkBattery()      // = 系统电量变化回调
waitFor(3) { !c.isOn }; spin(0.3)
expect("自动关闭", Power.sleepState == false)
expect("发出「电量低」通知", has("NOTIFY 电量低"))
expect("恢复亮度后让电脑睡眠", Backlight.panel == 0.8 && has("run /usr/bin/pmset sleepnow"))

// 11
c = fresh("11 接着电源时电量低", battery: (false, 10), threshold: 20)
turnOnAndWait(c); c.checkBattery(); spin(0.3)
expect("接电源时不关闭", c.isOn)

// 12
c = fresh("12 电量 15% 时坚持开启", battery: (true, 15), threshold: 20)
FakeUI.responses = [.alertFirstButtonReturn]
turnOnAndWait(c)
expect("先弹出低电量提醒", has("ALERT 电量只剩 15%"))
Power.batteryState = (true, 14); c.checkBattery(); spin(0.3)
expect("点了「仍然开启」后，14% 不会自动关", c.isOn)
Power.batteryState = (false, 14); c.checkBattery()
Power.batteryState = (true, 14); c.checkBattery(); waitFor(3) { !c.isOn }
expect("接过电源再拔掉，保护重新生效 → 关闭", !c.isOn)

// 13
c = fresh("13 App 崩溃后重开：系统仍是开启、盖子合着", lid: true, sleep: true)
expect("自动接管为开启", c.isOn)
waitFor(2) { Backlight.panel == 0 }
expect("继续合盖关屏", Backlight.panel == 0)

// 14
c = fresh("14 重开时定时早已过期", sleep: true, pre: { SimDefaults.d.set(Date().addingTimeInterval(-60).timeIntervalSince1970, forKey: "autoOffDeadline") })
waitFor(3) { !c.isOn }
expect("立即执行关闭", !c.isOn && Power.sleepState == false)

// 15
c = fresh("15 重开时在用电池且只剩 10%", sleep: true, battery: (true, 10), threshold: 20)
waitFor(3) { !c.isOn }
expect("低电量保护照常生效 → 关闭", !c.isOn)

// 16
c = fresh("16 上次崩溃时屏幕是黑的，开盖状态重开", pre: {
    Backlight.panel = 0; SimDefaults.d.set(0.6, forKey: "dimmedBrightness"); SimDefaults.d.set(1, forKey: "dimmedDisplay") })
expect("启动就恢复到 0.6", Backlight.panel == 0.6)

// 17
c = fresh("17 有人在终端关掉了 disablesleep（盖子合着）")
turnOnAndWait(c); setLid(c, true); waitFor { Backlight.panel == 0 }
Power.sleepState = false; c.syncWithSystem()
expect("App 同步为关闭", !c.isOn)
expect("盖子合着时保持黑屏（不在包里亮屏）", Backlight.panel == 0)
setLid(c, false)
expect("开盖后恢复亮度", Backlight.panel == 0.8)

// 18
c = fresh("18 系统状态读不到")
turnOnAndWait(c); Power.sleepState = nil; c.syncWithSystem()
expect("读不到时不乱改状态", c.isOn)

// 19
c = fresh("19 合盖时退出 / 注销")
turnOnAndWait(c); setLid(c, true); waitFor { Backlight.panel == 0 }
c.cleanupForExit(interactive: false)
expect("恢复正常休眠", Power.sleepState == false)
expect("恢复亮度但不在合着的盖子里唤醒屏幕", Backlight.panel == 0.8 && has("restore wake=false"))
expect("释放断言", assertionsHeld == 0)

// 20
c = fresh("20 点「退出」时 sudo 失败")
turnOnAndWait(c); Privileged.failNext = 5; Privileged.adminFails = true
c.cleanupForExit(interactive: true)
expect("改用管理员授权再试", has("admin: /usr/bin/pmset -a disablesleep 0"))
expect("仍失败时明确告诉用户", has("ALERT 电脑仍处于「不休眠」状态"))

// 21
c = fresh("21 正在关闭时又点了定时")
turnOnAndWait(c); Privileged.delay = 0.5
c.turnOff(reason: .user); c.setAutoOff(timer30)
waitFor(3) { !c.busy }; spin(0.2)
expect("关闭后没有残留定时", !c.isOn && c.deadline == nil)

// 22
c = fresh("22 关闭状态下选「30 分钟」")
c.setAutoOff(timer30); waitFor { c.isOn && !c.busy }; spin(0.1)
let rem = c.deadline?.timeIntervalSinceNow ?? 0
expect("自动开启并开始 30 分钟倒计时", c.isOn && rem > 29 * 60 && rem <= 30 * 60)

// 23
c = fresh("23 卸载", pre: { FileManager.default.createFile(atPath: Privileged.rulePath, contents: nil) })
turnOnAndWait(c)
FakeUI.responses = [.alertFirstButtonReturn]
// 模拟授权脚本删除了免密文件
let origAdmin = Privileged.adminFails
c.uninstallApp()
_ = origAdmin
expect("请求管理员授权执行卸载脚本", has("admin: uninstall("))
expect("（模拟里免密文件没被真正删，App 应发现并中止）", has("ALERT 卸载失败") && !has("recycle app"))
try? FileManager.default.removeItem(atPath: Privileged.rulePath)
FakeUI.responses = [.alertFirstButtonReturn]
resetEvents(); c.uninstallApp(); spin(0.3)
expect("文件删掉后：系统恢复休眠", Power.sleepState == false)
expect("App 移到废纸篓并退出", has("recycle app") && has("terminate"))

// 24
c = fresh("24 系统重启/注销后自动恢复开启，拔电源合盖不休眠")
turnOnAndWait(c)
expect("开启后记下重启恢复标记", c.shouldRestoreOnLaunch)
c.cleanupForExit(interactive: false)
expect("重启/注销退出时先安全恢复正常休眠", Power.sleepState == false && assertionsHeld == 0)
expect("非手动退出保留恢复标记", c.shouldRestoreOnLaunch)
c = relaunch("24 系统重启/注销后自动恢复开启，拔电源合盖不休眠", lid: false, sleep: false, battery: (false, 100))
waitFor(3) { c.isOn && !c.busy }
expect("重启后自动恢复 disablesleep=1", c.isOn && Power.sleepState == true)
expect("重启后重新持有防空闲睡眠断言", assertionsHeld == 1)
expect("重启后合盖监听恢复运行", c.lidWatcher.isRunning)
// 模拟夜间拔掉电源（99% 电池）再合盖
Power.batteryState = (true, 99); c.checkBattery()
setLid(c, true); waitFor(2) { Backlight.panel == 0 }
expect("切换电池 99% 并合盖后仍保持开启且关闭背光", c.isOn && Power.sleepState == true && assertionsHeld == 1 && Backlight.panel == 0)

// 25
c = fresh("25 用户主动点「退出」后重开保持关闭")
turnOnAndWait(c)
c.cleanupForExit(interactive: true)
expect("手动退出清除恢复标记", !c.shouldRestoreOnLaunch && Power.sleepState == false)
c = relaunch("25 用户主动点「退出」后重开保持关闭", lid: false, sleep: false)
spin(0.3)
expect("再次打开保持关闭状态", !c.isOn && Power.sleepState == false && assertionsHeld == 0)

// 26
c = fresh("26 重启后首次恢复 sudo 失败 → 自动重试成功")
turnOnAndWait(c)
c.cleanupForExit(interactive: false)
Privileged.failNext = 1
c = relaunch("26 重启后首次恢复 sudo 失败 → 自动重试成功", lid: false, sleep: false)
waitFor(3) { c.isOn && !c.busy }
expect("第一次失败后重试成功恢复开启", c.isOn && Power.sleepState == true && assertionsHeld == 1 && has("sudo pmset disablesleep 1 → FAIL"))

// 27
c = fresh("27 重启后连续 3 次恢复失败 → 通知用户")
turnOnAndWait(c)
c.cleanupForExit(interactive: false)
Privileged.failNext = 5
c = relaunch("27 重启后连续 3 次恢复失败 → 通知用户", lid: false, sleep: false)
waitFor(3) { has("NOTIFY 合盖不休眠未能自动恢复") }
expect("3 次失败后通知用户而不静默关闭", !c.isOn && has("NOTIFY 合盖不休眠未能自动恢复") && !c.shouldRestoreOnLaunch)

// 28
c = fresh("28 重启期间原定时已过期 → 不自动恢复")
turnOnAndWait(c)
c.deadline = Date().addingTimeInterval(-60)
c.cleanupForExit(interactive: false)
c = relaunch("28 重启期间原定时已过期 → 不自动恢复", lid: false, sleep: false)
spin(0.3)
expect("定时已过期时不恢复开启，并清掉定时与标记", !c.isOn && Power.sleepState == false && c.deadline == nil && !c.shouldRestoreOnLaunch)

// 29
c = fresh("29 重启后在用电池且电量低（15% ≤ 20%）→ 不自动恢复", threshold: 20)
turnOnAndWait(c)
c.cleanupForExit(interactive: false)
c = relaunch("29 重启后在用电池且电量低（15% ≤ 20%）→ 不自动恢复", lid: false, sleep: false, battery: (true, 15))
spin(0.3)
expect("低电量时不自动恢复并发出通知", !c.isOn && Power.sleepState == false && has("NOTIFY 电量低") && !c.shouldRestoreOnLaunch)

// 30
c = fresh("30 重启前有未到期定时 → 重启后自动恢复并继续倒计时")
turnOnAndWait(c)
c.deadline = Date().addingTimeInterval(120)
c.cleanupForExit(interactive: false)
c = relaunch("30 重启前有未到期定时 → 重启后自动恢复并继续倒计时", lid: false, sleep: false)
waitFor(3) { c.isOn && !c.busy }
expect("自动恢复开启且保留未到期定时与倒计时", c.isOn && Power.sleepState == true && (c.deadline?.timeIntervalSinceNow ?? 0) > 60 && c.countdownTimer != nil)

// 31
c = fresh("31 外部关闭 disablesleep → 同步关闭、清除恢复标记并通知")
turnOnAndWait(c)
Power.sleepState = false; c.syncWithSystem()
expect("同步关闭并清除重启恢复标记", !c.isOn && !c.shouldRestoreOnLaunch)
expect("发出外部关闭通知", has("NOTIFY 合盖不休眠已关闭"))

// 32
c = fresh("32 防空闲睡眠断言首次创建失败 → 定期同步自动补建")
failNextAssertion = 1
turnOnAndWait(c)
expect("首次创建断言失败时记录为未持有", c.isOn && assertionsHeld == 0 && c.idleAssertion == 0)
c.syncWithSystem()
expect("syncWithSystem 自动补建防空闲睡眠断言", assertionsHeld == 1 && c.idleAssertion != 0)

// ---------- report ----------
teardownCurrent()
SimDefaults.d.removePersistentDomain(forName: simSuite)
// 清理测试程序自己留下的偏好文件（隐藏菜单栏图标的记录等）
UserDefaults.standard.removePersistentDomain(forName: ProcessInfo.processInfo.processName)
for name in [ProcessInfo.processInfo.processName] {
    try? FileManager.default.removeItem(atPath: NSHomeDirectory() + "/Library/Preferences/\(name).plist")
}
var lastS = ""; var pass = 0
for r in report {
    if r.scenario != lastS { print("\n【\(r.scenario)】"); lastS = r.scenario }
    print("  \(r.ok ? "✅" : "❌") \(r.check)"); if r.ok { pass += 1 }
}
print("\n通过 \(pass)/\(report.count)")
exit(pass == report.count ? 0 : 1)
