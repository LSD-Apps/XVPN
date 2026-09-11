import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import 'core/auto_route.dart';
import 'core/core_log.dart';
import 'core/dns_monitor.dart';
import 'core/record_buffer.dart';
import 'core/rulesets.dart';
import 'core/startup_self_check.dart';
import 'core/store.dart';
import 'core/vpn_core.dart';
import 'format.dart';
import 'models.dart';
import 'protocols/parsed_profile.dart';
import 'protocols/protocol_adapter.dart';

/// 全局状态。界面只依赖它，不直接接触内核。
///
/// 内核通过构造函数注入：默认使用演示内核，接入 sing-box 后换成真实实现，
/// 界面与状态层的代码不需要改动。
///
/// 关于性能：分流记录是唯一「每秒都在变、又可能很长」的数据，
/// 因此它的存储与筛选都做了专门处理——见 [_recordsRing] 与 [filteredRecords]。
/// 这里的原则是：**每帧的构建里不做与数据量成正比的分配**。
class AppState extends ChangeNotifier implements VpnCoreListener {
  AppState({this.coreFactory, this.store}) {
    // 恢复必须在构造里同步做完：界面第一次 build 时就应该拿到已保存的配置，
    // 否则会先闪一下「导入配置」的空状态。
    _restore();
  }

  /// 内核工厂。默认使用演示内核，接入 sing-box 后由外部注入真实实现。
  final VpnCore Function(VpnCoreListener listener)? coreFactory;

  /// 本地持久化。为 null 时不落盘（测试与演示内核用）。
  final AppStore? store;

  /// 导入配置的原文，按 id 保存。
  ///
  /// 只存原文不存解析结果：解析结果是从原文推导出来的，存派生数据会在
  /// 解析器升级后变成一个需要迁移的历史包袱。
  final Map<String, String> _profileTexts = <String, String>{};
  final Map<String, ({String? username, String? password})> _profileCredentials =
      <String, ({String? username, String? password})>{};

  /// 用户期望的连接状态。
  ///
  /// 记的是「意图」而不是「事实」：重开应用时据此恢复到用户离开时的样子，
  /// 而不是每次都要手动点一次圆环。
  bool _wantConnected = false;

  late final VpnCore _core = coreFactory?.call(this) ?? DemoVpnCore(this);

  /// 分流记录上限，与设计稿脚注「最多保留最近 500 条」一致。
  static const recordLimit = 500;

  /// 失败记录上限。失败比成功更值得留存，但也没必要无限增长。
  static const failureLimit = 200;

  /// 迷你折线保留的采样点数量，对应设计稿统计卡里的 12 根柱子。
  static const sparkPoints = 12;

  /// 分流记录页在搜索时最多返回多少条。
  ///
  /// 列表本身是懒构建的，卡顿不来自「渲染多少行」，而来自「筛选要分配多少」。
  /// 500 条全量筛选其实很快，这个上限是为了给「记录上限被调大」留出余量，
  /// 并且向用户明确「还有更多结果」，而不是悄悄截断。
  static const searchResultLimit = 300;

  final List<VpnProfile> _profiles = <VpnProfile>[];

  /// 分流记录。环形缓冲，最新的在索引 0。
  ///
  /// 原实现是 `List.insert(0, record)` + `removeRange`：每次插入都要把
  /// 已存在的 500 条整体后移一格。每秒来几条连接时这不明显，但内核在
  /// 首次连接或批量请求时会一次推来大量连接，那时每插入一条都是一次
  /// 500 元素的搬移，界面直接卡住。环形缓冲把插入变成 O(1)。
  late final RingBuffer<SplitRecord> _recordsRing =
      RingBuffer<SplitRecord>(recordLimit);

  /// 筛选结果的缓存。
  ///
  /// 界面每次重建（每秒一次，外加任意次 setState）都会调用 [filteredRecords]。
  /// 原实现每次都全量遍历并新建列表，500 条时每秒产生 500 次字符串比较与
  /// 一个 500 元素的列表——纯浪费。这里按 (筛选条件, 查询串, 记录版本号)
  /// 缓存，只有记录真的变了才重算。
  List<SplitRecord>? _filteredCache;
  RouteFilter? _cachedFilter;
  String? _cachedQuery;
  int _cachedVersion = -1;

