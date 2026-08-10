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
                  'Netcatty Mobile 0.1.0 · GPL-3.0-or-later',
                  style: TextStyle(color: Colors.white38),
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
                style: const TextStyle(color: Colors.white54, fontSize: 12),
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
          tokenFuture: auth.poll(authorization),
        ),
      );
      if (token == null || !mounted) return;
      final user = await auth.currentUser(token);
      providerSecret.text = token;
      resourceId.clear();
      _githubUser = user['login']?.toString();
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
            terminalFontSize: terminalFontSize,
          ),
        );
    _message('外观设置已保存');
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

class _GitHubDeviceFlowDialog extends StatefulWidget {
  const _GitHubDeviceFlowDialog({
    required this.authorization,
    required this.tokenFuture,
  });

  final GitHubDeviceAuthorization authorization;
  final Future<String> tokenFuture;

  @override
  State<_GitHubDeviceFlowDialog> createState() =>
      _GitHubDeviceFlowDialogState();
}

class _GitHubDeviceFlowDialogState extends State<_GitHubDeviceFlowDialog> {
  Object? error;

  @override
  void initState() {
    super.initState();
    unawaited(Clipboard.setData(
      ClipboardData(text: widget.authorization.userCode),
    ));
    unawaited(_openGitHub());
    widget.tokenFuture.then((token) {
      if (mounted) Navigator.pop(context, token);
    }).catchError((Object value) {
      if (mounted) setState(() => error = value);
    });
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
              const Text('正在等待 GitHub 授权…'),
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
