import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../../domain/models/vault.dart';

/// Cloud collections used by desktop Netcatty's legacy materialized sync.
const _entityCollections = <String>[
  'hosts',
  'keys',
  'identities',
  'proxyProfiles',
  'snippets',
  'notes',
  'portForwardingRules',
  'groupConfigs',
];

const _stringCollections = <String>[
  'customGroups',
  'snippetPackages',
  'noteGroups',
];

const _optionalCollections = <String>{
  'identities',
  'proxyProfiles',
  'snippetPackages',
  'notes',
  'noteGroups',
  'portForwardingRules',
  'groupConfigs',
};

const _allCollections = <String>[
  ..._entityCollections,
  ..._stringCollections,
];

const _missing = Object();

/// Desktop-compatible Git-style three-way merge.
///
/// [base] is the payload from the last successful synchronization. Its
/// presence is what lets a missing remote entity mean "deleted on desktop"
/// instead of "unknown addition on mobile". Without a base, encrypted
/// desktop deletion records are used to suppress stale entities.
VaultData mergeVaults({
  VaultData? base,
  required VaultData local,
  required VaultData remote,
  int? timestamp,
}) {
  final baseJson = base == null
      ? _emptyPayload()
      : _syncJson(base, includeReliabilityMeta: true);
  final localJson = _syncJson(local, includeReliabilityMeta: true);
  final remoteJson = _syncJson(remote, includeReliabilityMeta: true);
  final output = <String, dynamic>{};

  for (final collection in _entityCollections) {
    final baseValues = _entityArray(baseJson, collection, const []);
    output[collection] = _mergeEntities(
      baseValues,
      _entityArray(localJson, collection, baseValues),
      _entityArray(remoteJson, collection, baseValues),
      localTombstones: _deletedIds(localJson, collection),
      remoteTombstones: _deletedIds(remoteJson, collection),
      idKey: collection == 'groupConfigs' ? 'path' : 'id',
    );
  }

  for (final collection in _stringCollections) {
    final baseValues = _stringArray(baseJson, collection, const []);
    output[collection] = _mergeStrings(
      baseValues,
      _stringArray(localJson, collection, baseValues),
      _stringArray(remoteJson, collection, baseValues),
      localTombstones: _deletedIds(localJson, collection),
      remoteTombstones: _deletedIds(remoteJson, collection),
    );
  }

  final settings = _mergeSettings(
    _mapOrNull(baseJson['settings']),
    _mapOrNull(localJson['settings']),
    _mapOrNull(remoteJson['settings']),
    preferRemoteOnConflict: base == null,
  );
  if (settings != null && settings.isNotEmpty) {
    _deduplicateSftpBookmarks(settings);
    output['settings'] = settings;
  }

  final sidecars = _mergePluginSidecars(baseJson, localJson, remoteJson);
  if (sidecars != null) output['pluginSidecars'] = sidecars;
  output['syncedAt'] = timestamp ?? DateTime.now().millisecondsSinceEpoch;

  final carriedDeletions = _mergeDeletionRecords(
    output,
    [
      ..._deletionRecords(localJson),
      ..._deletionRecords(remoteJson),
    ],
  );
  if (carriedDeletions.isNotEmpty) {
    output['syncMeta'] = _minimalReliabilityMeta(
      output,
      carriedDeletions,
      timestamp: timestamp,
    );
  }
  return VaultData.fromJson(output);
}

