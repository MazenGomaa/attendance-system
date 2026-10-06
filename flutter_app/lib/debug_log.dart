import 'package:flutter/foundation.dart';

/// In-memory ring buffer of log lines, shown on the Debug screen and copied
/// out with "Copy all" so a tester can paste it into a bug report.
class DebugLog extends ChangeNotifier {
  DebugLog._();
  static final DebugLog instance = DebugLog._();

  static const int maxLines = 500;
  final List<String> _lines = [];

  List<String> get lines => List.unmodifiable(_lines);

  void add(String source, String message) {
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp = '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
    for (final line in message.split('\n')) {
      if (line.trim().isEmpty) continue;
      _lines.add('$stamp [$source] $line');
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
