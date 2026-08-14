import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../infrastructure/ssh/terminal_picture_in_picture_service.dart';
import 'screens/settings_screen.dart';
import 'screens/sftp_screen.dart';
import 'screens/snippets_screen.dart';
import 'screens/terminal_screen.dart';
import 'screens/vault_screen.dart';

final homeTabProvider = StateProvider<int>((ref) => 0);

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
        body: IndexedStack(index: index, children: _pages),
        bottomNavigationBar: hideNavigation
            ? null
            : NavigationBar(
                key: const ValueKey('home-navigation-bar'),
                selectedIndex: index,
                onDestinationSelected: (value) =>
                    ref.read(homeTabProvider.notifier).state = value,
                destinations: const [
                  NavigationDestination(
                    icon: Icon(Icons.dns_outlined),
                    selectedIcon: Icon(Icons.dns),
                    label: '保险库',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.terminal_outlined),
                    selectedIcon: Icon(Icons.terminal),
                    label: '终端',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.folder_outlined),
                    selectedIcon: Icon(Icons.folder),
                    label: '文件',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.code_outlined),
                    selectedIcon: Icon(Icons.code),
                    label: '片段',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.settings_outlined),
                    selectedIcon: Icon(Icons.settings),
                    label: '设置',
                  ),
                ],
              ),
      ),
    );
  }
}

bool shouldHideHomeNavigation(int tabIndex, bool terminalFullscreen) =>
    tabIndex == 1 && terminalFullscreen;
