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
//
// 2026-09-27: assistant mode became Zeno as an assistant that acts - open a
// screen, search, hand a request to the Buying Agent, open a chat, place a
// call after a tap - through POST /zeno/assistant/turn
// (features/zeno_assistant/), and its microphone opens a full-screen voice
// mode instead of the compact card. See ZENO_ACTIONS.md.
//
// Then Zeno stayed: assistant voice mode belongs to the app now, not this
// screen (features/zeno_assistant/zeno_session.dart). "Open my dashboard"
// opens it with Zeno still listening in a pill over it; what is said there
// comes back into this conversation (ZenoSessionChat below). Zeno can also
// guide - "how do I open a store?" - with steps built from the user's own
// account, each a tap from where it is done.
//
// Later the same day, the Buying Agent got motion that shows it working
// (features/buy_agent/presentation/widgets/agent_motion.dart): an animated
// core before the first message, what Zeno has gathered as a live "brief"
// under the header, a radar card while it searches, results as a deck of
// cards to swipe through instead of a 210px column each, and a watch that
// switches on with a burst. The same pass fixed the screen's weak spots -
// see CHANGES.md and test/buy_agent_ui_test.dart.
//
// 2026-09-29: a listing's "Ask Zeno" card opens the assistant about that
// listing (aboutListing): pinned under the header, its id sent with every
// turn so the server can read it to Zeno, suggestions about it, and its own
// saved conversation. When it doesn't fit what the buyer wants, Zeno offers
// a search - a card with a button, not a search that just happens.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/broka_tts.dart';
import '../services/photo_capture.dart';
import '../services/realtime_stt.dart';
import '../services/zeno_chat_store.dart';
import '../services/zeno_voice_controller.dart';
import '../widgets/zeno_voice_card.dart';
import '../main.dart';
import '../widgets/broka_image.dart';
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
import '../features/buy_agent/presentation/widgets/agent_motion.dart';
import '../features/premium/presentation/premium_upsell.dart';
import '../features/safe_payment/payments_shown.dart';
import '../features/zeno_assistant/data/zeno_assistant_repository.dart';
import '../features/zeno_assistant/domain/zeno_about_listing.dart';
import '../features/zeno_assistant/domain/zeno_action.dart';
import '../features/zeno_assistant/presentation/zeno_action_card.dart';
import '../features/zeno_assistant/zeno_action_runner.dart';
import '../features/zeno_assistant/zeno_session.dart';
import '../features/zeno_assistant/zeno_tour.dart' show isTourRequest;
import '../features/listings/domain/models/listing.dart';
import '../theme/motion.dart';
import '../utils/price_format.dart';

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

  /// Set on a reply that never came: the message to send again.
  final String? retry;

  /// The assistant: what Zeno is doing, or offering to do, with this reply.
  final ZenoAction? action;

  /// A photo the user showed Zeno with this message. Kept for this visit
  /// only: a conversation picked up later shows that a photo was sent, not
  /// the photo (SharedPreferences holds every value in memory).
  final Uint8List? photo;

  /// With [retry]: the photo to send again.
  final Uint8List? retryPhoto;

  /// Replies the user can tap instead of typing, and a link to open - the
  /// escrow walkthrough's "Done - what's next?" and "Open E-Confirm". For
  /// the newest reply, this visit: an old "Done" chip tapped after the
  /// conversation moved on would answer a question nobody is asking.
  final List<String> suggestions;
  final ZenoLink? link;
  const _Turn(this.message,
      {this.matches = const [], this.retry, this.action, this.photo, this.retryPhoto,
       this.suggestions = const [], this.link});
}

/// What a photo turn reads as in the saved conversation and in the
/// context sent with later turns, where the photo itself is not.
String _withPhotoNote(String text) => text.isEmpty ? '📷 Photo' : '📷 $text';

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

  /// Asking Zeno to walk you through paying with escrow. BROKA holds no
  /// payments, and Zeno guides a buyer or seller through an escrow service
  /// step by step (backend zeno_assistant/escrow_walkthrough.py) - free,
  /// no model call, for this exact text. The opener chip, and every
  /// "Ask Zeno" beside escrow, send it.
  static const escrowOpener = 'Help me pay with escrow';

  /// Something the user already said elsewhere, sent as their first turn
  /// the moment the screen opens: the Buying Agent's query from Home's
  /// search bar, or a question tapped on a listing's "Ask Zeno" card.
  final String? initialQuery;

  /// Assistant only: the listing the user opened Zeno from, to ask about.
  final ZenoAboutListing? aboutListing;

  /// False renders the constellation as one still frame - for tests.
  final bool animateBackground;

  /// Assistant only: open straight into voice mode - a long press on the
  /// Zeno tab, the way holding a phone's side button wakes its assistant.
  final bool startInVoice;

  /// The speech provider voice uses. Tests pass a fake; the app leaves it
  /// null for the real one (RealtimeSttManager).
  final RealtimeSttProvider? voiceService;

  /// Where the photo button gets a photo. Tests pass bytes; the app leaves
  /// it null for BROKA's camera or the gallery (PhotoCapture).
  final Future<Uint8List?> Function(BuildContext context)? photoPicker;

  const ZenoScreen({
    super.key,
    this.mode = ZenoMode.assistant,
    this.initialQuery,
    this.aboutListing,
    this.animateBackground = true,
    this.startInVoice = false,
    @visibleForTesting this.voiceService,
    @visibleForTesting this.photoPicker,
  });

  @override
  State<ZenoScreen> createState() => _ZenoScreenState();
}

