# NikoDesk 2.2.0+27 — 可靠锁屏、更快的点击响应与 iPad 硬件解码 / Reliable locking, faster clicks and iPad hardware decoding

[下载 v2.2.0 / Download](https://github.com/baogutang/nikodesk/releases/tag/v2.2.0)

## 本次更新

**被控 Mac 的锁屏**

- 会话结束后锁屏（开启该选项时）和“锁定远程屏幕”，现在都直接请登录窗口锁屏，再在 2 秒内确认确实锁上了。只有没锁上时才退回到快捷键（Control‑Command‑Q）。
  - 以前靠快捷键锁屏。快捷键或触发角被改过时，Mac 可能一直停在未锁状态。
  - 实测：会话结束 5 秒后锁屏，107 ms 锁上。
- 控制端在会话开始时不再把远程指针移到左上角，而是放在屏幕中间。以前如果被控 Mac 的左上角设了“锁定屏幕”触发角，一连上就会被锁。

**点击响应**

- 被控 Mac 收到控制端的点击后，接下来 200 ms 内每 4 ms 检查一次有没有新画面，不再等下一个固定的帧间隔。
  - 实测（iPad 经私服中继控制 Mac，每组 200 次点击，多组交替对照）：从注入点击到采集到新画面，中位数从约 47 ms 降到约 33 ms。
  - 平均 CPU 占用没有可测的变化（两种情况都是约 1.7% 到 1.8%）。

**iPad（从源码构建，不提供 iPad 安装包）**

- H.264 和 HEVC 改用 VideoToolbox 硬件解码。3200×1800 的 HEVC 每帧解码从约 20 ms 降到约 6 ms，转成界面图像多花约 3.5 ms，合计每帧省约 10 ms。VideoToolbox 解不了的视频仍交给原来的软件解码。
- 没选过画面模式的设备，默认用“流畅”：按 iPad 屏幕的刷新率请求帧率（iPad Pro 是 120），不再是“平衡”画质的每秒 30 帧。被控端屏幕的刷新率是实际上限：75 Hz 的显示器实测 75 帧/秒，码率从约 2.7 Mbit/s 升到约 3.5 Mbit/s（测试画面）。选过的模式、在设置里改过的默认画质都不受影响。

## 升级须知

- 2.2.0 和 2.0.0、2.1.x 用同一个 NikoDesk 证书签名，屏幕录制和辅助功能的授权应当保留。同证书升级还没有在真机上演练过：如果升级后显示未授权，在系统设置里把 NikoDesk 的开关关掉再打开。
- 2.0.0 或 2.1.x 装了系统后台服务、并选择“空闲时自动安装”时，会在没有远控会话时自动安装 2.2.0。其他情况下会提醒并下载，由你手动安装：退出 NikoDesk，用新版替换“应用程序”里的旧版，再打开。
- Windows 便携版和 Android 需要手动下载安装。
- 和 2.0.0、2.1.x 可以互相连接，通信协议没有变化。锁屏和点击响应的改进在被控 Mac 上，控制端用旧版也能得到。

## 已知限制

- 从控制端按“锁定远程屏幕”没有单独测过。它和会话结束后锁屏用的是同一段代码，后者已验证。
- iPad 的默认画面模式只在单元测试里验证过，还没有在正式 iPad App 里看过。上面的帧率和解码数据来自 iPad 测量版。
- iOS 15 和 16 上的 VideoToolbox 解码没有真机测过（只测了 iPadOS 26）。
- 真实桌面内容（例如 5K 下滚动文字）在高帧率下的码率没有测。
- 2.1.x 的已知限制仍然有效：
  - Windows 和 Android 只做了构建和安装包检查；
  - 隐私屏全屏空间的修复还没有在真实的空间切换中验证；
  - Mac 控制端的解码直通还没有在真实的远控窗口里看过画面，画面异常时在“高级设置 → 常规”里关闭“使用纹理渲染”；
  - 第一次真实的自动更新还没有发生；
  - 注销后（登录窗口）的远控还没有提供；
  - Windows 便携版无法远程操作锁屏后的登录界面；
  - 5K 原生编码默认不开启。

## Changes

**Locking a controlled Mac**

- Locking after a session ends (when that option is on) and **Lock remote screen** now ask the login window to lock, then check within 2 seconds that the lock took. Only if it did not do they fall back to the keyboard shortcut (Control‑Command‑Q).
  - Before, locking relied on a shortcut. With a changed shortcut or hot corner the Mac could stay unlocked.
  - Measured: locked 5 seconds after a session ended, in 107 ms.
- The controller no longer moves the remote pointer to the top-left corner when a session starts; it starts mid-screen. A Mac with a Lock Screen hot corner there locked as soon as a session began.

**Click response**

- After a click from the controller, a controlled Mac checks for a new picture every 4 ms for 200 ms instead of waiting for the next regular frame slot.
  - Measured from an iPad through the private relay, 200 clicks per run, alternating runs: from injected click to captured picture, the median fell from about 47 ms to about 33 ms.
  - Average CPU use did not change measurably (about 1.7% to 1.8% either way).

**iPad (built from source; no iPad package is published)**

- H.264 and HEVC are decoded with VideoToolbox. A 3200×1800 HEVC picture takes about 6 ms instead of 20; turning it into the UI image adds about 3.5 ms, so each picture is about 10 ms faster. Video that VideoToolbox cannot decode still goes to the software decoder.
- A device without a chosen picture mode starts in the responsive mode, which asks for the iPad's refresh rate (120 on an iPad Pro) instead of the 30 frames a second of balanced quality. The controlled screen's refresh rate is the real limit: a 75 Hz display measured 75 frames a second, at about 3.5 Mbit/s instead of 2.7 (test pattern). A chosen mode and a changed default quality are left alone.

## Upgrading

- 2.2.0 is signed with the same NikoDesk certificate as 2.0.0 and 2.1.x, so Screen Recording and Accessibility should stay granted. An update under the same certificate has not been rehearsed on a real machine yet: if NikoDesk shows them as not granted afterwards, turn its switch off and on in System Settings.
- 2.0.0 or 2.1.x with the system background service and "Install when idle" installs 2.2.0 by itself while no remote session is active. Otherwise you are notified and the package is downloaded for you: quit NikoDesk, replace it in Applications and open it again.
- Windows (portable) and Android install by hand.
- 2.0.0, 2.1.x and 2.2.0 connect to each other; the protocol has not changed. The locking and click-response changes are on the controlled Mac, so older controllers get them too.

## Known limitations

- **Lock remote screen** pressed from a controller was not tested on its own; it runs the same code as locking after a session ends, which was verified.
- The iPad's default picture mode was verified in unit tests only, not yet in the regular iPad app. The frame-rate and decoding figures above come from a measuring build of the iPad app.
- VideoToolbox decoding on iOS 15 and 16 has not run on a real device (only iPadOS 26 was tested).
- The bitrate of real desktop content at high frame rates (such as scrolling text at 5K) was not measured.
- The 2.1.x limitations still apply:
  - Windows and Android were built and package-checked only;
  - the privacy-screen fix for full-screen Spaces has not been checked with a real Space switch;
  - zero-copy decoding on the Mac controller has not been seen in a real session window; if the picture looks wrong, turn off Use texture rendering under Advanced → General;
  - the first real automatic update has not happened yet;
  - remote control at the login window (after logout) is not available yet;
  - portable NikoDesk on Windows cannot operate the sign-in screen after a lock;
  - native encoding at 5K stays off by default.

## 安装包 / Packages

| Platform | Files | Installation |
|---|---|---|
| macOS ARM64, macOS 12.3+ | DMG / ZIP | 完整 NikoDesk.app。固定 NikoDesk 证书签名（自签名），没有 Apple Developer ID 签名和公证。/ Complete app, signed with the fixed NikoDesk certificate (self-signed), no Developer ID or notarization. |
| Windows x64 | Portable EXE / ZIP | 便携运行，无需安装；未签名。/ Portable, no installation; unsigned. |
| Windows x64 unattended setup | Setup-validation EXE / ZIP | 安装器会注册服务；未签名。/ Installer registers a service; unsigned. |
| Android ARM64 | APK | 专用 NikoDesk 发行证书，包名 io.nikodesk.android，build 27。/ Dedicated release certificate, controller app, build 27. |

对照 `SHA256SUMS` 校验下载；`SHA256SUMS.sig` 是它的发布签名，NikoDesk 的软件更新会自动核对。

Verify downloads against `SHA256SUMS`. `SHA256SUMS.sig` is its publisher signature, which NikoDesk's software update checks for you.
