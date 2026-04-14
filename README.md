# 🌙 合盖不休眠

<p align="center">
  <img src="Resources/AppIcon.jpg" width="128" height="128" alt="合盖不休眠图标">
</p>

<p align="center">
  <strong>MacBook 合盖后保持运行，自动关闭屏幕省电</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%20(Universal)-blue" alt="platform">
  <img src="https://img.shields.io/badge/version-v1.5.0-green" alt="version">
  <img src="https://img.shields.io/badge/license-MIT-orange" alt="license">
</p>

---

## ✨ 功能特性

- 🌙 **合盖不休眠** — 合上屏幕后电脑继续运行，屏幕自动关闭省电
- ⚡ **开盖秒亮** — 打开屏幕瞬间恢复，无需等待
- ⏱ **定时关闭** — 支持 30分钟/1h/2h/4h/8h 定时自动关闭，倒计时精确到秒
- 🔧 **菜单栏常驻** — 不占 Dock 位置，一键开/关
- 🗑 **完整卸载** — 一键清理所有系统修改，不留残留

## 🎯 解决什么问题？

MacBook 合上屏幕后会自动休眠，导致：

- ❌ 下载任务中断
- ❌ AI 助手掉线
- ❌ 远程连接断开
- ❌ 后台编译/渲染停止

**合盖不休眠** 让你合盖走人，电脑继续干活，屏幕关掉省电。

## 📋 安装

### 方式一：下载安装包（推荐）

1. 前往 [Releases](../../releases) 下载最新 DMG 文件
2. 双击打开 DMG
3. 将「合盖不休眠」拖入「Applications」文件夹
4. 从启动台打开

### 方式二：从源码构建

```bash
# 克隆仓库
git clone https://github.com/1073020318-cell/nosleep-mac.git
cd nosleep-mac

# 构建 App
./scripts/build.sh

# 或构建 DMG 安装包
./scripts/build.sh dmg
```

### ⚠️ 首次打开

macOS 安全机制可能拦截，请：
1. 右键点击 App → 选择「打开」
2. 点击「打开」确认

首次运行需要输入一次管理员密码（配置免密权限），之后不再需要。

## 🎮 使用方法

打开 App 后，菜单栏会出现 🌙 图标：

| 操作 | 说明 |
|------|------|
| 点击图标 | 弹出菜单，查看状态 |
| 「开启合盖不休眠」 | 开启功能，合盖后电脑继续运行 |
| 「关闭合盖不休眠」 | 关闭功能，恢复正常休眠 |
| 「⏱ 定时关闭」 | 设置定时自动关闭 |
| 「卸载并退出」 | 完整卸载，清理所有修改 |

## 🏗️ 项目结构

```
nosleep-mac/
├── Sources/
│   ├── menulet.swift     # 主程序（Swift 菜单栏应用）
│   ├── launch            # 启动脚本（Bash）
│   └── backlightctl      # 背光控制（Python3 + ctypes）
├── Resources/
│   ├── AppIcon.jpg       # 图标源文件
│   ├── Info.plist        # App 配置
│   └── 使用说明.txt       # 用户说明
├── scripts/
│   └── build.sh          # 构建脚本
├── README.md
└── LICENSE
```

## 🔧 技术细节

| 模块 | 技术 | 说明 |
|------|------|------|
| menulet | Swift + Cocoa | NSStatusItem 菜单栏应用，LSUIElement 模式 |
| lidwatch | Bash + ioreg | 0.5s 轮询 AppleClamshellState，控制背光 |
| backlightctl | Python3 + ctypes | 调用 DisplayServices 私有框架控制屏幕亮度 |
| pmset | macOS 命令 | 管理电源/休眠设置，sudoers 免密 |

### 安全说明

- `sudoers.d/nosleep` 仅允许无密码执行 `/usr/bin/pmset`，范围严格受限
- 无任何网络通信，无数据外传
- 临时文件全部存放在 `/tmp/`，系统重启自动清理
- 卸载时自动清理所有系统修改

## 💻 系统要求

| 要求 | 说明 |
|------|------|
| 系统 | **macOS 11.0+** (Big Sur 或更新版本) |
| 芯片 | Apple Silicon（M1/M2/M3/M4）✅ / Intel Mac ✅ |
| 权限 | 首次运行需管理员密码 |

> ✅ v1.5+ 已编译为 Universal Binary，同时支持 Apple Silicon 和 Intel Mac。

> ⚠️ **不支持 macOS 10.15 (Catalina) 及更低版本**。这是因为 Swift 6.2 编译器最低要求 macOS 11.0。如果你的 Mac 是 2020 年之前购买的旧机型，可能无法运行此版本。

## 📜 开源协议

[MIT License](LICENSE) — 自由使用、修改、分发。

## 🙏 致谢

因个人需求开发，从 v1 到 v15 迭代了十几轮。希望对有同样需求的 Mac 用户有帮助！

## ❓ 常见问题与排错

### 基础问题

**Q: 提示"无法验证开发者"或"已损坏"？**
> 这是 macOS Gatekeeper 安全机制，因为 App 使用 ad-hoc 签名。解决方法：
> 1. 右键点击 App → 选择「打开」→ 点击「打开」确认
> 2. 或在终端执行：`xattr -cr /Applications/合盖不休眠.app`

**Q: 提示需要 Python 3？**
> macOS 11.0+ 已自带 Python 3（`/usr/bin/python3`），无需额外安装。如果仍提示缺少 Python，请确认系统版本是否符合要求，或在终端执行 `xcode-select --install`。

**Q: Intel Mac 能用吗？**
> ✅ v1.5+ 已编译为 Universal Binary，同时支持 Apple Silicon 和 Intel Mac。

**Q: 为什么最低要求 macOS 11.0？**
> Swift 6.2 编译器最低要求 macOS 11.0，这是编译器限制，不是代码问题。2020 年后购买的 Mac 基本都符合要求。

### 排错指南

**Q: 双击 App 没有任何反应？**

> 请按以下步骤排查：
>
> **步骤1**：在终端执行 `xattr -cr /Applications/合盖不休眠.app`，然后右键→打开
>
> **步骤2**：如果仍然没反应，在终端手动启动查看报错：
> ```bash
> /Applications/合盖不休眠.app/Contents/MacOS/launch
> ```
> 把终端显示的错误信息截图反馈。
>
> **步骤3**：查看日志文件 `/tmp/nosleep_debug.log`

**Q: 输入密码后还是没反应？**
> 可能密码输入错误，或当前用户不是管理员。请在终端手动执行：
> ```bash
> sudo bash -c 'echo "ALL ALL=NOPASSWD: /usr/bin/pmset" > /etc/sudoers.d/nosleep'
> sudo chmod 444 /etc/sudoers.d/nosleep
> ```
> 然后重新打开 App。

**Q: 菜单栏图标不出现？**
> menulet 可能启动后崩溃了。在终端手动启动查看具体错误：
> ```bash
> /Applications/合盖不休眠.app/Contents/MacOS/menulet
> ```
> 如果提示 `Library not loaded` 或 `libswiftCore` 相关错误，说明 Swift 运行时版本不兼容，请更新 macOS 到最新版本。

**Q: 如何反馈问题？**
> 1. 查看 `/tmp/nosleep_debug.log` 日志
> 2. 在终端执行 `launch` 和 `menulet` 的输出截图
> 3. 到 [GitHub Issues](../../issues) 提交问题

---

<p align="center">
  觉得有用？给个 ⭐ Star 吧！
</p>
