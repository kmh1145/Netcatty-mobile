import 'host.dart';

class VaultData {
  VaultData({
    required this.hosts,
    required this.keys,
    required this.snippets,
    required this.customGroups,
    this.proxyProfiles = const [],
    Map<String, dynamic>? extras,
    Set<String>? presentFields,
  })  : extras = extras ?? <String, dynamic>{},
        _presentFields = presentFields ??
            const <String>{
              'hosts',
              'keys',
              'snippets',
              'customGroups',
              'proxyProfiles',
            };

  factory VaultData.empty() =>
      VaultData(hosts: [], keys: [], snippets: [], customGroups: []);

  factory VaultData.fromJson(Map<String, dynamic> json) {
    final extras = Map<String, dynamic>.from(json)
      ..remove('hosts')
      ..remove('keys')
      ..remove('snippets')
      ..remove('customGroups');
    extras.remove('proxyProfiles');
    return VaultData(
      hosts: (json['hosts'] as List? ?? const [])
          .whereType<Map>()
          .map((value) => HostProfile(Map<String, dynamic>.from(value)))
          .toList(),
      keys: (json['keys'] as List? ?? const [])
          .whereType<Map>()
          .map((value) => SshKeyProfile(Map<String, dynamic>.from(value)))
          .toList(),
      snippets: (json['snippets'] as List? ?? const [])
          .whereType<Map>()
          .map((value) => CommandSnippet(Map<String, dynamic>.from(value)))
          .toList(),
      customGroups: (json['customGroups'] as List? ?? const [])
          .map((value) => value.toString())
          .toList(),
      proxyProfiles: (json['proxyProfiles'] as List? ?? const [])
          .whereType<Map>()
          .map((value) => ProxyProfile(Map<String, dynamic>.from(value)))
          .toList(),
      extras: extras,
      presentFields: json.keys.toSet(),
    );
  }

  final List<HostProfile> hosts;
  final List<SshKeyProfile> keys;
  final List<CommandSnippet> snippets;
  final List<String> customGroups;
  final List<ProxyProfile> proxyProfiles;
  final Map<String, dynamic> extras;
  final Set<String> _presentFields;

  VaultData copyWith({
    List<HostProfile>? hosts,
    List<SshKeyProfile>? keys,
    List<CommandSnippet>? snippets,
    List<String>? customGroups,
    List<ProxyProfile>? proxyProfiles,
    Map<String, dynamic>? extras,
  }) =>
      VaultData(
        hosts: hosts ?? this.hosts,
        keys: keys ?? this.keys,
        snippets: snippets ?? this.snippets,
        customGroups: customGroups ?? this.customGroups,
        proxyProfiles: proxyProfiles ?? this.proxyProfiles,
        extras: extras ?? this.extras,
        presentFields: {
          ..._presentFields,
          if (proxyProfiles != null) 'proxyProfiles',
        },
      );

  Map<String, dynamic> toJson({bool legacySyncSnapshot = false}) {
    final result = Map<String, dynamic>.from(extras);
    if (legacySyncSnapshot) result.remove('convergentSync');
    result
      ..['hosts'] = hosts.map((value) => value.toJson()).toList()
      ..['keys'] = keys.map((value) => value.toJson()).toList()
      ..['snippets'] = snippets.map((value) => value.toJson()).toList()
      ..['customGroups'] = customGroups;
    if (_presentFields.contains('proxyProfiles') || proxyProfiles.isNotEmpty) {
      result['proxyProfiles'] =
          proxyProfiles.map((value) => value.toJson()).toList();
    }
    return result;
  }
}
