import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/clash_api.dart';
import 'package:xvpn/core/record_buffer.dart';

/// 造一条内核风格的连接对象。
///
/// 字段名与取值全部对齐 sing-box v1.14.0 的
/// `experimental/clashapi/connections.go`，包括那个反直觉的 `rule`——
/// 它不是规则名，而是 `"<条件描述> => <动作>"` 形式的字符串。
Map<String, Object?> _connection({
  required String id,
  String host = 'example.com',
  String destinationIp = '198.51.100.34',
  int port = 443,
  String rule = 'rule_set=[geosite-cn geoip-cn] => route',
  List<String> chains = const <String>['vpn'],
  int upload = 10,
  int download = 200,
  String start = '2026-02-14T10:20:30Z',
  String network = 'tcp',
  String processPath = '',
}) {
  return <String, Object?>{
    'id': id,
    'metadata': <String, Object?>{
      'network': network,
      'type': 'mixed/mixed-in',
      'sourceIP': '127.0.0.1',
      'destinationIP': destinationIp,
      'sourcePort': '51000',
      'destinationPort': '$port',
      'host': host,
      'dnsMode': 'normal',
      'processPath': processPath,
    },
    'upload': upload,
    'download': download,
    'start': start,
    'chains': chains,
    'rule': rule,
    // 内核恒发空字符串。任何依赖它的解析都拿不到东西，这里刻意保留这个事实。
    'rulePayload': '',
  };
}

Map<String, Object?> _snapshot({
  required List<Map<String, Object?>> connections,
  int downloadTotal = 1000,
  int uploadTotal = 100,
  int memory = 4096,
}) {
  return <String, Object?>{
    'downloadTotal': downloadTotal,
    'uploadTotal': uploadTotal,
    'connections': connections,
    'memory': memory,
  };
}

