import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:xterm/xterm.dart';

import '../../domain/models/host.dart';

typedef HostKeyVerifier =
    Future<bool> Function(String algorithm, String fingerprint);

typedef KeyboardInteractiveHandler =
    Future<List<String>?> Function(
      String name,
      String instruction,
      List<({String text, bool echo})> prompts,
    );

class ActiveTerminalSession {
  ActiveTerminalSession({
    required this.host,
    required this.terminal,
    this.sshClient,
    this.sshSession,
    this.telnetSocket,
  });

  final HostProfile host;
  final Terminal terminal;
  final SSHClient? sshClient;
  final SSHSession? sshSession;
  final Socket? telnetSocket;

  bool get isSsh => sshClient != null;

  Future<void> close() async {
    sshSession?.close();
    sshClient?.close();
    await telnetSocket?.close();
  }
}

class SshService {
  Future<ActiveTerminalSession> connect({
    required HostProfile host,
    required List<SshKeyProfile> keys,
    required HostKeyVerifier verifyHostKey,
    KeyboardInteractiveHandler? keyboardInteractive,
  }) async {
    if (host.protocol == HostProtocol.telnet) {
      return _connectTelnet(host);
    }
    if (host.protocol == HostProtocol.mosh) {
      throw UnsupportedError('Mosh 需要平台原生 UDP 运行时；当前构建请先使用 SSH。');
    }
    final socket = await SSHSocket.connect(
      host.hostname,
      host.port,
      timeout: Duration(
        seconds:
            (host.data['sshTcpConnectTimeoutSeconds'] as num?)?.toInt() ?? 15,
      ),
    );
    final identity = keys.cast<SshKeyProfile?>().firstWhere(
      (value) => value?.id == host.identityFileId,
      orElse: () => null,
    );
    final identities = identity == null || identity.privateKey.isEmpty
        ? null
        : SSHKeyPair.fromPem(identity.privateKey, identity.passphrase);
    final client = SSHClient(
      socket,
      username: host.username,
      identities: identities,
      onPasswordRequest: host.password == null ? null : () => host.password,
      onUserInfoRequest: (request) async {
        if (keyboardInteractive != null) {
          return keyboardInteractive(
            request.name,
            request.instruction,
            request.prompts
                .map((prompt) => (text: prompt.promptText, echo: prompt.echo))
                .toList(),
          );
        }
        return request.prompts
            .map((prompt) => prompt.echo ? '' : (host.password ?? ''))
            .toList();
      },
      keepAliveInterval: Duration(
        seconds: (host.data['keepaliveInterval'] as num?)?.toInt() ?? 10,
      ),
      authTimeout: Duration(
        seconds:
            (host.data['sshAuthReadyTimeoutSeconds'] as num?)?.toInt() ?? 30,
      ),
      onVerifyHostKey: (type, fingerprint) =>
          verifyHostKey(type, utf8.decode(fingerprint)),
    );
    final environment = <String, String>{};
    for (final value
        in host.data['environmentVariables'] as List? ?? const []) {
      if (value is Map && value['name'] != null) {
        environment[value['name'].toString()] =
            value['value']?.toString() ?? '';
      }
    }
    final session = await client.shell(
      pty: const SSHPtyConfig(type: 'xterm-256color', width: 80, height: 24),
      environment: environment,
    );
    final terminal = Terminal(maxLines: 10000);
    terminal.onOutput = (value) =>
        session.write(Uint8List.fromList(utf8.encode(value)));
    terminal.onResize = (width, height, pixelWidth, pixelHeight) {
      session.resizeTerminal(width, height, pixelWidth, pixelHeight);
    };
    session.stdout.listen(
      (data) => terminal.write(utf8.decode(data, allowMalformed: true)),
    );
    session.stderr.listen(
      (data) => terminal.write(utf8.decode(data, allowMalformed: true)),
    );
    unawaited(
      session.done.then((_) => terminal.write('\r\n\x1b[33m连接已关闭\x1b[0m\r\n')),
    );
    final startup = host.startupCommand;
    if (startup != null && startup.isNotEmpty) {
      session.write(Uint8List.fromList(utf8.encode('$startup\n')));
    }
    return ActiveTerminalSession(
      host: host,
      terminal: terminal,
      sshClient: client,
      sshSession: session,
    );
  }

  Future<ActiveTerminalSession> _connectTelnet(HostProfile host) async {
    final socket = await Socket.connect(
      host.hostname,
      host.port,
      timeout: const Duration(seconds: 15),
    );
    final terminal = Terminal(maxLines: 10000);
    terminal.onOutput = (value) => socket.add(utf8.encode(value));
    socket.listen((bytes) {
      final visible = <int>[];
      for (var i = 0; i < bytes.length; i++) {
        if (bytes[i] == 255 && i + 2 < bytes.length) {
          final command = bytes[i + 1];
          final option = bytes[i + 2];
          socket.add([255, command == 253 ? 252 : 254, option]);
          i += 2;
        } else {
          visible.add(bytes[i]);
        }
      }
      terminal.write(utf8.decode(visible, allowMalformed: true));
    });
    return ActiveTerminalSession(
      host: host,
      terminal: terminal,
      telnetSocket: socket,
    );
  }
}
