// BROKA - the store's plan: what it costs, paying for it, and what paying
// turns on (backend/api/domains/stores/billing.py; PRICING.md §5).
//
// Opened three ways, one screen for all of them:
//   * straight after "Open my store", when the new store is hidden until
//     its plan is paid (billing on);
//   * "Pay now" on My Store's plan card while the store is unpaid;
//   * "Manage plan" once it is paid - renew, or pay further ahead.
//
// Every amount is the server's rate card, never the app's; the plan's size
// follows the store's live listings, so the seller never picks a number the
// backend would refuse. Paying is the shared checkout
// (features/payments/): "Continue to payment" opens the methods, then the
// M-Pesa screen.
//
// Pops `true` once paid, so the caller can celebrate or refresh.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/utils/result.dart';
import '../../../main.dart';
import '../../../utils/price_format.dart';
import '../../payments/domain/checkout.dart';
import '../../payments/presentation/checkout_widgets.dart';
import '../../payments/presentation/payment_method_screen.dart';
import '../data/repositories/stores_repository.dart';
import '../domain/models/store_billing.dart';

enum _Stage { loading, loadFailed, ready }

class StoreBillingScreen extends StatefulWidget {
  const StoreBillingScreen({
    super.key,
    required this.storeId,
    required this.storeName,
    this.repository,
    this.pollEvery = const Duration(seconds: 3),
    this.giveUpAfter = const Duration(seconds: 150),
  });

  final String storeId;
  final String storeName;

  /// For tests.
  final StoresRepository? repository;
  final Duration pollEvery;
  final Duration giveUpAfter;

  @override
  State<StoreBillingScreen> createState() => _StoreBillingScreenState();
}

class _StoreBillingScreenState extends State<StoreBillingScreen> {
  StoresRepository get _repo => widget.repository ?? storesRepository;

  _Stage _stage = _Stage.loading;
  StoreBillingQuote? _quote;
  int _months = 1;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// The card first, then the plan priced for the store's own stock: the
  /// live count picks the size, so nobody has to know the bands.
  Future<void> _load() async {
    setState(() {
      _stage = _Stage.loading;
      _error = null;
    });
    final base = await _repo.billingQuote(widget.storeId);
    if (!mounted) return;
    if (base case Failure(:final message)) {
      setState(() {
        _error = message;
        _stage = _Stage.loadFailed;
      });
      return;
    }
    final listed = (base as Success<StoreBillingQuote>).data;
    final size = listed.liveListings < 1 ? 1 : listed.liveListings;
    final priced = await _repo.billingQuote(widget.storeId, listings: size);
    if (!mounted) return;
    switch (priced) {
      case Success(:final data):
        setState(() {
          _quote = data;
          _months = 1;
          _stage = _Stage.ready;
        });
      case Failure(:final message):
        setState(() {
          _error = message;
          _stage = _Stage.loadFailed;
        });
    }
  }

  StorePlanPeriod? get _period => _quote?.plan?.period(_months);

  int get _total => _period?.amount ?? 0;

  void _choose(int months) {
    HapticFeedback.selectionClick();
    setState(() => _months = months);
  }

  CheckoutOrder get _order {
    final plan = _quote!.plan!;
    final period = _period!;
    final months = _months == 1 ? '1 month' : '$_months months';
    return CheckoutOrder(
      title: 'Store plan',
      subject: widget.storeName,
      lines: [
        CheckoutLine('${plan.listings} listings · $months', period.total),
        if (period.setupFee > 0) CheckoutLine('Opening fee (one-off)', period.setupFee),
      ],
      total: period.amount,
    );
  }

