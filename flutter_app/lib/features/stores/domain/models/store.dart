// BROKA — Store domain model
//
// Mirrors backend/api/domains/stores/service.py's _store_dict(). Trust
// shown with a store is its owner's real seller record ([StoreOwnerFacts]);
// there is no separate store rating because nothing computes one.
import '../../../../models/listing_photo.dart';

/// The store owner's seller record, as shown on the storefront.
class StoreOwnerFacts {
  final bool verified;
  final double? rating;
  final int completedDeals;
  final DateTime? memberSince;

  const StoreOwnerFacts({
    this.verified = false,
    this.rating,
    this.completedDeals = 0,
    this.memberSince,
  });

  static StoreOwnerFacts? fromJson(Object? j) {
    if (j is! Map) return null;
    return StoreOwnerFacts(
      verified: j['verified'] as bool? ?? false,
      rating: (j['rating'] as num?)?.toDouble(),
      completedDeals: (j['completed_deals'] as num?)?.toInt() ?? 0,
      memberSince: DateTime.tryParse(j['member_since'] as String? ?? ''),
    );
  }
}

class Store {
  final String id;
  final String name;

  /// The link name: the `clanix` in broka.co.ke/store/clanix. Fixed.
  final String slug;

  /// The full shareable link, built by the backend.
  final String url;

  /// One of BROKA's top-level categories.
  final String? category;
  final String? description;
  final String country;
  final String? county;
  final String? subcounty;
  final String? locationDescription;

  /// Optional. Only a verified address is ever shown or mailed.
  final String? businessEmail;
  final bool businessEmailVerified;

  // Images. [logo]/[cover]/[photoImages] are stored images in three sizes;
  // [logoUrl]/[photos] are the plain strings older responses carry (a URL,
  // or base64 for a store the backend hasn't converted yet) - render any of
  // them with BrokaImage.
  final ListingPhoto? logo;
  final ListingPhoto? cover;
  final List<ListingPhoto> photoImages;
  final String? logoUrl;
  final List<String> photos;

  final StoreOwnerFacts? owner;
  final bool isActive;
  final int listingCount;
  final String? createdAt;
  final String? updatedAt;

  const Store({
    required this.id,
    required this.name,
    required this.slug,
    this.url = '',
    this.category,
    this.description,
    this.country = 'Kenya',
    this.county,
    this.subcounty,
    this.locationDescription,
    this.businessEmail,
    this.businessEmailVerified = false,
    this.logo,
    this.cover,
    this.photoImages = const [],
    this.logoUrl,
    this.photos = const [],
    this.owner,
    this.isActive = true,
    this.listingCount = 0,
    this.createdAt,
    this.updatedAt,
  });

  factory Store.fromJson(Map<String, dynamic> json) {
    final slug = json['slug'] as String;
    return Store(
      id:   json['id']   as String,
      name: json['name'] as String,
      slug: slug,
      url:  json['url'] as String? ?? 'https://broka.co.ke/store/$slug',
      // `specialization` is what backends before phase 2 send.
      category: json['category'] as String? ?? json['specialization'] as String?,
      description: json['description'] as String?,
      country:   json['country']   as String? ?? 'Kenya',
      county:    json['county']    as String?,
      subcounty: json['subcounty'] as String?,
      locationDescription: json['location_description'] as String?,
      businessEmail: json['business_email'] as String?,
      businessEmailVerified: json['business_email_verified'] as bool? ?? false,
      logo:  ListingPhoto.fromJson(json['logo']),
      cover: ListingPhoto.fromJson(json['cover']),
      photoImages: ListingPhoto.listFromJson(json['photo_images']),
      logoUrl: json['logo_url'] as String?,
      photos:  (json['photos'] as List?)?.whereType<String>().toList() ?? const [],
      owner: StoreOwnerFacts.fromJson(json['owner']),
      isActive:     json['is_active']     as bool? ?? true,
      listingCount: (json['listing_count'] as num?)?.toInt() ?? 0,
      createdAt: json['created_at'] as String?,
      updatedAt: json['updated_at'] as String?,
    );
  }

  /// "Subcounty, County", or null when neither is set.
  String? get locationLine {
    final parts = [subcounty, county]
        .where((s) => s != null && s.trim().isNotEmpty)
        .toList();
    return parts.isEmpty ? null : parts.join(', ');
  }

  /// The link without the scheme, for display: "broka.co.ke/store/clanix".
  String get displayUrl => url.replaceFirst(RegExp(r'^https?://'), '');

  /// [url] tagged with where it's being shared, so the owner's stats can
  /// say where visitors came from.
  String shareUrl(String via) {
    final uri = Uri.parse(url);
    return uri.replace(queryParameters: {...uri.queryParameters, 'via': via}).toString();
  }

