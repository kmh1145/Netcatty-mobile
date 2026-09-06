import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:netcatty_mobile/domain/models/settings.dart';
import 'package:netcatty_mobile/infrastructure/storage/vault_repository.dart';
import 'package:netcatty_mobile/presentation/widgets/sftp_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
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
    controller.dispose();
  });
}
