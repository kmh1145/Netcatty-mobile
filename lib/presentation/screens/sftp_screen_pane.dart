part of 'sftp_screen.dart';

class _SftpPane extends StatefulWidget {
  const _SftpPane({
    super.key,
    required this.label,
    required this.service,
    required this.sources,
    required this.onSourceChanged,
    required this.onPhoneMountChanged,
    required this.clipboard,
    required this.sharedTransferBusy,
    required this.onPaste,
    this.onCopyToOther,
    this.onOpenInTerminal,
  });

  final String label;
  final FileTransferService service;
  final List<FileTransferService> sources;
  final ValueChanged<String> onSourceChanged;
  final VoidCallback onPhoneMountChanged;
  final ValueNotifier<FileSelection?> clipboard;
  final bool sharedTransferBusy;
  final Future<void> Function(FileSelection, FileTransferService, String)
      onPaste;
  final ValueChanged<RemoteEntry>? onCopyToOther;
  final ValueChanged<String>? onOpenInTerminal;

  @override
  State<_SftpPane> createState() => _SftpPaneState();
}

class _SftpPaneState extends State<_SftpPane> {
  late String path = widget.service.rootPath;
  var _loading = false;
  var _listGeneration = 0;
  Object? _error;
  List<RemoteEntry> _entries = const [];
  String? _highlightedEntryPath;
  _TransferProgressSnapshot? _transfer;
  TransferCancellationToken? _transferCancellation;
  bool _extracting = false;
  String _archiveStatus = '正在服务器上解压…';
  bool _selecting = false;
  final _selected = <String>{};
  List<RemoteEntry> get _selection =>
      _entries.where((e) => _selected.contains(e.path)).toList();

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
      _selected.clear();
      _selecting = false;
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
                        tooltip: localized('切换 ${widget.label} 文件来源'),
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
                                title: LText(source.displayName),
                                subtitle: LText(
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
                                child: LText(
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
                    LText(widget.label, style: const TextStyle(fontSize: 10)),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: LText(
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
                    Expanded(
                      child: _toolbar(
                        Icons.arrow_upward,
                        '上级',
                        !localReady || path == service.rootPath ? null : _up,
                      ),
                    ),
                    Expanded(
                      child: _toolbar(
                        Icons.refresh,
                        '刷新',
                        _loading || !localReady ? null : refresh,
                      ),
                    ),
                    if (widget.onOpenInTerminal != null)
                      Expanded(
                        child: _toolbar(
                          Icons.terminal_outlined,
                          '在终端中打开当前目录',
                          _loading
                              ? null
                              : () => widget.onOpenInTerminal!(path),
                        ),
                      ),
                    if (mountable != null && !mountable.usesAppDocuments)
                      Expanded(
                        child: _toolbar(
                          Icons.folder_open_outlined,
                          mountable.isMounted ? '更换挂载目录' : '挂载手机目录',
                          _mountPhoneDirectory,
                        ),
                      ),
                    Expanded(
                      child: _toolbar(
                        service.isLocal
                            ? Icons.add_to_photos
                            : Icons.upload_file,
                        service.isLocal ? '导入其他手机文件' : '上传文件',
                        localReady && _transfer == null ? _importFile : null,
                      ),
                    ),
                    Expanded(
                      child: _toolbar(
                        Icons.create_new_folder_outlined,
                        '新建',
                        localReady ? _mkdir : null,
                      ),
                    ),
                  ],
                ),
              ),
              if (_loading) const LinearProgressIndicator(minHeight: 2),
              ValueListenableBuilder<FileSelection?>(
                  valueListenable: widget.clipboard,
                  builder: (context, clipboard, _) => Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 2,
                          children: [
                            if (_selecting) ...[
                              TextButton(
                                  onPressed: () => setState(() {
                                        if (_selected.length ==
                                            _entries.length) {
                                          _selected.clear();
                                        } else {
                                          _selected.addAll(
                                              _entries.map((e) => e.path));
                                        }
                                      }),
                                  child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const LText('全选'),
                                        Text(' (${_selected.length})'),
                                      ])),
                              IconButton(
                                  tooltip: localized('复制'),
                                  onPressed: _selected.isEmpty
                                      ? null
                                      : () => _copySelection(false),
                                  icon: const Icon(Icons.copy)),
                              IconButton(
                                  tooltip: localized('剪切'),
                                  onPressed: _selected.isEmpty
                                      ? null
                                      : () => _copySelection(true),
                                  icon: const Icon(Icons.cut)),
                              if (service.isLocal ||
                                  service.supportsArchiveExtraction)
                                IconButton(
                                    tooltip: localized('压缩'),
                                    onPressed: _selected.isEmpty || _extracting
                                        ? null
                                        : _compressSelection,
                                    icon:
                                        const Icon(Icons.folder_zip_outlined)),
                              IconButton(
                                  tooltip: localized('删除所选文件'),
                                  onPressed: _selected.isEmpty
                                      ? null
                                      : _deleteSelection,
                                  icon: const Icon(Icons.delete_outline)),
                              IconButton(
                                  tooltip: localized('取消多选'),
                                  onPressed: () => setState(() {
                                        _selecting = false;
                                        _selected.clear();
                                      }),
                                  icon: const Icon(Icons.close)),
                            ],
                            if (clipboard != null) ...[
                              TextButton.icon(
                                  onPressed: () =>
                                      widget.onPaste(clipboard, service, path),
                                  icon: const Icon(Icons.paste),
                                  label: LText(
                                      '${localized('粘贴')} (${clipboard.entries.length})')),
                              IconButton(
                                  tooltip: localized('清空文件剪贴板'),
                                  onPressed: () =>
                                      widget.clipboard.value = null,
                                  icon: const Icon(Icons.clear)),
                            ],
                          ])),
              if (_extracting) const LinearProgressIndicator(minHeight: 2),
              if (_extracting) LText(_archiveStatus),
              if (_transfer != null)
                _TransferProgressView(
                  progress: _transfer!,
                  compact: true,
                  onCancel: _transferCancellation?.cancel,
                ),
              if (_error != null)
                InkWell(
                  onTap: refresh,
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: LText(
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
                        child: LText(
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
        selected: _selected.contains(entry.path) ||
            entry.path == _highlightedEntryPath,
        selectedTileColor: Theme.of(context)
            .colorScheme
            .primaryContainer
            .withValues(alpha: .4),
        dense: true,
        visualDensity: compact
            ? const VisualDensity(horizontal: -4, vertical: -3)
            : VisualDensity.compact,
        contentPadding: const EdgeInsets.only(left: 5, right: 0),
        leading: _selecting
            ? Checkbox(
                value: _selected.contains(entry.path),
                onChanged: (_) => _toggleEntry(entry))
            : Icon(
                entry.isDirectory ? Icons.folder : _fileIcon(entry.name),
                size: compact ? 20 : 23,
                color: entry.isDirectory ? const Color(0xfff59e0b) : null,
              ),
        title: LText(
          entry.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: compact ? 12 : 14),
        ),
        subtitle: compact
            ? null
            : LText(entry.isDirectory ? '目录' : _formatBytes(entry.size)),
        onLongPress: () => _toggleEntry(entry),
        onTap: () => _selecting
            ? _toggleEntry(entry)
            : entry.isDirectory
                ? _open(entry.path)
                : _edit(entry),
        trailing: PopupMenuButton<String>(
          tooltip: localized('文件操作'),
          padding: EdgeInsets.zero,
          onSelected: (value) => _entryAction(value, entry),
          itemBuilder: (_) => [
            const PopupMenuItem(
                value: 'select',
                child: ListTile(
                    leading: Icon(Icons.checklist), title: LText('多选'))),
            if (!service.isLocal &&
                service.supportsArchiveExtraction &&
                !entry.isDirectory &&
                RemoteArchive.extension(entry.name) != null)
              PopupMenuItem(
                value: 'extract',
                enabled: !_extracting,
                child: const ListTile(
                  leading: Icon(Icons.unarchive_outlined),
                  title: LText('解压缩'),
                ),
              ),
            if (widget.onCopyToOther != null)
              const PopupMenuItem(
                value: 'copy',
                child: ListTile(
                  leading: Icon(Icons.compare_arrows),
                  title: LText('传输到另一栏'),
                ),
              ),
            if (!entry.isDirectory)
              const PopupMenuItem(
                value: 'share',
                child: ListTile(
                  leading: Icon(Icons.ios_share_outlined),
                  title: LText('下载 / 分享'),
                ),
              ),
            const PopupMenuItem(
              value: 'copy-path',
              child: ListTile(
                leading: Icon(Icons.content_copy_outlined),
                title: LText('复制文件路径'),
              ),
            ),
            if (service.supportsUnixPermissions)
              const PopupMenuItem(
                value: 'permissions',
                child: ListTile(
                  leading: Icon(Icons.admin_panel_settings_outlined),
                  title: LText('修改文件权限'),
                ),
              ),
            const PopupMenuItem(
              value: 'rename',
              child: ListTile(
                leading: Icon(Icons.drive_file_rename_outline),
                title: LText('重命名'),
              ),
            ),
            const PopupMenuItem(
              value: 'delete',
              child: ListTile(
                leading: Icon(Icons.delete_outline),
                title: LText('删除'),
              ),
            ),
          ],
        ),
      );

  Widget _toolbar(IconData icon, String tooltip, VoidCallback? onPressed) =>
      IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
        visualDensity: VisualDensity.compact,
        iconSize: 20,
        icon: Icon(icon),
      );

  Future<void> refresh() async {
    if (!mounted) return;
    final generation = ++_listGeneration;
    final source = service;
    final directory = path;
    bool current() =>
        mounted &&
        generation == _listGeneration &&
        identical(source, service) &&
        directory == path;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final entries = await source.list(directory);
      if (current()) {
        setState(() {
          _entries = entries;
          _selected.removeWhere((p) => !entries.any((e) => e.path == p));
        });
      }
    } catch (error) {
      if (current()) setState(() => _error = error);
    } finally {
      if (current()) setState(() => _loading = false);
    }
  }

  void resetAfterPhoneMount() {
    if (!service.isLocal) return;
    setState(() {
      path = service.rootPath;
      _entries = const [];
      _error = null;
      _highlightedEntryPath = null;
    });
    refresh();
  }

  Future<void> _mountPhoneDirectory() async {
    if (widget.sharedTransferBusy || _transfer != null || _extracting) return;
    final mountable = service is MountableFileTransferService
        ? service as MountableFileTransferService
        : null;
    if (mountable == null || mountable.activeOperations > 0) return;
    try {
      if (!await mountable.mount()) return;
      widget.clipboard.value = null;
      _selected.clear();
      _selecting = false;
      widget.onPhoneMountChanged();
      _message('已挂载手机目录：${mountable.mountedDirectoryName ?? '已选目录'}');
    } catch (error) {
      _message('挂载目录失败：$error');
    }
  }

  void _open(String value) {
    setState(() {
      _selected.clear();
      _selecting = false;
      path = value;
      _entries = const [];
      _highlightedEntryPath = null;
    });
    refresh();
  }

  Future<void> openRemoteFileLocation(String filePath) async {
    if (service.isLocal) return;
    setState(() {
      _selected.clear();
      _selecting = false;
      path = service.parentPath(filePath);
      _entries = const [];
      _error = null;
      _highlightedEntryPath = filePath;
    });
    await refresh();
  }

  void _up() => _open(service.parentPath(path));

  Future<void> _edit(RemoteEntry entry) async {
    if (entry.size > 1024 * 1024) return _share(entry);
    try {
      final source = service;
      final content = await source.readText(entry.path);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => Dialog.fullscreen(
          child: SftpEditor(
              name: entry.name,
              content: content,
              onSave: (value) => source.writeText(entry.path, value)),
        ),
      );
      await refresh();
    } catch (error) {
      _message('$error');
    }
  }

  Future<void> _importFile() async {
    if (_transfer != null) return;
    final result = await FilePicker.platform.pickFiles(withReadStream: true);
    if (result == null) return;
    final file = result.files.single;
    Stream<Uint8List>? stream;
    if (file.readStream != null) {
      stream = asUint8ListStream(file.readStream!);
    } else if (file.path != null) {
      stream = asUint8ListStream(File(file.path!).openRead());
    } else if (file.bytes != null) {
      stream = Stream.value(file.bytes!);
    }
    if (stream == null) return;
    final tracker = _beginTransfer(
      '${service.isLocal ? '导入' : '上传'} ${file.name}',
      file.size,
    );
    try {
      await writeStreamAtomically(
        service,
        service.joinPath(path, file.name),
        stream,
        totalBytes: file.size,
        onProgress: tracker.update,
        cancellationToken: _transferCancellation,
      );
      tracker.finish();
      await refresh();
      _message(service.isLocal ? '已导入到挂载目录' : '上传完成');
    } on TransferCancelledException {
      _message('传输已取消，可再次上传以继续');
    } catch (error) {
      _message('$error');
    } finally {
      _endTransfer();
    }
  }

  Future<void> _share(RemoteEntry entry) async {
    if (_transfer != null) return;
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
        final tracker = _beginTransfer('下载 ${entry.name}', entry.size);
        try {
          await sink.addStream(
            cancelOnDemand(
              service.readStream(entry.path, onProgress: tracker.update),
              _transferCancellation,
            ),
          );
          tracker.finish();
        } finally {
          await sink.close();
          _endTransfer();
        }
      }
      await SharePlus.instance.share(
        ShareParams(files: [XFile(file.path)], title: entry.name),
      );
    } on TransferCancelledException {
      _message('下载已取消');
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
    if (action == 'select') {
      _toggleEntry(entry);
      return;
    }
    if (action == 'extract') {
      final source = service;
      if (source.isLocal || !source.supportsArchiveExtraction || _extracting) {
        return;
      }
      final destination = await _ask(
          '解压缩',
          '新建解压目录的绝对路径（须不存在）',
          source.joinPath(source.parentPath(entry.path),
              RemoteArchive.directoryName(entry.name)));
      if (destination == null || destination.isEmpty || !mounted) return;
      setState(() {
        _extracting = true;
        _archiveStatus = '正在服务器上解压…';
      });
      try {
        await source.extractArchive(entry.path, destination);
        _message('解压完成');
      } catch (error) {
        _message('解压失败：$error');
      } finally {
        if (mounted) {
          setState(() => _extracting = false);
          if (identical(service, source)) await refresh();
        }
      }
      return;
    }
    if (action == 'copy') {
      widget.onCopyToOther?.call(entry);
      return;
    }
    if (action == 'share') return _share(entry);
    if (action == 'copy-path') {
      await Clipboard.setData(ClipboardData(text: entry.path));
      _message('文件路径已复制');
      return;
    }
    try {
      if (action == 'permissions') {
        final mode = await _askPermissions(entry);
        if (mode == null) return;
        await service.setPermissions(entry.path, mode);
        _message('权限已修改为 ${formatUnixPermissions(mode)}');
      } else if (action == 'rename') {
        final name = await _ask('重命名', '新名称', entry.name);
        if (name != null && name.isNotEmpty && name != entry.name) {
          await service.rename(entry.path, service.joinPath(path, name));
        }
      } else if (action == 'delete') {
        final ok = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: LText('删除 ${entry.name}？'),
            content: LText(service.isLocal
                ? '文件将从当前挂载的手机目录删除，无法撤销。'
                : '此操作会直接修改远程服务器，无法撤销。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const LText('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const LText('删除'),
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

  void _toggleEntry(RemoteEntry entry) => setState(() {
        _selecting = true;
        if (!_selected.remove(entry.path)) _selected.add(entry.path);
      });

  void _copySelection(bool move) {
    widget.clipboard.value = FileSelection(service, _selection, move: move);
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  Future<void> _compressSelection() async {
    final source = service;
    final entries = _selection;
    final directory = path;
    final name = await _ask(
        '压缩',
        source.isLocal ? '压缩文件名（.zip）' : '压缩文件名（.tar.gz 或 .zip）',
        source.isLocal ? 'archive.zip' : 'archive.tar.gz');
    if (name == null || name.isEmpty || !mounted) return;
    if (name.contains('/') || name.contains('\\') || name.contains('\u0000')) {
      _message('文件名不能包含路径分隔符');
      return;
    }
    setState(() {
      _extracting = true;
      _archiveStatus = '正在压缩…';
    });
    source.activeOperations++;
    try {
      if (source.isLocal) {
        await zipSelection(source, entries, source.joinPath(directory, name));
      } else {
        await source.compressEntries(entries, source.joinPath(directory, name));
      }
      _message('压缩完成');
      if (identical(source, service)) await refresh();
    } catch (e) {
      _message('压缩失败：$e');
    } finally {
      source.activeOperations--;
      if (mounted) setState(() => _extracting = false);
    }
  }

  Future<void> _deleteSelection() async {
    final source = service;
    final entries = _selection;
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: const LText('删除所选文件'),
                content: LText('${entries.length}\n${localized('此操作无法撤销。')}'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const LText('取消')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const LText('删除'))
                ]));
    if (confirmed != true) return;
    source.activeOperations++;
    try {
      for (final entry in entries) {
        await source.delete(entry);
      }
    } catch (e) {
      _message('$e');
    } finally {
      source.activeOperations--;
      if (mounted && identical(source, service)) await refresh();
    }
  }

  Future<String?> _ask(String title, String hint, [String initial = '']) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: LText(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: LInputDecoration(hintText: hint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const LText('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const LText('确定'),
          ),
        ],
      ),
    );
  }

  Future<int?> _askPermissions(RemoteEntry entry) {
    final formKey = GlobalKey<FormState>();
    final controller = TextEditingController(
      text: formatUnixPermissions(entry.unixMode) ??
          (entry.isDirectory ? '755' : '644'),
    );
    return showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: LText('修改 ${entry.name} 的权限'),
        content: Form(
          key: formKey,
          child: TextFormField(
            key: const ValueKey('sftp-permissions-input'),
            controller: controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            maxLength: 4,
            decoration: LInputDecoration(
              labelText: 'Unix 权限',
              hintText: '例如 644 或 0755',
              helperText: '依次表示所有者、用户组和其他用户的读写执行权限',
            ),
            validator: (value) => parseUnixPermissions(value ?? '') == null
                ? localized('请输入 3 或 4 位八进制权限（0-7）')
                : null,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const LText('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() != true) return;
              Navigator.pop(
                context,
                parseUnixPermissions(controller.text),
              );
            },
            child: const LText('应用'),
          ),
        ],
      ),
    );
  }

  void _message(String value) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: LText(value)));
    }
  }

  _TransferProgressTracker _beginTransfer(String title, int totalBytes) {
    _transferCancellation = TransferCancellationToken();
    final tracker = _TransferProgressTracker(
      title: title,
      totalBytes: totalBytes,
      onChanged: (progress) {
        if (mounted) setState(() => _transfer = progress);
      },
    )..start();
    return tracker;
  }

  void _endTransfer() {
    _transferCancellation = null;
    if (mounted) setState(() => _transfer = null);
  }
}

