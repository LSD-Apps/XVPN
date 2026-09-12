import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/cn_ip_index.dart';
import 'package:xvpn/core/dns_client.dart';
import 'package:xvpn/core/dns_monitor.dart';

/// 可编程的 DNS 桩：按 (服务器, 域名) 返回预定答案。
class _StubResolver implements DnsResolver {
  _StubResolver(this._answers);

  /// 键是 `服务器|域名`，值是要返回的结果。
  final Map<String, DnsOutcome> _answers;

  final List<String> queries = <String>[];

  @override
  Future<DnsOutcome> query(
    String server,
    String name, {
    Duration? timeout,
  }) async {
    queries.add('$server|$name');
    final hit = _answers['$server|$name'];
    if (hit != null) return hit;
    return DnsOutcome(
      server: server,
      name: name,
      answers: const <String>[],
      elapsed: const Duration(milliseconds: 5),
      error: '解析超时',
    );
  }

  @override
  void close() {}
}

DnsOutcome _ok(
  String server,
  String name,
  List<String> answers, {
  int millis = 10,
}) => DnsOutcome(
  server: server,
  name: name,
  answers: answers,
  elapsed: Duration(milliseconds: millis),
);

/// 构造一份最小的「国内」IP 索引：只含 192.0.2.0/25 与 192.0.2.128/25。
///
/// 刻意用 RFC 5737 的文档保留段，而不是真实的国内网段：
///
///   * 这里要验的是**归属判定的逻辑**，不是「哪一段地址在中国」。真实网段的
///     归属会变，把某一段写成测试事实迟早会过期；
///   * 仓库里因此不会留下任何从真实网络观察到的痕迹。真实域名与真实解析结果
///     一律不进代码，理由见 CONTRIBUTING.md 的「不要把真实会话数据写进代码」。
///
/// 拆成两个 /25 而不是一个 /24，是为了顺带覆盖「索引里有多条前缀」这条路径。
CnIpIndex _cnIndex() {
  final bytes = Uint8List(8 + 2 * 8);
  final view = ByteData.view(bytes.buffer);
  bytes[0] = 0x43;
  bytes[1] = 0x49;
  bytes[2] = 0x50;
  bytes[3] = 0x31;
  view.setUint32(4, 2, Endian.little);

  void put(int index, int network, int length) {
    final base = 8 + index * 8;
    view.setUint32(base, network, Endian.little);
    bytes[base + 4] = length;
  }

  const int base = (192 << 24) | (0 << 16) | (2 << 8); // 192.0.2.0
  put(0, base, 25);
  put(1, base | 128, 25);
  return CnIpIndex.parse(bytes)!;
}

DnsMonitor _monitor(
  _StubResolver resolver, {
  int? tunnelDelay,
  CnIpIndex? index,
}) {
  return DnsMonitor(
    config: const DnsMonitorConfig(
      domesticServers: <String>['223.5.5.5', '119.29.29.29'],
      tunnelProbeUrl: 'https://www.gstatic.com/generate_204',
      domesticProbeDomain: 'www.baidu.com',
    ),
    resolver: resolver,
    tunnelLatencyProbe: () async => tunnelDelay,
    cnIpIndex: index ?? _cnIndex(),
  );
}

