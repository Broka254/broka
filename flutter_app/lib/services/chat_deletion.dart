// Deleting whole chats from the Inbox (backend: POST /negotiate/{listing}/
// clear and /negotiate/store/{store}/clear, models/thread_clear.py).
//
// Old and finished conversations piled up in the Inbox with no way out. A
// delete is for this account only: the server leaves the chat out of its
// inbox, history and unread counts, and brings it back with only the new
// messages when either side writes again. The other person keeps their copy.
//
// This phone forgets its own copy too - the saved messages, receipts and
// anything queued to send - so the chat can't reopen from them. And for the
// rest of the session it keeps the server's deletion time per chat, so an
// inbox answer that left the server before the delete (the poller's
// 7-second sweep is often in flight) can't put a deleted chat back.
import '../core/network/api_client.dart';
import 'local_chat_store.dart';

class ChatDeletion {
  ChatDeletion._();

  /// Chat key -> the server's deletion time, this session.
  static final Map<String, DateTime> _deleted = {};

  /// One conversation's identity: a listing's or a store's, and its buyer.
  static String? keyOf(Map<String, dynamic> thread) {
    final buyer = thread['buyer_id'] as String?;
    if (buyer == null || buyer.isEmpty) return null;
    if (thread['thread_type'] == 'store') {
      final store = thread['store_id'] as String?;
      return store == null ? null : 'store:$store|$buyer';
    }
    final listing = thread['listing_id'] as String?;
    return listing == null ? null : '$listing|$buyer';
  }

  /// Whether [thread] is a chat deleted this session that nobody has
  /// written in since.
  static bool hides(Map<String, dynamic> thread) {
    final key = keyOf(thread);
    final at = key == null ? null : _deleted[key];
    if (at == null) return false;
    final last = DateTime.tryParse(thread['last_message_at'] as String? ?? '');
    return last == null || !last.isAfter(at);
  }

  /// [threads] without the chats deleted this session.
  static List<Map<String, dynamic>> visible(List<Map<String, dynamic>> threads) =>
      _deleted.isEmpty ? threads : [for (final t in threads) if (!hides(t)) t];

  /// Deletes [thread] for this account. Throws ApiException (or a network
  /// error) when the server didn't take it; nothing on the phone changes
  /// then.
  static Future<void> delete(Map<String, dynamic> thread, {ApiClient? client}) async {
    final api = client ?? apiClient;
    final buyer = thread['buyer_id'] as String?;
    final isStore = thread['thread_type'] == 'store';
    final id = (isStore ? thread['store_id'] : thread['listing_id']) as String?;
    if (id == null || buyer == null || buyer.isEmpty) {
      throw const ApiException(400, "This chat can't be deleted from here.");
    }
    final res = await api.post(
      isStore ? '/negotiate/store/$id/clear' : '/negotiate/$id/clear',
      {'buyer_id': buyer},
    );
    final at = res is Map ? DateTime.tryParse(res['cleared_at'] as String? ?? '') : null;
    final key = keyOf(thread);
    if (key != null) _deleted[key] = at ?? DateTime.now().toUtc();
    // The scopes the chat screens and the offline sync keep it under
    // (NegotiationScreen._threadScopeKey, NegotiateScreen, syncScopeFor).
    final threadId = isStore ? 'store:$id' : id;
    await LocalChatStore.forget('direct_${threadId}_$buyer');
    if (!isStore) await LocalChatStore.forget('ai_${id}_$buyer');
  }

  /// Signing out, and tests.
  static void reset() => _deleted.clear();
}
