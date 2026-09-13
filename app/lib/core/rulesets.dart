import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'platform_paths.dart';

/// 一个推荐给用户的第三方规则集。
///
/// 只描述「去哪儿取」，不含数据本身——因此不涉及再分发，也就绕开了
/// 上游许可与本项目许可是否兼容的问题（见 `RuleSetStore.suggested` 的注释）。
class SuggestedRuleSet {
  const SuggestedRuleSet({
    required this.name,
    required this.label,
    required this.url,
    required this.note,
    this.domainRuleSet = false,
  });

  /// 建议使用的本地名称。用户添加时仍可改，但不能与现有条目重名。
  final String name;

  /// 界面上的展示名。
  final String label;

  final String url;

  /// 说明：覆盖面、收录标准与许可状况。界面直接展示，让用户自己判断要不要用。
  final String note;

  /// 是否**域名类**规则集。
  ///
  /// 必须显式声明，而且是这一项决定了它能否参与 DNS 直连分流。因为
  /// `RuleSetEntry` 对自定义条目没法从名字推断类型，先前一律按「非域名类」
  /// 处理——于是**按我们自己的推荐**添加进来的规则集，被它判为直连的域名仍然
  /// 经隧道解析（拿到境外 CDN 地址再去直连）。那正是要修的那类不一致，
  /// 只不过从推荐入口重新引入了。
  final bool domainRuleSet;
}

/// 规则集来源：随包分发的出厂规则集，还是用户自己添加的。
///
/// 这个区分是界面诚实的依据：内置规则集是二进制 `.srs`，只能启用/停用与查看
/// 元信息；自定义规则集才有可编辑的名字与下载链接。
enum RuleSetKind { builtin, custom }

extension RuleSetKindX on RuleSetKind {
  String get label => this == RuleSetKind.builtin ? '内置' : '自定义';
}

/// 一个规则集的配置与状态。
///
/// 只描述「谁来用、从哪来、启不启用」，不持有文件内容：`.srs` 落盘在规则集目录
/// 里，内核按 [fileName] 去读。名称同时是内核里的 `tag`，因此必须唯一。
class RuleSetEntry {
  RuleSetEntry({
    required this.name,
    required this.kind,
    required this.url,
    this.enabled = true,
    this.updatedAt,
    this.sizeBytes = 0,
    this.updatable = true,
    this.domainRuleSet = false,
  });

  /// 唯一标识，同时是内核里的标签与文件名（去掉 `.srs`）。
  final String name;

  final RuleSetKind kind;

  /// 上游下载地址。内置的取自 [RuleSetStore.sources]，自定义的由用户填写。
  ///
  /// [updatable] 为 false 时它不是下载地址，而是**来源说明**（形如
  /// `builtin:...`），仅供界面展示。
  final String url;

  bool enabled;

  /// 最近一次成功更新的时间。从未更新过时为 null（用的是出厂副本）。
  DateTime? updatedAt;

  /// 磁盘上的字节数。为 0 表示还没量过。
  int sizeBytes;

  /// 能否用「检查更新」重新下载。
  ///
  /// 有些内置规则集是**构建期产物**（例如从 dnsmasq 配置编译出来的补充规则集）：
  /// 上游给的不是 `.srs`，程序去下载只会拿到一份 HTML 或配置文本，被魔数校验
  /// 拒绝，用户看到的是「检查更新失败」——而失败原因与他的网络毫无关系。
  /// 对这类条目必须显式关掉更新，并让界面说明「要刷新请重跑构建脚本」。
  final bool updatable;

