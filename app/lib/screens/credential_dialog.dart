import 'package:flutter/material.dart';

import '../theme.dart';
import '../widgets/common.dart';

/// 一次填写的账号密码。
typedef Credentials = ({String username, String password});

/// 弹出账号密码表单。用户取消时返回 null。
///
/// 存在的理由：OpenVPN 的 `auth-user-pass` 配置必须带服务端分配的账号密码才能
/// 连上，而这两项**不在配置文件里**。此前解析器会直接报「请在导入时填写」，
/// 但整个应用没有任何地方能填——于是这一整类配置导入即失败。
///
/// [storageNote] 由调用方给出「这份密码会怎么存」，直接取自当前平台的
/// [SecretProtector.description]。让用户知道密码是被加密还是明文落盘，
/// 而不是含糊带过。
Future<Credentials?> showCredentialDialog(
  BuildContext context, {
  required String fileName,
  required String storageNote,
  String? initialUsername,
  String? initialPassword,
}) {
  return showDialog<Credentials>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.6),
    builder: (BuildContext dialogContext) => _CredentialForm(
      fileName: fileName,
      storageNote: storageNote,
      initialUsername: initialUsername,
      initialPassword: initialPassword,
    ),
  );
}

/// 表单本体。
///
/// 做成 StatefulWidget 而不是在 [showCredentialDialog] 里就地建控制器并
/// `finally { dispose() }`：`showDialog` 的 Future 在**退场动画还没播完**时就
/// 已经返回，那一刻释放控制器会让动画里的 TextField 用到已释放的对象并抛
/// 「A TextEditingController was used after being disposed」。
/// 交给 [State.dispose]，时机才是对的。
class _CredentialForm extends StatefulWidget {
  const _CredentialForm({
    required this.fileName,
    required this.storageNote,
    this.initialUsername,
    this.initialPassword,
  });

  final String fileName;
  final String storageNote;
  final String? initialUsername;
  final String? initialPassword;

  @override
  State<_CredentialForm> createState() => _CredentialFormState();
}

class _CredentialFormState extends State<_CredentialForm> {
  late final TextEditingController _username = TextEditingController(
    text: widget.initialUsername ?? '',
  );
  late final TextEditingController _password = TextEditingController(
    text: widget.initialPassword ?? '',
  );
  String? _error;
  bool _obscured = true;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    final username = _username.text.trim();
    final password = _password.text;
    if (username.isEmpty) {
      setState(() => _error = '请填写用户名');
      return;
    }
    if (password.isEmpty) {
      setState(() => _error = '请填写密码');
      return;
    }
    Navigator.of(context).pop((username: username, password: password));
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
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  '这份配置需要账号密码',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: XV.text,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '「${widget.fileName}」声明了 auth-user-pass，用户名与密码由服务端分配，'
                  '不在配置文件里。填一次即可，之后连这份配置会一直使用。',
                  style: XvText.caption,
                ),
                const SizedBox(height: 16),
                _Field(
                  label: '用户名',
                  controller: _username,
                  hasError: _error != null,
                  onSubmitted: (_) => _submit(),
                ),
                const SizedBox(height: 10),
                _Field(
                  label: '密码',
                  controller: _password,
                  hasError: _error != null,
                  obscure: _obscured,
                  onSubmitted: (_) => _submit(),
                  trailing: IconButton(
                    tooltip: _obscured ? '显示密码' : '隐藏密码',
                    icon: Icon(
                      _obscured
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                      size: 18,
                      color: XV.muted,
                    ),
                    onPressed: () => setState(() => _obscured = !_obscured),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 36,
                      minHeight: 36,
                    ),
                    visualDensity: VisualDensity.compact,
                    splashRadius: 18,
                  ),
                ),
                if (_error != null) ...<Widget>[
                  const SizedBox(height: 10),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Icon(Icons.error_outline, size: 14, color: XV.redSoft),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _error!,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: XV.redSoft,
                            height: 1.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(Icons.lock_outline, size: 13, color: XV.muted2),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        widget.storageNote,
                        style: TextStyle(
                          fontSize: 11,
                          color: XV.muted2,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: <Widget>[
                    XvButton(
                      label: '稍后填写',
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    const SizedBox(width: 8),
                    XvButton(
                      label: '保存',
                      kind: XvButtonKind.primary,
                      onPressed: _submit,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 一行输入框。描边与其它弹窗保持一致，出错时整行变红。
class _Field extends StatelessWidget {
  const _Field({
    required this.label,
    required this.controller,
    required this.hasError,
    this.obscure = false,
    this.trailing,
    this.onSubmitted,
  });

  final String label;
  final TextEditingController controller;
  final bool hasError;
  final bool obscure;
  final Widget? trailing;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(label, style: TextStyle(fontSize: 11.5, color: XV.muted2)),
        const SizedBox(height: 5),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: XV.field,
            border: Border.all(
              color: hasError ? XV.red.withValues(alpha: 0.5) : XV.line,
            ),
            borderRadius: BorderRadius.circular(XV.rCtl),
          ),
          child: Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: controller,
                  obscureText: obscure,
                  onSubmitted: onSubmitted,
                  style: TextStyle(fontSize: 12.5, color: XV.text),
                  decoration: const InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(vertical: 6),
                  ),
                ),
              ),
              // 显示/隐藏密码：右侧眼睛图标（盲打时核对用）。
              ?trailing,
            ],
          ),
        ),
      ],
    );
  }
}
