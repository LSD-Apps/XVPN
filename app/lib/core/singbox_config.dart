import 'dart:convert';

import '../models.dart';
import '../protocols/parsed_profile.dart';
import '../protocols/protocol_adapter.dart';
import '../protocols/protocol_tuning.dart';
import 'auto_route.dart';
import 'outbound_tags.dart';
import 'route_rule_sets.dart';

/// 入站方式：决定内核如何接管流量。两端能力不同，因此按平台选择。
enum InboundMode {
  /// 本地 HTTP/SOCKS 混合入站 + 系统代理设置（Windows 默认）。
  mixed,

  /// VpnService 提供 TUN，内核接管整机流量（Android 唯一可选）。
  tun,
}

/// 一个规则集在生成配置时的引用方式：内核里的标签 + 磁盘上的文件名。
///
/// 拆出这个类型，是为了让「有哪些规则集」的**决定**留在界面/状态层，而
/// 配置生成只负责把决定翻译成 sing-box 语法。默认值是两份出厂规则集，
/// 因此不传它时生成的配置与从前逐字节相同。
class RuleSetSpec {
  const RuleSetSpec({
    required this.tag,
    required this.fileName,
    this.domainRuleSet = false,
  });

  final String tag;
  final String fileName;

  /// 是否**域名类**规则集，即能否参与 DNS 直连分流。
  ///
  /// 默认 false 是刻意的：把 IP 类规则集（如 `geoip-cn`）写进 DNS 规则没有
  /// 意义（DNS 查询的是域名），自定义规则集的类型程序无从得知。只有明确知道
  /// 是域名类的才置 true。
  final bool domainRuleSet;
}

/// 把用户的 WireGuard .conf 翻译成 sing-box 配置。
///
/// 这是「傻瓜式」的核心：用户只给一份 .conf，其余全部由这里推导出来。
///
/// 三条关键设计：
///
///  1. **.conf 里的 AllowedIPs 不参与路由**。它只描述原作者想要的隧道范围，
///     而分流由内置规则库决定。出站方向统一用 0.0.0.0/0 + ::/0，否则未命中
///     规则集、需要走隧道的地址根本进不了隧道。
///
///  2. **DNS 必须分流，否则一切白搭**。如果域名解析到错误的地址，再按 IP 判定
///     就可能误判成直连。所以命中规则集的域名走直连 DNS，
///     其余域名走隧道内的解析器。
///
///  3. **默认走代理，命中规则集才直连**。命中 geosite-cn / geoip-cn 的直连，
///     其余全部走隧道——白名单式直连比黑名单式代理可靠得多。
class SingBoxConfigBuilder {
  SingBoxConfigBuilder._();

  /// 出站/端点的标签。路由规则与 route.final 都引用它。
  ///
  /// 唯一来源在 [OutboundTags]——同一个字符串还被 Clash API 解析与流量统计
  /// 用来判断「这条连接走了隧道吗」，两边必须始终是同一个值。
  static const String vpnTag = OutboundTags.vpn;

  /// 出厂规则集。这是不传 [build] 的 `ruleSets` 时的默认值。
  ///
  /// 顺序即内核 `rule_set` 列表的顺序，与历史上写死的两份保持一致，
  /// 这样「用户没有改动任何规则」时生成的配置不会发生变化。
  static const List<RuleSetSpec> defaultRuleSets = <RuleSetSpec>[
    RuleSetSpec(tag: 'geosite-cn', fileName: 'geosite-cn.srs', domainRuleSet: true),
    RuleSetSpec(tag: 'geoip-cn', fileName: 'geoip-cn.srs'),
  ];

  /// 域名类规则集的标签，供调用方在没有 spec 时回退使用。
  ///
  /// 真正参与 DNS 分流的标签由 [RuleSetSpec.domainRuleSet] 逐条声明——不要再
  /// 用「标签等于 geosite-cn」这种硬编码判断：新增一个域名类规则集时它会
  /// 静默地不参与 DNS 分流，而现象是「判定该直连的域名仍被境外解析器解析」，
  /// 极难看出原因。
  static const String domainRuleSetTag = 'geosite-cn';

  /// 入站方式。两端能力不同，因此由调用方按平台选择。
  ///
  /// 分流规则、DNS 策略、路由表**完全共用**，只有这一处不同。
  static const int defaultMixedPort = 2080;

  /// Clash API 端口：用于读取实时连接与流量，界面上的「分流记录」由此而来。
  static const int defaultClashApiPort = 2081;

