import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 窗口可缩放的边与角。
enum WindowEdge {
  left,
  right,
  top,
  bottom,
  topLeft,
  topRight,
  bottomLeft,
  bottomRight,
}

extension WindowEdgeX on WindowEdge {
  String get wireName => switch (this) {
    WindowEdge.left => 'left',
    WindowEdge.right => 'right',
    WindowEdge.top => 'top',
    WindowEdge.bottom => 'bottom',
    WindowEdge.topLeft => 'topLeft',
    WindowEdge.topRight => 'topRight',
    WindowEdge.bottomLeft => 'bottomLeft',
    WindowEdge.bottomRight => 'bottomRight',
  };
}

/// 与原生窗口对接的通道。
///
/// 桌面端窗口是无边框的（Windows 上去掉了原生标题栏；Linux X11 下用
/// `gtk_window_set_decorated(FALSE)`），标题栏由 Flutter 自绘，见
/// widgets/title_bar.dart。Wayland 下无法可靠自绘/驱动，交回原生装饰并让
/// Dart 收起自绘按钮。
///
/// 拖动与缩放必须由界面主动触发：Flutter 视图是覆盖整个窗口的子窗口，
/// 系统把鼠标命中测试交给它，顶层窗口的 WM_NCHITTEST / GTK 事件收不到，
/// 因此「返回 HTCAPTION 就能拖」在 Flutter 里并不成立（已实测确认）。
class WindowControls {
  WindowControls._();

  /// 与原生窗口对接的通道。
  ///
  /// 窗口控制与系统代理共用同一个平台通道（Windows 在 flutter_window.cpp、
  /// Linux 在 runner/my_application.cc 中注册），因此这里的方法名必须与
  /// 两边都保持一致。
  static const MethodChannel _channel = MethodChannel('com.xvpn.xvpn/platform');

  /// 是否需要自绘标题栏（客户端装饰）。
  ///
  /// Windows 上原生标题栏已被 WM_NCCALCSIZE 去掉，恒为自绘；Android 由系统
  /// 状态栏接管，界面里不画标题栏。Linux 要看会话类型：X11 下可以自绘，
  /// Wayland 下窗口移动/缩放/最大化都不可靠（合成器不保证支持），此时交回
  /// 原生装饰，`supported` 为 false——否则会得到一个拖不动、点不动的死标题栏。
  ///
  /// Linux 的能力在启动时由 [listen] 问原生侧（见 linux/runner/
  /// my_application.cc），因此这里默认 true 只是「查询完成前的乐观初值」；
  /// 实际值在 `runApp` 之前就已经确定。
  static bool _linuxClientDecorations = true;

  static bool get supported => switch (defaultTargetPlatform) {
    TargetPlatform.windows => true,
    TargetPlatform.linux => _linuxClientDecorations,
    _ => false,
  };

  /// 供测试注入 Wayland 回退（开发机是 Windows，跑不到真实 Wayland 会话）。
  @visibleForTesting
  static set linuxClientDecorations(bool value) =>
      _linuxClientDecorations = value;

  static Future<void> minimize() => _invoke('minimize');

  static Future<void> toggleMaximize() => _invoke('toggleMaximize');

  static Future<void> close() => _invoke('close');

  /// 开始拖动窗口。应在标题栏按下时调用。
  static Future<void> startDragging() => _invoke('startDragging');

  /// 开始缩放窗口。应在边缘/角落按下时调用。
  static Future<void> startResize(WindowEdge edge) =>
      _invoke('startResize', edge.wireName);

  /// 查询当前是否最大化，用于切换按钮图标。
  static Future<bool> isMaximized() async {
    if (!supported) return false;
    try {
      return await _channel.invokeMethod<bool>('isMaximized') ?? false;
    } on Object {
      return false;
    }
  }

  /// 当前是否最大化，**由原生推送**。
  ///
  /// 为什么需要它：最大化并不只发生在点按钮的时候。双击标题栏、Win+↑、贴边、
  /// 从任务栏还原……这些都绕过了 Dart，窗口状态变了而界面不知道——标题栏会停在
  /// 旧图标上（已经最大化了却还画着「最大化」），用户按下去实际是还原，图形与
  /// 行为对不上。原生在状态翻转后推一次（Windows 是 WM_SIZE，Linux 是
  /// window-state-event），这里接住并广播。
  static final ValueNotifier<bool> maximized = ValueNotifier<bool>(false);

