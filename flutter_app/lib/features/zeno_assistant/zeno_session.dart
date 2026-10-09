// Zeno, staying with the user from screen to screen.
//
// Voice mode used to belong to the Zeno tab. "Open my dashboard" opened the
// dashboard and, because the microphone must not outlive the screen that
// opened it, ended the conversation: on the dashboard, Zeno was gone, and
// "now search for a PS5" meant going back to the Zeno tab to ask again. A
// phone's assistant doesn't work like that - it opens the app and is still
// there.
//
// So the conversation lives here, above the Navigator (ZenoSessionHost in
// MaterialApp.builder), not in any one screen:
//
//   expanded   the full-screen voice view (zeno_live_overlay.dart);
//   docked     a pill over whatever screen is showing, still listening -
//              what opening a screen does to it;
//   closed     nothing listening, nothing on screen.
//
// Its turns are the Zeno tab's conversation: while the tab is open
// (ZenoSessionChat) they appear there as they happen, and otherwise they
// are added to the saved conversation (ZenoChatStore) to be there when it
// opens.
//
// Where the microphone goes matters more now that it outlives screens:
//   - one voice session at a time (ZenoVoiceController's arbiter): the
//     negotiation room's voice card or a voice note takes it, and Zeno's
//     pill shows it has stopped listening rather than listen deaf;
//   - a call ends the session before it rings (the call needs the
//     microphone), and so does signing out;
//   - the app leaving the foreground ends it (ZenoSessionHost): nothing
//     listens from the background;
//   - a silence is not the end of the conversation (2026-10-09). The
//     microphone used to stop after a minute with nothing said, without a
//     word: the voice view folded away and whatever the user said next was
//     never heard. Now Zeno checks in - "are you still there?", in a few
//     different ways (zeno_check_ins.dart) - and only after two of those,
//     says it is stepping back and stops the microphone (the speech
//     provider bills by the minute, whether anyone is talking or not). The
//     pill then says "Tap to talk".
//
// Words said while Zeno is still working out its last answer are kept and
// sent after it, not dropped (they used to be: send() returned early).
//
// It also runs Zeno's tour of BROKA (zeno_tour.dart), offered to a new
// account the first time Home is in front, and tells the floating orb
// (zeno_launcher.dart) which screen is showing.
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter/scheduler.dart';

import '../../core/utils/result.dart';
import '../../services/api_service.dart';
import '../../services/broka_tts.dart';
import '../../services/realtime_stt.dart';
import '../../services/zeno_chat_store.dart';
import '../../services/zeno_voice_controller.dart';
import 'data/zeno_assistant_repository.dart';
import 'domain/zeno_action.dart';
import 'presentation/zeno_action_card.dart' show ZenoActionPhase;
import 'zeno_action_runner.dart';
import 'zeno_check_ins.dart';
import 'zeno_tour.dart';

enum ZenoSessionView { closed, expanded, docked }

/// The Zeno tab's conversation, as the session sees it while the tab is
/// open.
abstract interface class ZenoSessionChat {
  /// Whether the chat is the screen in front.
  bool get isFrontmost;

  /// The conversation so far, newest last, for the next turn's context.
  List<Map<String, String>> recentHistory(int count);

  /// The user said [text] to the session.
  void sessionHeard(String text);

  /// Zeno answered it - with, sometimes, replies to tap and a link
  /// (the escrow walkthrough's).
  void sessionAnswered(String reply, ZenoAction? action,
      {List<String> suggestions = const [], ZenoLink? link});

  /// No answer came.
  void sessionFailed(String text);

  /// Back to typing, in the chat.
  void focusComposer();
}

/// Which screen is on top, and what was just opened. The session needs a
/// NavigatorState to act on and has no route context to find one from;
/// this observer is attached to the app's Navigator and hands it over.
class ZenoRouteWatch extends NavigatorObserver {
  ZenoRouteWatch(this._onPush, [this._onTop]);

  final void Function(Route<dynamic> route) _onPush;