  /// 记录版本号。每次记录变化自增，用来让筛选缓存失效。
  int _recordsVersion = 0;

  /// 连接失败记录。这是「检测能力」的载体：把用户看到的「打不开」
  /// 翻译成「规则判错了」还是「节点不通了」。
  ///
  /// 同样用环形缓冲：失败在故障时会成批出现（例如节点掉线），
  /// 而它参与 [failureDigest] 的统计，那个统计也在每帧被调用。
  late final RingBuffer<ConnectionFailure> _failuresRing =
      RingBuffer<ConnectionFailure>(failureLimit);

  /// 失败归因摘要的缓存，理由与筛选缓存相同。
  FailureDigest? _digestCache;
  int _failuresVersion = 0;
  int _cachedDigestVersion = -1;

  final List<double> _downHistory = <double>[];
  final List<double> _upHistory = <double>[];
  final List<double> _totalHistory = <double>[];

  VpnStatus _status = VpnStatus.disconnected;
  AppSettings _settings = const AppSettings();
  String? _activeProfileId;
  String? _lastError;
  DateTime? _connectedSince;
  DateTime _ruleSetUpdatedAt = DateTime(2026, 2, 14);
  double _downBps = 0;
  double _upBps = 0;
  int _totalBytes = 0;
  int _directBytes = 0;
  int _proxiedBytes = 0;
  int _connectionCount = 0;
  int _kernelMemory = 0;
  int? _latencyMs;
  Timer? _ticker;
  bool _disposed = false;

  /// 最近一次 DNS 监测报告。
  DnsReport? _dnsReport;

  /// 最近一次启动自检报告。
  StartupSelfCheckReport? _selfCheckReport;

  /// 程序自动纠正过的域名，最新的在前。仅用于界面展示「它学会了什么」。
  final List<AutoRouteDecision> _learnedDecisions = <AutoRouteDecision>[];

  /// 保留多少条「最近学会的」记录用于展示。
  static const learnedDisplayLimit = 20;

  // ---------------------------------------------------------------- 只读视图

  VpnCore get core => _core;
  VpnStatus get status => _status;
  AppSettings get settings => _settings;
  List<VpnProfile> get profiles => List<VpnProfile>.unmodifiable(_profiles);

  /// 分流记录视图。
  ///
  /// 返回的是缓冲区的**只读包装**而不是复制：这个 getter 在每次界面重建时
  /// 都会被调用，复制 500 条元素的列表本身就是每秒一次的固定开销。
  /// 调用方只做遍历与索引访问，不修改。
  List<SplitRecord> get records => _recordsView;

  late final List<SplitRecord> _recordsView = _RingView<SplitRecord>(_recordsRing);

  List<ConnectionFailure> get failures => _failuresView;

  late final List<ConnectionFailure> _failuresView =
      _RingView<ConnectionFailure>(_failuresRing);

  /// 失败归因摘要：界面用它给出「该做什么」而不是只报「出错了」。
  ///
  /// 结果带缓存：摘要要对全部失败做一次遍历与去重，而界面每帧都会读它。
  FailureDigest get failureDigest {
    if (_cachedDigestVersion != _failuresVersion) {
      _digestCache = digestFailures(_failuresView);
      _cachedDigestVersion = _failuresVersion;
    }
    return _digestCache!;
  }

  List<double> get downHistory => List<double>.unmodifiable(_downHistory);
  List<double> get upHistory => List<double>.unmodifiable(_upHistory);
  List<double> get totalHistory => List<double>.unmodifiable(_totalHistory);
  String? get lastError => _lastError;
  DateTime get ruleSetUpdatedAt => _ruleSetUpdatedAt;
  double get downBps => _downBps;
  double get upBps => _upBps;
  int get totalBytes => _totalBytes;

  /// 走隧道 / 走直连的已传输字节。用来回答「这些流量里有多少真的进了隧道」——
  /// 这是判断分流是否按预期工作的唯一依据。
  int get directBytes => _directBytes;
  int get proxiedBytes => _proxiedBytes;

  /// 当前活连接数。
  int get connectionCount => _connectionCount;

