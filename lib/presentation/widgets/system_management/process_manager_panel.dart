import 'dart:async';

import 'package:flutter/material.dart';
import 'package:netcatty_mobile/presentation/localization/localized_widgets.dart';

import '../../../domain/models/system_management.dart';
import '../../../infrastructure/ssh/ssh_service.dart';
import '../../../infrastructure/ssh/system_management_service.dart';

class ProcessManagerPanel extends StatefulWidget {
  const ProcessManagerPanel({
    super.key,
    required this.session,
    required this.service,
  });

  final ActiveTerminalSession session;
  final SystemManagementService service;

  @override
  State<ProcessManagerPanel> createState() => _ProcessManagerPanelState();
}

class _ProcessManagerPanelState extends State<ProcessManagerPanel> {
  final _search = TextEditingController();
  Timer? _timer;
  List<RemoteProcess> _processes = const [];
  ProcessSortKey _sort = ProcessSortKey.cpu;
  bool _ascending = false;
  bool _runningOnly = false;
  bool _loading = true;
  bool _refreshing = false;
  Object? _error;
  bool _actionBusy = false;

  @override
  void initState() {
    super.initState();
    _search.addListener(_rebuild);
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
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
    if (_refreshing || _actionBusy || !widget.session.connected) return;
    _refreshing = true;
    try {
      final values = await widget.service.listProcesses(widget.session);
      if (!mounted) return;
      setState(() {
        _processes = values;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error;
      });
    } finally {
      _refreshing = false;
    }
  }

  List<RemoteProcess> get _visibleProcesses {
    final query = _search.text.trim().toLowerCase();
    final values = _processes.where((process) {
      if (_runningOnly && !process.isRunning) return false;
      if (query.isEmpty) return true;
      return process.pid.toString().contains(query) ||
          process.ppid.toString().contains(query) ||
          process.user.toLowerCase().contains(query) ||
          process.command.toLowerCase().contains(query);
    }).toList();
    int compare(RemoteProcess a, RemoteProcess b) => switch (_sort) {
          ProcessSortKey.cpu => a.cpuPercent.compareTo(b.cpuPercent),
          ProcessSortKey.memory => a.memoryPercent.compareTo(b.memoryPercent),
          ProcessSortKey.pid => a.pid.compareTo(b.pid),
          ProcessSortKey.command =>
            a.command.toLowerCase().compareTo(b.command.toLowerCase()),
          ProcessSortKey.user =>
            a.user.toLowerCase().compareTo(b.user.toLowerCase()),
        };
    values.sort((a, b) => _ascending ? compare(a, b) : compare(b, a));
    return values;
  }

  void _selectSort(ProcessSortKey value) {
    setState(() {
      if (_sort == value) {
        _ascending = !_ascending;
      } else {
        _sort = value;
        _ascending = value == ProcessSortKey.command ||
            value == ProcessSortKey.user ||
            value == ProcessSortKey.pid;
      }
    });
  }

  Future<void> _signal(RemoteProcess process, ProcessSignal signal) async {
    final destructive =
        signal == ProcessSignal.kill || signal == ProcessSignal.term;
    if (destructive) {
      final confirmed = await _confirm(
        signal == ProcessSignal.kill ? '强制结束进程？' : '终止进程？',
        '${process.command}\nPID ${process.pid}',
        signal == ProcessSignal.kill ? '强杀' : '终止',
      );
      if (!confirmed) return;
    }
    await _runAction(
      () => widget.service.signalProcess(widget.session, process.pid, signal),
    );
  }

  Future<void> _renice(RemoteProcess process) async {
    var value = 0.0;
    final result = await showDialog<int>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: LText('调整 PID ${process.pid} 优先级'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const LText('-20 优先级最高，19 最低'),
              const SizedBox(height: 12),
              Slider(
                min: -20,
                max: 19,
                divisions: 39,
                label: value.round().toString(),
                value: value,
                onChanged: (next) => setDialogState(() => value = next),
              ),
              LText(
                value.round().toString(),
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const LText('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, value.round()),
              child: const LText('应用'),
            ),
          ],
        ),
      ),
    );
    if (result == null) return;
    await _runAction(
      () => widget.service.reniceProcess(
        widget.session,
        process.pid,
        result,
      ),
    );
  }

  Future<void> _runAction(Future<void> Function() action) async {
    setState(() => _actionBusy = true);
    var succeeded = false;
    try {
      await action();
      succeeded = true;
    } catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
    if (succeeded) await _refresh();
  }

  Future<bool> _confirm(
    String title,
    String message,
    String action,
  ) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          icon: const Icon(Icons.warning_amber_outlined),
          title: LText(title),
          content: LText(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const LText('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: LText(action),
            ),
          ],
        ),
      ) ??
      false;

  void _showError(Object error) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: LText('$error')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visibleProcesses;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
          child: Column(
            children: [
              TextField(
                controller: _search,
                decoration: LInputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search),
                  hintText: '搜索 PID、用户名或命令',
                  suffixIcon: _search.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: localized('清除'),
                          onPressed: _search.clear,
                          icon: const Icon(Icons.close),
                        ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<ProcessSortKey>(
                      initialValue: _sort,
                      isDense: true,
                      decoration: LInputDecoration(
                        labelText: '排序',
                        prefixIcon: Icon(Icons.sort),
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: ProcessSortKey.cpu,
                          child: LText('CPU'),
                        ),
                        DropdownMenuItem(
                          value: ProcessSortKey.memory,
                          child: LText('内存'),
                        ),
                        DropdownMenuItem(
                          value: ProcessSortKey.pid,
                          child: LText('PID'),
                        ),
                        DropdownMenuItem(
                          value: ProcessSortKey.command,
                          child: LText('命令'),
                        ),
                        DropdownMenuItem(
                          value: ProcessSortKey.user,
                          child: LText('用户'),
                        ),
                      ],
                      onChanged: (value) {
                        if (value != null) _selectSort(value);
                      },
                    ),
                  ),
                  IconButton(
                    tooltip: _ascending ? '升序' : '降序',
                    onPressed: () => setState(() => _ascending = !_ascending),
                    icon: Icon(
                      _ascending ? Icons.arrow_upward : Icons.arrow_downward,
                    ),
                  ),
                  FilterChip(
                    label: const LText('仅运行中'),
                    selected: _runningOnly,
                    showCheckmark: false,
                    onSelected: (value) => setState(() => _runningOnly = value),
                  ),
                  IconButton(
                    tooltip: localized('刷新'),
                    onPressed: _loading ? null : _refresh,
                    icon: const Icon(Icons.refresh),
                  ),
                ],
              ),
            ],
          ),
        ),
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        if (_error != null)
          MaterialBanner(
            content: LText('读取进程失败：$_error'),
            actions: [
              TextButton(onPressed: _refresh, child: const LText('重试')),
            ],
          ),
        Expanded(
          child: visible.isEmpty && !_loading
              ? const Center(child: LText('没有符合条件的进程'))
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 20),
                  itemCount: visible.length,
                  itemBuilder: (context, index) => _ProcessCard(
                    process: visible[index],
                    enabled: !_actionBusy,
                    onSignal: _signal,
                    onRenice: _renice,
                  ),
                ),
        ),
      ],
    );
  }
}

