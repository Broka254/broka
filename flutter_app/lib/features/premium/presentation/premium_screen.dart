// BROKA Premium: what your plan gives you, what is left this month, and
// buying or renewing a plan with M-Pesa.
//
// Opened from Menu, and from any refused premium feature ("See plans" in
// premium_upsell.dart) with the plan that would do picked for them. Every
// price and allowance is the server's (GET /pricing/plans, GET /premium/me);
// Pay asks for exactly the total shown, because the server charges the
// catalogue price, never an amount the app sends.
//
// A plan cheaper than the one running can't be bought until it ends - the
// server refuses it, so the screen says so instead of offering Pay.
//
// Paying is the shared checkout: "Continue to payment" opens the payment
// methods, then the M-Pesa screen with the number to pay from at the top
// (features/payments/).
//
// Pops `true` once a plan is paid.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/utils/result.dart';
import '../../../main.dart';
import '../../../utils/price_format.dart';
import '../../payments/domain/checkout.dart';
import '../../payments/presentation/checkout_widgets.dart';
import '../../payments/presentation/payment_method_screen.dart';
import '../data/premium_repository.dart';
import '../domain/premium.dart';

enum _Stage { loading, loadFailed, choosing }

class PremiumScreen extends StatefulWidget {
  const PremiumScreen({
    super.key,
    this.highlight,
    this.repository,
    this.pollEvery = const Duration(seconds: 3),
    this.giveUpAfter = const Duration(seconds: 150),
  });

  /// The plan to pick first: the one a refused feature suggested.
  final String? highlight;

  /// For tests.
  final PremiumRepository? repository;
  final Duration pollEvery;

  /// How long to watch for M-Pesa before saying it is slow. The plan still
  /// starts when M-Pesa confirms.
  final Duration giveUpAfter;

  @override
  State<PremiumScreen> createState() => _PremiumScreenState();
}

class _PremiumScreenState extends State<PremiumScreen> {
  PremiumRepository get _repo => widget.repository ?? premiumRepository;

