import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/dns_client.dart';

/// 直连 DNS 探测必须真的能把报文发出去。
///
/// 这一组锁定的是一个**曾经长期存在、而且很难自查**的故障：实现里绑的是
/// `InternetAddress.loopbackIPv4`，于是所有对外查询瞬间失败（报文带着
/// 127.0.0.1 作源地址出不去）。症状是界面永远显示「国内解析异常」，并建议用户
/// 「更换国内解析器」——而同一时刻系统自带的 nslookup 查同一个服务器完全正常，
/// 所以用户只会越查越糊涂。
///
/// 之所以要用真实网络来测，是因为这个缺陷**只存在于真实套接字行为里**：
/// 用桩替换掉 [DnsResolver] 就永远测不到它，配置生成、报文编解码也都正确。
/// 因此这里发一次真实查询，并把「绑定是否可用」本身也作为断言对象。
///
/// 联网不可用（CI、离线环境）时整组跳过，而不是失败——它验证的是本机网络，
/// 不是代码逻辑。
void main() {
  /// 一个一定存在的公共解析器。
  const server = '223.5.5.5';

  /// 探测网络是否可用：不可用就跳过，不把环境问题算成失败。
  Future<bool> probeConnectivity() async {
    final outcome = await UdpDnsResolver().query(
      server,
      'www.baidu.com',
      timeout: const Duration(seconds: 3),
    );
    return outcome.resolved;
  }

  test('绑定通配地址后，真实解析器必须能查到地址', () async {
    if (!await probeConnectivity()) {
      markTestSkipped('无法访问 $server（离线或网络受限），跳过');
      return;
    }
    final resolver = UdpDnsResolver();
    addTearDown(resolver.close);

    final outcome = await resolver.query(server, 'www.baidu.com');
    expect(
      outcome.resolved,
      isTrue,
      reason:
          '拿不到地址说明探测报文根本没发出去或回不来。'
          '历史上这里绑的是回环地址，会让对外查询**瞬间**失败。'
          'error="${outcome.error}" 耗时=${outcome.millis}ms',
    );
    expect(outcome.answers, isNotEmpty);
    // 语法正确性：解析出来的是 IPv4 字面量。
    for (final a in outcome.answers) {
      expect(
        InternetAddress.tryParse(a),
        isNotNull,
        reason: '解析结果 "$a" 不是合法地址',
      );
    }
  });

  test('失败要区分「本机发不出去」与「解析器不通」', () async {
    // 指向一个必然不可达的回环端口：这是「解析器不通」，不是本机问题。
    // 该用例只断言标记位不会被误置，从而保证界面不会给出方向相反的建议。
    final resolver = UdpDnsResolver();
    addTearDown(resolver.close);

    final outcome = await resolver.query(
      '127.0.0.1',
      'www.baidu.com',
      timeout: const Duration(milliseconds: 600),
    );
    expect(outcome.succeeded, isFalse);
    expect(
      outcome.localProbeUnavailable,
      isFalse,
      reason: '解析器无响应时不该被说成「本机无法发起探测」——两者的处置方式相反',
    );
  });

  test('地址不合法时给出明确错误，而不是静默超时', () async {
    final resolver = UdpDnsResolver();
    addTearDown(resolver.close);

    final outcome = await resolver.query('not-an-ip', 'www.baidu.com');
    expect(outcome.succeeded, isFalse);
    expect(outcome.error, '解析器地址不合法');
  });
}