class _ProcessCard extends StatelessWidget {
  const _ProcessCard({
    required this.process,
    required this.enabled,
    required this.onSignal,
    required this.onRenice,
  });

  final RemoteProcess process;
  final bool enabled;
  final Future<void> Function(RemoteProcess, ProcessSignal) onSignal;
  final Future<void> Function(RemoteProcess) onRenice;

  @override
  Widget build(BuildContext context) => Card(
        child: Column(
          children: [
            ExpansionTile(
              leading: CircleAvatar(
                radius: 20,
                child: LText(
                  '${process.cpuPercent.round()}%',
                  style: const TextStyle(fontSize: 11),
                ),
              ),
              title: LText(
                process.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: LText(
                '${process.user} · '
                'CPU ${process.cpuPercent.toStringAsFixed(1)}% · '
                'MEM ${process.memoryPercent.toStringAsFixed(1)}%',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              children: [
                Row(
                  children: [
                    Expanded(
                      child: _Detail(label: 'PID', value: '${process.pid}'),
                    ),
                    Expanded(
                      child: _Detail(label: 'PPID', value: '${process.ppid}'),
                    ),
                    Expanded(
                      child: _Detail(label: '状态', value: process.state),
                    ),
                    Expanded(
                      child: _Detail(label: '运行时长', value: process.elapsed),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      LText(
                        '完整命令',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      SelectableText(
                        process.command,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _Detail(
                        label: 'RSS',
                        value: _kilobytes(process.rssKb),
                      ),
                    ),
                    Expanded(
                      child: _Detail(
                        label: 'VSZ',
                        value: _kilobytes(process.vszKb),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _UsageBar(label: 'CPU', value: process.cpuPercent),
                const SizedBox(height: 8),
                _UsageBar(label: '内存', value: process.memoryPercent),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (process.isStopped)
                    IconButton(
                      tooltip: localized('恢复 (CONT)'),
                      onPressed: enabled
                          ? () => onSignal(process, ProcessSignal.cont)
                          : null,
                      icon: const Icon(Icons.play_arrow),
                    )
                  else
                    IconButton(
                      tooltip: localized('暂停 (STOP)'),
                      onPressed: enabled
                          ? () => onSignal(process, ProcessSignal.stop)
                          : null,
                      icon: const Icon(Icons.pause),
                    ),
                  IconButton(
                    tooltip: localized('终止 (TERM)'),
                    onPressed: enabled
                        ? () => onSignal(process, ProcessSignal.term)
                        : null,
                    icon: const Icon(Icons.stop_circle_outlined),
                  ),
                  IconButton(
                    tooltip: localized('强杀 (KILL)'),
                    onPressed: enabled
                        ? () => onSignal(process, ProcessSignal.kill)
                        : null,
                    icon: const Icon(Icons.dangerous_outlined),
                  ),
                  IconButton(
                    tooltip: localized('调整优先级 (renice)'),
                    onPressed: enabled ? () => onRenice(process) : null,
                    icon: const Icon(Icons.low_priority),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
}

class _Detail extends StatelessWidget {
  const _Detail({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LText(label, style: Theme.of(context).textTheme.bodySmall),
          LText(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ],
      );
}

class _UsageBar extends StatelessWidget {
  const _UsageBar({required this.label, required this.value});

  final String label;
  final double value;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          SizedBox(width: 42, child: LText(label)),
          Expanded(
            child: LinearProgressIndicator(value: value.clamp(0, 100) / 100),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 52,
            child: LText(
              '${value.toStringAsFixed(1)}%',
              textAlign: TextAlign.end,
            ),
          ),
        ],
      );
}

String _kilobytes(int value) {
  if (value < 1024) return '$value KB';
  if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} MB';
  return '${(value / 1024 / 1024).toStringAsFixed(1)} GB';
}
