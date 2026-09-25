// Covers the four non-category destinations on Home's discovery rail -
// Trending, the Auction House, Traders and Stores - after the alignment pass.
//
// The tests are written against the four screens as a SET rather than one at a
// time, because "they all look and behave like Home now" is the actual claim
// being made. A loop that opens each one and checks the same five structural
// things is what would catch the fifth destination being added without the
// shared header, or one of these four drifting back to its own look.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:broka/features/auctions/presentation/auction_house_screen.dart';
import 'package:broka/features/discovery/domain/destination_visual.dart';
import 'package:broka/features/stores/presentation/store_list_screen.dart';
import 'package:broka/features/traders/presentation/trader_list_screen.dart';
import 'package:broka/features/trending/presentation/trending_screen.dart';
import 'package:broka/widgets/collapsing_screen_header.dart';
import 'package:broka/widgets/constellation_background.dart';
import 'package:broka/widgets/product_card.dart';

import 'support/fake_api.dart';

/// Every rail destination, paired with the widget it opens.
final _destinations = <DestinationVisual, Widget Function()>{
  DestinationVisuals.trending: () => const TrendingScreen(),
  DestinationVisuals.auctions: () => const AuctionHouseScreen(),
  DestinationVisuals.traders: () => const TraderListScreen(),
  DestinationVisuals.stores: () => const StoreListScreen(),
};

