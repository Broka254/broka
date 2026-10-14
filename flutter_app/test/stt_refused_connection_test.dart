// Voice input that said "Connecting…" and never anything else (2026-09-26).
//
// When the speech provider refused the WebSocket upgrade (a rejected token
// comes back as HTTP 401) or couldn't be reached, each service closed the
// failed socket and awaited that close. web_socket_channel never completes
// the close of a channel whose handshake failed, so start() stopped there:
// the card stayed on "Connecting…" until RealtimeSttManager's 45-second
// watchdog gave up, and then the same again for the second provider.
//
// stt_fallback_test.dart could not see it - its FakeSocket closes instantly.
// These tests use the real IOWebSocketChannel against a real local server
// that refuses the upgrade, which is what a phone gets.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/io.dart';

import 'package:broka/services/assemblyai_stt_service.dart';
import 'package:broka/services/deepgram_stt_service.dart';
import 'package:broka/services/realtime_stt.dart';
import 'package:broka/services/realtime_stt_manager.dart';
import 'package:broka/services/zeno_voice_controller.dart';

import 'support/fake_voice.dart';

/// Far less than the 45-second watchdog, far more than a refused upgrade on
/// localhost needs.
const _bound = Duration(seconds: 5);

void main() {
  late HttpServer server;
  var upgrades = 0;

  setUp(() async {
    SttDiagnostics.clear();
    DeepgramSttService.preferredAuthMode = DeepgramAuthMode.header;
    upgrades = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) {
      upgrades++;
      request.response.statusCode = HttpStatus.unauthorized;
      request.response.close();
    });
  });

  tearDown(() => server.close(force: true));

  IOWebSocketChannel refused() =>
      IOWebSocketChannel.connect(Uri.parse('ws://127.0.0.1:${server.port}/'),
          connectTimeout: const Duration(seconds: 2));

  DeepgramSttService deepgram(MicrophoneSource mic) => DeepgramSttService(
        microphone: mic,
        fetchToken: () async => 'dg-token',
        connect: (_, __) => refused(),
      );

  AssemblyAiSttService assemblyAi(MicrophoneSource mic) => AssemblyAiSttService(
        microphone: mic,
        fetchToken: () async => 'aai-token',
        connect: (_) => refused(),
      );

  test('Deepgram reports a refused connection instead of hanging', () async {
    final recorder = FakeRecorder();
    final service = deepgram(MicrophoneSource(recorder: recorder));

    await expectLater(
      service.start().timeout(_bound),
      throwsA(isA<VoiceSessionException>()
          .having((e) => e.failure, 'failure', VoiceFailure.handshakeFailed)),
    );
    // Both auth transports were tried - the retry after the first refusal is
    // where it used to stop.
    expect(upgrades, 2);
    expect(recorder.startCount, 0);
    await service.dispose();
  });

  test('AssemblyAI reports a refused connection instead of hanging', () async {
    final recorder = FakeRecorder();
    final service = assemblyAi(MicrophoneSource(recorder: recorder));

    await expectLater(
      service.start().timeout(_bound),
      throwsA(isA<VoiceSessionException>()
          .having((e) => e.failure, 'failure', VoiceFailure.handshakeFailed)),
    );
    expect(recorder.startCount, 0);
    await service.dispose();
  });

  test('the card leaves Connecting within seconds and says what failed',
      () async {
    final mic = MicrophoneSource(recorder: FakeRecorder());
    final controller = ZenoVoiceController(
      onSubmit: (_) async {},
      languageKey: () => 'english',
      service: RealtimeSttManager(
        microphone: mic,
        providers: [deepgram(mic), assemblyAi(mic)],
      ),
    );

    await controller.open().timeout(_bound);

    expect(controller.state, VoiceSessionState.error);
    expect(controller.errorMessage, contains("Voice couldn't connect"));
    // The last provider tried is the one reported: it answered and refused,
    // rather than never being reached - on a phone, the only trace of why.
    expect(controller.errorReference, 'ASSEMBLYAI_HANDSHAKE_FAILED');
    controller.dispose();
  });
}
