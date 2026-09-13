import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../core/links.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// 应用内「开源许可」界面。
///
/// 为什么不再用 Material 的 `showLicensePage`：那套页面自带 `AppBar`、Material
/// 配色与 `ExpansionTile`，而本应用是**无 AppBar** 的自绘标题栏界面，两套观感
/// 拼在一起像是另一个程序。这里改成用本项目的 token 与控件重画一个。
///
/// 条目来源仍是 [LicenseRegistry]，**不维护任何硬编码清单**：
///   * Flutter 在构建期把每个依赖与引擎的许可聚合成 `NOTICES.Z`，并由
///     `services` 在 `LicenseRegistry` 上注册（生产环境；测试里被刻意关掉）；
///   * 本项目自己的 `LICENSE` / `NOTICE.md` / `THIRD-PARTY-NOTICES.md` 由
///     `core/licenses.dart` 的 `registerBundledLicenses()` 注册。
/// 硬编码清单会在依赖变化时静默过期，而这正是合规上最不能接受的事。
///
/// 打开入口在设置页「关于」卡片（`settings_screen.dart` 的 `_openLicenses`）。
Future<void> showLicensesDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    // 与 `connect_screen._showKernelLog` / `credential_dialog` / `config_form`
    // 同一套弹窗外壳：遮罩浓度、圆角、描边都取自调色板。
    barrierColor: Colors.black.withValues(alpha: 0.6),
    builder: (BuildContext dialogContext) => const LicensesDialog(),
  );
}

/// 加载许可条目。抽成参数是为了可测试：
/// 真实调用链是 [LicenseRegistry.licenses]（其中一次是 `rootBundle` 真实 I/O），
/// 而 `testWidgets` 跑在 `FakeAsync` 下，测试需要先把条目读出来再注入。
typedef LicenseEntryLoader = Future<List<LicenseEntry>> Function();

/// 许可视图本体。
///
/// 列表（按组件名筛选）→ 点条目 → 全文，两级都在同一个弹窗内完成，返回只切
/// 内部状态而不是压路由，因此「返回列表」在任何平台上都不会丢筛选词。
class LicensesDialog extends StatefulWidget {
  const LicensesDialog({
    super.key,
    this.loadEntries,
    this.openExternalUrl = launchInBrowser,
  });

  /// 为 null 时读 [LicenseRegistry]（生产路径）。
  final LicenseEntryLoader? loadEntries;

  /// 打开正文里的链接。默认走 `core/links.dart` 的 [launchInBrowser]，与标题栏
  /// GitHub 按钮同一个实现；抽成参数是为了让测试注入记录器（真实实现要开浏览器）。
  final ExternalUrlLauncher openExternalUrl;

  @override
  State<LicensesDialog> createState() => _LicensesDialogState();
}

class _LicensesDialogState extends State<LicensesDialog> {
  /// 与 `config_form` 相同的断点：低于它时 760 宽的卡片两侧几乎不留白，
  /// 正文反而更窄，不如整屏铺开（窄屏不画圆角，贴满屏幕）。
  static const double _wideBreakpoint = 720;

  final TextEditingController _search = TextEditingController();

  /// 加载一次，之后重建不再重新拉取（`LicenseRegistry.licenses` 会遍历全部
  /// 注册器，重复拉取没有意义）。
  late final Future<List<LicenseEntry>> _entries = (widget.loadEntries ??
      _loadFromRegistry)();

  String _query = '';

  /// 当前正在读全文的条目；为 null 表示停在列表。
  LicenseEntry? _selected;

