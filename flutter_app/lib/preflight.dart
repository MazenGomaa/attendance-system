import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'debug_log.dart';
import 'net_probe.dart';
import 'server/logic.dart';
import 'server/model.dart';
import 'server/server.dart';
import 'tunnels.dart';

enum StepStatus { pending, running, ok, warn, fail }

class PreflightStep {
  PreflightStep(this.title);
  final String title;
  StepStatus status = StepStatus.pending;
  String detail = '';
  /// What the UI should offer to fix a failure: battery, notifications, brand.
  String? fix;
}

/// A rehearsal before class: everything a real session needs, end to end,
/// with a throwaway server, one tunnel and a test submission over the public
/// link. Nothing it does touches real sessions or the Downloads folder.
class Preflight extends ChangeNotifier {
  Preflight({
    required this.binary,
    required this.workDir,
    required this.statics,
    required this.deviceInfo,
    this.port = 8001,
    this.rewriteUrl,
    this.tunnelWait = const Duration(seconds: 45),
    this.reachWait = const Duration(seconds: 90),
    this.firstTryDelay = const Duration(seconds: 8),
  });

  final String binary;
  final String workDir;
  final Map<String, StaticFile> statics;
  final Future<Map<String, Object?>> Function() deviceInfo;
  final int port;
  /// Tests only: map the tunnel URL to a reachable address.
  final String Function(String url)? rewriteUrl;
  final Duration tunnelWait;
  final Duration reachWait;
  /// A new link isn't live the instant cloudflared prints it.
  final Duration firstTryDelay;

  late final PreflightStep cloudflared = PreflightStep('cloudflared runs on this phone');
  late final PreflightStep battery = PreflightStep('Battery optimisation off');
  late final PreflightStep notifications = PreflightStep('Notifications allowed');
  late final PreflightStep tunnel = PreflightStep('Tunnel comes up');
  late final PreflightStep page = PreflightStep('Student page loads through the public link');
  late final PreflightStep submit = PreflightStep('A test submission is recorded');
  List<PreflightStep> get steps => [cloudflared, battery, notifications, tunnel, page, submit];

  bool running = false;
  bool get passed => steps.every((s) => s.status == StepStatus.ok || s.status == StepStatus.warn);

  void _set(PreflightStep s, StepStatus st, [String detail = '', String? fix]) {
    s
      ..status = st
      ..detail = detail
      ..fix = fix;
    log('preflight', '${s.title}: ${st.name}${detail.isEmpty ? '' : ' — $detail'}');
    notifyListeners();
  }

