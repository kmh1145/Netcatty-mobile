import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/models/vault.dart';
import '../infrastructure/http_client_provider.dart';
import '../infrastructure/storage/vault_repository.dart';
import '../infrastructure/sync/cloud_sync_service.dart';
import '../infrastructure/sync/vault_merge_service.dart';
import 'vault_controller.dart';

const autoSyncChangeDebounce = Duration(seconds: 10);
const autoSyncRemoteInterval = Duration(minutes: 5);

class AutoSyncState {
  const AutoSyncState({
    this.enabled = false,
    this.syncing = false,
    this.lastSyncedAt,
    this.lastError,
  });

  final bool enabled;
  final bool syncing;
  final DateTime? lastSyncedAt;
  final Object? lastError;

  AutoSyncState copyWith({
    bool? enabled,
    bool? syncing,
    DateTime? lastSyncedAt,
    Object? lastError,
    bool clearError = false,
  }) =>
      AutoSyncState(
        enabled: enabled ?? this.enabled,
        syncing: syncing ?? this.syncing,
        lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
        lastError: clearError ? null : lastError ?? this.lastError,
      );
}

typedef AutoSyncVaultLoader = Future<VaultData> Function();
typedef AutoSyncOperation = Future<CloudSyncResult> Function(VaultData vault);
typedef AutoSyncVaultApplier = Future<void> Function(VaultData vault);

final autoSyncControllerProvider =
    StateNotifierProvider<AutoSyncController, AutoSyncState>((ref) {
  final repository = ref.watch(vaultRepositoryProvider);
  final vaultController = ref.watch(vaultControllerProvider.notifier);
  final service = CloudSyncService(
    repository,
    client: ref.watch(httpClientProvider),
  );
  return AutoSyncController(
    localChanges: repository.localChanges,
    loadVault: vaultController.ready,
    synchronize: service.synchronize,
    synchronizeConfirmed: (vault) =>
        service.synchronize(vault, overrideShrink: true),
    applyVault: (vault) => vaultController.replace(vault, remote: true),
  );
});

/// Shared manual/automatic coordinator with a ten-second
/// debounce after local edits, a startup/foreground refresh, and a periodic
/// remote check while the app is alive. Every operation still goes through
/// [CloudSyncService.synchronize], preserving its version and conflict guards.
class AutoSyncController extends StateNotifier<AutoSyncState> {
  AutoSyncController({
    required Stream<VaultData> localChanges,
    required AutoSyncVaultLoader loadVault,
    required AutoSyncOperation synchronize,
    AutoSyncOperation? synchronizeConfirmed,
    required AutoSyncVaultApplier applyVault,
    this.changeDebounce = autoSyncChangeDebounce,
    this.remoteInterval = autoSyncRemoteInterval,
    this.retryDelays = const [
      Duration(seconds: 30),
      Duration(minutes: 1),
      Duration(minutes: 2),
      Duration(minutes: 4),
    ],
  })  : _loadVault = loadVault,
        _synchronize = synchronize,
        _synchronizeConfirmed = synchronizeConfirmed,
        _applyVault = applyVault,
        super(const AutoSyncState()) {
    _localChangesSubscription = localChanges.listen(_onLocalChange);
  }

  final AutoSyncVaultLoader _loadVault;
  final AutoSyncOperation _synchronize;
  final AutoSyncOperation? _synchronizeConfirmed;
  final AutoSyncVaultApplier _applyVault;
  final Duration changeDebounce;
  final Duration remoteInterval;
  final List<Duration> retryDelays;

  late final StreamSubscription<VaultData> _localChangesSubscription;
  Timer? _changeTimer;
  Timer? _periodicTimer;
  Timer? _retryTimer;
  VaultData? _pendingLocalVault;
  bool _running = false;
  Future<CloudSyncResult>? _activeSync;
  bool _queued = false;
  int _retryIndex = 0;

  void setEnabled(bool enabled) {
    if (state.enabled == enabled) return;
    state = state.copyWith(enabled: enabled, clearError: !enabled);
    if (!enabled) {
      _changeTimer?.cancel();
      _periodicTimer?.cancel();
      _retryTimer?.cancel();
      if (!_running) _pendingLocalVault = null;
      _queued = false;
      return;
    }
    _periodicTimer?.cancel();
    _periodicTimer = Timer.periodic(remoteInterval, (_) => _requestSync());
    _scheduleSync(Duration.zero);
  }

  /// Called when the app returns to the foreground. Mobile timers may be
  /// suspended in the background, so this explicit refresh closes that gap.
  void onAppResumed() {
    if (state.enabled) _scheduleSync(Duration.zero);
  }

