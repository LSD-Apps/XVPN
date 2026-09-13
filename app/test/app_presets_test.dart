import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/app_state.dart';
import 'package:xvpn/core/app_presets.dart';
import 'package:xvpn/core/auto_route.dart';
import 'package:xvpn/core/singbox_config.dart';
import 'package:xvpn/core/singbox_runner.dart';
import 'package:xvpn/core/store.dart';
import 'package:xvpn/core/vpn_core.dart';
import 'package:xvpn/models.dart';
import 'package:xvpn/protocols/wireguard_conf.dart';
import 'package:xvpn/theme.dart';
import 'package:xvpn/widgets/app_preset_card.dart';

const _wireGuard = '''
[Interface]
PrivateKey = AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA=
Address = 10.0.0.3/32
DNS = 8.8.8.8

[Peer]
PublicKey = ISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+P0A=
Endpoint = vpn.example.net:51820
AllowedIPs = 0.0.0.0/0
''';

Map<String, Object?> _map(Object? value) =>
    (value! as Map<Object?, Object?>).cast<String, Object?>();

List<Object?> _list(Object? value) => value! as List<Object?>;

/// 按「已启用的预置」构造一份决策表 + 生成配置。
///
/// 预置现在走 `AutoRouteTable` 这**一条**统一路径（而不是在配置生成时另插
/// 规则），因此这里也必须按真实的安装方式搭表——这样断言才落在真实链路上。
({
  AutoRouteTable table,
  Map<String, Object?> config,
})
_build(
  List<AppPreset> presets, {
  SplitMode mode = SplitMode.smart,
  AutoRouteTable? table,
}) {
  final built = table ?? AutoRouteTable();
  for (final preset in presets) {
    built.setPreset(preset, enabled: true);
  }
  final config = SingBoxConfigBuilder.build(
    profile: WireGuardProfile(WireGuardConf.parse(_wireGuard)),
    splitMode: mode,
    ruleSetDir: r'C:\Users\test\XVPN\rulesets',
    autoRoute: built,
  );
  return (table: built, config: config);
}

List<Map<String, Object?>> _rules(Map<String, Object?> config) =>
    _list(_map(config['route'])['rules']).map(_map).toList();

/// DNS 规则里 domain / domain_suffix 字段里的域名集合。
List<Map<String, Object?>> _dnsRules(Map<String, Object?> config) =>
    _list(_map(config['dns'])['rules']).map(_map).toList();

/// 规则里 domain / domain_suffix 字段里的域名集合。
Set<String> _domainsOf(Map<String, Object?> rule) {
  final result = <String>{};
  for (final key in <String>['domain', 'domain_suffix']) {
    final raw = rule[key];
    if (raw is List) {
      result.addAll(raw.whereType<String>());
    }
  }
  return result;
}

