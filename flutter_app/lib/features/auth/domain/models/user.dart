// BROKA v3.0 - User domain model
class BrokaUser {
  final String id;
  final String name;
  final String? nickname;
  final String email;
  final String? phone;
  final double? lat;
  final double? lng;
  /// The account's buyer-review average (1-5), or null when nobody has
  /// reviewed them. Never default this to 5.0: that is the legacy column's
  /// starting value, not a score a buyer gave.
  final double? rating;

  /// How many buyer reviews [rating] is over. Zero means "no rating yet".
  final int reviewCount;
  final int completedDeals;
  final bool isVerified;
  final String? verifyTier;
  final String? verifyExpiresAt;
  final String? preferredLanguage;
  final bool locationVisible;
  final String? profilePhoto;
  final bool isAdmin;
  final String? lastSeen;
  final int trustScore;
  final String trustBand;
  final bool isFlagged;
  final String? createdAt;
  final double? distanceKm;

  const BrokaUser({
    required this.id,
    required this.name,
    this.nickname,
    required this.email,
    this.phone,
    this.lat,
    this.lng,
    this.rating,
    this.reviewCount = 0,
    this.completedDeals = 0,
    this.isVerified = false,
    this.verifyTier,
    this.verifyExpiresAt,
    this.preferredLanguage,
    this.locationVisible = true,
    this.profilePhoto,
    this.isAdmin = false,
    this.lastSeen,
    this.trustScore = 100,
    this.trustBand = 'trusted',
    this.isFlagged = false,
    this.createdAt,
    this.distanceKm,
  });

  factory BrokaUser.fromJson(Map<String, dynamic> json) {
    return BrokaUser(
      id: json['id'] as String,
      name: json['name'] as String? ?? '',
      nickname: json['nickname'] as String?,
      email: json['email'] as String? ?? '',
      phone: json['phone'] as String?,
      lat: (json['lat'] as num?)?.toDouble(),
      lng: (json['lng'] as num?)?.toDouble(),
      rating: (json['rating'] as num?)?.toDouble(),
      reviewCount: (json['review_count'] as num?)?.toInt() ?? 0,
      completedDeals: json['completed_deals'] as int? ?? 0,
      isVerified: json['is_verified'] as bool? ?? false,
      verifyTier: json['verify_tier'] as String?,
      verifyExpiresAt: json['verify_expires_at'] as String?,
      preferredLanguage: json['preferred_language'] as String?,
      locationVisible: json['location_visible'] as bool? ?? true,
      profilePhoto: json['profile_photo'] as String?,
      isAdmin: json['is_admin'] as bool? ?? false,
      lastSeen: json['last_seen'] as String?,
      trustScore: json['trust_score'] as int? ?? 100,
      trustBand: json['trust_band'] as String? ?? 'trusted',
      isFlagged: json['is_flagged'] as bool? ?? false,
      createdAt: json['created_at'] as String?,
      distanceKm: (json['distance_km'] as num?)?.toDouble(),
    );
  }

  String get displayName => nickname ?? name;

  bool get isHighRisk => trustScore < 20;
  bool get isAtRisk   => trustScore < 50;
}
