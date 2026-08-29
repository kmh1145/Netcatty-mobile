import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

class BackgroundImageService {
  BackgroundImageService({Future<Directory> Function()? supportDirectory})
      : _supportDirectory = supportDirectory ?? getApplicationSupportDirectory;

  final Future<Directory> Function() _supportDirectory;

  static const managedPathPrefix = 'netcatty-background:';

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
    final directory = await _managedDirectory();
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
    final directory = await _managedDirectory();
    await _deleteManagedFile(path, directory);
  }

  /// Resolves a portable managed reference or repairs a legacy absolute path
  /// after the operating system moves the app data container.
  Future<String> resolveStoredPath(String storedPath) async {
    final value = storedPath.trim();
    if (value.isEmpty) return '';

    if (value.startsWith(managedPathPrefix)) {
      final fileName = _fileName(value.substring(managedPathPrefix.length));
      if (fileName.isEmpty) return storedPath;
      final directory = await _managedDirectory();
      return File(
        '${directory.path}${Platform.pathSeparator}$fileName',
      ).absolute.path;
    }

    final storedFile = File(value);
    if (await storedFile.exists()) return storedFile.absolute.path;

    if (!_looksLikeManagedLegacyPath(value)) return storedPath;
    final fileName = _fileName(value);
    if (fileName.isEmpty) return storedPath;
    final directory = await _managedDirectory();
    final relocated = File(
      '${directory.path}${Platform.pathSeparator}$fileName',
    );
    return await relocated.exists() ? relocated.absolute.path : storedPath;
  }

  /// Converts a managed absolute path into a container-independent reference.
  Future<String> toStoredPath(String runtimePath) async {
    final value = runtimePath.trim();
    if (value.isEmpty || value.startsWith(managedPathPrefix)) return value;

    final runtimeFile = File(value);
    if (!await runtimeFile.exists()) return runtimePath;
    final directory = await _managedDirectory();
    final directoryPrefix =
        '${directory.absolute.path}${Platform.pathSeparator}';
    final file = File(value).absolute;
    if (!file.path.startsWith(directoryPrefix)) return runtimePath;
    final fileName = _fileName(file.path);
    return fileName.isEmpty ? runtimePath : '$managedPathPrefix$fileName';
  }

  Future<Directory> _managedDirectory() async {
    final support = await _supportDirectory();
    return Directory(
      '${support.path}${Platform.pathSeparator}custom-backgrounds',
    );
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

  static String _fileName(String path) {
    final normalized = path.replaceAll('\\', '/');
    final separator = normalized.lastIndexOf('/');
    return separator < 0 ? normalized : normalized.substring(separator + 1);
  }

  static bool _looksLikeManagedLegacyPath(String path) {
    final normalized = path.replaceAll('\\', '/');
    return normalized.contains('/custom-backgrounds/') &&
        _fileName(normalized).startsWith('background-');
  }
}
