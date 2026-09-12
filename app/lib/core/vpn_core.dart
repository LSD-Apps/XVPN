import 'dart:async';
import 'dart:io';
import 'dart:math';

import '../models.dart';
import 'auto_route.dart';
import 'clash_api.dart';
import 'cn_ip_index.dart';
import 'core_log.dart';
import 'core_monitor.dart';
import 'dns_monitor.dart';
import 'kernel_log.dart';
import 'mtu_probe.dart';
import 'rulesets.dart';
import 'singbox_config.dart';
import 'startup_self_check.dart';
import 'tunnel_health.dart';
import 'wireguard_handshake.dart';

/// 内核事件回调。UI 状态层实现它，内核只负责上报。
///
/// 关于「哪些方法是必需的」：观测相关的回调（DNS 报告、自检、自动纠正）
/// 都带默认实现。这样新增一种观测能力时，不会强迫所有实现立刻跟上——
/// 这正是此前复制两份观测代码的起因。
abstract class VpnCoreListener {
  void onStatusChanged(VpnStatus status);

  /// 流量统计。
  ///
  /// [directBytes] / [proxiedBytes] 是按出站聚合的已传输字节，
  /// [connectionCount] 是当前活连接数，[kernelMemory] 是内核报告的常驻内存。
  /// 三者都是可选上报：老实现可以只给总量。
  void onTraffic({
    required double downBps,
    required double upBps,
    required int totalBytes,
    int directBytes = 0,
    int proxiedBytes = 0,
    int connectionCount = 0,
    int kernelMemory = 0,
  });

  /// 到服务器的往返延迟（毫秒）。内核尚未测出时传 null。
  void onLatency(int? millis);

  void onSplitRecord(SplitRecord record);

  /// 一条连接上的流量增量。
  ///
  /// 与 [onSplitRecord] 分开的理由：分流记录是「一条连接出现了」这个事件，
  /// 而流量是连接存活期间每秒增长的量。界面把同目标的记录合并成一行之后，
  /// 需要把每秒的增量累加到那一行上，两者是不同性质的信号。
  ///
  /// 只有增量、没有累计：内核给的是每条连接的累计值，相减的工作留在观测引擎，
  /// 状态层不需要自己维护一份连接账本。
  void onConnectionTraffic(ConnectionTraffic traffic) {}

  /// 一条连接失败。
  ///
  /// 这是「检测能力」的数据来源：失败本身用户看得见（网站打不开），
  /// 但**为什么失败**只有内核知道——判为直连却失败，和走了隧道却失败，
  /// 是两种截然不同的问题。见 [ConnectionFailure]。
  void onConnectionFailure(ConnectionFailure failure);

  void onError(String message);

  /// 一轮 DNS 监测的结果。
  void onDnsReport(DnsReport report) {}

  /// 一次启动自检的结果。
  void onSelfCheck(StartupSelfCheckReport report) {}

  /// 自动纠正表新增了一条规则。
  ///
  /// 上报它是为了让「程序自己学会了」这件事对用户可见——否则分流规则
  /// 在背后变化，用户只会觉得「有时候能连有时候不能」。
  void onAutoRouteLearned(AutoRouteDecision decision) {}

  /// 自动纠正表的整体变化（含用户手工增删）。
  void onAutoRouteChanged(AutoRouteTable table) {}

  /// 内核日志有新内容。
  ///
  /// 单独一个回调而不是复用 [onError]：日志是**材料**不是结论，绝大多数行
  /// 都不代表出错。界面据此刷新日志视图即可，不该按错误去处理。
  void onKernelLog() {}

  /// 隧道健康状态发生变化。
  ///
  /// 只在**结论变化**时上报：从正常变为异常、从异常恢复为正常，以及异常
  /// 原因在「隧道断了」与「本地网络断了」之间切换。不是每次探测都报——
  /// 那样会把界面刷成噪声。
  ///
  /// 内核据此决定要不要自动恢复。断开状态下的正常上报同样重要：它是
  /// 「已经自愈」的证据，没有它，自愈限流器就永远不会解除。
  void onTunnelHealth(TunnelHealth health) {}

  /// MTU 校验有了新结论。
  ///
  /// 只在校验完成时上报（连接后自动一次、用户点重测一次），不是周期性探测：
  /// 它要真的往隧道里推一个接近 MTU 的包，不该反复做。
  void onMtuCheck(MtuCheck check) {}
}

