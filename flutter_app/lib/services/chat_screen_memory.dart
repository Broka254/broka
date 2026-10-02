// Which of a thread's two screens the user was last on: Zeno's negotiation
// room (/negotiate) or the direct chat with the other person (/direct-chat).
//
// The Inbox always opened Zeno's room. Someone who had moved a deal to the
// direct chat landed back in Zeno's room every time they opened the thread
// and had to switch again (reported from a phone, 2026-10-02). The Inbox now
// opens the screen remembered here, unless only the other screen has
// something new: the other person wrote in the direct chat (the inbox's
// `unread`), or Zeno said something in its room (`zeno_unread`).
//
// Kept on the phone, per thread - the same scope the chat caches and the
// poller's keys use (listing + buyer).
import 'package:shared_preferences/shared_preferences.dart';

import '../core/network/api_client.dart';

enum ChatScreen {
  zeno('/negotiate'),
  direct('/direct-chat');

  const ChatScreen(this.route);

  /// The named route that opens it.
  final String route;
}

class ChatScreenMemory {
  ChatScreenMemory._();

  static String _key(String listingId, String? buyerId) =>
      'chat_screen_${listingId}_${buyerId ?? ''}';

  /// Records that the user is on [screen] for this thread. A thread with no
  /// buyer id is skipped: a seller's chat reached without one is the latest
  /// buyer's, and saving it under no buyer would mix up every thread on the
  /// listing.
  static Future<void> remember(String listingId, String? buyerId, ChatScreen screen) async {
    if (buyerId == null || buyerId.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key(listingId, buyerId), screen.name);
    } catch (_) {
      // Nothing lost but a preference: the Inbox opens Zeno's room, as before.
    }
  }

  static Future<ChatScreen?> recall(String listingId, String? buyerId) async {
    if (buyerId == null || buyerId.isEmpty) return null;
    try {
      final prefs = await SharedPreferences.getInstance();
      final name = prefs.getString(_key(listingId, buyerId));
      for (final s in ChatScreen.values) {
        if (s.name == name) return s;
      }
    } catch (_) {}
    return null;
  }

  /// The screen an Inbox thread opens on.
  ///
  /// The one the user was last on, unless only the OTHER one has news. When
  /// both do, the user's own choice wins - they'll see the other's badge in
  /// its header. A thread never opened on this phone opens Zeno's room, as
  /// the Inbox always did, unless only the direct chat has news.
  static ChatScreen choose({
    required ChatScreen? remembered,
    required int directUnread,
    required int zenoUnread,
  }) {
    final last = remembered ?? ChatScreen.zeno;
    final otherHasNews = last == ChatScreen.zeno ? directUnread > 0 : zenoUnread > 0;
    final mineHasNews  = last == ChatScreen.zeno ? zenoUnread > 0 : directUnread > 0;
    if (otherHasNews && !mineHasNews) {
      return last == ChatScreen.zeno ? ChatScreen.direct : ChatScreen.zeno;
    }
    return last;
  }

  /// Tells the server the user has seen Zeno's messages in this thread, so
  /// the Inbox stops counting them as news (`zeno_unread`). Separate from
  /// the direct chat's read receipt: it marks nothing of the other person's
  /// read, and the other person is never told. Best-effort.
  static Future<void> markZenoSeen(String listingId, {String? buyerId, ApiClient? client}) async {
    try {
      await (client ?? apiClient).post('/negotiate/$listingId/zeno-read',
          {if (buyerId != null && buyerId.isNotEmpty) 'buyer_id': buyerId},
          timeout: const Duration(seconds: 10));
    } catch (_) {}
  }
}
