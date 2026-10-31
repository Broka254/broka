// BROKA - Listing fee: choose how long to list, then pay.
//
// Opened three ways, one screen for all of them:
//   * straight after Go live, when a new listing waits for its first
//     payment before buyers can see it ([afterCreate]);
//   * "Pay to publish" on a listing that is still unpaid;
//   * "Renew" on a listing whose paid time is ending or over.
//
// What the seller sees is PRICING.md's sell screen: the list price crossed
// out and their price, why it is that price, 2, 4 or 6 months with the recommended
// one picked. The listing fee is the only charge: featured placement is no
// longer sold (2026-10-12). Every amount is the server's; Pay asks M-Pesa
// for exactly the total shown, because the server works it out the same way.
//
// Paying is the shared checkout: "Continue to payment" opens the payment
// methods, then the M-Pesa screen with the number to pay from at the top
// (features/payments/).
//
// Pops `true` once paid, so Go live can celebrate.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/utils/result.dart';
import '../../../main.dart';
import '../../../utils/price_format.dart';
import '../../payments/domain/checkout.dart';
import '../../payments/presentation/checkout_widgets.dart';
import '../../payments/presentation/payment_method_screen.dart';
import '../../launch_offers/domain/launch_offers.dart';
import '../../launch_offers/presentation/launch_offer_widgets.dart';
import '../data/listing_fee_repository.dart';
import '../domain/listing_fee.dart';

