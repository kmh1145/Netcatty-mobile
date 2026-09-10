import 'package:flutter/material.dart';
import 'package:netcatty_mobile/presentation/localization/localized_widgets.dart';

import '../../../domain/models/system_management.dart';
import '../../../infrastructure/ssh/ssh_service.dart';
import '../../../infrastructure/ssh/system_management_service.dart';

class CaddyManagerPanel extends StatefulWidget {
  const CaddyManagerPanel({
    super.key,
    required this.session,
    required this.service,
  });

  final ActiveTerminalSession session;
  final SystemManagementService service;

  @override
  State<CaddyManagerPanel> createState() => _CaddyManagerPanelState();
}

class _CaddyManagerPanelState extends State<CaddyManagerPanel> {
  final _search = TextEditingController();
  final _busy = <String>{};
  CaddyStatus? _status;
  List<CaddySite> _sites = const [];
  Object? _error;
  var _loading = true;

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

  List<CaddySite> get _visibleSites {
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) return _sites;
    return _sites
        .where((site) =>
            site.address.toLowerCase().contains(query) ||
            site.upstreams.any(
              (upstream) => upstream.toLowerCase().contains(query),
            ))
        .toList(growable: false);
  }

  Future<void> _refresh() async {
    if (mounted) setState(() => _loading = true);
    try {
      final status = await widget.service.caddyStatus(widget.session);
      final sites = status.installed
          ? await widget.service.listCaddySites(widget.session, status)
          : const <CaddySite>[];
      if (!mounted) return;
      setState(() {
        _status = status;
        _sites = sites;
        _error = null;
      });
    } catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<T> _withSudo<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on CaddySudoPasswordRequired catch (error) {
      final password = await _requestSudoPassword(error.message);
      if (password == null) throw const _CaddyActionCancelled();
      widget.service.setCaddySudoPassword(widget.session, password);
      return action();
    }
  }

  Future<String?> _requestSudoPassword(String message) async {
    return showDialog<String>(
      context: context,
      builder: (context) => _CaddySudoPasswordDialog(message: message),
    );
  }

  Future<void> _edit([CaddySite? existing]) async {
    final status = _status;
    if (status?.installed != true) return;
    final site = await _siteDialog(existing);
    if (site == null || !mounted) return;
    setState(() => _busy.add(site.id));
    try {
      await _withSudo(
        () => widget.service.saveCaddySite(widget.session, status!, site),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: LText('Caddy 配置已更新并重新加载')),
      );
      await _refresh();
    } on _CaddyActionCancelled {
      // The password dialog was intentionally dismissed.
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${localized('Caddy 操作失败')}：$error')),
      );
    } finally {
      if (mounted) setState(() => _busy.remove(site.id));
    }
  }

  Future<void> _delete(CaddySite site) async {
    final status = _status;
    if (status?.installed != true || _busy.contains(site.id)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.delete_outline),
        title: const LText('删除反向代理站点？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(site.address),
            const SizedBox(height: 12),
            const LText('删除后 Caddy 会立即重新加载配置，此操作无法撤销。'),
          ],
        ),
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
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy.add(site.id));
    try {
      await _withSudo(
        () => widget.service.deleteCaddySite(widget.session, status!, site),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: LText('反向代理站点已删除')),
      );
      await _refresh();
    } on _CaddyActionCancelled {
      // The password dialog was intentionally dismissed.
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${localized('Caddy 操作失败')}：$error')),
      );
    } finally {
      if (mounted) setState(() => _busy.remove(site.id));
    }
  }

  Future<CaddySite?> _siteDialog(CaddySite? existing) => showDialog<CaddySite>(
        context: context,
        builder: (context) => _CaddySiteDialog(
          existing: existing,
          service: widget.service,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final status = _status;
    final sites = _visibleSites;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('caddy-search'),
                  controller: _search,
                  enabled: status?.installed == true,
                  decoration: LInputDecoration(
                    hintText: '搜索站点或上游地址',
                    prefixIcon: Icon(Icons.search),
                  ),
                ),
              ),
              IconButton(
                tooltip: localized('刷新'),
                onPressed: _loading ? null : _refresh,
                icon: const Icon(Icons.refresh),
              ),
              IconButton.filled(
                key: const ValueKey('caddy-add'),
                tooltip: localized('新增反向代理'),
                onPressed: status?.installed == true && !_loading
                    ? () => _edit()
                    : null,
                icon: const Icon(Icons.add),
              ),
            ],
          ),
        ),
        if (status?.installed == true)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 12, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LText(
                    status!.version.isEmpty ? 'Caddy' : status.version,
                    style: Theme.of(context).textTheme.labelLarge,
                  ),
                  const SizedBox(height: 2),
                  LText(
                    'Netcatty 创建的反向代理会直接保存到该 Caddyfile。',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  Row(
                    children: [
                      LText(
                        '配置入口：',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      Expanded(
                        child: Text(
                          status.configPath,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        Expanded(child: _buildContent(sites)),
      ],
    );
  }

  Widget _buildContent(List<CaddySite> sites) {
    if (_loading && _status == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_status?.installed == false) {
      return _message(
        Icons.public_off_outlined,
        caddyNotFoundMessage,
      );
    }
    if (_error != null && _sites.isEmpty) {
      return _message(
        Icons.error_outline,
        '${localized('无法读取 Caddy 配置')}：$_error',
        retry: true,
        localizedMessage: false,
      );
    }
    if (sites.isEmpty) {
      return _message(
        Icons.language_outlined,
        _search.text.trim().isEmpty
            ? '还没有由 Netcatty 管理的反向代理站点'
            : '没有符合条件的反向代理站点',
      );
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 24),
        itemCount: sites.length,
        itemBuilder: (context, index) {
          final site = sites[index];
          final busy = _busy.contains(site.id);
          return Card(
            child: ListTile(
              leading: const CircleAvatar(
                child: Icon(Icons.swap_horiz),
              ),
              title: Text(
                site.address,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                site.upstreams.join(' · '),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: busy
                  ? const SizedBox.square(
                      dimension: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : PopupMenuButton<String>(
                      onSelected: (action) =>
                          action == 'edit' ? _edit(site) : _delete(site),
                      itemBuilder: (_) => const [
                        PopupMenuItem(
                          value: 'edit',
                          child: ListTile(
                            leading: Icon(Icons.edit_outlined),
                            title: LText('编辑'),
                          ),
                        ),
                        PopupMenuItem(
                          value: 'delete',
                          child: ListTile(
                            leading: Icon(Icons.delete_outline),
                            title: LText('删除'),
                          ),
                        ),
                      ],
                    ),
              onTap: busy ? null : () => _edit(site),
            ),
          );
        },
      ),
    );
  }

  Widget _message(
    IconData icon,
    String message, {
    bool retry = false,
    bool localizedMessage = true,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48),
            const SizedBox(height: 12),
            if (localizedMessage)
              LText(message, textAlign: TextAlign.center)
            else
              Text(message, textAlign: TextAlign.center),
            if (retry) ...[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _refresh,
                icon: const Icon(Icons.refresh),
                label: const LText('重试'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CaddyActionCancelled implements Exception {
  const _CaddyActionCancelled();
}

class _CaddySudoPasswordDialog extends StatefulWidget {
  const _CaddySudoPasswordDialog({required this.message});

  final String message;

  @override
  State<_CaddySudoPasswordDialog> createState() =>
      _CaddySudoPasswordDialogState();
}

class _CaddySudoPasswordDialogState extends State<_CaddySudoPasswordDialog> {
  final controller = TextEditingController();
  var obscure = true;

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (controller.text.isNotEmpty) {
      Navigator.pop(context, controller.text);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        icon: const Icon(Icons.lock_outline),
        title: const LText('需要 sudo 权限'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LText(widget.message),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                obscureText: obscure,
                onSubmitted: (_) => _submit(),
                decoration: LInputDecoration(
                  labelText: 'sudo 密码',
                  helperText: '密码仅在本次系统管理面板打开期间保留',
                  suffixIcon: IconButton(
                    onPressed: () => setState(() => obscure = !obscure),
                    icon: Icon(
                      obscure ? Icons.visibility : Icons.visibility_off,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const LText('取消'),
          ),
          FilledButton(
            onPressed: _submit,
            child: const LText('继续'),
          ),
        ],
      );
}

class _CaddySiteDialog extends StatefulWidget {
  const _CaddySiteDialog({required this.existing, required this.service});

  final CaddySite? existing;
  final SystemManagementService service;

  @override
  State<_CaddySiteDialog> createState() => _CaddySiteDialogState();
}

class _CaddySiteDialogState extends State<_CaddySiteDialog> {
  late final address = TextEditingController(
    text: widget.existing?.address ?? '',
  );
  late final upstreams = TextEditingController(
    text: widget.existing?.upstreams.join('\n') ?? '',
  );
  String? validationError;

  @override
  void dispose() {
    address.dispose();
    upstreams.dispose();
    super.dispose();
  }

  void _submit() {
    final values = upstreams.text
        .split(RegExp(r'[,\r\n]+'))
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList(growable: false);
    final site = CaddySite(
      id: widget.existing?.id ??
          'site-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
      address: address.text.trim(),
      upstreams: values,
    );
    try {
      widget.service.buildCaddySiteSnippet(site);
      Navigator.pop(context, site);
    } on FormatException catch (error) {
      setState(() => validationError = error.message);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        icon: const Icon(Icons.language_outlined),
        title: LText(
          widget.existing == null ? '新增反向代理' : '编辑反向代理',
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                key: const ValueKey('caddy-address'),
                controller: address,
                autofocus: true,
                textInputAction: TextInputAction.next,
                scrollPadding: const EdgeInsets.only(bottom: 160),
                decoration: LInputDecoration(
                  labelText: '站点地址',
                  hintText: 'example.com',
                  helperText: '可使用域名、IP、端口或 http:// 地址',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                key: const ValueKey('caddy-upstreams'),
                controller: upstreams,
                minLines: 2,
                maxLines: 5,
                keyboardType: TextInputType.multiline,
                scrollPadding: const EdgeInsets.only(bottom: 160),
                decoration: LInputDecoration(
                  labelText: '上游地址',
                  hintText: '127.0.0.1:8080',
                  helperText: '多个上游地址使用换行或逗号分隔',
                  errorText: validationError,
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const LText('取消'),
          ),
          FilledButton(
            key: const ValueKey('caddy-save'),
            onPressed: _submit,
            child: const LText('保存并重新加载'),
          ),
        ],
      );
}
