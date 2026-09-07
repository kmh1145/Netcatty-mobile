import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:dartssh2/dartssh2.dart';
import 'package:xterm2/xterm.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/infrastructure/ssh/ssh_service.dart';
import 'package:netcatty_mobile/infrastructure/ssh/file_selection.dart';
import 'package:netcatty_mobile/infrastructure/ssh/server_transfer_commands.dart';
import 'package:netcatty_mobile/infrastructure/ssh/sftp_service.dart';

void main() {
  test(
      'separate tabs of the same saved endpoint select server-local operations',
      () async {
    ActiveTerminalSession session(String id, {int port = 2222}) =>
        ActiveTerminalSession(
            id: id,
            host: HostProfile({
              'id': 'saved-host',
              'hostname': 'example.test',
              'port': port,
              'username': 'deploy'
            }),
            terminal: Terminal(),
            verifyHostKey: (_, __, ___) async => true,
            keyboardInteractive: null);
    final a = _ProbeService(session('tab-a'));
    final b = _ProbeService(session('tab-b'));
    expect(a.id, isNot(b.id));
    expect(sameTransferStorage(a, b), isTrue);
    b.session.host.data['id'] = 'duplicate-profile';
    expect(sameTransferStorage(a, b), isTrue);
    expect((await prepareTransferRoute(FileSelection(a, []), b, null)).route,
        TransferRoute.serverLocal);
    expect(sameTransferStorage(a, _ProbeService(session('tab-c', port: 22))),
        isFalse);
  });

  testWidgets('cancelling a remote copy closes its command, not the SSH client',
      (tester) async {
    final client = _CommandClient();
    final session = ActiveTerminalSession(
        id: 'tab',
        host: HostProfile(
            {'id': 'host', 'hostname': 'example.test', 'username': 'deploy'}),
        terminal: Terminal(),
        verifyHostKey: (_, __, ___) async => true,
        keyboardInteractive: null,
        sshClients: [client]);
    final server = SftpService(session);
    final token = TransferCancellationToken();
    final task = server.copyOnServer(
        const RemoteEntry(name: 'a', path: '/a', isDirectory: false, size: 1),
        server,
        '/stage/a',
        token);
    final assertion =
        expectLater(task, throwsA(isA<TransferCancelledException>()));
    await tester.pump();
    token.cancel();
    await tester.pump(const Duration(milliseconds: 250));
    await assertion;
    expect(client.command.closed, isTrue);
    expect(client.closed, isFalse);
    expect(session.connected, isTrue);
    expect(client.command.signals, contains(SSHSignal.TERM));
  });
  test('phone endpoints keep streaming, remote endpoints choose server routes',
      () async {
    final source = _Server('a')..add('/a');
    final target = _Server('b');
    final selection = FileSelection(source, [source.entries['/a']!]);
    expect((await prepareTransferRoute(selection, source, null)).route,
        TransferRoute.serverLocal);
    expect((await prepareTransferRoute(selection, target, null)).route,
        TransferRoute.serverDirect);
    target.local = true;
    expect((await prepareTransferRoute(selection, target, null)).relayReason,
        isNull);
  });

  test('failed probe requests consent; cancellation never becomes relay',
      () async {
    final source = _Server('a')
      ..add('/a')
      ..probeError = StateError('host key not trusted');
    final selection = FileSelection(source, [source.entries['/a']!]);
    final plan = await prepareTransferRoute(selection, _Server('b'), null);
    expect(plan.route, TransferRoute.phoneRelay);
    expect(plan.relayReason, contains('host key not trusted'));
    expect(source.copies, 0);
    await expectLater(
        prepareTransferRoute(
            selection, _Server('b'), TransferCancellationToken()..cancel()),
        throwsA(isA<TransferCancelledException>()));
  });

  test(
      'direct transfer rejects symlinks and batch command injection before probing',
      () async {
    final source = _Server('a')..add('/link', mode: 0xa1ff);
    expect(
        (await prepareTransferRoute(
                FileSelection(source, source.entries.values),
                _Server('b'),
                null))
            .relayReason,
        contains('regular files'));
    source.entries.clear();
    source.add('/bad\n!command');
    expect(
        (await prepareTransferRoute(
                FileSelection(source, source.entries.values),
                _Server('b'),
                null))
            .relayReason,
        contains('Newlines'));
    expect(source.probes, 0);
  });

  test(
      'same-server copy executes remotely, with no content streams or size traversal',
      () async {
    final server = _Server('same')
      ..add('/folder', directory: true)
      ..add('/folder/a');
    await transferSelection(
        FileSelection(server, [server.entries['/folder']!]), server, '/out',
        route: TransferRoute.serverLocal);
    expect(server.entries.containsKey('/out/folder/a'), isTrue);
    expect(server.entries.containsKey('/folder/a'), isTrue);
    expect(server.copies, 1);
    expect(server.lists, ['/out']);
    expect(
        server.entries.keys.any((path) => path.contains('.netcatty-transfer-')),
        isFalse);
  });

  test('same-server cut does not scan or download a directory', () async {
    final server = _Server('same')
      ..add('/folder', directory: true)
      ..add('/folder/a');
    await transferSelection(
        FileSelection(server, [server.entries['/folder']!], move: true),
        server,
        '/out',
        route: TransferRoute.serverLocal);
    expect(server.entries.containsKey('/folder'), isFalse);
    expect(server.entries.containsKey('/out/folder/a'), isTrue);
    expect(server.copies, 0);
    expect(server.lists, ['/out']);
  });

  test('direct move verifies the full tree and only then deletes the source',
      () async {
    final source = _Server('a')
      ..add('/folder', directory: true)
      ..add('/folder/a');
    final target = _Server('b');
    await transferSelection(
        FileSelection(source, [source.entries['/folder']!], move: true),
        target,
        '/out',
        route: TransferRoute.serverDirect);
    expect(source.entries, isEmpty);
    expect(target.entries.containsKey('/out/folder/a'), isTrue);
    expect(source.copies, 1);
  });

  for (final failure in [
    'command',
    'missing child',
    'source changed',
    'cancel',
    'collision'
  ]) {
    test('direct $failure preserves originals and never retries through phone',
        () async {
      final source = _Server('a')
        ..add('/folder', directory: true)
        ..add('/folder/a');
      final target = _Server('b');
      final token = TransferCancellationToken();
      source.afterCopy = (destination) {
        switch (failure) {
          case 'command':
            throw StateError('connection lost');
          case 'missing child':
            target.entries.remove('$destination/a');
          case 'source changed':
            source.add('/folder/a', size: 999);
          case 'cancel':
            token.cancel();
          case 'collision':
            target.add('/out/folder', size: 77);
        }
      };
      await expectLater(
          transferSelection(
              FileSelection(source, [source.entries['/folder']!], move: true),
              target,
              '/out',
              route: TransferRoute.serverDirect,
              cancellationToken: token),
          throwsStateError);
      expect(source.entries.containsKey('/folder/a'), isTrue);
      expect(source.copies, 1);
      expect(
          target.entries.keys
              .any((path) => path.contains('.netcatty-transfer-')),
          isTrue);
      if (failure == 'collision') {
        expect(target.entries['/out/folder']!.size, 77);
      }
    });
  }

  test('canonical path protects aliased destination within the source',
      () async {
    final server = _Server('same')..add('/folder', directory: true);
    server.aliases['/alias'] = '/folder';
    await expectLater(
        transferSelection(FileSelection(server, [server.entries['/folder']!]),
            server, '/alias',
            route: TransferRoute.serverLocal),
        throwsStateError);
    expect(server.copies, 0);
  });

  test('different endpoint aliases cannot copy a shared folder into itself',
      () async {
    final source = _Server('a')
      ..add('/folder', directory: true)
      ..add('/folder/a');
    final target = _Server('alias', shared: source.entries);
    await expectLater(
        transferSelection(FileSelection(source, [source.entries['/folder']!]),
            target, '/folder',
            route: TransferRoute.serverDirect),
        throwsStateError);
    expect(source.copies, 0);
    expect(source.entries.containsKey('/folder/a'), isTrue);
  });

  test('batch progress uses a cumulative baseline and stops after completion',
      () async {
    final server = _Server('same')
      ..add('/a', size: 5)
      ..add('/b', size: 7);
    final reports = <int>[];
    final gate = Completer<void>();
    server.copyWait = gate.future;
    final task = transferSelection(
        FileSelection(server, server.entries.values.toList()), server, '/out',
        route: TransferRoute.serverLocal, onProgress: reports.add);
    await Future<void>.delayed(const Duration(milliseconds: 1100));
    gate.complete();
    await task;
    final count = reports.length;
    await Future<void>.delayed(const Duration(milliseconds: 1050));
    expect(count, greaterThan(0));
    expect(reports.length, count);
    expect(reports.first, 5);
  });

  test('commands quote paths and pin noninteractive strict-key authentication',
      () {
    final command = ServerTransferCommands.sftp('2001:db8::1', 2222, 'deploy');
    expect(command, contains('-P 2222'));
    expect(command, contains("'deploy@[2001:db8::1]'"));
    for (final option in [
      'StrictHostKeyChecking=yes',
      'BatchMode=yes',
      'ForwardAgent=no',
      'IdentityAgent=none',
      'ControlPath=none',
      '-F /dev/null'
    ]) {
      expect(command, contains(option));
    }
    expect(() => ServerTransferCommands.sftp('a\nProxyCommand=x', 22, 'user'),
        throwsArgumentError);
    expect(() => ServerTransferCommands.sftp('host', 22, '-user'),
        throwsArgumentError);
    expect(() => ServerTransferCommands.copy('/a', '/x/../b'),
        throwsArgumentError);
    expect(ServerTransferCommands.copy("/a'\$(bad)", '/new'),
        contains("'/a'\\''\$(bad)'"));
    expect(ServerTransferCommands.move('/a', '/b'), contains('mv -nT --'));
  });

  final bash =
      Platform.isWindows ? 'C:/Program Files/Git/bin/bash.exe' : '/bin/bash';
  test('real cp/mv preserve files and reject existing destination', () async {
    final fixture =
        await Directory.systemTemp.createTemp('netcatty-copy-test-');
    try {
      final source = File('${fixture.path}/source space\u0027\u0024.txt');
      await source.writeAsString('original');
      final copied = '${fixture.path}/copy';
      var result = await Process.run(bash, [
        '-c',
        ServerTransferCommands.copy(_posix(source.path), _posix(copied))
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(await File(copied).readAsString(), 'original');
      final existing = File('${fixture.path}/existing');
      await existing.writeAsString('keep');
      result = await Process.run(bash, [
        '-c',
        ServerTransferCommands.move(_posix(copied), _posix(existing.path))
      ]);
      expect(result.exitCode, isNot(0));
      expect(await existing.readAsString(), 'keep');
      expect(await File(copied).exists(), isTrue);
    } finally {
      await fixture.delete(recursive: true);
    }
  }, skip: !File(bash).existsSync());

  // This invokes the actual OpenSSH batch parser and SFTP server without a
  // network login. It catches quoting/globbing bugs that command-string tests miss.
  test('real OpenSSH SFTP uploads a literal glob filename and a directory',
      () async {
    final fixture =
        await Directory.systemTemp.createTemp('netcatty-sftp-test-');
    try {
      final file = File('${fixture.path}/a[1]\u0027\u0024.txt');
      await file.writeAsString('literal');
      await File('${fixture.path}/a1\u0027\u0024.txt')
          .writeAsString('wrong glob');
      final dir = await Directory('${fixture.path}/directory space').create();
      await File('${dir.path}/child').writeAsString('nested');
      final process = await Process.start(
          bash, ['-c', '/usr/bin/sftp -D /usr/lib/ssh/sftp-server -b -']);
      final stdout = process.stdout.transform(utf8.decoder).join();
      final stderr = process.stderr.transform(utf8.decoder).join();
      process.stdin.write(ServerTransferCommands.upload(
                  _posix(file.path), _posix('${fixture.path}/out'), false)
              .replaceAll('bye\n', '') +
          ServerTransferCommands.upload(
              _posix(dir.path), _posix('${fixture.path}/tree'), true));
      await process.stdin.close();
      final code = await process.exitCode;
      expect(code, 0, reason: '${await stdout}\n${await stderr}');
      expect(await File('${fixture.path}/out').readAsString(), 'literal');
      expect(await File('${fixture.path}/tree/child').readAsString(), 'nested');
    } finally {
      await fixture.delete(recursive: true);
    }
  },
      skip: !Platform.isWindows ||
          !File('C:/Program Files/Git/usr/lib/ssh/sftp-server.exe')
              .existsSync());
}

String _posix(String path) {
  final value = path.replaceAll('\\', '/');
  return Platform.isWindows
      ? '/${value[0].toLowerCase()}${value.substring(2)}'
      : value;
}

class _ProbeService extends SftpService {
  _ProbeService(super.session);
  @override
  Future<void> probeServerTransfer(
      FileTransferService target, TransferCancellationToken? token) async {}
}

class _CommandClient extends Fake implements SSHClient {
  final command = _CommandSession();
  bool closed = false;
  @override
  Future<SSHSession> execute(String command,
          {Map<String, String>? environment,
          SSHPtyConfig? pty,
          SSHX11Config? x11}) async =>
      this.command;
  @override
  void close() {
    closed = true;
  }
}

class _CommandSession extends Fake implements SSHSession {
  _CommandSession() {
    input.stream.listen((_) {});
  }
  final input = StreamController<Uint8List>();
  final completion = Completer<void>();
  final signals = <SSHSignal>[];
  bool closed = false;
  @override
  StreamSink<Uint8List> get stdin => input.sink;
  @override
  Stream<Uint8List> get stdout => const Stream.empty();
  @override
  Stream<Uint8List> get stderr => const Stream.empty();
  @override
  Future<void> get done => completion.future;
  @override
  int? get exitCode => 0;
  @override
  void kill(SSHSignal signal) => signals.add(signal);
  @override
  void close() {
    closed = true;
    if (!completion.isCompleted) completion.complete();
  }
}

class _Server extends FileTransferService {
  _Server(this.id, {Map<String, RemoteEntry>? shared}) : entries = shared ?? {};
  @override
  final String id;
  bool local = false;
  Object? probeError;
  int copies = 0, probes = 0;
  final Map<String, RemoteEntry> entries;
  final lists = <String>[];
  final aliases = <String, String>{};
  void Function(String)? afterCopy;
  Future<void>? copyWait;
  void add(String path, {bool directory = false, int size = 10, int? mode}) {
    entries[path] = RemoteEntry(
        name: path.split('/').last,
        path: path,
        isDirectory: directory,
        size: size,
        unixMode: mode);
  }

  @override
  bool get isLocal => local;
  @override
  bool get supportsServerTransfer => true;
  @override
  String get displayName => id;
  @override
  String get rootPath => '/';
  @override
  String displayPath(String path) => path;
  @override
  String joinPath(String path, String name) =>
      '${path == '/' ? '' : path}/$name';
  @override
  String parentPath(String path) =>
      path.substring(0, path.lastIndexOf('/')).isEmpty
          ? '/'
          : path.substring(0, path.lastIndexOf('/'));
  @override
  Future<String> canonicalPath(String path) async => aliases[path] ?? path;
  @override
  Future<List<RemoteEntry>> list(String path) async {
    lists.add(path);
    return entries.values.where((e) => parentPath(e.path) == path).toList();
  }

  @override
  Future<void> probeServerTransfer(
      FileTransferService target, TransferCancellationToken? token) async {
    probes++;
    if (probeError != null) throw probeError!;
  }

  @override
  Future<void> copyOnServer(RemoteEntry entry, FileTransferService target,
      String destination, TransferCancellationToken? token) async {
    copies++;
    final other = target as _Server;
    for (final item in entries.values.toList().where(
        (e) => e.path == entry.path || e.path.startsWith('${entry.path}/'))) {
      other.add(destination + item.path.substring(entry.path.length),
          directory: item.isDirectory, size: item.size);
    }
    if (copyWait != null) await copyWait;
    afterCopy?.call(destination);
  }

  @override
  Future<void> moveOnServer(
      String from, String to, TransferCancellationToken? token) async {
    if (entries.containsKey(to)) throw StateError('destination exists');
    final moved = entries.values
        .where((e) => e.path == from || e.path.startsWith('$from/'))
        .toList();
    for (final item in moved) {
      entries.remove(item.path);
      add(to + item.path.substring(from.length),
          directory: item.isDirectory, size: item.size);
    }
  }

  @override
  Future<void> mkdir(String path) async => add(path, directory: true);
  @override
  Future<void> ensureDirectory(String path) => mkdir(path);
  @override
  Future<void> delete(RemoteEntry entry) async => entries.removeWhere(
      (path, _) => path == entry.path || path.startsWith('${entry.path}/'));
  @override
  Future<void> setPermissions(String path, int mode) async {}
  @override
  Future<int?> fileSize(String path) async => entries[path]?.size;
  @override
  Future<void> rename(String from, String to) => moveOnServer(from, to, null);
  @override
  Stream<Uint8List> readStream(String path,
          {int startOffset = 0, TransferProgressCallback? onProgress}) =>
      throw StateError('Phone download must not be used');
  @override
  Future<void> writeStream(String path, Stream<Uint8List> stream,
          {int startOffset = 0,
          bool truncate = true,
          TransferProgressCallback? onProgress}) =>
      throw StateError('Phone upload must not be used');
}
