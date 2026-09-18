// lib/services/deepgram_stt_service.dart
//
// Streaming speech-to-text for the Zeno voice card: microphone -> Deepgram
// WebSocket -> interim and final transcripts.
//
// Credentials. The permanent Deepgram key is never in this binary. Every
// session asks BROKA's own /stt/deepgram-token endpoint for a short-lived JWT
// and spends it on the WebSocket handshake. The JWT goes in an Authorization
// header under the Bearer scheme, not Token (which is what the PERMANENT key
// uses on the server side) and not the Sec-WebSocket-Protocol subprotocol,
// which is documented but unreliable for a credential as long as a JWT. That
// is why this uses IOWebSocketChannel rather than the platform-agnostic
// WebSocketChannel.connect used elsewhere in the app: only the dart:io channel
// accepts custom handshake headers. BROKA ships to Android and iOS, so that
// costs nothing here.
//
// Audio. `record` 6.2.1's startStream gives a Stream<Uint8List> of raw PCM
// when configured with AudioEncoder.pcm16bits, which is exactly what
// Deepgram's encoding=linear16 wants - so the bytes go onto the socket as
// binary frames with no re-encoding and no base64.
//
// This service knows nothing about Zeno, negotiation, or any screen. It turns
// a microphone into transcripts; ZenoVoiceController decides what a transcript
// means.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:record/record.dart';
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/network/api_client.dart';

/// Why a voice session could not run. The card turns these into one honest
/// sentence each; the text composer stays usable in every case.
enum VoiceFailure {
  /// The server has no DEEPGRAM_API_KEY. Voice is off for everyone, and no
  /// amount of retrying by this user changes that.
  notConfigured,

  /// Microphone permission denied.
  microphoneDenied,

  /// Could not reach BROKA's own backend for a token.
  tokenUnavailable,

  /// Token was fine, Deepgram's socket was not.
  connectionFailed,

  /// Anything else, including a mid-session drop.
  unknown,
}

class VoiceSessionException implements Exception {
  VoiceSessionException(this.failure, [this.detail]);
  final VoiceFailure failure;
  final String? detail;

  @override
  String toString() => 'VoiceSessionException($failure, $detail)';
}

/// How one BROKA language maps onto Deepgram's model/language pair.
///
/// [supported] records whether Deepgram's streaming API can actually
/// transcribe that language, and it matters: BROKA's language picker offers
/// English, Kiswahili, Dholuo, Kikuyu, Luganda and Sheng, and a UI listing a
/// language is not evidence that a transcription vendor supports it.
///
/// Checked against Deepgram's own statements (Sept 2026): Nova-3's
/// `language=multi` is a code-switching mode over a fixed European/Asian set -
/// Deepgram staff listed it as English, Spanish, French, German, Hindi,
/// Russian, Portuguese, Japanese, Italian and Dutch, and the 2026 expansions
/// that took Nova-3 past 36 languages were Europe, South Asia, East Asia,
/// South-East Asia and Arabic. No Bantu or Nilotic language appears in any of
/// them. Deepgram transcribes Kiswahili only through Whisper Cloud, which is
/// pre-recorded audio only and cannot stream.
///
/// So the five non-English BROKA languages run on `en`, not `multi`. That is
/// not a claim they are supported - it is the least-wrong option of three:
///   * `multi` would hand Kiswahili to a model that must answer in Spanish,
///     Italian or Dutch, producing confident text in a language the user
///     does not read;
///   * refusing the session would remove voice from five of six BROKA
///     languages outright;
///   * `en` catches the English half of the code-switched sentences Kenyan
///     conversation is actually made of, which is the part Zeno can act on,
///     and leaves the rest for the user to correct in an editable box.
/// The card says as much on screen rather than letting anyone conclude
/// BROKA's Dholuo is broken.
///
/// Do NOT flip a `supported` flag without re-checking Deepgram's current
/// language documentation.
class DeepgramLanguage {
  const DeepgramLanguage({
    required this.model,
    required this.language,
    required this.supported,
  });

  final String model;
  final String language;

  /// True only where Deepgram is documented to transcribe this language.
  final bool supported;

