// BROKA - Negotiation Screen
// Pure buyer ↔ seller direct chat with:
//   • WebSocket real-time message delivery
//   • Voice note recording & playback
//   • Photos (the camera, or up to ten from the gallery at once) and
//     documents (PDF, Office, text), each sent as its own message
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
import '../widgets/broka_image.dart';
import '../main.dart';
import '../services/api_service.dart';
import '../features/escrow/presentation/escrow_actions.dart';
import '../features/safe_payment/escrow_callout.dart';
import '../features/safe_payment/payments_shown.dart';
import '../features/safe_payment/safe_payment.dart' show openZenoEscrowGuide;
import '../features/calls/domain/call_record.dart' show callSummary;
import 'package:share_plus/share_plus.dart' show Share, XFile;
import '../services/chat_documents.dart';
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
import '../services/chat_media_vault.dart';
import '../services/counterparty_profile_cache.dart';
import '../services/zeno_voice_controller.dart';
import '../core/errors/user_facing_error.dart';
import '../utils/backend_time.dart';

// ── Message model extensions ──────────────────────────────────────────────────
// Extends the existing Message model with media fields.
class ChatMessage {
  final String  role;
  final String  content;
  final String  msgType;   // "text" | "voice" | "image" | "file" | "call"
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
  /// A shared document (msgType "file"): its name, size and type - what
  /// the bubble shows before the file itself is downloaded.
  final String? fileName;
  final int?    fileSize;
  final String? fileMime;

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
    this.fileName,
    this.fileSize,
    this.fileMime,
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
    fileName:     j['file_name'] as String?,
    fileSize:     (j['file_size'] as num?)?.toInt(),
    fileMime:     j['file_mime'] as String?,
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
    fileName:     m.fileName,
    fileSize:     m.fileSize,
    fileMime:     m.fileMime,
  );

  ChatMessage withFailed(bool value) => ChatMessage(
    role: role, content: content, msgType: msgType, mediaUrl: mediaUrl,
    durationSecs: durationSecs, callType: callType, viaAi: viaAi,
    isBroker: isBroker, createdAt: createdAt, clientId: clientId,
    failed: value, id: id, editedAt: editedAt, deleted: deleted,
    replyToMessageId: replyToMessageId, replyPreview: replyPreview,
    fileName: fileName, fileSize: fileSize, fileMime: fileMime,
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
    if (fileName != null) 'file_name': fileName,
    if (fileSize != null) 'file_size': fileSize,
    if (fileMime != null) 'file_mime': fileMime,
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
    if (msgType == 'file') {
      // The document's name: what the reply is about.
      final name = (preview['preview'] ?? preview['label'] ?? '').toString().trim();
      return name.isEmpty ? 'Document' : (name.length > 80 ? '${name.substring(0, 77)}…' : name);
    }
    final text = (preview['preview'] ?? preview['label'] ?? '').toString();
    if (text.isEmpty) return fallback;
    return text.length > 80 ? '${text.substring(0, 77)}…' : text;
  }
}

/// A voice note, photo or document still to be (re)sent, kept in memory so
/// "Try again" doesn't mean recording or picking it again.
class _PendingUpload {
  _PendingUpload({
    required this.bytes, required this.contentType, required this.fileName,
    required this.mimeType, this.durationSecs,
    this.replyToMessageId, this.replyPreview, this.caption,
    this.listingId, this.storeId, this.buyerId,
    this.progress = 0,
  });
  final Uint8List bytes;
  final String contentType; // "audio" | "image" | "file"
  final String fileName;
  final String mimeType;
  final int? durationSecs;
  final String? replyToMessageId;
  final Map<String, dynamic>? replyPreview;
  final String? caption;
  /// The conversation this upload belongs to. A retry must go back there,
  /// never to whichever chat happens to be open when the app restarts.
  final String? listingId;
  final String? storeId;
  final String? buyerId;
  /// 0..1 bytes handed to the socket. Mutable on purpose: progress ticks
  /// must not rebuild the message list's immutable snapshots.
  double progress;
}

typedef _OutboxEntry = ({
  String clientId,
  String path,
  String? replyToMessageId,
  String? caption,
  String? listingId,
  String? storeId,
  String? buyerId,
  // "image" | "file". Entries from builds before documents have no
  // content type: they are photos.
  String contentType,
  String? fileName,
  String? mimeType,
});

/// Durable outbox: one file per unsent photo or document under the app
/// documents directory, plus a tiny metadata sidecar. SharedPreferences only
/// ever holds the file path and caption - never the bytes, which would
/// bloat the JSON cache and duplicate large payloads on every save.
class _ChatMediaOutbox {
  static String? _docsPath;

  /// Resolve the outbox directory once, then keep it.
  ///
  /// The filesystem steps are synchronous on purpose: a chat opens and
  /// reads the outbox in the same frame, so awaiting exists()/create()
  /// here left a restored retry invisible until a later tick.
  static Future<Directory> _dir() async {
    final docsPath =
        _docsPath ?? (await getApplicationDocumentsDirectory()).path;
    _docsPath = docsPath;
    final dir = Directory('$docsPath/chat_outbox');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  static String _safeId(String clientId) =>
      clientId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

  static String _safeExt(String ext) {
    final e = ext.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    return e.isEmpty || e == 'json' ? 'bin' : (e.length > 8 ? e.substring(0, 8) : e);
  }

  static Future<({String path, String localUri})?> storeImage(
      String clientId, Uint8List bytes, {String ext = 'jpg'}) =>
      _store(clientId, bytes, ext == 'png' ? 'png' : 'jpg');

  /// A document, under its own extension (the sidecar keeps its name).
  static Future<({String path, String localUri})?> storeDocument(
      String clientId, Uint8List bytes, {required String ext}) =>
      _store(clientId, bytes, _safeExt(ext));

  static Future<({String path, String localUri})?> _store(
      String clientId, Uint8List bytes, String ext) async {
    try {
      final dir = await _dir();
      final id = _safeId(clientId);
      final path = '${dir.path}/$id.$ext';
      await File(path).writeAsBytes(bytes, flush: true);
      return (path: path, localUri: 'file://$path');
    } catch (_) {
      return null;
    }
  }

  static Future<void> writeMeta(String clientId,
      {String? replyToMessageId, String? caption,
      String? listingId, String? storeId, String? buyerId,
      String contentType = 'image', String? fileName, String? mimeType}) async {
    try {
      final dir = await _dir();
      await File('${dir.path}/${_safeId(clientId)}.json').writeAsString(jsonEncode({
        'reply_to_message_id': replyToMessageId,
        'caption': caption,
        'listing_id': listingId,
        'store_id': storeId,
        'buyer_id': buyerId,
        'content_type': contentType,
        'file_name': fileName,
        'mime_type': mimeType,
      }));
    } catch (_) {}
  }

  /// Every staged file of [clientId] - its picture or document - not the
  /// sidecar.
  static List<File> _stagedIn(Directory dir, String clientId) {
    final prefix = '${_safeId(clientId)}.';
    if (!dir.existsSync()) return const [];
    final out = <File>[];
    for (final e in dir.listSync()) {
      if (e is! File) continue;
      final base = e.path.split('/').last;
      if (base.startsWith(prefix) && !base.endsWith('.json')) out.add(e);
    }
    return out;
  }

  static Future<void> remove(String clientId) async {
    try {
      final dir = await _dir();
      for (final f in _stagedIn(dir, clientId)) {
        await f.delete();
      }
      final meta = File('${dir.path}/${_safeId(clientId)}.json');
      if (await meta.exists()) await meta.delete();
    } catch (_) {}
  }

  static Future<String?> pathFor(String clientId) async {
    try {
      final staged = _stagedIn(await _dir(), clientId);
      return staged.isEmpty ? null : staged.first.path;
    } catch (_) {
      return null;
    }
  }

  /// The staged file for [clientId], moved into the vault. Used on confirm:
  /// the outbox copy is deleted right after, so without this the sent photo
  /// would have no on-device bytes left for offline opens.
  static Future<File?> takeStaged(String clientId) async {
    try {
      final path = await pathFor(clientId);
      return path == null ? null : File(path);
    } catch (_) {
      return null;
    }
  }

  static Future<List<_OutboxEntry>> list() async {
    try {
      return _listIn(await _dir());
    } catch (_) {
      return [];
    }
  }

  /// The same entries as [list], synchronously. A tap on a failed bubble
  /// cannot wait for the documents directory: this is what lets the retry
  /// sheet decide, in that frame, whether the staged file belongs here.
  static List<_OutboxEntry> listSync() {
    final docsPath = _docsPath;
    if (docsPath == null) return const [];
    return _listIn(Directory('$docsPath/chat_outbox'));
  }

  static List<_OutboxEntry> _listIn(Directory dir) {
    if (!dir.existsSync()) return const [];
    final out = <_OutboxEntry>[];
    for (final e in dir.listSync()) {
      if (e is! File) continue;
      final base = e.path.split('/').last;
      final dot = base.lastIndexOf('.');
      if (dot <= 0) continue;
      final ext = base.substring(dot + 1);
      if (ext == 'json') continue;
      final id = base.substring(0, dot);
      String? replyTo;
      String? caption;
      String? listingId;
      String? storeId;
      String? buyerId;
      String contentType = 'image';
      String? fileName;
      String? mimeType;
      try {
        final meta = File('${dir.path}/$id.json');
        if (meta.existsSync()) {
          final m = jsonDecode(meta.readAsStringSync()) as Map;
          replyTo = m['reply_to_message_id'] as String?;
          caption = m['caption'] as String?;
          listingId = m['listing_id'] as String?;
          storeId = m['store_id'] as String?;
          buyerId = m['buyer_id'] as String?;
          contentType = (m['content_type'] as String?) ?? 'image';
          fileName = m['file_name'] as String?;
          mimeType = m['mime_type'] as String?;
        }
      } catch (_) {}
      // A file this build doesn't know how to send is left alone.
      if (contentType == 'image' && ext != 'jpg' && ext != 'png') continue;
      out.add((
        clientId: id,
        path: e.path,
        replyToMessageId: replyTo,
        caption: caption,
        listingId: listingId,
        storeId: storeId,
        buyerId: buyerId,
        contentType: contentType,
        fileName: fileName,
        mimeType: mimeType,
      ));
    }
    return out;
  }
}

/// What the composer's "+" can attach.
enum _Attach { camera, photos, document }

/// Shrink a picked photo for sending: longest side 1600px, JPEG quality
/// 85 (PNG when the source has transparency). A 12MP camera photo is ~4MB;
/// sending it raw would stall the thread on a slow connection and bloat
/// the server's data-URI store for no visible gain. Decoding failures
/// fall back to the raw bytes - a photo never fails to send because the
/// shrinker couldn't read it. Top-level so it can run on another isolate
/// (compute) - ten of these in a row on the UI thread froze the chat.
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

// ── Screen ────────────────────────────────────────────────────────────────────

/// How a voice note is recorded: AAC, one channel, 22.05 kHz, 32 kbit/s -
/// clear speech at about 240 KB a minute. The record package's defaults
/// (stereo, 44.1 kHz, 128 kbit/s) made every minute of talking nearly a
/// megabyte to send, and the same again for the other side to play.
const voiceNoteConfig = RecordConfig(
  encoder: AudioEncoder.aacLc,
  bitRate: 32000,
  sampleRate: 22050,
  numChannels: 1,
);

/// 4-second ticks between two of the direct chat's fallback polls (while
/// its socket is down), after [quietPolls] polls in a row found nothing
/// new: 4, 8, 16, then 32 seconds.
int directChatPollTicksBetween(int quietPolls) {
  if (quietPolls < 3) return 1;
  if (quietPolls < 6) return 2;
  if (quietPolls < 9) return 4;
  return 8;
}

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
  // A store-general conversation has no listing. It shares every part of
  // this screen with listing chats, but its server thread is keyed by
  // (store_id, buyer_id) so archived products cannot take it away.
  String?           _storeId;
  String            _storeName = '';
  String?           _storeLogo;
  String?           _storeOwnerId;
  String?           _passedCounterpartName;
  String?           _threadArgError;
  bool              _routeArgsRead = false;
  List<ChatMessage> _messages = [];
  bool              _loading  = true;
  String            _role     = 'buyer';
  String?           _buyerId; // the buyer in this thread (may differ from current user when seller views)