  _Stage _stage = _Stage.loading;
  PremiumStatus? _status;
  List<PremiumPlan> _plans = const [];
  String? _planId;
  int _months = 1;
  String? _error;

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
    final results = await Future.wait([_repo.me(), _repo.plans()]);
    if (!mounted) return;
    final me = results[0] as Result<PremiumStatus>;
    final plans = results[1] as Result<List<PremiumPlan>>;
    switch ((me, plans)) {
      case (Success(data: final status), Success(data: final list)):
        final ids = list.map((p) => p.id).toSet();
        setState(() {
          _status = status;
          _plans = list;
          _planId = [widget.highlight, status.planId, list.isEmpty ? null : list.first.id]
              .firstWhere((id) => id != null && ids.contains(id), orElse: () => null);
          _stage = _Stage.choosing;
        });
      case (Failure(:final message), _) || (_, Failure(:final message)):
        setState(() {
          _error = message;
          _stage = _Stage.loadFailed;
        });
    }
  }

  PremiumPlan? _plan(String? id) {
    for (final p in _plans) {
      if (p.id == id) return p;
    }
    return null;
  }

  PremiumPlan? get _chosen => _plan(_planId);
  PremiumPlan? get _current => _plan(_status?.planId);

  /// A cheaper plan while a dearer one runs: bought when that one ends.
  bool get _isDowngrade {
    final current = _current, chosen = _chosen;
    return current != null && chosen != null && chosen.monthlyPrice < current.monthlyPrice;
  }

  int get _total => _chosen?.period(_months)?.total ?? 0;

  void _choose({String? plan, int? months}) {
    HapticFeedback.selectionClick();
    setState(() {
      if (plan != null) _planId = plan;
      if (months != null) _months = months;
      _error = null;
    });
  }

  /// The plan and months chosen, frozen: the checkout charges exactly
  /// what was on screen when Continue was pressed.
  MpesaCharge _charge(PremiumPlan plan) {
    final months = _months;
    return MpesaCharge(
      start: (phone, key) async {
        final r = await _repo.subscribe(planId: plan.id, months: months, phone: phone, idempotencyKey: key);
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
    final plan = _chosen;
    if (plan == null || _isDowngrade) return;
    HapticFeedback.selectionClick();
    final months = _months == 1 ? '1 month' : '$_months months';
    final paid = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => PaymentMethodScreen(
        order: CheckoutOrder(
          title: 'BROKA ${plan.name}',
          subject: 'Premium plan',
          lines: [CheckoutLine('${plan.name} for $months', _total)],
          total: _total,
        ),
        charge: _charge(plan),
        success: CheckoutSuccess(
          title: "You're on BROKA ${plan.name}",
          body: (until) => until == null ? 'Your plan has started.' : 'Paid until ${_date(until)}.',
        ),
        pollEvery: widget.pollEvery,
        giveUpAfter: widget.giveUpAfter,
      ),
    ));
    if (paid == true && mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final canPay = _stage == _Stage.choosing && (_status?.enabled ?? false) && _chosen != null && !_isDowngrade;
    return CheckoutScaffold(
      title: 'BROKA Premium',
      icon: Icons.workspace_premium_rounded,
      body: _body(),
      bottom: canPay
          ? CheckoutButton(
              key: const Key('premium-continue'),
              label: 'Continue to payment · KES ${formatKesAmount(_total)}',
              onPressed: _continue,
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
          title: "Couldn't load the plans",
          body: _error ?? 'Try again.',
          action: 'Try again',
          onAction: _load,
        );
      case _Stage.choosing:
        return _choosing();
    }
  }

  Widget _choosing() {
    final status = _status!;
    if (!status.enabled) {
      return const CheckoutMessage(
        key: Key('premium-off'),
        icon: Icons.celebration_rounded,
        title: "It's all free right now",
        body: 'Voice mode, the Buying Agent, AI covers and texts from Zeno are free for '
            'everyone while BROKA launches. Nothing to pay.',
      );
    }
    final chosen = _chosen;
    return Column(children: [
      Expanded(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (status.hasPlan) _CurrentPlan(status: status) else _NoPlan(status: status),
            const SizedBox(height: 20),
            CheckoutLabel(status.hasPlan ? 'Renew or change plan' : 'Choose a plan'),
            const SizedBox(height: 10),
            for (final p in _plans)
              _PlanCard(
                key: Key('premium-plan-${p.id}'),
                plan: p,
                selected: p.id == _planId,
                current: p.id == status.planId,
                onTap: () => _choose(plan: p.id),
              ),
            if (chosen != null && _isDowngrade)
              _Note(
                key: const Key('premium-downgrade-note'),
                text: "You're on ${_current!.name} until ${_date(status.paidUntil!)}. "
                    'You can move to ${chosen.name} when it ends.',
              )
            else if (chosen != null) ...[
              if (_current != null && chosen.id != _current!.id)
                _Note(
                  text: 'Your unused ${_current!.name} days become ${chosen.name} days, '
                      'then the months you buy are added. ${chosen.name} allowances start today.',
                )
              else if (_current != null && status.paidUntil != null)
                _Note(text: 'Added after ${_date(status.paidUntil!)}, so renewing early loses nothing.'),
              const SizedBox(height: 18),
              const CheckoutLabel('For how long?'),
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final period in chosen.periods)
                  _PeriodChip(
                    key: Key('premium-months-${period.months}'),
                    period: period,
                    selected: period.months == _months,
                    onTap: () => _choose(months: period.months),
                  ),
              ]),
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!,
                  key: const Key('premium-error'),
                  style: const TextStyle(color: BrokaColors.danger, fontSize: 12.5, fontWeight: FontWeight.w600)),
            ],
          ]),
        ),
      ),
    ]);
  }
}

String _date(DateTime d) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  return '${d.day} ${months[d.month - 1]} ${d.year}';
}