/// Adds the same durable deletion records and reliability envelope as the
/// desktop client immediately before an upload.
VaultData withSyncReliabilityMeta(
  VaultData payload,
  VaultData? base, {
  String? deviceId,
  int? timestamp,
}) {
  final now = timestamp ?? DateTime.now().millisecondsSinceEpoch;
  final payloadJson = _syncJson(payload, includeReliabilityMeta: true);
  final baseJson =
      base == null ? null : _syncJson(base, includeReliabilityMeta: true);
  final deletions = _mergeDeletionRecords(
    payloadJson,
    [
      ..._deletionRecords(payloadJson),
      ..._collectDeletions(baseJson, payloadJson, now, deviceId),
    ],
  );
  final summary = _summarizeChanges(baseJson, payloadJson);
  final baseSyncedAt = (baseJson?['syncedAt'] as num?)?.toInt() ?? 0;
  payloadJson['syncMeta'] = <String, dynamic>{
    'schemaVersion': 1,
    'generatedAt': now,
    if (deviceId != null && deviceId.isNotEmpty) 'deviceId': deviceId,
    if (baseSyncedAt > 0) 'baseSyncedAt': baseSyncedAt,
    'localChanged': summary['hasLocalChanges'] == true,
    'deletions': deletions,
    'changeSummary': summary,
  };
  return VaultData.fromJson(payloadJson);
}

/// Removes mobile-only state and connection telemetry from cloud material.
VaultData sanitizeVaultForSync(VaultData vault) =>
    VaultData.fromJson(_syncJson(vault, includeReliabilityMeta: true));

/// Re-attaches values that are intentionally device-local after applying a
/// cloud payload. They never participate in comparisons or uploads.
VaultData retainLocalDeviceData(VaultData incoming, VaultData local) {
  final json = incoming.toJson(legacySyncSnapshot: true);
  final localJson = local.toJson(legacySyncSnapshot: true);
  final localHosts = <String, Map<String, dynamic>>{
    for (final value in (localJson['hosts'] as List? ?? const []))
      if (value is Map && value['id'] is String)
        value['id'] as String: Map<String, dynamic>.from(value),
  };
  final incomingHosts =
      (json['hosts'] as List? ?? const []).whereType<Map>().map((value) {
    final host = Map<String, dynamic>.from(value);
    final localHost = localHosts[host['id']];
    if (!host.containsKey('lastConnectedAt') &&
        localHost?['lastConnectedAt'] != null) {
      host['lastConnectedAt'] = localHost!['lastConnectedAt'];
    }
    return host;
  }).toList(growable: false);
  json['hosts'] = incomingHosts;
  if (localJson.containsKey('knownHosts')) {
    json['knownHosts'] = _deepCopy(localJson['knownHosts']);
  }
  return VaultData.fromJson(json);
}

bool cloudSyncPayloadsEqual(VaultData left, VaultData right) =>
    _fingerprint(_cloudProjection(left)) ==
    _fingerprint(_cloudProjection(right));

Future<String> cloudSyncPayloadFingerprint(VaultData vault) async {
  final canonical = _canonicalize(_cloudProjection(vault));
  final digest = await Sha256().hash(utf8.encode(jsonEncode(canonical)));
  return base64UrlEncode(digest.bytes);
}

bool hasUnpublishedSyncDeletions(VaultData outgoing, VaultData remote) {
  String key(Map<String, dynamic> record) =>
      '${record['entityType']}:${record['id']}';
  final remoteKeys = _deletionRecords(
    _syncJson(remote, includeReliabilityMeta: true),
  ).map(key).toSet();
  return _deletionRecords(
    _syncJson(outgoing, includeReliabilityMeta: true),
  ).any((record) => !remoteKeys.contains(key(record)));
}

Map<String, dynamic> _emptyPayload() => <String, dynamic>{
      for (final collection in _allCollections) collection: <dynamic>[],
      'syncedAt': 0,
    };

Map<String, dynamic> _syncJson(
  VaultData vault, {
  required bool includeReliabilityMeta,
}) {
  final source = vault.toJson(legacySyncSnapshot: true);
  final result = <String, dynamic>{};
  for (final collection in _allCollections) {
    if (source.containsKey(collection)) {
      result[collection] = _deepCopy(source[collection]);
    }
  }
  if (result['hosts'] is List) {
    result['hosts'] = (result['hosts'] as List)
        .whereType<Map>()
        .map((value) =>
            Map<String, dynamic>.from(value)..remove('lastConnectedAt'))
        .toList(growable: false);
  }
  if (source.containsKey('settings')) {
    result['settings'] = _deepCopy(source['settings']);
  }
  if (source.containsKey('pluginSidecars')) {
    result['pluginSidecars'] = _deepCopy(source['pluginSidecars']);
  }
  result['syncedAt'] = (source['syncedAt'] as num?)?.toInt() ?? 0;
  if (includeReliabilityMeta && source['syncMeta'] is Map) {
    result['syncMeta'] = _deepCopy(source['syncMeta']);
  }
  return result;
}

