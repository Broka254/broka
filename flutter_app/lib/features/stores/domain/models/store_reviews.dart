// A store's buyer reviews, as GET /stores/{id}/reviews returns them
// (backend/api/domains/stores/service.py: store_reviews).
//
// These are the reviews of deals whose product this shop sold, attributed at
// write time (reviews.store_id) - not the owner's whole seller record, so a
// second shop of the same owner cannot borrow this one's reputation. The
// owner's published standing rides along as `seller_standing`; it is about
// the person, and the models come from the reviews feature and
// lib/models/seller_standing.dart so the same JSON reads the same way on
// every screen.
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
