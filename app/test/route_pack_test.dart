import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/auto_route.dart';
import 'package:xvpn/core/cn_ip_index.dart';
import 'package:xvpn/core/node_region.dart';
import 'package:xvpn/core/route_pack.dart';
import 'package:xvpn/protocols/protocol_adapter.dart';

void main() {
  group('规则包', () {
    test('导出不含预置，导入变成手工规则', () {
      final table = AutoRouteTable();
      table.setUserRule('keep.example', RoutePreference.forceDirect);
      table.recordDirectFailure('learned.example', reason: '超时');
      table.recordDirectFailure('learned.example', reason: '超时');
      table.recordDirectFailure('learned.example', reason: '超时');
      expect(
        table.match('learned.example')?.preference,
        RoutePreference.forceProxy,
      );

      final pack = exportRoutePack(table);
      expect(pack.direct, contains('keep.example'));
      expect(pack.proxy, contains('learned.example'));

      final other = AutoRouteTable();
      expect(importRoutePack(other, pack), 2);
      expect(other.match('keep.example')?.source, RouteRuleSource.user);
      expect(other.match('learned.example')?.source, RouteRuleSource.user);
      expect(
        other.match('learned.example')?.preference,
        RoutePreference.forceProxy,
      );
    });

    test('已有手工规则的域名不被覆盖', () {
      final table = AutoRouteTable()
        ..setUserRule('keep.example', RoutePreference.forceProxy);
      final added = importRoutePack(
        table,
        const RoutePack(
          direct: <String>['keep.example'],
          proxy: <String>[],
        ),
      );
      expect(added, 0);
      expect(
        table.match('keep.example')?.preference,
        RoutePreference.forceProxy,
      );
    });

    test('纯域名清单当成直连包', () {
      final pack = parseRoutePack('# 备注\nFoo.Example\nbar.example\n');
      expect(pack.direct, <String>['foo.example', 'bar.example']);
      expect(pack.proxy, isEmpty);
    });
  });

  group('节点地区', () {
    test('从 host:port 取出主机', () {
      expect(serverHostOf('ss.example.net:8388'), 'ss.example.net');
      expect(serverHostOf('[2001:db8::1]:443'), '2001:db8::1');
    });

    test('IP 字面量按索引判定，主机名保持未知', () {
      final parsed = VpnProtocolFactory.parse(
        'ss://aes-256-gcm:testpassword@8.8.8.8:8388#x',
        'x.txt',
      );
      expect(
        classifyNodeRegion(CnIpIndex.empty, parsed),
        AddressRegion.unknown,
        reason: '空索引不能把境外地址判成境外',
      );
      expect(serverHostOf(parsed.serverDisplay), '8.8.8.8');
    });
  });
}
