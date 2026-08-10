import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../domain/models/host.dart';
import '../infrastructure/ssh/ssh_service.dart';
import '../infrastructure/ssh/server_monitor_service.dart';
import 'vault_controller.dart';

class SessionState {
  const SessionState({
    this.sessions = const [],
    this.activeIndex = 0,
    this.connectingHostId,
    this.error,
  });
  final List<ActiveTerminalSession> sessions;
  final int activeIndex;
  final String? connectingHostId;
  final Object? error;

  ActiveTerminalSession? get active => sessions.isEmpty
      ? null
      : sessions[activeIndex.clamp(0, sessions.length - 1)];
}

final sshServiceProvider = Provider((ref) => SshService());

final sessionControllerProvider =
    StateNotifierProvider<SessionController, SessionState>(
  (ref) => SessionController(
    ref.watch(sshServiceProvider),
    ref.watch(vaultControllerProvider.notifier),
    ref,
  ),
);

class SessionController extends StateNotifier<SessionState> {
  SessionController(this.service, this.vaultController, this.ref)
      : super(const SessionState());

  final SshService service;
  final VaultController vaultController;
  final Ref ref;

  Future<void> connect(
    HostProfile host,
    HostKeyVerifier verifyHostKey, {
    KeyboardInteractiveHandler? keyboardInteractive,
  }) async {
    state = SessionState(
      sessions: state.sessions,
      activeIndex: state.activeIndex,
      connectingHostId: host.id,
    );
    try {
      final vault = ref.read(vaultControllerProvider).data;
      final keys = vault?.keys ?? const <SshKeyProfile>[];
      final session = await service.connect(
        sessionId: const Uuid().v4(),
        host: host,
        hosts: vault?.hosts ?? const <HostProfile>[],
        keys: keys,
        proxyProfiles: vault?.proxyProfiles ?? const <ProxyProfile>[],
        verifyHostKey: verifyHostKey,
        keyboardInteractive: keyboardInteractive,
      );
      final sessions = [...state.sessions, session];
      state = SessionState(
        sessions: sessions,
        activeIndex: sessions.length - 1,
      );
      _watchSession(session);
      unawaited(vaultController.markConnected(host));
      unawaited(_detectSystem(session, host));
    } catch (error) {
      state = SessionState(
        sessions: state.sessions,
        activeIndex: state.activeIndex,
        error: error,
      );
      rethrow;
    }
  }

  Future<void> reconnectDisconnected() async {
    if (state.connectingHostId != null) return;
    for (final old in [...state.sessions]) {
      if (old.connected || old.closedByUser) continue;
      final index = state.sessions.indexWhere((value) => value.id == old.id);
      if (index < 0) continue;
      state = SessionState(
        sessions: state.sessions,
        activeIndex: state.activeIndex,
        connectingHostId: old.host.id,
      );
      try {
        final vault = ref.read(vaultControllerProvider).data;
        old.terminal.write('\r\n\x1b[33m正在恢复连接…\x1b[0m\r\n');
        final replacement = await service.connect(
          sessionId: old.id,
          host: old.host,
          hosts: vault?.hosts ?? const <HostProfile>[],
          keys: vault?.keys ?? const <SshKeyProfile>[],
          proxyProfiles: vault?.proxyProfiles ?? const <ProxyProfile>[],
          verifyHostKey: old.verifyHostKey,
          keyboardInteractive: old.keyboardInteractive,
          terminal: old.terminal,
        );
        final sessions = [...state.sessions];
        final current = sessions.indexWhere((value) => value.id == old.id);
        if (current >= 0) sessions[current] = replacement;
        state = SessionState(
          sessions: sessions,
          activeIndex: state.activeIndex.clamp(0, sessions.length - 1),
        );
        _watchSession(replacement);
        unawaited(_detectSystem(replacement, old.host));
      } catch (error) {
        old.terminal.write('\r\n\x1b[31m恢复连接失败：$error\x1b[0m\r\n');
        state = SessionState(
          sessions: state.sessions,
          activeIndex: state.activeIndex,
          error: error,
        );
      }
    }
  }

  void _watchSession(ActiveTerminalSession session) {
    unawaited(session.done.then((_) {
      if (session.closedByUser) return;
      session.connected = false;
      session.terminal.write('\r\n\x1b[33m连接已断开，返回前台后将自动重连。\x1b[0m\r\n');
      if (!mounted) return;
      state = SessionState(
        sessions: [...state.sessions],
        activeIndex: state.activeIndex,
      );
    }));
  }

  Future<void> _detectSystem(
    ActiveTerminalSession session,
    HostProfile host,
  ) async {
    if (!session.isSsh) return;
    try {
      final info = await ServerMonitorService().detect(session);
      session.systemInfo = info;
      final updated = HostProfile({
        ...host.data,
        'os': info.platform,
        'distro': info.distro,
        'systemInfo': info.toJson(),
      });
      await vaultController.upsertHost(updated);
      if (!mounted) return;
      state = SessionState(
        sessions: [...state.sessions],
        activeIndex: state.activeIndex,
      );
    } on Object {
      // Detection is best effort and must never interrupt an SSH session.
    }
  }

  void activate(int index) {
    if (index < 0 || index >= state.sessions.length) return;
    state = SessionState(sessions: state.sessions, activeIndex: index);
  }

  Future<void> close(int index) async {
    if (index < 0 || index >= state.sessions.length) return;
    final sessions = [...state.sessions];
    final removed = sessions.removeAt(index);
    await removed.close();
    state = SessionState(
      sessions: sessions,
      activeIndex: sessions.isEmpty
          ? 0
          : state.activeIndex.clamp(0, sessions.length - 1),
    );
  }

  void send(String text, {bool enter = false}) {
    final session = state.active;
    if (session == null) return;
    session.terminal.textInput(enter ? '$text\r' : text);
  }
}
