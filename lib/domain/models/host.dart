import 'dart:convert';

enum HostProtocol { ssh, telnet, mosh }

enum HostAuthMethod { auto, password, key }

/// A lossless view over Netcatty's desktop Host JSON model.
///
/// Unknown desktop/plugin fields remain in [data] and survive every save/sync.
class HostProfile {
  HostProfile(Map<String, dynamic> value)
    : data = Map<String, dynamic>.from(value);

  factory HostProfile.create({
    required String id,
    required String label,
    required String hostname,
    required String username,
    int port = 22,
    HostProtocol protocol = HostProtocol.ssh,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return HostProfile({
      'id': id,
      'label': label,
      'hostname': hostname,
      'username': username,
      'port': port,
      'protocol': protocol.name,
      'tags': <String>[],
      'os': 'linux',
      'createdAt': now,
      'authMethod': 'auto',
      'savePassword': true,
    });
  }

  final Map<String, dynamic> data;

  String get id => data['id']?.toString() ?? '';
  String get label => data['label']?.toString() ?? hostname;
  String get hostname => data['hostname']?.toString() ?? '';
  String get username => data['username']?.toString() ?? '';
  int get port => (data['port'] as num?)?.toInt() ?? 22;
  String? get group => data['group']?.toString();
  String? get password => data['password']?.toString();
  String? get identityFileId => data['identityFileId']?.toString();
  String? get startupCommand => data['startupCommand']?.toString();
  bool get pinned => data['pinned'] == true;
  int get lastConnectedAt => (data['lastConnectedAt'] as num?)?.toInt() ?? 0;
  List<String> get tags => (data['tags'] as List? ?? const [])
      .map((value) => value.toString())
      .toList(growable: false);
  HostProtocol get protocol => HostProtocol.values.firstWhere(
    (value) => value.name == data['protocol'],
    orElse: () => HostProtocol.ssh,
  );

  HostProfile copyWith({
    String? label,
    String? hostname,
    String? username,
    int? port,
    String? group,
    String? password,
    String? identityFileId,
    List<String>? tags,
    HostProtocol? protocol,
    bool? pinned,
    int? lastConnectedAt,
  }) {
    final next = Map<String, dynamic>.from(data);
    void set(String key, Object? value) {
      if (value == null) {
        next.remove(key);
      } else {
        next[key] = value;
      }
    }

    if (label != null) set('label', label);
    if (hostname != null) set('hostname', hostname);
    if (username != null) set('username', username);
    if (port != null) set('port', port);
    if (group != null) set('group', group.isEmpty ? null : group);
    if (password != null) set('password', password.isEmpty ? null : password);
    if (identityFileId != null) {
      set('identityFileId', identityFileId.isEmpty ? null : identityFileId);
    }
    if (tags != null) set('tags', tags);
    if (protocol != null) set('protocol', protocol.name);
    if (pinned != null) set('pinned', pinned);
    if (lastConnectedAt != null) set('lastConnectedAt', lastConnectedAt);
    return HostProfile(next);
  }

  Map<String, dynamic> toJson() => Map<String, dynamic>.from(data);

  @override
  String toString() => jsonEncode(data);
}

class SshKeyProfile {
  SshKeyProfile(Map<String, dynamic> value)
    : data = Map<String, dynamic>.from(value);

  final Map<String, dynamic> data;
  String get id => data['id']?.toString() ?? '';
  String get label => data['label']?.toString() ?? 'SSH key';
  String get privateKey => data['privateKey']?.toString() ?? '';
  String? get passphrase => data['passphrase']?.toString();
  Map<String, dynamic> toJson() => Map<String, dynamic>.from(data);
}

class CommandSnippet {
  CommandSnippet(Map<String, dynamic> value)
    : data = Map<String, dynamic>.from(value);

  final Map<String, dynamic> data;
  String get id => data['id']?.toString() ?? '';
  String get label => data['label']?.toString() ?? 'Snippet';
  String get command => data['command']?.toString() ?? '';
  bool get autoRun => data['noAutoRun'] != true;
  Map<String, dynamic> toJson() => Map<String, dynamic>.from(data);
}
