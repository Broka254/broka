// The user's call history: GET /calls/history (backend/api/routers/calls.py).
//
// Mobile-data pass (2026-11-08). The first page is saved on the phone and
// asked for again conditionally: the screen opens on the saved calls, and
// an unchanged history comes back as an empty 304 instead of fifty calls
// and everyone's photo. It is always asked - a missed call has to show -
// but rarely downloaded. Answers are lean: a stored photo travels as its
// URL, not as base64.
import '../../../core/cache/screen_cache.dart';
import '../../../core/network/api_client.dart';
import '../../../core/utils/result.dart';
import '../../../services/api_service.dart';
import '../domain/call_record.dart';
import '../../../core/errors/user_facing_error.dart';

class CallHistoryRepository {
  final ApiClient _client;
  CallHistoryRepository({ApiClient? client}) : _client = client ?? apiClient;

  CacheKey _firstPageKey(int limit) =>
      CacheKey.forUser(CacheFeature.callHistory, ApiService.currentUserId, {'limit': limit});

  /// The first page as last fetched on this phone, without asking. Null
  /// when nothing is saved.
  Future<CallHistoryPage?> saved({int limit = 50}) async {
    final e = await ScreenCache.instance.read(_firstPageKey(limit), CachePolicies.callHistory);
    final body = e?.data is Map ? (e!.data as Map)['body'] : null;
    if (body is! Map) return null;
    try {
      return CallHistoryPage.fromJson(Map<String, dynamic>.from(body));
    } catch (_) {
      return null;
    }
  }

  /// Newest first. [before] is the previous page's `nextBefore`.
  Future<Result<CallHistoryPage>> page({String? before, int limit = 50}) async {
    try {
      final query = {
        'limit': '$limit',
        if (before != null) 'before': before,
        'lean': 'true',
      };
      if (before != null) {
        final data = await _client.get('/calls/history', queryParams: query);
        return Success(CallHistoryPage.fromJson(data as Map<String, dynamic>));
      }
      final key = _firstPageKey(limit);
      final held = (await ScreenCache.instance.read(key, CachePolicies.callHistory))?.data;
      final heldBody = held is Map ? held['body'] : null;
      final heldTag = held is Map ? held['etag'] as String? : null;
      final res = await _client.getConditional('/calls/history',
          queryParams: query, etag: heldBody is Map ? heldTag : null);
      final Map<String, dynamic> body;
      if (res.notModified && heldBody is Map) {
        body = Map<String, dynamic>.from(heldBody);
      } else if (res.notModified) {
        // A 304 with nothing to answer it from (the copy was cleared
        // meanwhile): ask once more in full.
        body = await _client.get('/calls/history', queryParams: query) as Map<String, dynamic>;
      } else {
        body = res.data as Map<String, dynamic>;
        await ScreenCache.instance.write(key, {
          'etag': res.etag,
          'body': stripLargeInlineMedia(body),
        });
      }
      return Success(CallHistoryPage.fromJson(body));
    } on ApiException catch (e) {
      return Failure(sanitizeErrorText(e.message), statusCode: e.statusCode);
    } catch (e) {
      return Failure(userFacingError(e));
    }
  }
}

final callHistoryRepository = CallHistoryRepository();
