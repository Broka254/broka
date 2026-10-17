// A store's buyer reviews, as GET /stores/{id}/reviews returns them
// (backend/api/domains/stores/service.py: store_reviews).
//
// A store has no reviews of its own: what buyers see is the owner's
// seller-level record - the same reviews the seller's profile shows - plus
// the owner's published standing. The models come from the reviews feature
// and lib/models/seller_standing.dart, so the same JSON reads the same way
// on every screen.
import '../../../../models/seller_standing.dart';
import '../../../reviews/domain/models/review.dart';

class StoreReviews {
  const StoreReviews({
    this.summary = const ReviewSummary(),
    this.reviews = const [],
    this.sellerStanding,
  });

  final ReviewSummary summary;
  final List<SellerReview> reviews;

  /// The owner's snapshot figures, or null when there is none recent enough
  /// to publish. Response time lives here.
  final SellerStanding? sellerStanding;

  factory StoreReviews.fromJson(Map<String, dynamic> json) => StoreReviews(
        summary: ReviewSummary.fromJson(
            (json['summary'] as Map?)?.cast<String, dynamic>() ?? const {}),
        reviews: [
          for (final r in json['reviews'] as List? ?? const [])
            if (r is Map) SellerReview.fromJson(r.cast<String, dynamic>()),
        ],
        sellerStanding: SellerStanding.fromJson(json['seller_standing']),
      );
}

/// How the store's reply time reads on its details screen, or null when
/// there was too little conversation to measure - the backend's null is
/// "unmeasured", and unmeasured is not "fast".
String? responseTimeLabel(double? minutes) => minutes == null
    ? null
    : 'Usually replies in about ${SellerStanding.formatMinutes(minutes)}';
