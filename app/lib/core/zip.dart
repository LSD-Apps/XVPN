/// 纯 Dart 的最小 ZIP 读取器：只做「列出条目」与「取出其中一个」两件事。
///
/// 为什么自己写、而不是引入 `archive`：与 `core/sha256.dart` 同一条依赖纪律
/// ——本项目的依赖策略是「标准库做不了才加依赖」（见 CONTRIBUTING.md）。这里
/// 需要的全部能力是「按中央目录定位一个条目、用 inflate 解出来」，而 inflate
/// 本身**标准库就有**：`dart:io` 的 `ZLibDecoder(raw: true)` 接受的正是 ZIP
/// 条目用的裸 deflate 流。为一个定位加解压的动作引入一份需要长期跟版本的第三方
/// 代码，代价大于这里的两百行实现——它由 `test/zip_test.dart` 用**真实压缩工具
/// 产出的包**锁死。
///
/// 只支持自动更新实际会遇到的那一小撮形态（都是 `zip` / `Compress-Archive`
/// 的默认输出），其余一律**明确报错**而不是猜：
///
///   * 压缩方法只有 store(0) 与 deflate(8)；
///   * 不加密（通用位标记的 bit 0）；
///   * 不支持 ZIP64（条目超过 4 GiB / 条目数超过 65535 时报错）。
///
/// 这三点都不可能在发布流程里出现：更新包由 CI 的 `zip -q` 或本机
/// `Compress-Archive` 产出，里面的 APK 只有几十 MB。真遇到时抛
/// [ZipFormatException]，由调用方翻译成一句用户看得懂的话。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// ZIP 中央目录里的一条记录。
///
/// 尺寸一律以**中央目录**为准，而不是本地头：带数据描述符（通用位标记 bit 3）
/// 的条目在本地头里写的是 0，真正的尺寸记在数据之后的描述符里、同时也记在中央
/// 目录。只读中央目录就不必处理这两种写法。
class ZipEntry {
  const ZipEntry({
    required this.name,
    required this.compressionMethod,
    required this.crc32,
    required this.compressedSize,
    required this.uncompressedSize,
    required this.localHeaderOffset,
  });

  /// 条目名（ZIP 用 `/` 作分隔符，与宿主平台无关）。
  final String name;

  /// 0 = 不压缩，8 = deflate。
  final int compressionMethod;

  /// 未压缩数据的 CRC-32 校验值。
  final int crc32;

  final int compressedSize;
  final int uncompressedSize;

  /// 本地文件头在文件中的偏移。
  final int localHeaderOffset;

  /// 目录条目（名字以 `/` 结尾）没有内容。
  bool get isDirectory => name.endsWith('/');

  @override
  String toString() =>
      'ZipEntry($name, method=$compressionMethod, $compressedSize→$uncompressedSize)';
}

