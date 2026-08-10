import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/models/settings.dart';
import '../../domain/models/vault.dart';

final vaultRepositoryProvider = Provider<VaultRepository>(
  (ref) => throw StateError('VaultRepository has not been initialized'),
);

class VaultRepository {
  VaultRepository._(this._preferences, this._secureStorage);

  static const _vaultKey = 'netcatty_mobile_vault_v1';
  static const _settingsKey = 'netcatty_mobile_settings_v1';
  static const _syncKey = 'netcatty_mobile_sync_v1';
  static const _masterPasswordKey = 'netcatty.mobile.sync.masterPassword';
  static const _aiApiKey = 'netcatty.mobile.ai.apiKey';

  final SharedPreferences _preferences;
  final FlutterSecureStorage _secureStorage;
  final _changes = StreamController<VaultData>.broadcast();

  static Future<VaultRepository> open() async => VaultRepository._(
        await SharedPreferences.getInstance(),
        const FlutterSecureStorage(
          aOptions: AndroidOptions(encryptedSharedPreferences: true),
          iOptions: IOSOptions(
            accessibility: KeychainAccessibility.first_unlock_this_device,
          ),
        ),
      );

  Stream<VaultData> get changes => _changes.stream;

  Future<VaultData> loadVault() async {
    final raw = _preferences.getString(_vaultKey);
    if (raw == null) return VaultData.empty();
    final vault = VaultData.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    for (final host in vault.hosts) {
      final password = await _secureStorage.read(
        key: 'host.${host.id}.password',
      );
      if (password != null) host.data['password'] = password;
      final telnet = await _secureStorage.read(
        key: 'host.${host.id}.telnetPassword',
      );
      if (telnet != null) host.data['telnetPassword'] = telnet;
      final proxyPassword = await _secureStorage.read(
        key: 'host.${host.id}.proxyPassword',
      );
      if (proxyPassword != null && host.data['proxyConfig'] is Map) {
        host.data['proxyConfig'] = {
          ...Map<String, dynamic>.from(host.data['proxyConfig'] as Map),
          'password': proxyPassword,
        };
      }
    }
    for (final key in vault.keys) {
      final privateKey = await _secureStorage.read(
        key: 'key.${key.id}.private',
      );
      final passphrase = await _secureStorage.read(
        key: 'key.${key.id}.passphrase',
      );
      if (privateKey != null) key.data['privateKey'] = privateKey;
      if (passphrase != null) key.data['passphrase'] = passphrase;
    }
    for (final profile in vault.proxyProfiles) {
      final password = await _secureStorage.read(
        key: 'proxy.${profile.id}.password',
      );
      if (password != null && profile.data['config'] is Map) {
        profile.data['config'] = {
          ...Map<String, dynamic>.from(profile.data['config'] as Map),
          'password': password,
        };
      }
    }
    return vault;
  }

  Future<void> saveVault(VaultData vault) async {
    final previousRaw = _preferences.getString(_vaultKey);
    if (previousRaw != null) {
      final previous = VaultData.fromJson(
        jsonDecode(previousRaw) as Map<String, dynamic>,
      );
      final hostIds = vault.hosts.map((value) => value.id).toSet();
      final keyIds = vault.keys.map((value) => value.id).toSet();
      final proxyIds = vault.proxyProfiles.map((value) => value.id).toSet();
      for (final host in previous.hosts.where(
        (value) => !hostIds.contains(value.id),
      )) {
        await _secureStorage.delete(key: 'host.${host.id}.password');
        await _secureStorage.delete(key: 'host.${host.id}.telnetPassword');
        await _secureStorage.delete(key: 'host.${host.id}.proxyPassword');
      }
      for (final proxy in previous.proxyProfiles.where(
        (value) => !proxyIds.contains(value.id),
      )) {
        await _secureStorage.delete(key: 'proxy.${proxy.id}.password');
      }
      for (final key in previous.keys.where(
        (value) => !keyIds.contains(value.id),
      )) {
        await _secureStorage.delete(key: 'key.${key.id}.private');
        await _secureStorage.delete(key: 'key.${key.id}.passphrase');
      }
    }
    final sanitized = VaultData.fromJson(vault.toJson());
    for (final host in sanitized.hosts) {
      await _writeSecret('host.${host.id}.password', host.password);
      await _writeSecret(
        'host.${host.id}.telnetPassword',
        host.data['telnetPassword']?.toString(),
      );
      host.data.remove('password');
      host.data.remove('telnetPassword');
      final proxy = host.proxyConfig;
      await _writeSecret('host.${host.id}.proxyPassword', proxy?.password);
      if (host.data['proxyConfig'] is Map) {
        host.data['proxyConfig'] =
            Map<String, dynamic>.from(host.data['proxyConfig'] as Map)
              ..remove('password');
      }
    }
    for (final key in sanitized.keys) {
      await _writeSecret('key.${key.id}.private', key.privateKey);
      await _writeSecret('key.${key.id}.passphrase', key.passphrase);
      key.data['privateKey'] = '';
      key.data.remove('passphrase');
    }
    for (final profile in sanitized.proxyProfiles) {
      final config = profile.config;
      await _writeSecret('proxy.${profile.id}.password', config?.password);
      if (profile.data['config'] is Map) {
        profile.data['config'] =
            Map<String, dynamic>.from(profile.data['config'] as Map)
              ..remove('password');
      }
    }
    await _preferences.setString(_vaultKey, jsonEncode(sanitized.toJson()));
    _changes.add(vault);
  }

  Future<AppSettings> loadSettings() async {
    final raw = _preferences.getString(_settingsKey);
    return raw == null
        ? const AppSettings()
        : AppSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> saveSettings(AppSettings settings) =>
      _preferences.setString(_settingsKey, jsonEncode(settings.toJson()));

  Future<SyncConnection?> loadSyncConnection() async {
    final raw = _preferences.getString(_syncKey);
    if (raw == null) return null;
    final connection = SyncConnection.fromJson(
      jsonDecode(raw) as Map<String, dynamic>,
    );
    final secret = await _secureStorage.read(key: 'sync.provider.secret');
    return SyncConnection(
      type: connection.type,
      endpoint: connection.endpoint,
      username: connection.username,
      secret: secret,
      resourceId: connection.resourceId,
    );
  }

  Future<void> saveSyncConnection(SyncConnection connection) async {
    await _preferences.setString(_syncKey, jsonEncode(connection.toJson()));
    await _writeSecret('sync.provider.secret', connection.secret);
  }

  Future<String?> readMasterPassword() =>
      _secureStorage.read(key: _masterPasswordKey);
  Future<void> saveMasterPassword(String? value) =>
      _writeSecret(_masterPasswordKey, value);
  Future<String?> readAiApiKey() => _secureStorage.read(key: _aiApiKey);
  Future<void> saveAiApiKey(String? value) => _writeSecret(_aiApiKey, value);

  Future<void> _writeSecret(String key, String? value) async {
    if (value == null || value.isEmpty) {
      await _secureStorage.delete(key: key);
    } else {
      await _secureStorage.write(key: key, value: value);
    }
  }
}
