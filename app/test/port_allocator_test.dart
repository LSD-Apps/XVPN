import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/core_monitor.dart';
import 'package:xvpn/core/port_allocator.dart';
import 'package:xvpn/core/singbox_config.dart';
import 'package:xvpn/models.dart';
import 'package:xvpn/protocols/wireguard_conf.dart';

import 'support/recording_listener.dart';

const _conf = '''
[Interface]
PrivateKey = k
Address = 10.0.0.3/32

[Peer]
PublicKey = p
Endpoint = 1.2.3.4:51820
''';

void main() {
  /// 先借一个确实空闲的端口当基准，避免测试写死 2080 而在开发机上偶然失败。
  Future<int> freePortNear(int from) async {
    final ports = await PortAllocator.allocate(from: from, count: 1);
    expect(ports, hasLength(1), reason: '测试基准端口都找不到，环境不正常');
    return ports.single;
  }

  group('端口探测', () {
    test('空闲端口原样返回，不无谓地换端口', () async {
      final base = await freePortNear(2080);
      final ports = await PortAllocator.allocate(from: base, count: 1);
      expect(ports, <int>[base]);
    });

    test('被占用的端口会被跳过', () async {
      final base = await freePortNear(2080);
      final blocker = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        base,
      );
      addTearDown(blocker.close);

      final ports = await PortAllocator.allocate(from: base, count: 1);

      expect(ports, hasLength(1));
      expect(
        ports.single,
        greaterThan(base),
        reason: '端口的默认值被占着时，内核原本会直接启动失败且报错看不懂',
      );
    });

    test('一次要两个端口时不会给出同一个', () async {
      final base = await freePortNear(2080);
      final ports = await PortAllocator.allocate(from: base, count: 2);
      expect(ports, hasLength(2));
      expect(ports[0], isNot(ports[1]), reason: '入站与 Clash API 抢同一个端口必然有一个绑不上');
    });

    test('搜索范围内凑不齐时返回能凑到的部分，由调用方决定怎么办', () async {
      final base = await freePortNear(2080);
      final blocker = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        base,
      );
      addTearDown(blocker.close);

      // 只允许往后看一个端口：第一个被占，就没有第二个可选了。
      final ports = await PortAllocator.allocate(
        from: base,
        count: 2,
        searchLimit: 1,
      );
      expect(ports, isEmpty);
    });

    test('要 0 个端口时直接返回空', () async {
      expect(await PortAllocator.allocate(from: 2080, count: 0), isEmpty);
    });

    test('越界端口按不可用处理，不抛异常', () async {
      expect(await PortAllocator.isAvailable(0), isFalse);
      expect(await PortAllocator.isAvailable(70000), isFalse);
    });
  });

  group('端口写进内核配置', () {
    test('入站与 Clash API 用传入的端口而不是默认值', () {
      final config = SingBoxConfigBuilder.build(
        profile: WireGuardProfile(WireGuardConf.parse(_conf)),
        splitMode: SplitMode.smart,
        ruleSetDir: '/tmp/rs',
        mixedPort: 12080,
        clashApiPort: 12081,
      );

      final inbound =
          (config['inbounds']! as List<Object?>).single!
              as Map<Object?, Object?>;
      expect(inbound['listen_port'], 12080);

      final experimental = config['experimental']! as Map<String, Object?>;
      final api = experimental['clash_api']! as Map<String, Object?>;
      expect(api['external_controller'], '127.0.0.1:12081');
    });
  });

  group('观测引擎跟随动态端口', () {
    test('端口被改掉之后，观测引擎问的是新端口', () async {
      // 这一条守的是一个很容易犯的错：hooks 在构造期就交给了观测引擎，
      // 如果引擎把端口缓存成 final，那么内核换了端口之后它会一直去问一个
      // 没人听的端口——表现是「连上了，但速率、连接数、分流记录全是空的」。
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);
      server.listen((HttpRequest request) {
        request.response
          ..statusCode = 200
          ..write(jsonEncode(<String, Object?>{'version': '1.14.0'}));
        request.response.close();
      });

      final listener = RecordingListener();
      final hooks = CoreMonitorHooks(
        listener: listener,
        // 一开始指向一个空端口：此时探测必然失败。
        clashApiPort: 1,
        probesEnabled: false,
      );
      final monitor = CoreMonitor(hooks);
      addTearDown(monitor.dispose);

      expect(
        await monitor.waitForApi(const Duration(milliseconds: 400)),
        isFalse,
        reason: '端口还没改的时候不该探测成功',
      );

      // 内核换端口之后同步过来。
      hooks.clashApiPort = server.port;

      expect(
        await monitor.waitForApi(const Duration(seconds: 2)),
        isTrue,
        reason: '引擎必须读最新端口，否则界面上的观测数据会全部为空',
      );
    });
  });
}
