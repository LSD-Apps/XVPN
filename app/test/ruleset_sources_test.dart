import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/app_state.dart';
import 'package:xvpn/core/rulesets.dart';
import 'package:xvpn/core/singbox_runner.dart';
import 'package:xvpn/core/store.dart';
import 'package:xvpn/core/vpn_core.dart';

/// 规则集清单的**结构**约束。
///
/// 这一组用例锁定的是几件「一旦出错就会静默」的事：
///   * 声明了内置条目、磁盘上却没有对应文件 → 界面上有个拨了没反应的开关；
///   * 把构建期产物当成可下载的条目 → 用户点「检查更新」会拿到一份配置文本，
///     被魔数拒绝，而报错指向他的网络；
///   * 推荐规则集的名称非法或与内置重名 → 用户点「添加」必然失败。
void main() {
  group('内置规则集与磁盘产物一致', () {
    /// 构建期产出的内置条目（没有可下载地址的那些）。
    Iterable<BuiltinRuleSet> extras() =>
        RuleSetStore.builtins.where((BuiltinRuleSet b) => !b.updatable);

    test('构建期产物的每个文件都真的在 assets 里且是合法 .srs', () {
      // 这是「界面上的开关能不能兑现」的底线：ensure() 找不到出厂副本时会
      // 静默跳过，界面上条目照样显示、开关照样能拨，实际什么都没发生。
      final dir = Directory('assets/rulesets');
      expect(dir.existsSync(), isTrue, reason: '规则集目录不存在，测试的工作目录不对');

      for (final entry in extras()) {
        final file = File('${dir.path}${Platform.pathSeparator}${entry.fileName}');
        expect(
          file.existsSync(),
          isTrue,
          reason: '声明了 ${entry.fileName} 却没有这个文件——请先跑 '
              'scripts/build-cn-domain-ruleset.ps1',
        );
        final head = file.readAsBytesSync().take(3).toList();
        expect(
          head,
          RuleSetStore.srsMagic,
          reason: '${entry.fileName} 不是 .srs（魔数不对），内核会拒绝加载',
        );
      }
    });

    test('构建期产物标成不可更新，且默认启用有实测依据', () {
      expect(
        extras().map((BuiltinRuleSet b) => b.name).toSet(),
        <String>{'geosite-cn-extra'},
        reason: '新增构建期产物时要同步这条断言与其默认值的实测依据',
      );
      for (final entry in extras()) {
        expect(
          RuleSetStore.defaultEntries()
              .firstWhere((RuleSetEntry e) => e.name == entry.name)
              .updatable,
          isFalse,
          reason: '${entry.name} 的来源不是 .srs 地址，不能走「检查更新」',
        );
        expect(
          entry.enabledByDefault,
          isTrue,
          // 实测：召回 40/40，误命中约 150 个境外域名中 0 个。
          // 若将来实测数据变差，改这里并同步 docs/RULES.md 与 script 自检。
          reason: '${entry.name} 的默认值必须由实测支撑，不能随手取',
        );
      }
    });

    test('域名类标记只给真正是域名的规则集', () {
      // 这一项决定规则集能否参与 DNS 直连分流。标错了不会报错，只会表现为
      // 「判定该直连的域名仍被境外解析器解析」。
      expect(
        RuleSetStore.isDomainRuleSetName('geosite-cn'),
        isTrue,
      );
      expect(
        RuleSetStore.isDomainRuleSetName('geosite-cn-extra'),
        isTrue,
        reason: '它是域名类；漏标会让被它判为直连的域名经隧道解析',
      );
      expect(
        RuleSetStore.isDomainRuleSetName('geoip-cn'),
        isFalse,
        reason: 'geoip-cn 是 IP 类，写进 DNS 规则没有意义',
      );
      expect(
        RuleSetStore.isDomainRuleSetName('some-custom'),
        isFalse,
        reason: '自定义规则集的类型无从得知，不猜',
      );
    });

    test('可更新的内置条目都有 http(s) 地址', () {
      for (final entry in RuleSetStore.defaultEntries()
          .where((RuleSetEntry e) => e.updatable)) {
        expect(
          entry.url,
          startsWith('https://'),
          reason: '${entry.name} 声明可更新，地址却不是 http(s)——点检查更新必然失败',
        );
      }
    });

    test('不可更新的条目不会让「检查更新」去下载它', () async {
      final dir = Directory.systemTemp.createTempSync('xvpn-ruleset-updatable');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      // 必须用真实内核：演示内核不维护可更新的规则库，会在更早一步就返回
      // 「当前内核不维护可更新的规则库」，测不到这条分支。
      final state = AppState(
        store: AppStore(dir),
        coreFactory: (VpnCoreListener l) => SingBoxRunner(
          l,
          probesEnabled: false,
          runtimeOverride: CoreRuntime(
            singBoxExe: File('${dir.path}${Platform.pathSeparator}sing-box'),
            ruleSetDir: dir,
            assetDir: dir,
            workDir: dir,
          ),
        ),
      );
      addTearDown(state.dispose);

      // 只启用构建期产物，其余全部停用。
      for (final entry in state.ruleSets) {
        state.setRuleSetEnabled(entry.name, !entry.updatable);
      }
      await state.refreshRuleSet();

      expect(
        state.lastError,
        isNotNull,
        reason: '全都是不可更新的条目时必须如实说明，而不是静默什么都不做',
      );
      expect(
        state.lastError,
        contains('构建脚本'),
        reason: '要告诉用户正确的刷新方式（重跑构建脚本），而不是让他查网络',
      );
    });
  });

  group('推荐规则集', () {
    test('建议名称合法、不重名，且地址是 http(s)', () {
      expect(RuleSetStore.suggested, isNotEmpty);
      final builtinNames = RuleSetStore.defaultEntries()
          .map((RuleSetEntry e) => e.name)
          .toSet();
      for (final suggestion in RuleSetStore.suggested) {
        expect(
          RuleSetEntry.isValidName(suggestion.name),
          isTrue,
          reason: '「${suggestion.name}」不合法，用户点添加必然失败',
        );
        expect(
          builtinNames.contains(suggestion.name),
          isFalse,
          reason: '「${suggestion.name}」与内置重名，添加会被拒绝',
        );
        expect(suggestion.url, startsWith('https://'));
        expect(
          suggestion.note,
          isNotEmpty,
          reason: '许可与收录标准必须写清楚，由用户自行判断要不要用',
        );
      }
    });

    test('建议名称互不重复', () {
      final names = RuleSetStore.suggested
          .map((SuggestedRuleSet s) => s.name)
          .toList();
      expect(names.toSet(), hasLength(names.length));
    });
  });
}
