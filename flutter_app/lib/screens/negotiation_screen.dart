// BROKA - Negotiation Screen
// Pure buyer ↔ seller direct chat with:
//   • WebSocket real-time message delivery
//   • Voice note recording & playback
//   • Image sharing (camera or gallery)
//   • Per-buyer thread isolation (buyer_id scoped)
//   • Audio/Video call buttons
//   • M-Pesa deal finalization
//   • Zeno AI accessible via header button (separate screen)
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:image/image.dart' as img;
import '../widgets/aspect_image.dart';
import '../main.dart';
import '../services/api_service.dart';
import '../features/escrow/presentation/escrow_actions.dart';
import '../features/safe_payment/escrow_callout.dart';
import '../features/safe_payment/payments_shown.dart';
import '../features/safe_payment/safe_payment.dart' show openZenoEscrowGuide;
import '../features/calls/domain/call_record.dart' show callSummary;
import '../services/chat_screen_memory.dart';
import '../services/notification_service.dart';
import '../services/photo_capture.dart';
import '../widgets/message_receipt.dart';
import '../widgets/chat_parts.dart';
import '../widgets/collapsing_screen_header.dart';
import '../widgets/constellation_background.dart';
import '../widgets/units_stepper.dart';
import '../widgets/zeno_avatar.dart';
import '../models/models.dart';
import '../models/listing.dart';
import '../services/last_screen_tracker.dart';
import '../services/global_poller_service.dart';
import '../services/local_chat_store.dart';
import '../services/counterparty_profile_cache.dart';
import '../services/zeno_voice_controller.dart';
import '../core/errors/user_facing_error.dart';
import '../utils/backend_time.dart';

// ── Message model extensions ──────────────────────────────────────────────────
// Extends the existing Message model with media fields.
class ChatMessage {
  final String  role;
  final String  content;
  final String  msgType;   // "text" | "voice" | "image" | "call"
  final String? mediaUrl;
  final int?    durationSecs;
  final String? callType;  // "audio" | "video" - set when msgType == "call"
  final bool    viaAi;
  final bool    isBroker;
  /// The server's id; empty while the message is still on its way.
  final String  id;
  final DateTime? createdAt;
  /// The id this phone gave the message before sending it. The server
  /// stores it and hands it back (on /history, the socket and the send's
  /// own answer), which is how the bubble already on screen is recognised
  /// as the same message rather than drawn a second time.
  final String? clientId;
  /// The send did not get through: shown as "Not sent", tap to try again.
  final bool    failed;
  /// When the sender last changed the text. Null unless it was edited.
  final DateTime? editedAt;
  /// Unsend tombstone: content and media are gone, the row stays in place.
  final bool    deleted;
  /// Quote-reply reference: the id of the message being answered, if any.
  final String? replyToMessageId;
  /// Compact preview of the referenced message, from the server or snapshot.
  final Map<String, dynamic>? replyPreview;

  const ChatMessage({
    required this.role,
    this.content = '',
    this.msgType = 'text',
    this.mediaUrl,
    this.durationSecs,
    this.callType,
    this.viaAi = false,
    this.isBroker = false,
    this.createdAt,
    this.clientId,
    this.failed = false,
    this.editedAt,
    this.deleted = false,
    this.replyToMessageId,
    this.replyPreview,
    String? id,
  }) : id = id ?? '';

  /// Not yet confirmed by the server.
  bool get isPending => id.isEmpty;

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
    role:         j['role'] as String? ?? 'buyer',
    content:      j['content'] as String? ?? '',
    msgType:      j['msg_type'] as String? ?? 'text',
    mediaUrl:     j['media_url'] as String?,
    durationSecs: j['duration_secs'] as int?,
    callType:     j['call_type'] as String?,
    viaAi:        j['via_ai'] as bool? ?? false,
    isBroker:     (j['role'] as String?) == 'broker',
    id:           j['id'] as String? ?? '',
    clientId:     j['client_msg_id'] as String?,
    failed:       j['failed'] as bool? ?? false,
    replyToMessageId: j['reply_to_message_id'] as String?,
    replyPreview: (j['reply_preview'] as Map?)?.cast<String, dynamic>(),
    editedAt:     (j['edited_at'] is String && (j['edited_at'] as String).isNotEmpty)
        ? DateTime.tryParse(j['edited_at'] as String)
        : null,
    deleted:      (j['deleted'] as bool?) ?? (j['msg_type'] == 'deleted'),
    // Backend timestamps are naive UTC: parseBackendUtc, not tryParse,
    // or every shown time is shifted by the device's UTC offset.
    createdAt:    (j['created_at'] is String && (j['created_at'] as String).isNotEmpty)
        ? parseBackendUtc(j['created_at'] as String)
        : null,
  );

  factory ChatMessage.fromMessage(Message m) => ChatMessage(
    role:         m.role,
    content:      m.content,
    msgType:      m.msgType,
    mediaUrl:     m.mediaUrl,
    durationSecs: m.durationSecs,
    callType:     m.callType,
    viaAi:        m.viaAi,
    isBroker:     m.isBroker,
    id:           m.id,
    clientId:     m.clientMsgId,
    createdAt:    m.createdAt,
    editedAt:     m.editedAt,
    deleted:      m.deleted,
    replyToMessageId: m.replyToMessageId,
    replyPreview: m.replyPreview,
  );

  ChatMessage withFailed(bool value) => ChatMessage(
    role: role, content: content, msgType: msgType, mediaUrl: mediaUrl,
    durationSecs: durationSecs, callType: callType, viaAi: viaAi,
    isBroker: isBroker, createdAt: createdAt, clientId: clientId,
    failed: value, id: id, editedAt: editedAt, deleted: deleted,
    replyToMessageId: replyToMessageId, replyPreview: replyPreview,
  );

  Map<String, dynamic> toJson() => {
    'role': role,
    'content': content,
    'msg_type': msgType,
    'media_url': mediaUrl,
    'duration_secs': durationSecs,
    'call_type': callType,
    'via_ai': viaAi,
    'id': id,
    'created_at': createdAt?.toIso8601String(),
    'client_msg_id': clientId,
    'edited_at': editedAt?.toIso8601String(),
    'deleted': deleted,
    if (replyToMessageId != null) 'reply_to_message_id': replyToMessageId,
    if (replyPreview != null) 'reply_preview': replyPreview,
    if (failed) 'failed': true,
  };

  /// Compact quote label for a reply preview: text clipped, media labelled,
  /// deleted rendered safely. Shared by the composer preview and bubbles.
  static String replyLabel(Map<String, dynamic>? preview, {String fallback = 'Message'}) {
    if (preview == null) return fallback;
    if (preview['deleted'] == true) return 'Message deleted';
    final msgType = preview['msg_type'] as String?;
    if (msgType == 'image') return 'Photo';
    if (msgType == 'voice' || msgType == 'audio') return 'Voice message';
    if (msgType == 'call') return 'Call';
    final text = (preview['preview'] ?? preview['label'] ?? '').toString();
    if (text.isEmpty) return fallback;
    return text.length > 80 ? '${text.substring(0, 77)}…' : text;
  }
}

/// A voice note or photo still to be (re)sent, kept in memory so "Try
/// again" doesn't mean recording or picking it again.
class _PendingUpload {
  _PendingUpload({
    required this.bytes, required this.contentType, required this.fileName,
    required this.mimeType, this.durationSecs,
    this.replyToMessageId, this.replyPreview, this.caption,
    this.progress = 0,
  });
  final Uint8List bytes;
  final String contentType; // "audio" | "image"
  final String fileName;
  final String mimeType;
  final int? durationSecs;
  final String? replyToMessageId;
  final Map<String, dynamic>? replyPreview;
  final String? caption;
  /// 0..1 bytes handed to the socket. Mutable on purpose: progress ticks
  /// must not rebuild the message list's immutable snapshots.
  double progress;
}

/// Durable image outbox: one file per unsent photo under the app documents
/// directory, plus a tiny metadata sidecar. SharedPreferences only ever
/// holds the file path and caption - never the image bytes, which would
/// bloat the JSON cache and duplicate large payloads on every save.
class _ChatMediaOutbox {
  static Future<Directory> _dir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/chat_outbox');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static String _safeId(String clientId) =>
      clientId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  static Future<({String path, String localUri})?> storeImage(
      String clientId, Uint8List bytes, {String ext = 'jpg'}) async {
    final safeExt = ext == 'png' ? 'png' : 'jpg';
    try {
      final dir = await _dir();
      final id = _safeId(clientId);
      final path = '${dir.path}/$id.$safeExt';
      await File(path).writeAsBytes(bytes, flush: true);
      return (path: path, localUri: 'file://$path');
    } catch (_) {
      return null;
    }
  }

  static Future<void> writeMeta(String clientId,
      {String? replyToMessageId, String? caption}) async {
    try {
      final dir = await _dir();
      await File('${dir.path}/${_safeId(clientId)}.json').writeAsString(jsonEncode({
        'reply_to_message_id': replyToMessageId,
        'caption': caption,
      }));
    } catch (_) {}
  }

  static Future<void> remove(String clientId) async {
    try {
      final dir = await _dir();
      final id = _safeId(clientId);
      for (final ext in ['jpg', 'png']) {
        final img = File('${dir.path}/$id.$ext');
        if (await img.exists()) await img.delete();
      }
      final meta = File('${dir.path}/$id.json');
      if (await meta.exists()) await meta.delete();
    } catch (_) {}
  }

