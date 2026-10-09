// Zeno as the user's assistant (2026-09-27): one-on-one conversation that
// can also DO things - open a screen, search, hand over to the Buying Agent,
// open a chat, place a call - typed or spoken, and a full-screen voice mode.
//
// The server (backend/api/domains/zeno_assistant) decides what an action is
// and who "Jane" is; what is under test here is what the app does with it:
// that a screen opens by itself, that nothing rings until Call is tapped,
// that the spoken loop works end to end, and that Zeno's own voice is never
// taken for the user's.
//
// Then Zeno stayed (zeno_session.dart): voice mode is the app's, above the
// Navigator, and opening a screen docks it in a pill that keeps listening -
// so the tests build the app the way main.dart does, with the session host.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:broka/features/safe_payment/payments_shown.dart';
import 'package:broka/features/zeno_assistant/domain/zeno_action.dart';
import 'package:broka/features/zeno_assistant/presentation/zeno_guide_card.dart';
import 'package:broka/features/zeno_assistant/presentation/zeno_live_overlay.dart';
import 'package:broka/features/zeno_assistant/presentation/zeno_orb.dart';
import 'package:broka/features/zeno_assistant/presentation/zeno_session_host.dart';
import 'package:broka/features/zeno_assistant/zeno_action_runner.dart';
import 'package:broka/features/zeno_assistant/zeno_session.dart';
import 'package:broka/screens/listing_search_screen.dart';
import 'package:broka/screens/zeno_screen.dart';
import 'package:broka/services/deepgram_stt_service.dart';
import 'package:broka/services/realtime_stt.dart';
import 'package:broka/services/zeno_chat_store.dart';
import 'package:broka/services/zeno_voice_controller.dart';

import 'support/fake_api.dart';
import 'support/fake_voice.dart';

