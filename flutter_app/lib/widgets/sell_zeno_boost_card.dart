// Zeno's premium help in the sell wizard (2026-10-05): a description
// written from the photo, the price checked against BROKA - one card each,
// in one look.
//
// Every card leads with what the help does for the sale, not with what it
// is: a seller deciding whether to upgrade is deciding whether the item
// sells sooner. The plan it needs is a badge on the card, and a locked card
// still opens - into the plans, with the same reason (premium_upsell.dart).
//
// 2026-10-08: sellers read the one-line pitch and moved on. A card could
// then show what the seller would get (an example), what it does in a few
// ticks, a ribbon for a free try, and a button saying what happens on tap.
//
// 2026-11-08: a strip, not a page. With the ticks, the example and a
// full-width button the card grew to 260-460 dp, and on a 360 dp phone it
// pushed each step's own field (the description box, the asking price)
// below the fold: sellers scrolled past an advert to reach the form. The
// strip is about 100 dp - the title, a line on what it does for the sale,
// and the button at its side. Being seen costs it no height: the plan's
// tag sits on the top border, the button is amber when it unlocks, and a
// sweep of light crosses the button once when the card appears or its
// offer changes (never under reduced motion, never in a loop - an advert
// that never stops moving is one sellers learn to ignore). The ticks and
// the example moved to where a seller decides: the plans' sheet a locked
// card opens (showPremiumUpsell's preview), with ZenoBeforeAfter and
// ZenoLockedRange below.
import 'package:flutter/material.dart';

import '../main.dart';

/// The premium amber: a plan's tag, and a button that unlocks.
const _amber = [Color(0xFFF5B83D), Color(0xFFE08A1E)];

class SellZenoBoostCard extends StatefulWidget {
  const SellZenoBoostCard({
    super.key,
    required this.icon,
    required this.title,
    required this.benefit,
    required this.onTap,
    this.badge,
    this.locked = false,
    this.busy = false,
    this.footnote,
    this.cta,
    this.ribbon,
  });

  final IconData icon;
  final String title;

  /// Why it helps the listing sell, in a few words: two lines at most.
  final String benefit;

  /// The plan it comes with: "PREMIUM", "PRO". None while plans are off
  /// (PremiumStatus.enabled false): nothing is sold then, and a plan's
  /// name on a feature that is free reads as a price.
  final String? badge;

  /// The plan doesn't have it (or this month's is spent): the tap shows
  /// the plans, and the card says so with a lock.
  final bool locked;

  /// Zeno is working on it.
  final bool busy;

  /// "28 of 30 left this month" - or nothing.
  final String? footnote;

  /// The button's words, short enough for the strip's side: "Unlock",
  /// "Write it". None: a chevron.
  final String? cta;

  /// "FIRST ONE FREE" - on the top border, in the plan tag's place.
  final String? ribbon;
  final VoidCallback? onTap;

  @override
  State<SellZenoBoostCard> createState() => _SellZenoBoostCardState();
}

class _SellZenoBoostCardState extends State<SellZenoBoostCard> with SingleTickerProviderStateMixin {
  // Made in initState, not lazily: a lazy one first touched in dispose
  // asks a deactivated tree for its TickerMode.
  late final AnimationController _sheen;
  bool _still = false;
  bool _swept = false;

  @override
  void initState() {
    super.initState();
    _sheen = AnimationController(vsync: this, duration: const Duration(milliseconds: 1600));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (_still) {
      _sheen.value = 0;
    } else if (!_swept) {
      _swept = true;
      _sheen.forward(from: 0);
    }
  }

  @override
  void didUpdateWidget(covariant SellZenoBoostCard old) {
    super.didUpdateWidget(old);
    // A new offer - the plan has loaded, a photo is in: sweep again, once.
    final changed = old.locked != widget.locked || old.cta != widget.cta || old.ribbon != widget.ribbon;
    if (changed && !_still) _sheen.forward(from: 0);
  }

  @override
  void dispose() {
    _sheen.dispose();
    super.dispose();
  }

