import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/infrastructure/ssh/ssh_service.dart';
import 'package:netcatty_mobile/infrastructure/ssh/terminal_input_filter.dart';
import 'package:xterm2/xterm.dart';

void main() {
  test('Ctrl modifier transforms the next soft-keyboard character', () {
    final input = TerminalInputController()..setModifiers(['ctrl']);

    expect(input.consume('c'), '\x03');
    expect(input.modifiers, isEmpty);
    expect(input.consume('c'), 'c');
  });

  test('Alt and Ctrl modifiers transform terminal navigation keys', () {
    final input = TerminalInputController()..setModifiers(['alt', 'ctrl']);

    expect(input.consume('\x1b[A'), '\x1b[1;7A');
    expect(input.modifiers, isEmpty);
  });

  test('empty IME updates do not consume a pending modifier', () {
    final input = TerminalInputController()..setModifiers(['ctrl']);

    expect(input.consume(''), '');
    expect(input.modifiers, {'ctrl'});
  });

  group('iOS double enter filter', () {
    late Duration clock;
    late List<String> sent;
    late TerminalInputController input;
    late TerminalOutputSink sink;

    setUp(() {
      clock = const Duration(seconds: 1);
      sent = <String>[];
      input = TerminalInputController();
      sink = bindTerminalOutput(input, sent.add, now: () => clock);
    });

    test('keeps a single return', () {
      sink.write('\r');
      expect(sent, ['\r']);
    });

    test('keeps a single newline', () {
      sink.write('\n');
      expect(sent, ['\n']);
    });

    test('drops the duplicated line ending of one iOS key press', () {
      // The insert path (LF) and the action path (CR) arrive within the window
      // for one tap, so the second arrival must not reach the shell.
      clock += const Duration(milliseconds: 3);
      sink.write('\n');
      sink.write('\r');
      expect(sent, ['\n']);
    });

    test('drops the second return of one iOS key press', () {
      // The insert path and the action path arrive back-to-back for one tap.
      clock += const Duration(milliseconds: 3);
      sink.write('\r');
      sink.write('\r');
      expect(sent, ['\r']);
    });

    test('drops the duplicated newline of one iOS key press', () {
      // Both emitters use the same sequence, so an LF pair collapses as well.
      sink.write('\n');
      sink.write('\n');
      expect(sent, ['\n']);
    });

    test('keeps two deliberate returns', () {
      sink.write('\r');
      clock += const Duration(milliseconds: 180);
      sink.write('\r');
      expect(sent, ['\r', '\r']);
    });

    test('keeps a held return key repeat', () {
      // A repeat is always slower than the duplicate window, so every line the
      // user asks for is delivered even while the key is held down.
      for (var repeat = 0; repeat < 3; repeat++) {
        clock += const Duration(milliseconds: 120);
        sink.write('\r');
      }
      expect(sent, ['\r', '\r', '\r']);
    });

    test('keeps a chunk that carries text as well as a line ending', () {
      sink.write('uptime\r');
      expect(sent, ['uptime\r']);
    });

    test('never collapses line endings inside one chunk', () {
      sink.write('a\rb\r\nc\n');
      expect(sent, ['a\rb\r\nc\n']);
    });

    test('keeps different line endings apart from each other', () {
      sink.write('first\n');
      clock += const Duration(milliseconds: 3);
      sink.write('second\r\n');
      expect(sent, ['first\n', 'second\r\n']);
    });

    test('keeps a pasted block apart from the next line ending', () {
      sink.write('make\nmake test\n');
      clock += const Duration(milliseconds: 3);
      sink.write('\r');
      expect(sent, ['make\nmake test\n', '\r']);
    });

    test('drops a duplicated CRLF pair under line feed mode', () {
      sink.write('\r\n');
      sink.write('\r\n');
      expect(sent, ['\r\n']);
    });

    test('applies toolbar modifiers before the enter filter', () {
      input.setModifiers(['shift']);
      sink.write('c');
      sink.write('\r');
      expect(sent, ['C', '\r']);
      expect(input.modifiers, isEmpty);
    });

    test('leaves ordinary input untouched', () {
      sink.write('ls -la');
      sink.write('');
      sink.write('\x03');
      expect(sent, ['ls -la', '\x03']);
    });
  });

  testWidgets('third-party IME newline action sends terminal enter',
      (tester) async {
    final output = <String>[];
    final terminal = Terminal()..onOutput = output.add;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalView(terminal, autofocus: true),
        ),
      ),
    );
    await tester.pump();

    expect(tester.testTextInput.isVisible, isTrue);
    await tester.testTextInput.receiveAction(TextInputAction.newline);
    await tester.pump();

    expect(output, contains('\r'));
  });

  testWidgets('iOS return key reaches the shell as exactly one enter',
      (tester) async {
    final output = <String>[];
    final terminal = Terminal();
    var clock = const Duration(seconds: 1);
    // Exactly the production wiring from ssh_service, with a controllable clock
    // so the one-tap window does not depend on how long the test host needs
    // between the two platform messages.
    terminal.onOutput = bindTerminalOutput(
      TerminalInputController(),
      output.add,
      now: () => clock,
    ).write;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TerminalView(terminal, autofocus: true, deleteDetection: true),
        ),
      ),
    );
    await tester.pump();

    // One iOS tap on the return key reports the newline twice: the insert path
    // sends LF and the newline action sends CR, so the shell would run the
    // command twice. Only the first arrival may survive.
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '  \n',
        selection: TextSelection.collapsed(offset: 3),
      ),
    );
    await tester.pump();
    clock += const Duration(milliseconds: 35);
    await tester.testTextInput.receiveAction(TextInputAction.newline);
    await tester.pump();

    expect(output, ['\n']);
  });
}
