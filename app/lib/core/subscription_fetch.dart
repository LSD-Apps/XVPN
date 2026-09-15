/// 拉取用户自己填写的订阅 URL。
///
/// 不内置任何地址。失败必须变成可读的中文，不能把 HTTP 异常原文甩到界面上。
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../protocols/parsed_profile.dart';
import '../protocols/subscription.dart';

const int subscriptionMaxBytes = 2 * 1024 * 1024;

Future<SubscriptionFetchResult> fetchSubscription(String url) async {
  if (!looksLikeSubscriptionUrl(url)) {
    throw VpnConfigException('这不是 http(s) 订阅地址');
  }
  final uri = Uri.parse(url.trim());
  try {
    final response = await http
        .get(uri, headers: const <String, String>{'User-Agent': 'XVPN'})
        .timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) {
      throw VpnConfigException('订阅地址返回 HTTP ${response.statusCode}');
    }
    if (response.bodyBytes.length > subscriptionMaxBytes) {
      throw VpnConfigException('订阅正文超过 2 MB，拒绝导入');
    }
    final body = utf8.decode(response.bodyBytes, allowMalformed: true);
    if (body.trim().isEmpty) {
      throw VpnConfigException('订阅地址返回了空内容');
    }
    return SubscriptionFetchResult(
      body: body,
      userinfo: response.headers['subscription-userinfo'],
    );
  } on VpnConfigException {
    rethrow;
  } on Object {
    throw VpnConfigException('无法拉取订阅，请检查网络与地址');
  }
}
