import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../domain/models/system_management.dart';
import 'ssh_service.dart';

class RemoteCommandException implements Exception {
  const RemoteCommandException(this.message, {this.exitCode});

  final String message;
  final int? exitCode;

  @override
  String toString() => message;
}

class DockerSudoPasswordRequired implements Exception {
  const DockerSudoPasswordRequired(this.message);

  final String message;

  @override
  String toString() => message;
}

enum ProcessSignal { stop, cont, term, kill }

enum DockerContainerAction {
  start,
  stop,
  restart,
  pause,
  unpause,
  kill,
  remove,
}

enum _DockerPrivilege { direct, sudoNoPassword, sudoPassword }

class SystemManagementService {
  final _dockerPrivileges = <String, _DockerPrivilege>{};
  final _sudoPasswords = <String, String>{};

  Future<List<RemoteProcess>> listProcesses(
    ActiveTerminalSession session,
  ) async {
    final output = await _executeSession(session, _processListCommand);
    return parseProcesses(output.stdout);
  }

  List<RemoteProcess> parseProcesses(String raw) {
    final result = <RemoteProcess>[];
    final expression = RegExp(
      r'^\s*(\d+)\s+(\d+)\s+(\S+)\s+(\S+)\s+([\d.]+)\s+([\d.]+)\s+(\d+)\s+(\d+)\s+(\S+)\s+(.+)$',
    );
    for (final line in const LineSplitter().convert(raw)) {
      final match = expression.firstMatch(line);
      if (match == null) continue;
      result.add(
        RemoteProcess(
          pid: int.parse(match.group(1)!),
          ppid: int.parse(match.group(2)!),
          user: match.group(3)!,
          state: match.group(4)!,
          cpuPercent: double.tryParse(match.group(5)!) ?? 0,
          memoryPercent: double.tryParse(match.group(6)!) ?? 0,
          rssKb: int.tryParse(match.group(7)!) ?? 0,
          vszKb: int.tryParse(match.group(8)!) ?? 0,
          elapsed: match.group(9)!,
          command: match.group(10)!.trim(),
        ),
      );
    }
    if (result.isNotEmpty) return result;
    return _parsePortableProcesses(raw);
  }

  Future<void> signalProcess(
    ActiveTerminalSession session,
    int pid,
    ProcessSignal signal,
  ) async {
    _validatePid(pid);
    final value = switch (signal) {
      ProcessSignal.stop => 'STOP',
      ProcessSignal.cont => 'CONT',
      ProcessSignal.term => 'TERM',
      ProcessSignal.kill => 'KILL',
    };
    await _executeSession(session, 'kill -s $value $pid');
  }

  Future<void> reniceProcess(
    ActiveTerminalSession session,
    int pid,
    int priority,
  ) async {
    _validatePid(pid);
    if (priority < -20 || priority > 19) {
      throw const FormatException('调度优先级必须在 -20 到 19 之间');
    }
    await _executeSession(session, 'renice $priority -p $pid');
  }

  Future<List<DockerContainerInfo>> listDockerContainers(
    ActiveTerminalSession session,
  ) async {
    final output = await _docker(
      session,
      const ['ps', '-a', '--no-trunc', '--format', '{{json .}}'],
    );
    return parseDockerContainers(output);
  }

  List<DockerContainerInfo> parseDockerContainers(String raw) {
    final result = <DockerContainerInfo>[];
    for (final line in const LineSplitter().convert(raw)) {
      if (line.trim().isEmpty) continue;
      try {
        final value = jsonDecode(line) as Map<String, dynamic>;
        final status = value['Status']?.toString() ?? '';
        final stateText = (value['State']?.toString() ?? '').toLowerCase();
        final state = switch (stateText) {
          'running' => DockerContainerState.running,
          'paused' => DockerContainerState.paused,
          'created' ||
          'exited' ||
          'dead' ||
          'removing' =>
            DockerContainerState.stopped,
          _ when status.toLowerCase().contains('paused') =>
            DockerContainerState.paused,
          _ when status.toLowerCase().startsWith('up') =>
            DockerContainerState.running,
          _ when status.isNotEmpty => DockerContainerState.stopped,
          _ => DockerContainerState.unknown,
        };
        result.add(
          DockerContainerInfo(
            id: value['ID']?.toString() ?? '',
            name: value['Names']?.toString() ?? '',
            image: value['Image']?.toString() ?? '',
            status: status,
            state: state,
            ports: value['Ports']?.toString() ?? '',
            createdAt: value['CreatedAt']?.toString() ?? '',
          ),
        );
      } on FormatException {
        continue;
      }
    }
    return result;
  }

