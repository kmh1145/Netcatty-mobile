import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/models/server_stats.dart';
import '../localization/localized_widgets.dart';

/// Readings use local sample timestamps, not interpolated or invented speeds.
/// Freeze the displayed timeline during a touch so polling cannot move it away.
class ServerNetworkChart extends StatefulWidget {
  const ServerNetworkChart({super.key, required this.samples});
  final List<ServerStats> samples;

  @override
  State<ServerNetworkChart> createState() => _ServerNetworkChartState();
}

class _ServerNetworkChartState extends State<ServerNetworkChart> {
  int? _pointer;
  double? _fraction;
  List<ServerStats>? _heldSamples;

  void _finish() => setState(() {
        _pointer = null;
        _fraction = null;
        _heldSamples = null;
      });

  @override
  Widget build(BuildContext context) {
    final timeline = _Timeline(_heldSamples ?? widget.samples);
    final colors = Theme.of(context).colorScheme;
    if (timeline.samples.isEmpty) {
      return const SizedBox(height: 160, child: Center(child: LText('暂无详细数据')));
    }
    final selected = _fraction == null ? null : timeline.nearest(_fraction!);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      LayoutBuilder(builder: (context, constraints) {
        final width = constraints.maxWidth;
        void position(Offset point) {
          if (width > 0) _fraction = (point.dx / width).clamp(0, 1);
        }

        final tooltipWidth = math.min(196.0, width);
        final pointX = selected == null ? 0.0 : timeline.x(selected) * width;
        final tooltipLeft =
            (pointX > width / 2 ? pointX - tooltipWidth - 8 : pointX + 8)
                .clamp(0.0, math.max(0.0, width - tooltipWidth))
                .toDouble();
        return Listener(
          key: const ValueKey('network-chart-touch-area'),
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) {
            if (_pointer != null) return;
            setState(() {
              _pointer = event.pointer;
              _heldSamples = List.of(widget.samples);
              position(event.localPosition);
            });
          },
          onPointerMove: (event) {
            if (event.pointer == _pointer) {
              setState(() => position(event.localPosition));
            }
          },
          onPointerUp: (event) {
            if (event.pointer == _pointer) _finish();
          },
          onPointerCancel: (event) {
            if (event.pointer == _pointer) _finish();
          },
          child: GestureDetector(
            // Own horizontal drags; vertical drags still scroll the sheet.
            onHorizontalDragStart: (_) {},
            onHorizontalDragUpdate: (_) {},
            child: SizedBox(
                height: 160,
                child: Stack(children: [
                  Positioned.fill(
                      child: CustomPaint(
                          painter: _NetworkPlot(
                              timeline,
                              selected,
                              colors.primary,
                              colors.tertiary,
                              colors.onSurfaceVariant,
                              colors.outlineVariant))),
                  if (selected != null)
                    Positioned(
                      left: tooltipLeft,
                      top: 4,
                      width: tooltipWidth,
                      child: IgnorePointer(
                          child: Material(
                              key: const ValueKey('network-chart-tooltip'),
                              elevation: 3,
                              color: colors.inverseSurface,
                              borderRadius: BorderRadius.circular(8),
                              child: Padding(
                                  padding: const EdgeInsets.all(8),
                                  child: DefaultTextStyle(
                                      style: TextStyle(
                                          color: colors.onInverseSurface,
                                          fontSize: 12),
                                      child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(_time(selected.sampledAt!),
                                                key: const ValueKey(
                                                    'network-selected-time')),
                                            const SizedBox(height: 3),
                                            _reading(
                                                '接收',
                                                selected
                                                    .networkRxBytesPerSecond,
                                                const ValueKey(
                                                    'network-selected-rx')),
                                            _reading(
                                                '发送',
                                                selected
                                                    .networkTxBytesPerSecond,
                                                const ValueKey(
                                                    'network-selected-tx')),
                                          ]))))),
                    ),
                ])),
          ),
        );
      }),
      const SizedBox(height: 4),
      Row(key: const ValueKey('network-time-axis'), children: [
        for (var i = 0; i < 3; i++)
          Expanded(
            child: Align(
                alignment: i == 0
                    ? Alignment.centerLeft
                    : i == 2
                        ? Alignment.centerRight
                        : Alignment.center,
                child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                        _time(timeline.start.add(Duration(seconds: i * 90))),
                        style: TextStyle(
                            fontSize: 11, color: colors.onSurfaceVariant)))),
          ),
      ]),
    ]);
  }

  Widget _reading(String label, double rate, Key key) => FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          LText(label),
          const SizedBox(width: 8),
          Text('${formatTrafficBytes(rate.round())}/s', key: key),
        ]),
      );
}

