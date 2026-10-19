// A store in the directory, as a shop window: the picture its owner chose
// to show (the cover, else a shop photo, else the logo), whether the owner
// is online, what and where it is, how far away it is, and Visit store.
//
// The seller's record (rating, deals done) is not on this card: a buyer
// judging a shop reads it in Store details. Where the shop is matters
// here, so "View on map" sits in the chip row, and the distance is shown
// whenever it is known - a shop 40 km away is a fact, not something to
// hide.
//
// Shared by the directory and a category's screen of its own
// (store_category_screen.dart). The directory opts into [StoreCard.compact]
// for its two-column grids; every other caller keeps the tall default card.
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

  /// Draw the directory's two-column card instead of the full-width card.
  ///
  /// The default stays the tall, single-column shopfront used by the nearby
  /// and category screens. This opt-in variant is deliberately narrower:
  /// the picture is cropped shorter, secondary actions become icon buttons,
  /// and the footer keeps Visit as the one loud action. Keeping it explicit
  /// means adding a grid to the directory cannot silently restyle a screen
  /// that already depends on the larger card.
  final bool compact;

  /// Opens the store's details screen (reviews, seller record, location).
  /// A chip on the picture, not another bar: the card itself still opens
  /// the store, and this is the secondary thing a buyer does from here.
  /// Null hides it.
  final VoidCallback? onDetails;

  /// Opens the store on the map. Null hides the Map action.
  final VoidCallback? onMap;

  const StoreCard({
    super.key,
    required this.store,
    required this.onTap,
    this.onDetails,
    this.onMap,
    this.compact = false,
  });

  /// Height of the compact card's picture. It is based on the card width so
  /// every card in a grid row fills the same box without stretching the
  /// source image; the cap keeps a single-column fallback from turning into
  /// an oversized hero.
  static double compactImageHeightFor(double width) =>
      (width * 0.60).clamp(104.0, 144.0).toDouble();

  /// The grid needs the card's full height before laying a row out. This is
  /// the same content budget the compact builder uses below, scaled with the
  /// system text size; reserving it up front is what keeps the last action
  /// row from overflowing instead of quietly clipping a long name.
  static double compactExtentFor({
    required double width,
    required double textScale,
  }) {
    final scale = textScale.clamp(1.0, 3.0).toDouble();
    final image = compactImageHeightFor(width);
    final name = 15.0 * 1.18 * 2 * scale;
    final rating = (13.0 * 1.2 * scale) + 4;
    final location = (12.0 * 1.25 * 2 * scale) + 4;
    final category = (11.5 * 1.2 * scale) + 4;
    final products = (11.5 * 1.2 * scale) + 6;
    return image +
        10 +
        name +
        rating +
        location +
        category +
        products +
        44 +
        10 +
        10 +
        // Sub-pixel row rounding and the border inset: without a little
        // slack a perfectly measured cell can still report a 0.2px overflow.
        4;
  }

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
    if (widget.compact) return _buildCompact(context);

    final store = widget.store;
    // The distance a buyer wants first, at any range: a shop 40 km away is
    // a fact worth knowing, not one to hide because it isn't "near".
    // Unknown stays unknown - nothing is shown at all (there is no honest
    // number to invent).
    final distLabel = store.anyDistanceLabel;
    final owner = store.owner;
    final colors = CategoryVisuals.gradientFor(store.category);
    final picture = store.coverSource ?? store.logo?.medium ?? store.logoUrl;
    final logo = store.logoSource;
    // The logo as a sign only when the picture is something else: a card
    // whose only image is the logo would show it twice. No cover at all
    // still shows BROKA's mark full width; with one, the sign is BROKA's
    // mark until the owner uploads their own.
    final showLogo = store.coverSource != null;
    final products =
        '${store.listingCount} product${store.listingCount == 1 ? '' : 's'}';
    // The pill shows whenever the screen wired a map action: with a real
    // pin it opens the in-app map, and without one the action falls back
    // to the shop's place (openStoreMap).
    final canMap = widget.onMap != null;

    final gradient = BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          BrokaColors.gold.withOpacity(0.45),
          BrokaColors.bgCard,
          colors.last.withOpacity(0.40),
        ],
      ),
    );

    // A shop with no picture at all shows BROKA's mark, not its category
    // emoji: the emoji read as clip-art standing in for a photo, and the
    // mark is what the store's own logo falls back to everywhere else.
    final fallback = DecoratedBox(
      decoration: gradient,
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

    // The slot a picture downloads into, or lands in when its URL fails.
    // It carries the mark only when the card has no sign: with a cover the
    // sign below the picture already wears BROKA's mark, and repeating it
    // here put two marks on one shopfront (the regression the directory
    // test caught after BrokaImage started drawing caller placeholders
    // while loading).
    final pictureFallback =
        showLogo ? DecoratedBox(decoration: gradient) : fallback;

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
                colors: [
                  BrokaColors.gold.withOpacity(0.55),
                  BrokaColors.neonBlue.withOpacity(0.40)
                ],
              ),
              boxShadow: [
                BoxShadow(
                    color: BrokaColors.gold.withOpacity(0.12), blurRadius: 18),
              ],
            ),
            child: Container(
              decoration: BoxDecoration(
                gradient: BrokaColors.cardGradient,
                borderRadius: BorderRadius.circular(19),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      height: _pictureHeight,
                      child: Stack(fit: StackFit.expand, children: [
                        picture == null
                            ? fallback
                            : StoreMediaImage(
                                dataUri: picture,
                                placeholderBuilder: (_) => pictureFallback,
                              ),
                        // Dark at the top and foot, so the chips on the picture
                        // stay legible whatever the photo is.
                        const DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Color(0x66000000),
                                Colors.transparent,
                                Color(0xCC0A1220)
                              ],
                              stops: [0, 0.42, 1],
                            ),
                          ),
                        ),
                        if (owner != null &&
                            (owner.online || owner.lastActive != null))
                          Positioned(
                            top: 10,
                            left: 10,
                            child: _Pill(
                              key: const Key('store-card-presence'),
                              dot: owner.online
                                  ? BrokaColors.success
                                  : BrokaColors.textMid,
                              label: owner.online
                                  ? 'Online now'
                                  : owner.lastActive!,
                              color: owner.online
                                  ? BrokaColors.success
                                  : Colors.white70,
                            ),
                          ),
                        if (store.categories.isNotEmpty)
                          Positioned(
                            right: 10,
                            bottom: 10,
                            child: _Pill(
                              // The primary, plus how many more: the full set
                              // belongs on the store's own page, not a caption.
                              label:
                                  '${CategoryVisuals.emojiFor(store.categories.first)}  '
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
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Padding(
                                padding: EdgeInsets.only(
                                    left: showLogo ? _logoSize + 12 : 0),
                                child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(children: [
                                        Flexible(
                                          child: Text(store.name,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                  color: BrokaColors.textHigh,
                                                  fontWeight: FontWeight.w800,
                                                  fontSize: 17.5,
                                                  letterSpacing: -0.2)),
                                        ),
                                        if (owner?.verified ?? false) ...[
                                          const SizedBox(width: 5),
                                          const Icon(Icons.verified_rounded,
                                              size: 17,
                                              color: BrokaColors.success,
                                              semanticLabel: 'Verified seller'),
                                        ],
                                        if (store.rating != null) ...[
                                          const SizedBox(width: 8),
                                          _RatingChip(
                                            key:
                                                Key('store-rating-${store.id}'),
                                            rating: store.rating!,
                                            reviews: store.reviewCount,
                                          ),
                                        ],
                                      ]),
                                      if (store.locationLine != null ||
                                          distLabel != null) ...[
                                        const SizedBox(height: 4),
                                        Row(children: [
                                          const Icon(Icons.location_on_outlined,
                                              size: 15,
                                              color: BrokaColors.gold),
                                          const SizedBox(width: 4),
                                          Flexible(
                                              child: Text.rich(
                                                  TextSpan(children: [
                                                    if (store.locationLine !=
                                                        null)
                                                      TextSpan(
                                                          text: store
                                                              .locationLine!,
                                                          style: const TextStyle(
                                                              color: BrokaColors
                                                                  .textMid,
                                                              fontSize: 13)),
                                                    if (store.locationLine !=
                                                            null &&
                                                        distLabel != null)
                                                      const TextSpan(
                                                          text: ' · ',
                                                          style: TextStyle(
                                                              color: BrokaColors
                                                                  .textMid,
                                                              fontSize: 13)),
                                                    if (distLabel != null)
                                                      TextSpan(
                                                          text: distLabel,
                                                          style: const TextStyle(
                                                              color: BrokaColors
                                                                  .gold,
                                                              fontSize: 13,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w700)),
                                                  ]),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis)),
                                        ]),
                                      ],
                                    ]),
                              ),
                              // At least the logo's overhang, so the chips never run
                              // under it when there's no location line.
                              SizedBox(
                                  height: showLogo && store.locationLine == null
                                      ? 16
                                      : 10),
                              Wrap(spacing: 6, runSpacing: 6, children: [
                                // The shop's place on the map, where the seller's
                                // record used to be. "View on map" is a real action
                                // and most people missed the small Map pill at the
                                // foot; the seller's record lives in Store details,
                                // where a buyer goes when they are judging a shop.
                                if (canMap)
                                  _MapPill(
                                    key: Key('store-map-${store.id}'),
                                    onTap: widget.onMap!,
                                  ),
                                // Details sits here, in the card's own chip row -
                                // the quiet sibling of Visit store below.
                                if (widget.onDetails != null)
                                  _DetailsPill(
                                    key: Key('store-details-${store.id}'),
                                    onTap: widget.onDetails!,
                                  ),
                              ]),
                              const SizedBox(height: 12),
                              Container(
                                  height: 1,
                                  color: BrokaColors.border.withOpacity(0.8)),
                              const SizedBox(height: 10),
                              // One line at every width: under 360dp Visit shortens,
                              // so the product count keeps room instead of
                              // overflowing the row (a 320dp phone's card is ~260dp
                              // inside).
                              LayoutBuilder(builder: (context, row) {
                                final compact = row.maxWidth < 360;
                                return Row(children: [
                                  const Icon(Icons.inventory_2_outlined,
                                      size: 15, color: BrokaColors.textMid),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(products,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                            color: BrokaColors.textHigh,
                                            fontSize: 13,
                                            fontWeight: FontWeight.w700)),
                                  ),
                                  const SizedBox(width: 10),
                                  _VisitButton(
                                      key: Key('visit-store-${store.id}'),
                                      short: compact),
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

  Widget _buildCompact(BuildContext context) {
    final store = widget.store;
    final distLabel = store.anyDistanceLabel;
    final owner = store.owner;
    final colors = CategoryVisuals.gradientFor(store.category);
    final picture = store.coverSource ?? store.logo?.medium ?? store.logoUrl;
    final logo = store.logoSource;
    // The logo is a sign over the cover, never a second copy of the picture.
    // A card whose only image is the logo therefore leaves the sign off.
    final showLogo = store.coverSource != null;
    final category = store.categories.isEmpty ? null : store.categories.first;
    final moreCategories =
        store.categories.length > 1 ? ' +${store.categories.length - 1}' : '';
    final products =
        '${store.listingCount} product${store.listingCount == 1 ? '' : 's'}';
    final gradient = BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          BrokaColors.gold.withOpacity(0.45),
          BrokaColors.bgCard,
          colors.last.withOpacity(0.40),
        ],
      ),
    );
    final fallback = DecoratedBox(
      decoration: gradient,
      child: const Center(
        child: SizedBox(
          width: 52,
          height: 52,
          child: ClipRRect(
            borderRadius: BorderRadius.all(Radius.circular(14)),
            child: BrokaDefaultLogo(),
          ),
        ),
      ),
    );
    final pictureFallback =
        showLogo ? DecoratedBox(decoration: gradient) : fallback;

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
          scale: _down && !BrokaMotion.reduced(context) ? 0.985 : 1.0,
          duration: BrokaMotion.instant,
          curve: Curves.easeOut,
          child: Container(
            padding: const EdgeInsets.all(1.1),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(17),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  BrokaColors.gold.withOpacity(0.55),
                  BrokaColors.neonBlue.withOpacity(0.40),
                ],
              ),
              boxShadow: [
                BoxShadow(
                  color: BrokaColors.gold.withOpacity(0.10),
                  blurRadius: 14,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Container(
              decoration: BoxDecoration(
                gradient: BrokaColors.cardGradient,
                borderRadius: BorderRadius.circular(16),
              ),
              clipBehavior: Clip.antiAlias,
              child: LayoutBuilder(builder: (context, box) {
                final imageHeight =
                    StoreCard.compactImageHeightFor(box.maxWidth);
                final secondaryActions = (widget.onMap == null ? 0 : 1) +
                    (widget.onDetails == null ? 0 : 1);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      height: imageHeight,
                      child: Stack(fit: StackFit.expand, children: [
                        picture == null
                            ? fallback
                            : StoreMediaImage(
                                dataUri: picture,
                                fit: BoxFit.cover,
                                placeholderBuilder: (_) => pictureFallback,
                              ),
                        // The chips sit on busy shop photos; this keeps the
                        // status and distance legible without dimming the
                        // whole picture.
                        const DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Color(0x55000000),
                                Color(0x00000000),
                                Color(0xBB070B16),
                              ],
                              stops: [0, 0.48, 1],
                            ),
                          ),
                        ),
                        if (owner != null &&
                            (owner.online || owner.lastActive != null))
                          Positioned(
                            top: 7,
                            left: 7,
                            right: 7,
                            child: Align(
                              alignment: Alignment.topLeft,
                              child: _Pill(
                                key: const Key('store-card-presence'),
                                dot: owner.online
                                    ? BrokaColors.success
                                    : BrokaColors.textMid,
                                label: owner.online
                                    ? 'Online now'
                                    : owner.lastActive!,
                                color: owner.online
                                    ? BrokaColors.success
                                    : Colors.white70,
                              ),
                            ),
                          ),
                        Positioned(
                          left: 7,
                          right: 7,
                          bottom: 7,
                          child: Row(children: [
                            if (showLogo) _Logo(source: logo, size: 34),
                            if (showLogo && distLabel != null)
                              const SizedBox(width: 6),
                            if (distLabel != null)
                              Expanded(
                                child: Align(
                                  alignment: Alignment.bottomRight,
                                  child: _CompactDistancePill(
                                    key: const Key('store-card-distance'),
                                    label: distLabel,
                                  ),
                                ),
                              ),
                          ]),
                        ),
                      ]),
                    ),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(10, 9, 10, 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: Text(
                                      store.name,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: BrokaColors.textHigh,
                                        fontWeight: FontWeight.w800,
                                        fontSize: 15,
                                        height: 1.18,
                                        letterSpacing: -0.2,
                                      ),
                                    ),
                                  ),
                                  if (owner?.verified ?? false) ...[
                                    const SizedBox(width: 4),
                                    const Icon(Icons.verified_rounded,
                                        size: 15,
                                        color: BrokaColors.success,
                                        semanticLabel: 'Verified seller'),
                                  ],
                                ]),
                            if (store.rating != null) ...[
                              const SizedBox(height: 4),
                              _RatingChip(
                                key: Key('store-rating-${store.id}'),
                                rating: store.rating!,
                                reviews: store.reviewCount,
                              ),
                            ],
                            if (store.locationLine != null) ...[
                              const SizedBox(height: 4),
                              Row(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Padding(
                                      padding: EdgeInsets.only(top: 1),
                                      child: Icon(Icons.location_on_outlined,
                                          size: 13, color: BrokaColors.gold),
                                    ),
                                    const SizedBox(width: 3),
                                    Expanded(
                                      child: Text(
                                        store.locationLine!,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                          color: BrokaColors.textMid,
                                          fontSize: 12,
                                          height: 1.25,
                                        ),
                                      ),
                                    ),
                                  ]),
                            ],
                            if (category != null) ...[
                              const SizedBox(height: 4),
                              Text(
                                '${CategoryVisuals.emojiFor(category)} $category$moreCategories',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: BrokaColors.textMid,
                                  fontSize: 11.5,
                                  height: 1.2,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                            const Spacer(),
                            Row(children: [
                              const Icon(Icons.inventory_2_outlined,
                                  size: 14, color: BrokaColors.textMid),
                              const SizedBox(width: 4),
                              Expanded(
                                child: Text(
                                  products,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: BrokaColors.textHigh,
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ]),
                            const SizedBox(height: 6),
                            LayoutBuilder(builder: (context, row) {
                              final fullLabel =
                                  secondaryActions == 0 || row.maxWidth >= 205;
                              return Row(children: [
                                if (widget.onMap != null)
                                  _CompactIconAction(
                                    key: Key('store-map-${store.id}'),
                                    icon: Icons.map_outlined,
                                    tooltip: 'View on map',
                                    color: BrokaColors.neonCyan,
                                    onTap: widget.onMap!,
                                  ),
                                if (widget.onMap != null &&
                                    widget.onDetails != null)
                                  const SizedBox(width: 4),
                                if (widget.onDetails != null)
                                  _CompactIconAction(
                                    key: Key('store-details-${store.id}'),
                                    icon: Icons.info_outline_rounded,
                                    tooltip: 'Store details',
                                    color: BrokaColors.gold,
                                    onTap: widget.onDetails!,
                                  ),
                                if (secondaryActions > 0)
                                  const SizedBox(width: 4),
                                Expanded(
                                  child: _CompactVisitButton(
                                    key: Key('visit-store-${store.id}'),
                                    fullLabel: fullLabel,
                                    onTap: widget.onTap,
                                  ),
                                ),
                              ]);
                            }),
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              }),
            ),
          ),
        ),
      ),
    );
  }
}

