import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../application/session_controller.dart';
import '../../application/settings_controller.dart';
import '../../domain/models/settings.dart';
import '../../infrastructure/ai/ai_service.dart';
import '../../infrastructure/ssh/ssh_service.dart';
import '../../infrastructure/storage/vault_repository.dart';
import '../theme.dart';
import '../widgets/empty_state.dart';
import '../widgets/port_forward_sheet.dart';

class TerminalScreen extends ConsumerStatefulWidget {
  const TerminalScreen({super.key});

  @override
  ConsumerState<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends ConsumerState<TerminalScreen> {
  var _split = false;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(sessionControllerProvider);
    final settings = ref.watch(settingsControllerProvider);
    return SafeArea(
      child: Column(
        children: [
          SizedBox(
            height: 52,
            child: Row(
              children: [
                const SizedBox(width: 12),
                const Icon(Icons.terminal, color: NetcattyTheme.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: state.sessions.isEmpty
                      ? const Text('终端')
                      : ListView.builder(
                          scrollDirection: Axis.horizontal,
                          itemCount: state.sessions.length,
                          itemBuilder: (_, index) {
                            final session = state.sessions[index];
                            final occurrence = state.sessions
                                .take(index + 1)
                                .where(
                                    (value) => value.host.id == session.host.id)
                                .length;
                            final duplicateCount = state.sessions
                                .where(
                                    (value) => value.host.id == session.host.id)
                                .length;
                            return Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: 7,
                                horizontal: 2,
                              ),
                              child: InputChip(
                                selected: state.activeIndex == index,
                                avatar: Icon(
                                  session.connected
                                      ? Icons.circle
                                      : Icons.error_outline,
                                  size: session.connected ? 10 : 16,
                                  color: session.connected
                                      ? Colors.greenAccent
                                      : Colors.orangeAccent,
                                ),
                                label: Text(
                                  duplicateCount > 1
                                      ? '${session.host.label} #$occurrence'
                                      : session.host.label,
                                ),
                                onPressed: () => ref
                                    .read(sessionControllerProvider.notifier)
                                    .activate(index),
                                onDeleted: () => ref
                                    .read(sessionControllerProvider.notifier)
                                    .close(index),
                              ),
                            );
                          },
                        ),
                ),
                if (state.sessions.length > 1)
                  IconButton(
                    tooltip: '分屏',
                    isSelected: _split,
                    onPressed: () => setState(() => _split = !_split),
                    icon: const Icon(Icons.vertical_split_outlined),
                  ),
                if (state.active != null)
                  IconButton(
                    tooltip: '端口转发',
                    onPressed: () => showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      builder: (_) => PortForwardSheet(session: state.active!),
                    ),
                    icon: const Icon(Icons.swap_horiz),
                  ),
                if (state.active != null)
                  IconButton(
                    tooltip: 'Catty AI',
                    onPressed: () => _openAi(state.active!),
                    icon: const Icon(
                      Icons.auto_awesome,
                      color: NetcattyTheme.accent,
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: state.connectingHostId != null
                ? const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 12),
                        Text('正在建立安全连接…'),
                      ],
                    ),
                  )
                : state.sessions.isEmpty
                    ? const EmptyState(
                        icon: Icons.terminal_outlined,
                        title: '没有活动会话',
                        subtitle: '从“保险库”选择主机开始连接。',
                      )
                    : LayoutBuilder(
                        builder: (context, constraints) {
                          if (!_split || state.sessions.length < 2) {
                            return _TerminalPane(
                              session: state.active!,
                              fontSize: settings.terminalFontSize,
                            );
                          }
                          final secondIndex =
                              (state.activeIndex + 1) % state.sessions.length;
                          final children = [
                            Expanded(
                              child: _TerminalPane(
                                session: state.active!,
                                fontSize: settings.terminalFontSize,
                              ),
                            ),
                            const Divider(height: 1, thickness: 1),
                            Expanded(
                              child: _TerminalPane(
                                session: state.sessions[secondIndex],
                                fontSize: settings.terminalFontSize,
                              ),
                            ),
                          ];
                          return constraints.maxWidth > constraints.maxHeight
                              ? Row(children: children)
                              : Column(children: children);
                        },
                      ),
          ),
          if (state.active != null)
            _SpecialKeys(
              order: settings.terminalQuickKeys,
              onSend: ref.read(sessionControllerProvider.notifier).send,
            ),
        ],
      ),
    );
  }

  Future<void> _openAi(ActiveTerminalSession session) async {
    final request = TextEditingController();
    final prompt = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: EdgeInsets.fromLTRB(
          16,
          18,
          16,
          MediaQuery.viewInsetsOf(context).bottom + 18,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Catty Agent', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            Text('为 ${session.host.label} 生成安全的运维命令。执行前会让你确认。'),
            const SizedBox(height: 14),
            TextField(
              controller: request,
              autofocus: true,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(
                hintText: '例如：检查磁盘空间并列出最大的 10 个目录',
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => Navigator.pop(context, request.text.trim()),
                icon: const Icon(Icons.auto_awesome),
                label: const Text('生成命令'),
              ),
            ),
          ],
        ),
      ),
    );
    if (prompt == null || prompt.isEmpty || !mounted) return;
    try {
      final repository = ref.read(vaultRepositoryProvider);
      final settings = await repository.loadSettings();
      final apiKey = await repository.readAiApiKey();
      if (apiKey == null || apiKey.isEmpty) {
        throw StateError('请先在设置中填写 AI API Key');
      }
      final suggestion = await AiService().suggestCommand(
        request: prompt,
        settings: settings,
        apiKey: apiKey,
        hostSummary:
            '${session.host.username}@${session.host.hostname}, ${session.host.data['os'] ?? 'linux'}',
      );
      if (!mounted) return;
      final run = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('确认命令'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(suggestion.explanation),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  suggestion.command,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('仅粘贴'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('执行'),
            ),
          ],
        ),
      );
      ref
          .read(sessionControllerProvider.notifier)
          .send(suggestion.command, enter: run == true);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$error')));
      }
    }
  }
}

