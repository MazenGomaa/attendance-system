import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'debug_log.dart';
import 'platform.dart';
import 'server/logic.dart';
import 'server/model.dart';
import 'server/server.dart';
import 'tunnels.dart';

const int kPort = 8000;

class SessionSettings {
  String course = '';
  bool geofence = true;
  double radiusKm = 0.5;
  String password = '';
  int tunnels = 2;
}

/// An unfinished session found on disk (the app was killed mid-session).
class UnfinishedSession {
  UnfinishedSession(this.journalPath, this.course, this.students, this.startedAt);
  final String journalPath;
  final String course;
  final int students;
  final DateTime startedAt;
}

/// What End session produced: the CSVs and where copies were saved.
class EndResult {
  EndResult(this.exportPaths, this.saved, this.error);
  final List<String> exportPaths;
  final List<String> saved;
  final String? error;
}

/// Owns a session: foreground service + attendance server + tunnels.
class HostController extends ChangeNotifier {
  AttendanceServer? server;
  TunnelManager? tunnels;
  Map<String, Object?> device = const {};
  String? binaryPath;
  bool busy = false;
  DateTime? runningSince;
  EndResult? lastEnd;
  UnfinishedSession? unfinished;
  Timer? _heartbeat;
  Timer? _refresh;
  DateTime? _lastBeat;
  Map<String, String>? _paths;
  bool _ending = false;

  bool get running => server != null;

  Future<Map<String, String>> paths() async => _paths ??= await HostPlatform.paths();
  Future<String> _dir(String name) async {
    final d = Directory('${(await paths())['filesDir']}/$name')..createSync(recursive: true);
    return d.path;
  }

  Future<void> refreshDevice() async {
    try {
      device = await HostPlatform.deviceInfo();
    } catch (e) {
      log('app', 'deviceInfo failed: $e');
    }
    notifyListeners();
  }

  /// Looks for the newest journal that never reached "ended".
  Future<void> findUnfinished() async {
    try {
      final dir = Directory(await _dir('sessions'));
      final files = dir.listSync().whereType<File>()
          .where((f) => f.path.endsWith('.jsonl')).toList()
        ..sort((a, b) => b.path.compareTo(a.path));
      unfinished = null;
      if (files.isNotEmpty) {
        final cfg = ServerConfig();
        final st = Store();
        Journal.replay(files.first.path, cfg, st);
        if (!cfg.ended && st.log.isNotEmpty) {
          unfinished = UnfinishedSession(
              files.first.path, cfg.courseName, st.records.length, cfg.startedAt);
        }
      }
    } catch (e) {
      log('app', 'could not check for unfinished sessions: $e');
    }
    notifyListeners();
  }

  Future<Map<String, StaticFile>> _loadStatics() async {
    const types = {'html': 'text/html; charset=utf-8', 'js': 'text/javascript; charset=utf-8'};
    final out = <String, StaticFile>{};
    for (final name in const ['index.html', 'index.js', 'admin.html', 'admin.js',
        'login.html', 'login.js']) {
      final data = await rootBundle.load('assets/web/$name');
      out[name] = StaticFile(data.buffer.asUint8List(), types[name.split('.').last]!);
    }
    return out;
  }

  Future<void> start(SessionSettings s, {UnfinishedSession? resume}) async {
    if (busy || running) return;
    busy = true;
    lastEnd = null;
    notifyListeners();
    try {
      await HostPlatform.requestNotifications();
      final p = await paths();
      final stamp = DateTime.now().toIso8601String().substring(0, 19).replaceAll(':', '-');
      DebugLog.instance.openFile('${await _dir('logs')}/session-$stamp.log');
      binaryPath = '${p['nativeLibDir']}/libcloudflared.so';
      final bin = File(binaryPath!);
      log('app', 'cloudflared: $binaryPath '
          '(${bin.existsSync() ? '${bin.lengthSync()} bytes' : 'MISSING'})');

      final cfg = ServerConfig()
        ..courseName = s.course.trim().isEmpty ? 'Session' : s.course.trim()
        ..pageSecret = randomHex()
        ..geofence = s.geofence
        ..auditRadiusKm = s.radiusKm
        ..forceSingleOrigin = s.tunnels <= 1;
      if (s.password.isNotEmpty) {
        cfg.adminPwSalt = randomHex(8);
        cfg.adminPwHash = sha256Hex(cfg.adminPwSalt + s.password);
      }
      final journal = resume?.journalPath ?? '${await _dir('sessions')}/$stamp.jsonl';
      final srv = AttendanceServer(
        config: cfg,
        statics: await _loadStatics(),
        exportDir: await _dir('exports'),
        journalPath: journal,
        onEndSession: _afterEnd,
      );
      if (resume != null) {
        srv.resumeFromJournal();
        cfg.ended = false;
        log('app', 'resumed "${cfg.courseName}": ${srv.store.records.length} students');
      }
      await HostPlatform.startService('Starting…');
      await srv.start(port: kPort);
      server = srv;
      unfinished = null;
      runningSince = DateTime.now();
      log('server', 'attendance server on 127.0.0.1:$kPort, journal $journal');

      final tm = TunnelManager(binary: binaryPath!, homeDir: p['filesDir']!, localPort: kPort);
      tm.addListener(() {
        // Keep the server's view of public URLs current (single-origin redirect).
        cfg.tunnelUrls = [for (final t in tm.tunnels) if (t.url != null) t.url!];
        _updateNotification();
        notifyListeners();
      });
      tunnels = tm;
      await tm.start(s.tunnels);
      _startTimers();
      log('app', 'session started with ${s.tunnels} tunnel(s)');
    } catch (e, st) {
      log('app', 'start failed: $e\n$st');
      await _teardown();
    } finally {
      busy = false;
      await refreshDevice();
    }
  }

