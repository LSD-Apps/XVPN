import 'dart:io';

import 'package:flutter/material.dart';

import '../core/update_session.dart';
import 'package:flutter/services.dart';

import '../core/links.dart';
import '../core/update_center.dart';
import '../core/updater.dart';
import '../format.dart';
import '../theme.dart';
import '../version.dart';
import 'common.dart';

/// 应用内自动更新的界面入口。
///
/// 引擎（[Updater]）已经把「查询 → 下载并校验 → 启动安装」三步都做成了返回
/// **结构化结果、永不抛异常**的形式，这里只负责把每个结果翻译成用户能读懂的
/// 状态，并在**用户明确确认**之后才启动安装。
///
/// 几条硬性约定：
///   * 同一时刻只展示一个阶段，阶段之间用 [setState] 切换；
///   * 任何会发起异步操作的动作在等待期间都会禁用，重复点击不会并发触发第二次；
///   * 下载完成后进入**确认步骤**，用户点「安装更新」之前绝不调用安装；
///   * 桌面端安装助手启动后必须让当前进程退出（助手在等它），安卓绝不退出——
///     安卓的安装界面由系统弹出，用户还要在那里再确认一次。
///
/// 组件不读取 [AppState]：引擎是自洽的，更新状态也不参与连接状态机。
class UpdateCard extends StatefulWidget {
  const UpdateCard({
    super.key,
    this.compact = false,
    this.session,
    this.updater,
    this.updateCenter,
    this.openExternalUrl = launchInBrowser,
    this.revealFile = revealInFileManager,
    this.exitProcess = exit,
  });

  /// 移动端卡片规范（panel2 / 12 圆角 / 更紧的内边距），与其它设置卡片一致。
  final bool compact;

  /// 更新流程的进程级状态机。
  ///
  /// **真实运行不要传它**——默认用 [UpdateSession.instance]，那正是「切页不中断
  /// 下载」的前提（见 [UpdateSession] 的说明）。传它只用于测试，让一条用例拿到
  /// 自己的一份会话，从而能断言下载期间卡片被销毁也不会中断。
  final UpdateSession? session;

  /// **仅供测试注入**更新引擎。为 null 时用 [Updater.forCurrentPlatform]。
  ///
  /// 与 `SystemProxy.forPlatform` / `SecretProtector.forPlatform` 的注入点同一
  /// 思路：真实更新要联网、要替换安装目录，测试只能靠替身把每条分支走一遍。
  final Updater? updater;

  /// 启动检查结果的共享持有者（见 [UpdateCenter]）。
  ///
  /// 为 null 时用全局 [UpdateCenter.instance]。注入点让测试可以预置一条
  /// 「已有新版本」的 notice，从而断言卡片**不联网**也会呈现该状态。
  final UpdateCenter? updateCenter;

  /// 打开发布页的实现。默认交给系统浏览器；测试注入记录器断言点了哪个地址。
  final ExternalUrlLauncher openExternalUrl;

  /// 在文件管理器里定位安装包。默认交给系统；测试注入记录器断言定位了哪个文件。
  ///
  /// 为什么需要它：自动替换失败时（权限、杀毒软件、目录只读），用户手里其实
  /// 已经有一个**校验通过**的安装包，把它找出来手动解压覆盖就够了。前提是
  /// 他知道那个文件在哪——这是「自行取安装」这条路的关键一步。
  final FileRevealer revealFile;

  /// **仅供测试注入**的退出实现。
  ///
  /// 桌面端安装助手在等当前进程退出，因此确认安装后必须调用真实的 `exit(0)`；
  /// 测试里那样做会把测试进程一起杀掉，这个注入点就是为它准备的。
  final void Function(int code) exitProcess;

  @override
  State<UpdateCard> createState() => _UpdateCardState();
}

class _UpdateCardState extends State<UpdateCard> {
  /// 状态机**不在这张卡片里**，而在 [UpdateSession]（进程级）。
  ///
  /// 卡片只是它的一个视图：切页会把本 State 销毁，但下载必须继续。
  late final UpdateSession _session;

