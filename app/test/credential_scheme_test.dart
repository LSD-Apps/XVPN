import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/app_state.dart';
import 'package:xvpn/core/secret_protector.dart';
import 'package:xvpn/core/store.dart';

/// 复现：跨方案读取凭据时，会不会把密文当成密码用。
///
/// 场景是真实的：`%LOCALAPPDATA%\XVPN\config.json` 被同步、被备份还原、
/// 或者用户换了机器/账户。写入时用的是某一个保护器，读取时可能是另一个。
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

void main() {
  late Directory dir;
  late AppStore store;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('xvpn-cross-scheme');
    store = AppStore(dir);
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('DPAPI 写的记录，被明文保护器读到时不能把密文当密码', () {
    // 写：用一个会真正变形的保护器（代替 Windows 上的 DPAPI）。
    final writer = _UpperCaseProtector();
    final first = AppState(store: store, protector: writer);
    first.importConf(
      text: _needCreds,
      fileName: 'n.ovpn',
      username: 'alice',
      password: 'real-password',
    );
    first.dispose();

    // 读：换成明文保护器（相当于在另一个平台上打开同一份文件）。
    final second = AppState(
      store: store,
      protector: const PlainSecretProtector(),
    );
    addTearDown(second.dispose);

    expect(second.profiles, hasLength(1), reason: '配置本身必须保留');
    final id = second.profiles.single.id;

    expect(
      second.profileNeedsCredentials(id),
      isTrue,
      reason:
          '解不开就当没填过，让用户重新填一次；'
          '绝不能把密文当成密码用——那样界面显示「已保存」，而认证永远失败',
    );
    expect(second.profileHasCredentials(id), isFalse);
  });

  test('明文写的记录，被会变形的保护器读到时也不能把明文当已解密结果', () {
    final first = AppState(
      store: store,
      protector: const PlainSecretProtector(),
    );
    first.importConf(
      text: _needCreds,
      fileName: 'n.ovpn',
      username: 'alice',
      password: 'real-password',
    );
    first.dispose();

    final second = AppState(store: store, protector: _UpperCaseProtector());
    addTearDown(second.dispose);

    final id = second.profiles.single.id;
    expect(
      second.profileNeedsCredentials(id),
      isTrue,
      reason: '方案不匹配时不该假装读出来了',
    );
  });
}

/// 会真正改变内容的保护器，用来模拟「另一个平台/账户」的密钥。
class _UpperCaseProtector implements SecretProtector {
  @override
  String get scheme => 'test-upper';

  @override
  bool get isSecure => true;

  @override
  String get description => '测试用';

  @override
  String protect(String plaintext) => plaintext.toUpperCase();

  @override
  String? unprotect(String payload) => payload.toLowerCase();
}