  /// 直连 DNS。走直连出站，用于解析命中规则集的域名，保证拿到离用户最近的节点。
  /// 直连侧解析器。与 [localPreferenceDnsServers] 同源——隧道内海外解析不得复用。
  static const List<String> domesticDns = localPreferenceDnsServers;

  /// 兜底的外部 DNS。.conf 里没有声明时使用。
  static const String fallbackRemoteDns = '1.1.1.1';

  // ------------------------------------------------------- 已评估的性能开关
  //
  // 下面两项都评估过，结论是**不采纳**。写在这里是为了不让后来者
  // （包括未来的自己）再花一遍时间验证同样的事：
  //
  //  1. **DNS 缓存容量**（`dns.cache_capacity` / `dns.independent_cache`）。
  //     用真实内核实测：同一域名连查 6 次，不下发缓存配置是
  //     19.5 / 4.9 / 5.7 / 5.1 / 5.9 / 5.2 ms，下发 4096 容量并开启独立缓存是
  //     15.8 / 5.8 / 4.8 / 6.1 / 4.8 / 5.2 ms——**没有可测差异**，内核自身
  //     已经在缓存。显式下发只是多一份配置，因此不做。
  //
  //  2. **直连出站的 tcp_fast_open / tcp_keep_alive**。内核接受这两个字段
  //     （已用 `sing-box check` 验证），但收益仅为「直连 TCP 少一个 RTT」，
  //     且 TFO 在部分中间设备上会被丢弃；在无法实测对比的环境里引入这个
  //     不确定性不划算。要做的话，先补一条可对比的时延基线。
  //
  //  3. **嗅探（`{action: sniff}`）的时延代价**。担心过这样一件事：嗅探要读
  //     客户端发来的第一个包才能认出域名，而路由依赖这个结果，那么「客户端
  //     等服务器先开口」的协议（SSH、SMTP、部分游戏）没有包可发，嗅探只能
  //     等到超时，凭空加上几百毫秒。
  //
  //     实测否定：本机起内核 + 一个「一 accept 就发问候」的 TCP 服务，经 SOCKS5
  //     连上去量首字节耗时，6 次取样——
  //       不开嗅探     1, 1, 1, 1, 1, 3 ms
  //       开嗅探(默认) 1, 1, 1, 1, 1, 1 ms
  //       嗅探 50ms    1, 1, 2, 2, 3, 3 ms
  //     三者没有差别，说明嗅探并不阻塞出站连接的建立（它是并行嗅探、认出来
  //     之后再补上目标域名）。因此**不要**为了「提速」去调小嗅探超时——
  //     那只会让慢一点的客户端认不出域名，从而按 IP 误判分流。
  //
  // 真正有据可依的速率改动是 TUN 入站的 MTU 对齐，见 [_inbound]。

