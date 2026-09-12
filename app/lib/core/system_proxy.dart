import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'platform_paths.dart';

/// 系统代理的接管与还原。
///
/// 抽成接口（而不是直接调静态方法）是为了让「接管 → 还原」这对动作的**配对关系**
/// 能被测试：系统代理是全局设置，一旦接管了却没还原，用户关掉应用后所有网站都
/// 打不开，而现象与隧道毫无关系——没人会想到去代理设置里找原因。这条路径此前
/// 只能靠读代码确认，而它恰恰是最不能出错的一处。
///
/// 与 [DnsResolver] 同一个思路：真实实现走平台通道或系统命令，测试注入替身。
abstract class SystemProxyController {
  /// 接管系统代理。[host] 与 [port] 指向本地内核的混合入站。
  ///
  /// 返回 false 表示没能接管（非桌面平台、没有可识别的桌面环境、
  /// 被策略锁定等），调用方据此决定要不要提示用户。
  Future<bool> set({required String host, required int port});

  /// 还原系统代理。返回 false 表示**还原失败**——此时用户的网络仍然是坏的，
  /// 调用方必须把这件事说出来，而不是静默继续。
  Future<bool> clear();

  /// 启动时调用：若上次异常退出留下了备份，先把系统代理恢复回去。
  Future<bool> recoverIfNeeded();
}

/// 执行外部命令。
///
/// 抽成接口的唯一目的是让 Linux 命令构造与备份/还原逻辑**能在 Windows 上被测**：
/// 开发机没有 gsettings，真实调用只会失败，于是这些分支此前只能靠肉眼复核。
abstract class ProcessRunner {
  const ProcessRunner();

  Future<ProcessResult> run(String executable, List<String> arguments);
}

/// 真实实现。
class RealProcessRunner implements ProcessRunner {
  const RealProcessRunner();

  @override
  Future<ProcessResult> run(String executable, List<String> arguments) =>
      Process.run(executable, arguments);
}

/// Windows 上的真实实现。
///
/// 原生侧会在写入前先备份用户原有的代理设置，断开时还原；备份放在注册表里，
/// 这样即使进程被强杀，下次启动也能恢复（见 [recoverIfNeeded]）。
class SystemProxy implements SystemProxyController {
  const SystemProxy();

  /// 与窗口控制共用同一个平台通道，方法名见 flutter_window.cpp。
  static const MethodChannel _channel = MethodChannel('com.xvpn.xvpn/platform');

  static bool get supported => defaultTargetPlatform == TargetPlatform.windows;

  /// 按平台选择实现。
  ///
  /// 存在的意义是让调用方（`main` 与 `SingBoxRunner`）不需要知道平台差异；
  /// 测试仍可显式注入 [SystemProxyController]，因此原有注入点不受影响。
  static SystemProxyController forPlatform({ProcessRunner? runner}) {
    if (defaultTargetPlatform == TargetPlatform.linux) {
      return LinuxSystemProxy(
        dataDir: resolveDesktopPaths(
          platform: defaultTargetPlatform,
          environment: Platform.environment,
        ).dataDir,
        environment: Platform.environment,
        runner: runner ?? const RealProcessRunner(),
      );
    }
    return const SystemProxy();
  }

  @override
  Future<bool> set({required String host, required int port}) async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>(
            'setSystemProxy',
            '$host:$port',
          ) ??
          false;
    } on Object {
      return false;
    }
  }

  @override
  Future<bool> clear() async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('clearSystemProxy') ?? false;
    } on Object {
      return false;
    }
  }

  /// 是否存在上次未还原的备份。
  Future<bool> hasBackup() async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('hasProxyBackup') ?? false;
    } on Object {
      return false;
    }
  }

  @override
  Future<bool> recoverIfNeeded() async {
    if (!await hasBackup()) return false;
    return clear();
  }
}

// ---------------------------------------------------------------- Linux

/// Linux 上能真正写入代理设置的桌面环境类型。
///
/// 只区分两类有统一接口的桌面。其它环境（XFCE、sway、i3……）没有共同的配置
/// 后端，宁可如实返回失败，也不去猜一个配置文件乱写——那会把用户自己的
/// 设置改坏，而用户完全看不出是 VPN 干的。
enum LinuxDesktopKind { gnome, kde }

