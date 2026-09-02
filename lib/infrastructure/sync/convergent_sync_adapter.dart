import 'dart:convert';

import '../../domain/models/vault.dart';

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

const _missing = Object();

/// Applies a materialized mobile snapshot to a desktop convergent-sync v2
/// envelope without downgrading the cloud file to the legacy format.
///
/// Desktop v2 deliberately stores the selected values in the adjacent v1
/// snapshot and keeps causal history in [convergentSync]. This adapter hydrates
/// that history, applies only the materialized changes made by mobile, then
/// compacts the updated state against the outgoing snapshot again.
VaultData updateConvergentSyncPayload({
  required VaultData remote,
  required VaultData desired,
  required String deviceId,
  int? timestamp,
}) {
  if (deviceId.isEmpty) {
    throw const FormatException('Invalid sync device ID');
  }
  final remoteJson = remote.toJson();
  final desiredJson = desired.toJson(legacySyncSnapshot: true);
  final envelope = _requiredMap(remoteJson['convergentSync'], 'convergentSync');
  final state = _hydrateEnvelope(envelope, remoteJson);
  final editor = _StateEditor(
    state,
    deviceId,
    timestamp ?? DateTime.now().millisecondsSinceEpoch,
  );
  editor.applySnapshot(remoteJson, desiredJson);
  desiredJson['convergentSync'] = _compactEnvelope(state, desiredJson);
  return VaultData.fromJson(desiredJson);
}

bool hasConvergentSyncEnvelope(VaultData vault) =>
    vault.extras['convergentSync'] is Map;

void validateConvergentSyncPayload(VaultData vault) {
  final json = vault.toJson();
  final envelope = _requiredMap(json['convergentSync'], 'convergentSync');
  _hydrateEnvelope(envelope, json);
}

Map<String, dynamic> _hydrateEnvelope(
  Map<String, dynamic> envelope,
  Map<String, dynamic> materialized,
) {
  if (envelope['schemaVersion'] != 2 ||
      envelope['encoding'] != 'materialized-winner-v1') {
    throw const FormatException('Invalid convergent sync envelope');
  }
  final encoded = _requiredMap(envelope['state'], 'convergentSync.state');
  final state = <String, dynamic>{
    'schemaVersion': 2,
    'vector': _copyMap(_requiredMap(encoded['vector'], 'state.vector')),
    'dotOrigins':
        _copyMap(_requiredMap(encoded['dotOrigins'], 'state.dotOrigins')),
    'hlc': _copyMap(_requiredMap(encoded['hlc'], 'state.hlc')),
    'collections': <String, dynamic>{},
    'settings': <String, dynamic>{},
    'stringCollections': <String, dynamic>{},
  };

  final collections = _requiredMap(encoded['collections'], 'state.collections');
  for (final entry in collections.entries) {
    if (!_entityCollections.contains(entry.key)) {
      throw FormatException('Unsupported sync collection: ${entry.key}');
    }
    final collection = _requiredMap(entry.value, 'collection.${entry.key}');
    final entities = _requiredMap(
      collection['entities'],
      'collection.${entry.key}.entities',
    );
    final hydratedEntities = <String, dynamic>{};
    for (final entityEntry in entities.entries) {
      final entity = _requiredMap(
        entityEntry.value,
        '${entry.key}/${entityEntry.key}',
      );
      final fields = _requiredMap(
        entity['fields'],
        '${entry.key}/${entityEntry.key}.fields',
      );
      final materializedEntity = _materializedEntity(
        materialized,
        entry.key,
        entityEntry.key,
      );
      hydratedEntities[entityEntry.key] = <String, dynamic>{
        'presence': _hydrateRegister(
          entity['presence'],
          true,
          '${entry.key}/${entityEntry.key}.presence',
        ),
        if (entity['position'] != null)
          'position': _hydrateRegister(
            entity['position'],
            _missing,
            '${entry.key}/${entityEntry.key}.position',
          ),
        'fields': <String, dynamic>{
          for (final field in fields.entries)
            field.key: _hydrateRegister(
              field.value,
              _materializedField(materializedEntity, field.key),
              '${entry.key}/${entityEntry.key}.${field.key}',
            ),
        },
      };
    }
    (state['collections'] as Map<String, dynamic>)[entry.key] = {
      'entities': hydratedEntities,
    };
  }

  final settings = _requiredMap(encoded['settings'], 'state.settings');
  for (final entry in settings.entries) {
    final path = _decodeSettingPath(entry.key);
    (state['settings'] as Map<String, dynamic>)[entry.key] = _hydrateRegister(
      entry.value,
      _nestedValue(materialized['settings'], path),
      'settings/${entry.key}',
    );
  }

  final strings = _requiredMap(
    encoded['stringCollections'],
    'state.stringCollections',
  );
  for (final entry in strings.entries) {
    if (!_stringCollections.contains(entry.key)) {
      throw FormatException('Unsupported sync string collection: ${entry.key}');
    }
    final collection = _requiredMap(entry.value, 'strings.${entry.key}');
    final entries = _requiredMap(
      collection['entries'],
      'strings.${entry.key}.entries',
    );
    (state['stringCollections'] as Map<String, dynamic>)[entry.key] = {
      'entries': <String, dynamic>{
        for (final item in entries.entries)
          item.key: <String, dynamic>{
            'presence': _hydrateRegister(
              _requiredMap(
                  item.value, 'strings.${entry.key}/${item.key}')['presence'],
              true,
              'strings.${entry.key}/${item.key}.presence',
            ),
            if (_requiredMap(
                  item.value,
                  'strings.${entry.key}/${item.key}',
                )['position'] !=
                null)
              'position': _hydrateRegister(
                _requiredMap(
                  item.value,
                  'strings.${entry.key}/${item.key}',
                )['position'],
                _missing,
                'strings.${entry.key}/${item.key}.position',
              ),
          },
      },
    };
  }
  _validateState(state);
  return state;
}

