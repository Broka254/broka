import 'dart:async';
import 'dart:convert';
// BROKA - Negotiation Room  (v5 — full dispute state machine)
// Persistent chat history stored per listing_id.
// Zeno (role=='broker' on the wire) knows both buyer and seller by name.
// TTS reads broker responses aloud.
// Action buttons are driven entirely by the deal's DB state —
// never by parsing AI text — so the correct choices are always shown.
import 'package:flutter/material.dart';
import '../services/broka_tts.dart';
import '../services/zeno_voice_controller.dart';
import '../widgets/zeno_voice_card.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../main.dart';
import '../widgets/chat_parts.dart';
import '../widgets/collapsing_screen_header.dart';
import '../widgets/constellation_background.dart';
import '../services/api_service.dart';
import '../services/chat_screen_memory.dart';
import '../services/global_poller_service.dart';
import '../services/photo_capture.dart';
import '../models/models.dart';
import '../services/last_screen_tracker.dart';
import '../services/local_chat_store.dart';
import '../models/listing.dart';
import '../widgets/zeno_avatar.dart';
import '../widgets/zeno_streaming_text.dart';
import '../widgets/protection_badge.dart';
import '../widgets/units_stepper.dart';
import '../features/reviews/presentation/review_prompt.dart';
import '../utils/price_format.dart';
import '../features/escrow/presentation/escrow_actions.dart';

class NegotiateScreen extends StatefulWidget {
  const NegotiateScreen({super.key, this.animateBackground = true});

  /// False renders the constellation as one still frame - for tests.
  final bool animateBackground;

  @override
  State<NegotiateScreen> createState() => _NegotiateScreenState();
}

class _NegotiateScreenState extends State<NegotiateScreen> {
  final _msgCtrl    = TextEditingController();
  final _scrollCtrl = ScrollController();
  bool _typing      = false;
  /// Zeno's current action offer: {action, label, parameters, draft_text}.
  /// Null when nothing is proposed. Always rendered as a tap target -
  /// never executed automatically. See api/core/negotiation_actions.py.
  Map<String, dynamic>? _pendingAction;
  bool _initialized = false;
  List<Message> _messages = [];

  /// Zeno's replies that have just arrived and are still being written out,
  /// word by word. History and the offline cache are simply there.
  final Set<Message> _fresh = Set.identity();

  final _composerFocus = FocusNode();
  bool _hasDraft = false;
  bool _composerFocused = false;
  Listing? _listing;
  String _role = 'buyer';
  String? _buyerId;
  double? _currentOffer;
  Map<String, dynamic>? _sellerInfo;
  int    _dealProbability = 50;
  Timer? _heartbeatTimer;

  // TTS
  final _tts = BrokaTts.instance;
  bool _ttsEnabled = true;
  bool _speaking   = false;

  // STT
  // Voice input (Deepgram voice-card pass, 2026-09-18). Same shared card as
  // ZenoScreen, over this room's own conversation. It replaced
  // speech_to_text outright rather than sitting alongside it - see the note
  // in zeno_screen.dart on why two STT engines on one screen fight over the
  // microphone.
  //
  // Voice is only another way to enter a message here: a spoken
  // "tell the seller I can only pay eighteen thousand" becomes exactly the
  // message a typed one would, through the same _send(). The deal state
  // machine, the action bar, escrow controls, roles and the broker replies
  // are all untouched by this.
  late final ZenoVoiceController _voice;

  String get _myName     => ApiService.currentUserName ?? 'You';
  String get _myFirst    => _myName.split(' ').first;
  // Fallback follows the viewer's role. "Seller" shown to a seller was
  // both wrong and confusing - it reads as their own label, not the
  // person they're negotiating with.
  String get _counterName =>
      (_sellerInfo?['name'] as String?) ??
      (_role == 'seller' ? 'Buyer' : (_listing?.sellerName ?? 'Seller'));

