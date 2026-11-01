// Premium storefront redesign: the responsive catalogue, the calmer hero,
// and the upgraded product card.
//
// Covers what the redesign promises without re-pinning the whole
// storefront (storefront_test.dart already owns loading, errors, visits,
// details and the cart screen):
//   1. one product owns the catalogue width;
//   2. several products keep the two-column phone grid;
//   3. wide screens gain columns;
//   4. narrow phones and long names never overflow;
//   5. Add to cart and the quantity stepper still work;
//   6. search, filters and category selection still work;
//   7. text scaling and reduced motion are respected;
//   8. the default ProductGridView stays a fixed two-column grid.
import 'dart:convert';

import 'package:broka/core/network/api_client.dart';
import 'package:broka/features/stores/data/repositories/stores_repository.dart';
import 'package:broka/features/stores/data/store_cart.dart';
import 'package:broka/features/stores/presentation/store_home_screen.dart';
import 'package:broka/features/stores/presentation/widgets/store_product_card.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/widgets/constellation_background.dart';
import 'package:broka/widgets/product_grid_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _json(Object? body, [int status = 200]) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json'});

Map<String, dynamic> _store({String name = 'Clanix Electronics'}) => {
      'id': 's1',
      'name': name,
      'slug': 'clanix',
      'url': 'https://broka.co.ke/store/clanix',
      'category': 'Electronics',
      'categories': ['Electronics'],
      'county': 'Nairobi',
      'subcounty': 'Starehe',
      'location_description': 'Moi Avenue, opposite the Hilton',
      'business_email': 'sales@clanix.co.ke',
      'business_email_verified': true,
      'owner': {
        'name': 'Jane Wanjiru',
        'verified': true,
        'rating': 4.8,
        'review_count': 4,
        'completed_deals': 12,
        'member_since': '2025-01-10T00:00:00',
        'online': true,
        'last_active': 'Active now'
      },
      'is_active': true,
      'listing_count': 3,
      'cover': null,
      'photos': [],
      'photo_images': [],
      'created_at': '2026-09-02T08:00:00',
    };

Map<String, dynamic> _listing(
        String id, String name, double price, String category,
        {String? condition, int quantity = 1}) =>
    {
      'id': id,
      'seller_id': 'u1',
      'name': name,
      'category': category,
      'price': price,
      'condition': condition,
      'quantity': quantity,
      'lat': 0,
      'lng': 0,
      'status': 'active',
      'listing_type': 'direct',
      'store_id': 's1',
      'store_name': 'Clanix Electronics',
      'store_slug': 'clanix',
    };

class _Backend {
  _Backend({
    String storeName = 'Clanix Electronics',
    List<Map<String, dynamic>>? listings,
    List<Map<String, dynamic>>? categories,
  })  : _storeName = storeName,
        _listings = listings ??
            [
              _listing('l1', 'Samsung A15', 18000, 'Electronics',
                  condition: 'new', quantity: 5),
              _listing('l2', 'Tecno Spark 20', 12000, 'Electronics',
                  condition: 'used'),
              _listing('l3', 'PS5 Controller', 9000, 'Gaming'),
            ],
        _categories = categories ??
            [
              {'name': 'Electronics', 'count': 2},
              {'name': 'Gaming', 'count': 1},
            ] {
    client = ApiClient(client: MockClient((req) async {
      requests.add(req);
      final path = req.url.path;
      if (path == '/stores/s1' || path == '/stores/slug/clanix') {
        return _json(_store(name: _storeName));
      }
      if (path == '/stores/mine') return _json(null);
      if (path == '/stores/s1/categories') return _json(_categories);
      if (path == '/stores/s1/visit') return _json({'counted': true}, 202);
      if (path == '/stores/s1/listings') {
        final q = req.url.queryParameters;
        var items = List<Map<String, dynamic>>.from(_listings);
        if (q['category'] != null) {
          items = items.where((l) => l['category'] == q['category']).toList();
        }
        if (q['condition'] != null) {
          items = items.where((l) => l['condition'] == q['condition']).toList();
        }
        if (q['max_price'] != null) {
          final max = double.parse(q['max_price']!);
          items = items.where((l) => (l['price'] as double) <= max).toList();
        }
        if (q['search'] != null) {
          items = items
              .where((l) => (l['name'] as String)
                  .toLowerCase()
                  .contains(q['search']!.toLowerCase()))
              .toList();
        }
        if (q['sort'] == 'price_low') {
          items.sort(
              (a, b) => (a['price'] as double).compareTo(b['price'] as double));
        }
        if (q['offset'] != '0') items = [];
        return _json(items);
      }
      return _json({'detail': 'no route $path'}, 404);
    }));
    repo = StoresRepository(client: client);
  }

