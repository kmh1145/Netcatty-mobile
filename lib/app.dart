import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'application/settings_controller.dart';
import 'application/session_controller.dart';
import 'infrastructure/ssh/connection_platform_service.dart';
import 'presentation/home_shell.dart';
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
      ref.read(sessionControllerProvider.notifier).reconnectDisconnected();
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      ConnectionPlatformService.beginBackgroundGrace();
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<bool>(
      sessionControllerProvider.select(
        (value) => value.sessions.any((session) => session.connected),
      ),
      (previous, next) => ConnectionPlatformService.setActive(next),
    );
    final settings = ref.watch(settingsControllerProvider);
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
