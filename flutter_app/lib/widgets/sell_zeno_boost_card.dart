// Zeno's premium help in the sell wizard (2026-10-05): a description
// written from the photo, the price checked against BROKA - one card each,
// in one look.
//
// Every card leads with what the help does for the sale, not with what it
// is: a seller deciding whether to upgrade is deciding whether the item
// sells sooner. The plan it needs is a badge on the card, and a locked card
// still opens - into the plans, with the same reason (premium_upsell.dart).
//
// 2026-10-08: sellers read the one-line pitch and moved on. A card can now
// show what the seller would get (a [preview]: Zeno's lines beside the
// usual "phone for sale, call me"), what it does in a few ticks
// ([points]), a [ribbon] for a free try, and a button that says what
// happens on tap ([cta]) rather than a chevron.
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
    this.points = const [],
    this.preview,
    this.cta,
    this.ribbon,
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

  /// What it does, a few words each, ticked.
  final List<String> points;

  /// What the seller would get, shown small.
  final Widget? preview;

  /// The button's words: "Write it for me". None: a chevron, as before.
  final String? cta;

  /// "FIRST ONE FREE" - over the card's corner.
  final String? ribbon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final card = Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 16, 14, 16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            BrokaColors.neonPurple.withOpacity(0.24),
            BrokaColors.neonBlue.withOpacity(0.10),
          ],
        ),
        border: Border.all(color: BrokaColors.neonPurple.withOpacity(0.6)),
        boxShadow: [BoxShadow(color: BrokaColors.neonPurple.withOpacity(0.18), blurRadius: 16)],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: BrokaColors.neonPurple.withOpacity(0.28),
            ),
            alignment: Alignment.center,
            child: busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : Icon(icon, color: Colors.white, size: 21),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 4,
                children: [
                  Text(title,
                      style: const TextStyle(
                          color: Colors.white, fontSize: 15, fontWeight: FontWeight.w800, height: 1.25)),
                  _Badge(badge, locked: locked),
                ],
              ),
              const SizedBox(height: 6),
              Text(benefit,
                  style: const TextStyle(color: BrokaColors.textHigh, fontSize: 12.5, height: 1.45)),
            ]),
          ),
          if (cta == null) ...[
            const SizedBox(width: 6),
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Icon(Icons.chevron_right_rounded, color: BrokaColors.textMid),
            ),
          ],
        ]),
        if (points.isNotEmpty) ...[
          const SizedBox(height: 12),
          for (final point in points)
            Padding(
              padding: const EdgeInsets.only(left: 54, bottom: 6),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Padding(
                  padding: EdgeInsets.only(top: 1),
                  child: Icon(Icons.check_rounded, size: 15, color: BrokaColors.neonGreen),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(point,
                      style: const TextStyle(color: BrokaColors.textHigh, fontSize: 12, height: 1.4)),
                ),
              ]),
            ),
        ],
        if (preview != null) ...[
          const SizedBox(height: 12),
          preview!,
        ],
        if (cta != null) ...[
          const SizedBox(height: 14),
          Container(
            key: const Key('zeno-boost-cta'),
            height: 44,
            width: double.infinity,
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              gradient: locked
                  ? const LinearGradient(colors: [Color(0xFFF5B83D), Color(0xFFE08A1E)])
                  : const LinearGradient(colors: [BrokaColors.neonPurple, BrokaColors.neonBlue]),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(locked ? Icons.lock_open_rounded : icon, size: 17, color: Colors.white),
              const SizedBox(width: 8),
              Flexible(
                child: Text(busy ? 'Zeno is on it…' : cta!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 13.5, fontWeight: FontWeight.w800)),
              ),
            ]),
          ),
        ],
        if (footnote != null) ...[
          const SizedBox(height: 8),
          Center(
            child: Text(footnote!,
                key: const Key('zeno-boost-footnote'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: BrokaColors.textMid, fontSize: 11.5, fontWeight: FontWeight.w600)),
          ),
        ],
      ]),
    );
    return Semantics(
      button: true,
      label: '$title. $benefit${locked ? ' Needs BROKA $badge.' : ''}',
      excludeSemantics: true,
      child: InkWell(
        onTap: busy ? null : onTap,
        borderRadius: BorderRadius.circular(18),
        child: ribbon == null
            ? card
            : Stack(clipBehavior: Clip.none, children: [
                card,
                Positioned(
                  top: -9,
                  right: 14,
                  child: Container(
                    key: const Key('zeno-boost-ribbon'),
                    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      gradient: const LinearGradient(colors: [BrokaColors.neonGreen, BrokaColors.neonCyan]),
                      boxShadow: [BoxShadow(color: BrokaColors.neonGreen.withOpacity(0.4), blurRadius: 10)],
                    ),
                    child: Text(ribbon!,
                        style: const TextStyle(
                            color: Colors.black, fontSize: 10, fontWeight: FontWeight.w900, letterSpacing: 0.6)),
                  ),
                ),
              ]),
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

/// What a listing says without Zeno and with it, side by side - examples
/// for the kind of item being sold, labelled as examples.
class ZenoBeforeAfter extends StatelessWidget {
  const ZenoBeforeAfter({super.key, required this.category, this.subcategory});
  final String category;
  final String? subcategory;

  /// (the usual seller's line, Zeno's lines) for this kind of item.
  static (String, List<String>) exampleFor(String category, String? subcategory) {
    switch (category) {
      case 'Automobiles':
        return ('Clean car, well maintained. Call me.',
            ['Make: Toyota', 'Model: Axio', 'Year: 2015', 'Mileage: 85,000 km', 'Logbook: Yes, in my name']);
      case 'Land':
        return ('Plot for sale, good area.',
            ['Size: 50x100', 'Title deed: Ready', 'Road: 300 m from tarmac', 'Water and power: On site']);
      case 'Fashion':
        return ('Nice shoes, worn twice.',
            ['Brand: Nike Air Force 1', 'Size: 42', 'Colour: White', 'Condition: Worn twice, no creases']);
      case 'Home & Furniture':
        return ('Sofa for sale, still good.',
            ['Type: 3-seater sofa', 'Material: Fabric, grey', 'Size: 2.1 m wide', 'Condition: No tears or stains']);
      case 'Agriculture':
      case 'Food & Beverages':
        return ('Maize available.',
            ['Type: Dry white maize', 'Harvested: August 2026', 'Moisture: Dry, ready to store', 'Packed: 90 kg bags']);
    }
    return ('Phone for sale, very clean. Call me.',
        ['Brand: Samsung', 'Model: Galaxy A54', 'Storage: 128 GB', 'Battery health: 91%', 'Included: Charger and box']);
  }

  @override
  Widget build(BuildContext context) {
    final (before, after) = exampleFor(category, subcategory);
    return Container(
      key: const Key('zeno-before-after'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: BrokaColors.bg.withOpacity(0.55),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: BrokaColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('FOR EXAMPLE', style: TextStyle(
            color: BrokaColors.textMid, fontSize: 9.5, fontWeight: FontWeight.w800, letterSpacing: 1.2)),
        const SizedBox(height: 8),
        Row(children: [
          const Icon(Icons.close_rounded, size: 14, color: BrokaColors.danger),
          const SizedBox(width: 6),
          Expanded(
            child: Text('"$before"',
                style: const TextStyle(
                    color: BrokaColors.textMid, fontSize: 12, fontStyle: FontStyle.italic,
                    decoration: TextDecoration.lineThrough, decorationColor: BrokaColors.textMid)),
          ),
        ]),
        const SizedBox(height: 10),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child: Icon(Icons.auto_awesome_rounded, size: 14, color: BrokaColors.neonGreen),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final line in after)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: _line(line),
                ),
            ]),
          ),
        ]),
      ]),
    );
  }

  static Widget _line(String line) {
    final at = line.indexOf(': ');
    return Text.rich(TextSpan(children: [
      TextSpan(text: line.substring(0, at + 1),
          style: const TextStyle(color: BrokaColors.textMid, fontWeight: FontWeight.w700)),
      TextSpan(text: line.substring(at + 1)),
    ]), style: const TextStyle(color: BrokaColors.textHigh, fontSize: 12, height: 1.4));
  }
}