  /// The screen in front changed, any way at all.
  final VoidCallback? _onTop;

  Route<dynamic>? top;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    top = route;
    _onPush(route);
    _onTop?.call();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (identical(route, top)) top = previousRoute;
    _onTop?.call();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (identical(route, top)) top = previousRoute;
    _onTop?.call();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (identical(oldRoute, top)) top = newRoute;
    if (newRoute != null) _onPush(newRoute);
    _onTop?.call();
  }
}

class ZenoSession extends ChangeNotifier implements ZenoTourHost {
  ZenoSession({
    ZenoAssistantRepository? repository,
    BrokaTts? tts,
    ZenoCheckIns? checkIns,
    @visibleForTesting this.voiceService,
  })  : _repository = repository ?? zenoAssistantRepository,
        _tts = tts ?? BrokaTts.instance,
        _checkIns = checkIns ?? ZenoCheckIns() {
    routes = ZenoRouteWatch(_onRoutePushed, _onTopChanged);
  }

  /// Attach to the app's Navigator (MaterialApp.navigatorObservers).
  late final ZenoRouteWatch routes;

  /// The speech provider for a session started without one (the floating
  /// orb's). Tests pass a fake; the app leaves it null for the real one.
  final RealtimeSttProvider Function()? voiceService;

  /// Zeno showing the user around (zeno_tour.dart).
  late final ZenoTour tour = ZenoTour(this);

  /// Goes up each time the screen in front changes - for what is drawn
  /// over it (the floating orb), told after the frame that changed it.
  final ValueNotifier<int> screenChanged = ValueNotifier(0);

  final ZenoAssistantRepository _repository;
  final BrokaTts _tts;
  final ZenoCheckIns _checkIns;

  /// Where voice mode grows from when the Zeno tab's microphone opens it.
  static const fromMic = Alignment(0.82, 0.9);

  // A silence, and what Zeno does about it - see the header. Full screen,
  // the user is talking to Zeno and a pause is a pause: it checks in,
  // asks again, then rests. Docked over a screen it opened, the user is
  // reading, not ignoring it: once, later, then it rests.
  static const checkInAfter = Duration(seconds: 14);
  static const checkInAgainAfter = Duration(seconds: 18);
  static const restAfter = Duration(seconds: 16);
  static const browsingCheckInAfter = Duration(seconds: 45);
  static const browsingRestAfter = Duration(seconds: 40);

  /// Screens the tour is never offered over: Home is the first route,
  /// and these can be first too.
  static const _noTourOn = {'/splash', '/auth', '/voip-call'};

  /// Routes the session must not survive: a call needs the microphone,
  /// and signing out or starting over ends the account's conversation.
  static const _endsOn = {'/voip-call', '/auth', '/splash'};

  static ZenoSession? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<ZenoSessionScope>()?.session;

  ZenoSessionView _view = ZenoSessionView.closed;
  ZenoVoiceController? _voice;
  ZenoSessionChat? _chat;

  /// The context sent with each turn when the chat isn't open to ask.
  final List<Map<String, String>> _history = [];
  Future<void>? _seeding;
  Future<void> _storeWrites = Future.value();
  Future<void>? _closing;

  // Bumped by start() and end(): a reply for a session that has ended is
  // recorded, but not spoken or acted on.
  int _epoch = 0;

  String? _heard;
  String? _reply;
  bool _thinking = false;
  ZenoAction? _action;
  ZenoActionPhase? _phase;
  int _burst = 0;
  bool _muted = false;
  bool _typing = false;
  bool _pillAtTop = false;
  bool _guideFolded = false;
  final Set<int> _guideVisited = {};
  Alignment _origin = fromMic;
  bool _speakingSelf = false;
  bool _wasListening = false;

  /// Check-ins since the user last said anything. See _onQuiet.
  int _nudges = 0;

  /// Zeno's last real answer this session (not a check-in), for what a
  /// check-in follows.
  String? _answered;