/// Linux 系统代理。
///
/// 与 Windows 同一种模型：只设置系统代理，不创建 TUN、不需要任何权限，因此
/// 立即生效；代价是只有认系统代理的程序会走隧道（浏览器、绝大多数桌面软件）。
/// 需要接管游戏、命令行工具时要等后续的 TUN 阶段（见 `singbox_config.dart`
/// 里 `InboundMode` 的说明），那条路需要 polkit 提权的辅助进程，本轮不做。
///
/// 备份写成 XDG 数据目录里的 `system_proxy_backup.json`。**没有备份就什么都
/// 不做**：原值只可能来自我们自己的接管，凭空猜一个「原来的设置」去写回去
/// 比不还原更危险。
class LinuxSystemProxy implements SystemProxyController {
  LinuxSystemProxy({
    required this.dataDir,
    required this.environment,
    this.runner = const RealProcessRunner(),
  });

  final Directory dataDir;

  /// 进程环境。抽成参数而不是直接读 [Platform.environment]，同样是为了可测。
  final Map<String, String> environment;

  final ProcessRunner runner;

  /// 备份文件名。用文件而不是 gsettings 自己的键：备份必须能跨进程存活，
  /// 且不能写进用户正在使用的同一个 schema（那会被当成用户设置）。
  static const String backupFileName = 'system_proxy_backup.json';

  static const String _proxySchema = 'org.gnome.system.proxy';
  static const String _httpSchema = 'org.gnome.system.proxy.http';
  static const String _httpsSchema = 'org.gnome.system.proxy.https';
  static const String _socksSchema = 'org.gnome.system.proxy.socks';

  /// 绕过代理的地址。必须包含回环：内核自己的 Clash API 也走 TCP，若把它
  /// 一起送进代理，观测引擎会绕回自己，表现为「连上了但什么都读不到」。
  static const String _ignoreHosts = "['localhost', '127.0.0.1', '::1']";

  static const String _kdeFile = 'kioslaverc';
  static const String _kdeGroup = 'Proxy Settings';

  /// GNOME 需要备份的键。格式为 `schema|key`，`gsettings get` 的原始输出
  /// 原样存下并原样写回——它本身就是 GVariant 文本，自己解析反而会引入
  /// 类型错误（例如把枚举当成字符串）。
  static const List<(String, String)> _gnomeKeys = <(String, String)>[
    (_proxySchema, 'mode'),
    (_httpSchema, 'host'),
    (_httpSchema, 'port'),
    (_httpsSchema, 'host'),
    (_httpsSchema, 'port'),
    (_socksSchema, 'host'),
    (_socksSchema, 'port'),
    (_proxySchema, 'ignore-hosts'),
  ];

  /// KDE 需要备份的键。
  static const List<(String, String)> _kdeKeys = <(String, String)>[
    (_kdeGroup, 'ProxyType'),
    (_kdeGroup, 'httpProxy'),
    (_kdeGroup, 'httpsProxy'),
    (_kdeGroup, 'ftpProxy'),
    (_kdeGroup, 'socksProxy'),
    (_kdeGroup, 'NoProxyFor'),
  ];

  File get backupFile =>
      File('${dataDir.path}${Platform.pathSeparator}$backupFileName');

  /// 是否存在尚未还原的备份。
  bool get hasBackup => backupFile.existsSync();

  /// 识别桌面环境。识别不出时返回 null，调用方据此如实失败。
  LinuxDesktopKind? detectDesktop() {
    final raw = <String>[
      environment['XDG_CURRENT_DESKTOP'] ?? '',
      environment['XDG_SESSION_DESKTOP'] ?? '',
      environment['DESKTOP_SESSION'] ?? '',
    ].join(':').toUpperCase();
    if (raw.isEmpty) return null;
    if (raw.contains('GNOME') ||
        raw.contains('UNITY') ||
        raw.contains('CINNAMON') ||
        raw.contains('BUDGIE')) {
      return LinuxDesktopKind.gnome;
    }
    if (raw.contains('KDE')) return LinuxDesktopKind.kde;
    return null;
  }

  @override
  Future<bool> set({required String host, required int port}) async {
    final desktop = detectDesktop();
    if (desktop == null) return false;
    try {
      // 已有备份时**不覆盖**：那份备份记的是用户原本的设置，而当前系统里
      // 的值可能已经是我们自己写进去的（例如上一次连接崩溃后重启）。
      var backup = _readBackup();
      if (backup == null) {
        backup = await _capture(desktop);
        if (backup == null) return false;
        if (!_writeBackup(backup)) return false;
      }
      return await _apply(backup, host, port);
    } on Object {
      return false;
    }
  }

  @override
  Future<bool> clear() async {
    final backup = _readBackup();
    if (backup == null) return false;
    try {
      final restored = await _restore(backup);
      // **只有还原成功才消费备份**。反过来（无条件删）会留下一个很难查的
      // 后果：写回失败、备份却没了，下次启动无从兜底，用户网络一直坏着。
      if (restored) _deleteBackup();
      return restored;
    } on Object {
      return false;
    }
  }

