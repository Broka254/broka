// The Buying Agent's screen after the motion pass (2026-09-26): what it
// shows while it works, and the weak spots that pass found in the screen.
// Each test in the "weak spots" group failed on the code before it (see
// CHANGES.md).
//
// "The agent's room" covers the HUD pass (2026-10-09, agent_hud.dart).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:broka/features/buy_agent/presentation/widgets/agent_hud.dart';
import 'package:broka/screens/zeno_screen.dart';
import 'package:broka/services/zeno_chat_store.dart';

import 'support/fake_api.dart';

void main() {
  setUpAll(() {
    installFakeApi();
    // BrokaTts owns an AudioPlayer; nothing plays in these tests.
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

  Widget agent({bool still = false}) {
    const screen = ZenoScreen(mode: ZenoMode.buyingAgent);
    return MaterialApp(
      // The real screen's MediaQuery with animations off - a bare
      // MediaQueryData would also make the screen zero pixels wide.
      home: still
          ? Builder(
              builder: (context) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(disableAnimations: true), child: screen))
          : screen,
      // Where a card or a button leads, by name, so a test can see it went.
      onGenerateRoute: (s) => MaterialPageRoute(
          settings: s, builder: (_) => Scaffold(body: Text('route ${s.name}'))),
    );
  }

  /// Runs the clock in frames. pumpAndSettle never returns here - the
  /// constellation and the agent's rings turn for as long as it is open.
  Future<void> run(WidgetTester tester, Duration total) async {
    final end = tester.binding.clock.now().add(total);
    while (tester.binding.clock.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Types [text] and sends it; returns as the tap lands.
  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const Key('zeno-composer')), text);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump();
  }

  Map lastConverse() => fakeRequests
      .lastWhere((r) => r.uri.path.startsWith('/buy-agent-requests/converse'))
      .json as Map;

  List<Map> actionsSent() => [
        for (final r in fakeRequests)
          if (r.uri.path.startsWith('/buy-agent-requests/action')) r.json as Map,
      ];

  Object? emptySearch(Uri uri, {Map<String, dynamic>? slots}) {
    if (uri.path.startsWith('/buy-agent-requests/converse')) {
      return {
        'reply': 'Nothing yet.',
        'phase': 'RESULTS',
        'verdict': 'EMPTY',
        'matches': const [],
        'slots': slots ?? {'query': 'sofa', 'category': 'Home & Furniture'},
        'questions_asked': 0,
      };
    }
    if (uri.path.startsWith('/buy-agent-requests/action')) {
      return {'action': 'CREATE_BUYING_REQUEST', 'status': 'SUCCESS', 'request': {'status': 'active'}};
    }
    return null;
  }

  group('weak spots', () {
    testWidgets('a reply to a conversation that was started over stays out of the new one',
        (tester) async {
      // New chat was offered while Zeno was still answering, and the answer
      // landed in the new conversation anyway - with the old one's
      // criteria, which the next turn then sent back as the new search's.
      var slow = true;
      setFakeRoute((uri) {
        if (!uri.path.startsWith('/buy-agent-requests/converse')) return null;
        if (slow) {
          return const FakeResponse({
            'reply': 'Which laptop?',
            'phase': 'ASKING',
            'slots': {'category': 'Electronics', 'query': 'laptop'},
            'questions_asked': 1,
          }, delay: Duration(seconds: 2));
        }
        return {'reply': 'What kind of sofa?', 'phase': 'ASKING', 'slots': {'query': 'sofa'}, 'questions_asked': 1};
      });
      await tester.pumpWidget(agent());
      await run(tester, const Duration(milliseconds: 500));
      await type(tester, 'a laptop');
      await run(tester, const Duration(milliseconds: 300));

      await tester.tap(find.byTooltip('New chat'));
      await run(tester, const Duration(milliseconds: 400));
      await tester.tap(find.text('New chat').last);
      await run(tester, const Duration(seconds: 3));
      expect(find.text('Which laptop?'), findsNothing);
      expect(find.text('a laptop'), findsNothing);

      slow = false;
      clearFakeRequests();
      await type(tester, 'a sofa');
      await run(tester, const Duration(seconds: 3));
      final sent = lastConverse();
      expect(sent.containsKey('slots'), isFalse,
          reason: "the old conversation's criteria went with it");
      expect(sent['questions_asked'], 0);
      expect((sent['history'] as List).map((h) => (h as Map)['content']),
          isNot(contains('Which laptop?')));
    });

    testWidgets("a quick turn's searching caption does not turn up on the next turn",
        (tester) async {
      // The caption waited on a Future.delayed nothing could cancel, so the
      // first turn's timer fired into the second turn and announced a
      // search 2.2s after the FIRST message rather than the second.
      var turn = 0;
      setFakeRoute((uri) {
        if (!uri.path.startsWith('/buy-agent-requests/converse')) return null;
        turn++;
        return FakeResponse({
          'reply': turn == 1 ? 'Which one?' : 'And the budget?',
          'phase': 'ASKING',
          'slots': {'query': 'iphone'},
          'questions_asked': 1,
        }, delay: turn == 1 ? Duration.zero : const Duration(seconds: 4));
      });
      await tester.pumpWidget(agent());
      await run(tester, const Duration(milliseconds: 500));
      await type(tester, 'an iPhone'); // t = 0
      await run(tester, const Duration(milliseconds: 200));
      await type(tester, 'the 14'); // t = 0.45s
      await run(tester, const Duration(milliseconds: 1850)); // t = 2.3s
      expect(find.text('Scanning Broka listings…'), findsNothing);
      await run(tester, const Duration(milliseconds: 700)); // 2.55s into the second
      expect(find.text('Scanning Broka listings…'), findsOneWidget);
      await run(tester, const Duration(seconds: 3));
    });

    testWidgets('the budget is grouped as it is typed, and read back whole', (tester) async {
      setFakeRoute((uri) => emptySearch(uri));
      await tester.pumpWidget(agent());
      await run(tester, const Duration(milliseconds: 500));
      await type(tester, 'a sofa');
      await run(tester, const Duration(seconds: 3));

      await tester.tap(find.text('Keep watching for me'));
      await run(tester, const Duration(milliseconds: 500));
      await tester.enterText(find.byType(TextField).last, '80000');
      await tester.pump();
      expect(tester.widget<EditableText>(find.byType(EditableText).last).controller.text, '80,000');
      await tester.tap(find.text('Watch for it'));
      await run(tester, const Duration(milliseconds: 800));

      final sent = actionsSent();
      expect(sent, hasLength(1));
      expect((sent.single['parameters'] as Map)['max_price'], 80000);
      expect(find.text("I'll keep watching and tell you when something turns up."), findsOneWidget);
    });

    testWidgets("a budget Zeno can't read keeps the question open", (tester) async {
      // Anything but a plain number - nothing, "cheap" - closed the dialog
      // without a word: no watch, no error, as if the button did nothing.
      setFakeRoute((uri) => emptySearch(uri));
      await tester.pumpWidget(agent());
      await run(tester, const Duration(milliseconds: 500));
      await type(tester, 'a sofa');
      await run(tester, const Duration(seconds: 3));

      await tester.tap(find.text('Keep watching for me'));
      await run(tester, const Duration(milliseconds: 500));
      await tester.enterText(find.byType(TextField).last, 'cheap');
      await tester.tap(find.text('Watch for it'));
      await run(tester, const Duration(milliseconds: 500));

      expect(find.text("What's your ceiling?"), findsOneWidget);
      expect(find.textContaining('Enter an amount'), findsOneWidget);
      expect(actionsSent(), isEmpty);

      // And a real amount still goes through from there.
      await tester.enterText(find.byType(TextField).last, '45000');
      await tester.tap(find.text('Watch for it'));
      await run(tester, const Duration(milliseconds: 800));
      expect((actionsSent().single['parameters'] as Map)['max_price'], 45000);
    });

    testWidgets('without a category it says so before asking for a budget', (tester) async {
      // The budget was asked for first, and only then was the buyer told
      // the watch could not be set up anyway.
      setFakeRoute((uri) => emptySearch(uri, slots: {'query': 'something nice'}));
      await tester.pumpWidget(agent());
      await run(tester, const Duration(milliseconds: 500));
      await type(tester, 'something nice');
      await run(tester, const Duration(seconds: 3));

      await tester.tap(find.text('Keep watching for me'));
      await run(tester, const Duration(milliseconds: 500));
      expect(find.text("What's your ceiling?"), findsNothing);
      expect(find.textContaining('what kind of thing it is'), findsOneWidget);
      expect(actionsSent(), isEmpty);
    });

    testWidgets('a watch stopped from Home is not shown as still running', (tester) async {
      // The conversation remembered "watching" on the phone, so after the
      // watch was stopped on Home (or ran out) Zeno still said it was
      // keeping watch - and offered nothing to start another.
      await ZenoChatStore.save('buying', ZenoConversation(
        turns: const [
          ZenoStoredTurn(role: 'user', content: 'a sofa'),
          ZenoStoredTurn(role: 'broker', content: 'Nothing yet.'),
        ],
        history: const [
          {'role': 'user', 'content': 'a sofa'},
          {'role': 'assistant', 'content': 'Nothing yet.'},
        ],
        slots: const {'query': 'sofa', 'category': 'Home & Furniture', 'max_price': 40000},
        lastVerdict: 'EMPTY',
        watching: true,
        savedAt: DateTime.now(),
      ));
      // GET /buy-agent-requests/me answers null: no watch running.
      await tester.pumpWidget(agent());
      await run(tester, const Duration(seconds: 1));

      expect(find.text("I'll keep watching and tell you when something turns up."), findsNothing);
      expect(find.text('Keep watching for me'), findsOneWidget);
    });

    testWidgets('the same listing found by two searches can still be opened', (tester) async {
      // Every card carries a Hero tagged with its listing id. Two searches
      // in one conversation often return the same listing, and two Heroes
      // with one tag on a screen is an assertion the moment either is
      // tapped (and, in a release build, a photo flying from the wrong one).
      tester.view.physicalSize = const Size(800, 3200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      setFakeRoute((uri) => uri.path.startsWith('/buy-agent-requests/converse')
          ? {
              'reply': 'Found one.',
              'phase': 'RESULTS',
              'verdict': 'EXACT',
              'matches': [fakeListingJson(1)..['match_is_exact'] = true],
              'slots': {'query': 'item', 'category': 'Electronics'},
              'questions_asked': 0,
            }
          : null);
      await tester.pumpWidget(agent());
      await run(tester, const Duration(milliseconds: 500));
      await type(tester, 'item one');
      await run(tester, const Duration(seconds: 3));
      await type(tester, 'show me that again');
      await run(tester, const Duration(seconds: 3));
      expect(find.text('Test item 1'), findsNWidgets(2));

      await tester.tap(find.text('Test item 1').last);
      await run(tester, const Duration(milliseconds: 800));
      expect(tester.takeException(), isNull);
      expect(find.text('route /product'), findsOneWidget);
    });

    testWidgets('a failed turn can be tried again without repeating itself', (tester) async {
      // A failure left the buyer to type it all again, and left their
      // message in the context unanswered - so the retyped one went to
      // Zeno twice.
      var calls = 0;
      setFakeRoute((uri) {
        if (!uri.path.startsWith('/buy-agent-requests/converse')) return null;
        calls++;
        if (calls == 1) return const FakeResponse.error();
        return {'reply': 'Which storage size?', 'phase': 'ASKING', 'slots': {'query': 'iphone'}, 'questions_asked': 1};
      });
      await tester.pumpWidget(agent());
      await run(tester, const Duration(milliseconds: 500));
      await type(tester, 'an iPhone 14');
      await run(tester, const Duration(seconds: 3));
      expect(find.textContaining("couldn't get that search through"), findsOneWidget);

      clearFakeRequests();
      await tester.tap(find.text('Try again'));
      await run(tester, const Duration(seconds: 3));
      final sent = lastConverse();
      expect(sent['message'], 'an iPhone 14');
      expect((sent['history'] as List).map((h) => (h as Map)['content']),
          isNot(contains('an iPhone 14')));
      expect(find.text('an iPhone 14'), findsOneWidget);
      expect(find.textContaining("couldn't get that search through"), findsNothing);
      expect(find.text('Which storage size?'), findsOneWidget);
    });
  });

  group('the agent at work', () {
    testWidgets('an empty agent shows its core and how it works, until the first message',
        (tester) async {
      setFakeRoute((uri) => uri.path.startsWith('/buy-agent-requests/converse')
          ? {'reply': 'Which storage size?', 'phase': 'ASKING', 'slots': {'query': 'iphone'}, 'questions_asked': 1}
          : null);
      await tester.pumpWidget(agent());
      await run(tester, const Duration(milliseconds: 1500));
      expect(find.text('Your Buying Agent'), findsOneWidget);
      expect(find.text('I negotiate'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await type(tester, 'an iPhone');
      await run(tester, const Duration(seconds: 3));
      expect(find.text('Your Buying Agent'), findsNothing);
    });

    testWidgets('what Zeno has gathered shows as its brief', (tester) async {
      setFakeRoute((uri) => uri.path.startsWith('/buy-agent-requests/converse')
          ? {
              'reply': 'Anything else?',
              'phase': 'ASKING',
              'slots': {
                'query': 'iPhone 14',
                'category': 'Electronics',
                'max_price': 60000,
                'condition': 'used',
                'attributes': {'Storage': '256GB'},
              },
              'questions_asked': 1,
            }
          : null);
      await tester.pumpWidget(agent());
      await run(tester, const Duration(milliseconds: 500));
      await type(tester, 'a used iPhone 14, 256GB, under 60k');
      await run(tester, const Duration(seconds: 3));

      expect(find.text('iPhone 14'), findsOneWidget);
      expect(find.text('Under KES 60,000'), findsOneWidget);
      expect(find.text('Used'), findsOneWidget);
      expect(find.text('Storage: 256GB'), findsOneWidget);
    });

    testWidgets('results are dealt as cards to swipe through, with the verdict on top',
        (tester) async {
      setFakeRoute((uri) => uri.path.startsWith('/buy-agent-requests/converse')
          ? {
              'reply': 'Closest I could get is three.',
              'phase': 'RESULTS',
              'verdict': 'PARTIAL',
              'matches': [
                for (var i = 1; i <= 3; i++)
                  fakeListingJson(i)
                    ..['match_misses'] = [
                      {'field': 'max_price', 'wanted': 'KES 1,000', 'actual': 'KES 1,300'},
                    ],
              ],
              'slots': {'query': 'item', 'category': 'Electronics', 'max_price': 1000},
              'questions_asked': 0,
            }
          : null);
      await tester.pumpWidget(agent());
      await run(tester, const Duration(milliseconds: 500));
      await type(tester, 'an item under 1000');
      await run(tester, const Duration(seconds: 4));

      expect(find.text('3 close options'), findsOneWidget);
      expect(find.text('1 / 3'), findsOneWidget);
      expect(find.text('Price KES 1,300, you wanted KES 1,000'), findsWidgets);

      await tester.drag(find.text('Test item 1'), const Offset(-400, 0));
      await run(tester, const Duration(milliseconds: 800));
      expect(find.text('2 / 3'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('under reduced motion everything is there, and nothing moves to get there',
        (tester) async {
      setFakeRoute((uri) => uri.path.startsWith('/buy-agent-requests/converse')
          ? {
              'reply': 'Found it.',
              'phase': 'RESULTS',
              'verdict': 'EXACT',
              'matches': [fakeListingJson(1)..['match_is_exact'] = true],
              'slots': {'query': 'item', 'category': 'Electronics', 'max_price': 2000},
              'questions_asked': 0,
            }
          : null);
      await tester.pumpWidget(agent(still: true));
      await run(tester, const Duration(milliseconds: 300));
      expect(find.text('Your Buying Agent'), findsOneWidget);
      await type(tester, 'an item');
      await run(tester, const Duration(milliseconds: 600));
      expect(find.text('Found it.'), findsOneWidget);
      expect(find.text('Test item 1'), findsOneWidget);
      expect(find.text('1 exact match'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group("the agent's room", () {
    testWidgets('a holographic room of its own, a HUD header, and the agent online', (tester) async {
      await tester.pumpWidget(agent());
      await run(tester, const Duration(seconds: 2));
      expect(find.byType(AgentHoloBackdrop), findsOneWidget);
      expect(find.byType(AgentHudBeam), findsOneWidget);
      expect(find.text('BUYING AGENT'), findsOneWidget, reason: "the header's state tag");
      expect(find.text('AGENT ONLINE · READY FOR YOUR BRIEF'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the assistant keeps the constellation', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: ZenoScreen(animateBackground: false)));
      await run(tester, const Duration(milliseconds: 500));
      expect(find.byType(AgentHoloBackdrop), findsNothing);
      expect(find.byType(AgentHudBeam), findsNothing);
    });

    testWidgets('while Zeno thinks: waves, and the header says so', (tester) async {
      setFakeRoute((uri) => uri.path.startsWith('/buy-agent-requests/converse')
          ? const FakeResponse({
              'reply': 'Which storage size?',
              'phase': 'ASKING',
              'slots': {'query': 'iphone'},
              'questions_asked': 1,
            }, delay: Duration(seconds: 1))
          : null);
      await tester.pumpWidget(agent());
      await run(tester, const Duration(milliseconds: 500));
      await type(tester, 'an iPhone');
      await run(tester, const Duration(milliseconds: 300));
      expect(find.byType(AgentThinkingWave), findsOneWidget);
      expect(find.text('ZENO IS THINKING'), findsOneWidget);
      expect(find.text('THINKING…'), findsOneWidget);
      await run(tester, const Duration(seconds: 2));
      expect(find.byType(AgentThinkingWave), findsNothing);
      expect(find.text('Which storage size?'), findsOneWidget);
    });

    testWidgets('each result is locked on as it is dealt', (tester) async {
      setFakeRoute((uri) => uri.path.startsWith('/buy-agent-requests/converse')
          ? {
              'reply': 'Two of them.',
              'phase': 'RESULTS',
              'verdict': 'EXACT',
              'matches': [
                for (var i = 1; i <= 2; i++) fakeListingJson(i)..['match_is_exact'] = true,
              ],
              'slots': {'query': 'item', 'category': 'Electronics', 'max_price': 2000},
              'questions_asked': 0,
            }
          : null);
      await tester.pumpWidget(agent());
      await run(tester, const Duration(milliseconds: 500));
      await type(tester, 'an item');
      await run(tester, const Duration(seconds: 4));
      expect(find.text('2 exact matches'), findsOneWidget);
      expect(find.byType(AgentLockOn), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('fits a 320dp phone at 1.3x text', (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MediaQuery(
        data: const MediaQueryData(size: Size(320, 568), textScaler: TextScaler.linear(1.3)),
        child: agent(),
      ));
      await run(tester, const Duration(seconds: 2));
      expect(tester.takeException(), isNull);
    });
  });
}
