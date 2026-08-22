import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:netcatty_mobile/presentation/localization/localized_widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../application/vault_controller.dart';
import '../../domain/models/host.dart';

class KeychainSheet extends ConsumerWidget {
  const KeychainSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vault = ref.watch(vaultControllerProvider).data;
    final keys = vault?.keys ?? const <SshKeyProfile>[];
    return SafeArea(
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            onPressed: () => Navigator.pop(context),
            icon: const Icon(Icons.close),
          ),
          title: const LText('SSH 密钥'),
          actions: [
            IconButton(
              onPressed: () => _import(context, ref),
              icon: const Icon(Icons.add),
            ),
          ],
        ),
        body: keys.isEmpty
            ? Center(
                child: FilledButton.icon(
                  onPressed: () => _import(context, ref),
                  icon: const Icon(Icons.key),
                  label: const LText('导入私钥'),
                ),
              )
            : ListView.separated(
                padding: const EdgeInsets.all(12),
                itemCount: keys.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, index) {
                  final key = keys[index];
                  return ListTile(
                    leading: const CircleAvatar(child: Icon(Icons.key)),
                    title: LText(key.label),
                    subtitle: LText(
                      key.data['type']?.toString() ?? 'OpenSSH / PEM',
                    ),
                    trailing: IconButton(
                      onPressed: () async {
                        final controller =
                            ref.read(vaultControllerProvider.notifier);
                        final current = await controller.ready();
                        await controller.replace(
                          current.copyWith(
                            keys: current.keys
                                .where((value) => value.id != key.id)
                                .toList(),
                          ),
                        );
                      },
                      icon: const Icon(Icons.delete_outline),
                    ),
                  );
                },
              ),
      ),
    );
  }

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      withData: true,
    );
    if (result == null) return;
    final file = result.files.single;
    final bytes = file.bytes ?? await File(file.path!).readAsBytes();
    final privateKey = utf8.decode(bytes);
    if (!privateKey.contains('PRIVATE KEY')) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: LText('所选文件不是受支持的私钥')));
      }
      return;
    }
    final label = TextEditingController(text: file.name);
    final passphrase = TextEditingController();
    if (!context.mounted) return;
    final key = await showDialog<SshKeyProfile>(
      context: context,
      builder: (context) => AlertDialog(
        title: const LText('导入 SSH 私钥'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: label,
              decoration: LInputDecoration(labelText: '名称'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: passphrase,
              obscureText: true,
              decoration: LInputDecoration(labelText: '口令（可选）'),
            ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(
              context,
              SshKeyProfile({
                'id': const Uuid().v4(),
                'label': label.text.trim(),
                'type': 'ED25519',
                'privateKey': privateKey,
                'passphrase': passphrase.text,
                'savePassphrase': true,
                'source': 'imported',
                'category': 'key',
                'created': DateTime.now().millisecondsSinceEpoch,
              }),
            ),
            child: const LText('导入'),
          ),
        ],
      ),
    );
    if (key != null) {
      final controller = ref.read(vaultControllerProvider.notifier);
      final vault = await controller.ready();
      await controller.replace(vault.copyWith(keys: [...vault.keys, key]));
    }
  }
}