Map<String, dynamic> _hydrateRegister(
  Object? value,
  Object? materialized,
  String label,
) {
  final register = _requiredMap(value, label);
  final candidates = register['candidates'];
  if (candidates is! List || candidates.isEmpty) {
    throw FormatException('$label has no candidates');
  }
  return {
    'candidates': candidates.indexed.map((indexed) {
      final candidate = _copyMap(
        _requiredMap(indexed.$2, '$label.candidates[${indexed.$1}]'),
      );
      if (candidate['tombstone'] == true) {
        if (candidate.containsKey('value') ||
            candidate.containsKey('materialized')) {
          throw FormatException('$label has an invalid tombstone candidate');
        }
      } else if (candidate['materialized'] == true) {
        if (candidate.containsKey('value') ||
            identical(materialized, _missing)) {
          throw FormatException('$label cannot restore its materialized value');
        }
        candidate
          ..remove('materialized')
          ..['value'] = _deepCopy(materialized);
      } else if (!candidate.containsKey('value')) {
        throw FormatException('$label is missing a candidate value');
      }
      return candidate;
    }).toList(growable: false),
  };
}

Map<String, dynamic> _compactEnvelope(
  Map<String, dynamic> state,
  Map<String, dynamic> materialized,
) {
  final collections = <String, dynamic>{};
  for (final collectionEntry in _map(state['collections']).entries) {
    final entities = <String, dynamic>{};
    for (final entityEntry
        in _map(_map(collectionEntry.value)['entities']).entries) {
      final entity = _map(entityEntry.value);
      final materializedEntity = _materializedEntity(
        materialized,
        collectionEntry.key,
        entityEntry.key,
      );
      entities[entityEntry.key] = <String, dynamic>{
        'presence': _compactRegister(_map(entity['presence'])),
        if (entity['position'] != null)
          'position': _compactRegister(_map(entity['position'])),
        'fields': <String, dynamic>{
          for (final field in _map(entity['fields']).entries)
            field.key: _compactRegister(
              _map(field.value),
              materialized: _materializedField(materializedEntity, field.key),
              allowMaterialized: true,
            ),
        },
      };
    }
    collections[collectionEntry.key] = {'entities': entities};
  }

  final settings = <String, dynamic>{};
  for (final entry in _map(state['settings']).entries) {
    settings[entry.key] = _compactRegister(
      _map(entry.value),
      materialized: _nestedValue(
        materialized['settings'],
        _decodeSettingPath(entry.key),
      ),
      allowMaterialized: true,
    );
  }

  final stringCollections = <String, dynamic>{};
  for (final collectionEntry in _map(state['stringCollections']).entries) {
    final entries = <String, dynamic>{};
    for (final entry in _map(_map(collectionEntry.value)['entries']).entries) {
      final item = _map(entry.value);
      entries[entry.key] = <String, dynamic>{
        'presence': _compactRegister(_map(item['presence'])),
        if (item['position'] != null)
          'position': _compactRegister(_map(item['position'])),
      };
    }
    stringCollections[collectionEntry.key] = {'entries': entries};
  }

  return <String, dynamic>{
    'schemaVersion': 2,
    'encoding': 'materialized-winner-v1',
    'state': <String, dynamic>{
      'vector': _deepCopy(state['vector']),
      'dotOrigins': _deepCopy(state['dotOrigins']),
      'hlc': _deepCopy(state['hlc']),
      'collections': collections,
      'settings': settings,
      'stringCollections': stringCollections,
    },
  };
}

