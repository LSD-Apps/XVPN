import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/route_learning.dart';

/// 交付速率判据（纯逻辑）。
///
/// 补的是**「能通但很慢」**这个缺口：此前两种判据都是二值的（连接失败、
/// 握手成功但零字节），抓不住「交付了 448 KB 却用了 12 秒」——那在
/// `classifyDirectConnection` 里算「确实交付」。
///
/// 这一组刻意不引入 `auto_route.dart`，因此阈值语义可以逐条直测。
void main() {
  group('RollingMedian：中位数而不是均值', () {
    test('奇数/偶数样本都正确', () {
      final window = RollingMedian();
      expect(window.median, isNull, reason: '空窗口没有中位数');
      window.add(10);
      expect(window.median, 10);
      window.add(30);
      expect(window.median, 20, reason: '偶数样本取中间两个的平均');
      window.add(20);
      expect(window.median, 20);
    });

    test('超出容量后丢最旧的', () {
      final window = RollingMedian(capacity: 3);
      for (final v in <double>[1, 2, 3, 4]) {
        window.add(v);
      }
      expect(window.length, 3);
      expect(window.median, 3, reason: '[2,3,4] 的中位数是 3，最旧的 1 已被丢弃');
    });

    test('一次异常样本不会把中位数带偏（这正是选它的理由）', () {
      final window = RollingMedian();
      for (final v in <double>[1000, 1000, 1000, 1000, 1000]) {
        window.add(v);
      }
      final before = window.median!;
      window.add(5); // 一次极慢的传输
      expect(
        window.median,
        before,
        reason: '均值会被这一次拉低，中位数不会——与 DNS 耗时统计同一条理由',
      );
    });

    test('忽略非有限值与负数', () {
      final window = RollingMedian();
      window.add(double.nan);
      window.add(double.infinity);
      window.add(-1);
      expect(window.isEmpty, isTrue);
    });

    test('clear 清空', () {
      final window = RollingMedian()..add(1);
      window.clear();
      expect(window.isEmpty, isTrue);
    });
  });

  group('LearningPolicy：速率判据的阈值', () {
    test('只需要字节下限：好样本不该被时长滤掉', () {
      const policy = LearningPolicy();
      // 270 字节的响应（实测 raw 的完整文件）由慢启动与往返时延主导，排除。
      expect(policy.isRateSampleMeaningful(270), isFalse);
      // 实测里 github.com 的成功样本应当计入——包括那次 764ms 的快速交付。
      // 一开始我另加了「至少存活 1 秒」，结果正是把这个**好样本**滤掉了，
      // 而它是用来清除偏慢计数的正面证据。测试当场暴露了这个设计错误。
      expect(policy.isRateSampleMeaningful(577137), isTrue);
      expect(policy.isRateSampleMeaningful(policy.minRateSampleBytes), isTrue);
      expect(policy.isRateSampleMeaningful(policy.minRateSampleBytes - 1), isFalse);
    });

    test('速率换算与非法输入', () {
      expect(
        LearningPolicy.bytesPerSecond(1024, const Duration(seconds: 1)),
        1024,
      );
      expect(
        LearningPolicy.bytesPerSecond(1024, Duration.zero),
        isNull,
        reason: '时长为零时速率无意义，不能返回 Infinity',
      );
      expect(LearningPolicy.bytesPerSecond(0, const Duration(seconds: 1)), isNull);
    });
  });

  group('judgeDeliveryRate：偏慢的判定', () {
    const policy = LearningPolicy();
    // 基准 1000 B/s，阈值 1/4 → 低于 250 才算偏慢。
    const link = 1000.0;

    test('基准未建立时不下结论', () {
      expect(
        policy.judgeDeliveryRate(
          domainMedian: 10,
          linkMedian: link,
          linkSamples: policy.minReferenceSamples - 1,
        ),
        RateVerdict.insufficient,
        reason: '拿几个样本当基准，会把「今天恰好没跑过大传输」误判成「所有站点都慢」',
      );
    });

    test('该域名还没有任何样本时不下结论', () {
      expect(
        policy.judgeDeliveryRate(
          domainMedian: null,
          linkMedian: link,
          linkSamples: 20,
        ),
        RateVerdict.insufficient,
      );
    });

    test('判据不管样本个数——那由调用方的连续计数承担', () {
      // 一开始判据里另设了一道「至少 N 个样本」的门槛，结果与连续计数
      // 重复计了一遍「3 次」，实际需要 5 次样本才提升。测试撞出了这个矛盾。
      // 现在判据只回答「这一次看起来偏慢吗」。
      expect(
        policy.judgeDeliveryRate(
          domainMedian: 10,
          linkMedian: link,
          linkSamples: 20,
        ),
        RateVerdict.slow,
        reason: '第一个样本就可以被判为偏慢，是否采纳由连续计数决定',
      );
    });

    test('明确低于阈值 → 偏慢', () {
      expect(
        policy.judgeDeliveryRate(
          domainMedian: 100,
          linkMedian: link,
          linkSamples: 20,
        ),
        RateVerdict.slow,
      );
    });

    test('只是略低 → 不下「偏慢」结论（阈值留了足够间隔）', () {
      // 实测同一次 github.com 的两次成功交付相差 20 倍，因此阈值必须宽。
      expect(
        policy.judgeDeliveryRate(
          domainMedian: 400,
          linkMedian: link,
          linkSamples: 20,
        ),
        RateVerdict.healthy,
      );
    });

    test('恰好落在阈值上不判偏慢（用严格小于）', () {
      expect(
        policy.judgeDeliveryRate(
          domainMedian: link * policy.slowFraction,
          linkMedian: link,
          linkSamples: 20,
        ),
        RateVerdict.healthy,
      );
    });

    test('基准为零时不下结论（避免除以零式的比较）', () {
      expect(
        policy.judgeDeliveryRate(
          domainMedian: 1,
          linkMedian: 0,
          linkSamples: 20,
        ),
        RateVerdict.insufficient,
      );
    });
  });

  group('rateTrialAllowed：冷却防止来回横跳', () {
    const policy = LearningPolicy();
    final t0 = DateTime(2026, 9, 13, 12);

    test('从未试过时允许', () {
      expect(policy.rateTrialAllowed(now: t0, lastTrialAt: null), isTrue);
    });

    test('冷却期内不允许', () {
      expect(
        policy.rateTrialAllowed(
          now: t0.add(policy.rateRetryCooldown - const Duration(minutes: 1)),
          lastTrialAt: t0,
        ),
        isFalse,
        reason: '没有冷却就会「直连慢→上隧道→隧道也慢→回直连→又上隧道」',
      );
    });

    test('冷却期满后允许', () {
      expect(
        policy.rateTrialAllowed(
          now: t0.add(policy.rateRetryCooldown),
          lastTrialAt: t0,
        ),
        isTrue,
      );
    });
  });
}
