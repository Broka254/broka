// Zeno's premium help in the sell wizard (2026-10-05): a description
// written from the photo, the price checked against BROKA - one card each,
// in one look.
//
// Every card leads with what the help does for the sale, not with what it
// is: a seller deciding whether to upgrade is deciding whether the item
// sells sooner. The plan it needs is a badge on the card, and a locked card
// still opens - into the plans, with the same reason (premium_upsell.dart).
import 'package:flutter/material.dart';

import '../main.dart';

class SellZenoBoostCard extends StatelessWidget {
  const SellZenoBoostCard({
    super.key,
    required this.icon,
    required this.title,
    required this.benefit,
    required this.badge,
    required this.onTap,
    this.locked = false,
    this.busy = false,
    this.footnote,
  });

  final IconData icon;
  final String title;

  /// Why it helps the listing sell - one line.
  final String benefit;

  /// The plan it comes with: "PREMIUM", "PRO".
  final String badge;

  /// The plan doesn't have it (or this month's is spent): the tap shows
  /// the plans, and the card says so with a lock.
  final bool locked;

  /// Zeno is working on it.
  final bool busy;

  /// "28 of 30 left this month" - or nothing.
  final String? footnote;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '$title. $benefit${locked ? ' Needs BROKA $badge.' : ''}',
      excludeSemantics: true,
      child: InkWell(
        onTap: busy ? null : onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                BrokaColors.neonPurple.withOpacity(0.22),
                BrokaColors.neonBlue.withOpacity(0.10),
              ],
            ),
            border: Border.all(color: BrokaColors.neonPurple.withOpacity(0.55)),
            boxShadow: [BoxShadow(color: BrokaColors.neonPurple.withOpacity(0.16), blurRadius: 14)],
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: BrokaColors.neonPurple.withOpacity(0.25),
              ),
              alignment: Alignment.center,
              child: busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : Icon(icon, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(
                    child: Text(title,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 14, fontWeight: FontWeight.w800)),
                  ),
                  const SizedBox(width: 8),
                  _Badge(badge, locked: locked),
                ]),
                const SizedBox(height: 4),
                Text(benefit,
                    style: const TextStyle(color: BrokaColors.textHigh, fontSize: 12, height: 1.4)),
                if (footnote != null) ...[
                  const SizedBox(height: 6),
                  Text(footnote!,
                      key: const Key('zeno-boost-footnote'),
                      style: const TextStyle(
                          color: BrokaColors.textMid, fontSize: 11, fontWeight: FontWeight.w600)),
                ],
              ]),
            ),
            const SizedBox(width: 6),
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Icon(Icons.chevron_right_rounded, color: BrokaColors.textMid),
            ),
          ]),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.label, {required this.locked});
  final String label;
  final bool locked;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [Color(0xFFF5B83D), Color(0xFFE08A1E)]),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (locked) ...[
            const Icon(Icons.lock_rounded, size: 10, color: Colors.white),
            const SizedBox(width: 3),
          ],
          Text(label,
              style: const TextStyle(
                  color: Colors.white, fontSize: 9.5, fontWeight: FontWeight.w900, letterSpacing: 0.6)),
        ]),
      );
}
