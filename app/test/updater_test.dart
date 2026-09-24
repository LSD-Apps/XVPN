import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/sha256.dart';
import 'package:xvpn/core/updater.dart';
import 'package:xvpn/core/zip.dart';

/// 自动更新引擎的纯逻辑测试。
///
/// 这里**不碰真实网络、不替换任何安装目录**：HTTP 客户端与安装/进程启动都抽成
/// 接口，测试注入替身。原因很直接——「限流、断网、JSON 坏掉、校验不匹配、
/// 路径里有空格」这些才是更新器真正会出错的地方，而它们恰好很难在真实环境里
/// 稳定复现；开发机是 Windows，Linux 与安卓的分支更是只能靠注入来锁定。

// ---------------------------------------------------------------- 测试替身

class _FakeHttpClient implements UpdateHttpClient {
  _FakeHttpClient(this.handler);

  final UpdateHttpResponse Function(Uri url) handler;
  final List<Uri> requested = <Uri>[];

  @override
  Future<UpdateHttpResponse> send(Uri url) async {
    requested.add(url);
    return handler(url);
  }
}

/// 记录以脱离方式启动的命令。
class _RecordingStarter implements ProcessStarter {
  final List<List<String>> calls = <List<String>>[];
  bool result = true;

  @override
  Future<bool> startDetached(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    calls.add(<String>[executable, ...arguments]);
    return result;
  }
}

class _FakeApkChannel implements ApkInstallChannel {
  _FakeApkChannel(this.status);

  final String? status;
  final List<String> paths = <String>[];
  Object? error;

  @override
  Future<String?> installApk(String path) async {
    paths.add(path);
    if (error != null) throw error!;
    return status;
  }
}

// ---------------------------------------------------------------- 夹具

const String _checksumsUrl = 'https://example.net/SHA256SUMS.txt';

UpdateHttpResponse _text(
  int status,
  String body, {
  Map<String, String> headers = const <String, String>{},
  int? contentLength,
}) => UpdateHttpResponse(
  statusCode: status,
  headers: headers,
  body: Stream<List<int>>.value(utf8.encode(body)),
  contentLength: contentLength,
);

UpdateHttpResponse _chunks(
  int status,
  List<List<int>> chunks, {
  int? contentLength,
}) => UpdateHttpResponse(
  statusCode: status,
  headers: const <String, String>{},
  body: Stream<List<int>>.fromIterable(chunks),
  contentLength: contentLength,
);

/// 一份形状与 GitHub API 一致的发布 JSON。
Map<String, Object?> _releaseJson({
  String tag = 'v1.1.0',
  List<Map<String, Object?>>? assets,
}) => <String, Object?>{
  'tag_name': tag,
  'html_url': 'https://github.com/LSD-Apps/XVPN/releases/tag/$tag',
  'body': '本次更新修复了若干问题。',
  'assets':
      assets ??
      <Map<String, Object?>>[
        <String, Object?>{
          'name': 'XVPN-1.1.0-windows-x64.msix',
          'browser_download_url': 'https://example.net/win.msix',
          'size': 1024,
        },
        <String, Object?>{
          'name': 'XVPN-1.1.0-linux-x64.zip',
          'browser_download_url': 'https://example.net/linux.zip',
          'size': 2048,
        },
        <String, Object?>{
          'name': 'XVPN-1.1.0-android-arm64.zip',
          'browser_download_url': 'https://example.net/app.zip',
          'size': 4096,
        },
        <String, Object?>{
          'name': 'SHA256SUMS.txt',
          'browser_download_url': _checksumsUrl,
          'size': 300,
        },
      ],
};

UpdateInfo _infoFor(
  String assetName,
  String assetUrl, {
  UpdatePlatform platform = UpdatePlatform.windows,
  String version = '1.1.0',
}) => UpdateInfo(
  tag: 'v$version',
  version: version,
  platform: platform,
  assetName: assetName,
  assetUri: Uri.parse(assetUrl),
  checksumsName: 'SHA256SUMS.txt',
  checksumsUri: Uri.parse(_checksumsUrl),
  assetSize: null,
  pageUri: Uri.parse('https://github.com/LSD-Apps/XVPN/releases/tag/v$version'),
  notes: null,
);

String _zeros64() => List<String>.filled(64, '0').join();

