import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/models/host.dart';
import '../infrastructure/ssh/ssh_service.dart';
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
    final existing = state.sessions.indexWhere(
      (item) => item.host.id == host.id,
    );
    if (existing >= 0) {
      state = SessionState(sessions: state.sessions, activeIndex: existing);
      return;
    }
    state = SessionState(
      sessions: state.sessions,
      activeIndex: state.activeIndex,
      connectingHostId: host.id,
    );
    try {
      final keys =
          ref.read(vaultControllerProvider).data?.keys ??
          const <SshKeyProfile>[];
      final session = await service.connect(
        host: host,
        keys: keys,
        verifyHostKey: verifyHostKey,
        keyboardInteractive: keyboardInteractive,
      );
      final sessions = [...state.sessions, session];
      state = SessionState(
        sessions: sessions,
        activeIndex: sessions.length - 1,
      );
      unawaited(vaultController.markConnected(host));
    } catch (error) {
      state = SessionState(
        sessions: state.sessions,
        activeIndex: state.activeIndex,
        error: error,
      );
      rethrow;
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
