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
// (store_category_screen.dart). The directory opts into [StoreCard.wide] -
// one shop per row, picture left, facts right (2026-10-22) - and every other
// caller keeps the tall default card.
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

  /// Draw the directory's wide card instead of the tall shopfront card.
  ///
  /// The default stays the tall, single-column shopfront used by the nearby
  /// and category screens. This opt-in variant lays the picture down the
  /// left of the card and the facts beside it, so one shop takes a row;
  /// keeping it explicit means changing the directory's density cannot
  /// silently restyle a screen that already depends on the larger card.
  final bool wide;

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
    this.wide = false,
  });

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
    if (widget.wide) return _buildWide(context);

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

  /// The directory's card, laid on its side: the shop's picture fills the
  /// left of the card and the facts a buyer scans sit in a column beside it.
  ///
  /// It replaced the two-column grid of tall cards (2026-10-22). Two cards
  /// across a phone halved every line, so a name wrapped, a place wrapped,
  /// and the picture shrank to a thumbnail above the text - the opposite of
  /// what a directory is for, which is comparing shops. One shop per row
  /// gives the picture the size of a shopfront and every fact a line of its
  /// own.
  Widget _buildWide(BuildContext context) {
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
    final secondaryActions = (widget.onMap == null ? 0 : 1) +
        (widget.onDetails == null ? 0 : 1);
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
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(1.2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
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
                  color: BrokaColors.gold.withOpacity(0.12),
                  blurRadius: 18,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Container(
              decoration: BoxDecoration(
                gradient: BrokaColors.cardGradient,
                borderRadius: BorderRadius.circular(19),
              ),
              clipBehavior: Clip.antiAlias,
              // The picture is a share of the card rather than a fixed
              // column: a narrow phone keeps the facts readable, and the cap
              // stops a wide tablet card from becoming a poster with captions.
              child: LayoutBuilder(builder: (context, box) {
                final imageWidth =
                    (box.maxWidth * 0.42).clamp(124.0, 210.0).toDouble();
                return Stack(children: [
                  ConstrainedBox(
                    // A floor, so a shop with no rating, no place and no
                    // category still gets a card with a real picture on it
                    // rather than a strip of one.
                    constraints: const BoxConstraints(minHeight: 172),
                    child: Padding(
                      padding:
                          EdgeInsets.fromLTRB(imageWidth + 14, 12, 14, 12),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Flexible(
                                child: Text(store.name,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                        color: BrokaColors.textHigh,
                                        fontWeight: FontWeight.w800,
                                        fontSize: 19,
                                        height: 1.15,
                                        letterSpacing: -0.3)),
                              ),
                              if (owner?.verified ?? false) ...[
                                const SizedBox(width: 5),
                                const Icon(Icons.verified_rounded,
                                    size: 17,
                                    color: BrokaColors.success,
                                    semanticLabel: 'Verified seller'),
                              ],
                            ],
                          ),
                          if (store.rating != null) ...[
                            const SizedBox(height: 6),
                            _RatingChip(
                              key: Key('store-rating-${store.id}'),
                              rating: store.rating!,
                              reviews: store.reviewCount,
                            ),
                          ],
                          if (store.locationLine != null ||
                              distLabel != null) ...[
                            const SizedBox(height: 7),
                            Row(children: [
                              const Icon(Icons.location_on_outlined,
                                  size: 15, color: BrokaColors.gold),
                              const SizedBox(width: 4),
                              // The distance rides on the place line: it is
                              // part of where the shop is, and the picture is
                              // too narrow here for a pill over it.
                              Flexible(
                                child: Text.rich(
                                  TextSpan(children: [
                                    if (store.locationLine != null)
                                      TextSpan(
                                          text: store.locationLine!,
                                          style: const TextStyle(
                                              color: BrokaColors.textMid,
                                              fontSize: 12.5)),
                                    if (store.locationLine != null &&
                                        distLabel != null)
                                      const TextSpan(
                                          text: ' · ',
                                          style: TextStyle(
                                              color: BrokaColors.textMid,
                                              fontSize: 12.5)),
                                    if (distLabel != null)
                                      TextSpan(
                                          text: distLabel,
                                          style: const TextStyle(
                                              color: BrokaColors.gold,
                                              fontSize: 12.5,
                                              fontWeight: FontWeight.w800)),
                                  ]),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ]),
                          ],
                          if (category != null) ...[
                            const SizedBox(height: 6),
                            // Emoji and label in one Text, as the tall card
                            // does: an emoji of its own would read as the
                            // card's category fallback when it is BROKA's mark
                            // that stands in for a missing picture.
                            Text(
                              '${CategoryVisuals.emojiFor(category)}  '
                              '$category$moreCategories',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  color: BrokaColors.textMid,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w600),
                            ),
                          ],
                          const SizedBox(height: 10),
                          Divider(
                              height: 1,
                              thickness: 1,
                              color: BrokaColors.border.withOpacity(0.9)),
                          const SizedBox(height: 10),
                          Row(children: [
                            const Icon(Icons.inventory_2_outlined,
                                size: 15, color: BrokaColors.textMid),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(products,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                      color: BrokaColors.textHigh,
                                      fontSize: 12.5,
                                      fontWeight: FontWeight.w700)),
                            ),
                          ]),
                          const SizedBox(height: 10),
                          // Visit takes whatever the two square actions leave,
                          // so it is still the widest target at the foot.
                          Row(children: [
                            if (widget.onMap != null)
                              _WideIconAction(
                                key: Key('store-map-${store.id}'),
                                icon: Icons.map_outlined,
                                tooltip: 'View on map',
                                color: BrokaColors.neonCyan,
                                onTap: widget.onMap!,
                              ),
                            if (widget.onMap != null &&
                                widget.onDetails != null)
                              const SizedBox(width: 8),
                            if (widget.onDetails != null)
                              _WideIconAction(
                                key: Key('store-details-${store.id}'),
                                icon: Icons.info_outline_rounded,
                                tooltip: 'Store details',
                                color: BrokaColors.gold,
                                onTap: widget.onDetails!,
                              ),
                            if (secondaryActions > 0) const SizedBox(width: 8),
                            Expanded(
                              child: _WideVisitButton(
                                key: Key('visit-store-${store.id}'),
                                onTap: widget.onTap,
                              ),
                            ),
                          ]),
                        ],
                      ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: imageWidth,
                    child: Stack(children: [
                      Positioned.fill(
                        child: picture == null
                            ? fallback
                            : StoreMediaImage(
                                dataUri: picture,
                                fit: BoxFit.cover,
                                placeholderBuilder: (_) => pictureFallback,
                              ),
                      ),
                      // Shade at the top and foot only: the status pill and
                      // the logo sit on busy shop photos, and both have to
                      // stay legible without dimming the middle of the shot.
                      const Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Color(0x55000000),
                                Color(0x00000000),
                                Color(0xBB070B16),
                              ],
                              stops: [0, 0.45, 1],
                            ),
                          ),
                        ),
                      ),
                      if (owner != null &&
                          (owner.online || owner.lastActive != null))
                        Positioned(
                          top: 8,
                          left: 8,
                          right: 8,
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
                      if (showLogo)
                        Positioned(
                          left: 10,
                          bottom: 10,
                          child: _Logo(source: logo, size: 46),
                        ),
                    ]),
                  ),
                ]);
              }),
            ),
          ),
        ),
      ),
    );
  }
}

