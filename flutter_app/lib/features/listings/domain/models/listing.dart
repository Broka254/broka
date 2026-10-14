// BROKA v3.0 - Listing domain model
import '../../../../models/listing_photo.dart';
import '../../../../utils/price_format.dart';

class BrokaListing {
  final String id;
  final String sellerId;
  final String name;
  final String? description;
  final String category;
  final String? subcategoryId;
  final String? condition;   // "new" | "used" | "refurbished"
  // Category details ({"make": "Toyota"}; a Land listing's land_size and
  // land_size_unit). Null when the listing has none.
  final Map<String, dynamic>? attributes;
  final double price;
  // Selling terms (2026-09-25) - see the backend Listing model. priceUnit
  // null = the price is for the whole item; quantity null = not said.
  final String? priceUnit;
  final int? quantity;
  final bool priceNegotiable;
  final bool? deliveryAvailable;
  final String? deliveryNote;
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
  // Stored images (Online Stores phase 1). `photos` is every photo, first
  // one first; `cover` is what a card shows (the showcase, else the first
  // photo). Empty/null for a listing the backend hasn't converted yet -
  // readers fall back to verifiedPhotos/showcaseImageUrl then.
  final List<ListingPhoto> photos;
  final ListingPhoto? cover;
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
  // The seller's avatar as a stored image (small size). Preferred over
  // sellerProfilePhoto, which list responses stop sending once it exists.
  final String? sellerAvatarUrl;
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
    this.attributes,
    required this.price,
    this.priceUnit,
    this.quantity,
    this.priceNegotiable = true,
    this.deliveryAvailable,
    this.deliveryNote,
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
    this.photos = const [],
    this.cover,
    this.isFeatured = false,
    this.featuredUntil,
    this.createdAt,
    this.distanceKm,
    this.sellerName,
    this.sellerVerified = false,
    this.sellerRating = 0,
    this.sellerCompletedDeals = 0,
    this.sellerProfilePhoto,
    this.sellerAvatarUrl,
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
      attributes:     json['attributes'] is Map
          ? Map<String, dynamic>.from(json['attributes'] as Map) : null,
      price:          (json['price']         as num).toDouble(),
      priceUnit:      json['price_unit']     as String?,
      quantity:       (json['quantity']      as num?)?.toInt(),
      priceNegotiable: json['price_negotiable'] as bool? ?? true,
      deliveryAvailable: json['delivery_available'] as bool?,
      deliveryNote:   json['delivery_note']  as String?,
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
      photos:         ListingPhoto.listFromJson(json['photos']),
      cover:          ListingPhoto.fromJson(json['cover']),
      isFeatured:     json['is_featured']     as bool? ?? false,
      featuredUntil:  json['featured_until']  as String?,
      createdAt:      json['created_at']      as String?,
      distanceKm:     (json['distance_km']    as num?)?.toDouble(),
      sellerName:            json['seller_name']            as String?,
      sellerVerified:        json['seller_verified']         as bool? ?? false,
      sellerRating:          (json['seller_rating']          as num?)?.toDouble() ?? 0,
      sellerCompletedDeals:  json['seller_completed_deals']  as int? ?? 0,
      sellerProfilePhoto:    json['seller_profile_photo']    as String?,
      sellerAvatarUrl:       json['seller_avatar_url']       as String?,
      storeId:    json['store_id']    as String?,
      storeName:  json['store_name']  as String?,
      storeSlug:  json['store_slug']  as String?,
    );
  }

  bool get isAuction => listingType == 'auction';
  bool get isActive  => status == 'active';
  bool get hasStore  => storeId != null;

  // Home collapsing-scroll pass (2026-09-18, brief §5): no more K/M
  // abbreviation. The old ladder here rounded five-figure prices to the
  // nearest thousand ("KES 15K" for anything from 14,500 to 15,499), which
  // is exactly the range a buyer compares within. utils/price_format.dart
  // is now the single implementation - ProductCard and HomeScreen's filter
  // panel each carried their own drifting copy of the same ladder.
  String get priceFormatted => formatKes(price);
}
