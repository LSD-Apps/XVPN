import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/app_state.dart';
import 'package:xvpn/models.dart';
import 'package:xvpn/protocols/hysteria2_conf.dart';
import 'package:xvpn/protocols/openvpn_conf.dart';
import 'package:xvpn/protocols/parsed_profile.dart';
import 'package:xvpn/protocols/protocol_adapter.dart';
import 'package:xvpn/protocols/vpn_protocol.dart';
import 'package:xvpn/protocols/wireguard_conf.dart';
import 'package:xvpn/screens/config_form.dart';
import 'package:xvpn/screens/import_conf.dart';
import 'package:xvpn/theme.dart';

/// 一份完整的 WireGuard 配置，用于「解析 → 预填 → 生成 → 再解析」往返。
const _wireGuard = '''
[Interface]
PrivateKey = aGVsbG8gd29ybGQgdGhpcyBpcyBhIGtleSB2YWx1ZQ=
Address = 10.7.0.2/32, fd00::2/128
DNS = 1.1.1.1, 8.8.8.8
MTU = 1420

[Peer]
PublicKey = cHVibGljIGtleSB2YWx1ZSBnb2VzIGhlcmUgcGFkZGVk
PresharedKey = cHNrIHZhbHVlIGdvZXMgaGVyZSBwYWRkZWQ=
Endpoint = 203.0.113.42:51821
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
''';

/// 一份带内联证书、tls-auth、加密套件与 auth-user-pass 的 OpenVPN 配置。
const _openVpn = '''
client
dev tun
proto tcp
remote vpn.example.net 443
auth-user-pass
cipher AES-256-CBC
data-ciphers AES-256-GCM:AES-128-GCM
auth SHA256
remote-cert-tls server
key-direction 1
<ca>
-----BEGIN CERTIFICATE-----
MIIBCA
-----END CERTIFICATE-----
</ca>
<cert>
-----BEGIN CERTIFICATE-----
MIIBCB
-----END CERTIFICATE-----
</cert>
<key>
-----BEGIN PRIVATE KEY-----
MIIBCK
-----END PRIVATE KEY-----
</key>
<tls-auth>
-----BEGIN OpenVPN Static key V1-----
deadbeef
-----END OpenVPN Static key V1-----
</tls-auth>
''';

/// pinSHA256 是一段合法的 32 字节 SHA-256（base64）。
const _pin = 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=';

const _hysteria2 =
    'hysteria2://secret@vpn.example.com:8443/'
    '?sni=vpn.example.com&insecure=1&obfs=salamander&obfs-password=obfspass'
    '&mport=8443-9443&hop-interval=30&pinSHA256=$_pin&up=100&down=200'
    '#%E6%B5%8B%E8%AF%95%E8%8A%82%E7%82%B9';

