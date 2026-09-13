/// 启动自检：用固定的探针分别验证「直连」「隧道」「DNS」三条腿。
///
/// 为什么需要它：分流出问题时用户看到的现象只有一个——「有的网站打不开」。
/// 但背后的原因至少有三种，处置方式完全不同：
///
/// | 现象 | 结论 | 该做什么 |
/// | --- | --- | --- |
/// | 直连不通、隧道通 | 本地网络或 DNS 有问题 | 检查网络；不要怪节点 |
/// | 直连通、隧道不通 | 节点/服务器有问题 | 换节点；改规则没有用 |
/// | 两条都通，个别站点不通 | 规则库覆盖问题 | 交给自动纠正 |
///
/// 这三种情况在「连上了但打不开网站」时表现完全一样，只有分别探测两条腿
/// 才能区分。`docs/RULES.md` 把这一项列为「尚未实现」的第二项，这里补上。
///
/// 全部是纯逻辑 + 注入的探测函数，因此可以完整单元测试。
library;

/// 单条探针的结论。
enum ProbeStatus {
  /// 尚未探测。
  pending,

  /// 通过。
  passed,

  /// 失败。
  failed,
}

extension ProbeStatusX on ProbeStatus {
  String get label => switch (this) {
    ProbeStatus.pending => '待检测',
    ProbeStatus.passed => '正常',
    ProbeStatus.failed => '异常',
  };
}

/// 一条探针的结果。
class ProbeResult {
  const ProbeResult({
    required this.name,
    required this.status,
    required this.detail,
    this.millis,
  });

  /// 探针名，例如「规则直连」。
  final String name;

  final ProbeStatus status;

  /// 一句话说明，直接显示在界面上。
  final String detail;

  /// 耗时（毫秒）。无耗时的探针为 null。
  final int? millis;

  static ProbeResult pending(String name) =>
      ProbeResult(name: name, status: ProbeStatus.pending, detail: '等待探测');

  bool get passed => status == ProbeStatus.passed;
  bool get failed => status == ProbeStatus.failed;
}

/// 一次完整自检的结果。
class StartupSelfCheckReport {
  const StartupSelfCheckReport({
    required this.checkedAt,
    required this.probes,
    required this.conclusion,
    required this.advice,
  });

  final DateTime checkedAt;
  final List<ProbeResult> probes;

  /// 结论：一句话说清「现在能不能正常上网」。
  final String conclusion;

  /// 处置建议。用户不需要懂分流。
  final String advice;

  bool get hasFailures => probes.any((ProbeResult p) => p.failed);

  ProbeResult? probeNamed(String name) {
    for (final probe in probes) {
      if (probe.name == name) return probe;
    }
    return null;
  }
}

/// 启动自检的执行器。
class StartupSelfCheck {
  StartupSelfCheck({
    required this.directProbe,
    required this.tunnelProbe,
    required this.coreResolve,
    required this.domesticResolve,
    this.directProbeHost = 'www.baidu.com',
    this.tunnelProbeHost = 'www.gstatic.com',
    this.domesticResolveDomain = 'www.baidu.com',
    this.tunnelResolveDomain = 'www.gstatic.com',
  });

  /// 直连探测：返回毫秒数，失败返回 null。
  final Future<int?> Function() directProbe;

  /// 隧道探测：返回毫秒数，失败返回 null。
  final Future<int?> Function() tunnelProbe;

  /// 经内核 DNS 模块解析（隧道内解析器）。
  final Future<List<String>> Function(String domain) coreResolve;

  /// 经直连解析器解析。
  final Future<List<String>> Function(String domain) domesticResolve;

  final String directProbeHost;
  final String tunnelProbeHost;

  /// 用于测量**直连解析**的域名。
  ///
  /// 必须命中 `geosite-cn`：内核的 DNS 规则会把命中规则集的域名交给直连解析器，
  /// 因此这个域名验证的是「直连解析能不能用」。
  final String domesticResolveDomain;

  /// 用于测量**隧道解析**的域名。
  ///
  /// 必须**不**命中 `geosite-cn`：只有这样的域名才会落到 `dns.final`（隧道解析器），
  /// 从而真正验证「隧道能不能承载 DNS」。
  ///
  /// 为什么必须单独一条：原来的 DNS 探针用的是 `www.baidu.com`，它命中
  /// `geosite-cn`，于是内核按 DNS 规则用**直连**解析器回答——这个探针从未
  /// 碰过隧道解析器。而隧道解析器是所有非规则集域名的解析出口，它坏了就是
  /// 「所有境外站点打不开」，属于失败面最大的故障，却恰好落在探测盲区里。
  ///
  /// 也不能指望「隧道出口」那条探针覆盖它：`/proxies/vpn/delay` 访问的是一个
  /// **域名**，代理出站支持域名透传，解析发生在隧道出口那一侧，内核自己的
  /// 解析器并不参与。
  final String tunnelResolveDomain;

