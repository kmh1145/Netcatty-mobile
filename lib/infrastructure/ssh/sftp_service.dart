import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

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

class SftpService {
  SftpService(this.session);

  final ActiveTerminalSession session;
  SftpClient? _client;

  Future<SftpClient> get _sftp async {
    final ssh = session.sshClient;
    if (ssh == null) throw StateError('当前会话不支持 SFTP');
    return _client ??= await ssh.sftp();
  }

  Future<List<RemoteEntry>> list(String path) async {
    final entries = await (await _sftp).listdir(path);
    return entries
        .where((item) => item.filename != '.' && item.filename != '..')
        .map((item) {
      final fullPath =
          path == '/' ? '/${item.filename}' : '$path/${item.filename}';
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
      ..sort((a, b) {
        if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
  }

  Future<Uint8List> readBytes(String path) async =>
      (await (await _sftp).open(path)).readBytes();

  Future<String> readText(String path) async =>
      utf8.decode(await readBytes(path), allowMalformed: true);

  Future<void> writeBytes(String path, Uint8List data) async {
    final file = await (await _sftp).open(
      path,
      mode: SftpFileOpenMode.create |
          SftpFileOpenMode.write |
          SftpFileOpenMode.truncate,
    );
    await file.writeBytes(data);
    await file.close();
  }

  Future<void> writeText(String path, String content) =>
      writeBytes(path, Uint8List.fromList(utf8.encode(content)));

  Future<void> mkdir(String path) async => (await _sftp).mkdir(path);
  Future<void> rename(String from, String to) async =>
      (await _sftp).rename(from, to);
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
