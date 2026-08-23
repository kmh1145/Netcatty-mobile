enum ProcessSortKey { cpu, memory, pid, command, user }

class RemoteProcess {
  const RemoteProcess({
    required this.pid,
    required this.ppid,
    required this.user,
    required this.state,
    required this.cpuPercent,
    required this.memoryPercent,
    required this.rssKb,
    required this.vszKb,
    required this.elapsed,
    required this.command,
    this.processName = '',
  });

  final int pid;
  final int ppid;
  final String user;
  final String state;
  final double cpuPercent;
  final double memoryPercent;
  final int rssKb;
  final int vszKb;
  final String elapsed;
  final String command;
  final String processName;

  String get name {
    final explicitName = processName.trim();
    if (explicitName.isNotEmpty) return explicitName;
    final value = command.trim();
    if (value.isEmpty) return '-';
    if (value.startsWith('[')) {
      final closingBracket = value.indexOf(']');
      if (closingBracket >= 0) return value.substring(0, closingBracket + 1);
    }
    final executable = value.split(RegExp(r'\s+')).first.replaceAll(
          RegExp(r'''^["']|["']$'''),
          '',
        );
    final separator = executable.lastIndexOf(RegExp(r'[/\\]'));
    return separator < 0 ? executable : executable.substring(separator + 1);
  }

  bool get isRunning => state.toUpperCase().startsWith('R');
  bool get isStopped => state.toUpperCase().startsWith('T');
}

enum DockerContainerState { running, stopped, paused, unknown }

class DockerContainerInfo {
  const DockerContainerInfo({
    required this.id,
    required this.name,
    required this.image,
    required this.status,
    required this.state,
    required this.ports,
    required this.createdAt,
    this.labels = const {},
  });

  final String id;
  final String name;
  final String image;
  final String status;
  final DockerContainerState state;
  final String ports;
  final String createdAt;
  final Map<String, String> labels;

  String get shortId => id.length > 12 ? id.substring(0, 12) : id;
  String get composeProject => labels['com.docker.compose.project'] ?? '';
  String get composeService => labels['com.docker.compose.service'] ?? '';
}

class DockerImageInfo {
  const DockerImageInfo({
    required this.id,
    required this.repository,
    required this.tag,
    required this.digest,
    required this.size,
    required this.createdAt,
  });

  final String id;
  final String repository;
  final String tag;
  final String digest;
  final String size;
  final String createdAt;

  String get name =>
      tag.isEmpty || tag == '<none>' ? repository : '$repository:$tag';
  String get shortId {
    final value = id.startsWith('sha256:') ? id.substring(7) : id;
    return value.length > 12 ? value.substring(0, 12) : value;
  }
}

enum DockerComposeAction {
  start,
  stop,
  restart,
  pause,
  unpause,
  pull,
  update,
  recreate,
  rebuild,
  down,
}

class DockerComposeProject {
  const DockerComposeProject({
    required this.name,
    required this.status,
    required this.configFiles,
    this.workingDirectory = '',
    this.runningCount = 0,
    this.stoppedCount = 0,
    this.pausedCount = 0,
  });

  final String name;
  final String status;
  final List<String> configFiles;
  final String workingDirectory;
  final int runningCount;
  final int stoppedCount;
  final int pausedCount;

  int get containerCount => runningCount + stoppedCount + pausedCount;
  bool get isRunning => runningCount > 0;
  bool get isPaused => pausedCount > 0 && runningCount == 0;
}

class TmuxSessionInfo {
  const TmuxSessionInfo({
    required this.name,
    required this.windowCount,
    required this.attachedClients,
    required this.createdAt,
    required this.activityAt,
    required this.group,
  });

  final String name;
  final int windowCount;
  final int attachedClients;
  final DateTime? createdAt;
  final DateTime? activityAt;
  final String group;
}

class TmuxWindowInfo {
  const TmuxWindowInfo({
    required this.index,
    required this.name,
    required this.paneCount,
    required this.active,
    required this.layout,
  });

  final int index;
  final String name;
  final int paneCount;
  final bool active;
  final String layout;
}

class TmuxClientInfo {
  const TmuxClientInfo({
    required this.name,
    required this.tty,
    required this.session,
    required this.activityAt,
  });

  final String name;
  final String tty;
  final String session;
  final DateTime? activityAt;
}

class TmuxSessionDetails {
  const TmuxSessionDetails({
    required this.windows,
    required this.clients,
  });

  final List<TmuxWindowInfo> windows;
  final List<TmuxClientInfo> clients;
}