  /// Said while Zeno was still answering: sent next.
  String? _queued;
  Timer? _queueTimer;

  bool _tourOfferScheduled = false;
  Timer? _tourOffer;
  bool _screenNotifyScheduled = false;
  bool _disposed = false;

  /// The screen Zeno opened last. When it is still the one in front, the
  /// next screen Zeno opens replaces it - see ZenoActionRunner.runOn.
  Route<dynamic>? _opened;

  Timer? _beat;
  Timer? _quiet;
  Timer? _speakCap;

  ZenoSessionView get view => _view;
  bool get isActive => _view != ZenoSessionView.closed;
  bool get expanded => _view == ZenoSessionView.expanded;
  bool get docked => _view == ZenoSessionView.docked;
  ZenoVoiceController? get voice => _voice;
  bool get listening => _voice?.isOpen ?? false;
  String? get heard => _heard;
  String? get reply => _reply;
  bool get thinking => _thinking;
  ZenoAction? get action => _action;
  ZenoActionPhase? get phase => _phase;
  int get burst => _burst;
  bool get muted => _muted;
  bool get typing => _typing;
  bool get pillAtTop => _pillAtTop;
  bool get guideFolded => _guideFolded;
  Set<int> get guideVisited => Set.unmodifiable(_guideVisited);
  Alignment get origin => _origin;

  /// Where the pill is, for the voice view to shrink into and grow from.
  Alignment get dockOrigin => Alignment(0, _pillAtTop ? -0.86 : 0.84);

  // ── The chat ────────────────────────────────────────────────────────────

  void attachChat(ZenoSessionChat chat) => _chat = chat;

  void detachChat(ZenoSessionChat chat) {
    if (!identical(_chat, chat)) return;
    // The chat was the conversation's record; carry on from what it had.
    _history
      ..clear()
      ..addAll(chat.recentHistory(40));
    _chat = null;
  }

  // ── Opening, docking, closing ─────────────────────────────────────────────

  /// Opens voice mode, or brings it back if it is docked. [docked] opens it
  /// straight into the pill - the tour's demo, asked over Home.
  Future<void> start({
    RealtimeSttProvider? service,
    Alignment from = fromMic,
    bool? muted,
    bool docked = false,
  }) async {
    if (isActive) return docked ? resumeMic() : expand(from: from);
    _epoch++;
    _heard = null;
    _reply = null;
    _answered = null;
    _queued = null;
    _nudges = 0;
    _action = null;
    _phase = null;
    _thinking = false;
    _typing = false;
    _opened = null;
    _guideVisited.clear();
    if (muted != null) _muted = muted;
    _origin = docked ? dockOrigin : from;
    _view = docked ? ZenoSessionView.docked : ZenoSessionView.expanded;
    _history.clear();
    final chat = _chat;
    _seeding = chat == null ? _seedFromStore() : null;
    if (chat != null) _history.addAll(chat.recentHistory(40));
    final voice = _voice ??= _makeVoice(service);
    unawaited(_tts.init());
    _tts.playing.addListener(_onTtsPlaying);
    notifyListeners();
    await voice.open();
    _touch();
  }

  ZenoVoiceController _makeVoice(RealtimeSttProvider? service) => ZenoVoiceController(
        onSubmit: send,
        languageKey: () => ApiService.currentUserLanguage,
        service: service ?? voiceService?.call(),
      )..addListener(_onVoice);

  Future<void> _seedFromStore() async {
    final saved = await ZenoChatStore.load('assistant');
    if (saved == null) return;
    final h = saved.history;
    _history.insertAll(0, h.length > 40 ? h.sublist(h.length - 40) : h);
  }

  /// Full screen again, listening.
  Future<void> expand({Alignment? from}) async {
    if (!isActive) return;
    _origin = from ?? dockOrigin;
    _view = ZenoSessionView.expanded;
    _typing = false;
    _nudges = 0;
    notifyListeners();
    final voice = _voice;
    if (voice != null && !voice.isOpen) await voice.open();
    _touch();
  }

