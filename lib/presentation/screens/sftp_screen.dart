import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../application/session_controller.dart';
import '../../infrastructure/ssh/sftp_service.dart';
import '../widgets/empty_state.dart';

class SftpScreen extends ConsumerStatefulWidget {
  const SftpScreen({super.key});

  @override
  ConsumerState<SftpScreen> createState() => _SftpScreenState();
}

class _SftpScreenState extends ConsumerState<SftpScreen> {
  SftpService? _service;
  String? _sessionId;
  var _leftKey = GlobalKey<_SftpPaneState>();
  var _rightKey = GlobalKey<_SftpPaneState>();
  var _copying = false;

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionControllerProvider).active;
    if (session == null || !session.isSsh) {
      return const SafeArea(
        child: EmptyState(
          icon: Icons.folder_outlined,
          title: 'SFTP 尚未连接',
          subtitle: '先建立一个 SSH 会话，然后在这里使用双栏文件管理器。',
        ),
      );
    }
    if (_sessionId != session.id) {
      _sessionId = session.id;
      _service = SftpService(session);
      _leftKey = GlobalKey<_SftpPaneState>();
      _rightKey = GlobalKey<_SftpPaneState>();
    }
    final service = _service!;
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
                  Expanded(
                    child: Text(
                      '${session.host.label} · 双栏 SFTP',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (_copying) ...[
                    const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 6),
                    const Text('复制中', style: TextStyle(fontSize: 12)),
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
                    service: service,
                    onCopyToOther: (entry) => _copy(entry, _rightKey, '右侧'),
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
                    service: service,
                    onCopyToOther: (entry) => _copy(entry, _leftKey, '左侧'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _copy(
    RemoteEntry entry,
    GlobalKey<_SftpPaneState> targetKey,
    String targetLabel,
  ) async {
    final target = targetKey.currentState;
    if (target == null || _copying) return;
    setState(() => _copying = true);
    try {
      await _service!.copyEntry(entry, target.path);
      await target.refresh();
      _message('已复制 ${entry.name} 到$targetLabel ${target.path}');
    } catch (error) {
      _message('复制失败：$error');
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
    required this.onCopyToOther,
  });

  final String label;
  final SftpService service;
  final ValueChanged<RemoteEntry> onCopyToOther;

  @override
  State<_SftpPane> createState() => _SftpPaneState();
}

class _SftpPaneState extends State<_SftpPane> {
  var path = '/';
  var _loading = false;
  Object? _error;
  List<RemoteEntry> _entries = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => refresh());
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 260;
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 7, 6, 3),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(7),
                      ),
                      child: Text(
                        widget.label,
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 5),
                    Expanded(
                      child: InkWell(
                        borderRadius: BorderRadius.circular(7),
                        onTap: _choosePath,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 6,
                          ),
                          child: Text(
                            path,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              SizedBox(
                height: 38,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _toolbar(
                        Icons.arrow_upward, '上级', path == '/' ? null : _up),
                    _toolbar(Icons.refresh, '刷新', _loading ? null : refresh),
                    _toolbar(Icons.upload_file, '上传', _upload),
                    _toolbar(Icons.create_new_folder_outlined, '新建', _mkdir),
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
                    ? const Center(
                        child: Text('目录为空', style: TextStyle(fontSize: 12)),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        itemCount: _entries.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (context, index) {
                          final entry = _entries[index];
                          return ListTile(
                            dense: true,
                            visualDensity: compact
                                ? const VisualDensity(
                                    horizontal: -4, vertical: -3)
                                : VisualDensity.compact,
                            contentPadding:
                                const EdgeInsets.only(left: 5, right: 0),
                            leading: Icon(
                              entry.isDirectory
                                  ? Icons.folder
                                  : _fileIcon(entry.name),
                              size: compact ? 20 : 23,
                              color: entry.isDirectory
                                  ? const Color(0xfff59e0b)
                                  : null,
                            ),
                            title: Text(
                              entry.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: compact ? 12 : 14),
                            ),
                            subtitle: compact
                                ? null
                                : Text(entry.isDirectory
                                    ? '目录'
                                    : _formatBytes(entry.size)),
                            onTap: () => entry.isDirectory
                                ? _open(entry.path)
                                : _edit(entry),
                            trailing: PopupMenuButton<String>(
                              tooltip: '文件操作',
                              padding: EdgeInsets.zero,
                              onSelected: (value) => _entryAction(value, entry),
                              itemBuilder: (_) => [
                                const PopupMenuItem(
                                  value: 'copy',
                                  child: ListTile(
                                    leading: Icon(Icons.compare_arrows),
                                    title: Text('复制到另一栏'),
                                  ),
                                ),
                                if (!entry.isDirectory)
                                  const PopupMenuItem(
                                    value: 'download',
                                    child: ListTile(
                                      leading: Icon(Icons.download_outlined),
                                      title: Text('下载 / 分享'),
                                    ),
                                  ),
                                const PopupMenuItem(
                                  value: 'rename',
                                  child: ListTile(
                                    leading:
                                        Icon(Icons.drive_file_rename_outline),
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
                        },
                      ),
              ),
            ],
          );
        },
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
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await widget.service.list(path);
      if (mounted) setState(() => _entries = entries);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _open(String value) {
    setState(() => path = value);
    refresh();
  }

  void _up() {
    final parts = path.split('/')..removeWhere((value) => value.isEmpty);
    if (parts.isNotEmpty) parts.removeLast();
    _open('/${parts.join('/')}');
  }

  Future<void> _choosePath() async {
    final controller = TextEditingController(text: path);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${widget.label}远程路径'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('打开'),
          ),
        ],
      ),
    );
    if (value?.startsWith('/') == true) _open(value!);
  }

  Future<void> _edit(RemoteEntry entry) async {
    if (entry.size > 1024 * 1024) return _download(entry);
    try {
      final controller = TextEditingController(
        text: await widget.service.readText(entry.path),
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
        await widget.service.writeText(entry.path, controller.text);
      }
      await refresh();
    } catch (error) {
      _message('$error');
    }
  }

  Future<void> _upload() async {
    final result = await FilePicker.platform.pickFiles(withData: true);
    if (result == null) return;
    final file = result.files.single;
    final bytes = file.bytes ??
        (file.path == null ? null : await File(file.path!).readAsBytes());
    if (bytes == null) return;
    try {
      await widget.service.writeBytes(
        joinRemotePath(path, file.name),
        Uint8List.fromList(bytes),
      );
      await refresh();
    } catch (error) {
      _message('$error');
    }
  }

  Future<void> _download(RemoteEntry entry) async {
    try {
      final bytes = await widget.service.readBytes(entry.path);
      final directory = await getTemporaryDirectory();
      final file = File(
        '${directory.path}/${DateTime.now().millisecondsSinceEpoch}-${entry.name}',
      );
      await file.writeAsBytes(bytes, flush: true);
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
      await widget.service.mkdir(joinRemotePath(path, name));
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
    if (action == 'download') return _download(entry);
    try {
      if (action == 'rename') {
        final name = await _ask('重命名', '新名称', entry.name);
        if (name != null && name.isNotEmpty && name != entry.name) {
          await widget.service.rename(entry.path, joinRemotePath(path, name));
        }
      } else if (action == 'delete') {
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text('删除 ${entry.name}？'),
            content: const Text('此操作会直接修改远程服务器，无法撤销。'),
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
        if (ok == true) await widget.service.delete(entry);
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
