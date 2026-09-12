import 'dart:typed_data';

/// 纯 Dart 实现的 SHA-256。
///
/// 为什么自己写、而不是引入 `crypto`：本项目的依赖策略是「标准库做不了才加依赖」
/// （见 CONTRIBUTING.md「不要引入不必要的依赖」）。校验发布包只需要 SHA-256
/// 这一个哈希函数，而 `crypto` 会为这一个用途引入一份需要长期跟版本、跟随
/// 依赖树维护的第三方代码；这里的实现只有几十行，并且用官方标准测试向量锁死
/// （见 `test/updater_test.dart`）。
///
/// 用法是流式的，因此大文件可以边下载边计算摘要、不必整个读进内存：
///
/// ```dart
/// final hasher = Sha256();
/// hasher.update(chunk1);
/// hasher.update(chunk2);
/// final hex = hasher.digestHex();
/// ```
///
/// [digestHex] 的计算基于当前已喂入的全部数据，且**不破坏**内部状态：
/// 可以在同一实例上重复调用（每次得到同一个摘要）。
class Sha256 {
  Sha256() : _state = List<int>.of(_initialState);

  /// FIPS 180-4 第 5.3.3 节的初始哈希值。
  static const List<int> _initialState = <int>[
    0x6a09e667,
    0xbb67ae85,
    0x3c6ef372,
    0xa54ff53a,
    0x510e527f,
    0x9b05688c,
    0x1f83d9ab,
    0x5be0cd19,
  ];

  /// FIPS 180-4 第 4.2.2 节的 64 个轮常量。
  static const List<int> _roundConstants = <int>[
    0x428a2f98,
    0x71374491,
    0xb5c0fbcf,
    0xe9b5dba5,
    0x3956c25b,
    0x59f111f1,
    0x923f82a4,
    0xab1c5ed5,
    0xd807aa98,
    0x12835b01,
    0x243185be,
    0x550c7dc3,
    0x72be5d74,
    0x80deb1fe,
    0x9bdc06a7,
    0xc19bf174,
    0xe49b69c1,
    0xefbe4786,
    0x0fc19dc6,
    0x240ca1cc,
    0x2de92c6f,
    0x4a7484aa,
    0x5cb0a9dc,
    0x76f988da,
    0x983e5152,
    0xa831c66d,
    0xb00327c8,
    0xbf597fc7,
    0xc6e00bf3,
    0xd5a79147,
    0x06ca6351,
    0x14292967,
    0x27b70a85,
    0x2e1b2138,
    0x4d2c6dfc,
    0x53380d13,
    0x650a7354,
    0x766a0abb,
    0x81c2c92e,
    0x92722c85,
    0xa2bfe8a1,
    0xa81a664b,
    0xc24b8b70,
    0xc76c51a3,
    0xd192e819,
    0xd6990624,
    0xf40e3585,
    0x106aa070,
    0x19a4c116,
    0x1e376c08,
    0x2748774c,
    0x34b0bcb5,
    0x391c0cb3,
    0x4ed8aa4a,
    0x5b9cca4f,
    0x682e6ff3,
    0x748f82ee,
    0x78a5636f,
    0x84c87814,
    0x8cc70208,
    0x90befffa,
    0xa4506ceb,
    0xbef9a3f7,
    0xc67178f2,
  ];

  /// 中间哈希状态。8 个 32 位字。
  final List<int> _state;

  /// 尚未凑满 64 字节的输入。
  final Uint8List _buffer = Uint8List(64);
  int _bufferLength = 0;
  int _totalBytes = 0;

  /// 追加数据。分块调用与一次性调用结果一致。
  void update(List<int> data) {
    if (data.isEmpty) return;
    _totalBytes += data.length;
    var offset = 0;

    // 先把上一次剩下的不足一个分组的部分补齐。
    if (_bufferLength > 0) {
      final needed = 64 - _bufferLength;
      final take = data.length < needed ? data.length : needed;
      _buffer.setRange(_bufferLength, _bufferLength + take, data);
      _bufferLength += take;
      offset += take;
      if (_bufferLength == 64) {
        _processBlock(_buffer, 0, _state);
        _bufferLength = 0;
      }
    }

    // 完整分组直接就地处理，不复制。
    while (offset + 64 <= data.length) {
      _processBlock(data, offset, _state);
      offset += 64;
    }

    // 尾巴留到下一次（或 digestHex 的填充阶段）。
    if (offset < data.length) {
      final rest = data.length - offset;
      _buffer.setRange(0, rest, data, offset);
      _bufferLength = rest;
    }
  }

