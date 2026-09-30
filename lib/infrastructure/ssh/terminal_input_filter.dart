import 'ssh_service.dart';

/// Collapses the duplicate Enter that the iOS soft keyboard produces.
///
/// A single tap on the iOS keyboard return key reaches the terminal through two
/// independent platform paths, and both end up on the wire:
///
/// 1. `TextInputClient.updateEditingValue` inserting the newline. xterm sends
///    the character itself when it is not a mapped key, so a bare LF arrives.
/// 2. `TextInputClient.performAction(TextInputAction.newline)`, which xterm
///    resolves through its key table and sends as CR.
///
/// A remote shell then sees two Enter presses for one tap and runs the command
/// twice, which is the reported iOS symptom.
///
/// Android reports the return key only once (through `performAction`), but the
/// filter stays platform independent so the production call path is exercised
/// by the regular test suite instead of depending on the host platform.
///
/// A real second press is never lost: [duplicateEnterWindow] is shorter than
/// the delay before a held return key starts repeating, so `kubectl get po`
/// followed by a deliberate second Enter, or a held-down return key, still
/// deliver every line ending the user asked for.
class TerminalOutputSink {
  TerminalOutputSink({
    required TerminalInputController input,
    required void Function(String value) send,
    Duration Function() now = systemClock,
  })  : _input = input,
        _send = send,
        _now = now;

  /// Upper bound for two line endings that describe one physical key press.
  ///
  /// The two iOS paths for one tap are dispatched from the same text input
  /// batch, so they normally land microseconds apart; the window only has to
  /// absorb a frame boundary or a busy main thread. It stays far below the
  /// roughly 500 ms delay before a held return key starts repeating, so a held
  /// or double-tapped Enter is still delivered.
  static const duplicateEnterWindow = Duration(milliseconds: 100);

  /// Monotonic clock used to compare line endings. Tests replace it so the
  /// window can be exercised without real delays.
  static Duration systemClock() => Duration(
        microseconds: DateTime.now().microsecondsSinceEpoch,
      );

  final TerminalInputController _input;
  final void Function(String value) _send;
  final Duration Function() _now;

  Duration? _lastLineEnding;

  /// Entry point for `Terminal.onOutput`.
  ///
  /// The toolbar modifiers from [TerminalInputController] are applied first,
  /// then the iOS duplicate Enter is removed. Nothing is written when the whole
  /// chunk was a duplicate.
  void write(String value) {
    final filtered = _filter(_input.consume(value));
    if (filtered.isNotEmpty) _send(filtered);
  }

  String _filter(String value) {
    if (value.isEmpty) return value;
    final lineEnding = _soleLineEnding(value);
    if (lineEnding == null) {
      // Typed text and pasted blocks keep every character, and they do not arm
      // the window: only a chunk that is nothing but a line ending can describe
      // a return key press.
      return value;
    }
    final previous = _lastLineEnding;
    final instant = _now();
    // The insert path and the action path of one tap do not agree on the
    // sequence (LF versus CR), so any line ending arriving inside the window is
    // the second report of the same tap.
    if (previous != null && instant - previous < duplicateEnterWindow) {
      return '';
    }
    _lastLineEnding = instant;
    return value;
  }

  /// Returns the line ending when [value] consists of exactly one, otherwise
  /// null. `\r\n` counts as a single ending so a duplicated CRLF pair under
  /// `CSI 20 h` line feed mode is compared as a unit.
  static String? _soleLineEnding(String value) {
    if (value == '\r' || value == '\n' || value == '\r\n') return value;
    return null;
  }
}

/// Connects `Terminal.onOutput` to the remote shell for every connection type,
/// so the one-shot toolbar modifiers and the iOS Enter coalescing behave the
/// same for SSH and Telnet. The returned sink owns the filter state and stays
/// referenced by the terminal for the lifetime of the session.
TerminalOutputSink bindTerminalOutput(
  TerminalInputController input,
  void Function(String value) send, {
  Duration Function() now = TerminalOutputSink.systemClock,
}) =>
    TerminalOutputSink(input: input, send: send, now: now);
