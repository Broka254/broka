// BROKA - Store Chat Screen
// Direct buyer <-> store-owner conversation, not tied to any one product.
// Thread identity is (storeId, buyerId) on the server, so it survives
// listings being added, archived or sold - unlike the old Message Store,
// which borrowed the store's first listing and lost the thread with it.
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../../../main.dart';
import '../../../models/models.dart';
import '../../../services/api_service.dart';
import '../../../services/global_poller_service.dart';
import '../../../services/local_chat_store.dart';
import '../../../widgets/chat_parts.dart' show kChatGradient;
import '../../../widgets/constellation_background.dart';

class StoreChatScreen extends StatefulWidget {
  const StoreChatScreen({super.key, this.animateBackground = true});
  final bool animateBackground;
  @override
  State<StoreChatScreen> createState() => _StoreChatScreenState();
}

class _LocalMsg {
  final Message msg;
  final bool failed;
  const _LocalMsg(this.msg, {this.failed = false});
}

class _StoreChatScreenState extends State<StoreChatScreen> {
  String? _storeId;
  String _storeName = 'Store';
  String? _storeLogo;
  String _role = 'buyer';
  String? _buyerId;
  String? _counterpartName;
  List<_LocalMsg> _messages = [];
  bool _loading = true;
  bool _started = false;
  final _msgCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  Timer? _pollTimer;
  Timer? _pingTimer;
  WebSocketChannel? _ws;
  bool _wsConnected = false;
  DateTime? _counterpartRead;
  DateTime? _counterpartDelivered;
  Message? _replyTo;

