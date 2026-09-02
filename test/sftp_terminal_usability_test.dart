import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/application/settings_controller.dart';
import 'package:netcatty_mobile/domain/models/settings.dart';
import 'package:netcatty_mobile/infrastructure/storage/vault_repository.dart';
import 'package:netcatty_mobile/infrastructure/ssh/sftp_service.dart';
import 'package:netcatty_mobile/infrastructure/ssh/ssh_service.dart';
import 'package:netcatty_mobile/infrastructure/ssh/terminal_picture_in_picture_service.dart';
import 'package:netcatty_mobile/presentation/home_shell.dart';
import 'package:netcatty_mobile/presentation/screens/sftp_screen.dart';
import 'package:netcatty_mobile/presentation/widgets/terminal_special_keys.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm2/xterm.dart';

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

  test('terminal font size supports 6 and clamps invalid stored values', () {
    expect(minTerminalFontSize, 6);
    expect(
      AppSettings.fromJson({'terminalFontSize': 6}).terminalFontSize,
      6,
    );
    expect(
      AppSettings.fromJson({'terminalFontSize': 2}).terminalFontSize,
      6,
    );
    expect(
      AppSettings.fromJson({'terminalFontSize': 30}).terminalFontSize,
      24,
    );
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

    final progress = <int>[];
    expect(await calculateTransferSize(source, entry), 4);
    final transferred = await transferEntry(
      source,
      entry,
      target,
      '/incoming',
      onProgress: progress.add,
    );

    expect(target.directories, contains('/incoming/logs'));
    expect(target.files['/incoming/logs/app.log'], [1, 2, 3, 4]);
    expect(transferred, 4);
    expect(progress, isNotEmpty);
    expect(progress.last, 4);
  });

  test('typed file chunks are reused without an extra memory copy', () async {
    final chunk = Uint8List.fromList([1, 2, 3]);

    final normalized = await asUint8ListStream(
      Stream<List<int>>.value(chunk),
    ).single;

    expect(identical(normalized, chunk), isTrue);
  });

  test('SFTP Unix permissions parse, format, and reject invalid values', () {
    expect(parseUnixPermissions('644'), 0x1a4);
    expect(parseUnixPermissions('0755'), 0x1ed);
    expect(parseUnixPermissions(' 700 '), 0x1c0);
    expect(parseUnixPermissions('888'), isNull);
    expect(parseUnixPermissions('64'), isNull);
    expect(parseUnixPermissions('07555'), isNull);
    expect(formatUnixPermissions(0x81a4), '644');
    expect(formatUnixPermissions(0x1ed), '755');
  });

  test('SFTP terminal directory path is safely quoted for POSIX shells', () {
    expect(quoteSftpTerminalPath('/srv/My Files'), "'/srv/My Files'");
    expect(
      quoteSftpTerminalPath("/srv/user's files"),
      "'/srv/user'\\''s files'",
    );
  });

  testWidgets(
    'SFTP uses a transparent title bar and switches between two and one pane',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final repository = await VaultRepository.open();
      final settingsController = _SeededSettingsController(
        repository,
        const AppSettings(
          customBackgroundEnabled: true,
          customBackgroundPath: '/app/background.jpg',
          customBackgroundScope: 'global',
        ),
      );
      final localService = _MemoryMountableTransferService('local');

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            vaultRepositoryProvider.overrideWithValue(repository),
            settingsControllerProvider.overrideWith(
              (ref) => settingsController,
            ),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SftpScreen(localService: Future.value(localService)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('SFTP文件管理'), findsOneWidget);
      expect(find.byKey(const ValueKey('sftp-left-pane')), findsOneWidget);
      expect(find.byKey(const ValueKey('sftp-right-pane')), findsOneWidget);
      expect(
        tester
            .widget<Material>(find.byKey(const ValueKey('sftp-title-bar')))
            .color,
        Colors.transparent,
      );

      await tester.tap(find.byKey(const ValueKey('sftp-pane-mode-toggle')));
      await tester.pump();

      expect(find.byKey(const ValueKey('sftp-left-pane')), findsOneWidget);
      expect(find.byKey(const ValueKey('sftp-right-pane')), findsNothing);
      expect(find.text('当前'), findsOneWidget);
    },
  );

  testWidgets('quick key region keeps exactly six adaptive columns',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 320,
                child: TerminalSpecialKeys(
                  order: defaultTerminalQuickKeys,
                  customKeys: [],
                  inputController: TerminalInputController(),
                  onSend: _ignoreSend,
                  onAi: _ignore,
                  onPortForward: null,
                  onSystemManagement: null,
                  pictureInPicture: false,
                  onPictureInPicture: _ignore,
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

    final firstRow = ['Esc', 'Alt', 'Home', '↑', 'End'];
    final firstRowY = [
      for (final label in firstRow) tester.getCenter(find.text(label)).dy,
      tester.getCenter(find.byTooltip('粘贴')).dy,
    ];
    expect(
      firstRowY.every((y) => (y - firstRowY.first).abs() < 1),
      isTrue,
    );
    final secondRowY = ['Tab', 'Ctrl', '←', '↓', '→', 'Shift']
        .map((label) => tester.getCenter(find.text(label)).dy)
        .toList();
    expect(
      secondRowY.every((y) => (y - secondRowY.first).abs() < 1),
      isTrue,
    );
    expect(secondRowY.first, greaterThan(firstRowY.first));
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
      'terminal-action-picture-in-picture',
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
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('全屏'), findsOneWidget);
    expect(find.byTooltip('画中画'), findsOneWidget);
  });

  test('terminal PiP text keeps only the most recent visible lines', () {
    final terminal = Terminal(maxLines: 100);
    terminal.write('one\r\ntwo\r\nthree\r\nfour');

    expect(
      terminalPictureInPictureText(terminal, maxLines: 3),
      'two\nthree\nfour',
    );
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
  Stream<Uint8List> readStream(
    String path, {
    int startOffset = 0,
    TransferProgressCallback? onProgress,
  }) {
    final value = files[path]!;
    final stream = Stream.value(
      Uint8List.sublistView(
        value,
        startOffset.clamp(0, value.length),
      ),
    );
    return onProgress == null
        ? stream
        : trackTransferProgress(stream, onProgress);
  }

  @override
  Future<void> writeStream(
    String path,
    Stream<Uint8List> stream, {
    int startOffset = 0,
    bool truncate = true,
    TransferProgressCallback? onProgress,
  }) async {
    final builder = BytesBuilder(copy: false);
    if (!truncate && startOffset > 0 && files[path] != null) {
      builder.add(Uint8List.sublistView(files[path]!, 0, startOffset));
    }
    await for (final chunk in stream) {
      builder.add(chunk);
      onProgress?.call(builder.length);
    }
    files[path] = builder.takeBytes();
  }

  @override
  Future<int?> fileSize(String path) async => files[path]?.length;

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

class _MemoryMountableTransferService extends _MemoryTransferService
    implements MountableFileTransferService {
  _MemoryMountableTransferService(super.name);

  @override
  bool get isLocal => true;

  @override
  bool get isMounted => true;

  @override
  String? get mountedDirectoryName => name;

  @override
  bool get usesAppDocuments => true;

  @override
  Future<bool> mount() async => true;
}

class _SeededSettingsController extends SettingsController {
  _SeededSettingsController(super.repository, AppSettings initialState) {
    state = initialState;
  }
}
