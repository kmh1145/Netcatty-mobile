import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/infrastructure/ssh/ssh_service.dart';

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
}
