// ScreenCache, DataChanges and the network instrumentation (data-saving
// pass): the shared cache-first layer Home, the Menu, the store section and
// the Seller Dashboard read from.
import 'dart:convert';
import 'dart:io';

import 'package:broka/core/cache/cache_store.dart';
import 'package:broka/core/cache/data_changes.dart';
import 'package:broka/core/cache/screen_cache.dart';
import 'package:broka/core/network/instrumented_client.dart';
import 'package:broka/core/network/network_stats.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  late DateTime now;
  late MemoryCacheStore store;
  late ScreenCache cache;

  setUp(() {
    now = DateTime.utc(2026, 11, 7, 10);
    store = MemoryCacheStore();
    cache = ScreenCache.debugInstall(store: store, clock: () => now);
    NetworkStats.instance.reset();
  });

  tearDown(ScreenCache.debugReset);

  const policy = CachePolicy(freshFor: Duration(minutes: 3), keepFor: Duration(days: 1));
  CacheKey key([String user = 'u1', Map<String, Object?> params = const {}]) =>
      CacheKey.forUser(CacheFeature.homeFeed, user, params);

  group('freshness', () {
    test('a copy is fresh, then stale but still shown, then gone', () async {
      await cache.write(key(), {'n': 1});
      expect((await cache.read(key(), policy))!.isFresh, isTrue);

      now = now.add(const Duration(minutes: 4));
      final stale = await cache.read(key(), policy);
      expect(stale, isNotNull, reason: 'past its freshness time it is still shown');
      expect(stale!.isFresh, isFalse);
      expect(stale.data, {'n': 1});

      now = now.add(const Duration(days: 2));
      expect(await cache.read(key(), policy), isNull, reason: 'past keepFor it is discarded');
    });

    test('a copy survives the app restarting (read back from storage)', () async {
      await cache.write(key(), [1, 2, 3]);
      final restarted = ScreenCache.debugInstall(store: store, memory: false, clock: () => now);
      final e = await restarted.read(key(), policy);
      expect(e!.data, [1, 2, 3]);
      expect(e.isFresh, isTrue);
    });

    test('invalidating a feature makes its copies stale, and only its copies', () async {
      await cache.write(key(), 'feed');
      final menu = CacheKey.forUser(CacheFeature.menuAccount, 'u1');
      await cache.write(menu, 'account');
      now = now.add(const Duration(seconds: 1));
      cache.invalidate([CacheFeature.homeFeed]);
      expect((await cache.read(key(), policy))!.isFresh, isFalse);
      expect((await cache.read(key(), policy))!.data, 'feed', reason: 'kept for offline');
      expect((await cache.read(menu, policy))!.isFresh, isTrue);

      // A copy fetched after the change is fresh again.
      now = now.add(const Duration(seconds: 1));
      await cache.write(key(), 'new feed');
      expect((await cache.read(key(), policy))!.isFresh, isTrue);
    });

    test('an invalidation outlives a restart', () async {
      await cache.write(key(), 'feed');
      now = now.add(const Duration(seconds: 1));
      cache.invalidate([CacheFeature.homeFeed]);
      await Future<void>.delayed(Duration.zero);
      final restarted = ScreenCache.debugInstall(store: store, memory: false, clock: () => now);
      expect((await restarted.read(key(), policy))!.isFresh, isFalse);
    });
  });

  group('fetch', () {
    test('concurrent fetches of one key share one request', () async {
      var calls = 0;
      Future<Object?> load() async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return {'v': calls};
      }

      final results = await Future.wait([cache.fetch(key(), load), cache.fetch(key(), load)]);
      expect(calls, 1);
      expect(results[0], results[1]);
      expect(NetworkStats.instance.deduplicated['homeFeed'], 1);
      expect((await cache.read(key(), policy))!.data, {'v': 1});
    });

    test('a failed fetch leaves the saved copy as it was', () async {
      await cache.write(key(), 'good');
      await expectLater(cache.fetch(key(), () async => throw const SocketException('offline')),
          throwsA(isA<SocketException>()));
      expect((await cache.read(key(), policy))!.data, 'good');
    });

    test('persist saves a transformed copy and returns the original', () async {
      final got = await cache.fetch(key(), () async => {'photo': 'x' * 10, 'name': 'A'},
          persist: (d) => {'name': (d as Map)['name']});
      expect(got, {'photo': 'x' * 10, 'name': 'A'});
      expect((await cache.read(key(), policy))!.data, {'name': 'A'});
    });

    test('an answer that lands after a sign-out is not saved', () async {
      final slow = cache.fetch(key(), () async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return 'u1 private';
      });
      await cache.clearAccount('u1');
      await slow;
      expect(await cache.read(key(), policy), isNull);
    });
  });

  group('accounts', () {
    test("one account never reads another's copy", () async {
      await cache.write(key('alice'), 'alice inbox');
      expect(await cache.read(key('bob'), policy), isNull);
      expect(await cache.read(CacheKey.forUser(CacheFeature.homeFeed, null), policy), isNull,
          reason: 'a guest is an account of its own');
    });

    test('sign-out deletes that account and nobody else', () async {
      await cache.write(key('alice'), 'a');
      await cache.write(key('bob'), 'b');
      await cache.clearAccount('alice');
      expect(await cache.read(key('alice'), policy), isNull);
      expect((await cache.read(key('bob'), policy))!.data, 'b');
    });

    test('filters are part of the key', () async {
      await cache.write(key('u1', {'sort': 'recent'}), 'recent');
      await cache.write(key('u1', {'sort': 'price_low'}), 'cheap');
      expect((await cache.read(key('u1', {'sort': 'recent'}), policy))!.data, 'recent');
      expect((await cache.read(key('u1', {'sort': 'price_low'}), policy))!.data, 'cheap');
      expect(key('u1', {'a': 1, 'b': null}).value, key('u1', {'a': 1}).value,
          reason: 'an unset filter is no filter');
      expect(key('u1', {'a': 1, 'b': 2}).name, key('u1', {'b': 2, 'a': 1}).name);
    });
  });

  group('FileCacheStore', () {
    test('round-trips, isolates accounts, and deletes one account', () async {
      final dir = await Directory.systemTemp.createTemp('screen_cache_test');
      addTearDown(() => dir.delete(recursive: true));
      final files = FileCacheStore(() async => dir);
      await files.write('u_a', 'homeFeed_1', '{"x":1}');
      await files.write('u_b', 'homeFeed_1', '{"x":2}');
      expect(await files.read('u_a', 'homeFeed_1'), '{"x":1}');
      expect(await files.read('u_b', 'homeFeed_1'), '{"x":2}');
      await files.deleteAccount('u_a');
      expect(await files.read('u_a', 'homeFeed_1'), isNull);
      expect(await files.read('u_b', 'homeFeed_1'), '{"x":2}');
      expect(FileCacheStore.safe('../../etc/passwd'), isNot(contains('/')));
    });

    test('a hash collision is a miss, not the other entry', () async {
      final a = key('u1', {'q': 'a'});
      await store.write(a.account, a.name, jsonEncode({'k': 'something else', 't': 0, 'd': 1}));
      expect(await ScreenCache.debugInstall(store: store, memory: false).read(a, policy), isNull);
    });
  });

  group('inline media', () {
    test('base64 images and videos are not saved; URLs are', () {
      final out = stripInlineMedia({
        'id': 'l1',
        'verified_photos': '/9j/4AAQSkZJRgABAQ',
        'showcase_image_url': 'data:image/jpeg;base64,/9j/4AAQ',
        'seller_profile_photo': 'https://media.broka.co.ke/a.webp',
        'verified_video': 'AAAA',
        'cover': {'thumb': 'https://x/t.webp'},
      });
      expect(out.containsKey('verified_photos'), isFalse);
      expect(out.containsKey('showcase_image_url'), isFalse);
      expect(out.containsKey('verified_video'), isFalse);
      expect(out['seller_profile_photo'], 'https://media.broka.co.ke/a.webp');
      expect(out['cover'], {'thumb': 'https://x/t.webp'});
    });

    test('only large inline pictures are dropped from an account', () {
      final out = stripLargeInlineMedia({
        'profile_photo': 'a' * 300000,
        'logo': 'b' * 100,
        'photos': ['c' * 300000, 'https://x/y.webp'],
      });
      expect(out.containsKey('profile_photo'), isFalse);
      expect(out['logo'], 'b' * 100);
      expect(out['photos'], ['https://x/y.webp']);
    });
  });

  group('DataChanges', () {
    test('classifies changes by what they change', () {
      Set<DataDomain> c(String m, String p) => DataChanges.classify(m, p);
      expect(c('POST', '/listings/'), {DataDomain.listings});
      expect(c('PATCH', '/listings/abc'), {DataDomain.listings});
      expect(c('DELETE', '/listings/abc'), {DataDomain.listings});
      expect(c('POST', '/listings/abc/store'), {DataDomain.listings, DataDomain.store});
      expect(c('POST', '/listings/abc/save'), isEmpty, reason: 'a buyer saving is not a change to the feed');
      expect(c('POST', '/listings/abc/like'), isEmpty);
      expect(c('POST', '/listings/abc/interest'), isEmpty);
      expect(c('PATCH', '/auth/profile'), {DataDomain.account});
      expect(c('POST', '/auth/login'), isEmpty);
      expect(c('POST', '/auth/token/refresh'), isEmpty);
      expect(c('POST', '/auth/heartbeat'), isEmpty);
      expect(c('POST', '/stores'), {DataDomain.store, DataDomain.listings});
      expect(c('POST', '/stores/s1/status'), {DataDomain.store, DataDomain.listings});
      expect(c('POST', '/stores/s1/visit'), isEmpty);
      expect(c('POST', '/deal/d1/confirm-delivery'), {DataDomain.deals});
      expect(c('POST', '/negotiate/chat'), isEmpty);
      expect(c('POST', '/media/images'), isEmpty);
    });

    test('a successful change marks its features stale; a refused one changes nothing', () async {
      final feed = key();
      final account = CacheKey.forUser(CacheFeature.menuAccount, 'u1');
      await cache.write(feed, 'feed');
      await cache.write(account, 'me');
      now = now.add(const Duration(seconds: 1));
      final before = DataChanges.instance.revision(DataDomain.listings).value;

      DataChanges.instance.observeResponse('DELETE', Uri.parse('https://api/listings/l9'), 409);
      expect(DataChanges.instance.revision(DataDomain.listings).value, before);
      expect((await cache.read(feed, policy))!.isFresh, isTrue);

      final events = <DataChange>[];
      final sub = DataChanges.instance.events.listen(events.add);
      DataChanges.instance.observeResponse('DELETE', Uri.parse('https://api/listings/l9'), 200);
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      expect(DataChanges.instance.revision(DataDomain.listings).value, before + 1);
      expect((await cache.read(feed, policy))!.isFresh, isFalse);
      expect((await cache.read(account, policy))!.isFresh, isTrue);
      expect(events.single.listingId, 'l9');
      expect(events.single.isDelete, isTrue);
    });
  });

  group('InstrumentedClient', () {
    test('counts requests and bytes, records no query, and reports changes', () async {
      final inner = MockClient((req) async => req.method == 'GET'
          ? http.Response('x' * 1234, 200)
          : http.Response('{}', 201));
      final client = InstrumentedClient(inner);
      await client.get(Uri.parse('https://api.test/listings/?search=my+secret&limit=20'));
      final before = DataChanges.instance.revision(DataDomain.listings).value;
      await client.post(Uri.parse('https://api.test/listings/'), body: '{}');

      final stats = NetworkStats.instance;
      expect(stats.requestCount, 2);
      expect(stats.records.first.bytes, 1234);
      expect(stats.records.first.endpoint, '/listings/');
      expect(stats.summary(), isNot(contains('secret')));
      expect(DataChanges.instance.revision(DataDomain.listings).value, before + 1);
    });

    test('folds ids out of endpoints', () {
      expect(NetworkStats.endpointOf(Uri.parse('https://x/negotiate/inbox/3f2a9c1e-77aa-4b')),
          '/negotiate/inbox/{id}');
      expect(NetworkStats.endpointOf(Uri.parse('https://x/listings/seller/user12345/summary')),
          '/listings/seller/{id}/summary');
    });
  });
}