  /// Down to the pill, still listening.
  void dock() {
    if (_view != ZenoSessionView.expanded) return;
    _origin = dockOrigin;
    _view = ZenoSessionView.docked;
    notifyListeners();
    // Over a screen, a silence is someone reading: the longer wait.
    _touch();
  }

  /// Ends the session: the microphone closes and Zeno leaves the screen.
  void end() {
    if (!isActive) return;
    _epoch++;
    if (_view == ZenoSessionView.docked) _origin = dockOrigin;
    _view = ZenoSessionView.closed;
    _typing = false;
    _thinking = false;
    _queued = null;
    _cancelTimers();
    _tts.playing.removeListener(_onTtsPlaying);
    if (_speakingSelf || _tts.isSpeaking) unawaited(_tts.stop());
    final voice = _voice;
    if (voice != null && voice.isOpen) _closing = voice.close();
    notifyListeners();
  }

  /// The pill's microphone button: stop listening, the session stays.
  void pauseMic() {
    final voice = _voice;
    _quiet?.cancel();
    if (voice != null && voice.isOpen) _closing = voice.close();
    notifyListeners();
  }

  /// ...and start again.
  Future<void> resumeMic() async {
    if (!isActive) return;
    _typing = false;
    _nudges = 0;
    notifyListeners();
    await _voice?.open();
    _touch();
  }

  /// Voice mode's keyboard button. In the Zeno tab that is the tab's own
  /// composer; anywhere else, the pill becomes a text field. Either way the
  /// microphone stops - it would take what the user says while typing.
  void typeInstead() {
    final chat = _chat;
    if (chat != null && chat.isFrontmost) {
      end();
      chat.focusComposer();
      return;
    }
    _typing = true;
    if (_view == ZenoSessionView.expanded) {
      _origin = dockOrigin;
      _view = ZenoSessionView.docked;
    }
    pauseMic();
  }

  void closeTyping() {
    _typing = false;
    notifyListeners();
  }

  /// Moves the pill to the top of the screen or back to the bottom.
  void movePill({required bool top}) {
    if (_pillAtTop == top) return;
    _pillAtTop = top;
    notifyListeners();
  }

  void foldGuide(bool folded) {
    if (_guideFolded == folded) return;
    _guideFolded = folded;
    notifyListeners();
  }

  void toggleMute() {
    _muted = !_muted;
    if (_muted) interrupt();
    notifyListeners();
  }

  /// Stop Zeno mid-sentence and listen.
  void interrupt() {
    unawaited(_tts.stop());
    _voice?.setZenoSpeaking(false);
  }

  // ── A turn ────────────────────────────────────────────────────────────────

