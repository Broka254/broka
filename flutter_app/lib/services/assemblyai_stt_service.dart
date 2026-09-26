// lib/services/assemblyai_stt_service.dart
//
// BROKA's fallback realtime speech-to-text. Same shape as Deepgram - it
// implements [RealtimeSttProvider] - so ZenoVoiceController cannot tell which
// one is running, and the card never mentions a vendor.
//
// This is AssemblyAI's Universal Streaming (v3) WebSocket API, verified
// against their current documentation rather than a remembered example:
//
//   token     GET https://streaming.assemblyai.com/v3/token
//             ?expires_in_seconds=N   (1..600), header `Authorization: <key>`
//             with NO Bearer prefix. Minted server-side; see
//             backend/api/routers/stt.py. The permanent key never leaves
//             Render.
//   socket    wss://streaming.assemblyai.com/v3/ws
//             ?sample_rate=16000&encoding=pcm_s16le&format_turns=true
//             &token=<temporary token>
//             The temporary token goes in the query string - that is the
//             documented transport for it, and the only one accepted for a
//             temporary token.
//   audio     raw binary PCM16 frames, 50..1000 ms each.
//   events    Begin / Turn / Termination, as JSON text frames.
//   ending    send {"type":"Terminate"} and let the server flush.
//
// Two of those are easy to get wrong and are handled explicitly below: the
// 50 ms minimum frame size (the recorder does not promise one), and the fact
// that a formatted turn arrives as a SECOND end_of_turn message for the same
// turn_order - emitting both would send Zeno every sentence twice.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/network/api_client.dart';
import 'realtime_stt.dart';

/// Opens a socket. Injected so tests drive the real service without a network.
typedef AssemblyAiConnector = WebSocketChannel Function(Uri uri);

/// How one BROKA language maps onto AssemblyAI Universal Streaming.
///
/// Universal Streaming is an English-first product. As with Deepgram, none of
/// Kiswahili, Sheng, Dholuo, Kikuyu or Luganda appears in its documented
/// streaming language set, so they are marked unsupported and run on English
/// rather than being quietly presented as working. The card tells the user.
///
/// Do NOT flip a `supported` flag without re-checking AssemblyAI's current
/// streaming language documentation.
class AssemblyAiLanguage {
  const AssemblyAiLanguage._();

  static const _english = ProviderLanguageConfig(
      model: 'universal-streaming', language: 'en', supported: true);
  static const _unsupported = ProviderLanguageConfig(
      model: 'universal-streaming', language: 'en', supported: false);

  static const Map<String, ProviderLanguageConfig> _byBrokaKey = {
    'english': _english,
    'swahili': _unsupported,
    'sheng': _unsupported,
    'luo': _unsupported,
    'kikuyu': _unsupported,
    'luganda': _unsupported,
  };

  static ProviderLanguageConfig forBrokaLanguage(String? key) =>
      _byBrokaKey[(key ?? 'english').toLowerCase().trim()] ?? _english;
}

class AssemblyAiSttService implements RealtimeSttProvider {
  AssemblyAiSttService({
    MicrophoneSource? microphone,
    Future<String> Function()? fetchToken,
    AssemblyAiConnector? connect,
    this.tokenTimeout = SttTimeouts.token,
    this.handshakeTimeout = SttTimeouts.handshake,
    this.microphoneTimeout = SttTimeouts.microphoneStart,
  })  : _mic = microphone ?? MicrophoneSource(),
        _fetchToken = fetchToken ?? _defaultFetchToken,
        _connect = connect ?? _defaultConnect;

  final MicrophoneSource _mic;
  final Future<String> Function() _fetchToken;
  final AssemblyAiConnector _connect;

  /// See [SttTimeouts] and the identical fields on DeepgramSttService.
  final Duration tokenTimeout;
  final Duration handshakeTimeout;
  final Duration microphoneTimeout;

  static const _host = 'streaming.assemblyai.com';
  static const _path = '/v3/ws';

  /// AssemblyAI documents a 50 ms floor and a 1000 ms ceiling per audio
  /// frame. `record` makes no promise about chunk size - on Android it hands
  /// over whatever the platform buffer produced, which at 16 kHz PCM16 can be
  /// ~32 ms - so frames are re-cut here rather than hoped about. 100 ms sits
  /// clear of the floor without adding latency anyone can feel.
  static const int minChunkMs = 100;
  static const int maxChunkMs = 500;

