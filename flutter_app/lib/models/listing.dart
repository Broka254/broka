// BROKA - Listing Model
import '../utils/backend_time.dart';
import '../features/categories/domain/category_visual.dart';
import 'listing_photo.dart';

class Listing {
  final String  id;
  final String  name;
  final String  category;
  final double  price;
  // Returned by the listing endpoints all along, but never read here - so
  // the product screen showed a placeholder where the description belongs.
  final String? description;
  final String? condition;
  final Map<String, dynamic>? attributes;
  // Selling terms (2026-09-25), as on BrokaListing.
  final String? priceUnit;
  final int?    quantity;
  final bool    priceNegotiable;
  final bool?   deliveryAvailable;
  final String? deliveryNote;
  final String? locationName;
  final double? lat;
  final double? lng;
  final String  listingType;
  final String  status;
  final int     views;
  /// Units not in a deal yet (direct sales), from the single-listing read
  /// only - lists don't carry it. Null when unknown.
  final int?    unitsLeft;
  /// Every unit sold or in a deal under way. Lists only ever hold listings
  /// on sale, so this is only ever true from the single-listing read.
  final bool    soldOut;
  // Media
  final String? verifiedPhotos;  // comma-separated base64 or URLs
  // AI Showcase/Cover Image (2026-08-29) - optional, homescreen-only.
  // NEVER the source for View Deal's photo gallery; that screen must keep
  // reading verifiedPhotos directly. See product_card.dart for the
  // showcaseImageUrl ?? first-verified-photo fallback this exists for.
  final String? showcaseImageUrl;  // "data:image/...;base64,..." or null
  // "gallery" | "ai" | null - which path produced showcaseImageUrl. Used
  // only to decide whether the "✨ AI Showcase" badge should render
  // (product_card.dart) - a gallery-picked cover never gets that label.
  final String? showcaseImageSource;
  // Stored images - see BrokaListing's matching fields.
  final List<ListingPhoto> photos;
  final ListingPhoto? cover;
  // Seller info
  final String? sellerId;
  final String? sellerName;
  final double? sellerRating;
  final int?    sellerCompletedDeals;
  /// Buyer-facing standing snapshot returned by the public listing detail.
  final Map<String, dynamic>? sellerStanding;
  final double? sellerDcr;
  final bool sellerDcrProvisional;
  final double? sellerResponseMinutes;
  final double? sellerAvgDealTimeMinutes;
  final int? sellerTimedDeals;
  final bool    sellerVerified;
  // Added (home-redesign brief, 2026-08-16) - see BrokaListing's matching
  // field for the full rationale.
  final String? sellerProfilePhoto;
  final String? sellerAvatarUrl;
  final double? sellerLat;
  final double? sellerLng;
  final String? sellerPhone;
  final DateTime? createdAt;
  final bool isFeatured;
  final DateTime? featuredUntil;
  // Store feature. See BrokaListing's matching fields (kept in sync
  // across both Listing models) for the full rationale.
  final String? storeId;
  final String? storeName;
  final String? storeSlug;

  Listing({
    required this.id,
    required this.name,
    required this.category,
    required this.price,
    this.description,
    this.condition,
    this.attributes,
    this.priceUnit,
    this.quantity,
    this.priceNegotiable = true,
    this.deliveryAvailable,
    this.deliveryNote,
    this.locationName,
    this.lat,
    this.lng,
    required this.listingType,
    required this.status,
    required this.views,
    this.unitsLeft,
    this.soldOut = false,
    this.verifiedPhotos,
    this.showcaseImageUrl,
    this.showcaseImageSource,
    this.photos = const [],
    this.cover,
    this.sellerId,
    this.sellerName,
    this.sellerRating,
    this.sellerCompletedDeals,
    this.sellerStanding,
    this.sellerDcr,
    this.sellerDcrProvisional = false,
    this.sellerResponseMinutes,
    this.sellerAvgDealTimeMinutes,
    this.sellerTimedDeals,
    this.sellerVerified = false,
    this.sellerProfilePhoto,
    this.sellerAvatarUrl,
    this.sellerLat,
    this.sellerLng,
    this.sellerPhone,
    this.createdAt,
    this.isFeatured = false,
    this.featuredUntil,
    this.storeId,
    this.storeName,
    this.storeSlug,
  });

