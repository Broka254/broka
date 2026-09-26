// Covers the Home collapsing-scroll architecture (2026-09-18 brief).
//
// The brief's own words: "The most important part of this task is NOT simply
// making Home look like the mockup. The actual scroll interaction must
// change." So these tests measure the interaction rather than the pixels -
// how tall the header is at rest and after a drag, where the first product
// card sits before and after, whether anything moved that shouldn't have
// (the bottom nav), and whether there is more than one vertical scrollable in
// the tree.
//
// Home talks to three endpoints on open (listings, categories, active buy
// agent request). Rather than stub the repositories - they are const globals,
// and swapping them would mean changing production code to suit a test - the
// whole HttpClient is faked below, which also means the cards under test are
// real ProductCards built from real BrokaListing.fromJson parsing, and the
// prices they show are the ones a user would see.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:broka/screens/home_screen.dart';
import 'package:broka/widgets/product_card.dart';
import 'package:broka/widgets/product_grid_view.dart';
import 'package:broka/widgets/zeno_avatar.dart';
import 'package:broka/features/listings/domain/models/listing.dart';
import 'package:broka/utils/price_format.dart';

import 'support/fake_api.dart';

void main() {
  setUpAll(installFakeApi);
  // These tests measure where the rail's pills sit; the rail's one-time
  // glide is home_rail_hint_test.dart's subject.
  setUpAll(() => HomeScreen.railHintEnabled = false);

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/shared_preferences'),
      (call) async => call.method == 'getAll' ? <String, Object>{} : null,
    );
  });

  // ── Price format (brief §5) ─────────────────────────────────────────────────

  group('price formatting', () {
    test('never abbreviates, always groups', () {
      expect(formatKes(250), 'KES 250');
      expect(formatKes(1300), 'KES 1,300');
      expect(formatKes(15000), 'KES 15,000');
      expect(formatKes(125000), 'KES 125,000');
      expect(formatKes(1500000), 'KES 1,500,000');
      expect(formatKes(5000000), 'KES 5,000,000');
      // The exact cases the brief forbids.
      for (final amount in [15000, 1500000, 125000]) {
        expect(formatKes(amount), isNot(contains('K ')));
        expect(formatKes(amount).endsWith('K'), isFalse);
        expect(formatKes(amount).endsWith('M'), isFalse);
      }
    });

    test('BrokaListing.priceFormatted goes through the same formatter', () {
      final listing = BrokaListing.fromJson(fakeListingJson(0, price: 15000));
      expect(listing.priceFormatted, 'KES 15,000');
    });

    test('sub-thousand and boundary amounts survive', () {
      expect(formatKes(0), 'KES 0');
      expect(formatKes(999), 'KES 999');
      expect(formatKes(1000), 'KES 1,000');
      expect(formatKes(999999), 'KES 999,999');
      // A price is a whole number of shillings on a card, not 1,300.4.
      expect(formatKes(1300.4), 'KES 1,300');
    });
  });

  // ── ProductGridView sliver mode (brief §3/§17) ──────────────────────────────

  group('ProductGridView sliver mode', () {
    testWidgets('renders inside a parent CustomScrollView and paginates',
        (tester) async {
      final pagesFetched = <int>[];
      await tester.pumpWidget(_slidingHost(
        fetchPage: (page) async {
          pagesFetched.add(page);
          return List.generate(20, (i) => BrokaListing.fromJson(
              fakeListingJson(page * 20 + i, price: 15000)));
        },
      ));
      await _settle(tester);

      expect(pagesFetched, [0]);
      expect(find.byType(ProductCard), findsWidgets);

      // Scrolling toward the end of page 0 must ask for page 1 - the change
      // from GridView to SliverGrid moved this trigger off the widget's own
      // ScrollController, so it is the thing most worth proving. Several
      // drags because one gesture only carries the viewport so far, and page
      // 0 is ten rows tall in this 800x600 window.
      for (int i = 0; i < 4 && !pagesFetched.contains(1); i++) {
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -2000));
        await _settle(tester);
      }
      expect(pagesFetched, contains(1));
    });

    testWidgets('the parent owns the only vertical scrollable', (tester) async {
      await tester.pumpWidget(_slidingHost(
        fetchPage: (page) async => List.generate(
            20, (i) => BrokaListing.fromJson(fakeListingJson(page * 20 + i))),
      ));
      await _settle(tester);
      expect(_verticalScrollableCount(tester), 1);
    });

    testWidgets('a controller refresh refetches from page 0', (tester) async {
      final controller = ProductGridController();
      final pagesFetched = <int>[];
      await tester.pumpWidget(_slidingHost(
        controller: controller,
        // A full page, so the look-ahead prefetch doesn't fire on its own
        // and muddy what this test is actually asserting.
        fetchPage: (page) async {
          pagesFetched.add(page);
          return List.generate(20, (i) => BrokaListing.fromJson(
              fakeListingJson(page * 20 + i)));
        },
      ));
      await _settle(tester);
      expect(pagesFetched, [0]);
      expect(controller.isAttached, isTrue);

      // This is what HomeScreen's RefreshIndicator calls. It has to start
      // again from page 0 and it has to complete, or pull-to-refresh spins
      // forever.
      await controller.refresh().timeout(const Duration(seconds: 5));
      await _settle(tester);
      expect(pagesFetched, [0, 0]);
    });

    testWidgets('an empty result still shows the caller empty state',
        (tester) async {
      await tester.pumpWidget(_slidingHost(
        fetchPage: (_) async => <BrokaListing>[],
        emptyStateBuilder: (_) => const Text('nothing here'),
      ));
      await _settle(tester);
      expect(find.text('nothing here'), findsOneWidget);
      expect(find.byType(ProductCard), findsNothing);
    });

    testWidgets('a failing fetch offers a retry that works', (tester) async {
      var shouldFail = true;
      await tester.pumpWidget(_slidingHost(
        fetchPage: (_) async {
          if (shouldFail) throw StateError('offline');
          return [BrokaListing.fromJson(fakeListingJson(0))];
        },
      ));
      await _settle(tester);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.byType(ProductCard), findsNothing);

      shouldFail = false;
      await tester.tap(find.text('Retry'));
      await _settle(tester);
      expect(find.byType(ProductCard), findsWidgets);
    });

    testWidgets('the controller survives the grid being remounted by a new key',
        (tester) async {
      // HomeScreen changes the grid's ValueKey whenever a filter changes or
      // the user comes back from a product screen, which remounts the whole
      // grid. If the controller did not re-attach across that remount,
      // pull-to-refresh would quietly stop working after the first visit to
      // a listing - and nothing on screen would say so.
      final controller = ProductGridController();
      final pagesFetched = <int>[];
      Future<List<dynamic>> fetch(int page) async {
        pagesFetched.add(page);
        return List.generate(20, (i) => BrokaListing.fromJson(
            fakeListingJson(page * 20 + i)));
      }

      Widget host(String key) => MaterialApp(
            home: Scaffold(
              body: CustomScrollView(slivers: [
                ProductGridView(
                  key: ValueKey(key),
                  sliver: true,
                  controller: controller,
                  fetchPage: fetch,
                ),
              ]),
            ),
          );

      await tester.pumpWidget(host('a'));
      await _settle(tester);
      expect(controller.isAttached, isTrue);

      await tester.pumpWidget(host('b'));
      await _settle(tester);
      expect(controller.isAttached, isTrue,
          reason: 'the new grid must own the controller after a remount');

      pagesFetched.clear();
      await controller.refresh().timeout(const Duration(seconds: 5));
      await _settle(tester);
      expect(pagesFetched, [0]);
    });

    testWidgets('a refresh that lands mid-fetch still refreshes',
        (tester) async {
      final controller = ProductGridController();
      final pagesFetched = <int>[];
      final gate = Completer<void>();
      await tester.pumpWidget(_slidingHost(
        controller: controller,
        fetchPage: (page) async {
          pagesFetched.add(page);
          if (page == 0 && !gate.isCompleted) await gate.future;
          return List.generate(20, (i) => BrokaListing.fromJson(
              fakeListingJson(page * 20 + i)));
        },
      ));
      await tester.pump();

      // Page 0 is still in flight here. A pull-to-refresh now must not be
      // swallowed by the "already loading" guard.
      final refresh = controller.refresh();
      gate.complete();
      await refresh.timeout(const Duration(seconds: 5));
      await _settle(tester);
      expect(pagesFetched, [0, 0]);
    });

    testWidgets('box mode is untouched: it still brings its own scrollable',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ProductGridView(
            fetchPage: (page) async => List.generate(
                20, (i) => BrokaListing.fromJson(fakeListingJson(page * 20 + i))),
          ),
        ),
      ));
      await _settle(tester);
      expect(find.byType(GridView), findsOneWidget);
      expect(find.byType(RefreshIndicator), findsOneWidget);
      expect(_verticalScrollableCount(tester), 1);
    });
  });

  // ── Home itself (brief §1/§2/§10/§11/§18/§19) ──────────────────────────────

  group('Home collapsing scroll', () {
    testWidgets('the acceptance walk: full header at rest, listings take over '
        'on scroll, header returns at the top', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
      await _settle(tester);

      // Steps 2-6: everything the brief wants visible at scroll position 0.
      expect(find.text('BROKA'), findsOneWidget);
      expect(find.textContaining('Good '), findsOneWidget);          // greeting
      expect(find.textContaining('Search listings'), findsOneWidget);
      expect(find.text(_firstCategory), findsOneWidget);              // rail
      expect(find.text('Fresh on Broka'), findsOneWidget);
      expect(find.byType(ProductCard), findsWidgets);
      // Step 19 + brief §11: the nav is outside the scroll view.
      expect(find.text('Inbox'), findsOneWidget);
      expect(find.text('Sell'), findsOneWidget);
      // The fifth tab is the Menu now (menu_screen.dart).
      expect(find.text('Menu'), findsOneWidget);

      // Step 29 + brief §3: ONE vertical scroll owner. The discovery rail is
      // horizontal and doesn't count; a second vertical one would mean the
      // grid brought its own controller back into this viewport.
      expect(_verticalScrollableCount(tester), 1);

      final headerAtRest = _headerHeight(tester);
      final navAtRest = tester.getRect(find.text('Home').last);
      final railAtRest = tester.getRect(find.text(_firstCategory));
      final firstCardAtRest = tester.getRect(find.byType(ProductCard).first);

      // Steps 7-9: a SLOW swipe up. Deliberately smaller than the header's
      // own collapse range, so this asserts gradual movement rather than a
      // header that snaps out of existence on the first gesture.
      await _scrollHome(tester, -70);

      expect(_headerHeight(tester), lessThan(headerAtRest),
          reason: 'the header must contract as the user scrolls');
      expect(tester.getRect(find.text(_firstCategory)).top,
          lessThan(railAtRest.top),
          reason: 'the discovery rail must travel upward with the content');
      expect(tester.getRect(find.byType(ProductCard).first).top,
          lessThan(firstCardAtRest.top),
          reason: 'listings must move up into the freed space');

      // Steps 10-12: keep going. The rail leaves entirely, the header bottoms
      // out at the compact search bar, and no tall empty band is left behind.
      await _scrollHome(tester, -1400);

      expect(find.text(_firstCategory), findsNothing,
          reason: 'the category rail must scroll completely off-screen');
      expect(find.text('Fresh on Broka'), findsNothing,
          reason: 'the feed heading scrolls away with everything else');
      expect(find.byType(ZenoAvatar), findsOneWidget,
          reason: 'the only Zeno left on screen is the one in the bottom nav');
      final collapsed = _headerHeight(tester);
      expect(collapsed, lessThan(headerAtRest * 0.55),
          reason: 'the collapsed header must be a fraction of the full one');
      expect(collapsed, lessThan(90),
          reason: 'what remains is a compact search control, not a header');
      // Brief §2: the search control survives the collapse - it is the one
      // thing that is meant to.
      expect(find.byIcon(Icons.search_rounded), findsOneWidget);
      expect(find.byIcon(Icons.tune_rounded), findsOneWidget);
      // Step 11: with the header down to ~60px the grid owns the screen.
      final viewportHeight = tester.getSize(find.byType(CustomScrollView)).height;
      expect(collapsed / viewportHeight, lessThan(0.15));

      // Step 19 again: the nav did not move while all of that happened.
      expect(tester.getRect(find.text('Home').last), navAtRest);

      // Steps 17-18: scroll back to the top, full header returns.
      await _scrollHome(tester, 3000);
      expect(_headerHeight(tester), closeTo(headerAtRest, 0.5));
      expect(find.text('BROKA'), findsOneWidget);
      expect(find.text(_firstCategory), findsOneWidget);
    });

    testWidgets('step 30: every price on screen is a full KES amount',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
      await _settle(tester);

      final prices = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .whereType<String>()
          .where((t) => t.startsWith('KES '))
          .toList();

      expect(prices, isNotEmpty);
      for (final price in prices) {
        expect(price, isNot(matches(RegExp(r'[0-9.]+[KM]$'))),
            reason: '$price is abbreviated');
      }
      // The fake feed is priced at 15,000 - the exact value the brief calls
      // out as "never display KES 15K".
      expect(prices, contains('KES 15,000'));
    });

    testWidgets('step 15/16: pull-to-refresh still reaches the feed',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
      await _settle(tester);

      expect(find.byType(RefreshIndicator), findsOneWidget);

      // Drag down from the top and let go: the indicator has to appear, which
      // it only can if the collapsing header left the overscroll gesture
      // alone.
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 320));
      await tester.pump();
      expect(find.byType(RefreshProgressIndicator), findsOneWidget);
      await _settle(tester);
      await tester.pump(const Duration(seconds: 1));
      // And the feed is still there afterwards, not wiped by the refetch.
      expect(find.byType(ProductCard), findsWidgets);
    });

    testWidgets('step 27/28: no overflow on a small Android screen',
        (tester) async {
      tester.view.physicalSize = const Size(320 * 2.0, 640 * 2.0);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
      await _settle(tester);
      expect(tester.takeException(), isNull);

      await _scrollHome(tester, -900);
      expect(tester.takeException(), isNull);
      expect(find.byType(ProductCard), findsWidgets);

      await _scrollHome(tester, 2000);
      expect(tester.takeException(), isNull);
      expect(find.text('BROKA'), findsOneWidget);
    });

    // ── Polish pass (2026-09-18) ───────────────────────────────────────────

    testWidgets('step 19: no overflow at any of the widths the brief names',
        (tester) async {
      // 320 and 340 are the small-Android band, 360 the old Android default,
      // 390-430 the current mainstream. Each one gets the full walk, because
      // an overflow that only appears once the header has collapsed is still
      // an overflow.
      for (final width in const [320.0, 340.0, 360.0, 390.0, 430.0]) {
        tester.view.physicalSize = Size(width * 2.0, 760 * 2.0);
        tester.view.devicePixelRatio = 2.0;

        await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
        await _settle(tester);
        expect(tester.takeException(), isNull, reason: 'at rest, ${width}dp');
        expect(find.byType(ProductCard), findsWidgets, reason: '${width}dp');

        await _scrollHome(tester, -900);
        expect(tester.takeException(), isNull, reason: 'scrolled, ${width}dp');

        await _scrollHome(tester, 2000);
        expect(tester.takeException(), isNull,
            reason: 'back at the top, ${width}dp');
      }
      tester.view.reset();
    });

    testWidgets('brief §1: the header is transparent at rest and opaque the '
        'moment anything scrolls under it', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
      await _settle(tester);

      // At rest nothing is behind the header but the constellation, which is
      // meant to show through.
      expect(_headerBackdropOpacity(tester), 0.0);

      // One nudge - far less than the collapse range - and it must already be
      // solid, or a product card would be visible through it.
      await _scrollHome(tester, -20);
      expect(_headerBackdropOpacity(tester), 1.0,
          reason: 'cards must never bleed through the collapsing header');

      await _scrollHome(tester, -1200);
      expect(_headerBackdropOpacity(tester), 1.0);

      await _scrollHome(tester, 3000);
      expect(_headerBackdropOpacity(tester), 0.0,
          reason: 'the constellation comes back when the header is expanded');
    });

    testWidgets('brief §16: one content edge down the whole screen',
        (tester) async {
      tester.view.physicalSize = const Size(390 * 3.0, 844 * 3.0);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
      await _settle(tester);

      // Sections that sit flush against the 16px page gutter.
      expect(tester.getTopLeft(find.text('🔥 ')).dx, 16);
      expect(tester.getTopLeft(find.byType(ProductCard).first).dx, 16);
      // The rail's first circle: 12px of ListView padding + each pill's own
      // 4px margin.
      expect(tester.getTopLeft(find.text(_firstCategory)).dx, 16);

      // The search field and the Zeno CTA are boxes rather than bare text, so
      // measure the box, not its contents - their own padding and 1px border
      // would otherwise read as misalignment when they are in fact flush.
      final searchField = find
          .ancestor(
              of: find.byIcon(Icons.search_rounded),
              matching: find.byType(Container))
          .first;
      final zenoCta = find
          .ancestor(
              of: find.byType(ZenoAvatar).first, matching: find.byType(Container))
          .first;
      expect(tester.getTopLeft(searchField).dx, 16);
      expect(tester.getTopLeft(zenoCta).dx, 16);
    });

    testWidgets('brief §2: the first product row starts in the top half of '
        'the screen', (tester) async {
      tester.view.physicalSize = const Size(390 * 3.0, 844 * 3.0);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
      await _settle(tester);

      final viewport = tester.getSize(find.byType(CustomScrollView));
      final firstCardTop = tester.getTopLeft(find.byType(ProductCard).first).dy;
      // A regression guard on the spacing, not a pixel spec: header +
      // rail + Zeno + heading must leave the listings starting above the
      // halfway line, so the feed - not the chrome - is what Home is.
      expect(firstCardTop / viewport.height, lessThan(0.47),
          reason: 'chrome above the feed has crept back up to '
              '${(firstCardTop / viewport.height * 100).round()}% of the screen');
    });

    testWidgets('brief §13: tapping the search bar opens listing search',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
      await _settle(tester);

      await tester.tap(find.byIcon(Icons.search_rounded));
      await _settle(tester);
      // Empty-history state of ListingSearchScreen (listing_search_test.dart
      // covers the search itself).
      expect(find.text('Find something to buy'), findsOneWidget);
    });

    testWidgets('the filter panel still opens from the collapsed header',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
      await _settle(tester);

      await _scrollHome(tester, -1400);
      await tester.tap(find.byIcon(Icons.tune_rounded));
      await _settle(tester);
      // Opening filters returns to the top, where the panel lives.
      await _settle(tester);
      expect(find.text('Max Price'), findsOneWidget);
      expect(find.text('Condition'), findsOneWidget);
      expect(find.text('Sort'), findsOneWidget);
    });
  });

  // ── Home feed bugs (2026-09-25 search pass) ─────────────────────────────────

  group('Home feed', () {
    tearDown(() => setFakeRoute(null));

    testWidgets('an untouched price filter is no filter at all', (tester) async {
      final requested = <Uri>[];
      setFakeRoute((uri) {
        if (uri.path.startsWith('/listings')) requested.add(uri);
        return null;
      });
      await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
      await _settle(tester);
      expect(requested, isNotEmpty);
      // max_price=5000000 went out on every request, hiding every car, plot
      // and house above five million from Home.
      expect(requested.first.queryParameters.containsKey('max_price'), isFalse);
    });

    testWidgets('a feed that fails to load offers a retry, not an empty market',
        (tester) async {
      setFakeRoute((uri) =>
          uri.path.startsWith('/listings') ? const FakeResponse.error() : null);
      await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
      await _settle(tester);
      expect(find.text("Couldn't load listings"), findsOneWidget);
      expect(find.text('No listings yet'), findsNothing);
    });

    testWidgets('a price sort is not reordered by featured pins', (tester) async {
      setFakeRoute((uri) {
        if (!uri.path.startsWith('/listings')) return null;
        if (uri.queryParameters['sort'] != 'price_low') return null;
        if (uri.queryParameters['offset'] != '0') return <Object?>[];
        return [
          fakeListingJson(1, price: 1000),
          fakeListingJson(2, price: 90000)
            ..['is_featured'] = true
            ..['featured_until'] = '2030-01-01T00:00:00',
        ];
      });
      await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
      await _settle(tester);
      await tester.tap(find.byIcon(Icons.tune_rounded));
      await _settle(tester);
      await tester.tap(find.byType(DropdownButton<String?>));
      await _settle(tester);
      await tester.tap(find.text('Price: low to high').last);
      await _settle(tester);
      // Close the panel so the grid is back on screen. `.first`: the panel's
      // own Condition row uses the same icon.
      await tester.tap(find.byIcon(Icons.tune_rounded).first);
      await _settle(tester);

      final first = find.byType(ProductCard).first;
      expect(find.descendant(of: first, matching: find.text('KES 1,000')), findsOneWidget,
          reason: 'low to high must open on the cheapest listing');
    });

    testWidgets('the location filter has no stray Seller Dashboard button',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
      await _settle(tester);
      await tester.tap(find.byIcon(Icons.tune_rounded));
      await _settle(tester);
      await tester.tap(find.text('All locations'));
      await _settle(tester);
      expect(find.text('Filter by Location'), findsOneWidget);
      expect(find.byTooltip('Seller Dashboard'), findsNothing);
    });

    testWidgets('an active filter still shows once the panel is closed',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
      await _settle(tester);
      expect(find.byKey(const Key('home-filters-active-dot')), findsNothing);

      await tester.tap(find.byIcon(Icons.tune_rounded));
      await _settle(tester);
      await tester.tap(find.text('New'));
      await _settle(tester);
      // `.first`: the panel's own Condition row uses the same icon.
      await tester.tap(find.byIcon(Icons.tune_rounded).first);
      await _settle(tester);
      expect(find.text('Max Price'), findsNothing);
      expect(find.byKey(const Key('home-filters-active-dot')), findsOneWidget);
    });
  });
}

