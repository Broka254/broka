// Zeno showing a new user around BROKA (2026-10-09).
//
// Someone who has just made an account knows BROKA is a marketplace and
// not much more: not that an agent will hunt for them and haggle for them,
// not that Zeno can write their listing from a photo, not that it is a tap
// away on every screen. The quickest way to show what an assistant can do
// is to have it do it - so after sign-up, the first time Home is in front,
// Zeno introduces itself and offers a tour. It opens each screen it talks
// about, says what it is for, and ends by asking what the user would love
// to buy and hunting it down with the Buying Agent, there and then.
//
// Scripted, not generated: every line is here, so the tour costs no model
// call, is the same quality on the hundredth sign-up as the first, and
// says only what the app does today (README, How BROKA works). It runs
// with or without the microphone - Zeno speaks each line (BrokaTts) and
// the card under it has the buttons - and when voice is on, "next", "go
// back", "say that again" and "stop" work out loud, in English or
// Swahili. Anything else said during the tour ends it and is answered as
// usual: a user asking a real question has finished being shown around.
//
// Offered once per account (ZenoTourStore), and only to accounts made on
// this phone; "show me around" (or How BROKA works' button) runs it again.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What the tour needs from Zeno's session (zeno_session.dart), which owns
/// the Navigator, the voice and the microphone.
abstract interface class ZenoTourHost {
  /// Opens one of kZenoDestinations - replacing the screen the tour opened
  /// last, so backing out after the tour is not seven screens deep.
  Future<void> tourNavigate(String destination);

  /// Says [text] in BROKA's voice; done when it has been said (or could
  /// not be). Silent, and done at once, while Zeno is muted.
  Future<void> tourSay(String text, String language);

  void tourStopSpeaking();

  /// The Buying Agent, opened on [query] - the demo.
  Future<void> tourFindForMe(String query);

  /// Opens the microphone, docked, for the user to answer out loud.
  Future<void> tourListen();
}

/// Where a tour is.
enum ZenoTourPhase { idle, welcome, step, demo, finale }

/// One stop on the tour.
@immutable
class ZenoTourStep {
  const ZenoTourStep({
    required this.id,
    required this.title,
    required this.line,
    required this.destination,
  });

  final String id;
  final String title;

  /// What Zeno says here.
  final String line;

  /// The screen it opens (a kZenoDestinations key).
  final String destination;
}

/// Every line of the tour, in the user's language.
@immutable
class ZenoTourScript {
  const ZenoTourScript({
    required this.language,
    required this.welcome,
    required this.steps,
    required this.demo,
    required this.onIt,
    required this.finaleAfterDemo,
    required this.finale,
    required this.declined,
  });

  /// The BROKA language key the lines are written in.
  final String language;
  final String welcome;
  final List<ZenoTourStep> steps;
  final String demo;
  final String onIt;
  final String finaleAfterDemo;
  final String finale;
  final String declined;

  /// Things to try in the demo, as the demo card's chips.
  static const demoIdeas = [
    ('📱', 'A phone under 20K'),
    ('💻', 'A laptop for work'),
    ('🛋️', 'A sofa for my living room'),
    ('🚗', 'A family car'),
  ];