  /// One turn, spoken or typed into the pill - the same turn the Zeno tab
  /// sends (POST /zeno/assistant/turn).
  Future<void> send(String text) async {
    text = text.trim();
    if (text.isEmpty || !isActive) return;
    _nudges = 0;
    // The tour's "next" and "stop", and its demo's answer, are the tour's;
    // anything else ends it and is answered as usual.
    if (tour.active && tour.handleSpeech(text)) {
      _heard = text;
      notifyListeners();
      _touch();
      return;
    }
    if (!tour.active && isTourRequest(text)) {
      _heard = text;
      if (expanded) dock();
      notifyListeners();
      tour.begin(firstName: _firstName, language: ApiService.currentUserLanguage);
      return;
    }
    if (_thinking) {
      // Said while Zeno works out its last answer: the rest of the
      // sentence, or the next thing. Kept, and sent once that answer is in.
      _queued = _queued == null ? text : '$_queued $text';
      return;
    }
    final epoch = _epoch;
    await _seeding;
    if (epoch != _epoch) return;
    _beat?.cancel();
    _heard = text;
    _reply = null;
    _action = null;
    _phase = null;
    _thinking = true;
    _touch();
    notifyListeners();

    // Taken before this message joins the conversation: the server adds
    // it after the history itself.
    final chat = _chat;
    final history = _context(chat, 20);
    _history.add({'role': 'user', 'content': text});
    chat?.sessionHeard(text);

    final result = await _repository.turn(
      message: text,
      history: history,
      language: ApiService.currentUserLanguage,
      voice: listening,
    );

    switch (result) {
      case Success(:final data):
        final reply = data.reply.isEmpty && data.action != null ? ZenoActionRunner.label(data.action!) : data.reply;
        _history.add({'role': 'assistant', 'content': reply});
        // Recorded even when the session has ended meanwhile: the user
        // asked, and the answer belongs in the conversation.
        if (identical(_chat, chat) && chat != null) {
          chat.sessionAnswered(reply, data.action, suggestions: data.suggestions, link: data.link);
        } else {
          _saveToStore(user: chat == null ? text : null, reply: reply);
        }
        if (epoch != _epoch) return;
        _thinking = false;
        _reply = reply;
        _answered = reply;
        _action = data.action;
        _phase = data.action == null ? null : ZenoActionPhase.pending;
        _guideVisited.clear();
        _guideFolded = false;
        notifyListeners();
        _afterReply(epoch);
        // After a screen it opens by itself has opened, not instead of it.
        _sendQueued(after: data.action?.runsByItself == true
            ? Duration(milliseconds: expanded ? 1500 : 1100)
            : Duration.zero);
      case Failure(:final message, :final statusCode):
        _history.removeLast();
        if (identical(_chat, chat)) chat?.sessionFailed(text);
        if (epoch != _epoch) return;
        _thinking = false;
        if (statusCode == 402) {
          // Voice mode needs a plan (or this month's requests are used):
          // say so in the server's words, and stop listening - every
          // further sentence would be refused the same way.
          _reply = message;
          _queued = null;
          pauseMic();
        } else {
          _reply = "I couldn't reach Zeno just now. Try again in a moment.";
          _sendQueued();
        }
        notifyListeners();
    }
  }

  void _sendQueued({Duration after = Duration.zero}) {
    final queued = _queued;
    if (queued == null) return;
    _queued = null;
    final epoch = _epoch;
    _queueTimer?.cancel();
    _queueTimer = Timer(after, () {
      if (epoch == _epoch && isActive) unawaited(send(queued));
    });
  }

  List<Map<String, String>> _context(ZenoSessionChat? chat, int count) {
    final h = chat?.recentHistory(count) ?? _history;
    return h.length > count ? h.sublist(h.length - count) : List.of(h);
  }

  /// A turn the Zeno tab wasn't open for, added to its saved conversation.
  /// Chained, so two quick turns can't each read the conversation before
  /// the other has written it and lose one.
  void _saveToStore({String? user, required String reply}) {
    _storeWrites = _storeWrites.then((_) async {
      final saved = await ZenoChatStore.load('assistant');
      final turns = [...?saved?.turns];
      final history = [...?saved?.history];
      if (user != null) {
        turns.add(ZenoStoredTurn(role: 'user', content: user));
        history.add({'role': 'user', 'content': user});
      }
      turns.add(ZenoStoredTurn(role: 'broker', content: reply));
      history.add({'role': 'assistant', 'content': reply});
      await ZenoChatStore.save(
        'assistant',
        ZenoConversation(turns: turns, history: history, savedAt: DateTime.now().toUtc()),
      );
    }).catchError((_) {});
  }

  /// Say it, and do what it said - on a short beat, so the reply lands
  /// before the screen changes (the Zeno tab does the same, _afterReply).
  void _afterReply(int epoch) {
    final reply = _reply ?? '';
    if (!_muted && reply.isNotEmpty) unawaited(_speak(reply));
    final action = _action;
    if (action == null || !action.runsByItself) return;
    _beat?.cancel();
    _beat = Timer(Duration(milliseconds: expanded ? 1100 : 750), () {
      if (epoch == _epoch && _phase == ZenoActionPhase.pending) unawaited(runAction());
    });
  }

