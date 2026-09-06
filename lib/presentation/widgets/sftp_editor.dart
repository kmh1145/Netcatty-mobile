import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../application/settings_controller.dart';
import '../localization/localized_widgets.dart';

class CodeTextController extends TextEditingController {
  CodeTextController({required String text, required this.filename})
      : super(text: text);
  final String filename;
  bool highlight = true;
  bool dark = true;
  static final tokens = RegExp(
    r'''("(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|//[^\n]*|\#[^\n]*|/\*[\s\S]*?\*/|\b(?:if|else|for|while|return|class|import|from|def|function|const|let|var|true|false|null|None|True|False|sudo|then|fi|do|done|echo|export)\b|\b\d+(?:\.\d+)?\b)''',
  );
  @override
  TextSpan buildTextSpan(
      {required BuildContext context,
      TextStyle? style,
      required bool withComposing}) {
    final supported =
        RegExp(r'\.(json|ya?ml|py|sh|bash|js|ts|tsx|jsx|dart|java|kt|c|cpp|h|rs|go|css|html|xml|toml|ini|conf|sql)$',
                    caseSensitive: false)
                .hasMatch(filename) ||
            filename == 'Dockerfile';
    if (!highlight ||
        !supported ||
        text.length > 200000 ||
        (withComposing &&
            value.composing.isValid &&
            !value.composing.isCollapsed)) {
      return super.buildTextSpan(
          context: context, style: style, withComposing: withComposing);
    }
    final spans = <TextSpan>[];
    var offset = 0;
    for (final match in tokens.allMatches(text)) {
      if (match.start > offset) {
        spans.add(TextSpan(text: text.substring(offset, match.start)));
      }
      final token = match.group(0)!;
      final color = token.startsWith('#') ||
              token.startsWith('//') ||
              token.startsWith('/*')
          ? (dark ? const Color(0xff96a3ac) : const Color(0xff56616a))
          : token.startsWith('"') || token.startsWith("'")
              ? (dark ? const Color(0xffa5d6a7) : const Color(0xff216e39))
              : RegExp(r'^\d').hasMatch(token)
                  ? (dark ? const Color(0xffffcc80) : const Color(0xff945500))
                  : (dark ? const Color(0xff90caf9) : const Color(0xff145eac));
      spans.add(TextSpan(text: token, style: TextStyle(color: color)));
      offset = match.end;
    }
    spans.add(TextSpan(text: text.substring(offset)));
    return TextSpan(style: style, children: spans);
  }
}

class SftpEditor extends ConsumerStatefulWidget {
  const SftpEditor(
      {super.key,
      required this.name,
      required this.content,
      required this.onSave});
  final String name;
  final String content;
  final Future<void> Function(String) onSave;
  @override
  ConsumerState<SftpEditor> createState() => _SftpEditorState();
}

class _SftpEditorState extends ConsumerState<SftpEditor> {
  late final code =
      CodeTextController(text: widget.content, filename: widget.name)
        ..addListener(_changed);
  late String saved = widget.content;
  bool saving = false;
  final undo = UndoHistoryController();
  String? error;
  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    code.dispose();
    undo.dispose();
    super.dispose();
  }

  Future<void> _close() async {
    if (saving) return;
    if (saved != code.text) {
      final discard = await showDialog<bool>(
          context: context,
          builder: (context) =>
              AlertDialog(title: const LText('放弃未保存的修改？'), actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const LText('取消')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const LText('放弃'))
              ]));
      if (discard != true || !mounted) return;
    }
    if (mounted) Navigator.pop(context);
  }

  Future<void> _save() async {
    final text = code.text;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      await widget.onSave(text);
      if (mounted) setState(() => saved = text);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    code.highlight = ref.watch(settingsControllerProvider).sftpSyntaxHighlight;
    code.dark = Theme.of(context).brightness == Brightness.dark;
    final lines = code.text.split('\n');
    const style = TextStyle(fontFamily: 'monospace', fontSize: 14, height: 1.5);
    final scaler = MediaQuery.textScalerOf(context);
    final measure = TextPainter(
        text: TextSpan(text: code.text, style: style),
        textDirection: TextDirection.ltr,
        textScaler: scaler)
      ..layout();
    final width =
        math.max(MediaQuery.sizeOf(context).width - 64, measure.width + 48);
    measure.dispose();
    return PopScope(
        canPop: saved == code.text && !saving,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _close();
        },
        child: Scaffold(
          appBar: AppBar(
              leading:
                  IconButton(onPressed: _close, icon: const Icon(Icons.close)),
              title: Text('${saved == code.text ? '' : '* '}${widget.name}'),
              actions: [
                ValueListenableBuilder<UndoHistoryValue>(
                    valueListenable: undo,
                    builder: (context, value, _) => Row(children: [
                          IconButton(
                              tooltip: localized('撤销'),
                              onPressed: value.canUndo ? undo.undo : null,
                              icon: const Icon(Icons.undo)),
                          IconButton(
                              tooltip: localized('重做'),
                              onPressed: value.canRedo ? undo.redo : null,
                              icon: const Icon(Icons.redo)),
                        ])),
                TextButton(
                    onPressed: saving ? null : _save,
                    child: LText(saving ? '保存中…' : '保存'))
              ]),
          body: Column(children: [
            if (error != null)
              Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error))),
            if (code.highlight && code.text.length > 200000)
              const LText('大文件已暂停代码高亮'),
            Expanded(
                child: SingleChildScrollView(
                    child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                  Container(
                      width: 56,
                      padding: const EdgeInsets.symmetric(
                          vertical: 12, horizontal: 6),
                      color:
                          Theme.of(context).colorScheme.surfaceContainerHighest,
                      child: Text(
                          List.generate(lines.length, (i) => '${i + 1}')
                              .join('\n'),
                          style: style,
                          textAlign: TextAlign.right)),
                  Expanded(
                      child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: SizedBox(
                              width: width,
                              child: TextField(
                                  controller: code,
                                  undoController: undo,
                                  maxLines: null,
                                  autocorrect: false,
                                  enableSuggestions: false,
                                  style: style,
                                  keyboardType: TextInputType.multiline,
                                  decoration: const InputDecoration(
                                      border: InputBorder.none,
                                      filled: false,
                                      isDense: true,
                                      contentPadding: EdgeInsets.all(12)))))),
                ]))),
          ]),
        ));
  }
}