class _ZenoScreenState extends State<ZenoScreen>
    with SingleTickerProviderStateMixin
    implements ZenoSessionChat {
  final _msgCtrl    = TextEditingController();

  // Composer state - mirrors negotiation_screen.dart so both conversation
  // surfaces behave identically.
  final FocusNode _composerFocus = FocusNode();
  bool _hasDraft = false;
  bool _composerFocused = false;

  /// A photo waiting in the composer to go with the next message.
  Uint8List? _photo;
  final _scrollCtrl = ScrollController();
  bool _typing      = false;
  final List<_Turn> _turns = [];
  final List<Map<String, String>> _history = [];

  /// Replies that have just arrived and are still being written out, word
  /// by word. Anything restored from earlier is simply there.
  final Set<_Turn> _fresh = Set.identity();

  /// Bubbles that have just been added, for their entrance, and result
  /// turns whose cards have not been dealt yet. Each is cleared after its
  /// first frame, so scrolling a bubble away and back doesn't replay it.
  final Set<_Turn> _arriving = Set.identity();
  final Set<_Turn> _dealing = Set.identity();

  /// Which conversation this is. "New chat" moves it on, and a reply that
  /// comes back for an earlier one is dropped: it used to land in the new
  /// conversation, bringing the old one's criteria with it.
  int _epoch = 0;

  /// Goes up for each confetti burst - an exact match, a watch set.
  int _confetti = 0;

  /// When the watch was set in this visit, so its card bursts once as it
  /// turns on - and not on a conversation picked up again later.
  DateTime? _watchSetAt;

  // ── The assistant's actions ────────────────────────────────────────────────
  // Where each of Zeno's actions has got to, and which person the user
  // picked when "call Mary" fitted more than one. Neither is saved: an
  // action belongs to the moment it was offered, and a call confirmation
  // coming back days later would be a trap.
  final Map<_Turn, ZenoActionPhase> _actionPhase = Map.identity();
  final Map<_Turn, ZenoAction> _chosen = Map.identity();

  /// Zeno's session, when the app has one (ZenoSessionHost): the
  /// assistant's voice mode, which outlives this screen.
  ZenoSession? _session;

  bool get _isBuying => widget.mode == ZenoMode.buyingAgent;

  /// The listing this conversation is about, when opened from one.
  ZenoAboutListing? get _about => _isBuying ? null : widget.aboutListing;

  /// ZenoChatStore's key for this mode's conversation. Questions about a
  /// listing are kept apart from the general assistant's conversation:
  /// "is it still available?" means nothing in the other one.
  String get _storeMode => _isBuying ? 'buying' : (_about != null ? 'listing' : 'assistant');

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
  // A Timer, not a Future.delayed: the delay has to be cancellable. The
  // Future could not be, so a quick turn's delay fired into the NEXT turn
  // and announced a search 2.2s after the earlier message.
  Timer? _searchDelay;

  /// The longest Zeno's current reply may keep voice mode "speaking" - see
  /// _speak.
  Timer? _speakCap;

  /// Replies this screen is reading aloud.
  int _saying = 0;
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

  static List<(String, String)> get _assistantSuggestions => [
    // First, because it is what a first deal needs most - while payments
    // are shown at all (payments_shown.dart).
    if (paymentsShown) ('🛡️', ZenoScreen.escrowOpener),
    ('🚗', 'Is KES 800K fair for a Toyota Axio 2012?'),
    ('🏪', 'How do I open an online store?'),
    ('⭐', 'What do you think of my rating?'),
    ('🤝', 'Tips to close a deal faster'),
    ('🔍', 'How do I spot a fake listing?'),
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

  /// About the listing it was opened from - the questions a buyer has
  /// before they start negotiating, and the way out when it doesn't fit.
  List<(String, String)> get _listingSuggestions => [
        ('💰', 'Is this a fair price?'),
        if (paymentsShown) ('🛡️', ZenoScreen.escrowOpener),
        ('⭐', 'Is this seller reliable?'),
        ('🔍', 'What should I check before buying?'),
        if (_about?.delivers != false) ('🚚', 'Can it be delivered to me?'),
        if (_about?.negotiable ?? true) ('🤝', 'What offer should I make?'),
        ('🔄', 'Find me something similar'),
      ];

  List<(String, String)> get _suggestions => _isBuying
      ? _buyingSuggestions
      : (_about != null ? _listingSuggestions : _assistantSuggestions);

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
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Not about a listing: the session's turns carry no listing, so a
    // question asked through it would reach Zeno without the listing it
    // is about. Voice here is the screen's own card, through _send.
    if (_session == null && !_isBuying && _about == null) {
      _session = ZenoSession.maybeOf(context);
      _session?.attachChat(this);
    }
  }

  @override
  void dispose() {
    _session?.detachChat(this);
    _msgCtrl.dispose();
    _composerFocus.dispose();
    _scrollCtrl.dispose();
    _pulseCtrl.dispose();
    _searchTicker?.cancel();
    _searchDelay?.cancel();
    _speakCap?.cancel();
    // Only this screen's own reply: Zeno's tour narrates over the Buying
    // Agent and moves on, and closing the screen under it must not cut
    // the next line off.
    if (_saying > 0) _tts.stop();
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
    var saved = fresh ? null : await ZenoChatStore.load(_storeMode);
    // Questions about another listing are another conversation.
    if (_about != null && saved?.aboutListing != _about!.id) saved = null;
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
    if (_isBuying && _watching) _checkWatchStillOn();
    // A question tapped on the listing joins its conversation - and so
    // does one asked from elsewhere ("Let Zeno guide me" on the escrow
    // screen), which used to be dropped: only the Buying Agent and a
    // listing's questions were ever sent.
    if (initial.isNotEmpty) _send(initial);
    if (widget.startInVoice && !_isBuying) _openVoice();
  }

  /// "Watching" is remembered on the phone, but the watch itself lives on
  /// the server, and may have been stopped from Home or run out since. Zeno
  /// went on saying it was keeping watch - and offered nothing to start
  /// another. Only a definite "none running" clears it: offline says
  /// nothing either way.
  Future<void> _checkWatchStillOn() async {
    final epoch = _epoch;
    final result = await buyAgentRepository.getActive();
    if (!mounted || epoch != _epoch) return;
    if (result.isSuccess && result.data == null) {
      setState(() => _watching = false);
      _persist();
    }
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
              content: t.photo != null ? _withPhotoNote(t.message.content) : t.message.content,
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
        aboutListing: _about?.id,
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
    // Before the await below, so a reply arriving meanwhile is already
    // for an old conversation.
    _epoch++;
    _setSearching(false);
    await ZenoChatStore.clear(_storeMode);
    if (!mounted) return;
    setState(() {
      _turns.clear();
      _fresh.clear();
      _arriving.clear();
      _dealing.clear();
      _history.clear();
      _slots = {};
      _questionsAsked = 0;
      _lastVerdict = null;
      _watching = false;
      _watchSetAt = null;
      _actionPhase.clear();
      _chosen.clear();
      // A reply still on its way belongs to the old conversation; this one
      // can start at once.
      _typing = false;
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
      service: widget.voiceService,
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

    final about = _about;
    if (about != null) {
      final ask = switch (_langKey) {
        'swahili' => 'Habari$greet! Niulize chochote kuhusu "${about.name}" - bei, muuzaji, usafirishaji, au kama kinakufaa. Kisipokufaa, nitakutafutia kingine.',
        _ => 'Hi$greet! Ask me anything about "${about.name}" - the price, the seller, delivery, or whether it fits what you need. If it doesn\'t, I\'ll find you something that does.',
      };
      _turns.add(_Turn(Message(role: 'broker', content: ask)));
      return;
    }

    final welcomeMsg = switch (_langKey) {
      'swahili' => 'Habari$greet! Mimi ni Zeno, mshauri wako wa biashara wa BROKA. Ninaweza kukusaidia kutathmini bei, kugundua udanganyifu, au kupanga mkakati wa mazungumzo. Niulize chochote! 🤝',
      'luo'     => 'Misawa$greet! An Zeno, jakony mar ohala mar BROKA. Anyalo konyi nyiso nengo maber, neno wach miriambo, kata loso hera. Penj gimoro amora! 🤝',
      'kikuyu'  => 'Wĩmwega$greet! Nĩ niĩ Zeno, mũteithia waku wa biashara wa BROKA. Ngũkuteithia gũthagania thaara, gwĩkira mahinda ma mũrũgamo, kana gũtheria wĩhĩo. Ĩũlĩria kĩndũ kĩothe! 🤝',
      _ when paymentsShown => 'Hello$greet! I\'m Zeno, your BROKA marketplace AI assistant. I can help you evaluate prices, spot suspicious listings and plan your negotiation - and when it\'s time to pay, I\'ll walk you through paying safely with an escrow service, step by step. Ask me anything! 🤝',
      _         => 'Hello$greet! I\'m Zeno, your BROKA marketplace AI assistant. I can help you evaluate prices, spot suspicious listings and plan your negotiation. Ask me anything! 🤝',
    };
    _turns.add(_Turn(Message(role: 'broker', content: welcomeMsg)));
  }

  /// Adds a bubble that should arrive rather than just be there.
  void _addArriving(_Turn turn, {bool writing = false}) {
    _turns.add(turn);
    _arriving.add(turn);
    if (writing) _fresh.add(turn);
    WidgetsBinding.instance.addPostFrameCallback((_) => _arriving.remove(turn));
  }

  /// [photoOverride]: a failed photo turn's photo, sent again.
  Future<void> _send([String? override, Uint8List? photoOverride]) async {
    final text = (override ?? _msgCtrl.text).trim();
    // The composer's photo goes with a typed message, not with one sent on
    // the user's behalf (a suggestion, Home's query, a retry of text).
    final photo = override == null ? _photo : photoOverride;
    if ((text.isEmpty && photo == null) || _typing) return;
    _msgCtrl.clear();
    if (_photo != null && override == null) setState(() => _photo = null);
    // While Zeno's session is on, it is the one conversation: a typed turn
    // goes through it too, so its actions dock rather than end it, and its
    // replies aren't spoken twice. It comes back through sessionHeard.
    // A photo can't go that way - the session carries words.
    final session = _session;
    if (!_isBuying && photo == null && session != null && session.isActive) {
      unawaited(session.send(text));
      return;
    }
    // "Show me around": Zeno's tour of BROKA (zeno_tour.dart), which opens
    // the screens it talks about - no model needed to say "follow me".
    if (!_isBuying && _about == null && photo == null && session != null && isTourRequest(text)) {
      final reply = _langKey == 'swahili' || _langKey == 'sheng'
          ? 'Twende - nifuate!'
          : "Let's go - follow me!";
      setState(() {
        _addArriving(_Turn(Message(role: 'user', content: text)));
        _addArriving(_Turn(Message(role: 'broker', content: reply)));
      });
      _history
        ..add({'role': 'user', 'content': text})
        ..add({'role': 'assistant', 'content': reply});
      _persist();
      session.startTour();
      return;
    }
    setState(() {
      _addArriving(_Turn(Message(role: 'user', content: text), photo: photo));
      _typing = true;
    });
    _scrollDown();
    // Taken BEFORE this message joins _history: both endpoints receive the
    // new message on its own and add it after the history themselves, so
    // sending it in both put every message into Zeno's context twice.
    final context20 = _recentHistory(20);
    final context40 = _recentHistory(40);
    _history.add({'role': 'user', 'content': photo != null ? _withPhotoNote(text) : text});
    _persist();
    final epoch = _epoch;

    if (_isBuying) {
      await _sendBuyingTurn(text, context40, epoch);
      return;
    }

    // The assistant: a reply, and maybe something to do. Typed or spoken,
    // it is the same turn; voice only asks for a reply that reads aloud.
    final result = await zenoAssistantRepository.turn(
      // A photo on its own still asks something - and a server from before
      // photos refuses an empty message.
      message: text.isEmpty && photo != null ? 'What can you tell me about this?' : text,
      history: context20,
      language: _langKey,
      voice: _voice.isOpen,
      listingId: _about?.id,
      imageBase64: photo != null ? base64Encode(photo) : null,
    );
    if (!mounted || epoch != _epoch) return;
    switch (result) {
      case Success(:final data):
        final reply = data.reply.isEmpty && data.action != null
            ? ZenoActionRunner.label(data.action!)
            : data.reply;
        _history.add({'role': 'assistant', 'content': reply});
        final turn = _Turn(Message(role: 'broker', content: reply), action: data.action,
            suggestions: data.suggestions, link: data.link);
        setState(() {
          // A reply that opens a screen is shown whole, not written out word
          // by word: it is a confirmation, and the screen is what the user
          // is waiting for.
          _addArriving(turn, writing: data.action == null || !data.action!.runsByItself);
          if (data.action != null) _actionPhase[turn] = ZenoActionPhase.pending;
          _typing = false;
        });
        _persist();
        unawaited(_afterReply(turn, epoch));
      case Failure(:final message, statusCode: 402):
        // Voice mode needs a plan, or this month's voice requests are used.
        // Not a retry: the same sentence would be refused again. The
        // microphone closes, and the plans are one tap away.
        setState(() {
          _addArriving(_Turn(Message(role: 'broker', content: message)));
          _typing = false;
        });
        _history.removeLast();
        await _endVoice();
        if (mounted) await showPremiumUpsell(context, message: message);
      case Failure(:final message, statusCode: 422) when photo != null:
        // The server couldn't use the photo (not an image, damaged) - its
        // message says so. Sending the same file again won't help.
        setState(() {
          _addArriving(_Turn(Message(role: 'broker', content: '⚠️ $message')));
          _typing = false;
        });
        _history.removeLast();
      case Failure():
        _turnFailed(text, '⚠️ Zeno is unavailable right now. Please try again shortly.',
            photo: photo);
    }
    _scrollDown();
  }

  /// The photo button: BROKA's camera or the gallery, the way listing and
  /// chat photos are taken (PhotoCapture). The photo waits in the composer
  /// until it is sent, with or without a question.
  Future<void> _attachPhoto() async {
    if (_typing) return;
    final Uint8List? bytes;
    final picker = widget.photoPicker;
    if (picker != null) {
      bytes = await picker(context);
    } else {
      final source = await PhotoCapture.askSource(context);
      if (source == null || !mounted) return;
      final file = await (source == PhotoSource.camera
          ? PhotoCapture.takePhoto(context,
              hint: 'Show Zeno the item clearly, in good light.')
          : PhotoCapture.pickFromGallery(context));
      bytes = file == null ? null : await file.readAsBytes();
    }
    if (bytes == null || !mounted) return;
    setState(() => _photo = bytes);
  }

  // ── The assistant's actions ────────────────────────────────────────────────

  ZenoAction? _actionOf(_Turn turn) => _chosen[turn] ?? turn.action;

  /// After Zeno's reply is on screen: say it, and do what it said.
  ///
  /// The screen changes on a short beat, not when Zeno finishes the
  /// sentence: "Opening your inbox" carries on over the inbox sliding in,
  /// the way a phone's assistant does it. Waiting for the voice would hang
  /// the command on the voice service - its fetch alone can take seconds.
  /// Voice mode gets a longer beat, so the orb and the action card land
  /// before the screen goes.
  Future<void> _afterReply(_Turn turn, int epoch) async {
    final voice = _voice.isOpen;
    final action = turn.action;
    if (_ttsEnabled && turn.message.content.isNotEmpty) unawaited(_speak(turn.message.content));
    if (action == null || !action.runsByItself) return;
    await Future<void>.delayed(Duration(milliseconds: voice ? 1100 : 750));
    if (!mounted || epoch != _epoch || _actionPhase[turn] != ZenoActionPhase.pending) return;
    await _runAction(turn);
  }

  /// Opens the screen, search or chat [turn] asked for.
  Future<void> _runAction(_Turn turn) async {
    final action = _actionOf(turn);
    if (action == null) return;
    setState(() => _actionPhase[turn] = ZenoActionPhase.running);
    // Leaving this screen: the microphone must not come along.
    if (_voice.isOpen) {
      await Future<void>.delayed(const Duration(milliseconds: 380));
      await _endVoice();
    }
    if (!mounted) return;
    final ok = await ZenoActionRunner.run(context, action);
    if (!mounted) return;
    setState(() => _actionPhase[turn] = ok ? ZenoActionPhase.done : ZenoActionPhase.dismissed);
  }

  /// The user tapped Call. The only way a call starts from Zeno.
  Future<void> _confirmCall(_Turn turn) async {
    final action = _actionOf(turn);
    final who = action?.target;
    if (action == null || who == null) return;
    setState(() => _actionPhase[turn] = ZenoActionPhase.running);
    unawaited(_tts.stop());
    // The call needs the microphone this session - or Zeno's - is holding.
    _session?.end();
    if (_voice.isOpen) await _endVoice();
    if (!mounted) return;
    final ok = await ZenoActionRunner.call(context, who, video: action.video);
    if (!mounted) return;
    // Failed to start: offer it again rather than pretend it happened.
    setState(() => _actionPhase[turn] = ok ? ZenoActionPhase.done : ZenoActionPhase.pending);
  }

  void _choose(_Turn turn, ZenoContact who) {
    final action = turn.action;
    if (action == null) return;
    setState(() => _chosen[turn] = action.choose(who));
    // A chat just opens; a call still asks.
    if (action.type != ZenoActionType.call) _runAction(turn);
  }

  void _dismissAction(_Turn turn) =>
      setState(() => _actionPhase[turn] = ZenoActionPhase.dismissed);

  Widget _actionCard(_Turn turn, {bool large = false}) {
    final action = _actionOf(turn)!;
    final phase = _actionPhase[turn] ?? ZenoActionPhase.done;
    return ZenoActionCard(
      key: ObjectKey(action),
      action: action,
      phase: phase,
      large: large,
      onConfirm: action.type == ZenoActionType.call
          ? () => _confirmCall(turn)
          // An offered search, taken: it runs, and its card follows it.
          : (action.isOffer && _actionPhase[turn] == ZenoActionPhase.pending
              ? () => _runAction(turn)
              : () => ZenoActionRunner.run(context, action)),
      onDismiss: () => _dismissAction(turn),
      onChoose: (who) => _choose(turn, who),
      onStep: (i) {
        final destination = action.guide?.steps[i].destination;
        if (destination != null) ZenoActionRunner.openDestination(Navigator.of(context), destination);
      },
    );
  }

  /// Ends the voice session before something else needs the screen or the
  /// microphone.
  ///
  /// Bounded: close() clears everything on screen at once, but its socket
  /// teardown can wait on a close handshake that never comes (a dead
  /// socket - the controller says so), and "open my inbox" must not hang
  /// on it. The recorder is released in close()'s first steps; a moment is
  /// enough for it, and the rest finishes on its own.
  Future<void> _endVoice() => _voice.close().timeout(
        const Duration(milliseconds: 600),
        onTimeout: () {},
      );

  /// A turn whose reply never came. The error carries the message, so
  /// "Try again" needs nothing retyped. Not saved - as before, a failure
  /// is not part of the conversation to come back to.
  void _turnFailed(String text, String error, {Uint8List? photo}) {
    setState(() {
      _addArriving(_Turn(Message(role: 'broker', content: error),
          retry: text, retryPhoto: photo));
      _typing = false;
    });
  }

  /// Sends a failed message again. The unanswered exchange - the message
  /// and the error under it - makes way for the new attempt, and the
  /// message comes out of the context first: left in, the retry put it in
  /// front of Zeno twice.
  void _retry(_Turn failed) {
    final text = failed.retry;
    if (text == null || _typing || !identical(_turns.lastOrNull, failed)) return;
    setState(() {
      _turns.removeLast();
      final mine = _turns.lastOrNull;
      if (mine != null && mine.message.role == 'user' && mine.message.content == text) {
        _turns.removeLast();
      }
    });
    final sent = failed.retryPhoto != null ? _withPhotoNote(text) : text;
    final h = _history.lastIndexWhere((e) => e['role'] == 'user' && e['content'] == sent);
    if (h != -1) _history.removeAt(h);
    _send(text, failed.retryPhoto);
  }

  /// One turn of the buying conversation.
  ///
  /// The screen does not decide whether this is a question or a search -
  /// the server does, and returns whichever it ran. That keeps the question
  /// budget, the criteria and the honesty of the result in one place
  /// instead of split across a client that could drift out of step with it.
  Future<void> _sendBuyingTurn(String text, List<Map<String, String>> history, int epoch) async {
    // When the caption appears, and why it is a guess rather than a fact:
    // only the server knows whether this turn is a question or a search,
    // and it says so in the response - which arrives at the END. Two
    // signals stand in for it. The question budget is exhausted (the server
    // will search, guaranteed - see conversation.MAX_QUESTIONS), so show it
    // at once; otherwise wait, because a question is one model call and a
    // search is two plus a ranked scan, so anything still running after a
    // couple of seconds is almost certainly the search. A turn that
    // resolves quickly never shows it at all.
    _searchDelay?.cancel();
    if (_questionsAsked >= 2) {
      _setSearching(true);
    } else {
      _searchDelay = Timer(const Duration(milliseconds: 2200), () {
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
    // An answer for a conversation that has since been started over. It
    // must not touch this one - not even to stop its "searching" caption,
    // which may belong to a search the new conversation is running.
    if (!mounted || epoch != _epoch) return;
    _setSearching(false);

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
          _addArriving(turn, writing: true);
          if (matches.isNotEmpty) _dealing.add(turn);
          _typing = false;
        });
        _persist();
        if (_ttsEnabled && reply.isNotEmpty) _speak(reply);
      },
      onFailure: (msg, code) => _turnFailed(
        text,
        code == 429
            ? "I need a moment — that's a lot of searching at once. Try me again shortly."
            : "⚠️ I couldn't get that search through just now. Try me again in a moment.",
      ),
    );
    _scrollDown();
  }

  /// Starts and stops the staged "searching" caption. Cosmetic only - it is
  /// a timer, and says nothing about how far along the search really is, so
  /// it never claims a step has finished.
  void _setSearching(bool on) {
    _searchTicker?.cancel();
    if (!on) {
      _searchDelay?.cancel();
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
    // Bounded by how long the reply can take to say: while Zeno is
    // "speaking" the microphone is ignored, and a player that never reports
    // the end (a stuck platform channel) must not leave voice mode deaf. The
    // cap is a Timer the screen owns, so it goes with the screen.
    final words = text.split(RegExp(r'\s+')).length;
    final done = Completer<void>();
    void finish() {
      if (!done.isCompleted) done.complete();
    }
    _speakCap?.cancel();
    _speakCap = Timer(Duration(milliseconds: (6000 + 450 * words).clamp(6000, 60000)), finish);
    _saying++;
    unawaited(_tts.speakToEnd(text, language: _langKey).whenComplete(finish));
    await done.future;
    _saying--;
    _speakCap?.cancel();
    if (!mounted) return;
    _voice.setZenoSpeaking(false);
  }

  /// Opens voice: the assistant's full-screen voice mode, which is Zeno's
  /// session and outlives this screen, or the Buying Agent's card. Guarded
  /// inside the controllers, so a double tap cannot open two sessions.
  void _openVoice() {
    final session = _session;
    if (!_isBuying && session != null) {
      session.start(service: widget.voiceService, muted: !_ttsEnabled);
      return;
    }
    _voice.open();
  }

  // ── ZenoSessionChat: the session's turns, in this conversation ────────────

  @override
  bool get isFrontmost => mounted && (ModalRoute.of(context)?.isCurrent ?? true);

  @override
  List<Map<String, String>> recentHistory(int count) => _recentHistory(count);

  @override
  void sessionHeard(String text) {
    if (!mounted) return;
    setState(() {
      _addArriving(_Turn(Message(role: 'user', content: text)));
      _typing = true;
    });
    _history.add({'role': 'user', 'content': text});
    _persist();
    _scrollDown();
  }

  @override
  void sessionAnswered(String reply, ZenoAction? action,
      {List<String> suggestions = const [], ZenoLink? link}) {
    if (!mounted) return;
    _history.add({'role': 'assistant', 'content': reply});
    setState(() {
      final turn = _Turn(Message(role: 'broker', content: reply), action: action,
          suggestions: suggestions, link: link);
      _addArriving(turn, writing: action == null || !action.runsByItself);
      // The session does it, over whatever screen is in front; here it is
      // the record of what happened. A call or a guide stays live - they
      // wait for a tap, and this may be where the user gives it.
      if (action != null) {
        _actionPhase[turn] = action.runsByItself ? ZenoActionPhase.done : ZenoActionPhase.pending;
      }
      _typing = false;
    });
    _persist();
    _scrollDown();
  }

  @override
  void sessionFailed(String text) {
    if (!mounted) return;
    _turnFailed(text, '⚠️ Zeno is unavailable right now. Please try again shortly.');
    _scrollDown();
  }

  @override
  void focusComposer() {
    if (mounted) _composerFocus.requestFocus();
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
      // Zeno negotiating for a buyer is part of a plan: the refusal says
      // which, and the plans are one tap away.
      onFailure: (msg, code) => isPlanRefusal(code)
          ? showPremiumUpsell(context, message: msg)
          : ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg))),
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
    // The category first: a watch can't be made without one, and asking
    // for a budget only to refuse afterwards threw the answer away.
    if (_slots['category'] == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Tell me roughly what kind of thing it is first, and I can watch for it."),
      ));
      return;
    }
    var maxPrice = (_slots['max_price'] as num?)?.toDouble();
    if (maxPrice == null) {
      maxPrice = await _askBudget();
      if (maxPrice == null || !mounted) return;
      // setState: the brief under the header shows the budget.
      setState(() => _slots['max_price'] = maxPrice);
    }

    final epoch = _epoch;
    setState(() => _watchBusy = true);
    final result = await buyAgentRepository.watchFromSlots(
      _slots,
      lat: ApiService.currentUserLat,
      lng: ApiService.currentUserLng,
    );
    if (!mounted) return;
    setState(() => _watchBusy = false);
    // Started over meanwhile: the watch is set, and Home shows it, but this
    // conversation has nothing to say about it.
    if (epoch != _epoch) return;
    result.fold(
      onSuccess: (data) {
        if (data['status'] == 'SUCCESS') {
          setState(() {
            _watching = true;
            _watchSetAt = DateTime.now();
            _confetti++;
          });
          _persist();
        } else if (data['error_code'] == 'ACTIVE_REQUEST_EXISTS' && !replacing) {
          // One watch at a time. This used to tell the buyer to "cancel
          // that one from the home screen", which had no such control -
          // nothing in the app could stop a watch, so the first one was
          // the only one a buyer would ever get. Offer the swap right here.
          _offerToReplaceWatch();
        } else {
          final message = data['message'] as String? ?? "I couldn't set that watch up just now.";
          setState(() => _addArriving(_Turn(Message(role: 'broker', content: message))));
          _scrollDown();
          // Watches come with a plan (the action's FAILED shape carries the
          // plan refusal's code).
          if (data['error_code'] == 'PREMIUM_REQUIRED' || data['error_code'] == 'ALLOWANCE_USED') {
            showPremiumUpsell(context, message: message);
          }
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

  Future<double?> _askBudget() =>
      showDialog<double>(context: context, builder: (_) => const _BudgetDialog());

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
    final allExact = turn.matches.isNotEmpty &&
        turn.matches.every((m) => m is Map && m['match_is_exact'] == true);
    setState(() {
      // Everything asked for, found: that deserves more than a sentence.
      if (allExact) _confetti++;
    });
    // The cards are dealt on the frame they first appear, and only then.
    WidgetsBinding.instance.addPostFrameCallback((_) => _dealing.remove(turn));
    // Cards, or the offer to keep watching, have just appeared under the
    // reply - bring them into view.
    final offersWatch = _isBuying && _lastVerdict == 'EMPTY' && identical(turn, _turns.lastOrNull);
    if (turn.matches.isNotEmpty || offersWatch) _scrollDown();
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
    // The same constellation as Home and every screen reached from it.
    final conversation = ConstellationBackground(
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
          child: Stack(children: [
            Column(children: [
              _buildHeader(),
              if (_about != null) _buildListingStrip(_about!),
              // What Zeno has gathered, growing in under the header as
              // it learns it. No AnimatedSize under reduced motion: at a
              // zero duration it asserts that it was mutated in its own
              // layout.
              if (_isBuying)
                BrokaMotion.reduced(context)
                    ? AgentBriefStrip(slots: _slots)
                    : AnimatedSize(
                        duration: BrokaMotion.standard,
                        curve: BrokaMotion.enter,
                        alignment: Alignment.topCenter,
                        child: AgentBriefStrip(slots: _slots),
                      ),
              Expanded(child: _buildMessages()),
              if (_typing) (_searching ? _buildSearchingIndicator() : _buildTypingIndicator()),
              if (!_restoring && !_hasConversation) _buildSuggestions(),
              _buildInputBar(),
            ]),
            Positioned.fill(child: AgentConfetti(burst: _confetti)),
          ]),
        ),
      ),
    );
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      // Voice floats OVER the conversation rather than replacing it: the
      // conversation stays mounted, at its scroll position, with its history
      // intact, and closing voice puts the user back exactly where they were
      // (brief §33). The Buying Agent keeps the compact card; the assistant
      // gets the full-screen voice mode, where Zeno is talked to rather than
      // dictated to.
      //
      // The assistant's voice mode is not mounted here: it is Zeno's
      // session, over the whole app (ZenoSessionHost). Without one - a
      // screen tested on its own - the assistant uses the card as well.
      body: _isBuying || _session == null
          ? ZenoVoiceOverlay(controller: _voice, child: conversation)
          : conversation,
    );
  }

  /// What the header says Zeno is doing, and the colour of its dot.
  (String, Color) get _agentState {
    if (_about != null) return ('Asking about a listing', BrokaColors.neonGreen);
    if (!_isBuying) return ('AI Market Assistant', BrokaColors.neonGreen);
    if (_searching) return ('Hunting…', BrokaColors.neonCyan);
    if (_typing) return ('Thinking…', BrokaColors.neonPurple);
    if (_watching) return ('On watch', BrokaColors.success);
    return ('Buying Agent', BrokaColors.neonGreen);
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
        // The Buying Agent's Zeno is the one Home's CTA flies into: in a
        // ring that turns faster while it works.
        if (_isBuying)
          AgentOrb(size: 36, heroTag: kBuyingAgentHeroTag, busy: _typing)
        else
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
              // The agent's state, not only that it is online: the dot
              // takes the colour of what it is doing and breathes while it
              // is busy.
              AnimatedBuilder(
                animation: _pulseCtrl,
                builder: (_, __) {
                  final busy = _isBuying && _typing;
                  return Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _agentState.$2.withOpacity(busy ? 0.4 + 0.6 * _pulseCtrl.value : 1),
                      boxShadow: busy
                          ? [BoxShadow(color: _agentState.$2.withOpacity(0.6), blurRadius: 6)]
                          : null,
                    ),
                  );
                },
              ),
              const SizedBox(width: 5),
              Flexible(
                child: AnimatedSwitcher(
                  duration: BrokaMotion.quick,
                  layoutBuilder: (current, previous) => Stack(
                      alignment: Alignment.centerLeft,
                      children: [...previous, if (current != null) current]),
                  child: Text(
                    '${_agentState.$1} · ${lang.flag} ${lang.name}',
                    key: ValueKey(_agentState.$1),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: BrokaColors.textMid, fontSize: 11.5),
                  ),
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

  /// The listing being asked about, pinned under the header: what it is,
  /// its price, and the two terms buyers ask about first - the listing
  /// screen's deal terms, shortened, in its colours.
  Widget _buildListingStrip(ZenoAboutListing l) {
    final fallback = Container(
      color: BrokaColors.bgMid,
      alignment: Alignment.center,
      child: Text(l.emoji, style: const TextStyle(fontSize: 20)),
    );
    return Padding(
      key: const Key('zeno-about-listing'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          gradient: BrokaColors.cardGradient,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: BrokaColors.neonPurple.withOpacity(0.4)),
        ),
        child: Row(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: 44,
              height: 44,
              child: l.photo == null
                  ? fallback
                  : BrokaImage(l.photo, width: 44, height: 44, placeholder: fallback),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(l.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: BrokaColors.textHigh, fontSize: 13.5, fontWeight: FontWeight.w700)),
              const SizedBox(height: 3),
              Row(children: [
                Flexible(
                  child: Text(l.priceLabel,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: BrokaColors.neonCyan, fontSize: 12.5, fontWeight: FontWeight.w800)),
                ),
                const SizedBox(width: 8),
                _term(l.negotiable ? 'Negotiable' : 'Fixed price',
                    l.negotiable ? BrokaColors.neonGreen : BrokaColors.neonPink),
                if (l.delivers != null) ...[
                  const SizedBox(width: 6),
                  _term(l.delivers! ? 'Delivers' : 'Pickup', l.delivers! ? BrokaColors.neonBlue : BrokaColors.warning),
                ],
              ]),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _term(String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withOpacity(0.4)),
        ),
        child: Text(label,
            style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w700)),
      );

  Widget _buildMessages() {
    // In the Buying Agent the list's first row is the agent's core. It is
    // always there, collapsing to nothing once the conversation starts, so
    // no bubble's row - and the state of a reply being written in it - ever
    // shifts by one.
    final lead = _isBuying ? 1 : 0;
    // Which turn's cards may fly into the product screen: the newest one
    // holding each listing. Two searches often return the same listing, and
    // two Heroes with one tag on a screen is an assertion the moment either
    // is tapped - and, in a release build, a photo flying from the wrong one.
    final heroTurn = <String, _Turn>{};
    for (final t in _turns.reversed) {
      for (final m in t.matches) {
        if (m is Map && m['id'] is String) heroTurn.putIfAbsent(m['id'] as String, () => t);
      }
    }
    return ListView.builder(
      controller: _scrollCtrl,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      itemCount: _turns.length + lead,
      itemBuilder: (_, index) {
        if (index < lead) return _buildCore();
        final i = index - lead;
        final turn = _turns[i];
        final isLast = i == _turns.length - 1;
        // What Zeno found comes after Zeno has said so, not under a sentence
        // still being written.
        final writing = _fresh.contains(turn);
        final bubble = AgentEntrance(
          play: _arriving.contains(turn),
          fromUser: !turn.message.isBroker,
          child: _ZenoBubble(
            message: turn.message,
            photo: turn.photo,
            stream: writing,
            onStreamed: () => _streamed(turn),
            onGrow: _followStream,
          ),
        );
        if (turn.matches.isEmpty || writing) {
          // The offer to keep watching belongs on the last turn even when it
          // found nothing - an empty search is exactly when a standing watch
          // is worth the most.
          final offerWatch = _isBuying && isLast && _lastVerdict == 'EMPTY' && !writing;
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            bubble,
            if (turn.retry != null && isLast && !_typing) _buildRetry(turn),
            if (offerWatch) _buildWatchOffer(),
            // What Zeno is doing, or asking to do - after it has said so.
            if (_actionOf(turn) != null && !writing)
              Padding(
                padding: const EdgeInsets.only(left: 36, bottom: 14),
                child: _actionCard(turn),
              ),
            if (isLast && !writing && !_typing && turn.message.isBroker &&
                (turn.suggestions.isNotEmpty || turn.link != null))
              _buildReplyChips(turn),
          ]);
        }
        final exact = turn.matches.where((m) => m is Map && m['match_is_exact'] == true).length;
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          bubble,
          Padding(
            padding: const EdgeInsets.only(left: 36, bottom: 14),
            child: AgentMatchCarousel(
              key: ObjectKey(turn),
              count: turn.matches.length,
              exact: exact,
              dealIn: _dealing.contains(turn),
              itemBuilder: (_, k) {
                final match = (turn.matches[k] as Map).cast<String, dynamic>();
                return _buildMatchCard(match, hero: identical(heroTurn[match['id']], turn));
              },
            ),
          ),
          if (isLast) _buildWatchOffer(),
          const SizedBox(height: 4),
        ]);
      },
    );
  }

  /// The Buying Agent before anything has been asked: its core, and what it
  /// does. Collapses away as the first message goes.
  Widget _buildCore() {
    final show = !_restoring && !_hasConversation;
    return AnimatedSwitcher(
      duration: BrokaMotion.of(context, const Duration(milliseconds: 650)),
      switchInCurve: BrokaMotion.enter,
      switchOutCurve: BrokaMotion.exit,
      transitionBuilder: (child, a) => SizeTransition(
        sizeFactor: a,
        axisAlignment: -1,
        child: FadeTransition(
          opacity: a,
          child: ScaleTransition(scale: Tween(begin: 0.7, end: 1.0).animate(a), child: child),
        ),
      ),
      child: show
          ? AgentCoreHero(
              key: const ValueKey('core'),
              orbit: [for (final s in _buyingSuggestions) s.$1],
              subtitle: "Tell me what you're after. I'll ask a question or two, "
                  'hunt it down across BROKA, and negotiate with the seller for you.',
            )
          : const SizedBox(key: ValueKey('none'), width: double.infinity),
    );
  }

  Widget _buildRetry(_Turn turn) => Padding(
    padding: const EdgeInsets.only(left: 36, bottom: 12),
    child: SizedBox(
      width: 150,
      child: AgentActionButton(
        label: 'Try again',
        icon: Icons.refresh_rounded,
        onTap: () => _retry(turn),
      ),
    ),
  );

  /// One result, with what it falls short on stated on its face.
  ///
  /// Design v2 §23 rules out invented match percentages, and the score this
  /// is ordered by is not a calibrated probability of anything - so what
  /// the buyer is shown is the concrete shortfall the backend measured
  /// ("8GB RAM, you wanted 12GB"), which is a fact about the listing, not a
  /// number about our confidence.
  ///
  /// A page of AgentMatchCarousel: the card takes what the fixed-height
  /// shortfall line and the button leave.
  Widget _buildMatchCard(Map<String, dynamic> match, {required bool hero}) {
    final listing = BrokaListing.fromJson(match);
    final misses = (match['match_misses'] as List?) ?? const [];
    final isExact = match['match_is_exact'] == true;
    final opened = _negotiationOpened.contains(listing.id);
    final busy = _negotiating.contains(listing.id);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Expanded(
        child: HeroMode(
          enabled: hero,
          child: ProductCard(
            item: listing,
            onTap: () => Navigator.pushNamed(
                context, '/product', arguments: {'listingId': listing.id}),
          ),
        ),
      ),
      const SizedBox(height: 8),
      SizedBox(
        height: 24,
        child: isExact
            ? const Row(children: [
                Icon(Icons.check_circle_rounded, size: 14, color: BrokaColors.success),
                SizedBox(width: 5),
                Flexible(
                  child: Text('Matches everything you asked for',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: BrokaColors.success, fontSize: 11.5,
                          fontWeight: FontWeight.w700)),
                ),
              ])
            // A second line of shortfalls is cut off rather than scrolled:
            // a sideways scroller inside a card you swipe sideways steals
            // the swipe.
            : Wrap(
                spacing: 6,
                runSpacing: 6,
                clipBehavior: Clip.hardEdge,
                children: [
                  for (final raw in misses.take(3))
                    if (raw is Map) _shortfallChip(raw.cast<String, dynamic>()),
                ],
              ),
      ),
      const SizedBox(height: 8),
      AgentActionButton(
        label: opened ? 'Zeno reached out — open chat' : 'Ask Zeno to negotiate this one',
        icon: opened ? Icons.forum_rounded : Icons.handshake_rounded,
        done: opened,
        busy: busy,
        onTap: opened
            ? () => Navigator.pushNamed(context, '/negotiate', arguments: {'listingId': listing.id})
            : (busy ? null : () => _startNegotiation(listing)),
      ),
    ]);
  }

  Widget _shortfallChip(Map<String, dynamic> miss) {
    final field = _prettyField(miss['field'] as String? ?? '');
    final wanted = miss['wanted']?.toString() ?? '';
    final actual = miss['actual']?.toString();
    final label = actual == null
        ? "$field not stated (you wanted $wanted)"
        : "$field $actual, you wanted $wanted";
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: BrokaColors.gold.withOpacity(0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: BrokaColors.gold.withOpacity(0.35)),
      ),
      child: Text(label,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
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
    final setAt = _watchSetAt;
    return Padding(
      padding: const EdgeInsets.only(left: 36, bottom: 14),
      child: AgentWatchOffer(
        watching: _watching,
        busy: _watchBusy,
        onWatch: _keepWatching,
        celebrate: setAt != null && DateTime.now().difference(setAt) < const Duration(seconds: 2),
      ),
    );
  }

  Widget _buildSearchingIndicator() => AgentScanCard(
    caption: _searchPhases[_searchPhase],
    step: _searchPhase,
    steps: _searchPhases.length,
  );

  Widget _buildTypingIndicator() => const Padding(
    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    child: AgentEntrance(play: true, fromUser: false, child: ZenoTypingBubble()),
  );

  /// Under Zeno's newest reply: the link it offers, then the replies the
  /// user can tap - each sent exactly as if typed, so the conversation
  /// and Zeno's context read the same either way.
  Widget _buildReplyChips(_Turn turn) {
    final link = turn.link;
    return Padding(
      padding: const EdgeInsets.only(left: 36, bottom: 14),
      child: Wrap(spacing: 8, runSpacing: 8, children: [
        if (link != null)
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [BrokaColors.neonGreen, BrokaColors.neonCyan]),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: () => _openLink(link),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Text(link.label, style: const TextStyle(color: BrokaColors.bg,
                        fontSize: 12.5, fontWeight: FontWeight.w800)),
                    const SizedBox(width: 6),
                    const Icon(Icons.open_in_new_rounded, size: 15, color: BrokaColors.bg),
                  ]),
                ),
              ),
            ),
          ),
        for (final s in turn.suggestions)
          Material(
            color: BrokaColors.bgCard.withOpacity(0.9),
            shape: StadiumBorder(side: BorderSide(color: BrokaColors.neonGreen.withOpacity(0.45))),
            child: InkWell(
              customBorder: const StadiumBorder(),
              onTap: () => _send(s),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                child: Text(s, style: const TextStyle(color: BrokaColors.textHigh,
                    fontSize: 12.5, fontWeight: FontWeight.w600)),
              ),
            ),
          ),
      ]),
    );
  }

  Future<void> _openLink(ZenoLink link) async {
    final opened = await launchUrl(link.url, mode: LaunchMode.externalApplication);
    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Open ${link.url.host} in your browser.')));
    }
  }

  /// Openers as chips floating over the constellation, like a Zone's
  /// subcategory rail - not a grey band across the screen. They fly in from
  /// the right one after another.
  Widget _buildSuggestions() => SizedBox(
    height: 50,
    child: ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      children: [
        for (final (i, s) in _suggestions.indexed)
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: BrokaMotion.of(context, const Duration(milliseconds: 900)),
            curve: Interval((0.1 * i).clamp(0.0, 0.5), 1.0, curve: Curves.easeOutBack),
            builder: (_, v, child) => Opacity(
              opacity: v.clamp(0.0, 1.0),
              child: Transform.translate(offset: Offset(60 * (1 - v), 0), child: child),
            ),
            child: Padding(
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
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              if (_photo != null) _buildStagedPhoto(_photo!),
              Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // The assistant can look at a photo; the Buying Agent's
                // conversation is about words (what you want, your budget).
                if (_isBuying)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 4, 14),
                    child: Icon(Icons.auto_awesome_rounded,
                        size: 18,
                        color: _composerFocused ? BrokaColors.neonBlue : BrokaColors.textMid),
                  )
                else
                  ChatComposerAction(
                    icon: Icons.add_photo_alternate_outlined,
                    tooltip: 'Show Zeno a photo',
                    onTap: _attachPhoto,
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
                          : (_about != null ? 'Ask about this listing' : 'Ask Zeno anything'),
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
                if (!_hasDraft && _photo == null)
                  InkResponse(
                    onTap: _openVoice,
                    radius: 22,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 13, 14, 13),
                      child: AnimatedBuilder(
                        animation: Listenable.merge([_voice, if (!_isBuying) _session]),
                        builder: (_, __) {
                          final on = _voice.isOpen || (!_isBuying && (_session?.listening ?? false));
                          return Icon(
                            on ? Icons.mic_rounded : Icons.mic_none_rounded,
                            size: 22,
                            color: on ? BrokaColors.neonBlue : BrokaColors.textMid,
                          );
                        },
                      ),
                    ),
                  ),
              ],
            ),
            ]),
          ),
        ),
        ChatSendButton(visible: _hasDraft || _photo != null, busy: _typing, onTap: () => _send()),
      ],
    ),
  );

  /// The photo waiting to go with the next message, with a way to take it
  /// back out.
  Widget _buildStagedPhoto(Uint8List photo) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Stack(clipBehavior: Clip.none, children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.memory(photo,
                  key: const Key('zeno-staged-photo'),
                  width: 72, height: 72, fit: BoxFit.cover, gaplessPlayback: true,
                  errorBuilder: (_, __, ___) => Container(
                      width: 72, height: 72, color: BrokaColors.bgMid,
                      child: const Icon(Icons.broken_image_rounded, color: BrokaColors.textLow))),
            ),
            Positioned(
              right: -8, top: -8,
              child: Material(
                color: BrokaColors.bgMid,
                shape: const CircleBorder(side: BorderSide(color: BrokaColors.border)),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => setState(() => _photo = null),
                  child: const Padding(
                    padding: EdgeInsets.all(4),
                    child: Icon(Icons.close_rounded, size: 14,
                        color: BrokaColors.textHigh, semanticLabel: 'Remove the photo'),
                  ),
                ),
              ),
            ),
          ]),
        ),
      );
}