  /// 生成 sing-box 配置对象。
  ///
  /// [ruleSetDir] 是规则集（.srs）所在目录的绝对路径；sing-box 需要真实路径，
  /// 因此运行时要把资源落到磁盘上再传进来。
  ///
  /// [autoRoute] 是自动纠正表。它的规则会被插在 `geosite-cn` / `geoip-cn`
  /// **之前**，因此「学到的判断」优先于规则库——这一点是自动纠正能生效的前提：
  /// 需要纠正的恰恰是规则库判错的那一批域名。
  ///
  /// [appPresets] 已并入 [autoRoute]（见 `AutoRouteTable.setPreset`）。保留这个
  /// 说明是为了让后来者知道：**不要**在这里再插一段预置规则——两套平行机制会让
  /// 匹配、优先级、界面与 DNS 策略各自为政。
  ///
  /// 协议相关部分完全交给适配器：本方法只负责「所有协议都一样的部分」——
  /// DNS 分流、路由规则、入站与观测接口。
  static Map<String, Object?> build({
    required ParsedProfile profile,
    required SplitMode splitMode,
    required String ruleSetDir,
    InboundMode inboundMode = InboundMode.mixed,
    int mixedPort = defaultMixedPort,
    int clashApiPort = defaultClashApiPort,
    bool logSplits = true,
    AutoRouteTable? autoRoute,
    List<RuleSetSpec> ruleSets = defaultRuleSets,
    RouteRuleSetRefs? hotRouteSets,
  }) {
    final remoteDns = _pickRemoteDns(profile);
    final adapter = VpnProtocolFactory.adapterForProtocol(profile.protocol);
    final endpoint = adapter.buildEndpoint(
      profile,
      const OutboundContext(tag: vpnTag, resolverTag: 'dns-cn'),
    );

    // 片段放哪儿由适配器声明，而不是在这里按协议名分支。
    //
    // sing-box 1.11 起把协议分成两类：带隧道地址的（WireGuard / OpenVPN）是
    // `endpoints`，流式代理（Hysteria2 等）是普通 `outbounds`。放错位置内核
    // 直接拒绝启动，报 `unknown endpoint type: hysteria2`。
    final isEndpoint = adapter.placement == FragmentPlacement.endpoint;

    return <String, Object?>{
      // 日志级别由协议决定，而不是写死。
      //
      // WireGuard 的握手里程碑是 DEBUG 级的（`Verbosef` → `Logger.Debug`），
      // 一旦停在 `warn` 这些行根本不会产生——界面上的「隧道握手」就会永远停在
      // 「正在读取内核握手状态…」。因此由 [ParsedProfile.wantsDebugLogs] 声明，
      // 两端共用同一个判断，不会出现「一端有、一端没有」。
      'log': <String, Object?>{
        'level': profile.wantsDebugLogs ? 'debug' : 'warn',
        'timestamp': true,
      },
      'dns': _dns(
        profile: profile,
        remoteDns: remoteDns,
        ruleSetDir: ruleSetDir,
        splitMode: splitMode,
        autoRoute: autoRoute,
        ruleSets: ruleSets,
        hotRouteSets: hotRouteSets,
      ),
      if (isEndpoint) 'endpoints': <Object?>[endpoint],
      'inbounds': <Object?>[
        _inbound(inboundMode, mixedPort, adapter.tunMtu(profile)),
      ],
      'outbounds': <Object?>[
        // 代理类协议的出站排在最前，可读性更好；顺序不影响内核行为，
        // 路由与 final 都是按 tag 引用的。
        if (!isEndpoint) endpoint,
        // direct 出站必须带一个域解析器，否则它在 sing-box 眼里是「空出站」，
        // 直连 DNS 的 detour=direct 会被拒绝（实测报错：
        // 「detour to an empty direct outbound makes no sense」）。
        // 顺带也解决了直连出站解析域名时的解析器问题。
        <String, Object?>{
          'type': 'direct',
          'tag': OutboundTags.direct,
          'domain_resolver': <String, Object?>{'server': 'dns-cn'},
        },
      ],
      // 拉取热更新规则集所用的 HTTP 客户端。
      //
      // 它必须在这里声明、并被 `route.rule_set[].http_client` 引用：不声明会让内核
      // 退回「隐式默认客户端」，那条路径在 1.14.0 已弃用、1.16.0 移除；用旧的
      // `download_detour` 同样是弃用路径。detour 固定指向 direct，理由与
      // [AutoRouteRuleSetTags.httpClient] 上记的一致——「投递决策」不该依赖任何
      // 分流判定，更不该依赖隧道可用。
      if (_hotActive(hotRouteSets, splitMode))
        'http_clients': <Object?>[
          <String, Object?>{
            'tag': AutoRouteRuleSetTags.httpClient,
            'detour': AutoRouteRuleSetTags.httpClientDetour,
          },
        ],
      'route': _route(
        ruleSetDir: ruleSetDir,
        splitMode: splitMode,
        resolveDnsTag: remoteDns.$3,
        autoRoute: autoRoute,
        ruleSets: ruleSets,
        hotRouteSets: hotRouteSets,
      ),
      'experimental': <String, Object?>{
        // 界面上的连接列表与实时流量都从这里取，避免自己解析日志。
        'clash_api': <String, Object?>{
          'external_controller': '127.0.0.1:$clashApiPort',
        },
        if (logSplits) 'cache_file': <String, Object?>{'enabled': true},
      },
    };
  }

  /// 序列化为写盘用的 JSON 文本。
  static String encode(Map<String, Object?> config) =>
      const JsonEncoder.withIndent('  ').convert(config);

