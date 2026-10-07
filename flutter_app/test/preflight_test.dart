import 'dart:io';

import 'package:attendance_host/preflight.dart';
import 'package:attendance_host/server/server.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, StaticFile> _statics() => {
      for (final f in Directory('../static').listSync().whereType<File>())
        f.uri.pathSegments.last: StaticFile(f.readAsBytesSync(),
            f.path.endsWith('.js') ? 'text/javascript' : 'text/html; charset=utf-8'),
    };

void main() {
  test('pre-class check passes end to end with a working tunnel', () async {
    final dir = await Directory.systemTemp.createTemp('preflight');
    final fake = File('${dir.path}/cloudflared');
    await fake.writeAsString('''#!/bin/sh
if [ "\$1" = "--version" ]; then echo "cloudflared version 2026.10.0 (fake)"; exit 0; fi
echo "INF |  https://pre-check.trycloudflare.com  |"; sleep 30
''');
    await Process.run('chmod', ['+x', fake.path]);
    final p = Preflight(
      binary: fake.path, workDir: dir.path, statics: _statics(), port: 8011,
      deviceInfo: () async => {'batteryOptimizationIgnored': true, 'notificationsGranted': false},
      // The "public" link is served by the local test server.
      rewriteUrl: (_) => 'http://127.0.0.1:8011',
      firstTryDelay: Duration.zero,
    );
    await p.run();
    for (final s in p.steps) {
      // ignore: avoid_print
      print('${s.status.name.padRight(5)} ${s.title}  ${s.detail}');
    }
    expect(p.cloudflared.status, StepStatus.ok);
    expect(p.battery.status, StepStatus.ok);
    expect(p.notifications.status, StepStatus.warn);   // warning, not a failure
    expect(p.tunnel.status, StepStatus.ok);
    expect(p.page.status, StepStatus.ok);
    expect(p.submit.status, StepStatus.ok);
    expect(p.passed, isTrue);
    expect(Directory('${dir.path}/preflight').existsSync(), isFalse);   // cleaned up
    await dir.delete(recursive: true);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('pre-class check fails clearly when cloudflared cannot run', () async {
    final dir = await Directory.systemTemp.createTemp('preflight');
    final p = Preflight(
      binary: '${dir.path}/missing', workDir: dir.path, statics: _statics(), port: 8012,
      deviceInfo: () async => {'batteryOptimizationIgnored': false, 'notificationsGranted': true},
    );
    await p.run();
    expect(p.cloudflared.status, StepStatus.fail);
    expect(p.battery.status, StepStatus.fail);
    expect(p.battery.fix, 'battery');
    expect(p.tunnel.detail, contains('skipped'));
    expect(p.passed, isFalse);
    await dir.delete(recursive: true);
  });
}