  bool get _isStoreThread => _storeId != null && _storeId!.isNotEmpty;
  bool get _hasThread => _isStoreThread || _listing != null;
  /// The canonical conversation id. The server's push tags use the same
  /// `store:<id>` form, so app notifications replace server ones instead of
  /// stacking a second copy.
  String? get _threadId => _isStoreThread ? 'store:$_storeId' : _listing?.id;

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
  // Client ids of sends queued or on their way. Ten photos go one after
  // another, and the last waits minutes on a slow connection: by the age
  // rule alone (receiptFor's 20 seconds) it read "Not sent" while it
  // waited its turn, and tapping it queued the same photo a second time.
  final Set<String> _inFlight = {};
  // Documents being downloaded to open, by message (or client) id.
  final Set<String> _downloading = {};
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
  // Watermarks live in memory AND in LocalChatStore (per thread scope):
  // without the on-device copy, a restart or an offline open forgot every
  // seen/delivered state and showed plain "Sent" for all of them.
  bool _receiptsRestored = false;

  /// Last known watermarks, before the cached messages render - so the
  /// first offline frame already shows the honest ticks, not "Sent".
  /// Idempotent per thread scope; safe to call from every load path.
  Future<void> _restoreReceiptWatermarks() async {
    if (_receiptsRestored || !_hasThread) return;
    _receiptsRestored = true;
    final saved = await LocalChatStore.loadReceipts(_threadScopeKey());
    if (!mounted) return;
    if (saved.read == null && saved.delivered == null) return;
    setState(() {
      _counterpartLastRead = _later(_counterpartLastRead, saved.read);
      _counterpartLastDelivered =
          _later(_counterpartLastDelivered, saved.delivered);
    });
  }

