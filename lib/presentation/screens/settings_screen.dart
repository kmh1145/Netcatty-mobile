import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../application/settings_controller.dart';
import '../../application/vault_controller.dart';
import '../../domain/models/settings.dart';
import '../../domain/models/vault.dart';
import '../../infrastructure/storage/vault_repository.dart';
import '../../infrastructure/storage/vault_export_service.dart';
import '../../infrastructure/http_client_provider.dart';
import '../../infrastructure/sync/cloud_sync_service.dart';
import '../../infrastructure/sync/github_auth_service.dart';
import '../../infrastructure/update_check_service.dart';
import '../theme.dart';
import '../localization/localized_widgets.dart';
import '../widgets/keychain_sheet.dart';

part 'settings_screen_dialogs.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late final Future<PackageInfo> _packageInfo;
  late final UpdateCheckService _updateCheckService;
  late Future<UpdateCheckResult> _updateCheck;
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
  var terminalSecureKeyboard = false;
  var _savingTerminalSecureKeyboard = false;
  var language = 'zh-CN';
  var _loaded = false;
  var _busy = false;
  var _checkingSyncVersions = false;
  String? _githubUser;
  CloudSyncVersions? _syncVersions;
  Object? _syncVersionsError;

  @override
  void initState() {
    super.initState();
    _packageInfo = PackageInfo.fromPlatform();
    _updateCheckService = UpdateCheckService(
      client: ref.read(httpClientProvider),
    );
    _updateCheck = _checkForUpdates();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _load();
    }
  }

  @override
  void dispose() {
    _updateCheckService.close();
    endpoint.dispose();
    username.dispose();
    providerSecret.dispose();
    resourceId.dispose();
    masterPassword.dispose();
    aiEndpoint.dispose();
    aiModel.dispose();
    aiKey.dispose();
    super.dispose();
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
    terminalSecureKeyboard = settings.terminalSecureKeyboard;
    language = settings.language;
    aiKey.text = await repository.readAiApiKey() ?? '';
    _githubUser =
        sync?.type == SyncProviderType.githubGist ? sync?.username : null;
    if (mounted) {
      setState(() => provider = sync?.type ?? SyncProviderType.webdav);
      if (sync?.type == SyncProviderType.githubGist &&
          sync?.secret?.isNotEmpty == true &&
          masterPassword.text.isNotEmpty) {
        unawaited(_refreshSyncVersions());
      }
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        child: Scaffold(
          appBar: AppBar(title: const LText('设置')),
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
                            label: LText('深色'),
                            icon: Icon(Icons.dark_mode_outlined),
                          ),
                          ButtonSegment(
                            value: 'light',
                            label: LText('浅色'),
                            icon: Icon(Icons.light_mode_outlined),
                          ),
                          ButtonSegment(
                            value: 'system',
                            label: LText('系统'),
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
                            title: const LText('界面主题'),
                            subtitle: LText(
                              '${selected.name} · ${NetcattyTheme.presets(brightness).length} 种可选',
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => _selectTheme(brightness),
                          );
                        },
                      ),
                      Row(
                        children: [
                          const LText('终端字号'),
                          Expanded(
                            child: Slider(
                              value: terminalFontSize,
                              min: minTerminalFontSize,
                              max: maxTerminalFontSize,
                              divisions: 18,
                              label: terminalFontSize.toStringAsFixed(0),
                              onChanged: (value) =>
                                  setState(() => terminalFontSize = value),
                            ),
                          ),
                          LText(terminalFontSize.toStringAsFixed(0)),
                        ],
                      ),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const LText('系统安全键盘'),
                        subtitle: const LText(
                          '使用系统密码键盘并关闭联想学习；终端快捷键仍可输入 Ctrl 组合键',
                        ),
                        value: terminalSecureKeyboard,
                        onChanged: _savingTerminalSecureKeyboard
                            ? null
                            : _setTerminalSecureKeyboard,
                      ),
                      const SizedBox(height: 8),
                      SegmentedButton<String>(
                        segments: const [
                          ButtonSegment(
                            value: 'zh-CN',
                            label: LText('中文'),
                          ),
                          ButtonSegment(
                            value: 'en',
                            label: LText('英文'),
                          ),
                        ],
                        selected: {language},
                        onSelectionChanged: (value) =>
                            setState(() => language = value.first),
                      ),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton(
                          onPressed: _saveAppearance,
                          child: const LText('保存外观设置'),
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
                            label: LText('WebDAV'),
                            icon: Icon(Icons.cloud_outlined),
                          ),
                          ButtonSegment(
                            value: SyncProviderType.githubGist,
                            label: LText('GitHub Gist'),
                            icon: Icon(Icons.code),
                          ),
                        ],
                        selected: {provider},
                        onSelectionChanged: (value) => setState(() {
                          provider = value.first;
                          _syncVersions = null;
                          _syncVersionsError = null;
                        }),
                      ),
                      const SizedBox(height: 14),
                      if (provider == SyncProviderType.webdav) ...[
                        TextField(
                          controller: endpoint,
                          keyboardType: TextInputType.url,
                          decoration: LInputDecoration(
                            labelText: 'WebDAV 地址',
                            hintText: 'https://dav.example.com/netcatty',
                          ),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: username,
                          decoration: LInputDecoration(labelText: '用户名'),
                        ),
                        const SizedBox(height: 10),
                        TextField(
                          controller: providerSecret,
                          obscureText: true,
                          decoration: LInputDecoration(labelText: '密码 / 应用密码'),
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
                          title: LText(
                            providerSecret.text.isEmpty
                                ? '尚未登录 GitHub'
                                : '已连接 GitHub',
                          ),
                          subtitle: LText(
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
                                  label: const LText('登录 GitHub'),
                                )
                              : OutlinedButton.icon(
                                  onPressed: _busy ? null : _logoutGitHub,
                                  icon: const Icon(Icons.logout),
                                  label: const LText('退出 GitHub'),
                                ),
                        ),
                        const SizedBox(height: 10),
                        _githubSyncVersionsCard(),
                        ExpansionTile(
                          tilePadding: EdgeInsets.zero,
                          title: const LText('高级 / 手动配置'),
                          subtitle: const LText('仅用于迁移或登录故障排查'),
                          children: [
                            TextField(
                              controller: resourceId,
                              decoration: LInputDecoration(
                                labelText: 'Gist ID（通常自动识别）',
                              ),
                            ),
                            const SizedBox(height: 10),
                            TextField(
                              controller: providerSecret,
                              obscureText: true,
                              onChanged: (_) => setState(() {}),
                              decoration: LInputDecoration(
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
                        decoration: LInputDecoration(
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
                              label: const LText('拉取并合并'),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: _busy ? null : () => _sync(push: true),
                              icon: const Icon(Icons.cloud_upload_outlined),
                              label: const LText('上传'),
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
                        decoration: LInputDecoration(labelText: 'API 地址'),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: aiModel,
                        decoration: LInputDecoration(labelText: '模型'),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: aiKey,
                        obscureText: true,
                        decoration: LInputDecoration(labelText: 'API Key'),
                      ),
                      const SizedBox(height: 12),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton(
                          onPressed: _saveAi,
                          child: const LText('保存 AI 设置'),
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
                      title: const LText('SSH 密钥库'),
                      subtitle: const LText('导入私钥与口令'),
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
                      title: const LText('导入 Netcatty JSON'),
                      subtitle: const LText('支持桌面端解密后的保险库数据'),
                      onTap: _import,
                    ),
                    const Divider(height: 1),
                    ListTile(
                      leading: const Icon(Icons.file_download_outlined),
                      title: const LText('导出保险库 JSON'),
                      subtitle: const LText('导出包含凭据，请妥善保存'),
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
                      title: LText('系统安全存储'),
                      subtitle: LText('Android Keystore / iOS Keychain'),
                    ),
                    Divider(height: 1),
                    ListTile(
                      leading: Icon(Icons.fingerprint),
                      title: LText('服务器身份验证'),
                      subtitle: LText('每次首次连接显示 SHA-256 主机指纹'),
                    ),
                  ],
                ),
              ),
              _header('关于与更新', '自动检查 GitHub 上的最新正式版本'),
              Card(child: _updateCheckTile()),
              const SizedBox(height: 20),
              Center(
                child: FutureBuilder<PackageInfo>(
                  future: _packageInfo,
                  builder: (context, snapshot) => LText(
                    snapshot.hasData
                        ? 'Netcatty Mobile ${snapshot.data!.version} · GPL-3.0-or-later'
                        : 'Netcatty Mobile · GPL-3.0-or-later',
                  ),
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
            LText(title, style: const TextStyle(fontWeight: FontWeight.w600)),
            if (subtitle != null)
              LText(
                subtitle,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 12,
                ),
              ),
          ],
        ),
      );

  Widget _githubSyncVersionsCard() {
    final colors = Theme.of(context).colorScheme;
    final versions = _syncVersions;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: _syncVersionMetric(
                  icon: Icons.smartphone_outlined,
                  label: '本地版本',
                  version: versions?.localVersion,
                  pending: versions?.hasLocalChanges == true,
                ),
              ),
              Container(
                width: 1,
                height: 42,
                margin: const EdgeInsets.symmetric(horizontal: 10),
                color: colors.outlineVariant,
              ),
              Expanded(
                child: _syncVersionMetric(
                  icon: Icons.cloud_outlined,
                  label: '云端版本',
                  version: versions?.cloudVersion,
                ),
              ),
              IconButton(
                tooltip: localized('刷新同步版本'),
                onPressed: _busy ||
                        _checkingSyncVersions ||
                        providerSecret.text.isEmpty
                    ? null
                    : () => _refreshSyncVersions(saveConfiguration: true),
                icon: _checkingSyncVersions
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
              ),
            ],
          ),
          const SizedBox(height: 8),
          LText(
            _syncVersionStatus(),
            style: TextStyle(
              color: _syncVersionsError == null
                  ? colors.onSurfaceVariant
                  : colors.error,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _syncVersionMetric({
    required IconData icon,
    required String label,
    required int? version,
    bool pending = false,
  }) =>
      Row(
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LText(label, style: const TextStyle(fontSize: 12)),
                Row(
                  children: [
                    Text(
                      version == null ? '—' : 'v$version',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                    if (pending) ...[
                      const SizedBox(width: 5),
                      const LText('待同步', style: TextStyle(fontSize: 11)),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      );

  String _syncVersionStatus() {
    if (providerSecret.text.isEmpty) return '登录 GitHub 后查看同步版本';
    if (_checkingSyncVersions) return '正在读取本地与云端版本…';
    if (_syncVersionsError != null) {
      return '版本信息读取失败：$_syncVersionsError';
    }
    final versions = _syncVersions;
    if (versions == null) return '点按刷新以确认当前同步版本';
    final base = versions.baseVersion;
    if (base == null) {
      if (versions.cloudVersion > 0 && versions.hasLocalChanges) {
        return '本地与云端尚无共同版本，请先拉取并合并';
      }
      if (versions.cloudVersion > 0) return '云端已有版本，建议拉取并合并';
      if (versions.hasLocalChanges) return '本地数据尚未上传';
      return '尚未建立同步版本';
    }
    final cloudChanged = versions.cloudVersion != base;
    if (cloudChanged && versions.hasLocalChanges) {
      return '本地和云端均有更新，请拉取并合并';
    }
    if (versions.hasLocalChanges) return '本地有待上传的更改';
    if (versions.cloudVersion > base) return '云端有新版本，建议拉取并合并';
    if (versions.cloudVersion < base) {
      return '云端版本与上次同步记录不一致，请先拉取并合并';
    }
    return '本地与云端版本一致';
  }

  Widget _updateCheckTile() => FutureBuilder<UpdateCheckResult>(
        future: _updateCheck,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const ListTile(
              leading: SizedBox.square(
                dimension: 24,
                child: CircularProgressIndicator(strokeWidth: 2.5),
              ),
              title: LText('正在检查更新'),
              subtitle: LText('正在查询 GitHub 最新 Release'),
            );
          }
          if (snapshot.hasError) {
            return ListTile(
              leading: Icon(
                Icons.error_outline,
                color: Theme.of(context).colorScheme.error,
              ),
              title: const LText('检查更新失败'),
              subtitle: LText('${snapshot.error}\n点按重试'),
              isThreeLine: true,
              trailing: const Icon(Icons.refresh),
              onTap: _retryUpdateCheck,
            );
          }

          final result = snapshot.requireData;
          final title = result.updateAvailable
              ? '发现新版本 ${result.latestVersion}'
              : result.isLatest
                  ? '已是最新版本'
                  : '当前为开发版本';
          final subtitle = result.updateAvailable
              ? '当前版本 ${result.currentVersion} · 点按前往下载'
              : result.isLatest
                  ? '当前版本 ${result.currentVersion} · 点按查看最新 Release'
                  : '当前 ${result.currentVersion} · 最新正式版 ${result.latestVersion}';
          final icon = result.updateAvailable
              ? Icons.system_update_alt
              : result.isLatest
                  ? Icons.check_circle_outline
                  : Icons.science_outlined;
          return ListTile(
            leading: Icon(
              icon,
              color: result.updateAvailable
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
            title: LText(title),
            subtitle: LText(subtitle),
            trailing: const Icon(Icons.open_in_new),
            onTap: () => _openLatestRelease(result.releaseUri),
          );
        },
      );

  Future<UpdateCheckResult> _checkForUpdates() async {
    final info = await _packageInfo;
    return _updateCheckService.check(info.version);
  }

  void _retryUpdateCheck() {
    setState(() => _updateCheck = _checkForUpdates());
  }

  Future<void> _openLatestRelease(Uri uri) async {
    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened) _message('无法打开 GitHub Release 页面');
    } on Object {
      _message('无法打开 GitHub Release 页面');
    }
  }

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

  Future<void> _refreshSyncVersions({
    bool saveConfiguration = false,
  }) async {
    if (provider != SyncProviderType.githubGist ||
        providerSecret.text.isEmpty) {
      return;
    }
    if (mounted) {
      setState(() {
        _checkingSyncVersions = true;
        _syncVersionsError = null;
      });
    }
    try {
      if (saveConfiguration) await _saveSync();
      final repository = ref.read(vaultRepositoryProvider);
      final service = CloudSyncService(
        repository,
        client: ref.read(httpClientProvider),
      );
      final vault = ref.read(vaultControllerProvider).data ??
          await repository.loadVault();
      final versions = await service.inspectVersions(vault);
      final updatedConnection = await repository.loadSyncConnection();
      if (mounted) {
        setState(() {
          _syncVersions = versions;
          resourceId.text = updatedConnection?.resourceId ?? resourceId.text;
        });
      }
    } on Object catch (error) {
      if (mounted) setState(() => _syncVersionsError = error);
    } finally {
      if (mounted) setState(() => _checkingSyncVersions = false);
    }
  }

  Future<void> _connectGitHub() async {
    setState(() => _busy = true);
    try {
      final auth = GitHubAuthService(client: ref.read(httpClientProvider));
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
      await _refreshSyncVersions();
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
    if (mounted) {
      setState(() {
        _syncVersions = null;
        _syncVersionsError = null;
      });
    }
    _message('已退出 GitHub');
  }

  Future<void> _sync({required bool push}) async {
    setState(() => _busy = true);
    try {
      await _saveSync();
      final service = CloudSyncService(
        ref.read(vaultRepositoryProvider),
        client: ref.read(httpClientProvider),
      );
      final vault = ref.read(vaultControllerProvider).data ?? VaultData.empty();
      String message;
      if (push) {
        final result = await service.push(vault);
        await ref
            .read(vaultControllerProvider.notifier)
            .replace(result.vault, remote: true);
        _syncVersions = result.versions;
        message = result.message;
      } else {
        final result = await service.pullAndMerge(vault);
        await ref
            .read(vaultControllerProvider.notifier)
            .replace(result.vault, remote: true);
        _syncVersions = result.versions;
        message = result.message;
      }
      final updatedConnection =
          await ref.read(vaultRepositoryProvider).loadSyncConnection();
      resourceId.text = updatedConnection?.resourceId ?? resourceId.text;
      if (mounted) setState(() {});
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
            terminalSecureKeyboard: terminalSecureKeyboard,
            language: language,
          ),
        );
    _message('外观设置已保存');
  }

  Future<void> _setTerminalSecureKeyboard(bool value) async {
    final previous = terminalSecureKeyboard;
    setState(() {
      terminalSecureKeyboard = value;
      _savingTerminalSecureKeyboard = true;
    });
    try {
      await ref
          .read(settingsControllerProvider.notifier)
          .updateTerminalSecureKeyboard(value);
    } catch (error) {
      if (!mounted) return;
      setState(() => terminalSecureKeyboard = previous);
      _message('安全键盘设置保存失败：$error');
    } finally {
      if (mounted) {
        setState(() => _savingTerminalSecureKeyboard = false);
      }
    }
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
    try {
      final vault = await ref.read(vaultControllerProvider.notifier).ready();
      final result = await VaultExportService().export(vault);
      if (result == VaultExportResult.saved) _message('导出完成');
    } catch (error) {
      _message('导出失败：$error');
    }
  }

  void _message(String value) {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: LText(value)));
    }
  }
}
