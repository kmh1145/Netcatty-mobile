import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:xterm2/xterm.dart';

class TerminalPictureInPictureService {
  const TerminalPictureInPictureService._();

  static const _channel = MethodChannel(
    'app.netcatty.mobile/picture_in_picture',
  );
  static final _stateChanges = StreamController<bool>.broadcast();
  static var _initialized = false;
  static var _active = false;
  static int? _lastUpdateSignature;

  static bool get active => _active;
  static Stream<bool> get stateChanges {
    _initialize();
    return _stateChanges.stream;
  }

  static void _initialize() {
    if (_initialized) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'stateChanged') return;
      final arguments = call.arguments;
      final active = arguments is Map && arguments['active'] == true;
      _setActive(active);
    });
  }

  static Future<bool> isSupported() async {
    _initialize();
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  static Future<bool> enter({
    required String title,
    required String text,
    required bool connected,
    required int backgroundColor,
    required int foregroundColor,
    required int accentColor,
  }) async {
    _initialize();
    _lastUpdateSignature = Object.hash(
      title,
      text,
      connected,
      backgroundColor,
      foregroundColor,
      accentColor,
    );
    try {
      final entered = await _channel.invokeMethod<bool>('enter', {
            'title': title,
            'text': text,
            'connected': connected,
            'backgroundColor': backgroundColor,
            'foregroundColor': foregroundColor,
            'accentColor': accentColor,
            'aspectWidth': 16,
            'aspectHeight': 9,
          }) ??
          false;
      if (entered) _setActive(true);
      return entered;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  static Future<void> update({
    required String title,
    required String text,
    required bool connected,
    required int backgroundColor,
    required int foregroundColor,
    required int accentColor,
  }) async {
    if (!_active) return;
    final signature = Object.hash(
      title,
      text,
      connected,
      backgroundColor,
      foregroundColor,
      accentColor,
    );
    if (_lastUpdateSignature == signature) return;
    _lastUpdateSignature = signature;
    try {
      await _channel.invokeMethod<void>('update', {
        'title': title,
        'text': text,
        'connected': connected,
        'backgroundColor': backgroundColor,
        'foregroundColor': foregroundColor,
        'accentColor': accentColor,
      });
    } on MissingPluginException {
      // Picture in Picture is optional outside Android and iOS.
    } on PlatformException {
      // A stopped native PiP session may race with the final terminal update.
    }
  }

  static Future<void> stop() async {
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // No-op on unsupported platforms and in widget tests.
    } on PlatformException {
      // The system may already have dismissed Picture in Picture.
    } finally {
      _lastUpdateSignature = null;
      _setActive(false);
    }
  }

  static void _setActive(bool active) {
    if (_active == active) return;
    _active = active;
    _stateChanges.add(active);
  }
}

String terminalPictureInPictureText(
  Terminal terminal, {
  int maxLines = 18,
  int maxColumns = 96,
}) {
  final buffer = terminal.buffer;
  if (buffer.lines.length == 0 || maxLines <= 0 || maxColumns <= 0) return '';
  final scanCount = math.max(buffer.viewHeight, maxLines * 3);
  final start = math.max(0, buffer.lines.length - scanCount);
  final result = <String>[];
  for (var index = start; index < buffer.lines.length; index++) {
    var text = buffer.lines[index].getText().trimRight();
    if (text.length > maxColumns) text = text.substring(0, maxColumns);
    result.add(text);
  }
  while (result.isNotEmpty && result.last.isEmpty) {
    result.removeLast();
  }
  if (result.length > maxLines) {
    result.removeRange(0, result.length - maxLines);
  }
  while (result.isNotEmpty && result.first.isEmpty) {
    result.removeAt(0);
  }
  return result.every((line) => line.isEmpty) ? '等待终端输出…' : result.join('\n');
}

/// Returns a bounded snapshot of recent terminal output for Catty Agent.
///
/// Physical xterm lines that were soft-wrapped are joined back together. The
/// result intentionally excludes unlimited scrollback so a chat request cannot
/// accidentally upload the entire terminal history.
String terminalAiContextText(
  Terminal terminal, {
  int maxLines = 80,
  int maxColumns = 240,
  int maxCharacters = 12000,
}) {
  final buffer = terminal.buffer;
  if (buffer.lines.length == 0 ||
      maxLines <= 0 ||
      maxColumns <= 0 ||
      maxCharacters <= 0) {
    return '';
  }

  final scanCount = math.max(buffer.viewHeight * 2, maxLines * 4);
  var start = math.max(0, buffer.lines.length - scanCount);
  while (start > 0 && buffer.lines[start].isWrapped) {
    start--;
  }

  final result = <String>[];
  for (var index = start; index < buffer.lines.length; index++) {
    final line = buffer.lines[index];
    var text = line.getText().trimRight();
    if (text.length > maxColumns) {
      text = text.substring(0, maxColumns);
    }
    if (line.isWrapped && result.isNotEmpty) {
      result[result.length - 1] += text;
    } else {
      result.add(text);
    }
  }

  while (result.isNotEmpty && result.last.isEmpty) {
    result.removeLast();
  }
  while (result.isNotEmpty && result.first.isEmpty) {
    result.removeAt(0);
  }
  if (result.length > maxLines) {
    result.removeRange(0, result.length - maxLines);
  }

  final output = result.join('\n');
  if (output.length <= maxCharacters) return output;
  return output.substring(output.length - maxCharacters);
}
