import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/home_navigation.dart';
import '../application/settings_controller.dart';
import '../infrastructure/ssh/terminal_picture_in_picture_service.dart';
import 'localization/localized_widgets.dart';
import 'screens/settings_screen.dart';
import 'screens/sftp_screen.dart';
import 'screens/snippets_screen.dart';
import 'screens/terminal_screen.dart';
import 'screens/vault_screen.dart';
import 'widgets/custom_background.dart';

class HomeShell extends ConsumerWidget {
  const HomeShell({super.key});

  static const _pages = [
    VaultScreen(),
    TerminalScreen(),
    SftpScreen(),
    SnippetsScreen(),
    SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final index = ref.watch(homeTabProvider);
    final terminalFullscreen = ref.watch(terminalFullscreenProvider);
    final terminalPictureInPicture =
        ref.watch(terminalPictureInPictureProvider);
    final settings = ref.watch(settingsControllerProvider);
    final customBackground = customBackgroundAppliesToTab(settings, index);
    final globalBackground = hasGlobalCustomBackground(settings);
    final hideNavigation = shouldHideHomeNavigation(
      index,
      terminalFullscreen || terminalPictureInPicture,
    );
    return PopScope(
      canPop: !hideNavigation,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop && hideNavigation) {
          if (terminalPictureInPicture) {
            ref.read(terminalPictureInPictureProvider.notifier).state = false;
            unawaited(TerminalPictureInPictureService.stop());
          } else {
            ref.read(terminalFullscreenProvider.notifier).state = false;
          }
        }
      },
      child: Scaffold(
        extendBody: globalBackground,
        body: Stack(
          fit: StackFit.expand,
          children: [
            if (customBackground) CustomBackgroundImage(settings: settings),
            Theme(
              data: customBackground
                  ? Theme.of(context).copyWith(
                      scaffoldBackgroundColor: Colors.transparent,
                      appBarTheme: Theme.of(context).appBarTheme.copyWith(
                            backgroundColor: Colors.transparent,
                          ),
                    )
                  : Theme.of(context),
              child: IndexedStack(index: index, children: _pages),
            ),
          ],
        ),
        bottomNavigationBar: hideNavigation
            ? null
            : _navigationBar(
                context,
                ref,
                index,
                transparent: globalBackground,
              ),
      ),
    );
  }

  Widget _navigationBar(
    BuildContext context,
    WidgetRef ref,
    int selectedIndex, {
    required bool transparent,
  }) {
    final navigation = NavigationBar(
      key: const ValueKey('home-navigation-bar'),
      selectedIndex: selectedIndex,
      onDestinationSelected: (value) =>
          ref.read(homeTabProvider.notifier).state = value,
      destinations: [
        NavigationDestination(
          icon: const Icon(Icons.dns_outlined),
          selectedIcon: const Icon(Icons.dns),
          label: localized('保险库'),
        ),
        NavigationDestination(
          icon: const Icon(Icons.terminal_outlined),
          selectedIcon: const Icon(Icons.terminal),
          label: localized('终端'),
        ),
        NavigationDestination(
          icon: const Icon(Icons.folder_outlined),
          selectedIcon: const Icon(Icons.folder),
          label: localized('文件'),
        ),
        NavigationDestination(
          icon: const Icon(Icons.code_outlined),
          selectedIcon: const Icon(Icons.code),
          label: localized('片段'),
        ),
        NavigationDestination(
          icon: const Icon(Icons.settings_outlined),
          selectedIcon: const Icon(Icons.settings),
          label: localized('设置'),
        ),
      ],
    );
    if (!transparent) return navigation;
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        navigationBarTheme: theme.navigationBarTheme.copyWith(
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          shadowColor: Colors.transparent,
          elevation: 0,
        ),
      ),
      child: navigation,
    );
  }
}

bool shouldHideHomeNavigation(int tabIndex, bool terminalFullscreen) =>
    tabIndex == 1 && terminalFullscreen;
