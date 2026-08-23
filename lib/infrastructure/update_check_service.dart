import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class UpdateCheckException implements Exception {
  const UpdateCheckException(this.message);

  final String message;

  @override
  String toString() => message;
}

class UpdateCheckResult {
  const UpdateCheckResult({
    required this.currentVersion,
    required this.latestVersion,
    required this.releaseUri,
  });

  final String currentVersion;
  final String latestVersion;
  final Uri releaseUri;

  bool get isLatest =>
      compareReleaseVersions(currentVersion, latestVersion) == 0;

  bool get updateAvailable =>
      compareReleaseVersions(latestVersion, currentVersion) > 0;

  bool get isDevelopmentVersion =>
      compareReleaseVersions(currentVersion, latestVersion) > 0;
}

class UpdateCheckService {
  UpdateCheckService({
    http.Client? client,
    this.requestTimeout = const Duration(seconds: 15),
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null;

  /// GitHub's `latest` endpoint excludes draft and prerelease releases, so the
  /// normal update channel never advertises beta builds.
  static final latestReleaseApi = Uri.parse(
    'https://api.github.com/repos/kmh1145/Netcatty-mobile/releases/latest',
  );
  static final latestReleasePage = Uri.parse(
    'https://github.com/kmh1145/Netcatty-mobile/releases/latest',
  );

  final http.Client _client;
  final bool _ownsClient;
  final Duration requestTimeout;

  Future<UpdateCheckResult> check(String currentVersion) async {
    late final http.Response response;
    try {
      response = await _client.get(
        latestReleaseApi,
        headers: const {
          'accept': 'application/vnd.github+json',
          'x-github-api-version': '2022-11-28',
          'user-agent': 'Netcatty-Mobile',
        },
      ).timeout(requestTimeout);
    } on TimeoutException {
      throw const UpdateCheckException('检查更新超时，请稍后重试');
    } on http.ClientException {
      throw const UpdateCheckException('无法连接 GitHub，请检查网络后重试');
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw UpdateCheckException(
        '检查更新失败（HTTP ${response.statusCode}）',
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw const UpdateCheckException('GitHub 返回了无法识别的版本信息');
    }
    if (decoded is! Map) {
      throw const UpdateCheckException('GitHub 返回了无法识别的版本信息');
    }
    if (decoded['draft'] == true || decoded['prerelease'] == true) {
      throw const UpdateCheckException('GitHub 返回的不是正式 Release');
    }

    final tagName = decoded['tag_name']?.toString().trim() ?? '';
    if (tagName.isEmpty) {
      throw const UpdateCheckException('最新 Release 缺少版本号');
    }
    final latestVersion = tagName.replaceFirst(RegExp(r'^[vV]'), '');
    try {
      compareReleaseVersions(currentVersion, latestVersion);
    } on FormatException {
      throw const UpdateCheckException('最新 Release 版本号格式无效');
    }

    final candidate = Uri.tryParse(decoded['html_url']?.toString() ?? '');
    final releaseUri = candidate != null &&
            candidate.scheme == 'https' &&
            candidate.host == 'github.com'
        ? candidate
        : latestReleasePage;
    return UpdateCheckResult(
      currentVersion: currentVersion,
      latestVersion: latestVersion,
      releaseUri: releaseUri,
    );
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}

int compareReleaseVersions(String left, String right) {
  final leftVersion = _ReleaseVersion.parse(left);
  final rightVersion = _ReleaseVersion.parse(right);
  for (var index = 0; index < 3; index++) {
    final compared = leftVersion.numbers[index].compareTo(
      rightVersion.numbers[index],
    );
    if (compared != 0) return compared;
  }

  final leftPre = leftVersion.preRelease;
  final rightPre = rightVersion.preRelease;
  if (leftPre == null && rightPre == null) return 0;
  if (leftPre == null) return 1;
  if (rightPre == null) return -1;
  final length =
      leftPre.length > rightPre.length ? leftPre.length : rightPre.length;
  for (var index = 0; index < length; index++) {
    if (index >= leftPre.length) return -1;
    if (index >= rightPre.length) return 1;
    final leftPart = leftPre[index];
    final rightPart = rightPre[index];
    final leftNumber = int.tryParse(leftPart);
    final rightNumber = int.tryParse(rightPart);
    if (leftNumber != null && rightNumber != null) {
      final compared = leftNumber.compareTo(rightNumber);
      if (compared != 0) return compared;
    } else if (leftNumber != null) {
      return -1;
    } else if (rightNumber != null) {
      return 1;
    } else {
      final compared = leftPart.compareTo(rightPart);
      if (compared != 0) return compared;
    }
  }
  return 0;
}

class _ReleaseVersion {
  const _ReleaseVersion(this.numbers, this.preRelease);

  final List<int> numbers;
  final List<String>? preRelease;

  factory _ReleaseVersion.parse(String value) {
    final withoutPrefix = value.trim().replaceFirst(RegExp(r'^[vV]'), '');
    final withoutBuild = withoutPrefix.split('+').first;
    final dash = withoutBuild.indexOf('-');
    final core = dash < 0 ? withoutBuild : withoutBuild.substring(0, dash);
    final rawPre = dash < 0 ? null : withoutBuild.substring(dash + 1);
    final parts = core.split('.');
    if (parts.isEmpty || parts.length > 3) {
      throw FormatException('Invalid release version: $value');
    }
    final numbers = <int>[];
    for (final part in parts) {
      final parsed = int.tryParse(part);
      if (parsed == null || parsed < 0) {
        throw FormatException('Invalid release version: $value');
      }
      numbers.add(parsed);
    }
    while (numbers.length < 3) {
      numbers.add(0);
    }
    final preRelease = rawPre
        ?.split('.')
        .where((part) => part.isNotEmpty)
        .map((part) => part.toLowerCase())
        .toList(growable: false);
    if (preRelease?.isEmpty ?? false) {
      throw FormatException('Invalid release version: $value');
    }
    return _ReleaseVersion(numbers, preRelease);
  }
}
