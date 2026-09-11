/// 直连 DNS 查询客户端。
///
/// 为什么要自己实现一套 DNS 报文编解码，而不是引入依赖：
///
///   1. **需要按服务器分别计时**。内核的 `/dns/query` 只告诉我们「最终用的哪个
///      解析器」，拿不到「223.5.5.5 用了多少毫秒、119.29.29.29 用了多少毫秒」。
///      而「DNS 监测」的核心价值恰恰是这个——只有分开测才能发现某个解析器
///      在变慢或已经不响应了。
///   2. **需要拿到「原始结果」用于交叉校验**。要判断一个域名是否被投毒，
///      必须比较国内解析器与隧道内解析器的答案；内核只会给你它自己挑中的那一个。
///   3. 报文格式极其稳定（RFC 1035），A/AAAA 查询的编解码不到 200 行，
///      引入一个包反而增加构建与审计成本。
///
/// 只支持 A / AAAA —— 分流判定需要的就是地址，CNAME / MX 之类与本功能无关。
/// 编解码是纯函数，可完整单元测试；网络部分通过注入 socket 工厂隔离。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// 一次 DNS 查询的结果。
class DnsOutcome {
  const DnsOutcome({
    required this.server,
    required this.name,
    required this.answers,
    required this.elapsed,
    this.error,
  });

  /// 被查询的解析器地址。
  final String server;

  final String name;

  /// 解析出的地址。空列表表示「解析成功但没有该类型的记录」。
  final List<String> answers;

  final Duration elapsed;

  /// 失败原因。为 null 表示查询本身成功（即便没有记录）。
  final String? error;

  bool get succeeded => error == null;

  /// 是否拿到了可用地址。
  bool get resolved => error == null && answers.isNotEmpty;

  /// 查询耗时（毫秒）。失败时是「等到超时」的耗时。
  int get millis => elapsed.inMilliseconds;

  /// 简短的可读结论。
  String get summary {
    if (error != null) return error!;
    if (answers.isEmpty) return '无记录';
    return answers.take(2).join(', ');
  }
}

/// DNS 查询器。给定解析器地址与域名，返回结果与耗时。
abstract class DnsResolver {
  Future<DnsOutcome> query(String server, String name, {Duration timeout});

  void close() {}
}

/// 基于 UDP 的真实实现。
///
/// 绑定到回环地址（`InternetAddress.loopbackIPv4`）而不是默认的任意地址，
/// 因此在 Windows 上**不需要管理员权限**——这正是选择 UDP 而非原始套接字的原因。
class UdpDnsResolver implements DnsResolver {
  UdpDnsResolver({Random? random, this.defaultTimeout = const Duration(seconds: 3)})
      : _random = random ?? Random();

  final Random _random;
  final Duration defaultTimeout;

  static const int dnsPort = 53;

  @override
  Future<DnsOutcome> query(
    String server,
    String name, {
    Duration? timeout,
  }) async {
    final effectiveTimeout = timeout ?? defaultTimeout;
    final watch = Stopwatch()..start();
    RawDatagramSocket? socket;
    try {
      final serverAddress = InternetAddress.tryParse(server);
      if (serverAddress == null) {
        return DnsOutcome(
          server: server,
          name: name,
          answers: const <String>[],
          elapsed: watch.elapsed,
          error: '解析器地址不合法',
        );
      }
      socket = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
      socket.broadcastEnabled = false;

      final id = _random.nextInt(0xFFFF);
      final request = buildQuery(id, name);
      final completer = Completer<Uint8List?>();

      final subscription = socket.listen((RawSocketEvent event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket?.receive();
        if (datagram == null) return;
        if (!completer.isCompleted) completer.complete(datagram.data);
      });

      socket.send(request, serverAddress, dnsPort);

      final response = await completer.future.timeout(
        effectiveTimeout,
        onTimeout: () => null,
      );
      await subscription.cancel();

      if (response == null) {
        return DnsOutcome(
          server: server,
          name: name,
          answers: const <String>[],
          elapsed: watch.elapsed,
          error: '解析超时',
        );
      }

      final parsed = parseResponse(response, expectedId: id);
      if (parsed == null) {
        return DnsOutcome(
          server: server,
          name: name,
          answers: const <String>[],
          elapsed: watch.elapsed,
          error: '响应无法解析',
        );
      }
      if (parsed.rcode != 0) {
        return DnsOutcome(
          server: server,
          name: name,
          answers: const <String>[],
          elapsed: watch.elapsed,
          error: rcodeText(parsed.rcode),
        );
      }
      return DnsOutcome(
        server: server,
        name: name,
        answers: parsed.addresses,
        elapsed: watch.elapsed,
      );
    } on Object catch (e) {
      return DnsOutcome(
        server: server,
        name: name,
        answers: const <String>[],
        elapsed: watch.elapsed,
        error: '查询失败：$e',
      );
    } finally {
      socket?.close();
    }
  }