  factory Listing.fromJson(Map<String, dynamic> j) => Listing(
        id:                   j['id']            as String,
        name:                 j['name']          as String,
        category:             j['category']      as String,
        price:                (j['price']        as num).toDouble(),
        description:          j['description']   as String?,
        condition:            j['condition']     as String?,
        attributes:           j['attributes'] is Map
            ? Map<String, dynamic>.from(j['attributes'] as Map) : null,
        priceUnit:            j['price_unit']    as String?,
        quantity:             (j['quantity']     as num?)?.toInt(),
        priceNegotiable:      j['price_negotiable'] as bool? ?? true,
        deliveryAvailable:    j['delivery_available'] as bool?,
        deliveryNote:         j['delivery_note'] as String?,
        locationName:         j['location_name'] as String?,
        lat:                  (j['lat']          as num?)?.toDouble(),
        lng:                  (j['lng']          as num?)?.toDouble(),
        listingType:          j['listing_type']  as String,
        status:               j['status']        as String,
        views:                ((j['views'] ?? 0) as num).toInt(),
        unitsLeft:            (j['units_left'] as num?)?.toInt(),
        soldOut:              j['sold_out'] as bool? ?? false,
        verifiedPhotos:       j['verified_photos'] as String?,
        showcaseImageUrl:     j['showcase_image_url'] as String?,
        showcaseImageSource:  j['showcase_image_source'] as String?,
        photos:               ListingPhoto.listFromJson(j['photos']),
        cover:                ListingPhoto.fromJson(j['cover']),
        sellerId:             j['seller_id']        as String?,
        sellerName:           j['seller_name']      as String?,
        sellerRating:         (j['seller_rating']   as num?)?.toDouble(),
        sellerCompletedDeals: (j['seller_completed_deals'] as num?)?.toInt(),
        sellerStanding:       j['seller_standing'] is Map
            ? Map<String, dynamic>.from(j['seller_standing'] as Map) : null,
        sellerDcr:             (j['seller_dcr'] as num?)?.toDouble(),
        sellerDcrProvisional:  j['seller_dcr_provisional'] as bool? ?? false,
        sellerResponseMinutes: (j['seller_response_minutes'] as num?)?.toDouble(),
        sellerAvgDealTimeMinutes: (j['seller_avg_deal_time_minutes'] as num?)?.toDouble(),
        sellerTimedDeals:      (j['seller_timed_deals'] as num?)?.toInt(),
        // FIX (redesign-guide audit): backend previously never returned
        // seller_verified at all for this endpoint, so ProductCard fell
        // back to "sellerName != null" as a proxy for verification. Real
        // field now, same as BrokaListing's.
        sellerVerified:       j['seller_verified']  as bool? ?? false,
        sellerProfilePhoto:   j['seller_profile_photo'] as String?,
        sellerAvatarUrl:      j['seller_avatar_url'] as String?,
        sellerLat:            (j['seller_lat']      as num?)?.toDouble(),
        sellerLng:            (j['seller_lng']      as num?)?.toDouble(),
        sellerPhone:          j['seller_phone']     as String?,
        // FIX (2026-08-18): was plain DateTime.tryParse - see
        // utils/backend_time.dart for why that misreads the backend's
        // naive-UTC timestamps as local time (turning "posted 5 minutes
        // ago" into "posted 3h ago" for a Kenya/UTC+3 device).
        createdAt:            parseBackendUtc(j['created_at'] as String?),
        isFeatured:           j['is_featured']  as bool?  ?? false,
        featuredUntil:        parseBackendUtc(j['featured_until'] as String?),
        storeId:              j['store_id']    as String?,
        storeName:            j['store_name']  as String?,
        storeSlug:            j['store_slug']  as String?,
      );

  // Category-alignment pass (2026-09-18): this four-case switch only
  // knew Vehicles/Property/Electronics/Livestock, so eleven of the
  // backend's sixteen top-level categories rendered as a generic box.
  // features/categories/domain/category_visual.dart is the one table now.
  String get emoji => CategoryVisuals.emojiFor(category);

  String get formattedPrice => 'KES ${price.toStringAsFixed(0).replaceAllMapped(
        RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'), (m) => '${m[1]},',
      )}';
}
