import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'debug_log.dart';
import 'net_probe.dart';

/// Matches the public Quick Tunnel URL in cloudflared's output. Skips
/// api.trycloudflare.com: that's the endpoint cloudflared calls to *request* a
/// tunnel, and it appears in the error line when that request fails.
final RegExp tunnelUrlPattern =
    RegExp(r'https://(?!api\.)[-\w]+\.trycloudflare\.com');

String? parseTunnelUrl(String line) => tunnelUrlPattern.firstMatch(line)?.group(0);

/// cloudflared lines that are expected on Android and harmless: a few optional
/// features use Go's built-in resolver, which looks for a DNS server at
/// [::1]:53 because Android has no /etc/resolv.conf; they just turn
/// themselves off. Tunnel traffic itself resolves fine (its own precheck says
/// "DNS Resolution PASS"). ICMP proxying needs a sysctl apps can't read.
const _knownHarmless = [
  'Failed to initialize DNS local resolver',
  'Failed to fetch features',
  'ping_group_range',
];

bool isHarmlessCfLine(String line) => _knownHarmless.any(line.contains);

/// cloudflared is chatty (banners, precheck tables). Keep only lines worth
/// reading in the on-screen log: errors/warnings that matter, the URL,
/// connection changes, and shutdown.
bool isInterestingCfLine(String line) {
  if (isHarmlessCfLine(line)) return false;
  return line.contains(' ERR ') ||
      line.contains(' WRN ') ||
      line.contains('trycloudflare.com') ||
      line.contains('Registered tunnel connection') ||
      line.contains('Unregistered tunnel connection') ||
      line.contains('Retrying') ||
      line.contains('Tunnel server stopped') ||
      line.contains('Version ');
}

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
  /// The link the professor has shared (first URL, or the last acknowledged
  /// one). A Quick Tunnel gets a brand-new URL every time it restarts.
  String? sharedUrl;
  /// True when [url] differs from [sharedUrl]: students holding the old QR
  /// can't reach the session until the new one is shared.
  bool get linkChanged => url != null && sharedUrl != null && url != sharedUrl;
  int failStreak = 0;
  int okStreak = 0;
  DateTime? upSince;
}

/// Runs 1–4 cloudflared Quick Tunnels pointing at the local server, restarts
/// any that exit, and health-checks each public URL once a minute by fetching
/// it from the phone itself (through Cloudflare and back).
class TunnelManager extends ChangeNotifier {
  TunnelManager({
    required this.binary,
    required this.homeDir,
    required this.localPort,
    this.checkEvery = const Duration(seconds: 30),
    this.quickRetryDelay = const Duration(seconds: 5),
    this.slowRetryDelay = const Duration(seconds: 60),
    this.probe,
    this.onLinkChanged,
    this.graceAfterUp = const Duration(seconds: 90),
  });

