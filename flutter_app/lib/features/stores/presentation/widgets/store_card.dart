// A store in the directory, as a shop window: the picture its owner chose
// to show (the cover, else a shop photo, else the logo), whether the owner
// is online, what and where it is, the seller's record, and Visit store.
//
// Shared by the directory and a category's screen of its own
// (store_category_screen.dart), so a shop looks the same however it was
// reached.
//
// Was a 52dp circle with the store's initial and three lines of small
// text - the same card as a trader's, and nothing to show it was a shop.
//
// Visual upgrade (2026-09-30), onto Home's product-card system: the thin
// violet-to-blue edge and card gradient instead of a flat border, the
// picture taller, the store's logo as its sign where the picture meets the
// details, the seller's record as chips, and a card that sinks a little
// under a finger. Visit store was a 42dp bar across the whole card - the
// loudest thing on it, louder than the shop's own picture, when the whole
// card already opens the store. It is now a pill sized to its words, at
// the foot beside the product count, where the thumb lands.
//
// The sign is always there when there's a shopfront (2026-10-16): the
// store's own logo, or BROKA's mark when the owner uploaded none - the
// same fallback the web storefront and My Store already show. Only a card
// whose picture IS the logo leaves the sign off, or the logo shows twice.
import 'package:flutter/material.dart';

import '../../../../main.dart';
import '../../../../theme/motion.dart';
import '../../../categories/domain/category_visual.dart';
import '../../domain/models/store.dart';
import '../store_media_image.dart';
import 'broka_default_logo.dart';

class StoreCard extends StatefulWidget {
  final Store store;
  final VoidCallback onTap;

  /// Opens the store's details screen (reviews, seller record, location).
  /// A chip on the picture, not another bar: the card itself still opens
  /// the store, and this is the secondary thing a buyer does from here.
  /// Null hides it.
  final VoidCallback? onDetails;

  /// Opens the store on the map. Null hides the Map action.
  final VoidCallback? onMap;

  /// Show the distance even beyond the 25 km "near" radius - for
  /// "nearest to you" lists, where the honest distance is the point.
  /// Directory cards leave this off: far shops show their place instead.
  final bool showAnyDistance;
  const StoreCard({super.key, required this.store, required this.onTap, this.onDetails, this.onMap,
      this.showAnyDistance = false});

  @override
  State<StoreCard> createState() => _StoreCardState();
}

class _StoreCardState extends State<StoreCard> {
  bool _down = false;

  void _press(bool down) {
    if (_down != down) setState(() => _down = down);
  }

  static const _pictureHeight = 168.0;
  static const _logoSize = 62.0;

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    final distLabel = widget.showAnyDistance ? store.anyDistanceLabel : store.nearLabel;
    final owner = store.owner;
    final colors = CategoryVisuals.gradientFor(store.category);
    final picture = store.coverSource ?? store.logo?.medium ?? store.logoUrl;
    final logo = store.logoSource;
    // The logo as a sign only when the picture is something else: a card
    // whose only image is the logo would show it twice. No cover at all
    // still shows BROKA's mark full width; with one, the sign is BROKA's
    // mark until the owner uploads their own.
    final showLogo = store.coverSource != null;
    final rating = owner?.shownRating;
    final deals = owner?.completedDeals ?? 0;
    final products = '${store.listingCount} product${store.listingCount == 1 ? '' : 's'}';

