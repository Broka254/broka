// lib/features/zeno_assistant/data/zeno_sessions_repository.dart
import '../../../core/network/api_client.dart';
import '../domain/zeno_sessions.dart';

class ZenoSessionsRepository {
  ZenoSessionsRepository({ApiClient? client}) : _client = client ?? apiClient;

  final ApiClient _client;

  /// Today's Zeno sessions (GET /zeno/sessions/today), or null when they
  /// can't be read - an older server, no connection. Only ever shown as a
  /// hint: the server decides, and refuses with a 402 when they're used.
  Future<ZenoSessionsToday?> today() async {
    try {
      return ZenoSessionsToday.fromJson(await _client.get('/zeno/sessions/today'));
    } catch (_) {
      return null;
    }
  }
}

final zenoSessionsRepository = ZenoSessionsRepository();
