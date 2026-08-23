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

  test('WebDAV upload uses the desktop temp PUT and MOVE replacement flow',
      () async {
    SharedPreferences.setMockInitialValues({});
    final repository = await VaultRepository.open();
    await repository.saveSyncConnection(const SyncConnection(
      type: SyncProviderType.webdav,
      endpoint: 'dav.example.com/netcatty',
      username: '同步用户',
      secret: '应用密码',
    ));
    await repository.saveMasterPassword('sync-password');

    final remoteFile = await NetcattyCrypto.encrypt(
      vault: VaultData.empty(),
      password: 'sync-password',
      deviceId: 'desktop-device',
      deviceName: 'Desktop',
      appVersion: '1.3.4',
      previousVersion: 3,
    );
    var canonical = <int>[...utf8.encode(jsonEncode(remoteFile.toJson()))];
    List<int>? temporary;
    var moveCount = 0;
    final expectedAuthorization =
        'Basic ${base64Encode(utf8.encode('同步用户:应用密码'))}';
    final client = MockClient((request) async {
      expect(request.url.scheme, 'https');
      expect(request.headers['authorization'], expectedAuthorization);
      expect(request.headers.containsKey('if-match'), isFalse);
      expect(request.headers.containsKey('if-none-match'), isFalse);
      if (request.method == 'GET' &&
          request.url.path.endsWith('netcatty-vault.json')) {
        return http.Response.bytes(canonical, 200, headers: {
          'content-type': 'application/json; charset=utf-8',
          'etag': '"desktop-revision"',
        });
      }
      if (request.method == 'GET' && request.url.path.endsWith('.tmp')) {
        return http.Response('', 404);
      }
      if (request.method == 'PUT' && request.url.path.endsWith('.tmp')) {
        temporary = List<int>.from(request.bodyBytes);
        return http.Response('', 201);
      }
      if (request.method == 'MOVE') {
        moveCount++;
        expect(request.headers['overwrite'], 'T');
        expect(
          request.headers['destination'],
          'https://dav.example.com/netcatty/netcatty-vault.json',
        );
        canonical = temporary!;
        return http.Response('', 201);
      }
      fail('Unexpected ${request.method} request to ${request.url}');
    });
    final local = VaultData.empty().copyWith(hosts: [
      HostProfile.create(
        id: 'mobile-host',
        label: 'Mobile server',
        hostname: 'mobile.example.com',
        username: 'root',
      ),
    ]);

    final result = await CloudSyncService(
      repository,
      client: client,
      deviceId: 'mobile-device',
      appVersion: '1.3.4',
    ).push(local);

    expect(moveCount, 1);
    expect(result.vault.hosts.single.id, 'mobile-host');
    final uploaded = SyncedVaultFile.fromJson(
      jsonDecode(utf8.decode(canonical)) as Map<String, dynamic>,
    );
    expect(uploaded.meta['version'], 5);
  });

  test('WebDAV fallback pads a shorter vault for non-truncating servers',
      () async {
    SharedPreferences.setMockInitialValues({});
    final repository = await VaultRepository.open();
    await repository.saveSyncConnection(const SyncConnection(
      type: SyncProviderType.webdav,
      endpoint: 'https://dav.example.com/netcatty/',
      username: 'user',
      secret: 'password',
    ));
    await repository.saveMasterPassword('sync-password');

    final remoteFile = await NetcattyCrypto.encrypt(
      vault: VaultData.empty(),
      password: 'sync-password',
      deviceId: 'desktop-device',
      deviceName: 'Desktop',
      appVersion: '1.3.4',
      previousVersion: 1,
    );
    final cleanRemote = utf8.encode(jsonEncode(remoteFile.toJson()));
    var canonical = <int>[...cleanRemote, ...List<int>.filled(4096, 0x20)];
    final originalLength = canonical.length;
    var canonicalPutLength = 0;
    var canonicalPutCount = 0;
    final client = MockClient((request) async {
      if (request.method == 'GET' && request.url.path.endsWith('.tmp')) {
        return http.Response('', 404);
      }
      if (request.method == 'PUT' && request.url.path.endsWith('.tmp')) {
        return http.Response('', 201);
      }
      if (request.method == 'MOVE') return http.Response('', 405);
      if (request.method == 'DELETE') return http.Response('', 204);
      if (request.method == 'GET') {
        return http.Response.bytes(canonical, 200, headers: {
          'content-type': 'application/json; charset=utf-8',
        });
      }
      if (request.method == 'PUT') {
        final bytes = request.bodyBytes;
        canonicalPutLength = bytes.length;
        canonicalPutCount++;
        canonical = List<int>.from(bytes);
        return http.Response('', 204);
      }
      fail('Unexpected ${request.method} request to ${request.url}');
    });
    final local = VaultData.empty().copyWith(customGroups: ['Mobile']);

    final result = await CloudSyncService(
      repository,
      client: client,
      deviceId: 'mobile-device',
      appVersion: '1.3.4',
    ).push(local);

    expect(result.vault.customGroups, contains('Mobile'));
    expect(canonicalPutCount, 1);
    expect(canonicalPutLength, greaterThanOrEqualTo(originalLength));
    expect(
      utf8.decode(canonical).trimRight().endsWith('}'),
      isTrue,
    );
  });

  test('S3 sync signs and uploads the desktop-compatible vault object',
      () async {
    SharedPreferences.setMockInitialValues({});
    final repository = await VaultRepository.open();
    const connection = SyncConnection(
      type: SyncProviderType.s3,
      endpoint: 'https://minio.example.com/storage',
      region: 'us-east-1',
      bucket: 'netcatty',
      accessKeyId: 'mobile-access-key',
      secret: 'mobile-secret-key',
      sessionToken: 'temporary-session-token',
      prefix: '/vaults/user/',
    );
    await repository.saveSyncConnection(connection);
    await repository.saveMasterPassword('sync-password');

    http.Request? uploaded;
    final client = MockClient((request) async {
      expect(
        request.url.path,
        '/storage/netcatty/vaults/user/netcatty-vault.json',
      );
      expect(
        request.headers['authorization'],
        startsWith('AWS4-HMAC-SHA256 Credential=mobile-access-key/'),
      );
      expect(
          request.headers['x-amz-security-token'], 'temporary-session-token');
      expect(request.headers['x-amz-content-sha256'], isNotEmpty);
      if (request.method == 'GET') return http.Response('', 404);
      if (request.method == 'PUT') {
        uploaded = request;
        return http.Response('', 200, headers: {'etag': '"s3-revision"'});
      }
      fail('Unexpected ${request.method} request to ${request.url}');
    });
    final local = VaultData.empty().copyWith(customGroups: ['S3']);

    final result = await CloudSyncService(
      repository,
      client: client,
      deviceId: 'mobile-device',
      appVersion: '1.3.6',
    ).push(local);

    expect(uploaded, isNotNull);
    final encrypted = SyncedVaultFile.fromJson(
      jsonDecode(uploaded!.body) as Map<String, dynamic>,
    );
    expect(encrypted.meta['version'], 1);
    expect(result.versions.cloudVersion, 1);
    expect(
      (await repository.loadSyncVersionCheckpoint())?.target,
      's3:https://minio.example.com/storage|netcatty|/vaults/user/',
    );

    final stored = await repository.loadSyncConnection();
    expect(stored?.sessionToken, 'temporary-session-token');
    final preferences = await SharedPreferences.getInstance();
    final serialized = preferences.getString('netcatty_mobile_sync_v1') ?? '';
    expect(serialized, isNot(contains('mobile-secret-key')));
    expect(serialized, isNot(contains('temporary-session-token')));
  });

  test('S3 virtual-host mode signs a bucket host connection test', () async {
    SharedPreferences.setMockInitialValues({});
    final repository = await VaultRepository.open();
    const connection = SyncConnection(
      type: SyncProviderType.s3,
      endpoint: 's3.example.com/api',
      region: 'eu-west-1',
      bucket: 'vault-bucket',
      accessKeyId: 'access',
      secret: 'secret',
      forcePathStyle: false,
    );
    final client = MockClient((request) async {
      expect(request.method, 'HEAD');
      expect(request.url.host, 'vault-bucket.s3.example.com');
      expect(request.url.path, '/api');
      expect(request.headers['authorization'], contains('/eu-west-1/s3/'));
      return http.Response('', 200);
    });

    await CloudSyncService(repository, client: client)
        .testS3Connection(connection);
  });
}
