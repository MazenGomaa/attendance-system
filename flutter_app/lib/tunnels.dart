import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'debug_log.dart';

/// Matches the public Quick Tunnel URL in cloudflared's output. Skips
/// api.trycloudflare.com: that's the endpoint cloudflared calls to *request* a
/// tunnel, and it appears in the error line when that request fails.
final RegExp tunnelUrlPattern =
    RegExp(r'https://(?!api\.)[-\w]+\.trycloudflare\.com');

String? parseTunnelUrl(String line) => tunnelUrlPattern.firstMatch(line)?.group(0);

enum TunnelState { starting, up, restarting, failed, stopped }

class Tunnel {
  Tunnel(this.index);
  final int index;
  TunnelState state = TunnelState.starting;
  String? url;
  String? lastError;
  int restarts = 0;
  int checksOk = 0;
  int checksFailed = 0;
  int? lastLatencyMs;
  DateTime? lastCheck;
  Process? process;
}

/// Runs 1–4 cloudflared Quick Tunnels pointing at the local server, restarts
/// any that exit, and health-checks each public URL once a minute by fetching
/// it from the phone itself (through Cloudflare and back).
class TunnelManager extends ChangeNotifier {
  TunnelManager({required this.binary, required this.homeDir, required this.localPort});

  final String binary;
  final String homeDir;
  final int localPort;
  static const int maxRestarts = 5;
  static const Duration checkEvery = Duration(seconds: 60);

  final List<Tunnel> tunnels = [];
  Timer? _checkTimer;
  bool _running = false;

  bool get running => _running;

  Future<void> start(int count) async {
    if (_running) return;
    _running = true;
    tunnels
      ..clear()
      ..addAll(List.generate(count, (i) => Tunnel(i + 1)));
    for (final t in tunnels) {
      await _launch(t);
    }
    _checkTimer = Timer.periodic(checkEvery, (_) => checkAll());
    notifyListeners();
  }

  Future<void> _launch(Tunnel t) async {
    t.state = t.restarts == 0 ? TunnelState.starting : TunnelState.restarting;
    t.url = null;
    notifyListeners();
    final args = [
      'tunnel', '--no-autoupdate',
      // http2 over TCP/443: many campus/mobile networks block QUIC's UDP 7844.
      '--protocol', 'http2',
      '--url', 'http://127.0.0.1:$localPort',
    ];
    log('tunnel${t.index}', 'starting: $binary ${args.join(' ')}');
    try {
      final p = await Process.start(binary, args,
          environment: {'HOME': homeDir}, workingDirectory: homeDir);
      t.process = p;
      void onLine(String line) {
        log('cf${t.index}', line);
        final url = parseTunnelUrl(line);
        if (url != null && t.url == null) {
          t.url = url;
          t.state = TunnelState.up;
          log('tunnel${t.index}', 'URL: $url');
          notifyListeners();
        } else if (line.contains(' ERR ') || line.contains('failed')) {
          t.lastError = line.trim();
          notifyListeners();
        }
      }
      p.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(onLine);
      p.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(onLine);
      unawaited(p.exitCode.then((code) => _onExit(t, p, code)));
    } catch (e) {
      t.state = TunnelState.failed;
      t.lastError = 'could not start cloudflared: $e';
      log('tunnel${t.index}', t.lastError!);
      notifyListeners();
    }
  }

  void _onExit(Tunnel t, Process p, int code) {
    if (t.process != p) return;   // an older process we already replaced
    log('tunnel${t.index}', 'cloudflared exited with code $code');
    t.process = null;
    if (!_running) {
      t.state = TunnelState.stopped;
    } else if (t.restarts < maxRestarts) {
      t.restarts++;
      t.state = TunnelState.restarting;
      log('tunnel${t.index}', 'restarting in 5 s (attempt ${t.restarts}/$maxRestarts)');
      Timer(const Duration(seconds: 5), () {
        if (_running) _launch(t);
      });
    } else {
      t.state = TunnelState.failed;
      log('tunnel${t.index}', 'giving up after $maxRestarts restarts');
    }
    notifyListeners();
  }

  /// Fetch each tunnel's /ping from the phone itself. Proves the public URL
  /// works end to end without needing a second device.
  Future<void> checkAll() async {
    for (final t in tunnels) {
      final url = t.url;
      if (url == null) continue;
      final sw = Stopwatch()..start();
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
      try {
        final req = await client.getUrl(Uri.parse('$url/ping'));
        final res = await req.close().timeout(const Duration(seconds: 20));
        await res.drain<void>();
        if (res.statusCode == 200) {
          t.checksOk++;
          t.lastLatencyMs = sw.elapsedMilliseconds;
          log('check${t.index}', 'OK ${res.statusCode} in ${sw.elapsedMilliseconds} ms');
        } else {
          t.checksFailed++;
          log('check${t.index}', 'FAILED: HTTP ${res.statusCode}');
        }
      } catch (e) {
        t.checksFailed++;
        log('check${t.index}', 'FAILED: $e');
      } finally {
        client.close(force: true);
        t.lastCheck = DateTime.now();
      }
    }
    notifyListeners();
  }

  Future<void> stop() async {
    _running = false;
    _checkTimer?.cancel();
    _checkTimer = null;
    for (final t in tunnels) {
      t.process?.kill();
      t.state = TunnelState.stopped;
    }
    notifyListeners();
  }
}