  /// Remember the watermarks on the phone. Forward-only like the in-memory
  /// merge: only ever called with the max-known pair.
  void _persistReceipts() {
    unawaited(LocalChatStore.saveReceipts(_threadScopeKey(),
        read: _counterpartLastRead, delivered: _counterpartLastDelivered));
  }

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
    // No presence heartbeat of its own any more: the app sends one every
    // 60 seconds while it is in front, whatever the screen (main.dart), and
    // this one doubled it for as long as a chat was open - and kept going
    // with the app in the background, so "online" never froze when the
    // user left.
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_routeArgsRead) {
      _routeArgsRead = true;
      final args = ModalRoute.of(context)?.settings.arguments;
      if (args is Map) {
        String? clean(Object? value) {
          final trimmed = value is String ? value.trim() : '';
          return trimmed.isEmpty ? null : trimmed;
        }

        final storeId = clean(args['storeId']) ?? clean(args['store_id']);
        final la = args['listing'];
        final passedListing = la is Listing
            ? la
            : la is Map
                ? Listing.fromJson(Map<String, dynamic>.from(la))
                : null;
        final listingId = clean(args['listingId']) ??
            (la is String ? clean(la) : null);
        // The backend accepts exactly one thread identity. Reject a route
        // carrying both here too; silently preferring the store used to
        // leave the product id in the screen arguments where a call or a
        // restored route could send the wrong identity.
        if (storeId != null && (passedListing != null || listingId != null)) {
          _threadArgError = 'This chat opens both a store and a product.';
          return;
        }

        _storeId = storeId;
        _listing = passedListing;
        if (_storeId != null && _storeId!.isNotEmpty) {
          _storeName = (args['storeName'] as String?)?.trim() ?? '';
          _storeLogo = args['storeLogo'] as String?;
          _storeOwnerId = (args['seller_id'] as String?) ??
              (args['counterpartId'] as String?);
          _passedCounterpartName = args['counterpartName'] as String?;
        }
        final passedRole = args['role'] as String?;
        _role = passedRole ?? _detectRole();
        // buyer_id passed from inbox screen (identifies the thread for sellers)
        _buyerId = args['buyer_id'] as String?;
        // If buyer, the buyer_id is always the current user
        if (_role == 'buyer') _buyerId = ApiService.currentUserId;
        final dealArg = args['deal'] as Map<String, dynamic>?;
        if (dealArg != null) _dealInfo = dealArg;

        if (!_hasThread && listingId != null) {
          // Restored from a relaunch - only the ID was persisted.
          _role = passedRole ?? args['role'] as String? ?? 'buyer';
          _restoreFromListingId(listingId);
          return;
        }
      } else if (args is Listing) {
        _listing = args;
        _role = _detectRole();
        _buyerId = _role == 'buyer' ? ApiService.currentUserId : null;
      }
      if (_hasThread) {
        if (_isStoreThread) {
          LastScreenTracker.save('/direct-chat', {
            'storeId': _storeId,
            'storeName': _storeName,
            'role': _role,
            'buyer_id': _buyerId,
          });
          GlobalPollerService.instance
              .markStoreScreenActive(_storeId!, buyerId: _buyerId);
        } else {
          LastScreenTracker.save('/direct-chat',
              {'listingId': _listing!.id, 'role': _role, 'buyer_id': _buyerId});
          GlobalPollerService.instance
              .markScreenActive(_listing!.id, buyerId: _buyerId);
        }
        _startThread();
      }
    }
  }

  /// Everything that runs once the screen knows its listing and thread.
  void _startThread() {
    // The Inbox opens this thread here next time, not in Zeno's room
    // (ChatScreenMemory).
    if (!_isStoreThread) {
      unawaited(ChatScreenMemory.remember(_listing!.id, _buyerId, ChatScreen.direct));
    }
    // A new thread scope: drop the previous thread's bubble keys so a stale
    // key can never reveal the wrong bubble.
    _bubbleKeys.clear();
    _receiptsRestored = false;
    // So a document bubble can tell, as it is drawn, whether the file is
    // already on this phone (ChatDocuments.fileForSync).
    unawaited(ChatDocuments.warm().then((_) {
      if (mounted) setState(() {});
    }));
    _loadCachedMessages();
    unawaited(_restoreMediaOutbox());
    _loadHistory();
    _connectWebSocket();
    _loadCounterpartyInfo();
    _refreshZenoUnreadCount();
    // Nothing on screen to keep current while the app is in the background:
    // the poller and pushes own that time, and resuming refreshes it all
    // (didChangeAppLifecycleState). These used to carry on behind the
    // user's back for as long as the chat stayed open.
    _presenceRefreshTimer = Timer.periodic(
        const Duration(seconds: 30), (_) {
      if (!_appVisible) return;
      _refreshCounterpartyPresence();
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
    //
    // A conversation that stays quiet is asked about less and less often
    // (directChatPollTicksBetween): every 4 seconds while it is moving, out
    // to every 32 once nothing has changed for a while - a socket that can't connect
    // (no such thread any more, a network that blocks WebSockets) used to
    // mean the whole thread every 4 seconds for as long as the chat was
    // open. Each answer is conditional too: an unchanged thread is an empty
    // 304.
    _pollTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!_hasThread || !mounted || !_appVisible) return;
      if (_wsConnected) return;
      if (++_pollWait < directChatPollTicksBetween(_quietPolls)) return;
      _pollWait = 0;
      _pollNewMessages();
      // Receipts too: without the socket, nothing else brings them.
      if (++_pollTicks % 3 == 0) _refreshReceipts();
    });
  }

  // Fallback-poll pace (see _startThread).
  int _quietPolls = 0;
  int _pollWait = 0;

  /// Something moved in the conversation (a message either way, the app
  /// back in front): poll at full speed again.
  void _pollNow() {
    _quietPolls = 0;
    _pollWait = 0;
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
    if (!visible || !_hasThread) return;
    // Back on screen: what arrived meanwhile has now been seen, and the
    // socket the OS may have closed in the background is reopened.
    if (!_wsConnected) {
      _wsReconnectAttempt = 0;
      _connectWebSocket();
    }
    _pollNow();
    unawaited(_pollNewMessages());
    unawaited(_syncReadState());
    // Presence was not refreshed while away.
    unawaited(_refreshCounterpartyPresence());
  }

  Timer? _presenceRefreshTimer;
  Map<String, dynamic>? _counterpartyInfo;
  /// Whose full profile [_counterpartyInfo] was last fetched from the
  /// server (not the on-device copy): until then the 30-second refresh
  /// fetches it whole, after that only their presence.
  String? _counterpartyProfileFor;
  /// Zeno's messages to this user that they haven't seen in its room - the
  /// badge on the Zeno button. From the server (the Inbox's `zeno_unread`):
  /// it used to be every Zeno message on the thread less a count saved only
  /// when that button was tapped, so Zeno's room read from the Inbox kept
  /// its whole history as "unread".
  int _zenoUnreadCount = 0;

  Future<void> _refreshZenoUnreadCount() async {
    if (_isStoreThread) return;
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
    if (!_hasThread) return;
    var counterpartyId = _counterpartyId;
    if (counterpartyId == null && _isStoreThread) {
      // Storefront and deep-link routes carry the store, not its owner.
      // The public store payload cannot supply the id, so ask the signed-in
      // thread endpoint the backend already uses to resolve its participants.
      try {
        final thread = await ApiService.getStoreThreadInfo(
            _storeId!, buyerId: _role == 'seller' ? _buyerId : null);
        counterpartyId = thread['counterpart_id'] as String?;
        if (mounted) {
          final threadStoreName = (thread['store_name'] as String?)?.trim() ?? '';
          setState(() {
            if (counterpartyId != null && counterpartyId.isNotEmpty) {
              if (_role == 'buyer') {
                _storeOwnerId = counterpartyId;
              } else {
                _buyerId ??= counterpartyId;
              }
            }
            if (_storeName.trim().isEmpty && threadStoreName.isNotEmpty) {
              _storeName = threadStoreName;
            }
          });
        }
      } catch (_) {
        // Older backend or offline: the conversation still works, it just
        // cannot show fresh owner presence.
      }
    }
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
      _counterpartyProfileFor = counterpartyId;
      setState(() => _counterpartyInfo = info);
      unawaited(CounterpartyProfileCache.save(ApiService.currentUserId,
          CounterpartyProfile.fromLive(counterpartyId, info)));
    } catch (_) {
      // Offline or failed: keep the cached identity rather than falling
      // back to a generic "Buyer"/"Seller" label.
    }
  }

  /// The 30-second refresh of the header's "online" / "last seen" line:
  /// just those fields, merged into the profile already shown. The whole
  /// profile is fetched only when there is none yet, or when the server
  /// has no presence route (older backends).
  Future<void> _refreshCounterpartyPresence() async {
    if (!_hasThread) return;
    final counterpartyId = _counterpartyId;
    if (counterpartyId == null || _counterpartyProfileFor != counterpartyId) {
      await _loadCounterpartyInfo();
      return;
    }
    final presence = await ApiService.getUserPresence(counterpartyId);
    if (!mounted) return;
    if (presence == null) {
      await _loadCounterpartyInfo();
      return;
    }
    // The answer is for whoever this chat shows now, not a thread since
    // left (a seller switching buyers).
    if (presence['id'] != null && presence['id'] != counterpartyId) return;
    if (_counterpartyId != counterpartyId) return;
    setState(() => _counterpartyInfo = {
          ...?_counterpartyInfo,
          for (final key in const ['is_online', 'last_seen', 'last_seen_label'])
            if (presence.containsKey(key)) key: presence[key],
        });
  }

  bool get _counterpartyOnline => (_counterpartyInfo?['is_online'] as bool?) ?? false;
  /// The other person in the thread - the seller, or for a seller the
  /// buyer they opened.
  String? get _counterpartyId => _isStoreThread
      ? (_role == 'buyer' ? _storeOwnerId : _buyerId)
      : (_role == 'buyer' ? _listing?.sellerId : _buyerId);
  /// Their name. A seller saw "Buyer" here, on the call screen and in the
  /// call prompt - never the buyer's name, although the profile this chat
  /// loads for their photo and presence carries it. A buyer sees the name
  /// the listing gives its seller (a business's name, when it has one), as
  /// before.
  String get _counterpartyName {
    if (_isStoreThread && _role == 'buyer') {
      if (_storeName.trim().isNotEmpty) return _storeName.trim();
      final passed = _passedCounterpartName?.trim() ?? '';
      if (passed.isNotEmpty) return passed;
      return 'Store';
    }
    final profile = (_counterpartyInfo?['name'] as String?)?.trim() ?? '';
    if (!_isStoreThread && _role == 'buyer') {
      final listed = _listing?.sellerName?.trim() ?? '';
      if (listed.isNotEmpty) return listed;
      return profile.isNotEmpty ? profile : 'Seller';
    }
    final passed = _passedCounterpartName?.trim() ?? '';
    if (profile.isNotEmpty) return profile;
    return passed.isNotEmpty ? passed : 'Buyer';
  }
  String? get _counterpartyLastSeen => _counterpartyInfo?['last_seen_label'] as String?;
  // Already on the payload _loadCounterpartyInfo fetches - the screen just
  // never read it. Used by the call screen's avatar and the header below,
  // both of which were falling back to a single initial.
  String? get _counterpartyPhoto => _counterpartyInfo?['profile_photo'] as String?;

  /// A shop's own logo stands in for the owner's face in a buyer's store
  /// conversation; the seller still sees the buyer's profile photo.
  String? get _headerPhotoSource =>
      _isStoreThread && _role == 'buyer' ? _storeLogo : _counterpartyPhoto;

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
    final token   = ApiService.authToken;
    if (!_hasThread || token == null || !mounted) return;

    // Build WS URL: replace http(s) with ws(s)
    final base = ApiService.baseUrl
        .replaceFirst('https://', 'wss://')
        .replaceFirst('http://',  'ws://');

    var url = _isStoreThread
        ? '$base/media/ws/store/${_storeId}?token=$token'
        : '$base/media/ws/${_listing!.id}?token=$token';
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
    _persistReceipts();
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
      // An unsent photo's bytes die with the bubble - the vault must not
      // keep rendering a picture the thread agreed to forget.
      if (old.msgType == 'image') {
        unawaited(ChatMediaVault.remove(
            messageId: old.id.isEmpty ? null : old.id,
            clientId: old.clientId));
      } else if (old.msgType == 'file') {
        // A downloaded document too: the server deleted its copy.
        unawaited(ChatDocuments.remove(
            messageId: old.id.isEmpty ? null : old.id,
            clientId: old.clientId));
      }
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
        // An edited caption must not turn a document into a nameless one.
        fileName: old.fileName, fileSize: old.fileSize, fileMime: old.fileMime,
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
    final threadId = _threadId;
    if (_appVisible || threadId == null || cm.msgType == 'call') return;
    // The server pushes every message, and Android shows that push with the
    // app in any state - posting this one too would buzz twice.
    if (GlobalPollerService.instance.pushReady) return;
    final who = _counterpartyName;
    final preview = switch (cm.msgType) {
      'image' => '\u{1F4F7} Photo',
      'voice' => '\u{1F3A4} Voice message',
      'file' => '\u{1F4C4} ${(cm.fileName ?? '').trim().isEmpty ? 'Document' : cm.fileName!.trim()}',
      _ => cm.content,
    };
    NotificationService.instance.showNewMessage(
      fromName: who,
      preview: preview,
      // One notification per conversation, shared with GlobalPollerService
      // and the server's push (NotificationService.threadTag).
      listingId: threadId,
      buyerId: _buyerId,
      payload: {
        'type': 'new_message',
        if (!_isStoreThread) 'listingId': _listing?.id,
        if (_isStoreThread) 'storeId': _storeId,
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
  String _threadScopeKey() => 'direct_${_threadId ?? ''}_${_buyerId ?? ''}';

  String? get _threadBuyerId => _role == 'buyer'
      ? (_buyerId ?? ApiService.currentUserId)
      : _buyerId;

  /// Whether an upload's persisted identity is this exact conversation.
  /// Empty strings are null here so a missing legacy field cannot match a
  /// real thread by accident.
  bool _isCurrentThread({
    String? listingId,
    String? storeId,
    String? buyerId,
  }) =>
      (listingId ?? '') == (_listing?.id ?? '') &&
      (storeId ?? '') == (_storeId ?? '') &&
      (buyerId ?? '') == (_threadBuyerId ?? '');

  /// Show whatever was last cached on-device immediately, before the network
  /// call even starts - this is what makes the thread visible instantly even
  /// with no connection at all, the same way WhatsApp opens a chat straight
  /// into its history rather than a blank/loading screen.
  Future<void> _loadCachedMessages() async {
    if (!_hasThread) return;
    // Watermarks first: the cached bubbles render their ticks from these,
    // so the offline frame must not show "Sent" for already-seen messages.
    await _restoreReceiptWatermarks();
    if (!mounted || !_hasThread) return;
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

  /// Persist the thread for instant offline open. Photos are never kept as
  /// text here: [ChatMediaVault.cacheMediaUrl] materialises data URIs into
  /// the on-device vault and the cache keeps only the small file://
  /// reference, so the picture still renders with no connection.
  /// Previously a data URI over ~50KB was slimmed to an empty placeholder
  /// and the bubble opened offline as a broken-image icon.
  Future<void> _cacheMessages() async {
    final slimmed = <Map<String, dynamic>>[];
    for (final m in _messages) {
      final j = m.toJson();
      final url = j['media_url'] as String?;
      if (m.msgType == 'image' && url != null && url.isNotEmpty) {
        j['media_url'] = await ChatMediaVault.cacheMediaUrl(
            url: url,
            messageId: m.id.isEmpty ? null : m.id,
            clientId: m.clientId);
      } else if (url != null &&
          url.length > 50 * 1024 &&
          !url.startsWith('file://')) {
        j['media_url'] = '';
      }
      slimmed.add(j);
    }
    return LocalChatStore.save(_threadScopeKey(), slimmed);
  }

  /// Tells the backend this side has the thread - read if the chat is on
  /// screen, only delivered if the app is in the background - and refreshes
  /// the other side's watermarks (the ticks on my own messages). Called
  /// whenever I load/receive messages while this screen is open, plus every
  /// 30s via _presenceRefreshTimer.
  Future<void> _syncReadState() async {
    if (!_hasThread) return;
    if (_appVisible) {
      unawaited(ApiService.markThreadRead(_listing?.id,
          storeId: _storeId, buyerId: _buyerId));
    } else {
      unawaited(ApiService.markThreadDelivered(_listing?.id,
          storeId: _storeId, buyerId: _buyerId));
    }
    await _refreshReceipts();
  }

  /// The other side's watermarks, applied forward only. A failed request
  /// changes nothing: it used to come back as "never read", which turned
  /// every seen tick back to a single grey one until the next poll.
  Future<void> _refreshReceipts() async {
    if (!_hasThread) return;
    final status = await ApiService.getReadStatus(_listing?.id,
        storeId: _storeId, buyerId: _buyerId);
    if (status == null || !mounted) return;
    final other = _role == 'buyer' ? 'seller' : 'buyer';
    setState(() {
      _counterpartLastRead      = _later(_counterpartLastRead, status['${other}_last_read']);
      _counterpartLastDelivered = _later(_counterpartLastDelivered, status['${other}_last_delivered']);
    });
    _persistReceipts();
  }

  // ── Polling fallback ───────────────────────────────────────────────────────

  Future<void> _loadHistory() async {
    try {
      final history = await ApiService.getThreadHistory(
        listingId: _listing?.id,
        storeId: _storeId,
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
    if (!_hasThread) return;
    try {
      final history = await ApiService.getThreadHistory(
        listingId: _listing?.id,
        storeId: _storeId,
        buyerId: _role == 'seller' ? _buyerId : null,
        conditional: true,
      );
      if (!mounted) return;
      if (ApiService.lastHistoryNotModified) {
        // The thread is exactly as last fetched: nothing to merge.
        _quietPolls++;
        return;
      }
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
      if (!changed) {
        _quietPolls++;
        return;
      }
      _pollNow();
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

  /// [job] delivers the message [clientId]: queued behind the sends before
  /// it, and "Sending" - never "Not sent" - until it has run.
  void _enqueueDelivery(String clientId, Future<void> Function() job) {
    _inFlight.add(clientId);
    _enqueue(() async {
      try {
        await job();
      } finally {
        _inFlight.remove(clientId);
        if (mounted) setState(() {});
      }
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
    if (m.msgType == 'file') {
      // The document's name - the server's reply preview says the same.
      return {'message_id': m.id, 'sender_role': m.role, 'msg_type': 'file',
          'preview': (m.fileName ?? '').trim().isEmpty ? 'Document' : m.fileName!.trim(),
          'deleted': false};
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
    if (text.isEmpty || !_hasThread) return;
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
    // A reply is likely soon: the fallback poll (if the socket is down)
    // stops idling.
    _pollNow();
    _enqueueDelivery(clientId, () => _deliverText(clientId, text,
        replyToMessageId: reply?.id.isEmpty == true ? null : reply?.id));
  }

  Future<void> _deliverText(String clientId, String text, {String? replyToMessageId}) async {
    if (!_hasThread) return;
    try {
      final saved = await ApiService.sendDirectMessage(
        listingId:   _listing?.id,
        storeId:     _storeId,
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
    final upload = _uploads[clientId];
    if (!_hasThread || upload == null) return;
    if (!_isCurrentThread(
      listingId: upload.listingId,
      storeId: upload.storeId,
      buyerId: upload.buyerId,
    )) {
      _markFailed(clientId);
      _notSent('This message belongs to another conversation.');
      return;
    }
    try {
      final saved = await ApiService.uploadMedia(
        listingId:    upload.listingId ?? _listing?.id,
        storeId:      upload.storeId ?? _storeId,
        senderRole:   _role,
        senderId:     ApiService.currentUserId ?? 'anon',
        contentType:  upload.contentType,
        fileBytes:    upload.bytes,
        fileName:     upload.fileName,
        mimeType:     upload.mimeType,
        buyerId:      upload.buyerId ?? _threadBuyerId,
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
    var canResend = m.msgType == 'text' || _uploads.containsKey(clientId);
    if (!canResend && (m.msgType == 'image' || m.msgType == 'file')) {
      // A photo written by an earlier run is retryable as soon as its file
      // exists - waiting for [_restoreMediaOutbox] left a cold-opened bubble
      // with only Delete, although its bytes were still on disk. The entry's
      // own thread ids are checked too, so a photo staged for another
      // conversation is never offered for upload into this one.
      for (final entry in _ChatMediaOutbox.listSync()) {
        if (entry.clientId != clientId) continue;
        canResend = _isCurrentThread(
          listingId: entry.listingId,
          storeId: entry.storeId,
          buyerId: entry.buyerId,
        );
        break;
      }
    }
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
      if (m.msgType == 'image') {
        unawaited(_ChatMediaOutbox.remove(clientId));
        unawaited(ChatMediaVault.remove(clientId: clientId));
      } else if (m.msgType == 'file') {
        unawaited(_ChatMediaOutbox.remove(clientId));
        unawaited(ChatDocuments.remove(clientId: clientId));
      }
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
    // Already on its way (a flush and a tap at once): never twice.
    if (_inFlight.contains(clientId)) return;
    final upload = _uploads[clientId];
    if (upload != null) upload.progress = 0;
    setState(() => _messages[i] = _messages[i].withFailed(false));
    if (m.msgType == 'text') {
      _enqueueDelivery(clientId, () => _deliverText(clientId, m.content,
          replyToMessageId: m.replyToMessageId));
    } else if (m.msgType == 'image' || m.msgType == 'file') {
      _enqueueDelivery(clientId, () async {
        final path = await _ChatMediaOutbox.pathFor(clientId);
        if (path == null) {
          _markFailed(clientId);
          _notSent(m.msgType == 'file'
              ? 'The file is gone from this phone. Send it again.'
              : 'Photo file is gone. Send it again from the gallery.');
          return;
        }
        await _deliverOutboxUpload(clientId, path);
      });
    } else {
      _enqueueDelivery(clientId, () => _deliverUpload(clientId));
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
                    : m.msgType == 'file'
                        ? (m.fileName ?? 'Document')
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
    // The sender's own copy goes as well. The socket's delete broadcast
    // can't do it here: this bubble is already the tombstone when it lands.
    if (m.msgType == 'image') {
      unawaited(ChatMediaVault.remove(messageId: m.id, clientId: m.clientId));
    } else if (m.msgType == 'file') {
      unawaited(ChatDocuments.remove(messageId: m.id, clientId: m.clientId));
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
      await _recorder.start(voiceNoteConfig, path: path);
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
      listingId: _listing?.id, storeId: _storeId, buyerId: _threadBuyerId,
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
    _enqueueDelivery(clientId, () => _deliverUpload(clientId));
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

  // ── Photos and documents ───────────────────────────────────────────────────
  //
  // Chat-specific flow: pick, preview with an optional caption, then send.
  // Nothing uploads until Send is tapped - selecting is not sending. Up to
  // ten photos, or ten documents, go in one send (2026-11-09: the chat
  // could send one photo at a time and no documents at all); each is its
  // own message, uploaded one after another. The bytes live in the
  // app-owned media outbox (a real file, not SharedPreferences), so a
  // failed upload retries without re-picking, even after a restart.

  /// At most this many photos in one send.
  static const maxPhotosPerSend = 10;

  /// The composer's "+": a photo from the camera, photos from the gallery,
  /// or documents. This screen's own sheet - not PhotoCapture.askSource,
  /// which other screens share. Bigger targets, explicit labels.
  Future<void> _showAttachSheet() async {
    final choice = await showModalBottomSheet<_Attach>(
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
            child: Text('Share in the chat',
                style: TextStyle(color: BrokaColors.textHigh,
                    fontWeight: FontWeight.w800, fontSize: 16)),
          ),
          _attachOption(sheet, _Attach.camera,
              Icons.photo_camera_rounded, 'Take a photo',
              'Use the camera to capture it now', BrokaColors.gold),
          _attachOption(sheet, _Attach.photos,
              Icons.photo_library_rounded, 'Choose photos',
              'Up to $maxPhotosPerSend from this phone, sent together', BrokaColors.neonBlue),
          _attachOption(sheet, _Attach.document,
              Icons.description_rounded, 'Send a document',
              'PDF, Word, Excel, PowerPoint, text or CSV', BrokaColors.neonPurple),
          const SizedBox(height: 12),
        ]),
      ),
    );
    if (!mounted || choice == null) return;
    switch (choice) {
      case _Attach.camera:
        await _takePhoto();
      case _Attach.photos:
        await _pickPhotos();
      case _Attach.document:
        await _pickDocuments();
    }
  }

  Widget _attachOption(BuildContext sheet, _Attach option, IconData icon,
      String title, String subtitle, Color color) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Material(
        color: BrokaColors.bgCard,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => Navigator.pop(sheet, option),
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

  Future<void> _takePhoto() async {
    try {
      final photo = await PhotoCapture.takePhoto(context,
          hint: 'Show it clearly, in good light - the other side sees exactly this.');
      if (photo == null || !mounted) return;
      await _showPhotosPreview([photo]);
    } catch (e) {
      _notSent('Could not open the camera. ${userFacingError(e)}');
    }
  }

  Future<void> _pickPhotos() async {
    try {
      final picked =
          await PhotoCapture.pickManyFromGallery(context, limit: maxPhotosPerSend);
      if (picked.isEmpty || !mounted) return;
      await _showPhotosPreview(picked);
    } catch (e) {
      _notSent('Could not open the gallery. ${userFacingError(e)}');
    }
  }

  /// Preview before sending: the photo in view large, all of them in a
  /// strip under it - tap one to look at it, its × takes it out, + adds
  /// more - and a caption, which goes with the first. Closing sends nothing:
  /// the bytes stay on the phone unsent.
  Future<void> _showPhotosPreview(List<File> initial) async {
    final captionCtrl = TextEditingController();
    final photos = List<File>.of(initial.take(maxPhotosPerSend));
    var current = 0;
    final send = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: BrokaColors.bgMid,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (sheet) => StatefulBuilder(builder: (ctx, setSheet) {
        if (photos.isEmpty) return const SizedBox.shrink();
        if (current >= photos.length) current = photos.length - 1;
        Future<void> addMore() async {
          final room = maxPhotosPerSend - photos.length;
          if (room <= 0) return;
          final more = await PhotoCapture.pickManyFromGallery(ctx, limit: room);
          if (more.isEmpty) return;
          setSheet(() {
            photos.addAll(more.take(room));
            current = photos.length - 1;
          });
        }
        void removeAt(int i) {
          if (photos.length == 1) {
            Navigator.pop(sheet, false);
            return;
          }
          setSheet(() {
            photos.removeAt(i);
            if (current >= photos.length) current = photos.length - 1;
          });
        }
        final many = photos.length > 1;
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
            // Scrolls on a short phone with the keyboard up, rather than
            // overflowing the sheet.
            child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
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
                    icon: const Icon(Icons.close_rounded, color: BrokaColors.textHigh),
                  ),
                  Expanded(child: Text(many ? '${photos.length} photos' : 'Preview',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: BrokaColors.textHigh,
                          fontWeight: FontWeight.w800, fontSize: 16))),
                  TextButton(
                    key: const Key('photos-send'),
                    onPressed: () => Navigator.pop(sheet, true),
                    child: Text(many ? 'Send ${photos.length}' : 'Send',
                        style: const TextStyle(color: BrokaColors.neonGreen,
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
                    constraints: const BoxConstraints(maxHeight: 300),
                    child: Image.file(photos[current], fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => Container(
                        height: 160, color: BrokaColors.bgCard,
                        alignment: Alignment.center,
                        child: const Icon(Icons.broken_image_outlined,
                            color: BrokaColors.textLow, size: 40))),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 68,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    for (var i = 0; i < photos.length; i++)
                      _PreviewThumb(
                        key: ValueKey('preview-thumb-$i'),
                        file: photos[i],
                        selected: i == current,
                        onTap: () => setSheet(() => current = i),
                        onRemove: () => removeAt(i),
                      ),
                    if (photos.length < maxPhotosPerSend)
                      Tooltip(
                        message: 'Add more photos',
                        child: InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: addMore,
                          child: Container(
                            width: 60, height: 60,
                            margin: const EdgeInsets.only(top: 4),
                            decoration: BoxDecoration(
                              color: BrokaColors.bgCard,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.5)),
                            ),
                            child: const Icon(Icons.add_photo_alternate_outlined,
                                color: BrokaColors.neonBlue),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: TextField(
                  controller: captionCtrl,
                  style: const TextStyle(color: BrokaColors.textHigh),
                  maxLines: 3,
                  minLines: 1,
                  maxLength: 1000,
                  decoration: InputDecoration(
                    hintText: many
                        ? 'Add a caption to the first photo (optional)'
                        : 'Add a caption (optional)',
                    hintStyle: const TextStyle(color: BrokaColors.textLow),
                    filled: true,
                    fillColor: BrokaColors.bgCard,
                    border: const OutlineInputBorder(
                      borderRadius: BorderRadius.all(Radius.circular(12)),
                      borderSide: BorderSide.none,
                    ),
                  ),
                ),
              ),
            ])),
          ),
        );
      }),
    );
    // Not disposed: the sheet's field still holds it while the sheet slides
    // away, after this returns. It holds nothing that needs freeing.
    final caption = captionCtrl.text.trim();
    if (send != true || !mounted || photos.isEmpty) return;
    for (var i = 0; i < photos.length; i++) {
      if (!mounted) return;
      await _stageImageUpload(photos[i], i == 0 && caption.isNotEmpty ? caption : null);
    }
  }

  /// Persist the photo to the app-owned outbox, render the optimistic bubble
  /// with an uploading state, then upload. Retries reuse the stored file -
  /// never the in-memory bytes - so they survive a restart.
  Future<void> _stageImageUpload(File picked, String? caption) async {
    try {
      final raw = await picked.readAsBytes();
      // Fitted off the UI thread when it is real work: ten photos decoded
      // and re-encoded in a row froze the chat for seconds.
      final fitted = raw.length > 256 * 1024
          ? await compute(_fitPhotoForUpload, raw)
          : _fitPhotoForUpload(raw);
      final clientId = _newClientId();
      final reply = _replyTo;
      final stored = await _ChatMediaOutbox.storeImage(
          clientId, fitted.bytes, ext: fitted.mimeType == 'image/png' ? 'png' : 'jpg');
      if (stored == null || !mounted) return;
      await _ChatMediaOutbox.writeMeta(clientId,
          replyToMessageId: reply?.id.isEmpty == true ? null : reply?.id,
          caption: caption, listingId: _listing?.id, storeId: _storeId,
          buyerId: _threadBuyerId, contentType: 'image',
          fileName: fitted.fileName, mimeType: fitted.mimeType);
      _uploads[clientId] = _PendingUpload(
        bytes: fitted.bytes,
        contentType: 'image',
        fileName: fitted.fileName,
        mimeType: fitted.mimeType,
        replyToMessageId: reply?.id.isEmpty == true ? null : reply?.id,
        replyPreview: reply == null ? null : _replySnapshotOf(reply),
        caption: caption,
        listingId: _listing?.id, storeId: _storeId, buyerId: _threadBuyerId,
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
      _enqueueDelivery(clientId, () => _deliverOutboxUpload(clientId, stored.path));
    } catch (e) {
      _notSent('Could not send image. ${userFacingError(e)}');
    }
  }

  /// Documents: Android's own picker, several at a time. What the chat
  /// can't carry is said here, by name, before anything uploads.
  Future<void> _pickDocuments() async {
    final picked = await ChatDocuments.pick();
    if (!mounted) return;
    if (picked == null) {
      _notSent("Documents can't be attached on this phone yet.");
      return;
    }
    if (picked.isEmpty) return;
    final ok = <PickedDocument>[];
    final refused = <String>[];
    for (final d in picked.take(ChatDocuments.maxPerSend)) {
      if (d.tooLarge) {
        refused.add('${d.name} is over ${ChatDocuments.maxBytes ~/ (1024 * 1024)} MB.');
      } else if (d.unreadable || d.path == null) {
        refused.add("${d.name} couldn't be read.");
      } else if (!ChatDocuments.accepts(d.name)) {
        refused.add("${d.name} can't be sent - only PDF, Word, Excel, "
            'PowerPoint, text and CSV files.');
      } else {
        ok.add(d);
      }
    }
    if (picked.length > ChatDocuments.maxPerSend) {
      refused.add('Only ${ChatDocuments.maxPerSend} go in one send.');
    }
    if (refused.isNotEmpty) _notSent(refused.join('\n'));
    if (ok.isEmpty) return;
    final caption = await _showDocumentsPreview(ok);
    if (caption == null || !mounted || ok.isEmpty) return;
    for (var i = 0; i < ok.length; i++) {
      if (!mounted) return;
      await _stageDocument(ok[i], i == 0 && caption.isNotEmpty ? caption : null);
    }
  }

  /// The documents about to go, each with its × to take it out, and one
  /// caption. Null when closed without sending; the caption ('' for none)
  /// when Send was tapped. [docs] is changed in place.
  Future<String?> _showDocumentsPreview(List<PickedDocument> docs) async {
    final captionCtrl = TextEditingController();
    final send = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: BrokaColors.bgMid,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (sheet) => StatefulBuilder(builder: (ctx, setSheet) {
        final many = docs.length > 1;
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
            // Scrolls on a short phone with the keyboard up, rather than
            // overflowing the sheet.
            child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
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
                    icon: const Icon(Icons.close_rounded, color: BrokaColors.textHigh),
                  ),
                  Expanded(child: Text(many ? '${docs.length} documents' : 'Send a document',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: BrokaColors.textHigh,
                          fontWeight: FontWeight.w800, fontSize: 16))),
                  TextButton(
                    key: const Key('documents-send'),
                    onPressed: () => Navigator.pop(sheet, true),
                    child: Text(many ? 'Send ${docs.length}' : 'Send',
                        style: const TextStyle(color: BrokaColors.neonGreen,
                            fontWeight: FontWeight.w800, fontSize: 15)),
                  ),
                ]),
              ),
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.4),
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  children: [
                    for (var i = 0; i < docs.length; i++)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _DocumentTile(
                          name: docs[i].name,
                          size: docs[i].size,
                          trailing: IconButton(
                            tooltip: 'Remove ${docs[i].name}',
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.close_rounded,
                                color: BrokaColors.textMid, size: 18),
                            onPressed: () {
                              if (docs.length == 1) {
                                Navigator.pop(sheet, false);
                                return;
                              }
                              setSheet(() => docs.removeAt(i));
                            },
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
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
            ])),
          ),
        );
      }),
    );
    // Not disposed - as in _showPhotosPreview.
    final caption = captionCtrl.text.trim();
    return send == true ? caption : null;
  }

  /// A document into the outbox, its bubble on screen at once, then the
  /// upload - the photo path's shape. The sender's own copy is kept, so
  /// opening what they sent never downloads it again.
  Future<void> _stageDocument(PickedDocument doc, String? caption) async {
    try {
      final picked = File(doc.path!);
      final bytes = await picked.readAsBytes();
      final clientId = _newClientId();
      final reply = _replyTo;
      final name = doc.name;
      final mime = ChatDocuments.mimeFor(name);
      final stored = await _ChatMediaOutbox.storeDocument(
          clientId, bytes, ext: ChatDocuments.extensionOf(name));
      if (stored == null || !mounted) return;
      await _ChatMediaOutbox.writeMeta(clientId,
          replyToMessageId: reply?.id.isEmpty == true ? null : reply?.id,
          caption: caption, listingId: _listing?.id, storeId: _storeId,
          buyerId: _threadBuyerId, contentType: 'file',
          fileName: name, mimeType: mime);
      await ChatDocuments.keepBytes(bytes, clientId: clientId, fileName: name);
      _uploads[clientId] = _PendingUpload(
        bytes: bytes,
        contentType: 'file',
        fileName: name,
        mimeType: mime,
        replyToMessageId: reply?.id.isEmpty == true ? null : reply?.id,
        replyPreview: reply == null ? null : _replySnapshotOf(reply),
        caption: caption,
        listingId: _listing?.id, storeId: _storeId, buyerId: _threadBuyerId,
      );
      if (!mounted) return;
      setState(() {
        _messages.add(ChatMessage(
          role: _role, msgType: 'file',
          mediaUrl: stored.localUri,
          content: caption ?? '',
          fileName: name, fileSize: bytes.length, fileMime: mime,
          clientId: clientId, createdAt: DateTime.now().toUtc(),
          replyToMessageId: reply?.id.isEmpty == true ? null : reply?.id,
          replyPreview: reply == null ? null : _replySnapshotOf(reply),
        ));
        _replyTo = null;
      });
      _scrollDown();
      unawaited(_cacheMessages());
      _enqueueDelivery(clientId, () => _deliverOutboxUpload(clientId, stored.path));
      // The picker's copy in the cache: the outbox has the file now.
      try {
        await picked.delete();
      } catch (_) {}
    } catch (e) {
      _notSent('Could not send ${doc.name}. ${userFacingError(e)}');
    }
  }

  /// Tap on a document: open it in another app - the copy on this phone,
  /// or downloaded first (and kept, for next time and offline).
  Future<void> _openDocument(ChatMessage m) async {
    final name = m.fileName ?? 'document';
    final key = m.id.isNotEmpty ? m.id : (m.clientId ?? '');
    if (key.isEmpty || _downloading.contains(key)) return;
    var file = ChatDocuments.fileForSync(
        messageId: m.id.isEmpty ? null : m.id, clientId: m.clientId);
    final url = m.mediaUrl ?? '';
    if (file == null && url.startsWith('file://')) {
      final staged = File(url.substring('file://'.length));
      if (staged.existsSync()) file = staged;
    }
    if (file == null) {
      if (!url.startsWith('/media/chat-files/')) {
        _notSent('This document is no longer available.');
        return;
      }
      setState(() => _downloading.add(key));
      try {
        final bytes = await ApiService.downloadChatFile(url);
        file = await ChatDocuments.keepBytes(bytes,
            messageId: m.id.isEmpty ? null : m.id, clientId: m.clientId, fileName: name);
      } catch (e) {
        _notSent('Could not download $name. ${userFacingError(e)}');
      } finally {
        if (mounted) setState(() => _downloading.remove(key));
      }
      if (file == null || !mounted) return;
    }
    final result = await ChatDocuments.open(file.path,
        mime: m.fileMime ?? ChatDocuments.mimeFor(name));
    if (!mounted) return;
    switch (result) {
      case OpenResult.opened:
        break;
      case OpenResult.missing:
        _notSent('This document is no longer on the phone. Tap it again to download it.');
        await ChatDocuments.remove(
            messageId: m.id.isEmpty ? null : m.id, clientId: m.clientId);
      case OpenResult.noApp:
      case OpenResult.unsupported:
        // Nothing on this phone opens it: hand it to an app that can keep
        // it (Drive, Files, WhatsApp...) instead.
        await _shareDocument(file, name, m.fileMime);
    }
  }

  Future<void> _shareDocument(File file, String name, String? mime) async {
    try {
      await Share.shareXFiles(
          [XFile(file.path, name: name, mimeType: mime ?? ChatDocuments.mimeFor(name))]);
    } catch (_) {
      _notSent("No app on this phone opens $name.");
    }
  }

  /// Upload from the outbox file (not the in-memory bytes). Cleans the
  /// temporary file once the server has it or the bubble is dropped.
  Future<void> _deliverOutboxUpload(String clientId, String storedPath) async {
    if (!_hasThread) return;
    // A retry reuses the staged format, not the raw pick: the server
    // must see the same file the idempotency key was first sent with.
    final staged = _uploads[clientId];
    final isFile = staged?.contentType == 'file';
    try {
      final bytes = await File(storedPath).readAsBytes();
      if (staged != null && !_isCurrentThread(
        listingId: staged.listingId,
        storeId: staged.storeId,
        buyerId: staged.buyerId,
      )) {
        _markFailed(clientId);
        _notSent(isFile
            ? 'This document belongs to another conversation.'
            : 'This photo belongs to another conversation.');
        return;
      }
      final saved = await ApiService.uploadMedia(
        listingId: staged?.listingId ?? _listing?.id,
        storeId: staged?.storeId ?? _storeId,
        senderRole: _role,
        senderId: ApiService.currentUserId ?? 'anon',
        contentType: staged?.contentType ?? 'image',
        fileBytes: bytes,
        fileName: staged?.fileName ?? 'image.jpg',
        mimeType: staged?.mimeType ?? 'image/jpeg',
        buyerId: staged?.buyerId ?? _threadBuyerId,
        clientMsgId: clientId,
        replyToMessageId: staged?.replyToMessageId,
        caption: staged?.caption,
        onProgress: (sent, total) => _reportUploadProgress(clientId, sent, total),
      );
      final serverMsg = ChatMessage.fromJson({'role': _role, ...saved});
      if (isFile) {
        // The sender's own copy follows the message to its settled id.
        if (serverMsg.id.isNotEmpty) {
          await ChatDocuments.settle(clientId: clientId, messageId: serverMsg.id);
        }
      } else {
        // Keep the sent photo on the phone under its settled id BEFORE the
        // staged copy is deleted - otherwise offline opens lose it.
        final stagedFile = await _ChatMediaOutbox.takeStaged(clientId);
        if (stagedFile != null) {
          await ChatMediaVault.adoptFile(stagedFile,
              messageId: serverMsg.id.isEmpty ? null : serverMsg.id,
              clientId: clientId);
        }
      }
      await _ChatMediaOutbox.remove(clientId);
      _confirm(clientId, serverMsg);
    } catch (e) {
      debugPrint('[DirectChat] ${isFile ? 'document' : 'photo'} upload failed: $e');
      _markFailed(clientId);
      _notSent(isFile
          ? 'Document not sent. ${userFacingError(e)}'
          : 'Photo not sent. Tap it to try again.');
    }
  }

  /// Restore outbox uploads from an earlier run: failed bubbles can retry
  /// without re-picking, because the file outlived the process. Each in
  /// its own format - a PNG photo was restored as "image/jpeg", and the
  /// server's decoder was told a lie about every one.
  Future<void> _restoreMediaOutbox() async {
    try {
      final entries = await _ChatMediaOutbox.list();
      for (final entry in entries) {
        if (_uploads.containsKey(entry.clientId)) continue;
        if (!_isCurrentThread(
          listingId: entry.listingId,
          storeId: entry.storeId,
          buyerId: entry.buyerId,
        )) {
          continue;
        }
        try {
          final bytes = await File(entry.path).readAsBytes();
          final png = entry.path.endsWith('.png');
          _uploads[entry.clientId] = _PendingUpload(
            bytes: bytes, contentType: entry.contentType,
            fileName: entry.fileName ?? (png ? 'image.png' : 'image.jpg'),
            mimeType: entry.mimeType ?? (png ? 'image/png' : 'image/jpeg'),
            replyToMessageId: entry.replyToMessageId,
            caption: entry.caption,
            listingId: entry.listingId,
            storeId: entry.storeId,
            buyerId: entry.buyerId,
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
    if (!_hasThread) return;
    final listing = _listing;
    final threadName = _isStoreThread ? _storeName : (listing?.name ?? '');
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
        listingId: listing?.id,
        storeId: _storeId,
        listingName: threadName,
        callType: callType,
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
        'peerPhoto': _headerPhotoSource,
        'peerOnline': _counterpartyOnline,
        'listingName': threadName, 'isCaller': true,
        if (listing != null) 'listingId': listing.id,
        if (_isStoreThread) 'storeId': _storeId,
        'buyerId': buyerId, 'callerRole': _role,
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
    if (_isStoreThread) return;
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
    if (_isStoreThread) {
      GlobalPollerService.instance
          .markStoreScreenInactive(_storeId!, buyerId: _buyerId);
    } else if (_listing != null) {
      GlobalPollerService.instance.markScreenInactive(_listing!.id, buyerId: _buyerId);
    }
    _msgCtrl.dispose();
    _composerFocus.dispose();
    _scrollCtrl.dispose();
    _pollTimer?.cancel();
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
  Widget build(BuildContext context) {
    if (_threadArgError != null) {
      return Scaffold(
        backgroundColor: BrokaColors.bg,
        body: SafeArea(
          child: Center(
            child: Padding(
              key: const Key('invalid-chat-arguments'),
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.link_off_rounded,
                    color: BrokaColors.textMid, size: 40),
                const SizedBox(height: 14),
                const Text('This chat link is invalid',
                    style: TextStyle(color: BrokaColors.textHigh,
                        fontSize: 17, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Text(_threadArgError!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: BrokaColors.textMid, height: 1.45)),
                const SizedBox(height: 18),
                TextButton(
                  onPressed: () => Navigator.maybePop(context),
                  child: const Text('Go back'),
                ),
              ]),
            ),
          ),
        ),
      );
    }
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      // Home's constellation, as on every screen reached from it. This thread
      // used to sit on ChatAmbientBackground - the splash field retuned and
      // held back - under an opaque header bar and an opaque composer bar,
      // which made it look like a different app from Home and Zeno.
      body: ConstellationBackground(
        animate: widget.animateBackground,
        child: Column(children: [
          _buildHeader(),
          if (!_isStoreThread)
            ChatModeSwitch(
              zenoActive: false,
              unread: _zenoUnreadCount,
              onSwitch: _openZenoAi,
            ),
          // Every buyer can pay from here: there is no "finalize" step before
          // it any more (auctions are paid from the auction screen).
          // Nothing at all while payments are hidden (payments_shown.dart).
          if (_isStoreThread || !paymentsShown)
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
  }

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
            child: (_headerPhotoSource != null && _headerPhotoSource!.isNotEmpty)
                ? BrokaImage(_headerPhotoSource,
                    fit: BoxFit.cover, placeholder: _headerInitial())
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
              _isStoreThread
                  ? (_role == 'buyer' ? 'Online store' : 'Direct store conversation')
                  : (_counterpartyLastSeen ??
                      (_counterpartyOnline ? 'Active now' : 'Last seen unavailable')),
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
        // Zeno has no room in a store-general thread: the conversation is
        // with the shop, and there is no listing for Zeno to negotiate on.
        if (!_isStoreThread) ...[
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
        ],
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
              clipBehavior: Clip.antiAlias,
              child: _isStoreThread && _storeLogo != null && _storeLogo!.isNotEmpty
                  ? BrokaImage(_storeLogo, fit: BoxFit.cover)
                  : Text(_listing?.emoji ?? (_isStoreThread ? '🏪' : '💬'),
                      style: const TextStyle(fontSize: 40)),
            ),
            const SizedBox(height: 18),
            Text(
              _isStoreThread
                  ? (_role == 'buyer'
                      ? 'You\'re talking to ${_storeName.isEmpty ? 'the store' : _storeName}'
                      : 'You\'re talking to the buyer')
                  : _role == 'buyer'
                  ? 'You\'re talking to ${_listing?.sellerName ?? 'the seller'}'
                  : 'You\'re talking to the buyer',
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: BrokaColors.textHigh,
                  fontSize: 16, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              _isStoreThread
                  ? 'Messages here go straight to the shop owner. This is a '
                      'direct conversation, not a product negotiation.'
                  : 'Messages here go straight to them — Zeno is not in this '
                      'thread and cannot read it.',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: BrokaColors.textLow, fontSize: 12.5, height: 1.5),
            ),
            if (!_isStoreThread) ...[
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
            ],
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
        final fileKey = id.isNotEmpty ? id : (clientId ?? '');
        return _ChatBubble(
        key: key,
        uploadProgress: clientId == null ? null : _uploads[clientId]?.progress,
        inFlight: clientId != null && _inFlight.contains(clientId),
        downloading: fileKey.isNotEmpty && _downloading.contains(fileKey),
        message:    _messages[i],
        userRole:   _role,
        isPlaying:  _isPlaying && _playingUrl == _messages[i].mediaUrl,
        onPlayTap:  (url) => _togglePlay(url),
        onCallBack: _callBack,
        onUnsentTap: _onUnsentTap,
        onLongPress: _onMessageLongPress,
        onQuoteTap: _jumpToReply,
        onOpenFile: _openDocument,
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
    // The snapshot of the message being answered - not its own reply
    // preview, which describes the message IT answered.
    final label = ChatMessage.replyLabel(_replySnapshotOf(reply));
    final isPhoto = reply.msgType == 'image';
    final isFile = reply.msgType == 'file';
    return Padding(
      key: const Key('composer-reply-preview'),
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
              Text(isPhoto && label == 'Photo'
                      ? '📷 Photo'
                      : isFile ? '📄 $label' : label,
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

  /// The composer card (chat_parts.dart, 2026-11-09): the message on top;
  /// under it the shortcuts people look for - Photos and Document - and on
  /// the right "+" for everything (the camera too), the microphone, and the
  /// send button that takes the microphone's place once there is text.
  Widget _buildInputBar() => SafeArea(
    top: false,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
      child: ChatComposerCard(
        focused: _composerFocused,
        field: TextField(
          key: const Key('direct-chat-composer'),
          controller: _msgCtrl,
          focusNode: _composerFocus,
          style: const TextStyle(
              color: BrokaColors.textHigh, fontSize: 15.5, height: 1.35),
          // Room to compose a real paragraph - a marketplace negotiation
          // is not a one-liner - while still scrolling rather than eating
          // the conversation.
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
            hintStyle: const TextStyle(color: BrokaColors.textMid, fontSize: 15),
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            contentPadding: const EdgeInsets.fromLTRB(2, 10, 2, 6),
          ),
        ),
        leading: [
          ChatComposerChip(
            key: const Key('composer-photos'),
            icon: Icons.photo_library_outlined,
            label: 'Photos',
            tooltip: 'Send photos',
            onTap: _pickPhotos,
          ),
          ChatComposerChip(
            key: const Key('composer-document'),
            icon: Icons.description_outlined,
            label: 'Document',
            tooltip: 'Send a document',
            color: BrokaColors.neonPurple,
            onTap: _pickDocuments,
          ),
        ],
        trailing: [
          ChatComposerIconButton(
            icon: Icons.add_rounded,
            tooltip: 'Attach',
            onTap: _showAttachSheet,
          ),
          // Gone once there's text - the send button is then the one action
          // that makes sense, and a second one beside it asks the user to aim.
          if (!_hasDraft)
            ChatComposerIconButton(
              icon: Icons.mic_none_rounded,
              tooltip: 'Record a voice note',
              onTap: _startRecording,
            ),
          ChatSendButton(visible: _hasDraft, onTap: _send, size: 38),
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

  /// Queued or on its way: "Sending", however long it waits its turn.
  final bool inFlight;

  /// A document: being downloaded to open.
  final bool downloading;

  /// A document was tapped.
  final ValueChanged<ChatMessage>? onOpenFile;

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
    this.onOpenFile,
    this.highlighted = false,
    this.uploadProgress,
    this.inFlight = false,
    this.downloading = false,
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
            inFlight: inFlight,
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
      // The photo's own frame carries the quote and the highlight: the
      // quote used to sit in a second bubble wrapped around the first.
      bubbleContent = _ImageBubble(
        url: message.mediaUrl!,
        messageId: message.id.isEmpty ? null : message.id,
        clientId: message.clientId,
        caption: message.content,
        isMe: isMe,
        createdAt: message.createdAt,
        receipt: receipt,
        // "Not sent" shows as such on the photo. A failed photo is still
        // pending (no server id), and it used to spin as if uploading.
        pending: message.isPending && !unsent,
        failed: unsent,
        progress: uploadProgress,
        quote: hasQuote ? quoteBlock() : null,
        highlighted: highlighted,
      );
    } else if (message.msgType == 'file') {
      bubbleContent = _FileBubble(
        message: message,
        isMe: isMe,
        quote: hasQuote ? quoteBlock() : null,
        highlighted: highlighted,
        pending: message.isPending && !unsent,
        failed: unsent,
        progress: uploadProgress,
        downloading: downloading,
        onOpen: onOpenFile == null ? null : () => onOpenFile!(message),
      );
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
        // The bubble's own targets (a photo opens its viewer on tap) must
        // not swallow this one: the message never reached the server, so
        // the only useful tap on it is Send again / Delete.
        behavior: HitTestBehavior.opaque,
        onTap: () => onUnsentTap!(message),
        child: IgnorePointer(
          child: Opacity(opacity: 0.7, child: bubbleContent),
        ),
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

/// Resolve a chat photo to an image provider. The on-device vault copy
/// wins whenever one exists, so settled photos keep rendering after the
/// server copy is unreachable (offline) - a data URI or remote URL is only
/// the fallback. Shared by the bubble and the full-screen viewer so both
/// show the same bytes.
ImageProvider? _chatImageProvider(String url,
    {String? messageId, String? clientId}) {
  try {
    final vault =
        ChatMediaVault.fileForSync(messageId: messageId, clientId: clientId);
    if (vault != null) return FileImage(vault);
    if (url.startsWith('data:')) {
      final commaIdx = url.indexOf(',');
      if (commaIdx < 0) return null;
      return MemoryImage(base64Decode(url.substring(commaIdx + 1)));
    }
    if (url.startsWith('file://')) {
      return FileImage(File(url.replaceFirst('file://', '')));
    }
    if (url.isEmpty) return null;
    // From the disk cache (BrokaImage.provider): a NetworkImage was fetched
    // again every time the chat was opened.
    return BrokaImage.provider(url) ?? NetworkImage(url);
  } catch (_) {
    return null;
  }
}

class _ImageBubble extends StatefulWidget {
  final String url;
  final String? messageId;
  final String? clientId;
  final String? caption;
  final bool isMe;
  final DateTime? createdAt;
  final MessageReceipt? receipt;
  final bool pending;
  final bool failed;

  /// 0..1 upload progress. Shown as a ring with a percent while uploading;
  /// null (or 0) keeps the plain spinner for indeterminate stages.
  final double? progress;

  /// The message this photo answers, drawn inside the frame above it.
  final Widget? quote;

  /// The jump-to-original flash.
  final bool highlighted;

  const _ImageBubble({
    required this.url,
    this.messageId,
    this.clientId,
    this.caption,
    this.isMe = false,
    this.createdAt,
    this.receipt,
    this.pending = false,
    this.failed = false,
    this.progress,
    this.quote,
    this.highlighted = false,
  });

  @override
  State<_ImageBubble> createState() => _ImageBubbleState();
}

class _ImageBubbleState extends State<_ImageBubble> {
  // Resolved once per (url, message id, client id): a fresh FileImage per
  // build would look unequal to AspectImage on every parent rebuild and
  // re-resolve (flickering the photo through its placeholder), so the
  // provider instance is pinned here for the bubble's lifetime.
  late ImageProvider? _provider;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(_ImageBubble old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url ||
        old.messageId != widget.messageId ||
        old.clientId != widget.clientId) {
      _resolve();
      setState(() {});
    }
  }

  void _resolve() {
    _provider = _chatImageProvider(widget.url,
        messageId: widget.messageId, clientId: widget.clientId);
  }

  @override
  Widget build(BuildContext context) {
    final provider = _provider;
    final captionText = (widget.caption ?? '').trim();
    final pending = widget.pending;
    final failed = widget.failed;
    // WhatsApp's photo bubble (2026-11-09): every photo the same width,
    // filling it edge to edge inside a thin frame in the bubble's own
    // colour - the gradient for mine, the card for theirs. It used to be
    // the photo at its own ratio in a dark card, so a portrait came out a
    // narrow strip between two wide dark bars. A photo is cropped only past
    // its bounds (taller than 3:4, flatter than 5:3); the whole picture is
    // one tap away in the viewer.
    final photoWidth = min(MediaQuery.of(context).size.width * 0.68, 300.0);
    final maxHeight = min(photoWidth * 1.33, 340.0);
    final minHeight = photoWidth * 0.6;
    final frame = (widget.isMe
            ? myBubbleDecoration(tailRight: false)
            : theirBubbleDecoration())
        .copyWith(
      borderRadius: const BorderRadius.all(Radius.circular(16)),
      // null keeps the frame's own border (copyWith).
      border: widget.highlighted
          ? Border.all(color: BrokaColors.gold, width: 1.5)
          : null,
    );
    return GestureDetector(
      onTap: provider == null
          ? null
          : () => Navigator.of(context).push(MaterialPageRoute(
                builder: (_) => _FullScreenImageViewer(
                    url: widget.url,
                    messageId: widget.messageId,
                    clientId: widget.clientId,
                    caption: captionText.isEmpty ? null : captionText),
              )),
      child: Container(
        key: const Key('photo-frame'),
        width: photoWidth + 6,
        padding: const EdgeInsets.all(3),
        decoration: frame,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.quote != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(5, 5, 5, 0),
                child: widget.quote!,
              ),
            ClipRRect(
              // The frame's 16 less its 3dp: the corners stay concentric.
              borderRadius: const BorderRadius.all(Radius.circular(13)),
              child: provider == null
                  ? Container(
                      height: 120,
                      color: Colors.black.withOpacity(0.25),
                      alignment: Alignment.center,
                      child: const Icon(Icons.broken_image_outlined,
                          color: BrokaColors.textLow, size: 36),
                    )
                  : Stack(
                      children: [
                        AspectImage(
                          provider: provider,
                          maxWidth: photoWidth,
                          maxHeight: maxHeight,
                          minHeight: minHeight,
                          fillWidth: true,
                          placeholderHeight: photoWidth * 0.75,
                        ),
                        if (pending || failed)
                          Positioned.fill(
                            child: Container(
                              color: Colors.black.withOpacity(0.45),
                              alignment: Alignment.center,
                              child: failed
                                  ? const Icon(Icons.error_outline_rounded,
                                      color: Colors.white, size: 30)
                                  : _UploadProgressRing(progress: widget.progress),
                            ),
                          ),
                        // The shade the time sits on: white text stays
                        // legible on a white wall or a bright sky.
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          height: 40,
                          child: IgnorePointer(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Colors.black.withOpacity(0.0),
                                    Colors.black.withOpacity(0.5),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        // The time and the ticks on the photo, bottom right,
                        // not in a row beneath it.
                        Positioned(
                          key: const Key('photo-meta-overlay'),
                          right: 8,
                          bottom: 5,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              MessageTimeLabel(
                                  sentAt: widget.createdAt, light: true),
                              if (widget.receipt != null) ...[
                                const SizedBox(width: 4),
                                MessageReceiptIcon(
                                    receipt: widget.receipt!,
                                    light: true,
                                    compact: true),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
            ),
            if (captionText.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 7, 8, 5),
                child: Text(captionText,
                    style: TextStyle(
                        color: widget.isMe
                            ? Colors.white
                            : BrokaColors.textHigh,
                        fontSize: 14, height: 1.35)),
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

// ── Document bubble ──────────────────────────────────────────────────────────

/// A shared document (2026-11-09): its type, name and size in the bubble's
/// colours, a caption under it. Tapping opens it in another app - straight
/// away when it is on this phone, after a download otherwise.
class _FileBubble extends StatelessWidget {
  const _FileBubble({
    required this.message,
    required this.isMe,
    this.quote,
    this.highlighted = false,
    this.pending = false,
    this.failed = false,
    this.progress,
    this.downloading = false,
    this.onOpen,
  });

  final ChatMessage message;
  final bool isMe;
  final Widget? quote;
  final bool highlighted;
  final bool pending;
  final bool failed;
  final double? progress;
  final bool downloading;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final name = (message.fileName ?? '').trim().isEmpty
        ? 'Document'
        : message.fileName!.trim();
    final caption = message.content.trim();
    final onPhone = (message.mediaUrl ?? '').startsWith('file://') ||
        ChatDocuments.fileForSync(
                messageId: message.id.isEmpty ? null : message.id,
                clientId: message.clientId) !=
            null;
    final ink = isMe ? Colors.white : BrokaColors.textHigh;
    final Widget state;
    if (pending) {
      state = SizedBox(
        width: 36,
        height: 36,
        child: FittedBox(child: _UploadProgressRing(progress: progress)),
      );
    } else if (failed) {
      state = const Icon(Icons.error_outline_rounded,
          color: BrokaColors.danger, size: 24);
    } else if (downloading) {
      state = SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(strokeWidth: 2.2, color: ink),
      );
    } else {
      state = Semantics(
        label: onPhone ? 'Open $name' : 'Download $name',
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: ink.withOpacity(0.6), width: 1.3),
          ),
          child: Icon(
              onPhone ? Icons.open_in_new_rounded : Icons.download_rounded,
              color: ink,
              size: 18),
        ),
      );
    }
    return Container(
      key: const Key('file-bubble'),
      width: min(MediaQuery.of(context).size.width * 0.72, 320.0),
      padding: const EdgeInsets.all(5),
      decoration: (isMe ? myBubbleDecoration() : theirBubbleDecoration()).copyWith(
        border: highlighted ? Border.all(color: BrokaColors.gold, width: 1.5) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (quote != null)
            Padding(padding: const EdgeInsets.fromLTRB(5, 5, 5, 0), child: quote!),
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: (pending || failed || downloading) ? null : onOpen,
              child: _DocumentTile(name: name, size: message.fileSize, onBrand: isMe, trailing: state),
            ),
          ),
          if (caption.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(7, 7, 7, 3),
              child: Text(caption,
                  style: TextStyle(color: ink, fontSize: 14, height: 1.35)),
            ),
        ],
      ),
    );
  }
}

/// One document: a badge in its type's colour (PDF red, Word blue, Excel
/// green, PowerPoint orange), its name, and "PDF · 1.2 MB". The chat's
/// bubble and the preview before sending draw the same tile.
class _DocumentTile extends StatelessWidget {
  const _DocumentTile({
    required this.name,
    this.size,
    this.trailing,
    this.onBrand = false,
  });

  final String name;
  final int? size;
  final Widget? trailing;

  /// On the brand gradient (my own bubble): white words.
  final bool onBrand;

  static Color colorFor(String kind) {
    switch (kind) {
      case 'PDF':
        return const Color(0xFFE5484D);
      case 'Word':
        return const Color(0xFF4C8DFF);
      case 'Excel':
      case 'CSV':
        return const Color(0xFF2FB673);
      case 'PowerPoint':
        return const Color(0xFFF38B3C);
      default:
        return BrokaColors.textMid;
    }
  }

  @override
  Widget build(BuildContext context) {
    final kind = ChatDocuments.kindLabel(name);
    final ext = ChatDocuments.extensionOf(name).toUpperCase();
    final color = colorFor(kind);
    final details = [
      kind == 'Document' ? (ext.isEmpty ? 'Document' : ext) : kind,
      ChatDocuments.sizeLabel(size),
    ].where((s) => s.isNotEmpty).join(' · ');
    final badge = ext.isEmpty ? 'DOC' : (ext.length > 4 ? ext.substring(0, 4) : ext);
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(onBrand ? 0.16 : 0.22),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(children: [
        Container(
          width: 40,
          height: 46,
          decoration: BoxDecoration(
            color: onBrand ? Colors.white : color.withOpacity(0.16),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: color.withOpacity(0.55)),
          ),
          alignment: Alignment.center,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.description_rounded, color: color, size: 18),
            const SizedBox(height: 1),
            Text(badge,
                maxLines: 1,
                textScaler: TextScaler.noScaling,
                style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.w800)),
          ]),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: onBrand ? Colors.white : BrokaColors.textHigh,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      height: 1.25)),
              if (details.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(details,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        color: onBrand ? Colors.white.withOpacity(0.78) : BrokaColors.textMid,
                        fontSize: 11.5)),
              ],
            ],
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 8), trailing!],
      ]),
    );
  }
}

