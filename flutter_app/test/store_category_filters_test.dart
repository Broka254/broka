// A category screen narrows the way the directory does (2026-10-22).
//
// Image 2's Electronics screen listed every electronics shop with no way to
// ask for "in Nairobi" or "within 5 km"; the directory above it had both.
// These tests pin the three things that make the row real: county and area
// reach the query, the distance control offers the presets plus a typed
// radius, and the nearby rail steps aside while a filter is on.
import 'dart:convert';

import 'package:broka/core/network/api_client.dart';
import 'package:broka/features/stores/data/repositories/stores_repository.dart';
import 'package:broka/features/stores/presentation/store_category_screen.dart';
import 'package:broka/features/stores/presentation/widgets/store_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object? body) => http.Response(jsonEncode(body), 200,
    headers: {'content-type': 'application/json'});

Map<String, dynamic> _store(String id, String name, {double? distanceKm}) => {
      'id': id,
      'name': name,
      'slug': id,
      'category': 'Electronics',
      'categories': ['Electronics'],
      'county': 'Nairobi',
      'subcounty': 'Starehe',
      'listing_count': 2,
      'rating': 8.0,
      'review_count': 3,
      if (distanceKm != null) 'distance_km': distanceKm,
      if (distanceKm != null)
        'distance_label': '${distanceKm.toStringAsFixed(0)} km from you',
    };

ApiClient _client(List<http.Request> requests) => ApiClient(
      client: MockClient((req) async {
        requests.add(req);
        if (req.url.path != '/stores') return _json({'detail': 'no route'});
        final q = req.url.queryParameters;
        var shops = [
          _store('near-1', 'Near Shop', distanceKm: 2),
          _store('far-1', 'Far Shop', distanceKm: 40),
        ];
        if (q.containsKey('max_distance_km')) {
          final max = double.parse(q['max_distance_km']!);
          shops = shops
              .where((s) => (s['distance_km'] as num) <= max)
              .toList();
        }
        if (q.containsKey('county')) {
          shops = shops.where((s) => s['county'] == q['county']).toList();
        }
        return _json(shops);
      }),
    );

Future<void> _pump(WidgetTester tester, StoresRepository repository) async {
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: StoreCategoryScreen(
      categoryName: 'Electronics',
      repository: repository,
      locate: () async => (lat: -1.286, lng: 36.817),
      animateBackground: false,
    ),
  ));
  // The list, then the location probe's second load.
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(seconds: 1));
  await tester.pumpAndSettle(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('the category screen filters by county', (tester) async {
    final requests = <http.Request>[];
    await _pump(tester, StoresRepository(client: _client(requests)));

    await tester.tap(find.byKey(const Key('store-filter-county')));
    await tester.pumpAndSettle();
    // The picker's own search, not the screen's: Nairobi is 20-odd counties
    // down the list, so it is typed for rather than scrolled to.
    await tester.enterText(find.byType(TextField).last, 'Nairobi');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nairobi').last);
    await tester.pumpAndSettle();

    expect(requests.last.url.queryParameters['county'], 'Nairobi');
    expect(requests.last.url.queryParameters['category'], 'Electronics');
    // A shop filtered away is not drawn, and neither is the nearby rail
    // above a narrowed list.
    expect(find.byType(StoreCard), findsWidgets);
    expect(find.text('Stores near you'), findsNothing);
  });

  testWidgets('a preset radius cuts the list and says which radius is on',
      (tester) async {
    final requests = <http.Request>[];
    await _pump(tester, StoresRepository(client: _client(requests)));
    expect(find.byKey(const Key('store-filter-distance')), findsOneWidget);

    await tester.tap(find.byKey(const Key('store-filter-distance')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('distance-10')));
    await tester.pumpAndSettle();

    expect(requests.last.url.queryParameters['max_distance_km'], '10.0');
    // The 40 km shop is gone; the 2 km shop is not.
    expect(find.text('Near Shop'), findsWidgets);
    expect(find.text('Far Shop'), findsNothing);
    expect(
        find.descendant(
            of: find.byKey(const Key('store-filter-distance')),
            matching: find.text('Within 10 km')),
        findsOneWidget,
        reason: 'the chip must show the radius that is actually applied');
  });

  testWidgets('a typed radius filters at exactly that many kilometres',
      (tester) async {
    final requests = <http.Request>[];
    await _pump(tester, StoresRepository(client: _client(requests)));

    await tester.tap(find.byKey(const Key('store-filter-distance')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('distance-custom')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('distance-custom-field')), '5');
    await tester.tap(find.byKey(const Key('distance-custom-apply')));
    await tester.pumpAndSettle();

    expect(requests.last.url.queryParameters['max_distance_km'], '5.0');
    expect(
        find.descendant(
            of: find.byKey(const Key('store-filter-distance')),
            matching: find.text('Within 5 km')),
        findsOneWidget);
    expect(find.text('Far Shop'), findsNothing);
  });

  testWidgets('any distance clears the radius and the rail comes back',
      (tester) async {
    final requests = <http.Request>[];
    await _pump(tester, StoresRepository(client: _client(requests)));

    await tester.tap(find.byKey(const Key('store-filter-distance')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('distance-25')));
    await tester.pumpAndSettle();
    expect(requests.last.url.queryParameters.containsKey('max_distance_km'),
        isTrue);

    await tester.tap(find.byKey(const Key('store-filter-distance')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('distance-any')));
    await tester.pumpAndSettle();
    expect(requests.last.url.queryParameters.containsKey('max_distance_km'),
        isFalse);
    expect(find.text('Stores near you'), findsWidgets);
  });
}
