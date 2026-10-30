// The customer's announcements feed: GET /communications,
// POST /communications/{id}/read and GET /communications/unread-count
// (backend/api/domains/service_communications/router.py, customer router).
import '../../../../core/errors/user_facing_error.dart';
import '../../../../core/network/api_client.dart';
import '../../../../core/utils/result.dart';
import '../../../../utils/backend_time.dart';
import '../../domain/models/announcement.dart';

/// What POST /communications/{id}/read answered: the acknowledgement the
/// server recorded, with the read timestamp it keeps (the first read -
/// repeats return the stored value).
class AnnouncementRead {
  const AnnouncementRead({required this.id, required this.readAt});
  final String id;
  final DateTime? readAt;
}

class CommunicationsRepository {
  final ApiClient _client;
  CommunicationsRepository({ApiClient? client}) : _client = client ?? apiClient;

  /// One page of the authenticated user's announcements, newest first (the
  /// server orders published_at DESC). Drafts, scheduled, cancelled and
  /// expired rows never appear - the server filters them.
  Future<Result<AnnouncementPage>> announcements({int limit = 50, int offset = 0}) async {
    try {
      final data = await _client.get('/communications', queryParams: {
        'limit': '$limit',
        'offset': '$offset',
      });
      if (data is! Map<String, dynamic> && data is! Map) {
        return const Failure('Something went wrong. Please try again.');
      }
      final page = AnnouncementPage.fromJson(
          data is Map<String, dynamic> ? data : Map<String, dynamic>.from(data as Map));
      return Success(page);
    } on ApiException catch (e) {
      return Failure(_messageFor(e), statusCode: e.statusCode);
    } catch (e) {
      return Failure(userFacingError(e));
    }
  }

  /// Acknowledge that the user opened [communicationId]. Idempotent - safe
  /// to retry, and safe to call again for an already-read announcement.
  /// A 404 means the row is gone for this user (expired, unpublished, or
  /// never theirs), not a failure to retry blindly.
  Future<Result<AnnouncementRead>> markRead(String communicationId) async {
    try {
      final data = await _client.post('/communications/$communicationId/read', const {});
      final map = data is Map<String, dynamic>
          ? data
          : data is Map
              ? Map<String, dynamic>.from(data)
              : <String, dynamic>{};
      return Success(AnnouncementRead(
        id: (map['id'] as String?) ?? communicationId,
        readAt: parseBackendUtc(map['read_at'] as String?),
      ));
    } on ApiException catch (e) {
      return Failure(_messageFor(e), statusCode: e.statusCode, code: e.code);
    } catch (e) {
      return Failure(userFacingError(e));
    }
  }

  /// Delete [communicationId] from this user's feed (DELETE
  /// /communications/{id}). Per-user only: other recipients keep it and
  /// admin delivery stats are untouched. Idempotent server-side.
  Future<Result<void>> dismiss(String communicationId) async {
    try {
      await _client.delete('/communications/$communicationId');
      return const Success(null);
    } on ApiException catch (e) {
      return Failure(_messageFor(e), statusCode: e.statusCode, code: e.code);
    } catch (e) {
      return Failure(userFacingError(e));
    }
  }

  /// Mark every visible announcement read; returns how many changed.
  Future<Result<int>> markAllRead() async {
    try {
      final data = await _client.post('/communications/read-all', const {});
      final map = data is Map<String, dynamic>
          ? data
          : data is Map
              ? Map<String, dynamic>.from(data)
              : <String, dynamic>{};
      return Success((map['marked_read'] as num?)?.toInt() ?? 0);
    } on ApiException catch (e) {
      return Failure(_messageFor(e), statusCode: e.statusCode, code: e.code);
    } catch (e) {
      return Failure(userFacingError(e));
    }
  }

  /// The server-backed unread total for the badge. Counted server-side
  /// under the same visibility rules as the feed, so it reflects the whole
  /// feed - not just whatever page is loaded.
  Future<Result<int>> unreadCount() async {
    try {
      final data = await _client.get('/communications/unread-count');
      final map = data is Map<String, dynamic>
          ? data
          : data is Map
              ? Map<String, dynamic>.from(data)
              : <String, dynamic>{};
      final count = (map['unread_count'] as num?)?.toInt();
      if (count == null || count < 0) {
        return const Failure('Something went wrong. Please try again.');
      }
      return Success(count);
    } on ApiException catch (e) {
      return Failure(_messageFor(e), statusCode: e.statusCode);
    } catch (e) {
      return Failure(userFacingError(e));
    }
  }
}

/// The message for a failed request: a 5xx body is the server's own
/// trouble ("Internal Server Error"), not something written for the user,
/// so it becomes the generic fallback - the same rule userFacingError
/// applies, which sanitizeErrorText alone does not know (it never sees
/// the status code).
String _messageFor(ApiException e) {
  if (e.statusCode >= 500) return kGenericErrorMessage;
  return sanitizeErrorText(e.message);
}

final communicationsRepository = CommunicationsRepository();
