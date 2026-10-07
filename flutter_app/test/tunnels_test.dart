import 'dart:io';

import 'package:attendance_host/net_probe.dart';
import 'package:attendance_host/tunnels.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('picks the tunnel URL, never the api endpoint from an error line', () {
    expect(parseTunnelUrl('INF |  https://brave-lion-quick.trycloudflare.com  |'),
        'https://brave-lion-quick.trycloudflare.com');
    expect(parseTunnelUrl('ERR failed to request quick Tunnel: Post '
        '"https://api.trycloudflare.com/tunnel": dial tcp: lookup api.trycloudflare.com '
        'on [::1]:53: connection refused'), isNull);
  });

  test('filters cloudflared noise but keeps what matters', () {
    // Real lines from a Samsung SM-S928B (Android 16) run.
    const ts = '2026-10-06T22:10:49Z';
    const dnsNoise = '$ts ERR Failed to initialize DNS local resolver error="lookup '
        'region1.v2.argotunnel.com on [::1]:53: connection refused"';
    expect(isHarmlessCfLine(dnsNoise), isTrue);
    expect(isInterestingCfLine(dnsNoise), isFalse);
    expect(isInterestingCfLine('$ts INF |  https://a-b.trycloudflare.com  |'), isTrue);
    expect(isInterestingCfLine('$ts INF Registered tunnel connection connIndex=0'), isTrue);
    expect(isInterestingCfLine('$ts ERR Connection terminated connIndex=0'), isTrue);
    expect(isInterestingCfLine('$ts INF |  DNS Resolution  region1  PASS  |'), isFalse);
  });

  test('starts a fake cloudflared, reads its URL, restarts it when it dies', () async {
    final dir = await Directory.systemTemp.createTemp('cf');
    final fake = File('${dir.path}/cloudflared');
    // First run prints a URL then exits; later runs print a URL and stay up.
    await fake.writeAsString('''#!/bin/sh
if [ ! -f "\$HOME/ran" ]; then touch "\$HOME/ran"
  echo "INF |  https://first-run.trycloudflare.com  |"; sleep 1; exit 1
fi
echo "INF |  https://second-run.trycloudflare.com  |"; sleep 30
''');
    await Process.run('chmod', ['+x', fake.path]);
    final tm = TunnelManager(binary: fake.path, homeDir: dir.path, localPort: 8000);
    await tm.start(1);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(tm.tunnels.single.url, 'https://first-run.trycloudflare.com');
    await Future<void>.delayed(const Duration(seconds: 7));   // exit + 5 s backoff
    expect(tm.tunnels.single.restarts, 1);
    expect(tm.tunnels.single.url, 'https://second-run.trycloudflare.com');
    expect(tm.tunnels.single.state, TunnelState.up);
    // The QR already shared points at the first link: flag it until acknowledged.
    expect(tm.tunnels.single.linkChanged, isTrue);
    expect(tm.anyLinkChanged, isTrue);
    tm.acknowledgeAll();
    expect(tm.tunnels.single.linkChanged, isFalse);
    await tm.stop();
    await dir.delete(recursive: true);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('restarts a live but unreachable tunnel and reports the new link', () async {
    final dir = await Directory.systemTemp.createTemp('cf');
    final fake = File('${dir.path}/cloudflared');
    // Every run prints a new URL (run-1, run-2, ...) and stays up.
    await fake.writeAsString('''#!/bin/sh
n=\$(cat "\$HOME/n" 2>/dev/null || echo 0); n=\$((n+1)); echo \$n > "\$HOME/n"
echo "INF |  https://run-\$n.trycloudflare.com  |"
echo "INF Registered tunnel connection connIndex=0"; sleep 30
''');
    await Process.run('chmod', ['+x', fake.path]);
    final changed = <String>[];
    var reachable = false;
    final tm = TunnelManager(
      binary: fake.path, homeDir: dir.path, localPort: 8000,
      checkEvery: const Duration(milliseconds: 150),
      quickRetryDelay: const Duration(milliseconds: 100),
      probe: (url) async => reachable,
      onLinkChanged: (t) => changed.add(t.url!),
      graceAfterUp: Duration.zero,
    );
    await tm.start(1);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(tm.tunnels.single.url, 'https://run-1.trycloudflare.com');
    // Unreachable: after 3 failed checks it is killed and comes back with run-2.
    final t = tm.tunnels.single;
    for (var i = 0; i < 40 && t.url != 'https://run-2.trycloudflare.com'; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    reachable = true;   // the new link works
    expect(t.url, 'https://run-2.trycloudflare.com');
    expect(t.restarts, 1);
    expect(changed, ['https://run-2.trycloudflare.com']);
    expect(t.linkChanged, isTrue);
    expect(t.sharedUrl, 'https://run-1.trycloudflare.com');
    // Healthy now: it stays on run-2, no further restarts.
    await Future<void>.delayed(const Duration(milliseconds: 800));
    expect(t.url, 'https://run-2.trycloudflare.com');
    expect(t.restarts, 1);
    expect(t.checksOk, greaterThan(0));
    await tm.stop();
    await dir.delete(recursive: true);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('no restarts for failed checks while a fresh link is in its grace period', () async {
    final dir = await Directory.systemTemp.createTemp('cf');
    final fake = File('${dir.path}/cloudflared');
    await fake.writeAsString('''#!/bin/sh
echo "INF |  https://fresh.trycloudflare.com  |"
echo "INF Registered tunnel connection connIndex=0"; sleep 30
''');
    await Process.run('chmod', ['+x', fake.path]);
    final tm = TunnelManager(
      binary: fake.path, homeDir: dir.path, localPort: 8000,
      checkEvery: const Duration(milliseconds: 100),
      probe: (url) async => false,   // DNS not live yet
      graceAfterUp: const Duration(seconds: 30),
    );
    await tm.start(1);
    await Future<void>.delayed(const Duration(milliseconds: 900));
    final t = tm.tunnels.single;
    expect(t.checksFailed, greaterThanOrEqualTo(3));
    expect(t.restarts, 0);
    expect(t.url, 'https://fresh.trycloudflare.com');
    await tm.stop();
    await dir.delete(recursive: true);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('parses DNS-over-HTTPS answers', () {
    const body = '{"Status":0,"Answer":[{"name":"a.trycloudflare.com","type":5,"data":"x."},'
        '{"name":"x.","type":1,"data":"104.16.230.132"},{"type":1,"data":"104.16.231.132"}]}';
    expect(parseDohAnswer(body).map((a) => a.address), ['104.16.230.132', '104.16.231.132']);
    expect(parseDohAnswer('{"Status":3}'), isEmpty);   // NXDOMAIN
  });

  test("a DNS failure on the phone itself never restarts the tunnel", () async {
    final dir = await Directory.systemTemp.createTemp('cf');
    final fake = File('${dir.path}/cloudflared');
    await fake.writeAsString('''#!/bin/sh
echo "INF |  https://dns-cached.trycloudflare.com  |"
echo "INF Registered tunnel connection connIndex=0"; sleep 30
''');
    await Process.run('chmod', ['+x', fake.path]);
    final tm = TunnelManager(
      binary: fake.path, homeDir: dir.path, localPort: 8000,
      checkEvery: const Duration(milliseconds: 100),
      graceAfterUp: Duration.zero,
      probe: (url) async => throw const SocketException(
          "Failed host lookup: 'dns-cached.trycloudflare.com'"),
    );
    await tm.start(1);
    await Future<void>.delayed(const Duration(milliseconds: 900));
    final t = tm.tunnels.single;
    expect(t.checksFailed, greaterThanOrEqualTo(3));
    expect(t.failStreak, 0);
    expect(t.restarts, 0);
    await tm.stop();
    await dir.delete(recursive: true);
  }, timeout: const Timeout(Duration(seconds: 30)));

  group('network outage', () {
    // Prints a fresh URL per run, connects, then loses the edge after 0.3 s;
    // with RECONNECT set it gets back in by itself 0.2 s later.
    Future<(TunnelManager, Directory)> outage({required bool online,
        bool reconnects = false, Duration window = const Duration(milliseconds: 300)}) async {
      final dir = await Directory.systemTemp.createTemp('cf');
      final fake = File('${dir.path}/cloudflared');
      await fake.writeAsString('''#!/bin/sh
n=\$(cat "\$HOME/n" 2>/dev/null || echo 0); n=\$((n+1)); echo \$n > "\$HOME/n"
echo "INF |  https://net-\$n.trycloudflare.com  |"
echo "INF Registered tunnel connection connIndex=0"
if [ "\$n" = "1" ]; then
  sleep 0.3; echo "ERR Connection terminated error=\\"connection with edge closed\\""
  if [ "${reconnects ? 1 : 0}" = "1" ]; then sleep 0.2; echo "INF Registered tunnel connection connIndex=0"; fi
fi
sleep 30
''');
      await Process.run('chmod', ['+x', fake.path]);
      final tm = TunnelManager(
        binary: fake.path, homeDir: dir.path, localPort: 8000,
        checkEvery: const Duration(milliseconds: 100),
        quickRetryDelay: const Duration(milliseconds: 100),
        graceAfterUp: Duration.zero,
        reconnectWindow: window,
        probe: (_) async => true,
        isOnline: () async => online,
      );
      await tm.start(1);
      return (tm, dir);
    }

    test('offline: waits, never restarts', () async {
      final (tm, dir) = await outage(online: false);
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      final t = tm.tunnels.single;
      expect(t.connected, isFalse);
      expect(t.restarts, 0);
      expect(t.url, 'https://net-1.trycloudflare.com');
      await tm.stop();
      await dir.delete(recursive: true);
    });

    test('reconnects by itself: same link, no restart, no alert', () async {
      final (tm, dir) = await outage(online: true, reconnects: true,
          window: const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      final t = tm.tunnels.single;
      expect(t.connected, isTrue);
      expect(t.restarts, 0);
      expect(t.linkChanged, isFalse);
      await tm.stop();
      await dir.delete(recursive: true);
    });

    test('online but stuck: restarted quickly with a new link', () async {
      final (tm, dir) = await outage(online: true);
      final t = tm.tunnels.single;
      for (var i = 0; i < 60 && t.url != 'https://net-2.trycloudflare.com'; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(t.url, 'https://net-2.trycloudflare.com');
      expect(t.restarts, 1);
      expect(t.linkChanged, isTrue);
      expect(t.connected, isTrue);
      await tm.stop();
      await dir.delete(recursive: true);
    });
  });
}
