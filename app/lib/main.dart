import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_state.dart';
import 'core/android_channel.dart';
import 'core/android_vpn_core.dart';
import 'core/screen_navigation.dart';
import 'core/secret_protector.dart';
import 'core/singbox_runner.dart';
import 'core/store.dart';
import 'core/system_proxy.dart';
import 'core/update_center.dart';
import 'core/vpn_core.dart';
import 'core/window_controls.dart';
import 'protocols/vpn_protocol.dart';
import 'screens/import_conf.dart';
import 'screens/legal_notice_dialog.dart';
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
  // 接住原生推来的窗口最大化状态：标题栏的「最大化 / 还原」图标据此切换，
  // 而双击标题栏、Win+↑、贴边这些由系统直接处理的最大化，Dart 侧只有靠它才知道。
  await WindowControls.listen();
  final store = await _resolveStore();
  // 账号密码的落盘保护必须在构造 AppState **之前**定下来：安卓要用 Keystore
  // 解开数据密钥，而那是异步的，而 AppState 是在构造里同步恢复凭据的。放在这里
  // 也是唯一能放的地方——晚于第一帧就等于让界面先显示一份「没有密码的配置」。
  final protector = await SecretProtector.resolve(directory: store?.directory);
  runApp(
    XvpnApp(
      launchConfPath: _confPathFromArgs(args),
      store: store,
      protector: protector,
    ),
  );

  // 启动后的静默更新检查。放在第一帧之后：它绝不能拖慢首帧；失败也绝不能
  // 打扰用户——checkOnStartup 在内部把失败处理成与「没有更新」完全一致，
  // 结果只共享给标题栏与设置页卡片，不弹任何对话框。
  //
  // 刻意放在顶层 main() 而不是 AppState 的 initState：测试会直接 pump
  // XvpnApp，若写在 initState 里，每个用例都会真的去摸一次网络。
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(UpdateCenter.instance.checkOnStartup());
  });
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
  const XvpnApp({
    super.key,
    this.launchConfPath,
    this.store,
    this.protector,
  });

  /// 启动时自动导入的配置文件路径（可选）。
  final String? launchConfPath;

  /// 本地持久化。为 null 时本次运行不落盘。
  final AppStore? store;

  /// 账号密码的落盘保护（可选）。
  ///
  /// 由 [main] 在构造本 Widget 之前解析好：安卓上要解一次 Keystore，那一步是
  /// 异步的，没法留到 [AppState] 的构造里。为 null 时交给
  /// [SecretProtector.forPlatform] 决定，也就是测试与桌面端的默认行为。
  final SecretProtector? protector;

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
    protector: widget.protector,
  );

  final ThemeController _theme = ThemeController();

  /// MaterialApp 之内那层 Navigator 的 Key。
  ///
  /// 导入确认表单必须从**这个** context 弹出，而不是 [State.context]：后者在
  /// `MaterialApp` **之上**，`showDialog` 从那里找不到 Navigator，表单永远弹不
  /// 出来——启动参数与安卓分享进来的配置就这样被静默丢掉（用户双击配置文件，
  /// 应用起来了，配置却没进去）。这类「什么都没发生」正是本项目最不能接受的
  /// 失败形态，因此这里用一个明确的 Key 把对话框的落点钉在 Navigator 上。
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  /// 能承载对话框的 context；Widget 已卸载或 Navigator 尚未挂载时为 null。
  BuildContext? get _dialogContext {
    if (!mounted) return null;
    return _navigatorKey.currentContext;
  }

  /// 取一个能弹出对话框的 context；Navigator 还没挂载时等一帧再试。
  ///
  /// 为什么值得等：安卓的分享配置会在 `initState` 阶段就推过来，那时第一帧还没
  /// 建、Navigator 自然不存在。此时直接退化成「静默导入」会跳过确认表单，而
  /// 「先让用户看清楚要导入什么」正是这条路径存在的全部意义——那是替用户做决定。
  /// 等一帧的代价是一个帧间隔，远小于这个代价。
  ///
  /// 仍然返回 null 只可能是 Widget 已经卸载（用户在这之前关掉了界面），那时才
  /// 退化为直接导入：配置宁可不经确认，也不能丢。
  Future<BuildContext?> _awaitDialogContext() async {
    final ready = _dialogContext;
    if (ready != null) return ready;
    await WidgetsBinding.instance.endOfFrame;
    return _dialogContext;
  }

  @override
  void initState() {
    super.initState();
    // 上次若被强杀，系统代理可能还指着已经退出的内核，先恢复回去。
    // Linux 侧严格只在**存在备份文件**时才动作（recoverIfNeeded 里判断），
    // 因此没有备份的机器上不会去碰 gsettings。
    unawaited(SystemProxy.forPlatform().recoverIfNeeded());
    _listenSharedConfig();
    // 托盘「退出 XVPN」与 SIGTERM/SIGINT 都走这条推送：原生不自己退出，先让
    // Dart 收尾（还原系统代理、结束 sing-box），再由原生退出。见
    // [WindowControls.onQuitRequested]。
    WindowControls.onQuitRequested = _shutdownForExit;
    // 托盘「发现新版本」：原生把窗口显示出来，这里让界面切到设置页的更新入口。
    // 走 ScreenNavigation 而不是直接改标签索引——那个「区域 → 本布局索引」的
    // 翻译由外壳负责，桌面与移动端落点不同（见 XvShell._onNavigationRequested）。
    WindowControls.onShowUpdateRequested = () =>
        ScreenNavigation.instance.request(AppSection.settings);

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
    // 盘上的规则集大小与存档里记的可能不一致（首次解包、手动替换过文件等）。
    // 与连接恢复并行做，互不依赖；它只影响「分流规则」页那一行展示。
    unawaited(_state.refreshRuleSetSizes());
  }

  /// 处理安卓从文件管理器「打开 / 分享」进来的配置。
  ///
  /// 安卓上 App 拿不到命令行参数，这是除界面导入之外唯一的入口。
  /// 原生侧会把内容存起来等 Dart 来取，因此不会因为通道尚未就绪而丢事件。
  void _listenSharedConfig() {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    // 走 [AndroidChannel] 而不是直接在这条通道上 setMethodCallHandler：同一条
    // 通道上还有 `AndroidVpnCore` 要收内核日志，而 Flutter 每条通道只保留一个
    // handler，后注册的会把先注册的静默顶掉。此前正是如此——应用连接过一次之后
    // 「分享配置进来」就再也不响应了，冷启动却正常。详见 AndroidChannel 的说明。
    AndroidChannel.addHandler((MethodCall call) async {
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
      await _confirmAndImport(text, name);
    } on Object catch (e) {
      _state.reportError('导入分享的配置失败：$e');
    }
  }

  /// 先弹出确认表单、用户点了「添加」才写进存档；界面已经卸载时直接导入。
  ///
  /// 抽出来是因为启动参数与安卓分享两条入口的差别只有文件名：它们都必须走同一
  /// 条「先确认再落盘」的路。原生侧的两条入口若各写一遍，迟早会有一条被改得
  /// 不一样——而这两条路里被静默跳过确认的那条，正是用户最没有机会察觉的。
  Future<void> _confirmAndImport(String text, String fileName) async {
    final dialogContext = await _awaitDialogContext();
    if (dialogContext == null) {
      // 界面已经卸载（用户在这之前关掉了界面）：退化为直接导入。
      // 配置宁可不经确认，也不能丢。
      importConfDirect(_state, text: text, fileName: fileName);
      return;
    }
    // 与界面导入一致：先弹出确认表单，不静默导入。
    //
    // 这个 context 是**等完之后**才从 [_navigatorKey] 现取的，不是跨 gap 的旧
    // context（[_awaitDialogContext] 内部已判过 mounted）；分析器看不穿这一层，
    // 而补一句 `if (!mounted) return;` 只是把同一个判断写两遍。
    // ignore: use_build_context_synchronously
    await reviewAndImportConf(dialogContext, _state, text: text, fileName: fileName);
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
    await _confirmAndImport(text, _basename(path));
  }

  @override
  void dispose() {
    WindowControls.onQuitRequested = null;
    _state.dispose();
    _theme.dispose();
    super.dispose();
  }

  /// 托盘退出 / SIGTERM 时先跑完 Dart 侧收尾。
  ///
  /// [AppState.disconnect] 会 **await** 两件必须完成的事：还原系统代理
  /// （Linux 上要执行 gsettings / kwriteconfig 这类外部命令）与结束 sing-box
  /// 子进程（最多再等它 3 秒）。先把进程退掉就会把这两步一起打断，用户会留下
  /// 一个指向死端口的系统代理和一个还在占端口的孤儿内核——正是本项目最不能
  /// 接受的那类故障。收尾完成后由 [WindowControls] 请原生退出。
  Future<void> _shutdownForExit() => _state.disconnect();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: _theme,
      builder: (BuildContext context, ThemeMode mode, _) {
        return MaterialApp(
          // 任务切换器里显示的名字。用产品中文名，与窗口标题、托盘一致。
          title: '幽门',
          debugShowCheckedModeBanner: false,
          // 导入确认表单要从 [_navigatorKey] 那层 context 弹出（见 [_dialogContext]）。
          navigatorKey: _navigatorKey,
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
            final Widget scaled = MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.noScaling),
              child: child ?? const SizedBox.shrink(),
            );
            // 确认层必须包在 Navigator 外面：导入对话框走 Navigator overlay，
            // 若确认层只盖在 home 上，用户可以不确认就导入配置。
            return ListenableBuilder(
              listenable: _state,
              builder: (BuildContext context, _) {
                if (_state.legalNoticeAcknowledged) return scaled;
                return PopScope(
                  canPop: false,
                  child: Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      scaled,
                      LegalAcceptanceGate(
                        onAcknowledge: _state.acknowledgeLegalNotice,
                      ),
                    ],
                  ),
                );
              },
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