// ── Helpers ──────────────────────────────────────────────────────────────────

/// The first category the fake backend returns, and so the first pill in the
/// rail. Width-sensitive assertions use this rather than a name further along
/// the list, which a narrow viewport never builds - the rail is a lazy
/// horizontal ListView.
final _firstCategory = fakeTopLevelCategories.first;

/// Scrolls Home's one scroll view by [dy] (negative scrolls down the feed)
/// and lets the frame settle. Uses the ScrollPosition directly rather than a
/// fling so the assertions read a settled offset instead of racing a
/// simulation.
Future<void> _scrollHome(WidgetTester tester, double dy) async {
  final state = tester.state<ScrollableState>(find.byType(Scrollable).first);
  final target = (state.position.pixels - dy)
      .clamp(0.0, state.position.maxScrollExtent);
  state.position.jumpTo(target);
  await _settle(tester);
}

/// Alpha of the pinned header's own backdrop. 0 means the constellation shows
/// through it; 1 means nothing behind it can.
double _headerBackdropOpacity(WidgetTester tester) {
  final box = tester.widget<DecoratedBox>(find
      .descendant(
        of: find.byType(SliverPersistentHeader),
        matching: find.byType(DecoratedBox),
      )
      .first);
  return (box.decoration as BoxDecoration).color!.opacity;
}

