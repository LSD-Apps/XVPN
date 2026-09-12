import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/core_log.dart';
import 'package:xvpn/core/core_monitor.dart';
import 'package:xvpn/core/mtu_probe.dart';
import 'package:xvpn/core/vpn_core.dart';
import 'package:xvpn/models.dart';

import 'support/recording_listener.dart';

void main() {
  group('MTU 校验的判定（纯函数）', () {
    test('按声明的 MTU 能传过去：结论是配置可用', () {
      final check = evaluateMtuCheck(
        declaredMtu: 1380,
        fullPassed: true,
        smallPassed: true,
        largestPassingBody: 1280,
      );

      expect(check.verdict, MtuVerdict.ok);
      expect(check.isProblem, isFalse);
      expect(check.summary, contains('1380'));
      expect(check.summary, contains('实测通过'));
    });

    test('大包不通但小包能通：判为 MTU 偏大，并给出可执行的下调区间', () {
      final check = evaluateMtuCheck(
        declaredMtu: 1420,
        fullPassed: false,
        smallPassed: true,
        largestPassingBody: mtuProbeSmallBody,
      );

      expect(check.verdict, MtuVerdict.mayBeTooLarge);
      expect(check.isProblem, isTrue, reason: '这是会真实致害的场景，必须让用户看见');
      expect(
        check.summary,
        contains('1280'),
        reason: '只说「偏大」不够，要给一个用户能直接照着改的值',
      );
    });

    test('连小包都不通：不下 MTU 结论，而是隧道不通', () {
      // 这一条是刻意加的分支。没有它，一个纯粹连不上的节点会被报成「MTU 过大」，
      // 把用户引向完全错误的方向。
      final check = evaluateMtuCheck(
        declaredMtu: 1420,
        fullPassed: false,
        smallPassed: false,
      );

      expect(check.verdict, MtuVerdict.inconclusive);
      expect(check.summary, contains('未测到结果'));
      expect(
        check.summary,
        isNot(contains('偏大')),
        reason: '测不到结果时绝不能说 MTU 有问题',
      );
      expect(
        check.isProblem,
        isFalse,
        reason:
            '「没测到结果」不是用户能处理的问题：隧道本身是好的（否则连接建不起来），'
            '标成警告会让界面出现「隧道正常跑流量」与「隧道不通」两行自相矛盾的话',
      );
    });

    test('没有声明 MTU：不校验，也不显示任何结论', () {
      for (final declared in <int?>[null, 0, -1]) {
        final check = evaluateMtuCheck(
          declaredMtu: declared,
          fullPassed: false,
          smallPassed: false,
        );
        expect(check.verdict, MtuVerdict.notDeclared);
        expect(check.summary, isNull, reason: '没声明就没什么可说的，界面据此整块不显示结论');
        expect(check.isProblem, isFalse);
      }
    });

    test('探测负载按 MTU 换算，且必须留有余量又不能留太多', () {
      expect(
        probeBodyForMtu(1380),
        1280,
        reason: '要留出 IP/TCP/TLS/HTTP 头的开销，否则正常配置也会被判成过大',
      );
      // 留太多就测不到边界：配置偏大反而会「通过」。因此余量是个小常数。
      expect(1380 - probeBodyForMtu(1380), lessThan(200));
      // 极端值不能算出非法的体长。
      expect(probeBodyForMtu(50), 1);
      expect(probeBodyForMtu(1), 1);
    });

    test('探测目标的形态不能变：必须走域名、且是明文 HTTP', () {
      // 这两条不是洁癖，各自对应一个实测过的失败：
      //   * 换成写死 IP → 不再命中「未命中规则集→走隧道」的域名规则，测的就不是真实路径；
      //   * 换成 HTTPS  → TLS 记录分层会把结论搅浑（握手自身的分包与 MTU 无关）。
      // 另外，目标域名必须真的能在隧道里解析——最初选的「上传测速」域名就
      // 解析不出来，会让校验永远落在「无法校验」上。
      final uri = Uri.parse(mtuProbeUrl);
      expect(uri.scheme, 'http', reason: 'HTTPS 会把 TLS 分层的变量搅进来');
      expect(int.tryParse(uri.host), isNull, reason: '必须是域名而不是裸 IP，否则不会被判为走隧道');
      expect(
        uri.host.contains('.'),
        isTrue,
        reason: '域名要形如 a.b，写成一个短名会在隧道里解析不出来',
      );
    });
  });

  group('校验流程接在观测引擎上', () {
    /// 没有声明 MTU 或没有端口时，校验直接给出「无从校验」而**不发任何请求**。
    test('配置没声明 MTU：不发网络请求，直接给 notDeclared', () async {
      final listener = RecordingListener();
      var probed = 0;
      final monitor = CoreMonitor(
        CoreMonitorHooks(
          listener: listener,
          clashApiPort: 2081,
          probesEnabled: false,
          declaredMtu: null,
          mixedPort: 2080,
          tunnelLatencyProbe: () async {
            probed++;
            return null;
          },
          directLatencyProbe: () async {
            probed++;
            return null;
          },
        ),
      );
      addTearDown(monitor.dispose);

      final check = await monitor.checkMtu();

      expect(check!.verdict, MtuVerdict.notDeclared);
      expect(probed, 0, reason: '没声明 MTU 还去推包，纯属白白占用隧道');
      expect(monitor.mtuCheck!.verdict, MtuVerdict.notDeclared);
    });

    test('没有混合入站端口（安卓 TUN 模式）：同样不发请求', () async {
      final listener = RecordingListener();
      final monitor = CoreMonitor(
        CoreMonitorHooks(
          listener: listener,
          clashApiPort: 2081,
          probesEnabled: false,
          declaredMtu: 1380,
          // 端口为 null：这正是安卓端的情况——TUN 模式没有本地混合入站。
          mixedPort: null,
        ),
      );
      addTearDown(monitor.dispose);

      final check = await monitor.checkMtu();

      expect(
        check!.verdict,
        MtuVerdict.notDeclared,
        reason: '没有可用的入站端口时应当安静跳过，而不是报一个假的「MTU 有问题」',
      );
      expect(listener.mtuChecks, isEmpty);
    });

    test('两端都不实现这个回调也不会崩：它是可选能力', () {
      // 真实的失败模式是这个：演示内核、安卓桥接这类**继承** VpnCoreListener
      // 的实现不重写 onMtuCheck。把默认实现去掉，它们会直接编译不过——
      // 而新增回调导致两端编译失败，正是这个项目最不想要的扩散方式。
      final listener = _RequiredOnlyListener();
      expect(
        () => listener.onMtuCheck(const MtuCheck.notDeclared()),
        returnsNormally,
      );
    });
  });
}

/// 只实现必需成员的监听器，用来确认可选回调确实有默认实现。
class _RequiredOnlyListener extends VpnCoreListener {
  @override
  void onStatusChanged(VpnStatus status) {}

  @override
  void onTraffic({
    required double downBps,
    required double upBps,
    required int totalBytes,
    int directBytes = 0,
    int proxiedBytes = 0,
    int connectionCount = 0,
    int kernelMemory = 0,
  }) {}

  @override
  void onLatency(int? millis) {}

  @override
  void onSplitRecord(SplitRecord record) {}

  @override
  void onConnectionFailure(ConnectionFailure failure) {}

  @override
  void onError(String message) {}
}
