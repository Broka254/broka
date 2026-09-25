// A Land listing's size: how the sell wizard asks for it and how cards and
// the product screen print it.
//
// The server requires it on every Land listing and stores what the seller
// gave - attributes.land_size and attributes.land_size_unit - plus
// land_size_acres for filtering (backend/api/domains/listings/validation.py
// clean_land_details). The units here are the ones it accepts; the keys are
// its canonical spellings.

class LandUnit {
  const LandUnit(this.key, this.label, this.short);

  /// As the server stores it ("50x100 plots").
  final String key;

  /// As a chip in the wizard shows it.
  final String label;

  /// One-word form for a card ("ac", "ha").
  final String short;
}

class LandSize {
  LandSize._();

  static const units = <LandUnit>[
    LandUnit('acres', 'Acres', 'acre'),
    LandUnit('50x100 plots', '50×100 plots', 'plot'),
    LandUnit('hectares', 'Hectares', 'ha'),
    LandUnit('square metres', 'Square metres', 'm²'),
    LandUnit('square feet', 'Square feet', 'ft²'),
  ];

  static const sizeKey = 'land_size';
  static const unitKey = 'land_size_unit';

  /// The attribute names the wizard asks for with its own control, so the
  /// generic attribute list leaves them out.
  static const fieldNames = {sizeKey, unitKey, 'land_size_acres'};

  static String? canonicalUnit(String? raw) {
    final key = (raw ?? '').trim().toLowerCase().replaceAll('×', 'x');
    for (final u in units) {
      if (u.key == key || u.label.toLowerCase().replaceAll('×', 'x') == key) return u.key;
    }
    return null;
  }

  /// The size typed ("2.5", "1,000"), or null when it isn't a size.
  static double? parse(String? raw) {
    final value = double.tryParse((raw ?? '').replaceAll(',', '').trim());
    if (value == null || !value.isFinite || value <= 0 || value > 1000000) return null;
    return value;
  }

  /// Why [attributes] can't be posted as land, or null when they can.
  static String? problem(Map<String, String> attributes) {
    if (parse(attributes[sizeKey]) == null) return 'Enter the size of the land.';
    if (canonicalUnit(attributes[unitKey]) == null) {
      return 'Choose what the size is measured in - acres, plots, hectares…';
    }
    return null;
  }

  // Keyed by thousandths: a double can't key a const map.
  static const _fractions = {125: '⅛', 250: '¼', 500: '½', 750: '¾'};

  /// "⅛ acre", "2.5 acres", "2 plots (50×100)", "450 m²". Null when
  /// [attributes] has no usable size - including a listing from before the
  /// size was required, unless it carries the old "acreage" detail.
  static String? describe(Map<String, dynamic>? attributes) {
    if (attributes == null) return null;
    final size = parse(attributes[sizeKey]?.toString());
    final unit = canonicalUnit(attributes[unitKey]?.toString());
    if (size != null && unit != null) return _format(size, unit);
    final acreage = parse(attributes['acreage']?.toString());
    return acreage == null ? null : _format(acreage, 'acres');
  }

  static String _format(double size, String unit) {
    final whole = size.truncateToDouble();
    final fraction = _fractions[((size - whole) * 1000).round()];
    final number = fraction != null
        ? (whole == 0 ? fraction : '${whole.toInt()}$fraction')
        : _trim(size);
    final one = size <= 1;
    switch (unit) {
      case 'acres':
        return '$number ${one ? 'acre' : 'acres'}';
      case 'hectares':
        return '$number ha';
      case '50x100 plots':
        return '$number ${one ? 'plot' : 'plots'} (50×100)';
      case 'square metres':
        return '$number m²';
      case 'square feet':
        return '$number ft²';
    }
    return '$number $unit';
  }

  static String _trim(double v) {
    if (v == v.roundToDouble()) {
      final s = v.toInt().toString();
      return s.replaceAllMapped(RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},');
    }
    return v.toStringAsFixed(v < 10 ? 2 : 1).replaceFirst(RegExp(r'0+$'), '');
  }
}
