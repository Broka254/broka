// BROKA - AI Dispute Assistant Screen
// Zeno mediates disputes between buyers and sellers.
// Full flow: Form → Zeno Thinking → Verdict + ZAC → Follow-up Chat → Execute → Resolved

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../main.dart';
import '../services/api_service.dart';

enum _DisputeStep { form, thinking, verdict, executing, resolved }

const _issueTypes = {
  'not_delivered':    'Item not delivered',
  'not_as_described': 'Item not as described',
  'payment_issue':    'Payment / M-Pesa issue',
  'fraud':            'Suspected fraud',
  'other':            'Other issue',
};

const _issueIcons = {
  'not_delivered':    Icons.local_shipping_outlined,
  'not_as_described': Icons.image_not_supported_outlined,
  'payment_issue':    Icons.credit_card_off_outlined,
  'fraud':            Icons.gpp_bad_outlined,
  'other':            Icons.help_outline_rounded,
};

class DisputeScreen extends StatefulWidget {
  const DisputeScreen({super.key});
  @override
  State<DisputeScreen> createState() => _DisputeScreenState();
}

class _DisputeScreenState extends State<DisputeScreen>
    with SingleTickerProviderStateMixin {

  // ── Route args ─────────────────────────────────────────────────────────────
  String _dealId      = '';
  String _listingName = '';
  String _receiptCode = '';
  double _amount      = 0;

  // ── State ──────────────────────────────────────────────────────────────────
  _DisputeStep _step          = _DisputeStep.form;
  String?      _selectedIssue;
  String?      _disputeId;
  String?      _verdict;
  String?      _zacCode;
  String?      _resolutionType;
  String?      _errorMsg;
  String?      _resolveMsg;
  bool         _mpesaTriggered = false;
  int          _chatMsgsReviewed = 0;

  // ── Controllers ────────────────────────────────────────────────────────────
  final _descCtrl    = TextEditingController();
  final _receiptCtrl = TextEditingController();   // M-Pesa receipt number
  final _chatCtrl    = TextEditingController();   // Zeno follow-up chat
  late  AnimationController _thinkCtrl;
  final _scrollCtrl  = ScrollController();

  // ── Zeno follow-up chat ────────────────────────────────────────────────────
  final List<_ChatMsg> _zenoChat = [];
  bool _isChatLoading = false;

  @override
  void initState() {
    super.initState();
    _thinkCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1400))
      ..repeat();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final args = ModalRoute.of(context)?.settings.arguments as Map?;
    if (args != null && _dealId.isEmpty) {
      _dealId      = args['dealId']      as String? ?? '';
      _listingName = args['listingName'] as String? ?? '';
      _receiptCode = args['receiptCode'] as String? ?? '';
      _amount      = (args['amount']     as num?)?.toDouble() ?? 0;
      // Pre-fill receipt if passed from deal receipt screen
      if (_receiptCode.isNotEmpty) _receiptCtrl.text = _receiptCode;
    }
  }

  @override
  void dispose() {
    _descCtrl.dispose();
    _receiptCtrl.dispose();
    _chatCtrl.dispose();
    _thinkCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  // ── Actions ────────────────────────────────────────────────────────────────

  Future<void> _submitDispute() async {
    if (_selectedIssue == null) {
      _showSnack('Please select an issue type');
      return;
    }
    if (_descCtrl.text.trim().length < 20) {
      _showSnack('Please describe the issue in at least 20 characters');
      return;
    }
    setState(() { _step = _DisputeStep.thinking; _errorMsg = null; });

    try {
      final opened = await ApiService.openDispute(
        dealId:      _dealId,
        issueType:   _selectedIssue!,
        description: _descCtrl.text.trim(),
      );
      _disputeId = opened['dispute_id'] as String?;

      final mediation = await ApiService.mediateDispute(
        disputeId:    _disputeId!,
        mpesaReceipt: _receiptCtrl.text.trim().isEmpty
            ? null
            : _receiptCtrl.text.trim().toUpperCase(),
      );

      setState(() {
        _verdict          = mediation['verdict']               as String?;
        _zacCode          = mediation['zac_code']              as String?;
        _resolutionType   = mediation['resolution_type']       as String?;
        _chatMsgsReviewed = (mediation['chat_messages_reviewed'] as int?) ?? 0;
        _step             = _DisputeStep.verdict;
      });

      // Scroll to top of verdict
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollCtrl.hasClients) {
          _scrollCtrl.animateTo(0,
              duration: const Duration(milliseconds: 350),
              curve: Curves.easeOut);
        }
      });
    } catch (e) {
      setState(() {
        _errorMsg = e.toString().replaceFirst('Exception: ', '');
        _step     = _DisputeStep.form;
      });
    }
  }

  Future<void> _sendZenoChat() async {
    final msg = _chatCtrl.text.trim();
    if (msg.isEmpty || _disputeId == null) return;

    setState(() {
      _zenoChat.add(_ChatMsg(text: msg, isUser: true));
      _chatCtrl.clear();
      _isChatLoading = true;
    });

    _scrollToBottom();

    try {
      final res = await ApiService.disputeChat(
        disputeId: _disputeId!,
        message:   msg,
      );
      setState(() {
        _zenoChat.add(_ChatMsg(
          text:   res['reply'] as String? ?? '…',
          isUser: false,
        ));
        _isChatLoading = false;
      });
    } catch (e) {
      setState(() {
        _zenoChat.add(_ChatMsg(
          text:   'Error: ${e.toString().replaceFirst("Exception: ", "")}',
          isUser: false,
          isError: true,
        ));
        _isChatLoading = false;
      });
    }

    _scrollToBottom();
  }

  void _scrollToBottom() {
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

  Future<void> _executeResolution() async {
    if (_zacCode == null || _disputeId == null) return;
    setState(() { _step = _DisputeStep.executing; });

    try {
      final result = await ApiService.executeDispute(
        disputeId: _disputeId!,
        zacCode:   _zacCode!,
      );
      setState(() {
        _resolveMsg     = result['message']          as String?;
        _mpesaTriggered = result['mpesa_triggered']  as bool? ?? false;
        _step           = _DisputeStep.resolved;
      });
      HapticFeedback.heavyImpact();
    } catch (e) {
      setState(() {
        _errorMsg = e.toString().replaceFirst('Exception: ', '');
        _step     = _DisputeStep.verdict;
      });
    }
  }

  void _copyZac() {
    if (_zacCode == null) return;
    Clipboard.setData(ClipboardData(text: _zacCode!));
    _showSnack('ZAC code copied to clipboard');
    HapticFeedback.lightImpact();
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: BrokaColors.bgCard,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      appBar: _buildAppBar(),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 350),
        child: _buildBody(),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar() => AppBar(
    backgroundColor: BrokaColors.bg,
    elevation: 0,
    leading: IconButton(
      icon: const Icon(Icons.arrow_back_ios_rounded,
          color: BrokaColors.textMid, size: 18),
      onPressed: () => Navigator.pop(context),
    ),
    title: Row(children: [
      Container(
        padding: const EdgeInsets.all(7),
        decoration: BoxDecoration(
          color: Colors.redAccent.withOpacity(0.12),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Icon(Icons.gavel_rounded,
            color: Colors.redAccent, size: 18),
      ),
      const SizedBox(width: 10),
      const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Dispute Assistant',
            style: TextStyle(color: BrokaColors.textHigh,
                fontSize: 15, fontWeight: FontWeight.w800)),
        Text('Powered by Zeno AI',
            style: TextStyle(color: BrokaColors.gold, fontSize: 10)),
      ]),
    ]),
    bottom: _step != _DisputeStep.thinking && _step != _DisputeStep.executing
        ? PreferredSize(
            preferredSize: const Size.fromHeight(4),
            child: _StepBar(step: _step),
          )
        : null,
  );

  Widget _buildBody() {
    switch (_step) {
      case _DisputeStep.form:      return _buildForm();
      case _DisputeStep.thinking:  return _buildThinking();
      case _DisputeStep.verdict:   return _buildVerdict();
      case _DisputeStep.executing: return _buildExecuting();
      case _DisputeStep.resolved:  return _buildResolved();
    }
  }

  // ── Form ───────────────────────────────────────────────────────────────────

  Widget _buildForm() => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

      // Deal info banner
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: BrokaColors.bgCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: BrokaColors.border),
        ),
        child: Row(children: [
          const Icon(Icons.receipt_long_rounded,
              color: BrokaColors.gold, size: 22),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(_listingName.isNotEmpty ? _listingName : 'BROKA Deal',
                style: const TextStyle(color: BrokaColors.textHigh,
                    fontWeight: FontWeight.w700, fontSize: 13),
                maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 2),
            Text('KES ${_amount.toStringAsFixed(0)}',
                style: const TextStyle(color: BrokaColors.textMid, fontSize: 11)),
          ])),
        ]),
      ),

      const SizedBox(height: 24),
      const Text('What went wrong?',
          style: TextStyle(color: BrokaColors.textHigh,
              fontWeight: FontWeight.w800, fontSize: 16)),
      const SizedBox(height: 12),

      // Issue type selector
      ...(_issueTypes.entries.map((e) => _IssueTypeTile(
        key:      ValueKey(e.key),
        value:    e.key,
        label:    e.value,
        icon:     _issueIcons[e.key]!,
        selected: _selectedIssue == e.key,
        onTap:    () => setState(() => _selectedIssue = e.key),
      ))),

      const SizedBox(height: 24),
      const Text('Describe the issue',
          style: TextStyle(color: BrokaColors.textHigh,
              fontWeight: FontWeight.w800, fontSize: 16)),
      const SizedBox(height: 4),
      const Text('Be specific - what did you pay for, what happened, what evidence do you have?',
          style: TextStyle(color: BrokaColors.textLow, fontSize: 11, height: 1.4)),
      const SizedBox(height: 10),
      Container(
        decoration: BoxDecoration(
          color: BrokaColors.bgCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: BrokaColors.border),
        ),
        child: TextField(
          controller: _descCtrl,
          style: const TextStyle(color: BrokaColors.textHigh, fontSize: 13),
          maxLines: 5,
          maxLength: 600,
          decoration: const InputDecoration(
            hintText: 'e.g. I paid KES 3,500 on Monday but the seller stopped responding. '
                'They agreed via chat to deliver by Wednesday. No delivery, no refund.',
            hintStyle: TextStyle(color: BrokaColors.textLow, fontSize: 12, height: 1.5),
            border: InputBorder.none,
            contentPadding: EdgeInsets.all(14),
            counterStyle: TextStyle(color: BrokaColors.textLow, fontSize: 10),
          ),
        ),
      ),

      const SizedBox(height: 20),
      const Text('M-Pesa Receipt Code (optional but recommended)',
          style: TextStyle(color: BrokaColors.textHigh,
              fontWeight: FontWeight.w800, fontSize: 15)),
      const SizedBox(height: 4),
      const Text(
        'Found in your M-Pesa SMS - starts with a letter e.g. QJL82XXXXXX. '
        'Zeno will use this as evidence.',
        style: TextStyle(color: BrokaColors.textLow, fontSize: 11, height: 1.4),
      ),
      const SizedBox(height: 10),
      Container(
        decoration: BoxDecoration(
          color: BrokaColors.bgCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: BrokaColors.border),
        ),
        child: TextField(
          controller: _receiptCtrl,
          style: const TextStyle(
              color: BrokaColors.textHigh,
              fontSize: 15,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.5,
              fontFamily: 'monospace'),
          textCapitalization: TextCapitalization.characters,
          maxLength: 14,
          decoration: const InputDecoration(
            hintText: 'e.g. QJL82XXXXXX',
            hintStyle: TextStyle(color: BrokaColors.textLow,
                fontSize: 13, letterSpacing: 0.5, fontWeight: FontWeight.w400),
            prefixIcon: Icon(Icons.receipt_rounded,
                color: BrokaColors.textLow, size: 18),
            border: InputBorder.none,
            contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            counterStyle: TextStyle(color: BrokaColors.textLow, fontSize: 10),
          ),
        ),
      ),

      if (_errorMsg != null) ...[
        const SizedBox(height: 12),
        _ErrorBanner(message: _errorMsg!),
      ],

      const SizedBox(height: 24),
      SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          onPressed: _submitDispute,
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.redAccent,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14)),
            elevation: 0,
          ),
          icon: const Icon(Icons.smart_toy_rounded, size: 18),
          label: const Text('Ask Zeno to Mediate',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14)),
        ),
      ),

      const SizedBox(height: 16),
      const _DisclaimerNote(),
    ]),
  );

  // ── Thinking ───────────────────────────────────────────────────────────────

  Widget _buildThinking() => Center(
    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      AnimatedBuilder(
        animation: _thinkCtrl,
        builder: (_, __) => Stack(alignment: Alignment.center, children: [
          for (int i = 0; i < 3; i++)
            Opacity(
              opacity: ((_thinkCtrl.value + i * 0.33) % 1.0).clamp(0.05, 0.5),
              child: Container(
                width: 60.0 + i * 30, height: 60.0 + i * 30,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: BrokaColors.gold, width: 1.5),
                ),
              ),
            ),
          Container(
            width: 60, height: 60,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(colors: [
                BrokaColors.gold.withOpacity(0.3),
                BrokaColors.gold.withOpacity(0.05),
              ]),
            ),
            child: const Icon(Icons.smart_toy_rounded,
                color: BrokaColors.gold, size: 28),
          ),
        ]),
      ),
      const SizedBox(height: 32),
      const Text('Zeno is reviewing your case…',
          style: TextStyle(color: BrokaColors.textHigh,
              fontSize: 17, fontWeight: FontWeight.w700)),
      const SizedBox(height: 10),
      const Text(
        'Reading your negotiation chat history,\npayment records, and marketplace policy.',
        style: TextStyle(color: BrokaColors.textMid, fontSize: 12, height: 1.6),
        textAlign: TextAlign.center,
      ),
    ]),
  );

  // ── Verdict ────────────────────────────────────────────────────────────────

  Widget _buildVerdict() {
    final resColor = _resolutionType == 'refund'
        ? Colors.orange
        : _resolutionType == 'release'
            ? BrokaColors.neonGreen
            : BrokaColors.neonBlue;

    return SingleChildScrollView(
      controller: _scrollCtrl,
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [

        // Zeno evidence notice
        if (_chatMsgsReviewed > 0)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: BrokaColors.gold.withOpacity(0.07),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: BrokaColors.gold.withOpacity(0.2)),
            ),
            child: Row(children: [
              const Icon(Icons.chat_bubble_outline_rounded,
                  color: BrokaColors.gold, size: 14),
              const SizedBox(width: 8),
              Text(
                'Zeno reviewed $_chatMsgsReviewed negotiation messages',
                style: const TextStyle(color: BrokaColors.gold,
                    fontSize: 11, fontWeight: FontWeight.w600),
              ),
            ]),
          ),

        // Verdict card
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            gradient: LinearGradient(colors: [
              BrokaColors.gold.withOpacity(0.08),
              BrokaColors.bgCard,
            ], begin: Alignment.topLeft, end: Alignment.bottomRight),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: BrokaColors.gold.withOpacity(0.3)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: BrokaColors.gold.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.smart_toy_rounded,
                    color: BrokaColors.gold, size: 20),
              ),
              const SizedBox(width: 10),
              const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text("Zeno's Verdict",
                    style: TextStyle(color: BrokaColors.textHigh,
                        fontWeight: FontWeight.w800, fontSize: 14)),
                Text('AI-powered mediation',
                    style: TextStyle(color: BrokaColors.gold, fontSize: 10)),
              ]),
              const Spacer(),
              // Resolution badge
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: resColor.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: resColor.withOpacity(0.4)),
                ),
                child: Text(
                  (_resolutionType ?? 'split').toUpperCase(),
                  style: TextStyle(
                      color: resColor,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.8),
                ),
              ),
            ]),
            const SizedBox(height: 16),
            _VerdictText(text: _verdict ?? ''),
          ]),
        ),

        const SizedBox(height: 20),

        // ZAC code block
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: resColor.withOpacity(0.06),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: resColor.withOpacity(0.4), width: 1.5),
          ),
          child: Column(children: [
            Row(children: [
              Icon(Icons.vpn_key_rounded, color: resColor, size: 20),
              const SizedBox(width: 10),
              Text('Zeno Authorization Code',
                  style: TextStyle(color: resColor,
                      fontWeight: FontWeight.w800, fontSize: 13)),
              const Spacer(),
              GestureDetector(
                onTap: _copyZac,
                child: Row(children: [
                  Icon(Icons.copy_rounded,
                      color: resColor.withOpacity(0.7), size: 16),
                  const SizedBox(width: 4),
                  Text('Copy', style: TextStyle(
                      color: resColor.withOpacity(0.7),
                      fontSize: 11, fontWeight: FontWeight.w600)),
                ]),
              ),
            ]),
            const SizedBox(height: 14),
            GestureDetector(
              onTap: _copyZac,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
                decoration: BoxDecoration(
                  color: BrokaColors.bg,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: resColor.withOpacity(0.3)),
                ),
                child: Text(
                  _zacCode ?? '',
                  style: TextStyle(
                      color: resColor,
                      fontSize: 22, fontWeight: FontWeight.w900,
                      letterSpacing: 3.0,
                      fontFamily: 'monospace'),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              _resolutionType == 'refund'
                  ? 'This code authorizes a refund to the buyer.'
                  : _resolutionType == 'release'
                      ? 'This code releases payment to the seller.'
                      : 'This code authorizes a split resolution.',
              style: TextStyle(color: resColor.withOpacity(0.8), fontSize: 11),
              textAlign: TextAlign.center,
            ),
          ]),
        ),

        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: BrokaColors.bgCard,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: BrokaColors.border),
          ),
          child: const Row(children: [
            Icon(Icons.info_outline_rounded, color: BrokaColors.textLow, size: 14),
            SizedBox(width: 8),
            Expanded(child: Text(
              'This code is single-use and expires in 24 hours. '
              'Tap "Execute" to trigger the M-Pesa refund or payment release.',
              style: TextStyle(color: BrokaColors.textLow, fontSize: 11, height: 1.5),
            )),
          ]),
        ),

        // ── Zeno Follow-up Chat ────────────────────────────────────────────
        const SizedBox(height: 28),
        const _SectionDivider(label: 'Ask Zeno a Follow-up Question'),
        const SizedBox(height: 12),

        if (_zenoChat.isEmpty)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: BrokaColors.bgCard,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: BrokaColors.border),
            ),
            child: const Text(
              'Not sure about the verdict? Ask Zeno to explain or clarify. '
              'Examples: "Why was it a refund?" • "What if I return the item?" • "What happens next?"',
              style: TextStyle(color: BrokaColors.textLow, fontSize: 12, height: 1.5),
            ),
          ),

        // Chat bubbles
        ..._zenoChat.map((m) => _ChatBubble(msg: m)),

        if (_isChatLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: _ZenoDotLoader(),
          ),

        const SizedBox(height: 8),

        // Chat input
        Row(children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: BrokaColors.bgCard,
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: BrokaColors.border),
              ),
              child: TextField(
                controller: _chatCtrl,
                style: const TextStyle(color: BrokaColors.textHigh, fontSize: 13),
                maxLines: 2,
                minLines: 1,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  hintText: 'Ask Zeno anything about this case…',
                  hintStyle: TextStyle(color: BrokaColors.textLow, fontSize: 12),
                  border: InputBorder.none,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                ),
                onSubmitted: (_) => _sendZenoChat(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _isChatLoading ? null : _sendZenoChat,
            child: Container(
              width: 44, height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _isChatLoading
                    ? BrokaColors.border
                    : BrokaColors.gold,
              ),
              child: const Icon(Icons.send_rounded,
                  color: Colors.white, size: 18),
            ),
          ),
        ]),

        if (_errorMsg != null) ...[
          const SizedBox(height: 12),
          _ErrorBanner(message: _errorMsg!),
        ],

        const SizedBox(height: 28),

        // Execute button
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _executeResolution,
            style: ElevatedButton.styleFrom(
              backgroundColor: resColor,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
              elevation: 0,
            ),
            icon: const Icon(Icons.check_circle_outline_rounded, size: 18),
            label: Text(
              _resolutionType == 'refund'  ? 'Execute - Issue Refund'     :
              _resolutionType == 'release' ? 'Execute - Release Payment'  :
                                             'Execute - Split Resolution',
              style: const TextStyle(
                  fontWeight: FontWeight.w800, fontSize: 14)),
          ),
        ),
      ]),
    );
  }

  // ── Executing ──────────────────────────────────────────────────────────────

  Widget _buildExecuting() => Center(
    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      const CircularProgressIndicator(color: BrokaColors.neonGreen),
      const SizedBox(height: 24),
      const Text('Executing resolution…',
          style: TextStyle(color: BrokaColors.textHigh,
              fontSize: 16, fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      const Text('Triggering M-Pesa - do not close this screen.',
          style: TextStyle(color: BrokaColors.textMid, fontSize: 12)),
    ]),
  );

  // ── Resolved ───────────────────────────────────────────────────────────────

  Widget _buildResolved() {
    final resColor = _resolutionType == 'refund'
        ? Colors.orange
        : _resolutionType == 'release'
            ? BrokaColors.neonGreen
            : BrokaColors.neonBlue;

    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Container(
            width: 80, height: 80,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: resColor.withOpacity(0.12),
              border: Border.all(color: resColor.withOpacity(0.4), width: 2),
            ),
            child: Icon(
              _resolutionType == 'refund'
                  ? Icons.currency_exchange_rounded
                  : _resolutionType == 'release'
                      ? Icons.check_circle_outline_rounded
                      : Icons.balance_rounded,
              color: resColor, size: 38,
            ),
          ),
          const SizedBox(height: 24),
          const Text('Dispute Resolved',
              style: TextStyle(color: BrokaColors.textHigh,
                  fontSize: 22, fontWeight: FontWeight.w900)),
          const SizedBox(height: 12),
          Text(
            _resolveMsg ?? 'The resolution has been executed successfully.',
            style: const TextStyle(color: BrokaColors.textMid,
                fontSize: 13, height: 1.6),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),

          // M-Pesa status indicator
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: BrokaColors.bgCard,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: BrokaColors.border),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(
                _mpesaTriggered
                    ? Icons.mobile_friendly_rounded
                    : Icons.schedule_rounded,
                color: _mpesaTriggered
                    ? BrokaColors.neonGreen
                    : BrokaColors.textMid,
                size: 16,
              ),
              const SizedBox(width: 8),
              Text(
                _mpesaTriggered
                    ? 'M-Pesa payment triggered'
                    : 'Payment will be processed manually within 24h',
                style: TextStyle(
                    color: _mpesaTriggered
                        ? BrokaColors.neonGreen
                        : BrokaColors.textMid,
                    fontSize: 11,
                    fontWeight: FontWeight.w600),
              ),
            ]),
          ),

          const SizedBox(height: 8),
          Text(
            'ZAC: ${_zacCode ?? ""}',
            style: const TextStyle(color: BrokaColors.textLow,
                fontSize: 10, fontFamily: 'monospace'),
          ),
          const SizedBox(height: 32),
          ElevatedButton(
            onPressed: () => Navigator.popUntil(context, (r) => r.isFirst),
            style: ElevatedButton.styleFrom(
              backgroundColor: BrokaColors.bgCard,
              foregroundColor: BrokaColors.textHigh,
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Back to Home',
                style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ]),
      ),
    );
  }
}

