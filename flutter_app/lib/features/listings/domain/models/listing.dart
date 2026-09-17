// BROKA v3.0 - Listing domain model
class BrokaListing {
  final String id;
  final String sellerId;
  final String name;
  final String? description;
  final String category;
  final String? subcategoryId;
  final String? condition;   // "new" | "used" | "refurbished"
  final double price;
  final double lat;
  final double lng;
  final String? locationName;
  final String listingType;    // "direct" | "auction"
  final String status;
  final int views;
  final int? targetBidders;
  final String? auctionDate;
  final double? reservePrice;
  final String? verifiedPhotos;
  // AI Showcase/Cover Image (2026-08-29) - see lib/models/listing.dart's
  // matching field for the full rationale (kept in sync across both
  // Listing models, same as verifiedPhotos above already is).
  final String? showcaseImageUrl;
  final String? showcaseImageSource; // "gallery" | "ai" | null
  final bool isFeatured;
  final String? featuredUntil;
  final String? createdAt;
  final double? distanceKm;
  // Seller trust fields (redesign-guide audit fix - backend previously
  // never returned these under any listings endpoint despite ProductCard
  // already being built to show them; see listings/service.py _listing_dict).
  final String? sellerName;
  final bool sellerVerified;
  final double sellerRating;
  final int sellerCompletedDeals;
  // Added (home-redesign brief, 2026-08-16) - see listings/service.py
  // _listing_dict's matching addition. Null is a real, expected state
  // (most sellers won't have uploaded one) - the card falls back to an
  // initial-letter avatar, never a generated face.
  final String? sellerProfilePhoto;
  // Store feature. storeId is null for a personal listing (the default,
  // unchanged case); storeName/storeSlug are only ever non-null alongside
  // it. Kept in sync with lib/models/listing.dart's matching fields, same
  // as showcaseImageUrl/showcaseImageSource above already are.
  final String? storeId;
  final String? storeName;
  final String? storeSlug;

  const BrokaListing({
    required this.id,
    required this.sellerId,
    required this.name,
    this.description,
    required this.category,
    this.subcategoryId,
    this.condition,
    required this.price,
    required this.lat,
    required this.lng,
    this.locationName,
    this.listingType = 'direct',
    this.status = 'active',
    this.views = 0,
    this.targetBidders,
    this.auctionDate,
    this.reservePrice,
    this.verifiedPhotos,
    this.showcaseImageUrl,
    this.showcaseImageSource,
    this.isFeatured = false,
    this.featuredUntil,
    this.createdAt,
    this.distanceKm,
    this.sellerName,
    this.sellerVerified = false,
    this.sellerRating = 0,
    this.sellerCompletedDeals = 0,
    this.sellerProfilePhoto,
    this.storeId,
    this.storeName,
    this.storeSlug,
  });

  factory BrokaListing.fromJson(Map<String, dynamic> json) {
    return BrokaListing(
      id:             json['id']             as String,
      sellerId:       json['seller_id']      as String,
      name:           json['name']           as String,
      description:    json['description']    as String?,
      category:       json['category']       as String,
      subcategoryId:  json['subcategory_id'] as String?,
      condition:      json['condition']      as String?,
      price:          (json['price']         as num).toDouble(),
      lat:            (json['lat']           as num).toDouble(),
      lng:            (json['lng']           as num).toDouble(),
      locationName:   json['location_name']  as String?,
      listingType:    json['listing_type']   as String? ?? 'direct',
      status:         json['status']         as String? ?? 'active',
      views:          json['views']          as int? ?? 0,
      targetBidders:  json['target_bidders'] as int?,
      auctionDate:    json['auction_date']   as String?,
      reservePrice:   (json['reserve_price'] as num?)?.toDouble(),
      verifiedPhotos: json['verified_photos'] as String?,
      showcaseImageUrl: json['showcase_image_url'] as String?,
      showcaseImageSource: json['showcase_image_source'] as String?,
      isFeatured:     json['is_featured']     as bool? ?? false,
      featuredUntil:  json['featured_until']  as String?,
      createdAt:      json['created_at']      as String?,
      distanceKm:     (json['distance_km']    as num?)?.toDouble(),
      sellerName:            json['seller_name']            as String?,
      sellerVerified:        json['seller_verified']         as bool? ?? false,
      sellerRating:          (json['seller_rating']          as num?)?.toDouble() ?? 0,
      sellerCompletedDeals:  json['seller_completed_deals']  as int? ?? 0,
      sellerProfilePhoto:    json['seller_profile_photo']    as String?,
      storeId:    json['store_id']    as String?,
      storeName:  json['store_name']  as String?,
      storeSlug:  json['store_slug']  as String?,
    );
  }

  bool get isAuction => listingType == 'auction';
  bool get isActive  => status == 'active';
  bool get hasStore  => storeId != null;

  String get priceFormatted {
    if (price >= 1000000) return 'KES ${(price / 1000000).toStringAsFixed(1)}M';
    // Below 10K, whole-thousand rounding is too lossy to be trustworthy -
    // KES 1,500 was rounding to "KES 2K", a third more than the real price.
    // One decimal keeps it accurate (1,500 -> "1.5K") without the clutter
    // of full digit-grouped prices once listings get into five figures.
    if (price >= 10000)   return 'KES ${(price / 1000).toStringAsFixed(0)}K';
    if (price >= 1000)    return 'KES ${(price / 1000).toStringAsFixed(1)}K';
    return 'KES ${price.toStringAsFixed(0)}';
  }
}
