import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:netcatty_mobile/domain/models/settings.dart';
import 'package:netcatty_mobile/infrastructure/storage/vault_repository.dart';
import 'package:netcatty_mobile/presentation/widgets/sftp_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final scale in [1.0, 1.8]) {
      testWidgets('gutter follows actual $platform layout at scale $scale',
          (tester) async {
        SharedPreferences.setMockInitialValues({});
        final repo = await VaultRepository.open();
        await tester.binding.setSurfaceSize(const Size(390, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final content =
            '${List.filled(8, 'long code 中文 👩‍💻 with spaces ').join()}\r\n\n'
            'const value = "another long line of highlighted code";\nlast\n';
        await tester.pumpWidget(ProviderScope(
            overrides: [vaultRepositoryProvider.overrideWithValue(repo)],
            child: MaterialApp(
                theme: ThemeData(
                    platform: platform,
                    textTheme: const TextTheme(
                        bodyLarge: TextStyle(letterSpacing: 1.4))),
                builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context)
                        .copyWith(textScaler: TextScaler.linear(scale)),
                    child: child!),
                home: SftpEditor(
                    name: 'sample.dart',
                    content: content,
                    onSave: (_) async {}))));
        await tester.pumpAndSettle();

        void verify() {
          final gutter = tester.renderObject<RenderEditorLineNumbers>(
              find.byType(EditorLineNumbers));
          final RenderEditable editable = tester
              .state<EditableTextState>(find.byType(EditableText))
              .renderEditable;
          final text = tester
              .widget<EditableText>(find.byType(EditableText))
              .controller
              .text;
          final origin = MatrixUtils.transformPoint(
              editable.getTransformTo(gutter), Offset.zero);
          final first =
              editable.getLocalRectForCaret(const TextPosition(offset: 0)).top;
          var offset = 0;
          final lines = text.split('\n');
          expect(gutter.lineOffsets.keys,
              List.generate(lines.length, (i) => i + 1));
          for (var i = 0; i < lines.length; i++) {
            final caret =
                editable.getLocalRectForCaret(TextPosition(offset: offset));
            expect(gutter.lineOffsets[i + 1],
                closeTo(origin.dy + caret.top - first, 0.01));
            offset += lines[i].length + 1;
          }
          expect(tester.takeException(), isNull);
        }

        verify(); // Includes accidental wrapping from inherited letter spacing.
        await tester.tap(find.byKey(const ValueKey('editor-wrap-toggle')));
        await tester.pumpAndSettle();
        verify();
        await tester.binding.setSurfaceSize(const Size(320, 800));
        await tester.pumpAndSettle();
        verify();
        await tester.enterText(find.byKey(const ValueKey('sftp-editor-field')),
            'new line\n$content');
        await tester.pumpAndSettle();
        verify();
      });
    }
  }
  test('file search supports literal, case, whole-word, regex and limits', () {
    var result = findEditorMatches('Alpha alpha alphabet', 'alpha');
    expect(result.matches.map((e) => '${e.start}:${e.end}'),
        ['0:5', '6:11', '12:17']);
    result =
        findEditorMatches('Alpha alpha alphabet', 'alpha', caseSensitive: true);
    expect(result.matches, [
      const TextRange(start: 6, end: 11),
      const TextRange(start: 12, end: 17)
    ]);
    result = findEditorMatches('Alpha alpha alphabet', 'alpha',
        mode: EditorSearchMode.wholeWord);
    expect(result.matches, hasLength(2));
    expect(
        findEditorMatches('猫 猫咪 猫', '猫', mode: EditorSearchMode.wholeWord)
            .matches,
        hasLength(2));
    result = findEditorMatches('one 12 two 345', r'\d+',
        mode: EditorSearchMode.regularExpression);
    expect(result.matches, [
      const TextRange(start: 4, end: 6),
      const TextRange(start: 11, end: 14)
    ]);
    expect(
        findEditorMatches('text', '[', mode: EditorSearchMode.regularExpression)
            .error,
        '正则表达式无效');
    result = findEditorMatches('aaaa', 'a', limit: 2);
    expect(result.matches, hasLength(2));
    expect(result.truncated, isTrue);
    expect(
        findEditorMatches('aaa', r'.*?',
                mode: EditorSearchMode.regularExpression)
            .matches,
        isEmpty);
  });

  test('line labels preserve logical numbering across visual wraps', () {
    const style = TextStyle(fontFamily: 'monospace', fontSize: 14, height: 1.5);
    const text =
        'this is a deliberately long first source line that must wrap\nsecond';
    expect(buildEditorLineLabels(text, style, TextScaler.noScaling), '1\n2');

    final wrapped = buildEditorLineLabels(
      text,
      style,
      TextScaler.noScaling,
      wrapWidth: 90,
    ).split('\n');
    expect(wrapped.first, '1');
    expect(wrapped.last, '2');
    expect(wrapped.where((label) => label == '1'), hasLength(1));
    expect(wrapped.where((label) => label == '2'), hasLength(1));
    expect(wrapped.where((label) => label.isEmpty), isNotEmpty);

    final enlarged = buildEditorLineLabels(
      text,
      style.copyWith(fontSize: 28),
      TextScaler.noScaling,
      wrapWidth: 90,
    ).split('\n');
    expect(enlarged.length, greaterThan(wrapped.length));
    expect(
        editorVisualRowForOffset(
          text,
          text.indexOf('second'),
          style,
          TextScaler.noScaling,
          wrapWidth: 90,
        ),
        wrapped.length - 1);
  });

  testWidgets(
      'editor searches, navigates, changes match mode and reports errors',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final repo = await VaultRepository.open();
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
        overrides: [vaultRepositoryProvider.overrideWithValue(repo)],
        child: MaterialApp(
            home: SftpEditor(
                name: 'sample.txt',
                content: 'foo\nbar foo\nFOO',
                onSave: (_) async {}))));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editor-search-toggle')));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(
        find.byKey(const ValueKey('editor-search-field')), 'foo');
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('1 / 3'), findsOneWidget);
    var editor = tester.widget<TextField>(find.byType(TextField).last);
    expect(editor.controller!.selection,
        const TextSelection(baseOffset: 0, extentOffset: 3));
    await tester.tap(find.byTooltip('下一个匹配'));
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('2 / 3'), findsOneWidget);
    editor = tester.widget<TextField>(find.byType(TextField).last);
    expect(editor.controller!.selection,
        const TextSelection(baseOffset: 8, extentOffset: 11));
    await tester.tap(find.byKey(const ValueKey('editor-search-case')));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('1 / 2'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('editor-search-mode')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('正则表达式').last);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(
        find.byKey(const ValueKey('editor-search-field')), '[');
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('正则表达式无效'), findsOneWidget);
  });

  test('highlight preference persists and defaults on', () {
    expect(AppSettings.fromJson({}).sftpSyntaxHighlight, isTrue);
    final value = const AppSettings().copyWith(sftpSyntaxHighlight: false);
    expect(AppSettings.fromJson(value.toJson()).sftpSyntaxHighlight, isFalse);
  });
  testWidgets('editor preserves text, numbers lines and retains failed saves',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final repo = await VaultRepository.open();
    await tester.pumpWidget(ProviderScope(
        overrides: [vaultRepositoryProvider.overrideWithValue(repo)],
        child: MaterialApp(
            home: SftpEditor(
                name: 'a.json',
                content: '{\n"a": 1\n}',
                onSave: (_) async {
                  throw StateError('save failed');
                }))));
    await tester.pumpAndSettle();
    expect(
        tester
            .renderObject<RenderEditorLineNumbers>(
                find.byType(EditorLineNumbers))
            .lineOffsets
            .keys,
        [1, 2, 3]);
    await tester.enterText(find.byType(TextField), '{"a": 2}');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('Bad state: save failed'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '{"a": 2}');
    expect(find.text('* a.json'), findsOneWidget);
  });

  testWidgets(
      'editor is borderless, wraps with logical line labels and pinch zooms',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final repo = await VaultRepository.open();
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const content =
        'this is a deliberately very long source line repeated repeated repeated repeated repeated repeated repeated repeated\nsecond';
    await tester.pumpWidget(ProviderScope(
        overrides: [vaultRepositoryProvider.overrideWithValue(repo)],
        child: MaterialApp(
            home: SftpEditor(
                name: 'long.txt', content: content, onSave: (_) async {}))));
    await tester.pumpAndSettle();

    RenderEditorLineNumbers gutter() => tester
        .renderObject<RenderEditorLineNumbers>(find.byType(EditorLineNumbers));
    var editor = tester
        .widget<TextField>(find.byKey(const ValueKey('sftp-editor-field')));
    final decoration = editor.decoration!;
    expect(decoration.border, InputBorder.none);
    expect(decoration.enabledBorder, InputBorder.none);
    expect(decoration.focusedBorder, InputBorder.none);
    expect(decoration.filled, isFalse);
    expect(gutter().lineOffsets.keys, [1, 2]);
    final unwrappedSpacing =
        gutter().lineOffsets[2]! - gutter().lineOffsets[1]!;
    expect(
        tester.getSize(find.byKey(const ValueKey('editor-line-numbers'))).width,
        lessThan(40));
    final initialEditorWidth =
        tester.getSize(find.byKey(const ValueKey('sftp-editor-field'))).width;
    final measuredLongestLine = editorLongestLineWidth(
      content,
      const TextStyle(fontFamily: 'monospace', fontSize: 14, height: 1.5),
      TextScaler.noScaling,
    );
    expect(initialEditorWidth, greaterThan(measuredLongestLine + 14));

    await tester.tap(find.byKey(const ValueKey('editor-wrap-toggle')));
    await tester.pumpAndSettle();
    expect(gutter().lineOffsets.keys, [1, 2]);
    expect(gutter().lineOffsets[2]! - gutter().lineOffsets[1]!,
        greaterThan(unwrappedSpacing));

    final zoomArea = find.byKey(const ValueKey('editor-zoom-area'));
    final center = tester.getCenter(zoomArea);
    final first =
        await tester.startGesture(center - const Offset(20, 0), pointer: 1);
    final second =
        await tester.startGesture(center + const Offset(20, 0), pointer: 2);
    await first.moveTo(center - const Offset(50, 0));
    await second.moveTo(center + const Offset(50, 0));
    await tester.pump();
    editor = tester
        .widget<TextField>(find.byKey(const ValueKey('sftp-editor-field')));
    expect(editor.style!.fontSize, greaterThan(14));
    expect(
        tester
            .widget<EditorLineNumbers>(find.byType(EditorLineNumbers))
            .style
            .fontSize,
        editor.style!.fontSize);
    expect(find.byKey(const ValueKey('editor-font-size')), findsOneWidget);
    await first.up();
    await second.up();
    await tester.pump();
    expect(find.byKey(const ValueKey('editor-font-size')), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('highlight toggles colors while preserving exact text',
      (tester) async {
    late BuildContext context;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) {
      context = c;
      return const SizedBox();
    })));
    final controller =
        CodeTextController(text: '{"key": true}', filename: 'a.json');
    final highlighted =
        controller.buildTextSpan(context: context, withComposing: true);
    expect(highlighted.toPlainText(), controller.text);
    expect(
        highlighted.children!
            .whereType<TextSpan>()
            .any((s) => s.style?.color != null),
        isTrue);
    controller.highlight = false;
    final plain =
        controller.buildTextSpan(context: context, withComposing: true);
    expect(plain.toPlainText(), controller.text);
    expect(plain.children, isNull);
    controller.searchMatches = const [TextRange(start: 2, end: 5)];
    controller.currentSearchIndex = 0;
    final searched =
        controller.buildTextSpan(context: context, withComposing: true);
    expect(searched.toPlainText(), controller.text);
    expect(
        searched.children!
            .whereType<TextSpan>()
            .any((span) => span.style?.backgroundColor != null),
        isTrue);
    controller.dispose();
  });
}
