// lib/services/realtime_stt.dart
//
// What BROKA needs from a realtime speech-to-text vendor, expressed without
// naming one.
//
// Deepgram is primary and AssemblyAI is the fallback, but nothing above this
// file knows that. ZenoVoiceController consumes [RealtimeSttProvider]; the
// manager picks which implementation is behind it. Adding a third vendor, or
// swapping the primary, is a new file and one line in the manager - not a
// change to the controller, the card, or either conversation screen.
//
// This file also owns the three things both providers genuinely share:
//  * the microphone ([MicrophoneSource]) - deliberately ONE owner, so two
//    providers cannot hold the recorder at the same time. That is a
//    structural guarantee rather than a rule someone has to remember;
//  * PCM chunk handling ([PcmChunkBuffer], [pcmLevel]) - both vendors take
//    16 kHz mono linear PCM16, and AssemblyAI has a minimum chunk duration;
//  * diagnostics ([SttDiagnostics]) - the reason a voice session failed, in a
//    form that can be read off a log without ever containing a credential.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Why a voice session could not run, or stopped running.
///
/// Every value here maps to a different sentence in the card and a different
/// decision in [RealtimeSttManager]: collapsing them into one "voice is
/// unavailable" is what made the original failure impossible to diagnose from
/// a user's screenshot.
enum VoiceFailure {
  /// The server has no API key for this provider. Voice is off for everyone
  /// on this provider, and no amount of retrying by this user changes that.
  notConfigured,

  /// The user declined the microphone permission prompt.
  microphoneDenied,

  /// Permission was granted but the recorder would not start - another app
  /// holds the microphone, the platform channel failed, the device has no
  /// usable input. Not the provider's fault, and failing over to a second
  /// provider cannot help.
  microphoneStartFailed,

  /// BROKA's own backend did not hand back a session token.
  tokenUnavailable,

  /// The WebSocket upgrade never completed: auth rejected, DNS, TLS, timeout.
  handshakeFailed,

  /// The socket was connected and then closed - by the provider, by the
  /// network, or by a proxy.
  socketClosed,

  /// The provider accepted the connection and then sent an error frame.
  providerError,

  /// Anything else.
  unknown,
}

/// A failure, with enough structure for the manager to decide what to do and
/// for a log to say what happened.
class VoiceSessionException implements Exception {
  VoiceSessionException(this.failure, [this.detail, this.diagnostic]);

  final VoiceFailure failure;

  /// Safe, provider-supplied or platform-supplied detail. Never a credential:
  /// see [SttDiagnostics.redact], which every construction path runs through.
  final String? detail;

  final SttDiagnostic? diagnostic;

  /// Whether trying a different speech vendor could possibly help.
  ///
  /// A denied microphone or a recorder that will not start is a device
  /// problem: failing over would burn a second token, open a second socket
  /// and produce the same silence. Everything else is worth a second opinion.
  bool get isProviderFault {
    switch (failure) {
      case VoiceFailure.microphoneDenied:
      case VoiceFailure.microphoneStartFailed:
        return false;
      case VoiceFailure.notConfigured:
      case VoiceFailure.tokenUnavailable:
      case VoiceFailure.handshakeFailed:
      case VoiceFailure.socketClosed:
      case VoiceFailure.providerError:
      case VoiceFailure.unknown:
        return true;
    }
  }

  @override
  String toString() => 'VoiceSessionException($failure, $detail)';
}

/// Where in a session's life something happened. Pairs with [SttDiagnostic].
enum SttStage { idle, token, handshake, connected, microphone, streaming, closing }

/// One line of the story of a voice session.
///
/// Structured rather than a printf so the fields can be asserted in tests and
/// read consistently off a log: `provider=deepgram stage=handshake
/// event=DEEPGRAM_HANDSHAKE_FAILED safe_error=...`.
@immutable
class SttDiagnostic {
  SttDiagnostic({
    required this.provider,
    required this.stage,
    required this.event,
    String? safeError,
    this.closeCode,
    String? closeReason,
    this.info,
  })  : safeError = SttDiagnostics.redact(safeError),
        closeReason = SttDiagnostics.redact(closeReason),
        at = DateTime.now();

  final String provider;
  final SttStage stage;

  /// A stable, greppable identifier: DEEPGRAM_HANDSHAKE_FAILED,
  /// MICROPHONE_START_FAILED, ASSEMBLYAI_SOCKET_CLOSED, and so on.
  final String event;

  final String? safeError;
  final int? closeCode;
  final String? closeReason;

  /// Non-sensitive extras - chunk sizes, sample rate, durations.
  final Map<String, Object?>? info;

  final DateTime at;

