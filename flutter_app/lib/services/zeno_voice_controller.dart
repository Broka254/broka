// lib/services/zeno_voice_controller.dart
//
// The state between "the user tapped the microphone" and "Zeno has a sentence
// to answer". It owns the Deepgram session, the transcript, and the session
// state machine; it owns nothing about what a transcript MEANS.
//
// It is also why the vendor is invisible from here up. This file holds a
// [RealtimeSttProvider]; whether that is Deepgram, AssemblyAI after a
// failover, or something not written yet, is RealtimeSttManager's business.
//
// That split is what lets one card work over both ZenoScreen and
// NegotiateScreen. The screen passes an [onSubmit] callback - ZenoScreen's
// hands the text to _send(), NegotiateScreen's hands it to its own _send() -
// and neither screen contains a line of WebSocket or audio code. A future
// direct-chat screen mounts the same overlay with a third callback.
//
// It is a ChangeNotifier rather than screen state on purpose: the interim
// transcript updates several times a second while someone speaks, and calling
// setState on ZenoScreen at that rate would relayout the whole conversation,
// the constellation field and every listing card for each syllable.
import 'dart:async';

import 'package:flutter/widgets.dart';

import 'realtime_stt.dart';
import 'realtime_stt_manager.dart';

/// Where a voice session is. One enum rather than a handful of booleans,
/// because `listening && !processing && !speaking` is a state machine written
/// in a way that permits states that should not exist.
enum VoiceSessionState {
  /// Card closed. Nothing is connected, no microphone is open.
  idle,

  /// Fetching a token and opening the socket.
  connecting,

  /// Microphone live, waiting for or receiving speech.
  listening,

  /// The provider is finalising an utterance.
  processing,

  /// The speech session died and a replacement is being established. Not an
  /// error: the transcript survives, the microphone comes back, and the user
  /// is told only that it is reconnecting.
  reconnecting,

  /// There is final text in the box and it has not been sent.
  readyToSend,

  /// The screen's own send path is running.
  sendingToZeno,

  /// Zeno is talking back, through the existing BrokaTts.
  speaking,

  /// Something failed. [ZenoVoiceController.errorMessage] says what.
  error,
}

class ZenoVoiceController extends ChangeNotifier {
  ZenoVoiceController({
    required Future<void> Function(String text) onSubmit,
    required String Function() languageKey,
    RealtimeSttProvider? service,

    /// Direct voice mode: a completed utterance goes to Zeno without the user
    /// tapping send. False makes every turn edit-then-send.
    this.autoSend = true,
    this.stallAfter = const Duration(seconds: 4),
  })  : _onSubmit = onSubmit,
        _languageKey = languageKey,
        _service = service ?? RealtimeSttManager();

  final Future<void> Function(String text) _onSubmit;
  final String Function() _languageKey;
  final RealtimeSttProvider _service;
  final bool autoSend;

  /// How long the microphone may go without a single frame, while it is
  /// meant to be open, before it counts as stalled. See [_heardAudio].
  final Duration stallAfter;

  /// The editable transcript. A TextEditingController rather than a String so
  /// the card's field is a real text field - brief §35: the user must never be
  /// stuck with a bad transcription.
  final TextEditingController transcript = TextEditingController();

  final List<StreamSubscription> _subs = [];
  Timer? _autoSendTimer;

  VoiceSessionState _state = VoiceSessionState.idle;
  String _interim = '';
  String? _errorMessage;
  String? _errorReference;
  bool _open = false;
  // Bumped by every open() and close(), so an async step can tell whether
  // the card it started in is still the card that is showing.
  int _session = 0;
  bool _userEdited = false;
  bool _languageUnsupported = false;

  /// The last close()'s teardown, while it runs. See open().
  Future<void>? _teardown;
  double _level = 0;

  /// Running for [echoTail] after Zeno stops speaking. See [_hearingZeno].
  /// A Timer rather than a timestamp, so it runs on the same clock as the
  /// auto-send timer beside it.
  Timer? _echoTimer;

  /// How long after Zeno stops that what the microphone hears is still
  /// taken to be Zeno: the provider's final text for the last words it
  /// heard arrives a few hundred milliseconds after the audio.
  static const echoTail = Duration(milliseconds: 700);

  /// Whether the screen says Zeno is talking - kept apart from [_state],
  /// which a microphone restart passes through connecting.
  bool _zenoSpeaking = false;

  // The stall watch. Armed by the first frame of audio (a fake provider in
  // a test that never sends any is never watched), checked every half of
  // [stallAfter]: a check that finds no frame since the last one counts,
  // a frame resets the count.
  Timer? _stallWatch;
  bool _audioSinceCheck = false;
  int _silentChecks = 0;
  int _stallRestarts = 0;

