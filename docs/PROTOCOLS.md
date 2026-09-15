# XVPN 协议支持规划

> **使用者：** 只要导入配置、连上即可——见 [`USER_GUIDE.zh-CN.md`](USER_GUIDE.zh-CN.md)。  
> **本文面向维护者：** 协议接入架构、参数规范化坑、后续协议怎么加。

本文说明协议接入的架构、当前进度，以及后续协议的落地方案。
新增协议时请先读「接入三步」，再对照文末的协议清单。

## 一、架构：协议工厂

```
lib/protocols/
├── vpn_protocol.dart        协议枚举 + 展示信息 + 文件扩展名
├── parsed_profile.dart      ParsedProfile：协议无关的解析结果
├── protocol_adapter.dart    VpnProtocolAdapter 接口 + VpnProtocolFactory 工厂
├── wireguard_conf.dart      WireGuard .conf 解析器 + WireGuardProfile
├── wireguard_adapter.dart   WireGuard 适配器
├── openvpn_conf.dart        OpenVPN .ovpn 解析器 + OpenVpnProfile
├── openvpn_adapter.dart     OpenVPN 适配器
├── hysteria2_conf.dart      Hysteria2 解析器（链接 / YAML / JSON）+ Hysteria2Profile
├── hysteria2_adapter.dart   Hysteria2 适配器
├── shadowsocks_conf.dart    Shadowsocks 解析器（ss:// / JSON）+ ShadowsocksProfile
├── shadowsocks_adapter.dart Shadowsocks 适配器
├── v2ray_conf.dart          VMess / VLESS / Trojan 共用解析（分享链接 / JSON）
└── v2ray_adapter.dart       三个薄适配器，传输层与 TLS 只实现一次
```

设计要点：

* **界面与内核配置生成都不认识具体协议**。前者只读 `ParsedProfile` 的展示
  字段（`serverDisplay` / `addressDisplay` / `details`），后者只调用
  `VpnProtocolAdapter.buildEndpoint()`。因此新增协议不会牵动 UI 与分流逻辑。
* **片段该进 `endpoints` 还是 `outbounds`，由适配器自己声明**。sing-box 1.11
  起把协议分成两类：自带隧道地址的（WireGuard / OpenVPN）是 `endpoints`，
  流式代理（Hysteria2）是普通 `outbounds`。放错位置内核直接拒绝启动，
  因此这件事由 `VpnProtocolAdapter.placement` 表达，配置生成器不按协议名分支。
* **按内容识别协议，不靠扩展名**。`.conf` 既可能是 WireGuard 也可能是
  OpenVPN，所以每个适配器都要用指令特征（`[Interface]` + `PrivateKey`、
  内联证书块、`remote` 等）判断，而不是看后缀。
* **分流与 DNS 策略是全局的**。无论什么协议，`geosite-cn` / `geoip-cn`
  直连、其余走隧道、DNS 分流的逻辑完全一致，写在 `SingBoxConfigBuilder`
  里，适配器不重复实现。
* **所有协议共用同一个内核**（sing-box）。除 WireGuard 外不需要额外二进制，
  这大幅降低了接入成本。

## 二、接入三步

1. 在 `vpn_protocol.dart` 的 `VpnProtocol` 加一个枚举值，补上 `label`、
   `fileExtensions`，并把 `isImportable` 改为 `true`。
2. 新建 `<协议>_conf.dart`（纯文本解析，可单测）与 `<协议>_adapter.dart`
   （实现 `canParse` / `parse` / `buildEndpoint` / `placement` / `tunMtu`）。
   `placement` 决定片段进 `endpoints` 还是 `outbounds`；`tunMtu` 决定安卓端
   TUN 入站的 MTU——两者都必须显式给出，不能沿用内核默认值。
3. 把适配器注册进 `VpnProtocolFactory.adapters`。

完成后：
* 导入流程自动接受新扩展名（文件选择器的过滤列表取自注册表）；
* 「配置文件」页自动展示新协议标注与 `details` 里的字段。

## 三、已实现