enum _Stage { loading, loadFailed, choosing }

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
  int _months = 2;
  String? _error;
  bool _renewing = false;

  @override
  void initState() {
    super.initState();
    _load();
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

  int get _total => _quote?.option(_months)?.total ?? 0;

  /// One more launch window, free: the way back for a window that ran out
  /// while listing fees are off. The server refuses once fees turn on, and
  /// then renewals go through pay/ instead.
  Future<void> _renewFree() async {
    HapticFeedback.selectionClick();
    setState(() => _renewing = true);
    final r = await _repo.renewFree(listingId: widget.listingId);
    if (!mounted) return;
    switch (r) {
      case Success():
        Navigator.of(context).pop(true);
      case Failure(:final message):
        setState(() => _renewing = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          backgroundColor: BrokaColors.danger,
        ));
    }
  }

  /// A deadline exists and it is ending soon or past: with fees off the
  /// answer is a free renewal, not Done.
  bool _needsFreeRenew(ListingFeeQuote q) {
    if (q.storeCovered || q.state?.isStoreCovered == true) return false;
    final until = q.state?.paidUntil;
    if (until == null) return false;
    return until.difference(DateTime.now()) <= const Duration(days: 7);
  }

  void _choose(int months) {
    HapticFeedback.selectionClick();
    setState(() => _months = months);
  }

  CheckoutOrder get _order {
    final months = _months == 1 ? '1 month' : '$_months months';
    return CheckoutOrder(
      title: _title,
      subject: widget.listingName,
      lines: [
        CheckoutLine('Listed for $months', _quote?.option(_months)?.total ?? 0),
      ],
      total: _total,
    );
  }

  /// The months chosen, frozen: the checkout charges exactly
  /// what was on screen when Continue was pressed.
  MpesaCharge _charge() {
    final months = _months;
    return MpesaCharge(
      start: (phone, key) async {
        final r = await _repo.pay(
            listingId: widget.listingId, months: months, phone: phone, idempotencyKey: key);
        return switch (r) {
          Success(:final data) => Success(ChargeStarted(paymentId: data.id, amount: data.amount)),
          Failure(:final message, :final statusCode) => Failure(message, statusCode: statusCode),
        };
      },
      check: (id) async {
        final r = await _repo.paymentStatus(id);
        return switch (r) {
          Success(:final data) =>
            Success(ChargeProgress(succeeded: data.succeeded, pending: data.pending, paidUntil: data.paidUntil)),
          Failure(:final message, :final statusCode) => Failure(message, statusCode: statusCode),
        };
      },
    );
  }

  Future<void> _continue() async {
    HapticFeedback.selectionClick();
    final name = widget.listingName;
    final paid = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => PaymentMethodScreen(
        order: _order,
        charge: _charge(),
        success: CheckoutSuccess(
          title: 'Paid - buyers can see it',
          body: (until) => until == null ? name : '$name is live until ${_date(until)}.',
        ),
        popOnPaid: widget.afterCreate,
        pollEvery: widget.pollEvery,
        giveUpAfter: widget.giveUpAfter,
      ),
    ));
    if (paid == true && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final q = _quote;
    final canPay = _stage == _Stage.choosing && q != null && q.feesEnabled && q.options.isNotEmpty;
    return CheckoutScaffold(
      title: _title,
      icon: Icons.sell_rounded,
      body: _body(),
      bottom: canPay
          ? CheckoutButton(
              key: const Key('fee-continue'),
              label: 'Continue to payment · KES ${formatKesAmount(_total)}',
              onPressed: _continue,
            )
          : null,
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
        return CheckoutMessage(
          icon: Icons.wifi_off_rounded,
          title: "Couldn't load the price",
          body: _error ?? 'Try again.',
          action: 'Try again',
          onAction: _load,
        );
      case _Stage.choosing:
        return _choosing();
    }
  }

  Widget _choosing() {
    final q = _quote!;
    if (q.storeCovered || q.state?.isStoreCovered == true) {
      return CheckoutMessage(
        icon: Icons.storefront_rounded,
        title: 'Covered by your store plan',
        body: 'Listings in your store never pay a listing fee. '
            'This one stays live while your store plan is paid.',
        action: 'Done',
        onAction: () => Navigator.of(context).pop(true),
      );
    }
    if (!q.feesEnabled) {
      final offer = q.launchOffer;
      if (_needsFreeRenew(q)) {
        final expired = (q.state?.status == 'expired') ||
            (q.state?.paidUntil?.isBefore(DateTime.now()) ?? false);
        return CheckoutMessage(
          icon: Icons.schedule_rounded,
          iconColor: expired ? BrokaColors.danger : BrokaColors.warning,
          title: expired ? 'Your listing is offline' : 'Your window is running out',
          body: expired
              ? 'Buyers can\'t see "${widget.listingName}" until it is renewed. '
                  'Renewing is free while BROKA launches - one tap brings it back '
                  'for another ${offer?.freeDays ?? 60} days.'
              : '"${widget.listingName}" goes offline ${_date(q.state!.paidUntil!)}. '
                  'Renew now, free - another ${offer?.freeDays ?? 60} days, no M-Pesa needed. '
                  'We text you 2 days before every deadline.',
          action: 'Renew free',
          key: const Key('fee-renew-free'),
          onAction: _renewing ? null : _renewFree,
          busy: _renewing,
        );
      }
      return CheckoutMessage(
        icon: Icons.celebration_rounded,
        title: q.freeListing ? 'This listing is free' : 'Listing is free right now',
        body: q.freeListing && offer?.eligible == true
            ? 'Your launch offer covers it: ${offer!.freeDays} days free, '
                'no payment due. Only ${offer.remaining} free listings left after yours.'
            : 'There is nothing to pay while BROKA launches.',
        action: 'Done',
        onAction: () => Navigator.of(context).pop(true),
      );
    }
    if (q.options.isEmpty) {
      final until = q.state?.paidUntil;
      return CheckoutMessage(
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
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(widget.listingName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: BrokaColors.textMid, fontSize: 13)),
        const SizedBox(height: 14),
        if (_timeLeftFor(q) != null) ...[
          TimeLeftBanner(timeLeft: _timeLeftFor(q), subject: 'Your listing'),
          const SizedBox(height: 12),
        ],
        _PriceHero(quote: q),
        const SizedBox(height: 12),
        for (final line in feeReasons(q)) _Reason(line),
        if (recommendation != null) ...[
          const SizedBox(height: 14),
          _Recommendation(text: recommendation, strong: q.strength == 'strong'),
        ],
        const SizedBox(height: 22),
        const CheckoutLabel('How long should it stay up?'),
        const SizedBox(height: 10),
        for (final o in q.options)
          _MonthOption(
            key: Key('fee-months-${o.months}'),
            option: o,
            selected: o.months == _months,
            onTap: () => _choose(o.months),
          ),
      ]),
    );
  }
}

/// The quote's fee state as a countdown, for the banner above the price.
/// Null when the listing has no deadline to warn about.
TimeLeft? _timeLeftFor(ListingFeeQuote q) {
  final state = q.state;
  if (state == null || state.isStoreCovered) return null;
  final until = state.paidUntil;
  if (until == null) return null;
  final seconds = until.difference(DateTime.now()).inSeconds;
  if (seconds > 7 * 86400) return null;
  return TimeLeft(
    status: seconds <= 0 ? 'expired' : 'ending',
    label: seconds <= 0 ? 'Offline' : '${(seconds / 86400).ceil()}d left',
    secondsLeft: seconds < 0 ? 0 : seconds,
    daysLeft: seconds / 86400,
    goesOfflineAt: until,
    isExpiringSoon: seconds > 0,
  );
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
                  TextSpan(
                      text: quote.periodMonths == 1 ? ' / month' : ' / ${quote.periodMonths} months',
                      style: const TextStyle(color: BrokaColors.textMid, fontSize: 14, fontWeight: FontWeight.w600)),
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
