# NikoDesk 1.0.9+20 — 样式隐私屏 / Privacy screen styles

[下载 v1.0.9 / Download](https://github.com/baogutang/nikodesk/releases/tag/v1.0.9)

## 本次更新

- **控制端选择隐私屏**：内置「雪岭」「纸光」「像素雨夜」，分别提供山雾、移动光影和雨滴动效；也可导入 PNG/JPG/WebP 作为自定义背景。
- **按设备保存**：可调整亮度、动效开关与强度、时钟和恢复提示。默认关闭时钟，保留小号恢复提示。被控端确认应用成功后才保存选择，重连继续使用。
- **会话与权限修复**：修复另一会话开启失败时可能清除现有隐私屏的问题，补齐键鼠权限判断，并限制采集器退出等待时间。
- **官网排版**：修复中文版相邻背景块连在一起的问题；中英文官网补充样式隐私屏介绍，下载入口更新到 1.0.9。
- **Android**：包含 1.0.8 的启动、私服连接、历史记录与已保存凭据重连修复；发行包名和签名证书沿用，构建号递增到 20。

## 使用方式

先在被控电脑打开“设置 → 会话安全 → 允许新连接使用隐私屏”，并允许该会话使用键鼠。两端升级到 1.0.9 后，在控制端的“控制中心 → 隐私屏”选择预设或图片，点击“应用并开启”。旧版本被控端继续使用原有黑屏方式。

Mac 使用原生遮罩，要求 macOS 12.3 或以上；Windows 使用原生遮罩。被控 Mac 上按 Control + Option + Shift + Esc，Windows 上按 Esc，或在控制端关闭隐私屏即可恢复。Android 是控制端，不提供手机被控能力。

## Changes

- Choose **Snow Ridge**, **Paper Light** or **Pixel Rain** from the controller, with mist, moving light and shadow, or rain. Import a PNG/JPG/WebP picture for a custom background.
- Adjust brightness, animation, intensity, the clock and recovery hint. The clock is off by default. Save each device's choice only after the controlled computer confirms it was applied, and reuse it on reconnect.
- Fix privacy-screen owner cleanup and input-permission checks, and bound capture shutdown waits.
- Separate the adjoining backgrounds on the Chinese website; update both languages with the feature and 1.0.9 downloads.
- Include 1.0.8's Android startup, private-server connection, history and saved-credential reconnect fixes. Keep the application ID and release certificate, with build number 20.

Enable privacy-screen permission on the controlled computer and allow keyboard input for the session. With both ends on 1.0.9, open **Control center → Privacy screen**, choose a style or picture, then apply it. Older endpoints keep their original blackout. The Mac overlay requires macOS 12.3+. Control + Option + Shift + Esc on the controlled Mac, Esc on Windows, or turning privacy off from the controller restores the screen.

## 安装包 / Packages

| Platform | Files | Installation |
|---|---|---|
| macOS ARM64, macOS 12.3+ | DMG / ZIP | 完整 NikoDesk.app；ad-hoc 签名，无 Apple Developer ID 签名与公证。/ Complete app, ad-hoc signed without Developer ID or notarization. |
| Windows x64 | Portable EXE / ZIP | 便携运行，无需安装；当前未签名。/ Portable, no installation; unsigned. |
| Windows x64 unattended setup | Setup-validation EXE / ZIP | 安装器会注册服务；当前未签名。/ Installer registers a service; unsigned. |
| Android ARM64 | APK | 专用 NikoDesk 发行证书签名，包名 io.nikodesk.android，build 20。/ Dedicated release certificate, controller app, build 20. |

对照 `SHA256SUMS` 校验下载。更新仍需手动安装：退出旧版，替换完整应用，再重新打开。macOS 可能需要重新授予原有系统权限。

Verify downloads against `SHA256SUMS`. Updates require manual installation: quit the previous app, replace the complete application and reopen it. macOS may require its permissions to be granted again.