  final _interim = StreamController<String>.broadcast();
  final _finals = StreamController<String>.broadcast();
  final _speechStarted = StreamController<bool>.broadcast();
  final _speechFinal = StreamController<bool>.broadcast();
  final _level = StreamController<double>.broadcast();
  final _failures = StreamController<VoiceSessionException>.broadcast();

  WebSocketChannel? _channel;

  /// Whether [_channel]'s handshake completed - see closeSocketWithoutHanging.
  bool _socketOpened = false;
  StreamSubscription<Uint8List>? _audioSub;
  StreamSubscription? _socketSub;
  PcmChunkBuffer? _buffer;

  int _generation = 0;
  SttStage _stage = SttStage.idle;
  bool _listening = false;
  bool _disposed = false;
  bool _failed = false;
  bool _loggedAudioShape = false;

  /// Turns whose final text has already been handed upward, so the formatted
  /// repeat of a turn does not send the same sentence to Zeno twice.
  final Set<int> _emittedTurns = <int>{};

  /// Unformatted finals waiting a moment for their formatted version.
  final Map<int, Timer> _pendingTurnTimers = {};

  /// The turn currently being spoken, so speechStarted fires once per turn
  /// rather than on every partial.
  int? _announcedTurn;

  /// Completes when the server acknowledges a Terminate, so a graceful stop
  /// can wait for the flush instead of guessing.
  Completer<void>? _terminated;

  @override
  String get name => 'assemblyai';

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

  /// Never: a dead AssemblyAI session is replaced by the manager, not revived
  /// here. Reconnecting in place would mean deciding, inside one vendor's
  /// file, that this vendor deserves another chance - which is exactly the
  /// judgement RealtimeSttManager exists to make.
  @override
  Stream<bool> get reconnecting => const Stream<bool>.empty();

  @override
  bool get isConnected =>
      _channel != null && _stage.index >= SttStage.connected.index;
  @override
  bool get isListening => _listening;

  SttStage get stage => _stage;

  @override
  ProviderLanguageConfig languageFor(String? brokaLanguage) =>
      AssemblyAiLanguage.forBrokaLanguage(brokaLanguage);

