import 'package:flutter/material.dart';

import '../protocols/parsed_profile.dart';
import '../theme.dart';

/// 配置提示的展示密度。
///
/// - [cards]：导入确认表单，每条独立边框，必须一眼看见
/// - [lines]：桌面配置卡，图标 + 正文，跟在 details 后面
/// - [foldable]：移动端窄行；warn 始终展开，info 收进「N 条提示」
enum ProfileNoticesLayout { cards, lines, foldable }

/// 三处配置提示共用的展示，避免表单 / 桌面 / 移动各写一套样式与分支。
class ProfileNoticesView extends StatefulWidget {
  const ProfileNoticesView({
    super.key,
    required this.notices,
    this.layout = ProfileNoticesLayout.lines,
  });

  final List<ProfileNotice> notices;
  final ProfileNoticesLayout layout;

  @override
  State<ProfileNoticesView> createState() => _ProfileNoticesViewState();
}

class _ProfileNoticesViewState extends State<ProfileNoticesView> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final notices = widget.notices;
    if (notices.isEmpty) return const SizedBox.shrink();

    return switch (widget.layout) {
      ProfileNoticesLayout.cards => _cards(notices),
      ProfileNoticesLayout.lines => _lines(notices),
      ProfileNoticesLayout.foldable => _foldable(notices),
    };
  }

  Widget _cards(List<ProfileNotice> notices) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (var i = 0; i < notices.length; i++) ...<Widget>[
          if (i > 0) const SizedBox(height: 8),
          _NoticeCard(notice: notices[i]),
        ],
      ],
    );
  }

  Widget _lines(List<ProfileNotice> notices) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (var i = 0; i < notices.length; i++)
          Padding(
            padding: EdgeInsets.only(bottom: i == notices.length - 1 ? 0 : 6),
            child: _NoticeLine(notice: notices[i]),
          ),
      ],
    );
  }

  Widget _foldable(List<ProfileNotice> notices) {
    final warns = notices.where((n) => n.isWarn).toList(growable: false);
    final infos = notices.where((n) => !n.isWarn).toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final notice in warns)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: _NoticeLine(notice: notice),
          ),
        if (infos.isNotEmpty) ...<Widget>[
          const SizedBox(height: 4),
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: <Widget>[
                  Icon(
                    _expanded
                        ? Icons.expand_less
                        : Icons.info_outline,
                    size: 13,
                    color: XV.muted2,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _expanded
                        ? '收起提示'
                        : '${infos.length} 条提示',
                    style: TextStyle(fontSize: 11.5, color: XV.muted2),
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            for (final notice in infos)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: _NoticeLine(notice: notice),
              ),
        ],
      ],
    );
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({required this.notice});

  final ProfileNotice notice;

  @override
  Widget build(BuildContext context) {
    final warn = notice.isWarn;
    final color = warn ? XV.amberSoft : XV.muted;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 9, 10, 9),
      decoration: BoxDecoration(
        color: (warn ? XV.amber : XV.line).withValues(alpha: warn ? 0.12 : 0.35),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: (warn ? XV.amber : XV.line).withValues(alpha: warn ? 0.35 : 1),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            warn ? Icons.warning_amber_outlined : Icons.info_outline,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              notice.message,
              style: TextStyle(fontSize: 11.5, color: color, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}

class _NoticeLine extends StatelessWidget {
  const _NoticeLine({required this.notice});

  final ProfileNotice notice;

  @override
  Widget build(BuildContext context) {
    final warn = notice.isWarn;
    final color = warn ? XV.amberSoft : XV.muted;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(
          warn ? Icons.warning_amber_outlined : Icons.info_outline,
          size: 13,
          color: color,
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            notice.message,
            style: TextStyle(fontSize: 11.5, color: color, height: 1.4),
          ),
        ),
      ],
    );
  }
}
