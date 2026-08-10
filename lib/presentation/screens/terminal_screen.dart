import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../../application/session_controller.dart';
import '../../application/settings_controller.dart';
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
                          itemBuilder: (_, index) => Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical: 7,
                              horizontal: 2,
                            ),
                            child: InputChip(
                              selected: state.activeIndex == index,
                              label: Text(state.sessions[index].host.label),
                              onPressed: () => ref
                                  .read(sessionControllerProvider.notifier)
                                  .activate(index),
                              onDeleted: () => ref
                                  .read(sessionControllerProvider.notifier)
                                  .close(index),
                            ),
                          ),
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

class _SpecialKeys extends StatelessWidget {
  const _SpecialKeys({required this.onSend});
  final void Function(String, {bool enter}) onSend;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 44,
    child: ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      children: [
        _key('Esc', '\x1b'),
        _key('Tab', '\t'),
        _key('Ctrl+C', '\x03'),
        _key('Ctrl+D', '\x04'),
        _key('Ctrl+Z', '\x1a'),
        _key('↑', '\x1b[A'),
        _key('↓', '\x1b[B'),
        _key('←', '\x1b[D'),
        _key('→', '\x1b[C'),
        _key('|', '|'),
        _key('/', '/'),
        _key('~', '~'),
      ],
    ),
  );

  Widget _key(String label, String value) => Padding(
    padding: const EdgeInsets.only(right: 6),
    child: OutlinedButton(
      onPressed: () => onSend(value),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12),
      ),
      child: Text(label),
    ),
  );
}