Map<String, dynamic> _cloudProjection(VaultData vault) {
  final json = _syncJson(vault, includeReliabilityMeta: false);
  return <String, dynamic>{
    for (final collection in _allCollections)
      collection: json[collection] ?? const <dynamic>[],
    'settings': json['settings'] ?? const <String, dynamic>{},
    'pluginSidecars': json['pluginSidecars'] ??
        const <String, dynamic>{'version': 1, 'entries': <dynamic>[]},
  };
}

List<Map<String, dynamic>> _entityArray(
  Map<String, dynamic> payload,
  String key,
  List<Map<String, dynamic>> fallback,
) {
  if (_optionalCollections.contains(key) && !payload.containsKey(key)) {
    return fallback.map(_copyMap).toList(growable: false);
  }
  final value = payload[key];
  if (value is! List) return <Map<String, dynamic>>[];
  return value.whereType<Map>().map(_copyMap).toList(growable: false);
}

List<String> _stringArray(
  Map<String, dynamic> payload,
  String key,
  List<String> fallback,
) {
  if (_optionalCollections.contains(key) && !payload.containsKey(key)) {
    return List<String>.from(fallback);
  }
  final value = payload[key];
  if (value is! List) return <String>[];
  return value.whereType<String>().toList(growable: false);
}

List<Map<String, dynamic>> _mergeEntities(
  List<Map<String, dynamic>> base,
  List<Map<String, dynamic>> local,
  List<Map<String, dynamic>> remote, {
  required Set<String> localTombstones,
  required Set<String> remoteTombstones,
  required String idKey,
}) {
  Map<String, Map<String, dynamic>> index(
    List<Map<String, dynamic>> values,
  ) =>
      <String, Map<String, dynamic>>{
        for (final value in values)
          if (value[idKey] is String && (value[idKey] as String).isNotEmpty)
            value[idKey] as String: value,
      };

  final baseMap = index(base);
  final localMap = index(local);
  final remoteMap = index(remote);
  final ids = <String>{
    ...baseMap.keys,
    ...localMap.keys,
    ...remoteMap.keys,
  };
  final merged = <Map<String, dynamic>>[];
  for (final id in ids) {
    final baseItem = baseMap[id];
    final localItem = localMap[id];
    final remoteItem = remoteMap[id];
    if (baseItem == null) {
      if (localItem != null && remoteItem == null) {
        if (!remoteTombstones.contains(id)) merged.add(_copyMap(localItem));
      } else if (localItem == null && remoteItem != null) {
        if (!localTombstones.contains(id)) merged.add(_copyMap(remoteItem));
      } else if (localItem != null && remoteItem != null) {
        merged.add(_copyMap(localItem));
      }
      continue;
    }
    if (localItem != null && remoteItem != null) {
      final localChanged = _fingerprint(localItem) != _fingerprint(baseItem);
      final remoteChanged = _fingerprint(remoteItem) != _fingerprint(baseItem);
      if (!localChanged && !remoteChanged) {
        merged.add(_copyMap(baseItem));
      } else if (!localChanged && remoteChanged) {
        merged.add(_copyMap(remoteItem));
      } else {
        merged.add(_copyMap(localItem));
      }
    } else if (localItem == null && remoteItem != null) {
      if (_fingerprint(remoteItem) != _fingerprint(baseItem)) {
        merged.add(_copyMap(remoteItem));
      }
    } else if (localItem != null && remoteItem == null) {
      if (_fingerprint(localItem) != _fingerprint(baseItem)) {
        merged.add(_copyMap(localItem));
      }
    }
  }
  return merged;
}

