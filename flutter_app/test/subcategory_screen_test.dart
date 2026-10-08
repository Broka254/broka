// Types of item on screens of their own (2026-10-08): a category's types are
// photo cards, each opening a SubcategoryScreen that leads with the type's
// brands (the makes, for vehicles) as one-tap filters.
//
// The claims these hold the screens to:
//  * the brands are the type's own, from /categories/{id}/filters - nothing
//    hardcoded in the app - and picking one narrows the server's results to
//    that brand within that type, not within the whole category;
//  * a type without brands leads with its first closed list of choices, and
//    one with neither has no row at all;
//  * the leading choice is not repeated in the filter sheet;
//  * Home's "See all" and a Zone's "See all" lay every card out at once.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:broka/features/categories/domain/models/category.dart';
import 'package:broka/features/categories/presentation/category_directory_screen.dart';
import 'package:broka/features/categories/presentation/category_zone_screen.dart';
import 'package:broka/features/categories/presentation/subcategory_screen.dart';
import 'package:broka/features/categories/presentation/widgets/category_art_card.dart';
import 'package:broka/screens/home_screen.dart';
import 'package:broka/widgets/product_card.dart';

import 'support/fake_api.dart';

const _brands = ['Samsung', 'Apple', 'Tecno', 'Infinix'];

/// The fields the fake backend gives each type of item.
Object? _fields(Uri uri) {
  final path = uri.path;
  if (!path.endsWith('/filters')) return null;
  if (path.contains('sub-phones')) {
    return [
      {'field_name': 'brand', 'field_type': 'text', 'options': _brands},
      {'field_name': 'model', 'field_type': 'text', 'options': null},
      {'field_name': 'storage', 'field_type': 'select', 'options': ['64GB', '128GB']},
    ];
  }
  if (path.contains('sub-cars')) {
    return [
      {'field_name': 'make', 'field_type': 'text', 'options': ['Toyota', 'Nissan']},
      {'field_name': 'fuel', 'field_type': 'select', 'options': ['Petrol', 'Diesel']},
    ];
  }
  if (path.contains('sub-plots')) {
    return [
      {'field_name': 'title_deed', 'field_type': 'select', 'options': ['Yes', 'No']},
    ];
  }
  return <Object?>[];
}

Widget _type(String id, String name, {String parent = 'Electronics'}) => MaterialApp(
      home: SubcategoryScreen(
        parentId: parent,
        parentName: parent,
        subcategory: Category(id: id, name: name, parentId: parent),
      ),
    );

