// BROKA - AI Assistant Screen
// General-purpose AI: honest about capabilities, addresses user by name
import 'package:flutter/material.dart';
import '../main.dart';
import '../services/api_service.dart';
import '../models/models.dart';
import '../models/listing.dart';

class AiAssistantScreen extends StatefulWidget {
  // When set (e.g. from home_screen.dart's Variant B search entry), this
  // is sent automatically on first frame instead of showing an empty chat.
  final String? initialQuery;
  const AiAssistantScreen({super.key, this.initialQuery});
  @override
  State<AiAssistantScreen> createState() => _AiAssistantScreenState();
}

class _AiAssistantScreenState extends State<AiAssistantScreen> {
  final _msgCtrl    = TextEditingController();
  final _scrollCtrl = ScrollController();
  bool _typing = false;
  List<Message> _messages = [];
  List<Map<String, String>> _history = [];
  // Keyed by message index in _messages - the shortlist a given advisor
  // reply was ranked from, rendered as tappable cards under that message.
  final Map<int, List<Listing>> _shortlists = {};

  String get _firstName {
    final name = ApiService.currentUserName;
    if (name != null && name.isNotEmpty) return name.split(' ').first;
    return '';
  }

  final _suggestions = const [
    ('📱', 'A phone under KES 30,000 with a good camera'),
    ('🚗', 'A reliable car under KES 1M for city driving'),
    ('🛋️', 'A 3-seater sofa under KES 40,000'),
    ('💻', 'A laptop for university under KES 60,000'),
  ];