void main() {
  group('预置清单自身的约束', () {
    test('id 唯一且能查到；未知 id 返回 null', () {
      final ids = AppPresets.all.map((AppPreset p) => p.id).toList();
      expect(ids.toSet(), hasLength(ids.length), reason: 'id 重复会让开关互相串台');
      for (final id in ids) {
        expect(AppPresets.byId(id), isNotNull);
      }
      expect(AppPresets.byId('does-not-exist'), isNull);
    });

    test('每个预置都有直连域名与实测依据', () {
      for (final preset in AppPresets.all) {
        expect(preset.directDomains, isNotEmpty, reason: '${preset.id} 没有直连域名');
        expect(
          preset.evidence,
          isNotNull,
          reason: '${preset.id} 缺少实测依据：可达性会变，没有依据将来无从复核',
        );
      }
    });

    test('直连域名不会与自己的例外完全重叠', () {
      // 完全重叠意味着这个预置自相矛盾：同一个域名既要求直连又要求在隧道里。
      for (final preset in AppPresets.all) {
        final direct = preset.directDomains.toSet();
        for (final exception in preset.tunnelExceptions) {
          expect(
            direct.contains(exception),
            isFalse,
            reason: '${preset.id} 的例外 $exception 同时出现在直连清单里',
          );
        }
      }
    });

    test('默认启用集合由 defaultEnabled 标记推导，且与实际标记一致', () {
      final ids = AppPresets.defaultEnabledIds();
      expect(
        ids,
        AppPresets.all
            .where((AppPreset p) => p.defaultEnabled)
            .map((AppPreset p) => p.id)
            .toList(),
      );
      expect(
        ids,
        contains(AppPresets.cnExtra.id),
        reason: '国内站点补充修正的是「国内站点被误判进隧道」，应默认启用',
      );
      expect(
        ids,
        isNot(contains(AppPresets.cursor.id)),
        reason: '境外应用走隧道才是常态，直连是例外，必须由用户显式启用',
      );
    });

    test('国内站点补充的清单都有实测依据，且不含例外', () {
      expect(AppPresets.cnExtra.directDomains, isNotEmpty);
      expect(AppPresets.cnExtra.evidence, isNotNull);
      expect(
        AppPresets.cnExtra.tunnelExceptions,
        isEmpty,
        reason: '这些是实测确认能直连的国内域名，不应再留隧道例外',
      );
    });

    test('resolve 按登记顺序返回、忽略未知 id', () {
      final resolved = AppPresets.resolve(<String>[
        'nope',
        AppPresets.cursor.id,
      ]);
      expect(resolved.map((AppPreset p) => p.id), <String>[AppPresets.cursor.id]);
      expect(AppPresets.resolve(const <String>[]), isEmpty);
    });

    test('Cursor 预置把三个国内解析不出的域名留在隧道里', () {
      // 这三条是实测结论（NXDOMAIN），任何一条被移出例外都会让直连直接打不开，
      // 而且 NXDOMAIN 属于「解析失败」，不会触发自动纠正救回来。
      expect(
        AppPresets.cursor.tunnelExceptions,
        containsAll(<String>[
          'api5.cursor.sh',
          'us-asia.gcpp.cursor.sh',
          'us-eu.gcpp.cursor.sh',
        ]),
      );
    });
  });

  group('生成配置里的预置规则', () {
    test('未启用预置时不产生任何按域名的预置规则', () {
      // 这是「新增功能不能悄悄改变既有路由」的保证：没有预置时，
      // 路由规则与从前完全一致（sniff / hijack-dns / 内网 / 规则集），
      // DNS 规则也与从前完全一致（只有 geosite-cn 那一条）。
      final built = _build(const <AppPreset>[]);
      final rules = _rules(built.config);
      expect(rules, hasLength(4));
      expect(rules[0]['action'], 'sniff');
      expect(rules[1]['action'], 'hijack-dns');
      expect(rules[2]['ip_is_private'], isTrue);
      expect(rules[3]['rule_set'], isNotNull);
      for (final rule in rules) {
        expect(rule.containsKey('domain'), isFalse);
        expect(rule.containsKey('domain_suffix'), isFalse);
      }
      expect(_dnsRules(built.config), hasLength(1));
    });

    test('启用 Cursor 预置后同时下发直连规则与例外规则', () {
      final rules = _rules(_build(<AppPreset>[AppPresets.cursor]).config);
      final direct = rules.firstWhere(
        (Map<String, Object?> r) =>
            r['outbound'] == 'direct' && _domainsOf(r).contains('cursor.sh'),
        orElse: () => <String, Object?>{},
      );
      expect(direct, isNotEmpty, reason: '直连规则必须真的写进配置');
      expect(
        _domainsOf(direct),
        containsAll(<String>['cursor.com', 'cursorapi.com', 'cursor-cdn.com']),
      );

      final exception = rules.firstWhere(
        (Map<String, Object?> r) =>
            r['outbound'] == 'vpn' &&
            _domainsOf(r).contains('api5.cursor.sh'),
        orElse: () => <String, Object?>{},
      );
      expect(exception, isNotEmpty, reason: '例外必须真的写进配置');
    });

    test('例外规则排在直连规则之前，否则后缀覆盖会让例外失效', () {
      // 内核按顺序首次命中即生效；api5.cursor.sh 落在 cursor.sh 后缀的覆盖范围内，
      // 因此例外必须先出现。顺序错了就是「curl 能通、Cursor 打不开」。
      final rules = _rules(_build(<AppPreset>[AppPresets.cursor]).config);
      final exceptionIndex = rules.indexWhere(
        (Map<String, Object?> r) => _domainsOf(r).contains('api5.cursor.sh'),
      );
      final directIndex = rules.indexWhere(
        (Map<String, Object?> r) => _domainsOf(r).contains('cursor.sh'),
      );
      expect(exceptionIndex, isNonNegative);
      expect(directIndex, isNonNegative);
      expect(
        exceptionIndex,
        lessThan(directIndex),
        reason: '例外必须先于直连规则，内核按首次命中生效',
      );
    });

    test('预置规则早于规则集规则，否则规则库先判成走隧道就没机会了', () {
      // 「不在规则库里」正是预置要处理的情形，规则必须早于 rule_set 那条才有意义。
      final rules = _rules(_build(<AppPreset>[AppPresets.cursor]).config);
      final presetIndex = rules.indexWhere(
        (Map<String, Object?> r) => _domainsOf(r).contains('cursor.sh'),
      );
      final ruleSetIndex = rules.indexWhere(
        (Map<String, Object?> r) => r['rule_set'] != null,
      );
      expect(presetIndex, lessThan(ruleSetIndex));
    });

    test('全局代理与全局直连不注入预置规则', () {
      for (final mode in <SplitMode>[
        SplitMode.globalProxy,
        SplitMode.globalDirect,
      ]) {
        final rules = _rules(
          _build(<AppPreset>[AppPresets.cursor], mode: mode).config,
        );
        expect(
          rules.any((Map<String, Object?> r) => r.containsKey('domain')),
          isFalse,
          reason: '${mode.name} 是用户显式声明不分流，注入域名规则与意图冲突',
        );
      }
    });

    test('DNS 决策跟随路由决策：直连的域名交给直连解析器', () {
      // 这一条锁定的是「DNS 与路由必须一致」这个不变量。此前 dns.rules 只认
      // geosite-cn，于是「已判定该直连」的域名仍被境外解析器解析，拿到境外
      // CDN 的地址再去直连——判定对了、结果仍错。
      final built = _build(<AppPreset>[AppPresets.cnExtra]);
      final dnsRules = _dnsRules(built.config);
      final toDirect = dnsRules.firstWhere(
        (Map<String, Object?> r) =>
            r['server'] == 'dns-cn' && r['domain'] != null,
        orElse: () => <String, Object?>{},
      );
      expect(toDirect, isNotEmpty, reason: '判定直连的域名必须用直连解析器解析');
      expect(_domainsOf(toDirect), contains('gaoding.com'));
    });

    test('DNS 决策跟随路由决策：强制代理的域名交给隧道解析器', () {
      // 镜像方向：「因境内答案不可信而被改成走隧道」的域名，不该继续被送去
      // 境内解析器——那与判定的依据直接冲突。
      final built = _build(<AppPreset>[AppPresets.cursor]);
      // 例外（api5 等）就是强制代理方向。
      final dnsRules = _dnsRules(built.config);
      final toRemote = dnsRules.firstWhere(
        (Map<String, Object?> r) =>
            r['server'] == 'dns-remote' && r['domain'] != null,
        orElse: () => <String, Object?>{},
      );
      expect(toRemote, isNotEmpty);
      expect(_domainsOf(toRemote), contains('api5.cursor.sh'));

      // 顺序：强制代理那条必须排在 geosite-cn 之前。
      final remoteIndex = dnsRules.indexOf(toRemote);
      final ruleSetIndex = dnsRules.indexWhere((r) => r['rule_set'] != null);
      expect(
        remoteIndex,
        lessThan(ruleSetIndex),
        reason: '这些域名往往同时命中 geosite-cn，排在后面就永远不生效',
      );
    });

    test('全局模式不注入 DNS 域名规则', () {
      for (final mode in <SplitMode>[
        SplitMode.globalProxy,
        SplitMode.globalDirect,
      ]) {
        final dnsRules = _dnsRules(
          _build(<AppPreset>[AppPresets.cursor], mode: mode).config,
        );
        expect(
          dnsRules.any((Map<String, Object?> r) => r['domain'] != null),
          isFalse,
          reason: '${mode.name} 下不分流，DNS 也不该按域名分流',
        );
      }
    });

    test('用户规则可以覆盖「内网直连」，其余规则不能', () {
      // 这是整条优先级链的落地检查：规则在配置里的**下标顺序**就是内核的
      // 判定顺序，因此用下标断言，而不是「某些规则存在」这种弱断言。
      //
      // 契约（见 AutoRouteTable.buildRouteRules 的表格）：
      //   用户规则 → 内网直连 → 学到/白名单 → 规则库 → final
      AutoRouteTable build({
        required String userDomain,
        required String learnedDomain,
      }) {
        final table = AutoRouteTable(promotionThreshold: 1)
          ..setUserRule(userDomain, RoutePreference.forceProxy)
          ..recordDirectFailure(learnedDomain);
        return table;
      }

      final rules = _rules(
        _build(<AppPreset>[], table: build(
          userDomain: 'mine.example',
          learnedDomain: 'learned.example',
        )).config,
      );

      int indexOfDomain(String domain) => rules.indexWhere(
        (Map<String, Object?> r) =>
            (_domainsOf(r).contains(domain)) ||
            ((r['domain_suffix'] as List?)?.contains(domain) ?? false),
      );

      final userIndex = indexOfDomain('mine.example');
      final privateIndex = rules.indexWhere(
        (Map<String, Object?> r) => r['ip_is_private'] == true,
      );
      final learnedIndex = indexOfDomain('learned.example');
      final ruleSetIndex = rules.indexWhere((r) => r['rule_set'] != null);

      expect(userIndex, isNonNegative);
      expect(privateIndex, isNonNegative);
      expect(learnedIndex, isNonNegative);
      expect(ruleSetIndex, isNonNegative);

      expect(
        userIndex,
        lessThan(privateIndex),
        reason: '用户显式指定要能覆盖内网直连（例如为了排查问题把内网域名指向代理）',
      );
      expect(
        privateIndex,
        lessThan(learnedIndex),
        reason: '私有地址段是确定的边界，不该被推断出的证据推翻——'
            '内网主机名一旦临时不可达就可能被学成「强制代理」，'
            '那会把内网流量送进隧道，既费流量又必然连不上',
      );
      expect(
        learnedIndex,
        lessThan(ruleSetIndex),
        reason: '学到的判断必须早于规则库，否则规则库先判成直连就没机会了',
      );
    });

    test('已有用户规则与学到规则都优先于预置，不会被预置覆盖', () {
      // 这是「预置是优先级最低的来源」这条设计契约。测试它是因为安装预置
      // 发生在**每次启动**，一旦允许覆盖，学到的纠正会被反复抹掉。
      final built = _build(<AppPreset>[AppPresets.cnExtra]);
      final table = built.table;
      // 造两条更高优先级的条目，域名与预置清单重叠。
      table.setUserRule('gaoding.com', RoutePreference.forceProxy);
      table.setPreset(AppPresets.cnExtra, enabled: true);

      expect(table.match('gaoding.com')!.source, RouteRuleSource.user);
      expect(
        table.match('gaoding.com')!.preference,
        RoutePreference.forceProxy,
        reason: '重新安装预置不该覆盖用户的明确决定',
      );

      // 学到规则同理。
      table.setPreset(AppPresets.cnExtra, enabled: false);
      for (var i = 0; i < 3; i++) {
        table.recordDirectFailure('jianyu360.com', reason: '连接超时');
      }
      expect(table.match('jianyu360.com')!.source, RouteRuleSource.learned);
      table.setPreset(AppPresets.cnExtra, enabled: true);
      expect(
        table.match('jianyu360.com')!.source,
        RouteRuleSource.learned,
        reason: '重新安装预置不该抹掉运行中学到的纠正',
      );
    });
  });

  group('预置开关与持久化', () {
    late Directory dir;
    late AppStore store;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('xvpn-presets-test');
      store = AppStore(dir);
    });

    tearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    /// 带**真实决策表**的状态对象。
    ///
    /// 预置现在装进 `AutoRouteTable`，而演示内核根本没有那张表——用演示内核
    /// 测等于在测一个不存在的东西。
    AppState newState() => AppState(
      store: store,
      coreFactory: (VpnCoreListener l) =>
          SingBoxRunner(l, probesEnabled: false),
    );

    test('默认启用「国内站点补充」，境外应用预置仍为关闭', () {
      final state = newState();
      addTearDown(state.dispose);
      expect(state.enabledAppPresets, <String>[AppPresets.cnExtra.id]);
      expect(state.appPresets, isNotEmpty);
    });

    test('默认启用集合会真的进入生成配置与状态表', () {
      final built = _build(AppPresets.resolve(AppPresets.defaultEnabledIds()));
      final rules = _rules(built.config);
      final direct = rules.firstWhere(
        (Map<String, Object?> r) =>
            r['outbound'] == 'direct' && _domainsOf(r).contains('gaoding.com'),
        orElse: () => <String, Object?>{},
      );
      expect(
        direct,
        isNotEmpty,
        reason: '默认启用却不出现在配置里，就是一个拨了没反应的开关',
      );
      expect(
        built.table.match('www.gaoding.com'),
        isNotNull,
        reason: '预置必须进决策表：界面、DNS 策略与反向纠正都从那张表读',
      );
    });

    test('首次启动（没有存档）也要安装默认启用的预置', () {
      // 只有全新安装才会走这条路：`_restore` 在读不到存档时提前返回。
      // 漏掉同步的表现是「开关显示已启用、路由里却什么都没有」。
      final dir = Directory.systemTemp.createTempSync('xvpn-presets-fresh');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final state = AppState(
        store: AppStore(dir),
        coreFactory: (VpnCoreListener l) =>
            SingBoxRunner(l, probesEnabled: false),
      );
      addTearDown(state.dispose);

      expect(state.enabledAppPresets, <String>[AppPresets.cnExtra.id]);
      expect(
        state.autoRoute!.match('www.gaoding.com')?.source,
        RouteRuleSource.preset,
      );
    });

    test('开关状态会真的同步进决策表（不只是改设置）', () {
      final state = newState();
      addTearDown(state.dispose);
      final table = state.autoRoute!;

      // 默认启用：国内站点补充的域名应当已在表里，且来源是预置。
      expect(table.match('www.gaoding.com')?.source, RouteRuleSource.preset);

      // 关掉后从表里移除。
      state.setAppPresetEnabled(AppPresets.cnExtra.id, false);
      expect(
        table.match('www.gaoding.com'),
        isNull,
        reason: '关掉开关却还把域名留在表里，等于开关没生效',
      );
    });

    test('启用与停用会立刻反映在状态上，未知 id 被拒绝', () {
      final state = newState();
      addTearDown(state.dispose);

      expect(state.setAppPresetEnabled('does-not-exist', true), isFalse);
      expect(state.setAppPresetEnabled(AppPresets.cursor.id, true), isTrue);
      expect(state.enabledAppPresets, <String>[
        AppPresets.cnExtra.id,
        AppPresets.cursor.id,
      ]);
      // 重复设置同一值不算改变。
      expect(state.setAppPresetEnabled(AppPresets.cursor.id, true), isFalse);

      expect(state.setAppPresetEnabled(AppPresets.cursor.id, false), isTrue);
      expect(state.enabledAppPresets, <String>[AppPresets.cnExtra.id]);
    });

    test('启用状态跨重启保留，且重启后重新安装进决策表', () {
      final first = newState();
      expect(first.setAppPresetEnabled(AppPresets.cursor.id, true), isTrue);
      first.dispose();

      final second = newState();
      addTearDown(second.dispose);
      expect(second.enabledAppPresets, <String>[
        AppPresets.cnExtra.id,
        AppPresets.cursor.id,
      ]);
      expect(
        second.autoRoute!.match('api2.cursor.sh')?.source,
        RouteRuleSource.preset,
        reason: '存档只存 id，域名清单每次启动要重新安装，否则重启后规则就没了',
      );
    });

    test('预置不写进存档（域名清单属于程序版本）', () {
      final state = newState();
      addTearDown(state.dispose);
      expect(state.autoRoute!.match('www.gaoding.com'), isNotNull);
      expect(
        state.core.exportAutoRoute().any(
          (Map<String, Object?> e) => e['domain'] == 'gaoding.com',
        ),
        isFalse,
        reason: '写进存档会留下一份会过期的副本，用户关掉开关后它还会留在文件里',
      );
    });

    test('用户关掉默认启用的条目后，重启不会被它复活', () {
      // 这是「键存在就用存档」这条分支的意义所在：默认启用只是一次性的默认值，
      // 一旦用户表达了相反的意思，程序就不能再自作主张地打开它。
      final first = newState();
      expect(
        first.setAppPresetEnabled(AppPresets.cnExtra.id, false),
        isTrue,
      );
      first.dispose();

      final second = newState();
      addTearDown(second.dispose);
      expect(second.enabledAppPresets, isEmpty);
    });

    test('旧存档没有 appPresets 键时回退到默认启用集合', () {
      // 升级上来的用户不会永远拿不到新增的默认项。
      store.save(<String, Object?>{
        'profiles': <Object?>[],
        'settings': <String, Object?>{'logSplits': false},
      });
      final state = newState();
      addTearDown(state.dispose);
      expect(state.enabledAppPresets, <String>[AppPresets.cnExtra.id]);
    });

    test('存档里出现已删除预置的 id 不会让恢复失败', () {
      store.save(<String, Object?>{
        'profiles': <Object?>[],
        'settings': <String, Object?>{
          'appPresets': <Object?>['ghost-preset', AppPresets.cursor.id],
        },
      });
      final state = newState();
      addTearDown(state.dispose);
      expect(state.enabledAppPresets, <String>[AppPresets.cursor.id]);
    });
  });

  group('分流规则页的预置开关', () {
    testWidgets('点击开关能启用预置，且卡片写明例外与依据', (WidgetTester tester) async {
      final state = AppState();
      addTearDown(state.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: buildXvTheme(XvPalette.dark),
          home: Scaffold(
            // 真实界面里由 XvShell 监听状态；这里单独渲染卡片，因此要自己接上，
            // 否则点了开关界面不会重建。
            body: AnimatedBuilder(
              animation: state,
              builder: (BuildContext context, Widget? _) =>
                  SingleChildScrollView(
                    child: AppPresetCard(state: state, compact: false),
                  ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('直连白名单'), findsOneWidget);
      // 默认启用的国内站点补充与默认关闭的境外应用，两者状态必须能区分。
      expect(find.byKey(const ValueKey<String>('app-preset-switch-cursor')), findsOneWidget);
      expect(find.text('未启用'), findsWidgets);
      // 例外必须摆给用户看，否则它们走隧道时会被当成判错。
      expect(find.textContaining('api5.cursor.sh'), findsWidgets);

      await tester.tap(
        find.byKey(const ValueKey<String>('app-preset-switch-cursor')),
      );
      await tester.pumpAndSettle();

      expect(
        state.enabledAppPresets,
        contains(AppPresets.cursor.id),
      );
      expect(find.text('已启用'), findsWidgets);
    });
  });
}
