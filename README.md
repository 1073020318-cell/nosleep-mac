# 🌙 合盖不休眠

<p align="center">
  <img src="Resources/AppIcon.jpg" width="128" height="128" alt="合盖不休眠图标">
</p>

<p align="center">
  <strong>MacBook 合盖后保持运行，自动关闭屏幕省电</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%20(Universal)-blue" alt="platform">
  <img src="https://img.shields.io/badge/version-v1.7.0-green" alt="version">
  <img src="https://img.shields.io/badge/license-MIT-orange" alt="license">
</p>

---

## ✨ 功能特性

- 🌙 **合盖不休眠** — 合上屏幕后电脑继续运行，屏幕自动关闭省电
- ⚡ **开盖秒亮** — 打开屏幕瞬间恢复，无需等待
- ⏱ **定时关闭** — 支持 30分钟/1h/2h/4h/8h 定时自动关闭，倒计时精确到秒；关闭状态下选定时会直接开启
- 🔋 **低电量保护** — 用电池时电量降到 10%/20%/30%（可选）自动关闭，防止合盖放包里把电耗光
- 🚀 **开机自动启动** — 菜单里一键开关（macOS 13+）
- 🔧 **菜单栏常驻** — 不占 Dock 位置，一键开/关
- 🪶 **几乎不耗电** — 合盖监听用系统事件，空闲时 CPU 占用接近 0
- 🗑 **一键卸载** — 关闭合盖不休眠、删除免密配置、删除 App 自己的日志和设置，再把 App 移到废纸篓

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

### 从旧版升级

1. **先退出旧版**：点菜单栏 🌙 → 「退出」（旧版退出时会恢复正常休眠）
2. 用新版替换「应用程序」里的「合盖不休眠」，再打开
3. 新版会提示「升级免密配置」，点「升级」并输入一次密码

如果打开新版后菜单栏没有变化，说明旧版还在运行：先在旧版菜单里点「退出」，再打开新版。

### 方式二：从源码构建

```bash
# 克隆仓库
git clone https://github.com/1073020318-cell/nosleep-mac.git
cd nosleep-mac

# 构建 App
./scripts/build.sh

# 或构建 DMG 安装包
./scripts/build.sh dmg

# 运行沙箱场景测试（模拟合盖、定时、低电量等 23 个场景，不改动电脑设置）
./scripts/test.sh
```

### ⚠️ 首次打开

App 没有苹果开发者签名，macOS 会拦截：
- **macOS 15 及以后**：双击后点「完成」，再到「系统设置 → 隐私与安全性」，在页面底部点「仍要打开」
- **macOS 14 及以前**：右键点击 App → 选择「打开」→ 点击「打开」确认
- 或者在终端执行：`xattr -cr /Applications/合盖不休眠.app`

第一次点「开启」时需要输入一次管理员密码（配置免密权限），之后不再需要。

> 💡 退出 App 会同时关闭合盖不休眠。如果 App 被强制结束，系统会一直保持「不休眠」，重新打开 App 即可接管或关闭（建议开启「开机自动启动」）。

## 🎮 使用方法

打开 App 后，菜单栏会出现 🌙 图标：

| 操作 | 说明 |
|------|------|
| 点击图标 | 弹出菜单，查看状态 |
| 「开启合盖不休眠」 | 开启功能，合盖后电脑继续运行 |
| 「关闭合盖不休眠」 | 关闭功能，恢复正常休眠 |
| 「定时关闭」 | 设置定时自动关闭（关闭状态下选择会同时开启） |
| 「低电量保护」 | 选择电量低于多少时自动关闭，或不启用 |
| 「开机自动启动」 | 登录后自动出现在菜单栏 |
| 「卸载并退出」 | 关闭功能、删除免密配置和 App 自己的文件，并把 App 移到废纸篓 |

## 🏗️ 项目结构

