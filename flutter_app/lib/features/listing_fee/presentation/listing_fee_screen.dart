// BROKA - Listing fee: choose how long to list, and pay with M-Pesa.
//
// Opened three ways, one screen for all of them:
//   * straight after Go live, when a new listing waits for its first
//     payment before buyers can see it ([afterCreate]);
//   * "Pay to publish" on a listing that is still unpaid;
//   * "Renew" on a listing whose paid time is ending or over.
//
// What the seller sees is PRICING.md's sell screen: the list price crossed
// out and their price, why it is that price, 1-6 months with the recommended
// one picked, and - for short-term sellers only - featured placement in the
// same payment. Every amount is the server's; Pay asks M-Pesa for exactly
// the total shown, because the server works it out the same way.
//
// Pops `true` once paid, so Go live can celebrate.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/utils/result.dart';
import '../../../main.dart';
import '../../../services/api_service.dart';
import '../../../utils/price_format.dart';
import '../data/listing_fee_repository.dart';
import '../domain/listing_fee.dart';

enum _Stage { loading, loadFailed, choosing, prompting, waiting, slow, paid }

class ListingFeeScreen extends StatefulWidget {
  const ListingFeeScreen({
    super.key,
    required this.listingId,
    required this.listingName,
    this.afterCreate = false,
    this.repository,
    this.pollEvery = const Duration(seconds: 3),
    this.giveUpAfter = const Duration(seconds: 150),
  });

  final String listingId;
  final String listingName;

  /// Opened by Go live: pop as soon as it is paid, and Go live celebrates.
  final bool afterCreate;

  /// For tests.
  final ListingFeeRepository? repository;
  final Duration pollEvery;

  /// How long to wait for M-Pesa before saying it is slow. The payment
  /// still lands when M-Pesa confirms; the seller just stops watching.
  final Duration giveUpAfter;

  @override
  State<ListingFeeScreen> createState() => _ListingFeeScreenState();
}

class _ListingFeeScreenState extends State<ListingFeeScreen> {
  ListingFeeRepository get _repo => widget.repository ?? listingFeeRepository;

  _Stage _stage = _Stage.loading;
  ListingFeeQuote? _quote;
  int _months = 1;
  String? _featured;
  final _phone = TextEditingController();
  String? _error;
  ListingFeePayment? _payment;

