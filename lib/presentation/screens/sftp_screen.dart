import 'dart:io';
import '../../infrastructure/ssh/remote_archive.dart';
import '../../infrastructure/ssh/file_selection.dart';
import '../../infrastructure/ssh/zip_selection.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import '../widgets/sftp_editor.dart';

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
  final _clipboard = ValueNotifier<FileSelection?>(null);

  @override
  void dispose() {
    _transferCancellation?.cancel();
    _clipboard.dispose();
    super.dispose();
  }

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
                          clipboard: _clipboard,
                          sharedTransferBusy: _transfer != null,
                          onPaste: _paste,
                          onSourceChanged: (id) => _changeSource(true, id),
                          onPhoneMountChanged: _phoneMountChanged,
                          onOpenInTerminal: left.isLocal
                              ? null
                              : (path) => _openInTerminal(left, path),
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
                            clipboard: _clipboard,
                            sharedTransferBusy: _transfer != null,
                            onPaste: _paste,
                            onSourceChanged: (id) => _changeSource(false, id),
                            onPhoneMountChanged: _phoneMountChanged,
                            onOpenInTerminal: right.isLocal
                                ? null
                                : (path) => _openInTerminal(right, path),
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

  void _openInTerminal(FileTransferService service, String path) {
    if (service is! SftpService) return;
    final controller = ref.read(sessionControllerProvider.notifier);
    final sessions = ref.read(sessionControllerProvider).sessions;
    final index = sessions.indexWhere(
      (session) => session.id == service.session.id,
    );
    if (index < 0 || !service.session.connected) {
      _message('无法打开终端：对应的 SSH 会话已断开');
      return;
    }
    try {
      controller.activate(index);
      controller.sendToSession(
        service.session.id,
        'cd ${quoteSftpTerminalPath(path)}',
        enter: true,
      );
      ref.read(homeTabProvider.notifier).state = 1;
    } catch (error) {
      _message('无法在终端中打开目录：$error');
    }
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
    await _paste(
        FileSelection(source.service, [entry]), target.service, target.path,
        resumePhoneCopy: true);
  }

  Future<void> _paste(
      FileSelection selection, FileTransferService target, String path,
      {bool resumePhoneCopy = false}) async {
    if (_transfer != null) return;
    if (selection.move) {
      final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
                  title: const LText('移动所选文件？'),
                  content: Column(mainAxisSize: MainAxisSize.min, children: [
                    Text(
                        '${selection.source.displayName} → ${target.displayName}\n${target.displayPath(path)}'),
                    const LText('传输并校验成功后删除源文件'),
                  ]),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const LText('取消')),
                    FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const LText('移动'))
                  ]));
      if (confirmed != true || !mounted) return;
    }
    if (_transfer != null) return;
    final token = TransferCancellationToken();
    _transferCancellation = token;
    final tracker = _TransferProgressTracker(
        title: '${selection.entries.length} → ${target.displayName}',
        totalBytes: null,
        onChanged: (value) {
          if (mounted) setState(() => _transfer = value);
        })
      ..start(preparing: true);
    final remaining = selection.entries.toList();
    selection.source.activeOperations++;
    target.activeOperations++;
    try {
      tracker.setStatus('正在检查服务器传输条件…');
      final plan = await prepareTransferRoute(selection, target, token,
          targetDirectory: path);
      if (!mounted) return;
      if (plan.relayReason != null) {
        final accepted = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
                  title: const LText('改用手机中转？'),
                  content: SingleChildScrollView(
                      child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const LText(
                          '服务器直传不可用。直传需要服务器之间可达，并已配置密钥认证和可信主机指纹。手机中转会使用手机流量。'),
                      const SizedBox(height: 12),
                      Text(plan.relayReason!,
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  )),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context, false),
                        child: const LText('取消')),
                    FilledButton(
                        onPressed: () => Navigator.pop(context, true),
                        child: const LText('使用手机中转')),
                  ],
                ));
        if (accepted != true || !mounted) return;
      }
      token.throwIfCancelled();
      if (plan.route == TransferRoute.phoneRelay) {
        tracker.setStatus('正在计算文件大小…');
        var total = 0;
        for (final entry in selection.entries) {
          total += await calculateTransferSize(selection.source, entry,
              cancellationToken: token);
        }
        tracker.setTotalBytes(total);
        tracker.setStatus('通过手机传输中…');
      }
      await transferSelection(selection, target, path,
          route: plan.route,
          resumePhoneCopy: resumePhoneCopy,
          cancellationToken: token,
          onStatus: tracker.setStatus,
          onProgress: tracker.update, onCompleted: (entry) {
        remaining.remove(entry);
        tracker.setStatus(
            '已完成 ${selection.entries.length - remaining.length}/${selection.entries.length}');
        if (mounted &&
            identical(_clipboard.value, selection) &&
            selection.move &&
            remaining.isEmpty) {
          _clipboard.value = null;
        }
      });
      tracker.finish();
      _message('批量操作完成');
    } on TransferCancelledException {
      _message('传输已取消');
    } catch (e) {
      _message('批量操作未完成：$e');
    } finally {
      selection.source.activeOperations--;
      target.activeOperations--;
      if (mounted) {
        if (selection.move &&
            remaining.isNotEmpty &&
            identical(_clipboard.value, selection)) {
          _clipboard.value =
              FileSelection(selection.source, remaining, move: true);
        }
        _transferCancellation = null;
        setState(() => _transfer = null);
        await _leftKey.currentState?.refresh();
        await _rightKey.currentState?.refresh();
      }
    }
  }

  void _message(String value) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: LText(value)));
    }
  }
}
