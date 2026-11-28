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
        c.stopProtection()
        c.lidWatcher.stop()
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
    FakeUI.responses = []; FakeUI.onRespond = nil; assertionsHeld = 0; failNextAssertion = 0
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
c = fresh("10 合盖用电池，电量降到 19%（低电量暂停）", battery: (true, 50), threshold: 20)
turnOnAndWait(c); setLid(c, true); waitFor { Backlight.panel == 0 }
Power.batteryState = (true, 19); c.checkBattery()      // = 系统电量变化回调
waitFor(3) { !c.isOn }; spin(0.3)
expect("自动关闭 disablesleep 并进入低电量暂停", Power.sleepState == false && c.pausedForLowBattery && c.shouldRestoreOnLaunch)
expect("保持电源监听且释放防空闲睡眠断言", c.powerWatcher.isRunning && assertionsHeld == 0)
expect("发出「电量低（已暂停）」通知", has("NOTIFY 电量低（已暂停）"))
expect("恢复亮度后让电脑睡眠", Backlight.panel == 0.8 && has("run /usr/bin/pmset sleepnow"))
expect("菜单显示暂停状态、无障碍描述与取消自动恢复入口",
       c.statusMenuItem.title.contains("已因低电量暂停")
       && c.toggleMenuItem.title == "立即开启合盖不休眠"
       && !c.cancelPauseMenuItem.isHidden
       && c.cancelPauseMenuItem.isEnabled
       && c.statusItem.button?.toolTip == "合盖不休眠 — 低电量暂停（充电后自动恢复）"
       && c.statusItem.button?.image?.accessibilityDescription == "合盖不休眠：低电量暂停")

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
let failedEnableAttempts = events().filter { $0 == "sudo pmset disablesleep 1 → FAIL" }
expect("3 次失败后通知用户而不静默关闭",
       failedEnableAttempts.count == 3 && !c.isOn && Power.sleepState == false
       && has("NOTIFY 合盖不休眠未能自动恢复") && !c.shouldRestoreOnLaunch)

// 28
c = fresh("28 重启期间原定时已过期 → 不自动恢复")
turnOnAndWait(c)
c.deadline = Date().addingTimeInterval(-60)
c.cleanupForExit(interactive: false)
c = relaunch("28 重启期间原定时已过期 → 不自动恢复", lid: false, sleep: false)
spin(0.3)
expect("定时已过期时不恢复开启，并清掉定时与标记", !c.isOn && Power.sleepState == false && c.deadline == nil && !c.shouldRestoreOnLaunch)

// 29
c = fresh("29 重启后在用电池且电量低（15% ≤ 20%）→ 保持低电量暂停等待恢复", threshold: 20)
turnOnAndWait(c)
c.cleanupForExit(interactive: false)
c = relaunch("29 重启后在用电池且电量低（15% ≤ 20%）→ 保持低电量暂停等待恢复", lid: false, sleep: false, battery: (true, 15))
spin(0.3)
expect("低电量时保持暂停、保留恢复意图、保持电源监听并发出通知",
       !c.isOn && Power.sleepState == false && c.pausedForLowBattery && c.shouldRestoreOnLaunch
       && c.powerWatcher.isRunning && has("NOTIFY 电量低（已暂停）"))

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

// 33
c = fresh("33 外部关闭后立即非手动退出 → 清除恢复标记与定时")
turnOnAndWait(c)
c.deadline = Date().addingTimeInterval(600); c.startCountdown()
Power.sleepState = false   // 模拟终端 pmset disablesleep 0，尚未触发 syncWithSystem
c.cleanupForExit(interactive: false)
expect("检测到系统已关闭，清除恢复标记与定时", !c.shouldRestoreOnLaunch && c.deadline == nil && c.countdownTimer == nil)
c = relaunch("33 外部关闭后立即非手动退出 → 清除恢复标记与定时", lid: false, sleep: false)
spin(0.3)
expect("重开后保持关闭而不误恢复", !c.isOn && Power.sleepState == false && assertionsHeld == 0)

