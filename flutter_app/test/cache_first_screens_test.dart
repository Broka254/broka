// The screens the first data-saving passes left out (2026-11-08), kept on
// the phone the way Home, the Menu and the Seller Dashboard already were:
//
//  * a Category Zone and a type-of-item screen open on their saved feed,
//    count, types and filters, and ask again only when those are old;
//  * Trending does the same, and a failed page is a Retry, not "nothing";
//  * the store directory opens on its saved list and rail;
//  * the call history opens on its saved calls and revalidates with an
//    ETag - an unchanged history is an empty 304;
//  * the store dashboard's performance card slows its self-refresh while
//    nothing changes.
// The store dashboard's own reopen test is in store_setup_test.dart, beside
// the fake store backend it uses.
import 'dart:convert';

import 'package:broka/core/cache/screen_cache.dart';
import 'package:broka/core/network/api_client.dart';
import 'package:broka/features/calls/data/call_history_repository.dart';
import 'package:broka/features/calls/presentation/call_history_screen.dart';
import 'package:broka/features/categories/data/repositories/categories_repository.dart';
import 'package:broka/features/categories/presentation/category_zone_screen.dart';
import 'package:broka/features/listings/data/listing_feed_cache.dart';
import 'package:broka/features/listings/domain/models/listing.dart';
import 'package:broka/features/stores/data/repositories/stores_repository.dart';
import 'package:broka/features/stores/presentation/store_list_screen.dart';
import 'package:broka/features/stores/presentation/widgets/store_performance.dart';
import 'package:broka/features/trending/presentation/trending_screen.dart';
import 'package:broka/services/api_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fake_api.dart';

