import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/application/auto_sync_controller.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/domain/models/vault.dart';
import 'package:netcatty_mobile/infrastructure/sync/cloud_sync_service.dart';

void main() {
  const versions = CloudSyncVersions(
    localVersion: 1,
    cloudVersion: 1,
    baseVersion: 1,
    hasLocalChanges: false,
  );

  test(
      'manual sync hydrates, joins concurrent requests and preserves in-flight edits with auto disabled',
      () async {
    final changes = StreamController<VaultData>.broadcast(sync: true);
    final hydrated = Completer<VaultData>();
    final network = Completer<CloudSyncResult>();
    var current = VaultData.empty();
    var calls = 0;
    var acknowledged = false;
    final controller = AutoSyncController(
      localChanges: changes.stream,
      loadVault: () =>
          hydrated.isCompleted ? Future.value(current) : hydrated.future,
      synchronize: (vault) {
        calls++;
        return network.future;
      },
      applyVault: (vault) async {
        current = vault;
      },
      retryDelays: const [],
    );
    final first = controller.synchronizeNow();
    final second = controller.synchronizeNow();
    expect(identical(first, second), isTrue);
    expect(calls, 0);
    final original = VaultData.empty().copyWith(hosts: [
      HostProfile({'id': 'h', 'label': 'Old', 'port': 22, 'password': 'secret'})
    ]);
    current = original;
    hydrated.complete(original);
    await Future<void>.delayed(Duration.zero);
    expect(calls, 1);
    current = original.copyWith(hosts: [
      HostProfile(
          {'id': 'h', 'label': 'Edited', 'port': 22, 'password': 'secret'})
    ]);
    changes.add(current);
    network.complete(CloudSyncResult(
      vault: original.copyWith(hosts: [
        HostProfile(
            {'id': 'h', 'label': 'Old', 'port': 2222, 'password': 'secret'})
      ]),
      message: 'ok',
      versions: versions,
      acknowledge: () async {
        expect(current.hosts.single.label, 'Edited');
        acknowledged = true;
      },
    ));
    final result = await first;
    expect(current.hosts.single.label, 'Edited');
    expect(current.hosts.single.data['port'], 2222);
    expect(result.versions.hasLocalChanges, isTrue);
    expect(acknowledged, isTrue);
    controller.dispose();
    await changes.close();
  });

  test('failed credential hydration prevents manual network writes', () async {
    final changes = StreamController<VaultData>.broadcast();
    var calls = 0;
    final controller = AutoSyncController(
      localChanges: changes.stream,
      loadVault: () async => throw StateError('keychain unavailable'),
      synchronize: (vault) async {
        calls++;
        return CloudSyncResult(vault: vault, message: 'ok', versions: versions);
      },
      applyVault: (_) async {},
      retryDelays: const [],
    );
    await expectLater(controller.synchronizeNow(), throwsStateError);
    expect(calls, 0);
    controller.dispose();
    await changes.close();
  });

  test('local changes use a ten second default debounce', () {
    expect(autoSyncChangeDebounce, const Duration(seconds: 10));
    expect(autoSyncRemoteInterval, const Duration(minutes: 5));
  });

  test('auto-sync is opt-in and coalesces rapid local changes', () async {
    final changes = StreamController<VaultData>.broadcast();
    var syncCount = 0;
    final applied = <VaultData>[];
    var current = VaultData.empty();
    final controller = AutoSyncController(
      localChanges: changes.stream,
      loadVault: () async => current,
      synchronize: (vault) async {
        syncCount += 1;
        return CloudSyncResult(
          vault: vault,
          message: 'ok',
          versions: versions,
        );
      },
      applyVault: (vault) async => applied.add(vault),
      changeDebounce: const Duration(milliseconds: 15),
      remoteInterval: const Duration(hours: 1),
      retryDelays: const [],
    );

    changes.add(_vaultWithSnippet('disabled'));
    await Future<void>.delayed(const Duration(milliseconds: 25));
    expect(syncCount, 0);

    controller.setEnabled(true);
    await Future<void>.delayed(const Duration(milliseconds: 25));
    expect(syncCount, 1);

    current = _vaultWithSnippet('latest');
    changes
      ..add(_vaultWithSnippet('first'))
      ..add(_vaultWithSnippet('latest'));
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(syncCount, 2);
    expect(applied.last.snippets.single.label, 'latest');

    controller.dispose();
    await changes.close();
  });

  test('returning to foreground requests an immediate refresh', () async {
    final changes = StreamController<VaultData>.broadcast();
    var syncCount = 0;
    final controller = AutoSyncController(
      localChanges: changes.stream,
      loadVault: () async => VaultData.empty(),
      synchronize: (vault) async {
        syncCount += 1;
        return CloudSyncResult(
          vault: vault,
          message: 'ok',
          versions: versions,
        );
      },
      applyVault: (_) async {},
      changeDebounce: const Duration(milliseconds: 5),
      remoteInterval: const Duration(hours: 1),
      retryDelays: const [],
    );

    controller.setEnabled(true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    controller.onAppResumed();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(syncCount, 2);
    controller.dispose();
    await changes.close();
  });

  test('an edit made during network sync is preserved and queued', () async {
    final changes = StreamController<VaultData>.broadcast();
    final firstSync = Completer<CloudSyncResult>();
    var syncCount = 0;
    final applied = <VaultData>[];
    final controller = AutoSyncController(
      localChanges: changes.stream,
      loadVault: () async => VaultData.empty(),
      synchronize: (vault) {
        syncCount += 1;
        if (syncCount == 1) return firstSync.future;
        return Future.value(CloudSyncResult(
          vault: vault,
          message: 'ok',
          versions: versions,
        ));
      },
      applyVault: (vault) async => applied.add(vault),
      changeDebounce: const Duration(milliseconds: 10),
      remoteInterval: const Duration(hours: 1),
      retryDelays: const [],
    );

    controller.setEnabled(true);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    changes.add(_vaultWithSnippet('during-sync'));
    firstSync.complete(CloudSyncResult(
      vault: VaultData.empty(),
      message: 'ok',
      versions: versions,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 45));

    expect(applied.first.snippets.single.label, 'during-sync');
    expect(syncCount, 2);
    controller.dispose();
    await changes.close();
  });

  test('host trust accepted during sync remains device-local', () async {
    final changes = StreamController<VaultData>.broadcast();
    final firstSync = Completer<CloudSyncResult>();
    final baseHost = HostProfile({
      'id': 'host-1',
      'label': 'Server',
      'hostname': 'server.example.com',
      'port': 22,
      'username': 'root',
    });
    var current = VaultData.empty().copyWith(hosts: [baseHost]);
    var syncCount = 0;
    final applied = <VaultData>[];
    final controller = AutoSyncController(
      localChanges: changes.stream,
      loadVault: () async => current,
      synchronize: (vault) {
        syncCount += 1;
        if (syncCount == 1) return firstSync.future;
        return Future.value(CloudSyncResult(
          vault: vault,
          message: 'ok',
          versions: versions,
        ));
      },
      applyVault: (vault) async {
        current = vault;
        applied.add(vault);
      },
      changeDebounce: const Duration(milliseconds: 10),
      remoteInterval: const Duration(hours: 1),
      retryDelays: const [],
    );

    controller.setEnabled(true);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    final acceptedAt = DateTime.now().millisecondsSinceEpoch;
    final trusted = VaultData.fromJson({
      ...current.toJson(),
      'hosts': [
        {
          ...baseHost.toJson(),
          'lastConnectedAt': acceptedAt,
        },
      ],
      'knownHosts': [
        {
          'hostname': 'server.example.com',
          'port': 22,
          'keyType': 'ssh-ed25519',
          'fingerprint': 'SHA256:test',
          'acceptedAt': acceptedAt,
        },
      ],
    });
    current = trusted;
    changes.add(trusted);
    await Future<void>.delayed(Duration.zero);
    firstSync.complete(CloudSyncResult(
      vault: VaultData.empty().copyWith(hosts: [baseHost]),
      message: 'ok',
      versions: versions,
    ));
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(applied, isNotEmpty);
    expect(applied.first.extras['knownHosts'], trusted.extras['knownHosts']);
    expect(applied.first.hosts.single.lastConnectedAt, acceptedAt);
    expect(current.extras['knownHosts'], trusted.extras['knownHosts']);
    controller.dispose();
    await changes.close();
  });
}

VaultData _vaultWithSnippet(String name) => VaultData.empty().copyWith(
      snippets: [
        CommandSnippet({
          'id': 'snippet-1',
          'label': name,
          'command': 'echo test',
          'updatedAt': DateTime.now().millisecondsSinceEpoch,
        }),
      ],
    );