  /// 原生请求退出（托盘「退出 XVPN」、SIGTERM/SIGINT）。由入口注册。
  ///
  /// 存在的意义很具体：Linux 上没有 Windows 的 WM_DESTROY / WM_QUERYENDSESSION
  /// 那样的退出钩子，而 Dart 的收尾是异步的——还原系统代理要执行 gsettings 这类
  /// 外部命令、结束 sing-box 要等子进程真的退出。原生直接结束进程会把这两步一起
  /// 打断，留下一个指向死端口的系统代理和一个孤儿内核。因此原生不自己退出，而是
  /// 先把这件事推给 Dart；这里跑完收尾后由 [quit] 关闭。
  ///
  /// 回调**失败也必须继续退出**：卡住不关比清理不干净更糟。
  static Future<void> Function()? onQuitRequested;

  /// 原生请求「打开更新界面」（托盘里那条「发现新版本」菜单项）。
  ///
  /// 托盘在原生侧，而「更新」是一个 Dart 侧的页面；这条推送就是把两者接起来
  /// 的那一步。此前那条菜单项被做成灰色纯信息项，理由是「没有现成的
  /// native → Dart 通道」——但本文件里 [maximized] 与 [onQuitRequested] 走的
  /// 就是同一条通道，所以那是个不成立的前提：于是一处「告诉你但让你做不了什么」
  /// 的界面被留了下来。
  ///
  /// 由入口注册（见 main.dart），与 [onQuitRequested] 同一处。
  static void Function()? onShowUpdateRequested;

  /// 请原生真正退出进程。只在 [onQuitRequested] 收尾完成（或失败）之后调用。
  ///
  /// 刻意不用 `exit()`：让 GTK 正常走完 shutdown。原生另有兜底超时，即使这条
  /// 调用没能送达，进程也不会永远不退。
  static Future<void> quit() async {
    try {
      await _channel.invokeMethod<void>('quitNow');
    } on Object {
      // 通道不可用时忽略：原生兜底超时会结束进程。
    }
  }

  /// 接住原生推来的窗口状态。应在应用启动时调用一次。
  ///
  /// Linux 上还要先问一句「这个会话能不能自绘窗口边框」：Wayland 下原生
  /// 保留装饰，界面必须把自绘按钮与拖动区收起来（见 [supported]）。
  static Future<void> listen() async {
    if (defaultTargetPlatform == TargetPlatform.linux) {
      try {
        final value = await _channel.invokeMethod<bool>('clientDecorations');
        if (value != null) _linuxClientDecorations = value;
      } on Object {
        // 通道不可用（测试环境、原生忘记注册）：保持 Linux 的乐观初值。
        // 这里不静默当成 Wayland——那会让 X11 用户白丢自绘标题栏。
      }
    }
    // **一个通道只能有一个方法处理器**：后设置的会顶掉前面的。原生在同一个
    // 通道上既推窗口状态（maximizedChanged）又推托盘退出（quitRequested，见
    // linux/runner/my_application.cc），因此这里统一接住再按方法名分发；拆成
    // 两个 setMethodCallHandler 的话，先注册的那条推送会被静默丢弃。
    //
    // 处理器在 Linux Wayland 下也要装（此时 [supported] 为 false）：那里的窗口
    // 装饰交回了原生，但托盘退出依然依赖这条推送。
    final bool desktopChannel =
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.linux;
    if (!desktopChannel) return;
    _channel.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'maximizedChanged') {
        final value = call.arguments;
        if (value is bool) maximized.value = value;
      } else if (call.method == 'trayOpenUpdate') {
        // 托盘「发现新版本」被点。原生已经顺手把窗口显示出来了，这里只负责
        // 让界面切到更新入口。回调缺失（测试、嵌入场景）时静默——原生那边
        // 至少还把窗口亮了出来，不会变成完全没反应。
        onShowUpdateRequested?.call();
      } else if (call.method == 'quitRequested') {
        try {
          await onQuitRequested?.call();
        } on Object {
          // 收尾失败也要继续退出：下一次启动还有 recoverIfNeeded 兜底。
        }
        await quit();
      }
      return null;
    });
    // 启动时先同步一次，避免「以最大化状态启动」时要等第一次 WM_SIZE 才纠正。
    if (supported) maximized.value = await isMaximized();
  }

  static Future<void> _invoke(String method, [Object? arguments]) async {
    if (!supported) return;
    try {
      await _channel.invokeMethod<void>(method, arguments);
    } on Object {
      // 通道不可用时忽略：窗口操作只是便利功能，不影响主流程。
    }
  }
}
