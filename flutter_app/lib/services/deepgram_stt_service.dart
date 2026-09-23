// lib/services/deepgram_stt_service.dart
//
// BROKA's primary realtime speech-to-text: microphone -> Deepgram WebSocket ->
// interim and final transcripts. Implements [RealtimeSttProvider], so nothing
// above it knows the vendor's name.
//
// Credentials. The permanent Deepgram key is never in this binary. Every
// session asks BROKA's own /stt/deepgram-token endpoint for a short-lived JWT
// and spends it on the WebSocket handshake.
//
// Two auth transports, because one of them is not always available. Deepgram
// documents both for a JWT minted by /v1/auth/grant:
//   * `Authorization: Bearer <jwt>` - preferred, and what dart:io can send;
//   * `?access_token=<jwt>` on the URL - documented for clients that cannot
//     set handshake headers.
// (The third form, `Sec-WebSocket-Protocol: token, <credential>`, is for
// permanent keys. Deepgram's own issue tracker has repeated reports of it
// closing the socket immediately when given something JWT-length, so it is
// not used here at all.)
//
// This service starts with the header and falls back to the query parameter
// on a handshake failure, then remembers which one worked for the rest of the
// process. That is not belt-and-braces: a WebSocket handshake header can be
// dropped by a carrier proxy or an OEM network stack, and when it is, the
// header form fails identically to a bad key - with no body and no error
// message. Trying the documented alternative once is the difference between
// "voice is broken on this phone" and a 200 ms delay on the first session.
//
// Audio. Capture belongs to the shared [MicrophoneSource]; this file only
// forwards its PCM16 frames as binary WebSocket messages, which is exactly
// what Deepgram's encoding=linear16 wants - no re-encoding, no base64.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/network/api_client.dart';
import 'realtime_stt.dart';

/// How the session token is presented to Deepgram.
enum DeepgramAuthMode {
  /// `Authorization: Bearer <jwt>` handshake header.
  header,

  /// `?access_token=<jwt>` on the WebSocket URL, for stacks that drop or
  /// refuse custom handshake headers.
  queryParam,
}

/// Opens a socket. Injected so tests drive the real service without a network.
typedef DeepgramConnector = WebSocketChannel Function(
    Uri uri, Map<String, String> headers);

/// How one BROKA language maps onto Deepgram's model/language pair.
///
/// Checked against Deepgram's own statements (Sept 2026): Nova-3's
/// `language=multi` is a code-switching mode over a fixed European/Asian set -
/// Deepgram staff listed it as English, Spanish, French, German, Hindi,
/// Russian, Portuguese, Japanese, Italian and Dutch - and the 2026 expansions
/// that took Nova-3 past 36 languages were Europe, South Asia, East Asia,
/// South-East Asia and Arabic. No Bantu or Nilotic language appears in any of
/// them. Deepgram transcribes Kiswahili only through Whisper Cloud, which is
/// pre-recorded audio only and cannot stream.
///
/// So the five non-English BROKA languages run on `en`, not `multi`. That is
/// not a claim they are supported - it is the least-wrong option of three:
///   * `multi` would hand Kiswahili to a model that must answer in Spanish,
///     Italian or Dutch, producing confident text in a language the user does
///     not read;
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
  const DeepgramLanguage._();

  static const Map<String, ProviderLanguageConfig> _byBrokaKey = {
    'english': ProviderLanguageConfig(
        model: 'nova-3', language: 'en', supported: true),
    // See the class doc: Deepgram has no streaming model for any of these, so
    // they run on English and are flagged so the card can say so.
    'swahili': ProviderLanguageConfig(
        model: 'nova-3', language: 'en', supported: false),
    'sheng': ProviderLanguageConfig(
        model: 'nova-3', language: 'en', supported: false),
    'luo': ProviderLanguageConfig(
        model: 'nova-3', language: 'en', supported: false),
    'kikuyu': ProviderLanguageConfig(
        model: 'nova-3', language: 'en', supported: false),
    'luganda': ProviderLanguageConfig(
        model: 'nova-3', language: 'en', supported: false),
  };

  static ProviderLanguageConfig forBrokaLanguage(String? key) =>
      _byBrokaKey[(key ?? 'english').toLowerCase().trim()] ??
      _byBrokaKey['english']!;
}

