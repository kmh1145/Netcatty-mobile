import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:netcatty_mobile/presentation/localization/localized_widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../application/session_controller.dart';
import '../../application/home_navigation.dart';
import '../../application/settings_controller.dart';
import '../../infrastructure/ssh/android_document_tree_service.dart';
import '../../infrastructure/ssh/sftp_service.dart';
import '../widgets/custom_background.dart';

part 'sftp_screen_pane.dart';

class SftpScreen extends ConsumerStatefulWidget {
  const SftpScreen({super.key, this.localService});

  final Future<MountableFileTransferService>? localService;

  @override
  ConsumerState<SftpScreen> createState() => _SftpScreenState();
}

class _SftpScreenState extends ConsumerState<SftpScreen> {
  late final Future<MountableFileTransferService> _localService;
  final _remoteServices = <String, SftpService>{};
  var _leftKey = GlobalKey<_SftpPaneState>();
  var _rightKey = GlobalKey<_SftpPaneState>();
  String? _leftSourceId;
  String? _rightSourceId = 'local';
  SftpNavigationRequest? _scheduledNavigation;
  _TransferProgressSnapshot? _transfer;
  TransferCancellationToken? _transferCancellation;
  var _dualPane = true;

  @override
  void initState() {
    super.initState();
    _localService = widget.localService ??
        (Platform.isAndroid
            ? AndroidDocumentTreeTransferService.create()
            : LocalFileTransferService.create());
  }