  // ── Doing it ──────────────────────────────────────────────────────────────

  /// Opens the screen, search or chat Zeno said it would - and stays.
  Future<void> runAction() async {
    final action = _action;
    final nav = routes.navigator;
    if (action == null || action.type == ZenoActionType.call || action.type == ZenoActionType.guide) return;
    if (nav == null) {
      _phase = ZenoActionPhase.dismissed;
      notifyListeners();
      return;
    }
    _phase = ZenoActionPhase.running;
    _burst++;
    // The Buying Agent is a voice conversation of its own, with its own
    // microphone and its own spoken replies: Zeno hands over rather than
    // talk over it.
    final handOver = action.type == ZenoActionType.findForMe ||
        (action.type == ZenoActionType.navigate && action.destination == 'buying_agent');
    if (handOver) {
      end();
    } else {
      dock();
      notifyListeners();
    }
    final ok = await _open(nav, (replace) => ZenoActionRunner.runOn(nav, action, replace: replace),
        home: action.type == ZenoActionType.navigate && action.destination == 'home');
    if (_action == action && _phase == ZenoActionPhase.running) {
      _phase = ok ? ZenoActionPhase.done : ZenoActionPhase.dismissed;
      notifyListeners();
    }
  }

  Future<bool> _open(NavigatorState nav, Future<bool> Function(bool replace) go, {required bool home}) async {
    final replace = !home && _opened != null && identical(routes.top, _opened);
    final ok = await go(replace);
    _opened = ok && !home ? routes.top : null;
    return ok;
  }

  /// A guide step's "Take me there". The guide stays, folded above the
  /// pill, for the next step.
  Future<void> openStep(int index) async {
    final steps = _action?.guide?.steps;
    final nav = routes.navigator;
    if (steps == null || index < 0 || index >= steps.length || nav == null) return;
    final destination = steps[index].destination;
    if (destination == null) return;
    _guideVisited.add(index);
    _guideFolded = true;
    _burst++;
    dock();
    notifyListeners();
    await _open(nav, (replace) => ZenoActionRunner.openDestination(nav, destination, replace: replace),
        home: destination == 'home');
  }

  /// The user tapped Call - the only way a call starts from Zeno.
  Future<void> confirmCall() async {
    final action = _action;
    final who = action?.target;
    final nav = routes.navigator;
    if (action == null || who == null || nav == null) return;
    _phase = ZenoActionPhase.running;
    _burst++;
    // The call needs the microphone this session is holding. Bounded, as
    // the Zeno tab's is: a dead socket's close handshake never comes, and
    // the recorder is released in close()'s first steps.
    end();
    await (_closing ?? Future<void>.value()).timeout(const Duration(milliseconds: 600), onTimeout: () {});
    await ZenoActionRunner.callOn(nav, who, video: action.video);
  }

  void choose(ZenoContact who) {
    final action = _action;
    if (action == null) return;
    _action = action.choose(who);
    notifyListeners();
    // A chat just opens; a call still asks.
    if (action.type != ZenoActionType.call) unawaited(runAction());
  }

  void dismissAction() {
    if (_action == null) return;
    _phase = ZenoActionPhase.dismissed;
    notifyListeners();
  }

  // ── Speaking and listening ────────────────────────────────────────────────

  Future<void> _speak(String text, {String? language}) async {
    final voice = _voice;
    _speakingSelf = true;
    voice?.setZenoSpeaking(true);
    // Bounded by how long the reply can take to say, as in the Zeno tab: a
    // player that never reports the end must not leave the session deaf.
    final words = text.split(RegExp(r'\s+')).length;
    final done = Completer<void>();
    void finish() {
      if (!done.isCompleted) done.complete();
    }

    _speakCap?.cancel();
    _speakCap = Timer(Duration(milliseconds: (6000 + 450 * words).clamp(6000, 60000)), finish);
    unawaited(_tts
        .speakToEnd(text, language: language ?? ApiService.currentUserLanguage)
        .whenComplete(finish));
    await done.future;
    _speakCap?.cancel();
    _speakingSelf = false;
    voice?.setZenoSpeaking(false);
    _touch();
  }

