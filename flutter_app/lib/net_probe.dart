import 'dart:convert';
import 'dart:io';

/// Reaching our own fresh *.trycloudflare.com links from the phone.
///
/// A Quick Tunnel's hostname only starts resolving a few seconds after
/// cloudflared prints it. If the phone looks it up too early, Android's
/// resolver caches the "no such host" answer, sometimes for many minutes, and
/// every later check fails even though students (on other resolvers) can
/// reach the link fine. That made health checks restart healthy tunnels and
/// failed the pre-class check. So these lookups go to Cloudflare's own
/// resolver over HTTPS (1.1.1.1), bypassing the phone's DNS cache, and the
/// TLS connection is still verified against the real hostname.

final Map<String, (List<InternetAddress>, DateTime)> _cache = {};

/// Where DoH failures are logged (the app points it at its log file). Kept as
/// a hook so this file stays pure dart:io.
void Function(String message)? netProbeLog;

/// Parses a DNS-over-HTTPS JSON answer (application/dns-json) into A records.
List<InternetAddress> parseDohAnswer(String body) {
  final j = jsonDecode(body);
  if (j is! Map || j['Answer'] is! List) return const [];
  return [
    for (final a in j['Answer'] as List)
      if (a is Map && a['type'] == 1 && InternetAddress.tryParse('${a['data']}') != null)
        InternetAddress('${a['data']}'),
  ];
}

Future<List<InternetAddress>> resolveViaDoh(String host) async {
  final hit = _cache[host];
  if (hit != null && DateTime.now().difference(hit.$2) < const Duration(seconds: 60)) {
    return hit.$1;
  }
  for (final server in const ['1.1.1.1', '1.0.0.1']) {
    final c = HttpClient()
      ..connectionTimeout = const Duration(seconds: 5)
      ..findProxy = (_) => 'DIRECT';   // straight to Cloudflare, like the probe itself
    try {
      final req = await c.getUrl(Uri.https(server, '/dns-query', {'name': host, 'type': 'A'}));
      req.headers.set('accept', 'application/dns-json');
      final res = await req.close().timeout(const Duration(seconds: 8));
      final ips = parseDohAnswer(await utf8.decodeStream(res));
      if (ips.isNotEmpty) {
        _cache[host] = (ips, DateTime.now());
        return ips;
      }
    } catch (e) {
      netProbeLog?.call('DoH via $server failed for $host: $e');
    } finally {
      c.close(force: true);
    }
  }
  return const [];
}

/// An HttpClient that resolves *.trycloudflare.com via [resolveViaDoh] and
/// falls back to the phone's normal DNS for anything else (or if DoH fails).
HttpClient tunnelHttpClient() {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  client.findProxy = (_) => 'DIRECT';
  client.connectionFactory = (uri, proxyHost, proxyPort) async {
    final port = uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80);
    if (uri.scheme != 'https') return Socket.startConnect(uri.host, port);
    if (uri.host.endsWith('.trycloudflare.com')) {
      final ips = await resolveViaDoh(uri.host);
      if (ips.isNotEmpty) {
        final task = await Socket.startConnect(ips.first, port);
        return ConnectionTask.fromSocket(
            task.socket.then((s) => SecureSocket.secure(s, host: uri.host)), task.cancel);
      }
    }
    return SecureSocket.startConnect(uri.host, port);
  };
  return client;
}
