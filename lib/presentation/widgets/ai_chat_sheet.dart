import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../domain/models/host.dart';
import '../../domain/models/settings.dart';
import '../../infrastructure/ai/ai_service.dart';
import '../localization/localized_widgets.dart';

class AiChatSheet extends StatefulWidget {
  const AiChatSheet({
    super.key,
    required this.host,
    required this.settings,
    required this.apiKey,
    required this.service,
    required this.initialMessages,
    required this.onMessagesChanged,
    required this.onCommand,
    required this.terminalContext,
    required this.onModelChanged,
    required this.onReasoningEffortChanged,
  });

  final HostProfile host;
  final AppSettings settings;
  final String apiKey;
  final AiService service;
  final List<AiChatMessage> initialMessages;
  final ValueChanged<List<AiChatMessage>> onMessagesChanged;
  final Future<void> Function(String command, bool execute) onCommand;
  final String Function() terminalContext;
  final Future<void> Function(String model) onModelChanged;
  final Future<void> Function(String effort) onReasoningEffortChanged;

  @override
  State<AiChatSheet> createState() => _AiChatSheetState();
}

class _AiChatSheetState extends State<AiChatSheet> {
  late final List<AiChatMessage> _messages;
  late String _selectedModel;
  late String _selectedReasoningEffort;
  final _input = TextEditingController();
  final _scroll = ScrollController();
  var _sending = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final initialMessages = widget.initialMessages;
    _messages = initialMessages.length <= maxAiChatHistoryMessages
        ? [...initialMessages]
        : initialMessages.sublist(
            initialMessages.length - maxAiChatHistoryMessages,
          );
    _selectedModel = widget.settings.aiModel;
    _selectedReasoningEffort = widget.settings.aiReasoningEffort;
  }

  String get _endpoint =>
      '${widget.host.username}@${widget.host.hostname}:${widget.host.port}';

  String get _modelTooltip {
    final action = localized('切换模型');
    return '$action · $_selectedModel';
  }

  String get _hostSummary {
    final protocol = widget.host.protocol.name.toUpperCase();
    final system = widget.host.systemInfo;
    final os = system == null
        ? widget.host.data['os']?.toString() ?? 'unknown'
        : '${system.platform} ${system.distro}'.trim();
    return '$protocol session ${widget.host.label}; endpoint $_endpoint; '
        'operating system $os';
  }

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send([String? suggestedPrompt]) async {
    final prompt = (suggestedPrompt ?? _input.text).trim();
    if (prompt.isEmpty || _sending) return;
    final history = List<AiChatMessage>.unmodifiable(_messages);
    setState(() {
      _appendMessage(
        AiChatMessage(role: AiChatRole.user, content: prompt),
      );
      _input.clear();
      _sending = true;
      _error = null;
    });
    _notifyMessagesChanged();
    _scrollToBottom();
    try {
      final reply = await widget.service.sendMessage(
        request: prompt,
        history: history,
        settings: widget.settings.copyWith(
          aiReasoningEffort: _selectedReasoningEffort,
        ),
        apiKey: widget.apiKey,
        hostSummary: _hostSummary,
        terminalContext: widget.settings.aiIncludeTerminalContext
            ? widget.terminalContext()
            : '',
        model: _selectedModel,
      );
      if (!mounted) return;
      setState(() => _appendMessage(reply));
      _notifyMessagesChanged();
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    } finally {
      if (mounted) {
        setState(() => _sending = false);
        _scrollToBottom();
      }
    }
  }

  void _notifyMessagesChanged() {
    widget.onMessagesChanged(List<AiChatMessage>.unmodifiable(_messages));
  }

  void _appendMessage(AiChatMessage message) {
    _messages.add(message);
    if (_messages.length > maxAiChatHistoryMessages) {
      _messages.removeRange(
        0,
        _messages.length - maxAiChatHistoryMessages,
      );
    }
  }

  Future<void> _selectModel(String model) async {
    if (_sending || model == _selectedModel) return;
    final previous = _selectedModel;
    setState(() {
      _selectedModel = model;
      _error = null;
    });
    try {
      await widget.onModelChanged(model);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _selectedModel = previous;
        _error = '$error';
      });
    }
  }

  Future<void> _selectReasoningEffort(String effort) async {
    if (_sending || effort == _selectedReasoningEffort) return;
    final previous = _selectedReasoningEffort;
    setState(() {
      _selectedReasoningEffort = effort;
      _error = null;
    });
    try {
      await widget.onReasoningEffortChanged(effort);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _selectedReasoningEffort = previous;
        _error = '$error';
      });
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      unawaited(
        _scroll.animateTo(
          _scroll.position.minScrollExtent,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        ),
      );
    });
  }

  Future<void> _newChat() async {
    if (_messages.isEmpty) return;
    final clear = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const LText('开始新对话？'),
            content: const LText('当前终端的 AI 对话记录将被清空。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const LText('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const LText('新对话'),
              ),
            ],
          ),
        ) ??
        false;
    if (!clear || !mounted) return;
    setState(() {
      _messages.clear();
      _error = null;
    });
    _notifyMessagesChanged();
  }

  Future<void> _handleCommand(String command, bool execute) async {
    if (execute) {
      final confirmed = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const LText('确认执行命令'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${localized('命令将发送到')} $_endpoint'),
                  const SizedBox(height: 12),
                  _CommandCode(command: command),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const LText('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const LText('执行'),
                ),
              ],
            ),
          ) ??
          false;
      if (!confirmed || !mounted) return;
    }
    try {
      await widget.onCommand(command, execute);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${localized(execute ? '命令已发送到' : '命令已粘贴到')} '
            '${widget.host.label}',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = '$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AnimatedPadding(
      key: const ValueKey('ai-chat-keyboard-padding'),
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(context).bottom,
      ),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      child: Material(
        color: colors.surface,
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              const SizedBox(height: 8),
              Container(
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: colors.onSurfaceVariant.withValues(alpha: .35),
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
              _buildHeader(context),
              const Divider(height: 1),
              Expanded(
                child: _messages.isEmpty
                    ? _buildEmptyState(context)
                    : ListView.builder(
                        key: const ValueKey('ai-chat-message-list'),
                        controller: _scroll,
                        reverse: true,
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
                        itemCount: _messages.length + (_sending ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (_sending && index == 0) {
                            return const _ThinkingBubble();
                          }
                          final offset = _sending ? index - 1 : index;
                          final message =
                              _messages[_messages.length - 1 - offset];
                          return _MessageBubble(
                            message: message,
                            onPaste: message.command == null
                                ? null
                                : () => _handleCommand(message.command!, false),
                            onExecute: message.command == null
                                ? null
                                : () => _handleCommand(message.command!, true),
                          );
                        },
                      ),
              ),
              if (_error != null)
                Container(
                  key: const ValueKey('ai-chat-error'),
                  width: double.infinity,
                  margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: colors.errorContainer,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline, color: colors.onErrorContainer),
                      const SizedBox(width: 8),
                      Expanded(
                        child: LText(
                          _error!,
                          style: TextStyle(color: colors.onErrorContainer),
                        ),
                      ),
                      IconButton(
                        tooltip: localized('关闭'),
                        visualDensity: VisualDensity.compact,
                        onPressed: () => setState(() => _error = null),
                        icon: const Icon(Icons.close, size: 18),
                      ),
                    ],
                  ),
                ),
              _buildComposer(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 10),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: Theme.of(context).colorScheme.primaryContainer,
              child: Icon(
                Icons.auto_awesome,
                color: Theme.of(context).colorScheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LText(
                    'Catty Agent',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(
                    '${widget.host.label} · $_endpoint',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            IconButton(
              key: const ValueKey('ai-chat-new'),
              tooltip: localized('新对话'),
              onPressed: _sending ? null : _newChat,
              icon: const Icon(Icons.add_comment_outlined),
            ),
            IconButton(
              tooltip: localized('关闭'),
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close),
            ),
          ],
        ),
      );

  Widget _buildEmptyState(BuildContext context) => ListView(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 16),
        children: [
          Icon(
            Icons.auto_awesome,
            size: 42,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 14),
          LText(
            '有什么可以帮你？',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          LText(
            widget.settings.aiIncludeTerminalContext
                ? 'Catty 会结合当前服务器信息和近期终端输出连续对话，并在需要时提供可粘贴或确认执行的命令。'
                : 'Catty 会结合当前服务器信息连续对话，并在需要时提供可粘贴或确认执行的命令。',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 8),
          LText(
            widget.settings.aiIncludeTerminalContext
                ? '每次提问会将当前终端的近期输出发送给已配置的 AI 服务。'
                : '终端输出上传已关闭，可在设置中开启。',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 24),
          for (final prompt in [
            '检查服务器健康状态',
            '分析当前磁盘使用情况',
            if (widget.settings.aiIncludeTerminalContext) '分析最近的终端输出',
            '帮我排查最近的系统错误',
          ])
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: OutlinedButton.icon(
                onPressed: _sending ? null : () => _send(prompt),
                icon: const Icon(Icons.arrow_outward, size: 17),
                label: Align(
                  alignment: Alignment.centerLeft,
                  child: LText(prompt),
                ),
              ),
            ),
        ],
      );

  Widget _buildComposer(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border(
            top: BorderSide(color: Theme.of(context).dividerColor),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(child: _buildModelSelector(context)),
                const SizedBox(width: 8),
                Expanded(child: _buildReasoningSelector(context)),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  Icons.terminal,
                  size: 14,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: LText(
                    widget.settings.aiIncludeTerminalContext
                        ? '提问时会自动附带近期终端输出'
                        : '终端输出上传已关闭',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 7),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('ai-chat-input'),
                    controller: _input,
                    enabled: !_sending,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.newline,
                    decoration: LInputDecoration(
                      hintText: '向 Catty 询问当前服务器…',
                      filled: true,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  key: const ValueKey('ai-chat-send'),
                  tooltip: localized('发送'),
                  onPressed: _sending ? null : _send,
                  icon: _sending
                      ? const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.arrow_upward),
                ),
              ],
            ),
          ],
        ),
      );

  Widget _buildModelSelector(BuildContext context) => PopupMenuButton<String>(
        key: const ValueKey('ai-chat-model-selector'),
        enabled: !_sending,
        tooltip: _modelTooltip,
        onSelected: (model) => unawaited(_selectModel(model)),
        itemBuilder: (context) => [
          for (final model in widget.settings.aiModels)
            PopupMenuItem(
              value: model,
              child: _popupItem(
                context,
                model,
                selected: model == _selectedModel,
              ),
            ),
        ],
        child: _selectorFace(
          context,
          icon: Icons.model_training_outlined,
          label: _selectedModel,
        ),
      );

  Widget _buildReasoningSelector(BuildContext context) =>
      PopupMenuButton<String>(
        key: const ValueKey('ai-chat-reasoning-selector'),
        enabled: !_sending,
        tooltip: localized('调整思考强度'),
        onSelected: (effort) => unawaited(_selectReasoningEffort(effort)),
        itemBuilder: (context) => [
          for (final effort in supportedAiReasoningEfforts)
            PopupMenuItem(
              value: effort,
              child: _popupItem(
                context,
                _reasoningEffortLabel(effort),
                selected: effort == _selectedReasoningEffort,
              ),
            ),
        ],
        child: _selectorFace(
          context,
          icon: Icons.psychology_outlined,
          label: _reasoningEffortLabel(_selectedReasoningEffort),
        ),
      );

  Widget _selectorFace(
    BuildContext context, {
    required IconData icon,
    required String label,
  }) =>
      Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).dividerColor),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(icon, size: 18),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Icon(Icons.arrow_drop_down, size: 18),
          ],
        ),
      );

  Widget _popupItem(
    BuildContext context,
    String label, {
    required bool selected,
  }) =>
      Row(
        children: [
          SizedBox(
            width: 28,
            child: selected
                ? Icon(
                    Icons.check,
                    size: 18,
                    color: Theme.of(context).colorScheme.primary,
                  )
                : null,
          ),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );

  String _reasoningEffortLabel(String effort) => switch (effort) {
        'minimal' => '思考：极低',
        'low' => '思考：低',
        'medium' => '思考：中',
        'high' => '思考：高',
        _ => '思考：模型默认',
      };
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    this.onPaste,
    this.onExecute,
  });

  final AiChatMessage message;
  final VoidCallback? onPaste;
  final VoidCallback? onExecute;

  @override
  Widget build(BuildContext context) {
    final user = message.role == AiChatRole.user;
    final colors = Theme.of(context).colorScheme;
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        key: ValueKey('ai-chat-${message.role.name}-message'),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * .86,
        ),
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: user ? colors.primaryContainer : colors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(16).copyWith(
            bottomRight: user ? const Radius.circular(4) : null,
            bottomLeft: user ? null : const Radius.circular(4),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!user) ...[
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.auto_awesome, size: 15, color: colors.primary),
                  const SizedBox(width: 6),
                  LText(
                    'Catty',
                    style: Theme.of(context)
                        .textTheme
                        .labelMedium
                        ?.copyWith(color: colors.primary),
                  ),
                ],
              ),
              const SizedBox(height: 8),
            ],
            LSelectableText(message.content),
            if (message.command?.isNotEmpty == true) ...[
              const SizedBox(height: 12),
              _CommandCode(command: message.command!),
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 4,
                runSpacing: 4,
                children: [
                  IconButton(
                    key: const ValueKey('ai-command-copy'),
                    tooltip: localized('复制命令'),
                    visualDensity: VisualDensity.compact,
                    onPressed: () async {
                      await Clipboard.setData(
                        ClipboardData(text: message.command!),
                      );
                    },
                    icon: const Icon(Icons.copy_outlined, size: 19),
                  ),
                  TextButton.icon(
                    key: const ValueKey('ai-command-paste'),
                    onPressed: onPaste,
                    icon: const Icon(Icons.content_paste_go_outlined, size: 18),
                    label: const LText('粘贴到终端'),
                  ),
                  FilledButton.icon(
                    key: const ValueKey('ai-command-execute'),
                    onPressed: onExecute,
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: const LText('执行'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CommandCode extends StatelessWidget {
  const _CommandCode({required this.command});

  final String command;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: .86),
          borderRadius: BorderRadius.circular(10),
        ),
        child: SelectableText(
          command,
          style: const TextStyle(
            fontFamily: 'monospace',
            color: Colors.white,
          ),
        ),
      );
}

class _ThinkingBubble extends StatelessWidget {
  const _ThinkingBubble();

  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerLeft,
        child: Container(
          key: const ValueKey('ai-chat-thinking'),
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(16),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 10),
              LText('Catty 正在思考…'),
            ],
          ),
        ),
      );
}
