/// 应用直连预置：把「确实能在国内直连」的境外应用域名显式拉出隧道。
///
/// 存在的理由，以及为什么它不能靠内置规则库自动解决：
///
/// 本程序是**白名单式直连**——命中 `geosite-cn` / `geoip-cn` 才直连，其余一律
/// 走隧道（见 `singbox_config.dart` 的 `_route()`）。这对绝大多数境外服务都是
/// 正确且省心的判断。但存在一类例外：**某些境外应用的后端在国内可以直接连通**，
/// 把它们送进隧道只是白白占用隧道带宽、增加延迟，并把访问来源换成一个境外 IP。
///
/// 内置规则库**不可能**收录这些域名——`geosite-cn` 是「中国站点」列表，
/// 而这些是境外站点；`geoip-cn` 看的是解析结果，它们的地址也在境外。因此
/// 「它们不在规则库里」这件事本身不代表规则不全，而是需要一份**方向相反的
/// 显式白名单**。这个文件就是那份白名单。
///
/// 每条预置都必须带 [AppPreset.evidence]：这些域名能直连是**实测**结论，
/// 不是想当然。境外服务的可达性会随链路与时间变化，把依据写下来，将来它失效时
/// 才有人能判断该怎么复核、要不要撤掉。
library;

/// 一个应用的直连预置。
class AppPreset {
  const AppPreset({
    required this.id,
    required this.label,
    required this.summary,
    required this.directDomains,
    this.tunnelExceptions = const <String>[],
    this.evidence,
    this.defaultEnabled = false,
  });

  /// 稳定标识，用于持久化用户的选择。改了名字会让用户的选择失效，因此不要改。
  final String id;

  /// 展示名。
  final String label;

  /// 一句话说明这个预置做了什么。
  final String summary;

  /// 命中即**直连**的域名。
  ///
  /// 生成配置时会同时下发精确与后缀两种写法，因此 `cursor.sh` 会一并覆盖
  /// `api2.cursor.sh` 这类子域。
  final List<String> directDomains;

  /// 必须**留在隧道里**的例外域名，优先级高于 [directDomains]。
  ///
  /// 存在的理由非常具体：[directDomains] 里的后缀会覆盖到一批子域，而其中
  /// 个别子域在国内**连 DNS 都解析不出来**（NXDOMAIN）。把它们直连就等于直接
  /// 打不开；留在这里交给隧道，反而能由远端解析器解析出来。
  ///
  /// 还要注意：NXDOMAIN 属于「解析失败」，按 `core_log.dart` 的失败归因规则
  /// **不会**触发自动纠正（那是给「判为直连却连接失败」用的）。也就是说，
  /// 一个错放进直连的域名不会被程序自己救回来——所以这个例外表必须写对。
  final List<String> tunnelExceptions;

  /// 实测依据。界面上展示，让用户知道「凭什么说它能直连」。
  final String? evidence;

  /// 首次安装时是否默认启用。
  ///
  /// 只有「国内站点补充」那一类是 true：本程序的设计意图就是国内站点直连，
  /// 把国内站点误判进隧道属于缺陷，补上它是修正默认行为。而境外应用的直连是
  /// **例外**（正常情况下它们本就该走隧道），必须由用户显式启用。
  final bool defaultEnabled;
}

/// 内置预置的登记表。
///
/// 这里只放**数据**，不生成 sing-box 语法：路由片段由
/// `SingBoxConfigBuilder._route()` 统一翻译，与其它规则走同一条路径，
/// 避免两处各写一份「怎么表达直连/代理」而慢慢分叉。
class AppPresets {
  AppPresets._();

