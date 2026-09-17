import 'dart:async';
import 'dart:io';

import 'system_proxy.dart';

/// 系统代理的**完整性看门狗**。
///
/// ## 为什么需要它
///
/// 接管系统代理是「动用户的全局网络设置」。一旦接管之后没能还原，用户机器上
/// **所有**走系统代理的程序（浏览器、绝大多数桌面软件）都会连不上，而现象与
/// 隧道毫无关系——没人会想到去代理设置里找原因。实测踩过一次：调试时强杀进程，
/// `ProxyEnable=1` + `127.0.0.1:2080` 被留了下来，内核已经不在，2080 没人监听，
/// 整台机器网络异常，但注册表里看不出任何线索。
///
/// 原有的两道防线各自覆盖了一部分，但都不完整：
///
///   * 内核进程退出时撤销代理（`singbox_runner` 监听 `process.exitCode`）——
///     内核**自己**死掉能覆盖；但代理设好而内核迟迟没起来、或内核被外部杀掉
///     而回调没来得及跑，就漏了。
///   * 启动时 `recoverIfNeeded()` 兜底——只在**下一次启动**才生效。被强杀之后
///     到下次启动之间，用户的网络一直是坏的。
///
/// 这个看门狗补的是「**运行期**的持续对账」：只要发现「代理处于接管状态，但它
/// 指向的端口没人监听」，就立刻把网络回正。它不依赖内核回调是否可靠，也不依赖
/// 用户下次启动。
///
/// ## 判定规则（这条规则是整个类的核心）
///
/// 每次对账只看两个事实，二者必须一致：
///
/// | 事实 A：我们是否接管了代理 | 事实 B：本地入站端口是否在监听 | 结论 |
/// |---|---|---|
/// | 否 | —— | 若有残留备份 → 回正（上次被强杀） |
/// | 是 | 在监听 | 正常 |
/// | 是 | **不在监听** | **回正**（内核死了 / 从没起来） |
///
/// 「是 + 不在监听」这一格就是实测踩到的那个坏状态。它在**接管前也要查**：
/// 端口没起来就不该接管，否则会主动制造出一个坏状态。
///
/// ## 为什么端口是「每次现取」而不是「接管时缓存」
///
/// 内核每次连接都会重新挑端口（基准端口被占用时往后找）。缓存一份极容易在
/// 「断开 → 重连到另一个端口」之后去探测一个已经没有意义的旧端口，把正常状态
/// 误判成坏状态——而误判的代价是把用户正常的代理撤掉。因此端口由内核运行器
/// 持有唯一的那份，看门狗每次对账现取。
///
/// ## 为什么要「持续」而不是「一次性」
///
/// 下面这些时刻都可能把状态弄坏，而它们分散在整个生命周期里：启动时可能带着
/// 上次的残留、连接时可能核心起来失败、运行中核心可能被杀、自愈重连期间可能
/// 出现「旧代理还在、新内核未就绪」的窗口。因此对账是**周期性**的，而不是
/// 只在某几个点上断言一次。
///
/// ## 为什么周期要短
///
/// 用户感知的是「网页打不开」，不是「几秒后恢复」。间隔越长，坏状态的暴露时间
/// 越长。但也不能太短——每次对账要开一个 TCP 连接。5 秒是这两者之间的折中：
/// 最坏情况下用户看到约 5 秒的断网，而不是一个永久坏掉的代理。
class ProxyWatchdog {
  // 这里逐条忽略 `prefer_initializing_formals`：那些字段是**私有**的，而
  // 「私有字段直接当作具名初始化形参」（`required this._proxy`）在本仓库的语言
  // 版本下不被接受。lint 的建议在这里无法采纳，不是懒得改。
  // ignore_for_file: prefer_initializing_formals
  ProxyWatchdog({
    required SystemProxyController proxy,
    required bool Function() isEngaged,
    required int Function() port,
    String host = '127.0.0.1',
    ProbePort? probe,
    Duration interval = const Duration(seconds: 5),
    void Function()? onRestored,
  })  : _proxy = proxy,
        _isEngaged = isEngaged,
        _port = port,
        _host = host,
        _probe = probe ?? tcpProbePort,
        _interval = interval,
        _onRestored = onRestored;

  final SystemProxyController _proxy;

  /// 当前是否处于「我们接管了系统代理」的状态。
  ///
  /// 由内核运行器提供（它才知道代理是不是自己设的）。做成回调而不是让看门狗
  /// 自己维护一份，是为了**只有一个事实来源**——两份状态迟早不一致，而这里
  /// 不一致的后果正是「以为没接管，于是不去还原」。
  final bool Function() _isEngaged;

  /// 当前入站端口。
  ///
  /// 同样做成回调、**每次对账现取**，而不是在接管时缓存一份：内核每次连接都会
  /// 重新挑端口（基准端口被占用时会往后找），缓存一份极容易在「断开 → 重连到
  /// 另一个端口」之后去探测一个已经没有意义的旧端口，从而误判成坏状态。
  /// 让运行器始终持有唯一的那份端口，这里只读。
  final int Function() _port;

