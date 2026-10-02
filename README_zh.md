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

NikoDesk 正在开发。**v1.0.0 是历史测试构建，不包含 9 月 30 日审查中的修复。** 有构建产物，不等于应用已经能运行。

最近一次通过整包检查的本地测试包为 **1.1.0+6（未发布，2026-10-01）**：Mac DMG、完整应用更新 ZIP 和 Android APK 的完整构建与包检查均通过，两端共同产品源码逐项相同。产品版本与上游内核/协议版本独立；新包尚未安装、启动或通过真机远控验收，后续源码改动不自动包含在这些包中。

| 平台 | v1.0.0 归档 | 当前验证状态（本地新包 1.1.0+6） |
|---|---|---|
| macOS ARM64 | ZIP 内是完整 `NikoDesk.app`；本地 ad-hoc 签名，无 Developer ID 签名与公证 | Rust＋Flutter 完整构建、DMG/更新 ZIP 结构与签名完整性检查通过；新包未安装、启动或远控验收。 |
| Windows x64 | ZIP 内有 EXE、DLL 与 `data`；NikoDesk 初始化门禁会拒绝启动 | 此前 build4 验证 CI 已完成 MSVC＋Flutter 整套编译，但应用身份检查未通过；第二轮固定 CI 修补仍待授权，尚无本批 Windows 验收包，Win10 启动与会话待验证。 |
| Android ARM64 | APK；NikoDesk 初始化门禁会拒绝启动 | Rust＋Gradle 完整测试 APK、独立包名、固定本地测试签名、16KB 及语音 JNI 保留检查通过；仅做控制端，Android 16 真机启动、升级、远控与通话仍待验证。 |

Windows 与 Android 的旧产物保留在 [v1.0.0 归档](https://github.com/baogutang/nikodesk/releases/tag/v1.0.0) 中供检查，暂不建议安装。新产物发布并验证后再提供下载入口。

## NikoDesk 增加了什么

- **私服配置**：填写 ID 服务器、中继和服务器公钥。未配置时保持停止；NikoDesk 构建特性禁用上游默认公共注册服务回退。
- **设备工作区**：本地别名、分组、收藏、搜索与再次连接。设备可用状态来自服务器查询，缺少有效结果时显示未知。
- **连接前输入密码**：NikoDesk 的连接入口要求远端密码，不将密码写入设备目录；对端仍逐次验证认证与加密。
- **本地历史**：保留最近 200 次连接发起记录；有记录不代表对端已接受。
- **原生会话**：保留 RustDesk 的采集、渲染、输入、文件传输、剪贴板与多屏路径。编码器是否可用取决于构建和两端能力，不能保证硬件加速。
- **诊断**：展示注明来源的会话样本。应用层 RTT、成功解码回调帧率、原生提交调用时长分别表达；它们不证明输入到画面延迟或实际呈现。未知数据保持未知。
- **明暗主题**：可跟随系统或在应用中选择。

终端、端口隧道、摄像头和语音请求默认关闭；允许提出请求不等于本机批准或资源已运行。终端、摄像头的连接与本机批准流程已有实现。build6 接入普通桌面远控会话的主控发起语音、本机手选设备与麦克风权限、Android 语音开关和关闭会话后的清理入口；准备或排队不代表通话已开始，静音不释放麦克风。以上能力均待真实跨设备验收，Android 的部分蓝牙组合暂不支持。

被控端主动发起语音、完整端口隧道、完整无人值守、隐私屏、虚拟屏、唤醒、重启和自动锁屏仍未交付。未完成的能力保持不可用；源码实现与包检查不代表已通过全面安全审计。

## macOS 快速开始

1. 阅读 [版本说明与 SHA256SUMS](https://github.com/baogutang/nikodesk/releases/tag/v1.0.0)。当前 ZIP 是历史构建，打包修复尚未发布。
2. 解压并保留完整 `NikoDesk.app`。不要从 `Contents/MacOS` 单独运行可执行文件，也不要拆开 Frameworks。GitHub Actions 下载的 artifact ZIP 还可能包着一层应用归档。
3. 在 **设置 → 私有服务器** 中填写自己的 [RustDesk Server OSS](https://github.com/rustdesk/rustdesk-server)：ID 服务器、中继与**服务器公钥**。服务器私钥只保留在服务端。
4. 另一端使用相同服务器与公钥。分别确认服务可达、本机注册，再通过真实会话验证密码认证；三者证明的是不同事情。
5. Mac 作为被控端时，通过 macOS 系统设置授予用于采集的屏幕录制权限、用于远端输入的辅助功能权限。接受会话前审核每项权限；仅做控制端时不应要求打开全部被控权限。

macOS 使用独立应用身份、配置目录与 IPC。评估时保留现有 RustDesk 安装。请保持系统安全防护；本地签名不等于公证。

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
- macOS 产物为本地 ad-hoc 签名，无 Apple Developer ID 签名或公证。Android 使用固定本地测试证书，正式发行签名与真机升级尚未验收；Windows 发行签名尚未验证。
- 跨设备远控、文件与剪贴板、撤权以及性能对比都是独立验收项。未测量的速度和延迟提升不作承诺。

## 项目与许可

- [官网](https://baogutang.github.io/nikodesk/zh/) · [问题反馈](https://github.com/baogutang/nikodesk/issues) · [发布归档](https://github.com/baogutang/nikodesk/releases)
- [保留的上游 README](docs/README_RUSTDESK_UPSTREAM.md)

NikoDesk 是基于 [RustDesk](https://github.com/rustdesk/rustdesk) 提交 `e9ddbd8f`（1.5.0-pre）的独立下游，保留其原生远控内核与上游版权声明。本项目与 RustDesk 官方无从属或背书关系。

[AGPL-3.0](LICENCE)。分发与修改须遵循完整许可条款，包括对应源码提供义务。