Map<String, dynamic> _compactRegister(
  Map<String, dynamic> register, {
  Object? materialized = _missing,
  bool allowMaterialized = false,
}) {
  final candidates = (_map(register)['candidates'] as List)
      .map((value) => _map(value))
      .toList(growable: false);
  final winner = _winner(register);
  return {
    'candidates': candidates.map((candidate) {
      final compact = <String, dynamic>{
        'dot': _deepCopy(candidate['dot']),
        'context': _deepCopy(candidate['context']),
        'hlc': _deepCopy(candidate['hlc']),
      };
      if (candidate['tombstone'] == true) {
        compact['tombstone'] = true;
      } else if (allowMaterialized &&
          !identical(materialized, _missing) &&
          _sameDot(candidate, winner) &&
          _jsonEqual(candidate['value'], materialized)) {
        compact['materialized'] = true;
      } else {
        compact['value'] = _deepCopy(candidate['value']);
      }
      return compact;
    }).toList(growable: false),
  };
}

class _StateEditor {
  _StateEditor(this.state, this.deviceId, this.now);

  final Map<String, dynamic> state;
  final String deviceId;
  final int now;

  Map<String, dynamic> get _collections => _map(state['collections']);
  Map<String, dynamic> get _strings => _map(state['stringCollections']);
  Map<String, dynamic> get _settings => _map(state['settings']);

  void applySnapshot(
    Map<String, dynamic> current,
    Map<String, dynamic> desired,
  ) {
    for (final collection in _entityCollections) {
      final currentEntities = _entityIndex(current, collection);
      final desiredEntities = _entityIndex(desired, collection);
      final desiredList = _list(desired[collection]);
      for (var position = 0; position < desiredList.length; position++) {
        final value = desiredList[position];
        if (value is! Map) continue;
        final entity = Map<String, dynamic>.from(value);
        final id = _entityId(collection, entity);
        if (id == null) continue;
        _upsertEntity(collection, id, entity, position);
      }
      for (final id in currentEntities.keys) {
        if (!desiredEntities.containsKey(id)) _deleteEntity(collection, id);
      }
    }

    for (final collection in _stringCollections) {
      final currentValues = _stringValues(current[collection]);
      final desiredValues = _stringValues(desired[collection]);
      for (var position = 0; position < desiredValues.length; position++) {
        _addString(collection, desiredValues[position], position);
      }
      for (final value in currentValues) {
        if (!desiredValues.contains(value)) _deleteString(collection, value);
      }
    }

    final currentSettings = <String, Object?>{};
    final desiredSettings = <String, Object?>{};
    _flattenSettings(current['settings'], const [], currentSettings);
    _flattenSettings(desired['settings'], const [], desiredSettings);
    for (final entry in desiredSettings.entries) {
      _setSetting(_decodeSettingPath(entry.key), entry.value);
    }
    for (final path in currentSettings.keys) {
      if (!desiredSettings.containsKey(path)) {
        _deleteSetting(_decodeSettingPath(path));
      }
    }
    _validateState(state);
  }

