# XVPN（幽门）

[![测试](https://github.com/LSD-Apps/XVPN/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/LSD-Apps/XVPN/actions/workflows/test.yml)
[![版本](https://img.shields.io/github/v/release/LSD-Apps/XVPN)](https://github.com/LSD-Apps/XVPN/releases/latest)
[![许可：GPL-3.0-or-later](https://img.shields.io/badge/license-GPL--3.0--or--later-blue)](LICENSE)

**导入一个 `.conf` 就能用的分流 VPN 客户端。**

自备 WireGuard / OpenVPN / Hysteria2 / Shadowsocks / VMess / VLESS / Trojan 配置即可：命中内置规则集的流量**直连**，
其余走**你自己的**隧道。不提供节点、不内置订阅地址、不需要账号。

| | |
| --- | --- |
| 桌面端 | Windows · Linux |
| 移动端 | Android |
| 内核 | [sing-box](https://github.com/SagerNet/sing-box) 1.14.0 |
| 界面 | Flutter（两端共用状态与调色板） |
| 许可 | [GPL-3.0-or-later](LICENSE) |

<sub>[English](README.md) · 简体中文 · [使用指南](docs/USER_GUIDE.zh-CN.md) · [隐私政策](privacy.html) · [法律声明](docs/LEGAL.md) · [文档索引](docs/README.md) · [作者](AUTHORS) · [贡献指南](CONTRIBUTING.md) · [许可](LICENSE)</sub>

> 装好之后，启动器、任务栏与系统 VPN 通知里显示的名字是**幽门**；仓库名、可执行文件名
> 与发布附件仍是 `XVPN`。两者指同一个软件——附件不改名，是为了让已装的旧版本还能找到
> 升级包。作者 LUSIDA（<https://www.lusida.net>）。

## 这是什么，以及不是什么

**是：** 配置客户端。你提供合法配置；程序翻译给内核、做分流，并区分失败原因
（本地 / 服务器 / 规则）。

**不是：** VPN 服务。不提供服务器、节点、订阅地址或账号；也不实现密码学（由 sing-box 提供）。

→ 完整教程：[`docs/USER_GUIDE.zh-CN.md`](docs/USER_GUIDE.zh-CN.md)  
→ 法律边界：[`docs/LEGAL.md`](docs/LEGAL.md)

## 上手

1. 准备合法可用的对端（自建服务器，或机构发放的客户端配置）。
2. 导出客户端配置（`.conf` / `.ovpn` / YAML 或 `ss://` / `vless://` 等分享链接）。
3. 从 [Releases](https://github.com/LSD-Apps/XVPN/releases/latest) 安装 ——
   解压到**用户目录**（`%LOCALAPPDATA%\Programs\XVPN`、`~/.local/opt/xvpn`），
   这样应用内更新不需要管理员权限。Android 的 zip 里是 APK：解压后安装即可。
4. 导入 → 连接 → 看状态与速率（界面地图与排障见使用指南）。

桌面端用**系统代理**（免管理员）；安卓用 **VpnService**。  
真正退出请用托盘「退出 XVPN」，以还原系统代理。Linux 说明与依赖见
[`docs/USER_GUIDE.zh-CN.md`](docs/USER_GUIDE.zh-CN.md)「日常使用」。
自动更新与「装在受保护目录时会请求管理员授权」见
[`docs/USER_GUIDE.zh-CN.md`](docs/USER_GUIDE.zh-CN.md)「安装」。

**协议**（按内容识别）：WireGuard、OpenVPN、Shadowsocks、VMess、VLESS、Trojan、Hysteria2 — 细节
[`docs/PROTOCOLS.md`](docs/PROTOCOLS.md)。

**多节点，来源自备**：粘贴你自己的订阅 URL，或导入分享链接列表 / Clash
`proxies:` / sing-box `outbounds[]`。同一个节点出现在两份来源里仍只保留一条。
服务器是 IP 时，节点地区用 `cn-ip.bin` 判定。

## 使用声明

这是**客户端**。你自备合法配置与服务器。本项目不提供网络接入，也不保证在你所在地
自动合法。预期用途、本仓库不受理的内容、与 GitHub 政策的对齐：
[`docs/LEGAL.md`](docs/LEGAL.md) · [English](docs/LEGAL.en.md)。

## 接着读

| 读者 | 文档 |
| --- | --- |
| 新用户 | [`docs/USER_GUIDE.zh-CN.md`](docs/USER_GUIDE.zh-CN.md) · [EN](docs/USER_GUIDE.md) |
| 规则 / DNS / 自动纠正 | [`docs/RULES.md`](docs/RULES.md) |
| 自愈与探针 | [`docs/RESILIENCE.md`](docs/RESILIENCE.md) |
| 隐私 / 安全 | [`PRIVACY.md`](PRIVACY.md) · [`SECURITY.md`](SECURITY.md) |
| 法律声明 | [`docs/LEGAL.md`](docs/LEGAL.md) · [EN](docs/LEGAL.en.md) |
| 发布与上架 | [`docs/RELEASE.md`](docs/RELEASE.md) · [`docs/STORE_LISTING.md`](docs/STORE_LISTING.md) |
| 总索引 | [`docs/README.md`](docs/README.md) |

## 构建与测试

Flutter 3.44+。Windows 需 VS「使用 C++ 的桌面开发」；安卓需 SDK + NDK；
Linux 需 `clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev`。

```powershell
cd app
flutter build windows                    # 或：flutter build linux --release
pwsh ../scripts/build-libbox.ps1         # 安卓内核 AAR，然后：
flutter build apk

flutter analyze
flutter test
```

桌面内核二进制在 `app/assets/bin/`（见 [`NOTICE.md`](NOTICE.md)）。
安卓工具链：[`docs/ANDROID.md`](docs/ANDROID.md)。
贡献约定：[`CONTRIBUTING.md`](CONTRIBUTING.md)。

更新随包 `.srs` 规则集后，请重新生成 DNS 用的 geo 索引：

```powershell
pwsh scripts/build-cn-ip-index.ps1
```

## 许可

**GPL-3.0-or-later**——安卓端将 GPL 的 sing-box **链进同一进程**，构成组合作品。
再分发请保留 `LICENSE`、[`NOTICE.md`](NOTICE.md)、
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md)，且不要使用 sing-box 名称或暗示关联。

版权 **LUSIDA** · [www.lusida.net](https://www.lusida.net) · 维护
[LSD2024](https://github.com/LSD2024) / [LSD-Apps](https://github.com/LSD-Apps)
— [`AUTHORS`](AUTHORS)。
