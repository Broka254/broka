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
import 'dart:async';

import 'package:flutter/material.dart';
import '../services/broka_tts.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import '../main.dart';
import '../widgets/chat_ambient_background.dart';
import '../widgets/product_card.dart';
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
  final String ttsLocale;
  const _Lang(this.key, this.name, this.flag, this.ttsLocale);
}

const _languages = [
  _Lang('english', 'English',   '🇬🇧', 'en-KE'),
  _Lang('swahili', 'Kiswahili', '🇰🇪', 'sw-KE'),
  _Lang('luo',     'Dholuo',    '🟡',  'en-KE'),
  _Lang('kikuyu',  'Kikuyu',    '🟤',  'en-KE'),
  _Lang('luganda', 'Luganda',   '🇺🇬', 'en-UG'),
  _Lang('sheng',   'Sheng',     '🔥',  'en-KE'),
];

_Lang _langByKey(String key) =>
    _languages.firstWhere((l) => l.key == key, orElse: () => _languages[0]);

class ZenoScreen extends StatefulWidget {
  final ZenoMode mode;

  /// Buying-agent mode only: something the buyer already typed elsewhere
  /// (Home's search bar) so they don't have to say it twice. Sent as their
  /// first turn the moment the screen opens.
  final String? initialQuery;

  const ZenoScreen({super.key, this.mode = ZenoMode.assistant, this.initialQuery});

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
  List<_Turn> _turns = [];
  List<Map<String, String>> _history = [];