  /// 内核报告的常驻内存字节数（0 表示尚未拿到）。
  int get kernelMemory => _kernelMemory;

  int? get latencyMs => _latencyMs;

  /// 最近一次 DNS 监测报告。尚未探测时为 null。
  DnsReport? get dnsReport => _dnsReport;

  /// 最近一次启动自检报告。尚未跑完时为 null。
  StartupSelfCheckReport? get selfCheckReport => _selfCheckReport;

  /// 最近自动纠正的域名记录。
  List<AutoRouteDecision> get learnedDecisions =>
      List<AutoRouteDecision>.unmodifiable(_learnedDecisions);

  /// 自动纠正表。为 null 表示当前内核不做学习（演示内核）。
  AutoRouteTable? get autoRoute => _core.autoRoute;

  bool get hasProfiles => _profiles.isNotEmpty;
  bool get isConnected => _status == VpnStatus.connected;
  bool get isConnecting => _status == VpnStatus.connecting;

  VpnProfile? get activeProfile {
    if (_profiles.isEmpty) return null;
    for (final p in _profiles) {
      if (p.id == _activeProfileId) return p;
    }
    return _profiles.first;
  }

  Duration get elapsed {
    final since = _connectedSince;
    if (since == null) return Duration.zero;
    return DateTime.now().difference(since);
  }

  /// 走隧道的记录条数。
  ///
  /// 保留 O(n) 的实现，但调用方（连接页的统计行）已经不再用它——
  /// 它被替换成了按字节聚合的 [proxiedBytes]，后者才是用户真正想知道的。
  /// 这里留着是为了兼容旧调用方与测试。
  int get proxyCount => _countKind(RouteKind.proxy);

  int get directCount => _countKind(RouteKind.direct);

  int _countKind(RouteKind kind) {
    var count = 0;
    final ring = _recordsRing;
    for (var i = 0; i < ring.length; i++) {
      if (ring[i]!.kind == kind) count++;
    }
    return count;
  }

  /// 按筛选条件取记录。
  ///
  /// 结果按 (筛选, 查询, 版本号) 缓存。界面在每次重建时调用它，
  /// 而重建频率是每秒一次加上任意次 setState，因此不能每次都全量重算。
  List<SplitRecord> filteredRecords(RouteFilter filter, String query) {
    if (_filteredCache != null &&
        _cachedFilter == filter &&
        _cachedQuery == query &&
        _cachedVersion == _recordsVersion) {
      return _filteredCache!;
    }

    final normalized = query.trim().toLowerCase();
    final ring = _recordsRing;
    final result = <SplitRecord>[];
    for (var i = 0; i < ring.length; i++) {
      final record = ring[i]!;
      final matchesFilter = switch (filter) {
        RouteFilter.all => true,
        RouteFilter.proxy => record.kind == RouteKind.proxy,
        RouteFilter.direct => record.kind == RouteKind.direct,
      };
      if (!matchesFilter) continue;
      if (normalized.isNotEmpty &&
          !record.target.toLowerCase().contains(normalized)) {
        continue;
      }
      result.add(record);
      if (result.length >= searchResultLimit) break;
    }

    _filteredCache = List<SplitRecord>.unmodifiable(result);
    _cachedFilter = filter;
    _cachedQuery = query;
    _cachedVersion = _recordsVersion;
    return _filteredCache!;
  }

  /// 本次筛选结果是否被上限截断。界面据此提示「还有更多」。
  bool isFilterTruncated(RouteFilter filter, String query) =>
      filteredRecords(filter, query).length >= searchResultLimit;

  // ---------------------------------------------------------------- 配置导入

