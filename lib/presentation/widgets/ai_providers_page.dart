import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../localization/localized_widgets.dart';

import '../../infrastructure/ai/ai_service.dart';
import '../../infrastructure/ai/ai_workspace.dart';

class AiProvidersPage extends StatefulWidget {
  const AiProvidersPage({super.key, required this.workspace});
  final AiWorkspace workspace;
  @override
  State<AiProvidersPage> createState() => _AiProvidersPageState();
}

class _AiProvidersPageState extends State<AiProvidersPage> {
  List<AiProviderProfile>? _profiles;
  String? _error;
  bool _saving = false;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final profiles = await widget.workspace.profiles();
      if (mounted) setState(() => _profiles = profiles);
    } catch (_) {
      if (mounted) setState(() => _error = '无法读取服务商配置，请返回重试');
    }
  }

  Future<void> _save(List<AiProviderProfile> next) async {
    setState(() => _saving = true);
    try {
      await widget.workspace.saveProfiles(next);
      if (mounted) {
        setState(() {
          _profiles = next;
          _error = null;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '保存失败，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _edit([AiProviderProfile? profile]) async {
    final result = await Navigator.of(context).push<AiProviderProfile>(
        MaterialPageRoute(builder: (_) => _ProviderEditor(profile: profile)));
    if (result == null || !mounted) return;
    await _save([..._profiles!.where((p) => p.id != result.id), result]);
  }

  Future<void> _delete(AiProviderProfile profile) async {
    final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
                title: const LText('删除服务商？'),
                content: Text(profile.name),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const LText('取消')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const LText('删除'))
                ]));
    if (confirm == true && mounted) {
      await _save(_profiles!.where((p) => p.id != profile.id).toList());
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const LText('AI 服务商'), actions: [
        IconButton(
            onPressed: _profiles == null || _saving ? null : () => _edit(),
            tooltip: localized('添加服务商'),
            icon: const Icon(Icons.add))
      ]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const LText(
            '支持 OpenAI Chat Completions 兼容接口。服务商及密钥仅保存在本机安全存储中，不修改或同步 PC 的 Agent 配置。原有 AI 设置作为“默认配置”保留。'),
        if (_error != null)
          LText(_error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        if (_profiles == null || _saving) const LinearProgressIndicator(),
        for (final p in _profiles ?? <AiProviderProfile>[])
          ListTile(
              title: Text(p.name),
              subtitle: LText('${p.endpoint}\n${p.models.length} 个模型'),
              onTap: _saving ? null : () => _edit(p),
              trailing: IconButton(
                  tooltip: localized('删除'),
                  onPressed: _saving ? null : () => _delete(p),
                  icon: const Icon(Icons.delete_outline))),
      ]));
}

class _ProviderEditor extends StatefulWidget {
  const _ProviderEditor({this.profile});
  final AiProviderProfile? profile;
  @override
  State<_ProviderEditor> createState() => _ProviderEditorState();
}

class _ProviderEditorState extends State<_ProviderEditor> {
  final _name = TextEditingController(),
      _endpoint = TextEditingController(),
      _key = TextEditingController(),
      _models = TextEditingController();
  bool _json = false, _reasoning = true, _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    final p = widget.profile;
    _name.text = p?.name ?? '';
    _endpoint.text = p?.endpoint ?? 'https://';
    _key.text = p?.apiKey ?? '';
    _models.text = p?.models.join('\n') ?? '';
    _json = p?.jsonMode ?? false;
    _reasoning = p?.reasoning ?? true;
  }

  @override
  void dispose() {
    for (final c in [_name, _endpoint, _key, _models]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _fetch() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final service = AiService();
    try {
      final models = await service.fetchModels(
          endpoint: _endpoint.text, apiKey: _key.text);
      if (mounted) setState(() => _models.text = models.join('\n'));
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      service.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  void _save() {
    final uri = Uri.tryParse(_endpoint.text.trim());
    final models = _models.text
        .split(RegExp(r'[\n,]'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet()
        .toList();
    if (_name.text.trim().isEmpty ||
        uri == null ||
        !['https', 'http'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        models.isEmpty) {
      setState(() => _error = '请填写名称、有效 API 地址（不含账号、查询参数）和至少一个模型');
      return;
    }
    Navigator.pop(
        context,
        AiProviderProfile(
            id: widget.profile?.id ?? const Uuid().v4(),
            name: _name.text.trim(),
            endpoint: _endpoint.text.trim(),
            apiKey: _key.text.trim(),
            models: models,
            jsonMode: _json,
            reasoning: _reasoning));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
      appBar: AppBar(title: const LText('服务商配置'), actions: [
        TextButton(onPressed: _busy ? null : _save, child: const LText('保存'))
      ]),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(
            controller: _name, decoration: LInputDecoration(labelText: '名称')),
        TextField(
            controller: _endpoint,
            decoration: LInputDecoration(labelText: 'API 地址（通常以 /v1 结尾）')),
        TextField(
            controller: _key,
            obscureText: true,
            decoration: LInputDecoration(labelText: 'API Key（无鉴权接口可留空）')),
        OutlinedButton(
            onPressed: _busy ? null : _fetch,
            child: LText(_busy ? '正在拉取…' : '自动拉取模型')),
        TextField(
            controller: _models,
            minLines: 3,
            maxLines: 8,
            decoration: LInputDecoration(labelText: '模型列表（每行一个）')),
        SwitchListTile(
            title: const LText('发送 JSON 模式参数'),
            subtitle: const LText('默认关闭；仍会通过提示词请求结构化命令'),
            value: _json,
            onChanged: (v) => setState(() => _json = v)),
        SwitchListTile(
            title: const LText('发送思考强度参数'),
            subtitle: const LText('不支持 reasoning_effort 的模型请关闭'),
            value: _reasoning,
            onChanged: (v) => setState(() => _reasoning = v)),
        if (_error != null)
          LText(_error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ]));
}