  Future<List<DockerImageInfo>> listDockerImages(
    ActiveTerminalSession session,
  ) async {
    final output = await _docker(
      session,
      const [
        'images',
        '--no-trunc',
        '--digests',
        '--format',
        '{{json .}}',
      ],
    );
    return parseDockerImages(output);
  }

  List<DockerImageInfo> parseDockerImages(String raw) {
    final result = <DockerImageInfo>[];
    for (final line in const LineSplitter().convert(raw)) {
      if (line.trim().isEmpty) continue;
      try {
        final value = jsonDecode(line) as Map<String, dynamic>;
        result.add(
          DockerImageInfo(
            id: value['ID']?.toString() ?? '',
            repository: value['Repository']?.toString() ?? '<none>',
            tag: value['Tag']?.toString() ?? '<none>',
            digest: value['Digest']?.toString() ?? '',
            size: value['Size']?.toString() ?? '',
            createdAt: value['CreatedAt']?.toString() ?? '',
          ),
        );
      } on FormatException {
        continue;
      }
    }
    return result;
  }

  Future<void> dockerContainerAction(
    ActiveTerminalSession session,
    String id,
    DockerContainerAction action,
  ) async {
    _validateDockerId(id);
    final args = switch (action) {
      DockerContainerAction.start => ['start', id],
      DockerContainerAction.stop => ['stop', id],
      DockerContainerAction.restart => ['restart', id],
      DockerContainerAction.pause => ['pause', id],
      DockerContainerAction.unpause => ['unpause', id],
      DockerContainerAction.kill => ['kill', id],
      DockerContainerAction.remove => ['rm', '-f', id],
    };
    await _docker(session, args);
  }

  Future<void> removeDockerImage(
    ActiveTerminalSession session,
    String id,
  ) async {
    _validateDockerId(id.replaceFirst('sha256:', ''));
    await _docker(session, ['rmi', id]);
  }

  Future<void> pullDockerImage(
    ActiveTerminalSession session,
    String reference,
  ) async {
    final value = reference.trim();
    if (value.isEmpty || value.length > 255 || value.contains('\n')) {
      throw const FormatException('请输入有效的镜像名称');
    }
    await _docker(session, ['pull', value],
        timeout: const Duration(minutes: 5));
  }

  void setDockerSudoPassword(
    ActiveTerminalSession session,
    String password,
  ) {
    if (password.isEmpty) return;
    _sudoPasswords[session.id] = password;
    _dockerPrivileges.remove(session.id);
  }

  String dockerShellCommand(ActiveTerminalSession session, String id) {
    _validateDockerId(id);
    return '${_interactiveDockerPrefix(session)} exec -it $id '
        "sh -lc 'if command -v bash >/dev/null 2>&1; then exec bash; else exec sh; fi'";
  }

  String dockerLogsCommand(ActiveTerminalSession session, String id) {
    _validateDockerId(id);
    return '${_interactiveDockerPrefix(session)} logs -f --tail 200 $id';
  }

  Future<String> tmuxVersion(ActiveTerminalSession session) async {
    final result = await _executeSession(session, 'tmux -V');
    return result.stdout.trim();
  }

