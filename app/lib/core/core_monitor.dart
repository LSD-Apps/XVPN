/// 两端共用的观测引擎。
///
/// Windows 与 Android 的差别只有「内核怎么跑」和「流量怎么接管」，而连接观测、
/// 速率统计、失败归因、DNS 监测、自动纠正这些逻辑完全一致。这份代码此前被复制
/// 在两处（`singbox_runner.dart` 与 `android_vpn_core.dart`），已经出现过
/// 「一端修好、另一端还是旧行为」的问题。现在统一到这里，两端只保留
/// 启动/停止与平台交互。
///
/// 主要职责：
///
///   1. **读 Clash API 并保持只读一次**。一个长连接复用 [HttpClient]，
///      不再每次轮询都新建 TCP 连接。
///   2. **只做必要的工作**。累计流量每秒都要更新；连接列表只在出现新连接时
///      才完整构造对象；已见过的连接稳态轮次只读 id/上下行三个字段。
///      速率、DNS、自检各有自己的节奏，不互相拖累。
///   3. **把观测结果转成对用户有意义的结论**：失败归因、DNS 健康、
///      自动纠正了哪些域名。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models.dart';
import 'auto_route.dart';
import 'clash_api.dart';
import 'cn_ip_index.dart';
import 'core_log.dart';
import 'dns_client.dart';
import 'dns_monitor.dart';
import 'mtu_probe.dart';
import 'outbound_tags.dart';
import 'port_allocator.dart';
import 'record_buffer.dart';
import 'singbox_config.dart';
import 'startup_self_check.dart';
import 'tunnel_health.dart';
import 'vpn_core.dart';
import 'wireguard_handshake.dart';

/// 一条连接在本机侧留下的最后状态。
///
/// 存在的理由：内核只给「当前活着的连接」，连接一关闭就从快照里消失。而判定
/// 它是否挂死，恰恰需要它**关闭那一刻**的字节数与存活时长。因此在每条连接存活
/// 期间逐轮刷新这里的字段，关闭时用它做判定。
class _ConnectionTrace {
  _ConnectionTrace({
    required this.host,
    required this.target,
    required this.direct,
    required this.upload,
    required this.download,
    this.startedAt,
    required this.lastSeenAt,
  }) : firstSeenAt = lastSeenAt;

  String host;

  /// 展示用目标（域名或 IP:port）。稳态轮次靠它归并增量，避免每秒再 fromJson。
  String target;

  final bool direct;

  /// 该连接累计上传 / 下载字节（内核计数，只增不减）。
  ///
  /// 分开存是为了让流量增量按方向精确差分，而不是只存总量再按比例拆。
  int upload;
  int download;

  /// 该连接累计交付的字节数（上传 + 下载）。质量判定用总量。
  int get bytes => upload + download;

  RouteKind get kind => direct ? RouteKind.direct : RouteKind.proxy;

  /// 内核给出的连接建立时间。缺失时退回本机首次看到它的时刻。
  final DateTime? startedAt;

  /// 本机首次看到它的时刻。
  final DateTime firstSeenAt;

  /// 本机最后一次看到它仍活着的时刻。
  DateTime lastSeenAt;

  /// 存活时长。用「最后看到」而不是「现在」作为终点：连接已经关闭，
  /// 用当前时刻会把之后每一轮的等待时间也算进去，越晚判定显得活得越久。
  Duration get alive => lastSeenAt.difference(startedAt ?? firstSeenAt);
}

/// 观测引擎的依赖注入点。
class CoreMonitorHooks {
  CoreMonitorHooks({
    required this.listener,
    required this.clashApiPort,
    this.autoRoute,
    LearningPolicy? learningPolicy,
    CnIpIndex? cnIpIndex,
    this.dnsResolver,
    this.probesEnabled = true,
    this.httpClient,
    this.tunnelLatencyProbe,
    this.directLatencyProbe,
    this.onHealth,
    this.latencyProbeInterval = CoreMonitor.latencyInterval,
    this.unreachableThreshold = CoreMonitor.defaultUnreachableThreshold,
    this.warmupSince,
    this.mixedPort,
    this.declaredMtu,
  }) : cnIpIndex = cnIpIndex ?? CnIpIndex.empty,
       // 默认跟随自动纠正表的策略：那样「整套阈值只有一处」是自动成立的，
       // 不需要调用方记得让观测层与表保持一致。
       learningPolicy =
           learningPolicy ?? autoRoute?.policy ?? const LearningPolicy();

  final VpnCoreListener listener;

  /// Clash API 端口。
  ///
  /// **可变**，理由与 [cnIpIndex] 相同：端口在连接时才最终确定。默认的 2081
  /// 被占用时内核会换一个端口监听（见 [PortAllocator]），而观测引擎是构造期
  /// 就建好的，只有让它每次读取时都拿最新值，才不会一直去问一个没人听的端口。
  int clashApiPort;

  /// 自动纠正表。为 null 时不做学习，行为与改造前一致。
  final AutoRouteTable? autoRoute;

  /// 学习策略（阈值、判据、限流窗口）。
  ///
  /// 由外部注入而不是让观测层自带一份：策略属于学习机制，而观测层只负责把
  /// 一条连接的最终状态翻译成证据。默认取表的策略——那样「一套阈值」这件事
  /// 是自动成立的，不需要调用方记得让两处一致。
  final LearningPolicy learningPolicy;

  /// 中国 IP 索引，用于 DNS 交叉校验的地理判定。
  ///
  /// 可变字段而不是 final：索引是异步加载的（首次连接时才读盘），
  /// 而观测引擎在更早就建好了。加载完成后赋值即可，下一次 DNS 监测就会用上。
  CnIpIndex cnIpIndex;

  /// DNS 查询实现。默认走真实 UDP；测试可注入桩。
  final DnsResolver? dnsResolver;

  /// 是否允许主动探测（DNS 监测、启动自检、直连连通性）。
  ///
  /// 关掉之后「被动观测」（Clash API 轮询、速率、分流记录、失败归因）照常工作。
  /// 之所以做成可关闭：
  ///   * 单元测试里不该真的发 UDP 包与 TCP 连接；
  ///   * 计量网络或用户明确不希望后台流量时，需要一条只读不探的模式。
  final bool probesEnabled;

  /// Clash API 的 HTTP 客户端。为 null 时由观测引擎自建并复用。
  ///
  /// 做成可注入是为了让「一轮采样到底上报了什么数字」可以被真正测到——
  /// 那是界面上所有统计的唯一来源，只靠读代码确认等于没测。
  final HttpClient? httpClient;

  /// 隧道延迟探测。默认走内核的 `/proxies/{tag}/delay`。
  ///
  /// 可注入的理由与 [httpClient] 相同：健康判定是「连续失败多少次 → 该不该
  /// 自动恢复」的逻辑，必须在**不真的连网**的前提下被完整测到，否则只能靠
  /// 拔网线来验证。
  final Future<int?> Function()? tunnelLatencyProbe;

  /// 直连延迟探测。默认直连访问一个固定的可达站点。
  ///
  /// 它是健康判定的对照组：只有「直连通、隧道不通」才说明问题在隧道这一侧。
  /// 同理做成可注入。
  final Future<int?> Function()? directLatencyProbe;

