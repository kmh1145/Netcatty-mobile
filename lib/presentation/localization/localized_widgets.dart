import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'translations_en.dart';

class NetcattyLocalizations {
  const NetcattyLocalizations._();

  static String _language = 'zh-CN';

  static String get language => _language;
  static bool get isEnglish => _language == 'en';

  static void use(String language) {
    _language = language == 'en' ? 'en' : 'zh-CN';
  }

  static String text(String source) {
    if (!isEnglish || source.isEmpty) return source;
    final exact = englishTranslations[source];
    if (exact != null) return exact;
    var value = source;
    for (final replacement in englishReplacements) {
      value = value.replaceAll(replacement.$1, replacement.$2);
    }
    return value.trim();
  }
}

String localized(String source) => NetcattyLocalizations.text(source);

class LText extends StatelessWidget {
  const LText(
    this.data, {
    super.key,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
  });

  final String data;
  final TextStyle? style;
  final StrutStyle? strutStyle;
  final TextAlign? textAlign;
  final TextDirection? textDirection;
  final Locale? locale;
  final bool? softWrap;
  final TextOverflow? overflow;
  final TextScaler? textScaler;
  final int? maxLines;
  final String? semanticsLabel;
  final TextWidthBasis? textWidthBasis;
  final TextHeightBehavior? textHeightBehavior;
  final Color? selectionColor;

  @override
  Widget build(BuildContext context) => Text(
        localized(data),
        style: style,
        strutStyle: strutStyle,
        textAlign: textAlign,
        textDirection: textDirection,
        locale: locale,
        softWrap: softWrap,
        overflow: overflow,
        textScaler: textScaler,
        maxLines: maxLines,
        semanticsLabel:
            semanticsLabel == null ? null : localized(semanticsLabel!),
        textWidthBasis: textWidthBasis,
        textHeightBehavior: textHeightBehavior,
        selectionColor: selectionColor,
      );
}

class LSelectableText extends StatelessWidget {
  const LSelectableText(
    this.data, {
    super.key,
    this.focusNode,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.textScaler,
    this.showCursor = false,
    this.autofocus = false,
    this.minLines,
    this.maxLines,
    this.cursorWidth = 2,
    this.cursorHeight,
    this.cursorRadius,
    this.cursorColor,
    this.enableInteractiveSelection = true,
    this.onTap,
    this.scrollPhysics,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.contextMenuBuilder,
    this.magnifierConfiguration,
    this.dragStartBehavior = DragStartBehavior.start,
  });

  final String data;
  final FocusNode? focusNode;
  final TextStyle? style;
  final StrutStyle? strutStyle;
  final TextAlign? textAlign;
  final TextDirection? textDirection;
  final TextScaler? textScaler;
  final bool showCursor;
  final bool autofocus;
  final int? minLines;
  final int? maxLines;
  final double cursorWidth;
  final double? cursorHeight;
  final Radius? cursorRadius;
  final Color? cursorColor;
  final bool enableInteractiveSelection;
  final GestureTapCallback? onTap;
  final ScrollPhysics? scrollPhysics;
  final TextWidthBasis? textWidthBasis;
  final TextHeightBehavior? textHeightBehavior;
  final EditableTextContextMenuBuilder? contextMenuBuilder;
  final TextMagnifierConfiguration? magnifierConfiguration;
  final DragStartBehavior dragStartBehavior;

  @override
  Widget build(BuildContext context) => SelectableText(
        localized(data),
        focusNode: focusNode,
        style: style,
        strutStyle: strutStyle,
        textAlign: textAlign,
        textDirection: textDirection,
        textScaler: textScaler,
        showCursor: showCursor,
        autofocus: autofocus,
        minLines: minLines,
        maxLines: maxLines,
        cursorWidth: cursorWidth,
        cursorHeight: cursorHeight,
        cursorRadius: cursorRadius,
        cursorColor: cursorColor,
        enableInteractiveSelection: enableInteractiveSelection,
        onTap: onTap,
        scrollPhysics: scrollPhysics,
        textWidthBasis: textWidthBasis,
        textHeightBehavior: textHeightBehavior,
        contextMenuBuilder: contextMenuBuilder,
        magnifierConfiguration: magnifierConfiguration,
        dragStartBehavior: dragStartBehavior,
      );
}

class LInputDecoration extends InputDecoration {
  LInputDecoration({
    super.icon,
    super.label,
    String? labelText,
    super.labelStyle,
    super.floatingLabelStyle,
    String? helperText,
    super.helperStyle,
    super.helperMaxLines,
    String? hintText,
    super.hintStyle,
    super.hintTextDirection,
    super.hintMaxLines,
    String? errorText,
    super.errorStyle,
    super.errorMaxLines,
    super.floatingLabelBehavior,
    super.floatingLabelAlignment,
    super.isCollapsed,
    super.isDense,
    super.contentPadding,
    super.prefixIcon,
    super.prefixIconConstraints,
    super.prefix,
    String? prefixText,
    super.prefixStyle,
    super.prefixIconColor,
    super.suffixIcon,
    super.suffix,
    String? suffixText,
    super.suffixStyle,
    super.suffixIconColor,
    String? counterText,
    super.counter,
    super.counterStyle,
    super.filled,
    super.fillColor,
    super.focusColor,
    super.hoverColor,
    super.error,
    super.errorBorder,
    super.focusedBorder,
    super.focusedErrorBorder,
    super.disabledBorder,
    super.enabledBorder,
    super.border,
    super.enabled,
    super.semanticCounterText,
    super.alignLabelWithHint,
    super.constraints,
  }) : super(
          labelText: labelText == null ? null : localized(labelText),
          helperText: helperText == null ? null : localized(helperText),
          hintText: hintText == null ? null : localized(hintText),
          errorText: errorText == null ? null : localized(errorText),
          prefixText: prefixText == null ? null : localized(prefixText),
          suffixText: suffixText == null ? null : localized(suffixText),
          counterText: counterText == null ? null : localized(counterText),
        );
}
