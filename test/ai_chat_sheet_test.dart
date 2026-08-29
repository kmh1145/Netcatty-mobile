import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/domain/models/settings.dart';
import 'package:netcatty_mobile/infrastructure/ai/ai_service.dart';
import 'package:netcatty_mobile/presentation/widgets/ai_chat_sheet.dart';

void main() {
  testWidgets('command actions stay bound to the displayed custom-port host',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final sent = <({String command, bool execute})>[];
    final host = HostProfile.create(
      id: 'nas',
      label: 'NAS',
      hostname: 'nas.example.com',
      username: 'root',
      port: 22022,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AiChatSheet(
            host: host,
            settings: const AppSettings(),
            apiKey: 'unused',
            service: AiService(
              client: MockClient(
                (_) async => http.Response('unexpected request', 500),
              ),
            ),
            initialMessages: const [
              AiChatMessage(
                role: AiChatRole.assistant,
                content: '检查当前监听端口。',
                command: 'ss -lntp',
              ),
            ],
            onMessagesChanged: (_) {},
            terminalContext: () => 'nginx is active',
            onModelChanged: (_) async {},
            onReasoningEffortChanged: (_) async {},
            onCommand: (command, execute) async {
              sent.add((command: command, execute: execute));
            },
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('root@nas.example.com:22022'), findsOneWidget);
    final paste = find.byKey(const ValueKey('ai-command-paste'));
    await tester.ensureVisible(paste);
    await tester.tap(paste);
    await tester.pump();

    expect(sent, [(command: 'ss -lntp', execute: false)]);
    expect(find.text('命令已粘贴到 NAS'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard keeps the composer visible above its inset',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(390, 844),
            viewInsets: EdgeInsets.only(bottom: 300),
          ),
          child: Scaffold(body: _testSheet()),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final input = find.byKey(const ValueKey('ai-chat-input'));
    expect(input, findsOneWidget);
    expect(tester.getBottomRight(input).dy, lessThanOrEqualTo(544));
    expect(tester.takeException(), isNull);
  });

  testWidgets('opening an existing chat starts at the latest message',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 480));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final messages = List<AiChatMessage>.generate(
      30,
      (index) => AiChatMessage(
        role: index.isEven ? AiChatRole.user : AiChatRole.assistant,
        content: index == 29 ? '最新一条消息' : '旧消息 $index 的较长内容',
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: _testSheet(initialMessages: messages)),
      ),
    );
    await tester.pump();

    expect(find.text('最新一条消息'), findsOneWidget);
    expect(find.text('旧消息 0 的较长内容'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disabled terminal sharing never reads or sends terminal text',
      (tester) async {
    var terminalReads = 0;
    late Map<String, dynamic> requestBody;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: _testSheet(
            terminalContext: () {
              terminalReads++;
              return 'private terminal output';
            },
            service: AiService(
              client: MockClient((request) async {
                requestBody = jsonDecode(request.body) as Map<String, dynamic>;
                return _chatResponse('已分析');
              }),
            ),
          ),
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('ai-chat-input')),
      '检查状态',
    );
    await tester.tap(find.byKey(const ValueKey('ai-chat-send')));
    await tester.pumpAndSettle();

    expect(terminalReads, 0);
    expect(jsonEncode(requestBody), isNot(contains('private terminal output')));
    expect(find.text('终端输出上传已关闭'), findsOneWidget);
  });

  testWidgets('chat model selector switches the model used by requests',
      (tester) async {
    late Map<String, dynamic> requestBody;
    final changedModels = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: _testSheet(
            settings: const AppSettings(
              aiModel: 'model-a',
              aiModels: ['model-a', 'model-b'],
              aiIncludeTerminalContext: true,
            ),
            service: AiService(
              client: MockClient((request) async {
                requestBody = jsonDecode(request.body) as Map<String, dynamic>;
                return _chatResponse('已切换');
              }),
            ),
            terminalContext: () => 'shared terminal output',
            onModelChanged: (model) async => changedModels.add(model),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('ai-chat-model-selector')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('model-b').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('ai-chat-input')),
      '继续',
    );
    await tester.tap(find.byKey(const ValueKey('ai-chat-send')));
    await tester.pumpAndSettle();

    expect(changedModels, ['model-b']);
    expect(requestBody['model'], 'model-b');
    expect(jsonEncode(requestBody), contains('shared terminal output'));
  });

  testWidgets('reasoning selector sits above the input and updates requests',
      (tester) async {
    late Map<String, dynamic> requestBody;
    final changedEfforts = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: _testSheet(
            settings: const AppSettings(aiReasoningEffort: 'low'),
            service: AiService(
              client: MockClient((request) async {
                requestBody = jsonDecode(request.body) as Map<String, dynamic>;
                return _chatResponse('已调整');
              }),
            ),
            onReasoningEffortChanged: (effort) async {
              changedEfforts.add(effort);
            },
          ),
        ),
      ),
    );

    final selector = find.byKey(
      const ValueKey('ai-chat-reasoning-selector'),
    );
    final input = find.byKey(const ValueKey('ai-chat-input'));
    expect(
        tester.getTopLeft(selector).dy, lessThan(tester.getTopLeft(input).dy));
    await tester.tap(selector);
    await tester.pumpAndSettle();
    await tester.tap(find.text('思考：高').last);
    await tester.pumpAndSettle();
    await tester.enterText(input, '深入分析');
    await tester.tap(find.byKey(const ValueKey('ai-chat-send')));
    await tester.pumpAndSettle();

    expect(changedEfforts, ['high']);
    expect(requestBody['reasoning_effort'], 'high');
  });

  testWidgets('persisted chat history is capped at 30 messages',
      (tester) async {
    var persisted = <AiChatMessage>[];
    final initialMessages = List<AiChatMessage>.generate(
      30,
      (index) => AiChatMessage(
        role: index.isEven ? AiChatRole.user : AiChatRole.assistant,
        content: 'old-$index',
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: _testSheet(
            initialMessages: initialMessages,
            service: AiService(
              client: MockClient((_) async => _chatResponse('new-reply')),
            ),
            onMessagesChanged: (messages) => persisted = messages,
          ),
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('ai-chat-input')),
      'new-request',
    );
    await tester.tap(find.byKey(const ValueKey('ai-chat-send')));
    await tester.pumpAndSettle();

    expect(persisted, hasLength(30));
    expect(persisted.first.content, 'old-2');
    expect(persisted.last.content, 'new-reply');
  });
}

