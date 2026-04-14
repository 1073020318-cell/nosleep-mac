#!/usr/bin/env swift
// ============================================================
//  合盖不休眠 v15 — 菜单栏版（含定时关闭功能）
//
//  功能：
//    - 菜单栏常驻图标（NSStatusItem），不占 Dock 位置
//    - 一键开/关合盖不休眠
//    - 合盖自动关屏幕背光，开盖秒亮
//    - 定时关闭（30分钟/1h/2h/4h/8h）
//    - 倒计时实时显示（精确到秒，每秒刷新）
//    - 完整卸载功能（清理 sudoers + 临时文件 + pmset 恢复）
//
//  编译：
//    swiftc -o menulet menulet.swift -framework Cocoa
//
//  作者：龙皇
//
// ============================================================

import Cocoa
import UserNotifications

class MenuBarController: NSObject, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()

    // 菜单项
    let statusMenuItem = NSMenuItem(title: "检测中…", action: nil, keyEquivalent: "")
    let toggleMenuItem = NSMenuItem(title: "开启合盖不休眠", action: #selector(toggleFeature), keyEquivalent: "")
    let timerMenuItem = NSMenuItem(title: "⏱ 定时关闭", action: nil, keyEquivalent: "")
    let cancelTimerMenuItem = NSMenuItem(title: "取消定时", action: #selector(cancelAutoOff), keyEquivalent: "")
    let aboutMenuItem = NSMenuItem(title: "关于", action: #selector(showAbout), keyEquivalent: "")
    let quitMenuItem = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
    let uninstallMenuItem = NSMenuItem(title: "卸载并退出", action: #selector(uninstallApp), keyEquivalent: "")

    // 定时器
    var refreshTimer: Timer?          // 5秒周期状态刷新
    var autoOffDeadline: Date?
    var autoOffTimer: Timer?          // 每秒检查定时触发
    var lastTickSecond: Int = 0       // 上次刷新的整秒数，避免重复刷新或跳秒

    // 缓存状态
    var lastKnownState: Bool = false

    // 脚本路径
    let scriptDir: String = {
        let path = Bundle.main.executablePath ?? ""
        return (path as NSString).deletingLastPathComponent
    }()
    var backlightctl: String { return scriptDir + "/backlightctl" }

    // lidwatch PID 文件
    let lidwatchPidFile = "/tmp/nosleep_lidwatch.pid"
    let lidwatchScript = "/tmp/nosleep_lidwatch.sh"

    // ============================================================
    // MARK: - 启动
    // ============================================================

    override init() {
        super.init()
        setupMenu()
        refreshStatus()
        startRefreshTimer()
        startPreciseTick()
    }

    func loadFallbackIcon() -> NSImage? {
        let bundle = Bundle.main
        if let iconPath = bundle.path(forResource: "AppIcon", ofType: "icns"),
           let iconImg = NSImage(contentsOfFile: iconPath) {
            return iconImg
        }
        if let iconPath = bundle.path(forResource: "AppIcon", ofType: "jpg"),
           let iconImg = NSImage(contentsOfFile: iconPath) {
            return iconImg
        }
        return nil
    }

    func setupMenu() {
        // 图标
        if let button = statusItem.button {
            let img: NSImage?
            if #available(macOS 11.0, *) {
                img = NSImage(systemSymbolName: "moon.zzz", accessibilityDescription: "合盖不休眠")
            } else {
                img = loadFallbackIcon()
            }
            img?.size = NSSize(width: 18, height: 18)
            img?.isTemplate = true
            button.image = img
            button.toolTip = "合盖不休眠"
        }

        // 菜单项
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem.separator())
        toggleMenuItem.target = self
        menu.addItem(toggleMenuItem)

        // 定时子菜单
        let timerSubMenu = NSMenu()
        for (label, minutes) in [("30 分钟", 30), ("1 小时", 60), ("2 小时", 120), ("4 小时", 240), ("8 小时", 480)] {
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

        menu.addItem(NSMenuItem.separator())
        aboutMenuItem.target = self
        menu.addItem(aboutMenuItem)
        quitMenuItem.target = self
        menu.addItem(quitMenuItem)
        menu.addItem(NSMenuItem.separator())

        // 卸载（红色）
        uninstallMenuItem.target = self
        let attrTitle = NSAttributedString(string: "卸载并退出", attributes: [
            .foregroundColor: NSColor.systemRed,
            .font: NSFont.menuFont(ofSize: 0)
        ])
        uninstallMenuItem.attributedTitle = attrTitle
        menu.addItem(uninstallMenuItem)

        statusItem.menu = menu
        menu.delegate = self
    }

    func menuWillOpen(_ menu: NSMenu) {
        if toggleMenuItem.title.isEmpty {
            toggleMenuItem.title = "开启合盖不休眠"
        }
        toggleMenuItem.isEnabled = true
        // 菜单打开时立即刷新倒计时显示
        updateTimerDisplay()
    }

    // ============================================================
    // MARK: - 状态检测
    // ============================================================

    func checkFeatureOn(from pmsetOutput: String) -> Bool {
        if let range = pmsetOutput.range(of: "SleepDisabled") {
            let after = pmsetOutput[range.upperBound...]
            let trimmed = after.trimmingCharacters(in: CharacterSet(charactersIn: "\t"))
            return trimmed.hasPrefix("1")
        }
        return false
    }

    func isLidwatchAlive() -> Bool {
        guard FileManager.default.fileExists(atPath: lidwatchPidFile),
              let pidStr = try? String(contentsOfFile: lidwatchPidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
              let pid = Int32(pidStr) else {
            return false
        }
        return kill(pid, 0) == 0
    }

    // ============================================================
    // MARK: - 开关功能
    // ============================================================

    @objc func toggleFeature() {
        if lastKnownState {
            disableFeatureAsync()
        } else {
            enableFeatureAsync()
        }
    }

    func enableFeatureAsync() {
        statusMenuItem.title = "⏳ 正在开启…"
        toggleMenuItem.isEnabled = false

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // 1. 设置 pmset
            self.shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disablesleep", "1")
            self.shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "sleep", "0")
            self.shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "displaysleep", "0")
            self.shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disksleep", "0")

            // 2. 写 lidwatch 脚本
            // ★ 关键修复：ioreg 必须用 -l -p IOService 才能读到 AppleClamshellState
            let script = """
#!/bin/bash
# lidwatch — 监听合盖/开盖，控制背光
LOG="/tmp/nosleep_debug.log"
BACKLIGHTCTL="\(self.backlightctl)"
LAST_STATE=""

while true; do
    # ★ 修复：用 ioreg -l -p IOService 才能正确读取合盖状态
    STATE=$(ioreg -l -p IOService | grep '"AppleClamshellState"' | head -1 | sed 's/.*= //' | tr -d '[:space:]')

    if [ "$STATE" = "Yes" ] && [ "$LAST_STATE" != "Yes" ]; then
        echo "[$(date '+%H:%M:%S')] 合盖 → 关背光" >> "$LOG"
        "$BACKLIGHTCTL" off 2>> "$LOG"
        LAST_STATE="Yes"
    elif [ "$STATE" = "No" ] && [ "$LAST_STATE" != "No" ]; then
        echo "[$(date '+%H:%M:%S')] 开盖 → 恢复背光" >> "$LOG"
        "$BACKLIGHTCTL" on 2>> "$LOG"
        /usr/bin/caffeinate -u -t 1 2>/dev/null
        LAST_STATE="No"
    fi

    sleep 0.5
done
"""
            try? script.write(toFile: self.lidwatchScript, atomically: true, encoding: .utf8)
            self.shell("/bin/chmod", "+x", self.lidwatchScript)

            // 3. 启动 lidwatch（后台执行，获取 PID）
            let pid = self.shell("/bin/bash", "-c", "\(self.lidwatchScript) & echo $!")
            let cleanPid = pid.trimmingCharacters(in: .whitespacesAndNewlines)
            try? cleanPid.write(toFile: self.lidwatchPidFile, atomically: true, encoding: .utf8)

            // 4. 回主线程更新 UI + 通知
            DispatchQueue.main.async {
                self.lastKnownState = true
                self.notify("合盖不休眠已开启", "合盖后电脑将继续运行，屏幕自动关闭省电")
                self.refreshStatus()
            }
        }
    }

    func disableFeatureAsync() {
        statusMenuItem.title = "⏳ 正在关闭…"
        toggleMenuItem.isEnabled = false

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // 1. 恢复 pmset
            self.shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disablesleep", "0")
            self.shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "sleep", "1")
            self.shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "displaysleep", "10")
            self.shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disksleep", "10")

            // 2. 停止 lidwatch
            self.stopLidwatch()

            // 3. 清除定时
            DispatchQueue.main.sync {
                self.cancelAutoOff()
            }

            // 4. 回主线程更新 UI + 通知
            DispatchQueue.main.async {
                self.lastKnownState = false
                self.notify("合盖不休眠已关闭", "电脑恢复正常休眠")
                self.refreshStatus()
            }
        }
    }

    func stopLidwatch() {
        if FileManager.default.fileExists(atPath: lidwatchPidFile),
           let pidStr = try? String(contentsOfFile: lidwatchPidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = Int32(pidStr) {
            kill(pid, SIGTERM)
        }
        try? FileManager.default.removeItem(atPath: lidwatchPidFile)
    }

    // ============================================================
    // MARK: - 定时关闭
    // ============================================================

    @objc func setAutoOff(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Int else { return }
        autoOffDeadline = Date().addingTimeInterval(TimeInterval(minutes * 60))

        // 启动检查定时器（每秒检查一次）
        autoOffTimer?.invalidate()
        autoOffTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkAutoOff()
        }

        refreshStatus()
        let hours = Double(minutes) / 60.0
        notify("定时已设置", "\(hours == floor(hours) ? "\(Int(hours))小时" : "\(minutes)分钟")后自动关闭")
    }

    @objc func cancelAutoOff() {
        autoOffDeadline = nil
        autoOffTimer?.invalidate()
        autoOffTimer = nil
        refreshStatus()
    }

    func checkAutoOff() {
        guard let deadline = autoOffDeadline else {
            autoOffTimer?.invalidate()
            autoOffTimer = nil
            return
        }
        if Date() >= deadline {
            autoOffDeadline = nil
            autoOffTimer?.invalidate()
            autoOffTimer = nil
            if lastKnownState {
                disableFeatureAsync()
            }
            notify("定时到", "合盖不休眠已自动关闭")
        }
    }

    func formatRemaining(_ seconds: TimeInterval) -> String {
        let totalSec = max(0, Int(seconds))
        let h = totalSec / 3600
        let m = (totalSec % 3600) / 60
        let s = totalSec % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%d:%02d", m, s)
        }
    }

    // ============================================================
    // MARK: - 刷新 UI
    // ============================================================

    func refreshStatus() {
        // 状态检测在后台线程执行
        shellAsync(["/usr/bin/sudo", "-n", "/usr/bin/pmset", "-g"]) { [weak self] result in
            guard let self = self else { return }

            let on = self.checkFeatureOn(from: result)
            self.lastKnownState = on
            let alive = self.isLidwatchAlive()

            self.updateUI(on: on, lidwatchAlive: alive)
        }
    }

    // ★ 仅更新倒计时相关显示，不执行 shell（每秒调用）
    func updateTimerDisplay() {
        let remaining = autoOffDeadline?.timeIntervalSinceNow ?? 0
        let hasTimer = autoOffDeadline != nil && remaining > 0
        let on = lastKnownState

        // 更新定时菜单标题
        if hasTimer {
            timerMenuItem.title = "⏱ 定时关闭 (\(formatRemaining(remaining)))"
            if let button = statusItem.button {
                button.toolTip = "合盖不休眠 — 已开启 ⏱ \(formatRemaining(remaining))"
            }
            if on {
                statusMenuItem.title = "✅ 已开启 — 合盖自动关屏 | ⏱ \(formatRemaining(remaining))"
            }
        } else {
            timerMenuItem.title = "定时关闭"
            if on {
                statusMenuItem.title = "✅ 已开启 — 合盖自动关屏"
                if let button = statusItem.button {
                    button.toolTip = "合盖不休眠 — 已开启"
                }
            }
        }

        cancelTimerMenuItem.isEnabled = hasTimer
    }

    // 完整 UI 更新（含状态切换）
    func updateUI(on: Bool, lidwatchAlive: Bool) {
        let remaining = autoOffDeadline?.timeIntervalSinceNow ?? 0
        let hasTimer = autoOffDeadline != nil && remaining > 0

        if on {
            var detail = "合盖自动关屏"
            if hasTimer {
                detail += " | ⏱ \(formatRemaining(remaining))"
            }
            statusMenuItem.title = "✅ 已开启 — \(detail)"
            toggleMenuItem.title = "关闭合盖不休眠"
            toggleMenuItem.isEnabled = true

            if let button = statusItem.button {
                let img: NSImage?
                if #available(macOS 11.0, *) {
                    img = NSImage(systemSymbolName: "moon.zzz.fill", accessibilityDescription: "已开启")
                } else {
                    img = self.loadFallbackIcon()
                }
                button.image = img
                button.image?.size = NSSize(width: 18, height: 18)
                if let img = button.image { img.isTemplate = true }
                if hasTimer {
                    button.toolTip = "合盖不休眠 — 已开启 ⏱ \(formatRemaining(remaining))"
                } else {
                    button.toolTip = "合盖不休眠 — 已开启"
                }
            }
        } else {
            statusMenuItem.title = "❌ 已关闭 — 正常休眠"
            toggleMenuItem.title = "开启合盖不休眠"
            toggleMenuItem.isEnabled = true

            if let button = statusItem.button {
                let img: NSImage?
                if #available(macOS 11.0, *) {
                    img = NSImage(systemSymbolName: "moon.zzz", accessibilityDescription: "已关闭")
                } else {
                    img = self.loadFallbackIcon()
                }
                button.image = img
                button.image?.size = NSSize(width: 18, height: 18)
                if let img = button.image { img.isTemplate = true }
                button.toolTip = "合盖不休眠 — 已关闭"
            }
        }

        // 定时菜单状态
        timerMenuItem.isEnabled = on
        cancelTimerMenuItem.isEnabled = hasTimer

        if hasTimer {
            timerMenuItem.title = "⏱ 定时关闭 (\(formatRemaining(remaining)))"
        } else {
            timerMenuItem.title = "定时关闭"
        }
    }

    func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
    }

    // ★ 精确每秒刷新倒计时（使用 0.25s 轮询 + 整秒检测，确保不跳秒不漏秒）
    func startPreciseTick() {
        // 每 0.25 秒检查一次，只在整秒变化时才更新 UI
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard let deadline = self.autoOffDeadline, deadline.timeIntervalSinceNow > 0 else {
                // 没有定时器或已过期，只需检查是否有残留更新
                if self.lastTickSecond != 0 {
                    self.lastTickSecond = 0
                    self.updateTimerDisplay()
                }
                return
            }
            let currentSecond = Int(deadline.timeIntervalSinceNow)
            if currentSecond != self.lastTickSecond {
                self.lastTickSecond = currentSecond
                self.updateTimerDisplay()
            }
        }
    }

    // ============================================================
    // MARK: - 关于 / 退出 / 卸载
    // ============================================================

    @objc func showAbout() {
        let alert = NSAlert()
        alert.messageText = "合盖不休眠 v15"
        alert.informativeText = """
MacBook 合盖后保持运行，自动关闭屏幕省电。

📦 开源地址：github.com/1073020318-cell/nosleep-mac

—— 关注作者 ——
🎵 抖音：ywhhxs1998
📕 小红书：4270972670

点赞关注，私信获取安装包～
"""
        alert.addButton(withTitle: "好的")
        alert.runModal()
    }

    @objc func quitApp() {
        if lastKnownState {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }
                self.shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disablesleep", "0")
                self.shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "sleep", "1")
                self.shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "displaysleep", "10")
                self.shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disksleep", "10")
                self.stopLidwatch()
                DispatchQueue.main.async {
                    NSApp.terminate(nil)
                }
            }
        } else {
            NSApp.terminate(nil)
        }
    }

    @objc func uninstallApp() {
        let alert = NSAlert()
        alert.messageText = "确认卸载？"
        alert.informativeText = "将执行以下操作：\n• 恢复系统休眠设置\n• 删除免密配置（sudoers）\n• 清理临时文件\n• 删除本应用\n\n此操作不可撤销。"
        alert.addButton(withTitle: "确认卸载")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .critical

        if alert.runModal() == .alertFirstButtonReturn {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self = self else { return }

                if self.lastKnownState {
                    self.shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disablesleep", "0")
                    self.shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "sleep", "1")
                    self.shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "displaysleep", "10")
                    self.shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disksleep", "10")
                    self.stopLidwatch()
                }

                self.shell("/usr/bin/sudo", "-n", "/bin/rm", "-f", "/etc/sudoers.d/nosleep")

                try? FileManager.default.removeItem(atPath: self.lidwatchScript)
                try? FileManager.default.removeItem(atPath: self.lidwatchPidFile)
                try? FileManager.default.removeItem(atPath: "/tmp/nosleep_debug.log")

                let appPath = Bundle.main.bundlePath
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.shell("/usr/bin/osascript", "-e", "tell application \"Finder\" to delete POSIX file \"\(appPath)\"")
                    NSApp.terminate(nil)
                }
            }
        }
    }

    // ============================================================
    // MARK: - 工具方法
    // ============================================================

    @discardableResult
    func shell(_ args: [String]) -> String {
        guard let executable = args.first else { return "" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(args.dropFirst())

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    @discardableResult
    func shell(_ args: String...) -> String {
        return shell(args)
    }

    func shellAsync(_ args: [String], completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let result = self.shell(args)
            DispatchQueue.main.async {
                completion(result)
            }
        }
    }

    func notify(_ title: String, _ body: String) {
        // ★ 双通道通知：osascript + UNUserNotificationCenter，确保弹窗必现
        // 通道1：osascript（最可靠，立刻显示）
        let escTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
        let escBody = body.replacingOccurrences(of: "\"", with: "\\\"")
        shellAsync(["/usr/bin/osascript", "-e", "display notification \"\(escBody)\" with title \"\(escTitle)\""]) { _ in }

        // 通道2：UNUserNotificationCenter（系统标准方式，作为补充）
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}

// ============================================================
// MARK: - AppDelegate
// ============================================================

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var controller: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // ★ 请求通知权限，确保弹窗通知能显示
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        controller = MenuBarController()
    }

    // ★ 确保即使 App 在前台也能显示通知
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let c = controller, c.lastKnownState {
            c.shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disablesleep", "0")
            c.shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "sleep", "1")
            c.shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "displaysleep", "10")
            c.shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disksleep", "10")
            c.stopLidwatch()
        }
    }
}

// 启动
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
