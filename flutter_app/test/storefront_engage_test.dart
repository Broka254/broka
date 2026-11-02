// The storefront's second act: talking to the shop and following it,
// browsing by type of item, and the catalogue card's save heart and
// stock line.
//
// Covers what storefront_test.dart's first act doesn't:
//   1. Message Store opens a direct chat about the picked product;
//   2. Follow follows and unfollows, moving the count;
//   3. Shop by Category shows types of item with their pictures, and
//      filters the catalogue by them;
//   4. the Featured rail shows featured products and See all drops to
//      the catalogue;
//   5. the save heart saves and unsaves through the listing's own save;
//   6. the stock line reads the shelf: in stock, nearly out, sold out.
import 'dart:convert';

import 'package:broka/core/network/api_client.dart';
import 'package:broka/features/listings/data/repositories/listings_repository.dart';
import 'package:broka/features/stores/data/repositories/stores_repository.dart';
import 'package:broka/features/stores/data/store_cart.dart';
import 'package:broka/features/stores/presentation/store_home_screen.dart';
import 'package:broka/features/stores/presentation/widgets/store_product_card.dart';
import 'package:broka/services/api_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _json(Object? body, [int status = 200]) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json'});

Map<String, dynamic> _listing(String id, String name, double price,
        String category,
        {int? quantity, bool featured = false}) =>
    {
      'id': id,
      'seller_id': 'u1',
      'name': name,
      'category': category,
      'price': price,
      'quantity': quantity,
      'is_featured': featured,
      'lat': 0,
      'lng': 0,
      'status': 'active',
      'listing_type': 'direct',
      'store_id': 's1',
      'store_name': 'Clanix Electronics',
      'store_slug': 'clanix',
    };

Map<String, dynamic> _store({int followers = 0, bool following = false}) => {
      'id': 's1',
      'name': 'Clanix Electronics',
      'slug': 'clanix',
      'url': 'https://broka.co.ke/store/clanix',
      'category': 'Electronics',
      'categories': ['Electronics'],
      'county': 'Nairobi',
      'subcounty': 'Starehe',
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
      'listing_count': 4,
      'follower_count': followers,
      'viewer_following': following,
      'cover': null,
      'photos': [],
      'photo_images': [],
      'created_at': '2026-09-02T08:00:00',
    };

class _Backend {
  _Backend({int followers = 0, bool following = false})
      : _followers = followers,
        _following = following {
    client = ApiClient(client: MockClient((req) async {
      requests.add(req);
      final path = req.url.path;
      if (path == '/stores/s1') {
        return _json(
            _store(followers: _followers, following: _following));
      }
      if (path == '/stores/mine') return _json(null);
      if (path == '/stores/s1/categories') {
        return _json([
          {
            'name': 'Electronics',
            'count': 3,
            'subcategories': [
              {'id': 'sub-phones', 'name': 'Phones', 'count': 2},
              {'id': 'sub-networking', 'name': 'Networking', 'count': 1},
            ],
          },
          {'name': 'Gaming', 'count': 1, 'subcategories': []},
        ]);
      }
      if (path == '/stores/s1/visit') return _json({'counted': true}, 202);
      if (path == '/stores/s1/follow' && req.method == 'POST') {
        _following = true;
        _followers++;
        return _json({'following': true, 'follower_count': _followers});
      }
      if (path == '/stores/s1/follow' && req.method == 'DELETE') {
        _following = false;
        _followers--;
        return _json({'following': false, 'follower_count': _followers});
      }
      if (path == '/stores/s1/listings') {
        final q = req.url.queryParameters;
        var items = [
          _listing('l1', 'Samsung A15', 18000, 'Electronics',
              quantity: 5, featured: true),
          _listing('l2', 'Tecno Spark', 12000, 'Electronics', quantity: 2),
          _listing('l3', 'Router', 2800, 'Electronics', quantity: 0),
          _listing('l4', 'PS5 Controller', 9000, 'Gaming'),
        ];
        if (q['subcategory_id'] == 'sub-phones') {
          items = items.where((l) => l['id'] == 'l1' || l['id'] == 'l2').toList();
        } else if (q['subcategory_id'] == 'sub-networking') {
          items = items.where((l) => l['id'] == 'l3').toList();
        } else if (q['category'] != null) {
          items =
              items.where((l) => l['category'] == q['category']).toList();
        }
        if (q['search'] != null) {
          items = items
              .where((l) => (l['name'] as String)
                  .toLowerCase()
                  .contains(q['search']!.toLowerCase()))
              .toList();
        }
        if (q['offset'] != '0') items = [];
        return _json(items);
      }
      // The save heart's reads and writes.
      if (path.startsWith('/listings/') && path.endsWith('/engagement')) {
        return _json({'liked': false, 'saved': _saved.contains(_listingId(path))});
      }
      if (path.startsWith('/listings/') && path.endsWith('/save')) {
        final id = _listingId(path);
        if (req.method == 'POST') {
          _saved.add(id);
          return _json({'saved': true});
        }
        _saved.remove(id);
        return _json({'saved': false});
      }
      return _json({'detail': 'no route $path'}, 404);
    }));
    repo = StoresRepository(client: client);
    listings = ListingsRepository(client: client);
  }

