import 'package:flutter_test/flutter_test.dart';
import 'package:xvpn/core/wireguard_handshake.dart';

/// 这一组的语料全部来自**真实内核输出**（sing-box 1.14.0 连真实 WireGuard
/// 节点时抓的），不是照文档编的。理由很直接：这个解析器的唯一价值就是「认得出
/// 内核实际写的那句话」，用编出来的语料测等于没测。
void main() {
  group('从真实内核日志行解析握手状态', () {
    test('发出握手请求：进入等待应答', () {
      final state = parseWireGuardHandshake(
        '+0800 2026-09-11 22:18:03 DEBUG endpoint/wireguard[vpn]: '
        'peer(Qk9y…7tZa) - sending handshake initiation',
      );

      expect(state, isNotNull);
      expect(state!.phase, HandshakePhase.awaitingResponse);
      expect(state.peerPublicKey, 'Qk9y…7tZa');
      expect(state.summary, contains('等待服务端应答'));
    });

    test('收到应答：这是判断密钥与通路成立的关键一行', () {
      final state = parseWireGuardHandshake(
        '+0800 2026-09-11 22:18:09 DEBUG endpoint/wireguard[vpn]: '
        'peer(Qk9y…7tZa) - received handshake response',
      );

      expect(state!.phase, HandshakePhase.responded);
      expect(state.isKnown, isTrue);
      expect(state.summary, contains('握手已完成'));
    });

    test('重试：累计次数并停在无应答', () {
      // 内核原文是 `retrying (try 2)`，这一行同时包含「sending handshake
      // initiation」，因此判定顺序必须让重试优先。
      final state = parseWireGuardHandshake(
        '+0800 2026-09-11 22:18:08 DEBUG endpoint/wireguard[vpn]: '
        'peer(Tm4p…x2Qd) - handshake did not complete after 5 seconds, retrying (try 2)',
      );

      expect(state!.phase, HandshakePhase.noResponse);
      expect(state.attempts, 2);
      expect(state.summary, contains('2 次'));
    });

    test('重试次数只增不减：后面续上的那次不能把次数改小', () {
      var state = parseWireGuardHandshake(
        'DEBUG endpoint/wireguard[vpn]: peer(a) - '
        'handshake did not complete after 5 seconds, retrying (try 3)',
      );
      // 会话重新协商时内核又从 try 2 开始计，用户看到的次数不该倒退。
      state = parseWireGuardHandshake(
        'DEBUG endpoint/wireguard[vpn]: peer(a) - '
        'handshake did not complete after 5 seconds, retrying (try 2)',
        previous: state!,
      );

      expect(state!.attempts, 3);
    });

    test('收到应答后不再被后续的重新发起降级', () {
      // 会话重协商时内核会再次 `sending handshake initiation`，
      //「曾经应答过」正是用户需要知道的事实，不能被冲掉。
      final responded = parseWireGuardHandshake(
        'DEBUG endpoint/wireguard[vpn]: peer(a) - received handshake response',
      );
      final again = parseWireGuardHandshake(
        'DEBUG endpoint/wireguard[vpn]: peer(a) - sending handshake initiation',
        previous: responded!,
      );

      expect(again!.phase, HandshakePhase.responded);
    });

    test('端点标签跟随配置，不写死 vpn', () {
      final state = parseWireGuardHandshake(
        'DEBUG endpoint/wireguard[my-node]: peer(x) - received handshake response',
      );

      expect(state!.phase, HandshakePhase.responded);
    });

    test('与握手无关的行返回 null，调用方保持原状', () {
      for (final line in <String>[
        '+0800 2026-09-11 22:18:03 INFO inbound/mixed[mixed-in]: tcp server started at 127.0.0.1:12080',
        '+0800 2026-09-11 22:18:03 DEBUG endpoint/wireguard[vpn]: routine: encryption worker 1 - started',
        '+0800 2026-09-11 22:18:03 DEBUG endpoint/wireguard[vpn]: peer(a) - sending keepalive packet',
        '+0800 2026-09-11 22:18:03 INFO outbound/direct[direct]: outbound packet connection to 223.5.5.5:53',
        // 别的协议也有 endpoint 前缀，不能当成 WireGuard 握手。
        'DEBUG endpoint/openvpn-client[ovpn]: peer(a) - sending handshake initiation',
      ]) {
        expect(
          parseWireGuardHandshake(line),
          isNull,
          reason: '这一行与握手无关，不该产出状态：$line',
        );
      }
    });

    test('未知状态不显示结论，靠 isKnown 让界面闭嘴', () {
      const unknown = WireGuardHandshake.unknown;

      expect(unknown.isKnown, isFalse);
      expect(unknown.phase, HandshakePhase.unknown);
    });
  });
}