// 34
c = fresh("34 关闭命令执行中遇到非手动退出 → 不保留过期恢复标记")
turnOnAndWait(c)
c.deadline = Date().addingTimeInterval(600); c.startCountdown()
Privileged.delay = 0.25
c.turnOff(reason: .user)
c.cleanupForExit(interactive: false)
expect("等待在途关闭完成后清除恢复标记与定时", !c.shouldRestoreOnLaunch && c.deadline == nil && Power.sleepState == false)
Privileged.delay = 0
c = relaunch("34 关闭命令执行中遇到非手动退出 → 不保留过期恢复标记", lid: false, sleep: false)
spin(0.3)
expect("重开后保持关闭而不误恢复", !c.isOn && Power.sleepState == false && assertionsHeld == 0)

// 35
c = fresh("35 开启命令执行中遇到非手动退出 → 保留恢复标记并安全恢复休眠")
Privileged.delay = 0.25
c.turnOn()
c.cleanupForExit(interactive: false)
expect("等待在途开启完成后记下恢复标记并恢复正常休眠", c.shouldRestoreOnLaunch && Power.sleepState == false)
Privileged.delay = 0
c = relaunch("35 开启命令执行中遇到非手动退出 → 保留恢复标记并安全恢复休眠", lid: false, sleep: false)
waitFor(3) { c.isOn && !c.busy }
expect("重开后自动恢复开启", c.isOn && Power.sleepState == true && assertionsHeld == 1)

// 36
c = fresh("36 重试窗口内外部/延迟恢复开启 → syncWithSystem 接管并启动原倒计时")
turnOnAndWait(c)
c.deadline = Date().addingTimeInterval(120)
c.cleanupForExit(interactive: false)
Privileged.failNext = 1
MenuBarController.restoreRetryDelay = 5.0
c = relaunch("36 重试窗口内外部/延迟恢复开启 → syncWithSystem 接管并启动原倒计时", lid: false, sleep: false)
waitFor(3) { !c.busy && c.pendingRestore != nil }
expect("首次失败后处于重试等待且保留原定时", !c.isOn && c.pendingRestore != nil && c.deadline != nil && c.countdownTimer == nil)
Power.sleepState = true
c.syncWithSystem()
expect("syncWithSystem 接管开启并启动保存的倒计时",
       c.isOn && c.pendingRestore == nil && assertionsHeld == 1 && c.countdownTimer != nil && (c.deadline?.timeIntervalSinceNow ?? 0) > 60)
c.deadline = Date().addingTimeInterval(0.3)
waitFor(3) { !c.isOn }
expect("接管后的倒计时正常到期关闭", !c.isOn && Power.sleepState == false && has("NOTIFY 定时到"))

// 37
c = fresh("37 低电量暂停后接通电源 → 自动重新开启", battery: (true, 50), threshold: 20)
turnOnAndWait(c)
Power.batteryState = (true, 20); c.checkBattery()
waitFor(3) { !c.isOn && c.pausedForLowBattery }
resetEvents()
Power.batteryState = (false, 20); c.checkBattery()
waitFor(3) { c.isOn && !c.busy }
expect("接通电源后自动恢复 disablesleep=1、断言与合盖监听",
       c.isOn && Power.sleepState == true && !c.pausedForLowBattery && c.shouldRestoreOnLaunch
       && assertionsHeld == 1 && c.lidWatcher.isRunning && c.cancelPauseMenuItem.isHidden)
expect("发出「合盖不休眠已自动恢复」通知", has("NOTIFY 合盖不休眠已自动恢复"))

// 38
c = fresh("38 低电量暂停 → 充电到 91% 后重启（电池 91%）→ 启动时自动恢复", battery: (true, 50), threshold: 20)
turnOnAndWait(c)
Power.batteryState = (true, 20); c.checkBattery()
waitFor(3) { !c.isOn && c.pausedForLowBattery }
c.cleanupForExit(interactive: false)
expect("非手动退出保留低电量暂停与恢复标记", c.pausedForLowBattery && c.shouldRestoreOnLaunch && !c.powerWatcher.isRunning)
c = relaunch("38 低电量暂停 → 充电到 91% 后重启（电池 91%）→ 启动时自动恢复", lid: false, sleep: false, battery: (true, 91))
waitFor(3) { c.isOn && !c.busy }
expect("重启后电池 91% 自动恢复开启并持有断言与合盖监听",
       c.isOn && Power.sleepState == true && !c.pausedForLowBattery && c.shouldRestoreOnLaunch
       && assertionsHeld == 1 && c.lidWatcher.isRunning && has("NOTIFY 合盖不休眠已自动恢复"))

