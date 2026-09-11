# XVPN 协议支持规划

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
└── openvpn_adapter.dart     OpenVPN 适配器
```

设计要点：

* **界面与内核配置生成都不认识具体协议**。前者只读 `ParsedProfile` 的展示
  字段（`serverDisplay` / `addressDisplay` / `details`），后者只调用
  `VpnProtocolAdapter.buildEndpoint()`。因此新增协议不会牵动 UI 与分流逻辑。
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
   （实现 `canParse` / `parse` / `buildEndpoint`）。
3. 把适配器注册进 `VpnProtocolFactory.adapters`。

完成后：
* 导入流程自动接受新扩展名（文件选择器的过滤列表取自注册表）；
* 「配置文件」页自动展示新协议标注与 `details` 里的字段。

## 三、已实现

| 协议 | 入口格式 | 内核映射 | 状态 |
| --- | --- | --- | --- |
| WireGuard | `wg-quick` 的 `.conf` | `endpoints[].type = wireguard` | ✅ 已用真实服务器验证 |
| OpenVPN | 客户端 `.ovpn`（含内联证书） | `endpoints[].type = openvpn-client` | ✅ 已通过官方 `sing-box check` |

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

### 3.5.4 WireGuard 的保活不替用户决定

原实现写的是 `peer.persistentKeepalive ?? 25`，也就是给**没有声明**保活的配置
硬塞一个 25 秒。这有两个反效果：

* 25 秒一次的握手包在移动网络上是实打实的耗电与流量，而配置作者显然不需要它
  ——否则他会写上；
* 内核自己的默认值是 0（不主动发包，靠上层流量自然维持 NAT 映射），
  这也正是 WireGuard 官方的推荐默认。

现在只在配置显式声明时才下发。

### 3.5.5 MTU 做合理性校验

低于 1280 违反 IPv6 的最小 MTU 要求，高于 1500 超出以太网帧。两者都会让隧道
时通时断且完全看不出原因。超出 `[1280, 1500]` 的值会被换成默认值 1420
（wg-quick 的默认值，也是 1500 字节以太网上不会分片的保守取值）。

### 3.5.6 AmneziaWG 配置明确告知

AmneziaWG 是 WireGuard 的非标准分支，靠 `Jc` / `Jmin` / `Jmax` / `S1` / `S2` /
`H1`~`H4` 把握手包伪装成随机数据。sing-box 的 WireGuard 端点**不支持**这些参数，
因此这类配置导入后会「看着正常但连不上」。现在识别出来并明确提示，
而不是让用户对着一个连不上的隧道猜。

## 四、后续协议

### 4.1 Shadowsocks（优先级最高，成本最低）

* 入口格式：`ss://` 分享链接（两种编码：`base64(method:password)@host:port`
  与新式的 URL-safe base64 全串）、以及 SIP002 的 `ss://.../?plugin=`。
* 内核映射：`outbounds[] = { type: "shadowsocks", method, password, server,
  server_port, plugin, plugin_opts }`。
* 难点：分享链接有两种编码变体；带插件的（`obfs`、`v2ray-plugin`）需要把
  `plugin` 参数翻译成内核字段。

### 4.2 VMess / VLESS / Trojan（三者可一起做）

* VMess：`vmess://base64(JSON)`，JSON 里含 `add`/`port`/`id`/`aid`/`net`/
  `tls`/`host`/`path`/`sni`。**注意 `aid` 有的是数字有的是字符串**，
  各家客户端导出的字段类型不统一，需要容错解析。
* VLESS / Trojan：`vless://uuid@host:port?params#name`、
  `trojan://password@host:port?params#name`，参数在 query 里
  （`type`/`security`/`sni`/`flow`/`path`/`host`）。
* 内核映射：上表三个都对应 `outbounds[]` 的对应类型，加 `tls` 与
  `transport`（ws / grpc / httpupgrade）子对象。
* 难点：传输层与 TLS 参数组合较多，建议先用真实节点做参数穷举测试。

### 4.3 Hysteria 2

* 入口格式：`hysteria2://password@host:port?sni=&insecure=1#name`，或客户端
  YAML。
* 内核映射：`outbounds[] = { type: "hysteria2", server, server_port,
  password, tls: {...}, obfs: {...} }`。
* 难点：QUIC 系协议对 UDP 支持有要求；`insecure` 与 `pinSHA256` 需要正确映射。

### 4.4 订阅链接（影响面最大的一项）

现实中绝大多数用户拿到的是**一条订阅地址**，而不是配置文件。这需要：

1. 新增「订阅」这一配置来源（与「文件导入」并列，而不是塞进协议适配器）；
2. 拉取内容后按 `subscription-userinfo` 响应头解析流量用量；
3. 自动识别订阅内容格式（Base64 的分享链接列表 / Clash YAML / sing-box JSON）；
4. 支持定时更新与多节点选择——此时 `VpnProfile` 需要从「单节点」扩展为
   「节点集合 + 当前选中项」。

建议在完成 4.1～4.3 中的任意两个之后再动这一项，因为它会引入配置模型的变化。

### 4.5 Clash / sing-box 原生配置

* Clash YAML：需要引入 YAML 解析（`yaml` 包），并把 `proxies` 映射到内核出站。
* sing-box JSON：可以直接透传 `outbounds`，但要剥离与本 App 冲突的
  `route` / `dns` 段（分流策略必须由本 App 掌控）。

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