  // Kept across a timed-out attempt, so pressing Pay again re-sends the
  // same request - and the server answers with the prompt it already sent
  // rather than prompting the phone twice. Anything else starts afresh.
  String? _attemptKey;
  Timer? _poll;
  DateTime? _waitingSince;
  // A status request still out: the timer's next tick waits for it rather
  // than stacking a second one on a slow connection.
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    _phone.text = ApiService.currentUserPhone ?? '';
    _load();
  }

  @override
  void dispose() {
    _poll?.cancel();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _stage = _Stage.loading;
      _error = null;
    });
    final r = await _repo.quoteForListing(widget.listingId);
    if (!mounted) return;
    switch (r) {
      case Success(:final data):
        setState(() {
          _quote = data;
          _months = data.defaultMonths;
          _stage = _Stage.choosing;
        });
      case Failure(:final message):
        setState(() {
          _error = message;
          _stage = _Stage.loadFailed;
        });
    }
  }

  int get _featuredPrice {
    for (final p in _quote?.featuredPlans ?? const <FeaturedPlan>[]) {
      if (p.id == _featured) return p.price;
    }
    return 0;
  }

  int get _total => (_quote?.option(_months)?.total ?? 0) + _featuredPrice;

  void _choose({int? months, String? featured, bool clearFeatured = false}) {
    HapticFeedback.selectionClick();
    setState(() {
      if (months != null) _months = months;
      if (featured != null || clearFeatured) _featured = featured;
      _error = null;
      _attemptKey = null;
    });
  }

  Future<void> _pay() async {
    if (_stage == _Stage.prompting) return;
    final digits = _phone.text.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length < 9) {
      setState(() => _error = 'Enter the Safaricom number to pay from, e.g. 0712 345 678.');
      return;
    }
    _attemptKey ??= ListingFeeRepository.newAttemptKey();
    setState(() {
      _stage = _Stage.prompting;
      _error = null;
    });
    final r = await _repo.pay(
      listingId: widget.listingId,
      months: _months,
      phone: _phone.text.trim(),
      featuredPlan: _featured,
      idempotencyKey: _attemptKey!,
    );
    if (!mounted) return;
    switch (r) {
      case Success(:final data):
        HapticFeedback.mediumImpact();
        _attemptKey = null;
        _startWaiting(data);
      case Failure(:final message, :final statusCode):
        setState(() {
          _stage = _Stage.choosing;
          _error = message;
          // Only a request that may not have arrived is worth re-sending
          // under the same key.
          if (statusCode != null) _attemptKey = null;
        });
    }
  }

  void _startWaiting(ListingFeePayment payment) {
    _poll?.cancel();
    setState(() {
      _payment = payment;
      _stage = _Stage.waiting;
      _waitingSince = DateTime.now();
    });
    _poll = Timer.periodic(widget.pollEvery, (_) => _check());
  }

  Future<void> _check() async {
    final payment = _payment;
    if (payment == null || _checking) return;
    _checking = true;
    final Result<ListingFeePayment> r;
    try {
      r = await _repo.paymentStatus(payment.id);
    } finally {
      _checking = false;
    }
    if (!mounted || _stage != _Stage.waiting) return;
    if (r case Success(:final data)) {
      if (data.succeeded) {
        _poll?.cancel();
        HapticFeedback.heavyImpact();
        if (widget.afterCreate) {
          Navigator.of(context).pop(true);
          return;
        }
        setState(() {
          _payment = data;
          _stage = _Stage.paid;
        });
        return;
      }
      if (!data.pending) {
        _poll?.cancel();
        setState(() {
          _stage = _Stage.choosing;
          _error = "M-Pesa didn't complete the payment. Nothing was charged - try again.";
        });
        return;
      }
    }
    if (DateTime.now().difference(_waitingSince!) >= widget.giveUpAfter) {
      _poll?.cancel();
      setState(() => _stage = _Stage.slow);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: BrokaColors.bg,
      appBar: AppBar(
        backgroundColor: BrokaColors.bg,
        elevation: 0,
        iconTheme: const IconThemeData(color: BrokaColors.textHigh),
        title: Text(_title,
            style: const TextStyle(color: BrokaColors.textHigh, fontSize: 17, fontWeight: FontWeight.w800)),
      ),
      body: SafeArea(child: _body()),
    );
  }

  String get _title {
    final status = _quote?.state?.status;
    if (status == 'ending' || status == 'expired') return 'Renew listing';
    return 'Listing fee';
  }

  Widget _body() {
    switch (_stage) {
      case _Stage.loading:
        return const Center(child: CircularProgressIndicator(color: BrokaColors.gold));
      case _Stage.loadFailed:
        return _Message(
          icon: Icons.wifi_off_rounded,
          title: "Couldn't load the price",
          body: _error ?? 'Try again.',
          action: 'Try again',
          onAction: _load,
        );
      case _Stage.waiting:
      case _Stage.prompting:
        if (_stage == _Stage.waiting) {
          return _Message(
            key: const Key('fee-waiting'),
            icon: Icons.phone_android_rounded,
            title: 'Check your phone',
            body: 'Enter your M-Pesa PIN to pay KES ${formatKesAmount(_payment?.amount ?? _total)}. '
                'This screen updates as soon as M-Pesa confirms.',
            busy: true,
          );
        }
        return _choosing();
      case _Stage.slow:
        return _Message(
          key: const Key('fee-slow'),
          icon: Icons.hourglass_bottom_rounded,
          title: 'Waiting for M-Pesa',
          body: "M-Pesa hasn't confirmed yet. If you entered your PIN, your listing goes live "
              'as soon as it does - you can close this and check your Seller Dashboard.',
          action: 'Check again',
          onAction: () => _startWaiting(_payment!),
        );
      case _Stage.paid:
        final until = _payment?.paidUntil;
        return _Message(
          key: const Key('fee-paid'),
          icon: Icons.check_circle_rounded,
          iconColor: BrokaColors.neonGreen,
          title: 'Paid - buyers can see it',
          body: until == null ? widget.listingName : '${widget.listingName} is live until ${_date(until)}.',
          action: 'Done',
          onAction: () => Navigator.of(context).pop(true),
        );
      case _Stage.choosing:
        return _choosing();
    }
  }

  Widget _choosing() {
    final q = _quote!;
    if (!q.feesEnabled) {
      return _Message(
        icon: Icons.celebration_rounded,
        title: 'Listing is free right now',
        body: 'There is nothing to pay while BROKA launches.',
        action: 'Done',
        onAction: () => Navigator.of(context).pop(true),
      );
    }
    if (q.options.isEmpty) {
      final until = q.state?.paidUntil;
      return _Message(
        icon: Icons.event_available_rounded,
        title: 'Paid 6 months ahead',
        body: 'A listing can be paid for up to six months at a time'
            '${until == null ? '' : ' - this one is live until ${_date(until)}'}. '
            'You can add more nearer the time.',
        action: 'Done',
        onAction: () => Navigator.of(context).pop(false),
      );
    }
    final recommendation = recommendationText(q);
    final busy = _stage == _Stage.prompting;
    return Column(children: [
      Expanded(
        // Not a ListView: the form is short, and a lazily built list drops
        // the phone field (and its focus) whenever it scrolls out of view.
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(widget.listingName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: BrokaColors.textMid, fontSize: 13)),
            const SizedBox(height: 14),
            _PriceHero(quote: q),
            const SizedBox(height: 12),
            for (final line in feeReasons(q)) _Reason(line),
            if (recommendation != null) ...[
              const SizedBox(height: 14),
              _Recommendation(text: recommendation, strong: q.strength == 'strong'),
            ],
            const SizedBox(height: 20),
            const _Heading('How long should it stay up?'),
            const SizedBox(height: 10),
            for (final o in q.options)
              _MonthOption(
                key: Key('fee-months-${o.months}'),
                option: o,
                selected: o.months == _months,
                onTap: busy ? null : () => _choose(months: o.months),
              ),
            if (q.featuredAvailable && q.featuredPlans.isNotEmpty) ...[
              const SizedBox(height: 18),
              const _Heading('Feature it at the top of Home?'),
              const SizedBox(height: 4),
              const Text('Optional. Pinned where every buyer looks first, with a FEATURED badge.',
                  style: TextStyle(color: BrokaColors.textMid, fontSize: 12)),
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, children: [
                _Chip(
                  key: const Key('fee-featured-none'),
                  label: 'No thanks',
                  selected: _featured == null,
                  onTap: busy ? null : () => _choose(clearFeatured: true),
                ),
                for (final p in q.featuredPlans)
                  _Chip(
                    key: Key('fee-featured-${p.id}'),
                    label: '${p.days} days  +KES ${formatKesAmount(p.price)}',
                    selected: _featured == p.id,
                    onTap: busy ? null : () => _choose(featured: p.id),
                  ),
              ]),
            ],
            const SizedBox(height: 20),
            const _Heading('Pay with M-Pesa'),
            const SizedBox(height: 8),
            _PhoneField(controller: _phone, enabled: !busy, onChanged: () => setState(() => _error = null)),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!,
                  key: const Key('fee-error'),
                  style: const TextStyle(color: BrokaColors.danger, fontSize: 12.5, fontWeight: FontWeight.w600)),
            ],
          ]),
        ),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
        child: SizedBox(
          width: double.infinity,
          height: 54,
          child: ElevatedButton(
            key: const Key('fee-pay'),
            onPressed: busy ? null : _pay,
            style: ElevatedButton.styleFrom(
              backgroundColor: BrokaColors.neonGreen,
              disabledBackgroundColor: BrokaColors.neonGreen.withOpacity(0.5),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            child: busy
                ? const SizedBox(
                    width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white))
                : Text('Pay KES ${formatKesAmount(_total)} with M-Pesa',
                    style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w900)),
          ),
        ),
      ),
    ]);
  }
}