class DeepgramSttService implements RealtimeSttProvider {
  DeepgramSttService({
    MicrophoneSource? microphone,
    Future<String> Function()? fetchToken,
    DeepgramConnector? connect,
    this.tokenTimeout = SttTimeouts.token,
    this.handshakeTimeout = SttTimeouts.handshake,
    this.microphoneTimeout = SttTimeouts.microphoneStart,
  })  : _mic = microphone ?? MicrophoneSource(),
        _fetchToken = fetchToken ?? _defaultFetchToken,
        _connect = connect ?? _defaultConnect;

  // The three seams that cannot exist in a widget test: a microphone, BROKA's
  // backend, and Deepgram's socket.
  final MicrophoneSource _mic;
  final Future<String> Function() _fetchToken;
  final DeepgramConnector _connect;

  /// See [SttTimeouts]. Constructor parameters, not constants, so a test can
  /// drive every timeout branch in milliseconds.
  final Duration tokenTimeout;
  final Duration handshakeTimeout;
  final Duration microphoneTimeout;

  static const _host = 'api.deepgram.com';
  static const _path = '/v1/listen';

  /// Which transport worked last. Static: once one session has established
  /// that this device's network stack drops handshake headers, every later
  /// session in the process should skip straight to the form that works.
  static DeepgramAuthMode preferredAuthMode = DeepgramAuthMode.header;

  /// Deepgram accepts these directly; the shared microphone produces them.
  static int get sampleRate => MicrophoneSource.sampleRate;
  static int get channels => MicrophoneSource.channels;

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

  /// Bumped by every start and every teardown.
  ///
  /// This is what makes the startup sequence safe. `start()` awaits four
  /// separate things - permission, a token, a handshake, a microphone - and
  /// during any of them the user can hit X, the screen can pop, or the socket
  /// can die and trigger a teardown. Before the original version checked a
  /// single `_starting` bool, which a completed teardown could not
  /// invalidate: a failed handshake called cancel(), and start() then
  /// cheerfully went on to open the microphone anyway, leaving a recorder
  /// running with no socket and `_listening == true`. Every await in start()
  /// is now followed by a generation check, and a stale generation abandons
  /// the whole sequence.
  int _generation = 0;

  SttStage _stage = SttStage.idle;
  bool _listening = false;
  bool _disposed = false;

  /// Set once per session the moment a failure is reported, so a socket that
  /// errors and then closes produces one failure rather than two.
  bool _failed = false;

  /// Audio-format diagnostics, emitted once per session on the first chunk.
  bool _loggedAudioShape = false;

  @override
  String get name => 'deepgram';

  @override
  Stream<String> get interimTranscript => _interim.stream;
  @override
  Stream<String> get finalTranscript => _finals.stream;
  @override
  Stream<bool> get speechStarted => _speechStarted.stream;
  @override
  Stream<bool> get speechFinal => _speechFinal.stream;

  /// Rough 0..1 loudness, for the waveform. Derived from the PCM frames that
  /// are already flowing, so it costs one pass over a buffer we hold anyway
  /// and needs no second microphone stream.
  @override
  Stream<double> get audioLevel => _level.stream;

  @override
  Stream<VoiceSessionException> get failures => _failures.stream;

  /// Never: a dead Deepgram session is replaced by the manager, not revived
  /// here. Reconnecting in place would mean deciding, inside one vendor's
  /// file, that this vendor deserves another chance - which is exactly the
  /// judgement RealtimeSttManager exists to make.
  @override
  Stream<bool> get reconnecting => const Stream<bool>.empty();

