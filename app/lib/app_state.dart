import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'core/app_presets.dart';
import 'core/auto_route.dart';
import 'core/cn_ip_index.dart';
import 'core/cn_ip_sync.dart';
import 'core/core_log.dart';
import 'core/dns_monitor.dart';
import 'core/domain_check.dart';
import 'core/mtu_probe.dart';
import 'core/node_region.dart';
import 'core/record_buffer.dart';
import 'core/route_pack.dart';
import 'core/rulesets.dart';
import 'core/secret_protector.dart';
import 'core/subscription_fetch.dart';
import 'core/singbox_runner.dart';
import 'core/startup_self_check.dart';
import 'core/store.dart';
import 'core/tunnel_report.dart';
import 'core/tunnel_health.dart';
import 'core/vpn_core.dart';
import 'core/wireguard_handshake.dart';
import 'format.dart';
import 'models.dart';
import 'protocols/parsed_profile.dart';
import 'protocols/protocol_adapter.dart';
import 'protocols/subscription.dart';

/// 全局状态。界面只依赖它，不直接接触内核。
///
/// 内核通过构造函数注入：默认使用演示内核，接入 sing-box 后换成真实实现，
/// 界面与状态层的代码不需要改动。
///
/// 关于性能：分流记录是唯一「每秒都在变、又可能很长」的数据，
/// 因此它的存储与筛选都做了专门处理——见 [_recordsRing] 与 [filteredRecords]。
/// 这里的原则是：**每帧的构建里不做与数据量成正比的分配**。
class AppState extends ChangeNotifier implements VpnCoreListener {
  AppState({
    this.coreFactory,
    this.store,
    SecretProtector? protector,
    this.ruleSetFetcher,
    this.subscriptionFetcher,
  }) : protector = protector ?? SecretProtector.forPlatform() {
    // 恢复必须在构造里同步做完：界面第一次 build 时就应该拿到已保存的配置，
    // 否则会先闪一下「导入配置」的空状态。
    _restore();
  }

  /// 内核工厂。默认使用演示内核，接入 sing-box 后由外部注入真实实现。
  final VpnCore Function(VpnCoreListener listener)? coreFactory;

  /// 本地持久化。为 null 时不落盘（测试与演示内核用）。
  final AppStore? store;

  /// 自定义规则集的下载器。可注入，测试里用它避开真实网络。
  ///
  /// 缺省走 [RuleSetStore.fetch]：真实实现只此一条，注入点存在的意义是让
  /// 「新增一个自定义规则集」这条路径能被自动化验证，而不必真的联网。
  final Future<List<int>?> Function(String url)? ruleSetFetcher;

  /// 订阅 URL 的拉取。缺省走 [fetchSubscription]；测试注入假实现，不碰网络。
  final Future<SubscriptionFetchResult> Function(String url)?
      subscriptionFetcher;

  /// 账号密码的落盘保护。见 [SecretProtector]。
  ///
  /// 可注入是为了让「密码确实是加密后写盘的」这件事能被测到，
  /// 而不是只能在真实机器上翻 config.json 用肉眼确认。
  final SecretProtector protector;

  /// 导入配置的原文，按 id 保存。
  ///
  /// 只存原文不存解析结果：解析结果是从原文推导出来的，存派生数据会在
  /// 解析器升级后变成一个需要迁移的历史包袱。
  final Map<String, String> _profileTexts = <String, String>{};
  final Map<String, ({String? username, String? password})>
  _profileCredentials = <String, ({String? username, String? password})>{};

  /// 用户期望的连接状态。
  ///
  /// 记的是「意图」而不是「事实」：重开应用时据此恢复到用户离开时的样子，
  /// 而不是每次都要手动点一次圆环。
  bool _wantConnected = false;

  /// 是否已在本机确认过法律与使用声明。
  ///
  /// 全新安装默认未确认，启动后挡住界面直到用户点「我已了解」。
  /// 没有持久化（测试 / 演示）时视为已确认，否则每个 widget 测试都会被挡。
  /// 升级上来的旧存档没有这个字段：视为已确认，避免突然挡住老用户。
  bool _legalNoticeAcknowledged = true;

  /// 当前在飞的连接尝试的取消令牌。null 表示没有用户发起的尝试在飞
  /// （未连接、已连接，或正在自动重连）。
  ConnectAttempt? _connectAttempt;

  /// 连接尝试的代际号。每次用户发起连接自增，便于测试与日志区分是哪一轮。
  int _connectGeneration = 0;

  /// 上一轮 `_core.connect` 的 Future，用来把两轮连接**串行化**。
  ///
  /// 内核的进程句柄与系统代理都是全局资源，两轮同时在飞时，旧的一轮可能在
  /// 任意 await 之后把新一轮刚设好的代理覆盖掉或撤掉。让新一轮等旧一轮彻底
  /// 收手，整类竞态就不存在了，而不必在每个副作用上再叠一层归属判断。
  Future<void>? _inFlightConnect;

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
  final List<ProfileSubscription> _subscriptions = <ProfileSubscription>[];

  /// 分流记录。环形缓冲，最新的在索引 0。
  ///
  /// 原实现是 `List.insert(0, record)` + `removeRange`：每次插入都要把
  /// 已存在的 500 条整体后移一格。每秒来几条连接时这不明显，但内核在
  /// 首次连接或批量请求时会一次推来大量连接，那时每插入一条都是一次
  /// 500 元素的搬移，界面直接卡住。环形缓冲把插入变成 O(1)。
  late final RingBuffer<SplitRecord> _recordsRing = RingBuffer<SplitRecord>(
    recordLimit,
  );

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

  /// 隧道流量去向的缓存，理由与筛选缓存相同（见 [tunnelVolume]）。
  List<TunnelVolumeEntry>? _tunnelVolumeCache;
  int _cachedTunnelVersion = -1;
  int? _tunnelTotalCache;
  int _cachedTunnelTotalVersion = -1;

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

  VpnStatus _status = VpnStatus.disconnected;

  /// 默认设置。
  ///
  /// 不直接用 `const AppSettings()`：应用直连预置里有一项（直连站点补充）是
  /// **默认启用**的，而默认值需要从 `AppPresets` 推导。放在这里集中一次，
  /// 三个「从头建设置」的入口（初始值、存档缺键、解析失败回退）就不会各写一份。
  static AppSettings defaultSettings() =>
      AppSettings(enabledAppPresets: AppPresets.defaultEnabledIds());

  AppSettings _settings = AppState.defaultSettings();
  String? _activeProfileId;
  String? _lastError;
  DateTime? _connectedSince;
  DateTime _ruleSetUpdatedAt = DateTime(2026, 2, 14);

  /// 上一次连接尝试失败的原因，**已经是一句用户能读懂的话**。
  ///
  /// 与 [_lastError] **刻意分开**，因为它们要活的时间完全不同：[_lastError] 是
  /// 一次性的通知，界面用 SnackBar 呈现，四秒后消失并当场清空。若圆环的失败态
  /// 也挂在它上面，用户看到的就只是圆环从「连接中」直接退回「未连接」——
  /// 一次失败被说成了「从来没试过」，重试也没有落点。
  ///
  /// 这一份留到下一次尝试开始、连上、用户主动断开或清除为止。**不落盘**：
  /// 上一次运行留下来的失败原因对现在没有任何意义，重启后应当回到中性态。
  String? _connectFailure;

  /// 失败原因的**技术原文**（内核或平台抛出来的那一句），只喂给「详情」弹窗。
  ///
  /// 与 [_connectFailure] 分开，是因为它们给两种人看：主视线上的那一句给只想
  /// 「知道下一步点什么」的用户，这里这一句给愿意翻日志、要把问题报出来的人。
  /// 原文一个字都不删——排查时它是唯一的事实来源，界面上少显示它，不构成把它
  /// 丢掉的理由。没有技术原文时（例如「还没有导入配置」）为 null。
  String? _connectFailureDetail;

  /// 规则集（内置 + 自定义）。默认是两份出厂规则集，均启用。
  ///
  /// 恢复时若存档里有 `ruleSets` 键就整份采用——「删掉一个内置规则集」因此
  /// 是持久的，直到用户主动「恢复内置规则」。键缺失（旧存档）才回落到出厂值。
  List<RuleSetEntry> _ruleSets = RuleSetStore.defaultEntries();
  double _downBps = 0;
  double _upBps = 0;
  int _totalBytes = 0;
  int _directBytes = 0;
  int _proxiedBytes = 0;

  /// 会话累计（按目标累加），见 [sessionProxiedBytes]。
  int _sessionProxiedBytes = 0;
  int _sessionDirectBytes = 0;
  int _connectionCount = 0;
  int _kernelMemory = 0;
  int? _latencyMs;
  Timer? _ticker;
  bool _disposed = false;

  /// 最近一次 DNS 监测报告。
  DnsReport? _dnsReport;

  /// 最近一次启动自检报告。
  StartupSelfCheckReport? _selfCheckReport;

  /// 最近一次隧道健康结论。为 null 表示还没有结论（未连接或尚未探测）。
  TunnelHealth? _tunnelHealth;

  /// 由健康结论写入的那条错误提示。
  ///
  /// 单记一份是为了在隧道恢复后**只**撤掉自己写的那句：直接清 _lastError
  /// 会把同时存在的其它错误（例如系统代理设置失败）一起抹掉。
  String? _healthNotice;

  /// 程序自动纠正过的域名，最新的在前。仅用于界面展示「它学会了什么」。
  final List<AutoRouteDecision> _learnedDecisions = <AutoRouteDecision>[];

  /// 保留多少条「最近学会的」记录用于展示。
  static const learnedDisplayLimit = 20;

  // ---------------------------------------------------------------- 只读视图

  VpnCore get core => _core;
  VpnStatus get status => _status;
  AppSettings get settings => _settings;

  /// 本机是否已确认法律与使用声明。未确认时界面盖一层说明，不能先连上再读。
  bool get legalNoticeAcknowledged => _legalNoticeAcknowledged;

