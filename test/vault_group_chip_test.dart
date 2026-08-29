import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/infrastructure/storage/vault_repository.dart';
import 'package:netcatty_mobile/presentation/screens/vault_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('vault group labels are centered inside a stable chip area',
      (tester) async {
    const secureStorageChannel =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (_) async => null);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(secureStorageChannel, null);
    });
    SharedPreferences.setMockInitialValues({
      'netcatty_mobile_vault_v1': jsonEncode({
        'hosts': [
          {
            'id': 'host-1',
            'label': 'Server',
            'hostname': '192.0.2.10',
            'username': 'root',
            'group': '生产',
          },
        ],
        'keys': const [],
        'snippets': const [],
        'customGroups': ['生产'],
      }),
    });
    final repository = await VaultRepository.open();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [vaultRepositoryProvider.overrideWithValue(repository)],
        child: const MaterialApp(
          home: Scaffold(body: VaultScreen()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final chip = find.byKey(const ValueKey('vault-group-chip-all'));
    final label = find.text('全部');
    expect(chip, findsOneWidget);
    expect(label, findsOneWidget);
    final chipCenter = tester.getCenter(chip);
    final labelCenter = tester.getCenter(label);
    expect((chipCenter.dx - labelCenter.dx).abs(), lessThan(1));
    expect((chipCenter.dy - labelCenter.dy).abs(), lessThan(1));
    expect(tester.getSize(chip).height, 40);
  });
}
