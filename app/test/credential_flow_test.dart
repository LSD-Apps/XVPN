import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/app_state.dart';
import 'package:xvpn/models.dart';
import 'package:xvpn/screens/import_conf.dart';
import 'package:xvpn/theme.dart';

/// 一份需要账号密码的 OpenVPN 配置。
const _needCreds = '''
client
dev tun
proto udp
remote vpn.example.net 1194
auth-user-pass
cipher AES-256-CBC
<ca>
-----BEGIN CERTIFICATE-----
MIIB
-----END CERTIFICATE-----
</ca>
''';

void main() {
  /// 关掉导入后自动连接。
  ///
  /// 演示内核一连上就会起每秒刷新的定时器，而这里的断言只关心「凭据有没有
  /// 存下来」，开着自动连接只会给测试引入需要额外清理的异步工作。
  AppState newState() {
    final state = AppState();
    state.updateSettings(const AppSettings(autoConnectOnImport: false));
    return state;
  }

  /// 一个最小宿主：一个按钮触发统一的导入路径。
  Future<void> pumpImporter(
    WidgetTester tester,
    AppState state, {
    String text = _needCreds,
    String fileName = 'need.ovpn',
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildXvTheme(XvPalette.dark),
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => importConfWithPrompt(
                  context,
                  state,
                  text: text,
                  fileName: fileName,
                ),
                child: const Text('导入'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('导入需要账号密码的配置会弹出表单，填完即保存', (WidgetTester tester) async {
    final state = newState();
    await pumpImporter(tester, state);

    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();

    // 表单要点出是哪份配置、缺的是什么。
    expect(find.text('这份配置需要账号密码'), findsOneWidget);
    expect(find.textContaining('need.ovpn'), findsWidgets);
    expect(find.textContaining('auth-user-pass'), findsOneWidget);

    // 配置此时已经导入，只是还没凭据。
    expect(state.profiles, hasLength(1));
    final id = state.profiles.single.id;
    expect(state.profileNeedsCredentials(id), isTrue);

    await tester.enterText(find.byType(TextField).at(0), 'alice');
    await tester.enterText(find.byType(TextField).at(1), 'pw-123');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(state.profileHasCredentials(id), isTrue);
    expect(state.profileNeedsCredentials(id), isFalse);
    expect(find.text('这份配置需要账号密码'), findsNothing, reason: '填完表单应当关闭');

    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('表单里选「稍后填写」不会丢掉刚导入的配置', (WidgetTester tester) async {
    final state = newState();
    await pumpImporter(tester, state);

    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('稍后填写'));
    await tester.pumpAndSettle();

    expect(state.profiles, hasLength(1), reason: '取消填写只是暂时连不上，不该让用户重新导入一遍');
    expect(state.profileNeedsCredentials(state.profiles.single.id), isTrue);
    expect(state.lastError, isNull, reason: '用户主动取消不是错误，不该报红');

    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('账号或密码为空时留在表单里提示', (WidgetTester tester) async {
    final state = newState();
    await pumpImporter(tester, state);

    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();

    // 只填密码直接保存：应当停在表单里。
    await tester.enterText(find.byType(TextField).at(1), 'pw-only');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('请填写用户名'), findsOneWidget);
    expect(find.text('这份配置需要账号密码'), findsOneWidget, reason: '校验失败不该关闭表单');
    expect(state.profileHasCredentials(state.profiles.single.id), isFalse);

    // 补上用户名后应当能保存。
    await tester.enterText(find.byType(TextField).at(0), 'alice');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(state.profileHasCredentials(state.profiles.single.id), isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('不需要账号密码的配置不会弹表单', (WidgetTester tester) async {
    final state = newState();
    await pumpImporter(
      tester,
      state,
      text: _needCreds.replaceAll('auth-user-pass\n', ''),
      fileName: 'plain.ovpn',
    );

    await tester.tap(find.text('导入'));
    await tester.pumpAndSettle();

    expect(find.text('这份配置需要账号密码'), findsNothing);
    expect(state.profiles, hasLength(1));

    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });

  testWidgets('手填表单关闭时不会用到已释放的输入控制器', (WidgetTester tester) async {
    // 这是一条回归测试，针对的是一类很容易复发的错误：`showDialog` 的 Future
    // 在**退场动画播完之前**就已经返回，如果那一刻就 dispose 掉 TextEditingController，
    // 动画里的 TextField 会用到已释放的对象并抛
    // 「A TextEditingController was used after being disposed」。
    // 表单里的输入框比普通弹窗多得多，一旦漏 dispose 一个就必然触发。
    // 必须 pumpAndSettle 把退场动画走完才暴露得出来。
    final state = newState();
    await tester.pumpWidget(
      MaterialApp(
        theme: buildXvTheme(XvPalette.dark),
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => startManualConfigForm(context, state),
                child: const Text('手动填写'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('手动填写'));
    await tester.pumpAndSettle();
    expect(find.text('手动添加配置'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('手动添加配置'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    state.dispose();
  });
}