List<String> _mergeStrings(
  List<String> base,
  List<String> local,
  List<String> remote, {
  required Set<String> localTombstones,
  required Set<String> remoteTombstones,
}) {
  final baseSet = base.toSet();
  final localSet = local.toSet();
  final remoteSet = remote.toSet();
  final result = <String>[];
  for (final value in <String>{...base, ...local, ...remote}) {
    final inBase = baseSet.contains(value);
    final inLocal = localSet.contains(value);
    final inRemote = remoteSet.contains(value);
    if (!inBase) {
      if (inLocal && !inRemote && remoteTombstones.contains(value)) continue;
      if (!inLocal && inRemote && localTombstones.contains(value)) continue;
      if (inLocal || inRemote) result.add(value);
    } else if (inLocal && inRemote) {
      result.add(value);
    }
  }
  return result;
}

Map<String, dynamic>? _mergeSettings(
  Map<String, dynamic>? base,
  Map<String, dynamic>? local,
  Map<String, dynamic>? remote, {
  required bool preferRemoteOnConflict,
}) {
  if (local == null && remote == null) return null;
  if (local == null) return _copyMap(remote!);
  if (remote == null) return _copyMap(local);
  final merged = _mergeMaps(
    base ?? const <String, dynamic>{},
    local,
    remote,
    preferRemoteOnConflict: preferRemoteOnConflict,
  );
  return merged.isEmpty ? null : merged;
}

Map<String, dynamic> _mergeMaps(
  Map<String, dynamic> base,
  Map<String, dynamic> local,
  Map<String, dynamic> remote, {
  required bool preferRemoteOnConflict,
}) {
  final output = <String, dynamic>{};
  for (final key in <String>{...base.keys, ...local.keys, ...remote.keys}) {
    final baseValue = base.containsKey(key) ? base[key] : _missing;
    final localValue = local.containsKey(key) ? local[key] : _missing;
    final remoteValue = remote.containsKey(key) ? remote[key] : _missing;
    final localChanged = !_jsonEqual(localValue, baseValue);
    final remoteChanged = !_jsonEqual(remoteValue, baseValue);
    Object? chosen = _missing;
    if (!localChanged && !remoteChanged) {
      chosen = baseValue;
    } else if (localChanged && !remoteChanged) {
      chosen = localValue;
    } else if (!localChanged && remoteChanged) {
      chosen = remoteValue;
    } else if (localValue is Map && remoteValue is Map) {
      if (preferRemoteOnConflict && remoteValue.isEmpty) {
        chosen = <String, dynamic>{};
      } else {
        chosen = _mergeMaps(
          _mapOrNull(baseValue) ?? const <String, dynamic>{},
          Map<String, dynamic>.from(localValue),
          Map<String, dynamic>.from(remoteValue),
          preferRemoteOnConflict: preferRemoteOnConflict,
        );
      }
    } else if (localValue is List &&
        remoteValue is List &&
        (_isIdArray(localValue) ||
            _isIdArray(remoteValue) ||
            (baseValue is List && _isIdArray(baseValue)))) {
      final baseList = baseValue is List
          ? baseValue.whereType<Map>().map(_copyMap).toList()
          : <Map<String, dynamic>>[];
      final preferred = preferRemoteOnConflict ? remoteValue : localValue;
      final other = preferRemoteOnConflict ? localValue : remoteValue;
      chosen = _mergeEntities(
        baseList,
        preferred.whereType<Map>().map(_copyMap).toList(),
        other.whereType<Map>().map(_copyMap).toList(),
        localTombstones: const <String>{},
        remoteTombstones: const <String>{},
        idKey: 'id',
      );
    } else {
      chosen = preferRemoteOnConflict ? remoteValue : localValue;
    }
    if (!identical(chosen, _missing)) output[key] = _deepCopy(chosen);
  }
  return output;
}