  /// 探针名。界面按名字取结果，因此做成常量。
  static const String directName = '规则直连';
  static const String tunnelName = '隧道出口';
  static const String dnsName = 'DNS 解析';
  static const String tunnelDnsName = '隧道 DNS';

  StartupSelfCheckReport? _report;

  StartupSelfCheckReport? get report => _report;

  /// 跑一次自检。
  ///
  /// 两条连通性探针**并发**执行：它们走的是完全不同的路径（一条不出本机、
  /// 一条穿过隧道），串行执行只会让用户多等一个超时。这与 `DnsMonitor`
  /// 里串行探测的选择不矛盾——那里串行是为了让耗时数字可比。
  Future<StartupSelfCheckReport> run() async {
    final directFuture = _runProbe(
      directName,
      directProbe,
      successDetail: '经系统网络可达 $directProbeHost:443',
      failureDetail: '无法连接 $directProbeHost:443，本地网络或 DNS 可能有问题',
    );
    final tunnelFuture = _runProbe(
      tunnelName,
      tunnelProbe,
      successDetail: '经隧道可达 $tunnelProbeHost',
      failureDetail: '经隧道访问 $tunnelProbeHost 失败，节点或服务器可能不可用',
    );

    final results = await Future.wait<ProbeResult>(<Future<ProbeResult>>[
      directFuture,
      tunnelFuture,
    ]);
    final dnsResult = await _runDnsProbe();
    final tunnelDnsResult = await _runTunnelDnsProbe();

    final probes = <ProbeResult>[...results, dnsResult, tunnelDnsResult];
    final report = _conclude(probes);
    _report = report;
    return report;
  }

  Future<ProbeResult> _runProbe(
    String name,
    Future<int?> Function() probe, {
    required String successDetail,
    required String failureDetail,
  }) async {
    try {
      final millis = await probe();
      if (millis == null) {
        return ProbeResult(
          name: name,
          status: ProbeStatus.failed,
          detail: failureDetail,
        );
      }
      return ProbeResult(
        name: name,
        status: ProbeStatus.passed,
        // 带上耗时：用户能据此判断「慢」是不是节点问题。
        detail: '$successDetail · ${millis}ms',
        millis: millis,
      );
    } on Object catch (e) {
      return ProbeResult(
        name: name,
        status: ProbeStatus.failed,
        detail: '$failureDetail（$e）',
      );
    }
  }

  /// DNS 探针：两条解析路径是否都能拿到答案。
  ///
  /// 只关心「有没有拿到地址」，不比较两者是否相同：域名有两套部署时
  /// 两组答案本来就不同，那是正常现象，不该报成异常。
  Future<ProbeResult> _runDnsProbe() async {
    List<String> domestic = const <String>[];
    List<String> viaCore = const <String>[];
    try {
      domestic = await domesticResolve(domesticResolveDomain);
    } on Object {
      domestic = const <String>[];
    }
    try {
      viaCore = await coreResolve(domesticResolveDomain);
    } on Object {
      viaCore = const <String>[];
    }

    if (domestic.isEmpty && viaCore.isEmpty) {
      return const ProbeResult(
        name: dnsName,
        status: ProbeStatus.failed,
        detail: '两条解析路径都拿不到结果，DNS 可能是问题根源',
      );
    }
    if (domestic.isEmpty) {
      return const ProbeResult(
        name: dnsName,
        status: ProbeStatus.failed,
        detail: '直连解析失败，只有隧道解析可用',
      );
    }
    if (viaCore.isEmpty) {
      // 隧道解析拿不到结果不一定是故障：如果这个域名命中 geosite-cn，
      // 内核会按 DNS 规则用直连解析器解析，`/dns/query` 返回的仍是直连答案。
      // 因此这里给「通过」但说明清楚，避免误报。
      return ProbeResult(
        name: dnsName,
        status: ProbeStatus.passed,
        detail:
            '直连解析正常（${domestic.first}）；'
            '内核未返回独立答案，该域名可能被判定为直连',
      );
    }
    return ProbeResult(
      name: dnsName,
      status: ProbeStatus.passed,
      detail: '直连 ${domestic.first} · 内核 ${viaCore.first}',
    );
  }

