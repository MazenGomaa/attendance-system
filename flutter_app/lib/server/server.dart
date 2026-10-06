// The attendance server in Dart: a port of app.py with the same endpoints,
// messages, identity rules and security checks. Pure dart:io (no Flutter), so
// it runs in the app and standalone (bin/serve.dart) for tests/scenarios.py.
//
// Atomicity: like the Python server, one isolate handles all requests and the
// submit resolve -> dedup -> write block has no `await`, so two submissions
// can't interleave. Every state change is also written to a Journal first.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'exporter.dart';
import 'logic.dart';
import 'model.dart';

const String cookieName = 'att_token';
const int maxBody = 16 * 1024;   // largest legitimate POST is a few hundred bytes

/// A static file the server can return: bytes + content type.
class StaticFile {
  const StaticFile(this.bytes, this.contentType);
  final List<int> bytes;
  final String contentType;
}

class _Reply {
  _Reply(this.status, this.body, this.contentType, [Map<String, String>? headers])
      : headers = headers ?? {};
  final int status;
  final List<int> body;
  final String contentType;
  final Map<String, String> headers;
  final List<String> cookies = [];
}

_Reply _json(Object data, [int status = 200]) =>
    _Reply(status, utf8.encode(jsonEncode(data)), 'application/json');

_Reply _reject(String msg, [int status = 409]) => _json({'ok': false, 'error': msg}, status);

class AttendanceServer {
  AttendanceServer({
    required this.config,
    required this.statics,
    required this.exportDir,
    this.journalPath,
    this.downloadsDir,
    this.onEndSession,
  });

  final ServerConfig config;
  final Store store = Store();
  /// Keyed by file name: index.html, index.js, admin.html, ...
  final Map<String, StaticFile> statics;
  final String exportDir;
  final String? journalPath;
  /// Where End session copies the CSVs (null: don't copy).
  final String? downloadsDir;
  /// Called after End session has exported, to stop the host (tunnels etc.).
  final void Function()? onEndSession;

  HttpServer? _http;
  Journal? _journal;
  int get port => _http?.port ?? 0;

  // --- throttles (same limits as app.py) ---
  final Map<String, List<double>> _throttle = {};
  final Map<String, List<double>> _ipThrottle = {};
  final Map<String, List<double>> _loginThrottle = {};
  static const int _ipNewLimit = 300;
  static const double _ipWindow = 60;
  static const int _loginMax = 5;
  static const double _loginWindow = 60;
  final Stopwatch _clock = Stopwatch()..start();
  double get _now => _clock.elapsedMicroseconds / 1e6;

  /// Rebuild state from the journal (crash recovery). Call before start().
  bool resumeFromJournal() {
    final p = journalPath;
    if (p == null) return false;
    return Journal.replay(p, config, store);
  }

  Future<void> start({String address = '127.0.0.1', int port = 8000}) async {
    if (journalPath != null) {
      _journal = Journal(journalPath!);
      if (store.records.isEmpty && store.log.isEmpty) _journalSession();
    }
    final s = await HttpServer.bind(address, port);
    s.defaultResponseHeaders.clear();   // we set our own security headers
    s.autoCompress = false;
    s.idleTimeout = const Duration(seconds: 30);
    _http = s;
    s.listen(_handle);
  }

  void _journalSession() => _journal?.write({
        'op': 'session', 'course': config.courseName,
        'started_at': config.startedAt.toIso8601String(),
      });

  /// Stop serving. Exports CSVs first unless [export] is false.
  Future<ExportResult?> stop({bool export = true, String reason = 'shutdown'}) async {
    ExportResult? res;
    if (export) {
      try {
        res = exportNow(reason);
      } catch (e) {
        stderr.writeln('[export:$reason] ERROR writing CSV: $e');
      }
    }
    await _http?.close(force: true);
    _http = null;
    _journal?.close();
    _journal = null;
    return res;
  }

  ExportResult exportNow([String reason = 'export']) => writeExports(
      List.of(store.records), List.of(store.log), exportDir, config.sessionId(),
      geofence: config.geofence, radiusKm: config.auditRadiusKm, reason: reason);

