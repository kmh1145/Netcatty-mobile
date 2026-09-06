import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/domain/models/server_stats.dart';
import 'package:netcatty_mobile/infrastructure/ssh/server_monitor_service.dart';
import 'package:netcatty_mobile/infrastructure/ssh/ssh_service.dart';
import 'package:netcatty_mobile/infrastructure/ssh/sftp_service.dart';
import 'package:xterm2/xterm.dart';
import 'package:netcatty_mobile/presentation/widgets/server_monitor_sheet.dart';

void main() {
  test('two tabs of one server share storage while changed endpoints do not',
      () async {
    ActiveTerminalSession session(String id, int port) => ActiveTerminalSession(
        id: id,
        host: HostProfile({
          'id': 'host',
          'hostname': 'example.invalid',
          'port': port,
          'username': 'demo'
        }),
        terminal: Terminal(),
        verifyHostKey: (_, __, ___) async => true,
        keyboardInteractive: null);
    final first = session('one', 22);
    final second = session('two', 22);
    final different = session('three', 2222);
    expect(
        sameTransferStorage(SftpService(first), SftpService(second)), isTrue);
    expect(sameTransferStorage(SftpService(first), SftpService(different)),
        isFalse);
    await first.close();
    await second.close();
    await different.close();
  });
  testWidgets('sheet shows cached readings and expands resource details',
      (tester) async {
    final session = ActiveTerminalSession(
        id: 'cached',
        host: HostProfile({'id': 'cached', 'label': 'Demo'}),
        terminal: Terminal(),
        verifyHostKey: (_, __, ___) async => true,
        keyboardInteractive: null);
    final monitor = SessionMonitor(session, service: _Monitor());
    monitor.stats = ServerMonitorService().parse(
        'CORES=2\nCPU_MODEL=Demo CPU\nCORE_0=100 50\nMEM=1000 500\nSWAP=200 100\nDISK_1=/dev/demo\t1000\t500\t/data\nCONNECTIONS=4\nNET=1073741824 2147483648');
    monitor.history.add(monitor.stats!);
    monitor.stop();
    session.monitor = monitor;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ServerMonitorSheet(session: session))));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('累计：1.0 GB'), findsOneWidget);
    expect(find.text('累计：2.0 GB'), findsOneWidget);
    await tester.tap(find.text('CPU').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final cpuDetails = find.byKey(const ValueKey('monitor-cpu-details'));
    final growingHeight = tester.getSize(cpuDetails).height;
    expect(growingHeight, greaterThan(0));
    await tester.pumpAndSettle();
    final fullHeight = tester.getSize(cpuDetails).height;
    expect(growingHeight, lessThan(fullHeight));
    expect(find.text('Demo CPU'), findsOneWidget);
    await tester.tap(find.text('CPU').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(tester.getSize(cpuDetails).height, inExclusiveRange(0, fullHeight));
    await tester.pumpAndSettle();
    expect(tester.getSize(cpuDetails).height, 0);
    await tester.tap(find.text('内存').first);
    await tester.pumpAndSettle();
    expect(find.text('内存与 Swap'), findsOneWidget);
    await tester.tap(find.text('内存').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('根分区').first);
    await tester.pumpAndSettle();
    expect(find.text('/dev/demo → /data'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    monitor.dispose();
    await session.close();
  });
  test('per-core deltas, memory, partitions and connections are parsed', () {
    final parser = ServerMonitorService();
    parser.parse('CPU=100 80\nCORE_0=100 80\nNET=100 200',
        sampledAt: DateTime(2026));
    final stats = parser.parse(
        'CPU=200 130\nCORE_0=200 130\nNET=400 800\nMEM=1000 600\nMEM_DETAIL=100 400 300\nSWAP=200 50\nDISK_1=/dev/sda1\t1000\t400\t/mount with spaces\nCPU_MODEL=Example CPU\nARCH=aarch64\nCONNECTIONS=42',
        sampledAt: DateTime(2026).add(const Duration(seconds: 3)));
    expect(stats.corePercents['0'], 50);
    expect(stats.networkRxBytesPerSecond, 100);
    expect(stats.networkTxBytesPerSecond, 200);
    expect(stats.networkRxBytesTotal, 400);
    expect(stats.networkTxBytesTotal, 800);
    expect(stats.swapUsedBytes, 50);
    expect(stats.memoryAvailableBytes, 400);
    expect(stats.disks.single.mount, '/mount with spaces');
    expect(stats.disks.single.percent, 40);
    expect(stats.connectionCount, 42);
    expect(stats.cpuModel, 'Example CPU');
    final reset = parser.parse('CORE_0=10 5\nNET=1 2');
    expect(reset.corePercents['0'], 0);
    expect(reset.networkRxBytesTotal, 1);
    expect(reset.networkTxBytesTotal, 2);
    expect(parser.parse('').networkRxBytesTotal, isNull);
  });

  testWidgets(
      'sampler starts immediately, avoids overlapping requests and stops',
      (tester) async {
    final session = ActiveTerminalSession(
        id: 'test',
        host: HostProfile({'id': 'test', 'label': 'test'}),
        terminal: Terminal(),
        verifyHostKey: (_, __, ___) async => true,
        keyboardInteractive: null);
    final service = _Monitor();
    final sampler = SessionMonitor(session, service: service);
    sampler.start();
    await tester.pump();
    expect(service.calls, 1);
    await tester.pump(const Duration(seconds: 9));
    expect(service.calls, 1);
    service.pending.complete(ServerMonitorService().parse('CPU=10 5'));
    await tester.pump();
    expect(sampler.stats, isNotNull);
    expect(sampler.history, hasLength(1));
    sampler.stop();
    await tester.pump(const Duration(seconds: 9));
    expect(service.calls, 1);
    sampler.dispose();
    await session.close();
  });
}

class _Monitor extends ServerMonitorService {
  int calls = 0;
  final pending = Completer<ServerStats>();
  @override
  Future<ServerStats> poll(ActiveTerminalSession session) {
    calls++;
    return pending.future;
  }
}
