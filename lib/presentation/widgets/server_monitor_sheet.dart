import 'package:flutter/material.dart';
import 'package:netcatty_mobile/presentation/localization/localized_widgets.dart';

import '../../domain/models/server_stats.dart';
import '../../infrastructure/ssh/server_monitor_service.dart';
import '../../infrastructure/ssh/ssh_service.dart';
import 'host_system_icon.dart';
import 'server_network_chart.dart';

class ServerMonitorSheet extends StatefulWidget {
  const ServerMonitorSheet({super.key, required this.session});

  final ActiveTerminalSession session;

  @override
  State<ServerMonitorSheet> createState() => _ServerMonitorSheetState();
}

class _ServerMonitorSheetState extends State<ServerMonitorSheet> {
  late SessionMonitor monitor;
  final expanded = <String>{};
  ServerStats? get stats => monitor.stats;
  Object? get error => monitor.error;
  bool get polling => monitor.polling;

  @override
  void initState() {
    super.initState();
    monitor = widget.session.monitor ??= SessionMonitor(widget.session);
    monitor.addListener(_updated);
    monitor.start();
  }

  @override
  void dispose() {
    monitor.removeListener(_updated);
    super.dispose();
  }

  void _updated() {
    if (mounted) setState(() {});
  }

  Future<void> _poll() => monitor.refresh();
  void _toggle(String key) => setState(() {
        if (!expanded.remove(key)) expanded.add(key);
      });