  void _upsertEntity(
    String collectionName,
    String id,
    Map<String, dynamic> value,
    int position,
  ) {
    final collection = _collections.putIfAbsent(
      collectionName,
      () => <String, dynamic>{'entities': <String, dynamic>{}},
    );
    final entities = _map(_map(collection)['entities']);
    var created = false;
    final entity = _map(entities.putIfAbsent(id, () {
      created = true;
      return <String, dynamic>{
        'presence': <String, dynamic>{'candidates': <dynamic>[]},
        'fields': <String, dynamic>{},
      };
    }));
    final fields = _map(entity['fields']);
    var changed = created ||
        !_registerIsPresent(_map(entity['presence'])) ||
        _registerHasConflict(_map(entity['presence']));
    final incoming = Map<String, dynamic>.from(value)..remove('id');
    final fieldNames = {...fields.keys, ...incoming.keys}.toList()..sort();
    for (final field in fieldNames) {
      final current = fields[field] == null ? null : _map(fields[field]);
      if (!incoming.containsKey(field)) {
        final winner = current == null ? null : _winner(current);
        if (winner != null && winner['tombstone'] != true) {
          fields[field] = _writeRegister(
            current,
            _registerId(['entity-field', collectionName, id, field]),
            tombstone: true,
          );
          changed = true;
        }
      } else if (current == null ||
          _registerHasConflict(current) ||
          !_registerValueEquals(current, incoming[field])) {
        fields[field] = _writeRegister(
          current,
          _registerId(['entity-field', collectionName, id, field]),
          value: incoming[field],
        );
        changed = true;
      }
    }
    final currentPosition =
        entity['position'] == null ? null : _map(entity['position']);
    if (currentPosition == null ||
        _registerHasConflict(currentPosition) ||
        !_registerValueEquals(currentPosition, position)) {
      entity['position'] = _writeRegister(
        currentPosition,
        _registerId(['entity-position', collectionName, id]),
        value: position,
      );
      changed = true;
    }
    if (changed) {
      entity['presence'] = _writeRegister(
        _map(entity['presence']),
        _registerId(['entity-presence', collectionName, id]),
        value: true,
      );
    }
  }

  void _deleteEntity(String collectionName, String id) {
    final collection = _collections[collectionName];
    if (collection == null) return;
    final entity = _map(_map(collection)['entities'])[id];
    if (entity == null) return;
    final presence = _map(_map(entity)['presence']);
    if (!_registerIsPresent(presence)) return;
    _map(entity)['presence'] = _writeRegister(
      presence,
      _registerId(['entity-presence', collectionName, id]),
      tombstone: true,
    );
  }

  void _addString(String collectionName, String value, int position) {
    final collection = _strings.putIfAbsent(
      collectionName,
      () => <String, dynamic>{'entries': <String, dynamic>{}},
    );
    final entries = _map(_map(collection)['entries']);
    var created = false;
    final entry = _map(entries.putIfAbsent(value, () {
      created = true;
      return <String, dynamic>{
        'presence': <String, dynamic>{'candidates': <dynamic>[]},
      };
    }));
    final presence = _map(entry['presence']);
    var changed = created ||
        !_registerIsPresent(presence) ||
        _registerHasConflict(presence);
    final currentPosition =
        entry['position'] == null ? null : _map(entry['position']);
    if (currentPosition == null ||
        _registerHasConflict(currentPosition) ||
        !_registerValueEquals(currentPosition, position)) {
      entry['position'] = _writeRegister(
        currentPosition,
        _registerId(['string-entry-position', collectionName, value]),
        value: position,
      );
      changed = true;
    }
    if (changed) {
      entry['presence'] = _writeRegister(
        presence,
        _registerId(['string-entry-presence', collectionName, value]),
        value: true,
      );
    }
  }