/// 压缩包结构不合法、或用了本实现不支持的形态。
///
/// [message] 是**可直接展示**的中文原因：更新失败时用户看到的就是它。
class ZipFormatException implements Exception {
  const ZipFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

const int _endOfCentralDirectorySignature = 0x06054b50;
const int _centralFileHeaderSignature = 0x02014b50;
const int _localFileHeaderSignature = 0x04034b50;

/// EOCD 固定部分 22 字节，后面最多跟 65535 字节的注释。
const int _maxEndOfCentralDirectorySearch = 22 + 0xffff;

/// 读出压缩包里的全部条目（按中央目录顺序）。
///
/// 只读中央目录，不解压任何内容——因此对几十 MB 的包也是瞬间完成，可以用来
/// 「先看一眼里面有没有我们要的那个文件」再决定是否解压。
List<ZipEntry> readZipEntries(File archive) {
  final RandomAccessFile file = archive.openSync();
  try {
    return _readEntries(file);
  } finally {
    file.closeSync();
  }
}

List<ZipEntry> _readEntries(RandomAccessFile file) {
  final int length = file.lengthSync();
  if (length < 22) {
    throw const ZipFormatException('压缩包太小，不是有效的 zip 文件');
  }

  // EOCD 在文件末尾，后面最多跟 65535 字节的注释。从尾部往前找签名，而不是
  // 直接假设它在最后 22 字节：带注释的包（`zip -z`、部分图形工具）会因此被
  // 误判成损坏。
  final int searchLength = length < _maxEndOfCentralDirectorySearch
      ? length
      : _maxEndOfCentralDirectorySearch;
  final int searchStart = length - searchLength;
  final Uint8List tail = _readAt(file, searchStart, searchLength);
  int eocd = -1;
  for (int i = tail.length - 22; i >= 0; i--) {
    if (_readUint32(tail, i) == _endOfCentralDirectorySignature) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) {
    throw const ZipFormatException('压缩包里找不到中央目录结束记录（文件可能被截断）');
  }

  final int entryCount = _readUint16(tail, eocd + 10);
  final int directorySize = _readUint32(tail, eocd + 12);
  final int directoryOffset = _readUint32(tail, eocd + 16);
  final int commentLength = _readUint16(tail, eocd + 20);
  if (searchStart + eocd + 22 + commentLength != length) {
    // 末尾还有本记录之外的数据：多半是文件被截断，或把两个包拼在了一起。
    throw const ZipFormatException('压缩包尾部有多余数据，结构不可信');
  }

  // ZIP64：条目数或偏移写成 0xFFFF/0xFFFFFFFF 时，真正的值在 ZIP64 记录里。
  // 自动更新包不可能这么大，明确拒绝好过读出一堆垃圾偏移。
  if (entryCount == 0xffff ||
      directoryOffset == 0xffffffff ||
      directorySize == 0xffffffff) {
    throw const ZipFormatException('压缩包使用了 ZIP64 扩展，本实现不支持');
  }
  if (directoryOffset + directorySize > length) {
    throw const ZipFormatException('压缩包的中央目录超出文件范围（文件可能被截断）');
  }

  final Uint8List directory = _readAt(file, directoryOffset, directorySize);
  final List<ZipEntry> entries = <ZipEntry>[];
  int cursor = 0;
  for (int i = 0; i < entryCount; i++) {
    if (cursor + 46 > directory.length) {
      throw const ZipFormatException('中央目录被截断');
    }
    if (_readUint32(directory, cursor) != _centralFileHeaderSignature) {
      throw const ZipFormatException('中央目录条目签名不合法');
    }
    final int flags = _readUint16(directory, cursor + 8);
    if ((flags & 0x1) != 0) {
      throw const ZipFormatException('压缩包是加密的，无法读取');
    }
    final int method = _readUint16(directory, cursor + 10);
    final int crc = _readUint32(directory, cursor + 16);
    final int compressedSize = _readUint32(directory, cursor + 20);
    final int uncompressedSize = _readUint32(directory, cursor + 24);
    final int nameLength = _readUint16(directory, cursor + 28);
    final int extraLength = _readUint16(directory, cursor + 30);
    final int entryCommentLength = _readUint16(directory, cursor + 32);
    final int localHeaderOffset = _readUint32(directory, cursor + 42);

    if (cursor + 46 + nameLength > directory.length) {
      throw const ZipFormatException('中央目录里的文件名被截断');
    }
    final Uint8List nameBytes = Uint8List.sublistView(
      directory,
      cursor + 46,
      cursor + 46 + nameLength,
    );
    // ZIP 的名字默认按 CP437 编解码，只有置了 bit 11 才是 UTF-8。我们只关心
    // ASCII 名字（附件名是 ASCII），因此非 UTF-8 时逐字节映射——不丢字节，
    // 匹配 ASCII 名字的结果与 CP437 一致。
    final String name = (flags & 0x800) != 0
        ? utf8.decode(nameBytes, allowMalformed: true)
        : String.fromCharCodes(nameBytes);

    if (method != 0 && method != 8) {
      throw ZipFormatException('压缩方法 $method 不受支持（只支持不压缩与 deflate）');
    }
    entries.add(
      ZipEntry(
        name: name,
        compressionMethod: method,
        crc32: crc,
        compressedSize: compressedSize,
        uncompressedSize: uncompressedSize,
        localHeaderOffset: localHeaderOffset,
      ),
    );
    cursor += 46 + nameLength + extraLength + entryCommentLength;
  }
  return entries;
}

/// 从条目里挑出唯一一个满足 [matches] 的条目。
///
/// 一个都不匹配、或匹配到多个时**抛异常**：发布包里只该有那一个 APK，出现两个
/// 意味着包被塞进了别的东西，此时猜哪一个都是错的。
ZipEntry singleZipEntry(
  List<ZipEntry> entries,
  bool Function(String name) matches, {
  required String what,
}) {
  final List<ZipEntry> hits = entries
      .where((ZipEntry entry) => !entry.isDirectory && matches(entry.name))
      .toList();
  if (hits.isEmpty) {
    throw ZipFormatException('压缩包里没有$what');
  }
  if (hits.length > 1) {
    throw ZipFormatException(
      '压缩包里有 ${hits.length} 个$what'
      '（${hits.map((ZipEntry e) => e.name).join('、')}），无法确定用哪一个',
    );
  }
  return hits.single;
}

/// 把 [entry] 的内容解到 [destination]（已存在则覆盖）。
///
/// 流式解压：按中央目录给的偏移一段段读、边解边写盘，因此不需要把几十 MB 的
/// 安装包整个读进内存（手机上这一点尤其重要）。解完**校验 CRC-32**：它与
/// 「文件整体 SHA-256 已通过」不重复——后者证明下载没被改坏，前者证明**我们
/// 解对了**（偏移算错、压缩方法判断错都会让内容看起来「成功」却是一堆垃圾）。
Future<void> extractZipEntry({
  required File archive,
  required ZipEntry entry,
  required File destination,
}) async {
  if (entry.compressionMethod == 0 && entry.compressedSize != entry.uncompressedSize) {
    throw const ZipFormatException('不压缩的条目尺寸自相矛盾');
  }

  final RandomAccessFile source = archive.openSync();
  RandomAccessFile? out;
  try {
    // 本地文件头的名字/扩展区长度**可能**与中央目录不同（两者是独立记录），
    // 因此数据起点必须按本地头重新算，不能拿中央目录的长度凑。
    final Uint8List localHeader = _readAt(source, entry.localHeaderOffset, 30);
    if (_readUint32(localHeader, 0) != _localFileHeaderSignature) {
      throw const ZipFormatException('条目的本地文件头签名不合法');
    }
    final int localNameLength = _readUint16(localHeader, 26);
    final int localExtraLength = _readUint16(localHeader, 28);
    final int dataStart = entry.localHeaderOffset + 30 + localNameLength + localExtraLength;
    final int dataEnd = dataStart + entry.compressedSize;
    if (dataEnd > source.lengthSync()) {
      throw const ZipFormatException('条目的数据超出文件范围（文件可能被截断）');
    }

    destination.parent.createSync(recursive: true);
    if (destination.existsSync()) destination.deleteSync();
    // 用同步句柄写：解压是一段纯内存/磁盘搬运，走 IOSink 只会把顺序问题
    // （写入未落盘就校验）引入这个函数，而这里没有任何需要并发的理由。
    out = destination.openSync(mode: FileMode.write);

    final _Crc32 crc = _Crc32();
    int written = 0;
    // 裸 deflate：ZIP 条目没有 zlib 头与 adler32 尾部，必须用 raw 模式，
    // 否则第一段数据就会以「数据格式错误」失败。
    final Stream<List<int>> parts = entry.compressionMethod == 0
        ? archive.openRead(dataStart, dataEnd)
        : archive.openRead(dataStart, dataEnd).transform(ZLibDecoder(raw: true));
    await for (final List<int> chunk in parts) {
      crc.add(chunk);
      written += chunk.length;
      out.writeFromSync(chunk);
    }
    out.closeSync();
    out = null;

    if (written != entry.uncompressedSize) {
      throw ZipFormatException(
        '解出的字节数与压缩包记录不符（记录 ${entry.uncompressedSize}，实际 $written）',
      );
    }
    if (crc.value != entry.crc32) {
      throw const ZipFormatException('解出的内容校验失败（CRC-32 不符），压缩包可能已损坏');
    }
  } finally {
    try {
      out?.closeSync();
    } on Object {
      // 写失败已经在上面抛过了，这里再失败不影响结论。
    }
    source.closeSync();
  }
}

/// 读文件的一段。所有解析都建立在这一个原语上，越界由调用方各自判断。
Uint8List _readAt(RandomAccessFile file, int start, int length) {
  if (length <= 0) return Uint8List(0);
  file.setPositionSync(start);
  final Uint8List buffer = Uint8List(length);
  int filled = 0;
  while (filled < length) {
    final int read = file.readIntoSync(buffer, filled, length);
    if (read <= 0) {
      throw const ZipFormatException('读取压缩包时意外到达文件末尾');
    }
    filled += read;
  }
  return buffer;
}

int _readUint16(Uint8List bytes, int offset) => bytes[offset] | (bytes[offset + 1] << 8);

int _readUint32(Uint8List bytes, int offset) =>
    bytes[offset] |
    (bytes[offset + 1] << 8) |
    (bytes[offset + 2] << 16) |
    (bytes[offset + 3] << 24);

/// CRC-32（IEEE 802.3，ZIP 用的那一个）。
///
/// 表在第一次使用时构建：直接写一张 256 项的常量表会让这个文件大半是数字。
class _Crc32 {
  static final Uint32List _table = _buildTable();

  static Uint32List _buildTable() {
    final Uint32List table = Uint32List(256);
    for (int i = 0; i < 256; i++) {
      int c = i;
      for (int k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1;
      }
      table[i] = c;
    }
    return table;
  }

  int _value = 0xffffffff;

  void add(List<int> bytes) {
    int c = _value;
    for (final int byte in bytes) {
      c = _table[(c ^ byte) & 0xff] ^ (c >> 8);
    }
    _value = c;
  }

  /// 最终的 CRC 值。
  int get value => (_value ^ 0xffffffff) & 0xffffffff;
}
