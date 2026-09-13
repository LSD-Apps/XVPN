# XVPN

[![测试](https://github.com/LSD-Apps/XVPN/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/LSD-Apps/XVPN/actions/workflows/test.yml)
[![版本](https://img.shields.io/github/v/release/LSD-Apps/XVPN)](https://github.com/LSD-Apps/XVPN/releases/latest)
[![许可：GPL-3.0-or-later](https://img.shields.io/badge/license-GPL--3.0--or--later-blue)](LICENSE)

**导入一个 `.conf` 就能用的分流 VPN 客户端。**

不需要选节点、不需要填规则、不需要理解什么是 geosite——把配置文件丢进来，
剩下的交给程序：命中内置规则集的流量自动直连，其余走隧道；DNS 走两套解析，
规则集命中用直连解析器、其余走隧道内解析，并交叉校验两组答案。

| | |
| --- | --- |
| 桌面端 | Windows · Linux |
| 移动端 | Android |
| 内核 | [sing-box](https://github.com/SagerNet/sing-box) 1.14.0 |
| 界面 | Flutter，两端共用一套状态层与调色板 |
| 许可 | [GPL-3.0-or-later](LICENSE)（受内核许可约束，见下） |

<sub>[English](README.md) · 简体中文 · [隐私政策](privacy.html) · [贡献指南](CONTRIBUTING.md) · [许可](LICENSE)</sub>

## 这是什么，以及不是什么

**是**：一个配置解析与分流客户端。你把 WireGuard / OpenVPN / Hysteria2 配置交给它，
它负责把配置翻译成内核能懂的形式、决定哪些流量直连哪些走隧道、并检查
分流有没有判错。

**不是**：一个 VPN 服务。本项目**不提供**任何节点、服务器、订阅或账号，
也**不分发**加密实现本身——密码学由 sing-box 提供。

因此你需要**自备配置**（自建服务器、公司内网、或你自己购买的合规服务）。
这一点是刻意设计的，理由见 [`docs/RELEASE.md`](docs/RELEASE.md)。

## 它做了什么（以及为什么不需要配置）

| 用户以为要做的 | 实际由程序完成 |
| --- | --- |
| 挑选流量走哪条路 | 内置 `geosite-cn` + `geoip-cn` 规则集：域名与 IP 分两条路判定（两者是**并列**的两条判定依据，不是互相兜底——见 [`docs/RULES.md`](docs/RULES.md)） |
| 配置 DNS 并校验结果一致性 | 自动生成两套 DNS：规则集命中走直连解析、其余走隧道解析 |
| 理解 WireGuard / OpenVPN / Hysteria2 参数 | 解析配置并翻译成内核配置，字段全部自动映射、非法值自动纠正 |
| 每次换配置重设一遍 | 记忆多份配置，切换即重连 |

规则集随包分发，首次连接时解包到应用私有目录，之后可以「检查更新」增量刷新。

## 支持的协议

按**内容**自动识别，不靠扩展名。每个协议有约定的后缀便于区分——WireGuard `.conf`、
OpenVPN `.ovpn`、Hysteria2 `.yaml`/`.yml`——但改名的文件只要内容正确同样能导入。
新增协议只需实现一个适配器，界面与内核层都不用改。

- WireGuard（`.conf`）
- OpenVPN（`.ovpn`）
- Hysteria2（`.yaml` / `.yml`；`hysteria2://` 分享链接与 sing-box 出站 JSON 也能解析）

详见 [`docs/PROTOCOLS.md`](docs/PROTOCOLS.md)。

## 出问题的时候

能自己修的自己修，修不了的告诉你原因：

- 内核崩溃、隧道不通、进程卡住都会自动恢复——但**有次数与冷却限制**，
  节点真的下线时会快速失败，而不是无限重连。
- 2080 / 2081 被占用时会自动换端口，而不是起不来。
- 状态卡片里能看到失败归因（规则判错还是节点不通）、内核原始日志，
  以及按域名查证「这个网站到底怎么了」。

具体行为、限制与背后的**实测依据**见 [`docs/RESILIENCE.md`](docs/RESILIENCE.md)。

## 快速开始

1. 启动程序。
2. 把 `.conf` / `.ovpn` 拖进窗口（Windows），或在手机上用文件管理器
   「打开方式」选择 XVPN，也可以点「选择配置文件」或粘贴配置文本。
3. 首次连接时 Windows / Linux 会设置系统代理、Android 会请求 VPN 授权。

Windows 与 Linux 端关闭主窗口都会收进系统托盘，连接不中断（Linux 需要系统提供
StatusNotifierItem 宿主，没有的话关闭即退出）；要真正退出走托盘右键菜单的
「退出 XVPN」——退出时会还原系统代理并结束内核进程，不会留下断网的烂摊子。

> **关于接管方式**：桌面端走系统代理（免管理员权限，浏览器与绝大多数软件
> 立即生效）；安卓端走 VpnService 的 TUN（唯一可行方式）。桌面端的 TUN 需要
> wintun 驱动或提权的辅助进程与管理员权限，当前版本未内置，因此设置页**不提供**
> 该选项——详见 [`docs/PROTOCOLS.md`](docs/PROTOCOLS.md) 的「暂不支持的方向」。

### Linux 桌面端

Linux 与 Windows 走同一条路径：内核以子进程运行，只设置系统代理，
**不需要 root、不需要任何特权**。因此它同样**只接管认系统代理的程序**
（浏览器与绝大多数桌面软件）；游戏、命令行工具等要等后续的 TUN 阶段。

- **桌面环境**：目前只支持 GNOME 系（gsettings）与 KDE（kioslaverc + KIO 重载）。
  其它桌面环境（XFCE、sway、i3……）没有统一接口，程序会如实报「无法设置系统
  代理」，而不是假装成功。
- **凭据存储**：优先使用系统钥匙串（libsecret 的 `secret-tool`）。依赖缺失时
  会降级为**明文落盘**，导入表单会明确显示这件事，不会谎称已加密。
- **窗口**：X11 下与 Windows 一样是自绘无边框标题栏；Wayland 下窗口移动/缩放
  不可靠，程序会隐藏自绘按钮、改用系统装饰。

运行时依赖（多数发行版默认已装，缺失只影响对应功能，不会导致崩溃）：

| 功能 | 依赖 | Debian/Ubuntu | Fedora / Arch |
| --- | --- | --- | --- |
| 系统代理（GNOME 系） | `gsettings` | `libglib2.0-bin` | `glib2` / `glib2` |
| 系统代理（KDE） | `kwriteconfig5/6`、`dbus-send` | `kde-cli-tools`、`dbus` | `kde-cli-tools`、`dbus` |
| 凭据加密 | libsecret 的 `secret-tool` | `libsecret-tools` | `libsecret` / `libsecret` |

## 分流与检测

- **分流**：`rule_set: [geosite-cn, geoip-cn, geosite-cn-extra] → direct`，
  其余 `route.final = vpn`。域名列表负责绝大多数情况；IP 列表作用于**目标本身是
  IP** 的连接。**域名一旦不在任何域名类规则集内就必然进隧道**，IP 列表兜不住它
  ——实测与方法见 [`docs/RULES.md`](docs/RULES.md)。
- **直连白名单**：把「确实能直连、却被默认规则送进隧道」的域名显式拉出来，两类：
  国内长尾站点补充（内置，默认启用）与境外应用预置（如 Cursor，按需启用）。
  两者都不依赖解析结果，因此不受 DNS 污染影响。改动在下一次连接时生效。
- **隧道流量去向**：「分流规则」页按流量列出走隧道的目标及原因，可就地改为直连。
  误入隧道的流量不失败、不报错，只能靠这样的清单被看见。
- **反方向自动纠正**：程序原先只会把「判为直连却失败」的域名推回隧道，现在也会把
  「直连解析落在国内网段、却走了隧道」的域名拉出来——连续 2 次独立测量后改为直连，
  任何一次直连失败都会撤销。
- **DNS 跟随路由**：`dns-cn`（223.5.5.5 / 119.29.29.29，`detour: direct`）与
  `dns-remote`（配置里声明的 DNS，`detour: vpn`）分流解析，且**解析决策与路由决策
  来自同一张表**——判定直连的域名用直连解析器，判定走隧道的域名用隧道解析器。
  两者分家会让「已判定该直连」的域名被境外解析器解析出境外 CDN 地址再去直连。
- **优先级顺序**（内核按首次命中生效）：用户手工指定 → 内网地址直连 →
  程序学到/内置白名单 → 规则库 → 兜底走隧道。写成契约并有测试断言下标关系。
- **检测**：解析内核日志区分两类失败——「判为直连却失败」说明规则可能没覆盖，
  「走了隧道却失败」说明节点有问题。结论直接显示在连接页，而不是只报一句
  「连接失败」。规则覆盖情况见 [`docs/RULES.md`](docs/RULES.md)。
- **自检四条腿**：直连、隧道、直连解析、**隧道解析**。最后一条是原先的盲区——
  旧的 DNS 探针用的是命中规则集的域名，因而走直连解析器，从未验证过隧道解析器，
  而后者是所有境外站点的解析出口。现在它单独成一条探针，失败时给出
  「隧道不通 DNS」的结论（多半是节点不允许 UDP/53 出站）。
- **规则数据源**：内置 `geosite-cn` + `geoip-cn`，以及 `geosite-cn-extra`
  （由 `scripts/build-cn-domain-ruleset.ps1` 从 `felixonmars/dnsmasq-china-list`
  （WTFPL v2）编译，11 万条，**默认启用**——实测召回 40/40、误命中约 150 个境外
  域名中 0 个）。另有「推荐规则集」区块，把覆盖更全但许可有灰区的第三方规则集以
  「只给地址、不再分发」的方式提供给用户自行添加。选型与实测依据见
  [`docs/RULES.md`](docs/RULES.md)。
- **分流优先级是显式契约**：用户手工指定 → 内网地址直连 → 程序学到/内置白名单 →
  规则库 → 兜底走隧道。有测试直接断言这五个位置的下标关系，因此重排会被拦下。
- **应用直连预置**：少数境外应用（如 Cursor）的后端在国内可以直接连通，走隧道
  只是白占带宽。这类域名不可能被 `geosite-cn` 收录（它是中国站点列表），因此提供
  一份显式白名单，在「分流规则」页按应用启用。哪些域名实测可直连、哪些必须留在
  隧道里，见 [`docs/RULES.md`](docs/RULES.md) 的「应用直连预置」。

### 自动纠正：程序自己学会

内置规则库覆盖不到的长尾情况有两类，而它们都会表现为「网站打不开，用户完全
看不出原因」：

| 情况 | 后果 | 规则库能否补救 |
| --- | --- | --- |
| 判为直连的主机解析到 `geoip-cn` 内的地址、却并不真的可达（例如服务由规则集范围内的 CDN 承载） | 命中 `geoip-cn` 被判为直连 → **直接打不开** | 否，它「正确地」命中了 |
| 域名的直连解析结果与隧道解析结果不一致 | 分流判定建立在一个不可信的地址之上 | 否 |

程序能观察到这两类的共同后果：**判为直连却失败**。因此它会把这类域名记下来，
连续 3 次失败后自动改为走隧道，并以**最高优先级**注入路由规则——插在
`geosite-cn` / `geoip-cn` 之前，否则规则库会先把它判成直连。

学到的规则会持久化、会衰减、也可以被撤销：

- 只要出现过一次**直连成功**（跑出了流量），连续失败计数立即清零；成功两次则
  撤销程序学到的强制代理规则 —— 反证比猜测可靠。
- 用户手工指定的规则永远优先，且不会被程序改写。
- 「分流规则」页列出每条规则的**证据**（失败次数、原因、已走隧道
  流量），并允许逐条撤销或手工指定。

### DNS 监测与交叉校验

sing-box 的 `/connections` 快照在服务端就把 DNS 流量过滤掉了
（`metadata.OutboundType != C.TypeDNS`），所以 DNS 的表现**不会**出现在连接列表
里，只能主动探测。程序做三件事：

1. 直接向直连解析器发 UDP 查询并计时，发现问题解析器；
2. 用 Clash API 的 `/proxies/vpn/delay` 让内核**真的经隧道**解析并建连，
   拿到用户实际感受的耗时；
3. **交叉校验**：同一个域名分别用直连解析器与内核 `/dns/query` 解析，
   比较两组地址，并结合 `geoip-cn` 前缀索引判断地理归属。

| 直连答案 | 与隧道答案 | 结论 | 处置 |
| --- | --- | --- | --- |
| 在 `geoip-cn` 内 | 不同 | 双部署 | 按域名判定分流是对的，不干预 |
| 不在 `geoip-cn` 内 | 完全不同 | 答案不一致 | 强制走隧道（一次失败即纠正）——不可信的答案不能拿来分流 |
| 在 `geoip-cn` 内 | 相同 | 一致 | 无需干预 |
| 全失败 | — | 直连解析异常 | 提示检查本地解析是否正常 |

**拿不到地理信息时不下「答案不一致」结论**——宁可少一次自动纠正，也不要把正常流量
推进隧道。统计用滚动窗口中位数而不是平均值：一次 3 秒超时能把均值从 20ms
拉到 100ms 以上，中位数几乎不受影响。

### 启动自检

用固定探针分别验证「直连」与「隧道」两条腿，区分三种表现完全一样、处置方式
却相反的情况：

| 现象 | 结论 | 建议 |
| --- | --- | --- |
| 直连不通、隧道通 | 本地网络或 DNS 有问题 | 不要怪节点 |
| 直连通、隧道不通 | 节点/服务器有问题 | 改规则没有用 |
| 两条都通、个别站点不通 | 规则库覆盖问题 | 交给自动纠正 |

DNS 与自检结论都是**采样**结果，界面上都带「重测」入口，不必等下一个采样周期。

### 统计数据

- 按出站分别统计已传输字节，回答「这些流量里有多少真的走了隧道」；
- 每条连接自带的上传/下载字节由内核精确计数，不是估算；
- 分流记录的「命中规则」列会把内核的描述文本
  （`rule_set=[geosite-cn geoip-cn] => route`）归一化成可读的名字。

### 大数据量下的性能

连接数上千时界面仍要保持流畅，为此做了几处针对性处理：

- 分流记录与失败记录用**固定容量环形缓冲**（插入 O(1)）。
  原先用 `List.insert(0, x)`，每插入一条都要把已存在的 500 条整体后移一格。
- 筛选结果按「筛选条件 + 关键字 + 记录版本号」**缓存**，界面每帧读到的都是
  同一个列表实例，不再每秒全量重算。
- 已上报连接集合有容量上限且会按实际连接数**自动扩容**。
  原先超过 2000 条就整体 `clear()`，那一刻所有活连接都会被当成新连接重新上报，
  分流记录里立刻出现成片重复。
- 观测引擎**复用同一个 HttpClient**（原先每秒新建并拆除一次 TCP 连接），
  并显式防重入——慢探测不会让定时器一轮轮叠起来。
- 累计流量与连接列表分开处理：前者每秒更新，后者只在出现新连接时才构造对象。
  两千条连接里提取一条新连接是单遍、近乎无分配的。

## 两端一致性

桌面与移动的布局是分开写的（桌面侧栏 + 独立页 / 移动底部标签 + 并入设置页），
但**呈现结构必须一致**：该讲清楚的信息两端都讲，该有的操作两端都有。

[`app/test/platform_parity_test.dart`](app/test/platform_parity_test.dart) 把这条
原则写成了断言。此前靠它抓出过几处真实缺失：移动端没有删除配置的入口、
「流量接管方式」整张卡只有桌面端有、DNS 与自检的「重测」入口两端都没有
（`AppState.refreshDns` / `runSelfCheck` 写了却从未被界面调用）。

能力本身可以按平台不同——桌面是系统代理、安卓是 VpnService 的 TUN——但两端
都会把「用什么接管、有什么限制」讲清楚。

## 从源码构建

需要 Flutter 3.44+、Visual Studio（Windows 端，含「使用 C++ 的桌面开发」工作负载）、
Android SDK + NDK（安卓端）；Linux 端需要 `clang cmake ninja-build pkg-config
libgtk-3-dev liblzma-dev`。

```powershell
# 桌面端
cd app
flutter build windows

# Linux 桌面端
cd app
flutter build linux --release

# 安卓端：先编译内核库，再打包
pwsh scripts/build-libbox.ps1      # 产出 app/android/app/libs/libbox.aar
cd app; flutter build apk
```

桌面端的内核二进制随仓库分发：Windows 用 `app/assets/bin/sing-box.exe`，
Linux 用 `app/assets/bin/sing-box`（两者都是 sing-box 1.14.0，来源与许可见
[`NOTICE.md`](NOTICE.md)）。构建脚本会把它们放到可执行文件旁边。

`scripts/build-libbox.ps1` 会拉取 sing-box 源码并用 gomobile 编译出 `libbox.aar`；
编译链路上的坑（Go 工具链版本、linkname 校验、脚本编码）记在
[`docs/ANDROID.md`](docs/ANDROID.md)。

## 测试

```powershell
cd app
flutter analyze
flutter test
```

测试覆盖配置解析（WireGuard / OpenVPN / Hysteria2）、参数规范化、内核配置生成、
分流日志归因、Clash API 解析、DNS 报文编解码与交叉校验、自动纠正表、
启动自检、两端一致性、以及界面行为。

**协议相关的内核行为不是靠猜的**：`test/protocol_tuning_test.dart` 里每一条
断言都对应一次真实的 `sing-box check` 结果——例如「加密套件名必须是大写规范名，
写小写会让内核直接 FATAL」。复核方式：

```powershell
cd app
dart run tool/build_singbox_config.dart ..\testdata\sample.ovpn build\ovpn.json
assets/bin/sing-box.exe check -c build\ovpn.json
```

### 更新规则库与 `geoip-cn` 前缀索引

「分流规则」页的「检查更新」会真的从上游拉取新的 `.srs`。规则库更新后，用于 DNS 交叉
校验的 `geoip-cn` 前缀索引需要一并重新生成（它是从 `geoip-cn.srs` 派生的）：

```powershell
pwsh scripts/build-cn-ip-index.ps1
```

## 目录

```
app/lib/
  core/          内核接入：sing-box 进程（Windows）、libbox（Android）、
                 观测引擎、Clash API 解析、DNS 客户端与监测、`geoip-cn` 前缀索引、
                 自动纠正表、启动自检、内核日志归因、规则集、系统代理
  protocols/     协议工厂：按内容识别协议，解析成统一的 ParsedProfile，
                 并把参数规范化成内核认可的写法
  screens/       五个页面（连接 / 分流记录 / 配置文件 / 分流规则 / 设置）+ 导入流程
  widgets/       公共组件与自绘标题栏、连接圆环、自动纠正管理卡片
  theme.dart     双主题调色板（暗色 / 亮色），界面只通过 XV.* 取色
  version.dart   版本号唯一来源（构建期注入，与 pubspec 同步）
app/tool/        开发工具：生成内核配置、校验配置、生成 `geoip-cn` 前缀索引
app/windows/     自绘无边框窗口、托盘、系统代理接管与还原
app/linux/       自绘无边框窗口（Wayland 回退）、窗口通道与系统托盘
                 （libayatana-appindicator3，运行期 dlopen，装不到就没有托盘）；
                 packaging/ 下为 .desktop 与 hicolor 图标
app/android/     VpnService 实现、VpnService 与 libbox 的桥接
design/          品牌资源与界面原型
docs/            协议、规则、自愈与观测、安卓接入、发布与平台合规、上架材料
scripts/         内核编译脚本、`geoip-cn` 前缀索引生成脚本
testdata/        用于测试的样例配置
```

## 实现要点

- **一套界面，两种布局**：以 900px 为界切换桌面侧栏与移动底部标签栏。
  桌面端的标题栏由 Flutter 自绘（去掉系统标题栏后与侧栏连成一体），
  运行计时、主题切换都在这一条上。
- **两端同一份观测代码**：Windows 读子进程日志，Android 读 `libbox` 回调，
  但连接观测、速率统计、失败归因、DNS 监测、启动自检全部走 `CoreMonitor`
  这一份实现——此前是两端各写一份，已经出现过「一端修好、另一端还是旧行为」。
- **控件高度有单一来源**：`XvControlMetrics.height`。此前「手工指定」那一行
  的输入框、按钮、分段选择器分别是 41 / 32 / 36 三种高度——41 也不是谁定的，
  而是 `TextField` 在当前字号下的自然高度，也就是根本没决定过。
- **协议适配器只做翻译，规范化单独一层**：加密套件名、摘要名、MTU 这些参数
  写错会让内核**直接启动失败**，而错误信息完全面向开发者。因此
  `protocol_tuning.dart` 负责把参数归一化成内核认可的写法，认不出的直接剔除。
- **主题可切换**：跟随系统 / 亮色 / 深色，标题栏按钮与设置页共用同一份状态。

## 许可

本项目采用 **GPL-3.0-or-later**。

这不是偏好，而是被依赖关系决定的：本项目把 [sing-box](https://github.com/SagerNet/sing-box)
（GPL-3.0-or-later）作为内核，安卓端更以原生库的形式**链接进同一个进程**，
构成 GPL 意义上的组合作品。

- 完整许可见 [`LICENSE`](LICENSE)；
- 第三方组件、上游附加条款（sing-box 对名称使用有限制）、
  规则库来源与出口管制提示见 [`NOTICE.md`](NOTICE.md)；
- 内核二进制静态链接的 Go 模块许可聚合见
  [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md)。

再分发时请保留 `LICENSE`、`NOTICE.md` 与 `THIRD-PARTY-NOTICES.md`，提供
sing-box 对应版本的源码获取方式，并且**不要**使用 sing-box 的名称或暗示与
上游有关联。

## 使用须知

本项目是**客户端工具**，不提供任何节点或服务。请自行确保你使用的配置
与服务符合你所在司法辖区的法律法规。发布工程、平台合规与发布前清单见
[`docs/RELEASE.md`](docs/RELEASE.md)。

- **隐私**：不收集任何数据。完整说明见 [`PRIVACY.md`](PRIVACY.md)。
- **安全**：漏洞请通过 GitHub 私密渠道报告，范围与支持版本见 [`SECURITY.md`](SECURITY.md)。
- **更新日志**：见 [`CHANGELOG.md`](CHANGELOG.md)。
- **贡献**：见 [`CONTRIBUTING.md`](CONTRIBUTING.md)。
- **上架材料**（Google Play 的 VpnService 声明、Data safety 答案等）：
  见 [`docs/STORE_LISTING.md`](docs/STORE_LISTING.md)。

## 背景调研

最初的技术可行性调研保留在 [`docs/RESEARCH.md`](docs/RESEARCH.md)：
为什么不能用现成的 WireGuard 插件做分流、为什么最终选择 sing-box 作为内核。
