import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/domain/models/system_management.dart';
import 'package:netcatty_mobile/infrastructure/ssh/ssh_service.dart';
import 'package:netcatty_mobile/infrastructure/ssh/system_management_service.dart';
import 'package:netcatty_mobile/presentation/widgets/system_management/caddy_manager_panel.dart';
import 'package:xterm2/xterm.dart';

void main() {
  ActiveTerminalSession session() => ActiveTerminalSession(
        id: 'caddy-test',
        host: HostProfile({
          'id': 'caddy-test',
          'hostname': 'example.invalid',
          'username': 'tester',
        }),
        terminal: Terminal(),
        verifyHostKey: (_, __, ___) async => true,
        keyboardInteractive: null,
      );

  testWidgets('shows a dedicated message when Caddy is not installed',
      (tester) async {
    final active = session();
    addTearDown(active.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CaddyManagerPanel(
            session: active,
            service: _FakeCaddyService(installed: false),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text(caddyNotFoundMessage), findsOneWidget);
    final add = tester.widget<IconButton>(
      find.byKey(const ValueKey('caddy-add')),
    );
    expect(add.onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('adds and deletes a managed reverse proxy site', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final active = session();
    addTearDown(active.close);
    final service = _FakeCaddyService(installed: true);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CaddyManagerPanel(session: active, service: service),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('v2.test'), findsOneWidget);
    expect(find.text('还没有由 Netcatty 管理的反向代理站点'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('caddy-add')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('caddy-address')),
      'demo.example.com',
    );
    await tester.enterText(
      find.byKey(const ValueKey('caddy-upstreams')),
      '127.0.0.1:8080\n127.0.0.1:8081',
    );
    await tester.tap(find.byKey(const ValueKey('caddy-save')));
    await tester.pumpAndSettle();

    expect(service.sites, hasLength(1));
    expect(find.text('demo.example.com'), findsOneWidget);
    expect(find.text('127.0.0.1:8080 · 127.0.0.1:8081'), findsOneWidget);
    await tester.tap(find.text('demo.example.com'));
    await tester.pumpAndSettle();
    expect(find.text('编辑反向代理'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除').last);
    await tester.pumpAndSettle();
    expect(find.text('删除反向代理站点？'), findsOneWidget);
    await tester.tap(find.text('删除').last);
    await tester.pumpAndSettle();
    expect(service.sites, isEmpty);
    expect(tester.takeException(), isNull);
  });
}

class _FakeCaddyService extends SystemManagementService {
  _FakeCaddyService({required this.installed});

  final bool installed;
  final sites = <CaddySite>[];

  @override
  Future<CaddyStatus> caddyStatus(ActiveTerminalSession session) async =>
      CaddyStatus(
        installed: installed,
        version: installed ? 'v2.test' : '',
        configPath: '/etc/caddy/Caddyfile',
      );

  @override
  Future<List<CaddySite>> listCaddySites(
    ActiveTerminalSession session,
    CaddyStatus status,
  ) async =>
      List.unmodifiable(sites);

  @override
  Future<void> saveCaddySite(
    ActiveTerminalSession session,
    CaddyStatus status,
    CaddySite site,
  ) async {
    sites.removeWhere((value) => value.id == site.id);
    sites.add(site);
  }

  @override
  Future<void> deleteCaddySite(
    ActiveTerminalSession session,
    CaddyStatus status,
    CaddySite site,
  ) async {
    sites.removeWhere((value) => value.id == site.id);
  }
}