  @override
  Future<bool> recoverIfNeeded() async {
    // 严格无备份即无操作：main.dart 每次启动都会调这里，不能在没备份的
    // 机器上碰 gsettings。
    if (!hasBackup) return false;
    return clear();
  }

  // ------------------------------------------------------------ 备份读写

  _ProxyBackup? _readBackup() {
    try {
      if (!backupFile.existsSync()) return null;
      final raw = backupFile.readAsStringSync();
      if (raw.trim().isEmpty) return null;
      return _ProxyBackup.fromJson(jsonDecode(raw));
    } on Object {
      return null;
    }
  }

  bool _writeBackup(_ProxyBackup backup) {
    try {
      dataDir.createSync(recursive: true);
      // 先写临时文件再改名：写入过程中被强杀也不会留下半截 JSON，
      // 否则下次启动读不出来，备份就白做了。
      final tmp = File('${backupFile.path}.tmp');
      tmp.writeAsStringSync(jsonEncode(backup.toJson()), flush: true);
      tmp.renameSync(backupFile.path);
      return true;
    } on Object {
      return false;
    }
  }

  void _deleteBackup() {
    try {
      if (backupFile.existsSync()) backupFile.deleteSync();
    } on Object {
      // 删不掉不影响功能。
    }
  }

  // ------------------------------------------------------------ GNOME

  Future<_ProxyBackup?> _capture(LinuxDesktopKind desktop) async {
    switch (desktop) {
      case LinuxDesktopKind.gnome:
        final values = <String, String>{};
        for (final entry in _gnomeKeys) {
          final result = await runner.run('gsettings', <String>[
            'get',
            entry.$1,
            entry.$2,
          ]);
          // 退出码非零说明这台机器上并没有这些键（或 gsettings 被策略限制）。
          // 不能当成「原值为空」继续，否则还原时会把用户设置写成空。
          if (result.exitCode != 0) return null;
          values['${entry.$1}|${entry.$2}'] = '${result.stdout}'.trim();
        }
        return _ProxyBackup(desktop: desktop, values: values);
      case LinuxDesktopKind.kde:
        return _captureKde();
    }
  }

  Future<bool> _apply(_ProxyBackup backup, String host, int port) async {
    switch (backup.desktop) {
      case LinuxDesktopKind.gnome:
        // 三处（http/https/socks）都指向同一个混合入站：sing-box 的 mixed
        // 入站在同一端口上同时说 HTTP 与 SOCKS，分开只写一种是常见误配。
        final commands = <List<String>>[
          <String>['set', _proxySchema, 'mode', 'manual'],
          <String>['set', _httpSchema, 'host', host],
          <String>['set', _httpSchema, 'port', '$port'],
          <String>['set', _httpsSchema, 'host', host],
          <String>['set', _httpsSchema, 'port', '$port'],
          <String>['set', _socksSchema, 'host', host],
          <String>['set', _socksSchema, 'port', '$port'],
          <String>['set', _proxySchema, 'ignore-hosts', _ignoreHosts],
        ];
        for (final args in commands) {
          final result = await runner.run('gsettings', args);
          if (result.exitCode != 0) return false;
        }
        return true;
      case LinuxDesktopKind.kde:
        return _applyKde(backup, host, port);
    }
  }

  Future<bool> _restore(_ProxyBackup backup) async {
    switch (backup.desktop) {
      case LinuxDesktopKind.gnome:
        for (final entry in backup.values.entries) {
          final split = entry.key.indexOf('|');
          if (split <= 0) continue;
          final result = await runner.run('gsettings', <String>[
            'set',
            entry.key.substring(0, split),
            entry.key.substring(split + 1),
            entry.value,
          ]);
          if (result.exitCode != 0) return false;
        }
        return true;
      case LinuxDesktopKind.kde:
        return _restoreKde(backup);
    }
  }

  // ------------------------------------------------------------ KDE（次要）

  /// KDE 的读写工具按 Frameworks 版本分 `kreadconfig5/6`。逐个探测而不是
  /// 假装某个版本一定存在。
  Future<String?> _firstAvailable(List<String> candidates) async {
    for (final candidate in candidates) {
      try {
        await runner.run(candidate, const <String>['--help']);
        return candidate;
      } on ProcessException {
        continue;
      }
    }
    return null;
  }

