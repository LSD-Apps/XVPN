// 临时验证工具：从 WireGuard 私钥推导公钥，用于核对 .conf 里的
// PrivateKey 与 Peer.PublicKey 是否成对（私钥/对端公钥不匹配时，
// 内核只会「握手无应答」，从客户端完全看不出原因）。
//
//   dart run tool/wg_keycheck.dart <PrivateKey> [期望的 PublicKey]
//
// 实现先自检 RFC 7748 §5.2 官方向量，自检失败则直接报错，避免用错误
// 的实现得出「密钥不匹配」这种会误导人的结论。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

final BigInt _p = (BigInt.one << 255) - BigInt.from(19);
final BigInt _a24 = BigInt.from(121665);

BigInt _mod(BigInt x) {
  final r = x % _p;
  return r.isNegative ? r + _p : r;
}

BigInt _inv(BigInt a) => a.modPow(_p - BigInt.two, _p);

BigInt _fromBytesLe(Uint8List b) {
  var r = BigInt.zero;
  for (var i = b.length - 1; i >= 0; i--) {
    r = (r << 8) | BigInt.from(b[i]);
  }
  return r;
}

Uint8List _toBytesLe(BigInt v) {
  final out = Uint8List(32);
  var x = v;
  final mask = BigInt.from(0xff);
  for (var i = 0; i < 32; i++) {
    out[i] = (x & mask).toInt();
    x = x >> 8;
  }
  return out;
}

/// X25519 标量乘（RFC 7748 Montgomery ladder）。
Uint8List x25519(Uint8List scalar, Uint8List u) {
  final k = Uint8List.fromList(scalar);
  k[0] &= 248;
  k[31] &= 127;
  k[31] |= 64;

  final x1 = _mod(_fromBytesLe(u));
  var x2 = BigInt.one, z2 = BigInt.zero;
  var x3 = x1, z3 = BigInt.one;
  var swap = 0;

  for (var t = 254; t >= 0; t--) {
    final kt = (k[t >> 3] >> (t & 7)) & 1;
    swap ^= kt;
    if (swap == 1) {
      final tx = x2; x2 = x3; x3 = tx;
      final tz = z2; z2 = z3; z3 = tz;
    }
    swap = kt;

    final a = _mod(x2 + z2);
    final aa = _mod(a * a);
    final b = _mod(x2 - z2);
    final bb = _mod(b * b);
    final e = _mod(aa - bb);
    final c = _mod(x3 + z3);
    final d = _mod(x3 - z3);
    final da = _mod(d * a);
    final cb = _mod(c * b);

    final daPlusCb = _mod(da + cb);
    x3 = _mod(daPlusCb * daPlusCb);
    final daMinusCb = _mod(da - cb);
    z3 = _mod(x1 * _mod(daMinusCb * daMinusCb));
    x2 = _mod(aa * bb);
    z2 = _mod(e * _mod(aa + _mod(_a24 * e)));
  }

  if (swap == 1) {
    final tx = x2; x2 = x3; x3 = tx;
    final tz = z2; z2 = z3; z3 = tz;
  }

  return _toBytesLe(_mod(x2 * _inv(z2)));
}

String _hex(Uint8List b) =>
    b.map((e) => e.toRadixString(16).padLeft(2, '0')).join();

Uint8List _fromHex(String h) {
  final out = Uint8List(h.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

/// 自检：RFC 7748 §5.2 第一个官方向量。
/// 输入/输出都是小端序字节串（RFC 里的十六进制即字节顺序）。
void _selfCheck() {
  final k = _fromHex('a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4');
  final u = _fromHex('e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c');
  const expected = 'c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552';
  final got = _hex(x25519(k, u));
  if (got != expected) {
    stderr.writeln('X25519 自检失败：实现有误，结论不可信。');
    stderr.writeln('  got     : $got');
    stderr.writeln('  expected: $expected');
    exit(3);
  }
  stdout.writeln('X25519 自检: 通过（RFC 7748 §5.2 向量 1）');
}

/// WireGuard 公钥 = X25519(clamp(私钥), basepoint 9)。
String wgPublicKey(String privateKeyBase64) {
  final raw = base64.decode(privateKeyBase64);
  if (raw.length != 32) {
    throw ArgumentError('私钥必须是 32 字节，实际 ${raw.length}');
  }
  final base = Uint8List(32)..[0] = 9;
  return base64.encode(x25519(raw, base));
}

void main(List<String> args) {
  _selfCheck();
  if (args.isEmpty) {
    stderr.writeln('用法: dart run tool/wg_keycheck.dart <PrivateKey> [期望的 PublicKey]');
    exit(2);
  }

  final derived = wgPublicKey(args[0].trim());
  stdout.writeln('推导出的公钥: $derived');
  if (args.length > 1) {
    final expected = args[1].trim();
    stdout.writeln('配置里的公钥: $expected');
    final ok = derived == expected;
    stdout.writeln('密钥成对    : ${ok ? '是' : '否'}');
    exit(ok ? 0 : 1);
  }
}