  /// 是否**域名类**规则集，即能否参与 DNS 直连分流。
  ///
  /// 这是逐条声明的元数据，不是从名字推导的：自定义规则集是域名类还是 IP 类，
  /// 从文件名无从得知。先前只有 `tag == 'geosite-cn'` 这个硬编码判断，于是新增
  /// 域名类规则集时**必然**漏掉它参与 DNS 分流——而现象是「判定该直连的域名仍被
  /// 境外解析器解析」，极难看出原因。
  ///
  /// 现在把它存进存档：内置条目由 [BuiltinRuleSet.isDomainRuleSet] 决定，
  /// 用户按推荐添加的第三方规则集则由 [SuggestedRuleSet.domainRuleSet] 带上。
  final bool domainRuleSet;

  String get fileName => '$name.srs';

  /// 内核里引用它的标签。
  String get tag => name;

  bool get isBuiltin => kind == RuleSetKind.builtin;

  RuleSetEntry copyWith({
    String? name,
    String? url,
    bool? enabled,
    DateTime? updatedAt,
    int? sizeBytes,
    bool? updatable,
    bool? domainRuleSet,
  }) {
    return RuleSetEntry(
      name: name ?? this.name,
      kind: kind,
      url: url ?? this.url,
      enabled: enabled ?? this.enabled,
      updatedAt: updatedAt ?? this.updatedAt,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      updatable: updatable ?? this.updatable,
      domainRuleSet: domainRuleSet ?? this.domainRuleSet,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'kind': kind == RuleSetKind.builtin ? 'builtin' : 'custom',
    'url': url,
    'enabled': enabled,
    if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
    'sizeBytes': sizeBytes,
    if (!updatable) 'updatable': false,
    'domainRuleSet': domainRuleSet,
  };

  static RuleSetEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final json = raw.cast<String, Object?>();
    final name = json['name']?.toString().trim() ?? '';
    if (name.isEmpty) return null;
    final url = json['url']?.toString() ?? '';
    final kind = json['kind'] == 'builtin'
        ? RuleSetKind.builtin
        : RuleSetKind.custom;
    // updatable 默认 true：键缺失是旧存档，那时的条目全都可更新。
    // 拿不到「这份文件是构建产物」这个事实时，宁可允许更新（用户点了会有
    // 明确报错），也不要凭空关掉一个本来能用的功能。
    //
    // domainRuleSet 相反，缺失时**回退到内置定义**而不是 false：旧存档里
    // geosite-cn 的标记必然缺失，若默认 false，升级上来的用户会突然失去
    // 「命中规则集的域名用直连解析器」这条行为——那是静默的功能回退。
    return RuleSetEntry(
      name: name,
      kind: kind,
      url: url,
      enabled: json['enabled'] as bool? ?? true,
      updatedAt: _time(json['updatedAt']),
      sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
      updatable: json['updatable'] as bool? ?? true,
      domainRuleSet: json['domainRuleSet'] as bool? ??
          RuleSetStore.isDomainRuleSetName(name),
    );
  }

  static DateTime? _time(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  /// 合法的自定义规则集名。
  ///
  /// 限制在小写字母、数字、连字符与下划线，是因为它同时是内核里的标签与磁盘上
  /// 的文件名：带上路径分隔符、空格或大写会让「标签唯一」和「文件落在正确的
  /// 目录里」这两件事同时变得难以保证。
  static final RegExp _namePattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$');

  static bool isValidName(String name) => _namePattern.hasMatch(name);
}

/// **内置**规则集的权威定义。
///
/// 把「有哪些内置规则集」做成一列带元数据的条目，而不是几张平行的
/// Map/Set，是因为每一条都同时决定了几件事，散开写必然漂移：
///   * 是否有可下载的 `.srs` 地址（能否用「检查更新」刷新）；
///   * 是否**域名类**（决定它能否参与 DNS 直连分流——IP 类不行）；
///   * 首次安装是否启用。
///
/// 尤其是「域名类」这一项：原先它是靠 `tag == 'geosite-cn'` 这个硬编码判断的，
/// 于是新增一个域名类规则集（如 `geosite-cn-extra`）时，它会**静默地**不参与
/// DNS 分流——表现为「判定该直连的域名仍被境外解析器解析，然后按境外 CDN 的
/// 地址直连」，而这是最难从现象看出原因的一类问题。
class BuiltinRuleSet {
  const BuiltinRuleSet({
    required this.name,
    this.url,
    this.source,
    this.enabledByDefault = true,
    this.isDomainRuleSet = false,
  });

