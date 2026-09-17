// BROKA v3.0 - Reviews Repository
import '../../../../core/network/api_client.dart';
import '../../../../core/utils/result.dart';

class ReviewsRepository {
  final ApiClient _client;
  ReviewsRepository({ApiClient? client}) : _client = client ?? apiClient;

  Future<Result<Map<String, dynamic>>> submitReview({
    required String dealId,
    required int rating,
    String comment = '',
  }) async {
    try {
      final data = await _client.post('/reviews/', {
        'deal_id': dealId,
        'rating':  rating,
        'comment': comment,
      });
      return Success(data as Map<String, dynamic>);
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  Future<Result<List<Map<String, dynamic>>>> getSellerReviews(String sellerId) async {
    try {
      final data = await _client.get('/reviews/seller/$sellerId') as List;
      return Success(data.cast<Map<String, dynamic>>());
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }
}

final reviewsRepository = ReviewsRepository();
