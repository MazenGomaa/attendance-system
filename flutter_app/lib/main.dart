import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import 'debug_log.dart';
import 'platform.dart';
import 'qr_image.dart';
import 'server/logic.dart';
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
  final _search = TextEditingController();
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    c.addListener(_redraw);
    c.refreshDevice();
    c.findUnfinished();
    c.loadSettings(settings).then((_) {
      _course.text = settings.course;
      _radius.text = '${settings.radiusKm}';
      _redraw();
    });
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (c.running) _redraw();
    });
    log('app', 'app opened');
  }

  void _redraw() {
    if (mounted) setState(() {});
  }

  void _toast(String msg) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
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
    if (settings.tunnels == 0 && !settings.localNetwork) settings.tunnels = 1;
    c.start(settings, resume: resume);
  }

  Future<bool> _confirm(String title, String body, String action, {bool danger = true}) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: danger ? FilledButton.styleFrom(backgroundColor: Colors.red.shade700) : null,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return yes == true;
  }

  Future<void> _confirmEnd() async {
    if (await _confirm('End the session?',
        '• Students can no longer submit\n'
        '• The CSVs are saved to Download/Attendance\n'
        '• The tunnels stop (the student links stop working)', 'End session')) {
      await c.endSession();
    }
  }

  @override
  Widget build(BuildContext context) {
    final batteryOk = c.device['batteryOptimizationIgnored'] == true;
    final header = <Widget>[
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
    ];
    final bottom = SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: c.running ? _runningActions() : FilledButton.icon(
          icon: const Icon(Icons.play_arrow),
          label: Text(c.busy ? 'Starting…' : 'Start session'),
          onPressed: c.busy ? null : () => _start(),
        ),
      ),
    );
    final debug = IconButton(
      tooltip: 'Debug',
      icon: const Icon(Icons.bug_report),
      onPressed: () => Navigator.push(context,
          MaterialPageRoute(builder: (_) => DebugPage(controller: c))),
    );

    if (!c.running) {
      return Scaffold(
        appBar: AppBar(title: const Text('Attendance Host'), actions: [debug]),
        bottomNavigationBar: bottom,
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [...header, ..._setupView()],
        ),
      );
    }

    final st = c.server!.stateSnapshot();
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text('${st['course']}', overflow: TextOverflow.ellipsis),
          actions: [
            PopupMenuButton<String>(
              tooltip: 'Session actions',
              onSelected: _sessionAction,
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'export', child: Text('Export & share CSVs now')),
                PopupMenuItem(value: 'reset', child: Text('Reset for a new take')),
                PopupMenuItem(value: 'subject', child: Text('New subject…')),
              ],
            ),
            debug,
          ],
          bottom: TabBar(tabs: [
            const Tab(text: 'Overview'),
            Tab(text: 'Students (${st['count']})'),
            Tab(text: 'Log (${(st['merges'] as List).length})'),
          ]),
        ),
        bottomNavigationBar: bottom,
        body: TabBarView(children: [
          ListView(padding: const EdgeInsets.all(16), children: [...header, ..._overview(st)]),
          _studentsTab(st),
          _logTab(),
        ]),
      ),
    );
  }

  Future<void> _sessionAction(String action) async {
    switch (action) {
      case 'export':
        final files = c.exportNow();
        if (files.isEmpty) return;
        await SharePlus.instance.share(ShareParams(
            files: [for (final p in files) XFile(p, mimeType: 'text/csv')]));
      case 'reset':
        if (await _confirm('Reset for a new take?',
            'Clears device locks so every student can submit again. Records are kept; '
            'a student who re-submits with the same ID and name updates their entry.',
            'Reset', danger: false)) {
          c.resetDevices();
          _toast('Device locks reset');
        }
      case 'subject':
        final name = TextEditingController();
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('New subject'),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('The current subject is saved to Download/Attendance and cleared. '
                  'The student links stay the same.'),
              TextField(controller: name, autofocus: true,
                  decoration: const InputDecoration(labelText: 'New subject name')),
            ]),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Start')),
            ],
          ),
        );
        if (ok == true) {
          final exported = await c.newSubject(name.text);
          _toast('Saved $exported');
        }
    }
  }

  Widget _runningActions() {
    final withUrl = c.tunnels?.tunnels.where((t) => t.url != null).toList() ?? const <Tunnel>[];
    final links = [
      for (final t in withUrl) (t.url!, 'Tunnel ${t.index}'),
      for (final (i, u) in c.lanUrls.indexed) (u, 'Local network ${i + 1}'),
    ];
    return Row(children: [
      if (links.isNotEmpty) ...[
        Expanded(
          child: OutlinedButton.icon(
            icon: const Icon(Icons.share),
            label: Text(links.length > 1 ? 'Share all QR' : 'Share QR'),
            onPressed: () => shareQrs(links),
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
      Card(
        child: ListTile(
          leading: const Icon(Icons.list_alt),
          title: Text(c.rosterIds.isEmpty
              ? 'No class list: any numeric ID is accepted'
              : 'Class list: ${c.rosterIds.length} IDs'),
          subtitle: Text(c.rosterName == null
              ? 'Import a CSV/TXT with student IDs in the first column'
              : 'From "${c.rosterName}"'),
          trailing: Wrap(children: [
            if (c.rosterIds.isNotEmpty)
              IconButton(tooltip: 'Remove class list', icon: const Icon(Icons.close),
                  onPressed: c.clearRoster),
            IconButton(
              tooltip: 'Import class list',
              icon: const Icon(Icons.file_open),
              onPressed: () async => _toast(await c.importRoster()),
            ),
          ]),
        ),
      ),
      const SizedBox(height: 8),
      TextField(
        controller: _password,
        obscureText: true,
        decoration: const InputDecoration(labelText: 'Web dashboard password (optional)',
            helperText: 'Only for opening the dashboard in a browser; this app needs none'),
      ),
      const SizedBox(height: 8),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('Also serve on this phone\'s Wi-Fi / hotspot'),
        subtitle: const Text('Students on the same network can use a local link. '
            'With 0 tunnels this works without internet.'),
        value: settings.localNetwork,
        onChanged: (v) => setState(() {
          settings.localNetwork = v;
          if (!v && settings.tunnels == 0) settings.tunnels = 1;
        }),
      ),
      if (settings.localNetwork)
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Allow the web dashboard from the same network'),
          subtitle: const Text('Lets e.g. a laptop on this Wi-Fi open /admin. '
              'Set a password if others share the network.'),
          value: settings.lanDashboard,
          onChanged: (v) => setState(() => settings.lanDashboard = v),
        ),
      const SizedBox(height: 16),
      const Text('Tunnels (each handles ~200 students at once)'),
      const SizedBox(height: 8),
      SegmentedButton<int>(
        segments: [
          for (var i = settings.localNetwork ? 0 : 1; i <= 4; i++)
            ButtonSegment(value: i, label: Text('$i')),
        ],
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

  // ------------------------------------------------------------- overview --

  List<Widget> _overview(Map<String, Object?> st) {
    final up = DateTime.now().difference(c.runningSince!);
    String two(int v) => v.toString().padLeft(2, '0');
    final geo = st['geofence'] == true;
    final roster = c.server!.config.roster.length;
    return [
      Text('Up ${up.inHours}:${two(up.inMinutes % 60)}:${two(up.inSeconds % 60)}'
          '${roster > 0 ? ' · class list $roster IDs' : ''}',
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
      for (final (i, u) in c.lanUrls.indexed) _linkCard(u, 'Local network ${i + 1}',
          'For phones on this Wi-Fi / hotspot'),
      if (c.lanUrls.isEmpty && (c.tunnels?.tunnels.isEmpty ?? true))
        const Card(child: ListTile(
          leading: Icon(Icons.wifi_off, color: Colors.redAccent),
          title: Text('No student link'),
          subtitle: Text('No tunnels and no Wi-Fi/hotspot address. Turn on the hotspot '
              'or Wi-Fi, then end and restart the session.'),
        )),
    ];
  }

  // ------------------------------------------------------------- students --

  Widget _studentsTab(Map<String, Object?> st) {
    final geo = st['geofence'] == true;
    final q = normalizeDigits(_search.text.trim());
    final all = c.server!.allStudents();
    final rows = q.isEmpty ? all : all.where((x) =>
        '${x['id']}'.contains(q) || nameKey('${x['name']}').contains(nameKey(q))).toList();
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: TextField(
          controller: _search,
          onChanged: (_) => _redraw(),
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            hintText: 'Search name or ID (${all.length})',
            suffixIcon: _search.text.isEmpty ? null : IconButton(
                icon: const Icon(Icons.clear),
                onPressed: () => setState(_search.clear)),
          ),
        ),
      ),
      Expanded(
        child: rows.isEmpty
            ? const Center(child: Text('No students yet.'))
            : ListView.separated(
                itemCount: rows.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final x = rows[i];
                  final out = x['out'] == true;
                  return ListTile(
                    dense: true,
                    title: Text('${x['name']}', textDirection: TextDirection.rtl),
                    subtitle: Text('${x['id']} · ${'${x['timestamp']}'.substring(11)}'
                        '${x['edited'] == true ? ' · edited' : ''}'
                        '${x['shared_ip'] == true ? ' · shared IP' : ''}'
                        '${geo && x['gps'] != true ? ' · no GPS' : ''}'),
                    trailing: geo
                        ? Text(_dist(x['dist_m'] as int?) + (out ? ' ⚠' : ''),
                            style: TextStyle(color: out ? Colors.redAccent : null))
                        : null,
                  );
                },
              ),
      ),
    ]);
  }

  // ------------------------------------------------------------------ log --

  Widget _logTab() {
    final events = c.server!.store.events.reversed.toList();
    if (events.isEmpty) return const Center(child: Text('No edits or conflicts yet.'));
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: events.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final e = events[i];
        final kind = '${e['kind']}';
        final color = switch (kind) {
          'refused: ID in use' => Colors.redAccent,
          'different student' => Colors.amber,
          _ => Colors.greenAccent,
        };
        return ListTile(
          dense: true,
          leading: Icon(Icons.circle, size: 12, color: color),
          title: Text(kind, style: TextStyle(color: color, fontWeight: FontWeight.bold)),
          subtitle: Text('Was: ${e['old_id']} · ${e['old_name']}\n'
              'Now: ${e['new_id']} · ${e['new_name']}\n'
              '${'${e['time']}'.replaceFirst('T', ' ')} · ${e['ip']}'
              '${e['dist_m'] == null ? '' : ' · moved ${_dist(e['dist_m'] as int?)}'}'),
          isThreeLine: true,
        );
      },
    );
  }

  // -------------------------------------------------------------- helpers --

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

  Widget _linkButtons(String url, String title) => Wrap(children: [
        TextButton.icon(
          icon: const Icon(Icons.copy, size: 18),
          label: const Text('Copy'),
          onPressed: () => Clipboard.setData(ClipboardData(text: url)),
        ),
        TextButton.icon(
          icon: const Icon(Icons.share, size: 18),
          label: const Text('Share QR'),
          onPressed: () => shareQrs([(url, title)]),
        ),
        TextButton.icon(
          icon: const Icon(Icons.qr_code, size: 18),
          label: const Text('Show QR'),
          onPressed: () => Navigator.push(context, MaterialPageRoute(
              builder: (_) => QrPage(url: url, title: title))),
        ),
      ]);

  Widget _linkCard(String url, String title, String note) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.wifi, size: 16, color: Colors.greenAccent),
              const SizedBox(width: 8),
              Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            ]),
            Text(note, style: const TextStyle(fontSize: 12, color: Colors.white70)),
            const SizedBox(height: 6),
            SelectableText(url, style: const TextStyle(color: Colors.lightBlueAccent)),
            _linkButtons(url, title),
          ]),
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
              _linkButtons(t.url!, 'Tunnel ${t.index}'),
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