  String toLogLine() {
    final b = StringBuffer()
      ..write('provider=$provider')
      ..write(' stage=${stage.name}')
      ..write(' event=$event');
    if (safeError != null) b.write(' safe_error="$safeError"');
    if (closeCode != null) b.write(' close_code=$closeCode');
    if (closeReason != null) b.write(' close_reason="$closeReason"');
    if (info != null) {
      for (final e in info!.entries) {
        b.write(' ${e.key}=${e.value}');
      }
    }
    return b.toString();
  }

  @override
  String toString() => toLogLine();
}

/// The diagnostic sink.
///
/// Keeps the last [_capacity] lines in memory so a failing session can be
/// inspected after the fact, and prints in debug builds only. Nothing here
/// ever reaches a crash reporter or the network: this is a developer tool,
/// and transcripts are the user's own words.
class SttDiagnostics {
  SttDiagnostics._();

  static const int _capacity = 80;
  static final List<SttDiagnostic> _recent = [];
  static final StreamController<SttDiagnostic> _stream =
      StreamController<SttDiagnostic>.broadcast();

  /// Most recent last.
  static List<SttDiagnostic> get recent => List.unmodifiable(_recent);

  static Stream<SttDiagnostic> get stream => _stream.stream;

  static void record(SttDiagnostic d) {
    _recent.add(d);
    if (_recent.length > _capacity) _recent.removeAt(0);
    if (!_stream.isClosed) _stream.add(d);
    if (kDebugMode) {
      debugPrint('[stt] ${d.toLogLine()}');
    }
  }

  static void clear() => _recent.clear();

  /// Last-line defence against a credential reaching a log.
  ///
  /// Nothing in this codebase deliberately puts a token in a diagnostic, but
  /// provider error strings and platform exceptions sometimes echo the
  /// request that failed - a URL with `?access_token=`, an `Authorization`
  /// header - and a leaked key is not the sort of thing to leave to
  /// discipline alone. Long opaque runs are replaced wholesale rather than
  /// trimmed, because a truncated JWT is still a JWT prefix.
  static String? redact(String? raw) {
    if (raw == null) return null;
    var s = raw;
    s = s.replaceAll(
        RegExp(r'(access_token|token|api[-_]?key|authorization)'
            r'\s*[=:]\s*"?[A-Za-z0-9._\-]+"?',
            caseSensitive: false),
        r'$1=<redacted>');
    s = s.replaceAll(
        RegExp(r'\b(Bearer|Token)\s+[A-Za-z0-9._\-]+', caseSensitive: false),
        r'$1 <redacted>');
    // Any remaining JWT-shaped run, wherever it came from.
    s = s.replaceAll(
        RegExp(r'\beyJ[A-Za-z0-9._\-]{10,}'), '<redacted-jwt>');
    if (s.length > 400) s = '${s.substring(0, 400)}…';
    return s;
  }
}

/// How long a startup stage may run before it counts as hung, so
/// "Connecting…" is never permanent.
///
/// Each provider bounds every awaited stage of `start()` with one of these -
/// token fetch, WebSocket handshake, microphone start - independently of
/// whatever timeout the underlying HTTP or WebSocket library claims to
/// apply internally. That independence is the point: a library's own
/// `connectTimeout` is one line easy to get right and just as easy to have
/// silently stop applying after a dependency bump, and the cost of a
/// redundant `.timeout()` here is a few characters against the cost of a
/// permanently stuck "Connecting…" screen.
///
/// Durations are generous enough for a real round trip over a weak Kenyan
/// mobile connection and short enough that a genuinely dead path fails into
/// the next thing - a retry, or the other provider - inside a time a person
/// will wait for once, not stare at.
///
/// Each service takes these as constructor parameters with these values as
/// defaults, so a test can inject a handful of milliseconds instead of
/// actually waiting out a production timeout.
class SttTimeouts {
  const SttTimeouts._();

  static const Duration token = Duration(seconds: 12);
  static const Duration handshake = Duration(seconds: 10);
  static const Duration microphoneStart = Duration(seconds: 8);
}

/// Closes a provider's socket without ever hanging the caller.
///
/// web_socket_channel never completes `sink.close()` on a channel whose
/// handshake failed - an upgrade the server refused (a rejected token comes
/// back as HTTP 401) or a host that couldn't be reached: nothing listens on
/// the stream the close is waiting for. Both providers awaited it inside
/// their handshake retry, so start() froze there and the voice card said
/// "Connecting…" until RealtimeSttManager's 45-second watchdog gave up on
/// the provider - and then the same again for the next one. Nobody waits
/// 90 seconds; to the user the microphone simply never worked.
///
/// A socket that never opened has nothing to say goodbye to, so its close is
/// not waited for at all. An open one gets [grace] to exchange close frames
/// with a server that may already be gone.
Future<void> closeSocketWithoutHanging(
  WebSocketChannel? channel, {
  required bool opened,
  Duration grace = const Duration(seconds: 2),
}) async {
  if (channel == null) return;
  final Future<void> closed;
  try {
    closed = channel.sink.close();
  } catch (_) {
    return;
  }
  if (!opened) {
    unawaited(closed.catchError((_) {}));
    return;
  }
  try {
    await closed.timeout(grace);
  } catch (_) {}
}

