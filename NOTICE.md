# 第三方组件与许可

本项目的分发物包含第三方软件。它们各自的许可以下逐一列出。**本节不是法律意见**，
如果你要再分发，请自行核对上游的最新许可条款。

## 一、sing-box（内核）

- 上游：<https://github.com/SagerNet/sing-box>
- 版本：1.14.0
- 许可：**GPL-3.0-or-later**
- 在本项目中的形态：
  - Windows：`app/assets/bin/sing-box.exe`，作为**子进程**运行；
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

## 二、规则库

| 文件 | 来源 | 说明 |
| --- | --- | --- |
| `app/assets/rulesets/geosite-cn.srs` | [SagerNet/sing-geosite](https://github.com/SagerNet/sing-geosite) `rule-set` 分支 | 国内域名列表 |
| `app/assets/rulesets/geoip-cn.srs` | [SagerNet/sing-geoip](https://github.com/SagerNet/sing-geoip) `rule-set` 分支 | 国内 IP 段列表 |
| `app/assets/rulesets/cn-ip.bin` | 由 `geoip-cn.srs` 派生 | 见下 |

`cn-ip.bin` 是本项目从 `geoip-cn.srs` 摊平出来的中国 IP 前缀索引
（由 `app/tool/build_cn_ip_index.dart` 生成），属于对上游数据的**格式转换**，
不是独立数据源。它同样按上游规则库的条款分发。

> 上游仓库在 `rule-set` 分支下未单独提供 LICENSE 文件。数据本身源自
> 各公开的域名/IP 归属列表。**若你计划再分发或商用，建议先与上游确认条款**，
> 不要以本文件作为依据。

## 三、Dart / Flutter 依赖

以下版本取自 `app/pubspec.lock`。

| 包 | 版本 | 许可 |
| --- | --- | --- |
| `cupertino_icons` | 1.0.9 | MIT |
| `file_selector` | 1.1.0 | BSD-3-Clause |
| `file_selector_platform_interface` | 2.7.0 | BSD-3-Clause |
| `file_selector_windows` | 0.9.3+6 | BSD-3-Clause |
| `desktop_drop` | 0.8.4 | Apache-2.0 |
| `http` | 1.6.0 | BSD-3-Clause |
| `flutter_lints`（仅开发期） | 6.0.0 | BSD-3-Clause |

BSD-3-Clause 与 Apache-2.0 均与 GPL-3.0 兼容。Flutter SDK 本身为
BSD-3-Clause。

## 四、字体与图标

- **图标**：`Material Icons`，随 Flutter 分发（Apache-2.0）。
  构建时 Flutter 会做 tree-shaking，只保留实际用到的字形。
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

1. 保留 `LICENSE`（GPL-3.0-or-later 全文）与 `NOTICE`（本文件）；
2. 提供或指明 sing-box 对应版本的源码获取方式；
3. 不要使用 sing-box 的名称或暗示与上游有关联；
4. 你的修改同样必须以 GPL-3.0-or-later 提供。
