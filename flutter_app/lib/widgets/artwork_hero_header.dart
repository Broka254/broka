// lib/widgets/artwork_hero_header.dart
//
// The pinned header of a Category Zone and of a subcategory screen
// (2026-10-08): the category's picture as a hero, the title written over its
// dark left side, collapsing as the feed scrolls into the same compact bar
// CollapsingScreenHeader leaves - back, badge, one-line title, the filter
// button.
//
// It keeps CollapsingScreenHeader's three guarantees (see that file), with
// the picture on top of them:
//
//  * Its child's height is always exactly maxExtent - shrinkOffset.
//  * Its backdrop (the first DecoratedBox, which the tests read) is
//    transparent at rest - the picture fades into the constellation below
//    it - and opaque within 18px of scroll, so cards scrolling under the
//    pinned bar never show through it. The picture fades out as it goes.
//  * Back and [trailing] are reachable at every scroll position, at the
//    same place, in the top 52px.
//
// The title is ONE widget that moves (bottom-left at rest, beside the back
// button collapsed) rather than two that cross-fade, so a screen reader and
// a finder see one title at every scroll position.
import 'package:flutter/material.dart';

import '../main.dart';

class ArtworkHeroHeader extends SliverPersistentHeaderDelegate {
  ArtworkHeroHeader({
    required this.title,
    required this.emoji,
    required this.gradient,
    required this.onBack,
    required this.narrow,
    required this.textScale,
    this.assetPath,
    this.eyebrow,
    this.trailing,
    this.trailingKey,
  });

  /// Rendered upper-cased through [ZoneGlowText].
  final String title;

  /// A small line above the title at rest - the parent category on a
  /// subcategory screen ("ELECTRONICS"). Gone once the header collapses.
  final String? eyebrow;

  final String emoji;
  final List<Color> gradient;

  /// The hero picture; null draws the category's gradient instead.
  final String? assetPath;

  final VoidCallback onBack;
  final Widget? trailing;

  /// What [trailing] depends on, for [shouldRebuild] (see
  /// CollapsingScreenHeader.trailingKey).
  final Object? trailingKey;

  final bool narrow;

  /// Clamped by the caller to 1.0-1.35.
  final double textScale;

  static const double control = 40;

  double get _titleFont => narrow ? 21.0 : 23.0;

  @override
  double get maxExtent =>
      // Room for a two-line title at the user's text size on top of the
      // picture's own height.
      (narrow ? 136.0 : 148.0) + _titleFont * 1.12 * 2 * (textScale - 1);

  @override
  double get minExtent => (control + 12) * textScale;

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final range = maxExtent - minExtent;
    final t = range <= 0 ? 1.0 : (shrinkOffset / range).clamp(0.0, 1.0);
    final height = (maxExtent - shrinkOffset).clamp(minExtent, maxExtent);
    final backdrop = (shrinkOffset / 18.0).clamp(0.0, 1.0);
    final art = (1 - t * 1.25).clamp(0.0, 1.0);
    final badge = _lerp(30, 26, t);
    final bar = minExtent;
    // Beside the back button once collapsed; on the page's 16px edge at rest.
    final titleLeft = _lerp(16, 6 + control + 4, t);
    final titleRight = 16.0 + (trailing == null ? 0.0 : _lerp(0, control + 8, t));
    // Centred in the bar once collapsed (the bar is the header's last 52px).
    final titleBottom = _lerp(14, (bar - badge) / 2, t);
    final eyebrowOpacity = (1 - t * 3).clamp(0.0, 1.0);

    return SizedBox(
      height: height,
      child: ClipRect(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: BrokaColors.bg.withOpacity(backdrop),
            border: Border(
              bottom: BorderSide(color: BrokaColors.border.withOpacity(0.7 * t)),
            ),
            boxShadow: t < 0.98
                ? null
                : [BoxShadow(color: Colors.black.withOpacity(0.35), blurRadius: 12, offset: const Offset(0, 2))],
          ),
          child: Stack(fit: StackFit.expand, children: [
            if (art > 0)
              Opacity(
                opacity: art,
                child: Stack(fit: StackFit.expand, children: [
                  if (assetPath != null)
                    Image.asset(
                      assetPath!,
                      fit: BoxFit.cover,
                      // The pictures' subject sits right of centre.
                      alignment: const Alignment(0.55, 0),
                      gaplessPlayback: true,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.bottomLeft,
                        end: Alignment.topRight,
                        colors: [
                          gradient.first.withOpacity(assetPath == null ? 0.38 : 0.22),
                          gradient.last.withOpacity(assetPath == null ? 0.16 : 0.0),
                        ],
                      ),
                    ),
                  ),
                  // Dark at the top for the controls, dark at the bottom for
                  // the title, and transparent at the very bottom edge so the
                  // picture runs into the constellation instead of ending on
                  // a line.
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0x99000000), Color(0x11000000), Color(0x8C03040A), Color(0x0003040A)],
                        stops: [0.0, 0.38, 0.86, 1.0],
                      ),
                    ),
                  ),
                ]),
              ),
            Positioned(
              left: 6,
              top: (bar - control) / 2,
              child: GestureDetector(
                onTap: onBack,
                behavior: HitTestBehavior.opaque,
                child: Container(
                  width: control,
                  height: control,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.black.withOpacity(0.35 * art),
                  ),
                  child: const Icon(Icons.arrow_back_ios_new_rounded,
                      color: BrokaColors.textHigh, size: 19),
                ),
              ),
            ),
            if (trailing != null)
              Positioned(
                right: 16,
                top: (bar - control) / 2,
                child: trailing!,
              ),
            Positioned(
              left: titleLeft,
              right: titleRight,
              bottom: titleBottom,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (eyebrow != null && eyebrowOpacity > 0)
                    Opacity(
                      opacity: eyebrowOpacity,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          eyebrow!.toUpperCase(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.82),
                            fontSize: 10.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1.6,
                          ),
                        ),
                      ),
                    ),
                  Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
                    Container(
                      width: badge,
                      height: badge,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: LinearGradient(colors: [
                          gradient.first.withOpacity(0.38),
                          gradient.last.withOpacity(0.18),
                        ]),
                        color: Colors.black.withOpacity(0.3),
                        border: Border.all(color: gradient.first.withOpacity(0.6)),
                      ),
                      child: Center(child: Text(emoji, style: TextStyle(fontSize: badge * 0.46))),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ZoneGlowText(
                        title,
                        gradient: gradient,
                        fontSize: _lerp(_titleFont, _titleFont * 0.76, t),
                        maxLines: t > 0.5 ? 1 : 2,
                        letterSpacing: narrow ? 0.8 : 1.1,
                      ),
                    ),
                  ]),
                ],
              ),
            ),
          ]),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant ArtworkHeroHeader oldDelegate) =>
      oldDelegate.title != title ||
      oldDelegate.eyebrow != eyebrow ||
      oldDelegate.emoji != emoji ||
      oldDelegate.assetPath != assetPath ||
      oldDelegate.gradient != gradient ||
      oldDelegate.narrow != narrow ||
      oldDelegate.textScale != textScale ||
      oldDelegate.trailingKey != trailingKey ||
      (oldDelegate.trailing == null) != (trailing == null) ||
      oldDelegate.onBack != onBack;
}