  static String _listingId(String path) => path.split('/')[2];

  int _followers;
  bool _following;
  final _saved = <String>{};
  late final ApiClient client;
  late final StoresRepository repo;
  late final ListingsRepository listings;
  final List<http.Request> requests = [];
  List<Map<String, String>> listingQueries() => requests
      .where((r) => r.url.path == '/stores/s1/listings')
      .map((r) => r.url.queryParameters)
      .toList();
}

/// A tall phone, so the hero, the rails and the first catalogue rows are
/// all built without scrolling.
Future<void> _pumpStore(WidgetTester tester, _Backend backend,
    {List<NavigatorObserver>? observers}) async {
  tester.view.physicalSize = const Size(1080, 6000);
  tester.view.devicePixelRatio = 2.75;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    navigatorObservers: observers ?? const [],
    // The message flow pushes the direct chat; the test records where
    // it would have gone instead of opening a real thread.
    onGenerateRoute: (settings) => MaterialPageRoute(
      settings: settings,
      builder: (_) => settings.name == '/direct-chat'
          ? const Scaffold(body: Text('direct chat'))
          : StoreHomeScreen(
              storeId: 's1',
              repository: backend.repo,
              listings: backend.listings,
              animateBackground: false),
    ),
  ));
  await tester.pumpAndSettle();
}

