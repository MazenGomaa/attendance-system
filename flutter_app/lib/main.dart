import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import 'debug_log.dart';
import 'platform.dart';
import 'qr_image.dart';
import 'test_server.dart';
import 'tunnels.dart';

const int kPort = 8000;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const HostApp());
}

class HostApp extends StatelessWidget {
  const HostApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Attendance Host',
      theme: ThemeData(colorSchemeSeed: const Color(0xFF3A8DDE), brightness: Brightness.dark),
      home: const HomePage(),
    );
  }
}

/// Owns the session: foreground service + local server + tunnels.
class HostController extends ChangeNotifier {
  final TestServer server = TestServer(kPort);
  TunnelManager? tunnels;
  Map<String, Object?> device = const {};
  String? binaryPath;
  bool busy = false;
  Timer? _heartbeat;
  DateTime? _lastBeat;

  bool get running => server.running;

  Future<void> refreshDevice() async {
    try {
      device = await HostPlatform.deviceInfo();
    } catch (e) {
      log('app', 'deviceInfo failed: $e');
    }
    notifyListeners();
  }

  Future<void> start(int tunnelCount) async {
    if (busy || running) return;
    busy = true;
    notifyListeners();
    try {
      await HostPlatform.requestNotifications();
      final paths = await HostPlatform.paths();
      final logDir = Directory('${paths['filesDir']}/logs')..createSync(recursive: true);
      final stamp = DateTime.now().toIso8601String().substring(0, 19).replaceAll(':', '-');
      DebugLog.instance.openFile('${logDir.path}/session-$stamp.log');
      binaryPath = '${paths['nativeLibDir']}/libcloudflared.so';
      final bin = File(binaryPath!);
      log('app', 'cloudflared: $binaryPath '
          '(${bin.existsSync() ? '${bin.lengthSync()} bytes' : 'MISSING'})');
      await HostPlatform.startService('Starting…');
      await server.start();
      final tm = TunnelManager(
          binary: binaryPath!, homeDir: paths['filesDir']!, localPort: kPort);
      tm.addListener(_onTunnelChange);
      tunnels = tm;
      await tm.start(tunnelCount);
      _startHeartbeat();
      log('app', 'session started with $tunnelCount tunnel(s)');
    } catch (e) {
      log('app', 'start failed: $e');
    } finally {
      busy = false;
      await refreshDevice();
    }
  }

  /// Logs a line every minute and flags late timers: if Android froze the
  /// process with the screen off, the gap shows up here with its length.
  void _startHeartbeat() {
    _lastBeat = DateTime.now();
    _heartbeat = Timer.periodic(const Duration(seconds: 60), (_) {
      final now = DateTime.now();
      final gap = now.difference(_lastBeat!).inSeconds;
      _lastBeat = now;
      final up = now.difference(server.startedAt!).inMinutes;
      if (gap > 90) {
        log('heartbeat', 'WARNING: timer ${gap - 60} s late — app was suspended?');
      }
      log('heartbeat', 'alive, up $up min, visits ${server.hits}, pings ${server.pings}');
      _updateNotification();
    });
  }

  void _onTunnelChange() {
    _updateNotification();
    notifyListeners();
  }

  void _updateNotification() {
    final tm = tunnels;
    if (tm == null || !running) return;
    final up = tm.tunnels.where((t) => t.state == TunnelState.up).length;
    final ok = tm.tunnels.fold<int>(0, (a, t) => a + t.checksOk);
    final bad = tm.tunnels.fold<int>(0, (a, t) => a + t.checksFailed);
    final mins = DateTime.now().difference(server.startedAt!).inMinutes;
    HostPlatform.updateNotification(
        'Up $mins min · $up/${tm.tunnels.length} tunnels · checks $ok ok / $bad failed');
  }