  @override
  void close() {}
}

/// 解析后的报文。
class DnsMessage {
  const DnsMessage({required this.rcode, required this.addresses});

  final int rcode;

  /// A / AAAA 记录里的地址，已归一化（AAAA 会压缩成最短写法）。
  final List<String> addresses;
}

/// 构造 A 查询报文。
Uint8List buildQuery(int id, String name, {int type = 1}) {
  final labels = name
      .split('.')
      .map((String s) => s.trim())
      .where((String s) => s.isNotEmpty)
      .toList(growable: false);

  // 头部 12 字节 + 每个标签（长度字节 + 内容）+ 结尾 0 + QTYPE 2 + QCLASS 2
  final nameLength = labels.fold<int>(1, (int sum, String l) => sum + 1 + l.length);
  final buffer = Uint8List(12 + nameLength + 4);
  final view = ByteData.view(buffer.buffer);

  view.setUint16(0, id & 0xFFFF); // ID
  view.setUint16(2, 0x0100); // RD=1，请求递归解析
  view.setUint16(4, 1); // QDCOUNT
  view.setUint16(6, 0); // ANCOUNT
  view.setUint16(8, 0); // NSCOUNT
  view.setUint16(10, 0); // ARCOUNT

  var offset = 12;
  for (final label in labels) {
    final bytes = _asciiBytes(label);
    // 单个标签最长 63 字节（RFC 1035）。超长直接截断而不是抛错：
    // 这么长的标签本来也不可能是真实域名，截断后查询会自然失败。
    final length = bytes.length > 63 ? 63 : bytes.length;
    buffer[offset++] = length;
    buffer.setRange(offset, offset + length, bytes);
    offset += length;
  }
  buffer[offset++] = 0; // 域名结束
  view.setUint16(offset, type);
  offset += 2;
  view.setUint16(offset, 1); // IN
  return buffer;
}