  // =========================================================================
  // HTTP plumbing
  // =========================================================================

  Future<void> _handle(HttpRequest req) async {
    _Reply reply;
    try {
      reply = await _dispatch(req);
    } catch (e, st) {
      stderr.writeln('[server] ${req.method} ${req.uri.path} failed: $e\n$st');
      reply = _json({'ok': false, 'error': 'server error'}, 500);
    }
    final res = req.response;
    try {
      res.statusCode = reply.status;
      final h = res.headers;
      h.set('content-type', reply.contentType);
      h.set('x-content-type-options', 'nosniff');
      h.set('x-frame-options', 'DENY');
      h.set('referrer-policy', 'same-origin');
      h.set('permissions-policy', 'geolocation=(self), camera=(), microphone=()');
      h.set('content-security-policy',
          "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; "
          "img-src 'self' data:; connect-src 'self'; object-src 'none'; "
          "base-uri 'none'; form-action 'self'; frame-ancestors 'none'");
      if (!req.uri.path.startsWith('/static')) h.set('cache-control', 'no-store');
      reply.headers.forEach(h.set);
      for (final c in reply.cookies) {
        h.add('set-cookie', c);
      }
      res.contentLength = reply.body.length;
      if (req.method != 'HEAD') res.add(reply.body);
      await res.close();
    } catch (_) {
      // client went away
    }
  }

  /// Reads the body with a hard cap; null means "too large".
  Future<List<int>?> _readBody(HttpRequest req) async {
    if (req.contentLength > maxBody) return null;
    final out = BytesBuilder(copy: false);
    await for (final chunk in req) {
      out.add(chunk);
      if (out.length > maxBody) return null;
    }
    return out.takeBytes();
  }

  Map<String, String> _cookies(HttpRequest req) {
    // Parsed by hand: dart:io's parser throws on cookie values it dislikes.
    final m = <String, String>{};
    for (final header in req.headers['cookie'] ?? const <String>[]) {
      for (final part in header.split(';')) {
        final i = part.indexOf('=');
        if (i > 0) m[part.substring(0, i).trim()] = part.substring(i + 1).trim();
      }
    }
    return m;
  }

  String _cookie(String name, String value,
      {required int maxAge, required String sameSite, required bool secure}) =>
      '$name=$value; HttpOnly; Max-Age=$maxAge; Path=/; SameSite=$sameSite${secure ? '; Secure' : ''}';

  Future<_Reply> _dispatch(HttpRequest req) async {
    final path = req.uri.path;
    final method = req.method == 'HEAD' ? 'GET' : req.method;
    List<int>? body;
    if (method == 'POST') {
      body = await _readBody(req);
      if (body == null) return _json({'ok': false, 'error': 'request too large'}, 413);
      // CSRF: a cross-site page can't add a custom header without a CORS
      // preflight, which this server never approves.
      if (path.startsWith('/admin') && req.headers.value('x-requested-with') != 'att-admin') {
        return _json({'ok': false, 'error': 'forbidden'}, 403);
      }
    }
    final routes = <String, Map<String, Future<_Reply> Function()>>{
      '/': {'GET': () async => _index(req)},
      '/favicon.ico': {'GET': () async => _Reply(204, const [], 'text/plain')},
      '/api/init': {'POST': () async => _init(req, body!)},
      '/submit': {'POST': () async => _submit(req, body!)},
      '/admin/login': {'POST': () async => _adminLogin(req, body!)},
      '/admin': {'GET': () async => _adminPage(req)},
      '/admin/state': {'GET': () async => _adminState(req)},
      '/admin/reset-devices': {'POST': () async => _adminResetDevices(req)},
      '/admin/new-session': {'POST': () async => _adminNewSession(req, body!)},
      '/admin/export': {'POST': () async => _adminExport(req)},
      '/admin/download': {'GET': () async => _adminDownload(req)},
      '/admin/end-session': {'POST': () async => _adminEndSession(req)},
    };
    if (path.startsWith('/static/') && method == 'GET') {
      final f = statics[path.substring('/static/'.length)];
      if (f == null) return _Reply(404, utf8.encode('Not Found'), 'text/plain; charset=utf-8');
      return _Reply(200, f.bytes, f.contentType);
    }
    final r = routes[path];
    if (r == null) return _Reply(404, utf8.encode('Not Found'), 'text/plain; charset=utf-8');
    final h = r[method];
    if (h == null) {
      return _Reply(405, utf8.encode('Method Not Allowed'), 'text/plain; charset=utf-8');
    }
    return h();
  }

