// Zeno's voice pass of 2026-10-09:
//
//  - voice mode that stopped hearing the user. The microphone was paused
//    by Zeno's own reply: record's default takes Android's audio focus and
//    pauses on losing it, with no resume, and BrokaTts's player asks for
//    focus every time Zeno speaks - while the socket's KeepAlive kept the
//    session looking alive. A minute of silence also stopped the microphone
//    without a word, and words said while Zeno was thinking were dropped;
//  - Zeno checking in when the user goes quiet;
//  - Zeno's tour of BROKA for a new account (zeno_tour.dart);
//  - Zeno's orb on every screen, the way into voice from anywhere
//    (zeno_launcher.dart).
//
// The fixes' tests - the microphone's, Deepgram's utterance end, and
// words said while Zeno is thinking - failed on the code before this pass
// ("quiet is not a stall" is the guard that keeps the watchdog honest).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:broka/features/zeno_assistant/presentation/zeno_launcher.dart';
import 'package:broka/features/zeno_assistant/presentation/zeno_session_host.dart';
import 'package:broka/features/zeno_assistant/zeno_check_ins.dart';
import 'package:broka/features/zeno_assistant/zeno_session.dart';
import 'package:broka/features/zeno_assistant/zeno_tour.dart';
import 'package:broka/screens/listing_search_screen.dart';
import 'package:broka/screens/zeno_screen.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/services/broka_tts.dart';
import 'package:broka/services/deepgram_stt_service.dart';
import 'package:broka/services/realtime_stt.dart';
import 'package:broka/services/zeno_voice_controller.dart';

import 'support/fake_api.dart';
import 'support/fake_voice.dart';

/// Check-ins that say which they are, so the ladder can be read off.
class _NamedLines extends ZenoCheckIns {
  @override
  ZenoLine checkIn(ZenoQuietMoment moment, {required int nudge, String? firstName, String language = 'english'}) =>
      ZenoLine('check-in ${moment.name} $nudge', 'english');

  @override
  ZenoLine resting({String? firstName, String language = 'english'}) => const ZenoLine('resting', 'english');
}

/// A tour host that only writes down what the tour asked of it.
class _Host implements ZenoTourHost {
  final opened = <String>[];
  final said = <String>[];
  final hunted = <String>[];

  @override
  Future<void> tourNavigate(String destination) async => opened.add(destination);

  @override
  Future<void> tourSay(String text, String language) async => said.add(text);

  @override
  void tourStopSpeaking() {}

  @override
  Future<void> tourFindForMe(String query) async => hunted.add(query);

  @override
  Future<void> tourListen() async {}
}

