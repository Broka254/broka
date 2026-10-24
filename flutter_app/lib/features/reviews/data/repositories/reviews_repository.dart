// BROKA v3.0 - Reviews Repository
//
// The one way the app reaches /reviews. The profile and review screens used
// ApiService calls to /reviews/summary/{id}, /reviews/{id}, /reviews/my-deals
// and /reviews/check/{id} - routes of a router the backend never mounted - so
// every one 404ed, and submitting treated the backend's 201 as a failure.
import '../../../../core/network/api_client.dart';
import '../../../../core/utils/result.dart';
import '../../domain/models/review.dart';
import '../../../../core/errors/user_facing_error.dart';

class ReviewsRepository {
  final ApiClient _client;
  ReviewsRepository({ApiClient? client}) : _client = client ?? apiClient;

  Future<Result<Map<String, dynamic>>> submitReview({
    required String dealId,
    required int rating,
    String comment = '',
  }) => _guard(() async {
        final data = await _client.post('/reviews/', {
          'deal_id': dealId,
          'rating':  rating,
          'comment': comment,
        });
        return data as Map<String, dynamic>;
      });

  /// Newest first.
  Future<Result<List<SellerReview>>> getSellerReviews(
    String sellerId, {int limit = 20, int offset = 0}) => _guard(() async {
        final data = await _client.get('/reviews/seller/$sellerId',
            queryParams: {'limit': '$limit', 'offset': '$offset'}) as List;
        return [for (final r in data) SellerReview.fromJson(r as Map<String, dynamic>)];
      });

  Future<Result<ReviewSummary>> getSummary(String sellerId) => _guard(() async =>
      ReviewSummary.fromJson(
          await _client.get('/reviews/summary/$sellerId') as Map<String, dynamic>));

  /// The signed-in buyer's deals they may review - with [sellerId] only, or
  /// on [storeId]'s products only, when given - each saying whether it has
  /// been reviewed yet.
  Future<Result<List<ReviewableDeal>>> myReviewableDeals({
    String? sellerId,
    String? storeId,
  }) =>
      _guard(() async {
        final data = await _client.get('/reviews/my-deals', queryParams: {
          if (sellerId != null) 'seller_id': sellerId,
          if (storeId != null) 'store_id': storeId,
        }) as Map<String, dynamic>;
        return [
          for (final d in (data['deals'] as List? ?? const []))
            ReviewableDeal.fromJson(d as Map<String, dynamic>),
        ];
      });

  Future<Result<T>> _guard<T>(Future<T> Function() call) async {
    try {
      return Success(await call());
    } on ApiException catch (e) {
      // A 5xx body is the server's own error text ("Internal Server Error"),
      // not something written for a buyer. userFacingError keeps a 4xx
      // sentence the API wrote for people and replaces a 5xx with the
      // generic retry message every other repository shows.
      return Failure(userFacingError(e), statusCode: e.statusCode);
    } catch (e) {
      return Failure(userFacingError(e));
    }
  }
}

final reviewsRepository = ReviewsRepository();