Future<void> _signIn() async {
  SharedPreferences.setMockInitialValues(
      {'auth_token': 't', 'user_id': 'buyer-1'});
  await ApiService.loadSavedSession();
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ApiService.clearSession();
    StoreCart.resetAll();
  });
  tearDown(() => ApiService.clearSession());

  group('Message Store', () {
    testWidgets('a signed-out tap asks for an account first',
        (tester) async {
      await _pumpStore(tester, _Backend());
      await tester.tap(find.byKey(const Key('store-message-button')));
      await tester.pumpAndSettle();
      // The account sheet, not the product picker.
      expect(find.textContaining('Create a free account'), findsOneWidget);
      expect(find.text('Which product are you asking about?'), findsNothing);
    });

    testWidgets('picks a product, then opens its direct chat',
        (tester) async {
      await _signIn();
      final backend = _Backend();
      final pushed = <RouteSettings>[];
      final observer = _PushRecorder(pushed);
      await _pumpStore(tester, backend, observers: [observer]);
      await tester.tap(find.byKey(const Key('store-message-button')));
      await tester.pumpAndSettle();
      expect(
          find.text('Which product are you asking about?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('message-product-l2')));
      await tester.pumpAndSettle();
      final chat =
          pushed.where((r) => r.name == '/direct-chat').singleOrNull;
      expect(chat, isNotNull, reason: 'no direct chat was opened');
      expect(
          chat!.arguments, {'listingId': 'l2', 'role': 'buyer'});
    });
  });

  group('Follow', () {
    testWidgets('a signed-out tap asks for an account first',
        (tester) async {
      await _pumpStore(tester, _Backend());
      await tester.tap(find.byKey(const Key('store-follow-button')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Create a free account'), findsOneWidget);
      expect(
          find.text('Follow', findRichText: true), findsWidgets);
    });

    testWidgets('follows and unfollows, moving the count', (tester) async {
      await _signIn();
      await _pumpStore(tester, _Backend(followers: 7));
      expect(find.text('7 followers'), findsOneWidget);
      expect(find.text('Follow'), findsOneWidget);

      await tester.tap(find.byKey(const Key('store-follow-button')));
      await tester.pumpAndSettle();
      expect(find.text('Following'), findsOneWidget);
      expect(find.text('8 followers'), findsOneWidget);

      await tester.tap(find.byKey(const Key('store-follow-button')));
      await tester.pumpAndSettle();
      expect(find.text('Follow'), findsOneWidget);
      expect(find.text('7 followers'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a store nobody follows shows no follower count',
        (tester) async {
      await _signIn();
      await _pumpStore(tester, _Backend());
      expect(find.byKey(const Key('hero-followers')), findsNothing);
      expect(find.text('Follow'), findsOneWidget);
    });
  });

  group('Shop by Category', () {
    testWidgets('types of item tile the rail and filter the catalogue',
        (tester) async {
      final backend = _Backend();
      await _pumpStore(tester, backend);
      expect(find.text('Shop by Category'), findsOneWidget);
      // Two filed types plus the unfiled category's own tile.
      expect(find.byKey(const Key('store-subcategory-sub-phones')),
          findsOneWidget);
      expect(find.byKey(const Key('store-subcategory-sub-networking')),
          findsOneWidget);
      expect(find.byKey(const Key('category-pill-Gaming')), findsOneWidget);

      await tester.tap(find.byKey(const Key('store-subcategory-sub-phones')));
      await tester.pumpAndSettle();
      expect(backend.listingQueries().last['subcategory_id'], 'sub-phones');
      expect(backend.listingQueries().last.containsKey('category'), isFalse);
      expect(find.text('Samsung A15'), findsOneWidget);
      expect(find.text('Tecno Spark'), findsOneWidget);
      expect(find.text('Router'), findsNothing);

      // Tapping the selected tile again clears it.
      await tester.tap(find.byKey(const Key('store-subcategory-sub-phones')));
      await tester.pumpAndSettle();
      // Four catalogued, plus the featured phone railed above them.
      expect(find.byType(StoreProductCard), findsNWidgets(5));
      expect(tester.takeException(), isNull);
    });

    testWidgets('View all lists every shelf and filters from it',
        (tester) async {
      final backend = _Backend();
      await _pumpStore(tester, backend);
      await tester.tap(find.byKey(const Key('store-categories-view-all')));
      await tester.pumpAndSettle();
      expect(find.text('Shop by Category'), findsNWidgets(2));
      expect(find.text('All in Electronics'), findsOneWidget);
      expect(find.text('Phones'), findsWidgets);

      await tester.tap(find.byKey(const Key('store-subcategory-row-sub-networking')));
      await tester.pumpAndSettle();
      expect(backend.listingQueries().last['subcategory_id'], 'sub-networking');
      expect(find.text('Router'), findsOneWidget);
      expect(find.text('Samsung A15'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('Featured Products', () {
    testWidgets('the rail shows featured products; See all drops down',
        (tester) async {
      await _pumpStore(tester, _Backend());
      expect(find.text('🔥 Featured Products'), findsOneWidget);
      // The featured phone shows twice: once railed, once catalogued.
      expect(find.text('Samsung A15'), findsNWidgets(2));
      expect(find.text('Tecno Spark'), findsOneWidget);

      await tester.tap(find.byKey(const Key('store-featured-see-all')));
      await tester.pumpAndSettle();
      expect(find.text('All products'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('save heart and stock', () {
    testWidgets('the heart saves and unsaves through the listing save',
        (tester) async {
      await _signIn();
      final backend = _Backend();
      await _pumpStore(tester, backend);
      final heart = find.byKey(const Key('save-product-l1'));
      expect(heart, findsWidgets);

      await tester.tap(heart.first);
      await tester.pumpAndSettle();
      expect(backend._saved, contains('l1'));
      final saves = backend.requests.where((r) =>
          r.url.path == '/listings/l1/save' && r.method == 'POST');
      expect(saves, hasLength(1));

      await tester.tap(heart.first);
      await tester.pumpAndSettle();
      expect(backend._saved, isNot(contains('l1')));
      expect(tester.takeException(), isNull);
    });

    testWidgets('the stock line reads the shelf', (tester) async {
      await _pumpStore(tester, _Backend());
      // Five left: in stock. Two left: nearly out. Zero: sold out.
      // Nothing stated: in stock - the listing is buyable. The featured
      // phone is both railed and catalogued, so it reads twice.
      expect(find.text('In stock'), findsNWidgets(3));
      expect(find.text('Only 2 left'), findsOneWidget);
      expect(find.text('Sold out'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

/// Records the routes the app pushes, so a test can say where a tap
/// would have gone without opening the screen itself.
class _PushRecorder extends NavigatorObserver {
  _PushRecorder(this.pushed);
  final List<RouteSettings> pushed;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route.settings);
    super.didPush(route, previousRoute);
  }
}