/// The rendered height of the pinned Home header, which is what "the header
/// collapses" actually means in pixels.
double _headerHeight(WidgetTester tester) =>
    tester
        .renderObject<RenderSliver>(find.byType(SliverPersistentHeader))
        .geometry!
        .paintExtent;

/// pumpAndSettle() cannot be used anywhere a CircularProgressIndicator is on
/// screen - it never stops scheduling frames, so settling never happens. A
/// fixed handful of pumps is enough here: every fetch in these tests resolves
/// on a microtask, and no test depends on a long animation finishing.
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

/// A stand-in for HomeScreen's own CustomScrollView: one scroll owner, with
/// the grid supplied as a sliver exactly the way Home supplies it.
Widget _slidingHost({
  required Future<List<dynamic>> Function(int page) fetchPage,
  ProductGridController? controller,
  Widget Function(BuildContext)? emptyStateBuilder,
}) {
  return MaterialApp(
    home: Scaffold(
      body: CustomScrollView(
        slivers: [
          const SliverToBoxAdapter(child: SizedBox(height: 120)),
          ProductGridView(
            sliver: true,
            controller: controller,
            fetchPage: fetchPage,
            emptyStateBuilder: emptyStateBuilder,
          ),
        ],
      ),
    ),
  );
}

int _verticalScrollableCount(WidgetTester tester) => tester
    .widgetList<Scrollable>(find.byType(Scrollable))
    .where((s) => s.axisDirection == AxisDirection.down || s.axisDirection == AxisDirection.up)
    .length;