class _Timeline {
  _Timeline(List<ServerStats> source) {
    final dated = source.where((s) => s.sampledAt != null).toList();
    end = dated.isEmpty
        ? DateTime.fromMillisecondsSinceEpoch(0)
        : dated.last.sampledAt!;
    start = end.subtract(const Duration(minutes: 3));
    samples = dated
        .where(
            (s) => !s.sampledAt!.isBefore(start) && !s.sampledAt!.isAfter(end))
        .toList()
      ..sort((a, b) => a.sampledAt!.compareTo(b.sampledAt!));
  }
  late final DateTime end;
  late final DateTime start;
  late final List<ServerStats> samples;

  double x(ServerStats sample) =>
      (sample.sampledAt!.difference(start).inMilliseconds / 180000).clamp(0, 1);

  ServerStats nearest(double fraction) => samples.reduce(
      (a, b) => (x(a) - fraction).abs() <= (x(b) - fraction).abs() ? a : b);
}

class _NetworkPlot extends CustomPainter {
  _NetworkPlot(this.timeline, this.selected, this.rxColor, this.txColor,
      this.textColor, this.gridColor);
  final _Timeline timeline;
  final ServerStats? selected;
  final Color rxColor, txColor, textColor, gridColor;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height < 24) return;
    final maximum = timeline.samples.fold<double>(
        1,
        (value, sample) => math.max(
            value,
            math.max(sample.networkRxBytesPerSecond,
                sample.networkTxBytesPerSecond)));
    final chart = Rect.fromLTRB(0, 4, size.width, size.height - 4);
    Offset point(ServerStats s, bool rx) => Offset(
        timeline.x(s) * chart.width,
        chart.bottom -
            (rx ? s.networkRxBytesPerSecond : s.networkTxBytesPerSecond) /
                maximum *
                chart.height);
    for (var i = 0; i < 3; i++) {
      final y = chart.top + chart.height * i / 2;
      canvas.drawLine(
          Offset(0, y), Offset(size.width, y), Paint()..color = gridColor);
      final x = chart.width * i / 2;
      canvas.drawLine(Offset(x, chart.top), Offset(x, chart.bottom),
          Paint()..color = gridColor);
    }
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    if (selected != null) {
      final x = timeline.x(selected!) * chart.width;
      canvas.drawLine(
          Offset(x, chart.top),
          Offset(x, chart.bottom),
          Paint()
            ..color = textColor
            ..strokeWidth = 1);
    }
    for (final rx in [true, false]) {
      final path = Path();
      for (var i = 0; i < timeline.samples.length; i++) {
        final p = point(timeline.samples[i], rx);
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      final color = rx ? rxColor : txColor;
      canvas.drawPath(
          path,
          Paint()
            ..color = color
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2);
      if (timeline.samples.length == 1 || selected != null) {
        canvas.drawCircle(point(selected ?? timeline.samples.single, rx), 3,
            Paint()..color = color);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _NetworkPlot oldDelegate) => true;
}

String _time(DateTime time) {
  final local = time.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
}

String formatTrafficBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  var value = bytes.toDouble();
  var unit = 0;
  const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(1)} ${units[unit]}';
}