  /// 用户确认已了解「自备合法配置、用途自负」。只记在本机，可在设置页再读全文。
  void acknowledgeLegalNotice() {
    if (_legalNoticeAcknowledged) return;
    _legalNoticeAcknowledged = true;
    notifyListeners();
    _persist();
  }

  List<VpnProfile> get profiles => List<VpnProfile>.unmodifiable(_profiles);

  List<ProfileSubscription> get subscriptions =>
      List<ProfileSubscription>.unmodifiable(_subscriptions);

  ProfileSubscription? subscriptionById(String? id) {
    if (id == null) return null;
    for (final item in _subscriptions) {
      if (item.id == id) return item;
    }
    return null;
  }

  /// 当前节点服务器是否落在国内网段。主机名在连接前无法判定。
  AddressRegion get activeNodeRegion {
    final profile = activeProfile;
    if (profile == null) return AddressRegion.unknown;
    return classifyNodeRegion(_core.cnIpIndex, profile.parsed);
  }

  /// 分流记录视图。
  ///
  /// 返回的是缓冲区的**只读包装**而不是复制：这个 getter 在每次界面重建时
  /// 都会被调用，复制 500 条元素的列表本身就是每秒一次的固定开销。
  /// 调用方只做遍历与索引访问，不修改。
  List<SplitRecord> get records => _recordsView;

  late final List<SplitRecord> _recordsView = _RingView<SplitRecord>(
    _recordsRing,
  );

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
  String? get lastError => _lastError;

  /// 上一次连接尝试失败的原因（一句人话）；没有失败过时为 null。
  /// 见 [_connectFailure]。
  String? get connectFailure => _connectFailure;

  /// 同一个失败的技术原文，供「详情」弹窗展示；没有则为 null。
  /// 见 [_connectFailureDetail]。
  String? get connectFailureDetail => _connectFailureDetail;

  /// 是否应当把圆环画成失败态：失败过、而且现在既没连上也没在重试。
  ///
  /// 「没在重试」这一条不能省：用户点了重试之后圆环必须立刻回到「连接中」，
  /// 否则他按下的动作在界面上没有任何回应，只会以为按钮坏了。
  bool get connectFailed =>
      _connectFailure != null && !isConnected && !isConnecting;

  DateTime get ruleSetUpdatedAt => _ruleSetUpdatedAt;

  /// 规则集视图。界面只读它，改动一律走这里的方法。
  List<RuleSetEntry> get ruleSets => List<RuleSetEntry>.unmodifiable(_ruleSets);

  /// `cn-ip.bin` 与当前 geoip `.srs` 是否同源。未检查过时为 null。
  CnIpSyncReport? get cnIpSync => _cnIpSync;
  CnIpSyncReport? _cnIpSync;
  double get downBps => _downBps;
  double get upBps => _upBps;

  /// 本次连接流量：内核自本次连接起累计的上下行总和。
  ///
  /// 用户语言叫「本次连接」——断开归零。它不分隧道/直连；要看占比请看
  /// [sessionProxiedBytes]。
  int get totalBytes => _totalBytes;

  /// 走隧道 / 走直连的已传输字节（兼容字段）。
  ///
  /// 真实内核路径不再每秒遍历活连接填这两个值（界面占比用 [sessionProxiedBytes]）；
  /// 演示内核仍会写入，供旧测试与演示面板对照。新代码请读 session*。
  int get directBytes => _directBytes;
  int get proxiedBytes => _proxiedBytes;

  /// 本次连接内观测到的隧道 / 直连字节（按连接增量累加）。
  ///
  /// 用户语言叫「隧道/直连」占比：回答「已看到的流量里，有多少进了隧道」。
  /// 与 [totalBytes]（「本次连接」= 内核全局累计）口径不同——这里按连接观测，
  /// 首次见到即计入，之后按 up/down 精确差分；仍可能略少于内核总量（关闭前
  /// 最后约 0～1 秒、以及 DNS 流量），但不会虚高，也不会像活连接快照那样
  /// 常年停在 0%。
  ///
  /// 生命周期与「本次连接」对齐：断开归零；点「清空」也归零。跨次连接不累加。
  int get sessionProxiedBytes => _sessionProxiedBytes;
  int get sessionDirectBytes => _sessionDirectBytes;

  /// 当前活连接数。
  int get connectionCount => _connectionCount;

  /// 内核报告的常驻内存字节数（0 表示尚未拿到）。
  int get kernelMemory => _kernelMemory;

  int? get latencyMs => _latencyMs;

  /// 最近一次 DNS 监测报告。尚未探测时为 null。
  DnsReport? get dnsReport => _dnsReport;

  /// 最近一次启动自检报告。尚未跑完时为 null。
  StartupSelfCheckReport? get selfCheckReport => _selfCheckReport;

  /// 最近一次隧道健康结论。尚未探测或已断开时为 null。
  TunnelHealth? get tunnelHealth => _tunnelHealth;

  /// 内核日志，最旧的在前。界面用于展示与复制。
  ///
  /// 出问题时这是唯一的原始材料：界面上看到的是「连不上」这类结论，而内核在
  /// 日志里写明了它做了哪个判定、走的哪个出站、失败在哪一步。
  List<String> get kernelLog => _core.kernelLog.lines;

  /// 因为容量上限被丢弃的日志行数。大于 0 时界面要如实说明「更早的看不到了」。
  int get kernelLogDropped => _core.kernelLog.droppedLines;

  /// 清空内核日志。由用户显式触发——程序不自动清，因为跨重连保留的
  /// 「崩之前那几行」正是排查时最需要的。
  void clearKernelLog() {
    _core.kernelLog.clear();
    notifyListeners();
  }

  /// 最近自动纠正的域名记录。
  List<AutoRouteDecision> get learnedDecisions =>
      List<AutoRouteDecision>.unmodifiable(_learnedDecisions);

  /// 自动纠正表。为 null 表示当前内核不做学习（演示内核）。
  AutoRouteTable? get autoRoute => _core.autoRoute;

  /// 内置的应用直连预置清单。界面据此渲染开关。
  List<AppPreset> get appPresets => AppPresets.all;

  /// 已启用的预置 id。生成内核配置时据此决定注入哪些直连规则。
  List<String> get enabledAppPresets =>
      List<String>.unmodifiable(_settings.enabledAppPresets);

  /// 最近观测到的 WireGuard 握手状态。
  ///
  /// 两端都由共用的内核日志管线喂出来，因此这里不需要按平台分支。
  WireGuardHandshake get handshake => _core.handshake;

  /// 本平台能否报告握手状态。为 false 时界面整行不显示。
  bool get supportsHandshakeState => _core.supportsHandshakeState;

  /// 界面层对「本平台能否报告握手状态」的覆盖值，仅用于测试。
  ///
  /// 存在的理由很具体：能力标志定义在**内核**侧（桌面 true / 安卓 false），
  /// 而 widget 测试里注入的替身内核无法在两个平台标签之间切换。没有这个注入点，
  /// 「安卓不显示握手行」这条分支就只能靠真机去撞——而它恰恰是真机上崩过一次
  /// 才发现的。
  bool? debugSupportsHandshakeOverride;

  /// 界面实际使用的判定：覆盖值优先。
  bool get handshakeVisible =>
      debugSupportsHandshakeOverride ?? supportsHandshakeState;

  bool get hasProfiles => _profiles.isNotEmpty;
  bool get isConnected => _status == VpnStatus.connected;

  /// 隧道正在建立（含预热）。
  ///
  /// 预热态对按钮而言与「连接中」完全一致——都不该让用户再点一次连接，
  /// 否则会并发跑两遍 connect()。因此这里合并成一个判断。
  bool get isConnecting =>
      _status == VpnStatus.connecting || _status == VpnStatus.warmingUp;

  /// 内核已就绪、但隧道还不能载流量。界面据此给出「正在建立隧道」而不是
  /// 干脆的「连接中」，让那几秒等待有明确解释。
  bool get isWarmingUp => _status == VpnStatus.warmingUp;

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

  /// 走隧道的目标按流量降序。回答「隧道带宽被谁占了」。
  ///
  /// 带缓存，理由与 [filteredRecords] 相同：界面每帧都会读它，而排序是
  /// 与记录数成正比的分配。只有记录真的变了（[_recordsVersion] 自增）才重算。
  List<TunnelVolumeEntry> get tunnelVolume {
    if (_tunnelVolumeCache != null && _cachedTunnelVersion == _recordsVersion) {
      return _tunnelVolumeCache!;
    }
    _tunnelVolumeCache = rankTunnelTargets(
      _recordsView,
      table: _core.autoRoute,
    );
    _cachedTunnelVersion = _recordsVersion;
    return _tunnelVolumeCache!;
  }

  /// 走隧道的总字节数（本次会话内被观察到的连接）。
  ///
  /// 与 [sessionProxiedBytes] 的口径不同：后者按流量增量累加、不受记录淘汰影响；
  /// 这里是对**当前留存记录**求和，用于说明「这份清单覆盖了多少」。
  int get tunnelVolumeTotalBytes {
    if (_tunnelTotalCache != null && _cachedTunnelTotalVersion == _recordsVersion) {
      return _tunnelTotalCache!;
    }
    _tunnelTotalCache = tunnelVolumeTotal(_recordsView);
    _cachedTunnelTotalVersion = _recordsVersion;
    return _tunnelTotalCache!;
  }

  /// 把一条隧道流量去向改为直连。返回是否写入成功（IP 目标会失败）。
  bool preferDirectFor(String domain) =>
      setDomainPreference(domain, RoutePreference.forceDirect);

  // ---------------------------------------------------------------- 配置导入