| 协议 | 入口格式 | 内核映射 | 状态 |
| --- | --- | --- | --- |
| WireGuard | `wg-quick` 的 `.conf` | `endpoints[].type = wireguard` | ✅ 已用真实服务器验证 |
| OpenVPN | 客户端 `.ovpn`（含内联证书） | `endpoints[].type = openvpn-client` | ✅ 已通过官方 `sing-box check` |
| Hysteria2 | `.yaml` / `.yml`（分享链接与 sing-box 出站 JSON 也能解析） | `outbounds[].type = hysteria2` | ✅ 已通过官方 `sing-box check`（两种入站） |
| Shadowsocks | `ss://` 分享链接（SIP002 两种编码 + 旧式整串 base64）与 sing-box 出站 JSON | `outbounds[].type = shadowsocks` | ✅ 已通过官方 `sing-box check`（两种入站） |
| VMess | `vmess://`（base64 JSON）与 sing-box 出站 JSON | `outbounds[].type = vmess` | ✅ 已通过官方 `sing-box check`（两种入站） |
| VLESS | `vless://uuid@host:port?params` 与 sing-box 出站 JSON | `outbounds[].type = vless` | ✅ 已通过官方 `sing-box check`（两种入站） |
| Trojan | `trojan://password@host:port?params` 与 sing-box 出站 JSON | `outbounds[].type = trojan` | ✅ 已通过官方 `sing-box check`（两种入站） |

### OpenVPN 实现中踩到的坑（供后续参考）

这些字段名与取值都是被 `sing-box check` 拒绝后才确定的，文档不一定写得清楚：

* 端点类型是 `openvpn-client`，**不是** `openvpn`；
* `tls-auth` / `tls-crypt` 走 `tls.control_wrap`，其 `type` 用**下划线**
  （`tls_auth` / `tls_crypt`）；
* `tls.control_wrap.direction` 只接受 `server` / `client`，且仅对 `tls_auth`
  有效（OpenVPN 的 `key-direction 1` 对应 `client`）；
* TLS 模式下**不支持**顶层 `static_key` 与 `cipher`，加密套件统一写
  `data_ciphers`（老式 `cipher` 需要并入其中）。

## 三点五、参数规范化：几个会让内核直接起不来的坑

协议适配器除了「翻译字段」，还要做一层**参数规范化**。原因是这些坑的共同点：
失败信息完全面向开发者，而用户看到的是「连不上」，没有任何线索。
实现见 `lib/protocols/protocol_tuning.dart`，每条都有对应的
`test/protocol_tuning_test.dart` 用例锁定。

复核方式（内核版本以随包分发为准）：

```powershell
cd app
dart run tool/build_singbox_config.dart ..\testdata\sample.ovpn build\ovpn.json
assets/bin/sing-box.exe check -c build\ovpn.json
```

### 3.5.1 加密套件名必须是大写规范名

**实测**：`data_ciphers` / `data_ciphers_fallback` 里写小写会得到

```
FATAL initialize endpoint[0]: ClientOptions.DataChannel.Ciphers[0]
      must use a canonical OpenVPN cipher name
```

`auth` 同理（`sha256` → `SHA256` 才行）。也就是说：一份 `data-ciphers
AES-256-GCM` 的配置能用，而写成 `aes-256-gcm` 会让**内核整体启动失败**。

处置：认识的名字统一成规范写法；**不认识的名字直接剔除**而不是原样传下去——
剔除最多让协商范围变小，原样传会让内核起不来。

### 3.5.2 fallback 必须与协商列表分开

OpenVPN 2.4+ 用 `data-ciphers` 协商，`data-ciphers-fallback` 是给
「服务端只支持老套件」时的兜底。把 `cipher` 直接并进 `data_ciphers` 会让客户端
主动提议一个服务端根本不会选的套件，严格服务端会因此拒绝协商。
现在两者分别下发。

### 3.5.3 `remote-cert-tls server` 要映射成服务端证书校验

这条指令几乎必然出现在客户端配置里（主流向导都会写），含义是「只接受服务端证书」。
映射到 sing-box 是 `tls.remote_certificate_tls: "server"`。原实现把它归到
「无需翻译」的指令里丢掉了——那等于悄悄放弃了服务端身份校验，属于
「看起来能连、实际不安全」的降级。`verify-x509-name` 同样处理。

### 3.5.3b OpenVPN：MTU / 保活 / MSS

sing-box 1.14 的 `openvpn-client` 已支持这些字段，原先被静默丢进 ignored：