  /// 本 State 是否**拥有**这个会话。
  ///
  /// 只有测试注入了替身时为真（那份额外的会话属于这条用例）；真实运行走
  /// [UpdateSession.instance]，由进程持有，卡片**绝不**释放它——一释放就等于
  /// 关掉 HTTP 客户端、把正在传的字节流切断。
  late final bool _ownsSession;

  // 以下一律委托给会话，好让下面几百行构建代码不必跟着改。
  bool get _checking => _session.checking;
  bool get _downloading => _session.downloading;
  bool get _installing => _session.installing;
  UpdateCheckResult? get _checkResult => _session.checkResult;
  UpdateDownloadResult? get _downloadResult => _session.downloadResult;
  UpdateInstallResult? get _installResult => _session.installResult;
  File? get _downloadedFile => _session.downloadedFile;
  int get _received => _session.received;
  int? get _total => _session.total;

  @override
  void initState() {
    super.initState();
    final injected = widget.session;
    if (injected != null) {
      _session = injected;
      _ownsSession = false;
    } else if (widget.updater != null || widget.updateCenter != null) {
      // 测试注入了替身：给这条用例配一份自己的会话。
      _session = UpdateSession(
        updater: widget.updater ?? Updater.forCurrentPlatform(),
        center: widget.updateCenter ?? UpdateCenter.instance,
        exitProcess: widget.exitProcess,
      );
      _ownsSession = true;
    } else {
      _session = UpdateSession.instance;
      _ownsSession = false;
    }
    _session.addListener(_onSessionChanged);
  }

  void _onSessionChanged() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  void dispose() {
    _session.removeListener(_onSessionChanged);
    // **绝不**在这里释放会话：真实运行时它是进程级的，释放它就会关掉 HTTP
    // 客户端、切断正在进行的下载——那正是「切页就断」的成因。
    // 只有测试注入出来的那一份额外会话才归本 State 收掉。
    if (_ownsSession) _session.dispose();
    super.dispose();
  }

  /// 桌面端：安装助手启动后必须由应用主动退出。安卓不在其列。
  bool get _isDesktop => _session.isDesktop;

  // ------------------------------------------------------------ 动作

  // 检查、下载、取消、安装一律转发给**进程级**会话 [UpdateSession]：状态、
  // 进度与取消语义都在那边，卡片因此可以在下载途中被安全销毁（切页）。
  Future<void> _check() => _session.check();

  /// [target] 用于启动检查已经发现更新、卡片尚未走过 `_check()` 的场景：
  /// 此时 `_info` 仍是 null，由入口把 notice 里的信息显式带进来。
  Future<void> _download([UpdateInfo? target]) => _session.download(target);

  void _cancelDownload() => _session.cancelDownload();

  /// 用户忽略启动检查发现的更新：本次运行内标题栏与卡片都不再提示。
  void _dismissNotice() => _session.dismissNotice();

  /// 用户在确认步骤里选择「稍后」：退回「有更新」状态，不安装。
  void _dismissDownload() => _session.dismissDownload();

  /// 用户已经在确认步骤里点了「安装更新」——这是唯一的安装入口。
  ///
  /// [elevate] 为 true 表示用户已在上一步同意用管理员权限完成写入（Windows）。
  Future<void> _install({bool elevate = false}) =>
      _session.install(elevate: elevate);

  Future<void> _openRelease(UpdateInfo info) async {
    // 与标题栏 GitHub 入口同一套做法：异步前先取 messenger，避免跨 await 用 context。
    final messenger = ScaffoldMessenger.maybeOf(context);
    final uri = info.pageUri ?? Uri.tryParse(info.releaseUrl);
    var opened = false;
    if (uri != null) {
      try {
        opened = await widget.openExternalUrl(uri);
      } on Object catch (error) {
        debugPrint('打开更新发布页失败：$error');
        opened = false;
      }
    }
    if (opened || !mounted) return;
    _snack(messenger, '无法打开浏览器，请手动访问 ${info.releaseUrl}', warn: true);
  }

