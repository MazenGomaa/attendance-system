// Pure rules shared by the server and the exporter. Mirrors app.py; keep the
// two in step (tests/scenarios.py checks both servers over HTTP).

import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

final RegExp idRe = RegExp(r'^\d{1,20}$');
final RegExp arabicWordRe = RegExp(r'^[؀-ۿ]+$');
const int minNameParts = 4;
final RegExp deviceRe = RegExp(r'^[A-Za-z0-9-]{8,64}$');

/// Arabic-Indic (٠-٩) and Persian (۰-۹) digits -> ASCII, so IDs typed on an
/// Arabic keyboard validate and match the roster.
String normalizeDigits(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    if (r >= 0x0660 && r <= 0x0669) {
      b.writeCharCode(0x30 + r - 0x0660);
    } else if (r >= 0x06F0 && r <= 0x06F9) {
      b.writeCharCode(0x30 + r - 0x06F0);
    } else {
      b.writeCharCode(r);
    }
  }
  return b.toString();
}

bool validId(String s) => idRe.hasMatch(s);

/// (ok, normalised name): 4+ Arabic words, single-spaced, at most 100 chars.
(bool, String) validName(String s) {
  final parts = s.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.length < minNameParts) return (false, s);
  if (parts.any((p) => !arabicWordRe.hasMatch(p))) return (false, s);
  final joined = parts.join(' ');
  if (joined.length > 100) return (false, s);
  return (true, joined);
}

// Arabic spelling variants students type interchangeably (أ/إ/آ/ا, ة/ه, ى/ي),
// plus tatweel and diacritics, are folded before names are compared.
const Map<String, String> _arFold = {
  'أ': 'ا', 'إ': 'ا', 'آ': 'ا', 'ٱ': 'ا', 'ة': 'ه', 'ى': 'ي', 'ـ': '',
};
final RegExp _arMarks = RegExp('[ً-ْٰ]');

String nameKey(String name) {
  final noMarks = name.replaceAll(_arMarks, '');
  final b = StringBuffer();
  for (final ch in noMarks.split('')) {
    b.write(_arFold[ch] ?? ch);
  }
  return b.toString().trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).join(' ');
}

String editKind(String oldId, String oldName, String newId, String newName) {
  final sameId = oldId == newId;
  final sameName = nameKey(oldName) == nameKey(newName);
  if (sameId && sameName) return 'same student';
  if (sameName) return 'ID corrected';
  if (sameId) return 'name corrected';
  return 'different student';
}

double haversineKm(double lat1, double lng1, double lat2, double lng2) {
  const r = 6371.0;
  double rad(double d) => d * math.pi / 180;
  final p1 = rad(lat1), p2 = rad(lat2);
  final dp = rad(lat2 - lat1), dl = rad(lng2 - lng1);
  final a = math.pow(math.sin(dp / 2), 2) +
      math.cos(p1) * math.cos(p2) * math.pow(math.sin(dl / 2), 2);
  return 2 * r * math.asin(math.sqrt(a));
}

bool isNum(Object? v) => v is num;

String mapsLink(Object? lat, Object? lng) {
  if (lat is num && lng is num) {
    return 'https://www.google.com/maps?q=${lat.toStringAsFixed(6)},${lng.toStringAsFixed(6)}';
  }
  return '';
}

String deviceTag(String deviceId) =>
    sha256.convert(utf8.encode(deviceId)).toString().substring(0, 8);

double _median(List<double> xs) {
  final s = [...xs]..sort();
  final n = s.length;
  return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
}

/// Median of all GPS points: robust to a minority of remote cheaters.
(double, double)? hallCenter(Iterable<Map<String, Object?>> rows) {
  final lats = <double>[], lngs = <double>[];
  for (final r in rows) {
    final lat = r['lat'], lng = r['lng'];
    if (lat is num && lng is num) {
      lats.add(lat.toDouble());
      lngs.add(lng.toDouble());
    }
  }
  if (lats.isEmpty) return null;
  return (_median(lats), _median(lngs));
}

/// Neutralise spreadsheet formulas (=, +, -, @) in free-text CSV cells.
String csvCell(Object? v) {
  final s = v == null ? '' : v.toString();
  if (s.isNotEmpty && '=+-@\t\r'.contains(s[0])) return "'$s";
  return s;
}

/// Python's str() for numbers written into CSV: ints stay ints, floats keep
/// their shortest form (31.0 stays "31.0").
String pyNum(Object? v) {
  if (v == null) return '';
  if (v is int) return '$v';
  if (v is double) {
    if (v == v.roundToDouble() && v.abs() < 1e16) return v.toStringAsFixed(1);
    return '$v';
  }
  return v.toString();
}

/// Python's round(x) for display values (half to even).
int pyRound(double x) {
  final f = x.floorToDouble();
  final diff = x - f;
  if (diff > 0.5) return f.toInt() + 1;
  if (diff < 0.5) return f.toInt();
  return f.toInt().isEven ? f.toInt() : f.toInt() + 1;
}

/// round(x, 3) as Python prints it.
String pyRound3(double x) {
  final v = (x * 1000).roundToDouble() / 1000;
  return pyNum(v);
}

String hmacHex(String key, String msg) =>
    Hmac(sha256, utf8.encode(key)).convert(utf8.encode(msg)).toString();

String sha256Hex(String s) => sha256.convert(utf8.encode(s)).toString();

/// 32 random hex chars (like Python's uuid4().hex).
String randomHex([int bytes = 16]) {
  final rnd = math.Random.secure();
  return List.generate(bytes, (_) => rnd.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
}

/// Local time, "YYYY-MM-DDTHH:MM:SS" (Python isoformat(timespec="seconds")).
String isoSeconds(DateTime t) => t.toIso8601String().substring(0, 19);
