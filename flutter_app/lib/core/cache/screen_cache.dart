// ScreenCache - what BROKA has already downloaded, kept on the phone.
//
// Every cached screen follows the same order (stale-while-revalidate):
//   1. read the last saved copy and show it - no network involved;
//   2. if it is past its freshness time (CachePolicies), or a change made in
//      the app marked it out of date (invalidate), fetch in the background;
//   3. on success show and save the new copy; on failure keep showing the
//      saved one and say it may be out of date.
// A saved copy past its freshness time is still shown - "stale" means
// "check again", not "throw away". Only past keepFor is it discarded.
//
// Keys are scoped to the signed-in account (CacheKey.forUser), so one person
// signing in on another's phone never sees the first one's account, store or
// dashboard; sign-out deletes that account's folder (clearAccount). Only
// public, account-independent data (the category list) uses CacheKey.public.
//
// The backend stays the source of truth. Nothing here records the result of
// a change (a create, a payment): a change is only ever learned from the
// server's next answer, and DataChanges marks what it affects out of date.
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../network/network_stats.dart';
import 'cache_store.dart';

/// What a cache entry holds. Invalidation works per feature.
enum CacheFeature {
  categories,
  homeFeed,
  menuAccount,
  menuListingCount,
  storeSummary,
  storeStats,
  launchOffers,
  dashboardProfile,
  dashboardListings,
  dashboardSummary,
  dashboardRevenue,
  dashboardMetrics,
}

/// How long an entry counts as current, and how long it is kept at all.
class CachePolicy {
  const CachePolicy({required this.freshFor, this.keepFor = const Duration(days: 7)});

  /// Younger than this: shown without asking the server.
  final Duration freshFor;

  /// Older than this: discarded rather than shown, even offline.
  final Duration keepFor;
}

/// Freshness per kind of data, set by how often it really changes and what
/// it costs to show it late.
class CachePolicies {
  CachePolicies._();

  /// Seeded by BROKA, changes with a release, not by the minute.
  static const categories = CachePolicy(freshFor: Duration(hours: 12), keepFor: Duration(days: 30));

  /// New listings arrive all day; three minutes keeps Home current without
  /// refetching it on every return from another screen.
  static const homeFeed = CachePolicy(freshFor: Duration(minutes: 3), keepFor: Duration(days: 3));

  /// The account changes when its owner changes it (DataChanges marks it
  /// then); the time limit only catches changes made elsewhere.
  static const menuAccount = CachePolicy(freshFor: Duration(minutes: 3), keepFor: Duration(days: 14));
  static const menuListingCount = CachePolicy(freshFor: Duration(minutes: 3));
  static const storeSummary = CachePolicy(freshFor: Duration(minutes: 3), keepFor: Duration(days: 14));
  static const storeStats = CachePolicy(freshFor: Duration(minutes: 5));

  /// Slots are claimed by other people, so the count moves on its own. Short.
  static const launchOffers = CachePolicy(freshFor: Duration(minutes: 2), keepFor: Duration(hours: 6));

  static const dashboardProfile = CachePolicy(freshFor: Duration(minutes: 3), keepFor: Duration(days: 14));
  static const dashboardListings = CachePolicy(freshFor: Duration(minutes: 3), keepFor: Duration(days: 7));
  static const dashboardSummary = CachePolicy(freshFor: Duration(minutes: 3), keepFor: Duration(days: 7));

  /// Money already paid out: shown as history with its age, never as a
  /// confirmation of anything still in progress (deal statuses are not
  /// cached at all).
  static const dashboardRevenue = CachePolicy(freshFor: Duration(minutes: 3), keepFor: Duration(days: 7));

  /// Daily history, recomputed by the backend's sweep; ten minutes is plenty.
  static const dashboardMetrics = CachePolicy(freshFor: Duration(minutes: 10), keepFor: Duration(days: 7));
}

/// Where an entry lives: whose it is, what it is, and for which parameters.
class CacheKey {
  CacheKey._(this.feature, this.account, Map<String, Object?> params)
      : params = SplayTreeMap<String, String>.from({
          for (final e in params.entries)
            if (e.value != null) e.key: '${e.value}',
        });

