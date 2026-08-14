import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/domain/models/settings.dart';
import 'package:netcatty_mobile/infrastructure/ssh/sftp_service.dart';
import 'package:netcatty_mobile/presentation/home_shell.dart';
import 'package:netcatty_mobile/presentation/widgets/terminal_special_keys.dart';

void main() {
  test('home navigation only hides for a fullscreen terminal', () {
    expect(shouldHideHomeNavigation(1, true), isTrue);
    expect(shouldHideHomeNavigation(1, false), isFalse);
    expect(shouldHideHomeNavigation(2, true), isFalse);
  });

  test('legacy default quick keys migrate to the new mobile defaults', () {
    final settings = AppSettings.fromJson({
      'terminalQuickKeys': legacyDefaultTerminalQuickKeys,
    });

    expect(settings.terminalQuickKeys, defaultTerminalQuickKeys);
    expect(settings.terminalQuickKeys, containsAll(['alt', 'ctrl', 'shift']));
    expect(settings.terminalQuickKeys, containsAll(['home', 'end', 'paste']));
  });

  test('previous mobile defaults migrate to the screenshot ordering', () {
    final settings = AppSettings.fromJson({
      'terminalQuickKeys': previousMobileDefaultTerminalQuickKeys,
    });

    expect(settings.terminalQuickKeys, defaultTerminalQuickKeys);
    expect(settings.terminalQuickKeys, [
      'escape',
      'alt',
      'home',
      'arrowUp',
      'end',
      'paste',
      'tab',
      'ctrl',
      'arrowLeft',
      'arrowDown',
      'arrowRight',
      'shift',
    ]);
  });

  test('custom terminal keys and their ordering round-trip', () {
    final settings = AppSettings.fromJson({
      'terminalQuickKeys': ['escape', 'custom-clear'],
      'terminalCustomKeys': [
        {
          'id': 'custom-clear',
          'label': '清屏',
          'value': r'clear\n',
        },
      ],
    });

    expect(settings.terminalQuickKeys, ['escape', 'custom-clear']);
    expect(settings.terminalCustomKeys.single.label, '清屏');
    expect(
      (settings.toJson()['terminalCustomKeys'] as List).single,
      {'id': 'custom-clear', 'label': '清屏', 'value': r'clear\n'},
    );
  });

  test('custom key escape sequences decode before sending', () {
    expect(decodeTerminalKeyEscapes(r'clear\n'), 'clear\n');
    expect(decodeTerminalKeyEscapes(r'\e[A'), '\x1b[A');
    expect(decodeTerminalKeyEscapes(r'\x03'), '\x03');
  });

  test('files and folders stream between independent services', () async {
    final source = _MemoryTransferService('source')
      ..directories.add('/logs')
      ..files['/logs/app.log'] = Uint8List.fromList([1, 2, 3, 4]);
    final target = _MemoryTransferService('target')
      ..directories.add('/incoming');
    const entry = RemoteEntry(
      name: 'logs',
      path: '/logs',
      isDirectory: true,
      size: 0,
    );

    await transferEntry(source, entry, target, '/incoming');

    expect(target.directories, contains('/incoming/logs'));
    expect(target.files['/incoming/logs/app.log'], [1, 2, 3, 4]);
  });

  testWidgets('quick key region wraps without horizontal scrolling',
      (tester) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 360,
                child: TerminalSpecialKeys(
                  order: defaultTerminalQuickKeys,
                  customKeys: [],
                  onSend: _ignoreSend,
                  onAi: _ignore,
                  onPortForward: null,
                  onSystemManagement: null,
                  fullscreen: false,
                  onFullscreen: _ignore,
                  split: false,
                  onSplit: null,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byType(Wrap), findsOneWidget);
    expect(
      tester.getTopLeft(find.byTooltip('粘贴')).dy,
      closeTo(tester.getTopLeft(find.text('Esc')).dy, 1),
    );
    final escButton = find.ancestor(
      of: find.text('Esc'),
      matching: find.byType(TextButton),
    );
    final homeButton = find.ancestor(
      of: find.text('Home'),
      matching: find.byType(TextButton),
    );
    expect(
      tester.getSize(escButton).width,
      closeTo(tester.getSize(homeButton).width, .01),
    );
    final actionKeys = [
      'terminal-action-ai',
      'terminal-action-port-forward',
      'terminal-action-system-management',
      'terminal-action-fullscreen',
      'terminal-action-split',
      'terminal-action-edit',
      'terminal-action-hide-keyboard',
    ];
    final actionCenters = actionKeys
        .map((key) => tester.getCenter(find.byKey(ValueKey(key))).dx)
        .toList();
    final actionGaps = [
      for (var index = 1; index < actionCenters.length; index++)
        actionCenters[index] - actionCenters[index - 1],
    ];
    expect(
      actionGaps.every((gap) => (gap - actionGaps.first).abs() < .01),
      isTrue,
    );
    expect(
      actionCenters[actionKeys.indexOf('terminal-action-edit')],
      lessThan(
        actionCenters[actionKeys.indexOf('terminal-action-hide-keyboard')],
      ),
    );
    expect(
      find.descendant(
        of: find.byType(TerminalSpecialKeys),
        matching: find.byType(Scrollable),
      ),
      findsNothing,
    );
    expect(find.byTooltip('全屏'), findsOneWidget);
  });
}

void _ignore() {}
void _ignoreSend(String value, {bool enter = false}) {}

class _MemoryTransferService extends FileTransferService {
  _MemoryTransferService(this.name) {
    directories.add('/');
  }

  final String name;
  final Map<String, Uint8List> files = {};
  final Set<String> directories = {};

  @override
  String get id => name;
  @override
  String get displayName => name;
  @override
  String get rootPath => '/';
  @override
  bool get isLocal => false;

  @override
  String displayPath(String path) => path;

  @override
  String joinPath(String path, String name) =>
      path == '/' ? '/$name' : '$path/$name';

  @override
  String parentPath(String path) {
    final separator = path.lastIndexOf('/');
    return separator <= 0 ? '/' : path.substring(0, separator);
  }

  @override
  Future<List<RemoteEntry>> list(String path) async {
    final prefix = path == '/' ? '/' : '$path/';
    final result = <RemoteEntry>[];
    for (final directory in directories) {
      if (directory == path ||
          !directory.startsWith(prefix) ||
          directory.substring(prefix.length).contains('/')) {
        continue;
      }
      result.add(RemoteEntry(
        name: directory.substring(prefix.length),
        path: directory,
        isDirectory: true,
        size: 0,
      ));
    }
    for (final file in files.entries) {
      if (!file.key.startsWith(prefix) ||
          file.key.substring(prefix.length).contains('/')) {
        continue;
      }
      result.add(RemoteEntry(
        name: file.key.substring(prefix.length),
        path: file.key,
        isDirectory: false,
        size: file.value.length,
      ));
    }
    return result;
  }

  @override
  Stream<Uint8List> readStream(String path) => Stream.value(files[path]!);

  @override
  Future<void> writeStream(String path, Stream<Uint8List> stream) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in stream) {
      builder.add(chunk);
    }
    files[path] = builder.takeBytes();
  }

  @override
  Future<void> mkdir(String path) async => directories.add(path);

  @override
  Future<void> ensureDirectory(String path) async => directories.add(path);

  @override
  Future<void> rename(String from, String to) async {
    final file = files.remove(from);
    if (file != null) files[to] = file;
  }

  @override
  Future<void> delete(RemoteEntry entry) async {
    files.remove(entry.path);
    directories.remove(entry.path);
  }
}
