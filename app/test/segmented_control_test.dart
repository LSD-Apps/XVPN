import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/theme.dart';
import 'package:xvpn/widgets/common.dart';

/// 会记住选中项的分段选择器外壳。
///
/// [XvSegmented] 本身是无状态的（index 由外部给），因此要观察「切换后的动效」
/// 就必须有一个真的会重建它的父层——否则点击之后 index 不变，自然什么都不会动。
class _SegmentedHarness extends StatefulWidget {
  const _SegmentedHarness({required this.labels, required this.initialIndex});

  final List<String> labels;
  final int initialIndex;

  @override
  State<_SegmentedHarness> createState() => _SegmentedHarnessState();
}

class _SegmentedHarnessState extends State<_SegmentedHarness> {
  late int _index = widget.initialIndex;

  @override
  Widget build(BuildContext context) {
    return XvSegmented(
      labels: widget.labels,
      index: _index,
      onChanged: (int i) => setState(() => _index = i),
    );
  }
}

/// 分段选择器（`XvSegmented`）的视觉回归用例。
///
/// 之所以专门测这个组件：它的原实现有两个叠在一起的毛病，而且都**不会**让
/// 测试失败、只会让用户觉得「切换不顺、两个状态糊在一起」——正是这类问题
/// 最容易在改动中被重新引入。
///
///   1. 选中态用的是 `panel3`，与轨道用的 `field` 色值极近。亮色下是
///      #ECECF2 对 #F1F1F6，几乎看不出差别——「选中了哪个」根本读不出来。
///   2. 每个分段各画各的背景再交叉淡入淡出，两个圆角矩形会在中间态同时
///      半透明地贴在一起，视觉上「两个状态串在一起」，且没有任何位移。
///
/// 因此这里断言两件事：滑块与轨道**必须**有可辨的色差；指示器必须是**单一
/// 滑块**（一个位置），而不是「跟着选中段散落在各处的背景」。
void main() {
  /// 把组件放进一个**有自然尺寸**的环境里。
  ///
  /// 必须用 Center 收住：直接塞进 MaterialApp 的 home，它会撑满整个屏幕
  /// （测试默认画布 800×600），轨道变成 800 宽、滑块半条轨道 400 宽，
  /// 而 Alignment 的左右位移在这种尺寸下相对可忽略，测「有没有在动」就失真。
  Future<void> pumpSegmented(
    WidgetTester tester, {
    required List<String> labels,
    required int index,
    XvPalette? palette,
  }) async {
    if (palette != null) {
      applyPalette(palette);
      addTearDown(() => applyPalette(XvPalette.dark));
    }
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: XvSegmented(labels: labels, index: index, onChanged: (_) {}),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pumpPalette(WidgetTester tester, XvPalette palette) => pumpSegmented(
        tester,
        labels: const <String>['走代理', '直连'],
        index: 0,
        palette: palette,
      );

  /// 滑块本体。挂具名 Key，避免按类型误撞到别的装饰盒。
  final Finder thumb = find.byKey(XvSegmented.thumbKey);

  /// 相对亮度（sRGB，WCAG 定义）。
  double luminance(Color c) => c.computeLuminance();

  /// 两色的亮度对比度（WCAG 定义）。1.0 表示完全一样。
  double contrast(Color a, Color b) {
    final la = luminance(a);
    final lb = luminance(b);
    final hi = la > lb ? la : lb;
    final lo = la > lb ? lb : la;
    return (hi + 0.05) / (lo + 0.05);
  }

  group('滑块与轨道的色差', () {
    test('暗色：滑块必须明显区别于轨道底色', () {
      // 原实现 panel3 vs field 的对比度只有 1.07 —— 几乎等同。
      final ratio = contrast(XvPalette.dark.segThumb, XvPalette.dark.field);
      expect(
        ratio,
        greaterThan(1.5),
        reason: '暗色下滑块对比度仅 ${ratio.toStringAsFixed(2)}，选中项会看不出来',
      );
    });

    test('亮色：滑块必须明显区别于轨道底色', () {
      final ratio = contrast(XvPalette.light.segThumb, XvPalette.light.field);
      expect(
        ratio,
        greaterThan(1.1),
        reason: '亮色下滑块对比度仅 ${ratio.toStringAsFixed(2)}，'
            '原实现是 #ECECF2 对 #F1F1F6（比轨道还暗），选中项几乎是隐形的',
      );
    });

    test('亮色下不建议沿用 panel3：它与 field 几乎同色', () {
      // 这条用例记录「为什么当初不可见」这个事实，防止有人图省事改回去。
      final ratio = contrast(XvPalette.light.panel3, XvPalette.light.field);
      expect(
        ratio,
        lessThan(1.15),
        reason: 'panel3 与 field 本就没什么差别，因此不能拿它当滑块底色',
      );
    });

    test('投影不能是全透明的，否则暗色下失去唯一的分层手段', () {
      expect(XvPalette.dark.shadow.a, greaterThan(0.2));
      expect(XvPalette.light.shadow.a, greaterThan(0.05));
    });
  });

  group('单一滑块结构', () {
    testWidgets('只存在一个滑块背景，而不是每段各一个', (WidgetTester tester) async {
      await pumpPalette(tester, XvPalette.dark);

      expect(
        thumb,
        findsOneWidget,
        reason: '必须是单一滑块；每段各画背景就会在中间态叠出「串在一起」的观感',
      );
    });

    testWidgets('滑块贴合被选中那一段的文字', (WidgetTester tester) async {
      await pumpPalette(tester, XvPalette.dark);
      final track = tester.getRect(find.byType(XvSegmented));

      // 索引 0：滑块靠左，且左缘与轨道内缘对齐（3px 内边距 + 1px 描边）。
      final first = tester.getRect(thumb);
      expect(first.left, closeTo(track.left + 4, 2));
      // 滑块应至少盖住「走代理」这四个字。
      final firstLabel = tester.getRect(find.text('走代理'));
      expect(first.left, lessThanOrEqualTo(firstLabel.left));
      expect(first.right, greaterThanOrEqualTo(firstLabel.right));

      await pumpSegmented(tester, labels: const <String>['走代理', '直连'], index: 1);
      final second = tester.getRect(thumb);
      expect(second.left, greaterThan(first.left), reason: '选中第 1 段时应右移');
      final secondLabel = tester.getRect(find.text('直连'));
      expect(second.left, lessThanOrEqualTo(secondLabel.left));
      expect(second.right, greaterThanOrEqualTo(secondLabel.right));
    });

    testWidgets('三段时滑块落在中间那一段，且不是简单等分', (WidgetTester tester) async {
      // 刻意用宽度差别很大的标签：如果按等分比例定位，滑块会与「亮色」错位。
      await pumpSegmented(
        tester,
        labels: const <String>['跟随系统', '亮色', '深色'],
        index: 1,
      );

      final box = tester.getRect(thumb);
      final label = tester.getRect(find.text('亮色'));
      expect(box.left, lessThanOrEqualTo(label.left));
      expect(box.right, greaterThanOrEqualTo(label.right));
    });

    testWidgets('没有点击回调（禁用）时不画滑块', (WidgetTester tester) async {
      applyPalette(XvPalette.dark);
      await tester.pumpWidget(
        const MaterialApp(
          home: Center(
            child: XvSegmented(labels: <String>['走代理', '直连'], index: 0),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(thumb, findsNothing);
    });
  });

  group('切换动效', () {
    testWidgets('点选后滑块带动画地移动（不是瞬间跳变）', (WidgetTester tester) async {
      // 用一个会记住选中项的外壳包住它。`pumpSegmented` 传的是固定 index，
      // 点击后父层不重建、滑块位置不变，自然看不到位移——
      // 那不是组件的问题，是测试外壳的问题。
      final harness = _SegmentedHarness(
        labels: const <String>['走代理', '直连'],
        initialIndex: 0,
      );
      applyPalette(XvPalette.dark);
      addTearDown(() => applyPalette(XvPalette.dark));
      await tester.pumpWidget(MaterialApp(home: Center(child: harness)));
      await tester.pumpAndSettle();

      final track = tester.getRect(find.byType(XvSegmented));
      final before = tester.getRect(thumb);
      expect(before.left, closeTo(track.left + 4, 2), reason: '初始选中第 0 段，滑块靠左');

      await tester.tap(find.text('直连'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final mid = tester.getRect(thumb);
      expect(mid.left, greaterThan(before.left), reason: '已经开始向右移动');
      expect(
        mid.right,
        lessThan(track.right - 4),
        reason: '尚未到达终点，说明是位移而不是跳变',
      );

      await tester.pumpAndSettle();
      final after = tester.getRect(thumb);
      expect(after.left, greaterThan(mid.left), reason: '继续移动到终点');
      expect(after.right, closeTo(track.right - 4, 2), reason: '停稳后贴住右内缘');
    });

    testWidgets('首帧不播放动画：组件刚建出来时滑块不该自己滑过去', (WidgetTester tester) async {
      applyPalette(XvPalette.dark);
      addTearDown(() => applyPalette(XvPalette.dark));
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: XvSegmented(
              labels: const <String>['走代理', '直连'],
              index: 1,
              onChanged: (_) {},
            ),
          ),
        ),
      );
      // 只 pump 一帧：此时若带时长，滑块仍停在起点，位置就是错的。
      await tester.pump();
      final box = tester.getRect(thumb);
      final track = tester.getRect(find.byType(XvSegmented));
      final lastLabel = tester.getRect(find.text('直连'));
      expect(
        box.right,
        closeTo(track.right - 4, 2),
        reason: '首帧滑块就应停在选中段（靠右），否则会看到它自己滑过去',
      );
      expect(box.left, lessThanOrEqualTo(lastLabel.left));
    });
  });

  group('索引越界', () {
    testWidgets('index 超出范围时收敛到合法位置，不跑到轨道外', (WidgetTester tester) async {
      await pumpSegmented(tester, labels: const <String>['走代理', '直连'], index: 5);
      final track = tester.getRect(find.byType(XvSegmented));
      final box = tester.getRect(thumb);
      expect(box.right, closeTo(track.right - 4, 2), reason: '越界应收敛到最后一段');
      expect(box.left, greaterThanOrEqualTo(track.left));
    });

    testWidgets('空标签列表不抛异常', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Center(
            child: XvSegmented(labels: <String>[], index: 0),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  });
}
