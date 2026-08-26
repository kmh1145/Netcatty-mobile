import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../domain/models/host.dart';
import '../../domain/models/settings.dart';
import '../../domain/models/vault.dart';

final vaultRepositoryProvider = Provider<VaultRepository>(
  (ref) => throw StateError('VaultRepository has not been initialized'),
);

enum VaultChangeOrigin { local, remote }

class VaultChange {
  const VaultChange(this.vault, this.origin);

  final VaultData vault;
  final VaultChangeOrigin origin;
}

class VaultRepository {
  VaultRepository._(this._preferences, this._secureStorage);

  static const _vaultKey = 'netcatty_mobile_vault_v1';
  static const _settingsKey = 'netcatty_mobile_settings_v1';
  static const _syncKey = 'netcatty_mobile_sync_v1';
  static const _syncVersionKey = 'netcatty_mobile_sync_version_v1';
  static const _masterPasswordKey = 'netcatty.mobile.sync.masterPassword';
  static const _aiApiKey = 'netcatty.mobile.ai.apiKey';
  static const _deviceIdKey = 'netcatty_mobile_device_id_v1';

  final SharedPreferences _preferences;
  final FlutterSecureStorage _secureStorage;
  final _changes = StreamController<VaultChange>.broadcast();
  VaultData? _cachedVault;
  Future<VaultData>? _vaultLoad;
  bool _vaultSecretsLoaded = false;

  static Future<VaultRepository> open() async {
    final repository = VaultRepository._(
      await SharedPreferences.getInstance(),
      const FlutterSecureStorage(
        aOptions: AndroidOptions(encryptedSharedPreferences: true),
        iOptions: IOSOptions(
          accessibility: KeychainAccessibility.first_unlock_this_device,
        ),
      ),
    );
    repository.loadVaultPreview();
    return repository;
  }

  Stream<VaultData> get changes => _changes.stream.map((event) => event.vault);

  /// Emits only user-originated mutations. Cloud sync listens to this stream
  /// so applying a downloaded vault never schedules an upload loop.
  Stream<VaultData> get localChanges => _changes.stream
      .where((event) => event.origin == VaultChangeOrigin.local)
      .map((event) => event.vault);

  /// Returns the non-secret part of the vault directly from the in-memory
  /// preferences snapshot. This lets list-oriented screens render without
  /// waiting for platform keychain calls.
  VaultData? loadVaultPreview() {
    if (_cachedVault != null) return _cachedVault;
    try {
      return _cachedVault = _readStoredVault();
    } on Object {
      return null;
    }
  }

  Future<VaultData> loadVault() {
    if (_vaultSecretsLoaded && _cachedVault != null) {
      return Future.value(_cachedVault);
    }
    final active = _vaultLoad;
    if (active != null) return active;
    final operation = _loadVaultWithSecrets();
    _vaultLoad = operation;
    return operation.whenComplete(() {
      if (identical(_vaultLoad, operation)) _vaultLoad = null;
    });
  }