    final fallback = DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            BrokaColors.gold.withOpacity(0.45),
            BrokaColors.bgCard,
            colors.last.withOpacity(0.40),
          ],
        ),
      ),
      // A shop with no picture shows BROKA's mark, not its category emoji:
      // the emoji read as clip-art standing in for a photo, and the mark is
      // what the store's own logo falls back to everywhere else.
      child: Center(
        child: SizedBox(
          width: 64,
          height: 64,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: const BrokaDefaultLogo(),
          ),
        ),
      ),
    );

    return Semantics(
      button: true,
      label: 'Visit ${store.name}',
      child: GestureDetector(
        key: Key('store-card-${store.id}'),
        onTap: widget.onTap,
        onTapDown: (_) => _press(true),
        onTapUp: (_) => _press(false),
        onTapCancel: () => _press(false),
        child: AnimatedScale(
          scale: _down && !BrokaMotion.reduced(context) ? 0.98 : 1.0,
          duration: BrokaMotion.instant,
          curve: Curves.easeOut,
          child: Container(
            margin: const EdgeInsets.only(bottom: 16),
            padding: const EdgeInsets.all(1.2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [BrokaColors.gold.withOpacity(0.55), BrokaColors.neonBlue.withOpacity(0.40)],
              ),
              boxShadow: [
                BoxShadow(color: BrokaColors.gold.withOpacity(0.12), blurRadius: 18),
              ],
            ),
            child: Container(
              decoration: BoxDecoration(
                gradient: BrokaColors.cardGradient,
                borderRadius: BorderRadius.circular(19),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                SizedBox(
                  height: _pictureHeight,
                  child: Stack(fit: StackFit.expand, children: [
                    picture == null
                        ? fallback
                        : StoreMediaImage(dataUri: picture, placeholderBuilder: (_) => fallback),
                    // Dark at the top and foot, so the chips on the picture
                    // stay legible whatever the photo is.
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Color(0x66000000), Colors.transparent, Color(0xCC0A1220)],
                          stops: [0, 0.42, 1],
                        ),
                      ),
                    ),
                    if (owner != null && (owner.online || owner.lastActive != null))
                      Positioned(
                        top: 10,
                        left: 10,
                        child: _Pill(
                          key: const Key('store-card-presence'),
                          dot: owner.online ? BrokaColors.success : BrokaColors.textMid,
                          label: owner.online ? 'Online now' : owner.lastActive!,
                          color: owner.online ? BrokaColors.success : Colors.white70,
                        ),
                      ),
                    if (store.categories.isNotEmpty)
                      Positioned(
                        right: 10,
                        bottom: 10,
                        child: _Pill(
                          // The primary, plus how many more: the full set
                          // belongs on the store's own page, not a caption.
                          label: '${CategoryVisuals.emojiFor(store.categories.first)}  '
                              '${store.categories.first}'
                              '${store.categories.length > 1 ? ' +${store.categories.length - 1}' : ''}',
                          color: Colors.white,
                        ),
                      ),
                    if (distLabel != null)
                      Positioned(
                        left: 10,
                        bottom: 10,
                        child: _DistancePill(
                          key: const Key('store-card-distance'),
                          label: distLabel,
                        ),
                      ),
                  ]),
                ),
                // The logo sits over the picture's lower edge - the sign on
                // the shop front - so the Stack lets it paint above itself.
                Stack(clipBehavior: Clip.none, children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Padding(
                        padding: EdgeInsets.only(left: showLogo ? _logoSize + 12 : 0),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [
                            Flexible(
                              child: Text(store.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(color: BrokaColors.textHigh,
                                      fontWeight: FontWeight.w800, fontSize: 17.5,
                                      letterSpacing: -0.2)),
                            ),
                            if (owner?.verified ?? false) ...[
                              const SizedBox(width: 5),
                              const Icon(Icons.verified_rounded, size: 17,
                                  color: BrokaColors.success, semanticLabel: 'Verified seller'),
                            ],
                          ]),
                          if (store.locationLine != null || distLabel != null) ...[
                            const SizedBox(height: 4),
                            Row(children: [
                              const Icon(Icons.location_on_outlined, size: 15,
                                  color: BrokaColors.gold),
                              const SizedBox(width: 4),
                              Flexible(child: Text.rich(
                                  TextSpan(children: [
                                    if (store.locationLine != null)
                                      TextSpan(text: store.locationLine!,
                                          style: const TextStyle(
                                              color: BrokaColors.textMid, fontSize: 13)),
                                    if (store.locationLine != null && distLabel != null)
                                      const TextSpan(text: ' · ',
                                          style: TextStyle(
                                              color: BrokaColors.textMid, fontSize: 13)),
                                    if (distLabel != null)
                                      TextSpan(text: distLabel,
                                          style: const TextStyle(
                                              color: BrokaColors.gold, fontSize: 13,
                                              fontWeight: FontWeight.w700)),
                                  ]),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis)),
                            ]),
                          ],
                        ]),
                      ),
                      // At least the logo's overhang, so the chips never run
                      // under it when there's no location line.
                      SizedBox(height: showLogo && store.locationLine == null ? 16 : 10),
                      Wrap(spacing: 6, runSpacing: 6, children: [
                        _Fact(icon: Icons.star_rounded, color: BrokaColors.zoneAmber,
                            text: rating != null ? rating.toStringAsFixed(1) : 'New seller'),
                        _Fact(icon: Icons.handshake_outlined, color: BrokaColors.neonCyan,
                            text: '$deals deal${deals == 1 ? '' : 's'} done'),
                        // Details lives here, in the card's own chip row -
                        // the quiet sibling of Visit store below. (The
                        // "Delivery or pickup" fact that sat here moved to
                        // Store details, with the buying-safely text - see
                        // store_details_view.dart.)
                        if (widget.onDetails != null)
                          _DetailsPill(
                            key: Key('store-details-${store.id}'),
                            onTap: widget.onDetails!,
                          ),
                      ]),
                      const SizedBox(height: 12),
                      Container(height: 1, color: BrokaColors.border.withOpacity(0.8)),
                      const SizedBox(height: 10),
                      // One line at every width: under 360dp the Map pill
                      // is icon-only and Visit shortens, so the product
                      // count keeps room instead of overflowing the row
                      // (a 320dp phone's card is ~260dp inside).
                      LayoutBuilder(builder: (context, row) {
                        final compact = row.maxWidth < 360;
                        return Row(children: [
                          const Icon(Icons.inventory_2_outlined, size: 15,
                              color: BrokaColors.textMid),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(products, maxLines: 1, overflow: TextOverflow.ellipsis,
                                style: const TextStyle(color: BrokaColors.textHigh, fontSize: 13,
                                    fontWeight: FontWeight.w700)),
                          ),
                          const SizedBox(width: 10),
                          if (widget.onMap != null) ...[
                            _MapButton(
                              key: Key('store-map-${store.id}'),
                              onTap: widget.onMap!,
                              iconOnly: compact,
                            ),
                            const SizedBox(width: 8),
                          ],
                          _VisitButton(key: Key('visit-store-${store.id}'), short: compact),
                        ]);
                      }),
                    ]),
                  ),
                  if (showLogo)
                    Positioned(
                      left: 14,
                      top: -30,
                      child: _Logo(source: logo, size: _logoSize),
                    ),
                ]),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// Distance on the picture: the buyer's first question about a shop,
