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
  var _path = '/';
  var _loading = false;
  Object? _error;
  List<RemoteEntry> _entries = [];

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(sessionControllerProvider).active;
    if (session == null || !session.isSsh) {
      return const SafeArea(
        child: EmptyState(
          icon: Icons.folder_outlined,
          title: 'SFTP 尚未连接',
          subtitle: '先建立一个 SSH 会话，然后在这里浏览、上传和编辑远程文件。',
        ),
      );
    }
    if (_sessionId != session.host.id) {
      _sessionId = session.host.id;
      _service = SftpService(session);
      _path = '/';
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 6, 6),
            child: Row(
              children: [
                IconButton(
                  onPressed: _path == '/' ? null : _up,
                  icon: const Icon(Icons.arrow_upward),
                ),
                Expanded(
                  child: InkWell(
                    onTap: _choosePath,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surface,
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: Text(
                        _path,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  onPressed: _loading ? null : _load,
                  icon: const Icon(Icons.refresh),
                ),
                PopupMenuButton<String>(
                  onSelected: (value) =>
                      value == 'upload' ? _upload() : _mkdir(),
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'upload',
                      child: ListTile(
                        leading: Icon(Icons.upload_file),
                        title: Text('上传文件'),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'mkdir',
                      child: ListTile(
                        leading: Icon(Icons.create_new_folder),
                        title: Text('新建目录'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          if (_error != null)
            MaterialBanner(
              content: Text('SFTP 错误：$_error'),
              actions: [TextButton(onPressed: _load, child: const Text('重试'))],
            ),
          Expanded(
            child: _entries.isEmpty && !_loading
                ? const EmptyState(
                    icon: Icons.folder_open,
                    title: '目录为空',
                    subtitle: '可从右上角上传文件或新建目录。',
                  )
                : ListView.separated(
                    padding: const EdgeInsets.all(8),
                    itemCount: _entries.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, index) {
                      final entry = _entries[index];
                      return ListTile(
                        leading: Icon(
                          entry.isDirectory
                              ? Icons.folder
                              : _fileIcon(entry.name),
                          color: entry.isDirectory
                              ? const Color(0xfff59e0b)
                              : null,
                        ),
                        title: Text(
                          entry.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          entry.isDirectory ? '目录' : _formatBytes(entry.size),
                        ),
                        onTap: () => entry.isDirectory
                            ? _open(entry.path)
                            : _edit(entry),
                        trailing: PopupMenuButton<String>(
                          onSelected: (value) => _entryAction(value, entry),
                          itemBuilder: (_) => [
                            if (!entry.isDirectory)
                              const PopupMenuItem(
                                value: 'download',
                                child: Text('下载 / 分享'),
                              ),
                            const PopupMenuItem(
                              value: 'rename',
                              child: Text('重命名'),
                            ),
                            const PopupMenuItem(
                              value: 'delete',
                              child: Text('删除'),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _load() async {
    if (_service == null || _loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await _service!.list(_path);
      if (mounted) setState(() => _entries = entries);
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _open(String path) {
    setState(() => _path = path);
    _load();
  }

  void _up() {
    final parts = _path.split('/')..removeWhere((value) => value.isEmpty);
    if (parts.isNotEmpty) parts.removeLast();
    _open('/${parts.join('/')}');
  }

  Future<void> _choosePath() async {
    final controller = TextEditingController(text: _path);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('远程路径'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('打开'),
          ),
        ],
      ),
    );
    if (value?.startsWith('/') == true) _open(value!);
  }

  Future<void> _edit(RemoteEntry entry) async {
    if (entry.size > 1024 * 1024) {
      await _download(entry);
      return;
    }
    try {
      final controller = TextEditingController(
        text: await _service!.readText(entry.path),
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
      if (save == true) await _service!.writeText(entry.path, controller.text);
      await _load();
    } catch (error) {
      _message('$error');
    }
  }

  Future<void> _upload() async {
    final result = await FilePicker.platform.pickFiles(withData: true);
    if (result == null) return;
    final file = result.files.single;
    final bytes =
        file.bytes ??
        (file.path == null ? null : await File(file.path!).readAsBytes());
    if (bytes == null) return;
    try {
      await _service!.writeBytes(
        _join(_path, file.name),
        Uint8List.fromList(bytes),
      );
      await _load();
    } catch (error) {
      _message('$error');
    }
  }

  Future<void> _download(RemoteEntry entry) async {
    try {
      final bytes = await _service!.readBytes(entry.path);
      final directory = await getTemporaryDirectory();
      final file = File('${directory.path}/${entry.name}');
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
    if (name == null) return;
    try {
      await _service!.mkdir(_join(_path, name));
      await _load();
    } catch (error) {
      _message('$error');
    }
  }

  Future<void> _entryAction(String action, RemoteEntry entry) async {
    if (action == 'download') return _download(entry);
    if (action == 'rename') {
      final name = await _ask('重命名', '新名称', entry.name);
      if (name != null) await _service!.rename(entry.path, _join(_path, name));
    } else if (action == 'delete') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('删除 ${entry.name}？'),
          content: const Text('此操作将直接修改远程服务器，无法撤销。'),
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
      if (ok == true) await _service!.delete(entry);
    }
    await _load();
  }

  Future<String?> _ask(String title, String hint, [String initial = '']) async {
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
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(value)));
    }
  }

  String _join(String path, String name) =>
      path == '/' ? '/$name' : '$path/$name';
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
}