  /// 导入配置文本。协议由 [VpnProtocolFactory] 按内容自动识别，
  /// 因此 WireGuard 的 .conf 与 OpenVPN 的 .ovpn 走的是同一条路径。
  ///
  /// 解析失败会抛出 [VpnConfigException]，消息是中文，由界面直接展示。
  void importConf({
    required String text,
    required String fileName,
    String? username,
    String? password,
  }) {
    final parsed = VpnProtocolFactory.parse(
      text,
      fileName,
      username: username,
      password: password,
    );
    // 以「协议 + 文本」作为身份：同一份配置重复导入会覆盖而不是新增。
    final id = stableHash('${parsed.protocol.name}|$text');
    final profile = VpnProfile(
      id: id,
      name: fileName,
      parsed: parsed,
    );

    final existing = _profiles.indexWhere((p) => p.id == id);
    if (existing >= 0) {
      _profiles[existing] = profile;
    } else {
      _profiles.add(profile);
    }
    _activeProfileId = id;
    _profileTexts[id] = text;
    _profileCredentials[id] = (username: username, password: password);
    _lastError = null;
    notifyListeners();
    _persist();

    if (_settings.autoConnectOnImport && _status == VpnStatus.disconnected) {
      unawaited(connect());
    }
  }

  void setActiveProfile(String id) {
    if (_activeProfileId == id) return;
    _activeProfileId = id;
    notifyListeners();
    _persist();
    if (_status != VpnStatus.disconnected) {
      // 切换配置意味着重建隧道，直接重连到新配置。
      unawaited(connect());
    }
  }

  void removeProfile(String id) {
    final wasActive = _activeProfileId == id;
    final wasRunning = _status != VpnStatus.disconnected;
    _profiles.removeWhere((p) => p.id == id);
    _profileTexts.remove(id);
    _profileCredentials.remove(id);
    if (wasActive) {
      _activeProfileId = _profiles.isEmpty ? null : _profiles.first.id;
      if (_profiles.isEmpty) {
        unawaited(disconnect());
      } else if (wasRunning) {
        // 与切换配置同理：隧道还挂在刚被删掉的配置上，必须按新的当前配置重建，
        // 否则界面显示的是新配置、实际走的还是旧线路。
        unawaited(connect());
      }
    }
    notifyListeners();
    _persist();
  }

  // ---------------------------------------------------------------- 连接控制

  Future<void> connect() async {
    final profile = activeProfile;
    if (profile == null) {
      _lastError = '还没有导入任何配置';
      notifyListeners();
      return;
    }
    _lastError = null;
    // 先记意图再拨号：中途失败时下次启动会重试，符合用户「我要连着」的预期。
    _wantConnected = true;
    _persist();
    await _core.connect(profile, _settings);
  }

  Future<void> disconnect() async {
    _wantConnected = false;
    _persist();
    await _core.disconnect();
  }

  /// 启动时尝试接管一个仍在运行的内核（目前只有安卓会命中）。
  ///
  /// 安卓的隧道活在前台服务里，界面进程被回收后隧道仍然在跑；不接管的话界面会
  /// 显示「未连接」而流量其实还在走隧道。
  ///
  /// 返回 true 表示确实接管到了一个正在运行的内核。
  Future<bool> adoptRunningCore() async {
    try {
      return await _core.resumeIfRunning();
    } on Object {
      // 接管失败不影响界面可用性，用户仍可手动连接。
      return false;
    }
  }

  Future<void> toggleConnection() async {
    switch (_status) {
      case VpnStatus.connected:
        await disconnect();
      case VpnStatus.connecting:
        // 连接过程中重复触发会并发跑两遍 connect()，第二次会先把刚建好的隧道拆掉。
        // 桌面端的按钮在连接中是禁用的，圆环没有禁用态，因此在这里兜住。
        return;
      case VpnStatus.disconnected:
        await connect();
    }
  }

  // ---------------------------------------------------------------- 界面维护

  void clearRecords() {
    _recordsRing.clear();
    _failuresRing.clear();
    _recordsVersion++;
    _failuresVersion++;
    // 「最近学会的」也跟着清掉：它展示的是本次会话观察到的结论，
    // 用户点了清空却还留着十几条记录，会让人以为没清干净。
    _learnedDecisions.clear();
    notifyListeners();
  }

  /// 清空一条自动纠正规则。用户可以撤销程序学到的判断。
  void clearAutoRouteRule(String domain) {
    final table = _core.autoRoute;
    if (table == null || !table.remove(domain)) return;
    _learnedDecisions.removeWhere((AutoRouteDecision d) => d.domain == domain);
    notifyListeners();
    _persist();
  }

