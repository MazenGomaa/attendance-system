import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import 'debug_log.dart';
import 'platform.dart';
import 'qr_image.dart';
import 'session.dart';
import 'tunnels.dart';

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

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final HostController c = HostController();
  final SessionSettings settings = SessionSettings();
  final _course = TextEditingController();
  final _radius = TextEditingController(text: '0.5');
  final _password = TextEditingController();
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    c.addListener(_redraw);
    c.refreshDevice();
    c.findUnfinished();
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

  void _start({UnfinishedSession? resume}) {
    settings
      ..course = _course.text
      ..radiusKm = double.tryParse(_radius.text.trim()) ?? 0.5
      ..password = _password.text;
    if (settings.radiusKm < 0.05) settings.radiusKm = 0.05;
    c.start(settings, resume: resume);
  }

  Future<void> _confirmEnd() async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('End the session?'),
        content: const Text('• Students can no longer submit\n'
            '• The CSVs are saved to Download/Attendance\n'
            '• The tunnels stop (the student links stop working)'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('End session'),
          ),
        ],
      ),
    );
    if (yes == true) await c.endSession();
  }

  @override
  Widget build(BuildContext context) {
    final batteryOk = c.device['batteryOptimizationIgnored'] == true;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Attendance Host'),
        actions: [
          IconButton(
            tooltip: 'Debug',
            icon: const Icon(Icons.bug_report),
            onPressed: () => Navigator.push(context,
                MaterialPageRoute(builder: (_) => DebugPage(controller: c))),
          ),
        ],
      ),
      // Actions live in a fixed bar above the system navigation buttons.
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: c.running ? _runningActions() : FilledButton.icon(
            icon: const Icon(Icons.play_arrow),
            label: Text(c.busy ? 'Starting…' : 'Start session'),
            onPressed: c.busy ? null : () => _start(),
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
                onTap: HostPlatform.requestBatteryExemption,
              ),
            ),
          if (c.lastEnd != null) _endCard(c.lastEnd!),
          if (c.running) ..._runningView() else ..._setupView(),
        ],
      ),
    );
  }

  Widget _runningActions() {
    final tm = c.tunnels;
    final withUrl = tm?.tunnels.where((t) => t.url != null).toList() ?? const <Tunnel>[];
    return Row(children: [
      if (withUrl.isNotEmpty) ...[
        Expanded(
          child: OutlinedButton.icon(
            icon: const Icon(Icons.share),
            label: Text(withUrl.length > 1 ? 'Share all QR' : 'Share QR'),
            onPressed: () => shareQrs(
                [for (final t in withUrl) (t.url!, 'Tunnel ${t.index}')]),
          ),
        ),
        const SizedBox(width: 12),
      ],
      Expanded(
        child: FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
          icon: const Icon(Icons.stop),
          label: const Text('End session'),
          onPressed: _confirmEnd,
        ),
      ),
    ]);
  }

  // ---------------------------------------------------------------- setup --

  List<Widget> _setupView() {
    final u = c.unfinished;
    return [
      if (u != null)
        Card(
          color: Colors.blueGrey.shade800,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Unfinished session found',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(height: 4),
              Text('"${u.course}" · ${u.students} students · started '
                  '${u.startedAt.toString().substring(0, 16)}\n'
                  'The app was closed before this session ended.'),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [
                FilledButton(
                  onPressed: c.busy ? null : () => _start(resume: u),
                  child: const Text('Resume it'),
                ),
                OutlinedButton(
                  onPressed: () => c.closeUnfinished(u),
                  child: const Text('End it & save CSVs'),
                ),
              ]),
              const Text('Resume uses the settings below (location, password, tunnels).',
                  style: TextStyle(color: Colors.white60, fontSize: 12)),
            ]),
          ),
        ),
      TextField(
        controller: _course,
        decoration: const InputDecoration(labelText: 'Course / subject name',
            hintText: 'e.g. Anatomy Lecture 5'),
      ),
      const SizedBox(height: 8),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Require location (GPS audit)'),
        subtitle: const Text('Students must allow location; far-away ones are flagged.'),
        value: settings.geofence,
        onChanged: (v) => setState(() => settings.geofence = v),
      ),
      if (settings.geofence)
        TextField(
          controller: _radius,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(labelText: 'Audit radius (km)',
              helperText: 'Flag anyone farther than this from where most students are'),
        ),
      const SizedBox(height: 8),
      TextField(
        controller: _password,
        obscureText: true,
        decoration: const InputDecoration(labelText: 'Web dashboard password (optional)',
            helperText: 'Only for opening the dashboard in a browser; this app needs none'),
      ),
      const SizedBox(height: 16),
      const Text('Tunnels (each handles ~200 students at once)'),
      const SizedBox(height: 8),
      SegmentedButton<int>(
        segments: [for (var i = 1; i <= 4; i++) ButtonSegment(value: i, label: Text('$i'))],
        selected: {settings.tunnels},
        onSelectionChanged: (s) => setState(() => settings.tunnels = s.first),
      ),
      const SizedBox(height: 12),
      const Text('Closing or swiping the app away keeps the session running. '
          'Only "End session" ends it.',
          style: TextStyle(color: Colors.white70, fontSize: 13)),
    ];
  }

  Widget _endCard(EndResult r) {
    return Card(
      color: r.error != null ? Colors.red.shade900 : Colors.green.shade900,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(r.error != null ? 'End session failed' : 'Session ended',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 4),
          if (r.error != null) Text(r.error!),
          if (r.saved.isNotEmpty) Text('Saved to Downloads:\n${r.saved.join('\n')}'),
          if (r.error == null && r.saved.isEmpty)
            const Text('Could not save to Downloads; use Share below.'),
          if (r.exportPaths.isNotEmpty)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.share),
                label: const Text('Share CSVs'),
                onPressed: () => SharePlus.instance.share(ShareParams(
                    files: [for (final p in r.exportPaths) XFile(p, mimeType: 'text/csv')])),
              ),
            ),
        ]),
      ),
    );
  }

  // -------------------------------------------------------------- running --

  List<Widget> _runningView() {
    final st = c.server!.stateSnapshot();
    final up = DateTime.now().difference(c.runningSince!);
    String two(int v) => v.toString().padLeft(2, '0');
    final geo = st['geofence'] == true;
    final recent = (st['recent'] as List).cast<Map<String, Object?>>();
    return [
      Text('${st['course']} · up ${up.inHours}:${two(up.inMinutes % 60)}:${two(up.inSeconds % 60)}',
          style: const TextStyle(color: Colors.white70)),
      const SizedBox(height: 8),
      Wrap(spacing: 8, runSpacing: 8, children: [
        _stat('Students', '${st['count']}'),
        _stat('Submissions', '${st['submissions']}'),
        _stat('Edits / conflicts', '${(st['merges'] as List).length}'),
        if (geo) _stat('Out of bounds', '${st['out_of_bounds']}',
            alert: (st['out_of_bounds'] as int) > 0),
        _stat('On a shared IP', '${st['shared_ip']}'),
      ]),
      const SizedBox(height: 8),
      for (final t in c.tunnels?.tunnels ?? const <Tunnel>[]) _tunnelCard(t),
      const SizedBox(height: 8),
      Text('Recent submissions${geo ? ' · distance from the hall' : ''}',
          style: const TextStyle(fontWeight: FontWeight.bold)),
      if (recent.isEmpty)
        const Padding(padding: EdgeInsets.all(8), child: Text('None yet.')),
      for (final x in recent.take(15))
        ListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          title: Text('${x['name']}', textDirection: TextDirection.rtl),
          subtitle: Text('${x['id']} · ${'${x['timestamp']}'.substring(11)}'
              '${x['edited'] == true ? ' · edited' : ''}'
              '${x['shared_ip'] == true ? ' · shared IP' : ''}'),
          trailing: geo
              ? Text(_dist(x['dist_m'] as int?) + (x['out'] == true ? ' ⚠' : ''),
                  style: TextStyle(color: x['out'] == true ? Colors.redAccent : null))
              : null,
        ),
    ];
  }

  String _dist(int? m) => m == null ? '—' : (m >= 1000 ? '${(m / 1000).toStringAsFixed(2)} km' : '$m m');

  Widget _stat(String label, String value, {bool alert = false}) => SizedBox(
        width: 104,
        child: Card(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold,
                  color: alert ? Colors.redAccent : null)),
              Text(label, style: const TextStyle(fontSize: 11, color: Colors.white70)),
            ]),
          ),
        ),
      );

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
              Text('checks ${t.checksOk}✓ ${t.checksFailed}✗'),
            ]),
            if (t.url != null) ...[
              const SizedBox(height: 6),
              SelectableText(t.url!, style: const TextStyle(color: Colors.lightBlueAccent)),
              Wrap(children: [
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
            if (t.restarts > 0) Text('restarted ${t.restarts}×',
                style: const TextStyle(color: Colors.amber, fontSize: 12)),
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
