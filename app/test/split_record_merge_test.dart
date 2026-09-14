import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/app_state.dart';
import 'package:xvpn/core/core_log.dart';
import 'package:xvpn/models.dart';

/// 分流记录的**同目标合并**与流量累加。
///
/// 这一组锁的是一个真实的可用性问题：此前「一条连接一条记录」，打开一个视频网站
/// 会刷出几十条一模一样的域名，把「走了哪条路、跑了多少流量、有没有失败」全淹没。
SplitRecord _rec(
  String target, {
  RouteKind kind = RouteKind.proxy,
  String rule = '默认规则',
  String outbound = 'vpn',
  int up = 0,
  int down = 0,
}) {
  return SplitRecord(
    time: DateTime(2026, 9, 12, 10, 0, 0),
    target: target,
    kind: kind,
    rule: rule,
    outbound: outbound,
    uploadBytes: up,
    downloadBytes: down,
  );
}

void main() {
  group('同目标合并', () {
    test('同一目标重复出现只占一行，次数累加', () {
      final state = AppState();
      addTearDown(state.dispose);

      for (var i = 0; i < 12; i++) {
        state.onSplitRecord(_rec('www.youtube.com'));
      }

      expect(state.records, hasLength(1), reason: '同一目标刷出十几行会把列表淹没');
      expect(state.records.single.connections, 12);
      expect(state.records.single.target, 'www.youtube.com');
    });

    test('不同目标各占一行，且最新的在最前', () {
      final state = AppState();
      addTearDown(state.dispose);

      state.onSplitRecord(_rec('a.example'));
      state.onSplitRecord(_rec('b.example'));
      state.onSplitRecord(_rec('a.example'));

      // `_recordsRing` 的枚举顺序是「最新的在最前」。a 的第一次访问先插入，
      // 因此排在 b 之后；它的第二次访问合并进原行，**不会**把它再置顶。
      expect(state.records.map((SplitRecord r) => r.target).toList(), <String>[
        'b.example',
        'a.example',
      ]);
      expect(state.records, hasLength(2), reason: 'a.example 重复访问两次仍只占一行');
      expect(
        state.records
            .firstWhere((SplitRecord r) => r.target == 'a.example')
            .connections,
        2,
      );
    });

    test('合并时保留首次出现的判定与规则，不因后续访问被改写', () {
      final state = AppState();
      addTearDown(state.dispose);

      state.onSplitRecord(
        _rec(
          'x.example',
          kind: RouteKind.direct,
          rule: 'geosite-cn + geoip-cn',
          outbound: 'direct',
        ),
      );
      // 同一个目标后来走了另一条路（例如自动纠正改了分流）：
      // 已有那一行保持首次的判定，避免用户看到的历史结论被悄悄改写。
      state.onSplitRecord(
        _rec(
          'x.example',
          kind: RouteKind.proxy,
          rule: 'learned',
          outbound: 'vpn',
        ),
      );

      final row = state.records.firstWhere(
        (SplitRecord r) => r.target == 'x.example',
      );
      expect(row.rule, 'geosite-cn + geoip-cn');
      expect(row.kind, RouteKind.direct);
      expect(row.connections, 2);
    });
  });

  group('流量增量累加到对应行', () {
    test('增量按目标累加，总量等于各次增量之和', () {
      final state = AppState();
      addTearDown(state.dispose);

      state.onSplitRecord(_rec('cdn.example'));
      for (var i = 0; i < 5; i++) {
        state.onConnectionTraffic(
          const ConnectionTraffic(
            target: 'cdn.example',
            kind: RouteKind.proxy,
            uploadDelta: 100,
            downloadDelta: 1000,
          ),
        );
      }

      final row = state.records.single;
      expect(row.uploadBytes, 500);
      expect(row.downloadBytes, 5000);
      expect(row.totalBytes, 5500);
    });

    test('没有对应记录时只丢增量、不凭空建行', () {
      final state = AppState();
      addTearDown(state.dispose);

      state.onConnectionTraffic(
        const ConnectionTraffic(
          target: 'ghost.example',
          kind: RouteKind.proxy,
          uploadDelta: 10,
          downloadDelta: 20,
        ),
      );

      expect(state.records, isEmpty, reason: '只更新流量、没有连接事件的目标不该在列表里冒出来');
    });
  });

  group('失败次数回填到行上', () {
    test('按主机名计数，并显示在对应那一行', () {
      final state = AppState();
      addTearDown(state.dispose);

      state.onSplitRecord(_rec('broken.example'));
      // 内核给的失败目标带端口，行上的目标是主机名——两者必须能对上。
      for (var i = 0; i < 3; i++) {
        state.onConnectionFailure(
          ConnectionFailure(
            time: DateTime(2026, 9, 12, 10),
            target: 'broken.example:443',
            outbound: 'vpn',
            reason: 'i/o timeout',
          ),
        );
      }

      expect(
        state.records
            .firstWhere((SplitRecord r) => r.target == 'broken.example')
            .failures,
        3,
      );
      expect(state.failures, hasLength(3), reason: '失败明细仍要完整保留，供排查使用');
    });

    test('清空记录时失败计数一并归零', () {
      final state = AppState();
      addTearDown(state.dispose);

      state.onSplitRecord(_rec('broken.example'));
      state.onConnectionFailure(
        ConnectionFailure(
          time: DateTime(2026, 9, 12, 10),
          target: 'broken.example:443',
          outbound: 'vpn',
          reason: 'i/o timeout',
        ),
      );
      state.clearRecords();
      state.onSplitRecord(_rec('broken.example'));

      expect(
        state.records
            .firstWhere((SplitRecord r) => r.target == 'broken.example')
            .failures,
        0,
        reason: '清空后旧的失败计数不该继续挂在新的那一行上',
      );
    });
  });

  group('观测分流（连接页占比数据来源）', () {
    ConnectionTraffic traffic(String target, RouteKind kind, int bytes) =>
        ConnectionTraffic(
          target: target,
          kind: kind,
          uploadDelta: 0,
          downloadDelta: bytes,
        );

    test('按路径累加，与目标是否有记录无关', () {
      final state = AppState();
      addTearDown(state.dispose);

      state.onSplitRecord(_rec('a.example', kind: RouteKind.proxy));
      state.onConnectionTraffic(traffic('a.example', RouteKind.proxy, 1000));
      // 这个目标没有记录（可能刚被淘汰），累计仍应生效——面板回答的是
      // 「本次连接走了多少隧道」，不该因为某一行消失而倒退。
      state.onConnectionTraffic(
        traffic('ghost.example', RouteKind.direct, 500),
      );

      expect(state.sessionProxiedBytes, 1000);
      expect(state.sessionDirectBytes, 500);
    });

    test('关闭分流明细后仍累计观测分流，只停按域名记账', () {
      final state = AppState();
      addTearDown(state.dispose);

      state.updateSettings(state.settings.copyWith(logSplits: false));
      state.onConnectionTraffic(traffic('a.example', RouteKind.proxy, 800));
      state.onConnectionTraffic(traffic('b.example', RouteKind.direct, 200));

      expect(state.sessionProxiedBytes, 800);
      expect(state.sessionDirectBytes, 200);
      expect(state.records, isEmpty, reason: '关闭明细后不该再长出分流行');
    });

    test('清空记录时观测分流一并归零', () {
      final state = AppState();
      addTearDown(state.dispose);

      state.onSplitRecord(_rec('a.example', kind: RouteKind.proxy));
      state.onConnectionTraffic(traffic('a.example', RouteKind.proxy, 1000));
      expect(state.sessionProxiedBytes, 1000);

      state.clearRecords();

      expect(state.sessionProxiedBytes, 0);
      expect(state.sessionDirectBytes, 0);
    });

    test('断开连接时观测分流与本次连接流量一并归零', () {
      final state = AppState();
      addTearDown(state.dispose);

      state.onTraffic(
        downBps: 1024,
        upBps: 512,
        totalBytes: 9000,
        directBytes: 100,
        proxiedBytes: 200,
        connectionCount: 3,
      );
      state.onConnectionTraffic(traffic('a.example', RouteKind.proxy, 1000));
      state.onConnectionTraffic(traffic('b.example', RouteKind.direct, 500));
      expect(state.sessionProxiedBytes, 1000);
      expect(state.totalBytes, 9000);

      state.onStatusChanged(VpnStatus.disconnected);

      expect(state.sessionProxiedBytes, 0);
      expect(state.sessionDirectBytes, 0);
      expect(state.totalBytes, 0);
      expect(state.downBps, 0);
      expect(state.upBps, 0);
      expect(state.connectionCount, 0);
    });

    test('已连接时 onTraffic 不立刻重建界面，避免与 ticker 双倍占用主线程', () async {
      final state = AppState();
      addTearDown(state.dispose);
      var notifies = 0;
      state.addListener(() => notifies++);

      state.onStatusChanged(VpnStatus.connected);
      final afterConnect = notifies;

      state.onTraffic(downBps: 1024, upBps: 512, totalBytes: 4096);
      expect(
        notifies,
        afterConnect,
        reason: '已连接时流量数字由 1s ticker 统一刷新，这里再 notify 会每秒双重建',
      );
      expect(state.downBps, 1024);
      expect(state.totalBytes, 4096);

      state.onStatusChanged(VpnStatus.disconnected);
      final afterDisconnect = notifies;
      state.onTraffic(downBps: 0, upBps: 0, totalBytes: 0);
      // 未连接时走合并通知（微任务），冲掉队列后再断言。
      await Future<void>.value();
      expect(notifies, greaterThan(afterDisconnect));
    });
  });

  group('记录淘汰时索引与计数一并清理', () {
    test('挤满上限后，被淘汰的目标会重新计为新的一行', () {
      final state = AppState();
      addTearDown(state.dispose);

      // 灌满上限再加一条，最早的那条会被环形缓冲挤出。
      for (var i = 0; i < AppState.recordLimit; i++) {
        state.onSplitRecord(_rec('h$i.example'));
      }
      state.onSplitRecord(_rec('overflow.example'));

      // 被挤出的目标再次出现时应当**重新建行**（而不是命中一个已失效的旧对象），
      // 否则它的流量与失败计数会累加到一条已经不在列表里的记录上。
      state.onSplitRecord(_rec('h0.example'));
      final revived = state.records.where(
        (SplitRecord r) => r.target == 'h0.example',
      );
      expect(revived, hasLength(1));
      expect(
        revived.single.connections,
        1,
        reason: '重新出现的行应当从 1 次访问开始，而不是沿用被淘汰前的计数',
      );
    });

    test('流量增量能找到仍有效的行，不会因为淘汰而错位', () {
      final state = AppState();
      addTearDown(state.dispose);

      state.onSplitRecord(_rec('keep.example'));
      state.onSplitRecord(_rec('evict.example', kind: RouteKind.proxy));
      state.onConnectionTraffic(
        const ConnectionTraffic(
          target: 'keep.example',
          kind: RouteKind.proxy,
          uploadDelta: 10,
          downloadDelta: 90,
        ),
      );

      expect(
        state.records
            .firstWhere((SplitRecord r) => r.target == 'keep.example')
            .downloadBytes,
        90,
      );
    });
  });
}
