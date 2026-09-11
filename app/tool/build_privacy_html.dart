// 开发工具：把 PRIVACY.md 渲染成一个可直接托管的静态 HTML 页面。
//
//   cd app && dart run tool/build_privacy_html.dart
//
// 为什么需要它：Google Play 要求隐私政策有一个**公开可访问的 URL**，
// 而仓库里的 `.md` 文件不是可以直接打开的网页。这个工具把政策渲染成
// 自包含的单文件页面（内联样式、无外部依赖、自适应深浅色），
// 放进仓库根目录即可由任意静态托管（GitHub Pages / Gitee Pages / 自有域名）直接提供。
//
// 为什么用 markdown 包而不是手写转换：这份政策的内容以表格为主，
// 手写的简易转换第一次就漏掉了表头行——而隐私政策渲染错乱是发布事故，
// 不值得为省一个 dev 依赖去冒险。markdown 只在 dev_dependencies 里，
// 不进应用产物。
//
// 改完 PRIVACY.md 后请重新运行本工具并一起提交，否则页面与源文件会脱节。
import 'dart:io';

import 'package:markdown/markdown.dart' as md;

/// 页面外壳。样式内联，避免任何外部请求——隐私政策页不该反过来加载第三方资源。
const String _template = '''
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>隐私政策 · XVPN Privacy Policy</title>
<meta name="description" content="XVPN 隐私政策：不收集任何个人数据。Privacy policy for XVPN — collects no personal data.">
<style>
  :root {
    color-scheme: light dark;
    --bg: #ffffff; --fg: #1c1c22; --muted: #5e5c6a;
    --line: #e3e3eb; --code-bg: #f1f1f6; --accent: #0b7a57;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #0e131d; --fg: #e7ebf3; --muted: #8a93a6;
      --line: #232b3a; --code-bg: #1b2231; --accent: #2ee6a8;
    }
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; padding: 40px 20px 80px;
    background: var(--bg); color: var(--fg);
    font: 16px/1.75 -apple-system, BlinkMacSystemFont, "Segoe UI",
          "Noto Sans CJK SC", "Microsoft YaHei", sans-serif;
  }
  main { max-width: 780px; margin: 0 auto; }
  h1 { font-size: 1.75rem; line-height: 1.35; margin: 0 0 8px; }
  h2 { font-size: 1.25rem; margin: 2.4em 0 .6em; padding-top: .8em;
       border-top: 1px solid var(--line); }
  h3 { font-size: 1.05rem; margin: 1.8em 0 .5em; }
  p { margin: .8em 0; }
  a { color: var(--accent); }
  code {
    background: var(--code-bg); padding: .12em .4em; border-radius: 4px;
    font-family: ui-monospace, SFMono-Regular, Consolas, monospace; font-size: .9em;
  }
  pre { background: var(--code-bg); padding: .9em 1em; border-radius: 8px; overflow-x: auto; }
  pre code { background: none; padding: 0; }
  table { border-collapse: collapse; width: 100%; margin: 1em 0; font-size: .95rem; }
  th, td { border: 1px solid var(--line); padding: .5em .7em; text-align: left; vertical-align: top; }
  th { background: var(--code-bg); font-weight: 600; }
  ul, ol { padding-left: 1.4em; }
  li { margin: .35em 0; }
  blockquote { margin: 1em 0; padding: .6em 1em; border-left: 3px solid var(--line); color: var(--muted); }
  blockquote p { margin: .3em 0; }
  hr { border: 0; border-top: 1px solid var(--line); margin: 2.5em 0; }
  footer { margin-top: 4em; color: var(--muted); font-size: .85rem;
           border-top: 1px solid var(--line); padding-top: 1.2em; }
</style>
</head>
<body>
<main>
__BODY__
<footer>
  <p>本页面是 <a href="https://gitcode.com/start-ai/XVPN">XVPN</a> 的隐私政策，
  同时用于满足 Google Play 与 App Store 的商店要求。
  源文件为仓库根目录的 <code>PRIVACY.md</code>，随源码一起版本管理，
  因此每一次修改都有公开记录可查。</p>
  <p>This page is the privacy policy for XVPN and serves the Google Play and
  App Store requirements. Source: <code>PRIVACY.md</code>.</p>
</footer>
</main>
</body>
</html>
''';

void main(List<String> args) {
  // 允许从仓库根目录或 app/ 目录运行，两种都常见。
  final candidates = <String>[
    '../PRIVACY.md',
    'PRIVACY.md',
  ];
  final source = candidates.map(File.new).where((File f) => f.existsSync()).firstOrNull;
  if (source == null) {
    stderr.writeln('找不到 PRIVACY.md（在 app/ 或仓库根目录下运行本工具）');
    exitCode = 2;
    return;
  }

  final outPath = args.isNotEmpty
      ? args.first
      : '${source.parent.path}${Platform.pathSeparator}privacy.html';

  final markdown = source.readAsStringSync();
  final body = md.markdownToHtml(
    markdown,
    extensionSet: md.ExtensionSet.gitHubWeb,
    // 政策里有裸 URL 与 <sub> 这类内联 HTML，需要保留。
    inlineSyntaxes: <md.InlineSyntax>[],
  );

  File(outPath).writeAsStringSync(
    _template.replaceFirst('__BODY__', body),
    flush: true,
  );

  final size = File(outPath).lengthSync();
  stdout.writeln('已生成: $outPath（$size 字节）');
  stdout.writeln('源文件: ${source.path}');
  stdout.writeln('');
  stdout.writeln('提示：改动 PRIVACY.md 后请重新运行本工具并一起提交，');
  stdout.writeln('      否则托管页面会与源文件脱节。');
}
