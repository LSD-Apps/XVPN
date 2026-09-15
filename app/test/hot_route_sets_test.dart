import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/auto_route.dart';
import 'package:xvpn/core/outbound_tags.dart';
import 'package:xvpn/core/route_rule_set_host.dart';
import 'package:xvpn/core/route_rule_sets.dart';
import 'package:xvpn/core/singbox_config.dart';
import 'package:xvpn/models.dart';
import 'package:xvpn/protocols/protocol_adapter.dart';

import 'support/host_platform.dart';

/// 热更新规则集：把「当前分流决策」以内核能反复拉取的规则集形式投递。
///
/// 这套机制要解决的问题是**决策与执行的时间差**：内联路由规则写在 config.json 里，
/// 内核拿着那份配置一直跑，不重连就不读新规则——于是程序刚学到的纠正、用户刚做的
/// 改判在本次会话里都不生效。
///
/// 因此这里既断言「配置长什么样」，也用**随包分发的真实内核**跑一遍「改判之后
/// 运行中的决策真的跟着变」。后者是这套机制的根据：只要内核的刷新行为变了，它就会
/// 失败，而不是等用户发现「界面说已纠正、网站照样打不开」。
const _hysteria2Link =
    'hysteria2://testpassword@hy2.example.net:443/?sni=hy2.example.net'
    '&insecure=1#test';

