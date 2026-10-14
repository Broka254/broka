// Zeno helping a seller while they write a listing (2026-10-05) - the
// app's side of backend/api/domains/zeno_assistant/selling.py.
//
// There is no listing yet, so the draft goes with each request: the
// seller's own entries in the sell wizard, nothing else. The same holds
// for a description Zeno is writing with the seller: the app keeps it and
// what Zeno asked, and sends both back with each answer.
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

/// Something Zeno needs from the seller that the photo couldn't show.
class ZenoDescribeQuestion {
  const ZenoDescribeQuestion({required this.label, required this.question});

  /// The description line the answer fills: "Battery health".
  final String label;

  /// "What's the battery health? Settings > Battery shows it."
  final String question;

  Map<String, String> toJson() => {'label': label, 'question': question};
}

/// One turn of Zeno writing a listing's description with the seller
/// (backend selling.describe and describe_turn).
class ZenoDescribeTurn {
  const ZenoDescribeTurn({required this.description, this.reply = '', this.questions = const []});

  /// "Label: value" lines - what buyers will read.
  final String description;

  /// What Zeno says to the seller; the questions are shown under it.
  final String reply;

  /// What Zeno still needs to know; empty once the description has the
  /// essentials.
  final List<ZenoDescribeQuestion> questions;

  /// The description with a blank "Label: " line for each question still
  /// open - what goes in the seller's box when they stop answering, for
  /// them to fill in there.
  String get withBlanks => [
        if (description.trim().isNotEmpty) description.trim(),
        for (final q in questions) '${q.label}: ',
      ].join('\n');

  factory ZenoDescribeTurn.fromJson(Map<String, dynamic> json) => ZenoDescribeTurn(
        description: (json['description'] as String? ?? '').trim(),
        reply: (json['reply'] as String? ?? '').trim(),
        questions: [
          for (final q in (json['questions'] as List? ?? const []))
            if (q is Map && q['label'] is String && (q['label'] as String).trim().isNotEmpty)
              ZenoDescribeQuestion(
                label: (q['label'] as String).trim(),
                question: (q['question'] as String? ?? '').trim().isEmpty
                    ? '${(q['label'] as String).trim()}?'
                    : (q['question'] as String).trim(),
              ),
        ],
      );
}

// ── Zeno listing an item from its photo (2026-10-08) ─────────────────────────
// The app's side of backend/api/domains/zeno_assistant/autolist.py: the
// seller takes the photos, Zeno fills the listing in and asks what the
// photo can't show, then prices it.

String? _str(Object? v) {
  final s = v is String ? v.trim() : null;
  return s == null || s.isEmpty ? null : s;
}

/// The listing Zeno has filled in so far. The category is one of BROKA's,
/// checked on the server, or null when nothing fits.
class ZenoAutoListing {
  const ZenoAutoListing({
    this.name = '',
    this.category,
    this.categoryId,
    this.subcategory,
    this.subcategoryId,
    this.condition,
    this.attributes = const {},
    this.description = '',
  });

  final String name;
  final String? category;
  final String? categoryId;
  final String? subcategory;
  final String? subcategoryId;

  /// "new" | "used" | "refurbished", or null (land, services - or unknown).
  final String? condition;

  /// Only under the category's own field names, in their shape.
  final Map<String, String> attributes;

  /// "Label: value" lines - what buyers will read.
  final String description;

  /// "Electronics › Phones" - or just the category, or nothing.
  String get filedUnder => [category, subcategory].whereType<String>().join(' › ');

  factory ZenoAutoListing.fromJson(Object? json) {
    final j = json is Map ? json.cast<String, dynamic>() : const <String, dynamic>{};
    final attrs = j['attributes'];
    return ZenoAutoListing(
      name: _str(j['name']) ?? '',
      category: _str(j['category']),
      categoryId: _str(j['category_id']),
      subcategory: _str(j['subcategory']),
      subcategoryId: _str(j['subcategory_id']),
      condition: _str(j['condition']),
      attributes: {
        if (attrs is Map)
          for (final e in attrs.entries)
            if (e.value != null && '${e.value}'.trim().isNotEmpty) '${e.key}': '${e.value}'.trim(),
      },
      description: _str(j['description']) ?? '',
    );
  }

  /// As the server takes it back on the next turn (ListingDraftIn).
  Map<String, dynamic> toJson() => {
        'name': name,
        'category': category ?? '',
        if (subcategory != null) 'subcategory': subcategory,
        if (condition != null) 'condition': condition,
        'attributes': attributes,
        'description': description,
      };
}

/// One turn of Zeno listing the item: what it says, the listing as it
/// stands, and what it still needs from the seller.
class ZenoAutoTurn {
  const ZenoAutoTurn({required this.listing, this.reply = '', this.questions = const []});

  final ZenoAutoListing listing;
  final String reply;
  final List<ZenoDescribeQuestion> questions;

  /// The description with a blank "Label: " line for each question still
  /// open - for the seller to fill in the Description step.
  String get descriptionWithBlanks =>
      ZenoDescribeTurn(description: listing.description, questions: questions).withBlanks;

  factory ZenoAutoTurn.fromJson(Map<String, dynamic> json) => ZenoAutoTurn(
        listing: ZenoAutoListing.fromJson(json['listing']),
        reply: (json['reply'] as String? ?? '').trim(),
        questions: ZenoDescribeTurn.fromJson({'questions': json['questions']}).questions,
      );
}

/// The price Zeno recommends for the listing it wrote: a range buyers will
/// find fair and the one number to ask.
class ZenoPriceRange {
  const ZenoPriceRange({
    required this.reply,
    required this.low,
    required this.high,
    required this.suggested,
    this.fromBroka = false,
    this.canCheckBroka = false,
    this.comparables,
  });

  final String reply;
  final int low;
  final int high;
  final int suggested;

  /// True: the range stands on similar live BROKA listings. False: Zeno's
  /// general estimate.
  final bool fromBroka;

  /// The plan checks prices against BROKA at all - without it, the app
  /// offers Pro for that.
  final bool canCheckBroka;
  final ZenoComparables? comparables;

  static ZenoPriceRange? fromJson(Object? json) {
    if (json is! Map) return null;
    int? whole(Object? v) {
      final n = _num(v);
      return n != null && n > 0 && n <= maxListingPriceKes ? n.round() : null;
    }

    final low = whole(json['low']);
    final high = whole(json['high']);
    final suggested = whole(json['suggested_price']);
    if (low == null || high == null || suggested == null) return null;
    return ZenoPriceRange(
      reply: (json['reply'] as String? ?? '').trim(),
      low: low,
      high: high,
      suggested: suggested,
      fromBroka: json['basis'] == 'broka',
      canCheckBroka: json['can_check_broka'] == true,
      comparables: ZenoComparables.fromJson(json['comparables']),
    );
  }
}
