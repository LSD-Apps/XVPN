import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'platform_paths.dart';

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
  /// 上游走 jsDelivr 的 `rule-set` 分支——GitHub 直连在部分网络下时通时断，
  /// 而 CDN 稳定得多（安装阶段也是从同一个地址拉取的）。
  static const Map<String, String> sources = <String, String>{
    'geosite-cn.srs':
        'https://cdn.jsdelivr.net/gh/SagerNet/sing-geosite@rule-set/geosite-cn.srs',
    'geoip-cn.srs':
        'https://cdn.jsdelivr.net/gh/SagerNet/sing-geoip@rule-set/geoip-cn.srs',
  };

  /// `.srs` 二进制格式的魔数。校验它就能挡住把 HTML 错误页当成规则库写盘。
  static const List<int> srsMagic = <int>[0x53, 0x52, 0x53]; // "SRS"

  /// 可写规则库目录：Windows 为 `%LOCALAPPDATA%\XVPN\rulesets`，
  /// Linux 为 `$XDG_DATA_HOME/XVPN/rulesets`。
  ///
  /// 与 [AppStore.defaultDesktopDir] 共用同一份解析，避免两处各拼一遍后分叉。
  static Directory writableDir() {
    final dataDir = resolveDesktopPaths(
      platform: defaultTargetPlatform,
      environment: Platform.environment,
    ).dataDir;
    return Directory('${dataDir.path}${Platform.pathSeparator}rulesets');
  }

  /// 规则库的最终落盘目录：显式传入时以它为准，否则用桌面端的可写目录。
  ///
  /// 单独抽成一个函数，是因为这个决定现在有**两个**调用方：内核启动时的
  /// [ensure] 与「检查更新」的 [update]。两者必须落在同一个目录——曾经安卓端
  /// 的更新写到一个内核根本不读的临时目录，界面报告成功、内核却一直用旧规则，
  /// 用户被明确告知「已经更新」而事实并非如此。把解析收在一处，就没有第二次
  /// 分叉的机会。
  static Directory resolveTargetDir({Directory? targetDir}) =>
      targetDir ?? writableDir();

  /// 确保可写目录里有可用的规则库，缺失时从出厂副本复制。
  ///
  /// 返回可直接交给内核的目录。[targetDir] 为 null 时用 [writableDir]；
  /// 安卓端把解包目录显式传进来，避免它再去猜桌面端的路径规则。
  static Directory ensure(Directory bundledDir, {Directory? targetDir}) {
    final target = resolveTargetDir(targetDir: targetDir);
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
  ///
  /// [targetDir] 必须是**内核真正读取**的那个目录；为 null 时退回桌面端的
  /// [writableDir]。安卓端由内核的 `ruleSetUpdateDir` 传入解包目录。
  static Future<RuleSetUpdateOutcome> update({Directory? targetDir}) async {
    final target = resolveTargetDir(targetDir: targetDir);
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

    final totalKb =
        downloaded.values.fold<int>(0, (sum, b) => sum + b.length) ~/ 1024;
    return RuleSetUpdateOutcome.success(
      DateTime.now(),
      '规则库已更新（共 $totalKb KB）',
    );
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