  VaultData _readStoredVault() {
    final raw = _preferences.getString(_vaultKey);
    if (raw == null) return VaultData.empty();
    return VaultData.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<VaultData> _loadVaultWithSecrets() async {
    final vault = _cachedVault ?? _readStoredVault();
    await Future.wait([
      ...vault.hosts.map(_loadHostSecrets),
      ...vault.keys.map(_loadKeySecrets),
      ...vault.proxyProfiles.map(_loadProxySecrets),
    ]);
    // A metadata-only edit (for example a snippet mutation) may complete while
    // platform keychain reads are still in flight. Keep that newer snapshot;
    // its host/key objects already received the hydrated secrets above.
    final latest = _cachedVault;
    final result = latest != null && !identical(latest, vault) ? latest : vault;
    _cachedVault = result;
    _vaultSecretsLoaded = true;
    return result;
  }

  Future<void> _loadHostSecrets(HostProfile host) async {
    final values = await Future.wait([
      _secureStorage.read(
        key: 'host.${host.id}.password',
      ),
      _secureStorage.read(
        key: 'host.${host.id}.telnetPassword',
      ),
      _secureStorage.read(
        key: 'host.${host.id}.proxyPassword',
      ),
    ]);
    final password = values[0];
    final telnet = values[1];
    final proxyPassword = values[2];
    if (password != null) host.data['password'] = password;
    if (telnet != null) host.data['telnetPassword'] = telnet;
    if (proxyPassword != null && host.data['proxyConfig'] is Map) {
      host.data['proxyConfig'] = {
        ...Map<String, dynamic>.from(host.data['proxyConfig'] as Map),
        'password': proxyPassword,
      };
    }
  }

  Future<void> _loadKeySecrets(SshKeyProfile key) async {
    final values = await Future.wait([
      _secureStorage.read(
        key: 'key.${key.id}.private',
      ),
      _secureStorage.read(
        key: 'key.${key.id}.passphrase',
      ),
    ]);
    final privateKey = values[0];
    final passphrase = values[1];
    if (privateKey != null) key.data['privateKey'] = privateKey;
    if (passphrase != null) key.data['passphrase'] = passphrase;
  }

  Future<void> _loadProxySecrets(ProxyProfile profile) async {
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

  Future<void> saveVault(VaultData vault, {bool remote = false}) async {
    final activeLoad = _vaultLoad;
    if (activeLoad != null) await activeLoad;
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
    for (final host in vault.hosts) {
      await _writeSecret('host.${host.id}.password', host.password);
      await _writeSecret(
        'host.${host.id}.telnetPassword',
        host.data['telnetPassword']?.toString(),
      );
      final proxy = host.proxyConfig;
      await _writeSecret('host.${host.id}.proxyPassword', proxy?.password);
    }
    for (final key in vault.keys) {
      await _writeSecret('key.${key.id}.private', key.privateKey);
      await _writeSecret('key.${key.id}.passphrase', key.passphrase);
    }
    for (final profile in vault.proxyProfiles) {
      final config = profile.config;
      await _writeSecret('proxy.${profile.id}.password', config?.password);
    }
    final sanitized = _withoutSecrets(vault);
    await _preferences.setString(_vaultKey, jsonEncode(sanitized.toJson()));
    _cachedVault = vault;
    _vaultSecretsLoaded = true;
    _changes.add(VaultChange(
      vault,
      remote ? VaultChangeOrigin.remote : VaultChangeOrigin.local,
    ));
  }

  /// Persists fields that never contain credentials without touching the
  /// platform keychain. This is intentionally limited to controller paths that
  /// only change snippets or other known non-secret metadata.
  Future<void> saveVaultMetadata(VaultData vault) async {
    final previousCache = _cachedVault;
    _cachedVault = vault;
    try {
      final sanitized = _withoutSecrets(vault);
      await _preferences.setString(_vaultKey, jsonEncode(sanitized.toJson()));
      _changes.add(VaultChange(vault, VaultChangeOrigin.local));
    } on Object {
      if (identical(_cachedVault, vault)) _cachedVault = previousCache;
      rethrow;
    }
  }

  VaultData _withoutSecrets(VaultData vault) {
    final sanitized = VaultData.fromJson(vault.toJson());
    for (final host in sanitized.hosts) {
      host.data.remove('password');
      host.data.remove('telnetPassword');
      if (host.data['proxyConfig'] is Map) {
        host.data['proxyConfig'] =
            Map<String, dynamic>.from(host.data['proxyConfig'] as Map)
              ..remove('password');
      }
    }
    for (final key in sanitized.keys) {
      key.data['privateKey'] = '';
      key.data.remove('passphrase');
    }
    for (final profile in sanitized.proxyProfiles) {
      if (profile.data['config'] is Map) {
        profile.data['config'] =
            Map<String, dynamic>.from(profile.data['config'] as Map)
              ..remove('password');
      }
    }
    return sanitized;
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
    final sessionToken =
        await _secureStorage.read(key: 'sync.provider.sessionToken');
    return connection.copyWith(secret: secret, sessionToken: sessionToken);
  }

  Future<void> saveSyncConnection(SyncConnection connection) async {
    await _preferences.setString(_syncKey, jsonEncode(connection.toJson()));
    await _writeSecret('sync.provider.secret', connection.secret);
    await _writeSecret(
      'sync.provider.sessionToken',
      connection.sessionToken,
    );
  }

  Future<SyncVersionCheckpoint?> loadSyncVersionCheckpoint() async {
    final raw = _preferences.getString(_syncVersionKey);
    if (raw == null) return null;
    try {
      final checkpoint = SyncVersionCheckpoint.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      return checkpoint.target.isEmpty ||
              checkpoint.version < 0 ||
              checkpoint.vaultFingerprint.isEmpty
          ? null
          : checkpoint;
    } on Object {
      return null;
    }
  }

  Future<void> saveSyncVersionCheckpoint(
    SyncVersionCheckpoint checkpoint,
  ) =>
      _preferences.setString(
        _syncVersionKey,
        jsonEncode(checkpoint.toJson()),
      );

  Future<void> clearSyncVersionCheckpoint() =>
      _preferences.remove(_syncVersionKey);

  Future<String?> readMasterPassword() =>
      _secureStorage.read(key: _masterPasswordKey);
  Future<void> saveMasterPassword(String? value) =>
      _writeSecret(_masterPasswordKey, value);
  Future<String?> readAiApiKey() => _secureStorage.read(key: _aiApiKey);
  Future<void> saveAiApiKey(String? value) => _writeSecret(_aiApiKey, value);

  Future<String> readOrCreateDeviceId() async {
    final existing = _preferences.getString(_deviceIdKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final created = const Uuid().v4();
    await _preferences.setString(_deviceIdKey, created);
    return created;
  }

  Future<void> _writeSecret(String key, String? value) async {
    if (value == null || value.isEmpty) {
      await _secureStorage.delete(key: key);
    } else {
      await _secureStorage.write(key: key, value: value);
    }
  }
}