  /// Restarts in a row that brought no audio back before the microphone is
  /// reported as stopped rather than restarted again.
  static const maxStallRestarts = 2;

  /// The session holding the microphone, if any.
  ///
  /// One at a time: Zeno's assistant session stays open across screens
  /// (zeno_session.dart), so the negotiation room's voice card or the
  /// Buying Agent's can now be opened while it listens - and two recorders
  /// on one device is whichever started second winning it, the other's
  /// session live and deaf. The newest open() takes it; the one before is
  /// closed, and its owner sees that like any other close.
  static ZenoVoiceController? _holder;

  /// Closes whichever session holds the microphone - for code that records
  /// without one (the negotiation room's voice notes).
  static Future<void> releaseMicrophone() async {
    final holder = _holder;
    _holder = null;
    if (holder != null && holder._open) await holder.close();
  }

  VoiceSessionState get state => _state;

  /// Live, still-being-revised text from Deepgram.
  String get interim => _interim;

  String? get errorMessage => _errorMessage;

  /// What failed, as a short code - "ASSEMBLYAI_HANDSHAKE_FAILED" (the
  /// provider answered and refused) against "DEEPGRAM_NETWORK_UNREACHABLE" -
  /// shown small under the error. Diagnostics are printed in debug builds
  /// only, so on a release phone this is the one trace of why.
  String? get errorReference => _errorReference;

  /// Whether the card should be mounted at all.
  bool get isOpen => _open;

  /// 0..1 microphone loudness, for the waveform.
  double get level => _level;

  /// True when the user's BROKA language is one the speech provider cannot
  /// transcribe, so this session is running on English. The card says so
  /// rather than letting a user conclude BROKA's Dholuo is broken.
  bool get languageUnsupported => _languageUnsupported;

  bool get hasSendableText => transcript.text.trim().isNotEmpty;

  /// Open the card and start listening.
  ///
  /// Guarded: a second tap while connecting or listening is ignored rather
  /// than opening a second socket (brief §26). The one exception is a card
  /// sitting on an error: there the microphone button is the obvious way to
  /// try again, and it used to do nothing at all - the only way out was to
  /// close the card with X and reopen it.
  Future<void> open() async {
    if (_open) {
      if (_state == VoiceSessionState.error) await _retryAfterError();
      return;
    }
    final previous = _holder;
    _holder = this;
    if (previous != null && !identical(previous, this) && previous._open) {
      unawaited(previous.close());
    }
    _open = true;
    final session = ++_session;
    _userEdited = false;
    _zenoSpeaking = false;
    _stallRestarts = 0;
    transcript.clear();
    // Opened again before the last close has finished - the pill's "tap to
    // talk" a moment after its microphone was stopped. The provider ignores
    // a start while its socket is still closing, and this card would have
    // said "Listening" over a microphone that never opened. The close is
    // bounded (closeSocketWithoutHanging), so this wait is too.
    final teardown = _teardown;
    if (teardown != null) {
      _set(VoiceSessionState.connecting);
      await teardown;
      if (!_open || session != _session) return;
    }
    await _start();
  }

  /// Start a fresh session in the card that is already open.
  ///
  /// Leaves `error` synchronously, before the first await, so a second tap
  /// during the teardown is ignored like any other tap while connecting.
  /// Whatever was already transcribed stays in the box - the user can still
  /// send or edit it - exactly as it does across a provider failover.
  Future<void> _retryAfterError() async {
    final session = _session;
    _errorMessage = null;
    _errorReference = null;
    _stallRestarts = 0;
    _set(VoiceSessionState.connecting);
    await _cancelSubs();
    await _service.cancel();
    // Closed with X during the teardown - or closed and reopened, in which
    // case that open() has started its own session and this one must not.
    if (!_open || session != _session) return;
    await _start();
  }

  Future<void> _start() async {
    _errorMessage = null;
    _errorReference = null;
    _interim = '';
    _set(VoiceSessionState.connecting);

    final language = _languageKey();
    _languageUnsupported = !_service.languageFor(language).supported;

    _listen();

    try {
      await _service.start(brokaLanguage: language);
      // The user may have closed the card during the handshake.
      if (!_open) {
        await _service.cancel();
        return;
      }
      // Restarted under Zeno's voice (a stalled microphone, below): what
      // it hears is still Zeno until the screen says otherwise.
      _set(_zenoSpeaking ? VoiceSessionState.speaking : VoiceSessionState.listening);
    } on VoiceSessionException catch (e) {
      _failWith(e);
    } catch (e) {
      _failWith(VoiceSessionException(VoiceFailure.unknown, '$e'));
    }
  }

