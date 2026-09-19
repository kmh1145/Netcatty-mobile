import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/domain/models/settings.dart';
import 'package:netcatty_mobile/infrastructure/ai/ai_service.dart';
import 'package:netcatty_mobile/infrastructure/ai/ai_workspace.dart';
import 'package:netcatty_mobile/presentation/widgets/ai_chat_sheet.dart';

void main() {
  testWidgets('preview shows only filtered terminal content and saves edits',
      (tester) async {
    String? sent;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: _testSheet(
      settings: const AppSettings(aiIncludeTerminalContext: true),
      initialSummary: 'old-summary',
      initialMessages: const [
        AiChatMessage(role: AiChatRole.user, content: 'old-history')
      ],
      terminalContext: () => 'terminal-output token=secret123',
      service: AiService(client: MockClient((r) async {
        sent = r.body;
        return _chatResponse('ok');
      })),
    ))));
    await tester.enterText(
        find.byKey(const ValueKey('ai-chat-input')), 'new-question');
    await tester.tap(find.byTooltip('服务商与预览'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('预览 / 编辑发送内容'));
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('ai-terminal-preview'));
    final value = tester.widget<TextField>(field).controller!.text;
    expect(value, contains('terminal-output'));
    expect(value, isNot(contains('secret123')));
    final dialogText = tester
        .widgetList<Text>(find.descendant(
            of: find.byType(AlertDialog), matching: find.byType(Text)))
        .map((w) => w.data ?? '')
        .join('\n');
    for (final hidden in [
      'old-history',
      'old-summary',
      'new-question',
      'test.example.com'
    ]) {
      expect(dialogText, isNot(contains(hidden)));
    }
    await tester.enterText(field, 'edited-terminal');
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('ai-chat-send')));
    await tester.pumpAndSettle();
    expect(sent, contains('edited-terminal'));
    expect(sent, isNot(contains('terminal-output')));
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('disabled preview does not read terminal text', (tester) async {
    var reads = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: _testSheet(
      terminalContext: () {
        reads++;
        return 'private';
      },
    ))));
    await tester.tap(find.byTooltip('服务商与预览'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('预览 / 编辑发送内容'));
    await tester.pumpAndSettle();
    expect(reads, 0);
    expect(find.byKey(const ValueKey('ai-terminal-preview')), findsNothing);
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 1));
  });

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets('chat selection uses built-in copy menu on $platform',
        (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));
      await tester.pumpWidget(MaterialApp(
          theme: ThemeData(platform: platform),
          home: Scaffold(
              body: _testSheet(
            initialMessages: const [
              AiChatMessage(
                  role: AiChatRole.assistant,
                  content: 'Selectable reply',
                  command: 'pwd')
            ],
          ))));
      await tester.longPress(find.text('Selectable reply'));
      await tester.pumpAndSettle();
      expect(find.text('Copy'), findsOneWidget);
      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();
      expect(copied, isNotEmpty);
      expect('Selectable reply', contains(copied!));
      expect(find.byKey(const ValueKey('ai-command-copy')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets(
      'upload selector shares the model row on a narrow screen and persists',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final changes = <bool>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: _testSheet(
      onTerminalContextChanged: (v) async => changes.add(v),
    ))));
    final upload = find.byKey(const ValueKey('ai-chat-upload-selector'));
    final model = find.byKey(const ValueKey('ai-chat-model-selector'));
    final reasoning = find.byKey(const ValueKey('ai-chat-reasoning-selector'));
    expect(tester.getTopLeft(upload).dy, tester.getTopLeft(model).dy);
    expect(tester.getTopLeft(upload).dy, tester.getTopLeft(reasoning).dy);
    expect(tester.getBottomRight(upload).dx, lessThanOrEqualTo(320));
    await tester.tap(upload);
    await tester.pumpAndSettle();
    await tester.tap(find.text('开启终端输出上传'));
    await tester.pumpAndSettle();
    expect(changes, [true]);
    expect(find.text('上传：开'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'execution uses current terminal only after explicit confirmation',
      (tester) async {
    var requests = 0;
    final commands = <(String, bool)>[];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: _testSheet(
      initialMessages: const [
        AiChatMessage(
            role: AiChatRole.assistant, content: 'check', command: 'pwd')
      ],
      onCommand: (command, execute) async => commands.add((command, execute)),
      service: AiService(client: MockClient((_) async {
        requests++;
        return _chatResponse('done');
      })),
    ))));
    await tester.tap(find.byKey(const ValueKey('ai-command-execute')));
    await tester.pumpAndSettle();
    expect(commands, isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(commands, isEmpty);
    await tester.tap(find.byKey(const ValueKey('ai-command-execute')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '执行').last);
    await tester.pumpAndSettle();
    expect(commands, [('pwd', true)]);
    expect(requests, 0);
  });

  testWidgets(
      'terminal analysis requires snapshot approval even with upload off',
      (tester) async {
    String? sent;
    var reads = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: _testSheet(
      terminalContext: () {
        reads++;
        return 'token=supersecret';
      },
      service: AiService(client: MockClient((r) async {
        sent = r.body;
        return _chatResponse('analysis');
      })),
    ))));
    await tester.tap(find.byTooltip('服务商与预览'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('读取终端并分析'));
    await tester.pumpAndSettle();
    expect(reads, 1);
    expect(sent, isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(sent, isNull);
    await tester.tap(find.byTooltip('服务商与预览'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('读取终端并分析'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('发送并分析'));
    await tester.pumpAndSettle();
    expect(reads, 2);
    expect(sent, contains('terminal snapshot'));
    expect(sent, isNot(contains('supersecret')));
    expect(find.text('analysis'), findsOneWidget);
  });
  testWidgets('summary failure does not discard existing conversation',
      (tester) async {
    var changes = 0;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: _testSheet(
      initialMessages: List.generate(
          30, (i) => AiChatMessage(role: AiChatRole.user, content: 'old-$i')),
      onMessagesChanged: (_) => changes++,
      service:
          AiService(client: MockClient((_) async => http.Response('', 500))),
    ))));
    await tester.enterText(
        find.byKey(const ValueKey('ai-chat-input')), 'continue');
    await tester.tap(find.byKey(const ValueKey('ai-chat-send')));
    await tester.pumpAndSettle();
    expect(changes, 0);
    expect(find.textContaining('AI 请求失败'), findsOneWidget);
    expect(find.text('continue'), findsOneWidget);
  });
  testWidgets('selected local provider controls endpoint model and parameters',
      (tester) async {
    late http.Request captured;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: _testSheet(
      profiles: const [
        AiProviderProfile(
            id: 'local',
            name: 'Local',
            endpoint: 'http://localhost:1234/v1',
            models: ['local-model'],
            reasoning: false)
      ],
      initialProfileId: 'local',
      settings: const AppSettings(aiReasoningEffort: 'high'),
      service: AiService(client: MockClient((r) async {
        captured = r;
        return _chatResponse('ok');
      })),
    ))));
    await tester.enterText(
        find.byKey(const ValueKey('ai-chat-input')), 'hello');
    await tester.tap(find.byKey(const ValueKey('ai-chat-send')));
    await tester.pumpAndSettle();
    expect(captured.url.host, 'localhost');
    expect(captured.headers.containsKey('authorization'), false);
    final payload = jsonDecode(captured.body) as Map;
    expect(payload['model'], 'local-model');
    expect(payload.containsKey('reasoning_effort'), false);
  });
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
    expect(find.text('上传：关'), findsOneWidget);
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

  testWidgets('older chat history is summarized before the next request',
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

    expect(persisted, hasLength(12));
    expect(persisted.first.content, 'old-20');
    expect(persisted.last.content, 'new-reply');
  });
}

