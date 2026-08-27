import '../../domain/models/host.dart';
import '../../domain/models/vault.dart';
import '../../domain/models/vault_sync_state.dart';

/// Merges two materialized vaults using per-entity clocks and encrypted
/// tombstones. Equal revisions deliberately prefer [remote], which makes
/// legacy snapshots converge deterministically on the last downloaded value.
VaultData mergeVaults({
  required VaultData local,
  required VaultData remote,
  int remoteFallbackTimestamp = 0,
}) {
  final localState = VaultSyncState.fromVault(local);
  final remoteState = VaultSyncState.fromVault(remote);
  final revisions = <String, Map<String, int>>{};
  final tombstones = <String, Map<String, int>>{};

  for (final kind in VaultSyncState.entityKinds) {
    revisions[kind] = _maxClocks(
      localState.revisions[kind],
      remoteState.revisions[kind],
    );
    tombstones[kind] = _maxClocks(
      localState.tombstones[kind],
      remoteState.tombstones[kind],
    );
  }

  final hosts = _mergeEntities<HostProfile>(
    kind: VaultSyncState.hosts,
    local: local.hosts,
    remote: remote.hosts,
    idOf: (item) => item.id,
    dataOf: (item) => item.data,
    localState: localState,
    remoteState: remoteState,
    remoteFallbackTimestamp: remoteFallbackTimestamp,
    mergedRevisions: revisions,
    mergedTombstones: tombstones,
  );
  final keys = _mergeEntities<SshKeyProfile>(
    kind: VaultSyncState.keys,
    local: local.keys,
    remote: remote.keys,
    idOf: (item) => item.id,
    dataOf: (item) => item.data,
    localState: localState,
    remoteState: remoteState,
    remoteFallbackTimestamp: remoteFallbackTimestamp,
    mergedRevisions: revisions,
    mergedTombstones: tombstones,
  );
  final snippets = _mergeEntities<CommandSnippet>(
    kind: VaultSyncState.snippets,
    local: local.snippets,
    remote: remote.snippets,
    idOf: (item) => item.id,
    dataOf: (item) => item.data,
    localState: localState,
    remoteState: remoteState,
    remoteFallbackTimestamp: remoteFallbackTimestamp,
    mergedRevisions: revisions,
    mergedTombstones: tombstones,
  );
  final proxies = _mergeEntities<ProxyProfile>(
    kind: VaultSyncState.proxies,
    local: local.proxyProfiles,
    remote: remote.proxyProfiles,
    idOf: (item) => item.id,
    dataOf: (item) => item.data,
    localState: localState,
    remoteState: remoteState,
    remoteFallbackTimestamp: remoteFallbackTimestamp,
    mergedRevisions: revisions,
    mergedTombstones: tombstones,
  );
  final groups = _mergeGroups(
    local.customGroups,
    remote.customGroups,
    localState,
    remoteState,
    remoteFallbackTimestamp,
    revisions,
    tombstones,
  );

  final state = VaultSyncState(
    revisions: revisions,
    tombstones: tombstones,
    lastMutationAt: localState.lastMutationAt > remoteState.lastMutationAt
        ? localState.lastMutationAt
        : remoteState.lastMutationAt,
  );
  return remote.copyWith(
    hosts: hosts,
    keys: keys,
    snippets: snippets,
    customGroups: groups,
    proxyProfiles: proxies,
    extras: {
      ..._mergeOpaqueExtras(local.extras, remote.extras),
      VaultSyncState.storageKey: state.toJson(),
    },
  );
}

/// Desktop Netcatty owns every opaque payload field except the mobile sync
/// sidecar and the host-key trust records maintained by this client. A mobile
/// vault can contain an older cached copy of `settings` (including AI
/// providers), notes, plugin sidecars, or other desktop-only data. Letting that
/// cache win would roll the desktop back whenever an unrelated mobile entity
/// changed, so the freshly downloaded snapshot is authoritative here.
Map<String, dynamic> _mergeOpaqueExtras(
  Map<String, dynamic> local,
  Map<String, dynamic> remote,
) {
  final result = Map<String, dynamic>.from(remote);

  // Preserve current and future mobile-private sidecars without allowing them
  // to overwrite a newer copy already present in the downloaded vault.
  for (final entry in local.entries) {
    if (entry.key.startsWith('_netcattyMobile')) {
      result.putIfAbsent(entry.key, () => entry.value);
    }
  }

  final knownHosts = _mergeKnownHosts(
    remote['knownHosts'],
    local['knownHosts'],
  );
  if (knownHosts == null) {
    result.remove('knownHosts');
  } else {
    result['knownHosts'] = knownHosts;
  }
  return result;
}

