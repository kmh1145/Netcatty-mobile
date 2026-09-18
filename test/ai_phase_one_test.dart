import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:netcatty_mobile/domain/models/settings.dart';
import 'package:netcatty_mobile/infrastructure/ai/ai_service.dart';
import 'package:netcatty_mobile/infrastructure/ai/ai_workspace.dart';

Future<AiChatMessage> send(AiService service,
        {AiCancellation? token,
        void Function(String)? progress,
        bool json = false}) =>
    service.sendMessage(
        request: 'diagnose',
        history: [],
        settings: const AppSettings(),
        apiKey: '',
        hostSummary: 'server',
        cancellation: token,
        onProgress: progress,
        jsonMode: json);

void main() {
  test('SSE decodes split UTF8, JSON deltas and CRLF events', () async {
    final content = jsonEncode({'message': '你好\n世界', 'command': 'pwd'});
    final wire = '${content.split('').map((c) => 'data: ${jsonEncode({
                  'choices': [
                    {
                      'delta': {'content': c}
                    }
                  ]
                })}\r\n\r\n').join()}'
        'data: [DONE]\r\n\r\n';
    final seen = <String>[];
    final service = AiService(client: MockClient.streaming((r, _) async {
      expect(r.headers.containsKey('authorization'), false);
      return http.StreamedResponse(
          Stream.fromIterable(utf8.encode(wire).map((b) => [b])), 200,
          headers: {'content-type': 'text/event-stream'});
    }));
    final result = await send(service, progress: seen.add);
    expect(result.content, '你好\n世界');
    expect(result.command, 'pwd');
    expect(seen, contains('你好\n世界'));
  });
  test('truncated SSE never exposes an executable partial command', () async {
    final service = AiService(
        client: MockClient.streaming((_, __) async => http.StreamedResponse(
            Stream.value(utf8.encode(
                'data: {"choices":[{"delta":{"content":"partial"}}]}\n\n')),
            200,
            headers: {'content-type': 'text/event-stream'})));
    await expectLater(send(service, progress: (_) {}), throwsStateError);
  });
  test('stop resolves immediately even if transport has not returned headers',
      () async {
    final token = AiCancellation();
    final response = Completer<http.StreamedResponse>();
    final service =
        AiService(client: MockClient.streaming((_, __) => response.future));
    final result = send(service, token: token);
    final check = expectLater(result, throwsA(isA<AiCancelled>()));
    token.cancel();
    await check;
    response
        .complete(http.StreamedResponse(Stream.value(utf8.encode('{}')), 200));
  });
  test('explicit unsupported JSON parameter retries once without it', () async {
    var calls = 0;
    final service = AiService(client: MockClient((r) async {
      final payload = jsonDecode(r.body) as Map;
      expect(payload.containsKey('temperature'), false);
      calls++;
      if (calls == 1) {
        expect(payload.containsKey('response_format'), true);
        return http.Response('unsupported response_format', 400);
      }
      expect(payload.containsKey('response_format'), false);
      return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'ok'}
              }
            ]
          }),
          200);
    }));
    expect((await send(service, json: true)).content, 'ok');
    expect(calls, 2);
  });
  test('auth failure is not retried', () async {
    var calls = 0;
    final service = AiService(client: MockClient((_) async {
      calls++;
      return http.Response('secret', 401);
    }));
    await expectLater(
        send(service),
        throwsA(predicate((e) =>
            e.toString().contains('密钥') && !e.toString().contains('secret'))));
    expect(calls, 1);
  });
  test('idle timeout terminates response', () async {
    final controller = StreamController<List<int>>();
    final service = AiService(
        requestTimeout: const Duration(milliseconds: 10),
        client: MockClient.streaming((_, __) async => http.StreamedResponse(
            controller.stream, 200,
            headers: {'content-type': 'text/event-stream'})));
    await expectLater(send(service, progress: (_) {}), throwsStateError);
    await controller.close();
  });
  test('secure workspace roundtrip preserves profile options and summary',
      () async {
    final memory = <String, String>{};
    final workspace = AiWorkspace(
        read: (k) async => memory[k],
        write: (k, v) async {
          if (v == null) {
            memory.remove(k);
          } else {
            memory[k] = v;
          }
        });
    await workspace.saveProfiles([
      const AiProviderProfile(
          id: 'a',
          name: 'A',
          endpoint: 'http://localhost:1234/v1',
          apiKey: '',
          models: ['local'],
          reasoning: false)
    ]);
    await workspace.setActiveProfile('a');
    expect(await workspace.activeProfile(), 'a');
    expect((await workspace.profiles()).single.reasoning, false);
    await workspace.saveConversation(
        'host',
        const AiConversation(summary: 'summary', messages: [
          AiChatMessage(
              role: AiChatRole.assistant, content: 'check', command: 'pwd')
        ]));
    expect((await workspace.conversation('host')).summary, 'summary');
    expect(
        (await workspace.conversation('host')).messages.single.command, 'pwd');
    await workspace.setRememberHistory('host', false);
    expect(await workspace.remembersHistory('host'), false);
    expect((await workspace.conversation('host')).messages, isEmpty);
    await workspace.saveConversation(
        'host', const AiConversation(summary: 'late callback'));
    expect((await workspace.conversation('host')).summary, isEmpty);
    expect(memory.keys.any((k) => k.contains('vault')), false);
  });
  test('queued history deletion cannot be undone by older writes', () async {
    final memory = <String, String>{};
    final workspace = AiWorkspace(
        read: (k) async => memory[k],
        write: (k, v) async {
          await Future<void>.delayed(const Duration(milliseconds: 2));
          if (v == null) {
            memory.remove(k);
          } else {
            memory[k] = v;
          }
        });
    final save = workspace.saveConversation(
        'h', const AiConversation(summary: 'secret'));
    final remove = workspace.setRememberHistory('h', false);
    await Future.wait([save, remove]);
    expect((await workspace.conversation('h')).summary, isEmpty);
  });
  test('redaction masks identity, credentials and private key blocks', () {
    final output = redactAiText(
        'server.example.com token=abc\nAuthorization: Bearer xyz\n'
        '-----BEGIN OPENSSH PRIVATE KEY-----\nprivate\n-----END OPENSSH PRIVATE KEY-----',
        identities: ['server.example.com']);
    expect(output, isNot(contains('abc')));
    expect(output, isNot(contains('xyz')));
    expect(output, isNot(contains('private')));
    expect(output, isNot(contains('server.example.com')));
  });
}
