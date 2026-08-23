import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:netcatty_mobile/infrastructure/update_check_service.dart';

void main() {
  test('matching app and v-prefixed release versions are latest', () async {
    late http.Request captured;
    final service = UpdateCheckService(
      client: MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode({
            'tag_name': 'v1.2.2',
            'html_url':
                'https://github.com/kmh1145/Netcatty-mobile/releases/tag/v1.2.2',
          }),
          200,
        );
      }),
    );

    final result = await service.check('1.2.2');

    expect(captured.url, UpdateCheckService.latestReleaseApi);
    expect(captured.headers['accept'], 'application/vnd.github+json');
    expect(result.currentVersion, '1.2.2');
    expect(result.latestVersion, '1.2.2');
    expect(result.isLatest, isTrue);
    expect(result.updateAvailable, isFalse);
    expect(result.isDevelopmentVersion, isFalse);
    expect(result.releaseUri.path, endsWith('/releases/tag/v1.2.2'));
  });

  test('newer GitHub release is reported as an available update', () async {
    final service = UpdateCheckService(
      client: MockClient((_) async => http.Response(
            jsonEncode({
              'tag_name': 'v1.3.0',
              'html_url':
                  'https://github.com/kmh1145/Netcatty-mobile/releases/tag/v1.3.0',
            }),
            200,
          )),
    );

    final result = await service.check('1.2.2');

    expect(result.isLatest, isFalse);
    expect(result.updateAvailable, isTrue);
    expect(result.isDevelopmentVersion, isFalse);
  });

  test('version newer than public release is treated as development', () async {
    final service = UpdateCheckService(
      client: MockClient((_) async => http.Response(
            jsonEncode({
              'tag_name': 'v1.2.2',
              'html_url': 'https://example.com/untrusted-release',
            }),
            200,
          )),
    );

    final result = await service.check('1.3.0');

    expect(result.isLatest, isFalse);
    expect(result.updateAvailable, isFalse);
    expect(result.isDevelopmentVersion, isTrue);
    expect(result.releaseUri, UpdateCheckService.latestReleasePage);
  });

  test('invalid release response produces a readable error', () async {
    final service = UpdateCheckService(
      client: MockClient((_) async => http.Response('{}', 200)),
    );

    await expectLater(
      service.check('1.2.2'),
      throwsA(
        isA<UpdateCheckException>().having(
          (error) => error.message,
          'message',
          contains('缺少版本号'),
        ),
      ),
    );
  });

  test('prerelease builds are never offered on the stable update channel',
      () async {
    final service = UpdateCheckService(
      client: MockClient((_) async => http.Response(
            jsonEncode({
              'tag_name': 'v9.0.0-beta.1',
              'html_url':
                  'https://github.com/kmh1145/Netcatty-mobile/releases/tag/v9.0.0-beta.1',
              'draft': false,
              'prerelease': true,
            }),
            200,
          )),
    );

    await expectLater(
      service.check('1.3.4'),
      throwsA(
        isA<UpdateCheckException>().having(
          (error) => error.message,
          'message',
          contains('不是正式 Release'),
        ),
      ),
    );
  });

  test('network failure produces a retryable error', () async {
    final service = UpdateCheckService(
      client: MockClient((_) async {
        throw http.ClientException('connection aborted');
      }),
    );

    await expectLater(
      service.check('1.2.2'),
      throwsA(
        isA<UpdateCheckException>().having(
          (error) => error.message,
          'message',
          contains('无法连接 GitHub'),
        ),
      ),
    );
  });

  test('release version comparison follows semantic ordering', () {
    expect(compareReleaseVersions('v1.2.2', '1.2.2'), 0);
    expect(compareReleaseVersions('1.10.0', '1.9.9'), greaterThan(0));
    expect(compareReleaseVersions('2.0', '1.99.99'), greaterThan(0));
    expect(compareReleaseVersions('1.2.2', '1.2.2-beta.1'), greaterThan(0));
    expect(
      compareReleaseVersions('1.2.2-beta.2', '1.2.2-beta.10'),
      lessThan(0),
    );
    expect(compareReleaseVersions('1.2.2+4', '1.2.2+30'), 0);
  });
}
