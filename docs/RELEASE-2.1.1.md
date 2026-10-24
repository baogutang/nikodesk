# NikoDesk 2.1.1+26 — 设备列表与 Windows 提示修复 / Device list and Windows guidance fixes

[下载 v2.1.1 / Download](https://github.com/baogutang/nikodesk/releases/tag/v2.1.1)

2.1.1 是 2.1.0 的修复版，2.1 的全部改动见 [2.1.0 版本说明](https://github.com/baogutang/nikodesk/blob/main/docs/RELEASE-2.1.0.md)。

## 本次更新

**设备列表**

- 列表不再显示本机。以前只要连过自己一次，本机就会出现在列表里，还能对自己发起连接。
  - 现在快速连接、设备卡片、会话记录里的“再次连接”和链接打开都会拒绝本机 ID，提示“这是本机的设备 ID，不能连接自己”。快速连接和会话记录在询问密码之前就会拒绝。
  - 连上自己不会再记进列表，手动添加本机 ID 也会被拒绝。
  - 目录文件里已有的那条记录不会删除，只是不再显示。
- 没有起名字的设备，标题显示对方上次连接时报告的主机名，ID 前面显示系统，例如“Windows · 123 456 789”。
  - 设备详情里多了“系统”和“主机名”两行，搜索也能搜到主机名。
  - 从没连上过的设备仍然只显示 ID。

**Windows**

- 虚拟屏驱动面板：
  - NikoDesk 没有以管理员身份运行时，标题显示“需要管理员权限”，并写明要在电脑前完成的步骤。提权时系统弹出的确认框，远程会话看不到，也点不了。
  - 说明里写清楚了：只有“允许连接创建虚拟屏”用这个驱动，隐私屏不需要它。
- “控制结束后自动锁屏”下面多了一句提醒：便携版在 Windows 锁屏后看不到也操作不了登录界面，远程只会看到黑屏，要回到电脑前解锁。

## 升级须知

- 2.1.1 和 2.0.0、2.1.0 用同一个 NikoDesk 证书签名，屏幕录制和辅助功能的授权应当保留。同证书升级还没有在真机上演练过：如果升级后显示未授权，在系统设置里把 NikoDesk 的开关关掉再打开。
- 2.0.0 或 2.1.0 装了系统后台服务、并选择“空闲时自动安装”时，会在没有远控会话时自动安装 2.1.1。其他情况下会提醒并下载，由你手动安装：退出 NikoDesk，用新版替换“应用程序”里的旧版，再打开。
- Windows 便携版和 Android 需要手动下载安装。
- 和 2.0.0、2.1.0 可以互相连接，通信协议没有变化。

## 已知限制

- 新的设备列表和 Windows 提示只在单元测试中验证过，还没有在真机上看过。Windows 上的文字只能在 Windows 包里看到。
- Windows 便携版无法远程操作锁屏后的登录界面，以前的版本也一样，这一版只是加了提示。无人值守服务（setup-validation 安装器）能解决这个问题，但还没有在真机上验证过。
- Windows 隐私屏还没有在真实的 Windows 上测试过。
- 2.1.0 的已知限制仍然有效：
  - Windows 和 Android 只做了构建和安装包检查；
  - 2.1 新界面没有在 iPad 真机上运行过；
  - 隐私屏全屏空间的修复还没有在真实的空间切换中验证；
  - Mac 控制端的解码直通还没有在真实的远控窗口里看过画面，画面异常时在“高级设置 → 常规”里关闭“使用纹理渲染”；
  - 第一次真实的自动更新还没有发生；
  - 注销后（登录窗口）的远控还没有提供；
  - 5K 原生编码默认不开启。

## Changes

2.1.1 fixes 2.1.0. For everything new in 2.1, see the [2.1.0 notes](https://github.com/baogutang/nikodesk/blob/main/docs/RELEASE-2.1.0.md).

**Device list**

- The list no longer shows this computer. Before, a single connection to its own ID put it in the list, and you could start a session to yourself from there.
  - Quick connect, device cards, Connect again in the session history and links now refuse this computer's own ID with "This is this computer’s own device ID. It cannot connect to itself." Quick connect and the history refuse it before asking for a password.
  - A session to yourself is no longer saved as a device, and adding your own ID by hand is refused.
  - An entry already in the directory file is hidden, not deleted.
- A device without a name shows the host name its peer reported in the last session, with the platform before the ID, for example "Windows · 123 456 789".
  - The device inspector gains System and Host name rows, and search matches host names.
  - A device that never connected still shows only its ID.

**Windows**

- Virtual display driver panel:
  - When NikoDesk is not running as Administrator, the panel heading says "Administrator rights needed" and lists the steps to take at the computer. A remote session cannot see or click the system prompt that elevation shows.
  - The panel now says that only virtual displays use this driver and the privacy screen does not need it.
- Lock after remote control gains a warning: after Windows locks, portable NikoDesk cannot see or use the sign-in screen, so a remote session shows black until someone unlocks the computer in person.

## Upgrading

- 2.1.1 is signed with the same NikoDesk certificate as 2.0.0 and 2.1.0, so Screen Recording and Accessibility should stay granted. An update under the same certificate has not been rehearsed on a real machine yet: if NikoDesk shows them as not granted afterwards, turn its switch off and on in System Settings.
- 2.0.0 or 2.1.0 with the system background service and "Install when idle" installs 2.1.1 by itself while no remote session is active. Otherwise you are notified and the package is downloaded for you: quit NikoDesk, replace it in Applications and open it again.
- Windows (portable) and Android install by hand.
- 2.0.0, 2.1.0 and 2.1.1 connect to each other; the protocol has not changed.

## Known limitations

- The new device list and the Windows notes were verified in unit tests only, not on real devices yet. The Windows text appears only in the Windows package.
- Portable NikoDesk on Windows cannot operate the sign-in screen after a lock. Earlier versions had the same limit; this release only explains it. The unattended service (the setup-validation installer) addresses it but has not been verified on a real machine.
- The Windows privacy screen has not been tested on a real Windows computer.
- The 2.1.0 limitations still apply:
  - Windows and Android were built and package-checked only;
  - the 2.1 interface has not run on a real iPad;
  - the privacy-screen fix for full-screen Spaces has not been checked with a real Space switch;
  - zero-copy decoding on the Mac controller has not been seen in a real session window; if the picture looks wrong, turn off Use texture rendering under Advanced → General;
  - the first real automatic update has not happened yet;
  - remote control at the login window (after logout) is not available yet;
  - native encoding at 5K stays off by default.

## 安装包 / Packages

| Platform | Files | Installation |
|---|---|---|
| macOS ARM64, macOS 12.3+ | DMG / ZIP | 完整 NikoDesk.app。固定 NikoDesk 证书签名（自签名），没有 Apple Developer ID 签名和公证。/ Complete app, signed with the fixed NikoDesk certificate (self-signed), no Developer ID or notarization. |
| Windows x64 | Portable EXE / ZIP | 便携运行，无需安装；未签名。/ Portable, no installation; unsigned. |
| Windows x64 unattended setup | Setup-validation EXE / ZIP | 安装器会注册服务；未签名。/ Installer registers a service; unsigned. |
| Android ARM64 | APK | 专用 NikoDesk 发行证书，包名 io.nikodesk.android，build 26。/ Dedicated release certificate, controller app, build 26. |

对照 `SHA256SUMS` 校验下载；`SHA256SUMS.sig` 是它的发布签名，NikoDesk 的软件更新会自动核对。

Verify downloads against `SHA256SUMS`. `SHA256SUMS.sig` is its publisher signature, which NikoDesk's software update checks for you.