  _Reply _page(String name, [int status = 200]) {
    final f = statics[name];
    if (f == null) return _Reply(404, utf8.encode('Not Found'), 'text/plain; charset=utf-8');
    return _Reply(status, f.bytes, f.contentType);
  }

  Map<String, Object?>? _jsonBody(List<int> body) {
    try {
      final v = jsonDecode(utf8.decode(body));
      return v is Map ? v.cast<String, Object?>() : null;
    } catch (_) {
      return null;
    }
  }

  // =========================================================================
  // Identity, IPs, throttles, tokens
  // =========================================================================

  String _realPeer(HttpRequest req) =>
      req.connectionInfo?.remoteAddress.address ?? 'unknown';

  bool _isLoopback(String ip) => ip == '127.0.0.1' || ip == '::1';

  /// Student's public IP. Forwarding headers are trusted only when the TCP
  /// peer is loopback (i.e. the local cloudflared), so LAN clients can't spoof.
  String _clientIp(HttpRequest req) {
    final peer = _realPeer(req);
    if (_isLoopback(peer)) {
      for (final header in ['cf-connecting-ip', 'x-forwarded-for']) {
        final raw = (req.headers.value(header) ?? '').split(',').first.trim();
        if (raw.isNotEmpty && InternetAddress.tryParse(raw) != null) return raw;
      }
    }
    return InternetAddress.tryParse(peer) != null ? peer : 'unknown';
  }

  bool _hit(Map<String, List<double>> table, String key, double window, int limit) {
    final now = _now;
    if (table.length > 5000) {
      table.removeWhere((_, v) => v.isEmpty || now - v.last >= window);
    }
    final hits = (table[key] ?? const <double>[]).where((t) => now - t < window).toList()
      ..add(now);
    table[key] = hits;
    return hits.length > limit;
  }

  bool _throttled(String deviceId) =>
      _hit(_throttle, deviceId, config.throttleWindow.toDouble(), config.throttleN);

  static const int _tokenPeriod = 30;

  String issuePageToken() {
    final bucket = DateTime.now().millisecondsSinceEpoch ~/ 1000 ~/ _tokenPeriod;
    return hmacHex(config.pageSecret, '$bucket').substring(0, 16);
  }

  bool _validPageToken(String tok) {
    if (tok.isEmpty || config.pageSecret.isEmpty) return false;
    final b = DateTime.now().millisecondsSinceEpoch ~/ 1000 ~/ _tokenPeriod;
    for (final x in [b, b - 1, b - 2]) {
      final good = hmacHex(config.pageSecret, '$x').substring(0, 16);
      if (_constEq(tok, good)) return true;
    }
    return false;
  }

