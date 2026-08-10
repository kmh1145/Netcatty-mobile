import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../application/settings_controller.dart';
import '../../application/vault_controller.dart';
import '../../domain/models/settings.dart';
import '../../domain/models/vault.dart';
import '../../infrastructure/storage/vault_repository.dart';
import '../../infrastructure/sync/cloud_sync_service.dart';
import '../../infrastructure/sync/github_auth_service.dart';
import '../theme.dart';
import '../widgets/keychain_sheet.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final endpoint = TextEditingController();
  final username = TextEditingController();
  final providerSecret = TextEditingController();
  final resourceId = TextEditingController();
  final masterPassword = TextEditingController();
  final aiEndpoint = TextEditingController();
  final aiModel = TextEditingController();
  final aiKey = TextEditingController();
  var provider = SyncProviderType.webdav;
  var themeMode = 'dark';
  var uiThemeId = 'tokyo-night';
  var terminalFontSize = 14.0;
  var _loaded = false;
  var _busy = false;
  String? _githubUser;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _load();
    }
  }

  Future<void> _load() async {
    final repository = ref.read(vaultRepositoryProvider);
    final sync = await repository.loadSyncConnection();
    final settings = await repository.loadSettings();
    endpoint.text = sync?.endpoint ?? '';
    username.text = sync?.username ?? '';
    providerSecret.text = sync?.secret ?? '';
    resourceId.text = sync?.resourceId ?? '';
    masterPassword.text = await repository.readMasterPassword() ?? '';
    aiEndpoint.text = settings.aiEndpoint;
    aiModel.text = settings.aiModel;
    themeMode = settings.themeMode;
    uiThemeId = settings.uiThemeId;
    terminalFontSize = settings.terminalFontSize;
    aiKey.text = await repository.readAiApiKey() ?? '';
    _githubUser =
        sync?.type == SyncProviderType.githubGist ? sync?.username : null;
    if (mounted) {
      setState(() => provider = sync?.type ?? SyncProviderType.webdav);
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Scaffold(
          appBar: AppBar(title: const Text('设置')),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            children: [
              _header('外观与终端', '移动端偏好不会覆盖桌面端专属布局字段'),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    children: [
                      SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(
                            value: 'dark',
                            label: Text('深色'),
                            icon: Icon(Icons.dark_mode_outlined),
                          ),
                          ButtonSegment(
                            value: 'light',
                            label: Text('浅色'),
                            icon: Icon(Icons.light_mode_outlined),
                          ),
                          ButtonSegment(
                            value: 'system',
                            label: Text('系统'),
                            icon: Icon(Icons.brightness_auto_outlined),
                          ),
                        ],
                        selected: {themeMode},
                        onSelectionChanged: (value) =>
                            setState(() => themeMode = value.first),
                      ),
                      const SizedBox(height: 12),
                      Builder(
                        builder: (context) {
                          final brightness = themeMode == 'light'
                              ? Brightness.light
                              : themeMode == 'dark'
                                  ? Brightness.dark
                                  : MediaQuery.platformBrightnessOf(context);
                          final selected =
                              NetcattyTheme.resolve(brightness, uiThemeId);
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: CircleAvatar(
                              backgroundColor: selected.background,
                              child: Icon(
                                Icons.palette_outlined,
                                color: selected.primary,
                              ),
                            ),
                            title: const Text('界面主题'),
                            subtitle: Text(
                              '${selected.name} · ${NetcattyTheme.presets(brightness).length} 种可选',
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => _selectTheme(brightness),
                          );
                        },
                      ),
                      Row(
                        children: [
                          const Text('终端字号'),
                          Expanded(
                            child: Slider(
                              value: terminalFontSize,
                              min: 10,
                              max: 24,
                              divisions: 14,
                              label: terminalFontSize.toStringAsFixed(0),
                              onChanged: (value) =>
                                  setState(() => terminalFontSize = value),
                            ),
                          ),
                          Text(terminalFontSize.toStringAsFixed(0)),
                        ],
                      ),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton(
                          onPressed: _saveAppearance,
                          child: const Text('保存外观设置'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              _header('云同步', '兼容桌面端 netcatty-vault.json 加密格式'),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    children: [
                      SegmentedButton<SyncProviderType>(
                        segments: const [
                          ButtonSegment(
                            value: SyncProviderType.webdav,
                            label: Text('WebDAV'),
                            icon: Icon(Icons.cloud_outlined),
                          ),
                          ButtonSegment(
                            value: SyncProviderType.githubGist,
                            label: Text('GitHub Gist'),
                            icon: Icon(Icons.code),
                          ),
                        ],
                        selected: {provider},
                        onSelectionChanged: (value) =>
                            setState(() => provider = value.first),
                      ),
                      const SizedBox(height: 14),
                      if (provider == SyncProviderType.webdav) ...[
                        TextField(
                          controller: endpoint,
                          keyboardType: TextInputType.url,
                          decoration: const InputDecoration(
                            labelText: 'WebDAV 地址',
                            hintText: 'https://dav.example.com/netcatty',
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: username,
                          decoration: const InputDecoration(labelText: '用户名'),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: providerSecret,
                          obscureText: true,
                          decoration:
                              const InputDecoration(labelText: '密码 / 应用密码'),
                        ),
                      ] else ...[
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: CircleAvatar(
                            child: Icon(
                              providerSecret.text.isEmpty
                                  ? Icons.login
                                  : Icons.check,
                            ),
                          ),
                          title: Text(
                            providerSecret.text.isEmpty
                                ? '尚未登录 GitHub'
                                : '已连接 GitHub',
                          ),
                          subtitle: Text(
                            _githubUser == null
                                ? '登录后自动查找或创建 Netcatty Gist'
                                : '@$_githubUser · 自动同步私有 Gist',
                          ),
                        ),
                        SizedBox(
                          width: double.infinity,
                          child: providerSecret.text.isEmpty
                              ? FilledButton.icon(
                                  onPressed: _busy ? null : _connectGitHub,
                                  icon: const Icon(Icons.login),
                                  label: const Text('登录 GitHub'),
                                )
                              : OutlinedButton.icon(
                                  onPressed: _busy ? null : _logoutGitHub,
                                  icon: const Icon(Icons.logout),
                                  label: const Text('退出 GitHub'),
                                ),
                        ),
                        ExpansionTile(
                          tilePadding: EdgeInsets.zero,
                          title: const Text('高级 / 手动配置'),
                          subtitle: const Text('仅用于迁移或登录故障排查'),
                          children: [
                            TextField(
                              controller: resourceId,
                              decoration: const InputDecoration(
                                labelText: 'Gist ID（通常自动识别）',
                              ),
                            ),
                            const SizedBox(height: 10),
                            TextField(
                              controller: providerSecret,
                              obscureText: true,
                              onChanged: (_) => setState(() {}),
                              decoration: const InputDecoration(
                                labelText: 'GitHub Token（备用）',
                              ),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 10),
                      TextField(
                        controller: masterPassword,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'Netcatty 同步主密码',
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed:
                                  _busy ? null : () => _sync(push: false),
                              icon: const Icon(Icons.cloud_download_outlined),
                              label: const Text('拉取并合并'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: _busy ? null : () => _sync(push: true),
                              icon: const Icon(Icons.cloud_upload_outlined),
                              label: const Text('上传'),
                            ),
                          ),
                        ],
                      ),
                      if (_busy)
                        const Padding(
                          padding: EdgeInsets.only(top: 12),
                          child: LinearProgressIndicator(),
                        ),
                    ],
                  ),
                ),
              ),
              _header('Catty Agent', '使用 OpenAI 兼容接口生成命令，执行前始终确认'),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    children: [
                      TextField(
                        controller: aiEndpoint,
                        decoration: const InputDecoration(labelText: 'API 地址'),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: aiModel,
                        decoration: const InputDecoration(labelText: '模型'),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: aiKey,
                        obscureText: true,
                        decoration: const InputDecoration(labelText: 'API Key'),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton(
                          onPressed: _saveAi,
                          child: const Text('保存 AI 设置'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              _header('数据管理', '导入导出会保留桌面端未知字段和插件数据'),
              Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.key_outlined),
                      title: const Text('SSH 密钥库'),
                      subtitle: const Text('导入私钥与口令'),
                      onTap: () => showModalBottomSheet<void>(
                        context: context,
                        isScrollControlled: true,
                        useSafeArea: true,
                        builder: (_) => const KeychainSheet(),
                      ),
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.file_upload_outlined),
                      title: const Text('导入 Netcatty JSON'),
                      subtitle: const Text('支持桌面端解密后的保险库数据'),
                      onTap: _import,
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.file_download_outlined),
                      title: const Text('导出保险库 JSON'),
                      subtitle: const Text('导出包含凭据，请妥善保存'),
                      onTap: _export,
                    ),
                  ],
                ),
              ),
              _header('安全', null),
              const Card(
                child: Column(
                  children: [
                    ListTile(
                      leading: Icon(Icons.security),
                      title: Text('系统安全存储'),
                      subtitle: Text('Android Keystore / iOS Keychain'),
                    ),
                    Divider(height: 1),
                    ListTile(
                      leading: Icon(Icons.fingerprint),
                      title: Text('服务器身份验证'),
                      subtitle: Text('每次首次连接显示 SHA-256 主机指纹'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              const Center(
                child: Text(
                  'Netcatty Mobile 1.0.0 · GPL-3.0-or-later',
                ),
              ),
            ],
          ),
        ),
      );

  Widget _header(String title, String? subtitle) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
            if (subtitle != null)
              Text(
                subtitle,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
          ],
        ),
      );

  Future<void> _saveSync() async {
    final connection = SyncConnection(
      type: provider,
      endpoint: endpoint.text.trim(),
      // GitHub 用户名仅用于展示，不参与 API 认证。
      username: provider == SyncProviderType.githubGist
          ? _githubUser
          : username.text.trim(),
      secret: providerSecret.text,
      resourceId: resourceId.text.trim(),
    );
    final repository = ref.read(vaultRepositoryProvider);
    await repository.saveSyncConnection(connection);
    await repository.saveMasterPassword(masterPassword.text);
  }

  Future<void> _connectGitHub() async {
    setState(() => _busy = true);
    try {
      final auth = GitHubAuthService();
      final authorization = await auth.start();
      if (!mounted) return;
      final token = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _GitHubDeviceFlowDialog(
          authorization: authorization,
          auth: auth,
        ),
      );
      if (token == null || !mounted) return;
      providerSecret.text = token;
      resourceId.clear();
      await _saveSync();
      try {
        final user = await auth.currentUser(token);
        _githubUser = user['login']?.toString();
      } on GitHubAuthNetworkException {
        _githubUser = null;
      }
      await _saveSync();
      if (mounted) setState(() {});
      _message('GitHub 登录成功，将自动查找 Netcatty Gist');
    } catch (error) {
      _message('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _logoutGitHub() async {
    providerSecret.clear();
    resourceId.clear();
    _githubUser = null;
    await _saveSync();
    if (mounted) setState(() {});
    _message('已退出 GitHub');
  }

  Future<void> _sync({required bool push}) async {
    setState(() => _busy = true);
    try {
      await _saveSync();
      final service = CloudSyncService(ref.read(vaultRepositoryProvider));
      final vault = ref.read(vaultControllerProvider).data ?? VaultData.empty();
      String message;
      if (push) {
        await service.push(vault);
        message = '加密上传完成';
      } else {
        final result = await service.pullAndMerge(vault);
        await ref.read(vaultControllerProvider.notifier).replace(result.vault);
        message = result.message;
      }
      _message(message);
    } catch (error) {
      _message('$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveAi() async {
    final repository = ref.read(vaultRepositoryProvider);
    final current = await repository.loadSettings();
    await ref.read(settingsControllerProvider.notifier).update(
          current.copyWith(
            aiEndpoint: aiEndpoint.text.trim(),
            aiModel: aiModel.text.trim(),
          ),
        );
    await repository.saveAiApiKey(aiKey.text);
    _message('AI 设置已保存');
  }

  Future<void> _saveAppearance() async {
    final current = ref.read(settingsControllerProvider);
    await ref.read(settingsControllerProvider.notifier).update(
          current.copyWith(
            themeMode: themeMode,
            uiThemeId: uiThemeId,
            terminalFontSize: terminalFontSize,
          ),
        );
    _message('外观设置已保存');
  }

  Future<void> _selectTheme(Brightness brightness) async {
    final selected = await showModalBottomSheet<String>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (_) => _ThemePicker(
        brightness: brightness,
        selectedId: uiThemeId,
      ),
    );
    if (selected != null && mounted) setState(() => uiThemeId = selected);
  }

  Future<void> _import() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      withData: true,
    );
    if (result == null) return;
    try {
      final file = result.files.single;
      final bytes = file.bytes ?? await File(file.path!).readAsBytes();
      final vault = VaultData.fromJson(
        jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>,
      );
      await ref.read(vaultControllerProvider.notifier).replace(vault);
      _message('已导入 ${vault.hosts.length} 台主机');
    } catch (error) {
      _message('导入失败：$error');
    }
  }

  Future<void> _export() async {
    final path = await FilePicker.platform.saveFile(
      dialogTitle: '导出 Netcatty 保险库',
      fileName: 'netcatty-mobile-export.json',
    );
    if (path == null) return;
    final vault = ref.read(vaultControllerProvider).data ?? VaultData.empty();
    await File(path).writeAsString(
      const JsonEncoder.withIndent('  ').convert(vault.toJson()),
      flush: true,
    );
    _message('导出完成');
  }

  void _message(String value) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(value)));
    }
  }
}