  void _deleteString(String collectionName, String value) {
    final collection = _strings[collectionName];
    if (collection == null) return;
    final entry = _map(_map(collection)['entries'])[value];
    if (entry == null) return;
    final presence = _map(_map(entry)['presence']);
    if (!_registerIsPresent(presence)) return;
    _map(entry)['presence'] = _writeRegister(
      presence,
      _registerId(['string-entry-presence', collectionName, value]),
      tombstone: true,
    );
  }

  void _setSetting(List<String> path, Object? value) =>
      _writeSetting(path, value: value);

  void _deleteSetting(List<String> path) =>
      _writeSetting(path, tombstone: true);

  void _writeSetting(
    List<String> path, {
    Object? value,
    bool tombstone = false,
  }) {
    final encoded = _encodeSettingPath(path);
    final related = _settings.keys.toList()..sort();
    for (final otherEncoded in related) {
      if (otherEncoded == encoded) continue;
      final otherPath = _decodeSettingPath(otherEncoded);
      final overlaps = tombstone
          ? _isPrefix(path, otherPath)
          : _isPrefix(path, otherPath) || _isPrefix(otherPath, path);
      if (!overlaps) continue;
      final register = _map(_settings[otherEncoded]);
      final winner = _winner(register);
      if (winner == null || winner['tombstone'] == true) continue;
      _settings[otherEncoded] = _writeRegister(
        register,
        _registerId(['setting', ...otherPath]),
        tombstone: true,
      );
    }
    final current =
        _settings[encoded] == null ? null : _map(_settings[encoded]);
    final currentWinner = current == null ? null : _winner(current);
    if (current != null &&
        !_registerHasConflict(current) &&
        (tombstone
            ? currentWinner != null && currentWinner['tombstone'] == true
            : _registerValueEquals(current, value))) {
      return;
    }
    _settings[encoded] = _writeRegister(
      current,
      _registerId(['setting', ...path]),
      value: value,
      tombstone: tombstone,
    );
  }

  Map<String, dynamic> _writeRegister(
    Map<String, dynamic>? current,
    String identity, {
    Object? value,
    bool tombstone = false,
  }) {
    final context = <String, Map<String, dynamic>>{};
    for (final candidateValue in _candidateList(current)) {
      final candidate = _map(candidateValue);
      for (final dotValue in _list(candidate['context'])) {
        final dot = _map(dotValue);
        context[_dotKey(dot)] = _copyMap(dot);
      }
      final dot = _map(candidate['dot']);
      context[_dotKey(dot)] = _copyMap(dot);
    }
    final vector = _map(state['vector']);
    final counter = ((vector[deviceId] as num?)?.toInt() ?? 0) + 1;
    vector[deviceId] = counter;
    final origins = _map(state['dotOrigins']);
    final deviceOrigins = origins.putIfAbsent(
      deviceId,
      () => <String, dynamic>{},
    );
    _map(deviceOrigins)['$counter'] = identity;
    final clock = _map(state['hlc']);
    final wallTime = (clock['wallTime'] as num?)?.toInt() ?? 0;
    final logical = (clock['logical'] as num?)?.toInt() ?? 0;
    if (now > wallTime) {
      clock
        ..['wallTime'] = now
        ..['logical'] = 0;
    } else {
      clock['logical'] = logical + 1;
    }
    final sortedContext = context.values.toList()
      ..sort((left, right) {
        final device =
            left['deviceId'].toString().compareTo(right['deviceId'].toString());
        if (device != 0) return device;
        return (left['counter'] as num)
            .toInt()
            .compareTo((right['counter'] as num).toInt());
      });
    final candidate = <String, dynamic>{
      'dot': {'deviceId': deviceId, 'counter': counter},
      'context': sortedContext,
      'hlc': _copyMap(clock),
      if (tombstone) 'tombstone': true else 'value': _deepCopy(value),
    };
    return {
      'candidates': [candidate],
    };
  }
}

