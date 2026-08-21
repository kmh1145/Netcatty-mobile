enum SyncProviderType { webdav, githubGist }

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
    this.aiModel = 'gpt-4.1-mini',
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
    return AppSettings(
      themeMode: json['themeMode']?.toString() ?? 'dark',
      uiThemeId: json['uiThemeId']?.toString() ?? 'tokyo-night',
      serverViewMode: _serverViewMode(json['serverViewMode']?.toString()),
      terminalFontSize: (json['terminalFontSize'] as num?)?.toDouble() ?? 14,
      terminalSecureKeyboard: json['terminalSecureKeyboard'] == true,
      language: json['language']?.toString() ?? 'zh-CN',
      aiEndpoint: json['aiEndpoint']?.toString() ?? 'https://api.openai.com/v1',
      aiModel: json['aiModel']?.toString() ?? 'gpt-4.1-mini',
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
        'terminalQuickKeys': terminalQuickKeys,
        'terminalCustomKeys':
            terminalCustomKeys.map((key) => key.toJson()).toList(),
      };

  static String _serverViewMode(String? value) =>
      const {'grid', 'list', 'tree'}.contains(value) ? value! : 'grid';
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
  });

  factory SyncConnection.fromJson(Map<String, dynamic> json) => SyncConnection(
        type: SyncProviderType.values.firstWhere(
          (value) => value.name == json['type'],
          orElse: () => SyncProviderType.webdav,
        ),
        endpoint: json['endpoint']?.toString() ?? '',
        username: json['username']?.toString(),
        secret: json['secret']?.toString(),
        resourceId: json['resourceId']?.toString(),
      );

  final SyncProviderType type;
  final String endpoint;
  final String? username;
  final String? secret;
  final String? resourceId;

  Map<String, dynamic> toJson() => {
        'type': type.name,
        'endpoint': endpoint,
        'username': username,
        'resourceId': resourceId,
      };
}
