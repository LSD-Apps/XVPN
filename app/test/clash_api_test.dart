import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/clash_api.dart';
import 'package:xvpn/core/record_buffer.dart';

/// 真实的 `/connections` 响应结构。
///
/// 字段与取值对着 sing-box v1.14.0 的
/// `experimental/clashapi/connections.go` 校正过。此前这份样例是按「Clash 原版」
/// 的习惯写的（`rule` 是规则名、`rulePayload` 带内容），而 sing-box 的实际行为
/// 完全不同：
///
///   * `rule` 是 `fmt.Sprintf("%s => %s", rule, action)` 拼出来的**描述文本**；
///   * `rulePayload` **恒为空字符串**。
///
/// 结果是界面上「命中规则」这一列一直在显示 `rule_set=[geosite-cn geoip-cn]
/// => route` 这种内核术语，而 `switch(rule) { case 'RuleSet': ... }` 那些分支
/// 从来没有命中过。
const _snapshot = '''
{
  "downloadTotal": 109756,
  "uploadTotal": 9004,
  "memory": 20480,
  "connections": [
    {
      "id": "abc-1",
      "metadata": {
        "network": "tcp", "host": "www.google.com",
        "destinationIP": "198.51.100.78", "destinationPort": "443"
      },
      "upload": 9004, "download": 90000,
      "start": "2026-02-14T10:20:30Z",
      "chains": ["vpn"],
      "rule": "final",
      "rulePayload": ""
    },
    {
      "id": "abc-2",
      "metadata": {
        "network": "tcp", "host": "www.baidu.com",
        "destinationIP": "192.0.2.177", "destinationPort": "443"
      },
      "upload": 100, "download": 5000,
      "start": "2026-02-14T10:20:31Z",
      "chains": ["direct"],
      "rule": "rule_set=[geosite-cn geoip-cn] => route",
      "rulePayload": ""
    },
    {
      "id": "abc-3",
      "metadata": {
        "network": "udp",
        "destinationIP": "192.168.1.1", "destinationPort": "53"
      },
      "upload": 0, "download": 200,
      "start": "2026-02-14T10:20:32Z",
      "chains": ["direct"],
      "rule": "ip_is_private=true => route",
      "rulePayload": ""
    }
  ]
}
''';

