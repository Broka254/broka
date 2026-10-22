// The Stores directory is a single-column list of wide cards - the picture
// on the left of each row, the facts beside it. These tests pin the parts
// the shared card's own tests cannot cover: one shop per row at every width,
// wide cards in both sections, and filters that actually reach the
// repository.
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

/// A card takes the row: the screen width minus the 16dp gutters. Two
/// columns would each be about half of this.
void _expectFullWidthCard(WidgetTester tester) {
  final screenWidth = tester.getSize(find.byType(StoreListScreen)).width;
  final card = tester.getRect(find.byKey(const Key('all-store-a')));
  expect(card.width, greaterThan(screenWidth * 0.85),
      reason: 'a grid card is about half the screen wide');
  expect(card.left, closeTo(16, 0.5));
}

void main() {
  testWidgets('the directory lists one wide shop per row', (tester) async {
    await _pump(
      tester,
      repository: StoresRepository(client: _client([])),
      hasLocation: false,
    );

    expect(find.byKey(const Key('all-store-list')), findsOneWidget);
    expect(tester.widgetList<StoreCard>(find.byType(StoreCard)), isNotEmpty);

    final first = tester.getRect(find.byKey(const Key('all-store-a')));
    _expectFullWidthCard(tester);
    // The next shop starts below it, at the same left edge - never beside
    // it, which is what the two-column grid did. Both fit the screen, so
    // this is read without scrolling, while the two rects share a viewport.
    final second = tester.getRect(find.byKey(const Key('all-store-b')));
    expect(second.top, greaterThan(first.top));
    expect(second.left, closeTo(first.left, 0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a 320dp phone still lays one shop per row', (tester) async {
    await _pump(
      tester,
      repository: StoresRepository(client: _client([])),
      hasLocation: false,
      size: const Size(320, 720),
    );
    _expectFullWidthCard(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('large system text keeps one shop per row and the filter sheet',
      (tester) async {
    await _pump(
      tester,
      repository: StoresRepository(client: _client([])),
      hasLocation: false,
      textScaler: const TextScaler.linear(2.0),
    );

    // The filter sheet still opens at this scale - checked before scrolling
    // away from the search row, whose sliver is dropped once it is far off
    // screen.
    await tester.tap(find.byKey(const Key('store-search-filter')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('store-filter-apply')), findsOneWidget);
    await tester.tap(find.byKey(const Key('store-filter-apply')));
    await tester.pumpAndSettle();

    _expectFullWidthCard(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('nearby stores use the wide list and See all has a real route',
      (tester) async {
    await _pump(
      tester,
      repository: StoresRepository(client: _client([])),
      hasLocation: true,
    );

    expect(find.byKey(const Key('nearby-store-list')), findsOneWidget);
    expect(find.byKey(const Key('nearby-see-all')), findsOneWidget);
    // The rail draws the same one-row card as the list below it, not a
    // narrower variant of its own.
    final screenWidth = tester.getSize(find.byType(StoreListScreen)).width;
    final nearbyCard = tester.getRect(find.byKey(const Key('store-card-a')).first);
    expect(nearbyCard.width, greaterThan(nearbyCard.height));
    expect(nearbyCard.width, greaterThan(screenWidth * 0.85));
    expect(nearbyCard.left, closeTo(16, 0.5));

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

  testWidgets('a typed distance is a filter like any preset', (tester) async {
    final requests = <http.Request>[];
    await _pump(
      tester,
      repository: StoresRepository(client: _client(requests)),
      hasLocation: true,
    );

    await tester.tap(find.byKey(const Key('store-search-filter')));
    await tester.pumpAndSettle();
    // The sheet holds the categories and the distances; on a phone the
    // custom chip sits below the fold.
    await tester.ensureVisible(find.byKey(const Key('store-filter-distance-custom')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('store-filter-distance-custom')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('distance-custom-field')), '7');
    await tester.tap(find.byKey(const Key('distance-custom-apply')));
    await tester.pumpAndSettle();
    // The chip names the radius that is on, not "Custom…" any more.
    expect(find.text('7 km'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('store-filter-apply')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('store-filter-apply')));
    await tester.pumpAndSettle();

    expect(requests.last.url.queryParameters['max_distance_km'], '7.0');
  });

  testWidgets('a distance outside the map is refused, not clamped',
      (tester) async {
    await _pump(
      tester,
      repository: StoresRepository(client: _client([])),
      hasLocation: true,
    );
    await tester.tap(find.byKey(const Key('store-search-filter')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('store-filter-distance-custom')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('store-filter-distance-custom')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('distance-custom-field')), '9999');
    await tester.tap(find.byKey(const Key('distance-custom-apply')));
    await tester.pumpAndSettle();

    // The dialog stays open and says what is allowed.
    expect(find.byKey(const Key('distance-custom-dialog')), findsOneWidget);
    expect(find.textContaining('between 0.5 and 2000 km'), findsOneWidget);
  });
}
