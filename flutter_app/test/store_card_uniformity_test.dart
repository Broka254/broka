// One store card, every store list.
//
// The bug this guards: the directory moved to the wide, one-shop-per-row card
// while the category screen and Stores near you kept the tall picture-on-top
// card, so the same shop looked like a different shop depending on which list
// it was reached from. These tests read the card on all three screens and
// compare its shape: the card is wider than it is tall, the picture holds the
// left of the row, and the name sits beside it - never under it.
import 'dart:convert';

import 'package:broka/core/network/api_client.dart';
import 'package:broka/features/stores/data/repositories/stores_repository.dart';
import 'package:broka/features/stores/presentation/nearby_stores_screen.dart';
import 'package:broka/features/stores/presentation/store_category_screen.dart';
import 'package:broka/features/stores/presentation/store_list_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object? body) => http.Response(jsonEncode(body), 200,
    headers: {'content-type': 'application/json'});

Map<String, dynamic> _store(String id, String name) => {
      'id': id,
      'name': name,
      'slug': id,
      'category': 'Electronics',
      'categories': ['Electronics'],
      'county': 'Nairobi',
      'subcounty': 'Starehe',
      'listing_count': 3,
      'rating': 8.4,
      'review_count': 7,
    };

/// Both shops come back from every query, so whichever screen asks, it has a
/// shop to draw in its list.
ApiClient _client() => ApiClient(
      client: MockClient((request) async {
        if (request.url.path != '/stores') {
          return _json({'detail': 'no route'});
        }
        return _json([
          _store('a', 'Tokyo Electronics'),
          _store('b', 'Clanix'),
        ]);
      }),
    );

/// Neither screen's constellation animation ever settles, so pumpAndSettle
/// would only time out.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

Future<void> _pumpScreen(WidgetTester tester, Widget screen) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(home: screen));
  await _settle(tester);
}

/// The card's geometry, as every store list must draw it.
void _expectOneRowCard(WidgetTester tester, String label) {
  final card = find.byKey(const Key('store-card-a'));
  expect(card, findsWidgets, reason: 'no card on the $label screen');
  final rect = tester.getRect(card.first);
  final name = tester.getRect(find.text('Tokyo Electronics').first);
  expect(rect.width, greaterThan(rect.height),
      reason: 'the $label screen draws a tall card, not the shared one');
  expect(rect.left, closeTo(16, 0.5),
      reason: 'the $label screen does not sit on the list gutter');
  expect(name.left, greaterThan(rect.left + rect.width * 0.35),
      reason: 'the $label screen puts the name under the picture');
  expect(name.right, lessThanOrEqualTo(rect.right + 0.5));
  expect(tester.takeException(), isNull);
}

void main() {
  setUp(() {
    // Stores near you asks the device directly (no injected locator): give it
    // a fix, so the screen reaches its list instead of its location prompt.
    GeolocatorPlatform.instance = _FixedGeolocator();
  });

  testWidgets('the directory draws the one-row card', (tester) async {
    await _pumpScreen(
      tester,
      StoreListScreen(
        repository: StoresRepository(client: _client()),
        animateBackground: false,
      ),
    );
    _expectOneRowCard(tester, 'directory');
  });

  testWidgets("a category's own screen draws the same card", (tester) async {
    await _pumpScreen(
      tester,
      StoreCategoryScreen(
        categoryName: 'Electronics',
        repository: StoresRepository(client: _client()),
        // No fix: the nearby rail stays empty, so the list's own card is what
        // the screen is read for.
        locate: () async => null,
        animateBackground: false,
      ),
    );
    _expectOneRowCard(tester, 'category');
  });

  testWidgets('Stores near you draws the same card', (tester) async {
    await _pumpScreen(
      tester,
      NearbyStoresScreen(repository: StoresRepository(client: _client())),
    );
    _expectOneRowCard(tester, 'nearby');
  });

  testWidgets('the same shop is the same card on every screen',
      (tester) async {
    final heights = <String, double>{};

    await _pumpScreen(
      tester,
      StoreListScreen(
        repository: StoresRepository(client: _client()),
        animateBackground: false,
      ),
    );
    heights['directory'] =
        tester.getRect(find.byKey(const Key('store-card-a')).first).height;

    await _pumpScreen(
      tester,
      StoreCategoryScreen(
        categoryName: 'Electronics',
        repository: StoresRepository(client: _client()),
        locate: () async => null,
        animateBackground: false,
      ),
    );
    heights['category'] =
        tester.getRect(find.byKey(const Key('store-card-a')).first).height;

    await _pumpScreen(
      tester,
      NearbyStoresScreen(repository: StoresRepository(client: _client())),
    );
    heights['nearby'] =
        tester.getRect(find.byKey(const Key('store-card-a')).first).height;

    // Same shop, same facts, same width available: one height across all
    // three (within a sub-pixel, since the slivers round independently). A
    // screen that restyled the card would drift here first.
    final directory = heights['directory']!;
    expect(heights['category'], closeTo(directory, 0.5),
        reason: 'the card differs between screens: $heights');
    expect(heights['nearby'], closeTo(directory, 0.5),
        reason: 'the card differs between screens: $heights');
  });
}

/// A device that is standing in Nairobi, with permission granted.
class _FixedGeolocator extends GeolocatorPlatform {
  @override
  Future<bool> isLocationServiceEnabled() async => true;

  @override
  Future<LocationPermission> checkPermission() async =>
      LocationPermission.whileInUse;

  @override
  Future<LocationPermission> requestPermission() async =>
      LocationPermission.whileInUse;

  @override
  Future<Position> getCurrentPosition({LocationSettings? locationSettings}) async =>
      Position(
        latitude: -1.286,
        longitude: 36.817,
        timestamp: DateTime(2026, 10, 22),
        accuracy: 5,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: 0,
        headingAccuracy: 0,
        speed: 0,
        speedAccuracy: 0,
      );
}
