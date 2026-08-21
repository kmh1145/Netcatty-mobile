import 'package:flutter/material.dart';
import 'package:netcatty_mobile/presentation/localization/localized_widgets.dart';

import '../../../domain/models/host.dart';
import '../../../infrastructure/ssh/ssh_service.dart';
import '../../../infrastructure/ssh/system_management_service.dart';
import 'docker_manager_panel.dart';
import 'process_manager_panel.dart';
import 'tmux_manager_panel.dart';

class SystemManagementSheet extends StatefulWidget {
  const SystemManagementSheet({
    super.key,
    required this.session,
    required this.snippets,
    required this.onOpenTerminal,
  });

  final ActiveTerminalSession session;
  final List<CommandSnippet> snippets;
  final Future<void> Function(String label, String command) onOpenTerminal;

  @override
  State<SystemManagementSheet> createState() => _SystemManagementSheetState();
}

class _SystemManagementSheetState extends State<SystemManagementSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final _service = SystemManagementService();

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _runInteractive(String label, String command) async {
    Navigator.of(context).pop();
    await widget.onOpenTerminal(label, command);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return FractionallySizedBox(
      heightFactor: .94,
      child: Material(
        color: colors.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            const SizedBox(height: 8),
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: colors.onSurfaceVariant.withValues(alpha: .35),
                borderRadius: BorderRadius.circular(99),
              ),
            ),
            ListTile(
              leading: CircleAvatar(
                backgroundColor: colors.primaryContainer,
                foregroundColor: colors.onPrimaryContainer,
                child: const Icon(Icons.admin_panel_settings_outlined),
              ),
              title: const LText('系统管理'),
              subtitle: LText(
                '${widget.session.host.username}@${widget.session.host.hostname}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: IconButton(
                tooltip: localized('关闭'),
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ),
            TabBar(
              controller: _tabs,
              tabs: const [
                Tab(icon: Icon(Icons.account_tree_outlined), text: '进程'),
                Tab(icon: Icon(Icons.view_in_ar_outlined), text: 'Docker'),
                Tab(icon: Icon(Icons.terminal_outlined), text: 'tmux'),
              ],
            ),
            const Divider(height: 1),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: [
                  ProcessManagerPanel(
                    session: widget.session,
                    service: _service,
                  ),
                  DockerManagerPanel(
                    session: widget.session,
                    service: _service,
                    onOpenTerminal: _runInteractive,
                  ),
                  TmuxManagerPanel(
                    session: widget.session,
                    service: _service,
                    snippets: widget.snippets,
                    onOpenTerminal: _runInteractive,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
