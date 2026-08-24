import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:netcatty_mobile/domain/models/settings.dart';
import 'package:netcatty_mobile/infrastructure/ai/ai_service.dart';

void main() {
  test('chat requests preserve history and the live custom SSH port', () async {
    late Map<String, dynamic> requestBody;
    final client = MockClient((request) async {
      requestBody = jsonDecode(request.body) as Map<String, dynamic>;
      expect(request.headers['authorization'], 'Bearer secret');
      return http.Response.bytes(
        utf8.encode(jsonEncode({
          'choices': [
            {
              'message': {
                'content': jsonEncode({
                  'message': '可以继续检查服务状态。',
                  'command': 'systemctl --failed',
                }),
              },
            },
          ],
        })),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    final service = AiService(client: client);

    final reply = await service.sendMessage(
      request: '继续检查',
      history: const [
        AiChatMessage(role: AiChatRole.user, content: '先检查磁盘'),
        AiChatMessage(
          role: AiChatRole.assistant,
          content: '可以运行磁盘检查。',
          command: 'df -h',
        ),
      ],
      settings: const AppSettings(
        aiEndpoint: 'https://ai.example.com/v1/',
        aiModel: 'test-model',
      ),
      apiKey: 'secret',
      hostSummary: 'SSH session NAS; endpoint root@nas.example.com:22022',
    );

    expect(reply.role, AiChatRole.assistant);
    expect(reply.content, '可以继续检查服务状态。');
    expect(reply.command, 'systemctl --failed');
    expect(requestBody['model'], 'test-model');
    final messages = (requestBody['messages'] as List).cast<Map>();
    expect(
      messages[1]['content'],
      contains('root@nas.example.com:22022'),
    );
    expect(messages[2], {'role': 'user', 'content': '先检查磁盘'});
    expect(messages[3]['content'], contains('df -h'));
    expect(messages.last, {'role': 'user', 'content': '继续检查'});
    expect(messages.first['content'], contains('never assume port 22'));
  });

  test('plain text replies from compatible providers remain usable', () async {
    final service = AiService(
      client: MockClient(
        (_) async => http.Response.bytes(
          utf8.encode(jsonEncode({
            'choices': [
              {
                'message': {'content': '目前不需要执行命令。'},
              },
            ],
          })),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    );

    final reply = await service.sendMessage(
      request: '现在安全吗？',
      history: const [],
      settings: const AppSettings(),
      apiKey: 'secret',
      hostSummary: 'root@example.com:2222',
    );

    expect(reply.content, '目前不需要执行命令。');
    expect(reply.command, isNull);
  });
}