class _ThemePicker extends StatefulWidget {
  const _ThemePicker({
    required this.brightness,
    required this.selectedId,
  });

  final Brightness brightness;
  final String selectedId;

  @override
  State<_ThemePicker> createState() => _ThemePickerState();
}

class _ThemePickerState extends State<_ThemePicker> {
  String query = '';

  @override
  Widget build(BuildContext context) {
    final themes = NetcattyTheme.presets(widget.brightness)
        .where(
          (theme) =>
              query.isEmpty ||
              theme.name.toLowerCase().contains(query.toLowerCase()) ||
              theme.id.contains(query.toLowerCase()),
        )
        .toList(growable: false);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      minChildSize: 0.45,
      maxChildSize: 0.95,
      builder: (context, controller) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.brightness == Brightness.dark ? '选择深色主题' : '选择浅色主题',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 10),
                TextField(
                  autofocus: false,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search),
                    hintText: '搜索 62 种主题',
                  ),
                  onChanged: (value) => setState(() => query = value.trim()),
                ),
              ],
            ),
          ),
          Expanded(
            child: GridView.builder(
              controller: controller,
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 210,
                mainAxisExtent: 88,
                crossAxisSpacing: 10,
                mainAxisSpacing: 10,
              ),
              itemCount: themes.length,
              itemBuilder: (context, index) {
                final theme = themes[index];
                final selected = theme.id == widget.selectedId;
                return InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => Navigator.pop(context, theme.id),
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: theme.background,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: selected ? theme.primary : theme.border,
                        width: selected ? 2 : 1,
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 12,
                          decoration: BoxDecoration(
                            color: theme.primary,
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            theme.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: theme.foreground,
                              fontWeight:
                                  selected ? FontWeight.bold : FontWeight.w500,
                            ),
                          ),
                        ),
                        if (selected)
                          Icon(Icons.check_circle, color: theme.primary),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _GitHubDeviceFlowDialog extends StatefulWidget {
  const _GitHubDeviceFlowDialog({
    required this.authorization,
    required this.auth,
  });

  final GitHubDeviceAuthorization authorization;
  final GitHubAuthService auth;

  @override
  State<_GitHubDeviceFlowDialog> createState() =>
      _GitHubDeviceFlowDialogState();
}

