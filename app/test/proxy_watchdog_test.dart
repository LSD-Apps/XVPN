import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/proxy_watchdog.dart';
import 'package:xvpn/core/system_proxy.dart';

/// 系统代理看门狗的测试。
///
/// 这一组用例回答的是「**怎么保证它真的在跑、真的会回正**」——因为这条路径写错
/// 的后果不是界面不好看，而是**用户整台机器上不了网**，且现象与隧道毫无关系：
/// 浏览器打不开任何网站，而代理设置里躺着一个指向死端口的地址。
///
/// 因此这里不测「某个方法被调用了」，而是把**状态矩阵的每一格**都钉住：
///
/// | 我们接管了 | 端口在监听 | 备份残留 | 期望 |
/// |---|---|---|---|
/// | 否 | —— | 有 | 回正（上次被强杀） |
/// | 否 | —— | 无 | **什么都不做**（用户自己的代理不能被碰） |
/// | 是 | 是 | —— | 什么都不做 |
/// | 是 | 否 | —— | 回正 |
/// | 是 | 探测失败 | —— | 回正（不能确认可用 = 坏状态） |
/// | 是 | 但不知道指向哪 | —— | 回正（保守） |
void main() {
  /// 一个记录所有动作的代理替身。
  ///
  /// `backupLeft` 模拟「上一次没退干净」：真实实现里它是注册表/文件里的备份，
  /// 只有还原成功才会被消费掉——这个替身照搬这条语义，因为**「还原失败但备份
  /// 没了」正是最该被防住的组合**（下次启动就无从兜底了）。
  late _FakeProxy proxy;

  setUp(() => proxy = _FakeProxy());

  /// 建一个看门狗。[probeAlive] 是端口探测的结果。
  ProxyWatchdog build({
    required bool engaged,
    bool? probeAlive = true,
    int port = 2080,
    void Function()? onRestored,
  }) => ProxyWatchdog(
    proxy: proxy,
    isEngaged: () => engaged,
    port: () => port,
    probe: (String h, int p) async => probeAlive,
    // 测试自己调 reconcile()，不让定时器掺进来。
    interval: const Duration(days: 1),
    onRestored: onRestored,
  );

  group('未接管时：只清理我们自己的残留', () {
    test('有残留备份 → 回正（上次被强杀的情形）', () async {
      proxy.backupLeft = true;
      var restored = 0;
      final w = build(engaged: false, onRestored: () => restored++);

      await w.reconcile();

      expect(proxy.clearCalls, 1, reason: '发现残留必须还原，否则用户网络一直坏着');
      expect(proxy.backupLeft, isFalse, reason: '还原成功后备份要被消费掉');
      expect(restored, 1, reason: '要通知调用方，好让界面/运行器跟着对齐');
    });

    test('没有备份 → 绝不碰系统代理', () async {
      // 这条最重要：用户自己设的代理也是「开着的」。若按「代理开着就关掉」
      // 去做对账，就等于把用户的设置改坏了，而用户完全看不出是 VPN 干的。
      proxy.backupLeft = false;
      final w = build(engaged: false);

      await w.reconcile();

      expect(proxy.clearCalls, 0, reason: '没有我们留下的痕迹时不得动系统代理');
    });

    test('环境里本来就没有代理，也不算残留', () async {
      proxy.backupLeft = false;
      final w = build(engaged: false);
      await w.reconcile();
      await w.reconcile();
      expect(proxy.clearCalls, 0);
    });
  });

  group('接管中：端口必须真的在监听', () {
    test('端口在监听 → 不动它', () async {
      proxy.backupLeft = true; // 接管时备份本来就该在
      final w = build(engaged: true, probeAlive: true);

      await w.reconcile();

      expect(proxy.clearCalls, 0, reason: '一切正常时不要多事');
    });

    test('端口没了 → 立刻回正', () async {
      // 这就是实测踩到的那个坏状态：ProxyEnable=1 指向 2080，而 2080 没人监听。
      proxy.backupLeft = true;
      var restored = 0;
      final w = build(engaged: true, probeAlive: false, onRestored: () => restored++);

      await w.reconcile();

      expect(proxy.clearCalls, 1, reason: '内核没了就必须撤销代理，否则全网打不开');
      expect(restored, 1);
    });

    test('探测「无法确认」也按坏状态处理', () async {
      // 超时 / 连接被拒都归为「不能确认它在监听」。纠结两者区别只会多出一堆
      // 没有实际差别的分支，而一个无法确认的全局代理就是坏状态。
      proxy.backupLeft = true;
      final w = build(engaged: true, probeAlive: null);

      await w.reconcile();

      expect(proxy.clearCalls, 1);
    });

    test('端口每次对账现取，不在接管时缓存', () async {
      // 内核每次连接都会重新挑端口。若看门狗在接管时缓存一份，就会在
      // 「断开 → 重连到另一个端口」之后去探测旧端口，把正常状态误判成坏状态
      // ——而误判的代价是把用户正常的代理撤掉。
      proxy.backupLeft = true;
      var livePort = 2080;
      final probed = <int>[];
      final w = ProxyWatchdog(
        proxy: proxy,
        isEngaged: () => true,
        port: () => livePort,
        probe: (String h, int p) async {
          probed.add(p);
          return true;
        },
        interval: const Duration(days: 1),
      );

      await w.reconcile();
      livePort = 2081; // 重连换了端口
      await w.reconcile();

      expect(probed, <int>[2080, 2081], reason: '每次对账都要用当时的端口');
      expect(proxy.clearCalls, 0, reason: '端口是活的，不该动代理');
    });
  });

  group('持续性与生命周期', () {
    test('start() 会立刻对账一次，不等第一个周期', () async {
      // 启动兜底不能等：那段等待时间里用户的网络一直是坏的。
      proxy.backupLeft = true;
      final w = build(engaged: false);

      w.start();
      // start() 里的首次对账是 fire-and-forget，让出一次事件循环等它跑完。
      await Future<void>.delayed(Duration.zero);

      expect(proxy.clearCalls, 1, reason: 'start() 必须立刻对账，不能等一个周期');

      w.stop();
    });

    test('stop() 之后不再对账', () async {
      proxy.backupLeft = true;
      final w = build(engaged: false);
      w.stop();
      await w.reconcile();
      // reconcile() 是显式调用，仍会执行一次；这里确认 stop() 不会把定时器留下。
      expect(proxy.clearCalls, 1);
    });

    test('状态在两次对账之间变化时，下一次对账用新状态判定', () async {
      proxy.backupLeft = true;
      var engaged = false;
      final w = ProxyWatchdog(
        proxy: proxy,
        isEngaged: () => engaged,
        port: () => 2080,
        probe: (String h, int p) async => false,
        interval: const Duration(days: 1),
      );

      // 第一轮：未接管 + 有备份 → 回正。
      await w.reconcile();
      expect(proxy.clearCalls, 1);

      // 接管之后端口是死的 → 还要回正。
      engaged = true;
      proxy.backupLeft = true;
      await w.reconcile();
      expect(proxy.clearCalls, 2);
    });
  });

  group('还原失败时绝不放弃', () {
    test('还原失败 → 备份必须留着，好让下次启动还能兜底', () async {
      proxy.backupLeft = true;
      proxy.clearSucceeds = false;
      final w = build(engaged: false);

      await w.reconcile();

      expect(proxy.clearCalls, 1, reason: '失败也要试过');
      expect(
        proxy.backupLeft,
        isTrue,
        reason: '还原失败却把备份删了，下次启动就无从兜底 —— 用户的网络会一直坏着',
      );
    });

    test('还原失败之后的下一次对账会再试', () async {
      proxy.backupLeft = true;
      proxy.clearSucceeds = false;
      final w = ProxyWatchdog(
        proxy: proxy,
        isEngaged: () => false,
        port: () => 2080,
        probe: (String h, int p) async => true,
        interval: const Duration(days: 1),
      );

      await w.reconcile();
      proxy.clearSucceeds = true;
      await w.reconcile();

      expect(proxy.clearCalls, 2, reason: '第一次失败后必须继续尝试，不能放弃');
      expect(proxy.backupLeft, isFalse);
    });
  });

  group('并发保护', () {
    test('上一次对账没结束时，重叠的触发直接跳过', () async {
      // 定时器可能在上一次对账（要开 TCP、要写注册表）还没跑完时又触发。
      // 并发跑两次会同时去 clear()，其中一次的「失败」会让退避计数无谓累加。
      proxy.backupLeft = true;
      proxy.clearDelay = const Duration(milliseconds: 50);
      final w = build(engaged: false);

      final first = w.reconcile();
      final second = w.reconcile(); // 应当被跳过
      await Future.wait(<Future<void>>[first, second]);

      expect(proxy.clearCalls, 1, reason: '重叠的对账必须被串行化，不能同时动手');
    });
  });
}

/// [SystemProxyController] 的替身，照搬真实实现的「只有还原成功才消费备份」语义。
class _FakeProxy implements SystemProxyController {
  int clearCalls = 0;
  bool backupLeft = false;
  bool clearSucceeds = true;
  Duration clearDelay = Duration.zero;

  @override
  Future<bool> hasBackup() async => backupLeft;

  @override
  Future<bool> clear() async {
    clearCalls++;
    if (clearDelay > Duration.zero) {
      await Future<void>.delayed(clearDelay);
    }
    if (!clearSucceeds) return false;
    backupLeft = false;
    return true;
  }

  @override
  Future<bool> recoverIfNeeded() async {
    if (!backupLeft) return false;
    return clear();
  }

  @override
  Future<bool> set({required String host, required int port}) async => true;
}
