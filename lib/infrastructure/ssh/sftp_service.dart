import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';

import 'ssh_service.dart';

class RemoteEntry {
  const RemoteEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    required this.size,
    this.modifiedAt,
  });

  final String name;
  final String path;
  final bool isDirectory;
  final int size;
  final DateTime? modifiedAt;
}

typedef TransferProgressCallback = void Function(int transferredBytes);

abstract class FileTransferService {
  String get id;
  String get displayName;
  String get rootPath;
  bool get isLocal;

  String displayPath(String path);
  String joinPath(String path, String name);
  String parentPath(String path);
  Future<List<RemoteEntry>> list(String path);
  Stream<Uint8List> readStream(
    String path, {
    TransferProgressCallback? onProgress,
  });
  Future<void> writeStream(
    String path,
    Stream<Uint8List> stream, {
    TransferProgressCallback? onProgress,
  });
  Future<void> mkdir(String path);
  Future<void> ensureDirectory(String path);
  Future<void> rename(String from, String to);
  Future<void> delete(RemoteEntry entry);

  Future<Uint8List> readBytes(String path) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in readStream(path)) {
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  Future<String> readText(String path) async =>
      utf8.decode(await readBytes(path), allowMalformed: true);

  Future<void> writeBytes(String path, Uint8List data) =>
      writeStream(path, Stream.value(data));

  Future<void> writeText(String path, String content) =>
      writeBytes(path, Uint8List.fromList(utf8.encode(content)));
}

abstract class MountableFileTransferService extends FileTransferService {
  bool get isMounted;
  String? get mountedDirectoryName;
  bool get usesAppDocuments => false;
  Future<bool> mount();
}

class SftpService extends FileTransferService {
  SftpService(this.session);

  final ActiveTerminalSession session;
  SftpClient? _client;

  @override
  String get id => 'ssh:${session.id}';
  @override
  String get displayName => session.host.label;
  @override
  String get rootPath => '/';
  @override
  bool get isLocal => false;

  Future<SftpClient> get _sftp async {
    final ssh = session.sshClient;
    if (ssh == null) throw StateError('当前会话不支持 SFTP');
    return _client ??= await ssh.sftp();
  }

  @override
  String displayPath(String path) => path;

  @override
  String joinPath(String path, String name) => joinRemotePath(path, name);

  @override
  String parentPath(String path) {
    final parts = path.split('/')..removeWhere((value) => value.isEmpty);
    if (parts.isNotEmpty) parts.removeLast();
    return '/${parts.join('/')}';
  }

  @override
  Future<List<RemoteEntry>> list(String path) async {
    final entries = await (await _sftp).listdir(path);
    return entries
        .where((item) => item.filename != '.' && item.filename != '..')
        .map((item) {
      final fullPath = joinPath(path, item.filename);
      final modified = item.attr.modifyTime;
      return RemoteEntry(
        name: item.filename,
        path: fullPath,
        isDirectory: item.attr.mode?.type == SftpFileType.directory,
        size: item.attr.size ?? 0,
        modifiedAt: modified == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(modified * 1000),
      );
    }).toList()
      ..sort(compareFileTransferEntries);
  }

  @override
  Stream<Uint8List> readStream(
    String path, {
    TransferProgressCallback? onProgress,
  }) async* {
    final file = await (await _sftp).open(path, mode: SftpFileOpenMode.read);
    try {
      yield* Platform.isIOS
          ? file.read(onProgress: onProgress, maxPendingRequests: 8)
          : file.read(onProgress: onProgress);
    } finally {
      await file.close();
    }
  }

  @override
  Future<void> writeStream(
    String path,
    Stream<Uint8List> stream, {
    TransferProgressCallback? onProgress,
  }) async {
    final file = await (await _sftp).open(
      path,
      mode: SftpFileOpenMode.create |
          SftpFileOpenMode.write |
          SftpFileOpenMode.truncate,
    );
    try {
      if (Platform.isIOS) {
        await _writeSftpStreamWithLimitedConcurrency(
          file,
          stream,
          onProgress: onProgress,
        );
      } else {
        await file.write(stream, onProgress: onProgress).done;
      }
    } finally {
      await file.close();
    }
  }

  @override
  Future<void> mkdir(String path) async => (await _sftp).mkdir(path);

