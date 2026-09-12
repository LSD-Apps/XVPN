/// 内核日志的环形缓冲。
///
/// 存在这一层的理由很具体：出问题时，内核日志是**唯一的事实来源**。界面上能
/// 看到的只有「连不上」「打不开」这类结论，而内核在那一行日志里写明了它到底
/// 做了哪个判定、走的哪个出站、失败在哪一步。
///
/// 此前这份日志只以两种形式存在：子进程的 40 行滚动尾巴（只在拼接错误信息时
/// 用一次），以及安卓端——**完全没有留存**，读完就丢。于是用户遇到问题只能
/// 描述现象，没有任何可供排查的原始信息。
///
/// 三个设计点：
///
///  1. **按容量丢弃最旧的，并如实记账**（[droppedLines]）。悄悄丢掉早期日志
///     会让用户以为「日志就这么长」，从而误判问题发生的时间点。
///  2. **正确拼接被切断的行**。子进程的 stdout 是按块到达的，一个日志行可能
///     横跨两块。原实现直接按 `\n` 切分，会产出一堆半截行——断在中间的那一行
///     恰恰常常是关键的那一行。
///  3. **不自动清空**。跨重连保留历史：内核崩了又自动重连时，「崩之前那几行」
///     正是要看的东西。容量有限，不会无限增长。
library;

/// 环形日志缓冲。
class KernelLogBuffer {
  KernelLogBuffer({this.capacity = defaultCapacity});

  /// 默认容量。
  ///
  /// 500 行足够覆盖一次连接建立 + 若干次失败尝试，而按每行 200 字节估算
  /// 也就 100 KB 量级，常驻内存完全无所谓。
  static const int defaultCapacity = 500;

  final int capacity;

  final List<String> _lines = <String>[];
  int _dropped = 0;

  /// 还没凑成完整一行的尾巴。
  String _pending = '';

  /// 当前保留的日志行，最旧的在前。
  List<String> get lines => List<String>.unmodifiable(_lines);

  /// 因为容量限制被丢弃的行数。
  int get droppedLines => _dropped;

  /// 最后一行。没有内容时为 null。
  String? get lastLine => _lines.isEmpty ? null : _lines.last;

  bool get isEmpty => _lines.isEmpty && _pending.isEmpty;

  /// 追加一整行。
  ///
  /// 行尾的换行与空白会被去掉；空行不记录——内核日志里的空行只是输出格式，
  /// 留在缓冲里除了占位置没有意义。
  void add(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty) return;
    _lines.add(trimmed);
    while (_lines.length > capacity) {
      _lines.removeAt(0);
      _dropped++;
    }
  }

  /// 追加一块原始输出，返回其中**新凑齐**的完整行。
  ///
  /// 最后一段若没有以换行结尾，会留在内部等下一块，不会当成完整行交出去。
  List<String> addChunk(String chunk) {
    _pending += chunk;
    final parts = _pending.split('\n');
    // 最后一段是「还没结束的那一行」，留在待续区。
    _pending = parts.removeLast();
    for (final part in parts) {
      add(part);
    }
    return parts
        .map((String p) => p.trim())
        .where((String p) => p.isNotEmpty)
        .toList();
  }

  /// 把待续区里那半行也当作完整行收下。
  ///
  /// 内核退出时调用：最后一行往往没有换行符结尾，而它常常正是崩溃原因。
  void flushPending() {
    if (_pending.trim().isEmpty) {
      _pending = '';
      return;
    }
    add(_pending);
    _pending = '';
  }

  void clear() {
    _lines.clear();
    _pending = '';
    _dropped = 0;
  }

  /// 导出用的纯文本。
  String asText() => _lines.join('\n');
}
