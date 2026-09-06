/// Commands run on the servers, never on the phone. No phone credentials are
/// embedded, and unknown host keys are never accepted automatically.
class ServerTransferCommands {
  static String shell(String value) => "'${value.replaceAll("'", "'\\''")}'";

  static void checkPath(String path) {
    if (!path.startsWith('/') ||
        path == '/' ||
        path.contains('\u0000') ||
        path.split('/').contains('..')) {
      throw ArgumentError('Unsafe remote transfer path');
    }
  }

  static String copy(String source, String destination) {
    checkPath(source);
    checkPath(destination);
    return 'test ! -e ${shell(destination)} && test ! -L ${shell(destination)} && '
        'exec cp -RP -- ${shell(source)} ${shell(destination)}';
  }

  // -T prevents a newly-created destination directory from silently receiving
  // the source as a child. -n refuses replacement; verify it did not just skip.
  static String move(String source, String destination) {
    checkPath(source);
    checkPath(destination);
    return 'test ! -e ${shell(destination)} && test ! -L ${shell(destination)} && '
        'mv -nT -- ${shell(source)} ${shell(destination)} && '
        'test ! -e ${shell(source)} && test ! -L ${shell(source)}';
  }

  static String sftp(String hostname, int port, String username) {
    // Do not allow option/config/URI injection. Unicode DNS is converted by the
    // caller's host configuration; unusual endpoint syntax falls back to relay.
    if (!RegExp(r'^[a-zA-Z0-9_.:\-]+$').hasMatch(hostname) ||
        hostname.startsWith('-') ||
        port < 1 ||
        port > 65535 ||
        !RegExp(r'^[a-zA-Z0-9_.\-]+$').hasMatch(username) ||
        username.startsWith('-')) {
      throw ArgumentError('Unsupported direct-transfer endpoint');
    }
    final host = hostname.contains(':') ? '[$hostname]' : hostname;
    return 'sftp -F /dev/null -b - -P $port '
        '-oBatchMode=yes -oStrictHostKeyChecking=yes -oUpdateHostKeys=no '
        '-oPasswordAuthentication=no -oKbdInteractiveAuthentication=no '
        '-oPreferredAuthentications=publickey -oIdentityAgent=none '
        '-oForwardAgent=no -oClearAllForwardings=yes '
        '-oControlMaster=no -oControlPath=none '
        '-oConnectTimeout=8 -oConnectionAttempts=1 '
        '-oServerAliveInterval=5 -oServerAliveCountMax=2 '
        '${shell('$username@$host')}';
  }

  static String batchPath(String path) {
    checkPath(path);
    // OpenSSH batch files are line-oriented. Do not let a filename inject a
    // second command; offer phone relay for these uncommon names instead.
    if (path.contains('\n') || path.contains('\r')) {
      throw ArgumentError('Newlines require phone relay');
    }
    // OpenSSH makeargv escapes glob metacharacters inside double quotes itself.
    // Adding a backslash before '[' here would create a literal backslash.
    final escaped = path.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
    return '"$escaped"';
  }

  static String upload(String source, String destination, bool directory) =>
      'put ${directory ? '-R ' : ''}${batchPath(source)} '
      '${batchPath(destination)}\nbye\n';
}