  @override
  Future<void> ensureDirectory(String path) async {
    try {
      await mkdir(path);
    } on SftpStatusError {
      final existing = await (await _sftp).stat(path);
      if (existing.mode?.type != SftpFileType.directory) rethrow;
    }
  }

  @override
  Future<void> rename(String from, String to) async =>
      (await _sftp).rename(from, to);

  /// Retained for callers that copy within this SSH session.
  Future<int> copyEntry(RemoteEntry entry, String targetDirectory) =>
      transferEntry(this, entry, this, targetDirectory);

  @override
  Future<void> delete(RemoteEntry entry) async => entry.isDirectory
      ? _deleteDirectory(entry.path)
      : (await _sftp).remove(entry.path);

  Future<void> _deleteDirectory(String path) async {
    for (final child in await list(path)) {
      await delete(child);
    }
    await (await _sftp).rmdir(path);
  }
}

class LocalFileTransferService extends MountableFileTransferService {
  LocalFileTransferService._(
    this.rootPath, {
    this.isMounted = false,
    this.usesAppDocuments = false,
  });

  static Future<LocalFileTransferService> create() async {
    final documents = await getApplicationDocumentsDirectory();
    if (Platform.isIOS) {
      await documents.create(recursive: true);
      return LocalFileTransferService._(
        documents.path,
        isMounted: true,
        usesAppDocuments: true,
      );
    }
    final root = Directory(
      '${documents.path}${Platform.pathSeparator}Netcatty',
    );
    await root.create(recursive: true);
    return LocalFileTransferService._(root.path);
  }

  @override
  String rootPath;
  @override
  bool isMounted;
  @override
  final bool usesAppDocuments;
  @override
  String? get mountedDirectoryName {
    if (!isMounted) return null;
    if (usesAppDocuments) return 'Netcatty';
    return Uri.file(rootPath)
        .pathSegments
        .where((value) => value.isNotEmpty)
        .last;
  }

  @override
  String get id => 'local';
  @override
  String get displayName => usesAppDocuments
      ? '文件：Netcatty'
      : isMounted
          ? '手机：${mountedDirectoryName ?? '已选目录'}'
          : '手机目录（未挂载）';
  @override
  bool get isLocal => true;

  @override
  Future<bool> mount() async {
    if (usesAppDocuments) {
      await Directory(rootPath).create(recursive: true);
      isMounted = true;
      return true;
    }
    final selected = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择要挂载到 SFTP 的手机目录',
    );
    if (selected == null || selected.isEmpty) return false;
    rootPath = selected;
    isMounted = true;
    return true;
  }

  @override
  String displayPath(String path) {
    if (!isMounted) return '尚未选择手机目录';
    if (path == rootPath) return '/';
    final relative = path.substring(rootPath.length).replaceAll('\\', '/');
    return relative.startsWith('/') ? relative : '/$relative';
  }

  @override
  String joinPath(String path, String name) =>
      '$path${Platform.pathSeparator}$name';

  @override
  String parentPath(String path) {
    if (path == rootPath) return rootPath;
    final parent = Directory(path).parent.path;
    return parent.length < rootPath.length ? rootPath : parent;
  }

  @override
  Future<List<RemoteEntry>> list(String path) async {
    if (!isMounted) return const [];
    final directory = Directory(path);
    if (!await directory.exists()) throw StateError('手机目录不存在');
    final result = <RemoteEntry>[];
    await for (final entity in directory.list(followLinks: false)) {
      final stat = await entity.stat();
      result.add(
        RemoteEntry(
          name: entity.uri.pathSegments.where((value) => value.isNotEmpty).last,
          path: entity.path,
          isDirectory: stat.type == FileSystemEntityType.directory,
          size: stat.type == FileSystemEntityType.file ? stat.size : 0,
          modifiedAt: stat.modified,
        ),
      );
    }
    return result..sort(compareFileTransferEntries);
  }

  @override
  Stream<Uint8List> readStream(
    String path, {
    TransferProgressCallback? onProgress,
  }) {
    final stream = asUint8ListStream(File(path).openRead());
    return onProgress == null
        ? stream
        : trackTransferProgress(stream, onProgress);
  }

  @override
  Future<void> writeStream(
    String path,
    Stream<Uint8List> stream, {
    TransferProgressCallback? onProgress,
  }) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    final sink = file.openWrite(mode: FileMode.writeOnly);
    try {
      await sink.addStream(
        onProgress == null ? stream : trackTransferProgress(stream, onProgress),
      );
    } finally {
      await sink.close();
    }
  }

  @override
  Future<void> mkdir(String path) => Directory(path).create();

  @override
  Future<void> ensureDirectory(String path) =>
      Directory(path).create(recursive: true);

  @override
  Future<void> rename(String from, String to) async {
    final type = await FileSystemEntity.type(from, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      await Directory(from).rename(to);
    } else {
      await File(from).rename(to);
    }
  }

  @override
  Future<void> delete(RemoteEntry entry) => entry.isDirectory
      ? Directory(entry.path).delete(recursive: true)
      : File(entry.path).delete();
}

