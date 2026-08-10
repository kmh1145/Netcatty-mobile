import 'package:flutter/material.dart';

import 'screens/settings_screen.dart';
import 'screens/sftp_screen.dart';
import 'screens/snippets_screen.dart';
import 'screens/terminal_screen.dart';
import 'screens/vault_screen.dart';

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  var _index = 0;
  final _pages = const [
    VaultScreen(),
    TerminalScreen(),
    SftpScreen(),
    SnippetsScreen(),
    SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) => Scaffold(
        body: IndexedStack(index: _index, children: _pages),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: (value) => setState(() => _index = value),
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
      );
}
