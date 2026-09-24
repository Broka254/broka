// A store's category is one of BROKA's top-level categories (the home
// screen's category rail). Sellers' signup business categories come from a
// different, older list; this maps those across for pre-filling, exactly
// as backend/api/domains/stores/categories.py does on the server.
import '../../categories/domain/category_visual.dart';

class StoreCategories {
  StoreCategories._();

  /// The canonical category names, in BROKA's order.
  static List<String> get all =>
      CategoryVisuals.canonical.map((c) => c.categoryName).toList(growable: false);

  static const Map<String, String> _legacy = {
    'wholesale': 'Business & Industrial',
    'clothing & fashion': 'Fashion',
    'furniture': 'Home & Furniture',
    'appliances': 'Home & Furniture',
    'automotive': 'Vehicles',
    'building materials': 'Construction',
    'phones & accessories': 'Electronics',
    'food & beverages': 'Other',
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
