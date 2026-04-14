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
        logDebug("开始开启功能")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            
            let startTime = Date()
            
            // 使用 DispatchGroup 并行执行 pmset 和脚本准备
            let group = DispatchGroup()
            
            // 1. 异步执行 pmset 命令（合并命令）
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                self.logDebug("开始执行 pmset 命令")
                let result = self.shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disablesleep", "1", "sleep", "0", "displaysleep", "0", "disksleep", "0")
                self.logDebug("pmset 命令完成: \(result.isEmpty ? "空输出" : result.prefix(50))...")
                group.leave()
            }
            
            // 2. 写 lidwatch 脚本（并行执行）
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                self.logDebug("开始创建 lidwatch 脚本")
                // ★ 关键修复：ioreg 必须用 -l -p IOService 才能读到 AppleClamshellState
                let script = """
#!/bin/bash
# lidwatch v4 — 监听合盖/开盖，控制背光（防闪屏 + 兼容版）
# 修复：进程互斥 + 状态确认 + 去抖 + Python3 兼容

LOG="/tmp/nosleep_debug.log"
BACKLIGHTCTL="\(self.backlightctl)"
PIDFILE="/tmp/nosleep_lidwatch.pid"

# ★ 进程互斥：确保只有一个 lidwatch 实例运行
if [ -f "$PIDFILE" ]; then
    OLD_PID=$(cat "$PIDFILE" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        echo "[$(date '+%H:%M:%S')] lidwatch 已在运行 (PID=$OLD_PID)，退出" >> "$LOG"
        exit 0
    fi
fi

# 写入当前 PID
echo $$ > "$PIDFILE"

# 清理函数：退出时删除 PID 文件
cleanup() {
    rm -f "$PIDFILE"
    exit 0
}
trap cleanup SIGTERM SIGINT SIGHUP

LAST_STATE=""
CANDIDATE_STATE=""
CONFIRM_COUNT=0
REQUIRED_CONFIRMS=2  # 连续确认次数（防止传感器抖动）
DEBOUNCE_SEC=1       # ★ 去抖时间（秒），两次触发至少间隔1秒
LAST_TRIGGER_TIME=0
BRIGHTNESS_FILE="/tmp/nosleep_brightness"  # 记录背光状态，防止重复触发

while true; do
    # 优化：使用 -r -k 快速查询 AppleClamshellState
    STATE=$(ioreg -r -k AppleClamshellState -p IOService 2>/dev/null | grep '"AppleClamshellState"' | head -1 | sed 's/.*= //' | tr -d '[:space:]')

    # 状态确认机制：连续多次检测到相同状态才触发
    if [ "$STATE" = "$CANDIDATE_STATE" ]; then
        CONFIRM_COUNT=$((CONFIRM_COUNT + 1))
    else
        CANDIDATE_STATE="$STATE"
        CONFIRM_COUNT=1
    fi

    if [ "$CONFIRM_COUNT" -ge "$REQUIRED_CONFIRMS" ] && [ "$STATE" != "$LAST_STATE" ]; then
        # ★ 去抖：两次触发间隔至少 DEBOUNCE_SEC 秒
        NOW_SEC=$(date +%s)
        ELAPSED=$((NOW_SEC - LAST_TRIGGER_TIME))
        if [ "$ELAPSED" -lt "$DEBOUNCE_SEC" ]; then
            # 去抖中，跳过此次触发
            :
        elif [ "$STATE" = "Yes" ]; then
            # 合盖 → 关背光（仅在背光为 on 时执行）
            if [ ! -f "$BRIGHTNESS_FILE" ] || [ "$(cat "$BRIGHTNESS_FILE" 2>/dev/null)" != "off" ]; then
                echo "[$(date '+%H:%M:%S')] 合盖 → 关背光" >> "$LOG"
                "$BACKLIGHTCTL" off >/dev/null 2>&1 || true
                echo "off" > "$BRIGHTNESS_FILE"
                LAST_STATE="Yes"
                LAST_TRIGGER_TIME=$NOW_SEC
            fi
        elif [ "$STATE" = "No" ]; then
            # 开盖 → 恢复背光（仅在背光为 off 时执行）
            if [ "$(cat "$BRIGHTNESS_FILE" 2>/dev/null)" = "off" ]; then
                echo "[$(date '+%H:%M:%S')] 开盖 → 恢复背光" >> "$LOG"
                "$BACKLIGHTCTL" on >/dev/null 2>&1 || true
                /usr/bin/caffeinate -u -t 1 >/dev/null 2>&1 || true
                echo "on" > "$BRIGHTNESS_FILE"
                LAST_STATE="No"
                LAST_TRIGGER_TIME=$NOW_SEC
            fi
        fi
    fi

    sleep 0.1
done
"""
                do {
                    try script.write(toFile: self.lidwatchScript, atomically: true, encoding: .utf8)
                    self.logDebug("脚本写入完成: \(self.lidwatchScript)")
                    self.shell("/bin/chmod", "+x", self.lidwatchScript)
                    self.logDebug("脚本添加执行权限")
                } catch {
                    self.logDebug("脚本写入失败: \(error)")
                }
                group.leave()
            }
            
            // 等待并行任务完成
            group.wait()
            
            let elapsed = Date().timeIntervalSince(startTime)
            self.logDebug("开启功能总耗时: \(String(format: "%.2f", elapsed))秒")
            
            // 3. 回主线程立即更新 UI（不等待 lidwatch 启动）
            DispatchQueue.main.async {
                self.lastKnownState = true
                // 先假设 lidwatch 会启动成功
                self.updateUI(on: true, lidwatchAlive: true)
                self.logDebug("UI 已更新为开启状态")
                // 发送通知
                self.notify("合盖不休眠已开启", "合盖后电脑将继续运行，屏幕自动关闭省电")
                // 异步刷新状态以确认
                self.refreshStatus()
            }
            
            // 4. 在后台异步启动 lidwatch（不阻塞 UI 响应）
            // ★ 修复闪屏：先杀所有残留，再用 Process 直接启动并 detach，避免 bash -c "&" PID 不可靠
            DispatchQueue.global(qos: .background).async {
                self.logDebug("开始启动 lidwatch")
                // 先清理所有残留的 lidwatch 进程
                self.shell("/usr/bin/pkill", "-f", "nosleep_lidwatch")
                self.logDebug("已清理残留 lidwatch 进程")
                // 短暂等待确保清理完成
                Thread.sleep(forTimeInterval: 0.3)
                
                // 使用 Process 直接启动脚本，不 waitUntilExit（detach 模式）
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/bash")
                process.arguments = [self.lidwatchScript]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    // ★ 保存 Process 引用，防止 ARC 释放导致子进程被杀
                    self.lidwatchProcess = process
                    self.logDebug("lidwatch 已启动 (PID=\(process.processIdentifier))")
                } catch {
                    self.logDebug("⚠️ lidwatch 启动失败: \(error)")
                }
                
                // 等待脚本自身写入 PID 文件
                Thread.sleep(forTimeInterval: 0.5)
                if FileManager.default.fileExists(atPath: "/tmp/nosleep_lidwatch.pid") {
                    let pid = (try? String(contentsOfFile: "/tmp/nosleep_lidwatch.pid", encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
                    self.logDebug("lidwatch 运行中 (PID=\(pid))")
                } else {
                    self.logDebug("⚠️ lidwatch PID 文件未生成，可能启动失败")
                }
            }
        }
    }

    func disableFeatureAsync() {
        statusMenuItem.title = "⏳ 正在关闭…"
        toggleMenuItem.isEnabled = false

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // 1. 合并 pmset 命令
            self.shell("/usr/bin/sudo", "-n", "/usr/bin/pmset", "-a", "disablesleep", "0", "sleep", "1", "displaysleep", "10", "disksleep", "10")

            // 2. 停止 lidwatch
            self.stopLidwatch()

            // 3. 清除定时
            DispatchQueue.main.sync {
                self.cancelAutoOff()
            }

            // 4. 回主线程立即更新 UI
            DispatchQueue.main.async {
                self.lastKnownState = false
                self.updateUI(on: false, lidwatchAlive: false)
                self.notify("合盖不休眠已关闭", "电脑恢复正常休眠")
                // 异步刷新状态以确认
                self.refreshStatus()
            }
        }
    }

    // ★ 保持 Process 引用，防止被 ARC 释放导致子进程被杀
    private var lidwatchProcess: Process?
    
    func stopLidwatch() {
        // ★ 修复：杀掉所有 lidwatch 进程（防止进程泄漏导致闪屏）
        // 1. 释放 Process 对象引用
        if let proc = lidwatchProcess, proc.isRunning {
            proc.terminate()
            lidwatchProcess = nil
        }
        // 2. 先尝试杀 PID 文件中记录的进程
        if FileManager.default.fileExists(atPath: lidwatchPidFile),
           let pidStr = try? String(contentsOfFile: lidwatchPidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let pid = Int32(pidStr) {
            kill(pid, SIGTERM)
        }
        // 3. 兜底：杀掉所有名为 nosleep_lidwatch 的进程（清理泄漏的旧进程）
        shell("/usr/bin/pkill", "-f", "nosleep_lidwatch")
        // 4. 清理所有临时文件
        try? FileManager.default.removeItem(atPath: lidwatchPidFile)
        try? FileManager.default.removeItem(atPath: "/tmp/nosleep_lidwatch.lock")
        try? FileManager.default.removeItem(atPath: "/tmp/nosleep_brightness")
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

    func logDebug(_ message: String) {
        let logPath = "/tmp/nosleep_menulet.log"
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let line = "[\(timestamp)] \(message)\n"
        if let data = line.data(using: .utf8) {
            if let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                try? data.write(to: URL(fileURLWithPath: logPath), options: .atomic)
            }
        }
    }

    func notify(_ title: String, _ body: String) {
        logDebug("通知发送开始: \(title) - \(body)")
        
        // ★ 简化通知逻辑：直接发送 UNNotification，失败时使用 NSUserNotification 备选
        let center = UNUserNotificationCenter.current()
        
        // 直接发送 UNNotification
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = nil
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        
        center.add(request) { [weak self] error in
            if let error = error {
                self?.logDebug("UNNotification 发送失败: \(error.localizedDescription)")
                // 失败时尝试 NSUserNotification（旧 API）
                DispatchQueue.main.async {
                    let note = NSUserNotification()
                    note.title = title
                    note.informativeText = body
                    note.soundName = nil
                    note.identifier = UUID().uuidString
                    note.deliveryDate = Date()
                    NSUserNotificationCenter.default.scheduleNotification(note)
                    self?.logDebug("已发送 NSUserNotification 作为备选")
                }
            } else {
                self?.logDebug("UNNotification 发送成功")
            }
        }
    }
}

// ============================================================
// MARK: - AppDelegate
// ============================================================

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSUserNotificationCenterDelegate {
    var controller: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // ★ 请求通知权限，确保弹窗通知能显示
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        
        // ★ 设置旧版通知中心代理，确保 NSUserNotification 能在前台显示
        NSUserNotificationCenter.default.delegate = self

        controller = MenuBarController()
    }

    // ★ 确保即使 App 在前台也能显示通知
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
    
    // ★ NSUserNotificationCenterDelegate: 确保旧版通知在前台也能显示
    func userNotificationCenter(_ center: NSUserNotificationCenter, shouldPresent notification: NSUserNotification) -> Bool {
        return true
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
