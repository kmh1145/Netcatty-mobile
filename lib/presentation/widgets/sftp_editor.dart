import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../application/settings_controller.dart';
import '../localization/localized_widgets.dart';

enum EditorSearchMode { text, wholeWord, regularExpression }

class EditorSearchResult {
  const EditorSearchResult(this.matches, {this.error, this.truncated = false});

  final List<TextRange> matches;
  final String? error;
  final bool truncated;
}

EditorSearchResult findEditorMatches(
  String text,
  String query, {
  EditorSearchMode mode = EditorSearchMode.text,
  bool caseSensitive = false,
  int limit = 10000,
}) {
  if (query.isEmpty || limit <= 0) return const EditorSearchResult([]);
  final matches = <TextRange>[];
  var truncated = false;
  bool add(int start, int end) {
    if (start == end) return true;
    if (matches.length == limit) {
      truncated = true;
      return false;
    }
    matches.add(TextRange(start: start, end: end));
    return true;
  }

  if (mode == EditorSearchMode.regularExpression) {
    try {
      final expression = RegExp(query,
          caseSensitive: caseSensitive, multiLine: true, unicode: true);
      for (final match in expression.allMatches(text)) {
        if (!add(match.start, match.end)) break;
      }
    } on FormatException {
      return const EditorSearchResult([], error: '正则表达式无效');
    }
    return EditorSearchResult(matches, truncated: truncated);
  }

  final wordCharacter = RegExp(r'[\p{L}\p{N}_]', unicode: true);
  final expression =
      RegExp(RegExp.escape(query), caseSensitive: caseSensitive, unicode: true);
  for (final match in expression.allMatches(text)) {
    final start = match.start;
    final end = match.end;
    final wholeWord = mode != EditorSearchMode.wholeWord ||
        !_isWordCharacterBefore(text, start, wordCharacter) &&
            !_isWordCharacterAt(text, end, wordCharacter);
    if (wholeWord && !add(start, end)) break;
  }
  return EditorSearchResult(matches, truncated: truncated);
}

bool _isWordCharacterBefore(String text, int offset, RegExp wordCharacter) {
  if (offset <= 0) return false;
  var start = offset - 1;
  final last = text.codeUnitAt(start);
  if (start > 0 && last >= 0xdc00 && last <= 0xdfff) {
    final first = text.codeUnitAt(start - 1);
    if (first >= 0xd800 && first <= 0xdbff) start--;
  }
  return wordCharacter.hasMatch(text.substring(start, offset));
}

bool _isWordCharacterAt(String text, int offset, RegExp wordCharacter) {
  if (offset >= text.length) return false;
  var end = offset + 1;
  final first = text.codeUnitAt(offset);
  if (end < text.length && first >= 0xd800 && first <= 0xdbff) {
    final last = text.codeUnitAt(end);
    if (last >= 0xdc00 && last <= 0xdfff) end++;
  }
  return wordCharacter.hasMatch(text.substring(offset, end));
}

int _visualLineCount(
  String text,
  TextStyle style,
  TextScaler scaler,
  double? wrapWidth,
) {
  if (wrapWidth == null || wrapWidth <= 0 || text.isEmpty) return 1;
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textScaler: scaler,
  )..layout(maxWidth: wrapWidth);
  final count = math.max(1, painter.computeLineMetrics().length);
  painter.dispose();
  return count;
}

/// Builds one gutter row per rendered editor row. Wrapped continuation rows
/// intentionally receive an empty label so a logical line is never presented
/// as several different source lines.
String buildEditorLineLabels(
  String text,
  TextStyle style,
  TextScaler scaler, {
  double? wrapWidth,
}) {
  final labels = <String>[];
  final lines = text.split('\n');
  for (var index = 0; index < lines.length; index++) {
    final visualLines =
        _visualLineCount(lines[index], style, scaler, wrapWidth);
    labels.add('${index + 1}');
    labels.addAll(List.filled(visualLines - 1, ''));
  }
  return labels.join('\n');
}

