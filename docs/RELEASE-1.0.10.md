# NikoDesk 1.0.10+21 — 隐私屏连接与退出 / Privacy screen connection and exit

[下载 v1.0.10 / Download](https://github.com/baogutang/nikodesk/releases/tag/v1.0.10)

## 本次更新

- **连接提醒**：连接桌面后，控制端提示开启被控电脑的隐私屏，可以选择“暂不开启”继续使用。
- **按设备自动开启**：勾选“以后连接这台电脑自动开启”，或在控制中心开启“连接后自动开启隐私屏”。关闭后改为可跳过的提醒，不再因上次开启状态自动重开。
- **状态与快捷键常驻**：被控屏幕显眼地显示“本机已开启隐私屏”与退出快捷键；雪岭、纸光、像素雨夜、自定义图片和黑屏均适用。
- **系统密码退出**：在被控 Mac 按 Control + Option + Shift + Esc，Windows 按 Esc，打开本地密码窗口。正确输入当前电脑账户的系统登录密码后才能主动退出。Windows 使用账户密码，不使用 PIN；密码仅在被控电脑内验证，不发送到控制端，也不写入配置或日志。
- **Mac 启动修复**：隐私采集改为在同一等待预算内完成内容列举与启动，修复短等待提前取消的问题。开启失败时，控制端会显示原因和重试提示。
- **文档与官网**：中英文 README、功能介绍和下载入口同步到 1.0.10。Android 发行包名与证书沿用，构建号递增到 21。

## 使用方式

先在被控电脑打开“设置 → 会话安全 → 允许新连接使用隐私屏”，并允许该会话使用键鼠。两端升级到 1.0.10 后，连接时可开启隐私屏，也可在“控制中心 → 隐私屏”选择三款动效预设或导入 PNG/JPG/WebP 图片，调整亮度、动效强度与时钟。样式在被控端确认成功后按设备保存。

本地退出需验证系统登录密码；错误密码、空密码、取消或验证不可用均不会主动退出。控制端关闭隐私屏、断开连接或租约失效仍会恢复屏幕。旧版被控端保留其原有退出行为，控制端按实际能力展示说明。

Mac 原生遮罩要求 macOS 12.3 或以上。Android 为控制端，不提供手机被控能力。

## Changes

- Show an optional privacy reminder after connecting to a desktop. **Not now** lets you keep working.
- Remember **Turn on automatically for this computer** per device, also available in Control center. Turning it off uses the optional reminder instead of reopening privacy from the previous toggle state.
- Keep the controlled screen's privacy status and exit shortcut visible across Snow Ridge, Paper Light, Pixel Rain, custom pictures and the black-screen choice.
- Require the current computer account's **system login password** for local exit. Press **Control + Option + Shift + Esc** on Mac or **Esc** on Windows to open the local prompt. Windows uses the account password rather than its PIN. Verification stays on the controlled computer; the password is never sent to the controller or stored in configuration or logs.
- Let Mac privacy capture discover content and start within one total wait budget, fixing premature cancellation from the shorter waits. Failed activation now shows the controller a reason and retry guidance.
- Update both README languages, website features and downloads to 1.0.10. Keep the Android application ID and release certificate, with build number 21.

Enable privacy-screen permission on the controlled computer and allow keyboard/mouse input for the session. With both ends on 1.0.10, use the connection reminder or **Control center → Privacy screen**. Choose an animated preset or import a PNG/JPG/WebP picture; adjust brightness, motion intensity and the clock. The device's style is saved after the controlled computer confirms it was applied.

Wrong or empty passwords, cancellation and unavailable verification keep privacy on. Turning it off from the controller, disconnecting or losing the lease still restores the screen. Older endpoints retain their version's exit behavior, with capability-aware explanations. The Mac overlay requires macOS 12.3+. Android is a controller app.

## 安装包 / Packages

| Platform | Files | Installation |
|---|---|---|
| macOS ARM64, macOS 12.3+ | DMG / ZIP | 完整 NikoDesk.app；ad-hoc 签名，无 Apple Developer ID 签名与公证。/ Complete app, ad-hoc signed without Developer ID or notarization. |
| Windows x64 | Portable EXE / ZIP | 便携运行，无需安装；当前未签名。/ Portable, no installation; unsigned. |
| Windows x64 unattended setup | Setup-validation EXE / ZIP | 安装器会注册服务；当前未签名。/ Installer registers a service; unsigned. |
| Android ARM64 | APK | 专用 NikoDesk 发行证书签名，包名 io.nikodesk.android，build 21。/ Dedicated release certificate, controller app, build 21. |

对照 `SHA256SUMS` 校验下载。更新仍需手动安装：退出旧版，替换完整应用，再重新打开。macOS 可能需要重新授予原有系统权限。

Verify downloads against `SHA256SUMS`. Updates require manual installation: quit the previous app, replace the complete application and reopen it. macOS may require its permissions to be granted again.