```
nosleep-mac/
├── Sources/
│   └── menulet.swift     # 全部代码（Swift 菜单栏应用）
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
| 菜单栏 | Swift + Cocoa | NSStatusItem 菜单栏应用，LSUIElement 模式 |
| 合盖监听 | IOKit | 订阅 IOPMrootDomain 的合盖事件（另有 1 秒一次的进程内兜底检查），不启动任何子进程 |
| 背光控制 | DisplayServices | 进程内直接调用私有框架控制内建屏幕亮度，不需要 Python |
| 休眠控制 | pmset | 只切换 `disablesleep`，不改你自己设置的显示器/硬盘睡眠时间 |
| 低电量保护 | IOKit.ps | 电源变化时系统回调，不轮询 |

### 安全说明

- `/etc/sudoers.d/nosleep-<你的用户ID>` 只允许**你的账户**免密执行两条固定命令：`pmset -a disablesleep 0` 和 `pmset -a disablesleep 1`；每个账户一个文件，互不覆盖
- 写入前用 `visudo` 校验，校验不通过不会替换，避免把 sudo 配置写坏
- 从旧版升级时会提示收紧旧的「所有账户可执行任意 pmset」配置
- 无任何网络通信，无数据外传
- 不在 `/tmp/` 放任何脚本；日志在 `~/Library/Logs/合盖不休眠.log`
- 卸载时关闭合盖不休眠、删除免密配置（会请求一次管理员密码）；如果睡眠时间还是旧版留下的「永不」，一并恢复默认值

## 💻 系统要求

| 要求 | 说明 |
|------|------|
| 系统 | **macOS 11.0+** (Big Sur 或更新版本) |
| 芯片 | Apple Silicon（M1/M2/M3/M4）✅ / Intel Mac ✅ |
| 权限 | 首次运行需管理员密码 |

> ✅ v1.5+ 已编译为 Universal Binary，同时支持 Apple Silicon 和 Intel Mac。

> ⚠️ **不支持 macOS 10.15 (Catalina) 及更低版本**。App 用到了 macOS 11 才有的系统功能（如菜单栏图标用的 SF Symbols），构建时也以 macOS 11 为最低版本。

## 📜 开源协议

[MIT License](LICENSE) — 自由使用、修改、分发。

## 🙏 致谢

因个人需求开发，从 v1 到 v15 迭代了十几轮。希望对有同样需求的 Mac 用户有帮助！

## ❓ 常见问题与排错

### 基础问题

**Q: 提示"无法验证开发者"或"已损坏"？**
> 这是 macOS Gatekeeper 安全机制，因为 App 使用 ad-hoc 签名。解决方法：
> 1. macOS 15 及以后：「系统设置 → 隐私与安全性」底部点「仍要打开」；macOS 14 及以前：右键点击 App →「打开」→「打开」
> 2. 或在终端执行：`xattr -cr /Applications/合盖不休眠.app`

**Q: 需要安装 Python 吗？**
> v1.7 起不需要。旧版依赖 Python 3，在没装开发者工具的 Mac 上合盖后屏幕可能不灭，升级即可。

**Q: Intel Mac 能用吗？**
> ✅ v1.5+ 已编译为 Universal Binary，同时支持 Apple Silicon 和 Intel Mac。

**Q: 为什么最低要求 macOS 11.0？**
> App 用到了 macOS 11 才有的系统功能。2020 年后购买的 Mac 基本都符合要求。

### 排错指南

**Q: 双击 App 没有任何反应？**

> 请按以下步骤排查：
>
> **步骤1**：在终端执行 `xattr -cr /Applications/合盖不休眠.app`，然后再打开
>
> **步骤2**：如果仍然没反应，在终端手动启动查看报错：
> ```bash
> /Applications/合盖不休眠.app/Contents/MacOS/menulet
> ```
> 把终端显示的错误信息截图反馈。
>
> **步骤3**：查看日志文件 `~/Library/Logs/合盖不休眠.log`（菜单 → 关于 → 查看日志）

**Q: 输入密码后还是没反应？**
> 可能密码输入错误，或当前用户不是管理员账户。配置免密需要管理员账户的密码。

**Q: 关闭后电脑不再自动关显示器了？**
> 旧版（v1.6 及以前）开启时会把显示器/系统/硬盘睡眠时间都改成「永不」，关闭时又统一改成 1/10/10 分钟（用电池时也是 10 分钟关显示器）。v1.7 不再改这些时间。升级免密配置时如果检测到旧版留下的设置，会提供一个「恢复为 macOS 默认值」的勾选项；也可以在「系统设置 → 电池 / 锁定屏幕」里自己调整。

**Q: v1.7 和旧版用起来有什么不同？**
> - 开盖使用时，显示器按你自己在系统设置里的时间自动关闭（旧版开启期间显示器永不关闭）
> - 开启/关闭不再弹通知，看菜单栏图标即可（定时到、低电量自动关闭仍会通知）
> - 管理员密码在第一次点「开启」时才需要输入，而不是一打开 App 就要
> - 「退出」会同时关闭合盖不休眠；如果在终端里用 `pmset` 开启了 disablesleep，App 也会接管并在退出时关闭

**Q: 菜单栏图标不出现？**
> menulet 可能启动后崩溃了。在终端手动启动查看具体错误：
> ```bash
> /Applications/合盖不休眠.app/Contents/MacOS/menulet
> ```
> 如果提示 `Library not loaded` 或 `libswiftCore` 相关错误，说明 Swift 运行时版本不兼容，请更新 macOS 到最新版本。

**Q: 如何反馈问题？**
> 1. 查看 `~/Library/Logs/合盖不休眠.log` 日志
> 2. 在终端执行 `menulet` 的输出截图
> 3. 到 [GitHub Issues](../../issues) 提交问题

---

<p align="center">
  觉得有用？给个 ⭐ Star 吧！
</p>
