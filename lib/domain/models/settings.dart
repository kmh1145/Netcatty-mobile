enum SyncProviderType { webdav, githubGist, s3 }

const minTerminalFontSize = 6.0;
const maxTerminalFontSize = 24.0;
const defaultAiModel = 'gpt-4.1-mini';
const maxAiChatHistoryMessages = 30;

class TerminalCustomKey {
  const TerminalCustomKey({
    required this.id,
    required this.label,
    required this.value,
  });

  factory TerminalCustomKey.fromJson(Map<String, dynamic> json) =>
      TerminalCustomKey(
        id: json['id']?.toString() ?? '',
        label: json['label']?.toString() ?? '',
        value: json['value']?.toString() ?? '',
      );

  final String id;
  final String label;
  final String value;

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'value': value,
      };
}

class AppSettings {
  const AppSettings({
    this.themeMode = 'dark',
    this.uiThemeId = 'tokyo-night',
    this.serverViewMode = 'grid',
    this.terminalFontSize = 14,
    this.terminalSecureKeyboard = false,
    this.language = 'zh-CN',
    this.aiEndpoint = 'https://api.openai.com/v1',
    this.aiModel = defaultAiModel,
    this.aiModels = const [defaultAiModel],
    this.aiIncludeTerminalContext = false,
    this.autoSyncEnabled = false,
    this.terminalQuickKeys = defaultTerminalQuickKeys,
    this.terminalCustomKeys = const [],
  });

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final customKeys = (json['terminalCustomKeys'] as List? ?? const [])
        .whereType<Map>()
        .map((value) => TerminalCustomKey.fromJson(
              Map<String, dynamic>.from(value),
            ))
        .where((key) =>
            key.id.startsWith('custom-') &&
            key.label.isNotEmpty &&
            key.value.isNotEmpty)
        .toList(growable: false);
    final supported = {
      ...supportedTerminalQuickKeys,
      ...customKeys.map((key) => key.id),
    };
    final rawStoredOrder = (json['terminalQuickKeys'] as List? ?? const [])
        .map((value) => value.toString())
        .toList();
    final storedOrder = rawStoredOrder.where(supported.contains).toList();
    final order = storedOrder.isEmpty ||
            _sameStrings(rawStoredOrder, legacyDefaultTerminalQuickKeys) ||
            _sameStrings(rawStoredOrder, previousMobileDefaultTerminalQuickKeys)
        ? defaultTerminalQuickKeys
        : storedOrder;
    final selectedAiModel =
        json['aiModel']?.toString().trim() ?? defaultAiModel;
    final aiModels = _normalizeAiModels(
      json['aiModels'],
      selectedAiModel: selectedAiModel,
    );
    return AppSettings(
      themeMode: json['themeMode']?.toString() ?? 'dark',
      uiThemeId: json['uiThemeId']?.toString() ?? 'tokyo-night',
      serverViewMode: _serverViewMode(json['serverViewMode']?.toString()),
      terminalFontSize: ((json['terminalFontSize'] as num?)?.toDouble() ?? 14)
          .clamp(minTerminalFontSize, maxTerminalFontSize)
          .toDouble(),
      terminalSecureKeyboard: json['terminalSecureKeyboard'] == true,
      language: json['language']?.toString() ?? 'zh-CN',
      aiEndpoint: json['aiEndpoint']?.toString() ?? 'https://api.openai.com/v1',
      aiModel:
          aiModels.contains(selectedAiModel) ? selectedAiModel : aiModels.first,
      aiModels: aiModels,
      aiIncludeTerminalContext: json['aiIncludeTerminalContext'] == true,
      autoSyncEnabled: json['autoSyncEnabled'] == true,
      terminalQuickKeys: order,
      terminalCustomKeys: customKeys,
    );
  }

  final String themeMode;
  final String uiThemeId;
  final String serverViewMode;
  final double terminalFontSize;
  final bool terminalSecureKeyboard;
  final String language;
  final String aiEndpoint;
  final String aiModel;
  final List<String> aiModels;
  final bool aiIncludeTerminalContext;
  final bool autoSyncEnabled;
  final List<String> terminalQuickKeys;
  final List<TerminalCustomKey> terminalCustomKeys;

  AppSettings copyWith({
    String? themeMode,
    String? uiThemeId,
    String? serverViewMode,
    double? terminalFontSize,
    bool? terminalSecureKeyboard,
    String? language,
    String? aiEndpoint,
    String? aiModel,
    List<String>? aiModels,
    bool? aiIncludeTerminalContext,
    bool? autoSyncEnabled,
    List<String>? terminalQuickKeys,
    List<TerminalCustomKey>? terminalCustomKeys,
  }) =>
      AppSettings(
        themeMode: themeMode ?? this.themeMode,
        uiThemeId: uiThemeId ?? this.uiThemeId,
        serverViewMode: serverViewMode ?? this.serverViewMode,
        terminalFontSize: terminalFontSize ?? this.terminalFontSize,
        terminalSecureKeyboard:
            terminalSecureKeyboard ?? this.terminalSecureKeyboard,
        language: language ?? this.language,
        aiEndpoint: aiEndpoint ?? this.aiEndpoint,
        aiModel: aiModel ?? this.aiModel,
        aiModels: aiModels ?? this.aiModels,
        aiIncludeTerminalContext:
            aiIncludeTerminalContext ?? this.aiIncludeTerminalContext,
        autoSyncEnabled: autoSyncEnabled ?? this.autoSyncEnabled,
        terminalQuickKeys: terminalQuickKeys ?? this.terminalQuickKeys,
        terminalCustomKeys: terminalCustomKeys ?? this.terminalCustomKeys,
      );

  Map<String, dynamic> toJson() => {
        'themeMode': themeMode,
        'uiThemeId': uiThemeId,
        'serverViewMode': serverViewMode,
        'terminalFontSize': terminalFontSize,
        'terminalSecureKeyboard': terminalSecureKeyboard,
        'language': language,
        'aiEndpoint': aiEndpoint,
        'aiModel': aiModel,
        'aiModels': aiModels,
        'aiIncludeTerminalContext': aiIncludeTerminalContext,
        'autoSyncEnabled': autoSyncEnabled,
        'terminalQuickKeys': terminalQuickKeys,
        'terminalCustomKeys':
            terminalCustomKeys.map((key) => key.toJson()).toList(),
      };

  static String _serverViewMode(String? value) =>
      const {'grid', 'list', 'tree'}.contains(value) ? value! : 'grid';

  static List<String> _normalizeAiModels(
    Object? value, {
    required String selectedAiModel,
  }) {
    final models = <String>[];
    void add(String model) {
      final normalized = model.trim();
      if (normalized.isNotEmpty && !models.contains(normalized)) {
        models.add(normalized);
      }
    }

    if (value is List) {
      for (final model in value) {
        add(model.toString());
      }
    }
    add(selectedAiModel);
    if (models.isEmpty) add(defaultAiModel);
    return List<String>.unmodifiable(models);
  }
}

