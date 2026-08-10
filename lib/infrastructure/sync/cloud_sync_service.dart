import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';

import '../../domain/models/host.dart';
import '../../domain/models/settings.dart';
import '../../domain/models/vault.dart';
import '../storage/vault_repository.dart';
import 'netcatty_crypto.dart';

class CloudSyncResult {
  const CloudSyncResult({required this.vault, required this.message});
  final VaultData vault;
  final String message;
}

class CloudSyncService {
  CloudSyncService(this.repository, {http.Client? client})
      : _client = client ?? http.Client();

  final VaultRepository repository;
  final http.Client _client;

  Future<CloudSyncResult> pullAndMerge(VaultData local) async {
    final setup = await _setup();
    final remote = await _download(setup.connection);
    if (remote == null) {
      await _uploadNew(setup.connection, local, setup.password);
      return CloudSyncResult(vault: local, message: '已创建加密云端保险库');
    }
    final downloaded = await NetcattyCrypto.decrypt(remote, setup.password);
    final merged = _merge(local, downloaded);
    await repository.saveVault(merged);
    if (jsonEncode(merged.toJson()) != jsonEncode(downloaded.toJson())) {
      await _upload(
        setup.connection,
        NetcattyCrypto.encrypt(
          vault: merged,
          password: setup.password,
          deviceId: const Uuid().v4(),
          deviceName: 'Netcatty Mobile',
          appVersion: '0.1.0',
          previousVersion: (remote.meta['version'] as num?)?.toInt() ?? 0,
        ),
      );
    }
    return CloudSyncResult(vault: merged, message: '同步完成');
  }

  Future<void> push(VaultData vault) async {
    final setup = await _setup();
    final current = await _download(setup.connection);
    await _upload(
      setup.connection,
      NetcattyCrypto.encrypt(
        vault: vault,
        password: setup.password,
        deviceId: const Uuid().v4(),
        deviceName: 'Netcatty Mobile',
        appVersion: '0.1.0',
        previousVersion: (current?.meta['version'] as num?)?.toInt() ?? 0,
      ),
    );
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

  Future<void> _uploadNew(
    SyncConnection connection,
    VaultData vault,
    String password,
  ) =>
      _upload(
        connection,
        NetcattyCrypto.encrypt(
          vault: vault,
          password: password,
          deviceId: const Uuid().v4(),
          deviceName: 'Netcatty Mobile',
          appVersion: '0.1.0',
        ),
      );

  Future<SyncedVaultFile?> _download(SyncConnection connection) async {
    if (connection.type == SyncProviderType.githubGist &&
        (connection.resourceId == null || connection.resourceId!.isEmpty)) {
      return null;
    }
    final response = connection.type == SyncProviderType.webdav
        ? await _client.get(
            _webdavUri(connection),
            headers: _webdavHeaders(connection),
          )
        : await _client.get(
            Uri.parse('https://api.github.com/gists/${connection.resourceId}'),
            headers: _githubHeaders(connection),
          );
    if (response.statusCode == 404) return null;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('云端读取失败 (${response.statusCode})');
    }
    if (connection.type == SyncProviderType.webdav) {
      return SyncedVaultFile.fromJson(_decodeJsonObject(response.body));
    }
    final gist = jsonDecode(response.body) as Map<String, dynamic>;
    final file = (gist['files'] as Map)['netcatty-vault.json'] as Map?;
    if (file == null) return null;
    if (file['truncated'] == true && file['raw_url'] != null) {
      final raw = await _client.get(
        Uri.parse(file['raw_url'].toString()),
        headers: _githubHeaders(connection),
      );
      if (raw.statusCode < 200 || raw.statusCode >= 300) {
        throw StateError('Gist 大文件读取失败 (${raw.statusCode})');
      }
      return SyncedVaultFile.fromJson(_decodeJsonObject(raw.body));
    }
    return SyncedVaultFile.fromJson(
      jsonDecode(file['content'] as String) as Map<String, dynamic>,
    );
  }

  Future<void> _upload(
    SyncConnection connection,
    Future<SyncedVaultFile> fileFuture,
  ) async {
    final file = await fileFuture;
    final body = jsonEncode(file.toJson());
    late http.Response response;
    if (connection.type == SyncProviderType.webdav) {
      response = await _client.put(
        _webdavUri(connection),
        headers: {
          ..._webdavHeaders(connection),
          'content-type': 'application/json',
        },
        body: body,
      );
    } else {
      final gistBody = jsonEncode({
        'description': 'Netcatty Encrypted Vault (DO NOT EDIT MANUALLY)',
        'public': false,
        'files': {
          'netcatty-vault.json': {'content': body},
        },
      });
      final id = connection.resourceId;
      response = id == null || id.isEmpty
          ? await _client.post(
              Uri.parse('https://api.github.com/gists'),
              headers: _githubHeaders(connection),
              body: gistBody,
            )
          : await _client.patch(
              Uri.parse('https://api.github.com/gists/$id'),
              headers: _githubHeaders(connection),
              body: gistBody,
            );
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('云端写入失败 (${response.statusCode})');
    }
    if (connection.type == SyncProviderType.githubGist &&
        (connection.resourceId == null || connection.resourceId!.isEmpty)) {
      final created = jsonDecode(response.body) as Map<String, dynamic>;
      final id = created['id']?.toString();
      if (id != null && id.isNotEmpty) {
        await repository.saveSyncConnection(
          SyncConnection(
            type: connection.type,
            endpoint: connection.endpoint,
            username: connection.username,
            secret: connection.secret,
            resourceId: id,
          ),
        );
      }
    }
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
      final response = await _client.get(
        Uri.parse('https://api.github.com/gists?per_page=100&page=$page'),
        headers: _githubHeaders(connection),
      );
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

  VaultData _merge(VaultData local, VaultData remote) {
    int hostTimestamp(HostProfile value) =>
        (value.data['updatedAt'] as num?)?.toInt() ?? value.lastConnectedAt;
    final hosts = <String, HostProfile>{
      for (final item in remote.hosts) item.id: item,
    };
    for (final item in local.hosts) {
      final other = hosts[item.id];
      hosts[item.id] = other == null
          ? item
          : hostTimestamp(item) > hostTimestamp(other)
              ? item
              : other;
    }
    final keys = <String, SshKeyProfile>{
      for (final item in remote.keys) item.id: item,
    };
    for (final item in local.keys) {
      keys[item.id] = item;
    }
    final snippets = <String, CommandSnippet>{
      for (final item in remote.snippets) item.id: item,
    };
    for (final item in local.snippets) {
      snippets[item.id] = item;
    }
    final proxyProfiles = <String, ProxyProfile>{
      for (final item in remote.proxyProfiles) item.id: item,
    };
    for (final item in local.proxyProfiles) {
      final other = proxyProfiles[item.id];
      final localUpdated = (item.data['updatedAt'] as num?)?.toInt() ??
          (item.data['createdAt'] as num?)?.toInt() ??
          0;
      final remoteUpdated = (other?.data['updatedAt'] as num?)?.toInt() ??
          (other?.data['createdAt'] as num?)?.toInt() ??
          0;
      if (other == null || localUpdated >= remoteUpdated) {
        proxyProfiles[item.id] = item;
      }
    }
    return remote.copyWith(
      hosts: hosts.values.toList(),
      keys: keys.values.toList(),
      snippets: snippets.values.toList(),
      customGroups: {...remote.customGroups, ...local.customGroups}.toList(),
      proxyProfiles: proxyProfiles.values.toList(),
    );
  }
}
