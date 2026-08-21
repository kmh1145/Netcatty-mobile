import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/domain/models/settings.dart';
import 'package:netcatty_mobile/domain/models/vault.dart';
import 'package:netcatty_mobile/infrastructure/storage/vault_repository.dart';
import 'package:netcatty_mobile/infrastructure/sync/cloud_sync_service.dart';
import 'package:netcatty_mobile/infrastructure/sync/netcatty_crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final secureValues = <String, String>{};

  setUp(() {
    secureValues.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (call) async {
      final arguments = Map<String, dynamic>.from(call.arguments as Map);
      final key = arguments['key']?.toString();
      switch (call.method) {
        case 'write':
          secureValues[key!] = arguments['value'].toString();
          return null;
        case 'read':
          return secureValues[key];
        case 'delete':
          secureValues.remove(key);
          return null;
        case 'deleteAll':
          secureValues.clear();
          return null;
        case 'readAll':
          return Map<String, String>.from(secureValues);
        case 'containsKey':
          return secureValues.containsKey(key);
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, null);
  });

  test('Gist update verifies the revision without If-Match on PATCH', () async {
    SharedPreferences.setMockInitialValues({});
    final repository = await VaultRepository.open();
    await repository.saveSyncConnection(const SyncConnection(
      type: SyncProviderType.githubGist,
      endpoint: '',
      username: 'octocat',
      secret: 'token',
      resourceId: 'gist-1',
    ));
    await repository.saveMasterPassword('sync-password');

    final remoteVault = VaultData.empty();
    final remoteFile = await NetcattyCrypto.encrypt(
      vault: remoteVault,
      password: 'sync-password',
      deviceId: 'remote-device',
      deviceName: 'Remote',
      appVersion: '1.3.0',
      previousVersion: 3,
    );
    final gistResponse = jsonEncode({
      'files': {
        'netcatty-vault.json': {
          'content': jsonEncode(remoteFile.toJson()),
          'truncated': false,
        },
      },
    });
    var getCount = 0;
    var patchCount = 0;
    final client = MockClient((request) async {
      if (request.method == 'GET') {
        getCount++;
        return http.Response(
          gistResponse,
          200,
          headers: {'etag': '"revision-1"'},
        );
      }
      if (request.method == 'PATCH') {
        patchCount++;
        expect(request.headers.containsKey('if-match'), isFalse);
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final files = body['files'] as Map<String, dynamic>;
        final vaultFile = jsonDecode(
          (files['netcatty-vault.json'] as Map<String, dynamic>)['content']
              as String,
        ) as Map<String, dynamic>;
        expect((vaultFile['meta'] as Map<String, dynamic>)['version'], 5);
        return http.Response('{}', 200);
      }
      fail('Unexpected ${request.method} request to ${request.url}');
    });
    final local = VaultData.empty().copyWith(hosts: [
      HostProfile.create(
        id: 'host-1',
        label: 'Server',
        hostname: 'server.example.com',
        username: 'root',
      ),
    ]);

    final result = await CloudSyncService(
      repository,
      client: client,
      deviceId: 'local-device',
      appVersion: '1.3.1',
    ).push(local);

    expect(getCount, 2, reason: 'download plus revision preflight');
    expect(patchCount, 1);
    expect(result.versions.localVersion, 5);
    expect(result.versions.cloudVersion, 5);
    expect(result.versions.hasLocalChanges, isFalse);
    final checkpoint = await repository.loadSyncVersionCheckpoint();
    expect(checkpoint?.target, 'github:gist-1');
    expect(checkpoint?.version, 5);
  });

  test('version inspection marks a local edit as the next pending version',
      () async {
    SharedPreferences.setMockInitialValues({});
    final repository = await VaultRepository.open();
    const connection = SyncConnection(
      type: SyncProviderType.githubGist,
      endpoint: '',
      secret: 'token',
      resourceId: 'gist-2',
    );
    await repository.saveSyncConnection(connection);
    await repository.saveMasterPassword('sync-password');
    final original = VaultData.empty();
    final remoteFile = await NetcattyCrypto.encrypt(
      vault: original,
      password: 'sync-password',
      deviceId: 'remote-device',
      deviceName: 'Remote',
      appVersion: '1.3.0',
      previousVersion: 6,
    );
    var currentFile = remoteFile;
    final initialClient = MockClient((request) async {
      if (request.method == 'PATCH') {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final files = body['files'] as Map<String, dynamic>;
        currentFile = SyncedVaultFile.fromJson(
          jsonDecode(
            (files['netcatty-vault.json'] as Map<String, dynamic>)['content']
                as String,
          ) as Map<String, dynamic>,
        );
        return http.Response('{}', 200);
      }
      return http.Response(
        jsonEncode({
          'files': {
            'netcatty-vault.json': {
              'content': jsonEncode(currentFile.toJson()),
              'truncated': false,
            },
          },
        }),
        200,
        headers: {'etag': '"revision-${currentFile.meta['version']}"'},
      );
    });
    final service = CloudSyncService(
      repository,
      client: initialClient,
      deviceId: 'local-device',
      appVersion: '1.3.1',
    );
    final synchronized = await service.pullAndMerge(original);
    final edited = synchronized.vault.copyWith(customGroups: ['Production']);

    final versions = await service.inspectVersions(edited);

    expect(versions.baseVersion, 8);
    expect(versions.localVersion, 9);
    expect(versions.cloudVersion, 8);
    expect(versions.hasLocalChanges, isTrue);
  });
}