  final String _host;
  final ProbePort _probe;
  final Duration _interval;

  /// 看门狗**代替内核运行器**把网络回正了。
  ///
  /// 运行器必须据此把自己那份「代理由我管着」的旗标也清掉，否则它会以为代理
  /// 还由自己管着，下次断开时会去还原一个已经还原过的代理（虽然无害，但会让
  /// 「谁负责还原」这件事变得含糊）。UI 也应借此提示用户网络已回正。
  final void Function()? _onRestored;

  Timer? _timer;
  bool _running = false;
  bool _busy = false;

  /// 已经连续回正失败多少次。用来在持续失败时退避，避免每 5 秒无脑重试。
  int _restoreFailures = 0;

  /// 开始看门狗。会**立刻**做一次对账，然后按 [interval] 周期进行。
  ///
  /// 「立刻」很关键：启动兜底不能等第一个周期——那段等待时间里用户的网络一直
  /// 是坏的。
  void start() {
    if (_running) return;
    _running = true;
    unawaited(reconcile());
    _timer = Timer.periodic(_interval, (_) => unawaited(reconcile()));
  }

  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
  }

  /// 做一次对账。测试直接调它；生产由 [start] 里的定时器驱动。
  ///
  /// 用 [_busy] 串行化：一次对账可能要开 TCP 连接、写注册表，都是异步的，
  /// 定时器却可能在上一次还没结束时又触发一次。并发跑两次对账会同时去
  /// `clear()`，其中一次的「失败」会让 [_restoreFailures] 无谓地累加。
  Future<void> reconcile() async {
    if (_busy) {
      return;
    }
    _busy = true;
    try {
      final engaged = _isEngaged();
      if (engaged) {
        await _checkEngaged();
      } else {
        // 没接管，却还留着备份 —— 上次异常退出的残留。
        //
        // **只信备份，不去猜代理当前的值**：备份是「我们曾经改过」的唯一证据。
        // 直接读 ProxyEnable 会把用户自己设的代理误判成我们的残留，然后删掉。
        final hasBackup = await _proxy.hasBackup();
        if (hasBackup) {
          await _restore();
        }
      }
    } on Object {
      // 对账本身绝不抛：它是后台巡检，抛出去会变成一个没人接的异步错误，
      // 而真正该做的是等下一个周期重试。
    } finally {
      _busy = false;
    }
  }

  /// 接管状态下的对账：端口必须在监听。
  Future<void> _checkEngaged() async {
    final port = _port();
    final alive = await _probe(_host, port);
    if (alive == true) {
      _restoreFailures = 0;
      return;
    }
    // `null` 与 `false` 同等处理：探测失败（超时、连接被拒、本机网络栈异常）
    // 都意味着「不能确认它在监听」，而一个无法确认的全局代理就是坏状态。
    await _restore();
  }

  /// 把网络回正。持续失败时退避，但**永不放弃**——放弃就等于把用户的网络
  /// 永久留在坏状态里。
  Future<void> _restore() async {
    if (_restoreFailures > 0) {
      // 退避：连续失败越多，等得越久，避免每 5 秒无脑重试。上限 30 秒——
      // 再长就等于「放弃」，而这条路不能放弃。
      final seconds = 5 * (1 << (_restoreFailures - 1).clamp(0, 3));
      await Future<void>.delayed(Duration(seconds: seconds));
    }
    final ok = await _proxy.clear();
    if (!ok) {
      // 还原失败：用户的网络仍然是坏的。计数后等下一个周期再试，
      // **绝不清掉「我们曾经接管过」的痕迹**（备份），否则下次启动就无从兜底。
      _restoreFailures++;
      return;
    }
    _restoreFailures = 0;
    _onRestored?.call();
  }
}

/// 探测某个本地端口是否在监听。返回 `null` 表示**无法确认**。
///
/// 用 `Socket.connect` 而不是看进程列表：内核可能换了 PID、可能被别的程序
/// 顶替，而「代理要指向的那个端口上有没有人」才是真正决定网络通不通的事实。
typedef ProbePort = Future<bool?> Function(String host, int port);

/// 真实实现：尝试建立一条到本地端口的连接。
///
/// 成功即视为在监听。失败（超时 / 拒绝 / 任何异常）返回 `null`——
/// **不区分「拒绝」与「超时」**：对看门狗来说两者都是「不能确认可用」，
/// 而区分它们只会多出一堆没有实际差别的分支。
Future<bool?> tcpProbePort(String host, int port) async {
  Socket? socket;
  try {
    socket = await Socket.connect(
      host,
      port,
      // 本地回环连接要么立刻成功，要么立刻被拒；只在极端情况下才会等到超时。
      timeout: const Duration(seconds: 2),
    );
    return true;
  } on Object {
    return null;
  } finally {
    try {
      socket?.destroy();
    } on Object {
      // 忽略：连接已经建立过，销毁失败不影响判定。
    }
  }
}