Map<String, dynamic>? _mergePluginSidecars(
  Map<String, dynamic> base,
  Map<String, dynamic> local,
  Map<String, dynamic> remote,
) {
  final baseHas = base.containsKey('pluginSidecars');
  final localHas = local.containsKey('pluginSidecars');
  final remoteHas = remote.containsKey('pluginSidecars');
  if (!baseHas && !localHas && !remoteHas) return null;
  final baseEntries = _sidecarEntries(base['pluginSidecars']);
  final localEntries =
      localHas ? _sidecarEntries(local['pluginSidecars']) : baseEntries;
  final remoteEntries =
      remoteHas ? _sidecarEntries(remote['pluginSidecars']) : baseEntries;
  final merged = _mergeSidecarEntries(baseEntries, localEntries, remoteEntries);
  return <String, dynamic>{'version': 1, 'entries': merged};
}

List<Map<String, dynamic>> _sidecarEntries(Object? value) {
  if (value is! Map || value['entries'] is! List) {
    return <Map<String, dynamic>>[];
  }
  return (value['entries'] as List)
      .whereType<Map>()
      .map(_copyMap)
      .where((entry) =>
          entry['pluginId'] is String &&
          const {'settings', 'account_baseline', 'crdt_baseline'}
              .contains(entry['kind']))
      .toList(growable: false);
}

List<Map<String, dynamic>> _mergeSidecarEntries(
  List<Map<String, dynamic>> base,
  List<Map<String, dynamic>> local,
  List<Map<String, dynamic>> remote,
) {
  String key(Map<String, dynamic> value) =>
      '${value['pluginId']}\u0000${value['kind']}\u0000${value['key']}';
  final baseMap = {for (final value in base) key(value): value};
  final localMap = {for (final value in local) key(value): value};
  final remoteMap = {for (final value in remote) key(value): value};
  final output = <Map<String, dynamic>>[];
  for (final id in <String>{
    ...baseMap.keys,
    ...localMap.keys,
    ...remoteMap.keys,
  }) {
    final baseItem = baseMap[id];
    final localItem = localMap[id];
    final remoteItem = remoteMap[id];
    final kind = localItem?['kind'] ?? remoteItem?['kind'] ?? baseItem?['kind'];
    if (kind != 'settings') {
      if (localItem != null && remoteItem != null) {
        final localTime = (localItem['updatedAt'] as num?)?.toInt() ?? 0;
        final remoteTime = (remoteItem['updatedAt'] as num?)?.toInt() ?? 0;
        output.add(_copyMap(localTime >= remoteTime ? localItem : remoteItem));
      } else if (localItem != null) {
        output.add(_copyMap(localItem));
      } else if (remoteItem != null) {
        output.add(_copyMap(remoteItem));
      }
      continue;
    }
    if (baseItem != null && localItem == null && remoteItem != null) {
      if (((remoteItem['updatedAt'] as num?)?.toInt() ?? 0) >
          ((baseItem['updatedAt'] as num?)?.toInt() ?? 0)) {
        output.add(_copyMap(remoteItem));
      }
    } else if (baseItem != null && localItem != null && remoteItem == null) {
      if (((localItem['updatedAt'] as num?)?.toInt() ?? 0) >
          ((baseItem['updatedAt'] as num?)?.toInt() ?? 0)) {
        output.add(_copyMap(localItem));
      }
    } else if (baseItem != null && localItem == null && remoteItem == null) {
      continue;
    } else if (localItem != null && remoteItem != null) {
      final localTime = (localItem['updatedAt'] as num?)?.toInt() ?? 0;
      final remoteTime = (remoteItem['updatedAt'] as num?)?.toInt() ?? 0;
      if (localTime != remoteTime) {
        output.add(_copyMap(localTime > remoteTime ? localItem : remoteItem));
      } else {
        output.add(_copyMap(
          jsonEncode(localItem['value'])
                      .compareTo(jsonEncode(remoteItem['value'])) >=
                  0
              ? localItem
              : remoteItem,
        ));
      }
    } else if (localItem != null) {
      output.add(_copyMap(localItem));
    } else if (remoteItem != null) {
      output.add(_copyMap(remoteItem));
    }
  }
  output.sort((left, right) => key(left).compareTo(key(right)));
  return output;
}

