import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/application/session_controller.dart';
import 'package:netcatty_mobile/application/settings_controller.dart';
import 'package:netcatty_mobile/application/vault_controller.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/domain/models/settings.dart';
import 'package:netcatty_mobile/infrastructure/ssh/ssh_service.dart';
import 'package:netcatty_mobile/infrastructure/storage/vault_repository.dart';
import 'package:netcatty_mobile/presentation/screens/terminal_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm2/xterm.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('pending connections remain separate selectable tabs', () {
    final host = _host('pending', '新服务器');
    final pending = PendingTerminalConnection(id: 'pending-1', host: host);
    final state = SessionState(
      pendingConnections: [pending],
      activePendingId: pending.id,
    );

    expect(state.tabCount, 1);
    expect(state.selectedPending, same(pending));
    expect(state.copyWith(activePendingId: null).selectedPending, isNull);
    expect(state.copyWith(activePendingId: null).pendingConnections, [pending]);
  });

  test('cancelling a pending connection removes its tab and stops transport',
      () async {
    SharedPreferences.setMockInitialValues({});
    final repository = await VaultRepository.open();
    final host = _host('cancel', '等待连接');
    final pending = PendingTerminalConnection(id: 'pending-cancel', host: host);
    final service = _TrackingSshService();
    final container = ProviderContainer(
      overrides: [
        vaultRepositoryProvider.overrideWithValue(repository),
        sessionControllerProvider.overrideWith(
          (ref) => _SeededSessionController(
            ref.read(vaultControllerProvider.notifier),
            ref,
            SessionState(
              pendingConnections: [pending],
              activePendingId: pending.id,
            ),
            service: service,
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    container
        .read(sessionControllerProvider.notifier)
        .cancelPendingConnection(pending.id);

    expect(service.cancelledIds, [pending.id]);
    expect(
      container.read(sessionControllerProvider).pendingConnections,
      isEmpty,
    );
    expect(container.read(sessionControllerProvider).activePendingId, isNull);
  });

  test('commands can target a captured session instead of the active tab',
      () async {
    SharedPreferences.setMockInitialValues({});
    final repository = await VaultRepository.open();
    final firstOutput = <String>[];
    final secondOutput = <String>[];
    final firstTerminal = Terminal()..onOutput = firstOutput.add;
    final secondTerminal = Terminal()..onOutput = secondOutput.add;
    final first = ActiveTerminalSession(
      id: 'session-first',
      host: HostProfile.create(
        id: 'first',
        label: 'First',
        hostname: 'first.example.com',
        username: 'root',
        port: 22022,
      ),
      terminal: firstTerminal,
      verifyHostKey: _acceptHostKey,
      keyboardInteractive: null,
    );
    final second = ActiveTerminalSession(
      id: 'session-second',
      host: _host('second', 'Second'),
      terminal: secondTerminal,
      verifyHostKey: _acceptHostKey,
      keyboardInteractive: null,
    );
    final container = ProviderContainer(
      overrides: [
        vaultRepositoryProvider.overrideWithValue(repository),
        sessionControllerProvider.overrideWith(
          (ref) => _SeededSessionController(
            ref.read(vaultControllerProvider.notifier),
            ref,
            SessionState(sessions: [first, second], activeIndex: 1),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(sessionControllerProvider.notifier);

    controller.sendToSession(first.id, 'ss -lntp');
    controller.send('pwd', enter: true);

    expect(firstOutput, ['ss -lntp']);
    expect(secondOutput, ['pwd\r']);
    expect(
      () => controller.sendToSession('closed-session', 'whoami'),
      throwsStateError,
    );
  });

  test('terminal session tabs reorder without changing the active session',
      () async {
    SharedPreferences.setMockInitialValues({});
    final repository = await VaultRepository.open();
    final first = ActiveTerminalSession(
      id: 'session-first',
      host: _host('first', 'First'),
      terminal: Terminal(),
      verifyHostKey: _acceptHostKey,
      keyboardInteractive: null,
    );
    final second = ActiveTerminalSession(
      id: 'session-second',
      host: _host('second', 'Second'),
      terminal: Terminal(),
      verifyHostKey: _acceptHostKey,
      keyboardInteractive: null,
    );
    final pending = PendingTerminalConnection(
      id: 'pending-third',
      host: _host('third', 'Third'),
    );
    final container = ProviderContainer(
      overrides: [
        vaultRepositoryProvider.overrideWithValue(repository),
        sessionControllerProvider.overrideWith(
          (ref) => _SeededSessionController(
            ref.read(vaultControllerProvider.notifier),
            ref,
            SessionState(
              sessions: [first, second],
              activeIndex: 1,
              pendingConnections: [pending],
            ),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    final controller = container.read(sessionControllerProvider.notifier);

    controller.reorderSessionTab(0, 1);
    var state = container.read(sessionControllerProvider);
    expect(state.sessions.map((session) => session.id), [second.id, first.id]);
    expect(state.active?.id, second.id);

    controller.reorderSessionTab(0, 2);
    state = container.read(sessionControllerProvider);
    expect(state.sessions.map((session) => session.id), [first.id, second.id]);
    expect(state.active?.id, second.id);
    expect(state.pendingConnections.single.id, pending.id);

    controller.reorderSessionTab(2, 0);
    expect(
      container
          .read(sessionControllerProvider)
          .sessions
          .map((session) => session.id),
      [first.id, second.id],
    );
  });

  testWidgets(
    'connection progress is a dialog in its tab and existing terminal stays usable',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final repository = await VaultRepository.open();
      final existingHost = _host('existing', '已有终端');
      final pendingHost = _host('pending', '正在连接');
      final existing = ActiveTerminalSession(
        id: 'session-1',
        host: existingHost,
        terminal: Terminal(),
        verifyHostKey: _acceptHostKey,
        keyboardInteractive: null,
      );
      existing.terminal.write('alpha beta gamma');
      final pending = PendingTerminalConnection(
        id: 'pending-1',
        host: pendingHost,
      );
      final initialState = SessionState(
        sessions: [existing],
        pendingConnections: [pending],
        activePendingId: pending.id,
      );

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            vaultRepositoryProvider.overrideWithValue(repository),
            sessionControllerProvider.overrideWith(
              (ref) => _SeededSessionController(
                ref.read(vaultControllerProvider.notifier),
                ref,
                initialState,
              ),
            ),
          ],
          child: const MaterialApp(
            home: Scaffold(body: TerminalScreen()),
          ),
        ),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('terminal-connection-status-dialog')),
        findsOneWidget,
      );
      expect(find.text('正在建立安全连接…'), findsOneWidget);
      expect(
        find.text('连接会在此标签页中完成，其他终端会话不会受到影响。'),
        findsNothing,
      );
      expect(find.text('已有终端'), findsOneWidget);
      expect(find.text('正在连接'), findsWidgets);
      expect(find.byType(ReorderableListView), findsOneWidget);
      expect(
        find.byKey(const ValueKey('terminal-tab-session-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('pending-terminal-tab-pending-1')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('cancel-pending-connection')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey('cancel-pending-connection')),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('terminal-connection-status-dialog')),
        findsNothing,
      );
      expect(find.byType(TerminalView), findsOneWidget);

      await tester.tap(find.text('已有终端'));
      await tester.pump();

      expect(
        find.byKey(const ValueKey('terminal-connection-status-dialog')),
        findsNothing,
      );
      expect(find.byType(TerminalView), findsOneWidget);
      expect(find.text('正在连接'), findsNothing);
      expect(
        tester.widget<TerminalView>(find.byType(TerminalView)).deleteDetection,
        isTrue,
      );

      final terminalState = tester.state<TerminalViewState>(
        find.byType(TerminalView),
      );
      final renderTerminal = terminalState.renderTerminal;
      final wordPosition = renderTerminal.localToGlobal(
        renderTerminal.getOffset(const CellOffset(2, 0)) +
            Offset(
              renderTerminal.cellSize.width / 2,
              renderTerminal.cellSize.height / 2,
            ),
      );
      await tester.longPressAt(wordPosition);
      await tester.pump();

      final startHandle = find.byKey(
        const ValueKey('terminal-selection-handle-start'),
      );
      final endHandle = find.byKey(
        const ValueKey('terminal-selection-handle-end'),
      );
      expect(startHandle, findsOneWidget);
      expect(endHandle, findsOneWidget);
      final endBeforeDrag = tester.getCenter(endHandle);

      await tester.drag(
        endHandle,
        Offset(renderTerminal.cellSize.width * 4, 0),
      );
      await tester.pump();

      expect(tester.getCenter(endHandle).dx, greaterThan(endBeforeDrag.dx));
      expect(
        find.byKey(const ValueKey('copy-terminal-selection')),
        findsOneWidget,
      );

      expect(
        find.byKey(const ValueKey('terminal-tab-strip')),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey('terminal-action-fullscreen')),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey('terminal-tab-strip')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('terminal-floating-performance')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('terminal-performance-monitor')),
        findsOneWidget,
      );
      expect(find.byTooltip('退出全屏'), findsOneWidget);
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      'custom background makes the xterm canvas transparent in ${brightness.name} mode',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final repository = await VaultRepository.open();
        final settingsController = _SeededSettingsController(
          repository,
          const AppSettings(
            customBackgroundEnabled: true,
            customBackgroundPath: '/app/background.jpg',
            customBackgroundScope: 'terminal',
          ),
        );
        final session = ActiveTerminalSession(
          id: 'transparent-${brightness.name}',
          host: _host('transparent', '透明终端'),
          terminal: Terminal(),
          verifyHostKey: _acceptHostKey,
          keyboardInteractive: null,
        );

        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              vaultRepositoryProvider.overrideWithValue(repository),
              settingsControllerProvider.overrideWith(
                (ref) => settingsController,
              ),
              sessionControllerProvider.overrideWith(
                (ref) => _SeededSessionController(
                  ref.read(vaultControllerProvider.notifier),
                  ref,
                  SessionState(sessions: [session]),
                ),
              ),
            ],
            child: MaterialApp(
              theme: ThemeData(brightness: brightness),
              home: const Scaffold(body: TerminalScreen()),
            ),
          ),
        );
        await tester.pump();

        final terminalView = tester.widget<TerminalView>(
          find.byType(TerminalView),
        );
        expect(terminalView.backgroundOpacity, 0);
        expect(terminalView.theme.background, isNot(Colors.transparent));
        expect(terminalView.theme.background.toARGB32() >>> 24, 255);
      },
    );
  }

  testWidgets('secure keyboard change recreates and persists the IME mode',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final repository = await VaultRepository.open();
    await repository.saveSettings(
      const AppSettings(uiThemeId: 'catppuccin', terminalFontSize: 18),
    );
    final settingsController = _SeededSettingsController(repository);
    final host = _host('secure', '安全终端');
    final session = ActiveTerminalSession(
      id: 'secure-session',
      host: host,
      terminal: Terminal(),
      verifyHostKey: _acceptHostKey,
      keyboardInteractive: null,
    );
    final initialState = SessionState(sessions: [session]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          vaultRepositoryProvider.overrideWithValue(repository),
          settingsControllerProvider.overrideWith(
            (ref) => settingsController,
          ),
          sessionControllerProvider.overrideWith(
            (ref) => _SeededSessionController(
              ref.read(vaultControllerProvider.notifier),
              ref,
              initialState,
            ),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: TerminalScreen()),
        ),
      ),
    );
    await tester.pump();

    final normalView = find.byType(TerminalView);
    expect(
      tester.widget<TerminalView>(normalView).keyboardType,
      TextInputType.emailAddress,
    );
    expect(tester.widget<TerminalView>(normalView).backgroundOpacity, 1);
    final normalState = tester.state<TerminalViewState>(normalView);

    await settingsController.updateTerminalSecureKeyboard(true);
    await tester.pump();

    final secureView = find.byType(TerminalView);
    expect(
      tester.widget<TerminalView>(secureView).keyboardType,
      TextInputType.visiblePassword,
    );
    expect(
        tester.state<TerminalViewState>(secureView), isNot(same(normalState)));
    final persisted = await repository.loadSettings();
    expect(persisted.terminalSecureKeyboard, isTrue);
    expect(persisted.uiThemeId, 'catppuccin');
    expect(persisted.terminalFontSize, 18);
  });
}

class _SeededSessionController extends SessionController {
  _SeededSessionController(
    VaultController vaultController,
    Ref ref,
    SessionState initialState, {
    SshService? service,
  }) : super(service ?? SshService(), vaultController, ref) {
    state = initialState;
  }
}

class _TrackingSshService extends SshService {
  final cancelledIds = <String>[];

  @override
  void cancelConnection(String sessionId) => cancelledIds.add(sessionId);
}

class _SeededSettingsController extends SettingsController {
  _SeededSettingsController(
    super.repository, [
    AppSettings initialState = const AppSettings(),
  ]) {
    state = initialState;
  }
}

HostProfile _host(String id, String label) => HostProfile.create(
      id: id,
      label: label,
      hostname: '$id.example.com',
      username: 'root',
    );

Future<bool> _acceptHostKey(
  HostProfile host,
  String algorithm,
  String fingerprint,
) async =>
    true;
