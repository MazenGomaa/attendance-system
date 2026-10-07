import 'package:flutter/material.dart';

import 'platform.dart';

/// What to change on each phone brand so Android doesn't freeze the session
/// with the screen off. Stock Android only needs the battery exemption;
/// several makers add their own extra killers on top.
({String name, List<String> steps, String slug}) brandAdvice(String manufacturer) {
  final m = manufacturer.toLowerCase();
  if (m.contains('samsung')) {
    return (
      name: 'Samsung',
      slug: 'samsung',
      steps: [
        'Settings → Battery → Background usage limits.',
        'Open "Never sleeping apps" and add Attendance Host.',
        'Make sure it is NOT in "Sleeping apps" or "Deep sleeping apps".',
        'Optional: turn off "Put unused apps to sleep" on that same screen.',
      ],
    );
  }
  if (m.contains('xiaomi') || m.contains('redmi') || m.contains('poco')) {
    return (
      name: 'Xiaomi / Redmi / POCO',
      slug: 'xiaomi',
      steps: [
        'Security app → Autostart → turn on Attendance Host.',
        'App info → Battery saver → "No restrictions".',
        'Recent apps: long-press Attendance Host → tap the lock icon.',
      ],
    );
  }
  if (m.contains('oppo') || m.contains('realme') || m.contains('oneplus')) {
    return (
      name: 'OPPO / realme / OnePlus',
      slug: 'oppo',
      steps: [
        'App info → Battery usage → allow background activity / "Don\'t optimise".',
        'Auto-launch (Startup manager) → turn on Attendance Host.',
        'Recent apps: lock Attendance Host so it isn\'t cleared.',
      ],
    );
  }
  if (m.contains('vivo') || m.contains('iqoo')) {
    return (
      name: 'vivo / iQOO',
      slug: 'vivo',
      steps: [
        'Settings → Battery → Background power consumption → allow Attendance Host.',
        'i Manager → App manager → Autostart → turn on Attendance Host.',
      ],
    );
  }
  if (m.contains('huawei') || m.contains('honor')) {
    return (
      name: 'Huawei / Honor',
      slug: 'huawei',
      steps: [
        'Settings → Battery → App launch → Attendance Host → "Manage manually".',
        'Turn on Auto-launch, Secondary launch and Run in background.',
      ],
    );
  }
  return (
    name: manufacturer.isEmpty ? 'This phone' : manufacturer,
    slug: m.isEmpty ? '' : m,
    steps: ['App info → Battery → "Unrestricted" (if your phone has it).'],
  );
}

class BackgroundGuidePage extends StatefulWidget {
  const BackgroundGuidePage({super.key});

  @override
  State<BackgroundGuidePage> createState() => _BackgroundGuidePageState();
}

class _BackgroundGuidePageState extends State<BackgroundGuidePage>
    with WidgetsBindingObserver {
  Map<String, Object?> info = const {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Coming back from a settings screen: re-read what changed.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    try {
      info = await HostPlatform.deviceInfo();
    } catch (_) {}
    if (mounted) setState(() {});
  }

  Widget _status(String title, bool ok, String fix, VoidCallback onFix) => Card(
        child: ListTile(
          leading: Icon(ok ? Icons.check_circle : Icons.error,
              color: ok ? Colors.greenAccent : Colors.redAccent),
          title: Text(title),
          subtitle: ok ? const Text('OK') : Text(fix),
          trailing: ok ? null : FilledButton(onPressed: onFix, child: const Text('Fix')),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final advice = brandAdvice('${info['manufacturer'] ?? ''}');
    return Scaffold(
      appBar: AppBar(title: const Text('Keep running in the background')),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(16), children: [
          const Text('Android may freeze apps when the screen is off. Do these once on '
              'this phone so a session survives a whole lecture.'),
          const SizedBox(height: 12),
          _status('Battery optimisation off', info['batteryOptimizationIgnored'] == true,
              'Android may pause the server with the screen off.',
              HostPlatform.requestBatteryExemption),
          _status('Notifications allowed', info['notificationsGranted'] == true,
              'Needed for link-changed alerts and the running-session notice.',
              () => HostPlatform.openSettings('notifications')),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${advice.name}: extra settings',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                const SizedBox(height: 6),
                for (final (i, step) in advice.steps.indexed)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text('${i + 1}. $step'),
                  ),
                const SizedBox(height: 6),
                Wrap(spacing: 8, children: [
                  FilledButton.icon(
                    icon: const Icon(Icons.settings),
                    label: const Text('Open settings'),
                    onPressed: () async {
                      final opened = await HostPlatform.openSettings('brand');
                      if (opened == 'app' && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                            content: Text("Opened this app's info page; follow the steps "
                                'from there.')));
                      }
                    },
                  ),
                  if (advice.slug.isNotEmpty)
                    OutlinedButton(
                      onPressed: () => HostPlatform.openUrl(
                          'https://dontkillmyapp.com/${advice.slug}'),
                      child: const Text('More help (dontkillmyapp.com)'),
                    ),
                ]),
                const SizedBox(height: 4),
                const Text("These brand settings can't be checked automatically; "
                    'the pre-class check shows whether the session really survives.',
                    style: TextStyle(fontSize: 12, color: Colors.white60)),
              ]),
            ),
          ),
        ]),
      ),
    );
  }
}
