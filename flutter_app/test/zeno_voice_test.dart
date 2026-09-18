// Covers the Zeno voice layer: the Deepgram service, the session controller,
// and the floating card.
//
// All three seams that cannot exist in a test - a microphone, BROKA's backend,
// and Deepgram's WebSocket - are injected, so these tests drive the real
// service and the real controller rather than a mock of them. The fake socket
// below emits Deepgram's actual frame shapes, which means a change to the
// parsing that broke on a real `Results` frame breaks here too.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:broka/services/deepgram_stt_service.dart';
import 'package:broka/services/zeno_voice_controller.dart';
import 'package:broka/widgets/voice_waveform.dart';
import 'package:broka/widgets/zeno_voice_card.dart';
import 'package:broka/widgets/zeno_avatar.dart';

void main() {
  group('DeepgramSttService', () {
    test('asks for one token per session and connects with Deepgram params',
        () async {
      final socket = _FakeSocket();
      var tokenCalls = 0;
      Uri? connectedTo;
      String? connectedWith;

      final service = DeepgramSttService(
        recorder: _FakeRecorder(),
        fetchToken: () async {
          tokenCalls++;
          return 'temp-jwt';
        },
        connect: (uri, token) {
          connectedTo = uri;
          connectedWith = token;
          return socket;
        },
      );

      await service.start(brokaLanguage: 'english');

      expect(tokenCalls, 1, reason: 'one token per session, not per utterance');
      expect(connectedWith, 'temp-jwt');
      expect(connectedTo!.scheme, 'wss');
      expect(connectedTo!.host, 'api.deepgram.com');
      expect(connectedTo!.path, '/v1/listen');

      final q = connectedTo!.queryParameters;
      // The configuration the brief specifies, checked rather than assumed:
      // these are what make interim text, endpointing and KES formatting work.
      expect(q['encoding'], 'linear16');
      expect(q['sample_rate'], '16000');
      expect(q['channels'], '1');
      expect(q['interim_results'], 'true');
      expect(q['smart_format'], 'true');
      expect(q['vad_events'], 'true');
      expect(q['endpointing'], '300');
      expect(q['model'], 'nova-3');
      expect(q['language'], 'en');

      await service.cancel();
      await service.dispose();
    });

    test('a second start while listening does not open a second session',
        () async {
      var connects = 0;
      final service = DeepgramSttService(
        recorder: _FakeRecorder(),
        fetchToken: () async => 't',
        connect: (_, __) {
          connects++;
          return _FakeSocket();
        },
      );

      await service.start();
      await service.start();
      await service.start();

      // One microphone, one socket, one bill.
      expect(connects, 1);
      await service.dispose();
    });

    test('denied microphone permission fails before any token is fetched',
        () async {
      var tokenCalls = 0;
      final service = DeepgramSttService(
        recorder: _FakeRecorder(permitted: false),
        fetchToken: () async {
          tokenCalls++;
          return 't';
        },
        connect: (_, __) => _FakeSocket(),
      );

      await expectLater(
        service.start(),
        throwsA(isA<VoiceSessionException>().having(
            (e) => e.failure, 'failure', VoiceFailure.microphoneDenied)),
      );
      expect(tokenCalls, 0);
      expect(service.isListening, isFalse);
      await service.dispose();
    });

    test('streams PCM to the socket as binary frames', () async {
      final socket = _FakeSocket();
      final recorder = _FakeRecorder();
      final service = DeepgramSttService(
        recorder: recorder,
        fetchToken: () async => 't',
        connect: (_, __) => socket,
      );
      await service.start();

      final chunk = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
      recorder.emit(chunk);
      await Future<void>.delayed(Duration.zero);

      expect(socket.sentBinary, isNotEmpty);
      expect(socket.sentBinary.first, chunk,
          reason: 'raw PCM, not base64 and not re-encoded');

      await service.dispose();
    });

    test('interim, final and speech-final all surface', () async {
      final socket = _FakeSocket();
      final service = DeepgramSttService(
        recorder: _FakeRecorder(),
        fetchToken: () async => 't',
        connect: (_, __) => socket,
      );
      final interims = <String>[];
      final finals = <String>[];
      var speechFinals = 0;
      var started = 0;
      service.interimTranscript.listen(interims.add);
      service.finalTranscript.listen(finals.add);
      service.speechFinal.listen((_) => speechFinals++);
      service.speechStarted.listen((_) => started++);

      await service.start();

      socket.emit({'type': 'SpeechStarted'});
      socket.emit(_results('Find me a phone under', isFinal: false));
      socket.emit(_results('Find me a phone under KES 20,000',
          isFinal: true, speechFinal: true));
      await Future<void>.delayed(Duration.zero);

      expect(started, 1);
      expect(interims, ['Find me a phone under']);
      expect(finals, ['Find me a phone under KES 20,000']);
      expect(speechFinals, 1);

      await service.dispose();
    });

    test('an empty final still closes the turn', () async {
      // Deepgram sends empty finals at the end of silence; they carry the
      // speech_final flag that ends a turn even though the text does not.
      final socket = _FakeSocket();
      final service = DeepgramSttService(
        recorder: _FakeRecorder(),
        fetchToken: () async => 't',
        connect: (_, __) => socket,
      );
      var speechFinals = 0;
      final finals = <String>[];
      service.speechFinal.listen((_) => speechFinals++);
      service.finalTranscript.listen(finals.add);

      await service.start();
      socket.emit(_results('', isFinal: true, speechFinal: true));
      await Future<void>.delayed(Duration.zero);

      expect(speechFinals, 1);
      expect(finals, isEmpty, reason: 'no empty transcript should be emitted');
      await service.dispose();
    });

    test('malformed frames are ignored rather than fatal', () async {
      final socket = _FakeSocket();
      final service = DeepgramSttService(
        recorder: _FakeRecorder(),
        fetchToken: () async => 't',
        connect: (_, __) => socket,
      );
      await service.start();

      // Every shape a flaky connection can produce.
      socket.emitRaw('not json at all');
      socket.emitRaw('[1,2,3]');
      socket.emit({'type': 'Results'});
      socket.emit({'type': 'Results', 'channel': 'nope'});
      socket.emit({'type': 'Results', 'channel': {'alternatives': []}});
      socket.emit({'type': 'Results', 'channel': {'alternatives': [42]}});
      socket.emit({'type': 'SomethingDeepgramAddedLater'});
      await Future<void>.delayed(Duration.zero);

      expect(service.isListening, isTrue, reason: 'session survived the noise');
      await service.dispose();
    });

    test('stop closes the microphone and the socket', () async {
      final socket = _FakeSocket();
      final recorder = _FakeRecorder();
      final service = DeepgramSttService(
        recorder: recorder,
        fetchToken: () async => 't',
        connect: (_, __) => socket,
      );
      await service.start();
      expect(service.isListening, isTrue);

      await service.stop();

      expect(service.isListening, isFalse);
      expect(recorder.stopped, isTrue, reason: 'microphone must not stay open');
      expect(socket.closed, isTrue);
      // Deepgram is asked to flush before the socket goes, or the last words
      // of an utterance are lost.
      expect(socket.sentText.any((m) => m.contains('Finalize')), isTrue);
      await service.dispose();
    });

    test('cancel tears down without waiting for a flush', () async {
      final socket = _FakeSocket();
      final recorder = _FakeRecorder();
      final service = DeepgramSttService(
        recorder: recorder,
        fetchToken: () async => 't',
        connect: (_, __) => socket,
      );
      await service.start();
      await service.cancel();

      expect(service.isListening, isFalse);
      expect(service.isConnected, isFalse);
      expect(recorder.cancelled, isTrue);
      await service.dispose();
    });

    test('a token failure never reaches the socket', () async {
      var connects = 0;
      final service = DeepgramSttService(
        recorder: _FakeRecorder(),
        fetchToken: () async =>
            throw VoiceSessionException(VoiceFailure.notConfigured),
        connect: (_, __) {
          connects++;
          return _FakeSocket();
        },
      );

      await expectLater(
        service.start(),
        throwsA(isA<VoiceSessionException>().having(
            (e) => e.failure, 'failure', VoiceFailure.notConfigured)),
      );
      expect(connects, 0);
      await service.dispose();
    });
  });

  group('language mapping', () {
    test('English is the one verified mapping', () {
      final en = DeepgramLanguage.forBrokaLanguage('english');
      expect(en.language, 'en');
      expect(en.verified, isTrue);
    });

    test('the other BROKA languages are flagged unverified', () {
      // The card shows a note for these. If someone later confirms a real
      // Deepgram language for Kiswahili and flips the flag, this test is the
      // reminder that the note disappears with it.
      for (final key in const ['swahili', 'sheng', 'luo', 'kikuyu', 'luganda']) {
        final m = DeepgramLanguage.forBrokaLanguage(key);
        expect(m.verified, isFalse, reason: key);
        expect(m.language, 'multi', reason: key);
      }
    });

    test('an unknown or null language falls back to English', () {
      expect(DeepgramLanguage.forBrokaLanguage(null).language, 'en');
      expect(DeepgramLanguage.forBrokaLanguage('klingon').language, 'en');
      expect(DeepgramLanguage.forBrokaLanguage('  ENGLISH  ').language, 'en');
    });
  });

  group('ZenoVoiceController', () {
    late _FakeSocket socket;
    late _FakeRecorder recorder;

    ZenoVoiceController build({
      required List<String> sent,
      bool autoSend = true,
      String language = 'english',
    }) {
      socket = _FakeSocket();
      recorder = _FakeRecorder();
      return ZenoVoiceController(
        onSubmit: (t) async => sent.add(t),
        languageKey: () => language,
        autoSend: autoSend,
        service: DeepgramSttService(
          recorder: recorder,
          fetchToken: () async => 't',
          connect: (_, __) => socket,
        ),
      );
    }

    test('open moves idle -> connecting -> listening', () async {
      final sent = <String>[];
      final c = build(sent: sent);
      expect(c.state, VoiceSessionState.idle);
      expect(c.isOpen, isFalse);

      await c.open();
      expect(c.isOpen, isTrue);
      expect(c.state, VoiceSessionState.listening);
      c.dispose();
    });

    test('interim text lands on the controller, final text in the box',
        () async {
      final sent = <String>[];
      final c = build(sent: sent);
      await c.open();

      socket.emit(_results('I need a laptop', isFinal: false));
      await Future<void>.delayed(Duration.zero);
      expect(c.interim, 'I need a laptop');
      expect(c.transcript.text, isEmpty);

      socket.emit(_results('I need a laptop for work', isFinal: true));
      await Future<void>.delayed(Duration.zero);
      expect(c.interim, isEmpty);
      expect(c.transcript.text, 'I need a laptop for work');
      expect(c.state, VoiceSessionState.processing);
      c.dispose();
    });

    test('direct voice mode sends a completed utterance on its own', () async {
      final sent = <String>[];
      final c = build(sent: sent);
      await c.open();

      socket.emit(_results('I need a laptop for work',
          isFinal: true, speechFinal: true));
      await Future<void>.delayed(Duration.zero);
      expect(c.state, VoiceSessionState.readyToSend);
      expect(sent, isEmpty, reason: 'there is a grace period first');

      // Past the grace period that lets someone keep talking mid-thought.
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(sent, ['I need a laptop for work']);
      expect(c.transcript.text, isEmpty, reason: 'box clears for the next turn');
      c.dispose();
    });

    test('editing cancels the auto-send so nothing is sent mid-correction',
        () async {
      final sent = <String>[];
      final c = build(sent: sent);
      await c.open();

      socket.emit(_results('Find me a good phone under twenty thousand',
          isFinal: true, speechFinal: true));
      await Future<void>.delayed(Duration.zero);

      c.markEdited();
      c.transcript.text = 'Find me a Samsung phone under KES 20,000';

      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(sent, isEmpty, reason: 'the user was still typing');
      expect(c.state, VoiceSessionState.readyToSend);

      await c.submit();
      expect(sent, ['Find me a Samsung phone under KES 20,000']);
      c.dispose();
    });

    test('autoSend false always waits for the send button', () async {
      final sent = <String>[];
      final c = build(sent: sent, autoSend: false);
      await c.open();

      socket.emit(_results('hello', isFinal: true, speechFinal: true));
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(sent, isEmpty);
      expect(c.state, VoiceSessionState.readyToSend);
      c.dispose();
    });

    test('empty transcripts are never sent', () async {
      final sent = <String>[];
      final c = build(sent: sent);
      await c.open();
      c.transcript.text = '   ';
      await c.submit();
      expect(sent, isEmpty);
      c.dispose();
    });

    test('Zeno speaking shows, then returns to listening', () async {
      final sent = <String>[];
      final c = build(sent: sent);
      await c.open();

      c.setZenoSpeaking(true);
      expect(c.state, VoiceSessionState.speaking);
      c.setZenoSpeaking(false);
      expect(c.state, VoiceSessionState.listening,
          reason: 'the card takes the next turn');
      c.dispose();
    });

    test('close stops everything and leaves no state behind', () async {
      final sent = <String>[];
      final c = build(sent: sent);
      await c.open();
      c.transcript.text = 'half a sentence';

      await c.close();

      expect(c.isOpen, isFalse);
      expect(c.state, VoiceSessionState.idle);
      expect(c.transcript.text, isEmpty);
      expect(recorder.cancelled, isTrue, reason: 'microphone must be released');
      expect(socket.closed, isTrue);
      c.dispose();
    });

    test('a failure surfaces one honest sentence and keeps typing possible',
        () async {
      final sent = <String>[];
      final c = ZenoVoiceController(
        onSubmit: (t) async => sent.add(t),
        languageKey: () => 'english',
        service: DeepgramSttService(
          recorder: _FakeRecorder(permitted: false),
          fetchToken: () async => 't',
          connect: (_, __) => _FakeSocket(),
        ),
      );

      await c.open();
      expect(c.state, VoiceSessionState.error);
      expect(c.errorMessage, contains('Microphone access'));
      c.dispose();
    });

    test('an unsupported language is flagged, not hidden', () async {
      final sent = <String>[];
      final c = build(sent: sent, language: 'luo');
      await c.open();
      expect(c.languageUnverified, isTrue);
      c.dispose();

      final c2 = build(sent: sent, language: 'english');
      await c2.open();
      expect(c2.languageUnverified, isFalse);
      c2.dispose();
    });
  });

  group('ZenoVoiceCard', () {
    late ZenoVoiceController controller;
    late _FakeSocket socket;
    late List<String> sent;

    Widget host() {
      return MaterialApp(
        home: Scaffold(
          body: ZenoVoiceOverlay(
            controller: controller,
            child: Column(children: const [
              Text('an existing conversation message'),
              Spacer(),
              Text('the composer'),
            ]),
          ),
        ),
      );
    }

    setUp(() {
      sent = [];
      socket = _FakeSocket();
      controller = ZenoVoiceController(
        onSubmit: (t) async => sent.add(t),
        languageKey: () => 'english',
        service: DeepgramSttService(
          recorder: _FakeRecorder(),
          fetchToken: () async => 't',
          connect: (_, __) => socket,
        ),
      );
    });

    tearDown(() => controller.dispose());

    testWidgets('closed by default - the microphone is not opened on entry',
        (tester) async {
      await tester.pumpWidget(host());
      await tester.pump();
      expect(find.byType(ZenoVoiceCard), findsNothing);
      expect(find.text('an existing conversation message'), findsOneWidget);
    });

    testWidgets('opens at the TOP, over a dimmed but visible conversation',
        (tester) async {
      tester.view.physicalSize = const Size(390 * 3, 844 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(host());
      await controller.open();
      await _settle(tester);

      expect(find.byType(ZenoVoiceCard), findsOneWidget);

      final card = tester.getRect(find.byType(ZenoVoiceCard));
      final screen = tester.getSize(find.byType(MaterialApp));
      // Top of the screen, not the middle and not the bottom.
      expect(card.top, lessThan(screen.height * 0.12));
      // Roughly a quarter to a third of the screen, never a takeover.
      expect(card.height / screen.height, lessThan(0.4));

      // The conversation is still there and still readable underneath.
      expect(find.text('an existing conversation message'), findsOneWidget);
      expect(find.text('the composer'), findsOneWidget);
    });

    testWidgets('is Zeno communication, not a phone call', (tester) async {
      await tester.pumpWidget(host());
      await controller.open();
      await _settle(tester);

      // None of these belong on this card - BROKA has real buyer/seller
      // calling elsewhere and confusing the two would be bad.
      for (final forbidden in const [
        Icons.call,
        Icons.call_end,
        Icons.call_end_rounded,
        Icons.phone,
        Icons.phone_rounded,
        Icons.videocam,
        Icons.videocam_rounded,
        Icons.pause,
        Icons.pause_rounded,
        Icons.stop,
        Icons.stop_rounded,
      ]) {
        expect(find.byIcon(forbidden), findsNothing,
            reason: '$forbidden is a telephone control');
      }
      // What it does have: Zeno, a waveform and one close button.
      expect(find.byType(ZenoAvatar), findsOneWidget);
      expect(find.byType(VoiceWaveform), findsOneWidget);
      expect(find.byIcon(Icons.close_rounded), findsOneWidget);
    });

    testWidgets('shows live interim text, then an editable final transcript',
        (tester) async {
      await tester.pumpWidget(host());
      await controller.open();
      await _settle(tester);

      socket.emit(_results('Find me a good phone under', isFinal: false));
      await tester.pump();
      await tester.pump();
      expect(find.text('Find me a good phone under'), findsOneWidget);

      socket.emit(_results('Find me a good phone under KES 20,000',
          isFinal: true));
      await tester.pump();
      await tester.pump();

      // Final text arrives in a real, editable field.
      final field = find.byType(TextField);
      expect(field, findsOneWidget);
      expect(controller.transcript.text, 'Find me a good phone under KES 20,000');

      await tester.enterText(field, 'Find me a Samsung phone under KES 20,000');
      await tester.pump();
      expect(controller.transcript.text,
          'Find me a Samsung phone under KES 20,000');
    });

    testWidgets('the send button submits the edited text', (tester) async {
      await tester.pumpWidget(host());
      await controller.open();
      await _settle(tester);

      socket.emit(_results('tell the seller eighteen thousand', isFinal: true));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.byIcon(Icons.arrow_forward_rounded));
      await tester.pump();
      await tester.pump();

      expect(sent, ['tell the seller eighteen thousand']);
    });

    testWidgets('X closes the card and leaves the conversation alone',
        (tester) async {
      await tester.pumpWidget(host());
      await controller.open();
      await _settle(tester);
      expect(find.byType(ZenoVoiceCard), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close_rounded));
      await _settle(tester);

      expect(find.byType(ZenoVoiceCard), findsNothing);
      expect(controller.state, VoiceSessionState.idle);
      // The thing underneath never went anywhere.
      expect(find.text('an existing conversation message'), findsOneWidget);
      expect(find.text('the composer'), findsOneWidget);
    });

    testWidgets('states read as sentences a user can act on', (tester) async {
      await tester.pumpWidget(host());
      await controller.open();
      await _settle(tester);
      expect(find.textContaining('Listening'), findsOneWidget);

      controller.setZenoSpeaking(true);
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('Zeno is speaking'), findsOneWidget);

      controller.setZenoSpeaking(false);
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('Listening'), findsOneWidget);
    });

    // One test per width rather than a loop: each gets the group's freshly
    // built controller from setUp, which is the shape every other card test
    // uses. A loop would mount and unmount five sessions on one controller,
    // which tests the harness more than the card.
    for (final width in const [320.0, 340.0, 360.0, 390.0, 430.0]) {
      testWidgets('fits a ${width.toInt()}dp phone without overflow',
          (tester) async {
        tester.view.physicalSize = Size(width * 2, 760 * 2);
        tester.view.devicePixelRatio = 2.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(host());
        await controller.open();
        await _settle(tester);

        socket.emit(_results(
            'Find me a Samsung Galaxy A54 128GB under KES 20,000 in Nairobi',
            isFinal: true));
        await _settle(tester);

        expect(tester.takeException(), isNull);
        final card = tester.getRect(find.byType(ZenoVoiceCard));
        // Never a takeover: the conversation underneath stays the screen.
        expect(card.height / 760.0, lessThan(0.4));
        // And pinned to the top on every width.
        expect(card.top, lessThan(760.0 * 0.12));
      });
    }
  });
}