  /// 复制安装包路径。用户拿它去文件管理器粘贴、或发给另一台机器都行。
  Future<void> _copyPath(File file) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await Clipboard.setData(ClipboardData(text: file.path));
    } on Object catch (error) {
      // 剪贴板也可能不可用（无 X11 剪贴板服务等）。路径就在上面的可选中文本里，
      // 如实告诉用户这一步没成功即可。
      debugPrint('复制安装包路径失败：$error');
      _snack(messenger, '复制失败，请手动选中上面的路径。', warn: true);
      return;
    }
    _snack(messenger, '已复制安装包路径。');
  }

  /// 在文件管理器里定位安装包。
  Future<void> _revealFile(File file) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    var opened = false;
    try {
      opened = await widget.revealFile(file);
    } on Object catch (error) {
      debugPrint('打开文件管理器失败：$error');
      opened = false;
    }
    if (opened || !mounted) return;
    _snack(messenger, '没能打开文件管理器，可复制路径后自行打开。', warn: true);
  }

  /// 一条浮动提示。
  ///
  /// 抽出来是因为这里已经有三处提示（打不开浏览器 / 复制不了 / 打不开文件
  /// 管理器），各写一份 SnackBar 样式迟早会走形。
  void _snack(ScaffoldMessengerState? messenger, String message, {bool warn = false}) {
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: TextStyle(fontSize: 12.5, color: XV.text),
        ),
        backgroundColor: XV.panel3,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(XV.rCtl),
          side: BorderSide(
            color: warn ? XV.red.withValues(alpha: 0.35) : XV.line,
          ),
        ),
        duration: const Duration(seconds: 4),
      ),
    );
  }

  // ------------------------------------------------------------ 渲染

  @override
  Widget build(BuildContext context) {
    return XvCard(
      color: widget.compact ? XV.panel2 : XV.panel,
      radius: widget.compact ? 12 : XV.rCard,
      padding: widget.compact
          ? const EdgeInsets.fromLTRB(14, 13, 14, 13)
          : const EdgeInsets.all(16),
      // 订阅启动检查的结果：notice 从「有新版本」变成「已忽略」时，
      // 卡片无需 setState 就会退回初始态。
      child: ValueListenableBuilder<UpdateNotice?>(
        valueListenable: _session.center.notice,
        builder: (BuildContext context, UpdateNotice? notice, Widget? _) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const XvCardTitle('版本更新'),
              ..._buildBody(notice),
            ],
          );
        },
      ),
    );
  }

  /// 左栏标题：本机当前是哪个版本。
  ///
  /// 每个阶段都用它当标题——在检查、在下载、还是失败了，这一行说的都是同一件
  /// 事，阶段状态走 [SettingRow.badge] 或 [SettingRow.description]。版本号只在
  /// **这一处**出现：测试断言 `find.textContaining(appVersion)` 只有一条，多写
  /// 一处会让「哪个才是当前版本」变得含糊。
  String get _versionTitle => '当前版本 v$appVersion';

  /// 一条「左边状态、右边动作」的设置行。
  ///
  /// 版本更新的每个阶段都是设置页里的一条设置项：左边是当前状态，右边是这一步
  /// 能做的动作，用的正是「外观」「启动」「关于」几张卡片用的 [SettingRow]。
  /// 此前这里是竖排——说明占一行、按钮另起一行——行距与控件的右边缘都和相邻
  /// 卡片对不齐，同一页里出现两套版式。
  ///
  /// 动作不止一个时在右侧**纵向**排开：横着放会先把左边的说明文字挤掉，窄屏上
  /// 随后溢出。
  Widget _row({
    Widget? badge,
    String? title,
    required String description,
    List<Widget> actions = const <Widget>[],
  }) {
    return SettingRow(
      badge: badge,
      title: title ?? _versionTitle,
      description: description,
      isLast: true,
      control: actions.isEmpty
          ? const SizedBox.shrink()
          : Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                for (int i = 0; i < actions.length; i++) ...<Widget>[
                  if (i > 0) const SizedBox(height: 6),
                  actions[i],
                ],
              ],
            ),
    );
  }

  /// 带图标的一行状态标记，用作 [SettingRow.badge]。
  ///
  /// 不直接用 [RouteTag] 是因为错误态需要一个图标：颜色之外还有形状，
  /// 色觉障碍的用户同样分得出「出错了」和「有更新」。
  static Widget _badge(IconData icon, String text, Color color) => Row(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Icon(icon, size: 14, color: color),
      const SizedBox(width: 6),
      Text(
        text,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    ],
  );

  /// 等待期的转圈指示。与按钮同高，单放也能明确表达「在做事」。
  static const Widget _spinner = SizedBox(
    width: 14,
    height: 14,
    child: CircularProgressIndicator(strokeWidth: 2),
  );

  List<Widget> _buildBody(UpdateNotice? notice) {
    if (_checking) return _buildChecking();
    if (_installing) return _buildInstalling();

    final installResult = _installResult;
    if (installResult != null) return _buildInstallBlock(installResult);

    if (_downloading) return _buildDownloading();

    final downloadResult = _downloadResult;
    if (downloadResult != null) return _buildDownloadBlock(downloadResult);

    final checkResult = _checkResult;
    if (checkResult == null) {
      // 启动检查已经发现了新版本：直接呈现它。卡片自己不发起任何网络请求，
      // 这正是「打开设置页不自动联网」那条纪律所要求的。
      if (notice != null && !notice.dismissed) {
        return _buildAvailable(notice.info, fromStartup: true);
      }
      return _buildIdle();
    }
    return switch (checkResult) {
      UpdateAvailable(:final info) => _buildAvailable(info),
      UpdateNotAvailable(:final latestVersion) => _buildUpToDate(latestVersion),
      UpdateCheckFailure(:final message) => _buildFailure(message),
    };
  }

  List<Widget> _buildIdle() => <Widget>[
    _row(
      description: '检查是否有新版本可用。',
      actions: <Widget>[XvButton(label: '检查更新', onPressed: _check)],
    ),
  ];

  List<Widget> _buildChecking() => <Widget>[
    _row(
      description: '正在检查更新…',
      actions: <Widget>[
        // 禁用而不是隐藏：按钮始终在位，重复点击不会再触发一次。
        // 转圈放在它旁边，等待中的动作与它的入口在同一处。
        Row(
          mainAxisSize: MainAxisSize.min,
          children: const <Widget>[
            _spinner,
            SizedBox(width: 10),
            XvButton(label: '检查更新', onPressed: null),
          ],
        ),
      ],
    ),
  ];

  /// 已是最新版本。这是最常见的结果，用绿色陈述句而不是告警样式。
  ///
  /// 刻意**不**加标记：这里没有需要用户做的事，多一个绿色标签只会让最常见的结果
  /// 看起来像一条通知。
  List<Widget> _buildUpToDate(String latestVersion) => <Widget>[
    _row(
      description: '已是最新版本（v$latestVersion）。',
      actions: <Widget>[XvButton(label: '检查更新', onPressed: _check)],
    ),
  ];

  /// [fromStartup] 为 true 表示这条更新来自启动时的静默检查（用户从未点过
  /// 「检查更新」）。此时多给一个「忽略」入口：用户不想要这个提示时，会话内
  /// 不再出现（见 [UpdateCenter.dismiss]），但手动检查照旧可用。
  List<Widget> _buildAvailable(UpdateInfo info, {bool fromStartup = false}) {
    final size = info.assetSize;
    return <Widget>[
      _row(
        badge: RouteTag.green('有新版本'),
        // 标题换成新版本号：这一行要回答的是「要不要升到哪个版本」，而当前版本
        // 在初始态与其它阶段都已经写过。
        title: 'v${info.version}',
        description: size == null
            ? _noteFor(info)
            : '${_noteFor(info)}（安装包 ${_formatSize(size)}）',
        actions: <Widget>[
          XvButton(
            label: '下载更新',
            kind: XvButtonKind.primary,
            onPressed: () => _download(info),
          ),
          XvButton(label: '查看发布页', onPressed: () => _openRelease(info)),
          if (fromStartup) XvButton(label: '忽略', onPressed: _dismissNotice),
        ],
      ),
    ];
  }

  List<Widget> _buildDownloading() {
    final total = _total;
    final double? fraction = (total != null && total > 0)
        ? (_received / total).clamp(0.0, 1.0).toDouble()
        : null;
    final progressText = total != null
        ? '${_formatSize(_received)} / ${_formatSize(total)}'
        : '已下载 ${_formatSize(_received)}';
    return <Widget>[
      _row(
        description: '正在下载更新包…',
        actions: <Widget>[XvButton(label: '取消', onPressed: _cancelDownload)],
      ),
      const SizedBox(height: 10),
      // 进度条是**整行**的：它表达的是整件事的进度，压在右栏里会和按钮抢宽度，
      // 也会让百分比数字频繁换行。已完成量与总量写在它右侧，与进度条同一行读。
      Row(
        children: <Widget>[
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: fraction,
                minHeight: 6,
                backgroundColor: XV.line2,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Text(progressText, style: XvText.caption),
        ],
      ),
    ];
  }

  List<Widget> _buildDownloadBlock(UpdateDownloadResult result) {
    switch (result) {
      case UpdateDownloaded():
        return _buildConfirmInstall();
      case UpdateDownloadFailure(:final message):
        // 失败原因写进说明，而不是自成一行的告警块：它和「当前版本」是同一条
        // 设置项的两种状态，拆成两块之后左边一列就不再对齐了。
        return <Widget>[
          _row(
            badge: _badge(Icons.error_outline, '下载失败', XV.redSoft),
            description: message,
            actions: <Widget>[XvButton(label: '重试下载', onPressed: _download)],
          ),
        ];
      case UpdateDownloadCancelled():
        return <Widget>[
          _row(
            badge: _badge(Icons.info_outline, '已取消下载', XV.muted2),
            description: '更新包没有装上，随时可以重来。',
            actions: <Widget>[XvButton(label: '重新下载', onPressed: _download)],
          ),
        ];
    }
  }

  /// 下载完成后的**确认步骤**。替换安装前必须由用户再点一次「安装更新」。
  List<Widget> _buildConfirmInstall() => <Widget>[
    _row(
      badge: RouteTag.green('已下载'),
      description: '更新包已下载并通过校验。安装会替换当前版本，完成后应用会自动重启。是否继续？',
      actions: <Widget>[
        XvButton(
          label: '安装更新',
          kind: XvButtonKind.primary,
          onPressed: _install,
        ),
        XvButton(label: '稍后', onPressed: _dismissDownload),
      ],
    ),
    ..._manualInstallSection(),
  ];

  /// 安装包落在哪，以及「拿它自己装」的两个动作。
  ///
  /// 存在的理由是自动替换**不是唯一出路**：它可能因为权限、杀毒软件或只读目录
  /// 失败，而这时用户手里已经有一个**校验通过**的安装包——解压覆盖安装目录就行，
  /// 或者拷到另一台机器上用。前提是他知道那个文件在哪，因此路径以**可选中的
  /// 明文**呈现，而不是只写进日志文件里让人去翻。
  ///
  /// 安卓不显示：APK 落在应用私有缓存（`updates/`，靠 FileProvider 交给系统
  /// 安装器），那个路径对用户既没有意义也打不开。
  List<Widget> _manualInstallSection() {
    final file = _downloadedFile;
    if (file == null || !_isDesktop) return const <Widget>[];

    final String? size = _fileSize(file);
    return <Widget>[
      const SizedBox(height: 12),
      Divider(height: 1, thickness: 1, color: XV.line2),
      const SizedBox(height: 10),
      Text('也可以自行安装：解压覆盖安装目录，或拷贝到另一台机器上使用。', style: XvText.caption),
      const SizedBox(height: 8),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
        decoration: BoxDecoration(
          color: XV.field,
          border: Border.all(color: XV.line),
          borderRadius: BorderRadius.circular(XV.rCtl),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.folder_outlined, size: 13, color: XV.muted2),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    size == null ? '安装包位置' : '安装包位置（$size）',
                    style: TextStyle(fontSize: 11, color: XV.muted2),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            // 可选中：即便剪贴板不可用，用户也能用鼠标把路径抄走。
            SelectableText(
              file.path,
              style: TextStyle(
                fontSize: 11,
                height: 1.45,
                color: XV.text,
                fontFamilyFallback: XV.monoFallback,
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          XvButton(label: '复制路径', onPressed: () => _copyPath(file)),
          XvButton(label: '打开所在文件夹', onPressed: () => _revealFile(file)),
        ],
      ),
    ];
  }

  /// 从磁盘读安装包大小。读不到时返回 null 而不是抛异常——文件可能已被用户
  /// 清理或挪走，而那不该让整个更新卡片崩掉。
  static String? _fileSize(File file) {
    try {
      if (!file.existsSync()) return null;
      return _formatSize(file.lengthSync());
    } on Object {
      return null;
    }
  }

  List<Widget> _buildInstalling() => <Widget>[
    _row(
      description: '正在启动安装…',
      actions: const <Widget>[_spinner],
    ),
  ];

  List<Widget> _buildInstallBlock(UpdateInstallResult result) {
    switch (result) {
      case UpdateInstallStarted(:final message, :final logPath):
        return <Widget>[
          _row(
            badge: _badge(Icons.check_circle_outline, '已开始安装', XV.greenSoft),
            description: _isDesktop
                ? '$message 应用即将自动退出并重新启动。'
                : message,
          ),
          if (logPath != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('日志：$logPath', style: XvText.monoSmall),
            ),
        ];
      case UpdateInstallElevationRequired(:final message, :final suggestedDir):
        // Windows：安装目录受保护。下一步会弹 UAC。这里可以把「取消不会损坏
        // 任何东西」说死——助手在拿到授权之前一条文件都还没复制。
        return <Widget>[
          _row(
            badge: RouteTag.warn('需要管理员授权'),
            description: message,
            actions: <Widget>[
              XvButton(
                label: '以管理员身份更新',
                kind: XvButtonKind.primary,
                onPressed: () => _install(elevate: true),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              '点「以管理员身份更新」后会弹出系统授权窗口；'
              '取消则不会改动任何文件。'
              '${suggestedDir == null ? '' : '若想以后不再需要授权，可把幽门解压到 $suggestedDir。'}',
              style: XvText.caption,
            ),
          ),
        ];
      case UpdateInstallPermissionRequired(:final message):
        // 安卓：原生已经把人送去「安装未知应用」设置页。允许在这里重试安装。
        return <Widget>[
          _row(
            badge: RouteTag.warn('需要授权'),
            description: message,
            actions: <Widget>[XvButton(label: '重试安装', onPressed: _install)],
          ),
        ];
      case UpdateInstallFailure(:final message):
        return <Widget>[
          _row(
            badge: _badge(Icons.error_outline, '安装失败', XV.redSoft),
            description: message,
            actions: <Widget>[XvButton(label: '重试安装', onPressed: _install)],
          ),
          // 自动安装失败正是最需要这条退路的时候：安装包已经下载并校验过、就
          // 在磁盘上，把位置与两个动作直接摆在这里，用户不必再去别处翻。
          ..._manualInstallSection(),
        ];
    }
  }

  List<Widget> _buildFailure(String message) => <Widget>[
    _row(
      badge: _badge(Icons.error_outline, '检查失败', XV.redSoft),
      description: message,
      actions: <Widget>[XvButton(label: '重试', onPressed: _check)],
    ),
  ];

  /// 发布说明可能很长且带换行。折叠成一行并截断，完整内容让用户去发布页看。
  static String _noteFor(UpdateInfo info) {
    final raw = info.notes;
    if (raw == null) return '本次更新的内容请见发布页。';
    final text = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (text.isEmpty) return '本次更新的内容请见发布页。';
    return text.length <= 160 ? text : '${text.substring(0, 160)}…';
  }

  /// 复用 [fmtBytes] 的单位进位规则，只是把 (数值, 单位) 拼成一句话。
  static String _formatSize(int bytes) {
    final parts = fmtBytes(bytes);
    return '${parts.value} ${parts.unit}';
  }
}