String _date(DateTime d) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${d.day} ${months[d.month - 1]} ${d.year}';
}

/// The list price crossed out, the seller's price, and the saving.
class _PriceHero extends StatelessWidget {
  const _PriceHero({required this.quote});
  final ListingFeeQuote quote;

  @override
  Widget build(BuildContext context) {
    final discounted = quote.monthlyFee < quote.listPrice;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: BrokaColors.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BrokaColors.gold.withOpacity(0.35)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (discounted)
              Text('KES ${formatKesAmount(quote.listPrice)}',
                  key: const Key('fee-list-price'),
                  style: const TextStyle(
                      color: BrokaColors.textMid,
                      fontSize: 14,
                      decoration: TextDecoration.lineThrough,
                      decorationColor: BrokaColors.textMid)),
            Text.rich(
                TextSpan(children: [
                  TextSpan(
                      text: 'KES ${formatKesAmount(quote.monthlyFee)}',
                      style: const TextStyle(color: BrokaColors.textHigh, fontSize: 30, fontWeight: FontWeight.w900)),
                  const TextSpan(
                      text: ' / month',
                      style: TextStyle(color: BrokaColors.textMid, fontSize: 14, fontWeight: FontWeight.w600)),
                ]),
                key: const Key('fee-monthly')),
          ]),
        ),
        if (discounted && quote.discountPercent > 0)
          Container(
            key: const Key('fee-discount'),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: BrokaColors.neonGreen.withOpacity(0.15),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text('${quote.discountPercent}% off',
                style: const TextStyle(color: BrokaColors.neonGreen, fontSize: 13, fontWeight: FontWeight.w900)),
          ),
      ]),
    );
  }
}

