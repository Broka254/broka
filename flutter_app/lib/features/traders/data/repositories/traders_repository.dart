// lib/features/traders/data/repositories/traders_repository.dart
import '../../../../core/network/api_client.dart';
import '../../../../core/utils/result.dart';
import '../../domain/models/trader.dart';

class TradersRepository {
  final ApiClient _client;
  TradersRepository({ApiClient? client}) : _client = client ?? apiClient;

  Future<Result<List<Trader>>> list({String? categoryId, double? lat, double? lng}) async {
    try {
      final params = <String, String>{
        if (categoryId != null) 'category_id': categoryId,
        // Added (redesign-guide audit): lets TradersService compute a real
        // distance_km per trader (only when that trader has also left
        // their own location visible - server-side privacy check either
        // way, this is just what makes it possible at all).
        if (lat != null) 'lat': lat.toString(),
        if (lng != null) 'lng': lng.toString(),
      };
      final res = await _client.get('/traders', queryParams: params);
      return Success((res as List).map((e) => Trader.fromJson(e)).toList());
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  Future<Result<Trader>> get(String traderId, {double? lat, double? lng}) async {
    try {
      final params = <String, String>{
        if (lat != null) 'lat': lat.toString(),
        if (lng != null) 'lng': lng.toString(),
      };
      final res = await _client.get('/traders/$traderId', queryParams: params);
      return Success(Trader.fromJson(res));
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }
}

final tradersRepository = TradersRepository();
