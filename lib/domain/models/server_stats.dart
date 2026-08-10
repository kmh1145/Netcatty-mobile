class ServerSystemInfo {
  const ServerSystemInfo({
    required this.platform,
    required this.distro,
    required this.prettyName,
    required this.hostname,
    required this.kernel,
    required this.cores,
  });

  factory ServerSystemInfo.fromJson(Map<String, dynamic> json) =>
      ServerSystemInfo(
        platform: json['platform']?.toString() ?? 'linux',
        distro: normalizeDistroId(
          json['distro']?.toString() ?? json['platform']?.toString() ?? 'linux',
        ),
        prettyName: json['prettyName']?.toString() ?? 'Linux',
        hostname: json['hostname']?.toString() ?? '',
        kernel: json['kernel']?.toString() ?? '',
        cores: (json['cores'] as num?)?.toInt() ?? 0,
      );

  final String platform;
  final String distro;
  final String prettyName;
  final String hostname;
  final String kernel;
  final int cores;

  Map<String, dynamic> toJson() => {
        'platform': platform,
        'distro': distro,
        'prettyName': prettyName,
        'hostname': hostname,
        'kernel': kernel,
        'cores': cores,
        'detectedAt': DateTime.now().millisecondsSinceEpoch,
      };
}

class ServerStats {
  const ServerStats({
    required this.system,
    required this.cpuPercent,
    required this.memoryUsedBytes,
    required this.memoryTotalBytes,
    required this.diskUsedBytes,
    required this.diskTotalBytes,
    required this.networkRxBytesPerSecond,
    required this.networkTxBytesPerSecond,
    required this.uptimeSeconds,
    required this.loadAverage,
  });

  final ServerSystemInfo system;
  final double cpuPercent;
  final int memoryUsedBytes;
  final int memoryTotalBytes;
  final int diskUsedBytes;
  final int diskTotalBytes;
  final double networkRxBytesPerSecond;
  final double networkTxBytesPerSecond;
  final int uptimeSeconds;
  final List<double> loadAverage;

  double get memoryPercent =>
      memoryTotalBytes <= 0 ? 0 : memoryUsedBytes / memoryTotalBytes * 100;
  double get diskPercent =>
      diskTotalBytes <= 0 ? 0 : diskUsedBytes / diskTotalBytes * 100;
}

String normalizeDistroId(String value) {
  final normalized = value.toLowerCase().replaceAll(RegExp(r'[_\s]+'), '-');
  if (normalized.contains('ubuntu')) return 'ubuntu';
  if (normalized.contains('debian')) return 'debian';
  if (normalized.contains('almalinux')) return 'almalinux';
  if (normalized.contains('rocky')) return 'rocky';
  if (normalized.contains('centos')) return 'centos';
  if (normalized.contains('fedora')) return 'fedora';
  if (normalized.contains('red-hat') || normalized.contains('rhel')) {
    return 'redhat';
  }
  if (normalized.contains('arch')) return 'arch';
  if (normalized.contains('alpine')) return 'alpine';
  if (normalized.contains('amazon')) return 'amazon';
  if (normalized.contains('opensuse') || normalized.contains('suse')) {
    return 'opensuse';
  }
  if (normalized.contains('oracle')) return 'oracle';
  if (normalized.contains('kali')) return 'kali';
  if (normalized.contains('alinux') || normalized.contains('anolis')) {
    return 'alinux';
  }
  if (normalized.contains('openeuler') || normalized.contains('open-euler')) {
    return 'openeuler';
  }
  if (normalized.contains('darwin') || normalized.contains('macos')) {
    return 'macos';
  }
  if (normalized.contains('freebsd')) return 'freebsd';
  if (normalized.contains('windows')) return 'windows';
  for (final vendor in const [
    'cisco',
    'juniper',
    'huawei',
    'h3c',
    'hpe',
    'mikrotik',
    'fortinet',
    'paloalto',
    'zyxel',
  ]) {
    if (normalized.contains(vendor)) return vendor;
  }
  return 'linux';
}