  @override
  void initState() {
    super.initState();
    _initChat();
    if (widget.initialQuery != null && widget.initialQuery!.trim().isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _send(widget.initialQuery));
    }
  }

  void _initChat() {
    final greet = _firstName.isNotEmpty ? 'Habari $_firstName!' : 'Habari!';
    setState(() => _messages = [
      Message(role: 'broker', content:
        "$greet I'm Zeno, your shopping advisor 🛍️\n\n"
        "Tell me what you're looking for - budget, category, anything "
        "specific you need - and I'll search current listings and rank "
        "what actually fits."),
    ]);
  }

  @override
  void dispose() { _scrollCtrl.dispose(); _msgCtrl.dispose(); super.dispose(); }

  Future<void> _send([String? quick]) async {
    final text = quick ?? _msgCtrl.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _messages.add(Message(role: 'user', content: text));
      _typing = true;
    });
    if (quick == null) _msgCtrl.clear();
    _scrollDown();

    try {
      final result = await ApiService.shoppingAdvisor(
        query: text,
        history: List.from(_history),
      );
      _history.add({'role': 'user',      'content': text});
      _history.add({'role': 'assistant', 'content': result.reply.content});

      if (mounted) {
        setState(() {
          _typing = false;
          _messages.add(result.reply);
          if (result.shortlist.isNotEmpty) {
            _shortlists[_messages.length - 1] = result.shortlist;
          }
        });
        _scrollDown();
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _typing = false;
          _messages.add(Message(role: 'broker',
            content: 'Network error. Please check your connection.'));
        });
      }
    }
  }

  void _scrollDown() => Future.delayed(const Duration(milliseconds: 120), () {
    if (_scrollCtrl.hasClients) _scrollCtrl.animateTo(
      _scrollCtrl.position.maxScrollExtent,
      duration: const Duration(milliseconds: 280), curve: Curves.easeOut);
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF070B16), Color(0xFF03040A)],
            begin: Alignment.topCenter, end: Alignment.bottomCenter,
          ),
        ),
        child: SafeArea(child: Column(children: [
          _buildHeader(),
          Expanded(child: _buildChat()),
          if (_messages.length <= 1) _buildSuggestions(),
          _buildInputBar(),
        ])),
      ),
    );
  }

  Widget _buildHeader() => Padding(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
    child: Row(children: [
      GestureDetector(
        onTap: () => Navigator.pop(context),
        child: Container(
          width: 36, height: 36,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: BrokaColors.bgCard,
            border: Border.all(color: BrokaColors.border),
          ),
          child: const Icon(Icons.arrow_back_ios_new_rounded,
              color: BrokaColors.textMid, size: 16),
        ),
      ),
      const SizedBox(width: 12),
      Container(
        width: 36, height: 36,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          gradient: const LinearGradient(
            colors: [BrokaColors.gold, BrokaColors.goldDim]),
          boxShadow: const [BrokaColors.glowGold],
        ),
        child: const Icon(Icons.psychology_outlined, color: Colors.white, size: 20),
      ),
      const SizedBox(width: 10),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(
          _firstName.isNotEmpty ? 'Hi $_firstName - ZENO' : 'ZENO',
          style: const TextStyle(color: BrokaColors.textHigh,
              fontSize: 15, fontWeight: FontWeight.w800)),
        const Text('Platform Intelligence',
          style: TextStyle(color: BrokaColors.textLow, fontSize: 10)),
      ])),
      // Switch to Zeno button
      GestureDetector(
        onTap: () => Navigator.pushReplacementNamed(context, '/zeno'),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
                colors: [Color(0xFF6A0DAD), Color(0xFF00B4D8)]),
            borderRadius: BorderRadius.circular(10),
            boxShadow: [BoxShadow(
                color: const Color(0xFF6A0DAD).withOpacity(0.4), blurRadius: 8)],
          ),
          child: const Text('ZENO',
              style: TextStyle(color: Colors.white,
                  fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 1.5)),
        ),
      ),
    ]),
  );

  Widget _buildChat() => ListView.builder(
    controller: _scrollCtrl,
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
    itemCount: _messages.length + (_typing ? 1 : 0),
    itemBuilder: (_, i) {
      if (_typing && i == _messages.length) return _typingBubble();
      final msg = _messages[i];
      final isBroker = msg.isBroker;
      final isUser   = msg.role == 'user';
      final shortlist = _shortlists[i];
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Align(
            alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              margin: const EdgeInsets.only(bottom: 12),
              constraints: const BoxConstraints(maxWidth: 290),
              child: Column(
                crossAxisAlignment: isUser
                    ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                children: [
                  Text(isUser
                      ? (_firstName.isNotEmpty ? _firstName.toUpperCase() : 'YOU')
                      : '🤖 ZENO',
                    style: TextStyle(
                      fontSize: 9, fontWeight: FontWeight.w800, letterSpacing: 1.2,
                      color: isUser ? BrokaColors.success : BrokaColors.gold)),
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      gradient: isBroker ? const LinearGradient(
                        colors: [Color(0xFF2A1560), Color(0xFF150A35)]) : null,
                      color: isBroker ? null : BrokaColors.bgCard,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: (isUser
                          ? BrokaColors.success : BrokaColors.gold).withOpacity(0.3)),
                      boxShadow: isBroker ? [BrokaColors.glowGold] : null,
                    ),
                    child: Text(msg.content, style: TextStyle(
                        color: BrokaColors.textHigh, fontSize: 13, height: 1.45)),
                  ),
                ],
              ),
            ),
          ),
          if (shortlist != null && shortlist.isNotEmpty) _buildShortlist(shortlist),
        ],
      );
    },
  );

  Widget _buildShortlist(List<Listing> items) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: SizedBox(
      height: 150,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: items.length,
        itemBuilder: (_, i) {
          final item = items[i];
          return GestureDetector(
            onTap: () => Navigator.pushNamed(context, '/product', arguments: item),
            child: Container(
              width: 130,
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: BrokaColors.bgCard,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: BrokaColors.border),
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(item.emoji, style: const TextStyle(fontSize: 22)),
                const Spacer(),
                Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: BrokaColors.textHigh, fontSize: 11, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(item.formattedPrice,
                    style: const TextStyle(color: BrokaColors.gold, fontSize: 12, fontWeight: FontWeight.bold)),
              ]),
            ),
          );
        },
      ),
    ),
  );

  Widget _typingBubble() => Align(
    alignment: Alignment.centerLeft,
    child: Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [Color(0xFF2A1560), Color(0xFF150A35)]),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: BrokaColors.gold.withOpacity(0.3)),
        boxShadow: const [BrokaColors.glowGold],
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: const [
        SizedBox(width: 16, height: 16,
          child: CircularProgressIndicator(strokeWidth: 1.5,
              color: BrokaColors.gold)),
        SizedBox(width: 10),
        Text('Zeno is thinking...', style: TextStyle(
            color: BrokaColors.gold, fontSize: 12,
            fontStyle: FontStyle.italic)),
      ]),
    ),
  );

  Widget _buildSuggestions() => Container(
    height: 42,
    child: ListView.builder(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: _suggestions.length,
      itemBuilder: (_, i) {
        final (emoji, label) = _suggestions[i];
        return GestureDetector(
          onTap: () => _send(label),
          child: Container(
            margin: const EdgeInsets.only(right: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: BrokaColors.bgCard,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: BrokaColors.border),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Text(emoji, style: const TextStyle(fontSize: 13)),
              const SizedBox(width: 6),
              Text(label, style: TextStyle(
                  color: BrokaColors.textMid, fontSize: 11)),
            ]),
          ),
        );
      },
    ),
  );

  Widget _buildInputBar() => SafeArea(
    top: false,
    child: Container(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
    decoration: BoxDecoration(
      color: BrokaColors.bgMid,
      border: Border(top: BorderSide(color: BrokaColors.border)),
    ),
    child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
      Expanded(child: TextField(
        controller: _msgCtrl,
        style: TextStyle(color: BrokaColors.textHigh, fontSize: 13),
        maxLines: 6,
        minLines: 1,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(
          hintText: _firstName.isNotEmpty
              ? 'Ask anything, $_firstName...'
              : 'Ask Zeno anything...',
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        ),
        onSubmitted: (_) => _send(),
        textInputAction: TextInputAction.newline,
      )),
      const SizedBox(width: 8),
      GestureDetector(
        onTap: () => _send(),
        child: Container(
          width: 46, height: 46,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            gradient: const LinearGradient(
              colors: [BrokaColors.gold, BrokaColors.gold]),
            boxShadow: const [BrokaColors.glowGold],
          ),
          child: const Icon(Icons.send_rounded, size: 18, color: Colors.white),
        ),
      ),
    ]),
  ));
}