  static bool _constEq(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  String? _resolveByDevice(String deviceId, String token) {
    if (deviceId.isNotEmpty && store.clientToRid.containsKey(deviceId)) {
      return store.clientToRid[deviceId];
    }
    if (token.isNotEmpty && store.clientToRid.containsKey(token)) {
      return store.clientToRid[token];
    }
    return null;
  }

  // =========================================================================
  // Student endpoints
  // =========================================================================

  _Reply _index(HttpRequest req) {
    if (config.forceSingleOrigin && config.tunnelUrls.length == 1) {
      final host = req.headers.value('host') ?? '';
      final turl = config.tunnelUrls.first;
      final thost = turl.split('://').last.split('/').first;
      if (thost.isNotEmpty && !host.contains(thost)) {
        return _Reply(307, const [], 'text/plain', {'location': turl});
      }
    }
    return _page('index.html');
  }

  _Reply _init(HttpRequest req, List<int> body) {
    final data = _jsonBody(body) ?? const {};
    final deviceId = '${data['deviceId'] ?? ''}'.trim();
    final token = _cookies(req)[cookieName] ?? '';
    final rec = store.get(_resolveByDevice(deviceId, token));
    return _json({
      'course': config.courseName, 'count': store.records.length,
      'geofence': config.geofence, 'page_token': issuePageToken(),
      'record': rec == null ? null : {'name': rec['name'], 'id': rec['id']},
    });
  }

  Map<String, Object?>? _formOrJson(HttpRequest req, List<int> body) {
    final ct = req.headers.value('content-type') ?? '';
    if (ct.startsWith('application/json')) return _jsonBody(body);
    try {
      return Uri.splitQueryString(utf8.decode(body));
    } catch (_) {
      return null;
    }
  }

  void _log(String action, String match, String? rid, String name, String sid,
      Rec? prev, double? lat, double? lng, double? acc, String ip, String deviceId,
      String now, {String note = ''}) {
    store.log.add({
      'seq': store.log.length + 1, 'time': now, 'action': action, 'match': match,
      'rid': rid, 'name': name, 'id': sid,
      'prev_name': prev?['name'] ?? '', 'prev_id': prev?['id'] ?? '',
      'lat': lat, 'lng': lng, 'acc': acc, 'ip': ip,
      'device': deviceTag(deviceId), 'note': note,
    });
  }

  Rec _event(String kind, String now, String oldId, String oldName, String newId,
      String newName, String ip, [int? dist]) {
    final e = <String, Object?>{
      'time': now, 'old_id': oldId, 'old_name': oldName, 'new_id': newId,
      'new_name': newName, 'ip': ip, 'dist_m': dist, 'kind': kind,
    };
    store.events.add(e);
    return e;
  }

  _Reply _submit(HttpRequest req, List<int> body) {
    if (config.ended) return _reject('انتهى تسجيل الحضور / Attendance is closed', 410);
    final data = _formOrJson(req, body);
    if (data == null) return _reject('Bad request payload', 400);

    final sid = normalizeDigits('${data['id'] ?? ''}'.trim());
    final rawName = '${data['name'] ?? ''}'.trim();
    var deviceId = '${data['deviceId'] ?? ''}'.trim();
    if (!deviceRe.hasMatch(deviceId)) deviceId = randomHex();   // treat as a new browser

    if (config.pageSecret.isNotEmpty &&
        !_validPageToken('${data['page_token'] ?? ''}'.trim())) {
      return _json({'ok': false, 'code': 'token',
          'error': 'افتح الصفحة من جديد وأعد المحاولة / Please reload the page and try again'}, 403);
    }
    if (_throttled(deviceId)) {
      return _json({'ok': false, 'retry': false,
          'error': 'محاولات كثيرة بسرعة — انتظر قليلًا / Too many attempts, slow down'}, 429);
    }
    if (!validId(sid)) return _reject('رقم الطالب غير صالح / Invalid student ID', 422);
    final rosterKey = sid.replaceFirst(RegExp(r'^0+'), '');
    if (config.roster.isNotEmpty &&
        !config.roster.contains(rosterKey.isEmpty ? '0' : rosterKey)) {
      return _reject('رقم الطالب غير مدرج في قائمة الطلاب / This ID is not on the class list', 403);
    }
    final (okName, name) = validName(rawName);
    if (!okName) {
      return _reject('ادخل الاسم الرباعي بالعربية (٤ مقاطع على الأقل) / '
          'Enter your full 4-part Arabic name', 422);
    }

    double? lat, lng, acc;
    if (config.geofence) {
      lat = _toDouble(data['lat']);
      lng = _toDouble(data['lng']);
      if (lat == null || lng == null) {
        return _reject('يجب السماح بالوصول إلى الموقع لتسجيل الحضور / '
            'Location access is required to submit', 403);
      }
      if (!(lat.isFinite && lng.isFinite && lat >= -90 && lat <= 90 && lng >= -180 && lng <= 180)) {
        return _reject('إحداثيات غير صالحة / Invalid location coordinates', 422);
      }
      final a = _toDouble(data['accuracy']) ?? 0.0;
      acc = (!a.isFinite || a < 0) ? 0.0 : a;
    }

    final ip = _clientIp(req);
    final peer = _realPeer(req);
    final token = _cookies(req)[cookieName] ?? randomHex();
    final now = isoSeconds(DateTime.now());
    final isHttps = req.headers.value('x-forwarded-proto') == 'https';
    _Reply ok(String mode, String message) {
      final r = _json({'ok': true, 'mode': mode, 'message': message});
      r.cookies.add(_cookie(cookieName, token, maxAge: 43200, sameSite: 'lax', secure: isHttps));
      return r;
    }

    // ===================== ATOMIC CRITICAL SECTION =====================
    // No await from here on: the event loop serialises concurrent submissions.

    // Identity is the browser (deviceId / cookie) only. A shared IP or nearby
    // GPS never picks a record (phones behind one tower share an IP).
    var existingRid = _resolveByDevice(deviceId, token);
    var matchMethod = 'device';
    if (existingRid != null && store.get(existingRid) == null) {
      store.clientToRid.remove(deviceId);
      store.clientToRid.remove(token);
      existingRid = null;
    }

    // Another browser re-submitting an existing ID: same student only if the
    // name matches too; otherwise refuse instead of overwriting the owner.
    if (existingRid == null && store.idToRid.containsKey(sid)) {
      final owner = store.get(store.idToRid[sid]);
      if (owner != null) {
        if (nameKey(owner['name'] as String) != nameKey(name)) {
          _log('refused', 'ID in use', owner['rid'] as String, name, sid, owner,
              lat, lng, acc, ip, deviceId, now,
              note: 'ID already registered with a different name');
          final ev = _event('refused: ID in use', now, owner['id'] as String,
              owner['name'] as String, sid, name, ip);
          _journal?.write({'op': 'refused', 'log': store.log.last, 'event': ev});
          return _reject('رقم الطالب مسجّل بالفعل باسم آخر — إذا كان رقمك فراجع المحاضر / '
              'This ID is already registered under another name. '
              'If it is yours, tell the instructor.', 409);
        }
        existingRid = owner['rid'] as String;
        matchMethod = 'same ID + name';
      }
    }

    if (existingRid != null) {
      final rec = store.get(existingRid)!;
      final oldId = rec['id'] as String, oldName = rec['name'] as String;
      final oldLat = rec['lat'], oldLng = rec['lng'];
      if (sid != oldId) {
        final owner = store.idToRid[sid];
        if (owner != null && owner != existingRid) {
          _log('refused', 'ID in use', existingRid, name, sid, rec, lat, lng, acc, ip,
              deviceId, now, note: 'tried to change to an ID another student registered');
          final ev = _event('refused: ID in use', now, oldId, oldName, sid, name, ip);
          _journal?.write({'op': 'refused', 'log': store.log.last, 'event': ev});
          return _reject('رقم الطالب مستخدم من جهاز آخر / '
              'This ID is already used on another device', 409);
        }
        store.idToRid.remove(oldId);
        store.idToRid[sid] = existingRid;
      }
      if (rec['ip'] != ip) {
        store.dropIp(rec['ip'] as String?, existingRid);
        store.addIp(ip, existingRid);
      }
      rec['name'] = name;
      rec['id'] = sid;
      rec['edited_at'] = now;
      rec['ip'] = ip;
      if (lat != null) {
        rec['lat'] = lat;
        rec['lng'] = lng;
        rec['acc'] = acc;
      }
      store.clientToRid[deviceId] = existingRid;
      store.clientToRid[token] = existingRid;
      int? dist;
      if (oldLat is num && oldLng is num && lat != null) {
        dist = pyRound(haversineKm(oldLat.toDouble(), oldLng.toDouble(), lat, lng!) * 1000);
      }
      final kind = editKind(oldId, oldName, sid, name);
      _log('updated', matchMethod, existingRid, name, sid, {'name': oldName, 'id': oldId},
          lat, lng, acc, ip, deviceId, now, note: kind);
      final ev = _event(kind, now, oldId, oldName, sid, name, ip, dist);
      _journal?.write({
        'op': 'updated', 'rid': existingRid, 'name': name, 'id': sid, 'edited_at': now,
        'ip': ip, 'lat': lat, 'lng': lng, 'acc': acc, 'device': deviceId, 'token': token,
        'log': store.log.last, 'event': ev,
      });
      return ok('updated', 'تم تحديث بياناتك / Your entry was updated');
    }

    // New record: secondary per-peer throttle before committing.
    if (_hit(_ipThrottle, peer, _ipWindow, _ipNewLimit)) {
      return _json({'ok': false, 'retry': true,
          'error': 'الخادم مشغول — انتظر قليلًا / Server busy, try again shortly'}, 429);
    }
    if (config.ipTracking && store.seenIps.contains(ip)) {
      _log('refused', 'IP already used', null, name, sid, null, lat, lng, acc, ip, deviceId, now);
      _journal?.write({'op': 'refused', 'log': store.log.last});
      return _reject('تم التسجيل من هذه الشبكة مسبقًا / Already submitted from this network', 409);
    }

    final rid = randomHex();
    final rec = <String, Object?>{
      'rid': rid, 'name': name, 'id': sid, 'timestamp': now, 'edited_at': null,
      'lat': lat, 'lng': lng, 'acc': acc, 'ip': ip,
    };
    store.addRecord(rec);
    store.clientToRid[deviceId] = rid;
    store.clientToRid[token] = rid;
    store.idToRid[sid] = rid;
    final shared = [
      for (final r in store.ipToRids[ip] ?? const <String>[])
        if (store.get(r) != null) store.get(r)!['id'] as String,
    ];
    store.addIp(ip, rid);
    if (config.ipTracking) store.seenIps.add(ip);
    _log('created', 'new', rid, name, sid, null, lat, lng, acc, ip, deviceId, now,
        note: shared.isEmpty ? '' : 'same IP as ${shared.join(' ')}');
    _journal?.write({'op': 'created', 'rec': rec, 'device': deviceId, 'token': token,
        'log': store.log.last});
    // =================== END ATOMIC CRITICAL SECTION ===================
    return ok('created', 'تم تسجيل الحضور / Attendance recorded');
  }

  static double? _toDouble(Object? v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v.trim());
    return null;
  }

