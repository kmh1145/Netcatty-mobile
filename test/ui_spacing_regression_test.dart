import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/presentation/widgets/github_manual_config.dart';
import 'package:netcatty_mobile/presentation/widgets/sftp_permissions_dialog.dart';

void main() {
  testWidgets('permission help wraps fully with a keyboard and large text',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 740));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    int? result;
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(1.4),
              viewInsets: const EdgeInsets.only(bottom: 280)),
          child: child!),
      home: Builder(
          builder: (context) => Scaffold(
              body: TextButton(
                  onPressed: () async {
                    result = await showDialog<int>(
                        context: context,
                        builder: (_) => const SftpPermissionsDialog(
                            name: 'docker-compose.yml', initialMode: '644'));
                  },
                  child: const Text('open')))),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final help = find.byKey(const ValueKey('sftp-permissions-help'));
    await tester.ensureVisible(help);
    await tester.pumpAndSettle();
    final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(of: help, matching: find.byType(RichText)));
    expect(paragraph.didExceedMaxLines, false);
    expect(paragraph.size.height, greaterThan(30));
    expect(tester.takeException(), isNull);
    await tester.enterText(
        find.byKey(const ValueKey('sftp-permissions-input')), '755');
    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    expect(result, int.parse('755', radix: 8));
  });

  testWidgets('advanced GitHub fields have room for floating labels',
      (tester) async {
    final id = TextEditingController(text: 'example-gist');
    final secret = TextEditingController(text: 'example-secret');
    addTearDown(id.dispose);
    addTearDown(secret.dispose);
    await tester.binding.setSurfaceSize(const Size(320, 740));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SingleChildScrollView(
                child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: GitHubManualConfig(
                        resourceId: id,
                        secret: secret,
                        onSecretChanged: (_) {}))))));
    await tester.tap(find.text('高级 / 手动配置'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    final header = find.text('仅用于迁移或登录故障排查');
    expect(tester.getTopLeft(fields.first).dy - tester.getBottomLeft(header).dy,
        greaterThanOrEqualTo(18));
    expect(
        tester.getTopLeft(fields.last).dy -
            tester.getBottomLeft(fields.first).dy,
        greaterThanOrEqualTo(20));
    expect(tester.widget<TextField>(fields.last).obscureText, true);
    expect(tester.takeException(), isNull);
  });
}
