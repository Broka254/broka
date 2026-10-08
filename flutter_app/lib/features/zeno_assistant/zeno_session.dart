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
//   - a minute with nothing said stops the microphone - the speech
//     provider bills by the minute, whether anyone is talking or not - and
//     the pill says "Tap to talk".
import 'dart:async';

import 'package:flutter/widgets.dart';

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
  ZenoRouteWatch(this._onPush);

  final void Function(Route<dynamic> route) _onPush;

  Route<dynamic>? top;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    top = route;
    _onPush(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (identical(route, top)) top = previousRoute;
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (identical(route, top)) top = previousRoute;
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (identical(oldRoute, top)) top = newRoute;
    if (newRoute != null) _onPush(newRoute);
  }
}

class ZenoSession extends ChangeNotifier {
  ZenoSession({ZenoAssistantRepository? repository, BrokaTts? tts})
      : _repository = repository ?? zenoAssistantRepository,
        _tts = tts ?? BrokaTts.instance {
    routes = ZenoRouteWatch(_onRoutePushed);
  }

  /// Attach to the app's Navigator (MaterialApp.navigatorObservers).
  late final ZenoRouteWatch routes;

  final ZenoAssistantRepository _repository;
  final BrokaTts _tts;

  /// Where voice mode grows from when the Zeno tab's microphone opens it.
  static const fromMic = Alignment(0.82, 0.9);

  /// A minute of nothing said, and the microphone stops. See the header.
  static const quietFor = Duration(seconds: 60);

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

  /// Opens voice mode, or brings it back if it is docked.
  Future<void> start({RealtimeSttProvider? service, Alignment from = fromMic, bool? muted}) async {
    if (isActive) return expand(from: from);
    _epoch++;
    _heard = null;
    _reply = null;
    _action = null;
    _phase = null;
    _thinking = false;
    _typing = false;
    _opened = null;
    _guideVisited.clear();
    if (muted != null) _muted = muted;
    _origin = from;
    _view = ZenoSessionView.expanded;
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
        service: service,
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
  }

  /// Ends the session: the microphone closes and Zeno leaves the screen.
  void end() {
    if (!isActive) return;
    _epoch++;
    if (_view == ZenoSessionView.docked) _origin = dockOrigin;
    _view = ZenoSessionView.closed;
    _typing = false;
    _thinking = false;
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
    if (text.isEmpty || !isActive || _thinking) return;
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
        _action = data.action;
        _phase = data.action == null ? null : ZenoActionPhase.pending;
        _guideVisited.clear();
        _guideFolded = false;
        notifyListeners();
        _afterReply(epoch);
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
          pauseMic();
        } else {
          _reply = "I couldn't reach Zeno just now. Try again in a moment.";
        }
        notifyListeners();
    }
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

  Future<void> _speak(String text) async {
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
    unawaited(_tts.speakToEnd(text, language: ApiService.currentUserLanguage).whenComplete(finish));
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
      // took the microphone, or it was closed for quiet: the session stays,
      // docked, with "Tap to talk".
      if (!open && _view == ZenoSessionView.expanded) {
        _origin = dockOrigin;
        _view = ZenoSessionView.docked;
      }
      if (!open) _quiet?.cancel();
      notifyListeners();
      return;
    }
    if (open && (voice.interim.isNotEmpty || voice.state != VoiceSessionState.listening)) _touch();
  }

  /// Something was said: the quiet clock starts again.
  void _touch() {
    _quiet?.cancel();
    if (!isActive || !listening) return;
    _quiet = Timer(quietFor, () {
      final voice = _voice;
      if (voice == null || !voice.isOpen || _thinking) return;
      if (voice.state == VoiceSessionState.listening && voice.interim.isEmpty && !voice.hasSendableText) {
        pauseMic();
      } else {
        _touch();
      }
    });
  }

  void _onRoutePushed(Route<dynamic> route) {
    if (_endsOn.contains(route.settings.name)) end();
  }

  void _cancelTimers() {
    _beat?.cancel();
    _quiet?.cancel();
    _speakCap?.cancel();
  }

  /// The host is going away: nothing may keep listening or ticking.
  void stopForDispose() {
    _epoch++;
    _view = ZenoSessionView.closed;
    _cancelTimers();
    _tts.playing.removeListener(_onTtsPlaying);
    _voice?.stopForDispose();
  }

  @override
  void dispose() {
    stopForDispose();
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
