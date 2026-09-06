import 'dart:async';

import 'package:uuid/uuid.dart';

import 'sftp_service.dart';
import 'server_transfer_commands.dart';

enum TransferRoute { phoneRelay, serverLocal, serverDirect }

class TransferRoutePlan {
  const TransferRoutePlan(this.route, {this.relayReason});
  final TransferRoute route;
  final String? relayReason;
}

Future<TransferRoutePlan> prepareTransferRoute(FileSelection selection,
    FileTransferService target, TransferCancellationToken? token,
    {String? targetDirectory}) async {
  final source = selection.source;
  if (source.isLocal || target.isLocal) {
    return const TransferRoutePlan(TransferRoute.phoneRelay);
  }
  try {
    token?.throwIfCancelled();
    if (!source.supportsServerTransfer || !target.supportsServerTransfer) {
      throw UnsupportedError('Remote command execution is unavailable');
    }
    if (!sameTransferStorage(source, target)) {
      if (targetDirectory != null) {
        ServerTransferCommands.batchPath('$targetDirectory/.netcatty-transfer');
      }
      for (final entry in selection.entries) {
        ServerTransferCommands.batchPath(entry.path);
        // OpenSSH's recursive SFTP skips symlinks. Never silently omit them.
        await _checkDirectEntry(source, entry, token);
      }
    }
    await source.probeServerTransfer(target, token);
    token?.throwIfCancelled();
    return TransferRoutePlan(sameTransferStorage(source, target)
        ? TransferRoute.serverLocal
        : TransferRoute.serverDirect);
  } on TransferCancelledException {
    rethrow;
  } catch (error) {
    token?.throwIfCancelled();
    return TransferRoutePlan(TransferRoute.phoneRelay,
        relayReason: error.toString());
  }
}

