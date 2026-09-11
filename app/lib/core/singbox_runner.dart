import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models.dart';
import 'auto_route.dart';
import 'cn_ip_index.dart';
import 'core_monitor.dart';
import 'rulesets.dart';
import 'singbox_config.dart';
import 'system_proxy.dart';
import 'vpn_core.dart';

/// 真实内核：以子进程方式运行随包分发的 sing-box。
///
/// 工作流程与「傻瓜式」的对应关系：
///   1. 把 .conf 翻译成 sing-box 配置（[SingBoxConfigBuilder]）；
///   2. 启动内核，内核按内置规则库 + 自动纠正表自行判定国内直连 / 国外走隧道；
///   3. 接管系统代理，让浏览器与绝大多数软件无需任何设置即可生效；
///   4. 从 Clash API 读取真实连接，界面上的「分流记录」由此而来——
///      不是模拟数据，而是内核实际做出的判定。
///
/// 观测部分（Clash API 轮询、速率、失败归因、DNS 监测、启动自检）全部在
/// [CoreMonitor] 里，与安卓端共用同一份实现，统计口径因此完全一致。
class SingBoxRunner extends VpnCore {
  SingBoxRunner(super.listener, {super.probesEnabled});

  /// 混合入站端口。与 [SingBoxConfigBuilder.defaultMixedPort] 保持一致。
  static const int mixedPort = SingBoxConfigBuilder.defaultMixedPort;
  static const int clashApiPort = SingBoxConfigBuilder.defaultClashApiPort;

  Process? _process;
  final List<String> _logTail = <String>[];

  /// 自动纠正表。跨连接保留，因此用户不用每次重连都重新学习一遍。
  final AutoRouteTable _autoRoute = AutoRouteTable();

  CnIpIndex _cnIpIndex = CnIpIndex.empty;
  bool _indexLoaded = false;

  bool _proxyTakenOver = false;

  @override
  String get name => 'sing-box 1.14.0';

  @override
  CnIpIndex get cnIpIndex => _cnIpIndex;

  @override
  void initAutoRoute(Object? saved) => _autoRoute.loadFrom(saved);

  @override
  List<Map<String, Object?>> exportAutoRoute() => _autoRoute.toJson();

  @override
  CoreMonitorHooks monitorHooks() => CoreMonitorHooks(
        listener: listener,
        clashApiPort: clashApiPort,
        autoRoute: _autoRoute,
        cnIpIndex: _cnIpIndex,
        probesEnabled: probesEnabled,
      );

  // ---------------------------------------------------------------- 启动

