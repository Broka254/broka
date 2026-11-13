// Deleting a chat from the inbox (backend POST /negotiate/thread/delete,
// api/core/thread_clear.py).
//
// For this person only: the other side keeps their copy and BROKA keeps the
// record a dispute needs. The chat leaves this inbox, opens empty, and comes
// back with the next message. A chat whose deal holds money in escrow is
// refused (409) until the deal is settled.
import '../../../core/errors/user_facing_error.dart';
import '../../../core/network/api_client.dart';
import '../../../core/utils/result.dart';
import '../../../services/local_chat_store.dart';

/// Which chat an inbox row is, as the inbox and the chats name it.
class ChatThreadRef {
  const ChatThreadRef({this.listingId, this.storeId, required this.buyerId});

  final String? listingId;
  final String? storeId;
  final String buyerId;

  bool get isStore => storeId != null && storeId!.isNotEmpty;

  /// One inbox row (GET /negotiate/inbox), or null for one naming no chat.
  static ChatThreadRef? fromInbox(Map<String, dynamic> t) {
    String? s(Object? v) => v is String && v.isNotEmpty ? v : null;
    final buyer = s(t['buyer_id']);
    if (buyer == null) return null;
    if (t['thread_type'] == 'store') {
      final store = s(t['store_id']);
      return store == null ? null : ChatThreadRef(storeId: store, buyerId: buyer);
    }
    final listing = s(t['listing_id']);
    return listing == null ? null : ChatThreadRef(listingId: listing, buyerId: buyer);
  }

  /// Stable for this chat, for remembering which rows were deleted.
  String get key => isStore ? 'store:$storeId:$buyerId' : '$listingId:$buyerId';

  /// Where the chats keep this thread on the phone (LocalChatStore). The
  /// direct chat's key names the buyer as its screen knew them, which for
  /// a buyer can be empty - both forms are cleared.
  List<String> get localScopes {
    final thread = isStore ? 'store:$storeId' : listingId!;
    return [
      'direct_${thread}_$buyerId',
      'direct_${thread}_',
      if (!isStore) 'ai_${listingId}_$buyerId',
    ];
  }

  Map<String, dynamic> toJson() => {
        if (isStore) 'store_id': storeId else 'listing_id': listingId,
        'buyer_id': buyerId,
      };
}

class ChatDeletionRepository {
  ChatDeletionRepository({ApiClient? client}) : _client = client ?? apiClient;

  final ApiClient _client;

  Future<Result<void>> delete(ChatThreadRef thread) async {
    try {
      await _client.post('/negotiate/thread/delete', thread.toJson());
    } on ApiException catch (e) {
      return Failure(sanitizeErrorText(e.message), statusCode: e.statusCode);
    } catch (e) {
      return Failure(userFacingError(e));
    }
    // Gone from the server's view: gone from the phone's too, or the
    // chat would repaint the deleted messages from its cache on open.
    for (final scope in thread.localScopes) {
      await LocalChatStore.forgetThread(scope);
    }
    return const Success(null);
  }
}

final chatDeletionRepository = ChatDeletionRepository();