Future<void> _checkDirectEntry(FileTransferService source, RemoteEntry entry,
    TransferCancellationToken? token) async {
  token?.throwIfCancelled();
  if (entry.unixMode != null &&
      (entry.unixMode! & 0xf000) != 0x8000 &&
      (entry.unixMode! & 0xf000) != 0x4000) {
    throw UnsupportedError(
        'Direct SFTP supports regular files and directories only');
  }
  if (entry.isDirectory) {
    for (final child in await source.list(entry.path)) {
      await _checkDirectEntry(source, child, token);
    }
  }
}

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
    TransferRoute route = TransferRoute.phoneRelay,
    bool resumePhoneCopy = false,
    TransferProgressCallback? onProgress,
    void Function(String)? onStatus,
    void Function(RemoteEntry)? onCompleted}) async {
  final source = selection.source;
  final targets = (await target.list(directory)).map((e) => e.name).toSet();
  final names = <String>{};
  for (final entry in selection.entries) {
    if (!names.add(entry.name) || targets.contains(entry.name)) {
      throw StateError('目标目录已有同名文件：${entry.name}');
    }
    final to = target.joinPath(directory, entry.name);
    if (sameTransferStorage(source, target)) {
      final from = await source.canonicalPath(entry.path);
      final canonicalTarget =
          target.joinPath(await target.canonicalPath(directory), entry.name);
      if (to == entry.path ||
          to.startsWith('${entry.path}/') ||
          canonicalTarget == from ||
          canonicalTarget.startsWith('$from/')) {
        throw StateError('不能把文件或目录复制到自身');
      }
    }
  }
  var transferred = 0;
  for (final entry in selection.entries) {
    cancellationToken?.throwIfCancelled();
    final destination = target.joinPath(directory, entry.name);
    if (route != TransferRoute.phoneRelay) {
      onStatus
          ?.call(route == TransferRoute.serverLocal ? '服务器内部操作中…' : '服务器间直传中…');
      final baseline = transferred;
      transferred += await _serverTransfer(
          selection,
          entry,
          target,
          directory,
          destination,
          route,
          cancellationToken,
          (bytes) => onProgress?.call(baseline + bytes),
          onStatus);
    } else if (selection.move && source.id == target.id && !source.isLocal) {
      await source.rename(entry.path, destination);
    } else {
      final before = selection.move ? await _snapshot(source, entry) : null;
      final count = await transferEntry(source, entry, target, directory,
          // A partial file may belong to another source with the same name.
          // Batch moves must not resume unverified bytes then delete originals.
          resume: resumePhoneCopy &&
              !selection.move &&
              selection.entries.length == 1,
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

Future<int> _serverTransfer(
    FileSelection selection,
    RemoteEntry entry,
    FileTransferService target,
    String directory,
    String destination,
    TransferRoute route,
    TransferCancellationToken? token,
    TransferProgressCallback? onProgress,
    void Function(String)? onStatus) async {
  final source = selection.source;
  if (route == TransferRoute.serverLocal &&
      !sameTransferStorage(source, target)) {
    throw StateError('Server-local route requires the same storage');
  }
  if (route == TransferRoute.serverLocal && selection.move) {
    // No directory-size traversal or phone download, including separate tabs.
    try {
      await source.moveOnServer(entry.path, destination, token);
    } catch (error) {
      throw StateError('服务器移动未确认完成，请检查源目录和目标目录后再重试：$error');
    }
    return 0;
  }
  // Unique staging directory; never resume another operation's partial data.
  final stage =
      target.joinPath(directory, '.netcatty-transfer-${const Uuid().v4()}');
  final stagedPath = target.joinPath(stage, entry.name);
  final before = route == TransferRoute.serverDirect
      ? await _snapshot(source, entry, token)
      : null;
  await target.mkdir(stage);
  Timer? progressTimer;
  var readingProgress = false;
  var done = false;
  try {
    await target.setPermissions(
        stage, 0x1c0); // 0700, never expose partial data.
    // Aliased endpoints can expose a shared filesystem. Never recurse into a
    // newly-created staging directory that is visible inside the source tree.
    if (route == TransferRoute.serverDirect &&
        entry.isDirectory &&
        await source.fileSize(stage) != null) {
      final from = await source.canonicalPath(entry.path);
      final stagingSourcePath = await source.canonicalPath(stage);
      if (stagingSourcePath == from || stagingSourcePath.startsWith('$from/')) {
        throw StateError('不能把文件或目录复制到自身');
      }
    }
    if (!entry.isDirectory && onProgress != null) {
      progressTimer = Timer.periodic(const Duration(seconds: 1), (_) async {
        if (readingProgress || done) return;
        readingProgress = true;
        try {
          final bytes = await target.fileSize(stagedPath);
          if (!done && bytes != null) onProgress(bytes);
        } catch (_) {
          /* Progress is best effort, not a success condition. */
        } finally {
          readingProgress = false;
        }
      });
    }
    token?.throwIfCancelled();
    await source.copyOnServer(entry, target, stagedPath, token);
    token?.throwIfCancelled();
    if (before != null) {
      onStatus?.call('正在校验服务器文件…');
      final after = await _snapshot(source, entry, token);
      if (!_same(before, after)) throw StateError('源文件已变化，已保留源文件');
      final copied = await _snapshot(
          target,
          RemoteEntry(
              name: entry.name,
              path: stagedPath,
              isDirectory: entry.isDirectory,
              size: entry.size),
          token);
      if (before.length != copied.length ||
          before.entries.any((item) {
            final other = copied[item.key];
            return other == null ||
                other.directory != item.value.directory ||
                (!other.directory && other.size != item.value.size);
          })) {
        throw StateError('目标文件校验失败，已保留源文件');
      }
    }
    token?.throwIfCancelled();
    // dartssh2 rename prefers posix-rename (which replaces destinations).
    // Use a no-clobber server move for publication instead.
    await target.moveOnServer(stagedPath, destination, token);
    if (selection.move) {
      token?.throwIfCancelled();
      if (!_same(before!, await _snapshot(source, entry, token))) {
        throw StateError('源文件已变化，已保留源文件');
      }
      await source.delete(entry);
    }
    try {
      await target.delete(RemoteEntry(
          name: stage.split('/').last,
          path: stage,
          isDirectory: true,
          size: 0));
    } catch (_) {
      /* An empty staging-directory cleanup failure is not a failed move. */
    }
    return before?.values
            .where((file) => !file.directory)
            .fold<int>(0, (sum, file) => sum + file.size) ??
        (entry.isDirectory ? 0 : entry.size);
  } catch (error) {
    // A server may ignore SSH signals. Do not delete/reuse a directory while a
    // remote writer might still own it, and never retry via relay automatically.
    throw StateError('服务器操作未完成，未自动切换手机中转；请检查目标及临时目录：$stage\n$error');
  } finally {
    done = true;
    progressTimer?.cancel();
  }
}

typedef _FileState = ({bool directory, int size, DateTime? modified});
Future<Map<String, _FileState>> _snapshot(
    FileTransferService source, RemoteEntry root,
    [TransferCancellationToken? token]) async {
  token?.throwIfCancelled();
  final result = <String, _FileState>{};
  final current = (await source.list(source.parentPath(root.path)))
      .where((e) => e.path == root.path)
      .firstOrNull;
  if (current == null) throw StateError('源文件不存在');
  Future<void> visit(RemoteEntry entry, String relative) async {
    token?.throwIfCancelled();
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