/// 一次连接尝试的取消令牌。
///
/// 连接路径上有若干处「等内核就绪 / 等系统代理 / 等隧道能载流量」的 await，
/// 用户完全可能在任意一处按下取消。没有这个令牌时，被取消的那一轮会在下一次
/// await 之后继续往下走，把已经拆掉的隧道与系统代理重新装回来——界面显示
/// 「已连接」，而用户以为自己已经把它停了。
///
/// 令牌的生命周期由 [AppState] 掌握：每次用户发起连接创建一个新的，取消或
/// 新一轮连接开始时把旧的标记掉。内核**只在每个 await 之后复查它**，而不是
/// 只看「用户是否要断开」——后者会被下一轮连接重置，不足以区分「这一轮已经
/// 被取代」和「这一轮正常继续」。
class ConnectAttempt {
  ConnectAttempt(this.generation);

  /// 第几轮连接（从 1 开始）。仅用于日志与测试定位。
  final int generation;

  bool _cancelled = false;

  /// 本轮尝试是否已被取消或被新的一轮取代。
  bool get isCancelled => _cancelled;

  /// 作废本轮尝试。幂等：重复调用没有额外效果。
  void cancel() => _cancelled = true;

  @override
  String toString() => 'ConnectAttempt(#$generation, cancelled: $isCancelled)';
}

/// 隧道内核抽象。
///
/// 两个真实实现：
///   * Windows / Linux：[SingBoxRunner] 以子进程方式启动随附的内核
///     （`sing-box.exe` / `sing-box`），并接管系统代理；
///   * Android：[AndroidVpnCore] 通过 MethodChannel 调用 libbox，配合 VpnService 建立 TUN。
///
/// 两者的观测逻辑共用 [CoreMonitor]，因此统计口径完全一致。
abstract class VpnCore {
  VpnCore(this.listener, {this.probesEnabled = true}) {
    monitor = _createMonitor();
  }

  final VpnCoreListener listener;

  /// 是否允许内核层主动发起探测（DNS 监测、启动自检、直连连通性）。
  ///
  /// 关掉之后被动观测照常工作。测试与「只读模式」会把它设为 false；
  /// 见 [CoreMonitorHooks.probesEnabled]。
  final bool probesEnabled;

  /// 观测引擎。子类通过 [monitorHooks] 提供平台差异。
  late final CoreMonitor monitor;

  /// 内核名称，展示在诊断信息里。
  String get name;

  /// 建立隧道。
  ///
  /// [attempt] 是本轮的取消令牌。带真实阻塞（等内核、等端口、等系统代理）的
  /// 实现必须在**每个 await 之后**复查 `attempt?.isCancelled`，在被取消时收手，
  /// 而不是继续把状态推到「已连接」。演示内核也必须遵守同一条约定，否则界面
  /// 的取消按钮在演示模式下会「按了没用」。
  Future<void> connect(
    VpnProfile profile,
    AppSettings settings, {
    ConnectAttempt? attempt,
  });

  Future<void> disconnect();

  /// 接管一个「界面进程没了、但内核还在跑」的隧道。
  ///
  /// 安卓的隧道跑在前台服务里，界面进程被系统回收后隧道不会停；此时重新打开
  /// 界面必须把状态接回来，否则会显示「未连接」而流量其实仍在走隧道——用户
  /// 要么以为没连上，要么以为断开失败了。
  ///
  /// 返回 true 表示确实接管了一个正在运行的内核。默认实现表示该平台没有这种
  /// 情况（内核与界面同生共死）。
  Future<bool> resumeIfRunning() async => false;

  /// 供观测引擎使用的东西。子类在构造时设置。
  ///
  /// 默认返回一个不做自动纠正的配置，让演示内核与测试不需要额外准备。
  CoreMonitorHooks monitorHooks() => CoreMonitorHooks(
    listener: listener,
    clashApiPort: SingBoxConfigBuilder.defaultClashApiPort,
    probesEnabled: probesEnabled,
  );

  /// 自动纠正表。为 null 表示本实现不做学习。
  AutoRouteTable? get autoRoute => monitor.autoRoute;

  /// 内核日志缓冲。两端共用同一份实现。
  ///
  /// 放在基类而不是各写一份：日志是排查问题的唯一原始材料，一端有、一端没有
  /// 正是「安卓上出了问题什么都查不到」的原因。
  final KernelLogBuffer kernelLog = KernelLogBuffer();

