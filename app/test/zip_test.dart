import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/zip.dart';

/// `core/zip.dart` 的测试。
///
/// 全部对着 `test/fixtures/` 里**真实压缩工具产出的包**，而不是自己拼出来的
/// 字节：自己写一份 zip 再自己读，只能证明「自己和自己一致」，而这个读取器要
/// 面对的恰恰是别人写出来的字节。夹具用了两个不同的写入器——.NET 的
/// `ZipArchive`（`Compress-Archive` 背后的那个）与 libarchive 的 `bsdtar`——
/// 顺带避免「只认得某一家布局」这种自欺；CI 上的 `zip -q` 写出的也是同一套
/// 结构（中央目录 + 条目，deflate 或不压缩）。

/// 夹具里那一个条目：名字就是发布契约里的 APK 名。
const String _entryName = 'XVPN-0.0.0-android-arm64.apk';

/// 条目内容：一行文本重复 120 次。
///
/// 刻意用重复内容而不是随机字节：重复才会让 deflate 真的用到长度/距离码，
/// 这样「解得对」在 deflate 路径上才有意义（只写字面量的流走不到那段解码）。
final String _content = 'XVPN-ANDROID-UPDATE-FIXTURE ' * 120;

/// 两个夹具，**压缩方法各一种**：
///
///   * `-deflate.zip`：.NET `ZipArchive` 写出，方法 8，数据段真的被压缩过
///     （208 字节装下 3360 字节）；
///   * `-stored.zip`：`bsdtar --options zip:compression=store` 写出，方法 0，
///     数据段原样存放。
///
/// 两条路都必须能走：CI 的 `zip -q` 产出 deflate 条目，而「不压缩」是 ZIP 的
/// 另一半——某些打包工具（以及已经压过的内容）会直接选它。
const List<String> _fixtures = <String>[
  'android-update-deflate.zip',
  'android-update-stored.zip',
];

