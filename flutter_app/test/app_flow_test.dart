import 'dart:convert';
import 'dart:io';

import 'package:attendance_host/main.dart';
import 'package:attendance_host/server/logic.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Drives the real app UI with the Android side faked: setup, roster import,
/// start, live tabs, new subject, end.
/// Lets real I/O (server bind, files) and the test's fake clock both advance
/// until [done] is true.
Future<void> settleUntil(WidgetTester tester, bool Function() done) async {
  for (var i = 0; i < 80 && !done(); i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  late Directory files;
  final calls = <String>[];

  setUp(() async {
    files = await Directory.systemTemp.createTemp('appflow');
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('attendance/host'),
      (call) async {
        calls.add(call.method);
        switch (call.method) {
          case 'paths':
            return {'nativeLibDir': files.path, 'filesDir': files.path};
          case 'deviceInfo':
            return {'batteryOptimizationIgnored': true, 'model': 'test'};
          case 'pickTextFile':
            return {'name': 'class.csv',
                'bytes': Uint8List.fromList(utf8.encode('ID,Name\n001001,a\n١٠٠٢,b\n'))};
          case 'saveToDownloads':
            return 'Download/Attendance/${(call.arguments as Map)['path'].split('/').last}';
          default:
            return null;
        }
      },
    );
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('attendance/host'), null);
    await files.delete(recursive: true);
  });

  testWidgets('setup -> roster -> start -> tabs -> new subject -> end', (tester) async {
    await tester.binding.setSurfaceSize(const Size(500, 1400));
    await tester.pumpWidget(const HostApp());
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await tester.pump();
    expect(find.text('Start session'), findsOneWidget);
    expect(find.text('No class list: any numeric ID is accepted'), findsOneWidget);

    // Import a class list (leading zeros dropped, Arabic-Indic digits normalised).
    await tester.tap(find.byTooltip('Import class list'));
    await settleUntil(tester, () => find.text('Class list: 2 IDs').evaluate().isNotEmpty);
    expect(find.text('Class list: 2 IDs'), findsOneWidget);
    final saved = jsonDecode(File('${files.path}/roster.json').readAsStringSync()) as Map;
    expect(saved['ids'], ['1001', '1002']);

    // A course name and 1 tunnel (no cloudflared binary here, so the tunnel
    // just reports failed; the server and screens still run).
    await tester.enterText(find.widgetWithText(TextField, 'Course / subject name'), 'Physics 1');
    await tester.tap(find.text('1'));
    await tester.pump();

    final state = tester.state(find.byType(HomePage)) as dynamic;
    await tester.tap(find.text('Start session'));
    await settleUntil(tester, () => state.c.running == true);
    expect(state.c.running, isTrue);
    expect(find.text('Physics 1'), findsOneWidget);
    expect(find.text('Students (0)'), findsOneWidget);
    expect(calls, contains('startService'));
    // Settings were remembered (no password stored).
    final prefs = jsonDecode(File('${files.path}/settings.json').readAsStringSync()) as Map;
    expect(prefs['course'], 'Physics 1');
    expect(prefs['tunnels'], 1);
    expect(prefs.containsKey('password'), isFalse);

    // After a resume the links are new: a red banner until acknowledged.
    state.c.resumedLinksPending = true;
    await tester.pump(const Duration(seconds: 3));
    expect(find.textContaining('Session resumed with NEW student links'), findsOneWidget);
    await tester.tap(find.text("Done, I've shared it"));
    await tester.pump();
    expect(find.textContaining('Session resumed with NEW student links'), findsNothing);

    // A student submits (straight into the server: flutter_test blocks real HTTP).
    final srv = state.c.server;
    srv.store.addRecord({'rid': 'r1', 'name': 'محمد احمد علي حسن', 'id': '1001',
        'timestamp': isoSeconds(DateTime.now()), 'edited_at': null,
        'lat': null, 'lng': null, 'acc': null, 'ip': '192.168.1.20'});
    srv.store.events.add({'time': isoSeconds(DateTime.now()), 'old_id': '1009',
        'old_name': 'x', 'new_id': '1001', 'new_name': 'y', 'ip': '1.1.1.1',
        'dist_m': null, 'kind': 'ID corrected'});
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('Students (1)'), findsOneWidget);
    await tester.tap(find.text('Students (1)'));
    await tester.pumpAndSettle();
    expect(find.text('محمد احمد علي حسن'), findsOneWidget);
    await tester.tap(find.text('Log (1)'));
    await tester.pumpAndSettle();
    expect(find.text('ID corrected'), findsOneWidget);

    // New subject: previous one exported and saved, links stay.
    await tester.tap(find.byTooltip('Session actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New subject…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'New subject name'), 'Physics 2');
    await tester.tap(find.text('Start'));
    // (Not "Physics 2": that text is also in the dialog's input box.)
    await settleUntil(tester, () => find.text('Students (0)').evaluate().isNotEmpty);
    await tester.pumpAndSettle();   // let the dialog finish closing
    expect(find.text('Physics 2'), findsOneWidget);
    expect(find.text('Students (0)'), findsOneWidget);
    expect(Directory('${files.path}/exports').listSync()
        .any((f) => f.path.contains('Physics_1') && f.path.endsWith('_Final.csv')), isTrue);

    // End session.
    await tester.tap(find.text('End session'));
    await tester.pumpAndSettle();
    // The dialog's button (the bottom bar has one with the same label).
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.widgetWithText(FilledButton, 'End session')));
    await settleUntil(tester, () => find.text('Session ended').evaluate().isNotEmpty);
    expect(state.c.running, isFalse);
    expect(find.text('Session ended'), findsOneWidget);
    expect(calls, contains('stopService'));
    expect(calls, contains('saveToDownloads'));

    await tester.pumpWidget(const SizedBox());   // dispose timers
  });
}