  @override
  Future<void> connect(VpnProfile profile, AppSettings settings) async {
    await disconnect();
    listener.onStatusChanged(VpnStatus.connecting);

    try {
      final runtime = _resolveRuntimePaths();
      if (!runtime.singBoxExe.existsSync()) {
        listener.onError('未找到内核文件：${runtime.singBoxExe.path}');
        listener.onStatusChanged(VpnStatus.disconnected);
        return;
      }
      for (final ruleSet in runtime.ruleSets) {
        if (!ruleSet.existsSync()) {
          listener.onError('缺少规则库文件：${ruleSet.path}');
          listener.onStatusChanged(VpnStatus.disconnected);
          return;
        }
      }

      // 中国 IP 索引只在第一次连接时读一次，之后常驻。
      // 它是 DNS 交叉校验的地理判定依据，缺了只会让判定变保守，不影响连通性。
      if (!_indexLoaded) {
        _cnIpIndex = await CnIpIndex.load(assetsDir: runtime.assetDir);
        _indexLoaded = true;
      }

      runtime.workDir.createSync(recursive: true);
      // 1) 生成配置。规则集直接引用随包分发的文件，避免二次拷贝。
      //    每次都重新生成：这样自动纠正表里新学到的规则能在下次连接时生效。
      final config = SingBoxConfigBuilder.build(
        profile: profile.parsed,
        splitMode: settings.splitMode,
        ruleSetDir: runtime.ruleSetDir.path,
        logSplits: settings.logSplits,
        autoRoute: _autoRoute,
      );
      final configFile = File('${runtime.workDir.path}${Platform.pathSeparator}config.json');
      configFile.writeAsStringSync(SingBoxConfigBuilder.encode(config));

      // 2) 启动内核。先清掉上次可能残留的实例，否则端口会被占用。
      _killStaleCore(runtime.pidFile);
      _logTail.clear();
      _autoRoute.evictStale();
      final process = await Process.start(
        runtime.singBoxExe.path,
        <String>['run', '-c', configFile.path],
        workingDirectory: runtime.workDir.path,
        runInShell: false,
      );
      _process = process;
      runtime.pidFile.writeAsStringSync('${process.pid}');
      process.stdout.transform(utf8.decoder).listen(_appendLog);
      process.stderr.transform(utf8.decoder).listen(_appendLog);
      unawaited(process.exitCode.then((int code) async {
        if (_process != process) return;
        // 内核自己退出了：多半是配置或网络问题，把原因带出来。
        _process = null;
        monitor.stop();
        // 必须同时撤销系统代理。否则内核已经没了、代理还指着它，
        // 用户的所有网站都会打不开，而且完全看不出原因。
        if (_proxyTakenOver) {
          await SystemProxy.clear();
          _proxyTakenOver = false;
        }
        _deletePidFile();
        listener.onError('内核已退出（代码 $code）${_logTail.isEmpty ? '' : '：${_logTail.last}'}');
        listener.onStatusChanged(VpnStatus.disconnected);
      }));

      // 3) 等内核就绪：Clash API 能应答就说明配置已经完整加载。
      final ready = await monitor.waitForApi(
        const Duration(seconds: 12),
        isAlive: () => _process != null,
      );
      if (!ready) {
        final detail = _logTail.isEmpty ? '' : '：${_logTail.last}';
        listener.onError('内核启动超时$detail');
        await disconnect();
        return;
      }

      // 4) 接管系统代理。
      //
      // 桌面端只有这一条可用路径。sing-box 的 tun 入站需要 wintun.dll 与管理员
      // 权限，两者都不具备，因此这里不再提供「TUN」选项（设置页已说明）；
      // 若历史设置里残留了 TUN，也在恢复时被忽略，不会出现「选了却不生效」
      // 的假象——那意味着界面上写着「接管全部程序」，实际只有认系统代理的
      // 程序走隧道，而用户完全看不出区别。
      _proxyTakenOver = await SystemProxy.set(
        host: '127.0.0.1',
        port: mixedPort,
      );
      if (!_proxyTakenOver) {
        listener.onError('无法设置系统代理，请检查系统设置是否被策略锁定');
      }

      listener.onStatusChanged(VpnStatus.connected);
      // 观测引擎在状态变为已连接之后启动：
      // 它第一件事就是探测 DNS 与自检，界面此时已经有「已连接」这个前提了。
      monitor.start();
    } on Object catch (e) {
      listener.onError('启动失败：$e');
      await disconnect();
    }
  }

  // ---------------------------------------------------------------- 停止

  @override
  Future<void> disconnect() async {
    monitor.stop();

    if (_proxyTakenOver) {
      await SystemProxy.clear();
      _proxyTakenOver = false;
    }

    final process = _process;
    _process = null;
    if (process != null) {
      process.kill();
      // 给它一点时间做清理；超时就不再等。
      await process.exitCode.timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
      _deletePidFile();
    }

    listener.onTraffic(downBps: 0, upBps: 0, totalBytes: 0);
    listener.onLatency(null);
    listener.onStatusChanged(VpnStatus.disconnected);
  }

  @override
  void dispose() {
    monitor.stop();
    _process?.kill();
    _process = null;
    super.dispose();
  }