/// given the strongest seat on the card after the shop's own name.
class _DistancePill extends StatelessWidget {
  const _DistancePill({super.key, required this.label});
  final String label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [BrokaColors.gold, BrokaColors.neonBlue]),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [BoxShadow(color: BrokaColors.gold.withOpacity(0.35), blurRadius: 10)],
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.near_me_rounded, size: 13, color: Colors.white),
          const SizedBox(width: 5),
          Text(label,
              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w800)),
        ]),
      );
}

/// Map: the quiet sibling of Visit store - an outline pill that opens
/// the shop's approximate point on the in-app map.
class _MapButton extends StatelessWidget {
  const _MapButton({super.key, required this.onTap, this.iconOnly = false});
  final VoidCallback onTap;

  /// Icon without the word, on narrow cards (see the footer's
  /// LayoutBuilder). The semantics label still says what it does.
  final bool iconOnly;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: 'View store on map',
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            height: 38,
            width: iconOnly ? 38 : null,
            padding: iconOnly ? EdgeInsets.zero : const EdgeInsets.symmetric(horizontal: 13),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: BrokaColors.neonCyan.withOpacity(0.10),
              borderRadius: BorderRadius.circular(19),
              border: Border.all(color: BrokaColors.neonCyan.withOpacity(0.65)),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.map_outlined, size: 16, color: BrokaColors.neonCyan),
              if (!iconOnly) ...[
                const SizedBox(width: 6),
                const Text('Map',
                    style: TextStyle(color: BrokaColors.neonCyan, fontSize: 13, fontWeight: FontWeight.w800)),
              ],
            ]),
          ),
        ),
      );
}

