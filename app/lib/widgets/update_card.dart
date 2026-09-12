import 'dart:io';

import 'package:flutter/material.dart';

import '../core/links.dart';
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
    this.updater,
    this.openExternalUrl = launchInBrowser,
    this.exitProcess = exit,
  });

  /// 移动端卡片规范（panel2 / 12 圆角 / 更紧的内边距），与其它设置卡片一致。
  final bool compact;

  /// **仅供测试注入**更新引擎。为 null 时用 [Updater.forCurrentPlatform]。
  ///
  /// 与 `SystemProxy.forPlatform` / `SecretProtector.forPlatform` 的注入点同一
  /// 思路：真实更新要联网、要替换安装目录，测试只能靠替身把每条分支走一遍。
  final Updater? updater;

  /// 打开发布页的实现。默认交给系统浏览器；测试注入记录器断言点了哪个地址。
  final ExternalUrlLauncher openExternalUrl;

  /// **仅供测试注入**的退出实现。
  ///
  /// 桌面端安装助手在等当前进程退出，因此确认安装后必须调用真实的 `exit(0)`；
  /// 测试里那样做会把测试进程一起杀掉，这个注入点就是为它准备的。
  final void Function(int code) exitProcess;

  @override
  State<UpdateCard> createState() => _UpdateCardState();
}

class _UpdateCardState extends State<UpdateCard> {
  late final Updater _updater;

  bool _checking = false;
  bool _downloading = false;
  bool _installing = false;

  UpdateCheckResult? _checkResult;
  UpdateDownloadResult? _downloadResult;
  UpdateInstallResult? _installResult;

  /// 当前可下载/已下载的发布信息。
  UpdateInfo? _info;

  File? _downloadedFile;
  UpdateCancellation? _cancellation;

  int _received = 0;
  int? _total;

  @override
  void initState() {
    super.initState();
    _updater = widget.updater ?? Updater.forCurrentPlatform();
  }

  @override
  void dispose() {
    // 默认实现里可能握着一个 HTTP 客户端；不使用注入替身时由这里释放。
    _updater.dispose();
    super.dispose();
  }

  /// 是否有异步操作正在进行。所有按钮据此禁用，保证重复点击安全。
  bool get _busy => _checking || _downloading || _installing;

  /// 桌面端：安装助手启动后必须由应用主动退出。安卓不在其列。
  bool get _isDesktop =>
      _updater.platform == TargetPlatform.windows ||
      _updater.platform == TargetPlatform.linux;

  // ------------------------------------------------------------ 动作

  Future<void> _check() async {
    if (_busy) return;
    setState(() {
      _checking = true;
      _checkResult = null;
      _downloadResult = null;
      _installResult = null;
      _info = null;
      _downloadedFile = null;
      _cancellation = null;
      _received = 0;
      _total = null;
    });
    final result = await _updater.checkForUpdate();
    if (!mounted) return;
    setState(() {
      _checking = false;
      _checkResult = result;
      if (result is UpdateAvailable) _info = result.info;
    });
  }

  Future<void> _download() async {
    final info = _info;
    if (info == null || _busy) return;
    final cancellation = UpdateCancellation();
    setState(() {
      _downloading = true;
      _downloadResult = null;
      _installResult = null;
      _downloadedFile = null;
      _cancellation = cancellation;
      _received = 0;
      _total = info.assetSize;
    });
    final result = await _updater.download(
      info,
      cancellation: cancellation,
      onProgress: (int received, int? total) {
        if (!mounted) return;
        setState(() {
          _received = received;
          // 服务器不给长度时保留引擎从附件信息里拿到的预估大小，
          // 两者都没有则进度条退化为不确定态。
          _total = total ?? info.assetSize;
        });
      },
    );
    if (!mounted) return;
    setState(() {
      _downloading = false;
      _cancellation = null;
      _downloadResult = result;
      if (result is UpdateDownloaded) _downloadedFile = result.file;
    });
  }

  void _cancelDownload() => _cancellation?.cancel();

  /// 用户在确认步骤里选择「稍后」：退回「有更新」状态，不安装。
  void _dismissDownload() {
    if (_busy) return;
    setState(() {
      _downloadResult = null;
      _downloadedFile = null;
      _received = 0;
      _total = null;
    });
  }

