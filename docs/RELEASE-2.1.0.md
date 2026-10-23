# NikoDesk 2.1.0+25 — 全新界面、iPad 适配与 Mac 解码直通 / A new interface, iPad layouts and zero-copy decoding on the Mac

[下载 v2.1.0 / Download](https://github.com/baogutang/nikodesk/releases/tag/v2.1.0)

## 本次更新

**全新界面 2.1**

- 所有端共用一套新的设计系统：
  - 两套配色：Orbit（系统灰和蓝，默认）和 Clay（象牙白和赤陶），各有浅色和深色，在“设置 → 外观”里切换；
  - 文字对比度至少 4.5:1，强调色和警示标记至少 3:1；
  - Inter 字体（补齐了 ⌘ ⌥ ⇧ ⌃ 等按键符号）、Lucide 图标，统一的动效节奏。
- 主页一套布局适配桌面、iPad 和手机：
  - 侧边栏放快速连接、搜索、收藏和分组；
  - 设备区有快速连接卡片、筛选、网格或列表视图，以及设备详情面板（宽窗口停靠在右侧，窄窗口浮在上面）；
  - 命令面板（⌘K / Ctrl+K）可以找到任意设备和操作；
  - 手机用底部导航；触控布局的点按区域为 44–48 pt，并避开安全区。
- 设置分区重排：宽窗口左侧是分区导航，窄窗口是一整页。会话记录按“今天 / 昨天 / 日期”分组。
- 远控会话：
  - 控制中心（桌面和移动端）分为快捷键、显示、隐私三栏，快捷键按对端系统显示（Mac 显示 ⌘C，其他显示 Ctrl+C）；
  - 手机和 iPad 的控制条换成深色悬浮条；显示选项、画质模式、会话诊断、聊天、语音通话和触控/鼠标说明都换成新的面板；
  - 软键盘上方的按键条重做：修饰键按一下保持，Mac 对端显示 ⌃ ⌥ ⇧ ⌘，另有 Esc、Tab、方向键、F1–F12 等。
- 连接管理、文件传输窗口、对话框和提示、首次设置、服务器设置、网络唤醒、隐私屏提醒和样式编辑、TCP 隧道、远程终端和键盘类型选择，也都换成新界面。
- 读屏软件（VoiceOver 等）读带文字的控件时只读一遍名字。

**iPad**

- 界面按 iPad 的横屏、竖屏和分屏宽度排版。
- 触控板双指捏合缩放本地画面；控制 Windows 时，双指滚动的速度和 Mac 控制端一致；硬件键盘可以交换 Ctrl 和 Cmd；按 Cmd-Tab 离开 App 时，松开对端上仍按着的键。
- 指针跟随 App 的光标：在远程画面上隐藏（画面里已经画了对端的光标），在文字上显示为文本光标。
- 文件传输：横屏时“应用文件”和远端并排显示。在一侧长按选择文件，在另一侧打开目标文件夹，再点发送；宽屏时任务列表单独占一栏。
- 本版本**不提供 iPad 安装包**。没有 Apple 开发者账号就不能分发，需要自己用 Xcode 构建并签名。

**Mac 控制端解码直通**

- 收到 H.264 / HEVC 画面时，用 VideoToolbox 解码，解出的画面直接交给 Flutter 纹理显示。原来要先把每帧从 GPU 拷回内存，在 CPU 上转成 RGBA，再拷进纹理。
- 4K HEVC 每帧（M1 Max 上的解码测试）：原来约 10.3 ms、CPU 约 4.7 ms；现在约 2.0 ms、CPU 约 0.13 ms。
- Mac 控制端默认用纹理渲染（上游在 macOS 上默认关闭）。纹理渲染崩溃，或一个窗口 8 秒内没有画面进入纹理，就自动改用软件渲染。你手动设置过的选择始终优先。
- 不受支持的流、连续两次解码失败的流，以及会话开头还没有完整参数集的帧，仍交给原来的 ffmpeg 解码。质量面板里的解码实现显示为 `videotoolbox-texture`。

**修复**

- macOS 被控端开着隐私屏时，切换到全屏 App 的瞬间会露出真实屏幕。遮罩窗口现在会加入所有空间，包括其他 App 的全屏空间。
- 会话诊断里，被控端的画面统计显示成 `hostVideo: Instance of 'NikoHostVideo'`。现在显示分辨率、编码器、帧率和各阶段耗时。
- Mac 控制端用纹理渲染时，关闭远控窗口不会释放最后一帧画面（4K 约 33 MB）。

## 升级须知

- 2.1.0 和 2.0.0 用同一个 NikoDesk 证书签名，屏幕录制和辅助功能的授权应当保留。这是第一次同证书升级，没有在真机上演练过：如果升级后显示未授权，在系统设置里把 NikoDesk 的开关关掉再打开。
- 2.0.0 装了系统后台服务、并选择“空闲时自动安装”时，会在没有远控会话时自动安装 2.1.0。其他情况会提醒并下载，由你手动安装：退出 NikoDesk，用新版替换“应用程序”里的旧版，再打开。
- 被控 Mac 建议在电脑前升级，以便授权出问题时当场处理。
- 2.0.0 与 2.1.0 可以互相连接，通信协议没有变化。

## 已知限制

- Windows 和 Android 只做了构建和安装包检查，新界面没有在这两个平台的真机上运行过。
- 2.1 新界面没有在 iPad 真机上运行过。iPad 控制 Mac 的完整流程，是在新界面之前的版本上、用自己签名的构建验证的。
- 隐私屏全屏空间的修复还没有在真实的空间切换中验证。
- Mac 控制端的解码直通只在解码测试和单元测试中验证过，还没有在真实的远控窗口里看过画面。如果画面显示异常，在“高级设置 → 常规”里关闭“使用纹理渲染”。
- 2.0.0 → 2.1.0 是第一次真实的自动更新。
- 注销后（登录窗口）的远控还没有提供。
- 5K 原生编码的帧节奏不如 4K 及以下，默认不开启。

## Changes

**Interface 2.1**

- One new design system on every platform:
  - two palettes, Orbit (system greys and blue, the default) and Clay (ivory and terracotta), each light and dark, chosen under Settings → Appearance;
  - text contrast of at least 4.5:1, accent and warning marks of at least 3:1;
  - Inter type (with the ⌘ ⌥ ⇧ ⌃ key symbols added), Lucide icons and one set of motion timings.
- One home layout for desktop, iPad and phone:
  - a sidebar with quick connect, search, favourites and groups;
  - the device area: a quick-connect card, filters, grid or list, and a device inspector that docks on the right in wide windows and floats in narrow ones;
  - a command palette (⌘K / Ctrl+K) that reaches every device and action;
  - a bottom bar on phones; touch layouts use 44–48 pt targets and respect safe areas.
- Settings are regrouped: a section sidebar in wide windows, one page in narrow ones. Session history is grouped under Today, Yesterday and dates.
- Remote sessions:
  - the control center, on desktop and mobile, has three sections, Shortcuts, Display and Privacy, and shows shortcuts as the remote system spells them (⌘C for a Mac, Ctrl+C elsewhere);
  - on phone and iPad the control bar is a dark floating dock, and display options, picture mode, session diagnostics, chat, voice calls and the touch and mouse guide open as new panels;
  - the key bar above the soft keyboard is new: modifiers stay down until tapped again, a Mac peer shows ⌃ ⌥ ⇧ ⌘, and Esc, Tab, arrows and F1–F12 are there.
- The connection manager, file transfer window, dialogs and toasts, first-run setup, server settings, Wake-on-LAN, the privacy reminder and style editor, TCP tunnels, the remote terminal and the keyboard type chooser use the new interface too.
- Screen readers such as VoiceOver read a control with visible text once.

**iPad**

- Layouts follow the iPad's landscape, portrait and Split View widths.
- A trackpad pinch zooms the local view; two-finger scrolling to Windows uses the Mac controller's speed; a hardware keyboard can swap Ctrl and Cmd; leaving the app with Cmd-Tab releases keys still held on the remote.
- The pointer follows the app's cursors: hidden over the remote screen, which already paints the remote cursor, and a text beam over text.
- File transfer: in landscape, App files and the remote side sit next to each other. Long-press files on one side, open the destination folder on the other and tap Send; wide screens give the tasks a column of their own.
- This release has **no iPad package**. Distributing one needs an Apple developer account, so build and sign it yourself with Xcode.

**Zero-copy decoding on the Mac controller**

- H.264 and HEVC pictures are decoded with VideoToolbox and handed to the Flutter texture as they are. Before, each picture was copied back from the GPU, converted to RGBA on the CPU and copied again into the texture.
- Per 4K HEVC picture (decoder test on an M1 Max): about 10.3 ms and 4.7 ms of CPU before, about 2.0 ms and 0.13 ms now.
- The Mac controller renders through the texture by default (upstream keeps it off on macOS). If texture rendering crashes, or a window gets no picture into its texture for 8 seconds, NikoDesk switches to software rendering. A choice you made yourself always wins.
- Unsupported streams, streams that fail twice in a row, and frames before the first complete parameter sets still go to the previous ffmpeg decoder. The quality panel shows the decoder as `videotoolbox-texture`.

**Fixes**

- With the privacy screen on, a controlled Mac showed its real screen for a moment when switching to a full-screen app. The cover now joins every Space, other apps' full-screen Spaces included.
- Session diagnostics showed the controlled side's picture statistics as `hostVideo: Instance of 'NikoHostVideo'`. They now read as resolution, encoder, frame rate and stage times.
- With texture rendering on the Mac controller, closing a session window kept its last picture in memory (about 33 MB at 4K).

## Upgrading

- 2.1.0 is signed with the same NikoDesk certificate as 2.0.0, so Screen Recording and Accessibility should stay granted. This is the first update under the same certificate and it has not been rehearsed on a real machine: if NikoDesk shows them as not granted afterwards, turn its switch off and on in System Settings.
- 2.0.0 with the system background service and "Install when idle" installs 2.1.0 by itself while no remote session is active. Otherwise you are notified and the package is downloaded for you: quit NikoDesk, replace it in Applications and open it again.
- Upgrade a controlled Mac while you are at it, so a permission problem can be fixed on the spot.
- 2.0.0 and 2.1.0 connect to each other; the protocol has not changed.

## Known limitations

- Windows and Android were built and package-checked only; the new interface has not run on real devices of either platform.
- The 2.1 interface has not run on a real iPad. iPad control of a Mac was verified end to end with a self-signed build from before the new interface.
- The privacy-screen fix for full-screen Spaces has not been checked with a real Space switch yet.
- Zero-copy decoding on the Mac controller was verified in a decoder test and unit tests only, not yet in a real session window. If the picture looks wrong, turn off Use texture rendering under Advanced → General.
- 2.0.0 → 2.1.0 is the first real automatic update.
- Remote control at the login window (after logout) is not available yet.
- Native encoding at 5K paces frames worse than at 4K and below, so it stays off by default.

## 安装包 / Packages

| Platform | Files | Installation |
|---|---|---|
| macOS ARM64, macOS 12.3+ | DMG / ZIP | 完整 NikoDesk.app。固定 NikoDesk 证书签名（自签名），没有 Apple Developer ID 签名和公证。/ Complete app, signed with the fixed NikoDesk certificate (self-signed), no Developer ID or notarization. |
| Windows x64 | Portable EXE / ZIP | 便携运行，无需安装；未签名。/ Portable, no installation; unsigned. |
| Windows x64 unattended setup | Setup-validation EXE / ZIP | 安装器会注册服务；未签名。/ Installer registers a service; unsigned. |
| Android ARM64 | APK | 专用 NikoDesk 发行证书，包名 io.nikodesk.android，build 25。/ Dedicated release certificate, controller app, build 25. |

对照 `SHA256SUMS` 校验下载；`SHA256SUMS.sig` 是它的发布签名，NikoDesk 的软件更新会自动核对。

Verify downloads against `SHA256SUMS`. `SHA256SUMS.sig` is its publisher signature, which NikoDesk's software update checks for you.
