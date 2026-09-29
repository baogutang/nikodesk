<div align="center">

<img src="flutter/assets/readme-logo.png" width="360" alt="NikoDesk logo" />

# NikoDesk

**你的服务器，你的密钥，你的桌面。** —— 基于 RustDesk 内核、私有优先的自托管远程桌面。

[![Release](https://img.shields.io/github/v/release/baogutang/nikodesk?style=flat-square&color=6C4CF1)](https://github.com/baogutang/nikodesk/releases)
[![Platforms](https://img.shields.io/badge/%E5%B9%B3%E5%8F%B0-macOS%20%7C%20Windows%20%7C%20Android-4C7CFF?style=flat-square)](https://github.com/baogutang/nikodesk/releases)
[![License](https://img.shields.io/badge/%E8%AE%B8%E5%8F%AF%E8%AF%81-AGPL--3.0-8E6CFF?style=flat-square)](LICENSE)
[![Stars](https://img.shields.io/github/stars/baogutang/nikodesk?style=flat-square&color=FFB020)](https://github.com/baogutang/nikodesk/stargazers)

[English](README.md) · **简体中文** · [官网](https://baogutang.github.io/nikodesk/)

<img src="flutter/assets/readme-light.png" width="48%" alt="NikoDesk 明亮主题" /> <img src="flutter/assets/readme-dark.png" width="48%" alt="NikoDesk 暗黑主题" />

*明亮（渐变毛玻璃）与暗黑（暗夜控制台）双主题，一个应用全都有。*

</div>

---

## 为什么选择 NikoDesk

公有远程桌面服务把你的屏幕、键鼠和文件都经过你无法控制的服务器。NikoDesk 反转了这个模型：它**只连接你自己配置的 ID/中继服务器**（比如部署在你自己 NAS 或 VPS 上的 [rustdesk-server](https://github.com/rustdesk/rustdesk-server)），并且**拒绝回退任何公共服务器**。会话内容点对点端到端加密，你的服务器只负责撮合握手。

| | NikoDesk | 常见 SaaS 远控 |
|---|---|---|
| 信令路径 | 仅你的私服 | 厂商云 |
| 公共服务器回退 | **设计上拒绝** | 默认开启 |
| 控制端策略 | 无密码绝不发起连接 | 免密"请求"流程 |
| 更新渠道 | GitHub Releases + SHA256 校验 | 厂商自动更新 |
| 自托管 | 填上你的 hbbs/hbbr 即可 | 不支持 |

## 功能特性

- **🔒 仅私服** —— ID 服务器/中继/公钥三要素校验；永远不回退公共协调服务。
- **🗝️ 控制端密码门控** —— 只输设备 ID 绝不发起连接；远端密码必须在控制端输入，空密码在任何握手前直接拒绝。
- **🖥️ 真实远控能力** —— 完整 RustDesk 内核：远程控制、文件传输、剪贴板、多显示器、硬件编解码（VP8/VP9/AV1/H.264/HEVC）。
- **🌗 双主题** —— 明亮"柔和渐变+毛玻璃"与暗黑"暗夜控制台"两套皮肤，默认跟随系统、可手动切换。
- **📱 设备工作台** —— 设备卡片、真实私服在线状态、别名/分组/收藏，以及诚实的"在线未知"状态。
- **🕓 会话记录** —— 本地、上限 200 条、损坏可恢复的发起历史（发起≠远端已接受，我们不说大话）。
- **🔎 诊断与权限** —— 私服注册状态、延迟/NAT、macOS 屏幕录制/辅助功能引导授权。
- **⬆️ 可验证更新** —— 应用内检查更新；从 GitHub Releases 经 HTTPS 下载，**替换任何文件前先校验 SHA256**。
- **🚫 策略性禁用** —— 终端、端口转发、摄像头、远程重启、隐私模式、屏蔽本机输入在本产品中已从核心裁掉。

## 快速开始

1. 下载最新 [Release](https://github.com/baogutang/nikodesk/releases)（`v1.0.0` 提供 macOS ARM64、Windows x64、Android ARM64）。
2. **macOS**：把 `NikoDesk.app` 放入 `/Applications`，在 **系统设置 → 隐私与安全性** 授予 *屏幕录制* 和 *辅助功能*（应用内有引导），重启一次应用。
3. 自行部署 [rustdesk-server](https://github.com/rustdesk/rustdesk-server)（hbbs/hbbr）。在 NikoDesk **设置 → 私有服务器** 里填入 ID 服务器、中继和服务器公钥。
4. 控制端（官方 RustDesk 客户端即可）配置同样的服务器，然后**带上密码**连接你的 NikoDesk 设备 ID。

> 已装官方 RustDesk？NikoDesk 使用独立的 Bundle ID、配置目录和 IPC 命名空间，两者互不干扰、可共存。

## 更新流程

设置 → **软件更新 → 检查更新**。应用仅访问 `api.github.com`（HTTPS、域名白名单），比对版本、展示更新说明、下载对应平台产物，**校验发布方公布的 SHA256** 后替换 `/Applications/NikoDesk.app` 并重启。Windows/Android 提供同版本下载链接。

## 从源码构建

```bash
git clone https://github.com/baogutang/nikodesk.git
cd nikodesk/flutter && flutter pub get
flutter build macos --release   # 需要 Rust 内核；完整工具链见 CI
```

完整可复现工具链（锁定 Rust、Flutter 3.24.5、vcpkg 原生依赖）由 [`.github/workflows/release.yml`](.github/workflows/release.yml) 在每个 tag 上全量执行。

## 安全说明

- 会话端到端加密；私服只做撮合与可选中继。
- 被控端权限逐会话生效、确认窗可见、可实时撤销（键鼠/剪贴板/文件/音频）。
- 更新器失败即关闭：没有 SHA256SUMS 或摘要不匹配 ⇒ 什么都不安装。
- 无遥测、无账号、无第三方网络调用。可联网的只有：你的服务器、`api.github.com`/`github.com`（仅更新检查）。
- 发布版为本地签名（无 Apple Developer ID/公证）。如需大范围分发请自行签名。

## 文档

- [官网](https://baogutang.github.io/nikodesk/) —— 功能、指南与下载。
- 上游原始 README 保留于 [`docs/README_RUSTDESK_UPSTREAM.md`](docs/README_RUSTDESK_UPSTREAM.md)。

## 致谢

NikoDesk 是 [RustDesk](https://github.com/rustdesk/rustdesk)（基线提交 `e9ddbd8f`，1.5.0-pre）的产品级下游，远控内核完全来自上游。感谢 RustDesk 的作者与贡献者；本地已回移上游剪贴板安全修复。

## 许可证

[AGPL-3.0](LICENSE) —— 承继 RustDesk 许可证。衍生作品必须以相同条款保持开源。