void main() {
  group('规则集文档', () {
    test('四份恒齐全且带 version —— 缺 version 内核会拒绝启动', () {
      final docs = routeRuleSetDocs(AutoRouteTable());
      expect(docs.keys.toSet(), AutoRouteRuleSetTags.all.toSet());
      for (final doc in docs.values) {
        // 实测：缺 `version` 时报 `missing rule-set version` 并拒绝启动。
        expect(doc['version'], 3);
        // 空集合产出空 rules，内核接受（实测），语义也正确：什么都不匹配。
        expect(doc['rules'], isEmpty);
      }
    });

    test('来源与走向各归各的一份，不会串味', () {
      final table = AutoRouteTable();
      table.setUserRule('manual.example.com', RoutePreference.forceProxy);
      table.setUserRule('local.example.com', RoutePreference.forceDirect);

      final docs = routeRuleSetDocs(table);
      expect(
        _domains(docs[AutoRouteRuleSetTags.userProxy]!),
        contains('manual.example.com'),
      );
      expect(
        _domains(docs[AutoRouteRuleSetTags.userDirect]!),
        contains('local.example.com'),
      );
      // 用户规则不能落进「程序学到」那两份：位置不同（一个能覆盖内网直连、
      // 一个不能），放错就不再是同一种语义。
      expect(_domains(docs[AutoRouteRuleSetTags.autoProxy]!), isEmpty);
      expect(_domains(docs[AutoRouteRuleSetTags.autoDirect]!), isEmpty);
    });

    test('同时下发精确域与后缀域', () {
      final table = AutoRouteTable()
        ..setUserRule('a.example.com', RoutePreference.forceDirect);
      final doc = routeRuleSetDocs(table)[AutoRouteRuleSetTags.userDirect]!;
      final rule = (doc['rules']! as List<Object?>).single as Map<String, Object?>;
      // sing-box 的 `domain` 是精确匹配，只下发它会让 www.a.example.com 漏掉。
      expect(rule['domain'], <String>['a.example.com']);
      expect(rule['domain_suffix'], <String>['a.example.com']);
    });

    test('文档与内联规则同源：改一处不会只改一边', () {
      // 这条锁的是一个很容易发生的分叉：两种投递方式各写一份分组逻辑，
      // 于是「界面显示的走向」与「内核执行的走向」不一致，且极难归因。
      final table = AutoRouteTable()
        ..setUserRule('x.example.com', RoutePreference.forceProxy)
        ..setUserRule('y.example.com', RoutePreference.forceDirect);

      final forms = table.domainMatchForms();
      final docs = routeRuleSetDocs(table);
      expect(_exact(docs[AutoRouteRuleSetTags.userProxy]!), forms.userProxy.exact);
      expect(_exact(docs[AutoRouteRuleSetTags.userDirect]!), forms.userDirect.exact);

      final inline = table.buildRouteRules().userRules;
      expect(
        inline.any(
          (Map<String, Object?> r) =>
              (r['domain'] as List<Object?>?)?.contains('x.example.com') ?? false,
        ),
        isTrue,
      );
      expect(
        inline.any(
          (Map<String, Object?> r) =>
              (r['domain'] as List<Object?>?)?.contains('y.example.com') ?? false,
        ),
        isTrue,
      );
    });

    test('接入点不齐等于没接入', () {
      const full = RouteRuleSetRefs(
        urls: <String, String>{
          AutoRouteRuleSetTags.userProxy: 'http://127.0.0.1:1/a',
          AutoRouteRuleSetTags.userDirect: 'http://127.0.0.1:1/b',
          AutoRouteRuleSetTags.autoProxy: 'http://127.0.0.1:1/c',
          AutoRouteRuleSetTags.autoDirect: 'http://127.0.0.1:1/d',
        },
      );
      expect(full.isComplete, isTrue);
      // 路由规则会引用全部四个标签，少一个内核就拒绝启动——因此「不齐」必须
      // 被当成「不可用」，而不是「能用几份算几份」。
      expect(
        RouteRuleSetRefs(
          urls: <String, String>{
            AutoRouteRuleSetTags.userProxy: 'http://127.0.0.1:1/a',
          },
        ).isComplete,
        isFalse,
      );
    });
  });

  group('配置生成：热更新投递', () {
    final profile = VpnProtocolFactory.parse(_hysteria2Link, 'test.yaml');

    RouteRuleSetRefs refsFor(int port) => RouteRuleSetRefs(
      urls: <String, String>{
        for (final tag in AutoRouteRuleSetTags.all)
          tag: 'http://127.0.0.1:$port/$tag.json',
      },
      updateInterval: const Duration(seconds: 5),
    );

    Map<String, Object?> build({
      required SplitMode mode,
      RouteRuleSetRefs? hot,
      AutoRouteTable? table,
    }) {
      return SingBoxConfigBuilder.build(
        profile: profile,
        splitMode: mode,
        ruleSetDir: 'rulesets',
        autoRoute: table ?? (AutoRouteTable()..setUserRule('u.example.com', RoutePreference.forceProxy)),
        ruleSets: SingBoxConfigBuilder.defaultRuleSets,
        hotRouteSets: hot,
      );
    }

    List<Map<String, Object?>> rulesOf(Map<String, Object?> config) =>
        ((config['route']! as Map<String, Object?>)['rules']! as List<Object?>)
            .cast<Map<String, Object?>>();

    test('四份 remote 规则集 + 显式 HTTP 客户端 + 引用规则', () {
      final config = build(mode: SplitMode.smart, hot: refsFor(12345));

      // HTTP 客户端必须显式声明：不声明会退回「隐式默认客户端」，那条路径
      // 在 1.14.0 已弃用、1.16.0 移除；用旧的 download_detour 同样是弃用路径。
      // detour 固定 direct，且 direct 必须是「非空出站」——见下面的 check 用例。
      expect(
        config['http_clients'],
        <Object?>[
          <String, Object?>{
            'tag': AutoRouteRuleSetTags.httpClient,
            'detour': OutboundTags.direct,
          },
        ],
      );

      final defs = ((config['route']! as Map<String, Object?>)['rule_set']!
              as List<Object?>)
          .cast<Map<String, Object?>>();
      final remote = defs
          .where((Map<String, Object?> d) => d['type'] == 'remote')
          .toList(growable: false);
      expect(remote.length, AutoRouteRuleSetTags.all.length);
      for (final tag in AutoRouteRuleSetTags.all) {
        final def = remote.firstWhere((Map<String, Object?> d) => d['tag'] == tag);
        expect(def['format'], 'source');
        expect(def['url'], 'http://127.0.0.1:12345/$tag.json');
        expect(def['update_interval'], '5s');
        expect(def['http_client'], AutoRouteRuleSetTags.httpClient);
      }
      // 内联规则库仍在。
      expect(
        defs.any((Map<String, Object?> d) => d['type'] == 'local'),
        isTrue,
      );
    });

    test('走向与位置：用户段早于内网直连，学到段晚于它', () {
      final config = build(mode: SplitMode.smart, hot: refsFor(1));
      final rules = rulesOf(config);
      int indexOfTag(String tag) => rules.indexWhere(
        (Map<String, Object?> r) => (r['rule_set'] as List<Object?>?)?.contains(tag) ?? false,
      );
      final private = rules.indexWhere(
        (Map<String, Object?> r) => r['ip_is_private'] == true,
      );
      final library = rules.indexWhere(
        (Map<String, Object?> r) =>
            (r['rule_set'] as List<Object?>?)?.contains('geosite-cn') ?? false,
      );

      expect(private, greaterThan(0));
      expect(indexOfTag(AutoRouteRuleSetTags.userProxy), lessThan(private));
      expect(indexOfTag(AutoRouteRuleSetTags.userDirect), lessThan(private));
      expect(indexOfTag(AutoRouteRuleSetTags.autoProxy), greaterThan(private));
      expect(indexOfTag(AutoRouteRuleSetTags.autoDirect), greaterThan(private));
      // 学到段仍必须早于规则库，否则「直连失败→走隧道」的域名会被规则库
      // 先判成直连。
      expect(indexOfTag(AutoRouteRuleSetTags.autoProxy), lessThan(library));

      // 走向由引用它的规则决定（规则集本身不携带 outbound）。
      expect(rules[indexOfTag(AutoRouteRuleSetTags.userProxy)]['outbound'], OutboundTags.vpn);
      expect(rules[indexOfTag(AutoRouteRuleSetTags.userDirect)]['outbound'], OutboundTags.direct);
    });

    test('热更新生效时不再下发内联域名规则', () {
      final table = AutoRouteTable()
        ..setUserRule('u.example.com', RoutePreference.forceProxy);
      final hot = build(mode: SplitMode.smart, hot: refsFor(1), table: table);
      final inline = build(mode: SplitMode.smart, hot: null, table: table);

      bool hasDomainRule(Map<String, Object?> config) => rulesOf(config).any(
        (Map<String, Object?> r) => r.containsKey('domain') || r.containsKey('domain_suffix'),
      );

      // 内联方式（改造前的行为）确实带域名规则。
      expect(hasDomainRule(inline), isTrue);
      // 两处都下发会让人分不清哪个在起作用，而且内联那份永远落后。
      expect(hasDomainRule(hot), isFalse);
    });

    test('DNS 决策跟着走：引用同一批规则集，不再用内联清单', () {
      final table = AutoRouteTable()
        ..setUserRule('d.example.com', RoutePreference.forceDirect);
      final config = build(mode: SplitMode.smart, hot: refsFor(1), table: table);
      final dnsRules = ((config['dns']! as Map<String, Object?>)['rules']! as List<Object?>)
          .cast<Map<String, Object?>>();

      // 该直连的域名要走国内解析器；该走隧道的要走隧道解析器。两者都必须与
      // 路由决策同源，否则会重新制造「判定对了、结果仍错」。
      expect(
        dnsRules.any(
          (Map<String, Object?> r) =>
              r['server'] == 'dns-cn' &&
              ((r['rule_set'] as List<Object?>?) ?? const <Object?>[]).contains(
                AutoRouteRuleSetTags.userDirect,
              ),
        ),
        isTrue,
      );
      expect(
        dnsRules.any(
          (Map<String, Object?> r) =>
              r['server'] == 'dns-remote' &&
              ((r['rule_set'] as List<Object?>?) ?? const <Object?>[]).contains(
                AutoRouteRuleSetTags.userProxy,
              ),
        ),
        isTrue,
      );
      // 内联清单不该再出现（否则它与规则集内容会各说各话）。
      expect(dnsRules.any((Map<String, Object?> r) => r.containsKey('domain')), isFalse);
    });

    test('接入点不齐就退回内联规则，而不是引用未定义的规则集', () {
      // 路由规则会引用全部四个标签。少了任何一个，内核都会因「引用了未定义的
      // rule_set」拒绝启动——那是「连不上」，不是「某条规则不生效」。
      final partial = RouteRuleSetRefs(
        urls: <String, String>{
          AutoRouteRuleSetTags.userProxy: 'http://127.0.0.1:1/a',
        },
      );
      final config = build(mode: SplitMode.smart, hot: partial);
      final rules = rulesOf(config);
      expect(
        rules.any(
          (Map<String, Object?> r) =>
              (r['rule_set'] as List<Object?>?)?.contains(
                AutoRouteRuleSetTags.userProxy,
              ) ??
              false,
        ),
        isFalse,
      );
      expect(config.containsKey('http_clients'), isFalse);
      // 退回内联：改造前的行为，域名规则仍在。
      expect(
        rules.any(
          (Map<String, Object?> r) =>
              r.containsKey('domain') || r.containsKey('domain_suffix'),
        ),
        isTrue,
      );
    });

    test('全局代理 / 全局直连不注入规则集', () {
      for (final mode in <SplitMode>[
        SplitMode.globalProxy,
        SplitMode.globalDirect,
      ]) {
        final config = build(mode: mode, hot: refsFor(1));
        expect(config.containsKey('http_clients'), isFalse, reason: mode.name);
        final defs = ((config['route']! as Map<String, Object?>)['rule_set']!
                as List<Object?>)
            .cast<Map<String, Object?>>();
        expect(
          defs.any((Map<String, Object?> d) => d['type'] == 'remote'),
          isFalse,
          reason: '${mode.name} 是用户显式要求忽略分流，注入规则会破坏这个承诺',
        );
      }
    });
  });

  group('本机规则集服务', () {
    test('四份地址齐全，且取到的内容随表变化', () async {
      final table = AutoRouteTable();
      final host = AutoRouteRuleSetHost(table);
      final refs = await host.start(updateInterval: const Duration(seconds: 1));
      addTearDown(host.stop);
      expect(refs, isNotNull, reason: '回环端口都绑不上，说明环境有问题');
      expect(refs!.isComplete, isTrue);

      final url = refs.urlOf(AutoRouteRuleSetTags.userDirect)!;
      expect(await _fetchDomains(url), isEmpty);

      // 同一个地址，第二次取到的内容已经变了——这正是热生效的来源：
      // 内核不需要重建配置，只要在下一次刷新时拿到新内容。
      table.setUserRule('later.example.com', RoutePreference.forceDirect);
      expect(await _fetchDomains(url), contains('later.example.com'));
    });

    test('只回应四个已知标签，其余一律 404', () async {
      final host = AutoRouteRuleSetHost(AutoRouteTable());
      final refs = await host.start();
      addTearDown(host.stop);
      final base = Uri.parse(refs!.urlOf(AutoRouteRuleSetTags.userProxy)!);

      for (final path in <String>['/nope.json', '/xvpn-unknown.json', '/../etc/passwd']) {
        final status = await _statusOf(base.replace(path: path));
        expect(status, 404, reason: path);
      }
    });

    test('重复启动幂等：地址不变', () async {
      final host = AutoRouteRuleSetHost(AutoRouteTable());
      final first = await host.start();
      addTearDown(host.stop);
      final second = await host.start();
      expect(second!.urls, first!.urls);
      expect(host.isRunning, isTrue);
    });

    test('停掉之后不再提供服务', () async {
      final host = AutoRouteRuleSetHost(AutoRouteTable());
      final refs = await host.start();
      final url = refs!.urlOf(AutoRouteRuleSetTags.autoProxy)!;
      expect(await _fetchDomains(url), isEmpty);

      await host.stop();
      expect(host.isRunning, isFalse);
      expect(host.refs, isNull);
      await expectLater(_fetchDomains(url), throwsA(anything));
    });
  });

  group('真实内核', () {
    final exe = hostCoreBinary;
    final rulesets = Directory('assets/rulesets');
    final skipReason = !exe.existsSync()
        ? '未找到 ${exe.path}，跳过内核校验'
        : (!rulesets.existsSync() ? '未找到规则集目录，跳过内核校验' : null);

    test('带热更新规则集的完整配置能通过 sing-box check', () async {
      final host = AutoRouteRuleSetHost(AutoRouteTable());
      final refs = await host.start();
      addTearDown(host.stop);
      final config = SingBoxConfigBuilder.build(
        profile: VpnProtocolFactory.parse(_hysteria2Link, 'test.yaml'),
        splitMode: SplitMode.smart,
        ruleSetDir: rulesets.absolute.path,
        autoRoute: AutoRouteTable()
          ..setUserRule('u.example.com', RoutePreference.forceProxy)
          ..setUserRule('d.example.com', RoutePreference.forceDirect),
        ruleSets: SingBoxConfigBuilder.defaultRuleSets,
        hotRouteSets: refs,
      );
      final file = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}xvpn-hot-check.json',
      );
      addTearDown(() {
        if (file.existsSync()) file.deleteSync();
      });
      // 不带 BOM 的 UTF-8：带 BOM 时内核报 invalid character 'ï'。
      file.writeAsStringSync(SingBoxConfigBuilder.encode(config));

      final result = await Process.run(exe.absolute.path, <String>[
        'check',
        '-c',
        file.path,
      ]);
      expect(
        result.exitCode,
        0,
        reason:
            '内核拒绝了这份配置，用户会看到「连不上」：\n'
            '${result.stdout}${result.stderr}',
      );
    }, skip: skipReason);

    test('改判之后运行中的内核跟着变 —— 不需要重启，也不需要重连', () async {
      // 这条是整套机制的根据：配置生成得再对，只要内核不刷新，学到的规则就
      // 只在「下一次连接」生效，而用户此刻正开着那个打不开的网页。
      final table = AutoRouteTable();
      final host = AutoRouteRuleSetHost(table);
      final refs = await host.start(updateInterval: const Duration(milliseconds: 500));
      addTearDown(host.stop);

      // 一个可达的目标：用来区分「走了直连」与「被规则拦下」。
      final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => target.close(force: true));
      target.listen((HttpRequest r) async {
        r.response.write('ok');
        await r.response.close();
      });

      final mixedPort = await _freePort();
      final configFile = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}xvpn-hot-live.json',
      );
      addTearDown(() {
        if (configFile.existsSync()) configFile.deleteSync();
      });
      configFile.writeAsStringSync(
        SingBoxConfigBuilder.encode(_hotLiveConfig(refs!, mixedPort)),
      );

      final core = await Process.start(exe.absolute.path, <String>[
        'run',
        '-c',
        configFile.path,
      ]);
      final logs = StringBuffer();
      core.stdout.transform(utf8.decoder).listen(logs.write);
      core.stderr.transform(utf8.decoder).listen(logs.write);
      addTearDown(() => core.kill(ProcessSignal.sigkill));

      await _waitUntil(
        () async =>
            await _proxyStatus(mixedPort, 'hot.example.com', target.port) == 200,
      );

      // 基线：域名不在任何规则集里，靠 `ip_is_private` 走直连，所以能通。
      expect(
        await _proxyStatus(mixedPort, 'hot.example.com', target.port),
        200,
        reason: '基线应当走直连到达本地目标：\n$logs',
      );

      // 走**真实的学习路径**把「判为直连却失败」变成一条走隧道的规则。
      for (var i = 0; i < 5; i++) {
        table.recordDirectFailure('hot.example.com', reason: '连接超时');
      }
      expect(
        table.domainMatchForms().autoProxy.exact,
        contains('hot.example.com'),
        reason: '阈值没达成，这条用例就不是在测它想测的东西',
      );

      // 字段本身变了还不够，要的是**运行中的内核**跟上。
      await _waitUntil(
        () async =>
            await _proxyStatus(mixedPort, 'hot.example.com', target.port) == 502,
      );
      expect(
        await _proxyStatus(mixedPort, 'hot.example.com', target.port),
        502,
        reason:
            '内核没有按 update_interval 刷新规则集——学到的规则只在下次连接'
            '生效，而用户此刻正打不开那个站点：\n$logs',
      );
    }, skip: skipReason, timeout: const Timeout(Duration(seconds: 120)));

    test('反方向纠正：学成直连后，运行中的内核把该目标从拦下改成放行', () async {
      final table = AutoRouteTable();
      final host = AutoRouteRuleSetHost(table);
      final refs = await host.start(updateInterval: const Duration(milliseconds: 500));
      addTearDown(host.stop);

      final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => target.close(force: true));
      target.listen((HttpRequest r) async {
        r.response.write('ok');
        await r.response.close();
      });

      final mixedPort = await _freePort();
      final configFile = File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}xvpn-hot-direct.json',
      );
      addTearDown(() {
        if (configFile.existsSync()) configFile.deleteSync();
      });
      configFile.writeAsStringSync(
        SingBoxConfigBuilder.encode(
          _hotLiveConfig(refs!, mixedPort, unmatchedBlocked: true),
        ),
      );

      final core = await Process.start(exe.absolute.path, <String>[
        'run',
        '-c',
        configFile.path,
      ]);
      final logs = StringBuffer();
      core.stdout.transform(utf8.decoder).listen(logs.write);
      core.stderr.transform(utf8.decoder).listen(logs.write);
      addTearDown(() => core.kill(ProcessSignal.sigkill));

      await _waitUntil(
        () async =>
            await _proxyStatus(mixedPort, 'cn-longtail.example', target.port) ==
            502,
      );
      expect(
        await _proxyStatus(mixedPort, 'cn-longtail.example', target.port),
        502,
        reason: '基线应走 final=block：\n$logs',
      );

      expect(table.recordDomesticAnswer('cn-longtail.example').added, isFalse);
      expect(table.recordDomesticAnswer('cn-longtail.example').added, isTrue);
      expect(
        table.match('cn-longtail.example')?.preference,
        RoutePreference.forceDirect,
      );

      await _waitUntil(
        () async =>
            await _proxyStatus(mixedPort, 'cn-longtail.example', target.port) ==
            200,
      );
      expect(
        await _proxyStatus(mixedPort, 'cn-longtail.example', target.port),
        200,
        reason: '学成直连后内核应放行到本地目标，无需重连：\n$logs',
      );
    }, skip: skipReason, timeout: const Timeout(Duration(seconds: 120)));
  });
}

