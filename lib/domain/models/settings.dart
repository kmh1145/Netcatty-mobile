enum SyncProviderType { webdav, githubGist }

class AppSettings {
  const AppSettings({
    this.themeMode = 'dark',
    this.terminalFontSize = 14,
    this.language = 'zh-CN',
    this.aiEndpoint = 'https://api.openai.com/v1',
    this.aiModel = 'gpt-4.1-mini',
  });

  factory AppSettings.fromJson(Map<String, dynamic> json) => AppSettings(
    themeMode: json['themeMode']?.toString() ?? 'dark',
    terminalFontSize: (json['terminalFontSize'] as num?)?.toDouble() ?? 14,
    language: json['language']?.toString() ?? 'zh-CN',
    aiEndpoint: json['aiEndpoint']?.toString() ?? 'https://api.openai.com/v1',
    aiModel: json['aiModel']?.toString() ?? 'gpt-4.1-mini',
  );

  final String themeMode;
  final double terminalFontSize;
  final String language;
  final String aiEndpoint;
  final String aiModel;

  AppSettings copyWith({
    String? themeMode,
    double? terminalFontSize,
    String? language,
    String? aiEndpoint,
    String? aiModel,
  }) => AppSettings(
    themeMode: themeMode ?? this.themeMode,
    terminalFontSize: terminalFontSize ?? this.terminalFontSize,
    language: language ?? this.language,
    aiEndpoint: aiEndpoint ?? this.aiEndpoint,
    aiModel: aiModel ?? this.aiModel,
  );

  Map<String, dynamic> toJson() => {
    'themeMode': themeMode,
    'terminalFontSize': terminalFontSize,
    'language': language,
    'aiEndpoint': aiEndpoint,
    'aiModel': aiModel,
  };
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