void main() {
  setUpAll(installFakeApi);

  late List<Uri> requested;

  setUp(() {
    requested = [];
    HomeScreen.railHintEnabled = false;
    setFakeRoute((uri) {
      if (uri.path.startsWith('/listings')) requested.add(uri);
      return _fields(uri);
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/shared_preferences'),
      (call) async => call.method == 'getAll' ? <String, Object>{} : null,
    );
  });

  Map<String, dynamic>? attributesOf(Uri uri) {
    final raw = uri.queryParameters['attributes'];
    return raw == null ? null : jsonDecode(raw) as Map<String, dynamic>;
  }

  group('brands lead', () {
    testWidgets('the type\'s own brands, and a pick narrows the type to it', (tester) async {
      await tester.pumpWidget(_type('sub-phones', 'Phones'));
      await _settle(tester);

      expect(tester.takeException(), isNull);
      expect(find.text('PHONES'), findsOneWidget, reason: 'the title');
      expect(find.text('ELECTRONICS'), findsOneWidget, reason: 'the category above it');
      expect(find.text('Shop by brand'), findsOneWidget);
      expect(find.text('All brands'), findsOneWidget);
      for (final brand in _brands.take(3)) {
        expect(find.text(brand), findsOneWidget, reason: brand);
      }
      expect(find.byType(ProductCard), findsWidgets);
      // The type, not the category - and no brand yet.
      expect(requested.last.queryParameters['subcategory_id'], 'sub-phones');
      expect(requested.last.queryParameters.containsKey('category_id'), isFalse);
      expect(attributesOf(requested.last), isNull);

      await tester.tap(find.byKey(const Key('subcategory-facet-Samsung')));
      await _settle(tester);
      expect(requested.last.queryParameters['subcategory_id'], 'sub-phones');
      expect(attributesOf(requested.last), {'brand': 'Samsung'});

      await tester.tap(find.byKey(const Key('subcategory-facet-Apple')));
      await _settle(tester);
      expect(attributesOf(requested.last), {'brand': 'Apple'});

      await tester.tap(find.byKey(const Key('subcategory-facet-all')));
      await _settle(tester);
      expect(attributesOf(requested.last), isNull);
    });

    testWidgets('vehicles lead with their makes', (tester) async {
      await tester.pumpWidget(_type('sub-cars', 'Cars', parent: 'Automobiles'));
      await _settle(tester);
      expect(find.text('Shop by make'), findsOneWidget);
      expect(find.text('All makes'), findsOneWidget);
      await tester.tap(find.text('Toyota'));
      await _settle(tester);
      expect(attributesOf(requested.last), {'make': 'Toyota'});
    });

    testWidgets('no brands: the first closed list leads instead', (tester) async {
      await tester.pumpWidget(_type('sub-plots', 'Residential Plots', parent: 'Land'));
      await _settle(tester);
      expect(find.text('Shop by title deed'), findsOneWidget);
      await tester.tap(find.text('Yes'));
      await _settle(tester);
      expect(attributesOf(requested.last), {'title_deed': 'Yes'});
    });

    testWidgets('nothing to choose from: no row, the feed still works', (tester) async {
      await tester.pumpWidget(_type('sub-other', 'Antiques & Collectibles', parent: 'Arts & Crafts'));
      await _settle(tester);
      expect(find.byKey(const Key('subcategory-facets')), findsNothing);
      expect(find.textContaining('Shop by'), findsNothing);
      expect(find.byType(ProductCard), findsWidgets);
    });

    test('a brand list wins over a select; a select over nothing', () {
      CategoryFilterField f(String name, String type, [List<String>? options]) =>
          CategoryFilterField(fieldName: name, fieldType: type, options: options);
      expect(
          SubcategoryScreen.leadingFacet([f('ram', 'select', ['4GB']), f('brand', 'text', ['HP'])])!
              .fieldName,
          'brand');
      // A brand box with nothing to offer is not a row of chips.
      expect(
          SubcategoryScreen.leadingFacet([f('brand', 'text'), f('ram', 'select', ['4GB'])])!.fieldName,
          'ram');
      expect(SubcategoryScreen.leadingFacet([f('model', 'text')]), isNull);
    });
  });

  testWidgets('the filter sheet has the type\'s other details, not the brand again',
      (tester) async {
    await tester.pumpWidget(_type('sub-phones', 'Phones'));
    await _settle(tester);
    await tester.tap(find.byIcon(Icons.tune_rounded));
    await _settleRoute(tester);
    final sheet = find.byType(BottomSheet);
    expect(sheet, findsOneWidget);
    expect(find.descendant(of: sheet, matching: find.text('Storage')), findsOneWidget);
    expect(find.descendant(of: sheet, matching: find.text('Brand')), findsNothing);
  });

  testWidgets('a brand with nothing listed says so, and offers every brand', (tester) async {
    setFakeRoute((uri) {
      if (uri.path.startsWith('/listings')) {
        requested.add(uri);
        return attributesOf(uri) == null
            ? null
            : {'items': <Object?>[], 'total': 0};
      }
      return _fields(uri);
    });
    await tester.pumpWidget(_type('sub-phones', 'Phones'));
    await _settle(tester);
    await tester.tap(find.byKey(const Key('subcategory-facet-Infinix')));
    await _settle(tester);
    expect(find.text('No Infinix in Phones yet'), findsOneWidget);

    await tester.tap(find.byKey(const Key('subcategory-facet-clear')));
    await _settle(tester);
    expect(find.byType(ProductCard), findsWidgets);
    expect(attributesOf(requested.last), isNull);
  });

  testWidgets('long names survive 320-430dp, at rest and scrolled, header collapsing',
      (tester) async {
    for (final width in const [320.0, 360.0, 390.0, 430.0]) {
      tester.view.physicalSize = Size(width * 2, 760 * 2);
      tester.view.devicePixelRatio = 2.0;
      await tester.pumpWidget(
          _type('sub-phones', 'Restaurant & Catering Equipment', parent: 'Business & Industrial'));
      await _settle(tester);
      expect(tester.takeException(), isNull, reason: 'at ${width}dp, at rest');
      final full = _headerHeight(tester);

      await _scroll(tester, -700);
      expect(tester.takeException(), isNull, reason: 'at ${width}dp, scrolled');
      expect(_headerHeight(tester), lessThan(full));
      expect(_headerBackdropOpacity(tester), 1.0,
          reason: 'cards must not show through the collapsed header');
      expect(find.byIcon(Icons.arrow_back_ios_new_rounded), findsOneWidget);
      expect(find.byIcon(Icons.tune_rounded), findsOneWidget);

      await _scroll(tester, 3000);
      expect(_headerHeight(tester), closeTo(full, 0.5));
    }
    tester.view.reset();
  });

  group('See all', () {
    testWidgets('a Zone lays every type out, and each opens its screen', (tester) async {
      await tester.pumpWidget(const MaterialApp(
          home: CategoryZoneScreen(categoryId: 'Electronics', categoryName: 'Electronics')));
      await _settle(tester);
      await tester.tap(find.text('See all 3 ›'));
      await _settleRoute(tester);

      expect(find.byType(CategoryDirectoryScreen), findsOneWidget);
      expect(find.text('ELECTRONICS TYPES'), findsOneWidget);
      for (final name in const ['Sub One', 'Sub Two', 'Sub Three']) {
        expect(find.byKey(Key('directory-card-$name')), findsOneWidget, reason: name);
      }
      await tester.tap(find.byKey(const Key('directory-card-Sub Two')));
      await _settleRoute(tester);
      expect(find.text('SUB TWO'), findsOneWidget);
      expect(requested.last.queryParameters['subcategory_id'], 'sub-Sub Two');
    });

    testWidgets('Home opens every category as cards, each to its Zone', (tester) async {
      tester.view.physicalSize = const Size(390 * 3.0, 844 * 3.0);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
      await _settle(tester);
      expect(find.text('Shop by category'), findsOneWidget);
      await tester.tap(find.byKey(const Key('home-categories-see-all')));
      await _settleRoute(tester);

      expect(find.text('ALL CATEGORIES'), findsOneWidget);
      expect(find.byKey(Key('directory-card-${fakeTopLevelCategories.first}')), findsOneWidget);
      await tester.tap(find.byKey(const Key('directory-card-Property')));
      await _settleRoute(tester);
      expect(find.text('PROPERTY ZONE'), findsOneWidget);
    });

    testWidgets('Home\'s categories are pictures; its destinations are not', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
      await _settle(tester);
      final first = find.byKey(Key('home-rail-card-${fakeTopLevelCategories.first}'));
      expect(first, findsOneWidget);
      final image = tester.widget<Image>(find.descendant(of: first, matching: find.byType(Image)));
      expect(((image.image as ResizeImage).imageProvider as AssetImage).assetName,
          'assets/category_art/automobiles.webp');

      // The destinations sit at the far end of the same row.
      final rail = find.descendant(
          of: find.byKey(const Key('home-category-rail')), matching: find.byType(Scrollable));
      await tester.scrollUntilVisible(find.byKey(const Key('home-rail-card-Stores')), 300,
          scrollable: rail);
      final stores = find.byKey(const Key('home-rail-card-Stores'));
      expect(tester.widget<CategoryArtCard>(stores).assetPath, isNull);
      expect(find.descendant(of: stores, matching: find.byType(Image)), findsNothing);
    });
  });
}

Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

Future<void> _settleRoute(WidgetTester tester) async {
  for (int i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _scroll(WidgetTester tester, double dy) async {
  final state = tester.state<ScrollableState>(find.byType(Scrollable).first);
  final target = (state.position.pixels - dy).clamp(0.0, state.position.maxScrollExtent);
  state.position.jumpTo(target);
  await _settle(tester);
}

double _headerHeight(WidgetTester tester) =>
    tester.renderObject<RenderSliver>(find.byType(SliverPersistentHeader)).geometry!.paintExtent;

double _headerBackdropOpacity(WidgetTester tester) {
  final box = tester.widget<DecoratedBox>(find
      .descendant(of: find.byType(SliverPersistentHeader), matching: find.byType(DecoratedBox))
      .first);
  return (box.decoration as BoxDecoration).color!.opacity;
}