  /// 按平台选择入站。
  ///
  /// * [InboundMode.mixed]：本地 HTTP/SOCKS 混合入站，配合系统代理设置。
  ///   Windows 用这条路径——免管理员权限，开箱即用。
  /// * [InboundMode.tun]：由 VpnService 提供 TUN，内核接管整机流量。
  ///   安卓只能走这条（VpnService 的 TUN 必须在应用进程内创建）。
  static Map<String, Object?> _inbound(
    InboundMode mode,
    int mixedPort,
    int tunMtu,
  ) {
    return switch (mode) {
      InboundMode.mixed => <String, Object?>{
        'type': 'mixed',
        'tag': 'mixed-in',
        'listen': '127.0.0.1',
        'listen_port': mixedPort,
      },
      InboundMode.tun => <String, Object?>{
        'type': 'tun',
        'tag': 'tun-in',
        // TUN 自身的地址段，与用户配置里的隧道地址不冲突即可。
        'address': <String>['172.19.0.1/30'],
        'auto_route': true,
        // stack 用 mixed：TCP 走系统协议栈、UDP 走 gvisor。
        // 这是 sing-box 官方安卓客户端的默认选择，兼容性最好。
        //
        // 曾试过改成 `system` 排查「TCP 走不通」，但真机证据不支持这个改动：
        // `system` 栈不转发 UDP，而内核自身的 UDP（QUIC 等）会因此失效；换过去
        // 之后 TCP 也没有变好。上游默认值更稳妥，因此保持 `mixed`。
        'stack': 'mixed',
        // MTU 必须与隧道自身的 MTU 对齐，不能沿用内核默认的 9000。
        //
        // 内核默认 9000 是为了摊薄每包开销，但它假定出站是一条同样大的
        // 管道；而这里出站是 WireGuard（1420）或 OpenVPN（1500）。两者
        // 不一致时系统栈会按 9000 组 TCP 段，进隧道后被迫在 IP 层分片，
        // 一个大包裂成六七个 UDP 包：吞吐下降、延迟抖动，而且不报错。
        // 取值由协议适配器给出（见 VpnProtocolAdapter.tunMtu）。
        'mtu': tunMtu,
      },
    };
  }

  // ---------------------------------------------------------------- DNS

  /// 选择隧道内的解析器。
  ///
  /// 优先沿用配置里声明的第一个**适合隧道**的 IP 型 DNS；跳过
  /// [localPreferenceDnsServers]（例如 `223.5.5.5`）——那些只适合直连侧。
  /// 没有可用的就退回 1.1.1.1。返回 (地址, 是否来自配置, 标签)。
  static (String, bool, String) _pickRemoteDns(ParsedProfile profile) {
    for (final entry in profile.declaredDns) {
      final value = entry.trim();
      if (value.isEmpty) continue;
      // 只接受 IP：域名型 DNS 自己就需要先被解析，会形成循环依赖。
      if (!_looksLikeIp(value)) continue;
      // 本地偏好解析器经隧道去问海外域名：延迟与错误 CDN，体感就是卡。
      if (isLocalPreferenceDns(value)) continue;
      return (value, true, 'dns-remote');
    }
    return (fallbackRemoteDns, false, 'dns-remote');
  }

  /// 隧道解析器的**备选**列表。
  ///
  /// 为什么必须有备选：经隧道到单个公共解析器的 UDP 查询会**随机丢失**。
  /// 实测（真实节点 + sing-box 1.14.0 的 debug 日志）：
  ///
  /// ```
  /// endpoint/wireguard[vpn]: outbound packet connection to 8.8.8.8:53
  /// dns: lookup failed for www.youtube.com: context deadline exceeded   ← 10 秒后超时
  /// ```
  ///
  /// 同一时刻走**直连**解析器的域名（`vpn.example.net` → 223.5.5.5）以及走直连的
  /// 域名都正常解析。失败的共同特征是「**首次**解析该域名」——成功过的域名进了
  /// 缓存，之后再查就正常。
  ///
  /// 因此只要外部解析器是单点，一次丢包就等于一次「网站打不开」，而用户重试时
  /// 又好了，表现为时通时断。配一组备选，单点丢失时内核会换下一个再试。
  ///
  /// 选择原则：只放**独立运营**的公共解析器，避免同一家挂掉时备选一起失效。
  static const List<String> fallbackRemoteDnsServers = <String>[
    '1.1.1.1', // Cloudflare
    '9.9.9.9', // Quad9
  ];

  /// 组装隧道内解析器的完整列表：配置声明的那个（若有）排在最前，其余为备选。
  /// 去重且保序——重复标签会让内核起不来。
  static List<String> remoteDnsServers(ParsedProfile profile) {
    final (primary, fromConfig, _) = _pickRemoteDns(profile);
    final ordered = <String>[primary];
    for (final candidate in fallbackRemoteDnsServers) {
      if (!ordered.contains(candidate)) ordered.add(candidate);
    }
    // fromConfig 为 false 时 primary 本身就是兜底值，无需特殊处理。
    assert(ordered.isNotEmpty && !fromConfig || ordered.first == primary);
    return ordered;
  }