// 39
c = fresh("39 低电量暂停后深度睡眠唤醒（无 IOPS 回调）→ systemDidWake 自动恢复", battery: (true, 50), threshold: 20)
turnOnAndWait(c)
Power.batteryState = (true, 18); c.checkBattery()
waitFor(3) { !c.isOn && c.pausedForLowBattery }
resetEvents()
Power.batteryState = (false, 25)
c.systemDidWake()
waitFor(3) { c.isOn && !c.busy }
expect("唤醒后自动恢复开启", c.isOn && Power.sleepState == true && !c.pausedForLowBattery && assertionsHeld == 1 && has("NOTIFY 合盖不休眠已自动恢复"))

// 40
c = fresh("40 低电量暂停后用户点击「取消自动恢复」→ 插电和重启均保持关闭", battery: (true, 50), threshold: 20)
turnOnAndWait(c)
c.deadline = Date().addingTimeInterval(600); c.startCountdown()
Power.batteryState = (true, 18); c.checkBattery()
waitFor(3) { !c.isOn && c.pausedForLowBattery }
c.cancelLowBatteryPause()
expect("取消后清除暂停、恢复标记、定时并停止电源监听",
       !c.pausedForLowBattery && !c.shouldRestoreOnLaunch && c.deadline == nil
       && !c.powerWatcher.isRunning && c.cancelPauseMenuItem.isHidden)
Power.batteryState = (false, 80); c.checkBattery(); spin(0.3)
expect("接通电源后保持关闭", !c.isOn && Power.sleepState == false)
c = relaunch("40 低电量暂停后用户点击「取消自动恢复」→ 插电和重启均保持关闭", lid: false, sleep: false, battery: (false, 100))
spin(0.3)
expect("重启后仍保持关闭", !c.isOn && Power.sleepState == false && assertionsHeld == 0)

// 41
c = fresh("41 低电量暂停期间用户主动点「退出」→ 重开接电源保持关闭", battery: (true, 50), threshold: 20)
turnOnAndWait(c)
Power.batteryState = (true, 18); c.checkBattery()
waitFor(3) { !c.isOn && c.pausedForLowBattery }
c.cleanupForExit(interactive: true)
expect("手动退出清除暂停与恢复标记", !c.pausedForLowBattery && !c.shouldRestoreOnLaunch && !c.powerWatcher.isRunning)
c = relaunch("41 低电量暂停期间用户主动点「退出」→ 重开接电源保持关闭", lid: false, sleep: false, battery: (false, 100))
spin(0.3)
expect("重开后保持关闭", !c.isOn && Power.sleepState == false && assertionsHeld == 0)

// 42
c = fresh("42 低电量暂停期间调低或关闭低电量阈值 → 立即自动恢复", battery: (true, 50), threshold: 20)
turnOnAndWait(c)
Power.batteryState = (true, 15); c.checkBattery()
waitFor(3) { !c.isOn && c.pausedForLowBattery }
let thresh10 = NSMenuItem(); thresh10.representedObject = 10
resetEvents()
c.setBatteryThreshold(thresh10)
waitFor(3) { c.isOn && !c.busy }
expect("阈值从 20% 调低到 10%（当前 15%）→ 立即自动恢复", c.isOn && Power.sleepState == true && !c.pausedForLowBattery && has("NOTIFY 合盖不休眠已自动恢复"))
// 再触发一次暂停后把阈值设为「不启用」(0%)
Power.batteryState = (true, 8); c.checkBattery()
waitFor(3) { !c.isOn && c.pausedForLowBattery }
let thresh0 = NSMenuItem(); thresh0.representedObject = 0
resetEvents()
c.setBatteryThreshold(thresh0)
waitFor(3) { c.isOn && !c.busy }
expect("阈值设为「不启用」(0%) → 立即自动恢复", c.isOn && Power.sleepState == true && !c.pausedForLowBattery && has("NOTIFY 合盖不休眠已自动恢复"))

