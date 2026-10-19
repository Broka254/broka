// The Stores directory is a compact, two-column catalogue. These tests pin
// the parts the wider shared card cannot cover: responsive columns, compact
// cards in both sections, and filters that actually reach the repository.
import 'dart:convert';

import 'package:broka/core/network/api_client.dart';
import 'package:broka/features/stores/data/repositories/stores_repository.dart';
import 'package:broka/features/stores/presentation/store_list_screen.dart';
import 'package:broka/features/stores/presentation/widgets/store_card.dart';
import 'package:broka/features/stores/presentation/nearby_stores_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object? body) => http.Response(jsonEncode(body), 200,
    headers: {'content-type': 'application/json'});

Map<String, dynamic> _store(String id, String name,
        {double? distanceKm, String category = 'Electronics'}) =>
    {
      'id': id,
      'name': name,
      'slug': id,
      'category': category,
      'categories': [category],
      'county': 'Nairobi',
      'subcounty': 'Starehe',
      'listing_count': 4,
      'rating': 8.4,
      'review_count': 12,
      if (distanceKm != null) 'distance_km': distanceKm,
      if (distanceKm != null) 'distance_label': '$distanceKm km from you',
    };

ApiClient _client(List<http.Request> requests, {bool nearby = true}) =>
    ApiClient(
      client: MockClient((request) async {
        requests.add(request);
        if (request.url.path != '/stores') {
          return _json({'detail': 'no route'});
        }
        final query = request.url.queryParameters;
        final shops = [
          _store('a', 'A very long store name that wraps cleanly',
              distanceKm: nearby ? 2.2 : null),
          _store('b', 'Second Store', distanceKm: nearby ? 4.8 : null),
          _store('c', 'Third Store',
              category: 'Fashion', distanceKm: nearby ? 18 : null),
        ];
        var shown = shops;
        if (query.containsKey('max_distance_km')) {
          shown = shown.where((s) => s['distance_km'] != null).toList();
        }
        if (query['category'] != null) {
          shown =
              shown.where((s) => s['category'] == query['category']).toList();
        }
        if (query['nearest_first'] == 'true') {
          shown = [...shown]..sort((a, b) => ((a['distance_km'] as num?) ?? 999)
              .compareTo((b['distance_km'] as num?) ?? 999));
        }
        return _json(shown);
      }),
    );

Future<void> _pump(
  WidgetTester tester, {
  required StoresRepository repository,
  required bool hasLocation,
  Size size = const Size(390, 844),
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  tester.view.physicalSize = Size(size.width * 3, size.height * 3);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: textScaler),
      child: child!,
    ),
    home: StoreListScreen(
      repository: repository,
      locate: hasLocation
          ? () async => (lat: -1.286, lng: 36.817)
          : () async => null,
      animateBackground: false,
    ),
  ));
  await tester.pumpAndSettle();
}

int _columns(WidgetTester tester, String gridKey) {
  final grid = tester.widget<SliverGrid>(find.byKey(Key(gridKey)));
  final delegate =
      grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
  return delegate.crossAxisCount;
}

void main() {
  testWidgets('phone directory uses two compact columns', (tester) async {
    await _pump(
      tester,
      repository: StoresRepository(client: _client([])),
      hasLocation: false,
    );

    expect(_columns(tester, 'all-store-grid'), 2);
    final cards = tester.widgetList<StoreCard>(find.byType(StoreCard));
    expect(cards, isNotEmpty);
    expect(cards.every((card) => card.compact), isTrue);

    await tester.ensureVisible(find.byKey(const Key('all-store-b')));
    await tester.pumpAndSettle();
    final first = tester.getTopLeft(find.byKey(const Key('all-store-a')));
    final second = tester.getTopLeft(find.byKey(const Key('all-store-b')));
    expect(first.dy, closeTo(second.dy, 0.5));
    expect(second.dx, greaterThan(first.dx));
  });

  testWidgets('narrow and large-text layouts fall back to one column',
      (tester) async {
    await _pump(
      tester,
      repository: StoresRepository(client: _client([])),
      hasLocation: false,
      size: const Size(320, 720),
    );
    expect(_columns(tester, 'all-store-grid'), 1);
    expect(tester.takeException(), isNull);

    await _pump(
      tester,
      repository: StoresRepository(client: _client([])),
      hasLocation: false,
      textScaler: const TextScaler.linear(2.0),
    );
    expect(_columns(tester, 'all-store-grid'), 1);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const Key('store-search-filter')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('store-filter-apply')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('nearby stores use the compact grid and See all has a real route',
      (tester) async {
    await _pump(
      tester,
      repository: StoresRepository(client: _client([])),
      hasLocation: true,
    );

    expect(find.byKey(const Key('nearby-store-grid')), findsOneWidget);
    expect(_columns(tester, 'nearby-store-grid'), 2);
    expect(find.byKey(const Key('nearby-see-all')), findsOneWidget);

    await tester.tap(find.byKey(const Key('nearby-see-all')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(NearbyStoresScreen), findsOneWidget);
  });

  testWidgets('category, radius and nearest controls reach the repository',
      (tester) async {
    final requests = <http.Request>[];
    await _pump(
      tester,
      repository: StoresRepository(client: _client(requests)),
      hasLocation: true,
    );
    expect(find.text('Nearby stores'), findsOneWidget);

    await tester.tap(find.byKey(const Key('store-search-filter')));
    await tester.pumpAndSettle();
    await tester
        .tap(find.byKey(const Key('store-filter-category-Electronics')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('store-filter-apply')));
    await tester.pumpAndSettle();
    expect(requests.last.url.queryParameters['category'], 'Electronics');
    expect(find.text('Nearby stores'), findsNothing,
        reason: 'a filtered catalogue must not sit under an unfiltered rail');

    await tester.tap(find.byKey(const Key('store-filter-distance')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Within 25 km'));
    await tester.pumpAndSettle();
    expect(requests.last.url.queryParameters['max_distance_km'], '25.0');

    await tester.tap(find.byKey(const Key('store-filter-clear')));
    await tester.pumpAndSettle();
    expect(requests.last.url.queryParameters.containsKey('max_distance_km'),
        isFalse);

    await tester.tap(find.byKey(const Key('store-sort-control')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('store-sort-nearest')));
    await tester.pumpAndSettle();
    expect(requests.last.url.queryParameters['nearest_first'], 'true');

    await tester.tap(find.byKey(const Key('store-search-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('store-filter-reset')));
    await tester.pumpAndSettle();
    final reset = requests.last.url.queryParameters;
    expect(reset.containsKey('category'), isFalse);
    expect(reset.containsKey('max_distance_km'), isFalse);
    expect(reset.containsKey('nearest_first'), isFalse);
  });
}