  /// 导入配置文本。协议由 [VpnProtocolFactory] 按内容自动识别，
  /// 因此 WireGuard 的 .conf 与 OpenVPN 的 .ovpn 走的是同一条路径。
  ///
  /// 解析失败会抛出 [VpnConfigException]，消息是中文，由界面直接展示。
  ImportOutcome importConf({
    required String text,
    required String fileName,
    String? username,
    String? password,
    String? subscriptionId,
    bool autoConnect = true,
  }) {
    final parsed = VpnProtocolFactory.parse(
      text,
      fileName,
      username: username,
      password: password,
    );
    // 以「协议 + 文本」作为身份：同一份配置重复导入会覆盖而不是新增。
    final id = stableHash('${parsed.protocol.name}|$text');
    final existing = _profiles.indexWhere((p) => p.id == id);
    // 归属是累加的：这份节点既然出现在来源 A 又被来源 B 导入，那它就同时属于
    // 两者。不清空原有归属，否则后导入的那一份会把节点从先前的来源里「抢走」，
    // 而那份来源的刷新与删除仍以为自己管着它。
    final subs = <String>{
      if (existing >= 0) ..._profiles[existing].subscriptionIds,
      ?subscriptionId,
    };
    final profile = VpnProfile(
      id: id,
      name: fileName,
      parsed: parsed,
      subscriptionIds: subs,
    );

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

    // 需要账号密码而这次没带：**先告诉调用方**，由界面弹表单补填。
    // 注意配置此时已经导入成功——用户中途取消填写也只是「暂时连不上」，
    // 不会丢掉刚导入的配置。
    if (_needsCredentials(id)) {
      return ImportOutcome.needsCredentials;
    }

    if (autoConnect &&
        _settings.autoConnectOnImport &&
        _status == VpnStatus.disconnected) {
      unawaited(connect());
    }
    return ImportOutcome.imported;
  }

  /// 导入用户自备的多节点清单。不会自动连接——有多条时不该替用户挑。
  SubscriptionImportResult importSubscription({
    required SubscriptionDocument document,
    required String name,
    String? url,
    String? replaceId,
  }) {
    final ready = materialize(document);
    if (ready.nodes.isEmpty) {
      throw VpnConfigException(
        ready.skipped.isEmpty
            ? '这份内容里没有可导入的节点'
            : '没有可导入的节点：${ready.skipped.join('；')}',
      );
    }
    final id = replaceId ??
        ((url != null && url.isNotEmpty)
            ? stableHash('sub|$url')
            : stableHash('sub|$name|${ready.nodes.first.text}'));
    final previousActive = _activeProfileId;
    _detachSubscription(id);
    _subscriptions.removeWhere((ProfileSubscription s) => s.id == id);
    _subscriptions.add(
      ProfileSubscription(
        id: id,
        name: name,
        url: url ?? '',
        fetchedAt: DateTime.now(),
        userinfo: ready.userinfo,
      ),
    );
    String? firstId;
    for (final node in ready.nodes) {
      importConf(
        text: node.text,
        fileName: node.name,
        subscriptionId: id,
        autoConnect: false,
      );
      firstId ??= _activeProfileId;
    }
    if (previousActive != null &&
        _profiles.any((VpnProfile p) => p.id == previousActive)) {
      _activeProfileId = previousActive;
    } else {
      _activeProfileId = firstId;
    }
    notifyListeners();
    _persist();
    return SubscriptionImportResult(
      imported: ready.nodes.length,
      skipped: ready.skipped,
    );
  }

  Future<SubscriptionImportResult> importSubscriptionFromUrl(
    String url, {
    String? name,
  }) async {
    final fetch = subscriptionFetcher ?? fetchSubscription;
    final result = await fetch(url);
    final raw = parseSubscriptionBody(
      result.body,
      userinfo: result.userinfo,
      fallbackName: name ?? '节点',
    );
    if (raw == null || raw.nodes.isEmpty) {
      throw VpnConfigException(
        '订阅正文不是分享链接列表、sing-box JSON 或多条 Clash proxies',
      );
    }
    final uri = Uri.tryParse(url.trim());
    return importSubscription(
      document: raw,
      name: name ?? uri?.host ?? '订阅',
      url: url.trim(),
    );
  }

  Future<SubscriptionImportResult> refreshSubscription(String id) async {
    final existing = subscriptionById(id);
    if (existing == null || existing.url.isEmpty) {
      throw VpnConfigException('这份导入没有可刷新的地址，请重新粘贴订阅 URL');
    }
    final fetch = subscriptionFetcher ?? fetchSubscription;
    final result = await fetch(existing.url);
    final raw = parseSubscriptionBody(
      result.body,
      userinfo: result.userinfo,
      fallbackName: existing.name,
    );
    if (raw == null || raw.nodes.isEmpty) {
      throw VpnConfigException('刷新后的正文里没有可导入的节点');
    }
    return importSubscription(
      document: raw,
      name: existing.name,
      url: existing.url,
      replaceId: id,
    );
  }

  /// 把某份订阅的归属从配置上摘掉——**只**摘这一份。
  ///
  /// 只属于它的配置一并删除（那是刷新前的旧节点）；同时属于别处的配置必须留下，
  /// 否则刷新一份来源会把另一份来源的节点也删掉，而用户看到的是一份完好的列表
  /// 突然少了几条。
  void _detachSubscription(String id) {
    final leftover = <VpnProfile>[];
    for (final profile in _profiles) {
      if (!profile.subscriptionIds.contains(id)) {
        leftover.add(profile);
        continue;
      }
      final rest = <String>{...profile.subscriptionIds}..remove(id);
      if (rest.isEmpty) {
        _profileTexts.remove(profile.id);
        _profileCredentials.remove(profile.id);
        continue;
      }
      leftover.add(
        VpnProfile(
          id: profile.id,
          name: profile.name,
          parsed: profile.parsed,
          subscriptionIds: rest,
        ),
      );
    }
    _profiles
      ..clear()
      ..addAll(leftover);
  }

  /// 这份配置所属的、带 URL 因而**可以刷新**的订阅来源。
  ///
  /// 一份配置可能同时属于多份来源，刷新其中任意一份都会把它更新到最新，
  /// 因此取第一个即可：按钮只做一件事，不摆出「刷新哪一份」的选择题。
  ProfileSubscription? refreshableSubscriptionOf(VpnProfile profile) {
    for (final id in profile.subscriptionIds) {
      final sub = subscriptionById(id);
      if (sub != null && sub.url.isNotEmpty) return sub;
    }
    return null;
  }

  /// 把一份规则包写入自动纠正表，变成手工规则。
  int importRoutePackText(String text) {
    final table = _core.autoRoute;
    if (table == null) {
      throw VpnConfigException('当前内核不支持域名分流规则');
    }
    final added = importRoutePack(table, parseRoutePack(text));
    notifyListeners();
    _persist();
    return added;
  }

  String exportRoutePackText() {
    final table = _core.autoRoute;
    if (table == null) return '';
    return exportRoutePack(table).encode();
  }

  /// 这份配置是否「需要账号密码但还没填」。
  bool _needsCredentials(String id) {
    final credentials = _profileCredentials[id];
    return _profileById(id)?.parsed.requiresCredentials == true &&
        (credentials?.username == null || credentials?.password == null);
  }

  /// 某份配置是否还需要用户补填账号密码。界面据此显示提示入口。
  bool profileNeedsCredentials(String id) => _needsCredentials(id);

  VpnProfile? _profileById(String id) {
    for (final profile in _profiles) {
      if (profile.id == id) return profile;
    }
    return null;
  }

  /// 这份配置是否保存了账号密码。
  bool profileHasCredentials(String id) {
    final credentials = _profileCredentials[id];
    return credentials?.username != null && credentials?.password != null;
  }

  /// 补填或修改某份配置的账号密码。
  ///
  /// 刻意不走 [importConf]：那个入口的副作用是「把它设为当前配置并按设置自动
  /// 连接」，而给一份**没在用**的配置补密码不该顺手把隧道切过去。
  void setProfileCredentials(
    String id, {
    required String username,
    required String password,
  }) {
    final text = _profileTexts[id];
    final name = _profileById(id)?.name;
    if (text == null || name == null) return;

    final parsed = VpnProtocolFactory.parse(
      text,
      name,
      username: username,
      password: password,
    );
    // 原文没变，因此 id 也不会变；这里仍然按解析结果重算一次，
    // 避免依赖「id 一定相同」这个隐含前提。
    final targetId = stableHash('${parsed.protocol.name}|$text');
    final index = _profiles.indexWhere((VpnProfile p) => p.id == targetId);
    if (index < 0) return;

    _profiles[index] = VpnProfile(
      id: targetId,
      name: name,
      parsed: parsed,
      subscriptionIds: _profiles[index].subscriptionIds,
    );
    _profileCredentials[targetId] = (username: username, password: password);
    _lastError = null;
    notifyListeners();
    _persist();

    // 隧道正连在这份配置上：凭据变了必须重建，否则内核里用的还是旧凭据
    // （或者根本没凭据），而界面显示「已连接」。
    if (_activeProfileId == targetId && _status != VpnStatus.disconnected) {
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
    final subIds = _profileById(id)?.subscriptionIds ?? const <String>{};
    _profiles.removeWhere((p) => p.id == id);
    _profileTexts.remove(id);
    _profileCredentials.remove(id);
    // 来源记录只在**没有任何配置**再用它时删除：删掉一份共享的节点不等于
    // 删掉整份订阅，否则另一份来源下还挂着的节点会失去刷新入口。
    for (final subId in subIds) {
      if (!_profiles.any((VpnProfile p) => p.subscriptionIds.contains(subId))) {
        _subscriptions.removeWhere((ProfileSubscription s) => s.id == subId);
      }
    }
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
      _failConnect(_lastError!);
      notifyListeners();
      return;
    }
    // 需要账号密码却还没填：绝不能带着空凭据去建隧道。
    //
    // 真让它连下去，内核会照常启动、界面显示「已连接」，然后所有网页都打不开，
    // 内核日志里只有一句握手失败——用户完全无从判断问题出在一行没填的输入框上。
    //
    // 这一句是**指令**而不是报错，因此原样显示在失败行上：它说的正是用户下一步
    // 要做的事，而其余的技术细节在这个处境里根本不存在。
    if (_needsCredentials(profile.id)) {
      _lastError = '「${profile.name}」需要账号密码，请先在配置页填写后再连接';
      _failConnect(_lastError!);
      notifyListeners();
      return;
    }

    // 新的一轮：作废上一轮仍在飞的尝试。它可能在任意 await 之后醒来，若不带上
    // 「已被取代」这个信息，就会把新一轮刚建立的状态覆盖掉。
    _connectAttempt?.cancel();
    final attempt = ConnectAttempt(++_connectGeneration);
    _connectAttempt = attempt;
    _lastError = null;
    // 上一轮的失败结论到此为止：新一轮正在进行，圆环该回到「连接中」。
    _clearConnectFailure();
    // 先记意图再拨号：中途失败时下次启动会重试，符合用户「我要连着」的预期。
    _wantConnected = true;
    _persist();

    // 等上一轮真正收手，再发起新一轮（见 [_inFlightConnect]）。等待期间用户
    // 可能点了取消，状态也可能已经被释放，因此醒来后要复查。
    final previous = _inFlightConnect;
    if (previous != null) {
      try {
        await previous;
      } on Object {
        // 上一轮的失败与本轮无关。
      }
    }
    if (_disposed || attempt.isCancelled) return;

    final run = _core.connect(profile, _settings, attempt: attempt);
    _inFlightConnect = run;
    try {
      await run;
    } finally {
      if (identical(_inFlightConnect, run)) _inFlightConnect = null;
    }
    // 核心返回后复查：本轮若已被取消/取代，绝不再碰状态。状态与错误都由核心
    // 经回调更新，这里只是不给自己记「本轮已结束」的账。
    if (attempt.isCancelled) return;
    if (identical(_connectAttempt, attempt)) _connectAttempt = null;
  }