void _validateState(Map<String, dynamic> state) {
  final vector = _requiredMap(state['vector'], 'state.vector');
  final origins = _requiredMap(state['dotOrigins'], 'state.dotOrigins');
  final clock = _requiredMap(state['hlc'], 'state.hlc');
  final wallTime = (clock['wallTime'] as num?)?.toInt();
  final logical = (clock['logical'] as num?)?.toInt();
  if (wallTime == null || wallTime < 0 || logical == null || logical < 0) {
    throw const FormatException('Invalid convergent sync clock');
  }
  final witnessed = <String>{};
  final candidateDots = <String>{};

  void validateRegister(Object? raw, String identity) {
    final register = _requiredMap(raw, identity);
    final candidates = register['candidates'];
    if (candidates is! List || candidates.isEmpty) {
      throw FormatException('$identity has no candidates');
    }
    for (final rawCandidate in candidates) {
      final candidate = _requiredMap(rawCandidate, identity);
      final dot = _requiredMap(candidate['dot'], '$identity.dot');
      final key = _validateDot(dot, identity, vector, origins);
      if (!candidateDots.add(key)) {
        throw FormatException('Duplicate convergent dot: $key');
      }
      witnessed.add(key);
      final contexts = candidate['context'];
      if (contexts is! List) {
        throw FormatException('$identity has an invalid context');
      }
      final localContexts = <String>{};
      for (final rawContext in contexts) {
        final context = _requiredMap(rawContext, '$identity.context');
        final contextKey = _validateDot(context, identity, vector, origins);
        if (contextKey == key || !localContexts.add(contextKey)) {
          throw FormatException('$identity has a duplicate context dot');
        }
        witnessed.add(contextKey);
      }
      final candidateClock = _requiredMap(candidate['hlc'], '$identity.hlc');
      final candidateWall = (candidateClock['wallTime'] as num?)?.toInt();
      final candidateLogical = (candidateClock['logical'] as num?)?.toInt();
      if (candidateWall == null ||
          candidateLogical == null ||
          candidateWall < 0 ||
          candidateLogical < 0 ||
          candidateWall > wallTime ||
          (candidateWall == wallTime && candidateLogical > logical)) {
        throw FormatException('$identity has an invalid clock');
      }
      if (candidate['tombstone'] == true) {
        if (candidate.containsKey('value')) {
          throw FormatException('$identity has an invalid tombstone');
        }
      } else if (!candidate.containsKey('value')) {
        throw FormatException('$identity is missing a value');
      }
    }
  }

  for (final collectionEntry in _map(state['collections']).entries) {
    for (final entityEntry
        in _map(_map(collectionEntry.value)['entities']).entries) {
      final entity = _map(entityEntry.value);
      validateRegister(
        entity['presence'],
        _registerId([
          'entity-presence',
          collectionEntry.key,
          entityEntry.key,
        ]),
      );
      if (entity['position'] != null) {
        validateRegister(
          entity['position'],
          _registerId([
            'entity-position',
            collectionEntry.key,
            entityEntry.key,
          ]),
        );
      }
      for (final field in _map(entity['fields']).entries) {
        validateRegister(
          field.value,
          _registerId([
            'entity-field',
            collectionEntry.key,
            entityEntry.key,
            field.key,
          ]),
        );
      }
    }
  }
  for (final entry in _map(state['settings']).entries) {
    validateRegister(
      entry.value,
      _registerId(['setting', ..._decodeSettingPath(entry.key)]),
    );
  }
  for (final collectionEntry in _map(state['stringCollections']).entries) {
    for (final entry in _map(_map(collectionEntry.value)['entries']).entries) {
      final value = _map(entry.value);
      validateRegister(
        value['presence'],
        _registerId([
          'string-entry-presence',
          collectionEntry.key,
          entry.key,
        ]),
      );
      if (value['position'] != null) {
        validateRegister(
          value['position'],
          _registerId([
            'string-entry-position',
            collectionEntry.key,
            entry.key,
          ]),
        );
      }
    }
  }
  for (final entry in vector.entries) {
    final counter = (entry.value as num?)?.toInt();
    final deviceOrigins = origins[entry.key];
    if (counter == null || counter <= 0 || deviceOrigins is! Map) {
      throw FormatException('Invalid state vector for ${entry.key}');
    }
    for (var value = 1; value <= counter; value++) {
      if (!_map(deviceOrigins).containsKey('$value') ||
          !witnessed.contains('${entry.key}:$value')) {
        throw FormatException('State vector for ${entry.key} is not witnessed');
      }
    }
  }
}

