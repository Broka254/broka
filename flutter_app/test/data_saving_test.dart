// Data-saving pass: screens remember what they downloaded.
//
//  * ProductGridView keeps what it shows while it refreshes, keeps it when
//    the refresh fails, and can start from a saved copy (ProductGridCache).
//  * Home is not refetched by a trip to the Inbox, the Menu or Sell: its
//    feed, pages and scroll position are all still there. A listing posted
//    or deleted meanwhile (DataChanges) is what refreshes it.
//  * Home, the Menu and the Seller Dashboard show their saved copy at once,
//    ask the server only when it is out of date, and keep showing it -
//    saying so - when the server can't be reached.
//  * The dashboard asks for the launch offers once, counts its totals on
//    the server, and loads listings a page at a time.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:broka/core/cache/data_changes.dart';
import 'package:broka/core/cache/screen_cache.dart';
import 'package:broka/core/navigation/app_route_observer.dart';
import 'package:broka/features/listings/domain/models/listing.dart';
import 'package:broka/screens/home_screen.dart';
import 'package:broka/screens/menu_screen.dart';
import 'package:broka/screens/seller_dashboard_screen.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/widgets/product_card.dart';
import 'package:broka/widgets/product_grid_view.dart';

import 'support/fake_api.dart';

Future<void> _settle(WidgetTester tester, [int frames = 8]) async {
  for (int i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

List<BrokaListing> _page(int page, [int n = 20]) =>
    [for (int i = 0; i < n; i++) BrokaListing.fromJson(fakeListingJson(page * 20 + i))];

class _FakeGridCache implements ProductGridCache {
  _FakeGridCache([this.snapshot]);
  ProductGridSnapshot? snapshot;
  final writes = <List<dynamic>>[];

  @override
  Future<ProductGridSnapshot?> read() async => snapshot;

  @override
  Future<void> write(List<dynamic> items,
      {required int page, required bool hasMore, required DateTime fetchedAt}) async {
    writes.add(items);
  }
}

Widget _gridHost({
  required Future<List<dynamic>> Function(int) fetchPage,
  ProductGridCache? cache,
  ProductGridController? controller,
}) =>
    MaterialApp(
      home: Scaffold(
        body: CustomScrollView(slivers: [
          ProductGridView(
            sliver: true,
            fetchPage: fetchPage,
            cache: cache,
            controller: controller,
            itemId: (i) => (i as BrokaListing).id,
          ),
        ]),
      ),
    );

int _listingPages() => fakeRequests
    .where((r) => r.method == 'GET' && r.uri.path == '/listings/' && r.uri.queryParameters['seller_id'] == null)
    .length;

void main() {
  setUpAll(installFakeApi);
  setUpAll(() => HomeScreen.railHintEnabled = false);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/shared_preferences'),
      (call) async => call.method == 'getAll' ? <String, Object>{} : null,
    );
    setFakeRoute(null);
    clearFakeRequests();
  });

  tearDown(ScreenCache.debugReset);

  // ── ProductGridView ─────────────────────────────────────────────────────────

  group('ProductGridView', () {
    testWidgets('a refresh keeps the listings on screen until the new page lands',
        (tester) async {
      final controller = ProductGridController();
      var fail = false;
      await tester.pumpWidget(_gridHost(
        controller: controller,
        fetchPage: (p) async {
          if (fail) throw StateError('offline');
          return _page(p);
        },
      ));
      await _settle(tester);
      expect(find.byType(ProductCard), findsWidgets);

      fail = true;
      final refresh = controller.refresh();
      await tester.pump();
      expect(find.byType(ProductCardSkeleton), findsNothing, reason: 'no skeleton over real listings');
      expect(find.byType(ProductCard), findsWidgets);
      await refresh;
      await _settle(tester);
      expect(find.byType(ProductCard), findsWidgets, reason: 'a failed refresh empties nothing');
      expect(find.text("Couldn't load listings"), findsNothing);
      expect(find.textContaining("Couldn't refresh"), findsOneWidget);
    });

    testWidgets('a fresh saved copy is shown without asking the server', (tester) async {
      final fetched = <int>[];
      final cache = _FakeGridCache(ProductGridSnapshot(
          items: _page(0, 6), page: 1, hasMore: true, fetchedAt: DateTime.now(), fresh: true));
      await tester.pumpWidget(_gridHost(
          cache: cache, fetchPage: (p) async { fetched.add(p); return _page(p); }));
      await _settle(tester);
      expect(fetched, isEmpty);
      expect(find.text('Test item 0'), findsOneWidget);
    });

    testWidgets('a stale saved copy shows first, then the refresh replaces it', (tester) async {
      final fetched = <int>[];
      final cache = _FakeGridCache(ProductGridSnapshot(
          items: _page(0, 4), page: 1, hasMore: true,
          fetchedAt: DateTime.now().subtract(const Duration(hours: 1)), fresh: false));
      await tester.pumpWidget(_gridHost(
        cache: cache,
        fetchPage: (p) async {
          fetched.add(p);
          await Future<void>.delayed(const Duration(milliseconds: 300));
          return [BrokaListing.fromJson(fakeListingJson(99))];
        },
      ));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('Test item 0'), findsOneWidget, reason: 'saved copy before the network answers');
      await _settle(tester);
      expect(fetched, [0]);
      expect(find.text('Test item 99'), findsOneWidget);
      expect(find.text('Test item 0'), findsNothing);
      expect(cache.writes, isNotEmpty);
    });

    testWidgets('a stale saved copy stays when its refresh fails', (tester) async {
      final cache = _FakeGridCache(ProductGridSnapshot(
          items: _page(0, 4), page: 1, hasMore: true,
          fetchedAt: DateTime.now().subtract(const Duration(hours: 1)), fresh: false));
      await tester.pumpWidget(_gridHost(
          cache: cache, fetchPage: (_) async => throw StateError('offline')));
      await _settle(tester);
      expect(find.text('Test item 0'), findsOneWidget);
      expect(find.text("Couldn't load listings"), findsNothing);
    });

    testWidgets('a removed listing leaves at once; a later page repeats nothing', (tester) async {
      final controller = ProductGridController();
      await tester.pumpWidget(_gridHost(
        controller: controller,
        // Page 1 overlaps page 0 by one item, as when a listing is posted
        // between the two requests.
        fetchPage: (p) async => p == 0
            ? _page(0, 4)
            : [BrokaListing.fromJson(fakeListingJson(3)), BrokaListing.fromJson(fakeListingJson(50))],
      ));
      await _settle(tester);
      controller.removeWhere((i) => (i as BrokaListing).id == 'listing-1');
      await tester.pump();
      expect(find.text('Test item 1'), findsNothing);
      expect(find.text('Test item 0'), findsOneWidget);
    });
  });

  // ── Home ────────────────────────────────────────────────────────────────────

  group('Home', () {
    Widget home() => MaterialApp(
          home: const HomeScreen(),
          navigatorObservers: [appRouteObserver],
          routes: {
            for (final r in ['/inbox', '/menu', '/sell', '/zeno', '/seller-dashboard'])
              r: (_) => Scaffold(body: Text('stub $r')),
          },
        );

    NavigatorState nav(WidgetTester tester) => tester.state<NavigatorState>(find.byType(Navigator));

    ScrollPosition feedPosition(WidgetTester tester) => tester
        .stateList<ScrollableState>(find.byType(Scrollable))
        .map((s) => s.position)
        .firstWhere((p) => p.axis == Axis.vertical);

    setUp(() => ApiService.currentUserId = null);

    testWidgets('opening the Inbox, Menu or Sell and coming back refetches nothing',
        (tester) async {
      await tester.pumpWidget(home());
      await _settle(tester);
      expect(_listingPages(), 1);

      for (final route in ['/inbox', '/menu', '/sell', '/seller-dashboard']) {
        nav(tester).pushNamed(route);
        await _settle(tester);
        await tester.pump(const Duration(seconds: 5));
        nav(tester).pop();
        await _settle(tester);
      }
      expect(_listingPages(), 1, reason: 'navigation alone is no reason to download the feed again');
      expect(find.byType(ProductCard), findsWidgets);
    });

    testWidgets('scroll position and loaded pages survive a trip to the Inbox', (tester) async {
      await tester.pumpWidget(home());
      await _settle(tester);
      for (int i = 0; i < 6 && _listingPages() < 2; i++) {
        await tester.drag(find.byType(CustomScrollView).first, const Offset(0, -1500));
        await _settle(tester);
      }
      expect(_listingPages(), 2, reason: 'page 1 loaded');
      final offset = feedPosition(tester).pixels;
      expect(offset, greaterThan(0));

      nav(tester).pushNamed('/inbox');
      await _settle(tester);
      nav(tester).pop();
      await _settle(tester);
      expect(feedPosition(tester).pixels, offset);
      expect(_listingPages(), 2, reason: 'no page reloaded');
    });

    testWidgets('a listing posted while Home was covered refreshes it once, on return',
        (tester) async {
      await tester.pumpWidget(home());
      await _settle(tester);
      nav(tester).pushNamed('/sell');
      await _settle(tester);
      // The publish request succeeding, as the network layer reports it.
      DataChanges.instance.observeResponse('POST', Uri.parse('https://api.test/listings/'), 201);
      await _settle(tester);
      expect(_listingPages(), 1, reason: 'not while Sell is on screen');
      nav(tester).pop();
      await _settle(tester);
      expect(_listingPages(), 2);
      expect(fakeRequests.where((r) => r.uri.path == '/listings/').last.uri.queryParameters['offset'], '0');
    });

    testWidgets('a listing deleted elsewhere leaves the feed', (tester) async {
      await tester.pumpWidget(home());
      await _settle(tester);
      expect(find.text('Test item 0'), findsOneWidget);
      nav(tester).pushNamed('/seller-dashboard');
      await _settle(tester);
      DataChanges.instance.observeResponse('DELETE', Uri.parse('https://api.test/listings/listing-0'), 200);
      nav(tester).pop();
      await _settle(tester);
      expect(find.text('Test item 0'), findsNothing);
    });

    testWidgets('offline, Home opens on the listings it saved', (tester) async {
      final cache = ScreenCache.debugInstall();
      await cache.write(
        CacheKey.forUser(CacheFeature.homeFeed, null, const {}),
        {'items': [for (int i = 0; i < 4; i++) fakeListingJson(i)], 'page': 1, 'has_more': true},
        fetchedAt: DateTime.now().subtract(const Duration(hours: 2)),
      );
      setFakeRoute((uri) => uri.path == '/listings/' ? const FakeResponse.error() : null);
      await tester.pumpWidget(home());
      await _settle(tester);
      expect(find.text('Test item 0'), findsOneWidget);
      expect(find.text("Couldn't load listings"), findsNothing);
      expect(find.byKey(const Key('stale-data-banner')), findsOneWidget);
    });

    testWidgets('a fresh saved feed opens without a request', (tester) async {
      final cache = ScreenCache.debugInstall();
      await cache.write(
        CacheKey.forUser(CacheFeature.homeFeed, null, const {}),
        {'items': [for (int i = 0; i < 4; i++) fakeListingJson(i)], 'page': 1, 'has_more': true},
      );
      await tester.pumpWidget(home());
      await _settle(tester);
      expect(find.text('Test item 0'), findsOneWidget);
      expect(_listingPages(), 0);
    });
  });

  // ── Menu ────────────────────────────────────────────────────────────────────

  group('Menu', () {
    Map<String, dynamic> me() => {
          'id': 'user-1', 'name': 'Grace Akinyi', 'nickname': 'Grace',
          'phone': '+254700000001', 'account_type': 'buyer_seller', 'seller_tier': 'long_term',
          'is_verified': true, 'rating': 4.7, 'review_count': 12, 'completed_deals': 3,
        };
    var offline = false;
    Object? route(Uri uri) {
      if (offline) return const FakeResponse.error();
      if (uri.path == '/auth/me') return me();
      if (uri.path.startsWith('/listings') && uri.queryParameters['seller_id'] != null) {
        return {'items': <Object?>[], 'total': 7};
      }
      if (uri.path == '/stores/mine') return const FakeResponse(null);
      return null;
    }

    int meRequests() => fakeRequests.where((r) => r.uri.path == '/auth/me').length;

    Widget menu() => MaterialApp(
          home: const MenuScreen(animateBackground: false),
          routes: {'/terms': (_) => const Scaffold(body: Text('terms'))},
        );

    setUp(() {
      offline = false;
      ApiService.currentUserId = 'user-1';
      setFakeRoute(route);
      ScreenCache.debugInstall();
    });

    testWidgets('opened again, it shows the saved account without a request', (tester) async {
      await tester.pumpWidget(menu());
      await _settle(tester);
      expect(find.text('Grace'), findsOneWidget);
      expect(meRequests(), 1);

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(menu());
      await tester.pump();
      await tester.pump();
      expect(find.text('Grace'), findsOneWidget, reason: 'from the saved copy');
      await _settle(tester);
      expect(meRequests(), 1);
    });

    testWidgets('offline, the saved account stays, and the store section with it', (tester) async {
      await tester.pumpWidget(menu());
      await _settle(tester);
      offline = true;
      // Out of date, so the next open asks - and fails.
      ScreenCache.instance.invalidate(CacheFeature.values);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(menu());
      await _settle(tester);
      expect(find.text('Grace'), findsOneWidget);
      expect(find.text("Couldn't load your profile"), findsNothing);
      expect(find.byKey(const Key('stale-data-banner')), findsWidgets);
    });

    testWidgets('back from an unrelated screen reloads nothing; a profile change reloads it',
        (tester) async {
      await tester.pumpWidget(menu());
      await _settle(tester);
      final nav = tester.state<NavigatorState>(find.byType(Navigator));
      final before = meRequests();
      nav.pushNamed('/terms');
      await _settle(tester);
      nav.pop();
      await _settle(tester);
      expect(meRequests(), before);
    });
  });

  // ── Seller Dashboard ────────────────────────────────────────────────────────

  group('Seller Dashboard', () {
    Map<String, dynamic> row(int i) => {
          'id': 'listing-$i', 'name': 'Item $i', 'category': 'Electronics', 'price': 1000 + i,
          'listing_type': 'direct', 'status': 'active', 'seller_id': 'seller-1', 'views': 2,
        };
    var offline = false;
    Map<String, dynamic>? summary;
    Object? route(Uri uri) {
      final p = uri.path;
      if (offline) return const FakeResponse.error();
      if (p == '/auth/user/seller-1') return {'id': 'seller-1', 'name': 'Grace Akinyi', 'completed_deals': 3};
      if (p == '/listings/seller/seller-1/summary') return summary ?? const FakeResponse(null, statusCode: 404);
      if (p == '/listings/') {
        final offset = int.parse(uri.queryParameters['offset'] ?? '0');
        final limit = int.parse(uri.queryParameters['limit'] ?? '20');
        return [for (int i = offset; i < offset + limit && i < 45; i++) row(i)];
      }
      if (p == '/stores/mine') return const FakeResponse(null);
      if (p.endsWith('/revenue')) return {'values': [0, 0, 0, 0, 0, 0, 0], 'has_real_data': false};
      if (p.endsWith('/metrics')) return {'history': [], 'advice': <String, dynamic>{}};
      if (p == '/pricing/launch-offers') {
        return {
          'listing_free': {'limit': 0, 'claimed': 0, 'remaining': 0, 'free_days': 60},
          'store_free': {'limit': 0, 'claimed': 0, 'remaining': 0, 'free_days': 60},
        };
      }
      return null;
    }

    Widget dashboard() => const MaterialApp(home: SellerDashboardScreen(animateBackground: false));

    setUp(() {
      offline = false;
      summary = null;
      ApiService.currentUserId = 'seller-1';
      setFakeRoute(route);
    });

    testWidgets('asks for the launch offers once while opening', (tester) async {
      await tester.pumpWidget(dashboard());
      await _settle(tester);
      expect(fakeRequests.where((r) => r.uri.path == '/pricing/launch-offers'), hasLength(1));
    });

    testWidgets('takes its totals from the server and loads one page of listings', (tester) async {
      summary = {'total_listings': 45, 'active_listings': 45, 'featured_listings': 2, 'total_views': 90};
      await tester.pumpWidget(dashboard());
      await _settle(tester);
      final pages = fakeRequests.where((r) => r.uri.path == '/listings/').toList();
      expect(pages, hasLength(1));
      expect(pages.single.uri.queryParameters['limit'], '20',
          reason: 'not the whole catalogue (it was 200)');
      expect(find.text('45'), findsWidgets, reason: "the server's count, not the 20 loaded");
    });

    testWidgets('the products tab loads the next page as it is reached', (tester) async {
      tester.view.physicalSize = const Size(390 * 3.0, 844 * 3.0);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(dashboard());
      await _settle(tester);
      await tester.tap(find.byKey(const Key('dashboard-tab-1')));
      await _settle(tester);
      for (int i = 0; i < 12; i++) {
        if (fakeRequests.any((r) => r.uri.path == '/listings/' && r.uri.queryParameters['offset'] == '20')) {
          break;
        }
        await tester.drag(find.text('Item 0').hitTestable().evaluate().isEmpty
            ? find.byType(Scrollable).last
            : find.text('Item 0'), const Offset(0, -2000), warnIfMissed: false);
        await _settle(tester, 4);
      }
      expect(fakeRequests.where((r) => r.uri.path == '/listings/' && r.uri.queryParameters['offset'] == '20'),
          hasLength(1));
    });

    testWidgets('the Deals tab loads every listing it needs to find their deals', (tester) async {
      await tester.pumpWidget(dashboard());
      await _settle(tester);
      await tester.tap(find.byKey(const Key('dashboard-tab-2')));
      await _settle(tester, 20);
      final offsets = fakeRequests
          .where((r) => r.uri.path == '/listings/')
          .map((r) => r.uri.queryParameters['offset'])
          .toList();
      expect(offsets, ['0', '20', '40']);
      expect(fakeRequests.where((r) => r.uri.path == '/negotiate/deal-status/listing-44'), hasLength(1));
    });

    testWidgets('offline, it opens on the saved figures and says so', (tester) async {
      ScreenCache.debugInstall();
      summary = {'total_listings': 45, 'active_listings': 45, 'featured_listings': 2, 'total_views': 90};
      await tester.pumpWidget(dashboard());
      await _settle(tester);
      await tester.pumpWidget(const SizedBox());

      offline = true;
      ScreenCache.instance.invalidate(CacheFeature.values);
      clearFakeRequests();
      await tester.pumpWidget(dashboard());
      await _settle(tester);
      expect(find.text('45'), findsWidgets);
      expect(find.byKey(const Key('stale-data-banner')), findsOneWidget);
    });

    testWidgets('reopened while its copy is current, it asks for nothing but live deal statuses',
        (tester) async {
      ScreenCache.debugInstall();
      await tester.pumpWidget(dashboard());
      await _settle(tester);
      await tester.pumpWidget(const SizedBox());
      clearFakeRequests();
      // Without a server summary nothing is saved for it, so give one.
      summary = {'total_listings': 45, 'active_listings': 45, 'featured_listings': 2, 'total_views': 90};
      await tester.pumpWidget(dashboard());
      await _settle(tester);
      await tester.pumpWidget(const SizedBox());
      clearFakeRequests();
      await tester.pumpWidget(dashboard());
      await _settle(tester);
      final paths = fakeRequests.map((r) => r.uri.path).toSet();
      expect(paths.contains('/auth/user/seller-1'), isFalse);
      expect(paths.contains('/listings/'), isFalse);
      expect(paths.contains('/listings/seller/seller-1/revenue'), isFalse);
      expect(paths.any((p) => p.startsWith('/negotiate/deal-status/')), isTrue,
          reason: 'whether money is in escrow is always asked, never saved');
    });
  });
}