// 43
c = fresh("43 低电量暂停与定时关闭交互（未到期继续 / 已到期取消）", battery: (true, 50), threshold: 20)
turnOnAndWait(c)
c.deadline = Date().addingTimeInterval(300); c.startCountdown()
Power.batteryState = (true, 18); c.checkBattery()
waitFor(3) { !c.isOn && c.pausedForLowBattery }
expect("暂停时保留未到期定时、停掉倒计时器并显示剩余时间",
       c.deadline != nil && c.countdownTimer == nil
       && !c.detailMenuItem.isHidden && c.detailMenuItem.title.contains("原定时剩余")
       && c.detailMenuItem.title.contains("自动恢复后继续"))
Power.batteryState = (false, 50); c.checkBattery()
waitFor(3) { c.isOn && !c.busy }
expect("恢复开启后继续原定时倒计时", c.isOn && c.deadline != nil && c.countdownTimer != nil)
// 再次暂停并模拟暂停期间定时到期
Power.batteryState = (true, 18); c.checkBattery()
waitFor(3) { !c.isOn && c.pausedForLowBattery }
c.deadline = Date().addingTimeInterval(-10)
resetEvents()
Power.batteryState = (false, 80); c.checkBattery(); spin(0.3)
expect("暂停期间定时已到期 → 不自动恢复并清除状态",
       !c.isOn && Power.sleepState == false && !c.pausedForLowBattery && !c.shouldRestoreOnLaunch
       && c.deadline == nil && !c.powerWatcher.isRunning)

// 44
c = fresh("44 低电量恢复时 sudo 失败重试（1 次成功 / 3 次放弃并通知）", battery: (true, 50), threshold: 20)
turnOnAndWait(c)
Power.batteryState = (true, 18); c.checkBattery()
waitFor(3) { !c.isOn && c.pausedForLowBattery }
resetEvents()
Privileged.failNext = 1
Power.batteryState = (false, 30); c.checkBattery()
waitFor(3) { c.isOn && !c.busy }
expect("1 次失败后重试成功恢复", c.isOn && Power.sleepState == true && !c.pausedForLowBattery && has("sudo pmset disablesleep 1 → FAIL") && has("NOTIFY 合盖不休眠已自动恢复"))
// 再触发暂停，模拟连续 3 次失败
Power.batteryState = (true, 18); c.checkBattery()
waitFor(3) { !c.isOn && c.pausedForLowBattery }
resetEvents()
Privileged.failNext = 5
Power.batteryState = (false, 30); c.checkBattery()
waitFor(3) { has("NOTIFY 合盖不休眠未能自动恢复") }
let resumeFailCount = events().filter { $0 == "sudo pmset disablesleep 1 → FAIL" }.count
expect("连续 3 次失败后通知用户、清除状态并停止电源监听",
       resumeFailCount == 3 && !c.isOn && Power.sleepState == false
       && !c.pausedForLowBattery && !c.shouldRestoreOnLaunch && !c.powerWatcher.isRunning)

// 45
c = fresh("45 低电量暂停期间用户手动坚持开启 → 清除暂停状态并保持开启", battery: (true, 50), threshold: 20)
turnOnAndWait(c)
Power.batteryState = (true, 15); c.checkBattery()
waitFor(3) { !c.isOn && c.pausedForLowBattery }
resetEvents()
FakeUI.responses = [.alertFirstButtonReturn]
turnOnAndWait(c)
expect("手动确认后开启并清除低电量暂停标记",
       c.isOn && Power.sleepState == true && !c.pausedForLowBattery && c.shouldRestoreOnLaunch
       && has("ALERT 电量只剩 15%") && c.cancelPauseMenuItem.isHidden)
Power.batteryState = (true, 14); c.checkBattery(); spin(0.3)
expect("电量继续降到 14% 仍保持开启（本次已确认忽略）", c.isOn && Power.sleepState == true)

// 46
c = fresh("46 低电量暂停后重启时仍为低电量 → 保持暂停 → 接电自动恢复", battery: (true, 50), threshold: 20)
turnOnAndWait(c)
Power.batteryState = (true, 15); c.checkBattery()
waitFor(3) { !c.isOn && c.pausedForLowBattery }
c.cleanupForExit(interactive: false)
c = relaunch("46 低电量暂停后重启时仍为低电量 → 保持暂停 → 接电自动恢复", lid: false, sleep: false, battery: (true, 15))
spin(0.3)
expect("重启时仍为 15% → 保持低电量暂停且电源监听运行中",
       !c.isOn && Power.sleepState == false && c.pausedForLowBattery && c.shouldRestoreOnLaunch && c.powerWatcher.isRunning)
