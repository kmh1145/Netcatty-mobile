import 'package:flutter_test/flutter_test.dart';
import 'package:netcatty_mobile/domain/models/system_management.dart';
import 'package:netcatty_mobile/infrastructure/ssh/system_management_service.dart';

void main() {
  late SystemManagementService service;

  setUp(() => service = SystemManagementService());

  test('parses canonical process output with resource details', () {
    const output = '''
  731     1 redis    Ssl   12.5  3.4  40960 162000  1-02:03:04 redis-server *:6379
 2048   731 app      R      8.0  1.2  12288  64000       12:31 python worker.py --queue high
''';

    final processes = service.parseProcesses(output);

    expect(processes, hasLength(2));
    expect(processes.first.pid, 731);
    expect(processes.first.ppid, 1);
    expect(processes.first.user, 'redis');
    expect(processes.first.cpuPercent, 12.5);
    expect(processes.first.rssKb, 40960);
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