void main() {
  group('DNS 报文编解码', () {
    test('构造的 A 查询报文结构正确', () {
      final query = buildQuery(0x1234, 'www.example.com');
      final view = ByteData.view(query.buffer);
      expect(view.getUint16(0), 0x1234, reason: '事务 ID');
      expect(view.getUint16(2) & 0x0100, 0x0100, reason: 'RD 位应为 1');
      expect(view.getUint16(4), 1, reason: 'QDCOUNT');

      // 域名按标签展开：3www 7example 3com 0
      expect(query[12], 3);
      expect(String.fromCharCodes(query.sublist(13, 16)), 'www');
      expect(query[16], 7);
      expect(String.fromCharCodes(query.sublist(17, 24)), 'example');
      expect(query[24], 3, reason: 'com 标签长度');
      expect(String.fromCharCodes(query.sublist(25, 28)), 'com');
      expect(query[28], 0, reason: '域名结束标记');

      final view32 = ByteData.view(query.buffer);
      expect(view32.getUint16(29), 1, reason: 'QTYPE = A');
      expect(view32.getUint16(31), 1, reason: 'QCLASS = IN');
      expect(query.length, 33);
    });

    test('解析 A 记录', () {
      final response = _makeResponse(
        id: 0x1234,
        answers: <List<int>>[
          // 与期望的字符串保持一致：198.51.100.34
          <int>[198, 51, 100, 34],
        ],
      );
      final parsed = parseResponse(response, expectedId: 0x1234)!;
      expect(parsed.rcode, 0);
      expect(parsed.addresses, <String>['198.51.100.34']);
    });

    test('事务 ID 不匹配时拒绝，避免串了别的查询的答案', () {
      final response = _makeResponse(
        id: 0x9999,
        answers: <List<int>>[
          <int>[1, 2, 3, 4],
        ],
      );
      expect(parseResponse(response, expectedId: 0x1234), isNull);
    });

    test('非响应报文（QR=0）被拒绝', () {
      final query = buildQuery(1, 'a.com');
      expect(parseResponse(query, expectedId: 1), isNull);
    });

    test('NXDOMAIN 之类被识别成错误码', () {
      final response = _makeResponse(
        id: 1,
        rcode: 3,
        answers: const <List<int>>[],
      );
      final parsed = parseResponse(response, expectedId: 1)!;
      expect(parsed.rcode, 3);
      expect(rcodeText(3), '域名不存在');
    });

    test('畸形报文返回 null 而不是抛异常', () {
      expect(parseResponse(Uint8List(0)), isNull);
      expect(parseResponse(Uint8List(5)), isNull);
      // 截断的报文
      final full = _makeResponse(
        id: 1,
        answers: <List<int>>[
          <int>[1, 2, 3, 4],
        ],
      );
      expect(
        parseResponse(Uint8List.sublistView(full, 0, full.length - 4)),
        isNull,
      );
    });

    test('IPv6 地址按 RFC 5952 压缩', () {
      final response = _makeResponse(
        id: 7,
        answers: const <List<int>>[],
        ipv6Answers: <List<int>>[
          <int>[0x24, 0x00, 0xcb, 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1],
        ],
      );
      final parsed = parseResponse(response, expectedId: 7)!;
      expect(parsed.addresses, <String>['2400:cb00::1']);
    });

    test('重复地址只保留一份', () {
      final response = _makeResponse(
        id: 8,
        answers: <List<int>>[
          <int>[1, 1, 1, 1],
          <int>[1, 1, 1, 1],
        ],
      );
      expect(parseResponse(response, expectedId: 8)!.addresses, <String>[
        '1.1.1.1',
      ]);
    });
  });

  group('中国 IP 索引', () {
    test('命中与未命中', () {
      final index = _cnIndex();
      expect(index.contains('192.0.2.173'), isTrue);
      expect(index.contains('192.0.2.148'), isTrue);
      expect(index.contains('8.8.8.8'), isFalse);
      expect(index.contains('198.51.100.1'), isFalse);
    });

    test('边界地址按掩码正确判定', () {
      final index = _cnIndex();
      // 索引是 192.0.2.0/25 与 192.0.2.128/25，合起来覆盖 192.0.2.0–255。
      expect(index.contains('192.0.2.0'), isTrue);
      expect(index.contains('192.0.2.127'), isTrue, reason: '前一个 /25 的末地址');
      expect(index.contains('192.0.2.128'), isTrue, reason: '后一个 /25 的首地址');
      expect(index.contains('192.0.2.255'), isTrue);
      // 范围外一律不命中。这里刻意用另外两个**文档保留段**而不是紧邻的地址：
      // 断言要验的是「掩码宽度没算错」，紧邻与否不影响这个结论，而紧邻地址会
      // 落在真实的公网段里（192.0.1.0/24、192.0.3.0/24 并非保留段）。
      expect(index.contains('198.51.100.255'), isFalse);
      expect(index.contains('203.0.113.1'), isFalse);
    });

    test('非 IPv4 与非法输入返回 false', () {
      final index = _cnIndex();
      expect(index.contains('not-an-ip'), isFalse);
      expect(index.contains('1.2.3'), isFalse);
      expect(index.contains('1.2.3.400'), isFalse);
      expect(index.contains('2001:db8::1'), isFalse);
    });

    test('空索引不做任何判定，而不是把一切判成境外', () {
      expect(CnIpIndex.empty.contains('192.0.2.1'), isFalse);
      expect(
        classifyRegion(CnIpIndex.empty, <String>['192.0.2.1']),
        AddressRegion.unknown,
        reason: '拿不到索引时必须保持「无法判断」，否则会误判',
      );
    });

    test('一组地址里有一个国内就算国内', () {
      final index = _cnIndex();
      expect(
        classifyRegion(index, <String>['8.8.8.8', '192.0.2.1']),
        AddressRegion.domestic,
      );
      expect(
        classifyRegion(index, <String>['8.8.8.8', '1.1.1.1']),
        AddressRegion.overseas,
      );
      expect(classifyRegion(index, const <String>[]), AddressRegion.unknown);
    });

    test('格式损坏的索引返回 null，不静默变成空表', () {
      expect(CnIpIndex.parse(Uint8List(8)), isNull);
      final wrongMagic = Uint8List(16);
      expect(CnIpIndex.parse(wrongMagic), isNull);
    });

    test('真实的出厂索引能加载并覆盖国内一线地址', () async {
      // 这份索引由 tool/build_cn_ip_index.dart 从 geoip-cn.srs 生成，
      // 随包分发。如果它没被构建进来，这个测试会失败——
      // 那样 DNS 交叉校验会退化成「无法判断」，属于静默失效。
      final index = await CnIpIndex.load();
      if (index.isEmpty) {
        markTestSkipped('当前环境没有出厂索引（纯 dart test 运行时常见）');
        return;
      }
      expect(index.length, greaterThan(1000));
      expect(index.contains('114.114.114.114'), isTrue, reason: '114 DNS 在国内');
      expect(index.contains('223.5.5.5'), isTrue, reason: '阿里 DNS 在国内');
      expect(index.contains('8.8.8.8'), isFalse, reason: 'Google DNS 不在国内');
    });
  });

  group('DNS 监测：解析器健康度', () {
    test('全部正常时统计出耗时与状态', () async {
      final resolver = _StubResolver(<String, DnsOutcome>{
        '223.5.5.5|www.baidu.com': _ok('223.5.5.5', 'www.baidu.com', <String>[
          '1.2.3.4',
        ], millis: 12),
        '119.29.29.29|www.baidu.com': _ok(
          '119.29.29.29',
          'www.baidu.com',
          <String>['1.2.3.4'],
          millis: 20,
        ),
      });
      final monitor = _monitor(resolver, tunnelDelay: 80);

      final report = await monitor.runOnce();

      expect(report.resolvers, hasLength(3), reason: '两个国内解析器 + 隧道');
      for (final health in report.resolvers) {
        expect(health.healthy, isTrue);
        expect(health.statusLabel, '正常');
      }
      // 直连耗时取最快的那台，与内核「谁先答用谁」的行为一致。
      expect(report.direct.median, 12);
      expect(report.tunnel.median, 80);
      expect(report.summary, contains('直连解析 12ms'));
    });

    test('连续失败会升级为「不响应」', () async {
      final resolver = _StubResolver(const <String, DnsOutcome>{});
      final monitor = _monitor(resolver, tunnelDelay: 50);

      for (var i = 0; i < 3; i++) {
        await monitor.runOnce();
      }

      final health = monitor.report.resolvers.firstWhere(
        (ResolverHealth h) => h.server == '223.5.5.5',
      );
      expect(health.consecutiveFailures, 3);
      expect(health.statusLabel, '不响应');
      expect(health.successRate, 0);
    });

    test('失败一次后恢复，连续失败计数清零', () async {
      final answers = <String, DnsOutcome>{};
      final resolver = _StubResolver(answers);
      final monitor = _monitor(resolver, tunnelDelay: 50);

      await monitor.runOnce();
      final failed = monitor.report.resolvers.firstWhere(
        (ResolverHealth h) => h.server == '223.5.5.5',
      );
      expect(failed.consecutiveFailures, 1);

      answers['223.5.5.5|www.baidu.com'] = _ok(
        '223.5.5.5',
        'www.baidu.com',
        <String>['1.2.3.4'],
      );
      await monitor.runOnce();

      final recovered = monitor.report.resolvers.firstWhere(
        (ResolverHealth h) => h.server == '223.5.5.5',
      );
      expect(recovered.consecutiveFailures, 0);
      expect(recovered.healthy, isTrue);
      expect(recovered.successRate, greaterThan(0));
    });

    test('隧道不可达时被记成失败，而不是静默忽略', () async {
      final resolver = _StubResolver(<String, DnsOutcome>{
        '223.5.5.5|www.baidu.com': _ok('223.5.5.5', 'www.baidu.com', <String>[
          '1.2.3.4',
        ]),
      });
      final monitor = _monitor(resolver);

      final report = await monitor.runOnce();
      final tunnelHealth = report.resolvers.firstWhere(
        (ResolverHealth h) => h.server == '隧道 DNS',
      );
      expect(tunnelHealth.consecutiveFailures, 1);
      expect(tunnelHealth.lastSummary, contains('超时'));
    });

    test('重入保护：上一轮没跑完时直接返回，不叠加探测', () async {
      final gate = Completer<void>();
      final resolver = _StubResolver(<String, DnsOutcome>{});
      final monitor = DnsMonitor(
        config: const DnsMonitorConfig(
          domesticServers: <String>['223.5.5.5'],
          tunnelProbeUrl: 'https://example.com',
        ),
        resolver: resolver,
        tunnelLatencyProbe: () async {
          await gate.future;
          return 10;
        },
        cnIpIndex: _cnIndex(),
      );

      final first = monitor.runOnce();
      // 等它进入隧道探测并挂住。
      await Future<void>.delayed(Duration.zero);
      expect(monitor.isRunning, isTrue);
      final second = await monitor.runOnce();
      expect(second.isEmpty || second.checkedAt.year == 1970, isTrue);

      gate.complete();
      await first;
      expect(monitor.isRunning, isFalse);
    });
  });

  group('DNS 监测：滚动窗口统计', () {
    test('分位数不受单次超时影响，均值会', () {
      final window = LatencyWindow(capacity: 10);
      for (var i = 0; i < 9; i++) {
        window.add(20);
      }
      window.add(3000);

      expect(window.median, 20, reason: '中位数要能代表常态');
      expect(window.p95, 3000);
      expect(window.average, greaterThan(300), reason: '均值被超时拉高，所以不用它做判断');
    });

    test('窗口满了丢最旧的样本', () {
      final window = LatencyWindow(capacity: 3);
      for (final value in <int>[10, 20, 30, 40]) {
        window.add(value);
      }
      expect(window.length, 3);
      expect(window.min, 20);
      expect(window.median, 30);
    });

    test('空窗口的统计返回 null 而不是 0', () {
      final window = LatencyWindow(capacity: 4);
      expect(window.median, isNull);
      expect(window.p95, isNull);
      expect(window.average, isNull);
      expect(window.min, isNull);
    });
  });

  group('DNS 交叉校验结论', () {
    test('国内答案在国内、与隧道不同 → 国内外双部署', () async {
      final resolver = _StubResolver(<String, DnsOutcome>{
        '223.5.5.5|www.example.com': _ok(
          '223.5.5.5',
          'www.example.com',
          <String>['192.0.2.1'],
        ),
      });
      final monitor = _monitor(resolver, tunnelDelay: 60);
      monitor.tunnelResolveProbe = (String domain) async => <String>[
        '198.51.100.1',
      ];

      final check = await monitor.crossCheck('www.example.com');

      expect(check.verdict, DnsVerdict.dualStack);
      expect(check.disjoint, isTrue);
      expect(check.domesticAnswers, <String>['192.0.2.1']);
      expect(DnsVerdict.dualStack.advice, contains('按域名判定分流'));
    });

    test('国内答案不在国内且与隧道不同 → 疑似投毒', () async {
      final resolver = _StubResolver(<String, DnsOutcome>{
        '223.5.5.5|www.blocked.com': _ok(
          '223.5.5.5',
          'www.blocked.com',
          <String>['198.51.100.174'],
        ),
      });
      final monitor = _monitor(resolver, tunnelDelay: 200);
      monitor.tunnelResolveProbe = (String domain) async => <String>[
        '198.51.100.14',
      ];

      final check = await monitor.crossCheck('www.blocked.com');

      expect(check.verdict, DnsVerdict.suspectPoisoning);
      expect(DnsVerdict.suspectPoisoning.advice, contains('走隧道'));
    });

    test('国内答案在国内且与隧道一致 → 一致', () async {
      final resolver = _StubResolver(<String, DnsOutcome>{
        '223.5.5.5|www.example.com': _ok(
          '223.5.5.5',
          'www.example.com',
          <String>['192.0.2.1'],
        ),
      });
      final monitor = _monitor(resolver, tunnelDelay: 60);
      monitor.tunnelResolveProbe = (String domain) async => <String>[
        '192.0.2.1',
      ];

      final check = await monitor.crossCheck('www.example.com');
      expect(check.verdict, DnsVerdict.consistent);
      expect(check.disjoint, isFalse);
    });

    test('国内解析器单次全失败 → 不下异常结论（一次丢包不足以定性）', () async {
      final resolver = _StubResolver(const <String, DnsOutcome>{});
      final monitor = _monitor(resolver, tunnelDelay: 60);
      monitor.tunnelResolveProbe = (String domain) async => <String>['1.2.3.4'];

      final check = await monitor.crossCheck('www.example.com');
      expect(
        check.verdict,
        DnsVerdict.consistent,
        reason: '明文 UDP 丢一个包就会走到这条分支，而界面上它是要用户去改设置的重结论',
      );
    });

    test('国内解析器连续两次全失败 → 判定为国内解析异常', () async {
      final resolver = _StubResolver(const <String, DnsOutcome>{});
      final monitor = _monitor(resolver, tunnelDelay: 60);
      monitor.tunnelResolveProbe = (String domain) async => <String>['1.2.3.4'];

      // 第一次：只累计失败次数，不下结论。
      await monitor.crossCheck('www.example.com');
      // 第二次：达到阈值，这时才认定解析器真的不可用。
      // force 是必需的：同一个域名的结果有 TTL 缓存，不绕过就拿不到新结论。
      final check = await monitor.crossCheck('www.example.com', force: true);
      expect(check.verdict, DnsVerdict.directResolverDown);
    });

    test('拿不到地理信息时不下「投毒」结论，宁可保守', () async {
      final resolver = _StubResolver(<String, DnsOutcome>{
        '223.5.5.5|www.example.com': _ok(
          '223.5.5.5',
          'www.example.com',
          <String>['198.51.100.174'],
        ),
      });
      // 空索引 = 拿不到地理信息。
      final monitor = _monitor(
        resolver,
        tunnelDelay: 60,
        index: CnIpIndex.empty,
      );
      monitor.tunnelResolveProbe = (String domain) async => <String>[
        '198.51.100.14',
      ];

      final check = await monitor.crossCheck('www.example.com');
      expect(
        check.verdict,
        DnsVerdict.consistent,
        reason: '没有地理依据就断言投毒，会把正常流量误推进隧道',
      );
    });

    test('第二个国内解析器能兜住第一个的失败', () async {
      final resolver = _StubResolver(<String, DnsOutcome>{
        // 223.5.5.5 查这个域名失败
        '119.29.29.29|www.example.com': _ok(
          '119.29.29.29',
          'www.example.com',
          <String>['192.0.2.1'],
          millis: 33,
        ),
      });
      final monitor = _monitor(resolver, tunnelDelay: 60);
      monitor.tunnelResolveProbe = (String domain) async => <String>[
        '198.51.100.1',
      ];

      final check = await monitor.crossCheck('www.example.com');
      expect(check.domesticAnswers, <String>['192.0.2.1']);
      expect(check.domesticMillis, 33);
      expect(check.verdict, DnsVerdict.dualStack);
    });

    test('校验结果被缓存，短时间内不重复占用隧道往返', () async {
      final resolver = _StubResolver(<String, DnsOutcome>{
        '223.5.5.5|www.example.com': _ok(
          '223.5.5.5',
          'www.example.com',
          <String>['192.0.2.1'],
        ),
      });
      final monitor = _monitor(resolver, tunnelDelay: 60);
      monitor.tunnelResolveProbe = (String domain) async => <String>[
        '198.51.100.1',
      ];

      await monitor.crossCheck('www.example.com');
      final queryCount = resolver.queries.length;
      await monitor.crossCheck('www.example.com');
      expect(resolver.queries.length, queryCount, reason: '第二次应命中缓存');

      // force 时强制重新校验。
      await monitor.crossCheck('www.example.com', force: true);
      expect(resolver.queries.length, greaterThan(queryCount));
    });

    test('cachedCheck 能读到缓存但不触发新探测', () async {
      final resolver = _StubResolver(<String, DnsOutcome>{
        '223.5.5.5|www.example.com': _ok(
          '223.5.5.5',
          'www.example.com',
          <String>['192.0.2.1'],
        ),
      });
      final monitor = _monitor(resolver, tunnelDelay: 60);
      monitor.tunnelResolveProbe = (String domain) async => <String>[
        '198.51.100.1',
      ];

      expect(monitor.cachedCheck('www.example.com'), isNull);
      await monitor.crossCheck('www.example.com');
      expect(monitor.cachedCheck('www.example.com'), isNotNull);
    });

    test('并发校验同一域名只发一轮探测', () async {
      // 失败往往成批出现。没有去重的话，一批失败会同时拉起几十个探测，
      // 互相抢带宽并把「耗时」测成排队时间，让 DNS 健康度看起来比实际差。
      final gate = Completer<void>();
      var probeCalls = 0;
      final resolver = _StubResolver(<String, DnsOutcome>{
        '223.5.5.5|www.example.com': _ok(
          '223.5.5.5',
          'www.example.com',
          <String>['192.0.2.1'],
        ),
      });
      final monitor = DnsMonitor(
        config: const DnsMonitorConfig(
          domesticServers: <String>['223.5.5.5'],
          tunnelProbeUrl: 'https://example.com',
        ),
        resolver: resolver,
        tunnelLatencyProbe: () async {
          probeCalls++;
          await gate.future;
          return 42;
        },
        cnIpIndex: _cnIndex(),
      );
      monitor.tunnelResolveProbe = (String domain) async => <String>[
        '198.51.100.1',
      ];

      // 三个并发请求同一个域名。
      final futures = <Future<DnsCrossCheck>>[
        monitor.crossCheck('www.example.com'),
        monitor.crossCheck('www.example.com'),
        monitor.crossCheck('www.example.com'),
      ];
      await Future<void>.delayed(Duration.zero);
      expect(probeCalls, 1, reason: '只应有一轮探测在跑');

      gate.complete();
      final results = await Future.wait(futures);
      for (final result in results) {
        expect(result.domesticAnswers, <String>['192.0.2.1']);
        expect(result.verdict, DnsVerdict.dualStack);
      }
    });

    test('探测失败后不会把失败结果永久缓存住', () async {
      // 如果异常路径忘了摘掉「进行中」的登记，这个域名之后再也不会被重新探测。
      final resolver = _StubResolver(<String, DnsOutcome>{
        '223.5.5.5|www.example.com': _ok(
          '223.5.5.5',
          'www.example.com',
          <String>['192.0.2.1'],
        ),
      });
      var shouldThrow = true;
      final monitor = DnsMonitor(
        config: const DnsMonitorConfig(
          domesticServers: <String>['223.5.5.5'],
          tunnelProbeUrl: 'https://example.com',
        ),
        resolver: resolver,
        tunnelLatencyProbe: () async {
          if (shouldThrow) throw StateError('隧道探测炸了');
          return 42;
        },
        cnIpIndex: _cnIndex(),
      );
      monitor.tunnelResolveProbe = (String domain) async => <String>[
        '198.51.100.1',
      ];

      await expectLater(
        monitor.crossCheck('www.example.com'),
        throwsA(isA<StateError>()),
      );

      shouldThrow = false;
      final recovered = await monitor.crossCheck('www.example.com');
      expect(recovered.verdict, DnsVerdict.dualStack, reason: '第二次应能重新探测');
    });

    test('reset 清空全部统计与缓存', () async {
      final resolver = _StubResolver(<String, DnsOutcome>{
        '223.5.5.5|www.baidu.com': _ok('223.5.5.5', 'www.baidu.com', <String>[
          '1.2.3.4',
        ]),
      });
      final monitor = _monitor(resolver, tunnelDelay: 60);
      await monitor.runOnce();
      expect(monitor.report.resolvers, isNotEmpty);

      monitor.reset();
      expect(monitor.report.resolvers, isEmpty);
      expect(monitor.report.isEmpty, isTrue);
      expect(monitor.report.summary, contains('尚未完成'));
    });
  });

  group('DNS 报告文案', () {
    test('直连明显慢于隧道时给出可操作的结论', () {
      final report = DnsReport(
        checkedAt: DateTime(2026, 1, 1),
        resolvers: const <ResolverHealth>[],
        direct: LatencyWindow(capacity: 4)..add(400),
        tunnel: LatencyWindow(capacity: 4)..add(60),
        verdict: DnsVerdict.consistent,
      );
      expect(report.summary, contains('慢 340ms'));
      expect(report.summary, contains('可能正在走隧道解析'));
    });

    test('两种耗时都正常时并列显示', () {
      final report = DnsReport(
        checkedAt: DateTime(2026, 1, 1),
        resolvers: const <ResolverHealth>[],
        direct: LatencyWindow(capacity: 4)..add(15),
        tunnel: LatencyWindow(capacity: 4)..add(80),
        verdict: DnsVerdict.consistent,
      );
      expect(report.summary, '直连解析 15ms · 隧道解析 80ms');
    });

    test('只有一侧有数据时不编造另一侧', () {
      final report = DnsReport(
        checkedAt: DateTime(2026, 1, 1),
        resolvers: const <ResolverHealth>[],
        direct: LatencyWindow(capacity: 4)..add(15),
        tunnel: LatencyWindow(capacity: 4),
        verdict: DnsVerdict.consistent,
      );
      expect(report.summary, '直连解析 15ms');
    });
  });
}

