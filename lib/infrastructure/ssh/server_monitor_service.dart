import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../../domain/models/server_stats.dart';
import 'ssh_service.dart';

/// One sampler per SSH session; opening a sheet only subscribes to cached data.
class SessionMonitor extends ChangeNotifier {
  SessionMonitor(this.session, {ServerMonitorService? service})
      : service = service ?? ServerMonitorService();
  final ActiveTerminalSession session;
  final ServerMonitorService service;
  ServerStats? stats;
  Object? error;
  bool polling = false;
  bool _stopped = false;
  Timer? _timer;
  final List<ServerStats> history = [];

  void start() {
    if (_timer != null || _stopped) return;
    unawaited(refresh());
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => refresh());
  }

  Future<void> refresh() async {
    if (_stopped || polling) return;
    if (!session.connected) {
      stop();
      return;
    }
    polling = true;
    try {
      final value = await service.poll(session);
      if (_stopped || !session.connected) return;
      stats = value;
      session.systemInfo = value.system;
      error = null;
      history.add(value);
      if (history.length > 60) history.removeAt(0);
    } catch (e) {
      if (!_stopped) error = e;
    } finally {
      polling = false;
      if (!_stopped) notifyListeners();
    }
  }

  void stop() {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}

class ServerMonitorService {
  int? _previousCpuTotal;
  int? _previousCpuIdle;
  int? _previousRx;
  int? _previousTx;
  DateTime? _previousNetworkAt;
  final _previousCores = <String, List<int>>{};

  Future<ServerSystemInfo> detect(ActiveTerminalSession session) async {
    final client = session.sshClient;
    if (client == null) throw UnsupportedError('性能监控仅支持 SSH 连接');
    final raw = await _execute(client, _systemCommand);
    final values = _keyValues(raw);
    return _system(values);
  }

  Future<ServerStats> poll(ActiveTerminalSession session) async {
    final client = session.sshClient;
    if (client == null) throw UnsupportedError('性能监控仅支持 SSH 连接');
    final raw = await _execute(client, _statsCommand);
    return parse(raw);
  }

  ServerStats parse(String raw, {DateTime? sampledAt}) {
    final values = _keyValues(raw);
    final cpu = _integers(values['CPU']);
    var cpuPercent = double.tryParse(values['CPU_PERCENT'] ?? '') ?? 0.0;
    if (cpu.length >= 2) {
      if (_previousCpuTotal != null && cpu[0] > _previousCpuTotal!) {
        final deltaTotal = cpu[0] - _previousCpuTotal!;
        final deltaIdle = cpu[1] - (_previousCpuIdle ?? cpu[1]);
        cpuPercent = ((deltaTotal - deltaIdle) / deltaTotal * 100)
            .clamp(0, 100)
            .toDouble();
      }
      _previousCpuTotal = cpu[0];
      _previousCpuIdle = cpu[1];
    }
    final memory = _integers(values['MEM']);
    final disk = _integers(values['DISK']);
    final network = _integers(values['NET']);
    final now = sampledAt ?? DateTime.now();
    var rxRate = 0.0;
    var txRate = 0.0;
    if (network.length >= 2 && _previousNetworkAt != null) {
      final seconds = now.difference(_previousNetworkAt!).inMilliseconds / 1000;
      if (seconds > 0) {
        rxRate = ((network[0] - (_previousRx ?? network[0])) / seconds)
            .clamp(0, double.infinity)
            .toDouble();
        txRate = ((network[1] - (_previousTx ?? network[1])) / seconds)
            .clamp(0, double.infinity)
            .toDouble();
      }
    }
    if (network.length >= 2) {
      _previousRx = network[0];
      _previousTx = network[1];
      _previousNetworkAt = now;
    }
    final loads = (values['LOAD'] ?? '')
        .split(RegExp(r'\s+'))
        .map(double.tryParse)
        .whereType<double>()
        .take(3)
        .toList(growable: true);
    while (loads.length < 3) {
      loads.add(0);
    }
    final cores = <String, double>{};
    for (final entry
        in values.entries.where((e) => e.key.startsWith('CORE_'))) {
      final numbers = _integers(entry.value);
      if (numbers.length < 2) continue;
      final previous = _previousCores[entry.key];
      final total = numbers[0] - (previous?[0] ?? numbers[0]);
      final idle = numbers[1] - (previous?[1] ?? numbers[1]);
      cores[entry.key.substring(5)] = total > 0
          ? ((total - idle) / total * 100).clamp(0, 100).toDouble()
          : 0;
      _previousCores[entry.key] = numbers;
    }
    _previousCores.removeWhere((key, _) => !values.containsKey(key));
    final memoryDetail = _integers(values['MEM_DETAIL']);
    final swap = _integers(values['SWAP']);
    final disks = <ServerDiskUsage>[];
    for (final entry
        in values.entries.where((e) => e.key.startsWith('DISK_'))) {
      final parts = entry.value.split('\t');
      if (parts.length != 4) continue;
      final total = int.tryParse(parts[1]);
      final used = int.tryParse(parts[2]);
      if (total == null || used == null) continue;
      disks.add(ServerDiskUsage(parts[0], parts[3], total * 1024, used * 1024));
    }
    return ServerStats(
      cpuModel: values['CPU_MODEL'] ?? '',
      cpuArchitecture: values['ARCH'] ?? '',
      cpuMHz: values['CPU_MHZ'] ?? '',
      corePercents: cores,
      memoryFreeBytes: memoryDetail.isNotEmpty ? memoryDetail[0] : 0,
      memoryAvailableBytes: memoryDetail.length > 1 ? memoryDetail[1] : 0,
      memoryCacheBytes: memoryDetail.length > 2 ? memoryDetail[2] : 0,
      swapTotalBytes: swap.isNotEmpty ? swap[0] : 0,
      swapUsedBytes: swap.length > 1 ? swap[1] : 0,
      disks: disks,
      connectionCount: int.tryParse(values['CONNECTIONS'] ?? ''),
      sampledAt: now,
      system: _system(values),
      cpuPercent: cpuPercent,
      memoryUsedBytes: memory.length > 1 ? memory[1] : 0,
      memoryTotalBytes: memory.isNotEmpty ? memory[0] : 0,
      diskUsedBytes: disk.length > 1 ? disk[1] : 0,
      diskTotalBytes: disk.isNotEmpty ? disk[0] : 0,
      networkRxBytesPerSecond: rxRate,
      networkTxBytesPerSecond: txRate,
      uptimeSeconds: int.tryParse(values['UPTIME'] ?? '') ?? 0,
      loadAverage: loads,
    );
  }