  /// Private to one account. A null [userId] is a guest, kept apart from
  /// every signed-in account.
  factory CacheKey.forUser(CacheFeature feature, String? userId,
          [Map<String, Object?> params = const {}]) =>
      CacheKey._(feature, 'u_${userId ?? 'guest'}', params);

  /// The same for everyone - public reference data only.
  factory CacheKey.public(CacheFeature feature, [Map<String, Object?> params = const {}]) =>
      CacheKey._(feature, 'public', params);

  final CacheFeature feature;
  final String account;
  final SplayTreeMap<String, String> params;

  String get _paramString => params.entries.map((e) => '${e.key}=${e.value}').join('&');

  /// The full key, stored in the entry and compared on read.
  String get value => '$account|${feature.name}|$_paramString';

  /// The entry's name in its account's folder.
  String get name => params.isEmpty ? feature.name : '${feature.name}_${cacheHash(_paramString)}';

  @override
  bool operator ==(Object other) => other is CacheKey && other.value == value;
  @override
  int get hashCode => value.hashCode;
  @override
  String toString() => value;
}

/// A saved copy, with when it was fetched and whether it still counts.
class CacheEntry {
  const CacheEntry({required this.data, required this.fetchedAt, required this.isFresh});
  final Object? data;
  final DateTime fetchedAt;

  /// Within its freshness time and not marked out of date since.
  final bool isFresh;
}

class _Stored {
  _Stored(this.data, this.fetchedAt);
  final Object? data;
  final DateTime fetchedAt;
}

class ScreenCache {
  ScreenCache({CacheStore? store, bool memory = true, DateTime Function()? clock})
      : _store = store ?? const NullCacheStore(),
        _memoryEnabled = memory,
        _clock = clock ?? DateTime.now,
        _off = (store == null || store is NullCacheStore) && !memory;

  /// The app's cache. Off under `flutter test` unless a test installs one.
  static ScreenCache instance = _default();

  static bool get isFlutterTest {
    if (kIsWeb) return false;
    try {
      return Platform.environment.containsKey('FLUTTER_TEST');
    } catch (_) {
      return false;
    }
  }

  static ScreenCache _default() {
    if (isFlutterTest) return ScreenCache(memory: false);
    final files = FileCacheStore(() async =>
        Directory('${(await getApplicationCacheDirectory()).path}/screen_cache_v1'));
    // Once per launch, in the background: entries nobody has rewritten in
    // a month are filters and accounts nobody uses on this phone any more.
    Future<void>.delayed(const Duration(seconds: 20), () => files.prune(const Duration(days: 30)));
    return ScreenCache(store: files);
  }

  /// Installs a cache for one test. Pass a [MemoryCacheStore] to look at
  /// what was saved, and [clock] to age entries without waiting.
  @visibleForTesting
  static ScreenCache debugInstall({CacheStore? store, bool memory = true, DateTime Function()? clock}) =>
      instance = ScreenCache(store: store ?? MemoryCacheStore(), memory: memory, clock: clock);

  /// Back to the default for this environment (off, in tests).
  @visibleForTesting
  static void debugReset() => instance = _default();

  final CacheStore _store;
  final bool _memoryEnabled;

  /// Keeps nothing at all (the default under `flutter test`): every read
  /// misses and every fetch is its own request, with no state carried from
  /// one call to the next. A shared in-flight request or invalidation load
  /// left over from a previous test would otherwise never complete in the
  /// next one's clock.
  final bool _off;
  final DateTime Function() _clock;

  DateTime now() => _clock();

  /// Recently used entries, so a screen opened a second time this session
  /// paints from memory in its first frame. Bounded: a long session browsing
  /// filters must not grow this without limit.
  static const _memoryCap = 48;
  final LinkedHashMap<String, _Stored> _memory = LinkedHashMap();

  final Map<String, Future<Object?>> _inflight = {};

  /// When each feature was last marked out of date. Persisted, so a change
  /// made just before the app was closed still counts after it reopens.
  final Map<CacheFeature, DateTime> _invalidated = {};
  Future<void>? _invalidationsLoaded;

  /// Bumped by clearAccount/clearAll: a fetch that started before a
  /// sign-out must not write the old account's answer back afterwards.
  int _epoch = 0;

