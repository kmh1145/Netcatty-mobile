import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../domain/models/host.dart';
import '../infrastructure/ssh/ssh_service.dart';
import '../infrastructure/ssh/server_monitor_service.dart';
import 'vault_controller.dart';

enum PendingConnectionPhase { connecting, failed }

class PendingTerminalConnection {
  const PendingTerminalConnection({
    required this.id,
    required this.host,
    this.phase = PendingConnectionPhase.connecting,
    this.error,
  });

  final String id;
  final HostProfile host;
  final PendingConnectionPhase phase;
  final Object? error;

  PendingTerminalConnection copyWith({
    PendingConnectionPhase? phase,
    Object? error,
  }) =>
      PendingTerminalConnection(
        id: id,
        host: host,
        phase: phase ?? this.phase,
        error: error ?? this.error,
      );
}

class SessionState {
  const SessionState({
    this.sessions = const [],
    this.activeIndex = 0,
    this.pendingConnections = const [],
    this.activePendingId,
    this.error,
  });

  static const _notProvided = Object();

  final List<ActiveTerminalSession> sessions;
  final int activeIndex;
  final List<PendingTerminalConnection> pendingConnections;
  final String? activePendingId;
  final Object? error;

  ActiveTerminalSession? get active => sessions.isEmpty
      ? null
      : sessions[activeIndex.clamp(0, sessions.length - 1)];

  PendingTerminalConnection? get selectedPending {
    for (final pending in pendingConnections) {
      if (pending.id == activePendingId) return pending;
    }
    return null;
  }

  int get tabCount => sessions.length + pendingConnections.length;

  SessionState copyWith({
    List<ActiveTerminalSession>? sessions,
    int? activeIndex,
    List<PendingTerminalConnection>? pendingConnections,
    Object? activePendingId = _notProvided,
    Object? error = _notProvided,
  }) =>
      SessionState(
        sessions: sessions ?? this.sessions,
        activeIndex: activeIndex ?? this.activeIndex,
        pendingConnections: pendingConnections ?? this.pendingConnections,
        activePendingId: identical(activePendingId, _notProvided)
            ? this.activePendingId
            : activePendingId as String?,
        error: identical(error, _notProvided) ? this.error : error,
      );
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
  bool _reconnecting = false;

  Future<void> connect(
    HostProfile host,
    HostKeyVerifier verifyHostKey, {
    KeyboardInteractiveHandler? keyboardInteractive,
  }) async {
    final sessionId = const Uuid().v4();
    final pending = PendingTerminalConnection(id: sessionId, host: host);
    state = state.copyWith(
      pendingConnections: [...state.pendingConnections, pending],
      activePendingId: sessionId,
      error: null,
    );
    try {
      final vault = await vaultController.ready();
      final connectionHost = host.data['_ephemeralTerminal'] == true
          ? host
          : vault.hosts.firstWhere(
              (value) => value.id == host.id,
              orElse: () => host,
            );
      final session = await service.connect(
        sessionId: sessionId,
        host: connectionHost,
        hosts: vault.hosts,
        keys: vault.keys,
        proxyProfiles: vault.proxyProfiles,
        verifyHostKey: verifyHostKey,
        keyboardInteractive: keyboardInteractive,
      );
      final sessions = [...state.sessions, session];
      final wasSelected = state.activePendingId == sessionId;
      state = state.copyWith(
        sessions: sessions,
        activeIndex: wasSelected ? sessions.length - 1 : state.activeIndex,
        pendingConnections: state.pendingConnections
            .where((value) => value.id != sessionId)
            .toList(growable: false),
        activePendingId: wasSelected ? null : state.activePendingId,
        error: null,
      );
      _watchSession(session);
      if (connectionHost.data['_ephemeralTerminal'] == true) {
        session.systemInfo = connectionHost.systemInfo;
      } else {
        unawaited(vaultController.markConnected(connectionHost));
        unawaited(_detectSystem(session, connectionHost));
      }
    } catch (error) {
      state = state.copyWith(
        pendingConnections: state.pendingConnections
            .map(
              (value) => value.id == sessionId
                  ? value.copyWith(
                      phase: PendingConnectionPhase.failed,
                      error: error,
                    )
                  : value,
            )
            .toList(growable: false),
        error: error,
      );
      rethrow;
    }
  }

