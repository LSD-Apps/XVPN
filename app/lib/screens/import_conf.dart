import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../protocols/parsed_profile.dart';
import '../protocols/vpn_protocol.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// 从配置文件导入。三种入口共用同一条解析与校验路径：
///   * [pickAndImportConf] 系统文件选择器（桌面端与移动端）
///   * [importConfFromPath] 桌面端拖拽落下的文件
///   * [startConfPasteDialog] 粘贴文本（兜底，任何环境下都可用）
///
/// 协议由 VpnProtocolFactory 按内容自动识别，因此这里不需要区分
/// WireGuard 的 .conf 与 OpenVPN 的 .ovpn。
///
/// 导入成功后由 [AppState] 决定是否自动连接，界面不需要额外处理。

/// 打开系统文件选择器并导入。
Future<void> pickAndImportConf(BuildContext context, AppState state) async {
  try {
    // Android 的选择器按 MIME 过滤，.conf / .ovpn 常被识别为未知类型从而在
    // 列表里置灰无法选中，因此移动端不加过滤，改由解析器校验内容。
    final List<XTypeGroup> groups = defaultTargetPlatform == TargetPlatform.android
        ? const <XTypeGroup>[]
        : <XTypeGroup>[
            XTypeGroup(
              label: 'VPN 配置',
              // 扩展名取自协议注册表：新增协议后这里自动跟上。
              extensions: allSupportedExtensions,
            ),
          ];
    final XFile? file = await openFile(acceptedTypeGroups: groups);
    if (file == null) return; // 用户取消
    final String text = await file.readAsString();
    state.importConf(text: text, fileName: file.name);
  } on VpnConfigException catch (e) {
    state.reportError(e.message);
  } on Object catch (e) {
    state.reportError('读取配置失败：$e');
  }
}

/// 导入指定路径的 .conf（桌面端拖拽）。
Future<void> importConfFromPath(AppState state, String path) async {
  try {
    // 用 XFile 读取，避免直接依赖 dart:io 的路径处理。
    final XFile file = XFile(path);
    final String text = await file.readAsString();
    state.importConf(text: text, fileName: file.name);
  } on VpnConfigException catch (e) {
    state.reportError(e.message);
  } on Object catch (e) {
    state.reportError('读取文件失败：$e');
  }
}

/// 粘贴 .conf 文本导入。走的是与文件导入完全相同的解析路径。
Future<void> startConfPasteDialog(BuildContext context, AppState state) async {
  final controller = TextEditingController();
  String? error;
  var fileName = 'pasted.conf';

  await showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.6),
    builder: (BuildContext dialogContext) {
      return StatefulBuilder(
        builder: (BuildContext context, void Function(void Function()) setDialogState) {
          void submit() {
            try {
              state.importConf(text: controller.text, fileName: fileName);
              Navigator.of(dialogContext).pop();
            } on VpnConfigException catch (e) {
              // 解析器抛出的是面向用户的中文说明，直接展示。
              setDialogState(() => error = e.message);
            }
          }

          return Dialog(
            backgroundColor: XV.panel,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(XV.rCard),
              side: BorderSide(color: XV.line),
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Text(
                        '粘贴 WireGuard 配置',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: XV.text),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '粘贴 .conf 的全部内容。分流规则已经内置，不需要再填任何东西。',
                        style: XvText.caption,
                      ),
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: XV.field,
                          border: Border.all(
                            color: error == null ? XV.line : XV.red.withValues(alpha: 0.5),
                          ),
                          borderRadius: BorderRadius.circular(XV.rCtl),
                        ),
                        child: TextField(
                          controller: controller,
                          maxLines: 9,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.6,
                            color: XV.text,
                            fontFamilyFallback: XV.monoFallback,
                          ),
                          decoration: InputDecoration(
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(vertical: 8),
                            hintText: '[Interface]\nPrivateKey = ...\nAddress = 10.7.0.2/32\n\n'
                                '[Peer]\nPublicKey = ...\nEndpoint = 1.2.3.4:51820',
                            hintStyle: TextStyle(
                              fontSize: 12,
                              height: 1.6,
                              color: XV.muted2,
                              fontFamilyFallback: XV.monoFallback,
                            ),
                          ),
                        ),
                      ),
                      if (error != null) ...<Widget>[
                        const SizedBox(height: 10),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Icon(Icons.error_outline, size: 14, color: XV.redSoft),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                error!,
                                style: TextStyle(fontSize: 11.5, color: XV.redSoft, height: 1.5),
                              ),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 16),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: TextField(
                              onChanged: (String v) =>
                                  fileName = v.trim().isEmpty ? 'pasted.conf' : v.trim(),
                              style: TextStyle(fontSize: 12.5, color: XV.text),
                              decoration: InputDecoration(
                                isDense: true,
                                border: InputBorder.none,
                                hintText: '配置名称（默认 pasted.conf）',
                                hintStyle: TextStyle(fontSize: 12.5, color: XV.muted2),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          XvButton(
                            label: '取消',
                            onPressed: () => Navigator.of(dialogContext).pop(),
                          ),
                          const SizedBox(width: 8),
                          XvButton(
                            label: '导入',
                            kind: XvButtonKind.primary,
                            onPressed: submit,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      );
    },
  );
  controller.dispose();
}
