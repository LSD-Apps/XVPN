/// 内核意外退出后的自愈策略。
///
/// 这一层被单独拆出来，是为了让「要不要重连、等多久、什么时候放弃」这件事
/// 变成**纯逻辑**：它不碰进程、不碰定时器，因此可以直接测。此前这段判断如果
/// 埋在 [SingBoxRunner] 的进程回调里，就只能靠观察真实崩溃来验证——而真实
/// 崩溃是偶发的，等于没测。
///
/// 设计上的三条取舍：
///
///  1. **指数退避而不是固定间隔**。内核起不来通常有两类原因：一类是瞬时
///     （节点抖动、DNS 未就绪），几秒后自己就好；另一类是持续性的（配置
///     错误、被防火墙拦）。固定 1 秒重试对前者有效，对后者只会把日志刷满。
///
///  2. **不加重试抖动（jitter）**。抖动是为了让大量客户端不要同时重试，
///     而这里是单机单内核，抖动只会让等待时间变得不可预测、不可测。
///
///  3. **「刚起来就死」与「跑了一阵才死」区别对待**。启动后立刻退出几乎
///     一定是配置或环境问题，重试再多次也是同样的结果，因此只给很少的
///     次数；而稳定运行过一段时间后崩溃属于新事故，重试额度重新计算。
library;

/// 重试节奏与上限。
class ReconnectPolicy {
  const ReconnectPolicy({
    this.maxAttempts = 5,
    this.maxRapidAttempts = 2,
    this.maxTotalAttempts = 10,
    this.baseDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 30),
    this.stableUptime = const Duration(seconds: 30),
    this.rapidUptime = const Duration(seconds: 10),
  });

  /// 内核稳定运行过之后崩溃，最多重试几次。
  final int maxAttempts;

  /// 内核「刚起来就死」时最多重试几次。
  ///
  /// 远小于 [maxAttempts]：这种情况几乎必然是配置问题，重试解决不了，
  /// 让它快速失败并把原因交给用户，比空转半分钟更有用。
  final int maxRapidAttempts;

  /// **一次连接生命周期内**累计重试次数的硬上限。
  ///
  /// 这一条是必需的，不是保险丝：上面那条「稳定运行过就算新事故」的规则会
  /// 重置单次事故的额度，于是一个「每跑两分钟就崩一次」的内核会被无限重连
  /// 下去——每次崩溃看起来都是独立事故，额度重新计算，用户永远等不到
  /// 「已经尽力了」这个结论。硬上限把这种情况收敛成明确的失败。
  final int maxTotalAttempts;

  /// 第一次重试前的等待时间，后续按 2 的幂增长。
  final Duration baseDelay;

  /// 单次等待的上限。
  final Duration maxDelay;

  /// 运行时间达到这个长度，就认为「这次崩溃是新的独立事故」，
  /// 重试次数重新计算。
  final Duration stableUptime;

  /// 运行时间短于这个长度，视为「刚起来就死」。
  final Duration rapidUptime;

  /// 第 [attempt] 次重试（从 1 开始）前的等待时间。
  ///
  /// 指数退避并封顶：1s、2s、4s、8s、16s…最多 [maxDelay]。
  Duration delayForAttempt(int attempt) {
    if (attempt <= 0) return Duration.zero;
    // 用移位而不是 pow：次数很少，整数运算不会溢出，也不引入浮点误差。
    // 上限先夹住指数，避免 attempt 很大时移位溢出成负数。
    final exponent = (attempt - 1).clamp(0, 30);
    final factor = 1 << exponent;
    final millis = baseDelay.inMilliseconds * factor;
    if (millis <= 0 || millis > maxDelay.inMilliseconds) return maxDelay;
    return Duration(milliseconds: millis);
  }
}

/// 一次内核退出之后的处置结论。
class CrashDecision {
  const CrashDecision._({
    required this.shouldRetry,
    required this.delay,
    required this.attempt,
    required this.reason,
  });

  /// 重试。
  const CrashDecision.retry({required Duration delay, required int attempt})
    : this._(shouldRetry: true, delay: delay, attempt: attempt, reason: '');

  /// 放弃重试，并把原因交给界面。
  const CrashDecision.giveUp(String reason)
    : this._(
        shouldRetry: false,
        delay: Duration.zero,
        attempt: 0,
        reason: reason,
      );

  final bool shouldRetry;

  /// 重试前应等待的时间；不重试时为 [Duration.zero]。
  final Duration delay;

  /// 这是第几次重试（从 1 开始）；不重试时为 0。
  final int attempt;

  /// 放弃重试的原因，面向用户。
  final String reason;
}

/// 崩溃恢复状态机。
///
/// 只做一件事：记录「连续重试了多少次」，并据此回答下一次该怎么办。
class CrashRecovery {
  CrashRecovery({ReconnectPolicy? policy})
    : policy = policy ?? const ReconnectPolicy();

  final ReconnectPolicy policy;

  /// 当前这一轮事故里已经重试过几次。
  int attempts = 0;

  /// 本次连接生命周期内累计重试过几次。只有 [reset] 会清空它。
  int totalAttempts = 0;

  /// 用户主动断开或手动重连时调用，把事故计数清零。
  void reset() {
    attempts = 0;
    totalAttempts = 0;
  }

  /// 内核进程退出时调用。
  ///
  /// [uptime] 是这次内核活了多久——它是区分「配置错」与「偶发崩溃」的唯一
  /// 依据。[userInitiated] 为 true 表示退出是我们自己 kill 的（用户点了断开），
  /// 那时绝不应该重连。
  CrashDecision onCoreExit({
    required Duration uptime,
    required bool userInitiated,
  }) {
    if (userInitiated) {
      attempts = 0;
      return const CrashDecision.giveUp('已按用户操作断开');
    }

    // 硬上限优先于其它判断：无论每次崩溃看起来多像独立事故，累计到上限
    // 就必须停，否则「稳定运行过就重置额度」的规则会变成无限重连。
    if (totalAttempts >= policy.maxTotalAttempts) {
      return CrashDecision.giveUp('本次连接累计自动重连 $totalAttempts 次仍未稳定，停止重连');
    }

    // 稳定运行过一段时间：这算一次新事故，单次额度重新计算。
    // 注意这里不在「启动成功」时清零——内核刚起来就死时也会走到启动成功，
    // 若那时清零就变成了无限重试。
    if (uptime >= policy.stableUptime) attempts = 0;

    final rapid = uptime < policy.rapidUptime;
    final limit = rapid ? policy.maxRapidAttempts : policy.maxAttempts;
    if (attempts >= limit) {
      return CrashDecision.giveUp(
        rapid
            ? '内核启动后立即退出，已连续 $attempts 次，判断为配置或环境问题，不再自动重连'
            : '已连续自动重连 $attempts 次仍未稳定，停止重连',
      );
    }

    attempts++;
    totalAttempts++;
    return CrashDecision.retry(
      delay: policy.delayForAttempt(attempts),
      attempt: attempts,
    );
  }
}