  @override
  void initState() {
    super.initState();
    _msgCtrl.addListener(() {
      final has = _msgCtrl.text.trim().isNotEmpty;
      if (has != _hasDraft) setState(() => _hasDraft = has);
    });
    _composerFocus.addListener(
        () => setState(() => _composerFocused = _composerFocus.hasFocus));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_initialized) {
      _initialized = true;
      final args = ModalRoute.of(context)?.settings.arguments;
      if (args is Map) {
        final listingArg = args['listing'];
        if (listingArg is Listing) {
          _listing = listingArg;
        } else if (listingArg is Map<String, dynamic>) {
          _listing = Listing.fromJson(listingArg);
        } else if (listingArg is Map) {
          _listing = Listing.fromJson(Map<String, dynamic>.from(listingArg));
        }
        _role    = (args['role'] as String?) ?? 'buyer';
        _buyerId = args['buyer_id'] as String?;
        if (_role == 'buyer') _buyerId = ApiService.currentUserId;
        if (_listing == null && args['listingId'] is String) {
          _restoreFromListingId(args['listingId'] as String);
          return;
        }
      } else if (args is Listing) {
        _listing = args;
        _buyerId = _role == 'buyer' ? ApiService.currentUserId : null;
      }
      LastScreenTracker.save('/negotiate',
          {'listingId': _listing?.id, 'role': _role, 'buyer_id': _buyerId});
      _finishInit();
    }
  }

  Future<void> _restoreFromListingId(String listingId) async {
    try {
      final listing = await ApiService.getListing(listingId);
      if (!mounted) return;
      setState(() {
        _listing = listing;
        _buyerId ??= _role == 'buyer' ? ApiService.currentUserId : null;
      });
      LastScreenTracker.save('/negotiate',
          {'listingId': listingId, 'role': _role, 'buyer_id': _buyerId});
      _finishInit();
    } catch (_) {
      if (mounted) Navigator.pushReplacementNamed(context, '/home');
    }
  }

  void _finishInit() {
    _initTts();
    _initVoice();
    _loadHistory();
    _loadCounterparty();
    // The Inbox opens this thread here next time (ChatScreenMemory).
    final listingId = _listing?.id;
    if (listingId != null) {
      unawaited(ChatScreenMemory.remember(listingId, _buyerId, ChatScreen.zeno));
    }
    // Register this thread as on-screen so the 7s poller does not notify
    // about a Zeno reply the user is reading right now. The direct-chat
    // screen has always done this; the negotiation room never did.
    final lid = _listing?.id;
    if (lid != null) {
      GlobalPollerService.instance.markScreenActive(lid, buyerId: _buyerId);
    }
    _loadDealStatus();
    ApiService.updateLastSeen();
    _heartbeatTimer = Timer.periodic(
        const Duration(seconds: 60), (_) => ApiService.updateLastSeen());
  }

  // ── Deal state ─────────────────────────────────────────────────────────────
  Map<String, dynamic>? _dealStatus;

  Future<void> _loadDealStatus() async {
    if (_listing == null) return;
    try {
      final status = await ApiService.getDealStatus(
        _listing!.id,
        buyerId: _role == 'seller' ? null : ApiService.currentUserId,
      );
      if (mounted) setState(() => _dealStatus = status);
    } catch (_) {}
  }

  // Core presence flag
  bool get _hasFundedDeal => (_dealStatus?['has_deal'] as bool?) ?? false;

  // Raw status string from DB
  String? get _dealStatusStr => _dealStatus?['status'] as String?;
  String? get _disputeBranch => _dealStatus?['dispute_branch'] as String?;
  bool get _sellerHasExplained => (_dealStatus?['seller_has_explained'] as bool?) ?? false;
  int get _replacementCycle  => (_dealStatus?['replacement_cycle'] as int?) ?? 0;

  // Seller-specific flags
  bool get _sellerHasClaimedDelivery =>
      _hasFundedDeal && _dealStatus?['seller_claimed_delivery_at'] != null;

  // Buyer protection (backend: api/domains/escrow/protection.py)
  String? get _dealId => _dealStatus?['deal_id'] as String?;
  double get _amountPaid => (_dealStatus?['amount_paid'] as num?)?.toDouble() ?? 0;
  double get _balance => (_dealStatus?['balance'] as num?)?.toDouble() ?? 0;
  double get _agreedPrice => (_dealStatus?['agreed_price'] as num?)?.toDouble() ?? 0;
  bool get _canAddPayment => (_dealStatus?['can_add_payment'] as bool?) ?? false;
  Map<String, dynamic>? get _refundRequest =>
      (_dealStatus?['refund_request'] as Map?)?.cast<String, dynamic>();
  bool get _refundOpen =>
      _refundRequest != null && _refundRequest!['resolved_at'] == null;

  /// After a protection action: the deal's new state, and Zeno's message
  /// about it in the thread.
  Future<void> _afterDealAction(bool changed) async {
    if (!changed || !mounted) return;
    await _loadDealStatus();
    await _loadHistory();
  }

  // Buyer state machine getters — each maps to one DB status value
  // 'paid': escrow funded, goods not yet delivered/confirmed
  bool get _awaitingArrivalConfirm =>
      _hasFundedDeal && _dealStatusStr == 'paid';

  // 'awaiting_condition_check': goods arrived, asking buyer about quality
  bool get _awaitingConditionCheck =>
      _hasFundedDeal && _dealStatusStr == 'awaiting_condition_check';

  // 'awaiting_resolution': buyer reported an issue, choosing refund/replacement
  bool get _awaitingResolution =>
      _hasFundedDeal && _dealStatusStr == 'awaiting_resolution';

  // 'awaiting_replacement': replacement shipped, waiting for buyer confirmation
  bool get _awaitingReplacement =>
      _hasFundedDeal && _dealStatusStr == 'awaiting_replacement';

  // 'goods_not_arrived': buyer said goods didn't arrive, seller being chased
  bool get _goodsNotArrived =>
      _hasFundedDeal && _dealStatusStr == 'goods_not_arrived';

  // Timer offer from last Zeno message (set by backend, not AI text parsing)
  bool get _timerOfferLive {
    if (_messages.isEmpty) return false;
    final last = _messages.last;
    return last.isBroker && last.timerOffer;
  }

  // ── TTS / STT ──────────────────────────────────────────────────────────────
  Future<void> _initTts() async {
    await _tts.init();
    // The card's "Zeno is speaking..." rides the TTS callbacks this screen
    // already had, so the existing TTS toggle still decides whether anything
    // is spoken at all.
    _tts.onStart    = () { _voice.setZenoSpeaking(true);
                           if (mounted) setState(() => _speaking = true);  };
    _tts.onDone     = () { _voice.setZenoSpeaking(false);
                           if (mounted) setState(() => _speaking = false); };
    _tts.onUnavailable = (reason) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ttsUnavailableMessage(reason)),
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
      ));
    };
  }

  /// Built once. Opens no microphone until the user taps the mic button.
  void _initVoice() {
    _voice = ZenoVoiceController(
      onSubmit: (text) => _send(text),
      languageKey: () => ApiService.currentUserLanguage,
    );
  }

  // ── Counterparty map ───────────────────────────────────────────────────────
  /// Opens the map showing where the OTHER party is relative to you.
  ///
  /// Sends the counterparty's own coordinates when we have them (the user
  /// profile carries lat/lng, gated server-side on `location_visible`), and
  /// falls back to the listing's seller coordinates for a buyer whose seller
  /// has hidden their profile location but published a listing location.
  ///
  /// A seller previously got the listing's own pin - i.e. a map of where
  /// their own sandals are - because the only argument this route ever
  /// received was the Listing.
  void _openCounterpartyMap() {
    final info = _sellerInfo;
    final peerLat = (info?['lat'] as num?)?.toDouble() ??
        (_role == 'buyer' ? _listing?.sellerLat : null);
    final peerLng = (info?['lng'] as num?)?.toDouble() ??
        (_role == 'buyer' ? _listing?.sellerLng : null);
    Navigator.pushNamed(context, '/listing-map', arguments: {
      'listing':   _listing,
      'peerName':  _counterName,
      'peerLat':   peerLat,
      'peerLng':   peerLng,
      'peerPhoto': _sellerPhoto,
      'role':      _role,
      // Server-computed, already rounded to 0.1km. Preferred over anything
      // recomputed on-device from a deliberately approximate pin.
      'distanceKm': (info?['distance_km'] as num?)?.toDouble(),
    });
  }

  // ── Counterparty info ──────────────────────────────────────────────────────
  /// Loads the OTHER party's profile - whoever that is for this viewer.
  ///
  /// BUG (2026-09-15): this only ever loaded the seller, and bailed outright
  /// when the viewer WAS the seller (`sid == currentUserId`). So a seller in
  /// their own negotiation room got no counterparty at all: the header fell
  /// through to the literal string "Seller" with an "S" avatar, offline,
  /// no distance, no rating - while the person they were actually talking to
  /// was the buyer, whose name was sitting in _buyerId the whole time.
  ///
  /// Everything downstream (_counterName, _counterIsOnline, _distKm,
  /// _sellerPhoto, the rating/deal counts on the card, and the peerPhoto
  /// handed to the call screen) reads this one map, so they were all wrong
  /// together on the seller's side and all become right together now.
  Future<void> _loadCounterparty() async {
    final uid = _role == 'seller' ? _buyerId : _listing?.sellerId;
    if (uid == null || uid == ApiService.currentUserId) return;
    try {
      final info = await ApiService.getUserProfile(uid);
      if (mounted) setState(() => _sellerInfo = info);
    } catch (_) {}
  }

  List<Message> _directChatContext = [];
  int _directChatUnreadCount = 0;

  String _directChatSeenKey() {
    final buyerScope = _role == 'buyer' ? (ApiService.currentUserId ?? '') : '';
    return 'directchat_seen_count_${_listing?.id}_$buyerScope';
  }

  Future<void> _refreshDirectChatUnreadCount() async {
    if (_listing == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final seenCount = prefs.getInt(_directChatSeenKey()) ?? 0;
      final unread = _directChatContext.length - seenCount;
      if (mounted) setState(() => _directChatUnreadCount = unread > 0 ? unread : 0);
    } catch (_) {}
  }

  Future<void> _markDirectChatSeen() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_directChatSeenKey(), _directChatContext.length);
    } catch (_) {}
  }

  /// Zeno's messages in this room are on screen. The Inbox stops counting
  /// them as news (`zeno_unread`), so it doesn't pull the user back here
  /// from the direct chat for something they've already read.
  void _sawZeno() {
    final listingId = _listing?.id;
    if (listingId == null) return;
    unawaited(ChatScreenMemory.markZenoSeen(listingId,
        buyerId: _role == 'seller' ? _buyerId : null));
  }

  // ── History ────────────────────────────────────────────────────────────────
  // ── Offline persistence ────────────────────────────────────────────────────
  String _threadScopeKey() =>
      'ai_${_listing?.id}_${_role == 'buyer' ? (ApiService.currentUserId ?? '') : (_buyerId ?? '')}';

  Future<void> _loadCachedMessages() async {
    if (_listing == null) return;
    final cached = await LocalChatStore.load(_threadScopeKey());
    if (cached.isEmpty || !mounted || _messages.isNotEmpty) return;
    try {
      setState(() => _messages = cached.map(Message.fromJson).toList());
      _scrollDown();
    } catch (_) {}
  }

  Future<void> _cacheMessages() => LocalChatStore.save(
      _threadScopeKey(), _messages.map((m) => m.toJson()).toList());

  Future<void> _loadHistory() async {
    if (_listing == null) { _addGreeting(); return; }
    await _loadCachedMessages();
    try {
      // A seller's thread is the buyer's they opened. Without buyer_id the
      // server answers with the latest buyer's, so a seller who opened an
      // earlier buyer from the Inbox read someone else's room.
      final history = await ApiService.getNegotiationHistory(_listing!.id,
          buyerId: _role == 'seller' ? _buyerId : null);
      // AI thread = Zeno's own replies + the human's own messages that were
      // actually sent to Zeno (via_ai=true). This used to only keep
      // role=='broker', which meant re-opening this screen silently dropped
      // the buyer/seller's own side of the conversation from view.
      final aiThread = history.where((m) =>
          m.role == 'broker' || ((m.role == 'buyer' || m.role == 'seller') && m.viaAi)).toList();
      // Direct (human-to-human) messages - only used here to size the
      // "open direct chat" unread badge, never rendered in this transcript.
      _directChatContext = history
          .where((m) => (m.role == 'buyer' || m.role == 'seller') && !m.viaAi)
          .toList();
      _refreshDirectChatUnreadCount();
      if (mounted) {
        if (aiThread.isEmpty) {
          _addGreeting();
        } else {
          setState(() => _messages = aiThread);
          _scrollDown();
        }
        _sawZeno();
      }
      unawaited(_cacheMessages());
    } catch (_) {
      // Offline - keep whatever the cache already showed rather than
      // replacing it with a fresh greeting.
      if (_messages.isEmpty) _addGreeting();
    }
  }

  Future<void> _addGreeting() async {
    setState(() => _typing = true);
    try {
      Message reply = const Message(role: 'broker', content: '');
      if (_listing != null) {
        reply = await ApiService.sendNegotiationMessage(
          listingId:  _listing!.id,
          senderRole: _role,
          senderId:   ApiService.currentUserId ?? '',
          content:    '',
          intent:     'opening_greeting',
        );
      }
      if (mounted) {
        setState(() { _typing = false; _messages = [reply]; _fresh.add(reply); });
        if (_ttsEnabled) _speak(reply.content);
      }
    } catch (_) {
      final name = _listing?.name ?? 'this item';
      final fallback = _role == 'seller'
          ? "Welcome back, $_myFirst! 👋 I'm here for pricing, buyer risk, or anything about \"$name\"."
          : "Hi $_myFirst! 👋 I can check if the price is fair, spot red flags, or translate. Ready when you are.";
      if (mounted) {
        final greeting = Message(role: 'broker', content: fallback);
        setState(() { _typing = false; _messages = [greeting]; _fresh.add(greeting); });
        if (_ttsEnabled) _speak(fallback);
      }
    }
  }

  // ── Lifecycle ──────────────────────────────────────────────────────────────
  @override
  void dispose() {
    // Symmetric with the markScreenActive in _finishInit/initState.
    // Leaving it registered would silence this thread's
    // notifications permanently.
    final lid = _listing?.id;
    if (lid != null) {
      GlobalPollerService.instance
        .markScreenInactive(lid, buyerId: _buyerId);
    }
    _msgCtrl.dispose(); _scrollCtrl.dispose(); _composerFocus.dispose();
    _tts.stop();
    _voice.dispose();
    _heartbeatTimer?.cancel();
    super.dispose();
  }

  Future<void> _speak(String text) async {
    if (!_ttsEnabled) return;
    await _tts.speak(text, language: ApiService.currentUserLanguage);
  }

  /// Opens the floating voice card over this negotiation.
  void _openVoice() => _voice.open();


  // ── Core message sender ────────────────────────────────────────────────────
  /// [photo]: a picture for Zeno to look at with this message. Only the
  /// sender's own reply is written with it in view; it is never passed to
  /// the other party (backend negotiate.send_message).
  Future<void> _send([String? quickText, List<int>? photo]) async {
    final text = (quickText ?? _msgCtrl.text).trim();
    if (text.isEmpty) return;
    setState(() {
      _messages.add(Message(role: _role, content: photo != null ? '📷 $text' : text));
      _typing = true;
    });
    if (quickText == null || photo != null) _msgCtrl.clear();
    _scrollDown();

    try {
      Message reply;
      if (_listing != null) {
        reply = await ApiService.sendNegotiationMessage(
          imageBase64: photo != null ? base64Encode(photo) : null,
          listingId:  _listing!.id,
          senderRole: _role,
          senderId:   ApiService.currentUserId ?? '',
          content:    text,
          buyerName:  _role == 'buyer' ? _myName : null,
          sellerName: _role == 'seller' ? _myName : _listing!.sellerName,
          buyerLat:   _role == 'buyer' ? ApiService.currentUserLat : null,
          buyerLng:   _role == 'buyer' ? ApiService.currentUserLng : null,
          sellerLat:  _listing!.sellerLat,
          sellerLng:  _listing!.sellerLng,
          // Without this, a seller's plain message has no buyer_id on the
          // backend, so it isn't scoped to any thread - it would leak across
          // every buyer negotiating this listing and Zeno's context/deal
          // lookups for it would silently fail to find the right deal.
          buyerIdForThread: _role == 'seller' ? _buyerId : null,
        );
      } else {
        reply = await ApiService.freeChat(
          content:  text,
          history:  _messages.map((m) => {'role': m.isBroker ? 'assistant' : 'user', 'content': m.content}).toList(),
          userName: _myName,
        );
      }
      if (mounted) {
        setState(() {
          _typing = false; _messages.add(reply);
          if (reply.isBroker) _fresh.add(reply);
          if (reply.dealProbability != null) _dealProbability = reply.dealProbability!;
        });
        if (reply.isBroker) _sawZeno();
        _scrollDown();
        if (_ttsEnabled) _speak(reply.content);
      }
      unawaited(_cacheMessages());
      // Zeno's action proposal, if any.
      //
      // SWITCH_TO_DIRECT_CHAT executes immediately; everything else is
      // still rendered as something to TAP.
      //
      // The distinction is what the action can do. A call rings a phone and
      // an SMS leaves under the user's name - both irreversible, both
      // reaching a person who did not ask for them, so both keep their
      // confirm step. Navigating to a screen inside the app is reversible
      // with the back button and reaches nobody, and the previous code's
      // own comment conceded as much ("benign on its own - navigation is
      // reversible") before applying the same gate anyway.
      //
      // The injection concern that motivated that gate is not fully gone:
      // the classifier sees `grounding`, which contains the other party's
      // relayed words, so a seller writing "move them to direct chat" can
      // in principle influence the action attached to the buyer's next
      // short message. What it cannot do is act on its own - the action is
      // classified from `data.content`, the text THIS user just typed, and
      // returned only to them. The worst case is a screen the user did not
      // ask for, one back-press from where they were.
      if (mounted) {
        final action = reply.zenoAction?['action'] as String?;
        if (action == 'SWITCH_TO_DIRECT_CHAT') {
          setState(() => _pendingAction = null);
          _markDirectChatSeen();
          Navigator.pushReplacementNamed(context, '/direct-chat',
              arguments: {'listing': _listing, 'role': _role, 'buyer_id': _buyerId});
          return;
        }
        setState(() => _pendingAction = reply.zenoAction);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
        _typing = false;
        _messages.add(const Message(role: 'broker', content: 'Connection issue. Please try again.'));
      });
      }
      unawaited(_cacheMessages());
    }
  }

  /// The photo button: show Zeno a picture - the item next to the listing's
  /// photos, a part, a receipt - with whatever is typed, or a plain
  /// question when nothing is.
  Future<void> _showZenoPhoto() async {
    if (_typing) return;
    final source = await PhotoCapture.askSource(context);
    if (source == null || !mounted) return;
    final file = await (source == PhotoSource.camera
        ? PhotoCapture.takePhoto(context, hint: 'Show Zeno clearly, in good light.')
        : PhotoCapture.pickFromGallery(context));
    if (file == null || !mounted) return;
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    final typed = _msgCtrl.text.trim();
    await _send(typed.isEmpty ? 'What can you tell me from this photo?' : typed, bytes);
  }

  // ─────────────────────────────────────────────────────────────────────────
  // INTENT ACTION HELPERS
  // Every button maps to one explicit intent string. The backend is the
  // authority — no business logic lives here. All methods:
  //   1. Show a confirm dialog if the action is irreversible
  //   2. Send the intent to the backend
  //   3. Append Zeno's reply to the chat
  //   4. Refresh _dealStatus so buttons update to the new state
  // ─────────────────────────────────────────────────────────────────────────

  /// Shared helper: send any intent and append reply.
  Future<void> _sendIntent(String intent, {
    String content = '',
    String? imageBase64,
  }) async {
    if (_listing == null) return;
    setState(() => _typing = true);
    try {
      final reply = await ApiService.sendNegotiationMessage(
        listingId:        _listing!.id,
        senderRole:       _role,
        senderId:         ApiService.currentUserId ?? '',
        content:          content,
        buyerName:        _role == 'buyer' ? _myName : null,
        sellerName:       _role == 'seller' ? _myName : null,
        buyerIdForThread: _buyerId,
        intent:           intent,
        imageBase64:      imageBase64,
      );
      if (mounted) {
        setState(() {
          _messages.add(reply);
          if (reply.isBroker) _fresh.add(reply);
          _typing = false;
        });
        if (reply.isBroker) _sawZeno();
      }
      _scrollDown();
      if (_ttsEnabled && reply.isBroker && reply.content.isNotEmpty) _speak(reply.content);
    } catch (e) {
      if (mounted) {
        setState(() => _typing = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Error: ${e.toString().replaceAll("Exception: ", "")}'),
          behavior: SnackBarBehavior.floating,
        ));
      }
    } finally {
      await _loadDealStatus();
    }
  }

  /// Show a confirm dialog. Returns true if the user tapped the action button.
  Future<bool> _confirm(String title, String body, {
    String yes = 'Confirm',
    Color  yesColor = BrokaColors.gold,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: BrokaColors.bgCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title:   Text(title, style: const TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.bold)),
        content: Text(body,  style: const TextStyle(color: BrokaColors.textMid, height: 1.45)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel', style: TextStyle(color: BrokaColors.textMid)),
          ),
          ElevatedButton(
            style:     ElevatedButton.styleFrom(backgroundColor: yesColor),
            onPressed: () => Navigator.pop(context, true),
            child:     Text(yes, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  // ── SELLER actions ─────────────────────────────────────────────────────────

  /// Starts the buyer's 3 days to release or object; after that the money
  /// is released automatically (POST /deal/{id}/mark-delivered).
  Future<void> _markAsDelivered() async {
    final dealId = _dealId;
    if (_role != 'seller' || dealId == null) return;
    await _afterDealAction(await markDealDelivered(context, dealId: dealId, balance: _balance));
  }

  Future<void> _respondToRefund() async {
    final dealId = _dealId;
    if (dealId == null) return;
    await _afterDealAction(await showRefundResponseDialog(context,
        dealId: dealId,
        amount: _amountPaid > 0 ? _amountPaid : _agreedPrice,
        reason: _refundRequest?['reason'] as String?,
        respondBy: _refundRequest?['respond_by'] as String?));
  }

  Future<void> _setPrice() async {
    final dealId = _dealId;
    if (dealId == null) return;
    await _afterDealAction(await showSetPriceDialog(context,
        dealId: dealId, currentPrice: _agreedPrice, amountPaid: _amountPaid));
  }

  Future<void> _replacementShipped() async {
    if (!await _confirm(
      'Replacement shipped?',
      'Confirm you have dispatched the replacement to the buyer. '
      'Funds will stay frozen until the buyer confirms it arrived '
      'and is correct.',
      yes: 'Yes, I shipped it',
    )) return;
    await _sendIntent('seller_ships_replacement', content: 'Replacement has been shipped.');
  }

  // ── BUYER: the money in escrow ─────────────────────────────────────────────

  /// Release to the seller, after "has it been delivered?" (and, for land
  /// or a vehicle, "have the documents been transferred?"). A "no" is a
  /// recommendation to wait, not a block.
  Future<void> _releasePayment() async {
    final dealId = _dealId;
    if (dealId == null) return;
    final released = await showReleaseDialog(context,
        dealId: dealId,
        amount: _amountPaid > 0 ? _amountPaid : _agreedPrice,
        requiresOwnershipTransfer: (_dealStatus?['requires_ownership_transfer'] as bool?) ?? false);
    await _afterDealAction(released);
    // Released: ask how it went while the goods are in hand. The backend
    // decides whether it is due (released, not yet reviewed).
    if (released && mounted) {
      await promptReviewIfDue(context, dealId: dealId, sellerId: _listing?.sellerId);
    }
  }

  /// Pay the rest of a deal paid in part.
  Future<void> _payBalance() async {
    final dealId = _dealId;
    if (dealId == null) return;
    await _afterDealAction(await showEscrowPayDialog(context,
        dealId: dealId, listingId: _listing?.id, listingName: _listing?.name ?? ''));
  }

  Future<void> _requestRefund() async {
    final dealId = _dealId;
    if (dealId == null) return;
    await _afterDealAction(await showRefundRequestDialog(context,
        dealId: dealId,
        amount: _amountPaid > 0 ? _amountPaid : _agreedPrice,
        sellerClaimedDelivery: _sellerHasClaimedDelivery));
  }

  Future<void> _withdrawRefund() async {
    final dealId = _dealId;
    if (dealId == null) return;
    await _afterDealAction(await withdrawRefundRequest(context, dealId: dealId));
  }

  // ── BUYER: condition check (goods arrived but quality unknown) ─────────────

  /// Everything is fine — release 97% to seller.
  Future<void> _goodsOk() async {
    if (!await _confirm(
      'Release payment?',
      'Confirming the item is correct and in good condition will immediately '
      'release 97% of the payment to the seller. This cannot be undone.',
      yes: 'Yes, release payment',
      yesColor: BrokaColors.neonGreen,
    )) return;
    // Read before the intent: once released, the deal-status fetch no
    // longer returns it.
    final dealId = _dealStatus?['deal_id'] as String?;
    await _sendIntent('buyer_confirms_goods_ok', content: 'The goods are correct and in good condition.');
    // Released: ask how it went while the goods are in hand. The backend
    // decides whether it is due (released, not yet reviewed).
    if (dealId != null && mounted) {
      await promptReviewIfDue(context, dealId: dealId, sellerId: _listing?.sellerId);
    }
  }

  /// Wrong item received.
  Future<void> _wrongItem() async {
    await _sendIntent('buyer_reports_wrong_item', content: 'I received the wrong item.');
  }

  /// Goods arrived damaged — opens camera, sends image to Zeno for AI analysis.
  ///
  /// BROKA's own camera, as for listing photos (services/photo_capture.dart):
  /// the phone's camera app could get BROKA killed behind it, losing the
  /// report mid-dispute.
  Future<void> _goodsDamaged() async {
    final photo = await PhotoCapture.takePhoto(context,
        hint: 'Get the damage in frame, close and in good light - Zeno will look at this photo.');
    if (photo == null || !mounted) return;

    final bytes = await photo.readAsBytes();
    final b64   = base64Encode(bytes);

    if (!await _confirm(
      'Report damaged goods?',
      "I'll send this photo to Zeno for AI analysis. Zeno will assess the "
      "damage and then ask whether you want a refund or a replacement.",
      yes: 'Send photo',
      yesColor: BrokaColors.warning,
    )) return;

    await _sendIntent('buyer_reports_damaged',
        content: 'The goods arrived damaged.', imageBase64: b64);
  }

  // ── BUYER: resolution choice ───────────────────────────────────────────────

  /// Buyer wants a refund (after wrong item or damaged report).
  Future<void> _wantRefund() async {
    if (!await _confirm(
      'Request a refund?',
      '97% of the payment will be returned to your M-Pesa. '
      'The seller will be notified and asked to arrange collection of the goods.',
      yes: 'Yes, I want a refund',
      yesColor: BrokaColors.danger,
    )) return;
    await _sendIntent('buyer_chooses_refund', content: 'I want a refund.');
  }

  /// Buyer wants a replacement instead of a refund.
  Future<void> _wantReplacement() async {
    if (!await _confirm(
      'Request a replacement?',
      'The seller will be asked to ship the correct item. '
      'Funds stay frozen until you confirm the replacement is correct.',
      yes: 'Yes, send a replacement',
    )) return;
    await _sendIntent('buyer_chooses_replacement', content: 'I want a replacement.');
  }

  // ── BUYER: replacement tracking ────────────────────────────────────────────

  /// Replacement arrived — restarts condition check for the replacement.
  Future<void> _replacementArrived() async {
    await _sendIntent('replacement_arrived', content: 'The replacement has arrived.');
  }

  /// Replacement also hasn't arrived — re-triggers goods-not-arrived flow.
  Future<void> _replacementMissing() async {
    if (!await _confirm(
      "Replacement not arrived?",
      "I'll contact the seller again. If there's no response within 3 days "
      "you will be automatically refunded.",
      yes: "Yes, it hasn't arrived",
      yesColor: BrokaColors.danger,
    )) return;
    await _sendIntent('goods_not_arrived', content: 'The replacement has not arrived.');
  }

  // ── Legacy / timer actions ─────────────────────────────────────────────────

  Future<void> _confirmStartTimer() async {
    if (_listing == null) return;
    setState(() { _messages.add(Message(role: _role, content: 'Yes, please start the timer.')); _typing = true; });
    _scrollDown();
    try {
      final reply = await ApiService.sendNegotiationMessage(
        listingId:  _listing!.id,
        senderRole: _role,
        senderId:   ApiService.currentUserId ?? '',
        content:    'Confirmed: start auto-resolution timer.',
        intent:     'confirm_start_timer',
        buyerIdForThread: _role == 'seller' ? _buyerId : null,
      );
      if (mounted) {
        setState(() {
          _typing = false;
          _messages.add(reply);
          if (reply.isBroker) _fresh.add(reply);
        });
        if (reply.isBroker) _sawZeno();
      }
      _scrollDown();
    } catch (_) {
      if (mounted) {
        setState(() {
        _typing = false;
        _messages.add(const Message(role: 'broker', content: 'Could not start timer — please try again.'));
      });
      }
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // STATE-MACHINE BUTTON BUILDER
  // Every branch of the deal flow has its own set of buttons. The DB status
  // field is the single source of truth for which branch is active.
  // ─────────────────────────────────────────────────────────────────────────
  Widget _buildQuickActions() {
    final chips = <Widget>[];

    // ── SELLER ──────────────────────────────────────────────────────────────
    if (_role == 'seller') {
      // The buyer asked for a refund: the seller's answer comes first.
      if (_awaitingArrivalConfirm && _refundOpen) {
        chips.add(_chip(
          label: 'Respond to refund request',
          icon: Icons.undo_rounded,
          gradient: const [BrokaColors.danger, Color(0xFFB91C1C)],
          onTap: _respondToRefund,
        ));
      }
      // Seller can mark as delivered only when funds are held and not yet claimed
      if (_hasFundedDeal && !_sellerHasClaimedDelivery && !_refundOpen &&
          (_dealStatusStr == 'paid' || _dealStatusStr == null)) {
        chips.add(_chip(
          label: 'Mark as delivered',
          icon: Icons.local_shipping_outlined,
          gradient: const [BrokaColors.gold, BrokaColors.goldDim],
          onTap: _markAsDelivered,
        ));
      }
      // A buyer may pay before the price is confirmed, or pay part of it:
      // the seller states the price, and the buyer sees the balance.
      if (_awaitingArrivalConfirm && !_refundOpen) {
        chips.add(_chip(
          label: 'Confirm agreed price',
          icon: Icons.sell_outlined,
          color: BrokaColors.bgCard,
          border: BrokaColors.gold,
          textColor: BrokaColors.gold,
          onTap: _setPrice,
        ));
      }
      if (_awaitingArrivalConfirm) {
        final summary = escrowSummary(_dealStatus ?? const {}, isBuyer: false);
        if (summary != null) {
          chips.add(_infoChip(label: summary, icon: Icons.lock_clock_outlined));
        }
      }
      // Seller confirms replacement shipped (A4 branch)
      if (_awaitingReplacement) {
        chips.add(_chip(
          label: 'Replacement shipped',
          icon: Icons.inventory_2_outlined,
          gradient: const [BrokaColors.gold, BrokaColors.neonBlue],
          onTap: _replacementShipped,
        ));
      }
      // Seller must explain before the buyer can choose refund/replacement
      if (_awaitingResolution && !_sellerHasExplained) {
        chips.add(_chip(
          label: 'Explain to buyer',
          icon: Icons.record_voice_over_outlined,
          gradient: const [BrokaColors.warning, BrokaColors.gold],
          onTap: _showExplainDisputeDialog,
        ));
      }
      // Seller responds to a "goods not arrived" report
      if (_goodsNotArrived) {
        chips.add(_chip(
          label: 'Explain delay',
          icon: Icons.local_shipping_outlined,
          gradient: const [BrokaColors.warning, BrokaColors.gold],
          onTap: () => _sendIntent('seller_explains_non_arrival',
              content: 'Explaining the delivery delay.'),
        ));
      }
    }

    // ── BUYER ───────────────────────────────────────────────────────────────
    if (_role == 'buyer') {
      // Nothing paid yet: pay straight into escrow - the payment opens the
      // deal, there is nothing to "finalize" first.
      if (!_hasFundedDeal && _listing != null && _listing!.listingType != 'auction') {
        chips.add(_chip(
          label: 'Pay securely',
          icon: Icons.lock_rounded,
          gradient: const [BrokaColors.neonGreen, BrokaColors.success],
          onTap: () => _payNow(agreedPrice: _currentOffer),
        ));
      }
      // ── paid: goods not yet confirmed arrived ──────────────────────────
      // Release (with the delivery check), pay the balance of a part-paid
      // deal, or ask for a refund - which, before the seller has marked it
      // delivered, refunds automatically if the seller stays silent.
      if (_awaitingArrivalConfirm && _refundOpen) {
        chips.add(_infoChip(
          label: "Refund requested - the seller has 48 hours to respond, or you're refunded automatically",
          icon: Icons.hourglass_top_rounded,
        ));
        chips.add(_chip(
          label: 'Withdraw refund request',
          icon: Icons.close_rounded,
          color: BrokaColors.bgCard,
          border: BrokaColors.textLow,
          textColor: BrokaColors.textMid,
          onTap: _withdrawRefund,
        ));
      } else if (_awaitingArrivalConfirm) {
        chips.add(_chip(
          label: 'Release payment',
          icon: Icons.verified_outlined,
          gradient: const [BrokaColors.neonGreen, BrokaColors.success],
          onTap: _releasePayment,
        ));
        if (_canAddPayment) {
          chips.add(_chip(
            label: 'Pay balance (${formatKes(_balance)})',
            icon: Icons.add_card_outlined,
            gradient: const [BrokaColors.neonBlue, BrokaColors.neonGreen],
            onTap: _payBalance,
          ));
        }
        chips.add(_chip(
          label: _sellerHasClaimedDelivery ? 'Report a problem' : 'Request refund',
          icon: Icons.undo_rounded,
          color: BrokaColors.bgCard,
          border: BrokaColors.danger,
          textColor: BrokaColors.danger,
          onTap: _requestRefund,
        ));
      }
      if (_awaitingArrivalConfirm) {
        final summary = escrowSummary(_dealStatus ?? const {}, isBuyer: true);
        if (summary != null) {
          chips.add(_infoChip(label: summary, icon: Icons.lock_clock_outlined));
        }
      }

      // ── awaiting_condition_check: goods arrived, confirm quality ───────
      if (_awaitingConditionCheck) {
        final cycleLabel = _replacementCycle > 0
            ? ' (replacement #$_replacementCycle)' : '';
        chips.add(_chip(
          label: 'All is well — release payment$cycleLabel',
          icon: Icons.verified_outlined,
          gradient: const [BrokaColors.neonGreen, BrokaColors.success],
          onTap: _goodsOk,
        ));
        chips.add(_chip(
          label: 'Wrong item received',
          icon: Icons.swap_horiz_rounded,
          color: BrokaColors.bgCard,
          border: BrokaColors.warning,
          textColor: BrokaColors.warning,
          onTap: _wrongItem,
        ));
        chips.add(_chip(
          label: 'Goods are damaged',
          icon: Icons.broken_image_outlined,
          color: BrokaColors.bgCard,
          border: BrokaColors.danger,
          textColor: BrokaColors.danger,
          onTap: _goodsDamaged,
        ));
      }

      // ── awaiting_resolution: buyer chose to complain, picking remedy ───
      // Only shown once the seller has actually responded - matches the
      // backend gate in buyer_chooses_refund/buyer_chooses_replacement.
      if (_awaitingResolution && !_sellerHasExplained) {
        chips.add(_infoChip(
          label: "Waiting for the seller's explanation - Zeno will update you",
          icon: Icons.hourglass_top_rounded,
        ));
      }
      if (_awaitingResolution && _sellerHasExplained) {
        chips.add(_chip(
          label: 'I want a refund',
          icon: Icons.undo_rounded,
          gradient: const [BrokaColors.danger, Color(0xFFB91C1C)],
          onTap: _wantRefund,
        ));
        chips.add(_chip(
          label: 'I want a replacement',
          icon: Icons.autorenew_rounded,
          gradient: const [BrokaColors.warning, BrokaColors.gold],
          onTap: _wantReplacement,
        ));
      }

      // ── awaiting_replacement: waiting for replacement to arrive ────────
      if (_awaitingReplacement) {
        chips.add(_chip(
          label: 'Replacement arrived',
          icon: Icons.check_circle_outline_rounded,
          gradient: const [BrokaColors.neonGreen, BrokaColors.success],
          onTap: _replacementArrived,
        ));
        chips.add(_chip(
          label: "Replacement not arrived",
          icon: Icons.remove_circle_outline_rounded,
          color: BrokaColors.bgCard,
          border: BrokaColors.danger,
          textColor: BrokaColors.danger,
          onTap: _replacementMissing,
        ));
      }

      // ── goods_not_arrived: seller is being chased — info chip only ─────
      if (_goodsNotArrived) {
        chips.add(_infoChip(
          label: 'Chasing seller — Zeno will keep you updated',
          icon: Icons.hourglass_top_rounded,
        ));
      }
    }

    // ── Timer offer (any role — backend sets this flag) ───────────────────
    if (_timerOfferLive) {
      chips.add(_chip(
        label: 'Start 48h timer',
        icon: Icons.timer_outlined,
        gradient: const [BrokaColors.danger, BrokaColors.warning],
        onTap: _confirmStartTimer,
      ));
    }

    if (chips.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: Wrap(spacing: 8, runSpacing: 8, children: chips),
    );
  }

  /// Pill-shaped action button (gradient or outline).
  Widget _chip({
    required String label,
    required IconData icon,
    required VoidCallback onTap,
    List<Color>? gradient,
    Color? color,
    Color? border,
    Color textColor = Colors.white,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          gradient: gradient != null ? LinearGradient(colors: gradient) : null,
          color: gradient == null ? (color ?? BrokaColors.bgCard) : null,
          borderRadius: BorderRadius.circular(20),
          border: border != null ? Border.all(color: border.withOpacity(0.65)) : null,
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: textColor),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(color: textColor, fontWeight: FontWeight.w700, fontSize: 13)),
        ]),
      ),
    );
  }

  /// Non-tappable status pill (informational only).
  Widget _infoChip({required String label, required IconData icon}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: BrokaColors.bgMid,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: BrokaColors.border),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: BrokaColors.textMid),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(color: BrokaColors.textMid, fontWeight: FontWeight.w600, fontSize: 13)),
      ]),
    );
  }

  // ── Scroll ─────────────────────────────────────────────────────────────────
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

  void _scrollDown() => Future.delayed(const Duration(milliseconds: 120), () {
    if (_scrollCtrl.hasClients) {
      _scrollCtrl.animateTo(
      _scrollCtrl.position.maxScrollExtent,
      duration: const Duration(milliseconds: 280), curve: Curves.easeOut);
    }
  });

  // ── Dialogs ────────────────────────────────────────────────────────────────
  void _showOfferDialog() {
    final ctrl = TextEditingController(text: _listing?.price.toStringAsFixed(0) ?? '');
    showDialog(context: context, builder: (ctx) => AlertDialog(
      backgroundColor: BrokaColors.bgCard,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('Make an Offer', style: TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.w800)),
      content: TextField(
        controller: ctrl,
        keyboardType: TextInputType.number,
        style: const TextStyle(color: BrokaColors.textHigh),
        decoration: const InputDecoration(prefixText: 'KES ', prefixStyle: TextStyle(color: BrokaColors.gold), hintText: 'Enter your offer'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel', style: TextStyle(color: BrokaColors.textMid))),
        TextButton(
          onPressed: () {
            final val = double.tryParse(ctrl.text.replaceAll(',', ''));
            if (val != null) {
              Navigator.pop(ctx); setState(() => _currentOffer = val);
              _send('I am offering KES ${val.toStringAsFixed(0).replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => "${m[1]},")} for this item.');
            }
          },
          child: const Text('Submit', style: TextStyle(color: BrokaColors.gold, fontWeight: FontWeight.w800)),
        ),
      ],
    ));
  }

  /// Seller taps "Explain" in response to a wrong-item or damaged-goods
  /// complaint. Sends seller_explains_wrong_item or seller_explains_damaged
  /// depending on which dispute branch is active - this is the missing
  /// counterpart to buyer_reports_wrong_item/buyer_reports_damaged; without
  /// it the seller has no way to respond and the dispute stalls forever.
  void _showExplainDisputeDialog() {
    final branch = _disputeBranch;
    final intent = branch == 'A3' ? 'seller_explains_damaged' : 'seller_explains_wrong_item';
    final ctrl = TextEditingController();
    showDialog(context: context, builder: (ctx) => AlertDialog(
      backgroundColor: BrokaColors.bgCard,
      title: const Text('Explain to the buyer', style: TextStyle(color: BrokaColors.textHigh)),
      content: TextField(
        controller: ctrl, autofocus: true, maxLines: 4,
        style: const TextStyle(color: BrokaColors.textHigh),
        decoration: InputDecoration(
          hintText: 'What happened? The buyer will see your explanation, '
                    'then choose a refund or a replacement.',
          hintStyle: const TextStyle(color: BrokaColors.textLow),
          filled: true, fillColor: BrokaColors.bg,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: () {
            final text = ctrl.text.trim();
            Navigator.pop(ctx);
            if (text.isNotEmpty) {
              _sendIntent(intent, content: text).then((_) => _loadDealStatus());
            }
          },
          style: ElevatedButton.styleFrom(backgroundColor: BrokaColors.gold),
          child: const Text('Send explanation'),
        ),
      ],
    ));
  }

  /// Pays into escrow in one step - the first payment opens the deal on
  /// the server, so there is no "finalize" to understand first.
  /// [agreedPrice] is the offer on the table, when there is one.
  Future<void> _payNow({double? agreedPrice}) async {
    final listing = _listing;
    if (listing == null || _role != 'buyer') return;
    final multi = hasUnits(listing);
    final opened = await showEscrowPayDialog(
      context,
      listingId: listing.id,
      listingName: listing.name,
      agreedPrice: agreedPrice,
      unitPrice: multi ? (agreedPrice ?? listing.price) : null,
      maxUnits: multi ? unitsAvailable(listing) : 1,
      unitLabel: listing.priceUnit,
    );
    await _afterDealAction(opened);
  }

  // ── BUILD ──────────────────────────────────────────────────────────────────
  bool get _counterIsOnline => (_sellerInfo?['is_online'] as bool?) ?? false;
  String? get _counterLastSeenText => _sellerInfo?['last_seen_label'] as String?;
  double? get _distKm {
    final d = _sellerInfo?['distance_km'];
    return d != null ? (d as num).toDouble() : null;
  }
  String? get _sellerLoc   => _sellerInfo?['location_name'] as String?;
  String? get _sellerPhoto => _sellerInfo?['profile_photo']  as String?;
  String? get _myPhoto     => ApiService.currentUserPhoto;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: BrokaColors.bg,
    resizeToAvoidBottomInset: true,
    // Home's constellation, as on every screen reached from it, with Zeno's
    // violet washing down from the top as on Zeno's own screen - this is
    // Zeno's room. It used to sit on ChatAmbientBackground, a retuned
    // splash field that made this the one conversation screen that didn't
    // look like the rest of the app.
    // The voice card floats over this room; the negotiation underneath keeps
    // its scroll position, its messages, its action bar and its deal state.
    body: ZenoVoiceOverlay(
      controller: _voice,
      child: ConstellationBackground(
        animate: widget.animateBackground,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment.topCenter,
              radius: 1.2,
              colors: [BrokaColors.neonPurple.withOpacity(0.14), Colors.transparent],
              stops: const [0.0, 0.6],
            ),
          ),
          child: SafeArea(child: Column(children: [
            _buildHeader(),
            if (_listing != null) _buildInfoStrip(),
            Expanded(child: _buildChat()),
            _buildActionBar(),
            _buildActionProposal(),
            _buildInputBar(),
          ])),
        ),
      ),
    ),
  );

  /// Home's header language, as on Zeno's screen: a bare back chevron,
  /// Zeno's avatar, a glowing title, and square controls on the right.
  Widget _buildHeader() => Container(
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
      const ZenoAvatar(size: 38, glow: true),
      const SizedBox(width: 11),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          const ZoneGlowText('Negotiation',
              gradient: kChatGradient, fontSize: 18, maxLines: 1, letterSpacing: 1.4),
          const SizedBox(height: 3),
          Row(children: [
            const Icon(Icons.verified_user_rounded, size: 12, color: BrokaColors.neonGreen),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                'Zeno mediating · Escrow protected',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: BrokaColors.textMid.withOpacity(0.95), fontSize: 11.5),
              ),
            ),
          ]),
        ]),
      ),
      const SizedBox(width: 8),
      Stack(clipBehavior: Clip.none, children: [
        BrokaHeaderButton(
          icon: Icons.chat_bubble_outline_rounded,
          tooltip: 'Chat directly',
          onTap: () {
            _markDirectChatSeen();
            Navigator.pushReplacementNamed(context, '/direct-chat',
                arguments: {'listing': _listing, 'role': _role, 'buyer_id': _buyerId});
          },
        ),
        if (_directChatUnreadCount > 0)
          Positioned(right: -4, top: -4, child: IgnorePointer(child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(color: BrokaColors.danger,
              borderRadius: BorderRadius.circular(8), border: Border.all(color: BrokaColors.bg, width: 1.5)),
            child: Text('$_directChatUnreadCount',
                style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w800)),
          ))),
      ]),
      const SizedBox(width: 8),
      BrokaHeaderButton(
        icon: _ttsEnabled
            ? (_speaking ? Icons.graphic_eq_rounded : Icons.volume_up_rounded)
            : Icons.volume_off_rounded,
        active: _ttsEnabled,
        tooltip: _ttsEnabled ? 'Mute Zeno' : "Read Zeno's replies aloud",
        onTap: () { setState(() => _ttsEnabled = !_ttsEnabled); if (!_ttsEnabled) _tts.stop(); },
      ),
    ]),
  );

  /// One compact card replacing the old three stacked cards (deal strip,
  /// counterparty strip, status bar) - same information, far less vertical
  /// space, leaving much more room for the actual chat below.
  Widget _buildInfoStrip() {
    final cName = _counterName; final cDist = _distKm;
    final cPhoto = _sellerPhoto; final rating = (_sellerInfo?['rating'] as num?)?.toStringAsFixed(1);
    final deals = _sellerInfo?['completed_deals'] as int?;
    final escrowPct = (_sellerInfo?['escrow_success_rate_pct'] as num?)?.toStringAsFixed(0);
    final ver = _sellerInfo?['is_verified'] as bool? ?? false;
    final isOnline = _counterIsOnline; final lastSeen = _counterLastSeenText;
    final sellerId = _sellerInfo?['id'] as String? ?? _listing?.sellerId;
    final prob = _dealProbability;
    final probColor = prob >= 70 ? BrokaColors.neonGreen : prob >= 40 ? Colors.orangeAccent : BrokaColors.danger;
    final priceLabel = _currentOffer != null
        ? 'Offer: KES ${_currentOffer!.toStringAsFixed(0).replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => "${m[1]},")}'
        : 'Asking ${_listing!.formattedPrice}';

    return GestureDetector(
      onTap: sellerId != null ? () => Navigator.pushNamed(context, '/user-profile', arguments: sellerId) : null,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 10, 16, 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        // A card like Home's: the dark translucent fill and hairline border
        // every card on the constellation has.
        decoration: BoxDecoration(
          color: BrokaColors.bgCard.withOpacity(0.86),
          borderRadius: BorderRadius.circular(16), border: Border.all(color: BrokaColors.border),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Stack(children: [
              Container(width: 32, height: 32,
                decoration: const BoxDecoration(shape: BoxShape.circle, gradient: LinearGradient(colors: [BrokaColors.gold, BrokaColors.goldDim])),
                child: ClipOval(child: cPhoto != null && cPhoto.isNotEmpty
                    ? Image.memory(base64Decode(cPhoto), fit: BoxFit.cover)
                    : Center(child: Text(cName[0].toUpperCase(), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 14))))),
              Positioned(bottom: 0, right: 0, child: Container(width: 9, height: 9,
                decoration: BoxDecoration(shape: BoxShape.circle,
                  color: isOnline ? BrokaColors.neonGreen : BrokaColors.textLow,
                  border: Border.all(color: BrokaColors.bg, width: 1.5)))),
            ]),
            const SizedBox(width: 9),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(child: Text(cName, style: const TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.w700, fontSize: 13), maxLines: 1, overflow: TextOverflow.ellipsis)),
                if (ver) ...[const SizedBox(width: 4), const Icon(Icons.verified_rounded, color: BrokaColors.gold, size: 12)],
              ]),
              Row(children: [
                Text(isOnline ? 'Online' : lastSeen != null ? 'Last seen $lastSeen' : 'Offline',
                    style: TextStyle(fontSize: 10, color: isOnline ? BrokaColors.neonGreen : BrokaColors.textLow, fontWeight: FontWeight.w600)),
                if (rating != null) ...[
                  const Text('  ·  ', style: TextStyle(fontSize: 10, color: BrokaColors.textLow)),
                  const Icon(Icons.star_rounded, size: 10, color: BrokaColors.gold),
                  Text(' $rating · ${deals ?? 0} deals${escrowPct != null ? ' · $escrowPct% escrow success' : ''}', style: const TextStyle(color: BrokaColors.textMid, fontSize: 10)),
                ],
              ]),
            ])),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text('$prob%', style: TextStyle(color: probColor, fontSize: 13, fontWeight: FontWeight.w800)),
              SizedBox(width: 44, height: 4,
                child: ClipRRect(borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(value: prob / 100, backgroundColor: BrokaColors.border,
                    valueColor: AlwaysStoppedAnimation<Color>(probColor)))),
            ]),
          ]),
          const Padding(padding: EdgeInsets.symmetric(vertical: 6), child: Divider(height: 1, color: BrokaColors.border)),
          Row(children: [
            Text(_listing!.emoji, style: const TextStyle(fontSize: 14)),
            const SizedBox(width: 6),
            Expanded(child: Text('${_listing!.name} · $priceLabel',
                style: const TextStyle(color: BrokaColors.textMid, fontSize: 11, fontWeight: FontWeight.w600),
                maxLines: 1, overflow: TextOverflow.ellipsis)),
            if (cDist != null) ...[
              Icon(Icons.near_me_rounded, size: 11, color: BrokaColors.neonBlue.withOpacity(0.8)),
              const SizedBox(width: 2),
              Text('${cDist.toStringAsFixed(1)}km', style: const TextStyle(color: BrokaColors.neonBlue, fontSize: 10, fontWeight: FontWeight.w700)),
              const SizedBox(width: 8),
            ],
            // "Where are they" - a labelled target, not a bare 14px glyph.
            //
            // The map has existed since the beginning behind that icon, and
            // nothing about it said what it did or that it would show the
            // OTHER person rather than a pin on the listing. At 14px it was
            // also under the ~44px minimum anyone can reliably hit.
            //
            // Now passes the counterparty explicitly, so the seller gets the
            // buyer's position rather than a map of their own listing back
            // at them - see _mapArgs.
            GestureDetector(
              onTap: _openCounterpartyMap,
              behavior: HitTestBehavior.opaque,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: BrokaColors.neonGreen.withOpacity(0.10),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: BrokaColors.neonGreen.withOpacity(0.35)),
                ),
                child: const Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.map_outlined, size: 13, color: BrokaColors.neonGreen),
                  SizedBox(width: 4),
                  Text('Where', style: TextStyle(color: BrokaColors.neonGreen,
                      fontSize: 10, fontWeight: FontWeight.w700)),
                ]),
              ),
            ),
          ]),
          if (_hasFundedDeal && _dealStatusStr != null) ...[
            const SizedBox(height: 8),
            ProtectionBadge(status: _dealStatusStr, compact: true),
          ],
        ]),
      ),
    );
  }

  Widget _buildChat() => ListView.builder(
    controller: _scrollCtrl,
    keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
    itemCount: _messages.length + (_typing ? 1 : 0) + 1,
    itemBuilder: (_, i) {
      final actionIdx = _messages.length + (_typing ? 1 : 0);
      if (i == actionIdx) return _buildQuickActions();
      if (_typing && i == _messages.length) {
        return const Padding(padding: EdgeInsets.only(bottom: 12), child: ZenoTypingBubble());
      }
      final msg = _messages[i];
      return _Bubble(msg: msg, role: _role, myName: _myFirst,
          myPhoto: _myPhoto, counterPhoto: _sellerPhoto, counterName: _counterName,
          stream: _fresh.contains(msg),
          onStreamed: () => _fresh.remove(msg),
          onGrow: _followStream);
    },
  );

  // "Make Offer" and "Escrow" are gone - typing a number is already picked
  // up as a real offer by the relay classifier, and Zeno already explains
  // escrow contextually when it's relevant. Once a number is on the table
  // the buyer can pay it straight into escrow - this used to be "Tap to
  // finalize", a step most buyers didn't understand, before they could pay.
  Widget _buildActionBar() {
    if (_currentOffer == null || _role != 'buyer' || _hasFundedDeal) return const SizedBox.shrink();
    if (_listing?.listingType == 'auction') return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
      child: GestureDetector(
        onTap: () => _payNow(agreedPrice: _currentOffer),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.lock_outline_rounded, size: 15, color: BrokaColors.success),
          const SizedBox(width: 5),
          Text('Agreed on ${formatKes(_currentOffer!)}? Pay it into escrow',
              style: const TextStyle(color: BrokaColors.success, fontSize: 12, fontWeight: FontWeight.w700)),
        ]),
      ),
    );
  }

  /// Places a call from Zeno's proposal.
  ///
  /// Deliberately thin: it calls the same ApiService.initiateCall that the
  /// header buttons and negotiation_screen use, then opens the same VoIP
  /// screen. Zeno decides whether to OFFER a call; it never sets one up,
  /// so there stays exactly one code path in the app that can ring a phone.
  Future<void> _initiateCall(String callType) async {
    final listing = _listing;
    if (listing == null) return;
    final isSeller = _role == 'seller';
    final info = await ApiService.initiateCall(
      listingId: listing.id,
      listingName: listing.name,
      callType: callType,
      calleeId: isSeller ? _buyerId : null,
    );
    if (!mounted) return;
    if (info == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("Couldn't start the call right now.")));
      return;
    }
    Navigator.pushNamed(context, '/voip-call', arguments: {
      'roomId': info['room_id'],
      'userId': ApiService.currentUserId ?? '',
      'callToken': info['call_token'],
      'isCaller': true,
      'peerName': _counterName,
      'peerId': _role == 'seller' ? _buyerId : _listing?.sellerId,
      // Same source the info strip and chat avatars already read
      // (_sellerInfo['profile_photo']). Null when the seller has no picture
      // set, or when this user IS the seller - _loadCounterparty skips the
      // fetch in that case - and the call screen falls back to initials.
      'peerPhoto': _sellerPhoto,
      // Presence at dial time. The call screen must not claim their phone
      // is ringing when we already know they are not reachable.
      'peerOnline': _counterIsOnline,
      'listingName': listing.name,
      'listingId': listing.id,
      'buyerId': _buyerId ?? ApiService.currentUserId ?? '',
      'callerRole': _role,
      'callType': callType,
    });
  }

  Future<void> _runPendingAction() async {
    final a = _pendingAction;
    if (a == null || _listing == null) return;
    final action = a['action'] as String? ?? '';
    final params = (a['parameters'] as Map?)?.cast<String, dynamic>() ?? {};
    setState(() => _pendingAction = null);

    switch (action) {
      case 'SWITCH_TO_DIRECT_CHAT':
        _markDirectChatSeen();
        Navigator.pushReplacementNamed(context, '/direct-chat',
            arguments: {'listing': _listing, 'role': _role, 'buyer_id': _buyerId});
        return;

      case 'START_AUDIO_CALL':
      case 'START_VIDEO_CALL':
        // Goes through the SAME /calls/initiate path as the header call
        // buttons. Zeno only chooses to offer it; it never sets up a call
        // itself, so there is exactly one place in the app that can ring a
        // phone.
        await _initiateCall(params['call_type'] as String? ?? 'audio');
        return;

      case 'DRAFT_SMS':
        final drafted = await ApiService.zenoDraftSms(
          listingId: _listing!.id, buyerId: _buyerId);
        if (!mounted) return;
        final ctrl = TextEditingController(
            text: drafted?['draft_text'] as String? ?? '');
        final send = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            backgroundColor: BrokaColors.bgCard,
            title: const Text('Send a text',
                style: TextStyle(color: BrokaColors.textHigh, fontSize: 16)),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              // Editable on purpose: Zeno writes a first pass, the human
              // owns the words that actually leave under their name.
              TextField(
                controller: ctrl, maxLines: 5, maxLength: 320,
                style: const TextStyle(color: BrokaColors.textHigh, fontSize: 14),
                decoration: const InputDecoration(border: OutlineInputBorder()),
              ),
              const Text('This goes to their phone as a normal SMS.',
                  style: TextStyle(color: BrokaColors.textLow, fontSize: 11)),
            ]),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel')),
              TextButton(onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Send')),
            ],
          ),
        );
        if (send != true || !mounted) return;
        final res = await ApiService.zenoDraftSms(
            listingId: _listing!.id, buyerId: _buyerId,
            text: ctrl.text, send: true);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(res?['status'] == 'sent'
              ? 'Text sent.'
              : "Couldn't send that text."),
        ));
        return;
    }
  }

  Widget _buildActionProposal() {
    final a = _pendingAction;
    if (a == null) return const SizedBox.shrink();
    final label = a['label'] as String? ?? 'Continue';
    final action = a['action'] as String? ?? '';
    final icon = switch (action) {
      'START_VIDEO_CALL' => Icons.videocam_rounded,
      'START_AUDIO_CALL' => Icons.call_rounded,
      'DRAFT_SMS' => Icons.sms_outlined,
      _ => Icons.forum_rounded,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Row(children: [
        Expanded(
          child: GestureDetector(
            onTap: _runPendingAction,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
              decoration: BoxDecoration(
                color: BrokaColors.gold.withOpacity(0.12),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: BrokaColors.gold.withOpacity(0.45)),
              ),
              child: Row(children: [
                Icon(icon, size: 17, color: BrokaColors.gold),
                const SizedBox(width: 9),
                Expanded(child: Text(label,
                    style: const TextStyle(color: BrokaColors.gold,
                        fontSize: 13, fontWeight: FontWeight.w700))),
                const Icon(Icons.arrow_forward_rounded, size: 15, color: BrokaColors.gold),
              ]),
            ),
          ),
        ),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: () => setState(() => _pendingAction = null),
          child: const Padding(
            padding: EdgeInsets.all(8),
            child: Icon(Icons.close_rounded, size: 18, color: BrokaColors.textLow),
          ),
        ),
      ]),
    );
  }

  /// Home's search pill, as on Zeno's screen: the offer tag and the mic sit
  /// inside it, and the send button scales in once there is a message.
  Widget _buildInputBar() => Padding(
    padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
    child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
      Expanded(
        child: ChatComposerPill(
          focused: _composerFocused,
          child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            ChatComposerAction(
              icon: Icons.sell_outlined,
              tooltip: 'Make an offer',
              onTap: _showOfferDialog,
            ),
            // Zeno can look at a picture here too; only in a deal's room -
            // the listing-less free chat has nowhere to send one.
            if (_listing != null)
              ChatComposerAction(
                icon: Icons.add_photo_alternate_outlined,
                tooltip: 'Show Zeno a photo',
                onTap: _showZenoPhoto,
              ),
            Expanded(
              child: TextField(
                key: const Key('negotiate-composer'),
                controller: _msgCtrl,
                focusNode: _composerFocus,
                style: const TextStyle(color: BrokaColors.textHigh, fontSize: 15.5, height: 1.35),
                minLines: 1,
                maxLines: 5,
                textCapitalization: TextCapitalization.sentences,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                cursorColor: BrokaColors.neonBlue,
                decoration: const InputDecoration(
                  isDense: true,
                  filled: false,
                  hintText: 'Message Zeno',
                  hintStyle: TextStyle(color: BrokaColors.textMid, fontSize: 15),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(horizontal: 4, vertical: 14),
                ),
              ),
            ),
            if (!_hasDraft)
              AnimatedBuilder(
                animation: _voice,
                builder: (_, __) => ChatComposerAction(
                  icon: _voice.isOpen ? Icons.mic_rounded : Icons.mic_none_rounded,
                  tooltip: 'Talk to Zeno',
                  onTap: _openVoice,
                  active: _voice.isOpen,
                  leading: false,
                ),
              ),
          ]),
        ),
      ),
      ChatSendButton(visible: _hasDraft, onTap: () => _send()),
    ]),
  );
}

