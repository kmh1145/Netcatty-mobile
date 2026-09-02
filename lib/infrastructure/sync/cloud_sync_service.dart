import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

import '../../domain/models/settings.dart';
import '../../domain/models/vault.dart';
import '../storage/vault_repository.dart';
import 'convergent_sync_adapter.dart';
import 'netcatty_crypto.dart';
import 's3_sync_client.dart';
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
    return synchronize(local);
  }

  Future<CloudSyncResult> push(VaultData vault) async {
    return synchronize(vault);
  }

  /// Performs the same download, three-way merge and round-trip used by the
  /// desktop client. Both automatic and manual sync call this single path.
  Future<CloudSyncResult> synchronize(VaultData local) async =>
      _synchronize(local);

  Future<CloudSyncVersions> inspectVersions(VaultData local) async {
    final setup = await _setup();
    final remote = await _download(setup.connection);
    return _versionsFor(
      local,
      setup.connection,
      cloudVersion: remote == null ? 0 : _fileVersion(remote.file),
    );
  }

  Future<void> testS3Connection(SyncConnection connection) =>
      _withTimeout(S3SyncClient(client: _client).testConnection(connection));

  Future<CloudSyncResult> _synchronize(VaultData local) async {
    final setup = await _setup();
    for (var attempt = 0; attempt < 3; attempt++) {
      final remote = await _download(setup.connection);
      if (remote == null) {
        try {
          final deviceId =
              _injectedDeviceId ?? await repository.readOrCreateDeviceId();
          final outgoing = withSyncReliabilityMeta(
            sanitizeVaultForSync(local),
            null,
            deviceId: deviceId,
          );
          final encrypted = await _encrypt(outgoing, setup.password);
          final uploaded = await _upload(setup.connection, encrypted);
          final applied = retainLocalDeviceData(outgoing, local);
          await repository.saveVault(applied, remote: true);
          await _saveCheckpoint(
            outgoing,
            uploaded.connection,
            uploaded.version,
            encrypted,
          );
          return CloudSyncResult(
            vault: applied,
            message: '已创建加密云端保险库',
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
      _assertSupportedSyncSchema(remote.file);
      final downloaded = await NetcattyCrypto.decrypt(
        remote.file,
        setup.password,
      );
      final remoteSchema = _syncSchema(remote.file);
      if (remoteSchema == 2) _validateConvergentPayload(downloaded);
      final base = await _loadSyncBase(
        setup.connection,
        setup.password,
      );
      final merged = mergeVaults(
        base: base,
        local: local,
        remote: downloaded,
      );
      try {
        var finalVersion = _fileVersion(remote.file);
        final deviceId =
            _injectedDeviceId ?? await repository.readOrCreateDeviceId();
        final outgoing = withSyncReliabilityMeta(
          merged,
          base,
          deviceId: deviceId,
        );
        var baseFile = remote.file;
        if (!cloudSyncPayloadsEqual(outgoing, downloaded) ||
            hasUnpublishedSyncDeletions(outgoing, downloaded)) {
          final wireVault = remoteSchema == 2
              ? _updateConvergentPayload(downloaded, outgoing, deviceId)
              : outgoing;
          final encrypted = await _encrypt(
            wireVault,
            setup.password,
            previousVersion: finalVersion,
          );
          final uploaded = await _upload(
            setup.connection,
            encrypted,
            expectedRevision: remote.revision,
          );
          finalVersion = uploaded.version;
          baseFile = encrypted;
        }
        final applied = retainLocalDeviceData(outgoing, local);
        await repository.saveVault(applied, remote: true);
        await _saveCheckpoint(
          outgoing,
          setup.connection,
          finalVersion,
          baseFile,
        );
        return CloudSyncResult(
          vault: applied,
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
          connection = connection.copyWith(resourceId: id);
          await repository.saveSyncConnection(connection);
        }
      }
    }
    if (connection.type == SyncProviderType.webdav &&
        _normalizedWebdavEndpoint(connection.endpoint).scheme != 'https') {
      throw StateError('WebDAV 必须使用 HTTPS 地址');
    }
    return (connection: connection, password: password);
  }

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
    if (connection.type == SyncProviderType.s3) {
      final response = await _withTimeout(
        S3SyncClient(client: _client).getVault(connection),
      );
      if (response == null) return null;
      final bytes = utf8.encode(response.body);
      if (bytes.length > maxResponseBytes) {
        throw StateError(
          '云端保险库超过 ${maxResponseBytes ~/ (1024 * 1024)} MB 限制',
        );
      }
      return _RemoteVault(
        SyncedVaultFile.fromJson(_decodeJsonObject(response.body)),
        response.revision,
      );
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
  }) async {
    final body = jsonEncode(file.toJson());
    if (connection.type == SyncProviderType.s3) {
      final s3 = S3SyncClient(client: _client);
      if (expectedRevision != null) {
        final current = await _withTimeout(s3.getVault(connection));
        if (current?.revision != expectedRevision) {
          throw const CloudSyncConflictException();
        }
      }
      await _withTimeout(s3.putVault(connection, body));
      return _UploadResult(
        version: _fileVersion(file),
        connection: connection,
      );
    }
    late http.Response response;
    if (connection.type == SyncProviderType.webdav) {
      if (expectedRevision != null) {
        final current = await _request(
          _client.get(
            _webdavUri(connection),
            headers: _webdavHeaders(connection),
          ),
        );
        if (current.statusCode == 404 ||
            current.statusCode < 200 ||
            current.statusCode >= 300 ||
            current.headers['etag'] != expectedRevision) {
          throw const CloudSyncConflictException();
        }
      }
      await _replaceWebdavFile(connection, body);
      response = http.Response('', 204);
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
        updatedConnection = connection.copyWith(resourceId: id);
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
    final endpoint = _normalizedWebdavEndpoint(connection.endpoint);
    final path = endpoint.path.endsWith('/')
        ? '${endpoint.path}netcatty-vault.json'
        : '${endpoint.path}/netcatty-vault.json';
    return endpoint.replace(path: path);
  }

  Uri _normalizedWebdavEndpoint(String value) {
    final trimmed = value.trim();
    final normalized =
        RegExp(r'^https?://', caseSensitive: false).hasMatch(trimmed)
            ? trimmed
            : 'https://$trimmed';
    final endpoint = Uri.tryParse(normalized);
    if (endpoint == null || endpoint.host.isEmpty) {
      throw StateError('WebDAV 地址无效');
    }
    return endpoint;
  }

  Future<void> _replaceWebdavFile(
    SyncConnection connection,
    String body,
  ) async {
    final target = _webdavUri(connection);
    final temporary = target.replace(path: '${target.path}.tmp');
    final expected = utf8.encode(body);

    // Match desktop Netcatty's WebDAV replacement strategy. Some lightweight
    // servers overwrite files without truncating them, leaving bytes from the
    // previous (longer) vault after the new JSON document.
    try {
      var temporaryLength = 0;
      try {
        temporaryLength = await _webdavLength(connection, temporary);
      } on Object {
        // A stale temp file is optional; inability to inspect it should not
        // prevent trying the atomic path.
      }
      await _putWebdav(
        connection,
        temporary,
        _padWebdavBody(expected, temporaryLength),
      );
      await _moveWebdav(connection, temporary, target);
      final moved = await _readWebdavBytes(connection, target);
      if (moved != null && _matchesWebdavBody(moved, expected)) return;
    } on Object {
      // MOVE is optional in WebDAV deployments. Fall back to the same padded
      // in-place PUT used by desktop Netcatty.
    }
    await _deleteWebdavBestEffort(connection, temporary);

    var minimumLength = await _webdavLength(connection, target);
    if (minimumLength < expected.length) minimumLength = expected.length;
    for (var attempt = 0; attempt < 3; attempt++) {
      final payload = _padWebdavBody(expected, minimumLength);
      await _putWebdav(connection, target, payload);
      final remote = await _readWebdavBytes(connection, target);
      if (remote != null && _matchesWebdavBody(remote, expected)) return;
      minimumLength = remote == null
          ? expected.length
          : remote.length > expected.length
              ? remote.length
              : expected.length;
    }
    throw StateError('WebDAV 上传校验失败：远端文件与上传内容不一致');
  }

  Future<int> _webdavLength(
    SyncConnection connection,
    Uri uri,
  ) async {
    final bytes = await _readWebdavBytes(connection, uri);
    return bytes?.length ?? 0;
  }

  Future<List<int>?> _readWebdavBytes(
    SyncConnection connection,
    Uri uri,
  ) async {
    final response = await _request(
      _client.get(uri, headers: _webdavHeaders(connection)),
    );
    if (response.statusCode == 404) return null;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('WebDAV 读取失败 (${response.statusCode})');
    }
    _ensureResponseSize(response);
    return response.bodyBytes;
  }

  Future<void> _putWebdav(
    SyncConnection connection,
    Uri uri,
    List<int> body,
  ) async {
    final response = await _request(_client.put(
      uri,
      headers: {
        ..._webdavHeaders(connection),
        'content-type': 'application/json; charset=utf-8',
      },
      body: body,
    ));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('WebDAV 写入失败 (${response.statusCode})');
    }
  }

  Future<void> _moveWebdav(
    SyncConnection connection,
    Uri source,
    Uri destination,
  ) async {
    final request = http.Request('MOVE', source)
      ..headers.addAll({
        ..._webdavHeaders(connection),
        'destination': destination.toString(),
        'overwrite': 'T',
      });
    final response = await _request(
      _client.send(request).then(http.Response.fromStream),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('WebDAV MOVE 失败 (${response.statusCode})');
    }
  }

  Future<void> _deleteWebdavBestEffort(
    SyncConnection connection,
    Uri uri,
  ) async {
    try {
      await _request(
        _client.delete(uri, headers: _webdavHeaders(connection)),
      );
    } on Object {
      // Temp-file cleanup must not hide the in-place fallback result.
    }
  }

  List<int> _padWebdavBody(List<int> body, int minimumLength) {
    if (body.length >= minimumLength) return body;
    return <int>[
      ...body,
      ...List<int>.filled(minimumLength - body.length, 0x20)
    ];
  }

  bool _matchesWebdavBody(List<int> remote, List<int> expected) {
    if (remote.length < expected.length) return false;
    for (var index = 0; index < expected.length; index++) {
      if (remote[index] != expected[index]) return false;
    }
    for (var index = expected.length; index < remote.length; index++) {
      final byte = remote[index];
      if (byte != 0x20 && byte != 0x09 && byte != 0x0a && byte != 0x0d) {
        return false;
      }
    }
    return true;
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
    final fingerprint = await cloudSyncPayloadFingerprint(local);
    if (checkpoint == null || checkpoint.target != target) {
      final emptyFingerprint =
          await cloudSyncPayloadFingerprint(VaultData.empty());
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
    SyncedVaultFile encryptedBase,
  ) async {
    await repository.saveSyncVersionCheckpoint(
      SyncVersionCheckpoint(
        target: _syncTarget(connection),
        version: version,
        vaultFingerprint: await cloudSyncPayloadFingerprint(vault),
        encryptedBase: encryptedBase.toJson(),
      ),
    );
  }

  Future<VaultData?> _loadSyncBase(
    SyncConnection connection,
    String password,
  ) async {
    final checkpoint = await repository.loadSyncVersionCheckpoint();
    if (checkpoint == null ||
        checkpoint.target != _syncTarget(connection) ||
        checkpoint.encryptedBase == null) {
      return null;
    }
    try {
      final file = SyncedVaultFile.fromJson(checkpoint.encryptedBase!);
      _assertSupportedSyncSchema(file);
      final decrypted = await NetcattyCrypto.decrypt(file, password);
      if (_syncSchema(file) == 2) _validateConvergentPayload(decrypted);
      return sanitizeVaultForSync(decrypted);
    } on Object {
      // Match desktop behavior: a missing/corrupt local base degrades to a
      // tombstone-aware first merge instead of blocking access to the vault.
      return null;
    }
  }

  void _assertSupportedSyncSchema(SyncedVaultFile file) {
    final raw = file.meta['syncSchemaVersion'];
    if (raw == null) return;
    if (raw is! num || raw.toInt() != raw || raw.toInt() < 1) {
      throw StateError('云端保险库的同步格式标记无效，已停止写入以保护数据');
    }
    final schema = raw.toInt();
    if (schema > 2) {
      throw StateError(
        '云端保险库使用了当前移动版尚不支持的新版同步格式，已停止写入以保护数据',
      );
    }
  }

  int? _syncSchema(SyncedVaultFile file) =>
      (file.meta['syncSchemaVersion'] as num?)?.toInt();

  void _validateConvergentPayload(VaultData vault) {
    try {
      validateConvergentSyncPayload(vault);
    } on FormatException {
      throw StateError(
        '云端保险库的同步格式无效，已停止写入以保护数据',
      );
    }
  }

  VaultData _updateConvergentPayload(
    VaultData remote,
    VaultData desired,
    String deviceId,
  ) {
    try {
      return updateConvergentSyncPayload(
        remote: remote,
        desired: desired,
        deviceId: deviceId,
      );
    } on FormatException {
      throw StateError(
        '云端保险库的同步格式无效，已停止写入以保护数据',
      );
    }
  }

  String _syncTarget(SyncConnection connection) {
    switch (connection.type) {
      case SyncProviderType.githubGist:
        return 'github:${connection.resourceId ?? ''}';
      case SyncProviderType.s3:
        return 's3:${connection.endpoint}|${connection.bucket}|${connection.prefix ?? ''}';
      case SyncProviderType.webdav:
        return 'webdav:${_webdavUri(connection)}';
    }
  }

  int _fileVersion(SyncedVaultFile file) {
    final version = (file.meta['version'] as num?)?.toInt() ?? 0;
    return version < 0 ? 0 : version;
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

  Future<T> _withTimeout<T>(Future<T> request) async {
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
