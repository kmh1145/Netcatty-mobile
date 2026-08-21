part of 'sftp_screen.dart';

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
  _TransferProgressSnapshot? _transfer;
  TransferCancellationToken? _transferCancellation;

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
        title: LText(
          entry.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: compact ? 12 : 14),
        ),
        subtitle: compact
            ? null
            : LText(entry.isDirectory ? '目录' : _formatBytes(entry.size)),
        onTap: () => entry.isDirectory ? _open(entry.path) : _edit(entry),
        trailing: PopupMenuButton<String>(
          tooltip: localized('文件操作'),
          padding: EdgeInsets.zero,
          onSelected: (value) => _entryAction(value, entry),
          itemBuilder: (_) => [
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
              title: LText(entry.name),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const LText('保存'),
                ),
              ],
            ),
            body: TextField(
              controller: controller,
              expands: true,
              maxLines: null,
              minLines: null,
              style: const TextStyle(fontFamily: 'monospace'),
              decoration: LInputDecoration(
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