| `.ovpn` | 内核字段 | 作用 |
| --- | --- | --- |
| `tun-mtu N` | `mtu`（经 `[1280,1500]` 校验）+ TUN 入站同值 | 避免分片卡顿 |
| `keepalive A B` / `ping` / `ping-restart` | `ping_interval` / `ping_restart`（`"Ns"`）；`ping-restart 0` → `ping_restart_disabled` | NAT 后会话稳定 |
| `mssfix [N]` | `mss_fix`（裸指令默认 1450） | TCP 性能 |

确认导入对话框会把上述字段写回 `.ovpn`（此前只解析不下发到表单，点确认会丢掉）。

配置提示统一走 `ProfileNotice` + `ParsedProfile.unusedKeys` /
`displayDetails`：未映射指令（含 OpenVPN 的 `comp-lzo` / `dhcp-option` 等）
进「未使用字段」；有实际影响的进 `notices`；多 `remote` 只采用第一个并提示。
导入确认 / 桌面列表 / 移动端共用 `ProfileNoticesView`，不再各写一套。

### 3.5.3c 隧道 DNS 卫生

配置里声明的 DNS（常见于 WireGuard `DNS = 223.5.5.5`）**不会**再被无脑当成
隧道内解析海外域名的解析器。`223.5.5.5` / `119.29.29.29` 只适合直连侧；
经隧道去问它们会放大延迟与错误 CDN。跳过这些地址后若无其它公网 DNS，
回退到 `1.1.1.1` + `9.9.9.9`。直连侧 DNS 列表仍用同一组地址
（`localPreferenceDnsServers` / `SingBoxConfigBuilder.domesticDns`）。

### 3.5.4 WireGuard 的保活不替用户决定

原实现写的是 `peer.persistentKeepalive ?? 25`，也就是给**没有声明**保活的配置
硬塞一个 25 秒。这有两个反效果：

* 25 秒一次的握手包在移动网络上是实打实的耗电与流量，而配置作者显然不需要它
  ——否则他会写上；
* 内核自己的默认值是 0（不主动发包，靠上层流量自然维持 NAT 映射），
  这也正是 WireGuard 官方的推荐默认。

现在只在配置显式声明时才下发。配置详情会提示：长距离 / 运营商 NAT 可自行声明
`PersistentKeepalive`。

### 3.5.5 MTU 做合理性校验

低于 1280 违反 IPv6 的最小 MTU 要求，高于 1500 超出以太网帧。两者都会让隧道
时通时断且完全看不出原因。超出 `[1280, 1500]` 的值会被换成默认值 1420
（wg-quick 的默认值，也是 1500 字节以太网上不会分片的保守取值）。

### 3.5.6 AmneziaWG 配置明确告知

AmneziaWG 是 WireGuard 的非标准分支，靠 `Jc` / `Jmin` / `Jmax` / `S1` / `S2` /
`H1`~`H4` 把握手包伪装成随机数据。sing-box 的 WireGuard 端点**不支持**这些参数，
因此这类配置导入后会「看着正常但连不上」。现在识别出来并明确提示，
而不是让用户对着一个连不上的隧道猜。

### 3.5.7 Hysteria2：字段名与取值全部由内核实测定下

Hysteria2 的字段名变动频繁，而内核的 JSON 解码是**严格**的——多一个不认识的
字段就直接 FATAL，用户看到的是「连不上」。下表每一条都对应一次真实的
`sing-box check` 拒绝，用例锁在 `test/hysteria2_conf_test.dart` 与
`test/singbox_config_binary_test.dart`：

| 写法 | 内核原文 | 处置 |
| --- | --- | --- |
| 把出站片段放进 `endpoints` | `unknown endpoint type: hysteria2` | 适配器声明 `placement = outbound` |
| 完全不下发 `tls` | `TLS required` | 始终下发 `tls.enabled = true` |
| `tls` 里既无 `server_name` 也无 `insecure` | `missing server_name or insecure=true` | 未声明 SNI 时用服务器名兜底 |
| `server_ports` 写单端口 `"443"` | `bad port range: 443` | 归一化成区间 `"443:443"` |
| `hop_interval` 写 `30` | `missing unit in duration "30"` | 统一写成 `"30s"` |
| `obfs.type` 写了别的值 | `unknown obfs type: ...` | 只放行 `salamander` |
| 声明了混淆却没给密码 | `missing obfs password` | 导入阶段就报错 |
| 字段名写成 `obfs_password` | `json: unknown field "obfs_password"` | 解析阶段映射成内核字段名 |

