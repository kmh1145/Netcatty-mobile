import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../../application/session_controller.dart';
import '../../application/settings_controller.dart';
import '../../infrastructure/ai/ai_service.dart';
import '../../infrastructure/ssh/ssh_service.dart';
import '../../infrastructure/storage/vault_repository.dart';
import '../widgets/empty_state.dart';
import '../widgets/host_system_icon.dart';
import '../widgets/port_forward_sheet.dart';
import '../widgets/server_monitor_sheet.dart';
import '../widgets/terminal_special_keys.dart';

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
    final selectedPending = state.selectedPending;
    final visibleSession = selectedPending == null ? state.active : null;
    final tabHosts = [
      ...state.sessions.map((value) => value.host),
      ...state.pendingConnections.map((value) => value.host),
    ];
    return SafeArea(
      child: Column(
        children: [
          SizedBox(
            height: 52,
            child: Row(
              children: [
                const SizedBox(width: 12),
                Icon(
                  Icons.terminal,
                  color: Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: state.tabCount == 0
                      ? const Text('终端')
                      : ListView.builder(
                          scrollDirection: Axis.horizontal,
                          itemCount: state.tabCount,
                          itemBuilder: (_, index) {
                            final host = tabHosts[index];
                            final occurrence = tabHosts
                                .take(index + 1)
                                .where((value) => value.id == host.id)
                                .length;
                            final duplicateCount = tabHosts
                                .where((value) => value.id == host.id)
                                .length;
                            if (index >= state.sessions.length) {
                              final pending = state.pendingConnections[
                                  index - state.sessions.length];
                              final failed = pending.phase ==
                                  PendingConnectionPhase.failed;
                              return Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 7,
                                  horizontal: 2,
                                ),
                                child: InputChip(
                                  selected: state.activePendingId == pending.id,
                                  showCheckmark: false,
                                  avatar: failed
                                      ? const Icon(
                                          Icons.error_outline,
                                          size: 17,
                                          color: Colors.redAccent,
                                        )
                                      : const SizedBox.square(
                                          dimension: 14,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        ),
                                  label: Text(
                                    duplicateCount > 1
                                        ? '${host.label} #$occurrence'
                                        : host.label,
                                  ),
                                  onPressed: () => ref
                                      .read(
                                        sessionControllerProvider.notifier,
                                      )
                                      .activate(index),
                                  onDeleted: failed
                                      ? () => ref
                                          .read(
                                            sessionControllerProvider.notifier,
                                          )
                                          .dismissPending(pending.id)
                                      : null,
                                ),
                              );
                            }
                            final session = state.sessions[index];
                            return Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: 7,
                                horizontal: 2,
                              ),
                              child: InputChip(
                                selected: state.activeIndex == index,
                                showCheckmark: false,
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
                                onDeleted: () => _confirmClose(index, session),
                              ),
                            );
                          },
                        ),
                ),
                if (visibleSession != null)
                  IconButton(
                    tooltip: '性能监控',
                    onPressed: visibleSession.isSsh
                        ? () => showModalBottomSheet<void>(
                              context: context,
                              useSafeArea: true,
                              isScrollControlled: true,
                              builder: (_) => ServerMonitorSheet(
                                session: visibleSession,
                              ),
                            )
                        : null,
                    icon: const Icon(Icons.monitor_heart_outlined),
                  ),
              ],
            ),
          ),
          Expanded(
            child: selectedPending != null
                ? _ConnectionStatusPane(
                    pending: selectedPending,
                    onReturn: state.sessions.isEmpty
                        ? null
                        : () => ref
                            .read(sessionControllerProvider.notifier)
                            .activate(state.activeIndex),
                    onClose:
                        selectedPending.phase == PendingConnectionPhase.failed
                            ? () => ref
                                .read(sessionControllerProvider.notifier)
                                .dismissPending(selectedPending.id)
                            : null,
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
                              key: ValueKey(state.active!.id),
                              session: state.active!,
                              fontSize: settings.terminalFontSize,
                            );
                          }
                          final secondIndex =
                              (state.activeIndex + 1) % state.sessions.length;
                          final children = [
                            Expanded(
                              child: _TerminalPane(
                                key: ValueKey(state.active!.id),
                                session: state.active!,
                                fontSize: settings.terminalFontSize,
                              ),
                            ),
                            const Divider(height: 1, thickness: 1),
                            Expanded(
                              child: _TerminalPane(
                                key: ValueKey(state.sessions[secondIndex].id),
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
          if (visibleSession != null)
            TerminalSpecialKeys(
              order: settings.terminalQuickKeys,
              customKeys: settings.terminalCustomKeys,
              onSend: ref.read(sessionControllerProvider.notifier).send,
              onAi: () => _openAi(visibleSession),
              onPortForward: visibleSession.isSsh
                  ? () => showModalBottomSheet<void>(
                        context: context,
                        isScrollControlled: true,
                        builder: (_) =>
                            PortForwardSheet(session: visibleSession),
                      )
                  : null,
              split: _split,
              onSplit: state.sessions.length > 1
                  ? () => setState(() => _split = !_split)
                  : null,
            ),
        ],
      ),
    );
  }

  Future<void> _confirmClose(
    int index,
    ActiveTerminalSession session,
  ) async {
    final close = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            icon: const Icon(Icons.warning_amber_outlined),
            title: const Text('关闭 SSH 标签页？'),
            content: Text(
              '将断开 ${session.host.label} '
              '(${session.host.username}@${session.host.hostname}) 的当前会话。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('断开并关闭'),
              ),
            ],
          ),
        ) ??
        false;
    if (!close || !mounted) return;
    await ref.read(sessionControllerProvider.notifier).close(index);
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