  /// Swahili for Swahili and Sheng speakers; English otherwise.
  static ZenoTourScript forUser({String? firstName, String language = 'english'}) {
    final name = firstName?.trim() ?? '';
    final swahili = language == 'swahili' || language == 'sheng';
    String n(String withName, String without) => name.isEmpty ? without : withName.replaceAll('{name}', name);
    if (swahili) {
      return ZenoTourScript(
        language: 'swahili',
        welcome: '${n('Habari {name}, karibu BROKA! ', 'Habari, karibu BROKA! ')}'
            'Mimi ni Zeno, dalali wako binafsi. Ninatafuta unachotaka, ninajadiliana bei kwa '
                'niaba yako, na ninakuangalilia kisipopatikana bado. Nikuonyeshe mambo yalivyo? '
                'Ni kama dakika moja tu.',
        steps: const [
          ZenoTourStep(
            id: 'home',
            title: 'Home',
            destination: 'home',
            line: 'Hii ni Home - soko lote, limepangwa kwa kanda: simu, magari, nyumba, mitindo na '
                'zaidi. Gusa kanda yoyote kuingia ndani.',
          ),
          ZenoTourStep(
            id: 'search',
            title: 'Tafuta',
            destination: 'search',
            line: 'Unajua unachotaka hasa? Tafuta kwa jina, nitakuonyesha bidhaa zinazokaribia zaidi '
                '- na kama hakuna kinachofaa, naweza kukitafuta kwa ajili yako.',
          ),
          ZenoTourStep(
            id: 'buying_agent',
            title: 'Wakala wako wa Kununua',
            destination: 'buying_agent',
            line: 'Hapa ndipo ninapopenda zaidi - Wakala wako wa Kununua. Niambie unachotafuta, '
                'nitakuuliza swali moja au mawili, nikitafute kote BROKA na nijadiliane na muuzaji '
                'kwa ajili yako. Hakipo bado? Nitaendelea kukiangalia na kukujulisha kikitokea.',
          ),
          ZenoTourStep(
            id: 'inbox',
            title: 'Inbox',
            destination: 'inbox',
            line: 'Kila dili iko kwenye Inbox yako. Niko kwenye mazungumzo yako - naweza kupendekeza '
                'bei nzuri na kujadiliana kwa niaba yako, na unaweza kumpigia muuzaji simu ya sauti '
                'au video moja kwa moja.',
          ),
          ZenoTourStep(
            id: 'sell',
            title: 'Kuuza',
            destination: 'home',
            line: 'Una kitu cha kuuza? Gusa Sell upige picha - naweza kuandika tangazo lote kwa ajili '
                'yako kutoka kwenye picha hiyo.',
          ),
          ZenoTourStep(
            id: 'anywhere',
            title: 'Niko kila mahali',
            destination: 'home',
            line: 'Na niko karibu kila wakati. Unaona duara langu pembeni mwa skrini? Ligusa kwenye '
                'skrini yoyote uongee nami - naweza kufungua kurasa, kutafuta, kukuongoza hatua kwa '
                'hatua, hata kumpigia muuzaji simu.',
          ),
        ],
        demo: '${n('Tujaribu, {name}. ', 'Tujaribu. ')}'
            'Niambie kitu kimoja ungependa kununua - kisha uone nikikiwinda.',
        onIt: 'Sawa - tazama hii.',
        finaleAfterDemo: 'Hivyo ndivyo ninavyofanya kazi. Nitakuuliza swali moja au mawili, kisha '
            'nikuonyeshe nilichopata.',
        finale: '${n('Uko tayari, {name}! ', 'Uko tayari! ')}'
            'Gusa duara langu wakati wowote ukinihitaji. Biashara njema!',
        declined: 'Sawa. Ukitaka nikutembeze baadaye, sema tu "nitembeze".',
      );
    }
    return ZenoTourScript(
      language: 'english',
      welcome: '${n('Hi {name}, welcome to BROKA! ', 'Hi, welcome to BROKA! ')}'
          "I'm Zeno, your personal broker. I find what you want, negotiate the price for you, "
              "and keep watch when it isn't here yet. Can I show you around? It takes about a minute.",
      steps: const [
        ZenoTourStep(
          id: 'home',
          title: 'Home',
          destination: 'home',
          line: 'This is Home - the whole marketplace, sorted into zones: phones, cars, homes, '
              'fashion and more. Tap any zone to dive in.',
        ),
        ZenoTourStep(
          id: 'search',
          title: 'Search',
          destination: 'search',
          line: "Know exactly what you want? Search by name and I'll show you the closest listings "
              "- and if nothing fits, I can hunt it down for you.",
        ),
        ZenoTourStep(
          id: 'buying_agent',
          title: 'Your Buying Agent',
          destination: 'buying_agent',
          line: "This is my favourite part - your Buying Agent. Tell me what you're after, I'll ask "
              "a question or two, hunt it down across BROKA and negotiate with the seller for you. "
              "Not here yet? I'll keep watch and tell you the moment it shows up.",
        ),
        ZenoTourStep(
          id: 'inbox',
          title: 'Inbox',
          destination: 'inbox',
          line: 'Every deal lives in your Inbox. I sit in on your chats - I can suggest a fair price '
              'and negotiate for you, and you can call or video call the seller right from there.',
        ),
        ZenoTourStep(
          id: 'sell',
          title: 'Selling',
          destination: 'home',
          line: 'Got something to sell? Tap Sell and take a photo - I can write the whole listing '
              'for you from it.',
        ),
        ZenoTourStep(
          id: 'anywhere',
          title: "I'm everywhere",
          destination: 'home',
          line: "And I'm never more than a tap away. See my orb at the edge of your screen? Tap it "
              'on any screen and just talk - I can open screens, search, guide you step by step, '
              'even call a seller for you.',
        ),
      ],
      demo: '${n("Let's try it, {name}. ", "Let's try it. ")}'
          "Tell me one thing you'd love to buy - and watch me hunt it down.",
      onIt: 'On it - watch this.',
      finaleAfterDemo: "That's me at work. I'll ask you a question or two, then show you what I found.",
      finale: '${n("You're all set, {name}! ", "You're all set! ")}'
          'Tap my orb any time you need me. Happy trading!',
      declined: 'No problem. Whenever you want the tour, just say "show me around".',
    );
  }
}

