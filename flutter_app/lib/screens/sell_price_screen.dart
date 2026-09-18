// BROKA - Sell Wizard Step 4: Price
import 'dart:async';
import 'package:flutter/material.dart';
import '../main.dart';
import '../services/sell_wizard_data.dart';
import '../widgets/sell_step_scaffold.dart';
import 'sell_location_screen.dart';

class SellPriceScreen extends StatefulWidget {
  final SellWizardData data;
  const SellPriceScreen({super.key, required this.data});
  @override
  State<SellPriceScreen> createState() => _SellPriceScreenState();
}

class _SellPriceScreenState extends State<SellPriceScreen> {
  late final TextEditingController _priceCtrl;
  late final TextEditingController _reserveCtrl;
  late final TextEditingController _incrementCtrl;
  Timer? _debounce;
  String? _error;

  // Defaults the seller can accept without thinking about them. An auction
  // needs a window and an increment to exist at all, and before this the
  // backend had to invent both because the wizard collected neither.
  static const _defaultIncrement = 500.0;
  static const _defaultDuration = Duration(days: 3);

  @override
  void initState() {
    super.initState();
    _priceCtrl = TextEditingController(text: widget.data.price);
    _reserveCtrl = TextEditingController(text: widget.data.reserve);
    _incrementCtrl = TextEditingController(
        text: widget.data.minBidIncrement.isNotEmpty
            ? widget.data.minBidIncrement
            : _defaultIncrement.toStringAsFixed(0));
    // Pre-fill a sensible window rather than making the seller pick two
    // datetimes before they can continue.
    widget.data.auctionStartsAt ??= DateTime.now();
    widget.data.auctionEndsAt ??= DateTime.now().add(_defaultDuration);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _priceCtrl.dispose();
    _reserveCtrl.dispose();
    _incrementCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDateTime({required bool isStart}) async {
    final current = isStart
        ? (widget.data.auctionStartsAt ?? DateTime.now())
        : (widget.data.auctionEndsAt ?? DateTime.now().add(_defaultDuration));
    final date = await showDatePicker(
      context: context,
      initialDate: current,
      firstDate: DateTime.now().subtract(const Duration(days: 1)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
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
    final price = double.tryParse(_priceCtrl.text.trim());
    if (price == null || price <= 0) {
      setState(() => _error = 'Enter a valid asking price.');
      return;
    }

    // Auction validation. The backend enforces every one of these again
    // (lifecycle.validate_terms) - this is here so the seller finds out
    // now rather than after tapping Activate, not because the client is
    // trusted with it.
    if (widget.data.type == 'auction') {
      final increment = double.tryParse(_incrementCtrl.text.trim());
      if (increment == null || increment <= 0) {
        setState(() => _error = 'Enter a minimum bid increment above zero.');
        return;
      }
      final reserveText = _reserveCtrl.text.trim();
      if (reserveText.isNotEmpty) {
        final reserve = double.tryParse(reserveText);
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
      widget.data.minBidIncrement = _incrementCtrl.text.trim();
    }

    widget.data.price = _priceCtrl.text;
    widget.data.reserve = _reserveCtrl.text;
    setState(() => _error = null);
    unawaited(widget.data.persist());
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => SellLocationScreen(data: widget.data),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final isAuction = widget.data.type == 'auction';
    return SellStepScaffold(
      step: 4, totalSteps: 7, title: 'Price',
      error: _error,
      onNext: _next,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        sellStepLabel('ASKING PRICE (KES)'),
        const SizedBox(height: 8),
        TextFormField(
          controller: _priceCtrl,
          keyboardType: TextInputType.number,
          style: const TextStyle(color: BrokaColors.gold, fontWeight: FontWeight.w800),
          decoration: const InputDecoration(hintText: 'e.g. 2500000'),
          onChanged: (_) => _scheduleSave(),
        ),

        if (isAuction) ...[
          const SizedBox(height: 20),
          sellStepLabel('MINIMUM BID INCREMENT (KES)'),
          const SizedBox(height: 8),
          TextFormField(
            controller: _incrementCtrl,
            keyboardType: TextInputType.number,
            style: const TextStyle(color: BrokaColors.textHigh),
            decoration: const InputDecoration(
                hintText: 'How much each bid must raise it by'),
            onChanged: (_) => _scheduleSave(),
          ),

          const SizedBox(height: 20),
          sellStepLabel('RESERVE PRICE (KES)  optional'),
          const SizedBox(height: 8),
          TextFormField(
            controller: _reserveCtrl,
            keyboardType: TextInputType.number,
            style: const TextStyle(color: BrokaColors.textHigh),
            decoration: const InputDecoration(
                hintText: 'Lowest price you would accept'),
            onChanged: (_) => _scheduleSave(),
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
