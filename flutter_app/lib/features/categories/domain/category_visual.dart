// lib/features/categories/domain/category_visual.dart
//
// ONE visual definition per canonical category, for the whole app.
//
// Before this file there were six independent category-visual tables:
// home_screen's _categoryEmojiMap (26 entries), BrokaColors.zoneGradients
// (27 entries), and four near-identical four-case switches in
// product_card.dart, models/listing.dart, boost_screen.dart and
// inbox_screen.dart. The four switches only knew Vehicles, Property,
// Electronics and Livestock, so eleven of the backend's then sixteen top-level
// categories rendered as a generic 📦 everywhere except Home - the exact
// drift the category brief describes. Adding a seventeenth category to
// backend/api/domains/categories/seed.py meant finding and editing six
// places, and nothing failed if you missed one.
//
// Resolution is by NAME, never by list position. A category's visual is
// looked up on `name.toLowerCase().trim()`, so the UI adapts to whatever
// the backend returns from /categories rather than assuming a count or an
// order. An unknown name falls back to the "Other" visual instead of a
// broken/blank one, which also means a category added to the backend before
// this table is updated still renders sensibly.
//
// The canonical taxonomy below is a mirror of CANONICAL_CATEGORIES in
// backend/api/domains/categories/seed.py, and the backend is the source of
// truth. test/category_visual_test.dart parses that Python file directly and
// fails if the two ever diverge, so this mirror cannot rot silently.
//
// [assetPath] is the category's card artwork (2026-10-08): the same pictures
// the website's category pages use, bundled under assets/category_art/ so a
// card is drawn the moment Home opens, offline too. Home's category cards,
// the Zone's hero and the sell wizard's category rows read it from here.
// "Other" has none on purpose - the website borrows the Services picture
// for it, and two identical photos side by side read as the same category -
// so it is drawn from its gradient and emoji instead. Subcategory artwork
// is keyed by parent and name in subcategory_visual.dart.
import 'package:flutter/material.dart';

import '../../../main.dart' show BrokaColors;

/// Everything the UI needs to render one category, resolved by name.
class CategoryVisual {
  /// Canonical display name, spelled exactly as the backend seeds it.
  final String categoryName;

  /// Shown beside the name: the header badge, a card's corner, the
  /// fallback when there is no [assetPath].
  final String emoji;

  /// Vector equivalent, for surfaces where an emoji reads as informal (a
  /// dense list row, a form field, a monochrome chip).
  final IconData icon;

  /// The category's personality colours. Used for the Zone's radial wash,
  /// the Home rail's circle ring, and selected subcategory chips - always as
  /// an accent over BROKA's own near-black/violet identity, never as a
  /// wholesale re-theme of the screen.
  final List<Color> gradient;

  /// The card artwork (an asset path), or null for a category drawn from its
  /// gradient alone ("Other").
  final String? assetPath;

  const CategoryVisual({
    required this.categoryName,
    required this.emoji,
    required this.icon,
    required this.gradient,
    this.assetPath,
  });

  /// For screen readers and tooltips.
  String get semanticLabel => categoryName;
}

/// Name-keyed registry for every category visual in the app.
///
/// Call [resolve] from anywhere that needs a category's emoji, icon or
/// gradient. Do not add a second table.
class CategoryVisuals {
  const CategoryVisuals._();