/// A 44dp square secondary action on the wide card - the map and the
/// store's details. Quiet outlines, because the card itself opens the
/// store and Visit is the one action meant to be found first.
class _WideIconAction extends StatelessWidget {
  const _WideIconAction({
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
                borderRadius: BorderRadius.circular(13),
                border: Border.all(color: color.withOpacity(0.55)),
              ),
              child: Icon(icon, size: 19, color: color),
            ),
          ),
        ),
      );
}

/// Visit store on the wide card: the loud action, filling the rest of the
/// row so the thumb lands on it first. The whole card opens the store too;
/// this says so, and gives the tap somewhere obvious to happen.
class _WideVisitButton extends StatelessWidget {
  const _WideVisitButton({super.key, required this.onTap});

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
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(horizontal: 8),
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
              // Scales down rather than clipping, so a narrow card at large
              // system text still reads "Visit" and keeps its arrow.
              child: const FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text('Visit',
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                          fontSize: 13)),
                  SizedBox(width: 5),
                  Icon(Icons.arrow_forward_rounded,
                      color: Colors.white, size: 16),
                ]),
              ),
            ),
          ),
        ),
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
        // Wrapped rather than a Row: the wide card gives the chip the width
        // of a column, and at large system text a Row can only overflow -
        // the count drops to a second line instead of losing its last digit.
        child: Wrap(
          spacing: 3,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Icon(Icons.star_rounded, size: 13, color: BrokaColors.gold),
            Text(rating.toStringAsFixed(1),
                style: const TextStyle(
                    color: BrokaColors.gold,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    height: 1.2)),
            if (reviews > 0)
              Text('($reviews)',
                  style: TextStyle(
                      color: BrokaColors.gold.withOpacity(0.75),
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      height: 1.2)),
          ],
        ),
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
