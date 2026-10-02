// The user's call history: GET /calls/history (backend/api/routers/calls.py).
import '../../../core/network/api_client.dart';
import '../../../core/utils/result.dart';
import '../domain/call_record.dart';

class CallHistoryRepository {
  final ApiClient _client;
  CallHistoryRepository({ApiClient? client}) : _client = client ?? apiClient;

  /// Newest first. [before] is the previous page's `nextBefore`.
  Future<Result<CallHistoryPage>> page({String? before, int limit = 50}) async {
    try {
      final data = await _client.get('/calls/history', queryParams: {
        'limit': '$limit',
        if (before != null) 'before': before,
      });
      return Success(CallHistoryPage.fromJson(data as Map<String, dynamic>));
    } on ApiException catch (e) {
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }
}

final callHistoryRepository = CallHistoryRepository();
