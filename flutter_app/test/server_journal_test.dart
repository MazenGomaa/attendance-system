import 'dart:convert';
import 'dart:io';

import 'package:attendance_host/server/logic.dart';
import 'package:attendance_host/server/model.dart';
import 'package:attendance_host/server/server.dart';
import 'package:flutter_test/flutter_test.dart';

/// A browser arriving through the tunnel from [ip], with its own cookie.
class _Phone {
  _Phone(this.port, this.ip, this.device);
  final int port;
  final String ip;
  final String device;
  String? cookie;

  Future<Map<String, dynamic>> post(String path, Map<String, Object?> body) async {
    final c = HttpClient();
    try {
      final req = await c.post('127.0.0.1', port, path);
      req.headers
        ..contentType = ContentType.json
        ..set('cf-connecting-ip', ip);
      if (cookie != null) req.headers.set('cookie', cookie!);
      req.write(jsonEncode(body));
      final res = await req.close();
      final set = res.headers['set-cookie'];
      if (set != null && set.isNotEmpty) cookie = set.first.split(';').first;
      return jsonDecode(await utf8.decodeStream(res)) as Map<String, dynamic>;
    } finally {
      c.close();
    }
  }

  Future<Map<String, dynamic>> submit(String id, String name) async {
    final tok = (await post('/api/init', {'deviceId': device}))['page_token'];
    return post('/submit', {'id': id, 'name': name, 'deviceId': device, 'page_token': tok,
        'lat': 30.0444, 'lng': 31.2357, 'accuracy': 15});
  }
}

AttendanceServer _server(String dir, String journal, ServerConfig cfg) => AttendanceServer(
    config: cfg, statics: const {}, exportDir: '$dir/exports', journalPath: journal);

ServerConfig _config(String secret) => ServerConfig()
  ..courseName = 'Journal test'
  ..pageSecret = secret
  ..geofence = true
  ..auditRadiusKm = 0.5;

void main() {
  test('a crashed session is rebuilt exactly from its journal', () async {
    final dir = (await Directory.systemTemp.createTemp('journal')).path;
    final journal = '$dir/session.jsonl';
    final secret = randomHex();

    final s1 = _server(dir, journal, _config(secret));
    await s1.start(port: 0);
    final a = _Phone(s1.port, '41.1.1.1', 'dev-aaaaaaaa');
    final b = _Phone(s1.port, '41.1.1.1', 'dev-bbbbbbbb');
    final c = _Phone(s1.port, '41.2.2.2', 'dev-cccccccc');
    expect((await a.submit('1001', 'محمد احمد علي حسن'))['mode'], 'created');
    expect((await b.submit('1002', 'سارة محمود علي حسن'))['mode'], 'created');
    expect((await a.submit('1009', 'محمد احمد علي حسن'))['mode'], 'updated');
    expect((await c.submit('1002', 'خالد يوسف عمر احمد'))['ok'], false);   // refused
    expect(s1.addStudent('1004', 'يوسف عمر خالد محمود').$2['mode'], 'created');   // no phone
    s1.resetDevices();
    s1.setHall((30.05, 31.24));
    // "Crash": no export, no clean shutdown.
    await s1.stop(export: false);

    // A torn half-line at the end (killed mid-write) must be ignored.
    File(journal).writeAsStringSync('{"op":"created","rec":{"ri', mode: FileMode.append);

    final cfg2 = _config(secret);
    final s2 = _server(dir, journal, cfg2);
    expect(s2.resumeFromJournal(), isTrue);
    expect(cfg2.courseName, 'Journal test');
    expect(s2.store.records.map((r) => r['id']), ['1009', '1002', '1004']);
    expect(s2.store.records.last['manual'], isTrue);
    expect(s2.store.records.first['edited_at'], isNotNull);
    expect(s2.store.log.map((e) => e['action']), ['created', 'created', 'updated', 'refused', 'created']);
    expect(s2.store.events.map((e) => e['kind']), ['ID corrected', 'refused: ID in use']);
    expect(s2.store.idToRid.keys.toSet(), {'1009', '1002', '1004'});
    expect(s2.addStudent('1004', 'يوسف عمر خالد محمود').$2['mode'], 'exists');
    expect(s2.store.clientToRid, isEmpty);   // the reset was replayed too
    expect(cfg2.hall, (30.05, 31.24));        // and the pinned hall

    // The resumed server keeps working: after the reset, same ID + name updates.
    await s2.start(port: 0);
    final a2 = _Phone(s2.port, '41.1.1.1', 'dev-aaaaaaaa');
    expect((await a2.submit('1009', 'محمد احمد علي حسن'))['mode'], 'updated');
    // ...and a brand-new student is still created.
    final d = _Phone(s2.port, '41.3.3.3', 'dev-dddddddd');
    expect((await d.submit('1003', 'عمر خالد يوسف احمد'))['mode'], 'created');
    await s2.stop(export: false);

    // Third start: the prefill link (device -> record) survives a restart.
    final s3 = _server(dir, journal, _config(secret));
    s3.resumeFromJournal();
    await s3.start(port: 0);
    final again = await _Phone(s3.port, '41.3.3.3', 'dev-dddddddd')
        .post('/api/init', {'deviceId': 'dev-dddddddd'});
    expect((again['record'] as Map)['id'], '1003');
    await s3.stop(export: false);
    await Directory(dir).delete(recursive: true);
  });

  test('coarse fixes are low accuracy, not out of bounds; median ignores them', () {
    expect(locationCheck(0.3, 20, 0.5), '');
    expect(locationCheck(0.847, 2000, 0.5), 'low');   // cell-tower centroid
    expect(locationCheck(2.5, 2000, 0.5), 'low');
    expect(locationCheck(3.0, 2000, 0.5), 'out');     // even the near edge is outside
    expect(locationCheck(2.0, 20, 0.5), 'out');
    expect(locationCheck(2.0, 0, 0.5), 'out');
    final rows = [
      {'lat': 30.0, 'lng': 31.0, 'acc': 15},
      {'lat': 30.0, 'lng': 31.0, 'acc': 20},
      {'lat': 30.1, 'lng': 31.1, 'acc': 2000},
      {'lat': 30.1, 'lng': 31.1, 'acc': 2000},
      {'lat': 30.1, 'lng': 31.1, 'acc': 2000},
    ];
    expect(hallCenter(rows), (30.0, 31.0));
    expect(hallCenter(rows.skip(2)), (30.1, 31.1));   // none precise: use them all
  });

  test('Arabic-Indic digits normalise and spelling variants fold', () {
    expect(normalizeDigits('١٠٠٥'), '1005');
    expect(normalizeDigits('۱۲۳'), '123');
    expect(nameKey('محمد أحمد علي حسن'), nameKey('محمد احمد علي حسن'));
    expect(editKind('1001', 'محمد احمد علي حسن', '1009', 'محمد أحمد علي حسن'), 'ID corrected');
  });
}