/// 运行期的热生效验证配置。
///
/// 刻意做到最小：只保留「域名规则集决定走向」这条链，把隧道端点换成必然失败的
/// `block` 出站，这样「命中规则集」与「没命中」有**确定性**的不同结果——命中被拦
/// （502），没命中落到 `ip_is_private` 走直连（200）。真隧道是连不上的，靠超时去
/// 区分会让这条用例又慢又不稳。
Map<String, Object?> _hotLiveConfig(
  RouteRuleSetRefs refs,
  int mixedPort, {
  bool unmatchedBlocked = false,
}) {
  return <String, Object?>{
    'log': <String, Object?>{'level': 'error'},
    // direct 出站必须带 domain_resolver，否则它是「空出站」，
    // http_clients 的 detour=direct 会被拒绝（实测报错）。
    'dns': <String, Object?>{
      'servers': <Object?>[
        <String, Object?>{
          'type': 'udp',
          'tag': 'dns-local',
          'server': '223.5.5.5',
          'detour': OutboundTags.direct,
        },
      ],
    },
    'inbounds': <Object?>[
      <String, Object?>{
        'type': 'mixed',
        'tag': 'mixed-in',
        'listen': '127.0.0.1',
        'listen_port': mixedPort,
      },
    ],
    'outbounds': <Object?>[
      <String, Object?>{
        'type': 'direct',
        'tag': OutboundTags.direct,
        'domain_resolver': <String, Object?>{'server': 'dns-local'},
      },
      <String, Object?>{'type': 'block', 'tag': 'blocked'},
    ],
    'http_clients': <Object?>[
      <String, Object?>{
        'tag': AutoRouteRuleSetTags.httpClient,
        'detour': OutboundTags.direct,
      },
    ],
    'route': <String, Object?>{
      'rule_set': <Object?>[
        for (final tag in AutoRouteRuleSetTags.all)
          <String, Object?>{
            'type': 'remote',
            'tag': tag,
            'format': 'source',
            'url': refs.urlOf(tag),
            'update_interval': '500ms',
            'http_client': AutoRouteRuleSetTags.httpClient,
          },
      ],
      'rules': <Object?>[
        <String, Object?>{'action': 'sniff'},
        <String, Object?>{
          'rule_set': <String>[
            AutoRouteRuleSetTags.userProxy,
            AutoRouteRuleSetTags.autoProxy,
          ],
          'outbound': 'blocked',
        },
        <String, Object?>{
          'rule_set': <String>[
            AutoRouteRuleSetTags.userDirect,
            AutoRouteRuleSetTags.autoDirect,
          ],
          'outbound': OutboundTags.direct,
        },
        if (!unmatchedBlocked)
          <String, Object?>{
            'ip_is_private': true,
            'outbound': OutboundTags.direct,
          },
      ],
      'final': unmatchedBlocked ? 'blocked' : OutboundTags.direct,
    },
  };
}

