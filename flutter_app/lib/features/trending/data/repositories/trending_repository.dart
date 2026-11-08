// lib/features/trending/data/repositories/trending_repository.dart
import '../../../../core/network/api_client.dart';
import '../../../../core/utils/result.dart';
import '../../../listings/domain/models/listing.dart';
import '../../../../core/errors/user_facing_error.dart';

class TrendingRepository {
  final ApiClient _client;
  TrendingRepository({ApiClient? client}) : _client = client ?? apiClient;

  Future<Result<List<BrokaListing>>> getTrending({
    String? categoryId,
    int limit = 20,
    int page = 0,
    // The page as sent, for the Trending screen's saved copy.
    void Function(List<Map<String, dynamic>> raw)? onRaw,
    // Cards without the legacy inline images ProductCard never draws.
    bool lean = false,
  }) async {
    try {
      final params = <String, String>{
        'limit': limit.toString(),
        'offset': (page * limit).toString(),
        if (categoryId != null) 'category_id': categoryId,
        if (lean) 'lean': 'true',
      };
      final res = await _client.get('/trending', queryParams: params);
      final raw = (res as List).cast<Map<String, dynamic>>();
      final items = raw.map((e) => BrokaListing.fromJson(e)).toList();
      onRaw?.call(raw);
      return Success(items);
    } on ApiException catch (e) {
      return Failure(sanitizeErrorText(e.message), statusCode: e.statusCode);
    } catch (e) {
      return Failure(userFacingError(e));
    }
  }
}

final trendingRepository = TrendingRepository();