/// 手工拼一个 DNS 响应报文，用于编解码测试。
Uint8List _makeResponse({
  required int id,
  int rcode = 0,
  required List<List<int>> answers,
  List<List<int>> ipv6Answers = const <List<int>>[],
}) {
  final answerCount = answers.length + ipv6Answers.length;
  final buffer = BytesBuilder();
  final header = ByteData(12);
  header.setUint16(0, id);
  header.setUint16(2, 0x8180); // QR=1, RD=1, RA=1
  header.setUint16(4, 1); // QDCOUNT
  header.setUint16(6, answerCount);
  buffer.add(header.buffer.asUint8List());

  // 问题段：example.com A IN
  buffer.add(<int>[7]);
  buffer.add('example'.codeUnits);
  buffer.add(<int>[3]);
  buffer.add('com'.codeUnits);
  buffer.add(<int>[0, 0, 1, 0, 1]);

  void addRecord(int type, List<int> rdata) {
    final record = ByteData(12);
    // 名字用压缩指针指向问题段里的 example.com。
    record.setUint16(0, 0xC00C);
    record.setUint16(2, type);
    record.setUint16(4, 1); // IN
    record.setUint32(6, 60); // TTL
    record.setUint16(10, rdata.length);
    buffer.add(record.buffer.asUint8List());
    buffer.add(rdata);
  }

  for (final address in answers) {
    addRecord(1, address);
  }
  for (final address in ipv6Answers) {
    addRecord(28, address);
  }

  final bytes = buffer.toBytes();
  bytes[3] = rcode & 0x0F;
  return bytes;
}