  Future<void> disconnect() async {
    // 在飞的尝试一并作废：显式断开同样是「不要继续了」。已连接时没有在飞的
    // 尝试，这一步无副作用，行为与从前一致。
    //
    // 刻意不等待在飞的那一轮：它的收尾由令牌驱动，会在下一个 await 之后自己
    // 完成清理；在这里 await 会把一次同步的断开变成异步，widget / 持久化用例里
    // 「断开后立刻 dispose」就会撞上「通知已销毁对象」。
    _connectAttempt?.cancel();
    _connectAttempt = null;
    _wantConnected = false;
    // 用户主动断开：上一次的失败结论随之作废，圆环回到中性态。
    _clearConnectFailure();
    _persist();
    await _core.disconnect();
  }

  /// 取消正在进行的连接尝试。
  ///
  /// 与 [disconnect] 的区别在**语义**而不是清理：取消会作废本轮尝试，让它在
  /// 下一个 await 之后收手，绝不把状态翻回已连接，也不留下错误——那是用户
  /// 自己的选择。清理仍复用 [disconnect] 那条路径（内核、系统代理、PID 文件
  /// 的回收只有一套），避免出现第二种「收不干净」的写法。
  ///
  /// 三种情形：
  ///   * 没有尝试在飞（未连接）：无害的 no-op；
  ///   * 尝试还没成功（连接中 / 建立隧道中）：作废并收干净；
  ///   * 尝试已经成功（已连接）：按普通断开处理。
  Future<void> cancelConnect() async {
    final attempt = _connectAttempt;
    if (attempt == null && !isConnecting && _status != VpnStatus.connected) {
      return;
    }
    attempt?.cancel();
    _connectAttempt = null;
    _wantConnected = false;
    // 取消是用户的选择，不该留下「错误」。核心在收尾时若发现系统代理没能
    // 还原，那是必须让用户知道的事实——因此先清掉本轮留下的提示，随后的
    // 清理仍可写入新的错误。
    _lastError = null;
    // 失败结论一并撤掉：用户已经表态不要连了，圆环不该继续红着。
    _clearConnectFailure();
    _persist();
    // 清理动作与 [disconnect] 完全共用（内核、系统代理、PID 文件只有一套
    // 收尾）；区别只在语义：这里先作废令牌，让在飞的那一轮自己收手。
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
      // 预热态也允许断开：内核已经就绪、系统代理已经生效，用户此时想中止
      // 连接是完全合理的诉求。此前这里只有 connected 一个分支，预热态会落到
      // 「连接中」那条上被静默忽略——点了没反应，只能一直等门控超时。
      case VpnStatus.connected:
      case VpnStatus.warmingUp:
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
    _recordByTarget.clear();
    _failureCounts.clear();
    _sessionProxiedBytes = 0;
    _sessionDirectBytes = 0;
    _failuresRing.clear();
    _recordsVersion++;
    _failuresVersion++;
    // 「最近学会的」也跟着清掉：它展示的是本次会话观察到的结论，
    // 用户点了清空却还留着十几条记录，会让人以为没清干净。
    _learnedDecisions.clear();
    notifyListeners();
  }

