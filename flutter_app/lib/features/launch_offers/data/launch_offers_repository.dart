// BROKA - Launch offers: GET /pricing/launch-offers. A read never claims
// a slot; claiming happens inside the create calls on the server.
import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../../core/cache/screen_cache.dart';
import '../../../core/errors/user_facing_error.dart';
import '../../../core/network/api_client.dart';
import '../../../core/utils/result.dart';
import '../../../services/api_service.dart';
import '../domain/launch_offers.dart';

class LaunchOffersRepository {
  LaunchOffersRepository({ApiClient? client}) : _client = client ?? apiClient;
  final ApiClient _client;

  /// The offers as this account stands with them.
  ///
  /// Home, the Menu, its store section and the Seller Dashboard each show
  /// them, and the dashboard asked twice while opening: each asked the
  /// server on its own. Now a copy younger than CachePolicies.launchOffers
  /// (two minutes - other people claim slots) is reused, concurrent asks
  /// share one request, and posting a listing or opening a store marks the
  /// copy out of date (DataChanges), since that is what claims a slot.
  /// [forceRefresh] (a pull) always asks. A failure is a failure: an old
  /// count is not shown as a live one.
  Future<Result<LaunchOffers>> offers({bool forceRefresh = false}) async {
    final key = CacheKey.forUser(CacheFeature.launchOffers, ApiService.currentUserId);
    final cache = ScreenCache.instance;
    if (!forceRefresh) {
      final saved = await cache.read(key, CachePolicies.launchOffers);
      final data = saved?.data;
      if (saved != null && saved.isFresh && data is Map) {
        try {
          return Success(LaunchOffers.fromJson(Map<String, dynamic>.from(data)));
        } catch (_) {}
      }
    }
    try {
      final data = await cache.fetch(key, () => _client.get('/pricing/launch-offers'))
          as Map<String, dynamic>;
      return Success(LaunchOffers.fromJson(data));
    } on ApiException catch (e) {
      return Failure(sanitizeErrorText(e.message), statusCode: e.statusCode);
    } on SocketException {
      return const Failure("You're offline. Check your connection and try again.");
    } on TimeoutException {
      return const Failure('BROKA is taking too long to answer. Try again.');
    } on http.ClientException {
      return const Failure("Couldn't reach BROKA. Try again.");
    } catch (e) {
      return Failure(userFacingError(e));
    }
  }
}

final launchOffersRepository = LaunchOffersRepository();