  static Future<String?> pathFor(String clientId) async {
    try {
      final dir = await _dir();
      for (final ext in ['jpg', 'png']) {
        final path = '${dir.path}/${_safeId(clientId)}.$ext';
        if (await File(path).exists()) return path;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  static Future<List<({String clientId, String path, String? replyToMessageId, String? caption})>> list() async {
    try {
      final dir = await _dir();
      if (!await dir.exists()) return [];
      final out = <({String clientId, String path, String? replyToMessageId, String? caption})>[];
      await for (final e in dir.list()) {
        if (e is! File) continue;
        final base = e.path.split('/').last;
        final dot = base.lastIndexOf('.');
        if (dot < 0) continue;
        final ext = base.substring(dot + 1);
        if (ext != 'jpg' && ext != 'png') continue;
        final id = base.substring(0, dot);
        String? replyTo;
        String? caption;
        try {
          final meta = File('${dir.path}/$id.json');
          if (await meta.exists()) {
            final m = jsonDecode(await meta.readAsString()) as Map;
            replyTo = m['reply_to_message_id'] as String?;
            caption = m['caption'] as String?;
          }
        } catch (_) {}
        out.add((clientId: id, path: e.path, replyToMessageId: replyTo, caption: caption));
      }
      return out;
    } catch (_) {
      return [];
    }
  }
}

// ── Screen ────────────────────────────────────────────────────────────────────

class NegotiationScreen extends StatefulWidget {
  const NegotiationScreen({super.key, this.animateBackground = true});

  /// False renders the constellation as one still frame - for tests.
  final bool animateBackground;

  @override
  State<NegotiationScreen> createState() => _NegotiationScreenState();
}

class _NegotiationScreenState extends State<NegotiationScreen>
    with WidgetsBindingObserver {
  Listing?          _listing;
  List<ChatMessage> _messages = [];
  bool              _loading  = true;
  String            _role     = 'buyer';
  String?           _buyerId; // the buyer in this thread (may differ from current user when seller views)

  // WebSocket
  WebSocketChannel? _ws;
  bool              _wsConnected = false;
  // The server closes a socket that says nothing for ~100s, and a mobile
  // network drops idle ones sooner; the app pings, and reconnects when the
  // socket goes anyway. There was no reconnect: once the socket dropped,
  // the rest of the conversation ran on the 4-second history poll.
  Timer?            _wsPingTimer;
  Timer?            _wsReconnectTimer;
  int               _wsReconnectAttempt = 0;

  // Whether the app is on screen. A chat left open behind the phone's home
  // screen still receives messages, which is "delivered" - it used to keep
  // marking them read, every 30 seconds, with nobody looking.
  bool _appVisible = true;

  // Sends go out one at a time, in the order they were typed - so a quick
  // second message can't overtake the first - while the composer stays
  // free to type the next one.
  Future<void> _sendQueue = Future<void>.value();
  // Voice notes and photos not yet confirmed, by client id: what "Try
  // again" resends. Memory only - a cached one from an earlier run can be
  // deleted, not resent.
  final Map<String, _PendingUpload> _uploads = {};
  int _pollTicks = 0;

  // Server ids already represented in _messages - the single source of
  // truth for "have I already shown this one" across cache load, history
  // load, the poll fallback and WS delivery. A message of mine that is
  // still on its way has no server id yet; it carries its client id, and
  // _absorb replaces it with the server's copy when that arrives by any
  // route (see _localCopyOf).
  final Set<String> _seenMsgIds = {};
  void _markSeen(Iterable<ChatMessage> msgs) {
    for (final m in msgs) {
      if (m.id.isNotEmpty) _seenMsgIds.add(m.id);
    }
  }

  // Polling fallback (used when WS not available)
  Timer? _pollTimer;
  Timer? _heartbeatTimer;

  // Typing presence. Outgoing events are debounced (one "typing", then
  // silence until the text goes quiet or is sent); the remote indicator
  // expires on its own so a dropped connection can't leave it stuck on.
  Timer? _typingDebounce;
  Timer? _remoteTypingExpiry;
  bool _typingSent = false;
  bool _remoteTyping = false;
  static const _typingIdle = Duration(seconds: 3);
  static const _typingTtl = Duration(seconds: 6);
  // Beaten every 4s while typing continues: under the remote 6s expiry so
  // the indicator never flickers, over the server's 2s throttle so the
  // heartbeat is relayed, not swallowed.
  static const _typingHeartbeatInterval = Duration(seconds: 4);

  // Quote-reply composer state: the message being answered, if any.
  ChatMessage? _replyTo;
  // Jump-to-original highlight: the message id flashed after tapping a quote.
  String? _highlightId;
  Timer? _highlightTimer;
  // One GlobalKey per settled message id, so tap-to-quote can ask the exact
  // bubble to reveal itself instead of guessing an offset from average
  // heights. Lazily created in the builder; stale ids are dropped when the
  // thread scope changes, and all keys die with the screen.
  final Map<String, GlobalKey> _bubbleKeys = {};

  // Read receipts: when the counterpart last read this thread - a message
  // I sent is "seen" once this is at/after that message's createdAt.
  DateTime? _counterpartLastRead;
  // When the counterpart's DEVICE last received this thread. Strictly
  // earlier than or equal to _counterpartLastRead; the gap between the
  // two is what single-tick vs double-tick expresses.
  DateTime? _counterpartLastDelivered;

  // M-Pesa
  Map<String, dynamic>? _dealInfo;

  // Recording
  final AudioRecorder _recorder    = AudioRecorder();
  final AudioPlayer   _player      = AudioPlayer();
  bool                _isRecording = false;
  // Between the mic tap and the recorder running (the permission prompt
  // can sit in between): a second tap must not start a second recording.
  bool                _startingRecording = false;
  bool                _isPlaying   = false;
  String?             _playingUrl;
  DateTime?           _recordStart;

  final _msgCtrl    = TextEditingController();
  final _scrollCtrl = ScrollController();

  // Language switcher


  // Composer state. _hasDraft drives the mic/send swap and the send
  // button's scale-in; _composerFocused drives the pill's focus ring.
  final FocusNode _composerFocus = FocusNode();
  bool _hasDraft = false;
  bool _composerFocused = false;

  // ── init ───────────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Rebuild only when the draft flips between empty and non-empty, not on
    // every keystroke - a setState per character would rebuild the whole
    // chat screen while typing.
    _msgCtrl.addListener(() {
      final has = _msgCtrl.text.trim().isNotEmpty;
      if (has != _hasDraft && mounted) setState(() => _hasDraft = has);
      _onComposerText(_msgCtrl.text);
    });
    _composerFocus.addListener(() {
      if (mounted && _composerFocus.hasFocus != _composerFocused) {
        setState(() => _composerFocused = _composerFocus.hasFocus);
      }
    });
    _heartbeatTimer = Timer.periodic(
        const Duration(seconds: 60), (_) => ApiService.updateLastSeen());
    ApiService.updateLastSeen();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_listing == null) {
      final args = ModalRoute.of(context)?.settings.arguments;
      if (args is Map) {
        final la = args['listing'];
        if (la is Listing) {
          _listing = la;
        } else if (la is Map) _listing = Listing.fromJson(Map<String, dynamic>.from(la));
        final passedRole = args['role'] as String?;
        _role = passedRole ?? _detectRole();
        // buyer_id passed from inbox screen (identifies the thread for sellers)
        _buyerId = args['buyer_id'] as String?;
        // If buyer, the buyer_id is always the current user
        if (_role == 'buyer') _buyerId = ApiService.currentUserId;
        final dealArg = args['deal'] as Map<String, dynamic>?;
        if (dealArg != null) _dealInfo = dealArg;

        if (_listing == null && args['listingId'] is String) {
          // Restored from a relaunch - only the ID was persisted.
          _role = passedRole ?? args['role'] as String? ?? 'buyer';
          _restoreFromListingId(args['listingId'] as String);
          return;
        }
      } else if (args is Listing) {
        _listing = args;
        _role = _detectRole();
        _buyerId = _role == 'buyer' ? ApiService.currentUserId : null;
      }
      if (_listing != null) {
        LastScreenTracker.save('/direct-chat',
            {'listingId': _listing!.id, 'role': _role, 'buyer_id': _buyerId});
        GlobalPollerService.instance.markScreenActive(_listing!.id, buyerId: _buyerId);
        _startThread();
      }
    }
  }

  /// Everything that runs once the screen knows its listing and thread.
  void _startThread() {
    // The Inbox opens this thread here next time, not in Zeno's room
    // (ChatScreenMemory).
    unawaited(ChatScreenMemory.remember(_listing!.id, _buyerId, ChatScreen.direct));
    // A new thread scope: drop the previous thread's bubble keys so a stale
    // key can never reveal the wrong bubble.
    _bubbleKeys.clear();
    _loadCachedMessages();
    unawaited(_restoreMediaOutbox());
    _loadHistory();
    _connectWebSocket();
    _loadCounterpartyInfo();
    _refreshZenoUnreadCount();
    _presenceRefreshTimer = Timer.periodic(
        const Duration(seconds: 30), (_) {
      _loadCounterpartyInfo();
      _refreshZenoUnreadCount();
      _syncReadState();
    });
    // WS failover. Incoming calls are not polled here any more: this chat
    // ran its own 4-second check with its own dialog and its own ring, on
    // top of the app-wide one (GlobalPollerService) - so a call showed as a
    // dialog AND a notification, and the dialog came up over a call the
    // user had already answered, its Decline hanging that call up. Calls
    // now ring through NotificationService.showIncomingCall alone, which
    // knows when the phone is already on one (ActiveCall).
    _pollTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (_listing == null || !mounted) return;
      if (!_wsConnected) {
        _pollNewMessages();
        // Receipts too: without the socket, nothing else brings them.
        if (++_pollTicks % 3 == 0) _refreshReceipts();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final visible = state == AppLifecycleState.resumed;
    if (visible == _appVisible) return;
    _appVisible = visible;
    // Leaving the chat or backgrounding must not leave the other side
    // seeing "typing..." forever; returning clears our stale flag anyway.
    if (!visible) {
      _sendStopTyping();
      _clearRemoteTyping();
    }
    if (!visible || _listing == null) return;
    // Back on screen: what arrived meanwhile has now been seen, and the
    // socket the OS may have closed in the background is reopened.
    if (!_wsConnected) {
      _wsReconnectAttempt = 0;
      _connectWebSocket();
    }
    unawaited(_pollNewMessages());
    unawaited(_syncReadState());
  }

  Timer? _presenceRefreshTimer;
  Map<String, dynamic>? _counterpartyInfo;
  /// Zeno's messages to this user that they haven't seen in its room - the
  /// badge on the Zeno button. From the server (the Inbox's `zeno_unread`):
  /// it used to be every Zeno message on the thread less a count saved only
  /// when that button was tapped, so Zeno's room read from the Inbox kept
  /// its whole history as "unread".
  int _zenoUnreadCount = 0;

  Future<void> _refreshZenoUnreadCount() async {
    final listing = _listing;
    if (listing == null) return;
    final counts = await ApiService.getUnreadCounts(listing.id, buyerId: _buyerId);
    if (counts == null || !mounted) return;
    setState(() => _zenoUnreadCount = counts.zenoUnread);
  }

  /// profile_photo is inline base64, not a URL - see voip_call_screen.
  Widget _decodedPhoto(String photo) {
    try {
      return Image.memory(base64Decode(photo), fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, __, ___) => _headerInitial());
    } catch (_) {
      return _headerInitial();
    }
  }

  Widget _headerInitial() => Center(child: Text(
      _counterpartyName.isEmpty ? '?' : _counterpartyName[0].toUpperCase(),
      style: const TextStyle(color: Colors.white,
          fontWeight: FontWeight.w800, fontSize: 16)));

  Future<void> _loadCounterpartyInfo() async {
    if (_listing == null) return;
    final counterpartyId = _counterpartyId;
    if (counterpartyId == null) return;
    // Render the cached profile immediately so the header keeps the known
    // name and photo while offline; the network only ever refreshes it.
    try {
      final cached = await CounterpartyProfileCache.load(
          ApiService.currentUserId, counterpartyId);
      if (cached != null && mounted && _counterpartyInfo == null) {
        // Cached presence is never trusted: only a fresh fetch may report
        // online, so an old "online" can't linger offline.
        setState(() => _counterpartyInfo =
            CounterpartyProfileCache.headerFromCache(cached));
      }
    } catch (_) {}
    try {
      final info = await ApiService.getUserProfile(counterpartyId);
      if (!mounted) return;
      setState(() => _counterpartyInfo = info);
      unawaited(CounterpartyProfileCache.save(ApiService.currentUserId,
          CounterpartyProfile.fromLive(counterpartyId, info)));
    } catch (_) {
      // Offline or failed: keep the cached identity rather than falling
      // back to a generic "Buyer"/"Seller" label.
    }
  }

  bool get _counterpartyOnline => (_counterpartyInfo?['is_online'] as bool?) ?? false;
  /// The other person in the thread - the seller, or for a seller the
  /// buyer they opened.
  String? get _counterpartyId => _role == 'buyer' ? _listing?.sellerId : _buyerId;
  /// Their name. A seller saw "Buyer" here, on the call screen and in the
  /// call prompt - never the buyer's name, although the profile this chat
  /// loads for their photo and presence carries it. A buyer sees the name
  /// the listing gives its seller (a business's name, when it has one), as
  /// before.
  String get _counterpartyName {
    final profile = (_counterpartyInfo?['name'] as String?)?.trim() ?? '';
    if (_role == 'buyer') {
      final listed = _listing?.sellerName?.trim() ?? '';
      if (listed.isNotEmpty) return listed;
      return profile.isNotEmpty ? profile : 'Seller';
    }
    return profile.isNotEmpty ? profile : 'Buyer';
  }
  String? get _counterpartyLastSeen => _counterpartyInfo?['last_seen_label'] as String?;
  // Already on the payload _loadCounterpartyInfo fetches - the screen just
  // never read it. Used by the call screen's avatar and the header below,
  // both of which were falling back to a single initial.
  String? get _counterpartyPhoto => _counterpartyInfo?['profile_photo'] as String?;

  Future<void> _restoreFromListingId(String listingId) async {
    try {
      final listing = await ApiService.getListing(listingId);
      if (!mounted) return;
      setState(() {
        _listing = listing;
        _buyerId ??= _role == 'buyer' ? ApiService.currentUserId : null;
      });
      LastScreenTracker.save('/direct-chat',
          {'listingId': listingId, 'role': _role, 'buyer_id': _buyerId});
      GlobalPollerService.instance.markScreenActive(listingId, buyerId: _buyerId);
      _startThread();
    } catch (_) {
      if (mounted) Navigator.pushReplacementNamed(context, '/home');
    }
  }

  String _detectRole() {
    final uid = ApiService.currentUserId;
    if (uid != null && _listing?.sellerId != null && uid == _listing!.sellerId) {
      return 'seller';
    }
    return 'buyer';
  }

  // ── WebSocket ──────────────────────────────────────────────────────────────

  void _connectWebSocket() {
    _wsReconnectTimer?.cancel();
    final listing = _listing;
    final token   = ApiService.authToken;
    if (listing == null || token == null || !mounted) return;

    // Build WS URL: replace http(s) with ws(s)
    final base = ApiService.baseUrl
        .replaceFirst('https://', 'wss://')
        .replaceFirst('http://',  'ws://');

    var url = '$base/media/ws/${listing.id}?token=$token';
    if (_role == 'seller' && _buyerId != null) {
      url += '&buyer_id=$_buyerId';
    }

    // The socket being replaced must not report its own closing as this
    // one's: every handler below checks it is still the current socket.
    final old = _ws;
    _ws = null;
    try {
      old?.sink.close();
    } catch (_) {}

    final WebSocketChannel ws;
    try {
      ws = WebSocketChannel.connect(Uri.parse(url));
    } catch (_) {
      _wsConnected = false;
      _scheduleReconnect();
      return;
    }
    _ws = ws;
    // Don't mark connected yet - .connect() only constructs the channel,
    // it doesn't confirm the handshake succeeded. Wait for the server's
    // first message (or just a successful stream event) before trusting
    // it, so the polling fallback isn't wrongly suppressed while a failed
    // connection is still timing out.
    _wsConnected = false;
    ws.ready.then((_) {
      if (!mounted || !identical(_ws, ws)) return;
      _wsReconnectAttempt = 0;
      setState(() => _wsConnected = true);
      // Back online: anything typed while offline goes out on its own.
      _flushFailed();
    }).catchError((_) {
      // The stream's onError/onDone below reports it and reconnects.
    });
    ws.stream.listen(
      (raw) {
        if (!mounted || !identical(_ws, ws)) return;
        _onSocketFrame(raw);
      },
      onError: (_) => _onSocketClosed(ws),
      onDone: () => _onSocketClosed(ws),
    );
    _wsPingTimer?.cancel();
    _wsPingTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      if (!identical(_ws, ws) || !_wsConnected) return;
      try {
        ws.sink.add(jsonEncode({'type': 'ping'}));
      } catch (_) {}
    });
  }

  // ── Typing presence ────────────────────────────────────────────────────
  // One "typing" when input starts, a heartbeat while it continues, and
  // "stop_typing" when it settles - never an event per character. The
  // heartbeat (every few seconds) keeps the other side's indicator alive
  // past its expiry while the user is still typing; the server throttles
  // faster repeats, so a heartbeat can never flood the thread.
  Timer? _typingHeartbeat;

  void _sendTypingEvent() {
    if (!_wsConnected) return;
    try {
      _ws?.sink.add(jsonEncode({'type': 'typing'}));
    } catch (_) {}
  }

  void _onComposerText(String text) {
    if (!_wsConnected) return;
    if (text.trim().isEmpty) {
      _sendStopTyping();
      return;
    }
    if (_typingSent) {
      _typingDebounce?.cancel();
      _typingDebounce = Timer(_typingIdle, _sendStopTyping);
      return;
    }
    _typingSent = true;
    _sendTypingEvent();
    _typingDebounce?.cancel();
    _typingDebounce = Timer(_typingIdle, _sendStopTyping);
    // While the composer holds text, re-announce before the other side's
    // expiry can clear a user who never stopped typing.
    _typingHeartbeat?.cancel();
    _typingHeartbeat = Timer.periodic(_typingHeartbeatInterval, (_) {
      if (!mounted || !_typingSent || !_wsConnected) {
        _typingHeartbeat?.cancel();
        return;
      }
      if (_msgCtrl.text.trim().isEmpty) {
        _sendStopTyping();
        return;
      }
      _sendTypingEvent();
    });
  }

  void _sendStopTyping() {
    _typingDebounce?.cancel();
    _typingHeartbeat?.cancel();
    if (!_typingSent) return;
    _typingSent = false;
    if (!_wsConnected) return;
    try {
      _ws?.sink.add(jsonEncode({'type': 'stop_typing'}));
    } catch (_) {}
  }

  /// Outgoing typing state died with the socket: the next keystroke after a
  /// reconnect must announce afresh, not assume the other side remembers.
  void _resetOutgoingTyping() {
    _typingDebounce?.cancel();
    _typingHeartbeat?.cancel();
    _typingSent = false;
  }

  void _clearRemoteTyping() {
    _remoteTypingExpiry?.cancel();
    if (_remoteTyping && mounted) setState(() => _remoteTyping = false);
  }

  void _handleRemoteTyping(bool typing) {
    _remoteTypingExpiry?.cancel();
    if (!typing) {
      if (_remoteTyping && mounted) setState(() => _remoteTyping = false);
      return;
    }
    if (mounted && !_remoteTyping) setState(() => _remoteTyping = true);
    // A device that loses connectivity sends no stop_typing: expire the
    // indicator rather than leaving the other side "typing" forever.
    _remoteTypingExpiry = Timer(_typingTtl, () {
      if (mounted && _remoteTyping) setState(() => _remoteTyping = false);
    });
  }

  void _onSocketClosed(WebSocketChannel ws) {
    if (!identical(_ws, ws)) return;
    _wsPingTimer?.cancel();
    _clearRemoteTyping();
    _resetOutgoingTyping();
    if (!mounted) return;
    setState(() => _wsConnected = false);
    // Refused for good - no such thread (4003) or listing (4004): asking
    // again every 30 seconds changes nothing. The poll carries on.
    final code = ws.closeCode;
    if (code == 4003 || code == 4004) return;
    // 4001: the token in the URL had expired (they last 15 minutes) - get
    // a new one first, or every reconnect is refused the same way.
    _scheduleReconnect(renewFirst: code == 4001);
  }

  void _scheduleReconnect({bool renewFirst = false}) {
    // In the background the OS is likely to close it again; coming back
    // on screen reconnects (didChangeAppLifecycleState).
    if (!mounted || !_appVisible) return;
    _wsReconnectTimer?.cancel();
    final seconds = min(30, 2 << min(_wsReconnectAttempt, 4)); // 2, 4, 8, 16, 30
    _wsReconnectAttempt++;
    _wsReconnectTimer = Timer(Duration(seconds: seconds), () async {
      if (!mounted) return;
      if (renewFirst) await ApiService.renewSession();
      if (mounted) _connectWebSocket();
    });
  }

  void _onSocketFrame(dynamic raw) {
    final Map<String, dynamic> data;
    try {
      data = jsonDecode(raw as String) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    if (!_wsConnected) setState(() => _wsConnected = true);
    _wsReconnectAttempt = 0;
    switch (data['type']) {
      case 'ping':
        try {
          _ws?.sink.add(jsonEncode({'type': 'pong'}));
        } catch (_) {}
        return;
      case 'receipt':
        _applyReceipt(data);
        return;
      case 'message_edited':
        _applyMessageChange(data, deleted: false);
        return;
      case 'message_deleted':
        _applyMessageChange(data, deleted: true);
        return;
      case 'typing':
      case 'stop_typing':
        // Only the other participant's indicator matters here; our own
        // devices are excluded server-side, so anything arriving is theirs.
        // Typing is presence, never a message: nothing is stored or cached.
        final other = _role == 'buyer' ? 'seller' : 'buyer';
        final senderRole = data['role'] as String?;
        if (senderRole != null && senderRole != other) return;
        _handleRemoteTyping(data['type'] == 'typing');
        return;
      case 'message':
        final cm = ChatMessage.fromJson(data);
        // Direct chat never shows Zeno (broker) messages - same rule as
        // _loadHistory/_pollNewMessages (_absorb).
        if (!_absorb(cm)) return;
        if (cm.role != _role) _handleRemoteTyping(false);
        setState(() {});
        _scrollDown();
        unawaited(_cacheMessages());
        if (cm.role != _role) {
          unawaited(_syncReadState());
          _notifyIfAway(cm);
        }
    }
  }

  /// The other side's device just received or read the thread
  /// (backend media.broadcast_receipt): turn the ticks now, not at the
  /// next read-status poll.
  void _applyReceipt(Map<String, dynamic> data) {
    final other = _role == 'buyer' ? 'seller' : 'buyer';
    if (data['role'] != other) return;
    DateTime? at(String key) {
      final v = data[key];
      return v is String ? DateTime.tryParse(v)?.toLocal() : null;
    }
    setState(() {
      _counterpartLastDelivered = _later(_counterpartLastDelivered, at('last_delivered'));
      _counterpartLastRead      = _later(_counterpartLastRead, at('last_read'));
    });
  }

  /// The sender edited or unsent a message (backend media.broadcast_
  /// message_update). Update the copy already on screen by id: a delete
  /// must remove the words from every device that had them, not only the
  /// phone that tapped it.
  void _applyMessageChange(Map<String, dynamic> data, {required bool deleted}) {
    final id = data['id'] as String?;
    if (id == null || id.isEmpty) return;
    final i = _messages.indexWhere((m) => m.id == id);
    if (i < 0) return;
    final old = _messages[i];
    if (deleted) {
      if (old.deleted) return;
      _messages[i] = ChatMessage(
        role: old.role, content: '', msgType: 'deleted',
        viaAi: old.viaAi, isBroker: old.isBroker,
        id: old.id, clientId: old.clientId, createdAt: old.createdAt,
        editedAt: old.editedAt, deleted: true,
        replyToMessageId: old.replyToMessageId, replyPreview: old.replyPreview,
      );
    } else {
      final content = data['content'] as String?;
      if (content == null) return;
      _messages[i] = ChatMessage(
        role: old.role, content: content, msgType: old.msgType,
        mediaUrl: old.mediaUrl, durationSecs: old.durationSecs,
        callType: old.callType, viaAi: old.viaAi, isBroker: old.isBroker,
        id: old.id, clientId: old.clientId, createdAt: old.createdAt,
        editedAt: (data['edited_at'] is String &&
                (data['edited_at'] as String).isNotEmpty)
            ? DateTime.tryParse(data['edited_at'] as String)?.toLocal()
            : DateTime.now(),
        deleted: old.deleted,
        replyToMessageId: old.replyToMessageId, replyPreview: old.replyPreview,
      );
    }
    setState(() {});
    unawaited(_cacheMessages());
  }

  /// Reconcile a message already on screen with the server's copy. Edits
  /// and unsends arrive on the socket, but a phone that was offline/closed
  /// only sees them in the next history poll - without this, the old words
  /// stayed on screen for the rest of the session.
  bool _updateIfChanged(ChatMessage m) {
    if (m.id.isEmpty) return false;
    final i = _messages.indexWhere((x) => x.id == m.id);
    if (i < 0) return false;
    final old = _messages[i];
    final editedChanged = (old.editedAt == null) != (m.editedAt == null) ||
        (old.editedAt != null && m.editedAt != null &&
            !old.editedAt!.isAtSameMomentAs(m.editedAt!));
    final changed = old.content != m.content ||
        old.msgType != m.msgType ||
        old.deleted != m.deleted ||
        editedChanged ||
        old.mediaUrl != m.mediaUrl ||
        old.replyToMessageId != m.replyToMessageId;
    if (changed) _messages[i] = m;
    return changed;
  }

  /// A message that arrived while the app is in the background. On screen
  /// it needs no notification - it is right there.
  void _notifyIfAway(ChatMessage cm) {
    final listing = _listing;
    if (_appVisible || listing == null || cm.msgType == 'call') return;
    // The server pushes every message, and Android shows that push with the
    // app in any state - posting this one too would buzz twice.
    if (GlobalPollerService.instance.pushReady) return;
    final who = _counterpartyName;
    final preview = switch (cm.msgType) {
      'image' => '\u{1F4F7} Photo',
      'voice' => '\u{1F3A4} Voice message',
      _ => cm.content,
    };
    NotificationService.instance.showNewMessage(
      fromName: who,
      preview: preview,
      // One notification per conversation, shared with GlobalPollerService
      // and the server's push (NotificationService.threadTag).
      listingId: listing.id,
      buyerId: _buyerId,
      payload: {
        'type': 'new_message',
        'listingId': listing.id,
        'buyerId': _buyerId,
        'myRole': _role,
      },
    );
  }

  static DateTime? _later(DateTime? a, DateTime? b) {
    if (a == null) return b;
    if (b == null) return a;
    return b.isAfter(a) ? b : a;
  }

  // ── One bubble per message ───────────────────────────────────────────────

  /// Puts a message from the server on screen - once. When it is the
  /// server's copy of one of mine still showing as sent-from-here, it
  /// takes that bubble's place instead of standing beside it. Returns
  /// whether anything changed. The caller calls setState.
  ///
  /// The duplicate this prevents: my message showed, the send's answer
  /// was still on its way, and the 4-second poll (or the socket) delivered
  /// the stored copy as "new" - two bubbles, one of which only went away
  /// when the chat was reopened.
  bool _absorb(ChatMessage m) {
    if (m.isBroker || m.viaAi) return false;
    if (m.id.isNotEmpty && _seenMsgIds.contains(m.id)) return false;
    if (m.id.isNotEmpty) _seenMsgIds.add(m.id);
    final i = _localCopyOf(m);
    if (i >= 0) {
      final cid = _messages[i].clientId;
      if (cid != null) _uploads.remove(cid);
      _messages[i] = m;
    } else {
      _messages.insert(_slotFor(_messages, m), m);
    }
    return true;
  }

  /// Where [m] goes in [list] so the thread reads in time order: after
  /// everything not later than it. What arrives here is not always new -
  /// the chat socket replays the thread's last fifty messages on every
  /// connect, and the poll returns the whole thread - so anything this
  /// screen had not seen yet went to the bottom whatever its age: a call
  /// from four days ago under today's "Yooh". A message with no time stays
  /// where it is put, and nothing moves past it.
  static int _slotFor(List<ChatMessage> list, ChatMessage m) {
    final at = m.createdAt;
    var i = list.length;
    if (at == null) return i;
    while (i > 0) {
      final before = list[i - 1].createdAt;
      if (before == null || !before.isAfter(at)) break;
      i--;
    }
    return i;
  }

  /// [msgs] in time order; equal times keep their order.
  static List<ChatMessage> _inTimeOrder(Iterable<ChatMessage> msgs) {
    final out = <ChatMessage>[];
    for (final m in msgs) {
      out.insert(_slotFor(out, m), m);
    }
    return out;
  }

  /// Index of my not-yet-confirmed bubble that [m] is the server's copy of,
  /// or -1. By client id; failing that (a server too old to hand it back),
  /// the oldest unconfirmed bubble of the same kind and words.
  int _localCopyOf(ChatMessage m) {
    if (m.role != _role || m.id.isEmpty) return -1;
    final cid = m.clientId;
    if (cid != null && cid.isNotEmpty) {
      return _messages.indexWhere((x) => x.isPending && x.clientId == cid);
    }
    return _messages.indexWhere((x) =>
        x.isPending && x.clientId != null && x.msgType == m.msgType &&
        (m.msgType != 'text' || x.content == m.content));
  }

  /// The send's own answer: [server] is the stored copy of the bubble
  /// [clientId] names.
  void _confirm(String clientId, ChatMessage server) {
    _uploads.remove(clientId);
    if (!mounted) return;
    setState(() {
      final i = _messages.indexWhere((x) => x.isPending && x.clientId == clientId);
      if (server.id.isNotEmpty && _seenMsgIds.contains(server.id)) {
        // The poll or the socket got here first and already shows it.
        if (i >= 0) _messages.removeAt(i);
        return;
      }
      if (server.id.isNotEmpty) _seenMsgIds.add(server.id);
      if (i >= 0) {
        _messages[i] = server;
      } else {
        _messages.insert(_slotFor(_messages, server), server);
      }
    });
    unawaited(_cacheMessages());
  }

  void _markFailed(String clientId) {
    if (!mounted) return;
    final i = _messages.indexWhere((x) => x.isPending && x.clientId == clientId);
    if (i < 0) return;
    setState(() => _messages[i] = _messages[i].withFailed(true));
    unawaited(_cacheMessages());
  }

  /// The server's thread, followed by whatever of mine it doesn't have yet
  /// (still sending, or failed). Replacing the list with the server's
  /// outright - as this used to - dropped a message typed while the
  /// history was loading.
  List<ChatMessage> _mergeWithUnsent(List<ChatMessage> server) {
    final out = List<ChatMessage>.of(server);
    final claimed = <int>{};
    for (final local in _messages.where((m) => m.isPending && m.clientId != null)) {
      final j = _serverCopyIndex(server, local, claimed);
      if (j >= 0) {
        claimed.add(j);
        _uploads.remove(local.clientId);
      } else {
        out.add(local);
      }
    }
    return out;
  }

  int _serverCopyIndex(List<ChatMessage> server, ChatMessage local, Set<int> claimed) {
    for (var j = 0; j < server.length; j++) {
      if (claimed.contains(j)) continue;
      final s = server[j];
      if (s.role != _role) continue;
      if (s.clientId != null) {
        if (s.clientId == local.clientId) return j;
        continue;
      }
      // A server too old to hand the client id back: the same kind and
      // words, not from before this bubble was made (with room for the
      // phone's clock being off) - "Yooh" sent last week is not this one.
      if (s.msgType != local.msgType) continue;
      if (s.msgType == 'text' && s.content != local.content) continue;
      final made = local.createdAt;
      final at = s.createdAt;
      if (made != null && at != null &&
          at.isBefore(made.subtract(const Duration(minutes: 5)))) {
        continue;
      }
      return j;
    }
    return -1;
  }

  // ── Offline persistence ────────────────────────────────────────────────────
  // Thread-scoped cache key so buyer/seller/listing combinations never collide.
  String _threadScopeKey() => 'direct_${_listing?.id}_${_buyerId ?? ''}';

  /// Show whatever was last cached on-device immediately, before the network
  /// call even starts - this is what makes the thread visible instantly even
  /// with no connection at all, the same way WhatsApp opens a chat straight
  /// into its history rather than a blank/loading screen.
  Future<void> _loadCachedMessages() async {
    if (_listing == null) return;
    final cached = await LocalChatStore.load(_threadScopeKey());
    if (cached.isEmpty || !mounted || _messages.isNotEmpty) return;
    try {
      final restored = <ChatMessage>[];
      for (final m in cached.map(ChatMessage.fromJson)) {
        if (m.isPending) {
          // An id-less copy from a build before client ids: nothing can
          // match it to the server's, so it would only ever be a duplicate.
          if (m.clientId == null) continue;
          // Was on its way when the app last closed: say so, and let the
          // user send it again (the server keeps one copy either way).
          restored.add(m.failed ? m : m.withFailed(true));
        } else {
          restored.add(m);
        }
      }
      setState(() {
        // A cache this screen saved out of order (see _slotFor) reads in
        // order from now on, even before the server's copy arrives.
        _messages = _inTimeOrder(restored);
        _loading = false;
      });
      _markSeen(_messages);
      _scrollToLatestAfterLayout();
    } catch (_) {}
  }

  /// Persist the thread for instant offline open. Image bytes are never
  /// duplicated here: a data URI over ~50KB is stored as an empty
  /// placeholder in the cache (the full image re-fetches with history),
  /// while pending outbox photos keep their small file:// reference.
  static const _cacheMediaBudget = 50 * 1024;

  Future<void> _cacheMessages() {
    final slimmed = _messages.map((m) {
      final j = m.toJson();
      final url = j['media_url'] as String?;
      if (url != null &&
          url.length > _cacheMediaBudget &&
          !url.startsWith('file://')) {
        j['media_url'] = '';
      }
      return j;
    }).toList();
    return LocalChatStore.save(_threadScopeKey(), slimmed);
  }

  /// Tells the backend this side has the thread - read if the chat is on
  /// screen, only delivered if the app is in the background - and refreshes
  /// the other side's watermarks (the ticks on my own messages). Called
  /// whenever I load/receive messages while this screen is open, plus every
  /// 30s via _presenceRefreshTimer.
  Future<void> _syncReadState() async {
    final listing = _listing;
    if (listing == null) return;
    if (_appVisible) {
      unawaited(ApiService.markThreadRead(listing.id, buyerId: _buyerId));
    } else {
      unawaited(ApiService.markThreadDelivered(listing.id, buyerId: _buyerId));
    }
    await _refreshReceipts();
  }

  /// The other side's watermarks, applied forward only. A failed request
  /// changes nothing: it used to come back as "never read", which turned
  /// every seen tick back to a single grey one until the next poll.
  Future<void> _refreshReceipts() async {
    final listing = _listing;
    if (listing == null) return;
    final status = await ApiService.getReadStatus(listing.id, buyerId: _buyerId);
    if (status == null || !mounted) return;
    final other = _role == 'buyer' ? 'seller' : 'buyer';
    setState(() {
      _counterpartLastRead      = _later(_counterpartLastRead, status['${other}_last_read']);
      _counterpartLastDelivered = _later(_counterpartLastDelivered, status['${other}_last_delivered']);
    });
  }

  // ── Polling fallback ───────────────────────────────────────────────────────

  Future<void> _loadHistory() async {
    try {
      final history = await ApiService.getNegotiationHistory(
        _listing!.id,
        buyerId: _role == 'seller' ? _buyerId : null,
      );
      // Direct chat shows ONLY the buyer<->seller conversation. Zeno
      // communicates exclusively through its own private AI screen
      // (negotiate_screen.dart) - it must never appear here, since each
      // side's conversation with Zeno is meant to stay private.
      final directOnly = history.where((m) => (m.role == 'buyer' || m.role == 'seller') && !m.viaAi).toList();
      final server = directOnly.map(ChatMessage.fromMessage).toList();
      if (!mounted) return;
      setState(() {
        _messages = _mergeWithUnsent(server);
        _loading = false;
      });
      _seenMsgIds.clear();
      _markSeen(server);
      _scrollToLatestAfterLayout();
      unawaited(_cacheMessages());
      unawaited(_syncReadState());
      // History proved the server reachable: flush anything still unsent.
      _flushFailed();
    } catch (_) {
      // Offline or request failed - fall back to on-device cache instead of
      // leaving the screen blank. Only replaces _messages if nothing has
      // been shown yet (don't clobber a cache already loaded/in-progress).
      if (_messages.isEmpty) await _loadCachedMessages();
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pollNewMessages() async {
    final listing = _listing;
    if (listing == null) return;
    try {
      final history = await ApiService.getNegotiationHistory(
        listing.id,
        buyerId: _role == 'seller' ? _buyerId : null,
      );
      if (!mounted) return;
      var changed = false;
      var inbound = false;
      for (final m in history) {
        if (!(m.role == 'buyer' || m.role == 'seller') || m.viaAi) continue;
        final cm = ChatMessage.fromMessage(m);
        if (_absorb(cm)) {
          changed = true;
          if (m.role != _role) inbound = true;
        } else if (_updateIfChanged(cm)) {
          changed = true;
        }
      }
      if (!changed) return;
      setState(() {});
      _scrollDown();
      unawaited(_cacheMessages());
      if (inbound) unawaited(_syncReadState());
    } catch (_) {}
  }

  // ── Sending ────────────────────────────────────────────────────────────────

  static final Random _random = Random();

  /// This phone's id for a message it is about to send (the server keeps
  /// it - NegotiationMessage.client_msg_id). Unique enough per sender: a
  /// clock in microseconds plus 32 random bits.
  String _newClientId() =>
      'c${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
      '${_random.nextInt(1 << 32).toRadixString(36)}';

  void _enqueue(Future<void> Function() job) {
    _sendQueue = _sendQueue.then((_) => job()).catchError((Object e) {
      debugPrint('[DirectChat] send job failed: $e');
    });
  }

  /// Snapshot the reply being answered for the optimistic bubble, so the
  /// quote renders instantly and survives a restart via the message cache.
  static Map<String, dynamic>? _replySnapshotOf(ChatMessage m) {
    if (m.deleted) return {'message_id': m.id, 'sender_role': m.role, 'deleted': true, 'label': 'Message deleted'};
    if (m.msgType == 'image') {
      return {'message_id': m.id, 'sender_role': m.role, 'msg_type': 'image', 'preview': 'Photo', 'deleted': false};
    }
    if (m.msgType == 'voice') {
      return {'message_id': m.id, 'sender_role': m.role, 'msg_type': 'voice', 'preview': 'Voice message', 'deleted': false};
    }
    final text = m.content.trim();
    return {
      'message_id': m.id,
      'sender_role': m.role,
      'msg_type': m.msgType,
      'preview': text.length > 140 ? '${text.substring(0, 137)}…' : text,
      'deleted': false,
    };
  }

  Future<void> _send() async {
    final text = _msgCtrl.text.trim();
    if (text.isEmpty || _listing == null) return;
    _sendStopTyping();
    final clientId = _newClientId();
    final reply = _replyTo;
    setState(() {
      _messages.add(ChatMessage(
        role: _role, content: text, msgType: 'text',
        clientId: clientId, createdAt: DateTime.now().toUtc(),
        replyToMessageId: reply?.id.isEmpty == true ? null : reply?.id,
        replyPreview: reply == null ? null : _replySnapshotOf(reply),
      ));
      _replyTo = null;
    });
    _msgCtrl.clear();
    _scrollDown();
    unawaited(_cacheMessages());
    _enqueue(() => _deliverText(clientId, text,
        replyToMessageId: reply?.id.isEmpty == true ? null : reply?.id));
  }

  Future<void> _deliverText(String clientId, String text, {String? replyToMessageId}) async {
    final listing = _listing;
    if (listing == null) return;
    try {
      final saved = await ApiService.sendDirectMessage(
        listingId:   listing.id,
        senderRole:  _role,
        senderId:    ApiService.currentUserId ?? 'anon',
        content:     text,
        buyerId:     _buyerId,
        clientMsgId: clientId,
        replyToMessageId: replyToMessageId,
      );
      if (saved != null && ((saved['id'] as String?) ?? '').isNotEmpty) {
        _confirm(clientId, ChatMessage.fromJson({'role': _role, ...saved}));
      } else {
        // A server that answers {"ok": true} alone: find it in the thread.
        await _pollNewMessages();
      }
    } catch (e) {
      debugPrint('[DirectChat] message not sent: $e');
      _markFailed(clientId);
      _notSent('Message not sent. Tap it to try again.');
    }
  }

  /// Progress ticks for one upload, repainted only when the percent visibly
  /// moves: the byte stream fires per 64KB chunk, and a setState per chunk
  /// would rebuild the whole chat sixty times per photo.
  void _reportUploadProgress(String clientId, int sent, int total) {
    final upload = _uploads[clientId];
    if (upload == null || total <= 0 || !mounted) return;
    final next = (sent / total).clamp(0.0, 1.0);
    if (next < 1.0 && (next - upload.progress) < 0.05 && upload.progress > 0) return;
    upload.progress = next;
    setState(() {});
  }

  Future<void> _deliverUpload(String clientId) async {
    final listing = _listing;
    final upload = _uploads[clientId];
    if (listing == null || upload == null) return;
    try {
      final saved = await ApiService.uploadMedia(
        listingId:    listing.id,
        senderRole:   _role,
        senderId:     ApiService.currentUserId ?? 'anon',
        contentType:  upload.contentType,
        fileBytes:    upload.bytes,
        fileName:     upload.fileName,
        mimeType:     upload.mimeType,
        buyerId:      _buyerId,
        durationSecs: upload.durationSecs,
        clientMsgId:  clientId,
        // Voice notes ride the same reply/caption contract as photos.
        replyToMessageId: upload.replyToMessageId,
        caption: upload.caption,
        onProgress: (sent, total) => _reportUploadProgress(clientId, sent, total),
      );
      _confirm(clientId, ChatMessage.fromJson({'role': _role, ...saved}));
    } catch (e) {
      debugPrint('[DirectChat] upload failed: $e');
      _markFailed(clientId);
      _notSent(upload.contentType == 'audio'
          ? 'Voice note not sent. Tap it to try again.'
          : 'Photo not sent. Tap it to try again.');
    }
  }

  void _notSent(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  /// A bubble showing "Not sent": send it again, or drop it.
  Future<void> _onUnsentTap(ChatMessage m) async {
    final clientId = m.clientId;
    if (clientId == null) return;
    final canResend = m.msgType == 'text' || _uploads.containsKey(clientId);
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: BrokaColors.bgMid,
      builder: (ctx) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (canResend)
          ListTile(
            leading: const Icon(Icons.refresh_rounded, color: BrokaColors.neonGreen),
            title: const Text('Try again', style: TextStyle(color: BrokaColors.textHigh)),
            onTap: () => Navigator.pop(ctx, 'retry'),
          ),
        ListTile(
          leading: const Icon(Icons.delete_outline_rounded, color: BrokaColors.danger),
          title: const Text('Delete', style: TextStyle(color: BrokaColors.textHigh)),
          subtitle: canResend ? null : const Text(
              'This was not sent before the app closed. Send it again from the chat.',
              style: TextStyle(color: BrokaColors.textLow, fontSize: 12)),
          onTap: () => Navigator.pop(ctx, 'delete'),
        ),
      ])),
    );
    if (!mounted || choice == null) return;
    final i = _messages.indexWhere((x) => x.isPending && x.clientId == clientId);
    if (i < 0) return; // confirmed meanwhile
    if (choice == 'delete') {
      setState(() => _messages.removeAt(i));
      _uploads.remove(clientId);
      if (m.msgType == 'image') unawaited(_ChatMediaOutbox.remove(clientId));
      unawaited(_cacheMessages());
      return;
    }
    _retryMessage(clientId);
  }

  /// Resend one optimistic message under its original client id: the server
  /// recognises an arrival that already landed instead of storing a second
  /// copy. Shared by the manual "Try again" sheet and the automatic flush
  /// that runs when connectivity returns.
  void _retryMessage(String clientId) {
    final i = _messages.indexWhere((x) => x.isPending && x.clientId == clientId);
    if (i < 0) return; // confirmed meanwhile
    final m = _messages[i];
    if (m.msgType != 'text' && !_uploads.containsKey(clientId)) return;
    final upload = _uploads[clientId];
    if (upload != null) upload.progress = 0;
    setState(() => _messages[i] = _messages[i].withFailed(false));
    if (m.msgType == 'text') {
      _enqueue(() => _deliverText(clientId, m.content,
          replyToMessageId: m.replyToMessageId));
    } else if (m.msgType == 'image') {
      _enqueue(() async {
        final path = await _ChatMediaOutbox.pathFor(clientId);
        if (path == null) {
          _markFailed(clientId);
          _notSent('Photo file is gone. Send it again from the gallery.');
          return;
        }
        await _deliverOutboxUpload(clientId, path);
      });
    } else {
      _enqueue(() => _deliverUpload(clientId));
    }
  }

  bool _flushing = false;

  /// Automatic delivery after reconnecting: every still-failed optimistic
  /// message goes again, oldest first, under its original client id. The
  /// queue serialises them and the server dedupes arrivals, so a message
  /// typed offline is delivered once, in order, without tapping anything.
  /// A flush already running is never doubled up.
  void _flushFailed() {
    if (_flushing || !mounted) return;
    final ids = [
      for (final m in _messages)
        if (m.failed && m.clientId != null) m.clientId!,
    ];
    if (ids.isEmpty) return;
    _flushing = true;
    for (final id in ids) {
      _retryMessage(id);
    }
    _enqueue(() async {
      _flushing = false;
    });
  }

  // ── Edit / unsend ──────────────────────────────────────────────────────────

  bool _withinWindow(DateTime? at, Duration window) {
    if (at == null) return false;
    return DateTime.now().toUtc().difference(at.toUtc()) <= window;
  }

  /// Long-press on a direct message. Reply is offered on any settled,
  /// visible direct message from either side; edit/unsend stay restricted
  /// to the sender's own messages inside their windows (server-enforced).
  Future<void> _onMessageLongPress(ChatMessage m) async {
    if (m.isBroker || m.viaAi || m.isPending || m.id.isEmpty) return;
    final own = m.role == _role;
    final canEdit = own && !m.deleted && m.msgType == 'text' &&
        _withinWindow(m.createdAt, const Duration(minutes: 15));
    final canDelete = own && !m.deleted &&
        _withinWindow(m.createdAt, const Duration(hours: 48));
    final canReply = !m.deleted && m.msgType != 'deleted';
    if (!canEdit && !canDelete && !canReply) return;

    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: BrokaColors.bgMid,
      builder: (ctx) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        ListTile(
          dense: true,
          title: Text(
            m.msgType == 'image'
                ? 'Photo${m.content.trim().isEmpty ? '' : ' · ${m.content.trim()}'}'
                : m.msgType == 'voice'
                    ? 'Voice message'
                    : (m.content.length > 60 ? '${m.content.substring(0, 57)}...' : m.content),
            maxLines: 2, overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: BrokaColors.textMid, fontSize: 12),
          ),
        ),
        if (canReply)
          ListTile(
            leading: const Icon(Icons.reply_rounded, color: BrokaColors.neonBlue),
            title: const Text('Reply', style: TextStyle(color: BrokaColors.textHigh)),
            onTap: () => Navigator.pop(ctx, 'reply'),
          ),
        if (canEdit)
          ListTile(
            leading: const Icon(Icons.edit_rounded, color: BrokaColors.neonGreen),
            title: const Text('Edit', style: TextStyle(color: BrokaColors.textHigh)),
            onTap: () => Navigator.pop(ctx, 'edit'),
          ),
        if (canDelete)
          ListTile(
            leading: const Icon(Icons.delete_outline_rounded, color: BrokaColors.danger),
            title: const Text('Unsend', style: TextStyle(color: BrokaColors.textHigh)),
            subtitle: const Text('Removes it for everyone',
                style: TextStyle(color: BrokaColors.textLow, fontSize: 12)),
            onTap: () => Navigator.pop(ctx, 'delete'),
          ),
      ])),
    );
    if (!mounted || choice == null) return;
    if (choice == 'reply') {
      setState(() => _replyTo = m);
      _composerFocus.requestFocus();
    } else if (choice == 'edit') {
      await _editMessage(m);
    } else if (choice == 'delete') {
      await _deleteMessage(m);
    }
  }

  /// Jump to the quoted message and flash it briefly. The bubble's own key
  /// reveals it at its exact position - bubble heights vary (text, quotes,
  /// photos, voice notes), so no averaged offset is ever estimated. A lazily
  /// built list may not hold the bubble yet: one coarse nudge toward its
  /// index lays it out, then the exact reveal runs. Deleted or unavailable
  /// originals get a safe fallback instead of a jump.
  Future<void> _jumpToReply(ChatMessage m) async {
    final target = m.replyToMessageId;
    if (target == null || target.isEmpty) return;
    if (_messages.indexWhere((x) => x.id == target) < 0) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Original message is not in this view.')));
      }
      return;
    }
    for (var attempt = 0; attempt < 4; attempt++) {
      final ctx = _bubbleKeys[target]?.currentContext;
      if (ctx != null) {
        try {
          await Scrollable.ensureVisible(
            ctx,
            alignment: 0.5,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        } catch (_) {}
        _flashHighlight(target);
        return;
      }
      // Not laid out yet: nudge toward its index so the builder creates it.
      if (!_scrollCtrl.hasClients) return;
      try {
        final i = _messages.indexWhere((x) => x.id == target);
        final extent = _scrollCtrl.position.maxScrollExtent;
        final offset = _messages.length <= 1
            ? extent
            : (extent * i / (_messages.length - 1)).clamp(0.0, extent);
        await _scrollCtrl.animateTo(
          offset,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      } catch (_) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Original message is not in this view.')));
    }
  }

  void _flashHighlight(String target) {
    if (!mounted) return;
    _highlightTimer?.cancel();
    setState(() => _highlightId = target);
    _highlightTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _highlightId = null);
    });
  }

  /// Test seams: drive one inbound socket frame, or run the reconnect
  /// flush, without a live WebSocket. Production code never calls these.
  @visibleForTesting
  void debugSocketFrame(Map<String, dynamic> frame) =>
      _onSocketFrame(jsonEncode(frame));

  @visibleForTesting
  void debugFlushFailed() => _flushFailed();

  @visibleForTesting
  bool get debugRemoteTyping => _remoteTyping;

  @visibleForTesting
  bool get debugTypingSent => _typingSent;

  Future<void> _editMessage(ChatMessage m) async {
    final controller = TextEditingController(text: m.content);
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: BrokaColors.bgCard,
        title: const Text('Edit message', style: TextStyle(color: BrokaColors.textHigh)),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: null,
          maxLength: 2000,
          style: const TextStyle(color: BrokaColors.textHigh),
          decoration: const InputDecoration(
            hintText: 'Message',
            hintStyle: TextStyle(color: BrokaColors.textLow),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: BrokaColors.textMid)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Save', style: TextStyle(color: BrokaColors.neonGreen)),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || text == null || text.isEmpty || text == m.content) return;

    final saved = await ApiService.editMessage(m.id, text);
    if (!mounted) return;
    if (saved == null) {
      _notSent('Could not edit that message. It may be too old, or the connection dropped.');
      return;
    }
    final i = _messages.indexWhere((x) => x.id == m.id);
    if (i < 0) return;
    setState(() => _messages[i] = ChatMessage.fromJson(saved));
    unawaited(_cacheMessages());
  }

  Future<void> _deleteMessage(ChatMessage m) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: BrokaColors.bgCard,
        title: const Text('Unsend message?', style: TextStyle(color: BrokaColors.textHigh)),
        content: const Text(
          'It will be removed for both of you. The other person may already have seen it.',
          style: TextStyle(color: BrokaColors.textMid),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: BrokaColors.textMid)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Unsend', style: TextStyle(color: BrokaColors.danger)),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;

    final saved = await ApiService.unsendMessage(m.id);
    if (!mounted) return;
    if (saved == null) {
      _notSent('Could not unsend that message. It may be too old, or the connection dropped.');
      return;
    }
    final i = _messages.indexWhere((x) => x.id == m.id);
    if (i < 0) return;
    setState(() => _messages[i] = ChatMessage.fromJson(saved));
    unawaited(_cacheMessages());
  }

  // ── Voice notes ────────────────────────────────────────────────────────────

  void _voiceNoteError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _startRecording() async {
    if (_isRecording || _startingRecording) return;
    _startingRecording = true;
    try {
      // Zeno may be listening from its session across screens: a voice note
      // takes the microphone from it rather than share it.
      await ZenoVoiceController.releaseMicrophone();
      final ok = await _recorder.hasPermission();
      if (!ok) {
        _voiceNoteError('Microphone permission required');
        return;
      }
      final dir  = await getTemporaryDirectory();
      final path = '${dir.path}/broka_voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
      // Left the chat while the recorder started: dispose() has already
      // queued the recorder's cancel, which runs after this start.
      if (!mounted) return;
      setState(() { _isRecording = true; _recordStart = DateTime.now(); });
    } catch (e) {
      // The recorder refused (the microphone held by a call or another app,
      // no storage). This used to escape unhandled: the mic button simply
      // did nothing, with no word why.
      debugPrint('[VoiceNote] could not start recording: $e');
      _voiceNoteError('Could not start recording. Please try again.');
    } finally {
      _startingRecording = false;
    }
  }

  Future<void> _stopAndSendVoice() async {
    if (!_isRecording) return;
    final started = _recordStart;
    // Back to the input bar first, whatever the recorder does: a stop that
    // threw used to leave the recording bar up with nothing behind it, and
    // this also turns a second tap on send into a no-op.
    setState(() { _isRecording = false; _recordStart = null; });
    String? path;
    try {
      path = await _recorder.stop();
    } catch (e) {
      debugPrint('[VoiceNote] could not stop recording: $e');
    }
    if (path == null) {
      _voiceNoteError('Could not save the voice note. Please try again.');
      return;
    }
    if (!mounted) return;

    final duration = started != null
        ? DateTime.now().difference(started).inSeconds
        : 0;

    final Uint8List bytes;
    try {
      bytes = await File(path).readAsBytes();
    } catch (e) {
      debugPrint('[VoiceNote] could not read the recording: $e');
      _voiceNoteError('Could not save the voice note. Please try again.');
      return;
    }
    if (!mounted) return;

    final clientId = _newClientId();
    final reply = _replyTo;
    _uploads[clientId] = _PendingUpload(
      bytes: bytes, contentType: 'audio', fileName: 'voice.m4a',
      mimeType: 'audio/mp4', durationSecs: duration,
      replyToMessageId: reply?.id.isEmpty == true ? null : reply?.id,
      replyPreview: reply == null ? null : _replySnapshotOf(reply),
    );
    setState(() {
      _messages.add(ChatMessage(
        role: _role, msgType: 'voice',
        mediaUrl: 'file://$path',
        durationSecs: duration,
        clientId: clientId, createdAt: DateTime.now().toUtc(),
        replyToMessageId: reply?.id.isEmpty == true ? null : reply?.id,
        replyPreview: reply == null ? null : _replySnapshotOf(reply),
      ));
      _replyTo = null;
    });
    _scrollDown();
    _enqueue(() => _deliverUpload(clientId));
  }

  Future<void> _cancelRecording() async {
    // As in _stopAndSendVoice: the bar goes whatever cancel() does.
    setState(() { _isRecording = false; _recordStart = null; });
    try {
      await _recorder.cancel();
    } catch (e) {
      debugPrint('[VoiceNote] could not cancel recording: $e');
    }
  }

  // ── Image sharing ──────────────────────────────────────────────────────────
  //
  // Chat-specific flow: pick a source from this screen's own sheet, preview
  // the photo with an optional caption, then send. Nothing uploads until
  // Send is tapped - selecting a photo is not sending it. The bytes live in
  // the app-owned media outbox (a real file, not SharedPreferences), so a
  // failed upload retries without re-picking, even after a restart.

  /// This screen's own attachment picker - not PhotoCapture.askSource, which
  /// other screens share. Bigger targets, explicit labels, BROKA styling.
  Future<void> _showImageSourceSheet() async {
    final source = await showModalBottomSheet<PhotoSource>(
      context: context,
      backgroundColor: BrokaColors.bgMid,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (sheet) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 8),
          Container(
            width: 40, height: 4,
            decoration: BoxDecoration(
                color: BrokaColors.border, borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(height: 12),
          const Padding(
            padding: EdgeInsets.only(bottom: 4),
            child: Text('Share a photo',
                style: TextStyle(color: BrokaColors.textHigh,
                    fontWeight: FontWeight.w800, fontSize: 16)),
          ),
          _chatSourceOption(sheet, PhotoSource.camera,
              Icons.photo_camera_rounded, 'Take a photo',
              'Use the camera to capture it now', BrokaColors.gold),
          _chatSourceOption(sheet, PhotoSource.gallery,
              Icons.photo_library_rounded, 'Choose from gallery',
              'Pick a photo already on this phone', BrokaColors.neonBlue),
          const SizedBox(height: 12),
        ]),
      ),
    );
    if (source != null && mounted) await _pickAndPreviewImage(source);
  }

  Widget _chatSourceOption(BuildContext sheet, PhotoSource source, IconData icon,
      String title, String subtitle, Color color) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Material(
        color: BrokaColors.bgCard,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => Navigator.pop(sheet, source),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: color.withOpacity(0.35)),
            ),
            child: Row(children: [
              Container(
                width: 48, height: 48,
                decoration: BoxDecoration(
                  color: color.withOpacity(0.14),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: color, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(color: BrokaColors.textHigh,
                          fontWeight: FontWeight.w700, fontSize: 15)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: const TextStyle(color: BrokaColors.textMid, fontSize: 12)),
                ],
              )),
              const Icon(Icons.chevron_right_rounded, color: BrokaColors.textLow),
            ]),
          ),
        ),
      ),
    );
  }

  /// Pick, then preview with an optional caption - the upload starts only
  /// when the preview's Send is tapped.
  Future<void> _pickAndPreviewImage(PhotoSource source) async {
    try {
      final File? picked;
      if (source == PhotoSource.camera) {
        picked = await PhotoCapture.takePhoto(context,
            hint: 'Show it clearly, in good light - the other side sees exactly this.');
      } else {
        picked = await PhotoCapture.pickFromGallery(context);
      }
      if (picked == null || !mounted) return;
      await _showImagePreview(picked, source);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not open image. ${userFacingError(e)}')));
      }
    }
  }

  /// Preview composer: inspect, replace or remove, add a caption, then Send.
  /// Cancel/close never uploads - the bytes stay on the phone unsent.
  Future<void> _showImagePreview(File file, PhotoSource source) async {
    final captionCtrl = TextEditingController();
    File current = file;
    bool? send;
    await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: BrokaColors.bgMid,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (sheet) => StatefulBuilder(
        builder: (ctx, setSheet) => SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
                bottom: MediaQuery.of(ctx).viewInsets.bottom),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const SizedBox(height: 8),
              Container(width: 40, height: 4,
                decoration: BoxDecoration(
                    color: BrokaColors.border,
                    borderRadius: BorderRadius.circular(2))),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(children: [
                  IconButton(
                    tooltip: 'Close without sending',
                    onPressed: () => Navigator.pop(sheet, false),
                    icon: const Icon(Icons.close_rounded,
                        color: BrokaColors.textHigh),
                  ),
                  const Expanded(child: Text('Preview',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: BrokaColors.textHigh,
                          fontWeight: FontWeight.w800, fontSize: 16))),
                  TextButton(
                    onPressed: () => Navigator.pop(sheet, true),
                    child: const Text('Send',
                        style: TextStyle(color: BrokaColors.neonGreen,
                            fontWeight: FontWeight.w800, fontSize: 15)),
                  ),
                ]),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 320),
                    child: Image.file(current, fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => Container(
                        height: 160, color: BrokaColors.bgCard,
                        alignment: Alignment.center,
                        child: const Icon(Icons.broken_image_outlined,
                            color: BrokaColors.textLow, size: 40))),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: TextField(
                  controller: captionCtrl,
                  style: const TextStyle(color: BrokaColors.textHigh),
                  maxLines: 3,
                  minLines: 1,
                  maxLength: 1000,
                  decoration: const InputDecoration(
                    hintText: 'Add a caption (optional)',
                    hintStyle: TextStyle(color: BrokaColors.textLow),
                    filled: true,
                    fillColor: BrokaColors.bgCard,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(12)),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: Row(children: [
                  TextButton.icon(
                    onPressed: () async {
                      final replacement = await (source == PhotoSource.camera
                          ? PhotoCapture.takePhoto(context)
                          : PhotoCapture.pickFromGallery(context));
                      if (replacement != null) {
                        setSheet(() => current = replacement);
                      }
                    },
                    icon: const Icon(Icons.swap_horiz_rounded,
                        color: BrokaColors.neonBlue, size: 18),
                    label: const Text('Replace',
                        style: TextStyle(color: BrokaColors.neonBlue)),
                  ),
                  TextButton.icon(
                    onPressed: () => Navigator.pop(sheet, false),
                    icon: const Icon(Icons.delete_outline_rounded,
                        color: BrokaColors.danger, size: 18),
                    label: const Text('Remove',
                        style: TextStyle(color: BrokaColors.danger)),
                  ),
                ]),
              ),
            ]),
          ),
        ),
      ),
    ).then((v) => send = v);
    final caption = captionCtrl.text.trim();
    captionCtrl.dispose();
    if (send != true || !mounted) return; // cancelled or removed: send nothing
    await _stageImageUpload(current, caption.isEmpty ? null : caption);
  }

  /// Shrink a picked photo for sending: longest side 1600px, JPEG quality
  /// 85 (PNG when the source has transparency). A 12MP camera photo is ~4MB;
  /// sending it raw would stall the thread on a slow connection and bloat
  /// the server's data-URI store for no visible gain. Decoding failures
  /// fall back to the raw bytes - a photo never fails to send because the
  /// shrinker couldn't read it.
  ({Uint8List bytes, String fileName, String mimeType}) _fitPhotoForUpload(
      Uint8List raw) {
    try {
      final decoded = img.decodeImage(raw);
      if (decoded == null) {
        return (bytes: raw, fileName: 'image.jpg', mimeType: 'image/jpeg');
      }
      img.Image out = decoded;
      const maxDim = 1600;
      final w = decoded.width, h = decoded.height;
      if ((w > maxDim || h > maxDim) && w > 0 && h > 0) {
        final s = maxDim / (w >= h ? w : h);
        out = img.copyResize(decoded, width: (w * s).round());
      }
      final isPng = raw.length >= 8 &&
          raw[0] == 0x89 && raw[1] == 0x50 && raw[2] == 0x4E && raw[3] == 0x47 &&
          raw[4] == 0x0D && raw[5] == 0x0A && raw[6] == 0x1A && raw[7] == 0x0A;
      if (isPng) {
        return (
          bytes: Uint8List.fromList(img.encodePng(out)),
          fileName: 'image.png',
          mimeType: 'image/png'
        );
      }
      return (
        bytes: Uint8List.fromList(img.encodeJpg(out, quality: 85)),
        fileName: 'image.jpg',
        mimeType: 'image/jpeg'
      );
    } catch (_) {
      return (bytes: raw, fileName: 'image.jpg', mimeType: 'image/jpeg');
    }
  }

  /// Persist the photo to the app-owned outbox, render the optimistic bubble
  /// with an uploading state, then upload. Retries reuse the stored file -
  /// never the in-memory bytes - so they survive a restart.
  Future<void> _stageImageUpload(File picked, String? caption) async {
    try {
      final raw = await picked.readAsBytes();
      final fitted = _fitPhotoForUpload(raw);
      final clientId = _newClientId();
      final reply = _replyTo;
      final stored = await _ChatMediaOutbox.storeImage(
          clientId, fitted.bytes, ext: fitted.mimeType == 'image/png' ? 'png' : 'jpg');
      if (stored == null || !mounted) return;
      await _ChatMediaOutbox.writeMeta(clientId,
          replyToMessageId: reply?.id.isEmpty == true ? null : reply?.id,
          caption: caption);
      _uploads[clientId] = _PendingUpload(
        bytes: fitted.bytes,
        contentType: 'image',
        fileName: fitted.fileName,
        mimeType: fitted.mimeType,
        replyToMessageId: reply?.id.isEmpty == true ? null : reply?.id,
        replyPreview: reply == null ? null : _replySnapshotOf(reply),
        caption: caption,
      );
      setState(() {
        _messages.add(ChatMessage(
          role: _role, msgType: 'image',
          // Tiny thumbnails render from memory; the durable file is what the
          // upload reads, so evicting this cache never breaks a retry.
          mediaUrl: stored.localUri,
          content: caption ?? '',
          clientId: clientId, createdAt: DateTime.now().toUtc(),
          replyToMessageId: reply?.id.isEmpty == true ? null : reply?.id,
          replyPreview: reply == null ? null : _replySnapshotOf(reply),
        ));
        _replyTo = null;
      });
      _scrollDown();
      unawaited(_cacheMessages());
      _enqueue(() => _deliverOutboxUpload(clientId, stored.path));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not send image. ${userFacingError(e)}')));
      }
    }
  }

  /// Upload from the outbox file (not the in-memory bytes). Cleans the
  /// temporary file once the server has the image or the bubble is dropped.
  Future<void> _deliverOutboxUpload(String clientId, String storedPath) async {
    final listing = _listing;
    if (listing == null) return;
    try {
      final bytes = await File(storedPath).readAsBytes();
      // A retry reuses the staged format, not the raw pick: the server
      // must see the same file the idempotency key was first sent with.
      final staged = _uploads[clientId];
      final saved = await ApiService.uploadMedia(
        listingId: listing.id,
        senderRole: _role,
        senderId: ApiService.currentUserId ?? 'anon',
        contentType: 'image',
        fileBytes: bytes,
        fileName: staged?.fileName ?? 'image.jpg',
        mimeType: staged?.mimeType ?? 'image/jpeg',
        buyerId: _buyerId,
        clientMsgId: clientId,
        replyToMessageId: staged?.replyToMessageId,
        caption: staged?.caption,
        onProgress: (sent, total) => _reportUploadProgress(clientId, sent, total),
      );
      await _ChatMediaOutbox.remove(clientId);
      _confirm(clientId, ChatMessage.fromJson({'role': _role, ...saved}));
    } catch (e) {
      debugPrint('[DirectChat] photo upload failed: $e');
      _markFailed(clientId);
      _notSent('Photo not sent. Tap it to try again.');
    }
  }

  /// Restore outbox uploads from an earlier run: failed bubbles can retry
  /// without re-picking, because the file outlived the process.
  Future<void> _restoreMediaOutbox() async {
    try {
      final entries = await _ChatMediaOutbox.list();
      for (final entry in entries) {
        if (_uploads.containsKey(entry.clientId)) continue;
        try {
          final bytes = await File(entry.path).readAsBytes();
          _uploads[entry.clientId] = _PendingUpload(
            bytes: bytes, contentType: 'image', fileName: 'image.jpg',
            mimeType: 'image/jpeg',
            replyToMessageId: entry.replyToMessageId,
            caption: entry.caption,
          );
        } catch (_) {}
      }
    } catch (_) {}
  }

  // ── Voice playback ─────────────────────────────────────────────────────────

  Future<void> _togglePlay(String url) async {
    if (_isPlaying && _playingUrl == url) {
      await _player.stop();
      setState(() { _isPlaying = false; _playingUrl = null; });
      return;
    }
    await _player.stop();
    setState(() { _isPlaying = true; _playingUrl = url; });
    _player.onPlayerComplete.listen((_) {
      if (mounted) setState(() { _isPlaying = false; _playingUrl = null; });
    });
    if (url.startsWith('data:')) {
      // Base64 data URI
      final commaIdx = url.indexOf(',');
      if (commaIdx < 0) return;
      final b64   = url.substring(commaIdx + 1);
      final bytes = base64Decode(b64);
      await _player.play(BytesSource(bytes));
    } else if (url.startsWith('file://')) {
      await _player.play(DeviceFileSource(url.replaceFirst('file://', '')));
    } else {
      await _player.play(UrlSource(url));
    }
  }

  /// Used by the "Call back" button on a missed/declined call card. Works
  /// for both roles.
  /// [callType] mirrors the original call ("audio" | "video") so calling
  /// back a missed video call opens with the camera on, not just audio.
  ///
  /// BUG FIX (calling audit, 2026-09-14): the seller branch used to build a
  /// room_id client-side ("broka_<listing>_<buyer>"), never call
  /// POST /calls/initiate, and navigate with no call_token at all. No
  /// session existed server-side, so the WebSocket was rejected with 4001
  /// the instant it connected and the buyer was never notified of anything
  /// - the button looked live and did nothing. Its own comment described
  /// this as a limitation of a "buyer-initiates-only" backend, but that
  /// stopped being true when initiate_call() gained seller-initiated
  /// support (it takes callee_id for exactly this case, and _initiateCall
  /// below already passes it). Both roles now go down the same real path.
  Future<void> _callBack(String callType) async {
    await _initiateCall(callType);
  }

  // ── Audio/Video call ───────────────────────────────────────────────────────

  Future<void> _initiateCall(String callType) async {
    final listing = _listing;
    if (listing == null) return;
    final isVideo = callType == 'video';
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: BrokaColors.bgMid,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
              color: isVideo ? BrokaColors.neonBlue : BrokaColors.neonGreen, width: 1)),
        title: Row(children: [
          Icon(isVideo ? Icons.videocam_rounded : Icons.call_rounded,
              color: isVideo ? BrokaColors.neonBlue : BrokaColors.neonGreen, size: 22),
          const SizedBox(width: 10),
          Text(isVideo ? 'In-App Video Call' : 'In-App Call', style: const TextStyle(
              color: BrokaColors.textHigh, fontWeight: FontWeight.w800)),
        ]),
        content: Text(
            'Start a secure ${isVideo ? 'video ' : ''}call with $_counterpartyName?',
            style: const TextStyle(color: BrokaColors.textMid, height: 1.5)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel', style: TextStyle(color: BrokaColors.textLow))),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: isVideo ? BrokaColors.neonBlue : BrokaColors.neonGreen,
              foregroundColor: Colors.black87,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
            child: const Text('Call Now', style: TextStyle(fontWeight: FontWeight.w800))),
        ],
      ),
    );
    if (confirm == true && mounted) {
      // buyerId must always be the actual buyer's ID, regardless of which
      // role tapped this button - using currentUserId unconditionally was
      // wrong when the SELLER initiated the call, since it would log the
      // call under the seller's own ID as if they were the buyer,
      // corrupting the inbox (their own name would appear as a counterpart).
      final buyerId = _role == 'buyer' ? (ApiService.currentUserId ?? 'anon') : (_buyerId ?? '');
      // room_id + call_token are server-issued (POST /calls/initiate).
      // This used to be awaited before navigating: on a slow network the
      // call screen took 3-5s to appear and looked broken. Now the
      // request starts here and the call screen opens at once with it
      // (`callSetup`); VoipCallScreen shows "Calling…" while it lands,
      // then starts WebRTC - or says why the call could not be placed.
      // calleeId is required when the seller is calling (see calls.py's
      // initiate_call - a listing can have multiple buyer threads, so the
      // backend can't infer which buyer to ring the way it can infer
      // the seller).
      final setup = ApiService.initiateCall(
        listingId: listing.id, listingName: listing.name, callType: callType,
        calleeId: _role == 'seller' ? _buyerId : null);
      if (!mounted) return;
      Navigator.pushNamed(context, '/voip-call', arguments: {
        'roomId': '', 'userId': ApiService.currentUserId ?? 'anon',
        'callToken': '',
        'callSetup': setup,
        'peerName': _counterpartyName,
        // Lets the call screen fetch the name itself when the profile
        // hadn't loaded by the time the call was placed.
        'peerId': _counterpartyId,
        'peerPhoto': _counterpartyPhoto,
        'peerOnline': _counterpartyOnline,
        'listingName': listing.name, 'isCaller': true,
        'listingId': listing.id, 'buyerId': buyerId, 'callerRole': _role,
        'callType': callType,
      });
    }
  }

  // ── M-Pesa deal ───────────────────────────────────────────────────────────

  /// Pays into escrow in one step: no "agree the deal" first - the first
  /// payment opens the deal on the server (POST /deal/pay), and later ones
  /// top it up. See escrow_actions.dart.
  Future<void> _payNow() async {
    final listing = _listing;
    if (listing == null) return;
    final multi = hasUnits(listing);
    await showEscrowPayDialog(
      context,
      listingId: listing.id,
      listingName: listing.name,
      // A deal handed over from Zeno's room carries the price agreed there.
      agreedPrice: (_dealInfo?['agreed_price'] as num?)?.toDouble(),
      unitPrice: multi ? listing.price : null,
      maxUnits: multi ? unitsAvailable(listing) : 1,
      unitLabel: listing.priceUnit,
    );
  }

  // ── Utility ────────────────────────────────────────────────────────────────

  /// Latest messages stay in view. The list is chronological (oldest at the
  /// top), so the newest end is the bottom - the opposite of the reversed
  /// list this screen used to build, which parked one message at the bottom
  /// of a tall empty viewport.
  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /// After a restore, land on the latest message without animating through
  /// the whole thread: jump once the first layout has a viewport.
  void _scrollToLatestAfterLayout() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
      }
    });
  }

  Future<void> _openZenoAi() async {
    // Zeno's room tells the server it has been seen as it opens.
    setState(() => _zenoUnreadCount = 0);
    // buyer_id names the thread for a seller. Dropping it here (and on the
    // way back from Zeno's room) left the seller in a chat with no buyer:
    // an empty history, "Buyer" in the header, and every call refused with
    // 400 because /calls/initiate had no callee_id to ring.
    Navigator.pushReplacementNamed(context, '/negotiate',
        arguments: {'listing': _listing, 'role': _role, 'buyer_id': _buyerId});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _sendStopTyping();
    _typingDebounce?.cancel();
    _typingHeartbeat?.cancel();
    _remoteTypingExpiry?.cancel();
    _highlightTimer?.cancel();
    _bubbleKeys.clear();
    if (_listing != null) {
      GlobalPollerService.instance.markScreenInactive(_listing!.id, buyerId: _buyerId);
    }
    _msgCtrl.dispose();
    _composerFocus.dispose();
    _scrollCtrl.dispose();
    _pollTimer?.cancel();
    _heartbeatTimer?.cancel();
    _presenceRefreshTimer?.cancel();
    // Not awaited, so a recorder that throws would otherwise surface as an
    // unhandled error.
    _recorder.cancel().catchError((Object e) {
      debugPrint('[VoiceNote] cancel on leaving the chat failed: $e');
    });
    _player.dispose();
    _wsPingTimer?.cancel();
    _wsReconnectTimer?.cancel();
    final ws = _ws;
    _ws = null; // so its closing doesn't schedule a reconnect
    ws?.sink.close();
    super.dispose();
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: BrokaColors.bg,
    // Home's constellation, as on every screen reached from it. This thread
    // used to sit on ChatAmbientBackground - the splash field retuned and
    // held back - under an opaque header bar and an opaque composer bar,
    // which made it look like a different app from Home and Zeno.
    body: ConstellationBackground(
      animate: widget.animateBackground,
      child: Column(children: [
        _buildHeader(),
        ChatModeSwitch(
          zenoActive: false,
          unread: _zenoUnreadCount,
          onSwitch: _openZenoAi,
        ),
        // Every buyer can pay from here: there is no "finalize" step before
        // it any more (auctions are paid from the auction screen).
        // Nothing at all while payments are hidden (payments_shown.dart).
        if (!paymentsShown)
          const SizedBox.shrink()
        else if (_role == 'buyer' && _listing != null && _listing!.listingType != 'auction')
          _buildPaymentPanel()
        // The seller needs escrow as much: "the money is held" is what lets
        // them hand an item to a stranger - and a screenshot is not.
        else if (_role == 'seller' && _listing != null)
          EscrowCallout(
            compact: true,
            title: 'Get paid with escrow',
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            onZeno: () => openZenoEscrowGuide(context, prompt: 'How do I get paid through escrow?'),
          ),
        Expanded(child: _loading
            ? const Center(child: CircularProgressIndicator(color: BrokaColors.gold))
            : _buildMessages()),
        _buildTypingIndicator(),
        _buildReplyPreview(),
        // REMOVED: the language chip row.
        //
        // It set a _selectedLang field and ApiService.currentUserLanguage, and
        // nothing in this screen ever read either one - direct chat sends
        // the user's literal text to the other party, untouched, so there
        // was nothing for a language selection to act on. It was six
        // permanently-visible controls that did nothing, occupying a full
        // row directly above the input, which is the most valuable strip
        // of a chat screen. The chips still exist (and still matter) on
        // Zeno's screen, where replies are actually generated in the
        // chosen language.
        //
        // "Finalize" lived in that same row and IS real, so it moved into
        // the header as a proper action - see _buildHeader.
        if (_isRecording) _buildRecordingBar() else _buildInputBar(),
      ]),
    ),
  );

  // ── Header ─────────────────────────────────────────────────────────────────

  /// Home's header language: a bare back chevron, the person's photo, their
  /// name, and square controls on the right - no opaque bar across the top.
  Widget _buildHeader() => SafeArea(
    bottom: false,
    child: Container(
      padding: const EdgeInsets.fromLTRB(4, 6, 12, 10),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: BrokaColors.border.withOpacity(0.6))),
      ),
      child: Row(children: [
        // Compact: four controls share this row with the person's name,
        // and the name is what the header is for.
        IconButton(
          tooltip: 'Back',
          visualDensity: VisualDensity.compact,
          onPressed: () => Navigator.maybePop(context),
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              color: BrokaColors.textHigh, size: 19),
        ),
        Stack(children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(colors: kChatGradient),
              border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.45), width: 1.2)),
            clipBehavior: Clip.antiAlias,
            child: (_counterpartyPhoto != null && _counterpartyPhoto!.isNotEmpty)
                ? _decodedPhoto(_counterpartyPhoto!)
                : _headerInitial(),
          ),
          if (_counterpartyOnline)
            Positioned(right: 0, bottom: 0, child: Container(
              width: 11, height: 11,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: BrokaColors.neonGreen,
                border: Border.all(color: BrokaColors.bg, width: 2),
              ),
            )),
        ]),
        const SizedBox(width: 9),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(_counterpartyName,
              maxLines: 1, overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: BrokaColors.textHigh,
                  fontWeight: FontWeight.w800, fontSize: 15.5)),
          const SizedBox(height: 2),
          Row(children: [
            // Their presence, as the words beside it give it. It was this
            // phone's chat socket: green beside "Active 22h ago", which
            // reads as "online" to anyone, about someone who is not.
            Container(
              key: const Key('direct-chat-presence-dot'),
              width: 6, height: 6, margin: const EdgeInsets.only(right: 5),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _counterpartyOnline ? BrokaColors.neonGreen : BrokaColors.textLow),
            ),
            Flexible(child: Text(
              _counterpartyLastSeen ??
                  (_counterpartyOnline ? 'Active now' : 'Last seen unavailable'),
              style: TextStyle(
                  color: _counterpartyOnline ? BrokaColors.neonGreen : BrokaColors.textMid,
                  fontSize: 11.5, fontWeight: _counterpartyOnline ? FontWeight.w600 : FontWeight.w400),
              maxLines: 1, overflow: TextOverflow.ellipsis)),
          ]),
        ])),
        const SizedBox(width: 4),
        BrokaHeaderButton(
          icon: Icons.call_rounded,
          tooltip: 'Voice call',
          onTap: () => _initiateCall('audio'),
        ),
        const SizedBox(width: 5),
        BrokaHeaderButton(
          icon: Icons.videocam_rounded,
          tooltip: 'Video call',
          onTap: () => _initiateCall('video'),
        ),
        const SizedBox(width: 5),
        // Zeno, a tap away, with its unread replies counted.
        Stack(clipBehavior: Clip.none, children: [
          BrokaHeaderButton(
            icon: Icons.auto_awesome_rounded,
            active: true,
            tooltip: 'Ask Zeno',
            onTap: _openZenoAi,
          ),
          if (_zenoUnreadCount > 0)
            Positioned(right: -4, top: -4, child: IgnorePointer(child: Container(
              key: const Key('zeno-unread-badge'),
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: BrokaColors.danger,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: BrokaColors.bg, width: 1.5),
              ),
              child: Text('$_zenoUnreadCount',
                  style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w800)),
            ))),
        ]),
      ]),
    ),
  );

  // ── Payment Panel ──────────────────────────────────────────────────────────

  /// The buyer's way to pay, at the top of the chat - loud on purpose
  /// (escrow_callout.dart). While BROKA holds no payments, Pay with escrow
  /// opens the escrow services and Zeno's walkthrough (escrow_actions.dart
  /// -> safe_payment.dart); with payments on, BROKA's own escrow payment.
  Widget _buildPaymentPanel() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [
          BrokaColors.neonGreen.withOpacity(0.24), BrokaColors.bgCard.withOpacity(0.94)]),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BrokaColors.neonGreen.withOpacity(0.75), width: 1.3),
        boxShadow: [BoxShadow(color: BrokaColors.neonGreen.withOpacity(0.22), blurRadius: 16)]),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Row(children: [
          Icon(Icons.shield_rounded, color: BrokaColors.neonGreen, size: 22),
          SizedBox(width: 10),
          Expanded(child: Text(
              "BROKA doesn't take payments itself yet. Pay with escrow: the money is held "
              'until you have the item - never pay a deposit.',
              style: TextStyle(color: BrokaColors.textHigh,
                  fontSize: 12, fontWeight: FontWeight.w600, height: 1.35))),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: GestureDetector(
              key: const Key('pay-now'),
              onTap: _payNow,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 9),
                alignment: Alignment.center,
                decoration: BoxDecoration(color: BrokaColors.neonGreen,
                    borderRadius: BorderRadius.circular(10)),
                child: const Text('Pay with escrow', style: TextStyle(color: Colors.black87,
                    fontWeight: FontWeight.w900, fontSize: 13)),
              ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            onPressed: () => openZenoEscrowGuide(context),
            style: TextButton.styleFrom(
              backgroundColor: BrokaColors.neonPurple,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            icon: const Icon(Icons.auto_awesome_rounded, size: 15),
            label: const Text('Zeno, guide me', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800)),
          ),
        ]),
      ]),
    );
  }

  // ── Messages list ──────────────────────────────────────────────────────────

  /// Chronological, top-oriented thread: a new or short conversation starts
  /// near the top of the message area instead of parking one bubble at the
  /// bottom of a tall empty viewport. Restores land on the latest message
  /// (see _scrollToLatestAfterLayout); the keyboard never covers it because
  /// new arrivals keep scrolling the bottom into view.
  Widget _buildMessages() {
    if (_messages.isEmpty) {
      // Aligned to the top, not centred: the empty state must not invent a
      // huge gap above a conversation that has barely started.
      return Align(
        alignment: Alignment.topCenter,
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(40, 24, 40, 16),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 96, height: 96,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(colors: [
                  BrokaColors.gold.withOpacity(0.16),
                  BrokaColors.gold.withOpacity(0.0),
                ]),
                border: Border.all(color: BrokaColors.gold.withOpacity(0.22)),
              ),
              alignment: Alignment.center,
              child: Text(_listing?.emoji ?? '💬',
                  style: const TextStyle(fontSize: 40)),
            ),
            const SizedBox(height: 18),
            Text(
              _role == 'buyer'
                  ? 'You\'re talking to ${_listing?.sellerName ?? 'the seller'}'
                  : 'You\'re talking to the buyer',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: BrokaColors.textHigh,
                  fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            const Text(
              'Messages here go straight to them — Zeno is not in this thread '
              'and cannot read it.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: BrokaColors.textLow, fontSize: 12.5, height: 1.5),
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: BrokaColors.neonGreen.withOpacity(0.08),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: BrokaColors.neonGreen.withOpacity(0.25)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.visibility_outlined, size: 13, color: BrokaColors.neonGreen),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                      _role == 'buyer'
                          ? 'See the item before you pay'
                          : 'Check the money has arrived before you hand over',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: BrokaColors.neonGreen,
                          fontSize: 11, fontWeight: FontWeight.w600)),
                ),
              ]),
            ),
          ]),
        ),
      );
    }
    return ListView.builder(
      controller: _scrollCtrl,
      reverse: false,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      itemCount: _messages.length,
      itemBuilder: (_, i) {
        final id = _messages[i].id;
        final key = id.isEmpty ? null : _bubbleKeys.putIfAbsent(id, () => GlobalKey());
        final clientId = _messages[i].clientId;
        return _ChatBubble(
        key: key,
        uploadProgress: clientId == null ? null : _uploads[clientId]?.progress,
        message:    _messages[i],
        userRole:   _role,
        isPlaying:  _isPlaying && _playingUrl == _messages[i].mediaUrl,
        onPlayTap:  (url) => _togglePlay(url),
        onCallBack: _callBack,
        onUnsentTap: _onUnsentTap,
        onLongPress: _onMessageLongPress,
        onQuoteTap: _jumpToReply,
        highlighted: _highlightId != null && _highlightId == _messages[i].id,
        counterpartLastRead: _counterpartLastRead,
        counterpartLastDelivered: _counterpartLastDelivered,
      );
      },
    );
  }

  /// The other participant's live typing state, above the composer - never
  /// inside the message list, so it can't shift bubbles around, and never
  /// confused with Zeno's thinking animation: it names the human.
  Widget _buildTypingIndicator() {
    if (!_remoteTyping) return const SizedBox.shrink();
    final who = _counterpartyName;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 2, 20, 4),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: BrokaColors.bgCard.withOpacity(0.92),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: BrokaColors.border.withOpacity(0.6)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const _TypingDots(),
            const SizedBox(width: 8),
            Flexible(child: Text('$who is typing…',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: BrokaColors.textMid, fontSize: 12))),
          ]),
        ),
      ]),
    );
  }

  /// The reply being composed, pinned above the composer with a clear X.
  /// Kept short on purpose: it must not make the composer tall.
  Widget _buildReplyPreview() {
    final reply = _replyTo;
    if (reply == null) return const SizedBox.shrink();
    final sender = reply.role == _role ? 'You' : _counterpartyName;
    final label = ChatMessage.replyLabel(reply.replyPreview ?? _replySnapshotOf(reply));
    final isPhoto = reply.msgType == 'image';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
        decoration: BoxDecoration(
          color: BrokaColors.bgCard.withOpacity(0.95),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.4)),
        ),
        child: Row(children: [
          Container(width: 3, height: 34,
            decoration: BoxDecoration(
                color: BrokaColors.neonBlue,
                borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 8),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(sender,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: BrokaColors.neonBlue,
                      fontSize: 11, fontWeight: FontWeight.w700)),
              const SizedBox(height: 1),
              Text(isPhoto && label == 'Photo' ? '📷 Photo' : label,
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: BrokaColors.textMid, fontSize: 12)),
            ],
          )),
          IconButton(
            tooltip: 'Cancel reply',
            visualDensity: VisualDensity.compact,
            onPressed: () => setState(() => _replyTo = null),
            icon: const Icon(Icons.close_rounded,
                color: BrokaColors.textMid, size: 18),
          ),
        ]),
      ),
    );
  }

  // ── Lang row ───────────────────────────────────────────────────────────────

  // ── Recording bar ──────────────────────────────────────────────────────────

  Widget _buildRecordingBar() => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
      child: Row(children: [
        // Cancel
        Tooltip(
          message: 'Discard the recording',
          child: GestureDetector(
            onTap: _cancelRecording,
            child: Container(
              width: 50, height: 50,
              decoration: BoxDecoration(
                color: BrokaColors.bgCard.withOpacity(0.92),
                shape: BoxShape.circle,
                border: Border.all(color: BrokaColors.danger.withOpacity(0.5))),
              child: const Icon(Icons.delete_rounded, color: BrokaColors.danger, size: 20)),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(child: Container(
          constraints: const BoxConstraints(minHeight: 50),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: BoxDecoration(
            color: BrokaColors.bgCard.withOpacity(0.92),
            borderRadius: BorderRadius.circular(26),
            border: Border.all(color: BrokaColors.danger.withOpacity(0.55), width: 1.2)),
          child: Row(children: [
            Container(width: 10, height: 10,
              decoration: const BoxDecoration(
                shape: BoxShape.circle, color: BrokaColors.danger)),
            const SizedBox(width: 10),
            const Flexible(child: Text('Recording…',
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(color: BrokaColors.danger, fontSize: 14,
                    fontWeight: FontWeight.w600))),
            const Spacer(),
            if (_recordStart != null)
              _RecordingTimer(start: _recordStart!),
          ]),
        )),
        ChatSendButton(visible: true, onTap: _stopAndSendVoice),
      ]),
    ),
  );

  // ── Input bar ──────────────────────────────────────────────────────────────

  /// Home's search pill, as on Zeno's screen. Attachment and mic sit inside
  /// the pill, as in every messaging app people already know; the send
  /// button scales in only once there is something to send.
  Widget _buildInputBar() => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: ChatComposerPill(
              focused: _composerFocused,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  ChatComposerAction(
                    icon: Icons.add_photo_alternate_outlined,
                    tooltip: 'Send a photo',
                    onTap: _showImageSourceSheet,
                  ),
                  Expanded(
                    child: TextField(
                      key: const Key('direct-chat-composer'),
                      controller: _msgCtrl,
                      focusNode: _composerFocus,
                      style: const TextStyle(
                          color: BrokaColors.textHigh, fontSize: 15.5, height: 1.35),
                      // Room to compose a real paragraph - a marketplace
                      // negotiation is not a one-liner - while still
                      // scrolling rather than eating the conversation.
                      minLines: 1,
                      maxLines: 6,
                      textCapitalization: TextCapitalization.sentences,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      cursorColor: BrokaColors.neonBlue,
                      decoration: InputDecoration(
                        isDense: true,
                        filled: false,
                        // By name, as the header says it - not "Message buyer".
                        hintText: 'Message $_counterpartyName',
                        hintStyle: const TextStyle(
                            color: BrokaColors.textMid, fontSize: 15),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 4, vertical: 14),
                      ),
                    ),
                  ),
                  // Mic sits inside the pill and disappears once there's
                  // text - at that point the send button is the only action
                  // that makes sense, and keeping a second one visible just
                  // asks the user to aim.
                  if (!_hasDraft)
                    ChatComposerAction(
                      icon: Icons.mic_none_rounded,
                      tooltip: 'Record a voice note',
                      onTap: _startRecording,
                      leading: false,
                    ),
                ],
              ),
            ),
          ),
          ChatSendButton(visible: _hasDraft, onTap: _send),
        ],
      ),
    ),
  );
}