  /// 规则集名（不含 `.srs`）。同时是内核标签与磁盘上的文件名。
  final String name;

  /// 上游下载地址。为 null 表示它**不能**在运行时更新（构建期产物）。
  final String? url;

  /// 来源说明，界面上展示。**不是 URL**——[url] 为 null 时用它交代怎么刷新。
  final String? source;

  /// 首次安装是否启用。
  ///
  /// 默认值必须有**实测**支撑，而不是随手取。`geosite-cn-extra` 取 true 的依据
  /// 见 [bundledExtras] 的注释与 `docs/RULES.md`。
  final bool enabledByDefault;

  /// 是否域名类。IP 类（如 `geoip-cn`）写进 DNS 规则没有意义：DNS 查询的是域名。
  final bool isDomainRuleSet;

  bool get updatable => url != null;

  String get fileName => '$name.srs';

  RuleSetEntry toEntry() => RuleSetEntry(
    name: name,
    kind: RuleSetKind.builtin,
    url: url ?? source ?? '',
    enabled: enabledByDefault,
    updatable: updatable,
    domainRuleSet: isDomainRuleSet,
  );
}

/// 规则库的落盘与更新。
///
/// 设计：程序内打包一份规则库作为**出厂副本**，运行时复制到可写目录，
/// 之后由本模块负责更新。这样做有两个好处：
///   * 首次启动无需联网即可分流；
///   * 更新只影响可写目录，不会破坏程序自身的安装内容（也不需要在
///     Program Files 下有写权限）。
///
/// 之前设置页的「检查更新」只是一个占位实现（只改了显示的日期），
/// 这里把它做成真的：从上游拉取 `.srs` 并覆盖本地副本。
class RuleSetStore {
  RuleSetStore._();

  /// 出厂规则集的**唯一**定义处。
  ///
  /// 前两项走 jsDelivr 的 `rule-set` 分支——GitHub 直连在部分网络下时通时断，
  /// 而 CDN 稳定得多（安装阶段也是从同一个地址拉取的）。
  static const List<BuiltinRuleSet> builtins = <BuiltinRuleSet>[
    BuiltinRuleSet(
      name: 'geosite-cn',
      url: 'https://cdn.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/geosite-cn.srs',
      isDomainRuleSet: true,
    ),
    BuiltinRuleSet(
      name: 'geoip-cn',
      url: 'https://cdn.jsdelivr.net/gh/SagerNet/sing-geoip@rule-set/geoip-cn.srs',
      // IP 类：不能参与 DNS 直连分流。
    ),
    // ── 构建期产物 ──────────────────────────────────────────────
    //
    // 它随包分发，但**不可**用「检查更新」下载：本项的来源是 dnsmasq 配置，
    // 需要先经 scripts/build-cn-domain-ruleset.ps1 编译。把那种地址填进来，
    // 用户点「检查更新」只会拿到一份配置文本、被魔数校验拒绝，
    // 而报错与他的网络毫无关系。
    //
    // 默认**启用**，依据是实测（见 script 的自检与 docs/RULES.md 第四节十）：
    //   * 召回：40 个国内站点全部命中（100%）；
    //   * 误命中：约 150 个境外域名（含被墙服务、无中国节点服务）**0 个**命中。
    // 再加上一条安全网：万一某个被列进去的域名其实不通，它被判为直连后连接
    // 失败会被自动纠正表学成「强制代理」，而学到的规则排在规则库**之前**，
    // 因此能覆盖它。
    BuiltinRuleSet(
      name: 'geosite-cn-extra',
      source: '由 scripts/build-cn-domain-ruleset.ps1 从 '
          'felixonmars/dnsmasq-china-list（WTFPL v2）编译；重跑脚本即可刷新',
      enabledByDefault: true,
      isDomainRuleSet: true,
    ),
    // ── IP 类补充 ───────────────────────────────────────────────
    //
    // 补的是 geoip-cn **整块缺失** 8.0.0.0/8（含阿里云国内段）——实测有 7ms
    // 延迟的国内地址被判为境外。刷新上游到当前版本后 `8.` 前缀仍是 0 条，
    // 因此不是「副本过期」而是那份数据本身不含该段。
    //
    // 用**并集**而不是替换：两份列表各有对方没有的网段（实测 `180.76.0.1`
    // 只在 geoip-cn 里）。内核的 `rule_set` 天然取并集，所以并存即可。
    //
    // `isDomainRuleSet` 保持 false（这是 IP 类），因此它**不会**进 DNS 规则——
    // DNS 查的是域名，把 IP 类规则集写进 DNS 规则没有意义。
    BuiltinRuleSet(
      name: 'geoip-cn-extra',
      source: '由 scripts/build-cn-ip-ruleset.ps1 从 '
          'gaoyifan/china-operator-ip（MIT）编译；重跑脚本即可刷新。'
          '刷新后必须同时重跑 build-cn-ip-index.ps1——cn-ip.bin 由它派生',
      enabledByDefault: true,
    ),
  ];

