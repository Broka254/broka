// lib/features/auctions/data/repositories/auctions_repository.dart
import '../../../../core/network/api_client.dart';
import '../../../../core/utils/result.dart';
import '../../domain/models/auction.dart';

class AuctionsRepository {
  final ApiClient _client;
  AuctionsRepository({ApiClient? client}) : _client = client ?? apiClient;

  Future<Result<List<Auction>>> list({String? status}) async {
    try {
      final params = <String, String>{
        if (status != null) 'status': status,
      };
      final res = await _client.get('/auctions', queryParams: params);
      return Success((res as List).map((e) => Auction.fromJson(e)).toList());
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  Future<Result<Auction>> get(String listingId) async {
    try {
      final res = await _client.get('/auctions/$listingId');
      return Success(Auction.fromJson(res));
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }
}

final auctionsRepository = AuctionsRepository();