  String get _scope => 'store_${_storeId ?? ''}_${_buyerId ?? ''}';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final args = ModalRoute.of(context)?.settings.arguments;
    if (args is Map) {
      _storeId = args['storeId'] as String? ?? args['store_id'] as String?;
      _storeName = (args['storeName'] as String?)?.trim().isNotEmpty == true
          ? args['storeName'] as String
          : 'Store';
      _storeLogo = args['storeLogo'] as String?;
      _role = args['role'] as String? ?? 'buyer';
      _buyerId = args['buyer_id'] as String?;
      _counterpartName = args['counterpartName'] as String?;
      if (_role == 'buyer') _buyerId = ApiService.currentUserId;
    }
    unawaited(_init());
  }

  Future<void> _init() async {
    if (_storeId != null) {
      GlobalPollerService.instance
          .markStoreScreenActive(_storeId!, buyerId: _buyerId);
    }
    await _loadCache();
    await _loadHistory();
    _connectWs();
    _pollTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!_wsConnected) unawaited(_loadHistory(silent: true));
    });
  }

  Future<void> _loadCache() async {
    final cached = await LocalChatStore.load(_scope);
    if (!mounted || cached.isEmpty) return;
    setState(() {
      _messages = cached.map((j) => _LocalMsg(Message.fromJson(j))).toList();
      _loading = false;
    });
  }

  Future<void> _saveCache() async {
    await LocalChatStore.save(
        _scope, _messages.where((m) => !m.failed).map((m) => m.msg.toJson()).toList());
  }

  Future<void> _loadHistory({bool silent = false}) async {
    final storeId = _storeId;
    if (storeId == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final history = await ApiService.getStoreHistory(
          storeId, buyerId: _role == 'seller' ? _buyerId : null);
      if (!mounted) return;
      final failed = _messages.where((m) => m.failed).toList();
      setState(() {
        _messages = [
          ...history.map((m) => _LocalMsg(m)),
          ...failed.where((f) => !history.any((h) => h.clientMsgId != null && h.clientMsgId == f.msg.clientMsgId)),
        ];
        _loading = false;
      });
      unawaited(_saveCache());
      unawaited(ApiService.markStoreRead(storeId, buyerId: _buyerId));
      unawaited(_refreshReceipts());
      _scrollToBottom();
    } catch (_) {
      if (mounted && !silent) setState(() => _loading = false);
    }
  }

  Future<void> _refreshReceipts() async {
    final storeId = _storeId;
    if (storeId == null) return;
    final status = await ApiService.getStoreReadStatus(
        storeId, buyerId: _role == 'seller' ? _buyerId : null);
    if (!mounted || status == null) return;
    final other = _role == 'buyer' ? 'seller' : 'buyer';
    setState(() {
      _counterpartRead = status['${other}_last_read'] ?? _counterpartRead;
      _counterpartDelivered =
          status['${other}_last_delivered'] ?? _counterpartDelivered;
    });
  }

  void _connectWs() {
    final storeId = _storeId;
    final token = ApiService.authToken;
    if (storeId == null || token == null) return;
    final base = ApiService.baseUrl
        .replaceFirst('https://', 'wss://')
        .replaceFirst('http://', 'ws://');
    var url = '$base/media/ws/store/$storeId?token=$token';
    if (_role == 'seller' && _buyerId != null) url += '&buyer_id=$_buyerId';
    try {
      final ws = WebSocketChannel.connect(Uri.parse(url));
      _ws = ws;
      ws.ready.then((_) {
        if (mounted && identical(_ws, ws)) setState(() => _wsConnected = true);
      }).catchError((_) {});
      ws.stream.listen((raw) {
        if (!mounted) return;
        try {
          final data = jsonDecode(raw as String) as Map<String, dynamic>;
          final type = data['type'] as String?;
          if (type == 'message') {
            final m = Message.fromJson({
              'role': data['role'], 'content': data['content'] ?? '',
              'id': data['id'] ?? '', 'msg_type': data['msg_type'] ?? 'text',
              'media_url': (data['media_url'] as String?)?.isEmpty == true ? null : data['media_url'],
              'duration_secs': data['duration_secs'],
              'call_type': data['call_type'],
              'via_ai': data['via_ai'] ?? false,
              'created_at': data['created_at'],
              'client_msg_id': data['client_msg_id'],
              'edited_at': data['edited_at'],
              'deleted': data['deleted'] ?? false,
              'reply_to_message_id': data['reply_to_message_id'],
              'reply_preview': data['reply_preview'],
            });
            if (_messages.any((x) => x.msg.id == m.id && m.id.isNotEmpty)) return;
            setState(() => _messages = [..._messages, _LocalMsg(m)]);
            unawaited(_saveCache());
            unawaited(ApiService.markStoreRead(storeId, buyerId: _buyerId));
            _scrollToBottom();
          } else if (type == 'receipt') {
            unawaited(_refreshReceipts());
          } else if (type == 'message_edited' || type == 'message_deleted') {
            unawaited(_loadHistory(silent: true));
          }
        } catch (_) {}
      }, onError: (_) => _wsConnected = false, onDone: () => _wsConnected = false);
      _pingTimer = Timer.periodic(const Duration(seconds: 25), (_) {
        try {
          ws.sink.add(jsonEncode({'type': 'ping'}));
        } catch (_) {}
      });
    } catch (_) {}
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.jumpTo(_scrollCtrl.position.maxScrollExtent);
      }
    });
  }

  Future<void> _send() async {
    final text = _msgCtrl.text.trim();
    final storeId = _storeId;
    final uid = ApiService.currentUserId;
    if (text.isEmpty || storeId == null || uid == null) return;
    final clientId = 'local-${DateTime.now().microsecondsSinceEpoch}';
    final reply = _replyTo;
    final local = Message(
      role: _role, content: text, id: '', clientMsgId: clientId,
      createdAt: DateTime.now(), replyToMessageId: reply?.id,
    );
    setState(() {
      _messages = [..._messages, _LocalMsg(local)];
      _replyTo = null;
    });
    _msgCtrl.clear();
    _scrollToBottom();
    try {
      final saved = await ApiService.sendStoreDirectMessage(
        storeId: storeId, senderRole: _role, senderId: uid, content: text,
        buyerId: _role == 'seller' ? _buyerId : null,
        clientMsgId: clientId, replyToMessageId: reply?.id,
      );
      if (!mounted) return;
      if (saved != null) {
        final m = Message.fromJson({
          'role': saved['role'] ?? _role, 'content': saved['content'] ?? text,
          'id': saved['id'] ?? '', 'msg_type': saved['msg_type'] ?? 'text',
          'created_at': saved['created_at'], 'client_msg_id': saved['client_msg_id'],
          'edited_at': saved['edited_at'], 'deleted': saved['deleted'] ?? false,
          'reply_to_message_id': saved['reply_to_message_id'],
          'reply_preview': saved['reply_preview'],
        });
        setState(() {
          _messages = _messages
              .map((x) => x.msg.clientMsgId == clientId ? _LocalMsg(m) : x)
              .toList();
        });
        unawaited(_saveCache());
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _messages = _messages
            .map((x) => x.msg.clientMsgId == clientId ? _LocalMsg(x.msg, failed: true) : x)
            .toList();
      });
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Not sent - check your connection and try again.')));
    }
  }

  String _receiptLabel(Message m) {
    if (m.role != _role || m.createdAt == null) return '';
    if (_counterpartRead != null && !_counterpartRead!.isBefore(m.createdAt!)) return 'Seen';
    if (_counterpartDelivered != null && !_counterpartDelivered!.isBefore(m.createdAt!)) {
      return 'Delivered';
    }
    return 'Sent';
  }

  @override
  void dispose() {
    if (_storeId != null) {
      GlobalPollerService.instance
          .markStoreScreenInactive(_storeId!, buyerId: _buyerId);
    }
    _pollTimer?.cancel();
    _pingTimer?.cancel();
    _ws?.sink.close();
    _msgCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final title = _role == 'buyer'
        ? _storeName
        : (_counterpartName?.trim().isNotEmpty == true ? _counterpartName! : 'Buyer');
    final subtitle = _role == 'buyer' ? 'Store conversation' : '$_storeName · Store conversation';
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      body: ConstellationBackground(
        animate: widget.animateBackground,
        child: SafeArea(
          child: Column(children: [
            Container(
              padding: const EdgeInsets.fromLTRB(4, 8, 16, 8),
              child: Row(children: [
                IconButton(
                  key: const Key('store-chat-back'),
                  icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
                  onPressed: () => Navigator.maybePop(context),
                ),
                CircleAvatar(
                  radius: 20,
                  backgroundColor: BrokaColors.bgCard,
                  backgroundImage: (_storeLogo != null && _storeLogo!.startsWith('http'))
                      ? NetworkImage(_storeLogo!)
                      : null,
                  child: (_storeLogo != null && _storeLogo!.startsWith('http'))
                      ? null
                      : Text(
                          title.isNotEmpty ? title[0].toUpperCase() : 'S',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
                        ),
                ),
                const SizedBox(width: 10),
                Expanded(child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w800)),
                  Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white70, fontSize: 12)),
                ])),
                const Icon(Icons.storefront_rounded, color: Colors.white54, size: 20),
              ]),
            ),
            const Divider(height: 1, color: Colors.white12),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator(color: BrokaColors.gold))
                  : _messages.isEmpty
                      ? const Center(child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('Say hello to the store - your conversation stays here in your Inbox.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.white70)),
                        ))
                      : ListView.builder(
                          controller: _scrollCtrl,
                          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                          itemCount: _messages.length,
                          itemBuilder: (_, i) => _bubble(_messages[i]),
                        ),
            ),
            if (_replyTo != null)
              Container(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                child: Row(children: [
                  Expanded(child: Text('Replying: ${_replyTo!.content}',
                      maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white70, fontSize: 12))),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, color: Colors.white70, size: 18),
                    onPressed: () => setState(() => _replyTo = null),
                  ),
                ]),
              ),
            Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Row(children: [
                Expanded(child: TextField(
                  key: const Key('store-chat-input'),
                  controller: _msgCtrl,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Message $_storeName',
                    hintStyle: const TextStyle(color: Colors.white54),
                    filled: true,
                    fillColor: BrokaColors.bgCard,
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(24),
                        borderSide: BorderSide.none),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  ),
                  onSubmitted: (_) => unawaited(_send()),
                )),
                const SizedBox(width: 8),
                Container(
                  decoration: const BoxDecoration(
                      gradient: LinearGradient(colors: kChatGradient),
                      shape: BoxShape.circle),
                  child: IconButton(
                    key: const Key('store-chat-send'),
                    icon: const Icon(Icons.send_rounded, color: Colors.white, size: 20),
                    onPressed: () => unawaited(_send()),
                  ),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _bubble(_LocalMsg item) {
    final m = item.msg;
    final mine = m.role == _role;
    final deleted = m.deleted || m.msgType == 'deleted';
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: deleted
            ? null
            : () => setState(() => _replyTo = m),
        child: Container(
          margin: const EdgeInsets.only(bottom: 8),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          constraints: BoxConstraints(
              maxWidth: MediaQuery.sizeOf(context).width * 0.78),
          decoration: BoxDecoration(
            gradient: mine ? const LinearGradient(colors: kChatGradient) : null,
            color: mine ? null : BrokaColors.bgCard,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (m.replyPreview != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  (m.replyPreview!['preview'] as String?) ??
                      (m.replyPreview!['label'] as String?) ?? 'Replied message',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 11),
                ),
              ),
            if (m.msgType == 'image' && (m.mediaUrl ?? '').isNotEmpty)
              const Padding(
                padding: EdgeInsets.only(bottom: 4),
                child: Text('Photo', style: TextStyle(color: Colors.white70, fontSize: 12)),
              ),
            Text(
              deleted ? 'Message deleted' : m.content,
              style: TextStyle(
                  color: Colors.white,
                  fontStyle: deleted ? FontStyle.italic : FontStyle.normal),
            ),
            const SizedBox(height: 3),
            Row(mainAxisSize: MainAxisSize.min, children: [
              if (m.editedAt != null)
                const Text('edited  ', style: TextStyle(color: Colors.white54, fontSize: 10)),
              if (item.failed)
                const Text('Not sent  ', style: TextStyle(color: Colors.redAccent, fontSize: 10)),
              if (mine && !item.failed)
                Text(_receiptLabel(m),
                    style: const TextStyle(color: Colors.white54, fontSize: 10)),
            ]),
          ]),
        ),
      ),
    );
  }
}