String _validateDot(
  Map<String, dynamic> dot,
  String identity,
  Map<String, dynamic> vector,
  Map<String, dynamic> origins,
) {
  final device = dot['deviceId'];
  final counter = (dot['counter'] as num?)?.toInt();
  if (device is! String ||
      device.isEmpty ||
      counter == null ||
      counter <= 0 ||
      counter > ((vector[device] as num?)?.toInt() ?? 0)) {
    throw FormatException('$identity has an invalid dot');
  }
  final deviceOrigins = origins[device];
  if (deviceOrigins is! Map || _map(deviceOrigins)['$counter'] != identity) {
    throw FormatException('$identity has an invalid dot origin');
  }
  return '$device:$counter';
}

Map<String, dynamic>? _materializedEntity(
  Map<String, dynamic> payload,
  String collection,
  String id,
) =>
    _entityIndex(payload, collection)[id];

Object? _materializedField(Map<String, dynamic>? entity, String field) =>
    entity != null && entity.containsKey(field) ? entity[field] : _missing;

Map<String, Map<String, dynamic>> _entityIndex(
  Map<String, dynamic> payload,
  String collection,
) {
  final result = <String, Map<String, dynamic>>{};
  for (final value in _list(payload[collection])) {
    if (value is! Map) continue;
    final entity = Map<String, dynamic>.from(value);
    final id = _entityId(collection, entity);
    if (id != null) result[id] = entity;
  }
  return result;
}

String? _entityId(String collection, Map<String, dynamic> value) {
  final id = collection == 'groupConfigs' ? value['path'] : value['id'];
  return id is String && id.isNotEmpty ? id : null;
}

List<String> _stringValues(Object? value) =>
    _list(value).whereType<String>().toList(growable: false);

void _flattenSettings(
  Object? value,
  List<String> path,
  Map<String, Object?> output,
) {
  if (value is Map && value.isNotEmpty) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    for (final key in keys) {
      _flattenSettings(value[key], [...path, key], output);
    }
    return;
  }
  if (path.isNotEmpty && !identical(value, _missing)) {
    output[_encodeSettingPath(path)] = _deepCopy(value);
  }
}

Object? _nestedValue(Object? value, List<String> path) {
  var current = value;
  for (final segment in path) {
    if (current is! Map || !current.containsKey(segment)) return _missing;
    current = current[segment];
  }
  return current;
}

String _encodeSettingPath(List<String> path) =>
    '/${path.map((segment) => segment.replaceAll('~', '~0').replaceAll('/', '~1')).join('/')}';

List<String> _decodeSettingPath(String encoded) {
  if (!encoded.startsWith('/') || encoded.length < 2) {
    throw FormatException('Invalid setting path: $encoded');
  }
  final path = encoded
      .substring(1)
      .split('/')
      .map((segment) => segment.replaceAll('~1', '/').replaceAll('~0', '~'))
      .toList(growable: false);
  if (_encodeSettingPath(path) != encoded) {
    throw FormatException('Non-canonical setting path: $encoded');
  }
  return path;
}

