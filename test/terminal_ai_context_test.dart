import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/infrastructure/ssh/terminal_picture_in_picture_service.dart';
import 'package:xterm2/xterm.dart';

void main() {
  test('terminal AI context joins wrapped lines and keeps recent output', () {
    final terminal = Terminal()..resize(8, 3);
    terminal.write('old line\r\n');
    terminal.write('another old line\r\n');
    terminal.write('abcdefghij\r\n');
    terminal.write('new result\r\n');

    final context = terminalAiContextText(
      terminal,
      maxLines: 2,
      maxColumns: 20,
    );

    expect(context, contains('abcdefghij'));
    expect(context, contains('new result'));
    expect(context, isNot(contains('old line')));
  });

  test('terminal AI context enforces its character limit', () {
    final terminal = Terminal()..resize(20, 3);
    terminal.write('first output\r\nsecond output\r\nlatest output');

    final context = terminalAiContextText(terminal, maxCharacters: 13);

    expect(context, 'latest output');
  });
}
