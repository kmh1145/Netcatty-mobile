import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/application/vault_controller.dart';
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
}