  /// 文件名 → 上游地址，只含**可更新**的那些。
  ///
  /// 兼容既有调用点。需要判断「是不是内置」时请用 [builtinFileNames]——
  /// 构建期产物同样是内置，只是没有可下载的地址。
  static final Map<String, String> sources = <String, String>{
    for (final entry in builtins)
      if (entry.url != null) entry.fileName: entry.url!,
  };

  /// 全部内置规则集的文件名。
  static final Set<String> builtinFileNames = <String>{
    for (final entry in builtins) entry.fileName,
  };

  /// 某个规则集名是否是**域名类**内置规则集。
  ///
  /// 自定义规则集一律返回 false：它是域名的还是 IP 的，程序从文件名无从得知，
  /// 因此不猜——保持既有的 DNS 策略不变（只让已知的域名类参与 DNS 分流）。
  static bool isDomainRuleSetName(String name) {
    for (final entry in builtins) {
      if (entry.name == name) return entry.isDomainRuleSet;
    }
    return false;
  }

  /// 推荐给用户的**第三方**规则集：只给链接，由用户自己添加。
  ///
  /// 为什么不做成内置：这些上游要么覆盖面更大但许可与本项目不完全兼容
  /// （ChinaMax 系是 GPL-2.0，非 or-later，不能单向升级到 GPL-3.0），要么
  /// 收录标准与我们的决策不等价。**不再分发**数据、只提供链接，就把许可问题
  /// 留给上游与用户，同时仍然让人一键可用。
  ///
  /// 与 [builtins] 的区别：那些是我们再分发的出厂规则集；这些不是。
  static const List<SuggestedRuleSet> suggested = <SuggestedRuleSet>[
    SuggestedRuleSet(
      name: 'cn-large',
      label: '国内站点（大范围）',
      url: 'https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@sing/geo/geosite/cn.srs',
      note: '约 11.1 万条，源自 ChinaMax。实测覆盖更全且不回退，'
          '但收录标准是「国内解析更快」，与「该直连」不完全等价。'
          '上游许可是 GPL-3.0（数据源自 GPL-2.0 的 ios_rule_script）。',
      // 它是域名清单（ChinaMax_Domain 派生），因此必须参与 DNS 直连分流。
      domainRuleSet: true,
    ),
  ];

  /// 出厂规则集列表。逐条按 [BuiltinRuleSet.enabledByDefault] 决定是否启用。
  static List<RuleSetEntry> defaultEntries() => <RuleSetEntry>[
    for (final entry in builtins) entry.toEntry(),
  ];