// ── Recording timer widget ─────────────────────────────────────────────────────

class _RecordingTimer extends StatefulWidget {
  final DateTime start;
  const _RecordingTimer({required this.start});
  @override
  State<_RecordingTimer> createState() => _RecordingTimerState();
}

class _RecordingTimerState extends State<_RecordingTimer> {
  late Timer _t;
  int _secs = 0;
  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _secs = DateTime.now().difference(widget.start).inSeconds);
    });
  }
  @override
  void dispose() { _t.cancel(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    final m = (_secs ~/ 60).toString().padLeft(2, '0');
    final s = (_secs % 60).toString().padLeft(2, '0');
    return Text('$m:$s',
        style: const TextStyle(color: BrokaColors.danger,
            fontSize: 12, fontWeight: FontWeight.w700));
  }
}

// ── Chat Bubble ───────────────────────────────────────────────────────────────

class _ChatBubble extends StatelessWidget {
  final ChatMessage message;
  final String      userRole;
  final bool        isPlaying;
  final void Function(String url) onPlayTap;
  final ValueChanged<String> onCallBack; // callType: "audio" | "video"
  final ValueChanged<ChatMessage>? onUnsentTap;
  final ValueChanged<ChatMessage>? onLongPress;
  final DateTime? counterpartLastRead;
  final DateTime? counterpartLastDelivered;
  final void Function(ChatMessage)? onQuoteTap;
  final bool highlighted;

