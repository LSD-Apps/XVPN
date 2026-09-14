import 'package:flutter/foundation.dart';
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

    test('OpenVPN：tun-mtu / keepalive / mssfix 确认导入后仍保留', () {
      const rich = '''
client
dev tun
proto udp
remote ovpn.example.net 1194
tun-mtu 1400
keepalive 10 60
mssfix 1360
cipher AES-256-GCM
auth SHA256
<ca>
-----BEGIN CERTIFICATE-----
MIIBCA
-----END CERTIFICATE-----
</ca>
''';
      final first = VpnProtocolFactory.parse(rich, 'rich.ovpn') as OpenVpnProfile;
      final model = ConfigFormModel.fromParsed(first, name: 'rich.ovpn');
      expect(model.tunMtu, '1400');
      expect(model.pingInterval, '10');
      expect(model.pingRestart, '60');
      expect(model.mssFix, '1360');
      expect(model.notices, isEmpty, reason: '已声明 keepalive 时不应再提示缺保活');

      final second =
          VpnProtocolFactory.parse(model.toConfText(), model.name)
              as OpenVpnProfile;
      expect(second.conf.tunMtu, 1400);
      expect(second.conf.pingInterval, 10);
      expect(second.conf.pingRestart, 60);
      expect(second.conf.mssFix, 1360);
    });

    test('OpenVPN：UDP 且无保活时附带 info notice', () {
      final profile = VpnProtocolFactory.parse(_openVpn.replaceAll('proto tcp', 'proto udp')
          .replaceAll('remote vpn.example.net 443', 'remote vpn.example.net 1194'), 'udp.ovpn')
          as OpenVpnProfile;
      expect(profile.notices, isNotEmpty);
      expect(profile.notices.first.kind, ProfileNoticeKind.info);
      final model = ConfigFormModel.fromParsed(profile, name: 'udp.ovpn');
      expect(model.notices, profile.notices);
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
      expect(model.notices, isEmpty, reason: '已声明带宽时不应再提示');
    });

    test('Hysteria2：未声明带宽时附带 info notice', () {
      const bare =
          'hysteria2://secret@vpn.example.com:8443/?sni=vpn.example.com';
      final profile =
          VpnProtocolFactory.parse(bare, 'bare.txt') as Hysteria2Profile;
      expect(profile.notices.single.kind, ProfileNoticeKind.info);
      expect(profile.notices.single.message, contains('带宽'));
      final model = ConfigFormModel.fromParsed(profile, name: 'bare.txt');
      expect(model.notices, profile.notices);
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

  // 这一组锁住「滚动条压住表单字段」这个缺陷。
  //
  // 测试环境默认按 Android 处理（见 `defaultTargetPlatform` 的文档），而只有
  // 桌面端的 [MaterialScrollBehavior] 会给纵向滚动视图挂滚动条。因此必须显式
  // 覆盖平台，否则这些断言在 Android 语义下根本遇不到滚动条、也就抓不到回归。
  group('配置表单界面：滚动条不遮挡字段', () {
    /// 在指定视口与桌面平台下打开「手动添加配置」表单。
    Future<AppState> pumpManual(WidgetTester tester, Size size) async {
      final state = AppState();
      state.updateSettings(const AppSettings(autoConnectOnImport: false));
      addTearDown(state.dispose);

      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildXvTheme(XvPalette.dark),
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => TextButton(
                onPressed: () => startManualConfigForm(context, state),
                child: const Text('手动填写'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('手动填写'));
      await tester.pumpAndSettle();
      return state;
    }

    /// 主题里滚动条的厚度（[ScrollbarThemeData.thickness]）。
    double scrollbarThickness(WidgetTester tester) {
      final theme = ScrollbarTheme.of(
        tester.element(find.byType(SingleChildScrollView)),
      );
      return theme.thickness?.resolve(<WidgetState>{}) ?? 0;
    }

    /// 滚动内容右侧为滚动条预留的间距。
    ///
    /// 桌面端滚动条浮在内容之上、不占布局宽度，因此这个间距就是字段让开
    /// 滚动条的唯一来源——它必须不小于滚动条厚度。
    double contentTrailingInset(WidgetTester tester) {
      final scrollView = tester.widget<SingleChildScrollView>(
        find.byType(SingleChildScrollView),
      );
      final child = scrollView.child;
      expect(child, isA<Padding>(), reason: '滚动内容应带有让开滚动条的内边距');
      return (child! as Padding).padding.resolve(TextDirection.ltr).right;
    }

    /// 某个字段最外层输入框（带描边的那层容器）的矩形。
    ///
    /// 这层容器横向铺满滚动内容，因此它的右边缘就是滚动内容的右边缘；用它
    /// 相对滚动视口右边缘的距离，可以直接判断字段有没有落进滚动条的槽位。
    Rect fieldBox(WidgetTester tester, String field) {
      final Finder box = find
          .ancestor(
            of: find.byKey(configFieldKey(field)),
            matching: find.byWidgetPredicate(
              (Widget w) =>
                  w is Container &&
                  w.decoration is BoxDecoration &&
                  (w.decoration! as BoxDecoration).border != null,
            ),
          )
          .first;
      return tester.getRect(box);
    }

    testWidgets('矮桌面窗口（1200×560）：内容让开滚动条且不溢出', (WidgetTester tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await pumpManual(tester, const Size(1200, 560));
        expect(tester.takeException(), isNull, reason: '矮窗口下表单不应溢出');

        final Finder scrollFinder = find.byType(SingleChildScrollView);
        expect(scrollFinder, findsOneWidget);

        final thickness = scrollbarThickness(tester);
        expect(thickness, greaterThan(0), reason: '主题应给滚动条一个非零厚度');

        expect(
          contentTrailingInset(tester),
          greaterThanOrEqualTo(thickness),
          reason: '滚动内容右侧必须留出滚动条的宽度',
        );

        // 结构性断言：输入框那层容器横向铺满滚动内容，它的右边缘必须整个让开
        // 滚动条所在的槽位——否则桌面端浮动滚动条会正好压在字段的右边框上。
        final viewport = tester.getRect(scrollFinder);
        expect(
          viewport.right - fieldBox(tester, 'name').right,
          greaterThanOrEqualTo(thickness),
          reason: '字段右边缘不应落进滚动条所在的槽位',
        );

        // 内容确实溢出，滚动条才会出现——否则这个用例什么也没覆盖到。
        final scrollView = tester.widget<SingleChildScrollView>(scrollFinder);
        expect(
          scrollView.controller!.position.maxScrollExtent,
          greaterThan(0),
          reason: '该窗口下表单内容应当溢出',
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('窄屏（390×640）：不溢出，且最后一个字段可滚动到完全可见', (WidgetTester tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await pumpManual(tester, const Size(390, 640));
        expect(tester.takeException(), isNull, reason: '窄屏下表单不应溢出');

        final Finder scrollFinder = find.byType(SingleChildScrollView);
        expect(scrollFinder, findsOneWidget);
        final thickness = scrollbarThickness(tester);
        expect(thickness, greaterThan(0));
        expect(contentTrailingInset(tester), greaterThanOrEqualTo(thickness));

        final viewport = tester.getRect(scrollFinder);
        expect(
          viewport.right - fieldBox(tester, 'wg.endpointHost').right,
          greaterThanOrEqualTo(thickness),
        );

        // 最后一个字段初始在视口之外，说明这份表单确实需要滚动。
        final Finder lastField = find.byKey(configFieldKey('wg.keepalive'));
        expect(
          tester.getRect(lastField).bottom,
          greaterThan(viewport.bottom),
          reason: '最后一个字段初始应在视口之外',
        );

        await tester.drag(scrollFinder, const Offset(0, -2000));
        await tester.pumpAndSettle();

        // 滚到底之后它应完整落在视口内，而不是被裁掉或压在按钮行下面。
        final Rect lastRect = tester.getRect(lastField);
        expect(lastRect.top, greaterThanOrEqualTo(viewport.top - 0.5));
        expect(lastRect.bottom, lessThanOrEqualTo(viewport.bottom + 0.5));
        expect(tester.takeException(), isNull);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('确认并添加配置流程同样让开滚动条', (WidgetTester tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final state = AppState();
        state.updateSettings(const AppSettings(autoConnectOnImport: false));
        addTearDown(state.dispose);
        tester.view.physicalSize = const Size(1200, 560);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          MaterialApp(
            theme: buildXvTheme(XvPalette.dark),
            home: Scaffold(
              body: Builder(
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
            ),
          ),
        );
        await tester.tap(find.text('导入'));
        await tester.pumpAndSettle();

        expect(find.text('确认并添加配置'), findsOneWidget);
        expect(tester.takeException(), isNull);
        expect(
          contentTrailingInset(tester),
          greaterThanOrEqualTo(scrollbarThickness(tester)),
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
