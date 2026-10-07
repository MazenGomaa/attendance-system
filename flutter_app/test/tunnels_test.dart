import 'dart:io';

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
echo "INF |  https://run-\$n.trycloudflare.com  |"; sleep 30
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
}
