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
}

AiChatSheet _testSheet({List<AiChatMessage> initialMessages = const []}) {
  return AiChatSheet(
    host: HostProfile.create(
      id: 'test',
      label: 'Test',
      hostname: 'test.example.com',
      username: 'root',
      port: 2222,
    ),
    settings: const AppSettings(),
    apiKey: 'unused',
    service: AiService(
      client: MockClient((_) async => http.Response('unexpected request', 500)),
    ),
    initialMessages: initialMessages,
    onMessagesChanged: (_) {},
    terminalContext: () => 'recent terminal output',
    onCommand: (_, __) async {},
  );
}
