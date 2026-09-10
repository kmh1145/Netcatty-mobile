import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:uuid/uuid.dart';

import '../../domain/models/settings.dart';
import '../../domain/models/vault.dart';
import '../storage/vault_repository.dart';
import 'convergent_sync_adapter.dart';
import 'netcatty_crypto.dart';
import 's3_sync_client.dart';
import 'sync_safety.dart';
import 'vault_merge_service.dart';

class CloudSyncResult {
  const CloudSyncResult({
    required this.vault,
    required this.message,
    required this.versions,
    this.acknowledge,
    this.validateBeforeApply,
  });
  final VaultData vault;
  final String message;
  final CloudSyncVersions versions;

  /// Clear recovery state only after the coordinator has safely applied it.
  final Future<void> Function()? acknowledge;
  final Future<void> Function()? validateBeforeApply;
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
  Future<CloudSyncResult> synchronize(VaultData local,
          {bool overrideShrink = false}) async =>
      _synchronize(
          VaultData.fromJson(
              jsonDecode(jsonEncode(local.toJson())) as Map<String, dynamic>),
          overrideShrink: overrideShrink);

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

  Future<CloudSyncResult> _synchronize(VaultData local,
      {required bool overrideShrink}) async {
    var setup = await _setup();
    final base = await _loadSyncBase(setup.connection, setup.password);
    final deviceId =
        _injectedDeviceId ?? await repository.readOrCreateDeviceId();
    VaultData? candidate;
    VaultData? pendingBaseline;
    final pending = await repository.loadPendingSyncReplica();
    if (pending != null && pending['target'] == _syncTarget(setup.connection)) {
      final bundle = await NetcattyCrypto.decrypt(
          SyncedVaultFile.fromJson(
              Map<String, dynamic>.from(pending['file'] as Map)),
          setup.password);
      candidate = VaultData.fromJson(
          Map<String, dynamic>.from(bundle.extras['replica'] as Map));
      pendingBaseline = VaultData.fromJson(
          Map<String, dynamic>.from(bundle.extras['baseline'] as Map));
    }
    var localApplied = false;
    for (var attempt = 0; attempt < 3; attempt++) {
      final remote = await _download(setup.connection);
      if (remote == null && base != null) {
        throw StateError('已同步的云端保险库暂时不可见，已停止写入；请检查存储路径或权限后重试');
      }
      if (remote != null) _assertSupportedSyncSchema(remote.file);
      final downloaded = remote == null
          ? VaultData.empty()
          : await NetcattyCrypto.decrypt(remote.file, setup.password);
      final isV2 = remote != null && _syncSchema(remote.file) == 2;
      if (isV2) _validateConvergentPayload(downloaded);
      if (!isV2 && hasConvergentSyncEnvelope(downloaded)) {
        throw StateError('云端保险库的同步格式标记无效，已停止写入以保护数据');
      }
      if (!isV2 &&
          ((candidate != null && hasConvergentSyncEnvelope(candidate)) ||
              (base != null && hasConvergentSyncEnvelope(base)))) {
        throw StateError('云端同步格式已降级，已停止写入以保护删除记录，请先在桌面端确认恢复');
      }
      final legacyMerged =
          mergeVaults(base: base, local: local, remote: downloaded);
      if (isV2) {
        if (!localApplied) {
          if (candidate != null ||
              (base != null && hasConvergentSyncEnvelope(base))) {
            candidate = applyConvergentLocalChanges(
                replica: candidate ?? base!,
                baseline: pendingBaseline ?? base!,
                local: sanitizeVaultForSync(local),
                deviceId: deviceId);
          } else {
            // Desktop migration.ts: a fresh empty device adopts v2; a nonempty
            // legacy snapshot MUST have a trusted base before it can write a
            // delta. An ID union here would resurrect desktop tombstones.
            final localJson = sanitizeVaultForSync(local).toJson();
            final hasEntities = localJson.values
                .any((value) => value is List && value.isNotEmpty);
            if (base == null) {
              if (hasEntities && !cloudSyncPayloadsEqual(local, downloaded)) {
                throw StateError(
                    '缺少可信同步基线，无法安全合并本地数据与云端 v2 保险库。请先导出本地备份，并在桌面端确认数据后重试；本次未写入云端');
              }
              candidate = downloaded;
            } else {
              candidate = applyConvergentLocalChanges(
                  replica: downloaded,
                  baseline: base,
                  local: sanitizeVaultForSync(local),
                  deviceId: deviceId);
            }
          }
          localApplied = true;
        }
        candidate = mergeConvergentPayloads(candidate!, downloaded);
        // Plugin sidecars are opaque host data, outside desktop CRDT registers.
        candidate = candidate.copyWith(extras: {
          ...candidate.extras,
          if (legacyMerged.extras.containsKey('pluginSidecars'))
            'pluginSidecars': legacyMerged.extras['pluginSidecars'],
        });
      } else {
        candidate = remote == null ? sanitizeVaultForSync(local) : legacyMerged;
      }
      try {
        final metadata =
            withSyncReliabilityMeta(candidate, base, deviceId: deviceId);
        final outgoing = isV2
            ? metadata.copyWith(extras: {
                ...metadata.extras,
                'convergentSync': candidate.extras['convergentSync'],
              })
            : metadata;
        var verifiedFile = remote?.file;
        var verifiedVault = downloaded;
        final needsWrite = remote == null ||
            !cloudSyncPayloadsEqual(outgoing, downloaded) ||
            hasUnpublishedSyncDeletions(outgoing, downloaded) ||
            (isV2 && !convergentPayloadDominates(downloaded, outgoing));
        if (needsWrite) {
          if (!overrideShrink) assertSafeSyncShrink(outgoing, base, downloaded);
          await _assertSetupUnchanged(setup.connection, setup.password);
          if (isV2) {
            // Persist before sending: interrupted uploads retain their original
            // dots and local baseline instead of inventing fresh writes on retry.
            final recovery = await _encrypt(
                VaultData.empty().copyWith(extras: {
                  'replica': outgoing.toJson(),
                  'baseline': local.toJson(),
                }),
                setup.password);
            await repository.savePendingSyncReplica({
              'target': _syncTarget(setup.connection),
              'file': recovery.toJson(),
            });
          }
          final encrypted = await _encrypt(outgoing, setup.password,
              previousVersion: remote == null ? 0 : _fileVersion(remote.file));
          await _assertSetupUnchanged(setup.connection, setup.password);
          final uploaded = await _upload(setup.connection, encrypted,
              expectedRevision: remote?.revision);
          setup = (connection: uploaded.connection, password: setup.password);
          final verified = await _download(setup.connection);
          if (verified == null) throw const CloudSyncConflictException();
          _assertSupportedSyncSchema(verified.file);
          verifiedVault =
              await NetcattyCrypto.decrypt(verified.file, setup.password);
          if (isV2) {
            if (_syncSchema(verified.file) != 2) {
              throw const CloudSyncConflictException();
            }
            _validateConvergentPayload(verifiedVault);
            if (!convergentPayloadDominates(verifiedVault, outgoing)) {
              candidate = mergeConvergentPayloads(outgoing, verifiedVault);
              throw const CloudSyncConflictException();
            }
            // Also validate dot payloads, not only version-vector counters.
            mergeConvergentPayloads(outgoing, verifiedVault);
            if (!cloudSyncPayloadsEqual(
                VaultData.empty().copyWith(extras: {
                  'pluginSidecars': verifiedVault.extras['pluginSidecars']
                }),
                VaultData.empty().copyWith(extras: {
                  'pluginSidecars': outgoing.extras['pluginSidecars']
                }))) {
              throw const CloudSyncConflictException();
            }
          } else if (!cloudSyncPayloadsEqual(outgoing, verifiedVault) ||
              hasUnpublishedSyncDeletions(outgoing, verifiedVault)) {
            throw const CloudSyncConflictException();
          }
          verifiedFile = verified.file;
        }
        await _assertSetupUnchanged(setup.connection, setup.password);
        final finalVersion = _fileVersion(verifiedFile!);
        final applied = retainLocalDeviceData(verifiedVault, local);
        return CloudSyncResult(
          vault: applied,
          message: '同步完成',
          validateBeforeApply: () =>
              _assertSetupUnchanged(setup.connection, setup.password),
          acknowledge: () async {
            await _assertSetupUnchanged(setup.connection, setup.password);
            await _saveCheckpoint(
                verifiedVault, setup.connection, finalVersion, verifiedFile!);
            await repository.clearPendingSyncReplica();
          },
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

  Future<void> _assertSetupUnchanged(
      SyncConnection connection, String password) async {
    final current = await repository.loadSyncConnection();
    if (current == null ||
        jsonEncode(current.toJson()) != jsonEncode(connection.toJson()) ||
        current.secret != connection.secret ||
        current.sessionToken != connection.sessionToken ||
        await repository.readMasterPassword() != password) {
      throw StateError('同步配置已改变，本次同步已停止，请使用新配置重试');
    }
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
    final temporary =
        target.replace(path: '${target.path}.${const Uuid().v4()}.tmp');
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
      throw const CloudSyncConflictException();
    } on CloudSyncConflictException {
      rethrow;
    } on Object {
      // MOVE is optional in WebDAV deployments. Fall back to the same padded
      // in-place PUT used by desktop Netcatty.
    }
    await _deleteWebdavBestEffort(connection, temporary);

    var minimumLength = await _webdavLength(connection, target);
    if (minimumLength < expected.length) minimumLength = expected.length;
    final payload = _padWebdavBody(expected, minimumLength);
    await _putWebdav(connection, target, payload);
    final remote = await _readWebdavBytes(connection, target);
    if (remote != null && _matchesWebdavBody(remote, expected)) return;
    // Re-read and MERGE in the outer loop; never blindly overwrite a competing
    // device's newer value with the same stale payload three times.
    throw const CloudSyncConflictException();
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
      return decrypted;
    } on Object {
      throw StateError('本地同步基线无法读取，已停止写入以保护数据，请先检查同步密码');
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