  /// 计算小写十六进制摘要。
  String digestHex() {
    // 在状态的副本上收尾，保证 digestHex 可以被重复调用（见类文档）。
    final state = List<int>.of(_state);

    // 末尾 8 字节是大端序的**比特**长度。高 32 位用移位单独算，
    // 避免把整个长度左移 3 位后溢出 64 位有符号整数。
    final bitLengthHigh = (_totalBytes >> 29) & 0xffffffff;
    final bitLengthLow = (_totalBytes << 3) & 0xffffffff;

    final afterMark = _bufferLength + 1;
    final zeroPadding = (56 - afterMark % 64 + 64) % 64;
    final padded = Uint8List(afterMark + zeroPadding + 8);
    padded.setRange(0, _bufferLength, _buffer);
    padded[_bufferLength] = 0x80;
    // zeroPadding 段已经是 0，无需显式写。
    padded[padded.length - 8] = (bitLengthHigh >> 24) & 0xff;
    padded[padded.length - 7] = (bitLengthHigh >> 16) & 0xff;
    padded[padded.length - 6] = (bitLengthHigh >> 8) & 0xff;
    padded[padded.length - 5] = bitLengthHigh & 0xff;
    padded[padded.length - 4] = (bitLengthLow >> 24) & 0xff;
    padded[padded.length - 3] = (bitLengthLow >> 16) & 0xff;
    padded[padded.length - 2] = (bitLengthLow >> 8) & 0xff;
    padded[padded.length - 1] = bitLengthLow & 0xff;

    for (var i = 0; i < padded.length; i += 64) {
      _processBlock(padded, i, state);
    }

    final out = StringBuffer();
    for (final word in state) {
      out.write(word.toRadixString(16).padLeft(8, '0'));
    }
    return out.toString();
  }

  /// 处理一个 64 字节分组，结果累加到 [state] 上。
  static void _processBlock(List<int> block, int offset, List<int> state) {
    final w = List<int>.filled(64, 0);
    for (var i = 0; i < 16; i++) {
      final j = offset + i * 4;
      w[i] =
          ((block[j] & 0xff) << 24) |
          ((block[j + 1] & 0xff) << 16) |
          ((block[j + 2] & 0xff) << 8) |
          (block[j + 3] & 0xff);
    }
    for (var i = 16; i < 64; i++) {
      final x = w[i - 15];
      final y = w[i - 2];
      final s0 = _rotr(x, 7) ^ _rotr(x, 18) ^ (x >> 3);
      final s1 = _rotr(y, 17) ^ _rotr(y, 19) ^ (y >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xffffffff;
    }

    var a = state[0];
    var b = state[1];
    var c = state[2];
    var d = state[3];
    var e = state[4];
    var f = state[5];
    var g = state[6];
    var h = state[7];

    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ ((~e & 0xffffffff) & g);
      final temp1 = (h + s1 + ch + _roundConstants[i] + w[i]) & 0xffffffff;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final temp2 = (s0 + maj) & 0xffffffff;

      h = g;
      g = f;
      f = e;
      e = (d + temp1) & 0xffffffff;
      d = c;
      c = b;
      b = a;
      a = (temp1 + temp2) & 0xffffffff;
    }

    state[0] = (state[0] + a) & 0xffffffff;
    state[1] = (state[1] + b) & 0xffffffff;
    state[2] = (state[2] + c) & 0xffffffff;
    state[3] = (state[3] + d) & 0xffffffff;
    state[4] = (state[4] + e) & 0xffffffff;
    state[5] = (state[5] + f) & 0xffffffff;
    state[6] = (state[6] + g) & 0xffffffff;
    state[7] = (state[7] + h) & 0xffffffff;
  }

  static int _rotr(int value, int bits) =>
      ((value >> bits) | (value << (32 - bits))) & 0xffffffff;
}

/// 一次性计算摘要的小写十六进制串。
String sha256Hex(List<int> bytes) {
  final hasher = Sha256();
  hasher.update(bytes);
  return hasher.digestHex();
}
