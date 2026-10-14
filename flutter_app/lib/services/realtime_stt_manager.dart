// lib/services/realtime_stt_manager.dart
//
// Which speech vendor is running, and what happens when one of them stops
// working. It is itself a [RealtimeSttProvider], so ZenoVoiceController binds
// to one object and never learns that there are two behind it.
//
// The policy, in one paragraph. Deepgram is primary. If Deepgram cannot get a
// token, cannot complete a handshake, or errors out before or during a
// session, AssemblyAI is started instead - once. If the microphone is denied
// or will not start, nothing fails over, because a second vendor would open a
// second socket to listen to the same silence. A session that is already
// streaming is never switched for being slow; only a dead session is
// replaced.
//
// The one invariant worth stating loudly: there is a single
// [MicrophoneSource], constructed here and handed to both providers, and a
// provider is always fully torn down before its successor starts. Two vendors
// cannot hold the microphone at the same time, cannot both be billed for the
// same speech, and cannot both be feeding transcripts into one conversation.
import 'dart:async';

import 'assemblyai_stt_service.dart';
import 'deepgram_stt_service.dart';
import 'realtime_stt.dart';

class RealtimeSttManager implements RealtimeSttProvider {
  RealtimeSttManager({
    MicrophoneSource? microphone,
    List<RealtimeSttProvider>? providers,
    this.providerStartWatchdog = const Duration(seconds: 45),
  }) : _mic = microphone ?? MicrophoneSource() {
    _providers = providers ??
        [
          DeepgramSttService(microphone: _mic),
          AssemblyAiSttService(microphone: _mic),
        ];
  }

  /// A last-resort bound on one provider's whole `start()`.
  ///
  /// Not the primary mechanism and not expected to fire: each provider
  /// already bounds its own token fetch, handshake and microphone start (see
  /// [SttTimeouts]), and the sum of those is comfortably under this. It
  /// exists because "the UI is stuck on Connecting…" is a failure mode with
  /// no floor - one un-bounded await anywhere below here, in this provider or
  /// the next one somebody writes, and the card hangs forever with no error
  /// and no failover. This guarantees the manager gets control back and moves
  /// on, whatever a provider does.
  ///
  /// 45s is deliberately above the worst legitimate sum (12s token + 2x10s
  /// handshake + 8s microphone = 40s), so a slow-but-working connection on a
  /// bad Kenyan mobile link is never cut off by the safety net.
  final Duration providerStartWatchdog;

  /// One recorder for every provider. See the file header.
  final MicrophoneSource _mic;

  /// Preference order. First is primary; the rest are fallbacks, in order.
  late final List<RealtimeSttProvider> _providers;

  final _interim = StreamController<String>.broadcast();
  final _finals = StreamController<String>.broadcast();
  final _speechStarted = StreamController<bool>.broadcast();
  final _speechFinal = StreamController<bool>.broadcast();
  final _level = StreamController<double>.broadcast();
  final _failures = StreamController<VoiceSessionException>.broadcast();
  final _reconnecting = StreamController<bool>.broadcast();

  final List<StreamSubscription> _bound = [];

  RealtimeSttProvider? _active;
  final Set<String> _tried = <String>{};
  String? _language;
  int _generation = 0;
  bool _failingOver = false;
  bool _disposed = false;

  /// True while a failover is in flight. The card shows "Reconnecting voice…"
  /// rather than an error: from the user's side nothing has gone wrong that
  /// they can act on, and the session is about to continue.
  @override
  Stream<bool> get reconnecting => _reconnecting.stream;

  /// Which vendor is currently running, for diagnostics and tests.
  String? get activeProvider => _active?.name;

  /// Every provider this manager can use, in preference order.
  List<String> get providerOrder => [for (final p in _providers) p.name];

  @override
  String get name => _active?.name ?? 'stt';

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
  bool get isConnected => _active?.isConnected ?? false;
  @override
  bool get isListening => _active?.isListening ?? false;

  /// The active provider's answer, or the primary's if nothing is running.
  ///
  /// The card asks this before a session exists, to decide whether to warn
  /// about the language - so it has to answer without one.
  @override
  ProviderLanguageConfig languageFor(String? brokaLanguage) =>
      (_active ?? _providers.first).languageFor(brokaLanguage);

  @override
  Future<void> start({String? brokaLanguage}) async {
    if (_disposed || _active != null) return;
    final generation = ++_generation;
    _language = brokaLanguage;
    _tried.clear();
    await _startFrom(0, generation);
  }

