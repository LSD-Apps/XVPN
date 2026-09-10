import 'dart:convert';

import '../models.dart';
import '../protocols/parsed_profile.dart';
import '../protocols/protocol_adapter.dart';

/// 入站方式：决定内核如何接管流量。两端能力不同，因此按平台选择。
enum InboundMode {
  /// 本地 HTTP/SOCKS 混合入站 + 系统代理设置（Windows 默认）。
  mixed,

  /// VpnService 提供 TUN，内核接管整机流量（Android 唯一可选）。
  tun,
}

/// 把用户的 WireGuard .conf 翻译成 sing-box 配置。
///
/// 这是「傻瓜式」的核心：用户只给一份 .conf，其余全部由这里推导出来。
///
/// 三条关键设计：
///
///  1. **.conf 里的 AllowedIPs 不参与路由**。它只描述原作者想要的隧道范围，
///     而分流由内置规则库决定。出站方向统一用 0.0.0.0/0 + ::/0，否则被墙的
///     地址根本进不了隧道。
///
///  2. **DNS 必须分流，否则一切白搭**。被墙域名会被污染解析，如果这类域名
///     拿到假 IP，再按 IP 判定就会误判成直连。所以国内域名走国内 DNS，
///     其余域名走隧道内的解析器。
///
///  3. **默认走代理，国内才直连**。命中 geosite-cn / geoip-cn 的直连，
///     其余全部走隧道——白名单式直连比黑名单式代理可靠得多。
class SingBoxConfigBuilder {
  SingBoxConfigBuilder._();

  /// 出站/端点的标签。路由规则与 route.final 都引用它。
  static const String vpnTag = 'vpn';

  /// 入站方式。两端能力不同，因此由调用方按平台选择。
  ///
  /// 分流规则、DNS 策略、路由表**完全共用**，只有这一处不同。
  static const int defaultMixedPort = 2080;

  /// Clash API 端口：用于读取实时连接与流量，界面上的「分流记录」由此而来。
  static const int defaultClashApiPort = 2081;

  /// 国内 DNS。走直连，用于解析国内域名，保证拿到离用户最近的节点。
  static const List<String> domesticDns = <String>['223.5.5.5', '119.29.29.29'];

  /// 兜底的外部 DNS。.conf 里没有声明时使用。
  static const String fallbackRemoteDns = '1.1.1.1';

  /// 生成 sing-box 配置对象。
  ///
  /// [ruleSetDir] 是规则集（.srs）所在目录的绝对路径；sing-box 需要真实路径，
  /// 因此运行时要把资源落到磁盘上再传进来。
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
  }) {
    final remoteDns = _pickRemoteDns(profile);
    final adapter = VpnProtocolFactory.adapterForProtocol(profile.protocol);
    final endpoint = adapter.buildEndpoint(
      profile,
      const OutboundContext(tag: vpnTag, resolverTag: 'dns-cn'),
    );

    return <String, Object?>{
      'log': <String, Object?>{
        'level': 'warn',
        'timestamp': true,
      },
      'dns': _dns(
        profile: profile,
        remoteDns: remoteDns,
        ruleSetDir: ruleSetDir,
        splitMode: splitMode,
      ),
      'endpoints': <Object?>[endpoint],
      'inbounds': <Object?>[_inbound(inboundMode, mixedPort)],
      'outbounds': <Object?>[
        // direct 出站必须带一个域解析器，否则它在 sing-box 眼里是「空出站」，
        // 国内 DNS 的 detour=direct 会被拒绝（实测报错：
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
      ),
      'experimental': <String, Object?>{
        // 界面上的连接列表与实时流量都从这里取，避免自己解析日志。
        'clash_api': <String, Object?>{
          'external_controller': '127.0.0.1:$clashApiPort',
        },
        if (logSplits)
          'cache_file': <String, Object?>{'enabled': true},
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
  static Map<String, Object?> _inbound(InboundMode mode, int mixedPort) {
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
          'stack': 'mixed',
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
  }) {
    final (remoteAddress, _, remoteTag) = remoteDns;

    return <String, Object?>{
      'servers': <Object?>[
        // 国内域名用国内 DNS：既快，又能拿到就近的 CDN 节点。
        //
        // detour 必须显式指向 direct：路由规则**不作用于** DNS 服务器自己的
        // 出站连接，只写路由规则的话这些查询会跟着 final 一起走隧道，
        // 实测表现为「解析国内域名也超时」。这不是推测，是通过
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
        <String, Object?>{
          'type': 'udp',
          'tag': remoteTag,
          'server': remoteAddress,
          'detour': 'vpn',
        },
      ],
      'rules': <Object?>[
        if (splitMode == SplitMode.smart)
          <String, Object?>{
            'rule_set': <String>['geosite-cn'],
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
      // 本地地址，直接报「missing IPv6 local address」，表现为部分国外站点
      // 打不开而另一些正常（实测 youtube 失败、google 与 github 正常）。
      // 是否具备 IPv6 完全由用户导入的配置决定，这里自动跟随。
      'strategy': profile.hasIpv6 ? 'prefer_ipv4' : 'ipv4_only',
    };
  }

  // ---------------------------------------------------------------- 路由

  static Map<String, Object?> _route({
    required String ruleSetDir,
    required SplitMode splitMode,
    required String resolveDnsTag,
  }) {
    return <String, Object?>{
      'rules': <Object?>[
        // 嗅探：从 TLS SNI / HTTP Host 里认出域名，
        // 这样即便流量以 IP 形式到达也能按域名规则判定。
        <String, Object?>{
          'action': 'sniff',
        },
        // 局域网与本机地址始终直连。
        <String, Object?>{
          'ip_is_private': true,
          'outbound': 'direct',
        },
        // 本地 DNS 代理自身的解析请求交给内置 DNS 模块处理。
        <String, Object?>{
          'protocol': 'dns',
          'action': 'hijack-dns',
        },
        if (splitMode == SplitMode.smart)
          <String, Object?>{
            'rule_set': <String>['geosite-cn', 'geoip-cn'],
            'outbound': 'direct',
          },
      ],
      'rule_set': <Object?>[
        <String, Object?>{
          'type': 'local',
          'tag': 'geosite-cn',
          'format': 'binary',
          'path': _ruleSetPath(ruleSetDir, 'geosite-cn.srs'),
        },
        <String, Object?>{
          'type': 'local',
          'tag': 'geoip-cn',
          'format': 'binary',
          'path': _ruleSetPath(ruleSetDir, 'geoip-cn.srs'),
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
