import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import '../protocols/parsed_profile.dart';
import '../protocols/protocol_adapter.dart';
import '../protocols/subscription.dart';
import '../protocols/vpn_protocol.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'config_form.dart';
import 'credential_dialog.dart';

/// 从配置文件导入。所有入口共用同一条解析与校验路径：
///   * [pickAndImportConf] 系统文件选择器（桌面端与移动端）
///   * [importConfFromPath] 桌面端拖拽落下的文件
///   * [reviewAndImportConf] 安卓分享 / 启动参数等已有文本的入口
///
/// 这里不再像以前那样「读完文件直接导入」：任何一份配置都要先经过确认表单，
/// 用户可以核对解析结果、补上账号密码、改个名字，确认后才写入。
/// 手填入口 [startManualConfigForm] 走的是同一张表单，只是字段从空开始。
///
/// 协议由 VpnProtocolFactory 按内容自动识别，因此这里不需要区分
/// WireGuard 的 .conf 与 OpenVPN 的 .ovpn。
///
/// 导入成功后由 [AppState] 决定是否自动连接，界面不需要额外处理。

/// 解析文本并打开确认表单。解析失败时直接给出可读的中文错误。
///
/// 返回是否完成了导入（用户在表单里取消时返回 false）。
Future<bool> reviewAndImportConf(
  BuildContext context,
  AppState state, {
  required String text,
  required String fileName,
}) async {
  if (looksLikeSubscriptionUrl(text)) {
    return importSubscriptionUrl(context, state, url: text.trim());
  }
  final bundle = parseSubscriptionBody(text, fallbackName: _stem(fileName));
  if (bundle != null && bundle.nodes.length > 1) {
    try {
      final result = state.importSubscription(
        document: bundle,
        name: _stem(fileName),
      );
      if (context.mounted) await _showImportSummary(context, result);
      return true;
    } on VpnConfigException catch (e) {
      state.reportError(e.message);
      return false;
    }
  }
  final ParsedProfile parsed;
  try {
    parsed = VpnProtocolFactory.parse(text, fileName);
  } on VpnConfigException catch (e) {
    state.reportError(e.message);
    return false;
  } on Object catch (e) {
    state.reportError('导入失败：$e');
    return false;
  }
  if (!context.mounted) return false;
  final result = await showConfigForm(
    context,
    model: ConfigFormModel.fromParsed(parsed, name: fileName),
    fromFile: true,
    storageNote: state.protector.description,
  );
  if (result == null) return false;
  if (!context.mounted) return false;
  return _applyFormResult(context, state, result);
}

/// 手填一份配置：打开同一张表单，协议可选、字段从空开始。
Future<bool> startManualConfigForm(BuildContext context, AppState state) async {
  final result = await showConfigForm(
    context,
    model: ConfigFormModel.empty(importableProtocols.first),
    fromFile: false,
    storageNote: state.protector.description,
  );
  if (result == null) return false;
  if (!context.mounted) return false;
  return _applyFormResult(context, state, result);
}

/// 把表单结果写进 [AppState]，并在配置需要账号密码时弹出补填表单。
Future<bool> _applyFormResult(
  BuildContext context,
  AppState state,
  ConfigFormResult result,
) async {
  final ImportOutcome outcome;
  try {
    outcome = state.importConf(
      text: result.text,
      fileName: result.name,
      username: result.username,
      password: result.password,
    );
  } on VpnConfigException catch (e) {
    state.reportError(e.message);
    return false;
  } on Object catch (e) {
    state.reportError('导入失败：$e');
    return false;
  }

  if (outcome != ImportOutcome.needsCredentials) return true;
  await promptForCredentials(
    context,
    state,
    text: result.text,
    fileName: result.name,
  );
  return true;
}

/// 直接导入并在需要账号密码时弹表单补填（不经过确认表单）。
///
/// 用于没有可用 Navigator、只能勉强导入的兜底路径（见 [importConfDirect]）。
/// 界面入口一律走 [reviewAndImportConf]。
Future<bool> importConfWithPrompt(
  BuildContext context,
  AppState state, {
  required String text,
  required String fileName,
}) async {
  final ImportOutcome outcome;
  try {
    outcome = state.importConf(text: text, fileName: fileName);
  } on VpnConfigException catch (e) {
    state.reportError(e.message);
    return false;
  } on Object catch (e) {
    state.reportError('导入失败：$e');
    return false;
  }

  if (outcome != ImportOutcome.needsCredentials) return true;
  await promptForCredentials(context, state, text: text, fileName: fileName);
  return true;
}

/// 无界面兜底：拿不到 Navigator 时直接导入。
///
/// 需要账号密码时无法补填，但配置本身已经导入成功，
/// 用户之后可以在「配置」页补填——这比因为弹不出表单而整份丢弃要好。
void importConfDirect(
  AppState state, {
  required String text,
  required String fileName,
}) {
  try {
    state.importConf(text: text, fileName: fileName);
  } on VpnConfigException catch (e) {
    state.reportError(e.message);
  } on Object catch (e) {
    state.reportError('导入失败：$e');
  }
}

/// 弹出账号密码表单并保存。配置**必须已经导入成功**之后再调用它。
Future<void> promptForCredentials(
  BuildContext context,
  AppState state, {
  required String text,
  required String fileName,
}) async {
  if (!context.mounted) return;
  // 配置此时已经导入成功了。用户在这里取消，只是暂时连不上，之后可以在
  // 「配置」页补填——因此取消不是错误，也不需要报红。
  final credentials = await showCredentialDialog(
    context,
    fileName: fileName,
    storageNote: '账号密码：${state.protector.description}',
  );
  if (credentials == null) return;
  try {
    state.importConf(
      text: text,
      fileName: fileName,
      username: credentials.username,
      password: credentials.password,
    );
  } on VpnConfigException catch (e) {
    state.reportError(e.message);
  }
}

