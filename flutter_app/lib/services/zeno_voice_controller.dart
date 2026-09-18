// lib/services/zeno_voice_controller.dart
//
// The state between "the user tapped the microphone" and "Zeno has a sentence
// to answer". It owns the Deepgram session, the transcript, and the session
// state machine; it owns nothing about what a transcript MEANS.
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

import 'deepgram_stt_service.dart';

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

  /// Deepgram is finalising an utterance.
  processing,

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
    DeepgramSttService? service,

    /// Direct voice mode: a completed utterance goes to Zeno without the user
    /// tapping send. False makes every turn edit-then-send.
    this.autoSend = true,
  })  : _onSubmit = onSubmit,
        _languageKey = languageKey,
        _service = service ?? DeepgramSttService();

  final Future<void> Function(String text) _onSubmit;
  final String Function() _languageKey;
  final DeepgramSttService _service;
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
  bool _open = false;
  bool _userEdited = false;
  bool _languageUnsupported = false;
  double _level = 0;

  VoiceSessionState get state => _state;

  /// Live, still-being-revised text from Deepgram.
  String get interim => _interim;

  String? get errorMessage => _errorMessage;

  /// Whether the card should be mounted at all.
  bool get isOpen => _open;

  /// 0..1 microphone loudness, for the waveform.
  double get level => _level;

  /// True when the user's BROKA language is one Deepgram cannot transcribe,
  /// so this session is running on English (see [DeepgramLanguage]). The card
  /// says so rather than letting a user conclude BROKA's Dholuo is broken.
  bool get languageUnsupported => _languageUnsupported;

  bool get hasSendableText => transcript.text.trim().isNotEmpty;

  /// Open the card and start listening.
  ///
  /// Guarded: a second tap while connecting is ignored rather than opening a
  /// second socket (brief §26).
  Future<void> open() async {
    if (_open) return;
    _open = true;
    _userEdited = false;
    _errorMessage = null;
    transcript.clear();
    _interim = '';
    _set(VoiceSessionState.connecting);

    final language = _languageKey();
    _languageUnsupported =
        !DeepgramLanguage.forBrokaLanguage(language).supported;

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
    _autoSendTimer?.cancel();
    _autoSendTimer = null;
    _interim = '';
    _level = 0;
    transcript.clear();
    _errorMessage = null;
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
    _interim = '';
    _level = 0;
    _set(VoiceSessionState.error);
    unawaited(_service.cancel());
  }

  /// One honest sentence per failure, each of which ends with the user still
  /// having a working text composer.
  static String _messageFor(VoiceFailure failure) {
    switch (failure) {
      case VoiceFailure.microphoneDenied:
        return 'Microphone access is needed to talk to Zeno.';
      case VoiceFailure.notConfigured:
        return "Voice isn't available right now. You can still type to Zeno.";
      case VoiceFailure.tokenUnavailable:
      case VoiceFailure.connectionFailed:
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