  ServerSystemInfo _system(Map<String, String> values) {
    final platform = (values['PLATFORM'] ?? 'Linux').trim();
    final distroSource = values['DISTRO'] ?? values['PRETTY'] ?? platform;
    return ServerSystemInfo(
      platform: platform.toLowerCase(),
      distro: normalizeDistroId(distroSource),
      prettyName: (values['PRETTY'] ?? distroSource).replaceAll('"', ''),
      hostname: values['HOST'] ?? '',
      kernel: values['KERNEL'] ?? '',
      cores: int.tryParse(values['CORES'] ?? '') ?? 0,
    );
  }

  static Map<String, String> _keyValues(String raw) {
    final result = <String, String>{};
    for (final line in const LineSplitter().convert(raw)) {
      final separator = line.indexOf('=');
      if (separator <= 0) continue;
      result[line.substring(0, separator).trim()] =
          line.substring(separator + 1).trim();
    }
    return result;
  }

  static List<int> _integers(String? value) => (value ?? '')
      .split(RegExp(r'\s+'))
      .map(int.tryParse)
      .whereType<int>()
      .toList(growable: false);

  static Future<String> _execute(SSHClient client, String command) async {
    final process = await client.execute(command);
    final stdout = utf8.decoder.bind(process.stdout).join();
    final stderr = utf8.decoder.bind(process.stderr).join();
    try {
      final values = await Future.wait<String>([
        stdout,
        stderr,
      ]).timeout(const Duration(seconds: 12));
      await process.done.timeout(const Duration(seconds: 2));
      final output = values[0];
      final error = values[1];
      if (process.exitCode != null && process.exitCode != 0 && output.isEmpty) {
        throw StateError(error.isEmpty ? '远程监控命令失败' : error.trim());
      }
      return output;
    } on TimeoutException {
      process.close();
      throw TimeoutException('读取服务器性能信息超时');
    }
  }
}

const _systemCommand = r'''LC_ALL=C sh -c '
platform=$(uname -s 2>/dev/null || echo Linux)
echo "PLATFORM=$platform"
echo "HOST=$(hostname 2>/dev/null)"
echo "KERNEL=$(uname -r 2>/dev/null)"
echo "CORES=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)"
if [ -r /etc/os-release ]; then
  . /etc/os-release
  echo "DISTRO=${ID:-linux}"
  echo "PRETTY=${PRETTY_NAME:-Linux}"
elif [ "$platform" = Darwin ]; then
  echo "DISTRO=macos"
  echo "PRETTY=macOS"
elif [ "$platform" = FreeBSD ]; then
  echo "DISTRO=freebsd"
  echo "PRETTY=FreeBSD"
else
  echo "DISTRO=linux"
  echo "PRETTY=$platform"
fi
 '
''';

