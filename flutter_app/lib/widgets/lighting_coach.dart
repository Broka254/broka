// BROKA — Lighting coach for the selfie scan.
//
// Turns a raw brightness reading into one short, actionable sentence,
// presented as if Zeno were watching the viewfinder. This is a plain
// heuristic on the camera's own luminance samples — it does NOT call the
// Zeno AI service. Zeno's face is the voice, not the engine: a network round
// trip per frame would be slow, costly and offline-fragile, for advice that
// is fully determined by one number.
//
// The guidance never blocks the shutter. Telling someone their room is dim
// and then refusing to let them continue is the behaviour that made people
// abandon this screen; advice they can act on or ignore is strictly better
// than a locked button.

import 'package:flutter/material.dart';

import '../main.dart';
import 'zeno_avatar.dart';

/// How usable the current lighting is. Ordered worst to best, then over-bright.
enum LightingLevel { veryDark, dim, good, bright, blownOut }

class LightingAdvice {
  const LightingAdvice(this.level, this.headline, this.detail, this.color);

  final LightingLevel level;

  /// Two or three words, shown in bold.
  final String headline;

  /// One sentence telling the person what to physically do.
  final String detail;

  final Color color;

  /// True when the shot is likely to come out well enough to accept.
  bool get isUsable =>
      level == LightingLevel.good || level == LightingLevel.bright;
}

/// Maps a 0-255 luminance average onto advice.
///
/// The thresholds are deliberately forgiving. A typical Kenyan living room at
/// night reads around 40-70, which is perfectly workable for a face photo,
/// so anything above 45 is treated as usable and only genuine near-darkness
/// is called out as a problem.
LightingAdvice adviceForBrightness(double brightness) {
  if (brightness < 25) {
    return const LightingAdvice(
      LightingLevel.veryDark,
      'Too dark to see you',
      'Move somewhere brighter, or turn on a light and face it.',
      Color(0xFFEF4444),
    );
  }
  if (brightness < 45) {
    return const LightingAdvice(
      LightingLevel.dim,
      'A bit dim',
      'Turn to face a window or lamp — you can still take the photo.',
      Color(0xFFF59E0B),
    );
  }
  if (brightness > 225) {
    return const LightingAdvice(
      LightingLevel.blownOut,
      'Too bright',
      'Step out of the direct light, or turn slightly away from it.',
      Color(0xFFF59E0B),
    );
  }
  if (brightness > 170) {
    return const LightingAdvice(
      LightingLevel.bright,
      'Nice and bright',
      'Hold steady and look straight at the camera.',
      BrokaColors.success,
    );
  }
  return const LightingAdvice(
    LightingLevel.good,
    'Lighting looks good',
    'Hold steady and look straight at the camera.',
    BrokaColors.success,
  );
}

/// The on-screen coach card: Zeno's face, a headline, and one instruction.
class LightingCoachCard extends StatelessWidget {
  const LightingCoachCard({super.key, required this.advice});

  final LightingAdvice advice;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 260),
      padding: const EdgeInsets.fromLTRB(12, 12, 16, 12),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.72),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: advice.color.withOpacity(0.55), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: advice.color.withOpacity(0.18),
            blurRadius: 18,
            spreadRadius: -4,
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const ZenoAvatar(size: 36, glow: true),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        advice.headline,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: advice.color,
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    if (advice.isUsable) ...[
                      const SizedBox(width: 6),
                      Icon(Icons.check_circle_rounded,
                          color: advice.color, size: 15),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  advice.detail,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
