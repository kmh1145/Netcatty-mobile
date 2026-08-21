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
  VaultController(this.repository) : super(const VaultState(loading: true));
  final VaultRepository repository;

  Future<void> load() async {
    state = VaultState(data: state.data, loading: true);
    try {
      state = VaultState(data: await repository.loadVault());
    } catch (error) {
      state = VaultState(data: state.data ?? VaultData.empty(), error: error);
    }
  }

  Future<void> replace(VaultData vault, {bool remote = false}) async {
    final next = remote
        ? vault
        : stampLocalVaultChanges(state.data ?? VaultData.empty(), vault);
    await repository.saveVault(next);
    state = VaultState(data: next);
  }

  Future<void> upsertHost(HostProfile host) async {
    final vault = state.data ?? VaultData.empty();
    final stamped = HostProfile({
      ...host.data,
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    });
    final hosts = [...vault.hosts];
    final index = hosts.indexWhere((value) => value.id == stamped.id);
    if (index == -1) {
      hosts.add(stamped);
    } else {
      hosts[index] = stamped;
    }
    await replace(vault.copyWith(hosts: hosts));
  }

  Future<void> deleteHost(String id) async {
    final vault = state.data ?? VaultData.empty();
    await replace(
      vault.copyWith(
        hosts: vault.hosts.where((value) => value.id != id).toList(),
      ),
    );
  }

  Future<void> markConnected(HostProfile host) => upsertHost(
        host.copyWith(lastConnectedAt: DateTime.now().millisecondsSinceEpoch),
      );
}
