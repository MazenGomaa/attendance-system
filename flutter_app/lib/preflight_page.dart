import 'package:flutter/material.dart';

import 'background_guide.dart';
import 'platform.dart';
import 'preflight.dart';
import 'session.dart';

/// "Pre-class check": a full rehearsal with a throwaway tunnel and a test
/// submission, plus the phone settings a long session depends on.
class PreflightPage extends StatefulWidget {
  const PreflightPage({super.key, required this.controller});
  final HostController controller;

  @override
  State<PreflightPage> createState() => _PreflightPageState();
}

class _PreflightPageState extends State<PreflightPage> {
  Preflight? p;

  Future<void> _run() async {
    final c = widget.controller;
    final paths = await c.paths();
    final pf = Preflight(
      binary: '${paths['nativeLibDir']}/libcloudflared.so',
      workDir: paths['filesDir']!,
      statics: await c.loadStatics(),
      deviceInfo: HostPlatform.deviceInfo,
    );
    pf.addListener(() {
      if (mounted) setState(() {});
    });
    setState(() => p = pf);
    await pf.run();
  }

  Widget _icon(StepStatus s) => switch (s) {
        StepStatus.ok => const Icon(Icons.check_circle, color: Colors.greenAccent),
        StepStatus.warn => const Icon(Icons.warning_amber, color: Colors.amber),
        StepStatus.fail => const Icon(Icons.cancel, color: Colors.redAccent),
        StepStatus.running => const SizedBox(width: 22, height: 22,
            child: CircularProgressIndicator(strokeWidth: 2)),
        StepStatus.pending => const Icon(Icons.radio_button_unchecked, color: Colors.white38),
      };

  Widget? _fixButton(PreflightStep s) {
    if (s.status != StepStatus.fail && s.status != StepStatus.warn) return null;
    final VoidCallback? action = switch (s.fix) {
      'battery' => HostPlatform.requestBatteryExemption,
      'notifications' => () => HostPlatform.openSettings('notifications'),
      _ => null,
    };
    return action == null ? null : TextButton(onPressed: action, child: const Text('Fix'));
  }

  @override
  Widget build(BuildContext context) {
    final pf = p;
    final busy = pf?.running ?? false;
    return Scaffold(
      appBar: AppBar(title: const Text('Pre-class check')),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton.icon(
            icon: const Icon(Icons.play_arrow),
            label: Text(busy ? 'Checking… (up to a minute)' : (pf == null ? 'Run check' : 'Run again')),
            onPressed: busy || widget.controller.running ? null : _run,
          ),
        ),
      ),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(16), children: [
          if (widget.controller.running)
            const Card(child: ListTile(
              leading: Icon(Icons.info_outline),
              title: Text('A session is running'),
              subtitle: Text('End it first; the check uses its own temporary tunnel.'),
            )),
          const Text('Run this a few minutes before class, on the network you will use. '
              'It opens a temporary tunnel, loads the student page through it and records '
              'a test submission, then throws everything away.'),
          const SizedBox(height: 12),
          if (pf != null)
            for (final s in pf.steps)
              Card(
                child: ListTile(
                  leading: _icon(s.status),
                  title: Text(s.title),
                  subtitle: s.detail.isEmpty ? null : Text(s.detail),
                  trailing: _fixButton(s),
                ),
              ),
          if (pf != null && !busy)
            Card(
              color: pf.passed ? Colors.green.shade900 : Colors.red.shade900,
              child: ListTile(
                title: Text(pf.passed ? 'Ready for class' : 'Fix the red items, then run again'),
                subtitle: const Text("Also check this phone's brand-specific background "
                    'settings (they can\'t be tested automatically).'),
                trailing: TextButton(
                  onPressed: () => Navigator.push(context, MaterialPageRoute(
                      builder: (_) => const BackgroundGuidePage())),
                  child: const Text('Open'),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}