  static bool _looksLikeIp(String value) {
    if (value.contains(':')) return true; // IPv6
    final parts = value.split('.');
    if (parts.length != 4) return false;
    for (final p in parts) {
      final n = int.tryParse(p);
      if (n == null || n < 0 || n > 255) return false;
    }
    return true;
  }

  static Map<String, Object?> _dns({
    required ParsedProfile profile,
    required (String, bool, String) remoteDns,
    required String ruleSetDir,
    required SplitMode splitMode,
    AutoRouteTable? autoRoute,
    required List<RuleSetSpec> ruleSets,
    RouteRuleSetRefs? hotRouteSets,
  }) {
    final (remoteAddress, _, remoteTag) = remoteDns;
    final remoteServers = remoteDnsServers(profile);
    // 参与 DNS 直连分流的**全部**域名类规则集。
    //
    // 必须按 spec 逐条声明来取，不能写死成某一个标签：`geosite-cn-extra`
    // 同样是域名类，如果它不在这里，被它判为直连的域名仍会被**境外**解析器
    // 解析——于是拿到境外 CDN 的地址再去直连，判定对了、结果仍错。
    final domainRuleSetTags = <String>[
      for (final spec in ruleSets)
        if (spec.domainRuleSet) spec.tag,
    ];
    // 这些规则集被用户删掉/停用后，DNS 规则不能再引用：内核会因「引用了未定义
    // 的 rule_set」直接拒绝启动。没有任何域名类规则集时退回纯 final 策略。
    final hasDomainRuleSet = domainRuleSetTags.isNotEmpty;

    // DNS 决策必须跟随**路由**决策，否则两者会互相矛盾。
    //
    // 这不是锦上添花：`route.default_domain_resolver` 与 `dns.final` 都指向隧道
    // 解析器，因此任何需要内核解析的域名默认都要经隧道问一个境外解析器。于是
    // 一个「已判定该直连」的域名会被境外解析器解析出境外 CDN 的地址，再照那个
    // 地址直连——判定对了、结果仍然错。反过来，一个「因境内答案不可信而被改成
    // 走隧道」的域名也不该继续被送去境内解析器。
    //
    // 因此这里从**同一个** [AutoRouteTable] 派生，而不是另写一份条件。
    //
    // 热更新可用时改为引用规则集：DNS 与路由必须跟着**同一次**决策变化，否则
    // 「路由已改判、DNS 还按旧判断解析」会重新制造本方法要消除的那种矛盾。
    final hot = _hotActive(hotRouteSets, splitMode);
    final decisions = !hot && splitMode == SplitMode.smart && autoRoute != null
        ? autoRoute.domainSets()
        : (directDomains: const <String>[], proxyDomains: const <String>[]);

    return <String, Object?>{
      'servers': <Object?>[
        // 命中规则集的域名用直连 DNS：既快，又能拿到就近的 CDN 节点。
        //
        // detour 必须显式指向 direct：路由规则**不作用于** DNS 服务器自己的
        // 出站连接，只写路由规则的话这些查询会跟着 final 一起走隧道，
        // 实测表现为「解析命中规则集的域名也超时」。这不是推测，是通过
        // 「只改 detour、其它不动」的对照实验确认的。
        for (var i = 0; i < domesticDns.length; i++)
          <String, Object?>{
            'type': 'udp',
            'tag': i == 0 ? 'dns-cn' : 'dns-cn-$i',
            'server': domesticDns[i],
            'detour': OutboundTags.direct,
          },
        // 其余域名走隧道内的解析器：明文 UDP 也无所谓，
        // 它整条链路都在 WireGuard 里，不会被篡改。
        //
        // 第一个用配置声明的（或兜底值），后面跟备选。**备选不是锦上添花**：
        // 经隧道到单个公共解析器的 UDP 查询会随机丢失，单点配置下一次丢包就是
        // 一次「网站打不开」——而重试时缓存已生效又好了。见
        // [fallbackRemoteDnsServers] 里记录的实测日志。
        for (var i = 0; i < remoteServers.length; i++)
          <String, Object?>{
            'type': 'udp',
            // 第一个沿用 remoteTag（'dns-remote'），后面的加序号后缀，
            // 与直连解析器的命名方式保持一致。
            'tag': i == 0 ? remoteTag : '$remoteTag-$i',
            'server': remoteServers[i],
            'detour': OutboundTags.vpn,
          },
      ],
      'rules': <Object?>[
        // 已判定「该走隧道」的域名：DNS 也必须经隧道解析。
        //
        // 这一条正是「境内答案不可信」这个判断的一部分——既然直连解析给出过
        // 可疑答案（或直连根本不通），就不该再让境内解析器来决定它连到哪。
        // 必须排在下面 geosite-cn 那条之前：这些域名往往同时命中 geosite-cn，
        // 而那条会把它们送去境内解析器，与判定的依据直接冲突。
        if (hot)
          <String, Object?>{
            'rule_set': <String>[
              AutoRouteRuleSetTags.userProxy,
              AutoRouteRuleSetTags.autoProxy,
            ],
            'action': 'route',
            'server': remoteTag,
          }
        else
          ..._dnsDomainRule(decisions.proxyDomains, remoteTag),
        // 命中**域名类**规则集的域名用直连 DNS：既快，又能拿到就近的 CDN 节点。
        //
        // 这里引用的是全部域名类规则集（`geosite-cn` 与 `geosite-cn-extra`），
        // 而不是其中一个：内核的一条规则里多个 `rule_set` 之间是「或」，
        // 因此一次就能表达「凡是被判为直连的域名都用直连解析器」。
        if (splitMode == SplitMode.smart && hasDomainRuleSet)
          <String, Object?>{
            'rule_set': domainRuleSetTags,
            'action': 'route',
            'server': 'dns-cn',
          },
        // 已判定「该直连」的域名（直连白名单预置 + 反方向学到的）：
        // 要用直连解析器，否则会拿到境外 CDN 的地址再去直连。
        if (hot)
          <String, Object?>{
            'rule_set': <String>[
              AutoRouteRuleSetTags.userDirect,
              AutoRouteRuleSetTags.autoDirect,
            ],
            'action': 'route',
            'server': 'dns-cn',
          }
        else
          ..._dnsDomainRule(decisions.directDomains, 'dns-cn'),
      ],
      'final': switch (splitMode) {
        SplitMode.smart => remoteTag,
        SplitMode.globalProxy => remoteTag,
        SplitMode.globalDirect => 'dns-cn',
      },
      // 隧道只有 IPv4 地址时只解析 IPv4。
      //
      // 否则目的地有 AAAA 记录时内核会尝试 IPv6，而隧道内没有可用的 IPv6
      // 本地地址，直接报「missing IPv6 local address」，表现为部分走隧道的站点
      // 打不开而另一些正常（实测 youtube 失败、google 与 github 正常）。
      // 是否具备 IPv6 完全由用户导入的配置决定，这里自动跟随。
      //
      // 例外是流式代理（Hysteria2）：它没有隧道地址，上述前提不成立，
      // 收紧成 ipv4_only 只会让 IPv6-only 的站点白白失败。该例外由
      // [ParsedProfile.needsIpv4OnlyDns] 表达，而不是在这里按协议名判断。
      'strategy': profile.needsIpv4OnlyDns ? 'ipv4_only' : 'prefer_ipv4',
    };
  }

