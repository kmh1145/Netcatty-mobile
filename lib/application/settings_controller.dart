import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/models/settings.dart';
import '../infrastructure/storage/vault_repository.dart';

final settingsControllerProvider =
    StateNotifierProvider<SettingsController, AppSettings>((ref) {
  final controller = SettingsController(ref.watch(vaultRepositoryProvider));
  unawaited(controller.load());
  return controller;
});

class SettingsController extends StateNotifier<AppSettings> {
  SettingsController(this.repository) : super(const AppSettings());
  final VaultRepository repository;

  Future<void> load() async => state = await repository.loadSettings();

  Future<void> update(AppSettings value) async {
    final previous = state;
    state = value;
    try {
      await repository.saveSettings(value);
    } catch (_) {
      state = previous;
      rethrow;
    }
  }

  Future<void> updateTerminalSecureKeyboard(bool enabled) async {
    final persisted = await repository.loadSettings();
    await update(persisted.copyWith(terminalSecureKeyboard: enabled));
  }
}
