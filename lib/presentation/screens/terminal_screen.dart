import 'dart:async';

import 'package:flutter/material.dart';
import 'package:netcatty_mobile/presentation/localization/localized_widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:xterm2/xterm.dart';

import '../../application/session_controller.dart';
import '../../application/home_navigation.dart';
import '../../application/settings_controller.dart';
import '../../application/vault_controller.dart';
import '../../infrastructure/ai/ai_service.dart';
import '../../infrastructure/http_client_provider.dart';
import '../../infrastructure/ssh/ssh_service.dart';
import '../../infrastructure/ssh/terminal_picture_in_picture_service.dart';
import '../../infrastructure/storage/vault_repository.dart';
import '../widgets/empty_state.dart';
import '../widgets/ai_chat_sheet.dart';
import '../widgets/host_system_icon.dart';
import '../widgets/port_forward_sheet.dart';
import '../widgets/server_monitor_sheet.dart';
import '../widgets/terminal_special_keys.dart';
import '../widgets/system_management/system_management_sheet.dart';

part 'terminal_screen_pane.dart';

final terminalFullscreenProvider = StateProvider<bool>((ref) => false);
final terminalPictureInPictureProvider = StateProvider<bool>((ref) => false);

class TerminalScreen extends ConsumerStatefulWidget {
  const TerminalScreen({super.key});

