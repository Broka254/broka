// Home's search: listings only, and the bugs the old SearchDelegate had.
//
// Every test starts from HomeScreen and taps its search bar, rather than
// pumping ListingSearchScreen directly, so each one describes what a person
// does - and so the same test run against the old _ListingSearchDelegate
// fails for the bug it names (checked when this file was written).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:broka/screens/home_screen.dart';
import 'package:broka/screens/listing_search_screen.dart';

import 'support/fake_api.dart';

void main() {
  setUpAll(installFakeApi);

  setUp(() {
    setFakeRoute(null);
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> openSearch(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await _settle(tester);
    await tester.tap(find.byIcon(Icons.search_rounded));
    await _settle(tester);
  }

  /// Types [text] and waits out the live-search debounce.
  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byType(TextField), text);
    await tester.pump(const Duration(milliseconds: 500));
    await _settle(tester);
  }

  Future<List<String>> storedHistory() async =>
      (await SharedPreferences.getInstance()).getStringList('search_history') ?? const [];

  testWidgets('opens a listing search screen', (tester) async {
    await openSearch(tester);
    expect(find.byType(ListingSearchScreen), findsOneWidget);
    expect(find.text('Find something to buy'), findsOneWidget);
  });

  testWidgets('searches listings only - never the user directory', (tester) async {
    final requested = <Uri>[];
    setFakeRoute((uri) {
      requested.add(uri);
      return null;
    });
    await openSearch(tester);
    await type(tester, 'iphone');

    final listingSearches =
        requested.where((u) => u.path.startsWith('/listings') && u.queryParameters['search'] == 'iphone');
    expect(listingSearches, isNotEmpty);
    // Home finds things to buy; people are found on the Traders screen.
    expect(requested.where((u) => u.path.startsWith('/auth/search')), isEmpty);
  });

  testWidgets('a pause while typing keeps the keyboard up', (tester) async {
    await openSearch(tester);
    await type(tester, 'iphone');
    // The delegate called showResults() after every pause, which unfocuses
    // the field: the keyboard closed mid-word.
    expect(tester.testTextInput.isVisible, isTrue);
    expect(find.text('Test item 0'), findsOneWidget);
  });

  testWidgets('only a submitted search is remembered', (tester) async {
    await openSearch(tester);
    await type(tester, 'iph');
    await type(tester, 'iphone');
    expect(await storedHistory(), isEmpty,
        reason: 'text on its way to being a search is not a search');

    await tester.testTextInput.receiveAction(TextInputAction.search);
    await _settle(tester);
    expect(await storedHistory(), ['iphone']);
  });

  testWidgets('clearing recent searches clears them on screen', (tester) async {
    SharedPreferences.setMockInitialValues({
      'search_history': ['iphone 13', 'maize'],
    });
    await openSearch(tester);
    expect(find.text('maize'), findsOneWidget);

    await tester.tap(find.textContaining('Clear').first);
    await _settle(tester);
    expect(find.text('maize'), findsNothing);
    expect(await storedHistory(), isEmpty);
  });

  testWidgets('a slow answer to an older search never replaces a newer one',
      (tester) async {
    setFakeRoute((uri) {
      if (!uri.path.startsWith('/listings')) return null;
      final q = uri.queryParameters['search'];
      // One page each: the grid asks for the next page until one comes back
      // empty.
      if (uri.queryParameters['offset'] != '0') {
        return uri.queryParameters['with_total'] == 'true'
            ? {'items': <Object?>[], 'total': 1}
            : <Object?>[];
      }
      if (q == 'ip') {
        return FakeResponse(
          [fakeListingJson(1)..['name'] = 'Slow old result'],
          delay: const Duration(seconds: 2),
        );
      }
      if (q == 'iphone') {
        final items = [fakeListingJson(2)..['name'] = 'Fresh result'];
        return uri.queryParameters['with_total'] == 'true'
            ? {'items': items, 'total': 1}
            : items;
      }
      return null;
    });
    await openSearch(tester);
    await type(tester, 'ip');
    await type(tester, 'iphone');
    expect(find.text('Fresh result'), findsOneWidget);

    // Let the old request finally answer.
    await tester.pump(const Duration(seconds: 3));
    await _settle(tester);
    expect(find.text('Fresh result'), findsOneWidget);
    expect(find.text('Slow old result'), findsNothing);
  });

  testWidgets('a failed search offers a retry instead of "no listings"',
      (tester) async {
    setFakeRoute((uri) => uri.path.startsWith('/listings') && uri.queryParameters['search'] != null
        ? const FakeResponse.error()
        : null);
    await openSearch(tester);
    await type(tester, 'iphone');
    expect(find.text("Couldn't load listings"), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.textContaining('No listings'), findsNothing);
  });

  testWidgets('results show the total and the chosen order reaches the backend',
      (tester) async {
    final requested = <Uri>[];
    setFakeRoute((uri) {
      if (uri.path.startsWith('/listings')) requested.add(uri);
      return null;
    });
    await openSearch(tester);
    await type(tester, 'phone');
    expect(find.text('128 results'), findsOneWidget);

    await tester.tap(find.byKey(const Key('listing-search-sort')));
    await _settle(tester);
    await tester.tap(find.text('Price: low to high').last);
    await _settle(tester);
    expect(requested.last.queryParameters['sort'], 'price_low');
    expect(requested.last.queryParameters['search'], 'phone');
  });

  testWidgets('no match offers Zeno', (tester) async {
    setFakeRoute((uri) => uri.path.startsWith('/listings') && uri.queryParameters['search'] != null
        ? {'items': <Object?>[], 'total': 0}
        : null);
    await openSearch(tester);
    await type(tester, 'hovercraft');
    expect(find.text('No listings match "hovercraft"'), findsOneWidget);
    expect(find.text('Ask Zeno to find it'), findsOneWidget);
  });

  testWidgets('nothing overflows on a 320dp phone at a large text size',
      (tester) async {
    tester.view.physicalSize = const Size(320 * 2, 640 * 2);
    tester.view.devicePixelRatio = 2.0;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    SharedPreferences.setMockInitialValues({
      'search_history': ['a very long search someone typed for a used laptop'],
    });
    await openSearch(tester);
    expect(tester.takeException(), isNull);
    await type(tester, 'I need a laptop for school under 40000 shillings');
    expect(tester.takeException(), isNull);
    expect(find.text('Ask Zeno'), findsOneWidget);
  });

  group('looksLikeBuyingRequest', () {
    test('a product name is just a search', () {
      expect(looksLikeBuyingRequest('iPhone 13 Pro'), isFalse);
    });
    test('a described need with a budget is offered to Zeno', () {
      expect(looksLikeBuyingRequest('I need a laptop for school under 40000'), isTrue);
    });
  });
}

/// pumpAndSettle never returns on these screens (the constellation animates
/// forever), so a fixed handful of frames.
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}
