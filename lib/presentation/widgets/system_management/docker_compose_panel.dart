import 'package:flutter/material.dart';
import 'package:netcatty_mobile/presentation/localization/localized_widgets.dart';

import '../../../domain/models/system_management.dart';
import '../../../infrastructure/ssh/ssh_service.dart';
import '../../../infrastructure/ssh/system_management_service.dart';
import 'docker_image_badge.dart';

class DockerComposePanel extends StatefulWidget {
  const DockerComposePanel({
    super.key,
    required this.session,
    required this.service,
    required this.onOpenTerminal,
    required this.onRequestSudoPassword,
  });

  final ActiveTerminalSession session;
  final SystemManagementService service;
  final Future<void> Function(String label, String command) onOpenTerminal;
  final Future<String?> Function(String message) onRequestSudoPassword;

  @override
  State<DockerComposePanel> createState() => _DockerComposePanelState();
}

class _DockerComposePanelState extends State<DockerComposePanel> {
  final _search = TextEditingController();
  List<DockerComposeProject> _projects = const [];
  List<DockerContainerInfo> _containers = const [];
  final _busy = <String>{};
  String _version = '';
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
    if (!mounted || _loading && _projects.isNotEmpty) return;
    setState(() => _loading = true);
    try {
      await _load();
    } on DockerSudoPasswordRequired catch (error) {
      final password = await widget.onRequestSudoPassword(error.message);
      if (password == null) {
        if (mounted) setState(() => _error = error);
        return;
      }
      widget.service.setDockerSudoPassword(widget.session, password);
      try {
        await _load();
      } catch (error) {
        if (mounted) setState(() => _error = error);
      }
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _load() async {
    final containers =
        await widget.service.listDockerContainers(widget.session);
    final version = await widget.service.dockerComposeVersion(widget.session);
    final projects = await widget.service.listDockerComposeProjects(
      widget.session,
      containers: containers,
    );
    if (!mounted) return;
    setState(() {
      _containers = containers;
      _projects = projects;
      _version = version;
      _error = null;
    });
  }

  List<DockerComposeProject> get _visibleProjects {
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return _projects;
    return _projects
        .where(
          (project) =>
              project.name.toLowerCase().contains(query) ||
              project.status.toLowerCase().contains(query) ||
              project.configFiles.any(
                (file) => file.toLowerCase().contains(query),
              ) ||
              _containers.any(
                (container) =>
                    container.composeProject == project.name &&
                    (container.composeService.toLowerCase().contains(query) ||
                        container.image.toLowerCase().contains(query)),
              ),
        )
        .toList(growable: false);
  }

  List<DockerContainerInfo> _services(DockerComposeProject project) =>
      _containers
          .where((container) => container.composeProject == project.name)
          .toList(growable: false);

  Future<void> _runAction(
    DockerComposeProject project,
    DockerComposeAction action,
  ) async {
    final confirmation = switch (action) {
      DockerComposeAction.update => (
          title: '更新 Compose 项目？',
          message: '将拉取 ${project.name} 的最新镜像并重新创建有变化的服务。',
          action: '更新',
        ),
      DockerComposeAction.recreate => (
          title: '重新创建容器？',
          message: '${project.name} 的服务会短暂中断，然后使用当前镜像重新创建。',
          action: '重建容器',
        ),
      DockerComposeAction.rebuild => (
          title: '重新构建项目？',
          message: '将重新构建 ${project.name} 的本地镜像并强制创建全部容器，服务会短暂中断。',
          action: '重新构建',
        ),
      DockerComposeAction.down => (
          title: '停止并移除项目？',
          message: '将移除 ${project.name} 的容器和默认网络，但不会删除数据卷。',
          action: '停止并移除',
        ),
      _ => null,
    };
    if (confirmation != null) {
      final confirmed = await _confirm(
        confirmation.title,
        confirmation.message,
        confirmation.action,
      );
      if (!confirmed) return;
    }
    setState(() => _busy.add(project.name));
    try {
      await widget.service.dockerComposeAction(
        widget.session,
        project,
        action,
      );
      await _load();
    } on DockerSudoPasswordRequired catch (error) {
      final password = await widget.onRequestSudoPassword(error.message);
      if (password == null) return;
      widget.service.setDockerSudoPassword(widget.session, password);
      await widget.service.dockerComposeAction(
        widget.session,
        project,
        action,
      );
      await _load();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: LText('$error')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy.remove(project.name));
    }
  }