  /// BROKA language key (ApiService.currentUserLanguage) -> Deepgram config.
  static const Map<String, DeepgramLanguage> _byBrokaKey = {
    'english': DeepgramLanguage(
        model: 'nova-3', language: 'en', supported: true),
    // See the class doc: Deepgram has no streaming model for any of these, so
    // they run on English and are flagged so the card can say so.
    'swahili': DeepgramLanguage(
        model: 'nova-3', language: 'en', supported: false),
    'sheng': DeepgramLanguage(
        model: 'nova-3', language: 'en', supported: false),
    'luo': DeepgramLanguage(
        model: 'nova-3', language: 'en', supported: false),
    'kikuyu': DeepgramLanguage(
        model: 'nova-3', language: 'en', supported: false),
    'luganda': DeepgramLanguage(
        model: 'nova-3', language: 'en', supported: false),
  };

  static DeepgramLanguage forBrokaLanguage(String? key) =>
      _byBrokaKey[(key ?? 'english').toLowerCase().trim()] ??
      _byBrokaKey['english']!;
}

/// Transcript update from Deepgram.
class TranscriptEvent {
  const TranscriptEvent({required this.text, required this.isFinal});

  final String text;

  /// True once Deepgram has stopped revising this span.
  final bool isFinal;
}

class DeepgramSttService {
  DeepgramSttService({
    AudioRecorder? recorder,
    Future<String> Function()? fetchToken,
    WebSocketChannel Function(Uri uri, String token)? connect,
  })  : _recorder = recorder ?? AudioRecorder(),
        _fetchToken = fetchToken ?? _defaultFetchToken,
        _connect = connect ?? _defaultConnect;

  // Injected so tests can drive the whole service without a microphone, a
  // backend or a network - all three seams are the ones that cannot exist in
  // a widget test.
  final AudioRecorder _recorder;
  final Future<String> Function() _fetchToken;
  final WebSocketChannel Function(Uri uri, String token) _connect;

  static const _host = 'api.deepgram.com';
  static const _path = '/v1/listen';

  /// Deepgram's linear16 input. 16 kHz mono is what the model expects and is
  /// a quarter of the bytes of 44.1 kHz stereo on a Kenyan mobile connection.
  static const int sampleRate = 16000;
  static const int channels = 1;

  final _interim = StreamController<String>.broadcast();
  final _finals = StreamController<String>.broadcast();
  final _speechStarted = StreamController<bool>.broadcast();
  final _speechFinal = StreamController<bool>.broadcast();
  final _level = StreamController<double>.broadcast();
  final _failures = StreamController<VoiceSessionException>.broadcast();

  WebSocketChannel? _channel;
  StreamSubscription<Uint8List>? _audioSub;
  StreamSubscription? _socketSub;
  Timer? _keepAlive;
  bool _starting = false;
  bool _listening = false;
  bool _disposed = false;

  Stream<String> get interimTranscript => _interim.stream;
  Stream<String> get finalTranscript => _finals.stream;
  Stream<bool> get speechStarted => _speechStarted.stream;
  Stream<bool> get speechFinal => _speechFinal.stream;

  /// Rough 0..1 loudness, for the waveform. Derived from the PCM frames that
  /// are already flowing, so it costs one pass over a buffer we hold anyway
  /// and needs no second microphone stream.
  Stream<double> get audioLevel => _level.stream;

  Stream<VoiceSessionException> get failures => _failures.stream;

  bool get isConnected => _channel != null;
  bool get isListening => _listening;

