/// 隧道健康判定与「健康检查触发的重启」限流。
///
/// 与 [CrashRecovery] 的分工：
///   * [CrashRecovery] 处理**内核没了**——进程退出，事件明确；
///   * 这里处理**内核还在、但隧道已经不通**——进程活着、Clash API 也在应答，
///     只有真正经隧道出去的那条路断了。
///
/// 后一种情况更隐蔽：界面上一切正常（有速率、有连接数），用户却打不开任何
/// 走隧道的网站。内核自身的 WireGuard 会话可能卡在一条已经失效的 UDP 映射上，
/// 重启内核是唯一能立刻恢复的手段。
///
/// 但重启必须克制。判断依据里最容易搞错的一点是：**隧道不通不等于该重连**。
/// 本地网络断了、或整个网络都不通时，重连只会反复失败并把日志刷满。因此
/// 判定时要拿直连的结果做对照——只有「直连正常、隧道不通」才值得重启。
library;

/// 隧道健康结论。
enum TunnelHealthVerdict {
  /// 隧道探测正常。
  healthy,

  /// 刚连上，隧道还在建立中——**这不算问题**。
  ///
  /// WireGuard 的首次握手要花几秒（实测同一节点上约 5 秒），这段窗口里经隧道
  /// 的请求会全部超时，而界面若按常规路径判定，就会得出「节点或服务器有问题，
  /// 请更换节点」——**对一次几秒后自愈的预热来说，这是错误的建议**，会把用户
  /// 推去做无意义的换节点操作。
  warmingUp,

  /// 隧道不通，但直连正常：问题出在隧道这一侧，重启内核有意义。
  tunnelDown,

  /// 直连也不通：多半是本地网络或上游断了，重连没有意义。
  networkDown,

  /// 内核自己不应答了。
  ///
  /// 与上面两种都不同：那两种说的是「隧道不通」，这一种是**连看都看不到内核**。
  /// Clash API 监听在回环地址上，不受外网影响，连续读不到只说明内核进程自己
  /// 卡住了。此时界面还显示着「已连接」，速率与连接数却停在几分钟前——这是最
  /// 难看的一种状态：看起来一切正常，实际上什么都没在动。
  ///
  /// 这一条**不需要**拿直连做对照：回环上的失败与本地网络无关，用直连去判断
  /// 只会把结论带偏。
  coreUnreachable,
}

/// 一次健康判定的结果。
class TunnelHealth {
  const TunnelHealth({
    required this.verdict,
    required this.consecutiveFailures,
    this.directLatencyMillis,
  });

  const TunnelHealth.healthy({
    required this.consecutiveFailures,
    this.directLatencyMillis,
  }) : verdict = TunnelHealthVerdict.healthy;

  /// 预热中的结论。**不携带直连对照**：预热期间还没到需要判断「是谁的问题」
  /// 的时候，多打一次直连探测只是白花一次 TCP 连接。
  const TunnelHealth.warmingUp({required this.consecutiveFailures})
    : verdict = TunnelHealthVerdict.warmingUp,
      directLatencyMillis = null;

  final TunnelHealthVerdict verdict;

  /// 连续多少次隧道探测失败。
  final int consecutiveFailures;

  /// 同时测得的直连延迟。为 null 表示直连也失败。
  final int? directLatencyMillis;

  /// 是否是一个**需要用户知道**的问题。
  ///
  /// 预热态**不算**问题：它描述的是「隧道正在建立」，属于正常过程。若把它算作
  /// 问题，界面会在每次刚连上时挂出一条故障提示，而几秒后它自己又消失——正是
  /// 这一轮改动要消掉的那种误导。
  bool get isProblem =>
      verdict != TunnelHealthVerdict.healthy &&
      verdict != TunnelHealthVerdict.warmingUp;

  /// 是否处于「刚连上、还在建立隧道」的宽限期。
  bool get isWarmingUp => verdict == TunnelHealthVerdict.warmingUp;

  /// 是否应当触发自动恢复（重启内核）。
  ///
  /// 「隧道不通」与「内核不应答」都值得重启：前者是隧道这一侧卡住了，
  /// 后者是内核进程本身卡住了，重启都是唯一能立刻恢复的手段。
  /// 预热中**不**重启：那等于对着一个正在握手的隧道反复拆掉重来。
  bool get shouldRecover =>
      verdict == TunnelHealthVerdict.tunnelDown ||
      verdict == TunnelHealthVerdict.coreUnreachable;

