import 'package:flutter/material.dart';
import '../localization/localized_widgets.dart';

class GitHubManualConfig extends StatelessWidget {
  const GitHubManualConfig(
      {super.key,
      required this.resourceId,
      required this.secret,
      required this.onSecretChanged});
  final TextEditingController resourceId;
  final TextEditingController secret;
  final ValueChanged<String> onSecretChanged;

  @override
  Widget build(BuildContext context) => ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(top: 18, bottom: 12),
        title: const LText('高级 / 手动配置'),
        subtitle: const LText('仅用于迁移或登录故障排查'),
        children: [
          TextField(
              controller: resourceId,
              decoration: LInputDecoration(labelText: 'Gist ID（通常自动识别）')),
          const SizedBox(height: 20),
          TextField(
              controller: secret,
              obscureText: true,
              onChanged: onSecretChanged,
              decoration: LInputDecoration(labelText: 'GitHub Token（备用）')),
        ],
      );
}
