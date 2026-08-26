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

  test('auto-sync is opt-in and coalesces rapid local changes', () async {
    final changes = StreamController<VaultData>.broadcast();
    var syncCount = 0;
    final applied = <VaultData>[];
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