/// Visit store: a pill as wide as its words (the whole card is the tap
/// target; this says what the tap does).
class _VisitButton extends StatelessWidget {
  const _VisitButton({super.key, this.short = false});

  /// "Visit" instead of "Visit store", on narrow cards (see the
  /// footer's LayoutBuilder).
  final bool short;

  @override
  Widget build(BuildContext context) => Container(
        height: 38,
        padding: const EdgeInsets.fromLTRB(16, 0, 12, 0),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [BrokaColors.gold, BrokaColors.neonBlue]),
          borderRadius: BorderRadius.circular(19),
          boxShadow: [BoxShadow(color: BrokaColors.gold.withOpacity(0.35), blurRadius: 12,
              offset: const Offset(0, 3))],
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.storefront_rounded, color: Colors.white, size: 17),
          const SizedBox(width: 7),
          Text(short ? 'Visit' : 'Visit store', style: const TextStyle(color: Colors.white,
              fontWeight: FontWeight.w800, fontSize: 13.5)),
          const SizedBox(width: 3),
          const Icon(Icons.arrow_forward_rounded, color: Colors.white, size: 16),
        ]),
      );
}

/// The store's logo in a ring of BROKA's gradient - or BROKA's own mark
/// when the owner uploaded none, so every shopfront wears a sign.
class _Logo extends StatelessWidget {
  const _Logo({required this.source, required this.size});
  final String? source;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: const LinearGradient(colors: BrokaColors.brandGradient),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.45), blurRadius: 10)],
        ),
        child: Container(
          decoration: const BoxDecoration(shape: BoxShape.circle, color: BrokaColors.bgMid),
          clipBehavior: Clip.antiAlias,
          child: source == null
              ? const BrokaDefaultLogo()
              : StoreMediaImage(
                  dataUri: source,
                  fit: BoxFit.cover,
                  placeholderBuilder: (_) => const BrokaDefaultLogo(),
                ),
        ),
      );
}

class _Pill extends StatelessWidget {
  const _Pill({super.key, required this.label, required this.color, this.dot});
  final String label;
  final Color color;
  final Color? dot;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 200),
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.55),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withOpacity(0.18)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (dot != null) ...[
          Container(width: 7, height: 7, decoration: BoxDecoration(color: dot,
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: dot!, blurRadius: 5)])),
          const SizedBox(width: 5),
        ],
        Flexible(
          child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color, fontSize: 11.5, fontWeight: FontWeight.w700)),
        ),
      ]),
    );
  }
}

/// Details: the secondary action on a store card (the card itself opens the
/// store). Drawn in the fact row's own language - a gold-outline pill on the
/// card surface, the quiet sibling of the gradient Visit store pill - so it
/// reads as part of BROKA, not a system warning.
class _DetailsPill extends StatelessWidget {
  const _DetailsPill({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: 'View store details',
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: BrokaColors.gold.withOpacity(0.10),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: BrokaColors.gold.withOpacity(0.65)),
            ),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.info_outline_rounded, size: 15, color: BrokaColors.gold),
              SizedBox(width: 5),
              Text('Details', style: TextStyle(color: BrokaColors.gold,
                  fontSize: 12.5, fontWeight: FontWeight.w800, letterSpacing: -0.1)),
            ]),
          ),
        ),
      );
}

class _Fact extends StatelessWidget {
  const _Fact({required this.icon, required this.color, required this.text});
  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withOpacity(0.10),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withOpacity(0.28)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(text, style: const TextStyle(color: BrokaColors.textHigh, fontSize: 11.5,
              fontWeight: FontWeight.w700)),
        ]),
      );
}