  /// Close the card: stop the microphone, close the socket, drop transient
  /// state. Does NOT touch the conversation underneath.
  Future<void> close() async {
    if (identical(_holder, this)) _holder = null;
    if (!_open && _state == VoiceSessionState.idle) return;
    // Everything the UI depends on is cleared and announced BEFORE the async
    // teardown. Tapping X should remove the card on that frame - making the
    // user watch it sit there until a WebSocket finishes closing is both
    // wrong to look at and, if the socket is already dead, indefinite.
    _open = false;
    _session++;
    _autoSendTimer?.cancel();
    _autoSendTimer = null;
    _echoTimer?.cancel();
    _echoTimer = null;
    _stopStallWatch();
    _zenoSpeaking = false;
    _interim = '';
    _level = 0;
    transcript.clear();
    _errorMessage = null;
    _errorReference = null;
    _state = VoiceSessionState.idle;
    notifyListeners();

    final teardown = () async {
      await _cancelSubs();
      await _service.cancel();
    }();
    _teardown = teardown;
    try {
      await teardown;
    } finally {
      if (identical(_teardown, teardown)) _teardown = null;
    }
  }

  /// Send whatever is in the transcript box through the screen's own path.
  Future<void> submit() async {
    final text = transcript.text.trim();
    if (text.isEmpty) return;
    if (_state == VoiceSessionState.sendingToZeno) return;

    _autoSendTimer?.cancel();
    transcript.clear();
    _interim = '';
    _userEdited = false;
    _set(VoiceSessionState.sendingToZeno);

    try {
      await _onSubmit(text);
    } catch (_) {
      // The screen owns its own error surface for a failed send - it has a
      // conversation to put the message in, which this card does not.
    }
    if (!_open) return;
    // If the screen started TTS it has already called setZenoSpeaking(true),
    // and stomping that here would flip the card back to "listening" while
    // Zeno is mid-sentence.
    if (_state == VoiceSessionState.sendingToZeno) {
      _set(VoiceSessionState.listening);
    }
  }

  /// Called by the screen around its existing BrokaTts playback, so the card
  /// can show "Zeno is speaking..." without this file knowing what TTS is.
  void setZenoSpeaking(bool speaking) {
    if (!_open) return;
    _zenoSpeaking = speaking;
    if (speaking) {
      _autoSendTimer?.cancel();
      _interim = '';
      _set(VoiceSessionState.speaking);
    } else if (_state == VoiceSessionState.speaking) {
      _echoTimer?.cancel();
      _echoTimer = Timer(echoTail, () => _echoTimer = null);
      _set(VoiceSessionState.listening);
    }
  }

  /// Whether the microphone is hearing Zeno's own voice.
  ///
  /// The session stays open while Zeno talks, through the phone's speaker,
  /// into the same microphone. Everything transcribed then used to be taken
  /// as the user's: Zeno's reply landed in the box and, in direct voice
  /// mode, was sent straight back to Zeno as the user's next turn. While
  /// Zeno speaks - and for [echoTail] after - what is heard is dropped. To
  /// cut in, the user stops Zeno (voice mode's stop button, or tapping it).
  bool get _hearingZeno => _state == VoiceSessionState.speaking || _echoTimer != null;

  /// The user touched the transcript field. Stops the auto-send countdown:
  /// someone correcting a transcription must not have it sent out from under
  /// them mid-edit.
  void markEdited() {
    _userEdited = true;
    _autoSendTimer?.cancel();
    _autoSendTimer = null;
    if (_state == VoiceSessionState.listening ||
        _state == VoiceSessionState.processing) {
      _set(VoiceSessionState.readyToSend);
    } else {
      notifyListeners();
    }
  }

  /// Stop everything because the widget that hosts this card is going away -
  /// a popped screen, a rebuilt tree, the app leaving the foreground.
  ///
  /// Deliberately does NOT notify: listeners are being torn down, and telling
  /// them to rebuild mid-disposal is an error. It is also deliberately
  /// synchronous up to the point where the microphone and the keep-alive
  /// timer are released - a voice session must not outlive the tree that
  /// opened it, and an awaited teardown would let it (brief §25).
  void stopForDispose() {
    if (identical(_holder, this)) _holder = null;
    _open = false;
    _autoSendTimer?.cancel();
    _autoSendTimer = null;
    _echoTimer?.cancel();
    _echoTimer = null;
    _stopStallWatch();
    _state = VoiceSessionState.idle;
    _interim = '';
    _level = 0;
    unawaited(_cancelSubs());
    // cancel()'s first statements - the timer and the listening flag - run
    // before its first await, so the timer is dead by the time this returns.
    unawaited(_service.cancel());
  }