  Future<void> openManagedTerminal(
    ActiveTerminalSession parent, {
    required String label,
    required String command,
  }) {
    final host = HostProfile({
      ...parent.host.data,
      'id': 'managed-${const Uuid().v4()}',
      'label': label,
      'startupCommand': command,
      '_ephemeralTerminal': true,
    });
    return connect(
      host,
      parent.verifyHostKey,
      keyboardInteractive: parent.keyboardInteractive,
    );
  }

  Future<void> reconnectDisconnected() async {
    if (_reconnecting ||
        state.pendingConnections.any(
          (value) => value.phase == PendingConnectionPhase.connecting,
        )) {
      return;
    }
    _reconnecting = true;
    try {
      for (final old in [...state.sessions]) {
        if (old.connected || old.closedByUser) continue;
        final index = state.sessions.indexWhere((value) => value.id == old.id);
        if (index < 0) continue;
        try {
          final vault = await vaultController.ready();
          old.terminal.write('\r\n\x1b[33m正在恢复连接…\x1b[0m\r\n');
          final replacement = await service.connect(
            sessionId: old.id,
            host: old.host,
            hosts: vault.hosts,
            keys: vault.keys,
            proxyProfiles: vault.proxyProfiles,
            verifyHostKey: old.verifyHostKey,
            keyboardInteractive: old.keyboardInteractive,
            terminal: old.terminal,
          );
          final sessions = [...state.sessions];
          final current = sessions.indexWhere((value) => value.id == old.id);
          if (current >= 0) sessions[current] = replacement;
          state = state.copyWith(
            sessions: sessions,
            activeIndex: state.activeIndex.clamp(0, sessions.length - 1),
            error: null,
          );
          _watchSession(replacement);
          unawaited(_detectSystem(replacement, old.host));
        } catch (error) {
          old.terminal.write('\r\n\x1b[31m恢复连接失败：$error\x1b[0m\r\n');
          state = state.copyWith(error: error);
        }
      }
    } finally {
      _reconnecting = false;
    }
  }

  void _watchSession(ActiveTerminalSession session) {
    unawaited(session.done.then((_) {
      if (session.closedByUser) return;
      session.connected = false;
      session.terminal.write('\r\n\x1b[33m连接已断开，返回前台后将自动重连。\x1b[0m\r\n');
      if (!mounted) return;
      state = state.copyWith(
        sessions: [...state.sessions],
      );
    }));
  }

  Future<void> _detectSystem(
    ActiveTerminalSession session,
    HostProfile host,
  ) async {
    if (!session.isSsh) return;
    if (host.data['_ephemeralTerminal'] == true) {
      session.systemInfo = host.systemInfo;
      return;
    }
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
      state = state.copyWith(
        sessions: [...state.sessions],
      );
    } on Object {
      // Detection is best effort and must never interrupt an SSH session.
    }
  }

  void activate(int index) {
    if (index < 0 || index >= state.tabCount) return;
    if (index < state.sessions.length) {
      state = state.copyWith(activeIndex: index, activePendingId: null);
      return;
    }
    final pending = state.pendingConnections[index - state.sessions.length];
    state = state.copyWith(activePendingId: pending.id);
  }

  void dismissPending(String id) {
    final pending =
        state.pendingConnections.where((value) => value.id == id).firstOrNull;
    if (pending == null || pending.phase == PendingConnectionPhase.connecting) {
      return;
    }
    state = state.copyWith(
      pendingConnections: state.pendingConnections
          .where((value) => value.id != id)
          .toList(growable: false),
      activePendingId:
          state.activePendingId == id ? null : state.activePendingId,
      error: null,
    );
  }

  Future<void> close(int index) async {
    if (index < 0 || index >= state.sessions.length) return;
    final sessions = [...state.sessions];
    final removed = sessions.removeAt(index);
    await removed.close();
    var activeIndex = state.activeIndex;
    if (index < activeIndex) {
      activeIndex--;
    } else if (index == activeIndex && activeIndex >= sessions.length) {
      activeIndex = sessions.length - 1;
    }
    state = state.copyWith(
      sessions: sessions,
      activeIndex:
          sessions.isEmpty ? 0 : activeIndex.clamp(0, sessions.length - 1),
    );
  }

  void send(String text, {bool enter = false}) {
    final session = state.active;
    if (session == null) return;
    session.terminal.textInput(enter ? '$text\r' : text);
  }
}