const defaultTerminalQuickKeys = <String>[
  'escape',
  'alt',
  'home',
  'arrowUp',
  'end',
  'paste',
  'tab',
  'ctrl',
  'arrowLeft',
  'arrowDown',
  'arrowRight',
  'shift',
];

const previousMobileDefaultTerminalQuickKeys = <String>[
  'escape',
  'alt',
  'ctrl',
  'shift',
  'tab',
  'arrowUp',
  'arrowDown',
  'arrowLeft',
  'arrowRight',
  'home',
  'end',
  'paste',
];

const supportedTerminalQuickKeys = <String>[
  ...defaultTerminalQuickKeys,
  'ctrlC',
  'ctrlD',
  'ctrlZ',
  'pipe',
  'slash',
  'tilde',
];

const legacyDefaultTerminalQuickKeys = <String>[
  'escape',
  'tab',
  'ctrlC',
  'ctrlD',
  'ctrlZ',
  'arrowUp',
  'arrowDown',
  'arrowLeft',
  'arrowRight',
  'pipe',
  'slash',
  'tilde',
  'hideKeyboard',
];

bool _sameStrings(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

class SyncConnection {
  const SyncConnection({
    required this.type,
    required this.endpoint,
    this.username,
    this.secret,
    this.resourceId,
    this.region,
    this.bucket,
    this.accessKeyId,
    this.sessionToken,
    this.prefix,
    this.forcePathStyle = true,
    this.allowInsecure = false,
  });

  factory SyncConnection.fromJson(Map<String, dynamic> json) => SyncConnection(
        type: SyncProviderType.values.firstWhere(
          (value) => value.name == json['type'],
          orElse: () => SyncProviderType.webdav,
        ),
        endpoint: json['endpoint']?.toString() ?? '',
        username: json['username']?.toString(),
        resourceId: json['resourceId']?.toString(),
        region: json['region']?.toString(),
        bucket: json['bucket']?.toString(),
        accessKeyId: json['accessKeyId']?.toString(),
        prefix: json['prefix']?.toString(),
        forcePathStyle: json['forcePathStyle'] as bool? ?? true,
        allowInsecure: json['allowInsecure'] as bool? ?? false,
      );

  final SyncProviderType type;
  final String endpoint;
  final String? username;
  final String? secret;
  final String? resourceId;
  final String? region;
  final String? bucket;
  final String? accessKeyId;
  final String? sessionToken;
  final String? prefix;
  final bool forcePathStyle;
  final bool allowInsecure;

  SyncConnection copyWith({
    SyncProviderType? type,
    String? endpoint,
    String? username,
    String? secret,
    String? resourceId,
    String? region,
    String? bucket,
    String? accessKeyId,
    String? sessionToken,
    String? prefix,
    bool? forcePathStyle,
    bool? allowInsecure,
  }) =>
      SyncConnection(
        type: type ?? this.type,
        endpoint: endpoint ?? this.endpoint,
        username: username ?? this.username,
        secret: secret ?? this.secret,
        resourceId: resourceId ?? this.resourceId,
        region: region ?? this.region,
        bucket: bucket ?? this.bucket,
        accessKeyId: accessKeyId ?? this.accessKeyId,
        sessionToken: sessionToken ?? this.sessionToken,
        prefix: prefix ?? this.prefix,
        forcePathStyle: forcePathStyle ?? this.forcePathStyle,
        allowInsecure: allowInsecure ?? this.allowInsecure,
      );

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'endpoint': endpoint,
        'username': username,
        'resourceId': resourceId,
        'region': region,
        'bucket': bucket,
        'accessKeyId': accessKeyId,
        'prefix': prefix,
        'forcePathStyle': forcePathStyle,
        'allowInsecure': allowInsecure,
      };
}

class SyncVersionCheckpoint {
  const SyncVersionCheckpoint({
    required this.target,
    required this.version,
    required this.vaultFingerprint,
  });

  factory SyncVersionCheckpoint.fromJson(Map<String, dynamic> json) =>
      SyncVersionCheckpoint(
        target: json['target']?.toString() ?? '',
        version: (json['version'] as num?)?.toInt() ?? 0,
        vaultFingerprint: json['vaultFingerprint']?.toString() ?? '',
      );

  final String target;
  final int version;
  final String vaultFingerprint;

  Map<String, dynamic> toJson() => {
        'target': target,
        'version': version,
        'vaultFingerprint': vaultFingerprint,
      };
}
