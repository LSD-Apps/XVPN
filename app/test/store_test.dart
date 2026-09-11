import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/app_state.dart';
import 'package:xvpn/core/store.dart';
import 'package:xvpn/models.dart';

const _wg = '''
[Interface]
PrivateKey = aGVsbG8gd29ybGQgdGhpcyBpcyBhIGtleSB2YWx1ZQ=
Address = 10.7.0.2/32
DNS = 223.5.5.5
MTU = 1420

[Peer]
PublicKey = cHVibGljIGtleSB2YWx1ZSBnb2VzIGhlcmUgcGFkZGVk
Endpoint = 203.0.113.42:51820
AllowedIPs = 0.0.0.0/0
''';

const _ovpn = '''
client
dev tun
proto udp
remote 198.51.100.7 1194
cipher AES-256-GCM
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
    dir = Directory.systemTemp.createTempSync('xvpn-store-test');
    store = AppStore(dir);
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('AppStore 读写', () {
    test('写入后能读回，且带版本号', () {
      expect(store.save(<String, Object?>{'a': 1}), isTrue);
      final loaded = store.load();
      expect(loaded['a'], 1);
      expect(loaded['version'], AppStore.schemaVersion);
    });

    test('文件不存在时返回空表而不是抛异常', () {
      expect(store.load(), isEmpty);
    });

    test('内容损坏时返回空表，不让应用起不来', () {
      dir.createSync(recursive: true);
      File('${dir.path}${Platform.pathSeparator}${AppStore.fileName}')
          .writeAsStringSync('{ 这不是 JSON');
      expect(store.load(), isEmpty);
    });

    test('未来版本的存档不解析，避免读出错的数据', () {
      dir.createSync(recursive: true);
      File('${dir.path}${Platform.pathSeparator}${AppStore.fileName}')
          .writeAsStringSync('{"version": 99, "profiles": []}');
      expect(store.load(), isEmpty);
    });

    test('clear 之后读回为空', () {
      store.save(<String, Object?>{'a': 1});
      store.clear();
      expect(store.load(), isEmpty);
    });
  });

  group('配置持久化', () {
    test('导入的配置在重启后仍在，并自动成为当前配置', () {
      final first = AppState(store: store);
      first.importConf(text: _wg, fileName: 'wg-hk-01.conf');
      expect(first.profiles, hasLength(1));
      first.dispose();

      // 模拟应用重启：全新的状态对象，同一份存档。
      final second = AppState(store: store);
      addTearDown(second.dispose);
      expect(second.profiles, hasLength(1), reason: '重启后配置不应丢失');
      expect(second.activeProfile?.name, 'wg-hk-01.conf');
      expect(second.activeProfile?.endpointDisplay, '203.0.113.42:51820');
    });

    test('多份配置与当前选中项都被记住', () {
      final first = AppState(store: store);
      first.importConf(text: _wg, fileName: 'wg.conf');
      first.importConf(text: _ovpn, fileName: 'ovpn.conf');
      expect(first.profiles, hasLength(2));
      first.setActiveProfile(first.profiles.first.id);
      final expectedActive = first.activeProfile!.id;
      first.dispose();

      final second = AppState(store: store);
      addTearDown(second.dispose);
      expect(second.profiles, hasLength(2));
      expect(second.activeProfile?.id, expectedActive);
    });

    test('删除配置会同步到存档', () {
      final first = AppState(store: store);
      first.importConf(text: _wg, fileName: 'wg.conf');
      final id = first.activeProfile!.id;
      first.removeProfile(id);
      expect(first.profiles, isEmpty);
      first.dispose();

      final second = AppState(store: store);
      addTearDown(second.dispose);
      expect(second.profiles, isEmpty, reason: '删掉的配置不应在重启后复活');
      expect(second.activeProfile, isNull);
    });

    test('设置项被记住', () {
      final first = AppState(store: store);
      first.updateSettings(first.settings.copyWith(
        autoConnectOnImport: false,
        splitMode: SplitMode.globalProxy,
        logSplits: false,
      ));
      first.dispose();

      final second = AppState(store: store);
      addTearDown(second.dispose);
      expect(second.settings.autoConnectOnImport, isFalse);
      expect(second.settings.splitMode, SplitMode.globalProxy);
      expect(second.settings.logSplits, isFalse);
    });

    test('旧存档里已移除的设置项不会让恢复失败', () {
      // 设置项只增不减地留在存档里是常态：用户升级后，旧文件里仍然有
      // 早已移除的字段。恢复逻辑必须忽略它们，而不是抛异常退回默认值——
      // 那会让用户的其他设置一起丢光。
      dir.createSync(recursive: true);
      File('${dir.path}${Platform.pathSeparator}${AppStore.fileName}').writeAsStringSync(
        '{"version":1,"settings":{"autoConnectOnImport":false,'
        '"splitMode":1,"logSplits":false,"launchAtStartup":true,"takeoverMode":1}}',
      );
      final state = AppState(store: store);
      addTearDown(state.dispose);

      expect(state.settings.autoConnectOnImport, isFalse);
      expect(state.settings.splitMode, SplitMode.globalProxy);
      expect(state.settings.logSplits, isFalse);
    });

    test('存档损坏时退回空状态，而不是崩溃', () {
      dir.createSync(recursive: true);
      File('${dir.path}${Platform.pathSeparator}${AppStore.fileName}')
          .writeAsStringSync('{"version":1,"profiles":"不是列表"}');
      final state = AppState(store: store);
      addTearDown(state.dispose);
      expect(state.profiles, isEmpty);
    });

    test('单份配置解析失败时跳过它，其余配置照常恢复', () {
      dir.createSync(recursive: true);
      File('${dir.path}${Platform.pathSeparator}${AppStore.fileName}').writeAsStringSync(
        '{"version":1,"profiles":['
        '{"name":"坏配置.conf","text":"这不是任何已知格式"},'
        '{"name":"wg.conf","text":${_jsonEscape(_wg)}}'
        '],"activeProfileId":null,"settings":{}}',
      );
      final state = AppState(store: store);
      addTearDown(state.dispose);
      expect(state.profiles, hasLength(1));
      expect(state.profiles.single.name, 'wg.conf');
    });
  });

  group('连接意图', () {
    test('用户断开后重启不会自动重连', () async {
      final first = AppState(store: store);
      // 关掉「导入即连」，避免导入触发的自动连接与显式断开抢跑，
      // 这样用例只考验「断开」这个意图本身。
      first.updateSettings(first.settings.copyWith(autoConnectOnImport: false));
      first.importConf(text: _wg, fileName: 'wg.conf');
      await first.connect();
      await first.disconnect();
      expect(first.status, VpnStatus.disconnected);
      first.dispose();

      final second = AppState(store: store);
      addTearDown(second.dispose);
      await second.restoreConnection();
      expect(second.status, VpnStatus.disconnected,
          reason: '用户主动断开过，重开应用不应自动连上');
    });

    test('导入配置后重启会按上次的意图自动连上', () async {
      final first = AppState(store: store);
      first.importConf(text: _wg, fileName: 'wg.conf');
      await first.connect();
      first.dispose();

      final second = AppState(store: store);
      addTearDown(second.dispose);
      expect(second.profiles, hasLength(1));
      await second.restoreConnection();
      expect(
        second.status,
        anyOf(VpnStatus.connecting, VpnStatus.connected),
        reason: '上次是连着离开的，重开应用应恢复连接',
      );
    });
  });
}

String _jsonEscape(String value) {
  final buffer = StringBuffer('"');
  for (final rune in value.runes) {
    switch (rune) {
      case 0x22:
        buffer.write(r'\"');
      case 0x5C:
        buffer.write(r'\\');
      case 0x0A:
        buffer.write(r'\n');
      case 0x0D:
        buffer.write(r'\r');
      case 0x09:
        buffer.write(r'\t');
      default:
        buffer.writeCharCode(rune);
    }
  }
  buffer.write('"');
  return buffer.toString();
}
