// Buyers' reviews of a seller, as the backend's /reviews routes return them
// (backend/api/domains/reviews/).
//
// A review can only be left by the buyer of a deal with the seller - one
// per deal - and, when that deal's product belonged to a store, it becomes
// the store's review too. A chat alone is not enough. The backend checks
// that on every submission; ReviewableDeal is what lets the app know before
// offering the button at all, and which shop the deal was on.
import '../../../../utils/backend_time.dart';

/// Every review of a seller, summed up.
class ReviewSummary {
  const ReviewSummary({this.average, this.count = 0, this.distribution = const {}});

  /// 1-5 stars. Null when nobody has reviewed the seller - not 0, and not the
  /// 5.0 an account's rating starts at.
  final double? average;
  final int count;

  /// Star (1-5) to how many reviews gave it.
  final Map<int, int> distribution;

  int countFor(int star) => distribution[star] ?? 0;

  factory ReviewSummary.fromJson(Map<String, dynamic> json) {
    final raw = json['distribution'];
    return ReviewSummary(
      average: (json['avg'] as num?)?.toDouble(),
      count: (json['count'] as num?)?.toInt() ?? 0,
      distribution: {
        // JSON keys are strings: "1".."5".
        if (raw is Map)
          for (final e in raw.entries)
            if (int.tryParse('${e.key}') case final star?) star: (e.value as num?)?.toInt() ?? 0,
      },
    );
  }
}

/// One review, as shown on the seller's profile.
class SellerReview {
  const SellerReview({
    required this.id,
    required this.rating,
    this.comment = '',
    this.reviewerName = 'BROKA buyer',
    this.createdAt,
  });

  final String id;
  final int rating;
  final String comment;

  /// First name and initial ("Amina W."): reviews are public, a buyer's full
  /// name is not.
  final String reviewerName;
  final DateTime? createdAt;

  factory SellerReview.fromJson(Map<String, dynamic> json) => SellerReview(
        id: json['id'] as String? ?? '',
        rating: (json['rating'] as num?)?.toInt() ?? 0,
        comment: json['comment'] as String? ?? '',
        reviewerName: json['reviewer_name'] as String? ?? 'BROKA buyer',
        createdAt: parseBackendUtc(json['created_at'] as String?),
      );
}

/// A deal of the signed-in buyer's, which they may review - agreed, paid,
/// delivered, or still being sorted out. Cancelled and refunded deals are
/// not offered; the backend refuses those too.
class ReviewableDeal {
  const ReviewableDeal({
    required this.dealId,
    required this.sellerId,
    this.sellerName = 'Seller',
    this.listingName = 'Listing',
    this.storeId,
    this.storeName,
    this.agreedPrice = 0,
    this.status = '',
    this.createdAt,
    this.completedAt,
    this.alreadyReviewed = false,
  });

  final String dealId;
  final String sellerId;
  final String sellerName;
  final String listingName;

  /// The shop that sold the product, when it was a store's - the review is
  /// attributed to that shop as well as to the seller (backend reviews/
  /// service.py). Null for a personal listing.
  final String? storeId;
  final String? storeName;
  final double agreedPrice;

  /// The deal's status when it was offered: 'agreed', 'paid', 'released',
  /// 'disputed'... Shown so a review of a deal still running does not claim
  /// it was completed.
  final String status;

  /// When the deal was struck, and when its money was released if it was.
  /// They are different facts: a deal still agreed has a date but has not
  /// completed, and the card must not print one as the other.
  final DateTime? createdAt;
  final DateTime? completedAt;
  final bool alreadyReviewed;

  /// True once the goods changed hands, per BROKA's own record. False for a
  /// deal still agreed or in escrow - which is still reviewable, because
  /// BROKA never learns about payments made outside it.
  bool get isCompleted => status == 'released';

  factory ReviewableDeal.fromJson(Map<String, dynamic> json) => ReviewableDeal(
        dealId: json['deal_id'] as String,
        sellerId: json['seller_id'] as String? ?? '',
        sellerName: json['seller_name'] as String? ?? 'Seller',
        listingName: json['listing_name'] as String? ?? 'Listing',
        storeId: json['store_id'] as String?,
        storeName: json['store_name'] as String?,
        agreedPrice: (json['agreed_price'] as num?)?.toDouble() ?? 0,
        status: json['status'] as String? ?? '',
        createdAt: parseBackendUtc(json['created_at'] as String?),
        completedAt: parseBackendUtc(json['completed_at'] as String?),
        alreadyReviewed: json['already_reviewed'] == true,
      );
}
