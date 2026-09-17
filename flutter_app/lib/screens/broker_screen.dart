import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import '../main.dart';
import '../services/api_service.dart';
import '../models/models.dart';
import '../models/listing.dart';
import '../widgets/zeno_avatar.dart';

// ── AI Thinking States ────────────────────────────────────────────────────────
const _thinkingStates = [
  'Analysing pricing...',
  'Comparing market rates...',
  'Checking trust score...',
  'Searching nearby buyers...',
  'Detecting fraud risk...',
  'Calculating fair value...',
  'Reviewing offer history...',
  'Optimising deal terms...',
];

class BrokerScreen extends StatefulWidget {
  const BrokerScreen({super.key});
  @override
  State<BrokerScreen> createState() => _BrokerScreenState();
}

class _BrokerScreenState extends State<BrokerScreen>
    with TickerProviderStateMixin {
  final _msgCtrl    = TextEditingController();
  final _scrollCtrl = ScrollController();

  bool   _brokerTyping   = false;
  String _thinkingLabel  = _thinkingStates[0];
  int    _thinkingIndex  = 0;
  Timer? _thinkingTimer;

  List<Message>               _messages = [];
  List<Map<String, String>>   _history  = [];
  Listing?                    _listing;

  // Deal probability (0-100)
  double _dealProbability = 50;

  // Typing-indicator dot animation
  late AnimationController _dotCtrl;
  late Animation<double>   _dot1, _dot2, _dot3;

  @override
  void initState() {
    super.initState();
    _dotCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();

    _dot1 = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _dotCtrl,
          curve: const Interval(0.0, 0.6, curve: Curves.easeInOut)));
    _dot2 = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _dotCtrl,
          curve: const Interval(0.2, 0.8, curve: Curves.easeInOut)));
    _dot3 = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _dotCtrl,
          curve: const Interval(0.4, 1.0, curve: Curves.easeInOut)));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_listing == null && _messages.isEmpty) {
      final args = ModalRoute.of(context)?.settings.arguments;
      if (args is Map) {
        final listingArg = args['listing'];
        if (listingArg is Listing) {
          _listing = listingArg;
        } else if (listingArg is Map) {
          _listing = Listing.fromJson(Map<String, dynamic>.from(listingArg));
        }
      } else if (args is Listing) {
        _listing = args;
      }
      _initChat();
    }
  }

  @override
  void dispose() {
    _dotCtrl.dispose();
    _thinkingTimer?.cancel();
    _scrollCtrl.dispose();
    _msgCtrl.dispose();
    super.dispose();
  }

  void _initChat() {
    final greeting = _listing != null
        ? 'Hello! I\'m your BROKA AI Broker 🤖\n\n'
          'I\'m here to help negotiate a fair deal for '
          '**${_listing!.name}** (${_listing!.formattedPrice}).\n\n'
          'What would you like to discuss?'
        : 'Hello! I\'m your BROKA AI Broker 🤖\n\n'
          'I can help you with:\n'
          '• Negotiating a fair price for any listing\n'
          '• Market insights and pricing advice\n'
          '• Buyer/seller strategy tips\n'
          '• Any marketplace question\n\n'
          'What\'s on your mind?';
    setState(() => _messages = [Message(role: 'broker', content: greeting)]);
  }

  // ── Thinking state cycling ─────────────────────────────────────────────────
  void _startThinking() {
    setState(() {
      _brokerTyping  = true;
      _thinkingIndex = 0;
      _thinkingLabel = _thinkingStates[0];
    });
    _thinkingTimer = Timer.periodic(const Duration(milliseconds: 1800), (_) {
      if (!mounted) return;
      setState(() {
        _thinkingIndex = (_thinkingIndex + 1) % _thinkingStates.length;
        _thinkingLabel = _thinkingStates[_thinkingIndex];
      });
    });
  }

  void _stopThinking() {
    _thinkingTimer?.cancel();
    _thinkingTimer = null;
    if (mounted) setState(() => _brokerTyping = false);
  }

  // ── Deal probability heuristic ─────────────────────────────────────────────
  void _updateDealProbability(String brokerReply) {
    final lower = brokerReply.toLowerCase();
    double delta = 0;
    if (lower.contains('agree') || lower.contains('deal') ||
        lower.contains('accepted') || lower.contains('congratulations')) {
      delta = 15;
    } else if (lower.contains('close') || lower.contains('fair') ||
        lower.contains('reasonable')) {
      delta = 8;
    } else if (lower.contains('far apart') || lower.contains('disagree') ||
        lower.contains('concern')) {
      delta = -5;
    }
    setState(() {
      _dealProbability = (_dealProbability + delta).clamp(10, 98);
    });
  }

  // ── Send message ───────────────────────────────────────────────────────────
  Future<void> _send() async {
    final text = _msgCtrl.text.trim();
    if (text.isEmpty) return;

    setState(() => _messages.add(Message(role: 'user', content: text)));
    _msgCtrl.clear();
    _scrollDown();
    _startThinking();

    try {
      final historyToSend = List<Map<String, String>>.from(_history);

      final contentToSend = _listing != null && historyToSend.isEmpty
          ? '[Listing: ${_listing!.name}, Price: ${_listing!.formattedPrice}, '
            'Location: ${_listing!.locationName ?? "Kenya"}]\n$text'
          : text;

      final reply = await ApiService.freeChat(
        content: contentToSend,
        history: historyToSend,
      );

      _history
        ..add({'role': 'user', 'content': text})
        ..add({'role': 'assistant', 'content': reply.content});

      _updateDealProbability(reply.content);

      if (mounted) setState(() => _messages.add(reply));
      _scrollDown();
    } catch (e) {
      if (mounted) {
        setState(() => _messages.add(Message(
          role: 'broker',
          content: '⚠️ Network issue - please retry.',
        )));
      }
    } finally {
      _stopThinking();
    }
  }

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent + 80,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ── Build ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      resizeToAvoidBottomInset: true,
      appBar: _buildAppBar(),
      body: Column(
        children: [
          if (_listing != null) _buildListingBanner(),
          _buildDealProbabilityBar(),
          Expanded(child: _buildMessageList()),
          if (_brokerTyping) _buildThinkingIndicator(),
          _buildInputBar(),
        ],
      ),
    );
  }

  AppBar _buildAppBar() => AppBar(
    backgroundColor: BrokaColors.bgMid,
    leading: IconButton(
      icon: const Icon(Icons.arrow_back_ios_new_rounded,
          color: BrokaColors.textMid, size: 18),
      onPressed: () => Navigator.pop(context),
    ),
    title: Row(
      children: [
        const ZenoAvatar(size: 32, glow: true),
        const SizedBox(width: 10),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('BROKA AI',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800,
                    color: BrokaColors.textHigh)),
            Text(_brokerTyping ? 'thinking...' : 'online',
                style: TextStyle(
                    fontSize: 11,
                    color: _brokerTyping
                        ? BrokaColors.gold
                        : BrokaColors.neonGreen)),
          ],
        ),
      ],
    ),
    actions: [
      IconButton(
        icon: const Icon(Icons.refresh_rounded,
            color: BrokaColors.textMid, size: 20),
        onPressed: () => setState(() {
          _messages.clear();
          _history.clear();
          _dealProbability = 50;
          _initChat();
        }),
        tooltip: 'New conversation',
      ),
      const SizedBox(width: 4),
    ],
  );

  Widget _buildListingBanner() => Container(
    margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        colors: [Color(0xFF1A0F3D), Color(0xFF0D0728)],
      ),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: BrokaColors.border),
    ),
    child: Row(
      children: [
        Text(_listing!.emoji, style: const TextStyle(fontSize: 20)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_listing!.name,
                  style: const TextStyle(
                      color: BrokaColors.textHigh,
                      fontWeight: FontWeight.w700, fontSize: 13),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              Text(_listing!.formattedPrice,
                  style: const TextStyle(
                      color: BrokaColors.neonGreen,
                      fontWeight: FontWeight.w800, fontSize: 12)),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: BrokaColors.gold.withOpacity(0.12),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: BrokaColors.gold.withOpacity(0.3)),
          ),
          child: Text(_listing!.listingType.toUpperCase(),
              style: const TextStyle(
                  color: BrokaColors.gold,
                  fontSize: 9, fontWeight: FontWeight.w800,
                  letterSpacing: 0.8)),
        ),
      ],
    ),
  );

  Widget _buildDealProbabilityBar() => Container(
    margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      color: BrokaColors.bgCard,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: BrokaColors.border),
    ),
    child: Row(
      children: [
        const Icon(Icons.show_chart_rounded,
            color: BrokaColors.neonGreen, size: 16),
        const SizedBox(width: 8),
        const Text('Deal probability',
            style: TextStyle(color: BrokaColors.textMid, fontSize: 11)),
        const Spacer(),
        Text('${_dealProbability.toStringAsFixed(0)}%',
            style: TextStyle(
              color: _dealProbability >= 70
                  ? BrokaColors.neonGreen
                  : _dealProbability >= 40
                      ? BrokaColors.warning
                      : BrokaColors.danger,
              fontWeight: FontWeight.w800,
              fontSize: 13,
            )),
        const SizedBox(width: 10),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: _dealProbability / 100,
              minHeight: 6,
              backgroundColor: BrokaColors.border,
              valueColor: AlwaysStoppedAnimation(
                _dealProbability >= 70
                    ? BrokaColors.neonGreen
                    : _dealProbability >= 40
                        ? BrokaColors.warning
                        : BrokaColors.danger,
              ),
            ),
          ),
        ),
      ],
    ),
  );

  Widget _buildMessageList() => ListView.builder(
    controller: _scrollCtrl,
    padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
    itemCount: _messages.length,
    itemBuilder: (_, i) => _MessageBubble(message: _messages[i]),
  );

  Widget _buildThinkingIndicator() => Container(
    margin: const EdgeInsets.fromLTRB(12, 0, 12, 4),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      color: BrokaColors.bgCard,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: BrokaColors.gold.withOpacity(0.3)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedBuilder(
          animation: _dotCtrl,
          builder: (_, __) => Row(
            children: [
              _Dot(opacity: _dot1.value),
              const SizedBox(width: 4),
              _Dot(opacity: _dot2.value),
              const SizedBox(width: 4),
              _Dot(opacity: _dot3.value),
            ],
          ),
        ),
        const SizedBox(width: 10),
        Text(_thinkingLabel,
            style: const TextStyle(
                color: BrokaColors.gold,
                fontSize: 12, fontStyle: FontStyle.italic)),
      ],
    ),
  );

  Widget _buildInputBar() => SafeArea(
    top: false,
    child: Container(
    padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
    decoration: BoxDecoration(
      color: BrokaColors.bgMid,
      border: const Border(top: BorderSide(color: BrokaColors.border)),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: BrokaColors.bgCard,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(color: BrokaColors.border),
            ),
            child: TextField(
              controller: _msgCtrl,
              style: const TextStyle(color: BrokaColors.textHigh, fontSize: 14),
              maxLines: 6,
              minLines: 1,
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                hintText: 'Message BROKA...',
                hintStyle: TextStyle(color: BrokaColors.textLow, fontSize: 14),
                border: InputBorder.none,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: _brokerTyping ? null : _send,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 46, height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: _brokerTyping
                    ? [BrokaColors.textLow, BrokaColors.textLow]
                    : [BrokaColors.gold, BrokaColors.neonBlue],
              ),
              boxShadow: _brokerTyping
                  ? []
                  : [
                      BoxShadow(
                          color: BrokaColors.gold.withOpacity(0.4),
                          blurRadius: 12),
                    ],
            ),
            child: const Icon(Icons.send_rounded, color: Colors.white, size: 20),
          ),
        ),
      ],
    ),
  ));
}