  Future<List<TmuxSessionInfo>> listTmuxSessions(
    ActiveTerminalSession session,
  ) async {
    const format = '#{session_name}\t#{session_windows}\t'
        '#{session_attached}\t#{session_created}\t'
        '#{session_activity}\t#{session_group}';
    final output = await _executeSession(
      session,
      'tmux list-sessions -F ${shellQuote(format)}',
      acceptedExitCodes: const {0, 1},
    );
    if (output.exitCode == 1 &&
        output.stderr.toLowerCase().contains('no server running')) {
      return const [];
    }
    if (output.exitCode == 1 &&
        output.stderr.toLowerCase().contains('no sessions')) {
      return const [];
    }
    if (output.exitCode != 0) {
      throw RemoteCommandException(
        output.stderr.trim().isEmpty
            ? '无法读取 tmux session'
            : output.stderr.trim(),
        exitCode: output.exitCode,
      );
    }
    return parseTmuxSessions(output.stdout);
  }

  List<TmuxSessionInfo> parseTmuxSessions(String raw) {
    final result = <TmuxSessionInfo>[];
    for (final line in const LineSplitter().convert(raw)) {
      final parts = line.split('\t');
      if (parts.length < 5) continue;
      result.add(
        TmuxSessionInfo(
          name: parts[0],
          windowCount: int.tryParse(parts[1]) ?? 0,
          attachedClients: int.tryParse(parts[2]) ?? 0,
          createdAt: _epoch(parts[3]),
          activityAt: _epoch(parts[4]),
          group: parts.length > 5 ? parts[5] : '',
        ),
      );
    }
    return result;
  }

  Future<TmuxSessionDetails> tmuxSessionDetails(
    ActiveTerminalSession session,
    String name,
  ) async {
    const windowFormat = '#{window_index}\t#{window_name}\t'
        '#{window_panes}\t#{window_active}\t#{window_layout}';
    const clientFormat = '#{client_name}\t#{client_tty}\t'
        '#{client_session}\t#{client_activity}';
    final windowsOutput = await _executeSession(
      session,
      'tmux list-windows -t ${shellQuote(name)} -F ${shellQuote(windowFormat)}',
    );
    final clientsOutput = await _executeSession(
      session,
      'tmux list-clients -t ${shellQuote(name)} -F ${shellQuote(clientFormat)}',
      acceptedExitCodes: const {0, 1},
    );
    final windows = <TmuxWindowInfo>[];
    for (final line in const LineSplitter().convert(windowsOutput.stdout)) {
      final parts = line.split('\t');
      if (parts.length < 5) continue;
      windows.add(
        TmuxWindowInfo(
          index: int.tryParse(parts[0]) ?? 0,
          name: parts[1],
          paneCount: int.tryParse(parts[2]) ?? 0,
          active: parts[3] == '1',
          layout: parts[4],
        ),
      );
    }
    final clients = <TmuxClientInfo>[];
    for (final line in const LineSplitter().convert(clientsOutput.stdout)) {
      final parts = line.split('\t');
      if (parts.length < 4) continue;
      clients.add(
        TmuxClientInfo(
          name: parts[0],
          tty: parts[1],
          session: parts[2],
          activityAt: _epoch(parts[3]),
        ),
      );
    }
    return TmuxSessionDetails(windows: windows, clients: clients);
  }

  Future<void> createTmuxSession(
    ActiveTerminalSession session, {
    required String name,
    String? startupCommand,
  }) async {
    final value = name.trim();
    if (value.isEmpty || value.length > 80 || value.contains(RegExp(r'[:.]'))) {
      throw const FormatException('session 名称不能为空，且不能包含冒号或句点');
    }
    var command = 'tmux new-session -d -s ${shellQuote(value)}';
    final startup = startupCommand?.trim() ?? '';
    if (startup.isNotEmpty) {
      command += ' && tmux send-keys -t ${shellQuote(value)} '
          '${shellQuote(startup)} C-m';
    }
    await _executeSession(session, command);
  }

  Future<void> killTmuxSession(
    ActiveTerminalSession session,
    String name,
  ) =>
      _executeSession(
        session,
        'tmux kill-session -t ${shellQuote(name)}',
      ).then((_) {});