  // ---------------------------------------------------------------- 路由

  static Map<String, Object?> _route({
    required String ruleSetDir,
    required SplitMode splitMode,
    required String resolveDnsTag,
    AutoRouteTable? autoRoute,
    required List<RuleSetSpec> ruleSets,
    RouteRuleSetRefs? hotRouteSets,
  }) {
    // 域名决策只在智能分流下注入。规则来自 AutoRouteTable 这**一个**来源——
    // 自动纠正（两个方向）与直连白名单预置都在那张表里，因此这里不需要为
    // 任何一类机制单独拼规则。
    //
    // 「全局代理」「全局直连」是用户显式要求忽略分流的两种模式，
    // 往里注入域名规则会与用户的意图冲突——尤其是全局直连时，
    // 注入 force-proxy 会让「完全不使用隧道」这个承诺失效。
    final hotRefs = _hotActive(hotRouteSets, splitMode) ? hotRouteSets : null;
    final hot = hotRefs != null;
    final decided = !hot && splitMode == SplitMode.smart && autoRoute != null
        ? autoRoute.buildRouteRules()
        : (
            userRules: const <Map<String, Object?>>[],
            otherRules: const <Map<String, Object?>>[],
          );

    // 热更新投递：决策由本机服务的四份规则集提供，内核按 update_interval 反复
    // 拉取，因此**不需要重连**就能改判。
    //
    // 两个投递方式只在「决策何时生效」上不同，规则内容同源（都来自
    // `AutoRouteTable.domainMatchForms()`）。分段的**位置**也逐条对应：用户段在
    // `ip_is_private` 之前，学到段在它之后——理由见 `buildRouteRules()` 的文档。
    final userSegment = hot
        ? <Map<String, Object?>>[
            _hotRule(AutoRouteRuleSetTags.userProxy, OutboundTags.vpn),
            _hotRule(AutoRouteRuleSetTags.userDirect, OutboundTags.direct),
          ]
        : decided.userRules;
    final autoSegment = hot
        ? <Map<String, Object?>>[
            _hotRule(AutoRouteRuleSetTags.autoProxy, OutboundTags.vpn),
            _hotRule(AutoRouteRuleSetTags.autoDirect, OutboundTags.direct),
          ]
        : decided.otherRules;

    // 规则集标签按传入顺序排列。用户删掉某个规则集后，这里也不会再引用它，
    // 因此内核不会因为「rule_set 未定义」而拒绝启动。
    final ruleSetTags = <String>[
      for (final spec in ruleSets) spec.tag,
    ];

    // 热更新的四份规则集定义。
    //
    // 四份恒被定义、恒被引用（即使某一组恰好为空，空规则集什么都不匹配）。少定义
    // 一个，内核就会因「引用了未定义的 rule_set」拒绝启动——那是启动期硬失败，
    // 而不是一条规则不生效。地址由 [RouteRuleSetRefs.isComplete] 保证齐全。
    final hotRuleSetDefs = <Map<String, Object?>>[];
    if (hotRefs != null) {
      for (final tag in AutoRouteRuleSetTags.all) {
        final url = hotRefs.urls[tag];
        if (url == null) continue;
        hotRuleSetDefs.add(<String, Object?>{
          'type': 'remote',
          'tag': tag,
          'format': 'source',
          'url': url,
          'update_interval': _goDuration(hotRefs.updateInterval),
          'http_client': AutoRouteRuleSetTags.httpClient,
        });
      }
    }

    return <String, Object?>{
      'rules': <Object?>[
        // 嗅探：从 TLS SNI / HTTP Host 里认出域名，
        // 这样即便流量以 IP 形式到达也能按域名规则判定。
        // 必须放在最前面：后面所有按域名判定的规则都依赖它填好目标域名。
        <String, Object?>{'action': 'sniff'},
        // 本地 DNS 代理自身的解析请求交给内置 DNS 模块处理。
        <String, Object?>{'protocol': 'dns', 'action': 'hijack-dns'},
        // ① 用户手工指定的走向。最高优先级，**连内网直连都能覆盖**
        // （用户可能为了排查问题故意把某个内网域名指向代理）。
        ...userSegment,
        // ② 私有地址段始终直连。
        //
        // 位置很关键，且**不再是口头约定**：它必须早于程序学到与内置白名单的
        // 规则（下一段），因为那两类都可能错误地指向内网——
        //   * `nas.local` 这类内网主机名解析出 192.168.x.x 时会被 `geoip-cn`
        //     命中，反方向学习会把它学成「直连」（无害）；
        //   * 而它一旦临时不可达就会攒够「直连失败」被推成 forceProxy
        //     （**有害**：内网流量进隧道，既费流量又必然连不上）。
        // 私有地址段是确定的、可判定的边界，不该由推断出的证据去推翻它。
        <String, Object?>{'ip_is_private': true, 'outbound': OutboundTags.direct},
        // ③ 程序学到 + 内置白名单。它们必须早于规则库：
        //   * 「直连失败→走隧道」的那一批需要被拉回隧道，而规则库会先把它们
        //     判成直连（因为它们解析到 geoip-cn 内的地址）；
        //   * 「该直连却被判进隧道」的那一批需要被拉出来，而规则库根本认不出它们。
        ...autoSegment,
        // ④ 规则库。
        if (splitMode == SplitMode.smart && ruleSetTags.isNotEmpty)
          <String, Object?>{
            'rule_set': ruleSetTags,
            'outbound': OutboundTags.direct,
          },
        // ⑤ `route.final` 兜底（见下方）。
      ],
      'rule_set': <Object?>[
        // 热更新的四份：由本机回环服务提供，内核按 update_interval 反复拉取。
        ...hotRuleSetDefs,
        for (final spec in ruleSets)
          <String, Object?>{
            'type': 'local',
            'tag': spec.tag,
            'format': 'binary',
            'path': _ruleSetPath(ruleSetDir, spec.fileName),
          },
      ],
      // 白名单式直连：命中规则才直连，其余一律走隧道。
      'final': switch (splitMode) {
        SplitMode.smart => OutboundTags.vpn,
        SplitMode.globalProxy => OutboundTags.vpn,
        SplitMode.globalDirect => OutboundTags.direct,
      },
      'auto_detect_interface': true,
      // 内核自己需要解析域名时用哪个解析器。
      //
      // 默认指向**隧道**解析器，这是一个方向性选择，理由与代价都要说清楚：
      //   * 方向：本程序是白名单式直连，未命中规则集的流量一律走隧道，因此
      //     「内核要解析的域名」绝大多数也是要经隧道的目标。让它们跟着出口去
      //     解析，才能拿到出口视角下的就近地址。
      //   * 代价：若某个域名**只能**在直连下解析，这个默认值会让它必然失败。
      //     已知的两类都不受影响——代理出站自己的服务器地址由适配器显式指定
      //     `domain_resolver=dns-cn`（隧道建立在解析之后，走隧道会形成死锁），
      //     而直连出站也带 `domain_resolver=dns-cn`。真正落到这个默认值的是
      //     「已判定走隧道、且需要内核自己解析」的域名，那正是我们要的方向。
      //   * 想改这里的默认值之前请先确认上面两类仍然成立。
      'default_domain_resolver': <String, Object?>{'server': resolveDnsTag},
    };
  }

