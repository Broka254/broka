// Today's free Zeno sessions (2026-11-12, backend premium/zeno_sessions.py):
// a free account asks Zeno about two listings a day and starts two Buying
// Agent hunts. Used up, the server refuses with a 402 ZENO_SESSIONS_USED
// whose words say when they come back. It names a plan to buy only while
// one is on sale (upgrade_to) - with none on sale, a sheet of plans would
// be an offer of nothing.
//
// Also here: a listing's "Find me something similar", which reaches the
// Buying Agent knowing the listing it came from.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:broka/features/premium/presentation/premium_upsell.dart';
import 'package:broka/features/zeno_assistant/domain/zeno_about_listing.dart';
import 'package:broka/features/zeno_assistant/domain/zeno_action.dart';
import 'package:broka/features/zeno_assistant/domain/zeno_sessions.dart';
import 'package:broka/features/zeno_assistant/presentation/zeno_session_host.dart';
import 'package:broka/features/zeno_assistant/zeno_session.dart';
import 'package:broka/screens/zeno_screen.dart';

import 'support/fake_api.dart';

const _iphone = ZenoAboutListing(
  id: 'listing-1',
  name: 'iPhone 13 128GB',
  priceLabel: 'KES 78,000',
  emoji: '📱',
  negotiable: true,
  delivers: true,
);

/// The 402 premium/zeno_sessions.py sends, with or without a plan to offer.
FakeResponse _sessionsUsed(String message, {String? upgradeTo, String kind = 'listing'}) =>
    FakeResponse({
      'detail': {
        'code': 'ZENO_SESSIONS_USED',
        'message': message,
        'feature': 'zeno_${kind}_sessions',
        'plan': null,
        'upgrade_to': upgradeTo,
        'limit': 2,
        'renews_at': '2026-11-12T21:00:00',
      },
    }, statusCode: 402);

const _listingsUsed = "You've asked Zeno about 2 listings today - the free limit. "
    'Every question about a listing counts once a day, and they renew at midnight.';
const _huntsUsed = "You've used today's 2 free Buying Agent hunts. "
    'A hunt counts once however long it runs, and they renew at midnight.';

