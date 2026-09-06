import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:netcatty_mobile/domain/models/settings.dart';
import 'package:netcatty_mobile/infrastructure/storage/vault_repository.dart';
import 'package:netcatty_mobile/presentation/widgets/sftp_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
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
    expect(find.text('1\n2\n3'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '{"a": 2}');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('Bad state: save failed'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '{"a": 2}');
    expect(find.text('* a.json'), findsOneWidget);
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