  /// 国内长尾站点补充（默认启用）。
  ///
  /// 存在的理由是本程序分流机制的一个结构性缺口：`geosite-cn` 是域名快路径，
  /// 而 `geoip-cn` **不参与域名目标的判定**（实测见 `docs/RULES.md`），因此
  /// 不在 `geosite-cn` 内的国内站点**必然**进隧道，没有任何兜底。这类流量不失败、
  /// 不报错，只白白占用隧道带宽。
  ///
  /// 2026-09 实测：55 个国内站点里 51 个命中 `geosite-cn`，漏出 4 个，
  /// 而这 4 个的直连解析**全部**落在 `geoip-cn` 覆盖的网段内——即它们确实是国内
  /// 站点、确实能直连，只是域名表没收。这 4 个就是下面的清单。
  ///
  /// 与 [cursor] 的区别：那些是「例外该直连」的境外应用，这里是「本该直连却被
  /// 判进隧道」的国内站点。所以这里 `defaultEnabled` 为 true——把国内站点送进
  /// 隧道是缺陷，不是配置选项。
  ///
  /// 清单的维护方式是**实测驱动**，不是抄一份大列表：只收「实测漏出且解析落在
  /// 国内网段」的域名。未收录的长尾由 `AutoRouteTable.recordDomesticAnswer`
  /// 在运行中自动学会（见 `core_monitor.probeDirectCandidates`）。
  static const AppPreset cnExtra = AppPreset(
    id: 'cn-extra',
    label: '国内长尾站点补充',
    summary:
        'geosite-cn 未收录、但直连解析落在国内网段的站点。默认启用——'
        '把国内站点送进隧道属于误判，不是可选项。',
    directDomains: <String>[
      'gaoding.com',
      'jianyu360.com',
      'gelonghui.com',
      'chuangkit.com',
    ],
    evidence:
        '2026-09 实测：55 个国内站点中 51 个被 geosite-cn 收录；'
        '下列 4 个未收录，且它们的直连解析（223.5.5.5）全部落在 geoip-cn 网段内，'
        '即确实为国内站点。',
    // 把国内站点送进隧道是缺陷而不是配置选项，因此默认启用。
    defaultEnabled: true,
  );

  /// Cursor 编辑器。
  ///
  /// 2026-09 实测（中国大陆·深圳，`curl --noproxy '*'` 强制绕过系统代理）：
  /// `api2.cursor.sh` 200 / `api3.cursor.sh` 404 / `api4.cursor.sh` 404 /
  /// `repo42.cursor.sh` 404 / `cursor.com` 200 / `marketplace.cursorapi.com` 200
  /// / `cursor-cdn.com` 404 / `downloads.cursor.com` 403 / `download.todesktop.com`
  /// 400 —— 都是「TCP 与 TLS 都能建立、服务器正常应答」。同一时刻
  /// `www.google.com` 连接超时，说明这些连接确实是直连而不是被悄悄代理。
  ///
  /// 例外三个是同一批实测里发现的：`api5.cursor.sh`、`us-asia.gcpp.cursor.sh`、
  /// `us-eu.gcpp.cursor.sh` 在国内（系统 DNS 与 223.5.5.5）都是 NXDOMAIN，
  /// 直连必然打不开，必须留在隧道里。
  static const AppPreset cursor = AppPreset(
    id: 'cursor',
    label: 'Cursor',
    summary: 'Cursor 编辑器的 API、索引、账号与更新域名走直连，不再占用隧道带宽。',
    directDomains: <String>[
      'cursor.sh',
      'cursor.com',
      'cursorapi.com',
      'cursor-cdn.com',
      'download.todesktop.com',
    ],
    tunnelExceptions: <String>[
      // 国内 NXDOMAIN：直连打不开，走隧道才能由远端解析器解析。
      'api5.cursor.sh',
      'us-asia.gcpp.cursor.sh',
      'us-eu.gcpp.cursor.sh',
    ],
    evidence:
        '2026-09 于中国大陆直连实测：上述直连域名均能完成 TLS 并收到 HTTP 应答'
        '（负对照 google.com 连接超时）；三个例外域名在国内 DNS 查询为 NXDOMAIN。',
  );

  /// 全部内置预置，顺序即界面顺序。
  static const List<AppPreset> all = <AppPreset>[cnExtra, cursor];

  /// 首次安装时应当默认启用的预置 id。
  ///
  /// 独立成一个方法而不是让调用方自己过滤：`AppSettings` 的默认值与「存档里没有
  /// 这个键」时的回退值必须是同一个，否则新装与升级会得到不同的默认行为。
  static List<String> defaultEnabledIds() => <String>[
    for (final preset in all)
      if (preset.defaultEnabled) preset.id,
  ];

  /// 按 id 查找。未知 id 返回 null——存档里出现过而现在删掉的预置不该让程序出错。
  static AppPreset? byId(String id) {
    for (final preset in all) {
      if (preset.id == id) return preset;
    }
    return null;
  }

  /// 把一组 id 解析成预置列表，保持 [all] 的顺序，忽略无法识别的 id。
  ///
  /// 用 `all` 的顺序而不是用户开启的顺序：生成配置的规则顺序必须稳定，
  /// 否则「先点哪个开关」会悄悄改变路由优先级。
  static List<AppPreset> resolve(Iterable<String> ids) {
    final wanted = ids.toSet();
    if (wanted.isEmpty) return const <AppPreset>[];
    return <AppPreset>[
      for (final preset in all)
        if (wanted.contains(preset.id)) preset,
    ];
  }
}
