import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../application/session_controller.dart';
import '../../application/vault_controller.dart';
import '../../domain/models/host.dart';
import '../home_shell.dart';
import '../theme.dart';
import '../widgets/empty_state.dart';
import '../widgets/host_editor.dart';

class VaultScreen extends ConsumerStatefulWidget {
  const VaultScreen({super.key});

  @override
  ConsumerState<VaultScreen> createState() => _VaultScreenState();
}

class _VaultScreenState extends ConsumerState<VaultScreen> {
  final _search = TextEditingController();
  var _grid = true;
  String? _group;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(vaultControllerProvider);
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
                const Icon(Icons.pets, color: NetcattyTheme.accent),
                const SizedBox(width: 10),
                Text(
                  'Netcatty',
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
                ),
                const Spacer(),
                IconButton(
                  tooltip: _grid ? '列表视图' : '网格视图',
                  onPressed: () => setState(() => _grid = !_grid),
                  icon: Icon(
                    _grid ? Icons.view_list_outlined : Icons.grid_view_outlined,
                  ),
                ),
                IconButton(
                  tooltip: '添加主机',
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
              decoration: const InputDecoration(
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
                    label: const Text('全部'),
                    selected: _group == null,
                    onSelected: (_) => setState(() => _group = null),
                  ),
                  const SizedBox(width: 8),
                  for (final group in vault!.customGroups) ...[
                    ChoiceChip(
                      label: Text(group),
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
                          label: const Text('添加主机'),
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: () =>
                            ref.read(vaultControllerProvider.notifier).load(),
                        child: _grid
                            ? GridView.builder(
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
                                  onConnect: () =>
                                      _showHostDetails(hosts[index]),
                                  onEdit: () => _editHost(hosts[index]),
                                ),
                              )
                            : ListView.separated(
                                padding: const EdgeInsets.all(12),
                                itemCount: hosts.length,
                                separatorBuilder: (_, __) =>
                                    const SizedBox(height: 8),
                                itemBuilder: (_, index) => _HostTile(
                                  host: hosts[index],
                                  onConnect: () =>
                                      _showHostDetails(hosts[index]),
                                  onEdit: () => _editHost(hosts[index]),
                                ),
                              ),
                      ),
          ),
        ],
      ),
    );
  }

  Future<void> _connect(HostProfile host) async {
    try {
      await ref.read(sessionControllerProvider.notifier).connect(
            host,
            _verifyHostKey,
            keyboardInteractive: _promptKeyboardInteractive,
          );
      if (mounted) {
        ref.read(homeTabProvider.notifier).state = 1;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已连接，请打开“终端”标签')));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('连接失败：$error')));
      }
    }
  }

  Future<void> _showHostDetails(HostProfile host) async {
    final vault = ref.read(vaultControllerProvider).data;
    final key = vault?.keys.cast<SshKeyProfile?>().firstWhere(
          (value) => value?.id == host.identityFileId,
          orElse: () => null,
        );
    final jumps = host.hostChainIds
        .map((id) => vault?.hosts.cast<HostProfile?>().firstWhere(
              (value) => value?.id == id,
              orElse: () => null,
            ))
        .whereType<HostProfile>()
        .toList();
    final profile = vault?.proxyProfiles.cast<ProxyProfile?>().firstWhere(
          (value) => value?.id == host.proxyProfileId,
          orElse: () => null,
        );
    final proxy = profile?.config ?? host.proxyConfig;
    final action = await showDialog<_HostAction>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.dns_outlined, color: NetcattyTheme.accent),
        title: Text(host.label),
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
            label: const Text('编辑'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(context, _HostAction.connect),
            icon: const Icon(Icons.terminal),
            label: const Text('连接'),
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
            title: Text(changed ? '服务器指纹已变化' : '确认服务器指纹'),
            content: SelectableText(
              '${host.hostname}:${host.port}\n$algorithm\n$fingerprint\n\n'
              '${changed ? '这可能表示服务器重装，也可能是中间人攻击。请重新向管理员核对。' : '首次连接前请与管理员核对。'}',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('拒绝'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(changed ? '确认更新' : '接受并记住'),
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
        title: Text(name.isEmpty ? '交互式认证' : name),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (instruction.isNotEmpty) ...[
                Text(instruction),
                const SizedBox(height: 12),
              ],
              for (var index = 0; index < prompts.length; index++) ...[
                TextField(
                  controller: controllers[index],
                  obscureText: !prompts[index].echo,
                  autofocus: index == 0,
                  decoration: InputDecoration(labelText: prompts[index].text),
                ),
                const SizedBox(height: 10),
              ],
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(
              context,
              controllers.map((value) => value.text).toList(),
            ),
            child: const Text('继续'),
          ),
        ],
      ),
    );
  }

  Future<void> _editHost([HostProfile? host]) async {
    final result = await showModalBottomSheet<HostProfile>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => HostEditor(host: host),
    );
    if (result != null) {
      await ref.read(vaultControllerProvider.notifier).upsertHost(result);
    }
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
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: const Color(0x22f97316),
                        borderRadius: BorderRadius.circular(9),
                      ),
                      child: const Icon(
                        Icons.terminal,
                        size: 20,
                        color: NetcattyTheme.accent,
                      ),
                    ),
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
                Text(
                  host.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 16),
                ),
                const SizedBox(height: 4),
                Text(
                  '${host.username}@${host.hostname}:${host.port}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (host.group?.isNotEmpty == true)
                  Text(
                    host.group!,
                    style: const TextStyle(
                      color: NetcattyTheme.accent,
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
          leading: const CircleAvatar(
            backgroundColor: Color(0x22f97316),
            child: Icon(Icons.terminal, color: NetcattyTheme.accent),
          ),
          title: Text(host.label),
          subtitle: Text('${host.username}@${host.hostname}:${host.port}'),
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
            Icon(icon, size: 19, color: NetcattyTheme.accent),
            const SizedBox(width: 12),
            SizedBox(
              width: 62,
              child: Text(
                label,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            Expanded(child: SelectableText(value)),
          ],
        ),
      );
}

class _LegacyHostEditor extends StatefulWidget {
  const _LegacyHostEditor({required this.host});
  final HostProfile? host;

  @override
  State<_LegacyHostEditor> createState() => _LegacyHostEditorState();
}

class _LegacyHostEditorState extends State<_LegacyHostEditor> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController label;
  late final TextEditingController hostname;
  late final TextEditingController username;
  late final TextEditingController port;
  late final TextEditingController password;
  late final TextEditingController group;
  late HostProtocol protocol;
  var obscure = true;

  @override
  void initState() {
    super.initState();
    final host = widget.host;
    label = TextEditingController(text: host?.label);
    hostname = TextEditingController(text: host?.hostname);
    username = TextEditingController(text: host?.username);
    port = TextEditingController(text: (host?.port ?? 22).toString());
    password = TextEditingController(text: host?.password);
    group = TextEditingController(text: host?.group);
    protocol = host?.protocol ?? HostProtocol.ssh;
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: Scaffold(
          appBar: AppBar(
            leading: IconButton(
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close),
            ),
            title: Text(widget.host == null ? '新建连接' : '编辑连接'),
            actions: [TextButton(onPressed: _save, child: const Text('保存'))],
          ),
          body: Form(
            key: _form,
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SegmentedButton<HostProtocol>(
                  segments: const [
                    ButtonSegment(
                      value: HostProtocol.ssh,
                      label: Text('SSH'),
                      icon: Icon(Icons.lock_outline),
                    ),
                    ButtonSegment(
                      value: HostProtocol.telnet,
                      label: Text('Telnet'),
                      icon: Icon(Icons.cable),
                    ),
                    ButtonSegment(
                      value: HostProtocol.mosh,
                      label: Text('Mosh'),
                      icon: Icon(Icons.wifi_tethering),
                    ),
                  ],
                  selected: {protocol},
                  onSelectionChanged: (value) =>
                      setState(() => protocol = value.first),
                ),
                const SizedBox(height: 20),
                TextFormField(
                  controller: label,
                  decoration: const InputDecoration(labelText: '名称'),
                  validator: _required,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: hostname,
                  decoration: const InputDecoration(labelText: '主机名 / IP'),
                  keyboardType: TextInputType.url,
                  validator: _required,
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: TextFormField(
                        controller: username,
                        decoration: const InputDecoration(labelText: '用户名'),
                        validator: _required,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: port,
                        decoration: const InputDecoration(labelText: '端口'),
                        keyboardType: TextInputType.number,
                        validator: _required,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: password,
                  obscureText: obscure,
                  decoration: InputDecoration(
                    labelText: '密码（可选）',
                    suffixIcon: IconButton(
                      onPressed: () => setState(() => obscure = !obscure),
                      icon: Icon(
                          obscure ? Icons.visibility : Icons.visibility_off),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: group,
                  decoration: const InputDecoration(labelText: '分组（可选）'),
                ),
                const SizedBox(height: 12),
                const Text(
                  '私钥、跳板机、代理、环境变量和高级算法参数可由桌面端同步导入，移动端会完整保留。',
                  style: TextStyle(fontSize: 12, color: Colors.white54),
                ),
              ],
            ),
          ),
        ),
      );

  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? '必填' : null;

  void _save() {
    if (!(_form.currentState?.validate() ?? false)) return;
    final base = widget.host ??
        HostProfile.create(
          id: const Uuid().v4(),
          label: label.text.trim(),
          hostname: hostname.text.trim(),
          username: username.text.trim(),
        );
    Navigator.pop(
      context,
      base.copyWith(
        label: label.text.trim(),
        hostname: hostname.text.trim(),
        username: username.text.trim(),
        port: int.tryParse(port.text) ??
            (protocol == HostProtocol.telnet ? 23 : 22),
        password: password.text,
        group: group.text,
        protocol: protocol,
      ),
    );
  }
}
