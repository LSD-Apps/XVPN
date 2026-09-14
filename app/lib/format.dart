/// 单位与时长格式化。集中在一处，保证两端显示完全一致。
library;

String _two(int v) => v.toString().padLeft(2, '0');

/// 速率：按 B/s → KB/s → MB/s 自动进位，返回数值与单位的组合。
({String value, String unit}) fmtRate(double bytesPerSecond) {
  if (bytesPerSecond >= 1024 * 1024) {
    return (
      value: (bytesPerSecond / (1024 * 1024)).toStringAsFixed(2),
      unit: 'MB/s',
    );
  }
  if (bytesPerSecond >= 1024) {
    return (value: (bytesPerSecond / 1024).toStringAsFixed(0), unit: 'KB/s');
  }
  return (value: bytesPerSecond.toStringAsFixed(0), unit: 'B/s');
}

/// 速率的整体标签，形如 `1.20 MB/s`。托盘 tooltip 与窄位文案用。
String fmtRateLabel(double bytesPerSecond) {
  final parts = fmtRate(bytesPerSecond);
  return '${parts.value} ${parts.unit}';
}

/// 累计流量：B → KB → MB → GB → TB。
({String value, String unit}) fmtBytes(int bytes) {
  const kb = 1024.0;
  const mb = kb * 1024;
  const gb = mb * 1024;
  const tb = gb * 1024;
  final b = bytes.toDouble();
  if (b >= tb) return (value: (b / tb).toStringAsFixed(2), unit: 'TB');
  if (b >= gb) return (value: (b / gb).toStringAsFixed(2), unit: 'GB');
  if (b >= mb) return (value: (b / mb).toStringAsFixed(1), unit: 'MB');
  if (b >= kb) return (value: (b / kb).toStringAsFixed(0), unit: 'KB');
  return (value: bytes.toString(), unit: 'B');
}

/// 时长：固定 HH:MM:SS，与设计稿的连接计时一致。
String fmtDuration(Duration d) {
  final seconds = d.inSeconds < 0 ? 0 : d.inSeconds;
  return '${_two(seconds ~/ 3600)}:${_two((seconds % 3600) ~/ 60)}:${_two(seconds % 60)}';
}

/// 单个字节数的**紧凑**形式：不带空格、不补零，用于表格里的窄列。
///
/// 与 [fmtBytes] 的区别是它返回一个整体字符串（`1.2M` 而不是 `(1.2, MB)`），
/// 并且单位只用一位，好让「↓1.2M ↑340K」这样的组合落在一列里放得下。
String fmtBytesCompact(int bytes) {
  const kb = 1024.0;
  const mb = kb * 1024;
  const gb = mb * 1024;
  final b = bytes.toDouble();
  if (b >= gb) return '${(b / gb).toStringAsFixed(1)}G';
  if (b >= mb) return '${(b / mb).toStringAsFixed(1)}M';
  if (b >= kb) return '${(b / kb).toStringAsFixed(0)}K';
  return '$bytes';
}

/// 上下行流量的紧凑组合，形如 `↓1.2M ↑340K`。
///
/// 两个方向都显示而不是只给总量：用户判断「这次访问是不是真的把内容拉下来了」
/// 靠的是下行，而「是不是在往外传东西」靠的是上行，合计成一个数字会把这个区别
/// 抹掉。同时它能稳定放进窄列，不需要再加一列。
String fmtTrafficPair({required int down, required int up}) {
  if (down == 0 && up == 0) return '—';
  return '↓${fmtBytesCompact(down)} ↑${fmtBytesCompact(up)}';
}

/// 日期：用于规则库更新时间展示。
String fmtDate(DateTime d) => '${d.year}-${_two(d.month)}-${_two(d.day)}';

/// 稳定的短哈希，用于给导入的配置生成不随进程变化的 id。
String stableHash(String input) {
  // FNV-1a 64 位。用自实现而非 hashCode，保证跨进程、跨平台一致。
  var hash = 0xcbf29ce484222325;
  for (final unit in input.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}
