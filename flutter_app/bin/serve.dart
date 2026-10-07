// Runs the Dart attendance server outside the app, in the same fixed test
// configuration as tests/serve_python.py, for tests/scenarios.py:
//
//   dart run bin/serve.dart --port 8765 [--no-password] [--export-dir DIR]
//       [--static-dir ../static] [--journal FILE] [--resume] [--roster FILE]
//
// Test configuration: geofence on, audit radius 0.5 km, admin password "pw"
// (unless --no-password), course "Scenario".

import 'dart:io';

import 'package:attendance_host/server/logic.dart';
import 'package:attendance_host/server/model.dart';
import 'package:attendance_host/server/server.dart';

const _types = {
  'html': 'text/html; charset=utf-8',
  'js': 'text/javascript; charset=utf-8',
  'css': 'text/css; charset=utf-8',
};

Future<void> main(List<String> args) async {
  String? opt(String name) {
    final i = args.indexOf(name);
    return i >= 0 && i + 1 < args.length ? args[i + 1] : null;
  }

  final port = int.parse(opt('--port') ?? '8765');
  final staticDir = opt('--static-dir') ?? '../static';
  final exportDir = opt('--export-dir') ?? '${Directory.systemTemp.path}/attendance-exports';

  final statics = <String, StaticFile>{};
  for (final f in Directory(staticDir).listSync().whereType<File>()) {
    final name = f.uri.pathSegments.last;
    final type = _types[name.split('.').last];
    if (type != null) statics[name] = StaticFile(f.readAsBytesSync(), type);
  }

  final config = ServerConfig()
    ..courseName = 'Scenario'
    ..pageSecret = randomHex()
    ..geofence = true
    ..auditRadiusKm = 0.5;
  final roster = opt('--roster');
  if (roster != null) config.roster = parseRoster(File(roster).readAsStringSync());
  if (!args.contains('--no-password')) {
    config
      ..adminPwSalt = 'salt'
      ..adminPwHash = sha256Hex('saltpw');
  }

  late final AttendanceServer server;
  server = AttendanceServer(
    config: config,
    statics: statics,
    exportDir: exportDir,
    journalPath: opt('--journal'),
    onEndSession: () async {
      await server.stop(reason: 'end-session-stop');
      exit(0);
    },
  );
  if (args.contains('--resume') && server.resumeFromJournal()) {
    stdout.writeln('[serve] resumed ${server.store.records.length} students from journal');
  }
  await server.start(port: port);
  stdout.writeln('[serve] Dart attendance server on 127.0.0.1:$port');
  ProcessSignal.sigint.watch().listen((_) async {
    await server.stop();
    exit(0);
  });
  ProcessSignal.sigterm.watch().listen((_) async {
    await server.stop();
    exit(0);
  });
}