/// What the user said, as far as the tour is concerned.
enum ZenoTourCommand { next, back, repeat, stop, yes, no }

/// Reads the short things people say to a guide. Longer sentences are
/// requests, not commands: "what's the next step to sell my car" is a
/// question for Zeno, not "next".
ZenoTourCommand? parseTourCommand(String said) {
  final t = said.toLowerCase().replaceAll(RegExp(r"[^a-z' ]"), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (t.isEmpty || t.split(' ').length > 6) return null;
  bool has(String pattern) => RegExp('\\b($pattern)\\b').hasMatch(t);
  if (has(r"stop|skip|end|exit|quit|enough|cancel|later|not now|no thanks|that's enough|acha|simama|basi|wacha")) {
    return ZenoTourCommand.stop;
  }
  if (has(r'back|previous|go back|rudi|nyuma')) return ZenoTourCommand.back;
  if (has(r'repeat|again|pardon|come again|say that|rudia')) return ZenoTourCommand.repeat;
  if (has(r'next|continue|go on|carry on|keep going|proceed|move on|endelea|mbele')) return ZenoTourCommand.next;
  if (has(r'no|nope|nah|hapana')) return ZenoTourCommand.no;
  if (has(r"yes|yeah|yep|sure|ok|okay|alright|all right|let's go|lets go|show me|go ahead|please|ndio|ndiyo|sawa|poa|twende")) {
    return ZenoTourCommand.yes;
  }
  return null;
}

/// "Show me around", "give me a tour", "nitembeze".
bool isTourRequest(String said) => RegExp(
      r"\b(give me a tour|take me on a tour|start the tour|the tour again|app tour|broka tour|"
      r"tour of (broka|the app|this app)|show me around|walk me through (broka|the app|this app)|"
      r"show me how (broka|the app|this app) works|nitembeze|nionyeshe mambo)\b",
      caseSensitive: false,
    ).hasMatch(said);

/// Which accounts are owed the offer of a tour. Per account and per phone:
/// set when the account is made here (auth_screen.dart), cleared the
/// moment it is offered, so nobody is asked twice.
class ZenoTourStore {
  const ZenoTourStore._();

  static String _key(String userId) => 'zeno_tour_v1:$userId';

  static Future<void> markNewAccount(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key(userId), 'pending');
    } catch (_) {}
  }

  static Future<bool> isPending(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_key(userId)) == 'pending';
    } catch (_) {
      return false;
    }
  }

  static Future<void> markOffered(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key(userId), 'offered');
    } catch (_) {}
  }
}

/// The tour as it runs: which phase, which step, what Zeno is saying.
class ZenoTour extends ChangeNotifier {
  ZenoTour(this._host, {this.settle = const Duration(milliseconds: 650)});

  final ZenoTourHost _host;

  /// How long a screen is given to open before Zeno talks over it: the
  /// screen it replaces may stop speech as it goes (and the words should
  /// land on the new screen, not the old one).
  final Duration settle;

  /// The pause after a step has been said, before the next one - long
  /// enough to look, short enough to feel like it is moving.
  static const linger = Duration(milliseconds: 2400);

  /// The finale card goes by itself after this.
  static const finaleFor = Duration(seconds: 12);

  ZenoTourPhase _phase = ZenoTourPhase.idle;
  ZenoTourScript? _script;
  int _index = 0;
  String _line = '';
  bool _speaking = false;
  bool _waiting = false;
  bool _demoRan = false;
  String? _demoQuery;
  int _burst = 0;

  // Bumped by every move, so a line still being said for a step the user
  // has moved past does not move the tour on when it ends.
  int _epoch = 0;