// ── Sub-widgets ────────────────────────────────────────────────────────────────

class _StepBar extends StatelessWidget {
  final _DisputeStep step;
  const _StepBar({required this.step});

  @override
  Widget build(BuildContext context) {
    final steps = [
      _DisputeStep.form,
      _DisputeStep.verdict,
      _DisputeStep.resolved,
    ];
    final idx = steps.indexOf(step).clamp(0, steps.length - 1);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: List.generate(steps.length * 2 - 1, (i) {
          if (i.isOdd) {
            // Connector
            final filled = (i ~/ 2) < idx;
            return Expanded(
              child: Container(
                height: 2,
                color: filled
                    ? BrokaColors.gold
                    : BrokaColors.border,
              ),
            );
          }
          final si = i ~/ 2;
          final done    = si < idx;
          final current = si == idx;
          final labels  = ['File', 'Verdict', 'Resolved'];
          final color   = done || current
              ? BrokaColors.gold
              : BrokaColors.textLow;
          return Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 18, height: 18,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: done
                    ? BrokaColors.gold
                    : current
                        ? BrokaColors.gold.withOpacity(0.2)
                        : BrokaColors.bgCard,
                border: Border.all(
                    color: color,
                    width: current ? 2 : 1.5),
              ),
              child: done
                  ? const Icon(Icons.check_rounded,
                      color: Colors.white, size: 10)
                  : null,
            ),
            const SizedBox(height: 2),
            Text(labels[si],
                style: TextStyle(color: color,
                    fontSize: 9, fontWeight: FontWeight.w600)),
          ]);
        }),
      ),
    );
  }
}

