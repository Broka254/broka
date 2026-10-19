// The store directory must show each shop once.
//
// The bug this guards: the screen fetches two lists - 'Stores near you'
// (within 25 km) and 'All stores' (everything) - and nothing removed the
// nearby ids from the main list, so every shop inside 25 km was drawn
// twice on one screen. Same structure in the category screen.
import 'dart:convert';

import 'package:broka/core/network/api_client.dart';
import 'package:broka/features/stores/data/repositories/stores_repository.dart';
import 'package:broka/features/stores/presentation/store_category_screen.dart';
import 'package:broka/features/stores/presentation/store_list_screen.dart';
import 'package:broka/features/stores/presentation/widgets/store_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object? body, [int status = 200]) =>
    http.Response(jsonEncode(body), status,
        headers: {'content-type': 'application/json'});

Map<String, dynamic> _store(String id, String name, {double? distanceKm}) => {
      'id': id,
      'name': name,
      'slug': id,
      'category': 'Electronics',
      'categories': ['Electronics'],
      'county': 'Nairobi',
      'listing_count': 2,
      if (distanceKm != null) 'distance_km': distanceKm,
      if (distanceKm != null)
        'distance_label': '${distanceKm.toStringAsFixed(0)} km from you',
      'rating': 8.0,
      'review_count': 3,
    };

/// A backend where the same two shops are both within 25 km AND in the
/// full directory - exactly the situation that produced the duplicate.
ApiClient _client({List<http.Request>? requests}) => ApiClient(
      client: MockClient((req) async {
        requests?.add(req);
        if (req.url.path != '/stores')
          return _json({'detail': 'no route'}, 404);
        final q = req.url.queryParameters;
        final nearby = q.containsKey('max_distance_km');
        final shops = [
          _store('near-1', 'Near Shop', distanceKm: 2),
          _store('near-2', 'Second Near Shop', distanceKm: 5),
          _store('far-1', 'Far Shop', distanceKm: nearby ? null : 60),
        ];
        if (nearby)
          return _json(shops.where((s) => s['distance_km'] != null).toList());
        return _json(shops);
      }),
    );

void main() {
  setUp(() {});

  testWidgets('a nearby shop appears once, not in both lists', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: StoreListScreen(
        repository: StoresRepository(client: _client()),
        // A real fix, so the 'near you' rail actually loads. Without it the
        // rail never exists and the duplicate this test guards cannot occur.
        locate: () async => (lat: -1.286, lng: 36.817),
        animateBackground: false,
      ),
    ));
    // Let the directory load and the location probe settle.
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    // One card per shop on the whole screen. The regression drew the two
    // nearby shops twice each, so this was 5 cards for 3 shops.
    final cards = find.byType(StoreCard);
    final names = <String>[];
    for (final element in cards.evaluate()) {
      names.add((element.widget as StoreCard).store.name);
    }
    expect(names.toSet().length, names.length,
        reason: 'a shop was drawn twice: $names');
  });

  testWidgets(
      'a search hides the nearby rail so the results are not contradicted',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: StoreListScreen(
        repository: StoresRepository(client: _client()),
        locate: () async => (lat: -1.286, lng: 36.817),
        animateBackground: false,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    // With no filter, the rail is allowed to exist.
    final railBefore = find.text('Nearby stores').evaluate().length;

    await tester.enterText(find.byType(TextField).first, 'far');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    // While filtering, no unfiltered shelf sits above the results.
    expect(find.text('Nearby stores'), findsNothing);
    expect(railBefore, greaterThanOrEqualTo(1),
        reason: 'the rail should have been visible before typing');
  });

  testWidgets('the category screen does not repeat a nearby shop either',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      home: StoreCategoryScreen(
        categoryName: 'Electronics',
        repository: StoresRepository(client: _client()),
        locate: () async => (lat: -1.286, lng: 36.817),
        animateBackground: false,
      ),
    ));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    final names = <String>[];
    for (final element in find.byType(StoreCard).evaluate()) {
      names.add((element.widget as StoreCard).store.name);
    }
    expect(names.toSet().length, names.length,
        reason: 'a shop was drawn twice: $names');
  });
}