/// 打开系统文件选择器，解析后进入确认表单。
Future<void> pickAndImportConf(BuildContext context, AppState state) async {
  try {
    // Android 的选择器按 MIME 过滤，.conf / .ovpn 常被识别为未知类型从而在
    // 列表里置灰无法选中，因此移动端不加过滤，改由解析器校验内容。
    final List<XTypeGroup> groups =
        defaultTargetPlatform == TargetPlatform.android
        ? const <XTypeGroup>[]
        : <XTypeGroup>[
            XTypeGroup(
              label: 'VPN 配置',
              // 桌面端只列约定的扩展名（每个扩展名只属于一个协议），
              // 取自协议注册表：新增协议后这里自动跟上。
              extensions: allSupportedExtensions,
            ),
          ];
    final XFile? file = await openFile(acceptedTypeGroups: groups);
    if (file == null) return; // 用户取消
    final String text = await file.readAsString();
    // 读文件是异步的，回来时页面可能已经不在（例如用户切走了路由）。
    if (!context.mounted) return;
    await reviewAndImportConf(context, state, text: text, fileName: file.name);
  } on VpnConfigException catch (e) {
    state.reportError(e.message);
  } on Object catch (e) {
    state.reportError('读取配置失败：$e');
  }
}

/// 导入指定路径的配置文件（桌面端拖拽），同样先进确认表单。
Future<void> importConfFromPath(
  BuildContext context,
  AppState state,
  String path,
) async {
  try {
    // 用 XFile 读取，避免直接依赖 dart:io 的路径处理。
    final XFile file = XFile(path);
    final String text = await file.readAsString();
    if (!context.mounted) return;
    await reviewAndImportConf(context, state, text: text, fileName: file.name);
  } on VpnConfigException catch (e) {
    state.reportError(e.message);
  } on Object catch (e) {
    state.reportError('读取文件失败：$e');
  }
}

String _stem(String fileName) {
  final slash = fileName.replaceAll('\\', '/').split('/').last;
  final dot = slash.lastIndexOf('.');
  if (dot <= 0) return slash;
  return slash.substring(0, dot);
}

/// 第三入口：粘贴用户自己的订阅 URL，或一整段多节点正文。
Future<bool> startSubscriptionImport(BuildContext context, AppState state) async {
  final raw = await showDialog<String>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.6),
    builder: (BuildContext dialogContext) => const _SubscriptionDialog(),
  );
  if (raw == null || raw.trim().isEmpty || !context.mounted) return false;
  final text = raw.trim();
  if (looksLikeSubscriptionUrl(text)) {
    return importSubscriptionUrl(context, state, url: text);
  }
  return reviewAndImportConf(
    context,
    state,
    text: text,
    fileName: 'subscription.txt',
  );
}

Future<bool> importSubscriptionUrl(
  BuildContext context,
  AppState state, {
  required String url,
}) async {
  try {
    final result = await state.importSubscriptionFromUrl(url);
    if (context.mounted) await _showImportSummary(context, result);
    return true;
  } on VpnConfigException catch (e) {
    state.reportError(e.message);
    return false;
  } on Object catch (e) {
    state.reportError('导入订阅失败：$e');
    return false;
  }
}

Future<void> _showImportSummary(
  BuildContext context,
  SubscriptionImportResult result,
) async {
  final skipped = result.skipped;
  await showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.6),
    builder: (BuildContext dialogContext) => Dialog(
      backgroundColor: XV.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(XV.rCard),
        side: BorderSide(color: XV.line),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                '已导入 ${result.imported} 个节点',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: XV.text,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                skipped.isEmpty
                    ? '本软件不提供节点。这些条目来自你粘贴的地址或文件。'
                    : '跳过 ${skipped.length} 个无法识别的条目：\n${skipped.take(8).join('\n')}'
                        '${skipped.length > 8 ? '\n…' : ''}',
                style: XvText.caption,
              ),
              const SizedBox(height: 18),
              Align(
                alignment: Alignment.centerRight,
                child: XvButton(
                  label: '好',
                  kind: XvButtonKind.primary,
                  onPressed: () => Navigator.of(dialogContext).pop(),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _SubscriptionDialog extends StatefulWidget {
  const _SubscriptionDialog();

  @override
  State<_SubscriptionDialog> createState() => _SubscriptionDialogState();
}

class _SubscriptionDialogState extends State<_SubscriptionDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: XV.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(XV.rCard),
        side: BorderSide(color: XV.line),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                '导入自备订阅',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: XV.text,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '只拉取你填写的 http(s) 地址，或解析你粘贴的分享链接列表 / '
                'Clash proxies / sing-box JSON。软件不提供任何订阅。',
                style: XvText.caption,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _controller,
                maxLines: 6,
                style: XvText.body,
                decoration: InputDecoration(
                  hintText: 'https://…  或一次粘贴多条 ss:// / vless://',
                  hintStyle: XvText.caption,
                  filled: true,
                  fillColor: XV.panel2,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: XV.line),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  XvButton(
                    label: '取消',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 10),
                  XvButton(
                    label: '导入',
                    kind: XvButtonKind.primary,
                    onPressed: () =>
                        Navigator.of(context).pop(_controller.text),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