/// pumpAndSettle never returns on these screens (the constellation animates).
Future<void> _settle(WidgetTester tester, [int frames = 10]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

http.Response _json(Object? body, {int status = 200, Map<String, String> headers = const {}}) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json', ...headers});

int _gets(bool Function(Uri uri) test) =>
    fakeRequests.where((r) => r.method == 'GET' && test(r.uri)).length;

Map<String, dynamic> _history() => {
      'calls': [
        {
          'id': 'c1', 'listing_id': 'listing-1', 'listing_name': 'Airtel 5G router',
          'buyer_id': 'buyer-7', 'my_role': 'seller', 'peer_id': 'buyer-7',
          'direction': 'incoming', 'outcome': 'missed', 'missed': true,
          'call_type': 'audio', 'duration_secs': null,
          'created_at': DateTime.now().toUtc().toIso8601String(),
        },
      ],
      'people': {
        'buyer-7': {'name': 'Amina Wanjiru', 'photo': null, 'photo_url': null, 'is_online': false},
      },
      'next_before': null,
    };

void main() {
  setUpAll(installFakeApi);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiService.currentUserId = 'u1';
    setFakeRoute(null);
    clearFakeRequests();
    ScreenCache.debugInstall();
  });

  tearDown(ScreenCache.debugReset);

  // ── Category Zone ─────────────────────────────────────────────────────────

  group('a Category Zone', () {
    Widget zone() => MaterialApp(
        home: CategoryZoneScreen(key: UniqueKey(), categoryId: 'Electronics', categoryName: 'Electronics'));

    // Page 0 only: whether a later page loads depends on how much of the
    // grid the test window builds, which is not what this is about.
    bool isFeed(Uri u) =>
        u.path == '/listings/' &&
        u.queryParameters['category_id'] == 'Electronics' &&
        u.queryParameters['offset'] == '0';

    testWidgets('asks for lean cards, and reopened while current asks for nothing', (tester) async {
      await tester.pumpWidget(zone());
      await _settle(tester);
      expect(_gets(isFeed), 1);
      expect(fakeRequests.firstWhere((r) => isFeed(r.uri)).uri.queryParameters['lean'], 'true');
      expect(find.text('128 results'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      clearFakeRequests();
      await tester.pumpWidget(zone());
      await _settle(tester);
      expect(_gets(isFeed), 0, reason: 'the saved feed is current');
      expect(_gets((u) => u.path.contains('/subcategories')), 0);
      expect(_gets((u) => u.path.contains('/filters')), 0);
      expect(find.text('Test item 0'), findsOneWidget);
      expect(find.text('128 results'), findsOneWidget, reason: 'the count is saved with the feed');
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('offline, it opens on the saved feed', (tester) async {
      await tester.pumpWidget(zone());
      await _settle(tester);
      await tester.pumpWidget(const SizedBox());

      ScreenCache.instance.invalidate(CacheFeature.values);
      setFakeRoute((_) => const FakeResponse.error());
      await tester.pumpWidget(zone());
      await _settle(tester);
      expect(find.text('Test item 0'), findsOneWidget);
      expect(find.text("Couldn't load listings"), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('the category repository', () {
    test('keeps types of item and filters, and serves them when the server fails', () async {
      var calls = 0;
      var fail = false;
      final repo = CategoriesRepository(client: ApiClient(client: MockClient((req) async {
        calls++;
        if (fail) return _json({'detail': 'down'}, status: 503);
        return _json(req.url.path.endsWith('/filters')
            ? <Object>[]
            : [{'id': 'phones', 'name': 'Phones', 'icon': null, 'parent_id': 'Electronics'}]);
      })));

      expect((await repo.getSubcategories('Electronics')).data.single.name, 'Phones');
      expect((await repo.getSubcategories('Electronics')).data, hasLength(1));
      expect(calls, 1, reason: 'the second came from the saved copy');
      await repo.getFilters('Electronics');
      await repo.getFilters('Electronics');
      expect(calls, 2, reason: 'an empty filter list is an answer, kept too');

      fail = true;
      final offline = await repo.getSubcategories('Electronics', forceRefresh: true);
      expect(calls, 3);
      expect(offline.data.single.name, 'Phones');
    });
  });

  test('a saved feed keeps its result count', () async {
    final total = ValueNotifier<int?>(128);
    final listing = fakeListingJson(1);
    final raw = {'listing-1': listing};
    final key = CacheKey.forUser(CacheFeature.categoryFeed, 'u1', {'category': 'x'});
    await ListingFeedCache(key: key, raw: raw, total: total)
        .write([BrokaListing.fromJson(listing)], page: 1, hasMore: false, fetchedAt: DateTime.now());

    final back = ValueNotifier<int?>(null);
    final snap = await ListingFeedCache(key: key, raw: {}, total: back).read();
    expect(snap!.items, hasLength(1));
    expect(back.value, 128);
  });

  // ── Trending ──────────────────────────────────────────────────────────────

  testWidgets('Trending asks for lean cards and reopens from its saved copy', (tester) async {
    Widget trending() => MaterialApp(home: TrendingScreen(key: UniqueKey()));
    await tester.pumpWidget(trending());
    await _settle(tester);
    bool firstPage(Uri u) => u.path == '/trending' && u.queryParameters['offset'] == '0';
    expect(_gets(firstPage), 1);
    expect(fakeRequests.firstWhere((r) => firstPage(r.uri)).uri.queryParameters['lean'], 'true');

    await tester.pumpWidget(const SizedBox());
    clearFakeRequests();
    await tester.pumpWidget(trending());
    await _settle(tester);
    expect(_gets(firstPage), 0);
    expect(find.text('Test item 0'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  // ── Store directory ───────────────────────────────────────────────────────

  testWidgets('the store directory reopens from its saved list', (tester) async {
    Widget directory() => MaterialApp(
        home: StoreListScreen(key: UniqueKey(), locate: () async => null, animateBackground: false));
    bool isList(Uri u) => u.path == '/stores';

    await tester.pumpWidget(directory());
    await _settle(tester);
    expect(_gets(isList), 1);
    expect(find.text('Store 0'), findsWidgets);

    await tester.pumpWidget(const SizedBox());
    clearFakeRequests();
    await tester.pumpWidget(directory());
    await _settle(tester);
    expect(_gets(isList), 0, reason: 'opened on the saved list');
    expect(find.text('Store 0'), findsWidgets);

    // An old copy is shown and refreshed - once, not once per step.
    await tester.pumpWidget(const SizedBox());
    ScreenCache.instance.invalidate([CacheFeature.storeDirectory]);
    clearFakeRequests();
    await tester.pumpWidget(directory());
    await _settle(tester);
    expect(_gets(isList), 1);
    await tester.pumpWidget(const SizedBox());
  });

  // ── Call history ──────────────────────────────────────────────────────────

  group('the call history', () {
    final requests = <http.Request>[];
    var down = false;
    late CallHistoryRepository repo;

    setUp(() {
      requests.clear();
      down = false;
      repo = CallHistoryRepository(client: ApiClient(client: MockClient((req) async {
        requests.add(req);
        if (down) return _json({'detail': 'down'}, status: 503);
        if (req.headers['If-None-Match'] == 'W/"h1"') {
          return http.Response('', 304, headers: {'etag': 'W/"h1"'});
        }
        return _json(_history(), headers: {'etag': 'W/"h1"'});
      })));
    });

    test('is lean, and an unchanged history is a 304 answered from the saved copy', () async {
      final first = await repo.page();
      expect(first.data.calls.single.peer.name, 'Amina Wanjiru');
      expect(requests.single.url.queryParameters['lean'], 'true');
      expect(requests.single.headers.containsKey('If-None-Match'), isFalse);

      final again = await repo.page();
      expect(requests.last.headers['If-None-Match'], 'W/"h1"');
      expect(again.data.calls.single.id, 'c1');
    });

    test('a later page is asked for plainly', () async {
      await repo.page();
      await repo.page(before: '2026-11-01T00:00:00Z');
      expect(requests.last.headers.containsKey('If-None-Match'), isFalse);
      expect(requests.last.url.queryParameters['before'], '2026-11-01T00:00:00Z');
    });

    testWidgets('offline, the screen opens on the saved calls', (tester) async {
      await repo.page();
      down = true;
      await tester.pumpWidget(MaterialApp(
          home: CallHistoryScreen(animateBackground: false, repository: repo)));
      await _settle(tester);
      expect(find.text('Amina Wanjiru'), findsOneWidget);
      expect(find.textContaining('No internet'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  });

  // ── Store dashboard ───────────────────────────────────────────────────────

  test("the performance card's self-refresh slows while nothing changes", () {
    expect([for (final q in [0, 1, 2, 3, 4, 9]) storeInsightsTicksBetween(q, dataSaver: false)],
        [1, 1, 2, 2, 4, 4]);
    expect(storeInsightsTicksBetween(0, dataSaver: true), 4);
  });

  test('the repository says whether the insights moved', () async {
    var visitors = 1;
    final repo = StoresRepository(client: ApiClient(client: MockClient((req) async =>
        _json({'stats': {'live_visitors': visitors}}))));
    await repo.getInsights('s1');
    expect(repo.insightsUnchanged('s1'), isFalse, reason: 'the first answer is news');
    await repo.getInsights('s1');
    expect(repo.insightsUnchanged('s1'), isTrue);
    visitors = 2;
    await repo.getInsights('s1');
    expect(repo.insightsUnchanged('s1'), isFalse);
    expect((await repo.savedInsights('s1')), isNotNull, reason: 'saved for the next open');
  });
}
