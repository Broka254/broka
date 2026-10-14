// Zeno pricing the listing a seller is writing (2026-10-05) - opened from
// the sell wizard's Price step, for Pro and Elite (PRICING.md section 4).
//
// The Zeno screen's look - the constellation, Zeno's avatar, its bubbles
// and composer - for one job: arriving at the right asking price. Zeno
// opens with a number and why, and offers to check what similar live
// listings on BROKA ask; that check is the Buying Agent's search run over
// the draft (backend zeno_assistant/selling.py), and it comes back as
// numbers and the listings themselves, as cards. Any price Zeno suggests
// is a button; tapping it closes this screen with that price for the
// wizard's field. Nothing is listed or changed from here.
//
// A conversation about a draft that isn't saved anywhere isn't saved
// either: it lives as long as this screen.
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/network/api_client.dart';
import '../../../main.dart';
import '../../../services/api_service.dart';
import '../../../services/sell_wizard_data.dart';
import '../../../utils/price_format.dart';
import '../../../widgets/chat_parts.dart';
import '../../../widgets/constellation_background.dart';
import '../../../widgets/product_card.dart';
import '../../../widgets/zeno_avatar.dart';
import '../../listings/domain/models/listing.dart';
import '../../premium/presentation/premium_upsell.dart';
import '../data/zeno_selling_repository.dart';
import '../domain/zeno_selling.dart';

class _PriceMessage {
  _PriceMessage.user(this.text)
      : fromZeno = false,
        turn = null;
  _PriceMessage.zeno(this.text, {this.turn}) : fromZeno = true;

  final String text;
  final bool fromZeno;

  /// Zeno's turn behind the message: its price, its offer, its findings.
  final ZenoPriceTurn? turn;
}

class ZenoPricingScreen extends StatefulWidget {
  const ZenoPricingScreen({
    super.key,
    required this.data,
    this.repository,
    this.animateBackground = true,
  });

  /// The listing being written.
  final SellWizardData data;

  /// For tests.
  final ZenoSellingRepository? repository;

  /// False renders the constellation as one still frame - for tests.
  final bool animateBackground;

  /// Opens the screen; resolves to the price the seller chose, if any.
  static Future<int?> open(BuildContext context, SellWizardData data) =>
      Navigator.of(context).push<int>(MaterialPageRoute(builder: (_) => ZenoPricingScreen(data: data)));

  @override
  State<ZenoPricingScreen> createState() => _ZenoPricingScreenState();
}

class _ZenoPricingScreenState extends State<ZenoPricingScreen> {
  final _msgCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _focus = FocusNode();
  final List<_PriceMessage> _messages = [];
  final List<Map<String, String>> _history = [];
  bool _thinking = false;
  bool _researching = false;

  /// Once a check has run, Zeno doesn't offer another for the same draft.
  bool _researched = false;

  ZenoSellingRepository get _repo => widget.repository ?? zenoSellingRepository;

  @override
  void initState() {
    super.initState();
    // Zeno speaks first: the seller came here for a number.
    WidgetsBinding.instance.addPostFrameCallback((_) => _send(_opening));
  }