  /// Opens one session: token, socket, microphone, in that order.
  ///
  /// Throws [VoiceSessionException]. Calling this while a session is already
  /// starting or running is a no-op rather than an error - the card's
  /// microphone button is tappable during the ~300ms handshake, and two
  /// sockets sharing one microphone is the kind of bug that only shows up as
  /// a billing line.
  Future<void> start({String? brokaLanguage}) async {
    if (_disposed || _starting || _listening) return;
    _starting = true;
    try {
      if (!await _recorder.hasPermission()) {
        throw VoiceSessionException(VoiceFailure.microphoneDenied);
      }

      final token = await _fetchToken();
      final config = DeepgramLanguage.forBrokaLanguage(brokaLanguage);

      final uri = Uri(
        scheme: 'wss',
        host: _host,
        path: _path,
        queryParameters: {
          'model': config.model,
          'language': config.language,
          'encoding': 'linear16',
          'sample_rate': '$sampleRate',
          'channels': '$channels',
          // Drives the live text in the card.
          'interim_results': 'true',
          // "twenty thousand shillings" -> "20,000" and similar. BROKA users
          // dictate prices, phone numbers and model numbers constantly.
          'smart_format': 'true',
          // SpeechStarted events, so the card can say "I'm listening" only
          // once it actually hears something.
          'vad_events': 'true',
          // 300ms of silence closes an utterance. Short enough that a normal
          // pause ends a turn, long enough to survive someone thinking
          // mid-sentence.
          'endpointing': '300',
        },
      );

      try {
        _channel = _connect(uri, token);
      } catch (e) {
        throw VoiceSessionException(VoiceFailure.connectionFailed, '$e');
      }

      _socketSub = _channel!.stream.listen(
        _onSocketMessage,
        onError: (e) => _fail(VoiceSessionException(VoiceFailure.unknown, '$e')),
        onDone: () {
          // Deepgram closed on us mid-session. Tear down rather than leave a
          // microphone streaming into a dead socket.
          if (_listening) {
            _fail(VoiceSessionException(VoiceFailure.connectionFailed,
                'socket closed'));
          }
        },
        cancelOnError: false,
      );

      final stream = await _recorder.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: channels,
        // Voice, in a room, on a phone. All three help the model more than
        // they cost in gain.
        echoCancel: true,
        noiseSuppress: true,
        autoGain: true,
      ));

      _audioSub = stream.listen(
        _onAudio,
        onError: (e) => _fail(VoiceSessionException(VoiceFailure.unknown, '$e')),
        cancelOnError: false,
      );

      // Deepgram drops a connection with ~10s of no audio. A user thinking
      // about what to ask is not a disconnect.
      _keepAlive = Timer.periodic(const Duration(seconds: 5), (_) {
        if (_channel != null) {
          _send(jsonEncode({'type': 'KeepAlive'}));
        }
      });

