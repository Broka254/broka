// The signed-in account: reading it and changing its settings.
//
// Through ApiClient, so an expired session is renewed and the call retried -
// Profile's ApiService.getMe() used a bare http.get, and after an access
// token expired it decoded the 401's body as the user's profile.
import '../../../../core/cache/screen_cache.dart';
import '../../../../core/network/api_client.dart';
import '../../../../core/utils/result.dart';
import '../../../../services/api_service.dart';
import '../../domain/models/my_account.dart';
import '../../../../core/errors/user_facing_error.dart';

class AccountRepository {
  final ApiClient _client;
  AccountRepository({ApiClient? client}) : _client = client ?? apiClient;

  Future<Result<T>> _guard<T>(Future<T> Function() call) async {
    try {
      return Success(await call());
    } on ApiException catch (e) {
      return Failure(sanitizeErrorText(e.message), statusCode: e.statusCode);
    } catch (e) {
      return Failure(userFacingError(e));
    }
  }

  CacheKey _meKey() => CacheKey.forUser(CacheFeature.menuAccount, ApiService.currentUserId);
  CacheKey _countKey(String userId) => CacheKey.forUser(CacheFeature.menuListingCount, userId);

  /// The account as last fetched on this phone, without asking the server -
  /// for the Menu's first paint, offline included. Null when there is none
  /// (or it is past its keep time).
  Future<({MyAccount account, DateTime fetchedAt, bool fresh})?> savedMe() async {
    final e = await ScreenCache.instance.read(_meKey(), CachePolicies.menuAccount);
    final data = e?.data;
    if (e == null || data is! Map) return null;
    try {
      final account = MyAccount.fromJson(Map<String, dynamic>.from(data));
      // A copy saved under one account and read under another would be a
      // leak; the key is per account, and this checks it again.
      final uid = ApiService.currentUserId;
      if (uid != null && account.id != uid) return null;
      return (account: account, fetchedAt: e.fetchedAt, fresh: e.isFresh);
    } catch (_) {
      return null;
    }
  }

  /// The saved active-listing count for [userId].
  Future<({int count, bool fresh})?> savedActiveListingCount(String userId) async {
    final e = await ScreenCache.instance.read(_countKey(userId), CachePolicies.menuListingCount);
    final n = e?.data;
    if (e == null || n is! num) return null;
    return (count: n.toInt(), fresh: e.isFresh);
  }

  /// Fetches the account, and saves it on the phone (see [savedMe]).
  Future<Result<MyAccount>> getMe() => _guard(() async {
        final json = await ScreenCache.instance
            .fetch(_meKey(), () => _client.get('/auth/me'),
                persist: (d) => d is Map<String, dynamic> ? stripLargeInlineMedia(d) : d)
            as Map<String, dynamic>;
        final me = MyAccount.fromJson(json);
        // Keep the session's cached copy in step, as Profile always did -
        // other screens read these statics.
        if (me.nickname != null) ApiService.currentUserNickname = me.nickname;
        if (me.photo != null) ApiService.currentUserPhoto = me.photo;
        ApiService.currentUserAccountType = me.accountType;
        return me;
      });

  /// Listings of [userId]'s that buyers can see right now - the same number
  /// the storefront and Home would find.
  Future<Result<int>> activeListingCount(String userId) => _guard(() async {
        final total = await ScreenCache.instance.fetch(_countKey(userId), () async {
          final data = await _client.get('/listings/', queryParams: {
            'seller_id': userId,
            'limit': '1',
            'with_total': 'true',
          }) as Map<String, dynamic>;
          return (data['total'] as num?)?.toInt() ?? 0;
        });
        return (total as num).toInt();
      });

  /// Show or hide the account's approximate location on trader cards,
  /// search results and profiles.
  Future<Result<void>> setLocationVisible(bool visible) => _guard(() async {
        await _client.patch('/auth/location-visibility?visible=$visible', const <String, dynamic>{});
      });
}

final accountRepository = AccountRepository();
