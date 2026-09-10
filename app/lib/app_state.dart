import 'dart:async';

import 'package:flutter/foundation.dart';

import 'core/core_log.dart';
import 'core/rulesets.dart';
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

  final List<VpnProfile> _profiles = <VpnProfile>[];
  final List<SplitRecord> _records = <SplitRecord>[];

  /// 连接失败记录。这是「检测能力」的载体：把用户看到的「打不开」
  /// 翻译成「规则判错了」还是「节点不通了」。
  final List<ConnectionFailure> _failures = <ConnectionFailure>[];
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
  int? _latencyMs;
  Timer? _ticker;
  bool _disposed = false;

  // ---------------------------------------------------------------- 只读视图

  VpnCore get core => _core;
  VpnStatus get status => _status;
  AppSettings get settings => _settings;
  List<VpnProfile> get profiles => List<VpnProfile>.unmodifiable(_profiles);
  List<SplitRecord> get records => List<SplitRecord>.unmodifiable(_records);
  List<ConnectionFailure> get failures => List<ConnectionFailure>.unmodifiable(_failures);

  /// 失败归因摘要：界面用它给出「该做什么」而不是只报「出错了」。
  FailureDigest get failureDigest => digestFailures(_failures);
  List<double> get downHistory => List<double>.unmodifiable(_downHistory);
  List<double> get upHistory => List<double>.unmodifiable(_upHistory);
  List<double> get totalHistory => List<double>.unmodifiable(_totalHistory);
  String? get lastError => _lastError;
  DateTime get ruleSetUpdatedAt => _ruleSetUpdatedAt;
  double get downBps => _downBps;
  double get upBps => _upBps;
  int get totalBytes => _totalBytes;
  int? get latencyMs => _latencyMs;
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

  int get proxyCount => _records.where((r) => r.kind == RouteKind.proxy).length;
  int get directCount => _records.where((r) => r.kind == RouteKind.direct).length;

  List<SplitRecord> filteredRecords(RouteFilter filter, String query) {
    final q = query.trim().toLowerCase();
    return _records.where((r) {
      final matchesFilter = switch (filter) {
        RouteFilter.all => true,
        RouteFilter.proxy => r.kind == RouteKind.proxy,
        RouteFilter.direct => r.kind == RouteKind.direct,
      };
      if (!matchesFilter) return false;
      if (q.isEmpty) return true;
      return r.target.toLowerCase().contains(q);
    }).toList(growable: false);
  }

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
    _records.clear();
    _failures.clear();
    notifyListeners();
  }

  /// 只清空失败记录，保留分流记录。
  void clearFailures() {
    _failures.clear();
    notifyListeners();
  }

  void updateSettings(AppSettings next) {
    final previous = _settings;
    _settings = next;
    if (!next.logSplits && previous.logSplits) {
      _records.clear();
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
          launchAtStartup: settings['launchAtStartup'] as bool? ?? false,
          // 枚举按下标存：名字改了也不会让用户的选择失效。
          takeoverMode: _enumAt(TakeoverMode.values, settings['takeoverMode'],
              TakeoverMode.systemProxy),
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
        'launchAtStartup': _settings.launchAtStartup,
        'takeoverMode': _settings.takeoverMode.index,
        'splitMode': _settings.splitMode.index,
        'logSplits': _settings.logSplits,
        'ruleSetUpdatedAt': _settings.ruleSetUpdatedAt?.toIso8601String(),
      },
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
          _failures.clear();
        }
        if (status == VpnStatus.disconnected) {
          _downBps = 0;
          _upBps = 0;
          _latencyMs = null;
          _pushSpark(0, 0);
        }
    }
    notifyListeners();
  }

  @override
  void onTraffic({required double downBps, required double upBps, required int totalBytes}) {
    _downBps = downBps;
    _upBps = upBps;
    _totalBytes = totalBytes;
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
    _records.insert(0, record);
    if (_records.length > recordLimit) {
      _records.removeRange(recordLimit, _records.length);
    }
    notifyListeners();
  }

  @override
  void onConnectionFailure(ConnectionFailure failure) {
    _failures.insert(0, failure);
    if (_failures.length > failureLimit) {
      _failures.removeRange(failureLimit, _failures.length);
    }
    notifyListeners();
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
