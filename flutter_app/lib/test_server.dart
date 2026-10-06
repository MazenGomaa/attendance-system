import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'debug_log.dart';

/// Phase 0 stand-in for the attendance server: proves a Dart HTTP server in the
/// app can be reached through cloudflared. Replaced by the real server in Phase 1.
class TestServer extends ChangeNotifier {
  TestServer(this.port);
  final int port;
  HttpServer? _server;
  DateTime? startedAt;
  int hits = 0;
  int pings = 0;

  bool get running => _server != null;

  Future<void> start() async {
    if (_server != null) return;
    // Loopback only: cloudflared runs on the same phone, nobody else needs it.
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    startedAt = DateTime.now();
    log('server', 'listening on 127.0.0.1:$port');
    _server!.listen(_handle, onError: (Object e) => log('server', 'error: $e'));
    notifyListeners();
  }

  void _handle(HttpRequest req) {
    final up = DateTime.now().difference(startedAt!);
    if (req.uri.path == '/ping') {
      pings++;
      req.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({'ok': true, 'uptime_s': up.inSeconds}));
    } else {
      hits++;
      log('server', '${req.method} ${req.uri.path} (visit #$hits)');
      req.response
        ..headers.contentType = ContentType.html
        ..write('<!doctype html><meta charset="utf-8">'
            '<meta name="viewport" content="width=device-width,initial-scale=1">'
            '<title>Attendance Host test</title>'
            '<body style="font-family:sans-serif;background:#0f1620;color:#eef3f8;'
            'display:flex;align-items:center;justify-content:center;min-height:90vh">'
            '<div style="text-align:center"><h1>✅ It works</h1>'
            '<p>Served by the Attendance Host app on the phone.</p>'
            '<p>Visit #$hits · server up ${up.inMinutes} min</p></div>');
    }
    req.response.close();
    notifyListeners();
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    log('server', 'stopped');
    notifyListeners();
  }
}