/// 解析响应报文。格式非法时返回 null。
///
/// [expectedId] 不为 null 时会校验事务 ID；不匹配说明收到了别的查询的响应。
DnsMessage? parseResponse(Uint8List data, {int? expectedId}) {
  if (data.length < 12) return null;
  final view = ByteData.view(data.buffer, data.offsetInBytes, data.length);
  final id = view.getUint16(0);
  if (expectedId != null && id != (expectedId & 0xFFFF)) return null;

  // 首字节最高位是 QR：1 表示这是响应。
  if ((data[2] & 0x80) == 0) return null;

  final rcode = data[3] & 0x0F;
  final questionCount = view.getUint16(4);
  final answerCount = view.getUint16(6);

  var offset = 12;
  for (var i = 0; i < questionCount; i++) {
    final skipped = _skipName(data, offset);
    if (skipped == null) return null;
    offset = skipped + 4; // QTYPE + QCLASS
    if (offset > data.length) return null;
  }

  final addresses = <String>[];
  final seen = <String>{};
  for (var i = 0; i < answerCount; i++) {
    final afterName = _skipName(data, offset);
    if (afterName == null) return null;
    if (afterName + 10 > data.length) return null;

    final type = view.getUint16(afterName);
    final rdLength = view.getUint16(afterName + 8);
    final rdataOffset = afterName + 10;
    if (rdataOffset + rdLength > data.length) return null;

    if (type == 1 && rdLength == 4) {
      final address =
          '${data[rdataOffset]}.${data[rdataOffset + 1]}.${data[rdataOffset + 2]}.${data[rdataOffset + 3]}';
      if (seen.add(address)) addresses.add(address);
    } else if (type == 28 && rdLength == 16) {
      final address = _formatIpv6(data, rdataOffset);
      if (seen.add(address)) addresses.add(address);
    }
    offset = rdataOffset + rdLength;
  }

  return DnsMessage(rcode: rcode, addresses: addresses);
}

/// 跳过域名（自动处理压缩指针）。返回下一个字节的位置，越界返回 null。
int? _skipName(Uint8List data, int offset) {
  var cursor = offset;
  var guard = 0;
  while (cursor < data.length) {
    if (guard++ > 128) return null; // 防御性上限，避免畸形报文导致死循环
    final length = data[cursor];
    if (length == 0) return cursor + 1;
    // 高两位置位表示这是 2 字节压缩指针，域名到此为止。
    if ((length & 0xC0) == 0xC0) {
      return cursor + 2 <= data.length ? cursor + 2 : null;
    }
    if ((length & 0xC0) != 0) return null; // 未定义的标签类型
    cursor += length + 1;
  }
  return null;
}

String _formatIpv6(Uint8List data, int offset) {
  final groups = <int>[];
  for (var i = 0; i < 8; i++) {
    groups.add((data[offset + i * 2] << 8) | data[offset + i * 2 + 1]);
  }
  // 找最长的一段 0，压缩成 `::`（RFC 5952）。只压缩长度 >= 2 的段。
  var bestStart = -1;
  var bestLength = 0;
  var currentStart = -1;
  var currentLength = 0;
  for (var i = 0; i < groups.length; i++) {
    if (groups[i] == 0) {
      if (currentStart == -1) currentStart = i;
      currentLength++;
      if (currentLength > bestLength) {
        bestLength = currentLength;
        bestStart = currentStart;
      }
    } else {
      currentStart = -1;
      currentLength = 0;
    }
  }
  if (bestLength < 2) {
    return groups.map((int g) => g.toRadixString(16)).join(':');
  }
  final head = groups
      .sublist(0, bestStart)
      .map((int g) => g.toRadixString(16))
      .join(':');
  final tail = groups
      .sublist(bestStart + bestLength)
      .map((int g) => g.toRadixString(16))
      .join(':');
  return '$head::$tail';
}

/// 把域名标签转成 ASCII 字节。
///
/// 刻意**不做 punycode 转换**：国内/国外主流站点在规则库里本就是 ASCII 形式，
/// 而 IDN 域名会在这里退化成「按 UTF-8 字节发送」，服务器多半返回格式错误——
/// 表现为探测失败而不是探测结果错误，不会误导分流判定。
Uint8List _asciiBytes(String label) {
  final units = label.codeUnits;
  final bytes = Uint8List(units.length);
  for (var i = 0; i < units.length; i++) {
    bytes[i] = units[i] > 127 ? 0x3F /* ? */ : units[i];
  }
  return bytes;
}

/// 响应码的简短中文说明。
String rcodeText(int rcode) => switch (rcode) {
      0 => '成功',
      1 => '报文格式错误',
      2 => '服务器故障',
      3 => '域名不存在',
      4 => '不支持该查询',
      5 => '服务器拒绝',
      _ => '响应码 $rcode',
    };
