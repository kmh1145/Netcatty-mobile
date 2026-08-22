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

      await tester.tap(find.text('已有终端'));
      await tester.pump();

      expect(
        find.byKey(const ValueKey('terminal-connection-status-dialog')),
        findsNothing,
      );
      expect(find.byType(TerminalView), findsOneWidget);
      expect(find.text('正在连接'), findsOneWidget);
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
    SessionState initialState,
  ) : super(SshService(), vaultController, ref) {
    state = initialState;
  }
}

class _SeededSettingsController extends SettingsController {
  _SeededSettingsController(super.repository) {
    state = const AppSettings();
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