  @override
  void dispose() {
    _msgCtrl.dispose();
    _scrollCtrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  String get _opening {
    final name = widget.data.name.trim();
    return name.isEmpty ? 'What should I charge for this?' : 'What should I charge for my $name?';
  }

  Future<void> _send(String text, {bool research = false}) async {
    final message = text.trim();
    if ((message.isEmpty && !research) || _thinking) return;
    _msgCtrl.clear();
    final history = List.of(_history);
    setState(() {
      _messages.add(_PriceMessage.user(message));
      _thinking = true;
      _researching = research;
    });
    _history.add({'role': 'user', 'content': message});
    _scrollDown();
    try {
      final turn = await _repo.priceTurn(
        draft: zenoListingDraft(widget.data),
        message: message,
        history: history,
        language: ApiService.currentUserLanguage,
        research: research,
      );
      if (!mounted) return;
      final reply = turn.reply.isEmpty ? _fallbackReply(turn) : turn.reply;
      _history.add({'role': 'assistant', 'content': reply});
      setState(() {
        if (turn.comparables != null) _researched = true;
        _messages.add(_PriceMessage.zeno(reply, turn: turn));
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      _history.removeLast();
      // Not thinking any more: the typing bubble must not go on bouncing
      // behind the plans sheet.
      setState(() {
        _thinking = false;
        _researching = false;
        _messages.add(_PriceMessage.zeno(e.message));
      });
      if (isPlanRefusal(e.statusCode)) {
        await showPremiumUpsell(context, message: e.message, upgradeTo: upgradeToOf(e));
      }
    } catch (_) {
      if (!mounted) return;
      _history.removeLast();
      setState(() => _messages.add(
          _PriceMessage.zeno("⚠️ I couldn't reach BROKA. Check your connection and try again.")));
    } finally {
      if (mounted) {
        setState(() {
          _thinking = false;
          _researching = false;
        });
      }
      _scrollDown();
    }
  }

  String _fallbackReply(ZenoPriceTurn turn) => turn.suggestedPrice != null
      ? 'I would ask ${formatKes(turn.suggestedPrice!)}.'
      : "I couldn't settle on a number - tell me a bit more about it.";

  void _research() => _send('Check how similar listings on BROKA are priced.', research: true);

  void _usePrice(int price) => Navigator.of(context).pop(price);

  void _scrollDown() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      _scrollCtrl.animateTo(_scrollCtrl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 280), curve: Curves.easeOut);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
              _draftStrip(),
              Expanded(
                child: ListView(
                  controller: _scrollCtrl,
                  padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
                  children: [
                    for (final (i, m) in _messages.indexed) _message(m, latest: i == _messages.length - 1),
                    if (_thinking) _thinkingRow(),
                  ],
                ),
              ),
              _composer(),
            ]),
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
              Text('Pricing your listing · PRO',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: BrokaColors.textMid, fontSize: 11.5)),
            ]),
          ),
        ]),
      );

  /// The listing being priced, pinned under the header.
  Widget _draftStrip() {
    final d = widget.data;
    final photo = d.verifiedPhotos.isEmpty ? null : d.verifiedPhotos.first;
    final price = parseKesInput(d.price);
    return Padding(
      key: const Key('zeno-pricing-draft'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 2),
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          gradient: BrokaColors.cardGradient,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: BrokaColors.neonPurple.withOpacity(0.4)),
        ),
        child: Row(children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: SizedBox(
              width: 44,
              height: 44,
              child: photo == null
                  ? Container(color: BrokaColors.bgMid, child: const Icon(Icons.sell_rounded, color: BrokaColors.textMid))
                  : Image.file(photo,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(color: BrokaColors.bgMid)),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(d.name.trim().isEmpty ? 'Your listing' : d.name.trim(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: BrokaColors.textHigh, fontSize: 13.5, fontWeight: FontWeight.w700)),
              const SizedBox(height: 3),
              Text(
                price != null && price > 0 ? 'Your price: ${formatKes(price)}' : 'No price yet',
                style: const TextStyle(color: BrokaColors.neonCyan, fontSize: 12.5, fontWeight: FontWeight.w800),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _message(_PriceMessage m, {required bool latest}) {
    final bubble = Padding(
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
              child: Text(m.text,
                  style: TextStyle(
                      color: m.fromZeno ? BrokaColors.textHigh : Colors.white, fontSize: 14.5, height: 1.5)),
            ),
          ),
        ],
      ),
    );
    final turn = m.turn;
    if (turn == null) return bubble;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      bubble,
      if (turn.comparables != null) _comparables(turn.comparables!),
      if (turn.suggestedPrice != null || (turn.offerResearch && !_researched && latest))
        Padding(
          padding: const EdgeInsets.only(left: 36, bottom: 14),
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            if (turn.suggestedPrice != null)
              ElevatedButton.icon(
                key: Key('zeno-use-price-${turn.suggestedPrice}'),
                onPressed: () => _usePrice(turn.suggestedPrice!),
                icon: const Icon(Icons.check_rounded, size: 18),
                label: Text('Use ${formatKes(turn.suggestedPrice!)}'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: BrokaColors.gold,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  textStyle: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            if (turn.offerResearch && !_researched && latest)
              OutlinedButton.icon(
                key: const Key('zeno-check-broka'),
                onPressed: _thinking ? null : _research,
                icon: const Icon(Icons.travel_explore_rounded, size: 18, color: BrokaColors.neonCyan),
                label: const Text('Check similar listings on BROKA'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: BrokaColors.textHigh,
                  side: BorderSide(color: BrokaColors.neonCyan.withOpacity(0.6)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  textStyle: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
          ]),
        ),
    ]);
  }

  /// What the check found: the spread in numbers, then the listings.
  Widget _comparables(ZenoComparables c) {
    if (c.count == 0) {
      return const Padding(
        padding: EdgeInsets.only(left: 36, bottom: 10),
        child: Text('No similar listings are live on BROKA right now.',
            key: Key('zeno-comparables-none'),
            style: TextStyle(color: BrokaColors.textMid, fontSize: 12)),
      );
    }
    Widget stat(String label, double? value) => Expanded(
          child: Column(children: [
            Text(value == null ? '-' : formatKes(value),
                style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(color: BrokaColors.textMid, fontSize: 10.5)),
          ]),
        );
    return Padding(
      key: const Key('zeno-comparables'),
      padding: const EdgeInsets.only(left: 36, bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
          decoration: BoxDecoration(
            color: BrokaColors.bgCard.withOpacity(0.92),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: BrokaColors.neonCyan.withOpacity(0.45)),
          ),
          child: Column(children: [
            Text(
              c.count == 1 ? '1 similar listing on BROKA' : '${c.count} similar listings on BROKA',
              style: const TextStyle(color: BrokaColors.neonCyan, fontSize: 12, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            Row(children: [stat('Lowest', c.low), stat('Typical', c.median), stat('Highest', c.high)]),
          ]),
        ),
        if (c.listings.isNotEmpty) ...[
          const SizedBox(height: 10),
          SizedBox(
            height: 250,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: c.listings.length,
              separatorBuilder: (_, __) => const SizedBox(width: 10),
              itemBuilder: (context, i) {
                final listing = BrokaListing.fromJson(c.listings[i]);
                return SizedBox(
                  width: 170,
                  child: HeroMode(
                    enabled: false,
                    child: ProductCard(
                      item: listing,
                      onTap: () => Navigator.pushNamed(context, '/product',
                          arguments: {'listingId': listing.id}),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ]),
    );
  }

  Widget _thinkingRow() => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: _researching
            ? const Row(children: [
                ZenoAvatar(size: 28),
                SizedBox(width: 8),
                Flexible(
                  child: Text('Checking similar listings on BROKA…',
                      style: TextStyle(color: BrokaColors.neonCyan, fontSize: 13, fontWeight: FontWeight.w700)),
                ),
              ])
            : const ZenoTypingBubble(),
      );

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
                key: const Key('zeno-pricing-input'),
                controller: _msgCtrl,
                focusNode: _focus,
                minLines: 1,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                style: const TextStyle(color: BrokaColors.textHigh, fontSize: 14.5),
                decoration: const InputDecoration(
                  hintText: 'Ask about the price…',
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
            key: const Key('zeno-pricing-send'),
            tooltip: 'Send',
            onPressed: _thinking ? null : () => _send(_msgCtrl.text),
            style: IconButton.styleFrom(backgroundColor: BrokaColors.gold, minimumSize: const Size(50, 50)),
            icon: const Icon(Icons.arrow_upward_rounded, color: Colors.white),
          ),
        ]),
      );
}
