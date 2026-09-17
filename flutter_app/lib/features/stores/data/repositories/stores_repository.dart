// BROKA — Stores Repository
import '../../../../core/network/api_client.dart';
import '../../../../core/utils/result.dart';
import '../../../listings/domain/models/listing.dart';
import '../../domain/models/store.dart';

class StoresRepository {
  final ApiClient _client;
  StoresRepository({ApiClient? client}) : _client = client ?? apiClient;

  /// Phase 4 discovery/browse - active stores only (same as the backend
  /// default), optionally filtered by a free-text name search.
  Future<Result<List<Store>>> listStores({
    String? search,
    String? specialization,
    String? county,
    int limit = 20,
    int offset = 0,
  }) async {
    try {
      final data = await _client.get('/stores', queryParams: {
        if (search != null && search.isNotEmpty) 'search': search,
        if (specialization != null) 'specialization': specialization,
        if (county != null) 'county': county,
        'limit': limit.toString(),
        'offset': offset.toString(),
      }) as List;
      return Success(data.map((e) => Store.fromJson(e)).toList());
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  Future<Result<Store>> createStore(Map<String, dynamic> payload) async {
    try {
      final data = await _client.post('/stores', payload);
      return Success(Store.fromJson(data));
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  Future<Result<Store>> getStore(String storeId) async {
    try {
      final data = await _client.get('/stores/$storeId');
      return Success(Store.fromJson(data));
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  Future<Result<Store>> getStoreBySlug(String slug) async {
    try {
      final data = await _client.get('/stores/slug/$slug');
      return Success(Store.fromJson(data));
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  /// Returns Success(null) - not a Failure - when the signed-in user has no
  /// store yet. That's the normal, expected state for most accounts, not
  /// an error; callers use this to decide whether to show "Create Store"
  /// or "Manage Store" (spec §9/§10's Store Mode entry point).
  Future<Result<Store?>> getMyStore() async {
    try {
      final data = await _client.get('/stores/mine');
      return Success(data == null ? null : Store.fromJson(data));
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  Future<Result<Store>> updateStore(String storeId, Map<String, dynamic> payload) async {
    try {
      final data = await _client.patch('/stores/$storeId', payload);
      return Success(Store.fromJson(data));
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  Future<Result<Store>> setStoreStatus(String storeId, bool isActive) async {
    try {
      final data = await _client.post('/stores/$storeId/status', {'is_active': isActive});
      return Success(Store.fromJson(data));
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }

  /// A store's public catalog. The backend delegates this to the same
  /// ListingService Home/search use (spec: "do not duplicate listings"),
  /// so this returns plain BrokaListing rows - reuse ProductCard to
  /// render them, don't build a second card widget for store catalogs.
  Future<Result<List<BrokaListing>>> getStoreListings(
    String storeId, {
    int limit = 20,
    int offset = 0,
  }) async {
    try {
      final data = await _client.get('/stores/$storeId/listings', queryParams: {
        'limit': limit.toString(),
        'offset': offset.toString(),
      }) as List;
      return Success(data.map((e) => BrokaListing.fromJson(e)).toList());
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }
}

final storesRepository = StoresRepository();
