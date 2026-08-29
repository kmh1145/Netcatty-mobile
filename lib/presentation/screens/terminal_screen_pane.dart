part of 'terminal_screen.dart';

class _ConnectionStatusPane extends StatelessWidget {
  const _ConnectionStatusPane({
    required this.pending,
    this.onReturn,
    this.onClose,
    this.onCancel,
  });

  final PendingTerminalConnection pending;
  final VoidCallback? onReturn;
  final VoidCallback? onClose;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final failed = pending.phase == PendingConnectionPhase.failed;
    return ColoredBox(
      color: scheme.surface,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Card(
              key: const ValueKey('terminal-connection-status-dialog'),
              elevation: 12,
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    HostSystemIcon(host: pending.host, size: 50),
                    const SizedBox(height: 12),
                    LText(
                      pending.host.label,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 4),
                    LText(
                      '${pending.host.protocol.name.toUpperCase()}  '
                      '${pending.host.username}@${pending.host.hostname}:'
                      '${pending.host.port}',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                    ),
                    const SizedBox(height: 20),
                    if (failed)
                      Icon(
                        Icons.error_outline,
                        size: 38,
                        color: scheme.error,
                      )
                    else ...[
                      const LinearProgressIndicator(),
                      const SizedBox(height: 18),
                    ],
                    LText(
                      failed ? '安全连接建立失败' : '正在建立安全连接…',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: failed ? scheme.error : null,
                          ),
                    ),
                    if (failed) ...[
                      const SizedBox(height: 8),
                      LText(
                        '${pending.error ?? '未知错误'}',
                        maxLines: 5,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                      ),
                    ],
                    if (onReturn != null ||
                        onClose != null ||
                        onCancel != null) ...[
                      const SizedBox(height: 18),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          if (onReturn != null)
                            TextButton.icon(
                              onPressed: onReturn,
                              icon: const Icon(Icons.arrow_back),
                              label: const LText('返回当前终端'),
                            ),
                          if (onClose != null)
                            FilledButton.icon(
                              onPressed: onClose,
                              icon: const Icon(Icons.close),
                              label: const LText('关闭标签页'),
                            ),
                          if (onCancel != null)
                            FilledButton.icon(
                              key: const ValueKey('cancel-pending-connection'),
                              onPressed: onCancel,
                              icon: const Icon(Icons.stop_circle_outlined),
                              label: const LText('终止连接'),
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TerminalPictureInPictureHeader extends StatelessWidget {
  const _TerminalPictureInPictureHeader({required this.session});

  final ActiveTerminalSession session;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: SizedBox(
          height: 30,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                Icon(
                  Icons.circle,
                  size: 8,
                  color: session.connected
                      ? Colors.greenAccent
                      : Colors.orangeAccent,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: LText(
                    session.host.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ),
                const Icon(Icons.picture_in_picture, size: 15),
              ],
            ),
          ),
        ),
      );
}

class _TerminalPane extends StatefulWidget {
  const _TerminalPane({
    super.key,
    required this.session,
    required this.fontSize,
    required this.secureKeyboard,
    required this.pictureInPicture,
    required this.transparentBackground,
  });
  final ActiveTerminalSession session;
  final double fontSize;
  final bool secureKeyboard;
  final bool pictureInPicture;
  final bool transparentBackground;

  @override
  State<_TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<_TerminalPane> {
  final _controller = TerminalController();
  var _terminalViewKey = GlobalKey<TerminalViewState>();
  final _terminalStackKey = GlobalKey();
  final _scrollController = ScrollController();
  Offset? _dragPointerToAnchor;
  Timer? _pictureInPictureUpdateTimer;

  @override
  void initState() {
    super.initState();
    widget.session.terminal.addListener(_onTerminalChanged);
    if (widget.pictureInPicture) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _sendPipUpdate());
    }
  }

