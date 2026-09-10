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

* **TUN 模式以外的全局接管**：当前 Windows 走系统代理，不改路由表、不需要
  管理员权限。若要做真正的全局接管（游戏、命令行工具），需要另开一条
  「TUN 接管」的工作线，与协议支持解耦。
* **自定义规则**：产品定位是零配置，因此不打算开放规则编辑。若确有需求，
  应做成「高级模式」，默认隐藏。