class _IssueTypeTile extends StatelessWidget {
  final String value, label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const _IssueTypeTile({
    super.key,
    required this.value, required this.label, required this.icon,
    required this.selected, required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = value == 'fraud' ? Colors.redAccent : BrokaColors.gold;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color:  selected ? color.withOpacity(0.12) : BrokaColors.bgCard,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? color.withOpacity(0.6) : BrokaColors.border,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(children: [
          Icon(icon, color: selected ? color : BrokaColors.textLow, size: 20),
          const SizedBox(width: 12),
          Text(label, style: TextStyle(
              color: selected ? color : BrokaColors.textMid,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              fontSize: 13)),
          const Spacer(),
          if (selected)
            Icon(Icons.check_circle_rounded, color: color, size: 18),
        ]),
      ),
    );
  }
}

class _VerdictText extends StatelessWidget {
  final String text;
  const _VerdictText({required this.text});

  @override
  Widget build(BuildContext context) {
    final lines = text.split('\n');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: lines.map((line) {
        final isBold = line.startsWith('**') && line.endsWith('**');
        final clean  = line.replaceAll('**', '');
        if (clean.trim().isEmpty) return const SizedBox(height: 6);
        if (line.startsWith('📋') || line.startsWith('🚨')) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(clean,
                style: const TextStyle(
                    color: BrokaColors.gold,
                    fontWeight: FontWeight.w800, fontSize: 13)),
          );
        }
        if (line.startsWith('⚠️')) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(clean,
                style: const TextStyle(
                    color: Colors.orange,
                    fontWeight: FontWeight.w600, fontSize: 12, height: 1.5)),
          );
        }
        return Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text(clean,
              style: TextStyle(
                  color: isBold ? BrokaColors.textHigh : BrokaColors.textMid,
                  fontWeight: isBold ? FontWeight.w700 : FontWeight.w400,
                  fontSize: 12, height: 1.5)),
        );
      }).toList(),
    );
  }
}

