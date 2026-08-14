import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
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

abstract class FileTransferService {
  String get id;
  String get displayName;
  String get rootPath;
  bool get isLocal;

  String displayPath(String path);
  String joinPath(String path, String name);
  String parentPath(String path);
  Future<List<RemoteEntry>> list(String path);
  Stream<Uint8List> readStream(String path);
  Future<void> writeStream(String path, Stream<Uint8List> stream);
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
  Stream<Uint8List> readStream(String path) async* {
    final file = await (await _sftp).open(path, mode: SftpFileOpenMode.read);
    try {
      yield* file.read();
    } finally {
      await file.close();
    }
  }

  @override
  Future<void> writeStream(String path, Stream<Uint8List> stream) async {
    final file = await (await _sftp).open(
      path,
      mode: SftpFileOpenMode.create |
          SftpFileOpenMode.write |
          SftpFileOpenMode.truncate,
    );
    try {
      await file.write(stream).done;
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
  Future<void> copyEntry(RemoteEntry entry, String targetDirectory) =>
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
  LocalFileTransferService._(this.rootPath, {this.isMounted = false});

  static const _iosStorageChannel = MethodChannel(
    'app.netcatty.mobile/storage',
  );

  static Future<LocalFileTransferService> create() async {
    if (Platform.isIOS) {
      final mount = await _iosStorageChannel.invokeMapMethod<String, dynamic>(
        'getMount',
      );
      final path = mount?['path']?.toString();
      if (mount?['mounted'] == true && path?.isNotEmpty == true) {
        return LocalFileTransferService._(path!, isMounted: true);
      }
    }
    final documents = await getApplicationDocumentsDirectory();
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
  String? get mountedDirectoryName => isMounted
      ? Uri.file(rootPath).pathSegments.where((value) => value.isNotEmpty).last
      : null;
  @override
  String get id => 'local';
  @override
  String get displayName =>
      isMounted ? '手机：${mountedDirectoryName ?? '已选目录'}' : '手机目录（未挂载）';
  @override
  bool get isLocal => true;

  @override
  Future<bool> mount() async {
    final String? selected;
    if (Platform.isIOS) {
      final mount = await _iosStorageChannel.invokeMapMethod<String, dynamic>(
        'mount',
      );
      selected = mount?['path']?.toString();
    } else {
      selected = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择要挂载到 SFTP 的手机目录',
      );
    }
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
  Stream<Uint8List> readStream(String path) =>
      File(path).openRead().map((chunk) => Uint8List.fromList(chunk));

  @override
  Future<void> writeStream(String path, Stream<Uint8List> stream) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    final sink = file.openWrite(mode: FileMode.writeOnly);
    try {
      await sink.addStream(stream);
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

Future<void> transferEntry(
  FileTransferService source,
  RemoteEntry entry,
  FileTransferService target,
  String targetDirectory,
) async {
  final targetPath = target.joinPath(targetDirectory, entry.name);
  final separator = source.isLocal ? Platform.pathSeparator : '/';
  if (source.id == target.id &&
      (targetPath == entry.path ||
          targetPath.startsWith('${entry.path}$separator'))) {
    throw StateError('不能把文件或目录复制到自身');
  }
  if (entry.isDirectory) {
    await target.ensureDirectory(targetPath);
    for (final child in await source.list(entry.path)) {
      await transferEntry(source, child, target, targetPath);
    }
    return;
  }
  await target.writeStream(targetPath, source.readStream(entry.path));
}

String joinRemotePath(String path, String name) =>
    path == '/' ? '/$name' : '$path/$name';

int compareFileTransferEntries(RemoteEntry a, RemoteEntry b) {
  if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
  return a.name.toLowerCase().compareTo(b.name.toLowerCase());
}