  Future<_ProxyBackup?> _captureKde() async {
    final reader = await _firstAvailable(<String>[
      'kreadconfig6',
      'kreadconfig5',
    ]);
    if (reader == null) return null;
    final values = <String, String>{};
    for (final entry in _kdeKeys) {
      final result = await runner.run(reader, <String>[
        '--file',
        _kdeFile,
        '--group',
        entry.$1,
        '--key',
        entry.$2,
      ]);
      // 键不存在时 kreadconfig 退出码为 1、输出为空；这在本实现里是正常情况
      // （用户从未设置过代理），必须记成空值，否则整个接管都会失败。
      values['${entry.$1}|${entry.$2}'] = result.exitCode == 0
          ? '${result.stdout}'.trim()
          : '';
    }
    final writer = reader.replaceFirst('kreadconfig', 'kwriteconfig');
    return _ProxyBackup(
      desktop: LinuxDesktopKind.kde,
      values: values,
      kdeTool: writer,
    );
  }

  Future<bool> _applyKde(_ProxyBackup backup, String host, int port) async {
    final writer = backup.kdeTool ?? 'kwriteconfig5';
    final commands = <List<String>>[
      <String>[
        '--file',
        _kdeFile,
        '--group',
        _kdeGroup,
        '--key',
        'ProxyType',
        '1',
      ],
      <String>[
        '--file',
        _kdeFile,
        '--group',
        _kdeGroup,
        '--key',
        'httpProxy',
        'http://$host:$port',
      ],
      <String>[
        '--file',
        _kdeFile,
        '--group',
        _kdeGroup,
        '--key',
        'httpsProxy',
        'http://$host:$port',
      ],
      <String>[
        '--file',
        _kdeFile,
        '--group',
        _kdeGroup,
        '--key',
        'ftpProxy',
        'http://$host:$port',
      ],
      <String>[
        '--file',
        _kdeFile,
        '--group',
        _kdeGroup,
        '--key',
        'socksProxy',
        'socks://$host:$port',
      ],
      <String>[
        '--file',
        _kdeFile,
        '--group',
        _kdeGroup,
        '--key',
        'NoProxyFor',
        'localhost,127.0.0.1,::1',
      ],
    ];
    for (final args in commands) {
      final result = await runner.run(writer, args);
      if (result.exitCode != 0) return false;
    }
    // 让已打开的 KDE 应用立刻读到新配置。没有 dbus-send 也不影响配置已写好。
    try {
      await runner.run('dbus-send', <String>[
        '--type=signal',
        '/KIO/Scheduler',
        'org.kde.KIO.Scheduler.reparseSlaveConfiguration',
        "string:''",
      ]);
    } on ProcessException {
      // 忽略：下次启动应用时仍会读到新配置。
    }
    return true;
  }

  Future<bool> _restoreKde(_ProxyBackup backup) async {
    final writer = backup.kdeTool ?? 'kwriteconfig5';
    for (final entry in backup.values.entries) {
      final split = entry.key.indexOf('|');
      if (split <= 0) continue;
      final args = <String>[
        '--file',
        _kdeFile,
        '--group',
        entry.key.substring(0, split),
        '--key',
        entry.key.substring(split + 1),
      ];
      if (entry.value.isEmpty) {
        // 原值不存在：必须**删掉**我们写进去的键，而不是留一个空字符串，
        // 否则 KDE 会把它读成「代理地址为空」而不是「没有代理」。
        args.add('--delete');
      } else {
        args.add(entry.value);
      }
      final result = await runner.run(writer, args);
      if (result.exitCode != 0) return false;
    }
    return true;
  }
}

/// 落盘的代理备份。结构变化时靠 [desktop] 区分，不靠字段猜测。
class _ProxyBackup {
  _ProxyBackup({required this.desktop, required this.values, this.kdeTool});

  final LinuxDesktopKind desktop;
  final Map<String, String> values;

  /// KDE 写入工具的完整名字。GNOME 下为 null。
  final String? kdeTool;

  Map<String, Object?> toJson() => <String, Object?>{
    'desktop': desktop.name,
    'values': values,
    if (kdeTool != null) 'kdeTool': kdeTool,
  };

  static _ProxyBackup? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? desktopName = raw['desktop'];
    final Object? values = raw['values'];
    if (desktopName is! String || values is! Map) return null;
    LinuxDesktopKind? kind;
    for (final LinuxDesktopKind candidate in LinuxDesktopKind.values) {
      if (candidate.name == desktopName) {
        kind = candidate;
        break;
      }
    }
    if (kind == null) return null;
    final decoded = <String, String>{};
    for (final MapEntry<Object?, Object?> entry in values.entries) {
      if (entry.key is String && entry.value is String) {
        decoded[entry.key! as String] = entry.value! as String;
      }
    }
    final Object? tool = raw['kdeTool'];
    return _ProxyBackup(
      desktop: kind,
      values: decoded,
      kdeTool: tool is String ? tool : null,
    );
  }
}