另有两条与「安全降级」有关，处置方向与 OpenVPN 的加密套件**相反**：

* **证书指纹 `pinSHA256` 不合法时报错，而不是悄悄丢掉**。丢掉等于放弃用户
  显式要求的证书固定；报错只让他改一次链接。OpenVPN 的加密套件名可以剔除，
  是因为那只会让协商范围变小——两者的取舍不同。
* **声明了混淆却没有密码时报错**，不能默默把这一层伪装去掉。

`up_mbps` / `down_mbps` 值得单独说一句：声明后内核不再自动探测带宽，拥塞控制
直接按这个值跑。高丢包链路上自动探测经常估不准，手写这两个值往往就是
「能连但很慢」与「跑得动」的差别，因此解析器会读出来并在详情里展示。

`testdata/hysteria2-node.txt` 与 `testdata/hysteria2-config.yaml` 是两种入口
的示例（用 RFC 2606 保留域名，不可连通），复核方式：

```powershell
cd app
dart run tool/build_singbox_config.dart ..\testdata\hysteria2-node.txt build\hy2.json
assets/bin/sing-box.exe check -c build\hy2.json
```

### 3.5.8 实测：为什么值得引入 Hysteria2

引入第二个协议的直接起因是 WireGuard 在实际链路上丢包严重、海外站点很卡。为了
确认这不是主观感受，在同一台服务器、同一条链路上做过一次对照实测。

**方法**（要点是消除网络本身的时间漂移，否则测出来的是「当时网好不好」）：

* 两个内核**同时**运行在不同端口，逐条**交替**采样；每轮交换先后顺序；
* 先做一次预热，把握手与冷启动代价排除在统计之外；
* 记录每一次的完整耗时，看 p50 / p90 / max 与失败率——丢包的特征正是
  「均值尚可、长尾极差」，只看均值会把它掩盖掉。

**结果**（同一台自建服务器实测，WireGuard 与 Hysteria2 各 20 次内核自身端到端探测）：

| 指标 | WireGuard | Hysteria2 |
| --- | --- | --- |
| 探测成功率 | **5 / 20（75% 失败）** | 20 / 20 |
| 成功样本 p50 | 1.35 s | **0.375 s** |
| 成功样本 p90 | 2.03 s | 0.520 s |

外层再叠加一组真实站点请求（`youtube.com`，各 10 次）与吞吐（10 MB 下载，各
5 次）：

| 指标 | WireGuard | Hysteria2 |
| --- | --- | --- |
| youtube p50 / p90 | 7.34 s / 12.16 s | **2.07 s / 3.78 s** |
| youtube max | 20.0 s | 8.65 s |
| 10 MB 下载 p50 | 1.01 MB/s | 1.11 MB/s |

**结论**：差别**不在吞吐**（两者相当），而在**可靠性**——WireGuard 在这条长距离
UDP 链路上大量探测直接失败、成功的那部分延迟也高一个量级；Hysteria2 几乎没有
失败样本，延迟低且集中。这与「QUIC 自带拥塞控制与前向纠错、而 WireGuard 的
握手/数据包在丢包链路上缺乏韧性」的预期相符。

一条可复现的办法同时留在这里：用 `PersistentKeepalive` 触发握手（无需真实流量），
配合不同 `log.level` 观察内核实际写了什么，见
`test/wireguard_handshake_e2e_test.dart`。

## 四、后续协议

### 4.1 Shadowsocks（已实现）

入口为 `ss://` 分享链接与 sing-box 出站 JSON，映射到 `outbounds[].type = shadowsocks`。
实现要点：

* SIP002 的 userinfo 既可能是百分号编码的 `method:password`，也可能是
  URL-safe base64；还有旧客户端把整段 `method:password@host:port` 做成一坨
  base64。三种都要认，认错一种用户只会看到「连不上」。
