# NikoDesk 2.0.0+23 — 夜航界面、原生编码与可校验的更新 / Nightline UI, native encoding and verified updates

[下载 v2.0.0 / Download](https://github.com/baogutang/nikodesk/releases/tag/v2.0.0)

## 本次更新

**全新界面「夜航」**

- 桌面端（macOS、Windows）重做：主页与设备列表、连接对话框、远控窗口、文件传输窗口、连接管理（来访卡片、权限与能力面板），以及设置和隐私屏样式编辑。深色为主，也有浅色；文字对比度按 WCAG AA 调整。
- 隐私屏场景换成「夜航」「深空」「极光」「石墨」，也可以用自己的图片。动效、光感、亮度、时钟和恢复提示都可以调。
- 首次设置服务器的页面也换成新界面。

**画面更顺、更省（被控 Mac）**

- 默认用 ScreenCaptureKit 采集。4K 及以下的画面直接交给 VideoToolbox HEVC 编码，中间不再复制。本机经隧道中继测试（3200×1800、60 帧）：被控端 CPU 约 3–4%，原来约 31%。超过 4K 仍用原来的编码路径。
- 分辨率变化、显示器插拔和排列调整改由系统事件触发，发现变化的时间从约 250–370 ms 缩短到约 60–80 ms。切换后第一帧的总耗时只略有缩短。
- 远控期间，NikoDesk 向系统声明低延迟活动，避免被 App Nap 降速。
- 控制端让被控 Mac 创建虚拟屏时，按控制端所在屏幕的像素、缩放和刷新率生成 HiDPI 虚拟屏，不再固定为 60 Hz、1x。两端都需要 2.0.0。

**状态看得见**

- 画质面板新增：
  - 连接路线（直连或中继）；
  - 建立连接各步骤的耗时；
  - 被控端的采集尺寸、编码器、每秒新画面数、帧率上限、刷新率和各阶段耗时。
- 被控 Mac 缺少屏幕录制或辅助功能权限时，控制端会在整个会话中说明哪些功能用不了、去哪里授权，不再只是黑屏或没有响应。
- Mac 菜单栏图标：
  - 显示能否被连接、当前有几个远程连接，有会话时图标右下角出现圆点；
  - 菜单里可以复制本机 ID、打开主窗口、退出。
- 启动时如果缺少屏幕录制或辅助功能权限，先显示权限引导：
  - 每一项都能直接打开对应的系统设置页，授权后自动刷新；
  - 可以跳过本次，也可以选择不再提醒。

**更新与安全（macOS）**

- 改用固定的 NikoDesk 证书签名（自签名，没有 Apple 公证）。从 2.0.0 起，后续版本保持同一签名身份，系统授权不会再因为更新而失效。
- 可选的系统后台服务。在“设置 → 无人值守”中安装，需要输入一次管理员密码。
  - 新版本下载并校验后，由它在没有远控会话时安装并重新打开 NikoDesk，也可以恢复上一个版本。
  - 它只接受 NikoDesk 证书签名的安装包，只运行自己在 root 私有目录里的副本，并对每个请求校验调用方签名、要求挑战应答。
- 软件更新只接受带有效发布签名（`SHA256SUMS.sig`）的版本。
  - 每 6 小时检查一次正式版，可以选择“提醒我”或“空闲时自动安装”。
  - 没有安装系统后台服务时，仍会提醒并下载，由你手动安装。
- 本地崩溃记录与脱敏诊断包：可以在设置中导出。地址、UUID 和长度与设备 ID 相同的数字会被替换，不会上传。

**修复**

- macOS 暂停隐私屏的输入过滤后，会自动恢复。
- 新连接不会把之前会话的隐私屏误显示为已开启。
- 隐私屏场景在遮罩窗口中上下颠倒。
- 后台恢复的条件不满足时（例如更新后授权失效），不再被系统每隔几秒重启一次，而是等待并写日志。

## 升级须知

- **被控 Mac 请在电脑前升级。**
  1. 退出旧版 NikoDesk，用 DMG 中的 NikoDesk.app 替换“应用程序”里的旧版，再打开。
  2. 签名换成了固定证书，这一次需要重新授权屏幕录制和辅助功能，启动时的权限引导会带你完成。
  3. 系统设置里已有 NikoDesk 且开关是开的，却仍显示未授权：先关掉再打开；仍不行，就删除后重新添加。
  4. 授权完成前，远程连接只能看到黑屏，也不能操作。
- 启用了“后台恢复”的 Mac，替换应用后注销并重新登录一次，让后台进程换成新版本。
- 1.0.11 及更早版本不会自动安装 2.0.0，这一次需要手动下载。
- 1.0.11 的控制端仍可以连接 2.0.0。虚拟屏按屏幕规格生成、被控端统计等新功能需要两端都升级。

## 已知限制

- Windows 和 Android 只做了构建和安装包检查，没有在真机上运行。
- 2.0.0 是第一个带系统后台服务的版本，第一次真正的自动更新会发生在下一个版本。
- 注销后（登录窗口）的远控还没有提供。
- 5K 原生编码的帧节奏不如 4K 及以下，默认不开启。

## Changes

**Nightline, a new interface**

- The desktop app (macOS and Windows) is redesigned: home and device list, connect dialog, session window, file transfer window, connection manager (visitor card, permission and capability panels), settings and the privacy-screen style editor. Dark first, with a light theme; text contrast follows WCAG AA.
- Privacy-screen scenes are now Nightline, Deep field, Aurora and Graphite, or your own image. Animation, glow, brightness, clock and restore hint can be adjusted.
- First-time server setup uses the new interface too.

**Smoother, lighter video (controlled Mac)**

- Capture uses ScreenCaptureKit by default. Up to 4K, frames go straight into a VideoToolbox HEVC session without a copy. In a local test through a tunnelled relay (3200×1800, 60 frames), the controlled side used about 3–4% CPU instead of about 31%. Above 4K the previous encoder path stays.
- Resolution changes, display hot-plug and arrangement changes are picked up from system events: detection takes about 60–80 ms instead of about 250–370 ms. The first frame after a switch arrives only slightly sooner.
- Each remote session declares a latency-critical activity, so App Nap does not slow NikoDesk down.
- A virtual display created on the controlled Mac now matches the controller's screen (pixels, scale and refresh rate, HiDPI) instead of fixed 60 Hz 1x modes. Both ends need 2.0.0.

**Status you can see**

- The quality panel adds:
  - the connection route (direct or relayed);
  - the time of each connection step;
  - the controlled side's capture size, encoder, new pictures per second, frame limit, refresh rate and stage times.
- When the controlled Mac lacks Screen Recording or Accessibility, the controller says for the whole session what will not work and where to grant it, instead of an empty picture or ignored input.
- A Mac menu bar icon:
  - shows whether the Mac can be reached and how many remote connections are active; a dot appears on the icon during a session;
  - its menu copies this Mac's ID, opens the main window or quits.
- If Screen Recording or Accessibility is missing at launch, a permission guide comes first:
  - each item opens its System Settings pane and the guide refreshes as you grant them;
  - skip it for now, or turn the reminder off.

**Updates and security (macOS)**

- Signed with the fixed NikoDesk certificate (self-signed, not notarized by Apple). From 2.0.0 on, later versions keep the same signing identity, so updates no longer reset system permissions.
- An optional system background service, installed under Settings → Unattended access with one administrator password.
  - After a new version is downloaded and verified, it installs it and reopens NikoDesk while no remote session is active. It can also restore the previous version.
  - It accepts only packages signed with the NikoDesk certificate, runs only its own copy in a root-owned directory, and checks the caller's signature and a challenge on every request.
- Software update accepts only releases with a valid publisher signature (`SHA256SUMS.sig`).
  - The stable channel is checked every 6 hours: choose "Remind me" or "Install when idle".
  - Without the background service you are still notified and the package is downloaded for you to install.
- Local crash records and a redacted diagnostics bundle can be exported from Settings. Addresses, UUIDs and numbers as long as a device ID are replaced. Nothing is uploaded.

**Fixes**

- The privacy-screen input filter resumes when macOS pauses it.
- A new connection never shows an earlier session's privacy screen as on.
- Privacy-screen scenes were drawn upside down in the cover window.
- When background recovery cannot start yet (for example after an update cleared permissions), launchd no longer restarts it every few seconds. It waits and logs the reason instead.

## Upgrading

- **Upgrade the controlled Mac while you are at it.**
  1. Quit the old NikoDesk, replace it in Applications with NikoDesk.app from the DMG, and open it.
  2. The new fixed certificate means Screen Recording and Accessibility must be granted once more. The permission guide at launch walks you through it.
  3. If NikoDesk is listed and switched on in System Settings but still not allowed, turn it off and on. If that does not help, remove it and add it again.
  4. Until then, remote sessions show an empty picture and cannot control the Mac.
- With background recovery enabled, log out and back in once after replacing the app, so the background process runs the new version.
- 1.0.11 and earlier do not install 2.0.0 by themselves: download it manually this time.
- Controllers on 1.0.11 can still connect to 2.0.0. New features such as screen-matched virtual displays and controlled-side statistics need both ends upgraded.

## Known limitations

- Windows and Android were built and package-checked only, not run on real devices.
- 2.0.0 is the first version with the background service. The first real automatic update will be to the next version.
- Remote control at the login window (after logout) is not available yet.
- Native encoding at 5K paces frames worse than at 4K and below, so it stays off by default.

## 安装包 / Packages

| Platform | Files | Installation |
|---|---|---|
| macOS ARM64, macOS 12.3+ | DMG / ZIP | 完整 NikoDesk.app。固定 NikoDesk 证书签名（自签名），没有 Apple Developer ID 签名和公证。/ Complete app, signed with the fixed NikoDesk certificate (self-signed), no Developer ID or notarization. |
| Windows x64 | Portable EXE / ZIP | 便携运行，无需安装；未签名。/ Portable, no installation; unsigned. |
| Windows x64 unattended setup | Setup-validation EXE / ZIP | 安装器会注册服务；未签名。/ Installer registers a service; unsigned. |
| Android ARM64 | APK | 专用 NikoDesk 发行证书，包名 io.nikodesk.android，build 23。/ Dedicated release certificate, controller app, build 23. |

对照 `SHA256SUMS` 校验下载；`SHA256SUMS.sig` 是它的发布签名，NikoDesk 的软件更新会自动核对。

Verify downloads against `SHA256SUMS`. `SHA256SUMS.sig` is its publisher signature, which NikoDesk's software update checks for you.