/// A price range with its numbers hidden - what Pro shows, before Pro.
class ZenoLockedRange extends StatelessWidget {
  const ZenoLockedRange({super.key});

  @override
  Widget build(BuildContext context) {
    Widget hidden(double width) => Container(
          width: width,
          height: 12,
          decoration: BoxDecoration(
            color: BrokaColors.textMid.withOpacity(0.35),
            borderRadius: BorderRadius.circular(4),
          ),
        );
    return Container(
      key: const Key('zeno-locked-range'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: BrokaColors.bg.withOpacity(0.55),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: BrokaColors.border),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.verified_rounded, size: 13, color: BrokaColors.neonGreen),
          const SizedBox(width: 6),
          const Expanded(
            child: Text('SIMILAR LIVE LISTINGS ON BROKA', style: TextStyle(
                color: BrokaColors.neonGreen, fontSize: 9.5, fontWeight: FontWeight.w800, letterSpacing: 1)),
          ),
          Icon(Icons.lock_rounded, size: 13, color: BrokaColors.gold.withOpacity(0.9)),
        ]),
        const SizedBox(height: 10),
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, runSpacing: 6, children: [
          const Text('KES ', style: TextStyle(color: BrokaColors.textMid, fontSize: 12, fontWeight: FontWeight.w700)),
          hidden(54),
          const Text('  -  KES ', style: TextStyle(color: BrokaColors.textMid, fontSize: 12, fontWeight: FontWeight.w700)),
          hidden(54),
        ]),
        const SizedBox(height: 10),
        Container(
          height: 6,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            gradient: LinearGradient(colors: [
              BrokaColors.neonBlue.withOpacity(0.5),
              BrokaColors.neonGreen.withOpacity(0.5),
              BrokaColors.gold.withOpacity(0.5),
            ]),
          ),
        ),
        const SizedBox(height: 8),
        const Text("Zeno's asking price for yours, and why",
            style: TextStyle(color: BrokaColors.textMid, fontSize: 11.5)),
      ]),
    );
  }
}
