// BROKA - Sell Wizard Step 5: Price
//
// The amount, what it is for, and whether it's negotiable (2026-09-25):
//   * "per bag" - a farmer with 100 bags of maize used to have one number
//     and no way to say what it bought. The price stays a number (escrow
//     and sorting need one); the unit is chosen alongside it, from units
//     that fit the category, or typed (PriceUnits).
//   * fixed or open to offers - Zeno is told which (Listing.price_negotiable)
//     and says so to buyers, instead of inviting offers on a fixed price.
// An auction has neither: it sells the lot, and bidding is its negotiation.
//
// Pricing with Zeno (2026-10-05), for Pro sellers (PRICING.md section 4):
// a card at the top opens Zeno's pricing screen, where Zeno suggests a
// price and can check what similar live listings on BROKA ask. The price
// the seller picks there comes back into the field. Without Pro the card
// opens the plans, saying why: a listing priced right sells faster.
import 'dart:async';
import 'package:flutter/material.dart';
import '../core/utils/result.dart';
import '../features/premium/data/premium_repository.dart';
import '../features/premium/domain/premium.dart';
import '../features/premium/presentation/premium_upsell.dart';
import '../features/zeno_assistant/presentation/zeno_pricing_screen.dart';
import '../main.dart';
import '../services/sell_wizard_data.dart';
import '../utils/price_format.dart';
import '../utils/price_unit.dart';
import '../widgets/sell_step_scaffold.dart';
import '../widgets/sell_zeno_boost_card.dart';
import 'sell_flow.dart';

class SellPriceScreen extends StatefulWidget {
  final SellWizardData data;

  /// For tests: where the plan is read, and how Zeno's pricing screen is
  /// opened (it resolves to the price the seller chose).
  final PremiumRepository? premium;
  final Future<int?> Function(BuildContext context, SellWizardData data)? openPricing;

  const SellPriceScreen({super.key, required this.data, this.premium, this.openPricing});
  @override
  State<SellPriceScreen> createState() => _SellPriceScreenState();
}

class _SellPriceScreenState extends State<SellPriceScreen> {
  late final TextEditingController _priceCtrl;
  late final TextEditingController _reserveCtrl;
  late final TextEditingController _incrementCtrl;
  late final TextEditingController _unitCtrl;
  // True while the seller types a unit the suggestions don't have.
  late bool _customUnit;
  Timer? _debounce;
  String? _error;

  // The seller's plan; null until known, and then the card opens Zeno and
  // the server decides.
  PremiumStatus? _premium;

  SellWizardData get _data => widget.data;
  List<String> get _suggestions =>
      PriceUnits.suggestionsFor(_data.category, _data.subcategoryName);

  // Defaults the seller can accept without thinking about them. An auction
  // needs a window and an increment to exist at all, and before this the
  // backend had to invent both because the wizard collected neither.
  static const _defaultIncrement = 500.0;
  static const _defaultDuration = Duration(days: 3);

  @override
  void initState() {
    super.initState();
    _priceCtrl = TextEditingController(text: _grouped(widget.data.price));
    _reserveCtrl = TextEditingController(text: _grouped(widget.data.reserve));
    _incrementCtrl = TextEditingController(
        text: widget.data.minBidIncrement.isNotEmpty
            ? _grouped(widget.data.minBidIncrement)
            : formatKesAmount(_defaultIncrement));
    final unit = widget.data.priceUnit;
    _customUnit = unit != null && !_suggestions.contains(unit);
    _unitCtrl = TextEditingController(text: _customUnit ? unit : '');
    // Pre-fill a sensible window rather than making the seller pick two
    // datetimes before they can continue. A restored draft's window may
    // already be over - an auction that closed before it opened - so that
    // one is replaced too, and a start in the past just means "now".
    final now = DateTime.now();
    final endsAt = widget.data.auctionEndsAt;
    if (endsAt == null || !endsAt.isAfter(now)) {
      widget.data.auctionStartsAt = now;
      widget.data.auctionEndsAt = now.add(_defaultDuration);
    } else if (widget.data.auctionStartsAt == null ||
        widget.data.auctionStartsAt!.isBefore(now)) {
      widget.data.auctionStartsAt = now;
    }
    _loadPremium();
  }

  Future<void> _loadPremium() async {
    final r = await (widget.premium ?? premiumRepository).me();
    if (mounted && r is Success<PremiumStatus>) setState(() => _premium = r.data);
  }

  /// No price checks on this plan: the card leads to Pro instead.
  bool get _pricingLocked => !(_premium?.includes(PremiumFeature.priceChecks) ?? true);

  String? get _checksLeftText {
    final p = _premium;
    if (p == null || !p.enabled || !p.hasPlan || _pricingLocked) return null;
    final all = p.usage[PremiumFeature.priceChecks]?.allowance ?? 0;
    return '${p.left(PremiumFeature.priceChecks)} of $all price checks left this month';
  }