  Future<void> stop() async {
    _heartbeat?.cancel();
    await tunnels?.stop();
    await server.stop();
    await HostPlatform.stopService();
    log('app', 'session stopped');
    await refreshDevice();
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final HostController c = HostController();
  int tunnelCount = 1;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    c.addListener(_redraw);
    c.server.addListener(_redraw);
    c.refreshDevice();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (c.running) _redraw();
    });
    log('app', 'app opened');
  }

  void _redraw() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    log('lifecycle', state.name);
    if (state == AppLifecycleState.resumed) c.refreshDevice();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tm = c.tunnels;
    final batteryOk = c.device['batteryOptimizationIgnored'] == true;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Attendance Host · Phase 0'),
        actions: [
          IconButton(
            tooltip: 'Debug',
            icon: const Icon(Icons.bug_report),
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => DebugPage(controller: c))),
          ),
        ],
      ),
      // Start/Stop live in a fixed bar above the system navigation buttons, so
      // they stay reachable however many tunnel cards the list holds.
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: c.running
              ? Row(children: [
                  if ((tm?.tunnels.where((t) => t.url != null).length ?? 0) > 1) ...[
                    Expanded(
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.share),
                        label: const Text('Share all QR'),
                        onPressed: () => shareQrs(tm!.tunnels
                            .where((t) => t.url != null)
                            .map((t) => (t.url!, 'Tunnel ${t.index}'))
                            .toList()),
                      ),
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
                      icon: const Icon(Icons.stop),
                      label: const Text('Stop session'),
                      onPressed: c.stop,
                    ),
                  ),
                ])
              : FilledButton.icon(
                  icon: const Icon(Icons.play_arrow),
                  label: Text(c.busy ? 'Starting…' : 'Start test session'),
                  onPressed: c.busy ? null : () => c.start(tunnelCount),
                ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (!batteryOk)
            Card(
              color: Colors.orange.shade900,
              child: ListTile(
                leading: const Icon(Icons.battery_alert),
                title: const Text('Battery optimisation is ON'),
                subtitle: const Text('Android may freeze the server with the screen off. '
                    'Tap to allow running in the background.'),
                onTap: () async {
                  await HostPlatform.requestBatteryExemption();
                },
              ),
            ),
          if (!c.running) ...[
            const Text('Tunnels'),
            const SizedBox(height: 8),
            SegmentedButton<int>(
              segments: [for (var i = 1; i <= 4; i++) ButtonSegment(value: i, label: Text('$i'))],
              selected: {tunnelCount},
              onSelectionChanged: (s) => setState(() => tunnelCount = s.first),
            ),
            const SizedBox(height: 12),
            const Text('Closing or swiping the app away keeps the session running. '
                'Only "Stop session" ends it.',
                style: TextStyle(color: Colors.white70, fontSize: 13)),
          ] else ...[
            _statusCard(),
            for (final t in tm?.tunnels ?? const <Tunnel>[]) _tunnelCard(t),
          ],
        ],
      ),
    );
  }

  Widget _statusCard() {
    final up = DateTime.now().difference(c.server.startedAt!);
    String two(int v) => v.toString().padLeft(2, '0');
    final upText = '${up.inHours}:${two(up.inMinutes % 60)}:${two(up.inSeconds % 60)}';
    return Card(
      child: ListTile(
        leading: const Icon(Icons.dns, color: Colors.greenAccent),
        title: Text('Server up $upText'),
        subtitle: Text('Page visits ${c.server.hits} · health pings ${c.server.pings}\n'
            'Background service: ${c.device['serviceRunning'] == true ? 'running' : 'NOT running'}'),
        isThreeLine: true,
      ),
    );
  }

  Widget _tunnelCard(Tunnel t) {
    final color = switch (t.state) {
      TunnelState.up => Colors.greenAccent,
      TunnelState.failed => Colors.redAccent,
      TunnelState.stopped => Colors.grey,
      _ => Colors.amber,
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(Icons.circle, size: 12, color: color),
              const SizedBox(width: 8),
              Text('Tunnel ${t.index}: ${t.state.name}',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              const Spacer(),
              Text('restarts ${t.restarts}'),
            ]),
            const SizedBox(height: 6),
            Text('Checks: ${t.checksOk} ok · ${t.checksFailed} failed'
                '${t.lastLatencyMs != null ? ' · last ${t.lastLatencyMs} ms' : ''}'),
            if (t.url != null) ...[
              const SizedBox(height: 8),
              SelectableText(t.url!, style: const TextStyle(color: Colors.lightBlueAccent)),
              Row(children: [
                TextButton.icon(
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Copy'),
                  onPressed: () => Clipboard.setData(ClipboardData(text: t.url!)),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.share, size: 18),
                  label: const Text('Share QR'),
                  onPressed: () => shareQrs([(t.url!, 'Tunnel ${t.index}')]),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.qr_code, size: 18),
                  label: const Text('Show QR'),
                  onPressed: () => Navigator.push(context, MaterialPageRoute(
                      builder: (_) => QrPage(url: t.url!, title: 'Tunnel ${t.index}'))),
                ),
              ]),
            ],
            if (t.lastError != null && t.state != TunnelState.up)
              Text(t.lastError!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

/// Shares one or more QR codes as PNG images through the Android share sheet.
Future<void> shareQrs(List<(String, String)> items) async {
  try {
    final files = <XFile>[];
    for (final (url, title) in items) {
      final bytes = await renderQrPng(url, title);
      // Directory.systemTemp is the app's cache dir on Android.
      final f = File('${Directory.systemTemp.path}/${_qrFileName(title)}');
      await f.writeAsBytes(bytes);
      files.add(XFile(f.path, mimeType: 'image/png'));
    }
    await SharePlus.instance.share(ShareParams(
      files: files,
      text: items.map((e) => '${e.$2}: ${e.$1}').join('\n\n'),
    ));
    log('qr', 'shared ${files.length} QR image(s)');
  } catch (e) {
    log('qr', 'share failed: $e');
  }
}

String _qrFileName(String title) =>
    'attendance-qr-${title.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-')}.png';

