import 'sftp_service.dart';

class FileSelection {
  FileSelection(this.source, Iterable<RemoteEntry> entries, {this.move = false})
      : entries = List.unmodifiable(entries);
  final FileTransferService source;
  final List<RemoteEntry> entries;
  final bool move;
}

Future<void> transferSelection(
    FileSelection selection, FileTransferService target, String directory,
    {TransferCancellationToken? cancellationToken,
    TransferProgressCallback? onProgress,
    void Function(RemoteEntry)? onCompleted}) async {
  final source = selection.source;
  final targets = (await target.list(directory)).map((e) => e.name).toSet();
  final names = <String>{};
  for (final entry in selection.entries) {
    if (!names.add(entry.name) || targets.contains(entry.name)) {
      throw StateError('目标目录已有同名文件：${entry.name}');
    }
    final to = target.joinPath(directory, entry.name);
    if (sameTransferStorage(source, target) &&
        (to == entry.path || to.startsWith('${entry.path}/'))) {
      throw StateError('不能把文件或目录复制到自身');
    }
  }
  var transferred = 0;
  for (final entry in selection.entries) {
    cancellationToken?.throwIfCancelled();
    final destination = target.joinPath(directory, entry.name);
    if (selection.move && source.id == target.id && !source.isLocal) {
      await source.rename(entry.path, destination);
    } else {
      final before = selection.move ? await _snapshot(source, entry) : null;
      final count = await transferEntry(source, entry, target, directory,
          // A partial file may belong to another source with the same name.
          // Batch moves must not resume unverified bytes then delete originals.
          resume: false,
          cancellationToken: cancellationToken,
          onProgress: (bytes) => onProgress?.call(transferred + bytes));
      transferred += count;
      if (selection.move) {
        cancellationToken?.throwIfCancelled();
        final after = await _snapshot(source, entry);
        if (!_same(before!, after)) throw StateError('源文件已变化，已保留源文件');
        for (final file in before.entries.where((e) => !e.value.directory)) {
          final targetPath = file.key.isEmpty
              ? destination
              : target.joinPath(destination, file.key);
          if (await target.fileSize(targetPath) != file.value.size) {
            throw StateError('目标文件校验失败，已保留源文件');
          }
        }
        await source.delete(entry);
      }
    }
    onCompleted?.call(entry);
  }
}

typedef _FileState = ({bool directory, int size, DateTime? modified});
Future<Map<String, _FileState>> _snapshot(
    FileTransferService source, RemoteEntry root) async {
  final result = <String, _FileState>{};
  final current = (await source.list(source.parentPath(root.path)))
      .where((e) => e.path == root.path)
      .firstOrNull;
  if (current == null) throw StateError('源文件不存在');
  Future<void> visit(RemoteEntry entry, String relative) async {
    result[relative] = (
      directory: entry.isDirectory,
      size: entry.size,
      modified: entry.modifiedAt
    );
    if (entry.isDirectory) {
      for (final child in await source.list(entry.path)) {
        await visit(
            child, relative.isEmpty ? child.name : '$relative/${child.name}');
      }
    }
  }

  await visit(current, '');
  return result;
}

bool _same(Map<String, _FileState> a, Map<String, _FileState> b) =>
    a.length == b.length && a.entries.every((e) => b[e.key] == e.value);