  @override
  ConsumerState<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends ConsumerState<TerminalScreen> {
  var _split = false;
  StreamSubscription<bool>? _pictureInPictureSubscription;
  final _aiMessagesBySession = <String, List<AiChatMessage>>{};

  @override
  void initState() {
    super.initState();
    _pictureInPictureSubscription =
        TerminalPictureInPictureService.stateChanges.listen((active) {
      if (!mounted) return;
      ref.read(terminalPictureInPictureProvider.notifier).state = active;
    });
  }

  @override
  void dispose() {
    _pictureInPictureSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(sessionControllerProvider);
    final settings = ref.watch(settingsControllerProvider);
    final snippets =
        ref.watch(vaultControllerProvider).data?.snippets ?? const [];
    final selectedPending = state.selectedPending;
    final visibleSession = selectedPending == null ? state.active : null;
    final fullscreen = ref.watch(terminalFullscreenProvider);
    final pictureInPicture = ref.watch(terminalPictureInPictureProvider);
    if ((fullscreen || pictureInPicture) && visibleSession == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (ref.read(terminalFullscreenProvider)) {
          ref.read(terminalFullscreenProvider.notifier).state = false;
        }
        if (ref.read(terminalPictureInPictureProvider)) {
          ref.read(terminalPictureInPictureProvider.notifier).state = false;
          unawaited(TerminalPictureInPictureService.stop());
        }
      });
    }
    final tabHosts = [
      ...state.sessions.map((value) => value.host),
      ...state.pendingConnections.map((value) => value.host),
    ];
    return SafeArea(
      child: Stack(
        children: [
          Positioned.fill(
            child: Column(
              children: [
                if (!fullscreen && !pictureInPicture)
                  SizedBox(
                    key: const ValueKey('terminal-tab-strip'),
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
                              ? const LText('终端')
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
                                          selected: state.activePendingId ==
                                              pending.id,
                                          showCheckmark: false,
                                          avatar: failed
                                              ? const Icon(
                                                  Icons.error_outline,
                                                  size: 17,
                                                  color: Colors.redAccent,
                                                )
                                              : const SizedBox.square(
                                                  dimension: 14,
                                                  child:
                                                      CircularProgressIndicator(
                                                    strokeWidth: 2,
                                                  ),
                                                ),
                                          label: LText(
                                            duplicateCount > 1
                                                ? '${host.label} #$occurrence'
                                                : host.label,
                                          ),
                                          onPressed: () => ref
                                              .read(
                                                sessionControllerProvider
                                                    .notifier,
                                              )
                                              .activate(index),
                                          onDeleted: failed
                                              ? () => ref
                                                  .read(
                                                    sessionControllerProvider
                                                        .notifier,
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
                                        label: LText(
                                          duplicateCount > 1
                                              ? '${session.host.label} #$occurrence'
                                              : session.host.label,
                                        ),
                                        onPressed: () => ref
                                            .read(sessionControllerProvider
                                                .notifier)
                                            .activate(index),
                                        onDeleted: () =>
                                            _confirmClose(index, session),
                                      ),
                                    );
                                  },
                                ),
                        ),
                        if (visibleSession != null)
                          IconButton(
                            key: const ValueKey(
                              'terminal-performance-monitor',
                            ),
                            tooltip: localized('性能监控'),
                            onPressed: visibleSession.isSsh
                                ? () => _openPerformanceMonitor(visibleSession)
                                : null,
                            icon: const Icon(Icons.monitor_heart_outlined),
                          ),
                      ],
                    ),
                  ),
                if (pictureInPicture && visibleSession != null)
                  _TerminalPictureInPictureHeader(session: visibleSession),
                Expanded(
                  child: selectedPending != null
                      ? _ConnectionStatusPane(
                          pending: selectedPending,
                          onReturn: state.sessions.isEmpty
                              ? null
                              : () => ref
                                  .read(sessionControllerProvider.notifier)
                                  .activate(state.activeIndex),
                          onClose: selectedPending.phase ==
                                  PendingConnectionPhase.failed
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
                                if (pictureInPicture ||
                                    !_split ||
                                    state.sessions.length < 2) {
                                  return _TerminalPane(
                                    key: ValueKey(state.active!.id),
                                    session: state.active!,
                                    fontSize: settings.terminalFontSize,
                                    secureKeyboard:
                                        settings.terminalSecureKeyboard,
                                    pictureInPicture: pictureInPicture,
                                  );
                                }
                                final secondIndex = (state.activeIndex + 1) %
                                    state.sessions.length;
                                final children = [
                                  Expanded(
                                    child: _TerminalPane(
                                      key: ValueKey(state.active!.id),
                                      session: state.active!,
                                      fontSize: settings.terminalFontSize,
                                      secureKeyboard:
                                          settings.terminalSecureKeyboard,
                                      pictureInPicture: false,
                                    ),
                                  ),
                                  const Divider(height: 1, thickness: 1),
                                  Expanded(
                                    child: _TerminalPane(
                                      key: ValueKey(
                                          state.sessions[secondIndex].id),
                                      session: state.sessions[secondIndex],
                                      fontSize: settings.terminalFontSize,
                                      secureKeyboard:
                                          settings.terminalSecureKeyboard,
                                      pictureInPicture: false,
                                    ),
                                  ),
                                ];
                                return constraints.maxWidth >
                                        constraints.maxHeight
                                    ? Row(children: children)
                                    : Column(children: children);
                              },
                            ),
                ),
                if (visibleSession != null && !pictureInPicture)
                  TerminalSpecialKeys(
                    order: settings.terminalQuickKeys,
                    customKeys: settings.terminalCustomKeys,
                    inputController: visibleSession.input,
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
                    onSystemManagement: visibleSession.isSsh
                        ? () => showModalBottomSheet<void>(
                              context: context,
                              useSafeArea: true,
                              isScrollControlled: true,
                              backgroundColor: Colors.transparent,
                              builder: (_) => SystemManagementSheet(
                                session: visibleSession,
                                snippets: snippets,
                                onOpenTerminal: (label, command) =>
                                    _openManagedTerminal(
                                  visibleSession,
                                  label,
                                  command,
                                ),
                                onOpenSftp: (filePath) {
                                  ref
                                      .read(sftpNavigationRequestProvider
                                          .notifier)
                                      .state = SftpNavigationRequest(
                                    sessionId: visibleSession.id,
                                    filePath: filePath,
                                  );
                                  ref.read(homeTabProvider.notifier).state = 2;
                                },
                              ),
                            )
                        : null,
                    pictureInPicture: pictureInPicture,
                    onPictureInPicture: () =>
                        _togglePictureInPicture(visibleSession),
                    fullscreen: fullscreen,
                    onFullscreen: () => ref
                        .read(terminalFullscreenProvider.notifier)
                        .state = !fullscreen,
                    split: _split,
                    onSplit: state.sessions.length > 1
                        ? () => setState(() => _split = !_split)
                        : null,
                  ),
              ],
            ),
          ),
          if (fullscreen && !pictureInPicture && visibleSession != null)
            Positioned(
              top: 4,
              right: 4,
              child: Material(
                key: const ValueKey('terminal-floating-performance'),
                color: Theme.of(context)
                    .colorScheme
                    .surfaceContainerHighest
                    .withValues(alpha: .82),
                elevation: 2,
                shape: const CircleBorder(),
                child: IconButton(
                  key: const ValueKey('terminal-performance-monitor'),
                  tooltip: localized('性能监控'),
                  onPressed: visibleSession.isSsh
                      ? () => _openPerformanceMonitor(visibleSession)
                      : null,
                  icon: const Icon(Icons.monitor_heart_outlined),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _togglePictureInPicture(
    ActiveTerminalSession session,
  ) async {
    if (ref.read(terminalPictureInPictureProvider)) {
      await TerminalPictureInPictureService.stop();
      return;
    }
    final supported = await TerminalPictureInPictureService.isSupported();
    if (!supported) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: LText('当前设备或系统版本不支持终端画中画')),
      );
      return;
    }
    ref.read(terminalPictureInPictureProvider.notifier).state = true;
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    final scheme = Theme.of(context).colorScheme;
    final entered = await TerminalPictureInPictureService.enter(
      title: session.host.label,
      text: terminalPictureInPictureText(session.terminal),
      connected: session.connected,
      backgroundColor: scheme.surface.toARGB32(),
      foregroundColor: scheme.onSurface.toARGB32(),
      accentColor: scheme.primary.toARGB32(),
    );
    if (entered || !mounted) return;
    ref.read(terminalPictureInPictureProvider.notifier).state = false;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: LText('画中画初始化失败，请稍后重试')),
    );
  }

  void _openPerformanceMonitor(ActiveTerminalSession session) {
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) => ServerMonitorSheet(session: session),
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
            title: const LText('关闭 SSH 标签页？'),
            content: LText(
              '将断开 ${session.host.label} '
              '(${session.host.username}@${session.host.hostname}) 的当前会话。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const LText('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const LText('断开并关闭'),
              ),
            ],
          ),
        ) ??
        false;
    if (!close || !mounted) return;
    await ref.read(sessionControllerProvider.notifier).close(index);
    _aiMessagesBySession.remove(session.id);
  }

  Future<void> _openManagedTerminal(
    ActiveTerminalSession parent,
    String label,
    String command,
  ) async {
    try {
      await ref.read(sessionControllerProvider.notifier).openManagedTerminal(
            parent,
            label: label,
            command: command,
          );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: LText('无法打开 $label：$error')),
      );
    }
  }

  Future<void> _openAi(ActiveTerminalSession session) async {
    try {
      final repository = ref.read(vaultRepositoryProvider);
      final settings = await repository.loadSettings();
      final apiKey = await repository.readAiApiKey();
      if (apiKey == null || apiKey.isEmpty) {
        throw StateError('请先在设置中填写 AI API Key');
      }
      if (!mounted) return;
      final service = AiService(client: ref.read(httpClientProvider));
      await showModalBottomSheet<void>(
        context: context,
        useSafeArea: true,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (context) => FractionallySizedBox(
          heightFactor: .92,
          child: ClipRRect(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            child: AiChatSheet(
              host: session.host,
              settings: settings,
              apiKey: apiKey,
              service: service,
              initialMessages: _aiMessagesBySession[session.id] ?? const [],
              onMessagesChanged: (messages) {
                _aiMessagesBySession[session.id] = messages;
              },
              terminalContext: () => terminalAiContextText(session.terminal),
              onModelChanged: (model) async {
                final current = await repository.loadSettings();
                await ref.read(settingsControllerProvider.notifier).update(
                      current.copyWith(aiModel: model),
                    );
              },
              onCommand: (command, execute) async {
                ref.read(sessionControllerProvider.notifier).sendToSession(
                      session.id,
                      command,
                      enter: execute,
                    );
              },
            ),
          ),
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: LText('$error')));
      }
    }
  }
}