  /// One of the store's products on the web storefront
  /// (…/store/clanix/p/<id>), which opens in the app when it's installed.
  String productUrl(String listingId, {String? via}) {
    final uri = Uri.parse(url);
    return uri.replace(
      path: '${uri.path}/p/$listingId',
      queryParameters: via == null ? null : {'via': via},
    ).toString();
  }

  /// Best image for a small square (logo), as a BrokaImage source.
  String? get logoSource => logo?.thumb ?? logoUrl;

  /// Best image for a wide header, as a BrokaImage source.
  String? get coverSource =>
      cover?.medium ??
      (photoImages.isNotEmpty ? photoImages.first.medium : null) ??
      (photos.isNotEmpty ? photos.first : null);
}

/// One entry of a store's category rail.
class StoreCategoryCount {
  final String name;
  final int count;
  const StoreCategoryCount(this.name, this.count);

  factory StoreCategoryCount.fromJson(Map<String, dynamic> j) =>
      StoreCategoryCount(j['name'] as String, (j['count'] as num).toInt());
}

/// The result of the setup wizard's live link check.
class LinkNameCheck {
  final String name;
  final bool available;
  final String? reason;
  final String? suggestion;
  final String? url;

  const LinkNameCheck({
    required this.name,
    required this.available,
    this.reason,
    this.suggestion,
    this.url,
  });

  factory LinkNameCheck.fromJson(Map<String, dynamic> j) => LinkNameCheck(
        name: j['name'] as String? ?? '',
        available: j['available'] as bool? ?? false,
        reason: j['reason'] as String?,
        suggestion: j['suggestion'] as String?,
        url: j['url'] as String?,
      );
}

/// The owner's numbers for the last few days (GET /stores/{id}/stats).
class StoreStats {
  final int days;
  final int visits;
  final List<({DateTime date, int count})> visitsByDay;
  final Map<String, int> visitsBySource;
  final Map<String, int> visitsBySurface;
  final int shares;
  final Map<String, int> sharesByChannel;

  const StoreStats({
    required this.days,
    required this.visits,
    required this.visitsByDay,
    required this.visitsBySource,
    required this.visitsBySurface,
    required this.shares,
    required this.sharesByChannel,
  });

  factory StoreStats.fromJson(Map<String, dynamic> j) {
    final visits = (j['visits'] as Map?)?.cast<String, dynamic>() ?? const {};
    final shares = (j['shares'] as Map?)?.cast<String, dynamic>() ?? const {};
    Map<String, int> counts(Object? m) => m is Map
        ? m.map((k, v) => MapEntry(k as String, (v as num?)?.toInt() ?? 0))
        : const {};
    return StoreStats(
      days: (j['days'] as num?)?.toInt() ?? 7,
      visits: (visits['total'] as num?)?.toInt() ?? 0,
      visitsByDay: [
        for (final d in (visits['by_day'] as List? ?? const []))
          if (d is Map && DateTime.tryParse(d['date'] as String? ?? '') != null)
            (date: DateTime.parse(d['date'] as String), count: (d['count'] as num?)?.toInt() ?? 0),
      ],
      visitsBySource: counts(visits['by_source']),
      visitsBySurface: counts(visits['by_surface']),
      shares: (shares['total'] as num?)?.toInt() ?? 0,
      sharesByChannel: counts(shares['by_channel']),
    );
  }
}

/// What the store wizard needs to know about the signed-in seller
/// (GET /auth/me): whether they can open a store yet, and the business
/// details to pre-fill it with.
class StoreOwnerProfile {
  final String? name;
  final String accountType;
  final String? sellerTier;
  final String? businessName;
  final String? businessCategory;
  final String? businessLocation;
  final String? businessDescription;
  final String? email;
  final bool emailVerified;

  const StoreOwnerProfile({
    this.name,
    this.accountType = 'buyer',
    this.sellerTier,
    this.businessName,
    this.businessCategory,
    this.businessLocation,
    this.businessDescription,
    this.email,
    this.emailVerified = false,
  });

  factory StoreOwnerProfile.fromJson(Map<String, dynamic> j) => StoreOwnerProfile(
        name: j['name'] as String?,
        accountType: j['account_type'] as String? ?? 'buyer',
        sellerTier: j['seller_tier'] as String?,
        businessName: j['business_name'] as String?,
        businessCategory: j['business_category'] as String?,
        businessLocation: j['business_location'] as String?,
        businessDescription: j['business_description'] as String?,
        email: j['email'] as String?,
        emailVerified: j['email_verified'] as bool? ?? false,
      );

  /// Only long-term sellers (who gave BROKA their business details) can
  /// open a store; everyone else adds those details first.
  bool get canOpenStore => accountType == 'buyer_seller' && sellerTier == 'long_term';
}
