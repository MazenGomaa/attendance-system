// CSV export, three files per session. Mirrors _write_raw / _write_final /
// _audit_csv in app.py (same columns, UTF-8 with BOM, \r\n line endings).
//   _Raw.csv      every submission in order, incl. refused and replaced values
//   _Final.csv    one row per student + shared-IP / same-name columns
//   _Audited.csv  Final + distance from the hall + status (geofence only)

import 'dart:io';

import 'logic.dart';
import 'model.dart';

String _field(String s) {
  if (s.contains(',') || s.contains('"') || s.contains('\n') || s.contains('\r')) {
    return '"${s.replaceAll('"', '""')}"';
  }
  return s;
}

void _writeCsv(String path, List<String> header, Iterable<List<String>> rows) {
  final b = StringBuffer('﻿');
  b.write('${header.map(_field).join(',')}\r\n');
  for (final r in rows) {
    b.write('${r.map(_field).join(',')}\r\n');
  }
  File(path).writeAsStringSync(b.toString());
}

String _opt(Object? v) => v == null ? '' : pyNum(v);
String _acc(Object? v) => v is num ? '${pyRound(v.toDouble())}' : '';

List<String> Function(Rec) _sharedIpIds(List<Rec> rows) {
  final byIp = <String, List<String>>{};
  for (final r in rows) {
    final ip = r['ip'] as String?;
    if (ip != null && ip.isNotEmpty) byIp.putIfAbsent(ip, () => []).add(r['id'] as String);
  }
  return (r) => (byIp[r['ip']] ?? const <String>[]).where((i) => i != r['id']).toList();
}

List<String> Function(Rec) _sameNameIds(List<Rec> rows) {
  final byName = <String, List<String>>{};
  for (final r in rows) {
    byName.putIfAbsent(nameKey(r['name'] as String), () => []).add(r['id'] as String);
  }
  return (r) => (byName[nameKey(r['name'] as String)] ?? const <String>[])
      .where((i) => i != r['id']).toList();
}

class ExportResult {
  ExportResult(this.finalPath, this.rawPath, this.auditPath);
  final String finalPath;
  final String rawPath;
  final String? auditPath;
  List<String> get all => [finalPath, rawPath, ?auditPath];
}

ExportResult writeExports(List<Rec> rows, List<Rec> log, String dir, String base,
    {required bool geofence, required double radiusKm, (double, double)? hall,
    String reason = 'export'}) {
  Directory(dir).createSync(recursive: true);
  final raw = '$dir/${base}_Raw.csv';
  _writeCsv(raw, const [
    'Seq', 'Time', 'Action', 'Match', 'Record', 'Name', 'ID', 'Prev_Name', 'Prev_ID',
    'Latitude', 'Longitude', 'Accuracy_m', 'Maps_Link', 'IP', 'Device', 'Note',
  ], log.map((e) {
    final rid = (e['rid'] as String?) ?? '';
    return [
      '${e['seq']}', e['time'] as String, e['action'] as String, e['match'] as String,
      rid.length > 8 ? rid.substring(0, 8) : rid,
      csvCell(e['name']), csvCell(e['id']), csvCell(e['prev_name']), csvCell(e['prev_id']),
      _opt(e['lat']), _opt(e['lng']), _acc(e['acc']),
      mapsLink(e['lat'], e['lng']), (e['ip'] as String?) ?? '', e['device'] as String,
      csvCell(e['note']),
    ];
  }));

  final fin = '$dir/${base}_Final.csv';
  final sameIp = _sharedIpIds(rows), sameName = _sameNameIds(rows);
  final edits = <String, int>{};
  for (final e in log) {
    if (e['action'] == 'updated') edits[e['rid'] as String] = (edits[e['rid']] ?? 0) + 1;
  }
  _writeCsv(fin, const [
    'Name', 'ID', 'Submitted_At', 'Last_Updated', 'Edits', 'Latitude', 'Longitude',
    'Accuracy_m', 'Maps_Link', 'IP', 'SameIP_Count', 'SameIP_IDs', 'SameName_IDs',
    'Added_Manually',
  ], rows.map((r) {
    final ips = sameIp(r), names = sameName(r);
    return [
      csvCell(r['name']), csvCell(r['id']), r['timestamp'] as String,
      (r['edited_at'] as String?) ?? '', '${edits[r['rid']] ?? 0}',
      _opt(r['lat']), _opt(r['lng']), _acc(r['acc']), mapsLink(r['lat'], r['lng']),
      (r['ip'] as String?) ?? '', '${ips.length + 1}', ips.join(' '), names.join(' '),
      r['manual'] == true ? 'yes' : '',
    ];
  }));
  stdout.writeln('[export:$reason] ${rows.length} students, ${log.length} submissions -> '
      '${base}_Final.csv, ${base}_Raw.csv');

  final audit = geofence ? _audit(rows, dir, base, radiusKm, hall) : null;
  return ExportResult(fin, raw, audit);
}