  /// 0..1 upload progress for a pending photo, if the outbox is tracking it.
  final double? uploadProgress;

  const _ChatBubble({
    super.key,
    required this.message,
    required this.userRole,
    required this.isPlaying,
    required this.onPlayTap,
    required this.onCallBack,
    this.onUnsentTap,
    this.onLongPress,
    this.onQuoteTap,
    this.highlighted = false,
    this.uploadProgress,
    this.counterpartLastRead,
    this.counterpartLastDelivered,
  });

  @override
  Widget build(BuildContext context) {
    final isBroker = message.isBroker;
    final isMe     = !isBroker && message.role == userRole;

    // Unsend tombstone. The row stays so the conversation keeps its shape;
    // the words and media are gone everywhere, including on a phone that
    // had already received them.
    if (message.deleted || message.msgType == 'deleted') {
      return _DeletedBubble(isMe: isMe);
    }

    // Call log card - rendered full-width/centered like a system message,
    // not as a left/right chat bubble, matching standard messaging-app
    // conventions for call history entries.
    if (message.msgType == 'call') {
      return _CallCard(message: message, userRole: userRole, onCallBack: onCallBack);
    }

    Color roleColor() {
      if (isBroker)                  return BrokaColors.gold;
      if (message.role == 'buyer')   return BrokaColors.neonBlue;
      return BrokaColors.neonGreen;
    }

    String roleLabel() {
      if (isBroker)              return '🤖 Zeno AI';
      if (message.role == 'buyer') return isMe ? '🛒 You' : '🛒 Buyer';
      return isMe ? '🏷️ You' : '🏷️ Seller';
    }

    // Sent/seen tick, WhatsApp-style - only shown on my own messages.
    // A message with no server id yet is still the optimistic local copy
    // (still sending, or failed); once it has one, "seen" is just a
    // timestamp compare against the counterpart's read watermark.
    //
    // FIX (communications audit, 2026-09-14): this was a two-state tick
    // that showed a grey DOUBLE tick for anything the counterpart hadn't
    // read yet. A double tick means "it reached their device" in every
    // messenger anyone has used - claiming it before we had any delivery
    // signal at all was simply false, and it collapsed the two states
    // users most need to tell apart ("it never arrived" and "they
    // haven't looked") into one indistinguishable grey glyph.
    final receipt = isMe
        ? receiptFor(
            sentAt: message.createdAt,
            counterpartDeliveredAt: counterpartLastDelivered,
            counterpartReadAt: counterpartLastRead,
            viaAi: message.viaAi,
            pending: message.isPending,
            failed: message.failed,
          )
        : null;
    // "Not sent" - failed, or stuck long enough to read as failed - is
    // tappable: try again, or delete.
    final unsent = receipt == MessageReceipt.failed && message.isPending;
    Widget? seenTick() =>
        receipt == null ? null : MessageReceiptIcon(receipt: receipt);

    // Zeno's notes in this thread: Zeno's avatar and bubble, as on Zeno's
    // own screen.
    if (isBroker) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const ZenoAvatar(size: 28),
          const SizedBox(width: 8),
          Flexible(child: Container(
            constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: zenoBubbleDecoration(),
            child: Text(message.content, style: const TextStyle(
                color: BrokaColors.textHigh, fontSize: 14, height: 1.5)),
          )),
        ]),
      );
    }

    // Quoted reply, above the content: who said it and a short preview.
    // Tapping jumps to the original; a deleted original renders safely.
    Widget quoteBlock() {
      final target = message.replyToMessageId;
      if (target == null || target.isEmpty) return const SizedBox.shrink();
      final preview = message.replyPreview;
      final deleted = preview?['deleted'] == true;
      final senderRole = (preview?['sender_role'] ?? '') as String;
      final who = senderRole == message.role
          ? (isMe ? 'You' : (message.role == 'buyer' ? 'Buyer' : 'Seller'))
          : (senderRole == 'buyer' ? 'Buyer' : 'Seller');
      final label = ChatMessage.replyLabel(preview);
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: GestureDetector(
          onTap: onQuoteTap == null ? null : () => onQuoteTap!(message),
          child: Container(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.22),
              borderRadius: BorderRadius.circular(8),
              border: Border(
                  left: BorderSide(
                      color: isMe ? Colors.white70 : BrokaColors.neonBlue,
                      width: 3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(who,
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: isMe ? Colors.white : BrokaColors.neonBlue,
                        fontSize: 11, fontWeight: FontWeight.w700)),
                const SizedBox(height: 1),
                Text(deleted ? 'Message deleted' : label,
                    maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: isMe
                            ? Colors.white.withOpacity(0.85)
                            : BrokaColors.textMid,
                        fontSize: 12,
                        fontStyle:
                            deleted ? FontStyle.italic : FontStyle.normal)),
              ],
            ),
          ),
        ),
      );
    }

    final hasQuote = (message.replyToMessageId ?? '').isNotEmpty;

    /// Quote above a media bubble: same block, wrapped in the chat's card
    /// styling so it reads as part of the bubble, not floating text. Also
    /// carries the jump-to-original highlight for media jump targets.
    Widget quotedMedia(Widget media) {
      if (!hasQuote && !highlighted) return media;
      return Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.72),
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
        decoration: (isMe ? myBubbleDecoration() : theirBubbleDecoration()).copyWith(
          border: highlighted ? Border.all(color: BrokaColors.gold, width: 1.5) : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [if (hasQuote) quoteBlock(), media],
        ),
      );
    }

    // Regular bubble
    Widget bubbleContent;
    if (message.msgType == 'voice' && message.mediaUrl != null) {
      bubbleContent = quotedMedia(_VoiceBubble(
        url: message.mediaUrl!,
        duration: message.durationSecs,
        isPlaying: isPlaying,
        onTap: () => onPlayTap(message.mediaUrl!),
        isMe: isMe,
      ));
    } else if (message.msgType == 'image' && message.mediaUrl != null) {
      bubbleContent = quotedMedia(_ImageBubble(
        url: message.mediaUrl!,
        caption: message.content,
        isMe: isMe,
        createdAt: message.createdAt,
        receipt: isMe
            ? receiptFor(
                sentAt: message.createdAt,
                counterpartDeliveredAt: counterpartLastDelivered,
                counterpartReadAt: counterpartLastRead,
                viaAi: message.viaAi,
                pending: message.isPending,
                failed: message.failed,
              )
            : null,
        pending: message.isPending,
        failed: message.failed,
        progress: uploadProgress,
      ));
    } else {
      // Yours on the brand gradient, theirs on a card - as on Zeno's screen
      // - rather than a role-coloured blue or green.
      bubbleContent = Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.72),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: (isMe ? myBubbleDecoration() : theirBubbleDecoration()).copyWith(
          border: highlighted
              ? Border.all(color: BrokaColors.gold, width: 1.5)
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (hasQuote) quoteBlock(),
            Text(message.content,
                style: TextStyle(color: isMe ? Colors.white : BrokaColors.textHigh,
                    fontSize: 14.5, height: 1.4)),
          ],
        ),
      );
    }

    if (unsent && onUnsentTap != null) {
      bubbleContent = GestureDetector(
        key: const Key('unsent-bubble'),
        onTap: () => onUnsentTap!(message),
        child: Opacity(opacity: 0.7, child: bubbleContent),
      );
    } else if (onLongPress != null && !message.isPending) {
      bubbleContent = GestureDetector(
        key: const Key('own-message-menu'),
        onLongPress: () => onLongPress!(message),
        child: bubbleContent,
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isMe) ...[
            Container(
              width: 28, height: 28, margin: const EdgeInsets.only(right: 6),
              decoration: BoxDecoration(
                shape: BoxShape.circle, color: roleColor().withOpacity(0.2)),
              child: Center(child: Icon(
                message.role == 'buyer' ? Icons.shopping_cart_rounded : Icons.store_rounded,
                color: roleColor(), size: 14)),
            ),
          ],
          Flexible(child: Column(
            crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              bubbleContent,
              const SizedBox(height: 2),
              Row(
                mainAxisSize: MainAxisSize.min,
                // Centre, not baseline: the receipt is an icon whose optical
                // centre sits above a text baseline, so baseline alignment
                // hung the ticks low against the label.
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(roleLabel(), style: TextStyle(color: roleColor(),
                      fontSize: 10, fontWeight: FontWeight.w600)),
                  // When it was sent (2026-10-27): no bubble carried a
                  // time at all. Their messages get the time; mine get
                  // time + the receipt word, so sent / delivered / seen /
                  // not-sent can be told apart without reading ticks.
                  // Image bubbles already carry their own time and receipt
                  // inside the photo card - repeating them underneath would
                  // draw every photo's state twice.
                  if (message.msgType != 'image' &&
                      formatMessageTime(message.createdAt).isNotEmpty) ...[
                    const SizedBox(width: 5),
                    const Text('·', style: TextStyle(color: BrokaColors.textLow, fontSize: 10)),
                    const SizedBox(width: 5),
                    MessageTimeLabel(sentAt: message.createdAt),
                  ],
                  if (message.editedAt != null) ...[
                    const SizedBox(width: 4),
                    const Text('edited', style: TextStyle(color: BrokaColors.textLow,
                        fontSize: 9, fontStyle: FontStyle.italic)),
                  ],
                  if (message.msgType != 'image' && seenTick() != null) ...[
                    const SizedBox(width: 5),
                    seenTick()!,
                  ],
                ],
              ),
            ],
          )),
          if (isMe) const SizedBox(width: 6),
        ],
      ),
    );
  }
}

