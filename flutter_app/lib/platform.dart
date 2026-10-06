import 'package:flutter/services.dart';

/// Dart side of the "attendance/host" channel implemented in MainActivity.kt.
class HostPlatform {
  static const _ch = MethodChannel('attendance/host');

  static Future<Map<String, String>> paths() async {
    final m = await _ch.invokeMapMethod<String, String>('paths');
    return m ?? const {};
  }

  static Future<void> startService(String text) =>
      _ch.invokeMethod('startService', {'text': text});

  static Future<void> stopService() => _ch.invokeMethod('stopService');

  static Future<void> updateNotification(String text) =>
      _ch.invokeMethod('updateNotification', {'text': text});

  static Future<void> requestNotifications() => _ch.invokeMethod('requestNotifications');

  static Future<void> requestBatteryExemption() =>
      _ch.invokeMethod('requestBatteryExemption');

  static Future<Map<String, Object?>> deviceInfo() async {
    final m = await _ch.invokeMapMethod<String, Object?>('deviceInfo');
    return m ?? const {};
  }
}
