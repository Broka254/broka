// "KES 3,500 per bag": what one unit of a listing's price is, and how many
// of them the seller has.
//
// A farmer with 100 bags of maize used to have one number for the price
// and nowhere to say "per bag" - so either the listing said KES 3,500 for
// what looked like one item, or KES 350,000 for a lot most buyers only want
// part of. The price stays a number (escrow, sorting and filters need one);
// the unit rides alongside it (Listing.price_unit on the server, cleaned the
// same way as [PriceUnits.clean]).

class PriceUnits {
  PriceUnits._();

  static const maxLength = 24;

  // Most likely units first. Keyed by subcategory name, then category name.
  static const Map<String, List<String>> _bySubcategory = {
    'Cereals & Grains': ['90kg bag', '50kg bag', 'kg', 'tonne'],
    'Fruits & Vegetables': ['kg', 'crate', 'sack', 'bunch', 'piece'],
    'Crops & Produce': ['kg', 'bag', 'sack', 'tonne'],
    'Livestock': ['head'],
    'Poultry': ['bird', 'tray'],
    'Dairy & Eggs': ['tray', 'litre', 'kg'],
    'Seeds': ['packet', 'kg'],
    'Seedlings & Nursery': ['seedling', 'tray'],
    'Animal Feed': ['bag', 'kg'],
    'Fertilizers & Agrochemicals': ['bag', 'litre', 'kg'],
    'Beekeeping & Honey': ['kg', 'litre', 'jar'],
    'Mtumba (Second-hand Clothes)': ['piece', 'bundle', 'bale'],
    'Fabrics & Textiles': ['metre', 'piece'],
    'Land for Lease': ['acre per season', 'acre per year'],
    'Rentals': ['month'],
    'Short Stays & Airbnb': ['night'],
    'Commercial Property': ['month', 'sq ft'],
    'Offices': ['month', 'sq ft'],
    'Shops': ['month'],
    'Warehouses & Godowns': ['month', 'sq ft'],
    'Building Materials': ['bag', 'tonne', 'lorry', 'piece'],
    'Roofing Materials': ['sheet', 'piece'],
    'Steel & Metal Works': ['piece', 'kg', 'tonne'],
    'Tiles & Flooring': ['box', 'sq metre', 'piece'],
    'Paint & Hardware': ['litre', 'bucket', 'piece'],
    'Meat & Fish': ['kg'],
    'Ready Meals & Catering': ['plate', 'person'],
    'Wholesale & Bulk Stock': ['carton', 'dozen', 'bale', 'piece'],
  };

  static const Map<String, List<String>> _byCategory = {
    'Land': ['plot', 'acre', 'hectare'],
    'Agriculture': ['kg', 'bag', 'piece'],
    'Food & Beverages': ['kg', 'packet', 'piece', 'litre', 'carton'],
    'Construction': ['piece', 'bag'],
    'Services': ['hour', 'day', 'job', 'session'],
    'Fashion': ['piece', 'pair'],
    'Business & Industrial': ['piece', 'carton'],
  };

  /// Unit suggestions for this category, most likely first. The wizard
  /// always offers "the whole item" before these, and a custom unit after.
  static List<String> suggestionsFor(String category, String? subcategory) =>
      _bySubcategory[subcategory] ?? _byCategory[category] ?? const ['piece'];

  static const _wholeItem = {'item', 'each', 'unit', 'whole', 'total', 'lot'};
  static final _allowed = RegExp(r'^[a-z0-9][a-z0-9 .()/x×-]*$');

  /// "per Bag" -> "bag"; "item" -> null (the whole listing). The same rule
  /// the server applies, so what the seller sees previewed is what's saved.
  static String? clean(String? raw) {
    var unit = (raw ?? '').trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
    for (final prefix in const ['per ', '/']) {
      if (unit.startsWith(prefix)) unit = unit.substring(prefix.length).trim();
    }
    if (unit.isEmpty || _wholeItem.contains(unit)) return null;
    return unit;
  }

  /// Why [raw] can't be a unit, or null when it can.
  static String? problem(String raw) {
    final unit = clean(raw);
    if (unit == null) return null;
    if (unit.length > maxLength || !_allowed.hasMatch(unit)) {
      return 'Use a short unit like "bag", "kg" or "piece".';
    }
    return null;
  }

  static const _invariant = {'kg', 'g', 'head', 'ha', 'm²', 'ft²', 'sq ft', 'sq metre', 'sheep', 'fish'};

  /// "bag" -> "bags", "90kg bag" -> "90kg bags", "box" -> "boxes",
  /// "acre per year" -> "acres per year", "kg" -> "kg".
  static String plural(String unit) {
    final parts = unit.split(' per ');
    final head = parts.first;
    if (_invariant.contains(head)) return unit;
    final words = head.split(' ');
    final last = words.last;
    String pluralLast;
    if (last.isEmpty || _invariant.contains(last)) {
      pluralLast = last;
    } else if (RegExp(r'(s|sh|ch|x|z)$').hasMatch(last)) {
      pluralLast = '${last}es';
    } else if (RegExp(r'[^aeiou]y$').hasMatch(last)) {
      pluralLast = '${last.substring(0, last.length - 1)}ies';
    } else {
      pluralLast = '${last}s';
    }
    words[words.length - 1] = pluralLast;
    return [words.join(' '), ...parts.skip(1)].join(' per ');
  }

  /// "100 bags", "1 bag", "12 pieces"; "3 items" when there is no unit.
  static String quantity(int count, String? unit) {
    final grouped = count.toString().replaceAllMapped(
        RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},');
    final u = unit ?? 'item';
    return '$grouped ${count == 1 ? u : plural(u)}';
  }

  /// "KES 3,500 / bag", or the price alone when it's for the whole item.
  static String priceLabel(String formattedPrice, String? unit) =>
      unit == null || unit.isEmpty ? formattedPrice : '$formattedPrice / $unit';
}