  /// 最近观测到的 WireGuard 握手状态。
  ///
  /// 放在基类，两端因此自动都有：解析发生在共用的 [CoreMonitor] 里，而日志
  /// 也由两端各自喂进同一条 [handleCoreLog] 管线。这正是「两端能力一致」最容易
  /// 做到的一种——不是各自实现一遍，而是根本不重复实现。
  WireGuardHandshake get handshake => monitor.handshake;

  /// 本平台能否报告 WireGuard 握手状态。
  ///
  /// 两端都为 true：内核日志管线两端共用，握手解析发生在 [CoreMonitor] 里，
  /// 日志也由两端各自喂进同一条 [handleCoreLog] 管线。此前安卓端为 false，
  /// 是因为 DEBUG 日志转发会在原生线程里调 MethodChannel 并 abort 进程；
  /// 根因修掉后两端能力一致。
  ///
  /// 「能报告」的前提是内核真的产生了那些行：握手行是 DEBUG 级的，因此生成
  /// 配置时会按 [ParsedProfile.wantsDebugLogs] 把 WireGuard 的 `log.level`
  /// 调到 debug。少了下发这一步，两端都会停在「正在读取内核握手状态…」。
  bool get supportsHandshakeState => true;

  /// 最近一次 MTU 校验结论。未校验过时为 null；配置没声明 MTU 时为 notDeclared。
  MtuCheck? get mtuCheck => monitor.mtuCheck;

  /// 由界面主动触发一次 MTU 校验。与 DNS/自检的重测入口同理。
  Future<MtuCheck?> checkMtu() => monitor.checkMtu();

  /// 流量接管入口的展示串，例如 `127.0.0.1:2080`。
  ///
  /// 为 null 表示该平台没有这样一个本地入口（安卓走 TUN，由 VpnService 接管
  /// 全部程序）。做成基类成员而不是让界面写死：默认端口 2080 被占用时内核会
  /// 换一个，界面若照旧显示 2080 就是在告诉用户一个错地址——而那一行恰恰是
  /// 「代理配到哪」的唯一说明。
  String? get takeOverEndpoint => null;

  /// 「检查更新」应当写入的目录——必须是内核**真正读取**规则库的那一个。
  ///
  /// 接口放在内核上而不是让界面直接调 `RuleSetStore.writableDir`：后者只知道
  /// 桌面端的路径规则（`%LOCALAPPDATA%` / `$XDG_DATA_HOME`）。安卓端的内核读的
  /// 是 APK 资源解包后的应用私有目录，更新若按桌面端那套路径写下去，界面会报告
  /// 成功、内核却永远用旧规则——这正是本轮要修掉的那条误导。
  ///
  /// 返回 null 表示本实现不维护可更新的规则库（例如演示内核）。
  Future<Directory?> ruleSetUpdateDir() async => RuleSetStore.writableDir();

  CoreMonitor _createMonitor() => CoreMonitor(monitorHooks());

  /// 内核日志回调的统一入口。两端各自把日志行喂进来。
  void handleCoreLog(String line) {
    if (line.trim().isEmpty) return;
    kernelLog.add(line);
    monitor.onCoreLogLine(line);
    listener.onKernelLog();
  }

  /// 内核输出的一整块文本。
  ///
  /// 子进程的 stdout/stderr 是按块到达的，一个日志行可能横跨两块。交给缓冲去
  /// 拼接完整行，只对**新凑齐**的行做失败归因——半截行拿去解析只会得到噪声。
  void handleCoreLogChunk(String chunk) {
    final fresh = kernelLog.addChunk(chunk);
    if (fresh.isEmpty) return;
    for (final line in fresh) {
      monitor.onCoreLogLine(line);
    }
    // 按块通知而不是按行：一次输出动辄几十行，逐行通知会把界面刷成噪声。
    listener.onKernelLog();
  }

  /// 由界面主动触发一次 DNS 监测。
  Future<void> refreshDns() => monitor.refreshDns();

  /// 由界面主动触发一次自检。
  Future<void> runSelfCheck() => monitor.runSelfCheck();

  /// 对单个域名做一次两路 DNS 对照。
  ///
  /// 这是**用户主动发起**的探测，因此不受 [probesEnabled] 限制：那个开关的
  /// 作用是「别在背后偷偷发流量」，而这里用户就是在明确要求查一次。
  Future<DnsCrossCheck?> crossCheckDomain(String domain) =>
      monitor.crossCheck(domain);

  /// 中国 IP 索引，供界面展示地理判定。默认空表。
  CnIpIndex get cnIpIndex => CnIpIndex.empty;