  static const _metaAccount = '_meta';
  static const _invalidationsName = 'invalidations';

  Future<void> _ensureInvalidations() => _off ? Future<void>.value() : _invalidationsLoaded ??= () async {
        final raw = await _store.read(_metaAccount, _invalidationsName);
        if (raw == null) return;
        try {
          final m = jsonDecode(raw) as Map<String, dynamic>;
          for (final f in CacheFeature.values) {
            final t = m[f.name];
            if (t is int) {
              final at = DateTime.fromMillisecondsSinceEpoch(t, isUtc: true);
              final mine = _invalidated[f];
              if (mine == null || at.isAfter(mine)) _invalidated[f] = at;
            }
          }
        } catch (_) {}
      }();

  bool _isFresh(CacheKey key, DateTime fetchedAt, CachePolicy policy) {
    if (now().difference(fetchedAt) >= policy.freshFor) return false;
    final invalidatedAt = _invalidated[key.feature];
    if (invalidatedAt != null && !fetchedAt.isAfter(invalidatedAt)) return false;
    return true;
  }

  CacheEntry? _entry(CacheKey key, _Stored s, CachePolicy policy) {
    if (now().difference(s.fetchedAt) > policy.keepFor) return null;
    return CacheEntry(data: s.data, fetchedAt: s.fetchedAt, isFresh: _isFresh(key, s.fetchedAt, policy));
  }

  void _remember(String k, _Stored s) {
    if (!_memoryEnabled) return;
    _memory.remove(k);
    _memory[k] = s;
    while (_memory.length > _memoryCap) {
      _memory.remove(_memory.keys.first);
    }
  }

  /// The copy already in memory, synchronously - for a first frame that
  /// shows content instead of a spinner. Null when it would take a read.
  CacheEntry? peek(CacheKey key, CachePolicy policy) {
    final s = _memory[key.value];
    return s == null ? null : _entry(key, s, policy);
  }

  /// The saved copy, from memory or storage. Null when there is none, or it
  /// is past [CachePolicy.keepFor].
  Future<CacheEntry?> read(CacheKey key, CachePolicy policy) async {
    if (_off) return null;
    await _ensureInvalidations();
    final mem = _memory[key.value];
    if (mem != null) {
      final e = _entry(key, mem, policy);
      NetworkStats.instance.recordCache(key.feature.name, hit: e != null, fresh: e?.isFresh ?? false);
      return e;
    }
    final raw = await _store.read(key.account, key.name);
    if (raw == null) {
      NetworkStats.instance.recordCache(key.feature.name, hit: false);
      return null;
    }
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      // A different key under the same name is a hash collision: a miss.
      if (m['k'] != key.value) {
        NetworkStats.instance.recordCache(key.feature.name, hit: false);
        return null;
      }
      final s = _Stored(m['d'], DateTime.fromMillisecondsSinceEpoch(m['t'] as int, isUtc: true));
      final e = _entry(key, s, policy);
      if (e == null) {
        unawaited(_store.delete(key.account, key.name));
      } else {
        _remember(key.value, s);
      }
      NetworkStats.instance.recordCache(key.feature.name, hit: e != null, fresh: e?.isFresh ?? false);
      return e;
    } catch (_) {
      NetworkStats.instance.recordCache(key.feature.name, hit: false);
      return null;
    }
  }

  /// Saves [data] (JSON-encodable) as fetched at [fetchedAt] (now).
  Future<void> write(CacheKey key, Object? data, {DateTime? fetchedAt}) async {
    final at = (fetchedAt ?? now()).toUtc();
    final s = _Stored(data, at);
    _remember(key.value, s);
    String encoded;
    try {
      encoded = jsonEncode({'k': key.value, 't': at.millisecondsSinceEpoch, 'd': data});
    } catch (_) {
      return;
    }
    await _store.write(key.account, key.name, encoded);
  }

  Future<void> remove(CacheKey key) async {
    _memory.remove(key.value);
    await _store.delete(key.account, key.name);
  }

  /// Runs [load] and saves what it returns - once at a time per key: a
  /// second caller while it is in flight gets the same answer instead of a
  /// second request. A failure is rethrown and saves nothing, so the saved
  /// copy stays as it was.
  /// [persist] turns the answer into what is saved (stripping inline
  /// images, say); the caller still gets the answer as it came.
  Future<Object?> fetch(CacheKey key, Future<Object?> Function() load,
      {Object? Function(Object? data)? persist}) {
    if (_off) return load();
    final k = key.value;
    final running = _inflight[k];
    if (running != null) {
      NetworkStats.instance.recordDedup(key.feature.name);
      return running;
    }
    final epoch = _epoch;
    final future = () async {
      try {
        final data = await load();
        if (epoch == _epoch) await write(key, persist == null ? data : persist(data));
        return data;
      } finally {
        _inflight.remove(k);
      }
    }();
    _inflight[k] = future;
    return future;
  }

  /// Marks every entry of [features] out of date. They are still shown
  /// until the refresh lands - offline, an out-of-date copy beats a blank
  /// screen - but the next read reports them as not fresh.
  void invalidate(Iterable<CacheFeature> features) {
    // A microsecond on, so an entry written in this same instant (the
    // fetch that raced the change) still counts as from before it.
    final at = now().toUtc().add(const Duration(microseconds: 1));
    var changed = false;
    for (final f in features) {
      _invalidated[f] = at;
      changed = true;
    }
    if (!changed || _off) return;
    unawaited(_store.write(_metaAccount, _invalidationsName, jsonEncode({
      for (final e in _invalidated.entries) e.key.name: e.value.millisecondsSinceEpoch,
    })));
  }

  /// Deletes everything kept for [userId] - sign-out.
  Future<void> clearAccount(String? userId) async {
    _epoch++;
    final account = 'u_${userId ?? 'guest'}';
    _memory.removeWhere((k, _) => k.startsWith('$account|'));
    _inflight.removeWhere((k, _) => k.startsWith('$account|'));
    await _store.deleteAccount(account);
  }

  Future<void> clearAll() async {
    _epoch++;
    _memory.clear();
    _inflight.clear();
    await _store.clear();
  }
}