  @override
  void dispose() {
    if (identical(_holder, this)) _holder = null;
    _autoSendTimer?.cancel();
    _echoTimer?.cancel();
    _stopStallWatch();
    unawaited(_cancelSubs());
    unawaited(_service.dispose());
    transcript.dispose();
    super.dispose();
  }

  // ── Wiring ─────────────────────────────────────────────────────────────────

  void _listen() {
    _subs.addAll([
      _service.interimTranscript.listen((text) {
        if (!_open || _userEdited || _hearingZeno) return;
        _interim = text;
        if (_state == VoiceSessionState.listening ||
            _state == VoiceSessionState.connecting) {
          _state = VoiceSessionState.listening;
        }
        notifyListeners();
      }),
      _service.finalTranscript.listen((text) {
        if (!_open || _hearingZeno) return;
        _interim = '';
        if (_userEdited) {
          // Respect the edit, but do not lose what was said next.
          transcript.text = '${transcript.text.trim()} $text'.trim();
        } else {
          final existing = transcript.text.trim();
          transcript.text = existing.isEmpty ? text : '$existing $text';
        }
        transcript.selection =
            TextSelection.collapsed(offset: transcript.text.length);
        _set(VoiceSessionState.processing);
      }),
      _service.speechFinal.listen((_) {
        if (!_open || _hearingZeno) return;
        if (!hasSendableText) {
          // An UtteranceEnd for words that have already gone to Zeno: the
          // turn is still on its way, not back to listening.
          if (_state != VoiceSessionState.sendingToZeno) _set(VoiceSessionState.listening);
          return;
        }
        _set(VoiceSessionState.readyToSend);
        if (autoSend && !_userEdited) _scheduleAutoSend();
      }),
      _service.speechStarted.listen((_) {
        if (!_open) return;
        if (_state == VoiceSessionState.listening) notifyListeners();
      }),
      _service.audioLevel.listen((v) {
        if (!_open) return;
        _level = v;
        _heardAudio();
        notifyListeners();
      }),
      _service.reconnecting.listen((busy) {
        if (!_open) return;
        if (busy) {
          _autoSendTimer?.cancel();
          _interim = '';
          _set(VoiceSessionState.reconnecting);
        } else if (_state == VoiceSessionState.reconnecting) {
          // Whatever was already transcribed is still in `transcript` - the
          // text lives here, not in the provider, so a vendor swap costs the
          // user nothing they had already said.
          _set(hasSendableText
              ? VoiceSessionState.readyToSend
              : VoiceSessionState.listening);
        }
      }),
      _service.failures.listen(_failWith),
    ]);
  }

  // ── A microphone that stops without saying so ──────────────────────────────
  //
  // The provider's socket stays open on its own KeepAlive whether or not
  // audio reaches it, so a recorder the platform pauses (another app's
  // audio focus, an iOS session deactivated under it) used to look exactly
  // like a quiet user: "Listening", and nothing the user said was heard,
  // for as long as the session lasted. Audio arrives every few dozen
  // milliseconds while the microphone runs - silence is still frames - so
  // [stallAfter] without one is a stopped microphone, and it is opened
  // again. What was already transcribed stays in the box.

  void _heardAudio() {
    _audioSinceCheck = true;
    if (_stallWatch == null) _startStallWatch();
  }

  void _startStallWatch() {
    _stallWatch?.cancel();
    _silentChecks = 0;
    final every = Duration(microseconds: stallAfter.inMicroseconds ~/ 2);
    _stallWatch = Timer.periodic(every, (_) => _checkForStall());
  }

  void _stopStallWatch() {
    _stallWatch?.cancel();
    _stallWatch = null;
    _audioSinceCheck = false;
    _silentChecks = 0;
  }

  /// States in which the microphone is streaming. Connecting, reconnecting
  /// and an error are the provider's own business and say so on screen.
  bool get _micShouldStream => switch (_state) {
        VoiceSessionState.listening ||
        VoiceSessionState.processing ||
        VoiceSessionState.readyToSend ||
        VoiceSessionState.sendingToZeno ||
        VoiceSessionState.speaking =>
          true,
        _ => false,
      };