List<dynamic>? _mergeKnownHosts(Object? remote, Object? local) {
  if (remote is! List && local is! List) return null;
  final merged = <String, dynamic>{};

  void addAll(Object? value, String source) {
    if (value is! List) return;
    for (var index = 0; index < value.length; index++) {
      final item = value[index];
      merged[_knownHostKey(item, source, index)] = item;
    }
  }

  addAll(remote, 'remote');
  // A fingerprint accepted on this phone is device-local state and must not be
  // discarded merely because desktop cloud snapshots omit knownHosts.
  addAll(local, 'local');
  return merged.values.toList(growable: false);
}

String _knownHostKey(Object? value, String source, int index) {
  if (value is Map) {
    final hostname = value['hostname']?.toString().trim() ?? '';
    if (hostname.isNotEmpty) {
      final port = (value['port'] as num?)?.toInt() ?? 22;
      return '$hostname:$port';
    }
    final id = value['id']?.toString().trim() ?? '';
    if (id.isNotEmpty) return 'id:$id';
  }
  return '$source:$index';
}

List<T> _mergeEntities<T>({
  required String kind,
  required List<T> local,
  required List<T> remote,
  required String Function(T) idOf,
  required Map<String, dynamic> Function(T) dataOf,
  required VaultSyncState localState,
  required VaultSyncState remoteState,
  required int remoteFallbackTimestamp,
  required Map<String, Map<String, int>> mergedRevisions,
  required Map<String, Map<String, int>> mergedTombstones,
}) {
  final localById = {for (final item in local) idOf(item): item};
  final remoteById = {for (final item in remote) idOf(item): item};
  final ids = {...localById.keys, ...remoteById.keys};
  final result = <T>[];
  for (final id in ids) {
    if (id.isEmpty) continue;
    final localItem = localById[id];
    final remoteItem = remoteById[id];
    final localRevision = localState.revision(
      kind,
      id,
      fallback: _entityTimestamp(localItem == null ? null : dataOf(localItem)),
    );
    final remoteRevision = remoteState.revision(
      kind,
      id,
      fallback: _entityTimestamp(
        remoteItem == null ? null : dataOf(remoteItem),
        fallback: remoteFallbackTimestamp,
      ),
    );
    final deletion = mergedTombstones[kind]?[id] ?? 0;
    final winningRevision =
        localRevision > remoteRevision ? localRevision : remoteRevision;
    if (deletion >= winningRevision && deletion > 0) {
      mergedRevisions[kind]?.remove(id);
      continue;
    }
    final winner = localRevision > remoteRevision ? localItem : remoteItem;
    final fallbackWinner = winner ?? localItem ?? remoteItem;
    if (fallbackWinner != null) {
      result.add(fallbackWinner);
      mergedRevisions[kind]?[id] = winningRevision;
      mergedTombstones[kind]?.remove(id);
    }
  }
  return result;
}

List<String> _mergeGroups(
  List<String> local,
  List<String> remote,
  VaultSyncState localState,
  VaultSyncState remoteState,
  int remoteFallbackTimestamp,
  Map<String, Map<String, int>> revisions,
  Map<String, Map<String, int>> tombstones,
) {
  final localSet = local.toSet();
  final remoteSet = remote.toSet();
  final result = <String>[];
  for (final group in {...localSet, ...remoteSet}) {
    final localRevision = localState.revision(
      VaultSyncState.groups,
      group,
      fallback: localSet.contains(group) ? localState.lastMutationAt : 0,
    );
    final remoteRevision = remoteState.revision(
      VaultSyncState.groups,
      group,
      fallback: remoteSet.contains(group) ? remoteFallbackTimestamp : 0,
    );
    final winningRevision =
        localRevision > remoteRevision ? localRevision : remoteRevision;
    final deletion = tombstones[VaultSyncState.groups]?[group] ?? 0;
    if (deletion >= winningRevision && deletion > 0) {
      revisions[VaultSyncState.groups]?.remove(group);
      continue;
    }
    if (localSet.contains(group) || remoteSet.contains(group)) {
      result.add(group);
      revisions[VaultSyncState.groups]?[group] = winningRevision;
      tombstones[VaultSyncState.groups]?.remove(group);
    }
  }
  result.sort();
  return result;
}

int _entityTimestamp(Map<String, dynamic>? data, {int fallback = 0}) {
  if (data == null) return 0;
  for (final key in const [
    'updatedAt',
    'lastConnectedAt',
    'createdAt',
    'created',
  ]) {
    final value = (data[key] as num?)?.toInt() ?? 0;
    if (value > 0) return value;
  }
  return fallback;
}

Map<String, int> _maxClocks(Map<String, int>? left, Map<String, int>? right) {
  final result = <String, int>{...?left};
  for (final entry in (right ?? const <String, int>{}).entries) {
    final existing = result[entry.key] ?? 0;
    if (entry.value > existing) result[entry.key] = entry.value;
  }
  return result;
}