  /// 用持久化的数据初始化自动纠正表。
  ///
  /// 由界面层在恢复设置后调用。做成独立方法而不是构造函数参数，
  /// 是为了让「内核」与「持久化」保持解耦——内核不认识 `AppStore`。
  ///
  /// 刻意声明为抽象而不是给一个空实现：不做学习的实现（演示内核）必须显式
  /// 写出来，否则「自动纠正在这个平台上悄悄失效」会变成一个看不出来的问题。
  void initAutoRoute(Object? saved);

  /// 导出自动纠正表，供界面层持久化。
  List<Map<String, Object?>> exportAutoRoute();

  /// 本内核是否已经销毁。
  ///
  /// 放在基类而不是各实现自己记：就绪门控会干等最多 20 秒，等待期间必须能判断
  /// 「这个内核还在不在」——原先只有演示内核有这个旗标，真实的两端都拿不到，
  /// 于是安卓端的门控只能靠一个自己新加的字段兜住。
  bool get isDisposed => _isDisposed;
  bool _isDisposed = false;

  void dispose() {
    _isDisposed = true;
    monitor.dispose();
  }
}

/// 演示内核：不建立任何真实隧道，只产生与设计稿一致的界面数据。
///
/// 它的存在只为让界面可以在没有真实内核的情况下被完整走查，
/// 不参与任何真实网络行为。
class DemoVpnCore extends VpnCore {
  DemoVpnCore(super.listener);

  final Random _random = Random(20260214);
  Timer? _trafficTimer;
  Timer? _recordTimer;
  Timer? _connectTimer;
  double _down = 0;
  double _up = 0;
  int _total = 0;
  int _directTotal = 0;
  int _proxiedTotal = 0;
  int _hostIndex = 0;

  @override
  String get name => 'demo';

  /// 演示内核同样模拟「系统代理已设置」，因此报出真实实现会用到的默认端口。
  ///
  /// 返回 null 会让界面显示成裸的 `127.0.0.1`——那是**假信息**，而演示内核的
  /// 用途恰恰是让界面在没有真实内核时也能被完整走查。
  @override
  String get takeOverEndpoint =>
      '127.0.0.1:${SingBoxConfigBuilder.defaultMixedPort}';

  /// 演示内核不维护规则库：它没有任何真实分流，「检查更新」在这里无从谈起。
  ///
  /// 显式返回 null 而不是继承基类默认的桌面端目录：否则界面上的「检查更新」
  /// 会在演示内核下真的往 `%LOCALAPPDATA%\XVPN` 写东西，而那个目录与演示内核
  /// 毫无关系——正是本轮要消掉的那种「做了但没意义」的假动作。
  @override
  Future<Directory?> ruleSetUpdateDir() async => null;

  /// 演示内核不参与自动纠正：它没有真实的连接失败，也就没有可学的证据。
  ///
  /// 显式写出来而不是继承一个默认空实现——自动纠正在这里「安静地不生效」
  /// 是预期行为，而不是一个看不出来的缺陷。
  @override
  void initAutoRoute(Object? saved) {}

  @override
  List<Map<String, Object?>> exportAutoRoute() =>
      const <Map<String, Object?>>[];

  /// 演示数据：域名与预期判定，覆盖两种分流路径与三种命中规则。
  ///
  /// 规则名刻意写成**内核真实的原始描述文本**（`rule_set=[...] => route`），
  /// 并经过与真实链路完全相同的归一化函数，这样界面上走的代码路径与接上真实
  /// 内核时一模一样。此前这里直接给的是 `geosite-cn` 这种成品名，于是
  /// 「界面显示内核术语」的问题在演示数据上永远暴露不出来。
  static const _demoTargets = <(String, RouteKind, String)>[
    ('www.youtube.com', RouteKind.proxy, 'final'),
    (
      'www.baidu.com',
      RouteKind.direct,
      'rule_set=[geosite-cn geoip-cn] => route',
    ),
    ('api.openai.com', RouteKind.proxy, 'final'),
    (
      '192.0.2.148',
      RouteKind.direct,
      'rule_set=[geosite-cn geoip-cn] => route',
    ),
    ('github.com', RouteKind.proxy, 'final'),
    (
      'npmmirror.com',
      RouteKind.direct,
      'rule_set=[geosite-cn geoip-cn] => route',
    ),
    ('192.168.1.1', RouteKind.direct, 'ip_is_private=true => route'),
    ('cdn.jsdelivr.net', RouteKind.proxy, 'final'),
    ('taobao.com', RouteKind.direct, 'rule_set=[geosite-cn geoip-cn] => route'),
    ('x.com', RouteKind.proxy, 'final'),
  ];