void main() {
  setUpAll(() {
    installFakeApi();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in ['xyz.luan/audioplayers', 'xyz.luan/audioplayers.global']) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
  });

  setUp(() {
    clearFakeRequests();
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() => setFakeRoute(null));

  Widget app(Widget home) {
    final session = ZenoSession();
    return MaterialApp(
      home: home,
      navigatorObservers: [session.routes],
      builder: (context, child) => ZenoSessionHost(session: session, child: child!),
      onGenerateRoute: (s) => MaterialPageRoute(
        settings: s,
        builder: (_) => Scaffold(body: Text('route ${s.name}')),
      ),
    );
  }

  /// Runs the clock in frames: Zeno's screen never settles.
  Future<void> run(WidgetTester tester, Duration total) async {
    final end = tester.binding.clock.now().add(total);
    while (tester.binding.clock.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> until(WidgetTester tester, Finder finder,
      {Duration limit = const Duration(seconds: 8)}) async {
    final end = tester.binding.clock.now().add(limit);
    while (finder.evaluate().isEmpty && tester.binding.clock.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(finder, findsWidgets);
  }

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const Key('zeno-composer')), text);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump();
  }

  List<Map> huntTurns() => [
        for (final r in fakeRequests)
          if (r.uri.path.startsWith('/buy-agent-requests/converse')) r.json as Map,
      ];

  group("today's questions about listings, used up", () {
    testWidgets('while no plan is on sale: Zeno says when they come back, and offers nothing to buy',
        (tester) async {
      setFakeRoute((uri) => uri.path == '/zeno/assistant/turn' ? _sessionsUsed(_listingsUsed) : null);
      await tester.pumpWidget(app(const ZenoScreen(animateBackground: false, aboutListing: _iphone)));
      await run(tester, const Duration(milliseconds: 400));
      await type(tester, 'Is this a fair price?');
      await run(tester, const Duration(seconds: 2));
      expect(find.textContaining('the free limit'), findsWidgets);
      expect(find.byKey(const Key('upsell-see-plans')), findsNothing);
    });

    testWidgets('with a plan on sale, the plans are one tap away', (tester) async {
      setFakeRoute((uri) => uri.path == '/zeno/assistant/turn'
          ? _sessionsUsed('$_listingsUsed Ask about as many as you like with BROKA Plus.', upgradeTo: 'plus')
          : null);
      await tester.pumpWidget(app(const ZenoScreen(animateBackground: false, aboutListing: _iphone)));
      await run(tester, const Duration(milliseconds: 400));
      await type(tester, 'Is this a fair price?');
      await run(tester, const Duration(seconds: 2));
      expect(find.byKey(const Key('upsell-see-plans')), findsOneWidget);
    });
  });

  group("today's Buying Agent hunts, used up", () {
    Widget agent() => app(const ZenoScreen(mode: ZenoMode.buyingAgent, animateBackground: false));

    testWidgets('while no plan is on sale: Zeno says when they come back, and offers nothing to buy',
        (tester) async {
      setFakeRoute((uri) => uri.path.startsWith('/buy-agent-requests/converse')
          ? _sessionsUsed(_huntsUsed, kind: 'agent')
          : null);
      await tester.pumpWidget(agent());
      await run(tester, const Duration(milliseconds: 500));
      await type(tester, 'a sofa');
      await run(tester, const Duration(seconds: 3));
      expect(find.textContaining("used today's 2 free Buying Agent hunts"), findsWidgets);
      expect(find.textContaining("couldn't get that search through"), findsNothing,
          reason: 'not an error to try again: it would be refused the same way');
      expect(find.byKey(const Key('upsell-see-plans')), findsNothing);
    });

    testWidgets('with a plan on sale, the plans are one tap away', (tester) async {
      setFakeRoute((uri) => uri.path.startsWith('/buy-agent-requests/converse')
          ? _sessionsUsed('$_huntsUsed With BROKA Plus Zeno hunts as often as you like.',
              upgradeTo: 'plus', kind: 'agent')
          : null);
      await tester.pumpWidget(agent());
      await run(tester, const Duration(milliseconds: 500));
      await type(tester, 'a sofa');
      await run(tester, const Duration(seconds: 3));
      expect(find.byKey(const Key('upsell-see-plans')), findsOneWidget);
    });
  });

  group('"Find me something similar" on a listing', () {
    // It came out as a hunt for the words "something similar", with
    // nothing to say what they were similar to (backend
    // zeno_assistant/service.py, _aim_at_listing).
    const offer = {
      'type': 'FIND_FOR_ME',
      'query': 'Something like iPhone 13 128GB',
      'requires_confirmation': true,
      'slots': {'category': 'Electronics', 'subcategory': 'Phones', 'query': 'iPhone 13 128GB'},
      'from_listing_id': 'listing-1',
    };

    testWidgets('hands the Buying Agent the listing, and every turn of the hunt carries it',
        (tester) async {
      setFakeRoute((uri) {
        if (uri.path == '/zeno/assistant/turn') {
          return {'reply': 'Want me to find phones like this one?', 'action': offer};
        }
        if (uri.path.startsWith('/buy-agent-requests/converse')) {
          return {
            'reply': "What's your budget?",
            'phase': 'ASKING',
            'slots': {'category': 'Electronics', 'subcategory': 'Phones', 'query': 'iPhone 13 128GB'},
            'questions_asked': 1,
          };
        }
        return null;
      });
      await tester.pumpWidget(app(const ZenoScreen(animateBackground: false, aboutListing: _iphone)));
      await run(tester, const Duration(milliseconds: 400));
      await type(tester, 'Find me something similar');
      await until(tester, find.text('Find it'));
      await tester.ensureVisible(find.text('Find it'));
      await tester.pump();
      await tester.tap(find.text('Find it'));
      await run(tester, const Duration(seconds: 2));

      final agent = tester.widget<ZenoScreen>(find.byType(ZenoScreen).last);
      expect(agent.mode, ZenoMode.buyingAgent);
      expect(agent.fromListingId, 'listing-1');
      final first = huntTurns().first;
      expect(first['message'], 'Something like iPhone 13 128GB');
      expect(first['from_listing_id'], 'listing-1');
      expect(first['slots'], {'category': 'Electronics', 'subcategory': 'Phones', 'query': 'iPhone 13 128GB'});

      await until(tester, find.text("What's your budget?"));
      await type(tester, 'under 60k');
      await run(tester, const Duration(seconds: 2));
      expect(huntTurns().map((t) => t['from_listing_id']), everyElement('listing-1'));
      expect(huntTurns(), hasLength(2));
    });

    test('a hunt the buyer starts in their own words carries no listing', () {
      final own = ZenoAction.fromJson({'type': 'FIND_FOR_ME', 'query': 'a phone with 256GB'})!;
      expect(own.slots, isEmpty);
      expect(own.fromListingId, isNull);
      final similar = ZenoAction.fromJson(offer)!;
      expect(similar.slots['category'], 'Electronics');
      expect(similar.fromListingId, 'listing-1');
      // A search is the search screen's: nothing to hand over.
      final search = ZenoAction.fromJson({...offer, 'type': 'SEARCH'})!;
      expect(search.slots, isEmpty);
      expect(search.fromListingId, isNull);
    });
  });

  group('the day as the app reads it', () {
    test('GET /zeno/sessions/today', () {
      final s = ZenoSessionsToday.fromJson({
        'limited': true,
        'day': '2026-11-12',
        'renews_at': '2026-11-12T21:00:00',
        'listing': {'limit': 2, 'used': 1, 'left': 1, 'listing_ids': ['listing-7', '', 3]},
        'agent': {'limit': 2, 'used': 2, 'left': 0},
      })!;
      expect(s.limited, isTrue);
      expect((s.listingLimit, s.listingLeft, s.agentLimit, s.agentLeft), (2, 1, 2, 0));
      expect(s.listingIds, {'listing-7'});
      expect(s.covers('listing-7'), isTrue, reason: 'asked about today: no new session');
      expect(s.covers('listing-8'), isFalse);
    });

    test('with a plan nothing is counted, and an answer it cannot read is no answer', () {
      final planned = ZenoSessionsToday.fromJson({
        'limited': false,
        'listing': {'limit': null, 'used': 4, 'left': null, 'listing_ids': <String>[]},
        'agent': {'limit': null, 'used': 1, 'left': null},
      })!;
      expect(planned.covers('listing-8'), isTrue);
      expect(planned.listingLeft, isNull);
      expect(ZenoSessionsToday.fromJson(null), isNull);
      expect(ZenoSessionsToday.fromJson({'detail': 'Not Found'}), isNull);
    });

    test('only a refusal with no plan to buy goes without the plans', () {
      expect(offersPlans('ZENO_SESSIONS_USED', {'upgrade_to': null}), isFalse);
      expect(offersPlans('ZENO_SESSIONS_USED', null), isFalse);
      expect(offersPlans('ZENO_SESSIONS_USED', {'upgrade_to': 'plus'}), isTrue);
      // Every other refusal offers them, as before.
      expect(offersPlans('PREMIUM_REQUIRED', {'upgrade_to': null}), isTrue);
      expect(offersPlans(null, null), isTrue);
    });
  });
}
