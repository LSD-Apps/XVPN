import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/app_state.dart';
import 'package:xvpn/core/secret_protector.dart';
import 'package:xvpn/core/store.dart';

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

/// 假的 Keystore。
///
/// 只模拟**「解得开 / 解不开」**这一件事，不模拟真加解密：真正的 AES-256-GCM 由
/// Dart 侧负责，它在本文件里被单独测过。这里要覆盖的是另一半记账——密钥文件与
/// 「设备」配对、首次生成、换设备轮换。`deviceTag` 换个值就等于换了一台设备。
class _FakeKeystore implements KeystoreBackend {
  _FakeKeystore({this.deviceTag = 'device-a'});

  /// 「这台设备」上的包装密钥。它不随备份 / 换机迁移，这正是 AndroidKeyStore 的
  /// 行为，也是本文件里「换设备解不开」那条用例要复现的东西。
  final String deviceTag;

  /// false 表示 Keystore 不可用（被裁剪过的系统）。
  bool available = true;

  /// 生成出来的密钥长度，用来测「长度不对时不装作加密好了」。
  int keyLength = 32;

  int generateCalls = 0;
  int unwrapCalls = 0;

  @override
  Future<({String wrapped, String key})?> generate() async {
    generateCalls++;
    if (!available) return null;
    // 内容本身不重要，但必须**跟着 deviceTag 变**：换设备解不开正是靠这一点，
    // 若两台设备拿到同一把密钥，那几条用例就测不出东西了。
    final seed = deviceTag.codeUnits.fold<int>(7, (a, b) => (a * 31 + b) & 0xffff);
    final key = Uint8List(keyLength);
    for (var i = 0; i < keyLength; i++) {
      key[i] = (seed + i * 31 + 7) & 0xff;
    }
    final encoded = base64Encode(key);
    return (wrapped: '$deviceTag::$encoded', key: encoded);
  }

  @override
  Future<String?> unwrap(String wrapped) async {
    unwrapCalls++;
    if (!available) return null;
    const separator = '::';
    final at = wrapped.indexOf(separator);
    if (at < 0) return null;
    // 换了设备：包装密钥不在，包里的东西就解不开。
    if (wrapped.substring(0, at) != deviceTag) return null;
    return wrapped.substring(at + separator.length);
  }
}

/// 会抛异常的后端，用来测「通道出错时不许把异常漏到启动流程上」。
class _ThrowingKeystore implements KeystoreBackend {
  const _ThrowingKeystore();

  @override
  Future<({String wrapped, String key})?> generate() async =>
      throw PlatformException(code: 'keystore_broken');

  @override
  Future<String?> unwrap(String wrapped) async =>
      throw PlatformException(code: 'keystore_broken');
}