resetEvents()
Power.batteryState = (false, 16); c.checkBattery()
waitFor(3) { c.isOn && !c.busy }
expect("接通电源后自动恢复开启", c.isOn && Power.sleepState == true && !c.pausedForLowBattery && assertionsHeld == 1 && has("NOTIFY 合盖不休眠已自动恢复"))

// 47
c = fresh("47 低电量暂停恢复时缺少免密配置 → 清除状态并通知", battery: (true, 50), threshold: 20)
turnOnAndWait(c)
Power.batteryState = (true, 15); c.checkBattery()
waitFor(3) { !c.isOn && c.pausedForLowBattery }
resetEvents()
Privileged.ownRuleInstalled = false
Power.batteryState = (false, 50); c.checkBattery(); spin(0.3)
expect("缺少免密配置时不开启、清除标记并通知",
       !c.isOn && Power.sleepState == false && !c.pausedForLowBattery && !c.shouldRestoreOnLaunch
       && !c.powerWatcher.isRunning && has("NOTIFY 合盖不休眠未自动恢复"))

// 48
c = fresh("48 低电量暂停期间外部开启 disablesleep → syncWithSystem 接管并清除暂停标记", battery: (true, 50), threshold: 20)
turnOnAndWait(c)
Power.batteryState = (true, 15); c.checkBattery()
waitFor(3) { !c.isOn && c.pausedForLowBattery }
Power.batteryState = (false, 50)
Power.sleepState = true
c.syncWithSystem()
expect("syncWithSystem 接管开启并清除低电量暂停标记",
       c.isOn && !c.pausedForLowBattery && c.shouldRestoreOnLaunch && assertionsHeld == 1 && c.cancelPauseMenuItem.isHidden)

// 49
c = fresh("49 cleanupForExit 停止定时器与防抖任务，且 terminating 后 tick 不再触发关闭")
turnOnAndWait(c)
c.deadline = Date().addingTimeInterval(600); c.startCountdown()
setLid(c, true) // 安排 pendingDim
c.cleanupForExit(interactive: false)
expect("退出后 countdownTimer/statusTimer/pendingDim/powerWatcher 均已停止",
       c.countdownTimer == nil && c.statusTimer == nil && c.pendingDim == nil && !c.powerWatcher.isRunning)
c.deadline = Date().addingTimeInterval(-10)
resetEvents()
c.tick()
expect("terminating 状态下 tick() 直接忽略，不清除 deadline 也不发命令",
       c.deadline != nil && !has("sudo pmset"))

// 50
c = fresh("50 低电量弹窗期间电源恢复（模态重入防护）", battery: (true, 50), threshold: 20)
turnOnAndWait(c)
Power.batteryState = (true, 15); c.powerWatcher.fire()
waitFor(3) { !c.isOn && c.pausedForLowBattery }
resetEvents()
FakeUI.responses = [.alertFirstButtonReturn]
FakeUI.onRespond = { _ in
    Power.batteryState = (false, 15)
    c.powerWatcher.fire()
    _ = waitFor(3) { c.isOn && !c.busy }
}
c.turnOn(); spin(0.2)
expect("弹窗期间自动恢复已完成 → 点击仍然开启不重复下发 disablesleep 1",
       c.isOn && !c.busy && !c.pausedForLowBattery
       && events().filter { $0 == "sudo pmset disablesleep 1" }.count == 1)
// 子场景：弹窗期间自动恢复尚在执行（busy == true）
Power.batteryState = (true, 15); c.powerWatcher.fire()
waitFor(3) { !c.isOn && c.pausedForLowBattery }
resetEvents()
Privileged.delay = 0.25
FakeUI.responses = [.alertFirstButtonReturn]
FakeUI.onRespond = { _ in
    Power.batteryState = (false, 15)
    c.powerWatcher.fire() // 开始异步 restoreOnLaunch，此时 busy == true
}
c.turnOn()
waitFor(3) { c.isOn && !c.busy }; spin(0.1)
Privileged.delay = 0
expect("弹窗期间自动恢复仍在进行（busy）→ 不重复下发 disablesleep 1 且最终开启",
       c.isOn && !c.busy && !c.pausedForLowBattery
       && events().filter { $0 == "sudo pmset disablesleep 1" }.count == 1)

