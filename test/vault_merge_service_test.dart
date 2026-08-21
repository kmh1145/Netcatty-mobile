import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/domain/models/vault.dart';
import 'package:netcatty_mobile/domain/models/vault_sync_state.dart';
import 'package:netcatty_mobile/infrastructure/sync/vault_merge_service.dart';

void main() {
  HostProfile host(String id, String label) => HostProfile({
        'id': id,
        'label': label,
        'hostname': '$id.example.com',
        'username': 'root',
        'port': 22,
      });

  test('newer entity revision wins regardless of merge direction', () {
    final oldVault = stampLocalVaultChanges(
      VaultData.empty(),
      VaultData.empty().copyWith(hosts: [host('one', 'Old')]),
      timestamp: 100,
    );
    final newVault = stampLocalVaultChanges(
      oldVault,
      oldVault.copyWith(hosts: [host('one', 'New')]),
      timestamp: 200,
    );

    expect(
      mergeVaults(local: oldVault, remote: newVault).hosts.single.label,
      'New',
    );
    expect(
      mergeVaults(local: newVault, remote: oldVault).hosts.single.label,
      'New',
    );
  });

  test('tombstone prevents a deleted host from being resurrected', () {
    final original = stampLocalVaultChanges(
      VaultData.empty(),
      VaultData.empty().copyWith(hosts: [host('gone', 'Delete me')]),
      timestamp: 100,
    );
    final deleted = stampLocalVaultChanges(
      original,
      original.copyWith(hosts: []),
      timestamp: 300,
    );

    final merged = mergeVaults(local: deleted, remote: original);

    expect(merged.hosts, isEmpty);
    expect(
      VaultSyncState.fromVault(merged).deletedAt(
        VaultSyncState.hosts,
        'gone',
      ),
      300,
    );
  });

  test('independent additions from two devices are preserved', () {
    final left = stampLocalVaultChanges(
      VaultData.empty(),
      VaultData.empty().copyWith(hosts: [host('left', 'Left')]),
      timestamp: 100,
    );
    final right = stampLocalVaultChanges(
      VaultData.empty(),
      VaultData.empty().copyWith(hosts: [host('right', 'Right')]),
      timestamp: 120,
    );

    final merged = mergeVaults(local: left, remote: right);

    expect(
        merged.hosts.map((value) => value.id), containsAll(['left', 'right']));
  });
}
