// BROKA - what the app does when a premium feature is refused.
//
// The server refuses with a 402 whose detail says why in words ("You've
// used this month's 20 AI cover tries on BROKA Pro. They renew on 12 Oct -
// or move up to Elite for 60 a month.") and which plan would do
// ("upgrade_to"). The words are shown as they are; this sheet adds the way
// to the plans.
//
// 2026-10-08: and the case for paying. Sellers were shown one grey
// sentence and a "See plans" button, and few tapped it. Given the
// [feature], the sheet now says what it does for the sale in concrete
// terms, what else the suggested plan includes, and what it costs a day
// - the plan's real numbers from GET /pricing/plans, never figures typed
// into the app.
import 'package:flutter/material.dart';

import '../../../core/network/api_client.dart';
import '../../../core/utils/result.dart';
import '../../../main.dart';
import '../data/premium_repository.dart';
import '../domain/premium.dart';

/// A premium feature's refusal (backend api/domains/premium/entitlements.py).
bool isPlanRefusal(int? statusCode) => statusCode == 402;

/// The plan the refusal suggests, when it says (ApiException.details).
String? upgradeToOf(ApiException e) => e.details?['upgrade_to'] as String?;

/// What a feature does for a sale, in a headline and three concrete lines.
class UpsellPitch {
  const UpsellPitch(this.icon, this.headline, this.points);
  final IconData icon;
  final String headline;
  final List<String> points;

  static UpsellPitch? of(String? feature) => switch (feature) {
        PremiumFeature.aiDescriptions => const UpsellPitch(
            Icons.auto_awesome_rounded,
            'Let Zeno write listings that sell',
            [
              'Zeno reads your photo and writes the facts buyers look for - brand, model, specs, condition.',
              "It asks you only what a photo can't show, so buyers get answers without messaging first.",
              'Or hand Zeno the whole listing: category, description, a price and a cover, from one photo.',
            ]),
        PremiumFeature.priceChecks => const UpsellPitch(
            Icons.insights_rounded,
            'Price it right the first time',
            [
              'Zeno checks what similar items live on BROKA ask right now.',
              'You get a fair range and one clear number to ask - with the reason.',
              'Too high and a listing sits; too low and you lose money. Know before buyers do.',
            ]),
        PremiumFeature.aiCovers => const UpsellPitch(
            Icons.auto_fix_high_rounded,
            'Stand out on Home',
            [
              'A studio-quality cover made from your own photo, in the look you pick.',
              'Your item stays exactly as it is - only the setting changes.',
              'The cover is the first thing buyers see, before your price.',
            ]),
        PremiumFeature.sms => const UpsellPitch(
            Icons.sms_rounded,
            'Never miss a buyer',
            [
              'Zeno texts you the moment a buyer is waiting - even with the app closed and no data.',
              'Buyers ask several sellers at once. The one who answers first is the one they deal with.',
              'One text per buyer, only when you haven\'t replied, and never at night.',
            ]),
        _ => null,
      };
}

// The plans change rarely; one fetch per app run is enough for a sheet.
List<PremiumPlan>? _plansCache;