// 51
c = fresh("51 电池恢复 +5% 迟滞 vs 插电/降阈值立即恢复", battery: (true, 50), threshold: 20)
turnOnAndWait(c)
Power.batteryState = (true, 20); c.powerWatcher.fire()
waitFor(3) { !c.isOn && c.pausedForLowBattery }
Power.batteryState = (true, 21); c.powerWatcher.fire(); spin(0.2)
Power.batteryState = (true, 24); c.powerWatcher.fire(); spin(0.2)
expect("电池 21%~24% 未达 20%+5% 迟滞阈值 → 保持暂停", !c.isOn && c.pausedForLowBattery && Power.sleepState == false)
// 24% 时重启也保持暂停
c.cleanupForExit(interactive: false)
c = relaunch("51 电池恢复 +5% 迟滞 vs 插电/降阈值立即恢复", lid: false, sleep: false, battery: (true, 24))
spin(0.3)
expect("暂停状态下 24% 重启仍保持暂停", !c.isOn && c.pausedForLowBattery && c.powerWatcher.isRunning)
// 充到 25%（阈值 + 5%）→ 自动恢复
Power.batteryState = (true, 25); c.powerWatcher.fire()
waitFor(3) { c.isOn && !c.busy }
expect("电池达到 25%（阈值 +5%）→ 自动恢复开启", c.isOn && Power.sleepState == true && !c.pausedForLowBattery)
// 再次暂停在 18%，用户把阈值降到 15%（18% > 15% 但 < 15%+5%）→ 立即恢复
Power.batteryState = (true, 18); c.powerWatcher.fire()
waitFor(3) { !c.isOn && c.pausedForLowBattery }
let thresh15 = NSMenuItem(); thresh15.representedObject = 15
c.setBatteryThreshold(thresh15)
waitFor(3) { c.isOn && !c.busy }
expect("用户手动调低阈值（18% > 15%）→ 无须等 +5% 立即恢复", c.isOn && Power.sleepState == true && !c.pausedForLowBattery)
// 再次暂停在 15%，插电（仍为 15%）→ 立即恢复
Power.batteryState = (true, 15); c.powerWatcher.fire()
waitFor(3) { !c.isOn && c.pausedForLowBattery }
Power.batteryState = (false, 15); c.powerWatcher.fire()
waitFor(3) { c.isOn && !c.busy }
expect("接通电源即使电量仍为 15% 也立即恢复", c.isOn && Power.sleepState == true && !c.pausedForLowBattery)

// 52
c = fresh("52 暂停期间 Power.battery() == nil 按未恢复处理（fail-closed）且不影响台式机正常重启", battery: (true, 50), threshold: 20)
turnOnAndWait(c)
Power.batteryState = (true, 15); c.powerWatcher.fire()
waitFor(3) { !c.isOn && c.pausedForLowBattery }
Power.batteryState = nil; c.powerWatcher.fire(); spin(0.2)
expect("暂停期间电池读数为 nil 且阈值 > 0 → 保持暂停", !c.isOn && c.pausedForLowBattery && Power.sleepState == false)
c.cleanupForExit(interactive: false)
c = relaunch("52 暂停期间 Power.battery() == nil 按未恢复处理（fail-closed）且不影响台式机正常重启", lid: false, sleep: false, battery: nil)
spin(0.3)
expect("暂停状态重启且电池读数为 nil → 保持暂停并运行电源监听", !c.isOn && c.pausedForLowBattery && c.powerWatcher.isRunning)
// 设为不启用（阈值 0%）→ 立即恢复
c.setBatteryThreshold(thresh0)
waitFor(3) { c.isOn && !c.busy }
expect("电池读数为 nil 时把阈值设为 0% → 立即恢复", c.isOn && Power.sleepState == true && !c.pausedForLowBattery)
// 台式机（battery == nil，非低电量暂停）正常重启恢复
c = fresh("52 台式机（无电池）非手动重启正常恢复", battery: nil, threshold: 20)
turnOnAndWait(c)
c.cleanupForExit(interactive: false)
c = relaunch("52 台式机（无电池）非手动重启正常恢复", lid: false, sleep: false, battery: nil)
waitFor(3) { c.isOn && !c.busy }
expect("台式机（battery=nil 且非低电量暂停）重启正常自动恢复", c.isOn && Power.sleepState == true && !c.pausedForLowBattery)