  // Every wait is a Timer, so a move, an end or the app going away can
  // cancel it: nothing of a tour the user has left goes on ticking.
  Timer? _advance;
  Timer? _finaleTimer;
  Timer? _settleTimer;
  Timer? _readTimer;

  ZenoTourPhase get phase => _phase;
  bool get active => _phase != ZenoTourPhase.idle;
  ZenoTourScript? get script => _script;
  int get index => _index;
  int get stepCount => _script?.steps.length ?? 0;
  ZenoTourStep? get step =>
      _phase == ZenoTourPhase.step && _script != null ? _script!.steps[_index] : null;
  String get line => _line;
  bool get speaking => _speaking;

  /// Said, and waiting [linger] before moving on by itself.
  bool get waiting => _waiting;
  bool get demoRan => _demoRan;
  String? get demoQuery => _demoQuery;

  /// Goes up for each celebration - the finale's confetti.
  int get burst => _burst;

  /// Zeno introducing itself and asking whether to show the user around.
  void offer({String? firstName, String language = 'english'}) {
    _script = ZenoTourScript.forUser(firstName: firstName, language: language);
    _moveTo(ZenoTourPhase.welcome);
    _line = _script!.welcome;
    notifyListeners();
    unawaited(_say(_line, then: null));
  }

  /// Straight into the steps - "show me around".
  void begin({String? firstName, String language = 'english'}) {
    _script ??= ZenoTourScript.forUser(firstName: firstName, language: language);
    _index = 0;
    _demoRan = false;
    _demoQuery = null;
    unawaited(_playStep());
  }

  /// "Maybe later".
  void decline() {
    final said = _script?.declined;
    end();
    if (said != null) unawaited(_host.tourSay(said, _script!.language));
  }

  void next() {
    if (_phase == ZenoTourPhase.welcome) return begin();
    if (_phase != ZenoTourPhase.step) return;
    if (_index < stepCount - 1) {
      _index++;
      unawaited(_playStep());
    } else {
      unawaited(_toDemo());
    }
  }

  void back() {
    if (_phase == ZenoTourPhase.demo) {
      _index = stepCount - 1;
      unawaited(_playStep());
      return;
    }
    if (_phase != ZenoTourPhase.step || _index == 0) return;
    _index--;
    unawaited(_playStep());
  }

  void repeat() {
    switch (_phase) {
      case ZenoTourPhase.step:
        unawaited(_playStep());
      case ZenoTourPhase.welcome || ZenoTourPhase.demo:
        _epoch++;
        unawaited(_say(_line, then: null));
      case ZenoTourPhase.idle || ZenoTourPhase.finale:
        break;
    }
  }

  /// What the user would love to buy: Zeno hunts it with the Buying Agent.
  Future<void> submitDemo(String query) async {
    final q = query.trim();
    final script = _script;
    // Once: a second answer while the first is on its way is not a second hunt.
    if (q.isEmpty || script == null || _phase != ZenoTourPhase.demo || _demoQuery != null) return;
    final epoch = _moveTo(ZenoTourPhase.demo);
    _demoQuery = q;
    _line = script.onIt;
    notifyListeners();
    await _say(script.onIt, then: null);
    if (epoch != _epoch) return;
    await _host.tourFindForMe(q);
    if (epoch != _epoch) return;
    _demoRan = true;
    _finish(script.finaleAfterDemo, speak: false);
  }

  /// No demo: straight to the end.
  void skipDemo() {
    final script = _script;
    if (script == null) return;
    _finish(script.finale, speak: true);
  }

  /// Opens the microphone for the demo's answer.
  Future<void> listen() => _host.tourListen();

  /// Stops the tour wherever it is.
  void end() {
    if (!active) return;
    _moveTo(ZenoTourPhase.idle);
    if (_speaking) _host.tourStopSpeaking();
    _speaking = false;
    notifyListeners();
  }

  /// The app went to the background: nothing more is said or opened until
  /// the user is back and taps on.
  void hold() {
    _cancelTimers();
    if (!active) return;
    _epoch++;
    _waiting = false;
    if (_speaking) _host.tourStopSpeaking();
    _speaking = false;
    notifyListeners();
  }

