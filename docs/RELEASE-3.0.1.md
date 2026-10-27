# NikoDesk 3.0.1+29 — Windows 安装程序修复 / Windows installer fix

[下载 v3.0.1 / Download](https://github.com/baogutang/nikodesk/releases/tag/v3.0.1)

## 本次更新

- **Windows 安装程序能打开了。**3.0.0 的 `NikoDesk-windows-x64-setup.exe` 会停在“Cannot create installer directory. Check disk space and permissions.”，和磁盘空间、权限无关：它逐级检查安装目录的上级文件夹，而 Windows 对 `C:\` 这样的盘符根目录可能回答“拒绝访问”，不是“已存在”（取决于 Windows 版本和账户，普通账户常见）。3.0.1 把已存在的文件夹当作存在处理。
- Windows 构建现在也在 Windows 上运行安装程序自己的测试，包括在真实的“本地应用数据”文件夹下解压一次。

Mac、iPad 和 Android 版和 3.0.0 相同，只是版本号变了。

## 已知限制

- Windows 安装版和后台服务的其余步骤（安装助手、管理员确认、开机启动、远程操作锁屏和登录界面、开始菜单入口、“设置 → 应用”卸载）还没有在真机上走完。遇到问题请截下安装助手的提示。
- 3.0.0 的其他已知限制仍然有效，见 [3.0.0 版本说明](RELEASE-3.0.0.md)。

## Changes

- **The Windows installer opens.** 3.0.0's `NikoDesk-windows-x64-setup.exe` stopped at "Cannot create installer directory. Check disk space and permissions." Space and permissions were not the cause: it checks each folder above the install folder, and for a drive root such as `C:\` Windows can answer "access denied" instead of "already exists" (it depends on the Windows version and the account; common for standard accounts). 3.0.1 treats an existing folder as existing.
- The Windows build now also runs the installer's own tests on Windows, including one extraction under the real local application data folder.

The Mac, iPad and Android apps are the same as 3.0.0 apart from the version number.

## Known limitations

- The rest of the Windows installer and its background service (the assistant, the administrator prompt, startup with Windows, remote control of the lock and sign-in screens, the Start menu entry, uninstalling from Settings > Apps) has not been run through on a real machine yet. If something goes wrong, take a screenshot of the assistant's message.
- 3.0.0's other limitations still apply; see the [3.0.0 notes](RELEASE-3.0.0.md).

## 安装包 / Packages

| Platform | Files | Installation |
|---|---|---|
| macOS ARM64, macOS 12.3+ | DMG / ZIP | 完整 NikoDesk.app。固定 NikoDesk 证书签名（自签名），没有 Apple Developer ID 签名和公证。/ Complete app, signed with the fixed NikoDesk certificate (self-signed), no Developer ID or notarization. |
| Windows x64 | Setup EXE | 安装版，带后台服务；未签名，SmartScreen 提示时点“更多信息 → 仍要运行”。/ Installer with the background service; unsigned, choose More info > Run anyway at SmartScreen. |
| Android ARM64 | APK | 专用 NikoDesk 发行证书，包名 io.nikodesk.android，build 29。/ Dedicated release certificate, controller app, build 29. |

对照 `SHA256SUMS` 校验下载；`SHA256SUMS.sig` 是它的发布签名，NikoDesk 的软件更新会自动核对。

Verify downloads against `SHA256SUMS`. `SHA256SUMS.sig` is its publisher signature, which NikoDesk's software update checks for you.
