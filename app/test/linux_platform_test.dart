import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/app_state.dart';
import 'package:xvpn/core/platform_paths.dart';
import 'package:xvpn/core/secret_protector.dart';
import 'package:xvpn/core/singbox_config.dart';
import 'package:xvpn/core/singbox_runner.dart';
import 'package:xvpn/core/system_proxy.dart';
import 'package:xvpn/core/window_controls.dart';
import 'package:xvpn/models.dart';
import 'package:xvpn/protocols/protocol_adapter.dart';
import 'package:xvpn/screens/shell.dart';
import 'package:xvpn/theme.dart';
import 'package:xvpn/theme_controller.dart';
import 'package:xvpn/widgets/title_bar.dart';

/// Linux 桌面支持的纯逻辑与界面锁定。
///
/// 开发机是 Windows，真实 Ubuntu 行为（gsettings 真写入、libsecret 真往返、
/// Wayland 真会话、gdk 真拖动）只能由 CI 在 Ubuntu 上跑。因此这里刻意把所有
/// 平台相关的判断都做成**可注入**的纯逻辑/替身，让「命令怎么拼、备份写什么、
/// 降级成什么、界面画什么」这些最容易写错的部分在 Windows 上就能被验证。
const _wireGuardConf = '''
[Interface]
PrivateKey = AQIDBAUGBwgJCgsMDQ4PEBESExQVFhc0Z3iJmqu8zd7v/yA=
Address = 10.0.0.3/32
MTU = 1420

[Peer]
PublicKey = ISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+P0A=
Endpoint = 203.0.113.7:51820
AllowedIPs = 0.0.0.0/0
''';

/// 记录调用并返回可编程结果的命令执行替身。
class _FakeRunner implements ProcessRunner {
  _FakeRunner(this.handler);

  final ProcessResult Function(String executable, List<String> arguments)
  handler;
  final List<String> calls = <String>[];

  @override
  Future<ProcessResult> run(String executable, List<String> arguments) async {
    calls.add('$executable ${arguments.join(' ')}');
    return handler(executable, arguments);
  }
}

ProcessResult _ok(String stdout) => ProcessResult(1, 0, stdout, '');

/// 模拟一台「用户从未设置过代理」的 GNOME 机器上 `gsettings get` 的输出。
ProcessResult _gnomeOriginal(String schema, String key) {
  if (schema == 'org.gnome.system.proxy' && key == 'mode') {
    return _ok("'none'");
  }
  if (key == 'port') return _ok('0');
  if (schema == 'org.gnome.system.proxy' && key == 'ignore-hosts') {
    return _ok("['localhost']");
  }
  return _ok("''");
}

/// 可编程的钥匙串替身。
class _FakeSecretService implements SecretServiceBackend {
  _FakeSecretService({required this.available});

  final bool available;
  final Map<String, String> entries = <String, String>{};

  @override
  bool verifyRoundTrip(String account, String value) {
    if (!available) return false;
    entries[account] = value;
    final readBack = entries[account];
    entries.remove(account);
    return readBack == value;
  }

  @override
  bool store(String account, String value) {
    if (!available) return false;
    entries[account] = value;
    return true;
  }

  @override
  String? lookup(String account) => entries[account];

  @override
  void clear(String account) => entries.remove(account);
}

