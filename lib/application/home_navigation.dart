import 'package:flutter_riverpod/flutter_riverpod.dart';

final homeTabProvider = StateProvider<int>((ref) => 0);

final sftpNavigationRequestProvider =
    StateProvider<SftpNavigationRequest?>((ref) => null);

class SftpNavigationRequest {
  const SftpNavigationRequest({
    required this.sessionId,
    required this.filePath,
  });

  final String sessionId;
  final String filePath;
}