/// A photo in the strip under the send preview: tap to look at it, × to
/// take it out.
class _PreviewThumb extends StatelessWidget {
  const _PreviewThumb({
    super.key,
    required this.file,
    required this.selected,
    required this.onTap,
    required this.onRemove,
  });

  final File file;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(right: 8),
    child: SizedBox(
      width: 64,
      height: 68,
      child: Stack(children: [
        Positioned(
          left: 0,
          top: 4,
          child: GestureDetector(
            onTap: onTap,
            child: Container(
              width: 60,
              height: 60,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: BrokaColors.bgCard,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: selected ? BrokaColors.neonBlue : BrokaColors.border,
                  width: selected ? 2 : 1,
                ),
              ),
              // Decoded small: ten full-size photos in a strip held tens of
              // megabytes for 60dp squares.
              child: Image.file(file,
                  fit: BoxFit.cover,
                  cacheWidth: 180,
                  errorBuilder: (_, __, ___) => const Icon(
                      Icons.broken_image_outlined,
                      color: BrokaColors.textLow, size: 22)),
            ),
          ),
        ),
        Positioned(
          right: 0,
          top: 0,
          child: Semantics(
            button: true,
            label: 'Take this photo out',
            child: GestureDetector(
              onTap: onRemove,
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black.withOpacity(0.8),
                  border: Border.all(color: Colors.white24),
                ),
                child: const Icon(Icons.close_rounded, color: Colors.white, size: 14),
              ),
            ),
          ),
        ),
      ]),
    ),
  );
}

/// Dedicated full-screen photo viewer: pinch-to-zoom, caption, close.
class _FullScreenImageViewer extends StatelessWidget {
  final String url;
  final String? messageId;
  final String? clientId;
  final String? caption;
  const _FullScreenImageViewer(
      {required this.url, this.messageId, this.clientId, this.caption});

  ImageProvider? _provider() =>
      _chatImageProvider(url, messageId: messageId, clientId: clientId);

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
