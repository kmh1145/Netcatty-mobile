import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../../domain/models/settings.dart';
import '../../domain/models/vault.dart';
import '../storage/vault_repository.dart';
import 'netcatty_crypto.dart';
import 'vault_merge_service.dart';

class CloudSyncResult {
  const CloudSyncResult({
    required this.vault,
    required this.message,
    required this.versions,
  });
  final VaultData vault;
  final String message;
  final CloudSyncVersions versions;
}

class CloudSyncVersions {
  const CloudSyncVersions({
    required this.localVersion,
    required this.cloudVersion,
    required this.baseVersion,
    required this.hasLocalChanges,
  });

  final int localVersion;
  final int cloudVersion;
  final int? baseVersion;
  final bool hasLocalChanges;
}

class CloudSyncConflictException implements Exception {
  const CloudSyncConflictException();

  @override
  String toString() => '云端保险库在同步期间发生变化，请重试';
}

class _RemoteVault {
  const _RemoteVault(this.file, this.revision);
  final SyncedVaultFile file;
  final String? revision;
}

class _UploadResult {
  const _UploadResult({required this.version, required this.connection});
  final int version;
  final SyncConnection connection;
}

class CloudSyncService {
  CloudSyncService(
    this.repository, {
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 25),
    this.maxResponseBytes = 8 * 1024 * 1024,
    String? deviceId,
    String? appVersion,
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null,
        _injectedDeviceId = deviceId,
        _injectedAppVersion = appVersion;

  final VaultRepository repository;
  final http.Client _client;
  final bool _ownsClient;
  final Duration requestTimeout;
  final int maxResponseBytes;
  final String? _injectedDeviceId;
  final String? _injectedAppVersion;

  void close() {
    if (_ownsClient) _client.close();
  }

  Future<CloudSyncResult> pullAndMerge(VaultData local) async {
    return _synchronize(local, createdMessage: '已创建加密云端保险库');
  }

  Future<CloudSyncResult> push(VaultData vault) async {
    return _synchronize(vault, createdMessage: '加密上传完成');
  }

  Future<CloudSyncVersions> inspectVersions(VaultData local) async {
    final setup = await _setup();
    final remote = await _download(setup.connection);
    return _versionsFor(
      local,
      setup.connection,
      cloudVersion: remote == null ? 0 : _fileVersion(remote.file),
    );
  }

  Future<CloudSyncResult> _synchronize(
    VaultData local, {
    required String createdMessage,
  }) async {
    final setup = await _setup();
    for (var attempt = 0; attempt < 3; attempt++) {
      final remote = await _download(setup.connection);
      if (remote == null) {
        try {
          final uploaded =
              await _uploadNew(setup.connection, local, setup.password);
          await repository.saveVault(local);
          await _saveCheckpoint(
            local,
            uploaded.connection,
            uploaded.version,
          );
          return CloudSyncResult(
            vault: local,
            message: createdMessage,
            versions: CloudSyncVersions(
              localVersion: uploaded.version,
              cloudVersion: uploaded.version,
              baseVersion: uploaded.version,
              hasLocalChanges: false,
            ),
          );
        } on CloudSyncConflictException {
          if (attempt == 2) rethrow;
          continue;
        }
      }
      final downloaded = await NetcattyCrypto.decrypt(
        remote.file,
        setup.password,
      );
      final merged = mergeVaults(
        local: local,
        remote: downloaded,
        remoteFallbackTimestamp:
            (remote.file.meta['updatedAt'] as num?)?.toInt() ?? 0,
      );
      try {
        var finalVersion = _fileVersion(remote.file);
        if (jsonEncode(merged.toJson()) != jsonEncode(downloaded.toJson())) {
          final uploaded = await _upload(
            setup.connection,
            await _encrypt(
              merged,
              setup.password,
              previousVersion: finalVersion,
            ),
            expectedRevision: remote.revision,
          );
          finalVersion = uploaded.version;
        }
        await repository.saveVault(merged);
        await _saveCheckpoint(merged, setup.connection, finalVersion);
        return CloudSyncResult(
          vault: merged,
          message: '同步完成',
          versions: CloudSyncVersions(
            localVersion: finalVersion,
            cloudVersion: finalVersion,
            baseVersion: finalVersion,
            hasLocalChanges: false,
          ),
        );
      } on CloudSyncConflictException {
        if (attempt == 2) rethrow;
      }
    }
    throw const CloudSyncConflictException();
  }

  Future<({SyncConnection connection, String password})> _setup() async {
    var connection = await repository.loadSyncConnection();
    final password = await repository.readMasterPassword();
    if (connection == null || password == null || password.isEmpty) {
      throw StateError('请先在设置中配置云同步与同步密码');
    }
    if (connection.type == SyncProviderType.githubGist) {
      if (connection.secret?.isNotEmpty != true) {
        throw StateError('请先登录 GitHub');
      }
      if (connection.resourceId?.isNotEmpty != true) {
        final id = await _discoverGist(connection);
        if (id != null) {
          connection = SyncConnection(
            type: connection.type,
            endpoint: connection.endpoint,
            username: connection.username,
            secret: connection.secret,
            resourceId: id,
          );
          await repository.saveSyncConnection(connection);
        }
      }
    }
    if (connection.type == SyncProviderType.webdav &&
        Uri.tryParse(connection.endpoint)?.scheme != 'https') {
      throw StateError('WebDAV 必须使用 HTTPS 地址');
    }
    return (connection: connection, password: password);
  }

  Future<_UploadResult> _uploadNew(
    SyncConnection connection,
    VaultData vault,
    String password,
  ) async =>
      _upload(
        connection,
        await _encrypt(vault, password),
        createOnly: true,
      );

  Future<SyncedVaultFile> _encrypt(
    VaultData vault,
    String password, {
    int previousVersion = 0,
  }) async {
    final deviceId =
        _injectedDeviceId ?? await repository.readOrCreateDeviceId();
    final appVersion =
        _injectedAppVersion ?? (await PackageInfo.fromPlatform()).version;
    return NetcattyCrypto.encrypt(
      vault: vault,
      password: password,
      deviceId: deviceId,
      deviceName: 'Netcatty Mobile',
      appVersion: appVersion,
      previousVersion: previousVersion,
    );
  }

  Future<_RemoteVault?> _download(SyncConnection connection) async {
    if (connection.type == SyncProviderType.githubGist &&
        (connection.resourceId == null || connection.resourceId!.isEmpty)) {
      return null;
    }
    final response = connection.type == SyncProviderType.webdav
        ? await _request(_client.get(
            _webdavUri(connection),
            headers: _webdavHeaders(connection),
          ))
        : await _request(_client.get(
            Uri.parse('https://api.github.com/gists/${connection.resourceId}'),
            headers: _githubHeaders(connection),
          ));
    if (response.statusCode == 404) return null;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('云端读取失败 (${response.statusCode})');
    }
    _ensureResponseSize(response);
    if (connection.type == SyncProviderType.webdav) {
      return _RemoteVault(
        SyncedVaultFile.fromJson(_decodeJsonObject(response.body)),
        response.headers['etag'],
      );
    }
    final gist = jsonDecode(response.body) as Map<String, dynamic>;
    final file = (gist['files'] as Map)['netcatty-vault.json'] as Map?;
    if (file == null) return null;
    if (file['truncated'] == true && file['raw_url'] != null) {
      final raw = await _request(_client.get(
        Uri.parse(file['raw_url'].toString()),
        headers: _githubHeaders(connection),
      ));
      if (raw.statusCode < 200 || raw.statusCode >= 300) {
        throw StateError('Gist 大文件读取失败 (${raw.statusCode})');
      }
      _ensureResponseSize(raw);
      return _RemoteVault(
        SyncedVaultFile.fromJson(_decodeJsonObject(raw.body)),
        response.headers['etag'],
      );
    }
    return _RemoteVault(
      SyncedVaultFile.fromJson(
        jsonDecode(file['content'] as String) as Map<String, dynamic>,
      ),
      response.headers['etag'],
    );
  }