  // ------------------------------------------------------------ 运行时路径

  /// 随包分发的内核与规则库所在位置。
  ///
  /// 内核是可执行文件，由 Windows 构建脚本直接放在 xvpn.exe 旁边（见
  /// windows/CMakeLists.txt），不走 Flutter 资源体系；规则集体积很小，
  /// 作为资源分发，两端共用。
  ({
    File singBoxExe,
    Directory ruleSetDir,
    List<File> ruleSets,
    Directory workDir,
    File pidFile,
    Directory assetDir,
  }) _resolveRuntimePaths() {
    final exeDir = File(Platform.resolvedExecutable).parent;
    final assetDir = Directory(
      '${exeDir.path}${Platform.pathSeparator}data${Platform.pathSeparator}flutter_assets'
      '${Platform.pathSeparator}assets${Platform.pathSeparator}rulesets',
    );
    final ruleDir = assetDir;

    final localAppData = Platform.environment['LOCALAPPDATA'] ??
        Directory.systemTemp.path;
    final workDir = Directory(
      '$localAppData${Platform.pathSeparator}XVPN${Platform.pathSeparator}runtime',
    );

    return (
      singBoxExe: File('${exeDir.path}${Platform.pathSeparator}sing-box.exe'),
      // 规则库用可写目录里的副本：出厂副本首次运行时复制过去，之后可由
      // 「检查更新」覆盖，既保证离线可用，又不依赖安装目录的写权限。
      ruleSetDir: RuleSetStore.ensure(ruleDir),
      ruleSets: <File>[
        File('${ruleDir.path}${Platform.pathSeparator}geosite-cn.srs'),
        File('${ruleDir.path}${Platform.pathSeparator}geoip-cn.srs'),
      ],
      workDir: workDir,
      // 内核 PID。正常关闭由原生侧按「自己的子进程」精确清理；这里用于
      // 「被强杀」的场景：下次启动据此清掉残留实例，否则端口会被一直占着。
      pidFile: File('${workDir.path}${Platform.pathSeparator}core.pid'),
      assetDir: assetDir,
    );
  }

  /// 删除 PID 文件。正常断开时内核已确认退出，这个文件就失去意义了。
  void _deletePidFile() {
    try {
      final pid = _resolveRuntimePaths().pidFile;
      if (pid.existsSync()) pid.deleteSync();
    } on Object {
      // 删不掉也不影响功能。
    }
  }

  /// 清理上次被强杀后残留的内核进程。
  ///
  /// 必须校验进程名：PID 会被系统复用，只按数字杀进程可能误伤别的程序。
  void _killStaleCore(File pidFile) {
    try {
      if (!pidFile.existsSync()) return;
      final pid = int.tryParse(pidFile.readAsStringSync().trim());
      pidFile.deleteSync();
      if (pid == null || pid <= 0) return;

      final probe = Process.runSync(
        'tasklist',
        <String>['/FI', 'PID eq $pid', '/NH', '/FO', 'CSV'],
      );
      if (!probe.stdout.toString().toLowerCase().contains('sing-box.exe')) {
        return;
      }
      Process.runSync('taskkill', <String>['/F', '/PID', '$pid']);
      listener.onError('已清理上次残留的内核进程（PID $pid）');
    } on Object {
      // 清理失败不阻断连接：端口若真被占用，内核启动时会自己报错。
    }
  }

  // ---------------------------------------------------------------- 日志

  void _appendLog(String chunk) {
    for (final line in chunk.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      _logTail.add(trimmed);
      // 顺路做失败归因与自动纠正：内核在失败日志里写明了走的哪个出站，
      // 这正是区分「规则判错」与「节点不通」所需要的唯一信息。
      handleCoreLog(trimmed);
    }
    // 只保留最近若干行，够诊断即可。
    while (_logTail.length > 40) {
      _logTail.removeAt(0);
    }
  }
}
