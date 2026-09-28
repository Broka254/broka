// BROKA — Stores Repository
import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../../../core/network/api_client.dart';
import '../../../../core/utils/result.dart';
import '../../../listings/domain/models/listing.dart';
import '../../domain/models/store.dart';
import '../../domain/models/store_product.dart';

/// Store catalogue sort orders the backend accepts.
enum StoreSort {
  featured('featured', 'Recommended'),
  newest('newest', 'Newest'),
  priceLow('price_low', 'Price: low to high'),
  priceHigh('price_high', 'Price: high to low');

  const StoreSort(this.value, this.label);
  final String value;
  final String label;
}

class StoresRepository {
  final ApiClient _client;
  StoresRepository({ApiClient? client}) : _client = client ?? apiClient;

  /// Runs [call], turning every failure into a [Failure] whose message can
  /// be shown to the person as-is.
  Future<Result<T>> _guard<T>(Future<T> Function() call) async {
    try {
      return Success(await call());
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } on SocketException {
      return const Failure("You're offline. Check your connection and try again.");
    } on TimeoutException {
      return const Failure('BROKA is taking too long to answer. Try again.');
    } on http.ClientException {
      return const Failure("Couldn't reach BROKA. Try again.");
    } catch (e) {
      return Failure(e.toString());
    }
  }

  /// Browse active stores.
  Future<Result<List<Store>>> listStores({
    String? search,
    String? category,
    String? county,
    int limit = 20,
    int offset = 0,
  }) =>
      _guard(() async {
        final data = await _client.get('/stores', queryParams: {
          if (search != null && search.isNotEmpty) 'search': search,
          if (category != null) 'category': category,
          if (county != null) 'county': county,
          'limit': limit.toString(),
          'offset': offset.toString(),
        }) as List;
        return data.map((e) => Store.fromJson(e as Map<String, dynamic>)).toList();
      });

  Future<Result<Store>> createStore(Map<String, dynamic> payload) =>
      _guard(() async => Store.fromJson(await _client.post('/stores', payload)));

  Future<Result<Store>> getStore(String storeId) =>
      _guard(() async => Store.fromJson(await _client.get('/stores/$storeId')));

  Future<Result<Store>> getStoreBySlug(String slug) =>
      _guard(() async => Store.fromJson(await _client.get('/stores/slug/$slug')));

  /// Success(null) - not a Failure - when the signed-in user has no store
  /// yet, which is the normal state for most accounts.
  Future<Result<Store?>> getMyStore() => _guard(() async {
        final data = await _client.get('/stores/mine');
        return data == null ? null : Store.fromJson(data as Map<String, dynamic>);
      });

  Future<Result<Store>> updateStore(String storeId, Map<String, dynamic> payload) =>
      _guard(() async => Store.fromJson(await _client.patch('/stores/$storeId', payload)));

  Future<Result<Store>> setStoreStatus(String storeId, bool isActive) => _guard(() async =>
      Store.fromJson(await _client.post('/stores/$storeId/status', {'is_active': isActive})));

  /// A store's catalogue, in the same card format as Home - render with
  /// ProductCard.
  Future<Result<List<BrokaListing>>> getStoreListings(
    String storeId, {
    int limit = 20,
    int offset = 0,
    String? search,
    String? category,
    StoreSort sort = StoreSort.featured,
  }) =>
      _guard(() async {
        final data = await _client.get('/stores/$storeId/listings', queryParams: {
          'limit': limit.toString(),
          'offset': offset.toString(),
          if (search != null && search.trim().isNotEmpty) 'search': search.trim(),
          if (category != null) 'category': category,
          if (sort != StoreSort.featured) 'sort': sort.value,
        }) as List;
        return data.map((e) => BrokaListing.fromJson(e as Map<String, dynamic>)).toList();
      });

  /// Every product in the owner's store, in every state (live, hidden
  /// until its fee is paid, in a deal, sold), with how many are in each.
  /// Owner only. [state] null is all of them.
  Future<Result<StoreProductsPage>> getOwnerProducts(
    String storeId, {
    StoreProductState? state,
    String? search,
    int limit = 20,
    int offset = 0,
  }) =>
      _guard(() async {
        final data = await _client.get('/stores/$storeId/manage/listings', queryParams: {
          'limit': limit.toString(),
          'offset': offset.toString(),
          if (state != null) 'state': state.value,
          if (search != null && search.trim().isNotEmpty) 'search': search.trim(),
        }) as Map<String, dynamic>;
        return StoreProductsPage(
          items: [
            for (final e in data['items'] as List? ?? const [])
              StoreProduct.fromJson(e as Map<String, dynamic>),
          ],
          counts: StoreProductCounts.fromJson(
              (data['counts'] as Map?)?.cast<String, dynamic>() ?? const {}),
        );
      });

  /// The categories the store has products in, biggest first.
  Future<Result<List<StoreCategoryCount>>> getStoreCategories(String storeId) =>
      _guard(() async {
        final data = await _client.get('/stores/$storeId/categories') as List;
        return data.map((e) => StoreCategoryCount.fromJson(e as Map<String, dynamic>)).toList();
      });

  /// The setup wizard's live check of a link name.
  Future<Result<LinkNameCheck>> checkLinkName(String name) => _guard(() async =>
      LinkNameCheck.fromJson(
          await _client.get('/stores/name-available', queryParams: {'name': name})));

  /// Emails a code to [email] to prove the store owner receives mail
  /// there. Returns the code itself only on development servers.
  Future<Result<String?>> requestEmailCode(String email) => _guard(() async {
        final data = await _client.post('/stores/email/request-code', {'email': email});
        return (data as Map?)?['debug_code'] as String?;
      });

  /// Checks the emailed code; returns the token that proves the address
  /// when the store is saved (`business_email_token`).
  Future<Result<String>> verifyEmailCode(String email, String code) => _guard(() async {
        final data = await _client.post('/stores/email/verify', {'email': email, 'code': code});
        return (data as Map)['email_verify_token'] as String;
      });

  /// Tells the backend this store was opened, for the owner's visit
  /// counts. Fire-and-forget: failures are ignored.
  Future<void> recordVisit(String storeId, {String? via}) async {
    try {
      await _client.post('/stores/$storeId/visit', {if (via != null) 'via': via});
    } catch (_) {}
  }

  /// Counts a share-button tap. Fire-and-forget.
  Future<void> recordShare(String storeId, String channel) async {
    try {
      await _client.post('/stores/$storeId/share', {'channel': channel});
    } catch (_) {}
  }

  /// The signed-in seller, for the setup wizard.
  Future<Result<StoreOwnerProfile>> getOwnerProfile() => _guard(() async =>
      StoreOwnerProfile.fromJson(await _client.get('/auth/me') as Map<String, dynamic>));

  Future<Result<StoreStats>> getStats(String storeId, {int days = 7}) => _guard(() async =>
      StoreStats.fromJson(await _client.get('/stores/$storeId/stats',
          queryParams: {'days': days.toString()}) as Map<String, dynamic>));
}

final storesRepository = StoresRepository();
