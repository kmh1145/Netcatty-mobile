import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../application/session_controller.dart';
import '../../infrastructure/ssh/android_document_tree_service.dart';
import '../../infrastructure/ssh/sftp_service.dart';

class SftpScreen extends ConsumerStatefulWidget {
  const SftpScreen({super.key});

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
  var _copying = false;

  @override
  void initState() {
    super.initState();
    _localService = Platform.isAndroid
        ? AndroidDocumentTreeTransferService.create()
        : LocalFileTransferService.create();
  }

  @override
  Widget build(BuildContext context) {
    final sessions = ref
        .watch(sessionControllerProvider)
        .sessions
        .where((session) => session.isSsh && session.connected)
        .toList(growable: false);
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
        final left = sources.firstWhere((source) => source.id == _leftSourceId);
        final right =
            sources.firstWhere((source) => source.id == _rightSourceId);
        return SafeArea(
          child: Column(
            children: [
              Material(
                color: Theme.of(context).colorScheme.surface,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
                  child: Row(
                    children: [
                      Icon(
                        Icons.compare_arrows,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          '双栏文件传输',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      if (sessions.isEmpty)
                        const Text(
                          '连接 SSH 后可选择服务器',
                          style: TextStyle(fontSize: 11),
                        ),
                      if (_copying) ...[
                        const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: 6),
                        const Text('传输中', style: TextStyle(fontSize: 12)),
                      ],
                    ],
                  ),
                ),
              ),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _SftpPane(
                        key: _leftKey,
                        label: '左侧',
                        service: left,
                        sources: sources,
                        onSourceChanged: (id) => _changeSource(true, id),
                        onPhoneMountChanged: _phoneMountChanged,
                        onCopyToOther: (entry) =>
                            _copy(entry, _leftKey, _rightKey, '右侧'),
                      ),
                    ),
                    VerticalDivider(
                      width: 1,
                      thickness: 1,
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                    Expanded(
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
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
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
    if (source == null || target == null || _copying) return;
    setState(() => _copying = true);
    try {
      await transferEntry(
        source.service,
        entry,
        target.service,
        target.path,
      );
      await target.refresh();
      _message(
        '已将 ${entry.name} 从 ${source.service.displayName} 传输到'
        '$targetLabel ${target.service.displayName}',
      );
    } catch (error) {
      _message('传输失败：$error');
    } finally {
      if (mounted) setState(() => _copying = false);
    }
  }

  void _message(String value) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(value)));
    }
  }
}

class _SftpPane extends StatefulWidget {
  const _SftpPane({
    super.key,
    required this.label,
    required this.service,
    required this.sources,
    required this.onSourceChanged,
    required this.onPhoneMountChanged,
    required this.onCopyToOther,
  });

  final String label;
  final FileTransferService service;
  final List<FileTransferService> sources;
  final ValueChanged<String> onSourceChanged;
  final VoidCallback onPhoneMountChanged;
  final ValueChanged<RemoteEntry> onCopyToOther;

  @override
  State<_SftpPane> createState() => _SftpPaneState();
}

class _SftpPaneState extends State<_SftpPane> {
  late String path = widget.service.rootPath;
  var _loading = false;
  Object? _error;
  List<RemoteEntry> _entries = const [];