/// A 44dp secondary action on the compact card. The icon is small enough for
/// two cards to share a phone row, while the box keeps the tap target usable.
class _CompactIconAction extends StatelessWidget {
  const _CompactIconAction({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: Semantics(
          button: true,
          label: tooltip,
          child: GestureDetector(
            onTap: onTap,
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: color.withOpacity(0.10),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: color.withOpacity(0.55)),
              ),
              child: Icon(icon, size: 18, color: color),
            ),
          ),
        ),
      );
}

class _CompactVisitButton extends StatelessWidget {
  const _CompactVisitButton({
    super.key,
    required this.fullLabel,
    required this.onTap,
  });

  final bool fullLabel;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: 'Visit store',
        child: Tooltip(
          message: 'Visit store',
          child: GestureDetector(
            onTap: onTap,
            behavior: HitTestBehavior.opaque,
            child: Container(
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 6),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [BrokaColors.gold, BrokaColors.neonBlue],
                ),
                borderRadius: BorderRadius.circular(22),
                boxShadow: [
                  BoxShadow(
                    color: BrokaColors.gold.withOpacity(0.30),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(
                    fullLabel ? 'Visit store' : 'Visit',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 11.5,
                    ),
                  ),
                  const SizedBox(width: 3),
                  const Icon(Icons.arrow_forward_rounded,
                      color: Colors.white, size: 14),
                ]),
              ),
            ),
          ),
        ),
      );
}

