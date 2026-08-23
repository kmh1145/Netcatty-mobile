import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'application/settings_controller.dart';
import 'application/session_controller.dart';
import 'infrastructure/ssh/connection_platform_service.dart';
import 'presentation/home_shell.dart';
import 'presentation/localization/localized_widgets.dart';
import 'presentation/theme.dart';

class NetcattyApp extends ConsumerStatefulWidget {
  const NetcattyApp({super.key});

  @override
  ConsumerState<NetcattyApp> createState() => _NetcattyAppState();
}

class _NetcattyAppState extends ConsumerState<NetcattyApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ConnectionPlatformService.endBackgroundGrace();
      ref.read(sessionControllerProvider.notifier).setBackgrounded(false);
    } else if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      ConnectionPlatformService.beginBackgroundGrace();
      if (state != AppLifecycleState.inactive) {
        ref.read(sessionControllerProvider.notifier).setBackgrounded(true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(
      sessionControllerProvider.select(
        // Start while the user-initiated connection is still in the foreground;
        // Android 12+ can reject a service first started after the app is hidden.
        // A disconnected tab also keeps it alive so recovery retains CPU time.
        (value) =>
            value.sessions.isNotEmpty ||
            value.pendingConnections.any(
              (connection) =>
                  connection.phase == PendingConnectionPhase.connecting,
            ),
      ),
      (previous, next) => ConnectionPlatformService.setActive(next),
    );
    final settings = ref.watch(settingsControllerProvider);
    NetcattyLocalizations.use(settings.language);
    final mode = switch (settings.themeMode) {
      'light' => ThemeMode.light,
      'system' => ThemeMode.system,
      _ => ThemeMode.dark,
    };
    return MaterialApp(
      title: 'Netcatty',
      debugShowCheckedModeBanner: false,
      theme: NetcattyTheme.build(Brightness.light, settings.uiThemeId),
      darkTheme: NetcattyTheme.build(Brightness.dark, settings.uiThemeId),
      themeMode: mode,
      locale: settings.language == 'en'
          ? const Locale('en')
          : const Locale('zh', 'CN'),
      supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const HomeShell(),
    );
  }
}