// ── Deleted message tombstone ─────────────────────────────────────────────────

class _DeletedBubble extends StatelessWidget {
  final bool isMe;
  const _DeletedBubble({required this.isMe});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: BrokaColors.bgCard.withOpacity(0.6),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: BrokaColors.border),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.block_rounded, size: 13, color: BrokaColors.textLow),
              const SizedBox(width: 6),
              Text(isMe ? 'You deleted this message' : 'This message was deleted',
                  style: const TextStyle(color: BrokaColors.textLow,
                      fontSize: 12, fontStyle: FontStyle.italic)),
            ]),
          ),
        ],
      ),
    );
  }
}

// ── Voice bubble ───────────────────────────────────────────────────────────────

class _VoiceBubble extends StatelessWidget {
  final String url;
  final int?   duration;
  final bool   isPlaying;
  final VoidCallback onTap;
  final bool   isMe;

  const _VoiceBubble({
    required this.url, required this.duration,
    required this.isPlaying, required this.onTap, required this.isMe,
  });

  @override
  Widget build(BuildContext context) {
    final secs = duration ?? 0;
    final m = (secs ~/ 60).toString().padLeft(1, '0');
    final s = (secs % 60).toString().padLeft(2, '0');

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: const BoxConstraints(minWidth: 140),
        decoration: BoxDecoration(
          color: isMe ? const Color(0xFF1565C0) : BrokaColors.bgCard,
          borderRadius: BorderRadius.only(
            topLeft:     Radius.circular(isMe ? 14 : 4),
            topRight:    Radius.circular(isMe ? 4 : 14),
            bottomLeft:  const Radius.circular(14),
            bottomRight: const Radius.circular(14)),
          border: Border.all(color: BrokaColors.gold.withOpacity(0.3))),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: BrokaColors.gold.withOpacity(0.2)),
            child: Icon(
              isPlaying ? Icons.stop_rounded : Icons.play_arrow_rounded,
              color: BrokaColors.gold, size: 20),
          ),
          const SizedBox(width: 10),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Voice Note',
                style: TextStyle(color: BrokaColors.textMid, fontSize: 11)),
            Text('$m:$s',
                style: const TextStyle(color: BrokaColors.textHigh,
                    fontSize: 13, fontWeight: FontWeight.w700)),
          ]),
          const SizedBox(width: 8),
          const Icon(Icons.mic_rounded, color: BrokaColors.gold, size: 14),
        ]),
      ),
    );
  }
}