  /// Starts [index], falling forward through the list on a provider fault.
  ///
  /// Throws the LAST failure if every provider is exhausted - which is the
  /// one the user should see, since it is the most recent thing that was
  /// actually tried.
  Future<void> _startFrom(int index, int generation) async {
    VoiceSessionException? last;
    for (var i = index; i < _providers.length; i++) {
      if (_generation != generation || _disposed) return;
      final provider = _providers[i];
      if (_tried.contains(provider.name)) continue;
      _tried.add(provider.name);

      _bind(provider);
      try {
        await provider.start(brokaLanguage: _language).timeout(
          providerStartWatchdog,
          onTimeout: () {
            // Recorded here rather than in the catch below, because that
            // catch also sees exceptions a provider has already recorded -
            // and a diagnostic logged twice is a diagnostic nobody trusts to
            // mean what it says.
            final d = SttDiagnostic(
              provider: provider.name,
              stage: SttStage.handshake,
              event: 'STT_PROVIDER_START_WATCHDOG_TIMEOUT',
              info: {'watchdog_ms': providerStartWatchdog.inMilliseconds},
            );
            SttDiagnostics.record(d);
            throw VoiceSessionException(
              VoiceFailure.unknown,
              'provider start exceeded '
              '${providerStartWatchdog.inMilliseconds}ms',
              d,
            );
          },
        );
        if (_generation != generation || _disposed) {
          // Closed during the handshake. Do not leave a live session behind.
          await _unbind();
          await provider.cancel();
          return;
        }
        _active = provider;
        SttDiagnostics.record(SttDiagnostic(
          provider: provider.name,
          stage: SttStage.streaming,
          event: 'STT_PROVIDER_ACTIVE',
          info: {'attempt': i + 1},
        ));
        return;
      } on VoiceSessionException catch (e) {
        last = e;
        await _unbind();
        // Also what stops a watchdog-abandoned start: `Future.timeout` does
        // not cancel the work it gave up on, but cancel() bumps the
        // provider's own session generation, so if that start does eventually
        // get past its next await it finds itself superseded and stops.
        await provider.cancel();
        if (!e.isProviderFault) {
          // A denied or broken microphone. No vendor can help, and trying one
          // would ask the user for permission a second time.
          SttDiagnostics.record(SttDiagnostic(
            provider: provider.name,
            stage: SttStage.microphone,
            event: 'STT_NO_FAILOVER_DEVICE_FAULT',
            safeError: e.failure.name,
          ));
          rethrow;
        }
        SttDiagnostics.record(SttDiagnostic(
          provider: provider.name,
          stage: SttStage.token,
          event: 'STT_PROVIDER_FAILED_TRYING_NEXT',
          safeError: e.failure.name,
        ));
      }
    }
    throw last ??
        VoiceSessionException(
          VoiceFailure.unknown,
          'no speech provider available',
          SttDiagnostic(
              provider: 'stt',
              stage: SttStage.token,
              event: 'STT_NO_PROVIDER_AVAILABLE'),
        );
  }

  /// A provider died after it was running.
  ///
  /// Everything already transcribed is safe: the controller holds the
  /// transcript, not the provider, so a failover cannot lose the sentence the
  /// user is halfway through. No audio is replayed - a clean restart that
  /// misses a syllable is better than one that sends Zeno the same sentence
  /// twice, which is what any naive buffer replay would do here.
  Future<void> _onActiveFailure(VoiceSessionException e) async {
    if (_failingOver || _disposed) return;
    final failed = _active;
    if (failed == null) {
      // Failed during startup; _startFrom owns that path.
      return;
    }
    if (!e.isProviderFault || _remaining.isEmpty) {
      _active = null;
      await _unbind();
      await failed.cancel();
      if (!_failures.isClosed) _failures.add(e);
      return;
    }

    _failingOver = true;
    final generation = _generation;
    if (!_reconnecting.isClosed) _reconnecting.add(true);
    SttDiagnostics.record(SttDiagnostic(
      provider: failed.name,
      stage: SttStage.streaming,
      event: 'STT_FAILING_OVER_MID_SESSION',
      safeError: e.failure.name,
    ));

    _active = null;
    await _unbind();
    // Completely, before anything else starts. One microphone, one socket.
    await failed.cancel();

    try {
      if (_generation != generation || _disposed) return;
      await _startFrom(0, generation);
    } on VoiceSessionException catch (next) {
      if (!_failures.isClosed) _failures.add(next);
    } finally {
      _failingOver = false;
      if (!_reconnecting.isClosed) _reconnecting.add(false);
    }
  }

  List<RealtimeSttProvider> get _remaining =>
      [for (final p in _providers) if (!_tried.contains(p.name)) p];

  void _bind(RealtimeSttProvider p) {
    _bound.addAll([
      p.interimTranscript.listen((t) {
        if (!_interim.isClosed) _interim.add(t);
      }),
      p.finalTranscript.listen((t) {
        if (!_finals.isClosed) _finals.add(t);
      }),
      p.speechStarted.listen((v) {
        if (!_speechStarted.isClosed) _speechStarted.add(v);
      }),
      p.speechFinal.listen((v) {
        if (!_speechFinal.isClosed) _speechFinal.add(v);
      }),
      p.audioLevel.listen((v) {
        if (!_level.isClosed) _level.add(v);
      }),
      p.failures.listen((e) => unawaited(_onActiveFailure(e))),
    ]);
  }

  /// Snapshot then clear before the first await: teardown can be entered from
  /// a failover and a close at the same time.
  Future<void> _unbind() async {
    if (_bound.isEmpty) return;
    final pending = List<StreamSubscription>.of(_bound);
    _bound.clear();
    for (final s in pending) {
      await s.cancel();
    }
  }

  @override
  Future<void> stop() async {
    _generation++;
    final active = _active;
    _active = null;
    await _unbind();
    await active?.stop();
  }

  @override
  Future<void> cancel() async {
    _generation++;
    _active = null;
    await _unbind();
    // Every provider, not just the active one: a start that was abandoned
    // mid-handshake may still own a socket that nothing else will close.
    for (final p in _providers) {
      await p.cancel();
    }
    _tried.clear();
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _generation++;
    _active = null;
    await _unbind();
    for (final p in _providers) {
      await p.dispose();
    }
    await _mic.dispose();
    await _interim.close();
    await _finals.close();
    await _speechStarted.close();
    await _speechFinal.close();
    await _level.close();
    await _failures.close();
    await _reconnecting.close();
  }
}