class _CompactDistancePill extends StatelessWidget {
  const _CompactDistancePill({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [BrokaColors.gold, BrokaColors.neonBlue],
          ),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: BrokaColors.gold.withOpacity(0.28),
              blurRadius: 8,
            ),
          ],
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.near_me_rounded, size: 11, color: Colors.white),
          const SizedBox(width: 3),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ]),
      );
}

/// The store's own rating, on the card beside its name.
///
/// Not the owner's seller rating: a shop is rated on its own reviews, its
/// own reply time and how long it has traded (backend stores/rating.py).
/// A shop with no reviews yet shows its neutral score with no count - the
/// number is real, it just has no reviews behind it, and the card never
/// claims otherwise.
class _RatingChip extends StatelessWidget {
  const _RatingChip({super.key, required this.rating, this.reviews = 0});
  final double rating;
  final int reviews;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: BrokaColors.gold.withOpacity(0.14),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: BrokaColors.gold.withOpacity(0.45)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.star_rounded, size: 13, color: BrokaColors.gold),
          const SizedBox(width: 3),
          Text(rating.toStringAsFixed(1),
              style: const TextStyle(
                  color: BrokaColors.gold,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  height: 1.2)),
          if (reviews > 0) ...[
            const SizedBox(width: 3),
            Text('($reviews)',
                style: TextStyle(
                    color: BrokaColors.gold.withOpacity(0.75),
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    height: 1.2)),
          ],
        ]),
      );
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
          gradient: const LinearGradient(
              colors: [BrokaColors.gold, BrokaColors.neonBlue]),
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(color: BrokaColors.gold.withOpacity(0.35), blurRadius: 10)
          ],
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.near_me_rounded, size: 13, color: Colors.white),
          const SizedBox(width: 5),
          Text(label,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w800)),
        ]),
      );
}

