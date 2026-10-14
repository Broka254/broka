// What a listing's seller is called, as a buyer sees it on the listing's
// screen.
//
// A long-term seller deals under a business name, and the listing (its
// seller_name) gives only that - "Clanix" - so a buyer never learned who the
// person behind it was. The seller's public profile (GET /auth/user/{id})
// carries both: business_name, which only a long-term seller has, and name,
// the official name given at signup. A business is headed by its own name
// with the official name under it; anyone else is just their name.
class SellerNames {
  /// The business name for a business, else the person's name.
  final String headline;

  /// The person's official name, set only under a business name - and only
  /// once the profile has loaded, since the listing doesn't carry it.
  final String? officialName;

  const SellerNames._(this.headline, this.officialName);

  factory SellerNames.of({String? listingName, Map<String, dynamic>? profile}) {
    final business = _clean(profile?['business_name']);
    final official = _clean(profile?['name']);
    if (business != null) {
      final sameName = official != null && official.toLowerCase() == business.toLowerCase();
      return SellerNames._(business, sameName ? null : official);
    }
    return SellerNames._(_clean(listingName) ?? official ?? 'Seller', null);
  }

  static String? _clean(Object? value) {
    final s = value is String ? value.trim() : null;
    return s == null || s.isEmpty ? null : s;
  }
}