File _fixture(String name) => File('test/fixtures/$name');

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('xvpn-zip-test');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  File destination(String name) =>
      File('${root.path}${Platform.pathSeparator}$name');

  /// 把 [source] 复制到 [root] 下，并翻转**数据段正中间**的那个字节。
  ///
  /// 刻意**不修**中央目录里的 CRC：要证明的正是「读取器不信压缩包自己写的
  /// 记录，而是真的解出来再算一遍」。
  File corruptPayload(File source) {
    final ZipEntry entry = readZipEntries(source).single;
    final List<int> bytes = source.readAsBytesSync();
    // 数据起点必须按**本地头**算，不能拿中央目录里的长度凑：两者是独立记录，
    // 名字与扩展区的长度都可能不同。
    final int localNameLength =
        bytes[entry.localHeaderOffset + 26] |
        (bytes[entry.localHeaderOffset + 27] << 8);
    final int localExtraLength =
        bytes[entry.localHeaderOffset + 28] |
        (bytes[entry.localHeaderOffset + 29] << 8);
    final int dataStart =
        entry.localHeaderOffset + 30 + localNameLength + localExtraLength;
    final int middle = dataStart + entry.compressedSize ~/ 2;
    bytes[middle] = bytes[middle] ^ 0xff;
    return destination('corrupt-${source.uri.pathSegments.last}')
      ..writeAsBytesSync(bytes);
  }

  group('真实压缩包', () {
    test('两个夹具分别覆盖不压缩与 deflate 两条解码路径', () {
      // 这条断言的价值不在读取器，而在**夹具本身**：哪一天有人把 `-stored` 换成
      // 另一个 deflate 包，上面那些「两种写法都解得对」就会变成同一条路径跑两遍，
      // 而测试仍然全绿——覆盖率悄悄少了一半。
      expect(
        readZipEntries(_fixture('android-update-deflate.zip'))
            .single
            .compressionMethod,
        8,
        reason: 'deflate 夹具必须是压缩条目',
      );
      expect(
        readZipEntries(_fixture('android-update-stored.zip'))
            .single
            .compressionMethod,
        0,
        reason: 'stored 夹具必须是不压缩条目（方法 0）',
      );
    });

    test('两个夹具都只列出契约里的那一个条目', () {
      for (final String name in _fixtures) {
        final List<ZipEntry> entries = readZipEntries(_fixture(name));
        expect(entries, hasLength(1), reason: name);
        expect(entries.single.name, _entryName, reason: name);
        expect(entries.single.isDirectory, isFalse, reason: name);
        // 尺寸以中央目录为准，读者据此知道自己该解出多少字节。
        expect(
          entries.single.uncompressedSize,
          utf8.encode(_content).length,
          reason: name,
        );
      }
    });

    test('两种写法的包都逐字节解出同样的内容', () async {
      for (final String name in _fixtures) {
        final File archive = _fixture(name);
        final File target = destination('$name.apk');
        await extractZipEntry(
          archive: archive,
          entry: readZipEntries(archive).single,
          destination: target,
        );
        expect(target.readAsBytesSync(), utf8.encode(_content), reason: name);
      }
    });

    test('目标文件已存在时覆盖它', () async {
      final File archive = _fixture('android-update-deflate.zip');
      // 先放一个更长、内容不同的文件：如果解压是「追加」或「不覆盖」，这里就会
      // 露出旧内容的尾巴。
      final File target = destination('existing.apk')
        ..writeAsStringSync(List<String>.filled(4096, '旧').join());
      await extractZipEntry(
        archive: archive,
        entry: readZipEntries(archive).single,
        destination: target,
      );
      expect(target.readAsBytesSync(), utf8.encode(_content));
    });

    test('singleZipEntry 能从真实条目里挑出唯一的那一个', () {
      for (final String name in _fixtures) {
        final ZipEntry entry = singleZipEntry(
          readZipEntries(_fixture(name)),
          (String candidate) => candidate.toLowerCase().endsWith('.apk'),
          what: 'APK',
        );
        expect(entry.name, _entryName, reason: name);
      }
    });
  });

  group('坏包必须被拒绝', () {
    test('截断的包抛出 ZipFormatException', () {
      final List<int> bytes = _fixture(
        'android-update-deflate.zip',
      ).readAsBytesSync();
      // 砍掉结尾：中央目录结束记录随之消失。
      final File truncated = destination('truncated.zip')
        ..writeAsBytesSync(bytes.sublist(0, bytes.length - 20));
      expect(
        () => readZipEntries(truncated),
        throwsA(isA<ZipFormatException>()),
      );
    });

    test('根本不是 zip 的文件抛出 ZipFormatException', () {
      final File text = destination('not-a-zip.zip')
        ..writeAsStringSync('<html>404</html>');
      expect(() => readZipEntries(text), throwsA(isA<ZipFormatException>()));

      // 比 EOCD 还短的输入同样要被当成坏包，而不是越界读。
      final File tiny = destination('tiny.zip')..writeAsBytesSync(<int>[0x50]);
      expect(() => readZipEntries(tiny), throwsA(isA<ZipFormatException>()));
    });

    test('数据段被改坏的包由 CRC-32 拦下', () async {
      // 只改字节、不改中央目录里记录的 CRC：这正是「下载没坏但解错了」的形态
      //（偏移算错、压缩方法判断错），文件整体的 SHA-256 对此无能为力。
      for (final String name in _fixtures) {
        final File corrupt = corruptPayload(_fixture(name));
        await expectLater(
          extractZipEntry(
            archive: corrupt,
            entry: readZipEntries(corrupt).single,
            destination: destination('corrupt.out'),
          ),
          throwsA(
            isA<ZipFormatException>().having(
              (ZipFormatException error) => error.message,
              'message',
              contains('校验失败'),
            ),
          ),
          reason: name,
        );
      }
    });
  });

  group('singleZipEntry 的取舍', () {
    ZipEntry entry(String name) => ZipEntry(
      name: name,
      compressionMethod: 8,
      crc32: 0,
      compressedSize: 0,
      uncompressedSize: 0,
      localHeaderOffset: 0,
    );

    bool isApk(String name) => name.toLowerCase().endsWith('.apk');

    test('一个都没匹配上时报错', () {
      expect(
        () => singleZipEntry(
          <ZipEntry>[entry('readme.txt')],
          isApk,
          what: 'APK',
        ),
        throwsA(
          isA<ZipFormatException>().having(
            (ZipFormatException error) => error.message,
            'message',
            contains('没有APK'),
          ),
        ),
      );
      expect(
        () => singleZipEntry(const <ZipEntry>[], isApk, what: 'APK'),
        throwsA(isA<ZipFormatException>()),
      );
    });

    test('匹配到两个时报错并列出它们，而不是猜一个', () {
      // 包里出现两个 APK 意味着被塞进了别的东西，此时猜哪一个都是错的。
      expect(
        () => singleZipEntry(
          <ZipEntry>[entry('a.apk'), entry('b.apk')],
          isApk,
          what: 'APK',
        ),
        throwsA(
          isA<ZipFormatException>().having(
            (ZipFormatException error) => error.message,
            'message',
            allOf(contains('2 个APK'), contains('a.apk'), contains('b.apk')),
          ),
        ),
      );
    });

    test('目录条目不算匹配', () {
      // 目录条目（名字以 `/` 结尾）没有内容；把它当成「那个文件」会解出 0 字节，
      // 而且系统安装器拿到的是一个空文件。
      expect(
        () => singleZipEntry(
          <ZipEntry>[entry('apk/')],
          (String name) => name.contains('apk'),
          what: 'APK',
        ),
        throwsA(isA<ZipFormatException>()),
      );
    });
  });
}
