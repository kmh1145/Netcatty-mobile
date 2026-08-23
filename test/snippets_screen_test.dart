import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/infrastructure/storage/vault_repository.dart';
import 'package:netcatty_mobile/presentation/screens/snippets_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('snippet can be deleted after confirmation', (tester) async {
    SharedPreferences.setMockInitialValues({
      'netcatty_mobile_vault_v1': jsonEncode({
        'hosts': const [],
        'keys': const [],
        'snippets': [
          {
            'id': 'snippet-1',
            'label': 'Disk usage',
            'command': 'df -h',
          },
        ],
        'customGroups': const [],
      }),
    });
    final repository = await VaultRepository.open();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          vaultRepositoryProvider.overrideWithValue(repository),
        ],
        child: const MaterialApp(home: SnippetsScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Disk usage'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('snippet-actions-snippet-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('delete-snippet-snippet-1')));
    await tester.pumpAndSettle();

    expect(find.text('删除命令片段？'), findsOneWidget);
    expect(
      find.text('将删除“Disk usage”，此操作可通过云同步传播到其他设备。'),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('confirm-delete-snippet')));
    await tester.pumpAndSettle();

    expect(find.text('Disk usage'), findsNothing);
    expect(find.text('还没有命令片段'), findsOneWidget);
    expect((await repository.loadVault()).snippets, isEmpty);
  });
}