// ── Helpers ──────────────────────────────────────────────────────────────────

/// pumpAndSettle cannot be used on this card: VoiceWaveform runs a repeating
/// controller by design, so the card never stops scheduling frames. A fixed
/// handful of pumps is enough - every future in these tests resolves on a
/// microtask and the entrance animation is 220ms.
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

// ── Fakes ────────────────────────────────────────────────────────────────────

/// A Deepgram `Results` frame, in the shape the real service sends.
Map<String, dynamic> _results(String text,
        {required bool isFinal, bool speechFinal = false}) =>
    {
      'type': 'Results',
      'is_final': isFinal,
      'speech_final': speechFinal,
      'channel': {
        'alternatives': [
          {'transcript': text, 'confidence': 0.98}
        ]
      },
    };

class _FakeSocket implements WebSocketChannel {
  final _incoming = StreamController<dynamic>.broadcast();
  final _sink = _FakeSink();

  final List<Uint8List> sentBinary = [];
  final List<String> sentText = [];
  bool closed = false;

  _FakeSocket() {
    _sink.onAdd = (data) {
      if (data is Uint8List) {
        sentBinary.add(data);
      } else if (data is String) {
        sentText.add(data);
      }
    };
    _sink.onClose = () => closed = true;
  }

  void emit(Map<String, dynamic> event) => emitRaw(jsonEncode(event));

