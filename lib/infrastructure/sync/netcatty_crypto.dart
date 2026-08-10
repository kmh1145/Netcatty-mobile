import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../../domain/models/vault.dart';

class SyncedVaultFile {
  const SyncedVaultFile({required this.meta, required this.payload});

  factory SyncedVaultFile.fromJson(Map<String, dynamic> json) =>
      SyncedVaultFile(
        meta: Map<String, dynamic>.from(json['meta'] as Map),
        payload: json['payload'] as String,
      );

  final Map<String, dynamic> meta;
  final String payload;
  Map<String, dynamic> toJson() => {'meta': meta, 'payload': payload};
}

class NetcattyCrypto {
  static const iterations = 600000;
  static const saltLength = 32;
  static const ivLength = 12;
  static const tagLength = 16;

  static final _pbkdf2 = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: iterations,
    bits: 256,
  );
  static final _aes = AesGcm.with256bits();

  static Future<SyncedVaultFile> encrypt({
    required VaultData vault,
    required String password,
    required String deviceId,
    required String deviceName,
    required String appVersion,
    int previousVersion = 0,
  }) async {
    final random = Random.secure();
    final salt = Uint8List.fromList(
      List<int>.generate(saltLength, (_) => random.nextInt(256)),
    );
    final iv = Uint8List.fromList(
      List<int>.generate(ivLength, (_) => random.nextInt(256)),
    );
    final key = await _pbkdf2.deriveKeyFromPassword(
      password: password,
      nonce: salt,
    );
    // A mobile write is a legacy materialized snapshot. Desktop Netcatty will
    // migrate it into its v2 CRDT replica on the next convergent sync.
    final cleartext = utf8.encode(
      jsonEncode(vault.toJson(legacySyncSnapshot: true)),
    );
    final box = await _aes.encrypt(cleartext, secretKey: key, nonce: iv);
    final ciphertextAndTag = Uint8List.fromList([
      ...box.cipherText,
      ...box.mac.bytes,
    ]);
    return SyncedVaultFile(
      meta: {
        'version': previousVersion + 1,
        'updatedAt': DateTime.now().millisecondsSinceEpoch,
        'deviceId': deviceId,
        'deviceName': deviceName,
        'appVersion': appVersion,
        'iv': base64Encode(iv),
        'salt': base64Encode(salt),
        'algorithm': 'AES-256-GCM',
        'kdf': 'PBKDF2',
        'kdfIterations': iterations,
      },
      payload: base64Encode(ciphertextAndTag),
    );
  }

  static Future<VaultData> decrypt(
    SyncedVaultFile file,
    String password,
  ) async {
    if (file.meta['algorithm'] != 'AES-256-GCM' ||
        file.meta['kdf'] != 'PBKDF2') {
      throw const FormatException('Unsupported Netcatty encryption format');
    }
    final salt = base64Decode(file.meta['salt'] as String);
    final iv = base64Decode(file.meta['iv'] as String);
    final body = base64Decode(file.payload);
    if (body.length <= tagLength) {
      throw const FormatException('Encrypted payload is truncated');
    }
    final key = await Pbkdf2(
      macAlgorithm: Hmac.sha256(),
      iterations: (file.meta['kdfIterations'] as num?)?.toInt() ?? iterations,
      bits: 256,
    ).deriveKeyFromPassword(password: password, nonce: salt);
    final box = SecretBox(
      body.sublist(0, body.length - tagLength),
      nonce: iv,
      mac: Mac(body.sublist(body.length - tagLength)),
    );
    try {
      final cleartext = await _aes.decrypt(box, secretKey: key);
      return VaultData.fromJson(
        jsonDecode(utf8.decode(cleartext)) as Map<String, dynamic>,
      );
    } on SecretBoxAuthenticationError {
      throw const FormatException('同步密码错误或云端文件已损坏');
    }
  }
}
