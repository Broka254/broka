// The seller's details as lines of the listing's description.
//
// What the Details step asked - "RAM: 8GB", "Storage: 128GB" - written into
// the Description step's box (sell_description_screen.dart) for the seller
// to keep, add to or edit, so the details are never typed twice and the
// description can be skipped. The same "Label: value" lines Zeno writes.
// The server writes the same lines for a listing that arrives with no
// description at all (backend api/domains/listings/details_text.py).
import 'land_size.dart';

class ListingDetailsText {
  ListingDetailsText._();

  /// Words a field name spells in lower case that a buyer reads in capitals.
  static const _acronyms = {
    'ram': 'RAM', 'tv': 'TV', 'ssd': 'SSD', 'hdd': 'HDD', 'gb': 'GB', 'tb': 'TB',
    'id': 'ID', 'usb': 'USB', 'cc': 'cc',
  };

  /// A unit at the end of a field name reads as one: "size_ml" -> "Size (ml)".
  static const _units = {
    'ml': 'ml', 'kg': 'kg', 'ft': 'ft', 'km': 'km', 'cm': 'cm', 'gb': 'GB',
    'watts': 'watts', 'years': 'years', 'inches': 'inches',
  };

  /// "battery_health" -> "Battery health", "ram" -> "RAM",
  /// "bale_weight_kg" -> "Bale weight (kg)".
  static String label(String fieldName) {
    var words = fieldName.trim().toLowerCase().split('_').where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return '';
    final unit = words.length > 1 ? _units[words.last] : null;
    if (unit != null) words = words.sublist(0, words.length - 1);
    final shown = [for (final w in words) _acronyms[w] ?? w];
    var text = shown.join(' ');
    if (shown.first == words.first) text = '${text[0].toUpperCase()}${text.substring(1)}';
    return unit == null ? text : '$text ($unit)';
  }

  /// The details as description lines - condition first, then a land
  /// listing's size, then the rest in the order given; "" when there is
  /// nothing to say. Never longer than [maxLength].
  static String compose({
    String? condition,
    required Map<String, String> attributes,
    int maxLength = 2000,
  }) {
    final lines = <String>[];
    final c = (condition ?? '').trim();
    if (c.isNotEmpty) lines.add('Condition: ${c[0].toUpperCase()}${c.substring(1)}');
    final land = LandSize.describe(attributes);
    if (land != null) lines.add('Size: $land');
    attributes.forEach((key, value) {
      // Asked with their own control (the size line above) or derived by
      // the server - never a line of their own.
      if (LandSize.fieldNames.contains(key) || key == 'acreage') return;
      final name = label(key);
      final text = value.trim();
      if (name.isNotEmpty && text.isNotEmpty) lines.add('$name: $text');
    });
    var out = '';
    for (final line in lines) {
      final next = out.isEmpty ? line : '$out\n$line';
      if (next.length > maxLength) break;
      out = next;
    }
    return out;
  }
}
