// Covers the Category Zone screen after the alignment pass: that it uses the
// same visual system and scroll architecture as Home, that its visuals come
// from the shared resolver rather than anything positional, and that the long
// category names in the real taxonomy do not break it on a small phone.
//
// The acceptance list in the brief names sixteen categories to open by hand.
// The loops below open all sixteen, which is the part of that list a test can
// actually carry.

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:broka/features/categories/domain/category_visual.dart';
import 'package:broka/features/categories/presentation/category_zone_screen.dart';
import 'package:broka/features/categories/presentation/widgets/feed_sort_row.dart';
import 'package:broka/widgets/constellation_background.dart';
import 'package:broka/widgets/product_card.dart';

import 'support/fake_api.dart';

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

  // The five the brief calls out by name, plus the rest of the taxonomy.
  const longNames = [
    'Books & Education',
    'Business & Industrial',
    'Beauty & Personal Care',
    'Home & Furniture',
    'Sports & Fitness',
  ];

  Widget zone(String name) => MaterialApp(
        home: CategoryZoneScreen(categoryId: name, categoryName: name),
      );

  group('every category in the taxonomy opens cleanly', () {
    testWidgets('all sixteen render with their own name and visual',
        (tester) async {
      for (final name in fakeTopLevelCategories) {
        await tester.pumpWidget(zone(name));
        await _settle(tester);

        expect(tester.takeException(), isNull, reason: name);
        // Correct name, in the Zone title.
        expect(find.text('$name ZONE'.toUpperCase()), findsOneWidget,
            reason: '$name title');
        // Correct visual, from the shared resolver - header badge and
        // nothing else, since this fake backend returns listings.
        final visual = CategoryVisuals.resolve(name);
        expect(find.text(visual.emoji), findsWidgets, reason: '$name emoji');
        // Search placeholder names the category the user is actually in.
        expect(find.text('Search in $name...'), findsOneWidget,
            reason: '$name placeholder');
        // Its types of item come from the backend, not a hardcoded list, as
        // cards that each open a screen of their own.
        expect(find.text('Shop $name by type'), findsOneWidget, reason: '$name types');
        expect(find.text('Sub One'), findsOneWidget, reason: '$name subcats');
        // Real listings.
        expect(find.byType(ProductCard), findsWidgets, reason: '$name grid');
      }
    });

    testWidgets('the visual matches what Home would have shown for the '
        'same category', (tester) async {
      // The whole point of the resolver: whatever icon Home's rail put on a
      // category, the Zone it opens shows the same one. Asserted against the
      // registry rather than a second copy of the table.
      for (final name in fakeTopLevelCategories) {
        await tester.pumpWidget(zone(name));
        await _settle(tester);
        final visual = CategoryVisuals.resolve(name);
        expect(find.text(visual.emoji), findsWidgets,
            reason: '$name should show ${visual.emoji}');
        // And no other category's emoji should be on screen.
        for (final other in CategoryVisuals.canonical) {
          if (other.categoryName == visual.categoryName) continue;
          if (other.emoji == visual.emoji) continue;
          expect(find.text(other.emoji), findsNothing,
              reason: '$name showed ${other.categoryName}\'s visual');
        }
      }
    });
  });

  group('responsive', () {
    testWidgets('long names survive 320-430dp, at rest and scrolled',
        (tester) async {
      for (final width in const [320.0, 340.0, 360.0, 390.0, 430.0]) {
        for (final name in longNames) {
          tester.view.physicalSize = Size(width * 2, 760 * 2);
          tester.view.devicePixelRatio = 2.0;

          await tester.pumpWidget(zone(name));
          await _settle(tester);
          expect(tester.takeException(), isNull,
              reason: '$name at ${width}dp, at rest');
          expect(find.text('$name ZONE'.toUpperCase()), findsOneWidget,
              reason: '$name at ${width}dp lost its title');

          await _scroll(tester, -700);
          expect(tester.takeException(), isNull,
              reason: '$name at ${width}dp, scrolled');

          await _scroll(tester, 2000);
          expect(tester.takeException(), isNull,
              reason: '$name at ${width}dp, back at top');
        }
      }
      tester.view.reset();
    });
  });

  group('architecture', () {
    testWidgets('one vertical scroll owner, on the constellation',
        (tester) async {
      await tester.pumpWidget(zone('Electronics'));
      await _settle(tester);

      expect(find.byType(ConstellationBackground), findsOneWidget);
      expect(find.byType(CustomScrollView), findsOneWidget);
      // The subcategory rail is horizontal and does not count; a second
      // vertical one would mean the grid brought its own controller back.
      final vertical = tester
          .widgetList<Scrollable>(find.byType(Scrollable))
          .where((s) =>
              s.axisDirection == AxisDirection.down ||
              s.axisDirection == AxisDirection.up)
          .length;
      expect(vertical, 1);
    });

    testWidgets('the header collapses and keeps back + filter reachable',
        (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(zone('Beauty & Personal Care'));
      await _settle(tester);

      final full = _headerHeight(tester);
      expect(find.byIcon(Icons.arrow_back_ios_new_rounded), findsOneWidget);
      expect(find.byIcon(Icons.tune_rounded), findsOneWidget);

      await _scroll(tester, -600);
      final collapsed = _headerHeight(tester);
      expect(collapsed, lessThan(full),
          reason: 'the zone header must contract as the feed takes over');
      // The search, rail and sort row are gone; the two controls are not.
      expect(find.text('Search in Beauty & Personal Care...'), findsNothing);
      expect(find.text('Sub One'), findsNothing);
      expect(find.byIcon(Icons.arrow_back_ios_new_rounded), findsOneWidget);
      expect(find.byIcon(Icons.tune_rounded), findsOneWidget);

      await _scroll(tester, 3000);
      expect(_headerHeight(tester), closeTo(full, 0.5));
    });

    testWidgets('the header is transparent at rest and opaque once scrolled',
        (tester) async {
      await tester.pumpWidget(zone('Automobiles'));
      await _settle(tester);
      expect(_headerBackdropOpacity(tester), 0.0);
      await _scroll(tester, -20);
      expect(_headerBackdropOpacity(tester), 1.0,
          reason: 'cards must not bleed through the collapsing zone header');
    });

    testWidgets('one content edge: header, search, types and grid all at 16',
        (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(zone('Agriculture'));
      await _settle(tester);

      // The search field's box and the first product card share the gutter.
      final searchField = find
          .ancestor(
              of: find.byIcon(Icons.search_rounded),
              matching: find.byType(Container))
          .first;
      expect(tester.getTopLeft(searchField).dx, 16);
      expect(tester.getTopLeft(find.byType(ProductCard).first).dx, 16);
      // The first type-of-item card sits on the same edge.
      expect(tester.getTopLeft(find.byKey(const Key('zone-type-Sub One'))).dx, 16);
    });
  });

  group('empty state', () {
    testWidgets('uses the category visual, not a generic package',
        (tester) async {
      setFakeRoute((uri) {
        if (uri.path.startsWith('/listings')) {
          return {'items': <Object?>[], 'total': 0};
        }
        return null;
      });

      await tester.pumpWidget(zone('Books & Education'));
      await _settle(tester);

      expect(find.text('No Books & Education listings yet'), findsOneWidget);
      expect(find.text('Try adjusting your filters'), findsOneWidget);
      // 📚, resolved from the name - and specifically not the old 📦.
      expect(find.text(CategoryVisuals.resolve('Books & Education').emoji),
          findsWidgets);
      expect(find.text('📦'), findsNothing);
      expect(find.byType(ProductCard), findsNothing);
    });

    testWidgets('sits in the content area, not near the bottom of the phone',
        (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      setFakeRoute((uri) {
        if (uri.path.startsWith('/listings')) {
          return {'items': <Object?>[], 'total': 0};
        }
        return null;
      });

      await tester.pumpWidget(zone('Services'));
      await _settle(tester);

      final viewport = tester.getRect(find.byType(CustomScrollView));
      final message = tester.getRect(find.text('No Services listings yet'));
      final sortRow = tester.getRect(find.byType(FeedSortRow));
      // Brief §11: comfortably below the sort row and centred in what's left,
      // rather than pushed toward the bottom edge. Measured against the space
      // under the sort row since the Zone began with its types of item
      // (2026-10-08), which take the top half of an empty Zone by design.
      final left = viewport.bottom - sortRow.bottom;
      final inSpace = (message.center.dy - sortRow.bottom) / left;
      expect(message.top, greaterThan(sortRow.bottom));
      expect(inSpace, inInclusiveRange(0.3, 0.7),
          reason: 'not centred in the space below the sort row');
      expect((message.center.dy - viewport.top) / viewport.height, lessThan(0.8),
          reason: 'the empty state drifted to the bottom of the screen');
    });
  });

  group('functionality survives the restyle', () {
    testWidgets('sort, filters and types of item still work',
        (tester) async {
      final requested = <Uri>[];
      setFakeRoute((uri) {
        if (uri.path.startsWith('/listings')) requested.add(uri);
        return null;
      });

      await tester.pumpWidget(zone('Electronics'));
      await _settle(tester);
      expect(requested.first.queryParameters['sort'], 'newest');
      expect(requested.first.queryParameters['category_id'], 'Electronics');
      // The Zone's own grid is the whole category.
      expect(requested.first.queryParameters.containsKey('subcategory_id'), isFalse);

      // A type of item opens its own screen, whose feed is that type: a
      // real backend id, sent as subcategory_id.
      await tester.tap(find.text('Sub One'));
      await _settleRoute(tester);
      expect(find.text('SUB ONE'), findsOneWidget, reason: 'the type screen\'s title');
      expect(requested.last.queryParameters['subcategory_id'], 'sub-Sub One');
      await tester.tap(find.byIcon(Icons.arrow_back_ios_new_rounded));
      await _settleRoute(tester);
      expect(find.text('ELECTRONICS ZONE'), findsOneWidget);

      // Sort.
      await tester.tap(find.byIcon(Icons.expand_more_rounded));
      await _settleRoute(tester);
      await tester.tap(find.text('Price: Low to High').last);
      await _settleRoute(tester);
      expect(requested.last.queryParameters['sort'], 'price_low');

      // The result count the backend reported, readable rather than dim.
      expect(find.text('128 results'), findsOneWidget);
    });

    testWidgets('the filter sheet still opens', (tester) async {
      await tester.pumpWidget(zone('Fashion'));
      await _settle(tester);
      await tester.tap(find.byIcon(Icons.tune_rounded));
      await _settleRoute(tester);
      // FilterBottomSheet is a modal route; something took over the screen.
      expect(find.byType(BottomSheet), findsOneWidget);
    });

    testWidgets('the search field is big enough to read back what was typed',
        (tester) async {
      await tester.pumpWidget(zone('Electronics'));
      await _settle(tester);

      final field = find
          .ancestor(of: find.byIcon(Icons.search_rounded), matching: find.byType(Container))
          .first;
      // Was a 44px pill with 13px text - reported as too small to see what
      // had been typed.
      expect(tester.getSize(field).height, greaterThanOrEqualTo(50));
      final style = tester.widget<TextField>(find.byType(TextField)).style!;
      expect(style.fontSize, greaterThanOrEqualTo(15));

      await tester.enterText(find.byType(TextField), 'samsung');
      await tester.pump();
      expect(find.text('samsung'), findsOneWidget);
    });

    testWidgets('a feed that fails to load offers a retry, not an empty zone',
        (tester) async {
      setFakeRoute((uri) =>
          uri.path.startsWith('/listings') ? const FakeResponse.error() : null);
      await tester.pumpWidget(zone('Electronics'));
      await _settle(tester);
      expect(find.text("Couldn't load listings"), findsOneWidget);
      expect(find.textContaining('No Electronics listings'), findsNothing);
    });

    testWidgets('search reaches the backend as a search param', (tester) async {
      final requested = <Uri>[];
      setFakeRoute((uri) {
        if (uri.path.startsWith('/listings')) requested.add(uri);
        return null;
      });

      await tester.pumpWidget(zone('Gaming'));
      await _settle(tester);

      await tester.enterText(find.byType(TextField), 'controller');
      // The field debounces by 450ms before it refetches.
      await tester.pump(const Duration(milliseconds: 600));
      await _settle(tester);
      expect(requested.last.queryParameters['search'], 'controller');
    });

    testWidgets('pull-to-refresh is wired to the feed', (tester) async {
      await tester.pumpWidget(zone('Property'));
      await _settle(tester);
      expect(find.byType(RefreshIndicator), findsOneWidget);

      await tester.drag(find.byType(CustomScrollView), const Offset(0, 320));
      await tester.pump();
      expect(find.byType(RefreshProgressIndicator), findsOneWidget);
      await _settle(tester);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(ProductCard), findsWidgets);
    });
  });
}

// ── Helpers ──────────────────────────────────────────────────────────────────

/// pumpAndSettle cannot be used where a CircularProgressIndicator is on screen
/// - it never stops scheduling frames. Every fetch here resolves on a
/// microtask, so a fixed handful of pumps is enough.
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

/// Long enough for a route transition (dropdown menu, modal sheet) to finish.
/// pumpAndSettle is unusable on this screen for the same reason as above,
/// with an extra one: ConstellationBackground runs a 24-second repeating
/// controller, so the Zone never stops scheduling frames at all.
Future<void> _settleRoute(WidgetTester tester) async {
  for (int i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
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