* 加密方法必须是内核认识的小写名字；不认识的在解析阶段拒绝，而不是让内核 FATAL。
* `plugin` query 拆成内核的 `plugin` + `plugin_opts`。随包内核认识
  `obfs-local` 与 `v2ray-plugin`；其它插件会 warn。
* 不做 Clash YAML 作为单节点入口：本项目不引入 `yaml` 包。多节点 Clash
  `proxies:` 由订阅解析器用缩进扫描处理。

### 4.2 VMess / VLESS / Trojan（已实现）

三者共用 `v2ray_conf.dart`：传输层（tcp / ws / grpc / http / httpupgrade / quic）
与 TLS（none / tls / reality）只实现一次，适配器只声明 `kind`。

* VMess：`vmess://base64(JSON)`。`aid` 既接受数字也接受字符串。
* VLESS / Trojan：query 里读 `type` / `security` / `sni` / `flow` / `path` / `host`。
  Trojan 未声明 `security` 时默认启用 TLS。Reality 缺公钥在解析阶段拒绝。
* VLESS 出站带 `packet_encoding: xudp`；`flow` 只允许空或 `xtls-rprx-vision`。
* 不做 Clash YAML：与 Shadowsocks 同一条约束；多节点走订阅入口。
* 三个协议都不独占文件扩展名（`.json` / `.txt` 已归 Shadowsocks 约定），按内容识别。

### 4.3 订阅链接（已实现）

现实中不少用户拿到的是**一条订阅地址**，而不是单份配置。本项目把订阅当成
**配置来源**，与「选文件 / 手填」并列：

1. 用户粘贴自己已有的 `http(s)` 地址，或导入多条分享链接 / Clash `proxies:` /
   sing-box `outbounds[]`；
2. 拉取时读取 `subscription-userinfo` 响应头（有则记下，没有也不失败）；
3. 每种正文拆成多条已支持协议的节点，写入配置列表；认不出的记进「跳过」；
4. 有 URL 的可以刷新。节点地区：服务器是 IP 时用 `cn-ip.bin` 判定，主机名在
   连接前保持「未判定」。若节点落在国内网段，连接页给一句说明——智能分流
   仍把境外目标送进这条隧道。

**不做的：** 不内置任何订阅 URL，不提供节点，不引入 `yaml` 包（Clash 列表用
缩进扫描）。定时后台刷新也不做：刷新是用户点的，避免在用户不知情时打出站请求。

**同一个节点出现在两份来源里仍是同一条配置。** 配置的身份是「协议 + 正文」，
而归属是一份**集合**：先导入的文件与后粘贴的订阅若含同一个节点，它同时属于
两者。记成单一归属会让另一份来源的刷新与删除算错——刷新一份订阅时把归属抢走，
删掉某个共享节点时看不见另一份来源还在用它。

**来源的身份**：有 URL 的按 URL（换个地址就是另一份来源，旧的那份不会被动）；
没有 URL 的按「名字 + 首个节点」——用同一个名字再导入同一份内容是替换，内容
变了则当成另一份来源并存。这条规则保守在**宁可多出一条来源，也不误删你的节点**。

### 4.4 Clash / sing-box 原生配置

* Clash YAML：订阅入口解析 `proxies:` 列表，映射到已支持协议的 sing-box 出站
  JSON。复杂 YAML（锚点、merge、SSR 等）跳过并说明。单节点文件仍不走 YAML。
* sing-box JSON：多出站整份配置按 `outbounds[]` 拆开；与本 App 冲突的
  `route` / `dns` 段直接丢弃——分流策略仍由本 App 掌控。

## 五、暂不支持的方向

* **桌面端的 TUN 全局接管**：当前 Windows 走系统代理，不改路由表、不需要
  管理员权限。若要做真正的全局接管（游戏、命令行工具），需要另开一条
  「TUN 接管」的工作线，与协议支持解耦。
  设置页**刻意不提供**这个选项：它需要 wintun 驱动与管理员权限，两者当前都
  不具备。原先摆着一个「TUN 虚拟网卡」选项而实际不生效，是一个安静的假承诺
  ——用户选了「接管全部程序」，实际只有认系统代理的程序走隧道，界面上完全
  看不出区别。宁可不给，也不要给一个兑现不了的。
* **自定义规则**：产品定位是零配置，因此不打算开放规则编辑。若确有需求，
  应做成「高级模式」，默认隐藏。
