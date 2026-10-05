// Zeno helping a seller while they write a listing (2026-10-05) - the
// app's side of backend/api/domains/zeno_assistant/selling.py.
//
// There is no listing yet, so the draft goes with each request: the
// seller's own entries in the sell wizard, nothing else.
import '../../../services/sell_wizard_data.dart';
import '../../../utils/price_format.dart';

/// The draft as the server reads it (ListingDraftIn).
Map<String, dynamic> zenoListingDraft(SellWizardData d) {
  final price = parseKesInput(d.price);
  final place = [d.subcounty.trim(), d.county.trim()].where((s) => s.isNotEmpty).join(', ');
  return {
    'name': d.name.trim(),
    'category': d.category,
    if (d.subcategoryName != null) 'subcategory': d.subcategoryName,
    if (d.condition != null) 'condition': d.condition,
    'attributes': {
      for (final e in d.attributes.entries)
        if (e.value.trim().isNotEmpty) e.key: e.value.trim(),
    },
    'description': d.description.trim(),
    if (price != null && price > 0) 'asking_price': price,
    if (d.priceUnit != null) 'price_unit': d.priceUnit,
    if (d.priceNegotiable != null) 'price_negotiable': d.priceNegotiable,
    'listing_type': d.isAuction ? 'auction' : 'direct',
    if (place.isNotEmpty) 'location': place,
  };
}

double? _num(Object? v) => v is num ? v.toDouble() : null;

/// What similar live listings on BROKA ask - the Buying Agent's search,
/// run over the draft. The numbers are null when nothing comparable is live.
class ZenoComparables {
  const ZenoComparables({
    required this.count,
    this.low,
    this.median,
    this.high,
    this.typicalLow,
    this.typicalHigh,
    this.listings = const [],
  });

  final int count;
  final double? low;
  final double? median;
  final double? high;

  /// The middle half, once there are enough listings for one.
  final double? typicalLow;
  final double? typicalHigh;

  /// Listing JSON, best match first - for cards.
  final List<Map<String, dynamic>> listings;

  static ZenoComparables? fromJson(Object? json) {
    if (json is! Map) return null;
    return ZenoComparables(
      count: (json['count'] as num?)?.toInt() ?? 0,
      low: _num(json['low']),
      median: _num(json['median']),
      high: _num(json['high']),
      typicalLow: _num(json['typical_low']),
      typicalHigh: _num(json['typical_high']),
      listings: [
        for (final l in (json['listings'] as List? ?? const []))
          if (l is Map) l.cast<String, dynamic>(),
      ],
    );
  }
}

/// One turn of the pricing conversation.
class ZenoPriceTurn {
  const ZenoPriceTurn({
    required this.reply,
    this.suggestedPrice,
    this.offerResearch = false,
    this.comparables,
  });

  final String reply;

  /// The asking price Zeno recommends, in KES - offered as a button.
  final int? suggestedPrice;

  /// Zeno offers to check what similar listings on BROKA ask.
  final bool offerResearch;

  /// Set on the turn that ran that check.
  final ZenoComparables? comparables;

  factory ZenoPriceTurn.fromJson(Map<String, dynamic> json) {
    final price = _num(json['suggested_price']);
    return ZenoPriceTurn(
      reply: (json['reply'] as String? ?? '').trim(),
      // The wizard's own ceiling: a price it couldn't take is no offer.
      suggestedPrice: price != null && price > 0 && price <= maxListingPriceKes ? price.round() : null,
      offerResearch: json['offer_research'] == true,
      comparables: ZenoComparables.fromJson(json['comparables']),
    );
  }
}
