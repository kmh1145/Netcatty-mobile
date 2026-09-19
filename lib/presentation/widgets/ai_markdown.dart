import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:highlight/highlight_core.dart' as syntax;
import 'package:highlight/languages/bash.dart';
import 'package:highlight/languages/css.dart';
import 'package:highlight/languages/dart.dart';
import 'package:highlight/languages/dockerfile.dart';
import 'package:highlight/languages/go.dart';
import 'package:highlight/languages/ini.dart';
import 'package:highlight/languages/javascript.dart';
import 'package:highlight/languages/json.dart';
import 'package:highlight/languages/nginx.dart';
import 'package:highlight/languages/powershell.dart';
import 'package:highlight/languages/python.dart';
import 'package:highlight/languages/rust.dart';
import 'package:highlight/languages/sql.dart';
import 'package:highlight/languages/typescript.dart';
import 'package:highlight/languages/xml.dart';
import 'package:highlight/languages/yaml.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher.dart';

import '../localization/localized_widgets.dart';

/// Render replies only; never evaluate HTML, code or embedded remote images.
class AiMarkdown extends StatelessWidget {
  const AiMarkdown(this.data, {super.key});
  final String data;

  @override
  Widget build(BuildContext context) => MarkdownBody(
        data: data,
        selectable: true,
        fitContent: true,
        extensionSet: md.ExtensionSet.gitHubFlavored,
        styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
          code: TextStyle(
              fontFamily: 'monospace',
              color: Theme.of(context).colorScheme.onSurface),
          codeblockPadding: EdgeInsets.zero,
          tableColumnWidth: const FlexColumnWidth(),
        ),
        builders: {'pre': _CodeBuilder(), 'code': _InlineCodeBuilder()},
        // Image URLs in model output can be tracking URLs. Do not load them.
        imageBuilder: (_, __, alt) => SelectableText(alt ?? '[image]'),
        onTapLink: (_, href, __) => _openLink(context, href),
      );

  Future<void> _openLink(BuildContext context, String? href) async {
    final uri = Uri.tryParse(href ?? '');
    if (uri == null ||
        !{'https', 'http'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      return;
    }
    final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
              title: const LText('打开链接？'),
              content: SelectableText(uri.toString()),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const LText('取消')),
                FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const LText('打开')),
              ],
            ));
    if (confirmed != true || !context.mounted) return;
    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        throw StateError('link');
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: LText('无法打开链接')));
      }
    }
  }
}

class _InlineCodeBuilder extends MarkdownElementBuilder {
  @override
  Widget visitElementAfterWithContext(BuildContext context, md.Element element,
          TextStyle? preferredStyle, TextStyle? parentStyle) =>
      AiInlineCode(element.textContent);
}

class AiInlineCode extends StatelessWidget {
  const AiInlineCode(this.code, {super.key});
  final String code;

  @override
  Widget build(BuildContext context) => IntrinsicWidth(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(5),
          ),
          child: SelectableText(code,
              style: TextStyle(
                fontFamily: 'monospace',
                color: Theme.of(context).colorScheme.onSurface,
                fontSize: Theme.of(context).textTheme.bodyMedium?.fontSize,
              )),
        ),
      );
}

class _CodeBuilder extends MarkdownElementBuilder {
  @override
  bool isBlockElement() => true;

  @override
  Widget visitElementAfterWithContext(BuildContext context, md.Element element,
      TextStyle? preferredStyle, TextStyle? parentStyle) {
    final code = element.children?.whereType<md.Element>().firstOrNull;
    final language =
        code?.attributes['class']?.replaceFirst('language-', '') ?? '';
    return AiCodeBlock(code: element.textContent, language: language);
  }
}

final _syntax = syntax.Highlight()
  ..registerLanguage('bash', bash)
  ..registerLanguage('json', json)
  ..registerLanguage('yaml', yaml)
  ..registerLanguage('python', python)
  ..registerLanguage('javascript', javascript)
  ..registerLanguage('typescript', typescript)
  ..registerLanguage('dart', dart)
  ..registerLanguage('dockerfile', dockerfile)
  ..registerLanguage('nginx', nginx)
  ..registerLanguage('ini', ini)
  ..registerLanguage('sql', sql)
  ..registerLanguage('xml', xml)
  ..registerLanguage('css', css)
  ..registerLanguage('go', go)
  ..registerLanguage('rust', rust)
  ..registerLanguage('powershell', powershell);

/// Bound syntax work and preserve exact source for selection/copy on fallback.
TextSpan aiCodeSpan(String code, String language, {required bool dark}) {
  final normalized = language.toLowerCase().trim();
  final name = const {
        'sh': 'bash',
        'shell': 'bash',
        'zsh': 'bash',
        'js': 'javascript',
        'ts': 'typescript',
        'py': 'python',
        'yml': 'yaml',
        'html': 'xml',
        'toml': 'ini',
        'ps1': 'powershell',
        'rs': 'rust'
      }[normalized] ??
      normalized;
  if (code.length > 20000 || name.isEmpty) {
    return TextSpan(text: code);
  }
  try {
    TextSpan span(syntax.Node node) => TextSpan(
          text: node.value,
          style: TextStyle(
              color: switch (node.className) {
            'comment' =>
              dark ? const Color(0xffa0a8b7) : const Color(0xff59636e),
            'string' ||
            'attr' =>
              dark ? const Color(0xffa5d6a7) : const Color(0xff216e39),
            'number' ||
            'literal' =>
              dark ? const Color(0xffffcc80) : const Color(0xff945500),
            'keyword' ||
            'built_in' ||
            'type' =>
              dark ? const Color(0xff90caf9) : const Color(0xff145eac),
            'variable' ||
            'title' ||
            'function' ||
            'name' =>
              dark ? const Color(0xffce93d8) : const Color(0xff7938a3),
            _ => null,
          }),
          children: node.children?.map(span).toList(),
        );
    final result = TextSpan(
        children:
            _syntax.parse(code, language: name).nodes?.map(span).toList());
    // Never risk copying altered commands if a grammar loses any characters.
    return result.toPlainText() == code ? result : TextSpan(text: code);
  } catch (_) {
    return TextSpan(text: code);
  }
}

class AiCodeBlock extends StatefulWidget {
  const AiCodeBlock({super.key, required this.code, this.language = ''});
  final String code;
  final String language;
  @override
  State<AiCodeBlock> createState() => _AiCodeBlockState();
}

class _AiCodeBlockState extends State<AiCodeBlock> {
  String? _source, _language;
  bool? _dark;
  TextSpan? _span;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    if (_source != widget.code ||
        _language != widget.language ||
        _dark != dark) {
      _source = widget.code;
      _language = widget.language;
      _dark = dark;
      _span = aiCodeSpan(widget.code, widget.language, dark: dark);
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10)),
      child: SelectableText.rich(_span!,
          style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 13,
              height: 1.4,
              color: theme.colorScheme.onSurface)),
    );
  }
}
