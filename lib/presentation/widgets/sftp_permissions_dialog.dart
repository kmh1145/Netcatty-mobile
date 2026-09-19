import 'package:flutter/material.dart';
import '../../infrastructure/ssh/sftp_service.dart';
import '../localization/localized_widgets.dart';

class SftpPermissionsDialog extends StatefulWidget {
  const SftpPermissionsDialog(
      {super.key, required this.name, required this.initialMode});
  final String name;
  final String initialMode;
  @override
  State<SftpPermissionsDialog> createState() => _SftpPermissionsDialogState();
}

class _SftpPermissionsDialogState extends State<SftpPermissionsDialog> {
  final _form = GlobalKey<FormState>();
  late final _controller = TextEditingController(text: widget.initialMode);
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = localized('修改文件权限');
    return AlertDialog(
      title: Text('$title：${widget.name}'),
      content: SingleChildScrollView(
          child: Form(
              key: _form,
              child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextFormField(
                      key: const ValueKey('sftp-permissions-input'),
                      controller: _controller,
                      autofocus: true,
                      keyboardType: TextInputType.number,
                      maxLength: 4,
                      decoration: LInputDecoration(
                          labelText: 'Unix 权限',
                          hintText: '例如 644 或 0755',
                          errorMaxLines: 3),
                      validator: (value) =>
                          parseUnixPermissions(value ?? '') == null
                              ? localized('请输入 3 或 4 位八进制权限（0-7）')
                              : null,
                    ),
                    const SizedBox(height: 8),
                    LText(
                      '依次表示所有者、用户组和其他用户的读写执行权限',
                      key: const ValueKey('sftp-permissions-help'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ]))),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context), child: const LText('取消')),
        FilledButton(
            onPressed: () {
              if (_form.currentState?.validate() == true) {
                Navigator.pop(context, parseUnixPermissions(_controller.text));
              }
            },
            child: const LText('应用')),
      ],
    );
  }
}
