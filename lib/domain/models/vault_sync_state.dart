import 'dart:convert';

import 'host.dart';
import 'vault.dart';

/// Mobile-side convergence metadata stored inside the encrypted vault payload.
///
/// Desktop Netcatty preserves unknown top-level fields, so this sidecar can
/// safely travel through older desktop versions without exposing entity IDs or
/// deletion history in the unencrypted envelope.
class VaultSyncState {
  VaultSyncState({
    Map<String, Map<String, int>>? revisions,
    Map<String, Map<String, int>>? tombstones,
    this.lastMutationAt = 0,
  })  : revisions = revisions ?? <String, Map<String, int>>{},
        tombstones = tombstones ?? <String, Map<String, int>>{};

  static const storageKey = '_netcattyMobileSync';
  static const schemaVersion = 1;

  static const hosts = 'hosts';
  static const keys = 'keys';
  static const snippets = 'snippets';
  static const groups = 'customGroups';
  static const proxies = 'proxyProfiles';
  static const entityKinds = <String>[
    hosts,
    keys,
    snippets,
    groups,
    proxies,
  ];

  final Map<String, Map<String, int>> revisions;
  final Map<String, Map<String, int>> tombstones;
  final int lastMutationAt;

  factory VaultSyncState.fromVault(VaultData vault) {
    final raw = vault.extras[storageKey];
    if (raw is! Map) return VaultSyncState();
    final json = Map<String, dynamic>.from(raw);
    return VaultSyncState(
      revisions: _readClockMap(json['revisions']),
      tombstones: _readClockMap(json['tombstones']),
      lastMutationAt: (json['lastMutationAt'] as num?)?.toInt() ?? 0,
    );
  }

  int revision(String kind, String id, {int fallback = 0}) =>
      revisions[kind]?[id] ?? fallback;

  int deletedAt(String kind, String id) => tombstones[kind]?[id] ?? 0;

  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'lastMutationAt': lastMutationAt,
        'revisions': revisions,
        'tombstones': tombstones,
      };

  VaultSyncState copyWith({
    Map<String, Map<String, int>>? revisions,
    Map<String, Map<String, int>>? tombstones,
    int? lastMutationAt,
  }) =>
      VaultSyncState(
        revisions: revisions ?? this.revisions,
        tombstones: tombstones ?? this.tombstones,
        lastMutationAt: lastMutationAt ?? this.lastMutationAt,
      );

  static Map<String, Map<String, int>> _readClockMap(Object? value) {
    final result = <String, Map<String, int>>{};
    if (value is! Map) return result;
    for (final entry in value.entries) {
      if (entry.value is! Map) continue;
      result[entry.key.toString()] = {
        for (final clock in (entry.value as Map).entries)
          if (clock.value is num)
            clock.key.toString(): (clock.value as num).toInt(),
      };
    }
    return result;
  }
}

