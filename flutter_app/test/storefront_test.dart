// Online Stores phase 3 in the app: the storefront screen, and store links
// opening it.
import 'dart:convert';

import 'package:broka/core/network/api_client.dart';
import 'package:broka/features/stores/data/repositories/stores_repository.dart';
import 'package:broka/features/stores/presentation/store_home_screen.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/services/deep_link_service.dart';
import 'package:broka/widgets/constellation_background.dart';
import 'package:broka/widgets/product_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _json(Object? body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

Map<String, dynamic> _store({bool active = true, String? description}) => {
      'id': 's1',
      'name': 'Clanix Electronics',
      'slug': 'clanix',
      'url': 'https://broka.co.ke/store/clanix',
      'category': 'Electronics',
      'description': description,
      'county': 'Nairobi',
      'subcounty': 'Starehe',
      'owner': {'verified': true, 'rating': 4.8, 'completed_deals': 12,
          'member_since': '2025-01-10T00:00:00'},
      'is_active': active,
      'listing_count': 3,
      'photos': [],
      'photo_images': [],
    };

Map<String, dynamic> _listing(String id, String name, double price, String category) => {
      'id': id, 'seller_id': 'u1', 'name': name, 'category': category, 'price': price,
      'lat': 0, 'lng': 0, 'status': 'active', 'listing_type': 'direct',
      'store_id': 's1', 'store_name': 'Clanix Electronics', 'store_slug': 'clanix',
    };

class _Backend {
  _Backend({bool active = true, String? description, int? failListingsTimes}) {
    _failListings = failListingsTimes ?? 0;
    client = ApiClient(client: MockClient((req) async {
      requests.add(req);
      final path = req.url.path;
      if (path == '/stores/s1' || path == '/stores/slug/clanix') {
        return _json(_store(active: active, description: description));
      }
      if (path == '/stores/slug/nope') return _json({'detail': 'Store not found'}, 404);
      if (path == '/stores/mine') return _json(null);
      if (path == '/stores/s1/categories') {
        return _json([{'name': 'Electronics', 'count': 2}, {'name': 'Gaming', 'count': 1}]);
      }
      if (path == '/stores/s1/visit') return _json({'counted': true}, 202);
      if (path == '/stores/s1/listings') {
        if (_failListings > 0) {
          _failListings--;
          return _json({'detail': 'Server busy'}, 503);
        }
        final q = req.url.queryParameters;
        var items = [
          _listing('l1', 'Samsung A15', 18000, 'Electronics'),
          _listing('l2', 'Tecno Spark', 12000, 'Electronics'),
          _listing('l3', 'PS5 Controller', 9000, 'Gaming'),
        ];
        if (q['category'] != null) items = items.where((l) => l['category'] == q['category']).toList();
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
  tester.view.physicalSize = const Size(1080, 2400);
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
  });

  group('StoreHomeScreen', () {
    testWidgets('shows the store, its categories and products, and counts the visit',
        (tester) async {
      final backend = _Backend(description: 'Genuine phones and accessories.');
      await _pumpStore(tester, backend, via: 'whatsapp');

      expect(find.byType(ConstellationBackground), findsOneWidget);
      expect(find.text('Clanix Electronics'), findsWidgets);
      expect(find.text('Electronics · Starehe, Nairobi'), findsOneWidget);
      expect(find.text('Verified seller'), findsOneWidget);
      expect(find.text('12 deals done'), findsOneWidget);
      expect(find.text('4.8'), findsOneWidget);
      expect(find.text('Genuine phones and accessories.'), findsOneWidget);
      expect(find.byKey(const Key('category-pill-all')), findsOneWidget);
      expect(find.byKey(const Key('category-pill-Gaming')), findsOneWidget);
      expect(find.byType(ProductCard), findsNWidgets(3));

      final visit = backend.requests.singleWhere((r) => r.url.path == '/stores/s1/visit');
      expect(jsonDecode(visit.body), {'via': 'whatsapp'});
    });

    testWidgets('category, search and sort filter the catalogue', (tester) async {
      final backend = _Backend();
      await _pumpStore(tester, backend);

      await tester.tap(find.byKey(const Key('category-pill-Gaming')));
      await tester.pumpAndSettle();
      expect(find.byType(ProductCard), findsOneWidget);
      expect(backend.listingQueries().last['category'], 'Gaming');

      await tester.tap(find.byKey(const Key('category-pill-all')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('store-search')), 'tecno');
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pumpAndSettle();
      expect(find.byType(ProductCard), findsOneWidget);
      expect(backend.listingQueries().last['search'], 'tecno');
      expect(backend.listingQueries().last.containsKey('category'), isFalse);

      await tester.tap(find.byKey(const Key('store-sort')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Price: low to high'));
      await tester.pumpAndSettle();
      expect(backend.listingQueries().last['sort'], 'price_low');
    });

    testWidgets('opens from a link name', (tester) async {
      final backend = _Backend();
      await _pumpStore(tester, backend, storeId: null, slug: 'clanix');
      expect(find.byType(ProductCard), findsNWidgets(3));
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
      expect(find.byType(ProductCard), findsNothing);
      expect(find.text('Nothing listed yet'), findsNothing);
      final retry = find.textContaining(RegExp('retry', caseSensitive: false));
      expect(retry, findsWidgets);
      await tester.tap(retry.first);
      await tester.pumpAndSettle();
      expect(find.byType(ProductCard), findsNWidgets(3));
    });

    for (final size in const [Size(320, 568), Size(430, 932)]) {
      testWidgets('nothing overflows at ${size.width.toInt()}dp', (tester) async {
        tester.view.physicalSize = size * 3;
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);
        final backend = _Backend(description: 'A long description ' * 20);
        await tester.pumpWidget(MaterialApp(home: StoreHomeScreen(
            storeId: 's1', repository: backend.repo, animateBackground: false)));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -600));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('Store links', () {
    test('which links are store links', () {
      expect(StoreLinkTarget.parse('https://broka.co.ke/store/clanix'),
          const StoreLinkTarget(slug: 'clanix'));
      expect(StoreLinkTarget.parse('https://www.broka.co.ke/store/Clanix/?via=tiktok'),
          const StoreLinkTarget(slug: 'clanix', via: 'tiktok'));
      expect(StoreLinkTarget.parse('https://broka.co.ke/store/clanix/p/abc-123?via=qr'),
          const StoreLinkTarget(slug: 'clanix', listingId: 'abc-123', via: 'qr'));
      for (final bad in [
        null, '', 'http://broka.co.ke/store/clanix', 'https://evil.com/store/clanix',
        'https://broka.co.ke/', 'https://broka.co.ke/store/', 'https://broka.co.ke/stores/x',
        'https://broka.co.ke/store/bad_name', 'https://broka.co.ke/store/x/p/',
        'https://broka.co.ke/store/clanix/q/1',
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