bool _isPrefix(List<String> prefix, List<String> path) =>
    prefix.length <= path.length &&
    prefix.indexed.every((entry) => entry.$2 == path[entry.$1]);

String _registerId(List<String> components) => jsonEncode(components);

List<dynamic> _candidateList(Map<String, dynamic>? register) =>
    register == null ? const [] : _list(register['candidates']);

Map<String, dynamic>? _winner(Map<String, dynamic> register) {
  final candidates = _candidateList(register).map(_map).toList();
  if (candidates.isEmpty) return null;
  return candidates.reduce(
    (winner, candidate) =>
        _compareCandidates(candidate, winner) > 0 ? candidate : winner,
  );
}

int _compareCandidates(
  Map<String, dynamic> left,
  Map<String, dynamic> right,
) {
  final leftTombstone = left['tombstone'] == true;
  final rightTombstone = right['tombstone'] == true;
  if (leftTombstone != rightTombstone) return leftTombstone ? -1 : 1;
  final leftClock = _map(left['hlc']);
  final rightClock = _map(right['hlc']);
  final wall = (leftClock['wallTime'] as num)
      .toInt()
      .compareTo((rightClock['wallTime'] as num).toInt());
  if (wall != 0) return wall;
  final logical = (leftClock['logical'] as num)
      .toInt()
      .compareTo((rightClock['logical'] as num).toInt());
  if (logical != 0) return logical;
  final leftDot = _map(left['dot']);
  final rightDot = _map(right['dot']);
  final device =
      leftDot['deviceId'].toString().compareTo(rightDot['deviceId'].toString());
  if (device != 0) return device;
  return (leftDot['counter'] as num)
      .toInt()
      .compareTo((rightDot['counter'] as num).toInt());
}

bool _registerValueEquals(Map<String, dynamic> register, Object? value) {
  final winner = _winner(register);
  return winner != null &&
      winner['tombstone'] != true &&
      _jsonEqual(winner['value'], value);
}

bool _registerIsPresent(Map<String, dynamic> register) {
  final winner = _winner(register);
  return winner != null && winner['tombstone'] != true;
}

bool _registerHasConflict(Map<String, dynamic> register) {
  final values = _candidateList(register).map((candidateValue) {
    final candidate = _map(candidateValue);
    return candidate['tombstone'] == true
        ? '<tombstone>'
        : jsonEncode(_canonicalize(candidate['value']));
  }).toSet();
  return values.length > 1;
}

bool _sameDot(Map<String, dynamic> left, Map<String, dynamic>? right) {
  if (right == null) return false;
  return _dotKey(_map(left['dot'])) == _dotKey(_map(right['dot']));
}

String _dotKey(Map<String, dynamic> dot) =>
    '${dot['deviceId']}:${dot['counter']}';

bool _jsonEqual(Object? left, Object? right) =>
    jsonEncode(_canonicalize(left)) == jsonEncode(_canonicalize(right));

Object? _canonicalize(Object? value) {
  if (value is List) return value.map(_canonicalize).toList(growable: false);
  if (value is Map) {
    final keys = value.keys.map((key) => key.toString()).toList()..sort();
    return <String, dynamic>{
      for (final key in keys) key: _canonicalize(value[key]),
    };
  }
  return value;
}

Map<String, dynamic> _requiredMap(Object? value, String label) {
  if (value is! Map) throw FormatException('$label is not an object');
  return Map<String, dynamic>.from(value);
}

Map<String, dynamic> _map(Object? value) => value is Map<String, dynamic>
    ? value
    : Map<String, dynamic>.from(value! as Map);

List<dynamic> _list(Object? value) => value is List ? value : const [];

Map<String, dynamic> _copyMap(Map<String, dynamic> value) =>
    Map<String, dynamic>.from(_deepCopy(value) as Map);

Object? _deepCopy(Object? value) => jsonDecode(jsonEncode(value));