void main() {
  group('ClashSnapshot.parse', () {
    test('解析连接列表与累计流量', () {
      final snapshot = ClashSnapshot.parse(_snapshot)!;
      expect(snapshot.downloadTotal, 109756);
      expect(snapshot.uploadTotal, 9004);
      expect(snapshot.totalBytes, 118760);
      expect(snapshot.connections, hasLength(3));
      expect(snapshot.memory, 20480, reason: '内核内存用量用于自查数据量带来的压力');
    });

    test('区分代理与直连，并把命中规则还原成人话', () {
      final snapshot = ClashSnapshot.parse(_snapshot)!;
      final google = snapshot.connections.firstWhere(
        (c) => c.target == 'www.google.com',
      );
      expect(google.proxied, isTrue);
      expect(google.outbound, 'vpn');
      // final 规则展示为「默认规则」，而不是把内核术语丢给用户。
      expect(google.rule, '默认规则');

      final baidu = snapshot.connections.firstWhere(
        (c) => c.target == 'www.baidu.com',
      );
      expect(baidu.proxied, isFalse);
      expect(baidu.outbound, 'direct');
      expect(
        baidu.rule,
        'geosite-cn + geoip-cn',
        reason: '内核给的是一整句描述，界面需要归一化，不能原样显示',
      );
    });

    test('没有域名时用 IP:端口 作为目标，并识别局域网规则', () {
      final snapshot = ClashSnapshot.parse(_snapshot)!;
      final local = snapshot.connections.firstWhere(
        (c) => c.target.startsWith('192.168'),
      );
      expect(local.target, '192.168.1.1:53');
      expect(local.rule, '局域网地址');
      expect(local.network, 'udp');
    });

    test('按连接统计字节数，这是分流占比的数据来源', () {
      final snapshot = ClashSnapshot.parse(_snapshot)!;
      final google = snapshot.connections.firstWhere(
        (c) => c.target == 'www.google.com',
      );
      expect(google.upload, 9004);
      expect(google.download, 90000);
      expect(google.totalBytes, 99004);
      expect(google.startedAt, isNotNull);
    });

    test('非法或空内容返回 null 而不是抛异常', () {
      expect(ClashSnapshot.parse(''), isNull);
      expect(ClashSnapshot.parse('<html>502 Bad Gateway</html>'), isNull);
      // connections 缺失或类型不对时按空列表处理，累计流量仍然可用——
      // 内核正在退出时经常只来得及回一个残缺的响应，此时流量数字仍应更新。
      final degraded = ClashSnapshot.parse('{"connections": "not-a-list"}')!;
      expect(degraded.connections, isEmpty);
    });

    test('缺少 id 的连接被跳过', () {
      final snapshot = ClashSnapshot.parse(
        '{"connections":[{"metadata":{"host":"a.com"}}]}',
      )!;
      expect(snapshot.connections, isEmpty);
    });

    test('只取总量的快速路径与完整解析结果一致', () {
      final snapshot = ClashSnapshot.parse(_snapshot)!;
      final json = <String, Object?>{
        'downloadTotal': snapshot.downloadTotal,
        'uploadTotal': snapshot.uploadTotal,
        'memory': snapshot.memory,
      };
      final totals = ClashSnapshot.totalsOf(json);
      expect(totals.downloadTotal, snapshot.downloadTotal);
      expect(totals.uploadTotal, snapshot.uploadTotal);
      expect(totals.memory, snapshot.memory);
    });
  });

  group('ClashSnapshot.newSince', () {
    test('只返回未见过的连接', () {
      final snapshot = ClashSnapshot.parse(_snapshot)!;
      final seen = <String>{'abc-1'};
      final fresh = snapshot.newSince(seen);
      expect(fresh.map((c) => c.id), <String>['abc-2', 'abc-3']);
    });

    test('limit 限制单次上报数量，避免首次连接刷屏', () {
      final snapshot = ClashSnapshot.parse(_snapshot)!;
      expect(snapshot.newSince(<String>{}, limit: 2), hasLength(2));
    });
  });

  group('ClashSnapshot.pullNew', () {
    /// 直接解析原始 JSON 文本——`pullNew` 在真实链路里拿到的就是已解码的 map。
    Map<String, Object?> raw() =>
        (jsonDecode(_snapshot) as Map).cast<String, Object?>();

    test('提取新连接并把它们登记进集合', () {
      final seen = BoundedIdSet(16);
      final first = ClashSnapshot.pullNew(raw(), seen);
      expect(first.map((ClashConnection c) => c.id), <String>[
        'abc-1',
        'abc-2',
        'abc-3',
      ]);
      expect(seen.length, 3);

      // 再来一轮：一条都不该重复。
      final second = ClashSnapshot.pullNew(raw(), seen);
      expect(second, isEmpty);
    });

    test('limit 之外的连接留给下一轮，不会丢失', () {
      final seen = BoundedIdSet(16);
      final first = ClashSnapshot.pullNew(raw(), seen, limit: 2);
      expect(first.map((ClashConnection c) => c.id), <String>[
        'abc-1',
        'abc-2',
      ]);
      final second = ClashSnapshot.pullNew(raw(), seen, limit: 2);
      expect(second.map((ClashConnection c) => c.id), <String>['abc-3']);
    });
  });

  group('RateCalculator', () {
    test('首次采样只建立基准，返回 null', () {
      final rate = RateCalculator();
      expect(rate.sample(DateTime(2026, 1, 1, 0, 0, 0), 1000, 500), isNull);
    });

    test('第二次采样按时间差算出速率', () {
      final rate = RateCalculator();
      final t0 = DateTime(2026, 1, 1, 0, 0, 0);
      rate.sample(t0, 1000, 500);
      // 2 秒后下行多了 4096 字节、上行多了 1024 字节
      final sample = rate.sample(
        t0.add(const Duration(seconds: 2)),
        5096,
        1524,
      )!;
      expect(sample.downBps, closeTo(2048, 0.01));
      expect(sample.upBps, closeTo(512, 0.01));
      expect(sample.totalBytes, 6620);
    });

    test('计数器归零（内核重启）时按 0 处理，不显示负数', () {
      final rate = RateCalculator();
      final t0 = DateTime(2026, 1, 1, 0, 0, 0);
      rate.sample(t0, 100000, 50000);
      final sample = rate.sample(t0.add(const Duration(seconds: 1)), 10, 5)!;
      expect(sample.downBps, 0);
      expect(sample.upBps, 0);
    });

    test('reset 之后重新建立基准', () {
      final rate = RateCalculator();
      final t0 = DateTime(2026, 1, 1, 0, 0, 0);
      rate.sample(t0, 1000, 500);
      rate.sample(t0.add(const Duration(seconds: 1)), 2000, 1000);
      rate.reset();
      expect(
        rate.sample(t0.add(const Duration(seconds: 2)), 3000, 1500),
        isNull,
      );
    });
  });
}