  /// `.srs` 二进制格式的魔数。校验它就能挡住把 HTML 错误页当成规则库写盘。
  static const List<int> srsMagic = <int>[0x53, 0x52, 0x53]; // "SRS"

  /// 可写规则库目录：Windows 为 `%LOCALAPPDATA%\XVPN\rulesets`，
  /// Linux 为 `$XDG_DATA_HOME/XVPN/rulesets`。
  ///
  /// 与 [AppStore.defaultDesktopDir] 共用同一份解析，避免两处各拼一遍后分叉。
  static Directory writableDir() {
    final dataDir = resolveDesktopPaths(
      platform: defaultTargetPlatform,
      environment: Platform.environment,
    ).dataDir;
    return Directory('${dataDir.path}${Platform.pathSeparator}rulesets');
  }

  /// 规则库的最终落盘目录：显式传入时以它为准，否则用桌面端的可写目录。
  ///
  /// 单独抽成一个函数，是因为这个决定现在有**两个**调用方：内核启动时的
  /// [ensure] 与「检查更新」的 [update]。两者必须落在同一个目录——曾经安卓端
  /// 的更新写到一个内核根本不读的临时目录，界面报告成功、内核却一直用旧规则，
  /// 用户被明确告知「已经更新」而事实并非如此。把解析收在一处，就没有第二次
  /// 分叉的机会。
  static Directory resolveTargetDir({Directory? targetDir}) =>
      targetDir ?? writableDir();

  /// 确保可写目录里有可用的规则库，缺失时从出厂副本复制。
  ///
  /// 返回可直接交给内核的目录。[targetDir] 为 null 时用 [writableDir]；
  /// 安卓端把解包目录显式传进来，避免它再去猜桌面端的路径规则。
  static Directory ensure(Directory bundledDir, {Directory? targetDir}) {
    final target = resolveTargetDir(targetDir: targetDir);
    target.createSync(recursive: true);
    // 全部内置条目都要解包：可更新的是出厂副本，构建期产物同样是随包分发的。
    for (final name in builtinFileNames) {
      final dest = File('${target.path}${Platform.pathSeparator}$name');
      if (dest.existsSync() && _looksValid(dest)) continue;
      final src = File('${bundledDir.path}${Platform.pathSeparator}$name');
      if (src.existsSync()) {
        src.copySync(dest.path);
      }
    }
    return target;
  }

  /// 从上游更新**出厂**规则库。
  ///
  /// 保留这个入口是为了兼容既有调用方；实现已收敛到 [updateMany]，
  /// 保证「先全部下载成功、再覆盖」这条原子性只有一份实现。
  static Future<RuleSetUpdateOutcome> update({Directory? targetDir}) =>
      updateMany(<({String fileName, String url})>[
        for (final entry in sources.entries)
          (fileName: entry.key, url: entry.value),
      ], targetDir: targetDir);

  /// 从上游更新一组规则集。
  ///
  /// 先全部下载到内存并校验魔数，全部成功后才逐个覆盖正式文件——
  /// 避免下载中断留下半个文件，导致内核直接起不来。
  ///
  /// [targetDir] 必须是**内核真正读取**的那个目录；为 null 时退回桌面端的
  /// [writableDir]。安卓端由内核的 `ruleSetUpdateDir` 传入解包目录。
  static Future<RuleSetUpdateOutcome> updateMany(
    List<({String fileName, String url})> targets, {
    Directory? targetDir,
  }) async {
    final target = resolveTargetDir(targetDir: targetDir);
    target.createSync(recursive: true);

    final downloaded = <String, List<int>>{};
    for (final entry in targets) {
      final bytes = await fetch(entry.url);
      if (bytes == null) {
        return RuleSetUpdateOutcome.failure('无法下载 ${entry.fileName}，请检查网络');
      }
      if (!isValidBytes(bytes)) {
        return RuleSetUpdateOutcome.failure('${entry.fileName} 的内容不是有效的规则库');
      }
      downloaded[entry.fileName] = bytes;
    }

    for (final entry in downloaded.entries) {
      writeSrs(target, entry.key, entry.value);
    }

    final totalKb =
        downloaded.values.fold<int>(0, (sum, b) => sum + b.length) ~/ 1024;
    return RuleSetUpdateOutcome.success(
      DateTime.now(),
      '规则库已更新（共 $totalKb KB）',
    );
  }

