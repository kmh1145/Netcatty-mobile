import 'package:flutter_test/flutter_test.dart';
import 'fixtures/desktop_v2_vault.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/domain/models/vault.dart';
import 'package:netcatty_mobile/infrastructure/sync/convergent_sync_adapter.dart';
import 'package:netcatty_mobile/infrastructure/sync/sync_safety.dart';

void main() {
  test('v2 preserves API settings and handles atomic-to-object setting changes',
      () {
    final initial = _desktopV2Vault();
    final base = updateConvergentSyncPayload(
        remote: initial,
        desired: initial.copyWith(extras: {
          'settings': {
            'appearance': 'dark',
            'ai': {
              'providers': [
                {'id': 'api-provider', 'model': 'model-a'}
              ]
            }
          }
        }),
        deviceId: 'settings-seed',
        timestamp: 150);
    final nested = applyConvergentLocalChanges(
        replica: base,
        baseline: base,
        local: base.copyWith(extras: {
          'settings': {
            'appearance': {'theme': 'light'},
            'ai': {
              'providers': [
                {'id': 'api-provider', 'model': 'model-a'}
              ]
            }
          }
        }),
        deviceId: 'phone',
        timestamp: 200);
    expect(
        (nested.extras['settings'] as Map)['appearance'], {'theme': 'light'});
    final desktop = applyConvergentLocalChanges(
        replica: base,
        baseline: base,
        local: base.copyWith(extras: {
          'settings': {
            'appearance': 'dark',
            'ai': {
              'providers': [
                {'id': 'api-provider', 'model': 'model-b'}
              ]
            }
          }
        }),
        deviceId: 'pc',
        timestamp: 250);
    final joined = mergeConvergentPayloads(nested, desktop);
    expect(joined.extras['settings'], {
      'appearance': {'theme': 'light'},
      'ai': {
        'providers': [
          {'id': 'api-provider', 'model': 'model-b'}
        ]
      }
    });
    validateConvergentSyncPayload(joined);
  });

  test('v2 concurrent different fields survive a causal join', () {
    final base = _desktopV2Vault();
    final a = applyConvergentLocalChanges(
        replica: base,
        baseline: base,
        local: base.copyWith(hosts: [
          HostProfile({'id': 'host-1', 'label': 'Mobile'})
        ]),
        deviceId: 'phone',
        timestamp: 200);
    final b = applyConvergentLocalChanges(
        replica: base,
        baseline: base,
        local: base.copyWith(hosts: [
          HostProfile({'id': 'host-1', 'label': 'Desktop', 'port': 2222})
        ]),
        deviceId: 'pc',
        timestamp: 300);
    final joined = mergeConvergentPayloads(a, b);
    expect(joined.hosts.single.label, 'Mobile');
    expect(joined.hosts.single.data['port'], 2222);
    expect(convergentPayloadDominates(joined, a), isTrue);
    expect(convergentPayloadDominates(joined, b), isTrue);
    expect(mergeConvergentPayloads(b, a).toJson(), joined.toJson());
    expect(mergeConvergentPayloads(joined, joined).toJson(), joined.toJson());
  });

  test('v2 unchanged old snapshot never revives a remotely deleted host', () {
    final base = _desktopV2Vault();
    final deleted = updateConvergentSyncPayload(
        remote: base,
        desired: base.copyWith(hosts: []),
        deviceId: 'pc',
        timestamp: 200);
    final unchanged = applyConvergentLocalChanges(
        replica: base,
        baseline: base,
        local: base,
        deviceId: 'phone',
        timestamp: 300);
    expect(mergeConvergentPayloads(unchanged, deleted).hosts, isEmpty);
    final repeated = applyConvergentLocalChanges(
        replica: deleted,
        baseline: base,
        local: base,
        deviceId: 'phone',
        timestamp: 400);
    expect(repeated.hosts, isEmpty);
    expect(repeated.extras['convergentSync'], deleted.extras['convergentSync']);
  });

  test('v2 unresolved conflicts are retained, not rewritten by unchanged sync',
      () {
    final base = _desktopV2Vault();
    VaultData edit(String device, String label) => applyConvergentLocalChanges(
        replica: base,
        baseline: base,
        local: base.copyWith(hosts: [
          HostProfile({'id': 'host-1', 'label': label})
        ]),
        deviceId: device,
        timestamp: 200);
    final joined = mergeConvergentPayloads(edit('a', 'A'), edit('b', 'B'));
    final untouched = applyConvergentLocalChanges(
        replica: joined,
        baseline: joined,
        local: joined,
        deviceId: 'phone',
        timestamp: 300);
    expect(untouched.extras['convergentSync'], joined.extras['convergentSync']);
    final state = (joined.extras['convergentSync'] as Map)['state'] as Map;
    expect(
        state['collections']['hosts']['entities']['host-1']['fields']['label']
            ['candidates'],
        hasLength(2));
  });

  test('v2 rejects an envelope that hides an extra materialized host', () {
    final base = _desktopV2Vault();
    final corrupt = base.copyWith(hosts: [
      ...base.hosts,
      HostProfile({'id': 'hidden', 'label': 'Hidden'})
    ]);
    expect(() => validateConvergentSyncPayload(corrupt), throwsFormatException);
  });

  test('shrink protection uses desktop thresholds and group safeguards', () {
    VaultData hosts(int count) => VaultData.empty().copyWith(hosts: [
          for (var i = 0; i < count; i++) HostProfile({'id': '$i'})
        ]);
    expect(() => assertSafeSyncShrink(hosts(2), hosts(5), null),
        throwsA(isA<SyncShrinkException>()));
    expect(() => assertSafeSyncShrink(hosts(89), hosts(100), null),
        throwsA(isA<SyncShrinkException>()));
    expect(
        () => assertSafeSyncShrink(hosts(3), hosts(5), null), returnsNormally);
    expect(() => assertSafeSyncShrink(hosts(0), null, hosts(5)),
        throwsA(isA<SyncShrinkException>()));
    final base = hosts(1).copyWith(extras: {
      'groupConfigs': [
        {'path': 'group'}
      ]
    });
    expect(() => assertSafeSyncShrink(hosts(1), base, null),
        throwsA(isA<SyncShrinkException>()));
  });

  test('updates a desktop v2 payload without downgrading its envelope',
      () async {
    final remote = _desktopV2Vault();
    final desired = remote.copyWith(
      hosts: [
        HostProfile({'id': 'host-1', 'label': 'Mobile'})
      ],
      extras: const {},
    );

    final updated = updateConvergentSyncPayload(
      remote: remote,
      desired: desired,
      deviceId: 'mobile-device',
      timestamp: 200,
    );

    expect(updated.hosts.single.label, 'Mobile');
    expect(updated.extras['convergentSync'], isA<Map>());
    validateConvergentSyncPayload(updated);

    // Encryption interoperability is exercised by netcatty_crypto_test and
    // provider round-trip tests; this suite only tests causal state semantics.
  });

  test('records a mobile deletion in the desktop v2 causal state', () {
    final remote = _desktopV2Vault();
    final desired = remote.copyWith(hosts: [], extras: const {});

    final updated = updateConvergentSyncPayload(
      remote: remote,
      desired: desired,
      deviceId: 'mobile-device',
      timestamp: 200,
    );

    expect(updated.hosts, isEmpty);
    validateConvergentSyncPayload(updated);
    final envelope = updated.extras['convergentSync'] as Map;
    final state = envelope['state'] as Map;
    final collections = state['collections'] as Map;
    final hosts = collections['hosts'] as Map;
    final entities = hosts['entities'] as Map;
    final entity = entities['host-1'] as Map;
    final presence = entity['presence'] as Map;
    final candidates = presence['candidates'] as List;
    expect((candidates.single as Map)['tombstone'], isTrue);
  });
}

VaultData _desktopV2Vault() => desktopV2Vault();
