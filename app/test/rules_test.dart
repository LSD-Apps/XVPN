import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/app_state.dart';
import 'package:xvpn/core/auto_route.dart';
import 'package:xvpn/core/rulesets.dart';
import 'package:xvpn/core/singbox_config.dart';
import 'package:xvpn/core/singbox_runner.dart';
import 'package:xvpn/core/store.dart';
import 'package:xvpn/core/vpn_core.dart';
import 'package:xvpn/models.dart';
import 'package:xvpn/protocols/wireguard_conf.dart';
import 'package:xvpn/screens/rules_screen.dart';
import 'package:xvpn/screens/shell.dart';
import 'package:xvpn/theme.dart';
import 'package:xvpn/theme_controller.dart';
import 'package:xvpn/widgets/auto_route_card.dart';
import 'package:xvpn/widgets/common.dart';

import 'support/recording_listener.dart';

const _wireGuard = '''
[Interface]
PrivateKey = AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA=
Address = 10.0.0.3/32
DNS = 8.8.8.8
MTU = 1380

[Peer]
PublicKey = ISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+P0A=
Endpoint = vpn.example.net:51820
AllowedIPs = 0.0.0.0/0
''';

Map<String, Object?> _map(Object? value) =>
    (value! as Map<Object?, Object?>).cast<String, Object?>();

List<Object?> _list(Object? value) => value! as List<Object?>;

Map<String, Object?> _build(List<RuleSetSpec> ruleSets) =>
    SingBoxConfigBuilder.build(
      profile: WireGuardProfile(WireGuardConf.parse(_wireGuard)),
      splitMode: SplitMode.smart,
      ruleSetDir: r'C:\Users\test\XVPN\rulesets',
      ruleSets: ruleSets,
    );

