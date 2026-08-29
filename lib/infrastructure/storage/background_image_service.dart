import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

class BackgroundImageService {
  Future<String> persist({
    String? sourcePath,
    Uint8List? bytes,
    Stream<List<int>>? stream,
    String? extension,
    String? previousPath,
  }) async {
    if ((sourcePath == null || sourcePath.isEmpty) &&
        bytes == null &&
        stream == null) {
      throw const FormatException('无法读取所选背景图片');
    }
    final support = await getApplicationSupportDirectory();
    final directory = Directory(
      '${support.path}${Platform.pathSeparator}custom-backgrounds',
    );
    await directory.create(recursive: true);
    final normalizedExtension = _normalizeExtension(extension, sourcePath);
    final destination = File(
      '${directory.path}${Platform.pathSeparator}'
      'background-${DateTime.now().microsecondsSinceEpoch}.$normalizedExtension',
    );
    if (sourcePath != null && sourcePath.isNotEmpty) {
      await File(sourcePath).copy(destination.path);
    } else if (bytes != null) {
      await destination.writeAsBytes(bytes, flush: true);
    } else {
      final sink = destination.openWrite();
      try {
        await sink.addStream(stream!);
      } finally {
        await sink.close();
      }
    }
    if (previousPath != null && previousPath != destination.path) {
      await _deleteManagedFile(previousPath, directory);
    }
    return destination.path;
  }

  Future<void> remove(String path) async {
    if (path.isEmpty) return;
    final support = await getApplicationSupportDirectory();
    final directory = Directory(
      '${support.path}${Platform.pathSeparator}custom-backgrounds',
    );
    await _deleteManagedFile(path, directory);
  }

  Future<void> _deleteManagedFile(String path, Directory directory) async {
    final file = File(path);
    final directoryPrefix =
        '${directory.absolute.path}${Platform.pathSeparator}';
    if (!file.absolute.path.startsWith(directoryPrefix)) return;
    if (await file.exists()) await file.delete();
  }

  static String _normalizeExtension(String? extension, String? sourcePath) {
    var value = extension?.trim().toLowerCase() ?? '';
    if (value.isEmpty && sourcePath != null) {
      final separator = sourcePath.lastIndexOf('.');
      if (separator >= 0) value = sourcePath.substring(separator + 1);
    }
    value = value.replaceAll(RegExp(r'[^a-z0-9]'), '');
    return value.isEmpty ? 'jpg' : value;
  }
}