  Future<void> _priceWithZeno() async {
    if (_pricingLocked) {
      final opened = await showPremiumUpsell(context,
          message: 'Pricing with Zeno is part of BROKA Pro. A listing priced right from the start '
              'sells faster - Zeno suggests your price and checks it against similar listings on BROKA.',
          upgradeTo: 'pro',
          feature: PremiumFeature.priceChecks,
          premium: widget.premium);
      if (opened && mounted) await _loadPremium();
      return;
    }
    // What is typed so far goes with the draft: Zeno weighs in on it.
    _onEdited();
    final chosen = await (widget.openPricing ?? ZenoPricingScreen.open)(context, _data);
    if (!mounted) return;
    if (_premium?.enabled ?? false) unawaited(_loadPremium());
    if (chosen == null) return;
    setState(() {
      _priceCtrl.text = formatKesAmount(chosen);
      _error = null;
    });
    _onEdited();
  }

  /// A stored amount ("2500000") as the field shows it ("2,500,000").
  static String _grouped(String amount) {
    final value = parseKesInput(amount);
    return value == null ? '' : formatKesAmount(value);
  }

  /// A field's text as the wizard stores it: plain digits.
  static String _digits(TextEditingController c) =>
      c.text.replaceAll(RegExp(r'[^0-9]'), '');