/// 一份文档里的全部域名（精确 + 后缀，去重）。
List<String> _domains(Map<String, Object?> doc) {
  final result = <String>[];
  for (final rule in (doc['rules']! as List<Object?>).cast<Map<String, Object?>>()) {
    for (final key in <String>['domain', 'domain_suffix']) {
      for (final value in (rule[key] as List<Object?>?) ?? const <Object?>[]) {
        if (!result.contains(value)) result.add(value! as String);
      }
    }
  }
  return result;
}

/// 一份文档里的精确域清单。
List<String> _exact(Map<String, Object?> doc) {
  final rules = (doc['rules']! as List<Object?>).cast<Map<String, Object?>>();
  if (rules.isEmpty) return const <String>[];
  return ((rules.first['domain'] as List<Object?>?) ?? const <Object?>[])
      .cast<String>();
}

Future<List<String>> _fetchDomains(String url) async {
  final client = HttpClient();
  try {
    final response = await (await client.getUrl(Uri.parse(url))).close();
    expect(response.statusCode, 200);
    final body = await response.transform(utf8.decoder).join();
    final decoded = jsonDecode(body) as Map<String, Object?>;
    return _domains(decoded);
  } finally {
    client.close(force: true);
  }
}

Future<int> _statusOf(Uri uri) async {
  final client = HttpClient();
  try {
    final response = await (await client.getUrl(uri)).close();
    await response.drain<void>();
    return response.statusCode;
  } finally {
    client.close(force: true);
  }
}

