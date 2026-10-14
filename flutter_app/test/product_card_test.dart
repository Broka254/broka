// ProductCard after the visual upgrade (2026-09-29): the FEATURED badge a
// boost buys, the store folded into the seller's row, the price as one piece
// of text, the round View Deal arrow, the press feedback, and no overflow in
// the tile ProductGridView sizes for it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:broka/features/listings/domain/models/listing.dart';
import 'package:broka/widgets/product_card.dart';
import 'package:broka/widgets/product_grid_view.dart';

import 'support/fake_api.dart';

BrokaListing _listing(int i, [Map<String, dynamic> extra = const {}]) =>
    BrokaListing.fromJson({...fakeListingJson(i), ...extra});

/// The backend's timestamp shape: naive UTC, no "Z".
String _naiveUtc(DateTime t) => t.toUtc().toIso8601String().replaceAll('Z', '');

const _store = {'store_id': 's1', 'store_name': 'Clanix Electronics', 'store_slug': 'clanix'};

Widget _host(Widget child, {bool reduceMotion = false}) => MaterialApp(
      builder: (context, app) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
        child: app!,
      ),
      home: Scaffold(body: Center(child: child)),
    );

Widget _card(BrokaListing listing,
        {VoidCallback? onTap, void Function(String, String)? onViewStore}) =>
    SizedBox(
      width: 180,
      height: 320,
      child: ProductCard(item: listing, onTap: onTap, onViewStore: onViewStore),
    );

Finder _photoOf(Finder card) =>
    find.descendant(of: card, matching: find.byType(Stack)).first;

void main() {
  group('FEATURED badge', () {
    testWidgets('shows while the boost is running', (tester) async {
      await tester.pumpWidget(_host(_card(_listing(1, {
        'is_featured': true,
        'featured_until': _naiveUtc(DateTime.now().add(const Duration(days: 3))),
      }))));
      expect(find.text('FEATURED'), findsOneWidget);
    });

    testWidgets("not once it has run out, nor on a listing that wasn't boosted",
        (tester) async {
      // The same rule Home pins featured listings by: a flag with no end
      // date, or an end date in the past, is not a live boost.
      for (final extra in [
        {'is_featured': true, 'featured_until': _naiveUtc(DateTime.now().subtract(const Duration(hours: 1)))},
        {'is_featured': true, 'featured_until': null},
        {'is_featured': false, 'featured_until': _naiveUtc(DateTime.now().add(const Duration(days: 3)))},
      ]) {
        await tester.pumpWidget(_host(_card(_listing(1, extra))));
        expect(find.text('FEATURED'), findsNothing, reason: '$extra');
      }
    });
  });

  group('store', () {
    testWidgets("a store listing's photo is as tall as its neighbour's", (tester) async {
      await tester.pumpWidget(_host(Row(mainAxisSize: MainAxisSize.min, children: [
        _card(_listing(1)),
        _card(_listing(2, _store)),
      ])));
      final plain = find.byType(ProductCard).at(0);
      final inStore = find.byType(ProductCard).at(1);
      expect(tester.getSize(_photoOf(inStore)).height,
          tester.getSize(_photoOf(plain)).height,
          reason: 'the store is on the seller row, not a line of its own');
      // On the seller's row: level with the seller's avatar.
      expect(tester.getCenter(find.text('Clanix Electronics')).dy,
          closeTo(tester.getCenter(find.descendant(of: inStore, matching: find.byType(CircleAvatar))).dy, 1));
    });

    testWidgets("tapping the store's name opens the store, not the deal", (tester) async {
      final opened = <String>[];
      var deals = 0;
      await tester.pumpWidget(_host(_card(_listing(1, _store),
          onTap: () => deals++, onViewStore: (id, slug) => opened.add('$id/$slug'))));
      await tester.tap(find.text('Clanix Electronics'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(opened, ['s1/clanix']);
      expect(deals, 0);
    });
  });

  testWidgets('the price is one piece of text, unit and all', (tester) async {
    await tester.pumpWidget(_host(_card(_listing(1, {'price': 3500, 'price_unit': 'bag'}))));
    expect(find.text('KES 3,500 / bag'), findsOneWidget);
  });

  testWidgets('the arrow opens the deal', (tester) async {
    var deals = 0;
    await tester.pumpWidget(_host(_card(_listing(1), onTap: () => deals++)));
    expect(find.bySemanticsLabel('View deal'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.arrow_forward_rounded));
    await tester.pump(const Duration(milliseconds: 300));
    expect(deals, 1);
  });

  group('press feedback', () {
    double scale(WidgetTester tester) => tester
        .widget<AnimatedScale>(find.descendant(
            of: find.byType(ProductCard), matching: find.byType(AnimatedScale)))
        .scale;

    testWidgets('the card sinks under a finger and comes back', (tester) async {
      var deals = 0;
      await tester.pumpWidget(_host(_card(_listing(1), onTap: () => deals++)));
      final press = await tester.startGesture(tester.getCenter(_photoOf(find.byType(ProductCard))));
      await tester.pump(const Duration(milliseconds: 150));
      expect(scale(tester), lessThan(1.0));
      await press.up();
      await tester.pump(const Duration(milliseconds: 300));
      expect(scale(tester), 1.0);
      expect(deals, 1);
    });

    testWidgets('nothing moves under reduced motion', (tester) async {
      await tester.pumpWidget(_host(_card(_listing(1), onTap: () {}), reduceMotion: true));
      final press = await tester.startGesture(tester.getCenter(_photoOf(find.byType(ProductCard))));
      await tester.pump(const Duration(milliseconds: 150));
      expect(scale(tester), 1.0);
      await press.up();
    });
  });

  testWidgets('everything at once fits the tile the grid sizes, on a small '
      'phone at a large text size', (tester) async {
    // The most a card carries: a live boost, a condition, a plot size, a
    // store, a two-line title, a seven-digit price per unit and a long place.
    final crowded = [
      for (int i = 0; i < 6; i++)
        _listing(i, {
          ..._store,
          'name': 'Prime quarter acre plot with ready title deed near the tarmac road',
          'category': 'Land',
          'condition': 'used',
          'attributes': {'land_size': '0.25', 'land_size_unit': 'acres'},
          'price': 1450000,
          'price_unit': 'plot',
          'location_name': 'Kamulu, Nairobi-Machakos border, Kenya',
          'is_featured': true,
          'featured_until': _naiveUtc(DateTime.now().add(const Duration(days: 3))),
          'seller_completed_deals': 0,
        }),
    ];
    for (final width in const [320.0, 430.0]) {
      for (final textScale in const [1.0, 1.35]) {
        tester.view.physicalSize = Size(width * 2, 900 * 2);
        tester.view.devicePixelRatio = 2;
        await tester.pumpWidget(MaterialApp(
          builder: (context, app) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(textScale)),
            child: app!,
          ),
          home: Scaffold(
            body: ProductGridView(
              key: ValueKey('$width/$textScale'),
              fetchPage: (page) async => page == 0 ? crowded : const [],
            ),
          ),
        ));
        await tester.pump();
        await tester.pump();
        expect(find.byType(ProductCard), findsWidgets);
        expect(find.text('FEATURED'), findsWidgets);
        expect(tester.takeException(), isNull, reason: '${width}dp at ${textScale}x');
      }
    }
    tester.view.reset();
  });
}
