/// 本机回环上的规则集服务：内核按 `update_interval` 从这里拉取当前分流决策。
///
/// 服务的每个请求都**当场**从 [AutoRouteTable] 生成文档，因此「内核下一次拉取
/// 看到的内容」恒等于「界面此刻显示的决策」。这正是热生效的来源：程序学到一条
/// 规则后，不需要重建配置、更不需要断开重连，内核在下一个间隔就会拿到它。
///
/// 为什么必须在启动内核**之前**就绪并自检：实测（sing-box 1.14.0）里**首次**
/// 拉取失败会让内核直接起不来——`start service: initialize rule-set: initial
/// rule-set: ... connection refused`，而这正是这套机制唯一的严重故障形态。所以
/// [start] 绑定端口后会先自己请求一遍全部四份文档，确认真的响应了才交出去。
/// 任何一步失败都返回 null，调用方退回内联规则：**热生效没了，连接照旧**。
///
/// 关于暴露面：服务只监听回环地址（不是 `anyIPv4`），且只回应四个已知标签，
/// 其余路径一律 404。内容是本机已学到的域名走向，不含凭据；能读它的本机进程
/// 同样能读应用私有目录里的存档，因此没有引入新的暴露面。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'auto_route.dart';
import 'route_rule_sets.dart';

class AutoRouteRuleSetHost {
  AutoRouteRuleSetHost(this._table);

  final AutoRouteTable _table;

  HttpServer? _server;
  RouteRuleSetRefs? _refs;

  /// 当前可用的接入点；未启动或启动失败时为 null。
  RouteRuleSetRefs? get refs => _refs;

  /// 是否正在提供服务。
  bool get isRunning => _server != null;

  /// 绑定回环端口并自检。失败返回 null，调用方退回内联规则。
  ///
  /// 幂等：已在服务时直接返回现有接入点，不重新绑定。
  Future<RouteRuleSetRefs?> start({
    Duration updateInterval = RouteRuleSetRefs.defaultUpdateInterval,
  }) async {
    final existing = _refs;
    if (existing != null) return existing;

    HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    } on Object {
      // 拿不到回环端口（极少见）。这不是连接失败，只是热生效不可用。
      return null;
    }
    _server = server;
    server.listen(
      (HttpRequest request) => unawaited(_handle(request)),
      onError: (Object _) {
        // 单个连接出错不该拖垮服务；内核下次拉取会重试。
      },
    );

    final refs = RouteRuleSetRefs(
      urls: <String, String>{
        for (final tag in AutoRouteRuleSetTags.all)
          tag: 'http://127.0.0.1:${server.port}/$tag.json',
      },
      updateInterval: updateInterval,
    );
    if (!await _verify(refs)) {
      await stop();
      return null;
    }
    _refs = refs;
    return refs;
  }

  /// 关闭服务。可重复调用。
  Future<void> stop() async {
    final server = _server;
    _server = null;
    _refs = null;
    if (server == null) return;
    try {
      await server.close(force: true);
    } on Object {
      // 关闭失败不影响后续：端口会随进程退出释放。
    }
  }

  /// 自检：四份文档都要能取到且是合法 JSON。
  ///
  /// 之所以逐份检查而不是只看端口是否监听：内核会引用**全部四个**标签，缺一个
  /// 就会因「引用了未定义的 rule_set」拒绝启动。把这件事在这里判掉，比让内核
  /// 起不来再回退要便宜得多。
  Future<bool> _verify(RouteRuleSetRefs refs) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 3);
    try {
      for (final tag in AutoRouteRuleSetTags.all) {
        final url = refs.urlOf(tag);
        if (url == null) return false;
        final request = await client.getUrl(Uri.parse(url));
        final response = await request.close().timeout(
          const Duration(seconds: 3),
        );
        if (response.statusCode != HttpStatus.ok) return false;
        final body = await response.transform(utf8.decoder).join();
        final decoded = jsonDecode(body);
        if (decoded is! Map) return false;
      }
      return true;
    } on Object {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final tag = _tagOf(request.uri.path);
    final docs = tag == null ? null : routeRuleSetDocs(_table);
    final doc = docs == null ? null : docs[tag];
    if (doc == null) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    request.response.headers.contentType = ContentType('application', 'json');
    request.response.write(jsonEncode(doc));
    await request.response.close();
  }

  /// `/xvpn-user-proxy.json` → `xvpn-user-proxy`；未知名返回 null。
  static String? _tagOf(String path) {
    if (!path.startsWith('/') || !path.endsWith('.json')) return null;
    final tag = path.substring(1, path.length - '.json'.length);
    return AutoRouteRuleSetTags.all.contains(tag) ? tag : null;
  }
}