void main() {
  group('平台路径解析', () {
    test('Linux 遵循 XDG 基本目录规范', () {
      final paths = resolveDesktopPaths(
        platform: TargetPlatform.linux,
        environment: const <String, String>{
          'HOME': '/home/u',
          'XDG_DATA_HOME': '/home/u/.local/share',
          'XDG_RUNTIME_DIR': '/run/user/1000',
        },
      );
      expect(paths.dataDir.path, '/home/u/.local/share/XVPN');
      // 运行目录放 tmpfs：上次被强杀留下的 core.pid 不该跨会话存活。
      expect(paths.runtimeDir.path, '/run/user/1000/XVPN');
    });

    test('缺少 XDG 变量时退回约定位置，而不是 /tmp', () {
      final paths = resolveDesktopPaths(
        platform: TargetPlatform.linux,
        environment: const <String, String>{'HOME': '/home/u'},
      );
      expect(paths.dataDir.path, '/home/u/.local/share/XVPN');
      // 没有 XDG_RUNTIME_DIR（SSH / 非 systemd）时退回到数据目录，
      // 而不是全局共享的 /tmp —— 那会在多用户机器上互相干扰。
      expect(paths.runtimeDir.path, '/home/u/.local/share/XVPN/runtime');
    });

    test('Windows 语义完全不变', () {
      final paths = resolveDesktopPaths(
        platform: TargetPlatform.windows,
        environment: const <String, String>{
          'LOCALAPPDATA': r'C:\Users\u\AppData\Local',
        },
      );
      expect(paths.dataDir.path, r'C:\Users\u\AppData\Local\XVPN');
      expect(paths.runtimeDir.path, r'C:\Users\u\AppData\Local\XVPN\runtime');
    });

    test('内核文件名按平台区分', () {
      expect(singBoxBinaryName(TargetPlatform.windows), 'sing-box.exe');
      expect(singBoxBinaryName(TargetPlatform.linux), 'sing-box');
    });
  });

  group('进程身份校验（残留内核清理）', () {
    test('只认 sing-box，不认复用同一 PID 的其它程序', () {
      expect(
        isSingBoxProcessIdentity(comm: 'sing-box\n', exePath: null),
        isTrue,
      );
      expect(
        isSingBoxProcessIdentity(comm: 'chrome', exePath: '/usr/bin/chrome'),
        isFalse,
      );
      expect(
        isSingBoxProcessIdentity(comm: 'xvpn', exePath: '/opt/xvpn/sing-box'),
        isTrue,
        reason: 'comm 被截断时要能退回 exe 路径判断',
      );
      expect(isSingBoxProcessIdentity(comm: null, exePath: null), isFalse);
    });

    test('缺少内核的提示按平台给出可操作的下一步', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        final message = missingKernelMessage('/x/sing-box');
        expect(message, contains('重新安装'));
        expect(message, isNot(contains('杀毒软件')));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });

  group('Linux 系统代理（GNOME）', () {
    late Directory dataDir;

    setUp(() {
      dataDir = Directory.systemTemp.createTempSync('xvpn-linux-proxy');
    });

    tearDown(() {
      if (dataDir.existsSync()) dataDir.deleteSync(recursive: true);
    });

    LinuxSystemProxy build(_FakeRunner runner) => LinuxSystemProxy(
      dataDir: dataDir,
      environment: const <String, String>{
        'XDG_CURRENT_DESKTOP': 'ubuntu:GNOME',
      },
      runner: runner,
    );

    test('识别桌面环境：只认有接口的两类', () {
      final proxy = build(_FakeRunner((_, _) => _ok('')));
      expect(proxy.detectDesktop(), LinuxDesktopKind.gnome);
      final kde = LinuxSystemProxy(
        dataDir: dataDir,
        environment: const <String, String>{'XDG_CURRENT_DESKTOP': 'KDE'},
        runner: _FakeRunner((_, _) => _ok('')),
      );
      expect(kde.detectDesktop(), LinuxDesktopKind.kde);
      final unknown = LinuxSystemProxy(
        dataDir: dataDir,
        environment: const <String, String>{'XDG_CURRENT_DESKTOP': 'sway'},
        runner: _FakeRunner((_, _) => _ok('')),
      );
      expect(unknown.detectDesktop(), isNull);
    });

    test('接管：备份原值，并把 http/https/socks 都指向混合入站', () async {
      final runner = _FakeRunner((String exe, List<String> args) {
        if (exe == 'gsettings' && args.length >= 3 && args[0] == 'get') {
          return _gnomeOriginal(args[1], args[2]);
        }
        return _ok('');
      });
      final proxy = build(runner);

      expect(await proxy.set(host: '127.0.0.1', port: 2080), isTrue);

      // 三个协议必须都指过去：只写 http 是常见误配，HTTPS 站点会漏出去。
      expect(
        runner.calls,
        contains('gsettings set org.gnome.system.proxy mode manual'),
      );
      expect(
        runner.calls,
        contains('gsettings set org.gnome.system.proxy.http host 127.0.0.1'),
      );
      expect(
        runner.calls,
        contains('gsettings set org.gnome.system.proxy.http port 2080'),
      );
      expect(
        runner.calls,
        contains('gsettings set org.gnome.system.proxy.https host 127.0.0.1'),
      );
      expect(
        runner.calls,
        contains('gsettings set org.gnome.system.proxy.socks host 127.0.0.1'),
      );
      expect(
        runner.calls,
        contains('gsettings set org.gnome.system.proxy.socks port 2080'),
      );
      // 回环必须绕过代理，否则内核自己的 Clash API 轮询会绕回自己。
      expect(
        runner.calls.any(
          (String c) =>
              c.startsWith('gsettings set org.gnome.system.proxy ignore-hosts'),
        ),
        isTrue,
      );

      final backup =
          jsonDecode(proxy.backupFile.readAsStringSync())
              as Map<String, Object?>;
      expect(backup['desktop'], 'gnome');
      final values = backup['values']! as Map<String, Object?>;
      expect(values['org.gnome.system.proxy|mode'], "'none'");
      expect(values['org.gnome.system.proxy.http|host'], "''");
    });

    test('还原：把备份的原值写回，并在成功后消费备份', () async {
      final runner = _FakeRunner((String exe, List<String> args) {
        if (exe == 'gsettings' && args.length >= 3 && args[0] == 'get') {
          return _gnomeOriginal(args[1], args[2]);
        }
        return _ok('');
      });
      final proxy = build(runner);
      await proxy.set(host: '127.0.0.1', port: 2080);
      runner.calls.clear();

      expect(await proxy.clear(), isTrue);
      expect(
        runner.calls,
        contains("gsettings set org.gnome.system.proxy mode 'none'"),
      );
      expect(
        proxy.backupFile.existsSync(),
        isFalse,
        reason: '还原成功后备份必须消费掉，否则下次启动会再写一遍旧值',
      );
    });

    test('没有备份时 recoverIfNeeded 严格不动系统设置', () async {
      final runner = _FakeRunner((String exe, List<String> args) {
        throw StateError('不应执行任何系统命令');
      });
      final proxy = build(runner);

      expect(await proxy.recoverIfNeeded(), isFalse);
      expect(runner.calls, isEmpty, reason: 'main.dart 每次启动都会调这里');
    });

    test('识别不出桌面环境时如实失败，不发任何命令', () async {
      final runner = _FakeRunner((_, _) => _ok(''));
      final proxy = LinuxSystemProxy(
        dataDir: dataDir,
        environment: const <String, String>{},
        runner: runner,
      );
      expect(await proxy.set(host: '127.0.0.1', port: 2080), isFalse);
      expect(runner.calls, isEmpty);
    });

    test('gsettings 不可用时失败且不留下半份备份', () async {
      final runner = _FakeRunner((String exe, List<String> args) {
        throw ProcessException(exe, args, '未找到 gsettings');
      });
      final proxy = build(runner);

      expect(await proxy.set(host: '127.0.0.1', port: 2080), isFalse);
      expect(proxy.backupFile.existsSync(), isFalse);
    });
  });

  group('凭据保护方案选择', () {
    test('可用钥匙串时选 libsecret，且只在真实往返成功后 isSecure 才为真', () {
      final protector = SecretProtector.forPlatform(
        isWindows: false,
        isLinux: true,
        secretService: _FakeSecretService(available: true),
      );
      expect(protector.scheme, 'libsecret');
      expect(protector.isSecure, isTrue);
      expect(protector.description, contains('钥匙串'));

      final payload = protector.protect('{"username":"u","password":"p"}');
      expect(protector.unprotect(payload), '{"username":"u","password":"p"}');
    });

    test('钥匙串不可用时降级为不加密，并如实说明缺什么', () {
      final protector = SecretProtector.forPlatform(
        isWindows: false,
        isLinux: true,
        secretService: _FakeSecretService(available: false),
      );
      expect(protector.scheme, 'plain');
      expect(protector.isSecure, isFalse);
      expect(protector.description, contains('secret-tool'));
    });

    test('同一份明文得到稳定的 key，不会在钥匙串里堆孤儿条目', () {
      expect(
        LinuxSecretProtector.accountFor('same'),
        LinuxSecretProtector.accountFor('same'),
      );
      expect(
        LinuxSecretProtector.accountFor('a'),
        isNot(LinuxSecretProtector.accountFor('b')),
      );
    });
  });

  group('Linux 入站方式：本轮不接 TUN', () {
    test('默认入站是 mixed，生成的配置里没有任何 tun', () {
      final parsed = VpnProtocolFactory.parse(_wireGuardConf, 'wg.conf');
      final config = SingBoxConfigBuilder.build(
        profile: parsed,
        splitMode: SplitMode.smart,
        ruleSetDir: '/tmp/xvpn-rules',
      );
      final inbounds = config['inbounds']! as List<Object?>;
      expect(inbounds, hasLength(1));
      expect((inbounds.first! as Map<String, Object?>)['type'], 'mixed');
      expect(
        SingBoxConfigBuilder.encode(config),
        isNot(contains('"tun"')),
        reason:
            'Linux 本轮只做系统代理；出现 tun 就意味着有人在没验证的情况下'
            '又打开了需要特权的路径',
      );
    });
  });

  group('Linux 界面', () {
    testWidgets('设置页讲系统代理并说明它的限制，不出现 TUN 选项', (WidgetTester tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        final state = AppState();
        addTearDown(state.dispose);
        tester.view.physicalSize = const Size(1400, 1200);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildXvTheme(XvPalette.dark),
            home: XvShell(state: state, theme: ThemeController()),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('设置').first);
        await tester.pumpAndSettle();

        expect(find.text('流量接管方式'), findsWidgets);
        expect(find.text('系统代理'), findsOneWidget);
        expect(find.text('TUN 虚拟网卡'), findsNothing);
        expect(
          find.textContaining('只有认系统代理的程序会走隧道'),
          findsOneWidget,
          reason: 'Linux 与 Windows 有同一个限制，必须讲清楚',
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('X11：自绘标题栏的窗口按钮照常渲染', (WidgetTester tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      WindowControls.linuxClientDecorations = true;
      try {
        final state = AppState();
        addTearDown(state.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildXvTheme(XvPalette.dark),
            home: Scaffold(
              body: Column(
                children: <Widget>[
                  XvTitleBar(theme: ThemeController(), state: state),
                ],
              ),
            ),
          ),
        );
        await tester.pump();

        for (final label in <String>['最小化', '最大化', '关闭']) {
          expect(find.byTooltip(label), findsOneWidget);
        }
      } finally {
        WindowControls.linuxClientDecorations = true;
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('Wayland：隐藏窗口按钮与拖动区，交回原生装饰', (WidgetTester tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      WindowControls.linuxClientDecorations = false;
      try {
        final state = AppState();
        addTearDown(state.dispose);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildXvTheme(XvPalette.dark),
            home: Scaffold(
              body: Column(
                children: <Widget>[
                  XvTitleBar(theme: ThemeController(), state: state),
                ],
              ),
            ),
          ),
        );
        await tester.pump();

        for (final label in <String>['最小化', '最大化', '关闭']) {
          expect(
            find.byTooltip(label),
            findsNothing,
            reason: 'Wayland 下这些按钮点了也没有可靠行为，必须整组消失',
          );
        }
        // 品牌与 GitHub 入口保留：它们与窗口控制无关。
        expect(find.byTooltip('在 GitHub 上查看源码'), findsOneWidget);
      } finally {
        WindowControls.linuxClientDecorations = true;
        debugDefaultTargetPlatformOverride = null;
      }
    });
  });
}