// ── Message bubble ─────────────────────────────────────────────────────────────

class _Bubble extends StatelessWidget {
  final Message msg; final String role; final String myName;
  final String? myPhoto; final String? counterPhoto; final String counterName;

  /// One of Zeno's replies that has just arrived: written out word by word.
  final bool stream;
  final VoidCallback? onStreamed;
  final VoidCallback? onGrow;
  const _Bubble({required this.msg, required this.role, required this.myName,
      this.myPhoto, this.counterPhoto, this.counterName = 'User',
      this.stream = false, this.onStreamed, this.onGrow});

  @override
  Widget build(BuildContext context) {
    final isBroker = msg.isBroker;
    final isMe     = !isBroker && msg.role == role;
    final color    = isBroker ? BrokaColors.gold : isMe ? BrokaColors.neonBlue : BrokaColors.textMid;
    if (isBroker) return _brokerBubble(context);
    final photo    = isMe ? myPhoto : counterPhoto;
    final initials = isMe ? (myName.isNotEmpty ? myName[0].toUpperCase() : 'M')
                          : (counterName.isNotEmpty ? counterName[0].toUpperCase() : 'U');
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isMe) ...[ _avatar(photo, initials, color), const SizedBox(width: 8) ],
          Flexible(child: Column(
            crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              Padding(padding: EdgeInsets.only(left: isMe ? 0 : 4, right: isMe ? 4 : 0, bottom: 3),
                child: Text(isMe ? myName : counterName,
                    style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: color, letterSpacing: 0.3))),
              // Yours on the brand gradient, theirs on a card - as on
              // Zeno's screen - rather than a role-coloured blue or green.
              Container(
                constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.72),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                decoration: isMe ? myBubbleDecoration() : theirBubbleDecoration(),
                child: Text(msg.content, style: TextStyle(
                    color: isMe ? Colors.white : BrokaColors.textHigh, fontSize: 14, height: 1.45))),
            ],
          )),
          if (isMe) ...[ const SizedBox(width: 8), _avatar(photo, initials, color) ],
        ],
      ),
    );
  }

  Widget _avatar(String? photo, String initials, Color color) => Container(
    width: 30, height: 30,
    decoration: BoxDecoration(shape: BoxShape.circle,
      gradient: const LinearGradient(colors: [BrokaColors.gold, BrokaColors.goldDim]),
      border: Border.all(color: color.withOpacity(0.5), width: 1.5)),
    child: ClipOval(child: photo != null && photo.isNotEmpty
        ? Image.memory(base64Decode(photo), fit: BoxFit.cover)
        : Center(child: Text(initials, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 12)))));

  Widget _brokerBubble(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const ZenoAvatar(size: 30, glow: true),
      const SizedBox(width: 8),
      Flexible(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Padding(padding: EdgeInsets.only(left: 4, bottom: 3),
          // "ZENO", not "AI BROKER". The assistant introduces itself as
          // Zeno everywhere else - the splash ("BOOTING ZENO"),
          // zeno_screen's header, and its own dialogue - so this screen was
          // the one place that named it something different. The wire value
          // stays role=='broker'; only the label changes.
          child: Text('ZENO', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: BrokaColors.gold, letterSpacing: 1.4))),
        if (msg.isAgentInitiated) Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 5),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: BrokaColors.gold.withOpacity(0.12),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: BrokaColors.gold.withOpacity(0.4)),
            ),
            child: const Text('Zeno reached out on your behalf — based on your buy request',
                style: TextStyle(fontSize: 10, fontStyle: FontStyle.italic, color: BrokaColors.gold)),
          ),
        ),
        Container(
          constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: zenoBubbleDecoration(),
          child: ZenoStreamingText(
            msg.content,
            key: ObjectKey(msg),
            style: const TextStyle(color: BrokaColors.textHigh, fontSize: 14, height: 1.5),
            animate: stream,
            onDone: onStreamed,
            onGrow: onGrow,
          )),
      ])),
    ]),
  );
}
