// BROKA - Zeno AI Assistant
// Powered by Gemini 2.0 Flash. Supports English, Kiswahili, Dholuo, Kikuyu, Luganda, Sheng.
//
// TWO MODES, ONE SURFACE
// ======================
// ZenoMode.assistant is the original general market assistant - price
// checks, scam spotting, negotiation advice.
//
// ZenoMode.buyingAgent is the Buying Agent, and it lives here rather than
// on a screen of its own for a reason. It used to be a three-stage wizard
// (type one sentence -> a confirmation card -> a result grid), which meant
// typing "iPhone" searched for the word "iPhone": no model, no storage, no
// budget, nothing asked, and "0 results found" when it missed. Every
// advantage of having an agent - that it can ask, compromise, and explain -
// was engineered out by putting a form in front of it.
//
// A buying agent is a conversation, and this screen is already Broka's
// conversation surface: bubbles, typing state, text-to-speech, dictation,
// and six languages including Sheng and Dholuo. Rebuilding that next door
// would have meant a second, worse copy of all of it - and a buyer who can
// say "nataka iPhone 14" out loud is most of the point in this market.
// So the Buying Agent is this screen in a different mode, talking to
// /buy-agent-requests/converse instead of the general chat endpoint, and
// rendering real listing cards inline when a search comes back.
//
// 2026-09-26: the conversation survives closing the app (ZenoChatStore -
// saved after every turn, restored when Zeno opens, "New chat" to start
// over), and the screen is on Home's visual system: the constellation, a
// glowing title with Home's Zeno avatar, brand-gradient bubbles and
// Home's search-pill composer, instead of flat grey bars over its own
// background.
import 'dart:async';

import 'package:flutter/material.dart';
import '../services/broka_tts.dart';
import '../services/zeno_chat_store.dart';
import '../services/zeno_voice_controller.dart';
import '../widgets/zeno_voice_card.dart';
import '../main.dart';
import '../widgets/chat_parts.dart';
import '../widgets/collapsing_screen_header.dart';
import '../widgets/constellation_background.dart';
import '../widgets/product_card.dart';
import '../widgets/zeno_avatar.dart';
import '../widgets/zeno_streaming_text.dart';
import '../services/api_service.dart';
import '../models/models.dart';
// Result.fold is an EXTENSION method (ResultExtension in result.dart), so the
// defining library has to be imported here for it to resolve - importing the
// repository that returns a Result is not enough. Omitting this is what turned
// CI red on the first push of the conversational buying agent.
import '../core/utils/result.dart';
import '../features/buy_agent/data/repositories/buy_agent_repository.dart';
import '../features/listings/domain/models/listing.dart';

/// What this screen is being used for. See the file header.
enum ZenoMode { assistant, buyingAgent }

/// One bubble, plus anything attached to it.
///
/// Zeno's search results are part of the message that announces them, not a
/// separate results screen - "here are the three I found" and the three
/// cards belong to the same turn, and scroll together with it.
class _Turn {
  final Message message;
  final List<dynamic> matches;
  const _Turn(this.message, {this.matches = const []});
}

// ── Language definitions ──────────────────────────────────────────────────────
class _Lang {
  final String key;
  final String name;
  final String flag;
  const _Lang(this.key, this.name, this.flag);
}

// No device-voice locale any more: the English-accented 'en-KE' that read
// Dholuo, Kikuyu and Sheng went with flutter_tts (see broka_tts.dart).
const _languages = [
  _Lang('english', 'English',   '🇬🇧'),
  _Lang('swahili', 'Kiswahili', '🇰🇪'),
  _Lang('luo',     'Dholuo',    '🟡'),
  _Lang('kikuyu',  'Kikuyu',    '🟤'),
  _Lang('luganda', 'Luganda',   '🇺🇬'),
  _Lang('sheng',   'Sheng',     '🔥'),
];

_Lang _langByKey(String key) =>
    _languages.firstWhere((l) => l.key == key, orElse: () => _languages[0]);

class ZenoScreen extends StatefulWidget {
  final ZenoMode mode;

  /// Buying-agent mode only: something the buyer already typed elsewhere
  /// (Home's search bar) so they don't have to say it twice. Sent as their
  /// first turn the moment the screen opens.
  final String? initialQuery;

  /// False renders the constellation as one still frame - for tests.
  final bool animateBackground;

  const ZenoScreen({
    super.key,
    this.mode = ZenoMode.assistant,
    this.initialQuery,
    this.animateBackground = true,
  });

  @override
  State<ZenoScreen> createState() => _ZenoScreenState();
}