// 53
c = fresh("53 低电量关闭执行中接通电源或关闭保护 → 取消 sleepnow 并立即恢复", battery: (true, 50), threshold: 20)
turnOnAndWait(c); setLid(c, true); waitFor { Backlight.panel == 0 }
resetEvents()
Privileged.delay = 0.25
Power.batteryState = (true, 18); c.powerWatcher.fire()
spin(0.05) // 此时 turnOff(.battery) 正在 workQueue 执行 pmset disablesleep 0
Power.batteryState = (false, 18) // 执行期间插电
waitFor(3) { c.isOn && !c.busy && !c.pausedForLowBattery }; spin(0.1)
Privileged.delay = 0
expect("执行中插电：不执行 pmset sleepnow、不发低电量暂停通知并立即恢复开启",
       c.isOn && Power.sleepState == true && !c.pausedForLowBattery
       && !has("run /usr/bin/pmset sleepnow") && !has("NOTIFY 电量低（已暂停）")
       && Backlight.panel == 0 && !has("restore wake=true"))
// 子场景：执行中用户关闭低电量保护（threshold -> 0）
Power.batteryState = (true, 50); c.powerWatcher.fire()
resetEvents()
Privileged.delay = 0.25
Power.batteryState = (true, 18); c.powerWatcher.fire()
spin(0.05)
c.setBatteryThreshold(thresh0)
waitFor(3) { c.isOn && !c.busy && !c.pausedForLowBattery }; spin(0.1)
Privileged.delay = 0
expect("执行中禁用低电量保护：不执行 pmset sleepnow 并立即恢复开启",
       c.isOn && Power.sleepState == true && !c.pausedForLowBattery && !has("run /usr/bin/pmset sleepnow"))

// 54
c = fresh("54 低电量关闭执行中遇到非手动退出（未到期保留 / 已到期清除）", battery: (true, 50), threshold: 20)
turnOnAndWait(c)
c.deadline = Date().addingTimeInterval(600); c.startCountdown()
Privileged.delay = 0.25
Power.batteryState = (true, 18); c.powerWatcher.fire()
c.cleanupForExit(interactive: false)
Privileged.delay = 0
expect("未到期定时：非手动退出保留低电量暂停、恢复标记与定时",
       c.pausedForLowBattery && c.shouldRestoreOnLaunch && c.deadline != nil && Power.sleepState == false)
c = relaunch("54 低电量关闭执行中遇到非手动退出（未到期保留 / 已到期清除）", lid: false, sleep: false, battery: (false, 80))
waitFor(3) { c.isOn && !c.busy }
expect("重启接电后自动恢复并继续定时", c.isOn && c.countdownTimer != nil && c.deadline != nil)
// 子场景：定时已到期
c = fresh("54 低电量关闭执行中遇到非手动退出（已到期定时）", battery: (true, 50), threshold: 20)
turnOnAndWait(c)
c.deadline = Date().addingTimeInterval(-10)
Privileged.delay = 0.25
Power.batteryState = (true, 18); c.powerWatcher.fire()
c.cleanupForExit(interactive: false)
Privileged.delay = 0
expect("已到期定时：非手动退出清除低电量暂停、恢复标记与定时",
       !c.pausedForLowBattery && !c.shouldRestoreOnLaunch && c.deadline == nil && Power.sleepState == false)
c = relaunch("54 低电量关闭执行中遇到非手动退出（已到期定时）", lid: false, sleep: false, battery: (false, 80))
spin(0.3)
expect("重开接电保持关闭", !c.isOn && Power.sleepState == false)