class _TransferProgressSnapshot {
  const _TransferProgressSnapshot({
    required this.title,
    required this.transferredBytes,
    required this.totalBytes,
    required this.bytesPerSecond,
    required this.preparing,
  });

  final String title;
  final int transferredBytes;
  final int? totalBytes;
  final double bytesPerSecond;
  final bool preparing;

  double? get value {
    final total = totalBytes;
    if (preparing || total == null || total <= 0) return null;
    return (transferredBytes / total).clamp(0.0, 1.0).toDouble();
  }
}

class _TransferProgressTracker {
  _TransferProgressTracker({
    required this.title,
    required int? totalBytes,
    required ValueChanged<_TransferProgressSnapshot> onChanged,
  })  : _totalBytes = totalBytes,
        _onChanged = onChanged;

  static const _minimumUpdateInterval = Duration(milliseconds: 200);
  static const _minimumByteDelta = 256 * 1024;

  final String title;
  final ValueChanged<_TransferProgressSnapshot> _onChanged;
  final Stopwatch _watch = Stopwatch();
  int? _totalBytes;
  int _transferredBytes = 0;
  int _lastEmittedBytes = 0;
  Duration _lastEmittedAt = Duration.zero;
  double _bytesPerSecond = 0;
  bool _preparing = false;