AiChatSheet _testSheet({
  List<AiChatMessage> initialMessages = const [],
  AppSettings settings = const AppSettings(),
  AiService? service,
  String Function()? terminalContext,
  Future<void> Function(String model)? onModelChanged,
  Future<void> Function(String effort)? onReasoningEffortChanged,
  ValueChanged<List<AiChatMessage>>? onMessagesChanged,
}) {
  return AiChatSheet(
    host: HostProfile.create(
      id: 'test',
      label: 'Test',
      hostname: 'test.example.com',
      username: 'root',
      port: 2222,
    ),
    settings: settings,
    apiKey: 'unused',
    service: service ??
        AiService(
          client:
              MockClient((_) async => http.Response('unexpected request', 500)),
        ),
    initialMessages: initialMessages,
    onMessagesChanged: onMessagesChanged ?? (_) {},
    terminalContext: terminalContext ?? () => 'recent terminal output',
    onModelChanged: onModelChanged ?? (_) async {},
    onReasoningEffortChanged: onReasoningEffortChanged ?? (_) async {},
    onCommand: (_, __) async {},
  );
}

http.Response _chatResponse(String message) => http.Response.bytes(
      utf8.encode(jsonEncode({
        'choices': [
          {
            'message': {
              'content': jsonEncode({'message': message}),
            },
          },
        ],
      })),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
