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
import 'package:shared_preferences/shared_preferences.dart';
import '../main.dart';
import '../services/api_service.dart';
import '../features/escrow/presentation/escrow_actions.dart';
import '../services/chat_screen_memory.dart';
import '../services/notification_service.dart';
import '../services/photo_capture.dart';
import '../widgets/message_receipt.dart';
import '../widgets/chat_parts.dart';
import '../widgets/collapsing_screen_header.dart';
import '../widgets/constellation_background.dart';
import '../widgets/units_stepper.dart';
import '../widgets/zeno_avatar.dart';
import '../services/ringtone_service.dart';
import 'voip_call_screen.dart';
import '../models/models.dart';
import '../models/listing.dart';
import '../services/last_screen_tracker.dart';
import '../services/global_poller_service.dart';
import '../services/local_chat_store.dart';
import '../services/zeno_voice_controller.dart';

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
    createdAt:    (j['created_at'] is String && (j['created_at'] as String).isNotEmpty)
        ? DateTime.tryParse(j['created_at'] as String)
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
  );

  ChatMessage withFailed(bool value) => ChatMessage(
    role: role, content: content, msgType: msgType, mediaUrl: mediaUrl,
    durationSecs: durationSecs, callType: callType, viaAi: viaAi,
    isBroker: isBroker, createdAt: createdAt, clientId: clientId,
    failed: value, id: id,
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
    if (failed) 'failed': true,
  };
}

/// A voice note or photo still to be (re)sent, kept in memory so "Try
/// again" doesn't mean recording or picking it again.
class _PendingUpload {
  const _PendingUpload({
    required this.bytes, required this.contentType, required this.fileName,
    required this.mimeType, this.durationSecs,
  });
  final Uint8List bytes;
  final String contentType; // "audio" | "image"
  final String fileName;
  final String mimeType;
  final int? durationSecs;
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
  bool   _incomingCallShown = false;

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
    _loadCachedMessages();
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
    // Polling fallback for calls + WS failover
    _pollTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (_listing == null || !mounted) return;
      _pollIncomingCall();
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
  int _zenoUnreadCount = 0;

  String _zenoSeenKey() => 'zeno_seen_count_${_listing?.id}_${_buyerId ?? ""}';

