import '../../domain/models/vault.dart';

/// Same thresholds and group-config safeguard as desktop domain/syncGuards.ts.
/// Automatic sync must never approve a suspicious shrink on the user's behalf.
class SyncShrinkException implements Exception {
  const SyncShrinkException(this.collection, this.before, this.after);
  final String collection;
  final int before;
  final int after;
  @override
  String toString() => '检测到 $collection 从 $before 项减少到 $after 项，已阻止上传以保护数据。'
      '请确认这些删除是否符合预期，再手动确认同步。';
}

void assertSafeSyncShrink(
    VaultData outgoing, VaultData? base, VaultData? remote) {
  final reference = (base ?? remote)?.toJson();
  if (reference == null) return;
  final next = outgoing.toJson();
  const keys = [
    'hosts',
    'keys',
    'identities',
    'proxyProfiles',
    'snippets',
    'notes',
    'portForwardingRules',
    'groupConfigs',
    'customGroups',
    'snippetPackages',
    'noteGroups'
  ];
  int count(Map<String, dynamic> json, String key) =>
      (json[key] as List?)?.length ?? 0;
  for (final key in keys) {
    final before = count(reference, key), after = count(next, key);
    final lost = before - after;
    if (lost <= 0) continue;
    if (lost >= 10 ||
        (lost >= 3 && lost / before >= .5) ||
        (key == 'groupConfigs' &&
            after == 0 &&
            keys.any((other) => other != key && count(next, other) > 0))) {
      throw SyncShrinkException(key, before, after);
    }
  }
}