  bool get _isBuying => widget.mode == ZenoMode.buyingAgent;

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
  bool _speaking   = false;

  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _sttAvailable = false;
  bool _listening    = false;

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
    _tts.onFallback = () {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Using offline voice — Zeno\'s usual voice is unavailable right now.'),
        duration: Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
      ));
    };
    _initTts();
    _initStt();
    _addWelcome();
    final initial = widget.initialQuery?.trim();
    if (_isBuying && initial != null && initial.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _send(initial));
    }
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
    super.dispose();
  }

  Future<void> _initTts() async => await _tts.init();

  Future<void> _initStt() async {
    _sttAvailable = await _speech.initialize();
    if (mounted) setState(() {});
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
    _history.add({'role': 'user', 'content': text});

    if (_isBuying) {
      await _sendBuyingTurn(text);
      return;
    }

    try {
      final reply = await ApiService.zenoChat(
        message: text,
        history: _history,
        language: _langKey,
      );
      if (mounted) {
        _history.add({'role': 'assistant', 'content': reply});
        setState(() {
          _turns.add(_Turn(Message(role: 'broker', content: reply)));
          _typing = false;
        });
        if (_ttsEnabled) _speak(reply);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _turns.add(_Turn(Message(role: 'broker',
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
  Future<void> _sendBuyingTurn(String text) async {
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
      history: _history,
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
        setState(() {
          _slots = (data['slots'] as Map?)?.cast<String, dynamic>() ?? _slots;
          _questionsAsked = (data['questions_asked'] as num?)?.toInt() ?? _questionsAsked;
          _lastVerdict = data['verdict'] as String?;
          // A fresh search replaces the old offer to keep watching - the
          // criteria it would have watched for have moved on.
          if (data['phase'] == 'RESULTS') _watching = false;
          _turns.add(_Turn(Message(role: 'broker', content: reply), matches: matches));
          _typing = false;
        });
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
    setState(() => _speaking = true);
    final lang = _langByKey(_langKey);
    await _tts.speak(text, language: _langKey);
    if (mounted) setState(() => _speaking = false);
  }

  void _toggleListening() async {
    if (_listening) {
      await _speech.stop();
      setState(() => _listening = false);
      return;
    }
    if (!_sttAvailable) return;
    setState(() => _listening = true);
    _speech.listen(
      onResult: (r) {
        if (r.finalResult) {
          setState(() { _listening = false; _msgCtrl.text = r.recognizedWords; });
        }
      },
      localeId: _langByKey(_langKey).ttsLocale,
      cancelOnError: true,
    );
  }

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
  Future<void> _keepWatching() async {
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
        } else {
          // Most often ACTIVE_REQUEST_EXISTS - say what it means and what
          // to do, not the raw error code.
          final code = data['error_code'];
          setState(() => _turns.add(_Turn(Message(
            role: 'broker',
            content: code == 'ACTIVE_REQUEST_EXISTS'
                ? "I'm already watching for something else for you. Cancel that one from "
                  "the home screen and I'll pick this up instead."
                : (data['message'] as String? ?? "I couldn't set that watch up just now."),
          ))));
          _scrollDown();
        }
      },
      onFailure: (msg, __) => ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(msg))),
    );
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

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent + 80,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      // Same constellation field as the splash screen and the direct-chat
      // thread, at slightly higher intensity: this is Zeno's own surface,
      // it carries less dense content than a buyer/seller thread, and the
      // visual continuity with "BOOTING ZENO" on the splash is the point.
      body: ChatAmbientBackground(
        intensity: 1.0,
        child: Column(children: [
          _buildHeader(),
          Expanded(child: _buildMessages()),
          if (_typing) (_searching ? _buildSearchingIndicator() : _buildTypingIndicator()),
          if (_turns.length <= 1) _buildSuggestions(),
          _buildInputBar(),
        ]),
      ),
    );
  }

  Widget _buildHeader() => SafeArea(
    bottom: false,
    child: Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        color: BrokaColors.bgMid.withOpacity(0.88),
        border: const Border(bottom: BorderSide(color: BrokaColors.border)),
      ),
      child: Row(children: [
        GestureDetector(
          onTap: () => Navigator.pop(context),
          child: Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              color: BrokaColors.bgCard,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: BrokaColors.border),
            ),
            child: const Icon(Icons.arrow_back_ios_new_rounded,
                color: BrokaColors.textMid, size: 16),
          ),
        ),
        const SizedBox(width: 12),
        AnimatedBuilder(
          animation: _pulseCtrl,
          builder: (_, __) => Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                  colors: [BrokaColors.gold, BrokaColors.neonBlue]),
              boxShadow: [BoxShadow(
                color: BrokaColors.gold.withOpacity(0.3 + 0.3 * _pulseCtrl.value),
                blurRadius: 12 + 8 * _pulseCtrl.value,
              )],
            ),
            child: const Icon(Icons.auto_awesome_rounded,
                color: Colors.white, size: 20),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Zeno', style: TextStyle(
              color: BrokaColors.textHigh, fontSize: 16, fontWeight: FontWeight.w800)),
          Text(
              '${_isBuying ? 'Buying Agent' : 'AI Market Assistant'} · '
              '${_langByKey(_langKey).flag} ${_langByKey(_langKey).name}',
              style: const TextStyle(color: BrokaColors.textMid, fontSize: 11)),
        ])),
        // TTS toggle
        GestureDetector(
          onTap: () { _tts.stop(); setState(() => _ttsEnabled = !_ttsEnabled); },
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: _ttsEnabled
                  ? BrokaColors.gold.withOpacity(0.12)
                  : BrokaColors.bgCard,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _ttsEnabled
                  ? BrokaColors.gold.withOpacity(0.5) : BrokaColors.border),
            ),
            child: Icon(_ttsEnabled ? Icons.volume_up_rounded : Icons.volume_off_rounded,
                color: _ttsEnabled ? BrokaColors.gold : BrokaColors.textLow, size: 18),
          ),
        ),
      ]),
    ),
  );

  Widget _buildMessages() => ListView.builder(
    controller: _scrollCtrl,
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
    itemCount: _turns.length,
    itemBuilder: (_, i) {
      final turn = _turns[i];
      final isLast = i == _turns.length - 1;
      if (turn.matches.isEmpty) {
        // The offer to keep watching belongs on the last turn even when it
        // found nothing - an empty search is exactly when a standing watch
        // is worth the most.
        final offerWatch = _isBuying && isLast && _lastVerdict == 'EMPTY';
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _ZenoBubble(message: turn.message),
          if (offerWatch) _buildWatchOffer(),
        ]);
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _ZenoBubble(message: turn.message),
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
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(children: const [
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
      return Padding(
        padding: const EdgeInsets.only(left: 38, bottom: 14),
        child: Row(children: const [
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
        builder: (_, __) => Container(
          width: 32, height: 32,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: const LinearGradient(
                colors: [BrokaColors.gold, BrokaColors.neonBlue]),
            boxShadow: [BoxShadow(
              color: BrokaColors.neonBlue.withOpacity(0.25 + 0.35 * _pulseCtrl.value),
              blurRadius: 10 + 10 * _pulseCtrl.value,
            )],
          ),
          child: const Icon(Icons.travel_explore_rounded, color: Colors.white, size: 16),
        ),
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

  Widget _buildTypingIndicator() => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    child: Row(children: [
      Container(
        width: 32, height: 32,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
              colors: [BrokaColors.gold, BrokaColors.neonBlue]),
        ),
        child: const Icon(Icons.auto_awesome_rounded, color: Colors.white, size: 14),
      ),
      const SizedBox(width: 8),
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: BrokaColors.bgCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: BrokaColors.border),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          _dot(0), const SizedBox(width: 4),
          _dot(200), const SizedBox(width: 4),
          _dot(400),
        ]),
      ),
    ]),
  );

  Widget _dot(int delayMs) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0.3, end: 1.0),
    duration: const Duration(milliseconds: 600),
    curve: Curves.easeInOut,
    builder: (_, v, __) => Opacity(
      opacity: v,
      child: Container(width: 6, height: 6,
          decoration: const BoxDecoration(
              shape: BoxShape.circle, color: BrokaColors.gold)),
    ),
  );

  Widget _buildSuggestions() => Container(
    height: 80,
    color: BrokaColors.bgMid,
    child: ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      children: _suggestions.map((s) => GestureDetector(
        onTap: () => _send(s.$2),
        child: Container(
          margin: const EdgeInsets.only(right: 10),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: BrokaColors.bgCard,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: BrokaColors.border),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(s.$1, style: const TextStyle(fontSize: 14)),
            const SizedBox(width: 6),
            Text(s.$2, style: const TextStyle(
                color: BrokaColors.textMid, fontSize: 12)),
          ]),
        ),
      )).toList(),
    ),
  );

  Widget _buildInputBar() => SafeArea(
    top: false,
    child: Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      decoration: BoxDecoration(
        color: BrokaColors.bgMid.withOpacity(0.92),
        border: const Border(top: BorderSide(color: BrokaColors.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Container(
              constraints: const BoxConstraints(minHeight: 46),
              decoration: BoxDecoration(
                color: BrokaColors.bgCard,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: _listening
                      ? BrokaColors.danger.withOpacity(0.6)
                      : (_composerFocused
                          ? BrokaColors.gold.withOpacity(0.55)
                          : BrokaColors.border),
                  width: (_listening || _composerFocused) ? 1.4 : 1,
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(14, 13, 2, 13),
                    child: Icon(Icons.auto_awesome_rounded,
                        size: 17, color: BrokaColors.gold),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _msgCtrl,
                      focusNode: _composerFocus,
                      style: const TextStyle(
                          color: BrokaColors.textHigh, fontSize: 15, height: 1.35),
                      minLines: 1,
                      maxLines: 6,
                      textCapitalization: TextCapitalization.sentences,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      cursorColor: BrokaColors.gold,
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: _isBuying
                            ? "Tell Zeno what you're looking for"
                            : 'Ask Zeno anything',
                        hintStyle: const TextStyle(color: BrokaColors.textLow, fontSize: 15),
                        border: InputBorder.none,
                        contentPadding:
                            EdgeInsets.symmetric(horizontal: 6, vertical: 13),
                      ),
                    ),
                  ),
                  if (_sttAvailable && !_hasDraft)
                    InkResponse(
                      onTap: _toggleListening,
                      radius: 22,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(8, 11, 12, 11),
                        child: Icon(
                          _listening ? Icons.mic_rounded : Icons.mic_none_rounded,
                          size: 22,
                          color: _listening ? BrokaColors.danger : BrokaColors.textMid,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          AnimatedScale(
            scale: (_hasDraft || _typing) ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutBack,
            child: AnimatedOpacity(
              opacity: (_hasDraft || _typing) ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 140),
              child: GestureDetector(
                onTap: (_typing || !_hasDraft) ? null : () => _send(),
                child: Container(
                  width: 46,
                  height: 46,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [BrokaColors.gold, BrokaColors.neonBlue],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: BrokaColors.gold.withOpacity(0.35),
                        blurRadius: 14, spreadRadius: 1),
                    ],
                  ),
                  child: _typing
                      ? const Center(
                          child: SizedBox(width: 18, height: 18,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white)))
                      : const Icon(Icons.arrow_upward_rounded,
                          color: Colors.white, size: 21),
                ),
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

// ── Zeno Chat Bubble ─────────────────────────────────────────────────────────
class _ZenoBubble extends StatelessWidget {
  final Message message;
  const _ZenoBubble({required this.message});

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
            Container(
              width: 30, height: 30,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(colors: [BrokaColors.gold, BrokaColors.neonBlue]),
              ),
              child: const Icon(Icons.auto_awesome_rounded, color: Colors.white, size: 14),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.82),
              decoration: BoxDecoration(
                gradient: isAI
                    ? LinearGradient(colors: [
                        BrokaColors.gold.withOpacity(0.10),
                        BrokaColors.bgCard,
                      ])
                    : const LinearGradient(
                        colors: [BrokaColors.gold, BrokaColors.goldDim]),
                borderRadius: isAI
                    ? const BorderRadius.only(
                        topLeft: Radius.circular(4),
                        topRight: Radius.circular(14),
                        bottomLeft: Radius.circular(14),
                        bottomRight: Radius.circular(14))
                    : const BorderRadius.only(
                        topLeft: Radius.circular(14),
                        topRight: Radius.circular(4),
                        bottomLeft: Radius.circular(14),
                        bottomRight: Radius.circular(14)),
                border: Border.all(color: isAI
                    ? BrokaColors.gold.withOpacity(0.3)
                    : BrokaColors.gold.withOpacity(0.4)),
              ),
              child: Text(message.content,
                  style: const TextStyle(color: BrokaColors.textHigh,
                      fontSize: 14, height: 1.5)),
            ),
          ),
        ],
      ),
    );
  }
}
