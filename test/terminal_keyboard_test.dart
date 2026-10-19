import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/application/session_controller.dart';
import 'package:netcatty_mobile/application/settings_controller.dart';
import 'package:netcatty_mobile/application/vault_controller.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/infrastructure/ssh/ssh_service.dart';
import 'package:netcatty_mobile/infrastructure/storage/vault_repository.dart';
import 'package:netcatty_mobile/presentation/screens/terminal_screen.dart';
import 'package:netcatty_mobile/presentation/widgets/terminal_keyboard_toggle.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm2/xterm.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('TerminalKeyboardToggle', () {
    test('does nothing until a pane is attached', () {
      final toggle = TerminalKeyboardToggle();

      expect(toggle.isAttached, isFalse);
      toggle.toggle();
      expect(toggle.isOpen, isFalse);
    });

    test('opens then closes the attached pane', () {
      final toggle = TerminalKeyboardToggle();
      var opens = 0;
      var closes = 0;
      toggle.attach(
        onOpen: () => opens++,
        onClose: () => closes++,
      );

      toggle.toggle();
      expect(toggle.isOpen, isTrue);
      expect(opens, 1);
      expect(closes, 0);

      toggle.toggle();
      expect(toggle.isOpen, isFalse);
      expect(closes, 1);
    });

    test('markClosed resets the state after a platform dismissal', () {
      final toggle = TerminalKeyboardToggle()
        ..attach(onOpen: () {}, onClose: () {});
      toggle.toggle();

      toggle.markClosed();

      expect(toggle.isOpen, isFalse);
    });

    test('markClosed is a no-op when the keyboard is already closed', () {
      final toggle = TerminalKeyboardToggle();
      var notifications = 0;
      toggle.addListener(() => notifications++);

      toggle.markClosed();

      expect(notifications, 0);
    });

    test('detach drops the pane callbacks', () {
      final toggle = TerminalKeyboardToggle()
        ..attach(onOpen: () {}, onClose: () {});
      toggle.detach();

      expect(toggle.isAttached, isFalse);
      expect(toggle.isOpen, isFalse);
    });
  });

  group('terminal soft keyboard', () {
    testWidgets('tapping the terminal does not open the keyboard',
        (tester) async {
      await _pumpTerminal(tester);

      expect(tester.testTextInput.isVisible, isFalse);

      await tester.tapAt(tester.getCenter(find.byType(TerminalView)));
      await tester.pumpAndSettle();

      expect(tester.testTextInput.isVisible, isFalse);
    });

    testWidgets('scrolling the terminal does not open the keyboard',
        (tester) async {
      await _pumpTerminal(tester);

      await tester.drag(find.byType(TerminalView), const Offset(0, -120));
      await tester.pumpAndSettle();

      expect(tester.testTextInput.isVisible, isFalse);
    });

    testWidgets('the keyboard button opens and closes the keyboard',
        (tester) async {
      await _pumpTerminal(tester);
      final button = find.byKey(
        const ValueKey('terminal-action-hide-keyboard'),
      );

      expect(find.byTooltip('显示键盘'), findsOneWidget);

      await tester.tap(button);
      await tester.pumpAndSettle();

      expect(tester.testTextInput.isVisible, isTrue);
      expect(find.byTooltip('收起键盘'), findsOneWidget);

      await tester.tap(button);
      await tester.pumpAndSettle();

      expect(tester.testTextInput.isVisible, isFalse);
      expect(find.byTooltip('显示键盘'), findsOneWidget);
    });

    testWidgets('tapping the terminal keeps an open keyboard open',
        (tester) async {
      await _pumpTerminal(tester);

      await tester.tap(
        find.byKey(const ValueKey('terminal-action-hide-keyboard')),
      );
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isTrue);

      await tester.tapAt(tester.getCenter(find.byType(TerminalView)));
      await tester.pumpAndSettle();

      expect(tester.testTextInput.isVisible, isTrue);
    });
  });
}

Future<void> _pumpTerminal(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final repository = await VaultRepository.open();
  final session = ActiveTerminalSession(
    id: 'keyboard-session',
    host: HostProfile.create(
      id: 'keyboard-host',
      label: '键盘测试',
      hostname: 'keyboard.example.com',
      username: 'demo',
    ),
    terminal: Terminal(),
    verifyHostKey: (host, algorithm, fingerprint) async => true,
    keyboardInteractive: null,
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        vaultRepositoryProvider.overrideWithValue(repository),
        settingsControllerProvider.overrideWith(
          (ref) => _SeededSettingsController(repository),
        ),
        sessionControllerProvider.overrideWith(
          (ref) => _SeededSessionController(
            ref.read(vaultControllerProvider.notifier),
            ref,
            SessionState(sessions: [session]),
          ),
        ),
      ],
      child: const MaterialApp(
        home: Scaffold(body: TerminalScreen()),
      ),
    ),
  );
  await tester.pump();
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
  _SeededSettingsController(super.repository);
}