AiChatSheet _testSheet({
  String initialSummary = '',
  List<AiChatMessage> initialMessages = const [],
  AppSettings settings = const AppSettings(),
  AiService? service,
  String Function()? terminalContext,
  Future<void> Function(String model)? onModelChanged,
  Future<void> Function(String effort)? onReasoningEffortChanged,
  ValueChanged<List<AiChatMessage>>? onMessagesChanged,
  List<AiProviderProfile> profiles = const [],
  String? initialProfileId,
  Future<void> Function(String, bool)? onCommand,
  Future<void> Function(bool)? onTerminalContextChanged,
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
    profiles: profiles,
    initialProfileId: initialProfileId,
    onTerminalContextChanged: onTerminalContextChanged,
    apiKey: 'unused',
    service: service ??
        AiService(
          client:
              MockClient((_) async => http.Response('unexpected request', 500)),
        ),
    initialMessages: initialMessages,
    initialSummary: initialSummary,
    onMessagesChanged: onMessagesChanged ?? (_) {},
    terminalContext: terminalContext ?? () => 'recent terminal output',
    onModelChanged: onModelChanged ?? (_) async {},
    onReasoningEffortChanged: onReasoningEffortChanged ?? (_) async {},
    onCommand: onCommand ?? (_, __) async {},
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
