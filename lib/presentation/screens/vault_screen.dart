import 'package:flutter/material.dart';
import 'package:netcatty_mobile/presentation/localization/localized_widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/session_controller.dart';
import '../../application/settings_controller.dart';
import '../../application/vault_controller.dart';
import '../../domain/models/host.dart';
import '../../application/home_navigation.dart';
import '../widgets/empty_state.dart';
import '../widgets/host_editor.dart';
import '../widgets/host_system_icon.dart';

class VaultScreen extends ConsumerStatefulWidget {
  const VaultScreen({super.key});

  @override
  ConsumerState<VaultScreen> createState() => _VaultScreenState();
}

class _VaultScreenState extends ConsumerState<VaultScreen> {
  final _search = TextEditingController();
  String? _group;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(vaultControllerProvider);
    final settings = ref.watch(settingsControllerProvider);
    final viewMode = settings.serverViewMode;
    final vault = state.data;
    final hosts = (vault?.hosts ?? const <HostProfile>[]).where((host) {
      final query = _search.text.toLowerCase();
      final matchesQuery = query.isEmpty ||
          host.label.toLowerCase().contains(query) ||
          host.hostname.toLowerCase().contains(query) ||
          host.tags.any((tag) => tag.toLowerCase().contains(query));
      return matchesQuery && (_group == null || host.group == _group);
    }).toList()
      ..sort((a, b) {
        if (a.pinned != b.pinned) return a.pinned ? -1 : 1;
        return a.label.toLowerCase().compareTo(b.label.toLowerCase());
      });

    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 8),
            child: Row(
              children: [
                Icon(Icons.pets, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 10),
                LText(
                  'Netcatty',
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                PopupMenuButton<String>(
                  tooltip: localized('服务器视图'),
                  initialValue: viewMode,
                  onSelected: (value) => ref
                      .read(settingsControllerProvider.notifier)
                      .update(settings.copyWith(serverViewMode: value)),
                  itemBuilder: (_) => const [
                    PopupMenuItem(
                      value: 'grid',
                      child: ListTile(
                        leading: Icon(Icons.grid_view_outlined),
                        title: LText('网格视图'),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'list',
                      child: ListTile(
                        leading: Icon(Icons.view_list_outlined),
                        title: LText('列表视图'),
                      ),
                    ),
                    PopupMenuItem(
                      value: 'tree',
                      child: ListTile(
                        leading: Icon(Icons.account_tree_outlined),
                        title: LText('树形视图'),
                      ),
                    ),
                  ],
                  icon: Icon(switch (viewMode) {
                    'list' => Icons.view_list_outlined,
                    'tree' => Icons.account_tree_outlined,
                    _ => Icons.grid_view_outlined,
                  }),
                ),
                IconButton(
                  tooltip: localized('添加主机'),
                  onPressed: () => _editHost(),
                  icon: const Icon(Icons.add_circle_outline),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _search,
              onChanged: (_) => setState(() {}),
              decoration: LInputDecoration(
                prefixIcon: Icon(Icons.search),
                hintText: '搜索主机、地址或标签',
                isDense: true,
              ),
            ),
          ),
          if ((vault?.customGroups.isNotEmpty ?? false))
            SizedBox(
              height: 48,
              child: ListView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                scrollDirection: Axis.horizontal,
                children: [
                  ChoiceChip(
                    label: const LText('全部'),
                    selected: _group == null,
                    onSelected: (_) => setState(() => _group = null),
                  ),
                  const SizedBox(width: 8),
                  for (final group in vault!.customGroups) ...[
                    ChoiceChip(
                      label: LText(group),
                      selected: _group == group,
                      onSelected: (_) => setState(() => _group = group),
                    ),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
          Expanded(
            child: state.loading && vault == null
                ? const Center(child: CircularProgressIndicator())
                : hosts.isEmpty
                    ? EmptyState(
                        icon: Icons.dns_outlined,
                        title: '还没有服务器',
                        subtitle: '添加 SSH 或 Telnet 连接，云同步后也会出现在这里。',
                        action: FilledButton.icon(
                          onPressed: () => _editHost(),
                          icon: const Icon(Icons.add),
                          label: const LText('添加主机'),
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: () =>
                            ref.read(vaultControllerProvider.notifier).load(),
                        child: switch (viewMode) {
                          'grid' => GridView.builder(
                              padding: const EdgeInsets.all(12),
                              gridDelegate:
                                  const SliverGridDelegateWithMaxCrossAxisExtent(
                                maxCrossAxisExtent: 230,
                                mainAxisExtent: 148,
                                crossAxisSpacing: 10,
                                mainAxisSpacing: 10,
                              ),
                              itemCount: hosts.length,
                              itemBuilder: (_, index) => _HostCard(
                                host: hosts[index],
                                onConnect: () => _showHostDetails(hosts[index]),
                                onEdit: () => _editHost(hosts[index]),
                              ),
                            ),
                          'tree' => _HostTree(
                              hosts: hosts,
                              onConnect: _showHostDetails,
                              onEdit: _editHost,
                            ),
                          _ => ListView.separated(
                              padding: const EdgeInsets.all(12),
                              itemCount: hosts.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 8),
                              itemBuilder: (_, index) => _HostTile(
                                host: hosts[index],
                                onConnect: () => _showHostDetails(hosts[index]),
                                onEdit: () => _editHost(hosts[index]),
                              ),
                            ),
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Future<void> _connect(HostProfile host) async {
    ref.read(homeTabProvider.notifier).state = 1;
    try {
      await ref.read(sessionControllerProvider.notifier).connect(
            host,
            _verifyHostKey,
            keyboardInteractive: _promptKeyboardInteractive,
          );
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: LText('${host.label} 已连接')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: LText('连接失败：$error')));
      }
    }
  }

  Future<void> _showHostDetails(HostProfile host) async {
    final vault = await ref.read(vaultControllerProvider.notifier).ready();
    host = vault.hosts.firstWhere(
      (value) => value.id == host.id,
      orElse: () => host,
    );
    if (!mounted) return;
    final key = vault.keys.cast<SshKeyProfile?>().firstWhere(
          (value) => value?.id == host.identityFileId,
          orElse: () => null,
        );
    final jumps = host.hostChainIds
        .map((id) => vault.hosts.cast<HostProfile?>().firstWhere(
              (value) => value?.id == id,
              orElse: () => null,
            ))
        .whereType<HostProfile>()
        .toList();
    final profile = vault.proxyProfiles.cast<ProxyProfile?>().firstWhere(
          (value) => value?.id == host.proxyProfileId,
          orElse: () => null,
        );
    final proxy = profile?.config ?? host.proxyConfig;
    final action = await showDialog<_HostAction>(
      context: context,
      builder: (context) => AlertDialog(
        icon: HostSystemIcon(host: host, size: 52),
        title: LText(host.label),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _DetailRow(
                icon: Icons.link,
                label: '连接地址',
                value:
                    '${host.protocol.name.toUpperCase()}  ${host.username}@${host.hostname}:${host.port}',
              ),
              if (host.systemInfo != null)
                _DetailRow(
                  icon: Icons.memory_outlined,
                  label: '系统',
                  value: [
                    host.systemInfo!.prettyName,
                    if (host.systemInfo!.kernel.isNotEmpty)
                      host.systemInfo!.kernel,
                    if (host.systemInfo!.cores > 0)
                      '${host.systemInfo!.cores} 核',
                  ].join(' · '),
                ),
              _DetailRow(
                icon: Icons.key_outlined,
                label: '认证',
                value: key == null
                    ? (host.password?.isNotEmpty == true ? '密码' : '自动 / 交互式')
                    : '私钥 · ${key.label}',
              ),
              if (jumps.isNotEmpty)
                _DetailRow(
                  icon: Icons.alt_route,
                  label: '跳板机',
                  value: jumps.map((value) => value.label).join(' → '),
                ),
              if (proxy != null)
                _DetailRow(
                  icon: Icons.public,
                  label: '代理',
                  value:
                      '${proxy.type.name.toUpperCase()} · ${proxy.host}:${proxy.port}',
                ),
              if (host.group?.isNotEmpty == true)
                _DetailRow(
                  icon: Icons.folder_outlined,
                  label: '分组',
                  value: host.group!,
                ),
              if (host.tags.isNotEmpty)
                _DetailRow(
                  icon: Icons.sell_outlined,
                  label: '标签',
                  value: host.tags.join('、'),
                ),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () => Navigator.pop(context, _HostAction.edit),
            icon: const Icon(Icons.edit_outlined),
            label: const LText('编辑'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, _HostAction.connect),
            icon: const Icon(Icons.terminal),
            label: const LText('连接'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (action == _HostAction.edit) {
      await _editHost(host);
    } else if (action == _HostAction.connect) {
      await _connect(host);
    }
  }

  Future<bool> _verifyHostKey(
    HostProfile host,
    String algorithm,
    String fingerprint,
  ) async {
    final vault = ref.read(vaultControllerProvider).data;
    if (vault == null) return false;
    final entries = (vault.extras['knownHosts'] as List? ?? const [])
        .whereType<Map>()
        .map((value) => Map<String, dynamic>.from(value))
        .toList();
    final index = entries.indexWhere(
      (value) =>
          value['hostname'] == host.hostname &&
          ((value['port'] as num?)?.toInt() ?? 22) == host.port,
    );
    final existing = index < 0 ? null : entries[index];
    if (existing?['fingerprint'] == fingerprint &&
        existing?['keyType'] == algorithm) {
      return true;
    }
    if (!mounted) return false;
    final changed = existing != null;
    final accepted = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            icon: Icon(
              changed ? Icons.warning_amber : Icons.verified_user_outlined,
              color: changed ? Colors.redAccent : null,
            ),
            title: LText(changed ? '服务器指纹已变化' : '确认服务器指纹'),
            content: LSelectableText(
              '${host.hostname}:${host.port}\n$algorithm\n$fingerprint\n\n'
              '${changed ? '这可能表示服务器重装，也可能是中间人攻击。请重新向管理员核对。' : '首次连接前请与管理员核对。'}',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const LText('拒绝'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: LText(changed ? '确认更新' : '接受并记住'),
              ),
            ],
          ),
        ) ??
        false;
    if (!accepted) return false;
    final record = {
      'hostname': host.hostname,
      'port': host.port,
      'keyType': algorithm,
      'fingerprint': fingerprint,
      'acceptedAt': DateTime.now().millisecondsSinceEpoch,
    };
    if (index < 0) {
      entries.add(record);
    } else {
      entries[index] = record;
    }
    await ref.read(vaultControllerProvider.notifier).replace(
          vault.copyWith(extras: {...vault.extras, 'knownHosts': entries}),
        );
    return true;
  }

  Future<List<String>?> _promptKeyboardInteractive(
    String name,
    String instruction,
    List<({bool echo, String text})> prompts,
  ) async {
    if (!mounted) return null;
    final controllers = prompts.map((_) => TextEditingController()).toList();
    return showDialog<List<String>>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: LText(name.isEmpty ? '交互式认证' : name),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (instruction.isNotEmpty) ...[
                LText(instruction),
                const SizedBox(height: 12),
              ],
              for (var index = 0; index < prompts.length; index++) ...[
                TextField(
                  controller: controllers[index],
                  obscureText: !prompts[index].echo,
                  autofocus: index == 0,
                  decoration: LInputDecoration(labelText: prompts[index].text),
                ),
                const SizedBox(height: 10),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const LText('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              context,
              controllers.map((value) => value.text).toList(),
            ),
            child: const LText('继续'),
          ),
        ],
      ),
    );
  }

  Future<void> _editHost([HostProfile? host]) async {
    final vault = await ref.read(vaultControllerProvider.notifier).ready();
    var resolvedHost = host;
    if (host != null) {
      resolvedHost = vault.hosts.firstWhere(
        (value) => value.id == host.id,
        orElse: () => host,
      );
    }
    if (!mounted) return;
    final result = await showModalBottomSheet<HostProfile>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => HostEditor(
        host: resolvedHost,
        onDelete: resolvedHost == null
            ? null
            : () => _confirmDeleteHost(resolvedHost!),
      ),
    );
    if (result != null) {
      await ref.read(vaultControllerProvider.notifier).upsertHost(result);
    }
  }

  Future<bool> _confirmDeleteHost(HostProfile host) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            icon: const Icon(Icons.delete_outline),
            title: const LText('删除服务器？'),
            content: LText('将从保险库中删除“${host.label}”，此操作可通过云同步传播到其他设备。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const LText('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const LText('删除'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return false;
    await ref.read(vaultControllerProvider.notifier).deleteHost(host.id);
    return true;
  }
}

class _HostTree extends StatelessWidget {
  const _HostTree({
    required this.hosts,
    required this.onConnect,
    required this.onEdit,
  });

  final List<HostProfile> hosts;
  final ValueChanged<HostProfile> onConnect;
  final ValueChanged<HostProfile> onEdit;

  @override
  Widget build(BuildContext context) {
    final grouped = <String, List<HostProfile>>{};
    for (final host in hosts) {
      grouped
          .putIfAbsent(
              host.group?.trim().isNotEmpty == true
                  ? host.group!.trim()
                  : '未分组',
              () => <HostProfile>[])
          .add(host);
    }
    final groups = grouped.keys.toList()
      ..sort((a, b) {
        if (a == '未分组') return 1;
        if (b == '未分组') return -1;
        return a.toLowerCase().compareTo(b.toLowerCase());
      });
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: groups.length,
      itemBuilder: (context, index) {
        final group = groups[index];
        final children = grouped[group]!;
        return Card(
          margin: const EdgeInsets.only(bottom: 10),
          clipBehavior: Clip.antiAlias,
          child: ExpansionTile(
            initiallyExpanded: true,
            leading: Icon(
              group == '未分组'
                  ? Icons.folder_off_outlined
                  : Icons.folder_outlined,
              color: Theme.of(context).colorScheme.primary,
            ),
            title: LText(group),
            subtitle: LText('${children.length} 台服务器'),
            children: [
              for (final host in children)
                ListTile(
                  contentPadding: const EdgeInsets.only(left: 28, right: 8),
                  onTap: () => onConnect(host),
                  leading: HostSystemIcon(host: host, size: 38),
                  title: LText(host.label),
                  subtitle:
                      LText('${host.username}@${host.hostname}:${host.port}'),
                  trailing: IconButton(
                    tooltip: localized('编辑'),
                    onPressed: () => onEdit(host),
                    icon: const Icon(Icons.more_vert),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _HostCard extends StatelessWidget {
  const _HostCard({
    required this.host,
    required this.onConnect,
    required this.onEdit,
  });
  final HostProfile host;
  final VoidCallback onConnect;
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) => Card(
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onConnect,
          onLongPress: onEdit,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    HostSystemIcon(host: host, size: 40),
                    const Spacer(),
                    if (host.pinned) const Icon(Icons.push_pin, size: 16),
                    IconButton(
                      onPressed: onEdit,
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.more_horiz),
                    ),
                  ],
                ),
                const Spacer(),
                LText(
                  host.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 16),
                ),
                const SizedBox(height: 4),
                LText(
                  '${host.username}@${host.hostname}:${host.port}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (host.group?.isNotEmpty == true)
                  LText(
                    host.group!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontSize: 11,
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
}

class _HostTile extends StatelessWidget {
  const _HostTile({
    required this.host,
    required this.onConnect,
    required this.onEdit,
  });
  final HostProfile host;
  final VoidCallback onConnect;
  final VoidCallback onEdit;
  @override
  Widget build(BuildContext context) => Card(
        child: ListTile(
          onTap: onConnect,
          leading: HostSystemIcon(host: host, size: 42),
          title: LText(host.label),
          subtitle: LText('${host.username}@${host.hostname}:${host.port}'),
          trailing: IconButton(
            onPressed: onEdit,
            icon: const Icon(Icons.more_vert),
          ),
        ),
      );
}

enum _HostAction { connect, edit }

class _DetailRow extends StatelessWidget {
  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 19, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 12),
            SizedBox(
              width: 62,
              child: LText(
                label,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            Expanded(child: LSelectableText(value)),
          ],
        ),
      );
}
