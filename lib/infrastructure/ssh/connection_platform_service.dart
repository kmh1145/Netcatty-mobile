import 'package:flutter/services.dart';

class ConnectionPlatformService {
  const ConnectionPlatformService._();

  static const _channel = MethodChannel('app.netcatty.mobile/connection');

  static Future<void> setActive(bool active) async {
    try {
      await _channel.invokeMethod<void>('setActive', {'active': active});
    } on MissingPluginException {
      // Desktop/test builds do not need a mobile keepalive service.
    }
  }

  static Future<void> beginBackgroundGrace() async {
    try {
      await _channel.invokeMethod<void>('beginBackgroundGrace');
    } on MissingPluginException {
      // No-op outside iOS.
    }
  }

  static Future<void> endBackgroundGrace() async {
    try {
      await _channel.invokeMethod<void>('endBackgroundGrace');
    } on MissingPluginException {
      // No-op outside iOS.
    }
  }
}