  // =========================================================================
  // Admin
  // =========================================================================

  bool _pwOk(String pw) {
    if (config.adminPwHash.isEmpty) return false;
    return _constEq(sha256Hex(config.adminPwSalt + pw), config.adminPwHash);
  }

  String adminSessionCookie() => hmacHex(config.pageSecret, 'admin-session').substring(0, 32);

  /// Password (header or login cookie); with no password set: loopback or a
  /// trusted private network, never via the tunnel, and only with an IP or
  /// localhost as Host (DNS-rebinding guard).
  bool _checkAdmin(HttpRequest req) {
    final supplied = req.headers.value('x-admin-pw');
    if (supplied != null && _pwOk(supplied)) return true;
    if (config.adminPwHash.isNotEmpty) {
      final c = _cookies(req)['att_admin'];
      return c != null && _constEq(c, adminSessionCookie());
    }
    if ((req.headers.value('cf-connecting-ip') ?? '').isNotEmpty ||
        (req.headers.value('x-forwarded-for') ?? '').isNotEmpty) {
      return false;
    }
    final host = req.headers.host ?? '';
    if (host != 'localhost' &&
        InternetAddress.tryParse(host.replaceAll('[', '').replaceAll(']', '')) == null) {
      return false;
    }
    final peer = _realPeer(req);
    if (_isLoopback(peer) || peer == 'localhost') return true;
    final ip = InternetAddress.tryParse(peer);
    if (ip == null) return false;
    return config.adminCidrs.any((c) => _inCidr(ip, c));
  }

