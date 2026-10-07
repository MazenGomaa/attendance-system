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

  /// Heads-up alert the professor must act on (separate from the ongoing one).
  static Future<void> alert(String title, String text) =>
      _ch.invokeMethod('alert', {'title': title, 'text': text});

  static Future<void> requestNotifications() => _ch.invokeMethod('requestNotifications');

  static Future<void> requestBatteryExemption() =>
      _ch.invokeMethod('requestBatteryExemption');

  /// Saves a PNG into Pictures/Attendance; returns the saved location.
  static Future<String> saveImage(Uint8List bytes, String name) async =>
      (await _ch.invokeMethod<String>('saveImage', {'bytes': bytes, 'name': name}))!;

  /// Copies an exported file into Download/Attendance; returns where it went.
  static Future<String> saveToDownloads(String path, {String mime = 'text/csv'}) async =>
      (await _ch.invokeMethod<String>('saveToDownloads', {'path': path, 'mime': mime}))!;

  /// System file picker; returns (name, bytes) or null if cancelled.
  static Future<(String, Uint8List)?> pickTextFile() async {
    final m = await _ch.invokeMapMethod<String, Object?>('pickTextFile');
    if (m == null) return null;
    return (m['name'] as String, m['bytes'] as Uint8List);
  }

  /// kind: "app", "notifications" or "brand"; returns what was opened.
  static Future<String> openSettings(String kind) async =>
      (await _ch.invokeMethod<String>('openSettings', {'kind': kind})) ?? 'none';

  static Future<void> openUrl(String url) => _ch.invokeMethod('openUrl', {'url': url});

  /// This phone's best location within ~20 s: {lat, lng, acc, provider} or
  /// {error: denied | off | none}. Asks for the permission if needed.
  static Future<Map<String, Object?>> currentLocation() async {
    final m = await _ch.invokeMapMethod<String, Object?>('currentLocation');
    return m ?? const {'error': 'none'};
  }

  static Future<Map<String, Object?>> deviceInfo() async {
    final m = await _ch.invokeMapMethod<String, Object?>('deviceInfo');
    return m ?? const {};
  }
}