void main() {
  setUpAll(() {
    installFakeApi();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in ['xyz.luan/audioplayers', 'xyz.luan/audioplayers.global']) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
    // Zeno's voice listens to its player's events from the first thing it
    // says; nothing plays here.
    messenger.setMockMethodCallHandler(const MethodChannel('xyz.luan/audioplayers.global/events'), (_) async => null);
    // Its player is made once, here, rather than inside whichever test
    // speaks first: the player's own event channel has no plugin here
    // either, and its name is the player's id.
    BrokaTts.instance;
  });

  setUp(() {
    clearFakeRequests();
    SharedPreferences.setMockInitialValues({});
    ZenoLauncherPrefs.reset();
  });

  tearDown(() {
    setFakeRoute(null);
    ApiService.currentUserId = null;
    ApiService.currentUserName = null;
  });

  // ── The microphone ─────────────────────────────────────────────────────────

  group('the microphone is not lost', () {
    ZenoVoiceController controller(FakeRecorder mic, {List<FakeSocket>? sockets, Duration? stallAfter,
        List<Uri>? uris, List<String>? heard}) {
      return ZenoVoiceController(
        onSubmit: (t) async => heard?.add(t),
        languageKey: () => 'english',
        stallAfter: stallAfter ?? const Duration(seconds: 4),
        service: DeepgramSttService(
          microphone: MicrophoneSource(recorder: mic),
          fetchToken: () async => 't',
          connect: (uri, __) {
            uris?.add(uri);
            final s = FakeSocket();
            sockets?.add(s);
            return s;
          },
        ),
      );
    }

    test("Zeno's own voice cannot pause it", () async {
      // record's default (AudioInterruptionMode.pause) paused capture for
      // good the first time BrokaTts's player took the audio focus - the
      // first time Zeno answered.
      final mic = FakeRecorder();
      final c = controller(mic);
      await c.open();
      expect(mic.lastConfig!.audioInterruption, AudioInterruptionMode.none);
      c.dispose();
    });

    test('a microphone that stops sending audio is opened again, and what was said stays', () async {
      final mic = FakeRecorder();
      final sockets = <FakeSocket>[];
      final c = controller(mic, sockets: sockets, stallAfter: const Duration(milliseconds: 200));
      await c.open();
      for (var i = 0; i < 4; i++) {
        mic.emit(pcmOfMs(40));
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
      sockets.last.emit(deepgramResults('a phone under', isFinal: true));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(c.transcript.text, 'a phone under');

      // The platform pauses the recorder; the socket stays up on its own.
      for (var waited = 0; mic.startCount < 2 && waited < 2000; waited += 20) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(mic.startCount, 2, reason: 'the microphone was opened again');
      // The new recorder delivers audio again, and that is the end of it.
      for (var i = 0; i < 10; i++) {
        mic.emit(pcmOfMs(40));
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
      expect(mic.startCount, 2);
      expect(c.isOpen, isTrue);
      expect(c.state, isNot(VoiceSessionState.error));
      expect(c.transcript.text, 'a phone under', reason: 'nothing already said is lost');

      // ...and what is said now is heard.
      sockets.last.emit(deepgramResults('20K', isFinal: true));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(c.transcript.text, 'a phone under 20K');
      c.dispose();
    });

    test('a microphone that never comes back says so instead of "listening"', () async {
      final mic = FakeRecorder();
      final c = controller(mic, stallAfter: const Duration(milliseconds: 150));
      await c.open();
      mic.emit(pcmOfMs(40));
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(c.state, VoiceSessionState.error);
      expect(c.errorMessage, contains('microphone'));
      expect(mic.startCount, 1 + ZenoVoiceController.maxStallRestarts);
      c.dispose();
    });

    test('quiet is not a stall: frames of silence keep coming, and nothing restarts', () async {
      final mic = FakeRecorder();
      final c = controller(mic, stallAfter: const Duration(milliseconds: 200));
      await c.open();
      for (var i = 0; i < 15; i++) {
        mic.emit(pcmOfMs(40, amplitude: 0));
        await Future<void>.delayed(const Duration(milliseconds: 40));
      }
      expect(mic.startCount, 1);
      expect(c.state, VoiceSessionState.listening);
      c.dispose();
    });

    test("Deepgram ends an utterance after a second without words, whatever the room sounds like", () async {
      // Endpointing waits for silence a street never gives it: the words sat
      // in the box, never sent. UtteranceEnd was handled but never asked for.
      final uris = <Uri>[];
      final sockets = <FakeSocket>[];
      final heard = <String>[];
      final c = controller(FakeRecorder(), uris: uris, sockets: sockets, heard: heard);
      await c.open();
      expect(uris.single.queryParameters['utterance_end_ms'], '1000');

      sockets.last.emit(deepgramResults('find me a sofa', isFinal: true));
      sockets.last.emit({'type': 'UtteranceEnd', 'last_word_end': 1.4});
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(heard, ['find me a sofa']);
      c.dispose();
    });
  });

  // ── The session ────────────────────────────────────────────────────────────

  late ZenoSession session;

  Widget app({Widget? home, ZenoCheckIns? checkIns, RealtimeSttProvider Function()? voice}) {
    session = ZenoSession(checkIns: checkIns, voiceService: voice);
    return MaterialApp(
      home: home ?? const Scaffold(body: Center(child: Text('Home'))),
      navigatorObservers: [session.routes],
      builder: (context, child) => ZenoSessionHost(session: session, child: child!),
      onGenerateRoute: (s) => MaterialPageRoute(
        settings: s,
        builder: (_) => Scaffold(body: Text('route ${s.name} ${s.arguments ?? ''}')),
      ),
    );
  }

  Future<void> run(WidgetTester tester, Duration total, {Duration step = const Duration(milliseconds: 50)}) async {
    final end = tester.binding.clock.now().add(total);
    while (tester.binding.clock.now().isBefore(end)) {
      await tester.pump(step);
    }
  }

  Future<void> letTeardownFinish(WidgetTester tester) async {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
    await run(tester, const Duration(milliseconds: 200));
  }

  List<String> said() => [
        for (final r in fakeRequests)
          if (r.uri.path == '/zeno/assistant/turn') (r.json as Map)['message'] as String,
      ];

  group('the session', () {
    late FakeSocket socket;
    late FakeRecorder mic;

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

    Future<void> openVoice(WidgetTester tester) async {
      final voice = fakeVoice();
      await session.start(service: voice, muted: true);
      await run(tester, const Duration(milliseconds: 900));
    }

    Future<void> say(WidgetTester tester, String words, {Duration then = const Duration(seconds: 2)}) async {
      socket.emit(deepgramResults(words, isFinal: true, speechFinal: true));
      await run(tester, then);
    }

    testWidgets('said while Zeno is still answering: sent after the answer, not lost', (tester) async {
      var turn = 0;
      setFakeRoute((uri) {
        if (uri.path != '/zeno/assistant/turn') return null;
        turn++;
        return turn == 1
            ? const FakeResponse({'reply': 'Which kind of phone?', 'action': null}, delay: Duration(seconds: 3))
            : {'reply': 'Got it - under 20K.', 'action': null};
      });
      await tester.pumpWidget(app());
      await openVoice(tester);

      await say(tester, 'find me a phone', then: const Duration(milliseconds: 1200));
      expect(session.thinking, isTrue);
      await say(tester, 'under 20K', then: const Duration(seconds: 5));

      expect(said(), ['find me a phone', 'under 20K']);
      expect(session.reply, 'Got it - under 20K.');
      session.end();
      await letTeardownFinish(tester);
    });

    testWidgets('a silence in voice mode: Zeno checks in, asks again, then says it is stepping back',
        (tester) async {
      setFakeRoute((uri) => uri.path == '/zeno/assistant/turn'
          ? {'reply': 'Hi! What are you looking for today?', 'action': null}
          : null);
      await tester.pumpWidget(app(checkIns: _NamedLines()));
      await openVoice(tester);
      await say(tester, 'hi zeno');
      expect(session.reply, 'Hi! What are you looking for today?');

      await tester.pump(ZenoSession.checkInAfter);
      expect(session.reply, 'check-in afterQuestion 0');
      expect(mic.running, isTrue, reason: 'still listening for the answer');

      await tester.pump(ZenoSession.checkInAgainAfter);
      expect(session.reply, 'check-in afterQuestion 1');
      expect(mic.running, isTrue);

      await tester.pump(ZenoSession.restAfter);
      await letTeardownFinish(tester);
      expect(session.reply, 'resting');
      expect(mic.running, isFalse, reason: 'the speech provider bills by the minute');
      expect(session.isActive, isTrue);
      expect(find.text('TAP TO TALK'), findsOneWidget);
      session.end();
      await run(tester, const Duration(milliseconds: 400));
    });

    testWidgets('anything said starts the check-ins over', (tester) async {
      setFakeRoute((uri) => uri.path == '/zeno/assistant/turn' ? {'reply': 'Sure.', 'action': null} : null);
      await tester.pumpWidget(app(checkIns: _NamedLines()));
      await openVoice(tester);
      await tester.pump(ZenoSession.checkInAfter);
      expect(session.reply, 'check-in nothingYet 0');

      await say(tester, 'show me sofas');
      expect(session.reply, 'Sure.');
      await tester.pump(ZenoSession.checkInAfter);
      expect(session.reply, 'check-in afterReply 0', reason: 'the first check-in again, not the second');
      expect(mic.running, isTrue);
      session.end();
      await letTeardownFinish(tester);
    });

    testWidgets('"show me around", said, starts the tour', (tester) async {
      await tester.pumpWidget(app());
      await openVoice(tester);
      await say(tester, 'can you show me around', then: const Duration(seconds: 1));
      expect(session.tour.phase, ZenoTourPhase.step);
      expect(said(), isEmpty, reason: 'no model needed for that');
      expect(find.text('ZENO TOUR · 1 OF 6'), findsOneWidget);

      // And it hears "next" and "stop".
      await say(tester, 'next', then: const Duration(seconds: 2));
      expect(session.tour.index, 1);
      expect(find.byType(ListingSearchScreen), findsOneWidget);
      await say(tester, 'stop the tour', then: const Duration(seconds: 1));
      expect(session.tour.active, isFalse);
      session.end();
      await letTeardownFinish(tester);
    });
  });

  group('ZenoCheckIns', () {
    test('never the same line twice in a row, with the name some of the time', () {
      final lines = ZenoCheckIns();
      final said = [
        for (var i = 0; i < 40; i++)
          lines.checkIn(ZenoQuietMoment.afterReply, nudge: 0, firstName: 'Xavier').text,
      ];
      for (var i = 1; i < said.length; i++) {
        expect(said[i], isNot(said[i - 1]));
      }
      expect(said.any((l) => l.contains('Xavier')), isTrue);
      expect(said.toSet().length, greaterThan(2));
    });

    test('no name, no line that needs one', () {
      final lines = ZenoCheckIns();
      for (var i = 0; i < 30; i++) {
        expect(lines.checkIn(ZenoQuietMoment.afterQuestion, nudge: 0).text, isNot(contains('{name}')));
        expect(lines.resting().text, isNot(contains('{name}')));
      }
    });

    test('the second check-in asks whether the user is still there', () {
      final lines = ZenoCheckIns();
      for (var i = 0; i < 10; i++) {
        final t = lines.checkIn(ZenoQuietMoment.afterReply, nudge: 1).text.toLowerCase();
        expect(t.contains('still') || t.contains('ready'), isTrue, reason: t);
      }
    });

    test('Swahili and Sheng speakers hear Swahili', () {
      final lines = ZenoCheckIns();
      expect(lines.checkIn(ZenoQuietMoment.nothingYet, nudge: 1, language: 'sheng').language, 'swahili');
      expect(lines.resting(language: 'swahili').language, 'swahili');
      expect(lines.resting(language: 'luo').language, 'english');
    });

    test('what the silence follows', () {
      expect(ZenoCheckIns.momentAfter(null, docked: false), ZenoQuietMoment.nothingYet);
      expect(ZenoCheckIns.momentAfter('Want me to find one?', docked: false), ZenoQuietMoment.afterQuestion);
      expect(ZenoCheckIns.momentAfter('Opening your inbox.', docked: false), ZenoQuietMoment.afterReply);
      expect(ZenoCheckIns.momentAfter('Want me to find one?', docked: true), ZenoQuietMoment.browsing);
    });
  });

  // ── The tour ───────────────────────────────────────────────────────────────

  group('the tour', () {
    test('the commands people say to a guide, and not inside a request', () {
      expect(parseTourCommand('next'), ZenoTourCommand.next);
      expect(parseTourCommand('okay, continue'), ZenoTourCommand.next);
      expect(parseTourCommand('go back'), ZenoTourCommand.back);
      expect(parseTourCommand('say that again'), ZenoTourCommand.repeat);
      expect(parseTourCommand('okay stop'), ZenoTourCommand.stop);
      expect(parseTourCommand('not now'), ZenoTourCommand.stop);
      expect(parseTourCommand('yes please'), ZenoTourCommand.yes);
      expect(parseTourCommand('endelea'), ZenoTourCommand.next);
      expect(parseTourCommand('acha'), ZenoTourCommand.stop);
      expect(parseTourCommand("what's the next step to sell my old car"), isNull);
      expect(parseTourCommand('a laptop'), isNull);
    });

    test('a tour is asked for in so many words', () {
      expect(isTourRequest('Give me a tour'), isTrue);
      expect(isTourRequest('can you show me around'), isTrue);
      expect(isTourRequest('walk me through the app'), isTrue);
      expect(isTourRequest('nitembeze'), isTrue);
      expect(isTourRequest('find me a tour guide in Mombasa'), isFalse);
      expect(isTourRequest('show me phones'), isFalse);
    });

    test('step by step, by voice: next, back, again, and anything else ends it', () async {
      final host = _Host();
      final tour = ZenoTour(host, settle: Duration.zero);
      tour.begin(firstName: 'Xavier');
      await Future<void>.delayed(Duration.zero);
      expect(tour.phase, ZenoTourPhase.step);
      expect(host.opened, ['home']);
      expect(tour.handleSpeech('next'), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(host.opened, ['home', 'search']);
      expect(tour.handleSpeech('go back'), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(tour.index, 0);
      expect(tour.handleSpeech('how much does a listing cost?'), isFalse,
          reason: 'a real question is answered as usual');
      expect(tour.active, isFalse);
      tour.dispose();
    });

    test('the demo: what the user would love to buy is hunted with the Buying Agent', () async {
      final host = _Host();
      final tour = ZenoTour(host, settle: Duration.zero);
      tour.begin();
      for (var i = 0; i < tour.stepCount; i++) {
        tour.next();
        await Future<void>.delayed(Duration.zero);
      }
      expect(tour.phase, ZenoTourPhase.demo);
      expect(tour.handleSpeech('yes'), isTrue);
      expect(host.hunted, isEmpty, reason: '"yes" is not something to buy');
      expect(tour.handleSpeech('a PS5 under 50K'), isTrue);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(host.hunted, ['a PS5 under 50K']);
      expect(tour.phase, ZenoTourPhase.finale);
      expect(tour.demoRan, isTrue);
      tour.dispose();
    });

    testWidgets('a new account: the first time Home is in front, Zeno offers the tour - once', (tester) async {
      ApiService.currentUserId = 'new-1';
      ApiService.currentUserName = 'Xavier Otieno';
      await ZenoTourStore.markNewAccount('new-1');
      await tester.pumpWidget(app());
      await run(tester, const Duration(seconds: 3));
      expect(session.tour.phase, ZenoTourPhase.welcome);
      expect(find.text('MEET ZENO'), findsOneWidget);
      expect(find.byKey(const Key('zeno-tour-start')), findsOneWidget);
      expect(session.tour.line, startsWith('Hi Xavier, welcome to BROKA!'));
      expect(await ZenoTourStore.isPending('new-1'), isFalse, reason: 'offered once');

      await tester.tap(find.byKey(const Key('zeno-tour-later')));
      await run(tester, const Duration(seconds: 1));
      expect(session.tour.active, isFalse);
      expect(find.text('MEET ZENO'), findsNothing);
    });

    testWidgets('not over a screen sign-up was for: it waits for Home', (tester) async {
      ApiService.currentUserId = 'new-2';
      await ZenoTourStore.markNewAccount('new-2');
      await tester.pumpWidget(app());
      final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
      // Signed up on the way to Sell: Sell opens first.
      nav.pushNamed('/sell');
      await run(tester, const Duration(seconds: 3));
      expect(session.tour.active, isFalse);
      nav.pop();
      await run(tester, const Duration(seconds: 3));
      expect(session.tour.phase, ZenoTourPhase.welcome);
    });

    testWidgets('the tour opens each screen as Zeno talks about it, then asks what to hunt', (tester) async {
      ApiService.currentUserId = 'u-tour';
      await tester.pumpWidget(app());
      await run(tester, const Duration(milliseconds: 300));
      session.toggleMute();
      session.startTour();
      await run(tester, const Duration(seconds: 1));
      expect(find.text('ZENO TOUR · 1 OF 6'), findsOneWidget);
      expect(find.text('Home'), findsWidgets);

      // It moves on by itself once a step has had its time.
      await run(tester, const Duration(seconds: 14), step: const Duration(milliseconds: 200));
      expect(session.tour.index, 1);
      expect(find.byType(ListingSearchScreen), findsOneWidget);

      await tester.tap(find.byKey(const Key('zeno-tour-next')));
      await run(tester, const Duration(seconds: 2));
      expect(find.byType(ZenoScreen), findsOneWidget, reason: 'the Buying Agent');
      expect(find.byType(ListingSearchScreen), findsNothing, reason: 'replaced, not stacked');

      await tester.tap(find.byKey(const Key('zeno-tour-next')));
      await run(tester, const Duration(seconds: 2));
      expect(find.text('route /inbox '), findsOneWidget);

      for (var i = 0; i < 3; i++) {
        await tester.tap(find.byKey(const Key('zeno-tour-next')));
        await run(tester, const Duration(seconds: 2));
      }
      expect(session.tour.phase, ZenoTourPhase.demo);
      expect(find.text('Home'), findsWidgets, reason: 'back on Home for the demo');

      await tester.enterText(find.byKey(const Key('zeno-tour-demo-field')), 'a phone under 20K');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await run(tester, const Duration(seconds: 3));
      final converse = fakeRequests.where((r) => r.uri.path == '/buy-agent-requests/converse');
      expect((converse.last.json as Map)['message'], 'a phone under 20K');
      expect(session.tour.phase, ZenoTourPhase.finale);

      await tester.tap(find.byKey(const Key('zeno-tour-done')));
      await run(tester, const Duration(seconds: 1));
      expect(session.tour.active, isFalse);
      expect(tester.takeException(), isNull);
    });
  });

  // ── The orb on every screen ────────────────────────────────────────────────

  group("Zeno's orb", () {
    final orb = find.byKey(const Key('zeno-launcher'));

    testWidgets('signed in, it is on the screen, and a tap opens voice', (tester) async {
      ApiService.currentUserId = 'u1';
      final mic = FakeRecorder();
      await tester.pumpWidget(app(
        voice: () => DeepgramSttService(
          microphone: MicrophoneSource(recorder: mic),
          fetchToken: () async => 't',
          connect: (_, __) => FakeSocket(),
        ),
      ));
      await run(tester, const Duration(milliseconds: 600));
      expect(orb, findsOneWidget);

      session.toggleMute();
      await tester.tap(orb);
      await run(tester, const Duration(milliseconds: 900));
      expect(session.isActive, isTrue);
      expect(session.expanded, isTrue);
      expect(mic.running, isTrue, reason: 'listening');
      expect(orb, findsNothing, reason: 'Zeno is open: the orb steps aside');
      session.end();
      await letTeardownFinish(tester);
    });

    testWidgets('held, it opens the typed conversation', (tester) async {
      ApiService.currentUserId = 'u1';
      await tester.pumpWidget(app());
      await run(tester, const Duration(milliseconds: 600));
      await tester.longPress(orb);
      await run(tester, const Duration(milliseconds: 600));
      expect(find.text('route /zeno '), findsOneWidget);
      expect(orb, findsNothing, reason: 'the Zeno tab has its own microphone');
    });

    testWidgets('not when signed out, over sign-in or a call, over a dialog - or switched off', (tester) async {
      await tester.pumpWidget(app());
      await run(tester, const Duration(milliseconds: 600));
      expect(orb, findsNothing, reason: 'signed out');

      ApiService.currentUserId = 'u1';
      final nav = tester.state<NavigatorState>(find.byType(Navigator).first);
      nav.pushNamed('/inbox');
      await run(tester, const Duration(milliseconds: 600));
      expect(orb, findsOneWidget);

      nav.pushNamed('/voip-call');
      await run(tester, const Duration(milliseconds: 600));
      expect(orb, findsNothing, reason: 'in a call');
      nav.pop();
      await run(tester, const Duration(milliseconds: 600));
      expect(orb, findsOneWidget);

      showDialog<void>(context: nav.context, builder: (_) => const AlertDialog(content: Text('Sure?')));
      await run(tester, const Duration(milliseconds: 600));
      expect(orb, findsNothing, reason: 'over a dialog');
      nav.pop();
      await run(tester, const Duration(milliseconds: 600));
      expect(orb, findsOneWidget);

      await ZenoLauncherPrefs.setEnabled(false);
      await run(tester, const Duration(milliseconds: 600));
      expect(orb, findsNothing, reason: 'switched off in Settings');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('zeno_launcher_on'), isFalse);
    });

    testWidgets('dragged across, it stays on the side it was put', (tester) async {
      ApiService.currentUserId = 'u1';
      await tester.pumpWidget(app());
      await run(tester, const Duration(milliseconds: 600));
      final width = tester.view.physicalSize.width / tester.view.devicePixelRatio;
      expect(tester.getCenter(orb).dx, greaterThan(width / 2));
      await tester.drag(orb, Offset(-width * 0.8, -60));
      await run(tester, const Duration(milliseconds: 800));
      expect(tester.getCenter(orb).dx, lessThan(width / 2));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('zeno_launcher_left'), isTrue);
    });
  });
}