  static bool _inCidr(InternetAddress ip, String cidr) {
    final parts = cidr.split('/');
    final net = InternetAddress.tryParse(parts[0]);
    if (net == null || net.type != ip.type) return false;
    final bits = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : net.rawAddress.length * 8;
    final a = ip.rawAddress, b = net.rawAddress;
    var left = bits;
    for (var i = 0; i < a.length && left > 0; i++, left -= 8) {
      final mask = left >= 8 ? 0xFF : (0xFF << (8 - left)) & 0xFF;
      if ((a[i] & mask) != (b[i] & mask)) return false;
    }
    return true;
  }

  _Reply _adminLogin(HttpRequest req, List<int> body) {
    if (_hit(_loginThrottle, _realPeer(req), _loginWindow, _loginMax)) {
      return _json({'ok': false, 'error': 'Too many attempts — try later'}, 429);
    }
    final data = _jsonBody(body) ?? const {};
    if (config.adminPwHash.isEmpty) return _json({'ok': true, 'no_password': true});
    if (_pwOk('${data['pw'] ?? ''}')) {
      final r = _json({'ok': true});
      r.cookies.add(_cookie('att_admin', adminSessionCookie(), maxAge: 43200,
          sameSite: 'strict', secure: req.headers.value('x-forwarded-proto') == 'https'));
      return r;
    }
    return _json({'ok': false, 'error': 'wrong password'}, 401);
  }