  @override
  bool get isConnected => _channel != null && _stage.index >= SttStage.connected.index;
  @override
  bool get isListening => _listening;

  /// Visible for diagnostics and tests.
  SttStage get stage => _stage;

  @override
  ProviderLanguageConfig languageFor(String? brokaLanguage) =>
      DeepgramLanguage.forBrokaLanguage(brokaLanguage);

  /// Opens one session: permission, token, handshake, microphone - in that
  /// order, with the session generation re-checked after each.
  ///
  /// Throws [VoiceSessionException] with a failure that says which stage
  /// failed. Calling this while a session is already starting or running is a
  /// no-op rather than an error: the card's microphone button is tappable
  /// during the handshake, and two sockets sharing one microphone is the kind
  /// of bug that only shows up as a billing line.
  @override
  Future<void> start({String? brokaLanguage}) async {
    if (_disposed || _stage != SttStage.idle) return;

    final generation = ++_generation;
    _failed = false;
    _loggedAudioShape = false;
    _stage = SttStage.token;

    try {
      // ── Permission ────────────────────────────────────────────────────────
      if (!await _mic.hasPermission()) {
        throw VoiceSessionException(
          VoiceFailure.microphoneDenied,
          null,
          _diag(SttStage.microphone, 'MICROPHONE_PERMISSION_DENIED'),
        );
      }
      _assertCurrent(generation);

      // ── Token ─────────────────────────────────────────────────────────────
      final String token;
      try {
        token = await _fetchToken().timeout(tokenTimeout);
      } on TimeoutException {
        throw VoiceSessionException(
          VoiceFailure.tokenUnavailable,
          'token request timed out after ${tokenTimeout.inMilliseconds}ms',
          _diag(SttStage.token, 'DEEPGRAM_TOKEN_TIMEOUT'),
        );
      }
      _assertCurrent(generation);
      _log(SttStage.token, 'DEEPGRAM_TOKEN_OK');

      final config = DeepgramLanguage.forBrokaLanguage(brokaLanguage);

      // ── Handshake ─────────────────────────────────────────────────────────
      // Both documented transports, preferred first. A handshake that fails
      // for auth reasons and one that fails because a proxy ate the header
      // are indistinguishable from here, so the second attempt is worth its
      // ~200 ms whenever the first fails at the handshake.
      final order = preferredAuthMode == DeepgramAuthMode.header
          ? const [DeepgramAuthMode.header, DeepgramAuthMode.queryParam]
          : const [DeepgramAuthMode.queryParam, DeepgramAuthMode.header];

      VoiceSessionException? handshakeFailure;
      for (final mode in order) {
        _stage = SttStage.handshake;
        _log(SttStage.handshake, 'DEEPGRAM_HANDSHAKE_START',
            info: {'auth_mode': mode.name});
        try {
          await _openSocket(config: config, token: token, mode: mode);
          handshakeFailure = null;
          if (preferredAuthMode != mode) {
            preferredAuthMode = mode;
            _log(SttStage.handshake, 'DEEPGRAM_AUTH_MODE_SWITCHED',
                info: {'auth_mode': mode.name});
          }
          break;
        } on VoiceSessionException catch (e) {
          handshakeFailure = e;
          await _closeSocket();
          _assertCurrent(generation);
          // A timeout means the network path itself is not answering, not
          // that this particular transport was rejected - retrying the other
          // auth mode over the same dead path buys nothing and costs a
          // second full timeout window. Only retry on a fast, definitive
          // failure (a rejected upgrade, a closed connection).
          if (e.diagnostic?.event.endsWith('_TIMEOUT') == true) break;
        }
      }
      if (handshakeFailure != null) throw handshakeFailure;
      _assertCurrent(generation);

      _stage = SttStage.connected;
      _log(SttStage.connected, 'DEEPGRAM_CONNECTED',
          info: {'auth_mode': preferredAuthMode.name});

      // Only now is there a live socket to listen to. Errors and closures
      // before this point arrived through `ready` instead, which is why there
      // is no ambiguity about whether a close belongs to the handshake or to
      // the session.
      _socketSub = _channel!.stream.listen(
        _onSocketMessage,
        onError: _onSocketError,
        onDone: _onSocketDone,
        cancelOnError: false,
      );

      // ── Microphone ────────────────────────────────────────────────────────
      _stage = SttStage.microphone;
      final Stream<Uint8List> audio;
      try {
        audio = await _mic.start().timeout(microphoneTimeout);
      } on TimeoutException {
        throw VoiceSessionException(
          VoiceFailure.microphoneStartFailed,
          'microphone did not start within '
          '${microphoneTimeout.inMilliseconds}ms',
          _diag(SttStage.microphone, 'MICROPHONE_START_TIMEOUT'),
        );
      } on VoiceSessionException {
        rethrow;
      } catch (e) {
        throw VoiceSessionException(
          VoiceFailure.microphoneStartFailed,
          '$e',
          _diag(SttStage.microphone, 'MICROPHONE_START_FAILED', safeError: '$e'),
        );
      }
      _assertCurrent(generation);

      _audioSub = audio.listen(
        _onAudio,
        onError: (e) => _fail(VoiceSessionException(
          VoiceFailure.microphoneStartFailed,
          '$e',
          _diag(SttStage.streaming, 'MICROPHONE_STREAM_ERROR', safeError: '$e'),
        )),
        cancelOnError: false,
      );

      // Deepgram drops a connection with ~10s of no audio. A user thinking
      // about what to ask is not a disconnect.
      _keepAlive = Timer.periodic(const Duration(seconds: 5), (_) {
        if (_channel != null) _send(jsonEncode({'type': 'KeepAlive'}));
      });

      _stage = SttStage.streaming;
      _listening = true;
      _log(SttStage.streaming, 'DEEPGRAM_STREAMING');
    } on _SessionSuperseded {
      // The user closed the card, the screen went away, or a teardown ran
      // while this start was mid-await. Nothing failed; this start simply no
      // longer has a session to finish. Whoever superseded it owns the
      // teardown, so touching state here would stomp a newer session.
      _log(_stage, 'DEEPGRAM_START_SUPERSEDED');
      return;
    } catch (e) {
      // Whatever stage threw, the session does not survive it.
      if (_generation == generation) {
        await _teardown();
      }
      if (e is VoiceSessionException) {
        if (e.diagnostic != null) {
          SttDiagnostics.record(e.diagnostic!);
        } else {
          _log(_stage, 'DEEPGRAM_START_FAILED', safeError: '${e.failure.name}');
        }
        rethrow;
      }
      _log(_stage, 'DEEPGRAM_START_FAILED', safeError: '$e');
      throw VoiceSessionException(VoiceFailure.unknown, '$e');
    }
  }

