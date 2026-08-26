import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/domain/models/host.dart';
import 'package:netcatty_mobile/domain/models/server_stats.dart';
import 'package:netcatty_mobile/domain/models/settings.dart';
import 'package:netcatty_mobile/infrastructure/ssh/server_monitor_service.dart';
import 'package:netcatty_mobile/infrastructure/ssh/sftp_service.dart';
import 'package:netcatty_mobile/presentation/theme.dart';

void main() {
  test('desktop theme catalogue exposes 62 light and 62 dark themes', () {
    expect(NetcattyTheme.presets(Brightness.light), hasLength(62));
    expect(NetcattyTheme.presets(Brightness.dark), hasLength(62));
    expect(
      NetcattyTheme.resolve(Brightness.dark, 'tokyo-night').name,
      'Tokyo Night',
    );
    expect(
      NetcattyTheme.build(Brightness.light, 'rose-pine').brightness,
      Brightness.light,
    );
  });

  test('new appearance and server view settings round-trip safely', () {
    final settings = AppSettings.fromJson({
      'themeMode': 'system',
      'uiThemeId': 'catppuccin',
      'serverViewMode': 'tree',
      'terminalSecureKeyboard': true,
      'autoSyncEnabled': true,
      'language': 'en',
    });
    expect(settings.uiThemeId, 'catppuccin');
    expect(settings.serverViewMode, 'tree');
    expect(settings.terminalSecureKeyboard, isTrue);
    expect(settings.autoSyncEnabled, isTrue);
    expect(settings.language, 'en');
    expect(AppSettings.fromJson({'serverViewMode': 'invalid'}).serverViewMode,
        'grid');
    expect(settings.toJson()['serverViewMode'], 'tree');
    expect(settings.toJson()['terminalSecureKeyboard'], isTrue);
    expect(settings.toJson()['autoSyncEnabled'], isTrue);
    expect(const AppSettings().autoSyncEnabled, isFalse);
  });

  test('desktop and detected OS names normalize to bundled icon ids', () {
    expect(normalizeDistroId('Ubuntu 24.04 LTS'), 'ubuntu');
    expect(normalizeDistroId('Red Hat Enterprise Linux'), 'redhat');
    expect(normalizeDistroId('Anolis OS / Alibaba Linux'), 'alinux');
    expect(normalizeDistroId('Darwin'), 'macos');
    expect(normalizeDistroId('unknown unix'), 'linux');

    final host = HostProfile({
      'id': 'server-1',
      'hostname': 'example.com',
      'username': 'root',
      'systemInfo': {
        'platform': 'linux',
        'distro': 'rocky',
        'prettyName': 'Rocky Linux 9',
        'hostname': 'prod-1',
        'kernel': '6.8.0',
        'cores': 8,
      },
    });
    expect(host.distro, 'rocky');
    expect(host.systemInfo?.cores, 8);
  });

  test('monitor parser calculates deltas and resource percentages', () {
    final service = ServerMonitorService();
    final first = service.parse(
      _sample(cpu: '1000 700', network: '10000 4000'),
      sampledAt: DateTime.fromMillisecondsSinceEpoch(1000),
    );
    final second = service.parse(
      _sample(cpu: '1200 800', network: '13000 5000'),
      sampledAt: DateTime.fromMillisecondsSinceEpoch(2000),
    );

    expect(first.system.distro, 'ubuntu');
    expect(second.cpuPercent, closeTo(50, 0.01));
    expect(second.memoryPercent, closeTo(50, 0.01));
    expect(second.diskPercent, closeTo(25, 0.01));
    expect(second.networkRxBytesPerSecond, 3000);
    expect(second.networkTxBytesPerSecond, 1000);
    expect(second.loadAverage, [0.25, 0.5, 0.75]);
  });

  test('remote path joining is root-safe', () {
    expect(joinRemotePath('/', 'file.txt'), '/file.txt');
    expect(joinRemotePath('/var/log', 'app.log'), '/var/log/app.log');
  });
}

String _sample({required String cpu, required String network}) => '''
PLATFORM=Linux
DISTRO=ubuntu
PRETTY=Ubuntu 24.04 LTS
HOST=prod-1
KERNEL=6.8.0
CORES=4
CPU=$cpu
MEM=10000 5000
DISK=20000 5000
NET=$network
UPTIME=86461
LOAD=0.25 0.50 0.75
''';