  /// 只清空失败记录。
  ///
  /// 与 [clearRecords] 分开：失败记录是排查用的原始证据，用户在失败面板里点
  /// 「清空」的意思是「这一批我看过了」，不该顺手把分流记录一起清掉。
  void clearFailures() {
    _failuresRing.clear();
    _failuresVersion++;
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
  ///
  /// 「什么时候生效」由 `route_rule_sets.dart` 那套投递机制决定：内核按
  /// update_interval 反复拉取当前决策，因此**不需要重连**，最多十几秒后生效。
  /// 这里不做任何主动通知——投递是内核侧的行为，不是界面状态。
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

  /// 启用/停用一个直连白名单预置。
  ///
  /// 返回是否真的改变了状态。改动经 [AutoRouteTable] 下发，而那张表是作为
  /// **可热更新的规则集**投递给内核的（见 `route_rule_sets.dart`）：内核按
  /// update_interval 反复拉取，因此不需要重连，最多十几秒后生效。
  ///
  /// 预置走 [AutoRouteTable] 这一条统一路径（而不是在配置生成时另插规则），
  /// 因此匹配、优先级、界面、DNS 策略、反向纠正都自动一致。
  bool setAppPresetEnabled(String id, bool enabled) {
    final preset = AppPresets.byId(id);
    if (preset == null) return false;
    final current = _settings.enabledAppPresets.toList();
    if (current.contains(id) == enabled) return false;
    if (enabled) {
      current.add(id);
    } else {
      current.remove(id);
    }
    updateSettings(_settings.copyWith(enabledAppPresets: current));
    _syncAppPresets();
    return true;
  }

  /// 把当前的开关状态同步进决策表。
  ///
  /// 幂等：已启用且已安装的重复调用不会产生变化。安装时 [AutoRouteTable.setPreset]
  /// 不会覆盖优先级更高的条目（学到的、用户指定的），因此重启时重新安装预置
  /// 不会把运行中学到的纠正悄悄抹掉。
  void _syncAppPresets() {
    final table = _core.autoRoute;
    if (table == null) return;
    final enabled = _settings.enabledAppPresets.toSet();
    for (final preset in AppPresets.all) {
      table.setPreset(preset, enabled: enabled.contains(preset.id));
    }
  }

  /// 对一个域名做查证。
  ///
  /// 汇总三份已有的证据：内核**实际**把它判到了哪条路（分流记录）、有没有规则
  /// 覆盖它、两路 DNS 的解析是否一致。DNS 那一步是真的发查询，因此这是用户
  /// 主动触发的动作，不会自己跑。
  Future<DomainCheck> checkDomain(String domain) async {
    final normalized = AutoRouteTable.normalizeDomain(domain);
    if (normalized.isEmpty) {
      // 非法域名（IP、单标签主机名、空串）不必发探测：分流规则本来就按域名，
      // 对它们谈「有没有规则覆盖」没有意义。
      return buildDomainCheck(domain: domain, records: _recordsView);
    }
    final dns = await _core.crossCheckDomain(normalized);
    return buildDomainCheck(
      domain: normalized,
      records: _recordsView,
      rule: _core.autoRoute?.match(normalized),
      dns: dns,
    );
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

  /// 最近一次 MTU 校验结论。未校验过时为 null。
  MtuCheck? get mtuCheck => _mtuCheck;
  MtuCheck? _mtuCheck;

  /// 流量接管入口的展示串；为 null 表示该平台没有这样一个本地入口。
  ///
  /// 界面据此显示「系统代理已设置到哪个地址」，而不是写死一个默认值。
  String? get takeOverEndpoint => _core.takeOverEndpoint;

  /// 主动重测一次 MTU。
  ///
  /// 与 DNS/自检的重测入口同理：结论是采样出来的，只展示不给重测入口，用户
  /// 换了节点或改了配置之后就只能干等下一次自动校验（而那要等下一次连接）。
  Future<void> recheckMtu() async {
    final check = await _core.checkMtu();
    if (check != null) {
      _mtuCheck = check;
      notifyListeners();
    }
  }

  void updateSettings(AppSettings next) {
    final previous = _settings;
    _settings = next;
    if (!next.logSplits && previous.logSplits) {
      _recordsRing.clear();
      _recordByTarget.clear();
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
    if (data == null || data.isEmpty) {
      // 没有持久化：测试与演示不挡界面。有目录却没有存档：全新安装，要确认。
      _legalNoticeAcknowledged = store == null;
      // 首次启动没有存档，但**默认启用的预置仍要安装**：它不是存档数据，
      // 而是随代码分发的默认行为。忘了这一步的表现是「开关显示已启用、
      // 路由里却什么都没有」，而且只有全新安装才会遇到。
      _syncAppPresets();
      return;
    }
    // 键缺失 = 本字段出现之前的存档，当作已经确认过。
    _legalNoticeAcknowledged = data['legalNoticeAcknowledged'] as bool? ?? true;

    final savedProfiles = data['profiles'];
    if (savedProfiles is List) {
      for (final item in savedProfiles) {
        if (item is! Map) continue;
        final name = item['name'];
        final text = item['text'];
        if (name is! String || text is! String || text.isEmpty) continue;
        // 凭据是加密存的，取不回来时返回空——那种情况下配置**照常恢复**，
        // 只是标记成「待补填账号密码」，用户补一次就能用。
        final credentials = _readCredentials(item as Map<Object?, Object?>);
        final username = credentials.username;
        final password = credentials.password;
        try {
          final parsed = VpnProtocolFactory.parse(
            text,
            name,
            username: username,
            password: password,
          );
          final id = stableHash('${parsed.protocol.name}|$text');
          _profiles.add(
            VpnProfile(
              id: id,
              name: name,
              parsed: parsed,
              subscriptionIds: _readSubscriptionIds(item),
            ),
          );
          _profileTexts[id] = text;
          _profileCredentials[id] = (username: username, password: password);
        } on Object {
          continue;
        }
      }
    }

    final activeId = data['activeProfileId'];
    if (activeId is String &&
        _profiles.any((VpnProfile p) => p.id == activeId)) {
      _activeProfileId = activeId;
    } else if (_profiles.isNotEmpty) {
      _activeProfileId = _profiles.first.id;
    }

    final savedSubs = data['subscriptions'];
    if (savedSubs is List) {
      for (final item in savedSubs) {
        if (item is! Map) continue;
        final id = item['id'];
        final name = item['name'];
        if (id is! String || name is! String) continue;
        _subscriptions.add(
          ProfileSubscription(
            id: id,
            name: name,
            url: item['url'] as String? ?? '',
            fetchedAt: DateTime.tryParse(item['fetchedAt'] as String? ?? ''),
            userinfo: item['userinfo'] as String?,
          ),
        );
      }
    }

    final settings = data['settings'];
    if (settings is Map) {
      try {
        _settings = AppSettings(
          autoConnectOnImport: settings['autoConnectOnImport'] as bool? ?? true,
          // 键缺失（旧版本存档）按「关」恢复：这一项是用户主动开启的，
          // 老存档里没有它就等于用户从来没开过。真正的结论随后由
          // AutoStartController.refresh() 与系统核对（见 core/auto_start.dart）。
          autoRunAtStartup: settings['autoRunAtStartup'] as bool? ?? false,
          // 枚举按下标存：名字改了也不会让用户的选择失效。
          splitMode: _enumAt(
            SplitMode.values,
            settings['splitMode'],
            SplitMode.smart,
          ),
          logSplits: settings['logSplits'] as bool? ?? true,
          ruleSetUpdatedAt: DateTime.tryParse(
            settings['ruleSetUpdatedAt'] as String? ?? '',
          ),
          // 键存在就用存档里的（用户关掉默认启用的预置后重启不会被它复活）；
          // 键缺失（旧版本存档）才回退到默认启用集合——否则升级上来的用户
          // 会永远拿不到新增的默认项，而那不是任何人做过的选择。
          enabledAppPresets: settings.containsKey('appPresets')
              ? _readAppPresets(settings['appPresets'])
              : AppPresets.defaultEnabledIds(),
        );
      } on Object {
        _settings = defaultSettings();
      }
    }

    _wantConnected = data['wantConnected'] as bool? ?? false;

    // 规则集：键存在就采用存档（删掉的内置规则集因此保持删除），键缺失才用
    // 出厂默认值。这两者必须区分——用「列表为空」当「没有配置」会让用户
    // 删光规则集后又在重启时看到它们全部复活。
    if (data.containsKey('ruleSets')) {
      _ruleSets = _readRuleSets(data['ruleSets']);
      _removedBuiltins = _readRemovedBuiltins(data['removedBuiltins']);
      // 关键一步：把**存档里没有、也没有被用户删除过**的内置规则集补进来。
      //
      // 只做「有存档就用存档」是不够的：升级上来的用户存档里没有新加的内置
      // 规则集，于是那些「默认启用」的规则集对他们**静默失效**——开关显示成
      // 未启用，用户以为是自己关的。这个缺陷端到端跑起来才暴露：出厂副本都解包
      // 到了磁盘，但生成的内核配置里只引用了两个旧规则集。
      _mergeNewBuiltins();
    }

    // 自动纠正表交给内核侧恢复：它是内核的行为，不是界面的状态。
    // 放在最后，因为此时内核实例一定已经建好了。
    _core.initAutoRoute(data['autoRoute']);
    // 规则集同步给内核：生成配置时引用哪些 .srs 由它决定。
    _core.setRuleSets(_ruleSets);
    // 预置只在存档里存了 id，域名清单属于程序版本，因此每次启动重新安装。
    // 必须在 initAutoRoute 之后：安装时不能覆盖刚恢复的「学到 / 用户指定」条目。
    _syncAppPresets();
    // 规则集大小不在这里量：真实目录要问内核（安卓是 APK 解包目录，不是桌面
    // 路径规则），因此交给 `refreshRuleSetSizes()`——它在启动时被调用。见那里的
    // 说明。
  }

  /// 按磁盘上的真实文件刷新每个规则集的大小。
  ///
  /// 为什么需要它：[BuiltinRuleSet.toEntry] 是无 IO 的纯转换，因此**内置**规则集
  /// 起初的 `sizeBytes` 一律是 0——于是「分流规则」页里那条「大小」永远显示
  /// 「尚未量过」，尽管程序刚刚亲手把这份文件解包到了磁盘。
  ///
  /// 目录必须问内核（`ruleSetUpdateDir`），不能用 [RuleSetStore.writableDir]：
  /// 安卓的真实落点是 APK 资源解包出来的私有目录，桌面路径规则在那边是错的。
  /// 「检查更新」走的也是同一个来源，两处因此不会分叉。
  Future<void> refreshRuleSetSizes() async {
    final Directory? dir = await _core.ruleSetUpdateDir();
    if (dir == null || _disposed) return;
    var changed = RuleSetStore.refreshSizes(_ruleSets, targetDir: dir);
    final sync = await checkCnIpSync(
      ruleSetDir: dir,
      index: _core.cnIpIndex,
    );
    if (_cnIpSync?.ok != sync.ok || _cnIpSync?.detail != sync.detail) {
      _cnIpSync = sync;
      changed = true;
    } else {
      _cnIpSync = sync;
    }
    if (changed && !_disposed) {
      notifyListeners();
      _persist();
    }
  }

  /// 解析存档里的已启用预置 id。
  ///
  /// 忽略无法识别的 id：预置清单属于程序版本，用户升级后某个预置可能已被移除，
  /// 存档里却还留着它的 id——那不该让恢复流程出错，也不该凭空复活一个不存在的开关。
  static List<String> _readAppPresets(Object? raw) {
    if (raw is! List) return const <String>[];
    final ids = <String>[];
    for (final item in raw) {
      if (item is! String) continue;
      if (AppPresets.byId(item) == null) continue;
      if (ids.contains(item)) continue;
      ids.add(item);
    }
    return ids;
  }

  /// 解析存档里的规则集列表。单条损坏只跳过这一条。
  static List<RuleSetEntry> _readRuleSets(Object? raw) {
    if (raw is! List) return RuleSetStore.defaultEntries();
    final entries = <RuleSetEntry>[];
    for (final item in raw) {
      final entry = RuleSetEntry.fromJson(item);
      if (entry == null) continue;
      entries.add(entry);
    }
    return entries;
  }

  /// 按下标取枚举，越界或类型不对时回退到默认值。
  static T _enumAt<T>(List<T> values, Object? raw, T fallback) {
    if (raw is int && raw >= 0 && raw < values.length) return values[raw];
    return fallback;
  }

  /// 一份配置的凭据落盘字段。
  ///
  /// 账号与密码打包成一个整体再加密：只加密密码而把账号明文写在旁边，
  /// 等于把「谁在用这台机器上的哪个账号」直接告诉任何读到文件的人。
  ///
  /// 落盘形态：
  /// ```
  /// "credentials": "<密文>",        // 加密后（或未加密时的原文）
  /// "credentialScheme": "dpapi",    // 用哪个方案解的，将来换方案时旧数据仍可读
  /// ```
  Map<String, Object?> _credentialFields(String id) {
    final credentials = _profileCredentials[id];
    final username = credentials?.username;
    final password = credentials?.password;
    if (username == null || password == null) return const <String, Object?>{};
    return <String, Object?>{
      'credentials': protector.protect(
        jsonEncode(<String, String>{
          'username': username,
          'password': password,
        }),
      ),
      'credentialScheme': protector.scheme,
    };
  }

  /// 还原一份配置的凭据。
  ///
  /// 三条路径，按优先级：
  ///   1. 有 `credentials` 且方案与当前一致 → 解密；
  ///   2. 有 `credentials` 但方案不同（或解密失败）→ 放弃，等用户重新填；
  ///   3. 老版本留下的明文 `username` / `password` → 直接采用（下次落盘
  ///      就会升级成加密形态）。
  ///
  /// 第 2 条刻意不抛异常：换机器、换 Windows 账户都会走到这里，
  /// 那时需要的是「请重新填一次密码」，而不是让这份配置消失。
  ({String? username, String? password}) _readCredentials(
    Map<Object?, Object?> item,
  ) {
    final encoded = item['credentials'];
    if (encoded is String && encoded.isNotEmpty) {
      final scheme = item['credentialScheme'];
      if (scheme == protector.scheme) {
        final plain = protector.unprotect(encoded);
        if (plain != null) {
          try {
            final decoded = jsonDecode(plain);
            if (decoded is Map) {
              final username = decoded['username'];
              final password = decoded['password'];
              if (username is String && password is String) {
                return (username: username, password: password);
              }
            }
          } on FormatException {
            // 内容坏了，按「需要重新填」处理。
          }
        }
      }
      return (username: null, password: null);
    }

    final legacyUsername = item['username'];
    final legacyPassword = item['password'];
    if (legacyUsername is String && legacyPassword is String) {
      return (username: legacyUsername, password: legacyPassword);
    }
    return (username: null, password: null);
  }

  /// 恢复一份配置的订阅归属。
  ///
  /// 同时认早期的单值写法 `subscriptionId`：订阅功能上线前的存档（以及开发
  /// 中途留下的存档）因此不需要用户重新导入。认不出来时返回空集合——那只是
  /// 少一个「刷新」按钮，不该让这份配置恢复失败。
  Set<String> _readSubscriptionIds(Object? item) {
    if (item is! Map) return const <String>{};
    final list = item['subscriptionIds'];
    if (list is List) {
      return <String>{
        for (final value in list)
          if (value is String && value.isNotEmpty) value,
      };
    }
    final single = item['subscriptionId'];
    if (single is String && single.isNotEmpty) return <String>{single};
    return const <String>{};
  }

  /// 落盘。任何一处失败都不影响界面，只是这次不持久化。
  void _persist() {
    final target = store;
    if (target == null) return;
    // 整段包在 try 里。组装落盘数据的阶段就会碰系统 API——凭据加密在 Windows 上
    // 走 DPAPI，它可能失败（FFI 调用返回非零）。而 _persist 的调用点遍布各处，
    // 其中一些是定时器回调（例如自动纠正学到规则时），异常在那里会变成一个
    // **没人处理的异步错误**，界面既不提示、数据也没存下来。
    try {
      target.save(<String, Object?>{
        'profiles': <Object?>[
          for (final VpnProfile p in _profiles)
            if (_profileTexts[p.id] case final String text)
              <String, Object?>{
                'name': p.name,
                'text': text,
                // 排序后落盘：集合的迭代顺序不该让存档每次都不一样。
                if (p.subscriptionIds.isNotEmpty)
                  'subscriptionIds': p.subscriptionIds.toList()..sort(),
                ..._credentialFields(p.id),
              },
        ],
        'subscriptions': <Object?>[
          for (final ProfileSubscription s in _subscriptions)
            <String, Object?>{
              'id': s.id,
              'name': s.name,
              if (s.url.isNotEmpty) 'url': s.url,
              if (s.fetchedAt != null) 'fetchedAt': s.fetchedAt!.toIso8601String(),
              if (s.userinfo != null) 'userinfo': s.userinfo,
            },
        ],
        'activeProfileId': _activeProfileId,
        'wantConnected': _wantConnected,
        'legalNoticeAcknowledged': _legalNoticeAcknowledged,
        'settings': <String, Object?>{
          'autoConnectOnImport': _settings.autoConnectOnImport,
          // 只是界面用的镜像；事实在系统里（注册表 Run 键或 MSIX 的
          // StartupTask），启动时会被回读结果校准。
          'autoRunAtStartup': _settings.autoRunAtStartup,
          'splitMode': _settings.splitMode.index,
          'logSplits': _settings.logSplits,
          'ruleSetUpdatedAt': _settings.ruleSetUpdatedAt?.toIso8601String(),
          // 应用直连预置只存 id：域名清单属于程序版本，随实测结论修正，
          // 存一份副本在用户机器上只会变成过期的第二事实来源。
          'appPresets': _settings.enabledAppPresets,
        },
        // 规则集清单随设置一起落盘。删掉的内置规则集、停用标记、自定义规则集
        // 的链接都必须重启后仍在，否则用户每次启动都要重新配置一遍。
        'ruleSets': <Object?>[
          for (final RuleSetEntry entry in _ruleSets) entry.toJson(),
        ],
        // 用户明确删掉的内置规则集。必须落盘，否则下次启动会被
        // `_mergeNewBuiltins` 补回来，「删掉的内置保持删除」这条语义就没了。
        'removedBuiltins': _removedBuiltins,
        // 自动纠正表随设置一起落盘。它的价值是「学一次，以后都记得」，
        // 每次重启就忘掉会让用户觉得分流时好时坏。
        'autoRoute': _core.exportAutoRoute(),
      });
    } on Object catch (e) {
      // 说明清楚并继续跑：这次没存下来不该让整个界面崩掉或静默丢数据。
      _lastError = '保存配置失败：$e';
      notifyListeners();
    }
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

  /// 撤掉圆环上的失败态。
  ///
  /// 只在用户明确表示「知道了」时调用。断开与重新连接各自清得掉它，因此这不是
  /// 唯一的出口——它的用处是那些**看了一眼仍不想重连**的场景（例如刚发现配置
  /// 里服务器地址写错了），用户不该被迫连一次才能把红色去掉。
  void dismissConnectFailure() {
    if (_connectFailure == null) return;
    _clearConnectFailure();
    notifyListeners();
  }

  /// 记一次连接失败。两个字段必须成对动。
  ///
  /// 单独一个入口是为了不再四处手写「只清了一个、忘了另一个」——那种遗漏的表现
  /// 是红色圆环已经撤掉，点「详情」却还能看到上一轮的技术原文。
  ///
  /// [summary] 是给用户看的那句话；[detail] 是技术原文，没有就不传。
  void _failConnect(String summary, {String? detail}) {
    _connectFailure = summary;
    _connectFailureDetail = detail;
  }

  void _clearConnectFailure() {
    _connectFailure = null;
    _connectFailureDetail = null;
  }

  /// 由界面层主动上报错误（例如启动参数里的配置文件读取失败）。
  void reportError(String message) {
    _lastError = message;
    notifyListeners();
  }

  // ---------------------------------------------------------------- 规则集管理

  /// 启用 / 停用一个规则集。返回是否命中。
  bool setRuleSetEnabled(String name, bool enabled) {
    final index = _ruleSets.indexWhere((RuleSetEntry e) => e.name == name);
    if (index < 0) return false;
    if (_ruleSets[index].enabled == enabled) return true;
    _ruleSets[index].enabled = enabled;
    _commitRuleSets();
    return true;
  }

  /// 从列表里删除一个规则集。
  ///
  /// 内置规则集也能删：它只是「本程序不再使用这一份」，安装包与出厂副本都不会
  /// 被改动，随时可以用 [restoreBuiltinRuleSets] 找回来。删除会连磁盘上的副本
  /// 一并清掉；内置的下次确保目录时可能由出厂副本重新落盘，但它已不在列表里，
  /// 因此不会被内核引用。
  /// 用户**明确删除过**的内置规则集名。
  ///
  /// 存在的理由是「删掉的内置规则集保持删除」这条语义需要区分两种情况：
  ///
  ///   * 「用户把它删了」→ 不该复活；
  ///   * 「这个内置规则集是**新增的**，存档里自然没有」→ 应当补进来。
  ///
  /// 靠「不在 `_ruleSets` 里」无法区分这两者，因此把删除动作显式记下来。
  /// 这个缺陷是端到端自测发现的：出厂副本都解包到了磁盘，但生成的内核配置里
  /// 只引用了两个旧规则集，新增的两份对升级用户**静默失效**。
  List<String> _removedBuiltins = <String>[];

  /// 把存档里没有、也没有被用户删除过的内置规则集补进来。
  void _mergeNewBuiltins() {
    final present = _ruleSets.map((RuleSetEntry e) => e.name).toSet();
    for (final builtin in RuleSetStore.builtins) {
      if (present.contains(builtin.name)) continue;
      if (_removedBuiltins.contains(builtin.name)) continue;
      _ruleSets.add(builtin.toEntry());
    }
    // 清掉指向已不存在内置规则集的陈旧记录：程序升级后某个内置项可能被移除，
    // 留着它只会让存档慢慢积攒无意义的条目。
    _removedBuiltins.removeWhere(
      (String name) => !RuleSetStore.builtinFileNames.contains('$name.srs'),
    );
  }

  /// 解析存档里的「已删除内置规则集」列表。单条损坏只跳过这一条。
  static List<String> _readRemovedBuiltins(Object? raw) {
    // 必须返回**可增长**的列表：调用方随后会对它做 removeWhere 清理陈旧记录。
    if (raw is! List) return <String>[];
    final names = <String>[];
    for (final item in raw) {
      if (item is! String) continue;
      if (names.contains(item)) continue;
      names.add(item);
    }
    return names;
  }

  /// 删除一个规则集。
  bool deleteRuleSet(String name) {
    final index = _ruleSets.indexWhere((RuleSetEntry e) => e.name == name);
    if (index < 0) return false;
    final entry = _ruleSets.removeAt(index);
    // 内置的删除要显式记下来，否则下次启动会被 [_mergeNewBuiltins] 当成
    // 「新增的内置规则集没有出现过」而补回来。
    if (entry.isBuiltin && !_removedBuiltins.contains(name)) {
      _removedBuiltins = <String>[..._removedBuiltins, name];
    }
    unawaited(_deleteRuleSetFile(entry));
    _commitRuleSets();
    return true;
  }

  Future<void> _deleteRuleSetFile(RuleSetEntry entry) async {
    try {
      final dir = await _core.ruleSetUpdateDir();
      if (dir != null) RuleSetStore.deleteSrs(dir, entry.fileName);
    } on Object {
      // 删除文件失败只影响磁盘占用，不影响分流：列表已经不再引用它。
    }
  }

  /// 新增一个自定义规则集：下载 → 校验魔数 → 落盘。
  ///
  /// 返回 null 表示成功，否则是给用户看的中文原因。**下载失败就不写入列表**，
  /// 而不是先登记再补下载：一个指向不存在文件的规则集会直接让内核启动失败。
  /// 新增一个自定义规则集。
  ///
  /// [domainRuleSet] 决定它能否参与 DNS 直连分流。**只有按推荐添加的**才该传
  /// true——手工新增时我们无从得知文件内容是域名还是 IP 清单，猜错会让 DNS 策略
  /// 与实际路由不一致，因此默认 false。
  Future<String?> addCustomRuleSet({
    required String name,
    required String url,
    bool domainRuleSet = false,
  }) async {
    final cleanName = name.trim();
    final cleanUrl = url.trim();
    final invalid = _validateCustom(
      name: cleanName,
      url: cleanUrl,
      excluding: null,
    );
    if (invalid != null) return invalid;
    final dir = await _core.ruleSetUpdateDir();
    if (dir == null) return '当前内核不支持自定义规则集';
    final bytes = await (ruleSetFetcher ?? RuleSetStore.fetch)(cleanUrl);
    if (bytes == null) return '无法下载规则集，请检查链接与网络';
    if (!RuleSetStore.isValidBytes(bytes)) {
      return '「$cleanName」的内容不是有效的 .srs 规则集';
    }
    RuleSetStore.writeSrs(dir, '$cleanName.srs', bytes);
    _ruleSets.add(
      RuleSetEntry(
        name: cleanName,
        kind: RuleSetKind.custom,
        url: cleanUrl,
        updatedAt: DateTime.now(),
        sizeBytes: bytes.length,
        domainRuleSet: domainRuleSet,
      ),
    );
    _commitRuleSets();
    return null;
  }

  /// 修改一个自定义规则集的名称与链接。
  ///
  /// 内置规则集不可改名或改链接：它们是二进制文件，来源也固定。
  Future<String?> updateCustomRuleSet({
    required String oldName,
    required String name,
    required String url,
  }) async {
    final index = _ruleSets.indexWhere((RuleSetEntry e) => e.name == oldName);
    if (index < 0) return '找不到规则集「$oldName」';
    final entry = _ruleSets[index];
    if (entry.kind != RuleSetKind.custom) {
      return '内置规则集不能改名或修改链接';
    }
    final cleanName = name.trim();
    final cleanUrl = url.trim();
    final invalid = _validateCustom(
      name: cleanName,
      url: cleanUrl,
      excluding: oldName,
    );
    if (invalid != null) return invalid;

    final dir = await _core.ruleSetUpdateDir();
    if (dir == null) return '当前内核不支持自定义规则集';

    final changedUrl = cleanUrl != entry.url;
    final changedName = cleanName != oldName;

    List<int>? bytes;
    if (changedUrl) {
      bytes = await (ruleSetFetcher ?? RuleSetStore.fetch)(cleanUrl);
      if (bytes == null) return '无法下载规则集，请检查链接与网络';
      if (!RuleSetStore.isValidBytes(bytes)) {
        return '「$cleanName」的内容不是有效的 .srs 规则集';
      }
    }

    if (bytes != null) {
      // 链接变了：删掉旧文件再写新内容，避免新旧两份同时存在。
      RuleSetStore.deleteSrs(dir, entry.fileName);
      RuleSetStore.writeSrs(dir, '$cleanName.srs', bytes);
    } else if (changedName) {
      RuleSetStore.renameSrs(dir, entry.fileName, '$cleanName.srs');
    }

    _ruleSets[index] = entry.copyWith(
      name: cleanName,
      url: cleanUrl,
      updatedAt: bytes != null ? DateTime.now() : null,
      sizeBytes: bytes?.length,
    );
    _commitRuleSets();
    return null;
  }

  /// 恢复出厂规则集，并清除**程序学到**的分流规则。
  ///
  /// 范围刻意定死：只重发布两个内置规则集（geosite-cn / geoip-cn），只丢弃
  /// 程序自动学到的规则；用户手工指定的域名规则与自定义规则集一律保留——
  /// 那些是用户明确做过的决定，顺手清掉比不清理更糟。
  void restoreBuiltinRuleSets() {
    final custom = _ruleSets
        .where((RuleSetEntry e) => e.kind == RuleSetKind.custom)
        .toList(growable: false);
    _ruleSets = <RuleSetEntry>[
      ...RuleSetStore.defaultEntries(),
      ...custom,
    ];
    // 「恢复内置规则」的意思就是把删除记录清空——之后新增的内置规则集
    // 也应当照常补进来。
    _removedBuiltins = <String>[];
    _core.autoRoute?.removeLearned();
    // 展示用的「最近学到」也一并清掉；用户手工指定的条目保留。
    _learnedDecisions.removeWhere(
      (AutoRouteDecision d) => d.entry?.source != RouteRuleSource.user,
    );
    _commitRuleSets();
  }

  /// 校验自定义规则集的名称与链接。
  String? _validateCustom({
    required String name,
    required String url,
    required String? excluding,
  }) {
    if (!RuleSetEntry.isValidName(name)) {
      return '名称只能用小写字母、数字、连字符或下划线，且以字母或数字开头';
    }
    // 与内置重名要挡住，即便那个内置已被删除：内置文件与解包逻辑都按固定
    // 文件名工作，重名会让「这份文件到底是出厂副本还是自定义内容」无法分辨。
    if (RuleSetStore.builtinFileNames.contains('$name.srs')) {
      return '「$name」与内置规则集重名，请换一个名称';
    }
    if (name != excluding &&
        _ruleSets.any((RuleSetEntry e) => e.name == name)) {
      return '已存在同名规则集：$name';
    }
    if (url.isEmpty) return '请填写规则集的下载链接';
    final uri = Uri.tryParse(url);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) {
      return '链接需要是 http 或 https 地址';
    }
    return null;
  }

  /// 规则集变化后的统一收尾：同步给内核、通知界面、落盘。
  void _commitRuleSets() {
    _core.setRuleSets(_ruleSets);
    notifyListeners();
    _persist();
  }

  /// 从上游更新**所有启用中**的规则集。
  ///
  /// 之前这里只是把显示的日期改成「今天」，并没有真的下载——属于误导性实现。
  /// 现在真的去拉取 `.srs` 并覆盖本地副本，失败时明确报错而不是假装成功。
  ///
  /// 目标目录**由内核决定**（[VpnCore.ruleSetUpdateDir]）：必须是内核真正读取
  /// 规则库的那一个。安卓端此前写死在桌面端的路径规则上，结果更新落进一个
  /// 临时目录，界面说成功、内核照旧用旧规则——用户被明确告知了一件没发生的事。
  Future<void> refreshRuleSet() async {
    try {
      final target = await _core.ruleSetUpdateDir();
      if (target == null) {
        _lastError = '当前内核不维护可更新的规则库';
        notifyListeners();
        return;
      }
      final targets = <({String fileName, String url})>[
        for (final entry in _ruleSets)
          // 只更新**能**更新的：构建期产物（bundledExtras）的来源不是 `.srs`
          // 地址，下载回来必然通不过魔数校验，报错却指向用户的网络。
          if (entry.enabled && entry.updatable)
            (fileName: entry.fileName, url: entry.url),
      ];
      if (targets.isEmpty) {
        // 区分「没启用任何规则集」与「启用的都不可更新」——后者是正常状态
        // （内置补充规则集只能靠重跑构建脚本刷新），不该报成错误。
        final enabledCount = _ruleSets.where((RuleSetEntry e) => e.enabled).length;
        _lastError = enabledCount == 0
            ? '没有启用中的规则集可更新'
            : '启用中的规则集都是构建期产物，需重跑构建脚本刷新';
        notifyListeners();
        return;
      }
      final outcome = await RuleSetStore.updateMany(targets, targetDir: target);
      if (outcome.succeeded) {
        final now = outcome.updatedAt ?? DateTime.now();
        for (final entry in _ruleSets) {
          if (!entry.enabled) continue;
          entry.updatedAt = now;
          final file = File(
            '${target.path}${Platform.pathSeparator}${entry.fileName}',
          );
          if (file.existsSync()) entry.sizeBytes = file.lengthSync();
        }
        _ruleSetUpdatedAt = now;
        _lastError = null;
        _core.setRuleSets(_ruleSets);
      } else {
        _lastError = outcome.message;
      }
    } on Object catch (e) {
      // 解析目标目录本身就可能失败（安卓端解包需要原生通道与 APK 资源）。
      // 那是「更新没能完成」的又一种形态，必须变成用户看得见的结论，而不是
      // 一个没人处理的异步异常——按钮点了没反应，用户只会以为程序卡住了。
      _lastError = '更新规则库失败：$e';
    }
    notifyListeners();
    _persist();
  }

  // -------------------------------------------------------- VpnCoreListener

  @override
  void onStatusChanged(VpnStatus status) {
    _status = status;
    switch (status) {
      case VpnStatus.connected:
        _connectedSince = DateTime.now();
        // 连上了：上一次的失败结论已经过期，圆环必须回到「已连接」。
        _clearConnectFailure();
        _startTicker();
        // 首次连接会把出厂规则集解包到可写目录（`RuleSetStore.ensure` 在内核
        // 解析运行路径时执行）。解包之后才量得到大小，因此这里再补一次——否则
        // 新装的机器要等到用户点过一次「检查更新」，「大小」那行才会有值。
        // 「找文件」是磁盘操作且安卓要过平台通道，因此不阻塞状态机。
        unawaited(refreshRuleSetSizes());
      case VpnStatus.disconnected:
      case VpnStatus.connecting:
      case VpnStatus.warmingUp:
        _connectedSince = null;
        _stopTicker();
        // 每次重新连接都从干净的失败记录开始，避免旧失败误导判断。
        // 预热不算「重新连接」：失败记录里可能已经有本次预热期间的真实失败，
        // 那是排查用的证据，不该在预热转正时被抹掉。
        if (status == VpnStatus.connecting) {
          _failuresRing.clear();
          _failuresVersion++;
        }
        if (status == VpnStatus.disconnected) {
          _downBps = 0;
          _upBps = 0;
          _totalBytes = 0;
          _latencyMs = null;
          _directBytes = 0;
          _proxiedBytes = 0;
          _connectionCount = 0;
          _kernelMemory = 0;
          // 「本次连接 / 观测分流」都是这一次连接的口径，断开后必须归零；
          // 否则重连后用户会把上一次的数字当成这一次的。
          _sessionProxiedBytes = 0;
          _sessionDirectBytes = 0;
          _pushSpark(0, 0);
          // 断开后 DNS 与自检的结论已经过期，留着会误导。
          // 自动纠正表不清：那是学到的长期结论，与本次连接无关。
          _dnsReport = null;
          _selfCheckReport = null;
          // 健康结论同理：它描述的是「刚才那条隧道」，断开后不再有意义。
          _tunnelHealth = null;
          _healthNotice = null;
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
    // 已连接时由 1 秒 ticker 统一刷新界面（含连接时长）。这里再 notify 会让
    // 主线程每秒重建两次，而界面与分流数据处理共用同一个 isolate。
    // 未连接 / 连接中仍合并通知一次，好让断开后的归零立刻反映到统计卡。
    if (_status == VpnStatus.connected) return;
    _notifyCoalesced();
  }

  @override
  void onLatency(int? millis) {
    _latencyMs = millis;
    notifyListeners();
  }

  /// 同目标合并表的查找索引：target → 环形缓冲里的那一条记录。
  ///
  /// **必须是 O(1) 的**。这条路径每秒会被调用「目标数」次（每个目标一次流量增量），
  /// 一旦退化成遍历整个缓冲（上限 500 条），每秒就是几万次比较——那是纯粹的
  /// 界面开销，而它跑在与分流同一个进程里，界面卡住会直接影响分流数据的处理。
  /// 因此淘汰清理放在写入侧做（见 [onSplitRecord]），读取侧只查表。
  final Map<String, SplitRecord> _recordByTarget = <String, SplitRecord>{};

  /// 每个目标的累计失败次数。内核只在日志里报失败，不算进连接快照，
  /// 因此需要状态层自己按目标计数。
  final Map<String, int> _failureCounts = <String, int>{};

  @override
  void onSplitRecord(SplitRecord record) {
    if (!_settings.logSplits) return;

    final existing = _recordByTarget[record.target];
    if (existing != null) {
      // 同一目标再次出现：合并到已有那一行，不新增行。
      existing.connections++;
      existing.lastSeen = record.time;
      _recordsVersion++;
      return;
    }

    // 先记下即将被挤出的那一条，push 之后把它从索引里摘掉。
    //
    // 这一步是「读取侧只查表」的前提：环形缓冲满员时会静默丢弃最旧的一条，
    // 若索引不跟着清理，它就会一直涨、并且留下指向已淘汰对象的引用。
    final ring = _recordsRing;
    final evicted = ring.length >= AppState.recordLimit
        ? ring[ring.length - 1]
        : null;

    ring.push(record);
    _recordByTarget[record.target] = record;
    if (evicted != null &&
        !identical(evicted, record) &&
        identical(_recordByTarget[evicted.target], evicted)) {
      _recordByTarget.remove(evicted.target);
      // 失败计数与记录生命周期一致：记录被挤出后计数也一并清掉，
      // 否则同一目标再次出现时会带着上一轮的旧计数。
      _failureCounts.remove(evicted.target);
    }
    _recordsVersion++;
  }

  /// 把一条连接的流量增量累加到它所属的那一行上。
  ///
  /// 目标还没出现过时不新建行：行由 [onSplitRecord] 建，流量只做累加——
  /// 否则会出现「只有流量、没有连接事件」的记录。
  ///
  /// 「观测分流」占比与「按域名记账」刻意拆开：关闭 [AppSettings.logSplits]
  /// 只停分流行，连接页的隧道占比仍要动——用户关掉明细记录，不等于不要
  /// 「这次连上有多少进了隧道」这个答案。
  ///
  /// 这里是**每秒 × 目标数**的高频路径，因此只做常数级工作：查表、两个加法、
  /// 一个计数器自增。**不调用 `notifyListeners`**——界面每秒有一次统一定时刷新，
  /// 每条流量都触发重绘会把主线程占满，而它和分流共用同一个 isolate。
  @override
  void onConnectionTraffic(ConnectionTraffic traffic) {
    // 观测分流独立于记录是否存在、也独立于是否记账：记录会被淘汰或关闭，
    // 而「本次连接走了多少隧道」不该因此倒退或停更。
    if (traffic.kind == RouteKind.proxy) {
      _sessionProxiedBytes += traffic.totalDelta;
    } else {
      _sessionDirectBytes += traffic.totalDelta;
    }

    if (!_settings.logSplits) return;

    final record = _recordByTarget[traffic.target];
    if (record == null) {
      _recordsVersion++;
      return;
    }
    record.uploadBytes += traffic.uploadDelta;
    record.downloadBytes += traffic.downloadDelta;
    record.lastSeen = DateTime.now();
    _recordsVersion++;
  }

  @override
  void onConnectionFailure(ConnectionFailure failure) {
    _failuresRing.push(failure);
    final host = failure.host;
    final total = (_failureCounts[host] ?? 0) + 1;
    _failureCounts[host] = total;
    // 立刻回填到对应那一行，而不是等到界面取列表时才填。
    //
    // 此前回填写在 filteredRecords 里，于是「失败次数」只在渲染路径上可见：
    // 任何直接读记录的地方（测试、以后可能加的导出）拿到的都是 0，
    // 同一份数据出现两个值。计数处就写进去，来源只有一个。
    final record = _recordByTarget[host];
    if (record != null) record.failures = total;
    _recordsVersion++;
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
    // 学到的规则要尽快落盘：它既决定本次会话接下来的分流（经可热更新的规则集
    // 投递给运行中的内核），也是下一次连接的路由表来源。
    _persist();
  }

  @override
  void onAutoRouteChanged(AutoRouteTable table) {
    notifyListeners();
  }

  /// 记下一条自动纠正结论，供界面展示。只保留最近若干条。
  void _rememberDecision(AutoRouteDecision decision) {
    _learnedDecisions.removeWhere(
      (AutoRouteDecision d) => d.domain == decision.domain,
    );
    _learnedDecisions.insert(0, decision);
    if (_learnedDecisions.length > learnedDisplayLimit) {
      _learnedDecisions.removeRange(
        learnedDisplayLimit,
        _learnedDecisions.length,
      );
    }
  }

  @override
  void onTunnelHealth(TunnelHealth health) {
    _tunnelHealth = health;
    if (health.isProblem) {
      // 任何异常结论都先在这里说清楚，这样即便某个平台没有自愈能力，
      // 用户也不会只看到「网页打不开」却不知道原因。
      //
      // 有能力自愈的内核会在随后用一条更具体的消息覆盖它（例如
      // 「第 1 次自动恢复」）——观测引擎刻意先通知界面、再通知内核，
      // 就是为了让那条更具体的消息排在后面。
      _healthNotice = health.summary;
      _lastError = health.summary;
    } else {
      if (_healthNotice != null && _lastError == _healthNotice) {
        // 恢复后撤掉这句已经过期的结论。
        _lastError = null;
        _healthNotice = null;
      }
      // 连接期那条「隧道尚未就绪」也要撤掉。
      //
      // 它是门控超时时写下的临时说明，而门控超时**不阻断连接**：隧道完全可能
      // 再过几秒就通了——实测正是如此。没有这一句撤销，那条提示会一直挂在
      // 界面上，用户拿着一个过期的结论去排查一条已经好了的隧道。
      if (_lastError == tunnelNotReadyNotice) {
        _lastError = null;
      }
    }
    notifyListeners();
  }

  @override
  void onMtuCheck(MtuCheck check) {
    _mtuCheck = check;
    notifyListeners();
  }

  @override
  void onError(String message) {
    _lastError = message;
    // 只有在**连接过程中**报的错才升级成「圆环失败态」。
    //
    // 这个条件不能放宽成「没连上就算」：导入失败、规则库更新失败、系统代理没能
    // 还原都会走到 [reportError] 或这里，而它们与「刚才那次连接」毫无关系——
    // 让它们把圆环染红，等于用一个不相干的错误告诉用户「你的连接失败了」。
    //
    // 健康自愈那类通知也正因此被排除在外：它们发生在已经连上的隧道上，
    // 那时状态是 connected，不是 connecting。
    //
    // 上主视线的是 [connectFailureSummary] 这一句人话，不是 [message] 的原文：
    // 内核抛出来的东西常常是 `parse rule-set: open /data/user/0/…: no such file
    // or directory`，把它整段挂在连接页上，用户看不懂、也没有能做的事，唯一
    // 的实际效果是让人以为自己弄坏了什么。原文留在「详情」里，一步就能看到。
    if (_status == VpnStatus.connecting) {
      _failConnect(connectFailureSummary, detail: message);
    }
    notifyListeners();
  }

  @override
  void onKernelLog() {
    // 只重建界面，不写进 _lastError：日志是材料不是结论，绝大多数行都
    // 不代表出错，按错误显示会把真正的错误淹掉。
    //
    // 但**必须合并同一轮里的多次通知**：内核日志是按块到达的，而且内核以
    // debug 级别运行时每秒可能来几十块。逐块 notifyListeners 会让整棵界面树
    // 每秒重建几十次，而界面与分流数据处理共用同一个 isolate——界面把主线程
    // 占满，分流数据的处理就会被推迟。日志缓冲本身已经立刻写入（用户点开日志
    // 看到的是最新的），这里只是把「重绘」这一步合并掉。
    _notifyCoalesced();
  }

  /// 把同一轮事件里的多次重绘请求合并成一次。
  ///
  /// 用微任务而不是延时定时器：微任务在本轮事件循环结束时立刻执行，因此
  /// 界面依然是「这一瞬间就更新」，只是不会为同一批数据重复重建多遍；
  /// 而在测试里 `pump()` 会先冲掉微任务队列，通知不会被漏掉。
  void _notifyCoalesced() {
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    scheduleMicrotask(() {
      _notifyScheduled = false;
      if (_disposed) return;
      notifyListeners();
    });
  }

  bool _notifyScheduled = false;

  // ---------------------------------------------------------------- 内部工具

  void _pushSpark(double down, double up) {
    _downHistory.add(down);
    _upHistory.add(up);
    // totalHistory 曾给「本次连接」卡配速率火花，已去掉该误导用法，不再维护。
    while (_downHistory.length > sparkPoints) {
      _downHistory.removeAt(0);
    }
    while (_upHistory.length > sparkPoints) {
      _upHistory.removeAt(0);
    }
  }

  void _startTicker() {
    _ticker ??= Timer.periodic(
      const Duration(seconds: 1),
      (_) => notifyListeners(),
    );
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

/// 连接失败时挂在圆环旁边的那一句。
///
/// 刻意**不**把内核的原文搬上主视线：`parse rule-set: open /data/user/0/…: no
/// such file or directory` 这类句子，用户看不懂，也没有能做的事——把它整段显示
/// 出来，实际效果只是让人以为自己弄坏了什么。原文一步之遥（「详情」），愿意看
/// 的人照样看得到。
///
/// 这里也刻意不做「智能分类」。内核的报错有几十种，凭字符串猜出来的结论一旦猜
/// 错，就会把用户引到错误的方向；「没能连上服务器」是唯一一句对所有这些情况都
/// 成立、且不需要用户懂技术的话。
const String connectFailureSummary = '没能连上服务器';

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
  set length(int value) => throw UnsupportedError('记录视图是只读的');

  @override
  T operator [](int index) {
    final value = _ring[index];
    if (value == null) {
      throw RangeError.index(index, this, 'index', null, _ring.length);
    }
    return value;
  }

  @override
  void operator []=(int index, T value) => throw UnsupportedError('记录视图是只读的');
}