  void emitRaw(String raw) {
    if (!_incoming.isClosed) _incoming.add(raw);
  }

  @override
  Stream get stream => _incoming.stream;

  @override
  WebSocketSink get sink => _sink;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeSink implements WebSocketSink {
  void Function(dynamic)? onAdd;
  void Function()? onClose;

  @override
  void add(dynamic data) => onAdd?.call(data);

  @override
  Future close([int? closeCode, String? closeReason]) async => onClose?.call();

  @override
  Future addStream(Stream stream) async {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future get done async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeRecorder implements AudioRecorder {
  _FakeRecorder({this.permitted = true});

  final bool permitted;
  final _audio = StreamController<Uint8List>.broadcast();
  bool stopped = false;
  bool cancelled = false;

  void emit(Uint8List chunk) {
    if (!_audio.isClosed) _audio.add(chunk);
  }

  @override
  Future<bool> hasPermission({bool request = true}) async => permitted;

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async {
    // The service must ask for exactly what Deepgram's linear16 expects.
    expect(config.encoder, AudioEncoder.pcm16bits);
    expect(config.sampleRate, 16000);
    expect(config.numChannels, 1);
    return _audio.stream;
  }

  @override
  Future<String?> stop() async {
    stopped = true;
    return null;
  }

  @override
  Future<void> cancel() async {
    cancelled = true;
  }

  @override
  Future<void> dispose() async {
    if (!_audio.isClosed) await _audio.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