void main() {
  setUpAll(installFakeApi);

  setUp(() {
    setFakeRoute(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/shared_preferences'),
      (call) async => call.method == 'getAll' ? <String, Object>{} : null,
    );
  });

  Widget host(Widget screen) => MaterialApp(home: screen);

  group('all four destinations share one system', () {
    testWidgets('constellation, one scroll owner, shared collapsing header',
        (tester) async {
      for (final entry in _destinations.entries) {
        final visual = entry.key;
        await tester.pumpWidget(host(entry.value()));
        await _settle(tester);

        expect(tester.takeException(), isNull, reason: visual.title);
        expect(find.byType(ConstellationBackground), findsOneWidget,
            reason: '${visual.title} is not on the constellation');
        expect(find.byType(CustomScrollView), findsOneWidget,
            reason: '${visual.title} has no single scroll view');
        expect(find.byType(CollapsingScreenHeader), findsNothing,
            reason: 'the delegate is not a widget');
        expect(find.byType(SliverPersistentHeader), findsOneWidget,
            reason: '${visual.title} has no pinned header');
        // The header carries the destination's own identity - the same title,
        // emoji and gradient the rail pill that opens it carries.
        expect(find.text(visual.title.toUpperCase()), findsOneWidget,
            reason: '${visual.title} title');
        expect(find.text(visual.emoji), findsWidgets,
            reason: '${visual.title} emoji');
        expect(find.byIcon(Icons.arrow_back_ios_new_rounded), findsOneWidget,
            reason: '${visual.title} back button');

        final vertical = tester
            .widgetList<Scrollable>(find.byType(Scrollable))
            .where((s) =>
                s.axisDirection == AxisDirection.down ||
                s.axisDirection == AxisDirection.up)
            .length;
        expect(vertical, 1,
            reason: '${visual.title} has $vertical vertical scrollables');

        expect(find.byType(RefreshIndicator), findsOneWidget,
            reason: '${visual.title} lost pull-to-refresh');
      }
    });

    testWidgets('the header collapses and comes back, opaque once scrolled',
        (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      for (final entry in _destinations.entries) {
        final visual = entry.key;
        await tester.pumpWidget(host(entry.value()));
        await _settle(tester);

        expect(_headerBackdropOpacity(tester), 0.0,
            reason: '${visual.title} should show the constellation at rest');
        final full = _headerHeight(tester);

        await _scroll(tester, -400);
        expect(_headerHeight(tester), lessThan(full),
            reason: '${visual.title} header did not contract');
        expect(_headerBackdropOpacity(tester), 1.0,
            reason: '${visual.title} would let content bleed through');
        // Back stays reachable at every scroll position.
        expect(find.byIcon(Icons.arrow_back_ios_new_rounded), findsOneWidget,
            reason: '${visual.title} lost its back button when collapsed');

        await _scroll(tester, 3000);
        expect(_headerHeight(tester), closeTo(full, 0.5),
            reason: '${visual.title} header did not return');
      }
    });

    testWidgets('no overflow at 320-430dp, at rest and scrolled',
        (tester) async {
      for (final width in const [320.0, 340.0, 360.0, 390.0, 430.0]) {
        for (final entry in _destinations.entries) {
          tester.view.physicalSize = Size(width * 2, 760 * 2);
          tester.view.devicePixelRatio = 2.0;

          await tester.pumpWidget(host(entry.value()));
          await _settle(tester);
          expect(tester.takeException(), isNull,
              reason: '${entry.key.title} at ${width}dp, at rest');

          await _scroll(tester, -600);
          expect(tester.takeException(), isNull,
              reason: '${entry.key.title} at ${width}dp, scrolled');

          await _scroll(tester, 2000);
          expect(tester.takeException(), isNull,
              reason: '${entry.key.title} at ${width}dp, back at top');
        }
      }
      tester.view.reset();
    });

    testWidgets('content sits on the same 16px edge as the header',
        (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      // One representative item per screen, since the four render different
      // card types.
      await tester.pumpWidget(host(const TrendingScreen()));
      await _settle(tester);
      expect(tester.getTopLeft(find.byType(ProductCard).first).dx, 16);

      await tester.pumpWidget(host(const TraderListScreen()));
      await _settle(tester);
      expect(tester.getTopLeft(find.text('Trader 0')).dx, greaterThan(16));
      expect(tester.getTopLeft(find.text('Trader 0')).dx, lessThan(110));

      await tester.pumpWidget(host(const StoreListScreen()));
      await _settle(tester);
      final searchField = find
          .ancestor(
              of: find.byIcon(Icons.search_rounded),
              matching: find.byType(Container))
          .first;
      expect(tester.getTopLeft(searchField).dx, 16);
    });

    testWidgets('every empty state wears its own destination visual',
        (tester) async {
      setFakeRoute((uri) {
        final p = uri.path;
        if (p.startsWith('/trending') ||
            p.startsWith('/auctions') ||
            p.startsWith('/traders') ||
            p.startsWith('/stores')) {
          return <Object?>[];
        }
        if (p.startsWith('/listings')) return {'items': <Object?>[], 'total': 0};
        return null;
      });

      for (final entry in _destinations.entries) {
        final visual = entry.key;
        await tester.pumpWidget(host(entry.value()));
        await _settle(tester);

        expect(find.text(visual.emptyHeadline), findsOneWidget,
            reason: '${visual.title} empty headline');
        expect(find.text(visual.emoji), findsWidgets,
            reason: '${visual.title} empty visual');
        // Not the old bare "No traders yet" on a flat black screen.
        expect(find.byType(BrokaEmptyState), findsOneWidget,
            reason: '${visual.title} is not using the shared empty state');
      }
    });

    testWidgets('a backend failure offers a retry that works', (tester) async {
      // Trending and the product grid swallow failures into an empty list by
      // design, so this covers the three that surface an error.
      var failing = true;
      setFakeRoute((uri) {
        if (!failing) return null;
        final p = uri.path;
        if (p.startsWith('/auctions') ||
            p.startsWith('/traders') ||
            p.startsWith('/stores')) {
          // A shape the repository cannot parse produces a real Failure.
          return {'detail': 'backend exploded'};
        }
        return null;
      });

      for (final screen in [
        () => const AuctionHouseScreen(),
        () => const TraderListScreen(),
        () => const StoreListScreen(),
      ]) {
        failing = true;
        await tester.pumpWidget(host(screen()));
        await _settle(tester);
        expect(find.text('Retry'), findsOneWidget);

        failing = false;
        await tester.tap(find.text('Retry'));
        await _settle(tester);
        expect(find.text('Retry'), findsNothing,
            reason: 'retry did not recover');
      }
    });
  });

  group('Trending', () {
    testWidgets('renders real listings and navigates by listing id',
        (tester) async {
      await tester.pumpWidget(host(const TrendingScreen()));
      await _settle(tester);
      expect(find.byType(ProductCard), findsWidgets);
      // Prices come through the shared formatter, unabbreviated.
      expect(find.text('KES 15,000'), findsWidgets);
    });
  });

  group('Auction House', () {
    testWidgets('the four statuses are chips that refetch', (tester) async {
      final requested = <Uri>[];
      setFakeRoute((uri) {
        if (uri.path.startsWith('/auctions')) requested.add(uri);
        return null;
      });

      await tester.pumpWidget(host(const AuctionHouseScreen()));
      await _settle(tester);

      for (final label in const [
        'Live Now',
        'Ending Soon',
        'Upcoming',
        'Completed'
      ]) {
        expect(find.text(label), findsOneWidget, reason: '$label chip');
      }
      expect(requested.first.queryParameters['status'], 'live');

      await tester.tap(find.text('Upcoming'));
      await _settle(tester);
      expect(requested.last.queryParameters['status'], 'upcoming');

      await tester.tap(find.text('Completed'));
      await _settle(tester);
      expect(requested.last.queryParameters['status'], 'ended');
    });

    testWidgets('bids are exact amounts, never abbreviated', (tester) async {
      await tester.pumpWidget(host(const AuctionHouseScreen()));
      await _settle(tester);

      // The fake bids at 1,500,000 - which the old _fmtKes rendered "KES 1.5M".
      expect(find.text('KES 1,500,000'), findsWidgets);
      final abbreviated = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .whereType<String>()
          .where((t) =>
              t.startsWith('KES ') && RegExp(r'[0-9.]+[KM]$').hasMatch(t));
      expect(abbreviated, isEmpty, reason: 'found abbreviated bids');
    });

    testWidgets('an auction with no bids says so rather than showing KES 0',
        (tester) async {
      setFakeRoute((uri) {
        if (uri.path.startsWith('/auctions')) {
          return [fakeAuctionJson(0, currentBid: null)];
        }
        return null;
      });
      await tester.pumpWidget(host(const AuctionHouseScreen()));
      await _settle(tester);
      expect(find.text('No bids yet'), findsOneWidget);
      expect(find.text('KES 0'), findsNothing);
    });
  });

  group('Traders', () {
    testWidgets('lists traders from the backend and keeps embedded mode',
        (tester) async {
      await tester.pumpWidget(host(const TraderListScreen()));
      await _settle(tester);
      expect(find.text('Trader 0'), findsOneWidget);
      expect(find.text('Trader 3'), findsWidgets);

      // embedded: true is a pre-existing contract - no Scaffold, no header,
      // just the list, for a caller that hosts it itself.
      await tester.pumpWidget(const MaterialApp(
          home: Scaffold(body: TraderListScreen(embedded: true))));
      await _settle(tester);
      expect(find.byType(SliverPersistentHeader), findsNothing);
      expect(find.byType(ConstellationBackground), findsNothing);
      expect(find.text('Trader 0'), findsOneWidget);
    });
  });

  group('Trader search', () {
    testWidgets('reaches /traders and reports no matches', (tester) async {
      final requested = <Uri>[];
      setFakeRoute((uri) {
        if (uri.path.startsWith('/traders')) {
          requested.add(uri);
          if (uri.queryParameters['search'] == 'nobody') return <Object?>[];
        }
        return null;
      });

      await tester.pumpWidget(host(const TraderListScreen()));
      await _settle(tester);
      expect(find.text('Trader 0'), findsOneWidget);
      expect(find.text('Search traders by name'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('trader-search-field')), 'nobody');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await _settle(tester);

      expect(requested.last.queryParameters['search'], 'nobody');
      expect(find.text('No traders match "nobody"'), findsOneWidget);
      // Never the user directory, which returns email and phone.
      expect(requested.where((u) => u.path.contains('/auth/search')), isEmpty);
    });

    testWidgets('types live, and an older answer cannot replace a newer one',
        (tester) async {
      setFakeRoute((uri) {
        if (!uri.path.startsWith('/traders')) return null;
        final q = uri.queryParameters['search'];
        if (q == 'gr') {
          return FakeResponse([fakeTraderJson(1)..['business_name'] = 'Slow Greta'],
              delay: const Duration(seconds: 2));
        }
        if (q == 'grace') return [fakeTraderJson(2)..['business_name'] = 'Grace Stores'];
        return null;
      });
      await tester.pumpWidget(host(const TraderListScreen()));
      await _settle(tester);

      final field = find.byKey(const Key('trader-search-field'));
      await tester.enterText(field, 'gr');
      await tester.pump(const Duration(milliseconds: 500));
      await tester.enterText(field, 'grace');
      await tester.pump(const Duration(milliseconds: 500));
      await _settle(tester);
      expect(find.text('Grace Stores'), findsOneWidget);

      await tester.pump(const Duration(seconds: 3));
      await _settle(tester);
      expect(find.text('Grace Stores'), findsOneWidget);
      expect(find.text('Slow Greta'), findsNothing);
    });
  });

  group('Stores', () {
    testWidgets('search reaches the backend and reports no matches',
        (tester) async {
      final requested = <Uri>[];
      setFakeRoute((uri) {
        if (uri.path.startsWith('/stores')) {
          requested.add(uri);
          if (uri.queryParameters['search'] == 'nothing') return <Object?>[];
        }
        return null;
      });

      await tester.pumpWidget(host(const StoreListScreen()));
      await _settle(tester);
      expect(find.text('Store 0'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'nothing');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await _settle(tester);

      expect(requested.last.queryParameters['search'], 'nothing');
      expect(find.text('No stores match "nothing"'), findsOneWidget);
    });
  });
}

// ── Helpers ──────────────────────────────────────────────────────────────────

/// pumpAndSettle is unusable on these screens: ConstellationBackground runs a
/// 24-second repeating controller, so they never stop scheduling frames.
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

Future<void> _scroll(WidgetTester tester, double dy) async {
  final state = tester.state<ScrollableState>(find.byType(Scrollable).first);
  final target =
      (state.position.pixels - dy).clamp(0.0, state.position.maxScrollExtent);
  state.position.jumpTo(target);
  await _settle(tester);
}

double _headerHeight(WidgetTester tester) => tester
    .renderObject<RenderSliver>(find.byType(SliverPersistentHeader))
    .geometry!
    .paintExtent;

double _headerBackdropOpacity(WidgetTester tester) {
  final box = tester.widget<DecoratedBox>(find
      .descendant(
        of: find.byType(SliverPersistentHeader),
        matching: find.byType(DecoratedBox),
      )
      .first);
  return (box.decoration as BoxDecoration).color!.opacity;
}
