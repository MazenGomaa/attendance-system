import 'dart:io';

import 'package:flutter/foundation.dart';

/// In-memory ring buffer of log lines, shown on the Debug screen and copied
/// out with "Copy all" so a tester can paste it into a bug report.
class DebugLog extends ChangeNotifier {
  DebugLog._();
  static final DebugLog instance = DebugLog._();

  static const int maxLines = 2000;
  final List<String> _lines = [];
  IOSink? _file;
  String? filePath;

  List<String> get lines => List.unmodifiable(_lines);

  /// Also append every line (including ones too noisy for the screen) to a
  /// file, so a whole lecture can be reviewed afterwards.
  void openFile(String path) {
    _file?.close();
    filePath = path;
    _file = File(path).openWrite(mode: FileMode.append);
    _file!.writeln('===== log opened ${DateTime.now().toIso8601String()} =====');
  }

  static String _stamp() {
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  void addToFileOnly(String source, String message) {
    final stamp = _stamp();
    for (final line in message.split('\n')) {
      if (line.trim().isNotEmpty) _file?.writeln('$stamp [$source] $line');
    }
  }

  void add(String source, String message) {
    final stamp = _stamp();
    for (final line in message.split('\n')) {
      if (line.trim().isEmpty) continue;
      _lines.add('$stamp [$source] $line');
      _file?.writeln('$stamp [$source] $line');
    }
    if (_lines.length > maxLines) {
      _lines.removeRange(0, _lines.length - maxLines);
    }
    debugPrint('[$source] $message');
    notifyListeners();
  }

  void clear() {
    _lines.clear();
    notifyListeners();
  }
}

void log(String source, String message) => DebugLog.instance.add(source, message);

void logToFileOnly(String source, String message) =>
    DebugLog.instance.addToFileOnly(source, message);