void main() {
  group('配置表单模型：解析往返', () {
    test('WireGuard：预填后生成的文本能解析回同样的字段', () {
      final first = VpnProtocolFactory.parse(_wireGuard, 'wg.conf');
      final model = ConfigFormModel.fromParsed(first, name: 'wg.conf');
      expect(model.protocol, VpnProtocol.wireGuard);
      expect(model.endpointHost, '203.0.113.42');
      expect(model.privateKey, isNotEmpty);

      final second =
          VpnProtocolFactory.parse(model.toConfText(), model.name)
              as WireGuardProfile;
      final a = (first as WireGuardProfile).conf;
      final b = second.conf;
      expect(b.privateKey, a.privateKey);
      expect(b.addresses, a.addresses);
      expect(b.dns, a.dns);
      expect(b.mtu, a.mtu);
      expect(b.endpointHost, a.endpointHost);
      expect(b.endpointPort, a.endpointPort);
      expect(b.primaryPeer!.publicKey, a.primaryPeer!.publicKey);
      expect(b.primaryPeer!.presharedKey, a.primaryPeer!.presharedKey);
      expect(
        b.primaryPeer!.persistentKeepalive,
        a.primaryPeer!.persistentKeepalive,
      );
    });

    test('OpenVPN：证书 / 加密套件 / 身份校验都不会在确认时丢掉', () {
      final first = VpnProtocolFactory.parse(_openVpn, 'need.ovpn');
      final model = ConfigFormModel.fromParsed(first, name: 'need.ovpn');
      expect(model.requiresCredentials, isTrue);
      expect(model.remoteCertTls, isTrue);

      final second =
          VpnProtocolFactory.parse(model.toConfText(), model.name)
              as OpenVpnProfile;
      final a = (first as OpenVpnProfile).conf;
      final b = second.conf;
      expect(b.remoteHost, a.remoteHost);
      expect(b.remotePort, a.remotePort);
      expect(b.network, a.network);
      expect(b.cipher, a.cipher);
      expect(b.dataCiphers, a.dataCiphers);
      expect(b.auth, a.auth);
      expect(b.ca, a.ca);
      expect(b.cert, a.cert);
      expect(b.key, a.key);
      expect(b.tlsAuth, a.tlsAuth);
      expect(b.keyDirection, a.keyDirection);
      expect(b.requiresServerCert, a.requiresServerCert);
      expect(b.requiresCredentials, a.requiresCredentials);
    });

    test('Hysteria2：分享链接的全部参数都保留', () {
      final first = VpnProtocolFactory.parse(_hysteria2, 'node.txt');
      final model = ConfigFormModel.fromParsed(first, name: 'node.txt');
      expect(model.protocol, VpnProtocol.hysteria2);

      final second =
          VpnProtocolFactory.parse(model.toConfText(), model.name)
              as Hysteria2Profile;
      final a = (first as Hysteria2Profile).conf;
      final b = second.conf;
      expect(b.server, a.server);
      expect(b.port, a.port);
      expect(b.auth, a.auth);
      expect(b.sni, a.sni);
      expect(b.insecure, a.insecure);
      expect(b.obfsPassword, a.obfsPassword);
      expect(b.serverPorts, a.serverPorts);
      expect(b.hopIntervalSeconds, a.hopIntervalSeconds);
      expect(b.pinSha256, a.pinSha256);
      expect(b.upMbps, a.upMbps);
      expect(b.downMbps, a.downMbps);
      expect(b.displayName, a.displayName);
    });
  });

  group('配置表单模型：手填生成', () {
    test('WireGuard：从空模型填完必填项即可解析', () {
      final model = ConfigFormModel.empty(VpnProtocol.wireGuard)
        ..name = '手填节点'
        ..privateKey = 'cHJpdmF0ZQ=='
        ..address = '10.0.0.2/32'
        ..peerPublicKey = 'cHVibGlj'
        ..endpointHost = 'vpn.example.com';
      final parsed = VpnProtocolFactory.parse(model.toConfText(), model.name)
          as WireGuardProfile;
      expect(parsed.conf.endpointHost, 'vpn.example.com');
      expect(parsed.conf.endpointPort, 51820, reason: '空端口应回落到 WG 默认值');
    });

    test('OpenVPN：手填服务器与证书即可解析', () {
      final model = ConfigFormModel.empty(VpnProtocol.openVpn)
        ..name = '手填 ovpn'
        ..remoteHost = 'vpn.example.com'
        ..transport = 'tcp'
        ..requiresCredentials = true
        ..ca = 'CERT'
        ..cert = 'CLIENTCERT'
        ..clientKey = 'PRIVATEKEY';
      final parsed = VpnProtocolFactory.parse(model.toConfText(), model.name)
          as OpenVpnProfile;
      expect(parsed.conf.remoteHost, 'vpn.example.com');
      expect(parsed.conf.remotePort, 443, reason: 'TCP 空端口应回落到 443');
      expect(parsed.conf.requiresCredentials, isTrue);
      expect(parsed.conf.hasInlineCredentials, isTrue);
    });

    test('Hysteria2：生成的是可解析的 hysteria2:// 链接', () {
      final model = ConfigFormModel.empty(VpnProtocol.hysteria2)
        ..name = '手填 hy2'
        ..server = 'vpn.example.com'
        ..hysteriaAuth = 'user:pass'
        ..obfsPassword = 'obfs';
      final text = model.toConfText();
      expect(text, startsWith('hysteria2://'));
      final parsed = VpnProtocolFactory.parse(text, model.name)
          as Hysteria2Profile;
      expect(parsed.conf.server, 'vpn.example.com');
      expect(parsed.conf.port, 443);
      expect(parsed.conf.auth, 'user:pass');
      expect(parsed.conf.obfsPassword, 'obfs');
    });
  });

  group('配置表单模型：校验错误', () {
    test('空 WireGuard 表单生成时给出可读中文错误', () {
      final model = ConfigFormModel.empty(VpnProtocol.wireGuard);
      expect(
        () => model.toConfText(),
        throwsA(isA<VpnConfigException>()),
      );
    });

    test('空 OpenVPN 表单生成时给出可读中文错误', () {
      final model = ConfigFormModel.empty(VpnProtocol.openVpn);
      expect(
        () => model.toConfText(),
        throwsA(isA<VpnConfigException>()),
      );
    });

    test('空 Hysteria2 表单生成时给出可读中文错误', () {
      final model = ConfigFormModel.empty(VpnProtocol.hysteria2);
      expect(
        () => model.toConfText(),
        throwsA(isA<VpnConfigException>()),
      );
    });

    test('端口超出范围时拒绝生成', () {
      final model = ConfigFormModel.empty(VpnProtocol.hysteria2)
        ..server = 'vpn.example.com'
        ..hysteriaAuth = 'secret'
        ..port = '70000';
      expect(
        () => model.toConfText(),
        throwsA(isA<VpnConfigException>()),
      );
    });

    test('OpenVPN 只填证书不填私钥时拒绝生成', () {
      final model = ConfigFormModel.empty(VpnProtocol.openVpn)
        ..remoteHost = 'vpn.example.com'
        ..cert = 'CLIENTCERT';
      expect(
        () => model.toConfText(),
        throwsA(isA<VpnConfigException>()),
      );
    });

    test('账号密码只填一半时不作为凭据下发', () {
      final model = ConfigFormModel.empty(VpnProtocol.openVpn)
        ..username = 'alice';
      expect(model.toCredentialPair(), isNull);

      model.password = 'secret';
      expect(model.toCredentialPair(), (username: 'alice', password: 'secret'));
    });
  });

  group('配置表单界面', () {
    AppState newState() {
      final state = AppState();
      state.updateSettings(const AppSettings(autoConnectOnImport: false));
      addTearDown(state.dispose);
      return state;
    }

    Future<void> pumpEntry(WidgetTester tester, Widget entry) async {
      tester.view.physicalSize = const Size(1100, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildXvTheme(XvPalette.dark),
          home: Scaffold(body: Center(child: entry)),
        ),
      );
    }

    testWidgets('手动填写入口打开表单并添加一份配置', (WidgetTester tester) async {
      final state = newState();
      await pumpEntry(
        tester,
        Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => startManualConfigForm(context, state),
            child: const Text('手动填写'),
          ),
        ),
      );

      await tester.tap(find.text('手动填写'));
      await tester.pumpAndSettle();
      expect(find.text('手动添加配置'), findsOneWidget);

      await tester.enterText(find.byKey(configFieldKey('name')), '手填节点');
      await tester.enterText(
        find.byKey(configFieldKey('wg.privateKey')),
        'cHJpdmF0ZQ==',
      );
      await tester.enterText(
        find.byKey(configFieldKey('wg.address')),
        '10.0.0.2/32',
      );
      await tester.enterText(
        find.byKey(configFieldKey('wg.peerPublicKey')),
        'cHVibGlj',
      );
      await tester.enterText(
        find.byKey(configFieldKey('wg.endpointHost')),
        'vpn.example.com',
      );
      await tester.tap(find.text('添加'));
      await tester.pumpAndSettle();

      expect(find.text('手动添加配置'), findsNothing, reason: '添加成功后表单应关闭');
      expect(state.profiles, hasLength(1));
      expect(state.profiles.single.name, '手填节点');
      expect(state.profiles.single.protocolType, VpnProtocol.wireGuard);
    });

    testWidgets('手填表单在必填项为空时就地报错，不关闭', (WidgetTester tester) async {
      final state = newState();
      await pumpEntry(
        tester,
        Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => startManualConfigForm(context, state),
            child: const Text('手动填写'),
          ),
        ),
      );

      await tester.tap(find.text('手动填写'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加'));
      await tester.pumpAndSettle();

      expect(find.text('手动添加配置'), findsOneWidget, reason: '校验失败不该关闭表单');
      expect(
        find.textContaining('这不是一个完整的 WireGuard 配置'),
        findsOneWidget,
      );
      expect(state.profiles, isEmpty);
    });

    testWidgets('选中配置文件后先进入确认表单，字段已预填', (WidgetTester tester) async {
      final state = newState();
      await pumpEntry(
        tester,
        Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => reviewAndImportConf(
              context,
              state,
              text: _wireGuard,
              fileName: 'wg.conf',
            ),
            child: const Text('导入'),
          ),
        ),
      );

      await tester.tap(find.text('导入'));
      await tester.pumpAndSettle();

      expect(find.text('确认并添加配置'), findsOneWidget);
      // 预填：值来自解析结果，而不是空白表单。
      final host = tester.widget<TextField>(
        find.byKey(configFieldKey('wg.endpointHost')),
      );
      expect(host.controller?.text, '203.0.113.42');
      final port = tester.widget<TextField>(
        find.byKey(configFieldKey('wg.endpointPort')),
      );
      expect(port.controller?.text, '51821');

      await tester.tap(find.text('添加'));
      await tester.pumpAndSettle();

      expect(state.profiles, hasLength(1));
      expect(state.profiles.single.name, 'wg.conf');
      expect(state.profiles.single.protocolType, VpnProtocol.wireGuard);
    });

    testWidgets('确认表单里选「取消」不会导入任何配置', (WidgetTester tester) async {
      final state = newState();
      await pumpEntry(
        tester,
        Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () => reviewAndImportConf(
              context,
              state,
              text: _wireGuard,
              fileName: 'wg.conf',
            ),
            child: const Text('导入'),
          ),
        ),
      );

      await tester.tap(find.text('导入'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(state.profiles, isEmpty);
    });
  });
}