// ── Image bubble ───────────────────────────────────────────────────────────────
// WhatsApp-style: the photo keeps its aspect ratio inside a bounded bubble,
// with an optional caption, a timestamp and the delivery state. Tapping
// opens a dedicated viewer with pinch-to-zoom and a clear close control.

class _ImageBubble extends StatelessWidget {
  final String url;
  final String? caption;
  final bool isMe;
  final DateTime? createdAt;
  final MessageReceipt? receipt;
  final bool pending;
  final bool failed;

  /// 0..1 upload progress. Shown as a ring with a percent while uploading;
  /// null (or 0) keeps the plain spinner for indeterminate stages.
  final double? progress;
  const _ImageBubble({
    required this.url,
    this.caption,
    this.isMe = false,
    this.createdAt,
    this.receipt,
    this.pending = false,
    this.failed = false,
    this.progress,
  });

  ImageProvider? _provider() {
    try {
      if (url.startsWith('data:')) {
        final commaIdx = url.indexOf(',');
        if (commaIdx < 0) return null;
        return MemoryImage(base64Decode(url.substring(commaIdx + 1)));
      }
      if (url.startsWith('file://')) return FileImage(File(url.replaceFirst('file://', '')));
      if (url.isEmpty) return null;
      return NetworkImage(url);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = _provider();
    final captionText = (caption ?? '').trim();
    return GestureDetector(
      onTap: provider == null
          ? null
          : () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => _FullScreenImageViewer(
                    url: url, caption: captionText.isEmpty ? null : captionText),
              )),
      child: Container(
        constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.68,
            maxHeight: 340),
        decoration: BoxDecoration(
          color: BrokaColors.bgCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: BrokaColors.border.withOpacity(0.7)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (provider == null)
              Container(
                height: 120,
                alignment: Alignment.center,
                child: const Icon(Icons.broken_image_outlined,
                    color: BrokaColors.textLow, size: 36),
              )
            else
              // The photo's own ratio drives the frame: portrait, landscape
              // and square all render whole, never centre-cropped.
              Stack(
                children: [
                  AspectImage(
                    provider: provider,
                    maxWidth: MediaQuery.of(context).size.width * 0.68,
                    maxHeight: 340,
                  ),
                  if (pending || failed)
                    Positioned.fill(
                      child: Container(
                        color: Colors.black.withOpacity(0.45),
                        alignment: Alignment.center,
                        child: pending
                            ? _UploadProgressRing(progress: progress)
                            : const Icon(Icons.error_outline_rounded,
                                color: Colors.white, size: 30),
                      ),
                    ),
                ],
              ),
            if (captionText.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 2),
                child: Text(captionText,
                    style: TextStyle(
                        color: isMe ? Colors.white : BrokaColors.textHigh,
                        fontSize: 13.5, height: 1.35)),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  MessageTimeLabel(sentAt: createdAt),
                  if (receipt != null) ...[
                    const SizedBox(width: 5),
                    MessageReceiptIcon(receipt: receipt!),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Upload progress over a pending photo: a determinate ring with a percent
/// once bytes are moving, the plain spinner before the first tick.
class _UploadProgressRing extends StatelessWidget {
  const _UploadProgressRing({this.progress});

  final double? progress;

  @override
  Widget build(BuildContext context) {
    final p = progress;
    if (p == null || p <= 0) {
      return const SizedBox(
        width: 26,
        height: 26,
        child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white),
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 44,
          height: 44,
          child: Stack(
            alignment: Alignment.center,
            children: [
              CircularProgressIndicator(
                  value: p.clamp(0.0, 1.0), strokeWidth: 3, color: Colors.white,
                  backgroundColor: Colors.white24),
              Text('${(p.clamp(0.0, 1.0) * 100).round()}',
                  style: const TextStyle(
                      color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
            ],
          ),
        ),
      ],
    );
  }
}

/// Dedicated full-screen photo viewer: pinch-to-zoom, caption, close.
class _FullScreenImageViewer extends StatelessWidget {
  final String url;
  final String? caption;
  const _FullScreenImageViewer({required this.url, this.caption});

  ImageProvider? _provider() {
    try {
      if (url.startsWith('data:')) {
        final commaIdx = url.indexOf(',');
        if (commaIdx < 0) return null;
        return MemoryImage(base64Decode(url.substring(commaIdx + 1)));
      }
      if (url.startsWith('file://')) return FileImage(File(url.replaceFirst('file://', '')));
      if (url.isEmpty) return null;
      return NetworkImage(url);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final provider = _provider();
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        leading: IconButton(
          tooltip: 'Close',
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Column(children: [
        Expanded(
          child: Center(
            child: provider == null
                ? const Icon(Icons.broken_image_outlined,
                    color: Colors.white54, size: 48)
                : InteractiveViewer(
                    minScale: 1.0,
                    maxScale: 4.0,
                    child: Image(
                      image: provider,
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => const Icon(
                          Icons.broken_image_outlined,
                          color: Colors.white54, size: 48),
                    ),
                  ),
          ),
        ),
        if ((caption ?? '').trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
            child: Text((caption ?? '').trim(),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 14)),
          ),
      ]),
    );
  }
}

/// Three-dot typing animation in BROKA's chat styling.
class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => Row(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < 3; i++)
          Container(
            width: 6, height: 6,
            margin: EdgeInsets.only(right: i == 2 ? 0 : 3),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: BrokaColors.textMid.withOpacity(
                  0.35 + 0.65 * ((i / 3 + _ctrl.value) % 1.0)),
            ),
          ),
      ]),
    );
  }
}