class _ConnectionStatusPane extends StatelessWidget {
  const _ConnectionStatusPane({
    required this.pending,
    this.onReturn,
    this.onClose,
  });

  final PendingTerminalConnection pending;
  final VoidCallback? onReturn;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final failed = pending.phase == PendingConnectionPhase.failed;
    return ColoredBox(
      color: scheme.surface,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Card(
              key: const ValueKey('terminal-connection-status-dialog'),
              elevation: 12,
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    HostSystemIcon(host: pending.host, size: 50),
                    const SizedBox(height: 12),
                    Text(
                      pending.host.label,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${pending.host.protocol.name.toUpperCase()}  '
                      '${pending.host.username}@${pending.host.hostname}:'
                      '${pending.host.port}',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                    const SizedBox(height: 20),
                    if (failed)
                      Icon(
                        Icons.error_outline,
                        size: 38,
                        color: scheme.error,
                      )
                    else ...[
                      const LinearProgressIndicator(),
                      const SizedBox(height: 18),
                    ],
                    Text(
                      failed ? '安全连接建立失败' : '正在建立安全连接…',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: failed ? scheme.error : null,
                          ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      failed
                          ? '${pending.error ?? '未知错误'}'
                          : '连接会在此标签页中完成，其他终端会话不会受到影响。',
                      maxLines: failed ? 5 : 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                    if (onReturn != null || onClose != null) ...[
                      const SizedBox(height: 18),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          if (onReturn != null)
                            TextButton.icon(
                              onPressed: onReturn,
                              icon: const Icon(Icons.arrow_back),
                              label: const Text('返回当前终端'),
                            ),
                          if (onClose != null)
                            FilledButton.icon(
                              onPressed: onClose,
                              icon: const Icon(Icons.close),
                              label: const Text('关闭标签页'),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TerminalPane extends StatefulWidget {
  const _TerminalPane({
    super.key,
    required this.session,
    required this.fontSize,
  });
  final ActiveTerminalSession session;
  final double fontSize;

  @override
  State<_TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<_TerminalPane> {
  final _controller = TerminalController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final terminalTheme = TerminalTheme(
      cursor: scheme.primary,
      selection: scheme.primary.withValues(alpha: 0.35),
      foreground: scheme.onSurface,
      background: scheme.surface,
      black: const Color(0xff1d1f21),
      red: const Color(0xffcc6666),
      green: const Color(0xffb5bd68),
      yellow: const Color(0xfff0c674),
      blue: const Color(0xff81a2be),
      magenta: const Color(0xffb294bb),
      cyan: const Color(0xff8abeb7),
      white: const Color(0xffc5c8c6),
      brightBlack: const Color(0xff666666),
      brightRed: const Color(0xffd54e53),
      brightGreen: const Color(0xffb9ca4a),
      brightYellow: const Color(0xffe7c547),
      brightBlue: const Color(0xff7aa6da),
      brightMagenta: const Color(0xffc397d8),
      brightCyan: const Color(0xff70c0b1),
      brightWhite: const Color(0xffeaeaea),
      searchHitBackground: scheme.tertiaryContainer,
      searchHitBackgroundCurrent: scheme.primaryContainer,
      searchHitForeground: scheme.onSurface,
    );
    return ColoredBox(
      color: scheme.surface,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => Stack(
          fit: StackFit.expand,
          children: [
            TerminalView(
              widget.session.terminal,
              controller: _controller,
              theme: terminalTheme,
              keyboardAppearance: Theme.of(context).brightness,
              autofocus: true,
              padding: const EdgeInsets.all(8),
              textStyle: TerminalStyle(
                fontSize: widget.fontSize,
                fontFamily: 'monospace',
              ),
            ),
            if (_controller.selection != null)
              Positioned(
                top: 10,
                right: 10,
                child: FilledButton.tonalIcon(
                  key: const ValueKey('copy-terminal-selection'),
                  onPressed: _copySelection,
                  icon: const Icon(Icons.copy_outlined, size: 18),
                  label: const Text('复制'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _copySelection() async {
    final selection = _controller.selection;
    if (selection == null) return;
    final text = widget.session.terminal.buffer.getText(selection);
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    _controller.clearSelection();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('已复制终端文本'),
        duration: Duration(seconds: 1),
      ),
    );
  }
}