// ── Zeno Chat Bubble ─────────────────────────────────────────────────────────
//
// Zeno's words on a dark card with a violet edge; yours on the brand
// gradient, like Home's Zeno CTA and every primary button in the app.
class _ZenoBubble extends StatelessWidget {
  final Message message;

  /// A photo the user showed Zeno with this message.
  final Uint8List? photo;

  /// A reply that has just arrived: written out word by word.
  final bool stream;
  final VoidCallback? onStreamed;
  final VoidCallback? onGrow;
  const _ZenoBubble({
    required this.message, this.photo, this.stream = false, this.onStreamed, this.onGrow,
  });

  static const _zenoCorners = BorderRadius.only(
      topLeft: Radius.circular(4),
      topRight: Radius.circular(16),
      bottomLeft: Radius.circular(16),
      bottomRight: Radius.circular(16));

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
            // A light runs round the edge of a reply while it is written.
            child: AgentLiveEdge(
              active: isAI && stream,
              borderRadius: _zenoCorners,
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
                      ? _zenoCorners
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
                    : _userContent(context),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

extension on _ZenoBubble {
  Widget _userContent(BuildContext context) {
    final text = Text(message.content,
        style: const TextStyle(color: Colors.white, fontSize: 14.5, height: 1.5));
    final shown = photo;
    if (shown == null) return text;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Image.memory(shown,
            key: const Key('zeno-sent-photo'),
            width: 200, height: 200, fit: BoxFit.cover, gaplessPlayback: true,
            errorBuilder: (_, __, ___) => const SizedBox(
                width: 200, height: 60,
                child: Icon(Icons.broken_image_rounded, color: Colors.white70))),
      ),
      if (message.content.isNotEmpty) ...[const SizedBox(height: 8), text],
    ]);
  }
}

