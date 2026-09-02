import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/domain/models/vault.dart';
import 'package:netcatty_mobile/infrastructure/sync/convergent_sync_adapter.dart';
import 'package:netcatty_mobile/infrastructure/sync/netcatty_crypto.dart';

void main() {
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

    final encrypted = await NetcattyCrypto.encrypt(
      vault: updated,
      password: 'password',
      deviceId: 'mobile-device',
      deviceName: 'Mobile',
      appVersion: '1.4.1',
      previousVersion: 4,
    );
    expect(encrypted.meta['syncSchemaVersion'], 2);
    final roundTrip = await NetcattyCrypto.decrypt(encrypted, 'password');
    expect(roundTrip.hosts.single.label, 'Mobile');
    validateConvergentSyncPayload(roundTrip);
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

VaultData _desktopV2Vault() => VaultData.fromJson({
      'hosts': [
        {'id': 'host-1', 'label': 'Desktop'},
      ],
      'keys': <dynamic>[],
      'snippets': <dynamic>[],
      'customGroups': <dynamic>[],
      'proxyProfiles': <dynamic>[],
      'syncedAt': 100,
      'convergentSync': {
        'schemaVersion': 2,
        'encoding': 'materialized-winner-v1',
        'state': {
          'vector': {'desktop-device': 3},
          'dotOrigins': {
            'desktop-device': {
              '1': '["entity-presence","hosts","host-1"]',
              '2': '["entity-position","hosts","host-1"]',
              '3': '["entity-field","hosts","host-1","label"]',
            },
          },
          'hlc': {'wallTime': 100, 'logical': 2},
          'collections': {
            'hosts': {
              'entities': {
                'host-1': {
                  'presence': {
                    'candidates': [
                      {
                        'dot': {'deviceId': 'desktop-device', 'counter': 1},
                        'context': <dynamic>[],
                        'hlc': {'wallTime': 100, 'logical': 0},
                        'value': true,
                      },
                    ],
                  },
                  'position': {
                    'candidates': [
                      {
                        'dot': {'deviceId': 'desktop-device', 'counter': 2},
                        'context': <dynamic>[],
                        'hlc': {'wallTime': 100, 'logical': 1},
                        'value': 0,
                      },
                    ],
                  },
                  'fields': {
                    'label': {
                      'candidates': [
                        {
                          'dot': {
                            'deviceId': 'desktop-device',
                            'counter': 3,
                          },
                          'context': <dynamic>[],
                          'hlc': {'wallTime': 100, 'logical': 2},
                          'materialized': true,
                        },
                      ],
                    },
                  },
                },
              },
            },
          },
          'settings': <String, dynamic>{},
          'stringCollections': <String, dynamic>{},
        },
      },
    });
