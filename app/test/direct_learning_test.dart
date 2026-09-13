import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/auto_route.dart';
import 'package:xvpn/core/cn_ip_index.dart';
import 'package:xvpn/core/core_monitor.dart';
import 'package:xvpn/core/dns_client.dart';

import 'support/recording_listener.dart';

/// 反方向自动纠正：把「本该直连却走了隧道」的域名拉出来。
///
/// 这条路径补的是一个设计缺口：原来的自动纠正只有「判为直连却失败」这一种证据，
/// 于是程序只能往隧道里推。而误入隧道的流量不失败、不报错，此前完全不可观测。
void main() {
  group('AutoRouteTable 的反方向学习', () {
    test('不到阈值不建规则，也不在表里留下任何条目', () {
      final table = AutoRouteTable();
      final first = table.recordDomesticAnswer('cn.example');
      expect(first.added, isFalse);
      expect(
        table.match('cn.example'),
        isNull,
        reason: '解析到国内地址是事实，「所以该直连」是推断——单次不足以改路由',
      );
      expect(
        table.buildRouteRules().otherRules,
        isEmpty,
        reason: '未定性的证据绝不能变成路由规则：默认 preference 是「强制走隧道」，'
            '方向恰好与本证据相反，会把域名钉死在隧道里',
      );
      expect(first.reason, contains('1/2'));
    });

    test('连续两次落在国内网段后学成直连规则', () {
      final table = AutoRouteTable();
      table.recordDomesticAnswer('cn.example');
      final decision = table.recordDomesticAnswer('cn.example');

      expect(decision.added, isTrue);
      final entry = table.match('cn.example');
      expect(entry, isNotNull);
      expect(entry!.preference, RoutePreference.forceDirect);
      expect(entry.source, RouteRuleSource.learned);
      expect(entry.domesticHits, 2);
      expect(decision.reason, contains('已自动改为直连'));
    });

    test('学成的直连规则会写进路由片段（并注入到规则库之前）', () {
      final table = AutoRouteTable();
      table.recordDomesticAnswer('cn.example');
      table.recordDomesticAnswer('cn.example');

      final rules = table.buildRouteRules().otherRules;
      final direct = rules.last;
      expect(direct['outbound'], 'direct');
      expect(direct['domain_suffix'], contains('cn.example'));
    });

    test('用户已指定的规则不会被改写，只记证据', () {
      final table = AutoRouteTable()
        ..setUserRule('mine.example', RoutePreference.forceProxy);
      table.recordDomesticAnswer('mine.example');
      final decision = table.recordDomesticAnswer('mine.example');

      expect(decision.added, isFalse);
      final entry = table.match('mine.example')!;
      expect(entry.source, RouteRuleSource.user);
      expect(
        entry.preference,
        RoutePreference.forceProxy,
        reason: '用户的明确决定不该被程序的推断改写',
      );
    });

    test('IP 目标与单标签主机名不参与', () {
      final table = AutoRouteTable();
      expect(table.recordDomesticAnswer('198.51.100.7').added, isFalse);
      expect(table.recordDomesticAnswer('localhost').added, isFalse);
      expect(table.match('198.51.100.7'), isNull);
    });

    test('一次直连失败会把国内解析计数清零，避免来回翻转', () {
      final table = AutoRouteTable();
      table.recordDomesticAnswer('flaky.example');
      // 直连失败是反证：清零后需要**重新**连续两次正向证据才会改路由。
      table.recordDirectFailure('flaky.example', reason: '连接超时');

      expect(table.recordDomesticAnswer('flaky.example').added, isFalse);
      expect(
        table.match('flaky.example')!.preference,
        isNot(RoutePreference.forceDirect),
        reason: '反证优先：不清零会让两个方向反复互相推翻，分流时好时坏',
      );
      expect(table.recordDomesticAnswer('flaky.example').added, isTrue);
    });

    test('学成的直连规则若直连失败，会被改回走隧道', () {
      final table = AutoRouteTable();
      table.recordDomesticAnswer('wrong.example');
      table.recordDomesticAnswer('wrong.example');
      expect(table.match('wrong.example')!.preference, RoutePreference.forceDirect);

      for (var i = 0; i < 3; i++) {
        table.recordDirectFailure('wrong.example', reason: '连接超时');
      }
      final entry = table.match('wrong.example')!;
      expect(entry.preference, RoutePreference.forceProxy);
      expect(
        entry.domesticHits,
        0,
        reason: '残留的计数会在下一次正面解析时立刻把它翻回直连',
      );
    });

    test('国内解析计数会持久化（重启后不从头再数）', () {
      final table = AutoRouteTable();
      table.recordDomesticAnswer('cn.example');
      table.recordDomesticAnswer('cn.example');
      expect(table.match('cn.example')!.domesticHits, 2);

      final restored = AutoRouteTable()
        ..loadFrom(jsonDecode(jsonEncode(table.toJson())));

      final entry = restored.match('cn.example')!;
      expect(entry.preference, RoutePreference.forceDirect);
      expect(
        entry.domesticHits,
        2,
        reason: '证据要随规则一起落盘，否则界面无法解释这条规则为什么存在',
      );
    });

    test('未定性的证据不落盘（它还不是规则）', () {
      final table = AutoRouteTable();
      table.recordDomesticAnswer('pending.example');
      expect(table.toJson(), isEmpty);
    });

    test('长期未命中淘汰时，直连跑出过流量的规则会被保留', () {
      final table = AutoRouteTable();
      table.recordDomesticAnswer('used.example');
      table.recordDomesticAnswer('used.example');
      // 直连确实跑出过流量 —— 这是这条规则有用的证据。
      table.recordDirectSuccess('used.example');
      table.recordDirectSuccess('used.example');

      final removed = table.evictStale(
        now: DateTime.now().add(const Duration(days: 30)),
      );
      expect(
        removed,
        isNot(contains('used.example')),
        reason: '直连规则的收益是「省下隧道流量」，不能用 proxiedBytes 判断它有没有用',
      );
    });
  });

  group('CoreMonitor 的候选探测驱动', () {
    late Directory assets;

    setUp(() {
      assets = Directory('assets/rulesets');
    });

    /// 一份含一条走隧道连接的 `/connections` 快照。
    String snapshotWith(String host) => jsonEncode(<String, Object?>{
      'downloadTotal': 4096,
      'uploadTotal': 1024,
      'memory': 1024,
      'connections': <Object?>[
        <String, Object?>{
          'id': 'conn-1',
          'metadata': <String, Object?>{
            'network': 'tcp',
            'host': host,
            'destinationIP': '203.0.113.9',
            'destinationPort': '443',
          },
          'upload': 1024,
          'download': 4096,
          'start': '2026-02-14T10:20:30Z',
          'chains': <String>['vpn'],
          'rule': 'final',
          'rulePayload': '',
        },
      ],
    });

    /// 一个总是返回固定地址的解析器桩。
    DnsResolver resolverReturning(List<String> answers) =>
        _StubResolver(answers);

    test('走隧道的域名在解析落在国内网段时被学成直连', () async {
      final index = CnIpIndex.parse(
        File('${assets.path}${Platform.pathSeparator}cn-ip.bin')
            .readAsBytesSync(),
      );
      expect(index, isNotNull, reason: '前缀索引缺失时这个用例没有意义');

      final table = AutoRouteTable();
      final listener = RecordingListener();
      final monitor = CoreMonitor(
        CoreMonitorHooks(
          listener: listener,
          clashApiPort: 2081,
          autoRoute: table,
          cnIpIndex: index!,
          probesEnabled: true,
          // 223.5.5.5 确实落在 geoip-cn 覆盖的网段内（见 docs/RULES.md 的实测）。
          dnsResolver: resolverReturning(<String>['223.5.5.5']),
          tunnelLatencyProbe: () async => 120,
          httpClient: _FakeHttpClient(snapshotWith('cn-longtail.example')),
        ),
      );
      addTearDown(monitor.dispose);

      // 一轮采样把这条走隧道的连接排进候选队列。
      await monitor.tick();
      expect(listener.records, hasLength(1));

      // 阈值是 2：两次**独立**测量后才改路由（第二轮会绕过校验缓存，
      // 否则第二次只是重读同一次测量）。
      await monitor.probeDirectCandidates();
      expect(
        table.match('cn-longtail.example'),
        isNull,
        reason: '第一次探测只该累计证据',
      );
      await monitor.probeDirectCandidates();

      final entry = table.match('cn-longtail.example');
      expect(entry, isNotNull);
      expect(entry!.preference, RoutePreference.forceDirect);
      expect(
        listener.learned.map((AutoRouteDecision d) => d.domain),
        contains('cn-longtail.example'),
        reason: '学到的规则要通知界面，否则用户看不到程序改了什么',
      );
    });

    test('解析结果不在国内网段时不动路由', () async {
      final index = CnIpIndex.parse(
        File('${assets.path}${Platform.pathSeparator}cn-ip.bin')
            .readAsBytesSync(),
      );
      final table = AutoRouteTable();
      final monitor = CoreMonitor(
        CoreMonitorHooks(
          listener: RecordingListener(),
          clashApiPort: 2081,
          autoRoute: table,
          cnIpIndex: index!,
          probesEnabled: true,
          // 8.8.8.8 不在 geoip-cn 内。
          dnsResolver: resolverReturning(<String>['8.8.8.8']),
          tunnelLatencyProbe: () async => 120,
          httpClient: _FakeHttpClient(snapshotWith('overseas.example')),
        ),
      );
      addTearDown(monitor.dispose);

      await monitor.tick();
      await monitor.probeDirectCandidates();
      await monitor.probeDirectCandidates();

      expect(
        table.match('overseas.example'),
        isNull,
        reason: '拿不到国内归属就不下结论——宁可少一次纠正，也不要把流量推出隧道',
      );
    });

    test('索引缺失时不下结论', () async {
      final table = AutoRouteTable();
      final monitor = CoreMonitor(
        CoreMonitorHooks(
          listener: RecordingListener(),
          clashApiPort: 2081,
          autoRoute: table,
          cnIpIndex: CnIpIndex.empty,
          probesEnabled: true,
          dnsResolver: resolverReturning(<String>['223.5.5.5']),
          tunnelLatencyProbe: () async => 120,
          httpClient: _FakeHttpClient(snapshotWith('cn-longtail.example')),
        ),
      );
      addTearDown(monitor.dispose);

      await monitor.tick();
      await monitor.probeDirectCandidates();
      await monitor.probeDirectCandidates();

      expect(table.match('cn-longtail.example'), isNull);
    });

    test('已有用户规则的目标不排入候选', () async {
      final table = AutoRouteTable()
        ..setUserRule('cn-longtail.example', RoutePreference.forceProxy);
      final monitor = CoreMonitor(
        CoreMonitorHooks(
          listener: RecordingListener(),
          clashApiPort: 2081,
          autoRoute: table,
          cnIpIndex: CnIpIndex.empty,
          probesEnabled: true,
          dnsResolver: resolverReturning(<String>['223.5.5.5']),
          tunnelLatencyProbe: () async => 120,
          httpClient: _FakeHttpClient(snapshotWith('cn-longtail.example')),
        ),
      );
      addTearDown(monitor.dispose);

      await monitor.tick();
      // 队列为空时直接返回，不产生任何探测。
      await monitor.probeDirectCandidates();
      await monitor.probeDirectCandidates();
      final entry = table.match('cn-longtail.example')!;
      expect(entry.source, RouteRuleSource.user);
      expect(
        entry.preference,
        RoutePreference.forceProxy,
        reason: '用户明确指定的走向不该被程序的推断覆盖',
      );
      expect(entry.domesticHits, 0);
    });
  });
}

class _StubResolver implements DnsResolver {
  _StubResolver(this.answers);

  final List<String> answers;

  @override
  Future<DnsOutcome> query(
    String server,
    String name, {
    Duration? timeout,
  }) async => DnsOutcome(
    server: server,
    name: name,
    answers: answers,
    elapsed: const Duration(milliseconds: 8),
  );

  @override
  void close() {}
}

class _FakeHttpClient implements HttpClient {
  _FakeHttpClient(this.body);

  final String body;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _FakeRequest(body);

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeRequest implements HttpClientRequest {
  _FakeRequest(this.body);

  final String body;

  @override
  Future<HttpClientResponse> close() async => _FakeResponse(body);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeResponse extends Stream<List<int>> implements HttpClientResponse {
  _FakeResponse(String body) : _bytes = utf8.encode(body);

  final List<int> _bytes;

  @override
  int get statusCode => 200;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.fromIterable(<List<int>>[_bytes]).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
