import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/models/host.dart';
import '../domain/models/vault.dart';
import '../domain/models/vault_sync_state.dart';
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
    final next = remote
        ? vault
        : stampLocalVaultChanges(state.data ?? VaultData.empty(), vault);
    await repository.saveVault(next, remote: remote);
    state = VaultState(data: next);
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
    final next = stampLocalVaultChanges(
      previous.data ?? repository.loadVaultPreview() ?? VaultData.empty(),
      vault,
    );
    state = VaultState(data: next, loading: previous.loading);
    try {
      await repository.saveVaultMetadata(next);
    } on Object catch (error) {
      state = VaultState(
        data: previous.data,
        loading: previous.loading,
        error: error,
      );
      rethrow;
    }
  }

  Future<void> markConnected(HostProfile host) => upsertHost(
        host.copyWith(lastConnectedAt: DateTime.now().millisecondsSinceEpoch),
      );
}
