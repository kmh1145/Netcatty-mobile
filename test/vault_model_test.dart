import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/domain/models/vault.dart';

void main() {
  test('host edits preserve unknown desktop fields', () {
    final host = HostProfile({
      'id': '1',
      'label': 'Old',
      'hostname': 'example.com',
      'username': 'root',
      'tags': <String>[],
      'os': 'linux',
      'pluginConnection': {
        'providerId': 'example.provider',
        'configuration': {'mode': 'future'},
      },
      'algorithms': {
        'kex': ['curve25519-sha256'],
      },
    });
    final edited = host.copyWith(label: 'New');
    expect(edited.label, 'New');
    expect(edited.data['pluginConnection'], host.data['pluginConnection']);
    expect(edited.data['algorithms'], host.data['algorithms']);
  });

  test('legacy snapshot strips stale CRDT envelope only', () {
    final vault = VaultData.fromJson({
      'hosts': [],
      'keys': [],
      'snippets': [],
      'customGroups': [],
      'convergentSync': {'schemaVersion': 2},
      'pluginSidecars': {'kept': true},
    });
    final snapshot = vault.toJson(legacySyncSnapshot: true);
    expect(snapshot.containsKey('convergentSync'), isFalse);
    expect(snapshot['pluginSidecars'], {'kept': true});
  });

  test('host connection routing fields round-trip with desktop names', () {
    final host = HostProfile({
      'id': 'target',
      'label': 'Production',
      'hostname': 'prod.example.com',
      'username': 'root',
      'authMethod': 'key',
      'identityFileId': 'key-1',
      'hostChain': {
        'hostIds': ['jump-1', 'jump-2'],
      },
      'proxyConfig': {
        'type': 'socks5',
        'host': '127.0.0.1',
        'port': 1080,
        'username': 'proxy-user',
      },
    });

    expect(host.authMethod, HostAuthMethod.key);
    expect(host.identityFileId, 'key-1');
    expect(host.hostChainIds, ['jump-1', 'jump-2']);
    expect(host.proxyConfig?.type, ProxyType.socks5);
    expect(host.proxyConfig?.port, 1080);
    expect(host.toJson()['hostChain'], {
      'hostIds': ['jump-1', 'jump-2'],
    });
  });

  test('vault preserves reusable desktop proxy profiles', () {
    final vault = VaultData.fromJson({
      'hosts': [],
      'keys': [],
      'snippets': [],
      'customGroups': [],
      'proxyProfiles': [
        {
          'id': 'proxy-1',
          'label': 'Office SOCKS',
          'config': {'type': 'socks5', 'host': 'proxy.local', 'port': 1080},
          'createdAt': 1,
        },
      ],
    });

    expect(vault.proxyProfiles.single.label, 'Office SOCKS');
    expect(vault.proxyProfiles.single.config?.host, 'proxy.local');
    expect(
      (vault.toJson()['proxyProfiles'] as List).single['id'],
      'proxy-1',
    );
  });
}
