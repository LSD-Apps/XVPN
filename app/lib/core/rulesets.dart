import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'platform_paths.dart';

/// 规则集来源：随包分发的出厂规则集，还是用户自己添加的。
///
/// 这个区分是界面诚实的依据：内置规则集是二进制 `.srs`，只能启用/停用与查看
/// 元信息；自定义规则集才有可编辑的名字与下载链接。
enum RuleSetKind { builtin, custom }

extension RuleSetKindX on RuleSetKind {
  String get label => this == RuleSetKind.builtin ? '内置' : '自定义';
}

/// 一个规则集的配置与状态。
///
/// 只描述「谁来用、从哪来、启不启用」，不持有文件内容：`.srs` 落盘在规则集目录
/// 里，内核按 [fileName] 去读。名称同时是内核里的 `tag`，因此必须唯一。
class RuleSetEntry {
  RuleSetEntry({
    required this.name,
    required this.kind,
    required this.url,
    this.enabled = true,
    this.updatedAt,
    this.sizeBytes = 0,
  });

  /// 唯一标识，同时是内核里的标签与文件名（去掉 `.srs`）。
  final String name;

  final RuleSetKind kind;

  /// 上游下载地址。内置的取自 [RuleSetStore.sources]，自定义的由用户填写。
  final String url;

  bool enabled;

  /// 最近一次成功更新的时间。从未更新过时为 null（用的是出厂副本）。
  DateTime? updatedAt;

  /// 磁盘上的字节数。为 0 表示还没量过。
  int sizeBytes;

  String get fileName => '$name.srs';

  /// 内核里引用它的标签。
  String get tag => name;

  bool get isBuiltin => kind == RuleSetKind.builtin;

  RuleSetEntry copyWith({
    String? name,
    String? url,
    bool? enabled,
    DateTime? updatedAt,
    int? sizeBytes,
  }) {
    return RuleSetEntry(
      name: name ?? this.name,
      kind: kind,
      url: url ?? this.url,
      enabled: enabled ?? this.enabled,
      updatedAt: updatedAt ?? this.updatedAt,
      sizeBytes: sizeBytes ?? this.sizeBytes,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'name': name,
    'kind': kind == RuleSetKind.builtin ? 'builtin' : 'custom',
    'url': url,
    'enabled': enabled,
    if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
    'sizeBytes': sizeBytes,
  };

  static RuleSetEntry? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final json = raw.cast<String, Object?>();
    final name = json['name']?.toString().trim() ?? '';
    if (name.isEmpty) return null;
    final url = json['url']?.toString() ?? '';
    final kind = json['kind'] == 'builtin'
        ? RuleSetKind.builtin
        : RuleSetKind.custom;
    return RuleSetEntry(
      name: name,
      kind: kind,
      url: url,
      enabled: json['enabled'] as bool? ?? true,
      updatedAt: _time(json['updatedAt']),
      sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
    );
  }

  static DateTime? _time(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }

  /// 合法的自定义规则集名。
  ///
  /// 限制在小写字母、数字、连字符与下划线，是因为它同时是内核里的标签与磁盘上
  /// 的文件名：带上路径分隔符、空格或大写会让「标签唯一」和「文件落在正确的
  /// 目录里」这两件事同时变得难以保证。
  static final RegExp _namePattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,63}$');

  static bool isValidName(String name) => _namePattern.hasMatch(name);
}

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

  /// 出厂规则集列表。内置规则集默认全部启用。
  static List<RuleSetEntry> defaultEntries() => <RuleSetEntry>[
    for (final entry in sources.entries)
      RuleSetEntry(
        name: entry.key.substring(0, entry.key.length - '.srs'.length),
        kind: RuleSetKind.builtin,
        url: entry.value,
      ),
  ];

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

  /// 从上游更新**出厂**规则库。
  ///
  /// 保留这个入口是为了兼容既有调用方；实现已收敛到 [updateMany]，
  /// 保证「先全部下载成功、再覆盖」这条原子性只有一份实现。
  static Future<RuleSetUpdateOutcome> update({Directory? targetDir}) =>
      updateMany(<({String fileName, String url})>[
        for (final entry in sources.entries)
          (fileName: entry.key, url: entry.value),
      ], targetDir: targetDir);

  /// 从上游更新一组规则集。
  ///
  /// 先全部下载到内存并校验魔数，全部成功后才逐个覆盖正式文件——
  /// 避免下载中断留下半个文件，导致内核直接起不来。
  ///
  /// [targetDir] 必须是**内核真正读取**的那个目录；为 null 时退回桌面端的
  /// [writableDir]。安卓端由内核的 `ruleSetUpdateDir` 传入解包目录。
  static Future<RuleSetUpdateOutcome> updateMany(
    List<({String fileName, String url})> targets, {
    Directory? targetDir,
  }) async {
    final target = resolveTargetDir(targetDir: targetDir);
    target.createSync(recursive: true);

    final downloaded = <String, List<int>>{};
    for (final entry in targets) {
      final bytes = await fetch(entry.url);
      if (bytes == null) {
        return RuleSetUpdateOutcome.failure('无法下载 ${entry.fileName}，请检查网络');
      }
      if (!isValidBytes(bytes)) {
        return RuleSetUpdateOutcome.failure('${entry.fileName} 的内容不是有效的规则库');
      }
      downloaded[entry.fileName] = bytes;
    }

    for (final entry in downloaded.entries) {
      writeSrs(target, entry.key, entry.value);
    }

    final totalKb =
        downloaded.values.fold<int>(0, (sum, b) => sum + b.length) ~/ 1024;
    return RuleSetUpdateOutcome.success(
      DateTime.now(),
      '规则库已更新（共 $totalKb KB）',
    );
  }

  /// 下载一个 URL 的原始字节。失败返回 null。
  ///
  /// 公开是为了让「新增自定义规则集」复用同一条下载路径——网络错误、超时与
  /// 非 200 的处理只有一份实现，界面拿到的失败原因是同一个口径。
  static Future<List<int>?> fetch(String url) async {
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

  /// 内容是否是有效的 `.srs`：足够长且带魔数。
  static bool isValidBytes(List<int> bytes) =>
      bytes.length >= 64 && _hasMagic(bytes);

  /// 把一份规则集原子地写进规则集目录。
  ///
  /// 先写临时文件再改名：改名在同一分区上是原子的，因此下载中断也不会留下
  /// 半个文件把内核卡在启动失败上。
  static void writeSrs(Directory target, String fileName, List<int> bytes) {
    target.createSync(recursive: true);
    final dest = File('${target.path}${Platform.pathSeparator}$fileName');
    final tmp = File('${dest.path}.tmp');
    tmp.writeAsBytesSync(bytes, flush: true);
    tmp.renameSync(dest.path);
  }

  /// 删除规则集目录里的一份文件。删不掉时静默——它只是清理，不是承诺。
  static void deleteSrs(Directory target, String fileName) {
    try {
      final file = File('${target.path}${Platform.pathSeparator}$fileName');
      if (file.existsSync()) file.deleteSync();
    } on Object {
      // 清理失败不影响功能：列表里已经不再引用它。
    }
  }

  /// 重命名规则集文件。源文件不存在时什么也不做。
  static void renameSrs(Directory target, String from, String to) {
    if (from == to) return;
    try {
      final source = File('${target.path}${Platform.pathSeparator}$from');
      if (!source.existsSync()) return;
      final dest = File('${target.path}${Platform.pathSeparator}$to');
      if (dest.existsSync()) dest.deleteSync();
      source.renameSync(dest.path);
    } on Object {
      // 改名失败交给调用方按「文件缺失」处理。
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
