<div align="center">

<img src="flutter/assets/readme-logo.png" width="360" alt="NikoDesk 徽标" />

# NikoDesk

**你的设备，你的服务器，你的远程桌面。**

基于 RustDesk 原生内核、使用自建服务的远程桌面。

[![Release](https://img.shields.io/github/v/release/baogutang/nikodesk?style=flat-square&color=CC6D45)](https://github.com/baogutang/nikodesk/releases)
[![License](https://img.shields.io/badge/%E8%AE%B8%E5%8F%AF%E8%AF%81-AGPL--3.0-8A7665?style=flat-square)](LICENCE)

[English](README.md) · **简体中文** · [官网](https://baogutang.github.io/nikodesk/zh/)

<img src="flutter/assets/readme-light.png" width="48%" alt="已遮盖连接信息的 NikoDesk 真实明亮主题工作区" /> <img src="flutter/assets/readme-dark.png" width="48%" alt="已遮盖连接信息的 NikoDesk 真实暗黑主题工作区" />

*历史构建的本地真实界面；设备 ID、密码与服务器信息已遮盖。截图展示外观，不代表远控或性能验收通过。*

</div>

## 当前状态

NikoDesk 正在活跃开发。每次推送到 `main` 都会构建全部三个平台，并替换滚动更新的 **[nightly 预发布](https://github.com/baogutang/nikodesk/releases/tag/nightly)**；`v*` 标签发布正式版本。[v1.0.0 归档](https://github.com/baogutang/nikodesk/releases/tag/v1.0.0) 是历史测试构建，其中仅 macOS ZIP 仍保留发布。

| 渠道 | macOS ARM64 | Windows x64 | Android ARM64 |
|---|---|---|---|
| [nightly](https://github.com/baogutang/nikodesk/releases/tag/nightly) | DMG + 更新 ZIP，ad-hoc 签名（无 Apple Developer ID 签名与公证；首次启动时右键 → 打开） | 便携 EXE/ZIP（免安装，可与 RustDesk 并存运行）＋用于验证安装流程的无人值守安装器。未签名：SmartScreen 会询问一次。安装器会改动系统，请先在测试机上使用。 | 控制端 APK（`io.nikodesk.android`），使用专用 NikoDesk 发行密钥签名，并对照固定证书指纹校验 |
| [v1.0.0](https://github.com/baogutang/nikodesk/releases/tag/v1.0.0) | 仅保留归档 ZIP | 已移除（拒绝启动） | 已移除（拒绝启动） |

**实际验证过的内容：** 在开发者的 Mac 上，两个相互隔离的 NikoDesk 身份经由自建 RustDesk 服务器中继运行过真实会话——带视频的密码认证、双向文件传输（经 SHA-256 校验）、含重放拒绝的 TOTP 双重验证、两端的会话审计记录、远程终端（请求 → 本机批准 → 命令输出）、端口隧道（数据经隧道验证）、画质模式（可测量的码率/帧率变化）。这些都是同机、同用户会话：跨设备、跨操作系统、Windows 与 Android 真机验收仍待完成，未测试的组合保持不作宣称。

**实现范围：** 所有规划能力均已在源码中实现——覆盖 macOS、Windows 与 Android 的无人值守、网络唤醒、隐私屏、虚拟屏、终端、摄像头、隧道、语音、双重验证、会话记录与诊断。源码实现与包检查不能替代逐设备验收。

## NikoDesk 增加了什么

**基础**

- **私服优先**：ID 服务器、中继服务器与服务器公钥都由你配置。未配置时注册保持停止；NikoDesk 构建禁用上游公共注册服务回退。
- **隔离身份**：独立的应用 ID、配置、IPC 命名空间与设备密钥。已安装的 RustDesk 不受影响，可在旁正常使用。
- **设备工作区**：别名、分组、收藏、搜索、来自真实服务器查询的在线状态、再次连接控制，以及按服务器保存的会话记录（各保留最近 200 条）。
- **连接前输入密码**：连接入口要求输入远端密码；保存的凭据按服务器范围存入系统安全存储，绝不写入明文文件。
- **双重验证**：TOTP 采用持久化、带文件锁的重放计数器；已用验证码跨重启仍被拒绝，记录损坏时禁用登录而不是降级放行。

**会话**

- **原生内核**：保留 RustDesk 的采集、编解码、输入、文件传输、剪贴板与多屏路径。画质模式（办公 / 流畅 / 弱网）改变被控端实际发送的内容。
- **连接反馈与诊断**：逐连接展示进度、中继路由与解码统计——是注明来源的观测，不是延迟承诺。
- **扩展能力默认全部关闭**：远程终端、端口隧道、摄像头与语音（含接收方发起的通话）各自需要本机对应的能力策略，并需被控端连接管理器批准；批准可在会话中途撤回。

**被控端功能**

- **无人值守（Windows）**：单文件安装器、带恢复的服务生命周期、机器级权限（虚拟屏、断开时锁定、隐私屏、远程重启）默认关闭，以及密码轮换。nightly 中用于验证安装流程的安装器面向测试机。
- **隐私屏与虚拟屏**：macOS 采用基于 gamma 的黑屏；Windows 使用上游签名的 Amyuni 显示驱动，随包捆绑并按字节固定。
- **网络唤醒**：可直接唤醒白名单内的机器；主控端位于远端时，可经授权的隧道代理唤醒。
- **断开时锁定**与**远程重启**，各自受权限门禁控制。

明暗主题可跟随系统或按你的选择；界面提供英语与简体中文。扩展能力尚待真实跨设备验收；Android 的部分蓝牙组合不受支持；未测量的行为不作宣称。

## 快速开始

1. 从 **[nightly 预发布](https://github.com/baogutang/nikodesk/releases/tag/nightly)** 下载，并对照其 `SHA256SUMS` 校验。macOS DMG 安装完整的 `NikoDesk.app`（ad-hoc 签名：首次启动时右键 → 打开）。Windows 便携 EXE 可与现有 RustDesk 并存运行；Android 在此前任意 nightly 之上覆盖安装已签名 APK。
2. 在 **设置 → 私有服务器** 中配置自己的 [RustDesk Server OSS](https://github.com/rustdesk/rustdesk-server)：ID 服务器、中继与**服务器公钥**。服务器私钥只保留在服务端。
3. 另一端使用相同服务器与公钥。分别确认服务可达、本机注册，再通过真实会话验证密码认证；三者证明的是不同事情。
4. Mac 作为被控端时，通过 macOS 系统设置授予用于采集的屏幕录制权限、用于远端输入的辅助功能权限。接受会话前逐项审核会话权限；各扩展能力仍会单独请求批准。

## 网络与升级

注册与中继使用你配置的服务。认证后的点对点会话还会访问协商得到的对端地址，更新检查与下载会访问 GitHub 的 API 和产物域名。“私服模式”不等于所有网络请求都只到 NAS。

修订后的 macOS 更新流程会核对发布摘要、校验并暂存应用归档，再打开文件位置供你**手动安装**，不会自动覆盖已安装应用。v1.0.0 不包含此修复。确认新版本可用前保留旧应用。Windows 与 Android 尚无已验证的应用内安装流程。

SHA256 用于对照发布摘要检查文件一致性，不证明发布者身份，也不能替代可信的平台签名。

## 从源码构建

必须先构建原生内核，再构建 Flutter。macOS ARM64 需要按 [构建工作流](.github/workflows/release.yml) 准备固定的 Rust、Flutter、Xcode 与 vcpkg 原生依赖，并将 `VCPKG_ROOT` 指向准备好的目录。建议使用项目专用工具链，不修改全局 SDK。

```bash
git clone --recurse-submodules https://github.com/baogutang/nikodesk.git
cd nikodesk
cargo build --locked --lib --release \
  --features flutter,hwcodec,unix-file-copy-paste,screencapturekit,nikodesk
cp target/release/liblibrustdesk.dylib target/release/librustdesk.dylib
cd flutter
flutter pub get
FLUTTER_XCODE_ARCHS=arm64 FLUTTER_XCODE_ONLY_ACTIVE_ARCH=YES \
  flutter build macos --release --dart-define=NIKODESK=true
```

产物位于 `flutter/build/macos/Build/Products/Release/NikoDesk.app`，打包与签名另行执行。工作流固定 Rust 1.88.0、Flutter 3.24.5 和 vcpkg 依赖。公开脚本支持审查与自行构建，但尚未证明产物逐字节可复现。Windows、Android 需要各自原生工具链与运行验证。

## 安全与验证边界

- 沿用上游加密与认证。服务器公钥不是远控密码；设备私钥与服务器私钥分别属于客户端、服务端，不能相互复制。
- 会话确认与权限开关需要在真实被控平台验证。按实际需求审核能力，不为方便一次授予全部权限。
- macOS 产物为本地 ad-hoc 签名，无 Apple Developer ID 签名或公证。Android nightly APK 使用专用 NikoDesk 发行密钥签名；真机安装与升级仍未验证。Windows 产物未签名。
- 跨设备远控、文件与剪贴板、撤权以及性能对比都是独立验收项。未测量的速度和延迟提升不作承诺。

## 项目与许可

- [官网](https://baogutang.github.io/nikodesk/zh/) · [问题反馈](https://github.com/baogutang/nikodesk/issues) · [发布归档](https://github.com/baogutang/nikodesk/releases)
- [保留的上游 README](docs/README_RUSTDESK_UPSTREAM.md)

NikoDesk 是基于 [RustDesk](https://github.com/rustdesk/rustdesk) 提交 `e9ddbd8f`（1.5.0-pre）的独立下游，保留其原生远控内核与上游版权声明。本项目与 RustDesk 官方无从属或背书关系。

[AGPL-3.0](LICENCE)。分发与修改须遵循完整许可条款，包括对应源码提供义务。
