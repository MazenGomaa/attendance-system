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
    await tm.stop();
    await dir.delete(recursive: true);
  }, timeout: const Timeout(Duration(seconds: 30)));
}
