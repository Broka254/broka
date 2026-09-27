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
// Pops `true` once a plan is paid.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/utils/result.dart';
import '../../../main.dart';
import '../../../services/api_service.dart';
import '../../../utils/price_format.dart';
import '../../listing_fee/data/listing_fee_repository.dart';
import '../data/premium_repository.dart';
import '../domain/premium.dart';

enum _Stage { loading, loadFailed, choosing, prompting, waiting, slow, paid }

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
  final _phone = TextEditingController();
  String? _error;
  PlanPayment? _payment;

  // Kept across a timed-out attempt so Pay re-sends the same request and
  // gets the prompt already on the phone, not a second one.
  String? _attemptKey;
  Timer? _poll;
  DateTime? _waitingSince;
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
      _attemptKey = null;
    });
  }

  Future<void> _pay() async {
    final plan = _chosen;
    if (plan == null || _stage == _Stage.prompting || _isDowngrade) return;
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
    final r = await _repo.subscribe(
      planId: plan.id,
      months: _months,
      phone: _phone.text.trim(),
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
          // Only a request that may not have arrived is re-sent under the
          // same key.
          if (statusCode != null) _attemptKey = null;
        });
    }
  }

  void _startWaiting(PlanPayment payment) {
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
    final Result<PlanPayment> r;
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
        title: const Text('BROKA Premium',
            style: TextStyle(color: BrokaColors.textHigh, fontSize: 17, fontWeight: FontWeight.w800)),
      ),
      body: SafeArea(child: _body()),
    );
  }

  Widget _body() {
    switch (_stage) {
      case _Stage.loading:
        return const Center(child: CircularProgressIndicator(color: BrokaColors.gold));
      case _Stage.loadFailed:
        return _Message(
          icon: Icons.wifi_off_rounded,
          title: "Couldn't load the plans",
          body: _error ?? 'Try again.',
          action: 'Try again',
          onAction: _load,
        );
      case _Stage.waiting:
        return _Message(
          key: const Key('premium-waiting'),
          icon: Icons.phone_android_rounded,
          title: 'Check your phone',
          body: 'Enter your M-Pesa PIN to pay KES ${formatKesAmount(_payment?.amount ?? _total)}. '
              'This screen updates as soon as M-Pesa confirms.',
          busy: true,
        );
      case _Stage.slow:
        return _Message(
          key: const Key('premium-slow'),
          icon: Icons.hourglass_bottom_rounded,
          title: 'Waiting for M-Pesa',
          body: "M-Pesa hasn't confirmed yet. If you entered your PIN, your plan starts as soon "
              'as it does - you can close this and come back.',
          action: 'Check again',
          onAction: () => _startWaiting(_payment!),
        );
      case _Stage.paid:
        final plan = _plan(_payment?.planId) ?? _chosen;
        final until = _payment?.paidUntil;
        return _Message(
          key: const Key('premium-paid'),
          icon: Icons.workspace_premium_rounded,
          title: "You're on BROKA ${plan?.name ?? 'Premium'}",
          body: until == null ? 'Your plan has started.' : 'Paid until ${_date(until)}.',
          action: 'Done',
          onAction: () => Navigator.of(context).pop(true),
        );
      case _Stage.prompting:
      case _Stage.choosing:
        return _choosing();
    }
  }

  Widget _choosing() {
    final status = _status!;
    if (!status.enabled) {
      return const _Message(
        key: Key('premium-off'),
        icon: Icons.celebration_rounded,
        title: "It's all free right now",
        body: 'Voice mode, the Buying Agent, AI covers and texts from Zeno are free for '
            'everyone while BROKA launches. Nothing to pay.',
      );
    }
    final chosen = _chosen;
    final busy = _stage == _Stage.prompting;
    return Column(children: [
      Expanded(
        // Not a ListView: a lazily built list drops the phone field (and
        // its focus) when it scrolls out of view.
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 18),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (status.hasPlan) _CurrentPlan(status: status) else _NoPlan(status: status),
            const SizedBox(height: 20),
            _Heading(status.hasPlan ? 'Renew or change plan' : 'Choose a plan'),
            const SizedBox(height: 10),
            for (final p in _plans)
              _PlanCard(
                key: Key('premium-plan-${p.id}'),
                plan: p,
                selected: p.id == _planId,
                current: p.id == status.planId,
                onTap: busy ? null : () => _choose(plan: p.id),
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
              const _Heading('For how long?'),
              const SizedBox(height: 10),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final period in chosen.periods)
                  _PeriodChip(
                    key: Key('premium-months-${period.months}'),
                    period: period,
                    selected: period.months == _months,
                    onTap: busy ? null : () => _choose(months: period.months),
                  ),
              ]),
              const SizedBox(height: 20),
              const _Heading('Pay with M-Pesa'),
              const SizedBox(height: 8),
              _PhoneField(controller: _phone, enabled: !busy, onChanged: () => setState(() => _error = null)),
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
      if (chosen != null && !_isDowngrade)
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
          child: SizedBox(
            width: double.infinity,
            height: 54,
            child: ElevatedButton(
              key: const Key('premium-pay'),
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

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: const TextStyle(color: BrokaColors.textHigh, fontSize: 15, fontWeight: FontWeight.w800));
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
          key: const Key('premium-phone'),
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

/// A full-screen state: waiting, paid, slow, failed to load, premium off.
class _Message extends StatelessWidget {
  const _Message({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.action,
    this.onAction,
    this.busy = false,
  });
  final IconData icon;
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
            Icon(icon, color: BrokaColors.gold, size: 64),
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
