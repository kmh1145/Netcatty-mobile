import 'package:flutter/material.dart';

import '../../../domain/models/system_management.dart';
import '../../../infrastructure/ssh/ssh_service.dart';
import '../../../infrastructure/ssh/system_management_service.dart';
import 'docker_compose_panel.dart';
import 'docker_image_badge.dart';

enum _ContainerFilter { all, running, stopped, paused }

class DockerManagerPanel extends StatefulWidget {
  const DockerManagerPanel({
    super.key,
    required this.session,
    required this.service,
    required this.onOpenTerminal,
  });

  final ActiveTerminalSession session;
  final SystemManagementService service;
  final Future<void> Function(String label, String command) onOpenTerminal;

  @override
  State<DockerManagerPanel> createState() => _DockerManagerPanelState();
}

class _DockerManagerPanelState extends State<DockerManagerPanel>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final _containerSearch = TextEditingController();
  final _imageSearch = TextEditingController();
  List<DockerContainerInfo> _containers = const [];
  List<DockerImageInfo> _images = const [];
  _ContainerFilter _filter = _ContainerFilter.all;
  final _busy = <String>{};
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    _containerSearch.addListener(_rebuild);
    _imageSearch.addListener(_rebuild);
    _refresh();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _containerSearch
      ..removeListener(_rebuild)
      ..dispose();
    _imageSearch
      ..removeListener(_rebuild)
      ..dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() => _loading = true);
    try {
      List<DockerContainerInfo> containers;
      List<DockerImageInfo> images;
      try {
        containers = await widget.service.listDockerContainers(widget.session);
        images = await widget.service.listDockerImages(widget.session);
      } on DockerSudoPasswordRequired catch (error) {
        final password = await _requestSudoPassword(error.message);
        if (password == null) rethrow;
        widget.service.setDockerSudoPassword(widget.session, password);
        containers = await widget.service.listDockerContainers(widget.session);
        images = await widget.service.listDockerImages(widget.session);
      }
      if (!mounted) return;
      setState(() {
        _containers = containers;
        _images = images;
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
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
          title: const Text('需要 sudo 权限'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(message),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                obscureText: obscure,
                onSubmitted: (value) {
                  if (value.isNotEmpty) Navigator.pop(context, value);
                },
                decoration: InputDecoration(
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
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                if (controller.text.isNotEmpty) {
                  Navigator.pop(context, controller.text);
                }
              },
              child: const Text('继续'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    return result;
  }

  List<DockerContainerInfo> get _visibleContainers {
    final query = _containerSearch.text.trim().toLowerCase();
    return _containers.where((container) {
      final stateMatches = switch (_filter) {
        _ContainerFilter.all => true,
        _ContainerFilter.running =>
          container.state == DockerContainerState.running,
        _ContainerFilter.stopped =>
          container.state == DockerContainerState.stopped,
        _ContainerFilter.paused =>
          container.state == DockerContainerState.paused,
      };
      if (!stateMatches) return false;
      if (query.isEmpty) return true;
      return container.name.toLowerCase().contains(query) ||
          container.image.toLowerCase().contains(query) ||
          container.id.toLowerCase().contains(query);
    }).toList(growable: false);
  }

  List<DockerImageInfo> get _visibleImages {
    final query = _imageSearch.text.trim().toLowerCase();
    if (query.isEmpty) return _images;
    return _images
        .where(
          (image) =>
              image.name.toLowerCase().contains(query) ||
              image.id.toLowerCase().contains(query) ||
              image.digest.toLowerCase().contains(query),
        )
        .toList(growable: false);
  }

  Future<void> _containerAction(
    DockerContainerInfo container,
    DockerContainerAction action,
  ) async {
    if (action == DockerContainerAction.kill ||
        action == DockerContainerAction.remove) {
      final confirmed = await _confirm(
        action == DockerContainerAction.kill ? '强制停止容器？' : '删除容器？',
        action == DockerContainerAction.kill
            ? '${container.name} 将立即被 kill。'
            : '${container.name} 将被强制删除，此操作无法撤销。',
        action == DockerContainerAction.kill ? '强杀' : '删除',
      );
      if (!confirmed) return;
    }
    await _runBusy(
      container.id,
      () => widget.service.dockerContainerAction(
        widget.session,
        container.id,
        action,
      ),
    );
  }

  Future<void> _removeImage(DockerImageInfo image) async {
    final confirmed = await _confirm(
      '删除镜像？',
      '${image.name}\n${image.shortId}',
      '删除',
    );
    if (!confirmed) return;
    await _runBusy(
      image.id,
      () => widget.service.removeDockerImage(widget.session, image.id),
    );
  }

  Future<void> _pullImage() async {
    final controller = TextEditingController();
    final reference = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('拉取镜像'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '镜像',
            hintText: '例如 nginx:latest',
          ),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('拉取'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (reference == null || reference.trim().isEmpty) return;
    await _runBusy(
      'pull',
      () => widget.service.pullDockerImage(widget.session, reference),
    );
  }

  Future<void> _runBusy(
    String id,
    Future<void> Function() action,
  ) async {
    setState(() => _busy.add(id));
    try {
      await action();
      await _refresh();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$error')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
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
          title: Text(title),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TabBar(
                  controller: _tabs,
                  tabs: [
                    Tab(text: '容器 (${_containers.length})'),
                    Tab(text: '镜像 (${_images.length})'),
                    const Tab(text: 'Compose'),
                  ],
                ),
              ),
              IconButton(
                tooltip: '刷新 Docker',
                onPressed: _loading ? null : _refresh,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          if (_error != null)
            MaterialBanner(
              content: Text('Docker 读取失败：$_error'),
              actions: [
                TextButton(onPressed: _refresh, child: const Text('重试')),
              ],
            ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: [
                _buildContainers(),
                _buildImages(),
                DockerComposePanel(
                  session: widget.session,
                  service: widget.service,
                  onOpenTerminal: widget.onOpenTerminal,
                  onRequestSudoPassword: _requestSudoPassword,
                ),
              ],
            ),
          ),
        ],
      );

  Widget _buildContainers() {
    final values = _visibleContainers;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: TextField(
            controller: _containerSearch,
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search),
              hintText: '搜索名称、镜像或容器 ID',
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Wrap(
            spacing: 6,
            children: [
              _filterChip('全部', _ContainerFilter.all),
              _filterChip('运行中', _ContainerFilter.running),
              _filterChip('已停止', _ContainerFilter.stopped),
              _filterChip('已暂停', _ContainerFilter.paused),
            ],
          ),
        ),
        Expanded(
          child: values.isEmpty && !_loading
              ? const Center(child: Text('没有符合条件的容器'))
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(8, 2, 8, 20),
                  itemCount: values.length,
                  itemBuilder: (context, index) {
                    final container = values[index];
                    return _ContainerCard(
                      container: container,
                      busy: _busy.contains(container.id),
                      onAction: _containerAction,
                      onShell: () => widget.onOpenTerminal(
                        'Docker: ${container.name}',
                        widget.service.dockerShellCommand(
                          widget.session,
                          container.id,
                        ),
                      ),
                      onLogs: () => widget.onOpenTerminal(
                        'Logs: ${container.name}',
                        widget.service.dockerLogsCommand(
                          widget.session,
                          container.id,
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _filterChip(String label, _ContainerFilter value) => ChoiceChip(
        label: Text(label),
        selected: _filter == value,
        onSelected: (_) => setState(() => _filter = value),
      );

  Widget _buildImages() {
    final values = _visibleImages;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _imageSearch,
                  decoration: const InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(Icons.search),
                    hintText: '搜索镜像名称、ID 或 digest',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _busy.contains('pull') ? null : _pullImage,
                icon: const Icon(Icons.download),
                label: const Text('拉取'),
              ),
            ],
          ),
        ),
        Expanded(
          child: values.isEmpty && !_loading
              ? const Center(child: Text('没有符合条件的镜像'))
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(8, 2, 8, 20),
                  itemCount: values.length,
                  itemBuilder: (context, index) {
                    final image = values[index];
                    return Card(
                      child: ListTile(
                        leading: DockerImageBadge(imageName: image.name),
                        title: Text(
                          image.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${image.shortId} · ${image.size}\n${image.createdAt}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: _busy.contains(image.id)
                            ? const SizedBox.square(
                                dimension: 22,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : IconButton(
                                tooltip: '删除镜像',
                                onPressed: () => _removeImage(image),
                                icon: const Icon(Icons.delete_outline),
                              ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _ContainerCard extends StatelessWidget {
  const _ContainerCard({
    required this.container,
    required this.busy,
    required this.onAction,
    required this.onShell,
    required this.onLogs,
  });

  final DockerContainerInfo container;
  final bool busy;
  final Future<void> Function(DockerContainerInfo, DockerContainerAction)
      onAction;
  final VoidCallback onShell;
  final VoidCallback onLogs;

  @override
  Widget build(BuildContext context) => Card(
        child: Column(
          children: [
            ExpansionTile(
              leading: DockerImageBadge(imageName: container.image),
              title: Text(
                container.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${container.image} · ${container.shortId}\n${container.status}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: busy
                  ? const SizedBox.square(
                      dimension: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : _StateDot(state: container.state),
              childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              children: [
                if (container.ports.isNotEmpty)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.lan_outlined),
                    title: const Text('端口'),
                    subtitle: Text(container.ports),
                  )
                else
                  const ListTile(
                    dense: true,
                    leading: Icon(Icons.lan_outlined),
                    title: Text('没有公开端口'),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 2,
                children: [
                  if (container.state == DockerContainerState.stopped)
                    _actionButton(
                      '启动',
                      Icons.play_arrow,
                      DockerContainerAction.start,
                    ),
                  if (container.state == DockerContainerState.running) ...[
                    _actionButton(
                      '停止',
                      Icons.stop,
                      DockerContainerAction.stop,
                    ),
                    _actionButton(
                      '重启',
                      Icons.restart_alt,
                      DockerContainerAction.restart,
                    ),
                    _actionButton(
                      '暂停',
                      Icons.pause,
                      DockerContainerAction.pause,
                    ),
                  ],
                  if (container.state == DockerContainerState.paused) ...[
                    _actionButton(
                      '恢复',
                      Icons.play_arrow,
                      DockerContainerAction.unpause,
                    ),
                    _actionButton(
                      '停止',
                      Icons.stop,
                      DockerContainerAction.stop,
                    ),
                  ],
                  IconButton(
                    tooltip: '进入容器终端',
                    onPressed:
                        busy || container.state == DockerContainerState.stopped
                            ? null
                            : onShell,
                    icon: const Icon(Icons.terminal),
                  ),
                  IconButton(
                    tooltip: '查看实时日志',
                    onPressed: busy ? null : onLogs,
                    icon: const Icon(Icons.article_outlined),
                  ),
                  IconButton(
                    tooltip: '强杀',
                    onPressed:
                        busy || container.state == DockerContainerState.stopped
                            ? null
                            : () => onAction(
                                  container,
                                  DockerContainerAction.kill,
                                ),
                    icon: const Icon(Icons.dangerous_outlined),
                  ),
                  IconButton(
                    tooltip: '删除',
                    onPressed: busy
                        ? null
                        : () => onAction(
                              container,
                              DockerContainerAction.remove,
                            ),
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _actionButton(
    String tooltip,
    IconData icon,
    DockerContainerAction action,
  ) =>
      IconButton(
        tooltip: tooltip,
        onPressed: busy ? null : () => onAction(container, action),
        icon: Icon(icon),
      );
}

class _StateDot extends StatelessWidget {
  const _StateDot({required this.state});

  final DockerContainerState state;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (state) {
      DockerContainerState.running => ('运行中', Colors.green),
      DockerContainerState.paused => ('已暂停', Colors.orange),
      DockerContainerState.stopped => ('已停止', Colors.grey),
      DockerContainerState.unknown => ('未知', Colors.blueGrey),
    };
    return Tooltip(
      message: label,
      child: Icon(Icons.circle, size: 12, color: color),
    );
  }
}