  @override
  Future<void> start({String? brokaLanguage}) async {
    if (_disposed || _stage != SttStage.idle) return;

    final generation = ++_generation;
    _failed = false;
    _loggedAudioShape = false;
    _emittedTurns.clear();
    _announcedTurn = null;
    _terminated = null;
    _buffer = PcmChunkBuffer.forDuration(minMs: minChunkMs, maxMs: maxChunkMs);
    _stage = SttStage.token;

    try {
      if (!await _mic.hasPermission()) {
        throw VoiceSessionException(
          VoiceFailure.microphoneDenied,
          null,
          _diag(SttStage.microphone, 'MICROPHONE_PERMISSION_DENIED'),
        );
      }
      _assertCurrent(generation);

      final String token;
      try {
        token = await _fetchToken().timeout(tokenTimeout);
      } on TimeoutException {
        throw VoiceSessionException(
          VoiceFailure.tokenUnavailable,
          'token request timed out after ${tokenTimeout.inMilliseconds}ms',
          _diag(SttStage.token, 'ASSEMBLYAI_TOKEN_TIMEOUT'),
        );
      }
      _assertCurrent(generation);
      _log(SttStage.token, 'ASSEMBLYAI_TOKEN_OK');

      _stage = SttStage.handshake;
      _log(SttStage.handshake, 'ASSEMBLYAI_HANDSHAKE_START');
      final uri = Uri(
        scheme: 'wss',
        host: _host,
        path: _path,
        queryParameters: {
          'sample_rate': '${MicrophoneSource.sampleRate}',
          'encoding': 'pcm_s16le',
          // Punctuation and casing on the finalised turn. BROKA users dictate
          // prices and model numbers; an unformatted turn is materially worse
          // input for Zeno.
          'format_turns': 'true',
          // The documented transport for a temporary token. It is short-lived
          // and single-use, and the permanent key is never in this app at all.
          'token': token,
        },
      );

      final WebSocketChannel channel;
      try {
        channel = _connect(uri);
      } catch (e) {
        throw VoiceSessionException(
          VoiceFailure.handshakeFailed,
          '$e',
          _diag(SttStage.handshake, 'ASSEMBLYAI_HANDSHAKE_FAILED',
              safeError: '$e'),
        );
      }
      _channel = channel;

      // As with Deepgram: a channel object is not a connection. `ready` is
      // what separates "constructed" from "AssemblyAI accepted this token" -
      // and it is bounded independently of whatever the connector's own
      // internal timeout may or may not do. See [SttTimeouts].
      try {
        await channel.ready.timeout(handshakeTimeout);
      } on TimeoutException {
        throw VoiceSessionException(
          VoiceFailure.handshakeFailed,
          'handshake timed out after ${handshakeTimeout.inMilliseconds}ms',
          _diag(SttStage.handshake, 'ASSEMBLYAI_HANDSHAKE_TIMEOUT',
              info: {'timeout_ms': handshakeTimeout.inMilliseconds}),
        );
      } catch (e) {
        throw VoiceSessionException(
          VoiceFailure.handshakeFailed,
          '$e',
          _diag(SttStage.handshake, _connectEventFor(e),
              safeError: _describeConnectError(e)),
        );
      }
      _socketOpened = true;
      _assertCurrent(generation);

      _stage = SttStage.connected;
      _log(SttStage.connected, 'ASSEMBLYAI_CONNECTED');

      _socketSub = channel.stream.listen(
        _onSocketMessage,
        onError: (e) => _fail(VoiceSessionException(
          VoiceFailure.socketClosed,
          '$e',
          _diag(SttStage.streaming, 'ASSEMBLYAI_SOCKET_ERROR',
              safeError: _describeConnectError(e),
              closeCode: _closeCodeOf(_channel),
              closeReason: _closeReasonOf(_channel)),
        )),
        onDone: _onSocketDone,
        cancelOnError: false,
      );

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

      _stage = SttStage.streaming;
      _listening = true;
      _log(SttStage.streaming, 'ASSEMBLYAI_STREAMING');
    } on _SessionSuperseded {
      _log(_stage, 'ASSEMBLYAI_START_SUPERSEDED');
      return;
    } catch (e) {
      if (_generation == generation) await _teardown();
      if (e is VoiceSessionException) {
        if (e.diagnostic != null) {
          SttDiagnostics.record(e.diagnostic!);
        } else {
          _log(_stage, 'ASSEMBLYAI_START_FAILED', safeError: e.failure.name);
        }
        rethrow;
      }
      _log(_stage, 'ASSEMBLYAI_START_FAILED', safeError: '$e');
      throw VoiceSessionException(VoiceFailure.unknown, '$e');
    }
  }

  /// Graceful stop, in the order AssemblyAI's docs require.
  ///
  /// Dropping the socket instead loses whatever the server is still holding -
  /// which is exactly the end of the user's last sentence. So: stop capture,
  /// flush the sub-50 ms remainder that would otherwise be stuck in the
  /// buffer, send Terminate, wait for the server's own Termination, and only
  /// then close.
  @override
  Future<void> stop() async {
    if (_stage == SttStage.idle) return;
    _generation++;
    _stage = SttStage.closing;
    _listening = false;

    await _audioSub?.cancel();
    _audioSub = null;
    await _mic.stop();

    // The tail below the 50 ms floor. AssemblyAI would reject it as a frame
    // of its own mid-stream, but at the end of a session it is the last
    // fragment of a word and worth sending.
    final tail = _buffer?.flush();
    if (tail != null && tail.isNotEmpty) _sendBinary(tail);
    _buffer = null;

    final done = _terminated = Completer<void>();
    _send(jsonEncode({'type': 'Terminate'}));
    try {
      await done.future.timeout(const Duration(milliseconds: 1200));
    } on TimeoutException {
      _log(SttStage.closing, 'ASSEMBLYAI_TERMINATE_TIMEOUT');
    }
    _terminated = null;

    await _closeSocket();
    _stage = SttStage.idle;
    _log(SttStage.closing, 'ASSEMBLYAI_STOPPED');
  }

  @override
  Future<void> cancel() async {
    _generation++;
    _listening = false;
    _cancelTurnTimers();
    await _teardown();
  }