  void _checkForStall() {
    if (!_open) {
      _stopStallWatch();
      return;
    }
    if (_audioSinceCheck || !_micShouldStream) {
      if (_audioSinceCheck) _stallRestarts = 0;
      _audioSinceCheck = false;
      _silentChecks = 0;
      return;
    }
    if (++_silentChecks < 2) return;
    _stopStallWatch();
    if (_stallRestarts >= maxStallRestarts) {
      // Opened again and again, and still nothing: say so rather than
      // pretend to listen.
      _failWith(VoiceSessionException(
        VoiceFailure.microphoneStartFailed,
        'microphone stopped delivering audio',
        SttDiagnostic(
            provider: 'microphone', stage: SttStage.streaming, event: 'MICROPHONE_STALLED'),
      ));
      return;
    }
    _stallRestarts++;
    unawaited(_restartAfterStall());
  }

  Future<void> _restartAfterStall() async {
    final session = _session;
    SttDiagnostics.record(SttDiagnostic(
      provider: 'microphone',
      stage: SttStage.streaming,
      event: 'MICROPHONE_STALLED_RESTARTING',
      info: {'attempt': _stallRestarts},
    ));
    _autoSendTimer?.cancel();
    _interim = '';
    _level = 0;
    _set(VoiceSessionState.reconnecting);
    await _cancelSubs();
    await _service.cancel();
    if (!_open || session != _session) return;
    await _start();
    // Watched from the start this time: a microphone that comes back with
    // no audio at all is the same stall.
    if (_open && session == _session && _state != VoiceSessionState.error) _startStallWatch();
  }

  /// A short grace period before a completed utterance is sent.
  ///
  /// Deepgram's endpointing fires on 300ms of silence, which is shorter than
  /// the pause someone takes mid-thought. Sending the instant speech_final
  /// arrives would cut people off halfway through a request; this gives them
  /// a beat to keep talking, and any new final text cancels and restarts it.
  void _scheduleAutoSend() {
    _autoSendTimer?.cancel();
    _autoSendTimer = Timer(const Duration(milliseconds: 900), () {
      if (!_open || _userEdited) return;
      if (_state != VoiceSessionState.readyToSend) return;
      unawaited(submit());
    });
  }

  /// Snapshot then clear, before the first await.
  ///
  /// Two teardown paths can run at once - the overlay unmounting and the
  /// screen disposing the controller - and the previous version iterated
  /// `_subs` across an await while the other call cleared it, which threw a
  /// ConcurrentModificationError out of an unawaited future. Clearing first
  /// also makes this idempotent: the second caller finds nothing to do.
  Future<void> _cancelSubs() async {
    if (_subs.isEmpty) return;
    final pending = List<StreamSubscription>.of(_subs);
    _subs.clear();
    for (final s in pending) {
      await s.cancel();
    }
  }

  void _failWith(VoiceSessionException e) {
    _stopStallWatch();
    _errorMessage = _messageFor(e.failure);
    _errorReference = referenceFor(e);
    _interim = '';
    _level = 0;
    _set(VoiceSessionState.error);
    unawaited(_service.cancel());
  }

  /// The reference shown under an error: the failing stage's diagnostic
  /// event, plus the close code when the provider hung up on a live session.
  @visibleForTesting
  static String? referenceFor(VoiceSessionException e) {
    final d = e.diagnostic;
    if (d == null) return null;
    return d.closeCode == null ? d.event : '${d.event} · close ${d.closeCode}';
  }

  /// One honest sentence per failure, each of which ends with the user still
  /// having a working text composer.
  ///
  /// Every one of these used to be the same sentence. That was the single
  /// worst thing about the original: a user could not tell a denied
  /// microphone from an unreachable server, and neither could anyone reading
  /// their screenshot. These say what happened without leaking a stack trace
  /// or a server detail, and each one leaves the user somewhere to go.
  static String _messageFor(VoiceFailure failure) {
    switch (failure) {
      case VoiceFailure.microphoneDenied:
        return 'Microphone access is needed to talk to Zeno. '
            'You can still type.';
      case VoiceFailure.microphoneStartFailed:
        return "Your microphone didn't start. Close anything else using it, "
            'or type to Zeno.';
      case VoiceFailure.notConfigured:
        return "Voice isn't switched on yet. You can still type to Zeno.";
      case VoiceFailure.tokenUnavailable:
        return "Couldn't start a voice session. Check your connection, "
            'or type to Zeno.';
      case VoiceFailure.handshakeFailed:
      case VoiceFailure.socketClosed:
        return "Voice couldn't connect. Check your connection, "
            'or type to Zeno.';
      case VoiceFailure.providerError:
      case VoiceFailure.unknown:
        return "Voice isn't available right now. You can still type to Zeno.";
    }
  }

  void _set(VoiceSessionState next) {
    if (_state == next) {
      notifyListeners();
      return;
    }
    _state = next;
    notifyListeners();
  }
}