/// A provider's answer for one BROKA language.
///
/// [supported] is a claim about the vendor's documentation, not a hope. The
/// card tells the user when it is false; see the per-provider tables.
@immutable
class ProviderLanguageConfig {
  const ProviderLanguageConfig({
    required this.model,
    required this.language,
    required this.supported,
  });

  final String model;
  final String language;
  final bool supported;
}

/// What ZenoVoiceController consumes. No vendor concepts cross this line.
abstract class RealtimeSttProvider {
  /// Lowercase, stable, used in diagnostics: 'deepgram', 'assemblyai'.
  String get name;

  /// Opens one session. Throws [VoiceSessionException] on failure.
  Future<void> start({String? brokaLanguage});

  /// Graceful stop: flush whatever the provider is holding, then close.
  Future<void> stop();

  /// Immediate teardown, no flush.
  Future<void> cancel();

  Future<void> dispose();

  /// Live, still-being-revised text.
  Stream<String> get interimTranscript;

  /// Text the provider has stopped revising.
  Stream<String> get finalTranscript;

  /// The provider heard speech begin.
  Stream<bool> get speechStarted;

  /// An utterance/turn completed - the cue to send to Zeno.
  Stream<bool> get speechFinal;

  /// 0..1 microphone loudness, for the waveform.
  Stream<double> get audioLevel;

  /// Failures after a successful start. Failures during start are thrown.
  Stream<VoiceSessionException> get failures;

  /// True while the session is being re-established and false once it is.
  ///
  /// On the interface rather than only on the manager because "this session
  /// is coming back" is a fact about speech recognition, not about failover:
  /// a single provider that reconnects its own socket would report it the
  /// same way, and the controller should not have to ask what kind of object
  /// it is holding to know whether to say "Reconnecting voice…".
  Stream<bool> get reconnecting;

  bool get isConnected;
  bool get isListening;

  ProviderLanguageConfig languageFor(String? brokaLanguage);
}

/// The single owner of the microphone.
///
/// Both providers take one of these, and [RealtimeSttManager] hands both of
/// them the SAME instance. Two vendors cannot therefore hold the recorder at
/// once however the failover logic is later edited - the object will not let
/// them, and [start] stops a previous stream before opening a new one.
class MicrophoneSource {
  MicrophoneSource({AudioRecorder? recorder})
      : _recorder = recorder ?? AudioRecorder();

  final AudioRecorder _recorder;

  /// What both vendors want, and what the app therefore only has to capture
  /// once: 16 kHz mono linear PCM16. A quarter of the bytes of 44.1 kHz
  /// stereo on a Kenyan mobile connection, and the format both WebSocket APIs
  /// accept with no re-encoding.
  static const int sampleRate = 16000;
  static const int channels = 1;
  static const int bytesPerSample = 2;

  bool _running = false;
  bool _disposed = false;
  bool get isRunning => _running;

  /// Permission, without requesting it a second time once denied.
  Future<bool> hasPermission() async {
    try {
      return await _recorder.hasPermission();
    } catch (e) {
      SttDiagnostics.record(SttDiagnostic(
        provider: 'microphone',
        stage: SttStage.microphone,
        event: 'MICROPHONE_PERMISSION_CHECK_FAILED',
        safeError: '$e',
      ));
      return false;
    }
  }

