// A store's category is one of BROKA's top-level categories (the home
// screen's category rail). Sellers' signup business categories come from a
// different, older list; this maps those across for pre-filling, exactly
// as backend/api/domains/stores/categories.py does on the server.
//
// Phase 3: a store may sell across several categories, and a store with
// two or more is listed under "Wholesale and General" - a directory facet,
// not a taxonomy category (the backend's CANONICAL_CATEGORIES is
// untouched). [rail] is what the store directory shows; [all] stays the
// canonical list the setup wizard's chips use.
import 'package:flutter/material.dart';

import '../../../main.dart' show BrokaColors;
import '../../categories/domain/category_visual.dart';

class StoreCategories {
  StoreCategories._();

  /// The directory facet for a store that sells across several
  /// categories. Spelled exactly as the backend compares it
  /// (api/domains/stores/categories.py: is_wholesale_facet).
  static const String wholesale = 'Wholesale and General';

  /// The canonical category names, in BROKA's order.
  static List<String> get all =>
      CategoryVisuals.canonical.map((c) => c.categoryName).toList(growable: false);

  /// The store directory rail's order: the categories buyers shop first,
  /// then the multi-category facet fourth, then the rest of the taxonomy.
  /// A presentation order only - [all] and the backend's taxonomy (and
  /// every home-screen rail) are unchanged.
  static const List<String> rail = <String>[
    'Electronics',
    'Fashion',
    'Home & Furniture',
    wholesale,
    'Agriculture',
    'Food & Beverages',
    'Beauty & Personal Care',
    'Property',
    'Automobiles',
    'Land',
    'Health & Medical',
    'Baby & Kids',
    'Gaming',
    'Construction',
    'Sports & Fitness',
    'Business & Industrial',
    'Books & Education',
    'Music & Instruments',
    'Arts & Crafts',
    'Pets & Animals',
    'Services',
    'Other',
  ];

  /// Listing categories not sold through an online store: dealer/agent
  /// trades (Property, Automobiles, Land), booked Services, and the
  /// catch-all Other. Mirrors backend/api/domains/stores/categories.py
  /// ONLINE_STORE_EXCLUDED - the rows stay stored, only browsing hides them.
  static const Set<String> onlineExcluded = {
    'Property',
    'Automobiles',
    'Land',
    'Services',
    'Other',
  };

  /// The directory rail without the excluded online-store trades, for the
  /// online-store directory. Dealer/agent shops keep their own screens.
  static List<String> get onlineRail =>
      rail.where((name) => !onlineExcluded.contains(name)).toList(growable: false);

  /// What the setup wizard may offer as a choice: [onlineRail] without
  /// the Wholesale facet. The facet is derived from selling in two or
  /// more categories, never chosen - and it is not a canonical category,
  /// so a store "choosing" it could not even be created.
  static List<String> get onlineChoices =>
      onlineRail.where((name) => !isWholesaleFacet(name)).toList(growable: false);

  /// A store catalogue rail without the excluded trades (store_home's pills,
  /// the web CategoryPills, and the backend list_categories for goods).
  static bool isOnlineListingCategory(String? name) =>
      name != null && !onlineExcluded.contains(name);

  /// The "Wholesale and General" card's visual. It lives here, not in
  /// CategoryVisuals: that table mirrors the backend seed exactly
  /// (test/category_visual_test.dart holds it to it), and this facet is
  /// not a category the backend seeds.
  static const CategoryVisual wholesaleVisual = CategoryVisual(
    categoryName: wholesale,
    // The facet has no Zone screen of its own (its card opens the Wholesale
    // catalog, not a category feed), but every visual carries a label so a
    // caller can never be handed a blank title.
    zoneTitle: 'The Wholesale Floor',
    emoji: '🏬',
    icon: Icons.storefront_rounded,
    gradient: [BrokaColors.neonPurple, BrokaColors.neonCyan],
    assetPath: 'assets/category_art/business-and-industrial/wholesale-bulk-stock.webp',
  );

  /// Whether [value] names the multi-category facet, not a category.
  static bool isWholesaleFacet(String? value) =>
      (value ?? '').trim().toLowerCase() == wholesale.toLowerCase();

  /// The visual for a rail entry: canonical categories resolve as
  /// everywhere else in the app; the facet card gets its own.
  static CategoryVisual visualFor(String name) =>
      isWholesaleFacet(name) ? wholesaleVisual : CategoryVisuals.resolve(name);

  static const Map<String, String> _legacy = {
    'wholesale': 'Business & Industrial',
    'clothing & fashion': 'Fashion',
    'furniture': 'Home & Furniture',
    'appliances': 'Home & Furniture',
    'automotive': 'Automobiles',
    // Renamed 2026-09-25 (see CategoryVisuals._aliases).
    'vehicles': 'Automobiles',
    'building materials': 'Construction',
    'phones & accessories': 'Electronics',
    'general merchandise': 'Other',
    'supermarket': 'Other',
  };

  /// The canonical category for [value], or null when [value] is empty.
  /// Unknown text maps to "Other".
  static String? fromAny(String? value) {
    final key = (value ?? '').trim().toLowerCase();
    if (key.isEmpty) return null;
    for (final name in all) {
      if (name.toLowerCase() == key) return name;
    }
    return _legacy[key] ?? 'Other';
  }
}
