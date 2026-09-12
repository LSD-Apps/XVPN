import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/app_state.dart';
import 'package:xvpn/core/secret_protector.dart';
import 'package:xvpn/core/singbox_config.dart';
import 'package:xvpn/core/store.dart';
import 'package:xvpn/models.dart';

/// 一份需要账号密码的 OpenVPN 配置。
const _needCreds = '''
client
dev tun
proto udp
remote vpn.example.net 1194
auth-user-pass
cipher AES-256-CBC
<ca>
-----BEGIN CERTIFICATE-----
MIIB
-----END CERTIFICATE-----
</ca>
''';

/// 不需要账号密码的配置，用作对照。
const _noCreds = '''
client
dev tun
proto udp
remote vpn.example.net 1194
cipher AES-256-CBC
<ca>
-----BEGIN CERTIFICATE-----
MIIB
-----END CERTIFICATE-----
</ca>
''';

/// 一个真的会变形、也能检测出「有没有被调用」的保护器。
///
/// 不用 [PlainSecretProtector]：它原样返回，测不出「落盘时到底走没走保护器」。
/// 也不用真实 DPAPI：那样断言就只能依赖 Windows，而且看不到中间状态。
class _ReversingProtector implements SecretProtector {
  int protectCalls = 0;
  int unprotectCalls = 0;

  @override
  String get scheme => 'test-reverse';

  @override
  bool get isSecure => true;

  @override
  String get description => '测试用（反转字符串）';

  @override
  String protect(String plaintext) {
    protectCalls++;
    // 反转 + base64：既不是明文，也能一眼看出是不是这里处理的。
    return base64Encode(plaintext.split('').reversed.join().codeUnits);
  }

  @override
  String? unprotect(String payload) {
    unprotectCalls++;
    try {
      final reversed = String.fromCharCodes(base64Decode(payload));
      return reversed.split('').reversed.join();
    } on Object {
      return null;
    }
  }
}