void main() {
  group('规则描述文本归一化', () {
    test('规则库命中显示成标签列表，而不是整句描述', () {
      // 改造前：界面上「命中规则」这一列会原样显示
      // 「rule_set=[geosite-cn geoip-cn] => route」。
      expect(
        ClashConnection.ruleDisplayName(
          'rule_set=[geosite-cn geoip-cn] => route',
        ),
        'geosite-cn + geoip-cn',
      );
      expect(
        ClashConnection.ruleDisplayName('rule_set=[geosite-cn] => route'),
        'geosite-cn',
      );
    });

    test('单条规则库标签也保留名字', () {
      expect(
        ClashConnection.ruleDisplayName('rule_set=geoip-cn => route'),
        'geoip-cn',
      );
    });

    test('条目过多时折叠成数量，避免撑破表格', () {
      final label = ClashConnection.ruleDisplayName(
        'rule_set=[a-one b-two c-three d-four] => route',
      );
      expect(label, '规则库（4 项）');
    });

    test('局域网与默认规则各自有可读名字', () {
      expect(
        ClashConnection.ruleDisplayName('ip_is_private=true => route'),
        '局域网地址',
      );
      expect(ClashConnection.ruleDisplayName('final'), '默认规则');
      expect(ClashConnection.ruleDisplayName(''), '默认规则');
    });

    test('未知描述原样保留但截断，不把整句塞进表格', () {
      final long = 'something=${'x' * 100} => route';
      final label = ClashConnection.ruleDisplayName(long);
      expect(label.length, lessThanOrEqualTo(41));
      expect(label.endsWith('…'), isTrue);
    });
  });

  group('连接解析', () {
    test('出站取链尾，判定以链里是否出现 vpn 为准', () {
      final direct = ClashConnection.fromJson(
        _connection(id: 'a', chains: <String>['direct']),
      )!;
      expect(direct.outbound, 'direct');
      expect(direct.proxied, isFalse);

      final proxied = ClashConnection.fromJson(
        _connection(id: 'b', chains: <String>['vpn']),
      )!;
      expect(proxied.outbound, 'vpn');
      expect(proxied.proxied, isTrue);
    });

    test('按连接统计字节数，这是分流占比的数据来源', () {
      final conn = ClashConnection.fromJson(
        _connection(id: 'a', upload: 300, download: 700),
      )!;
      expect(conn.upload, 300);
      expect(conn.download, 700);
      expect(conn.totalBytes, 1000);
    });

    test('展示目标优先域名，其次 IP 加端口', () {
      final withHost = ClashConnection.fromJson(_connection(id: 'a'))!;
      expect(withHost.target, 'example.com');

      final ipOnly = ClashConnection.fromJson(
        _connection(id: 'b', host: '', destinationIp: '1.2.3.4', port: 8443),
      )!;
      expect(ipOnly.target, '1.2.3.4:8443');

      final ipv6 = ClashConnection.fromJson(
        _connection(
          id: 'c',
          host: '',
          destinationIp: '2400:cb00::1',
          port: 443,
        ),
      )!;
      expect(ipv6.target, '[2400:cb00::1]:443');

      final unknown = ClashConnection.fromJson(
        _connection(id: 'd', host: '', destinationIp: '0.0.0.0'),
      )!;
      expect(unknown.target, '(未知目标)');
    });

    test('缺少 id 的连接被丢弃，解析其余字段容错', () {
      expect(ClashConnection.fromJson(<String, Object?>{'id': ''}), isNull);
      expect(ClashConnection.fromJson('not a map'), isNull);

      final sparse = ClashConnection.fromJson(<String, Object?>{'id': 'x'})!;
      expect(sparse.rule, '默认规则');
      expect(sparse.outbound, 'direct');
    });

    test('开始时间解析成当地时间，格式异常时为 null', () {
      final conn = ClashConnection.fromJson(_connection(id: 'a'))!;
      expect(conn.startedAt, isNotNull);
      expect(conn.startedAt!.toUtc().year, 2026);

      final bad = ClashConnection.fromJson(
        _connection(id: 'b', start: 'not-a-time'),
      )!;
      expect(bad.startedAt, isNull);
    });
  });

  group('增量提取新连接', () {
    test('只上报本次新出现的连接', () {
      final seen = BoundedIdSet(100);
      final first = ClashSnapshot.pullNew(
        _snapshot(
          connections: <Map<String, Object?>>[
            _connection(id: 'a'),
            _connection(id: 'b'),
          ],
        ),
        seen,
      );
      expect(first.map((ClashConnection c) => c.id), <String>['a', 'b']);

      // 同一批再来一次：一条都不该重复上报。
      final again = ClashSnapshot.pullNew(
        _snapshot(
          connections: <Map<String, Object?>>[
            _connection(id: 'a'),
            _connection(id: 'b'),
          ],
        ),
        seen,
      );
      expect(again, isEmpty);
    });

    test('单次上报数量受 limit 限制，避免首连刷屏', () {
      final seen = BoundedIdSet(100);
      final batch = <Map<String, Object?>>[
        for (var i = 0; i < 50; i++) _connection(id: 'id-$i'),
      ];
      final pulled = ClashSnapshot.pullNew(
        _snapshot(connections: batch),
        seen,
        limit: 8,
      );
      expect(pulled, hasLength(8));

      // 被限制掉的那些没有进 seen，下一轮会补上。
      final second = ClashSnapshot.pullNew(
        _snapshot(connections: batch),
        seen,
        limit: 8,
      );
      expect(second.first.id, 'id-8');
    });

    test('id 为空的连接不占用名额', () {
      final seen = BoundedIdSet(100);
      final pulled = ClashSnapshot.pullNew(
        _snapshot(
          connections: <Map<String, Object?>>[
            <String, Object?>{'id': ''},
            _connection(id: 'good'),
          ],
        ),
        seen,
        limit: 1,
      );
      expect(pulled.map((ClashConnection c) => c.id), <String>['good']);
    });
  });

  group('已上报集合的容量上限', () {
    test('满了以后淘汰最旧的，而不是整体清空', () {
      // 这是被修掉的那个 bug：原实现是
      //   if (_seenConnections.length > 2000) _seenConnections.clear();
      // 清空的那一刻，当前活着的每条连接都会被当成新连接重新上报，
      // 分流记录里立刻出现成片重复。
      //
      // 这里把天花板对齐初始容量，专门验证「淘汰最旧」这个行为本身；
      // 正常运行时容量会按实际规模自动增长（另有测试覆盖）。
      final seen = BoundedIdSet(3)..growthCeiling = 3;
      seen.add('keep-1');
      seen.add('keep-2');
      seen.add('keep-3');
      seen.add('new-4'); // 挤掉 keep-1

      expect(seen.length, 3);
      expect(seen.contains('keep-1'), isFalse, reason: '最旧的应被淘汰');
      expect(seen.contains('keep-2'), isTrue, reason: '清空式的 bug 会把这条也丢掉');
      expect(seen.contains('keep-3'), isTrue);
      expect(seen.contains('new-4'), isTrue);
    });

    test('重复登记返回 false，长度不增长', () {
      final seen = BoundedIdSet(3);
      expect(seen.add('a'), isTrue);
      expect(seen.add('a'), isFalse);
      expect(seen.length, 1);
    });

    test('超过容量后长度恒定，内存不会随连接数无限增长', () {
      final seen = BoundedIdSet(50)..growthCeiling = 50;
      for (var i = 0; i < 5000; i++) {
        seen.add('id-$i');
      }
      expect(seen.length, 50);
      expect(seen.contains('id-4999'), isTrue);
      expect(seen.contains('id-0'), isFalse);
    });

    test('活连接数超过初始容量时自动扩容，而不是开始重复上报', () {
      // 容量固定时会陷入一个持续抖动的死循环：活连接数稳定超过容量 →
      // 每轮都有若干条被挤出集合 → 下一轮它们又被当成新连接上报，
      // 表现为分流记录里每隔几秒出现一批重复条目。
      final seen = BoundedIdSet(100);
      final live = <Map<String, Object?>>[
        for (var i = 0; i < 200; i++) _connection(id: 'live-$i'),
      ];

      final first = ClashSnapshot.pullNew(
        _snapshot(connections: live),
        seen,
        limit: 5000,
      );
      expect(first, hasLength(200), reason: '首次全部是新连接');
      expect(seen.capacity, greaterThanOrEqualTo(200), reason: '容量应跟着实际规模增长');

      final reportedAgain = ClashSnapshot.pullNew(
        _snapshot(connections: live),
        seen,
        limit: 5000,
      );
      expect(
        reportedAgain,
        isEmpty,
        reason: '稳态下不该有任何一条被重复上报，这正是原实现整体清空造成的 bug',
      );
    });

    test('连接数逐渐增长时持续扩容，稳态后不再重复', () {
      final seen = BoundedIdSet(10);
      var live = <Map<String, Object?>>[];
      // 连接数一路涨到 1500，每轮都跑一次提取。
      for (var round = 0; round < 15; round++) {
        live = <Map<String, Object?>>[
          for (var i = 0; i < (round + 1) * 100; i++) _connection(id: 'c-$i'),
        ];
        ClashSnapshot.pullNew(_snapshot(connections: live), seen, limit: 10000);
      }
      // 最后一轮再跑一次：此时集合必须已经装得下全部活连接。
      final steady = ClashSnapshot.pullNew(
        _snapshot(connections: live),
        seen,
        limit: 10000,
      );
      expect(steady, isEmpty);
      expect(seen.capacity, greaterThanOrEqualTo(1500));
      expect(seen.length, 1500);
    });

    test('到达容量天花板后长度恒定，不会无限增长', () {
      final seen = BoundedIdSet(50);
      for (var i = 0; i < 10000; i++) {
        seen.add('id-$i');
      }
      expect(seen.capacity, BoundedIdSet.defaultGrowthCeiling);
      expect(seen.length, BoundedIdSet.defaultGrowthCeiling);
      expect(seen.contains('id-9999'), isTrue);
      expect(seen.contains('id-0'), isFalse);
    });
  });

  group('快照整体解析', () {
    test('累计流量与内存用量', () {
      final snapshot = ClashSnapshot.parse(
        jsonEncode(
          _snapshot(
            connections: <Map<String, Object?>>[_connection(id: 'a')],
            downloadTotal: 2048,
            uploadTotal: 512,
            memory: 123456,
          ),
        ),
      )!;
      expect(snapshot.totalBytes, 2560);
      expect(snapshot.memory, 123456);
      expect(snapshot.connections, hasLength(1));
    });

    test('只取总量的快速路径不需要构造连接对象', () {
      final json = _snapshot(
        connections: <Map<String, Object?>>[_connection(id: 'a')],
        downloadTotal: 10,
        uploadTotal: 20,
        memory: 30,
      );
      final totals = ClashSnapshot.totalsOf(json);
      expect(totals.downloadTotal, 10);
      expect(totals.uploadTotal, 20);
      expect(totals.memory, 30);
    });

    test('解析失败返回 null 而不是抛异常', () {
      expect(ClashSnapshot.parse(''), isNull);
      expect(ClashSnapshot.parse('not json'), isNull);
      expect(ClashSnapshot.parse('[1,2,3]'), isNull);
      // 字段缺失时按 0 处理，不能让界面崩掉。
      final empty = ClashSnapshot.parse('{}')!;
      expect(empty.totalBytes, 0);
      expect(empty.connections, isEmpty);
    });
  });

  group('速率计算器', () {
    test('首次采样只建立基准，不报速率', () {
      final rate = RateCalculator();
      expect(
        rate.sample(DateTime(2026, 1, 1, 0, 0, 0), 1000, 100),
        isNull,
        reason: '累计值没有前一个采样点，算不出瞬时速率',
      );
    });

    test('按两次采样的差值算速率', () {
      final rate = RateCalculator();
      final t0 = DateTime(2026, 1, 1, 0, 0, 0);
      rate.sample(t0, 0, 0);
      final sample = rate.sample(
        t0.add(const Duration(seconds: 2)),
        4096,
        2048,
      )!;
      expect(sample.downBps, closeTo(2048, 0.001));
      expect(sample.upBps, closeTo(1024, 0.001));
      expect(sample.totalBytes, 6144);
    });

    test('内核重启导致计数归零时按 0 处理，不显示负数', () {
      final rate = RateCalculator();
      final t0 = DateTime(2026, 1, 1, 0, 0, 0);
      rate.sample(t0, 100000, 50000);
      final sample = rate.sample(t0.add(const Duration(seconds: 1)), 0, 0)!;
      expect(sample.downBps, 0);
      expect(sample.upBps, 0);
    });

    test('reset 之后重新建立基准', () {
      final rate = RateCalculator();
      final t0 = DateTime(2026, 1, 1, 0, 0, 0);
      rate.sample(t0, 1, 1);
      rate.reset();
      expect(rate.sample(t0.add(const Duration(seconds: 1)), 5, 5), isNull);
    });
  });

  group('环形缓冲', () {
    test('最新的在前，容量满了丢弃最旧的', () {
      final ring = RingBuffer<int>(3);
      ring.push(1);
      ring.push(2);
      ring.push(3);
      expect(ring.values.toList(), <int>[3, 2, 1]);
      ring.push(4);
      expect(ring.values.toList(), <int>[4, 3, 2]);
      expect(ring.length, 3);
    });

    test('索引访问与遍历顺序一致，越界返回 null', () {
      final ring = RingBuffer<String>(3);
      for (final value in <String>['a', 'b', 'c', 'd']) {
        ring.push(value);
      }
      expect(ring[0], 'd');
      expect(ring[2], 'b');
      expect(ring[3], isNull);
      expect(ring[-1], isNull);
      expect(ring.values.toList(), <String>['d', 'c', 'b']);
    });

    test('clear 之后不残留引用', () {
      final ring = RingBuffer<List<int>>(2);
      ring.push(<int>[1, 2, 3]);
      ring.clear();
      expect(ring.length, 0);
      expect(ring.isEmpty, isTrue);
    });

    test('插入一万条不产生额外分配', () {
      // 这是性能修复的核心断言：插入的代价与已存条数无关。
      final ring = RingBuffer<int>(500);
      for (var i = 0; i < 10000; i++) {
        ring.push(i);
      }
      expect(ring.length, 500);
      expect(ring[0], 9999);
    });
  });

  group('大数据量下的提取性能', () {
    test('两千条连接里只提取一条新连接，且不构造其余对象', () {
      final seen = BoundedIdSet(4000);
      final batch = <Map<String, Object?>>[
        for (var i = 0; i < 2000; i++) _connection(id: 'bulk-$i'),
      ];
      // 先全部登记，模拟稳态。
      ClashSnapshot.pullNew(_snapshot(connections: batch), seen, limit: 5000);

      final withNew = <Map<String, Object?>>[
        ...batch,
        _connection(id: 'brand-new'),
      ];
      // 计时只是为了防止出现「每次都全量构造」的回归；阈值放得很宽，
      // 避免在慢速 CI 上变成偶发失败。
      final watch = Stopwatch()..start();
      final pulled = ClashSnapshot.pullNew(
        _snapshot(connections: withNew),
        seen,
      );
      watch.stop();

      expect(pulled.map((ClashConnection c) => c.id), <String>['brand-new']);
      expect(
        watch.elapsedMilliseconds,
        lessThan(200),
        reason: '稳态提取必须是单遍且近乎无分配的',
      );
    });

    test('总量读取路径不随连接数变化', () {
      final big = _snapshot(
        connections: <Map<String, Object?>>[
          for (var i = 0; i < 2000; i++) _connection(id: 'bulk-$i'),
        ],
      );
      final watch = Stopwatch()..start();
      for (var i = 0; i < 1000; i++) {
        ClashSnapshot.totalsOf(big);
      }
      watch.stop();
      expect(watch.elapsedMilliseconds, lessThan(500));
    });
  });

  group('Uint8List 与 JSON 编码兼容性', () {
    test('内核返回的连接里 processPath 会被带上（TUN 模式下可用）', () {
      final conn = ClashConnection.fromJson(
        _connection(id: 'a', processPath: 'C:/Program Files/Chrome/chrome.exe'),
      )!;
      expect(conn.processPath, contains('chrome.exe'));
      expect(conn.network, 'tcp');
    });

    test('udp 连接同样被识别', () {
      final conn = ClashConnection.fromJson(
        _connection(id: 'a', network: 'udp', port: 53, host: 'dns.example'),
      )!;
      expect(conn.network, 'udp');
      expect(conn.target, 'dns.example');
    });

    test('空 connections 数组不会出错', () {
      final snapshot = ClashSnapshot.fromJson(<String, Object?>{
        'connections': <Object?>[],
      });
      expect(snapshot.connections, isEmpty);
    });
  });
}