  /// sing-box 需要正斜杠分隔的路径，Windows 上反斜杠会被当作转义。
  static String _ruleSetPath(String dir, String fileName) {
    final normalized = dir.replaceAll('\\', '/');
    final trimmed = normalized.endsWith('/')
        ? normalized.substring(0, normalized.length - 1)
        : normalized;
    return '$trimmed/$fileName';
  }

  /// 把一组域名翻译成一条 sing-box 路由规则。空列表返回空片段。
  ///
  /// 与 `AutoRouteTable.buildRouteRules()` 用同一种写法：同时下发 `domain`
  /// （精确）与 `domain_suffix`（后缀）。理由在那边写得更细——`cursor.sh`
  /// 不写成后缀就匹配不到 `api2.cursor.sh`，而预置里的域名恰恰以后者为主。
  ///
  /// 只用于 **DNS** 规则：路由规则一律由 `AutoRouteTable.buildRouteRules()`
  /// 生成，不再有第二条路径。
  static List<Map<String, Object?>> _dnsDomainRule(
    List<String> domains,
    String server,
  ) {
    if (domains.isEmpty) return const <Map<String, Object?>>[];
    return <Map<String, Object?>>[
      <String, Object?>{
        'domain': List<String>.of(domains),
        'domain_suffix': List<String>.of(domains),
        'action': 'route',
        'server': server,
      },
    ];
  }

