import 'host.dart';

class VaultData {
  VaultData({
    required this.hosts,
    required this.keys,
    required this.snippets,
    required this.customGroups,
    Map<String, dynamic>? extras,
  }) : extras = extras ?? <String, dynamic>{};

  factory VaultData.empty() =>
      VaultData(hosts: [], keys: [], snippets: [], customGroups: []);

  factory VaultData.fromJson(Map<String, dynamic> json) {
    final extras = Map<String, dynamic>.from(json)
      ..remove('hosts')
      ..remove('keys')
      ..remove('snippets')
      ..remove('customGroups');
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
      extras: extras,
    );
  }

  final List<HostProfile> hosts;
  final List<SshKeyProfile> keys;
  final List<CommandSnippet> snippets;
  final List<String> customGroups;
  final Map<String, dynamic> extras;

  VaultData copyWith({
    List<HostProfile>? hosts,
    List<SshKeyProfile>? keys,
    List<CommandSnippet>? snippets,
    List<String>? customGroups,
    Map<String, dynamic>? extras,
  }) =>
      VaultData(
        hosts: hosts ?? this.hosts,
        keys: keys ?? this.keys,
        snippets: snippets ?? this.snippets,
        customGroups: customGroups ?? this.customGroups,
        extras: extras ?? this.extras,
      );

  Map<String, dynamic> toJson({bool legacySyncSnapshot = false}) {
    final result = Map<String, dynamic>.from(extras);
    if (legacySyncSnapshot) result.remove('convergentSync');
    return result
      ..['hosts'] = hosts.map((value) => value.toJson()).toList()
      ..['keys'] = keys.map((value) => value.toJson()).toList()
      ..['snippets'] = snippets.map((value) => value.toJson()).toList()
      ..['customGroups'] = customGroups;
  }
}