  /// The twenty-one top-level categories, in the backend's own seed order
  /// (which is also the order GET /categories returns them in).
  static const List<CategoryVisual> canonical = <CategoryVisual>[
    // Was "Vehicles" until the 2026-09-25 listing overhaul (see _aliases).
    CategoryVisual(
      categoryName: 'Automobiles',
      emoji: '🚗',
      icon: Icons.directions_car_rounded,
      gradient: [BrokaColors.zoneOrange, BrokaColors.neonPurple],
      assetPath: 'assets/category_art/automobiles.webp',
    ),
    CategoryVisual(
      categoryName: 'Property',
      emoji: '🏠',
      icon: Icons.home_work_rounded,
      gradient: [BrokaColors.neonBlue, BrokaColors.neonGreen],
      assetPath: 'assets/category_art/property.webp',
    ),
    CategoryVisual(
      categoryName: 'Land',
      emoji: '🏞️',
      icon: Icons.landscape_rounded,
      gradient: [BrokaColors.zoneAmber, BrokaColors.neonGreen],
      assetPath: 'assets/category_art/land.webp',
    ),
    CategoryVisual(
      categoryName: 'Electronics',
      emoji: '📱',
      icon: Icons.smartphone_rounded,
      gradient: [BrokaColors.neonCyan, BrokaColors.neonBlue],
      assetPath: 'assets/category_art/electronics.webp',
    ),
    CategoryVisual(
      categoryName: 'Fashion',
      emoji: '👗',
      icon: Icons.checkroom_rounded,
      gradient: [BrokaColors.neonPink, BrokaColors.gold],
      assetPath: 'assets/category_art/fashion.webp',
    ),
    CategoryVisual(
      categoryName: 'Agriculture',
      emoji: '🌾',
      icon: Icons.agriculture_rounded,
      gradient: [BrokaColors.neonGreen, BrokaColors.zoneAmber],
      assetPath: 'assets/category_art/agriculture.webp',
    ),
    CategoryVisual(
      categoryName: 'Home & Furniture',
      emoji: '🛋️',
      icon: Icons.chair_rounded,
      gradient: [BrokaColors.zoneAmber, BrokaColors.gold],
      assetPath: 'assets/category_art/home-and-furniture.webp',
    ),
    CategoryVisual(
      categoryName: 'Food & Beverages',
      emoji: '🍽️',
      icon: Icons.restaurant_rounded,
      gradient: [BrokaColors.zoneOrange, BrokaColors.zoneAmber],
      assetPath: 'assets/category_art/food-and-beverages.webp',
    ),
    CategoryVisual(
      categoryName: 'Construction',
      emoji: '🏗️',
      icon: Icons.construction_rounded,
      gradient: [BrokaColors.zoneOrange, BrokaColors.warning],
      assetPath: 'assets/category_art/construction.webp',
    ),
    CategoryVisual(
      categoryName: 'Beauty & Personal Care',
      emoji: '💄',
      icon: Icons.spa_rounded,
      gradient: [BrokaColors.neonPink, BrokaColors.zoneAmber],
      assetPath: 'assets/category_art/beauty-and-personal-care.webp',
    ),
    CategoryVisual(
      categoryName: 'Health & Medical',
      emoji: '🏥',
      icon: Icons.medical_services_rounded,
      gradient: [BrokaColors.neonCyan, BrokaColors.neonGreen],
      assetPath: 'assets/category_art/health-and-medical.webp',
    ),
    CategoryVisual(
      categoryName: 'Baby & Kids',
      emoji: '🧸',
      icon: Icons.child_friendly_rounded,
      gradient: [BrokaColors.neonPink, BrokaColors.neonCyan],
      assetPath: 'assets/category_art/baby-and-kids.webp',
    ),
    // Top-level Gaming is NOT the same thing as Electronics -> Gaming, and
    // the backend defines both on purpose. Nothing here collapses them: this
    // table only ever describes top-level names, and a subcategory is
    // identified by its own id and parent_id everywhere it is used.
    CategoryVisual(
      categoryName: 'Gaming',
      emoji: '🎮',
      icon: Icons.sports_esports_rounded,
      gradient: [BrokaColors.neonPurple, BrokaColors.neonPink],
      assetPath: 'assets/category_art/gaming.webp',
    ),
    CategoryVisual(
      categoryName: 'Sports & Fitness',
      emoji: '⚽',
      icon: Icons.fitness_center_rounded,
      gradient: [BrokaColors.neonGreen, BrokaColors.neonBlue],
      assetPath: 'assets/category_art/sports-and-fitness.webp',
    ),
    CategoryVisual(
      categoryName: 'Books & Education',
      emoji: '📚',
      icon: Icons.menu_book_rounded,
      gradient: [BrokaColors.gold, BrokaColors.neonBlue],
      assetPath: 'assets/category_art/books-and-education.webp',
    ),
    CategoryVisual(
      categoryName: 'Music & Instruments',
      emoji: '🎸',
      icon: Icons.music_note_rounded,
      gradient: [BrokaColors.neonPink, BrokaColors.neonPurple],
      assetPath: 'assets/category_art/music-and-instruments.webp',
    ),
    CategoryVisual(
      categoryName: 'Arts & Crafts',
      emoji: '🎨',
      icon: Icons.palette_rounded,
      gradient: [BrokaColors.neonPurple, BrokaColors.zoneAmber],
      assetPath: 'assets/category_art/arts-and-crafts.webp',
    ),
    CategoryVisual(
      categoryName: 'Business & Industrial',
      emoji: '🏭',
      icon: Icons.factory_rounded,
      gradient: [BrokaColors.neonBlue, BrokaColors.warning],
      assetPath: 'assets/category_art/business-and-industrial.webp',
    ),
    CategoryVisual(
      categoryName: 'Pets & Animals',
      emoji: '🐾',
      icon: Icons.pets_rounded,
      gradient: [BrokaColors.neonGreen, BrokaColors.neonPink],
      assetPath: 'assets/category_art/pets-and-animals.webp',
    ),
    CategoryVisual(
      categoryName: 'Services',
      emoji: '🛠️',
      icon: Icons.handyman_rounded,
      gradient: [BrokaColors.neonCyan, BrokaColors.gold],
      assetPath: 'assets/category_art/services.webp',
    ),
    // "Other" carries plain BROKA brand identity rather than a colour of its
    // own - it is a real catch-all, and inventing a theme for it would make
    // it look like a category with a personality when it is the absence of
    // one. It is also what an unrecognised name resolves to.
    CategoryVisual(
      categoryName: 'Other',
      emoji: '🛍️',
      icon: Icons.shopping_bag_rounded,
      gradient: BrokaColors.brandGradient,
    ),
  ];

