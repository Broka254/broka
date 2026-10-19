// StoreCard: distance is prominent when known, the Map action shows
// only when wired, and the shop's approximate point parses for the map.
import 'package:broka/features/stores/domain/models/store.dart';
import 'package:broka/features/stores/presentation/widgets/store_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Store _store(
        {double? distanceKm,
        String? distanceLabel,
        bool distanceApproximate = false,
        double? approxLat,
        double? approxLng,
        double? rating,
        int reviewCount = 0,
        StoreOwnerFacts? owner}) =>
    Store(
      id: 's1',
      name: 'Tokyo Electronics',
      slug: 'tokyo',
      category: 'Electronics',
      categories: const ['Electronics'],
      county: 'Kiambu',
      subcounty: 'Ruiru',
      listingCount: 12,
      rating: rating,
      reviewCount: reviewCount,
      owner: owner,
      distanceKm: distanceKm,
      distanceLabel: distanceLabel,
      distanceApproximate: distanceApproximate,
      approxLat: approxLat,
      approxLng: approxLng,
      hasLocation: approxLat != null,
    );

Future<void> _pumpCompact(
  WidgetTester tester,
  Store store, {
  VoidCallback? onMap,
  VoidCallback? onDetails,
  VoidCallback? onTap,
}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  const width = 174.0;
  final height = StoreCard.compactExtentFor(width: width, textScale: 1);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          height: height,
          child: StoreCard(
            store: store,
            compact: true,
            onTap: onTap ?? () {},
            onMap: onMap,
            onDetails: onDetails,
          ),
        ),
      ),
    ),
  ));
  await tester.pump();
}

Future<void> _pump(WidgetTester tester, Store store,
    {VoidCallback? onMap}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: StoreCard(store: store, onTap: () {}, onMap: onMap),
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  testWidgets('a nearby shop wears its distance on the picture',
      (tester) async {
    await _pump(
        tester, _store(distanceKm: 0.8, distanceLabel: '800 m from you'));
    expect(find.byKey(const Key('store-card-distance')), findsOneWidget);
    expect(find.text('800 m from you'), findsWidgets);
  });

  testWidgets('no distance, no pill - unknown is never 0 km', (tester) async {
    await _pump(tester, _store());
    expect(find.byKey(const Key('store-card-distance')), findsNothing);
  });

  testWidgets('the Map action fires only when wired', (tester) async {
    var opened = 0;
    await _pump(tester, _store(approxLat: -1.29, approxLng: 36.82),
        onMap: () => opened++);
    await tester.ensureVisible(find.byKey(const Key('store-map-s1')));
    await tester.tap(find.byKey(const Key('store-map-s1')));
    expect(opened, 1);
  });

  testWidgets('a far shop still shows its distance - 42 km is worth knowing',
      (tester) async {
    await _pump(
        tester, _store(distanceKm: 42, distanceLabel: '42 km from you'));
    expect(find.byKey(const Key('store-card-distance')), findsOneWidget);
    expect(find.text('42 km from you'), findsWidgets);
  });

  testWidgets('no distance known, no distance text anywhere', (tester) async {
    await _pump(tester, _store());
    expect(find.textContaining('km'), findsNothing);
    expect(find.textContaining('from you'), findsNothing);
  });

  testWidgets('View on map sits in the chip row, not only at the foot',
      (tester) async {
    var opened = 0;
    await _pump(tester, _store(approxLat: -1.29, approxLng: 36.82),
        onMap: () => opened++);
    expect(find.text('View on map'), findsOneWidget);
    expect(find.text('Map'), findsNothing);
    await tester.tap(find.byKey(const Key('store-map-s1')));
    expect(opened, 1);
  });

  testWidgets('the seller record is gone from the directory card',
      (tester) async {
    await _pump(tester, _store(distanceKm: 3));
    expect(find.text('New seller'), findsNothing);
    expect(find.textContaining('deal'), findsNothing);
    expect(find.textContaining('done'), findsNothing);
  });

  testWidgets('compact cards omit unknown ratings and distances honestly',
      (tester) async {
    await _pumpCompact(tester, _store());
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('store-rating-s1')), findsNothing);
    expect(find.byKey(const Key('store-card-distance')), findsNothing);
    expect(find.textContaining('from you'), findsNothing);
    // Missing media falls back to BROKA's own mark rather than stretching or
    // leaving an empty slot.
    expect(find.byKey(const Key('store-default-logo')), findsOneWidget);
  });

  testWidgets(
      'compact cards show the 0-10 store rating but never a fake review count',
      (tester) async {
    await _pumpCompact(tester, _store(rating: 8.4, reviewCount: 0));
    expect(
        find.descendant(
            of: find.byKey(const Key('store-rating-s1')),
            matching: find.text('8.4')),
        findsOneWidget);
    expect(find.text('(0)'), findsNothing);
  });

  testWidgets('compact card actions keep separate callbacks', (tester) async {
    var visits = 0;
    var maps = 0;
    var details = 0;
    await _pumpCompact(
      tester,
      _store(distanceKm: 2.3, distanceLabel: '2.3 km from you'),
      onTap: () => visits++,
      onMap: () => maps++,
      onDetails: () => details++,
    );

    await tester.tap(find.byKey(const Key('visit-store-s1')));
    await tester.tap(find.byKey(const Key('store-map-s1')));
    await tester.tap(find.byKey(const Key('store-details-s1')));
    expect(visits, 1);
    expect(maps, 1);
    expect(details, 1);
  });

  test('approximate distances are marked, near and far', () {
    final near = _store(distanceKm: 3.2, distanceApproximate: true);
    expect(near.nearLabel, '≈ 3.2 km from you');
    final far = _store(distanceKm: 42, distanceApproximate: true);
    expect(far.nearLabel, isNull);
    expect(far.anyDistanceLabel, '≈ 42 km from you');
    // The server's own label (already marked) passes through untouched.
    final served = _store(
        distanceKm: 42,
        distanceLabel: '≈ 42 km from you',
        distanceApproximate: true);
    expect(served.anyDistanceLabel, '≈ 42 km from you');
  });

  test('distance_approximate parses from the payload', () {
    final store = Store.fromJson(const {
      'id': 's9',
      'name': 'Area Shop',
      'slug': 'area-shop',
      'distance_km': 5.0,
      'distance_label': '≈ 5.0 km from you',
      'distance_approximate': true,
    });
    expect(store.distanceApproximate, isTrue);
    expect(store.nearLabel, '≈ 5.0 km from you');
  });

  test('the mappable point prefers the approximate point', () {
    final store = _store(approxLat: -1.29, approxLng: 36.82);
    expect(store.mapPoint, (lat: -1.29, lng: 36.82));
    expect(_store().mapPoint, isNull);
  });
}
