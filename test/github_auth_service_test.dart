import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:netcatty_mobile/infrastructure/sync/github_auth_service.dart';

void main() {
  GitHubDeviceAuthorization authorization() => GitHubDeviceAuthorization(
        deviceCode: 'device-code',
        userCode: 'ABCD-1234',
        verificationUri: Uri.parse('https://github.com/login/device'),
        expiresAt: DateTime.now().add(const Duration(minutes: 1)),
        interval: Duration.zero,
      );

  test('device polling recovers from an aborted mobile connection', () async {
    var requests = 0;
    final states = <GitHubAuthPollState>[];
    final client = MockClient((request) async {
      requests++;
      if (requests == 1) {
        throw http.ClientException('Software caused connection abort');
      }
      if (requests == 2) {
        return http.Response(
          jsonEncode({'error': 'authorization_pending'}),
          200,
        );
      }
      return http.Response(jsonEncode({'access_token': 'token-123'}), 200);
    });
    final service = GitHubAuthService(
      client: client,
      delay: (_) async {},
    );

    final token = await service.poll(
      authorization(),
      onStateChanged: states.add,
    );

    expect(token, 'token-123');
    expect(requests, 3);
    expect(states, contains(GitHubAuthPollState.retryingNetwork));
    expect(states.last, GitHubAuthPollState.waitingForAuthorization);
  });

  test('closing the login dialog cancels polling before a request', () async {
    var requests = 0;
    final service = GitHubAuthService(
      client: MockClient((request) async {
        requests++;
        return http.Response('{}', 200);
      }),
      delay: (_) async {},
    );

    await expectLater(
      service.poll(authorization(), isCancelled: () => true),
      throwsA(isA<GitHubAuthCancelledException>()),
    );
    expect(requests, 0);
  });

  test('user lookup retries a transient connection abort', () async {
    var requests = 0;
    final service = GitHubAuthService(
      client: MockClient((request) async {
        requests++;
        if (requests == 1) {
          throw http.ClientException('Software caused connection abort');
        }
        return http.Response(jsonEncode({'login': 'netcatty-user'}), 200);
      }),
      delay: (_) async {},
    );

    final user = await service.currentUser('token-123');

    expect(user['login'], 'netcatty-user');
    expect(requests, 2);
  });
}
