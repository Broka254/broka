// Online Stores phase 3 in the app: the storefront screen, and store links
// opening it.
import 'dart:convert';

import 'package:broka/core/network/api_client.dart';
import 'package:broka/features/stores/data/repositories/stores_repository.dart';
import 'package:broka/features/stores/domain/models/store.dart';
import 'package:broka/features/stores/data/store_cart.dart';
import 'package:broka/features/stores/presentation/store_cart_screen.dart';
import 'package:broka/features/stores/presentation/store_home_screen.dart';
import 'package:broka/features/stores/presentation/widgets/store_details_view.dart';
import 'package:broka/features/stores/presentation/widgets/store_product_card.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/services/deep_link_service.dart';
import 'package:broka/widgets/broka_image.dart';
import 'package:broka/widgets/broka_search_field.dart';
import 'package:broka/widgets/constellation_background.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _json(Object? body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

// A 1x1 PNG, so a store can have photos without the network.
const _pixel = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42'
    'mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';

Map<String, dynamic> _image(String id) =>
    {'id': id, 'thumb': _pixel, 'medium': _pixel, 'large': _pixel};

Map<String, dynamic> _store({bool active = true, String? description, bool photos = false,
    bool online = true}) => {
      'id': 's1',
      'name': 'Clanix Electronics',
      'slug': 'clanix',
      'url': 'https://broka.co.ke/store/clanix',
      'category': 'Electronics',
      'description': description,
      'county': 'Nairobi',
      'subcounty': 'Starehe',
      'location_description': 'Moi Avenue, opposite the Hilton',
      'business_email': 'sales@clanix.co.ke',
      'business_email_verified': true,
      'owner': {'name': 'Jane Wanjiru', 'verified': true, 'rating': 4.8, 'completed_deals': 12,
          'member_since': '2025-01-10T00:00:00', 'online': online, 'last_active': online ? 'Active now' : 'Active 3h ago'},
      'is_active': active,
      'listing_count': 3,
      'cover': photos ? _image('c1') : null,
      'photos': [],
      'photo_images': photos ? [_image('p1'), _image('p2')] : [],
      'created_at': '2026-09-02T08:00:00',
    };

Map<String, dynamic> _listing(String id, String name, double price, String category,
        {String? condition, int? quantity}) => {
      'id': id, 'seller_id': 'u1', 'name': name, 'category': category, 'price': price,
      'condition': condition, 'quantity': quantity,
      'lat': 0, 'lng': 0, 'status': 'active', 'listing_type': 'direct',
      'store_id': 's1', 'store_name': 'Clanix Electronics', 'store_slug': 'clanix',
    };

class _Backend {
  _Backend({bool active = true, String? description, bool photos = false,
      int? failListingsTimes, bool online = true}) {
    _failListings = failListingsTimes ?? 0;
    client = ApiClient(client: MockClient((req) async {
      requests.add(req);
      final path = req.url.path;
      if (path == '/stores/s1' || path == '/stores/slug/clanix') {
        return _json(_store(active: active, description: description, photos: photos,
            online: online));
      }
      if (path == '/stores/slug/nope') return _json({'detail': 'Store not found'}, 404);
      if (path == '/stores/mine') return _json(null);
      if (path == '/stores/s1/categories') {
        return _json([{'name': 'Electronics', 'count': 2}, {'name': 'Gaming', 'count': 1}]);
      }
      if (path == '/stores/s1/visit') return _json({'counted': true}, 202);
      if (path == '/listings/l1') return _json(_listing('l1', 'Samsung A15', 18000, 'Electronics', quantity: 5));
      if (path == '/listings/l9') {
        return _json({..._listing('l9', 'Not this store', 1, 'Electronics'), 'store_id': 's2'});
      }
      if (path == '/stores/s1/listings') {
        if (_failListings > 0) {
          _failListings--;
          return _json({'detail': 'Server busy'}, 503);
        }
        final q = req.url.queryParameters;
        var items = [
          _listing('l1', 'Samsung A15', 18000, 'Electronics', condition: 'new', quantity: 2),
          _listing('l2', 'Tecno Spark', 12000, 'Electronics', condition: 'used'),
          _listing('l3', 'PS5 Controller', 9000, 'Gaming'),
        ];
        if (q['category'] != null) items = items.where((l) => l['category'] == q['category']).toList();
        if (q['condition'] != null) {
          items = items.where((l) => l['condition'] == q['condition']).toList();
        }
        if (q['max_price'] != null) {
          final max = double.parse(q['max_price']!);
          items = items.where((l) => (l['price'] as double) <= max).toList();
        }
        if (q['search'] != null) {
          items = items.where((l) =>
              (l['name'] as String).toLowerCase().contains(q['search']!.toLowerCase())).toList();
        }
        if (q['sort'] == 'price_low') {
          items.sort((a, b) => (a['price'] as double).compareTo(b['price'] as double));
        }
        if (q['offset'] != '0') items = [];
        return _json(items);
      }
      return _json({'detail': 'no route $path'}, 404);
    }));
    repo = StoresRepository(client: client);
  }