  /// 手工指定某个域名走代理或直连。这是用户对自动判断的最终否决权。
  ///
  /// 返回是否真的写入了规则。界面据此给出反馈——用户点了「添加」却什么都没
  /// 发生（例如输入的是一个 IP，而 IP 不参与按域名的分流规则），是必须说清楚的。
  bool setDomainPreference(String domain, RoutePreference preference) {
    final table = _core.autoRoute;
    if (table == null) return false;
    // 真正的有效性判断在这里：归一化会把 IP、单标签主机名、空串都变成空串。
    if (AutoRouteTable.normalizeDomain(domain).isEmpty) return false;

    final decision = table.setUserRule(domain, preference);
    _rememberDecision(decision);
    notifyListeners();
    _persist();
    return true;
  }

  /// 淘汰长期没有新证据的学习规则。返回被淘汰的域名。
  ///
  /// 平时由内核在每次连接时自动做，这里给界面一个手工入口：
  /// 用户想立刻清理掉一批久未命中的规则时不必等到下次重连。
  List<String> pruneAutoRoute() {
    final table = _core.autoRoute;
    if (table == null) return const <String>[];
    final removed = table.evictStale();
    if (removed.isEmpty) return removed;
    _learnedDecisions.removeWhere(
      (AutoRouteDecision d) => removed.contains(d.domain),
    );
    notifyListeners();
    _persist();
    return removed;
  }

  /// 主动触发一次 DNS 监测（界面上的「重新检测」）。
  Future<void> refreshDns() async {
    await _core.refreshDns();
  }

  /// 主动触发一次启动自检。
  Future<void> runSelfCheck() async {
    await _core.runSelfCheck();
  }

  void updateSettings(AppSettings next) {
    final previous = _settings;
    _settings = next;
    if (!next.logSplits && previous.logSplits) {
      _recordsRing.clear();
      _recordsVersion++;
    }
    notifyListeners();
    _persist();
  }

  // ---------------------------------------------------------------- 持久化

  /// 从磁盘恢复配置与设置。
  ///
  /// 逐份重新解析而不是存解析结果：解析器升级后旧数据依然可用，
  /// 也不会因为模型字段变化就需要写迁移。单份解析失败只跳过这一份，
  /// 不影响其余配置——一份坏配置不该让用户丢掉全部配置。
  void _restore() {
    final data = store?.load();
    if (data == null || data.isEmpty) return;

    final savedProfiles = data['profiles'];
    if (savedProfiles is List) {
      for (final item in savedProfiles) {
        if (item is! Map) continue;
        final name = item['name'];
        final text = item['text'];
        if (name is! String || text is! String || text.isEmpty) continue;
        final username = item['username'] as String?;
        final password = item['password'] as String?;
        try {
          final parsed = VpnProtocolFactory.parse(
            text,
            name,
            username: username,
            password: password,
          );
          final id = stableHash('${parsed.protocol.name}|$text');
          _profiles.add(VpnProfile(id: id, name: name, parsed: parsed));
          _profileTexts[id] = text;
          _profileCredentials[id] = (username: username, password: password);
        } on Object {
          continue;
        }
      }
    }

    final activeId = data['activeProfileId'];
    if (activeId is String && _profiles.any((VpnProfile p) => p.id == activeId)) {
      _activeProfileId = activeId;
    } else if (_profiles.isNotEmpty) {
      _activeProfileId = _profiles.first.id;
    }

    final settings = data['settings'];
    if (settings is Map) {
      try {
        _settings = AppSettings(
          autoConnectOnImport: settings['autoConnectOnImport'] as bool? ?? true,
          // 枚举按下标存：名字改了也不会让用户的选择失效。
          splitMode:
              _enumAt(SplitMode.values, settings['splitMode'], SplitMode.smart),
          logSplits: settings['logSplits'] as bool? ?? true,
          ruleSetUpdatedAt: DateTime.tryParse(
            settings['ruleSetUpdatedAt'] as String? ?? '',
          ),
        );
      } on Object {
        _settings = const AppSettings();
      }
    }

    _wantConnected = data['wantConnected'] as bool? ?? false;

    // 自动纠正表交给内核侧恢复：它是内核的行为，不是界面的状态。
    // 放在最后，因为此时内核实例一定已经建好了。
    _core.initAutoRoute(data['autoRoute']);
  }