/// 经本机混合入站请求一个目标，返回状态码。
///
/// 手写 HTTP 代理请求而不是用 `HttpClient`：需要把 `Host` 改成被测域名，好让内核
/// 的 sniff 认出域名并按域名规则判定。超过超时返回 -1。
Future<int> _proxyStatus(int proxyPort, String host, int targetPort) async {
  Socket? socket;
  try {
    socket = await Socket.connect(
      '127.0.0.1',
      proxyPort,
      timeout: const Duration(seconds: 2),
    );
    socket.write(
      'GET http://127.0.0.1:$targetPort/ HTTP/1.1\r\n'
      'Host: $host\r\n'
      'Connection: close\r\n\r\n',
    );
    await socket.flush();
    final bytes = <int>[];
    final done = Completer<void>();
    socket.listen(
      bytes.addAll,
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      onError: (Object _) {
        if (!done.isCompleted) done.complete();
      },
    );
    await done.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {},
    );
    final text = utf8.decode(bytes, allowMalformed: true);
    final match = RegExp(r'^HTTP/1\.[01] (\d{3})').firstMatch(text);
    return int.tryParse(match?.group(1) ?? '') ?? -1;
  } on Object {
    return -1;
  } finally {
    socket?.destroy();
  }
}

Future<void> _waitUntil(
  Future<bool> Function() condition, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (await condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
}

Future<int> _freePort() async {
  final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = probe.port;
  await probe.close();
  return port;
}