  late final ApiClient client;
  late final StoresRepository repo;
  late int _failListings;
  final List<http.Request> requests = [];

  List<Map<String, String>> listingQueries() => requests
      .where((r) => r.url.path == '/stores/s1/listings')
      .map((r) => r.url.queryParameters)
      .toList();
}

Future<void> _pumpStore(WidgetTester tester, _Backend backend,
    {String? storeId = 's1', String? slug, String? via}) async {
  // A tall phone: the whole first page of products is on screen.
  tester.view.physicalSize = const Size(1080, 3000);
  tester.view.devicePixelRatio = 2.75;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: StoreHomeScreen(storeId: storeId, slug: slug, via: via,
        repository: backend.repo, animateBackground: false),
  ));
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiService.currentUserId = null;
    StoreCart.resetAll();
  });

  group('StoreHomeScreen', () {

    testWidgets('shows the store, its categories and products, and counts the visit',
        (tester) async {
      final backend = _Backend(description: 'Genuine phones and accessories.');
      await _pumpStore(tester, backend, via: 'whatsapp');

      expect(find.byType(ConstellationBackground), findsOneWidget);
      expect(find.text('Clanix Electronics'), findsWidgets);
      expect(find.text('Electronics · Starehe, Nairobi'), findsOneWidget);
      final identity = find.byKey(const Key('store-identity'));
      expect(find.descendant(of: identity, matching: find.byIcon(Icons.verified_rounded)),
          findsOneWidget);
      // The name is the header: no logo square, no initial in a box.
      expect(find.byKey(const Key('store-hero-name')), findsOneWidget);
      expect(find.descendant(of: identity, matching: find.byType(BrokaImage)), findsNothing);
      expect(find.descendant(of: identity, matching: find.text('C')), findsNothing);
      // Whether the owner is around, and their record at a glance.
      expect(find.descendant(of: find.byKey(const Key('store-presence')),
          matching: find.text('Online now')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('hero-rating')),
          matching: find.text('4.8')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('hero-deals')),
          matching: find.text('12 deals')), findsOneWidget);
      // The rest is under More, not crowding the header.
      expect(find.byKey(const Key('store-more-details')), findsOneWidget);
      expect(find.byKey(const Key('store-details-button')), findsOneWidget);
      for (final text in ['Since 2025', 'Genuine phones and accessories.']) {
        expect(find.text(text), findsNothing, reason: text);
      }
      expect(find.byKey(const Key('store-perks')), findsOneWidget);
      expect(find.byKey(const Key('category-pill-all')), findsOneWidget);
      expect(find.byKey(const Key('category-pill-Gaming')), findsOneWidget);
      expect(find.byType(StoreProductCard), findsNWidgets(3));
      // A shop's card: condition on the photo, Add to cart under the price.
      expect(find.descendant(of: find.byKey(const Key('store-product-l1')),
          matching: find.text('New')), findsOneWidget);
      expect(find.byKey(const Key('add-to-cart-l1')), findsOneWidget);

      final visit = backend.requests.singleWhere((r) => r.url.path == '/stores/s1/visit');
      expect(jsonDecode(visit.body), {'via': 'whatsapp'});
    });

    testWidgets("the search box is the app's own, readable one", (tester) async {
      await _pumpStore(tester, _Backend());
      // The shared field (16px text, 54dp) rather than the old 44dp pill
      // with 14px text people couldn't read back.
      final field = find.byKey(const Key('store-search'));
      expect(find.ancestor(of: field, matching: find.byType(BrokaSearchField)), findsOneWidget);
      expect(find.text('Search Clanix Electronics'), findsOneWidget);
      // The filter button stands as tall as the field beside it.
      final fieldBox = tester.getSize(find.byType(BrokaSearchField));
      expect(tester.getSize(find.byKey(const Key('store-filter'))).height, fieldBox.height);

      // Typing, then the clear button, searches and then shows everything.
      await tester.enterText(field, 'tecno');
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pumpAndSettle();
      expect(find.byType(StoreProductCard), findsOneWidget);
      await tester.tap(find.byTooltip('Clear'));
      await tester.pumpAndSettle();
      expect(find.byType(StoreProductCard), findsNWidgets(3));
    });

    testWidgets('the catalogue gets more of the screen than Home gives a card', (tester) async {
      await _pumpStore(tester, _Backend());
      final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
      final card = tester.getSize(find.byType(StoreProductCard).first);
      // 8dp sides (was 12) and 12dp between the two columns...
      expect(card.width, closeTo((width - 16 - 12) / 2, 0.5));
      // ...and a photo 0.95 of the card's width tall (Home's cards: 0.85).
      expect(card.height,
          closeTo(card.width * StoreProductCard.imageShare + StoreProductCard.textBlock, 0.5));
      expect(StoreProductCard.imageShare, greaterThan(0.85));
    });

    testWidgets('an owner who is away shows when they were last active', (tester) async {
      await _pumpStore(tester, _Backend(online: false));
      final presence = find.byKey(const Key('store-presence'));
      expect(find.descendant(of: presence, matching: find.text('Active 3h ago')), findsOneWidget);
      expect(find.text('Online now'), findsNothing);
    });

    testWidgets('the store photo is not behind the name, but under Store details',
        (tester) async {
      final backend = _Backend(photos: true);
      await _pumpStore(tester, backend);
      final photo = find.byWidgetPredicate((w) => w is BrokaImage && w.source == _pixel);
      // The header is the name and the facts, on colour - not the photo.
      expect(photo, findsNothing);
      expect(find.byType(StoreProductCard), findsNWidgets(3));

      await tester.tap(find.byKey(const Key('store-more-details')));
      await tester.pumpAndSettle();
      expect(find.byType(StoreDetailsScreen), findsOneWidget);
      // The cover and both shop photos.
      await tester.dragUntilVisible(find.byKey(const Key('store-photos')),
          find.byKey(const Key('store-details-list')), const Offset(0, -200));
      expect(find.descendant(of: find.byKey(const Key('store-photos')), matching: photo),
          findsNWidgets(3));
      await tester.tap(find.byKey(const Key('store-photo-1')));
      await tester.pumpAndSettle();
      expect(find.byType(StorePhotoViewer), findsOneWidget);
      expect(find.text('2 of 3'), findsOneWidget);
    });

    testWidgets("Store details: the seller's record, location, contact and store info",
        (tester) async {
      final backend = _Backend(description: 'Genuine phones and accessories.');
      await _pumpStore(tester, backend);
      // From the bar, as from anywhere in the catalogue.
      await tester.tap(find.byKey(const Key('store-details-button')));
      await tester.pumpAndSettle();

      final summary = find.byKey(const Key('store-details-summary'));
      expect(find.descendant(of: summary, matching: find.text('Clanix Electronics')),
          findsOneWidget);
      expect(find.descendant(of: summary, matching: find.text('Open')), findsOneWidget);
      final owner = find.byKey(const Key('store-owner'));
      expect(find.descendant(of: owner, matching: find.text('Jane Wanjiru')), findsOneWidget);
      expect(find.descendant(of: owner, matching: find.text('Verified seller')), findsOneWidget);
      // Deals done, rating and the year joined, each in its own tile.
      for (final (key, value, label) in [
        ('owner-deals', '12', 'Deals done'),
        ('owner-rating', '4.8', 'Rating'),
        ('owner-since', '2025', 'On BROKA since'),
      ]) {
        final tile = find.byKey(Key(key));
        expect(find.descendant(of: tile, matching: find.text(value)), findsOneWidget, reason: key);
        expect(find.descendant(of: tile, matching: find.text(label)), findsOneWidget, reason: key);
      }
      final details = find.byKey(const Key('store-details'));
      Future<void> show(Finder f) => tester.dragUntilVisible(
          f, find.byKey(const Key('store-details-list')), const Offset(0, -200));
      await show(find.text('Genuine phones and accessories.'));
      await show(find.byKey(const Key('store-location')));
      expect(find.text('Starehe, Nairobi'), findsOneWidget);
      expect(find.text('Moi Avenue, opposite the Hilton'), findsOneWidget);
      await show(find.byKey(const Key('store-email')));
      expect(find.text('sales@clanix.co.ke'), findsOneWidget);
      await show(find.byKey(const Key('store-buying-safely')));
      for (final text in ['Electronics', 'broka.co.ke/store/clanix', '3 on sale',
          'September 2026']) {
        expect(find.descendant(of: details, matching: find.text(text)), findsOneWidget,
            reason: text);
      }
      // Nothing about the store is fetched twice for the details.
      expect(backend.requests.where((r) => r.url.path == '/stores/s1'), hasLength(1));

      // Back is the store's products again.
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(StoreProductCard), findsNWidgets(3));
    });

    testWidgets("a new seller's record says so instead of inventing numbers", (tester) async {
      await tester.pumpWidget(MaterialApp(home: StoreDetailsScreen(
        store: Store.fromJson({
          ..._store(),
          'owner': {'verified': false, 'rating': 5.0, 'completed_deals': 0},
        }),
        animateBackground: false,
      )));
      await tester.pumpAndSettle();
      final owner = find.byKey(const Key('store-owner'));
      expect(find.descendant(of: owner, matching: find.text('The owner of Clanix Electronics')),
          findsOneWidget);
      expect(find.descendant(of: owner, matching: find.text('Not verified yet')), findsOneWidget);
      expect(find.descendant(of: find.byKey(const Key('owner-deals')), matching: find.text('0')),
          findsOneWidget);
      // A rating with no deals behind it isn't one.
      expect(find.descendant(of: find.byKey(const Key('owner-rating')),
          matching: find.text('New')), findsOneWidget);
      expect(find.text('5.0'), findsNothing);
      expect(find.descendant(of: find.byKey(const Key('owner-since')), matching: find.text('–')),
          findsOneWidget);
    });

    testWidgets('a link can open straight on Store details', (tester) async {
      final backend = _Backend();
      tester.view.physicalSize = const Size(1080, 3000);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        onGenerateRoute: (settings) => MaterialPageRoute(
          settings: const RouteSettings(arguments: {'storeId': 's1', 'view': 'details'}),
          builder: (_) => StoreHomeScreen(repository: backend.repo, animateBackground: false),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(StoreDetailsScreen), findsOneWidget);
      expect(find.byKey(const Key('store-owner')), findsOneWidget);
      // Opened on top of the store's home: Back is its products.
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(StoreDetailsScreen), findsNothing);
      expect(find.byType(StoreProductCard), findsNWidgets(3));
    });

    testWidgets('Store details finds the shop on a map and emails it', (tester) async {
      final opened = <Uri>[];
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(
        child: StoreDetailsView(
          store: Store.fromJson(_store()),
          openUrl: (uri) async {
            opened.add(uri);
            return true;
          },
        ),
      ))));
      await tester.ensureVisible(find.byKey(const Key('store-open-map')));
      await tester.tap(find.byKey(const Key('store-open-map')));
      await tester.ensureVisible(find.byTooltip('Email the store'));
      await tester.tap(find.byTooltip('Email the store'));
      await tester.pumpAndSettle();
      expect(opened.first.host, 'www.google.com');
      expect(opened.first.queryParameters['query'],
          'Moi Avenue, opposite the Hilton, Starehe, Nairobi, Kenya');
      expect(opened.last.toString(), 'mailto:sales@clanix.co.ke');
    });

    testWidgets('category, search and sort filter the catalogue', (tester) async {
      final backend = _Backend();
      await _pumpStore(tester, backend);

      await tester.tap(find.byKey(const Key('category-pill-Gaming')));
      await tester.pumpAndSettle();
      expect(find.byType(StoreProductCard), findsOneWidget);
      expect(backend.listingQueries().last['category'], 'Gaming');

      await tester.tap(find.byKey(const Key('category-pill-all')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('store-search')), 'tecno');
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pumpAndSettle();
      expect(find.byType(StoreProductCard), findsOneWidget);
      expect(backend.listingQueries().last['search'], 'tecno');
      expect(backend.listingQueries().last.containsKey('category'), isFalse);

      // Home's filter button opens the panel: sort, condition and price.
      expect(find.byKey(const Key('store-filter-panel')), findsNothing);
      await tester.tap(find.byKey(const Key('store-filter')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('store-filter-panel')), findsOneWidget);
      await tester.tap(find.byKey(const Key('filter-sort-price_low')));
      await tester.pumpAndSettle();
      expect(backend.listingQueries().last['sort'], 'price_low');
      expect(find.byKey(const Key('store-filters-active-dot')), findsOneWidget);

      await tester.enterText(find.byKey(const Key('store-search')), '');
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('filter-condition-used')));
      await tester.pumpAndSettle();
      expect(backend.listingQueries().last['condition'], 'used');
      expect(find.byType(StoreProductCard), findsOneWidget);
      expect(find.text('Tecno Spark'), findsOneWidget);

      await tester.ensureVisible(find.byKey(const Key('filter-price-to5k')));
      await tester.tap(find.byKey(const Key('filter-price-to5k')));
      await tester.pumpAndSettle();
      expect(backend.listingQueries().last['min_price'], '1000');
      expect(backend.listingQueries().last['max_price'], '5000');

      await tester.ensureVisible(find.text('Reset filters'));
      await tester.tap(find.text('Reset filters'));
      await tester.pumpAndSettle();
      final last = backend.listingQueries().last;
      for (final key in ['sort', 'condition', 'min_price', 'max_price']) {
        expect(last.containsKey(key), isFalse, reason: key);
      }
      expect(find.byKey(const Key('store-filters-active-dot')), findsNothing);
    });

    testWidgets('Add to cart: a stepper on the card, the cart bar, and the badge',
        (tester) async {
      final backend = _Backend();
      await _pumpStore(tester, backend);
      expect(find.byKey(const Key('store-cart-bar')), findsNothing);

      await tester.ensureVisible(find.byKey(const Key('add-to-cart-l1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('add-to-cart-l1')));
      await tester.pumpAndSettle();
      // The button became - 1 +, and the bar and badge count it.
      expect(find.byKey(const Key('add-to-cart-l1')), findsNothing);
      expect(find.byKey(const Key('card-l1-qty')), findsOneWidget);
      expect(find.byKey(const Key('store-cart-bar')), findsOneWidget);
      expect(find.text('1 item in your cart'), findsOneWidget);
      expect(find.text('KES 18,000'), findsWidgets);

      // Two in stock: a second is fine, a third isn't offered.
      await tester.ensureVisible(find.byKey(const Key('card-l1-plus')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('card-l1-plus')));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(find.byKey(const Key('card-l1-qty'))).data, '2');
      expect(tester.widget<IconButton>(find.byKey(const Key('card-l1-plus'))).onPressed, isNull);

      // A single item (no stock count) is one.
      await tester.ensureVisible(find.byKey(const Key('add-to-cart-l2')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('add-to-cart-l2')));
      await tester.pumpAndSettle();
      expect(find.text('3 items in your cart'), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('store-cart-count'))).data, '3');
      expect(find.text('KES 48,000'), findsOneWidget);

      // Kept on the phone for the next visit.
      final prefs = await SharedPreferences.getInstance();
      final saved = jsonDecode(prefs.getString('store_cart_v1_s1')!) as List;
      expect(saved.map((i) => (i as Map)['id']), ['l1', 'l2']);

      // - at one takes it out.
      await tester.ensureVisible(find.byKey(const Key('card-l2-minus')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('card-l2-minus')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('add-to-cart-l2')), findsOneWidget);
      expect(find.text('2 items in your cart'), findsOneWidget);

      await tester.tap(find.byKey(const Key('store-cart-bar')));
      await tester.pumpAndSettle();
      expect(find.byType(StoreCartScreen), findsOneWidget);
    });

    testWidgets('a saved cart comes back when the store opens again', (tester) async {
      SharedPreferences.setMockInitialValues({
        'store_cart_v1_s1': jsonEncode([
          {'id': 'l3', 'name': 'PS5 Controller', 'price': 9000, 'category': 'Gaming',
              'max': 1, 'qty': 1},
        ]),
      });
      await _pumpStore(tester, _Backend());
      expect(find.text('1 item in your cart'), findsOneWidget);
      expect(find.byKey(const Key('card-l3-qty')), findsOneWidget);
    });

    testWidgets('opens from a link name', (tester) async {
      final backend = _Backend();
      await _pumpStore(tester, backend, storeId: null, slug: 'clanix');
      expect(find.byType(StoreProductCard), findsNWidgets(3));
      expect(backend.requests.first.url.path, '/stores/slug/clanix');
    });

    testWidgets('a missing store says so', (tester) async {
      final backend = _Backend();
      await _pumpStore(tester, backend, storeId: null, slug: 'nope');
      expect(find.text('Store not found'), findsOneWidget);
      expect(find.text('Try again'), findsNothing);
    });

    testWidgets('a paused store shows a notice and no catalogue', (tester) async {
      final backend = _Backend(active: false);
      await _pumpStore(tester, backend);
      expect(find.byKey(const Key('store-paused-banner')), findsOneWidget);
      expect(find.byKey(const Key('store-search')), findsNothing);
      expect(backend.listingQueries(), isEmpty);
    });

    testWidgets('a failed catalogue load can be retried, not shown as empty', (tester) async {
      final backend = _Backend(failListingsTimes: 1);
      await _pumpStore(tester, backend);
      expect(find.byType(StoreProductCard), findsNothing);
      expect(find.text('Nothing listed yet'), findsNothing);
      final retry = find.textContaining(RegExp('retry', caseSensitive: false));
      expect(retry, findsWidgets);
      await tester.tap(retry.first);
      await tester.pumpAndSettle();
      expect(find.byType(StoreProductCard), findsNWidgets(3));
    });

    testWidgets("a cart link fills this store's cart and opens it", (tester) async {
      final backend = _Backend();
      tester.view.physicalSize = const Size(1080, 3000);
      tester.view.devicePixelRatio = 2.75;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        onGenerateRoute: (settings) => MaterialPageRoute(
          settings: const RouteSettings(arguments: {
            'slug': 'clanix', 'view': 'cart', 'items': {'l1': 2, 'l9': 1},
          }),
          builder: (_) => StoreHomeScreen(repository: backend.repo, animateBackground: false),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(StoreCartScreen), findsOneWidget);
      final cart = StoreCart.of('s1');
      // Another store's product never comes in through this store's link.
      expect(cart.items.map((i) => (i.listingId, i.quantity)), [('l1', 2)]);
      expect(cart.items.single.price, 18000);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(StoreProductCard), findsNWidgets(3));
    });

    for (final size in const [Size(320, 568), Size(430, 932)]) {
      testWidgets('nothing overflows at ${size.width.toInt()}dp', (tester) async {
        tester.view.physicalSize = size * 3;
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);
        final backend = _Backend(description: 'A long description ' * 20, photos: true);
        await tester.pumpWidget(MaterialApp(home: StoreHomeScreen(
            storeId: 's1', repository: backend.repo, animateBackground: false)));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        // "More details" has scrolled away; the bar's button is still there.
        await tester.tap(find.byKey(const Key('store-details-button')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'Store details at $size');
        for (var i = 0; i < 4; i++) {
          await tester.drag(find.byKey(const Key('store-details-list')), const Offset(0, -500));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull, reason: 'Store details at $size');
        }
      });
    }
  });

  group('StoreCartScreen', () {
    CartItem item(String id, String name, double price, {int max = 1}) =>
        CartItem(listingId: id, name: name, price: price, category: 'Electronics',
            maxQuantity: max);

    Future<List<String>> pumpCart(WidgetTester tester, List<CartItem> items) async {
      // Signed in, as checkout needs.
      SharedPreferences.setMockInitialValues({'auth_token': 't', 'user_id': 'buyer-1'});
      await ApiService.loadSavedSession();
      addTearDown(ApiService.clearSession);
      final cart = StoreCart.of('s1');
      await cart.load();
      for (final i in items) {
        cart.add(i);
      }
      final opened = <String>[];
      await tester.pumpWidget(MaterialApp(home: StoreCartScreen(
        storeId: 's1',
        storeName: 'Clanix Electronics',
        animateBackground: false,
        openDeal: (_, i) => opened.add(i.listingId),
      )));
      await tester.pumpAndSettle();
      return opened;
    }

    testWidgets('lines, quantities and the total', (tester) async {
      await pumpCart(tester, [item('l1', 'Samsung A15', 18000, max: 3), item('l2', 'Case', 500)]);
      expect(find.text('Your cart (2)'), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const Key('cart-subtotal'))).data, 'KES 18,500');

      await tester.tap(find.byKey(const Key('cart-l1-plus')));
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(find.byKey(const Key('cart-subtotal'))).data, 'KES 36,500');
      expect(find.text('Your cart (3)'), findsOneWidget);

      await tester.tap(find.byKey(const Key('cart-remove-l2')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('cart-item-l2')), findsNothing);
      expect(tester.widget<Text>(find.byKey(const Key('cart-subtotal'))).data, 'KES 36,000');

      await tester.tap(find.byKey(const Key('cart-clear')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Empty'));
      await tester.pumpAndSettle();
      expect(find.text('Your cart is empty'), findsOneWidget);
      expect(find.byKey(const Key('cart-checkout')), findsNothing);
    });

    testWidgets('checkout pays each product in its own deal room', (tester) async {
      final opened = await pumpCart(
          tester, [item('l1', 'Samsung A15', 18000), item('l2', 'Case', 500)]);
      await tester.tap(find.byKey(const Key('cart-checkout')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('checkout-sheet')), findsOneWidget);
      expect(find.text('Checkout · Clanix Electronics'), findsOneWidget);

      await tester.tap(find.byKey(const Key('checkout-pay-l2')));
      await tester.pumpAndSettle();
      expect(opened, ['l2']);
      expect(find.text('Opened'), findsOneWidget);
      expect(find.byKey(const Key('checkout-pay-l1')), findsOneWidget);
    });

    testWidgets('a cart of one product goes straight to its deal room', (tester) async {
      final opened = await pumpCart(tester, [item('l1', 'Samsung A15', 18000)]);
      await tester.tap(find.byKey(const Key('cart-checkout')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('checkout-sheet')), findsNothing);
      expect(opened, ['l1']);
    });

    test('a quantity never passes what the listing has', () async {
      final cart = StoreCart.of('s2');
      expect(cart.add(item('a', 'A', 100, max: 2)), isTrue);
      expect(cart.add(item('a', 'A', 100, max: 2)), isTrue);
      expect(cart.add(item('a', 'A', 100, max: 2)), isFalse);
      cart.setQuantity('a', 9);
      expect(cart.quantityOf('a'), 2);
      cart.setQuantity('a', 0);
      expect(cart.isEmpty, isTrue);
    });
  });

  group('Store links', () {
    test('which links are store links', () {
      expect(StoreLinkTarget.parse('https://broka.co.ke/store/clanix'),
          const StoreLinkTarget(slug: 'clanix'));
      expect(StoreLinkTarget.parse('https://www.broka.co.ke/store/Clanix/?via=tiktok'),
          const StoreLinkTarget(slug: 'clanix', via: 'tiktok'));
      expect(StoreLinkTarget.parse('https://broka.co.ke/store/clanix/p/abc-123?via=qr'),
          const StoreLinkTarget(slug: 'clanix', listingId: 'abc-123', via: 'qr'));
      // The web's Store details page.
      expect(StoreLinkTarget.parse('https://broka.co.ke/store/clanix/about?via=whatsapp'),
          const StoreLinkTarget(slug: 'clanix', via: 'whatsapp', details: true));
      // The web's "check out in the app": the products and how many.
      expect(StoreLinkTarget.parse('https://broka.co.ke/store/clanix/cart?items=l1:2,l2,bad!:1,l3:0'),
          const StoreLinkTarget(slug: 'clanix', cart: {'l1': 2, 'l2': 1}));
      expect(StoreLinkTarget.parse('https://broka.co.ke/store/clanix/cart'),
          const StoreLinkTarget(slug: 'clanix', cart: {}));
      for (final bad in [
        null, '', 'http://broka.co.ke/store/clanix', 'https://evil.com/store/clanix',
        'https://broka.co.ke/', 'https://broka.co.ke/store/', 'https://broka.co.ke/stores/x',
        'https://broka.co.ke/store/bad_name', 'https://broka.co.ke/store/x/p/',
        'https://broka.co.ke/store/clanix/q/1', 'https://broka.co.ke/store/clanix/about/x',
        'https://broka.co.ke/store/clanix/abouts',
      ]) {
        expect(StoreLinkTarget.parse(bad), isNull, reason: '$bad');
      }
    });

    testWidgets('a link that launched the app waits for the splash, then opens on top',
        (tester) async {
      const channel = MethodChannel('test/links');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async =>
              call.method == 'getInitialLink'
                  ? 'https://broka.co.ke/store/clanix?via=whatsapp'
                  : null);
      final seen = <RouteSettings>[];
      final key = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: key,
        home: const Text('home'),
        onGenerateRoute: (s) {
          seen.add(s);
          return MaterialPageRoute(settings: s, builder: (_) => Text('route ${s.name}'));
        },
      ));
      final links = DeepLinkService(channel: channel);
      await links.init(key);
      expect(links.pending, const StoreLinkTarget(slug: 'clanix', via: 'whatsapp'));
      expect(seen, isEmpty, reason: 'nothing opens before the app is ready');

      links.appReady();
      await tester.pumpAndSettle();
      expect(seen.single.name, '/store-view');
      expect(seen.single.arguments, {'slug': 'clanix', 'via': 'whatsapp'});
      expect(find.text('route /store-view'), findsOneWidget);

      // A link while the app is running opens straight away.
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage('test/links',
              const StandardMethodCodec().encodeMethodCall(
                  const MethodCall('onLink', 'https://broka.co.ke/store/clanix/p/l1')),
              (_) {});
      await tester.pumpAndSettle();
      expect(seen.last.name, '/product');
      expect(seen.last.arguments, {'listingId': 'l1'});

      // The web's Store details page opens the store with its details on
      // top. It was an unknown /store/ link: the app opened, showing nothing.
      expect(links.handle('https://broka.co.ke/store/clanix/about'), isTrue);
      await tester.pumpAndSettle();
      expect(seen.last.name, '/store-view');
      expect(seen.last.arguments, {'slug': 'clanix', 'via': null, 'view': 'details'});

      expect(links.handle('https://broka.co.ke/store/clanix/cart?items=l1:3'), isTrue);
      await tester.pumpAndSettle();
      expect(seen.last.arguments,
          {'slug': 'clanix', 'via': null, 'view': 'cart', 'items': {'l1': 3}});

      // Links that aren't BROKA store links are ignored.
      expect(links.handle('https://example.com/store/x'), isFalse);
    });

    testWidgets('an incoming call wins over a held link', (tester) async {
      final key = GlobalKey<NavigatorState>();
      final seen = <String?>[];
      await tester.pumpWidget(MaterialApp(
        navigatorKey: key,
        home: const SizedBox(),
        onGenerateRoute: (s) {
          seen.add(s.name);
          return MaterialPageRoute(settings: s, builder: (_) => const SizedBox());
        },
      ));
      const channel = MethodChannel('test/none');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async => null);
      final links = DeepLinkService(channel: channel);
      await links.init(key);
      links.handle('https://broka.co.ke/store/clanix');
      links.appReady(openPending: false);
      await tester.pumpAndSettle();
      expect(seen, isEmpty);
      expect(links.pending, isNull);
    });
  });
}