  /// Opens and *verifies* one socket.
  ///
  /// [WebSocketChannel] construction is synchronous and tells you nothing: the
  /// object exists long before - and whether or not - the upgrade succeeds.
  /// The original code treated a returned object as a connection, wrapped
  /// only the constructor in a try, and then started the microphone. Awaiting
  /// `ready` is what makes "a channel exists" and "Deepgram accepted this
  /// handshake" two different facts.
  Future<void> _openSocket({
    required ProviderLanguageConfig config,
    required String token,
    required DeepgramAuthMode mode,
  }) async {
    final uri = _uriFor(config,
        accessToken: mode == DeepgramAuthMode.queryParam ? token : null);
    final headers = mode == DeepgramAuthMode.header
        // Bearer, not Token: the grant endpoint returns a JWT, and Deepgram
        // accepts JWTs only under the Bearer scheme.
        ? {HttpHeaders.authorizationHeader: 'Bearer $token'}
        : const <String, String>{};

    final WebSocketChannel channel;
    try {
      channel = _connect(uri, headers);
    } catch (e) {
      throw VoiceSessionException(
        VoiceFailure.handshakeFailed,
        '$e',
        _diag(SttStage.handshake, 'DEEPGRAM_HANDSHAKE_FAILED',
            safeError: '$e', info: {'auth_mode': mode.name}),
      );
    }
    _channel = channel;

    try {
      await channel.ready.timeout(handshakeTimeout);
    } on TimeoutException {
      // Independent of whatever `connectTimeout` the connector itself may or
      // may not honour - see [SttTimeouts]. This is the guarantee that
      // "Connecting…" ends.
      throw VoiceSessionException(
        VoiceFailure.handshakeFailed,
        'handshake timed out after ${handshakeTimeout.inMilliseconds}ms',
        _diag(SttStage.handshake, 'DEEPGRAM_HANDSHAKE_TIMEOUT',
            info: {
              'auth_mode': mode.name,
              'timeout_ms': handshakeTimeout.inMilliseconds,
            }),
      );
    } catch (e) {
      throw VoiceSessionException(
        VoiceFailure.handshakeFailed,
        '$e',
        _diag(SttStage.handshake, _connectEventFor(e),
            safeError: _describeConnectError(e),
            info: {'auth_mode': mode.name}),
      );
    }
  }

