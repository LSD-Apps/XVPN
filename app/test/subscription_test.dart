import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/app_state.dart';
import 'package:xvpn/core/store.dart';
import 'package:xvpn/models.dart';
import 'package:xvpn/protocols/protocol_adapter.dart';
import 'package:xvpn/protocols/subscription.dart';
import 'package:xvpn/protocols/vpn_protocol.dart';

const _ss =
    'ss://aes-256-gcm:testpassword@ss.example.net:8388#ss-example';
const _vless =
    'vless://aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee@vless.example.net:443'
    '?type=tcp&security=tls&sni=vless.example.net#vless-example';
const _trojan =
    'trojan://p%40ss%2Fword@trojan.example.net:443?security=tls'
    '&sni=trojan.example.net#trojan-example';

void main() {
  group('订阅 URL 识别', () {
    test('https 整段是订阅地址', () {
      expect(
        looksLikeSubscriptionUrl('https://sub.example.net/token'),
        isTrue,
      );
    });

    test('分享链接不是订阅地址', () {
      expect(looksLikeSubscriptionUrl(_ss), isFalse);
    });

    test('多行正文不是订阅地址', () {
      expect(looksLikeSubscriptionUrl('$_ss\n$_vless'), isFalse);
    });
  });

  group('分享链接列表', () {
    test('一行一条，备注当名字', () {
      final doc = parseSubscriptionBody('$_ss\n$_vless\n# 注释\n$_trojan');
      expect(doc, isNotNull);
      expect(doc!.nodes, hasLength(3));
      expect(doc.nodes.map((SubscriptionNode n) => n.name), <String>[
        'ss-example',
        'vless-example',
        'trojan-example',
      ]);
    });

    test('整段 Base64 也能拆开', () {
      final raw = '$_ss\n$_vless';
      final encoded = base64.encode(utf8.encode(raw));
      final doc = parseSubscriptionBody(encoded);
      expect(doc, isNotNull);
      expect(doc!.nodes, hasLength(2));
    });

    test('工厂能解析拆出来的每一条', () {
      final raw = parseSubscriptionBody('$_ss\n$_vless\n$_trojan')!;
      final doc = materialize(raw);
      expect(doc.nodes, hasLength(3));
      expect(doc.skipped, isEmpty);
      expect(
        VpnProtocolFactory.parse(doc.nodes[0].text, 'a.txt').protocol,
        VpnProtocol.shadowsocks,
      );
      expect(
        VpnProtocolFactory.parse(doc.nodes[1].text, 'b.txt').protocol,
        VpnProtocol.vless,
      );
      expect(
        VpnProtocolFactory.parse(doc.nodes[2].text, 'c.txt').protocol,
        VpnProtocol.trojan,
      );
    });
  });

  group('sing-box JSON', () {
    test('多个出站各自成节点，direct 被跳过', () {
      const json = '''
{
  "outbounds": [
    {"type": "direct", "tag": "direct"},
    {
      "type": "shadowsocks",
      "tag": "ss-1",
      "server": "ss.example.net",
      "server_port": 8388,
      "method": "aes-256-gcm",
      "password": "testpassword"
    },
    {
      "type": "trojan",
      "tag": "tj-1",
      "server": "trojan.example.net",
      "server_port": 443,
      "password": "testpassword",
      "tls": {"enabled": true, "server_name": "trojan.example.net"}
    }
  ]
}
''';
      final doc = parseSubscriptionBody(json);
      expect(doc, isNotNull);
      expect(doc!.nodes.map((SubscriptionNode n) => n.name).toList(), <String>[
        'ss-1',
        'tj-1',
      ]);
      final ready = materialize(doc);
      expect(ready.nodes, hasLength(2));
      expect(ready.skipped, isEmpty);
    });
  });

  group('Clash YAML', () {
    test('缩进列表映射到已支持的协议', () {
      const yaml = '''
proxies:
  - name: clash-ss
    type: ss
    server: ss.example.net
    port: 8388
    cipher: aes-256-gcm
    password: testpassword
  - name: clash-trojan
    type: trojan
    server: trojan.example.net
    port: 443
    password: testpassword
    sni: trojan.example.net
    skip-cert-verify: true
  - name: skip-me
    type: ssr
    server: ssr.example.net
    port: 1
    password: x
''';
      final doc = parseSubscriptionBody(yaml);
      expect(doc, isNotNull);
      expect(doc!.nodes, hasLength(2));
      expect(doc.skipped.single, contains('ssr'));
      final ready = materialize(doc);
      expect(ready.nodes, hasLength(2), reason: ready.skipped.join('; '));
      expect(
        VpnProtocolFactory.parse(ready.nodes[0].text, 'a.json').protocol,
        VpnProtocol.shadowsocks,
      );
      expect(
        VpnProtocolFactory.parse(ready.nodes[1].text, 'b.json').protocol,
        VpnProtocol.trojan,
      );
    });

    test('flow 写法 {name: ..., type: ss, ...}', () {
      const yaml = '''
proxies:
  - { name: "flow-ss", type: ss, server: ss.example.net, port: 8388, cipher: aes-256-gcm, password: testpassword }
  - { name: "flow-hy2", type: hysteria2, server: hy2.example.net, port: 443, password: testpassword, sni: hy2.example.net, skip-cert-verify: true }
''';
      final doc = parseSubscriptionBody(yaml);
      expect(doc, isNotNull);
      expect(doc!.nodes, hasLength(2));
      final ready = materialize(doc);
      expect(ready.skipped, isEmpty, reason: ready.skipped.join('; '));
      expect(
        VpnProtocolFactory.parse(ready.nodes[1].text, 'h.json').protocol,
        VpnProtocol.hysteria2,
      );
    });
  });

  group('写入 AppState', () {
    test('多节点导入后可切换，刷新替换同一订阅', () async {
      final state = AppState(
        subscriptionFetcher: (String url) async {
          expect(url, 'https://sub.example.net/token');
          return SubscriptionFetchResult(
            body: '$_ss\n$_vless',
            userinfo: 'upload=1; download=2; total=3',
          );
        },
      );
      addTearDown(state.dispose);

      final fromFile = state.importSubscription(
        document: parseSubscriptionBody('$_ss\n$_trojan')!,
        name: 'file-sub',
      );
      expect(fromFile.imported, 2);
      expect(state.profiles, hasLength(2));
      expect(state.subscriptions, hasLength(1));
      final fileSub = state.subscriptions.single;
      expect(fileSub.userinfo, isNull, reason: '文件导入没有响应头可用');

      final fromUrl = await state.importSubscriptionFromUrl(
        'https://sub.example.net/token',
      );
      expect(fromUrl.imported, 2);
      expect(state.subscriptions, hasLength(2));
      final urlSub = state.subscriptions.last;
      expect(urlSub.userinfo, 'upload=1; download=2; total=3');
      // `ss` 同时出现在两份来源里：配置按「协议 + 正文」去重后仍是一条，
      // 但归属是集合——两边都算它，不是后者把前者抢走。
      expect(state.profiles, hasLength(3));
      final ss = state.profiles.firstWhere(
        (VpnProfile p) => p.protocolType == VpnProtocol.shadowsocks,
      );
      expect(ss.subscriptionIds, <String>{fileSub.id, urlSub.id});
      expect(
        state.profiles
            .where((VpnProfile p) => p.subscriptionIds.contains(urlSub.id)),
        hasLength(2),
      );

      final refreshed = await state.refreshSubscription(urlSub.id);
      expect(refreshed.imported, 2);
      expect(state.profiles, hasLength(3), reason: '刷新不该复制出第二份同样的节点');
      expect(
        state.profiles
            .where((VpnProfile p) => p.subscriptionIds.contains(urlSub.id)),
        hasLength(2),
      );
      // 另一份来源的归属没有被刷新动到：它仍管着自己的节点，也仍看得到共享的
      // 那一个——否则「刷新一份订阅会悄悄删掉另一份的节点」。
      expect(
        state.profiles
            .where((VpnProfile p) => p.subscriptionIds.contains(fileSub.id)),
        hasLength(2),
      );
    });

    test('同名同内容的文件再导入是替换，变了内容则并存', () {
      final state = AppState();
      addTearDown(state.dispose);

      state.importSubscription(
        document: parseSubscriptionBody('$_ss\n$_trojan')!,
        name: 'sub',
      );
      final first = state.subscriptions.single.id;
      expect(state.profiles, hasLength(2));

      // 同一份文件再导入一次：替换，节点数不变。
      state.importSubscription(
        document: parseSubscriptionBody('$_ss\n$_trojan')!,
        name: 'sub',
      );
      expect(state.subscriptions, hasLength(1));
      expect(state.subscriptions.single.id, first);
      expect(state.profiles, hasLength(2));

      // 首节点变了（用户换了一份清单）：当成另一份来源并存。
      // 宁可多一条来源，也不要把用户手里两份清单里的节点误删。
      state.importSubscription(
        document: parseSubscriptionBody('$_vless\n$_trojan')!,
        name: 'sub',
      );
      expect(state.subscriptions, hasLength(2));
      expect(state.profiles, hasLength(3), reason: 'trojan 是两份来源共享的节点');
    });

    test('删掉共享节点时只删除不再被任何来源引用的订阅记录', () async {
      final state = AppState(
        subscriptionFetcher: (String url) async => SubscriptionFetchResult(
          body: '$_ss\n$_vless',
        ),
      );
      addTearDown(state.dispose);

      state.importSubscription(
        document: parseSubscriptionBody('$_ss\n$_trojan')!,
        name: 'file-sub',
      );
      await state.importSubscriptionFromUrl('https://sub.example.net/token');
      final shared = state.profiles.firstWhere(
        (VpnProfile p) => p.protocolType == VpnProtocol.shadowsocks,
      );

      state.removeProfile(shared.id);

      expect(
        state.subscriptions,
        hasLength(2),
        reason: '共享节点被删不等于订阅被删：另一份来源下还挂着它的其它节点',
      );
      expect(
        state.profiles
            .where((VpnProfile p) => p.protocolType == VpnProtocol.vless),
        hasLength(1),
      );
    });
  });

  group('持久化', () {
    late Directory dir;
    late AppStore store;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('xvpn-sub-store');
      store = AppStore(dir);
    });
    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('订阅来源与归属跨重启保留', () async {
      final first = AppState(
        store: store,
        subscriptionFetcher: (String url) async =>
            SubscriptionFetchResult(body: '$_ss\n$_vless'),
      );
      first.importSubscription(
        document: parseSubscriptionBody('$_ss\n$_trojan')!,
        name: 'file-sub',
      );
      await first.importSubscriptionFromUrl('https://sub.example.net/token');
      final subIds = first.subscriptions
          .map((ProfileSubscription s) => s.id)
          .toSet();
      first.dispose();

      final second = AppState(store: store);
      addTearDown(second.dispose);
      expect(second.subscriptions, hasLength(2));
      expect(
        second.subscriptions.map((ProfileSubscription s) => s.id).toSet(),
        subIds,
        reason: '来源记录丢了，「刷新」按钮就会凭空消失',
      );
      final ss = second.profiles.firstWhere(
        (VpnProfile p) => p.protocolType == VpnProtocol.shadowsocks,
      );
      expect(
        ss.subscriptionIds,
        hasLength(2),
        reason: '归属是集合，跨重启必须两份都在——只存一份等于悄悄改写了归属',
      );
    });

    test('旧存档的单值归属仍能恢复', () {
      store.save(<String, Object?>{
        'profiles': <Object?>[
          <String, Object?>{
            'name': 'ss.txt',
            'text': _ss,
            'subscriptionId': 'legacy-sub',
          },
        ],
        'subscriptions': <Object?>[
          <String, Object?>{
            'id': 'legacy-sub',
            'name': 'legacy',
            'url': 'https://sub.example.net/old',
          },
        ],
      });

      final state = AppState(store: store);
      addTearDown(state.dispose);
      expect(
        state.profiles.single.subscriptionIds,
        <String>{'legacy-sub'},
        reason: '字段从单值改成集合，旧存档继续可用而不是让用户重新导入',
      );
      expect(
        state.refreshableSubscriptionOf(state.profiles.single),
        isNotNull,
      );
    });
  });
}
