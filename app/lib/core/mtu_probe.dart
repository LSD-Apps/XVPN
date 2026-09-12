/// MTU 校验：判断配置里写的 MTU 在这个节点上**是否真的能用**。
///
/// 为什么是「校验配置值」而不是「测出链路 MTU」：后者要输出一个数字，而这个
/// 数字受沿途每跳、隧道封装、服务端网卡、TLS 记录分层共同影响。测不准还给出
/// 具体数值，比不说更糟——用户会拿着它去改配置。
///
/// 而真正会致害的场景只有一个，且完全可以判定：**配置的 MTU 比路径实际能过的
/// 大**。它的现象是「小请求一切正常、一传大东西就卡死」，用户与客服都极难
/// 自证，而配置里就有这个数字。
///
/// 判据用「读到的值」与「写出去的值」之间的不对称，这条经验很硬：
///   * 客户端未声明 DF 时，**读**方向的大包会由沿途路由器分片成功，所以「大文件
///     能下载」不能证明 MTU 正确；
///   * **写**方向的大包会被自己这一侧的内核按 MTU 分片后发出，若 MTU 高于路径
///     容量，分片本身仍过大而被丢弃，于是表现为请求发不出去。
///
/// 因此这里刻意只测**上传**方向，且只给出三种结论，不下任何模糊判断。
library;

/// 本次 MTU 校验的结论。
enum MtuVerdict {
  /// 按配置的 MTU 能完整传输：配置可用。
  ok,

  /// 该大小传不过去，但更小的能过去：配置的 MTU 偏大。
  mayBeTooLarge,

  /// 连小请求都过不去：隧道本身不通，**此时不能对 MTU 下任何结论**。
  ///
  /// 这一条是刻意加的。没有它的话，一个纯粹连不上的节点会被报成「MTU 过大」，
  /// 把用户引向一个完全错误的方向。
  inconclusive,

  /// 配置里没有声明 MTU（或该协议不解析它），无从校验。
  notDeclared,
}

/// 一次 MTU 校验的结果。
class MtuCheck {
  const MtuCheck({
    required this.verdict,
    this.declaredMtu,
    this.largestPassingBody,
  });

  const MtuCheck.notDeclared()
    : verdict = MtuVerdict.notDeclared,
      declaredMtu = null,
      largestPassingBody = null;

  final MtuVerdict verdict;

  /// 配置里声明的 MTU。
  final int? declaredMtu;

  /// 实测能完整传过去的最大 HTTP 体大小；没测到任何成功时为 null。
  ///
  /// 它与 MTU 不是同一个量：这是应用层负载，MTU 是链路层单元。把它直接当 MTU
  /// 显示会误导，因此只用于支撑结论，界面文案不暴露这个数字的含义。
  final int? largestPassingBody;

  /// 是否应当标成**需要用户处理**的问题。
  ///
  /// 只有 [MtuVerdict.mayBeTooLarge] 算：那是唯一一个「配置确实有问题、且用户
  /// 能据此改配置」的结论。
  ///
  /// [MtuVerdict.inconclusive] **刻意不算**。它说的是「这次探测没测到结果」——
  /// 可能是丢包、可能是那个探测目标暂时不可达，而**隧道本身是好的**（否则连接
  /// 根本建立不起来）。把它标成警告时，界面会出现自相矛盾的两行：一边说隧道
  /// 正常在跑流量，一边说「隧道当前不通」。用户按它去改 MTU 只会白费功夫。
  bool get isProblem => verdict == MtuVerdict.mayBeTooLarge;

  /// 面向用户的一句话结论。没有声明 MTU 时返回 null，界面据此整块不显示。
  String? get summary => switch (verdict) {
    MtuVerdict.ok => '已按 $declaredMtu 字节的包实测通过，配置可用',
    MtuVerdict.mayBeTooLarge =>
      '配置的 MTU（$declaredMtu 字节）有包传不过去，而更小的包可以；'
          '该值可能偏大，可尝试下调到 1280–1380',
    MtuVerdict.inconclusive => '本次未测到结果，可点「重测」再试一次',
    MtuVerdict.notDeclared => null,
  };
}

/// 判断一次 MTU 校验的结论。纯函数，便于把三种分支都直接测到。
///
/// [declaredMtu] 为 null 表示配置没声明 MTU。
/// [fullPassed] 表示「按声明的 MTU 换算出的负载」是否完整传过去了；
/// [smallPassed] 表示「明显更小的负载」是否传过去了。
MtuCheck evaluateMtuCheck({
  required int? declaredMtu,
  required bool fullPassed,
  required bool smallPassed,
  int? largestPassingBody,
}) {
  if (declaredMtu == null || declaredMtu <= 0) {
    return const MtuCheck.notDeclared();
  }
  if (fullPassed) {
    return MtuCheck(
      verdict: MtuVerdict.ok,
      declaredMtu: declaredMtu,
      largestPassingBody: largestPassingBody,
    );
  }
  // 大包不通、小包能通：才是「MTU 偏大」。顺序不能反——小包也不通时那是
  // 隧道本身不通，把结论指向 MTU 会把人带偏。
  if (smallPassed) {
    return MtuCheck(
      verdict: MtuVerdict.mayBeTooLarge,
      declaredMtu: declaredMtu,
      largestPassingBody: largestPassingBody,
    );
  }
  return MtuCheck(
    verdict: MtuVerdict.inconclusive,
    declaredMtu: declaredMtu,
    largestPassingBody: largestPassingBody,
  );
}

/// 应该拿多大的 HTTP 体去试「按声明的 MTU 能不能过」。
///
/// 取 `MTU - 100`：要留出 IP(20) + TCP(20) + TLS 记录(5) 以及 HTTP 头本身的
/// 开销，同时**不能留太多**——留太多就测不到边界，配置偏大反而会「通过」。
/// 100 字节的余量对 1280–1500 这个区间是够的，也让判定落在保守一侧：
/// 宁可放过一个临界值，也不要对可用配置误报。
int probeBodyForMtu(int mtu) {
  final body = mtu - 100;
  return body < 1 ? 1 : body;
}

/// 对照用的小负载：远小于任何 MTU，能通过只说明「隧道通」。
const int mtuProbeSmallBody = 256;

/// 上传校验用的目标地址。
///
/// 选它有四个具体理由，都是实测出来的：
///   * **按域名访问**而不是写死 IP：这样它会被内置规则判为境外→走隧道，与用户的
///     真实场景一致；
///   * **明文 HTTP**：避免把 TLS 记录分层的额外变量搅进来——要测的是链路能不能
///     承载这么大的包，不是 TLS 栈的行为；
///   * **它明确拒绝 POST（实测返回 405）**：这恰恰是理想结果——请求体必须完整
///     送达才会收到这个应答，而服务端**不会留存任何东西**，也不存在「往第三方
///     站点灌数据」的问题；
///   * **实测可解析、往返约 0.6 秒**：最初选的那个「上传测速」域名在本节点的
///     隧道里**解析不出来**，会让校验永远落在「无法校验」上，等于白做。
const String mtuProbeUrl = 'http://ifconfig.me/';
