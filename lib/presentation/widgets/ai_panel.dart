import 'package:flutter/material.dart';

import '../../infrastructure/ai/ai_workspace.dart';
import '../localization/localized_widgets.dart';

Future<bool> confirmAiRisk(BuildContext context, AiWorkspace workspace) async {
  if (await workspace.riskAcknowledged()) return true;
  if (!context.mounted) return false;
  final accepted = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: const LText('使用 AI Agent 前请了解风险'),
      content: const SingleChildScrollView(
          child: LText(
              'AI 可能生成错误或危险命令，造成数据丢失、服务中断或安全问题。执行前请检查完整命令并做好备份。命令会发送到当前终端，请确认终端处于可输入命令的状态。\n\n'
              '对话会发送给你配置的 AI 服务商；开启终端输出上传后，近期终端内容也会被发送。脱敏无法保证移除所有敏感信息，请勿上传密码、密钥或隐私数据。')),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const LText('取消')),
        FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const LText('了解了')),
      ],
    ),
  );
  if (accepted != true) return false;
  await workspace.acknowledgeRisk();
  return true;
}

/// Resizing uses the header, leaving reverse chat scrolling independent.
class ResizableAiPanel extends StatefulWidget {
  const ResizableAiPanel({super.key, required this.builder});
  final Widget Function(GestureDragUpdateCallback onResize) builder;
  @override
  State<ResizableAiPanel> createState() => _ResizableAiPanelState();
}

class _ResizableAiPanelState extends State<ResizableAiPanel> {
  double _extent = .9;
  @override
  Widget build(BuildContext context) => Padding(
        padding:
            EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: LayoutBuilder(
            builder: (context, constraints) => Align(
                  alignment: Alignment.bottomCenter,
                  child: SizedBox(
                    key: const ValueKey('ai-resizable-panel'),
                    height: constraints.maxHeight *
                        (MediaQuery.viewInsetsOf(context).bottom > 0
                            ? 1
                            : _extent),
                    child: ClipRRect(
                      borderRadius: BorderRadius.vertical(
                          top: Radius.circular(_extent >= 1 ? 0 : 24)),
                      child: widget.builder((details) {
                        if (constraints.maxHeight <= 0) return;
                        setState(() => _extent =
                            (_extent - details.delta.dy / constraints.maxHeight)
                                .clamp(.55, 1));
                      }),
                    ),
                  ),
                )),
      );
}