  String tmuxAttachCommand(String name) =>
      'tmux attach-session -t ${shellQuote(name)}';

  Future<String> _docker(
    ActiveTerminalSession session,
    List<String> args, {
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final direct = 'docker ${args.map(shellQuote).join(' ')}';
    final cached = _dockerPrivileges[session.id];
    if (cached != null) {
      try {
        final result = await _executeDockerMode(
          session,
          direct,
          cached,
          timeout,
        );
        return result.stdout;
      } on RemoteCommandException catch (error) {
        if (cached != _DockerPrivilege.sudoPassword) rethrow;
        _dockerPrivileges.remove(session.id);
        _sudoPasswords.remove(session.id);
        throw DockerSudoPasswordRequired(
          'sudo 密码验证失败，请重新输入。\n${error.message}',
        );
      }
    }

    try {
      final result = await _executeSession(session, direct, timeout: timeout);
      _dockerPrivileges[session.id] = _DockerPrivilege.direct;
      return result.stdout;
    } on RemoteCommandException catch (error) {
      if (!_isDockerPermissionError(error.message)) rethrow;
    }

    try {
      final result = await _executeSession(
        session,
        'sudo -n $direct',
        timeout: timeout,
      );
      _dockerPrivileges[session.id] = _DockerPrivilege.sudoNoPassword;
      return result.stdout;
    } on RemoteCommandException catch (error) {
      final password = _sudoPasswords[session.id];
      if (password == null) {
        throw DockerSudoPasswordRequired(
          '当前用户无权访问 docker.sock，且 sudo 需要密码。\n${error.message}',
        );
      }
    }

    final result = await _executeDockerMode(
      session,
      direct,
      _DockerPrivilege.sudoPassword,
      timeout,
    );
    _dockerPrivileges[session.id] = _DockerPrivilege.sudoPassword;
    return result.stdout;
  }

  Future<_RemoteResult> _executeDockerMode(
    ActiveTerminalSession session,
    String direct,
    _DockerPrivilege mode,
    Duration timeout,
  ) {
    return switch (mode) {
      _DockerPrivilege.direct =>
        _executeSession(session, direct, timeout: timeout),
      _DockerPrivilege.sudoNoPassword =>
        _executeSession(session, 'sudo -n $direct', timeout: timeout),
      _DockerPrivilege.sudoPassword => _executeSession(
          session,
          "sudo -S -p '' $direct",
          stdinText: '${_sudoPasswords[session.id] ?? ''}\n',
          timeout: timeout,
        ),
    };
  }

  String _interactiveDockerPrefix(ActiveTerminalSession session) =>
      switch (_dockerPrivileges[session.id]) {
        _DockerPrivilege.sudoNoPassword ||
        _DockerPrivilege.sudoPassword =>
          'sudo docker',
        _ => 'docker',
      };

  Future<_RemoteResult> _executeSession(
    ActiveTerminalSession session,
    String command, {
    String? stdinText,
    Duration timeout = const Duration(seconds: 15),
    Set<int> acceptedExitCodes = const {0},
  }) async {
    final client = session.sshClient;
    if (client == null) {
      throw UnsupportedError('系统管理仅支持 SSH 连接');
    }
    final process = await client.execute(command);
    if (stdinText != null) {
      process.stdin.add(Uint8List.fromList(utf8.encode(stdinText)));
      await process.stdin.close();
    }
    try {
      final values = await Future.wait<String>([
        utf8.decoder.bind(process.stdout).join(),
        utf8.decoder.bind(process.stderr).join(),
      ]).timeout(timeout);
      await process.done.timeout(const Duration(seconds: 2));
      final result = _RemoteResult(
        stdout: values[0],
        stderr: values[1],
        exitCode: process.exitCode ?? 0,
      );
      if (!acceptedExitCodes.contains(result.exitCode)) {
        final message = result.stderr.trim().isNotEmpty
            ? result.stderr.trim()
            : result.stdout.trim().isNotEmpty
                ? result.stdout.trim()
                : '远程命令执行失败';
        throw RemoteCommandException(message, exitCode: result.exitCode);
      }
      return result;
    } on TimeoutException {
      process.close();
      throw TimeoutException('远程系统管理命令执行超时');
    }
  }

  static bool _isDockerPermissionError(String message) {
    final value = message.toLowerCase();
    return (value.contains('permission denied') ||
            value.contains('got permission denied')) &&
        (value.contains('docker.sock') ||
            value.contains('docker daemon') ||
            value.contains('connect'));
  }

  static List<RemoteProcess> _parsePortableProcesses(String raw) {
    final lines = const LineSplitter()
        .convert(raw)
        .where((line) => line.trim().isNotEmpty)
        .toList(growable: false);
    final headerIndex = lines.indexWhere(
      (line) => line.toUpperCase().split(RegExp(r'\s+')).contains('PID'),
    );
    if (headerIndex < 0) return const [];
    final header =
        lines[headerIndex].trim().toUpperCase().split(RegExp(r'\s+'));
    int column(String name) => header.indexOf(name);
    final pidColumn = column('PID');
    final ppidColumn = column('PPID');
    final userColumn = column('USER') >= 0 ? column('USER') : column('UID');
    final stateColumn = column('STAT') >= 0 ? column('STAT') : column('S');
    final cpuColumn = column('%CPU');
    final memoryColumn = column('%MEM');
    final rssColumn = column('RSS');
    final vszColumn = column('VSZ');
    final elapsedColumn = column('ELAPSED') >= 0
        ? column('ELAPSED')
        : column('ETIME') >= 0
            ? column('ETIME')
            : column('TIME');
    var commandColumn = column('COMMAND');
    if (commandColumn < 0) commandColumn = column('CMD');
    if (commandColumn < 0) commandColumn = column('ARGS');
    if (pidColumn < 0 || commandColumn < 0) return const [];

    String valueAt(List<String> values, int index, [String fallback = '']) =>
        index >= 0 && index < values.length ? values[index] : fallback;
    final result = <RemoteProcess>[];
    for (final line in lines.skip(headerIndex + 1)) {
      final values = line.trim().split(RegExp(r'\s+'));
      final pid = int.tryParse(valueAt(values, pidColumn));
      if (pid == null || pid <= 0 || commandColumn >= values.length) continue;
      result.add(
        RemoteProcess(
          pid: pid,
          ppid: int.tryParse(valueAt(values, ppidColumn)) ?? 0,
          user: valueAt(values, userColumn, '?'),
          state: valueAt(values, stateColumn, '?'),
          cpuPercent: double.tryParse(valueAt(values, cpuColumn)) ?? 0,
          memoryPercent: double.tryParse(valueAt(values, memoryColumn)) ?? 0,
          rssKb: int.tryParse(valueAt(values, rssColumn)) ?? 0,
          vszKb: int.tryParse(valueAt(values, vszColumn)) ?? 0,
          elapsed: valueAt(values, elapsedColumn, '-'),
          command: values.skip(commandColumn).join(' '),
        ),
      );
    }
    return result;
  }

  static DateTime? _epoch(String value) {
    final seconds = int.tryParse(value);
    if (seconds == null || seconds <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
  }

  static void _validatePid(int pid) {
    if (pid <= 0) throw const FormatException('PID 必须大于 0');
  }

  static void _validateDockerId(String id) {
    if (!RegExp(r'^[a-zA-Z0-9]{1,64}$').hasMatch(id)) {
      throw const FormatException('容器或镜像 ID 无效');
    }
  }
}

class _RemoteResult {
  const _RemoteResult({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
  });

  final String stdout;
  final String stderr;
  final int exitCode;
}

String shellQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";

const _processListCommand =
    'LC_ALL=C ps -eo pid=,ppid=,user=,stat=,pcpu=,pmem=,rss=,vsz=,etime=,args= 2>/dev/null || LC_ALL=C ps ww 2>/dev/null || LC_ALL=C ps 2>/dev/null';
