/// Builds a non-interactive extraction command for a remote POSIX server.
/// A new destination directory is required so existing files are not replaced.
class RemoteArchive {
  static String compressCommand(List<String> paths, String destination) {
    if (paths.isEmpty ||
        !destination.startsWith('/') ||
        destination.contains('\u0000')) {
      throw ArgumentError('Invalid archive destination');
    }
    final parent = paths.first.substring(0, paths.first.lastIndexOf('/') + 1);
    if (paths.any((p) => destination == p || destination.startsWith('$p/'))) {
      throw ArgumentError('Archive cannot be inside its source');
    }
    if (paths.any((p) =>
            !p.startsWith('/') ||
            p.contains('\u0000') ||
            p.split('/').contains('..') ||
            p.substring(0, p.lastIndexOf('/') + 1) != parent) ||
        destination.split('/').contains('..')) {
      throw ArgumentError('Files must share a directory');
    }
    String quote(String value) => "'${value.replaceAll("'", "'\\''")}'";
    final names =
        paths.map((p) => quote('./${p.substring(parent.length)}')).join(' ');
    final zip = destination.toLowerCase().endsWith('.zip');
    if (!zip && !destination.toLowerCase().endsWith('.tar.gz')) {
      throw ArgumentError('Use .zip or .tar.gz');
    }
    final tool = zip ? 'zip' : 'tar';
    final operation = zip ? 'zip -r - $names' : 'tar -czf - $names';
    return 'command -v $tool >/dev/null 2>&1 || exit 127; '
        'cd ${quote(parent)} && (set -C; $operation > ${quote(destination)}) < /dev/null';
  }

  static const _formats = {
    '.tar.gz': 'tar',
    '.tar.bz2': 'tar',
    '.tar.xz': 'tar',
    '.tgz': 'tar',
    '.tbz2': 'tar',
    '.txz': 'tar',
    '.tar': 'tar',
    '.zip': 'unzip',
    '.7z': '7z',
    '.rar': 'unrar',
  };

  static String? extension(String name) {
    final lower = name.toLowerCase();
    for (final suffix in _formats.keys) {
      if (lower.endsWith(suffix)) return suffix;
    }
    return null;
  }

  static String directoryName(String name) {
    final suffix = extension(name);
    final base =
        suffix == null ? name : name.substring(0, name.length - suffix.length);
    return base.isEmpty ? 'extracted' : '$base-extracted';
  }

  static String command(String archive, String destination) {
    final suffix = extension(archive);
    if (suffix == null) throw ArgumentError('Unsupported archive format');
    for (final path in [archive, destination]) {
      if (!path.startsWith('/') ||
          path.contains('\u0000') ||
          path.split('/').contains('..')) {
        throw ArgumentError('An absolute remote path without .. is required');
      }
    }
    String quote(String value) => "'${value.replaceAll("'", "'\\''")}'";
    final tool = _formats[suffix]!;
    final source = quote(archive);
    final target = quote(destination);
    final extract = switch (tool) {
      'tar' => 'tar -xf $source -C $target',
      'unzip' => 'unzip -n $source -d $target',
      '7z' => '7z x -aos -o$target $source',
      _ => 'unrar x -o- $source ${quote('$destination/')}',
    };
    return 'command -v $tool >/dev/null 2>&1 || { echo "Missing extraction tool: $tool" >&2; exit 127; }; '
        'mkdir $target && $extract < /dev/null';
  }
}
