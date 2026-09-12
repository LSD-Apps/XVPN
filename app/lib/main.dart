import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_state.dart';
import 'core/android_vpn_core.dart';
import 'core/licenses.dart';
import 'core/singbox_runner.dart';
import 'core/store.dart';
import 'core/system_proxy.dart';
import 'core/vpn_core.dart';
import 'core/window_controls.dart';
import 'protocols/vpn_protocol.dart';
import 'screens/import_conf.dart';
import 'screens/shell.dart';
import 'theme.dart';
import 'theme_controller.dart';

/// 入口。桌面端支持把配置文件路径作为启动参数传入，
/// 这样就实现了「双击配置文件直接用 XVPN 打开」。
///
/// main 必须是 async：持久化目录在安卓上要问原生要（`filesDir`），
/// 而配置必须在第一帧之前恢复好，否则界面会先闪一下空状态。
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // 把 LICENSE / NOTICE.md / THIRD-PARTY-NOTICES.md 注册进 LicenseRegistry，
  // 设置页的「开源许可」界面才能读到它们。注册是惰性的，真正读文件发生在
  // 用户打开该页面时。
  registerBundledLicenses();
  // 接住原生推来的窗口最大化状态：标题栏的「最大化 / 还原」图标据此切换，
  // 而双击标题栏、Win+↑、贴边这些由系统直接处理的最大化，Dart 侧只有靠它才知道。
  await WindowControls.listen();
  final store = await _resolveStore();
  runApp(XvpnApp(launchConfPath: _confPathFromArgs(args), store: store));
}

/// 安卓侧的原生通道。桌面端用不到——桌面走命令行参数打开配置文件。
const MethodChannel _androidChannel = MethodChannel('com.xvpn.xvpn/vpn');

/// 解析持久化目录。拿不到时返回 null：不落盘也比起不来强。
Future<AppStore?> _resolveStore() async {
  try {
    // 安卓的沙箱目录名不固定，只能问原生侧要；桌面端用固定的本地目录。
    if (defaultTargetPlatform == TargetPlatform.android) {
      final dir = await _androidChannel.invokeMethod<String>('filesDir');
      if (dir == null || dir.isEmpty) return null;
      return AppStore(Directory(dir));
    }
    return AppStore(AppStore.defaultDesktopDir());
  } on Object {
    return null;
  }
}

/// 从命令行参数里挑出第一个指向受支持配置文件的路径。
///
/// 扩展名取自协议注册表而不是写死 `.conf`：OpenVPN 的 `.ovpn`
/// 同样要能双击打开，否则「打开方式」里选了 XVPN 却没反应。
/// 协议最终仍由内容识别，这里只负责把明显不是配置文件的参数挡掉。
String? _confPathFromArgs(List<String> args) {
  for (final arg in args) {
    if (arg.startsWith('-')) continue;
    final lower = arg.toLowerCase();
    if (!allSupportedExtensions.any((String ext) => lower.endsWith('.$ext'))) {
      continue;
    }
    if (File(arg).existsSync()) return arg;
  }
  return null;
}

String _basename(String path) => path.split(RegExp(r'[\\/]')).last;

/// 应用入口。全局状态与主题控制器在这里创建，向下传给外壳与各页面。
class XvpnApp extends StatefulWidget {
  const XvpnApp({super.key, this.launchConfPath, this.store});

  /// 启动时自动导入的配置文件路径（可选）。
  final String? launchConfPath;

