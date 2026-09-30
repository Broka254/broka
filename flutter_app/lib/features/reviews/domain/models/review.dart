// Buyers' reviews of a seller, as the backend's /reviews routes return them
// (backend/api/domains/reviews/).
//
// A review can only be left by the buyer of a deal with the seller that
// completed - delivery confirmed, escrow paid out - once per deal. The
// backend checks that on every submission; ReviewableDeal is what lets the
// app know before offering the button at all.
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

/// A completed purchase of the signed-in buyer's, which they may review.
class ReviewableDeal {
  const ReviewableDeal({
    required this.dealId,
    required this.sellerId,
    this.sellerName = 'Seller',
    this.listingName = 'Listing',
    this.agreedPrice = 0,
    this.completedAt,
    this.alreadyReviewed = false,
  });

  final String dealId;
  final String sellerId;
  final String sellerName;
  final String listingName;
  final double agreedPrice;
  final DateTime? completedAt;
  final bool alreadyReviewed;

  factory ReviewableDeal.fromJson(Map<String, dynamic> json) => ReviewableDeal(
        dealId: json['deal_id'] as String,
        sellerId: json['seller_id'] as String? ?? '',
        sellerName: json['seller_name'] as String? ?? 'Seller',
        listingName: json['listing_name'] as String? ?? 'Listing',
        agreedPrice: (json['agreed_price'] as num?)?.toDouble() ?? 0,
        completedAt: parseBackendUtc(
            json['completed_at'] as String? ?? json['created_at'] as String?),
        alreadyReviewed: json['already_reviewed'] == true,
      );
}