  /// Anything read aloud anywhere in the app - the negotiation room's
  /// replies, the Buying Agent's - is not the user talking.
  void _onTtsPlaying() {
    final voice = _voice;
    if (voice == null || !voice.isOpen || _speakingSelf) return;
    voice.setZenoSpeaking(_tts.playing.value);
  }

  void _onVoice() {
    final voice = _voice!;
    final open = voice.isOpen;
    if (open != _wasListening) {
      _wasListening = open;
      // Closed by something other than this session - another voice card
      // took the microphone, or Zeno stepped back after a silence: the
      // session stays, docked, with "Tap to talk".
      if (!open && _view == ZenoSessionView.expanded) {
        _origin = dockOrigin;
        _view = ZenoSessionView.docked;
      }
      if (!open) _quiet?.cancel();
      notifyListeners();
      return;
    }
    if (!open) return;
    final userTalking = voice.interim.isNotEmpty ||
        voice.hasSendableText ||
        voice.state == VoiceSessionState.processing ||
        voice.state == VoiceSessionState.readyToSend;
    if (userTalking) _nudges = 0;
    if (userTalking || voice.state != VoiceSessionState.listening) _touch();
  }

  /// Something happened: the quiet clock starts again, from wherever the
  /// check-ins have got to.
  void _touch() {
    _quiet?.cancel();
    if (!isActive || !listening) return;
    _quiet = Timer(_quietDelay, _onQuiet);
  }

  Duration get _quietDelay => docked
      ? (_nudges == 0 ? browsingCheckInAfter : browsingRestAfter)
      : switch (_nudges) {
          0 => checkInAfter,
          1 => checkInAgainAfter,
          _ => restAfter,
        };

  /// The silence has lasted: check in, or - after enough check-ins - rest.
  void _onQuiet() {
    final voice = _voice;
    if (voice == null || !voice.isOpen || !isActive) return;
    final busy = _thinking ||
        _speakingSelf ||
        tour.active ||
        voice.state != VoiceSessionState.listening ||
        voice.interim.isNotEmpty ||
        voice.hasSendableText;
    if (busy) {
      _touch();
      return;
    }
    final checkIns = docked ? 1 : 2;
    if (_nudges >= checkIns) {
      unawaited(_rest());
      return;
    }
    final line = _checkIns.checkIn(
      ZenoCheckIns.momentAfter(_answered, docked: docked),
      nudge: _nudges,
      firstName: _firstName,
      language: ApiService.currentUserLanguage,
    );
    _nudges++;
    _reply = line.text;
    notifyListeners();
    if (_muted) {
      _touch();
    } else {
      unawaited(_speak(line.text, language: line.language));
    }
  }

  /// Zeno says it is stepping back, then the microphone stops.
  Future<void> _rest() async {
    final epoch = _epoch;
    final line = _checkIns.resting(firstName: _firstName, language: ApiService.currentUserLanguage);
    _reply = line.text;
    notifyListeners();
    if (!_muted) await _speak(line.text, language: line.language);
    if (epoch != _epoch || !isActive) return;
    final voice = _voice;
    // Spoke up as Zeno said it: the conversation goes on.
    if (voice != null && (voice.interim.isNotEmpty || voice.hasSendableText || _thinking)) {
      _nudges = 0;
      _touch();
      return;
    }
    _nudges = 0;
    pauseMic();
  }

  static String? get _firstName {
    final n = ApiService.currentUserName?.trim() ?? '';
    return n.isEmpty ? null : n.split(RegExp(r'\s+')).first;
  }

  void _onRoutePushed(Route<dynamic> route) {
    if (_endsOn.contains(route.settings.name)) {
      end();
      tour.end();
    }
  }

  // ── The screen in front ───────────────────────────────────────────────────