class _ZenoScreenState extends State<ZenoScreen>
    with SingleTickerProviderStateMixin {
  final _msgCtrl    = TextEditingController();

  // Composer state - mirrors negotiation_screen.dart so both conversation
  // surfaces behave identically.
  final FocusNode _composerFocus = FocusNode();
  bool _hasDraft = false;
  bool _composerFocused = false;
  final _scrollCtrl = ScrollController();
  bool _typing      = false;
  final List<_Turn> _turns = [];
  final List<Map<String, String>> _history = [];

  /// Replies that have just arrived and are still being written out, word
  /// by word. Anything restored from earlier is simply there.
  final Set<_Turn> _fresh = Set.identity();

  bool get _isBuying => widget.mode == ZenoMode.buyingAgent;

  /// ZenoChatStore's key for this mode's conversation.
  String get _storeMode => _isBuying ? 'buying' : 'assistant';

  /// True until the saved conversation (if any) has been read back, so the
  /// opening suggestions don't flash up over a conversation that is about
  /// to appear.
  bool _restoring = true;

  /// The context sent with each message: the newest entries only. The
  /// conversation is kept on the phone now and outlives any one visit, and
  /// /negotiate/chat refuses a history longer than 100 entries (it reads the
  /// last 20); the Buying Agent reads its last 12 of 40.
  List<Map<String, String>> _recentHistory(int n) =>
      _history.length > n ? _history.sublist(_history.length - n) : List.of(_history);

  // ── Buying-agent turn state ────────────────────────────────────────────────
  // The conversation is stateless server-side (same contract as the general
  // chat), so the criteria Zeno has gathered and how many questions it has
  // spent ride along with every turn and come back updated.
  Map<String, dynamic> _slots = {};
  int _questionsAsked = 0;
  // Zeno's own read of the last search, used to decide what to offer next -
  // "EXACT" | "PARTIAL" | "MIXED" | "EMPTY", computed server-side.
  String? _lastVerdict;
  bool _watching = false;
  bool _watchBusy = false;
  final Set<String> _negotiating = <String>{};
  final Set<String> _negotiationOpened = <String>{};

  // A search is two model round-trips plus a ranked scan, so it is genuinely
  // slower than a reply. Three dots for that long reads as a hang; saying
  // what it is doing reads as work. Purely cosmetic - it advances on a timer
  // and makes no claim about actual progress.
  bool _searching = false;
  int _searchPhase = 0;
  Timer? _searchTicker;
  static const _searchPhases = [
    'Scanning Broka listings…',
    'Matching against your specs…',
    'Ranking the closest ones…',
  ];

  String get _langKey => ApiService.currentUserLanguage;

  final _tts = BrokaTts.instance;
  bool _ttsEnabled = true;

  // Voice input (Deepgram voice-card pass, 2026-09-18).
  //
  // This replaced speech_to_text's SpeechToText/_sttAvailable/_listening
  // trio outright rather than sitting beside it. Two STT engines on one
  // screen is two microphone owners: whichever one starts second wins the
  // device, the other's callbacks keep firing into a dead session, and the
  // composer ends up showing whichever one happened to finish last.
  //
  // The controller owns the Deepgram session and the transcript. This screen
  // still owns what a transcript MEANS - _submitVoice below hands it to the
  // same _send() a typed message goes through, so Zeno's history, the
  // buying-agent branch, the language handling and the TTS are all untouched.
  late final ZenoVoiceController _voice;

  late AnimationController _pulseCtrl;

  String get _firstName {
    final n = ApiService.currentUserName;
    return n != null && n.isNotEmpty ? n.split(' ').first : '';
  }

  static const _assistantSuggestions = [
    ('🚗', 'Is KES 800K fair for a Toyota Axio 2012?'),
    ('📊', 'What\'s the market like for phones right now?'),
    ('🔍', 'How do I spot a fake listing?'),
    ('🤝', 'Tips to close a deal faster'),
    ('🏠', 'How does BROKA escrow work?'),
    ('📍', 'Why does location matter in a deal?'),
  ];

  // Openers, not filters: each one is deliberately under-specified so Zeno
  // has something real to ask about, which is the whole shape of the flow.
  static const _buyingSuggestions = [
    ('📱', 'I\'m looking for an iPhone'),
    ('🚗', 'I need a car for under 1M'),
    ('💻', 'Find me a laptop for work'),
    ('🏠', 'Looking for a 2 bedroom to buy'),
    ('🚜', 'I need farm equipment'),
    ('🛋️', 'Something for my living room'),
  ];

  List<(String, String)> get _suggestions =>
      _isBuying ? _buyingSuggestions : _assistantSuggestions;

  @override
  void initState() {
    super.initState();
    _tts.onUnavailable = (reason) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ttsUnavailableMessage(reason)),
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
      ));
    };
    _initTts();
    _initVoice();
    _restore();
    // Only rebuild on the empty/non-empty boundary, not per keystroke.
    _msgCtrl.addListener(() {
      final has = _msgCtrl.text.trim().isNotEmpty;
      if (has != _hasDraft && mounted) setState(() => _hasDraft = has);
    });
    _composerFocus.addListener(() {
      if (mounted && _composerFocus.hasFocus != _composerFocused) {
        setState(() => _composerFocused = _composerFocus.hasFocus);
      }
    });
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _msgCtrl.dispose();
    _composerFocus.dispose();
    _scrollCtrl.dispose();
    _pulseCtrl.dispose();
    _searchTicker?.cancel();
    _tts.stop();
    _voice.dispose();
    super.dispose();
  }

  Future<void> _initTts() async => await _tts.init();

  /// Picks the saved conversation back up, or starts with Zeno's greeting.
  ///
  /// Arriving with a query from Home ("Ask Zeno" on a search) is a new
  /// request, so it starts a new Buying Agent conversation rather than
  /// folding into the old one's budget and specs.
  Future<void> _restore() async {
    final initial = widget.initialQuery?.trim() ?? '';
    final fresh = _isBuying && initial.isNotEmpty;
    final saved = fresh ? null : await ZenoChatStore.load(_storeMode);
    if (!mounted) return;
    setState(() {
      if (saved != null && !saved.isEmpty) {
        _turns.addAll(saved.turns.map((t) => _Turn(
              Message(role: t.role, content: t.content),
              matches: t.matches,
            )));
        _history.addAll(saved.history);
        _slots = Map.of(saved.slots);
        _questionsAsked = saved.questionsAsked;
        _lastVerdict = saved.lastVerdict;
        _watching = saved.watching;
        _negotiationOpened.addAll(saved.negotiationOpened);
      } else {
        _addWelcome();
      }
      _restoring = false;
    });
    _scrollDown(animate: false);
    if (fresh) _send(initial);
  }

  /// Saves the conversation as it stands. Called after every turn.
  void _persist() {
    ZenoChatStore.save(
      _storeMode,
      ZenoConversation(
        turns: [
          for (final t in _turns)
            ZenoStoredTurn(
              role: t.message.role,
              content: t.message.content,
              matches: [
                for (final m in t.matches)
                  if (m is Map) m.cast<String, dynamic>(),
              ],
            ),
        ],
        history: _history,
        slots: _slots,
        questionsAsked: _questionsAsked,
        lastVerdict: _lastVerdict,
        watching: _watching,
        negotiationOpened: _negotiationOpened,
        savedAt: DateTime.now(),
      ),
    );
  }

  bool get _hasConversation => _turns.any((t) => t.message.role == 'user');

  Future<void> _confirmNewChat() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: BrokaColors.bgCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Start a new chat?',
            style: TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.w800)),
        content: Text(
            _isBuying
                ? "This conversation and what Zeno has gathered for it will be cleared from this phone."
                : 'This conversation will be cleared from this phone.',
            style: const TextStyle(color: BrokaColors.textMid)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel', style: TextStyle(color: BrokaColors.textMid))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('New chat',
                  style: TextStyle(color: BrokaColors.neonBlue, fontWeight: FontWeight.w700))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    // Not awaited: silencing a reply mid-sentence must not hold up the reset.
    unawaited(_tts.stop());
    await ZenoChatStore.clear(_storeMode);
    if (!mounted) return;
    setState(() {
      _turns.clear();
      _fresh.clear();
      _history.clear();
      _slots = {};
      _questionsAsked = 0;
      _lastVerdict = null;
      _watching = false;
      _negotiationOpened.clear();
      _addWelcome();
    });
  }

  /// Voice input goes through exactly the path a typed message does.
  Future<void> _submitVoice(String text) => _send(text);

  /// Built once, not per tap. Nothing here opens a microphone - the
  /// controller only touches the device when the user taps the mic (brief
  /// §23: no permission prompt on screen entry).
  void _initVoice() {
    _voice = ZenoVoiceController(
      onSubmit: _submitVoice,
      languageKey: () => _langKey,
    );
  }

  void _addWelcome() {
    final greet = _firstName.isNotEmpty ? ', $_firstName' : '';

    // Buying agent: Zeno speaks first and asks an open question, because
    // the buyer arriving here has already said what they want by tapping
    // "Buying Agent" - what they haven't said is what they're after.
    if (_isBuying) {
      final opener = switch (_langKey) {
        'swahili' => 'Mambo$greet! Unatafuta nini leo? Niambie kitu unachotaka — nitakuuliza machache kisha nikitafute.',
        'luo'     => 'Amosi$greet! Angʼo ma imanyo kawuono? Nyisa gima idwaro — abiro penji matin eka amanyni.',
        'kikuyu'  => 'Wĩmwega$greet! Nĩ kĩĩ ũracaria ũmũthĩ? Njĩra kĩrĩa ũkwenda — nĩngũkũũria tũnini na thuutha ũcio ngũcarĩrie.',
        _         => "What's up$greet — need my help finding something? Tell me what you're after and I'll ask a couple of questions before I go looking.",
      };
      _turns.add(_Turn(Message(role: 'broker', content: opener)));
      return;
    }

    final welcomeMsg = switch (_langKey) {
      'swahili' => 'Habari$greet! Mimi ni Zeno, mshauri wako wa biashara wa BROKA. Ninaweza kukusaidia kutathmini bei, kugundua udanganyifu, au kupanga mkakati wa mazungumzo. Niulize chochote! 🤝',
      'luo'     => 'Misawa$greet! An Zeno, jakony mar ohala mar BROKA. Anyalo konyi nyiso nengo maber, neno wach miriambo, kata loso hera. Penj gimoro amora! 🤝',
      'kikuyu'  => 'Wĩmwega$greet! Nĩ niĩ Zeno, mũteithia waku wa biashara wa BROKA. Ngũkuteithia gũthagania thaara, gwĩkira mahinda ma mũrũgamo, kana gũtheria wĩhĩo. Ĩũlĩria kĩndũ kĩothe! 🤝',
      _         => 'Hello$greet! I\'m Zeno, your BROKA marketplace AI assistant. I can help you evaluate prices, spot suspicious listings, plan your negotiation strategy, and analyse market trends. Ask me anything! 🤝',
    };
    _turns.add(_Turn(Message(role: 'broker', content: welcomeMsg)));
  }

  Future<void> _send([String? override]) async {
    final text = (override ?? _msgCtrl.text).trim();
    if (text.isEmpty || _typing) return;
    _msgCtrl.clear();
    setState(() {
      _turns.add(_Turn(Message(role: 'user', content: text)));
      _typing = true;
    });
    _scrollDown();
    // Taken BEFORE this message joins _history: both endpoints receive the
    // new message on its own and add it after the history themselves, so
    // sending it in both put every message into Zeno's context twice.
    final context20 = _recentHistory(20);
    final context40 = _recentHistory(40);
    _history.add({'role': 'user', 'content': text});
    _persist();

    if (_isBuying) {
      await _sendBuyingTurn(text, context40);
      return;
    }

    try {
      final reply = await ApiService.zenoChat(
        message: text,
        history: context20,
        language: _langKey,
      );
      if (mounted) {
        _history.add({'role': 'assistant', 'content': reply});
        final turn = _Turn(Message(role: 'broker', content: reply));
        setState(() {
          _turns.add(turn);
          _fresh.add(turn);
          _typing = false;
        });
        _persist();
        if (_ttsEnabled) _speak(reply);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _turns.add(const _Turn(Message(role: 'broker',
              content: '⚠️ Zeno is unavailable right now. Please try again shortly.')));
          _typing = false;
        });
      }
    }
    _scrollDown();
  }

  /// One turn of the buying conversation.
  ///
  /// The screen does not decide whether this is a question or a search -
  /// the server does, and returns whichever it ran. That keeps the question
  /// budget, the criteria and the honesty of the result in one place
  /// instead of split across a client that could drift out of step with it.
  Future<void> _sendBuyingTurn(String text, List<Map<String, String>> history) async {
    // When the caption appears, and why it is a guess rather than a fact:
    // only the server knows whether this turn is a question or a search,
    // and it says so in the response - which arrives at the END. Two
    // signals stand in for it. The question budget is exhausted (the server
    // will search, guaranteed - see conversation.MAX_QUESTIONS), so show it
    // at once; otherwise wait, because a question is one model call and a
    // search is two plus a ranked scan, so anything still running after a
    // couple of seconds is almost certainly the search. A turn that
    // resolves quickly never shows it at all.
    if (_questionsAsked >= 2) {
      _setSearching(true);
    } else {
      Future.delayed(const Duration(milliseconds: 2200), () {
        if (mounted && _typing && !_searching) _setSearching(true);
      });
    }

    final result = await buyAgentRepository.converse(
      message: text,
      history: history,
      slots: _slots.isEmpty ? null : _slots,
      questionsAsked: _questionsAsked,
      lat: ApiService.currentUserLat,
      lng: ApiService.currentUserLng,
    );
    _setSearching(false);
    if (!mounted) return;

    result.fold(
      onSuccess: (data) {
        final reply = (data['reply'] as String?)?.trim() ?? '';
        final matches = (data['matches'] as List?) ?? const [];
        _history.add({'role': 'assistant', 'content': reply});
        final turn = _Turn(Message(role: 'broker', content: reply), matches: matches);
        setState(() {
          _slots = (data['slots'] as Map?)?.cast<String, dynamic>() ?? _slots;
          _questionsAsked = (data['questions_asked'] as num?)?.toInt() ?? _questionsAsked;
          _lastVerdict = data['verdict'] as String?;
          // A fresh search replaces the old offer to keep watching - the
          // criteria it would have watched for have moved on.
          if (data['phase'] == 'RESULTS') _watching = false;
          _turns.add(turn);
          _fresh.add(turn);
          _typing = false;
        });
        _persist();
        if (_ttsEnabled && reply.isNotEmpty) _speak(reply);
      },
      onFailure: (msg, code) => setState(() {
        _turns.add(_Turn(Message(
          role: 'broker',
          content: code == 429
              ? "I need a moment — that's a lot of searching at once. Try me again shortly."
              : "⚠️ I couldn't get that search through just now. Try me again in a moment.",
        )));
        _typing = false;
      }),
    );
    _scrollDown();
  }

  /// Starts and stops the staged "searching" caption. Cosmetic only - it is
  /// a timer, and says nothing about how far along the search really is, so
  /// it never claims a step has finished.
  void _setSearching(bool on) {
    _searchTicker?.cancel();
    if (!on) {
      if (mounted) setState(() { _searching = false; _searchPhase = 0; });
      return;
    }
    setState(() { _searching = true; _searchPhase = 0; });
    _searchTicker = Timer.periodic(const Duration(milliseconds: 1600), (t) {
      if (!mounted) { t.cancel(); return; }
      setState(() => _searchPhase = (_searchPhase + 1) % _searchPhases.length);
    });
  }

  Future<void> _speak(String text) async {
    if (!_ttsEnabled) return;
    // The same playback the screen already did, with the voice card told
    // about it so it can show "Zeno is speaking..." and then go back to
    // listening. The existing TTS toggle still governs whether this runs at
    // all - voice input does not force spoken replies on anyone.
    _voice.setZenoSpeaking(true);
    await _tts.speak(text, language: _langKey);
    _voice.setZenoSpeaking(false);
  }

  /// Opens the floating voice card. Guarded inside the controller, so a
  /// double tap cannot open two Deepgram sessions.
  void _openVoice() => _voice.open();


  /// START_NEGOTIATION for one result. The confirmation is required before
  /// Zeno ever messages a seller (Design v2 §24) - the buyer authorises
  /// this specific conversation, which is a different moment from
  /// pre-authorising the standing watch to message on their behalf.
  Future<void> _startNegotiation(BrokaListing listing) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: BrokaColors.bgCard,
        title: const Text('Start negotiating?',
            style: TextStyle(color: BrokaColors.textHigh, fontSize: 16)),
        content: Text(
          "I'll reach out to the seller of \"${listing.name}\" on your behalf and open a "
          "conversation. You'll see everything they say and can take over anytime.",
          style: const TextStyle(color: BrokaColors.textMid, fontSize: 13.5),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Not yet', style: TextStyle(color: BrokaColors.textMid))),
          TextButton(onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Yes, start it',
                  style: TextStyle(color: BrokaColors.neonBlue))),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _negotiating.add(listing.id));
    final result = await buyAgentRepository.startNegotiation(listing.id);
    if (!mounted) return;
    setState(() => _negotiating.remove(listing.id));
    result.fold(
      onSuccess: (data) {
        if (data['status'] == 'SUCCESS') {
          setState(() => _negotiationOpened.add(listing.id));
          _persist();
          Navigator.pushNamed(context, '/negotiate',
              arguments: {'listingId': listing.id});
        } else {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(data['message'] as String? ??
                "Couldn't start that negotiation just now."),
          ));
        }
      },
      onFailure: (msg, __) => ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg))),
    );
  }

  /// Turns the criteria gathered in conversation into a standing request.
  ///
  /// A standing request needs a price ceiling it can match against
  /// (BuyAgentRequest.max_price is NOT NULL, and a watch with no budget
  /// matches on category alone), so if the buyer waved the budget away
  /// during the conversation - which is a perfectly reasonable thing to do
  /// for a one-off search - this is where it has to be asked for. Asked
  /// once, at the moment it becomes necessary, rather than demanded up
  /// front by a form.
  ///
  /// [replacing] is set on the retry after the buyer agreed to swap out the
  /// watch they already had, so a second refusal is reported rather than
  /// offered again.
  Future<void> _keepWatching({bool replacing = false}) async {
    var maxPrice = (_slots['max_price'] as num?)?.toDouble();
    if (maxPrice == null) {
      maxPrice = await _askBudget();
      if (maxPrice == null || !mounted) return;
      _slots['max_price'] = maxPrice;
    }
    if (_slots['category'] == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Tell me roughly what kind of thing it is first, and I can watch for it."),
      ));
      return;
    }

    setState(() => _watchBusy = true);
    final result = await buyAgentRepository.watchFromSlots(
      _slots,
      lat: ApiService.currentUserLat,
      lng: ApiService.currentUserLng,
    );
    if (!mounted) return;
    setState(() => _watchBusy = false);
    result.fold(
      onSuccess: (data) {
        if (data['status'] == 'SUCCESS') {
          setState(() => _watching = true);
          _persist();
        } else if (data['error_code'] == 'ACTIVE_REQUEST_EXISTS' && !replacing) {
          // One watch at a time. This used to tell the buyer to "cancel
          // that one from the home screen", which had no such control -
          // nothing in the app could stop a watch, so the first one was
          // the only one a buyer would ever get. Offer the swap right here.
          _offerToReplaceWatch();
        } else {
          setState(() => _turns.add(_Turn(Message(
            role: 'broker',
            content: data['message'] as String? ?? "I couldn't set that watch up just now.",
          ))));
          _scrollDown();
        }
      },
      onFailure: (msg, __) => ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg))),
    );
  }

  /// Asks before stopping the buyer's current watch for this one - it may
  /// still be finding them things - then retries [_keepWatching] once.
  Future<void> _offerToReplaceWatch() async {
    final replace = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: BrokaColors.bgCard,
        title: const Text('Replace your current watch?',
            style: TextStyle(color: BrokaColors.textHigh, fontSize: 16)),
        content: const Text(
          "I'm already watching for something else for you, and I keep one watch at a "
          "time. Shall I stop that one and watch for this instead?",
          style: TextStyle(color: BrokaColors.textMid, fontSize: 13.5),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep the old one', style: TextStyle(color: BrokaColors.textMid))),
          TextButton(onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Replace it', style: TextStyle(color: BrokaColors.gold))),
        ],
      ),
    );
    if (replace != true || !mounted) return;

    setState(() => _watchBusy = true);
    final cancelled = await buyAgentRepository.cancelRequest();
    if (!mounted) return;
    setState(() => _watchBusy = false);
    // NO_ACTIVE_REQUEST means it is already gone (stopped elsewhere) - the
    // slot is free either way.
    final freed = cancelled.isSuccess &&
        (cancelled.data['status'] == 'SUCCESS' ||
            cancelled.data['error_code'] == 'NO_ACTIVE_REQUEST');
    if (!freed) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("I couldn't stop the other watch just now. Try again in a moment."),
      ));
      return;
    }
    await _keepWatching(replacing: true);
  }

  Future<double?> _askBudget() async {
    final ctrl = TextEditingController();
    return showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: BrokaColors.bgCard,
        title: const Text("What's your ceiling?",
            style: TextStyle(color: BrokaColors.textHigh, fontSize: 16)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text("To keep watching I need a top price, so I only bring you things "
              "you'd actually consider.",
              style: TextStyle(color: BrokaColors.textMid, fontSize: 13)),
          const SizedBox(height: 12),
          TextField(
            controller: ctrl,
            autofocus: true,
            keyboardType: TextInputType.number,
            style: const TextStyle(color: BrokaColors.textHigh),
            decoration: const InputDecoration(
              prefixText: 'KES ',
              prefixStyle: TextStyle(color: BrokaColors.textMid),
              hintText: '80000',
              hintStyle: TextStyle(color: BrokaColors.textLow),
            ),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel', style: TextStyle(color: BrokaColors.textMid))),
          TextButton(
            onPressed: () {
              final v = double.tryParse(ctrl.text.trim().replaceAll(',', ''));
              Navigator.pop(ctx, (v != null && v > 0) ? v : null);
            },
            child: const Text('Watch for it', style: TextStyle(color: BrokaColors.gold)),
          ),
        ],
      ),
    );
  }

  /// [animate] false jumps - for a restored conversation, which should open
  /// at its latest message rather than scroll there in front of the user.
  void _scrollDown({bool animate = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      final end = _scrollCtrl.position.maxScrollExtent;
      if (!animate) {
        _scrollCtrl.jumpTo(end);
        return;
      }
      _scrollCtrl.animateTo(
        end + 80,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }

  /// A reply has finished writing itself out: show what came with it.
  void _streamed(_Turn turn) {
    if (!mounted || !_fresh.remove(turn)) return;
    setState(() {});
    if (turn.matches.isNotEmpty) _scrollDown();
  }

  /// Keeps a reply that is being written in view as it grows - unless the
  /// user has scrolled up to read something else.
  ///
  /// Called every frame while a reply is written, so each step is a few
  /// pixels - smooth, not a jump per line. Never while a finger or a fling
  /// is moving the list.
  void _followStream() {
    if (!_scrollCtrl.hasClients) return;
    final p = _scrollCtrl.position;
    if (p.isScrollingNotifier.value) return;
    if (p.maxScrollExtent - p.pixels < 160 && p.pixels < p.maxScrollExtent) {
      _scrollCtrl.jumpTo(p.maxScrollExtent);
    }
  }

  /// Zeno's colours - the brand gradient Home's Zeno CTA and the splash use.
  static const _zenoGradient = kChatGradient;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      // The same constellation as Home and every screen reached from it.
      // The voice card floats OVER this conversation rather than replacing
      // it: the Column below stays mounted, at its scroll position, with its
      // history intact, and closing the card puts the user back exactly where
      // they were (brief §33).
      body: ZenoVoiceOverlay(
        controller: _voice,
        child: ConstellationBackground(
          animate: widget.animateBackground,
          child: DecoratedBox(
            // Zeno's colour washing down from the top, as a category's does
            // in its Zone - over the constellation, fading to transparent.
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment.topCenter,
                radius: 1.2,
                colors: [BrokaColors.neonPurple.withOpacity(0.14), Colors.transparent],
                stops: const [0.0, 0.6],
              ),
            ),
            child: SafeArea(
              child: Column(children: [
                _buildHeader(),
                Expanded(child: _buildMessages()),
                if (_typing) (_searching ? _buildSearchingIndicator() : _buildTypingIndicator()),
                if (!_restoring && !_hasConversation) _buildSuggestions(),
                _buildInputBar(),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  /// Home's header language: a bare back chevron, the avatar Home uses for
  /// Zeno, a glowing title, and square controls on the right.
  Widget _buildHeader() {
    final lang = _langByKey(_langKey);
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 6, 12, 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: BrokaColors.border.withOpacity(0.6))),
      ),
      child: Row(children: [
        IconButton(
          tooltip: 'Back',
          onPressed: () => Navigator.maybePop(context),
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              color: BrokaColors.textHigh, size: 19),
        ),
        AnimatedBuilder(
          animation: _pulseCtrl,
          builder: (_, child) => Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: BrokaColors.neonBlue.withOpacity(0.18 + 0.14 * _pulseCtrl.value),
                  blurRadius: 12 + 6 * _pulseCtrl.value,
                ),
              ],
            ),
            child: child,
          ),
          child: const ZenoAvatar(size: 38, glow: true),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            const ZoneGlowText('Zeno',
                gradient: _zenoGradient, fontSize: 20, maxLines: 1, letterSpacing: 1.6),
            const SizedBox(height: 3),
            Row(children: [
              Container(
                width: 6,
                height: 6,
                decoration: const BoxDecoration(shape: BoxShape.circle, color: BrokaColors.neonGreen),
              ),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  '${_isBuying ? 'Buying Agent' : 'AI Market Assistant'} · ${lang.flag} ${lang.name}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: BrokaColors.textMid, fontSize: 11.5),
                ),
              ),
            ]),
          ]),
        ),
        const SizedBox(width: 8),
        BrokaHeaderButton(
          icon: _ttsEnabled ? Icons.volume_up_rounded : Icons.volume_off_rounded,
          active: _ttsEnabled,
          tooltip: _ttsEnabled ? 'Mute Zeno' : "Read Zeno's replies aloud",
          onTap: () {
            _tts.stop();
            setState(() => _ttsEnabled = !_ttsEnabled);
          },
        ),
        if (_hasConversation) ...[
          const SizedBox(width: 8),
          BrokaHeaderButton(
            icon: Icons.add_comment_outlined,
            tooltip: 'New chat',
            onTap: _confirmNewChat,
          ),
        ],
      ]),
    );
  }

  Widget _buildMessages() => ListView.builder(
    controller: _scrollCtrl,
    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
    itemCount: _turns.length,
    itemBuilder: (_, i) {
      final turn = _turns[i];
      final isLast = i == _turns.length - 1;
      // What Zeno found comes after Zeno has said so, not under a sentence
      // still being written.
      final writing = _fresh.contains(turn);
      final bubble = _ZenoBubble(
        message: turn.message,
        stream: writing,
        onStreamed: () => _streamed(turn),
        onGrow: _followStream,
      );
      if (turn.matches.isEmpty || writing) {
        // The offer to keep watching belongs on the last turn even when it
        // found nothing - an empty search is exactly when a standing watch
        // is worth the most.
        final offerWatch = _isBuying && isLast && _lastVerdict == 'EMPTY' && !writing;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          bubble,
          if (offerWatch) _buildWatchOffer(),
        ]);
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        bubble,
        ...turn.matches.map((m) => _buildMatchCard(m as Map<String, dynamic>)),
        if (isLast) _buildWatchOffer(),
        const SizedBox(height: 4),
      ]);
    },
  );

  /// One result, with what it falls short on stated on its face.
  ///
  /// Design v2 §23 rules out invented match percentages, and the score this
  /// is ordered by is not a calibrated probability of anything - so what
  /// the buyer is shown is the concrete shortfall the backend measured
  /// ("8GB RAM, you wanted 12GB"), which is a fact about the listing, not a
  /// number about our confidence.
  Widget _buildMatchCard(Map<String, dynamic> match) {
    final listing = BrokaListing.fromJson(match);
    final misses = (match['match_misses'] as List?) ?? const [];
    final isExact = match['match_is_exact'] == true;

    return Padding(
      padding: const EdgeInsets.only(left: 38, bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          height: 210,
          child: ProductCard(
            item: listing,
            onTap: () => Navigator.pushNamed(
                context, '/product', arguments: {'listingId': listing.id}),
          ),
        ),
        if (isExact)
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Row(children: [
              Icon(Icons.check_circle_rounded, size: 13, color: BrokaColors.success),
              SizedBox(width: 5),
              Text('Matches everything you asked for',
                  style: TextStyle(color: BrokaColors.success, fontSize: 11.5,
                      fontWeight: FontWeight.w600)),
            ]),
          )
        else if (misses.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(spacing: 6, runSpacing: 6, children: [
              for (final raw in misses.take(3))
                _shortfallChip(raw as Map<String, dynamic>),
            ]),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: SizedBox(
            width: double.infinity,
            child: _negotiationOpened.contains(listing.id)
                ? OutlinedButton.icon(
                    onPressed: () => Navigator.pushNamed(
                        context, '/negotiate', arguments: {'listingId': listing.id}),
                    icon: const Icon(Icons.check_rounded, size: 15, color: BrokaColors.success),
                    label: const Text('Zeno reached out — open chat',
                        style: TextStyle(color: BrokaColors.success, fontSize: 12.5,
                            fontWeight: FontWeight.w600)),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: BrokaColors.success.withOpacity(0.4)),
                      padding: const EdgeInsets.symmetric(vertical: 9),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  )
                : OutlinedButton.icon(
                    onPressed: _negotiating.contains(listing.id)
                        ? null
                        : () => _startNegotiation(listing),
                    icon: _negotiating.contains(listing.id)
                        ? const SizedBox(width: 15, height: 15,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: BrokaColors.neonBlue))
                        : const Icon(Icons.chat_bubble_outline_rounded,
                            size: 15, color: BrokaColors.neonBlue),
                    label: const Text('Ask Zeno to negotiate this one',
                        style: TextStyle(color: BrokaColors.neonBlue, fontSize: 12.5,
                            fontWeight: FontWeight.w600)),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: BrokaColors.neonBlue.withOpacity(0.4)),
                      padding: const EdgeInsets.symmetric(vertical: 9),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
          ),
        ),
      ]),
    );
  }

  Widget _shortfallChip(Map<String, dynamic> miss) {
    final field = _prettyField(miss['field'] as String? ?? '');
    final wanted = miss['wanted']?.toString() ?? '';
    final actual = miss['actual']?.toString();
    final label = actual == null
        ? "$field not stated (you wanted $wanted)"
        : "$field $actual, you wanted $wanted";
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: BrokaColors.gold.withOpacity(0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: BrokaColors.gold.withOpacity(0.35)),
      ),
      child: Text(label, style: const TextStyle(
          color: BrokaColors.gold, fontSize: 10.5, fontWeight: FontWeight.w600)),
    );
  }

  static String _prettyField(String field) => switch (field) {
        'max_price' => 'Price',
        'min_price' => 'Price',
        'max_distance_km' => 'Distance',
        'condition' => 'Condition',
        'ram' => 'RAM',
        _ => field.isEmpty
            ? field
            : field.replaceAll('_', ' ')[0].toUpperCase() +
                field.replaceAll('_', ' ').substring(1),
      };

  /// "Keep watching for me" - the standing request, offered in conversation
  /// rather than as a checkbox on a results screen. This is what keeps the
  /// Buy-Agent request feature reachable now the wizard that used to create
  /// it is gone.
  Widget _buildWatchOffer() {
    if (!_isBuying) return const SizedBox.shrink();
    if (_slots['category'] == null && _slots['query'] == null) return const SizedBox.shrink();

    if (_watching) {
      return const Padding(
        padding: EdgeInsets.only(left: 38, bottom: 14),
        child: Row(children: [
          Icon(Icons.visibility_rounded, size: 14, color: BrokaColors.success),
          SizedBox(width: 6),
          Flexible(child: Text("I'll keep watching and tell you when something turns up.",
              style: TextStyle(color: BrokaColors.success, fontSize: 12,
                  fontWeight: FontWeight.w600))),
        ]),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(left: 38, bottom: 14),
      child: OutlinedButton.icon(
        onPressed: _watchBusy ? null : _keepWatching,
        icon: _watchBusy
            ? const SizedBox(width: 14, height: 14,
                child: CircularProgressIndicator(strokeWidth: 2, color: BrokaColors.gold))
            : const Icon(Icons.visibility_outlined, size: 15, color: BrokaColors.gold),
        label: const Text('Keep watching for me',
            style: TextStyle(color: BrokaColors.gold, fontSize: 12.5,
                fontWeight: FontWeight.w600)),
        style: OutlinedButton.styleFrom(
          side: BorderSide(color: BrokaColors.gold.withOpacity(0.4)),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
    );
  }

  Widget _buildSearchingIndicator() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    child: Row(children: [
      AnimatedBuilder(
        animation: _pulseCtrl,
        builder: (_, child) => Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [BoxShadow(
              color: BrokaColors.neonBlue.withOpacity(0.25 + 0.35 * _pulseCtrl.value),
              blurRadius: 10 + 10 * _pulseCtrl.value,
            )],
          ),
          child: child,
        ),
        child: const ZenoAvatar(size: 28),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 320),
          child: Text(
            _searchPhases[_searchPhase],
            key: ValueKey(_searchPhase),
            style: const TextStyle(color: BrokaColors.textMid, fontSize: 12.5,
                fontStyle: FontStyle.italic),
          ),
        ),
      ),
    ]),
  );

  Widget _buildTypingIndicator() => const Padding(
    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    child: ZenoTypingBubble(),
  );

  /// Openers as chips floating over the constellation, like a Zone's
  /// subcategory rail - not a grey band across the screen.
  Widget _buildSuggestions() => SizedBox(
    height: 50,
    child: ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      children: [
        for (final s in _suggestions)
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Material(
              color: BrokaColors.bgCard.withOpacity(0.86),
              shape: StadiumBorder(side: BorderSide(color: BrokaColors.neonPurple.withOpacity(0.35))),
              child: InkWell(
                customBorder: const StadiumBorder(),
                onTap: () => _send(s.$2),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(s.$1, style: const TextStyle(fontSize: 14)),
                    const SizedBox(width: 6),
                    Text(s.$2, style: const TextStyle(
                        color: BrokaColors.textHigh, fontSize: 12.5)),
                  ]),
                ),
              ),
            ),
          ),
      ],
    ),
  );

  /// Home's search pill as the composer: the same fill, outline and focus
  /// glow, so typing to Zeno looks like typing anywhere else in BROKA.
  Widget _buildInputBar() => Padding(
    padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            constraints: const BoxConstraints(minHeight: 50),
            decoration: BoxDecoration(
              color: BrokaColors.bgCard.withOpacity(0.92),
              borderRadius: BorderRadius.circular(26),
              // The composer doesn't highlight for listening - the voice
              // card above owns that state, and a second "recording" outline
              // down here read as a competing session.
              border: Border.all(
                color: BrokaColors.neonBlue.withOpacity(_composerFocused ? 0.85 : 0.45),
                width: _composerFocused ? 1.6 : 1.2,
              ),
              boxShadow: _composerFocused
                  ? [BoxShadow(color: BrokaColors.neonBlue.withOpacity(0.18), blurRadius: 14)]
                  : null,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 4, 14),
                  child: Icon(Icons.auto_awesome_rounded,
                      size: 18,
                      color: _composerFocused ? BrokaColors.neonBlue : BrokaColors.textMid),
                ),
                Expanded(
                  child: TextField(
                    key: const Key('zeno-composer'),
                    controller: _msgCtrl,
                    focusNode: _composerFocus,
                    style: const TextStyle(
                        color: BrokaColors.textHigh, fontSize: 15.5, height: 1.35),
                    minLines: 1,
                    maxLines: 6,
                    textCapitalization: TextCapitalization.sentences,
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.newline,
                    cursorColor: BrokaColors.neonBlue,
                    decoration: InputDecoration(
                      isDense: true,
                      filled: false,
                      hintText: _isBuying
                          ? "Tell Zeno what you're looking for"
                          : 'Ask Zeno anything',
                      hintStyle: const TextStyle(color: BrokaColors.textMid, fontSize: 15),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 6, vertical: 14),
                    ),
                  ),
                ),
                // Opens the Zeno voice card over this conversation. The
                // composer stays exactly where it is underneath - voice is
                // another way in, not a replacement for typing.
                if (!_hasDraft)
                  InkResponse(
                    onTap: _openVoice,
                    radius: 22,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 13, 14, 13),
                      child: AnimatedBuilder(
                        animation: _voice,
                        builder: (_, __) => Icon(
                          _voice.isOpen ? Icons.mic_rounded : Icons.mic_none_rounded,
                          size: 22,
                          color: _voice.isOpen ? BrokaColors.neonBlue : BrokaColors.textMid,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        ChatSendButton(visible: _hasDraft, busy: _typing, onTap: () => _send()),
      ],
    ),
  );
}