/// A copy of a listing (or any record) safe to keep on the phone: inline
/// base64 images and videos dropped, URLs kept.
///
/// Legacy listings carry their photos as base64 strings that can run to
/// megabytes. Keeping them in the cache would make it as heavy as the
/// download it is meant to save; a legacy card shown offline falls back to
/// its placeholder instead, and gets its photo back on the next refresh.
Map<String, dynamic> stripInlineMedia(Map<String, dynamic> json) {
  final out = Map<String, dynamic>.from(json);
  for (final k in const [
    'verified_photos', 'showcase_image_url', 'seller_profile_photo',
    'profile_photo', 'photo', 'logo', 'cover_photo',
  ]) {
    final v = out[k];
    if (v is String && !isUrlLike(v)) out.remove(k);
  }
  out.remove('verified_video');
  out.remove('advert_video');
  return out;
}

/// [json] with any inline (base64) image longer than [maxInlineChars]
/// dropped. For records whose small inline picture is worth keeping - an
/// account's selfie, so the Menu shows a face offline - but not a
/// megabyte-long one.
Map<String, dynamic> stripLargeInlineMedia(Map<String, dynamic> json, {int maxInlineChars = 200000}) {
  bool tooBig(Object? v) => v is String && v.length > maxInlineChars && !isUrlLike(v);
  Object? walk(Object? v) {
    if (v is Map) {
      return <String, dynamic>{
        for (final e in v.entries)
          if (!tooBig(e.value)) '${e.key}': walk(e.value),
      };
    }
    if (v is List) return [for (final x in v) if (!tooBig(x)) walk(x)];
    return v;
  }

  return walk(json) as Map<String, dynamic>;
}

/// An http(s) URL or one of BROKA's own /media paths - as opposed to inline
/// base64 or a data: URI.
bool isUrlLike(String v) {
  final s = v.trim();
  if (s.contains(',')) {
    // Comma-joined photo lists: URLs only if every part is one.
    return s.split(',').every((p) => isUrlLike(p));
  }
  return s.startsWith('http://') || s.startsWith('https://') || s.startsWith('/media/');
}
