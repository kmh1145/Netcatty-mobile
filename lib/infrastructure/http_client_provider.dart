import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

/// One application-scoped HTTP client. Services receive it explicitly so
/// sockets are reused and closed exactly once with the provider container.
final httpClientProvider = Provider<http.Client>((ref) {
  final client = TimeoutHttpClient(
    http.Client(),
    timeout: const Duration(seconds: 25),
  );
  ref.onDispose(client.close);
  return client;
});

class TimeoutHttpClient extends http.BaseClient {
  TimeoutHttpClient(this._inner, {required this.timeout});

  final http.Client _inner;
  final Duration timeout;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _inner.send(request).timeout(timeout);

  @override
  void close() => _inner.close();
}