class _TerminalPane extends StatelessWidget {
  const _TerminalPane({required this.session, required this.fontSize});
  final ActiveTerminalSession session;
  final double fontSize;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: const Color(0xff050607),
        child: TerminalView(
          session.terminal,
          autofocus: true,
          padding: const EdgeInsets.all(8),
          textStyle: TerminalStyle(fontSize: fontSize, fontFamily: 'monospace'),
        ),
      );
}

class _SpecialKeys extends ConsumerWidget {
  const _SpecialKeys({required this.order, required this.onSend});
  final List<String> order;
  final void Function(String, {bool enter}) onSend;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final normalized = [
      ...order.where(_quickKeys.containsKey),
      ...defaultTerminalQuickKeys.where((value) => !order.contains(value)),
    ];
    final split = (normalized.length + 1) ~/ 2;
    return SizedBox(
      height: 92,
      child: Row(
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 6),
            child: IconButton(
              tooltip: '自定义快捷键顺序',
              onPressed: () => _customize(context, ref, normalized),
              icon: const Icon(Icons.tune, size: 20),
            ),
          ),
          Expanded(
            child: Column(
              children: [
                Expanded(child: _row(normalized.take(split))),
                Expanded(child: _row(normalized.skip(split))),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(Iterable<String> ids) => ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
        children: ids.map((id) {
          final key = _quickKeys[id]!;
          return _key(key.label, key.value);
        }).toList(),
      );

  Widget _key(String label, String? value) => Padding(
        padding: const EdgeInsets.only(right: 6),
        child: OutlinedButton(
          onPressed: value == null
              ? () => FocusManager.instance.primaryFocus?.unfocus()
              : () => onSend(value),
          style: OutlinedButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 12),
          ),
          child: Text(label),
        ),
      );

  Future<void> _customize(
    BuildContext context,
    WidgetRef ref,
    List<String> current,
  ) async {
    final working = [...current];
    final result = await showModalBottomSheet<List<String>>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => SizedBox(
          height: MediaQuery.sizeOf(context).height * .72,
          child: Column(
            children: [
              ListTile(
                title: const Text('快捷键顺序'),
                subtitle: const Text('拖动排序，终端中会自动分成两行显示'),
                trailing: TextButton(
                  onPressed: () => setModalState(() {
                    working
                      ..clear()
                      ..addAll(defaultTerminalQuickKeys);
                  }),
                  child: const Text('恢复默认'),
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ReorderableListView.builder(
                  itemCount: working.length,
                  onReorderItem: (oldIndex, newIndex) => setModalState(() {
                    final value = working.removeAt(oldIndex);
                    working.insert(newIndex, value);
                  }),
                  itemBuilder: (context, index) {
                    final id = working[index];
                    return ListTile(
                      key: ValueKey(id),
                      leading: const Icon(Icons.drag_handle),
                      title: Text(_quickKeys[id]!.label),
                      trailing: Text(
                          index < (working.length + 1) ~/ 2 ? '第一行' : '第二行'),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: () => Navigator.pop(context, working),
                    child: const Text('保存排序'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (result == null) return;
    final settings = ref.read(settingsControllerProvider);
    await ref.read(settingsControllerProvider.notifier).update(
          settings.copyWith(terminalQuickKeys: result),
        );
  }
}

class _QuickKey {
  const _QuickKey(this.label, this.value);
  final String label;
  final String? value;
}

const _quickKeys = <String, _QuickKey>{
  'escape': _QuickKey('Esc', '\x1b'),
  'tab': _QuickKey('Tab', '\t'),
  'ctrlC': _QuickKey('Ctrl+C', '\x03'),
  'ctrlD': _QuickKey('Ctrl+D', '\x04'),
  'ctrlZ': _QuickKey('Ctrl+Z', '\x1a'),
  'arrowUp': _QuickKey('↑', '\x1b[A'),
  'arrowDown': _QuickKey('↓', '\x1b[B'),
  'arrowLeft': _QuickKey('←', '\x1b[D'),
  'arrowRight': _QuickKey('→', '\x1b[C'),
  'pipe': _QuickKey('|', '|'),
  'slash': _QuickKey('/', '/'),
  'tilde': _QuickKey('~', '~'),
  'hideKeyboard': _QuickKey('收起键盘', null),
};