  /// 隧道健康结论的**决策**回调。
  ///
  /// [listener] 负责显示，这里负责行动。分成两条路是必要的：要重启内核的
  /// 是内核实现自己，而它只是观测引擎的一个持有者，不该被塞进界面回调里。
  final void Function(TunnelHealth health)? onHealth;

  /// 两次延迟探测之间的最小间隔。
  ///
  /// 可注入是为了让「连续失败三次后触发健康判定」这条链路能被直接测到：
  /// 否则一个用例要真等 45 秒，等于没法测。
  final Duration latencyProbeInterval;

  /// 连续多少次读不到内核才判定「内核卡住」。
  ///
  /// 可注入的理由同上：测试不该为了验证一个阈值等 5 秒。
  final int unreachableThreshold;

  /// 预热宽限期的起点。为 null 时由 [CoreMonitor.start] 取当时时刻。
  ///
  /// 可注入是为了让「预热窗口内不下故障结论」这条能被直接测到：否则一个用例
  /// 只能靠真的等 12 秒，而 `start()` 又会顺手拉起真实 DNS 与自检探测，
  /// 把一个纯逻辑用例变成一次真实网络访问。
  final DateTime? warmupSince;

  /// 内核混合入站的端口，MTU 校验要从这里把包送进隧道。
  ///
  /// 与 [clashApiPort] 同理是**可变**的：端口在连接时才最终确定（默认端口被占
  /// 时会换一个）。为 null 表示还没有可用端口，此时不做 MTU 校验。
  int? mixedPort;

  /// 配置里声明的 Tunnel MTU（字节）。为 null 表示没声明，校验直接跳过。
  int? declaredMtu;
}

/// 观测引擎。
class CoreMonitor {
  CoreMonitor(this.hooks)
    : _autoRoute = hooks.autoRoute,
      _connectedSince = hooks.warmupSince,
      _http =
          hooks.httpClient ??
          (HttpClient()
            ..connectionTimeout = const Duration(seconds: 3)
            ..idleTimeout = const Duration(seconds: 30));

  final CoreMonitorHooks hooks;
  final AutoRouteTable? _autoRoute;

  /// 复用的 HTTP 客户端。
  ///
  /// 原实现每次轮询都 `HttpClient()` + `close(force: true)`，即每秒建立并
  /// 拆除一次 TCP 连接。本地回环上这不算致命，但它同时意味着每秒一次的
  /// 三向握手与四次挥手，在连接数很大、界面本来就在吃力时是纯粹的额外负担。
  ///
  /// 由 [CoreMonitorHooks.httpClient] 注入时不再由本对象关闭——那属于调用方。
  final HttpClient _http;

  /// 已上报过的连接 id。有容量上限，见 [BoundedIdSet]。
  ///
  /// 原实现在长度超过 2000 时整体 `clear()`，那一刻「当前活着的每条连接」
  /// 都会被当成新连接重新上报，分流记录里立刻出现成片重复。
  static const int seenCapacity = 4000;

  final BoundedIdSet _seen = BoundedIdSet(seenCapacity);

  final RateCalculator _rate = RateCalculator();

  /// 学习策略。所有权重的阈值与判据都在 `route_learning.dart`，本层只负责
  /// **观测**——把一条连接的最终状态翻译成「该记哪种证据」。
  LearningPolicy get policy => hooks.learningPolicy;

  /// 同类观测的时间窗限流。见 [OutcomeThrottle]。
  ///
  /// 放在本层而不是策略模块：限流要回答的是「这段时间里这个域名记过几次」，
  /// 而那是观测层的知识——策略只规定窗口有多长。
  late final OutcomeThrottle _throttle = OutcomeThrottle(policy: policy);

  /// 待探测「是否本该直连」的隧道目标。
  ///
  /// 反方向自动纠正的输入队列：新出现的走隧道域名先排进来，之后按
  /// [candidateInterval] 一批一批去探测。做成「积压 + 分批」而不是「见到就探」，
  /// 是因为每次探测都要占一次隧道往返（`DnsMonitor.crossCheck`），一次全探
  /// 会与其它探测抢带宽，还会把耗时测成排队时间。
  final List<String> _directCandidates = <String>[];

  /// 已经在队列里的域名，避免同一域名被反复排入。
  final Set<String> _directCandidateSeen = <String>{};

  /// 队列容量。满了丢最旧的：这是「最近谁在走隧道」的近期证据，
  /// 不需要长期记忆，而无界队列在异常流量下会一直涨。
  static const int candidateBacklogCapacity = 64;

  /// 每轮最多探测几个域名。
  static const int candidatesPerRound = 2;

  /// 两轮候选探测之间的间隔。
  static const Duration candidateInterval = Duration(seconds: 30);

  Timer? _candidateTimer;

  /// 候选探测是否有一轮在跑。与 [_tickRunning] 同理：慢探测不该被定时器叠起来。
  bool _candidateProbeRunning = false;

  late final DnsResolver _dnsResolver = hooks.dnsResolver ?? UdpDnsResolver();

  /// 隧道与直连探测的实现。默认走真实网络，测试可注入桩。
  late final Future<int?> Function() _tunnelProbe =
      hooks.tunnelLatencyProbe ?? probeTunnelLatency;
  late final Future<int?> Function() _directProbe =
      hooks.directLatencyProbe ?? probeDirectLatency;

  DnsMonitor? _dnsMonitor;
  StartupSelfCheck? _selfCheck;

  int _lastConnectionCount = 0;
  int _kernelMemory = 0;

  /// 本轮采样是否还在跑。慢探测（DNS 超时、内核卡住）会让定时器一轮接一轮地
  /// 叠起来，最终表现为界面越来越卡、数字越来越乱，因此要显式防重入。
  bool _tickRunning = false;

  bool _disposed = false;

  /// 轮询周期。1 秒是「够快」与「别浪费」之间的折中：
  /// 界面上速率与记录都按秒刷新，再快也只是重复同样的数字。
  static const Duration pollInterval = Duration(seconds: 1);

  /// DNS 监测间隔。DNS 状态不会每秒都变，探测本身要发 UDP 包，
  /// 频繁探测既浪费带宽也会把「耗时」测成排队时间。
  static const Duration dnsInterval = Duration(seconds: 45);

  /// 延迟探测间隔。
  static const Duration latencyInterval = Duration(seconds: 15);

  /// 连续失败多少次才算「隧道可能不正常」。
  ///
  /// 定在 3 而不是 1：单次失败多半只是网络抖动，用它触发自愈会造成
  /// 「一抖动就重连」，那比不重连更影响体验。
  static const int unhealthyThreshold = 3;

  /// 连续多少次读不到内核才判定「内核卡住」。
  ///
  /// 定在 5：轮询周期是 1 秒，也就是给内核 5 秒的宽限。内核在重负载下偶尔
  /// 一次应答超时是正常的，但连续 5 秒完全不应答就不是「忙」了。
  static const int defaultUnreachableThreshold = 5;

  Timer? _pollTimer;
  Timer? _dnsTimer;
  Timer? _selfCheckTimer;
  DateTime? _lastLatencyProbe;
  int _latencyFailures = 0;

