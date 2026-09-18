import 'dart:convert';

/// Only completed replies reach this parser. Extracting a suggestion never
/// authorizes execution: the UI must still show the complete command for review.
({String message, String? command}) parseAiReply(String content) {
  final fences =
      RegExp(r'```([^\n`]*)\n([\s\S]*?)```').allMatches(content).toList();
  final candidates = <String>[content.trim()];
  for (final fence in fences) {
    if (['', 'json'].contains(fence[1]!.trim().toLowerCase())) {
      candidates.add(fence[2]!.trim());
    }
  }
  // A provider may put prose before or after its JSON response. Scan balanced
  // objects instead of a greedy regex (braces inside quoted commands are valid).
  var depth = 0, start = 0;
  var quoted = false, escaped = false;
  for (var i = 0; i < content.length; i++) {
    final c = content[i];
    if (depth == 0) {
      if (c == '{') {
        start = i;
        depth = 1;
        quoted = false;
      }
      continue;
    }
    if (escaped) {
      escaped = false;
      continue;
    }
    if (quoted && c == r'\') {
      escaped = true;
      continue;
    }
    if (c == '"') {
      quoted = !quoted;
      continue;
    }
    if (quoted) continue;
    if (c == '{') depth++;
    if (c == '}' && --depth == 0) {
      candidates.add(content.substring(start, i + 1));
    }
  }
  for (final candidate in candidates) {
    try {
      final json = jsonDecode(candidate);
      if (json is! Map) continue;
      final message = json['message'] ?? json['explanation'] ?? json['content'];
      final command = _command(json['command'] ?? json['commands']);
      if (message is! String && command == null) continue;
      return (
        message: message is String && message.trim().isNotEmpty
            ? message.trim()
            : content.trim(),
        command: command ??
            (message is String ? _markdownCommand(message) : null) ??
            _shellBlocks(fences)
      );
    } on FormatException {/* Try the next structured candidate. */}
  }
  return (message: content.trim(), command: _markdownCommand(content));
}

String? _markdownCommand(String content) {
  final blocks = _shellBlocks(
      RegExp(r'```([^\n`]*)\n([\s\S]*?)```').allMatches(content).toList());
  if (blocks != null) return blocks;
  // Inline code is only a suggestion when explicitly introduced as a command.
  final inline = RegExp(
          r'(?:\brun\b|\bexecute\b|\bcommand\b|\u6267\u884c|\u8fd0\u884c|\u547d\u4ee4)\s*[:\uff1a]?\s*`([^`\n]+)`',
          caseSensitive: false)
      .allMatches(content)
      .map((m) => m[1]!.trim())
      .where(_looksLikeCommand)
      .toList();
  return inline.isEmpty ? null : inline.join('\n');
}

bool _looksLikeCommand(String line) => RegExp(
        r'^(?:sudo|doas|ls|pwd|cd|cat|grep|find|sed|awk|head|tail|less|echo|printf|df|du|free|ps|top|htop|kill|ip|ss|ping|curl|wget|apt|apt-get|apk|yum|dnf|systemctl|journalctl|service|rc-service|docker|podman|tmux|git|chmod|chown|mkdir|cp|mv|rm|tar|unzip|zip|python3?|node|bash|sh)(?:\s|$)')
    .hasMatch(line);

String? _command(Object? value) {
  if (value is String) return value.trim().isEmpty ? null : value.trim();
  if (value is List) {
    final commands = value
        .map((v) => _command(v is Map ? v['command'] : v))
        .whereType<String>()
        .toList();
    return commands.isEmpty ? null : commands.join('\n');
  }
  return null;
}

String? _shellBlocks(List<RegExpMatch> fences) {
  final commands = <String>[];
  for (final fence in fences) {
    final language = fence[1]!.trim().toLowerCase();
    var body = fence[2]!.trim();
    final lines = body.split('\n');
    if (lines.every((line) => line.startsWith(r'$ '))) {
      body = lines.map((line) => line.substring(2)).join('\n');
    }
    // Never interpret arbitrary configuration, logs or JSON as shell input.
    if (body.isEmpty ||
        (!{'bash', 'sh', 'shell', 'zsh', 'fish', 'powershell', 'ps1', 'cmd'}
                .contains(language) &&
            !(language.isEmpty &&
                body
                    .split('\n')
                    .every((line) => _looksLikeCommand(line.trim()))))) {
      continue;
    }
    commands.add(body);
  }
  return commands.isEmpty ? null : commands.join('\n');
}