void main() {
  late Directory dir;
  late AppStore store;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('xvpn-rules-test');
    store = AppStore(dir);
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// 一份通过魔数校验的假 `.srs`：前三个字节是 "SRS"，长度超过 64。
  Uint8List validSrs() {
    final bytes = Uint8List(128);
    bytes[0] = 0x53;
    bytes[1] = 0x52;
    bytes[2] = 0x53;
    return bytes;
  }

  Future<List<int>?> fakeFetch(String url) async => validSrs();

  /// 带真实内核状态的状态对象；规则集目录指向本次测试的临时目录。
  AppState newState({Future<List<int>?> Function(String)? fetcher}) => AppState(
    store: store,
    ruleSetFetcher: fetcher ?? fakeFetch,
    coreFactory: (VpnCoreListener listener) => SingBoxRunner(
      listener,
      probesEnabled: false,
      runtimeOverride: CoreRuntime(
        singBoxExe: File('${dir.path}${Platform.pathSeparator}sing-box'),
        ruleSetDir: dir,
        assetDir: dir,
        workDir: dir,
      ),
    ),
  );

  RuleSetEntry entryOf(AppState state, String name) =>
      state.ruleSets.firstWhere((RuleSetEntry e) => e.name == name);

  group('规则集状态与持久化', () {
    test('默认规则集清单是一份显式的、可复核的出厂清单', () {
      final state = newState();
      addTearDown(state.dispose);

      // 刻意**写死**清单而不是按来源推导：改变默认启用的规则集会改变所有用户的
      // 路由，属于需要被看见的决定。写死意味着任何改动都必须同时改这条断言，
      // 于是它会出现在 diff 里，而不是悄悄溜过去。
      expect(
        state.ruleSets.map((RuleSetEntry e) => e.name),
        <String>[
          'geosite-cn',
          'geoip-cn',
          'geosite-cn-extra',
          'geoip-cn-extra',
        ],
      );
      for (final entry in state.ruleSets) {
        expect(entry.isBuiltin, isTrue);
      }
      // 每个条目的启用状态必须与内置定义里的声明一致——那是唯一的默认值来源。
      for (final entry in state.ruleSets) {
        final declared = RuleSetStore.builtins
            .firstWhere((BuiltinRuleSet b) => b.name == entry.name);
        expect(
          entry.enabled,
          declared.enabledByDefault,
          reason: '${entry.name} 的默认值只能来自 BuiltinRuleSet，不能由别处决定',
        );
      }
    });

    test('停用标记跨重启保留', () {
      final first = newState();
      expect(first.setRuleSetEnabled('geosite-cn', false), isTrue);
      first.dispose();

      final second = newState();
      addTearDown(second.dispose);
      expect(entryOf(second, 'geosite-cn').enabled, isFalse);
      expect(entryOf(second, 'geoip-cn').enabled, isTrue);
    });

    test('删除内置规则集跨重启保留，恢复内置能找回', () {
      final first = newState();
      expect(first.deleteRuleSet('geosite-cn'), isTrue);
      first.dispose();

      final second = newState();
      addTearDown(second.dispose);
      expect(
        second.ruleSets.map((RuleSetEntry e) => e.name),
        isNot(contains('geosite-cn')),
        reason: '删掉的内置规则集不该在重启时自己复活',
      );

      second.restoreBuiltinRuleSets();
      expect(
        second.ruleSets.map((RuleSetEntry e) => e.name),
        containsAll(<String>['geosite-cn', 'geoip-cn']),
      );
      expect(entryOf(second, 'geosite-cn').enabled, isTrue);
    });

    test('删除全部规则集后重启不会退回出厂默认列表', () {
      final first = newState();
      // 逐条删完当前所有规则集（而不是写死两个名字）：将来新增内置项时，
      // 这条用例仍然在验证「删光之后不会自己复活」。
      for (final entry in first.ruleSets.toList()) {
        first.deleteRuleSet(entry.name);
      }
      expect(first.ruleSets, isEmpty);
      first.dispose();

      final second = newState();
      addTearDown(second.dispose);
      expect(second.ruleSets, isEmpty);
    });

    test('新增自定义规则集：下载、落盘、跨重启保留', () async {
      final first = newState();
      final error = await first.addCustomRuleSet(
        name: 'my-rules',
        url: 'https://example.com/my-rules.srs',
      );
      expect(error, isNull);
      final custom = entryOf(first, 'my-rules');
      expect(custom.kind, RuleSetKind.custom);
      expect(custom.enabled, isTrue);
      expect(
        File('${dir.path}${Platform.pathSeparator}my-rules.srs').existsSync(),
        isTrue,
        reason: '自定义规则集必须真的落盘，否则内核引用的是一个不存在的文件',
      );
      first.dispose();

      final second = newState();
      addTearDown(second.dispose);
      final restored = entryOf(second, 'my-rules');
      expect(restored.kind, RuleSetKind.custom);
      expect(restored.url, 'https://example.com/my-rules.srs');
    });

    test('新增自定义规则集的非法输入与下载失败都返回原因且不写入', () async {
      final state = newState(fetcher: (String url) async => null);
      addTearDown(state.dispose);

      expect(
        await state.addCustomRuleSet(name: 'Bad Name', url: 'https://e.com/a.srs'),
        isNotNull,
        reason: '名称非法要给出原因',
      );
      expect(
        await state.addCustomRuleSet(name: 'ok', url: 'not a url'),
        isNotNull,
        reason: '链接非法要给出原因',
      );
      expect(
        await state.addCustomRuleSet(name: 'ok', url: 'https://e.com/a.srs'),
        isNotNull,
        reason: '下载失败要给出原因',
      );
      expect(state.ruleSets.any((RuleSetEntry e) => e.name == 'ok'), isFalse);

      // 即便内置规则集已被删除，也不能用它的名字新增自定义规则集：
      // 固定文件名会让「出厂副本还是自定义内容」无法分辨。
      state.deleteRuleSet('geosite-cn');
      expect(
        await state.addCustomRuleSet(
          name: 'geosite-cn',
          url: 'https://e.com/a.srs',
        ),
        isNotNull,
      );
    });

    test('编辑自定义规则集：改名与换链接会重命名文件并重新下载', () async {
      final state = newState();
      addTearDown(state.dispose);
      expect(
        await state.addCustomRuleSet(
          name: 'my-rules',
          url: 'https://example.com/a.srs',
        ),
        isNull,
      );
      final error = await state.updateCustomRuleSet(
        oldName: 'my-rules',
        name: 'my-rules-2',
        url: 'https://example.com/b.srs',
      );
      expect(error, isNull);
      expect(entryOf(state, 'my-rules-2').url, 'https://example.com/b.srs');
      expect(
        File('${dir.path}${Platform.pathSeparator}my-rules-2.srs').existsSync(),
        isTrue,
      );
      expect(
        File('${dir.path}${Platform.pathSeparator}my-rules.srs').existsSync(),
        isFalse,
        reason: '改名后旧文件应被清掉，避免两个文件同时存在',
      );
    });

    test('内置规则集不能改名或修改链接', () async {
      final state = newState();
      addTearDown(state.dispose);
      expect(
        await state.updateCustomRuleSet(
          oldName: 'geosite-cn',
          name: 'renamed',
          url: 'https://example.com/x.srs',
        ),
        isNotNull,
      );
      expect(state.ruleSets.any((RuleSetEntry e) => e.name == 'renamed'), isFalse);
    });

    test('恢复内置规则的清理范围：清学到、保留手工与自定义', () async {
      final state = newState();
      addTearDown(state.dispose);

      await state.addCustomRuleSet(
        name: 'mine',
        url: 'https://example.com/mine.srs',
      );
      state.setRuleSetEnabled('geosite-cn', false);
      state.deleteRuleSet('geoip-cn');

      // 一条手工指定的规则。
      expect(
        state.setDomainPreference('user.example', RoutePreference.forceProxy),
        isTrue,
      );
      // 一条程序学到的规则（解析不一致一次即纠正）。
      state.autoRoute!.recordDirectFailure(
        'learned.example',
        reason: '连接超时',
        dnsVerdict: 'suspectPoisoning',
      );
      expect(state.autoRoute!.match('learned.example'), isNotNull);

      state.restoreBuiltinRuleSets();

      expect(
        state.ruleSets.map((RuleSetEntry e) => e.name),
        containsAll(<String>['geosite-cn', 'geoip-cn', 'mine']),
      );
      expect(
        entryOf(state, 'geosite-cn').enabled,
        isTrue,
        reason: '恢复内置要重新启用被停用的内置规则集',
      );
      expect(
        state.autoRoute!.match('learned.example'),
        isNull,
        reason: '程序学到的规则应当被丢弃——用户要的是回到出厂判断',
      );
      final user = state.autoRoute!.match('user.example');
      expect(user, isNotNull, reason: '手工指定的规则是用户的决定，必须保留');
      expect(user!.source, RouteRuleSource.user);
    });
  });

  group('生成配置只随规则改动而变化', () {
    test('默认规则集清单是显式的，且整份写进内核配置', () {
      final core = SingBoxRunner(RecordingListener(), probesEnabled: false);
      addTearDown(core.dispose);

      // 刻意写死：默认启用的规则集一变，所有用户的路由就变，因此这个清单必须
      // 是一处**显式**的、会被 diff 看到的事实，而不是从别处推导出来的结果。
      expect(
        core.enabledRuleSetSpecs.map((RuleSetSpec s) => s.tag),
        <String>[
          'geosite-cn',
          'geoip-cn',
          'geosite-cn-extra',
          'geoip-cn-extra',
        ],
      );
      // 域名类标记决定谁能参与 DNS 直连分流，标错不会报错、只会让判定失效。
      expect(
        core.enabledRuleSetSpecs
            .where((RuleSetSpec s) => s.domainRuleSet)
            .map((RuleSetSpec s) => s.tag),
        <String>['geosite-cn', 'geosite-cn-extra'],
        reason: 'geosite-cn-extra 是域名类；漏标会让被它判为直连的域名经隧道解析',
      );

      // 生成出来的配置里，这四条规则集都要有定义并参与路由。
      final route = _map(_build(core.enabledRuleSetSpecs)['route']);
      expect(
        _list(route['rule_set']).map((Object? s) => _map(s)['tag']),
        <String>[
          'geosite-cn',
          'geoip-cn',
          'geosite-cn-extra',
          'geoip-cn-extra',
        ],
      );
    });

    test('推荐规则集声明的域名类标记会一路进到 DNS 规则', () {
      // 这条锁定的是 P0 缺口：先前「是否域名类」靠 `tag == 'geosite-cn'` 硬编码，
      // 而按推荐添加的规则集走自定义路径 → 一律被当成非域名类 → 被它判为直连的
      // 域名仍经隧道解析（拿到境外 CDN 地址再去直连）。
      final suggestion = RuleSetStore.suggested
          .firstWhere((SuggestedRuleSet s) => s.name == 'cn-large');
      expect(
        suggestion.domainRuleSet,
        isTrue,
        reason: 'cn-large 是域名清单（ChinaMax_Domain 派生），必须参与 DNS 分流',
      );

      final specs = <RuleSetSpec>[
        ...SingBoxConfigBuilder.defaultRuleSets,
        RuleSetSpec(
          tag: suggestion.name,
          fileName: '${suggestion.name}.srs',
          domainRuleSet: suggestion.domainRuleSet,
        ),
      ];
      final config = _build(specs);
      final dnsRules = _list(_map(config['dns'])['rules']).map(_map).toList();
      final toDirect = dnsRules.firstWhere(
        (Map<String, Object?> r) =>
            r['server'] == 'dns-cn' && r['rule_set'] != null,
        orElse: () => <String, Object?>{},
      );
      expect(
        toDirect['rule_set'],
        contains('cn-large'),
        reason: '推荐规则集必须出现在 DNS 直连规则里，否则判定与实际解析不一致',
      );
    });

    test('手工新增的自定义规则集不参与 DNS 分流（类型无从得知）', () {
      final config = _build(<RuleSetSpec>[
        ...SingBoxConfigBuilder.defaultRuleSets,
        const RuleSetSpec(tag: 'my-rules', fileName: 'my-rules.srs'),
      ]);
      final dnsRules = _list(_map(config['dns'])['rules']).map(_map).toList();
      for (final rule in dnsRules) {
        final tags = rule['rule_set'];
        if (tags is List) {
          expect(
            tags,
            isNot(contains('my-rules')),
            reason: '手工新增的规则集是域名还是 IP 清单，程序不猜',
          );
        }
      }
    });

    test('域名类标记跨重启保留', () async {
      final state = newState();
      addTearDown(state.dispose);
      expect(
        await state.addCustomRuleSet(
          name: 'named-rules',
          url: 'https://e.com/a.srs',
          domainRuleSet: true,
        ),
        isNull,
      );
      expect(entryOf(state, 'named-rules').domainRuleSet, isTrue);
      state.dispose();

      final second = newState();
      addTearDown(second.dispose);
      expect(
        entryOf(second, 'named-rules').domainRuleSet,
        isTrue,
        reason: '标记不持久化的话，重启后就又变成不参与 DNS 分流了',
      );
    });

    test('旧存档缺少域名类标记时，按内置定义回退', () {
      // 这是升级路径的关键：旧存档里 geosite-cn 必然没有这个键，
      // 若默认 false，升级上来的用户会静默失去「命中规则集的域名走直连解析器」。
      final legacy = RuleSetEntry.fromJson(<String, Object?>{
        'name': 'geosite-cn',
        'kind': 'builtin',
        'url': 'https://example.com/geosite-cn.srs',
      });
      expect(legacy, isNotNull);
      expect(
        legacy!.domainRuleSet,
        isTrue,
        reason: '键缺失要回退到内置定义，而不是默认 false',
      );

      // 未知名字（自定义）缺失键时仍按非域名类。
      final custom = RuleSetEntry.fromJson(<String, Object?>{
        'name': 'whatever',
        'kind': 'custom',
        'url': 'https://example.com/x.srs',
      });
      expect(custom!.domainRuleSet, isFalse);
    });

    test('自定义规则集确实被写进内核配置', () {
      final config = _build(<RuleSetSpec>[
        ...SingBoxConfigBuilder.defaultRuleSets,
        const RuleSetSpec(tag: 'my-rules', fileName: 'my-rules.srs'),
      ]);
      final route = _map(config['route']);
      final sets = _list(route['rule_set']).map(_map).toList();

      final custom = sets.firstWhere((Map<String, Object?> s) => s['tag'] == 'my-rules');
      expect(custom['type'], 'local');
      expect(custom['format'], 'binary');
      expect(custom['path'], endsWith('/my-rules.srs'));

      final direct = _list(route['rules'])
          .map(_map)
          .firstWhere(
            (Map<String, Object?> r) =>
                r['outbound'] == 'direct' && r['rule_set'] != null,
          );
      expect(
        direct['rule_set'],
        <String>['geosite-cn', 'geoip-cn', 'my-rules'],
        reason: '自定义规则集必须真的参与路由，否则就是一个拨了没反应的开关',
      );
    });

    test('停用的规则集不进入配置', () {
      final core = SingBoxRunner(RecordingListener(), probesEnabled: false);
      addTearDown(core.dispose);
      final defaults = RuleSetStore.defaultEntries();
      core.setRuleSets(<RuleSetEntry>[
        defaults[0],
        defaults[1]..enabled = false,
      ]);
      expect(
        core.enabledRuleSetSpecs.map((RuleSetSpec s) => s.tag),
        <String>['geosite-cn'],
      );
      final route = _map(_build(core.enabledRuleSetSpecs)['route']);
      final sets = _list(route['rule_set']).map(_map).toList();
      expect(sets, hasLength(1));
      expect(sets.single['tag'], 'geosite-cn');
    });

    test('删光规则集时不产生引用未定义 rule_set 的规则', () {
      final config = _build(const <RuleSetSpec>[]);
      final route = _map(config['route']);
      expect(_list(route['rule_set']), isEmpty);
      final rules = _list(route['rules']).map(_map).toList();
      expect(
        rules.any((Map<String, Object?> r) => r['rule_set'] != null),
        isFalse,
        reason: '引用一个不存在的 rule_set 会让内核直接拒绝启动',
      );
      final dns = _map(config['dns']);
      expect(_list(dns['rules']), isEmpty);
    });

    test('全部域名类规则集都参与 DNS 直连分流', () {
      // 这条锁定的是「新增域名类规则集时必须同时进 DNS 规则」：漏掉它不会报错，
      // 只会表现为「被它判为直连的域名仍被境外解析器解析」——于是拿到境外 CDN
      // 的地址再去直连，判定对了、结果仍错。这是最难从现象看出原因的一类问题。
      final config = _build(<RuleSetSpec>[
        ...SingBoxConfigBuilder.defaultRuleSets,
        const RuleSetSpec(
          tag: 'geosite-cn-extra',
          fileName: 'geosite-cn-extra.srs',
          domainRuleSet: true,
        ),
      ]);
      final dnsRules = _list(_map(config['dns'])['rules']).map(_map).toList();
      final toDirect = dnsRules.firstWhere(
        (Map<String, Object?> r) =>
            r['server'] == 'dns-cn' && r['rule_set'] != null,
        orElse: () => <String, Object?>{},
      );
      expect(
        toDirect['rule_set'],
        <String>['geosite-cn', 'geosite-cn-extra'],
        reason: '内核的一条规则里多个 rule_set 之间是「或」，一次即可表达全部域名类',
      );
    });

    test('IP 类规则集不进入 DNS 规则', () {
      // dns 查询的是域名，把 IP 类规则集写进 DNS 规则没有意义。
      final config = _build(SingBoxConfigBuilder.defaultRuleSets);
      final dnsRules = _list(_map(config['dns'])['rules']).map(_map).toList();
      for (final rule in dnsRules) {
        final tags = rule['rule_set'];
        if (tags is List) {
          expect(tags, isNot(contains('geoip-cn')));
        }
      }
    });
  });

  group('域名规则的新增 / 编辑 / 删除', () {
    Future<void> scrollTo(WidgetTester tester, String target) async {
      var guard = 0;
      // 用具名 Key 而不是 find.byType(Scrollable).first：输入框内部的
      // EditableText 本身也是一个 Scrollable，按类型取到的可能是它。
      final scrollable = find.byKey(RulesScreen.desktopScrollKey);
      while (find.text(target).evaluate().isEmpty && guard < 30) {
        await tester.drag(scrollable, const Offset(0, -220));
        await tester.pumpAndSettle();
        guard++;
      }
    }

    testWidgets('在分流规则页新增、编辑、删除一条域名规则', (WidgetTester tester) async {
      final state = newState();
      addTearDown(state.dispose);

      tester.view.physicalSize = const Size(1500, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildXvTheme(XvPalette.dark),
          home: XvShell(state: state, theme: ThemeController()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('分流规则'));
      await tester.pumpAndSettle();
      await scrollTo(tester, '手工指定');

      // 新增。
      await tester.enterText(
        find.widgetWithText(TextField, '例如 example.com'),
        'blocked.example.com',
      );
      // 白名单会往这张卡片里多插一组条目，因此「添加」按钮可能落在视口外。
      // 先滚到它再点，否则 tap 会命不中（报「widget is off-screen」）。
      await tester.ensureVisible(find.text('添加'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加'));
      await tester.pumpAndSettle();
      expect(
        state.autoRoute!.match('blocked.example.com')!.preference,
        RoutePreference.forceProxy,
      );

      // 编辑：把走向改成直连。
      //
      // 规则集行与域名规则行都有「编辑」，因此必须限定在 AutoRouteCard 内，
      // 否则 find.text 会同时命中多个。
      final editAction = find.descendant(
        of: find.byType(AutoRouteCard),
        matching: find.text('编辑'),
      );
      await tester.ensureVisible(editAction);
      await tester.tap(editAction);
      await tester.pumpAndSettle();
      expect(find.text('编辑域名规则'), findsOneWidget);
      await tester.tap(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.text('直连'),
        ),
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(
        state.autoRoute!.match('blocked.example.com')!.preference,
        RoutePreference.forceDirect,
      );

      // 删除：需要确认。
      final deleteAction = find.descendant(
        of: find.byType(AutoRouteCard),
        matching: find.text('删除'),
      );
      await tester.ensureVisible(deleteAction);
      await tester.tap(deleteAction);
      await tester.pumpAndSettle();
      expect(find.text('删除域名规则'), findsOneWidget);
      await tester.tap(find.widgetWithText(XvButton, '删除'));
      await tester.pumpAndSettle();
      expect(state.autoRoute!.match('blocked.example.com'), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