  /// 用户已经在确认步骤里点了「安装更新」——这是唯一的安装入口。
  Future<void> _install() async {
    final info = _info;
    final file = _downloadedFile;
    if (info == null || file == null || _busy) return;
    setState(() {
      _installing = true;
      _installResult = null;
    });
    final result = await _updater.install(info, file);
    if (!mounted) return;
    setState(() {
      _installing = false;
      _installResult = result;
    });
    // 桌面端的重启助手在等当前进程退出。消息先渲染一帧再退出，
    // 让用户看到「正在更新」而不是应用凭空消失；安卓交给系统安装器，绝不退出。
    if (result is UpdateInstallStarted && _isDesktop) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.exitProcess(0);
      });
    }
  }

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
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          '无法打开浏览器，请手动访问 ${info.releaseUrl}',
          style: TextStyle(fontSize: 12.5, color: XV.text),
        ),
        backgroundColor: XV.panel3,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.all(16),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(XV.rCtl),
          side: BorderSide(color: XV.red.withValues(alpha: 0.35)),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const XvCardTitle('版本更新'),
          Row(
            children: <Widget>[
              Text('当前版本', style: XvText.rowDesc),
              const SizedBox(width: 8),
              Text('v$appVersion', style: XvText.rowTitle),
            ],
          ),
          const SizedBox(height: 10),
          ..._buildBody(),
        ],
      ),
    );
  }

  List<Widget> _buildBody() {
    if (_checking) return _buildChecking();
    if (_installing) return _buildInstalling();

    final installResult = _installResult;
    if (installResult != null) return _buildInstallBlock(installResult);

    if (_downloading) return _buildDownloading();

    final downloadResult = _downloadResult;
    if (downloadResult != null) return _buildDownloadBlock(downloadResult);

    final checkResult = _checkResult;
    if (checkResult == null) return _buildIdle();
    return switch (checkResult) {
      UpdateAvailable(:final info) => _buildAvailable(info),
      UpdateNotAvailable(:final latestVersion) => _buildUpToDate(latestVersion),
      UpdateCheckFailure(:final message) => _buildFailure(message),
    };
  }

  List<Widget> _buildIdle() => <Widget>[
    Text('检查是否有新版本可用。', style: XvText.rowDesc),
    const SizedBox(height: 10),
    Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        XvButton(label: '检查更新', onPressed: _check),
      ],
    ),
  ];

  List<Widget> _buildChecking() => <Widget>[
    Row(
      children: <Widget>[
        const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 10),
        Expanded(child: Text('正在检查更新…', style: XvText.rowDesc)),
      ],
    ),
    const SizedBox(height: 10),
    Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        // 禁用而不是隐藏：进度条旁边始终有一个明确的入口，重复点击也不会再触发。
        XvButton(label: '检查更新', onPressed: null),
      ],
    ),
  ];

  /// 已是最新版本。这是最常见的结果，用绿色陈述句而不是告警样式。
  List<Widget> _buildUpToDate(String latestVersion) => <Widget>[
    Row(
      children: <Widget>[
        Icon(Icons.check_circle_outline, size: 15, color: XV.green),
        const SizedBox(width: 8),
        Expanded(
          child: Text('已是最新版本（v$latestVersion）。', style: XvText.rowDesc),
        ),
      ],
    ),
    const SizedBox(height: 10),
    Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        XvButton(label: '检查更新', onPressed: _check),
      ],
    ),
  ];

  List<Widget> _buildAvailable(UpdateInfo info) {
    final size = info.assetSize;
    return <Widget>[
      Row(
        children: <Widget>[
          RouteTag.green('有新版本'),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'v${info.version}',
              style: XvText.rowTitle,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      const SizedBox(height: 6),
      Text(_noteFor(info), style: XvText.caption),
      if (size != null) ...<Widget>[
        const SizedBox(height: 4),
        Text('安装包大小：${_formatSize(size)}', style: XvText.caption),
      ],
      const SizedBox(height: 10),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          XvButton(
            label: '下载更新',
            kind: XvButtonKind.primary,
            onPressed: _download,
          ),
          XvButton(label: '查看发布页', onPressed: () => _openRelease(info)),
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
      Row(
        children: <Widget>[
          Expanded(child: Text('正在下载更新包…', style: XvText.rowDesc)),
          Text(progressText, style: XvText.caption),
        ],
      ),
      const SizedBox(height: 8),
      ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: LinearProgressIndicator(
          value: fraction,
          minHeight: 6,
          backgroundColor: XV.line2,
        ),
      ),
      const SizedBox(height: 10),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          XvButton(label: '取消', onPressed: _cancelDownload),
        ],
      ),
    ];
  }

  List<Widget> _buildDownloadBlock(UpdateDownloadResult result) {
    switch (result) {
      case UpdateDownloaded():
        return _buildConfirmInstall();
      case UpdateDownloadFailure(:final message):
        return <Widget>[
          _errorRow(message),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              XvButton(label: '重试下载', onPressed: _download),
            ],
          ),
        ];
      case UpdateDownloadCancelled():
        return <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.info_outline, size: 15, color: XV.muted2),
              const SizedBox(width: 8),
              Expanded(child: Text('已取消下载。', style: XvText.rowDesc)),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              XvButton(label: '重新下载', onPressed: _download),
            ],
          ),
        ];
    }
  }

  /// 下载完成后的**确认步骤**。替换安装前必须由用户再点一次「安装更新」。
  List<Widget> _buildConfirmInstall() => <Widget>[
    Row(
      children: <Widget>[
        Icon(Icons.download_done, size: 15, color: XV.green),
        const SizedBox(width: 8),
        Expanded(child: Text('更新包已下载并通过校验。', style: XvText.rowDesc)),
      ],
    ),
    const SizedBox(height: 6),
    Text(
      '安装会替换当前版本，完成后应用会自动重启。是否继续？',
      style: XvText.caption,
    ),
    const SizedBox(height: 10),
    Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        XvButton(
          label: '安装更新',
          kind: XvButtonKind.primary,
          onPressed: _install,
        ),
        XvButton(label: '稍后', onPressed: _dismissDownload),
      ],
    ),
  ];

  List<Widget> _buildInstalling() => <Widget>[
    Row(
      children: <Widget>[
        const SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 10),
        Expanded(child: Text('正在启动安装…', style: XvText.rowDesc)),
      ],
    ),
  ];

  List<Widget> _buildInstallBlock(UpdateInstallResult result) {
    switch (result) {
      case UpdateInstallStarted(:final message, :final logPath):
        return <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Icon(Icons.check_circle_outline, size: 15, color: XV.green),
              const SizedBox(width: 8),
              Expanded(child: Text(message, style: XvText.rowDesc)),
            ],
          ),
          if (_isDesktop)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('应用即将自动退出并重新启动。', style: XvText.caption),
            ),
          if (logPath != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('日志：$logPath', style: XvText.monoSmall),
            ),
        ];
      case UpdateInstallPermissionRequired(:final message):
        // 安卓：原生已经把人送去「安装未知应用」设置页。允许在这里重试安装。
        return <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              RouteTag.warn('需要授权'),
              const SizedBox(width: 8),
              Expanded(child: Text(message, style: XvText.rowDesc)),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              XvButton(label: '重试安装', onPressed: _install),
            ],
          ),
        ];
      case UpdateInstallFailure(:final message):
        return <Widget>[
          _errorRow(message),
          if (_downloadedFile != null) ...<Widget>[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                XvButton(label: '重试安装', onPressed: _install),
              ],
            ),
          ],
        ];
    }
  }

  List<Widget> _buildFailure(String message) => <Widget>[
    _errorRow(message),
    const SizedBox(height: 10),
    Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        XvButton(label: '重试', onPressed: _check),
      ],
    ),
  ];

  /// 与 `config_form.dart` 的错误块同一种观感：图标 + 可直接展示的中文消息。
  Widget _errorRow(String message) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Icon(Icons.error_outline, size: 14, color: XV.redSoft),
      const SizedBox(width: 8),
      Expanded(
        child: Text(
          message,
          style: TextStyle(fontSize: 11.5, color: XV.redSoft, height: 1.5),
        ),
      ),
    ],
  );

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