  Future<void> _refreshZenoUnreadCount() async {
    if (_listing == null) return;
    try {
      final history = await ApiService.getNegotiationHistory(
        _listing!.id, buyerId: _buyerId,
      );
      final brokerCount = history.where((m) => m.role == 'broker').length;
      final prefs = await SharedPreferences.getInstance();
      final seenCount = prefs.getInt(_zenoSeenKey()) ?? 0;
      final unread = brokerCount - seenCount;
      if (mounted) setState(() => _zenoUnreadCount = unread > 0 ? unread : 0);
    } catch (_) {}
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
    try {
      final info = await ApiService.getUserProfile(counterpartyId);
      if (mounted) setState(() => _counterpartyInfo = info);
    } catch (_) {}
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

  void _onSocketClosed(WebSocketChannel ws) {
    if (!identical(_ws, ws)) return;
    _wsPingTimer?.cancel();
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
      case 'message':
        final cm = ChatMessage.fromJson(data);
        // Direct chat never shows Zeno (broker) messages - same rule as
        // _loadHistory/_pollNewMessages (_absorb).
        if (!_absorb(cm)) return;
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

  /// A message that arrived while the app is in the background. On screen
  /// it needs no notification - it is right there.
  void _notifyIfAway(ChatMessage cm) {
    final listing = _listing;
    if (_appVisible || listing == null || cm.msgType == 'call') return;
    final who = _counterpartyName;
    final preview = switch (cm.msgType) {
      'image' => '\u{1F4F7} Photo',
      'voice' => '\u{1F3A4} Voice message',
      _ => cm.content,
    };
    NotificationService.instance.showNewMessage(
      fromName: who,
      preview: preview,
      // The key GlobalPollerService posts this thread's messages under, so
      // the two collapse into one notification instead of stacking.
      threadKey: 'thread_${listing.id}_${_buyerId ?? ''}',
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
      _messages.add(m);
    }
    return true;
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
        _messages.add(server);
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
        _messages = restored;
        _loading = false;
      });
      _markSeen(_messages);
      _scrollDown();
    } catch (_) {}
  }

  Future<void> _cacheMessages() => LocalChatStore.save(
      _threadScopeKey(), _messages.map((m) => m.toJson()).toList());

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
      _scrollDown();
      unawaited(_cacheMessages());
      unawaited(_syncReadState());
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
        if (_absorb(ChatMessage.fromMessage(m))) {
          changed = true;
          if (m.role != _role) inbound = true;
        }
      }
      if (!changed) return;
      setState(() {});
      _scrollDown();
      unawaited(_cacheMessages());
      if (inbound) unawaited(_syncReadState());
    } catch (_) {}
  }

  Future<void> _pollIncomingCall() async {
    try {
      final callInfo = await ApiService.checkIncomingCall(_listing!.id);
      if (!mounted) return;
      // FIX (V2 hardening, 2026-09-03): this used to also require
      // _role == 'seller' - but /calls/pending/{listingId} already scopes
      // its result to the current authenticated user as callee, whichever
      // role they are, so gating on role here just meant a BUYER polling
      // for an incoming call from the seller would get a real callInfo
      // back and then silently do nothing with it. The backend's
      // authorization is the actual gate; this client-side role check was
      // redundant and wrong.
      if (callInfo != null && !_incomingCallShown) {
        final roomId    = callInfo['room_id'] as String?;
        // The caller's app sends its user's name, or "Buyer" when it has
        // none; the caller is the person this chat is with, whose name the
        // chat already has.
        final sentName = callInfo['caller_name'] as String? ?? '';
        final callerName = VoipCallScreen.isPlaceholderName(sentName)
            ? _counterpartyName : sentName;
        final callerId   = callInfo['caller_id'] as String? ?? '';
        final callToken  = callInfo['call_token'] as String? ?? '';
        final callType   = callInfo['call_type'] as String? ?? 'audio';
        final isVideo    = callType == 'video';
        // Whoever is polling here is NOT the caller (call_state.py never
        // returns your own outgoing call as pending) - so the caller is
        // whichever side I'm not. If I'm the seller, the caller is the
        // buyer (callerId IS the buyer). If I'm the buyer, the caller is
        // the seller, and I am the buyer myself.
        final iAmSeller = _role == 'seller';
        final buyerIdForThread   = iAmSeller ? callerId : (ApiService.currentUserId ?? _buyerId ?? '');
        final callerRoleForThread = iAmSeller ? 'buyer' : 'seller';
        if (roomId != null) {
          _incomingCallShown = true;
          NotificationService.instance.showIncomingCall(
            roomId: roomId,
            callerName: callerName,
            listingName: _listing?.name ?? 'your listing',
            isVideo: isVideo,
            payload: {
              'type':      'incoming_call',
              'roomId':    roomId,
              'listingId': _listing!.id,
              'buyerId':   buyerIdForThread,
            },
          );
          // Ring until Answer/Decline - or this safety timeout, in case the
          // caller cancels before we ever notice (we haven't joined the call
          // room yet at this point, so there's no signal that could tell us).
          RingtoneService.instance.play(
            autoStopAfter: const Duration(seconds: 45),
            onTimeout: () {
              if (!mounted || !_incomingCallShown) return;
              _incomingCallShown = false;
              NotificationService.instance.cancelIncomingCall(roomId);
              Navigator.pop(context);
            },
          );
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (_) => AlertDialog(
              backgroundColor: BrokaColors.bgMid,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              title: Row(children: [
                Icon(isVideo ? Icons.videocam_rounded : Icons.call_rounded,
                    color: BrokaColors.neonGreen),
                const SizedBox(width: 10),
                Text(isVideo ? 'Incoming Video Call' : 'Incoming Call',
                    style: const TextStyle(color: BrokaColors.textHigh)),
              ]),
              content: Text(
                  '$callerName is ${isVideo ? 'video calling' : 'calling'} about ${_listing?.name ?? 'your listing'}',
                  style: const TextStyle(color: BrokaColors.textMid)),
              actions: [
                TextButton(
                  onPressed: () {
                    RingtoneService.instance.stop();
                    Navigator.pop(context);
                    _incomingCallShown = false;
                    NotificationService.instance.cancelIncomingCall(roomId);
                    if (buyerIdForThread.isNotEmpty && _listing?.id != null) {
                      unawaited(ApiService.logCallResult(
                        roomId: roomId, listingId: _listing!.id, buyerId: buyerIdForThread,
                        outcome: 'declined', callerRole: callerRoleForThread,
                        callType: callType,
                      ));
                    }
                  },
                  child: const Text('Decline', style: TextStyle(color: BrokaColors.danger)),
                ),
                ElevatedButton.icon(
                  icon: Icon(isVideo ? Icons.videocam_rounded : Icons.call_rounded, size: 16),
                  label: const Text('Answer'),
                  style: ElevatedButton.styleFrom(backgroundColor: BrokaColors.neonGreen),
                  onPressed: () {
                    RingtoneService.instance.stop();
                    Navigator.pop(context);
                    NotificationService.instance.cancelIncomingCall(roomId);
                    Navigator.pushNamed(context, '/voip-call', arguments: {
                      'roomId': roomId, 'userId': ApiService.currentUserId ?? '',
                      'callToken': callToken,
                      'isCaller': false, 'peerName': callerName,
                      'peerId': callerId,
                      'peerPhoto': _counterpartyPhoto,
                      'listingName': _listing?.name ?? '', 'listingId': _listing?.id ?? '',
                      'buyerId': buyerIdForThread, 'callerRole': callerRoleForThread,
                      'callType': callType,
                      // Tapping Answer here IS answering - don't make the
                      // user tap Accept again on the call screen (which by
                      // then is silent, because the ringtone has stopped).
                      'autoAccept': true,
                    }).then((_) => _incomingCallShown = false);
                  },
                ),
              ],
            ),
          );
        }
      }
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

  Future<void> _send() async {
    final text = _msgCtrl.text.trim();
    if (text.isEmpty || _listing == null) return;
    final clientId = _newClientId();
    setState(() => _messages.add(ChatMessage(
      role: _role, content: text, msgType: 'text',
      clientId: clientId, createdAt: DateTime.now().toUtc(),
    )));
    _msgCtrl.clear();
    _scrollDown();
    unawaited(_cacheMessages());
    _enqueue(() => _deliverText(clientId, text));
  }

  Future<void> _deliverText(String clientId, String text) async {
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
      unawaited(_cacheMessages());
      return;
    }
    setState(() => _messages[i] = _messages[i].withFailed(false));
    // The same client id: if the first attempt did arrive after all, the
    // server answers with that copy instead of storing a second.
    if (m.msgType == 'text') {
      _enqueue(() => _deliverText(clientId, m.content));
    } else {
      _enqueue(() => _deliverUpload(clientId));
    }
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
    _uploads[clientId] = _PendingUpload(
      bytes: bytes, contentType: 'audio', fileName: 'voice.m4a',
      mimeType: 'audio/mp4', durationSecs: duration,
    );
    setState(() => _messages.add(ChatMessage(
      role: _role, msgType: 'voice',
      mediaUrl: 'file://$path',
      durationSecs: duration,
      clientId: clientId, createdAt: DateTime.now().toUtc(),
    )));
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

  /// A photo into the chat, taken with BROKA's own camera or picked from the
  /// gallery the way listing photos are (services/photo_capture.dart). This
  /// used to open the phone's camera app, which Android could kill BROKA
  /// behind, dropping the user out of the conversation.
  Future<void> _pickAndSendImage(PhotoSource source) async {
    try {
      final File? picked;
      if (source == PhotoSource.camera) {
        picked = await PhotoCapture.takePhoto(context,
            hint: 'Show it clearly, in good light - the other side sees exactly this.');
      } else {
        picked = await PhotoCapture.pickFromGallery(context);
      }
      if (picked == null || !mounted) return;
      final bytes = await picked.readAsBytes();
      final b64   = base64Encode(bytes);
      final dataUri = 'data:image/jpeg;base64,$b64';
      if (!mounted) return;

      final clientId = _newClientId();
      _uploads[clientId] = _PendingUpload(
        bytes: bytes, contentType: 'image', fileName: 'image.jpg',
        mimeType: 'image/jpeg',
      );
      setState(() => _messages.add(ChatMessage(
        role: _role, msgType: 'image', mediaUrl: dataUri,
        clientId: clientId, createdAt: DateTime.now().toUtc(),
      )));
      _scrollDown();
      _enqueue(() => _deliverUpload(clientId));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not send image: $e')));
      }
    }
  }

  Future<void> _showImageSourceSheet() async {
    final source = await PhotoCapture.askSource(context);
    if (source != null && mounted) await _pickAndSendImage(source);
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
      // room_id + call_token are now server-issued (POST /calls/initiate) -
      // no longer constructed client-side, so this has to be awaited
      // before navigating rather than fired-and-forgotten. calleeId is
      // required when the seller is calling (see calls.py's initiate_call
      // - a listing can have multiple buyer threads, so the backend can't
      // infer which buyer to ring the way it can infer the seller).
      final initResult = await ApiService.initiateCall(
        listingId: listing.id, listingName: listing.name, callType: callType,
        calleeId: _role == 'seller' ? _buyerId : null);
      if (initResult == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Could not start the call - please try again.')),
          );
        }
        return;
      }
      if (!mounted) return;
      Navigator.pushNamed(context, '/voip-call', arguments: {
        'roomId': initResult['room_id'], 'userId': ApiService.currentUserId ?? 'anon',
        'callToken': initResult['call_token'],
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

  Future<void> _openZenoAi() async {
    if (_listing != null) {
      try {
        final history = await ApiService.getNegotiationHistory(
          _listing!.id, buyerId: _buyerId,
        );
        final brokerCount = history.where((m) => m.role == 'broker').length;
        final prefs = await SharedPreferences.getInstance();
        await prefs.setInt(_zenoSeenKey(), brokerCount);
      } catch (_) {}
    }
    if (!mounted) return;
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
    RingtoneService.instance.stop();
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
        // Every buyer can pay from here: there is no "finalize" step before
        // it any more (auctions are paid from the auction screen).
        if (_role == 'buyer' && _listing != null && _listing!.listingType != 'auction')
          _buildPaymentPanel(),
        Expanded(child: _loading
            ? const Center(child: CircularProgressIndicator(color: BrokaColors.gold))
            : _buildMessages()),
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
            // The live connection, folded into the status line rather than
            // a lone dot among the buttons.
            Container(
              width: 6, height: 6, margin: const EdgeInsets.only(right: 5),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _wsConnected ? BrokaColors.neonGreen : BrokaColors.textLow),
            ),
            Flexible(child: Text(
              _counterpartyLastSeen ?? (_counterpartyOnline ? 'Active now' : 'Direct chat'),
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

  Widget _buildPaymentPanel() {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: BrokaColors.bgCard.withOpacity(0.86),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BrokaColors.neonGreen.withOpacity(0.45))),
      child: Row(children: [
        const Icon(Icons.lock_rounded, color: BrokaColors.neonGreen, size: 20),
        const SizedBox(width: 10),
        const Expanded(child: Text(
            "Pay securely - the seller is paid only after you've received the item.",
            style: TextStyle(color: BrokaColors.neonGreen,
                fontSize: 12, fontWeight: FontWeight.w600))),
        GestureDetector(
          key: const Key('pay-now'),
          onTap: _payNow,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(color: BrokaColors.neonGreen,
                borderRadius: BorderRadius.circular(8)),
            child: const Text('Pay', style: TextStyle(color: Colors.black87,
                fontWeight: FontWeight.w800, fontSize: 12)),
          ),
        ),
      ]),
    );
  }

  // ── Messages list ──────────────────────────────────────────────────────────

  Widget _buildMessages() {
    if (_messages.isEmpty) {
      // Reworked to sit ON the constellation rather than float in a void.
      // The previous version was a bare emoji over two grey lines centred in
      // pure black, which read as an error state more than an invitation.
      // A haloed emblem plus an explicit privacy line — the single most
      // useful thing to tell someone opening a marketplace chat — does more
      // work in the same space.
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 40),
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
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.shield_outlined, size: 13, color: BrokaColors.neonGreen),
                SizedBox(width: 6),
                Text('Keep payments on BROKA to stay protected',
                    style: TextStyle(
                        color: BrokaColors.neonGreen,
                        fontSize: 11, fontWeight: FontWeight.w600)),
              ]),
            ),
          ]),
        ),
      );
    }
    return ListView.builder(
      controller: _scrollCtrl,
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      itemCount: _messages.length,
      itemBuilder: (_, i) => _ChatBubble(
        message:    _messages[i],
        userRole:   _role,
        isPlaying:  _isPlaying && _playingUrl == _messages[i].mediaUrl,
        onPlayTap:  (url) => _togglePlay(url),
        onCallBack: _callBack,
        onUnsentTap: _onUnsentTap,
        counterpartLastRead: _counterpartLastRead,
        counterpartLastDelivered: _counterpartLastDelivered,
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
                        hintText: _role == 'buyer' ? 'Message seller' : 'Message buyer',
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
  final DateTime? counterpartLastRead;
  final DateTime? counterpartLastDelivered;

  const _ChatBubble({
    required this.message,
    required this.userRole,
    required this.isPlaying,
    required this.onPlayTap,
    required this.onCallBack,
    this.onUnsentTap,
    this.counterpartLastRead,
    this.counterpartLastDelivered,
  });

  @override
  Widget build(BuildContext context) {
    final isBroker = message.isBroker;
    final isMe     = !isBroker && message.role == userRole;

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

    // Regular bubble
    Widget bubbleContent;
    if (message.msgType == 'voice' && message.mediaUrl != null) {
      bubbleContent = _VoiceBubble(
        url: message.mediaUrl!,
        duration: message.durationSecs,
        isPlaying: isPlaying,
        onTap: () => onPlayTap(message.mediaUrl!),
        isMe: isMe,
      );
    } else if (message.msgType == 'image' && message.mediaUrl != null) {
      bubbleContent = _ImageBubble(url: message.mediaUrl!);
    } else {
      // Yours on the brand gradient, theirs on a card - as on Zeno's screen
      // - rather than a role-coloured blue or green.
      bubbleContent = Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.72),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: isMe ? myBubbleDecoration() : theirBubbleDecoration(),
        child: Text(message.content,
            style: TextStyle(color: isMe ? Colors.white : BrokaColors.textHigh,
                fontSize: 14.5, height: 1.4)),
      );
    }

    if (unsent && onUnsentTap != null) {
      bubbleContent = GestureDetector(
        key: const Key('unsent-bubble'),
        onTap: () => onUnsentTap!(message),
        child: Opacity(opacity: 0.7, child: bubbleContent),
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
                  if (seenTick() != null) ...[
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

class _ImageBubble extends StatelessWidget {
  final String url;
  const _ImageBubble({required this.url});

  @override
  Widget build(BuildContext context) {
    ImageProvider provider;
    if (url.startsWith('data:')) {
      final commaIdx = url.indexOf(',');
      if (commaIdx >= 0) {
        final bytes = base64Decode(url.substring(commaIdx + 1));
        provider = MemoryImage(bytes);
      } else {
        provider = const AssetImage('assets/placeholder.png') as ImageProvider;
      }
    } else {
      provider = NetworkImage(url);
    }

    return GestureDetector(
      onTap: () => showDialog(
        context: context,
        builder: (_) => Dialog(
          backgroundColor: Colors.transparent,
          child: InteractiveViewer(child: Image(image: provider)),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Image(
          image: provider,
          width: 200, height: 200,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => Container(
            width: 200, height: 80, color: BrokaColors.bgCard,
            child: const Center(child: Icon(Icons.broken_image_rounded,
                color: BrokaColors.textLow))),
        ),
      ),
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
    final outcome = message.content; // "missed" | "completed" | "declined" | "cancelled"
    final callType = message.callType ?? 'audio';
    final isVideo    = callType == 'video';
    final isMissed    = outcome == 'missed';
    final isDeclined  = outcome == 'declined';
    final isCancelled = outcome == 'cancelled';
    final color = isMissed || isDeclined || isCancelled ? BrokaColors.danger : BrokaColors.neonGreen;
    final isMe = message.role == userRole;
    final icon = isMissed
        ? Icons.call_missed_rounded
        : (isDeclined || isCancelled)
            ? Icons.call_end_rounded
            : (isVideo ? Icons.videocam_rounded : Icons.call_made_rounded);
    final label = isMissed
        ? (isVideo ? 'Missed video call' : 'Missed call')
        : isDeclined
            ? (isVideo ? 'Video call declined' : 'Call declined')
            : isCancelled
                ? (isVideo ? 'Video call cancelled' : 'Call cancelled')
                : (isVideo ? 'Video call' : 'Call');
    // Phrase relative to whoever is viewing this card, not just the caller's
    // raw role - "from You" if the viewer placed the call, otherwise name
    // the other party.
    final callerLabel = isMe
        ? 'from You'
        : (message.role == 'buyer' ? 'from Buyer' : 'from Seller');

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
              Text('$label $callerLabel', style: const TextStyle(
                  color: BrokaColors.textHigh, fontWeight: FontWeight.w700, fontSize: 13)),
              if (message.createdAt != null)
                Text(_relativeTime(message.createdAt), style: const TextStyle(
                    color: BrokaColors.textLow, fontSize: 11)),
            ])),
            if ((isMissed || isDeclined || isCancelled) && !isMe)
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