/// Shows why, and offers the plans. Resolves true if the user went to see
/// them - what they have left may have changed, so the caller re-checks.
///
/// [feature] (a PremiumFeature) adds what it does for the sale and what
/// the suggested plan costs; [premium] is where the plans are read, for
/// tests.
Future<bool> showPremiumUpsell(
  BuildContext context, {
  required String message,
  String? upgradeTo,
  String? feature,
  PremiumRepository? premium,
}) async {
  final pitch = UpsellPitch.of(feature);
  final open = await showModalBottomSheet<bool>(
    context: context,
    backgroundColor: BrokaColors.bgCard,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    // Scrollable: the server writes the message, and the ones that say
    // what a feature does for a sale run to several lines - on a short
    // phone an unscrollable column overflowed and cut off the buttons.
    isScrollControlled: true,
    builder: (ctx) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(22, 18, 22, 16),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 40, height: 4,
            decoration: BoxDecoration(color: BrokaColors.border, borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(height: 20),
          Container(
            width: 58, height: 58,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(colors: [BrokaColors.gold, BrokaColors.goldDim]),
              boxShadow: [BrokaColors.glowGold],
            ),
            child: Icon(pitch?.icon ?? Icons.workspace_premium_rounded, color: Colors.white, size: 30),
          ),
          const SizedBox(height: 14),
          Text(pitch?.headline ?? 'BROKA Premium',
              textAlign: TextAlign.center,
              style: const TextStyle(color: BrokaColors.textHigh, fontSize: 19, fontWeight: FontWeight.w900)),
          const SizedBox(height: 10),
          Text(message,
              key: const Key('upsell-message'),
              textAlign: TextAlign.center,
              style: const TextStyle(color: BrokaColors.textMid, fontSize: 13.5, height: 1.45)),
          if (pitch != null) ...[
            const SizedBox(height: 18),
            for (final point in pitch.points)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 1),
                    child: Icon(Icons.check_circle_rounded, color: BrokaColors.success, size: 18),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(point,
                        style: const TextStyle(color: BrokaColors.textHigh, fontSize: 13, height: 1.45)),
                  ),
                ]),
              ),
            _PlanLine(upgradeTo: upgradeTo, feature: feature!, premium: premium),
          ],
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              key: const Key('upsell-see-plans'),
              onPressed: () => Navigator.of(ctx).pop(true),
              style: ElevatedButton.styleFrom(
                backgroundColor: BrokaColors.gold,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              ),
              child: const Text('See plans', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900)),
            ),
          ),
          const SizedBox(height: 4),
          TextButton(
            key: const Key('upsell-not-now'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Not now', style: TextStyle(color: BrokaColors.textMid)),
          ),
        ]),
      ),
    ),
  );
  if (open != true || !context.mounted) return false;
  await Navigator.of(context).pushNamed('/premium', arguments: upgradeTo);
  return true;
}

/// "BROKA Plus · KES 199 a month - about KES 7 a day", and what else the
/// plan includes. Nothing until the plans have loaded, and nothing if they
/// can't: the sheet works without it.
class _PlanLine extends StatefulWidget {
  const _PlanLine({required this.upgradeTo, required this.feature, this.premium});
  final String? upgradeTo;
  final String feature;
  final PremiumRepository? premium;

  @override
  State<_PlanLine> createState() => _PlanLineState();
}

class _PlanLineState extends State<_PlanLine> {
  List<PremiumPlan>? _plans = _plansCache;

  @override
  void initState() {
    super.initState();
    if (_plans == null) _load();
  }

  Future<void> _load() async {
    final r = await (widget.premium ?? premiumRepository).plans();
    if (r is Success<List<PremiumPlan>> && r.data.isNotEmpty) {
      _plansCache = r.data;
      if (mounted) setState(() => _plans = r.data);
    }
  }

  PremiumPlan? get _plan {
    final plans = _plans ?? const <PremiumPlan>[];
    for (final p in plans) {
      if (p.id == widget.upgradeTo) return p;
    }
    // The cheapest plan with the feature - the one the server suggests too.
    for (final p in plans) {
      if (p.allowance(widget.feature) > 0) return p;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    if (plan == null) return const SizedBox.shrink();
    final perDay = (plan.monthlyPrice / 30).ceil();
    final also = [
      for (final f in PremiumFeature.all)
        if (plan.allowance(f) > 0) PremiumFeature.describe(f, plan.allowance(f)),
    ].take(4).toList();
    return Container(
      key: const Key('upsell-plan'),
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: BrokaColors.gold.withOpacity(0.08),
        border: Border.all(color: BrokaColors.gold.withOpacity(0.45)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('BROKA ${plan.name} · KES ${plan.monthlyPrice} a month',
            style: const TextStyle(color: BrokaColors.textHigh, fontSize: 14, fontWeight: FontWeight.w900)),
        const SizedBox(height: 3),
        Text('About KES $perDay a day',
            style: const TextStyle(color: BrokaColors.gold, fontSize: 12.5, fontWeight: FontWeight.w800)),
        if (also.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text('Every month: ${also.join(' · ')}',
              style: const TextStyle(color: BrokaColors.textMid, fontSize: 12, height: 1.45)),
        ],
      ]),
    );
  }
}