  /// Keeps the draft current as the seller types. The debounced save used
  /// to run before anything was copied into the draft - only Next did
  /// that - so a price typed and then lost to the app being closed was
  /// never saved at all.
  void _onEdited() {
    widget.data.price = _digits(_priceCtrl);
    widget.data.reserve = _digits(_reserveCtrl);
    widget.data.minBidIncrement = _digits(_incrementCtrl);
    _scheduleSave();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _priceCtrl.dispose();
    _reserveCtrl.dispose();
    _incrementCtrl.dispose();
    _unitCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDateTime({required bool isStart}) async {
    final current = isStart
        ? (widget.data.auctionStartsAt ?? DateTime.now())
        : (widget.data.auctionEndsAt ?? DateTime.now().add(_defaultDuration));
    // From today: yesterday used to be offered, and an auction set to
    // close then was over before it began.
    final today = DateUtils.dateOnly(DateTime.now());
    final date = await showDatePicker(
      context: context,
      initialDate: current.isBefore(today) ? today : current,
      firstDate: today,
      lastDate: today.add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(current),
    );
    if (!mounted) return;
    final picked = DateTime(
      date.year, date.month, date.day,
      time?.hour ?? current.hour, time?.minute ?? current.minute,
    );
    setState(() {
      if (isStart) {
        widget.data.auctionStartsAt = picked;
      } else {
        widget.data.auctionEndsAt = picked;
      }
      _error = null;
    });
    _scheduleSave();
  }

  static String _fmtDateTime(DateTime? dt) {
    if (dt == null) return 'Choose…';
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '${dt.day}/${dt.month}/${dt.year}  $h:$m';
  }

  void _scheduleSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 600), () => widget.data.persist());
  }

  void _next() {
    final price = parseKesInput(_priceCtrl.text);
    if (price == null || price <= 0) {
      setState(() => _error = 'Enter a valid asking price.');
      return;
    }
    if (price > maxListingPriceKes) {
      // Not "the most BROKA can hold in escrow": it holds none while
      // payments are paused. The limit is the server's either way.
      setState(() => _error = "The price can't be more than "
          '${formatKes(maxListingPriceKes)} on BROKA.');
      return;
    }

    // Auction validation. The backend enforces every one of these again
    // (lifecycle.validate_terms) - this is here so the seller finds out
    // now rather than after tapping Activate, not because the client is
    // trusted with it.
    if (widget.data.type == 'auction') {
      final increment = parseKesInput(_incrementCtrl.text);
      if (increment == null || increment <= 0) {
        setState(() => _error = 'Enter a minimum bid increment above zero.');
        return;
      }
      final reserveText = _reserveCtrl.text.trim();
      if (reserveText.isNotEmpty) {
        final reserve = parseKesInput(reserveText);
        if (reserve == null || reserve <= 0) {
          setState(() => _error = 'A reserve price must be above zero, or left empty.');
          return;
        }
        if (reserve < price) {
          setState(() => _error =
              'A reserve below the starting price would be met by the first bid.');
          return;
        }
      }
      final startsAt = widget.data.auctionStartsAt;
      final endsAt = widget.data.auctionEndsAt;
      if (startsAt == null || endsAt == null) {
        setState(() => _error = 'Set when bidding opens and closes.');
        return;
      }
      if (!endsAt.isAfter(startsAt)) {
        setState(() => _error = 'The auction must close after it opens.');
        return;
      }
      if (!endsAt.isAfter(DateTime.now())) {
        setState(() => _error = 'That closing time has already passed. Choose a later one.');
        return;
      }
    }

    if (!_data.isAuction) {
      if (_customUnit) {
        final problem = PriceUnits.problem(_unitCtrl.text);
        if (problem != null) {
          setState(() => _error = problem);
          return;
        }
        _data.priceUnit = PriceUnits.clean(_unitCtrl.text);
      }
      if (_data.priceNegotiable == null) {
        setState(() => _error = 'Say whether the price is fixed or open to offers.');
        return;
      }
    } else {
      // An auction sells the lot, and bidding is its negotiation.
      _data.priceUnit = null;
      _data.priceNegotiable = true;
    }

    widget.data.price = _digits(_priceCtrl);
    widget.data.reserve = _digits(_reserveCtrl);
    widget.data.minBidIncrement = _digits(_incrementCtrl);
    setState(() => _error = null);
    SellFlow.next(context, _data, from: SellFlow.price);
  }

  void _setUnit(String? unit, {bool custom = false}) {
    setState(() {
      _customUnit = custom;
      _data.priceUnit = custom ? PriceUnits.clean(_unitCtrl.text) : unit;
      _error = null;
    });
    _scheduleSave();
  }

  Widget _unitChip(String label, bool selected, VoidCallback onTap, {Key? key}) => ChoiceChip(
        key: key,
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
        selectedColor: BrokaColors.gold,
        backgroundColor: BrokaColors.bgCard,
        side: BorderSide(color: selected ? BrokaColors.gold : BrokaColors.border),
        labelStyle: TextStyle(
            color: selected ? Colors.white : BrokaColors.textMid,
            fontWeight: FontWeight.w700, fontSize: 12.5),
        showCheckmark: false,
      );

  Widget _priceUnitSection() {
    final amount = parseKesInput(_priceCtrl.text);
    final preview = amount == null || amount <= 0
        ? null
        : PriceUnits.priceLabel(formatKes(amount), _data.priceUnit);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      sellStepLabel('THE PRICE IS FOR'),
      SellGap.label,
      Wrap(spacing: 8, runSpacing: 8, children: [
        _unitChip('The whole item', !_customUnit && _data.priceUnit == null,
            () => _setUnit(null), key: const Key('sell-unit-whole')),
        for (final unit in _suggestions)
          _unitChip('Per $unit', !_customUnit && _data.priceUnit == unit,
              () => _setUnit(unit), key: Key('sell-unit-$unit')),
        _unitChip('Other…', _customUnit, () => _setUnit(null, custom: true),
            key: const Key('sell-unit-other')),
      ]),
      if (_customUnit) ...[
        const SizedBox(height: 10),
        TextField(
          key: const Key('sell-unit-field'),
          controller: _unitCtrl,
          autofocus: true,
          maxLength: PriceUnits.maxLength,
          style: const TextStyle(color: BrokaColors.textHigh),
          decoration: const InputDecoration(
              prefixText: 'per  ', hintText: 'e.g. crate, dozen, trip'),
          onChanged: (_) => _setUnit(null, custom: true),
        ),
      ],
      if (preview != null) ...[
        const SizedBox(height: 10),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          child: SellCard(
            key: ValueKey(preview),
            highlight: true,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(children: [
              const Icon(Icons.visibility_rounded, color: BrokaColors.gold, size: 18),
              const SizedBox(width: 10),
              const Text('Buyers see  ', style: TextStyle(color: BrokaColors.textMid, fontSize: 12)),
              Expanded(child: Text(preview, style: const TextStyle(
                  color: Colors.white, fontSize: 15, fontWeight: FontWeight.w800))),
            ]),
          ),
        ),
      ],
    ]);
  }

  Widget _negotiableSection() => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        sellStepLabel('IS THE PRICE NEGOTIABLE?'),
        SellGap.label,
        SellChoiceCard(
          key: const Key('sell-negotiable-yes'),
          emoji: '🤝',
          title: 'Open to offers',
          subtitle: 'Buyers can make offers - Zeno brings you each one to accept or counter.',
          selected: _data.priceNegotiable == true,
          accent: BrokaColors.neonGreen,
          onTap: () {
            setState(() {
              _data.priceNegotiable = true;
              _error = null;
            });
            _scheduleSave();
          },
        ),
        SellGap.item,
        SellChoiceCard(
          key: const Key('sell-negotiable-no'),
          emoji: '🔒',
          title: 'Fixed price',
          subtitle: 'Zeno tells buyers the price is final - no haggling.',
          selected: _data.priceNegotiable == false,
          accent: BrokaColors.neonBlue,
          onTap: () {
            setState(() {
              _data.priceNegotiable = false;
              _error = null;
            });
            _scheduleSave();
          },
        ),
      ]);

  @override
  Widget build(BuildContext context) {
    final isAuction = widget.data.type == 'auction';
    return SellStepScaffold(
      step: SellFlow.price, totalSteps: SellFlow.total, title: SellFlow.title(SellFlow.price),
      subtitle: isAuction
          ? 'Where bidding starts, and the rules of your auction.'
          : 'What you want for it - and what that price buys.',
      data: _data,
      error: _error,
      onNext: _next,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SellZenoBoostCard(
          key: const Key('sell-zeno-price'),
          icon: Icons.insights_rounded,
          title: isAuction ? 'Set the right starting bid with Zeno' : 'Price it to sell with Zeno',
          benefit: 'Listings priced right from the start sell faster. Zeno suggests your price and '
              'checks what similar listings on BROKA ask.',
          badge: 'PRO',
          locked: _pricingLocked,
          footnote: _checksLeftText,
          points: const [
            'What similar items on BROKA ask right now',
            'One clear number to ask - and why',
            "Know if you're overpriced before buyers do",
          ],
          // What Pro shows, with the numbers hidden: the seller sees what
          // they'd get rather than reading about it.
          preview: _pricingLocked ? const ZenoLockedRange() : null,
          cta: _pricingLocked ? 'Unlock with Pro' : 'Price it with Zeno',
          onTap: _priceWithZeno,
        ),
        SellGap.section,
        sellStepLabel(isAuction ? 'STARTING PRICE (KES)' : 'ASKING PRICE (KES)'),
        SellGap.label,
        TextFormField(
          key: const Key('sell-price-field'),
          controller: _priceCtrl,
          keyboardType: TextInputType.number,
          inputFormatters: const [KesInputFormatter()],
          style: const TextStyle(color: BrokaColors.gold, fontWeight: FontWeight.w800, fontSize: 22),
          decoration: const InputDecoration(prefixText: 'KES  ', hintText: 'e.g. 3,500'),
          onChanged: (_) {
            _onEdited();
            setState(() {});
          },
        ),

        if (!isAuction) ...[
          SellGap.section,
          _priceUnitSection(),
          SellGap.section,
          _negotiableSection(),
        ],

        if (isAuction) ...[
          const SizedBox(height: 20),
          sellStepLabel('MINIMUM BID INCREMENT (KES)'),
          const SizedBox(height: 8),
          TextFormField(
            controller: _incrementCtrl,
            keyboardType: TextInputType.number,
            inputFormatters: const [KesInputFormatter()],
            style: const TextStyle(color: BrokaColors.textHigh),
            decoration: const InputDecoration(
                hintText: 'How much each bid must raise it by'),
            onChanged: (_) => _onEdited(),
          ),

          const SizedBox(height: 20),
          sellStepLabel('RESERVE PRICE (KES)  optional'),
          const SizedBox(height: 8),
          TextFormField(
            controller: _reserveCtrl,
            keyboardType: TextInputType.number,
            inputFormatters: const [KesInputFormatter()],
            style: const TextStyle(color: BrokaColors.textHigh),
            decoration: const InputDecoration(
                hintText: 'Lowest price you would accept'),
            onChanged: (_) => _onEdited(),
          ),
          const SizedBox(height: 6),
          const Text(
            'Buyers never see this amount. Bids below it are still accepted — '
            'if the auction ends under your reserve, it simply does not sell.',
            style: TextStyle(color: BrokaColors.textLow, fontSize: 11.5, height: 1.4),
          ),

          const SizedBox(height: 20),
          sellStepLabel('BIDDING OPENS'),
          const SizedBox(height: 8),
          _dateTimeField(
            value: widget.data.auctionStartsAt,
            onTap: () => _pickDateTime(isStart: true),
          ),
          const SizedBox(height: 16),
          sellStepLabel('BIDDING CLOSES'),
          const SizedBox(height: 8),
          _dateTimeField(
            value: widget.data.auctionEndsAt,
            onTap: () => _pickDateTime(isStart: false),
          ),
          const SizedBox(height: 6),
          const Text(
            'These can be changed until the first bid arrives. After that the '
            'auction terms are fixed — people are bidding against them.',
            style: TextStyle(color: BrokaColors.textLow, fontSize: 11.5, height: 1.4),
          ),
        ],
      ]),
    );
  }

  Widget _dateTimeField({required DateTime? value, required VoidCallback onTap}) =>
      InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: BrokaColors.border),
          ),
          child: Row(children: [
            const Icon(Icons.schedule_rounded, size: 16, color: BrokaColors.textLow),
            const SizedBox(width: 10),
            Text(_fmtDateTime(value),
                style: const TextStyle(
                    color: BrokaColors.textHigh, fontWeight: FontWeight.w600)),
            const Spacer(),
            const Icon(Icons.edit_calendar_outlined,
                size: 16, color: BrokaColors.textLow),
          ]),
        ),
      );
}