  static Future<List<LicenseEntry>> _loadFromRegistry() async {
    final entries = await LicenseRegistry.licenses.toList();
    return entries;
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _clearSearch() {
    _search.clear();
    setState(() => _query = '');
  }

  void _openEntry(LicenseEntry entry) => setState(() => _selected = entry);

  void _backToList() => setState(() => _selected = null);

  /// 组件名。`LicenseEntry.packages` 可能有多项（Flutter 会把持有同一份许可
  /// 文本的多个包合并成一条），全部列出来才不会让用户以为漏了某个包。
  static String _entryLabel(LicenseEntry entry) =>
      entry.packages.isEmpty ? '（未标注组件）' : entry.packages.join('  ·  ');

  /// 按组件名过滤。
  ///
  /// 刻意**不匹配正文**：347 KB 的 `THIRD-PARTY-NOTICES.md` 有上千段，为了搜索
  /// 而把每一条正文都解析一遍会把筛选变成卡顿的来源。组件名是用户实际记得住
  /// 的检索维度（「GPL」「sing-box」「Apache」），也足够便宜。
  List<LicenseEntry> _visible(List<LicenseEntry> all) {
    final query = _query.trim().toLowerCase();
    final list = query.isEmpty
        ? List<LicenseEntry>.of(all)
        : all
              .where(
                (LicenseEntry e) => e.packages.any(
                  (String p) => p.toLowerCase().contains(query),
                ),
              )
              .toList();
    // 用 compareTo 直接排（大写字母在前），本项目条目以 `XVPN` 开头，因此第一屏
    // 就能看到，与 `core/licenses.dart` 里选择 `XVPN` 前缀的理由一致。
    list.sort(
      (LicenseEntry a, LicenseEntry b) =>
          _entryLabel(a).compareTo(_entryLabel(b)),
    );
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= _wideBreakpoint;
    return Dialog(
      backgroundColor: XV.panel,
      // 窄屏整屏铺开，圆角与四周留白一并去掉，与 `config_form` 的宽/窄处理一致。
      insetPadding: wide
          ? const EdgeInsets.symmetric(horizontal: 40, vertical: 40)
          : EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(wide ? XV.rCard : 0),
        side: BorderSide(color: XV.line),
      ),
      child: ConstrainedBox(
        // 列表在真实产物里会有几百条（依赖 + 引擎），不能按内容自然高度撑开，
        // 因此宽屏固定一个上限高度、由内部滚动；窄屏则由弹窗铺满整屏高度
        // （不设上限，交给外层 `insetPadding: zero` 的约束决定）。
        constraints: BoxConstraints(
          maxWidth: 760,
          maxHeight: wide ? 640 : double.infinity,
        ),
        child: Padding(
          padding: EdgeInsets.all(wide ? 20 : 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _header(context),
              const SizedBox(height: 14),
              Expanded(child: _content(context)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header(BuildContext context) {
    final selected = _selected;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (selected != null) ...<Widget>[
          // 返回是「从全文回到列表」，与关闭（退出整个弹窗）是两件事，因此两者
          // 同时存在，用户不会误以为返回会关掉整个界面。
          XvButton(
            label: '返回',
            icon: Icons.arrow_back,
            onPressed: _backToList,
            minWidth: 0,
          ),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                selected == null ? '开源许可' : _entryLabel(selected),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: XV.text,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                selected == null
                    ? '本项目（GPL-3.0-or-later）与第三方组件的许可证全文'
                    : '许可证全文，可选中复制',
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

  Widget _content(BuildContext context) {
    final selected = _selected;
    if (selected != null) {
      return _LicenseDetail(
        key: ObjectKey(selected),
        entry: selected,
        openExternalUrl: widget.openExternalUrl,
      );
    }

    return FutureBuilder<List<LicenseEntry>>(
      future: _entries,
      builder:
          (BuildContext context, AsyncSnapshot<List<LicenseEntry>> snapshot) {
            if (snapshot.hasError) {
              // 读不到就说明白，而不是留一个空白弹窗——许可页打不开本身也是
              // 需要排查的问题（asset 漏进 pubspec、副本缺失等）。
              return _licenseNote('读取许可条目失败：${snapshot.error}');
            }
            final all = snapshot.data;
            if (all == null) {
              return _licenseNote('正在读取许可条目…');
            }

            final visible = _visible(all);
            final filtering = _query.trim().isNotEmpty;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                XvSearchField(
                  hint: '按组件或包名筛选',
                  controller: _search,
                  onChanged: (String value) =>
                      setState(() => _query = value),
                  onClear: _query.isEmpty ? null : _clearSearch,
                ),
                const SizedBox(height: 8),
                Text(
                  filtering
                      ? '匹配 ${visible.length} 项'
                      : '共 ${all.length} 项，点开可读全文',
                  style: XvText.caption,
                ),
                const SizedBox(height: 4),
                Expanded(
                  child: visible.isEmpty
                      ? _licenseNote(
                          filtering ? '没有匹配「${_query.trim()}」的组件' : '没有可展示的许可条目',
                        )
                      : _LicenseGutterList(
                          itemCount: visible.length,
                          itemBuilder: (BuildContext context, int index) =>
                              _entryRow(visible[index]),
                        ),
                ),
              ],
            );
          },
    );
  }

  Widget _entryRow(LicenseEntry entry) {
    return HoverRow(
      onTap: () => _openEntry(entry),
      child: Row(
        children: <Widget>[
          Expanded(child: Text(_entryLabel(entry), style: XvText.rowTitle)),
          const SizedBox(width: 10),
          Icon(Icons.chevron_right, size: 15, color: XV.muted2),
        ],
      ),
    );
  }
}

/// 某个条目的全文。
///
/// 单独成一个 StatefulWidget：这样每换一个条目就重新解析一次，而 [_content] 只在
/// 打开时算一次，不会在滚动时反复触发。
class _LicenseDetail extends StatefulWidget {
  const _LicenseDetail({
    super.key,
    required this.entry,
    required this.openExternalUrl,
  });

  final LicenseEntry entry;

  /// 打开正文里的链接的实现，由 [LicensesDialog] 注入。
  final ExternalUrlLauncher openExternalUrl;

  @override
  State<_LicenseDetail> createState() => _LicenseDetailState();
}

class _LicenseDetailState extends State<_LicenseDetail> {
  /// 只在打开时算一次。
  ///
  /// 用 `Future` 而不是在 `initState` 里同步算：355 KB 那份即使只是扫描分段也要
  /// 十几毫秒，已经接近一帧的预算；放进首帧会表现为「点了没反应」。让出一帧先
  /// 显示「正在排版」。
  late final Future<_LicenseContent> _content = Future<_LicenseContent>(
    () => _parseLicenseContent(widget.entry),
  );

  /// 打开正文里的链接。
  ///
  /// 失败绝不能把异常甩到界面上：与标题栏 GitHub 按钮（`_GitHubButtonState._open`）
  /// 同一套容错——平台通道缺失、系统没有默认浏览器都归为「没打开」，提示一句
  /// 即可。异步返回前先取 messenger，避免跨 await 使用 context。
  Future<void> _openLink(String? href) async {
    if (href == null || href.isEmpty) return;
    final Uri? uri = Uri.tryParse(href);
    if (uri == null) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    bool opened;
    try {
      opened = await widget.openExternalUrl(uri);
    } on Object catch (error) {
      debugPrint('打开许可链接失败：$error');
      opened = false;
    }
    if (opened || !mounted) return;
    messenger?.showSnackBar(
      SnackBar(
        content: Text(
          '无法打开浏览器，请手动访问 $href',
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

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_LicenseContent>(
      future: _content,
      builder:
          (BuildContext context, AsyncSnapshot<_LicenseContent> snapshot) {
            if (snapshot.hasError) {
              return _licenseNote('无法展开许可证全文：${snapshot.error}');
            }
            final content = snapshot.data;
            if (content == null) {
              return _licenseNote('正在排版许可全文…');
            }
            // 整段包在 SelectionArea 里：用户可以跨段落选中并复制 GPL 全文。
            // Markdown 正文也靠这一层做选择，因此下面的 `MarkdownBody` **不**打开
            // 它自己的 `selectable`——那会给每个文本片段建一个 `SelectableText`，
            // 选中机制与这里重复，而且对 347 KB 的条目明显更重。
            return SelectionArea(child: _body(content));
          },
    );
  }

  Widget _body(_LicenseContent content) {
    switch (content) {
      case final _PlainLicenseContent plain:
        if (plain.paragraphs.isEmpty) {
          return _licenseNote('这一条目没有可显示的正文');
        }
        return _LicenseGutterList(
          itemCount: plain.paragraphs.length,
          itemBuilder: (BuildContext context, int index) =>
              LicenseParagraphLine(paragraph: plain.paragraphs[index]),
        );
      case final _MarkdownLicenseContent markdown:
        if (markdown.sections.isEmpty) {
          return _licenseNote('这一条目没有可显示的正文');
        }
        final styleSheet = _markdownStyleSheet();
        return _LicenseGutterList(
          itemCount: markdown.sections.length,
          itemBuilder: (BuildContext context, int index) => Padding(
            padding: const EdgeInsets.only(bottom: 6),
            // 用 `MarkdownBody` 而不是 `Markdown(noScroll: true)`：后者会给每个
            // 块再套一层默认 16px 的 `Padding`，与这里的行距/缩进打架；`MarkdownBody`
            // 既不滚动也不加内边距，正好塞进外层已有的滚动区（[_LicenseGutterList]）。
            child: MarkdownBody(
              data: markdown.sections[index],
              styleSheet: styleSheet,
              onTapLink: (String text, String? href, String title) =>
                  unawaited(_openLink(href)),
            ),
          ),
        );
    }
  }
}

/// 许可全文的渲染模型。
///
/// 分两种而不是一律走 Markdown：`LICENSE` 是 GPL-3.0 的**纯文本**正文，里面有
/// `<name of author>`、`<program>` 这类尖括号占位，交给 Markdown 解析会被当成
/// 内联 HTML 标签吞掉（正文直接少内容）；Flutter 聚合的依赖许可同理。因此只有
/// 真正带 Markdown 结构（顶层标题 / GFM 表格）的文档才按 Markdown 渲染。
sealed class _LicenseContent {
  const _LicenseContent();
}

/// 纯文本正文：仍按段落渲染（[LicenseParagraphLine]）。
class _PlainLicenseContent extends _LicenseContent {
  const _PlainLicenseContent(this.paragraphs);

  final List<LicenseParagraph> paragraphs;
}

/// Markdown 正文：已按顶层标题切成若干段，交给 `ListView.builder` 懒建。
class _MarkdownLicenseContent extends _LicenseContent {
  const _MarkdownLicenseContent(this.sections);

  final List<String> sections;
}

/// 判定一份正文是不是 Markdown。
///
/// 只看两个**结构性**标记：列 0 的 ATX 标题、GFM 表格分隔行。纯文本许可里几乎
/// 不会出现这两样（GPL 正文实测 0 处），因此不会把 GPL / Flutter 聚合许可误判。
_LicenseContent _parseLicenseContent(LicenseEntry entry) {
  final String? raw = entry is LicenseEntryWithLineBreaks ? entry.text : null;
  if (raw != null && _looksLikeMarkdown(raw)) {
    return _MarkdownLicenseContent(splitMarkdownSections(raw));
  }
  return _PlainLicenseContent(entry.paragraphs.toList());
}

/// 列 0 的 ATX 标题。CommonMark 允许标题打断段落，因此它必然是顶层块的开头。
final RegExp _atxHeading = RegExp(r'^#{1,6}(\s|$)');

/// 代码围栏的开头（``` 或 ~~~，3 个以上）。
final RegExp _fenceStart = RegExp(r'^(`{3,}|~{3,})');

/// GFM 表格分隔行，例如 `| --- | :--: |`。
final RegExp _tableDelimiter = RegExp(r'^[\s:|-]*-{3,}[\s:|-]*$');

bool _looksLikeMarkdown(String text) {
  var headings = 0;
  for (final String line in const LineSplitter().convert(text)) {
    if (_atxHeading.hasMatch(line)) {
      headings++;
      // 两个列 0 标题就足以判定；纯文本正文里不会这样成对出现。
      if (headings >= 2) return true;
    } else if (line.contains('|') && _tableDelimiter.hasMatch(line)) {
      return true;
    }
  }
  return false;
}

/// 把 Markdown 按**顶层标题**切成若干段，供懒加载逐段渲染。
///
/// 为什么必须切：Markdown 渲染不是懒的——`MarkdownBody` 会把整段文档一次性解析
/// 成 widget 树。`THIRD-PARTY-NOTICES.md` 有 355 KB / 1683 段，一次性铺完会卡住
/// 首帧。切开后交给 [_LicenseGutterList] 的 `ListView.builder`，只有视口附近的段
/// 会被真正构建。
///
/// 为什么按标题切是安全的：列 0 的标题必然是顶层块的开头（前一个块一定已经
/// 结束），切点不会落进表格或列表中间。围栏状态单独跟踪：围栏里的 `#` 是正文而
/// 不是标题——这份文件把每份许可正文都包在 4 个反引号的围栏里，里面出现 3 个
/// 反引号时也不能误判成闭合。
List<String> splitMarkdownSections(String source) {
  final sections = <String>[];
  final buffer = <String>[];
  String? openFence;

  void flush() {
    if (buffer.any((String line) => line.trim().isNotEmpty)) {
      sections.add(buffer.join('\n'));
    }
    buffer.clear();
  }

  for (final String line in const LineSplitter().convert(source)) {
    final Match? fence = _fenceStart.firstMatch(line);
    if (openFence == null) {
      if (fence != null) {
        openFence = fence.group(1);
      } else if (_atxHeading.hasMatch(line)) {
        flush();
      }
    } else if (fence != null && _closesFence(line, openFence)) {
      openFence = null;
    }
    buffer.add(line);
  }
  flush();
  return sections;
}

/// 闭合围栏必须与开启围栏同字符、不短于它，且其后只有空白。
bool _closesFence(String line, String openFence) {
  final String marker = openFence[0];
  var run = 0;
  while (run < line.length && line[run] == marker) {
    run++;
  }
  return run >= openFence.length && line.substring(run).trim().isEmpty;
}

/// 把 Markdown 的各个元素映射到本项目 token。
///
/// 不传这份样式表的话，`flutter_markdown_plus` 会退回 `MarkdownStyleSheet.fromTheme`
/// （蓝色链接、Material 字号、卡片底色）。上一版界面正是因为露出 Material 观感才
/// 被用户说「像另一个程序」，这里每个可见元素都显式取自 [XV] / `XvText`；颜色在
/// 每次 build 时重新读取，因此 [XV] 全局切换深浅调色板后两边都会跟着走。
MarkdownStyleSheet _markdownStyleSheet() {
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

/// 许可正文的一段。
///
/// 公开是为了让测试能按类型统计「实际建了多少段」——这正是「347 KB 的条目
/// 不会卡住」的证据：懒建时这个数字只与视口有关，与总段数无关。
class LicenseParagraphLine extends StatelessWidget {
  const LicenseParagraphLine({super.key, required this.paragraph});

  final LicenseParagraph paragraph;

  /// 缩进单位，与 Flutter 自己的许可页保持同一观感。
  static const double indentStep = 16;

  @override
  Widget build(BuildContext context) {
    // 正文用等宽字体：GPL / 组件许可里的大量对齐与缩进（尤其 ASCII 版式）只有
    // 等宽才读得对。样式取自 token，只补一个行高。
    final base = XvText.mono.copyWith(color: XV.text, height: 1.6);
    if (paragraph.indent == LicenseParagraph.centeredIndent) {
      return Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 2),
        child: Text(
          paragraph.text,
          textAlign: TextAlign.center,
          style: base.copyWith(fontWeight: FontWeight.w700),
        ),
      );
    }
    final indent = paragraph.indent < 0 ? 0 : paragraph.indent;
    return Padding(
      padding: EdgeInsetsDirectional.only(top: 6, start: indentStep * indent),
      child: Text(paragraph.text, style: base),
    );
  }
}

/// 带滚动条预留槽的懒加载列表。
///
/// 与 [XvScrollableColumn] 同一处坑：桌面端 Flutter 的滚动条**浮在内容之上**、
/// 不占布局宽度，内容会顶到右边缘被压住（「滚动条与内容重叠」）。那里用
/// `SingleChildScrollView` + 固定 `Column` 解决，这里因为条目/段落数量可能上千、
/// 必须懒建，所以换成 `ListView.builder`——但右侧同样预留 10px，取值理由见
/// [XvScrollableColumn]。
class _LicenseGutterList extends StatefulWidget {
  const _LicenseGutterList({
    required this.itemCount,
    required this.itemBuilder,
  });

  final int itemCount;
  final Widget Function(BuildContext, int) itemBuilder;

  @override
  State<_LicenseGutterList> createState() => _LicenseGutterListState();
}

class _LicenseGutterListState extends State<_LicenseGutterList> {
  /// `Scrollbar.thumbVisibility` 要求显式提供 controller，因此由本组件持有。
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      controller: _controller,
      thumbVisibility: true,
      child: ListView.builder(
        controller: _controller,
        padding: const EdgeInsets.only(right: 10),
        itemCount: widget.itemCount,
        itemBuilder: widget.itemBuilder,
      ),
    );
  }
}

/// 居中的一行说明文案（加载中 / 出错 / 空结果）。
Widget _licenseNote(String text) {
  return Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Text(text, style: XvText.caption, textAlign: TextAlign.center),
    ),
  );
}