void main() {
  // Written for a build that shows payments. The default build hides them
  // (payments_shown.dart): see the "payments hidden" tests.
  setUpAll(() => paymentsShown = true);
  tearDownAll(() => paymentsShown = false);

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

  late ZenoSession session;

  /// The app as main.dart builds it: Zeno's session above the Navigator.
  Widget app({Widget home = const ZenoScreen(animateBackground: false)}) {
    session = ZenoSession();
    return MaterialApp(
      home: home,
      navigatorObservers: [session.routes],
      builder: (context, child) => ZenoSessionHost(session: session, child: child!),
      // Where an action leads, by name, so a test can see it went there.
      onGenerateRoute: (s) => MaterialPageRoute(
        settings: s,
        builder: (_) => Scaffold(body: Text('route ${s.name} ${s.arguments ?? ''}')),
      ),
    );
  }

  Future<void> run(WidgetTester tester, Duration total) async {
    final end = tester.binding.clock.now().add(total);
    while (tester.binding.clock.now().isBefore(end)) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const Key('zeno-composer')), text);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump();
  }

  /// The assistant endpoint answering [reply] with [action].
  void answer(String reply, [Map<String, dynamic>? action]) => setFakeRoute((uri) {
        if (uri.path == '/zeno/assistant/turn') return {'reply': reply, 'action': action};
        if (uri.path == '/calls/initiate') return {'room_id': 'room-1', 'call_token': 'call-tok'};
        return null;
      });

  const jane = {
    'listing_id': 'listing-9', 'listing_name': 'Toyota Axio 2014', 'peer_id': 'seller-9',
    'peer_name': 'Jane Wanjiru', 'role': 'buyer', 'buyer_id': 'me',
  };

  List<FakeRequest> sent(String path) => [
        for (final r in fakeRequests)
          if (r.uri.path == path) r,
      ];

  group('with payments hidden (the default build)', () {
    setUp(() => paymentsShown = false);
    tearDown(() => paymentsShown = true);

    testWidgets("Zeno doesn't open a screen that leads to a payment", (tester) async {
      final opened = <String>[];
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: nav,
        home: const SizedBox(),
        onGenerateRoute: (s) {
          opened.add(s.name!);
          return MaterialPageRoute(builder: (_) => const SizedBox());
        },
      ));
      for (final dest in ['verify', 'escrow_services', 'deal_history']) {
        final ran = await ZenoActionRunner.runOn(nav.currentState!,
            ZenoAction(type: ZenoActionType.navigate, destination: dest));
        expect(ran, isFalse, reason: dest);
      }
      expect(await ZenoActionRunner.runOn(nav.currentState!,
          const ZenoAction(type: ZenoActionType.navigate, destination: 'settings')), isTrue);
      await tester.pump();
      expect(opened, ['/settings']);
    });
  });

  group('typed', () {
    testWidgets('"open my inbox" opens the inbox, by itself', (tester) async {
      answer('Opening your inbox.', {'type': 'NAVIGATE', 'destination': 'inbox'});
      await tester.pumpWidget(app());
      await run(tester, const Duration(milliseconds: 400));
      await type(tester, 'open my inbox');
      await run(tester, const Duration(milliseconds: 300));
      // Zeno says so first...
      expect(find.text('Opening your inbox.'), findsOneWidget);
      expect(find.text('Opening Inbox'), findsOneWidget);
      // ...then goes.
      await run(tester, const Duration(seconds: 2));
      expect(find.textContaining('route /inbox'), findsOneWidget);
      final body = sent('/zeno/assistant/turn').single.json as Map;
      expect(body['message'], 'open my inbox');
      expect(body['mode'], 'text');
    });

    testWidgets('a search opens the search screen on those words', (tester) async {
      answer('Searching for "toyota axio".', {'type': 'SEARCH', 'query': 'toyota axio'});
      await tester.pumpWidget(app());
      await run(tester, const Duration(milliseconds: 400));
      await type(tester, 'search for toyota axio');
      await run(tester, const Duration(seconds: 2));
      final screen = tester.widget<ListingSearchScreen>(find.byType(ListingSearchScreen));
      expect(screen.initialQuery, 'toyota axio');
    });

    testWidgets('a shopping request goes to the Buying Agent, already asked', (tester) async {
      answer("Handing that to the Buying Agent.", {'type': 'FIND_FOR_ME', 'query': 'a laptop under 50k'});
      await tester.pumpWidget(app());
      await run(tester, const Duration(milliseconds: 400));
      await type(tester, 'find me a laptop under 50k');
      await run(tester, const Duration(seconds: 2));
      final agents = tester.widgetList<ZenoScreen>(find.byType(ZenoScreen, skipOffstage: false));
      expect(agents.any((z) => z.mode == ZenoMode.buyingAgent && z.initialQuery == 'a laptop under 50k'),
          isTrue);
      await run(tester, const Duration(seconds: 3));
    });

    testWidgets('a chat opens the thread Zeno resolved', (tester) async {
      answer('Opening your chat with Jane.', {'type': 'OPEN_CHAT', 'contact': 'jane', 'target': jane});
      await tester.pumpWidget(app());
      await run(tester, const Duration(milliseconds: 400));
      await type(tester, 'message jane');
      await run(tester, const Duration(seconds: 2));
      expect(find.textContaining('route /negotiate'), findsOneWidget);
      expect(find.textContaining('listingId: listing-9'), findsOneWidget);
    });

    testWidgets('nothing rings until Call is tapped', (tester) async {
      answer('Calling Jane - just confirm.',
          {'type': 'CALL', 'contact': 'jane', 'call_type': 'video', 'target': jane, 'requires_confirmation': true});
      await tester.pumpWidget(app());
      await run(tester, const Duration(milliseconds: 400));
      await type(tester, 'video call jane');
      await run(tester, const Duration(seconds: 4));

      expect(find.text('Video call Jane Wanjiru?'), findsOneWidget);
      expect(find.text('About Toyota Axio 2014'), findsOneWidget);
      expect(sent('/calls/initiate'), isEmpty, reason: 'no call without a tap');
      expect(find.textContaining('route /voip-call'), findsNothing);

      await tester.tap(find.text('Video call'));
      await run(tester, const Duration(seconds: 1));
      final call = sent('/calls/initiate').single.json as Map;
      expect(call['listing_id'], 'listing-9');
      expect(call['call_type'], 'video');
      // A buyer's call goes to the listing's seller: no callee to name.
      expect(call.containsKey('callee_id'), isFalse);
      expect(find.textContaining('route /voip-call'), findsOneWidget);
      expect(find.textContaining('roomId: room-1'), findsOneWidget);
    });

    testWidgets('"Not now" means no call', (tester) async {
      answer('Calling Jane - just confirm.',
          {'type': 'CALL', 'contact': 'jane', 'call_type': 'audio', 'target': jane});
      await tester.pumpWidget(app());
      await run(tester, const Duration(milliseconds: 400));
      await type(tester, 'call jane');
      await run(tester, const Duration(seconds: 4));
      await tester.tap(find.text('Not now'));
      await run(tester, const Duration(milliseconds: 600));
      expect(find.text('Call cancelled'), findsOneWidget);
      expect(sent('/calls/initiate'), isEmpty);
    });

    testWidgets('a seller calling a buyer names the buyer', (tester) async {
      answer('Calling George - just confirm.', {
        'type': 'CALL', 'contact': 'george', 'call_type': 'audio',
        'target': {...jane, 'peer_name': 'George Omondi', 'peer_id': 'buyer-7', 'role': 'seller', 'buyer_id': 'buyer-7'},
      });
      await tester.pumpWidget(app());
      await run(tester, const Duration(milliseconds: 400));
      await type(tester, 'call george');
      await run(tester, const Duration(seconds: 4));
      await tester.tap(find.text('Call'));
      await run(tester, const Duration(seconds: 1));
      expect((sent('/calls/initiate').single.json as Map)['callee_id'], 'buyer-7');
    });

    testWidgets('when "Mary" is two people, the user picks, then confirms', (tester) async {
      answer('Which one - Mary Achieng (Leather sofa) or Mary Njeri (Samsung TV)?', {
        'type': 'CALL', 'contact': 'mary', 'call_type': 'audio', 'requires_confirmation': true,
        'choices': [
          {...jane, 'listing_id': 'sofa', 'listing_name': 'Leather sofa', 'peer_id': 'm1', 'peer_name': 'Mary Achieng'},
          {...jane, 'listing_id': 'tv', 'listing_name': 'Samsung TV', 'peer_id': 'm2', 'peer_name': 'Mary Njeri'},
        ],
      });
      await tester.pumpWidget(app());
      await run(tester, const Duration(milliseconds: 400));
      await type(tester, 'call mary');
      await run(tester, const Duration(seconds: 5));
      expect(find.text('Who should I call?'), findsOneWidget);

      await tester.tap(find.text('Mary Njeri'));
      await run(tester, const Duration(milliseconds: 600));
      expect(find.text('Call Mary Njeri?'), findsOneWidget);
      expect(sent('/calls/initiate'), isEmpty, reason: 'picking is not confirming');
      await tester.tap(find.text('Call'));
      await run(tester, const Duration(seconds: 1));
      expect((sent('/calls/initiate').single.json as Map)['listing_id'], 'tv');
    });

    testWidgets('an action this build does not know is ignored, the reply is not', (tester) async {
      answer('Done - transferred!', {'type': 'TRANSFER_MONEY', 'amount': 5000});
      await tester.pumpWidget(app());
      await run(tester, const Duration(milliseconds: 400));
      await type(tester, 'send 5000 to my friend');
      await run(tester, const Duration(seconds: 5));
      expect(find.text('Done - transferred!'), findsOneWidget);
      expect(find.byType(Scaffold), findsOneWidget, reason: 'nowhere to go');
    });

    testWidgets('a guide in the chat: steps, each a tap from where it is done', (tester) async {
      answer("Selling faster: your listings - here's how.", {
        'type': 'GUIDE',
        'guide': 'sell_faster',
        'guide_content': {
          'id': 'sell_faster',
          'title': 'Selling faster: your listings',
          'intro': 'From your own listings, the changes most likely to help:',
          'steps': [
            {'title': 'Check the price of "PS5 Slim"', 'detail': 'KES 90,000 is 20% above the median KES 75,000 of 6 similar Gaming listings.', 'destination': 'seller_dashboard'},
            {'title': 'Answer the buyers of "PS5 Slim"', 'detail': '2 buyer(s) asked about it.', 'destination': 'inbox'},
            {'title': 'Something this build has no screen for', 'destination': 'admin_panel'},
          ],
        },
      });
      await tester.pumpWidget(app());
      await run(tester, const Duration(milliseconds: 400));
      await type(tester, 'tips to sell faster');
      await run(tester, const Duration(seconds: 3));
      expect(find.text('Selling faster: your listings'), findsOneWidget);
      expect(find.textContaining('20% above the median'), findsOneWidget);
      // A screen this build has no route for is a step without a button.
      expect(find.text('Take me there'), findsNWidgets(2));
      expect(find.textContaining('route /'), findsNothing, reason: 'a guide opens nothing by itself');

      await tester.ensureVisible(find.text('Take me there').last);
      await run(tester, const Duration(milliseconds: 300));
      await tester.tap(find.text('Take me there').last);
      await run(tester, const Duration(seconds: 1));
      expect(find.textContaining('route /inbox'), findsOneWidget);
    });

    // Zeno walking someone through an escrow service (backend
    // zeno_assistant/escrow_walkthrough.py): each step comes with the
    // replies to tap, and the step that opens the service links to it.
    testWidgets('the escrow walkthrough: tap a reply to go on, and the link opens the service', (tester) async {
      setFakeRoute((uri) => uri.path == '/zeno/assistant/turn'
          ? {
              'reply': 'Step 2 of 7 · Buying with E-Confirm\n\nOpen E-Confirm yourself: go to econfirm.co.ke.',
              'action': null,
              'suggestions': ["Done - what's next?", 'Repeat this step', 'Back'],
              'link': {'label': 'Open E-Confirm', 'url': 'https://econfirm.co.ke'},
            }
          : null);
      await tester.pumpWidget(app());
      await run(tester, const Duration(milliseconds: 400));
      await type(tester, 'next');
      await run(tester, const Duration(seconds: 3));
      expect(find.text('Open E-Confirm'), findsOneWidget);
      expect(find.text("Done - what's next?"), findsOneWidget);
      expect(find.text('Repeat this step'), findsOneWidget);

      await tester.tap(find.text("Done - what's next?"));
      await run(tester, const Duration(seconds: 1));
      final said = [for (final r in sent('/zeno/assistant/turn')) (r.json as Map)['message']];
      expect(said, ['next', "Done - what's next?"], reason: 'a tapped reply is sent as if typed');
    });

    testWidgets('a question asked from another screen is sent the moment Zeno opens', (tester) async {
      answer("I'll walk you through it, one step at a time.");
      await tester.pumpWidget(app(home: const ZenoScreen(
          animateBackground: false, initialQuery: ZenoScreen.escrowOpener)));
      await run(tester, const Duration(seconds: 2));
      final body = sent('/zeno/assistant/turn').single.json as Map;
      expect(body['message'], ZenoScreen.escrowOpener);
      expect(find.text("I'll walk you through it, one step at a time."), findsOneWidget);
    });

    test('suggestions are bounded, and a link opens only over https', () {
      final turn = ZenoTurnResult.fromJson({
        'reply': 'Which one?',
        'suggestions': ['A', ' B ', '', 42, 'C', 'D', 'E', 'F', 'G', 'x' * 61],
        'link': {'label': 'Open it', 'url': 'http://econfirm.co.ke'},
      });
      expect(turn.suggestions, ['A', 'B', 'C', 'D', 'E', 'F']);
      expect(turn.link, isNull, reason: 'not https');
      expect(ZenoLink.fromJson({'label': 'Open', 'url': 'https://lipasafe.co.ke'})!.url.host, 'lipasafe.co.ke');
      expect(ZenoLink.fromJson({'label': 'Open', 'url': 'javascript:alert(1)'}), isNull);
    });

    testWidgets('a server from before the assistant still answers, the old way', (tester) async {
      setFakeRoute((uri) {
        if (uri.path == '/zeno/assistant/turn') return const FakeResponse({'detail': 'Not Found'}, statusCode: 404);
        if (uri.path == '/negotiate/chat') return {'role': 'broker', 'content': 'Old Zeno here.'};
        return null;
      });
      await tester.pumpWidget(app());
      await run(tester, const Duration(milliseconds: 400));
      await type(tester, 'hello');
      await run(tester, const Duration(seconds: 5));
      expect(find.text('Old Zeno here.'), findsOneWidget);
    });
  });

  group('voice mode', () {
    late FakeSocket socket;
    late FakeRecorder mic;

    /// The session's teardown waits on the fake socket's close, which only
    /// moves in real time, not on the test's clock.
    Future<void> letTeardownFinish(WidgetTester tester) async {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await run(tester, const Duration(milliseconds: 200));
    }

    /// A new socket for each connection, so the microphone can be closed
    /// and opened again; [socket] is the live one.
    RealtimeSttProvider fakeVoice() {
      socket = FakeSocket();
      mic = FakeRecorder();
      var first = true;
      return DeepgramSttService(
        microphone: MicrophoneSource(recorder: mic),
        fetchToken: () async => 't',
        connect: (_, __) {
          if (!first) socket = FakeSocket();
          first = false;
          return socket;
        },
      );
    }

    Future<void> say(WidgetTester tester, String words, {Duration then = const Duration(seconds: 2)}) async {
      socket.emit(deepgramResults(words, isFinal: true, speechFinal: true));
      await run(tester, then);
    }

    /// The assistant answering each turn in order.
    void answers(List<Map<String, Object?>> turns) {
      var i = 0;
      setFakeRoute((uri) {
        if (uri.path == '/zeno/assistant/turn') return turns[i++ % turns.length];
        if (uri.path == '/calls/initiate') return {'room_id': 'room-1', 'call_token': 'call-tok'};
        return null;
      });
    }

    testWidgets('the microphone opens full-screen voice, and it closes back to the chat', (tester) async {
      answer('Hi!');
      await tester.pumpWidget(app(home: ZenoScreen(animateBackground: false, voiceService: fakeVoice())));
      await run(tester, const Duration(milliseconds: 400));
      expect(find.byType(ZenoOrb), findsNothing);

      await tester.tap(find.byIcon(Icons.mic_none_rounded));
      await run(tester, const Duration(milliseconds: 900));
      expect(find.byType(ZenoOrb), findsOneWidget);
      expect(find.text('Try saying'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byTooltip('End voice'));
      await run(tester, const Duration(milliseconds: 900));
      expect(find.byType(ZenoOrb), findsNothing);
      expect(find.byKey(const Key('zeno-composer')), findsOneWidget);
    });

    testWidgets('say "open my inbox": heard, answered, the inbox opens - and Zeno stays', (tester) async {
      answer('Opening your inbox.', {'type': 'NAVIGATE', 'destination': 'inbox'});
      await tester.pumpWidget(app(home: ZenoScreen(animateBackground: false, voiceService: fakeVoice())));
      await run(tester, const Duration(milliseconds: 400));
      await tester.tap(find.byIcon(Icons.mic_none_rounded));
      await run(tester, const Duration(milliseconds: 600));

      socket.emit(deepgramResults('open my', isFinal: false));
      await run(tester, const Duration(milliseconds: 100));
      expect(find.textContaining('open my'), findsWidgets, reason: 'what it hears, as it hears it');
      socket.emit(deepgramResults('open my inbox', isFinal: true, speechFinal: true));
      // The grace period, then the turn goes to Zeno as a spoken one.
      await run(tester, const Duration(milliseconds: 1200));
      final body = sent('/zeno/assistant/turn').single.json as Map;
      expect(body['message'], 'open my inbox');
      expect(body['mode'], 'voice');

      await run(tester, const Duration(seconds: 2));
      expect(find.textContaining('route /inbox'), findsOneWidget);
      // Zeno came along: docked in its pill over the inbox, still listening.
      expect(session.docked, isTrue);
      expect(find.byTooltip('End Zeno'), findsOneWidget);
      expect(mic.running, isTrue);
      expect(find.byType(ZenoOrb), findsOneWidget, reason: "the pill's orb; the full view has gone");

      await tester.tap(find.byTooltip('End Zeno'));
      await letTeardownFinish(tester);
      await run(tester, const Duration(milliseconds: 500));
      expect(mic.running, isFalse);
      expect(find.byType(ZenoOrb), findsNothing);
    });

    testWidgets('a spoken call still waits for a tap', (tester) async {
      answer('Calling Jane - just confirm.',
          {'type': 'CALL', 'contact': 'jane', 'call_type': 'audio', 'target': jane});
      await tester.pumpWidget(app(home: ZenoScreen(animateBackground: false, voiceService: fakeVoice())));
      await run(tester, const Duration(milliseconds: 400));
      await tester.tap(find.byIcon(Icons.mic_none_rounded));
      await run(tester, const Duration(milliseconds: 600));
      socket.emit(deepgramResults('call jane', isFinal: true, speechFinal: true));
      await run(tester, const Duration(seconds: 3));

      expect(find.byType(ZenoOrb), findsOneWidget, reason: 'still in voice mode');
      expect(find.text('Call Jane Wanjiru?'), findsWidgets);
      expect(sent('/calls/initiate'), isEmpty);
      // "yes" out loud is not a confirmation: a misheard word must never
      // place a call.
      socket.emit(deepgramResults('yes', isFinal: true, speechFinal: true));
      await run(tester, const Duration(seconds: 2));
      expect(sent('/calls/initiate'), isEmpty);

      await tester.tap(find.text('Call').last);
      await run(tester, const Duration(seconds: 1));
      expect(sent('/calls/initiate'), hasLength(1));
      await letTeardownFinish(tester);
      expect(mic.running, isFalse, reason: 'the call needs the microphone');
      expect(session.isActive, isFalse, reason: 'and Zeno does not wait over the call');
      expect(find.textContaining('route /voip-call'), findsOneWidget);
    });

    testWidgets('a conversation: Zeno answers, then hears the next thing said', (tester) async {
      var turn = 0;
      setFakeRoute((uri) {
        if (uri.path != '/zeno/assistant/turn') return null;
        turn++;
        return turn == 1
            ? {'reply': 'About 850K to 950K. Want me to find you one?', 'action': null}
            : {'reply': 'Handing that to the Buying Agent.', 'action': {'type': 'FIND_FOR_ME', 'query': 'toyota axio 2014'}};
      });
      await tester.pumpWidget(app(home: ZenoScreen(animateBackground: false, voiceService: fakeVoice())));
      await run(tester, const Duration(milliseconds: 400));
      // Spoken replies are out of this test: the TTS player is a singleton,
      // and in a test isolate it carries over from earlier tests. What is
      // under test is the loop; the microphone during Zeno's voice has its
      // own test below.
      await tester.tap(find.byTooltip('Mute Zeno'));
      await tester.tap(find.byIcon(Icons.mic_none_rounded));
      await run(tester, const Duration(milliseconds: 600));

      socket.emit(deepgramResults("what's a fair price for a 2014 axio", isFinal: true, speechFinal: true));
      await run(tester, const Duration(seconds: 2));
      expect(find.text('About 850K to 950K. Want me to find you one?'), findsWidgets);

      socket.emit(deepgramResults('yes find me one', isFinal: true, speechFinal: true));
      await run(tester, const Duration(seconds: 3));
      final said = [for (final r in sent('/zeno/assistant/turn')) (r.json as Map)['message']];
      expect(said, ["what's a fair price for a 2014 axio", 'yes find me one']);
      final second = sent('/zeno/assistant/turn').last.json as Map;
      expect((second['history'] as List).map((h) => (h as Map)['content']),
          contains('About 850K to 950K. Want me to find you one?'));
      await run(tester, const Duration(seconds: 3));
      expect(find.byType(ZenoScreen, skipOffstage: false), findsNWidgets(2),
          reason: 'the Buying Agent opened on top');
      // It has a voice of its own: Zeno hands over rather than talk over it.
      expect(session.isActive, isFalse);
      await letTeardownFinish(tester);
      expect(mic.running, isFalse);
    });

    testWidgets('holding the Zeno tab opens straight into voice', (tester) async {
      answer('Hi!');
      await tester.pumpWidget(app(
          home: ZenoScreen(animateBackground: false, startInVoice: true, voiceService: fakeVoice())));
      await run(tester, const Duration(milliseconds: 900));
      expect(find.byType(ZenoOrb), findsOneWidget);
      await tester.tap(find.byTooltip('End voice'));
      await run(tester, const Duration(milliseconds: 900));
    });

    testWidgets('fits a 320dp phone at 1.3x text without overflow', (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      answer('Calling Jane - just confirm.',
          {'type': 'CALL', 'contact': 'jane', 'call_type': 'video', 'target': jane});
      await tester.pumpWidget(MediaQuery(
        data: const MediaQueryData(size: Size(320, 568), textScaler: TextScaler.linear(1.3)),
        child: app(home: ZenoScreen(animateBackground: false, voiceService: fakeVoice())),
      ));
      await run(tester, const Duration(milliseconds: 400));
      await tester.tap(find.byIcon(Icons.mic_none_rounded));
      await run(tester, const Duration(milliseconds: 600));
      socket.emit(deepgramResults('video call jane', isFinal: true, speechFinal: true));
      await run(tester, const Duration(seconds: 3));
      expect(find.byType(ZenoLiveOverlay), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('End voice'));
      await run(tester, const Duration(milliseconds: 900));
    });

    testWidgets('Zeno stays: the dashboard, a search from there, then the inbox - one conversation', (tester) async {
      // The request that started this: "open my dashboard", and Zeno is
      // still there to be told to search, and then to switch to the inbox.
      answers([
        {'reply': 'Opening your dashboard.', 'action': {'type': 'NAVIGATE', 'destination': 'seller_dashboard'}},
        {'reply': 'Searching for "ps5".', 'action': {'type': 'SEARCH', 'query': 'ps5'}},
        {'reply': 'Opening your inbox.', 'action': {'type': 'NAVIGATE', 'destination': 'inbox'}},
      ]);
      await tester.pumpWidget(app(home: ZenoScreen(animateBackground: false, voiceService: fakeVoice())));
      await run(tester, const Duration(milliseconds: 400));
      await tester.tap(find.byTooltip('Mute Zeno'));
      await tester.tap(find.byIcon(Icons.mic_none_rounded));
      await run(tester, const Duration(milliseconds: 600));

      await say(tester, 'open my dashboard', then: const Duration(seconds: 3));
      expect(find.textContaining('route /seller-dashboard'), findsOneWidget);
      expect(session.docked && mic.running, isTrue);

      await say(tester, 'search for a ps5', then: const Duration(seconds: 3));
      expect(tester.widget<ListingSearchScreen>(find.byType(ListingSearchScreen)).initialQuery, 'ps5');
      // Swapped for the dashboard, not piled on it: back goes to where the
      // user was before Zeno started opening things.
      expect(find.textContaining('route /seller-dashboard', skipOffstage: false), findsNothing);

      await say(tester, 'now switch to my inbox', then: const Duration(seconds: 3));
      expect(find.textContaining('route /inbox'), findsOneWidget);
      expect(find.byType(ListingSearchScreen, skipOffstage: false), findsNothing);
      expect(session.docked && mic.running, isTrue, reason: 'still listening, three screens later');

      // One conversation: each turn had the ones before it.
      final third = sent('/zeno/assistant/turn').last.json as Map;
      expect((third['history'] as List).map((h) => (h as Map)['content']),
          containsAll(['open my dashboard', 'Opening your dashboard.', 'search for a ps5']));

      // ...and it is the Zeno tab's: back there, it is in the chat, and
      // saved with it.
      tester.state<NavigatorState>(find.byType(Navigator).first).pop();
      await run(tester, const Duration(seconds: 1));
      expect(find.text('now switch to my inbox'), findsOneWidget);
      final saved = await tester.runAsync(() => ZenoChatStore.load('assistant'));
      expect(saved!.turns.map((t) => t.content), containsAllInOrder([
        'open my dashboard', 'Opening your dashboard.',
        'search for a ps5', 'Searching for "ps5".',
        'now switch to my inbox', 'Opening your inbox.',
      ]));

      await tester.tap(find.byTooltip('End Zeno'));
      await letTeardownFinish(tester);
      expect(mic.running, isFalse);
    });

    testWidgets('the pill: type instead, and the turn goes through the same session', (tester) async {
      answers([
        {'reply': 'Opening your inbox.', 'action': {'type': 'NAVIGATE', 'destination': 'inbox'}},
        {'reply': 'Opening Settings.', 'action': {'type': 'NAVIGATE', 'destination': 'settings'}},
      ]);
      await tester.pumpWidget(app(home: ZenoScreen(animateBackground: false, voiceService: fakeVoice())));
      await run(tester, const Duration(milliseconds: 400));
      await tester.tap(find.byTooltip('Mute Zeno'));
      await tester.tap(find.byIcon(Icons.mic_none_rounded));
      await run(tester, const Duration(milliseconds: 600));
      await say(tester, 'open my inbox', then: const Duration(seconds: 3));

      await tester.tap(find.byTooltip('Type to Zeno'));
      await letTeardownFinish(tester);
      expect(mic.running, isFalse, reason: 'it would take what is said while typing');
      await tester.enterText(find.byKey(const Key('zeno-pill-field')), 'open settings');
      await tester.tap(find.byTooltip('Send to Zeno'));
      await run(tester, const Duration(seconds: 3));
      expect((sent('/zeno/assistant/turn').last.json as Map)['message'], 'open settings');
      expect(find.textContaining('route /settings'), findsOneWidget);
      expect(session.isActive, isTrue);

      // And back to talking.
      await tester.tap(find.byTooltip('Talk to Zeno'));
      // The last session's socket closes first, in real time.
      await letTeardownFinish(tester);
      expect(mic.running, isTrue);
      expect(mic.startCount, 2);
      await tester.tap(find.byTooltip('End Zeno'));
      await letTeardownFinish(tester);
    });

    testWidgets('another voice session takes the microphone; Zeno waits with "Tap to talk"', (tester) async {
      answer('Opening your inbox.', {'type': 'NAVIGATE', 'destination': 'inbox'});
      await tester.pumpWidget(app(home: ZenoScreen(animateBackground: false, voiceService: fakeVoice())));
      await run(tester, const Duration(milliseconds: 400));
      await tester.tap(find.byTooltip('Mute Zeno'));
      await tester.tap(find.byIcon(Icons.mic_none_rounded));
      await run(tester, const Duration(milliseconds: 600));
      await say(tester, 'open my inbox', then: const Duration(seconds: 3));
      expect(mic.running, isTrue);

      // A voice note in the negotiation room, say.
      await tester.runAsync(ZenoVoiceController.releaseMicrophone);
      await letTeardownFinish(tester);
      expect(mic.running, isFalse);
      expect(session.isActive, isTrue);
      expect(find.text('TAP TO TALK'), findsOneWidget);

      await tester.tap(find.byTooltip('Talk to Zeno'));
      await run(tester, const Duration(milliseconds: 600));
      expect(mic.running, isTrue);
      await tester.tap(find.byTooltip('End Zeno'));
      await letTeardownFinish(tester);
    });

    testWidgets('voice without a plan: Zeno says why in words, and stops listening', (tester) async {
      // The server refuses a spoken turn with a 402 (premium/entitlements.py).
      // It used to read as "I couldn't reach Zeno", and the microphone
      // stayed open for every next sentence to be refused the same way.
      setFakeRoute((uri) => uri.path == '/zeno/assistant/turn'
          ? const FakeResponse({'detail': {
              'code': 'PREMIUM_REQUIRED', 'feature': 'voice_requests', 'plan': null, 'upgrade_to': 'plus',
              'message': 'Talking to Zeno in voice mode is part of BROKA Plus - from KES 169 a month.'}},
              statusCode: 402)
          : null);
      await tester.pumpWidget(app(home: ZenoScreen(animateBackground: false, voiceService: fakeVoice())));
      await run(tester, const Duration(milliseconds: 400));
      await tester.tap(find.byTooltip('Mute Zeno'));
      await tester.tap(find.byIcon(Icons.mic_none_rounded));
      await run(tester, const Duration(milliseconds: 600));
      await say(tester, 'open my inbox');
      await letTeardownFinish(tester);

      expect(find.textContaining('part of BROKA Plus'), findsWidgets);
      expect(find.textContaining("couldn't reach Zeno"), findsNothing);
      expect(mic.running, isFalse);
      expect(session.isActive, isTrue, reason: 'the answer stays on screen to read');
      await tester.tap(find.byTooltip('End Zeno'));
      await run(tester, const Duration(milliseconds: 600));
    });

    testWidgets('a minute with nothing said stops the microphone', (tester) async {
      answer('Opening your inbox.', {'type': 'NAVIGATE', 'destination': 'inbox'});
      await tester.pumpWidget(app(home: ZenoScreen(animateBackground: false, voiceService: fakeVoice())));
      await run(tester, const Duration(milliseconds: 400));
      await tester.tap(find.byTooltip('Mute Zeno'));
      await tester.tap(find.byIcon(Icons.mic_none_rounded));
      await run(tester, const Duration(milliseconds: 600));
      await say(tester, 'open my inbox', then: const Duration(seconds: 3));

      await tester.pump(const Duration(seconds: 30));
      expect(mic.running, isTrue);
      await tester.pump(ZenoSession.quietFor);
      await letTeardownFinish(tester);
      expect(mic.running, isFalse, reason: 'the speech provider bills by the minute');
      expect(session.isActive, isTrue);
      expect(find.text('TAP TO TALK'), findsOneWidget);
      await tester.tap(find.byTooltip('End Zeno'));
      await run(tester, const Duration(milliseconds: 600));
    });

    testWidgets('the app leaving the foreground ends it', (tester) async {
      addTearDown(() => tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));
      answer('Hi!');
      await tester.pumpWidget(app(home: ZenoScreen(animateBackground: false, voiceService: fakeVoice())));
      await run(tester, const Duration(milliseconds: 400));
      await tester.tap(find.byIcon(Icons.mic_none_rounded));
      await run(tester, const Duration(milliseconds: 600));
      expect(mic.running, isTrue);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await letTeardownFinish(tester);
      expect(session.isActive, isFalse);
      expect(mic.running, isFalse, reason: 'nothing listens from the background');
    });

    testWidgets('started from anywhere, what is said lands in the Zeno tab', (tester) async {
      answer('Hey! What can I do?');
      final voice = fakeVoice();
      await tester.pumpWidget(app(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => ZenoSession.maybeOf(context)!.start(service: voice, muted: true),
                child: const Text('hold the Zeno tab'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('hold the Zeno tab'));
      await run(tester, const Duration(milliseconds: 900));
      expect(find.byType(ZenoOrb), findsOneWidget);
      await say(tester, 'hi zeno');
      expect(find.text('Hey! What can I do?'), findsWidgets);
      await tester.tap(find.byTooltip('End voice'));
      await letTeardownFinish(tester);

      // The Zeno tab, opened afterwards, has the exchange.
      tester.state<NavigatorState>(find.byType(Navigator).first).push(
          MaterialPageRoute<void>(builder: (_) => const ZenoScreen(animateBackground: false)));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await run(tester, const Duration(seconds: 1));
      expect(find.text('hi zeno'), findsOneWidget);
      expect(find.text('Hey! What can I do?'), findsOneWidget);
    });

    testWidgets('a guide in voice mode: step by step, with Zeno along', (tester) async {
      answer("Open your online store - here's how.", {
        'type': 'GUIDE',
        'guide': 'open_store',
        'guide_content': {
          'id': 'open_store',
          'title': 'Open your online store',
          'intro': 'A store gives your business its own page on BROKA. Four steps:',
          'steps': [
            {'title': 'Open store setup', 'detail': 'It asks a few business questions first.', 'destination': 'store_setup'},
            {'title': 'Name it and brand it', 'detail': 'A clear name and a logo.'},
            {'title': 'Share your link', 'detail': 'broka.co.ke/store/your-name'},
          ],
        },
      });
      await tester.pumpWidget(app(home: ZenoScreen(animateBackground: false, voiceService: fakeVoice())));
      await run(tester, const Duration(milliseconds: 400));
      await tester.tap(find.byTooltip('Mute Zeno'));
      await tester.tap(find.byIcon(Icons.mic_none_rounded));
      await run(tester, const Duration(milliseconds: 600));
      await say(tester, 'how do I open a store', then: const Duration(seconds: 3));

      // A guide is read, not run: nothing opens until a step is tapped.
      expect(find.byType(ZenoGuideCard), findsWidgets);
      expect(find.text('Open store setup'), findsWidgets);
      expect(find.textContaining('route /'), findsNothing);
      expect(session.expanded, isTrue);

      await tester.tap(find.text('Take me there').last);
      await run(tester, const Duration(seconds: 1));
      expect(find.textContaining('route /store-setup'), findsOneWidget);
      // The guide comes along, folded above the pill, one step ticked.
      expect(session.docked && mic.running, isTrue);
      expect(find.text('Next: Name it and brand it'), findsOneWidget);
      await tester.tap(find.text('Next: Name it and brand it'));
      await run(tester, const Duration(milliseconds: 600));
      expect(find.text('1 of 3 done'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byTooltip('End Zeno'));
      await letTeardownFinish(tester);
    });

    testWidgets('the pill fits a 320dp phone at 1.3x text', (tester) async {
      tester.view.physicalSize = const Size(320, 568);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      answer('Opening your inbox and everything in it, all of your conversations with buyers and sellers.',
          {'type': 'NAVIGATE', 'destination': 'inbox'});
      await tester.pumpWidget(MediaQuery(
        data: const MediaQueryData(size: Size(320, 568), textScaler: TextScaler.linear(1.3)),
        child: app(home: ZenoScreen(animateBackground: false, voiceService: fakeVoice())),
      ));
      await run(tester, const Duration(milliseconds: 400));
      await tester.tap(find.byTooltip('Mute Zeno'));
      await tester.tap(find.byIcon(Icons.mic_none_rounded));
      await run(tester, const Duration(milliseconds: 600));
      await say(tester, 'open my inbox', then: const Duration(seconds: 3));
      expect(find.byTooltip('End Zeno'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip('End Zeno'));
      await letTeardownFinish(tester);
    });
  });

  group("Zeno's own voice is not the user's", () {
    test('what the microphone hears while Zeno speaks is dropped', () async {
      // The session stays open while Zeno talks, through the speaker, into
      // the same microphone. That used to land Zeno's reply in the box and
      // send it straight back to Zeno as the user's next turn.
      final socket = FakeSocket();
      final heard = <String>[];
      final c = ZenoVoiceController(
        onSubmit: (t) async => heard.add(t),
        languageKey: () => 'english',
        service: DeepgramSttService(
          microphone: MicrophoneSource(recorder: FakeRecorder()),
          fetchToken: () async => 't',
          connect: (_, __) => socket,
        ),
      );
      await c.open();
      c.setZenoSpeaking(true);
      socket.emit(deepgramResults('Opening your', isFinal: false));
      socket.emit(deepgramResults('Opening your inbox', isFinal: true, speechFinal: true));
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(heard, isEmpty);
      expect(c.transcript.text, isEmpty);
      expect(c.interim, isEmpty);

      // The provider's final text for Zeno's last words lands just after
      // the audio stops.
      c.setZenoSpeaking(false);
      socket.emit(deepgramResults('your inbox', isFinal: true, speechFinal: true));
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(heard, isEmpty);

      // And then the user is heard again.
      socket.emit(deepgramResults('thanks Zeno', isFinal: true, speechFinal: true));
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(heard, ['thanks Zeno']);
      c.dispose();
    });
  });

  group('the microphone', () {
    test('opened again while the last close is still finishing, it really listens', () async {
      // The pill's "Tap to talk" a moment after its microphone stopped: the
      // provider was still closing its socket, ignored the start, and the
      // card said "Listening" over a microphone that never opened.
      final mic = FakeRecorder();
      final c = ZenoVoiceController(
        onSubmit: (_) async {},
        languageKey: () => 'english',
        service: DeepgramSttService(
          microphone: MicrophoneSource(recorder: mic),
          fetchToken: () async => 't',
          connect: (_, __) => FakeSocket(),
        ),
      );
      await c.open();
      expect(mic.startCount, 1);
      unawaited(c.close());
      await c.open();
      expect(c.state, VoiceSessionState.listening);
      expect(mic.startCount, 2, reason: 'a second session, not a deaf one');
      expect(mic.running, isTrue);
      c.dispose();
    });

    test('one voice session holds the microphone at a time', () async {
      ZenoVoiceController make(FakeRecorder mic) => ZenoVoiceController(
            onSubmit: (_) async {},
            languageKey: () => 'english',
            service: DeepgramSttService(
              microphone: MicrophoneSource(recorder: mic),
              fetchToken: () async => 't',
              connect: (_, __) => FakeSocket(),
            ),
          );
      final zenoMic = FakeRecorder();
      final cardMic = FakeRecorder();
      final zeno = make(zenoMic);
      final card = make(cardMic);
      await zeno.open();
      await card.open();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(zeno.isOpen, isFalse);
      expect(zenoMic.running, isFalse);
      expect(cardMic.running, isTrue);
      zeno.dispose();
      card.dispose();
    });
  });

  group('ZenoAction', () {
    test('parses only what this build can do', () {
      expect(ZenoAction.fromJson({'type': 'NAVIGATE', 'destination': 'inbox'})?.destination, 'inbox');
      expect(ZenoAction.fromJson({'type': 'NAVIGATE', 'destination': 'admin'}), isNull);
      expect(ZenoAction.fromJson({'type': 'SEARCH', 'query': '  '}), isNull);
      expect(ZenoAction.fromJson({'type': 'CALL', 'contact': 'jane'}), isNull,
          reason: 'a call with nobody resolved to call');
      expect(ZenoAction.fromJson({'type': 'WIRE_MONEY'}), isNull);
      expect(ZenoAction.fromJson(null), isNull);
    });

    test('a guide parses its steps, and drops what it cannot show', () {
      final a = ZenoAction.fromJson({
        'type': 'GUIDE',
        'guide': 'open_store',
        'guide_content': {
          'id': 'open_store',
          'title': 'Open your online store',
          'steps': [
            {'title': 'Open store setup', 'destination': 'store_setup'},
            {'title': 'Somewhere new', 'destination': 'hyperdrive'},
            {'title': '   '},
          ],
        },
      })!;
      expect(a.type, ZenoActionType.guide);
      expect(a.runsByItself, isFalse, reason: 'a guide is read, not run');
      expect(a.guide!.steps.map((s) => s.destination), ['store_setup', null]);
      expect(ZenoAction.fromJson({'type': 'GUIDE', 'guide': 'open_store'}), isNull,
          reason: 'no steps, no guide');
      expect(ZenoAction.fromJson({'type': 'NAVIGATE', 'destination': 'my_store'})?.destination, 'my_store');
    });

    test('a call always asks first, whatever the server says', () {
      final a = ZenoAction.fromJson(
          {'type': 'CALL', 'contact': 'jane', 'target': jane, 'requires_confirmation': false})!;
      expect(a.requiresConfirmation, isTrue);
      expect(a.runsByItself, isFalse);
    });
  });
}
