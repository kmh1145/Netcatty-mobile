import 'dart:async';
import 'dart:convert';

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

class GitHubAuthService {
  GitHubAuthService({http.Client? client}) : _client = client ?? http.Client();

  static const clientId = String.fromEnvironment(
    'GITHUB_OAUTH_CLIENT_ID',
    defaultValue: 'Ov23lidR2u8OIkHW19nk',
  );

  final http.Client _client;

  Future<GitHubDeviceAuthorization> start() async {
    final response = await _client.post(
      Uri.parse('https://github.com/login/device/code'),
      headers: const {'accept': 'application/json'},
      body: const {'client_id': clientId, 'scope': 'gist read:user'},
    );
    final json = _json(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError(
          json['error_description']?.toString() ?? 'GitHub 授权启动失败');
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

  Future<String> poll(GitHubDeviceAuthorization authorization) async {
    var interval = authorization.interval;
    while (DateTime.now().isBefore(authorization.expiresAt)) {
      await Future<void>.delayed(interval);
      final response = await _client.post(
        Uri.parse('https://github.com/login/oauth/access_token'),
        headers: const {'accept': 'application/json'},
        body: {
          'client_id': clientId,
          'device_code': authorization.deviceCode,
          'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
        },
      );
      final json = _json(response);
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
      }
    }
    throw StateError('GitHub 验证码已过期，请重新登录');
  }

  Future<Map<String, dynamic>> currentUser(String token) async {
    final response = await _client.get(
      Uri.parse('https://api.github.com/user'),
      headers: {
        'accept': 'application/vnd.github+json',
        'authorization': 'Bearer $token',
        'x-github-api-version': '2022-11-28',
      },
    );
    final json = _json(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw StateError('GitHub 登录状态无效 (${response.statusCode})');
    }
    return json;
  }

  Map<String, dynamic> _json(http.Response response) {
    final value = jsonDecode(response.body);
    return value is Map
        ? Map<String, dynamic>.from(value)
        : <String, dynamic>{};
  }
}