  /// 按下标取枚举，越界或类型不对时回退到默认值。
  static T _enumAt<T>(List<T> values, Object? raw, T fallback) {
    if (raw is int && raw >= 0 && raw < values.length) return values[raw];
    return fallback;
  }

  /// 落盘。任何一处失败都不影响界面，只是这次不持久化。
  void _persist() {
    final target = store;
    if (target == null) return;
    target.save(<String, Object?>{
      'profiles': <Object?>[
        for (final VpnProfile p in _profiles)
          if (_profileTexts[p.id] case final String text)
            <String, Object?>{
              'name': p.name,
              'text': text,
              if (_profileCredentials[p.id]?.username != null)
                'username': _profileCredentials[p.id]!.username,
              if (_profileCredentials[p.id]?.password != null)
                'password': _profileCredentials[p.id]!.password,
            },
      ],
      'activeProfileId': _activeProfileId,
      'wantConnected': _wantConnected,
      'settings': <String, Object?>{
        'autoConnectOnImport': _settings.autoConnectOnImport,
        'splitMode': _settings.splitMode.index,
        'logSplits': _settings.logSplits,
        'ruleSetUpdatedAt': _settings.ruleSetUpdatedAt?.toIso8601String(),
      },
      // 自动纠正表随设置一起落盘。它的价值是「学一次，以后都记得」，
      // 每次重启就忘掉会让用户觉得分流时好时坏。
      'autoRoute': _core.exportAutoRoute(),
    });
  }

  /// 启动时把用户离开时的连接状态接回来。
  ///
  /// 顺序很重要：先看内核是不是还在跑（安卓的隧道活在前台服务里），
  /// 只有在没有现成内核可用、而用户上次是连着的时候才重新拨号。
  Future<void> restoreConnection() async {
    final adopted = await adoptRunningCore();
    if (adopted) return;
    if (_wantConnected && activeProfile != null) {
      await connect();
    }
  }

  void dismissError() {
    if (_lastError == null) return;
    _lastError = null;
    notifyListeners();
  }

  /// 由界面层主动上报错误（例如启动参数里的配置文件读取失败）。
  void reportError(String message) {
    _lastError = message;
    notifyListeners();
  }

  /// 从上游更新规则库。
  ///
  /// 之前这里只是把显示的日期改成「今天」，并没有真的下载——属于误导性实现。
  /// 现在真的去拉取 `.srs` 并覆盖本地副本，失败时明确报错而不是假装成功。
  Future<void> refreshRuleSet() async {
    final outcome = await RuleSetStore.update();
    if (outcome.succeeded) {
      _ruleSetUpdatedAt = outcome.updatedAt ?? DateTime.now();
      _lastError = null;
    } else {
      _lastError = outcome.message;
    }
    notifyListeners();
  }

  // -------------------------------------------------------- VpnCoreListener

  @override
  void onStatusChanged(VpnStatus status) {
    _status = status;
    switch (status) {
      case VpnStatus.connected:
        _connectedSince = DateTime.now();
        _startTicker();
      case VpnStatus.disconnected:
      case VpnStatus.connecting:
        _connectedSince = null;
        _stopTicker();
        // 每次重新连接都从干净的失败记录开始，避免旧失败误导判断。
        if (status == VpnStatus.connecting) {
          _failuresRing.clear();
          _failuresVersion++;
        }
        if (status == VpnStatus.disconnected) {
          _downBps = 0;
          _upBps = 0;
          _latencyMs = null;
          _directBytes = 0;
          _proxiedBytes = 0;
          _connectionCount = 0;
          _pushSpark(0, 0);
          // 断开后 DNS 与自检的结论已经过期，留着会误导。
          // 自动纠正表不清：那是学到的长期结论，与本次会话无关。
          _dnsReport = null;
          _selfCheckReport = null;
        }
    }
    notifyListeners();
  }

