import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/domain/models/server_stats.dart';
import 'package:netcatty_mobile/infrastructure/ssh/server_monitor_service.dart';
import 'package:netcatty_mobile/presentation/widgets/server_network_chart.dart';

void main() {
  final start = DateTime(2026, 9, 6, 12);
  List<ServerStats> readings() {
    final parser = ServerMonitorService();
    return [
      parser.parse('NET=0 0', sampledAt: start),
      parser.parse('NET=92160 184320',
          sampledAt: start.add(const Duration(seconds: 90))),
      parser.parse('NET=276480 552960',
          sampledAt: start.add(const Duration(minutes: 3))),
    ];
  }

  Widget app(List<ServerStats> data, {double width = 320}) => MaterialApp(
      home: Scaffold(
          body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                  width: width, child: ServerNetworkChart(samples: data)))));

  test('traffic totals format large counters without long GB strings', () {
    expect(formatTrafficBytes(0), '0 B');
    expect(formatTrafficBytes(1024), '1.0 KB');
    expect(formatTrafficBytes(1024 * 1024 * 1024 * 1024), '1.0 TB');
  });

  testWidgets('axis, immediate touch, drag, frozen samples and release',
      (tester) async {
    final samples = readings();
    await tester.pumpWidget(app(samples));
    expect(find.text('12:00:00'), findsOneWidget);
    expect(find.text('12:01:30'), findsOneWidget);
    expect(find.text('12:03:00'), findsOneWidget);
    final rect =
        tester.getRect(find.byKey(const ValueKey('network-chart-touch-area')));
    final gesture = await tester.startGesture(rect.center);
    await tester.pump();
    expect(find.byKey(const ValueKey('network-chart-tooltip')), findsOneWidget);
    expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('network-selected-time')))
            .data,
        '12:01:30');
    expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('network-selected-rx')))
            .data,
        '1.0 KB/s');
    expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('network-selected-tx')))
            .data,
        '2.0 KB/s');
    await gesture.moveTo(Offset(rect.right - 1, rect.center.dy));
    await tester.pump();
    expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('network-selected-time')))
            .data,
        '12:03:00');
    expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('network-selected-rx')))
            .data,
        '2.0 KB/s');
    final newer = ServerMonitorService().parse('NET=500000 800000',
        sampledAt: start.add(const Duration(minutes: 4)));
    await tester.pumpWidget(app([...samples, newer]));
    expect(find.text('12:04:00'), findsNothing);
    expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('network-selected-time')))
            .data,
        '12:03:00');
    await gesture.up();
    await tester.pump();
    expect(find.byKey(const ValueKey('network-chart-tooltip')), findsNothing);
    expect(find.text('12:04:00'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('single sample and cancelled touch work on a narrow chart',
      (tester) async {
    await tester.pumpWidget(app([readings().last], width: 220));
    final rect =
        tester.getRect(find.byKey(const ValueKey('network-chart-touch-area')));
    final gesture =
        await tester.startGesture(Offset(rect.left + 1, rect.center.dy));
    await tester.pump();
    final tooltip =
        tester.getRect(find.byKey(const ValueKey('network-chart-tooltip')));
    expect(tooltip.left, greaterThanOrEqualTo(rect.left));
    expect(tooltip.right, lessThanOrEqualTo(rect.right));
    expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('network-selected-time')))
            .data,
        '12:03:00');
    await gesture.cancel();
    await tester.pump();
    expect(find.byKey(const ValueKey('network-chart-tooltip')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(app([]));
    expect(find.text('暂无详细数据'), findsOneWidget);
  });
}
