enum SyncProviderType { webdav, githubGist }

class AppSettings {
  const AppSettings({
    this.themeMode = 'dark',
    this.uiThemeId = 'tokyo-night',
    this.serverViewMode = 'grid',
    this.terminalFontSize = 14,
    this.language = 'zh-CN',
    this.aiEndpoint = 'https://api.openai.com/v1',
    this.aiModel = 'gpt-4.1-mini',
    this.terminalQuickKeys = defaultTerminalQuickKeys,
  });

  factory AppSettings.fromJson(Map<String, dynamic> json) => AppSettings(
        themeMode: json['themeMode']?.toString() ?? 'dark',
        uiThemeId: json['uiThemeId']?.toString() ?? 'tokyo-night',
        serverViewMode: _serverViewMode(json['serverViewMode']?.toString()),
        terminalFontSize: (json['terminalFontSize'] as num?)?.toDouble() ?? 14,
        language: json['language']?.toString() ?? 'zh-CN',
        aiEndpoint:
            json['aiEndpoint']?.toString() ?? 'https://api.openai.com/v1',
        aiModel: json['aiModel']?.toString() ?? 'gpt-4.1-mini',
        terminalQuickKeys:
            (json['terminalQuickKeys'] as List? ?? defaultTerminalQuickKeys)
                .map((value) => value.toString())
                .where(defaultTerminalQuickKeys.contains)
                .toList(),
      );

  final String themeMode;
  final String uiThemeId;
  final String serverViewMode;
  final double terminalFontSize;
  final String language;
  final String aiEndpoint;
  final String aiModel;
  final List<String> terminalQuickKeys;

  AppSettings copyWith({
    String? themeMode,
    String? uiThemeId,
    String? serverViewMode,
    double? terminalFontSize,
    String? language,
    String? aiEndpoint,
    String? aiModel,
    List<String>? terminalQuickKeys,
  }) =>
      AppSettings(
        themeMode: themeMode ?? this.themeMode,
        uiThemeId: uiThemeId ?? this.uiThemeId,
        serverViewMode: serverViewMode ?? this.serverViewMode,
        terminalFontSize: terminalFontSize ?? this.terminalFontSize,
        language: language ?? this.language,
        aiEndpoint: aiEndpoint ?? this.aiEndpoint,
        aiModel: aiModel ?? this.aiModel,
        terminalQuickKeys: terminalQuickKeys ?? this.terminalQuickKeys,
      );

  Map<String, dynamic> toJson() => {
        'themeMode': themeMode,
        'uiThemeId': uiThemeId,
        'serverViewMode': serverViewMode,
        'terminalFontSize': terminalFontSize,
        'language': language,
        'aiEndpoint': aiEndpoint,
        'aiModel': aiModel,
        'terminalQuickKeys': terminalQuickKeys,
      };

  static String _serverViewMode(String? value) =>
      const {'grid', 'list', 'tree'}.contains(value) ? value! : 'grid';
}

const defaultTerminalQuickKeys = <String>[
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
