// Session config and in-memory store. Mirrors state.py.

import 'dart:convert';
import 'dart:io';

typedef Rec = Map<String, Object?>;

class ServerConfig {
  String courseName = 'Session';
  DateTime startedAt = DateTime.now();
  bool ipTracking = false;
  List<String> tunnelUrls = [];
  bool forceSingleOrigin = true;
  Set<String> roster = {};
  bool geofence = false;
  double auditRadiusKm = 2.0;
  /// Hall centre pinned by the admin; null = median of precise fixes.
  (double, double)? hall;
  String pageSecret = '';
  int throttleN = 15;
  int throttleWindow = 20;
  List<String> adminCidrs = [];
  String adminPwHash = '';
  String adminPwSalt = '';
  bool ended = false;

  String sessionId() {
    final t = startedAt;
    String p(int v, [int w = 2]) => v.toString().padLeft(w, '0');
    final stamp = '${t.year}-${p(t.month)}-${p(t.day)}_${p(t.hour)}-${p(t.minute)}-'
        '${p(t.second)}_${p(t.millisecond * 1000 + t.microsecond, 6)}';
    final safe = courseName.split('').map((c) =>
        RegExp(r'[\p{L}\p{N} _-]', unicode: true).hasMatch(c) ? c : '_').join()
        .trim().replaceAll(' ', '_');
    return '${safe.isEmpty ? 'Session' : safe}_$stamp';
  }
}

/// [lat, lng] (journal form) -> record; anything else -> null.
(double, double)? hallFromJson(Object? v) =>
    v is List && v.length == 2 && v[0] is num && v[1] is num
        ? ((v[0] as num).toDouble(), (v[1] as num).toDouble())
        : null;

List<double>? hallToJson((double, double)? h) => h == null ? null : [h.$1, h.$2];

class Store {
  final List<Rec> records = [];
  final Map<String, Rec> ridIndex = {};
  final Map<String, String> clientToRid = {};
  final Map<String, String> idToRid = {};
  final Map<String, List<String>> ipToRids = {};
  final Set<String> seenIps = {};
  /// Edits + refused ID conflicts (admin view).
  final List<Rec> events = [];
  /// Append-only history of every accepted or identity-refused submission:
  /// what the Raw CSV exports, so nothing an edit replaced is ever lost.
  final List<Rec> log = [];

  Rec? get(String? rid) => rid == null ? null : ridIndex[rid];

  void addRecord(Rec r) {
    records.add(r);
    ridIndex[r['rid'] as String] = r;
  }

  void addIp(String? ip, String rid) {
    if (ip == null || ip.isEmpty) return;
    final l = ipToRids.putIfAbsent(ip, () => []);
    if (!l.contains(rid)) l.add(rid);
  }

  void dropIp(String? ip, String rid) {
    final l = ip == null ? null : ipToRids[ip];
    if (l == null) return;
    l.remove(rid);
    if (l.isEmpty) ipToRids.remove(ip);
  }

  /// Clear browser identity links; rebuild ID and IP indices from surviving
  /// records so a student who re-submits after a reset updates their record.
  void clearDevices() {
    clientToRid.clear();
    seenIps.clear();
    idToRid.clear();
    ipToRids.clear();
    for (final r in records) {
      idToRid[r['id'] as String] = r['rid'] as String;
      final ip = r['ip'] as String?;
      if (ip != null && ip.isNotEmpty) addIp(ip, r['rid'] as String);
    }
  }

  void clearAll() {
    records.clear();
    ridIndex.clear();
    events.clear();
    log.clear();
    clientToRid.clear();
    idToRid.clear();
    ipToRids.clear();
    seenIps.clear();
  }
}

/// Crash-safe history of every state change, one JSON object per line.
/// Written synchronously (no await, so it fits inside the submit critical
/// section); replaying it rebuilds the Store exactly.
class Journal {
  Journal(this.path) : _file = File(path).openSync(mode: FileMode.append);
  final String path;
  final RandomAccessFile _file;

  void write(Map<String, Object?> entry) {
    _file.writeStringSync('${jsonEncode(entry)}\n');
  }

  void close() {
    try {
      _file.closeSync();
    } catch (_) {}
  }

  /// Rebuild config + store from a journal file. Returns false if empty.
  static bool replay(String path, ServerConfig config, Store store) {
    final f = File(path);
    if (!f.existsSync()) return false;
    var any = false;
    for (final line in f.readAsLinesSync()) {
      if (line.trim().isEmpty) continue;
      final Map<String, Object?> e;
      try {
        e = (jsonDecode(line) as Map).cast<String, Object?>();
      } catch (_) {
        continue;   // a torn last line from a crash mid-write
      }
      any = true;
      apply(e, config, store);
    }
    return any;
  }

  static void apply(Map<String, Object?> e, ServerConfig config, Store store) {
    switch (e['op']) {
      case 'session':
        store.clearAll();
        config.courseName = e['course'] as String;
        config.startedAt = DateTime.parse(e['started_at'] as String);
        config.ended = false;
        if (e.containsKey('hall')) config.hall = hallFromJson(e['hall']);
      case 'hall':
        config.hall = hallFromJson(e['hall']);
      case 'created':
        final rec = Map<String, Object?>.from(e['rec'] as Map);
        store.addRecord(rec);
        final rid = rec['rid'] as String;
        store.clientToRid[e['device'] as String] = rid;
        store.clientToRid[e['token'] as String] = rid;
        store.idToRid[rec['id'] as String] = rid;
        store.addIp(rec['ip'] as String?, rid);
        if (config.ipTracking && rec['ip'] != null) store.seenIps.add(rec['ip'] as String);
        store.log.add(Map<String, Object?>.from(e['log'] as Map));
      case 'updated':
        final rid = e['rid'] as String;
        final rec = store.get(rid);
        if (rec == null) return;
        final oldId = rec['id'] as String;
        final newId = e['id'] as String;
        if (oldId != newId) {
          store.idToRid.remove(oldId);
          store.idToRid[newId] = rid;
        }
        if (rec['ip'] != e['ip']) {
          store.dropIp(rec['ip'] as String?, rid);
          store.addIp(e['ip'] as String?, rid);
        }
        rec['name'] = e['name'];
        rec['id'] = newId;
        rec['edited_at'] = e['edited_at'];
        rec['ip'] = e['ip'];
        if (e['lat'] != null) {
          rec['lat'] = e['lat'];
          rec['lng'] = e['lng'];
          rec['acc'] = e['acc'];
        }
        store.clientToRid[e['device'] as String] = rid;
        store.clientToRid[e['token'] as String] = rid;
        store.log.add(Map<String, Object?>.from(e['log'] as Map));
        store.events.add(Map<String, Object?>.from(e['event'] as Map));
      case 'refused':
        store.log.add(Map<String, Object?>.from(e['log'] as Map));
        if (e['event'] != null) store.events.add(Map<String, Object?>.from(e['event'] as Map));
      case 'reset_devices':
        store.clearDevices();
      case 'ended':
        config.ended = true;
    }
  }
}