  void start({bool preparing = false}) {
    _preparing = preparing;
    _watch.start();
    _emit(0, force: true);
  }

  void setTotalBytes(int value) {
    _totalBytes = value;
    _preparing = false;
    _emit(_transferredBytes, force: true);
  }

  void update(int value) {
    _preparing = false;
    _emit(value);
  }

  void finish() {
    _emit(_totalBytes ?? _transferredBytes, force: true);
  }

  void _emit(int value, {bool force = false}) {
    final now = _watch.elapsed;
    final elapsedSinceUpdate = now - _lastEmittedAt;
    final byteDelta = value - _lastEmittedBytes;
    final complete = _totalBytes != null && value >= _totalBytes!;
    if (!force &&
        !complete &&
        elapsedSinceUpdate < _minimumUpdateInterval &&
        byteDelta < _minimumByteDelta) {
      return;
    }

    final micros = elapsedSinceUpdate.inMicroseconds;
    if (micros > 0 && byteDelta >= 0) {
      final instantSpeed = byteDelta * Duration.microsecondsPerSecond / micros;
      _bytesPerSecond = _bytesPerSecond == 0
          ? instantSpeed
          : (_bytesPerSecond * .7) + (instantSpeed * .3);
    }
    _transferredBytes = value;
    _lastEmittedBytes = value;
    _lastEmittedAt = now;
    _onChanged(
      _TransferProgressSnapshot(
        title: title,
        transferredBytes: value,
        totalBytes: _totalBytes,
        bytesPerSecond: _bytesPerSecond,
        preparing: _preparing,
      ),
    );
  }
}