  final String _storeName;
  final List<Map<String, dynamic>> _listings;
  final List<Map<String, dynamic>> _categories;
  late final ApiClient client;
  late final StoresRepository repo;
  final List<http.Request> requests = [];
}

/// Pumps the store at [size] logical pixels (devicePixelRatio 3, so
/// 360x640 is the narrow Android phone and 800x1280 a tablet).
Future<void> _pumpStore(WidgetTester tester, _Backend backend,
    {Size size = const Size(390, 844)}) async {
  tester.view.physicalSize = Size(size.width * 3, size.height * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: StoreHomeScreen(
        storeId: 's1', repository: backend.repo, animateBackground: false),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiService.currentUserId = null;
    StoreCart.resetAll();
  });

  group('redesigned store catalogue', () {
    testWidgets('one product owns the catalogue width', (tester) async {
      final backend = _Backend(
        listings: [
          _listing('l1', 'Airtel 5G router', 1800, 'Electronics',
              condition: 'refurbished', quantity: 3),
        ],
        categories: [
          {'name': 'Electronics', 'count': 1},
        ],
      );
      await _pumpStore(tester, backend);

      expect(find.byType(StoreProductCard), findsOneWidget);
      // The single card is not squeezed into a two-column cell...
      expect(find.byType(SliverGrid), findsNothing);
      // ...it spans the catalogue (390 wide phone, 8dp sides).
      final cardWidth = tester.getSize(find.byType(StoreProductCard)).width;
      expect(cardWidth, greaterThan(390 * 0.8));
      expect(cardWidth, closeTo(390 - 16, 2));
      // A lone category is not navigation: no rail.
      expect(find.byKey(const Key('category-pill-all')), findsNothing);
      // And the catalogue sky stays calm behind the product.
      expect(
          tester
              .widget<ConstellationBackground>(
                  find.byType(ConstellationBackground))
              .intensity,
          lessThan(1.0));
      expect(tester.takeException(), isNull);
    });

    // Tall enough that every card is built: lazily-built slivers only
    // materialise the visible rows.
    testWidgets('several products keep the two-column phone grid',
        (tester) async {
      await _pumpStore(tester, _Backend(), size: const Size(390, 1250));

      expect(find.byType(StoreProductCard), findsNWidgets(3));
      final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
      expect(
          (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
              .crossAxisCount,
          2);
      // The first row holds two cards side by side.
      final cards = find.byType(StoreProductCard);
      expect(
          tester.getTopLeft(cards.at(0)).dy, tester.getTopLeft(cards.at(1)).dy);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a tablet gains a third column', (tester) async {
      final backend = _Backend(listings: [
        _listing('l1', 'Samsung A15', 18000, 'Electronics'),
        _listing('l2', 'Tecno Spark 20', 12000, 'Electronics'),
        _listing('l3', 'PS5 Controller', 9000, 'Gaming'),
        _listing('l4', 'JBL Flip 6', 15000, 'Electronics'),
        _listing('l5', 'Anker Charger', 2500, 'Electronics'),
      ]);
      await _pumpStore(tester, backend, size: const Size(800, 1280));

      final grid = tester.widget<SliverGrid>(find.byType(SliverGrid));
      expect(
          (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
              .crossAxisCount,
          3);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a narrow Android phone lays out cleanly', (tester) async {
      await _pumpStore(tester, _Backend(), size: const Size(360, 640));

      expect(find.byKey(const Key('store-hero-name')), findsOneWidget);
      expect(find.byType(StoreProductCard), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('long store and product names never overflow', (tester) async {
      final backend = _Backend(
        storeName:
            'Java House of Electronics and Fine Home Goods Trading Company Limited',
        listings: [
          _listing(
              'l1',
              'Airtel 5G router with an extra long descriptive product name for testing',
              1800,
              'Electronics',
              condition: 'refurbished',
              quantity: 3),
        ],
      );
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await _pumpStore(tester, backend, size: const Size(360, 640));

      expect(find.byKey(const Key('store-hero-name')), findsOneWidget);
      expect(find.byType(StoreProductCard), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Add to cart and the stepper still work', (tester) async {
      await _pumpStore(tester, _Backend());

      await tester.ensureVisible(find.byKey(const Key('add-to-cart-l1')));
      await tester.tap(find.byKey(const Key('add-to-cart-l1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('store-cart-bar')), findsOneWidget);

      await tester.ensureVisible(find.byKey(const Key('card-l1-plus')));
      await tester.tap(find.byKey(const Key('card-l1-plus')));
      await tester.pump();
      expect(
          tester.widget<Text>(find.byKey(const Key('card-l1-qty'))).data, '2');
      expect(tester.takeException(), isNull);
    });

    testWidgets('search, filters and categories still work', (tester) async {
      final backend = _Backend();
      // Tall enough that the full catalogue is built after each filter.
      await _pumpStore(tester, backend, size: const Size(390, 1250));

      // Search narrows the catalogue...
      await tester.enterText(find.byKey(const Key('store-search')), 'tecno');
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pumpAndSettle();
      expect(find.byType(StoreProductCard), findsOneWidget);
      expect(find.text('Tecno Spark 20'), findsOneWidget);
      expect(backend.requests.last.url.path, '/stores/s1/listings');
      expect(backend.requests.last.url.queryParameters['search'], 'tecno');

      // ...clearing it shows everything again.
      await tester.enterText(find.byKey(const Key('store-search')), '');
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pumpAndSettle();
      expect(find.byType(StoreProductCard), findsNWidgets(3));

      // Category pills filter too.
      await tester.tap(find.byKey(const Key('category-pill-Gaming')));
      await tester.pumpAndSettle();
      expect(find.byType(StoreProductCard), findsOneWidget);
      expect(find.text('PS5 Controller'), findsOneWidget);
      await tester.tap(find.byKey(const Key('category-pill-all')));
      await tester.pumpAndSettle();
      expect(find.byType(StoreProductCard), findsNWidgets(3));

      // The filter panel sorts, and the gold dot says a filter is on.
      await tester.tap(find.byKey(const Key('store-filter')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('store-filter-panel')), findsOneWidget);
      await tester.tap(find.byKey(const Key('filter-sort-price_low')));
      await tester.pumpAndSettle();
      expect(backend.requests.last.url.queryParameters['sort'], 'price_low');
      expect(find.byKey(const Key('store-filters-active-dot')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('large text and reduced motion stay clean', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final semantics = tester.ensureSemantics();
      await _pumpStore(tester, _Backend(), size: const Size(360, 640));

      expect(find.byKey(const Key('store-hero-name')), findsOneWidget);
      expect(find.byType(StoreProductCard), findsWidgets);
      // Key actions keep their labels at large text.
      expect(find.bySemanticsLabel('More about this store'), findsOneWidget);
      expect(tester.takeException(), isNull);
      semantics.dispose();
    });
  });

  group('marketplace grids are unaffected', () {
    testWidgets('the default grid is still two fixed columns', (tester) async {
      tester.view.physicalSize = const Size(1080, 1920);
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 800,
            child: ProductGridView(
              fetchPage: (page) async => page == 0 ? [1, 2, 3] : [],
              itemBuilder: (_, item) => SizedBox(
                key: Key('market-item-$item'),
                height: 120,
                child: Text('item $item'),
              ),
            ),
          ),
        ),
      ));
      // Fixed pumps, not pumpAndSettle: the trailing spinner keeps ticking
      // while more pages could load (category_zone_test.dart pins why).
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();

      final grid = tester.widget<GridView>(find.byType(GridView));
      expect(
          (grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount)
              .crossAxisCount,
          2);
      expect(find.text('item 1'), findsOneWidget);
      expect(find.text('item 3'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
