import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'sftp_service.dart';

/// A phone-side file source backed by Android's Storage Access Framework.
///
/// Paths exposed to the rest of the app are logical paths rooted at the tree
/// selected by the user. Native code keeps the persistable URI permission and
/// resolves those paths without requesting broad storage access.
class AndroidDocumentTreeTransferService extends MountableFileTransferService {
  AndroidDocumentTreeTransferService._({
    required bool mounted,
    String? directoryName,
  })  : isMounted = mounted,
        mountedDirectoryName = directoryName;

  static const _channel = MethodChannel('app.netcatty.mobile/storage');

  static Future<AndroidDocumentTreeTransferService> create() async {
    final value = await _channel.invokeMapMethod<String, dynamic>('getMount');
    return AndroidDocumentTreeTransferService._(
      mounted: value?['mounted'] == true,
      directoryName: value?['name']?.toString(),
    );
  }

  @override
  bool isMounted;
  @override
  String? mountedDirectoryName;

  @override
  String get id => 'local';
  @override
  String get displayName =>
      isMounted ? '手机：${mountedDirectoryName ?? '已选目录'}' : '手机目录（未挂载）';
  @override
  String get rootPath => '/';
  @override
  bool get isLocal => true;

  @override
  Future<bool> mount() async {
    final value = await _channel.invokeMapMethod<String, dynamic>('mount');
    if (value == null) return false;
    isMounted = value['mounted'] == true;
    mountedDirectoryName = value['name']?.toString();
    return isMounted;
  }

  @override
  String displayPath(String path) {
    final name = mountedDirectoryName;
    if (name == null) return '尚未选择手机目录';
    return path == '/' ? '/$name' : '/$name$path';
  }

  @override
  String joinPath(String path, String name) =>
      path == '/' ? '/$name' : '$path/$name';

  @override
  String parentPath(String path) {
    if (path == '/') return '/';
    final separator = path.lastIndexOf('/');
    return separator <= 0 ? '/' : path.substring(0, separator);
  }

  @override
  Future<List<RemoteEntry>> list(String path) async {
    if (!isMounted) return const [];
    final values = await _channel.invokeListMethod<dynamic>(
          'list',
          {'path': path},
        ) ??
        const [];
    return values
        .whereType<Map>()
        .map((value) {
          final item = Map<String, dynamic>.from(value);
          final modified = (item['modified'] as num?)?.toInt();
          return RemoteEntry(
            name: item['name']?.toString() ?? '',
            path: item['path']?.toString() ?? '/',
            isDirectory: item['isDirectory'] == true,
            size: (item['size'] as num?)?.toInt() ?? 0,
            modifiedAt: modified == null || modified <= 0
                ? null
                : DateTime.fromMillisecondsSinceEpoch(modified),
          );
        })
        .where((entry) => entry.name.isNotEmpty)
        .toList()
      ..sort(compareFileTransferEntries);
  }

  @override
  Stream<Uint8List> readStream(
    String path, {
    TransferProgressCallback? onProgress,
  }) async* {
    _requireMounted();
    final cachePath = await _channel.invokeMethod<String>(
      'copyToCache',
      {'path': path},
    );
    if (cachePath == null) throw StateError('无法读取手机文件');
    final cache = File(cachePath);
    try {
      final stream = asUint8ListStream(cache.openRead());
      yield* onProgress == null
          ? stream
          : trackTransferProgress(stream, onProgress);
    } finally {
      if (await cache.exists()) await cache.delete();
    }
  }

  @override
  Future<void> writeStream(
    String path,
    Stream<Uint8List> stream, {
    TransferProgressCallback? onProgress,
  }) async {
    _requireMounted();
    final cacheDirectory = await getTemporaryDirectory();
    final cache = File(
      '${cacheDirectory.path}${Platform.pathSeparator}'
      'saf-upload-${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      final sink = cache.openWrite(mode: FileMode.writeOnly);
      try {
        await sink.addStream(
          onProgress == null
              ? stream
              : trackTransferProgress(stream, onProgress),
        );
      } finally {
        await sink.close();
      }
      await _channel.invokeMethod<void>(
        'copyFromCache',
        {'path': path, 'cachePath': cache.path},
      );
    } finally {
      if (await cache.exists()) await cache.delete();
    }
  }

  @override
  Future<void> mkdir(String path) async {
    _requireMounted();
    await _channel.invokeMethod<void>('mkdir', {'path': path});
  }

  @override
  Future<void> ensureDirectory(String path) async {
    _requireMounted();
    await _channel.invokeMethod<void>('ensureDirectory', {'path': path});
  }

  @override
  Future<void> rename(String from, String to) async {
    _requireMounted();
    await _channel.invokeMethod<void>('rename', {'from': from, 'to': to});
  }

  @override
  Future<void> delete(RemoteEntry entry) async {
    _requireMounted();
    await _channel.invokeMethod<void>('delete', {'path': entry.path});
  }

  void _requireMounted() {
    if (!isMounted) throw StateError('请先选择并挂载手机目录');
  }
}