  FileTransferService get service => widget.service;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => refresh());
  }

  @override
  void didUpdateWidget(covariant _SftpPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.service, widget.service)) {
      path = widget.service.rootPath;
      _entries = const [];
      WidgetsBinding.instance.addPostFrameCallback((_) => refresh());
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 260;
          final mountable = service is MountableFileTransferService
              ? service as MountableFileTransferService
              : null;
          final localReady = mountable?.isMounted ?? true;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(5, 6, 3, 2),
                child: Row(
                  children: [
                    Expanded(
                      child: PopupMenuButton<String>(
                        tooltip: '切换 ${widget.label} 文件来源',
                        initialValue: service.id,
                        onSelected: widget.onSourceChanged,
                        itemBuilder: (_) => [
                          for (final source in widget.sources)
                            PopupMenuItem(
                              value: source.id,
                              child: ListTile(
                                leading: Icon(source.isLocal
                                    ? Icons.phone_android
                                    : Icons.dns_outlined),
                                title: Text(source.displayName),
                                subtitle: Text(
                                  source is MountableFileTransferService
                                      ? source.usesAppDocuments
                                          ? '文件 App：我的 iPhone/iPad/Netcatty'
                                          : source.isMounted
                                              ? '已挂载：${source.mountedDirectoryName}'
                                              : '点文件夹按钮选择手机目录'
                                      : '已连接 SSH',
                                ),
                              ),
                            ),
                        ],
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color:
                                Theme.of(context).colorScheme.primaryContainer,
                            borderRadius: BorderRadius.circular(7),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                service.isLocal
                                    ? Icons.phone_android
                                    : Icons.dns_outlined,
                                size: 16,
                              ),
                              const SizedBox(width: 5),
                              Expanded(
                                child: Text(
                                  service.displayName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              const Icon(Icons.arrow_drop_down, size: 18),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 3),
                    Text(widget.label, style: const TextStyle(fontSize: 10)),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    service.displayPath(path),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                    ),
                  ),
                ),
              ),
              SizedBox(
                height: 38,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _toolbar(Icons.arrow_upward, '上级',
                        !localReady || path == service.rootPath ? null : _up),
                    _toolbar(Icons.refresh, '刷新',
                        _loading || !localReady ? null : refresh),
                    if (mountable != null && !mountable.usesAppDocuments)
                      _toolbar(
                        Icons.folder_open_outlined,
                        mountable.isMounted ? '更换挂载目录' : '挂载手机目录',
                        _mountPhoneDirectory,
                      ),
                    _toolbar(
                      service.isLocal ? Icons.add_to_photos : Icons.upload_file,
                      service.isLocal ? '导入其他手机文件' : '上传文件',
                      localReady ? _importFile : null,
                    ),
                    _toolbar(Icons.create_new_folder_outlined, '新建',
                        localReady ? _mkdir : null),
                  ],
                ),
              ),
              if (_loading) const LinearProgressIndicator(minHeight: 2),
              if (_error != null)
                InkWell(
                  onTap: refresh,
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Text(
                      '加载失败，点按重试\n$_error',
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ),
              Expanded(
                child: _entries.isEmpty && !_loading
                    ? Center(
                        child: Text(
                          mountable != null && !mountable.isMounted
                              ? '尚未挂载手机目录\n点上方文件夹按钮选择目录'
                              : mountable?.usesAppDocuments == true
                                  ? 'Netcatty 文件夹为空\n可从服务器下载或导入文件'
                                  : service.isLocal
                                      ? '挂载目录为空\n可直接上传或导入文件'
                                      : '目录为空',
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 11),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        itemCount: _entries.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, index) =>
                            _entryTile(_entries[index], compact),
                      ),
              ),
            ],
          );
        },
      );

  Widget _entryTile(RemoteEntry entry, bool compact) => ListTile(
        dense: true,
        visualDensity: compact
            ? const VisualDensity(horizontal: -4, vertical: -3)
            : VisualDensity.compact,
        contentPadding: const EdgeInsets.only(left: 5, right: 0),
        leading: Icon(
          entry.isDirectory ? Icons.folder : _fileIcon(entry.name),
          size: compact ? 20 : 23,
          color: entry.isDirectory ? const Color(0xfff59e0b) : null,
        ),
        title: Text(
          entry.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: compact ? 12 : 14),
        ),
        subtitle: compact
            ? null
            : Text(entry.isDirectory ? '目录' : _formatBytes(entry.size)),
        onTap: () => entry.isDirectory ? _open(entry.path) : _edit(entry),
        trailing: PopupMenuButton<String>(
          tooltip: '文件操作',
          padding: EdgeInsets.zero,
          onSelected: (value) => _entryAction(value, entry),
          itemBuilder: (_) => [
            const PopupMenuItem(
              value: 'copy',
              child: ListTile(
                leading: Icon(Icons.compare_arrows),
                title: Text('传输到另一栏'),
              ),
            ),
            if (!entry.isDirectory)
              const PopupMenuItem(
                value: 'share',
                child: ListTile(
                  leading: Icon(Icons.ios_share_outlined),
                  title: Text('下载 / 分享'),
                ),
              ),
            const PopupMenuItem(
              value: 'rename',
              child: ListTile(
                leading: Icon(Icons.drive_file_rename_outline),
                title: Text('重命名'),
              ),
            ),
            const PopupMenuItem(
              value: 'delete',
              child: ListTile(
                leading: Icon(Icons.delete_outline),
                title: Text('删除'),
              ),
            ),
          ],
        ),
      );

  Widget _toolbar(IconData icon, String tooltip, VoidCallback? onPressed) =>
      IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        visualDensity: VisualDensity.compact,
        iconSize: 20,
        icon: Icon(icon),
      );

  Future<void> refresh() async {
    if (_loading || !mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await service.list(path);
      if (mounted) setState(() => _entries = entries);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void resetAfterPhoneMount() {
    if (!service.isLocal) return;
    setState(() {
      path = service.rootPath;
      _entries = const [];
      _error = null;
    });
    refresh();
  }

  Future<void> _mountPhoneDirectory() async {
    final mountable = service is MountableFileTransferService
        ? service as MountableFileTransferService
        : null;
    if (mountable == null) return;
    try {
      if (!await mountable.mount()) return;
      widget.onPhoneMountChanged();
      _message('已挂载手机目录：${mountable.mountedDirectoryName ?? '已选目录'}');
    } catch (error) {
      _message('挂载目录失败：$error');
    }
  }

  void _open(String value) {
    setState(() => path = value);
    refresh();
  }

  void _up() => _open(service.parentPath(path));

  Future<void> _edit(RemoteEntry entry) async {
    if (entry.size > 1024 * 1024) return _share(entry);
    try {
      final controller = TextEditingController(
        text: await service.readText(entry.path),
      );
      if (!mounted) return;
      final save = await showDialog<bool>(
        context: context,
        builder: (context) => Dialog.fullscreen(
          child: Scaffold(
            appBar: AppBar(
              leading: IconButton(
                onPressed: () => Navigator.pop(context, false),
                icon: const Icon(Icons.close),
              ),
              title: Text(entry.name),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('保存'),
                ),
              ],
            ),
            body: TextField(
              controller: controller,
              expands: true,
              maxLines: null,
              minLines: null,
              style: const TextStyle(fontFamily: 'monospace'),
              decoration: const InputDecoration(
                filled: false,
                border: InputBorder.none,
                contentPadding: EdgeInsets.all(16),
              ),
            ),
          ),
        ),
      );
      if (save == true) {
        await service.writeText(entry.path, controller.text);
      }
      await refresh();
    } catch (error) {
      _message('$error');
    }
  }

  Future<void> _importFile() async {
    final result = await FilePicker.platform.pickFiles(withReadStream: true);
    if (result == null) return;
    final file = result.files.single;
    Stream<Uint8List>? stream;
    if (file.readStream != null) {
      stream = file.readStream!.map(Uint8List.fromList);
    } else if (file.path != null) {
      stream = File(file.path!).openRead().map(Uint8List.fromList);
    } else if (file.bytes != null) {
      stream = Stream.value(file.bytes!);
    }
    if (stream == null) return;
    try {
      await service.writeStream(service.joinPath(path, file.name), stream);
      await refresh();
      _message(service.isLocal ? '已导入到挂载目录' : '上传完成');
    } catch (error) {
      _message('$error');
    }
  }

  Future<void> _share(RemoteEntry entry) async {
    try {
      late final File file;
      if (service is LocalFileTransferService) {
        file = File(entry.path);
      } else {
        final directory = await getTemporaryDirectory();
        file = File(
          '${directory.path}/${DateTime.now().millisecondsSinceEpoch}-${entry.name}',
        );
        final sink = file.openWrite(mode: FileMode.writeOnly);
        try {
          await sink.addStream(service.readStream(entry.path));
        } finally {
          await sink.close();
        }
      }
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], title: entry.name),
      );
    } catch (error) {
      _message('$error');
    }
  }

  Future<void> _mkdir() async {
    final name = await _ask('新建目录', '目录名');
    if (name == null || name.isEmpty) return;
    try {
      await service.mkdir(service.joinPath(path, name));
      await refresh();
    } catch (error) {
      _message('$error');
    }
  }

  Future<void> _entryAction(String action, RemoteEntry entry) async {
    if (action == 'copy') {
      widget.onCopyToOther(entry);
      return;
    }
    if (action == 'share') return _share(entry);
    try {
      if (action == 'rename') {
        final name = await _ask('重命名', '新名称', entry.name);
        if (name != null && name.isNotEmpty && name != entry.name) {
          await service.rename(entry.path, service.joinPath(path, name));
        }
      } else if (action == 'delete') {
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('删除 ${entry.name}？'),
            content: Text(service.isLocal
                ? '文件将从当前挂载的手机目录删除，无法撤销。'
                : '此操作会直接修改远程服务器，无法撤销。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('删除'),
              ),
            ],
          ),
        );
        if (ok == true) await service.delete(entry);
      }
      await refresh();
    } catch (error) {
      _message('$error');
    }
  }

  Future<String?> _ask(String title, String hint, [String initial = '']) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: hint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  void _message(String value) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(value)));
    }
  }
}

IconData _fileIcon(String name) =>
    RegExp(r'\.(png|jpg|jpeg|gif|webp)$', caseSensitive: false).hasMatch(name)
        ? Icons.image_outlined
        : RegExp(
            r'\.(dart|js|ts|py|sh|json|ya?ml|conf)$',
            caseSensitive: false,
          ).hasMatch(name)
            ? Icons.code
            : Icons.description_outlined;

String _formatBytes(int value) => value < 1024
    ? '$value B'
    : value < 1024 * 1024
        ? '${(value / 1024).toStringAsFixed(1)} KB'
        : '${(value / 1024 / 1024).toStringAsFixed(1)} MB';
