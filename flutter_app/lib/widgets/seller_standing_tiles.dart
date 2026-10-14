// A seller's standing as buyers see it: the seller dashboard's rating, deal
// completion rate and response time, and how long their deals take - in the
// dashboard's colours (models/seller_standing.dart), green where it shades
// green.
//
// Shared by the listing screen's seller block and the seller's profile, so a
// buyer reads the same four figures, the same way, in both places. It was the
// listing screen's own; the profile showed invented scores instead
// ("Reliability" and "Response Rate" from fields the API never returned).
import 'package:flutter/material.dart';

import '../main.dart';
import '../models/seller_standing.dart';

class SellerStandingTiles extends StatelessWidget {
  const SellerStandingTiles({super.key, required this.standing});

  final SellerStanding standing;

  static Color bandColor(StandingBand b) => switch (b) {
        StandingBand.good => BrokaColors.neonGreen,
        StandingBand.fair => BrokaColors.warning,
        StandingBand.poor => BrokaColors.danger,
        StandingBand.unknown => BrokaColors.textMid,
      };

  @override
  Widget build(BuildContext context) {
    final s = standing;
    final rating = s.overallRating;
    final dcr = s.dcr;
    final reply = s.responseMinutes;
    final dealTime = s.dealTimeMinutes;
    // Two by two: four across left each tile about 76dp on a small phone,
    // too narrow for "of deals completed" on fewer than three lines.
    Widget pair(Widget a, Widget b) => IntrinsicHeight(
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(child: a),
            const SizedBox(width: 8),
            Expanded(child: b),
          ]),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      pair(
        _tile(
          key: const Key('standing-rating'),
          label: 'RATING',
          value: rating == null ? '—' : rating.toStringAsFixed(1),
          suffix: rating == null ? null : '/10',
          sub: rating == null ? 'Not rated yet' : 'BROKA rating',
          band: s.ratingBand,
        ),
        _tile(
          key: const Key('standing-dcr'),
          label: 'COMPLETION',
          value: dcr == null ? '—' : '${dcr.round()}%',
          sub: dcr == null
              ? 'No deals yet'
              : (s.dcrProvisional ? 'Early - few deals' : 'of deals completed'),
          band: s.dcrBand,
        ),
      ),
      const SizedBox(height: 8),
      pair(
        _tile(
          key: const Key('standing-response'),
          label: 'AVG RESPONSE',
          value: reply == null ? '—' : SellerStanding.formatMinutes(reply),
          sub: reply == null ? 'Not measured yet' : 'average reply time',
          band: s.responseBand,
        ),
        _tile(
          key: const Key('standing-deal-time'),
          label: 'AVG DEAL TIME',
          value: dealTime == null ? '—' : SellerStanding.formatMinutes(dealTime),
          // How much evidence the mean stands on, like the provisional
          // completion rate: one deal is a fact, not a habit.
          sub: dealTime == null
              ? 'No completed deals'
              : (s.timedDeals == 1
                  ? 'agreed to paid · 1 deal'
                  : 'agreed to paid · ${s.timedDeals} deals'),
          band: s.dealTimeBand,
        ),
      ),
      const SizedBox(height: 6),
      const Text("Measured by BROKA from the seller's deals and chats",
          style: TextStyle(color: BrokaColors.textMid, fontSize: 10)),
    ]);
  }

  Widget _tile({
    required Key key,
    required String label,
    required String value,
    String? suffix,
    required String sub,
    required StandingBand band,
  }) {
    final color = bandColor(band);
    return Container(
      key: key,
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: [
          Color.alphaBlend(color.withOpacity(0.10), BrokaColors.bgCard),
          BrokaColors.cardGradColors.last,
        ], begin: Alignment.topLeft, end: Alignment.bottomRight),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(label, maxLines: 1, style: const TextStyle(
              color: BrokaColors.textMid, fontSize: 9,
              fontWeight: FontWeight.w700, letterSpacing: 1.1)),
        ),
        const SizedBox(height: 6),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text.rich(TextSpan(children: [
            TextSpan(text: value, style: TextStyle(
                color: color, fontSize: 21, fontWeight: FontWeight.w900, height: 1.0)),
            if (suffix != null)
              TextSpan(text: suffix, style: TextStyle(
                  color: color.withOpacity(0.75), fontSize: 11, fontWeight: FontWeight.w700)),
          ]), maxLines: 1),
        ),
        const SizedBox(height: 5),
        Text(sub, maxLines: 2, overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: BrokaColors.textMid, fontSize: 10, height: 1.3)),
      ]),
    );
  }
}
