import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/theme.dart';
import 'package:xvpn/widgets/connect_ring.dart';

/// 圆环的预热态流转弧。
///
/// 这一组重点锁两件事：
///   1. 预热时**确实在动**（用户能看出程序没卡住），非预热时不空转；
///   2. 构建后立即销毁不会崩——这是实现过程中真实踩到的崩溃（controller 用
///      `late final` 惰性初始化，非预热态直到 dispose 才第一次求值，那一刻
///      Ticker 已无处可挂）。
Widget _host({required bool warmup, bool active = true, VoidCallback? onTap}) {
  return MaterialApp(
    theme: buildXvTheme(XvPalette.dark),
    home: Scaffold(
      body: Center(
        child: ConnectRing(
          size: ConnectRing.mobileSize,
          active: active,
          icon: Icons.power_settings_new,
          title: warmup ? '正在建立隧道…' : '已连接',
          warmup: warmup,
          onTap: onTap,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('预热态持续出帧：用户能看出程序在动', (WidgetTester tester) async {
    await tester.pumpWidget(_host(warmup: true));

    // 第一帧之后应当仍有排队的帧——这正是「在动」的判据。
    await tester.pump(const Duration(milliseconds: 16));
    expect(
      tester.binding.hasScheduledFrame,
      isTrue,
      reason: '预热态若不出帧，圆环就是静止的，用户会以为卡住了',
    );

    // 再推几帧确认动画在持续推进，而不是只排了一帧就停。
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.binding.hasScheduledFrame, isTrue);
    }
  });

  testWidgets('非预热态不空转：已连接时不该每帧重绘', (WidgetTester tester) async {
    await tester.pumpWidget(_host(warmup: false));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 100));

    expect(
      tester.binding.hasScheduledFrame,
      isFalse,
      reason: '已连接还在转，既让人以为隧道不稳，也白耗电',
    );
  });

  testWidgets('构建后立即销毁不崩：惰性 controller 的回归用例', (WidgetTester tester) async {
    // 非预热态下从未读过 controller，旧实现会在 dispose 时才初始化它并崩溃。
    await tester.pumpWidget(_host(warmup: false));
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('预热态转非预热：动画停下，且不崩', (WidgetTester tester) async {
    await tester.pumpWidget(_host(warmup: true));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.binding.hasScheduledFrame, isTrue);

    // 隧道就绪 → 回到静止态。
    await tester.pumpWidget(_host(warmup: false));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);
    expect(
      tester.binding.hasScheduledFrame,
      isFalse,
      reason: '连上之后必须停转，否则「已连接」看起来仍不稳定',
    );
  });

  testWidgets('预热态也允许点击断开：圆环不能因为动画吞掉手势', (WidgetTester tester) async {
    var taps = 0;
    await tester.pumpWidget(_host(warmup: true, onTap: () => taps++));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byType(ConnectRing));
    await tester.pump();

    expect(taps, 1, reason: '预热期间用户点断开是合理诉求，动画不该拦住它');
  });
}