  Uri _uriFor(ProviderLanguageConfig config, {String? accessToken}) => Uri(
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
          if (accessToken != null) 'access_token': accessToken,
        },
      );

  /// Graceful stop: ask Deepgram to flush what it is holding, then close.
  ///
  /// The last words someone says are the ones most likely to still be sitting
  /// in Deepgram's buffer as an interim result, so a hard close here would
  /// routinely lose the end of an utterance.
  @override
  Future<void> stop() async {
    if (_stage == SttStage.idle) return;
    _generation++;
    _stage = SttStage.closing;
    _listening = false;
    // Timers first, and synchronously: everything below this line awaits, and
    // a keep-alive firing into a half-closed socket during that window is
    // both a crash risk and - in a widget test - a timer outliving the tree.
    _keepAlive?.cancel();
    _keepAlive = null;
    await _audioSub?.cancel();
    _audioSub = null;
    await _mic.stop();

    _send(jsonEncode({'type': 'Finalize'}));
    // A brief window for the flushed final to arrive before the socket goes.
    await Future<void>.delayed(const Duration(milliseconds: 350));
    _send(jsonEncode({'type': 'CloseStream'}));
    await _closeSocket();
    _stage = SttStage.idle;
    _log(SttStage.closing, 'DEEPGRAM_STOPPED');
  }

  /// Immediate teardown, no flush. For the X button and for leaving the
  /// screen, where a late transcript has nowhere to go anyway.
  @override
  Future<void> cancel() async {
    _generation++;
    // Synchronous first, before any await: a cancel racing a start must
    // invalidate that start's generation immediately, and the keep-alive must
    // be dead before this method yields.
    _keepAlive?.cancel();
    _keepAlive = null;
    _listening = false;
    await _teardown();
  }

  Future<void> _teardown() async {
    _stage = SttStage.closing;
    _listening = false;
    _keepAlive?.cancel();
    _keepAlive = null;
    final audio = _audioSub;
    _audioSub = null;
    await audio?.cancel();
    await _mic.cancel();
    await _closeSocket();
    _stage = SttStage.idle;
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await cancel();
    await _mic.dispose();
    await _interim.close();
    await _finals.close();
    await _speechStarted.close();
    await _speechFinal.close();
    await _level.close();
    await _failures.close();
  }

  // ── Internals ──────────────────────────────────────────────────────────────

  /// Abandons a start whose session has been superseded or torn down.
  void _assertCurrent(int generation) {
    if (_generation != generation || _disposed) {
      throw const _SessionSuperseded();
    }
  }

  void _onAudio(Uint8List chunk) {
    if (chunk.isEmpty) return;
    if (!_loggedAudioShape) {
      _loggedAudioShape = true;
      // Configuration is a request, not a receipt. This records what the
      // recorder is actually producing, so "we asked for 16 kHz PCM16" and
      // "16 kHz PCM16 is what is on the wire" stop being the same claim.
      final samples = chunk.lengthInBytes ~/ MicrophoneSource.bytesPerSample;
      _log(SttStage.streaming, 'DEEPGRAM_AUDIO_SHAPE', info: {
        'bytes_per_chunk': chunk.lengthInBytes,
        'samples_per_chunk': samples,
        'chunk_ms': (samples * 1000 / MicrophoneSource.sampleRate).round(),
        'sample_rate': MicrophoneSource.sampleRate,
        'channels': MicrophoneSource.channels,
        'encoding': 'pcm16le',
      });
    }
    if (!_level.isClosed) _level.add(pcmLevel(chunk));
    final channel = _channel;
    if (channel == null) return;
    try {
      channel.sink.add(chunk);
    } catch (_) {
      // A send on a closing socket is not worth tearing the session down for;
      // the onDone/onError handlers own that decision.
    }
  }

  void _onSocketError(Object e) {
    _fail(VoiceSessionException(
      VoiceFailure.socketClosed,
      '$e',
      _diag(SttStage.streaming, 'DEEPGRAM_SOCKET_ERROR',
          safeError: _describeConnectError(e),
          closeCode: _closeCodeOf(_channel),
          closeReason: _closeReasonOf(_channel)),
    ));
  }

  /// Deepgram closed on us.
  ///
  /// Reached in two different phases, both of which matter: after `ready`
  /// completed but before the microphone is up (a socket accepted and then
  /// dropped, which the original `if (_listening)` guard silently ignored),
  /// and mid-session. [_failed] keeps a socket that errors and then closes
  /// from reporting twice.
  void _onSocketDone() {
    if (_stage == SttStage.idle || _stage == SttStage.closing) return;
    _fail(VoiceSessionException(
      VoiceFailure.socketClosed,
      'socket closed',
      _diag(_stage, 'DEEPGRAM_SOCKET_CLOSED',
          closeCode: _closeCodeOf(_channel),
          closeReason: _closeReasonOf(_channel)),
    ));
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
        // Deepgram's own error frame: it accepted the socket and then
        // objected to something. Distinct from a transport failure, and the
        // one case where the provider tells us why in words.
        final description =
            '${event['description'] ?? event['message'] ?? 'deepgram error'}';
        _fail(VoiceSessionException(
          VoiceFailure.providerError,
          description,
          _diag(SttStage.streaming, 'DEEPGRAM_SERVER_ERROR',
              safeError: description),
        ));
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
    if (_failed) return;
    _failed = true;
    if (e.diagnostic != null) SttDiagnostics.record(e.diagnostic!);
    if (!_failures.isClosed) _failures.add(e);
    // Fire and forget: the caller learns about this through the stream, and
    // awaiting teardown inside an error handler risks deadlocking on the very
    // socket that failed.
    unawaited(cancel());
  }

  // ── Diagnostics ────────────────────────────────────────────────────────────

  SttDiagnostic _diag(
    SttStage stage,
    String event, {
    String? safeError,
    int? closeCode,
    String? closeReason,
    Map<String, Object?>? info,
  }) =>
      SttDiagnostic(
        provider: 'deepgram',
        stage: stage,
        event: event,
        safeError: safeError,
        closeCode: closeCode,
        closeReason: closeReason,
        info: info,
      );

  void _log(SttStage stage, String event,
          {String? safeError, Map<String, Object?>? info}) =>
      SttDiagnostics.record(
          _diag(stage, event, safeError: safeError, info: info));

  static int? _closeCodeOf(WebSocketChannel? c) {
    try {
      return c?.closeCode;
    } catch (_) {
      return null;
    }
  }

  static String? _closeReasonOf(WebSocketChannel? c) {
    try {
      return c?.closeReason;
    } catch (_) {
      return null;
    }
  }

  /// The greppable name for *why* a handshake failed.
  ///
  /// All of these are [VoiceFailure.handshakeFailed] to the user - the card
  /// has one honest sentence for "voice could not connect" - but a support
  /// conversation needs them apart: a rejected upgrade is a credential
  /// problem on the server, a SocketException is the user's connection, a
  /// timeout is a network that accepted the TCP connection and then went
  /// quiet, and each points at a different person to go and talk to.
  static String _connectEventFor(Object e) {
    final inner = e is WebSocketChannelException ? (e.inner ?? e) : e;
    if (inner is SocketException) return 'DEEPGRAM_NETWORK_UNREACHABLE';
    if (inner is HandshakeException) return 'DEEPGRAM_TLS_FAILED';
    if (inner is TimeoutException) return 'DEEPGRAM_HANDSHAKE_TIMEOUT';
    return 'DEEPGRAM_HANDSHAKE_FAILED';
  }

  /// A readable, credential-free description.
  ///
  /// dart:io's WebSocketException for a rejected upgrade carries the HTTP
  /// status in its message ("Connection to '...' was not upgraded to
  /// websocket, HTTP status code: 401"), which is the single most useful
  /// string in this whole file - it separates "Deepgram refused the
  /// credential" from "the network never got there". [SttDiagnostics.redact]
  /// scrubs the URL it quotes, which may carry access_token.
  static String _describeConnectError(Object e) {
    final inner = e is WebSocketChannelException ? (e.inner ?? e) : e;
    if (inner is WebSocketException) return 'WebSocketException: ${inner.message}';
    if (inner is SocketException) {
      final os = inner.osError;
      return 'SocketException: ${inner.message}'
          '${os == null ? '' : ' (errno ${os.errorCode})'}';
    }
    if (inner is HandshakeException) return 'HandshakeException: ${inner.message}';
    if (inner is TimeoutException) return 'TimeoutException';
    return '$inner';
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
      throw VoiceSessionException(
        VoiceFailure.tokenUnavailable,
        'malformed token response',
        SttDiagnostic(
            provider: 'deepgram',
            stage: SttStage.token,
            event: 'DEEPGRAM_TOKEN_MALFORMED'),
      );
    } on ApiException catch (e) {
      // 503 is the server saying voice is switched off, which is a different
      // message to the user than "try again".
      throw VoiceSessionException(
        e.statusCode == 503
            ? VoiceFailure.notConfigured
            : VoiceFailure.tokenUnavailable,
        'http ${e.statusCode}',
        SttDiagnostic(
          provider: 'deepgram',
          stage: SttStage.token,
          event: 'DEEPGRAM_TOKEN_FETCH_FAILED',
          info: {'http_status': e.statusCode},
        ),
      );
    } on VoiceSessionException {
      rethrow;
    } catch (e) {
      throw VoiceSessionException(
        VoiceFailure.tokenUnavailable,
        '$e',
        SttDiagnostic(
            provider: 'deepgram',
            stage: SttStage.token,
            event: 'DEEPGRAM_TOKEN_FETCH_FAILED',
            safeError: '$e'),
      );
    }
  }

  /// dart:io's channel is the only one that can send handshake headers, which
  /// is why BROKA - an Android and iOS app - uses it rather than the
  /// platform-agnostic `WebSocketChannel.connect`.
  static WebSocketChannel _defaultConnect(Uri uri, Map<String, String> headers) =>
      IOWebSocketChannel.connect(
        uri,
        headers: headers.isEmpty ? null : headers,
        connectTimeout: const Duration(seconds: 10),
      );
}

/// Thrown internally when a start has been superseded by a newer one or by a
/// teardown. Never escapes [DeepgramSttService.start]: it means "stop quietly",
/// not "tell the user something failed".
class _SessionSuperseded implements Exception {
  const _SessionSuperseded();
}