String _audit(List<Rec> rows, String dir, String base, double radiusKm,
    (double, double)? hall) {
  final path = '$dir/${base}_Audited.csv';
  final sameIp = _sharedIpIds(rows), sameName = _sameNameIds(rows);
  final center = hall ?? hallCenter(rows);

  // ~8 m grid for O(n) near-duplicate GPS detection (3x3 neighbourhood).
  const cellDeg = 0.008 / 111.0;
  final grid = <(int, int), List<Rec>>{};
  for (final r in rows) {
    final lat = r['lat'], lng = r['lng'];
    if (lat is num && lng is num) {
      grid.putIfAbsent(((lat / cellDeg).truncate(), (lng / cellDeg).truncate()), () => []).add(r);
    }
  }
  // Same IP and within ~8 m: one phone or hotspot registering friends. Same
  // spot alone means nothing in a lecture hall (indoor fixes snap together).
  bool nearDuplicate(Rec r) {
    final lat = r['lat'], lng = r['lng'];
    if (lat is! num || lng is! num || ((r['ip'] as String?) ?? '').isEmpty) return false;
    final gx = (lat / cellDeg).truncate(), gy = (lng / cellDeg).truncate();
    for (var dx = -1; dx <= 1; dx++) {
      for (var dy = -1; dy <= 1; dy++) {
        for (final o in grid[(gx + dx, gy + dy)] ?? const <Rec>[]) {
          if (identical(o, r) || o['id'] == r['id'] || o['ip'] != r['ip']) continue;
          if (haversineKm(lat.toDouble(), lng.toDouble(), (o['lat'] as num).toDouble(),
                  (o['lng'] as num).toDouble()) * 1000 <= 8) {
            return true;
          }
        }
      }
    }
    return false;
  }

  _writeCsv(path, const [
    'Name', 'ID', 'Submitted_At', 'Last_Updated', 'Latitude', 'Longitude', 'Accuracy_m',
    'Maps_Link', 'Distance_km', 'IP', 'SameIP_Count', 'SameIP_IDs', 'Status',
  ], rows.map((r) {
    final ip = ((r['ip'] as String?) ?? '').isEmpty ? 'unknown' : r['ip'] as String;
    final ips = sameIp(r);
    final lat = r['lat'], lng = r['lng'], acc = r['acc'];
    final notes = <String>[];
    var dist = '';
    if (lat is num && lng is num && center != null) {
      final d = haversineKm(center.$1, center.$2, lat.toDouble(), lng.toDouble());
      dist = pyRound3(d);
      final where = locationCheck(d, acc, radiusKm);
      if (where == 'out') notes.add('Out of bounds');
      if (where == 'low') notes.add('Low accuracy (±${_acc(acc)} m)');
    } else if (r['manual'] == true) {
      notes.add('added manually');
    } else {
      notes.add('No GPS');
    }
    if (ips.isNotEmpty) notes.add('shared IP x${ips.length + 1}');
    if (nearDuplicate(r)) notes.add('duplicate location');
    final names = sameName(r);
    if (names.isNotEmpty) notes.add('same name as ID ${names.join('/')}');
    if (lat is num && (acc == null || acc == 0)) notes.add('no accuracy (possible spoof)');
    final status = notes.isEmpty
        ? 'Valid'
        : notes.length == 1 && notes.first == 'added manually'
        ? 'Added manually'
        : '${notes.contains('Out of bounds') || notes.contains('No GPS') ? 'FLAGGED: ' : 'SUSPECT: '}'
            '${notes.join(', ')}';
    return [
      csvCell(r['name']), csvCell(r['id']), r['timestamp'] as String,
      (r['edited_at'] as String?) ?? '', _opt(lat), _opt(lng), _acc(acc),
      mapsLink(lat, lng), dist, ip, '${ips.length + 1}', ips.join(' '), status,
    ];
  }));
  return path;
}