void main() {
  late Directory dir;
  late AppStore store;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('xvpn-credentials-test');
    store = AppStore(dir);
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  String readStore() => File(
    '${dir.path}${Platform.pathSeparator}${AppStore.fileName}',
  ).readAsStringSync();

  AppState newState({SecretProtector? protector}) => AppState(
    store: store,
    protector: protector ?? const PlainSecretProtector(),
  );

  group('导入需要账号密码的配置', () {
    test('配置照常导入，只是标记出还缺账号密码', () {
      final state = newState();
      addTearDown(state.dispose);

      final outcome = state.importConf(text: _needCreds, fileName: 'need.ovpn');

      expect(outcome, ImportOutcome.needsCredentials);
      expect(
        state.profiles,
        hasLength(1),
        reason: '配置必须已经导入成功——「导入失败」会让用户白填一次文件',
      );
      final id = state.profiles.single.id;
      expect(state.profileNeedsCredentials(id), isTrue);
      expect(state.profileHasCredentials(id), isFalse);
    });

    test('不需要账号密码的配置直接就是 imported', () {
      final state = newState();
      addTearDown(state.dispose);

      expect(
        state.importConf(text: _noCreds, fileName: 'plain.ovpn'),
        ImportOutcome.imported,
      );
    });

    test('带着账号密码导入时不需要补填', () {
      final state = newState();
      addTearDown(state.dispose);

      final outcome = state.importConf(
        text: _needCreds,
        fileName: 'need.ovpn',
        username: 'alice',
        password: 'secret',
      );

      expect(outcome, ImportOutcome.imported);
      expect(state.profileHasCredentials(state.profiles.single.id), isTrue);
    });
  });

  group('连接前检查', () {
    test('缺账号密码时拒绝连接，并说明该去哪里填', () async {
      final state = newState();
      addTearDown(state.dispose);
      state.importConf(text: _needCreds, fileName: 'need.ovpn');

      await state.connect();

      expect(
        state.status,
        VpnStatus.disconnected,
        reason: '带着空凭据建隧道只会得到一个「已连接但打不开网页」的假象',
      );
      expect(state.lastError, contains('需要账号密码'));
      expect(state.lastError, contains('配置页'), reason: '光说缺什么没用，要指出在哪填');
    });

    test('补填之后可以正常连接', () async {
      final state = newState();
      addTearDown(state.dispose);
      state.importConf(text: _needCreds, fileName: 'need.ovpn');
      final id = state.profiles.single.id;

      state.setProfileCredentials(id, username: 'alice', password: 'secret');
      expect(state.profileNeedsCredentials(id), isFalse);

      await state.connect();
      expect(state.status, VpnStatus.connected);
    });
  });

  group('补填与修改凭据', () {
    test('补填不会改变配置身份，也不会顺手切换当前配置', () {
      final state = newState();
      addTearDown(state.dispose);
      // 先导入一份不需要凭据的配置并设为当前。
      state.importConf(text: _noCreds, fileName: 'plain.ovpn');
      final activeId = state.activeProfile!.id;

      state.importConf(text: _needCreds, fileName: 'need.ovpn');
      final needId = state.profiles.firstWhere((p) => p.name == 'need.ovpn').id;
      // 导入会把新配置设为当前，先切回去，模拟「用户在编辑一份没在用的配置」。
      state.setActiveProfile(activeId);

      state.setProfileCredentials(
        needId,
        username: 'alice',
        password: 'secret',
      );

      expect(state.profileHasCredentials(needId), isTrue);
      expect(state.activeProfile?.id, activeId, reason: '给没在用的配置补密码不该把隧道切过去');
    });

    test('改密码会覆盖旧值', () {
      final state = newState();
      addTearDown(state.dispose);
      state.importConf(
        text: _needCreds,
        fileName: 'n.ovpn',
        username: 'a',
        password: 'b',
      );
      final id = state.profiles.single.id;

      state.setProfileCredentials(id, username: 'a2', password: 'b2');

      expect(state.profiles, hasLength(1), reason: '同一份原文只应有一份配置');
      expect(state.profileHasCredentials(id), isTrue);
    });
  });

  group('凭据落盘', () {
    test('账号密码经过保护器处理后才写盘，文件里不含明文', () {
      final protector = _ReversingProtector();
      final state = newState(protector: protector);
      state.importConf(
        text: _needCreds,
        fileName: 'need.ovpn',
        username: 'alice',
        password: 'super-secret-pw',
      );

      expect(protector.protectCalls, greaterThan(0));
      final raw = readStore();
      expect(
        raw.contains('super-secret-pw'),
        isFalse,
        reason: '明文密码出现在 config.json 里，等于任何读到这个文件的人都拿到了它',
      );
      expect(raw.contains('alice'), isFalse, reason: '账号与密码一起加密，不留半边明文');
      expect(raw, contains('test-reverse'), reason: '方案标识要一起落盘，否则将来换方案读不回来');
      state.dispose();
    });

    test('重启后能解密还原，账号密码仍然可用', () {
      final protector = _ReversingProtector();
      final first = newState(protector: protector);
      first.importConf(
        text: _needCreds,
        fileName: 'need.ovpn',
        username: 'alice',
        password: 'pw-123',
      );
      first.dispose();

      // 模拟重启：同一份文件、同一个保护器（同一台机器上的同一把密钥）。
      final second = newState(protector: protector);
      addTearDown(second.dispose);

      expect(second.profiles, hasLength(1));
      final id = second.profiles.single.id;
      expect(second.profileHasCredentials(id), isTrue);
      expect(second.profileNeedsCredentials(id), isFalse);
    });

    test('解不开时配置仍然保留，只是要求重新填一次', () {
      final first = newState(protector: _ReversingProtector());
      first.importConf(
        text: _needCreds,
        fileName: 'need.ovpn',
        username: 'alice',
        password: 'pw-123',
      );
      first.dispose();

      // 换了机器/换了 Windows 账户：方案标识还在，但密钥已经不同。
      final second = newState(protector: const PlainSecretProtector());
      addTearDown(second.dispose);

      expect(
        second.profiles,
        hasLength(1),
        reason: '凭据解不开绝不能让配置消失——用户会以为「我导入的配置不见了」',
      );
      final id = second.profiles.single.id;
      expect(second.profileNeedsCredentials(id), isTrue);
      expect(second.profileHasCredentials(id), isFalse);
    });

    test('老版本留下的明文 username/password 仍然读得出来（迁移路径）', () {
      // 手工造出旧格式：没有 credentials，只有两个明文字段。
      store.save(<String, Object?>{
        'profiles': <Object?>[
          <String, Object?>{
            'name': 'legacy.ovpn',
            'text': _needCreds,
            'username': 'old-user',
            'password': 'old-pass',
          },
        ],
      });

      final state = newState(protector: _ReversingProtector());
      addTearDown(state.dispose);

      expect(state.profiles, hasLength(1), reason: '升级不能让已有用户丢掉配置');
      final id = state.profiles.single.id;
      expect(state.profileHasCredentials(id), isTrue);
      expect(state.profileNeedsCredentials(id), isFalse);
    });

    test('内容损坏的凭据不会让整份配置失效', () {
      store.save(<String, Object?>{
        'profiles': <Object?>[
          <String, Object?>{
            'name': 'broken.ovpn',
            'text': _needCreds,
            'credentials': '这不是合法的密文',
            'credentialScheme': 'test-reverse',
          },
        ],
      });

      final state = newState(protector: _ReversingProtector());
      addTearDown(state.dispose);

      expect(state.profiles, hasLength(1));
      expect(state.profileNeedsCredentials(state.profiles.single.id), isTrue);
    });
  });

  group('真实平台的保护器走完整条落盘链路', () {
    test('保存后重启仍能还原，且文件里找不到明文密码', () {
      // 前面的用例用的是测试替身，证明的是「流程接了保护器」；
      // 这一条用当前平台真正会用的那个（Windows 上是 DPAPI），
      // 证明的是「装了这把锁之后确实还能打开门」。
      final protector = SecretProtector.forPlatform();
      final first = newState(protector: protector);
      first.importConf(
        text: _needCreds,
        fileName: 'need.ovpn',
        username: 'real-user',
        password: 'real-pw-1qaz',
      );
      first.dispose();

      if (protector.isSecure) {
        final raw = readStore();
        expect(raw.contains('real-pw-1qaz'), isFalse);
        expect(raw.contains('real-user'), isFalse);
      }

      final second = newState(protector: SecretProtector.forPlatform());
      addTearDown(second.dispose);
      expect(second.profiles, hasLength(1));
      expect(second.profileHasCredentials(second.profiles.single.id), isTrue);
    });
  });

  group('凭据进入内核配置', () {
    test('填好的账号密码会写进 sing-box 的 openvpn 端点', () {
      // 这一条把「界面填了」和「内核用上了」连起来：前面的用例只证明凭据存在
      // 状态里，而真正决定能不能连上的是这一段配置。
      final state = newState();
      addTearDown(state.dispose);
      state.importConf(
        text: _needCreds,
        fileName: 'need.ovpn',
        username: 'alice',
        password: 'pw-123',
      );

      final config = SingBoxConfigBuilder.build(
        profile: state.profiles.single.parsed,
        splitMode: SplitMode.smart,
        ruleSetDir: '/tmp/rs',
      );
      final endpoints = config['endpoints']! as List<Object?>;
      final endpoint = (endpoints.single! as Map<Object?, Object?>)
          .cast<String, Object?>();

      expect(endpoint['type'], 'openvpn-client');
      expect(endpoint['username'], 'alice');
      expect(endpoint['password'], 'pw-123');
    });

    test('没填凭据时端点里不会出现空字符串账号', () {
      // 空的 username 字段比没有这个字段更糟：内核会拿它去认证，
      // 失败信息里不会提到「你根本没填」。
      final state = newState();
      addTearDown(state.dispose);
      state.importConf(text: _needCreds, fileName: 'need.ovpn');

      final config = SingBoxConfigBuilder.build(
        profile: state.profiles.single.parsed,
        splitMode: SplitMode.smart,
        ruleSetDir: '/tmp/rs',
      );
      final endpoints = config['endpoints']! as List<Object?>;
      final endpoint = (endpoints.single! as Map<Object?, Object?>)
          .cast<String, Object?>();

      expect(endpoint.containsKey('username'), isFalse);
      expect(endpoint.containsKey('password'), isFalse);
    });
  });
}
