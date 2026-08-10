import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../infrastructure/ssh/ssh_service.dart';

enum ForwardKind { local, dynamic }

class ActivePortForward {
  ActivePortForward({
    required this.id,
    required this.kind,
    required this.localPort,
    this.remoteHost,
    this.remotePort,
    this.server,
    this.dynamic,
  });
  final String id;
  final ForwardKind kind;
  final int localPort;
  final String? remoteHost;
  final int? remotePort;
  final ServerSocket? server;
  final SSHDynamicForward? dynamic;

  Future<void> close() async {
    await server?.close();
    await dynamic?.close();
  }
}

final portForwardControllerProvider =
    StateNotifierProvider<PortForwardController, List<ActivePortForward>>(
      (ref) => PortForwardController(),
    );

class PortForwardController extends StateNotifier<List<ActivePortForward>> {
  PortForwardController() : super(const []);

  Future<void> startLocal({
    required ActiveTerminalSession session,
    required int localPort,
    required String remoteHost,
    required int remotePort,
  }) async {
    final client = session.sshClient;
    if (client == null) throw StateError('需要活动 SSH 会话');
    final server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      localPort,
    );
    server.listen((socket) async {
      try {
        final channel = await client.forwardLocal(remoteHost, remotePort);
        unawaited(socket.pipe(channel.sink));
        unawaited(channel.stream.pipe(socket));
      } catch (_) {
        socket.destroy();
      }
    });
    state = [
      ...state,
      ActivePortForward(
        id: 'local-${server.port}-$remoteHost-$remotePort',
        kind: ForwardKind.local,
        localPort: server.port,
        remoteHost: remoteHost,
        remotePort: remotePort,
        server: server,
      ),
    ];
  }

  Future<void> startDynamic({
    required ActiveTerminalSession session,
    required int localPort,
  }) async {
    final client = session.sshClient;
    if (client == null) throw StateError('需要活动 SSH 会话');
    final dynamic = await client.forwardDynamic(bindPort: localPort);
    state = [
      ...state,
      ActivePortForward(
        id: 'dynamic-${dynamic.port}',
        kind: ForwardKind.dynamic,
        localPort: dynamic.port,
        dynamic: dynamic,
      ),
    ];
  }

  Future<void> stop(String id) async {
    ActivePortForward? item;
    for (final value in state) {
      if (value.id == id) {
        item = value;
        break;
      }
    }
    await item?.close();
    state = state.where((value) => value.id != id).toList();
  }
}