      _listening = true;
    } finally {
      _starting = false;
    }
  }

  /// Graceful stop: ask Deepgram to flush what it is holding, then close.
  ///
  /// The last words someone says are the ones most likely to still be sitting
  /// in Deepgram's buffer as an interim result, so a hard close here would
  /// routinely lose the end of an utterance.
  Future<void> stop() async {
    if (!_listening && _channel == null) return;
    _listening = false;
    // Timers first, and synchronously: everything below this line awaits, and
    // a keep-alive firing into a half-closed socket during that window is
    // both a crash risk and - in a widget test - a timer outliving the tree.
    _keepAlive?.cancel();
    _keepAlive = null;
    await _audioSub?.cancel();
    _audioSub = null;
    try {
      await _recorder.stop();
    } catch (_) {}

    _send(jsonEncode({'type': 'Finalize'}));
    // A brief window for the flushed final to arrive before the socket goes.
    await Future<void>.delayed(const Duration(milliseconds: 350));
    _send(jsonEncode({'type': 'CloseStream'}));
    await _closeSocket();
  }

  /// Immediate teardown, no flush. For the X button and for leaving the
  /// screen, where a late transcript has nowhere to go anyway.
  Future<void> cancel() async {
    _listening = false;
    _keepAlive?.cancel();
    _keepAlive = null;
    await _audioSub?.cancel();
    _audioSub = null;
    try {
      await _recorder.cancel();
    } catch (_) {
      try {
        await _recorder.stop();
      } catch (_) {}
    }
    await _closeSocket();
  }

  Future<void> dispose() async {
    _disposed = true;
    await cancel();
    try {
      await _recorder.dispose();
    } catch (_) {}
    await _interim.close();
    await _finals.close();
    await _speechStarted.close();
    await _speechFinal.close();
    await _level.close();
    await _failures.close();
  }

  // ── Internals ──────────────────────────────────────────────────────────────

  void _onAudio(Uint8List chunk) {
    if (chunk.isEmpty) return;
    _emitLevel(chunk);
    final channel = _channel;
    if (channel == null) return;
    try {
      channel.sink.add(chunk);
    } catch (_) {
      // A send on a closing socket is not worth tearing the session down for;
      // the onDone/onError handlers above own that decision.
    }
  }

  /// Mean absolute amplitude of a 16-bit little-endian frame, normalised.
  void _emitLevel(Uint8List chunk) {
    if (_level.isClosed) return;
    final samples = chunk.lengthInBytes ~/ 2;
    if (samples == 0) return;
    final view = ByteData.sublistView(chunk);
    var sum = 0;
    // Every 8th sample: the waveform needs a loudness, not a measurement, and
    // this runs on every audio chunk.
    var counted = 0;
    for (var i = 0; i < samples; i += 8) {
      sum += view.getInt16(i * 2, Endian.little).abs();
      counted++;
    }
    if (counted == 0) return;
    final mean = sum / counted;
    // 32768 is full scale; speech sits far below it, so the divisor is tuned
    // to put normal speech in the upper half of the bar rather than a flicker
    // at the bottom.
    _level.add((mean / 6000).clamp(0.0, 1.0));
  }

  void _onSocketMessage(dynamic raw) {
    if (raw is! String) return;
    Map<String, dynamic> event;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return;
      event = decoded;
    } catch (_) {
      // Malformed frame. Deepgram is not supposed to send one, but a partial
      // frame on a flaky connection must not take the app down.
      return;
    }

    switch (event['type']) {
      case 'SpeechStarted':
        if (!_speechStarted.isClosed) _speechStarted.add(true);
        return;
      case 'UtteranceEnd':
        if (!_speechFinal.isClosed) _speechFinal.add(true);
        return;
      case 'Results':
        _onResults(event);
        return;
      case 'Error':
        _fail(VoiceSessionException(
            VoiceFailure.unknown, '${event['description'] ?? 'deepgram error'}'));
        return;
      default:
        // Metadata and anything Deepgram adds later.
        return;
    }
  }

  void _onResults(Map<String, dynamic> event) {
    // Defensive at every level: this is parsing a third party's JSON on a
    // live connection, and one unexpected null should cost a transcript
    // fragment, not the session.
    final channel = event['channel'];
    if (channel is! Map) return;
    final alternatives = channel['alternatives'];
    if (alternatives is! List || alternatives.isEmpty) return;
    final first = alternatives.first;
    if (first is! Map) return;
    final text = (first['transcript'] as String?)?.trim() ?? '';

    final isFinal = event['is_final'] == true;
    final speechFinal = event['speech_final'] == true;

    if (text.isEmpty) {
      // Deepgram emits empty finals at the end of silence. They carry the
      // speech_final flag that closes a turn, so the flag still matters even
      // though the text does not.
      if (speechFinal && !_speechFinal.isClosed) _speechFinal.add(true);
      return;
    }

    if (isFinal) {
      if (!_finals.isClosed) _finals.add(text);
      if (speechFinal && !_speechFinal.isClosed) _speechFinal.add(true);
    } else {
      if (!_interim.isClosed) _interim.add(text);
    }
  }

  void _send(String message) {
    try {
      _channel?.sink.add(message);
    } catch (_) {}
  }

  Future<void> _closeSocket() async {
    final sub = _socketSub;
    final channel = _channel;
    _socketSub = null;
    _channel = null;
    await sub?.cancel();
    try {
      await channel?.sink.close();
    } catch (_) {}
  }

  void _fail(VoiceSessionException e) {
    if (!_failures.isClosed) _failures.add(e);
    // Fire and forget: the caller learns about this through the stream, and
    // awaiting teardown inside an error handler risks deadlocking on the very
    // socket that failed.
    unawaited(cancel());
  }

  // ── Defaults ───────────────────────────────────────────────────────────────

  /// One token per session, from BROKA's own authenticated endpoint. Never
  /// called per transcript.
  static Future<String> _defaultFetchToken() async {
    try {
      final body = await apiClient.post('/stt/deepgram-token', const {});
      if (body is Map && body['access_token'] is String) {
        return body['access_token'] as String;
      }
      throw VoiceSessionException(VoiceFailure.tokenUnavailable);
    } on ApiException catch (e) {
      // 503 is the server saying voice is switched off, which is a different
      // message to the user than "try again".
      throw VoiceSessionException(
        e.statusCode == 503
            ? VoiceFailure.notConfigured
            : VoiceFailure.tokenUnavailable,
      );
    } on VoiceSessionException {
      rethrow;
    } catch (_) {
      throw VoiceSessionException(VoiceFailure.tokenUnavailable);
    }
  }

  static WebSocketChannel _defaultConnect(Uri uri, String token) =>
      IOWebSocketChannel.connect(
        uri,
        // Bearer, not Token: the grant endpoint returns a JWT, and Deepgram
        // accepts JWTs only under the Bearer scheme.
        headers: {HttpHeaders.authorizationHeader: 'Bearer $token'},
        connectTimeout: const Duration(seconds: 10),
      );
}
