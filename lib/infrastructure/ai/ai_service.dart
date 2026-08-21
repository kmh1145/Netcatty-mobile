import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../domain/models/settings.dart';

class AiSuggestion {
  const AiSuggestion({required this.explanation, required this.command});
  final String explanation;
  final String command;
}

class AiService {
  AiService({
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 30),
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null;
  final http.Client _client;
  final bool _ownsClient;
  final Duration requestTimeout;

  Future<AiSuggestion> suggestCommand({
    required String request,
    required AppSettings settings,
    required String apiKey,
    required String hostSummary,
  }) async {
    final response = await _client
        .post(
          Uri.parse(
            '${settings.aiEndpoint.replaceFirst(RegExp(r'/$'), '')}/chat/completions',
          ),
          headers: {
            'authorization': 'Bearer $apiKey',
            'content-type': 'application/json',
          },
          body: jsonEncode({
            'model': settings.aiModel,
            'temperature': 0.1,
            'response_format': {'type': 'json_object'},
            'messages': [
              {
                'role': 'system',
                'content':
                    'You are Catty, an SSH operations assistant. Return JSON with explanation and command. '
                        'Generate one non-interactive shell command. Never claim it ran. Prefer read-only diagnostics.',
              },
              {
                'role': 'user',
                'content': 'Host: $hostSummary\nRequest: $request'
              },
            ],
          }),
        )
        .timeout(requestTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('AI 请求失败 (${response.statusCode})');
    }
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    final content = ((body['choices'] as List).first as Map)['message']
        ['content'] as String;
    final normalized = content
        .replaceFirst(RegExp(r'^\s*```(?:json)?\s*'), '')
        .replaceFirst(RegExp(r'\s*```\s*$'), '');
    final result = jsonDecode(normalized) as Map<String, dynamic>;
    return AiSuggestion(
      explanation: result['explanation']?.toString() ?? '',
      command: result['command']?.toString() ?? '',
    );
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}
