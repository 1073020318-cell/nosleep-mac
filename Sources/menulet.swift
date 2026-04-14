#!/usr/bin/env swift
// ============================================================
//  合盖不休眠 v15 — 菜单栏版（含定时关闭功能）
//
//  功能：
//    - 菜单栏常驻图标（NSStatusItem），不占 Dock 位置
//    - 一键开/关合盖不休眠
//    - 合盖自动关屏幕背光，开盖秒亮
//    - 定时关闭（30分钟/1h/2h/4h/8h）
//    - 倒计时实时显示（精确到秒）
//    - 完整卸载功能（清理 sudoers + 临时文件 + pmset 恢复）
//
//  编译：
//    swiftc -o menulet menulet.swift -framework Cocoa
//
//  作者：龙皇
//  开源协议：MIT License
// ============================================================

import Cocoa

class MenuBarController: NSObject, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()

    // 菜单项
    let statusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let toggleMenuItem = NSMenuItem(title: "", action: #selector(toggleFeature), keyEquivalent: "")
    let timerMenuItem = NSMenuItem(title: "⏱ 定时关闭", action: nil, keyEquivalent: "")
    let cancelTimerMenuItem = NSMenuItem(title: "取消定时", action: #selector(cancelAutoOff), keyEquivalent: "")
    let aboutMenuItem = NSMenuItem(title: "关于", action: #selector(showAbout), keyEquivalent: "")
    let quitMenuItem = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
    let uninstallMenuItem = NSMenuItem(title: "卸载并退出", action: #selector(uninstallApp), keyEquivalent: "")

    // 定时器
    var refreshTimer: Timer?
    var autoOffDeadline: Date?
    var autoOffTimer: Timer?

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
    }

    // 加载备用图标（用于 macOS 10.13-10.15）
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
        // 图标 - 兼容 macOS 10.13+
        if let button = statusItem.button {
            let img: NSImage?
            if #available(macOS 11.0, *) {
                // macOS 11.0+ 使用 SF Symbols
                img = NSImage(systemSymbolName: "moon.zzz", accessibilityDescription: "合盖不休眠")
            } else {
                // macOS 10.13-10.15 使用应用图标
                let bundle = Bundle.main
                if let iconPath = bundle.path(forResource: "AppIcon", ofType: "icns"),
                   let iconImg = NSImage(contentsOfFile: iconPath) {
                    img = iconImg
                } else if let iconPath = bundle.path(forResource: "AppIcon", ofType: "jpg"),
                          let iconImg = NSImage(contentsOfFile: iconPath) {
                    img = iconImg
                } else {
                    img = nil
                }
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

    // ============================================================
    // MARK: - 状态检测
    // ============================================================

    func isFeatureOn() -> Bool {
        let result = shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-g", "custom")
        return result.contains("disablesleep    1")
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
        if isFeatureOn() {
            disableFeature()
        } else {
            enableFeature()
        }
        refreshStatus()
    }

    func enableFeature() {
        // 1. 设置 pmset
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disablesleep", "1")
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "sleep", "0")
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "displaysleep", "0")
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disksleep", "0")

        // 2. 写 lidwatch 脚本
        let script = """
#!/bin/bash
# lidwatch — 监听合盖/开盖，控制背光
LOG="/tmp/nosleep_debug.log"
BACKLIGHTCTL="\(backlightctl)"
CLOSE_COUNT=0
OPEN_COUNT=0

while true; do
    STATE=$(ioreg -r -c AppleClamshellState | grep "AppleClamshellState" | head -1 | awk '{print $NF}')

    if [ "$STATE" = "Yes" ]; then
        CLOSE_COUNT=$((CLOSE_COUNT + 1))
        OPEN_COUNT=0
        if [ $CLOSE_COUNT -eq 2 ]; then
            echo "[$(date '+%H:%M:%S')] 合盖 → 关背光" >> "$LOG"
            "$BACKLIGHTCTL" off 2>> "$LOG"
            CLOSE_COUNT=0
        fi
    elif [ "$STATE" = "No" ]; then
        OPEN_COUNT=$((OPEN_COUNT + 1))
        CLOSE_COUNT=0
        if [ $OPEN_COUNT -eq 1 ]; then
            echo "[$(date '+%H:%M:%S')] 开盖 → 恢复背光" >> "$LOG"
            "$BACKLIGHTCTL" on 2>> "$LOG"
            /usr/bin/caffeinate -u -t 1 2>/dev/null
            OPEN_COUNT=0
        fi
    fi

    sleep 0.5
done
"""
        try? script.write(toFile: lidwatchScript, atomically: true, encoding: .utf8)
        shell("/bin/chmod", "+x", lidwatchScript)

        // 3. 启动 lidwatch
        let pid = shell("/bin/bash", lidwatchScript, "& echo $!")
        let cleanPid = pid.trimmingCharacters(in: .whitespacesAndNewlines)
        try? cleanPid.write(toFile: lidwatchPidFile, atomically: true, encoding: .utf8)

        notify("合盖不休眠已开启", "合盖后电脑将继续运行，屏幕自动关闭省电")
    }

    func disableFeature() {
        // 1. 恢复 pmset
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disablesleep", "0")
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "sleep", "1")
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "displaysleep", "10")
        shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disksleep", "10")

        // 2. 停止 lidwatch
        stopLidwatch()

        // 3. 清除定时
        cancelAutoOff()

        notify("合盖不休眠已关闭", "电脑恢复正常休眠")
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
            if isFeatureOn() {
                disableFeature()
            }
            notify("定时到", "合盖不休眠已自动关闭")
            refreshStatus()
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
        let on = isFeatureOn()
        let alive = isLidwatchAlive()

        // ★ 关键修复：在主队列内部计算 remaining，
        //   避免多定时器异步调度时的竞态条件导致倒计时跳变
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // 在主队列中实时计算剩余时间，确保每次渲染都是最新值
            let remaining = self.autoOffDeadline?.timeIntervalSinceNow ?? 0
            let hasTimer = self.autoOffDeadline != nil && remaining > 0

            // 状态行
            if on {
                var detail = "合盖自动关屏"
                if !alive { detail = "⚠️ 监听进程已停止" }
                if hasTimer {
                    detail += " | ⏱ \(self.formatRemaining(remaining))"
                }
                self.statusMenuItem.title = "✅ 已开启 — \(detail)"
                self.toggleMenuItem.title = "关闭合盖不休眠"

                if let button = self.statusItem.button {
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
                        button.toolTip = "合盖不休眠 — 已开启 ⏱ \(self.formatRemaining(remaining))"
                    } else {
                        button.toolTip = "合盖不休眠 — 已开启"
                    }
                }
            } else {
                self.statusMenuItem.title = "❌ 已关闭 — 正常休眠"
                self.toggleMenuItem.title = "开启合盖不休眠"
                if let button = self.statusItem.button {
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
            self.timerMenuItem.isEnabled = on
            self.cancelTimerMenuItem.isEnabled = hasTimer

            // 定时菜单标题（带秒数显示）
            if hasTimer {
                self.timerMenuItem.title = "⏱ 定时关闭 (\(self.formatRemaining(remaining)))"
            } else {
                self.timerMenuItem.title = "定时关闭"
            }
        }
    }

    func startRefreshTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.refreshStatus()
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
        📄 协议：MIT License

        —— 关注作者 ——
        🎵 抖音：ywhhxs1998
        📕 小红书：4270972670

        点赞关注，私信获取安装包～
        """
        alert.addButton(withTitle: "好的")
        alert.runModal()
    }

    @objc func quitApp() {
        if isFeatureOn() {
            disableFeature()
        }
        NSApp.terminate(nil)
    }

    @objc func uninstallApp() {
        let alert = NSAlert()
        alert.messageText = "确认卸载？"
        alert.informativeText = "将执行以下操作：\n• 恢复系统休眠设置\n• 删除免密配置（sudoers）\n• 清理临时文件\n• 删除本应用\n\n此操作不可撤销。"
        alert.addButton(withTitle: "确认卸载")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .critical

        if alert.runModal() == .alertFirstButtonReturn {
            // 1. 恢复 pmset
            if isFeatureOn() {
                disableFeature()
            }

            // 2. 删除 sudoers
            shell("/usr/bin/sudo", "-n", "/bin/rm", "-f", "/etc/sudoers.d/nosleep")

            // 3. 清理临时文件
            try? FileManager.default.removeItem(atPath: lidwatchScript)
            try? FileManager.default.removeItem(atPath: lidwatchPidFile)
            try? FileManager.default.removeItem(atPath: "/tmp/nosleep_debug.log")

            // 4. 删除 App
            let appPath = Bundle.main.bundlePath
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.shell("/usr/bin/osascript", "-e", "tell application \"Finder\" to delete POSIX file \"\(appPath)\"")
                NSApp.terminate(nil)
            }
        }
    }

    // ============================================================
    // MARK: - 工具方法
    // ============================================================

    @discardableResult
    func shell(_ args: String...) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: args[0])
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

    func notify(_ title: String, _ body: String) {
        let escTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
        let escBody = body.replacingOccurrences(of: "\"", with: "\\\"")
        shell("/usr/bin/osascript", "-e", "display notification \"\(escBody)\" with title \"\(escTitle)\"")
    }
}

// ============================================================
// MARK: - AppDelegate
// ============================================================

class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = MenuBarController()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 退出时如果功能还在开启状态，自动关闭
        if let c = controller, c.isFeatureOn() {
            c.disableFeature()
        }
    }
}

// 启动
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
