import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/sha256.dart';
import 'package:xvpn/core/updater.dart';

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
          'name': 'XVPN-1.1.0-windows-x64.zip',
          'browser_download_url': 'https://example.net/win.zip',
          'size': 1024,
        },
        <String, Object?>{
          'name': 'XVPN-1.1.0-linux-x64.zip',
          'browser_download_url': 'https://example.net/linux.zip',
          'size': 2048,
        },
        <String, Object?>{
          'name': 'XVPN-1.1.0-android-arm64.apk',
          'browser_download_url': 'https://example.net/app.apk',
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
      expect(
        expectedAssetName(UpdatePlatform.windows, '1.1.0'),
        'XVPN-1.1.0-windows-x64.zip',
      );
      expect(
        expectedAssetName(UpdatePlatform.linux, '1.1.0'),
        'XVPN-1.1.0-linux-x64.zip',
      );
      expect(
        expectedAssetName(UpdatePlatform.android, '1.1.0'),
        'XVPN-1.1.0-android-arm64.apk',
      );
    });

    test('安卓优先裸 APK，且不会退回 zip', () {
      final release = ReleaseInfo.tryParse(
        _releaseJson(
          assets: <Map<String, Object?>>[
            <String, Object?>{
              'name': 'XVPN-1.1.0-android-arm64.apk',
              'browser_download_url': 'https://example.net/app.apk',
            },
            <String, Object?>{
              'name': 'XVPN-1.1.0-android-arm64.zip',
              'browser_download_url': 'https://example.net/app.zip',
            },
          ],
        ),
      )!;
      final apk = selectAsset(
        release.assets,
        UpdatePlatform.android,
        release.version,
      );
      expect(apk!.name, 'XVPN-1.1.0-android-arm64.apk');

      // 只有 zip 时不能退回：系统安装器只接受 APK 文件。
      final onlyZip = <ReleaseAsset>[
        ReleaseAsset(
          name: 'XVPN-1.1.0-android-arm64.zip',
          downloadUrl: Uri.parse('https://example.net/app.zip'),
        ),
      ];
      expect(
        selectAsset(onlyZip, UpdatePlatform.android, '1.1.0'),
        isNull,
      );
    });

    test('找不到精确名字时按后缀近似匹配', () {
      final assets = <ReleaseAsset>[
        ReleaseAsset(
          name: 'XVPN-1.2.0-windows-x64.zip',
          downloadUrl: Uri.parse('https://example.net/custom.zip'),
        ),
      ];
      expect(
        selectAsset(assets, UpdatePlatform.windows, '1.1.0')!.name,
        'XVPN-1.2.0-windows-x64.zip',
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
        '$hashA  XVPN-1.1.0-windows-x64.zip\r\n'
        '$hashB *XVPN-1.1.0-linux-x64.zip\n'
        '# 注释行\n'
        '\n',
      );
      expect(sums['XVPN-1.1.0-windows-x64.zip'], hashA);
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
              'name': 'XVPN-1.1.0-windows-x64.zip',
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
      expect(info.assetName, 'XVPN-1.1.0-windows-x64.zip');
      expect(info.assetUri.toString(), 'https://example.net/win.zip');
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
        contains('android-arm64.apk'),
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
              'name': 'XVPN-1.1.0-windows-x64.zip',
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
              'name': 'XVPN-1.1.0-windows-x64.zip',
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
      final name = 'XVPN-1.1.0-windows-x64.zip';
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
      final name = 'XVPN-1.1.0-windows-x64.zip';
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
      final name = 'XVPN-1.1.0-windows-x64.zip';
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
        _infoFor('XVPN-1.1.0-windows-x64.zip', 'https://example.net/win.zip'),
      );
      expect(result, isA<UpdateDownloadFailure>());
      expect((result as UpdateDownloadFailure).message, contains('无法解析'));
      // 只请求了校验文件，没有下载安装包。
      expect(http.requested, hasLength(1));
    });

    test('下载失败时不留半成品', () async {
      final name = 'XVPN-1.1.0-windows-x64.zip';
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
      final name = 'XVPN-1.1.0-windows-x64.zip';
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
        _infoFor('XVPN-1.1.0-windows-x64.zip', 'https://example.net/win.zip'),
        cancellation: cancellation,
      );
      expect(result, isA<UpdateDownloadCancelled>());
      expect(http.requested, isEmpty);
    });
  });

  // -------------------------------------------------------------- 脚本生成

  group('安装脚本生成', () {
    test('Windows：等待退出 → 解压 → 覆盖 → 重启，且路径被单引号包裹', () {
      const archive =
          r"C:\Program Files\XVPN\Bob's updates\XVPN-1.1.0-windows-x64.zip";
      const staging = r"C:\Users\me\AppData\Local\Temp\XVPN's update";
      const install = r'C:\Program Files\XVPN';
      const launch = r'C:\Program Files\XVPN\xvpn.exe';

      final script = buildWindowsRelaunchScript(
        pid: 4321,
        archivePath: archive,
        stagingDir: staging,
        installDir: install,
        launchPath: launch,
      );

      // 带空格的路径必须整体被引号包住；路径里的单引号按 PowerShell 规则翻倍。
      expect(
        script,
        contains(
          r"'C:\Program Files\XVPN\Bob''s updates\XVPN-1.1.0-windows-x64.zip'",
        ),
      );
      expect(script, contains(r"'C:\Program Files\XVPN'"));
      expect(script, contains('Wait-Process -Id 4321'));
      expect(script, contains('Expand-Archive -LiteralPath'));
      expect(script, contains('Copy-Item -Path'));
      expect(script, contains('Start-Process -FilePath'));

      final waitIndex = script.indexOf('Wait-Process -Id 4321');
      final extractIndex = script.indexOf('Expand-Archive -LiteralPath');
      final copyIndex = script.indexOf('Copy-Item -Path');
      final startIndex = script.indexOf('Start-Process -FilePath');
      expect(waitIndex, lessThan(extractIndex));
      expect(extractIndex, lessThan(copyIndex));
      expect(copyIndex, lessThan(startIndex));
    });

    test('Windows：不提权时不出现任何 UAC 痕迹', () {
      final script = buildWindowsRelaunchScript(
        pid: 7,
        archivePath: r'C:\a b\x.zip',
        stagingDir: r'C:\a b\stage',
        installDir: r'C:\Program Files\XVPN',
        launchPath: r'C:\Program Files\XVPN\xvpn.exe',
      );

      expect(script, isNot(contains('RunAs')));
      expect(
        script,
        contains('Copy-Item -Path'),
        reason: '不需要提权时，复制仍由助手自己完成',
      );
    });

    test('Windows：提权时只把复制交给管理员，重启仍是普通权限', () {
      const staging = r'C:\Users\Zhang San\AppData\Local\Temp\xvpn-update';
      const install = r'C:\Program Files\XVPN';
      const launch = r'C:\Program Files\XVPN\xvpn.exe';
      const copyScript =
          r'C:\Users\Zhang San\AppData\Local\Temp\xvpn-update\xvpn-elevate-copy.ps1';

      final script = buildWindowsRelaunchScript(
        pid: 99,
        archivePath: r'C:\Users\Zhang San\AppData\Local\Temp\xvpn-update\pkg.zip',
        stagingDir: staging,
        installDir: install,
        launchPath: launch,
        elevatedCopyScriptPath: copyScript,
      );

      expect(script, contains('-Verb RunAs'));
      // -Wait 才能等到复制结束并拿到退出码；-PassThru 才能读到它。
      expect(script, contains('-Wait -PassThru'));
      // 提权复制脚本的路径带空格，必须被双引号保护，否则会被拆成两个参数。
      expect(script, contains('"$copyScript"'));
      expect(
        script,
        isNot(contains('Copy-Item -Path')),
        reason: '复制已经交给管理员进程，助手自己不做',
      );

      // 最关键的一条：**重启那一步不能带 RunAs**。带了的话用户拿到的 XVPN 是
      // 管理员身份；若 UAC 是由另一个管理员账户确认的，读到的就是那个账户的
      // 配置目录，看起来像「所有配置都不见了」。
      final restartBlock = script.substring(
        script.indexOf("Write-Log '重新启动'"),
      );
      expect(restartBlock, isNot(contains('RunAs')));
      expect(restartBlock, contains("Start-Process -FilePath '$launch'"));
      expect(restartBlock, contains("'$install'"));
    });

    test('Windows：提权复制脚本只复制、不重启', () {
      final script = buildWindowsElevatedCopyScript(
        stagingDir: r'C:\a b\stage',
        installDir: r'C:\Program Files\XVPN',
      );

      expect(script, contains('Copy-Item -Path'));
      expect(script, contains(r"'C:\Program Files\XVPN'"));
      // 失败必须以非零退出码收场：助手据此判定「没成功」，不装作更新好了。
      expect(script, contains('exit 0'));
      expect(script, contains('exit 1'));
      expect(
        script,
        isNot(contains('Start-Process')),
        reason: '它必须只做复制：重启由非提权的助手负责，否则 XVPN 会以管理员身份运行',
      );
    });

    test('Windows：解压结果里没有 xvpn.exe 时不动原安装', () {      final script = buildWindowsRelaunchScript(
        pid: 1,
        archivePath: r'C:\a b\x.zip',
        stagingDir: r'C:\a b\stage',
        installDir: r'C:\a b\install',
        launchPath: r'C:\a b\install\xvpn.exe',
      );
      // 覆盖动作必须在「确认存在 xvpn.exe」之后。
      final guardIndex = script.indexOf("Join-Path");
      final copyIndex = script.indexOf('Copy-Item -Path');
      expect(guardIndex, lessThan(copyIndex));
      expect(script, contains("throw '解压结果里没有 xvpn.exe，已取消替换'"));
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

    test('Windows：成功才删安装包，失败必须留着它', () {
      const archive = r'C:\stage\pkg.zip';
      const staging = r'C:\stage';
      final script = buildWindowsRelaunchScript(
        pid: 5,
        archivePath: archive,
        stagingDir: staging,
        installDir: r'C:\Program Files\XVPN',
        launchPath: r'C:\Program Files\XVPN\xvpn.exe',
      );

      // 只有走到「重新启动」之后才把 ok 置真；清理逻辑据此分流。
      final relaunchIndex = script.indexOf("Write-Log '重新启动'");
      final okIndex = script.indexOf(r'$ok = $true');
      expect(relaunchIndex, lessThan(okIndex), reason: '成功标志必须在重启之后才置位');

      final finallyBlock = script.substring(script.indexOf('} finally {'));
      expect(
        finallyBlock,
        contains(r'if ($ok) {'),
        reason: '清理必须按成功/失败分流',
      );
      // 失败分支要保留安装包并记下它，让用户还能重试或自行解压覆盖。
      expect(finallyBlock, contains('已保留安装包：'));
      // 提权路径上用户点「否」时，日志是事后唯一能查到原因的入口。
      expect(finallyBlock, contains('日志：'));
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
      final archive = File('${root.path}${separator}XVPN-1.1.0-windows-x64.zip')
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
          'XVPN-1.1.0-windows-x64.zip',
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
      final copy = File('$staging$separator$elevatedCopyScriptName.ps1');
      Directory(staging).createSync(recursive: true);

      final relaunch = File('$staging$separator$relaunchScriptName.ps1')
        ..writeAsStringSync(
          '\uFEFF${buildWindowsRelaunchScript(
            pid: 1234,
            archivePath: "$staging${separator}pkg.zip",
            stagingDir: staging,
            installDir: install,
            launchPath: '$install${separator}xvpn.exe',
            elevatedCopyScriptPath: copy.path,
          )}',
          flush: true,
        );
      copy.writeAsStringSync(
        '\uFEFF${buildWindowsElevatedCopyScript(stagingDir: staging, installDir: install)}',
        flush: true,
      );

      for (final script in <File>[relaunch, copy]) {
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
      }

      // 顺带确认「提权复制脚本被真的指向了」，并把引号规则写清楚：
      // 单引号内的单引号按 PowerShell 规则翻倍，整体再套一层双引号保护空格。
      // 少任何一层，Start-Process 都会收到一个截断的路径。
      final quotedCopyPath = '"${copy.path.replaceAll("'", "''")}"';
      expect(
        relaunch.readAsStringSync(),
        contains("-File','$quotedCopyPath'"),
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
          'XVPN-1.1.0-windows-x64.zip',
          'https://example.net/win.zip',
        ),
        archive: File('${root.path}${separator}nope.zip'),
        stagingDir: root,
      );
      expect(result, isA<UpdateInstallFailure>());
      expect((result as UpdateInstallFailure).message, contains('更新包不存在'));
    });

    test('安装目录不存在时拒绝而不是破坏安装', () async {
      final separator = Platform.pathSeparator;
      final installer = DesktopUpdateInstaller(
        platform: TargetPlatform.windows,
        installDir: Directory('${root.path}${separator}not-here'),
        launchPath: r'C:\nope\xvpn.exe',
        processStarter: _RecordingStarter(),
        hostPid: 1,
      );
      final result = await installer.install(
        info: _infoFor(
          'XVPN-1.1.0-windows-x64.zip',
          'https://example.net/win.zip',
        ),
        archive: File('${root.path}${separator}a.zip')..writeAsBytesSync(<int>[1]),
        stagingDir: root,
      );
      expect(result, isA<UpdateInstallFailure>());
      expect((result as UpdateInstallFailure).message, contains('找不到安装目录'));
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
          'XVPN-1.1.0-windows-x64.zip',
          'https://example.net/win.zip',
        ),
        archive: File('${root.path}${separator}a.zip')..writeAsBytesSync(<int>[1]),
        stagingDir: root,
      );
      expect(result, isA<UpdateInstallFailure>());
      expect((result as UpdateInstallFailure).message, contains('手动解压'));
    });

    // ---------------------------------------------------------- 受保护安装目录
    //
    // 「装在 C:\Program Files」是自动更新唯一需要提权的场景。真实的受保护目录
    // 在测试里造不出来（Windows 上要管理员才能改 ACL），因此用探测替身表达。

    /// 造一个「安装目录写不进去」的安装器。
    DesktopUpdateInstaller protectedInstaller({
      required Directory installDir,
      required _RecordingStarter starter,
      TargetPlatform platform = TargetPlatform.windows,
    }) => DesktopUpdateInstaller(
      platform: platform,
      installDir: installDir,
      launchPath: '${installDir.path}${Platform.pathSeparator}xvpn.exe',
      processStarter: starter,
      hostPid: 1,
      writabilityProbe: (Directory _) => false,
    );

    File archiveIn(String separator) =>
        File('${root.path}${separator}a.zip')..writeAsBytesSync(<int>[1]);

    test('Windows：受保护目录先征求同意，未经同意不启动任何东西', () async {
      final separator = Platform.pathSeparator;
      final installDir = Directory('${root.path}${separator}install')
        ..createSync(recursive: true);
      final starter = _RecordingStarter();
      final installer = protectedInstaller(
        installDir: installDir,
        starter: starter,
      );

      final result = await installer.install(
        info: _infoFor('XVPN-1.1.0-windows-x64.zip', 'https://example.net/win.zip'),
        archive: archiveIn(separator),
        stagingDir: root,
      );

      expect(result, isA<UpdateInstallElevationRequired>());
      final required = result as UpdateInstallElevationRequired;
      expect(required.message, contains('管理员权限'));
      expect(
        required.suggestedDir,
        isNotNull,
        reason: '要给出一条「以后不必再授权」的出路，而不是每次都弹 UAC',
      );
      expect(
        starter.calls,
        isEmpty,
        reason: '用户还没同意，一个进程都不该启动（UAC 更不能自己弹）',
      );
      expect(
        File('${root.path}${separator}xvpn-relaunch.ps1').existsSync(),
        isFalse,
      );
    });

    test('Windows：同意后写出两个脚本，助手带上提权复制', () async {
      final separator = Platform.pathSeparator;
      final installDir = Directory('${root.path}${separator}install')
        ..createSync(recursive: true);
      final starter = _RecordingStarter();
      final installer = protectedInstaller(
        installDir: installDir,
        starter: starter,
      );

      final result = await installer.install(
        info: _infoFor('XVPN-1.1.0-windows-x64.zip', 'https://example.net/win.zip'),
        archive: archiveIn(separator),
        stagingDir: root,
        elevate: true,
      );

      expect(result, isA<UpdateInstallStarted>());
      expect(
        (result as UpdateInstallStarted).message,
        contains('管理员授权'),
        reason: '文案必须说清楚「授权后才会动手」，否则用户以为更新已经在跑',
      );

      final relaunch = File('${root.path}${separator}xvpn-relaunch.ps1');
      final copy = File('${root.path}${separator}xvpn-elevate-copy.ps1');
      expect(relaunch.existsSync(), isTrue);
      expect(copy.existsSync(), isTrue);
      expect(relaunch.readAsStringSync(), contains('-Verb RunAs'));
      // 提权复制脚本同样要带 BOM：PowerShell 5.1 没有它会按 ANSI 读，中文日志
      // 会变成乱码——而用户要读的正是那些中文。
      expect(copy.readAsBytesSync().sublist(0, 3), <int>[0xEF, 0xBB, 0xBF]);
      expect(starter.calls.single, contains('-File'));
      expect(starter.calls.single.last, contains('xvpn-relaunch.ps1'));
    });

    test('Windows：目录其实可写时，用户点过同意也不弹 UAC', () async {
      // 场景：上一次点了「以管理员身份更新」，之后把安装目录搬到了用户目录。
      // 此时仍然提权就是纯粹的打扰——探测说可写就走普通路径。
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
        writabilityProbe: (Directory _) => true,
      );

      final result = await installer.install(
        info: _infoFor('XVPN-1.1.0-windows-x64.zip', 'https://example.net/win.zip'),
        archive: archiveIn(separator),
        stagingDir: root,
        elevate: true,
      );

      expect(result, isA<UpdateInstallStarted>());
      final relaunch = File('${root.path}${separator}xvpn-relaunch.ps1');
      expect(relaunch.readAsStringSync(), isNot(contains('RunAs')));
      expect(
        File('${root.path}${separator}xvpn-elevate-copy.ps1').existsSync(),
        isFalse,
        reason: '一个用不上的提权脚本会让人以为提权路径被走过了',
      );
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
        platform: TargetPlatform.linux,
      );

      final result = await installer.install(
        info: _infoFor('XVPN-1.1.0-linux-x64.zip', 'https://example.net/lin.zip'),
        archive: archiveIn(separator),
        stagingDir: root,
        elevate: true,
      );

      expect(
        result,
        isA<UpdateInstallFailure>(),
        reason: 'Linux 上即便用户要求提权也不做——那是包管理器的地盘',
      );
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

  // -------------------------------------------------------------- 安卓安装策略

  group('安卓安装策略', () {
    late Directory root;
    late File apk;

    setUp(() {
      root = Directory.systemTemp.createTempSync('xvpn-android-test');
      apk = File('${root.path}${Platform.pathSeparator}XVPN-1.1.0-android-arm64.apk')
        ..writeAsBytesSync(<int>[1, 2, 3]);
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    Future<UpdateInstallResult> installWith(_FakeApkChannel channel) {
      final installer = AndroidUpdateInstaller(channel: channel);
      return installer.install(
        info: _infoFor(
          'XVPN-1.1.0-android-arm64.apk',
          'https://example.net/app.apk',
          platform: UpdatePlatform.android,
        ),
        archive: apk,
        stagingDir: root,
      );
    }

    test('交给系统安装器', () async {
      final channel = _FakeApkChannel('launched');
      final result = await installWith(channel);
      expect(result, isA<UpdateInstallStarted>());
      expect(channel.paths.single, apk.path);
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

    test('APK 不存在时直接失败', () async {
      final installer = AndroidUpdateInstaller(
        channel: _FakeApkChannel('launched'),
      );
      final result = await installer.install(
        info: _infoFor(
          'XVPN-1.1.0-android-arm64.apk',
          'https://example.net/app.apk',
          platform: UpdatePlatform.android,
        ),
        archive: File('${root.path}${Platform.pathSeparator}nope.apk'),
        stagingDir: root,
      );
      expect(result, isA<UpdateInstallFailure>());
      expect((result as UpdateInstallFailure).message, contains('不存在'));
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
