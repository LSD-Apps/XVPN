import 'dart:io';

import 'package:http/http.dart' as http;

/// 规则库的落盘与更新。
///
/// 设计：程序内打包一份规则库作为**出厂副本**，运行时复制到可写目录，
/// 之后由本模块负责更新。这样做有两个好处：
///   * 首次启动无需联网即可分流；
///   * 更新只影响可写目录，不会破坏程序自身的安装内容（也不需要在
///     Program Files 下有写权限）。
///
/// 之前设置页的「检查更新」只是一个占位实现（只改了显示的日期），
/// 这里把它做成真的：从上游拉取 `.srs` 并覆盖本地副本。
class RuleSetStore {
  RuleSetStore._();

  /// 需要维护的规则库。键是文件名，值是上游地址。
  ///
  /// 上游走 jsDelivr 的 `rule-set` 分支——GitHub 直连在国内时通时断，
  /// 而 CDN 稳定得多（安装阶段也是从同一个地址拉取的）。
  static const Map<String, String> sources = <String, String>{
    'geosite-cn.srs': 'https://cdn.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/geosite-cn.srs',
    'geoip-cn.srs': 'https://cdn.jsdelivr.net/gh/SagerNet/sing-geoip@rule-set/geoip-cn.srs',
  };

  /// `.srs` 二进制格式的魔数。校验它就能挡住把 HTML 错误页当成规则库写盘。
  static const List<int> srsMagic = <int>[0x53, 0x52, 0x53]; // "SRS"

  /// 可写规则库目录：`%LOCALAPPDATA%\XVPN\rulesets`。
  static Directory writableDir() {
    final base = Platform.environment['LOCALAPPDATA'] ??
        Platform.environment['APPDATA'] ??
        Directory.systemTemp.path;
    return Directory('$base${Platform.pathSeparator}XVPN${Platform.pathSeparator}rulesets');
  }

  /// 确保可写目录里有可用的规则库，缺失时从出厂副本复制。
  ///
  /// 返回可直接交给内核的目录。
  static Directory ensure(Directory bundledDir) {
    final target = writableDir();
    target.createSync(recursive: true);
    for (final name in sources.keys) {
      final dest = File('${target.path}${Platform.pathSeparator}$name');
      if (dest.existsSync() && _looksValid(dest)) continue;
      final src = File('${bundledDir.path}${Platform.pathSeparator}$name');
      if (src.existsSync()) {
        src.copySync(dest.path);
      }
    }
    return target;
  }

  /// 从上游更新规则库。
  ///
  /// 先下载到临时文件并校验魔数，全部成功后才覆盖正式文件——
  /// 避免下载中断留下半个文件，导致内核直接起不来。
  static Future<RuleSetUpdateOutcome> update() async {
    final target = writableDir();
    target.createSync(recursive: true);

    final downloaded = <String, List<int>>{};
    for (final entry in sources.entries) {
      final bytes = await _download(entry.value);
      if (bytes == null) {
        return RuleSetUpdateOutcome.failure('无法下载 ${entry.key}，请检查网络');
      }
      if (bytes.length < 64 || !_hasMagic(bytes)) {
        return RuleSetUpdateOutcome.failure('${entry.key} 的内容不是有效的规则库');
      }
      downloaded[entry.key] = bytes;
    }

    for (final entry in downloaded.entries) {
      final dest = File('${target.path}${Platform.pathSeparator}${entry.key}');
      // 先写临时文件再改名：改名在同一分区上是原子的。
      final tmp = File('${dest.path}.tmp');
      tmp.writeAsBytesSync(entry.value, flush: true);
      tmp.renameSync(dest.path);
    }

    final totalKb = downloaded.values.fold<int>(0, (sum, b) => sum + b.length) ~/ 1024;
    return RuleSetUpdateOutcome.success(
      DateTime.now(),
      '规则库已更新（共 $totalKb KB）',
    );
  }

  /// 读取当前规则库的落盘时间，用于界面展示。
  static DateTime? lastModified() {
    final target = writableDir();
    DateTime? newest;
    for (final name in sources.keys) {
      final f = File('${target.path}${Platform.pathSeparator}$name');
      if (!f.existsSync()) continue;
      final t = f.lastModifiedSync();
      if (newest == null || t.isAfter(newest)) newest = t;
    }
    return newest;
  }

  static Future<List<int>?> _download(String url) async {
    try {
      final response = await http
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) return null;
      return response.bodyBytes;
    } on Object {
      // 下载失败由调用方统一转成用户可读的提示，这里不重复处理。
      return null;
    }
  }

  static bool _hasMagic(List<int> bytes) {
    if (bytes.length < srsMagic.length) return false;
    for (var i = 0; i < srsMagic.length; i++) {
      if (bytes[i] != srsMagic[i]) return false;
    }
    return true;
  }

  static bool _looksValid(File file) {
    try {
      final raf = file.openSync();
      try {
        final head = raf.readSync(srsMagic.length);
        if (head.length < srsMagic.length) return false;
        for (var i = 0; i < srsMagic.length; i++) {
          if (head[i] != srsMagic[i]) return false;
        }
        return true;
      } finally {
        raf.closeSync();
      }
    } on Object {
      return false;
    }
  }
}

/// 规则库更新的结果。
class RuleSetUpdateOutcome {
  const RuleSetUpdateOutcome._({
    required this.succeeded,
    required this.message,
    this.updatedAt,
  });

  factory RuleSetUpdateOutcome.success(DateTime at, String message) =>
      RuleSetUpdateOutcome._(succeeded: true, message: message, updatedAt: at);

  factory RuleSetUpdateOutcome.failure(String message) =>
      RuleSetUpdateOutcome._(succeeded: false, message: message);

  final bool succeeded;
  final String message;
  final DateTime? updatedAt;
}