/// The plan running, until when, and what is left of this month.
class _CurrentPlan extends StatelessWidget {
  const _CurrentPlan({required this.status});
  final PremiumStatus status;

  @override
  Widget build(BuildContext context) {
    final renews = status.renewsAt;
    return Container(
      key: const Key('premium-usage'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: BrokaColors.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BrokaColors.gold.withOpacity(0.45)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.workspace_premium_rounded, color: BrokaColors.gold, size: 22),
          const SizedBox(width: 8),
          Expanded(
            child: Text('BROKA ${status.planName ?? ''}',
                style: const TextStyle(color: BrokaColors.textHigh, fontSize: 18, fontWeight: FontWeight.w900)),
          ),
        ]),
        if (status.paidUntil != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text('Paid until ${_date(status.paidUntil!)}',
                style: const TextStyle(color: BrokaColors.textMid, fontSize: 12.5)),
          ),
        const SizedBox(height: 12),
        for (final f in PremiumFeature.all)
          if ((status.usage[f]?.allowance ?? 0) > 0) _UsageRow(feature: f, allowance: status.usage[f]!),
        if (renews != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text("This month's allowances renew on ${_date(renews)}.",
                style: const TextStyle(color: BrokaColors.textMid, fontSize: 11.5)),
          ),
      ]),
    );
  }
}

class _UsageRow extends StatelessWidget {
  const _UsageRow({required this.feature, required this.allowance});
  final String feature;
  final Allowance allowance;

  @override
  Widget build(BuildContext context) {
    // Watches are how many run at once, not a monthly count.
    final label = feature == PremiumFeature.watches
        ? '${allowance.used} of ${allowance.allowance} running'
        : '${allowance.left} of ${allowance.allowance} left';
    final share = allowance.allowance == 0 ? 0.0 : allowance.left / allowance.allowance;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(
            child: Text(PremiumFeature.title(feature),
                style: const TextStyle(color: BrokaColors.textHigh, fontSize: 13, fontWeight: FontWeight.w700)),
          ),
          Text(label, style: const TextStyle(color: BrokaColors.textMid, fontSize: 12)),
        ]),
        const SizedBox(height: 5),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: feature == PremiumFeature.watches ? 1 - share : share,
            minHeight: 5,
            backgroundColor: BrokaColors.border,
            color: BrokaColors.gold,
          ),
        ),
      ]),
    );
  }
}

/// No plan yet: what is free, and the free AI cover tries left.
class _NoPlan extends StatelessWidget {
  const _NoPlan({required this.status});
  final PremiumStatus status;

