import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/presentation/widgets/ai_markdown.dart';

void main() {
  testWidgets('inline code has rounded fill and wraps in narrow lists',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 740));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: Padding(
                    padding: EdgeInsets.all(20),
                    child: AiMarkdown(
                        '1. `journalctl -p err -b --no-pager | tail -30` then inspect the log.'))))));
    await tester.pumpAndSettle();
    final inline = find.byType(AiInlineCode);
    expect(inline, findsOneWidget);
    final container = tester.widget<Container>(
        find.descendant(of: inline, matching: find.byType(Container)).first);
    expect((container.decoration as BoxDecoration).borderRadius,
        BorderRadius.circular(5));
    expect(tester.getBottomRight(inline).dx, lessThanOrEqualTo(320));
    final text = tester.widget<SelectableText>(
        find.descendant(of: inline, matching: find.byType(SelectableText)));
    expect(text.data, 'journalctl -p err -b --no-pager | tail -30');
    expect(text.contextMenuBuilder, isNotNull);
    final selectable =
        find.descendant(of: inline, matching: find.byType(SelectableText));
    await tester
        .longPressAt(tester.getTopLeft(selectable) + const Offset(16, 8));
    await tester.pumpAndSettle();
    expect(find.text('Copy'), findsOneWidget);
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('highlighted code uses the standard selection copy menu',
      (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map)['text'] as String;
      }
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: AiMarkdown('```bash\necho "hello"\n```'))));
    final code = find.descendant(
        of: find.byType(AiCodeBlock), matching: find.byType(SelectableText));
    // The block fills the available width. Press the first word, not the
    // blank space at the centre of that full-width block.
    await tester.longPressAt(tester.getTopLeft(code) + const Offset(16, 8));
    await tester.pumpAndSettle();
    expect(find.text('Copy'), findsOneWidget);
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(copied, isNotEmpty);
    expect('echo "hello"\n', contains(copied!));
  });
  test('syntax spans preserve original code and color known languages', () {
    for (final dark in [true, false]) {
      for (final sample in {
        'bash': 'echo "hello"\n# note',
        'json': '{"value": 42, "ok": true}',
        'python': 'def hello():\n  return "hi"',
        'yaml': 'name: hello\ncount: 42',
        'js': 'const answer = 42;',
      }.entries) {
        final span = aiCodeSpan(sample.value, sample.key, dark: dark);
        expect(span.toPlainText(), sample.value);
        final colors = <Color>{};
        void visit(InlineSpan node) {
          if (node.style?.color != null) colors.add(node.style!.color!);
          if (node is TextSpan) node.children?.forEach(visit);
        }

        visit(span);
        expect(colors, isNotEmpty, reason: sample.key);
      }
    }
  });

  test('unknown languages and long code safely fall back to exact plain text',
      () {
    for (final code in ['some <raw> & "text"', 'echo x\n' * 5000]) {
      for (final language in ['', 'not-a-language', 'bash']) {
        expect(aiCodeSpan(code, language, dark: true).toPlainText(), code);
      }
    }
  });

  for (final brightness in Brightness.values) {
    testWidgets(
        'renders GFM and selectable code without narrow-screen overflow ($brightness)',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: const Scaffold(
              body: SingleChildScrollView(
                  child: Padding(
                      padding: EdgeInsets.all(12),
                      child: AiMarkdown(
                          '# Heading\n\n**Bold** and *italic* with `inline`\n\n'
                          '- First\n- Second\n\n> Quote\n\n'
                          '| Name | Status |\n| --- | --- |\n| nginx | running |\n\n'
                          '```bash\necho "hello"\nprintf "a very long line that should wrap safely on a narrow phone screen without losing any characters"\n```'))))));
      await tester.pumpAndSettle();
      expect(find.byType(Table), findsOneWidget);
      expect(find.byType(AiCodeBlock), findsOneWidget);
      final text = tester
          .widgetList<SelectableText>(find.byType(SelectableText))
          .map((t) => t.data ?? t.textSpan!.toPlainText())
          .join('\n');
      expect(text, contains('Heading'));
      expect(text, contains('Bold'));
      expect(text, isNot(contains('**Bold**')));
      expect(text, contains('echo "hello"'));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('remote images stay local and unsafe links are ignored',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: AiMarkdown(
                '![private image](https://example.invalid/tracker.png)\n\n[unsafe](javascript:alert(1))'))));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsNothing);
    expect(find.text('private image'), findsOneWidget);
    final markdown = tester.widget<MarkdownBody>(find.byType(MarkdownBody));
    markdown.onTapLink!('unsafe', 'javascript:alert(1)', '');
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    markdown.onTapLink!('safe', 'https://example.org/docs', '');
    await tester.pumpAndSettle();
    expect(find.text('https://example.org/docs'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });

  testWidgets('incomplete streamed fences render without enabling actions',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: AiMarkdown('Thinking **bold\n\n```bash\necho "unfinished'))));
    await tester.pumpAndSettle();
    expect(find.byType(FilledButton), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
