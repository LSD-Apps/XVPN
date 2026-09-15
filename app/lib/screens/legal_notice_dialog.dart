import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../core/links.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/markdown_style.dart';

/// 应用内「法律与使用声明」的 asset 路径。
///
/// 正文与 [`docs/LEGAL.md`] 同源：Flutter 无法声明包目录之外的文件，因此
/// `assets/legal/LEGAL.md` 是副本。时效性由 `test/legal_assets_test.dart` 守住。
const String kLegalNoticeAsset = 'assets/legal/LEGAL.md';

/// 打开法律与使用声明。
///
/// 必须走应用内全文，而不是只给一个 GitHub 链接：设置页承诺「可以阅读」，
/// 离线时链接打不开就等于假入口。链接仍可点正文里的 URL。
Future<void> showLegalNoticeDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.6),
    builder: (BuildContext dialogContext) => const LegalNoticeDialog(),
  );
}

/// 单份 Markdown 声明的阅读器。
class LegalNoticeDialog extends StatefulWidget {
  const LegalNoticeDialog({
    super.key,
    this.loadText,
    this.openExternalUrl = launchInBrowser,
  });

  /// 为 null 时读 [kLegalNoticeAsset]（生产路径）。
  final Future<String> Function()? loadText;

  final ExternalUrlLauncher openExternalUrl;

  @override
  State<LegalNoticeDialog> createState() => _LegalNoticeDialogState();
}

class _LegalNoticeDialogState extends State<LegalNoticeDialog> {
  static const double _wideBreakpoint = 720;

  late final Future<String> _text = (widget.loadText ?? _loadAsset)();

  static Future<String> _loadAsset() async {
    try {
      return await rootBundle.loadString(kLegalNoticeAsset);
    } on Object catch (e) {
      throw StateError('读不到法律声明：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= _wideBreakpoint;
    return Dialog(
      backgroundColor: XV.panel,
      insetPadding: wide
          ? const EdgeInsets.symmetric(horizontal: 40, vertical: 40)
          : EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(wide ? XV.rCard : 0),
        side: BorderSide(color: XV.line),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 760,
          maxHeight: wide ? 640 : double.infinity,
        ),
        child: Padding(
          padding: EdgeInsets.all(wide ? 20 : 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _header(),
              const SizedBox(height: 14),
              Expanded(child: _body()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return Row(
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('法律与使用声明', style: XvText.rowTitle),
              const SizedBox(height: 4),
              Text(
                '本软件是自备配置的客户端，不是 VPN 服务',
                style: XvText.caption,
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        XvButton(
          label: '关闭',
          onPressed: () => Navigator.of(context).pop(),
          minWidth: 0,
        ),
      ],
    );
  }

  Widget _body() {
    return FutureBuilder<String>(
      future: _text,
      builder: (BuildContext context, AsyncSnapshot<String> snapshot) {
        if (snapshot.hasError) {
          return Text(
            '读不到法律声明：${snapshot.error}',
            style: XvText.bodyMuted,
          );
        }
        final data = snapshot.data;
        if (data == null || data.isEmpty) {
          return Text('正在读取…', style: XvText.bodyMuted);
        }
        return SingleChildScrollView(
          child: MarkdownBody(
            data: data,
            styleSheet: xvMarkdownStyleSheet(),
            onTapLink: (String text, String? href, String title) {
              if (href == null || href.isEmpty) return;
              final uri = Uri.tryParse(href);
              if (uri == null) return;
              unawaited(widget.openExternalUrl(uri));
            },
          ),
        );
      },
    );
  }
}

/// 首次启动盖在整窗上的确认层。
///
/// 必须挡在 Navigator 之外（见 `main.dart` 的 `MaterialApp.builder`），否则
/// 导入对话框会盖过它，用户可以不读就导入配置。点外侧或返回键都不能关掉：
/// 这不是可跳过的提示，是「本软件不是 VPN 服务」这条边界的本机记录。
///
/// 全文在本层展开，不另开对话框——本层已经在 Navigator 外面，`showDialog`
/// 找不到 Navigator。
class LegalAcceptanceGate extends StatefulWidget {
  const LegalAcceptanceGate({
    super.key,
    required this.onAcknowledge,
    this.loadText,
    this.openExternalUrl = launchInBrowser,
  });

  final VoidCallback onAcknowledge;

  /// 为 null 时读 [kLegalNoticeAsset]。
  final Future<String> Function()? loadText;

  final ExternalUrlLauncher openExternalUrl;

  @override
  State<LegalAcceptanceGate> createState() => _LegalAcceptanceGateState();
}

class _LegalAcceptanceGateState extends State<LegalAcceptanceGate> {
  bool _expanded = false;
  Future<String>? _fullText;

  Future<String> _load() {
    return (widget.loadText ?? () => rootBundle.loadString(kLegalNoticeAsset))();
  }

  void _toggleFull() {
    setState(() {
      _expanded = !_expanded;
      _fullText ??= _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final wide = size.width >= 720;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        const ModalBarrier(dismissible: false, color: Color(0xCC000000)),
        SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 520,
                maxHeight: wide ? 640 : size.height - 24,
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    // 未展开时随内容收缩；展开全文时把滚动区限制在剩余高度内，
                    // 避免 Column+Flexible 在 mainAxisSize.min 下没有边界。
                    final double scrollMax = _expanded
                        ? (constraints.maxHeight - 168).clamp(120.0, 480.0)
                        : 220;
                    return XvCard(
                      padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          Text('使用前请确认', style: XvText.screenTitle),
                          const SizedBox(height: 6),
                          Text(
                            '本软件是自备配置的客户端，不是 VPN 服务',
                            style: XvText.caption,
                          ),
                          const SizedBox(height: 14),
                          ConstrainedBox(
                            constraints: BoxConstraints(maxHeight: scrollMax),
                            child: SingleChildScrollView(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: <Widget>[
                                  Text(
                                    '不提供节点、订阅或账号。你必须自备有权使用的服务器与配置，'
                                    '并自行确认用途符合所在地及服务器所在地的法律。'
                                    '开源不等于在每一个国家都自动合法。本文不是法律意见。',
                                    style: XvText.body,
                                  ),
                                  if (_expanded) ...<Widget>[
                                    const SizedBox(height: 14),
                                    _fullBody(),
                                  ],
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            alignment: WrapAlignment.end,
                            children: <Widget>[
                              XvButton(
                                label: _expanded ? '收起全文' : '阅读全文',
                                onPressed: _toggleFull,
                                minWidth: 0,
                              ),
                              XvButton(
                                label: '我已了解，继续',
                                kind: XvButtonKind.primary,
                                onPressed: widget.onAcknowledge,
                                minWidth: 0,
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _fullBody() {
    return FutureBuilder<String>(
      future: _fullText,
      builder: (BuildContext context, AsyncSnapshot<String> snapshot) {
        if (snapshot.hasError) {
          return Text(
            '读不到法律声明：${snapshot.error}',
            style: XvText.bodyMuted,
          );
        }
        final data = snapshot.data;
        if (data == null || data.isEmpty) {
          return Text('正在读取…', style: XvText.bodyMuted);
        }
        return MarkdownBody(
          data: data,
          styleSheet: xvMarkdownStyleSheet(),
          onTapLink: (String text, String? href, String title) {
            if (href == null || href.isEmpty) return;
            final uri = Uri.tryParse(href);
            if (uri == null) return;
            unawaited(widget.openExternalUrl(uri));
          },
        );
      },
    );
  }
}