class _Reason extends StatelessWidget {
  const _Reason(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(Icons.check_rounded, size: 14, color: BrokaColors.neonGreen),
          ),
          const SizedBox(width: 6),
          Expanded(child: Text(text, style: const TextStyle(color: BrokaColors.textMid, fontSize: 12.5))),
        ]),
      );
}

class _Recommendation extends StatelessWidget {
  const _Recommendation({required this.text, required this.strong});
  final String text;
  final bool strong;

  @override
  Widget build(BuildContext context) {
    final color = strong ? BrokaColors.warning : BrokaColors.neonBlue;
    return Container(
      key: const Key('fee-recommendation'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.lightbulb_rounded, color: color, size: 18),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: const TextStyle(color: BrokaColors.textHigh, fontSize: 12.5))),
      ]),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: const TextStyle(color: BrokaColors.textHigh, fontSize: 15, fontWeight: FontWeight.w800));
}

class _MonthOption extends StatelessWidget {
  const _MonthOption({super.key, required this.option, required this.selected, required this.onTap});
  final FeeOption option;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final months = option.months == 1 ? '1 month' : '${option.months} months';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Semantics(
        selected: selected,
        button: true,
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: selected ? BrokaColors.gold.withOpacity(0.10) : BrokaColors.bgCard,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: selected ? BrokaColors.gold.withOpacity(0.6) : BrokaColors.border,
                width: selected ? 2 : 1,
              ),
            ),
            child: Row(children: [
              Icon(selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                  color: selected ? BrokaColors.gold : BrokaColors.textMid, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  // Wraps: "5 months" and its badge beside a total don't fit
                  // a 360-wide phone on one line.
                  Wrap(spacing: 8, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    Text(months,
                        style: const TextStyle(color: BrokaColors.textHigh, fontSize: 14, fontWeight: FontWeight.w800)),
                    if (option.recommended) ...[
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                        decoration: BoxDecoration(
                          color: BrokaColors.gold.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Text('Recommended',
                            style: TextStyle(color: BrokaColors.gold, fontSize: 10, fontWeight: FontWeight.w800)),
                      ),
                    ],
                  ]),
                  if (option.months > 1)
                    Text(
                        'KES ${formatKesAmount(option.perMonth.round())} a month'
                        '${option.savingPercent > 0 ? ' · save ${option.savingPercent}%' : ''}',
                        style: const TextStyle(color: BrokaColors.textMid, fontSize: 11.5)),
                ]),
              ),
              Text('KES ${formatKesAmount(option.total)}',
                  style: TextStyle(
                      color: selected ? BrokaColors.gold : BrokaColors.textHigh,
                      fontSize: 15,
                      fontWeight: FontWeight.w900)),
            ]),
          ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({super.key, required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: selected ? BrokaColors.neonPink.withOpacity(0.14) : BrokaColors.bgCard,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: selected ? BrokaColors.neonPink : BrokaColors.border),
          ),
          child: Text(label,
              style: TextStyle(
                  color: selected ? BrokaColors.neonPink : BrokaColors.textHigh,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w700)),
        ),
      );
}

