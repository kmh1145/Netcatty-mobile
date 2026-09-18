import 'dart:async';
import 'dart:convert';

import '../ssh/ssh_service.dart';
import 'ai_service.dart';

class AiCommandResult {
  const AiCommandResult(
      {required this.stdout,
      required this.stderr,
      required this.exitCode,
      this.truncated = false});
  final String stdout, stderr;
  final int? exitCode;
  final bool truncated;
  String get text => 'Exit code: ${exitCode ?? "unknown"}\n'
      'STDOUT:\n$stdout\nSTDERR:\n$stderr${truncated ? "\n[输出已截断]" : ""}';
}

/// Reuses the authenticated transport (including its jump/proxy/port), never
/// injects markers or execution into an interactive shell / tmux session.
Future<AiCommandResult> executeAiCommand(ActiveTerminalSession session,
    String command, AiCancellation cancellation) async {
  final client = session.sshClient;
  if (!session.connected || client == null) throw StateError('当前 SSH 连接不可用');
  cancellation.check();
  final pending = client.execute(command);
  // A channel may open after cancellation or timeout. Close that late channel.
  var abandoned = false;
  unawaited(pending.then((channel) {
    if (abandoned || cancellation.isCancelled) channel.close();
  }, onError: (Object _) {}));
  final process = await cancellation
      .bind(pending.timeout(const Duration(seconds: 15)))
      .catchError((Object error) {
    abandoned = true;
    throw error;
  });
  final out = StringBuffer(), err = StringBuffer();
  var truncated = false;
  void collect(StringBuffer buffer, String text) {
    final remaining = 12000 - buffer.length;
    if (text.length > remaining) truncated = true;
    if (remaining > 0) {
      buffer
          .write(text.length > remaining ? text.substring(0, remaining) : text);
    }
  }

  try {
    // Close stdin immediately: interactive/password commands must not hang or
    // consume keystrokes intended for the user's terminal.
    await cancellation
        .bind(process.stdin.close().timeout(const Duration(seconds: 5)));
    await cancellation.bind(Future.wait([
      const Utf8Decoder(allowMalformed: true)
          .bind(process.stdout)
          .forEach((s) => collect(out, s)),
      const Utf8Decoder(allowMalformed: true)
          .bind(process.stderr)
          .forEach((s) => collect(err, s)),
      process.done,
    ]).timeout(const Duration(seconds: 60)));
    return AiCommandResult(
        stdout: out.toString(),
        stderr: err.toString(),
        exitCode: process.exitCode,
        truncated: truncated);
  } finally {
    // Closing a channel does not guarantee detached remote processes stop.
    process.close();
  }
}