// ── Message Bubble ─────────────────────────────────────────────────────────────
class _MessageBubble extends StatelessWidget {
  final Message message;
  const _MessageBubble({required this.message});

  @override
  Widget build(BuildContext context) {
    final isBroker = message.isBroker;
    final isUser   = !isBroker;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (isBroker) ...[
            _BrokerAvatar(),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.78),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                gradient: isBroker
                    ? const LinearGradient(
                        colors: [Color(0xFF1A0F3D), Color(0xFF0D0728)],
                        begin: Alignment.topLeft, end: Alignment.bottomRight)
                    : const LinearGradient(
                        colors: [BrokaColors.gold, BrokaColors.goldDim],
                        begin: Alignment.topLeft, end: Alignment.bottomRight),
                borderRadius: BorderRadius.only(
                  topLeft:     const Radius.circular(18),
                  topRight:    const Radius.circular(18),
                  bottomLeft:  Radius.circular(isBroker ? 4 : 18),
                  bottomRight: Radius.circular(isUser  ? 4 : 18),
                ),
                border: isBroker
                    ? Border.all(color: BrokaColors.gold.withOpacity(0.2))
                    : null,
                boxShadow: [
                  BoxShadow(
                    color: (isBroker
                            ? BrokaColors.gold
                            : BrokaColors.gold)
                        .withOpacity(0.2),
                    blurRadius: 8, offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: _buildContent(),
            ),
          ),
          if (isUser) const SizedBox(width: 4),
        ],
      ),
    );
  }

  Widget _buildContent() {
    final text  = message.content;
    final spans = <TextSpan>[];
    final regex = RegExp(r'\*\*(.+?)\*\*');
    int   last  = 0;

    for (final m in regex.allMatches(text)) {
      if (m.start > last) {
        spans.add(TextSpan(
            text: text.substring(last, m.start),
            style: const TextStyle(
                color: BrokaColors.textHigh, fontSize: 14, height: 1.5)));
      }
      spans.add(TextSpan(
          text: m.group(1),
          style: const TextStyle(
              color: BrokaColors.gold,
              fontWeight: FontWeight.w700,
              fontSize: 14, height: 1.5)));
      last = m.end;
    }
    if (last < text.length) {
      spans.add(TextSpan(
          text: text.substring(last),
          style: const TextStyle(
              color: BrokaColors.textHigh, fontSize: 14, height: 1.5)));
    }

    return RichText(text: TextSpan(children: spans));
  }
}

class _BrokerAvatar extends StatelessWidget {
  @override
  Widget build(BuildContext context) => const ZenoAvatar(size: 28, glow: true);
}

class _Dot extends StatelessWidget {
  final double opacity;
  const _Dot({required this.opacity});

  @override
  Widget build(BuildContext context) => Opacity(
    opacity: opacity.clamp(0.3, 1.0),
    child: Container(
      width: 6, height: 6,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: BrokaColors.gold,
      ),
    ),
  );
}
