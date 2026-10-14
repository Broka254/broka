// The signed-in account: reading it and changing its settings.
//
// Through ApiClient, so an expired session is renewed and the call retried -
// Profile's ApiService.getMe() used a bare http.get, and after an access
// token expired it decoded the 401's body as the user's profile.
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

  Future<Result<MyAccount>> getMe() => _guard(() async {
        final me = MyAccount.fromJson(await _client.get('/auth/me') as Map<String, dynamic>);
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
        final data = await _client.get('/listings/', queryParams: {
          'seller_id': userId,
          'limit': '1',
          'with_total': 'true',
        }) as Map<String, dynamic>;
        return (data['total'] as num?)?.toInt() ?? 0;
      });

  /// Show or hide the account's approximate location on trader cards,
  /// search results and profiles.
  Future<Result<void>> setLocationVisible(bool visible) => _guard(() async {
        await _client.patch('/auth/location-visibility?visible=$visible', const <String, dynamic>{});
      });
}

final accountRepository = AccountRepository();
