# 第三方组件与许可

本项目的分发物包含第三方软件。它们各自的许可以下逐一列出。**本节不是法律意见**，
如果你要再分发，请自行核对上游的最新许可条款。

## 零、本项目的授权声明

```
XVPN（幽门） — Copyright (C) 2026 LUSIDA — https://www.lusida.net

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE.  See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with
this program.  If not, see <https://www.gnu.org/licenses/>.

SPDX-License-Identifier: GPL-3.0-or-later
```

版权与维护者身份见 [`AUTHORS`](AUTHORS)。法律与使用声明见
[`docs/LEGAL.md`](docs/LEGAL.md)。

**为什么这段声明放在这里而不是 `LICENSE` 文件里**：GitHub 的许可证识别要求
`LICENSE` 保持 GPL 正文的**原样**——只要在里面插入任何自定义段落，
识别结果就会退化成「Other」，仓库页面上就不再显示 GPL 标识。
因此版权与授权声明放在本文件，`LICENSE` 保持纯净。

**为什么是 `or-later` 而不是 `only`**：内置内核 sing-box 的许可证就是
GPL-3.0-or-later，本项目与它组合作品，采用同一版本范围最清晰，
下游也不会因为「到底能不能用 GPL-4」产生歧义。

## 一、sing-box（内核）

- 上游：<https://github.com/SagerNet/sing-box>
- 版本：1.14.0
- 许可：**GPL-3.0-or-later**
- 在本项目中的形态：
  - Windows：`app/assets/bin/sing-box.exe`，作为**子进程**运行；
  - Linux：`app/assets/bin/sing-box`（amd64），作为**子进程**运行；
    取自上游发布
    <https://github.com/SagerNet/sing-box/releases/download/v1.14.0/sing-box-1.14.0-linux-amd64.tar.gz>
    （SHA-256 `57b3da14e264b6e05e8f46aee027c02d7dd7f1594d19aa39e2f4d2b9459bbd04`）。
    该哈希已复核：仓库内这一文件与官方 tar.gz 中的 `sing-box` 成员**逐字节一致**，
    即本项目再分发的内核是**未经修改**的上游二进制。
    上游压缩包内另有 `libcronet.so`，本项目**不**分发它；
    本项目支持的协议（WireGuard / OpenVPN / Hysteria2 / Shadowsocks / VMess / VLESS / Trojan）不依赖该库。
  - Android：`app/android/app/libs/libbox.aar`，由 gomobile 编译，
    作为**进程内原生库**加载（`VpnService` 提供 TUN）。

### 为什么本项目也采用 GPL-3.0-or-later

不是出于偏好，而是被依赖关系决定的：安卓端把 sing-box 以原生库的形式
**链接进同一个进程**，这构成 GPL 意义上的组合作品，因此分发时整体必须
按 GPL 兼容的条款提供。

Windows 端虽然是以子进程方式调用（更接近「聚合」而非「链接」），但本项目
两端共用同一套 Dart 代码，没有必要为桌面端单独使用一套更严格的许可。

### 上游的附加条款（重要）

sing-box 的 LICENSE 在 GPL 正文之外还有一句：

> In addition, no derivative work may use the name or imply association
> with this application without prior consent.

因此：

- **不要**把本项目的名称或宣传语写成与 sing-box 官方有关联的样子；
- 本 README 与界面文案只做「使用了 sing-box 作为内核」的**事实陈述**，
  并明确本项目与 SagerNet 官方无隶属关系；
- 应用名、图标、品牌标识均为本项目自有，未使用 sing-box 的名称或标识。

### 对应源码的获取

GPL 要求向接收者提供对应源码。sing-box 的源码可从上述上游地址按版本获取：

```
https://github.com/SagerNet/sing-box/tree/v1.14.0
```

安卓端的 `libbox.aar` 由 `scripts/build-libbox.ps1` 从该源码编译得到，
脚本随仓库分发，可复现构建。

### 内核内嵌的上游 Go 依赖

三端的 sing-box 产物（Windows / Linux 可执行文件、Android `libbox.aar`）都是
**静态链接**的 Go 程序，除 sing-box 自身外还内嵌了它在 `go.mod` 中声明的整棵
依赖树——gVisor、quic-go、utls、tailscale、wireguard-go 等，直接与间接依赖合计
在百项量级。这些模块各自采用 BSD-3-Clause、Apache-2.0、MIT 等许可，其条款要求
在二进制再分发时**复现**版权与许可声明；只在文档里指向上游 `go.mod` 并不构成
「复现」。因此本项目生成了一份聚合声明：

