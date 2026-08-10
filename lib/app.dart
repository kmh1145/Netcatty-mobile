import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'application/settings_controller.dart';
import 'presentation/home_shell.dart';
import 'presentation/theme.dart';

class NetcattyApp extends ConsumerWidget {
  const NetcattyApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(settingsControllerProvider);
    final mode = switch (settings.themeMode) {
      'light' => ThemeMode.light,
      'system' => ThemeMode.system,
      _ => ThemeMode.dark,
    };
    return MaterialApp(
      title: 'Netcatty',
      debugShowCheckedModeBanner: false,
      theme: NetcattyTheme.light,
      darkTheme: NetcattyTheme.dark,
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
