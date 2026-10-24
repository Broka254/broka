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
    this.viewer,
  });

  final ReviewSummary summary;
  final List<SellerReview> reviews;

  /// The owner's snapshot figures, or null when there is none recent enough
  /// to publish. Response time lives here.
  final SellerStanding? sellerStanding;

  /// Present only for a signed-in caller: their own eligible deals on this
  /// shop. Null for a visitor, so the screen shows no button it could not
  /// back with a review the backend would accept.
  final StoreReviewsViewer? viewer;

  factory StoreReviews.fromJson(Map<String, dynamic> json) => StoreReviews(
        summary: ReviewSummary.fromJson(
            (json['summary'] as Map?)?.cast<String, dynamic>() ?? const {}),
        reviews: [
          for (final r in json['reviews'] as List? ?? const [])
            if (r is Map) SellerReview.fromJson(r.cast<String, dynamic>()),
        ],
        sellerStanding: SellerStanding.fromJson(json['seller_standing']),
        viewer: StoreReviewsViewer.fromJson(json['viewer']),
      );
}

/// What the signed-in viewer may do here, computed by the backend from
/// their own deals (backend stores/service.py: store_reviews). It saves the
/// app a second request, and keeps the button and the server's answer in
/// step: a review submitted a moment ago arrives back as already_reviewed.
class StoreReviewsViewer {
  const StoreReviewsViewer({
    this.canReview = false,
    this.alreadyReviewed = false,
    this.deals = const [],
  });

  final bool canReview;

  /// True only when every sale this buyer had on this shop is reviewed.
  /// A visitor with no deal at all is neither can_review nor reviewed.
  final bool alreadyReviewed;
  final List<ReviewableDeal> deals;

  /// How many deals are still open to review, for the button's label.
  int get unreviewedCount => deals.where((d) => !d.alreadyReviewed).length;

  static StoreReviewsViewer? fromJson(Object? json) {
    if (json is! Map) return null;
    return StoreReviewsViewer(
      canReview: json['can_review'] == true,
      alreadyReviewed: json['already_reviewed'] == true,
      deals: [
        for (final d in json['reviewable_deals'] as List? ?? const [])
          if (d is Map) ReviewableDeal.fromJson(d.cast<String, dynamic>()),
      ],
    );
  }
}

/// How the store's reply time reads on its details screen, or null when
/// there was too little conversation to measure - the backend's null is
/// "unmeasured", and unmeasured is not "fast".
String? responseTimeLabel(double? minutes) => minutes == null
    ? null
    : 'Usually replies in about ${SellerStanding.formatMinutes(minutes)}';