  /// 面向用户的一句话结论。
  ///
  /// 只说**诊断**，不说「正在恢复」。是否真的去恢复由内核实现决定——Windows 端
  /// 会重启进程并自己补一句「第 N 次自动恢复」，而安卓端目前不会。此前这里的
  /// 措辞是「正在尝试自动恢复」，于是安卓用户会看到一句**永远不会兑现的承诺**：
  /// 界面说它在试，实际上什么都没发生。
  String get summary => switch (verdict) {
    TunnelHealthVerdict.healthy => '隧道恢复正常',
    TunnelHealthVerdict.warmingUp => '正在建立隧道…',
    TunnelHealthVerdict.tunnelDown =>
      '连续 $consecutiveFailures 次隧道探测失败，但直连正常（${directLatencyMillis}ms），'
          '判断为隧道本身异常',
    TunnelHealthVerdict.networkDown =>
      '连续 $consecutiveFailures 次隧道探测失败，直连同时不通，'
          '判断为本地网络问题，暂不自动重连',
    TunnelHealthVerdict.coreUnreachable =>
      '连续 $consecutiveFailures 次读不到内核状态，判断为内核进程卡住',
  };
}

/// 刚连上之后的预热宽限期。
///
/// 实测依据：同一个可用节点上，内核报「Clash API 就绪」时 WireGuard 握手还在
/// 进行，约 5 秒后才收到 `handshake response`；这段窗口内经隧道的请求全部超时。
/// 因此宽限期要明显长于一次握手，又不能长到把真实的节点故障藏起来。
const Duration tunnelWarmupWindow = Duration(seconds: 12);

/// 这次判定是否还处在「刚连上」的预热宽限期内。
///
/// [sinceConnect] 为 null 表示还没连过，按「不在预热」处理——否则冷启动期间的
/// 健康判定会全部被误吞。
///
/// 起点晚于当前时刻（NTP 校时、时区调整、测试注入）时**按刚开始算**：那种情况
/// 下 elapsed 是负数，若直接拿它去比窗口，宽限期会被静默关掉，预热期的失败又
/// 会被当成节点故障——正是这个判定要避免的事。
bool isWithinWarmupWindow({
  required DateTime now,
  required DateTime? sinceConnect,
  Duration window = tunnelWarmupWindow,
}) {
  if (sinceConnect == null) return false;
  final elapsed = now.difference(sinceConnect);
  return elapsed < window;
}

/// 判定隧道健康。纯函数，便于直接测试三种分支。
///
/// [directLatencyMillis] 为 null 表示直连探测失败。
///
/// [now] 与 [sinceConnect] 一起决定是否仍在预热宽限期内：宽限期内失败**不下
/// 结论**，返回 [TunnelHealthVerdict.warmingUp]。
TunnelHealth evaluateTunnelHealth({
  required int consecutiveFailures,
  required int threshold,
  int? directLatencyMillis,
  DateTime? now,
  DateTime? sinceConnect,
  Duration warmupWindow = tunnelWarmupWindow,
}) {
  if (consecutiveFailures < threshold || consecutiveFailures <= 0) {
    return TunnelHealth.healthy(
      consecutiveFailures: consecutiveFailures,
      directLatencyMillis: directLatencyMillis,
    );
  }
  // 阈值已到，但如果这次连接才刚开始，先当作「还在预热」。
  if (now != null &&
      isWithinWarmupWindow(
        now: now,
        sinceConnect: sinceConnect,
        window: warmupWindow,
      )) {
    return TunnelHealth.warmingUp(consecutiveFailures: consecutiveFailures);
  }
  return TunnelHealth(
    verdict: directLatencyMillis == null
        ? TunnelHealthVerdict.networkDown
        : TunnelHealthVerdict.tunnelDown,
    consecutiveFailures: consecutiveFailures,
    directLatencyMillis: directLatencyMillis,
  );
}

/// 「健康检查触发重启」的限流器。
///
/// 隧道不通时重启内核是有效手段，但如果根因是节点已经下线，重启就成了
/// 无效循环——每次重启都会重新握手、重新建连，用户看到的是延迟数字反复
/// 跳变。因此这里给出两道闸：次数上限与冷却时间。
class HealthRecoveryGuard {
  HealthRecoveryGuard({
    this.maxRestarts = 2,
    this.cooldown = const Duration(minutes: 2),
  });

  /// 一次连接生命周期内，最多因健康问题重启几次。
  final int maxRestarts;

  /// 两次健康重启之间的最小间隔。
  final Duration cooldown;

  int restarts = 0;
  DateTime? lastRestartAt;

  /// 现在是否可以因为健康问题重启内核。
  bool shouldRestart(DateTime now) {
    if (restarts >= maxRestarts) return false;
    final last = lastRestartAt;
    if (last != null && now.difference(last) < cooldown) return false;
    return true;
  }

  /// 记下一次已经执行的重启。
  void noteRestart(DateTime now) {
    restarts++;
    lastRestartAt = now;
  }

  /// 隧道恢复正常：本轮事故结束，重启额度重新可用。
  ///
  /// 刻意**不**清除 [lastRestartAt]：隧道「断了又通、通了又断」时，若把冷却
  /// 时间戳一起清掉，额度就会被反复重置，限流形同虚设。
  void noteHealthy() {
    restarts = 0;
  }

  /// 重新连接（用户手动或内核重启完成）时清零。
  void reset() {
    restarts = 0;
    lastRestartAt = null;
  }

  /// 额度是否已经用尽——用于决定要不要把「无法自愈」告诉用户。
  bool get exhausted => restarts >= maxRestarts;
}
