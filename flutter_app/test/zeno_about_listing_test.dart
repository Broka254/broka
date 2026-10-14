// Zeno, opened from a listing's "Ask Zeno" card (2026-09-29): the listing
// pinned under the header, questions about it, its id on every turn so the
// server can read it to Zeno (zeno_assistant/listing_context.py), and - when
// it doesn't fit - a search Zeno offers and the buyer takes or leaves,
// instead of one that simply happens.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:broka/features/zeno_assistant/domain/zeno_about_listing.dart';
import 'package:broka/features/zeno_assistant/presentation/zeno_session_host.dart';
import 'package:broka/features/zeno_assistant/zeno_session.dart';
import 'package:broka/screens/zeno_screen.dart';
import 'package:broka/services/zeno_chat_store.dart';

import 'support/fake_api.dart';

const _iphone = ZenoAboutListing(
  id: 'listing-1',
  name: 'iPhone 13 128GB',
  priceLabel: 'KES 78,000',
  emoji: '📱',
  negotiable: false,
  delivers: true,
);

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

  /// The app as main.dart builds it, with Zeno's session above the
  /// Navigator - which a conversation about a listing must not go through.
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

  Future<void> run(WidgetTester tester, Duration total) async {
    final end = tester.binding.clock.now().add(total);
    while (tester.binding.clock.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Pumps until [finder] shows, for at most [limit]. Zeno writes a reply
  /// out at a randomised pace (ZenoStreamingText) and shows its action card
  /// only once the last word lands, so a fixed wait is a guess.
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

  void answer(String reply, [Map<String, dynamic>? action]) => setFakeRoute((uri) {
        if (uri.path == '/zeno/assistant/turn') return {'reply': reply, 'action': action};
        return null;
      });

  List<Map> turnsSent() => [
        for (final r in fakeRequests)
          if (r.uri.path == '/zeno/assistant/turn') r.json as Map,
      ];

  testWidgets('the listing is pinned, the suggestions are about it, and every turn carries its id',
      (tester) async {
    answer('It comes with the box, but no charger.');
    await tester.pumpWidget(app(const ZenoScreen(animateBackground: false, aboutListing: _iphone)));
    await run(tester, const Duration(milliseconds: 400));

    final strip = find.byKey(const Key('zeno-about-listing'));
    expect(find.descendant(of: strip, matching: find.text('iPhone 13 128GB')), findsOneWidget);
    expect(find.descendant(of: strip, matching: find.text('Fixed price')), findsOneWidget);
    expect(find.descendant(of: strip, matching: find.text('Delivers')), findsOneWidget);
    expect(find.textContaining('Ask me anything about "iPhone 13 128GB"'), findsOneWidget);
    expect(find.text('Is this a fair price?'), findsOneWidget);
    // A fixed price has no offer to make.
    expect(find.text('What offer should I make?'), findsNothing);

    await type(tester, 'does it come with a charger?');
    await run(tester, const Duration(milliseconds: 600));
    await type(tester, 'and the battery?');
    await run(tester, const Duration(milliseconds: 600));
    expect(turnsSent().map((t) => t['listing_id']), ['listing-1', 'listing-1']);
    await until(tester, find.text('It comes with the box, but no charger.'));
  });

  testWidgets('the general assistant sends no listing', (tester) async {
    answer('Hello!');
    await tester.pumpWidget(app(const ZenoScreen(animateBackground: false)));
    await run(tester, const Duration(milliseconds: 400));
    expect(find.byKey(const Key('zeno-about-listing')), findsNothing);
    await type(tester, 'hi');
    await run(tester, const Duration(milliseconds: 600));
    expect(turnsSent().single.containsKey('listing_id'), isFalse);
  });

  group('a search Zeno offers', () {
    const offer = {
      'type': 'FIND_FOR_ME',
      'query': 'phone with 256GB',
      'requires_confirmation': true,
    };

    testWidgets('waits for the buyer, then goes where it said', (tester) async {
      answer('This one has 128GB. Want me to find one with 256GB?', offer);
      await tester.pumpWidget(app(const ZenoScreen(animateBackground: false, aboutListing: _iphone)));
      await run(tester, const Duration(milliseconds: 400));
      await type(tester, 'I need 256GB');
      await until(tester, find.text('Find it'));
      // Long past the beat after which a search runs by itself.
      await run(tester, const Duration(seconds: 3));
      expect(find.byType(ZenoScreen), findsOneWidget, reason: 'nothing opened by itself');
      expect(find.text('Find something that fits?'), findsOneWidget);
      expect(find.text('"phone with 256GB"'), findsOneWidget);

      await tester.ensureVisible(find.text('Find it'));
      await tester.tap(find.text('Find it'));
      await run(tester, const Duration(seconds: 1));
      final agent = tester.widget<ZenoScreen>(find.byType(ZenoScreen).last);
      expect(agent.mode, ZenoMode.buyingAgent);
      expect(agent.initialQuery, 'phone with 256GB');
    });

    testWidgets('"Not now" leaves the buyer where they are', (tester) async {
      answer('Want me to look for "phone with 256GB" instead?', offer);
      await tester.pumpWidget(app(const ZenoScreen(animateBackground: false, aboutListing: _iphone)));
      await run(tester, const Duration(milliseconds: 400));
      await type(tester, 'too small');
      await until(tester, find.text('Not now'));
      await tester.ensureVisible(find.text('Not now'));
      await tester.tap(find.text('Not now'));
      await run(tester, const Duration(seconds: 2));
      expect(find.byType(ZenoScreen), findsOneWidget);
      expect(find.text('Not searching'), findsOneWidget);
      expect(find.text('Find it'), findsNothing);
    });
  });

  group('the conversation', () {
    ZenoConversation saved(String listingId) => ZenoConversation(
          turns: const [
            ZenoStoredTurn(role: 'user', content: 'Is it new?'),
            ZenoStoredTurn(role: 'broker', content: 'It is used - battery at 89%.'),
          ],
          history: const [
            {'role': 'user', 'content': 'Is it new?'},
            {'role': 'assistant', 'content': 'It is used - battery at 89%.'},
          ],
          aboutListing: listingId,
          savedAt: DateTime.now(),
        );

    testWidgets('about the same listing, it is picked up again', (tester) async {
      await ZenoChatStore.save('listing', saved('listing-1'));
      await tester.pumpWidget(app(const ZenoScreen(animateBackground: false, aboutListing: _iphone)));
      await run(tester, const Duration(milliseconds: 400));
      expect(find.text('Is it new?'), findsOneWidget);
    });

    testWidgets('about another listing, it starts afresh', (tester) async {
      await ZenoChatStore.save('listing', saved('listing-other'));
      await tester.pumpWidget(app(const ZenoScreen(animateBackground: false, aboutListing: _iphone)));
      await run(tester, const Duration(milliseconds: 400));
      expect(find.text('Is it new?'), findsNothing);
      expect(find.textContaining('Ask me anything about "iPhone 13 128GB"'), findsOneWidget);
    });

    testWidgets("is kept apart from the general assistant's", (tester) async {
      answer('Used, 89% battery.');
      await ZenoChatStore.save('assistant', saved('unused'));
      await tester.pumpWidget(app(const ZenoScreen(animateBackground: false, aboutListing: _iphone)));
      await run(tester, const Duration(milliseconds: 400));
      await type(tester, 'what condition is it in?');
      await run(tester, const Duration(milliseconds: 600));
      final general = await ZenoChatStore.load('assistant');
      expect(general!.turns.map((t) => t.content), ['Is it new?', 'It is used - battery at 89%.']);
      final about = await ZenoChatStore.load('listing');
      expect(about!.aboutListing, 'listing-1');
      expect(about.turns.map((t) => t.content), contains('what condition is it in?'));
    });
  });
}
