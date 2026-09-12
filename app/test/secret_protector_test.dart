import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/secret_protector.dart';

void main() {
  group('DPAPI 保护（Windows）', () {
    final protector = DpapiSecretProtector.tryCreate();

    test('能取到系统加密能力', () {
      if (!Platform.isWindows) return;
      expect(protector, isNotNull, reason: 'Windows 上应当能加载 crypt32');
      expect(protector!.scheme, 'dpapi');
      expect(protector.isSecure, isTrue);
    }, skip: Platform.isWindows ? null : '仅在 Windows 上有意义');

    test('加密后可原样还原，且密文不等于明文', () {
      if (protector == null) return;
      // 用带中文与特殊字符的密码：UTF-8 编解码只要有一处写错就会在这里暴露。
      const secret = r'p@ss w0rd-测试/中文:符号';
      final protected = protector.protect(secret);

      expect(protected, isNot(secret), reason: '落盘的内容不能等于明文');
      expect(protected.contains('p@ss'), isFalse, reason: '明文片段不该出现在密文里');
      expect(protector.unprotect(protected), secret);
    });

    test('同一明文两次加密得到不同密文（DPAPI 带随机盐）', () {
      if (protector == null) return;
      final a = protector.protect('same-input');
      final b = protector.protect('same-input');
      expect(a, isNot(b), reason: '每次加密都带随机量，密文可对比性更弱');
      expect(protector.unprotect(a), 'same-input');
      expect(protector.unprotect(b), 'same-input');
    });

    test('空字符串也能往返', () {
      if (protector == null) return;
      final protected = protector.protect('');
      expect(protector.unprotect(protected), '');
    });

    test('解不开时返回 null 而不是抛异常', () {
      if (protector == null) return;
      // 这是换机器/换 Windows 账户之后的真实形态：拿到一段不是自己加密的
      // 数据。此时应用要能继续跑，只是需要用户重新填一次密码。
      expect(protector.unprotect('这不是 base64'), isNull);
      expect(protector.unprotect(base64Encode(<int>[1, 2, 3, 4, 5])), isNull);
      expect(protector.unprotect(''), isNull);
      expect(
        protector.unprotect(base64Encode(utf8.encode('被别人加密的内容'))),
        isNull,
      );
    });
  });

  group('不加密的兜底方案', () {
    const plain = PlainSecretProtector();

    test('如实声明自己没有加密', () {
      expect(plain.scheme, 'plain');
      expect(plain.isSecure, isFalse, reason: '不能让界面以为密码被保护了——谎报比不加密更糟');
      expect(plain.description, contains('未加密'));
    });

    test('原样往返', () {
      expect(plain.protect('abc'), 'abc');
      expect(plain.unprotect('abc'), 'abc');
    });
  });

  group('按平台选择方案', () {
    test('Windows 上选 DPAPI，并且方案标识与实现一致', () {
      final selected = SecretProtector.forPlatform();
      if (Platform.isWindows) {
        expect(selected.scheme, 'dpapi');
        expect(selected.isSecure, isTrue);
      } else {
        expect(selected.scheme, 'plain');
      }
      // 方案标识必须是可落盘的短字符串：它会被写进 config.json。
      expect(selected.scheme, matches(RegExp(r'^[a-z0-9_]+$')));
    });
  });
}