  /// The size and months chosen, frozen: the checkout charges exactly what
  /// was on screen when Continue was pressed.
  MpesaCharge _charge() {
    final size = _quote!.plan!.listings;
    final months = _months;
    return MpesaCharge(
      start: (phone, key) async {
        final r = await _repo.payStorePlan(
            storeId: widget.storeId, listings: size, months: months,
            phone: phone, idempotencyKey: key);
        return switch (r) {
          Success(:final data) => Success(ChargeStarted(paymentId: data.id, amount: data.amount)),
          Failure(:final message, :final statusCode) => Failure(message, statusCode: statusCode),
        };
      },
      check: (id) async {
        final r = await _repo.storePaymentStatus(widget.storeId, id);
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
    final name = widget.storeName;
    final paid = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => PaymentMethodScreen(
        order: _order,
        charge: _charge(),
        success: CheckoutSuccess(
          title: 'Plan paid - your store is on',
          body: (until) => until == null
              ? '$name is visible to buyers again.'
              : '$name is visible to buyers until ${_date(until)}.',
        ),
        pollEvery: widget.pollEvery,
        giveUpAfter: widget.giveUpAfter,
      ),
    ));
    if (paid == true && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    // Nothing to buy without a priced plan - a store still in its grace
    // time shows where it stands and nothing else (no dead Pay button).
    final showPay = _stage == _Stage.ready && _quote?.plan != null;
    return CheckoutScaffold(
      title: 'Store plan',
      icon: Icons.storefront_rounded,
      body: _body(),
      bottom: showPay
          ? CheckoutButton(
              key: const Key('store-billing-continue'),
              label: 'Continue to payment · KES ${formatKesAmount(_total)}',
              onPressed: _total > 0 ? _continue : null,
            )
          : null,
    );
  }

  Widget _body() {
    switch (_stage) {
      case _Stage.loading:
        return const Center(child: CircularProgressIndicator(color: BrokaColors.gold));
      case _Stage.loadFailed:
        return CheckoutMessage(
          icon: Icons.wifi_off_rounded,
          title: "Couldn't load your plan",
          body: _error ?? 'Try again.',
          action: 'Try again',
          onAction: _load,
        );
      case _Stage.ready:
        return _ready();
    }
  }

  Widget _ready() {
    final q = _quote!;
    final plan = q.plan;
    if (q.current.active && plan == null) {
      // Grace time from before billing switched on, or a quote the server
      // has no size for: nothing to sell, say where it stands.
      return CheckoutMessage(
        icon: Icons.check_circle_outline_rounded,
        iconColor: BrokaColors.success,
        title: 'Your plan is paid up',
        body: q.current.paidUntil == null
            ? 'Buyers can see your store.'
            : 'Buyers can see your store until ${_date(q.current.paidUntil!)}.',
        action: 'Done',
        onAction: () => Navigator.of(context).pop(false),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(widget.storeName,
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: BrokaColors.textMid, fontSize: 13)),
        const SizedBox(height: 14),
        _StatusCard(storeName: widget.storeName, current: q.current),
        const SizedBox(height: 16),
        if (plan != null) ...[
          CheckoutCard(
            accent: BrokaColors.gold,
            child: Row(children: [
              const Icon(Icons.inventory_2_outlined, color: BrokaColors.gold, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${q.rateCard.name} · up to ${plan.listings} listings',
                      key: const Key('store-billing-plan'),
                      style: const TextStyle(color: BrokaColors.textHigh, fontSize: 15,
                          fontWeight: FontWeight.w800)),
                  const SizedBox(height: 2),
                  Text('KES ${formatKesAmount(plan.monthlyPrice)} a month'
                      '${q.liveListings > 1 ? ' · ${q.liveListings} live now' : ''}',
                      style: const TextStyle(color: BrokaColors.textMid, fontSize: 12.5)),
                ]),
              ),
            ]),
          ),
          const SizedBox(height: 12),
          Text(
            q.setupFee > 0
                ? 'Plus a one-off KES ${formatKesAmount(q.setupFee)} opening fee. '
                    'Pay for ${q.setupFeeWaivedFromMonths} months or more and it is waived.'
                : 'Opening fee already paid.',
            style: const TextStyle(color: BrokaColors.textMid, fontSize: 12.5, height: 1.4),
          ),
          const SizedBox(height: 22),
          const CheckoutLabel('How long should it run?'),
          const SizedBox(height: 10),
          for (final months in q.monthsOptions)
            if (plan.period(months) != null)
              _MonthOption(
                key: Key('store-billing-months-$months'),
                period: plan.period(months)!,
                waived: plan.period(months)!.setupFee == 0 && q.setupFee > 0,
                selected: months == _months,
                onTap: () => _choose(months),
              ),
        ],
      ]),
    );
  }
}

String _date(DateTime d) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${d.day} ${months[d.month - 1]} ${d.year}';
}

/// Where the store stands right now: offline and hidden, or on until a date.
class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.storeName, required this.current});
  final String storeName;
  final StoreBilling current;

  @override
  Widget build(BuildContext context) {
    final active = current.active;
    final color = active ? BrokaColors.success : BrokaColors.warning;
    return CheckoutCard(
      accent: color,
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(active ? Icons.visibility_rounded : Icons.visibility_off_rounded,
            color: color, size: 22),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(active ? 'Your store is on' : 'Your store is offline',
                key: const Key('store-billing-status'),
                style: const TextStyle(color: BrokaColors.textHigh, fontSize: 15,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 3),
            Text(
              active
                  ? 'Buyers can see $storeName and its products'
                      '${current.paidUntil == null ? '' : ' until ${_date(current.paidUntil!)}'}.'
                  : "Buyers can't see $storeName or its products until the plan "
                      'is paid. Your link, products and settings are all kept.',
              style: const TextStyle(color: BrokaColors.textMid, fontSize: 12.5, height: 1.4),
            ),
          ]),
        ),
      ]),
    );
  }
}

/// One prepay period, its total the amount actually charged.
class _MonthOption extends StatelessWidget {
  const _MonthOption({
    super.key,
    required this.period,
    required this.selected,
    required this.onTap,
    this.waived = false,
  });

  final StorePlanPeriod period;
  final bool selected;
  final VoidCallback onTap;

  /// This period's opening fee is 0 where one is owed: say why.
  final bool waived;

  @override
  Widget build(BuildContext context) {
    final months = period.months == 1 ? '1 month' : '${period.months} months';
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
                  Wrap(spacing: 8, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(months, style: const TextStyle(color: BrokaColors.textHigh,
                            fontSize: 14, fontWeight: FontWeight.w800)),
                        if (waived)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: BrokaColors.neonGreen.withOpacity(0.15),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: const Text('Opening fee waived',
                                style: TextStyle(color: BrokaColors.neonGreen, fontSize: 10,
                                    fontWeight: FontWeight.w800)),
                          ),
                      ]),
                  if (period.months > 1)
                    Text(
                        'KES ${formatKesAmount(period.perMonth.round())} a month'
                        '${period.savingPercent > 0 ? ' · save ${period.savingPercent}%' : ''}'
                        '${period.setupFee > 0 ? ' · + KES ${formatKesAmount(period.setupFee)} opening fee' : ''}',
                        style: const TextStyle(color: BrokaColors.textMid, fontSize: 11.5)),
                ]),
              ),
              Text('KES ${formatKesAmount(period.amount)}',
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