void _deduplicateSftpBookmarks(Map<String, dynamic> settings) {
  final value = settings['sftpGlobalBookmarks'];
  if (value is! List) return;
  final paths = <String>{};
  settings['sftpGlobalBookmarks'] = value
      .whereType<Map>()
      .where((bookmark) => paths.add(bookmark['path']?.toString() ?? ''))
      .map(_copyMap)
      .toList(growable: false);
}

Set<String> _deletedIds(Map<String, dynamic> payload, String entityType) =>
    _deletionRecords(payload)
        .where((record) => record['entityType'] == entityType)
        .map((record) => record['id']?.toString() ?? '')
        .where((id) => id.isNotEmpty)
        .toSet();

List<Map<String, dynamic>> _deletionRecords(Map<String, dynamic> payload) {
  final meta = payload['syncMeta'];
  if (meta is! Map || meta['deletions'] is! List) {
    return <Map<String, dynamic>>[];
  }
  return (meta['deletions'] as List)
      .whereType<Map>()
      .map(_copyMap)
      .where((record) =>
          _allCollections.contains(record['entityType']) &&
          (record['id']?.toString().isNotEmpty ?? false))
      .toList(growable: false);
}

List<Map<String, dynamic>> _collectDeletions(
  Map<String, dynamic>? base,
  Map<String, dynamic> current,
  int deletedAt,
  String? deviceId,
) {
  if (base == null) return <Map<String, dynamic>>[];
  final result = <Map<String, dynamic>>[];
  for (final collection in _allCollections) {
    final baseIds = _valueIds(base[collection], collection);
    final currentValue = _optionalCollections.contains(collection) &&
            !current.containsKey(collection)
        ? base[collection]
        : current[collection];
    final currentIds = _valueIds(currentValue, collection);
    for (final id in baseIds.difference(currentIds)) {
      result.add(<String, dynamic>{
        'entityType': collection,
        'id': id,
        'deletedAt': deletedAt,
        if (deviceId != null && deviceId.isNotEmpty) 'deviceId': deviceId,
      });
    }
  }
  return result;
}

List<Map<String, dynamic>> _mergeDeletionRecords(
  Map<String, dynamic> payload,
  List<Map<String, dynamic>> records,
) {
  final byKey = <String, Map<String, dynamic>>{};
  for (final record in records) {
    final type = record['entityType']?.toString() ?? '';
    final id = record['id']?.toString() ?? '';
    if (!_allCollections.contains(type) || id.isEmpty) continue;
    if (_valueIds(payload[type], type).contains(id)) continue;
    final mapKey = '$type:$id';
    final previous = byKey[mapKey];
    final time = (record['deletedAt'] as num?)?.toInt() ?? 0;
    final previousTime = (previous?['deletedAt'] as num?)?.toInt() ?? -1;
    if (previous == null || time >= previousTime) {
      byKey[mapKey] = _copyMap(record);
    }
  }
  final output = byKey.values.toList();
  output.sort((left, right) {
    final type = left['entityType'].toString().compareTo(
          right['entityType'].toString(),
        );
    return type != 0
        ? type
        : left['id'].toString().compareTo(right['id'].toString());
  });
  return output;
}

Set<String> _valueIds(Object? value, String collection) {
  if (value is! List) return <String>{};
  if (_stringCollections.contains(collection)) {
    return value.whereType<String>().toSet();
  }
  final idKey = collection == 'groupConfigs' ? 'path' : 'id';
  return value
      .whereType<Map>()
      .map((item) => item[idKey]?.toString() ?? '')
      .where((id) => id.isNotEmpty)
      .toSet();
}

