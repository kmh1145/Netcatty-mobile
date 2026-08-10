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
}