  _Reply _adminPage(HttpRequest req) {
    if (!_checkAdmin(req)) {
      if (config.adminPwHash.isNotEmpty) return _page('login.html');
      return _Reply(403, utf8.encode('<h2>Admin is available only on the host machine or a '
          'device on the same private network — not through the public link.</h2>'),
          'text/html; charset=utf-8');
    }
    return _page('admin.html');
  }

  /// Live numbers for the web dashboard and the app's own screens.
  Map<String, Object?> stateSnapshot() {
    final rows = store.records;
    final center = config.geofence ? hallCenter(rows) : null;
    double? distKm(Rec r) {
      final lat = r['lat'], lng = r['lng'];
      if (center == null || lat is! num || lng is! num) return null;
      return haversineKm(center.$1, center.$2, lat.toDouble(), lng.toDouble());
    }

    var outOfBounds = 0;
    for (final r in rows) {
      final d = distKm(r);
      if (d != null && d > config.auditRadiusKm) outOfBounds++;
    }
    final sharedIp = store.ipToRids.values.where((v) => v.length > 1)
        .fold<int>(0, (a, v) => a + v.length);
    final recent = <Map<String, Object?>>[];
    for (final r in rows.reversed.take(30)) {
      final d = distKm(r);
      recent.add({
        'name': r['name'], 'id': r['id'], 'timestamp': r['timestamp'],
        'edited': r['edited_at'] != null, 'gps': r['lat'] is num,
        'dist_m': d == null ? null : pyRound(d * 1000),
        'out': d != null && d > config.auditRadiusKm,
        'shared_ip': (store.ipToRids[r['ip']]?.length ?? 0) > 1,
      });
    }
    return {
      'course': config.courseName, 'session_id': config.sessionId(),
      'count': rows.length, 'devices': store.idToRid.length,
      'ip_tracking': config.ipTracking, 'geofence': config.geofence,
      'audit_radius_km': config.auditRadiusKm,
      'out_of_bounds': outOfBounds, 'shared_ip': sharedIp,
      'submissions': store.log.length,
      'merges': store.events.reversed.take(30).toList(), 'recent': recent,
    };
  }

  _Reply _adminState(HttpRequest req) {
    if (!_checkAdmin(req)) return _reject('unauthorized', 401);
    return _json(stateSnapshot());
  }

  void resetDevices() {
    store.clearDevices();
    _throttle.clear();
    _ipThrottle.clear();
    _journal?.write({'op': 'reset_devices'});
  }