/// View on map: the shop's place, as a chip in the card's own row.
///
/// This replaced the seller's record here (rating / deals done): most
/// buyers never noticed the small Map button at the foot of the card, and
/// where a shop actually is matters more to a buyer than a deal count,
/// which Store details still shows in full.
class _MapPill extends StatelessWidget {
  const _MapPill({super.key, required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: 'View store on map',
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: BrokaColors.neonCyan.withOpacity(0.10),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: BrokaColors.neonCyan.withOpacity(0.65)),
            ),
            child: const Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.map_outlined, size: 15, color: BrokaColors.neonCyan),
              SizedBox(width: 5),
              Text('View on map',
                  style: TextStyle(
                      color: BrokaColors.neonCyan,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.1)),
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
          gradient: const LinearGradient(
              colors: [BrokaColors.gold, BrokaColors.neonBlue]),
          borderRadius: BorderRadius.circular(19),
          boxShadow: [
            BoxShadow(
                color: BrokaColors.gold.withOpacity(0.35),
                blurRadius: 12,
                offset: const Offset(0, 3))
          ],
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          const Icon(Icons.storefront_rounded, color: Colors.white, size: 17),
          const SizedBox(width: 7),
          Text(short ? 'Visit' : 'Visit store',
              style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 13.5)),
          const SizedBox(width: 3),
          const Icon(Icons.arrow_forward_rounded,
              color: Colors.white, size: 16),
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
          boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(0.45), blurRadius: 10)
          ],
        ),
        child: Container(
          decoration: const BoxDecoration(
              shape: BoxShape.circle, color: BrokaColors.bgMid),
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
          Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                  color: dot,
                  shape: BoxShape.circle,
                  boxShadow: [BoxShadow(color: dot!, blurRadius: 5)])),
          const SizedBox(width: 5),
        ],
        Flexible(
          child: Text(label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  color: color, fontSize: 11.5, fontWeight: FontWeight.w700)),
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
              Icon(Icons.info_outline_rounded,
                  size: 15, color: BrokaColors.gold),
              SizedBox(width: 5),
              Text('Details',
                  style: TextStyle(
                      color: BrokaColors.gold,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.1)),
            ]),
          ),
        ),
      );
}
