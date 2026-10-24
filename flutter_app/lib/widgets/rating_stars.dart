// The app's one five-star renderer.
//
// Two different ratings meet on a store page, and they do not share a
// scale: a buyer review is 1-5 stars, while a store's composite score is
// 0-10 (backend stores/rating.py). Passing a 0-10 score straight to a
// five-star row drew 6.5/10 as five filled stars. Every caller converts
// through starsFromStoreScore first, and RatingStars only ever accepts
// star units - so the mistake cannot be made quietly again.
import 'package:flutter/material.dart';

import '../main.dart';

/// The top of the buyer-review scale. A composite store score is 0-10 and
/// is not this.
const double buyerRatingMax = 5;

/// A store's 0-10 score, in stars: 6.5/10 is 3.25/5, never 5/5.
double starsFromStoreScore(double score) {
  if (score.isNaN) return 0;
  return (score.clamp(0, 10) / 2).toDouble();
}

/// A buyer average as stars, clamped to the 1-5 scale it came from.
double buyerStars(double average) {
  if (average.isNaN) return 0;
  return average.clamp(0, buyerRatingMax).toDouble();
}

/// [value] in star units, 0-5, drawn as five stars with a fractional fill.
///
/// The fill is exact rather than rounded to the nearest half: 3.25 stars is
/// a quarter of the way through the fourth. The numeric value beside it
/// remains the caller's, so a 4.3 average reads "4.3" and is drawn as 4.3.
class RatingStars extends StatelessWidget {
  const RatingStars({
    super.key,
    required this.value,
    this.size = 13,
    this.color = BrokaColors.gold,
    this.semanticLabel,
  });

  /// Star units, 0-5. For a 0-10 store score use [starsFromStoreScore].
  final double value;
  final double size;
  final Color color;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final stars = buyerStars(value);
    final fraction = stars / buyerRatingMax;
    return Semantics(
      label: semanticLabel ?? '${stars.toStringAsFixed(1)} out of 5 stars',
      child: ExcludeSemantics(
        child: SizedBox(
          width: size * buyerRatingMax,
          height: size,
          child: Stack(children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < buyerRatingMax; i++)
                  Icon(Icons.star_outline_rounded,
                      size: size, color: color.withOpacity(0.35)),
              ],
            ),
            // The filled row is the full width; the alignment box is only
            // the filled fraction of it, so ClipRect cuts the row there.
            // This is what makes a fractional star fractional rather than
            // rounded up to the next whole one.
            ClipRect(
              child: Align(
                alignment: Alignment.centerLeft,
                widthFactor: fraction,
                heightFactor: 1,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < buyerRatingMax; i++)
                      Icon(Icons.star_rounded, size: size, color: color),
                  ],
                ),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
