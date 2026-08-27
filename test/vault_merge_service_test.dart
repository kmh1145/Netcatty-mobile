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
      merged.hosts.map((value) => value.id),
      containsAll(['left', 'right']),
    );
  });

  test('cloud desktop settings replace a stale mobile cached snapshot', () {
    final local = VaultData.fromJson({
      'hosts': const [],
      'keys': const [],
      'snippets': const [],
      'customGroups': const [],
      'settings': {
        'theme': 'light',
        'ai': {
          'providers': [
            {'id': 'stale-provider', 'name': 'Old API Agent'},
          ],
          'defaultAgentId': 'codex',
        },
      },
    });
    final remote = VaultData.fromJson({
      'hosts': const [],
      'keys': const [],
      'snippets': const [],
      'customGroups': const [],
      'settings': {
        'theme': 'dark',
        'ai': {
          'providers': [
            {'id': 'desktop-api', 'name': 'Desktop API Agent'},
          ],
          'activeProviderId': 'desktop-api',
          'defaultAgentId': 'catty',
        },
      },
    });

    final merged = mergeVaults(local: local, remote: remote);

    expect(merged.extras['settings'], remote.extras['settings']);
    final ai = (merged.extras['settings'] as Map)['ai'] as Map;
    expect((ai['providers'] as List).single['id'], 'desktop-api');
    expect(ai['defaultAgentId'], 'catty');
  });

  test('removed desktop settings are not resurrected from mobile cache', () {
    final local = VaultData.fromJson({
      'hosts': const [],
      'keys': const [],
      'snippets': const [],
      'customGroups': const [],
      'settings': {
        'ai': {
          'providers': [
            {'id': 'deleted-provider'},
          ],
        },
      },
      'pluginSidecars': {
        'version': 1,
        'entries': [
          {'pluginId': 'stale-plugin'},
        ],
      },
    });
    final remote = VaultData.empty();

    final merged = mergeVaults(local: local, remote: remote);

    expect(merged.extras.containsKey('settings'), isFalse);
    expect(merged.extras.containsKey('pluginSidecars'), isFalse);
  });

  test('desktop-only payload fields always follow the downloaded snapshot', () {
    final local = VaultData.fromJson({
      'hosts': const [],
      'keys': const [],
      'snippets': const [],
      'customGroups': const [],
      'notes': [
        {'id': 'old-note'},
      ],
      'portForwardingRules': [
        {'id': 'old-forward'},
      ],
      'groupConfigs': [
        {'id': 'old-group'},
      ],
      'syncMeta': {'writer': 'old-mobile-cache'},
    });
    final remote = VaultData.fromJson({
      'hosts': const [],
      'keys': const [],
      'snippets': const [],
      'customGroups': const [],
      'notes': [
        {'id': 'new-note'},
      ],
      'portForwardingRules': [
        {'id': 'new-forward'},
      ],
      'groupConfigs': [
        {'id': 'new-group'},
      ],
      'syncMeta': {'writer': 'desktop'},
    });

    final merged = mergeVaults(local: local, remote: remote);

    expect((merged.extras['notes'] as List).single['id'], 'new-note');
    expect(
      (merged.extras['portForwardingRules'] as List).single['id'],
      'new-forward',
    );
    expect(
      (merged.extras['groupConfigs'] as List).single['id'],
      'new-group',
    );
    expect((merged.extras['syncMeta'] as Map)['writer'], 'desktop');
  });

  test('mobile host-key trust and private sync metadata stay intact', () {
    final local = VaultData.fromJson({
      'hosts': const [],
      'keys': const [],
      'snippets': const [],
      'customGroups': const [],
      'knownHosts': [
        {
          'hostname': 'server.example.com',
          'port': 22,
          'fingerprint': 'mobile-new',
        },
      ],
      '_netcattyMobileFuture': {'enabled': true},
    });
    final remote = VaultData.fromJson({
      'hosts': const [],
      'keys': const [],
      'snippets': const [],
      'customGroups': const [],
      'knownHosts': [
        {
          'hostname': 'server.example.com',
          'port': 22,
          'fingerprint': 'remote-old',
        },
        {
          'hostname': 'other.example.com',
          'port': 2222,
          'fingerprint': 'remote-other',
        },
      ],
    });

    final merged = mergeVaults(local: local, remote: remote);
    final knownHosts = (merged.extras['knownHosts'] as List).cast<Map>();

    expect(knownHosts, hasLength(2));
    expect(
      knownHosts.singleWhere(
        (entry) => entry['hostname'] == 'server.example.com',
      )['fingerprint'],
      'mobile-new',
    );
    expect(merged.extras['_netcattyMobileFuture'], {'enabled': true});
    expect(merged.extras[VaultSyncState.storageKey], isA<Map>());
  });
}