  /// 下载一个 URL 的原始字节。失败返回 null。
  ///
  /// 公开是为了让「新增自定义规则集」复用同一条下载路径——网络错误、超时与
  /// 非 200 的处理只有一份实现，界面拿到的失败原因是同一个口径。
  static Future<List<int>?> fetch(String url) async {
    try {
      final response = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) return null;
      return response.bodyBytes;
    } on Object {
      // 下载失败由调用方统一转成用户可读的提示，这里不重复处理。
      return null;
    }
  }

  /// 内容是否是有效的 `.srs`：足够长且带魔数。
  static bool isValidBytes(List<int> bytes) =>
      bytes.length >= 64 && _hasMagic(bytes);

  /// 把一份规则集原子地写进规则集目录。
  ///
  /// 先写临时文件再改名：改名在同一分区上是原子的，因此下载中断也不会留下
  /// 半个文件把内核卡在启动失败上。
  static void writeSrs(Directory target, String fileName, List<int> bytes) {
    target.createSync(recursive: true);
    final dest = File('${target.path}${Platform.pathSeparator}$fileName');
    final tmp = File('${dest.path}.tmp');
    tmp.writeAsBytesSync(bytes, flush: true);
    tmp.renameSync(dest.path);
  }

  /// 删除规则集目录里的一份文件。删不掉时静默——它只是清理，不是承诺。
  static void deleteSrs(Directory target, String fileName) {
    try {
      final file = File('${target.path}${Platform.pathSeparator}$fileName');
      if (file.existsSync()) file.deleteSync();
    } on Object {
      // 清理失败不影响功能：列表里已经不再引用它。
    }
  }

  /// 重命名规则集文件。源文件不存在时什么也不做。
  static void renameSrs(Directory target, String from, String to) {
    if (from == to) return;
    try {
      final source = File('${target.path}${Platform.pathSeparator}$from');
      if (!source.existsSync()) return;
      final dest = File('${target.path}${Platform.pathSeparator}$to');
      if (dest.existsSync()) dest.deleteSync();
      source.renameSync(dest.path);
    } on Object {
      // 改名失败交给调用方按「文件缺失」处理。
    }
  }

  static bool _hasMagic(List<int> bytes) {
    if (bytes.length < srsMagic.length) return false;
    for (var i = 0; i < srsMagic.length; i++) {
      if (bytes[i] != srsMagic[i]) return false;
    }
    return true;
  }

  static bool _looksValid(File file) {
    try {
      final raf = file.openSync();
      try {
        final head = raf.readSync(srsMagic.length);
        if (head.length < srsMagic.length) return false;
        for (var i = 0; i < srsMagic.length; i++) {
          if (head[i] != srsMagic[i]) return false;
        }
        return true;
      } finally {
        raf.closeSync();
      }
    } on Object {
      return false;
    }
  }
}

/// 规则库更新的结果。
class RuleSetUpdateOutcome {
  const RuleSetUpdateOutcome._({
    required this.succeeded,
    required this.message,
    this.updatedAt,
  });

  factory RuleSetUpdateOutcome.success(DateTime at, String message) =>
      RuleSetUpdateOutcome._(succeeded: true, message: message, updatedAt: at);

  factory RuleSetUpdateOutcome.failure(String message) =>
      RuleSetUpdateOutcome._(succeeded: false, message: message);

  final bool succeeded;
  final String message;
  final DateTime? updatedAt;
}
