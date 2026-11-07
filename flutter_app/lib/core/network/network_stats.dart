// NetworkStats - counts of what the app asked the network for, and what the
// cache answered instead.
//
// Kept in memory only, for debugging and for tests that measure a
// navigation session (request count, bytes, cache hits). Never recorded:
// query strings (a search is the user's own words), headers (the bearer
// token), or any body. Endpoints are recorded as paths with their ids folded
// to {id}, so "/negotiate/inbox/{id}" counts every account's inbox as one.
import 'package:flutter/foundation.dart';

class NetworkRecord {
  const NetworkRecord({
    required this.method,
    required this.endpoint,
    required this.status,
    required this.bytes,
    required this.duration,
  });

  final String method;
  final String endpoint;

  /// 0 when no response arrived (offline, timeout).
  final int status;

  /// Response body bytes as the app received them (after any gzip
  /// decompression, which dart:io does transparently).
  final int bytes;
  final Duration duration;

  bool get ok => status >= 200 && status < 400;

  @override
  String toString() => '$method $endpoint -> $status, $bytes B, ${duration.inMilliseconds} ms';
}

class NetworkStats {
  NetworkStats();
  static final NetworkStats instance = NetworkStats();

  /// Print each request as it completes (debug builds only).
  static bool logToConsole = false;

  static const _keep = 500;
  final List<NetworkRecord> records = [];

  final Map<String, int> cacheHits = {};
  final Map<String, int> cacheFreshHits = {};
  final Map<String, int> cacheMisses = {};

  /// Requests not sent because the same one was already in flight.
  final Map<String, int> deduplicated = {};

  int get requestCount => records.length;
  int get totalBytes => records.fold(0, (s, r) => s + r.bytes);
  int get failedCount => records.where((r) => !r.ok).length;

  int requestsTo(String endpointPrefix) =>
      records.where((r) => r.endpoint.startsWith(endpointPrefix)).length;

  void record(String method, Uri url, {required int status, required int bytes, required Duration duration}) {
    final r = NetworkRecord(
        method: method, endpoint: endpointOf(url), status: status, bytes: bytes, duration: duration);
    records.add(r);
    if (records.length > _keep) records.removeAt(0);
    if (logToConsole && kDebugMode) debugPrint('[net] $r');
  }

  void recordCache(String feature, {required bool hit, bool fresh = false}) {
    final m = hit ? cacheHits : cacheMisses;
    m[feature] = (m[feature] ?? 0) + 1;
    if (hit && fresh) cacheFreshHits[feature] = (cacheFreshHits[feature] ?? 0) + 1;
  }

  void recordDedup(String feature) => deduplicated[feature] = (deduplicated[feature] ?? 0) + 1;

  void reset() {
    records.clear();
    cacheHits.clear();
    cacheFreshHits.clear();
    cacheMisses.clear();
    deduplicated.clear();
  }

  /// Requests and bytes per endpoint, largest first.
  String summary() {
    final by = <String, (int, int)>{};
    for (final r in records) {
      final key = '${r.method} ${r.endpoint}';
      final (n, b) = by[key] ?? (0, 0);
      by[key] = (n + 1, b + r.bytes);
    }
    final rows = by.entries.toList()..sort((a, b) => b.value.$2.compareTo(a.value.$2));
    return [
      'requests=$requestCount bytes=$totalBytes failed=$failedCount',
      for (final e in rows) '  ${e.key}: ${e.value.$1} req, ${e.value.$2} B',
      'cache hits=$cacheHits fresh=$cacheFreshHits misses=$cacheMisses dedup=$deduplicated',
    ].join('\n');
  }

  static final _idLike = RegExp(r'^(?=.*\d)[A-Za-z0-9_-]{8,}$');

  /// The path with ids folded: "/listings/3f2a.../metrics" -> "/listings/{id}/metrics".
  static String endpointOf(Uri url) {
    final parts = url.pathSegments
        .where((s) => s.isNotEmpty)
        .map((s) => _idLike.hasMatch(s) ? '{id}' : s);
    final path = '/${parts.join('/')}';
    return url.path.endsWith('/') && path != '/' ? '$path/' : path;
  }
}