class _TransferProgressView extends StatelessWidget {
  const _TransferProgressView({
    required this.progress,
    this.compact = false,
    this.onCancel,
  });

  final _TransferProgressSnapshot progress;
  final bool compact;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final total = progress.totalBytes;
    final percent = progress.value == null
        ? null
        : '${(progress.value! * 100).toStringAsFixed(0)}%';
    final speed = progress.bytesPerSecond <= 0
        ? null
        : '${_formatBytes(progress.bytesPerSecond.round())}/s';
    final details = progress.preparing
        ? '正在计算文件大小…'
        : [
            if (percent != null) percent,
            total == null || total <= 0
                ? _formatBytes(progress.transferredBytes)
                : '${_formatBytes(progress.transferredBytes)} / ${_formatBytes(total)}',
            if (speed != null) speed,
          ].join(' · ');
    return Semantics(
      label: '${progress.title} $details',
      child: Padding(
        padding: EdgeInsets.fromLTRB(8, compact ? 2 : 0, 8, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  flex: 2,
                  child: LText(
                    progress.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: compact ? 10 : 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (onCancel != null)
                  IconButton(
                    tooltip: localized('取消传输'),
                    onPressed: onCancel,
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 30,
                      minHeight: 30,
                    ),
                    iconSize: compact ? 16 : 18,
                    icon: const Icon(Icons.close),
                  ),
                const SizedBox(width: 6),
                Expanded(
                  flex: 3,
                  child: LText(
                    details,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                    style: TextStyle(fontSize: compact ? 9 : 10),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            LinearProgressIndicator(
              value: progress.value,
              minHeight: compact ? 3 : 4,
            ),
          ],
        ),
      ),
    );
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
        : value < 1024 * 1024 * 1024
            ? '${(value / 1024 / 1024).toStringAsFixed(1)} MB'
            : '${(value / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