  /// 隧道 DNS 探针：内核能不能**经隧道**解析一个非规则集域名。
  ///
  /// 这是原来自检的盲区：那条 DNS 探针用的是 `www.baidu.com`，命中 `geosite-cn`
  /// 因而被路由到直连解析器，从未碰过隧道解析器。而 `dns.final` 与
  /// `default_domain_resolver` 都指向隧道解析器，所以所有非规则集域名（也就是
  /// 全部境外站点）的解析都走它——它坏了，表现为「隧道连上了但什么都打不开」，
  /// 与「节点不通」的外在表现几乎一样，而处置方式完全不同。
  ///
  /// 用 [tunnelResolveDomain]，它不命中 `geosite-cn`，因此必然落到隧道解析器。
  /// 拿不到答案就是真的坏了，不再像那条直连 DNS 探针一样可以「通过并说明」。
  Future<ProbeResult> _runTunnelDnsProbe() async {
    List<String> answers = const <String>[];
    try {
      answers = await coreResolve(tunnelResolveDomain);
    } on Object {
      answers = const <String>[];
    }
    if (answers.isEmpty) {
      return const ProbeResult(
        name: tunnelDnsName,
        status: ProbeStatus.failed,
        detail: '经隧道解析拿不到结果，非规则集域名可能全部打不开',
      );
    }
    return ProbeResult(
      name: tunnelDnsName,
      status: ProbeStatus.passed,
      detail: '经隧道解析 $tunnelResolveDomain → ${answers.first}',
    );
  }

  /// 把探针结果合成一句结论。
  StartupSelfCheckReport _conclude(List<ProbeResult> probes) {
    final direct = _find(probes, directName);
    final tunnel = _find(probes, tunnelName);
    final dns = _find(probes, dnsName);
    final tunnelDns = _find(probes, tunnelDnsName);

    if (direct?.passed == true &&
        tunnel?.passed == true &&
        dns?.passed == true &&
        tunnelDns?.passed == true) {
      return StartupSelfCheckReport(
        checkedAt: DateTime.now(),
        probes: probes,
        conclusion: '两条路径都正常',
        advice: '命中规则集的站点直连、其余站点走隧道，可以正常使用',
      );
    }

    // 隧道能载流量、直连解析正常、但**经隧道解析**不出任何域名——这是
    // 「隧道建起来了却什么都打不开」的典型成因，且与节点不通的外观几乎一样，
    // 必须单独说出来。
    //
    // 前提是直连解析正常：两条都失败时问题是 DNS 本身（下面的分支覆盖），
    // 归因给隧道会把人引向换节点，而换节点没有用。
    if (tunnel?.passed == true &&
        tunnelDns?.failed == true &&
        dns?.passed == true) {
      return StartupSelfCheckReport(
        checkedAt: DateTime.now(),
        probes: probes,
        conclusion: '隧道不通 DNS',
        advice:
            '隧道能建立连接，但经它解析域名失败，非规则集域名会全部打不开。'
            '通常是节点不允许 UDP/53 出站，或隧道内声明的 DNS 不可达。'
            '可在配置文件里改用一个可达的 DNS，或换一个节点。',
      );
    }

    if (direct?.failed == true && tunnel?.passed == true) {
      return StartupSelfCheckReport(
        checkedAt: DateTime.now(),
        probes: probes,
        conclusion: '直连这条腿不通，隧道是通的',
        advice:
            '问题在本地网络或 DNS，不在节点。'
            '请检查本机网络；若只有直连站点打不开，可先切换为「全局代理」应急。',
      );
    }

    if (direct?.passed == true && tunnel?.failed == true) {
      return StartupSelfCheckReport(
        checkedAt: DateTime.now(),
        probes: probes,
        conclusion: '隧道这条腿不通',
        advice:
            '规则判定正常，问题在节点或服务器本身。'
            '请更换节点或导入另一份配置；调整分流规则不会有帮助。',
      );
    }

    if (direct?.failed == true && tunnel?.failed == true) {
      return StartupSelfCheckReport(
        checkedAt: DateTime.now(),
        probes: probes,
        conclusion: '两条路径都不通',
        advice:
            '本机网络可能完全不可用，或配置里的服务器地址/端口不正确。'
            '请先确认这台设备本身能上网。',
      );
    }

    if (dns?.failed == true) {
      return StartupSelfCheckReport(
        checkedAt: DateTime.now(),
        probes: probes,
        conclusion: 'DNS 解析异常',
        advice:
            '解析环节有问题，即使隧道连通也会表现为网站打不开。'
            '可尝试在设置里更新规则库，或检查本地解析是否正常。',
      );
    }

    return StartupSelfCheckReport(
      checkedAt: DateTime.now(),
      probes: probes,
      conclusion: '自检未得出结论',
      advice: '部分探针未能完成，稍后会自动重试',
    );
  }

  static ProbeResult? _find(List<ProbeResult> probes, String name) {
    for (final probe in probes) {
      if (probe.name == name) return probe;
    }
    return null;
  }

  /// 尚未探测时的占位结果，供界面在自检跑完前显示。
  static List<ProbeResult> pendingProbes() => <ProbeResult>[
    ProbeResult.pending(directName),
    ProbeResult.pending(tunnelName),
    ProbeResult.pending(dnsName),
    ProbeResult.pending(tunnelDnsName),
  ];
}
