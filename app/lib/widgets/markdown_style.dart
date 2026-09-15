import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../theme.dart';

/// 把 Markdown 的各个元素映射到本项目 token。
///
/// 「法律与使用声明」（`screens/legal_notice_dialog.dart` 的阅读器与首次启动
/// 的确认层）都用这一份，避免两处各维护、深浅色只改了一边。
///
/// 不传这份样式表的话，`flutter_markdown_plus` 会退回 `MarkdownStyleSheet.fromTheme`
/// （蓝色链接、Material 字号、卡片底色）。此前界面正是因为露出 Material 观感才
/// 被用户说「像另一个程序」，这里每个可见元素都显式取自 [XV] / `XvText`；颜色在
/// 每次 build 时重新读取，因此 [XV] 全局切换深浅调色板后两边都会跟着走。
///
/// 曾经它还服务于「开源许可」那个自绘的许可浏览界面——那个界面连同随包的
/// 400 KB 许可文本一起删掉了（见 `core/links.dart` 的 [kLicenseUrl]），
/// 这里保留下来是因为法律声明仍然要在应用内按 Markdown 读全文。
MarkdownStyleSheet xvMarkdownStyleSheet() {
  // 局部变量是为了少写几次 `XV.field`，同时强调「代码底色 = 输入类控件底色」。
  final Color field = XV.field;
  return MarkdownStyleSheet(
    a: TextStyle(
      color: XV.green,
      decoration: TextDecoration.underline,
      decorationColor: XV.green.withValues(alpha: 0.5),
    ),
    p: XvText.body.copyWith(height: 1.65, letterSpacing: 0),
    pPadding: EdgeInsets.zero,
    code: XvText.mono.copyWith(
      color: XV.text,
      fontSize: 12,
      letterSpacing: 0,
      backgroundColor: field,
    ),
    h1: TextStyle(
      fontSize: 17,
      fontWeight: FontWeight.w700,
      height: 1.4,
      letterSpacing: -0.2,
      color: XV.text,
    ),
    h1Padding: const EdgeInsets.only(top: 4, bottom: 10),
    h2: TextStyle(
      fontSize: 15,
      fontWeight: FontWeight.w700,
      height: 1.4,
      letterSpacing: 0,
      color: XV.text,
    ),
    h2Padding: const EdgeInsets.only(top: 14, bottom: 8),
    h3: TextStyle(
      fontSize: 13.5,
      fontWeight: FontWeight.w600,
      height: 1.4,
      letterSpacing: 0,
      color: XV.text,
    ),
    h3Padding: const EdgeInsets.only(top: 12, bottom: 6),
    h4: TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w600,
      height: 1.4,
      letterSpacing: 0,
      color: XV.text,
    ),
    h4Padding: const EdgeInsets.only(top: 10, bottom: 4),
    h5: TextStyle(
      fontSize: 12.5,
      fontWeight: FontWeight.w600,
      height: 1.4,
      letterSpacing: 0,
      color: XV.text,
    ),
    h5Padding: const EdgeInsets.only(top: 8, bottom: 4),
    h6: TextStyle(
      fontSize: 12.5,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.2,
      color: XV.muted,
    ),
    h6Padding: const EdgeInsets.only(top: 8, bottom: 4),
    em: const TextStyle(fontStyle: FontStyle.italic),
    strong: TextStyle(fontWeight: FontWeight.w700, color: XV.text),
    del: const TextStyle(decoration: TextDecoration.lineThrough),
    blockquote: XvText.bodyMuted,
    blockquotePadding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
    blockquoteDecoration: BoxDecoration(
      color: XV.panel3.withValues(alpha: 0.5),
      border: Border(
        left: BorderSide(color: XV.green.withValues(alpha: 0.55), width: 3),
      ),
      borderRadius: BorderRadius.circular(6),
    ),
    listIndent: 18,
    listBullet: XvText.body.copyWith(height: 1.65, letterSpacing: 0),
    listBulletPadding: const EdgeInsets.only(right: 6),
    tablePadding: const EdgeInsets.only(top: 2, bottom: 10),
    tableHead: TextStyle(
      fontSize: 12.5,
      fontWeight: FontWeight.w600,
      height: 1.5,
      letterSpacing: 0,
      color: XV.text,
    ),
    tableBody: TextStyle(
      fontSize: 12.5,
      height: 1.5,
      letterSpacing: 0,
      color: XV.text,
    ),
    tableBorder: TableBorder.all(color: XV.line, width: 1),
    tableColumnWidth: const FlexColumnWidth(),
    // 表头与正文同向左对齐：包的兜底样式把表头居中，看起来像 Material 默认表。
    tableHeadAlign: TextAlign.left,
    tableCellsPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    tableCellsDecoration: const BoxDecoration(),
    tableHeadCellsDecoration: BoxDecoration(color: XV.panel3),
    blockSpacing: 8,
    codeblockPadding: const EdgeInsets.all(12),
    codeblockDecoration: BoxDecoration(
      color: field,
      border: Border.all(color: XV.line),
      borderRadius: BorderRadius.circular(8),
    ),
    horizontalRuleDecoration: BoxDecoration(
      border: Border(top: BorderSide(color: XV.line)),
    ),
    checkbox: XvText.body.copyWith(color: XV.green),
  );
}
