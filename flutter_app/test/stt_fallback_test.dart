// Covers the realtime STT layer below ZenoVoiceController: how each provider
// fails, how those failures are told apart, and what RealtimeSttManager does
// about them.
//
// The Deepgram group exists because the original service could not say WHY a
// session failed - every path produced one sentence, which made a real
// on-device failure impossible to diagnose from a screenshot. Each test here
// pins one cause to one VoiceFailure and one greppable diagnostic event.
//
// The manager group exists to hold the two invariants that make a fallback
// safe rather than a second bug: exactly one provider runs at a time, and a
// failover never sends Zeno the same sentence twice.
import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:broka/services/assemblyai_stt_service.dart';
import 'package:broka/services/deepgram_stt_service.dart';
import 'package:broka/services/realtime_stt.dart';
import 'package:broka/services/realtime_stt_manager.dart';
import 'package:broka/services/zeno_voice_controller.dart';

import 'support/fake_voice.dart';

void main() {
  setUp(() {
    SttDiagnostics.clear();
    // Static, and deliberately so in production - one session's discovery that
    // this device drops handshake headers should save every later session the
    // attempt. Tests have to reset it or they leak into each other.
    DeepgramSttService.preferredAuthMode = DeepgramAuthMode.header;
  });

  /// The last diagnostic with this event name, or null.
  SttDiagnostic? diag(String event) {
    for (final d in SttDiagnostics.recent.reversed) {
      if (d.event == event) return d;
    }
    return null;
  }

  bool sawEvent(String event) => diag(event) != null;

  // ══ Deepgram: telling failures apart ═══════════════════════════════════════

  group('Deepgram failure diagnosis', () {
    test('a refused upgrade is a handshake failure, not "unknown"', () async {
      final socket = FakeSocket(
        handshakeError: WebSocketChannelException.from(const WebSocketException(
            "Connection to 'https://api.deepgram.com/v1/listen' was not "
            'upgraded to websocket, HTTP status code: 401')),
      );
      final recorder = FakeRecorder();
      final service = DeepgramSttService(
        microphone: MicrophoneSource(recorder: recorder),
        fetchToken: () async => 'temp-jwt',
        connect: (_, __) => socket,
      );

      await expectLater(
        service.start(),
        throwsA(isA<VoiceSessionException>().having(
            (e) => e.failure, 'failure', VoiceFailure.handshakeFailed)),
      );

      // The single most useful string in the whole feature: the HTTP status
      // separates "Deepgram refused the credential" from "the network never
      // got there".
      final d = diag('DEEPGRAM_HANDSHAKE_FAILED');
      expect(d, isNotNull);
      expect(d!.safeError, contains('401'));
      expect(d.stage, SttStage.handshake);

      // And the race that made this invisible: a failed handshake must never
      // reach the microphone.
      expect(recorder.startCount, 0);
      expect(service.isListening, isFalse);
      await service.dispose();
    });

    test('a dead network is reported as a network failure, not a bad key',
        () async {
      final socket = FakeSocket(
        handshakeError: WebSocketChannelException.from(
            const SocketException('Failed host lookup: api.deepgram.com')),
      );
      final service = DeepgramSttService(
        microphone: MicrophoneSource(recorder: FakeRecorder()),
        fetchToken: () async => 't',
        connect: (_, __) => socket,
      );

      await expectLater(service.start(), throwsA(isA<VoiceSessionException>()));
      expect(sawEvent('DEEPGRAM_NETWORK_UNREACHABLE'), isTrue);
      await service.dispose();
    });

    test('a header handshake that fails is retried on the documented '
        'query-parameter transport', () async {
      // Why this exists: a carrier proxy or an OEM network stack can drop a
      // WebSocket handshake header, and when it does the header form fails
      // exactly like a bad credential - no body, no message. Deepgram
      // documents ?access_token= for clients that cannot send headers, so one
      // retry is the difference between "voice is broken on this phone" and a
      // short delay.
      final attempts = <Map<String, String>>[];
      final uris = <Uri>[];
      final service = DeepgramSttService(
        microphone: MicrophoneSource(recorder: FakeRecorder()),
        fetchToken: () async => 'temp-jwt',
        connect: (uri, headers) {
          attempts.add(headers);
          uris.add(uri);
          return attempts.length == 1
              ? FakeSocket(
                  handshakeError: WebSocketChannelException.from(
                      const WebSocketException('not upgraded, HTTP status '
                          'code: 401')))
              : FakeSocket();
        },
      );

      await service.start();

      expect(attempts.length, 2);
      expect(attempts.first['authorization'], 'Bearer temp-jwt');
      // Second attempt carries no header and puts the JWT on the URL instead.
      expect(attempts[1], isEmpty);
      expect(uris[1].queryParameters['access_token'], 'temp-jwt');
      expect(uris.first.queryParameters.containsKey('access_token'), isFalse);
      expect(service.isListening, isTrue);

      // And it remembers, so the next session does not pay for the discovery
      // twice.
      expect(DeepgramSttService.preferredAuthMode, DeepgramAuthMode.queryParam);
      expect(sawEvent('DEEPGRAM_AUTH_MODE_SWITCHED'), isTrue);
      await service.dispose();
    });

    test('a socket that closes right after connecting is not ignored',
        () async {
      // The original guard was `if (_listening)`, and _listening is false
      // until the very end of start(). A socket accepted and then dropped
      // during startup therefore produced silence and no error at all.
      final socket = FakeSocket();
      final service = DeepgramSttService(
        microphone: MicrophoneSource(recorder: FakeRecorder()),
        fetchToken: () async => 't',
        connect: (_, __) => socket,
      );
      final failures = <VoiceSessionException>[];
      service.failures.listen(failures.add);

      await service.start();
      socket.closeWith(code: 1011, reason: 'server error');
      await pumpEventQueue();

      expect(failures, hasLength(1));
      expect(failures.single.failure, VoiceFailure.socketClosed);
      final d = diag('DEEPGRAM_SOCKET_CLOSED');
      expect(d, isNotNull);
      expect(d!.closeCode, 1011);
      expect(d.closeReason, 'server error');
      await service.dispose();
    });

    test('a Deepgram Error frame is a provider error, with its own words',
        () async {
      final socket = FakeSocket();
      final service = DeepgramSttService(
        microphone: MicrophoneSource(recorder: FakeRecorder()),
        fetchToken: () async => 't',
        connect: (_, __) => socket,
      );
      final failures = <VoiceSessionException>[];
      service.failures.listen(failures.add);

      await service.start();
      socket.emit({
        'type': 'Error',
        'description': 'invalid sample rate for model',
      });
      await pumpEventQueue();

      expect(failures.single.failure, VoiceFailure.providerError);
      expect(diag('DEEPGRAM_SERVER_ERROR')!.safeError,
          contains('invalid sample rate'));
      await service.dispose();
    });

    test('a recorder that will not start is never blamed on Deepgram',
        () async {
      final service = DeepgramSttService(
        microphone: MicrophoneSource(recorder: FakeRecorder(failToStart: true)),
        fetchToken: () async => 't',
        connect: (_, __) => FakeSocket(),
      );

      await expectLater(
        service.start(),
        throwsA(isA<VoiceSessionException>()
            .having((e) => e.failure, 'failure',
                VoiceFailure.microphoneStartFailed)
            .having((e) => e.isProviderFault, 'isProviderFault', isFalse)),
      );
      expect(sawEvent('MICROPHONE_START_FAILED'), isTrue);
      expect(service.isConnected, isFalse);
      await service.dispose();
    });

    test('what is actually on the wire is recorded, not assumed', () async {
      // Configuration is a request, not a receipt. This is the diagnostic
      // that answers "is 16 kHz PCM16 what the recorder is really producing".
      final socket = FakeSocket();
      final recorder = FakeRecorder();
      final service = DeepgramSttService(
        microphone: MicrophoneSource(recorder: recorder),
        fetchToken: () async => 't',
        connect: (_, __) => socket,
      );
      await service.start();
      recorder.emit(pcmOfMs(64));
      await pumpEventQueue();

      final d = diag('DEEPGRAM_AUDIO_SHAPE');
      expect(d, isNotNull);
      expect(d!.info!['bytes_per_chunk'], 64 * 32);
      expect(d.info!['chunk_ms'], 64);
      expect(d.info!['sample_rate'], 16000);
      expect(d.info!['channels'], 1);
      expect(d.info!['encoding'], 'pcm16le');
      // Raw PCM16, straight onto the socket as a binary frame.
      expect(socket.sentBinary.single.lengthInBytes, 64 * 32);
      await service.dispose();
    });

    test('closing during the handshake never opens the microphone', () async {
      final recorder = FakeRecorder();
      final service = DeepgramSttService(
        microphone: MicrophoneSource(recorder: recorder),
        fetchToken: () async {
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return 't';
        },
        connect: (_, __) => FakeSocket(),
      );

      final starting = service.start();
      await service.cancel();
      await starting;

      expect(recorder.startCount, 0);
      expect(service.isListening, isFalse);
      expect(sawEvent('DEEPGRAM_START_SUPERSEDED'), isTrue);
      await service.dispose();
    });
  });

  // ══ Nothing may wait forever ═══════════════════════════════════════════════

  group('startup timeouts', () {
    // The bug these exist for: the card sat on "Connecting…" permanently. A
    // socket that is refused, reset or closed produces an error the code
    // already handled - but one that is simply swallowed by a proxy or a dead
    // radio produces nothing at all, and every await below `start()` waited
    // on it for as long as the user was willing to look at the screen.
    //
    // Short timeouts here so the branches run in milliseconds; production
    // values live in SttTimeouts.
    const fast = Duration(milliseconds: 40);

    test('a handshake that never answers times out instead of hanging',
        () async {
      final recorder = FakeRecorder();
      final service = DeepgramSttService(
        microphone: MicrophoneSource(recorder: recorder),
        fetchToken: () async => 't',
        connect: (_, __) => FakeSocket(hangs: true),
        handshakeTimeout: fast,
      );

      await expectLater(
        service.start(),
        throwsA(isA<VoiceSessionException>().having(
            (e) => e.failure, 'failure', VoiceFailure.handshakeFailed)),
      );

      expect(sawEvent('DEEPGRAM_HANDSHAKE_START'), isTrue);
      expect(sawEvent('DEEPGRAM_HANDSHAKE_TIMEOUT'), isTrue);
      // And the ordering rule holds even here: no microphone before a
      // provider is actually connected.
      expect(recorder.startCount, 0);
      expect(service.isListening, isFalse);
      expect(service.isConnected, isFalse);
      await service.dispose();
    });

    test('a timed-out handshake does not spend a second timeout on the other '
        'auth transport', () async {
      // A refusal says "this transport was rejected" and is worth retrying
      // the documented alternative. Silence says the path is dead, and the
      // alternative travels the same path - so retrying only doubles the
      // time the user spends watching "Connecting…" before the fallback.
      var connects = 0;
      final service = DeepgramSttService(
        microphone: MicrophoneSource(recorder: FakeRecorder()),
        fetchToken: () async => 't',
        connect: (_, __) {
          connects++;
          return FakeSocket(hangs: true);
        },
        handshakeTimeout: fast,
      );

      await expectLater(service.start(), throwsA(isA<VoiceSessionException>()));
      expect(connects, 1);
      await service.dispose();
    });

    test('a token request that never answers times out', () async {
      final service = DeepgramSttService(
        microphone: MicrophoneSource(recorder: FakeRecorder()),
        fetchToken: () => Completer<String>().future,
        connect: (_, __) => FakeSocket(),
        tokenTimeout: fast,
      );

      await expectLater(
        service.start(),
        throwsA(isA<VoiceSessionException>().having(
            (e) => e.failure, 'failure', VoiceFailure.tokenUnavailable)),
      );
      expect(sawEvent('DEEPGRAM_TOKEN_TIMEOUT'), isTrue);
      await service.dispose();
    });

    test('a microphone that never starts times out', () async {
      final service = DeepgramSttService(
        microphone: MicrophoneSource(recorder: FakeRecorder(hangsOnStart: true)),
        fetchToken: () async => 't',
        connect: (_, __) => FakeSocket(),
        microphoneTimeout: fast,
      );

      await expectLater(
        service.start(),
        throwsA(isA<VoiceSessionException>().having(
            (e) => e.failure, 'failure', VoiceFailure.microphoneStartFailed)),
      );
      expect(sawEvent('MICROPHONE_START_TIMEOUT'), isTrue);
      await service.dispose();
    });

    test('AssemblyAI bounds its handshake too', () async {
      // Otherwise the identical bug simply moves to the fallback, and the
      // card hangs on "Reconnecting voice…" instead of "Connecting…".
      final service = AssemblyAiSttService(
        microphone: MicrophoneSource(recorder: FakeRecorder()),
        fetchToken: () async => 't',
        connect: (_) => FakeSocket(hangs: true),
        handshakeTimeout: fast,
      );

      await expectLater(
        service.start(),
        throwsA(isA<VoiceSessionException>().having(
            (e) => e.failure, 'failure', VoiceFailure.handshakeFailed)),
      );
      expect(sawEvent('ASSEMBLYAI_HANDSHAKE_START'), isTrue);
      expect(sawEvent('ASSEMBLYAI_HANDSHAKE_TIMEOUT'), isTrue);
      await service.dispose();
    });

    test('AssemblyAI bounds its token request too', () async {
      final service = AssemblyAiSttService(
        microphone: MicrophoneSource(recorder: FakeRecorder()),
        fetchToken: () => Completer<String>().future,
        connect: (_) => FakeSocket(),
        tokenTimeout: fast,
      );

      await expectLater(
        service.start(),
        throwsA(isA<VoiceSessionException>().having(
            (e) => e.failure, 'failure', VoiceFailure.tokenUnavailable)),
      );
      expect(sawEvent('ASSEMBLYAI_TOKEN_TIMEOUT'), isTrue);
      await service.dispose();
    });

    test('a hung Deepgram handshake reaches AssemblyAI, which becomes active',
        () async {
      // The whole point. Before the timeout, a swallowed handshake meant
      // RealtimeSttManager never learned Deepgram had failed, so the fallback
      // it was built for could never run.
      final recorder = FakeRecorder();
      final mic = MicrophoneSource(recorder: recorder);
      final manager = RealtimeSttManager(
        microphone: mic,
        providers: [
          DeepgramSttService(
            microphone: mic,
            fetchToken: () async => 'dg-token',
            connect: (_, __) => FakeSocket(hangs: true),
            handshakeTimeout: fast,
          ),
          AssemblyAiSttService(
            microphone: mic,
            fetchToken: () async => 'aai-token',
            connect: (_) => FakeSocket(),
            handshakeTimeout: fast,
          ),
        ],
      );

      await manager.start(brokaLanguage: 'english');

      expect(manager.activeProvider, 'assemblyai');
      expect(manager.isListening, isTrue);
      // One microphone, and it belongs to the provider that actually
      // connected.
      expect(recorder.startCount, 1);
      expect(recorder.running, isTrue);

      expect(sawEvent('DEEPGRAM_HANDSHAKE_TIMEOUT'), isTrue);
      expect(sawEvent('STT_PROVIDER_FAILED_TRYING_NEXT'), isTrue);
      expect(sawEvent('ASSEMBLYAI_STREAMING'), isTrue);
      await manager.dispose();
    });

    test('the card leaves Connecting even when Deepgram never answers',
        () async {
      // The same thing one layer up, in the state the user actually sees.
      final mic = MicrophoneSource(recorder: FakeRecorder());
      final manager = RealtimeSttManager(
        microphone: mic,
        providers: [
          DeepgramSttService(
            microphone: mic,
            fetchToken: () async => 'dg',
            connect: (_, __) => FakeSocket(hangs: true),
            handshakeTimeout: fast,
          ),
          AssemblyAiSttService(
            microphone: mic,
            fetchToken: () async => 'aai',
            connect: (_) => FakeSocket(),
          ),
        ],
      );
      final c = ZenoVoiceController(
        onSubmit: (_) async {},
        languageKey: () => 'english',
        service: manager,
      );

      await c.open();

      expect(c.state, VoiceSessionState.listening);
      expect(c.state, isNot(VoiceSessionState.connecting));
      expect(c.errorMessage, isNull);
      c.dispose();
    });

    test('a provider that never returns at all still hands control back',
        () async {
      // The backstop. Every stage inside a provider is bounded, but the point
      // of a watchdog is the stage somebody forgets to bound.
      final hung = _Scripted('deepgram', hangsForever: true);
      final b = _Scripted('assemblyai');
      final manager = RealtimeSttManager(
        microphone: MicrophoneSource(recorder: FakeRecorder()),
        providers: [hung, b],
        providerStartWatchdog: fast,
      );

      await manager.start();

      expect(manager.activeProvider, 'assemblyai');
      expect(sawEvent('STT_PROVIDER_START_WATCHDOG_TIMEOUT'), isTrue);
      // The abandoned start is cancelled, not left running.
      expect(hung.cancelCount, greaterThanOrEqualTo(1));
      await manager.dispose();
    });
  });

  // ══ Diagnostics must never carry a credential ══════════════════════════════

  group('diagnostic redaction', () {
    test('tokens are stripped however they appear', () {
      const jwt = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.abcdefghijklmnop.sig';
      final d = SttDiagnostic(
        provider: 'deepgram',
        stage: SttStage.handshake,
        event: 'DEEPGRAM_HANDSHAKE_FAILED',
        safeError: "Connection to 'wss://api.deepgram.com/v1/listen"
            "?access_token=$jwt' was not upgraded, Authorization: Bearer $jwt",
      );
      expect(d.safeError, isNot(contains(jwt)));
      expect(d.safeError, isNot(contains('eyJ')));
      expect(d.safeError, contains('api.deepgram.com'));
      expect(d.toLogLine(), isNot(contains(jwt)));
    });

    test('a close reason from a provider is redacted too', () {
      final d = SttDiagnostic(
        provider: 'assemblyai',
        stage: SttStage.streaming,
        event: 'ASSEMBLYAI_SOCKET_CLOSED',
        closeReason: 'token=abc123def456 rejected',
      );
      expect(d.closeReason, isNot(contains('abc123def456')));
    });
  });

  // ══ AssemblyAI ═════════════════════════════════════════════════════════════

  group('AssemblyAiSttService', () {
    test('connects to v3 with the documented parameters', () async {
      Uri? connected;
      final service = AssemblyAiSttService(
        microphone: MicrophoneSource(recorder: FakeRecorder()),
        fetchToken: () async => 'temp-token',
        connect: (uri) {
          connected = uri;
          return FakeSocket();
        },
      );
      await service.start(brokaLanguage: 'english');

      expect(connected!.scheme, 'wss');
      expect(connected!.host, 'streaming.assemblyai.com');
      expect(connected!.path, '/v3/ws');
      final q = connected!.queryParameters;
      expect(q['sample_rate'], '16000');
      expect(q['encoding'], 'pcm_s16le');
      expect(q['format_turns'], 'true');
      // A temporary token goes in the query string - that is the documented
      // transport for it, and the permanent key is never in the app at all.
      expect(q['token'], 'temp-token');
      await service.dispose();
    });

    test('a partial turn is interim text; a formatted turn is final once',
        () async {
      final socket = FakeSocket();
      final service = AssemblyAiSttService(
        microphone: MicrophoneSource(recorder: FakeRecorder()),
        fetchToken: () async => 't',
        connect: (_) => socket,
      );
      final interim = <String>[];
      final finals = <String>[];
      final turnEnds = <bool>[];
      service.interimTranscript.listen(interim.add);
      service.finalTranscript.listen(finals.add);
      service.speechFinal.listen(turnEnds.add);

      await service.start();
      socket.emit({'type': 'Begin', 'id': 's1', 'expires_at': 1790000000});
      socket.emit(assemblyTurn('how much', order: 0));
      socket.emit(assemblyTurn('how much for the', order: 0));
      await pumpEventQueue();
      expect(interim, ['how much', 'how much for the']);
      expect(finals, isEmpty);

      // The unformatted end-of-turn, then the formatted one AssemblyAI sends
      // straight after with the same turn_order. Emitting both would send
      // Zeno the same sentence twice.
      socket.emit(assemblyTurn('how much for the router', order: 0,
          endOfTurn: true));
      socket.emit(assemblyTurn('How much for the router?', order: 0,
          endOfTurn: true, formatted: true));
      await pumpEventQueue();

      expect(finals, ['How much for the router?']);
      expect(turnEnds, hasLength(1));
      await service.dispose();
    });

    test('an unformatted turn still lands if no formatted version follows',
        () async {
      // The formatted repeat is not guaranteed. Waiting forever for it would
      // silently drop the user's sentence.
      final socket = FakeSocket();
      final service = AssemblyAiSttService(
        microphone: MicrophoneSource(recorder: FakeRecorder()),
        fetchToken: () async => 't',
        connect: (_) => socket,
      );
      final finals = <String>[];
      service.finalTranscript.listen(finals.add);

      await service.start();
      socket.emit(assemblyTurn('is it still available', order: 3,
          endOfTurn: true));
      await pumpEventQueue();
      expect(finals, isEmpty, reason: 'still waiting for the formatted turn');

      await Future<void>.delayed(const Duration(milliseconds: 1100));
      expect(finals, ['is it still available']);
      await service.dispose();
    });

    test('short recorder chunks are re-cut to the documented frame size',
        () async {
      // AssemblyAI documents a 50 ms floor per binary frame. `record` makes no
      // promise about chunk size, so shipping its chunks straight through is a
      // bug waiting for a device that buffers small.
      final socket = FakeSocket();
      final recorder = FakeRecorder();
      final service = AssemblyAiSttService(
        microphone: MicrophoneSource(recorder: recorder),
        fetchToken: () async => 't',
        connect: (_) => socket,
      );
      await service.start();

      // Four 32 ms chunks: a real Android buffer size, and under the floor.
      for (var i = 0; i < 4; i++) {
        recorder.emit(pcmOfMs(32));
      }
      await pumpEventQueue();

      expect(socket.sentBinary, isNotEmpty);
      for (final frame in socket.sentBinary) {
        final ms = frame.lengthInBytes / 32;
        expect(ms, greaterThanOrEqualTo(50));
        expect(ms, lessThanOrEqualTo(1000));
      }
      await service.dispose();
    });

    test('a graceful stop terminates the session rather than dropping it',
        () async {
      final socket = FakeSocket();
      final service = AssemblyAiSttService(
        microphone: MicrophoneSource(recorder: FakeRecorder()),
        fetchToken: () async => 't',
        connect: (_) => socket,
      );
      await service.start();

      final stopping = service.stop();
      await pumpEventQueue();
      expect(socket.sentJson.map((m) => m['type']), contains('Terminate'));

      // The server flushes and answers; only then does the socket go.
      socket.emit({
        'type': 'Termination',
        'audio_duration_seconds': 4.2,
        'session_duration_seconds': 5.0,
      });
      await stopping;

      expect(socket.closed, isTrue);
      expect(sawEvent('ASSEMBLYAI_SESSION_TERMINATED'), isTrue);
      await service.dispose();
    });

    test('a token failure never reaches the socket', () async {
      var connects = 0;
      final service = AssemblyAiSttService(
        microphone: MicrophoneSource(recorder: FakeRecorder()),
        fetchToken: () async =>
            throw VoiceSessionException(VoiceFailure.notConfigured),
        connect: (_) {
          connects++;
          return FakeSocket();
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

    test('a refused handshake is reported as one', () async {
      final service = AssemblyAiSttService(
        microphone: MicrophoneSource(recorder: FakeRecorder()),
        fetchToken: () async => 't',
        connect: (_) => FakeSocket(
          handshakeError: WebSocketChannelException.from(
              const WebSocketException('not upgraded, HTTP status code: 401')),
        ),
      );
      await expectLater(
        service.start(),
        throwsA(isA<VoiceSessionException>().having(
            (e) => e.failure, 'failure', VoiceFailure.handshakeFailed)),
      );
      expect(sawEvent('ASSEMBLYAI_HANDSHAKE_FAILED'), isTrue);
      await service.dispose();
    });
  });

  // ══ Failover ═══════════════════════════════════════════════════════════════

  group('RealtimeSttManager', () {
    /// A provider that fails on demand, so the manager's policy can be tested
    /// without either vendor's wire format getting in the way.
    _Scripted primary({VoiceSessionException? failsOnStart}) =>
        _Scripted('deepgram', failsOnStart: failsOnStart);

    test('Deepgram first, AssemblyAI only if Deepgram cannot start', () async {
      final a = primary(
          failsOnStart: VoiceSessionException(VoiceFailure.handshakeFailed));
      final b = _Scripted('assemblyai');
      final manager = RealtimeSttManager(
          microphone: MicrophoneSource(recorder: FakeRecorder()),
          providers: [a, b]);

      await manager.start(brokaLanguage: 'english');

      expect(a.startCount, 1);
      expect(b.startCount, 1);
      expect(manager.activeProvider, 'assemblyai');
      // Never both: the failed one is fully cancelled before the next starts.
      expect(a.isListening, isFalse);
      expect(a.cancelCount, greaterThanOrEqualTo(1));
      expect(sawEvent('STT_PROVIDER_FAILED_TRYING_NEXT'), isTrue);
      await manager.dispose();
    });

    test('a token failure fails over just as a handshake failure does',
        () async {
      final a = primary(
          failsOnStart: VoiceSessionException(VoiceFailure.tokenUnavailable));
      final b = _Scripted('assemblyai');
      final manager = RealtimeSttManager(
          microphone: MicrophoneSource(recorder: FakeRecorder()),
          providers: [a, b]);
      await manager.start();
      expect(manager.activeProvider, 'assemblyai');
      await manager.dispose();
    });

    test('a denied microphone does not try a second vendor', () async {
      // A second provider would ask for permission again and listen to the
      // same silence.
      final a = primary(
          failsOnStart: VoiceSessionException(VoiceFailure.microphoneDenied));
      final b = _Scripted('assemblyai');
      final manager = RealtimeSttManager(
          microphone: MicrophoneSource(recorder: FakeRecorder()),
          providers: [a, b]);

      await expectLater(
        manager.start(),
        throwsA(isA<VoiceSessionException>().having(
            (e) => e.failure, 'failure', VoiceFailure.microphoneDenied)),
      );
      expect(b.startCount, 0);
      expect(manager.activeProvider, isNull);
      expect(sawEvent('STT_NO_FAILOVER_DEVICE_FAULT'), isTrue);
      await manager.dispose();
    });

    test('a mid-session death swaps providers and says it is reconnecting',
        () async {
      final a = _Scripted('deepgram');
      final b = _Scripted('assemblyai');
      final manager = RealtimeSttManager(
          microphone: MicrophoneSource(recorder: FakeRecorder()),
          providers: [a, b]);
      final reconnects = <bool>[];
      final finals = <String>[];
      manager.reconnecting.listen(reconnects.add);
      manager.finalTranscript.listen(finals.add);

      await manager.start();
      a.emitFinal('how much for the router');
      await pumpEventQueue();

      a.die(VoiceSessionException(VoiceFailure.socketClosed));
      await pumpEventQueue();

      expect(reconnects, [true, false]);
      expect(manager.activeProvider, 'assemblyai');
      expect(a.isListening, isFalse);
      expect(sawEvent('STT_FAILING_OVER_MID_SESSION'), isTrue);

      // The sentence already transcribed is not re-emitted, and the new
      // provider's output flows through the same stream.
      b.emitFinal('is it still available');
      await pumpEventQueue();
      expect(finals, ['how much for the router', 'is it still available']);
      await manager.dispose();
    });

    test('the transcript survives a failover', () async {
      final a = _Scripted('deepgram');
      final b = _Scripted('assemblyai');
      final manager = RealtimeSttManager(
          microphone: MicrophoneSource(recorder: FakeRecorder()),
          providers: [a, b]);
      final sent = <String>[];
      final c = ZenoVoiceController(
        onSubmit: (t) async => sent.add(t),
        languageKey: () => 'english',
        autoSend: false,
        service: manager,
      );

      await c.open();
      a.emitFinal('how much for the router');
      await pumpEventQueue();
      expect(c.transcript.text, 'how much for the router');

      a.die(VoiceSessionException(VoiceFailure.socketClosed));
      await pumpEventQueue();

      // Reconnecting, not an error - and the user's words are still in the
      // box, because the text lives in the controller and not in a vendor.
      expect(c.transcript.text, 'how much for the router');
      expect(c.errorMessage, isNull);

      b.emitFinal('is it still available');
      await pumpEventQueue();
      expect(c.transcript.text, 'how much for the router is it still available');
      expect(sent, isEmpty);
      c.dispose();
    });

    test('when every provider is exhausted the last failure is reported',
        () async {
      final a = primary(
          failsOnStart: VoiceSessionException(VoiceFailure.handshakeFailed));
      final b = _Scripted('assemblyai',
          failsOnStart: VoiceSessionException(VoiceFailure.notConfigured));
      final manager = RealtimeSttManager(
          microphone: MicrophoneSource(recorder: FakeRecorder()),
          providers: [a, b]);

      await expectLater(
        manager.start(),
        throwsA(isA<VoiceSessionException>().having(
            (e) => e.failure, 'failure', VoiceFailure.notConfigured)),
      );
      expect(manager.activeProvider, isNull);
      await manager.dispose();
    });

    test('one provider at a time, one microphone, always', () async {
      final a = _Scripted('deepgram');
      final b = _Scripted('assemblyai');
      final manager = RealtimeSttManager(
          microphone: MicrophoneSource(recorder: FakeRecorder()),
          providers: [a, b]);

      await manager.start();
      expect([a.isListening, b.isListening], [true, false]);

      a.die(VoiceSessionException(VoiceFailure.providerError));
      await pumpEventQueue();
      expect([a.isListening, b.isListening], [false, true]);

      await manager.cancel();
      expect([a.isListening, b.isListening], [false, false]);
      await manager.dispose();
    });

    test('opening twice does not start a second session', () async {
      final a = _Scripted('deepgram');
      final manager = RealtimeSttManager(
          microphone: MicrophoneSource(recorder: FakeRecorder()),
          providers: [a]);
      await manager.start();
      await manager.start();
      await manager.start();
      expect(a.startCount, 1);
      await manager.dispose();
    });

    test('closing twice is not an error and leaves nothing running', () async {
      final a = _Scripted('deepgram');
      final manager = RealtimeSttManager(
          microphone: MicrophoneSource(recorder: FakeRecorder()),
          providers: [a]);
      await manager.start();
      await manager.cancel();
      await manager.cancel();
      expect(a.isListening, isFalse);
      expect(manager.isListening, isFalse);
      expect(manager.activeProvider, isNull);
      await manager.dispose();
    });

    test('teardown leaves no recorder, socket or timer behind', () async {
      // The real providers, so the real teardown paths run.
      final recorder = FakeRecorder();
      final mic = MicrophoneSource(recorder: recorder);
      final dgSocket = FakeSocket();
      final manager = RealtimeSttManager(
          microphone: MicrophoneSource(recorder: FakeRecorder()),
          providers: [
        DeepgramSttService(
          microphone: mic,
          fetchToken: () async => 't',
          connect: (_, __) => dgSocket,
        ),
        AssemblyAiSttService(
          microphone: mic,
          fetchToken: () async => 't',
          connect: (_) => FakeSocket(),
        ),
      ]);

      await manager.start();
      expect(recorder.running, isTrue);

      await manager.cancel();
      expect(recorder.running, isFalse);
      expect(recorder.cancelled, isTrue);
      expect(dgSocket.closed, isTrue);
      await manager.dispose();
    });

    test('the language answer comes from whichever provider is running',
        () async {
      final manager = RealtimeSttManager(
          microphone: MicrophoneSource(recorder: FakeRecorder()),
          providers: [
        DeepgramSttService(
          microphone: MicrophoneSource(recorder: FakeRecorder()),
          fetchToken: () async => 't',
          connect: (_, __) => FakeSocket(),
        ),
      ]);
      // Answers before a session exists, because the card asks before opening.
      expect(manager.languageFor('english').supported, isTrue);
      expect(manager.languageFor('swahili').supported, isFalse);
      expect(manager.languageFor('swahili').language, 'en');
      await manager.dispose();
    });
  });
}

/// A provider with no wire format, for testing the manager's policy.
///
/// The real services are used where the wire format IS the subject; here the
/// question is only which provider runs and when, and a scripted one keeps
/// those tests about failover rather than about JSON.
class _Scripted implements RealtimeSttProvider {
  _Scripted(this.name, {this.failsOnStart, this.hangsForever = false});

  @override
  final String name;

  final VoiceSessionException? failsOnStart;

  /// start() never completes - the failure mode the manager's watchdog is
  /// the last line of defence against.
  final bool hangsForever;

  int startCount = 0;
  int cancelCount = 0;
  int stopCount = 0;
  bool _listening = false;

  final _interim = StreamController<String>.broadcast();
  final _finals = StreamController<String>.broadcast();
  final _speechStarted = StreamController<bool>.broadcast();
  final _speechFinal = StreamController<bool>.broadcast();
  final _level = StreamController<double>.broadcast();
  final _failures = StreamController<VoiceSessionException>.broadcast();

  void emitFinal(String text) {
    if (!_finals.isClosed) _finals.add(text);
    if (!_speechFinal.isClosed) _speechFinal.add(true);
  }

  void die(VoiceSessionException e) {
    _listening = false;
    if (!_failures.isClosed) _failures.add(e);
  }

  @override
  Future<void> start({String? brokaLanguage}) async {
    startCount++;
    final failure = failsOnStart;
    if (failure != null) throw failure;
    if (hangsForever) await Completer<void>().future;
    _listening = true;
  }

  @override
  Future<void> stop() async {
    stopCount++;
    _listening = false;
  }

  @override
  Future<void> cancel() async {
    cancelCount++;
    _listening = false;
  }

  @override
  Future<void> dispose() async {
    _listening = false;
    await _interim.close();
    await _finals.close();
    await _speechStarted.close();
    await _speechFinal.close();
    await _level.close();
    await _failures.close();
  }

  @override
  Stream<String> get interimTranscript => _interim.stream;
  @override
  Stream<String> get finalTranscript => _finals.stream;
  @override
  Stream<bool> get speechStarted => _speechStarted.stream;
  @override
  Stream<bool> get speechFinal => _speechFinal.stream;
  @override
  Stream<double> get audioLevel => _level.stream;
  @override
  Stream<VoiceSessionException> get failures => _failures.stream;
  @override
  Stream<bool> get reconnecting => const Stream<bool>.empty();

  @override
  bool get isConnected => _listening;
  @override
  bool get isListening => _listening;

  @override
  ProviderLanguageConfig languageFor(String? brokaLanguage) =>
      const ProviderLanguageConfig(
          model: 'scripted', language: 'en', supported: true);
}