// ── Zeno Chat Bubble ─────────────────────────────────────────────────────────
//
// Zeno's words on a dark card with a violet edge; yours on the brand
// gradient, like Home's Zeno CTA and every primary button in the app.
class _ZenoBubble extends StatelessWidget {
  final Message message;

  /// A reply that has just arrived: written out word by word.
  final bool stream;
  final VoidCallback? onStreamed;
  final VoidCallback? onGrow;
  const _ZenoBubble({required this.message, this.stream = false, this.onStreamed, this.onGrow});

  @override
  Widget build(BuildContext context) {
    final isAI = message.isBroker;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: isAI ? MainAxisAlignment.start : MainAxisAlignment.end,
        children: [
          if (isAI) ...[
            const ZenoAvatar(size: 28),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.82),
              decoration: BoxDecoration(
                color: isAI ? BrokaColors.bgCard.withOpacity(0.92) : null,
                gradient: isAI
                    ? null
                    : const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [BrokaColors.neonPurple, BrokaColors.neonBlue]),
                borderRadius: isAI
                    ? const BorderRadius.only(
                        topLeft: Radius.circular(4),
                        topRight: Radius.circular(16),
                        bottomLeft: Radius.circular(16),
                        bottomRight: Radius.circular(16))
                    : const BorderRadius.only(
                        topLeft: Radius.circular(16),
                        topRight: Radius.circular(4),
                        bottomLeft: Radius.circular(16),
                        bottomRight: Radius.circular(16)),
                border: isAI
                    ? Border.all(color: BrokaColors.neonPurple.withOpacity(0.30))
                    : null,
                boxShadow: isAI
                    ? null
                    : [BoxShadow(color: BrokaColors.neonBlue.withOpacity(0.18), blurRadius: 10)],
              ),
              child: isAI
                  ? ZenoStreamingText(
                      message.content,
                      key: ObjectKey(message),
                      style: const TextStyle(
                          color: BrokaColors.textHigh, fontSize: 14.5, height: 1.5),
                      animate: stream,
                      onDone: onStreamed,
                      onGrow: onGrow,
                    )
                  : Text(message.content,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 14.5, height: 1.5)),
            ),
          ),
        ],
      ),
    );
  }
}