  /// Starts capture. Throws [VoiceFailure.microphoneStartFailed] - never a
  /// provider failure, because a recorder that will not start is not the
  /// speech vendor's doing and failing over to a second vendor cannot fix it.
  Future<Stream<Uint8List>> start() async {
    if (_running) await stop();
    try {
      final stream = await _recorder.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: channels,
        // Voice, in a room, on a phone. All three help the model more than
        // they cost in gain.
        echoCancel: true,
        noiseSuppress: true,
        autoGain: true,
        // Never paused by other audio. record's default (pause) takes
        // Android's audio focus and pauses capture on any focus loss,
        // with no resume - and Zeno's own reply, played by BrokaTts's
        // AudioPlayer, requests focus. So the first thing Zeno said
        // paused the microphone for the rest of the session, while the
        // socket's KeepAlive kept it looking connected: voice mode said
        // "Listening" and heard nothing the user said after Zeno spoke.
        audioInterruption: AudioInterruptionMode.none,
      ));
      _running = true;
      SttDiagnostics.record(SttDiagnostic(
        provider: 'microphone',
        stage: SttStage.microphone,
        event: 'MICROPHONE_STARTED',
        info: const {
          'sample_rate': sampleRate,
          'channels': channels,
          'encoding': 'pcm16le',
        },
      ));
      return stream;
    } catch (e) {
      SttDiagnostics.record(SttDiagnostic(
        provider: 'microphone',
        stage: SttStage.microphone,
        event: 'MICROPHONE_START_FAILED',
        safeError: '$e',
      ));
      throw VoiceSessionException(VoiceFailure.microphoneStartFailed, '$e');
    }
  }

  Future<void> stop() async {
    _running = false;
    try {
      await _recorder.stop();
    } catch (_) {
      // Stopping a recorder that is already stopped is not an error worth
      // propagating into a teardown path.
    }
  }

  Future<void> cancel() async {
    _running = false;
    try {
      await _recorder.cancel();
    } catch (_) {
      try {
        await _recorder.stop();
      } catch (_) {}
    }
  }

  /// Idempotent: the manager shares one of these with every provider, so
  /// several of them will call this during one teardown.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _running = false;
    try {
      await _recorder.dispose();
    } catch (_) {}
  }
}

/// Mean absolute amplitude of a 16-bit little-endian frame, normalised to
/// 0..1 for the waveform.
///
/// Samples every 8th frame: the waveform needs a loudness, not a measurement,
/// and this runs on every audio chunk.
double pcmLevel(Uint8List chunk) {
  final samples = chunk.lengthInBytes ~/ 2;
  if (samples == 0) return 0;
  final view = ByteData.sublistView(chunk);
  var sum = 0;
  var counted = 0;
  for (var i = 0; i < samples; i += 8) {
    sum += view.getInt16(i * 2, Endian.little).abs();
    counted++;
  }
  if (counted == 0) return 0;
  // 32768 is full scale; speech sits far below it, so the divisor is tuned to
  // put normal speech in the upper half of the bar rather than a flicker at
  // the bottom.
  return (sum / counted / 6000).clamp(0.0, 1.0);
}

/// Re-frames the recorder's chunks to a provider's accepted size range.
///
/// `record` does not promise a chunk size; on Android it delivers whatever
/// the underlying AudioRecord buffer produces, which at 16 kHz PCM16 has been
/// seen anywhere from ~1 KB (32 ms) upward. AssemblyAI documents a 50 ms
/// minimum and 1000 ms maximum per binary frame, so shipping the raw chunks
/// straight through is a bug waiting for a device that buffers small.
///
/// Deepgram has no such floor, so it uses this only as a pass-through.
class PcmChunkBuffer {
  PcmChunkBuffer({
    required this.minBytes,
    required this.maxBytes,
  }) : assert(minBytes <= maxBytes);

  /// For 16 kHz mono PCM16: bytes = ms * 32.
  factory PcmChunkBuffer.forDuration({
    required int minMs,
    required int maxMs,
  }) {
    const bytesPerMs =
        MicrophoneSource.sampleRate * MicrophoneSource.channels *
            MicrophoneSource.bytesPerSample ~/ 1000;
    return PcmChunkBuffer(
      minBytes: minMs * bytesPerMs,
      maxBytes: maxMs * bytesPerMs,
    );
  }

  final int minBytes;
  final int maxBytes;

  final BytesBuilder _pending = BytesBuilder(copy: false);

  /// Accumulates [chunk] and returns whatever complete frames are now ready.
  ///
  /// Returns an empty list while under [minBytes] - the caller sends nothing
  /// and waits for the next chunk.
  List<Uint8List> add(Uint8List chunk) {
    if (chunk.isEmpty) return const [];
    _pending.add(chunk);
    if (_pending.length < minBytes) return const [];

    final all = _pending.takeBytes();
    final out = <Uint8List>[];
    var offset = 0;
    while (all.length - offset >= minBytes) {
      final take = (all.length - offset).clamp(0, maxBytes);
      out.add(Uint8List.sublistView(all, offset, offset + take));
      offset += take;
    }
    if (offset < all.length) {
      _pending.add(Uint8List.sublistView(all, offset));
    }
    return out;
  }

  /// Whatever is left, regardless of [minBytes]. For the end of a session,
  /// where waiting for a floor that will never arrive loses the last word.
  Uint8List? flush() {
    if (_pending.isEmpty) return null;
    return _pending.takeBytes();
  }

  void clear() => _pending.clear();
}
