import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_state.dart';
import 'core/android_vpn_core.dart';
import 'core/singbox_runner.dart';
import 'core/system_proxy.dart';
import 'core/vpn_core.dart';
import 'screens/shell.dart';
import 'theme.dart';
import 'theme_controller.dart';

/// 入口。桌面端支持把 .conf 路径作为启动参数传入，
/// 这样就实现了「双击 .conf 直接用 XVPN 打开」。
void main(List<String> args) {
  runApp(XvpnApp(launchConfPath: _confPathFromArgs(args)));
}

/// 从命令行参数里挑出第一个指向 .conf 文件的路径。
String? _confPathFromArgs(List<String> args) {
  for (final arg in args) {
    if (arg.startsWith('-')) continue;
    if (!arg.toLowerCase().endsWith('.conf')) continue;
    if (File(arg).existsSync()) return arg;
  }
  return null;
}

String _basename(String path) => path.split(RegExp(r'[\\/]')).last;

/// 应用入口。全局状态与主题控制器在这里创建，向下传给外壳与各页面。
class XvpnApp extends StatefulWidget {
  const XvpnApp({super.key, this.launchConfPath});

  /// 启动时自动导入的 .conf 路径（可选）。
  final String? launchConfPath;

  @override
  State<XvpnApp> createState() => _XvpnAppState();
}

class _XvpnAppState extends State<XvpnApp> {
  /// 按平台选择内核实现。
  ///
  /// 两端的分流规则、DNS 策略、配置生成与连接观测完全相同，
  /// 差别只在「内核怎么跑」和「流量怎么接管」。
  static VpnCore Function(VpnCoreListener listener) get _coreFactory {
    return switch (defaultTargetPlatform) {
      TargetPlatform.windows => (VpnCoreListener listener) => SingBoxRunner(listener),
      TargetPlatform.android => (VpnCoreListener listener) => AndroidVpnCore(listener),
      // 其它平台尚未接入内核，先用演示内核驱动界面，
      // 避免出现「看起来能连、其实没连」的假象。
      _ => (VpnCoreListener listener) => DemoVpnCore(listener),
    };
  }

  late final AppState _state = AppState(coreFactory: _coreFactory);

  final ThemeController _theme = ThemeController();

  /// 安卓侧的通道。桌面端用不到——桌面走命令行参数打开 .conf。
  static const MethodChannel _androidChannel = MethodChannel('com.xvpn.xvpn/vpn');

  @override
  void initState() {
    super.initState();
    // 上次若被强杀，系统代理可能还指着已经退出的内核，先恢复回去。
    unawaited(SystemProxy.recoverIfNeeded());
    _listenSharedConfig();
    // 安卓的隧道跑在前台服务里，界面被回收后隧道仍在运行，这里把状态接回来。
    unawaited(_state.adoptRunningCore());

    final path = widget.launchConfPath;
    if (path == null) return;
    try {
      _state.importConf(text: File(path).readAsStringSync(), fileName: _basename(path));
    } on Object catch (e) {
      // 启动参数里的配置有问题时不能影响界面可用性，只提示失败原因。
      _state.reportError(
        '无法导入 $path：${e.toString().replaceFirst('WireGuardConfException: ', '')}',
      );
    }
  }

  /// 处理安卓从文件管理器「打开 / 分享」进来的配置。
  ///
  /// 安卓上 App 拿不到命令行参数，这是除界面导入之外唯一的入口。
  /// 原生侧会把内容存起来等 Dart 来取，因此不会因为通道尚未就绪而丢事件。
  void _listenSharedConfig() {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    _androidChannel.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'sharedConfigAvailable') {
        await _consumeSharedConfig();
      }
    });
    unawaited(_consumeSharedConfig());
  }

  Future<void> _consumeSharedConfig() async {
    try {
      final shared =
          await _androidChannel.invokeMethod<Map<Object?, Object?>>('takeSharedConfig');
      if (shared == null) return;
      final name = shared['name'] as String? ?? 'shared.conf';
      final text = shared['text'] as String?;
      if (text == null || text.isEmpty) return;
      _state.importConf(text: text, fileName: name);
    } on Object catch (e) {
      _state.reportError('导入分享的配置失败：$e');
    }
  }

  @override
  void dispose() {
    _state.dispose();
    _theme.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: _theme,
      builder: (BuildContext context, ThemeMode mode, _) {
        return MaterialApp(
          title: 'XVPN',
          debugShowCheckedModeBanner: false,
          // 两套主题分别对应两套调色板，themeMode 决定用哪一套（system 交给 Flutter 判定）。
          theme: buildXvTheme(XvPalette.light),
          darkTheme: buildXvTheme(XvPalette.dark),
          themeMode: mode,
          // 用 builder 而不是直接给 home 传实例：每次重建都生成新的 widget，
          // 保证切换主题时下层界面一定会重新读取调色板。
          home: _PaletteSync(
            builder: (BuildContext inner) => XvShell(state: _state, theme: _theme),
          ),
          builder: (BuildContext context, Widget? child) {
            // 只锁定文字缩放，保证两端排版与设计稿一致；亮度交由主题系统决定。
            return MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling),
              child: child ?? const SizedBox.shrink(),
            );
          },
        );
      },
    );
  }
}

/// 把 Material 当前生效的亮度同步到全局调色板。
///
/// 界面统一通过 `XV.xxx` 读取颜色，因此必须在子树构建之前完成切换；
/// 它位于外壳之上，且每次重建都会重新求值，系统主题变化时同样会跟上。
class _PaletteSync extends StatelessWidget {
  const _PaletteSync({required this.builder});

  final Widget Function(BuildContext context) builder;

  @override
  Widget build(BuildContext context) {
    applyPalette(
      Theme.of(context).brightness == Brightness.dark ? XvPalette.dark : XvPalette.light,
    );
    return builder(context);
  }
}
