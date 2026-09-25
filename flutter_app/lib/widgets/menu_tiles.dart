// The building blocks of the Menu and Settings screens: a section label, a
// card that groups rows, and the row itself.
//
// One set, so the Menu, Settings and anything added under them later read as
// one surface - Profile used to build a slightly different card for every
// kind of row (info, toggle, link, language), five gradients in all.
import 'package:flutter/material.dart';

import '../main.dart';

/// Upper-cased, letter-spaced heading above a [MenuGroup].
class MenuSectionLabel extends StatelessWidget {
  const MenuSectionLabel(this.label, {super.key, this.trailing});

  final String label;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 22, 4, 8),
        child: Row(children: [
          Expanded(
            child: Text(label.toUpperCase(),
                style: const TextStyle(
                    // textMid, not textLow: at 1.6:1 the old labels were the
                    // one thing on the screen that could not be read.
                    color: BrokaColors.textMid,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.3)),
          ),
          if (trailing != null) trailing!,
        ]),
      );
}

/// A card of rows separated by hairlines. Opaque enough that the
/// constellation shows in the gaps between groups, not through the text.
class MenuGroup extends StatelessWidget {
  const MenuGroup({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(const Divider(height: 1, thickness: 1, indent: 60, color: BrokaColors.border));
      }
      rows.add(children[i]);
    }
    return Container(
      decoration: BoxDecoration(
        color: BrokaColors.bgCard.withOpacity(0.9),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: BrokaColors.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        type: MaterialType.transparency,
        child: Column(mainAxisSize: MainAxisSize.min, children: rows),
      ),
    );
  }
}

/// One row: a tinted icon, a title, an optional subtitle, and a trailing
/// control (a chevron when it navigates and nothing else is given).
class MenuTile extends StatelessWidget {
  const MenuTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    this.trailing,
    this.tint = BrokaColors.gold,
    this.destructive = false,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;
  final Color tint;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final color = destructive ? BrokaColors.danger : tint;
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        // 56dp: a comfortable tap target even for a one-line row.
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: color.withOpacity(0.14),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: color, size: 19),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(title,
                      style: TextStyle(
                          color: destructive ? BrokaColors.danger : BrokaColors.textHigh,
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600)),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(subtitle!,
                        style: const TextStyle(color: BrokaColors.textMid, fontSize: 12, height: 1.3)),
                  ],
                ],
              ),
            ),
            if (trailing != null)
              trailing!
            else if (onTap != null)
              const Icon(Icons.chevron_right_rounded, color: BrokaColors.textMid, size: 20),
          ]),
        ),
      ),
    );
  }
}

/// The small rounded status label used on the Menu's cards ("Open",
/// "Paused", "Verified").
class MenuPill extends StatelessWidget {
  const MenuPill(this.label, {super.key, required this.color, this.icon});

  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withOpacity(0.45)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: color),
            const SizedBox(width: 3),
          ],
          Text(label,
              style: TextStyle(color: color, fontSize: 10.5, fontWeight: FontWeight.w700)),
        ]),
      );
}