  Future<void> _openLogs(DockerComposeProject project) async {
    try {
      final command = await widget.service.dockerComposeLogsCommand(
        widget.session,
        project,
      );
      await widget.onOpenTerminal('Compose logs: ${project.name}', command);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: LText('$error')),
        );
      }
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

  @override
  Widget build(BuildContext context) {
    final projects = _visibleProjects;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: TextField(
            controller: _search,
            decoration: LInputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search),
              hintText: '搜索项目、服务、镜像或配置文件',
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Row(
            children: [
              Chip(
                avatar: const Icon(Icons.layers_outlined, size: 18),
                label: LText(
                  _version.isEmpty ? 'Docker Compose' : 'Compose $_version',
                ),
              ),
              const Spacer(),
              LText('${_projects.length} 个项目'),
              IconButton(
                tooltip: localized('刷新 Compose'),
                onPressed: _loading ? null : _refresh,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        if (_error != null)
          MaterialBanner(
            content: LText('Compose 读取失败：$_error'),
            actions: [
              TextButton(onPressed: _refresh, child: const LText('重试')),
            ],
          ),
        Expanded(
          child: projects.isEmpty && !_loading
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.layers_clear_outlined, size: 48),
                      const SizedBox(height: 10),
                      LText(_error == null
                          ? '没有发现 Docker Compose 项目'
                          : 'Docker Compose 当前不可用'),
                      if (_error == null)
                        const Padding(
                          padding: EdgeInsets.fromLTRB(24, 6, 24, 0),
                          child: LText(
                            '通过 Compose 创建过容器后，项目会自动显示在这里。',
                            textAlign: TextAlign.center,
                          ),
                        ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 20),
                  itemCount: projects.length,
                  itemBuilder: (context, index) {
                    final project = projects[index];
                    return _ComposeProjectCard(
                      project: project,
                      services: _services(project),
                      busy: _busy.contains(project.name),
                      onAction: (action) => _runAction(project, action),
                      onLogs: () => _openLogs(project),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _ComposeProjectCard extends StatelessWidget {
  const _ComposeProjectCard({
    required this.project,
    required this.services,
    required this.busy,
    required this.onAction,
    required this.onLogs,
  });

  final DockerComposeProject project;
  final List<DockerContainerInfo> services;
  final bool busy;
  final ValueChanged<DockerComposeAction> onAction;
  final VoidCallback onLogs;

  @override
  Widget build(BuildContext context) => Card(
        child: Column(
          children: [
            ExpansionTile(
              leading: CircleAvatar(
                child: Icon(
                  project.isRunning
                      ? Icons.layers
                      : project.isPaused
                          ? Icons.pause
                          : Icons.layers_outlined,
                ),
              ),
              title: LText(project.name),
              subtitle: LText(
                project.status.isEmpty
                    ? '${services.length} 个服务'
                    : project.status,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: busy
                  ? const SizedBox.square(
                      dimension: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : null,
              childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              children: [
                if (project.configFiles.isNotEmpty)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.description_outlined),
                    title: const LText('Compose 配置'),
                    subtitle: LText(project.configFiles.join('\n')),
                  ),
                if (services.isEmpty)
                  const ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: LText('当前没有项目容器'),
                  )
                else
                  for (final service in services)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: DockerImageBadge(imageName: service.image),
                      title: LText(
                        service.composeService.isEmpty
                            ? service.name
                            : service.composeService,
                      ),
                      subtitle: LText(
                        '${service.image} · ${service.status}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: _ComposeStateIcon(state: service.state),
                    ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 2,
                children: [
                  if (project.isPaused)
                    _button(
                      '恢复项目',
                      Icons.play_arrow,
                      DockerComposeAction.unpause,
                    )
                  else if (!project.isRunning)
                    _button(
                      '启动项目',
                      Icons.play_arrow,
                      DockerComposeAction.start,
                    )
                  else ...[
                    _button(
                      '停止项目',
                      Icons.stop,
                      DockerComposeAction.stop,
                    ),
                    _button(
                      '重启项目',
                      Icons.restart_alt,
                      DockerComposeAction.restart,
                    ),
                    _button(
                      '暂停项目',
                      Icons.pause,
                      DockerComposeAction.pause,
                    ),
                  ],
                  _button(
                    '更新镜像并应用',
                    Icons.system_update_alt,
                    DockerComposeAction.update,
                  ),
                  _button(
                    '重新构建',
                    Icons.build_circle_outlined,
                    DockerComposeAction.rebuild,
                  ),
                  IconButton(
                    tooltip: localized('实时日志'),
                    onPressed: busy ? null : onLogs,
                    icon: const Icon(Icons.article_outlined),
                  ),
                  PopupMenuButton<DockerComposeAction>(
                    tooltip: localized('更多 Compose 操作'),
                    enabled: !busy,
                    onSelected: onAction,
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                        value: DockerComposeAction.pull,
                        child: ListTile(
                          leading: Icon(Icons.download),
                          title: LText('仅拉取最新镜像'),
                        ),
                      ),
                      PopupMenuItem(
                        value: DockerComposeAction.recreate,
                        child: ListTile(
                          leading: Icon(Icons.autorenew),
                          title: LText('使用当前镜像重建容器'),
                        ),
                      ),
                      PopupMenuItem(
                        value: DockerComposeAction.down,
                        child: ListTile(
                          leading: Icon(Icons.delete_sweep_outlined),
                          title: LText('停止并移除项目'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _button(
    String tooltip,
    IconData icon,
    DockerComposeAction action,
  ) =>
      IconButton(
        tooltip: tooltip,
        onPressed: busy ? null : () => onAction(action),
        icon: Icon(icon),
      );
}

class _ComposeStateIcon extends StatelessWidget {
  const _ComposeStateIcon({required this.state});

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
      child: Icon(Icons.circle, size: 11, color: color),
    );
  }
}