class _GitHubDeviceFlowDialogState extends State<_GitHubDeviceFlowDialog> {
  Object? error;
  GitHubAuthPollState state = GitHubAuthPollState.waitingForAuthorization;
  bool cancelled = false;

  @override
  void initState() {
    super.initState();
    unawaited(Clipboard.setData(
      ClipboardData(text: widget.authorization.userCode),
    ));
    unawaited(_openGitHub());
    unawaited(_poll());
  }

  @override
  void dispose() {
    cancelled = true;
    super.dispose();
  }

  Future<void> _poll() async {
    try {
      final token = await widget.auth.poll(
        widget.authorization,
        isCancelled: () => cancelled,
        onStateChanged: (value) {
          if (mounted) setState(() => state = value);
        },
      );
      if (mounted) Navigator.pop(context, token);
    } on GitHubAuthCancelledException {
      // Closing the dialog intentionally stops the pending device flow.
    } on Object catch (value) {
      if (mounted) setState(() => error = value);
    }
  }

  Future<void> _openGitHub() => launchUrl(
        widget.authorization.verificationUri,
        mode: LaunchMode.externalApplication,
      );

  @override
  Widget build(BuildContext context) => AlertDialog(
        icon: const Icon(Icons.code, size: 34),
        title: const Text('登录 GitHub'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('验证码已复制。请在浏览器中登录 GitHub 并确认授权。'),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: SelectableText(
                widget.authorization.userCode,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      letterSpacing: 3,
                      fontWeight: FontWeight.bold,
                    ),
              ),
            ),
            const SizedBox(height: 16),
            if (error == null) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              Text(
                state == GitHubAuthPollState.retryingNetwork
                    ? '网络连接发生变化，正在自动重试…'
                    : '正在等待 GitHub 授权…',
                textAlign: TextAlign.center,
              ),
            ] else
              Text(
                '$error',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          OutlinedButton.icon(
            onPressed: _openGitHub,
            icon: const Icon(Icons.open_in_browser),
            label: const Text('打开 GitHub'),
          ),
        ],
      );
}
