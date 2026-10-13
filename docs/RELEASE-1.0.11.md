# NikoDesk 1.0.11+22 — 修复 Mac 隐私屏自动关闭 / Mac privacy screen fix

[下载 v1.0.11 / Download](https://github.com/baogutang/nikodesk/releases/tag/v1.0.11)

## 本次更新

- 修复 Mac 隐私屏开启后，在另一个控制会话断开或远控采集尺寸调整时自动关闭、重新露出本机桌面的问题。
- 调整采集尺寸时，保留本机遮罩和输入保护，为当前隐私屏辅助进程重新建立排除遮罩的画面采集。新的采集收到有效画面后再替换旧采集。
- 新增尺寸切换、多屏隔离、采集失败和会话归属变化的回归检查。
- macOS、Windows、Android 的产品版本统一更新到 1.0.11，构建号为 22。

优先更新**被控 Mac**。控制端可以继续使用 1.0.10，也可一并升级。隐私屏设置、动效、按设备自动开启和系统登录密码退出方式沿用现有操作。

连接前，在被控电脑的“设置 → 会话安全”允许隐私屏，并允许会话使用键鼠。开启后可在控制端调整画面尺寸；其他控制会话退出时，当前会话的隐私屏保持开启。控制端关闭或断开后仍会恢复屏幕。

## Changes

- Fix the Mac privacy screen turning off and exposing the local desktop when another controller disconnects or the remote capture size changes.
- Keep the local cover and input protection active while creating a replacement capture that explicitly excludes the current privacy helper. Replace the old capture after the new one produces a valid frame.
- Add regression checks for resizing, monitor isolation, capture failure and changes of session ownership.
- Update macOS, Windows and Android to product version 1.0.11, build 22.

Update the **controlled Mac** first. Controllers on 1.0.10 remain compatible, or can be upgraded together. Existing styles, automatic activation settings and local system-password exit remain available.

Enable privacy-screen permission on the controlled computer and allow keyboard/mouse input for the session. The current owner's privacy screen stays on across capture-size changes and the departure of other controllers. Turning privacy off or disconnecting the owner still restores the screen.

## 安装包 / Packages

| Platform | Files | Installation |
|---|---|---|
| macOS ARM64, macOS 12.3+ | DMG / ZIP | 完整 NikoDesk.app；ad-hoc 签名，无 Apple Developer ID 签名与公证。/ Complete app, ad-hoc signed without Developer ID or notarization. |
| Windows x64 | Portable EXE / ZIP | 便携运行，无需安装；当前未签名。/ Portable, no installation; unsigned. |
| Windows x64 unattended setup | Setup-validation EXE / ZIP | 安装器会注册服务；当前未签名。/ Installer registers a service; unsigned. |
| Android ARM64 | APK | 专用 NikoDesk 发行证书，包名 io.nikodesk.android，build 22。/ Dedicated release certificate, controller app, build 22. |

对照 `SHA256SUMS` 校验下载。更新需手动退出旧版、替换完整应用或安装包、再重新打开。macOS 可能需要重新授予原有系统权限。

Verify downloads against `SHA256SUMS`. Updates require manually quitting the previous app, replacing the complete application or installing the package, and reopening it. macOS may require its existing permissions to be granted again.