  // ------------------------------------------------------------ 热更新规则集

  /// 热更新投递是否可用。
  ///
  /// 三个条件缺一不可：调用方给了接入点、四份地址齐全、且是智能分流。
  ///
  /// 「四份地址齐全」不是多余的谨慎：路由规则会引用全部四个标签，少一个内核就
  /// 拒绝启动。把它在这里判掉，就退回了改造前的内联方式——**热生效没了，连接
  /// 照旧**，而不是让用户面对一个起不来的内核。
  ///
  /// 全局代理/全局直连不注入域名决策（用户显式要求忽略分流），因此也不需要规则集；
  /// 那时若仍引用它们，反而会让「完全不使用隧道」这类承诺被一条规则悄悄破坏。
  static bool _hotActive(RouteRuleSetRefs? refs, SplitMode splitMode) =>
      refs != null && refs.isComplete && splitMode == SplitMode.smart;

  /// 一条「引用规则集决定走向」的路由规则。
  static Map<String, Object?> _hotRule(String tag, String outbound) =>
      <String, Object?>{
        'rule_set': <String>[tag],
        'outbound': outbound,
      };

  /// Go 风格的时长文本。sing-box 的 `update_interval` 用这种写法。
  static String _goDuration(Duration duration) {
    if (duration.inMilliseconds % 1000 == 0) return '${duration.inSeconds}s';
    return '${duration.inMilliseconds}ms';
  }
}
