// lib/features/trending/data/repositories/trending_repository.dart
import '../../../../core/network/api_client.dart';
import '../../../../core/utils/result.dart';
import '../../../listings/domain/models/listing.dart';

class TrendingRepository {
  final ApiClient _client;
  TrendingRepository({ApiClient? client}) : _client = client ?? apiClient;

  Future<Result<List<BrokaListing>>> getTrending({
    String? categoryId,
    int limit = 20,
    int page = 0,
  }) async {
    try {
      final params = <String, String>{
        'limit': limit.toString(),
        'offset': (page * limit).toString(),
        if (categoryId != null) 'category_id': categoryId,
      };
      final res = await _client.get('/trending', queryParams: params);
      return Success((res as List).map((e) => BrokaListing.fromJson(e)).toList());
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }
}

final trendingRepository = TrendingRepository();
