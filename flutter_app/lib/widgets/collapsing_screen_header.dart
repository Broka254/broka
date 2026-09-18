// lib/widgets/collapsing_screen_header.dart
//
// The pinned, collapsing header shared by every screen you reach from Home's
// discovery rail: the five Category Zones' worth of category screens, plus
// Trending, the Auction House, Traders and Stores.
//
// It started life inside category_zone_screen.dart as _ZoneHeaderDelegate.
// Bringing the other four destinations onto the same visual system would have
// meant four more copies of it, which is how the app ended up with six
// category-emoji tables - so it moved here first.
//
// Three things it guarantees, and the reasons they are not left to call sites:
//
//  * Its child's height is always exactly maxExtent - shrinkOffset, so the
//    pinned sliver's geometry stays honest and the feed below genuinely
//    inherits the pixels rather than scrolling under a fixed bar.
//  * It is transparent at scroll offset 0, where there is nothing underneath
//    it and the constellation should show, and fully opaque within 18px of
//    scroll, where there is. That is the rule Home follows; a screen that got
//    it wrong would show product cards through its own header.
//  * The title wraps to two lines at rest and condenses to one as the header
//    collapses, with the break point decided by the width. "BEAUTY & PERSONAL
//    CARE ZONE" is the name that forced this; nothing is hardcoded per screen,
//    so a new destination with a long title needs no change here.
import 'package:flutter/material.dart';

import '../main.dart';

/// Back button + category/destination badge + gradient title + optional
/// trailing control, collapsing as the screen scrolls.
///
/// Back and [trailing] stay reachable at every scroll position on purpose:
/// they are the two things a user on a deep screen always needs within reach.
class CollapsingScreenHeader extends SliverPersistentHeaderDelegate {
  CollapsingScreenHeader({
    required this.title,
    required this.emoji,
    required this.gradient,
    required this.onBack,
    required this.narrow,
    required this.textScale,
    this.trailing,
    this.trailingKey,
  });

  /// Rendered upper-cased through [ZoneGlowText].
  final String title;

  /// The screen's own visual, from whichever registry owns it
  /// (CategoryVisuals for a zone, DestinationVisuals for a rail destination).
  final String emoji;
  final List<Color> gradient;

  final VoidCallback onBack;

  /// Optional right-hand control - a filter toggle, say. Null leaves the
  /// title the extra width.
  final Widget? trailing;

  /// Whatever [trailing] actually depends on, so [shouldRebuild] can compare
  /// it. Widgets do not implement ==, so passing the widget itself would make
  /// every comparison unequal.
  final Object? trailingKey;

  /// Small-Android layout (< 360dp wide).
  final bool narrow;

  /// Already clamped by the caller to 1.0-1.35: the header grows with the
  /// user's text size, but a 3x accessibility scale cannot eat the whole
  /// screen before a single result is visible.
  final double textScale;

  /// Brief §4 of the category pass: 20-22 on a normal phone, 18-20 narrow.
  double get _titleFont => narrow ? 19.0 : 21.0;

  /// Two lines reserved at rest, so a long title wraps instead of ellipsising.
  double get _titleBlock => _titleFont * 1.12 * 2;

  static const double control = 40;

  @override
  double get maxExtent =>
      ((_titleBlock > control ? _titleBlock : control) + 16) * textScale;

  @override
  double get minExtent => (control + 12) * textScale;

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final range = maxExtent - minExtent;
    final t = range <= 0 ? 1.0 : (shrinkOffset / range).clamp(0.0, 1.0);
    final height = (maxExtent - shrinkOffset).clamp(minExtent, maxExtent);
    final backdrop = (shrinkOffset / 18.0).clamp(0.0, 1.0);
    // Past the halfway mark the row is no longer tall enough for two lines, so
    // the title drops to one. For a short title nothing visibly changes.
    final lines = t > 0.5 ? 1 : 2;
    final badge = _lerp(34, 26, t);

