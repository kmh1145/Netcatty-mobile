import 'dart:async';
import 'dart:convert';

import '../../domain/models/settings.dart';
import 'ai_service.dart';

/// Mobile-only configuration. Never serialized into the desktop vault.
class AiProviderProfile {
  const AiProviderProfile(
      {required this.id,
      required this.name,
      required this.endpoint,
      required this.models,
      this.apiKey = '',
      this.jsonMode = false,
      this.reasoning = true});
  final String id, name, endpoint, apiKey;
  final List<String> models;
  final bool jsonMode, reasoning;
  AppSettings apply(AppSettings base) => base.copyWith(
      aiEndpoint: endpoint, aiModels: models, aiModel: models.first);
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'endpoint': endpoint,
        'apiKey': apiKey,
        'models': models,
        'jsonMode': jsonMode,
        'reasoning': reasoning
      };
  factory AiProviderProfile.fromJson(Map<String, dynamic> value) {
    final models = (value['models'] as List? ?? [])
        .whereType<String>()
        .where((s) => s.trim().isNotEmpty)
        .toSet()
        .toList();
    return AiProviderProfile(
        id: value['id'] as String,
        name: value['name'] as String,
        endpoint: value['endpoint'] as String,
        apiKey: value['apiKey'] as String? ?? '',
        models: models.isEmpty ? [defaultAiModel] : models,
        jsonMode: value['jsonMode'] == true,
        reasoning: value['reasoning'] != false);
  }
}

class AiConversation {
  const AiConversation({this.messages = const [], this.summary = ''});
  final List<AiChatMessage> messages;
  final String summary;
  Map<String, dynamic> toJson() => {
        'summary': summary,
        'messages': messages
            .map((m) => {
                  'role': m.role.name,
                  'content': m.content,
                  'command': m.command
                })
            .toList()
      };
  factory AiConversation.fromJson(Map<String, dynamic> json) => AiConversation(
      summary: json['summary'] as String? ?? '',
      messages: (json['messages'] as List? ?? [])
          .whereType<Map>()
          .map((m) => AiChatMessage(
              role: m['role'] == 'assistant'
                  ? AiChatRole.assistant
                  : AiChatRole.user,
              content: m['content'] as String? ?? '',
              command: m['command'] as String?))
          .toList());
}

/// Stores secrets and chat history through the same secure store as vault keys.
/// Serial writes ensure an older callback cannot resurrect a deleted history.
class AiWorkspace {
  AiWorkspace({required this.read, required this.write});
  final Future<String?> Function(String) read;
  final Future<void> Function(String, String?) write;
  Future<void> _pending = Future.value();
  Future<void> _save(String key, String? value) {
    final next = _pending.then((_) => write(key, value));
    _pending = next.catchError((Object _) {});
    return next;
  }

  Future<List<AiProviderProfile>> profiles() async {
    await _pending;
    final value = await read('profiles');
    if (value == null) return [];
    return (jsonDecode(value) as List)
        .map((v) =>
            AiProviderProfile.fromJson(Map<String, dynamic>.from(v as Map)))
        .toList();
  }

  /// Import legacy mobile configuration once without changing the shared vault.
  /// The marker prevents a deleted imported provider from being resurrected.
  Future<void> migrateLegacyProvider(AppSettings settings, String apiKey) {
    final next = _pending.then((_) async {
      if (await read('legacyMigrated') == 'true') return;
      final configured = apiKey.trim().isNotEmpty ||
          settings.aiEndpoint != const AppSettings().aiEndpoint ||
          settings.aiModel != defaultAiModel ||
          settings.aiModels.any((model) => model != defaultAiModel);
      if (configured) {
        final raw = await read('profiles');
        final entries = raw == null
            ? <AiProviderProfile>[]
            : (jsonDecode(raw) as List)
                .map((v) => AiProviderProfile.fromJson(
                    Map<String, dynamic>.from(v as Map)))
                .toList();
        var migrated = entries
            .where((p) =>
                p.id == 'legacy-mobile' ||
                (p.endpoint == settings.aiEndpoint &&
                    p.apiKey == apiKey &&
                    p.models.contains(settings.aiModel)))
            .firstOrNull;
        if (migrated == null) {
          migrated = AiProviderProfile(
              id: 'legacy-mobile',
              name: '原有配置',
              endpoint: settings.aiEndpoint,
              apiKey: apiKey,
              models: {settings.aiModel, ...settings.aiModels}.toList());
          entries.add(migrated);
          await write(
              'profiles', jsonEncode(entries.map((p) => p.toJson()).toList()));
        }
        if (await read('activeProfile') == null) {
          await write('activeProfile', migrated.id);
        }
        await write('model.${migrated.id}', settings.aiModel);
      }
      await write('legacyMigrated', 'true');
    });
    _pending = next.catchError((Object _) {});
    return next;
  }

  Future<bool> riskAcknowledged() async {
    await _pending;
    return await read('riskAcknowledged') == 'true';
  }

  Future<void> acknowledgeRisk() => _save('riskAcknowledged', 'true');

  Future<void> saveProfiles(List<AiProviderProfile> profiles) =>
      _save('profiles', jsonEncode(profiles.map((p) => p.toJson()).toList()));
  Future<String?> activeProfile() async {
    await _pending;
    return read('activeProfile');
  }

  Future<void> setActiveProfile(String? id) => _save('activeProfile', id);
  Future<String?> preferredModel(String id) async {
    await _pending;
    return read('model.$id');
  }

  Future<void> setPreferredModel(String id, String model) =>
      _save('model.$id', model);
  Future<AiConversation> conversation(String hostId) async {
    await _pending;
    final value = await read('history.$hostId');
    return value == null
        ? const AiConversation()
        : AiConversation.fromJson(jsonDecode(value) as Map<String, dynamic>);
  }

  Future<void> saveConversation(String hostId, AiConversation? conversation) {
    final next = _pending.then((_) async {
      // Also enforce the preference at write time: a late UI callback must
      // not resurrect history after the user turned persistence off.
      if (conversation != null && await read('remember.$hostId') == 'false') {
        return;
      }
      await write('history.$hostId',
          conversation == null ? null : jsonEncode(conversation.toJson()));
    });
    _pending = next.catchError((Object _) {});
    return next;
  }

  Future<bool> remembersHistory(String hostId) async {
    await _pending;
    return await read('remember.$hostId') != 'false';
  }

  Future<void> setRememberHistory(String hostId, bool value) async {
    await _save('remember.$hostId', '$value');
    if (!value) await saveConversation(hostId, null);
  }
}

/// Best-effort redaction, not a guarantee. The preview remains user-reviewable.
String redactAiText(String text,
    {Iterable<String> identities = const [], bool redactSecrets = true}) {
  var result = text;
  if (redactSecrets) {
    result = result.replaceAll(
        RegExp(
            r'-----BEGIN [^-]*PRIVATE KEY-----[\s\S]*?-----END [^-]*PRIVATE KEY-----'),
        '[PRIVATE KEY REDACTED]');
    result = result.replaceAllMapped(
        RegExp(
            r'(authorization\s*:\s*bearer\s+|(?:api[_-]?key|token|password|secret)\s*[=:]\s*)[^\s,;]+',
            caseSensitive: false),
        (m) => '${m[1]}[REDACTED]');
    result = result.replaceAll(
        RegExp(r'\b(?:sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9_]{16,})\b'),
        '[TOKEN REDACTED]');
  }
  final sorted = identities.where((s) => s.isNotEmpty).toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  for (final identity in sorted) {
    result = result.replaceAll(identity, '[HOST]');
  }
  return result;
}