double editorLongestLineWidth(String text, TextStyle style, TextScaler scaler) {
  var width = 0.0;
  for (final line in text.split('\n')) {
    final painter = TextPainter(
      text: TextSpan(text: line, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    width = math.max(width, painter.width);
    painter.dispose();
  }
  return width;
}

int editorVisualRowForOffset(
  String text,
  int offset,
  TextStyle style,
  TextScaler scaler, {
  double? wrapWidth,
}) {
  final safeOffset = offset.clamp(0, text.length);
  final prefix = text.substring(0, safeOffset);
  final lines = prefix.split('\n');
  var row = 0;
  for (var index = 0; index < lines.length; index++) {
    final count = _visualLineCount(lines[index], style, scaler, wrapWidth);
    row += index == lines.length - 1 ? count - 1 : count;
  }
  return row;
}

class CodeTextController extends TextEditingController {
  CodeTextController({required String text, required this.filename})
      : super(text: text);
  final String filename;
  bool highlight = true;
  bool dark = true;
  List<TextRange> searchMatches = const [];
  int currentSearchIndex = -1;
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
    final syntaxEnabled = highlight &&
        supported &&
        text.length <= 200000 &&
        !(withComposing &&
            value.composing.isValid &&
            !value.composing.isCollapsed);
    if (!syntaxEnabled && searchMatches.isEmpty) {
      return super.buildTextSpan(
          context: context, style: style, withComposing: withComposing);
    }
    final syntaxMatches = syntaxEnabled
        ? tokens.allMatches(text).toList()
        : const <RegExpMatch>[];
    final boundaries = <int>{0, text.length};
    for (final match in syntaxMatches) {
      boundaries
        ..add(match.start)
        ..add(match.end);
    }
    for (final match in searchMatches) {
      boundaries
        ..add(match.start)
        ..add(match.end);
    }
    final points = boundaries.toList()..sort();
    final spans = <TextSpan>[];
    var syntaxIndex = 0;
    var searchIndex = 0;
    for (var i = 0; i + 1 < points.length; i++) {
      final start = points[i];
      final end = points[i + 1];
      if (end <= start) continue;
      while (syntaxIndex < syntaxMatches.length &&
          syntaxMatches[syntaxIndex].end <= start) {
        syntaxIndex++;
      }
      while (searchIndex < searchMatches.length &&
          searchMatches[searchIndex].end <= start) {
        searchIndex++;
      }
      Color? color;
      if (syntaxIndex < syntaxMatches.length &&
          syntaxMatches[syntaxIndex].start <= start &&
          syntaxMatches[syntaxIndex].end >= end) {
        final token = syntaxMatches[syntaxIndex].group(0)!;
        color = token.startsWith('#') ||
                token.startsWith('//') ||
                token.startsWith('/*')
            ? (dark ? const Color(0xff96a3ac) : const Color(0xff56616a))
            : token.startsWith('"') || token.startsWith("'")
                ? (dark ? const Color(0xffa5d6a7) : const Color(0xff216e39))
                : RegExp(r'^\d').hasMatch(token)
                    ? (dark ? const Color(0xffffcc80) : const Color(0xff945500))
                    : (dark
                        ? const Color(0xff90caf9)
                        : const Color(0xff145eac));
      }
      Color? background;
      if (searchIndex < searchMatches.length &&
          searchMatches[searchIndex].start <= start &&
          searchMatches[searchIndex].end >= end) {
        background = searchIndex == currentSearchIndex
            ? (dark ? const Color(0xffb26a00) : const Color(0xffffb74d))
            : (dark ? const Color(0xff665c00) : const Color(0xffffe082));
      }
      spans.add(TextSpan(
          text: text.substring(start, end),
          style: color == null && background == null
              ? null
              : TextStyle(color: color, backgroundColor: background)));
    }
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
  final editorScroll = ScrollController();
  final horizontalScroll = ScrollController();
  final searchFocus = FocusNode();
  late final search = TextEditingController()..addListener(_searchChanged);
  var searchVisible = false;
  var searchMode = EditorSearchMode.text;
  var searchCaseSensitive = false;
  var searchMatches = const <TextRange>[];
  var currentSearchIndex = -1;
  var searchTruncated = false;
  String? searchError;
  String searchedText = '';
  var softWrap = false;
  var editorFontSize = 14.0;
  final pointers = <int, Offset>{};
  double? pinchStartDistance;
  double? pinchStartFontSize;
  var pinching = false;
  double? lastWrapWidth;
  String? error;

  TextStyle get editorStyle =>
      TextStyle(fontFamily: 'monospace', fontSize: editorFontSize, height: 1.5);

  void _toggleWrap() {
    setState(() => softWrap = !softWrap);
    if (softWrap) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (horizontalScroll.hasClients) horizontalScroll.jumpTo(0);
      });
    }
  }

  void _pointerDown(PointerDownEvent event) {
    pointers[event.pointer] = event.localPosition;
    if (pointers.length == 2) {
      final points = pointers.values.toList();
      pinchStartDistance = (points[0] - points[1]).distance;
      pinchStartFontSize = editorFontSize;
      pinching = true;
      setState(() {});
    } else if (pointers.length > 2) {
      pinchStartDistance = null;
      pinchStartFontSize = null;
      if (pinching) setState(() => pinching = false);
    }
  }

  void _pointerMove(PointerMoveEvent event) {
    if (!pointers.containsKey(event.pointer)) return;
    pointers[event.pointer] = event.localPosition;
    if (pointers.length != 2 ||
        pinchStartDistance == null ||
        pinchStartDistance! <= 0 ||
        pinchStartFontSize == null) {
      return;
    }
    final points = pointers.values.toList();
    final next = (pinchStartFontSize! *
            (points[0] - points[1]).distance /
            pinchStartDistance!)
        .clamp(6.0, 32.0);
    if ((next - editorFontSize).abs() < 0.05) return;
    final ratio = next / editorFontSize;
    final oldVertical = editorScroll.hasClients ? editorScroll.offset : 0.0;
    final oldHorizontal =
        horizontalScroll.hasClients ? horizontalScroll.offset : 0.0;
    setState(() => editorFontSize = next);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (editorScroll.hasClients) {
        editorScroll.jumpTo((oldVertical * ratio)
            .clamp(0.0, editorScroll.position.maxScrollExtent));
      }
      if (!softWrap && horizontalScroll.hasClients) {
        horizontalScroll.jumpTo((oldHorizontal * ratio)
            .clamp(0.0, horizontalScroll.position.maxScrollExtent));
      }
    });
  }

  void _pointerEnd(PointerEvent event) {
    pointers.remove(event.pointer);
    if (pointers.length < 2) {
      pinchStartDistance = null;
      pinchStartFontSize = null;
      if (pinching && mounted) setState(() => pinching = false);
    }
  }

  void _changed() {
    if (searchVisible && searchedText != code.text) _calculateSearch();
    if (mounted) setState(() {});
  }

  void _searchChanged() {
    if (!mounted || !searchVisible) return;
    setState(() => _calculateSearch(reset: true));
    _showCurrentMatch();
  }

  void _calculateSearch({bool reset = false}) {
    searchedText = code.text;
    final result = findEditorMatches(code.text, search.text,
        mode: searchMode, caseSensitive: searchCaseSensitive);
    searchMatches = result.matches;
    searchError = result.error;
    searchTruncated = result.truncated;
    if (searchMatches.isEmpty) {
      currentSearchIndex = -1;
    } else if (reset || currentSearchIndex < 0) {
      currentSearchIndex = 0;
    } else {
      currentSearchIndex =
          currentSearchIndex.clamp(0, searchMatches.length - 1);
    }
  }

  void _toggleSearch() {
    setState(() {
      searchVisible = !searchVisible;
      if (searchVisible) {
        _calculateSearch(reset: true);
      } else {
        searchMatches = const [];
        currentSearchIndex = -1;
        searchError = null;
      }
    });
    if (searchVisible) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => searchFocus.requestFocus());
    } else {
      searchFocus.unfocus();
    }
  }

  void _navigateSearch(int direction) {
    if (searchMatches.isEmpty) return;
    setState(() {
      currentSearchIndex =
          (currentSearchIndex + direction) % searchMatches.length;
      if (currentSearchIndex < 0) currentSearchIndex += searchMatches.length;
    });
    _showCurrentMatch();
  }

  void _showCurrentMatch() {
    if (currentSearchIndex < 0 || currentSearchIndex >= searchMatches.length) {
      return;
    }
    final match = searchMatches[currentSearchIndex];
    code.selection =
        TextSelection(baseOffset: match.start, extentOffset: match.end);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final prefix = code.text.substring(0, match.start);
      final lineStart = prefix.lastIndexOf('\n') + 1;
      final scaler = MediaQuery.textScalerOf(context);
      final line = editorVisualRowForOffset(
        code.text,
        match.start,
        editorStyle,
        scaler,
        wrapWidth: softWrap ? lastWrapWidth : null,
      );
      final lineHeight = editorFontSize * 1.5;
      if (editorScroll.hasClients) {
        final target =
            line * lineHeight - editorScroll.position.viewportDimension / 2;
        editorScroll.animateTo(
            target.clamp(0.0, editorScroll.position.maxScrollExtent),
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut);
      }
      if (!softWrap && horizontalScroll.hasClients) {
        final painter = TextPainter(
            text: TextSpan(
                text: code.text.substring(lineStart, match.start),
                style: editorStyle),
            textDirection: TextDirection.ltr,
            textScaler: scaler)
          ..layout();
        final target =
            painter.width - horizontalScroll.position.viewportDimension / 2;
        painter.dispose();
        horizontalScroll.animateTo(
            target.clamp(0.0, horizontalScroll.position.maxScrollExtent),
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut);
      }
    });
  }

  @override
  void dispose() {
    code.dispose();
    search.removeListener(_searchChanged);
    search.dispose();
    searchFocus.dispose();
    editorScroll.dispose();
    horizontalScroll.dispose();
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
    code.searchMatches = searchVisible ? searchMatches : const [];
    code.currentSearchIndex = searchVisible ? currentSearchIndex : -1;
    final style = editorStyle;
    final scaler = MediaQuery.textScalerOf(context);
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
                IconButton(
                    key: const ValueKey('editor-wrap-toggle'),
                    tooltip: localized('自动换行'),
                    isSelected: softWrap,
                    onPressed: _toggleWrap,
                    icon: const Icon(Icons.wrap_text)),
                IconButton(
                    key: const ValueKey('editor-search-toggle'),
                    tooltip: localized('在文件中搜索'),
                    onPressed: _toggleSearch,
                    icon:
                        Icon(searchVisible ? Icons.search_off : Icons.search)),
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
            if (searchVisible) _searchPanel(),
            if (error != null)
              Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error))),
            if (code.highlight && code.text.length > 200000)
              const LText('大文件已暂停代码高亮'),
            Expanded(child: _editorArea(style, scaler)),
          ]),
        ));
  }

  Widget _editorArea(TextStyle style, TextScaler scaler) {
    return LayoutBuilder(builder: (context, constraints) {
      final digitPainter = TextPainter(
          text: TextSpan(text: '${code.text.split('\n').length}', style: style),
          textDirection: TextDirection.ltr,
          textScaler: scaler)
        ..layout();
      final gutterWidth = math.max(30.0, digitPainter.width + 10);
      digitPainter.dispose();
      final textViewport = math.max(1.0, constraints.maxWidth - gutterWidth);
      const horizontalPadding = 14.0;
      final wrapWidth = math.max(1.0, textViewport - horizontalPadding);
      lastWrapWidth = wrapWidth;
      final labels = buildEditorLineLabels(
        code.text,
        style,
        scaler,
        wrapWidth: softWrap ? wrapWidth : null,
      );
      final editorWidth = softWrap
          ? textViewport
          : math.max(
              textViewport,
              editorLongestLineWidth(code.text, style, scaler) +
                  horizontalPadding);
      final strut = StrutStyle(
        fontFamily: 'monospace',
        fontSize: editorFontSize,
        height: 1.5,
        forceStrutHeight: true,
      );
      return Stack(children: [
        Listener(
          key: const ValueKey('editor-zoom-area'),
          behavior: HitTestBehavior.opaque,
          onPointerDown: _pointerDown,
          onPointerMove: _pointerMove,
          onPointerUp: _pointerEnd,
          onPointerCancel: _pointerEnd,
          child: SingleChildScrollView(
            controller: editorScroll,
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                key: const ValueKey('editor-line-numbers'),
                width: gutterWidth,
                padding: const EdgeInsets.fromLTRB(2, 12, 4, 12),
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Text(
                  labels,
                  style: style,
                  strutStyle: strut,
                  textAlign: TextAlign.right,
                  softWrap: false,
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  controller: horizontalScroll,
                  scrollDirection: Axis.horizontal,
                  physics:
                      softWrap ? const NeverScrollableScrollPhysics() : null,
                  child: SizedBox(
                    width: editorWidth,
                    child: TextField(
                      key: const ValueKey('sftp-editor-field'),
                      controller: code,
                      undoController: undo,
                      maxLines: null,
                      autocorrect: false,
                      enableSuggestions: false,
                      style: style,
                      strutStyle: strut,
                      keyboardType: TextInputType.multiline,
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        disabledBorder: InputBorder.none,
                        errorBorder: InputBorder.none,
                        focusedErrorBorder: InputBorder.none,
                        filled: false,
                        isDense: true,
                        contentPadding: EdgeInsets.fromLTRB(6, 12, 8, 12),
                      ),
                    ),
                  ),
                ),
              ),
            ]),
          ),
        ),
        if (pinching)
          Positioned(
            right: 12,
            bottom: 12,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.inverseSurface,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  child: Text(
                    '${editorFontSize.toStringAsFixed(1)} pt',
                    key: const ValueKey('editor-font-size'),
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.onInverseSurface),
                  ),
                ),
              ),
            ),
          ),
      ]);
    });
  }

  Widget _searchPanel() {
    final label = switch (searchMode) {
      EditorSearchMode.text => '普通文本',
      EditorSearchMode.wholeWord => '全词匹配',
      EditorSearchMode.regularExpression => '正则表达式',
    };
    final count = searchError != null
        ? searchError!
        : searchMatches.isEmpty
            ? '0 / 0'
            : '${currentSearchIndex + 1} / ${searchMatches.length}${searchTruncated ? '+' : ''}';
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        child: Column(children: [
          Row(children: [
            Expanded(
              child: TextField(
                key: const ValueKey('editor-search-field'),
                controller: search,
                focusNode: searchFocus,
                maxLines: 1,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: localized('搜索打开的文件'),
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: search.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: localized('清除'),
                          onPressed: search.clear,
                          icon: const Icon(Icons.clear)),
                  isDense: true,
                ),
              ),
            ),
            IconButton(
                tooltip: localized('关闭搜索'),
                onPressed: _toggleSearch,
                icon: const Icon(Icons.close)),
          ]),
          const SizedBox(height: 4),
          Row(children: [
            PopupMenuButton<EditorSearchMode>(
              key: const ValueKey('editor-search-mode'),
              tooltip: localized('匹配方式'),
              initialValue: searchMode,
              onSelected: (value) {
                setState(() {
                  searchMode = value;
                  _calculateSearch(reset: true);
                });
                _showCurrentMatch();
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                    value: EditorSearchMode.text, child: LText('普通文本')),
                PopupMenuItem(
                    value: EditorSearchMode.wholeWord, child: LText('全词匹配')),
                PopupMenuItem(
                    value: EditorSearchMode.regularExpression,
                    child: LText('正则表达式')),
              ],
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.tune, size: 18),
                  const SizedBox(width: 5),
                  LText(label),
                ]),
              ),
            ),
            IconButton(
              key: const ValueKey('editor-search-case'),
              tooltip: localized('区分大小写'),
              isSelected: searchCaseSensitive,
              onPressed: () {
                setState(() {
                  searchCaseSensitive = !searchCaseSensitive;
                  _calculateSearch(reset: true);
                });
                _showCurrentMatch();
              },
              icon: const Icon(Icons.text_fields),
            ),
            Expanded(
              child: Text(count,
                  key: const ValueKey('editor-search-count'),
                  maxLines: 1,
                  textAlign: TextAlign.end,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: searchError == null
                          ? null
                          : Theme.of(context).colorScheme.error)),
            ),
            IconButton(
                tooltip: localized('上一个匹配'),
                onPressed:
                    searchMatches.isEmpty ? null : () => _navigateSearch(-1),
                icon: const Icon(Icons.keyboard_arrow_up)),
            IconButton(
                tooltip: localized('下一个匹配'),
                onPressed:
                    searchMatches.isEmpty ? null : () => _navigateSearch(1),
                icon: const Icon(Icons.keyboard_arrow_down)),
          ]),
        ]),
      ),
    );
  }
}
