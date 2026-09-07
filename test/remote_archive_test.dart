import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/infrastructure/ssh/remote_archive.dart';

void main() {
  test('compression quotes input paths and never overwrites an archive', () {
    final command = RemoteArchive.compressCommand(
        ["/data/a'b.txt", '/data/--help', r'/data/$(echo bad)'],
        '/data/out.zip');
    expect(command, contains('command -v zip'));
    expect(command, contains("'./a'\\''b.txt'"));
    expect(command, contains("'./--help'"));
    expect(command, contains('set -C;'));
    expect(RemoteArchive.compressCommand(['/data/a'], '/data/out.tar.gz'),
        contains("tar -czf - './a'"));
    for (final output in ['/data/a/out.zip', '/data/../out.zip', '/out.rar']) {
      expect(() => RemoteArchive.compressCommand(['/data/a'], output),
          throwsArgumentError);
    }
    expect(
        () =>
            RemoteArchive.compressCommand(['/data/a', '/other/b'], '/out.zip'),
        throwsArgumentError);
  });
  test('recognizes compound and case-insensitive archive suffixes', () {
    expect(RemoteArchive.extension('Backup.TAR.GZ'), '.tar.gz');
    expect(RemoteArchive.directoryName('Backup.TAR.GZ'), 'Backup-extracted');
    expect(RemoteArchive.extension('image.png'), isNull);
    expect(RemoteArchive.extension('fake.zip.txt'), isNull);
    for (final suffix in [
      '.zip',
      '.tar',
      '.tgz',
      '.tar.bz2',
      '.tar.xz',
      '.7z',
      '.rar'
    ]) {
      expect(RemoteArchive.extension('backup$suffix'), suffix);
    }
  });

  test('checks tools and requires a new destination before extracting', () {
    final command = RemoteArchive.command('/backup/a.zip', '/backup/new');
    expect(command, contains('command -v unzip'));
    expect(command, contains("mkdir '/backup/new' && unzip -n"));
    expect(command, endsWith('< /dev/null'));
    expect(command, isNot(contains('mkdir -p')));
    expect(RemoteArchive.command('/a.tar.gz', '/new'),
        contains("tar -xf '/a.tar.gz' -C '/new'"));
    expect(
        RemoteArchive.command('/a.7z', '/new'), contains("7z x -aos -o'/new'"));
    expect(RemoteArchive.command('/a.rar', '/new'),
        contains("unrar x -o- '/a.rar' '/new/'"));
  });

  test('quotes spaces, quotes and shell substitutions as literal paths', () {
    final command =
        RemoteArchive.command("/a'b \$(touch bad).zip", '/new; echo bad');
    expect(command, contains("'/a'\\''b \$(touch bad).zip'"));
    expect(command, contains("mkdir '/new; echo bad' &&"));
  });

  test('rejects unsupported formats and non-absolute or unsafe paths', () {
    expect(() => RemoteArchive.command('/a.txt', '/new'), throwsArgumentError);
    for (final path in ['-folder', '/a/../b', '/a\u0000b']) {
      expect(() => RemoteArchive.command('/a.zip', path), throwsArgumentError);
    }
    expect(() => RemoteArchive.command('a.zip', '/new'), throwsArgumentError);
  });
}
