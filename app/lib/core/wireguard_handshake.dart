/// WireGuard 握手的可见状态。
///
/// 为什么值得单独做一层：抓「连不上」的原因时，握手是**唯一能区分病因**的证据，
/// 而它此前只存在于内核日志的原始行里。一次真实排查的转折点就是这行——
///
/// ```
/// endpoint/wireguard[vpn]: peer(Tm4p…x2Qd) - received handshake response
/// ```
///
/// 上面这行里的对端标识是**合成示例**，不是任何真实服务器。凡是会进版本库的
/// 日志片段、密钥、域名，一律用假值——真实调试现场抄来的东西很容易把用户自己
/// 的节点信息带出去，见 CONTRIBUTING.md 的「不要把真实会话数据写进代码」。
///
/// 它一出现就能确定「密钥、UDP 通路、服务端都对，问题在别处」；反之若始终停在
/// 「已发出、无应答」，就说明客户端发出的握手根本没被受理（对端公钥不对、
/// 服务端没配这个 peer、或 UDP 被挡）。而这两类原因**处置方式完全相反**，
/// 用户却都只看到「连不上」。
///
/// 这一层刻意与 sing-box 的措辞解耦：解析集中在这里，内核改了输出文案只会
/// 让状态停在「未知」，而不会把错误结论显示给用户。
library;

/// 握手阶段。
enum HandshakePhase {
  /// 还没从日志里认出任何握手信息。
  ///
  /// 包含两种情况：还没开始连接，或者连接的协议不是 WireGuard。界面据此不显示
  /// 这一行——而不是显示一个「未知」状态让用户去猜。
  unknown,

  /// 已发出握手请求，正在等对端应答。
  awaitingResponse,

  /// 单向通了：发出了请求，也收到了应答。
  ///
  /// 它**不等于隧道已经可用**——数据面还可能在别处断掉，因此措辞上只描述握手。
  responded,

  /// 反复重试仍无应答。
  ///
  /// 这是最有价值的一种：密钥不对、服务端没配这个 peer、UDP 被挡，都会落到
  /// 这里，而它们与「服务端通了但数据面有问题」的处置方式相反。
  noResponse,
}

/// 一次握手的观测结果。
class WireGuardHandshake {
  const WireGuardHandshake({
    required this.phase,
    this.attempts = 0,
    this.peerPublicKey,
  });

  /// 未观测到任何握手信息。
  static const WireGuardHandshake unknown = WireGuardHandshake(
    phase: HandshakePhase.unknown,
  );

  final HandshakePhase phase;

  /// 观测到的最大重试序号。内核的措辞是 `retrying (try N)`。
  final int attempts;

  /// 对端公钥的短标识（形如 `Tm4p…x2Qd`，示例值）。
  ///
  /// 只留短标识：完整公钥是标识信息而非秘密，但在界面上没有意义，而一份配置
  /// 里可能有多个 peer 需要区分。
  final String? peerPublicKey;

  bool get isKnown => phase != HandshakePhase.unknown;

  /// 面向用户的一句话结论。刻意不提「密钥」「peer」这类术语——
  /// 用户能做的动作是核对服务端配置或换节点，而不是去读 WireGuard 文档。
  String get summary => switch (phase) {
    HandshakePhase.unknown => '未获取到握手状态',
    HandshakePhase.awaitingResponse => '已发出握手请求，等待服务端应答',
    HandshakePhase.responded => '握手已完成，服务端已应答',
    HandshakePhase.noResponse =>
      '握手请求发出 ${attempts > 0 ? '$attempts 次' : '多次'}均无应答，'
          '服务端可能未受理本客户端',
  };

  @override
  String toString() =>
      'WireGuardHandshake(${phase.name}, attempts: $attempts, peer: $peerPublicKey)';
}

/// 从内核日志行里解析握手状态。
///
/// [previous] 是当前已知状态；返回 null 表示这一行与握手无关，调用方保持原状。
/// 做成纯函数是为了让「内核换一种措辞之后我们还认不认」这件事能被直接测到，
/// 而不是只在真机上碰运气。
WireGuardHandshake? parseWireGuardHandshake(
  String line, {
  WireGuardHandshake previous = WireGuardHandshake.unknown,
}) {
  // 只认 WireGuard 端点自己写的行。`endpoint/wireguard[vpn]:` 是内核的固定前缀；
  // 用 `[^\]]+` 而不是写死 `vpn`，因为标签名由配置决定。
  final endpoint = RegExp(r'endpoint/wireguard\[([^\]]+)\]:').firstMatch(line);
  if (endpoint == null) return null;

  // peer(Tm4p…x2Qd) - <正文>
  final peer = RegExp(r'peer\(([^)]+)\)\s*-\s*(.+)$').firstMatch(line);
  final peerId = peer?.group(1);
  final body = (peer?.group(2) ?? line).trim();

  // 命中重试：累计次数，并保持在「无应答」阶段。
  // 必须先于「sending handshake initiation」判断——重试那一行同时包含两者，
  // 顺序反了的话次数会永远停在 1，用户看到的是「只试了一次」。
  final retry = RegExp(
    r'handshake did not complete after \d+ seconds, retrying \(try (\d+)\)',
  ).firstMatch(body);
  if (retry != null) {
    final attempt = int.tryParse(retry.group(1)!) ?? previous.attempts;
    return WireGuardHandshake(
      phase: HandshakePhase.noResponse,
      attempts: attempt > previous.attempts ? attempt : previous.attempts,
      peerPublicKey: peerId ?? previous.peerPublicKey,
    );
  }

  // 收到应答：单向通了。这是判断「密钥/服务端配置是否成立」的关键一行。
  if (body.contains('received handshake response')) {
    return WireGuardHandshake(
      phase: HandshakePhase.responded,
      attempts: previous.attempts,
      peerPublicKey: peerId ?? previous.peerPublicKey,
    );
  }

  // 只是在发握手请求：还没到能下结论的时候。若此前已经收到过应答，
  // **不**把它降级回「等待应答」——会话重协商时内核会再次发请求，
  // 而「曾经应答过」正是用户需要知道的事实。
  if (body.contains('sending handshake initiation')) {
    if (previous.phase == HandshakePhase.responded) return previous;
    return WireGuardHandshake(
      phase: HandshakePhase.awaitingResponse,
      attempts: previous.attempts,
      peerPublicKey: peerId ?? previous.peerPublicKey,
    );
  }

  return null;
}
