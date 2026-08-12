import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../domain/models/host.dart';
import '../../../domain/models/system_management.dart';
import '../../../infrastructure/ssh/ssh_service.dart';
import '../../../infrastructure/ssh/system_management_service.dart';

class TmuxManagerPanel extends StatefulWidget {
  const TmuxManagerPanel({
    super.key,
    required this.session,
    required this.service,
    required this.snippets,
    required this.onOpenTerminal,
  });

  final ActiveTerminalSession session;
  final SystemManagementService service;
  final List<CommandSnippet> snippets;
  final Future<void> Function(String label, String command) onOpenTerminal;

  @override
  State<TmuxManagerPanel> createState() => _TmuxManagerPanelState();
}

class _TmuxManagerPanelState extends State<TmuxManagerPanel> {
  final _search = TextEditingController();
  Timer? _timer;
  String _version = '';
  List<TmuxSessionInfo> _sessions = const [];
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _search.addListener(_rebuild);
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _search
      ..removeListener(_rebuild)
      ..dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    if (!widget.session.connected) return;
    try {
      final version = await widget.service.tmuxVersion(widget.session);
      final sessions = await widget.service.listTmuxSessions(widget.session);
      if (!mounted) return;
      setState(() {
        _version = version;
        _sessions = sessions;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error;
      });
    }
  }

  List<TmuxSessionInfo> get _visibleSessions {
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return _sessions;
    return _sessions
        .where(
          (session) =>
              session.name.toLowerCase().contains(query) ||
              session.group.toLowerCase().contains(query),
        )
        .toList(growable: false);
  }

  Future<void> _createSession() async {
    final name = TextEditingController();
    final command = TextEditingController();
    CommandSnippet? selectedSnippet;
    final result = await showDialog<({String name, String command})>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('新建 tmux session'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'session 名称',
                    hintText: '例如 work',
                  ),
                ),
                const SizedBox(height: 12),
                if (widget.snippets.isNotEmpty) ...[
                  DropdownButtonFormField<CommandSnippet>(
                    initialValue: selectedSnippet,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: '从命令片段选择（可选）',
                    ),
                    items: widget.snippets
                        .map(
                          (snippet) => DropdownMenuItem(
                            value: snippet,
                            child: Text(
                              snippet.label,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: (snippet) {
                      setDialogState(() => selectedSnippet = snippet);
                      if (snippet != null) command.text = snippet.command;
                    },
                  ),
                  const SizedBox(height: 12),
                ],
                TextField(
                  controller: command,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: '启动命令（可选）',
                    hintText: '例如 cd /srv/app && ./start.sh',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                if (name.text.trim().isEmpty) return;
                Navigator.pop(
                  context,
                  (name: name.text.trim(), command: command.text.trim()),
                );
              },
              child: const Text('创建'),
            ),
          ],
        ),
      ),
    );
    name.dispose();
    command.dispose();
    if (result == null) return;
    try {
      await widget.service.createTmuxSession(
        widget.session,
        name: result.name,
        startupCommand: result.command,
      );
      await _refresh();
    } catch (error) {
      if (mounted) _showError(error);
    }
  }

  Future<void> _killSession(TmuxSessionInfo session) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            icon: const Icon(Icons.warning_amber_outlined),
            title: const Text('结束 tmux session？'),
            content: Text(
              '${session.name} 中的所有窗口和程序都会被终止，此操作无法撤销。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('结束 session'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    try {
      await widget.service.killTmuxSession(widget.session, session.name);
      await _refresh();
    } catch (error) {
      if (mounted) _showError(error);
    }
  }

  void _showError(Object error) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$error')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final values = _visibleSessions;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _search,
                  decoration: const InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(Icons.search),
                    hintText: '搜索 session',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _createSession,
                icon: const Icon(Icons.add),
                label: const Text('新建'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Chip(
                avatar: const Icon(Icons.terminal, size: 18),
                label: Text(_version.isEmpty ? 'tmux' : _version),
              ),
              const Spacer(),
              Text('${_sessions.length} 个 session'),
              IconButton(
                tooltip: '刷新',
                onPressed: _loading ? null : _refresh,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        if (_error != null)
          MaterialBanner(
            content: Text('tmux 读取失败：$_error'),
            actions: [
              TextButton(onPressed: _refresh, child: const Text('重试')),
            ],
          ),
        Expanded(
          child: values.isEmpty && !_loading
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.terminal_outlined, size: 48),
                      const SizedBox(height: 10),
                      Text(_error == null ? '还没有 tmux session' : '无法读取 tmux'),
                      if (_error == null)
                        TextButton.icon(
                          onPressed: _createSession,
                          icon: const Icon(Icons.add),
                          label: const Text('创建第一个 session'),
                        ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 20),
                  itemCount: values.length,
                  itemBuilder: (context, index) {
                    final session = values[index];
                    return _TmuxSessionCard(
                      key: ValueKey(session.name),
                      session: session,
                      parentSession: widget.session,
                      service: widget.service,
                      onAttach: () => widget.onOpenTerminal(
                        'tmux: ${session.name}',
                        widget.service.tmuxAttachCommand(session.name),
                      ),
                      onKill: () => _killSession(session),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _TmuxSessionCard extends StatefulWidget {
  const _TmuxSessionCard({
    super.key,
    required this.session,
    required this.parentSession,
    required this.service,
    required this.onAttach,
    required this.onKill,
  });

  final TmuxSessionInfo session;
  final ActiveTerminalSession parentSession;
  final SystemManagementService service;
  final VoidCallback onAttach;
  final VoidCallback onKill;

  @override
  State<_TmuxSessionCard> createState() => _TmuxSessionCardState();
}

class _TmuxSessionCardState extends State<_TmuxSessionCard> {
  TmuxSessionDetails? _details;
  bool _loading = false;
  Object? _error;

  Future<void> _loadDetails() async {
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final value = await widget.service.tmuxSessionDetails(
        widget.parentSession,
        widget.session.name,
      );
      if (!mounted) return;
      setState(() {
        _details = value;
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final date = widget.session.activityAt ?? widget.session.createdAt;
    return Card(
      child: ExpansionTile(
        onExpansionChanged: (expanded) {
          if (expanded) _loadDetails();
        },
        leading: CircleAvatar(
          child: Text('${widget.session.windowCount}'),
        ),
        title: Text(widget.session.name),
        subtitle: Text(
          '${widget.session.windowCount} 个窗口 · '
          '${widget.session.attachedClients} 个客户端'
          '${date == null ? '' : ' · ${DateFormat('MM-dd HH:mm').format(date)}'}',
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'attach',
              onPressed: widget.onAttach,
              icon: const Icon(Icons.login),
            ),
            IconButton(
              tooltip: '结束 session',
              onPressed: widget.onKill,
              icon: const Icon(Icons.delete_outline),
            ),
          ],
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
        children: [
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          if (_error != null)
            ListTile(
              dense: true,
              leading: const Icon(Icons.error_outline),
              title: Text('读取详情失败：$_error'),
              trailing: IconButton(
                tooltip: '重试',
                onPressed: _loadDetails,
                icon: const Icon(Icons.refresh),
              ),
            ),
          if (_details case final details?) ...[
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '窗口',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            for (final window in details.windows)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  window.active
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                ),
                title: Text('#${window.index} ${window.name}'),
                subtitle: Text(
                  '${window.paneCount} 个 pane · ${window.layout}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            const Divider(),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '已连接客户端',
                style: Theme.of(context).textTheme.titleSmall,
              ),
            ),
            if (details.clients.isEmpty)
              const ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text('没有客户端连接'),
              )
            else
              for (final client in details.clients)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.devices, size: 19),
                  title: Text(client.tty.isEmpty ? client.name : client.tty),
                  subtitle: Text(client.session),
                ),
          ],
        ],
      ),
    );
  }
}
