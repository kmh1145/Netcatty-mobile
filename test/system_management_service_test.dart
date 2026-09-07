import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/domain/models/system_management.dart';
import 'package:netcatty_mobile/infrastructure/ssh/system_management_service.dart';

void main() {
  late SystemManagementService service;

  setUp(() => service = SystemManagementService());

  test('parses canonical process output with resource details', () {
    const output = '''
  731     1 redis    Ssl   12.5  3.4  40960 162000  1-02:03:04 redis-server redis-server *:6379
 2048   731 app      R      8.0  1.2  12288  64000       12:31 python python worker.py --queue high
''';

    final processes = service.parseProcesses(output);

    expect(processes, hasLength(2));
    expect(processes.first.pid, 731);
    expect(processes.first.ppid, 1);
    expect(processes.first.user, 'redis');
    expect(processes.first.cpuPercent, 12.5);
    expect(processes.first.rssKb, 40960);
    expect(processes.first.name, 'redis-server');
    expect(processes.first.command, 'redis-server *:6379');
    expect(processes.last.isRunning, isTrue);
  });

  test('falls back to portable BusyBox process output', () {
    const output = '''
PID   USER     TIME  COMMAND
1     root     0:01  /sbin/init
25    admin    1:12  top -b
''';

    final processes = service.parseProcesses(output);

    expect(processes, hasLength(2));
    expect(processes.last.pid, 25);
    expect(processes.last.user, 'admin');
    expect(processes.last.elapsed, '1:12');
    expect(processes.first.name, 'init');
    expect(processes.last.name, 'top');
    expect(processes.last.command, 'top -b');
  });

  test('parses Docker containers and derives state from JSON lines', () {
    const output = '''
{"ID":"0123456789abcdef","Names":"web","Image":"nginx:latest","Status":"Up 3 hours","State":"running","Ports":"0.0.0.0:80->80/tcp","CreatedAt":"2026-08-12","Labels":"com.docker.compose.project=site,com.docker.compose.service=web,com.docker.compose.project.config_files=/srv/site/compose.yml,/srv/site/compose.prod.yml,owner=ops"}
{"ID":"abcdef0123456789","Names":"cache","Image":"redis:7","Status":"Up 2 hours (Paused)","State":"paused","Ports":"","CreatedAt":"2026-08-12"}
{"ID":"ffeeddccbbaa9988","Names":"db","Image":"postgres:17","Status":"Exited (0) 1 hour ago","State":"exited","Ports":"","CreatedAt":"2026-08-11"}
''';

    final containers = service.parseDockerContainers(output);

    expect(containers, hasLength(3));
    expect(containers[0].state, DockerContainerState.running);
    expect(containers[1].state, DockerContainerState.paused);
    expect(containers[2].state, DockerContainerState.stopped);
    expect(containers[0].shortId, '0123456789ab');
    expect(containers[0].composeProject, 'site');
    expect(containers[0].composeService, 'web');
    expect(
      containers[0].labels['com.docker.compose.project.config_files'],
      '/srv/site/compose.yml,/srv/site/compose.prod.yml',
    );
  });

  test('parses Docker image JSON lines', () {
    const output = '''
{"ID":"sha256:0123456789abcdef","Repository":"postgres","Tag":"17","Digest":"sha256:abc","Size":"438MB","CreatedAt":"2026-08-10"}
''';

    final images = service.parseDockerImages(output);

    expect(images.single.name, 'postgres:17');
    expect(images.single.shortId, '0123456789ab');
    expect(images.single.size, '438MB');
  });

  test('parses Compose v2 project JSON and status counts', () {
    const output = '''
[{"Name":"site","Status":"running(2), exited(1)","ConfigFiles":"/srv/site/compose.yml,/srv/site/compose.prod.yml"}]
''';

    final projects = service.parseDockerComposeProjects(output);

    expect(projects, hasLength(1));
    expect(projects.single.name, 'site');
    expect(projects.single.runningCount, 2);
    expect(projects.single.stoppedCount, 1);
    expect(projects.single.containerCount, 3);
    expect(projects.single.workingDirectory, '/srv/site');
    expect(projects.single.configFiles, [
      '/srv/site/compose.yml',
      '/srv/site/compose.prod.yml',
    ]);
  });

  test('reconstructs Compose projects from container labels', () {
    final containers = service.parseDockerContainers('''
{"ID":"1","Names":"site-web-1","Image":"nginx","Status":"Up","State":"running","Ports":"","CreatedAt":"","Labels":"com.docker.compose.project=site,com.docker.compose.service=web,com.docker.compose.project.working_dir=/srv/site,com.docker.compose.project.config_files=/srv/site/compose.yml"}
{"ID":"2","Names":"site-db-1","Image":"postgres","Status":"Exited","State":"exited","Ports":"","CreatedAt":"","Labels":"com.docker.compose.project=site,com.docker.compose.service=db,com.docker.compose.project.working_dir=/srv/site,com.docker.compose.project.config_files=/srv/site/compose.yml"}
''');

    final projects = service.composeProjectsFromContainers(containers);

    expect(projects, hasLength(1));
    expect(projects.single.name, 'site');
    expect(projects.single.runningCount, 1);
    expect(projects.single.stoppedCount, 1);
    expect(projects.single.status, 'running(1), exited(1)');
    expect(projects.single.workingDirectory, '/srv/site');
  });

  test('parses tmux formatted session list', () {
    const output =
        'work\t3\t1\t1786450000\t1786450300\tdev\nops\t1\t0\t1786440000\t1786440100\t\n';

    final sessions = service.parseTmuxSessions(output);

    expect(sessions, hasLength(2));
    expect(sessions.first.name, 'work');
    expect(sessions.first.windowCount, 3);
    expect(sessions.first.attachedClients, 1);
    expect(sessions.first.group, 'dev');
    expect(sessions.last.attachedClients, 0);
  });

  test('parses systemd services with state and startup policy', () {
    const output = '''
nginx.service loaded active running A high performance web server
failed.service loaded failed failed Broken service
__NETCATTY_SERVICE_METADATA__
nginx.service enabled enabled
failed.service disabled enabled
timer-only.service static -
''';

    final services = service.parseSystemdServices(output);

    expect(services, hasLength(3));
    final nginx = services.firstWhere((value) => value.name == 'nginx.service');
    expect(nginx.state, RemoteServiceState.running);
    expect(nginx.enabled, isTrue);
    expect(nginx.description, 'A high performance web server');
    expect(
      services.firstWhere((value) => value.name == 'failed.service').state,
      RemoteServiceState.failed,
    );
  });

  test('parses OpenRC services and enabled runlevels', () {
    const output = '''
 sshd                         [  started  ]
 local                        [  stopped  ]
 crashed                      [  crashed  ]
__NETCATTY_SERVICE_METADATA__
                 sshd | default
                local |
''';

    final services = service.parseOpenRcServices(output);

    expect(services, hasLength(3));
    final sshd = services.firstWhere((value) => value.name == 'sshd');
    expect(sshd.state, RemoteServiceState.running);
    expect(sshd.enabled, isTrue);
    expect(
      services.firstWhere((value) => value.name == 'crashed').state,
      RemoteServiceState.failed,
    );
  });

  test('builds safe systemd and OpenRC service actions', () {
    const systemd = RemoteService(
      name: 'sshd.service',
      description: '',
      state: RemoteServiceState.running,
      enabled: true,
      manager: ServiceManager.systemd,
    );
    const openRc = RemoteService(
      name: 'sshd',
      description: '',
      state: RemoteServiceState.running,
      enabled: false,
      manager: ServiceManager.openRc,
    );

    expect(
      service.serviceActionCommand(systemd, RemoteServiceAction.restart),
      'systemctl restart sshd.service',
    );
    expect(
      service.serviceActionCommand(openRc, RemoteServiceAction.enable),
      'rc-update add sshd default',
    );
  });

  test('parses Caddy detection and Netcatty-managed sites', () {
    expect(service.parseCaddyStatus('missing\n').installed, isFalse);
    final status = service.parseCaddyStatus(
      'installed\nv2.10.2 h1:example\n/etc/caddy/Caddyfile\n',
    );
    expect(status.installed, isTrue);
    expect(status.version, 'v2.10.2 h1:example');
    expect(status.configPath, '/etc/caddy/Caddyfile');

    final sites = service.parseCaddySites('''
manual.example.com {
    respond "manual"
}
${service.buildCaddySiteSnippet(const CaddySite(
      id: 'site-one',
      address: 'example.com',
      upstreams: ['127.0.0.1:8080', '127.0.0.1:8081'],
    ))}
# netcatty-begin: malformed
# netcatty-address: not-base64
# netcatty-upstreams: broken
# netcatty-end: malformed
''');
    expect(sites, hasLength(1));
    expect(sites.single.id, 'site-one');
    expect(sites.single.address, 'example.com');
    expect(sites.single.upstreams, [
      '127.0.0.1:8080',
      '127.0.0.1:8081',
    ]);
  });

  test('builds marked Caddyfile blocks with validation and rollback', () {
    const status = CaddyStatus(
      installed: true,
      version: 'v2.10.2',
      configPath: '/etc/caddy/Caddyfile',
    );
    const site = CaddySite(
      id: 'site-one',
      address: 'example.com',
      upstreams: ['127.0.0.1:8080', '127.0.0.1:8081'],
    );

    final snippet = service.buildCaddySiteSnippet(site);
    expect(snippet, contains('example.com {'));
    expect(
      snippet,
      contains('reverse_proxy 127.0.0.1:8080 127.0.0.1:8081'),
    );
    expect(snippet, contains('# netcatty-address:'));
    expect(snippet, contains('# netcatty-upstreams:'));
    expect(snippet, startsWith('# netcatty-begin: site-one'));
    expect(snippet, endsWith('# netcatty-end: site-one\n'));

    final save = service.saveCaddySiteCommand(status, site);
    expect(save, contains('/etc/caddy/Caddyfile'));
    expect(save, contains('# netcatty-begin: site-one'));
    expect(save, contains('caddy validate'));
    expect(save, contains('caddy reload'));
    expect(save, contains('rollback'));

    final delete = service.deleteCaddySiteCommand(status, site);
    expect(delete, contains('caddy validate'));
    expect(delete, contains('caddy reload'));
    expect(delete, contains('rollback'));
  });

  test('rejects Caddyfile injection and missing installations', () {
    const installed = CaddyStatus(installed: true);
    expect(
      () => service.buildCaddySiteSnippet(
        const CaddySite(
          id: '../bad',
          address: 'example.com',
          upstreams: ['127.0.0.1:8080'],
        ),
      ),
      throwsFormatException,
    );
    expect(
      () => service.buildCaddySiteSnippet(
        const CaddySite(
          id: 'safe-id',
          address: 'example.com {\nrespond hacked',
          upstreams: ['127.0.0.1:8080'],
        ),
      ),
      throwsFormatException,
    );
    expect(
      () => service.buildCaddySiteSnippet(
        const CaddySite(
          id: 'safe-id',
          address: 'example.com',
          upstreams: ['127.0.0.1:8080\nhandle'],
        ),
      ),
      throwsFormatException,
    );
    expect(
      () => service.saveCaddySiteCommand(
        const CaddyStatus(installed: false),
        const CaddySite(
          id: 'safe-id',
          address: 'example.com',
          upstreams: ['127.0.0.1:8080'],
        ),
      ),
      throwsUnsupportedError,
    );
    expect(
      service.saveCaddySiteCommand(
        installed,
        const CaddySite(
          id: 'safe-id',
          address: 'example.com',
          upstreams: ['127.0.0.1:8080'],
        ),
      ),
      contains('# netcatty-begin: safe-id'),
    );
    expect(caddyNotFoundMessage, '未检测到 Caddy，请先安装 Caddy 后再重试。');
  });

  test('Caddy mutation scripts apply, remove and roll back atomically',
      () async {
    if (!Platform.isLinux) return;
    final temporary = await Directory.systemTemp.createTemp('netcatty caddy ');
    addTearDown(() => temporary.delete(recursive: true));
    final binaryDirectory = Directory('${temporary.path}/bin')..createSync();
    final fakeCaddy = File('${binaryDirectory.path}/caddy');
    fakeCaddy.writeAsStringSync('''#!/bin/sh
case "\$1" in
  version) printf 'v2.test\\n' ;;
  fmt) exit 0 ;;
  validate)
    if [ "\${FAIL_CADDY_VALIDATE:-0}" = 1 ]; then
      printf 'invalid test configuration\\n' >&2
      exit 1
    fi
    ;;
  reload) exit 0 ;;
esac
''');
    final chmod = await Process.run('chmod', ['+x', fakeCaddy.path]);
    expect(chmod.exitCode, 0);
    final status = CaddyStatus(
      installed: true,
      version: 'v2.test',
      configPath: '${temporary.path}/Caddyfile',
    );
    const initial = CaddySite(
      id: 'site-one',
      address: 'example.com',
      upstreams: ['127.0.0.1:8080'],
    );
    final environment = {
      ...Platform.environment,
      'PATH': '${binaryDirectory.path}:${Platform.environment['PATH']}',
    };
    final config = File(status.configPath)
      ..writeAsStringSync('manual.example.com {\n    respond "manual"\n}\n');

    var result = await Process.run(
      'sh',
      ['-c', service.saveCaddySiteCommand(status, initial)],
      environment: environment,
    );
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(config.readAsStringSync(), contains('127.0.0.1:8080'));
    expect(config.readAsStringSync(), contains('manual.example.com'));
    expect(config.readAsStringSync(), contains('# netcatty-begin: site-one'));

    const invalidUpdate = CaddySite(
      id: 'site-one',
      address: 'example.com',
      upstreams: ['127.0.0.1:9090'],
    );
    result = await Process.run(
      'sh',
      ['-c', service.saveCaddySiteCommand(status, invalidUpdate)],
      environment: {...environment, 'FAIL_CADDY_VALIDATE': '1'},
    );
    expect(result.exitCode, isNot(0));
    expect(config.readAsStringSync(), contains('127.0.0.1:8080'));
    expect(config.readAsStringSync(), isNot(contains('127.0.0.1:9090')));

    result = await Process.run(
      'sh',
      ['-c', service.deleteCaddySiteCommand(status, initial)],
      environment: environment,
    );
    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(config.readAsStringSync(), isNot(contains('netcatty-begin')));
    expect(config.readAsStringSync(), contains('manual.example.com'));
  });

  test('recognizes missing tmux command errors', () {
    expect(
      isTmuxCommandMissing('/bin/sh: tmux: command not found', exitCode: 127),
      isTrue,
    );
    expect(
      isTmuxCommandMissing('sh: tmux: not found', exitCode: 1),
      isTrue,
    );
    expect(
      isTmuxCommandMissing('no server running on /tmp/tmux-1000/default'),
      isFalse,
    );
    expect(tmuxNotFoundMessage, '未找到 tmux 命令，请先安装 tmux 后再重试。');
  });

  test('shellQuote safely escapes apostrophes', () {
    expect(shellQuote("team's work"), "'team'\\''s work'");
  });
}