  /// 上一次已上报的健康结论。
  ///
  /// 只在**结论变化**时上报：否则每 15 秒一条「隧道还是不通」，界面会被
  /// 同样的句子刷满，真正重要的状态切换反而被埋掉。
  TunnelHealthVerdict? _lastHealthVerdict;

  /// 连续多少次采样没能从内核读到数据。
  int _tickFailures = 0;

  /// 本会话开始观测的时刻，用于「刚连上」的预热宽限期判定。
  ///
  /// 构造期就取 [CoreMonitorHooks.warmupSince]，而不是只在 [start] 里赋值：
  /// 后者一旦漏调（或探测先于 start 发生），这里就是 null，而
  /// [isWithinWarmupWindow] 对 null 一律返回 false——宽限期会被**静默关闭**，
  /// 预热期的失败又会被当成节点故障。默认值放在构造期，这个失效路径就不存在。
  DateTime? _connectedSince;

  AutoRouteTable? get autoRoute => _autoRoute;

  int get connectionCount => _lastConnectionCount;

  int get kernelMemory => _kernelMemory;

  // ---------------------------------------------------------------- 生命周期

  /// 内核就绪后调用。清空上一次会话的观测状态并开始定时采样。
  ///
  /// [since] 是**隧道开始建立**的时刻，预热宽限期从它算起。默认取当前时刻，
  /// 但连接路径应当把更早的那个真实起点传进来：门控本身可能已经花掉几秒，
  /// 若这里再重置一次，就等于把已经等过的时间一笔勾销——门控都确认隧道通了，
  /// 紧接着一次探测失败又会报「隧道不通」。
  void start({DateTime? since}) {
    _seen.clear();
    _throttle.clear();
    // 连接轨迹必须清掉：上一次会话的连接 id 不会重现，留着会让第一次
    // 质量判定把「上一轮的旧轨迹」当成一条刚关闭的连接。
    _connTraces.clear();
    _rate.reset();
    _lastLatencyProbe = null;
    _latencyFailures = 0;
    _lastHealthVerdict = null;
    _tickFailures = 0;
    _lastConnectionCount = 0;
    _kernelMemory = 0;
    // 预热宽限期从这里开始：隧道刚建好时握手可能还没完成，这段窗口内的探测
    // 失败属于正常现象，不能当成节点故障（否则用户会看到一句错误的「换节点」）。
    _connectedSince = since ?? hooks.warmupSince ?? DateTime.now();
    // 握手状态是「本次连接」的事实，跨连接保留会让用户看着上一次的结论排查
    // 这一条隧道。日志缓冲刻意跨重连保留，这一项则不。
    _handshake = WireGuardHandshake.unknown;

    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(pollInterval, (_) => unawaited(tick()));

    if (hooks.probesEnabled) {
      _ensureDnsMonitor();
      _dnsMonitor?.reset();
      _dnsTimer?.cancel();
      _dnsTimer = Timer.periodic(dnsInterval, (_) => unawaited(refreshDns()));

      // 反方向自动纠正的驱动：探测「走隧道的域名是否本该直连」。
      // 只在有自动纠正表时启用——没有表就没有地方写结论。
      if (_autoRoute != null) {
        _directCandidates.clear();
        _directCandidateSeen.clear();
        _candidateTimer?.cancel();
        _candidateTimer = Timer.periodic(
          candidateInterval,
          (_) => unawaited(probeDirectCandidates()),
        );
      }

      _selfCheckTimer?.cancel();
      _selfCheckTimer = Timer.periodic(
        const Duration(minutes: 10),
        (_) => unawaited(runSelfCheck()),
      );

      // 第一轮尽快跑：界面在连上之后的几秒内就能看到真实结论，
      // 而不是先空白一分多钟。
      unawaited(refreshDns());
      unawaited(runSelfCheck());
      // 自动做一次 DNS 交叉校验：界面一直承诺「连接后会校验」，
      // 而在此之前它只发生在「连接失败学习」与「手动查证」两条路径上，
      // 于是一般会话里结论永远是「未校验」。延后一点执行，避免与
      // 上面两个探测抢带宽、把耗时测成排队时间。
      unawaited(
        Future<void>.delayed(const Duration(seconds: 3), runInitialDnsCheck),
      );
    }
  }

