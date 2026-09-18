// lib/features/discovery/domain/destination_visual.dart
//
// The four non-category destinations on Home's discovery rail - Trending,
// Auctions, Traders, Stores - and their one visual definition each.
//
// This is the same lesson as features/categories/domain/category_visual.dart,
// applied to the other half of the rail. Those four pills had their emoji,
// label and gradient written inline in home_screen._buildDiscoveryRail(),
// while each destination screen picked its own unrelated look: a plain
// AppBar with a bold white title and no colour at all. Tapping the pink 🔥
// "Trending" pill landed you on a screen with no trace of either. One
// registry means the pill and the screen it opens cannot disagree, and a
// fifth destination is one entry here plus one rail item, not a hunt.
//
// Categories deliberately stay in their own registry: they come from the
// backend taxonomy and are resolved by name at runtime, whereas these four
// are fixed app destinations with fixed routes. Same shape, different source
// of truth - so they are siblings rather than one merged table.
import 'package:flutter/material.dart';

import '../../../main.dart' show BrokaColors;

/// A rail destination and the identity it carries into its own screen.
class DestinationVisual {
  /// Rail pill label - short, because it sits under a 52px circle.
  final String label;

  /// Screen title. Sometimes longer than [label]: the rail says "Auctions",
  /// the screen it opens is the "Auction House".
  final String title;

  final String emoji;
  final IconData icon;
  final List<Color> gradient;

  /// Shown in the screen's empty state, under the visual. Written to say what
  /// the screen would contain, never to imply activity that isn't there.
  final String emptyHeadline;
  final String emptyBody;

  const DestinationVisual({
    required this.label,
    required this.title,
    required this.emoji,
    required this.icon,
    required this.gradient,
    required this.emptyHeadline,
    required this.emptyBody,
  });
}

class DestinationVisuals {
  const DestinationVisuals._();

  static const trending = DestinationVisual(
    label: 'Trending',
    title: 'Trending',
    emoji: '🔥',
    icon: Icons.local_fire_department_rounded,
    gradient: [BrokaColors.neonPink, Color(0xFFFF6B9D)],
    emptyHeadline: 'Nothing trending yet',
    // Trending ranks on view/interest count with time decay (see
    // trending/service.py), so this says the literal reason the list is
    // empty rather than a softened one.
    emptyBody: 'Listings show up here once people start viewing them',
  );

  static const auctions = DestinationVisual(
    label: 'Auctions',
    title: 'Auction House',
    emoji: '🔨',
    icon: Icons.gavel_rounded,
    gradient: [BrokaColors.danger, Color(0xFFFF8C42)],
    emptyHeadline: 'No auctions here yet',
    emptyBody: 'Nothing is listed under this status right now',
  );

  static const traders = DestinationVisual(
    label: 'Traders',
    title: 'Traders',
    emoji: '👤',
    icon: Icons.person_rounded,
    gradient: [BrokaColors.neonBlue, Color(0xFF60A5FA)],
    emptyHeadline: 'No traders yet',
    emptyBody: 'Verified sellers will appear here as they join',
  );

  static const stores = DestinationVisual(
    label: 'Stores',
    title: 'Stores',
    emoji: '🏬',
    icon: Icons.storefront_rounded,
    gradient: [BrokaColors.gold, BrokaColors.neonPurple],
    emptyHeadline: 'No stores yet',
    emptyBody: 'Sellers who open a storefront will show up here',
  );

  /// Rail order, which is also the order home_screen renders them in.
  static const List<DestinationVisual> all = [
    trending,
    auctions,
    traders,
    stores,
  ];
}
