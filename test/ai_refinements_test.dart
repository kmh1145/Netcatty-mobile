import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/domain/models/settings.dart';
import 'package:netcatty_mobile/infrastructure/ai/ai_reply_parser.dart';
import 'package:netcatty_mobile/infrastructure/ai/ai_workspace.dart';
import 'package:netcatty_mobile/presentation/widgets/ai_panel.dart';
import 'package:netcatty_mobile/presentation/widgets/ai_providers_page.dart';

void main() {
  late Map<String, String?> values;
  late AiWorkspace workspace;
  setUp(() {
    values = {};
    workspace = AiWorkspace(
        read: (key) async => values[key],
        write: (key, value) async {
          values[key] = value;
        });
  });

  test('legacy migration preserves key, selected model and existing provider',
      () async {
    await workspace.saveProfiles([
      const AiProviderProfile(
          id: 'other',
          name: 'Other',
          endpoint: 'https://example.test/v1',
          models: ['other'])
    ]);
    await workspace.setActiveProfile('other');
    const settings =
        AppSettings(aiModel: 'custom', aiModels: ['custom', 'second']);
    await workspace.migrateLegacyProvider(settings, 'private-key');
    final profiles = await workspace.profiles();
    expect(profiles, hasLength(2));
    expect(profiles.last.apiKey, 'private-key');
    expect(profiles.last.models, ['custom', 'second']);
    expect(await workspace.preferredModel(profiles.last.id), 'custom');
    expect(await workspace.activeProfile(), 'other');
    await workspace.saveProfiles([]);
    await workspace.migrateLegacyProvider(settings, 'private-key');
    expect(await workspace.profiles(), isEmpty);
  });

  test('unconfigured defaults do not create a hidden provider', () async {
    await workspace.migrateLegacyProvider(const AppSettings(), '');
    expect(await workspace.profiles(), isEmpty);
  });

  test(
      'JSON, prose-wrapped JSON, command arrays and shell fences are recognized',
      () {
    final json = jsonEncode({
      'message': 'inspect',
      'commands': [
        'pwd',
        {'command': 'ls -la'}
      ]
    });
    for (final input in [
      json,
      'Here is the plan:\n```json\n$json\n```',
      'Answer: $json done'
    ]) {
      expect(parseAiReply(input).command, 'pwd\nls -la');
    }
    expect(
        parseAiReply('Run:\n```bash\npwd\n```\nThen:\n```sh\nls -la\n```')
            .command,
        'pwd\nls -la');
    expect(
        parseAiReply('before ${jsonEncode({
              'message': 'x',
              'command': 'echo "{ok}"'
            })} after')
            .command,
        'echo "{ok}"');
  });

  test(
      'configuration, output, incomplete fences and non-string JSON stay inert',
      () {
    for (final input in [
      '```yaml\nservice: nginx\n```',
      '```text\nrm -rf example\n```',
      '```bash\nreboot',
      'plain explanatory text',
      '{"command":false}',
      '{"command":12}'
    ]) {
      expect(parseAiReply(input).command, isNull);
    }
  });

  test('unlabelled and inline suggestions are conservatively recognized', () {
    expect(parseAiReply('Run:\n```\npwd\nls -la\n```').command, 'pwd\nls -la');
    expect(parseAiReply('Run `df -h` to check disk.').command, 'df -h');
    expect(
        parseAiReply('See `/etc/nginx/nginx.conf` for configuration.').command,
        isNull);
    expect(parseAiReply('```\nservice: nginx\n```').command, isNull);
    expect(
        parseAiReply(jsonEncode({'message': 'Run:\n```sh\npwd\n```'})).command,
        'pwd');
  });

  testWidgets('risk notice requires explicit acknowledgement and persists it',
      (tester) async {
    final results = <bool>[];
    workspace = AiWorkspace(
        read: (key) async => values[key],
        write: (key, value) async {
          values[key] = value;
        });
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (context) => Scaffold(
                body: TextButton(
                    onPressed: () async {
                      results.add(await confirmAiRisk(context, workspace));
                    },
                    child: const Text('open'))))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(results, [false]);
    expect(await workspace.riskAcknowledged(), false);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('了解了'));
    await tester.pumpAndSettle();
    expect(await workspace.riskAcknowledged(), true);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(results, [false, true, true]);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('panel can be dragged to full available height and back',
      (tester) async {
    workspace = AiWorkspace(
        read: (key) async => values[key],
        write: (key, value) async {
          values[key] = value;
        });
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ResizableAiPanel(
                builder: (resize) => GestureDetector(
                    onVerticalDragUpdate: resize,
                    behavior: HitTestBehavior.opaque,
                    child: const ColoredBox(
                        color: Colors.blue,
                        child: Center(child: Text('drag'))))))));
    final panel = find.byKey(const ValueKey('ai-resizable-panel'));
    final original = tester.getSize(panel).height;
    await tester.drag(find.text('drag'), const Offset(0, -250));
    await tester.pumpAndSettle();
    expect(tester.getSize(panel).height, greaterThan(original));
    expect(tester.getSize(panel).height,
        tester.getSize(find.byType(Scaffold)).height);
    await tester.drag(find.text('drag'), const Offset(0, 200));
    await tester.pumpAndSettle();
    expect(tester.getSize(panel).height, lessThan(original));
  });

  testWidgets('provider fields have space and model list expands from one line',
      (tester) async {
    workspace = AiWorkspace(
        read: (key) async => values[key],
        write: (key, value) async {
          values[key] = value;
        });
    await tester
        .pumpWidget(MaterialApp(home: AiProvidersPage(workspace: workspace)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('添加服务商'));
    await tester.pumpAndSettle();
    final name = find.byKey(const ValueKey('provider-name'));
    final endpoint = find.byKey(const ValueKey('provider-endpoint'));
    final key = find.byKey(const ValueKey('provider-key'));
    final models = find.byKey(const ValueKey('provider-models'));
    expect(tester.getTopLeft(endpoint).dy - tester.getBottomLeft(name).dy,
        greaterThanOrEqualTo(20));
    expect(tester.getTopLeft(key).dy - tester.getBottomLeft(endpoint).dy,
        greaterThanOrEqualTo(20));
    expect(tester.widget<TextField>(models).minLines, 1);
    expect(tester.widget<TextField>(models).maxLines, isNull);
    await tester.ensureVisible(models);
    final before = tester.getSize(models).height;
    await tester.enterText(models, 'one\ntwo\nthree');
    await tester.pumpAndSettle();
    expect(tester.getSize(models).height, greaterThan(before));
    expect(tester.takeException(), isNull);
  });
}
