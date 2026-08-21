part of 'settings_screen.dart';

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
                LText(
                  widget.brightness == Brightness.dark ? '选择深色主题' : '选择浅色主题',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 10),
                TextField(
                  autofocus: false,
                  decoration: LInputDecoration(
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
                          child: LText(
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
        title: const LText('登录 GitHub'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const LText('验证码已复制。请在浏览器中登录 GitHub 并确认授权。'),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 14),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: LSelectableText(
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
              LText(
                state == GitHubAuthPollState.retryingNetwork
                    ? '网络连接发生变化，正在自动重试…'
                    : '正在等待 GitHub 授权…',
                textAlign: TextAlign.center,
              ),
            ] else
              LText(
                '$error',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const LText('取消'),
          ),
          OutlinedButton.icon(
            onPressed: _openGitHub,
            icon: const Icon(Icons.open_in_browser),
            label: const LText('打开 GitHub'),
          ),
        ],
      );
}
