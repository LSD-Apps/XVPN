# 技术可行性调研（立项前的原始笔记）

本文是项目开始前的调研记录，保留下来是为了说明**为什么最终没有用现成的
WireGuard 插件**，而是自己接一层规则引擎。结论部分与最终实现一致。

基于 Flutter 开发 WireGuard 客户端在技术上**完全可行**，并且已有多个成熟的开源项目和插件可供参考。对于“如何自动识别代理流量”的问题，核心在于实现 **“分流隧道”（Split Tunneling）** ，其实现方式因平台和具体需求而异。

### 📱 技术可行性：有成熟的 Flutter 插件支持

Flutter 社区已经提供了多个封装 WireGuard 核心的插件，让开发者可以专注于 UI 和业务逻辑。

*   **flutter_wireguard**：一个纯 Dart 的插件，支持 Android、Linux 和 Windows。它通过启动独立的 `:wireguard` 进程来运行 WireGuard Go 运行时，避免与 Flutter 主进程冲突。iOS 和 macOS 版本仍在开发中。
*   **wireguard_flutter**：另一个流行的插件，支持 Android、iOS、macOS、Windows 和 Linux。它允许你直接传入标准的 WireGuard `.conf` 配置字符串来启动连接。
*   **axevpn_flutter**：一个多协议插件，同时支持 OpenVPN 和 WireGuard，覆盖 Android 和 iOS。它提供了连接状态、流量统计等监听接口。
*   **wireguard_flutter_plus**：在基础功能上增强了流量统计和**分流功能**（目前支持 Android 和 Linux），允许指定哪些应用绕过或强制使用 VPN。

此外，像 **FoxWire** 这样的开源项目，已经提供了完整的 Flutter WireGuard 客户端实现，可以作为很好的学习起点。

### 🔀 如何实现自动分流（流量识别）

“自动识别”代理流量并非由客户端实时“智能判断”，而是通过**预配置的路由规则**在系统层面实现。主要有以下几种策略，你可以根据需求组合使用。

#### 策略一：基于目标 IP 段（AllowedIPs）—— 最基础的方式

这是 WireGuard 协议原生支持的分流方式，通过配置 `AllowedIPs` 字段来决定哪些目标 IP 的流量会被送入隧道。

*   **全局代理**：设置 `AllowedIPs = 0.0.0.0/0, ::/0`，所有流量走 VPN。
*   **仅代理特定 IP**：设置 `AllowedIPs = 10.8.0.0/24, 10.0.4.0/24`，只有发往这些网段的流量走 VPN。
*   **排除特定 IP（国内直连）**：设置 `AllowedIPs` 为“排除国内 IP 段后的剩余全球 IP 段”。这需要一份精细的**中国 IP 路由表**（如 `auto-add-routes` 项目提供的），通过计算得出需要代理的 IP 范围。

#### 策略二：基于应用（Per-App Proxy）—— 移动端最常用的方式

在 Android 和 iOS 上，你可以选择让哪些 App 的流量走 VPN。

*   **Android**：利用 `VpnService` 的 `addRoute` 和 `excludeRoute` API。
    *   在 **Android 13 (API 33) 及以上**，可以使用 `builder.excludeRoute()` 直接排除指定 IP 或网段。
    *   对于更低版本，通常采用 `builder.addRoute()` 反向包含需要代理的 IP 地址。
    *   一些 Flutter 插件（如 `wireguard_flutter_plus`）已经封装了此功能，可以通过 `excludedApps` 参数指定包名来绕过 VPN。
*   **iOS**：需要通过 **Network Extension** 框架，在 `NEPacketTunnelProvider` 的配置中设置 `includedRoutes` 和 `excludedRoutes` 来实现基于路由的分流。

#### 策略三：基于域名/IP/规则引擎 —— 实现“智能”分流

这是最灵活的方式，通常需要集成一个代理规则引擎（如 **sing-box** 或 **Clash Meta**）作为内核，而非直接使用 WireGuard。

*   **工作流程**：客户端捕获所有流量，交由规则引擎处理。引擎根据预设规则（如域名、IP、进程名）决定每条连接是直连（DIRECT）还是走代理（PROXY）。
*   **规则示例**：
    *   `DOMAIN-SUFFIX,google.com,PROXY`：访问 Google 相关域名走代理。
    *   `GEOIP,CN,DIRECT`：目标 IP 属于中国的直连。
    *   `PROCESS-NAME,com.example.app,PROXY`：特定应用的流量走代理。
*   **Flutter 集成**：可以使用 `flutter_sing_box` 或 `FlClash` 等项目，它们在 Flutter 层封装了规则引擎，并提供了 Dart API 来管理配置和规则。

### 💎 总结与建议

如果你计划基于 Flutter 开发 WireGuard 客户端：

1.  **快速起步**：对于 Android 平台，可以直接使用 `wireguard_flutter` 或 `wireguard_flutter_plus` 插件，它们提供了成熟的分流接口。
2.  **实现基础分流**：通过配置 `AllowedIPs` 字段，结合一份中国 IP 路由表，即可实现“国内直连、国外代理”的效果。
3.  **追求高级功能**：如果需要基于域名、应用甚至进程名的精细分流，建议考虑集成 **sing-box** 或 **Clash Meta** 作为内核，而非直接使用 WireGuard。这在 Flutter 中已有 `flutter_sing_box` 等插件可供选择。
4.  **注意平台差异**：iOS 的 VPN 开发受限于苹果的 Network Extension 框架，分流功能的实现方式与 Android 有较大不同，需要单独处理。

## 调研结论与本项目的取舍

调研指向两条路：**直接用 WireGuard 插件**，或**自接规则引擎**。

- 方案一（`AllowedIPs` + 中国 IP 路由表）实现最简单，但只能按 IP 分流：
  同一个 IP 上既有国内站点又有国外站点时无法区分，而且 IP 表需要自己维护。
  这与「傻瓜式、导入即用」的目标冲突。
- 方案二（sing-box / Clash Meta 作内核）能按域名分流，规则集可以随包分发并自动更新。

因此本项目选择 **sing-box 作为内核**，并且**没有采用现成的 Flutter 封装**：
`flutter_sing_box` / `FlClash` 都是把内核与完整客户端绑在一起，而这里需要的是
「导入 `.conf` 就用」的最小可用面，配置生成、分流策略、DNS 策略都要自己控制，
才能做到两端行为完全一致。内核接入层因此自己实现（见 `app/lib/core/`）。

iOS 未纳入范围：其分流必须走 Network Extension，
与 Android 的 `VpnService` 是不同的实现路径，需要单独处理。