  void _onTopChanged() {
    // Told after the frame: the Navigator reports its first route while it
    // is itself being built, and nothing may rebuild then.
    if (!_screenNotifyScheduled) {
      _screenNotifyScheduled = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _screenNotifyScheduled = false;
        if (!_disposed) screenChanged.value++;
      });
      SchedulerBinding.instance.ensureVisualUpdate();
    }
    unawaited(_maybeOfferTour());
  }

  /// Whether [route] is Home: the first screen, and not the splash or
  /// sign-in on its way to it.
  static bool _isHome(Route<dynamic>? route) =>
      route != null && route.isFirst && route is PageRoute && !_noTourOn.contains(route.settings.name);

  /// A new account, and Home in front: Zeno offers the tour - once, after
  /// a moment for Home to draw itself.
  Future<void> _maybeOfferTour() async {
    final user = ApiService.currentUserId;
    if (user == null || _tourOfferScheduled || tour.active || isActive) return;
    if (!_isHome(routes.top)) return;
    if (!await ZenoTourStore.isPending(user)) return;
    if (_disposed || _tourOfferScheduled) return;
    _tourOfferScheduled = true;
    _tourOffer?.cancel();
    _tourOffer = Timer(const Duration(milliseconds: 1400), () {
      _tourOfferScheduled = false;
      if (_disposed || ApiService.currentUserId != user || tour.active || isActive) return;
      if (!_isHome(routes.top)) return;
      unawaited(ZenoTourStore.markOffered(user));
      tour.offer(firstName: _firstName, language: ApiService.currentUserLanguage);
    });
  }

  /// The tour, from anywhere - How BROKA works' button.
  void startTour() {
    if (isActive && expanded) dock();
    tour.begin(firstName: _firstName, language: ApiService.currentUserLanguage);
  }

  // ── ZenoTourHost ──────────────────────────────────────────────────────────

  @override
  Future<void> tourNavigate(String destination) async {
    final nav = routes.navigator;
    if (nav == null) return;
    if (expanded) dock();
    _burst++;
    notifyListeners();
    await _open(nav, (replace) => ZenoActionRunner.openDestination(nav, destination, replace: replace),
        home: destination == 'home');
  }

  @override
  Future<void> tourSay(String text, String language) async {
    if (_muted) return;
    await _speak(text, language: language);
  }

  @override
  void tourStopSpeaking() {
    if (_speakingSelf || _tts.isSpeaking) unawaited(_tts.stop());
  }

  @override
  Future<void> tourFindForMe(String query) async {
    final nav = routes.navigator;
    if (nav == null) return;
    // The Buying Agent has a voice of its own: Zeno hands over, as it does
    // for a spoken "find me one".
    if (isActive) end();
    _opened = null;
    await ZenoActionRunner.runOn(nav, ZenoAction(type: ZenoActionType.findForMe, query: query));
  }

  @override
  Future<void> tourListen() => start(docked: true, muted: _muted);

  void _cancelTimers() {
    _beat?.cancel();
    _quiet?.cancel();
    _speakCap?.cancel();
    _queueTimer?.cancel();
  }

  /// The host is going away: nothing may keep listening or ticking.
  void stopForDispose() {
    _epoch++;
    _view = ZenoSessionView.closed;
    _cancelTimers();
    _tourOffer?.cancel();
    tour.hold();
    _tts.playing.removeListener(_onTtsPlaying);
    _voice?.stopForDispose();
  }

  @override
  void dispose() {
    stopForDispose();
    _disposed = true;
    tour.dispose();
    screenChanged.dispose();
    _voice?.removeListener(_onVoice);
    _voice?.dispose();
    super.dispose();
  }
}

/// Puts [session] where the screens under the host can find it
/// (ZenoSession.maybeOf).
class ZenoSessionScope extends InheritedWidget {
  const ZenoSessionScope({super.key, required this.session, required super.child});

  final ZenoSession session;

  @override
  bool updateShouldNotify(ZenoSessionScope oldWidget) => !identical(oldWidget.session, session);
}