  @override
  Widget build(BuildContext context) {
    final value = stats;
    final system = value?.system ?? widget.session.systemInfo;
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.82,
      minChildSize: 0.45,
      maxChildSize: 0.96,
      builder: (context, controller) => CustomScrollView(
        controller: controller,
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
              child: Row(
                children: [
                  HostSystemIcon(
                    host: widget.session.host,
                    systemInfo: system,
                    size: 52,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        LText(
                          system?.hostname.isNotEmpty == true
                              ? system!.hostname
                              : widget.session.host.label,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        LText(
                          system == null
                              ? '正在读取系统信息…'
                              : '${system.prettyName} · ${system.kernel}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: localized('刷新'),
                    onPressed: polling ? null : _poll,
                    icon: const Icon(Icons.refresh),
                  ),
                  IconButton(
                    tooltip: localized('关闭'),
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
          ),
          if (value == null && error == null)
            const SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: CircularProgressIndicator()),
            )
          else if (value == null)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.monitor_heart_outlined, size: 48),
                      const SizedBox(height: 12),
                      LText('无法读取性能数据\n$error', textAlign: TextAlign.center),
                      const SizedBox(height: 12),
                      FilledButton(onPressed: _poll, child: const LText('重试')),
                    ],
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 24),
              sliver: SliverList.list(
                children: [
                  GridView.count(
                    crossAxisCount:
                        MediaQuery.sizeOf(context).width > 620 ? 4 : 2,
                    mainAxisSpacing: 10,
                    crossAxisSpacing: 10,
                    childAspectRatio: 1.55,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    children: [
                      _GaugeCard(
                        icon: Icons.speed,
                        onTap: () => _toggle('cpu'),
                        label: 'CPU',
                        percent: value.cpuPercent,
                        detail: '${value.system.cores} 核',
                      ),
                      _GaugeCard(
                        icon: Icons.memory,
                        onTap: () => _toggle('memory'),
                        label: '内存',
                        percent: value.memoryPercent,
                        detail:
                            '${_bytes(value.memoryUsedBytes)} / ${_bytes(value.memoryTotalBytes)}',
                      ),
                      _GaugeCard(
                        icon: Icons.storage_outlined,
                        onTap: () => _toggle('disk'),
                        label: '根分区',
                        percent: value.diskPercent,
                        detail:
                            '${_bytes(value.diskUsedBytes)} / ${_bytes(value.diskTotalBytes)}',
                      ),
                      _GaugeCard(
                        icon: Icons.schedule,
                        label: '运行时间',
                        percent: 0,
                        detail: _uptime(value.uptimeSeconds),
                        showProgress: false,
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _animatedDetail(
                      'cpu',
                      _detailCard('CPU', [
                        LText(
                            value.cpuModel.isEmpty ? '暂无详细数据' : value.cpuModel),
                        LText(
                            '${value.cpuArchitecture} · ${value.system.cores} cores · ${value.cpuMHz} MHz'),
                        for (final core in value.corePercents.entries)
                          _usage('CPU ${core.key}', core.value,
                              '${core.value.toStringAsFixed(1)}%'),
                      ])),
                  _animatedDetail(
                      'memory',
                      _detailCard('内存与 Swap', [
                        _usage('内存', value.memoryPercent,
                            '${_bytes(value.memoryUsedBytes)} / ${_bytes(value.memoryTotalBytes)}'),
                        LText('可用：${_bytes(value.memoryAvailableBytes)}'),
                        LText('空闲：${_bytes(value.memoryFreeBytes)}'),
                        LText('缓存：${_bytes(value.memoryCacheBytes)}'),
                        _usage(
                            'Swap',
                            value.swapTotalBytes <= 0
                                ? 0
                                : value.swapUsedBytes /
                                    value.swapTotalBytes *
                                    100,
                            '${_bytes(value.swapUsedBytes)} / ${_bytes(value.swapTotalBytes)}'),
                      ])),
                  _animatedDetail(
                      'disk',
                      _detailCard('分区与磁盘', [
                        if (value.disks.isEmpty) const LText('暂无详细数据'),
                        for (final disk in value.disks)
                          _usage('${disk.device} → ${disk.mount}', disk.percent,
                              '${_bytes(disk.usedBytes)} / ${_bytes(disk.totalBytes)}'),
                      ])),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const LText(
                            '网络吞吐',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 12),
                          Row(
                            children: [
                              Expanded(
                                child: _Metric(
                                  icon: Icons.south,
                                  label: '接收',
                                  value:
                                      '${_bytes(value.networkRxBytesPerSecond.round())}/s',
                                  total: value.networkRxBytesTotal,
                                ),
                              ),
                              Expanded(
                                child: _Metric(
                                  icon: Icons.north,
                                  label: '发送',
                                  value:
                                      '${_bytes(value.networkTxBytesPerSecond.round())}/s',
                                  total: value.networkTxBytesTotal,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          LText(
                              '当前 TCP 连接数：${value.connectionCount?.toString() ?? '—'}'),
                          const SizedBox(height: 8),
                          ServerNetworkChart(samples: List.of(monitor.history)),
                          Row(children: [
                            Icon(Icons.remove,
                                color: Theme.of(context).colorScheme.primary),
                            const LText('接收'),
                            const SizedBox(width: 16),
                            Icon(Icons.remove,
                                color: Theme.of(context).colorScheme.tertiary),
                            const LText('发送'),
                          ]),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.timeline),
                      title: const LText('系统负载（1 / 5 / 15 分钟）'),
                      subtitle: LText(value.loadAverage
                          .map((item) => item.toStringAsFixed(2))
                          .join('  /  ')),
                      trailing: error == null
                          ? const Icon(Icons.circle,
                              color: Colors.green, size: 10)
                          : Tooltip(
                              message: '$error',
                              child: const Icon(Icons.warning_amber),
                            ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _animatedDetail(String id, Widget child) =>
      TweenAnimationBuilder<double>(
        key: ValueKey('monitor-$id-details'),
        tween: Tween(begin: 0, end: expanded.contains(id) ? 1 : 0),
        duration: MediaQuery.disableAnimationsOf(context)
            ? Duration.zero
            : const Duration(milliseconds: 240),
        curve: Curves.easeInOutCubic,
        builder: (context, factor, _) => ClipRect(
            child: Align(
                alignment: Alignment.topCenter,
                heightFactor: factor,
                child: IgnorePointer(
                    ignoring: !expanded.contains(id),
                    child: Opacity(
                        opacity: factor,
                        child:
                            factor == 0 ? const SizedBox.shrink() : child)))),
      );
}

class _GaugeCard extends StatelessWidget {
  const _GaugeCard({
    required this.icon,
    required this.label,
    required this.percent,
    required this.detail,
    this.showProgress = true,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final double percent;
  final String detail;
  final bool showProgress;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
      onTap: onTap,
      child: Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, size: 18),
                  const SizedBox(width: 6),
                  LText(label,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  const Spacer(),
                  if (showProgress)
                    LText('${percent.clamp(0, 100).toStringAsFixed(1)}%'),
                ],
              ),
              const Spacer(),
              LText(
                detail,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (showProgress) ...[
                const SizedBox(height: 7),
                LinearProgressIndicator(value: percent.clamp(0, 100) / 100),
              ],
            ],
          ),
        ),
      ));
}

Widget _detailCard(String title, List<Widget> children) => Card(
    child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          LText(title, style: const TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ...children
        ])));

Widget _usage(String label, double percent, String detail) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      LText(label),
      LText(detail),
      const SizedBox(height: 4),
      LinearProgressIndicator(value: percent.clamp(0, 100) / 100)
    ]));

class _Metric extends StatelessWidget {
  const _Metric(
      {required this.icon,
      required this.label,
      required this.value,
      this.total});

  final IconData icon;
  final String label;
  final String value;
  final int? total;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          CircleAvatar(radius: 18, child: Icon(icon, size: 18)),
          const SizedBox(width: 9),
          Expanded(
              child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LText(label, style: Theme.of(context).textTheme.bodySmall),
              FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(value,
                      style: const TextStyle(fontWeight: FontWeight.w600))),
              FittedBox(
                  fit: BoxFit.scaleDown,
                  child: LText(
                      '累计：${total == null ? '—' : formatTrafficBytes(total!)}',
                      style: Theme.of(context).textTheme.bodySmall)),
            ],
          )),
        ],
      );
}

String _bytes(int value) {
  if (value < 1024) return '$value B';
  if (value < 1024 * 1024) return '${(value / 1024).toStringAsFixed(1)} KB';
  if (value < 1024 * 1024 * 1024) {
    return '${(value / 1024 / 1024).toStringAsFixed(1)} MB';
  }
  return '${(value / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
}

String _uptime(int seconds) {
  final days = seconds ~/ 86400;
  final hours = (seconds % 86400) ~/ 3600;
  final minutes = (seconds % 3600) ~/ 60;
  if (days > 0) return '$days 天 $hours 小时';
  return '$hours 小时 $minutes 分钟';
}