void main() {
  // 「通道契约」那组要拦平台通道，取 TestDefaultBinaryMessengerBinding 之前
  // binding 必须已初始化。
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('xvpn-keystore-test');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  File keyFile() => File(
    '${dir.path}${Platform.pathSeparator}'
    '${AndroidKeystoreSecretProtector.wrappedKeyFileName}',
  );

  Future<AndroidKeystoreSecretProtector?> create({KeystoreBackend? backend}) =>
      AndroidKeystoreSecretProtector.create(
        directory: dir,
        backend: backend ?? _FakeKeystore(),
      );

  group('加解密', () {
    test('存进去再取出来是同一份内容，且自报为加密', () async {
      final protector = (await create())!;

      expect(protector.scheme, 'android-keystore');
      expect(protector.isSecure, isTrue);
      expect(protector.description, contains('Keystore'));

      const secret = 'alice:super-secret-pw';
      expect(protector.unprotect(protector.protect(secret)), secret);
    });

    test('密文里没有明文，长度是 nonce + 密文 + 标签', () async {
      final protector = (await create())!;
      const secret = 'pw-1qaz-2wsx';

      final payload = protector.protect(secret);
      expect(payload.contains(secret), isFalse, reason: '落盘的必须不是明文');
      expect(
        base64Decode(payload).length,
        12 + secret.length + 16,
        reason: '12 字节 nonce + 明文等长的密文 + 16 字节 GCM 标签',
      );
    });

    test('同一个明文两次加密结果不同，但都能解开', () async {
      // nonce 每次随机。若两次相同，说明 nonce 固定了——GCM 下重复 nonce 会直接
      // 泄漏两次明文的异或，这是最不能接受的实现错误。
      final protector = (await create())!;
      const secret = 'alice:pw';

      final first = protector.protect(secret);
      final second = protector.protect(secret);
      expect(first, isNot(second));
      expect(protector.unprotect(first), secret);
      expect(protector.unprotect(second), secret);
    });

    test('密文被改过一个字节就解不开，而不是返回半截明文', () async {
      final protector = (await create())!;
      final payload = base64Decode(protector.protect('alice:pw'));
      // 改最后一个字节：落在 GCM 的认证标签里。
      payload[payload.length - 1] ^= 0x01;

      expect(protector.unprotect(base64Encode(payload)), isNull);
    });

    test('换一把密钥解不开（换设备 / 从备份恢复的场景）', () async {
      final onDeviceA = (await create(backend: _FakeKeystore()))!;
      final payload = onDeviceA.protect('alice:pw');

      // 直接拿另一把密钥构造：密文不是它写的，认证必然失败。
      final onDeviceB = (await create(
        backend: _FakeKeystore(deviceTag: 'device-b'),
      ))!;
      expect(onDeviceB.unprotect(payload), isNull);
    });

    test('不是密文的输入一律返回 null，不抛异常', () async {
      final protector = (await create())!;

      expect(protector.unprotect('这不是 base64'), isNull);
      expect(protector.unprotect(''), isNull);
      expect(protector.unprotect(base64Encode(<int>[1, 2, 3])), isNull);
      // 长度刚够 nonce + 标签但内容是随机的。
      expect(protector.unprotect(base64Encode(List<int>.filled(28, 0))), isNull);
    });
  });

  group('启动时取回密钥', () {
    test('首次运行生成一把密钥并落在单独的文件里', () async {
      final keystore = _FakeKeystore();
      final protector = await create(backend: keystore);

      expect(protector, isNotNull);
      expect(keystore.generateCalls, 1);
      expect(keyFile().existsSync(), isTrue);
      expect(
        keyFile().readAsStringSync(),
        startsWith('device-a::'),
        reason: '落盘的应当是「被 Keystore 包起来」的那份，而不是明文密钥',
      );
    });

    test('再次启动不再生成，而是解开文件里的那把密钥', () async {
      final keystore = _FakeKeystore();
      final first = (await create(backend: keystore))!;
      final payload = first.protect('alice:pw');
      final generateCallsAfterFirst = keystore.generateCalls;

      // 模拟重启：同一个「设备」、同一份密钥文件。
      final second = (await create(backend: keystore))!;

      expect(
        keystore.generateCalls,
        generateCallsAfterFirst,
        reason: '能解开就不该再生成一把——换了密钥，上次写下的凭据就全废了',
      );
      expect(keystore.unwrapCalls, greaterThan(0));
      expect(
        second.unprotect(payload),
        'alice:pw',
        reason: '重启解不开等于每次开应用都要重填密码',
      );
    });

    test('换了设备解不开时改用新密钥，而不是让应用起不来', () async {
      final first = (await create(backend: _FakeKeystore()))!;
      final oldPayload = first.protect('alice:pw');

      final otherKeystore = _FakeKeystore(deviceTag: 'device-b');
      final second = await create(backend: otherKeystore);

      expect(second, isNotNull, reason: '解不开是预期内的情况，不该抛出去');
      expect(otherKeystore.generateCalls, 1, reason: '得换一把新密钥，后续保存才会重新受保护');
      expect(
        keyFile().readAsStringSync(),
        startsWith('device-b::'),
        reason: '旧文件永远解不开了，留着只会让人以为还有救',
      );
      expect(second!.unprotect(oldPayload), isNull);
      expect(second.unprotect(second.protect('bob:pw')), 'bob:pw');
    });

    test('Keystore 不可用时返回 null，且不留下半截密钥文件', () async {
      final keystore = _FakeKeystore()..available = false;

      expect(await create(backend: keystore), isNull);
      expect(
        keyFile().existsSync(),
        isFalse,
        reason: '没拿到密钥就不该留下一个空文件，那会让下次启动以为有',
      );
    });

    test('没有可写目录时返回 null', () async {
      // 密钥存不住 = 下次启动一定解不开今天写下的密文，
      // 那种「宣称加密了、实则读不回」比明文更坏。
      expect(
        await AndroidKeystoreSecretProtector.create(
          directory: null,
          backend: _FakeKeystore(),
        ),
        isNull,
      );
      expect(keyFile().existsSync(), isFalse);
    });

    test('后端抛异常时返回 null，不让启动流程炸掉', () async {
      expect(await create(backend: const _ThrowingKeystore()), isNull);
    });

    test('密钥长度不对时返回 null，而不是装作加密好了', () async {
      // 128 位 AES 本身不算弱，但原生侧生成的固定是 32 字节；长度对不上说明这条
      // 链路出了别的问题，宁可如实退回不加密。
      final keystore = _FakeKeystore()..keyLength = 16;
      expect(await create(backend: keystore), isNull);
    });
  });

  group('平台选择', () {
    test('安卓且 Keystore 可用时选中 Keystore 方案', () async {
      final protector = await SecretProtector.resolve(
        directory: dir,
        keystore: _FakeKeystore(),
        isAndroid: true,
      );

      expect(protector.scheme, 'android-keystore');
      expect(protector.isSecure, isTrue);
    });

    test('Keystore 不可用时如实退回不加密，并说明原因', () async {
      final protector = await SecretProtector.resolve(
        directory: dir,
        keystore: _FakeKeystore()..available = false,
        isAndroid: true,
      );

      expect(protector.isSecure, isFalse, reason: '不允许谎报已经保护好了');
      expect(protector.description, contains('Keystore'));
      expect(protector.description, contains('明文'));
    });

    test('非安卓平台不碰 Keystore 通道', () async {
      final keystore = _FakeKeystore();
      final protector = await SecretProtector.resolve(
        directory: dir,
        keystore: keystore,
        isAndroid: false,
      );

      expect(protector.scheme, isNot('android-keystore'));
      expect(keystore.generateCalls, 0);
      expect(keystore.unwrapCalls, 0);
    });
  });

  group('通道契约', () {
    const channel = MethodChannel('com.xvpn.xvpn/vpn');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const backend = MethodChannelKeystoreBackend();

    tearDown(() => messenger.setMockMethodCallHandler(channel, null));

    test('生成走 generateCredentialKey，返回值原样解析', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        calls.add(call);
        return <String, Object?>{'wrapped': 'W', 'key': 'K'};
      });

      final result = await backend.generate();

      expect(calls.single.method, 'generateCredentialKey');
      expect(result?.wrapped, 'W');
      expect(result?.key, 'K');
    });

    test('解包走 unwrapCredentialKey，并把密文当参数传下去', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        calls.add(call);
        return 'DEK';
      });

      expect(await backend.unwrap('W'), 'DEK');
      expect(calls.single.method, 'unwrapCredentialKey');
      expect(calls.single.arguments, <String, Object?>{'wrapped': 'W'});
    });

    test('原生报错或返回空值时当作「没拿到」，不抛出去', () async {
      // 通道没接上（原生侧还没注册）：返回 null。
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async => null);
      expect(await backend.generate(), isNull);
      expect(await backend.unwrap('W'), isNull);

      // 原生返回一个缺字段的表：同样当作没拿到。
      messenger.setMockMethodCallHandler(
        channel,
        (MethodCall call) async => <String, Object?>{'wrapped': 'W'},
      );
      expect(await backend.generate(), isNull);

      // 原生直接报错。
      messenger.setMockMethodCallHandler(
        channel,
        (MethodCall call) async =>
            throw PlatformException(code: 'bad_argument'),
      );
      expect(
        await backend.generate(),
        isNull,
        reason: '通道出错要在这一层收住，不能漏到启动流程上',
      );
    });
  });

  group('走完整条落盘链路', () {
    test('config.json 里没有明文密码，重启后仍能还原', () async {
      // 前面的用例测的是保护器本身；这一条把 AppState 与存档一起拉进来，
      // 证明「装了这把锁之后确实还能打开门」——这正是真机上要肉眼确认的那件事，
      // 能在开发机上断言就不必只靠真机。
      final keystore = _FakeKeystore();
      final first = AppState(
        store: AppStore(dir),
        protector: (await create(backend: keystore))!,
      );
      first.importConf(
        text: _needCreds,
        fileName: 'need.ovpn',
        username: 'alice',
        password: 'real-pw-1qaz',
      );
      first.dispose();

      final raw = File(
        '${dir.path}${Platform.pathSeparator}${AppStore.fileName}',
      ).readAsStringSync();
      expect(raw.contains('real-pw-1qaz'), isFalse);
      expect(raw.contains('alice'), isFalse);
      expect(raw.contains('android-keystore'), isTrue, reason: '方案标识要一起落盘');

      // 模拟重启。
      final second = AppState(
        store: AppStore(dir),
        protector: (await create(backend: keystore))!,
      );
      addTearDown(second.dispose);

      expect(second.profiles, hasLength(1));
      expect(second.profileHasCredentials(second.profiles.single.id), isTrue);
      expect(second.profileNeedsCredentials(second.profiles.single.id), isFalse);
    });

    test('换了设备后凭据解不开，但配置还在、只是标记成待补填', () async {
      final first = AppState(
        store: AppStore(dir),
        protector: (await create(backend: _FakeKeystore()))!,
      );
      first.importConf(
        text: _needCreds,
        fileName: 'need.ovpn',
        username: 'alice',
        password: 'real-pw-1qaz',
      );
      first.dispose();

      final second = AppState(
        store: AppStore(dir),
        protector: (await create(
          backend: _FakeKeystore(deviceTag: 'device-b'),
        ))!,
      );
      addTearDown(second.dispose);

      expect(second.profiles, hasLength(1), reason: '解不开凭据不能让配置消失');
      expect(second.profileNeedsCredentials(second.profiles.single.id), isTrue);
      expect(second.profileHasCredentials(second.profiles.single.id), isFalse);
    });
  });
}