- **文件**：[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md)（约 350 KB，111 个模块）；
- **分发**：Windows / Linux 压缩包根目录、Android APK 的 `assets/licenses/`；
- **可复现**：`pwsh scripts/build-third-party-notices.ps1` 会重新生成它。

> 这份聚合声明**不再**打进应用界面所读的 asset：设置页「开源许可」改为跳到
> 项目主页的许可章节，在那里按需指向全文。理由见本文件第六节——合规要求的是
> 「接收者能拿到」，而不是「长在安装包里」；把它并进应用的 Flutter assets 只会
> 让每个安装包多背 350 KB。

依赖集合不是照抄 `go.mod`，而是对**三个实际分发目标**分别执行
`go list -deps` 得到的真实链接集合的并集（构建标签
`with_gvisor,with_quic,with_openvpn,with_clash_api,with_naive_outbound`）：

| 目标 | 实际链接的依赖模块数 |
| --- | --- |
| windows/amd64（`sing-box.exe`） | 82 |
| linux/amd64（`sing-box`） | 89 |
| android/arm64（`libbox.aar`） | 102 |

因此平台专属模块（Android 的 cronet 库、Windows 的 wintun 等）不会被漏掉，
`go.mod` 里声明但实际没有包被链接的模块也不会被误列。以 sing-box v1.14.0
为准，上述并集共 **111 个模块，全部取到了许可/声明文件**（无未解析项）。

生成脚本会为每个模块输出模块路径、版本、自动识别的许可标识（MIT 39、
BSD-3-Clause 28、Apache-2.0 19、GPL-3.0 16、BSD-2-Clause 3、ISC 2，以及
CC0-1.0 / MPL-2.0 / Unlicense 各 1）与许可全文。

> **诚实边界**：许可标识由脚本按文件文本自动判定，**可能存在误判**；模块集合
> 也随构建标签与目标平台变化。我们核实的是「依赖集合 = `go list -deps` 对上述
> 三个目标求得的并集」这一关系，并未人工逐条复核每份许可文本。商用再分发请以
> 各上游模块的最新条款为准。

上游 `go.mod` 仍是模块与版本的权威来源：
<https://github.com/SagerNet/sing-box/blob/v1.14.0/go.mod>。每个模块的许可随其
源码分发，可用 `go mod download <module>@<version>` 在模块根目录取到。

## 二、规则库

