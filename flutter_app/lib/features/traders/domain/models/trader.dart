// lib/features/traders/domain/models/trader.dart
// Trader is a display-side view over an existing User (Design Journal
// Volume 6, Ch.5) - not a new backend identity, so this model just mirrors
// TradersService._trader_dict's exact output shape.
class TraderSpecialization {
  final String id;
  final String name;
  TraderSpecialization({required this.id, required this.name});
  factory TraderSpecialization.fromJson(Map<String, dynamic> json) =>
      TraderSpecialization(id: json['id'] as String, name: json['name'] as String);
}

class Trader {
  final String id;
  final String businessName;
  final bool isVerified;
  final double rating;
  final int completedDeals;
  final int listingCount;
  final List<TraderSpecialization>? specializations;
  // Added (redesign-guide audit): TradersService previously never returned
  // any of these three despite Design v2 §30 listing "business/profile
  // image, ...location, distance" as trader-card elements, and the data
  // (User.profile_photo/business_location/lat/lng) already existing.
  // location_name/distance_km are only ever sent when the trader has left
  // their location visible (same privacy switch the rest of the app
  // already respects) - null here means either "not visible" or "no
  // viewer coordinates were sent", not "definitely hidden".
  final String? profilePhoto;
  final String? locationName;
  final double? distanceKm;

  /// The card's optional background image (POST /traders/me/cover), its
  /// medium size; null for the card's own gradient.
  final String? coverUrl;

  // The trader's own page only (GET /traders/{id}); defaults on a list card.
  final String? about;
  final DateTime? memberSince;
  final int? activeListings;
  final int reviewCount;
  final double? reviewAvg;
  final double? medianResponseMinutes;
  final bool isOnline;
  final DateTime? lastSeen;
  final List<TraderStore> stores;

  Trader({
    required this.id,
    required this.businessName,
    required this.isVerified,
    required this.rating,
    required this.completedDeals,
    required this.listingCount,
    this.specializations,
    this.profilePhoto,
    this.locationName,
    this.distanceKm,
    this.coverUrl,
    this.about,
    this.memberSince,
    this.activeListings,
    this.reviewCount = 0,
    this.reviewAvg,
    this.medianResponseMinutes,
    this.isOnline = false,
    this.lastSeen,
    this.stores = const [],
  });

  factory Trader.fromJson(Map<String, dynamic> json) => Trader(
        id: json['id'] as String,
        businessName: json['business_name'] as String,
        isVerified: json['is_verified'] as bool? ?? false,
        rating: (json['rating'] as num?)?.toDouble() ?? 0,
        completedDeals: (json['completed_deals'] as num?)?.toInt() ?? 0,
        listingCount: (json['listing_count'] as num?)?.toInt() ?? 0,
        specializations: (json['specializations'] as List?)
            ?.map((e) => TraderSpecialization.fromJson(e as Map<String, dynamic>))
            .toList(),
        profilePhoto: json['profile_photo'] as String?,
        locationName: json['location_name'] as String?,
        distanceKm: (json['distance_km'] as num?)?.toDouble(),
        coverUrl: (json['cover'] as Map?)?['medium'] as String?,
        about: json['about'] as String?,
        memberSince: DateTime.tryParse(json['member_since'] as String? ?? ''),
        activeListings: (json['active_listings'] as num?)?.toInt(),
        reviewCount: (json['review_count'] as num?)?.toInt() ?? 0,
        reviewAvg: (json['review_avg'] as num?)?.toDouble(),
        medianResponseMinutes: (json['median_response_minutes'] as num?)?.toDouble(),
        isOnline: json['is_online'] as bool? ?? false,
        lastSeen: DateTime.tryParse(json['last_seen'] as String? ?? ''),
        stores: [
          for (final s in (json['stores'] as List? ?? const []))
            TraderStore.fromJson(s as Map<String, dynamic>),
        ],
      );
}

class TraderStore {
  final String id;
  final String name;
  final String? slug;
  const TraderStore({required this.id, required this.name, this.slug});
  factory TraderStore.fromJson(Map<String, dynamic> json) => TraderStore(
        id: json['id'] as String,
        name: json['name'] as String? ?? 'Store',
        slug: json['slug'] as String?,
      );
}