  static String _words(String label) => label.isEmpty
      ? label
      : label[0].toUpperCase() + label.substring(1).toLowerCase();

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final Widget? tag = w.ribbon != null
        ? _Tag(key: const Key('zeno-boost-ribbon'), label: w.ribbon!, free: true)
        : w.badge != null
            ? _Tag(key: const Key('zeno-boost-badge'), label: w.badge!, locked: w.locked)
            : null;
    final card = Container(
      width: double.infinity,
      // A little more on top when a tag sits on the border above the title.
      padding: EdgeInsets.fromLTRB(12, tag == null ? 12 : 15, 12, 12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            BrokaColors.neonPurple.withOpacity(0.24),
            BrokaColors.neonBlue.withOpacity(0.10),
          ],
        ),
        border: Border.all(color: BrokaColors.neonPurple.withOpacity(0.6)),
        boxShadow: [BoxShadow(color: BrokaColors.neonPurple.withOpacity(0.18), blurRadius: 14)],
      ),
      child: Row(children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: BrokaColors.neonPurple.withOpacity(0.28),
          ),
          alignment: Alignment.center,
          child: w.busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : Icon(w.icon, color: Colors.white, size: 18),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(w.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: Colors.white, fontSize: 14, fontWeight: FontWeight.w800, height: 1.25)),
            const SizedBox(height: 3),
            Text(w.benefit,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: BrokaColors.textHigh, fontSize: 12, height: 1.35)),
            if (w.footnote != null) ...[
              const SizedBox(height: 4),
              Text(w.footnote!,
                  key: const Key('zeno-boost-footnote'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: BrokaColors.textMid, fontSize: 11, fontWeight: FontWeight.w600)),
            ],
          ]),
        ),
        const SizedBox(width: 10),
        if (w.cta == null)
          const Icon(Icons.chevron_right_rounded, color: BrokaColors.textMid)
        else
          _Button(
            label: w.busy ? 'On it…' : w.cta!,
            icon: w.locked ? Icons.lock_open_rounded : w.icon,
            locked: w.locked,
            sheen: _sheen,
          ),
      ]),
    );
    final needs = w.locked && w.badge != null ? ' Needs BROKA ${_words(w.badge!)}.' : '';
    final free = w.ribbon != null ? ' ${_words(w.ribbon!)}.' : '';
    return Semantics(
      button: true,
      label: '${w.title}. ${w.benefit}$needs$free',
      excludeSemantics: true,
      // The whole strip is the button, its pill included: one target, so a
      // tap anywhere on it does what the pill says.
      child: InkWell(
        onTap: w.busy ? null : w.onTap,
        borderRadius: BorderRadius.circular(16),
        child: tag == null
            ? card
            : Stack(clipBehavior: Clip.none, children: [
                card,
                Positioned(top: -9, right: 14, child: tag),
              ]),
      ),
    );
  }
}

/// The plan's name (or the free try) on the strip's top border.
class _Tag extends StatelessWidget {
  const _Tag({super.key, required this.label, this.locked = false, this.free = false});
  final String label;
  final bool locked;
  final bool free;

  @override
  Widget build(BuildContext context) {
    final colors = free ? const [BrokaColors.neonGreen, BrokaColors.neonCyan] : _amber;
    final ink = free ? Colors.black : Colors.white;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        gradient: LinearGradient(colors: colors),
        boxShadow: [BoxShadow(color: colors.first.withOpacity(0.4), blurRadius: 10)],
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (locked) ...[
          Icon(Icons.lock_rounded, size: 10, color: ink),
          const SizedBox(width: 3),
        ],
        Text(label,
            style: TextStyle(color: ink, fontSize: 9.5, fontWeight: FontWeight.w900, letterSpacing: 0.6)),
      ]),
    );
  }
}

/// The strip's pill: amber to unlock, Zeno's violet-to-blue to use.
class _Button extends StatelessWidget {
  const _Button({required this.label, required this.icon, required this.locked, required this.sheen});
  final String label;
  final IconData icon;
  final bool locked;
  final Animation<double> sheen;

  @override
  Widget build(BuildContext context) {
    final colors = locked ? _amber : const [BrokaColors.neonPurple, BrokaColors.neonBlue];
    return ConstrainedBox(
      key: const Key('zeno-boost-cta'),
      constraints: const BoxConstraints(minHeight: 36, maxWidth: 128),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: LinearGradient(colors: colors),
          boxShadow: [BoxShadow(color: colors.first.withOpacity(0.35), blurRadius: 10)],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: Stack(alignment: Alignment.center, children: [
            Positioned.fill(child: _Sheen(animation: sheen)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(icon, size: 15, color: Colors.white),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w800)),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

/// One band of light across the pill. It waits out the step's own
/// entrance (the first third of the controller), then crosses once.
class _Sheen extends StatelessWidget {
  const _Sheen({required this.animation});
  final Animation<double> animation;

  static const _crossing = Interval(0.35, 1, curve: Curves.easeInOutCubic);

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: AnimatedBuilder(
          animation: animation,
          builder: (_, __) {
            final t = _crossing.transform(animation.value);
            if (t <= 0 || t >= 1) return const SizedBox.shrink();
            return FractionalTranslation(
              translation: Offset(t * 2.4 - 1.2, 0),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [
                    Colors.white.withOpacity(0),
                    Colors.white.withOpacity(0.45),
                    Colors.white.withOpacity(0),
                  ]),
                ),
              ),
            );
          },
        ),
      );
}

/// What a listing says without Zeno and with it, side by side - examples
/// for the kind of item being sold, labelled as examples. Shown in the
/// plans' sheet a locked description or listing card opens.
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
/// Shown in the plans' sheet a locked price card opens.
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
