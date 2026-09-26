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
  })  : _onSubmit = onSubmit,
        _languageKey = languageKey,
        _service = service ?? RealtimeSttManager();

  final Future<void> Function(String text) _onSubmit;
  final String Function() _languageKey;
  final RealtimeSttProvider _service;
  final bool autoSend;

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
  double _level = 0;

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
    _open = true;
    _session++;
    _userEdited = false;
    transcript.clear();
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
      _set(VoiceSessionState.listening);
    } on VoiceSessionException catch (e) {
      _failWith(e);
    } catch (e) {
      _failWith(VoiceSessionException(VoiceFailure.unknown, '$e'));
    }
  }

  /// Close the card: stop the microphone, close the socket, drop transient
  /// state. Does NOT touch the conversation underneath.
  Future<void> close() async {
    if (!_open && _state == VoiceSessionState.idle) return;
    // Everything the UI depends on is cleared and announced BEFORE the async
    // teardown. Tapping X should remove the card on that frame - making the
    // user watch it sit there until a WebSocket finishes closing is both
    // wrong to look at and, if the socket is already dead, indefinite.
    _open = false;
    _session++;
    _autoSendTimer?.cancel();
    _autoSendTimer = null;
    _interim = '';
    _level = 0;
    transcript.clear();
    _errorMessage = null;
    _errorReference = null;
    _state = VoiceSessionState.idle;
    notifyListeners();

    await _cancelSubs();
    await _service.cancel();
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
    if (speaking) {
      _set(VoiceSessionState.speaking);
    } else if (_state == VoiceSessionState.speaking) {
      _set(VoiceSessionState.listening);
    }
  }

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
    _open = false;
    _autoSendTimer?.cancel();
    _autoSendTimer = null;
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
    _autoSendTimer?.cancel();
    unawaited(_cancelSubs());
    unawaited(_service.dispose());
    transcript.dispose();
    super.dispose();
  }

  // ── Wiring ─────────────────────────────────────────────────────────────────

  void _listen() {
    _subs.addAll([
      _service.interimTranscript.listen((text) {
        if (!_open || _userEdited) return;
        _interim = text;
        if (_state == VoiceSessionState.listening ||
            _state == VoiceSessionState.connecting) {
          _state = VoiceSessionState.listening;
        }
        notifyListeners();
      }),
      _service.finalTranscript.listen((text) {
        if (!_open) return;
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
        if (!_open) return;
        if (!hasSendableText) {
          _set(VoiceSessionState.listening);
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