// ── Chat bubble model ─────────────────────────────────────────────────────────

class _ChatMsg {
  final String text;
  final bool   isUser;
  final bool   isError;
  const _ChatMsg({required this.text, required this.isUser, this.isError = false});
}

class _ChatBubble extends StatelessWidget {
  final _ChatMsg msg;
  const _ChatBubble({required this.msg});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        top: 6, bottom: 6,
        left: msg.isUser ? 48 : 0,
        right: msg.isUser ? 0 : 48,
      ),
      child: Align(
        alignment: msg.isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          decoration: BoxDecoration(
            color: msg.isError
                ? Colors.redAccent.withOpacity(0.1)
                : msg.isUser
                    ? BrokaColors.gold.withOpacity(0.12)
                    : BrokaColors.bgCard,
            borderRadius: BorderRadius.only(
              topLeft:     const Radius.circular(16),
              topRight:    const Radius.circular(16),
              bottomLeft:  Radius.circular(msg.isUser ? 16 : 4),
              bottomRight: Radius.circular(msg.isUser ? 4 : 16),
            ),
            border: Border.all(
              color: msg.isError
                  ? Colors.redAccent.withOpacity(0.3)
                  : msg.isUser
                      ? BrokaColors.gold.withOpacity(0.3)
                      : BrokaColors.border,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!msg.isUser) ...[
                const Icon(Icons.smart_toy_rounded,
                    color: BrokaColors.gold, size: 14),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(msg.text,
                    style: TextStyle(
                        color: msg.isError
                            ? Colors.redAccent
                            : BrokaColors.textHigh,
                        fontSize: 12, height: 1.5)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ZenoDotLoader extends StatefulWidget {
  const _ZenoDotLoader();
  @override
  State<_ZenoDotLoader> createState() => _ZenoDotLoaderState();
}

class _ZenoDotLoaderState extends State<_ZenoDotLoader>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat();
  }

  @override
  void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: BrokaColors.bgCard,
          borderRadius: const BorderRadius.only(
            topLeft:     Radius.circular(16),
            topRight:    Radius.circular(16),
            bottomRight: Radius.circular(16),
            bottomLeft:  Radius.circular(4),
          ),
          border: Border.all(color: BrokaColors.border),
        ),
        child: AnimatedBuilder(
          animation: _ctrl,
          builder: (_, __) => Row(
            mainAxisSize: MainAxisSize.min,
            children: List.generate(3, (i) {
              final opacity = (((_ctrl.value * 3 - i) % 1).abs() < 0.5)
                  ? 1.0 : 0.3;
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Opacity(
                  opacity: opacity.clamp(0.3, 1.0),
                  child: Container(
                    width: 6, height: 6,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: BrokaColors.gold,
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

class _SectionDivider extends StatelessWidget {
  final String label;
  const _SectionDivider({required this.label});

  @override
  Widget build(BuildContext context) => Row(children: [
    Expanded(child: Divider(color: BrokaColors.border, height: 1)),
    Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Text(label, style: const TextStyle(
          color: BrokaColors.textLow,
          fontSize: 11, fontWeight: FontWeight.w600)),
    ),
    Expanded(child: Divider(color: BrokaColors.border, height: 1)),
  ]);
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner({required this.message});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Colors.redAccent.withOpacity(0.1),
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: Colors.redAccent.withOpacity(0.3)),
    ),
    child: Row(children: [
      const Icon(Icons.error_outline_rounded, color: Colors.redAccent, size: 16),
      const SizedBox(width: 8),
      Expanded(child: Text(message,
          style: const TextStyle(color: Colors.redAccent,
              fontSize: 12, height: 1.4))),
    ]),
  );
}

class _DisclaimerNote extends StatelessWidget {
  const _DisclaimerNote();
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: BrokaColors.bgCard,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: BrokaColors.border),
    ),
    child: const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(Icons.shield_outlined, color: BrokaColors.gold, size: 14),
      SizedBox(width: 8),
      Expanded(child: Text(
        "Zeno's verdicts are AI-generated and based on BROKA marketplace policy. "
        'For fraud cases, a human reviewer will verify within 24 hours. '
        'ZAC codes are cryptographically signed and single-use.',
        style: TextStyle(color: BrokaColors.textLow, fontSize: 10, height: 1.5),
      )),
    ]),
  );
}