  /// Free-text category values that predate the canonical taxonomy.
  ///
  /// Listings created before the taxonomy migration still carry strings like
  /// "Livestock" or "Vehicles" in their `category` column, and
  /// lib/models/listing.dart hands those straight to this resolver. Mapping
  /// them onto their canonical successor keeps an old listing showing a real
  /// icon instead of the catch-all. migrate_categories_from_freetext.py is
  /// what eventually retires these; until every deployment has run it, they
  /// are live data.
  static const Map<String, String> _aliases = <String, String>{
    // Renamed in place on 2026-09-25; drafts and older listings still say it.
    'vehicles': 'Automobiles',
    'cars': 'Automobiles',
    'phones': 'Electronics',
    'computers': 'Electronics',
    'laptops': 'Electronics',
    'home appliances': 'Home & Furniture',
    'furniture': 'Home & Furniture',
    'clothing': 'Fashion',
    'mtumba': 'Fashion',
    'livestock': 'Agriculture',
    'farm equipment': 'Agriculture',
    'food': 'Food & Beverages',
    'beauty': 'Beauty & Personal Care',
    'health': 'Health & Medical',
    'baby': 'Baby & Kids',
    'sports': 'Sports & Fitness',
    'books': 'Books & Education',
    'musical instruments': 'Music & Instruments',
    'music': 'Music & Instruments',
    'art': 'Arts & Crafts',
  };

  static final Map<String, CategoryVisual> _byKey = <String, CategoryVisual>{
    for (final visual in canonical) _key(visual.categoryName): visual,
    for (final entry in _aliases.entries)
      _key(entry.key): canonical.firstWhere(
          (v) => v.categoryName == entry.value),
  };

  static String _key(String name) => name.toLowerCase().trim();

  /// What an unknown or missing category name renders as.
  static CategoryVisual get fallback => _byKey['other']!;

  /// The visual for [categoryName], matched case- and whitespace-insensitively.
  ///
  /// Never returns null and never throws: a name this table has not heard of
  /// - a new backend category, a typo, a legacy free-text value - resolves to
  /// [fallback] so the UI degrades to "generic marketplace item" instead of
  /// an empty box.
  static CategoryVisual resolve(String? categoryName) {
    if (categoryName == null) return fallback;
    return _byKey[_key(categoryName)] ?? fallback;
  }

  /// Convenience accessors, so a call site that wants one field does not have
  /// to spell out the resolve.
  static String emojiFor(String? categoryName) => resolve(categoryName).emoji;

  static IconData iconFor(String? categoryName) => resolve(categoryName).icon;

  static List<Color> gradientFor(String? categoryName) =>
      resolve(categoryName).gradient;
}
