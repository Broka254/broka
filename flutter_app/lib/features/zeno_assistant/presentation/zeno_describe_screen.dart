// Zeno writing a listing's description with the seller (2026-10-06) -
// opened from the sell wizard's Description step when Zeno's look at the
// photo left out things a buyer needs to know that a photo can't show
// (battery health, mileage, a title deed).
//
// What buyers will read is "Label: value" lines - "RAM: 4 GB", not "It has a
// RAM of 4 GB" - shown as a card under Zeno's latest message and filled in
// as the seller answers. Each answer goes back to Zeno (backend
// selling.describe_turn), which folds it in and says what is still open;
// that is free, only the look at the photo was counted. "Use this
// description" - or Back - closes the screen with it, any question still
// open as a blank "Label: " line for the seller to fill in the description
// box. Nothing is listed from here.
//
// A conversation about a draft that isn't saved anywhere isn't saved
// either: it lives as long as this screen.
import 'package:flutter/material.dart';

import '../../../core/network/api_client.dart';
import '../../../main.dart';
import '../../../services/api_service.dart';
import '../../../services/sell_wizard_data.dart';
import '../../../widgets/chat_parts.dart';
import '../../../widgets/constellation_background.dart';
import '../../../widgets/zeno_avatar.dart';
import '../../premium/presentation/premium_upsell.dart';
import '../data/zeno_selling_repository.dart';
import '../domain/zeno_selling.dart';

class _DescribeMessage {
  _DescribeMessage.user(this.text)
      : fromZeno = false,
        turn = null;
  _DescribeMessage.zeno(this.text, {this.turn}) : fromZeno = true;

  final String text;
  final bool fromZeno;

  /// Zeno's turn behind the message: its description and questions.
  final ZenoDescribeTurn? turn;
}

class ZenoDescribeScreen extends StatefulWidget {
  const ZenoDescribeScreen({
    super.key,
    required this.data,
    required this.first,
    this.repository,
    this.animateBackground = true,
  });

  /// The listing being written.
  final SellWizardData data;

  /// Zeno's look at the photo: the description so far and its questions.
  final ZenoDescribeTurn first;

  /// For tests.
  final ZenoSellingRepository? repository;

  /// False renders the constellation as one still frame - for tests.
  final bool animateBackground;

  /// Opens the screen; resolves to the description for the seller's box.
  static Future<String> open(BuildContext context, SellWizardData data, ZenoDescribeTurn first) async =>
      await Navigator.of(context)
          .push<String>(MaterialPageRoute(builder: (_) => ZenoDescribeScreen(data: data, first: first))) ??
      first.withBlanks;

  @override
  State<ZenoDescribeScreen> createState() => _ZenoDescribeScreenState();
}

class _ZenoDescribeScreenState extends State<ZenoDescribeScreen> {
  final _msgCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final List<_DescribeMessage> _messages = [];
  final List<Map<String, String>> _history = [];
  late ZenoDescribeTurn _current = widget.first;
  bool _thinking = false;

  ZenoSellingRepository get _repo => widget.repository ?? zenoSellingRepository;

  @override
  void initState() {
    super.initState();
    final first = widget.first;
    final reply = first.reply.isEmpty ? _fallbackReply(first) : first.reply;
    _messages.add(_DescribeMessage.zeno(reply, turn: first));
    _history.add({'role': 'assistant', 'content': _spoken(reply, first)});
  }

