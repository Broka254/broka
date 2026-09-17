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
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:record/record.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/webrtc_service.dart';
import '../main.dart';
import '../services/api_service.dart';
import '../services/notification_service.dart';
import '../widgets/message_receipt.dart';
import '../widgets/chat_ambient_background.dart';
import '../services/ringtone_service.dart';
import '../models/models.dart';
import '../models/listing.dart';
import '../services/last_screen_tracker.dart';
import '../services/global_poller_service.dart';
import '../services/local_chat_store.dart';

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
  final String  id;
  final DateTime? createdAt;

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
    String? id,
  }) : id = id ?? '';

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
    createdAt:    j['created_at'] != null
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
    createdAt:    m.createdAt,
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
  };
}

// ── Screen ────────────────────────────────────────────────────────────────────

class NegotiationScreen extends StatefulWidget {
  const NegotiationScreen({super.key});
  @override
  State<NegotiationScreen> createState() => _NegotiationScreenState();
}

class _NegotiationScreenState extends State<NegotiationScreen>
    with WidgetsBindingObserver {
  Listing?          _listing;
  List<ChatMessage> _messages = [];
  bool              _loading  = true;
  bool              _sending  = false;
  String            _role     = 'buyer';
  String?           _buyerId; // the buyer in this thread (may differ from current user when seller views)

  // WebSocket
  WebSocketChannel? _ws;
  bool              _wsConnected = false;

  // Message ids already represented in _messages - the single source of
  // truth for "have I already shown this one" across cache load, history
  // load, the poll fallback, WS delivery, and my own optimistic sends.
  // Previously the poll fallback only compared list *lengths*
  // (_serverMsgCount), which raced with _send()'s own history refetch: if
  // the 4-second poll timer fired while that refetch was still in flight,
  // it would see the just-sent message as "new" a second time and append
  // a duplicate bubble - this is what caused direct-chat messages to
  // visibly appear twice.
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
  bool                _isPlaying   = false;
  String?             _playingUrl;
  String?             _recordPath;
  DateTime?           _recordStart;

  // Image picker
  final ImagePicker _picker = ImagePicker();

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
        if (la is Listing) _listing = la;
        else if (la is Map) _listing = Listing.fromJson(Map<String, dynamic>.from(la));
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
          if (_listing != null && mounted) {
            _pollIncomingCall();
            if (!_wsConnected) _pollNewMessages();
          }
        });
      }
    }
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
      (_listing?.sellerName ?? 'S')[0].toUpperCase(),
      style: const TextStyle(color: Colors.white,
          fontWeight: FontWeight.w800, fontSize: 16)));

  Future<void> _loadCounterpartyInfo() async {
    if (_listing == null) return;
    final counterpartyId = _role == 'buyer' ? _listing!.sellerId : _buyerId;
    if (counterpartyId == null) return;
    try {
      final info = await ApiService.getUserProfile(counterpartyId);
      if (mounted) setState(() => _counterpartyInfo = info);
    } catch (_) {}
  }

  bool get _counterpartyOnline => (_counterpartyInfo?['is_online'] as bool?) ?? false;
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
      _pollTimer = Timer.periodic(const Duration(seconds: 4), (_) {
        if (_listing != null && mounted) {
          _pollIncomingCall();
          if (!_wsConnected) _pollNewMessages();
        }
      });
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
    final listing = _listing;
    final token   = ApiService.authToken;
    if (listing == null || token == null) return;

    // Build WS URL: replace http(s) with ws(s)
    final base = ApiService.baseUrl
        .replaceFirst('https://', 'wss://')
        .replaceFirst('http://',  'ws://');

    var url = '$base/media/ws/${listing.id}?token=$token';
    if (_role == 'seller' && _buyerId != null) {
      url += '&buyer_id=$_buyerId';
    }

    try {
      _ws = WebSocketChannel.connect(Uri.parse(url));
      // Don't mark connected yet - .connect() only constructs the channel,
      // it doesn't confirm the handshake succeeded. Wait for the server's
      // first message (or just a successful stream event) before trusting
      // it, so the polling fallback isn't wrongly suppressed while a failed
      // connection is still timing out.
      _wsConnected = false;
      _ws!.ready.then((_) {
        if (mounted) setState(() => _wsConnected = true);
      }).catchError((_) {
        if (mounted) setState(() => _wsConnected = false);
      });
      _ws!.stream.listen(
        (raw) {
          if (!mounted) return;
          if (!_wsConnected) setState(() => _wsConnected = true);
          try {
            final data = jsonDecode(raw as String) as Map<String, dynamic>;
            if (data['type'] == 'pong') return;
            if (data['type'] == 'message') {
              final cm = ChatMessage.fromJson(data);
              // Direct chat never shows Zeno (broker) messages - same rule
              // as _loadHistory/_pollNewMessages.
              if (cm.isBroker || cm.viaAi) return;
              // Avoid duplicates (optimistic local add + WS broadcast)
              if (cm.id.isNotEmpty && _seenMsgIds.contains(cm.id)) return;
              if (cm.id.isNotEmpty) _seenMsgIds.add(cm.id);
              setState(() => _messages.add(cm));
              _scrollDown();
              unawaited(_cacheMessages());
              unawaited(_syncReadState());
              // Local push notification for inbound
              if (cm.role != _role) {
                final who = _role == 'buyer'
                    ? (_listing?.sellerName ?? 'Seller')
                    : 'Buyer';
                NotificationService.instance.showNewMessage(
                  fromName: who,
                  preview: cm.content.isNotEmpty ? cm.content : '[${cm.msgType}]',
                  threadKey: 'thread_${listing.id}',
                );
              }
            }
          } catch (_) {}
        },
        onError: (_) {
          if (mounted) setState(() => _wsConnected = false);
        },
        onDone: () {
          if (mounted) setState(() => _wsConnected = false);
        },
      );
    } catch (_) {
      _wsConnected = false;
    }
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
      setState(() {
        _messages = cached.map(ChatMessage.fromJson).toList();
        _loading = false;
      });
      _markSeen(_messages);
      _scrollDown();
    } catch (_) {}
  }

  Future<void> _cacheMessages() => LocalChatStore.save(
      _threadScopeKey(), _messages.map((m) => m.toJson()).toList());

  /// Tells the backend I've now seen everything in this thread, and
  /// refreshes when the counterpart last read it (drives the seen-ticks
  /// on my own sent messages). Called whenever I load/receive messages
  /// while this screen is open, plus periodically via _presenceRefreshTimer
  /// so my ticks still update even when nothing new has arrived.
  Future<void> _syncReadState() async {
    if (_listing == null) return;
    unawaited(ApiService.markThreadRead(_listing!.id, buyerId: _buyerId));
    final status = await ApiService.getReadStatus(_listing!.id, buyerId: _buyerId);
    if (!mounted) return;
    final other = _role == 'buyer' ? 'seller' : 'buyer';
    setState(() {
      _counterpartLastRead      = status['${other}_last_read'];
      _counterpartLastDelivered = status['${other}_last_delivered'];
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
      if (mounted) setState(() {
        _messages = directOnly.map(ChatMessage.fromMessage).toList();
        _loading = false;
      });
      _seenMsgIds.clear();
      _markSeen(_messages);
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
    try {
      final history = await ApiService.getNegotiationHistory(
        _listing!.id,
        buyerId: _role == 'seller' ? _buyerId : null,
      );
      if (!mounted) return;
      final directOnly = history.where((m) => (m.role == 'buyer' || m.role == 'seller') && !m.viaAi).toList();
      final fresh = directOnly
          .map(ChatMessage.fromMessage)
          .where((m) => m.id.isNotEmpty && !_seenMsgIds.contains(m.id))
          .toList();
      if (fresh.isEmpty) return;
      _markSeen(fresh);
      setState(() => _messages.addAll(fresh));
      _scrollDown();
      unawaited(_cacheMessages());
      unawaited(_syncReadState());
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
        final callerName = callInfo['caller_name'] as String? ?? 'Buyer';
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
              if (roomId != null) {
                NotificationService.instance.cancelIncomingCall(roomId);
              }
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
                    if (roomId != null) {
                      NotificationService.instance.cancelIncomingCall(roomId);
                    }
                    if (buyerIdForThread.isNotEmpty && _listing?.id != null && roomId != null) {
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
                    NotificationService.instance.cancelIncomingCall(roomId!);
                    Navigator.pushNamed(context, '/voip-call', arguments: {
                      'roomId': roomId, 'userId': ApiService.currentUserId ?? '',
                      'callToken': callToken,
                      'isCaller': false, 'peerName': callerName,
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

  // ── Sending text ───────────────────────────────────────────────────────────

  Future<void> _send() async {
    final text = _msgCtrl.text.trim();
    if (text.isEmpty || _sending) return;
    final optimistic = ChatMessage(role: _role, content: text, msgType: 'text');
    final optimisticIndex = _messages.length;
    setState(() { _messages.add(optimistic); _sending = true; });
    _msgCtrl.clear();
    _scrollDown();

    try {
      await ApiService.sendDirectMessage(
        listingId:  _listing!.id,
        senderRole: _role,
        senderId:   ApiService.currentUserId ?? 'anon',
        content:    text,
        buyerId:    _buyerId,
      );
    } catch (_) {}

    await _reconcileAfterSend(optimisticIndex, text);
    if (mounted) setState(() => _sending = false);
  }

  /// Swaps the id-less optimistic bubble for the real, server-confirmed
  /// copy of the same message (proper id + timestamp), and records every
  /// id seen along the way. Without this, the optimistic bubble stayed in
  /// _messages forever with no id, so the next poll or WS delivery had no
  /// way to recognise "I already have this one" and appended it again -
  /// that mismatch was the direct-chat "message sent twice" bug.
  Future<void> _reconcileAfterSend(int optimisticIndex, String text) async {
    try {
      final history = await ApiService.getNegotiationHistory(
        _listing!.id, buyerId: _role == 'seller' ? _buyerId : null);
      final directOnly = history
          .where((m) => (m.role == 'buyer' || m.role == 'seller') && !m.viaAi)
          .toList();
      final all = directOnly.map(ChatMessage.fromMessage).toList();
      _markSeen(all);
      // Newest matching message = the one I just sent (searching from the
      // end so an earlier message with identical text isn't picked).
      for (var i = all.length - 1; i >= 0; i--) {
        final m = all[i];
        if (m.role == _role && m.content == text) {
          if (mounted && optimisticIndex < _messages.length) {
            setState(() => _messages[optimisticIndex] = m);
          }
          break;
        }
      }
    } catch (_) {
      // Offline or request failed - the optimistic bubble stays as-is;
      // the next successful poll/WS delivery or _loadHistory will
      // reconcile it then.
    }
  }

  // ── Voice notes ────────────────────────────────────────────────────────────

  Future<void> _startRecording() async {
    final ok = await _recorder.hasPermission();
    if (!ok) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Microphone permission required')));
      return;
    }
    final dir  = await getTemporaryDirectory();
    final path = '${dir.path}/broka_voice_${DateTime.now().millisecondsSinceEpoch}.m4a';
    await _recorder.start(const RecordConfig(encoder: AudioEncoder.aacLc), path: path);
    setState(() { _isRecording = true; _recordPath = path; _recordStart = DateTime.now(); });
  }

  Future<void> _stopAndSendVoice() async {
    if (!_isRecording) return;
    final path = await _recorder.stop();
    setState(() => _isRecording = false);
    if (path == null) return;

    final duration = _recordStart != null
        ? DateTime.now().difference(_recordStart!).inSeconds
        : 0;

    // Add optimistic bubble
    final optimistic = ChatMessage(
      role: _role, msgType: 'voice',
      mediaUrl: 'file://$path',
      durationSecs: duration,
    );
    setState(() => _messages.add(optimistic));
    _scrollDown();

    // Upload
    try {
      final bytes = await File(path).readAsBytes();
      await ApiService.uploadMedia(
        listingId:    _listing!.id,
        senderRole:   _role,
        senderId:     ApiService.currentUserId ?? 'anon',
        contentType:  'audio',
        fileBytes:    bytes,
        fileName:     'voice.m4a',
        mimeType:     'audio/mp4',
        buyerId:      _buyerId,
        durationSecs: duration,
      );
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not send voice note: $e')));
    }
  }

  Future<void> _cancelRecording() async {
    await _recorder.cancel();
    setState(() { _isRecording = false; _recordPath = null; _recordStart = null; });
  }

  // ── Image sharing ──────────────────────────────────────────────────────────

  Future<void> _pickAndSendImage(ImageSource source) async {
    try {
      final picked = await _picker.pickImage(source: source, imageQuality: 70);
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      final b64   = base64Encode(bytes);
      final dataUri = 'data:image/jpeg;base64,$b64';

      final optimistic = ChatMessage(role: _role, msgType: 'image', mediaUrl: dataUri);
      setState(() => _messages.add(optimistic));
      _scrollDown();

      await ApiService.uploadMedia(
        listingId:   _listing!.id,
        senderRole:  _role,
        senderId:    ApiService.currentUserId ?? 'anon',
        contentType: 'image',
        fileBytes:   bytes,
        fileName:    'image.jpg',
        mimeType:    'image/jpeg',
        buyerId:     _buyerId,
      );
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not send image: $e')));
    }
  }

  void _showImageSourceSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: BrokaColors.bgMid,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(height: 8),
        Container(width: 40, height: 4,
            decoration: BoxDecoration(color: BrokaColors.border,
                borderRadius: BorderRadius.circular(2))),
        const SizedBox(height: 16),
        ListTile(
          leading: Container(width: 40, height: 40,
              decoration: BoxDecoration(
                color: BrokaColors.gold.withOpacity(0.12),
                borderRadius: BorderRadius.circular(10)),
              child: const Icon(Icons.camera_alt_rounded,
                  color: BrokaColors.gold, size: 20)),
          title: const Text('Take Photo', style: TextStyle(color: BrokaColors.textHigh)),
          onTap: () { Navigator.pop(context); _pickAndSendImage(ImageSource.camera); },
        ),
        ListTile(
          leading: Container(width: 40, height: 40,
              decoration: BoxDecoration(
                color: BrokaColors.neonBlue.withOpacity(0.15),
                borderRadius: BorderRadius.circular(10)),
              child: const Icon(Icons.photo_library_rounded,
                  color: BrokaColors.neonBlue, size: 20)),
          title: const Text('Choose from Gallery',
              style: TextStyle(color: BrokaColors.textHigh)),
          onTap: () { Navigator.pop(context); _pickAndSendImage(ImageSource.gallery); },
        ),
        const SizedBox(height: 12),
      ])),
    );
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
            'Start a secure ${isVideo ? 'video ' : ''}call with ${_role == "buyer" ? (listing.sellerName ?? "the seller") : "the buyer"}?',
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
        'peerName': _role == 'buyer' ? (listing.sellerName ?? 'Seller') : 'Buyer',
        'peerPhoto': _counterpartyPhoto,
        'peerOnline': _counterpartyOnline,
        'listingName': listing.name, 'isCaller': true,
        'listingId': listing.id, 'buyerId': buyerId, 'callerRole': _role,
        'callType': callType,
      });
    }
  }

  // ── M-Pesa deal ───────────────────────────────────────────────────────────

  Future<void> _finalizeDeal() async {
    final listing = _listing;
    if (listing == null) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: BrokaColors.bgMid,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: BrokaColors.neonBlue, width: 1)),
        title: const Text('Finalize Deal?',
            style: TextStyle(color: BrokaColors.textHigh, fontWeight: FontWeight.w800)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          Text('Listing: ${listing.name}',
              style: const TextStyle(color: BrokaColors.textMid)),
          const SizedBox(height: 8),
          Text('Price: ${listing.formattedPrice}',
              style: const TextStyle(color: BrokaColors.neonGreen, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          const Text('BROKA commission: 3%',
              style: TextStyle(color: BrokaColors.textLow, fontSize: 12)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel', style: TextStyle(color: BrokaColors.textLow))),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: BrokaColors.neonBlue, foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
            child: const Text('Confirm', style: TextStyle(fontWeight: FontWeight.w800))),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      final deal = await ApiService.finalizeDeal(
        listingId: listing.id,
        buyerId: ApiService.currentUserId ?? '',
        agreedPrice: listing.price,
      );
      if (mounted) setState(() => _dealInfo = deal);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not finalize deal: $e',
            style: const TextStyle(color: Colors.white)),
          backgroundColor: Colors.redAccent));
    }
  }

  /// 2026-09: pays through E-Confirm escrow instead of the old direct-
  /// Daraja STK push (which only ever escrowed BROKA's commission, not the
  /// goods price — see mpesa.py's stk-push). Fetches a real fee quote
  /// before showing any amount (Phase 5 of the integration: never guess
  /// this number client-side) and hands off to the provider-neutral
  /// econfirm_payment_screen.dart instead of mpesa_confirmation_screen.dart.
  /// No password field: the fund endpoint authorizes via the existing JWT
  /// (must already be this deal's buyer), matching Phase 7 of the spec.
  Future<void> _showPaymentDialog() async {
    final deal = _dealInfo;
    if (deal == null) return;
    final dealId = (deal['id'] ?? deal['deal_id']) as String?;
    if (dealId == null || dealId.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text("This deal couldn't be loaded properly. Try finalizing again."),
        ));
      }
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(
        child: CircularProgressIndicator(color: BrokaColors.neonGreen),
      ),
    );
    Map<String, dynamic> quote;
    try {
      quote = await ApiService.getEConfirmFeeQuote(dealId);
    } catch (e) {
      if (mounted) Navigator.pop(context); // close the loading spinner
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e.toString().replaceAll('Exception: ', '')),
        ));
      }
      return;
    }
    if (mounted) Navigator.pop(context); // close the loading spinner
    if (!mounted) return;

    final goodsAmount = (quote['goods_amount'] as num?)?.toDouble() ?? 0.0;
    final commission  = (quote['merchant_commission'] as num?)?.toDouble() ?? 0.0;
    final providerFee = (quote['provider_fee'] as num?)?.toDouble() ?? 0.0;
    final total       = (quote['total_to_pay'] as num?)?.toDouble()
        ?? (goodsAmount + commission + providerFee);

    final phoneCtrl = TextEditingController();
    bool paying = false;
    String? errorMsg;

    Widget quoteRow(String label, double amount, {bool emphasize = false}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(children: [
            Expanded(child: Text(label,
                style: TextStyle(
                    color: emphasize ? BrokaColors.textHigh : BrokaColors.textMid,
                    fontSize: emphasize ? 13 : 12,
                    fontWeight: emphasize ? FontWeight.w700 : FontWeight.normal))),
            Text('KES ${amount.toStringAsFixed(0)}',
                style: TextStyle(
                    color: emphasize ? BrokaColors.neonGreen : BrokaColors.textMid,
                    fontWeight: emphasize ? FontWeight.w800 : FontWeight.w600,
                    fontSize: emphasize ? 13 : 12)),
          ]),
        );

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDlg) {
        return AlertDialog(
          backgroundColor: BrokaColors.bgMid,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(color: BrokaColors.neonGreen, width: 1)),
          title: const Row(children: [
            Text('🔒', style: TextStyle(fontSize: 18)),
            SizedBox(width: 8),
            Text('Pay & Secure in Escrow', style: TextStyle(color: BrokaColors.textHigh,
                fontSize: 16, fontWeight: FontWeight.w800)),
          ]),
          content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: BrokaColors.bgCard,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: BrokaColors.border)),
              child: Column(children: [
                quoteRow('Item price', goodsAmount),
                quoteRow('BROKA commission', commission),
                quoteRow('Payment processing fee', providerFee),
                const Divider(color: BrokaColors.border, height: 16),
                quoteRow('Total to pay', total, emphasize: true),
              ]),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: phoneCtrl,
              keyboardType: TextInputType.phone,
              style: const TextStyle(color: BrokaColors.textHigh),
              decoration: const InputDecoration(
                labelText: 'M-Pesa Phone', hintText: '07XXXXXXXX',
                prefixIcon: Icon(Icons.phone_android_rounded,
                    color: BrokaColors.neonGreen, size: 20)),
            ),
            const SizedBox(height: 10),
            const Text(
              'Funds are held safely in escrow until you confirm delivery.',
              style: TextStyle(color: BrokaColors.textLow, fontSize: 11),
            ),
            if (errorMsg != null) ...[
              const SizedBox(height: 10),
              Text(errorMsg!, style: const TextStyle(color: Colors.redAccent, fontSize: 12)),
            ],
          ])),
          actions: [
            TextButton(onPressed: paying ? null : () => Navigator.pop(ctx),
                child: const Text('Cancel', style: TextStyle(color: BrokaColors.textLow))),
            ElevatedButton(
              onPressed: paying ? null : () async {
                final phone = phoneCtrl.text.trim();
                if (phone.isEmpty) { setDlg(() => errorMsg = 'Enter your phone number'); return; }
                setDlg(() { paying = true; errorMsg = null; });
                try {
                  final fundResult = await ApiService.fundDealEscrow(
                    dealId: dealId, payerPhone: phone);
                  final finalTotal = (fundResult['total_to_pay'] as num?)?.toDouble() ?? total;
                  if (mounted) {
                    Navigator.pop(ctx);
                    Navigator.pushNamed(context, '/escrow-payment', arguments: {
                      'deal_id': dealId,
                      'amount': finalTotal,
                      'phone': phone,
                      'listing_name': _listing?.name ?? '',
                    });
                  }
                } catch (e) {
                  setDlg(() { paying = false;
                    errorMsg = e.toString().replaceAll('Exception: ', ''); });
                }
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: BrokaColors.neonGreen, foregroundColor: Colors.black87,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
              child: paying
                  ? const SizedBox(width: 16, height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black87))
                  : const Text('Pay', style: TextStyle(fontWeight: FontWeight.w800)),
            ),
          ],
        );
      }),
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
    Navigator.pushReplacementNamed(context, '/negotiate',
        arguments: {'listing': _listing, 'role': _role});
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
    _recorder.cancel();
    _player.dispose();
    _ws?.sink.close();
    super.dispose();
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: BrokaColors.bg,
    // The constellation field from the splash screen, retuned so it sits
    // behind conversation content without fighting it - see
    // widgets/chat_ambient_background.dart. Intensity is held back here
    // (vs Zeno's own screen) because this thread carries photos, voice
    // notes and payment panels that need the background to stay out of
    // their way.
    body: ChatAmbientBackground(
      intensity: 0.85,
      child: Column(children: [
        _buildHeader(),
        if (_dealInfo != null) _buildPaymentPanel(),
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

  Widget _buildHeader() => SafeArea(
    bottom: false,
    child: Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: BrokaColors.bgMid.withOpacity(0.88),
        border: const Border(bottom: BorderSide(color: BrokaColors.border)),
      ),
      child: Row(children: [
        GestureDetector(
          onTap: () => Navigator.pop(context),
          child: Container(
            width: 36, height: 36,
            decoration: BoxDecoration(color: BrokaColors.bgCard,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: BrokaColors.border)),
            child: const Icon(Icons.arrow_back_ios_new_rounded,
                color: BrokaColors.textMid, size: 16),
          ),
        ),
        const SizedBox(width: 12),
        Stack(children: [
          Container(
            width: 38, height: 38,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(colors: [BrokaColors.gold, BrokaColors.goldDim])),
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
                border: Border.all(color: BrokaColors.bgMid, width: 2),
              ),
            )),
        ]),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(_role == 'buyer'
              ? (_listing?.sellerName ?? 'Seller')
              : 'Buyer',
              style: const TextStyle(color: BrokaColors.textHigh,
                  fontWeight: FontWeight.w700, fontSize: 15)),
          Text(
            _counterpartyLastSeen ?? (_counterpartyOnline ? 'Active now' : ''),
            style: TextStyle(
                color: _counterpartyOnline ? BrokaColors.neonGreen : BrokaColors.textMid,
                fontSize: 11, fontWeight: _counterpartyOnline ? FontWeight.w600 : FontWeight.w400),
            maxLines: 1, overflow: TextOverflow.ellipsis),
        ])),
        // WS indicator
        Container(
          width: 8, height: 8, margin: const EdgeInsets.only(right: 8),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _wsConnected ? BrokaColors.neonGreen : BrokaColors.textLow),
        ),
        // Audio call
        GestureDetector(
          onTap: () => _initiateCall('audio'),
          child: Container(
            width: 36, height: 36, margin: const EdgeInsets.only(right: 6),
            decoration: BoxDecoration(
              color: BrokaColors.neonGreen.withOpacity(0.12),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: BrokaColors.neonGreen.withOpacity(0.3))),
            child: const Icon(Icons.call_rounded, color: BrokaColors.neonGreen, size: 18),
          ),
        ),
        // Finalize - relocated from the deleted language row, where it was
        // the only control that actually did anything. It belongs with the
        // other thread-level actions, not stranded among dead chips.
        if (_role == 'buyer' && _dealInfo == null)
          GestureDetector(
            onTap: _finalizeDeal,
            child: Container(
              height: 36, margin: const EdgeInsets.only(right: 6),
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: BrokaColors.neonGreen.withOpacity(0.12),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: BrokaColors.neonGreen.withOpacity(0.35))),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.handshake_rounded, size: 15, color: BrokaColors.neonGreen),
                SizedBox(width: 5),
                Text('Deal', style: TextStyle(color: BrokaColors.neonGreen,
                    fontSize: 11, fontWeight: FontWeight.w700)),
              ]),
            ),
          ),
        // Video call
        GestureDetector(
          onTap: () => _initiateCall('video'),
          child: Container(
            width: 36, height: 36, margin: const EdgeInsets.only(right: 6),
            decoration: BoxDecoration(
              color: BrokaColors.neonBlue.withOpacity(0.12),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.3))),
            child: const Icon(Icons.videocam_rounded, color: BrokaColors.neonBlue, size: 18),
          ),
        ),
        // Zeno AI button
        GestureDetector(
          onTap: _openZenoAi,
          child: Stack(clipBehavior: Clip.none, children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: BrokaColors.gold.withOpacity(0.12),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: BrokaColors.gold.withOpacity(0.5))),
              child: const Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.auto_awesome_rounded, size: 14, color: BrokaColors.gold),
                SizedBox(width: 5),
                Text('AI', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700,
                    color: BrokaColors.gold)),
              ]),
            ),
            if (_zenoUnreadCount > 0)
              Positioned(right: -4, top: -4, child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: BrokaColors.danger,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: BrokaColors.bgMid, width: 1.5),
                ),
                child: Text('$_zenoUnreadCount',
                    style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w800)),
              )),
          ]),
        ),
      ]),
    ),
  );

  // ── Payment Panel ──────────────────────────────────────────────────────────

  Widget _buildPaymentPanel() {
    final deal = _dealInfo;
    if (deal == null) return const SizedBox();
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: BrokaColors.neonGreen.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: BrokaColors.neonGreen.withOpacity(0.4))),
      child: Row(children: [
        const Icon(Icons.check_circle_rounded, color: BrokaColors.neonGreen, size: 20),
        const SizedBox(width: 10),
        const Expanded(child: Text('Deal agreed! Pay commission to complete.',
            style: TextStyle(color: BrokaColors.neonGreen,
                fontSize: 12, fontWeight: FontWeight.w600))),
        GestureDetector(
          onTap: _showPaymentDialog,
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
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      itemCount: _messages.length,
      itemBuilder: (_, i) => _ChatBubble(
        message:    _messages[i],
        userRole:   _role,
        isPlaying:  _isPlaying && _playingUrl == _messages[i].mediaUrl,
        onPlayTap:  (url) => _togglePlay(url),
        onCallBack: _callBack,
        counterpartLastRead: _counterpartLastRead,
        counterpartLastDelivered: _counterpartLastDelivered,
      ),
    );
  }

  // ── Lang row ───────────────────────────────────────────────────────────────

  // ── Recording bar ──────────────────────────────────────────────────────────

  Widget _buildRecordingBar() => SafeArea(
    top: false,
    child: Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
      decoration: const BoxDecoration(
        color: BrokaColors.bgMid,
        border: Border(top: BorderSide(color: BrokaColors.border))),
      child: Row(children: [
        // Cancel
        GestureDetector(
          onTap: _cancelRecording,
          child: Container(
            width: 44, height: 44,
            decoration: BoxDecoration(
              color: BrokaColors.danger.withOpacity(0.15),
              shape: BoxShape.circle,
              border: Border.all(color: BrokaColors.danger.withOpacity(0.4))),
            child: const Icon(Icons.delete_rounded, color: BrokaColors.danger, size: 20)),
        ),
        const SizedBox(width: 12),
        Expanded(child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: BrokaColors.danger.withOpacity(0.08),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(color: BrokaColors.danger.withOpacity(0.3))),
          child: Row(children: [
            Container(width: 10, height: 10,
              decoration: const BoxDecoration(
                shape: BoxShape.circle, color: BrokaColors.danger)),
            const SizedBox(width: 10),
            const Text('Recording…',
                style: TextStyle(color: BrokaColors.danger, fontSize: 13,
                    fontWeight: FontWeight.w600)),
            const Spacer(),
            if (_recordStart != null)
              _RecordingTimer(start: _recordStart!),
          ]),
        )),
        const SizedBox(width: 12),
        // Send
        GestureDetector(
          onTap: _stopAndSendVoice,
          child: Container(
            width: 46, height: 46,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(colors: [BrokaColors.neonGreen, Color(0xFF059669)])),
            child: const Icon(Icons.send_rounded, color: Colors.white, size: 20)),
        ),
      ]),
    ),
  );

  // ── Input bar ──────────────────────────────────────────────────────────────

  Widget _buildInputBar() => SafeArea(
    top: false,
    child: Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      decoration: BoxDecoration(
        // Slight translucency so the constellation reads through the
        // composer instead of the bar looking like a lid clamped over it.
        color: BrokaColors.bgMid.withOpacity(0.92),
        border: const Border(top: BorderSide(color: BrokaColors.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          // ── The composer pill ───────────────────────────────────────────
          // REDESIGN: attachment and mic now live INSIDE the pill, which is
          // what every messaging app the user already knows does (WhatsApp,
          // Telegram, Gemini). Previously they were two large standalone
          // squares sitting to the left of the field, each with its own
          // tinted fill and border - three separate bordered boxes competing
          // in one row, which is what made the input read as casual and
          // unfinished rather than like a real chat composer.
          Expanded(
            child: Container(
              constraints: const BoxConstraints(minHeight: 46),
              decoration: BoxDecoration(
                color: BrokaColors.bgCard,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(
                  color: _composerFocused
                      ? BrokaColors.gold.withOpacity(0.55)
                      : BrokaColors.border,
                  width: _composerFocused ? 1.4 : 1,
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _ComposerAction(
                    icon: Icons.add_photo_alternate_outlined,
                    tooltip: 'Send a photo',
                    onTap: _showImageSourceSheet,
                  ),
                  Expanded(
                    child: TextField(
                      controller: _msgCtrl,
                      focusNode: _composerFocus,
                      style: const TextStyle(
                          color: BrokaColors.textHigh, fontSize: 15, height: 1.35),
                      // Room to compose a real paragraph - a marketplace
                      // negotiation is not a one-liner - while still
                      // scrolling rather than eating the conversation.
                      minLines: 1,
                      maxLines: 6,
                      textCapitalization: TextCapitalization.sentences,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      cursorColor: BrokaColors.gold,
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: _role == 'buyer' ? 'Message seller' : 'Message buyer',
                        hintStyle: const TextStyle(
                            color: BrokaColors.textLow, fontSize: 15),
                        border: InputBorder.none,
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 4, vertical: 13),
                      ),
                    ),
                  ),
                  // Mic sits inside the pill and disappears once there's
                  // text - at that point the send button is the only action
                  // that makes sense, and keeping a second one visible just
                  // asks the user to aim.
                  if (!_hasDraft)
                    _ComposerAction(
                      icon: Icons.mic_none_rounded,
                      tooltip: 'Record a voice note',
                      onTap: _startRecording,
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          // ── Send ────────────────────────────────────────────────────────
          // Scales in only when there is something to send. An always-on
          // send button next to an empty field is dead weight that trains
          // people to ignore it.
          AnimatedScale(
            scale: _hasDraft || _sending ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutBack,
            child: AnimatedOpacity(
              opacity: _hasDraft || _sending ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 140),
              child: GestureDetector(
                onTap: (_sending || !_hasDraft) ? null : _send,
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
                        blurRadius: 14,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                  child: _sending
                      ? const Center(
                          child: SizedBox(
                              width: 18,
                              height: 18,
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

// ── Composer action (icon inside the input pill) ─────────────────────────────

class _ComposerAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _ComposerAction({required this.icon, required this.tooltip, required this.onTap});

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: InkResponse(
      onTap: onTap,
      radius: 22,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 11, 8, 11),
        child: Icon(icon, size: 22, color: BrokaColors.textMid),
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
  final DateTime? counterpartLastRead;
  final DateTime? counterpartLastDelivered;

  const _ChatBubble({
    required this.message,
    required this.userRole,
    required this.isPlaying,
    required this.onPlayTap,
    required this.onCallBack,
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
    // (still sending); once it has one, "seen" is just a timestamp compare
    // against the counterpart's read watermark.
    Widget? seenTick() {
      if (!isMe) return null;
      // FIX (communications audit, 2026-09-14): this was a two-state tick
      // that showed a grey DOUBLE tick for anything the counterpart hadn't
      // read yet. A double tick means "it reached their device" in every
      // messenger anyone has used - claiming it before we had any delivery
      // signal at all was simply false, and it collapsed the two states
      // users most need to tell apart ("it never arrived" and "they
      // haven't looked") into one indistinguishable grey glyph.
      return MessageReceiptIcon(
        receipt: receiptFor(
          sentAt: message.createdAt,
          counterpartDeliveredAt: counterpartLastDelivered,
          counterpartReadAt: counterpartLastRead,
          viaAi: message.viaAi,
          pending: message.id.isEmpty,
        ),
      );
    }

    // Broker bubbles are centered
    if (isBroker) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(children: [
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            Container(
              width: 18, height: 18,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(colors: [BrokaColors.gold, BrokaColors.neonBlue])),
              child: const Icon(Icons.auto_awesome_rounded, color: Colors.white, size: 10)),
            const SizedBox(width: 5),
            const Text('ZENO', style: TextStyle(color: BrokaColors.gold, fontSize: 10,
                fontWeight: FontWeight.w800, letterSpacing: 1.0)),
          ]),
          const SizedBox(height: 6),
          Container(
            constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.88),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [
                BrokaColors.gold.withOpacity(0.10), BrokaColors.bgCard]),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: BrokaColors.gold.withOpacity(0.3))),
            child: Text(message.content, style: const TextStyle(
                color: BrokaColors.textHigh, fontSize: 14, height: 1.5)),
          ),
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
      bubbleContent = Container(
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.72),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isMe
              ? (message.role == 'buyer'
                  ? const Color(0xFF1565C0) : const Color(0xFF2E7D32))
              : BrokaColors.bgCard,
          borderRadius: BorderRadius.only(
            topLeft:     Radius.circular(isMe ? 14 : 4),
            topRight:    Radius.circular(isMe ? 4 : 14),
            bottomLeft:  const Radius.circular(14),
            bottomRight: const Radius.circular(14)),
          border: Border.all(color: roleColor().withOpacity(0.2))),
        child: Text(message.content,
            style: const TextStyle(color: BrokaColors.textHigh, fontSize: 14, height: 1.4)),
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
              Text('$label $callerLabel', style: TextStyle(
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