  void stop() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _dnsTimer?.cancel();
    _dnsTimer = null;
    _candidateTimer?.cancel();
    _candidateTimer = null;
    _selfCheckTimer?.cancel();
    _selfCheckTimer = null;
    _rate.reset();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    stop();
    _dnsResolver.close();
    // 注入进来的客户端由调用方负责关闭，避免测试里出现「用完之后被自己关掉」。
    if (hooks.httpClient == null) {
      try {
        _http.close(force: true);
      } on Object {
        // 关闭失败无所谓。
      }
    }
  }

  void _ensureDnsMonitor() {
    if (_dnsMonitor != null) {
      // 索引可能是异步加载完成后才到位的，这里同步一次。
      _dnsMonitor!.cnIpIndex = hooks.cnIpIndex;
      return;
    }
    final monitor = DnsMonitor(
      config: const DnsMonitorConfig(
        domesticServers: SingBoxConfigBuilder.domesticDns,
        tunnelProbeUrl: tunnelProbeUrl,
      ),
      resolver: _dnsResolver,
      tunnelLatencyProbe: _tunnelProbe,
      cnIpIndex: hooks.cnIpIndex,
    );
    // 经内核 DNS 模块解析，用于交叉校验的第二组答案。
    monitor.tunnelResolveProbe = resolveViaCoreDns;
    _dnsMonitor = monitor;

    _selfCheck ??= StartupSelfCheck(
      directProbe: _directProbe,
      tunnelProbe: _tunnelProbe,
      coreResolve: resolveViaCoreDns,
      domesticResolve: _resolveDomestically,
    );
  }

  // ---------------------------------------------------------------- 每次采样

  /// 跑一轮采样。可以安全地重复调用（例如手动刷新）。
  Future<void> tick() async {
    // 上一轮还没结束时直接跳过：慢探测（DNS 超时、内核卡住）会让每一轮都
    // 叠在一起，最终表现为界面越来越卡、数字越来越乱。
    if (_tickRunning || _disposed) return;
    _tickRunning = true;
    try {
      final body = await _get('/connections');
      if (body == null) {
        _onTickMissed();
        return;
      }
      _onTickSucceeded();
      Map<String, Object?> json;
      try {
        json = jsonDecode(body) as Map<String, Object?>;
      } on Object {
        return;
      }

      // 1) 累计流量与活连接数：每秒都要更新。
      //
      // 不再每轮遍历连接算「活连接上的隧道/直连字节」——界面占比用的是
      // session*（按连接增量累加），那一套活连接快照对短连接永远偏空，而且
      // 每秒扫一遍 chains 是纯浪费。连接数取列表长度即可。
      final totals = ClashSnapshot.totalsOf(json);
      _kernelMemory = totals.memory;
      final sample = _rate.sample(
        DateTime.now(),
        totals.downloadTotal,
        totals.uploadTotal,
      );
      if (sample != null) {
        final rawList = json['connections'];
        final connectionCount = rawList is List ? rawList.length : 0;
        _lastConnectionCount = connectionCount;
        hooks.listener.onTraffic(
          downBps: sample.downBps,
          upBps: sample.upBps,
          totalBytes: sample.totalBytes,
          connectionCount: connectionCount,
          kernelMemory: totals.memory,
        );
      }

      // 2) 新连接：只有这一路需要构造对象与拼字符串。
      _emitNewConnections(json);

      // 2b) 流量增量：界面把同目标的记录合并成一行，需要把每条连接这次新增的
      //     字节累加到那一行上。放在这里是因为连接列表已经在手上，不必再解析一次。
      _emitTrafficDeltas(json);

      // 3) 延迟探测按自己的节奏走。
      await probeLatency();
    } finally {
      _tickRunning = false;
    }
  }

  static int _int(Object? raw) {
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw) ?? 0;
    return 0;
  }

  /// 把「每条连接累计多少字节」换算成「本目标这一轮新增多少」，上报给界面。
  ///
  /// 为什么必须算增量：内核的 `upload` / `download` 是**该连接的累计值**，
  /// 直接累加会让数字随轮询次数成倍膨胀。相减之后才是真实新增。
  ///
  /// **首次见到**就把当前累计值记为一笔增量：HTTP 类短连接经常只出现在一轮
  /// 快照里就关闭，若跳过首见字节，整段流量永远进不了「隧道/直连」统计——
  /// 那正是统计卡无法真实呈现分流占比的根因。
  ///
  /// 仍可能略少：两次轮询之间已关闭连接的最后约 0～1 秒增长，以及内核本身
  /// 就不进 `/connections` 的 DNS 流量。因此相对内核全局总量是接近精确的
  /// 下界，不会虚高。质量判定仍在连接消失时消费账本（见
  /// [_emitClosedConnectionQuality]）。
  ///
  /// **稳态热路径**只读 id / upload / download 三个字段，不再每秒
  /// `ClashConnection.fromJson`：目标与出站在首见时已写入账本。观测与分流
  /// 数据处理共用同一个 isolate，这里每秒多分配就会直接推迟分流记录处理。
  void _emitTrafficDeltas(Map<String, Object?> json) {
    final rawList = json['connections'];
    if (rawList is! List) {
      // 读不到列表时**不能**清空账本、也不做质量判定：两种误动作都会把
      // 「读不到」当成「连接已关闭/没有流量」。留着旧值最多让某条连接的
      // 增量算成 0。
      return;
    }

    final live = <String>{};
    final now = DateTime.now();
    // 同一目标可能同时有多条连接，先把增量按目标归并再一次上报，
    // 避免一秒内为同一个域名回调十几次。
    //
    // 键里必须带 kind：同一个目标在同一秒内既有直连又有代理连接是可能的
    // （例如先被判直连、后续连接走了隧道）。只按目标归并会让两路字节被合并到
    // 「最后一条连接」的方向上，于是会话占比统计把一整份混合流量记到其中一路。
    final deltas = <(String, RouteKind), ({int up, int down})>{};

    for (final raw in rawList) {
      if (raw is! Map) continue;
      final id = ClashConnection.idOf(raw);
      if (id.isEmpty) continue;
      live.add(id);

      final map = raw.cast<String, Object?>();
      final upload = _int(map['upload']);
      final download = _int(map['download']);
      final trace = _connTraces[id];

      late final int upDelta;
      late final int downDelta;
      late final String target;
      late final RouteKind kind;

      if (trace != null) {
        // 热路径：账本里已有目标与方向，只做上下行差分。
        final rawUp = upload - trace.upload;
        final rawDown = download - trace.download;
        upDelta = rawUp < 0 ? 0 : rawUp;
        downDelta = rawDown < 0 ? 0 : rawDown;
        trace.upload = upload;
        trace.download = download;
        trace.lastSeenAt = now;
        target = trace.target;
        kind = trace.kind;
        // 有流量活动时才读 metadata.host：稳态无增量的连接不必每秒解析。
        if (upDelta > 0 || downDelta > 0) {
          final host = _hostOf(map);
          if (host.isNotEmpty) trace.host = host;
        }
      } else {
        // 冷路径（首见）：完整解析一次，把 target/kind 写入账本供后续热路径用。
        final conn = ClashConnection.fromJson(raw);
        if (conn == null) {
          live.remove(id);
          continue;
        }
        upDelta = conn.upload < 0 ? 0 : conn.upload;
        downDelta = conn.download < 0 ? 0 : conn.download;
        target = conn.target;
        kind = conn.proxied ? RouteKind.proxy : RouteKind.direct;
        _connTraces[id] = _ConnectionTrace(
          host: conn.host,
          target: conn.target,
          direct: !conn.proxied,
          upload: conn.upload,
          download: conn.download,
          startedAt: conn.startedAt,
          lastSeenAt: now,
        );
      }

      if (upDelta <= 0 && downDelta <= 0) continue;

      final key = (target, kind);
      final previousOfTarget = deltas[key];
      deltas[key] = (
        up: (previousOfTarget?.up ?? 0) + upDelta,
        down: (previousOfTarget?.down ?? 0) + downDelta,
      );
    }

    // 已关闭的连接：清账目，并按最终字节数与存活时长判定质量。
    _emitClosedConnectionQuality(live);

    for (final entry in deltas.entries) {
      hooks.listener.onConnectionTraffic(
        ConnectionTraffic(
          target: entry.key.$1,
          kind: entry.key.$2,
          uploadDelta: entry.value.up,
          downloadDelta: entry.value.down,
        ),
      );
    }
  }

  /// 只读 metadata.host，供热路径偶尔刷新嗅探结果。
  static String _hostOf(Map<String, Object?> json) {
    final rawMetadata = json['metadata'];
    if (rawMetadata is! Map) return '';
    return rawMetadata['host']?.toString() ?? '';
  }

  /// 新连接 → 分流记录，并顺带把走隧道的流量按域名累计。
  ///
  /// 注意这里**不再**判定「直连成功」。原因见
  /// [LearningPolicy.classifyDirectConnection]：一条连接刚出现时它的字节数还没有
  /// 意义（新连接往往只有几百字节的首包），当时就下结论会把「握手成功、随后挂住」
  /// 误判成成功。现在改为在该连接**消失之后**按它的最终字节数与存活时长判定。
  void _emitNewConnections(Map<String, Object?> json) {
    final fresh = ClashSnapshot.pullNew(json, _seen);
    if (fresh.isEmpty) return;
    final table = _autoRoute;
    for (final conn in fresh) {
      hooks.listener.onSplitRecord(
        SplitRecord(
          time: DateTime.now(),
          target: conn.target,
          kind: conn.proxied ? RouteKind.proxy : RouteKind.direct,
          rule: conn.rule,
          outbound: conn.outbound,
        ),
      );
      if (table == null) continue;
      final host = conn.host.isNotEmpty ? conn.host : '';
      if (host.isEmpty) continue;
      if (conn.proxied) {
        table.recordProxiedBytes(host, conn.totalBytes);
        // 顺带排入反方向纠正的候选：走隧道的域名里，可能有本该直连的。
        // 这里只入队，不做探测——探测要占隧道往返，见 [probeDirectCandidates]。
        _enqueueDirectCandidate(host, table);
      }
    }
  }

  // ------------------------------------------------- 直连连接的质量判定

  /// 逐轮记录每条连接的最后状态，用于在它**消失之后**做质量判定。
  ///
  /// 键是连接 id。连接关闭时从内核列表里消失，那一刻本机手里留着它最后已知的
  /// 字节数与时间戳——这正好是判定所需的两项。因此把 [ClashConnection.startedAt]
  /// （此前被解析但从未被使用）用起来。
  final Map<String, _ConnectionTrace> _connTraces = <String, _ConnectionTrace>{};

  /// 消费「本轮消失了」的连接：对每一条做质量判定并转成学习证据。
  ///
  /// [live] 是本轮仍活着的连接 id 集合。
  void _emitClosedConnectionQuality(Set<String> live) {
    if (_connTraces.length <= live.length) return;
    final table = _autoRoute;
    final now = DateTime.now();

    final closed = _connTraces.entries
        .where((MapEntry<String, _ConnectionTrace> e) => !live.contains(e.key))
        .toList(growable: false);

    for (final entry in closed) {
      _connTraces.remove(entry.key);
      if (table == null) continue;
      final trace = entry.value;
      final outcome = policy.classifyDirectConnection(
        direct: trace.direct,
        bytes: trace.bytes,
        alive: trace.alive,
      );
      final domain = AutoRouteTable.normalizeDomain(trace.host);
      if (domain.isEmpty) continue;
      switch (outcome) {
        case DirectOutcome.delivered:
          // 限流：一次页面加载会开出几十条连接，同一个域名的同类观测在时间窗内
          // 只记一次，否则阈值会被突发刷满。
          if (!_throttle.tryRecord(EvidenceKind.delivery, domain, now)) continue;
          table.recordDirectSuccess(trace.host);
        case DirectOutcome.stalled:
          if (!_throttle.tryRecord(EvidenceKind.stall, domain, now)) continue;
          final decision = table.recordDirectStall(
            trace.host,
            reason: '握手成功但 ${trace.bytes} 字节后无数据',
          );
          if (decision.added) hooks.listener.onAutoRouteLearned(decision);
        case DirectOutcome.notApplicable:
        case DirectOutcome.pending:
          break;
      }

      // 交付速率是**独立的第三种证据**：它回答「能通，但够快吗」。
      // 与上面三种质量判定并列而不是替代——一条连接可以「确实交付了」却
      // 慢到用户能察觉（实测有 448 KB 用了 12 秒的样本）。
      //
      // 不走限流：速率要看的是同一路径上的多次采样，把它们折成一次反而
      // 让中位数失去意义。样本够不够格由策略的字节/时长下限把关。
      final alive = trace.alive;
      if (alive > Duration.zero) {
        final decision = table.recordDeliveryRate(
          trace.host,
          direct: trace.direct,
          bytes: trace.bytes,
          duration: alive,
          now: now,
        );
        if (decision != null && decision.added) {
          hooks.listener.onAutoRouteLearned(decision);
        }
      }
    }
  }

  // ------------------------------------------------- 反方向自动纠正（隧道→直连）

  /// 把一个走隧道的域名排入「是否本该直连」的探测队列。
  ///
  /// 过滤掉不必要与没意义的候选：
  ///   * IP 目标与单标签主机名——按域名的规则对它们没有意义；
  ///   * 已有用户规则——用户的决定不该被程序改写；
  ///   * 已经是直连的——没有要改的东西。
  void _enqueueDirectCandidate(String host, AutoRouteTable table) {
    final domain = AutoRouteTable.normalizeDomain(host);
    if (domain.isEmpty) return;
    if (_directCandidateSeen.contains(domain)) return;
    final existing = table.match(domain);
    if (existing != null &&
        (existing.source == RouteRuleSource.user ||
            existing.preference == RoutePreference.forceDirect)) {
      return;
    }
    _directCandidateSeen.add(domain);
    _directCandidates.add(domain);
    while (_directCandidates.length > candidateBacklogCapacity) {
      final evicted = _directCandidates.removeAt(0);
      _directCandidateSeen.remove(evicted);
    }
  }

  /// 探测「走隧道的域名是否本该直连」，并把结论写进自动纠正表。
  ///
  /// 为什么必须有这一步：本程序是白名单式直连，不在 `geosite-cn` 内的域名
  /// **必然**进隧道，而 `geoip-cn` 不参与域名目标的判定（实测见
  /// `docs/RULES.md`）。这类流量不失败、不报错，只白占隧道带宽，因此原先
  /// 唯一能自动纠正的方向是「往隧道里推」。这里补上反方向。
  ///
  /// 证据是**DNS 事实**：该域名的直连解析答案落在 `geoip-cn` 覆盖的网段内。
  /// 拿不到地理信息时不下结论（索引缺失、答案全是 IPv6）——与 `DnsMonitor`
  /// 的保守原则一致：宁可少一次纠正，也不要把正常流量推出隧道。
  Future<void> probeDirectCandidates() async {
    if (_disposed || _candidateProbeRunning) return;
    final table = _autoRoute;
    if (table == null || _directCandidates.isEmpty) return;
    _candidateProbeRunning = true;
    // 本轮需要留到下一轮再探的域名。
    //
    // 必须攒到这里、循环结束后再入队：如果就地重新入队，循环的下一次迭代会
    // **立刻**再探同一个域名，于是「两次独立测量」变成背靠背的两次——证据强度
    // 与它的意图不符（指望的是隔一会的另一次观测，不是同一瞬间重复一次）。
    final requeue = <String>[];
    try {
      for (
        var i = 0;
        i < candidatesPerRound && _directCandidates.isNotEmpty;
        i++
      ) {
        // 从队尾取：队列代表的是一批待查目标，顺序无关紧要，而队尾取出是 O(1)。
        final domain = _directCandidates.removeLast();
        _directCandidateSeen.remove(domain);
        if (_disposed) return;
        // force 是必须的：见 [crossCheck] 的说明——不绕过缓存的话，第二次
        // 「证据」只是重读同一次测量，会让阈值变成假指标。
        final check = await crossCheck(domain, force: true);
        if (check == null) continue;
        final region = classifyRegion(hooks.cnIpIndex, check.domesticAnswers);
        if (region != AddressRegion.domestic) {
          // 不在国内网段：不必再探。答案会随 CDN 调度变化，但为此每 30 秒
          // 占一次隧道往返并不划算——它下次出现在隧道流量里时会重新入队。
          continue;
        }
        final decision = table.recordDomesticAnswer(
          domain,
          reason: '直连解析 ${check.domesticAnswers.join('、')} 落在规则库网段',
        );
        if (decision.added) {
          hooks.listener.onAutoRouteLearned(decision);
        } else {
          // 证据还不够：留到下一轮再测一次独立观测，去凑阈值。
          // 不留的话这个域名只被测一次，阈值永远凑不满——反方向纠正就等于
          // 完全不会生效。
          requeue.add(domain);
        }
      }
    } finally {
      for (final domain in requeue) {
        _enqueueDirectCandidate(domain, table);
      }
      _candidateProbeRunning = false;
    }
  }

  // ---------------------------------------------------------------- 失败归因
  /// 内核日志回调。两端各自把日志行喂进来。
  ///
  /// 这是「自动化智能化分流」的入口：判为直连却失败是唯一能同时说明
  /// 「规则库没覆盖」与「需要改为走隧道」的证据。
  void onCoreLogLine(String line) {
    // 握手状态与失败归因吃的是同一份日志，但两者互不依赖：没有失败的那些行
    // 恰恰是握手最有价值的证据（「收到了应答」本身不是错误行）。
    // 因此这一句必须在失败判空**之前**执行。
    final handshake = parseWireGuardHandshake(line, previous: _handshake);
    if (handshake != null) _handshake = handshake;

    final failure = parseConnectionFailure(line);
    if (failure == null) return;
    hooks.listener.onConnectionFailure(failure);
    unawaited(_learnFromFailure(failure));
  }

  /// 最近观测到的 WireGuard 握手状态。
  ///
  /// 供界面显示。内核换了措辞时它会停在 `unknown`，界面据此不显示这一行——
  /// 宁可少说一句，也不要显示一个猜出来的结论。
  WireGuardHandshake get handshake => _handshake;

  WireGuardHandshake _handshake = WireGuardHandshake.unknown;

  /// 把一次直连失败转成自动纠正的证据。
  ///
  /// 需要 DNS 交叉校验时先补一次校验——它要发 UDP 查询，因此异步做，
  /// 不阻塞日志回调；校验结果会写进证据里，让「答案不一致」的域名
  /// 一次失败即可纠正（见 [AutoRouteTable.recordDirectFailure]）。
  Future<void> _learnFromFailure(ConnectionFailure failure) async {
    final table = _autoRoute;
    if (table == null) return;
    if (!failure.suggestsMissingRule) return;

    String? verdict;
    final monitor = _dnsMonitor;
    if (monitor != null) {
      try {
        final check =
            monitor.cachedCheck(failure.host) ??
            await monitor.crossCheck(failure.host);
        verdict = check.verdict.name;
      } on Object {
        // 校验失败不影响纠正：没有 DNS 证据时按普通阈值处理。
      }
    }

    final decision = table.recordDirectFailure(
      failure.host,
      reason: failure.reasonSummary,
      dnsVerdict: verdict,
    );
    if (decision.added) {
      hooks.listener.onAutoRouteLearned(decision);
    }
  }

  // ---------------------------------------------------------------- DNS 监测

  /// 连接后自动做**一次** DNS 交叉校验。
  ///
  /// 补的是一个「界面承诺了、程序却没做」的缺口：DNS 那一行一直写着「连接后会自动
  /// 完成一次校验」，而实际上交叉校验只在两种情况下发生——某个域名判为直连却失败
  /// （自动纠正的学习路径），或用户手动「查证域名」。于是绝大多数会话里结论永远是
  /// 「未校验」，用户看到的是一个永远不会兑现的承诺。
  ///
  /// 用一个**必定走隧道**的域名来校验：它能同时回答两件事——直连解析器是否可用、
  /// 隧道内解析是否给出不同答案（两套部署或答案不一致）。失败或超时都不影响连接。
  Future<void> runInitialDnsCheck() async {
    if (_disposed) return;
    try {
      await crossCheck(initialDnsCheckDomain);
    } on Object {
      // 校验失败不改变任何连接行为，界面保持「未校验」即可。
    }
  }

  /// 自动校验使用的域名。
  ///
  /// 必须是一个稳定的公开站点：直连解析器对它的答案与隧道内不同，才能形成对照；
  /// 同时它在直连解析器上是可解析的（否则直连那一侧永远失败，结论会退化成「直连异常」）。
  static const String initialDnsCheckDomain = 'www.google.com';

  /// 跑一轮 DNS 监测并上报。
  Future<void> refreshDns() async {
    if (_disposed) return;
    _ensureDnsMonitor();
    final monitor = _dnsMonitor;
    if (monitor == null) return;
    try {
      final report = await monitor.runOnce();
      hooks.listener.onDnsReport(report);
    } on Object {
      // 探测失败不该影响连接：界面保持上一次的报告。
    }
  }

  /// 对一个域名做交叉校验（连接失败时调用，也可由界面主动触发）。
  ///
  /// [force] 为 true 时绕过交叉校验的缓存。反方向纠正需要它：那条路径要求
  /// **多次独立测量**才能改路由，而 `DnsMonitor` 的缓存 TTL 是 10 分钟——
  /// 不绕过缓存的话，第二次「证据」只是把同一次测量重读一遍，等于伪造证据。
  Future<DnsCrossCheck?> crossCheck(String domain, {bool force = false}) async {
    _ensureDnsMonitor();
    final monitor = _dnsMonitor;
    if (monitor == null) return null;
    try {
      return await monitor.crossCheck(domain, force: force);
    } on Object {
      return null;
    }
  }

  Future<List<String>> _resolveDomestically(String domain) async {
    for (final server in SingBoxConfigBuilder.domesticDns) {
      final outcome = await _dnsResolver.query(server, domain);
      if (outcome.resolved) return outcome.answers;
    }
    return const <String>[];
  }

  // ---------------------------------------------------------------- 探测原语

  /// 让内核**经隧道**访问一个地址并计时。
  ///
  /// 用 `/proxies/{tag}/delay` 而不是 ping 服务器 IP：用户关心的是
  /// 「能不能顺畅上网」，而不是「服务器 ICMP 通不通」。内核会真的完成
  /// 解析、TCP 握手与 TLS 握手，回来的是端到端耗时。
  Future<int?> probeTunnelLatency() async {
    final body = await _get(
      '/proxies/${SingBoxConfigBuilder.vpnTag}/delay'
      '?timeout=8000&url=$tunnelProbeUrl',
      timeout: const Duration(seconds: 12),
    );
    if (body == null) return null;
    try {
      final json = jsonDecode(body) as Map<String, Object?>;
      final delay = (json['delay'] as num?)?.toInt();
      return (delay != null && delay > 0) ? delay : null;
    } on Object {
      return null;
    }
  }

  /// 隧道是否已经能载流量的**快速**探测，专供连接流程做就绪门控。
  ///
  /// 与 [probeTunnelLatency] 的区别只在超时：那个走 `/delay?timeout=8000` +
  /// 12 秒 HTTP 超时，适合放在后台按 15 秒一轮观测；这里是连接路径上的等门，
  /// 一次就要几秒的话，20 秒的上限只够试两三次。因此把内核侧超时压到 3 秒、
  /// HTTP 超时压到 4 秒——**内层必须小于外层**，否则内核还没到点，HTTP 先断了，
  /// 失败原因会被记成「读不到 Clash API」而不是「隧道没通」。
  Future<int?> probeTunnelReadiness() async {
    final body = await _get(
      '/proxies/${SingBoxConfigBuilder.vpnTag}/delay'
      '?timeout=3000&url=$tunnelProbeUrl',
      timeout: const Duration(seconds: 4),
    );
    if (body == null) return null;
    try {
      final json = jsonDecode(body) as Map<String, Object?>;
      final delay = (json['delay'] as num?)?.toInt();
      return (delay != null && delay > 0) ? delay : null;
    } on Object {
      return null;
    }
  }

  // ---------------------------------------------------------------- MTU 校验

  /// 最近一次 MTU 校验结论。未校验过时为 null。
  MtuCheck? get mtuCheck => _mtuCheck;
  MtuCheck? _mtuCheck;

  /// 校验「配置里写的 MTU」在这个节点上是否真的能用。
  ///
  /// 做法见 [mtu_probe] 的说明：只测**上传**方向，且只给三种结论。这里负责
  /// 把包送进隧道并计时，判定全部交给纯函数 [evaluateMtuCheck]，因此三种分支
  /// 都能在不联网的前提下被测到。
  ///
  /// 结论通过 [CoreMonitorHooks.listener] 的 `onMtuCheck` 上报；两端都由基类
  /// 转发，不存在「一端有、一端没有」的余地。
  Future<MtuCheck?> checkMtu() async {
    if (_disposed) return null;
    final mtu = hooks.declaredMtu;
    final port = hooks.mixedPort;
    if (mtu == null || mtu <= 0 || port == null) {
      _mtuCheck = const MtuCheck.notDeclared();
      return _mtuCheck;
    }

    // 先试小负载：它决定「隧道到底通不通」。不通就不必再测大包，也绝不能
    // 把结论说成 MTU 问题。
    final smallPassed = await _uploadThroughTunnel(
      port: port,
      bodyBytes: mtuProbeSmallBody,
    );
    if (_disposed) return null;

    var largestPassing = smallPassed ? mtuProbeSmallBody : null;
    var fullPassed = false;

    if (smallPassed) {
      final body = probeBodyForMtu(mtu);
      fullPassed = await _uploadThroughTunnel(port: port, bodyBytes: body);
      if (_disposed) return null;
      if (fullPassed) largestPassing = body;
    }

    final check = evaluateMtuCheck(
      declaredMtu: mtu,
      fullPassed: fullPassed,
      smallPassed: smallPassed,
      largestPassingBody: largestPassing,
    );
    _mtuCheck = check;
    hooks.listener.onMtuCheck(check);
    return check;
  }

  /// 把指定大小的请求体经内核混合入站发出去，看它能否完整走完一个来回。
  ///
  /// [HttpClient.findProxy] 指向内核的混合入站，因此这一次请求的路径与用户
  /// 浏览器完全一致：内核按规则判定 → 走隧道出站。这样测到的就是**真实路径**，
  /// 而不是我们另造的一条连接。
  ///
  /// 判定标准是「有没有收到一个完整的 HTTP 响应」，不看状态码：状态码 4xx/5xx
  /// 同样证明请求体完整送达并被处理了；我们测的是链路承载能力，不是那个站点
  /// 的业务逻辑。
  Future<bool> _uploadThroughTunnel({
    required int port,
    required int bodyBytes,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..findProxy = (Uri _) => 'PROXY 127.0.0.1:$port';
    try {
      final request = await client
          .postUrl(Uri.parse(mtuProbeUrl))
          .timeout(const Duration(seconds: 12));
      request.headers.contentType = ContentType.binary;
      request.contentLength = bodyBytes;
      // 用同一个字节重复填充：内容无关紧要，要的是**体积**。
      final chunk = Uint8List(1024);
      var remaining = bodyBytes;
      while (remaining > 0) {
        final take = remaining < chunk.length ? remaining : chunk.length;
        request.add(take == chunk.length ? chunk : chunk.sublist(0, take));
        remaining -= take;
      }
      final response = await request.close().timeout(
        const Duration(seconds: 15),
      );
      // 必须把响应体读干（或丢弃）才算真的收到完整响应。
      await response.drain<void>().timeout(const Duration(seconds: 10));
      return true;
    } on Object {
      // 超时、连接被重置、写入失败——都算「这个体积过不去」。
      return false;
    } finally {
      client.close(force: true);
    }
  }

  /// 直连路径的连通性探测：经系统网络直接访问一个稳定的公开站点。
  ///
  /// 这是「启动自检」里判断「直连这条腿是否正常」的依据。
  Future<int?> probeDirectLatency() async {
    final watch = Stopwatch()..start();
    Socket? socket;
    try {
      socket = await Socket.connect(
        directProbeHost,
        443,
        timeout: const Duration(seconds: 5),
      );
      return watch.elapsedMilliseconds;
    } on Object {
      return null;
    } finally {
      try {
        socket?.destroy();
      } on Object {
        // 忽略。
      }
    }
  }

  /// 经内核 DNS 模块解析域名。
  ///
  /// sing-box 的 Clash API 暴露了 `/dns/query`，它走的是内核自己的 DNS 路由，
  /// 因此返回的正是「隧道内解析器给出的答案」，正好用来与直连解析器交叉校验。
  Future<List<String>> resolveViaCoreDns(String domain) async {
    final body = await _get('/dns/query?name=$domain&type=A');
    if (body == null) return const <String>[];
    try {
      final json = jsonDecode(body) as Map<String, Object?>;
      final answer = json['Answer'];
      if (answer is! List) return const <String>[];
      final addresses = <String>[];
      for (final record in answer) {
        if (record is! Map) continue;
        final data = record['data']?.toString() ?? '';
        // A 记录里 data 就是地址；AAAA 会带冒号，这里一并放行，
        // 因为交叉校验只关心「两组答案是否一致」。
        if (data.isEmpty) continue;
        addresses.add(data);
      }
      return addresses;
    } on Object {
      return const <String>[];
    }
  }

  /// 隧道探测用的目标地址。
  ///
  /// 用 https 而不是 http：不少网络封 80 端口但放行 443，
  /// 用 80 会让正常的节点看起来像挂了。
  static const String tunnelProbeUrl = 'https://www.gstatic.com/generate_204';

  /// 直连探测的目标。选一个稳定的公开站点：它必须秒连，
  /// 连不上说明本地网络或 DNS 有问题，而不是节点问题。
  static const String directProbeHost = 'www.baidu.com';

  // ---------------------------------------------------------------- 启动自检

  /// 跑一次启动自检。
  Future<StartupSelfCheckReport?> runSelfCheck() async {
    if (_disposed) return null;
    _ensureDnsMonitor();
    final check = _selfCheck;
    if (check == null) return null;
    try {
      final report = await check.run();
      hooks.listener.onSelfCheck(report);
      return report;
    } on Object {
      return null;
    }
  }

  /// 延迟探测：把结果上报给界面，并区分抖动与真的挂了。
  ///
  /// 连续失败达到 [unhealthyThreshold] 时做一次**健康判定**：拿直连的结果
  /// 做对照，判断问题在隧道这一侧还是本地网络。两者要区分开——隧道不通
  /// 重启内核有意义，本地网络断了重启只会空转。
  Future<void> probeLatency() async {
    final now = DateTime.now();
    final last = _lastLatencyProbe;
    if (last != null && now.difference(last) < hooks.latencyProbeInterval) {
      return;
    }
    _lastLatencyProbe = now;

    final delay = await _tunnelProbe();
    if (delay != null) {
      hooks.listener.onLatency(delay);
      _latencyFailures = 0;
      // 恢复正常同样要上报：它是自动恢复的「已解除」信号，没有它，
      // 自愈限流器就永远停在上一次事故里。
      _publishHealth(TunnelHealth.healthy(consecutiveFailures: 0));
      return;
    }

    _latencyFailures++;
    hooks.listener.onLatency(null);
    if (_latencyFailures < unhealthyThreshold) return;

    // 先判一次「是不是还在预热」。预热期间不下任何结论，也就**不需要**打那次
    // 直连对照探测——省掉一次无意义的 TCP 连接，也避免把「预热」显示成故障。
    final verdictNow = evaluateTunnelHealth(
      consecutiveFailures: _latencyFailures,
      threshold: unhealthyThreshold,
      now: DateTime.now(),
      sinceConnect: _connectedSince,
    );
    if (verdictNow.isWarmingUp) {
      _publishHealth(verdictNow);
      return;
    }

    // 做对照探测需要真的发一次 TCP 连接。用户明确关掉主动探测时不做，
    // 退回到改造前的行为：只提示，不判定，也不触发自动恢复。
    if (!hooks.probesEnabled) {
      if (_latencyFailures == unhealthyThreshold) {
        hooks.listener.onError('连续 3 次延迟探测失败，节点可能不稳定');
      }
      return;
    }

    final directLatency = await _directProbe();
    _publishHealth(
      evaluateTunnelHealth(
        consecutiveFailures: _latencyFailures,
        threshold: unhealthyThreshold,
        directLatencyMillis: directLatency,
        now: DateTime.now(),
        sinceConnect: _connectedSince,
      ),
    );
  }

  /// 一次采样从内核读到了数据。
  void _onTickSucceeded() {
    _tickFailures = 0;
    // 只在「刚刚还在读不到」的情况下补报健康：正常情况下这里什么都不做，
    // 否则每次成功采样都会把「隧道不通」那个结论冲掉——那是另一路信号的事，
    // 两条信号共用一个结论字段，谁都不该去清对方。
    if (_lastHealthVerdict == TunnelHealthVerdict.coreUnreachable) {
      _publishHealth(TunnelHealth.healthy(consecutiveFailures: 0));
    }
  }

  /// 一次采样没能从内核读到数据。
  ///
  /// 单次读不到很正常（内核正忙），但**连续**读不到是另一回事：Clash API 监听
  /// 在回环地址上，不受外网影响，连续不应答只说明内核进程自己卡住了。此前这种
  /// 情况是完全静默的——界面照旧显示「已连接」，速率和连接数停在几分钟前的
  /// 数字上，用户只会觉得「网速怎么不动了」。
  void _onTickMissed() {
    _tickFailures++;
    if (_tickFailures < hooks.unreachableThreshold) return;
    // 预热宽限期内不下「内核卡住」的结论：刚连上时内核正在加载规则集、建立
    // 握手，几秒读不到状态是正常的。宽限期一过，同样次数的失败才说明它真的卡了。
    if (isWithinWarmupWindow(
      now: DateTime.now(),
      sinceConnect: _connectedSince,
    )) {
      return;
    }
    _publishHealth(
      TunnelHealth(
        verdict: TunnelHealthVerdict.coreUnreachable,
        consecutiveFailures: _tickFailures,
      ),
    );
  }

  /// 只在结论变化时把健康状态上报出去。
  ///
  /// **上报顺序是有意的**：先交给界面显示结论，再交给内核去行动。
  /// 这样能保证「隧道有问题」在任何平台上都至少有一条用户可见的提示——即便
  /// 那个平台没有自愈能力。有能力自愈的实现会紧接着用一条更具体的消息覆盖它
  /// （如「第 1 次自动恢复」）。反过来先行动后显示的话，通用结论会把具体结论
  /// 盖掉，用户就看不到内核已经做了什么。
  void _publishHealth(TunnelHealth health) {
    if (_disposed) return;
    if (_lastHealthVerdict == health.verdict) return;
    _lastHealthVerdict = health.verdict;
    hooks.listener.onTunnelHealth(health);
    hooks.onHealth?.call(health);
  }

  // ---------------------------------------------------------------- HTTP

  /// 读一个 Clash API 接口。
  ///
  /// 注意 `/traffic` 与 websocket 形态的 `/connections` 是**流式**接口，
  /// 不会自己结束；这里只用于普通 GET，`join()` 必须带超时，
  /// 否则一个不返回的响应会把整个轮询卡死（这是踩过的坑）。
  Future<String?> _get(
    String path, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    if (_disposed) return null;
    try {
      final request = await _http
          .getUrl(Uri.parse('http://127.0.0.1:${hooks.clashApiPort}$path'))
          .timeout(timeout);
      final response = await request.close().timeout(timeout);
      if (response.statusCode != 200) return null;
      return await response.transform(utf8.decoder).join().timeout(timeout);
    } on Object {
      return null;
    }
  }

  /// 轮询 Clash API 直到它能应答，或超时。
  ///
  /// [isAlive] 用于提前退出：内核进程已经退出时没必要把超时等满。
  /// [isCancelled] 用于用户取消：取消的优先级高于一切，这里一秒都不该多等——
  /// 否则「取消」在等内核就绪这一步上要等满 12/25 秒才生效。
  Future<bool> waitForApi(
    Duration timeout, {
    bool Function()? isAlive,
    bool Function()? isCancelled,
  }) async {
    final started = DateTime.now();
    final deadline = started.add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (isCancelled != null && isCancelled()) return false;
      if (isAlive != null && !isAlive()) return false;
      if (await _get('/version') != null) return true;
      await Future<void>.delayed(
        readinessPollDelay(DateTime.now().difference(started)),
      );
    }
    return false;
  }

  /// 等内核就绪时的轮询间隔：一开始密，随后逐步放宽。
  ///
  /// 起因是一次实测（本机 4 组，每组单独启动内核）：
  ///
  /// | 内核真实就绪 | 旧实现（固定 300ms）探测到 | 新节奏探测到 |
  /// |---|---|---|
  /// | 527ms | 600ms | 522ms |
  /// | 608ms | 900ms | 535ms |
  /// | 561ms | 600ms | 543ms |
  /// | 520ms | 600ms | 634ms |
  ///
  /// （真实就绪用 5ms 密集探测测得；旧实现那一列按「探测点落在 0/300/600/900ms」
  /// 推算，因为每个样本是独立的进程启动，逐行相减没有意义，看分布即可。）
  ///
  /// 结论：内核就绪在 520–610ms 之间，而旧实现的固定间隔让**每一次连接都白等
  /// 平均约 120ms、最坏约 290ms**——这段时间与内核毫无关系，纯粹是客户端自己
  /// 的定时器。新节奏把探测点铺到 25ms 一个，实测已基本等于真实就绪时刻。
  ///
  /// 一秒之后仍未就绪通常说明启动不顺利，那时密集地问也没有意义，放宽到
  /// 100ms；三秒之后放宽到 300ms，避免在明显失败的情况下空转。
  static Duration readinessPollDelay(Duration elapsed) {
    if (elapsed < const Duration(seconds: 1)) {
      return const Duration(milliseconds: 25);
    }
    if (elapsed < const Duration(seconds: 3)) {
      return const Duration(milliseconds: 100);
    }
    return const Duration(milliseconds: 300);
  }
}
