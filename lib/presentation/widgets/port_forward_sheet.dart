import 'package:flutter/material.dart';
import 'package:netcatty_mobile/presentation/localization/localized_widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/port_forward_controller.dart';
import '../../infrastructure/ssh/ssh_service.dart';

class PortForwardSheet extends ConsumerStatefulWidget {
  const PortForwardSheet({super.key, required this.session});
  final ActiveTerminalSession session;

  @override
  ConsumerState<PortForwardSheet> createState() => _PortForwardSheetState();
}

class _PortForwardSheetState extends ConsumerState<PortForwardSheet> {
  final localPort = TextEditingController(text: '8080');
  final remoteHost = TextEditingController(text: '127.0.0.1');
  final remotePort = TextEditingController(text: '80');
  var kind = ForwardKind.local;
  var busy = false;

  @override
  Widget build(BuildContext context) {
    final forwards = ref.watch(portForwardControllerProvider);
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        18,
        16,
        MediaQuery.viewInsetsOf(context).bottom + 18,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LText('端口转发', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            SegmentedButton<ForwardKind>(
              segments: const [
                ButtonSegment(value: ForwardKind.local, label: LText('本地转发')),
                ButtonSegment(
                  value: ForwardKind.dynamic,
                  label: LText('SOCKS5'),
                ),
              ],
              selected: {kind},
              onSelectionChanged: (value) => setState(() => kind = value.first),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: localPort,
              keyboardType: TextInputType.number,
              decoration: LInputDecoration(labelText: '本地端口（0 为自动）'),
            ),
            if (kind == ForwardKind.local) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: remoteHost,
                      decoration: LInputDecoration(labelText: '远端主机'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: remotePort,
                      keyboardType: TextInputType.number,
                      decoration: LInputDecoration(labelText: '端口'),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: busy ? null : _start,
                icon: const Icon(Icons.play_arrow),
                label: const LText('启动'),
              ),
            ),
            if (forwards.isNotEmpty) ...[
              const Padding(
                padding: EdgeInsets.only(top: 18, bottom: 6),
                child: LText('运行中'),
              ),
              for (final item in forwards)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.swap_horiz),
                  title: LText(
                    item.kind == ForwardKind.dynamic
                        ? 'SOCKS5 127.0.0.1:${item.localPort}'
                        : '127.0.0.1:${item.localPort} → ${item.remoteHost}:${item.remotePort}',
                  ),
                  trailing: IconButton(
                    onPressed: () => ref
                        .read(portForwardControllerProvider.notifier)
                        .stop(item.id),
                    icon: const Icon(Icons.stop_circle_outlined),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _start() async {
    setState(() => busy = true);
    try {
      final controller = ref.read(portForwardControllerProvider.notifier);
      if (kind == ForwardKind.local) {
        await controller.startLocal(
          session: widget.session,
          localPort: int.tryParse(localPort.text) ?? 0,
          remoteHost: remoteHost.text.trim(),
          remotePort: int.tryParse(remotePort.text) ?? 80,
        );
      } else {
        await controller.startDynamic(
          session: widget.session,
          localPort: int.tryParse(localPort.text) ?? 0,
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: LText('$error')));
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
}