  /// Something the user said while the tour runs. True when the tour took
  /// it; false hands it back to be answered as usual (and the tour ends).
  bool handleSpeech(String said) {
    final command = parseTourCommand(said);
    switch (_phase) {
      case ZenoTourPhase.idle:
        return false;
      case ZenoTourPhase.welcome:
        if (command == ZenoTourCommand.yes || command == ZenoTourCommand.next) {
          begin();
          return true;
        }
        if (command == ZenoTourCommand.no || command == ZenoTourCommand.stop) {
          decline();
          return true;
        }
        end();
        return false;
      case ZenoTourPhase.step:
        switch (command) {
          case ZenoTourCommand.next || ZenoTourCommand.yes:
            next();
            return true;
          case ZenoTourCommand.back:
            back();
            return true;
          case ZenoTourCommand.repeat:
            repeat();
            return true;
          case ZenoTourCommand.stop || ZenoTourCommand.no:
            end();
            return true;
          case null:
            end();
            return false;
        }
      case ZenoTourPhase.demo:
        switch (command) {
          case ZenoTourCommand.stop || ZenoTourCommand.no || ZenoTourCommand.next:
            skipDemo();
            return true;
          case ZenoTourCommand.back:
            back();
            return true;
          case ZenoTourCommand.repeat:
            repeat();
            return true;
          // "Yes" is not a thing to buy: still waiting for one.
          case ZenoTourCommand.yes:
            return true;
          case null:
            unawaited(submitDemo(said));
            return true;
        }
      case ZenoTourPhase.finale:
        end();
        return command != null;
    }
  }

  // ── Moving ────────────────────────────────────────────────────────────────

  int _moveTo(ZenoTourPhase phase) {
    _phase = phase;
    _cancelTimers();
    _waiting = false;
    return ++_epoch;
  }

  void _cancelTimers() {
    _advance?.cancel();
    _finaleTimer?.cancel();
    _settleTimer?.cancel();
    _readTimer?.cancel();
  }

  /// Waits [settle] for a screen to open; never finishes if the tour moves
  /// on meanwhile (the caller is abandoned with it).
  Future<void> _settled() {
    final done = Completer<void>();
    _settleTimer?.cancel();
    _settleTimer = Timer(settle, done.complete);
    return done.future;
  }

  Future<void> _playStep() async {
    final script = _script;
    if (script == null) return;
    final epoch = _moveTo(ZenoTourPhase.step);
    final step = script.steps[_index];
    _line = step.line;
    if (_speaking) _host.tourStopSpeaking();
    notifyListeners();
    await _host.tourNavigate(step.destination);
    if (epoch != _epoch) return;
    await _settled();
    if (epoch != _epoch) return;
    await _say(step.line, then: epoch);
  }

  Future<void> _toDemo() async {
    final script = _script;
    if (script == null) return;
    final epoch = _moveTo(ZenoTourPhase.demo);
    _line = script.demo;
    _demoQuery = null;
    if (_speaking) _host.tourStopSpeaking();
    notifyListeners();
    await _host.tourNavigate('home');
    if (epoch != _epoch) return;
    await _settled();
    if (epoch != _epoch) return;
    await _say(script.demo, then: null);
  }

  void _finish(String line, {required bool speak}) {
    final epoch = _moveTo(ZenoTourPhase.finale);
    _line = line;
    _burst++;
    notifyListeners();
    if (speak) unawaited(_say(line, then: null));
    _finaleTimer = Timer(finaleFor, () {
      if (epoch == _epoch) end();
    });
  }

  /// Says [text]; with [then], moves on after it, once it has had as long
  /// on screen as it takes to read - Zeno muted, or its voice unavailable,
  /// says it in no time at all.
  Future<void> _say(String text, {required int? then}) async {
    final epoch = _epoch;
    _speaking = true;
    notifyListeners();
    var read = then == null;
    var said = false;
    void maybeMoveOn() {
      if (!read || !said || then == null || then != _epoch) return;
      _waiting = true;
      notifyListeners();
      _advance = Timer(linger, () {
        if (then == _epoch) next();
      });
    }

    if (then != null) {
      _readTimer?.cancel();
      _readTimer = Timer(readingTime(text), () {
        read = true;
        maybeMoveOn();
      });
    }
    await _host.tourSay(text, _script?.language ?? 'english');
    if (epoch != _epoch) return;
    _speaking = false;
    notifyListeners();
    said = true;
    maybeMoveOn();
  }

  /// About how long [text] takes to read on the card.
  static Duration readingTime(String text) =>
      Duration(milliseconds: 1200 + 260 * text.split(RegExp(r'\s+')).length);

  @override
  void dispose() {
    _cancelTimers();
    super.dispose();
  }
}