  @override
  void dispose() {
    _msgCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  /// Zeno's turn as the transcript holds it: the questions are part of
  /// what it said, so on the next turn it knows what it asked.
  String _spoken(String reply, ZenoDescribeTurn turn) => [
        reply,
        for (final (i, q) in turn.questions.indexed) '${i + 1}. ${q.question}',
      ].join('\n');

  String _fallbackReply(ZenoDescribeTurn turn) => turn.questions.isEmpty
      ? 'Your description is ready.'
      : 'A few things buyers will ask that I need from you:';

  Future<void> _send(String text) async {
    final message = text.trim();
    if (message.isEmpty || _thinking) return;
    _msgCtrl.clear();
    final history = List.of(_history);
    setState(() {
      _messages.add(_DescribeMessage.user(message));
      _thinking = true;
    });
    _history.add({'role': 'user', 'content': message});
    _scrollDown();
    try {
      final turn = await _repo.describeTurn(
        draft: zenoListingDraft(widget.data),
        description: _current.description,
        questions: _current.questions,
        message: message,
        history: history,
        language: ApiService.currentUserLanguage,
      );
      if (!mounted) return;
      final reply = turn.reply.isEmpty ? _fallbackReply(turn) : turn.reply;
      _history.add({'role': 'assistant', 'content': _spoken(reply, turn)});
      setState(() {
        _current = turn;
        _messages.add(_DescribeMessage.zeno(reply, turn: turn));
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      _history.removeLast();
      // Not thinking any more: the typing bubble must not go on bouncing
      // behind the plans sheet.
      setState(() {
        _thinking = false;
        _messages.add(_DescribeMessage.zeno(e.message));
      });
      if (isPlanRefusal(e.statusCode)) {
        await showPremiumUpsell(context, message: e.message, upgradeTo: upgradeToOf(e));
      }
    } catch (_) {
      if (!mounted) return;
      _history.removeLast();
      setState(() => _messages.add(
          _DescribeMessage.zeno("⚠️ I couldn't reach BROKA. Check your connection and try again.")));
    } finally {
      if (mounted) setState(() => _thinking = false);
      _scrollDown();
    }
  }

  /// Closes the screen with the description - questions still open as
  /// blank lines, so nothing Zeno asked is lost.
  void _use() => Navigator.of(context).pop(_current.withBlanks);

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      _scrollCtrl.animateTo(_scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 280), curve: Curves.easeOut);
    });
  }

  @override
  Widget build(BuildContext context) {
    // The description card goes under Zeno's latest turn - not under an
    // error that came after it.
    final cardAt = _messages.lastIndexWhere((m) => m.turn != null);
    // Back is "use what we have": the photo was counted, and the
    // answers so far are the seller's.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _use();
      },
      child: Scaffold(
        backgroundColor: BrokaColors.bg,
        body: ConstellationBackground(
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
            child: SafeArea(
              child: Column(children: [
                _header(),
                Expanded(
                  child: ListView(
                    controller: _scrollCtrl,
                    padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
                    children: [
                      for (final (i, m) in _messages.indexed) ...[
                        _message(m),
                        if (i == cardAt) _descriptionCard(),
                      ],
                      if (_thinking) const Padding(
                        padding: EdgeInsets.only(bottom: 10),
                        child: ZenoTypingBubble(),
                      ),
                    ],
                  ),
                ),
                _composer(),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _header() => Container(
        padding: const EdgeInsets.fromLTRB(6, 6, 12, 10),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: BrokaColors.border.withOpacity(0.6))),
        ),
        child: Row(children: [
          IconButton(
            tooltip: 'Back',
            onPressed: () => Navigator.maybePop(context),
            icon: const Icon(Icons.arrow_back_ios_new_rounded, color: BrokaColors.textHigh, size: 19),
          ),
          const ZenoAvatar(size: 38, glow: true),
          const SizedBox(width: 11),
          const Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              ZoneGlowText('Zeno', gradient: kChatGradient, fontSize: 20, maxLines: 1, letterSpacing: 1.6),
              SizedBox(height: 3),
              Text('Writing your description · PREMIUM',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: BrokaColors.textMid, fontSize: 11.5)),
            ]),
          ),
        ]),
      );

  Widget _message(_DescribeMessage m) {
    final questions = m.turn?.questions ?? const <ZenoDescribeQuestion>[];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: m.fromZeno ? MainAxisAlignment.start : MainAxisAlignment.end,
        children: [
          if (m.fromZeno) ...[const ZenoAvatar(size: 28), const SizedBox(width: 8)],
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: m.fromZeno ? BrokaColors.bgCard.withOpacity(0.92) : null,
                gradient: m.fromZeno ? null : const LinearGradient(colors: kChatGradient),
                borderRadius: BorderRadius.circular(16),
                border: m.fromZeno ? Border.all(color: BrokaColors.neonPurple.withOpacity(0.30)) : null,
              ),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(m.text,
                    style: TextStyle(
                        color: m.fromZeno ? BrokaColors.textHigh : Colors.white, fontSize: 14.5, height: 1.5)),
                for (final (i, q) in questions.indexed)
                  Padding(
                    key: Key('zeno-describe-question-${q.label}'),
                    padding: const EdgeInsets.only(top: 6),
                    child: Text('${i + 1}. ${q.question}',
                        style: const TextStyle(
                            color: BrokaColors.textHigh, fontSize: 14, height: 1.45, fontWeight: FontWeight.w600)),
                  ),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  /// The description as buyers will read it, and the way out with it.
  Widget _descriptionCard() {
    final lines = _current.description.split('\n').where((l) => l.trim().isNotEmpty).toList();
    final open = _current.questions.length;
    return Padding(
      padding: const EdgeInsets.only(left: 36, bottom: 14),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          key: const Key('zeno-describe-preview'),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            color: BrokaColors.bgCard.withOpacity(0.92),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: BrokaColors.neonCyan.withOpacity(0.45)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('WHAT BUYERS WILL READ',
                style: TextStyle(
                    color: BrokaColors.neonCyan, fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.6)),
            const SizedBox(height: 8),
            if (lines.isEmpty)
              const Text('Nothing yet - answer Zeno and it fills in here.',
                  style: TextStyle(color: BrokaColors.textMid, fontSize: 13)),
            for (final line in lines) _line(line),
          ]),
        ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: ElevatedButton.icon(
            key: const Key('zeno-describe-use'),
            onPressed: _use,
            icon: const Icon(Icons.check_rounded, size: 18),
            label: const Text('Use this description'),
            style: ElevatedButton.styleFrom(
              backgroundColor: BrokaColors.gold,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              textStyle: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
        ),
        if (open > 0) ...[
          const SizedBox(height: 6),
          Text(
            open == 1
                ? "If you skip the question, it's left as a blank line for you to fill in."
                : "Questions you skip are left as blank lines for you to fill in.",
            style: const TextStyle(color: BrokaColors.textMid, fontSize: 11.5),
          ),
        ],
      ]),
    );
  }

  /// "RAM: 4 GB" with the label set apart, so the card reads as the list
  /// it is.
  Widget _line(String line) {
    final at = line.indexOf(': ');
    const value = TextStyle(color: BrokaColors.textHigh, fontSize: 13.5, height: 1.45);
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: at <= 0
          ? Text(line, style: value)
          : Text.rich(TextSpan(children: [
              TextSpan(
                  text: line.substring(0, at + 1),
                  style: const TextStyle(color: BrokaColors.textMid, fontWeight: FontWeight.w700)),
              TextSpan(text: line.substring(at + 1)),
            ]), style: value),
    );
  }

  Widget _composer() => Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Expanded(
            child: Container(
              constraints: const BoxConstraints(minHeight: 50),
              decoration: BoxDecoration(
                color: BrokaColors.bgCard.withOpacity(0.92),
                borderRadius: BorderRadius.circular(26),
                border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.45), width: 1.2),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                key: const Key('zeno-describe-input'),
                controller: _msgCtrl,
                minLines: 1,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                style: const TextStyle(color: BrokaColors.textHigh, fontSize: 14.5),
                decoration: InputDecoration(
                  hintText: _current.questions.isEmpty ? 'Anything else buyers should know?' : 'Answer Zeno…',
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  filled: false,
                ),
                onSubmitted: (v) => _send(v),
              ),
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filled(
            key: const Key('zeno-describe-send'),
            tooltip: 'Send',
            onPressed: _thinking ? null : () => _send(_msgCtrl.text),
            style: IconButton.styleFrom(backgroundColor: BrokaColors.gold, minimumSize: const Size(50, 50)),
            icon: const Icon(Icons.arrow_upward_rounded, color: Colors.white),
          ),
        ]),
      );
}
