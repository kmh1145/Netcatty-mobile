import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/models/host.dart';
import '../domain/models/vault.dart';
import '../infrastructure/storage/vault_repository.dart';

class VaultState {
  const VaultState({this.data, this.loading = false, this.error});
  final VaultData? data;
  final bool loading;
  final Object? error;
}

final vaultControllerProvider =
    StateNotifierProvider<VaultController, VaultState>((ref) {
  final controller = VaultController(ref.watch(vaultRepositoryProvider));
  unawaited(controller.load());
  return controller;
});

class VaultController extends StateNotifier<VaultState> {
  VaultController(this.repository)
      : super(
          VaultState(
            data: repository.loadVaultPreview(),
            loading: true,
          ),
        );
  final VaultRepository repository;
  Future<VaultData>? _activeLoad;

  Future<void> load() async {
    state = VaultState(data: state.data, loading: true);
    final operation = repository.loadVault();
    _activeLoad = operation;
    try {
      state = VaultState(data: await operation);
    } catch (error) {
      state = VaultState(data: state.data ?? VaultData.empty(), error: error);
    } finally {
      if (identical(_activeLoad, operation)) _activeLoad = null;
    }
  }

  /// Waits for platform-backed secrets to be available before an operation
  /// that connects, edits, exports, or saves the vault.
  Future<VaultData> ready() async {
    final active = _activeLoad;
    if (active != null) return active;
    final data = state.data;
    if (!state.loading && state.error == null && data != null) return data;
    final loaded = await repository.loadVault();
    state = VaultState(data: loaded);
    return loaded;
  }

  Future<void> replace(VaultData vault, {bool remote = false}) async {
    await repository.saveVault(vault, remote: remote);
    state = VaultState(data: vault);
  }

  Future<void> upsertHost(HostProfile host) async {
    final vault = await ready();
    final stamped = HostProfile({
      ...host.data,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    });
    final hosts = [...vault.hosts];
    final index = hosts.indexWhere((value) => value.id == stamped.id);
    final previousGroup = index == -1 ? null : _normalizedGroup(hosts[index]);
    if (index == -1) {
      hosts.add(stamped);
    } else {
      hosts[index] = stamped;
    }
    await replace(
      vault.copyWith(
        hosts: hosts,
        customGroups: _updatedGroups(
          vault.customGroups,
          hosts,
          previousGroup: previousGroup,
          currentGroup: _normalizedGroup(stamped),
        ),
      ),
    );
  }

  Future<void> deleteHost(String id) async {
    final vault = await ready();
    final removedHost = vault.hosts.cast<HostProfile?>().firstWhere(
          (value) => value?.id == id,
          orElse: () => null,
        );
    final hosts = vault.hosts.where((value) => value.id != id).toList();
    await replace(
      vault.copyWith(
        hosts: hosts,
        customGroups: _updatedGroups(
          vault.customGroups,
          hosts,
          previousGroup:
              removedHost == null ? null : _normalizedGroup(removedHost),
        ),
      ),
    );
  }

  String? _normalizedGroup(HostProfile host) {
    final value = host.group?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  List<String> _updatedGroups(
    List<String> current,
    List<HostProfile> hosts, {
    String? previousGroup,
    String? currentGroup,
  }) {
    final groups = current
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList(growable: true);
    if (currentGroup != null && !groups.contains(currentGroup)) {
      groups.add(currentGroup);
    }
    if (previousGroup != null &&
        previousGroup != currentGroup &&
        !hosts.any((host) => _normalizedGroup(host) == previousGroup)) {
      groups.removeWhere((group) => group == previousGroup);
    }
    return groups.toSet().toList(growable: false);
  }

  Future<void> upsertSnippet(CommandSnippet snippet) async {
    final vault =
        state.data ?? repository.loadVaultPreview() ?? VaultData.empty();
    final snippets = [...vault.snippets];
    final index = snippets.indexWhere((value) => value.id == snippet.id);
    if (index < 0) {
      snippets.add(snippet);
    } else {
      snippets[index] = snippet;
    }
    await _replaceMetadata(vault.copyWith(snippets: snippets));
  }

  Future<void> deleteSnippet(String id) async {
    final vault =
        state.data ?? repository.loadVaultPreview() ?? VaultData.empty();
    await _replaceMetadata(
      vault.copyWith(
        snippets: vault.snippets
            .where((value) => value.id != id)
            .toList(growable: false),
      ),
    );
  }

  Future<void> _replaceMetadata(VaultData vault) async {
    final previous = state;
    state = VaultState(data: vault, loading: previous.loading);
    try {
      await repository.saveVaultMetadata(vault);
    } on Object catch (error) {
      state = VaultState(
        data: previous.data,
        loading: previous.loading,
        error: error,
      );
      rethrow;
    }
  }

  Future<void> markConnected(HostProfile host) async {
    final vault = await ready();
    final connected = host.copyWith(
      lastConnectedAt: DateTime.now().millisecondsSinceEpoch,
    );
    final hosts = vault.hosts
        .map((value) => value.id == connected.id ? connected : value)
        .toList(growable: false);
    final next = vault.copyWith(hosts: hosts);
    // Connection recency is device-local telemetry in desktop Netcatty. Do
    // not schedule a cloud write just because a terminal was opened.
    await repository.saveVault(next, remote: true);
    state = VaultState(data: next);
  }
}