void main() {
  // -------------------------------------------------------------- SHA-256

  group('SHA-256', () {
    test('标准测试向量', () {
      expect(
        sha256Hex(const <int>[]),
        'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );
      expect(
        sha256Hex(utf8.encode('abc')),
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
      );
      // 56 字节：填充正好跨越一个分组的边界（考验填充与长度写入）。
      expect(
        sha256Hex(
          utf8.encode(
            'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq',
          ),
        ),
        '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1',
      );
    });

    test('一百万个 a（多分组流式）', () {
      expect(
        sha256Hex(List<int>.filled(1000000, 0x61)),
        'cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0',
      );
    });

    test('分块喂入与一次性喂入结果一致', () {
      final data = List<int>.generate(1000, (int i) => (i * 31 + 7) & 0xff);
      final oneShot = sha256Hex(data);

      for (final chunkSize in <int>[1, 7, 63, 64, 65, 999, 1000]) {
        final hasher = Sha256();
        for (var i = 0; i < data.length; i += chunkSize) {
          final end = (i + chunkSize) > data.length ? data.length : i + chunkSize;
          hasher.update(data.sublist(i, end));
        }
        expect(
          hasher.digestHex(),
          oneShot,
          reason: '分块大小 $chunkSize 时摘要应相同',
        );
      }
    });

    test('digestHex 可以重复调用', () {
      final hasher = Sha256()..update(utf8.encode('abc'));
      expect(hasher.digestHex(), hasher.digestHex());
    });
  });

  // -------------------------------------------------------------- 版本比较

  group('版本比较', () {
    test('更高的版本视为更新，相等或更低不算', () {
      expect(isNewerVersion('v1.2.3', '1.2.2'), isTrue);
      expect(isNewerVersion('v1.0.0', '1.0.0'), isFalse);
      expect(isNewerVersion('v0.9.9', '1.0.0'), isFalse);
      expect(isNewerVersion('1.1.0', '1.0.0'), isTrue, reason: '前导 v 可有可无');
    });

    test('缺少的版本段按 0 处理', () {
      expect(isNewerVersion('v1.1', '1.1.0'), isFalse);
      expect(isNewerVersion('v1.1.1', '1.1'), isTrue);
      expect(isNewerVersion('v2', '1.9.9'), isTrue);
    });

    test('预发布后缀：低于同主干正式版，高于更低主干', () {
      expect(isNewerVersion('v1.1.0-beta.1', '1.0.0'), isTrue);
      expect(isNewerVersion('v1.1.0-beta.1', '1.1.0'), isFalse);
      expect(isNewerVersion('v1.1.0', '1.1.0-beta.1'), isTrue);
      expect(isNewerVersion('v1.1.0-beta.2', '1.1.0-beta.1'), isTrue);
      expect(isNewerVersion('v1.1.0-alpha', '1.1.0-beta'), isFalse);
    });

    test('构建元数据不参与比较', () {
      expect(isNewerVersion('v1.0.0+build.5', '1.0.0'), isFalse);
      expect(isNewerVersion('v1.0.1+1', '1.0.0'), isTrue);
    });

    test('无法识别的版本号一律不算更新，也不抛异常', () {
      expect(isNewerVersion('not-a-version', '1.0.0'), isFalse);
      expect(isNewerVersion('v', '1.0.0'), isFalse);
      expect(isNewerVersion('v1.x.0', '1.0.0'), isFalse);
      expect(isNewerVersion('v1.0.0', ''), isFalse);
      expect(isNewerVersion('v1.0.0-', '1.0.0'), isFalse);
    });

    test('normalizeTagVersion 只去掉前导 v', () {
      expect(normalizeTagVersion('v1.2.3'), '1.2.3');
      expect(normalizeTagVersion('1.2.3'), '1.2.3');
      // 预发布后缀是版本号的一部分，附件名里带着它。
      expect(normalizeTagVersion('v1.2.3-beta.1'), '1.2.3-beta.1');
    });
  });

  // -------------------------------------------------------------- 附件选择

  group('附件选择', () {
    test('精确匹配契约里的附件名', () {
      // 三端一律只发压缩包：Windows 是 MSIX、Linux 是 bundle 的 zip、安卓是
      // **装着 APK 的 zip**，发布页上不再有裸文件。
      expect(
        expectedAssetName(UpdatePlatform.windows, '1.1.0'),
        'XVPN-1.1.0-windows-x64.msix',
      );
      expect(
        expectedAssetName(UpdatePlatform.linux, '1.1.0'),
        'XVPN-1.1.0-linux-x64.zip',
      );
      expect(
        expectedAssetName(UpdatePlatform.android, '1.1.0'),
        'XVPN-1.1.0-android-arm64.zip',
      );
    });

    test('找不到精确名字时按后缀近似匹配', () {
      final assets = <ReleaseAsset>[
        ReleaseAsset(
          name: 'XVPN-1.2.0-windows-x64.msix',
          downloadUrl: Uri.parse('https://example.net/win.msix'),
        ),
        ReleaseAsset(
          name: 'XVPN-1.2.0-android-arm64.zip',
          downloadUrl: Uri.parse('https://example.net/app.zip'),
        ),
        ReleaseAsset(
          name: 'XVPN-1.2.0-linux-x64.zip',
          downloadUrl: Uri.parse('https://example.net/linux.zip'),
        ),
      ];
      expect(
        selectAsset(assets, UpdatePlatform.windows, '1.1.0')!.name,
        'XVPN-1.2.0-windows-x64.msix',
      );
      // 安卓的 zip 与 Linux 的 zip 结尾相同，只按 `.zip` 松散匹配会串台。
      expect(
        selectAsset(assets, UpdatePlatform.android, '1.1.0')!.name,
        'XVPN-1.2.0-android-arm64.zip',
      );
      expect(
        selectAsset(assets, UpdatePlatform.linux, '1.1.0')!.name,
        'XVPN-1.2.0-linux-x64.zip',
      );
    });

    test('近似匹配与精确匹配一样不区分大小写', () {
      final assets = <ReleaseAsset>[
        ReleaseAsset(
          name: 'XVPN-1.2.0-Windows-X64.MSIX',
          downloadUrl: Uri.parse('https://example.net/win.msix'),
        ),
      ];
      expect(
        selectAsset(assets, UpdatePlatform.windows, '1.1.0')!.name,
        'XVPN-1.2.0-Windows-X64.MSIX',
      );
    });

    test('绝不把签名证书当成 Windows 安装包', () {
      // 自签名公钥 `.cer` 与 `.msix` 一起发布，两者只差扩展名。把证书下下来当
      // 安装包用，用户拿到的是一个装不上的文件。
      final onlyCertificate = <ReleaseAsset>[
        ReleaseAsset(
          name: 'XVPN-1.1.0-windows-x64.cer',
          downloadUrl: Uri.parse('https://example.net/sign.cer'),
        ),
      ];
      expect(
        selectAsset(onlyCertificate, UpdatePlatform.windows, '1.1.0'),
        isNull,
      );

      final both = <ReleaseAsset>[
        ...onlyCertificate,
        ReleaseAsset(
          name: 'XVPN-1.1.0-windows-x64.msix',
          downloadUrl: Uri.parse('https://example.net/win.msix'),
        ),
      ];
      expect(
        selectAsset(both, UpdatePlatform.windows, '1.1.0')!.name,
        'XVPN-1.1.0-windows-x64.msix',
      );
    });

    test('安卓只认装着 APK 的 zip，裸 APK 不再算数', () {
      // 旧契约发的是裸 APK，新契约统一成压缩包。发布页上出现裸 `.apk` 只可能是
      // 上游没跟上契约——那时如实报「没有本平台的包」，好过下载一个来历不明的
      // 文件去交给系统安装器。
      final onlyApk = <ReleaseAsset>[
        ReleaseAsset(
          name: 'XVPN-1.1.0-android-arm64.apk',
          downloadUrl: Uri.parse('https://example.net/app.apk'),
        ),
      ];
      expect(selectAsset(onlyApk, UpdatePlatform.android, '1.1.0'), isNull);

      final withZip = <ReleaseAsset>[
        ...onlyApk,
        ReleaseAsset(
          name: 'XVPN-1.1.0-android-arm64.zip',
          downloadUrl: Uri.parse('https://example.net/app.zip'),
        ),
      ];
      expect(
        selectAsset(withZip, UpdatePlatform.android, '1.1.0')!.name,
        'XVPN-1.1.0-android-arm64.zip',
      );
    });

    test('没有任何匹配时返回 null', () {
      final assets = <ReleaseAsset>[
        ReleaseAsset(
          name: 'XVPN-1.1.0-macos-arm64.zip',
          downloadUrl: Uri.parse('https://example.net/mac.zip'),
        ),
      ];
      expect(selectAsset(assets, UpdatePlatform.windows, '1.1.0'), isNull);
      expect(selectAsset(assets, UpdatePlatform.linux, '1.1.0'), isNull);
      expect(selectAsset(assets, UpdatePlatform.android, '1.1.0'), isNull);
    });

    test('SHA256SUMS.txt 大小写不敏感地匹配', () {
      final assets = <ReleaseAsset>[
        ReleaseAsset(
          name: 'sha256sums.TXT',
          downloadUrl: Uri.parse('https://example.net/sums'),
        ),
      ];
      expect(selectChecksumsAsset(assets)!.name, 'sha256sums.TXT');
    });
  });

  // -------------------------------------------------------------- 校验和

  group('SHA256SUMS 解析与校验', () {
    final hashA = List<String>.filled(64, 'a').join();
    final hashB = List<String>.filled(64, 'b').join();

    test('接受 sha256sum 的两种分隔与 CRLF 行尾', () {
      final sums = parseChecksums(
        '$hashA  XVPN-1.1.0-windows-x64.msix\r\n'
        '$hashB *XVPN-1.1.0-linux-x64.zip\n'
        '# 注释行\n'
        '\n',
      );
      expect(sums['XVPN-1.1.0-windows-x64.msix'], hashA);
      expect(sums['XVPN-1.1.0-linux-x64.zip'], hashB);
      expect(sums.length, 2);
    });

    test('坏行被跳过，不拖垮整份文件', () {
      final sums = parseChecksums(
        '这不是校验和\n'
        'abc123  short-hash.txt\n'
        '$hashA  good.zip\n',
      );
      expect(sums.length, 1);
      expect(sums['good.zip'], hashA);
    });

    test('完全无法解析时返回空表', () {
      expect(parseChecksums('<html>404</html>'), isEmpty);
    });

    test('BOM 不影响解析', () {
      expect(parseChecksums('\uFEFF$hashA  a.zip\n')['a.zip'], hashA);
    });

    test('匹配 / 不匹配 / 缺记录', () {
      final expected = <String, String>{'a.zip': hashA};
      expect(
        verifyChecksum(
          checksums: expected,
          assetName: 'a.zip',
          actualSha256: hashA,
        ),
        isA<ChecksumVerified>(),
      );
      // 大小写不敏感：sha256sum 输出小写，但别处可能给大写。
      expect(
        verifyChecksum(
          checksums: expected,
          assetName: 'a.zip',
          actualSha256: hashA.toUpperCase(),
        ),
        isA<ChecksumVerified>(),
      );

      final mismatch = verifyChecksum(
        checksums: expected,
        assetName: 'a.zip',
        actualSha256: hashB,
      );
      expect(mismatch, isA<ChecksumMismatch>());
      expect((mismatch as ChecksumMismatch).expected, hashA);
      expect(mismatch.actual, hashB);

      expect(
        verifyChecksum(
          checksums: expected,
          assetName: 'missing.zip',
          actualSha256: hashA,
        ),
        isA<ChecksumEntryMissing>(),
      );
    });
  });

  // -------------------------------------------------------------- JSON 解析

  group('GitHub 发布 JSON 解析', () {
    test('正常发布解析出 tag、版本与附件', () {
      final release = ReleaseInfo.tryParse(_releaseJson());
      expect(release, isNotNull);
      expect(release!.tag, 'v1.1.0');
      expect(release.version, '1.1.0');
      expect(release.assets, hasLength(4));
      expect(release.notes, isNotNull);
    });

    test('结构不对时返回 null 而不是抛异常', () {
      expect(ReleaseInfo.tryParse(null), isNull);
      expect(ReleaseInfo.tryParse(<Object?>[]), isNull);
      expect(ReleaseInfo.tryParse(<String, Object?>{}), isNull);
      expect(
        ReleaseInfo.tryParse(<String, Object?>{'tag_name': 42}),
        isNull,
      );
    });

    test('单个附件字段不合法时跳过该条，其余照常', () {
      final release = ReleaseInfo.tryParse(
        _releaseJson(
          assets: <Map<String, Object?>>[
            <String, Object?>{'name': 'no-url.zip'},
            <String, Object?>{'browser_download_url': 'https://example.net/x'},
            <String, Object?>{
              'name': 'XVPN-1.1.0-windows-x64.msix',
              'browser_download_url': 'https://example.net/win.zip',
            },
          ],
        ),
      );
      expect(release!.assets, hasLength(1));
    });
  });

  // -------------------------------------------------------------- 错误映射

  group('HTTP 错误映射为中文', () {
    test('2xx 不是错误', () {
      expect(describeHttpFailure(200, null), isNull);
      expect(describeHttpFailure(204, null), isNull);
    });

    test('403 + 限流耗尽', () {
      final message = describeHttpFailure(403, '0');
      expect(message, contains('频繁'));
      expect(describeHttpFailure(403, '12'), contains('403'));
    });

    test('404 / 429 / 5xx / 其它', () {
      expect(describeHttpFailure(404, null), contains('没有找到发布记录'));
      expect(describeHttpFailure(429, null), contains('429'));
      expect(describeHttpFailure(500, null), contains('500'));
      expect(describeHttpFailure(302, null), contains('302'));
    });
  });

  // -------------------------------------------------------------- 检查更新

  group('检查更新', () {
    Updater updaterWith(
      UpdateHttpClient http, {
      TargetPlatform platform = TargetPlatform.windows,
      String currentVersion = '1.0.0',
    }) => Updater(
      platform: platform,
      currentVersion: currentVersion,
      http: http,
    );

    test('查询地址来自 kRepoUrl（不是第二份硬编码）', () async {
      final http = _FakeHttpClient((_) => _text(200, jsonEncode(_releaseJson())));
      final updater = updaterWith(http);
      await updater.checkForUpdate();
      expect(
        http.requested.single.toString(),
        'https://api.github.com/repos/LSD-Apps/XVPN/releases/latest',
      );
    });

    test('发现新版本时返回本平台附件与校验文件', () async {
      final http = _FakeHttpClient((_) => _text(200, jsonEncode(_releaseJson())));
      final result = await updaterWith(http).checkForUpdate();
      expect(result, isA<UpdateAvailable>());
      final info = (result as UpdateAvailable).info;
      expect(info.version, '1.1.0');
      expect(info.assetName, 'XVPN-1.1.0-windows-x64.msix');
      expect(info.assetUri.toString(), 'https://example.net/win.msix');
      expect(info.checksumsUri.toString(), _checksumsUrl);
      expect(info.platform, UpdatePlatform.windows);
    });

    test('Linux 与安卓选各自的附件', () async {
      final json = jsonEncode(_releaseJson());
      final linux = await updaterWith(
        _FakeHttpClient((_) => _text(200, json)),
        platform: TargetPlatform.linux,
      ).checkForUpdate();
      expect((linux as UpdateAvailable).info.assetName, contains('linux-x64.zip'));

      final android = await updaterWith(
        _FakeHttpClient((_) => _text(200, json)),
        platform: TargetPlatform.android,
      ).checkForUpdate();
      expect(
        (android as UpdateAvailable).info.assetName,
        contains('android-arm64.zip'),
      );
    });

    test('版本相同或更低时不报告更新', () async {
      final http = _FakeHttpClient((_) => _text(200, jsonEncode(_releaseJson())));
      final same = await updaterWith(
        http,
        currentVersion: '1.1.0',
      ).checkForUpdate();
      expect(same, isA<UpdateNotAvailable>());
      expect((same as UpdateNotAvailable).latestVersion, '1.1.0');

      final newer = await updaterWith(
        http,
        currentVersion: '2.0.0',
      ).checkForUpdate();
      expect(newer, isA<UpdateNotAvailable>());
    });

    test('没有本平台附件时给出可读原因', () async {
      final json = jsonEncode(
        _releaseJson(
          assets: <Map<String, Object?>>[
            <String, Object?>{
              'name': 'XVPN-1.1.0-windows-x64.msix',
              'browser_download_url': 'https://example.net/win.zip',
            },
            <String, Object?>{
              'name': 'SHA256SUMS.txt',
              'browser_download_url': _checksumsUrl,
            },
          ],
        ),
      );
      final result = await updaterWith(
        _FakeHttpClient((_) => _text(200, json)),
        platform: TargetPlatform.linux,
      ).checkForUpdate();
      expect(result, isA<UpdateCheckFailure>());
      expect((result as UpdateCheckFailure).message, contains('Linux x64'));
    });

    test('缺少 SHA256SUMS.txt 时中止', () async {
      final json = jsonEncode(
        _releaseJson(
          assets: <Map<String, Object?>>[
            <String, Object?>{
              'name': 'XVPN-1.1.0-windows-x64.msix',
              'browser_download_url': 'https://example.net/win.zip',
            },
          ],
        ),
      );
      final result = await updaterWith(
        _FakeHttpClient((_) => _text(200, json)),
      ).checkForUpdate();
      expect(result, isA<UpdateCheckFailure>());
      expect((result as UpdateCheckFailure).message, contains('SHA256SUMS'));
    });

    test('JSON 坏掉 / 字段缺失', () async {
      final broken = await updaterWith(
        _FakeHttpClient((_) => _text(200, '{ this is not json')),
      ).checkForUpdate();
      expect((broken as UpdateCheckFailure).message, contains('JSON'));

      final noTag = await updaterWith(
        _FakeHttpClient((_) => _text(200, jsonEncode(<String, Object?>{}))),
      ).checkForUpdate();
      expect((noTag as UpdateCheckFailure).message, contains('必要字段'));

      final badTag = await updaterWith(
        _FakeHttpClient(
          (_) => _text(200, jsonEncode(_releaseJson(tag: 'nightly'))),
        ),
      ).checkForUpdate();
      expect((badTag as UpdateCheckFailure).message, contains('无法识别最新版本号'));
    });

    test('非 200 状态映射', () async {
      final notFound = await updaterWith(
        _FakeHttpClient((_) => _text(404, '')),
      ).checkForUpdate();
      expect((notFound as UpdateCheckFailure).message, contains('404'));

      final limited = await updaterWith(
        _FakeHttpClient(
          (_) => _text(
            403,
            '',
            headers: <String, String>{'X-RateLimit-Remaining': '0'},
          ),
        ),
      ).checkForUpdate();
      expect((limited as UpdateCheckFailure).message, contains('频繁'));
    });

    test('断网与超时给出可读原因，不抛异常', () async {
      final offline = await updaterWith(
        _FakeHttpClient((_) => throw SocketException('网络不可达')),
      ).checkForUpdate();
      expect((offline as UpdateCheckFailure).message, contains('网络'));

      final timeout = await updaterWith(
        _FakeHttpClient((_) => throw TimeoutException('超时')),
      ).checkForUpdate();
      expect((timeout as UpdateCheckFailure).message, contains('超时'));
    });

    test('当前平台不支持时如实说明', () async {
      final result = await updaterWith(
        _FakeHttpClient((_) => _text(200, jsonEncode(_releaseJson()))),
        platform: TargetPlatform.macOS,
      ).checkForUpdate();
      expect(result, isA<UpdateCheckFailure>());
      expect((result as UpdateCheckFailure).message, contains('不支持'));
    });
  });

  // -------------------------------------------------------------- 下载

  group('下载与校验', () {
    late Directory staging;

    setUp(() {
      staging = Directory.systemTemp.createTempSync('xvpn-updater-test');
    });

    tearDown(() {
      if (staging.existsSync()) staging.deleteSync(recursive: true);
    });

    Updater updater(UpdateHttpClient http, {TargetPlatform? platform}) => Updater(
      platform: platform ?? TargetPlatform.windows,
      currentVersion: '1.0.0',
      http: http,
      stagingRoot: staging,
    );

    File downloadedFile(String name) => File(
      '${staging.path}${Platform.pathSeparator}downloads'
      '${Platform.pathSeparator}$name',
    );

    test('校验通过时落盘并回报最终摘要', () async {
      final bytes = <int>[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11];
      final name = 'XVPN-1.1.0-windows-x64.msix';
      final sums = '${sha256Hex(bytes)}  $name\n';
      final http = _FakeHttpClient((Uri url) {
        if (url.toString() == _checksumsUrl) return _text(200, sums);
        return _chunks(
          200,
          <List<int>>[bytes.sublist(0, 4), bytes.sublist(4)],
          contentLength: bytes.length,
        );
      });

      final progress = <int>[];
      final result = await updater(http).download(
        _infoFor(name, 'https://example.net/win.zip'),
        onProgress: (int received, int? _) => progress.add(received),
      );

      expect(result, isA<UpdateDownloaded>());
      final file = (result as UpdateDownloaded).file;
      expect(file.readAsBytesSync(), bytes);
      expect(result.sha256, sha256Hex(bytes));
      expect(progress.first, 0);
      expect(progress.last, bytes.length);
    });

    test('摘要不匹配时拒绝安装并删掉半成品', () async {
      final bytes = <int>[9, 9, 9];
      final name = 'XVPN-1.1.0-windows-x64.msix';
      final sums = '${_zeros64()}  $name\n';
      final http = _FakeHttpClient((Uri url) {
        if (url.toString() == _checksumsUrl) return _text(200, sums);
        return _chunks(200, <List<int>>[bytes], contentLength: bytes.length);
      });

      final result = await updater(http).download(
        _infoFor(name, 'https://example.net/win.zip'),
      );

      expect(result, isA<UpdateDownloadFailure>());
      expect((result as UpdateDownloadFailure).message, contains('校验失败'));
      expect(downloadedFile(name).existsSync(), isFalse);
    });

    test('校验文件里没有该附件时拒绝', () async {
      final bytes = <int>[1, 2, 3];
      final name = 'XVPN-1.1.0-windows-x64.msix';
      final sums = '${sha256Hex(bytes)}  some-other.zip\n';
      final http = _FakeHttpClient((Uri url) {
        if (url.toString() == _checksumsUrl) return _text(200, sums);
        return _chunks(200, <List<int>>[bytes], contentLength: bytes.length);
      });

      final result = await updater(http).download(
        _infoFor(name, 'https://example.net/win.zip'),
      );
      expect(result, isA<UpdateDownloadFailure>());
      expect((result as UpdateDownloadFailure).message, contains('没有'));
      expect(downloadedFile(name).existsSync(), isFalse);
    });

    test('校验文件本身无法解析时连大文件都不下', () async {
      final http = _FakeHttpClient((_) => _text(200, '<html>oops</html>'));
      final result = await updater(http).download(
        _infoFor('XVPN-1.1.0-windows-x64.msix', 'https://example.net/win.zip'),
      );
      expect(result, isA<UpdateDownloadFailure>());
      expect((result as UpdateDownloadFailure).message, contains('无法解析'));
      // 只请求了校验文件，没有下载安装包。
      expect(http.requested, hasLength(1));
    });

    test('下载失败时不留半成品', () async {
      final name = 'XVPN-1.1.0-windows-x64.msix';
      final sums = '${sha256Hex(<int>[1])}  $name\n';
      final http = _FakeHttpClient((Uri url) {
        if (url.toString() == _checksumsUrl) return _text(200, sums);
        throw SocketException('下载中断');
      });
      final result = await updater(http).download(
        _infoFor(name, 'https://example.net/win.zip'),
      );
      expect(result, isA<UpdateDownloadFailure>());
      expect((result as UpdateDownloadFailure).message, contains('网络'));
      expect(downloadedFile(name).existsSync(), isFalse);
    });

    test('取消时停止下载并删掉半成品', () async {
      final bytes = <int>[1, 2, 3, 4];
      final name = 'XVPN-1.1.0-windows-x64.msix';
      final sums = '${sha256Hex(bytes)}  $name\n';
      final http = _FakeHttpClient((Uri url) {
        if (url.toString() == _checksumsUrl) return _text(200, sums);
        return _chunks(200, <List<int>>[bytes], contentLength: bytes.length);
      });

      final cancellation = UpdateCancellation();
      final result = await updater(http).download(
        _infoFor(name, 'https://example.net/win.zip'),
        cancellation: cancellation,
        onProgress: (int received, int? _) {
          if (received == 0) cancellation.cancel();
        },
      );

      expect(result, isA<UpdateDownloadCancelled>());
      expect(downloadedFile(name).existsSync(), isFalse);
    });

    test('已经取消时不发任何请求', () async {
      final cancellation = UpdateCancellation()..cancel();
      final http = _FakeHttpClient((_) => _text(200, ''));
      final result = await updater(http).download(
        _infoFor('XVPN-1.1.0-windows-x64.msix', 'https://example.net/win.zip'),
        cancellation: cancellation,
      );
      expect(result, isA<UpdateDownloadCancelled>());
      expect(http.requested, isEmpty);
    });
  });

  // -------------------------------------------------------------- 脚本生成

  group('安装脚本生成', () {
    test('Windows：等待退出 → 交给系统部署服务装 MSIX → 重启，路径被单引号包裹', () {
      const msix =
          r"C:\Program Files\XVPN\Bob's updates\XVPN-1.1.0-windows-x64.msix";
      const staging = r"C:\Users\me\AppData\Local\Temp\XVPN's update";
      const launch = r"C:\Program Files\XVPN\xvpn.exe";

      final script = buildWindowsMsixRelaunchScript(
        pid: 4321,
        msixPath: msix,
        stagingDir: staging,
        fallbackLaunchPath: launch,
      );

      // 带空格的路径必须整体被引号包住；路径里的单引号按 PowerShell 规则翻倍。
      expect(
        script,
        contains(
          r"'C:\Program Files\XVPN\Bob''s updates\XVPN-1.1.0-windows-x64.msix'",
        ),
      );

      // 顺序是硬要求：MSIX 的部署服务不允许在包正在运行时替换它（会以
      // 0x80073D02 一类错误失败），因此必须先等当前进程退出再安装。
      final waitIndex = script.indexOf('Wait-Process -Id 4321');
      final installIndex = script.indexOf('Add-AppxPackage -Path');
      final startIndex = script.indexOf('Start-Process -FilePath');
      expect(waitIndex, greaterThanOrEqualTo(0));
      expect(installIndex, greaterThanOrEqualTo(0));
      expect(startIndex, greaterThanOrEqualTo(0));
      expect(waitIndex, lessThan(installIndex));
      expect(installIndex, lessThan(startIndex));

      // 升级不再碰安装目录：不成立的前提是「把文件复制进去」，而现在由系统部署
      // 服务写 %ProgramFiles%\WindowsApps\，因此不存在「替换到一半」的失败形态。
      expect(script, isNot(contains('Expand-Archive')));
      expect(script, isNot(contains('Copy-Item')));
    });

    test('Windows：重启走执行别名，且别名在脚本里算', () {
      final script = buildWindowsMsixRelaunchScript(
        pid: 7,
        msixPath: r'C:\a b\x.msix',
        stagingDir: r'C:\a b\stage',
        fallbackLaunchPath: r'C:\Program Files\XVPN\xvpn.exe',
      );

      // 包目录名里带着版本号（...\WindowsApps\XVPN_1.4.0.0_x64__<哈希>\），升级
      // 之后旧路径就没了；清单声明的执行别名升级前后都指向当前版本。
      expect(
        script,
        contains(
          r"Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\xvpn.exe'",
        ),
      );
      expect(script, contains(r'Start-Process -FilePath $alias'));
      // 别名必须在**脚本里**算：MSIX 打包应用的 %LOCALAPPDATA% 被重定向到包私有
      // 目录，从应用里读出来是假路径；助手是未打包的普通进程，读到的才是真值。
      expect(script, contains(r'$env:LOCALAPPDATA'));
      expect(
        script,
        isNot(contains(r"Start-Process -FilePath 'C:\a b\x.msix'")),
        reason: '重启不能拿安装包路径顶替——它是 MSIX 包，不是可执行文件',
      );
    });

    test('Windows：装不上也要把旧版本拉起来，并把原因写进日志', () {
      const launch = r'C:\Program Files\XVPN\xvpn.exe';
      final script = buildWindowsMsixRelaunchScript(
        pid: 99,
        msixPath: r'C:\stage\pkg.msix',
        stagingDir: r'C:\stage',
        fallbackLaunchPath: launch,
      );

      final catchBlock = script.substring(
        script.indexOf('} catch {'),
        script.indexOf('} finally {'),
      );
      // 失败不能让用户手里没有程序可用：用回退路径把旧版本拉起来。
      expect(catchBlock, contains("Start-Process -FilePath '$launch'"));
      // 最常见的失败原因是签名没被信任与系统策略禁止侧载——不写出来，用户只能
      // 对着一个一闪而过的窗口猜。
      expect(catchBlock, contains('签名'));
      expect(catchBlock, contains('侧载'));
      expect(catchBlock, isNot(contains('RunAs')));
    });

    test('Windows：成功才删安装包与助手脚本，失败必须留着它们', () {
      const msix = r'C:\stage\pkg.msix';
      final script = buildWindowsMsixRelaunchScript(
        pid: 5,
        msixPath: msix,
        stagingDir: r'C:\stage',
        fallbackLaunchPath: r'C:\Program Files\XVPN\xvpn.exe',
      );

      // 只有走到「重新启动」之后才把 ok 置真；清理逻辑据此分流。
      final relaunchIndex = script.indexOf(r'Start-Process -FilePath $alias');
      final okIndex = script.indexOf(r'$ok = $true');
      expect(relaunchIndex, lessThan(okIndex), reason: '成功标志必须在重启之后才置位');

      final finallyBlock = script.substring(script.indexOf('} finally {'));
      expect(finallyBlock, contains(r'if ($ok) {'));
      // 失败分支要保留安装包与日志：包已下载并校验过，用户还能重试或按发布页
      // 说明自行安装；日志是事后唯一能查到原因的入口。
      final failureBranch = finallyBlock.substring(
        finallyBlock.indexOf('} else {'),
      );
      expect(failureBranch, isNot(contains('Remove-Item')));
      expect(failureBranch, contains('已保留安装包：'));
      expect(failureBranch, contains('日志：'));

      final successBranch = finallyBlock.substring(
        0,
        finallyBlock.indexOf('} else {'),
      );
      expect(
        successBranch,
        contains(r"Remove-Item -LiteralPath 'C:\stage\pkg.msix'"),
      );
      // 脚本自己也一并删掉：它已经没用了，留在暂存目录里只会让人以为还有一次
      // 没跑完的更新。
      expect(
        successBranch,
        contains(r'Remove-Item -LiteralPath $PSCommandPath'),
      );
    });

    test('Windows：脚本里不再有任何提权痕迹', () {
      final script = buildWindowsMsixRelaunchScript(
        pid: 1,
        msixPath: r'C:\a b\x.msix',
        stagingDir: r'C:\a b\stage',
        fallbackLaunchPath: r'C:\a b\install\xvpn.exe',
      );

      // 同一发布者的包做用户级升级是常规操作，不需要管理员：弹一次 UAC 既没有
      // 必要，还会让用户以为更新要动系统。
      expect(script, isNot(contains('RunAs')));
      expect(script, isNot(contains('Verb')));
    });

    test('Linux：等待退出 → unzip → 覆盖 → 重启，路径被正确转义', () {
      const archive = "/tmp/xvpn update/XVPN-1.1.0-linux-x64.zip";
      const staging = "/tmp/xvpn update";
      const install = "/opt/My VPN's dir";
      const launch = '/opt/My VPN\'s dir/xvpn';

      final script = buildLinuxRelaunchScript(
        pid: 777,
        archivePath: archive,
        stagingDir: staging,
        installDir: install,
        launchPath: launch,
      );

      expect(script, contains('while kill -0 777'));
      // 安装包与安装目录都收进变量：它们在脚本里出现多次（解压、保留提示、
      // 成功后的清理），逐处硬编码引号迟早会出现某处漏转义。
      expect(
        script,
        contains("ARCHIVE='/tmp/xvpn update/XVPN-1.1.0-linux-x64.zip'"),
      );
      expect(script, contains('unzip -o -q "\$ARCHIVE" -d "\$EXTRACT"'));
      // 安装目录里的单引号按 POSIX 规则以 '\'' 脱出。
      expect(script, contains(r"INSTALL='/opt/My VPN'\''s dir'"));
      expect(script, contains('cp -a'));

      final waitIndex = script.indexOf('while kill -0 777');
      final extractIndex = script.indexOf('unzip -o -q');
      final copyIndex = script.indexOf('cp -a');
      final relaunchIndex = script.indexOf("log '重新启动'");
      expect(waitIndex, lessThan(extractIndex));
      expect(extractIndex, lessThan(copyIndex));
      expect(copyIndex, lessThan(relaunchIndex));

      // 每一步失败都要中止：`cp` 失败若被放过，脚本会继续「重新启动」并声称
      // 成功，而安装目录可能正被替换成一半——把失败当成功是最坏的一种形态。
      expect(script, contains("|| fail 'unzip 解压失败"));
      expect(script, contains("|| fail '覆盖安装目录失败"));

      // 只有**成功**才清理安装包；失败路径必须留着它，否则用户既没有新版本，
      // 也找不到可手动解压的包。
      expect(script, contains('log "已保留安装包：\$ARCHIVE"'));
      final failBody = script.substring(
        script.indexOf('fail() {'),
        script.indexOf("\n}", script.indexOf('fail() {')),
      );
      expect(
        failBody,
        isNot(contains('rm -f "\$ARCHIVE"')),
        reason: '中止路径绝不能删安装包',
      );
      final successTail = script.substring(script.indexOf("log '重新启动'"));
      expect(successTail, contains('rm -f "\$ARCHIVE"'));
    });

    test('Linux：没有 unzip 时给出可操作提示而不是静默失败', () {
      final script = buildLinuxRelaunchScript(
        pid: 1,
        archivePath: '/tmp/a.zip',
        stagingDir: '/tmp/stage',
        installDir: '/tmp/install',
        launchPath: '/tmp/install/xvpn',
      );
      expect(script, contains('系统里没有 unzip'));
    });

    test('启动命令：Windows 隐藏窗口并绕过执行策略，Linux 走 /bin/sh', () {
      expect(
        windowsRelaunchCommand(r'C:\tmp\x p\s.ps1'),
        <String>[
          'powershell.exe',
          '-NoProfile',
          '-NonInteractive',
          '-WindowStyle',
          'Hidden',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          r'C:\tmp\x p\s.ps1',
        ],
      );
      expect(
        linuxRelaunchCommand('/tmp/x p/s.sh'),
        <String>['/bin/sh', '/tmp/x p/s.sh'],
      );
    });
  });

  // -------------------------------------------------------------- 桌面安装策略

  group('桌面安装策略', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('xvpn-install-test');
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('Windows：写出脚本、启动助手，并报告日志位置', () async {
      final separator = Platform.pathSeparator;
      final installDir = Directory('${root.path}${separator}install')
        ..createSync(recursive: true);
      final staging = Directory('${root.path}${separator}staging')
        ..createSync(recursive: true);
      final archive = File('${root.path}${separator}XVPN-1.1.0-windows-x64.msix')
        ..writeAsBytesSync(<int>[1, 2, 3]);
      final starter = _RecordingStarter();

      final installer = DesktopUpdateInstaller(
        platform: TargetPlatform.windows,
        installDir: installDir,
        launchPath: '${installDir.path}${separator}xvpn.exe',
        processStarter: starter,
        hostPid: 4242,
      );

      final result = await installer.install(
        info: _infoFor(
          'XVPN-1.1.0-windows-x64.msix',
          'https://example.net/win.zip',
        ),
        archive: archive,
        stagingDir: staging,
      );

      expect(result, isA<UpdateInstallStarted>());
      expect((result as UpdateInstallStarted).logPath, contains('xvpn-update.log'));
      expect(starter.calls, hasLength(1));
      expect(starter.calls.single.first, 'powershell.exe');
      expect(starter.calls.single, contains('-File'));

      final script = File('${staging.path}${separator}xvpn-relaunch.ps1');
      expect(script.existsSync(), isTrue);
      // UTF-8 BOM：PowerShell 5.1 没有它就会按 ANSI 读，中文日志会乱码。
      // 注意断言的是**原始字节**——Dart 的 UTF-8 解码器读取时会吞掉 BOM。
      expect(
        script.readAsBytesSync().sublist(0, 3),
        <int>[0xEF, 0xBB, 0xBF],
      );
      expect(script.readAsStringSync(), contains('Wait-Process -Id 4242'));
      // 助手这一版只做一件事：把 MSIX 交给系统部署服务。安装目录在这里已经不
      // 参与升级，因此脚本里不该再有解压/覆盖的痕迹。
      expect(script.readAsStringSync(), contains('Add-AppxPackage -Path'));
      expect(script.readAsStringSync(), isNot(contains('Copy-Item')));
    });

    test('Linux：写出 sh 脚本并交给 /bin/sh', () async {
      final separator = Platform.pathSeparator;
      final installDir = Directory('${root.path}${separator}install')
        ..createSync(recursive: true);
      final staging = Directory('${root.path}${separator}staging')
        ..createSync(recursive: true);
      final archive = File('${root.path}${separator}XVPN-1.1.0-linux-x64.zip')
        ..writeAsBytesSync(<int>[1, 2, 3]);
      final starter = _RecordingStarter();

      final installer = DesktopUpdateInstaller(
        platform: TargetPlatform.linux,
        installDir: installDir,
        launchPath: '${installDir.path}${separator}xvpn',
        processStarter: starter,
        hostPid: 99,
      );

      final result = await installer.install(
        info: _infoFor(
          'XVPN-1.1.0-linux-x64.zip',
          'https://example.net/linux.zip',
          platform: UpdatePlatform.linux,
        ),
        archive: archive,
        stagingDir: staging,
      );

      expect(result, isA<UpdateInstallStarted>());
      expect(starter.calls.single.first, '/bin/sh');
      final script = File('${staging.path}${separator}xvpn-relaunch.sh');
      expect(script.existsSync(), isTrue);
      expect(script.readAsStringSync(), contains('kill -0 99'));
    });

    // 字符串断言只能证明「该有的片段在」，证明不了整份脚本**能被解析**。而一段
    // 语法错误的更新脚本，只会在用户的机器上、更新进行到一半时才暴露——那时
    // 应用已经退出、安装目录可能正被改写。因此这里把生成的脚本交给真正的解释器
    // 做语法检查。两个平台各覆盖一半：Windows 用 PowerShell 的解析器，Linux 用
    // `sh -n`。
    test('Windows：生成的脚本能被 PowerShell 解析', () async {
      if (!Platform.isWindows) return; // Linux runner 上没有 PowerShell。
      final separator = Platform.pathSeparator;
      final dir = Directory.systemTemp.createTempSync('xvpn-ps1-syntax');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });

      // 路径刻意带空格与单引号：这两者最容易把引号拼错（单引号要翻倍、带空格的
      // 参数要再套一层双引号）。
      final staging = "${dir.path}${separator}Bob's update scripts";
      final install = '$staging${separator}Program Files';
      final msix =
          "$staging${separator}Bob's package"
          '${separator}XVPN-1.1.0-windows-x64.msix';
      Directory(staging).createSync(recursive: true);

      final script = File('$staging$separator$relaunchScriptName.ps1')
        ..writeAsStringSync(
          '\uFEFF${buildWindowsMsixRelaunchScript(
            pid: 1234,
            msixPath: msix,
            stagingDir: staging,
            fallbackLaunchPath: '$install${separator}xvpn.exe',
          )}',
          flush: true,
        );

      final result = await Process.run(
        'powershell.exe',
        <String>[
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          // 只用解析器，不执行任何东西。
          r'$errors = $null;'
          r'[System.Management.Automation.Language.Parser]::ParseFile('
          r'$env:XVPN_PARSE_PATH, [ref]$null, [ref]$errors) | Out-Null;'
          r'if ($errors.Count -gt 0) { $errors | ForEach-Object { $_.Message }; exit 1 }',
        ],
        // 路径经环境变量传进去，而不是拼进命令串：路径里可能有单引号
        // （`Bob's`），拼进去会先把这个检查自己写坏——第一次就是这么错的。
        environment: <String, String>{'XVPN_PARSE_PATH': script.path},
      );
      expect(
        result.exitCode,
        0,
        reason: '${script.path} 解析失败：${result.stdout}${result.stderr}',
      );

      // 顺带把引号规则写清楚：单引号内的单引号按 PowerShell 规则翻倍。少这一层，
      // Add-AppxPackage 会收到一个截断的路径，而报错要到用户机器上才出现。
      expect(
        script.readAsStringSync(),
        contains("Add-AppxPackage -Path '${msix.replaceAll("'", "''")}'"),
      );
    });

    test('Linux：生成的脚本能被 sh -n 解析', () async {
      if (Platform.isWindows) return; // Windows 上的 sh 不是 POSIX 目标环境。
      final separator = Platform.pathSeparator;
      final dir = Directory.systemTemp.createTempSync('xvpn-sh-syntax');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final staging = "${dir.path}${separator}Bob's update scripts";
      final install = '$staging${separator}opt';
      Directory(staging).createSync(recursive: true);

      final script = File('$staging$separator$relaunchScriptName.sh')
        ..writeAsStringSync(
          buildLinuxRelaunchScript(
            pid: 1234,
            archivePath: '$staging${separator}pkg.zip',
            stagingDir: staging,
            installDir: install,
            launchPath: '$install${separator}xvpn',
          ),
          flush: true,
        );

      final result = await Process.run('/bin/sh', <String>['-n', script.path]);
      expect(
        result.exitCode,
        0,
        reason: '${script.path} 解析失败：${result.stdout}${result.stderr}',
      );
    });

    test('更新包不存在时直接失败', () async {
      final separator = Platform.pathSeparator;
      final installDir = Directory('${root.path}${separator}install')
        ..createSync(recursive: true);
      final installer = DesktopUpdateInstaller(
        platform: TargetPlatform.windows,
        installDir: installDir,
        launchPath: '${installDir.path}${separator}xvpn.exe',
        processStarter: _RecordingStarter(),
        hostPid: 1,
      );
      final result = await installer.install(
        info: _infoFor(
          'XVPN-1.1.0-windows-x64.msix',
          'https://example.net/win.zip',
        ),
        archive: File('${root.path}${separator}nope.zip'),
        stagingDir: root,
      );
      expect(result, isA<UpdateInstallFailure>());
      expect((result as UpdateInstallFailure).message, contains('更新包不存在'));
    });

    test('Linux：安装目录不存在时拒绝而不是破坏安装', () async {
      final separator = Platform.pathSeparator;
      final installer = DesktopUpdateInstaller(
        platform: TargetPlatform.linux,
        installDir: Directory('${root.path}${separator}not-here'),
        launchPath: '/nope/xvpn',
        processStarter: _RecordingStarter(),
        hostPid: 1,
      );
      final result = await installer.install(
        info: _infoFor(
          'XVPN-1.1.0-linux-x64.zip',
          'https://example.net/linux.zip',
          platform: UpdatePlatform.linux,
        ),
        archive: File('${root.path}${separator}a.zip')..writeAsBytesSync(<int>[1]),
        stagingDir: root,
      );
      expect(result, isA<UpdateInstallFailure>());
      expect((result as UpdateInstallFailure).message, contains('找不到安装目录'));
    });

    test('Windows：安装目录不存在也照样升级——MSIX 不写安装目录', () async {
      // MSIX 的升级由系统部署服务写 %ProgramFiles%\WindowsApps\，与应用自己的
      // 目录无关。绿色解压版被搬到别处、目录已被删掉，都不该拦住一次升级。
      final separator = Platform.pathSeparator;
      final starter = _RecordingStarter();
      final installer = DesktopUpdateInstaller(
        platform: TargetPlatform.windows,
        installDir: Directory('${root.path}${separator}not-here'),
        launchPath: r'C:\nope\xvpn.exe',
        processStarter: starter,
        hostPid: 1,
      );
      final result = await installer.install(
        info: _infoFor(
          'XVPN-1.1.0-windows-x64.msix',
          'https://example.net/win.msix',
        ),
        archive: File('${root.path}${separator}a.msix')..writeAsBytesSync(<int>[1]),
        stagingDir: root,
      );
      expect(result, isA<UpdateInstallStarted>());
      expect(starter.calls, hasLength(1));
    });

    test('无法启动助手时告诉用户如何手动更新', () async {
      final separator = Platform.pathSeparator;
      final installDir = Directory('${root.path}${separator}install')
        ..createSync(recursive: true);
      final starter = _RecordingStarter()..result = false;
      final installer = DesktopUpdateInstaller(
        platform: TargetPlatform.windows,
        installDir: installDir,
        launchPath: '${installDir.path}${separator}xvpn.exe',
        processStarter: starter,
        hostPid: 1,
      );
      final result = await installer.install(
        info: _infoFor(
          'XVPN-1.1.0-windows-x64.msix',
          'https://example.net/win.msix',
        ),
        archive: File('${root.path}${separator}a.msix')..writeAsBytesSync(<int>[1]),
        stagingDir: root,
      );
      expect(result, isA<UpdateInstallFailure>());
      // Windows 的产物是 MSIX，手动那条路是「双击安装」而不是「解压覆盖」，
      // 提示必须指对方向。
      expect((result as UpdateInstallFailure).message, contains('手动安装'));
    });

    // ---------------------------------------------------------- 受保护安装目录
    //
    // 「装在只读目录」如今只剩 Linux 一种形态：Windows 走 MSIX，由系统部署服务
    // 写包目录，既不看也不写安装目录。真实的只读目录在测试里造不出来（Windows
    // 上要管理员才能改 ACL，CI 的 Linux runner 也不是以 root 跑的），因此用探测
    // 替身表达。

    /// 造一个「安装目录写不进去」的安装器。
    DesktopUpdateInstaller protectedInstaller({
      required Directory installDir,
      required _RecordingStarter starter,
    }) => DesktopUpdateInstaller(
      platform: TargetPlatform.linux,
      installDir: installDir,
      launchPath: '${installDir.path}${Platform.pathSeparator}xvpn',
      processStarter: starter,
      hostPid: 1,
      writabilityProbe: (Directory _) => false,
    );

    File archiveIn(String separator, {String name = 'a.zip'}) =>
        File('${root.path}$separator$name')..writeAsBytesSync(<int>[1]);

    test('Windows：不再探测安装目录是否可写，也不再有提权这一步', () async {
      // 这里刻意让探测回答「写不进去」：Windows 这条路根本不该问它。
      // 以前升级要往安装目录里复制文件，于是「目录只读」是唯一需要管理员授权的
      // 场景；现在升级交给 MSIX 部署服务，那条分支连同它的结果类型一起没了。
      final separator = Platform.pathSeparator;
      final installDir = Directory('${root.path}${separator}install')
        ..createSync(recursive: true);
      final starter = _RecordingStarter();
      final installer = DesktopUpdateInstaller(
        platform: TargetPlatform.windows,
        installDir: installDir,
        launchPath: '${installDir.path}${separator}xvpn.exe',
        processStarter: starter,
        hostPid: 1,
        writabilityProbe: (Directory _) => false,
      );

      final result = await installer.install(
        info: _infoFor('XVPN-1.1.0-windows-x64.msix', 'https://example.net/win.msix'),
        archive: archiveIn(separator, name: 'a.msix'),
        stagingDir: root,
      );

      expect(result, isA<UpdateInstallStarted>());
      expect(starter.calls, hasLength(1));
      final script = File('${root.path}${separator}xvpn-relaunch.ps1');
      expect(script.existsSync(), isTrue);
      expect(script.readAsStringSync(), isNot(contains('RunAs')));
    });

    test('Linux：只读安装拒绝自动更新，并给出用户目录这条出路', () async {
      // Linux 不自行提权：/usr/bin、/usr/lib 归包管理器所有，绕过 dpkg/rpm
      // 覆盖文件会破坏包数据库，而且下一次包升级又会把它们改回去。
      final separator = Platform.pathSeparator;
      final installDir = Directory('${root.path}${separator}install')
        ..createSync(recursive: true);
      final starter = _RecordingStarter();
      final installer = protectedInstaller(
        installDir: installDir,
        starter: starter,
      );

      final result = await installer.install(
        info: _infoFor(
          'XVPN-1.1.0-linux-x64.zip',
          'https://example.net/lin.zip',
          platform: UpdatePlatform.linux,
        ),
        archive: archiveIn(separator),
        stagingDir: root,
      );

      expect(result, isA<UpdateInstallFailure>());
      final message = (result as UpdateInstallFailure).message;
      expect(message, contains('只读'));
      expect(
        message,
        contains('.local/opt/xvpn'),
        reason: '只说「不行」没有用，要给出真实可走的出路',
      );
      expect(starter.calls, isEmpty);
    });
  });

  // -------------------------------------------------------------- 建议安装位置

  group('建议的用户目录安装位置', () {
    test('Windows：优先 %LOCALAPPDATA%，拿不到时退回用户主目录', () {
      expect(
        suggestedUserInstallDir(
          TargetPlatform.windows,
          environment: <String, String>{
            'LOCALAPPDATA': r'C:\Users\me\AppData\Local',
          },
        ),
        r'C:\Users\me\AppData\Local\Programs\XVPN',
      );
      expect(
        suggestedUserInstallDir(
          TargetPlatform.windows,
          environment: <String, String>{'USERPROFILE': r'C:\Users\me'},
        ),
        r'C:\Users\me\AppData\Local\Programs\XVPN',
      );
      expect(
        suggestedUserInstallDir(
          TargetPlatform.windows,
          environment: const <String, String>{},
        ),
        contains('%LOCALAPPDATA%'),
        reason: '一个变量都拿不到时也要说清是哪个目录，而不是给一条空路径',
      );
    });

    test('Linux：用 ~/.local/opt 下的用户级位置', () {
      expect(
        suggestedUserInstallDir(
          TargetPlatform.linux,
          environment: <String, String>{'HOME': '/home/me'},
        ),
        '/home/me/.local/opt/xvpn',
      );
      expect(
        suggestedUserInstallDir(
          TargetPlatform.linux,
          environment: const <String, String>{},
        ),
        '~/.local/opt/xvpn',
      );
    });
  });

  // -------------------------------------------------------------- MSIX 与绿色版

  group('MSIX 版与绿色解压版', () {
    test('按可执行文件所在位置判断是不是 MSIX 安装', () {
      // MSIX 的应用装在 %ProgramFiles%\WindowsApps\<包名>_<版本>_<架构>__<哈希>\
      // 下，绿色解压版是用户自己挑的目录——只需要一个路径判断，不必再加一条
      // 要与原生同步维护的平台通道。
      expect(
        isMsixInstall(
          r'C:\Program Files\WindowsApps\XVPN_1.4.0.0_x64__abc123\xvpn.exe',
        ),
        isTrue,
      );
      expect(isMsixInstall(r'C:\Users\me\Downloads\XVPN\xvpn.exe'), isFalse);
      // 路径由系统给出，大小写与分隔符都不该影响结论。
      expect(
        isMsixInstall(r'c:/program files/windowsapps/XVPN/xvpn.exe'),
        isTrue,
      );
    });

    test('只有 Windows 的绿色版才需要提前说清配置目录会变', () {
      final note = preInstallNoteFor(
        TargetPlatform.windows,
        r'C:\Users\me\Downloads\XVPN\xvpn.exe',
      );
      expect(note, isNotNull);
      // 这句话的全部意义：事后再说，用户看到的是一个配置空空的新版本，只会以为
      // 更新把他的数据弄丢了。
      expect(note, contains('MSIX'));
      expect(note, contains('配置目录'));
      expect(note, contains('重新导入'));

      // MSIX 版升级到 MSIX 版：包身份相同，配置目录不变，没什么要提前说的。
      expect(
        preInstallNoteFor(
          TargetPlatform.windows,
          r'C:\Program Files\WindowsApps\XVPN_1.0.0.0_x64__a\xvpn.exe',
        ),
        isNull,
      );
      // 其它平台没有这条形态切换。
      expect(preInstallNoteFor(TargetPlatform.linux, '/opt/xvpn/xvpn'), isNull);
      expect(
        preInstallNoteFor(TargetPlatform.android, '/data/app/xvpn'),
        isNull,
      );
    });

    test('Updater 用注入的可执行文件路径算出这句提示', () {
      Updater withExecutable(String path) => Updater(
        platform: TargetPlatform.windows,
        currentVersion: '1.0.0',
        http: _FakeHttpClient((_) => _text(200, '{}')),
        resolvedExecutable: path,
      );

      expect(
        withExecutable(r'C:\Users\me\Downloads\XVPN\xvpn.exe').preInstallNote,
        isNotNull,
      );
      expect(
        withExecutable(
          r'C:\Program Files\WindowsApps\XVPN_1.0.0.0_x64__a\xvpn.exe',
        ).preInstallNote,
        isNull,
      );
    });
  });

  // -------------------------------------------------------------- 安卓安装策略

  group('安卓安装策略', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('xvpn-android-test');
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    /// 把 `test/fixtures/` 里的**真实压缩包**按发布资产的名字放进暂存目录。
    ///
    /// 刻意用真包而不是自己拼字节：这一段的全部意义就是「从别人写出来的 zip 里
    /// 把 APK 取出来」，自己写一份 zip 再自己读证明不了这件事。
    File releaseZip({
      String from = 'android-update-deflate.zip',
      String name = 'XVPN-0.0.0-android-arm64.zip',
    }) => File('${root.path}${Platform.pathSeparator}$name')
      ..writeAsBytesSync(File('test/fixtures/$from').readAsBytesSync());

    Future<UpdateInstallResult> installWith(
      _FakeApkChannel channel, {
      File? archive,
      String version = '0.0.0',
    }) {
      final installer = AndroidUpdateInstaller(channel: channel);
      return installer.install(
        info: _infoFor(
          'XVPN-$version-android-arm64.zip',
          'https://example.net/app.zip',
          platform: UpdatePlatform.android,
          version: version,
        ),
        archive: archive ?? releaseZip(),
        stagingDir: root,
      );
    }

    test('先从 zip 里取出 APK，再交给系统安装器', () async {
      final channel = _FakeApkChannel('launched');
      final result = await installWith(channel);
      expect(result, isA<UpdateInstallStarted>());

      // 交给系统安装器的必须是**取出来的 APK**，而不是下载下来的 zip：
      // 安装器只认 APK 文件。
      final String installed = channel.paths.single;
      expect(installed, endsWith('XVPN-0.0.0-android-arm64.apk'));
      expect(
        File(installed).readAsBytesSync(),
        utf8.encode('XVPN-ANDROID-UPDATE-FIXTURE ' * 120),
      );
      // 落在压缩包**旁边**：两个路径分头去拼迟早会分叉，而系统安装器拿到的 URI
      // 必须落在 FileProvider 声明的 cache-path 之内。
      expect(File(installed).parent.path, root.path);
    });

    test('包内名字与契约不符时退回唯一的那一个 .apk', () async {
      // 上游哪天改了压缩包内部的取名方式，更新不该立刻失效。落盘的文件名取自
      // 包内条目名——系统安装器只在乎它是不是一个 APK。
      final channel = _FakeApkChannel('launched');
      final result = await installWith(
        channel,
        archive: releaseZip(from: 'android-update-renamed.zip'),
      );
      expect(result, isA<UpdateInstallStarted>());
      expect(channel.paths.single, endsWith('payload.apk'));
    });

    test('包内同时有契约名与别的 APK 时优先契约名', () async {
      final channel = _FakeApkChannel('launched');
      final result = await installWith(
        channel,
        archive: releaseZip(from: 'android-update-two-apks.zip'),
      );
      expect(result, isA<UpdateInstallStarted>());
      expect(channel.paths.single, endsWith('XVPN-0.0.0-android-arm64.apk'));
    });

    test('包里没有 APK 时如实失败，而不是交给安装器一个空文件', () async {
      final channel = _FakeApkChannel('launched');
      final result = await installWith(
        channel,
        archive: releaseZip(from: 'android-update-no-apk.zip'),
      );
      expect(result, isA<UpdateInstallFailure>());
      final message = (result as UpdateInstallFailure).message;
      expect(message, contains('APK'));
      // 失败也要给一条真实可走的路：发布页还能手动下载。
      expect(message, contains('发布页'));
      expect(channel.paths, isEmpty, reason: '没有 APK 就没有什么可交给系统安装器');
    });

    test('包里有两个 APK 又对不上契约名时明确失败，而不是随便挑一个', () async {
      final channel = _FakeApkChannel('launched');
      final result = await installWith(
        channel,
        archive: releaseZip(from: 'android-update-two-apks.zip'),
        // 版本号对不上，契约名也就不匹配：两个 `.apk` 条目都不是它。
        version: '9.9.9',
      );
      expect(result, isA<UpdateInstallFailure>());
      final message = (result as UpdateInstallFailure).message;
      expect(message, contains('2 个APK'));
      // 报错要把两个候选名都写出来，用户才知道包里被塞了什么。
      expect(message, contains('XVPN-0.0.0-android-arm64.apk'));
      expect(message, contains('payload.apk'));
      expect(channel.paths, isEmpty);
    });

    test('下载到的不是 zip 时给一句用户看得懂的话', () async {
      final channel = _FakeApkChannel('launched');
      final bad = File('${root.path}${Platform.pathSeparator}bad.zip')
        ..writeAsStringSync('<html>404</html>');
      final result = await installWith(channel, archive: bad);

      expect(result, isA<UpdateInstallFailure>());
      final message = (result as UpdateInstallFailure).message;
      expect(message, contains('无法解出安装文件'));
      expect(message, contains('发布页'));
      // 不能把 Dart 的异常字符串直接甩给用户。
      expect(message, isNot(contains('Exception')));
      expect(channel.paths, isEmpty);
    });

    test('缺少「安装未知应用」权限时引导去设置并如实报告', () async {
      final result = await installWith(_FakeApkChannel('permission_required'));
      expect(result, isA<UpdateInstallPermissionRequired>());
      expect(
        (result as UpdateInstallPermissionRequired).message,
        contains('未知应用'),
      );
    });

    test('原生返回未知状态或报错时不静默成功', () async {
      final unknown = await installWith(_FakeApkChannel(null));
      expect(unknown, isA<UpdateInstallFailure>());

      final failed = _FakeApkChannel('launched')
        ..error = PlatformException(code: 'launch_failed', message: '没有安装器');
      final error = await installWith(failed);
      expect(error, isA<UpdateInstallFailure>());
      expect((error as UpdateInstallFailure).message, contains('安装器'));
    });

    test('更新包不存在时直接失败', () async {
      final installer = AndroidUpdateInstaller(
        channel: _FakeApkChannel('launched'),
      );
      final result = await installer.install(
        info: _infoFor(
          'XVPN-0.0.0-android-arm64.zip',
          'https://example.net/app.zip',
          platform: UpdatePlatform.android,
          version: '0.0.0',
        ),
        archive: File('${root.path}${Platform.pathSeparator}nope.zip'),
        stagingDir: root,
      );
      expect(result, isA<UpdateInstallFailure>());
      expect((result as UpdateInstallFailure).message, contains('不存在'));
    });
  });

  // -------------------------------------------------------------- 取出 APK

  group('extractAndroidApk', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('xvpn-extract-apk-test');
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    File asset({String from = 'android-update-deflate.zip'}) => File(
      '${root.path}${Platform.pathSeparator}XVPN-0.0.0-android-arm64.zip',
    )..writeAsBytesSync(File('test/fixtures/$from').readAsBytesSync());

    test('APK 落在压缩包旁边，文件名就是契约里的名字', () async {
      final File archive = asset();
      final File apk = await extractAndroidApk(
        archive: archive,
        version: '0.0.0',
      );
      expect(
        apk.path,
        '${root.path}${Platform.pathSeparator}XVPN-0.0.0-android-arm64.apk',
      );
      expect(
        apk.readAsBytesSync(),
        utf8.encode('XVPN-ANDROID-UPDATE-FIXTURE ' * 120),
      );
    });

    test('包内名字对不上时返回包内那一个 .apk', () async {
      final File apk = await extractAndroidApk(
        archive: asset(from: 'android-update-renamed.zip'),
        version: '0.0.0',
      );
      expect(apk.path, '${root.path}${Platform.pathSeparator}payload.apk');
    });

    test('既没有契约名也没有别的 APK 时抛出可展示的异常', () async {
      await expectLater(
        extractAndroidApk(
          archive: asset(from: 'android-update-no-apk.zip'),
          version: '0.0.0',
        ),
        throwsA(
          isA<ZipFormatException>().having(
            (ZipFormatException e) => e.message,
            'message',
            contains('没有APK'),
          ),
        ),
      );
    });
  });

  // -------------------------------------------------------------- 暂存目录与地址

  group('暂存目录与仓库地址', () {
    test('安卓暂存在 /updates 之下（FileProvider 的 cache-path 契约）', () {
      expect(
        defaultUpdateStagingDir(
          TargetPlatform.android,
          tempPath: '/data/user/0/net.lusida.xvpnclient/cache',
        ).path,
        '/data/user/0/net.lusida.xvpnclient/cache/updates',
      );
    });

    test('桌面暂存在系统临时目录下的 xvpn-update', () {
      expect(
        defaultUpdateStagingDir(
          TargetPlatform.windows,
          tempPath: r'C:\Temp',
        ).path,
        r'C:\Temp\xvpn-update',
      );
      expect(
        defaultUpdateStagingDir(
          TargetPlatform.linux,
          tempPath: '/tmp',
        ).path,
        '/tmp/xvpn-update',
      );
    });

    test('仓库地址解析成 API 地址', () {
      final repo = parseGitHubRepo('https://github.com/LSD-Apps/XVPN');
      expect(repo, isNotNull);
      expect(repo!.owner, 'LSD-Apps');
      expect(repo.repo, 'XVPN');
      expect(parseGitHubRepo('https://example.net/only-one'), isNull);
      expect(
        latestReleaseApiUri().toString(),
        'https://api.github.com/repos/LSD-Apps/XVPN/releases/latest',
      );
    });

    test('插件未接入的平台落到「不支持」安装策略', () {
      expect(
        defaultUpdateInstaller(TargetPlatform.macOS),
        isA<UnsupportedUpdateInstaller>(),
      );
    });
  });
}
