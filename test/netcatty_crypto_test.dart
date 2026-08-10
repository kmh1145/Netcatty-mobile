import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/domain/models/vault.dart';
import 'package:netcatty_mobile/infrastructure/sync/netcatty_crypto.dart';

void main() {
  test(
    'decrypts a desktop-compatible Node/WebCrypto AES-GCM fixture',
    () async {
      final fixture = SyncedVaultFile.fromJson(
        jsonDecode(r'''{
      "meta":{"version":1,"updatedAt":0,"deviceId":"node","appVersion":"test","iv":"ICEiIyQlJicoKSor","salt":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=","algorithm":"AES-256-GCM","kdf":"PBKDF2","kdfIterations":600000},
      "payload":"XpWQHpkTt3OcfxHaMbVyXd8zinKKSiF+/EojLtOyM3oboVr9W+1yayvyE3TEfDtaFwJL8aowFuYX/NtNNwhNOlFImWuL6IdPaylpSU8bz860qTpv3pak0VnT6xqVzmKYEoIoUMuZVpKdcNji1O2MFL/6fO1TVJ2HWSbCMxJMlcvjQvPLJDe/z3pQIZJMNTFGeJ0MilIY0qwyBVnh+QavMQJD"
    }''')
            as Map<String, dynamic>,
      );

      final vault = await NetcattyCrypto.decrypt(fixture, 'netcatty-test');
      expect(vault.hosts.single.label, 'Demo');
      expect(vault.hosts.single.hostname, 'example.com');
    },
  );

  test('round-trips a vault and rejects the wrong password', () async {
    final vault = VaultData.fromJson({
      'hosts': [
        {
          'id': 'host-1',
          'label': 'Production',
          'hostname': '10.0.0.1',
          'username': 'root',
          'tags': ['prod'],
          'os': 'linux',
          'futureDesktopField': {'preserved': true},
        },
      ],
      'keys': [],
      'snippets': [],
      'customGroups': ['Production'],
      'pluginSidecars': {
        'example.plugin': {'version': 1},
      },
    });
    final encrypted = await NetcattyCrypto.encrypt(
      vault: vault,
      password: 'correct horse battery staple',
      deviceId: 'mobile-test',
      deviceName: 'Test Phone',
      appVersion: 'test',
    );
    final decrypted = await NetcattyCrypto.decrypt(
      encrypted,
      'correct horse battery staple',
    );
    expect(decrypted.hosts.single.data['futureDesktopField'], {
      'preserved': true,
    });
    expect(decrypted.extras['pluginSidecars'], isNotNull);
    await expectLater(
      NetcattyCrypto.decrypt(encrypted, 'wrong'),
      throwsA(isA<FormatException>()),
    );
  });
}
