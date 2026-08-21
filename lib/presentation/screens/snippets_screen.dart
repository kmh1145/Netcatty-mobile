import 'package:flutter/material.dart';
import 'package:netcatty_mobile/presentation/localization/localized_widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../application/session_controller.dart';
import '../../application/vault_controller.dart';
import '../../domain/models/host.dart';
import '../widgets/empty_state.dart';

class SnippetsScreen extends ConsumerWidget {
  const SnippetsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vault = ref.watch(vaultControllerProvider).data;
    final snippets = vault?.snippets ?? const <CommandSnippet>[];
    return SafeArea(
      child: Scaffold(
        appBar: AppBar(
          title: const LText('命令片段'),
          actions: [
            IconButton(
              onPressed: () => _edit(context, ref),
              icon: const Icon(Icons.add),
            ),
          ],
        ),
        body: snippets.isEmpty
            ? EmptyState(
                icon: Icons.code,
                title: '还没有命令片段',
                subtitle: '保存常用命令，一次点击即可发送到当前终端。',
                action: FilledButton.icon(
                  onPressed: () => _edit(context, ref),
                  icon: const Icon(Icons.add),
                  label: const LText('新建片段'),
                ),
              )
            : ListView.separated(
                padding: const EdgeInsets.all(12),
                itemCount: snippets.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (_, index) {
                  final snippet = snippets[index];
                  return Card(
                    child: ListTile(
                      leading: const Icon(Icons.code),
                      title: LText(snippet.label),
                      subtitle: LText(
                        snippet.command,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                      onTap: () {
                        final active =
                            ref.read(sessionControllerProvider).active;
                        if (active == null) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: LText('请先建立终端会话')),
                          );
                        } else {
                          ref
                              .read(sessionControllerProvider.notifier)
                              .send(snippet.command, enter: snippet.autoRun);
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: LText('已发送到 ${active.host.label}'),
                            ),
                          );
                        }
                      },
                      trailing: IconButton(
                        onPressed: () => _edit(context, ref, snippet),
                        icon: const Icon(Icons.edit_outlined),
                      ),
                    ),
                  );
                },
              ),
      ),
    );
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref, [
    CommandSnippet? snippet,
  ]) async {
    final label = TextEditingController(text: snippet?.label);
    final command = TextEditingController(text: snippet?.command);
    var autoRun = snippet?.autoRun ?? true;
    final result = await showModalBottomSheet<CommandSnippet>(
      context: context,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            20,
            16,
            MediaQuery.viewInsetsOf(context).bottom + 20,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LText(
                snippet == null ? '新建命令片段' : '编辑命令片段',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: label,
                decoration: LInputDecoration(labelText: '名称'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: command,
                minLines: 4,
                maxLines: 10,
                style: const TextStyle(fontFamily: 'monospace'),
                decoration: LInputDecoration(labelText: '命令'),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const LText('发送后立即执行'),
                value: autoRun,
                onChanged: (value) => setState(() => autoRun = value),
              ),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () {
                    if (label.text.trim().isEmpty ||
                        command.text.trim().isEmpty) {
                      return;
                    }
                    Navigator.pop(
                      context,
                      CommandSnippet({
                        ...?snippet?.data,
                        'id': snippet?.id ?? const Uuid().v4(),
                        'label': label.text.trim(),
                        'command': command.text,
                        'noAutoRun': !autoRun,
                        'kind': 'snippet',
                      }),
                    );
                  },
                  child: const LText('保存'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (result == null) return;
    final vault = ref.read(vaultControllerProvider).data;
    if (vault == null) return;
    final list = [...vault.snippets];
    final index = list.indexWhere((value) => value.id == result.id);
    if (index < 0) {
      list.add(result);
    } else {
      list[index] = result;
    }
    await ref
        .read(vaultControllerProvider.notifier)
        .replace(vault.copyWith(snippets: list));
  }
}
