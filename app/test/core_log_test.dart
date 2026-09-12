import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/core_log.dart';

/// 真实的 sing-box 日志行（带 ANSI 色码与时间戳前缀），
/// 取自实际调试过程中的输出。
const _directTimeout =
    '+0800 2026-09-10 21:16:19 \u001b[31mERROR\u001b[0m [4081391031 4.97s] '
    'connection: open connection to www.qq.com:443 using outbound/direct[direct]: '
    'lookup www.qq.com: (exchange4: context deadline exceeded | exchange6: context deadline exceeded)';

const _directDialTimeout =
    '+0800 2026-09-10 21:13:33 \u001b[31mERROR\u001b[0m [2052270269 5.0s] '
    'connection: open connection to 183.2.172.177:80 using outbound/direct[direct]: '
    'dial tcp 183.2.172.177:80: i/o timeout';

const _proxyTimeout =
    '+0800 2026-09-10 21:14:59 \u001b[31mERROR\u001b[0m [2784999641 10.1s] '
    'connection: open connection to www.youtube.com:443 using outbound/wireguard[vpn]: '
    'lookup www.youtube.com: (exchange6: context deadline exceeded | exchange4: context deadline exceeded)';

const _ipv6Missing =
    'ERROR [1079344440 10.0s] connection: open connection to www.youtube.com:443 '
    'using outbound/wireguard[vpn]: missing IPv6 local address';

const _endpointResolve =
    'ERROR endpoint/wireguard[vpn]: peer(95je...) - failed to resolve endpoints: '
    'lookup vpn.example.net: (exchange6: context deadline exceeded)';

const _infoLine =
    '+0800 2026-09-10 21:14:59 \u001b[36mINFO\u001b[0m [2784999641 0ms] '
    'inbound/mixed[mixed-in]: inbound connection to www.baidu.com:80';

void main() {
  group('parseConnectionFailure', () {
    test('解析直连失败，并识别出走的哪个出站', () {
      final f = parseConnectionFailure(_directTimeout)!;
      expect(f.target, 'www.qq.com:443');
      expect(f.host, 'www.qq.com');
      expect(f.outbound, 'direct');
      expect(f.wasDirect, isTrue);
      expect(f.reasonSummary, '解析或握手超时');
    });

    test('解析隧道失败', () {
      final f = parseConnectionFailure(_proxyTimeout)!;
      expect(f.outbound, 'vpn');
      expect(f.wasProxied, isTrue);
      expect(f.wasDirect, isFalse);
    });

    test('识别 i/o timeout 与 IPv6 缺失等具体原因', () {
      expect(parseConnectionFailure(_directDialTimeout)!.reasonSummary, '连接超时');
      expect(
        parseConnectionFailure(_ipv6Missing)!.reasonSummary,
        '隧道缺少 IPv6 地址',
      );
    });

    test('解析隧道端点自身解析失败（此时连接还没建立）', () {
      final f = parseConnectionFailure(_endpointResolve)!;
      expect(f.target, '(隧道端点)');
      expect(f.outbound, 'vpn');
      expect(f.reason, contains('vpn.example.net'));
    });

    test('忽略 INFO 级别的正常连接记录', () {
      expect(parseConnectionFailure(_infoLine), isNull);
    });

    test('忽略无关文本', () {
      expect(parseConnectionFailure('sing-box started (0.05s)'), isNull);
      expect(parseConnectionFailure(''), isNull);
    });
  });

  group('suggestsMissingRule 的判断', () {
    test('域名走直连却失败 → 疑似规则未覆盖', () {
      expect(
        parseConnectionFailure(_directTimeout)!.suggestsMissingRule,
        isTrue,
      );
    });

    test('IP 走直连失败 → 不归咎于规则（域名规则管不到 IP）', () {
      final f = parseConnectionFailure(_directDialTimeout)!;
      expect(f.isIpTarget, isTrue);
      expect(f.suggestsMissingRule, isFalse);
    });

    test('走隧道失败 → 是节点问题，与规则无关', () {
      expect(
        parseConnectionFailure(_proxyTimeout)!.suggestsMissingRule,
        isFalse,
      );
      expect(
        parseConnectionFailure(_ipv6Missing)!.suggestsMissingRule,
        isFalse,
      );
    });

    test('域名解析失败不归咎于分流规则', () {
      const line =
          'ERROR [1 1s] connection: open connection to a.example.com:443 '
          'using outbound/direct[direct]: lookup a.example.com: no such host';
      final f = parseConnectionFailure(line)!;
      expect(f.reasonSummary, '域名解析失败');
      expect(f.suggestsMissingRule, isFalse);
    });
  });

  group('digestFailures', () {
    test('空列表给出空摘要与正常结论', () {
      final d = digestFailures(<ConnectionFailure>[]);
      expect(d.total, 0);
      expect(d.hasProblems, isFalse);
      expect(d.advice, '暂未发现异常连接');
    });

    test('区分「规则疑似漏判」与「节点不通」', () {
      final failures = <ConnectionFailure>[
        parseConnectionFailure(_directTimeout)!, // 域名直连失败 → 疑似漏判
        parseConnectionFailure(_proxyTimeout)!, // 隧道失败 → 节点问题
        parseConnectionFailure(_directDialTimeout)!, // IP 直连失败 → 与规则无关
      ];
      final d = digestFailures(failures);
      expect(d.total, 3);
      expect(d.directFailures, 2);
      expect(d.proxiedFailures, 1);
      expect(d.suspectedMissingRules, <String>['www.qq.com']);
      expect(d.advice, contains('规则库未覆盖'));
    });

    test('只有隧道失败时明确指出是节点问题', () {
      final d = digestFailures(<ConnectionFailure>[
        parseConnectionFailure(_proxyTimeout)!,
      ]);
      expect(d.suspectedMissingRules, isEmpty);
      expect(d.advice, contains('节点'));
    });

    test('同一域名多次失败只记一次', () {
      final d = digestFailures(<ConnectionFailure>[
        parseConnectionFailure(_directTimeout)!,
        parseConnectionFailure(_directTimeout)!,
      ]);
      expect(d.suspectedMissingRules, <String>['www.qq.com']);
      expect(d.total, 2);
    });
  });
}