  @override
  void onTraffic({
    required double downBps,
    required double upBps,
    required int totalBytes,
    int directBytes = 0,
    int proxiedBytes = 0,
    int connectionCount = 0,
    int kernelMemory = 0,
  }) {
    _downBps = downBps;
    _upBps = upBps;
    _totalBytes = totalBytes;
    _directBytes = directBytes;
    _proxiedBytes = proxiedBytes;
    _connectionCount = connectionCount;
    _kernelMemory = kernelMemory;
    _pushSpark(downBps, upBps);
    notifyListeners();
  }

  @override
  void onLatency(int? millis) {
    _latencyMs = millis;
    notifyListeners();
  }

  @override
  void onSplitRecord(SplitRecord record) {
    if (!_settings.logSplits) return;
    _recordsRing.push(record);
    _recordsVersion++;
    notifyListeners();
  }

  @override
  void onConnectionFailure(ConnectionFailure failure) {
    _failuresRing.push(failure);
    _failuresVersion++;
    notifyListeners();
  }

  @override
  void onDnsReport(DnsReport report) {
    _dnsReport = report;
    notifyListeners();
  }

  @override
  void onSelfCheck(StartupSelfCheckReport report) {
    _selfCheckReport = report;
    notifyListeners();
  }

  @override
  void onAutoRouteLearned(AutoRouteDecision decision) {
    _rememberDecision(decision);
    notifyListeners();
    // 学到的规则要尽快落盘：它决定下一次连接的路由表。
    _persist();
  }

  @override
  void onAutoRouteChanged(AutoRouteTable table) {
    notifyListeners();
  }

  /// 记下一条自动纠正结论，供界面展示。只保留最近若干条。
  void _rememberDecision(AutoRouteDecision decision) {
    _learnedDecisions.removeWhere((AutoRouteDecision d) => d.domain == decision.domain);
    _learnedDecisions.insert(0, decision);
    if (_learnedDecisions.length > learnedDisplayLimit) {
      _learnedDecisions.removeRange(learnedDisplayLimit, _learnedDecisions.length);
    }
  }

  @override
  void onError(String message) {
    _lastError = message;
    notifyListeners();
  }

  // ---------------------------------------------------------------- 内部工具

  void _pushSpark(double down, double up) {
    _downHistory.add(down);
    _upHistory.add(up);
    _totalHistory.add((down + up));
    while (_downHistory.length > sparkPoints) {
      _downHistory.removeAt(0);
    }
    while (_upHistory.length > sparkPoints) {
      _upHistory.removeAt(0);
    }
    while (_totalHistory.length > sparkPoints) {
      _totalHistory.removeAt(0);
    }
  }

  void _startTicker() {
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) => notifyListeners());
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  @override
  void dispose() {
    // 幂等：外壳与入口都可能触发释放，重复调用不应抛错。
    if (_disposed) return;
    _disposed = true;
    _stopTicker();
    _core.dispose();
    super.dispose();
  }
}

/// 分流记录页的筛选条件。
enum RouteFilter { all, proxy, direct }

extension RouteFilterX on RouteFilter {
  String get label => switch (this) {
        RouteFilter.all => '全部',
        RouteFilter.proxy => '走代理',
        RouteFilter.direct => '直连',
      };
}

/// 把 [RingBuffer] 包装成只读的 `List`。
///
/// 界面代码（`ListView.builder`、`records.take(3)`、测试里的 `records[0]`）
/// 都按 `List` 使用记录，因此这里保持同一个接口，只在背后换成环形缓冲。
/// 写操作一律抛出——记录只能通过 `onSplitRecord` 进来，这样版本号才不会被绕过。
///
/// 之所以不直接返回 `List.unmodifiable(ring.values.toList())`：那会在每次读取时
/// 复制一遍，而 `records` 在每次界面重建时都会被读到，复制就成了每秒一次的固定开销。
class _RingView<T> extends ListBase<T> {
  _RingView(this._ring);

  final RingBuffer<T> _ring;

  @override
  int get length => _ring.length;

  @override
  set length(int value) =>
      throw UnsupportedError('记录视图是只读的');

  @override
  T operator [](int index) {
    final value = _ring[index];
    if (value == null) {
      throw RangeError.index(index, this, 'index', null, _ring.length);
    }
    return value;
  }

  @override
  void operator []=(int index, T value) =>
      throw UnsupportedError('记录视图是只读的');
}