const _statsCommand = r'''LC_ALL=C sh -c '
platform=$(uname -s 2>/dev/null || echo Linux)
echo "PLATFORM=$platform"
echo "HOST=$(hostname 2>/dev/null)"
echo "KERNEL=$(uname -r 2>/dev/null)"
echo "CORES=$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)"
if [ -r /etc/os-release ]; then . /etc/os-release; echo "DISTRO=${ID:-linux}"; echo "PRETTY=${PRETTY_NAME:-Linux}"; elif [ "$platform" = Darwin ]; then echo DISTRO=macos; echo PRETTY=macOS; else echo DISTRO=linux; echo "PRETTY=$platform"; fi
if [ -r /proc/stat ]; then
  set -- $(head -1 /proc/stat)
  total=0; idle=0; i=0
  shift
  for n in "$@"; do i=$((i+1)); if [ "$i" -gt 8 ]; then break; fi; total=$((total+n)); if [ "$i" -eq 4 ]; then idle=$n; fi; if [ "$i" -eq 5 ]; then idle=$((idle+n)); fi; done
  echo "CPU=$total $idle"
  awk "/^cpu[0-9]+ / {total=0; for(i=2;i<=9 && i<=NF;i++) total+=\$i; printf \"CORE_%s=%.0f %.0f\\n\",substr(\$1,4),total,\$5+\$6}" /proc/stat
else
  echo "CPU=0 0"
  echo "CPU_PERCENT=$(top -l 1 2>/dev/null | awk "/CPU usage/{gsub(/%/,\"\",\$7); print 100-\$7; exit}")"
fi
if [ -r /proc/meminfo ]; then
  awk "/^MemTotal:/{t=\$2} /^MemFree:/{f=\$2} /^MemAvailable:/{a=\$2;has=1} /^Buffers:/{b=\$2} /^Cached:/{c=\$2} /^SReclaimable:/{r=\$2} /^Shmem:/{s=\$2} /^SwapTotal:/{st=\$2} /^SwapFree:/{sf=\$2} END {cache=b+c+r-s; if(cache<0) cache=0; if(!has) a=f+cache; if(a>t) a=t; printf \"MEM=%.0f %.0f\\nMEM_DETAIL=%.0f %.0f %.0f\\nSWAP=%.0f %.0f\\n\",t*1024,(t-a)*1024,f*1024,a*1024,cache*1024,st*1024,(st-sf)*1024}" /proc/meminfo
else
  mt=$(sysctl -n hw.memsize 2>/dev/null || echo 0); echo "MEM=$mt 0"
fi
set -- $(df -Pk / 2>/dev/null | awk "NR==2 {print \$2,\$3}"); dt=${1:-0}; du=${2:-0}; echo "DISK=$((dt*1024)) $((du*1024))"
df -Pk 2>/dev/null | awk "NR>1 && \$2 ~ /^[0-9]+$/ {m=\$6; for(i=7;i<=NF;i++) m=m \" \" \$i; printf \"DISK_%d=%s\\t%s\\t%s\\t%s\\n\", NR,\$1,\$2,\$3,m}"
echo "ARCH=$(uname -m 2>/dev/null)"
if [ -r /proc/cpuinfo ]; then
  echo "CPU_MODEL=$(grep -m1 -E "^(model name|Hardware|Processor)[[:space:]]*:" /proc/cpuinfo | cut -d: -f2- | sed "s/^[[:space:]]*//")"
  echo "CPU_MHZ=$(grep -m1 "^cpu MHz" /proc/cpuinfo | cut -d: -f2- | tr -d " ")"
fi
if command -v ss >/dev/null 2>&1; then
  count=$(ss -Htn state established 2>/dev/null | wc -l); echo "CONNECTIONS=$count"
elif [ -r /proc/net/tcp ]; then
  awk "FNR>1 && \$4==\"01\" {n++} END {print \"CONNECTIONS=\" n+0}" /proc/net/tcp /proc/net/tcp6 2>/dev/null
fi
if [ -r /proc/net/dev ]; then set -- $(awk -F"[: ]+" "NR>2 {rx+=\$3; tx+=\$11} END {printf \"%.0f %.0f\\n\",rx,tx}" /proc/net/dev); else set -- 0 0; fi; echo "NET=$1 $2"
if [ -r /proc/uptime ]; then echo "UPTIME=$(cut -d. -f1 /proc/uptime)"; else echo "UPTIME=0"; fi
if [ -r /proc/loadavg ]; then set -- $(cat /proc/loadavg); echo "LOAD=$1 $2 $3"; else set -- $(sysctl -n vm.loadavg 2>/dev/null | tr -d "{}"); echo "LOAD=${1:-0} ${2:-0} ${3:-0}"; fi
 '
''';