Future<int> calculateTransferSize(
  FileTransferService source,
  RemoteEntry entry,
) async {
  if (!entry.isDirectory) return entry.size;
  var total = 0;
  for (final child in await source.list(entry.path)) {
    total += await calculateTransferSize(source, child);
  }
  return total;
}

Future<int> transferEntry(
  FileTransferService source,
  RemoteEntry entry,
  FileTransferService target,
  String targetDirectory, {
  TransferProgressCallback? onProgress,
}) async {
  final targetPath = target.joinPath(targetDirectory, entry.name);
  final separator = source.isLocal ? Platform.pathSeparator : '/';
  if (source.id == target.id &&
      (targetPath == entry.path ||
          targetPath.startsWith('${entry.path}$separator'))) {
    throw StateError('不能把文件或目录复制到自身');
  }

  var transferred = 0;

  Future<void> copy(RemoteEntry current, String directory) async {
    final currentTargetPath = target.joinPath(directory, current.name);
    if (current.isDirectory) {
      await target.ensureDirectory(currentTargetPath);
      for (final child in await source.list(current.path)) {
        await copy(child, currentTargetPath);
      }
      return;
    }

    final baseline = transferred;
    var fileProgress = 0;
    await target.writeStream(
      currentTargetPath,
      source.readStream(current.path),
      onProgress: (value) {
        fileProgress = value;
        onProgress?.call(baseline + value);
      },
    );
    transferred = baseline + fileProgress;
  }

  await copy(entry, targetDirectory);
  return transferred;
}

Stream<Uint8List> asUint8ListStream(Stream<List<int>> source) => source.map(
      (chunk) => chunk is Uint8List ? chunk : Uint8List.fromList(chunk),
    );

Stream<Uint8List> trackTransferProgress(
  Stream<Uint8List> source,
  TransferProgressCallback onProgress,
) async* {
  var transferred = 0;
  await for (final chunk in source) {
    yield chunk;
    transferred += chunk.length;
    onProgress(transferred);
  }
}

Future<void> _writeSftpStreamWithLimitedConcurrency(
  SftpFile file,
  Stream<Uint8List> stream, {
  TransferProgressCallback? onProgress,
  int maxPendingWrites = 8,
}) async {
  const maxChunkSize = 16 * 1024;
  var offset = 0;
  var acknowledged = 0;
  var batch = <Future<int>>[];

  Future<void> flushBatch() async {
    if (batch.isEmpty) return;
    final completed = await Future.wait(batch);
    acknowledged += completed.fold(0, (total, value) => total + value);
    onProgress?.call(acknowledged);
    batch = <Future<int>>[];
  }

  await for (final chunk in _splitByteChunks(stream, maxChunkSize)) {
    final writeOffset = offset;
    offset += chunk.length;
    batch.add(
      file.writeBytes(chunk, offset: writeOffset).then((_) => chunk.length),
    );
    if (batch.length >= maxPendingWrites) await flushBatch();
  }
  await flushBatch();
}

Stream<Uint8List> _splitByteChunks(
  Stream<Uint8List> source,
  int maxChunkSize,
) async* {
  await for (final chunk in source) {
    if (chunk.length <= maxChunkSize) {
      yield chunk;
      continue;
    }
    for (var offset = 0; offset < chunk.length; offset += maxChunkSize) {
      final end = (offset + maxChunkSize).clamp(0, chunk.length);
      yield Uint8List.sublistView(chunk, offset, end);
    }
  }
}

String joinRemotePath(String path, String name) =>
    path == '/' ? '/$name' : '$path/$name';

int compareFileTransferEntries(RemoteEntry a, RemoteEntry b) {
  if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
  return a.name.toLowerCase().compareTo(b.name.toLowerCase());
}