Map<String, dynamic> _summarizeChanges(
  Map<String, dynamic>? base,
  Map<String, dynamic> current,
) {
  final reference = base ?? _emptyPayload();
  final byEntity = <String, dynamic>{};
  var changed = false;
  for (final collection in _allCollections) {
    final before = _itemsById(reference[collection], collection);
    final afterValue = _optionalCollections.contains(collection) &&
            !current.containsKey(collection)
        ? reference[collection]
        : current[collection];
    final after = _itemsById(afterValue, collection);
    var added = 0;
    var modified = 0;
    var deleted = 0;
    for (final id in <String>{...before.keys, ...after.keys}) {
      if (!before.containsKey(id)) {
        added++;
      } else if (!after.containsKey(id)) {
        deleted++;
      } else if (!_jsonEqual(before[id], after[id])) {
        modified++;
      }
    }
    if (added + modified + deleted > 0) {
      changed = true;
      byEntity[collection] = <String, dynamic>{
        'added': {'local': added, 'remote': 0},
        'modified': {'local': modified, 'remote': 0},
        'deleted': {'local': deleted, 'remote': 0},
      };
    }
  }
  final settingsChanged =
      !_jsonEqual(reference['settings'], current['settings']);
  if (settingsChanged) {
    changed = true;
    byEntity['settings'] = <String, dynamic>{
      'added': {'local': 0, 'remote': 0},
      'modified': {'local': 1, 'remote': 0},
      'deleted': {'local': 0, 'remote': 0},
    };
  }
  return <String, dynamic>{
    'hasLocalChanges': changed,
    'hasRemoteChanges': false,
    'hasConflicts': false,
    'byEntity': byEntity,
    'conflicts': <dynamic>[],
  };
}

Map<String, dynamic> _minimalReliabilityMeta(
  Map<String, dynamic> payload,
  List<Map<String, dynamic>> deletions, {
  int? timestamp,
}) =>
    <String, dynamic>{
      'schemaVersion': 1,
      'generatedAt': timestamp ?? DateTime.now().millisecondsSinceEpoch,
      'localChanged': false,
      'deletions': deletions,
      'changeSummary': _summarizeChanges(null, payload),
    };

Map<String, Object?> _itemsById(Object? value, String collection) {
  if (value is! List) return <String, Object?>{};
  if (_stringCollections.contains(collection)) {
    return {for (final item in value.whereType<String>()) item: item};
  }
  final idKey = collection == 'groupConfigs' ? 'path' : 'id';
  return <String, Object?>{
    for (final item in value.whereType<Map>())
      if (item[idKey] is String && (item[idKey] as String).isNotEmpty)
        item[idKey] as String: item,
  };
}

bool _isIdArray(List<dynamic> value) =>
    value.isNotEmpty &&
    value.first is Map &&
    (value.first as Map).containsKey('id');

Map<String, dynamic>? _mapOrNull(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : null;

Map<String, dynamic> _copyMap(Map<dynamic, dynamic> value) =>
    Map<String, dynamic>.from(_deepCopy(value) as Map);

Object? _deepCopy(Object? value) {
  if (value is Map) {
    return <String, dynamic>{
      for (final entry in value.entries)
        entry.key.toString(): _deepCopy(entry.value),
    };
  }
  if (value is List) return value.map(_deepCopy).toList(growable: false);
  return value;
}

bool _jsonEqual(Object? left, Object? right) {
  if (identical(left, _missing) || identical(right, _missing)) {
    return identical(left, right);
  }
  return _fingerprint(left) == _fingerprint(right);
}

String _fingerprint(Object? value) => jsonEncode(_canonicalize(value));

Object? _canonicalize(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return <String, dynamic>{
      for (final key in keys) key: _canonicalize(value[key]),
    };
  }
  if (value is List) return value.map(_canonicalize).toList(growable: false);
  return value;
}
