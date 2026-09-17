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
      );
}
