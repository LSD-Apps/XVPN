import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/auto_route.dart';
import 'package:xvpn/core/core_monitor.dart';
import 'package:xvpn/core/dns_client.dart';

import 'support/recording_listener.dart';

/// 观测循环的成本上限。
///
/// 这一组用例不是微基准，而是**回归护栏**：把「高频路径花销与连接数成正比、
/// 且不随轮次退化」写成断言。项目里已有明确的性能纪律（分流记录用环形缓冲、
/// 筛选结果带缓存、已上报集合自动扩容、稳态连接不再每秒 fromJson），但那些
/// 有的是为**界面**而做的；这一组盯的是**观测循环本身**——它每秒都跑，且与
/// 分流共用同一个 isolate，卡住就会同时影响分流数据的处理。
///
/// 阈值刻意定得宽松（远高于实测值），这样它在 CI 的负载波动下也不会误报，
/// 但一旦有人把某个 O(n²) 的写法带进来就会立刻触发。
void main() {
  /// 造一份含 [count] 条活连接的快照。
  ///
  /// [hostPrefix] 与 [idPrefix] 让每次调用产生不同的连接 id，从而覆盖
  /// 「新连接」这条路径；传相同前缀则覆盖「同一批连接持续存在」的稳态。
  String snapshot({
    required int count,
    required String idPrefix,
    required String hostPrefix,
    bool proxied = false,
    int bytesEach = 4096,
  }) {
    final start = DateTime.now().toUtc().subtract(const Duration(seconds: 2));
    return jsonEncode(<String, Object?>{
      'downloadTotal': bytesEach * count,
      'uploadTotal': 0,
      'memory': 2048,
      'connections': <Object?>[
        for (var i = 0; i < count; i++)
          <String, Object?>{
            'id': '$idPrefix-$i',
            'metadata': <String, Object?>{
              'network': 'tcp',
              'host': '$hostPrefix-$i.example',
              'destinationIP': '203.0.113.${(i % 250) + 1}',
              'destinationPort': '443',
            },
            'upload': 0,
            'download': bytesEach,
            'start': start.toIso8601String(),
            'chains': <String>[proxied ? 'vpn' : 'direct'],
            'rule': 'final',
            'rulePayload': '',
          },
      ],
    });
  }

  /// 一个总返回同一份（或按轮次轮换）响应的 HttpClient 桩。
  CoreMonitor monitorWith(RecordingListener listener, List<String> bodies) {
    return CoreMonitor(
      CoreMonitorHooks(
        listener: listener,
        clashApiPort: 2081,
        autoRoute: AutoRouteTable(),
        probesEnabled: false,
        dnsResolver: _NoopResolver(),
        httpClient: _RotatingHttpClient(bodies),
      ),
    );
  }

  group('观测循环的成本', () {
    test('2000 条活连接的稳态采样：单轮远低于 1 秒的轮询预算', () async {
      final listener = RecordingListener();
      final monitor = monitorWith(
        listener,
        <String>[snapshot(count: 2000, idPrefix: 'live', hostPrefix: 'h')],
      );
      addTearDown(monitor.dispose);

      // 预热一轮，把首次分配排除。
      await monitor.tick();

      final sw = Stopwatch()..start();
      for (var i = 0; i < 20; i++) {
        await monitor.tick();
      }
      sw.stop();

      final perTick = sw.elapsedMilliseconds / 20;
      // 预算：轮询周期是 1 秒，而按目标归并的上报本来就是这个量级的工作。
      // 定在 250ms 是「明显不对就报」的门槛，不是性能目标。
      expect(
        perTick,
        lessThan(250),
        reason: '2000 条连接的稳态采样每轮 ${perTick.toStringAsFixed(1)}ms，'
            '已接近 1 秒轮询预算——方向性地说明有与连接数不成正比的写法混进来了',
      );
    });

    test('连接反复开关（走质量判定路径）时成本仍与连接数成正比', () async {
      // 这条专门覆盖新增的「连接关闭后判定质量」路径：它每轮都会遍历消失的连接。
      // 若那里写成「每次都全表扫描」或「每个域名线性查找」，这里会立刻变大。
      final listener = RecordingListener();
      final bodies = <String>[
        for (var round = 0; round < 40; round++)
          round.isEven
              ? snapshot(
                  count: 500,
                  idPrefix: 'r$round',
                  hostPrefix: 'churn$round',
                )
              : snapshot(count: 0, idPrefix: 'r$round', hostPrefix: 'churn'),
      ];
      final monitor = monitorWith(listener, bodies);
      addTearDown(monitor.dispose);

      // 预热：让第一批连接的轨迹建立起来。
      await monitor.tick();

      final sw = Stopwatch()..start();
      for (var i = 0; i < 40; i++) {
        await monitor.tick();
      }
      sw.stop();

      final perTick = sw.elapsedMilliseconds / 40;
      expect(
        perTick,
        lessThan(250),
        reason: '500 条连接反复开关时每轮 ${perTick.toStringAsFixed(1)}ms',
      );
    });

    test('判定挂死不会随表内域名数退化（时间窗限流是 O(1)）', () async {
      // 先在表里堆一批无关域名，再让同一批连接反复挂死。
      // 若限流写成「遍历已记录域名」，这一步会随表大小线性变慢。
      final table = AutoRouteTable(capacity: 2000);
      for (var i = 0; i < 1000; i++) {
        table.recordDirectFailure('noise-$i.example', reason: '预热');
      }
      final listener = RecordingListener();
      final stalled = jsonEncode(<String, Object?>{
        'downloadTotal': 0,
        'uploadTotal': 0,
        'memory': 2048,
        'connections': <Object?>[
          for (var i = 0; i < 200; i++)
            <String, Object?>{
              'id': 'stall-$i',
              'metadata': <String, Object?>{
                'network': 'tcp',
                'host': 'stalled-$i.example',
                'destinationPort': '443',
              },
              'upload': 0,
              'download': 0,
              'start': DateTime.now()
                  .toUtc()
                  .subtract(const Duration(seconds: 10))
                  .toIso8601String(),
              'chains': <String>['direct'],
              'rule': 'final',
            },
        ],
      });
      final empty = snapshot(count: 0, idPrefix: 'none', hostPrefix: 'none');
      final monitor = CoreMonitor(
        CoreMonitorHooks(
          listener: listener,
          clashApiPort: 2081,
          autoRoute: table,
          probesEnabled: false,
          dnsResolver: _NoopResolver(),
          httpClient: _RotatingHttpClient(<String>[stalled, empty, stalled, empty]),
        ),
      );
      addTearDown(monitor.dispose);

      final sw = Stopwatch()..start();
      for (var i = 0; i < 10; i++) {
        await monitor.tick();
      }
      sw.stop();

      expect(
        sw.elapsedMilliseconds,
        lessThan(2000),
        reason: '表内已有 1000 条无关域名时，10 轮采样用了 ${sw.elapsedMilliseconds}ms',
      );
    });
  });
}

class _NoopResolver implements DnsResolver {
  @override
  Future<DnsOutcome> query(
    String server,
    String name, {
    Duration? timeout,
  }) async => DnsOutcome(
    server: server,
    name: name,
    answers: const <String>[],
    elapsed: const Duration(milliseconds: 1),
  );

  @override
  void close() {}
}

/// 按轮次轮换响应体，模拟连接的出现与关闭。
class _RotatingHttpClient implements HttpClient {
  _RotatingHttpClient(this._bodies);

  final List<String> _bodies;
  int _index = 0;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    final body = _bodies[_index % _bodies.length];
    _index++;
    return _RotatingRequest(body);
  }

  @override
  void close({bool force = false}) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RotatingRequest implements HttpClientRequest {
  _RotatingRequest(this.body);

  final String body;

  @override
  Future<HttpClientResponse> close() async => _RotatingResponse(body);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RotatingResponse extends Stream<List<int>> implements HttpClientResponse {
  _RotatingResponse(String body) : _bytes = utf8.encode(body);

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