| 文件 | 来源 | 说明 |
| --- | --- | --- |
| `app/assets/rulesets/geosite-cn.srs` | [SagerNet/sing-geosite](https://github.com/SagerNet/sing-geosite) `rule-set` 分支 | 域名规则集 |
| `app/assets/rulesets/geoip-cn.srs` | [SagerNet/sing-geoip](https://github.com/SagerNet/sing-geoip) `rule-set` 分支 | IP 规则集 |
| `app/assets/rulesets/geoip-cn-extra.srs` | 由 [gaoyifan/china-operator-ip](https://github.com/gaoyifan/china-operator-ip) 编译 | 国内 IP 补充（聚合 + 分运营商，IPv4 + IPv6，**默认启用**） |
| `app/assets/rulesets/cn-ip.bin` | 由 `geoip-cn.srs` 与 `geoip-cn-extra.srs` 合并派生 | CIP2 前缀索引，见下 |
| `app/assets/rulesets/cn-ip.origin.json` | 生成 `cn-ip.bin` 时写下的来源指纹 | 运行时同源校验 |
| `app/assets/rulesets/geosite-cn-extra.srs` | 由 [felixonmars/dnsmasq-china-list](https://github.com/felixonmars/dnsmasq-china-list) 编译 | 国内域名补充（**默认启用**） |

`cn-ip.bin` 是本项目从 `geoip-cn.srs` **与** `geoip-cn-extra.srs` 摊平出来的前缀索引
（CIP2：IPv4 + IPv6，由 `app/tool/build_cn_ip_index.dart` 生成），属于对上游数据的
**格式转换**，不是独立数据源。它同样按上游规则库的条款分发。`cn-ip.origin.json`
记录生成时两份 `.srs` 的指纹，规则集更新后若没重算索引，分流规则页会标明脱节。

`geoip-cn-extra.srs` 由 `scripts/build-cn-ip-ruleset.ps1` 从
`gaoyifan/china-operator-ip` 的 `china.txt` / `china6.txt` **以及**分运营商表
（chinanet / cmcc / unicom / cernet / cstnet / drpeng / googlecn，含 IPv6）
编译而来（**格式转换**）。`china.txt` 是 origin_only 聚合，不是分表并集。

> **上游许可情况（本次已核实）**：`gaoyifan/china-operator-ip` 为 **MIT**
> （Copyright (c) 2018 Yifan Gao）。与 GPL-3.0-or-later 兼容。归属信息保留在此处。
> 重跑 `scripts/build-cn-ip-ruleset.ps1` 后再跑 `scripts/build-cn-ip-index.ps1`
> 即可刷新该产物与派生索引。

`geosite-cn-extra.srs` 由 `scripts/build-cn-domain-ruleset.ps1` 从
`accelerated-domains.china.conf` 编译而来（**格式转换**，不是独立数据源）。

> **上游许可情况（本次已核实）**：`felixonmars/dnsmasq-china-list` 的
> `LICENSE` 为 **WTFPL v2**（Do What The Fuck You Want To Public License，
> 版本 2，零条件）——是本项目引入的规则数据里**最没有约束**的一份，
> 与 GPL-3.0-or-later 不存在任何兼容性问题。归属信息保留在此处。
> 重跑 `scripts/build-cn-domain-ruleset.ps1` 即可刷新该产物。

> **为什么不内置覆盖更全的 ChinaMax 系**：`MetaCubeX/meta-rules-dat` 的
> `geosite:cn` 覆盖更全（约 11.1 万条，实测零回退），但它来源是
> `blackmatrix7/ios_rule_script` 的 ChinaMax，而后者许可是 **GPL-2.0
> （非 or-later）**——GPL-2.0-only 不能单向升级到 GPL-3.0，再分发进本项目
> 存在合规灰区。因此本项目**不再分发**它，只在「规则集」页提供地址，
> 由用户自行添加（见 `RuleSetStore.suggested`）。

> **上游许可情况（本次已核实）**：`SagerNet/sing-geosite` 与 `SagerNet/sing-geoip`
> 的默认分支（`main`）根目录下**有** `LICENSE`，内容为 **GPL-3.0-or-later**
> （`Copyright (C) 2022 by nekohasekai <contact-sagernet@sekai.icu>`，且**不含**
> sing-box 那条「不得暗示关联」的附加条款）。
> 分发 `.srs` 的 `rule-set` 分支本身没有单独放 `LICENSE`，但它是同一仓库的
> 分支，受仓库根同一许可证约束。
>
> 结论：这些规则数据按 **GPL-3.0-or-later** 分发，与本项目许可一致，可以随包
> 分发。若你计划再分发或商用，仍建议以上游地址的最新条款为准。

## 三、Dart / Flutter 依赖

以下版本取自 `app/pubspec.lock`。

| 包 | 版本 | 许可 |
| --- | --- | --- |
| `cupertino_icons` | 1.0.9 | MIT |
| `file_selector` | 1.1.0 | BSD-3-Clause |
| `file_selector_platform_interface` | 2.7.0 | BSD-3-Clause |
| `file_selector_android` | 0.5.2+11 | BSD-3-Clause |
| `file_selector_linux` | 0.9.4+1 | BSD-3-Clause |
| `file_selector_windows` | 0.9.3+6 | BSD-3-Clause |
| `desktop_drop` | 0.8.4 | Apache-2.0 |
| `ffi` | 2.2.0 | BSD-3-Clause |
| `flutter_markdown_plus` | 1.0.12 | BSD-3-Clause |
| `http` | 1.6.0 | BSD-3-Clause |
| `pointycastle` | 4.0.0 | MIT |
| `url_launcher` | 6.3.2 | BSD-3-Clause |
| `url_launcher_android` | 6.3.33 | BSD-3-Clause |
| `url_launcher_linux` | 3.2.3 | BSD-3-Clause |
| `url_launcher_platform_interface` | 2.3.2 | BSD-3-Clause |
| `url_launcher_windows` | 3.1.6 | BSD-3-Clause |
| `markdown`（开发期工具 + 运行时传递依赖） | 7.3.1 | BSD-3-Clause |
| `flutter_lints`（仅开发期） | 6.0.0 | BSD-3-Clause |

`flutter_markdown_plus` 用于应用内「法律与使用声明」界面渲染 Markdown 正文，其传递
依赖为 `markdown` / `meta` / `path`（均为 BSD-3-Clause）。其中 `meta` 与 `path`
本就随 Flutter SDK 进入依赖图；`markdown` 此前只被 `tool/build_privacy_html.dart`
这个开发期工具用到、标注为「仅开发期」，现在同时是 `flutter_markdown_plus` 的
运行时传递依赖，**会进入应用产物**，因此上表不再把它标成仅开发期。

`pointycastle` 用于安卓端 `auth-user-pass` 账号密码的 AES-256-GCM 加解密（Keystore
里的包装密钥不可导出、只能经 Java 侧异步调用，因此数据本身要由 Dart 侧同步加密；
见 [`docs/RESILIENCE.md`](docs/RESILIENCE.md) 第 4.1 节）。它的传递依赖为 `convert`
（3.1.2，BSD-3-Clause）。它是纯 Dart 实现，无需平台通道。

MIT、BSD-3-Clause 与 Apache-2.0 均与 GPL-3.0 兼容。Flutter SDK 本身为
BSD-3-Clause。

> **关于 Flutter 自动生成的 `NOTICES.Z`**：Flutter 构建会把 Dart/Flutter
> 依赖（含 Flutter 引擎与上述包）的许可证合并成 `data/flutter_assets/NOTICES.Z`
> 放进桌面端 bundle（Android 端在 `flutter_assets` 内），因此这些声明**仍随
> 二进制分发**。Flutter 工具链会自动把这份聚合许可注册进 `LicenseRegistry`，
> 这一步不受本项目控制，也无需本项目维护。
>
> 本项目自身**不再**注册额外条目，也**不再**提供应用内的许可浏览界面：那套界面
> 会把 `LICENSE` / `NOTICE.md` / `THIRD-PARTY-NOTICES.md` 一起打进包供其读取
> （合计约 430 KB，其中绝大多数是没人会在手机上逐条读的聚合许可）。设置页
> 「开源许可」现在跳到项目主页的许可章节（`app/lib/core/links.dart` 的
> `kLicenseUrl`），全文随仓库与各平台发布包分发。

## 四、字体与图标

- **图标**：`Material Icons`，随 Flutter 分发（Apache-2.0）。
  构建时 Flutter 会做 tree-shaking，只保留实际用到的字形。
- **GitHub 标记**：标题栏的仓库入口使用 GitHub 官方的 octicon `mark-github-16`，
  取自 <https://github.com/primer/octicons>（**MIT**）。代码中只内联了该图标的
  路径数据（`lib/widgets/title_bar.dart` 的 `buildGitHubMarkPath`），
  未引入任何图标字体或图形依赖。该标记是 GitHub, Inc. 的商标，
  此处仅用于指向本项目的 GitHub 仓库，属指名性使用。
- **品牌标识**：`design/brand/` 下的母版与导出物为本项目自有，
  由 `scripts/export-icons.py` 从 `logo.svg` 生成。

## 五、出口管制提示

本项目**不分发**加密实现本身——密码学由 sing-box（上游开源项目）提供，
而本项目只负责配置生成与分流决策。

美国 EAR 下，实现**标准密码学**且**公开可用**的加密软件源码不受管制
（ECCN 5D002 的公开可用例外）；2021 年起，「发表通知」义务只适用于
**非标准密码学**。相关背景见
[Linux Foundation 的出口管制指引](https://bestpractices.linuxfoundation.org/regulatory/export/non-standard-cryptography.html)。

**但请注意**：公开可用例外只覆盖**源码公开**的形态。如果你只分发编译好的
二进制、而源码不公开，就不再享有该例外，需要自行评估合规。
保持本仓库源码公开同时也满足这一条件。

## 六、再分发清单

如果你要再分发本项目的构建产物，至少需要：

1. 保留 `LICENSE`（GPL-3.0-or-later 全文）、`NOTICE`（本文件）与
   `THIRD-PARTY-NOTICES.md`（内核静态依赖的聚合声明）；
2. 提供或指明 sing-box 对应版本的源码获取方式；
3. 不要使用 sing-box 的名称或暗示与上游有关联；
4. 你的修改同样必须以 GPL-3.0-or-later 提供。

> **本项目自身的分发物已做到第 1、2 条**：`.github/workflows/release.yml` 与
> `scripts/build-release.ps1` 会把 `LICENSE`、`NOTICE.md` 与
> `THIRD-PARTY-NOTICES.md` 放进 Windows / Linux 压缩包的**根目录**；Android 的
> APK 内为 `assets/licenses/` 下的同名文件（APK 本身又在发布用的 zip 里）。
> 这三份文本**不再**作为 Flutter asset 打进应用，应用内也没有许可浏览界面
> （设置页「开源许可」只把用户送到项目主页的许可章节）。附件命名契约
> （`XVPN-<ver>-windows-x64.zip` / `-linux-x64.zip` / `-android-arm64.zip` /
> `SHA256SUMS.txt`，**不直接分发裸 APK**）见
> [`docs/RELEASE.md`](docs/RELEASE.md) 5.2。
> Release 说明也会给出对应 tag 的源码地址。