  @override
  Future<void> connect(
    VpnProfile profile,
    AppSettings settings, {
    ConnectAttempt? attempt,
  }) async {
    listener.onStatusChanged(VpnStatus.connecting);
    await Future<void>.delayed(const Duration(milliseconds: 700));
    // 演示内核也必须遵守取消约定：用户在这 700ms 里按了取消，本轮已经作废，
    // 绝不能事后再把状态翻回「已连接」——那正是界面取消按钮要防住的那类竞态。
    if (isDisposed || (attempt?.isCancelled ?? false)) return;
    listener.onStatusChanged(VpnStatus.connected);
    listener.onLatency(38 + _random.nextInt(20));
    _startTraffic();
    if (settings.logSplits) _startRecords();
  }

  @override
  Future<void> disconnect() async {
    _trafficTimer?.cancel();
    _recordTimer?.cancel();
    _connectTimer?.cancel();
    _trafficTimer = null;
    _recordTimer = null;
    _down = 0;
    _up = 0;
    listener.onTraffic(downBps: 0, upBps: 0, totalBytes: _total);
    listener.onStatusChanged(VpnStatus.disconnected);
  }

  void _startTraffic() {
    // 先取消上一个：connect 可能被连续调用（切配置、改密码都会重建连接），
    // 而这里若直接覆盖字段，旧的那个每秒定时器就成了没人持有的孤儿——
    // 它会一直跑下去，流量数字按两倍速往上跳，测试里还会表现为「有未完成的
    // 定时器」。
    _trafficTimer?.cancel();
    // 首帧立即给一个非零值，避免界面出现 0.00 MB/s 的空白感。
    _down = 1.1 * 1024 * 1024;
    _up = 300 * 1024;
    _emitTraffic();
    _trafficTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _down = _walk(_down, 220 * 1024, 2.4 * 1024 * 1024);
      _up = _walk(_up, 60 * 1024, 900 * 1024);
      final delta = (_down + _up).round();
      _total += delta;
      // 演示内核也把总量拆成两条路径，界面上的分流占比才有数据。
      final kind = _hostIndex.isEven ? RouteKind.proxy : RouteKind.direct;
      if (kind == RouteKind.proxy) {
        _proxiedTotal += delta;
      } else {
        _directTotal += delta;
      }
      _emitTraffic();

      // 同时上报**按目标的流量增量**，与真实内核走同一条路径。
      //
      // 不补这一步的话，演示内核下「本次分流」那行永远是空的——而它的用途正是
      // 让界面在没有真实内核时也能被完整走查。演示数据必须流经与真实内核相同的
      // 代码路径，否则它掩盖的恰恰是要检查的东西。
      final (target, _, _) = _demoTargets[_hostIndex % _demoTargets.length];
      listener.onConnectionTraffic(
        ConnectionTraffic(
          target: target,
          kind: kind,
          // 演示数据按 7:3 分配上下行，让两列都有非零值。
          uploadDelta: (delta * 0.3).round(),
          downloadDelta: delta - (delta * 0.3).round(),
        ),
      );
    });
  }

  double _walk(double current, double min, double max) {
    final next = current + (_random.nextDouble() - 0.45) * (max - min) * 0.35;
    return next.clamp(min, max);
  }

  void _emitTraffic() {
    listener.onTraffic(
      downBps: _down,
      upBps: _up,
      totalBytes: _total,
      directBytes: _directTotal,
      proxiedBytes: _proxiedTotal,
      connectionCount: 6 + _hostIndex % 5,
    );
  }

  void _startRecords() {
    // 同上：重复连接不能留下上一个记录定时器。
    _recordTimer?.cancel();
    _recordTimer = Timer.periodic(const Duration(milliseconds: 2600), (_) {
      final (target, kind, rule) =
          _demoTargets[_hostIndex % _demoTargets.length];
      _hostIndex++;
      listener.onSplitRecord(
        SplitRecord(
          time: DateTime.now(),
          target: target,
          kind: kind,
          // 走与真实内核相同的归一化路径，保证演示数据不会掩盖界面问题。
          rule: normalizeRuleDescription(rule),
          outbound: kind == RouteKind.proxy ? 'vpn' : 'direct',
        ),
      );
    });
  }

  @override
  void dispose() {
    _trafficTimer?.cancel();
    _recordTimer?.cancel();
    _connectTimer?.cancel();
    // 处置状态由基类统一记账（见 VpnCore.isDisposed）。
    super.dispose();
  }
}