  Future<_UploadResult> _upload(
    SyncConnection connection,
    SyncedVaultFile file, {
    String? expectedRevision,
    bool createOnly = false,
  }) async {
    final body = jsonEncode(file.toJson());
    late http.Response response;
    if (connection.type == SyncProviderType.webdav) {
      response = await _request(_client.put(
        _webdavUri(connection),
        headers: {
          ..._webdavHeaders(connection),
          'content-type': 'application/json',
          if (expectedRevision != null) 'if-match': expectedRevision,
          if (createOnly) 'if-none-match': '*',
        },
        body: body,
      ));
    } else {
      final gistBody = jsonEncode({
        'description': 'Netcatty Encrypted Vault (DO NOT EDIT MANUALLY)',
        'public': false,
        'files': {
          'netcatty-vault.json': {'content': body},
        },
      });
      final id = connection.resourceId;
      if (id != null && id.isNotEmpty && expectedRevision != null) {
        final currentRevision = await _readGithubRevision(connection, id);
        if (currentRevision != expectedRevision) {
          throw const CloudSyncConflictException();
        }
      }
      response = id == null || id.isEmpty
          ? await _request(_client.post(
              Uri.parse('https://api.github.com/gists'),
              headers: _githubHeaders(connection),
              body: gistBody,
            ))
          : await _request(_client.patch(
              Uri.parse('https://api.github.com/gists/$id'),
              headers: _githubHeaders(connection),
              body: gistBody,
            ));
    }
    if (response.statusCode == 409 || response.statusCode == 412) {
      throw const CloudSyncConflictException();
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        connection.type == SyncProviderType.githubGist
            ? _githubError('云端写入失败', response)
            : '云端写入失败 (${response.statusCode})',
      );
    }
    var updatedConnection = connection;
    if (connection.type == SyncProviderType.githubGist &&
        (connection.resourceId == null || connection.resourceId!.isEmpty)) {
      final created = jsonDecode(response.body) as Map<String, dynamic>;
      final id = created['id']?.toString();
      if (id != null && id.isNotEmpty) {
        updatedConnection = SyncConnection(
          type: connection.type,
          endpoint: connection.endpoint,
          username: connection.username,
          secret: connection.secret,
          resourceId: id,
        );
        await repository.saveSyncConnection(
          updatedConnection,
        );
      }
    }
    return _UploadResult(
      version: _fileVersion(file),
      connection: updatedConnection,
    );
  }

  Future<String?> _readGithubRevision(
    SyncConnection connection,
    String gistId,
  ) async {
    final response = await _request(_client.get(
      Uri.parse('https://api.github.com/gists/$gistId'),
      headers: _githubHeaders(connection),
    ));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(_githubError('无法确认云端版本', response));
    }
    return response.headers['etag'];
  }

  Uri _webdavUri(SyncConnection connection) {
    final endpoint = connection.endpoint.endsWith('/')
        ? connection.endpoint.substring(0, connection.endpoint.length - 1)
        : connection.endpoint;
    return Uri.parse('$endpoint/netcatty-vault.json');
  }

  Map<String, String> _webdavHeaders(SyncConnection connection) => {
        if (connection.username?.isNotEmpty == true)
          'authorization':
              'Basic ${base64Encode(utf8.encode('${connection.username}:${connection.secret ?? ''}'))}',
      };

  Map<String, String> _githubHeaders(SyncConnection connection) => {
        'accept': 'application/vnd.github+json',
        'content-type': 'application/json',
        'authorization': 'Bearer ${connection.secret ?? ''}',
        'x-github-api-version': '2022-11-28',
      };

  Future<String?> _discoverGist(SyncConnection connection) async {
    for (var page = 1; page <= 10; page++) {
      final response = await _request(_client.get(
        Uri.parse('https://api.github.com/gists?per_page=100&page=$page'),
        headers: _githubHeaders(connection),
      ));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError('无法查找 Netcatty Gist (${response.statusCode})');
      }
      final values = jsonDecode(response.body) as List;
      for (final value in values.whereType<Map>()) {
        final files = value['files'];
        final description = value['description']?.toString();
        if ((files is Map && files.containsKey('netcatty-vault.json')) ||
            description == 'Netcatty Encrypted Vault (DO NOT EDIT MANUALLY)') {
          final id = value['id']?.toString();
          if (id?.isNotEmpty == true) return id;
        }
      }
      if (values.length < 100) break;
    }
    return null;
  }

  Future<CloudSyncVersions> _versionsFor(
    VaultData local,
    SyncConnection connection, {
    required int cloudVersion,
  }) async {
    final checkpoint = await repository.loadSyncVersionCheckpoint();
    final target = _syncTarget(connection);
    final fingerprint = await _vaultFingerprint(local);
    if (checkpoint == null || checkpoint.target != target) {
      final emptyFingerprint = await _vaultFingerprint(VaultData.empty());
      final hasLocalChanges = fingerprint != emptyFingerprint;
      return CloudSyncVersions(
        localVersion: hasLocalChanges ? 1 : 0,
        cloudVersion: cloudVersion,
        baseVersion: null,
        hasLocalChanges: hasLocalChanges,
      );
    }
    final hasLocalChanges = checkpoint.vaultFingerprint != fingerprint;
    return CloudSyncVersions(
      localVersion: checkpoint.version + (hasLocalChanges ? 1 : 0),
      cloudVersion: cloudVersion,
      baseVersion: checkpoint.version,
      hasLocalChanges: hasLocalChanges,
    );
  }

  Future<void> _saveCheckpoint(
    VaultData vault,
    SyncConnection connection,
    int version,
  ) async {
    await repository.saveSyncVersionCheckpoint(
      SyncVersionCheckpoint(
        target: _syncTarget(connection),
        version: version,
        vaultFingerprint: await _vaultFingerprint(vault),
      ),
    );
  }

  String _syncTarget(SyncConnection connection) =>
      connection.type == SyncProviderType.githubGist
          ? 'github:${connection.resourceId ?? ''}'
          : 'webdav:${_webdavUri(connection)}';

  int _fileVersion(SyncedVaultFile file) {
    final version = (file.meta['version'] as num?)?.toInt() ?? 0;
    return version < 0 ? 0 : version;
  }

  Future<String> _vaultFingerprint(VaultData vault) async {
    final canonical = _canonicalize(vault.toJson(legacySyncSnapshot: true));
    final digest = await Sha256().hash(utf8.encode(jsonEncode(canonical)));
    return base64UrlEncode(digest.bytes);
  }

  Object? _canonicalize(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((key) => key.toString()).toList()..sort();
      return {
        for (final key in keys) key: _canonicalize(value[key]),
      };
    }
    if (value is List) return value.map(_canonicalize).toList();
    return value;
  }

  String _githubError(String label, http.Response response) {
    var detail = '';
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map && decoded['message'] != null) {
        detail = decoded['message'].toString().trim();
      }
    } on Object {
      detail = response.body.trim();
    }
    if (detail.length > 240) detail = '${detail.substring(0, 240)}…';
    final requestId = response.headers['x-github-request-id'];
    return '$label (${response.statusCode})'
        '${detail.isEmpty ? '' : '：$detail'}'
        '${requestId == null || requestId.isEmpty ? '' : ' · Request ID $requestId'}';
  }

  Map<String, dynamic> _decodeJsonObject(String input) {
    final raw = input.trim();
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } on FormatException {
      var depth = 0;
      var inString = false;
      var escaped = false;
      for (var index = 0; index < raw.length; index++) {
        final unit = raw.codeUnitAt(index);
        if (inString) {
          if (escaped) {
            escaped = false;
          } else if (unit == 0x5c) {
            escaped = true;
          } else if (unit == 0x22) {
            inString = false;
          }
          continue;
        }
        if (unit == 0x22) {
          inString = true;
        } else if (unit == 0x7b) {
          depth++;
        } else if (unit == 0x7d) {
          depth--;
          if (depth == 0) {
            return jsonDecode(raw.substring(0, index + 1))
                as Map<String, dynamic>;
          }
        }
      }
      rethrow;
    }
  }

  Future<http.Response> _request(Future<http.Response> request) async {
    try {
      return await request.timeout(requestTimeout);
    } on TimeoutException {
      throw StateError('云同步请求超时，请检查网络后重试');
    }
  }

  void _ensureResponseSize(http.Response response) {
    if (response.bodyBytes.length > maxResponseBytes) {
      throw StateError('云端保险库超过 ${maxResponseBytes ~/ (1024 * 1024)} MB 限制');
    }
  }
}
