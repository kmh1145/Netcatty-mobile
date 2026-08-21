import 'package:flutter/material.dart';
import 'package:netcatty_mobile/presentation/localization/localized_widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../application/vault_controller.dart';
import '../../domain/models/host.dart';
import 'keychain_sheet.dart';

class HostEditor extends ConsumerStatefulWidget {
  const HostEditor({super.key, this.host, this.onDelete});

  final HostProfile? host;
  final Future<bool> Function()? onDelete;

  @override
  ConsumerState<HostEditor> createState() => _HostEditorState();
}

class _HostEditorState extends ConsumerState<HostEditor> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController label;
  late final TextEditingController hostname;
  late final TextEditingController username;
  late final TextEditingController port;
  late final TextEditingController password;
  late final TextEditingController group;
  late final TextEditingController tags;
  late final TextEditingController startupCommand;
  late final TextEditingController proxyHost;
  late final TextEditingController proxyPort;
  late final TextEditingController proxyUsername;
  late final TextEditingController proxyPassword;
  late final TextEditingController keepalive;
  late final TextEditingController connectTimeout;
  late final TextEditingController authTimeout;
  late HostProtocol protocol;
  late HostAuthMethod authMethod;
  late ProxyType proxyType;
  late List<String> jumpHostIds;
  String? identityFileId;
  String proxyMode = 'none';
  bool obscurePassword = true;
  bool obscureProxyPassword = true;
  bool pinned = false;

  @override
  void initState() {
    super.initState();
    final host = widget.host;
    final proxy = host?.proxyConfig;
    label = TextEditingController(text: host?.label);
    hostname = TextEditingController(text: host?.hostname);
    username = TextEditingController(text: host?.username);
    port = TextEditingController(text: (host?.port ?? 22).toString());
    password = TextEditingController(text: host?.password);
    group = TextEditingController(text: host?.group);
    tags = TextEditingController(text: host?.tags.join(', '));
    startupCommand = TextEditingController(text: host?.startupCommand);
    proxyHost = TextEditingController(text: proxy?.host);
    proxyPort = TextEditingController(
      text: proxy == null || proxy.port == 0 ? '' : proxy.port.toString(),
    );
    proxyUsername = TextEditingController(text: proxy?.username);
    proxyPassword = TextEditingController(text: proxy?.password);
    keepalive = TextEditingController(
      text:
          ((host?.data['keepaliveInterval'] as num?)?.toInt() ?? 10).toString(),
    );
    connectTimeout = TextEditingController(
      text: ((host?.data['sshTcpConnectTimeoutSeconds'] as num?)?.toInt() ?? 15)
          .toString(),
    );
    authTimeout = TextEditingController(
      text: ((host?.data['sshAuthReadyTimeoutSeconds'] as num?)?.toInt() ?? 30)
          .toString(),
    );
    protocol = host?.protocol ?? HostProtocol.ssh;
    authMethod = host?.authMethod ?? HostAuthMethod.auto;
    identityFileId = host?.identityFileId;
    jumpHostIds = [...?host?.hostChainIds];
    proxyType = proxy?.type ?? ProxyType.http;
    proxyMode = host?.proxyProfileId?.isNotEmpty == true
        ? 'profile:${host!.proxyProfileId}'
        : proxy == null
            ? 'none'
            : 'custom';
    pinned = host?.pinned ?? false;
  }

  @override
  void dispose() {
    for (final controller in [
      label,
      hostname,
      username,
      port,
      password,
      group,
      tags,
      startupCommand,
      proxyHost,
      proxyPort,
      proxyUsername,
      proxyPassword,
      keepalive,
      connectTimeout,
      authTimeout,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vault = ref.watch(vaultControllerProvider).data;
    final keys = vault?.keys ?? const <SshKeyProfile>[];
    final availableHosts = (vault?.hosts ?? const <HostProfile>[])
        .where((value) =>
            value.id != widget.host?.id &&
            value.protocol == HostProtocol.ssh &&
            !jumpHostIds.contains(value.id))
        .toList();
    final profiles = vault?.proxyProfiles ?? const <ProxyProfile>[];
    if (identityFileId != null &&
        !keys.any((value) => value.id == identityFileId)) {
      identityFileId = null;
    }
    if (proxyMode.startsWith('profile:') &&
        !profiles.any((value) => 'profile:${value.id}' == proxyMode)) {
      proxyMode = 'none';
    }

    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.close),
        ),
        title: LText(widget.host == null ? '新建连接' : '编辑连接'),
        actions: [TextButton(onPressed: _save, child: const LText('保存'))],
      ),
      body: Form(
        key: _form,
        child: ListView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            SegmentedButton<HostProtocol>(
              segments: const [
                ButtonSegment(
                  value: HostProtocol.ssh,
                  label: LText('SSH'),
                  icon: Icon(Icons.lock_outline),
                ),
                ButtonSegment(
                  value: HostProtocol.telnet,
                  label: LText('Telnet'),
                  icon: Icon(Icons.cable),
                ),
                ButtonSegment(
                  value: HostProtocol.mosh,
                  label: LText('Mosh'),
                  icon: Icon(Icons.wifi_tethering),
                ),
              ],
              selected: {protocol},
              onSelectionChanged: (value) => setState(() {
                protocol = value.first;
                if (port.text == '22' || port.text == '23') {
                  port.text = protocol == HostProtocol.telnet ? '23' : '22';
                }
              }),
            ),
            _section('基本信息'),
            TextFormField(
              controller: label,
              decoration: LInputDecoration(labelText: '名称'),
              validator: _required,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: hostname,
              decoration: LInputDecoration(labelText: '主机名 / IP'),
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
                    decoration: LInputDecoration(labelText: '用户名'),
                    validator: _required,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextFormField(
                    controller: port,
                    decoration: LInputDecoration(labelText: '端口'),
                    keyboardType: TextInputType.number,
                    validator: _validPort,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: group,
              decoration: LInputDecoration(labelText: '分组（可选）'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: tags,
              decoration: LInputDecoration(
                labelText: '标签（逗号分隔）',
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const LText('置顶显示'),
              value: pinned,
              onChanged: (value) => setState(() => pinned = value),
            ),
            if (protocol != HostProtocol.telnet) ...[
              _section('身份认证'),
              DropdownButtonFormField<HostAuthMethod>(
                initialValue: authMethod,
                decoration: LInputDecoration(labelText: '认证方式'),
                items: const [
                  DropdownMenuItem(
                    value: HostAuthMethod.auto,
                    child: LText('自动（私钥 / 密码 / 交互式）'),
                  ),
                  DropdownMenuItem(
                    value: HostAuthMethod.password,
                    child: LText('密码'),
                  ),
                  DropdownMenuItem(
                    value: HostAuthMethod.key,
                    child: LText('私钥'),
                  ),
                ],
                onChanged: (value) =>
                    setState(() => authMethod = value ?? HostAuthMethod.auto),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: password,
                obscureText: obscurePassword,
                decoration: LInputDecoration(
                  labelText: '密码（可选）',
                  suffixIcon: IconButton(
                    onPressed: () =>
                        setState(() => obscurePassword = !obscurePassword),
                    icon: Icon(
                      obscurePassword ? Icons.visibility : Icons.visibility_off,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: identityFileId,
                      decoration: LInputDecoration(labelText: 'SSH 私钥'),
                      items: [
                        const DropdownMenuItem(
                          value: '',
                          child: LText('不指定'),
                        ),
                        for (final key in keys)
                          DropdownMenuItem(
                            value: key.id,
                            child: LText(key.label),
                          ),
                      ],
                      onChanged: (value) => setState(
                        () => identityFileId =
                            value?.isEmpty == true ? null : value,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    tooltip: localized('管理私钥'),
                    onPressed: _openKeychain,
                    icon: const Icon(Icons.key_outlined),
                  ),
                ],
              ),
              if (authMethod == HostAuthMethod.key && identityFileId == null)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: LText(
                    '私钥认证需要选择或导入私钥。',
                    style: TextStyle(color: Colors.redAccent, fontSize: 12),
                  ),
                ),
              _section('跳板机'),
              if (jumpHostIds.isEmpty)
                const ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.alt_route),
                  title: LText('直接连接'),
                  subtitle: LText('未设置 SSH 跳板机'),
                )
              else
                ReorderableListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: jumpHostIds.length,
                  onReorderItem: (oldIndex, newIndex) => setState(() {
                    final id = jumpHostIds.removeAt(oldIndex);
                    jumpHostIds.insert(newIndex, id);
                  }),
                  itemBuilder: (context, index) {
                    final id = jumpHostIds[index];
                    final jump = vault?.hosts.cast<HostProfile?>().firstWhere(
                          (value) => value?.id == id,
                          orElse: () => null,
                        );
                    return ListTile(
                      key: ValueKey(id),
                      contentPadding: EdgeInsets.zero,
                      leading: CircleAvatar(child: LText('${index + 1}')),
                      title: LText(jump?.label ?? '缺失的主机'),
                      subtitle: jump == null
                          ? LText(id)
                          : LText(
                              '${jump.username}@${jump.hostname}:${jump.port}'),
                      trailing: IconButton(
                        onPressed: () =>
                            setState(() => jumpHostIds.removeAt(index)),
                        icon: const Icon(Icons.remove_circle_outline),
                      ),
                    );
                  },
                ),
              if (availableHosts.isNotEmpty)
                DropdownButtonFormField<String>(
                  decoration: LInputDecoration(
                    labelText: '添加跳板机',
                    prefixIcon: Icon(Icons.add_road),
                  ),
                  items: [
                    for (final value in availableHosts)
                      DropdownMenuItem(
                        value: value.id,
                        child: LText(value.label),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) setState(() => jumpHostIds.add(value));
                  },
                ),
              _section('代理'),
              DropdownButtonFormField<String>(
                initialValue: proxyMode,
                decoration: LInputDecoration(labelText: '代理方式'),
                items: [
                  const DropdownMenuItem(
                    value: 'none',
                    child: LText('不使用代理'),
                  ),
                  const DropdownMenuItem(
                    value: 'custom',
                    child: LText('自定义 HTTP / SOCKS5 代理'),
                  ),
                  for (final profile in profiles)
                    DropdownMenuItem(
                      value: 'profile:${profile.id}',
                      child: LText('已保存 · ${profile.label}'),
                    ),
                ],
                onChanged: (value) =>
                    setState(() => proxyMode = value ?? 'none'),
              ),
              if (proxyMode == 'custom') ...[
                const SizedBox(height: 12),
                SegmentedButton<ProxyType>(
                  segments: const [
                    ButtonSegment(value: ProxyType.http, label: LText('HTTP')),
                    ButtonSegment(
                      value: ProxyType.socks5,
                      label: LText('SOCKS5'),
                    ),
                  ],
                  selected: {proxyType},
                  onSelectionChanged: (value) =>
                      setState(() => proxyType = value.first),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      flex: 2,
                      child: TextFormField(
                        controller: proxyHost,
                        decoration: LInputDecoration(labelText: '代理主机'),
                        validator: proxyMode == 'custom' ? _required : null,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextFormField(
                        controller: proxyPort,
                        decoration: LInputDecoration(labelText: '端口'),
                        keyboardType: TextInputType.number,
                        validator: proxyMode == 'custom' ? _validPort : null,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: proxyUsername,
                  decoration: LInputDecoration(labelText: '代理用户名（可选）'),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: proxyPassword,
                  obscureText: obscureProxyPassword,
                  decoration: LInputDecoration(
                    labelText: '代理密码（可选）',
                    suffixIcon: IconButton(
                      onPressed: () => setState(
                        () => obscureProxyPassword = !obscureProxyPassword,
                      ),
                      icon: Icon(
                        obscureProxyPassword
                            ? Icons.visibility
                            : Icons.visibility_off,
                      ),
                    ),
                  ),
                ),
              ],
              _section('高级选项'),
              TextFormField(
                controller: startupCommand,
                minLines: 1,
                maxLines: 4,
                decoration: LInputDecoration(labelText: '连接后执行命令（可选）'),
              ),
              const SizedBox(height: 12),
              LayoutBuilder(
                builder: (context, constraints) {
                  final fields = [
                    _AdvancedNumberField(
                      controller: keepalive,
                      label: 'Keepalive 间隔',
                      helper: '每隔多少秒发送一次保活消息',
                    ),
                    _AdvancedNumberField(
                      controller: connectTimeout,
                      label: '连接超时',
                      helper: '建立 TCP 连接的最长等待时间',
                    ),
                    _AdvancedNumberField(
                      controller: authTimeout,
                      label: '认证超时',
                      helper: 'SSH 身份认证的最长等待时间',
                    ),
                  ];
                  if (constraints.maxWidth < 720) {
                    return Column(
                      children: [
                        for (var index = 0; index < fields.length; index++) ...[
                          fields[index],
                          if (index < fields.length - 1)
                            const SizedBox(height: 12),
                        ],
                      ],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var index = 0; index < fields.length; index++) ...[
                        Expanded(child: fields[index]),
                        if (index < fields.length - 1)
                          const SizedBox(width: 12),
                      ],
                    ],
                  );
                },
              ),
              if (widget.host != null && widget.onDelete != null) ...[
                const SizedBox(height: 28),
                OutlinedButton.icon(
                  key: const ValueKey('delete-host-from-editor'),
                  onPressed: _delete,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                    side:
                        BorderSide(color: Theme.of(context).colorScheme.error),
                  ),
                  icon: const Icon(Icons.delete_outline),
                  label: const LText('删除此服务器'),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 22, 2, 10),
        child: LText(
          title,
          style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
        ),
      );

  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? '必填' : null;

  String? _validPort(String? value) {
    final parsed = int.tryParse(value ?? '');
    return parsed == null || parsed < 1 || parsed > 65535 ? '端口无效' : null;
  }

  Future<void> _openKeychain() => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        builder: (_) => const KeychainSheet(),
      );

  Future<void> _delete() async {
    FocusManager.instance.primaryFocus?.unfocus();
    if (await widget.onDelete!() && mounted) Navigator.pop(context);
  }

  void _save() {
    if (!(_form.currentState?.validate() ?? false)) return;
    if (authMethod == HostAuthMethod.key && identityFileId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: LText('请选择用于认证的 SSH 私钥')),
      );
      return;
    }
    final base = widget.host ??
        HostProfile.create(
          id: const Uuid().v4(),
          label: label.text.trim(),
          hostname: hostname.text.trim(),
          username: username.text.trim(),
        );
    final data = Map<String, dynamic>.from(base.data)
      ..['label'] = label.text.trim()
      ..['hostname'] = hostname.text.trim()
      ..['username'] = username.text.trim()
      ..['port'] = int.parse(port.text)
      ..['protocol'] = protocol.name
      ..['authMethod'] = authMethod.name
      ..['savePassword'] = true
      ..['pinned'] = pinned
      ..['tags'] = tags.text
          .split(RegExp(r'[,，]'))
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toList()
      ..['keepaliveOverride'] = true
      ..['keepaliveInterval'] = int.tryParse(keepalive.text) ?? 10
      ..['sshTcpConnectTimeoutSeconds'] =
          int.tryParse(connectTimeout.text) ?? 15
      ..['sshAuthReadyTimeoutSeconds'] = int.tryParse(authTimeout.text) ?? 30;
    _setOrRemove(data, 'password', password.text.trim());
    _setOrRemove(data, 'group', group.text.trim());
    _setOrRemove(data, 'identityFileId', identityFileId);
    _setOrRemove(data, 'startupCommand', startupCommand.text.trim());
    if (jumpHostIds.isEmpty) {
      data.remove('hostChain');
    } else {
      data['hostChain'] = {
        'hostIds': [...jumpHostIds]
      };
    }
    if (proxyMode == 'none') {
      data.remove('proxyProfileId');
      data.remove('proxyConfig');
    } else if (proxyMode.startsWith('profile:')) {
      data['proxyProfileId'] = proxyMode.substring('profile:'.length);
      data.remove('proxyConfig');
    } else {
      data.remove('proxyProfileId');
      data['proxyConfig'] = ProxyConfig(
        type: proxyType,
        host: proxyHost.text.trim(),
        port: int.parse(proxyPort.text),
        username: proxyUsername.text.trim(),
        password: proxyPassword.text,
      ).toJson();
    }
    Navigator.pop(context, HostProfile(data));
  }

  void _setOrRemove(Map<String, dynamic> data, String key, String? value) {
    if (value == null || value.isEmpty) {
      data.remove(key);
    } else {
      data[key] = value;
    }
  }
}

class _AdvancedNumberField extends StatelessWidget {
  const _AdvancedNumberField({
    required this.controller,
    required this.label,
    required this.helper,
  });

  final TextEditingController controller;
  final String label;
  final String helper;

  @override
  Widget build(BuildContext context) => TextFormField(
        controller: controller,
        keyboardType: TextInputType.number,
        decoration: LInputDecoration(
          labelText: label,
          helperText: helper,
          suffixText: '秒',
          helperMaxLines: 2,
        ),
      );
}