  final String binary;
  final String homeDir;
  final int localPort;
  final Duration checkEvery;
  final Duration quickRetryDelay;
  final Duration slowRetryDelay;
  /// Overrides the public-URL health probe (tests). Returns true if reachable.
  final Future<bool> Function(String url)? probe;
  /// Called when a restarted tunnel comes back with a different link.
  final void Function(Tunnel t)? onLinkChanged;
  /// A fresh link may not be reachable yet: failed checks in this window
  /// after it appears are logged but never trigger a restart.
  final Duration graceAfterUp;
  /// Quick retries before slowing down; a tunnel is never given up on while
  /// the session runs (giving up mid-lecture helps nobody).
  static const int quickRestarts = 5;
  /// Consecutive failed health checks before a live-but-unreachable tunnel
  /// is restarted.
  static const int failLimit = 3;
  /// Consecutive good checks that earn back the quick-retry budget.
  static const int healthyResetAfter = 10;

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
        // Everything goes to the session log file; the screen gets the gist.
        logToFileOnly('cf${t.index}', line);
        if (isInterestingCfLine(line)) log('cf${t.index}', line);
        final url = parseTunnelUrl(line);
        if (url != null && t.url == null) {
          t.url = url;
          t.state = TunnelState.up;
          t.failStreak = 0;
          t.upSince = DateTime.now();
          t.sharedUrl ??= url;
          log('tunnel${t.index}', 'URL: $url');
          if (t.linkChanged) {
            log('tunnel${t.index}', 'WARNING: link changed from ${t.sharedUrl} to $url — '
                'students need the new QR');
            onLinkChanged?.call(t);
          }
          notifyListeners();
        } else if ((line.contains(' ERR ') || line.contains('failed')) &&
            !isHarmlessCfLine(line)) {
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
    } else {
      t.restarts++;
      t.state = TunnelState.restarting;
      final delay = t.restarts <= quickRestarts ? quickRetryDelay : slowRetryDelay;
      log('tunnel${t.index}', 'restarting in ${delay.inSeconds} s (attempt ${t.restarts})');
      Timer(delay, () {
        if (_running && t.process == null) _launch(t);
      });
    }
    notifyListeners();
  }

  /// The professor has shared the current link: stop warning about it.
  void acknowledgeLink(Tunnel t) {
    t.sharedUrl = t.url;
    notifyListeners();
  }

  void acknowledgeAll() {
    for (final t in tunnels) {
      if (t.url != null) t.sharedUrl = t.url;
    }
    notifyListeners();
  }

  bool get anyLinkChanged => tunnels.any((t) => t.linkChanged);

  Future<bool> _defaultProbe(String url) async {
    // Resolves via Cloudflare DoH, not the phone's (possibly poisoned) cache.
    final client = tunnelHttpClient();
    try {
      // /favicon.ico answers 204 with no body: the cheapest end-to-end probe.
      final req = await client.getUrl(Uri.parse('$url/favicon.ico'));
      final res = await req.close().timeout(const Duration(seconds: 20));
      await res.drain<void>();
      return res.statusCode == 204 || res.statusCode == 200;
    } finally {
      client.close(force: true);
    }
  }

  /// Fetch each tunnel's public URL from the phone itself (through Cloudflare
  /// and back). A tunnel whose process is alive but unreachable for
  /// [failLimit] checks in a row is restarted.
  Future<void> checkAll() async {
    for (final t in tunnels) {
      final url = t.url;
      if (url == null || t.state != TunnelState.up) continue;
      final sw = Stopwatch()..start();
      bool ok;
      String? why;
      try {
        ok = await (probe ?? _defaultProbe)(url);
      } catch (e) {
        ok = false;
        why = '$e';
      }
      t.lastCheck = DateTime.now();
      if (ok) {
        t.checksOk++;
        t.failStreak = 0;
        t.okStreak++;
        t.lastLatencyMs = sw.elapsedMilliseconds;
        if (t.okStreak >= healthyResetAfter && t.restarts > 0) {
          t.restarts = 0;   // healthy for a while: earn back quick retries
        }
        logToFileOnly('check${t.index}', 'OK in ${sw.elapsedMilliseconds} ms');
      } else if (why != null && why.contains('Failed host lookup')) {
        // Only this phone can't resolve its own link (e.g. a cached "no such
        // host" from looking too early, with 1.1.1.1 blocked on this network).
        // Students use other resolvers, so this says nothing about the
        // tunnel: don't count it toward a restart.
        t.checksFailed++;
        t.okStreak = 0;
        log('check${t.index}', "phone can't look up its own link yet (DNS); not restarting");
      } else {
        t.checksFailed++;
        t.okStreak = 0;
        t.failStreak++;
        log('check${t.index}', 'FAILED (${t.failStreak} in a row)${why == null ? '' : ': $why'}');
        final young = t.upSince != null &&
            DateTime.now().difference(t.upSince!) < graceAfterUp;
        if (t.failStreak >= failLimit && t.process != null && !young) {
          log('tunnel${t.index}', 'unreachable for $failLimit checks — restarting it');
          t.failStreak = 0;
          t.lastError = 'restarted: public link unreachable';
          t.process!.kill();   // exit -> _onExit -> restart
        }
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
