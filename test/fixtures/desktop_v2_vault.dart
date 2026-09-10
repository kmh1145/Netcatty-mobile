import 'package:netcatty_mobile/domain/models/vault.dart';

// Synthetic desktop v2 envelope; no real host or account data.
VaultData desktopV2Vault() => VaultData.fromJson({
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