  @override
  Widget build(BuildContext context) {
    final covers = status.trial[PremiumFeature.aiCovers] ?? 0;
    final listings = status.trial[PremiumFeature.aiDescriptions] ?? 0;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: BrokaColors.bgCard,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BrokaColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Buying and selling on BROKA stays free',
            style: TextStyle(color: BrokaColors.textHigh, fontSize: 15, fontWeight: FontWeight.w800)),
        const SizedBox(height: 6),
        const Text('Chatting with Zeno, negotiating, bidding and uploading your own photos '
            'cost nothing. A plan adds the things that cost BROKA money to run.',
            style: TextStyle(color: BrokaColors.textMid, fontSize: 12.5, height: 1.4)),
        if (covers > 0) ...[
          const SizedBox(height: 8),
          Text(covers == 1 ? 'You have 1 free AI cover try left.' : 'You have $covers free AI cover tries left.',
              key: const Key('premium-trial'),
              style: const TextStyle(color: BrokaColors.gold, fontSize: 12.5, fontWeight: FontWeight.w700)),
        ],
        // One listing written by Zeno from its photo, free (plans.FREE_TRIAL):
        // the way to see what a plan does before paying for one.
        if (listings > 0) ...[
          const SizedBox(height: 6),
          const Text('Your first listing written by Zeno is free - tap Sell, take a photo, and let Zeno list it.',
              key: Key('premium-trial-zeno'),
              style: TextStyle(color: BrokaColors.gold, fontSize: 12.5, fontWeight: FontWeight.w700, height: 1.4)),
        ],
      ]),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    super.key,
    required this.plan,
    required this.selected,
    required this.current,
    required this.onTap,
  });
  final PremiumPlan plan;
  final bool selected;
  final bool current;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final lines = [
      for (final f in PremiumFeature.all)
        if (plan.allowance(f) > 0)
          f == PremiumFeature.aiCovers && plan.aiCoverListings > 0
              ? '${PremiumFeature.describe(f, plan.allowance(f))} - covers for about '
                  '${plan.aiCoverListings} ${plan.aiCoverListings == 1 ? 'listing' : 'listings'}'
              : PremiumFeature.describe(f, plan.allowance(f)),
      if (plan.prioritySupportMinutes > 0) 'Priority support calls',
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Semantics(
        selected: selected,
        button: true,
        child: GestureDetector(
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: selected ? BrokaColors.gold.withOpacity(0.10) : BrokaColors.bgCard,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: selected ? BrokaColors.gold.withOpacity(0.7) : BrokaColors.border,
                width: selected ? 2 : 1,
              ),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    Text(plan.name,
                        style: const TextStyle(color: BrokaColors.textHigh, fontSize: 17, fontWeight: FontWeight.w900)),
                    if (current)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: BrokaColors.neonGreen.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Text('Your plan',
                            style: TextStyle(color: BrokaColors.neonGreen, fontSize: 10.5, fontWeight: FontWeight.w800)),
                      ),
                  ]),
                ),
                Text.rich(TextSpan(children: [
                  TextSpan(
                      text: 'KES ${formatKesAmount(plan.monthlyPrice)}',
                      style: TextStyle(
                          color: selected ? BrokaColors.gold : BrokaColors.textHigh,
                          fontSize: 16,
                          fontWeight: FontWeight.w900)),
                  const TextSpan(text: ' /mo', style: TextStyle(color: BrokaColors.textMid, fontSize: 12)),
                ])),
              ]),
              if (plan.pitch.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(plan.pitch, style: const TextStyle(color: BrokaColors.textMid, fontSize: 12.5)),
              ],
              const SizedBox(height: 8),
              for (final line in lines)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: Icon(Icons.check_rounded, size: 14, color: BrokaColors.neonGreen),
                    ),
                    const SizedBox(width: 6),
                    Expanded(child: Text(line, style: const TextStyle(color: BrokaColors.textHigh, fontSize: 12.5))),
                  ]),
                ),
              const SizedBox(height: 4),
              const Text('A month is 30 days.', style: TextStyle(color: BrokaColors.textLow, fontSize: 10.5)),
            ]),
          ),
        ),
      ),
    );
  }
}

class _PeriodChip extends StatelessWidget {
  const _PeriodChip({super.key, required this.period, required this.selected, required this.onTap});
  final PlanPeriod period;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final months = period.months == 1 ? '1 month' : '${period.months} months';
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: selected ? BrokaColors.gold.withOpacity(0.14) : BrokaColors.bgCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: selected ? BrokaColors.gold : BrokaColors.border),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(months,
              style: TextStyle(
                  color: selected ? BrokaColors.gold : BrokaColors.textHigh,
                  fontSize: 13,
                  fontWeight: FontWeight.w800)),
          Text('KES ${formatKesAmount(period.total)}'
              '${period.savingPercent > 0 ? ' · save ${period.savingPercent}%' : ''}',
              style: const TextStyle(color: BrokaColors.textMid, fontSize: 11)),
        ]),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({super.key, required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(top: 2),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: BrokaColors.neonBlue.withOpacity(0.10),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: BrokaColors.neonBlue.withOpacity(0.4)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.info_outline_rounded, color: BrokaColors.neonBlue, size: 18),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(color: BrokaColors.textHigh, fontSize: 12.5))),
        ]),
      );
}