// ── The budget question ──────────────────────────────────────────────────────
//
// Asked only when a watch needs a ceiling the conversation never set. Its
// own widget so the field's controller is disposed with the field - after
// the dialog's closing animation, not while it is still on screen. The
// field is the sell wizard's amount field (KesInputFormatter: digits only,
// grouped as typed), and an empty answer is answered: it used to close the
// dialog with no watch and no word, as if the button did nothing.
class _BudgetDialog extends StatefulWidget {
  const _BudgetDialog();

  @override
  State<_BudgetDialog> createState() => _BudgetDialogState();
}

class _BudgetDialogState extends State<_BudgetDialog> {
  final _ctrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _submit() {
    final v = parseKesInput(_ctrl.text);
    if (v == null || v <= 0) {
      setState(() => _error = 'Enter an amount, like 80,000.');
      return;
    }
    Navigator.pop(context, v);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        backgroundColor: BrokaColors.bgCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: BrokaColors.neonPurple.withOpacity(0.4)),
        ),
        title: const Text("What's your ceiling?",
            style: TextStyle(color: BrokaColors.textHigh, fontSize: 16, fontWeight: FontWeight.w800)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text("To keep watching I need a top price, so I only bring you things "
              "you'd actually consider.",
              style: TextStyle(color: BrokaColors.textMid, fontSize: 13)),
          const SizedBox(height: 12),
          TextField(
            controller: _ctrl,
            autofocus: true,
            keyboardType: TextInputType.number,
            inputFormatters: const [KesInputFormatter()],
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            onSubmitted: (_) => _submit(),
            style: const TextStyle(color: BrokaColors.textHigh, fontSize: 18, fontWeight: FontWeight.w700),
            decoration: InputDecoration(
              prefixText: 'KES ',
              prefixStyle: const TextStyle(color: BrokaColors.textMid),
              hintText: '80,000',
              hintStyle: const TextStyle(color: BrokaColors.textLow),
              errorText: _error,
            ),
          ),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context),
              child: const Text('Cancel', style: TextStyle(color: BrokaColors.textMid))),
          TextButton(
            onPressed: _submit,
            child: const Text('Watch for it', style: TextStyle(color: BrokaColors.gold)),
          ),
        ],
      );
}
