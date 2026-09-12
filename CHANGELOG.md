# 更新日志 · Changelog

本文件记录 XVPN 的每个公开版本。格式遵循
[Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循
[语义化版本](https://semver.org/lang/zh-CN/)。

> 版本号的**唯一来源**是 [`app/pubspec.yaml`](app/pubspec.yaml) 的 `version:`
> （去掉 `+build` 后缀）。发布 tag 必须与它一致，否则发布流水线会直接失败——
> 见 [`.github/workflows/release.yml`](.github/workflows/release.yml)。

## [未发布]

## [1.0.0] - 2026-09-12

首个公开版本。仓库自 2026-09-10 起开发，因此本节描述的是**当前真实落地的功能
集**，而不是相对某个更早版本的增量；所列内容均来自仓库历史与实现，未做前瞻性
承诺。

### 新增

**协议与配置**
- WireGuard（`.conf`）、OpenVPN（`.ovpn`）、Hysteria2（`hysteria2://` 分享链接 /
  官方 `config.yaml` / sing-box 出站 JSON）：一律按**内容**识别，不靠扩展名。
- 参数规范化层：把加密套件名、摘要名、MTU 等归一化成内核认可的写法，认不出的
  直接剔除——这些参数写错会让内核**直接启动失败**，而错误信息只面向开发者。
- 导入路径：拖拽、系统文件选择器、粘贴文本；多份配置的记忆与切换。
- 配置与凭据的本地保护：Windows 用 DPAPI、Linux 优先用系统钥匙串
  （libsecret）；钥匙串不可用时降级为明文，并在界面**如实告知**。

**分流与 DNS**
- 内置 `geosite-cn` + `geoip-cn` 规则集，域名与 IP 双重判定；规则集随包分发，
  首次连接解包到应用私有目录，可「检查更新」增量刷新。
- 双解析器 DNS：国内域名走国内 DNS，其余在隧道内解析，避免污染驱动分流。
- DNS 交叉校验：同一域名分别用国内解析器与内核 `/dns/query` 解析，比较答案集
  并用中国 IP 前缀索引判断归属，区分「国内外双部署」与「疑似投毒」。
- 自动纠正：连续「判为直连却失败」的域名会被改走隧道，并以最高优先级注入路由
  规则；一次直连成功即清零失败计数，两次成功则撤销——反证优先于猜测。

**诊断与观测**
- 失败归因区分三类：直连失败（本地网络 / DNS）、隧道失败（节点 / 服务器）、
  规则覆盖缺口；启动自检分别验证两条腿。
- 连接列表、按出站的字节统计与实时速率来自内核 Clash API（仅回环 `127.0.0.1`）。
- 自动恢复：内核崩溃 / 隧道不通 / 进程卡住时带次数与冷却限制地重启；
  2080 / 2081 端口被占用时自动换端口。

**平台与界面**
- **Windows** 桌面端：无边框自绘标题栏、系统托盘、系统代理接管与还原
  （免管理员权限）。
- **Android** 端：`VpnService` 提供 TUN，`libbox` 作为进程内原生库。
- **Linux** 桌面端：与 Windows 相同的「子进程内核 + 系统代理」模型，无需 root；
  桌面环境支持 GNOME 系（gsettings）与 KDE；X11 下自绘标题栏、Wayland 下回退
  系统装饰。
- 一套状态层、两种布局：以 900px 为界切换桌面侧栏与移动底部标签；两端呈现结构
  由 `app/test/platform_parity_test.dart` 的断言守住。

### 安全与合规

- 采用 **GPL-3.0-or-later**：受内置内核
  [sing-box](https://github.com/SagerNet/sing-box)（GPL-3.0-or-later，`v1.14.0`）
  约束——Android 端以原生库形式把它链接进同一进程，构成 GPL 意义上的组合作品。
- 第三方声明见 [`NOTICE.md`](NOTICE.md)：sing-box（含上游「不得暗示关联」附加
  条款与对应源码获取方式）、GPL-3.0-or-later 的规则库、Dart/Flutter 依赖、
  字体图标、出口管制提示；内核静态内嵌的 Go 依赖许可由
  [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md) 聚合列出（sing-box `v1.14.0`
  下 111 个模块，含许可标识与全文）。
- 发布产物**随附许可证**：Windows / Linux 压缩包根含 `LICENSE`、`NOTICE.md` 与
  `THIRD-PARTY-NOTICES.md`，Android APK 内含 `assets/licenses/` 下的同名文件。
- 应用内**设置页「关于 → 开源许可」**可读上述三份文本与 Flutter 生成的
  `NOTICES.Z`，无需离开应用。
- 隐私政策 [`PRIVACY.md`](PRIVACY.md) 逐项列出本地数据与应用会发起的全部网络
  连接；应用不集成任何分析、广告或崩溃上报 SDK，也不运营后端。
- 新增 [`SECURITY.md`](SECURITY.md)（私密漏洞报告渠道）、本文件与
  [`CODE_OF_CONDUCT.md`](CODE_OF_CONDUCT.md)。

### 已知限制

- 桌面端只接管**认系统代理**的程序：浏览器与多数桌面软件生效，游戏与命令行
  工具不生效。桌面端 TUN 需要 wintun 驱动或提权辅助进程，当前版本未内置，
  设置页**刻意不提供**该选项，而不是给一个拨了没反应的开关。
- 尚无 iOS 工程。

[未发布]: https://github.com/LSD-Apps/XVPN/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/LSD-Apps/XVPN/releases/tag/v1.0.0
