import 'package:flutter/material.dart';
import 'package:netcatty_mobile/presentation/localization/localized_widgets.dart';

import '../../../domain/models/system_management.dart';
import '../../../infrastructure/ssh/ssh_service.dart';
import '../../../infrastructure/ssh/system_management_service.dart';
import 'management_filter_chip.dart';

enum _ServiceFilter { all, running, stopped, failed }

class ServiceManagerPanel extends StatefulWidget {
  const ServiceManagerPanel({
    super.key,
    required this.session,
    required this.service,
  });

  final ActiveTerminalSession session;
  final SystemManagementService service;

  @override
  State<ServiceManagerPanel> createState() => _ServiceManagerPanelState();
}

class _ServiceManagerPanelState extends State<ServiceManagerPanel> {
  final _search = TextEditingController();
  final _busy = <String>{};
  List<RemoteService> _services = const [];
  ServiceManager? _manager;
  _ServiceFilter _filter = _ServiceFilter.all;
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _search.addListener(_rebuild);
    _refresh();
  }

  @override
  void dispose() {
    _search
      ..removeListener(_rebuild)
      ..dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    try {
      final manager = await widget.service.detectServiceManager(widget.session);
      final services = await widget.service.listServices(widget.session);
      if (!mounted) return;
      setState(() {
        _manager = manager;
        _services = services;
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  List<RemoteService> get _visibleServices {
    final query = _search.text.trim().toLowerCase();
    return _services.where((service) {
      final stateMatches = switch (_filter) {
        _ServiceFilter.all => true,
        _ServiceFilter.running => service.state == RemoteServiceState.running,
        _ServiceFilter.stopped => service.state == RemoteServiceState.stopped,
        _ServiceFilter.failed => service.state == RemoteServiceState.failed,
      };
      if (!stateMatches) return false;
      return query.isEmpty ||
          service.name.toLowerCase().contains(query) ||
          service.description.toLowerCase().contains(query);
    }).toList(growable: false);
  }

  Future<void> _run(
    RemoteService service,
    RemoteServiceAction action,
  ) async {
    if (_busy.contains(service.name)) return;
    setState(() => _busy.add(service.name));
    try {
      try {
        await widget.service.serviceAction(widget.session, service, action);
      } on ServiceSudoPasswordRequired catch (error) {
        final password = await _requestSudoPassword(error.message);
        if (password == null) return;
        widget.service.setServiceSudoPassword(widget.session, password);
        await widget.service.serviceAction(widget.session, service, action);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: LText('${service.name} 操作完成')),
      );
      await _refresh();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: LText('服务操作失败：$error')),
      );
    } finally {
      if (mounted) setState(() => _busy.remove(service.name));
    }
  }

  Future<String?> _requestSudoPassword(String message) async {
    final controller = TextEditingController();
    var obscure = true;
    final result = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          icon: const Icon(Icons.lock_outline),
          title: const LText('需要 sudo 权限'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LText(message),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                obscureText: obscure,
                onSubmitted: (value) {
                  if (value.isNotEmpty) Navigator.pop(context, value);
                },
                decoration: LInputDecoration(
                  labelText: 'sudo 密码',
                  helperText: '密码仅在本次系统管理面板打开期间保留',
                  suffixIcon: IconButton(
                    onPressed: () => setDialogState(() => obscure = !obscure),
                    icon: Icon(
                      obscure ? Icons.visibility : Icons.visibility_off,
                    ),
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const LText('取消'),
            ),
            FilledButton(
              onPressed: () {
                if (controller.text.isNotEmpty) {
                  Navigator.pop(context, controller.text);
                }
              },
              child: const LText('继续'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final services = _visibleServices;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
          child: TextField(
            key: const ValueKey('service-search'),
            controller: _search,
            decoration: LInputDecoration(
              hintText: '搜索服务名称或描述',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: IconButton(
                tooltip: localized('刷新'),
                onPressed: _loading ? null : _refresh,
                icon: const Icon(Icons.refresh),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Row(
            children: [
              Icon(
                _manager == ServiceManager.openRc
                    ? Icons.alt_route
                    : Icons.settings_suggest_outlined,
                size: 18,
              ),
              const SizedBox(width: 7),
              LText(
                _manager == ServiceManager.openRc ? 'OpenRC 服务' : 'systemd 服务',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const Spacer(),
              LText('${services.length} / ${_services.length}'),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Wrap(
            spacing: 6,
            children: [
              _filterChip('全部', _ServiceFilter.all),
              _filterChip('运行中', _ServiceFilter.running),
              _filterChip('已停止', _ServiceFilter.stopped),
              _filterChip('失败', _ServiceFilter.failed),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Expanded(child: _buildList(services)),
      ],
    );
  }

  Widget _filterChip(String label, _ServiceFilter value) =>
      ManagementFilterChip(
        label: label,
        selected: _filter == value,
        onSelected: () => setState(() => _filter = value),
      );

  Widget _buildList(List<RemoteService> services) {
    if (_loading && _services.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _services.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.miscellaneous_services_outlined, size: 44),
              const SizedBox(height: 12),
              LText('无法读取系统服务：$_error', textAlign: TextAlign.center),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _refresh,
                icon: const Icon(Icons.refresh),
                label: const LText('重试'),
              ),
            ],
          ),
        ),
      );
    }
    if (services.isEmpty) {
      return const Center(child: LText('没有符合条件的服务'));
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 24),
        itemCount: services.length,
        itemBuilder: (context, index) => _ServiceCard(
          service: services[index],
          busy: _busy.contains(services[index].name),
          onAction: _run,
        ),
      ),
    );
  }
}

class _ServiceCard extends StatelessWidget {
  const _ServiceCard({
    required this.service,
    required this.busy,
    required this.onAction,
  });

  final RemoteService service;
  final bool busy;
  final Future<void> Function(RemoteService, RemoteServiceAction) onAction;

  @override
  Widget build(BuildContext context) => Card(
        child: ExpansionTile(
          leading: _ServiceStateIcon(state: service.state),
          title: LText(
            service.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: LText(
            service.description.isEmpty
                ? service.enabled
                    ? '已设置开机自启'
                    : '未设置开机自启'
                : service.description,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: busy
              ? const SizedBox.square(
                  dimension: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Icon(
                  service.enabled
                      ? Icons.power_settings_new
                      : Icons.power_off_outlined,
                  color: service.enabled
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          children: [
            if (service.description.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: LText(service.description),
                ),
              ),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 2,
              children: [
                if (!service.isRunning)
                  _button('启动', Icons.play_arrow, RemoteServiceAction.start),
                if (service.isRunning)
                  _button('停止', Icons.stop, RemoteServiceAction.stop),
                _button('重启', Icons.restart_alt, RemoteServiceAction.restart),
                _button(
                  service.enabled ? '关闭开机自启' : '设置开机自启',
                  service.enabled
                      ? Icons.power_off_outlined
                      : Icons.power_settings_new,
                  service.enabled
                      ? RemoteServiceAction.disable
                      : RemoteServiceAction.enable,
                ),
              ],
            ),
          ],
        ),
      );

  Widget _button(
    String tooltip,
    IconData icon,
    RemoteServiceAction action,
  ) =>
      IconButton(
        tooltip: tooltip,
        onPressed: busy ? null : () => onAction(service, action),
        icon: Icon(icon),
      );
}

class _ServiceStateIcon extends StatelessWidget {
  const _ServiceStateIcon({required this.state});

  final RemoteServiceState state;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (state) {
      RemoteServiceState.running => ('运行中', Colors.green),
      RemoteServiceState.stopped => ('已停止', Colors.grey),
      RemoteServiceState.failed => ('失败', Colors.redAccent),
      RemoteServiceState.unknown => ('未知', Colors.blueGrey),
    };
    return Tooltip(
      message: localized(label),
      child: Icon(Icons.circle, size: 13, color: color),
    );
  }
}
