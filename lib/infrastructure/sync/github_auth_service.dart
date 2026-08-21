import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

class GitHubDeviceAuthorization {
  const GitHubDeviceAuthorization({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.expiresAt,
    required this.interval,
  });

  final String deviceCode;
  final String userCode;
  final Uri verificationUri;
  final DateTime expiresAt;
  final Duration interval;
}

enum GitHubAuthPollState { waitingForAuthorization, retryingNetwork }

class GitHubAuthCancelledException implements Exception {
  const GitHubAuthCancelledException();

  @override
  String toString() => 'GitHub 登录已取消';
}

class GitHubAuthNetworkException implements Exception {
  const GitHubAuthNetworkException(this.message);

  final String message;

  @override
  String toString() => message;
}

typedef GitHubAuthDelay = Future<void> Function(Duration duration);

class GitHubAuthService {
  GitHubAuthService({
    http.Client? client,
    GitHubAuthDelay? delay,
    this.requestTimeout = const Duration(seconds: 20),
  })  : _client = client ?? http.Client(),
        _ownsClient = client == null,
        _delay = delay ?? Future<void>.delayed;

  static const clientId = String.fromEnvironment(
    'GITHUB_OAUTH_CLIENT_ID',
    defaultValue: 'Ov23lidR2u8OIkHW19nk',
  );

  final http.Client _client;
  final bool _ownsClient;
  final GitHubAuthDelay _delay;
  final Duration requestTimeout;

  Future<GitHubDeviceAuthorization> start() async {
    late final http.Response response;
    try {
      response = await _client.post(
        Uri.parse('https://github.com/login/device/code'),
        headers: const {'accept': 'application/json'},
        body: const {'client_id': clientId, 'scope': 'gist read:user'},
      ).timeout(requestTimeout);
    } on Object catch (error) {
      if (_isTransient(error)) {
        throw const GitHubAuthNetworkException(
          '无法连接 GitHub，请检查网络、VPN或代理后重试',
        );
      }
      rethrow;
    }
    final json = _json(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
        json['error_description']?.toString() ??
            'GitHub 授权启动失败（HTTP ${response.statusCode}）',
      );
    }
    return GitHubDeviceAuthorization(
      deviceCode: json['device_code'].toString(),
      userCode: json['user_code'].toString(),
      verificationUri: Uri.parse(json['verification_uri'].toString()),
      expiresAt: DateTime.now().add(
        Duration(seconds: (json['expires_in'] as num).toInt()),
      ),
      interval: Duration(seconds: (json['interval'] as num?)?.toInt() ?? 5),
    );
  }

  Future<String> poll(
    GitHubDeviceAuthorization authorization, {
    bool Function()? isCancelled,
    void Function(GitHubAuthPollState state)? onStateChanged,
  }) async {
    var interval = authorization.interval;
    onStateChanged?.call(GitHubAuthPollState.waitingForAuthorization);
    while (DateTime.now().isBefore(authorization.expiresAt)) {
      _throwIfCancelled(isCancelled);
      await _delay(interval);
      _throwIfCancelled(isCancelled);

      http.Response response;
      try {
        response = await _client.post(
          Uri.parse('https://github.com/login/oauth/access_token'),
          headers: const {'accept': 'application/json'},
          body: {
            'client_id': clientId,
            'device_code': authorization.deviceCode,
            'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
          },
        ).timeout(requestTimeout);
      } on Object catch (error) {
        if (_isTransient(error)) {
          onStateChanged?.call(GitHubAuthPollState.retryingNetwork);
          continue;
        }
        rethrow;
      }

      if (_isRetryableStatus(response.statusCode)) {
        onStateChanged?.call(GitHubAuthPollState.retryingNetwork);
        continue;
      }
      final json = _json(response);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw StateError(
          json['error_description']?.toString() ??
              'GitHub 授权请求失败（HTTP ${response.statusCode}）',
        );
      }

      onStateChanged?.call(GitHubAuthPollState.waitingForAuthorization);
      final token = json['access_token']?.toString();
      if (token?.isNotEmpty == true) return token!;
      switch (json['error']?.toString()) {
        case 'authorization_pending':
          continue;
        case 'slow_down':
          interval += const Duration(seconds: 5);
          continue;
        case 'expired_token':
          throw StateError('GitHub 验证码已过期，请重新登录');
        case 'access_denied':
          throw StateError('GitHub 授权已取消');
        case final String error when error.isNotEmpty:
          throw StateError(
            json['error_description']?.toString() ?? 'GitHub 授权失败：$error',
          );
        default:
          throw StateError('GitHub 返回了无法识别的授权响应');
      }
    }
    throw StateError('GitHub 验证码已过期，请重新登录');
  }

  Future<Map<String, dynamic>> currentUser(String token) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      if (attempt > 0) {
        await _delay(Duration(seconds: attempt * 2));
      }
      try {
        final response = await _client.get(
          Uri.parse('https://api.github.com/user'),
          headers: {
            'accept': 'application/vnd.github+json',
            'authorization': 'Bearer $token',
            'x-github-api-version': '2022-11-28',
          },
        ).timeout(requestTimeout);
        if (_isRetryableStatus(response.statusCode)) {
          if (attempt < 2) continue;
          throw GitHubAuthNetworkException(
            '已取得 GitHub 授权，但暂时无法读取用户信息（HTTP ${response.statusCode}）',
          );
        }
        final json = _json(response);
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw StateError('GitHub 登录状态无效（${response.statusCode}）');
        }
        return json;
      } on Object catch (error) {
        if (_isTransient(error)) {
          if (attempt < 2) continue;
          throw const GitHubAuthNetworkException(
            '已取得 GitHub 授权，但网络仍不可用；Token 已安全保存，可稍后直接同步',
          );
        }
        rethrow;
      }
    }
    throw const GitHubAuthNetworkException('暂时无法读取 GitHub 用户信息');
  }

  void _throwIfCancelled(bool Function()? isCancelled) {
    if (isCancelled?.call() == true) {
      throw const GitHubAuthCancelledException();
    }
  }

  bool _isTransient(Object error) =>
      error is http.ClientException ||
      error is SocketException ||
      error is HandshakeException ||
      error is TimeoutException;

  bool _isRetryableStatus(int statusCode) =>
      statusCode == 408 ||
      statusCode == 429 ||
      statusCode == 500 ||
      statusCode == 502 ||
      statusCode == 503 ||
      statusCode == 504;

  Map<String, dynamic> _json(http.Response response) {
    try {
      final value = jsonDecode(response.body);
      return value is Map
          ? Map<String, dynamic>.from(value)
          : <String, dynamic>{};
    } on FormatException {
      return <String, dynamic>{};
    }
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}
