// lib/widgets/zeno_avatar.dart
//
// The approved Zeno visual (mockup-actualization spec §13, Home Redesign
// Guide §10, Design v2 §14: "replace the generic robot icon with the
// approved Zeno visual"). One widget, two source images, so every
// Zeno touchpoint in the app stays visually identical and there's a
// single place to swap the art in future instead of N call sites.
//
// - ZenoAvatarStyle.icon: tight head crop (assets/images/zeno_icon.png),
//   clipped to a circle. For anything small/round - bottom nav, chat and
//   broker-message avatars, quick-access cards.
// - ZenoAvatarStyle.hero: the full character + neon ring
//   (assets/images/zeno_full.png), unclipped. For the large Home Buying
//   Agent card and anywhere else Zeno is the visual centerpiece.
//
// A raster image can't be recoloured the way Icon(color: ...) can, so
// "selected" state here is opacity + an optional glow ring instead of a
// colour swap - the same "dim when inactive" read, different mechanism.
import 'package:flutter/material.dart';
import '../main.dart';

enum ZenoAvatarStyle { icon, hero }

class ZenoAvatar extends StatelessWidget {
  final double size;
  final ZenoAvatarStyle style;
  final bool selected;
  final bool glow;

  const ZenoAvatar({
    super.key,
    this.size = 32,
    this.style = ZenoAvatarStyle.icon,
    this.selected = true,
    this.glow = false,
  });

  @override
  Widget build(BuildContext context) {
    final asset = style == ZenoAvatarStyle.hero
        ? 'assets/images/zeno_full.png'
        : 'assets/images/zeno_icon.png';

    Widget image = Image.asset(asset, width: size, height: size, fit: BoxFit.cover);

    if (style == ZenoAvatarStyle.icon) {
      image = ClipOval(child: image);
    } else {
      image = ClipRRect(borderRadius: BorderRadius.circular(size * 0.12), child: image);
    }

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 150),
      opacity: selected ? 1.0 : 0.55,
      child: Container(
        width: size,
        height: size,
        decoration: glow
            ? BoxDecoration(
                shape: style == ZenoAvatarStyle.icon ? BoxShape.circle : BoxShape.rectangle,
                borderRadius: style == ZenoAvatarStyle.hero ? BorderRadius.circular(size * 0.12) : null,
                boxShadow: [
                  BoxShadow(color: BrokaColors.neonBlue.withOpacity(0.45), blurRadius: size * 0.25, spreadRadius: size * 0.02),
                ],
              )
            : null,
        child: image,
      ),
    );
  }
}