class QrPage extends StatelessWidget {
  const QrPage({super.key, required this.url, required this.title});
  final String url;
  final String title;

  Future<void> _save(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final bytes = await renderQrPng(url, title);
      final stamp = DateTime.now().toIso8601String().substring(0, 19).replaceAll(':', '-');
      final where = await HostPlatform.saveImage(
          bytes, _qrFileName('$title $stamp'));
      log('qr', 'saved $where');
      messenger.showSnackBar(SnackBar(content: Text('Saved to $where')));
    } catch (e) {
      log('qr', 'save failed: $e');
      messenger.showSnackBar(SnackBar(content: Text('Save failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(title: Text(title)),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(children: [
            Expanded(
              child: FilledButton.icon(
                icon: const Icon(Icons.download),
                label: const Text('Save to Gallery'),
                onPressed: () => _save(context),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton.icon(
                icon: const Icon(Icons.share),
                label: const Text('Share'),
                onPressed: () => shareQrs([(url, title)]),
              ),
            ),
          ]),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              QrImageView(data: url, backgroundColor: Colors.white, size: 320),
              const SizedBox(height: 12),
              SelectableText(url, style: const TextStyle(color: Colors.black, fontSize: 16)),
            ]),
          ),
        ),
      ),
    );
  }
}

class DebugPage extends StatefulWidget {
  const DebugPage({super.key, required this.controller});
  final HostController controller;

  @override
  State<DebugPage> createState() => _DebugPageState();
}

class _DebugPageState extends State<DebugPage> {
  String binaryVersion = '(not checked)';

  @override
  void initState() {
    super.initState();
    DebugLog.instance.addListener(_redraw);
    widget.controller.refreshDevice();
  }

  void _redraw() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    DebugLog.instance.removeListener(_redraw);
    super.dispose();
  }

  Future<void> _checkBinary() async {
    final paths = await HostPlatform.paths();
    final path = '${paths['nativeLibDir']}/libcloudflared.so';
    try {
      final r = await Process.run(path, ['--version']);
      binaryVersion = '${r.stdout}${r.stderr}'.trim();
    } catch (e) {
      binaryVersion = 'FAILED to run $path: $e';
    }
    log('debug', 'cloudflared --version: $binaryVersion');
    _redraw();
  }

  String _report() {
    final c = widget.controller;
    final b = StringBuffer('=== Attendance Host debug report ===\n');
    c.device.forEach((k, v) => b.writeln('$k: $v'));
    b.writeln('cloudflared: ${c.binaryPath ?? '(not started)'}');
    b.writeln('cloudflared version: $binaryVersion');
    b.writeln('full log file: ${DebugLog.instance.filePath ?? '(none yet)'}');
    for (final t in c.tunnels?.tunnels ?? const <Tunnel>[]) {
      b.writeln('tunnel ${t.index}: ${t.state.name} url=${t.url} restarts=${t.restarts} '
          'checks ok=${t.checksOk} failed=${t.checksFailed} lastError=${t.lastError}');
    }
    b.writeln('--- log (${DebugLog.instance.lines.length} lines) ---');
    DebugLog.instance.lines.forEach(b.writeln);
    return b.toString();
  }

  @override
  Widget build(BuildContext context) {
    final lines = DebugLog.instance.lines;
    final info = widget.controller.device;
    return Scaffold(
      appBar: AppBar(title: const Text('Debug')),
      body: SafeArea(child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final e in info.entries)
                Text('${e.key}: ${e.value}', style: const TextStyle(fontSize: 12)),
              Text('cloudflared version: $binaryVersion', style: const TextStyle(fontSize: 12)),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [
                FilledButton.icon(
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy all'),
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: _report()));
                    ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Debug report copied')));
                  },
                ),
                OutlinedButton(onPressed: _checkBinary, child: const Text('Test cloudflared')),
                OutlinedButton(
                    onPressed: DebugLog.instance.clear, child: const Text('Clear log')),
              ]),
            ]),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              reverse: true,   // newest at the bottom, auto-scrolled into view
              itemCount: lines.length,
              itemBuilder: (_, i) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
                child: Text(lines[lines.length - 1 - i],
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
              ),
            ),
          ),
        ],
      )),
    );
  }
}