class _CallCard extends StatelessWidget {
  final ChatMessage message;
  final String userRole;
  final ValueChanged<String> onCallBack; // callType: "audio" | "video"
  const _CallCard({required this.message, required this.userRole, required this.onCallBack});

  String _relativeTime(DateTime? dt) {
    if (dt == null) return '';
    final diff = DateTime.now().difference(dt.toLocal());
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours   < 24) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }

  @override
  Widget build(BuildContext context) {
    // The card carries the caller's role: mine when I placed the call.
    final outgoing = message.role == userRole;
    final outcome = message.content; // "completed" | "missed" | "declined" | "cancelled"
    final callType = message.callType ?? 'audio';
    final isVideo = callType == 'video';
    // It rang me and nobody picked up; "cancelled" only says the caller gave
    // up first. The Calls screen's rule (backend calls.py get_call_history).
    final missed = !outgoing && (outcome == 'missed' || outcome == 'cancelled');
    // Said as the Calls screen says it. This card said "Call from Buyer"
    // with an outgoing arrow for a call that came in, "Call cancelled from
    // You" in red for one the user simply hung up on, and the other
    // person's side of the deal where the header names them.
    final kind = isVideo ? 'video call' : 'call';
    final title = missed ? 'Missed $kind' : '${outgoing ? 'Outgoing' : 'Incoming'} $kind';
    final when = _relativeTime(message.createdAt);
    final detail = [
      if (!missed)
        callSummary(outcome: outcome, isOutgoing: outgoing, durationSecs: message.durationSecs),
      if (when.isNotEmpty) when,
    ].join(' · ');
    final color = missed
        ? BrokaColors.danger
        : (outgoing ? BrokaColors.neonBlue : BrokaColors.neonGreen);
    final icon = missed
        ? Icons.call_missed_rounded
        : (outgoing ? Icons.call_made_rounded : Icons.call_received_rounded);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Center(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 280),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: BrokaColors.bgCard,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: color.withOpacity(0.4)),
          ),
          child: Row(children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(
                  color: missed ? BrokaColors.danger : BrokaColors.textHigh,
                  fontWeight: FontWeight.w700, fontSize: 13)),
              if (detail.isNotEmpty)
                Text(detail, style: const TextStyle(
                    color: BrokaColors.textLow, fontSize: 11)),
            ])),
            if (!outgoing && outcome != 'completed')
              GestureDetector(
                onTap: () => onCallBack(callType),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: BrokaColors.neonGreen.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(isVideo ? Icons.videocam_rounded : Icons.call_rounded,
                        size: 14, color: BrokaColors.neonGreen),
                    const SizedBox(width: 4),
                    const Text('Call back', style: TextStyle(
                        color: BrokaColors.neonGreen, fontSize: 12, fontWeight: FontWeight.w700)),
                  ]),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}
