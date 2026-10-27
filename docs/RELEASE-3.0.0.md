# NikoDesk 3.0.0+28 — 全新界面、Windows 安装版与锁屏远控 / A new interface, the Windows installer and remote unlock

[下载 v3.0.0 / Download](https://github.com/baogutang/nikodesk/releases/tag/v3.0.0)

## 本次更新

**全新界面（Mac、Windows、iPad、手机）**

- 首页就是连接：对方的设备代码填进蓝色的连接面板，模式（远程控制、文件传输、TCP 隧道）在面板上切换。电脑上，本机的设备代码和临时密码在旁边。
- 连接过的设备排在下面，卡片上带着它的上次画面。会话进行时每 30 秒存一张缩小的画面，只存在这台设备上；在“设置 → 外观”（手机和 iPad 在“设置 → 通用”）可以关掉，关掉会删除已存的画面。
- “设备”页是列表加详情；“会话记录”和“设置”改成同一套卡片样式。
- 统一成一个蓝色、一套字号和圆角，去掉了中点分隔的说明文字。

**控制 Windows 便携版**

- 对方是便携版、又弹出管理员确认窗口（UAC）时，不再出现永远不会成功的“请求提升权限”，改为说明要在那台电脑前确认，或者在那台电脑上安装正式版。
- “会话结束后锁屏”开着时，会话开始时提醒一次：便携版锁上后无法远程解锁。会话菜单里这一项也注明了。

**Windows 只提供安装版**

- 下载 `NikoDesk-windows-x64-setup.exe`，按向导安装：确认私服，设置服务密码，在 Windows 的管理员确认窗口点“是”。
- 装好后 NikoDesk 作为后台服务运行，开机自动启动；锁屏、登录界面和管理员确认窗口都能远程操作。
- 开始菜单里有 NikoDesk；在 Windows 的“设置 → 应用”里卸载。
- 不再发布便携版 EXE 和 ZIP。

## 升级须知

- **Windows：**安装版有自己的设备代码和服务密码，和便携版不同。装完后，在 Mac、iPad 上改用安装向导最后显示的新代码。便携版留下的设备列表和设置会保留。
- Mac：3.0.0 和 2.x 用同一个 NikoDesk 证书签名。装了系统后台服务并选择“空闲时自动安装”时会自动安装；否则会提醒并下载，由你替换“应用程序”里的旧版。
- Android 需要手动下载安装。
- 和 2.x 可以互相连接，通信协议没有变化。

## 已知限制

（发布前补完：Windows 安装版的实机验收状态、各平台实机检查情况。）

## Changes

**A new interface (Mac, Windows, iPad and phones)**

- The home screen is for connecting: type the other device's code into the blue connect panel and switch between remote control, file transfer and TCP tunnel there. On a computer, this computer's code and one-time password sit beside it.
- Devices you have connected to are listed below, each showing its last screen. While a session runs, a small picture is kept every 30 seconds, on this device only; turn it off under Settings > Appearance (Settings > General on phones and iPads), which deletes the kept pictures.
- Devices is a list with a detail pane; Sessions and Settings share the same card style.
- One blue, one set of type sizes and radii; meta lines no longer use middle dots.

**Controlling portable NikoDesk on Windows**

- When a portable Windows host shows an administrator prompt (UAC), the controller no longer offers an elevation request that cannot succeed; it explains that the prompt must be answered at that computer, or NikoDesk installed there.
- With "Lock after session end" on, a session warns once that a portable host cannot be unlocked remotely after locking; the menu item says so too.

**Windows ships as an installer**

- Download `NikoDesk-windows-x64-setup.exe` and follow the assistant: confirm your private server, set a service password and choose Yes in Windows' administrator prompt.
- NikoDesk then runs as a background service that starts with Windows, so the lock screen, the sign-in screen and administrator prompts can be operated remotely.
- NikoDesk is in the Start menu; uninstall it from Windows Settings > Apps.
- The portable EXE and ZIP are no longer published.

## Upgrading

- **Windows:** the installed app has its own device code and service password, not the portable one's. After installing, use the new code the assistant shows on your Mac or iPad. The portable app's device list and settings are kept.
- Mac: 3.0.0 is signed with the same NikoDesk certificate as 2.x. With the system background service and "Install when idle" it installs itself; otherwise you are notified and the package is downloaded for you to replace the app in Applications.
- Android installs by hand.
- 3.0.0 and 2.x connect to each other; the protocol has not changed.

## Known limitations

(To be completed before release: the Windows installer's real-device status and each platform's real-device checks.)

## 安装包 / Packages

| Platform | Files | Installation |
|---|---|---|
| macOS ARM64, macOS 12.3+ | DMG / ZIP | 完整 NikoDesk.app。固定 NikoDesk 证书签名（自签名），没有 Apple Developer ID 签名和公证。/ Complete app, signed with the fixed NikoDesk certificate (self-signed), no Developer ID or notarization. |
| Windows x64 | Setup EXE | 安装版，带后台服务；未签名，SmartScreen 提示时点“更多信息 → 仍要运行”。/ Installer with the background service; unsigned, choose More info > Run anyway at SmartScreen. |
| Android ARM64 | APK | 专用 NikoDesk 发行证书，包名 io.nikodesk.android，build 28。/ Dedicated release certificate, controller app, build 28. |

对照 `SHA256SUMS` 校验下载；`SHA256SUMS.sig` 是它的发布签名，NikoDesk 的软件更新会自动核对。

Verify downloads against `SHA256SUMS`. `SHA256SUMS.sig` is its publisher signature, which NikoDesk's software update checks for you.
