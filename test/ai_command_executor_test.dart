import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm2/xterm.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/infrastructure/ai/ai_command_executor.dart';
import 'package:netcatty_mobile/infrastructure/ai/ai_service.dart';
import 'package:netcatty_mobile/infrastructure/ssh/ssh_service.dart';

class _Channel extends Fake implements SSHSession {
  _Channel({String output = '', String error = '', this.code = 0, this.wait})
      : stdout = Stream.value(Uint8List.fromList(utf8.encode(output))),
        stderr = Stream.value(Uint8List.fromList(utf8.encode(error))) {
    input.stream.listen((_) {});
  }
  final input = StreamController<Uint8List>();
  final int? code;
  final Completer<void>? wait;
  bool closed = false;
  @override
  final Stream<Uint8List> stdout;
  @override
  final Stream<Uint8List> stderr;
  @override
  StreamSink<Uint8List> get stdin => input.sink;
  @override
  int? get exitCode => code;
  @override
  Future<void> get done => wait?.future ?? Future.value();
  @override
  void close() {
    closed = true;
    if (wait?.isCompleted == false) wait!.complete();
  }
}

class _Client extends Fake implements SSHClient {
  _Client(this.open);
  final Future<SSHSession> Function() open;
  String? command;
  @override
  Future<SSHSession> execute(String command,
      {SSHPtyConfig? pty,
      SSHX11Config? x11,
      Map<String, String>? environment}) {
    this.command = command;
    expect(pty, isNull);
    return open();
  }
}

ActiveTerminalSession _session(_Client client) => ActiveTerminalSession(
    id: 'session',
    host: HostProfile.create(
        id: 'host',
        label: 'test',
        hostname: 'example.test',
        username: 'user',
        port: 22022),
    terminal: Terminal(),
    verifyHostKey: (_, __, ___) async => true,
    keyboardInteractive: null,
    sshClients: [client]);

void main() {
  test('exec uses existing client, reports stdout stderr and failure code',
      () async {
    final channel =
        _Channel(output: 'some output', error: 'permission denied', code: 1);
    final client = _Client(() async => channel);
    final target = _session(client);
    final result = await executeAiCommand(target, 'command', AiCancellation());
    expect(client.command, 'command');
    expect(result.stdout, 'some output');
    expect(result.stderr, 'permission denied');
    expect(result.exitCode, 1);
    expect(channel.closed, true);
    expect(target.connected, true);
  });
  test('large output is bounded without losing exit status', () async {
    final channel = _Channel(output: 'x' * 30000);
    final result = await executeAiCommand(
        _session(_Client(() async => channel)), 'log', AiCancellation());
    expect(result.stdout.length, 12000);
    expect(result.truncated, true);
    expect(result.exitCode, 0);
  });
  test('cancel closes exec channel without closing terminal transport',
      () async {
    final channel = _Channel(wait: Completer<void>());
    final token = AiCancellation();
    final target = _session(_Client(() async => channel));
    final result = executeAiCommand(target, 'long-running', token);
    final assertion = expectLater(result, throwsA(isA<AiCancelled>()));
    await Future<void>.delayed(Duration.zero);
    token.cancel();
    await assertion;
    expect(channel.closed, true);
    expect(target.connected, true);
  });
  test('channel opened after cancellation is closed', () async {
    final pending = Completer<SSHSession>();
    final token = AiCancellation();
    final result =
        executeAiCommand(_session(_Client(() => pending.future)), 'cmd', token);
    final assertion = expectLater(result, throwsA(isA<AiCancelled>()));
    token.cancel();
    await assertion;
    final channel = _Channel();
    pending.complete(channel);
    await Future<void>.delayed(Duration.zero);
    expect(channel.closed, true);
    await channel.input.close();
  });
}
