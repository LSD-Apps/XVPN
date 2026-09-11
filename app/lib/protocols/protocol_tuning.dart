/// OpenVPN 参数名的规范化。
///
/// 这一层存在的唯一理由是一个**会让内核直接起不来**的坑，实测确认过：
/// sing-box 的 openvpn-client 端点要求 `data_ciphers` / `data_ciphers_fallback`
/// 里的名字必须是 **OpenVPN 官方的大写规范名**，否则：
///
/// ```
/// FATAL initialize endpoint[0]: ClientOptions.DataChannel.Ciphers[0]
///       must use a canonical OpenVPN cipher name
/// ```
///
/// 也就是说，配置里写 `data-ciphers AES-256-GCM` 可以，但写成小写
/// `aes-256-gcm`、写成 OpenVPN 的旧别名、或者带上任何 sing-box 不认识的
/// 名字，都会让内核**整体启动失败**——用户看到的是「连不上」，而且
/// 错误信息里没有任何他能理解的东西。
///
/// 同理 `auth` 必须是大写的摘要名（`SHA256`，不是 `sha256`）。
///
/// 因此这里的策略是：认识的名字统一成规范写法；不认识的**直接剔除**而不是
/// 原样传下去——剔除最多让协商范围变小，原样传下去会让内核起不来。
library;

/// sing-box / OpenVPN 认可的规范数据加密套件名。
///
/// 取自 OpenVPN 3 的 cipher 名称表。只保留对称加密套件；
/// `none` 是 OpenVPN 允许的「不加密」，也一并支持。
const Set<String> canonicalDataCiphers = <String>{
  'AES-128-CBC',
  'AES-192-CBC',
  'AES-256-CBC',
  'AES-128-GCM',
  'AES-192-GCM',
  'AES-256-GCM',
  'AES-128-CFB',
  'AES-192-CFB',
  'AES-256-CFB',
  'AES-128-OFB',
  'AES-192-OFB',
  'AES-256-OFB',
  'AES-128-CTR',
  'AES-192-CTR',
  'AES-256-CTR',
  'ARIA-128-CBC',
  'ARIA-192-CBC',
  'ARIA-256-CBC',
  'ARIA-128-GCM',
  'ARIA-192-GCM',
  'ARIA-256-GCM',
  'BF-CBC',
  'CAMELLIA-128-CBC',
  'CAMELLIA-192-CBC',
  'CAMELLIA-256-CBC',
  'CHACHA20-POLY1305',
  'DES-EDE3-CBC',
  'DES-EDE3-CFB',
  'DES-EDE3-OFB',
  'DESX-CBC',
  'RC2-40-CBC',
  'RC2-64-CBC',
  'RC2-CBC',
  'SEED-CBC',
  'SM4-CBC',
  'SM4-CTR',
  'SM4-GCM',
  'SM4-OFB',
  'none',
};

/// sing-box / OpenVPN 认可的规范 HMAC 摘要名。
const Set<String> canonicalAuthDigests = <String>{
  'MD5',
  'SHA1',
  'SHA256',
  'SHA512',
  'RIPEMD160',
  'none',
};

/// 把加密套件名归一化成规范写法。不认识时返回 null。
///
/// 容错几种常见写法：大小写、下划线、以及少见的 `AES256GCM`。
String? canonicalizeCipher(String raw) {
  final normalized = _normalizeKey(raw);
  if (normalized.isEmpty) return null;
  for (final canonical in canonicalDataCiphers) {
    if (_normalizeKey(canonical) == normalized) return canonical;
  }
  // OpenVPN 3 的文档里 `chacha20-poly1305` 也写成 `CHACHA20-POLY1305`，
  // 两者归一化后相同，上面的循环已经覆盖；这里再兜一个无连字符的写法。
  if (normalized == 'CHACHA20POLY1305') return 'CHACHA20-POLY1305';
  return null;
}

/// 把摘要名归一化成规范写法。不认识时返回 null。
String? canonicalizeAuth(String raw) {
  final normalized = _normalizeKey(raw);
  if (normalized.isEmpty) return null;
  for (final canonical in canonicalAuthDigests) {
    if (_normalizeKey(canonical) == normalized) return canonical;
  }
  return null;
}