  @override
  void didUpdateWidget(covariant _TerminalPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.secureKeyboard != widget.secureKeyboard) {
      // xterm keeps the platform TextInputConnection alive while the view is
      // mounted. Recreate it so Android and iOS receive the new input type.
      _terminalViewKey = GlobalKey<TerminalViewState>();
    }
    if (oldWidget.session.terminal != widget.session.terminal) {
      oldWidget.session.terminal.removeListener(_onTerminalChanged);
      widget.session.terminal.addListener(_onTerminalChanged);
    }
    if (!oldWidget.pictureInPicture && widget.pictureInPicture) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _sendPipUpdate());
    } else if (oldWidget.pictureInPicture && !widget.pictureInPicture) {
      _pictureInPictureUpdateTimer?.cancel();
      _pictureInPictureUpdateTimer = null;
    }
  }

  @override
  void dispose() {
    widget.session.terminal.removeListener(_onTerminalChanged);
    _pictureInPictureUpdateTimer?.cancel();
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onTerminalChanged() {
    if (!widget.pictureInPicture || _pictureInPictureUpdateTimer != null) {
      return;
    }
    _pictureInPictureUpdateTimer = Timer(
      const Duration(seconds: 1),
      () {
        _pictureInPictureUpdateTimer = null;
        _sendPipUpdate();
      },
    );
  }

  void _sendPipUpdate() {
    if (!mounted || !widget.pictureInPicture) return;
    final scheme = Theme.of(context).colorScheme;
    unawaited(
      TerminalPictureInPictureService.update(
        title: widget.session.host.label,
        text: terminalPictureInPictureText(widget.session.terminal),
        connected: widget.session.connected,
        backgroundColor: scheme.surface.toARGB32(),
        foregroundColor: scheme.onSurface.toARGB32(),
        accentColor: scheme.primary.toARGB32(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final paneBackground =
        widget.transparentBackground ? Colors.transparent : scheme.surface;
    final terminalTheme = TerminalTheme(
      cursor: scheme.primary,
      selection: scheme.primary.withValues(alpha: 0.35),
      foreground: scheme.onSurface,
      background: scheme.surface,
      black: const Color(0xff1d1f21),
      red: const Color(0xffcc6666),
      green: const Color(0xffb5bd68),
      yellow: const Color(0xfff0c674),
      blue: const Color(0xff81a2be),
      magenta: const Color(0xffb294bb),
      cyan: const Color(0xff8abeb7),
      white: const Color(0xffc5c8c6),
      brightBlack: const Color(0xff666666),
      brightRed: const Color(0xffd54e53),
      brightGreen: const Color(0xffb9ca4a),
      brightYellow: const Color(0xffe7c547),
      brightBlue: const Color(0xff7aa6da),
      brightMagenta: const Color(0xffc397d8),
      brightCyan: const Color(0xff70c0b1),
      brightWhite: const Color(0xffeaeaea),
      searchHitBackground: scheme.tertiaryContainer,
      searchHitBackgroundCurrent: scheme.primaryContainer,
      searchHitForeground: scheme.onSurface,
    );
    return ColoredBox(
      color: paneBackground,
      child: AnimatedBuilder(
        animation: Listenable.merge([_controller, _scrollController]),
        builder: (context, _) {
          final selection = _controller.selection?.normalized;
          final startHandle = selection == null
              ? null
              : _selectionHandlePosition(selection.begin);
          final endHandle = selection == null
              ? null
              : _selectionHandlePosition(selection.end);
          return Stack(
            key: _terminalStackKey,
            fit: StackFit.expand,
            clipBehavior: Clip.none,
            children: [
              TerminalView(
                widget.session.terminal,
                key: _terminalViewKey,
                controller: _controller,
                scrollController: _scrollController,
                theme: terminalTheme,
                backgroundOpacity: widget.transparentBackground ? 0 : 1,
                keyboardAppearance: Theme.of(context).brightness,
                keyboardType: widget.secureKeyboard
                    ? TextInputType.visiblePassword
                    : TextInputType.emailAddress,
                deleteDetection: true,
                autofocus: !widget.pictureInPicture,
                padding: const EdgeInsets.all(8),
                textStyle: TerminalStyle(
                  fontSize: widget.fontSize,
                  fontFamily: 'monospace',
                ),
              ),
              if (!widget.pictureInPicture && startHandle != null)
                _TerminalSelectionHandle(
                  key: const ValueKey('terminal-selection-handle-start'),
                  anchor: startHandle,
                  color: scheme.primary,
                  onPanStart: (details) => _startHandleDrag(true, details),
                  onPanUpdate: (details) => _updateHandleDrag(true, details),
                  onPanEnd: _endHandleDrag,
                ),
              if (!widget.pictureInPicture && endHandle != null)
                _TerminalSelectionHandle(
                  key: const ValueKey('terminal-selection-handle-end'),
                  anchor: endHandle,
                  color: scheme.primary,
                  onPanStart: (details) => _startHandleDrag(false, details),
                  onPanUpdate: (details) => _updateHandleDrag(false, details),
                  onPanEnd: _endHandleDrag,
                ),
              if (!widget.pictureInPicture && selection != null)
                Positioned(
                  top: 10,
                  right: 10,
                  child: FilledButton.tonalIcon(
                    key: const ValueKey('copy-terminal-selection'),
                    onPressed: _copySelection,
                    icon: const Icon(Icons.copy_outlined, size: 18),
                    label: const LText('复制'),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Offset? _selectionHandlePosition(CellOffset offset) {
    final terminalView = _terminalViewKey.currentState;
    final stackContext = _terminalStackKey.currentContext;
    if (terminalView == null || stackContext == null) return null;
    final stackBox = stackContext.findRenderObject();
    if (stackBox is! RenderBox || !stackBox.hasSize) return null;
    final renderTerminal = terminalView.renderTerminal;
    if (!renderTerminal.attached || !renderTerminal.hasSize) return null;
    final terminalOffset = renderTerminal.getOffset(offset).translate(
          0,
          renderTerminal.cellSize.height,
        );
    final position = stackBox.globalToLocal(
      renderTerminal.localToGlobal(terminalOffset),
    );
    if (position.dy < 0 ||
        position.dy > stackBox.size.height ||
        position.dx < 0 ||
        position.dx > stackBox.size.width) {
      return null;
    }
    return position;
  }

  void _startHandleDrag(bool start, DragStartDetails details) {
    final selection = _controller.selection?.normalized;
    final stackContext = _terminalStackKey.currentContext;
    if (selection == null || stackContext == null) return;
    final stackBox = stackContext.findRenderObject();
    if (stackBox is! RenderBox) return;
    final anchor = _selectionHandlePosition(
      start ? selection.begin : selection.end,
    );
    if (anchor == null) return;
    _dragPointerToAnchor =
        details.globalPosition - stackBox.localToGlobal(anchor);
  }

  void _updateHandleDrag(bool start, DragUpdateDetails details) {
    final pointerToAnchor = _dragPointerToAnchor;
    if (pointerToAnchor == null) return;
    final boundary = _selectionBoundaryAt(
      details.globalPosition - pointerToAnchor,
    );
    final selection = _controller.selection?.normalized;
    if (boundary == null || selection == null) return;

    var begin = selection.begin;
    var end = selection.end;
    if (start) {
      begin = boundary.isAfter(end) ? end : boundary;
    } else {
      end = boundary.isBefore(begin) ? begin : boundary;
    }
    _controller.setSelection(
      widget.session.terminal.buffer.createAnchorFromOffset(begin),
      widget.session.terminal.buffer.createAnchorFromOffset(end),
      mode: _controller.selectionMode,
    );
  }

  CellOffset? _selectionBoundaryAt(Offset globalPosition) {
    final terminalView = _terminalViewKey.currentState;
    if (terminalView == null) return null;
    final renderTerminal = terminalView.renderTerminal;
    if (!renderTerminal.attached || !renderTerminal.hasSize) return null;
    final local = renderTerminal.globalToLocal(globalPosition);
    final origin = renderTerminal.getOffset(const CellOffset(0, 0));
    final cellSize = renderTerminal.cellSize;
    final column = ((local.dx - origin.dx) / cellSize.width)
        .round()
        .clamp(0, widget.session.terminal.viewWidth)
        .toInt();
    final row = (((local.dy - origin.dy) / cellSize.height).round() - 1)
        .clamp(0, widget.session.terminal.buffer.lines.length - 1)
        .toInt();
    return CellOffset(column, row);
  }

  void _endHandleDrag(DragEndDetails details) {
    _dragPointerToAnchor = null;
  }

  Future<void> _copySelection() async {
    final selection = _controller.selection;
    if (selection == null) return;
    final text = widget.session.terminal.buffer.getText(selection);
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    _controller.clearSelection();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: LText('已复制终端文本'),
        duration: Duration(seconds: 1),
      ),
    );
  }
}

class _TerminalSelectionHandle extends StatelessWidget {
  const _TerminalSelectionHandle({
    super.key,
    required this.anchor,
    required this.color,
    required this.onPanStart,
    required this.onPanUpdate,
    required this.onPanEnd,
  });

  static const hitSize = 44.0;

  final Offset anchor;
  final Color color;
  final GestureDragStartCallback onPanStart;
  final GestureDragUpdateCallback onPanUpdate;
  final GestureDragEndCallback onPanEnd;

  @override
  Widget build(BuildContext context) => Positioned(
        left: anchor.dx - hitSize / 2,
        top: anchor.dy - 2,
        width: hitSize,
        height: hitSize,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: onPanStart,
          onPanUpdate: onPanUpdate,
          onPanEnd: onPanEnd,
          child: CustomPaint(
            painter: _TerminalSelectionHandlePainter(color),
          ),
        ),
      );
}

class _TerminalSelectionHandlePainter extends CustomPainter {
  const _TerminalSelectionHandlePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final centerX = size.width / 2;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(centerX - 2, 0, 4, 11),
        const Radius.circular(2),
      ),
      paint,
    );
    canvas.drawCircle(Offset(centerX, 16), 11, paint);
  }

  @override
  bool shouldRepaint(_TerminalSelectionHandlePainter oldDelegate) =>
      oldDelegate.color != color;
}
