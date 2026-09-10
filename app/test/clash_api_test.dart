import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/clash_api.dart';

/// 真实的 `/connections` 响应结构（取自实际内核返回）。
const _snapshot = '''
{
  "downloadTotal": 109756,
  "uploadTotal": 9004,
  "connections": [
    {
      "id": "abc-1",
      "metadata": {"host": "www.google.com", "destinationIP": "142.250.66.78", "destinationPort": "443"},
      "chains": ["vpn"],
      "rule": "final",
      "rulePayload": ""
    },
    {
      "id": "abc-2",
      "metadata": {"host": "www.baidu.com", "destinationIP": "183.2.172.177", "destinationPort": "443"},
      "chains": ["direct"],
      "rule": "RuleSet",
      "rulePayload": "geosite-cn"
    },
    {
      "id": "abc-3",
      "metadata": {"destinationIP": "192.168.1.1", "destinationPort": "53"},
      "chains": ["direct"],
      "rule": "IpIsPrivate",
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
    });

    test('区分代理与直连，并还原命中规则', () {
      final snapshot = ClashSnapshot.parse(_snapshot)!;
      final google = snapshot.connections.firstWhere((c) => c.target == 'www.google.com');
      expect(google.proxied, isTrue);
      expect(google.outbound, 'vpn');
      // final 规则展示为「默认规则」，而不是把内核术语丢给用户
      expect(google.rule, '默认规则');

      final baidu = snapshot.connections.firstWhere((c) => c.target == 'www.baidu.com');
      expect(baidu.proxied, isFalse);
      expect(baidu.outbound, 'direct');
      expect(baidu.rule, 'geosite-cn');
    });

    test('没有域名时用 IP:端口 作为目标', () {
      final snapshot = ClashSnapshot.parse(_snapshot)!;
      final local = snapshot.connections.firstWhere((c) => c.target.startsWith('192.168'));
      expect(local.target, '192.168.1.1:53');
      expect(local.rule, '局域网地址');
    });

    test('非法或空内容返回 null 而不是抛异常', () {
      expect(ClashSnapshot.parse(''), isNull);
      expect(ClashSnapshot.parse('<html>502 Bad Gateway</html>'), isNull);
      // connections 字段类型不对时，整份快照视为无效而返回 null。
      // 这比「当成空列表」更好：空列表会被误读成「当前没有连接」。
      expect(ClashSnapshot.parse('{"connections": "not-a-list"}'), isNull);
    });

    test('缺少 id 的连接被跳过', () {
      final snapshot = ClashSnapshot.parse('{"connections":[{"metadata":{"host":"a.com"}}]}')!;
      expect(snapshot.connections, isEmpty);
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
      final sample = rate.sample(t0.add(const Duration(seconds: 2)), 5096, 1524)!;
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
      expect(rate.sample(t0.add(const Duration(seconds: 2)), 3000, 1500), isNull);
    });
  });
}