  Future<void> run() async {
    if (running) return;
    running = true;
    for (final s in steps) {
      _set(s, StepStatus.pending);
    }
    AttendanceServer? srv;
    TunnelManager? tm;
    try {
      // 1. The bundled binary runs.
      _set(cloudflared, StepStatus.running);
      try {
        final r = await Process.run(binary, ['--version']).timeout(const Duration(seconds: 15));
        final out = '${r.stdout}${r.stderr}'.trim().split('\n').first;
        _set(cloudflared, r.exitCode == 0 ? StepStatus.ok : StepStatus.fail, out);
      } catch (e) {
        _set(cloudflared, StepStatus.fail, '$e');
      }

      // 2-3. Phone settings.
      final info = await deviceInfo();
      _set(battery, info['batteryOptimizationIgnored'] == true ? StepStatus.ok : StepStatus.fail,
          info['batteryOptimizationIgnored'] == true ? '' : 'Android may pause the session '
              'with the screen off', 'battery');
      _set(notifications, info['notificationsGranted'] == true ? StepStatus.ok : StepStatus.warn,
          info['notificationsGranted'] == true ? '' : "You won't get link-changed alerts",
          'notifications');
      if (cloudflared.status != StepStatus.ok) {
        _set(tunnel, StepStatus.fail, 'skipped: cloudflared does not run');
        _set(page, StepStatus.fail, 'skipped');
        _set(submit, StepStatus.fail, 'skipped');
        return;
      }

      // 4. Throwaway server + one tunnel.
      _set(tunnel, StepStatus.running, 'starting…');
      final dir = Directory('$workDir/preflight')..createSync(recursive: true);
      final cfg = ServerConfig()
        ..courseName = 'Pre-class check'
        ..pageSecret = randomHex()
        ..geofence = false;   // the phone itself can't prove it's in the hall
      srv = AttendanceServer(config: cfg, statics: statics, exportDir: '${dir.path}/exports');
      await srv.start(port: port);
      tm = TunnelManager(binary: binary, homeDir: workDir, localPort: port,
          checkEvery: const Duration(hours: 1));
      final sw = Stopwatch()..start();
      await tm.start(1);
      final t = tm.tunnels.single;
      while (t.url == null && sw.elapsed < tunnelWait && t.state != TunnelState.failed) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      if (t.url == null) {
        _set(tunnel, StepStatus.fail, t.lastError ?? 'no link after ${tunnelWait.inSeconds} s; '
            'check the internet connection');
        _set(page, StepStatus.fail, 'skipped');
        _set(submit, StepStatus.fail, 'skipped');
        return;
      }
      _set(tunnel, StepStatus.ok, '${t.url} in ${sw.elapsed.inSeconds} s');

      // 5. The student page loads from outside (new links can take a few
      // seconds before they resolve, so retry for a while).
      final base = rewriteUrl?.call(t.url!) ?? t.url!;
      _set(page, StepStatus.running, 'waiting for the link to go live…');
      await Future<void>.delayed(firstTryDelay);
      // Resolves the new hostname via Cloudflare DoH, so an early lookup
      // cached as "no such host" on this phone can't fail the check.
      final client = tunnelHttpClient();
      try {
        final reach = Stopwatch()..start();
        String? err;
        var ok = false;
        while (!ok && reach.elapsed < reachWait) {
          try {
            final rt = Stopwatch()..start();
            final req = await client.getUrl(Uri.parse('$base/'));
            final res = await req.close().timeout(const Duration(seconds: 15));
            final body = await utf8.decodeStream(res);
            ok = res.statusCode == 200 && body.contains('/static/index.js');
            if (ok) {
              _set(page, StepStatus.ok, 'loaded in ${rt.elapsedMilliseconds} ms');
            } else {
              err = 'HTTP ${res.statusCode}';
            }
          } catch (e) {
            err = '$e';
          }
          if (!ok) await Future<void>.delayed(const Duration(seconds: 3));
        }
        if (!ok) {
          _set(page, StepStatus.fail, 'not reachable after ${reachWait.inSeconds} s: $err');
          _set(submit, StepStatus.fail, 'skipped');
          return;
        }

        // 6. A real submission round trip through the public link.
        _set(submit, StepStatus.running);
        Future<Map<String, Object?>> post(String path, Map<String, Object?> body) async {
          final req = await client.postUrl(Uri.parse('$base$path'));
          req.headers.contentType = ContentType.json;
          req.write(jsonEncode(body));
          final res = await req.close().timeout(const Duration(seconds: 15));
          return (jsonDecode(await utf8.decodeStream(res)) as Map).cast<String, Object?>();
        }
        final device = 'preflight-${randomHex(6)}';
        final init = await post('/api/init', {'deviceId': device});
        final res = await post('/submit', {
          'id': '1', 'name': 'اختبار اختبار اختبار اختبار', 'deviceId': device,
          'page_token': init['page_token'],
        });
        if (res['ok'] == true && srv.store.records.length == 1) {
          _set(submit, StepStatus.ok, 'recorded (test data discarded)');
        } else {
          _set(submit, StepStatus.fail, '${res['error'] ?? res}');
        }
      } finally {
        client.close(force: true);
      }
    } catch (e) {
      for (final s in steps.where((s) => s.status == StepStatus.running)) {
        _set(s, StepStatus.fail, '$e');
      }
    } finally {
      await tm?.stop();
      await srv?.stop(export: false);
      try {
        Directory('$workDir/preflight').deleteSync(recursive: true);
      } catch (_) {}
      running = false;
      notifyListeners();
    }
  }
}