// 55
c = fresh("55 低电量恢复执行中遇到非手动退出 → 安全恢复休眠并在重启后自动开启", battery: (true, 50), threshold: 20)
turnOnAndWait(c)
Power.batteryState = (true, 15); c.powerWatcher.fire()
waitFor(3) { !c.isOn && c.pausedForLowBattery }
Privileged.delay = 0.25
Power.batteryState = (false, 50); c.powerWatcher.fire()
c.cleanupForExit(interactive: false)
Privileged.delay = 0
expect("恢复途中非手动退出：等待完成并安全恢复 disablesleep=0，保留恢复标记",
       Power.sleepState == false && c.shouldRestoreOnLaunch && !c.pausedForLowBattery)
c = relaunch("55 低电量恢复执行中遇到非手动退出 → 安全恢复休眠并在重启后自动开启", lid: false, sleep: false, battery: (false, 50))
waitFor(3) { c.isOn && !c.busy }
expect("重启后自动恢复开启", c.isOn && Power.sleepState == true && assertionsHeld == 1)

// 56
c = fresh("56 合盖低电量暂停后盖子仍合着时插电 → 自动恢复并重新关背光且不唤醒屏幕", battery: (true, 50), threshold: 20)
turnOnAndWait(c); setLid(c, true); waitFor { Backlight.panel == 0 }
Power.batteryState = (true, 19); c.powerWatcher.fire()
waitFor(3) { !c.isOn && c.pausedForLowBattery }; spin(0.3)
expect("低电量暂停睡眠前已恢复亮度", Backlight.panel == 0.8 && has("run /usr/bin/pmset sleepnow"))
resetEvents()
Power.batteryState = (false, 19); c.powerWatcher.fire()
waitFor(3) { c.isOn && !c.busy }
waitFor(2) { Backlight.panel == 0 }
expect("盖子仍合着时插电恢复：开启 disablesleep、重新关背光且不唤醒显示器",
       c.isOn && Power.sleepState == true && Backlight.panel == 0 && !has("restore wake=true"))

// 57
c = fresh("57 定时已过期时触发低电量关闭 → 不进入低电量暂停、停止电源监听", battery: (true, 50), threshold: 20)
turnOnAndWait(c)
c.deadline = Date().addingTimeInterval(-10)
resetEvents()
Power.batteryState = (true, 18); c.powerWatcher.fire()
waitFor(3) { !c.isOn }; spin(0.2)
expect("已过期定时触发低电量关闭：清除状态、不暂停、停电源监听且不发已暂停通知",
       !c.isOn && Power.sleepState == false && !c.pausedForLowBattery && !c.shouldRestoreOnLaunch
       && c.deadline == nil && !c.powerWatcher.isRunning
       && has("NOTIFY 电量低") && !has("NOTIFY 电量低（已暂停）"))
Power.batteryState = (false, 80); c.powerWatcher.fire(); spin(0.2)
expect("之后插电不再自动恢复", !c.isOn && Power.sleepState == false)

// 58
c = fresh("58 低电量暂停状态下直接选定时（30 分钟）→ 开启、清除暂停并开始倒计时", battery: (true, 50), threshold: 20)
turnOnAndWait(c)
Power.batteryState = (true, 15); c.powerWatcher.fire()
waitFor(3) { !c.isOn && c.pausedForLowBattery }
FakeUI.responses = [.alertFirstButtonReturn]
c.setAutoOff(timer30)
waitFor(3) { c.isOn && !c.busy }; spin(0.1)
let rem58 = c.deadline?.timeIntervalSinceNow ?? 0
expect("确认低电量后开启、清除暂停并启动 30 分钟倒计时",
       c.isOn && Power.sleepState == true && !c.pausedForLowBattery && c.countdownTimer != nil
       && rem58 > 29 * 60 && rem58 <= 30 * 60)

// 59
c = fresh("59 Fake PowerSourceWatcher.fire() 仅在 isRunning 时触发回调", battery: (true, 50), threshold: 20)
turnOnAndWait(c)
Power.batteryState = (true, 15); c.powerWatcher.fire()
waitFor(3) { !c.isOn && c.pausedForLowBattery }
expect("暂停时 powerWatcher 在运行", c.powerWatcher.isRunning)
c.cancelLowBatteryPause()
expect("取消暂停后 powerWatcher 已停止", !c.powerWatcher.isRunning)
Power.batteryState = (false, 100)
c.powerWatcher.fire(); spin(0.2)
expect("停止后 fire() 不触发回调、保持关闭", !c.isOn && Power.sleepState == false)

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
