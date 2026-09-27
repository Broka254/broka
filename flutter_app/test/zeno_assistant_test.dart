// Zeno as the user's assistant (2026-09-27): one-on-one conversation that
// can also DO things - open a screen, search, hand over to the Buying Agent,
// open a chat, place a call - typed or spoken, and a full-screen voice mode.
//
// The server (backend/api/domains/zeno_assistant) decides what an action is
// and who "Jane" is; what is under test here is what the app does with it:
// that a screen opens by itself, that nothing rings until Call is tapped,
// that the spoken loop works end to end, and that Zeno's own voice is never
// taken for the user's.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:broka/features/zeno_assistant/domain/zeno_action.dart';
import 'package:broka/features/zeno_assistant/presentation/zeno_live_overlay.dart';
import 'package:broka/features/zeno_assistant/presentation/zeno_orb.dart';
import 'package:broka/screens/listing_search_screen.dart';
import 'package:broka/screens/zeno_screen.dart';
import 'package:broka/services/deepgram_stt_service.dart';
import 'package:broka/services/realtime_stt.dart';
import 'package:broka/services/zeno_voice_controller.dart';

import 'support/fake_api.dart';
import 'support/fake_voice.dart';

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

  Widget app({Widget home = const ZenoScreen(animateBackground: false)}) => MaterialApp(
        home: home,
        // Where an action leads, by name, so a test can see it went there.
        onGenerateRoute: (s) => MaterialPageRoute(
          settings: s,
          builder: (_) => Scaffold(body: Text('route ${s.name} ${s.arguments ?? ''}')),
        ),
      );

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

    RealtimeSttProvider fakeVoice() {
      socket = FakeSocket();
      mic = FakeRecorder();
      return DeepgramSttService(
        microphone: MicrophoneSource(recorder: mic),
        fetchToken: () async => 't',
        connect: (_, __) => socket,
      );
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

    testWidgets('say "open my inbox": heard, answered, and the inbox opens', (tester) async {
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
      // The microphone did not come along.
      await letTeardownFinish(tester);
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
      await letTeardownFinish(tester);
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

    test('a call always asks first, whatever the server says', () {
      final a = ZenoAction.fromJson(
          {'type': 'CALL', 'contact': 'jane', 'target': jane, 'requires_confirmation': false})!;
      expect(a.requiresConfirmation, isTrue);
      expect(a.runsByItself, isFalse);
    });
  });
}
