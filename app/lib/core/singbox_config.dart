import 'dart:convert';

import '../models.dart';
import '../protocols/parsed_profile.dart';
import '../protocols/protocol_adapter.dart';
import 'auto_route.dart';

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
  const RuleSetSpec({required this.tag, required this.fileName});

  final String tag;
  final String fileName;
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
  static const String vpnTag = 'vpn';

  /// 出厂规则集。这是不传 [build] 的 `ruleSets` 时的默认值。
  ///
  /// 顺序即内核 `rule_set` 列表的顺序，与历史上写死的两份保持一致，
  /// 这样「用户没有改动任何规则」时生成的配置不会发生变化。
  static const List<RuleSetSpec> defaultRuleSets = <RuleSetSpec>[
    RuleSetSpec(tag: 'geosite-cn', fileName: 'geosite-cn.srs'),
    RuleSetSpec(tag: 'geoip-cn', fileName: 'geoip-cn.srs'),
  ];

  /// 域名类规则集的标签：只有它参与 DNS 直连分流。
  ///
  /// geoip-cn 是 IP 类规则集，不参与域名 DNS 判定；自定义规则集是域名的还是
  /// IP 的，程序从文件名无从得知，因此不猜——保持既有的 DNS 策略不变。
  static const String domainRuleSetTag = 'geosite-cn';

  /// 入站方式。两端能力不同，因此由调用方按平台选择。
  ///
  /// 分流规则、DNS 策略、路由表**完全共用**，只有这一处不同。
  static const int defaultMixedPort = 2080;

  /// Clash API 端口：用于读取实时连接与流量，界面上的「分流记录」由此而来。
  static const int defaultClashApiPort = 2081;

  /// 直连 DNS。走直连出站，用于解析命中规则集的域名，保证拿到离用户最近的节点。
  static const List<String> domesticDns = <String>['223.5.5.5', '119.29.29.29'];

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
        ruleSets: ruleSets,
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
          'tag': 'direct',
          'domain_resolver': <String, Object?>{'server': 'dns-cn'},
        },
      ],
      'route': _route(
        ruleSetDir: ruleSetDir,
        splitMode: splitMode,
        resolveDnsTag: remoteDns.$3,
        autoRoute: autoRoute,
        ruleSets: ruleSets,
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
  /// 优先沿用配置里声明的第一个 IP 型 DNS——那是配置作者选定的解析器；
  /// 没有可用的就退回 1.1.1.1。返回 (地址, 是否来自配置, 标签)。
  static (String, bool, String) _pickRemoteDns(ParsedProfile profile) {
    for (final entry in profile.declaredDns) {
      final value = entry.trim();
      if (value.isEmpty) continue;
      // 只接受 IP：域名型 DNS 自己就需要先被解析，会形成循环依赖。
      if (_looksLikeIp(value)) return (value, true, 'dns-remote');
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
    required List<RuleSetSpec> ruleSets,
  }) {
    final (remoteAddress, _, remoteTag) = remoteDns;
    final remoteServers = remoteDnsServers(profile);
    // geosite-cn 被用户删掉/停用后，DNS 规则不能再引用它：内核会因
    // 「引用了未定义的 rule_set」直接拒绝启动。没有它时退回纯 final 策略，
    // 与全局直连时的行为一致。
    final hasDomainRuleSet = ruleSets.any((RuleSetSpec s) => s.tag == domainRuleSetTag);

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
            'detour': 'direct',
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
            'detour': 'vpn',
          },
      ],
      'rules': <Object?>[
        if (splitMode == SplitMode.smart && hasDomainRuleSet)
          <String, Object?>{
            'rule_set': <String>[domainRuleSetTag],
            'action': 'route',
            'server': 'dns-cn',
          },
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
  }) {
    // 自动纠正规则只在智能分流下注入。
    //
    // 「全局代理」「全局直连」是用户显式要求忽略分流的两种模式，
    // 往里注入域名规则会与用户的意图冲突——尤其是全局直连时，
    // 注入 force-proxy 会让「完全不使用隧道」这个承诺失效。
    final learnedRules = splitMode == SplitMode.smart && autoRoute != null
        ? autoRoute.buildRouteRules()
        : const <Map<String, Object?>>[];

    // 规则集标签按传入顺序排列。用户删掉某个规则集后，这里也不会再引用它，
    // 因此内核不会因为「rule_set 未定义」而拒绝启动。
    final ruleSetTags = <String>[
      for (final spec in ruleSets) spec.tag,
    ];

    return <String, Object?>{
      'rules': <Object?>[
        // 嗅探：从 TLS SNI / HTTP Host 里认出域名，
        // 这样即便流量以 IP 形式到达也能按域名规则判定。
        // 必须放在最前面：后面所有按域名判定的规则都依赖它填好目标域名。
        <String, Object?>{'action': 'sniff'},
        // 本地 DNS 代理自身的解析请求交给内置 DNS 模块处理。
        <String, Object?>{'protocol': 'dns', 'action': 'hijack-dns'},
        // 自动纠正学到的规则紧跟在嗅探之后。
        //
        // 位置很关键：它必须早于下面的 geosite-cn / geoip-cn，否则规则库会先把
        // 域名判成直连，纠正永远不生效——而这正是需要纠正的场景
        // （域名解析到 geoip-cn 内的地址时，规则集「正确地」命中）。
        ...learnedRules,
        // 局域网与本机地址始终直连。
        //
        // 放在自动纠正之后：用户如果显式把某个内网域名指向代理（例如为了
        // 排查问题），应当尊重他的选择；但默认情况下内网地址绝不进隧道。
        <String, Object?>{'ip_is_private': true, 'outbound': 'direct'},
        if (splitMode == SplitMode.smart && ruleSetTags.isNotEmpty)
          <String, Object?>{
            'rule_set': ruleSetTags,
            'outbound': 'direct',
          },
      ],
      'rule_set': <Object?>[
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
        SplitMode.smart => 'vpn',
        SplitMode.globalProxy => 'vpn',
        SplitMode.globalDirect => 'direct',
      },
      'auto_detect_interface': true,
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
}