/// 去掉分隔符并大写，用于宽松比较。
String _normalizeKey(String raw) => raw
    .trim()
    .toUpperCase()
    .replaceAll('-', '')
    .replaceAll('_', '')
    .replaceAll(' ', '');

/// 归一化一组加密套件，并剔除不认识的名字。
///
/// 返回归一化后的列表与被剔除的名字（供界面提示）。
({List<String> ciphers, List<String> rejected}) canonicalizeCipherList(
  Iterable<String> raw,
) {
  final result = <String>[];
  final rejected = <String>[];
  for (final item in raw) {
    final trimmed = item.trim();
    if (trimmed.isEmpty) continue;
    final canonical = canonicalizeCipher(trimmed);
    if (canonical == null) {
      rejected.add(trimmed);
      continue;
    }
    if (!result.contains(canonical)) result.add(canonical);
  }
  return (ciphers: result, rejected: rejected);
}

/// 把 OpenVPN 的 `data-ciphers` 默认值按内核偏好排序。
///
/// OpenVPN 2.6 的默认顺序是 `AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305`，
/// 但 CHACHA20-POLY1305 在移动设备上（没有 AES-NI 时）往往比 AES-GCM 更快。
/// 这里不擅自改变用户配置里写明的顺序——只做一件事：
/// 把 GCM 类套件排在 CBC 类之前，因为 GCM 同时提供完整性校验，
/// 在同样的安全性下少一轮 HMAC 计算，明显更快。
List<String> preferFastCiphersFirst(List<String> ciphers) {
  int rank(String cipher) {
    final upper = cipher.toUpperCase();
    if (upper.contains('GCM')) return 0; // AEAD：单次遍历，最快
    if (upper.contains('POLY1305')) return 0;
    if (upper.contains('CTR')) return 1;
    if (upper.contains('CFB') || upper.contains('OFB')) return 2;
    return 3; // CBC 及其它
  }

  // 稳定排序：同档内保持用户原本的顺序。
  final indexed = <(int, String)>[
    for (var i = 0; i < ciphers.length; i++) (i, ciphers[i]),
  ];
  indexed.sort((a, b) {
    final byRank = rank(a.$2).compareTo(rank(b.$2));
    return byRank != 0 ? byRank : a.$1.compareTo(b.$1);
  });
  return indexed.map(((int, String) e) => e.$2).toList(growable: false);
}

/// WireGuard 的 MTU 合理区间。
///
/// wg-quick 默认 1420，sing-box 端点的默认值是 1408。低于 1280 会撞上 IPv6 的
/// 最小 MTU 要求，高于 1500 则超出以太网帧——两者都几乎必然是配置写错了。
const int minReasonableMtu = 1280;
const int maxReasonableMtu = 1500;

/// 校验并归一化 MTU。超出合理区间时返回 null，交给调用方回退到默认值。
int? sanitizeMtu(int? raw) {
  if (raw == null) return null;
  if (raw < minReasonableMtu || raw > maxReasonableMtu) return null;
  return raw;
}

/// 判断一份 WireGuard 配置是否用到了 AmneziaWG 的混淆参数。
///
/// AmneziaWG 是 WireGuard 的非标准分支，靠 `Jc` / `Jmin` / `Jmax` / `S1` / `S2` /
/// `H1`~`H4` 这些参数把握手包伪装成随机数据。sing-box 的 WireGuard 端点**不
/// 支持**这些参数，因此这类配置导入后会「看起来正常但连不上」。
///
/// 明确识别出来并告知用户，比让他对着一个连不上的隧道猜要好得多。
bool looksLikeAmneziaWireGuard(Map<String, String> ignoredKeys) {
  const amneziaKeys = <String>{
    'jc',
    'jmin',
    'jmax',
    's1',
    's2',
    'h1',
    'h2',
    'h3',
    'h4',
  };
  for (final key in ignoredKeys.keys) {
    if (amneziaKeys.contains(key.toLowerCase())) return true;
  }
  return false;
}
