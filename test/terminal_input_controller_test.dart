import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/infrastructure/ssh/ssh_service.dart';
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
}