  _Reply _adminResetDevices(HttpRequest req) {
    if (!_checkAdmin(req)) return _reject('unauthorized', 401);
    resetDevices();
    return _json({'ok': true, 'message': 'Device locks cleared; cookies reset for a new take'});
  }

  /// Export the current session, clear everything, start a new one.
  String newSession(String course) {
    final rows = List.of(store.records), log = List.of(store.log);
    final oldBase = config.sessionId();
    store.clearAll();
    _throttle.clear();
    _ipThrottle.clear();
    if (course.trim().isNotEmpty) config.courseName = course.trim();
    config.startedAt = DateTime.now();
    _journalSession();
    try {
      final res = writeExports(rows, log, exportDir, oldBase,
          geofence: config.geofence, radiusKm: config.auditRadiusKm, reason: 'new-session');
      return res.finalPath.split('/').last;
    } catch (e) {
      stderr.writeln('[export:new-session] ERROR: $e');
      return '(export failed)';
    }
  }

  _Reply _adminNewSession(HttpRequest req, List<int> body) {
    if (!_checkAdmin(req)) return _reject('unauthorized', 401);
    final data = _jsonBody(body) ?? const {};
    final exported = newSession('${data['course'] ?? ''}');
    return _json({'ok': true, 'exported': exported, 'course': config.courseName,
        'session_id': config.sessionId()});
  }

  _Reply _adminExport(HttpRequest req) {
    if (!_checkAdmin(req)) return _reject('unauthorized', 401);
    try {
      final r = exportNow('manual');
      return _json({'ok': true, 'final': r.finalPath.split('/').last,
          'raw': r.rawPath.split('/').last, 'audited': r.auditPath?.split('/').last});
    } catch (e) {
      return _json({'ok': false, 'error': '$e'}, 500);
    }
  }

  _Reply _adminDownload(HttpRequest req) {
    if (!_checkAdmin(req)) return _reject('unauthorized', 401);
    final kind = req.uri.queryParameters['file'] ?? 'final';
    if (!const ['final', 'raw', 'audited'].contains(kind)) return _reject('unknown file', 400);
    final ExportResult r;
    try {
      r = exportNow('download');
    } catch (e) {
      return _json({'ok': false, 'error': '$e'}, 500);
    }
    final path = switch (kind) {
      'raw' => r.rawPath,
      'audited' => r.auditPath ?? r.finalPath,
      _ => r.finalPath,
    };
    final name = path.split('/').last;
    return _Reply(200, File(path).readAsBytesSync(), 'text/csv; charset=utf-8',
        {'content-disposition': 'attachment; filename="$name"'});
  }

  /// Close attendance: refuse submissions, export, copy to Downloads, then
  /// ask the host to stop. Returns the export (null if it failed).
  Map<String, Object?> endSession() {
    config.ended = true;   // from here on /submit refuses
    final ExportResult r;
    try {
      r = exportNow('end-session');
    } catch (e) {
      config.ended = false;   // nothing saved: keep the session open
      return {'ok': false, 'error': 'export failed: $e'};
    }
    _journal?.write({'op': 'ended'});
    final copied = <String>[];
    final dest = downloadsDir;
    if (dest != null && Directory(dest).existsSync()) {
      for (final p in r.all) {
        try {
          File(p).copySync('$dest/${p.split('/').last}');
          copied.add(p.split('/').last);
        } catch (e) {
          stderr.writeln('[end-session] could not copy $p: $e');
        }
      }
    }
    final stopping = onEndSession != null;
    if (stopping) Timer(const Duration(seconds: 1), onEndSession!);
    return {'ok': true, 'files': r.all.map((p) => p.split('/').last).toList(),
        'exports_dir': exportDir, 'copied_to': copied.isEmpty ? null : dest,
        'copied': copied, 'stopping': stopping};
  }

  _Reply _adminEndSession(HttpRequest req) {
    if (!_checkAdmin(req)) return _reject('unauthorized', 401);
    final res = endSession();
    return _json(res, res['ok'] == true ? 200 : 500);
  }
}