  void _startTimers() {
    _lastBeat = DateTime.now();
    // Logs a line a minute and flags late timers: if Android froze the
    // process with the screen off, the gap shows up here with its length.
    _heartbeat = Timer.periodic(const Duration(seconds: 60), (_) {
      final now = DateTime.now();
      final gap = now.difference(_lastBeat!).inSeconds;
      _lastBeat = now;
      if (gap > 90) log('heartbeat', 'WARNING: timer ${gap - 60} s late — app was suspended?');
      final st = server?.store;
      log('heartbeat', 'alive, up ${now.difference(runningSince!).inMinutes} min, '
          '${st?.records.length ?? 0} students, ${st?.log.length ?? 0} submissions');
      _updateNotification();
    });
    _refresh = Timer.periodic(const Duration(seconds: 2), (_) => notifyListeners());
  }

  void _updateNotification() {
    final tm = tunnels, srv = server;
    if (tm == null || srv == null) return;
    final up = tm.tunnels.where((t) => t.state == TunnelState.up).length;
    final mins = DateTime.now().difference(runningSince!).inMinutes;
    HostPlatform.updateNotification('${srv.store.records.length} students · up $mins min · '
        '$up/${tm.tunnels.length} tunnels');
  }

  /// End attendance: export, stop everything, save CSVs to Downloads.
  Future<void> endSession() async {
    final srv = server;
    if (srv == null || _ending) return;
    final res = srv.endSession();   // schedules _afterEnd via onEndSession
    if (res['ok'] != true) {
      lastEnd = EndResult(const [], const [], '${res['error']}');
      notifyListeners();
    }
  }

  /// Runs after End session from the app or the web dashboard.
  Future<void> _afterEnd() async {
    if (_ending) return;
    _ending = true;
    final srv = server;
    final exportDir = srv?.exportDir;
    final base = srv?.config.sessionId();
    await _teardown();
    final files = <String>[
      for (final k in const ['Final', 'Raw', 'Audited'])
        if (exportDir != null && File('$exportDir/${base}_$k.csv').existsSync())
          '$exportDir/${base}_$k.csv',
    ];
    lastEnd = EndResult(files, await _saveToDownloads(files), null);
    _ending = false;
    log('app', 'session ended; ${files.length} CSV file(s)');
    await findUnfinished();
    notifyListeners();
  }

  Future<List<String>> _saveToDownloads(List<String> files) async {
    final saved = <String>[];
    for (final f in files) {
      try {
        saved.add(await HostPlatform.saveToDownloads(f));
      } catch (e) {
        log('app', 'could not save $f to Downloads: $e');
      }
    }
    return saved;
  }

  /// Export an unfinished session found on disk and close it.
  Future<void> closeUnfinished(UnfinishedSession u) async {
    final cfg = ServerConfig();
    final srv = AttendanceServer(config: cfg, statics: const {},
        exportDir: await _dir('exports'), journalPath: u.journalPath);
    srv.resumeFromJournal();
    final r = srv.exportNow('recovered');
    File(u.journalPath).writeAsStringSync('${jsonEncode({'op': 'ended'})}\n',
        mode: FileMode.append);
    lastEnd = EndResult(r.all, await _saveToDownloads(r.all), null);
    unfinished = null;
    log('app', 'closed unfinished session "${u.course}" (${u.students} students)');
    notifyListeners();
  }

  Future<void> _teardown() async {
    _heartbeat?.cancel();
    _refresh?.cancel();
    await tunnels?.stop();
    await server?.stop(export: false);
    server = null;
    tunnels = null;
    runningSince = null;
    try {
      await HostPlatform.stopService();
    } catch (_) {}
    notifyListeners();
  }
}
