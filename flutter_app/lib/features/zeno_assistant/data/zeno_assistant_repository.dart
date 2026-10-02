// lib/features/zeno_assistant/data/zeno_assistant_repository.dart
import '../../../core/network/api_client.dart';
import '../../../core/utils/result.dart';
import '../../../services/api_service.dart';
import '../domain/zeno_action.dart';

class ZenoAssistantRepository {
  ZenoAssistantRepository({ApiClient? client}) : _client = client ?? apiClient;

  final ApiClient _client;

  /// One turn with Zeno (POST /zeno/assistant/turn): its reply, and at most
  /// one thing to do in the app. Typed and spoken turns are the same turn;
  /// [voice] only asks for a reply that reads well aloud.
  ///
  /// Stateless, like the Buying Agent: [history] is the conversation so far,
  /// without [message] - the server adds it after the history itself.
  ///
  /// [listingId]: the listing the user opened Zeno from to ask about. Only
  /// the id - the server reads the listing itself.
  ///
  /// [imageBase64]: a photo for Zeno to look at with this message (raw
  /// base64). The server checks it, strips its metadata and shrinks it
  /// before any model sees it.
  Future<Result<ZenoTurnResult>> turn({
    required String message,
    required List<Map<String, String>> history,
    required String language,
    bool voice = false,
    String? listingId,
    String? imageBase64,
  }) async {
    try {
      final res = await _client.post('/zeno/assistant/turn', {
        'message': message,
        'history': history,
        'language': language,
        'mode': voice ? 'voice' : 'text',
        if (listingId != null) 'listing_id': listingId,
        if (imageBase64 != null) 'image_base64': imageBase64,
      });
      if (res is! Map) return const Failure('Zeno sent back nothing usable.');
      return Success(ZenoTurnResult.fromJson(res.cast<String, dynamic>()));
    } on ApiException catch (e) {
      // A server from before the assistant: talk the old way, with no
      // actions, rather than leave the Zeno tab dead until it is updated.
      if (e.statusCode == 404) {
        try {
          final reply = await ApiService.zenoChat(
              message: message, history: history, language: language,
              imageBase64: imageBase64);
          return Success(ZenoTurnResult(reply: reply));
        } catch (_) {}
      }
      return Failure(e.message, statusCode: e.statusCode);
    } catch (e) {
      return Failure(e.toString());
    }
  }
}

final zenoAssistantRepository = ZenoAssistantRepository();