  /// 本地持久化。为 null 时本次运行不落盘。
  final AppStore? store;

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
      TargetPlatform.windows => (VpnCoreListener listener) => SingBoxRunner(
        listener,
      ),
      // Linux 与 Windows 走同一条路径：内核以子进程运行、只做系统代理接管。
      // TUN 阶段尚未实现，因此不引入任何需要特权的东西（见
      // core/singbox_config.dart 里的 InboundMode 说明）。
      TargetPlatform.linux => (VpnCoreListener listener) => SingBoxRunner(
        listener,
      ),
      TargetPlatform.android => (VpnCoreListener listener) => AndroidVpnCore(
        listener,
      ),
      // 其它平台尚未接入内核，先用演示内核驱动界面，
      // 避免出现「看起来能连、其实没连」的假象。
      _ => (VpnCoreListener listener) => DemoVpnCore(listener),
    };
  }

  late final AppState _state = AppState(
    coreFactory: _coreFactory,
    store: widget.store,
  );

  final ThemeController _theme = ThemeController();

  @override
  void initState() {
    super.initState();
    // 幂等：main() 已调用过一次；这里再兜一次，保证以 XvpnApp 为入口的
    // 测试/嵌入场景也能在许可页看到本项目许可，而不依赖具体启动路径。
    registerBundledLicenses();
    // 上次若被强杀，系统代理可能还指着已经退出的内核，先恢复回去。
    // Linux 侧严格只在**存在备份文件**时才动作（recoverIfNeeded 里判断），
    // 因此没有备份的机器上不会去碰 gsettings。
    unawaited(SystemProxy.forPlatform().recoverIfNeeded());
    _listenSharedConfig();

    // 启动参数里的配置优先导入（「双击配置文件打开」的场景）。
    final path = widget.launchConfPath;
    if (path != null) {
      // 延后到第一帧之后：导入过程可能弹出「填写账号密码」表单，而补填表单
      // 需要 Navigator，initState 阶段还没有。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_importFromLaunchPath(path));
      });
      return;
    }

    // 没有新配置时恢复上次的状态：先看内核是不是还在跑（安卓的隧道活在前台
    // 服务里，界面被回收后它仍然在运行），否则按用户离开时的意图重新拨号。
    // 走启动参数的分支不做这件事——那说明用户刚导入了一份新配置。
    unawaited(_state.restoreConnection());
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
      final shared = await _androidChannel.invokeMethod<Map<Object?, Object?>>(
        'takeSharedConfig',
      );
      if (shared == null) return;
      final name = shared['name'] as String? ?? 'shared.conf';
      final text = shared['text'] as String?;
      if (text == null || text.isEmpty) return;
      if (!mounted) {
        // 没有可用页面时退化为直接导入：至少配置不会因为弹不出表单而丢掉。
        importConfDirect(_state, text: text, fileName: name);
        return;
      }
      // 与界面导入一致：先弹出确认表单，不静默导入。
      await reviewAndImportConf(context, _state, text: text, fileName: name);
    } on Object catch (e) {
      _state.reportError('导入分享的配置失败：$e');
    }
  }

  /// 导入启动参数指定的配置文件。
  ///
  /// 先单独读文件：读不到时的提示要带上路径，用户才知道双击的那份文件怎么了；
  /// 而解析类的错误由统一的导入路径给出，消息本身已经足够清楚。
  Future<void> _importFromLaunchPath(String path) async {
    final String text;
    try {
      text = File(path).readAsStringSync();
    } on Object catch (e) {
      _state.reportError('无法读取 $path：$e');
      return;
    }
    if (!mounted) {
      // 启动瞬间还没有 Navigator：退化为直接导入，配置不会丢。
      importConfDirect(_state, text: text, fileName: _basename(path));
      return;
    }
    // 与界面导入一致：先弹出确认表单，不静默导入。
    await reviewAndImportConf(
      context,
      _state,
      text: text,
      fileName: _basename(path),
    );
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
            builder: (BuildContext inner) =>
                XvShell(state: _state, theme: _theme),
          ),
          builder: (BuildContext context, Widget? child) {
            // 只锁定文字缩放，保证两端排版与设计稿一致；亮度交由主题系统决定。
            return MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.noScaling),
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
      Theme.of(context).brightness == Brightness.dark
          ? XvPalette.dark
          : XvPalette.light,
    );
    return builder(context);
  }
}