  Future<void> _teardown() async {
    _stage = SttStage.closing;
    _listening = false;
    _cancelTurnTimers();
    final audio = _audioSub;
    _audioSub = null;
    await audio?.cancel();
    await _mic.cancel();
    _buffer = null;
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

  void _assertCurrent(int generation) {
    if (_generation != generation || _disposed) {
      throw const _SessionSuperseded();
    }
  }

  void _onAudio(Uint8List chunk) {
    if (chunk.isEmpty) return;
    if (!_loggedAudioShape) {
      _loggedAudioShape = true;
      final samples = chunk.lengthInBytes ~/ MicrophoneSource.bytesPerSample;
      _log(SttStage.streaming, 'ASSEMBLYAI_AUDIO_SHAPE', info: {
        'bytes_per_chunk': chunk.lengthInBytes,
        'samples_per_chunk': samples,
        'chunk_ms': (samples * 1000 / MicrophoneSource.sampleRate).round(),
        'min_frame_ms': minChunkMs,
        'sample_rate': MicrophoneSource.sampleRate,
        'channels': MicrophoneSource.channels,
        'encoding': 'pcm16le',
      });
    }
    if (!_level.isClosed) _level.add(pcmLevel(chunk));

    final buffer = _buffer;
    if (buffer == null || _channel == null) return;
    for (final frame in buffer.add(chunk)) {
      _sendBinary(frame);
    }
  }

  void _onSocketDone() {
    // A Terminate we sent ourselves ends with the socket closing; that is the
    // protocol working, not a failure.
    if (_stage == SttStage.idle || _stage == SttStage.closing) return;
    _fail(VoiceSessionException(
      VoiceFailure.socketClosed,
      'socket closed',
      _diag(_stage, 'ASSEMBLYAI_SOCKET_CLOSED',
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
      return;
    }

    switch (event['type']) {
      case 'Begin':
        // The session is genuinely live. `expires_at` is the server's own
        // deadline for it; recorded, not acted on - a session that outlives
        // it ends through the normal close path.
        _log(SttStage.connected, 'ASSEMBLYAI_SESSION_BEGIN', info: {
          'expires_at': event['expires_at'],
        });
        return;
      case 'Turn':
        _onTurn(event);
        return;
      case 'Termination':
        _log(SttStage.closing, 'ASSEMBLYAI_SESSION_TERMINATED', info: {
          'audio_duration_seconds': event['audio_duration_seconds'],
          'session_duration_seconds': event['session_duration_seconds'],
        });
        if (_terminated != null && !_terminated!.isCompleted) {
          _terminated!.complete();
        }
        return;
      case 'Error':
        final description = '${event['error'] ?? event['message'] ?? 'error'}';
        _fail(VoiceSessionException(
          VoiceFailure.providerError,
          description,
          _diag(SttStage.streaming, 'ASSEMBLYAI_SERVER_ERROR',
              safeError: description),
        ));
        return;
      default:
        return;
    }
  }

  /// One Turn message.
  ///
  /// `transcript` holds only the words AssemblyAI has finalised, so live text
  /// comes from the `words` array instead - it carries the not-yet-final tail
  /// that makes the card feel like it is keeping up with the speaker.
  ///
  /// With `format_turns=true` a completed turn arrives TWICE: once
  /// unformatted and once formatted, both with `end_of_turn: true` and the
  /// same `turn_order`. Sending both to Zeno would say everything twice, so a
  /// turn is emitted once - preferring the formatted text, and falling back
  /// to the unformatted one on a short timer if the formatted version never
  /// comes.
  void _onTurn(Map<String, dynamic> event) {
    final order = event['turn_order'] is int ? event['turn_order'] as int : -1;
    final endOfTurn = event['end_of_turn'] == true;
    final formatted = event['turn_is_formatted'] == true;
    final text = _textOf(event);

    if (!endOfTurn) {
      if (text.isEmpty) return;
      if (order != _announcedTurn) {
        _announcedTurn = order;
        if (!_speechStarted.isClosed) _speechStarted.add(true);
      }
      if (!_interim.isClosed) _interim.add(text);
      return;
    }

    if (_emittedTurns.contains(order)) return;

    if (formatted) {
      _pendingTurnTimers.remove(order)?.cancel();
      _emitTurn(order, text);
      return;
    }

    // Unformatted end-of-turn: give the formatted version a moment.
    _pendingTurnTimers[order]?.cancel();
    _pendingTurnTimers[order] = Timer(const Duration(milliseconds: 900), () {
      _pendingTurnTimers.remove(order);
      if (_emittedTurns.contains(order)) return;
      _emitTurn(order, text);
    });
    // Keep the live text on screen while that timer runs, so the card does
    // not appear to lose the sentence in the gap.
    if (text.isNotEmpty && !_interim.isClosed) _interim.add(text);
  }

  void _emitTurn(int order, String text) {
    _emittedTurns.add(order);
    _announcedTurn = null;
    if (text.isNotEmpty && !_finals.isClosed) _finals.add(text);
    if (!_speechFinal.isClosed) _speechFinal.add(true);
  }

  /// Prefers the word list, which includes the non-final tail; falls back to
  /// `transcript`, which is what a formatted turn carries.
  static String _textOf(Map<String, dynamic> event) {
    final words = event['words'];
    if (words is List && words.isNotEmpty) {
      final parts = <String>[];
      for (final w in words) {
        if (w is Map && w['text'] is String) {
          final t = (w['text'] as String).trim();
          if (t.isNotEmpty) parts.add(t);
        }
      }
      if (parts.isNotEmpty) return parts.join(' ');
    }
    final transcript = event['transcript'];
    return transcript is String ? transcript.trim() : '';
  }

  void _cancelTurnTimers() {
    for (final t in _pendingTurnTimers.values) {
      t.cancel();
    }
    _pendingTurnTimers.clear();
  }

  void _send(String message) {
    try {
      _channel?.sink.add(message);
    } catch (_) {}
  }

  void _sendBinary(Uint8List frame) {
    try {
      _channel?.sink.add(frame);
    } catch (_) {}
  }

  Future<void> _closeSocket() async {
    final sub = _socketSub;
    final channel = _channel;
    final opened = _socketOpened;
    _socketSub = null;
    _channel = null;
    _socketOpened = false;
    await sub?.cancel();
    await closeSocketWithoutHanging(channel, opened: opened);
  }

  void _fail(VoiceSessionException e) {
    if (_failed) return;
    _failed = true;
    if (e.diagnostic != null) SttDiagnostics.record(e.diagnostic!);
    if (!_failures.isClosed) _failures.add(e);
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
        provider: 'assemblyai',
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

  static String _connectEventFor(Object e) {
    final inner = e is WebSocketChannelException ? (e.inner ?? e) : e;
    if (inner is SocketException) return 'ASSEMBLYAI_NETWORK_UNREACHABLE';
    if (inner is HandshakeException) return 'ASSEMBLYAI_TLS_FAILED';
    if (inner is TimeoutException) return 'ASSEMBLYAI_HANDSHAKE_TIMEOUT';
    return 'ASSEMBLYAI_HANDSHAKE_FAILED';
  }

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

  static Future<String> _defaultFetchToken() async {
    try {
      final body = await apiClient.post('/stt/assemblyai-token', const {});
      if (body is Map && body['token'] is String) {
        return body['token'] as String;
      }
      throw VoiceSessionException(
        VoiceFailure.tokenUnavailable,
        'malformed token response',
        SttDiagnostic(
            provider: 'assemblyai',
            stage: SttStage.token,
            event: 'ASSEMBLYAI_TOKEN_MALFORMED'),
      );
    } on ApiException catch (e) {
      throw VoiceSessionException(
        e.statusCode == 503
            ? VoiceFailure.notConfigured
            : VoiceFailure.tokenUnavailable,
        'http ${e.statusCode}',
        SttDiagnostic(
          provider: 'assemblyai',
          stage: SttStage.token,
          event: 'ASSEMBLYAI_TOKEN_FETCH_FAILED',
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
            provider: 'assemblyai',
            stage: SttStage.token,
            event: 'ASSEMBLYAI_TOKEN_FETCH_FAILED',
            safeError: '$e'),
      );
    }
  }

  static WebSocketChannel _defaultConnect(Uri uri) => IOWebSocketChannel.connect(
        uri,
        connectTimeout: const Duration(seconds: 10),
      );
}

/// See the note on Deepgram's copy: means "stop quietly", not "tell the user".
class _SessionSuperseded implements Exception {
  const _SessionSuperseded();
}