class _PhoneField extends StatelessWidget {
  const _PhoneField({required this.controller, required this.enabled, required this.onChanged});
  final TextEditingController controller;
  final bool enabled;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(
          color: BrokaColors.bgCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: BrokaColors.border),
        ),
        child: TextField(
          key: const Key('fee-phone'),
          controller: controller,
          enabled: enabled,
          keyboardType: TextInputType.phone,
          style: const TextStyle(color: BrokaColors.textHigh, fontSize: 16, fontWeight: FontWeight.w700),
          decoration: const InputDecoration(
            hintText: '0712 345 678',
            hintStyle: TextStyle(color: BrokaColors.textLow, fontSize: 14),
            prefixIcon: Icon(Icons.phone_android_rounded, color: BrokaColors.neonGreen, size: 20),
            border: InputBorder.none,
            contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 16),
          ),
          onChanged: (_) => onChanged(),
        ),
      );
}

/// A full-screen state: waiting, paid, slow, failed to load.
class _Message extends StatelessWidget {
  const _Message({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.iconColor = BrokaColors.gold,
    this.action,
    this.onAction,
    this.busy = false,
  });
  final IconData icon;
  final Color iconColor;
  final String title;
  final String body;
  final String? action;
  final VoidCallback? onAction;
  final bool busy;

  @override
  Widget build(BuildContext context) => Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, color: iconColor, size: 64),
            const SizedBox(height: 16),
            Text(title,
                textAlign: TextAlign.center,
                style: const TextStyle(color: BrokaColors.textHigh, fontSize: 20, fontWeight: FontWeight.w900)),
            const SizedBox(height: 8),
            Text(body,
                textAlign: TextAlign.center,
                style: const TextStyle(color: BrokaColors.textMid, fontSize: 13.5, height: 1.4)),
            if (busy) ...[
              const SizedBox(height: 22),
              const CircularProgressIndicator(color: BrokaColors.neonGreen),
            ],
            if (action != null) ...[
              const SizedBox(height: 22),
              ElevatedButton(
                onPressed: onAction,
                style: ElevatedButton.styleFrom(
                  backgroundColor: BrokaColors.gold,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: Text(action!, style: const TextStyle(fontWeight: FontWeight.w800)),
              ),
            ],
          ]),
        ),
      );
}