  void _onLocalChange(VaultData vault) {
    if (!state.enabled && !_running) return;
    _pendingLocalVault = vault;
    if (!state.enabled) return;
    _changeTimer?.cancel();
    _changeTimer = Timer(changeDebounce, _requestSync);
  }

  void _scheduleSync(Duration delay) {
    _changeTimer?.cancel();
    _changeTimer = Timer(delay, _requestSync);
  }

  void _requestSync() {
    if (!state.enabled) return;
    if (_running) {
      _queued = true;
      return;
    }
    unawaited(synchronizeNow()
        .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
  }

  /// Manual sync joins an existing run; it never starts a competing writer.
  Future<CloudSyncResult> synchronizeNow({bool confirmShrink = false}) =>
      _activeSync ??= _runSync(confirmShrink: confirmShrink);

  Future<CloudSyncResult> _runSync({required bool confirmShrink}) async {
    _running = true;
    _queued = false;
    _retryTimer?.cancel();
    state = state.copyWith(syncing: true, clearError: true);
    try {
      // Always hydrate credentials, including when a metadata edit was queued.
      _pendingLocalVault = null;
      final local = VaultData.fromJson(
          jsonDecode(jsonEncode((await _loadVault()).toJson()))
              as Map<String, dynamic>);
      final result = await (confirmShrink
          ? _synchronizeConfirmed ?? _synchronize
          : _synchronize)(local);
      var merged = result.vault;
      var rebaseBase = local;

      // A user edit can finish while the network request is in flight. Merge
      // every such local snapshot back before publishing the downloaded state,
      // then run once more so that edit reaches the cloud as well.
      while (_pendingLocalVault != null) {
        final pending = _pendingLocalVault!;
        _pendingLocalVault = null;
        merged = mergeVaults(
          base: rebaseBase,
          local: pending,
          remote: merged,
          rebaseLocalEdits: true,
        );
        rebaseBase = pending;
        _queued = true;
      }
      merged = await _retainLatestDeviceLocalData(merged, rebaseBase);
      await result.validateBeforeApply?.call();
      await _applyVault(merged);
      while (_pendingLocalVault != null) {
        final pending = _pendingLocalVault!;
        _pendingLocalVault = null;
        merged = mergeVaults(
          base: rebaseBase,
          local: pending,
          remote: merged,
          rebaseLocalEdits: true,
        );
        rebaseBase = pending;
        merged = await _retainLatestDeviceLocalData(merged, rebaseBase);
        await result.validateBeforeApply?.call();
        await _applyVault(merged);
        _queued = true;
      }

      await result.acknowledge?.call();
      _retryIndex = 0;
      state = state.copyWith(
        syncing: false,
        lastSyncedAt: DateTime.now(),
        clearError: true,
      );
      final changed = !cloudSyncPayloadsEqual(merged, result.vault);
      return CloudSyncResult(
        vault: merged,
        message: changed ? '云端同步完成；同步期间的本地修改已保留，待下次同步' : result.message,
        versions: CloudSyncVersions(
          localVersion: result.versions.localVersion + (changed ? 1 : 0),
          cloudVersion: result.versions.cloudVersion,
          baseVersion: result.versions.baseVersion,
          hasLocalChanges: changed,
        ),
      );
    } on Object catch (error) {
      state = state.copyWith(syncing: false, lastError: error);
      _scheduleRetry();
      rethrow;
    } finally {
      _running = false;
      _activeSync = null;
      if (_queued && state.enabled) {
        _queued = false;
        _scheduleSync(changeDebounce);
      }
    }
  }

  Future<VaultData> _retainLatestDeviceLocalData(
    VaultData incoming,
    VaultData fallback,
  ) async {
    // `mergeVaults` deliberately operates only on cloud-synchronized fields.
    // Reattach trust records and connection telemetry from both the newest
    // queued edit and the live vault before replacing local state. This closes
    // the race where accepting a host key while a sync request is in flight
    // caused `knownHosts` (and `lastConnectedAt`) to disappear afterwards.
    final rebased = retainLocalDeviceData(incoming, fallback);
    final latest = await _loadVault();
    return retainLocalDeviceData(rebased, latest);
  }

  void _scheduleRetry() {
    if (!state.enabled || retryDelays.isEmpty) return;
    final index = _retryIndex.clamp(0, retryDelays.length - 1);
    _retryIndex = (_retryIndex + 1).clamp(0, retryDelays.length - 1);
    _retryTimer?.cancel();
    _retryTimer = Timer(retryDelays[index], _requestSync);
  }

  @override
  void dispose() {
    _changeTimer?.cancel();
    _periodicTimer?.cancel();
    _retryTimer?.cancel();
    unawaited(_localChangesSubscription.cancel());
    super.dispose();
  }
}
