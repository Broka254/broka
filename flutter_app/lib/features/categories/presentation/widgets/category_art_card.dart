// lib/features/categories/presentation/widgets/category_art_card.dart
//
// The photo card every category and subcategory is drawn as (2026-10-08):
// Home's category row, a Zone's types of item, and both directories. It
// replaced the emoji circles on Home, after the website's category cards -
// a picture says "phones" faster than a 📱 says "electronics", and a type
// of item ("Phones") needs a face of its own now that it has a screen of
// its own.
//
// The artwork is dark, with its subject to the right and empty space on the
// left (it was made for the website's heroes, title on the left), so the
// card crops toward the right and writes its name bottom-left over a shade.
// A card with no picture ("Other", a destination like Trending) is drawn
// from its gradient and a large emoji instead, in the same frame.
import 'package:flutter/material.dart';

import '../../../../main.dart';

class CategoryArtCard extends StatelessWidget {
  const CategoryArtCard({
    super.key,
    required this.label,
    required this.emoji,
    required this.gradient,
    required this.onTap,
    this.assetPath,
    this.width,
    this.height,
    this.labelSize = 12.5,
    this.caption,
  });

  final String label;
  final String emoji;
  final List<Color> gradient;
  final VoidCallback onTap;

  /// The card's picture, or null to draw it from [gradient] and [emoji].
  final String? assetPath;

  /// Fixed size in a row; null to fill the cell of a grid.
  final double? width;
  final double? height;
  final double labelSize;

  /// A second, smaller line under the label ("12 types").
  final String? caption;

  static const double radius = 16;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            color: BrokaColors.bgCard,
            border: Border.all(color: gradient.first.withOpacity(0.45)),
            boxShadow: [
              BoxShadow(color: gradient.first.withOpacity(0.16), blurRadius: 10, offset: const Offset(0, 3)),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(radius - 1),
            child: LayoutBuilder(builder: (context, box) {
              final noArt = assetPath == null;
              return Stack(fit: StackFit.expand, children: [
                if (noArt)
                  _GradientArt(emoji: emoji, gradient: gradient)
                else
                  Image.asset(
                    assetPath!,
                    fit: BoxFit.cover,
                    alignment: const Alignment(0.45, 0),
                    // Decoded at the size it is shown, not the file's 640px:
                    // a screen of these is otherwise tens of MB of bitmaps.
                    cacheWidth: artDecodeWidth(context, box.maxWidth, box.maxHeight),
                    gaplessPlayback: true,
                    errorBuilder: (_, __, ___) => _GradientArt(emoji: emoji, gradient: gradient),
                  ),
                // The category's colour, low, from the corner the name sits in.
                DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomLeft,
                      end: Alignment.topRight,
                      colors: [gradient.first.withOpacity(0.32), Colors.transparent],
                      stops: const [0.0, 0.7],
                    ),
                  ),
                ),
                // What keeps a white name readable over any picture.
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [Color(0xE6000000), Color(0x33000000), Color(0x00000000)],
                      stops: [0.0, 0.58, 1.0],
                    ),
                  ),
                ),
                if (!noArt)
                  Positioned(
                    top: 7,
                    left: 7,
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: Colors.black.withOpacity(0.45),
                        border: Border.all(color: gradient.first.withOpacity(0.6)),
                      ),
                      alignment: Alignment.center,
                      child: Text(emoji, style: const TextStyle(fontSize: 12)),
                    ),
                  ),
                Positioned(
                  left: 10,
                  right: 10,
                  bottom: 9,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: labelSize,
                          height: 1.15,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.1,
                          shadows: const [Shadow(color: Color(0xCC000000), blurRadius: 6)],
                        ),
                      ),
                      if (caption != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          caption!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.78),
                            fontSize: labelSize * 0.82,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ]);
            }),
          ),
        ),
      ),
    );
  }
}

/// How wide to decode a card picture shown [width] x [height] with
/// BoxFit.cover: wide enough to fill the box's height too, since a 16:9
/// category picture in a squarer card is cropped at the sides (decoding to
/// the box's width alone left it a quarter too small, and soft). Never past
/// the files' own 640px; null when the box is unbounded.
int? artDecodeWidth(BuildContext context, double width, double height) {
  if (!width.isFinite || !height.isFinite) return null;
  final cover = width > height * 16 / 9 ? width : height * 16 / 9;
  return (cover * MediaQuery.devicePixelRatioOf(context)).clamp(1, 640).round();
}

/// A card without a picture: its gradient, deep, with a large emoji where
/// the picture's subject would be.
class _GradientArt extends StatelessWidget {
  const _GradientArt({required this.emoji, required this.gradient});
  final String emoji;
  final List<Color> gradient;

  @override
  Widget build(BuildContext context) => DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topRight,
            end: Alignment.bottomLeft,
            colors: [gradient.first.withOpacity(0.75), gradient.last.withOpacity(0.35), BrokaColors.bgCard],
            stops: const [0.0, 0.55, 1.0],
          ),
        ),
        child: Align(
          alignment: const Alignment(0.6, -0.35),
          child: Text(emoji, style: const TextStyle(fontSize: 30)),
        ),
      );
}
