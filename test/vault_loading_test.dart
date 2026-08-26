import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/application/vault_controller.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/infrastructure/storage/vault_repository.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('vault metadata and snippets are available before secret hydration',
      () async {
    SharedPreferences.setMockInitialValues({
      'netcatty_mobile_vault_v1': jsonEncode({
        'hosts': [
          {
            'id': 'host-1',
            'label': 'Cached server',
            'hostname': '192.0.2.10',
            'username': 'root',
          },
        ],
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

    final preview = repository.loadVaultPreview();
    final controller = VaultController(repository);

    expect(preview?.hosts.single.label, 'Cached server');
    expect(preview?.snippets.single.command, 'df -h');
    expect(controller.state.loading, isTrue);
    expect(controller.state.data?.hosts.single.label, 'Cached server');
    expect(controller.state.data?.snippets.single.command, 'df -h');
  });

  test('snippet edits do not wait for or rewrite platform secrets', () async {
    const secureStorageChannel =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    final unblockReads = Completer<String?>();
    var secureStorageCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (call) async {
      secureStorageCalls++;
      if (call.method == 'read') return unblockReads.future;
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(secureStorageChannel, null);
    });
    SharedPreferences.setMockInitialValues({
      'netcatty_mobile_vault_v1': jsonEncode({
        'hosts': [
          {
            'id': 'host-1',
            'label': 'Slow keychain server',
            'hostname': '192.0.2.10',
            'username': 'root',
          },
        ],
        'keys': const [],
        'snippets': const [],
        'customGroups': const [],
      }),
    });
    final repository = await VaultRepository.open();
    final controller = VaultController(repository);
    final loading = controller.load();
    await Future<void>.delayed(Duration.zero);
    expect(secureStorageCalls, greaterThan(0));

    await controller
        .upsertSnippet(CommandSnippet({
          'id': 'snippet-fast',
          'label': 'Fast edit',
          'command': 'uptime',
        }))
        .timeout(const Duration(milliseconds: 500));

    expect(controller.state.data?.snippets.single.id, 'snippet-fast');
    expect(secureStorageCalls, 3, reason: 'only the active hydration may read');
    unblockReads.complete(null);
    await loading;
    expect(controller.state.data?.snippets.single.id, 'snippet-fast');
    expect(repository.loadVaultPreview()?.snippets.single.id, 'snippet-fast');
  });

  test('host edits keep custom group tabs synchronized', () async {
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
            'group': 'Old group',
          },
        ],
        'keys': const [],
        'snippets': const [],
        'customGroups': ['Old group'],
      }),
    });
    final repository = await VaultRepository.open();
    final controller = VaultController(repository);
    await controller.load();

    final edited = controller.state.data!.hosts.single.copyWith(
      group: 'New group',
    );
    await controller.upsertHost(edited);

    expect(controller.state.data!.customGroups, ['New group']);
    expect(repository.loadVaultPreview()!.customGroups, ['New group']);
  });

  test('deleting the last host removes its unused group tab', () async {
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
            'group': 'Temporary',
          },
        ],
        'keys': const [],
        'snippets': const [],
        'customGroups': ['Temporary'],
      }),
    });
    final repository = await VaultRepository.open();
    final controller = VaultController(repository);
    await controller.load();

    await controller.deleteHost('host-1');

    expect(controller.state.data!.hosts, isEmpty);
    expect(controller.state.data!.customGroups, isEmpty);
  });
}
