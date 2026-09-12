import 'dart:io';

/// 本地端口分配。
///
/// 存在的理由是一个很常见、但错误信息完全看不懂的失败：
///
/// 混合入站固定监听 2080、Clash API 固定监听 2081。只要这两个端口被占着
/// ——上一次被强杀后残留的内核、另一个 VPN 客户端、用户自己的某个开发服务
/// ——内核就会启动失败，而用户看到的是一句 curl 风格的
/// 「bind: Only one usage of each socket address is normally permitted」，
/// 接着是「内核启动超时」。他既不知道是端口冲突，也不知道该改什么。
///
/// 现在改成：默认端口被占就在后面找第一个可用的。用户什么都不用做。
///
/// 关于可靠性边界要说清楚：这里只是**探测**，绑得上就立刻释放，随后内核再去绑。
/// 两步之间理论上可能被别的进程抢走。这一层不追求绝对，只把「本来一定会失败」
/// 变成「绝大多数情况下自己就好了」；真被抢走时仍然走原来的超时报错路径。
class PortAllocator {
  const PortAllocator._();

  /// 探测时最多往后找多少个端口。
  ///
  /// 连续 50 个端口都被占，说明这台机器上的端口使用方式已经不正常了，
  /// 继续找下去只是把失败推迟，不如快点报错。
  static const int defaultSearchLimit = 50;

  /// 从 [from] 开始找 [count] 个可用的本地回环端口。
  ///
  /// 返回值**可能不等于** [from]：调用方必须使用返回的端口，
  /// 而不是继续假设默认端口可用。返回的各个端口互不相同。
  ///
  /// 一个都凑不齐时返回空列表，由调用方决定怎么报错。
  static Future<List<int>> allocate({
    required int from,
    required int count,
    int searchLimit = defaultSearchLimit,
  }) async {
    final found = <int>[];
    if (count <= 0) return found;
    for (
      var offset = 0;
      offset < searchLimit && found.length < count;
      offset++
    ) {
      final candidate = from + offset;
      if (candidate > 65535) break;
      if (await isAvailable(candidate)) found.add(candidate);
    }
    return found;
  }

  /// 某个本地回环端口现在能不能绑上。
  static Future<bool> isAvailable(int port) async {
    // 0 号端口在系统调用里表示「随便给我一个」，问它「可不可用」没有意义；
    // 越界端口同样不是真实端口。两者都直接判为不可用，免得把它们当成
    // 选中的端口写进配置。
    if (port <= 0 || port > 65535) return false;

    ServerSocket? socket;
    try {
      // 只探回环地址：内核也只监听回环，探 0.0.0.0 会把「别的地址上被占用」
      // 误判成不可用，从而平白换端口。
      socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      return true;
    } on SocketException {
      return false;
    } on Object {
      // 端口越界等其它情况一律按「不可用」处理。
      return false;
    } finally {
      try {
        await socket?.close();
      } on Object {
        // 关不掉无所谓：探测结果已经拿到了。
      }
    }
  }
}
