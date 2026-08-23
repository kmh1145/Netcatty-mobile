import 'dart:convert';
import 'dart:io' as io;

import 'package:aws_common/aws_common.dart';
import 'package:aws_signature_v4/aws_signature_v4.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../../domain/models/settings.dart';

class S3ObjectResponse {
  const S3ObjectResponse({
    required this.body,
    required this.revision,
  });

  final String body;
  final String? revision;
}

/// Minimal S3 object client matching desktop Netcatty's S3 configuration.
/// Requests are signed with AWS Signature Version 4 and work with AWS S3,
/// MinIO and other compatible object stores.
class S3SyncClient {
  S3SyncClient({required http.Client client}) : _client = client;

  static const vaultFileName = 'netcatty-vault.json';

  final http.Client _client;

  Future<S3ObjectResponse?> getVault(SyncConnection connection) async {
    final response = await _send(
      connection,
      method: AWSHttpMethod.get,
      objectKey: _vaultKey(connection),
    );
    if (response.statusCode == 404) return null;
    _ensureSuccess(response, 'S3 云端读取失败');
    return S3ObjectResponse(
      body: response.body,
      revision: response.headers['etag'],
    );
  }

  Future<String?> putVault(
    SyncConnection connection,
    String body,
  ) async {
    final response = await _send(
      connection,
      method: AWSHttpMethod.put,
      objectKey: _vaultKey(connection),
      body: utf8.encode(body),
      headers: const {'content-type': 'application/json; charset=utf-8'},
    );
    _ensureSuccess(response, 'S3 云端写入失败');
    return response.headers['etag'];
  }

  Future<void> testConnection(SyncConnection connection) async {
    final response = await _send(
      connection,
      method: AWSHttpMethod.head,
    );
    _ensureSuccess(response, 'S3 连接测试失败');
  }

  Future<http.Response> _send(
    SyncConnection connection, {
    required AWSHttpMethod method,
    String? objectKey,
    List<int> body = const [],
    Map<String, String> headers = const {},
  }) async {
    _validate(connection);
    final uri = _requestUri(connection, objectKey: objectKey);
    final credentials = AWSCredentials(
      connection.accessKeyId!.trim(),
      connection.secret!,
      _optional(connection.sessionToken),
    );
    final signer = AWSSigV4Signer(
      credentialsProvider: AWSCredentialsProvider(credentials),
    );
    final signed = await signer.sign(
      AWSHttpRequest(
        method: method,
        uri: uri,
        headers: headers,
        body: body,
      ),
      credentialScope: AWSCredentialScope(
        region: connection.region!.trim(),
        service: AWSService.s3,
      ),
      serviceConfiguration: S3ServiceConfiguration(),
    );
    final request = http.Request(method.value, signed.uri)
      ..headers.addAll(Map<String, String>.from(signed.headers)
        ..remove('host')
        ..remove('content-length'))
      ..bodyBytes = body;

    if (!connection.allowInsecure) {
      return http.Response.fromStream(await _client.send(request));
    }

    final native = io.HttpClient()
      ..badCertificateCallback =
          (io.X509Certificate certificate, String host, int port) => true;
    final insecureClient = IOClient(native);
    try {
      return http.Response.fromStream(await insecureClient.send(request));
    } finally {
      insecureClient.close();
    }
  }

  Uri _requestUri(
    SyncConnection connection, {
    String? objectKey,
  }) {
    final endpoint = _endpoint(connection);
    final bucket = connection.bucket!.trim();
    final endpointSegments = endpoint.pathSegments
        .where((segment) => segment.isNotEmpty)
        .toList(growable: true);
    final keySegments =
        objectKey?.split('/').where((segment) => segment.isNotEmpty).toList() ??
            const <String>[];

    if (connection.forcePathStyle) {
      return endpoint.replace(
        pathSegments: [...endpointSegments, bucket, ...keySegments],
        query: null,
        fragment: null,
      );
    }
    return endpoint.replace(
      host: '$bucket.${endpoint.host}',
      pathSegments: [...endpointSegments, ...keySegments],
      query: null,
      fragment: null,
    );
  }

  Uri _endpoint(SyncConnection connection) {
    final value = connection.endpoint.trim();
    final normalized = RegExp(
      r'^https?://',
      caseSensitive: false,
    ).hasMatch(value)
        ? value
        : 'https://$value';
    final endpoint = Uri.tryParse(normalized);
    if (endpoint == null || endpoint.host.isEmpty) {
      throw StateError('S3 Endpoint 无效');
    }
    if (endpoint.scheme != 'https' && !connection.allowInsecure) {
      throw StateError('S3 Endpoint 必须使用 HTTPS，或明确启用不安全连接');
    }
    return endpoint;
  }

  String _vaultKey(SyncConnection connection) {
    final prefix =
        connection.prefix?.trim().replaceAll(RegExp(r'^/+|/+$'), '') ?? '';
    return prefix.isEmpty ? vaultFileName : '$prefix/$vaultFileName';
  }

  void _validate(SyncConnection connection) {
    _endpoint(connection);
    if (connection.region?.trim().isNotEmpty != true) {
      throw StateError('请填写 S3 Region');
    }
    if (connection.bucket?.trim().isNotEmpty != true) {
      throw StateError('请填写 S3 Bucket');
    }
    if (connection.accessKeyId?.trim().isNotEmpty != true) {
      throw StateError('请填写 S3 Access Key ID');
    }
    if (connection.secret?.isNotEmpty != true) {
      throw StateError('请填写 S3 Secret Access Key');
    }
  }

  void _ensureSuccess(http.Response response, String label) {
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    var detail = _xmlValue(response.body, 'Message');
    final code = _xmlValue(response.body, 'Code');
    if (code.isNotEmpty) detail = '$code${detail.isEmpty ? '' : ': $detail'}';
    if (detail.length > 240) detail = '${detail.substring(0, 240)}…';
    final requestId = response.headers['x-amz-request-id'];
    throw StateError(
      '$label (${response.statusCode})'
      '${detail.isEmpty ? '' : '：$detail'}'
      '${requestId?.isNotEmpty == true ? ' · Request ID $requestId' : ''}',
    );
  }

  String _xmlValue(String body, String name) {
    final match = RegExp(
      '<$name>([\\s\\S]*?)</$name>',
      caseSensitive: false,
    ).firstMatch(body);
    if (match == null) return '';
    return match
        .group(1)!
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&amp;', '&')
        .trim();
  }

  String? _optional(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }
}