/// Stamps changed entities and records deletions before a local vault save.
VaultData stampLocalVaultChanges(
  VaultData previous,
  VaultData next, {
  int? timestamp,
}) {
  final now = timestamp ?? DateTime.now().millisecondsSinceEpoch;
  final oldState = VaultSyncState.fromVault(previous);
  final revisions = _copyClocks(oldState.revisions);
  final tombstones = _copyClocks(oldState.tombstones);

  final stampedHosts = _stampEntities<HostProfile>(
    kind: VaultSyncState.hosts,
    previous: previous.hosts,
    next: next.hosts,
    idOf: (item) => item.id,
    jsonOf: (item) => item.toJson(),
    stamp: (item) => HostProfile({...item.data, 'updatedAt': now}),
    now: now,
    revisions: revisions,
    tombstones: tombstones,
  );
  final stampedKeys = _stampEntities<SshKeyProfile>(
    kind: VaultSyncState.keys,
    previous: previous.keys,
    next: next.keys,
    idOf: (item) => item.id,
    jsonOf: (item) => item.toJson(),
    stamp: (item) => SshKeyProfile({...item.data, 'updatedAt': now}),
    now: now,
    revisions: revisions,
    tombstones: tombstones,
  );
  final stampedSnippets = _stampEntities<CommandSnippet>(
    kind: VaultSyncState.snippets,
    previous: previous.snippets,
    next: next.snippets,
    idOf: (item) => item.id,
    jsonOf: (item) => item.toJson(),
    stamp: (item) => CommandSnippet({...item.data, 'updatedAt': now}),
    now: now,
    revisions: revisions,
    tombstones: tombstones,
  );
  final stampedProxies = _stampEntities<ProxyProfile>(
    kind: VaultSyncState.proxies,
    previous: previous.proxyProfiles,
    next: next.proxyProfiles,
    idOf: (item) => item.id,
    jsonOf: (item) => item.toJson(),
    stamp: (item) => ProxyProfile({...item.data, 'updatedAt': now}),
    now: now,
    revisions: revisions,
    tombstones: tombstones,
  );
  final stampedGroups = _stampGroups(
    previous.customGroups,
    next.customGroups,
    now,
    revisions,
    tombstones,
  );

  final state = VaultSyncState(
    revisions: revisions,
    tombstones: tombstones,
    lastMutationAt: now,
  );
  return next.copyWith(
    hosts: stampedHosts,
    keys: stampedKeys,
    snippets: stampedSnippets,
    customGroups: stampedGroups,
    proxyProfiles: stampedProxies,
    extras: {...next.extras, VaultSyncState.storageKey: state.toJson()},
  );
}

List<T> _stampEntities<T>({
  required String kind,
  required List<T> previous,
  required List<T> next,
  required String Function(T) idOf,
  required Map<String, dynamic> Function(T) jsonOf,
  required T Function(T) stamp,
  required int now,
  required Map<String, Map<String, int>> revisions,
  required Map<String, Map<String, int>> tombstones,
}) {
  final oldById = {for (final item in previous) idOf(item): item};
  final newIds = next.map(idOf).where((id) => id.isNotEmpty).toSet();
  final clocks = revisions.putIfAbsent(kind, () => <String, int>{});
  final deleted = tombstones.putIfAbsent(kind, () => <String, int>{});
  final result = <T>[];
  for (final item in next) {
    final id = idOf(item);
    final old = oldById[id];
    if (id.isNotEmpty &&
        (old == null || !_sameJson(jsonOf(old), jsonOf(item)))) {
      final stamped = stamp(item);
      result.add(stamped);
      clocks[id] = now;
      deleted.remove(id);
    } else {
      result.add(item);
    }
  }
  for (final item in previous) {
    final id = idOf(item);
    if (id.isNotEmpty && !newIds.contains(id)) {
      deleted[id] = now;
      clocks.remove(id);
    }
  }
  return result;
}

List<String> _stampGroups(
  List<String> previous,
  List<String> next,
  int now,
  Map<String, Map<String, int>> revisions,
  Map<String, Map<String, int>> tombstones,
) {
  final old = previous.toSet();
  final current = next.toSet();
  final clocks = revisions.putIfAbsent(
    VaultSyncState.groups,
    () => <String, int>{},
  );
  final deleted = tombstones.putIfAbsent(
    VaultSyncState.groups,
    () => <String, int>{},
  );
  for (final group in current.difference(old)) {
    clocks[group] = now;
    deleted.remove(group);
  }
  for (final group in old.difference(current)) {
    deleted[group] = now;
    clocks.remove(group);
  }
  return current.toList(growable: false);
}

Map<String, Map<String, int>> _copyClocks(
  Map<String, Map<String, int>> source,
) =>
    {
      for (final entry in source.entries)
        entry.key: Map<String, int>.from(entry.value),
    };

bool _sameJson(Map<String, dynamic> left, Map<String, dynamic> right) =>
    jsonEncode(left) == jsonEncode(right);
