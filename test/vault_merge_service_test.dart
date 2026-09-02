import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/domain/models/vault.dart';
import 'package:netcatty_mobile/infrastructure/sync/vault_merge_service.dart';

void main() {
  HostProfile host(String id, String label, {int? lastConnectedAt}) =>
      HostProfile({
        'id': id,
        'label': label,
        'hostname': '$id.example.com',
        'username': 'root',
        'port': 22,
        if (lastConnectedAt != null) 'lastConnectedAt': lastConnectedAt,
      });

  SshKeyProfile key(String id, String label) => SshKeyProfile({
        'id': id,
        'label': label,
        'privateKey': 'secret-$id',
      });

  test('remote host and key deletion wins when local is unchanged from base',
      () {
    final base = VaultData.empty().copyWith(
      hosts: [host('removed-host', 'Server')],
      keys: [key('removed-key', 'Key')],
    );
    final remote = base.copyWith(hosts: [], keys: []);

    final merged = mergeVaults(base: base, local: base, remote: remote);

    expect(merged.hosts, isEmpty);
    expect(merged.keys, isEmpty);
  });

  test('local deletion wins when remote is unchanged from base', () {
    final base = VaultData.empty().copyWith(
      hosts: [host('removed-host', 'Server')],
    );

    final merged = mergeVaults(
      base: base,
      local: base.copyWith(hosts: []),
      remote: base,
    );

    expect(merged.hosts, isEmpty);
  });

  test('delete versus edit conflict keeps the edited record', () {
    final base = VaultData.empty().copyWith(
      hosts: [host('conflict', 'Original')],
    );

    final merged = mergeVaults(
      base: base,
      local: base.copyWith(hosts: [host('conflict', 'Edited')]),
      remote: base.copyWith(hosts: []),
    );

    expect(merged.hosts.single.label, 'Edited');
  });

  test('independent first-sync additions are unioned', () {
    final local = VaultData.empty().copyWith(hosts: [host('local', 'Local')]);
    final remote =
        VaultData.empty().copyWith(hosts: [host('remote', 'Remote')]);

    final merged = mergeVaults(local: local, remote: remote);

    expect(merged.hosts.map((value) => value.id), ['local', 'remote']);
  });

  test('remote tombstones suppress stale records without a local base', () {
    final local = VaultData.empty().copyWith(
      hosts: [host('deleted-host', 'Stale')],
      keys: [key('deleted-key', 'Stale')],
    );
    final remote = VaultData.fromJson({
      'hosts': const [],
      'keys': const [],
      'snippets': const [],
      'customGroups': const [],
      'syncMeta': {
        'schemaVersion': 1,
        'deletions': [
          {
            'entityType': 'hosts',
            'id': 'deleted-host',
            'deletedAt': 100,
          },
          {
            'entityType': 'keys',
            'id': 'deleted-key',
            'deletedAt': 100,
          },
        ],
      },
    });

    final merged = mergeVaults(local: local, remote: remote);

    expect(merged.hosts, isEmpty);
    expect(merged.keys, isEmpty);
    expect(
      ((merged.extras['syncMeta'] as Map)['deletions'] as List),
      hasLength(2),
    );
  });

  test('reliability metadata records and carries desktop-compatible deletions',
      () {
    final base = VaultData.empty().copyWith(
      hosts: [host('deleted-host', 'Server')],
      keys: [key('deleted-key', 'Key')],
    );
    final enriched = withSyncReliabilityMeta(
      base.copyWith(hosts: [], keys: []),
      base,
      deviceId: 'mobile-device',
      timestamp: 500,
    );
    final meta = enriched.extras['syncMeta'] as Map;
    final deletions = (meta['deletions'] as List).cast<Map>();

    expect(meta['schemaVersion'], 1);
    expect(meta['deviceId'], 'mobile-device');
    expect(deletions.map((entry) => entry['entityType']),
        containsAll(['hosts', 'keys']));
    expect(deletions.every((entry) => entry['deletedAt'] == 500), isTrue);
  });

  test('first merge adopts cloud setting conflicts but keeps one-sided fields',
      () {
    final local = VaultData.fromJson({
      'hosts': const [],
      'keys': const [],
      'snippets': const [],
      'customGroups': const [],
      'settings': {
        'theme': 'light',
        'mobileOnly': true,
        'ai': {
          'providers': [
            {'id': 'stale-provider'},
          ],
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
        'desktopOnly': true,
        'ai': {
          'providers': [
            {'id': 'desktop-provider'},
          ],
        },
      },
    });

    final settings =
        mergeVaults(local: local, remote: remote).extras['settings'] as Map;

    expect(settings['theme'], 'dark');
    expect(settings['mobileOnly'], isTrue);
    expect(settings['desktopOnly'], isTrue);
    expect(
      ((settings['ai'] as Map)['providers'] as List)
          .map((provider) => (provider as Map)['id']),
      containsAll(['stale-provider', 'desktop-provider']),
    );
  });

  test('optional collection omission inherits the base instead of deleting it',
      () {
    final base = VaultData.fromJson({
      'hosts': const [],
      'keys': const [],
      'snippets': const [],
      'customGroups': const [],
      'notes': [
        {'id': 'note-1', 'text': 'Keep me'},
      ],
      'proxyProfiles': [
        {
          'id': 'proxy-1',
          'label': 'Keep proxy',
          'config': {'type': 'socks5', 'host': 'proxy.example.com'},
        },
      ],
    });
    final remote = VaultData.fromJson({
      'hosts': const [],
      'keys': const [],
      'snippets': const [],
      'customGroups': const [],
    });

    final merged = mergeVaults(base: base, local: base, remote: remote);

    expect((merged.extras['notes'] as List).single['id'], 'note-1');
    expect(merged.proxyProfiles.single.id, 'proxy-1');
  });

  test('sync comparison ignores timestamps, reliability meta and telemetry',
      () {
    final left = VaultData.fromJson({
      'hosts': [host('one', 'Server', lastConnectedAt: 100).toJson()],
      'keys': const [],
      'snippets': const [],
      'customGroups': const [],
      'syncedAt': 100,
      'syncMeta': {'generatedAt': 100},
    });
    final right = VaultData.fromJson({
      'hosts': [host('one', 'Server', lastConnectedAt: 999).toJson()],
      'keys': const [],
      'snippets': const [],
      'customGroups': const [],
      'syncedAt': 999,
      'syncMeta': {'generatedAt': 999},
    });

    expect(cloudSyncPayloadsEqual(left, right), isTrue);
  });

  test('cloud sanitization removes private metadata and keeps trust local', () {
    final local = VaultData.fromJson({
      'hosts': [host('one', 'Server', lastConnectedAt: 100).toJson()],
      'keys': const [],
      'snippets': const [],
      'customGroups': const [],
      'knownHosts': [
        {'hostname': 'one.example.com', 'fingerprint': 'local'},
      ],
      '_netcattyMobileSync': {'legacy': true},
    });
    final sanitized = sanitizeVaultForSync(local).toJson();
    final applied = retainLocalDeviceData(
      VaultData.empty().copyWith(hosts: [host('one', 'Server')]),
      local,
    ).toJson();

    expect(sanitized.containsKey('_netcattyMobileSync'), isFalse);
    expect(sanitized.containsKey('knownHosts'), isFalse);
    expect((sanitized['hosts'] as List).single.containsKey('lastConnectedAt'),
        isFalse);
    expect(applied['knownHosts'], local.toJson()['knownHosts']);
    expect((applied['hosts'] as List).single['lastConnectedAt'], 100);
  });
}