    return SizedBox(
      height: height,
      child: ClipRect(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: BrokaColors.bg.withOpacity(backdrop),
            border: Border(
              bottom: BorderSide(
                  color: BrokaColors.border.withOpacity(0.7 * backdrop)),
            ),
            boxShadow: backdrop <= 0
                ? null
                : [BoxShadow(
                    color: Colors.black.withOpacity(0.35 * backdrop),
                    blurRadius: 12,
                    offset: const Offset(0, 2),
                  )],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 4, 16, 6),
            child: Row(children: [
              GestureDetector(
                onTap: onBack,
                behavior: HitTestBehavior.opaque,
                child: const SizedBox(
                  width: control,
                  height: control,
                  child: Icon(Icons.arrow_back_ios_new_rounded,
                      color: BrokaColors.textHigh, size: 19),
                ),
              ),
              // The same visual the rail pill carried, so the thing you tapped
              // on Home is the thing at the top of the screen it opened.
              Container(
                width: badge,
                height: badge,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(colors: [
                    gradient.first.withOpacity(0.28),
                    gradient.last.withOpacity(0.14),
                  ]),
                  border: Border.all(color: gradient.first.withOpacity(0.5)),
                ),
                child: Center(
                    child:
                        Text(emoji, style: TextStyle(fontSize: badge * 0.46))),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ZoneGlowText(
                  title,
                  gradient: gradient,
                  fontSize: _lerp(_titleFont, _titleFont * 0.82, t),
                  maxLines: lines,
                  letterSpacing: narrow ? 0.8 : 1.1,
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 8),
                trailing!,
              ],
            ]),
          ),
        ),
      ),
    );
  }

  @override
  bool shouldRebuild(covariant CollapsingScreenHeader old) =>
      old.title != title ||
      old.emoji != emoji ||
      old.gradient != gradient ||
      old.narrow != narrow ||
      old.textScale != textScale ||
      old.trailingKey != trailingKey ||
      (old.trailing == null) != (trailing == null) ||
      old.onBack != onBack;
}

/// The square control that sits at the right of a [CollapsingScreenHeader] -
/// Home's filter button, in a shape any destination can reuse. Dark card
/// surface, subtle border, violet once it is doing something, with an optional
/// dot so "a filter is applied" survives a glance.
class BrokaHeaderButton extends StatelessWidget {
  const BrokaHeaderButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.active = false,
    this.dotGradient,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback onTap;
  final bool active;
  final List<Color>? dotGradient;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final button = GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: CollapsingScreenHeader.control,
        height: CollapsingScreenHeader.control,
        decoration: BoxDecoration(
          color: active
              ? BrokaColors.gold.withOpacity(0.2)
              : BrokaColors.bgCard.withOpacity(0.86),
          borderRadius: BorderRadius.circular(12),
          border:
              Border.all(color: active ? BrokaColors.gold : BrokaColors.border),
        ),
        child: Stack(clipBehavior: Clip.none, children: [
          Center(
            child: Icon(icon,
                size: 18,
                color: active ? BrokaColors.gold : BrokaColors.textMid),
          ),
          if (active && dotGradient != null)
            Positioned(
              top: 5,
              right: 5,
              child: Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: dotGradient!),
                  shape: BoxShape.circle,
                ),
              ),
            ),
        ]),
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

/// The empty/error state every rail destination shows: the screen's own visual
/// in a tinted ring, a headline, and one line of explanation.
///
/// Compact and centred by design - ProductGridView's sliver mode and
/// SliverFillRemaining both hand this the leftover viewport, so it sits in the
/// content area rather than near the bottom of the phone.
class BrokaEmptyState extends StatelessWidget {
  const BrokaEmptyState({
    super.key,
    required this.emoji,
    required this.gradient,
    required this.headline,
    required this.body,
    this.action,
  });

  final String emoji;
  final List<Color> gradient;
  final String headline;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 8, 32, 40),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 74,
          height: 74,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(colors: [
              gradient.first.withOpacity(0.22),
              gradient.last.withOpacity(0.10),
            ]),
            border: Border.all(color: gradient.first.withOpacity(0.45)),
          ),
          child:
              Center(child: Text(emoji, style: const TextStyle(fontSize: 32))),
        ),
        const SizedBox(height: 14),
        Text(headline,
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: BrokaColors.textHigh,
                fontSize: 14.5,
                fontWeight: FontWeight.w700)),
        const SizedBox(height: 5),
        Text(body,
            textAlign: TextAlign.center,
            style: const TextStyle(color: BrokaColors.textMid, fontSize: 12.5)),
        if (action != null) ...[
          const SizedBox(height: 16),
          action!,
        ],
      ]),
    );
  }
}