  @override
  Widget build(BuildContext context) {
    final transparentHeader =
        hasGlobalCustomBackground(ref.watch(settingsControllerProvider));
    final sessions = ref
        .watch(sessionControllerProvider)
        .sessions
        .where((session) => session.isSsh && session.connected)
        .toList(growable: false);
    final navigationRequest = ref.watch(sftpNavigationRequestProvider);
    for (final session in sessions) {
      final existing = _remoteServices[session.id];
      if (existing == null || !identical(existing.session, session)) {
        _remoteServices[session.id] = SftpService(session);
      }
    }
    return FutureBuilder<MountableFileTransferService>(
      future: _localService,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const SafeArea(
            child: Center(child: CircularProgressIndicator()),
          );
        }
        final sources = <FileTransferService>[
          for (final session in sessions) _remoteServices[session.id]!,
          snapshot.data!,
        ];
        final sourceIds = sources.map((source) => source.id).toSet();
        final active = ref.watch(sessionControllerProvider).active;
        final preferred =
            active != null && sourceIds.contains('ssh:${active.id}')
                ? 'ssh:${active.id}'
                : sources.first.id;
        if (!sourceIds.contains(_leftSourceId)) _leftSourceId = preferred;
        if (!sourceIds.contains(_rightSourceId)) _rightSourceId = 'local';
        _scheduleNavigation(navigationRequest, sourceIds);
        final left = sources.firstWhere((source) => source.id == _leftSourceId);
        final right =
            sources.firstWhere((source) => source.id == _rightSourceId);
        return SafeArea(
          child: Column(
            children: [
              Material(
                key: const ValueKey('sftp-title-bar'),
                color: transparentHeader
                    ? Colors.transparent
                    : Theme.of(context).colorScheme.surface,
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
                      child: Row(
                        children: [
                          Icon(
                            Icons.folder_copy_outlined,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: LText(
                              'SFTP文件管理',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                          ),
                          if (sessions.isEmpty)
                            const Flexible(
                              child: LText(
                                '连接 SSH 后可选择服务器',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 11),
                              ),
                            ),
                          IconButton(
                            key: const ValueKey('sftp-pane-mode-toggle'),
                            tooltip: localized(
                              _dualPane ? '切换为单栏模式' : '切换为双栏模式',
                            ),
                            onPressed: _transfer == null
                                ? () => setState(() => _dualPane = !_dualPane)
                                : null,
                            visualDensity: VisualDensity.compact,
                            icon: Icon(
                              _dualPane
                                  ? Icons.view_column_outlined
                                  : Icons.view_stream_outlined,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_transfer != null)
                      _TransferProgressView(
                        progress: _transfer!,
                        onCancel: _transferCancellation?.cancel,
                      ),
                  ],
                ),
              ),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: KeyedSubtree(
                        key: const ValueKey('sftp-left-pane'),
                        child: _SftpPane(
                          key: _leftKey,
                          label: _dualPane ? '左侧' : '当前',
                          service: left,
                          sources: sources,
                          onSourceChanged: (id) => _changeSource(true, id),
                          onPhoneMountChanged: _phoneMountChanged,
                          onCopyToOther: _dualPane
                              ? (entry) =>
                                  _copy(entry, _leftKey, _rightKey, '右侧')
                              : null,
                        ),
                      ),
                    ),
                    if (_dualPane) ...[
                      VerticalDivider(
                        width: 1,
                        thickness: 1,
                        color: Theme.of(context).colorScheme.outlineVariant,
                      ),
                      Expanded(
                        child: KeyedSubtree(
                          key: const ValueKey('sftp-right-pane'),
                          child: _SftpPane(
                            key: _rightKey,
                            label: '右侧',
                            service: right,
                            sources: sources,
                            onSourceChanged: (id) => _changeSource(false, id),
                            onPhoneMountChanged: _phoneMountChanged,
                            onCopyToOther: (entry) =>
                                _copy(entry, _rightKey, _leftKey, '左侧'),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _scheduleNavigation(
    SftpNavigationRequest? request,
    Set<String> sourceIds,
  ) {
    if (request == null || identical(_scheduledNavigation, request)) return;
    final sourceId = 'ssh:${request.sessionId}';
    if (!sourceIds.contains(sourceId)) {
      _scheduledNavigation = request;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(sftpNavigationRequestProvider.notifier).state = null;
        _scheduledNavigation = null;
        _message('无法打开 Compose 配置：对应的 SSH 会话已断开');
      });
      return;
    }
    if (_leftSourceId != sourceId) {
      _leftSourceId = sourceId;
      _leftKey = GlobalKey<_SftpPaneState>();
    }
    _scheduledNavigation = request;
    final targetKey = _leftKey;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final pane = targetKey.currentState;
      if (pane == null) {
        _scheduledNavigation = null;
        setState(() {});
        return;
      }
      await pane.openRemoteFileLocation(request.filePath);
      if (!mounted) return;
      ref.read(sftpNavigationRequestProvider.notifier).state = null;
      _scheduledNavigation = null;
    });
  }

  void _changeSource(bool left, String id) {
    setState(() {
      if (left) {
        _leftSourceId = id;
        _leftKey = GlobalKey<_SftpPaneState>();
      } else {
        _rightSourceId = id;
        _rightKey = GlobalKey<_SftpPaneState>();
      }
    });
  }

  void _phoneMountChanged() {
    setState(() {});
    _leftKey.currentState?.resetAfterPhoneMount();
    _rightKey.currentState?.resetAfterPhoneMount();
  }

  Future<void> _copy(
    RemoteEntry entry,
    GlobalKey<_SftpPaneState> sourceKey,
    GlobalKey<_SftpPaneState> targetKey,
    String targetLabel,
  ) async {
    final source = sourceKey.currentState;
    final target = targetKey.currentState;
    if (source == null || target == null || _transfer != null) return;
    final cancellation = TransferCancellationToken();
    _transferCancellation = cancellation;
    final tracker = _TransferProgressTracker(
      title: '${entry.name} → ${target.service.displayName}',
      totalBytes: entry.isDirectory ? null : entry.size,
      onChanged: (progress) {
        if (mounted) setState(() => _transfer = progress);
      },
    )..start(preparing: entry.isDirectory);
    try {
      if (entry.isDirectory) {
        tracker.setTotalBytes(await calculateTransferSize(
          source.service,
          entry,
          cancellationToken: cancellation,
        ));
      }
      await transferEntry(
        source.service,
        entry,
        target.service,
        target.path,
        onProgress: tracker.update,
        cancellationToken: cancellation,
      );
      tracker.finish();
      await target.refresh();
      _message(
        '已将 ${entry.name} 从 ${source.service.displayName} 传输到'
        '$targetLabel ${target.service.displayName}',
      );
    } on TransferCancelledException {
      _message('传输已取消，可再次传输以继续');
    } catch (error) {
      _message('传输失败：$error');
    } finally {
      _transferCancellation = null;
      if (mounted) setState(() => _transfer = null);
    }
  }

  void _message(String value) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: LText(value)));
    }
  }
}
