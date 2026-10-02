// BROKA - Global Poller Service
//
// Runs independently of any single screen's lifecycle, checking ALL of the
// user's active negotiation threads (via the same inbox the inbox screen
// uses) for two things:
//   1. New messages that arrived while the user wasn't on that exact
//      negotiation/direct-chat screen.
//   2. Incoming calls, for either role - same reason.
//
// This exists because NotificationService was previously only ever
// triggered from inside negotiation_screen.dart's own poll timer - meaning
// notifications (for both calls and messages) were invisible unless that
// specific screen, for that specific listing, was open and in the
// foreground. FCM client integration is now wired in (main.dart) as the
// PRIMARY mechanism for background/terminated-app call delivery; this
// service's role is the foreground fallback - it still works today even
// before a real Firebase project exists (see FCM_SETUP_REMAINING.md), and
// keeps working as a safety net alongside FCM afterwards.
//
// IMPORTANT: this only works while the Dart VM is alive (app open or
// recently backgrounded, depending on OS). It does NOT wake a fully-killed
// app on its own - only real push (FCM) can do that.
//
// This is also where the device's FCM token gets (re-)registered with the
// backend - start() is the one function every login/session-restore path
// already calls (auth_screen.dart x3, splash_screen.dart's session
// restore), so registering here covers all of them without duplicating
// the call at each site, and naturally re-associates the token with
// whichever user is now authenticated on this device.

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'api_service.dart';
import 'local_chat_store.dart';
import 'notification_service.dart';
import 'callkit_service.dart';

class GlobalPollerService {
  GlobalPollerService._();
  static final GlobalPollerService instance = GlobalPollerService._();

  Timer? _timer;
  bool _checking = false;

  // Threads currently "owned" by an open negotiation/direct-chat screen -
  // that screen already polls live, so notifying about them here would be
  // notifying about a message the user is looking at.
  //
  // markScreenActive/markScreenInactive were wired from the direct-chat
  // screen (negotiation_screen) and NOT from the Zeno negotiation room
  // (negotiate_screen) - which is the screen the "I read Zeno's message and
  // a notification for it arrives four seconds later" report came from.
  // Reading a Zeno reply left the thread unregistered, so the next 7s sweep
  // saw a signature it had not recorded and did its job.
  //
  // Keyed by (listing, buyer) rather than listing alone: a seller has one
  // thread per buyer on the same listing, and suppressing by listing would
  // silence every other buyer's messages while one thread is open.
  final Set<String> _activelyViewedThreads = {};

  static String threadKeyFor(String listingId, String? buyerId) =>
      '$listingId::${buyerId ?? ''}';

  // listing_id -> room_id of an incoming-call notification we've posted and
  // not yet taken down. Lets a later poll cancel the exact notification it
  // raised once that call stops ringing.
  final Map<String, String> _shownCallNotifications = {};

  /// Whether the app is on screen (main.dart sets it from the lifecycle).
  /// A thread "being viewed" is only being viewed while the app is in
  /// front: a chat left open behind the phone's home screen used to
  /// silence that thread's notifications - messages and missed calls -
  /// for as long as it stayed open.
  bool appInForeground = true;

  /// Unread messages across all threads, as of the last sweep: the number
  /// on Home's Inbox tab. Seeded from the cached inbox at start so the
  /// badge is right before the first sweep answers.
  final ValueNotifier<int> unreadTotal = ValueNotifier<int>(0);

  static int unreadIn(Iterable<Map<String, dynamic>> threads) => threads.fold(
      0, (sum, t) => sum + (((t['unread'] ?? t['unread_count']) as num?)?.toInt() ?? 0));

  /// Call from a conversation screen's initState / onResume.
  void markScreenActive(String listingId, {String? buyerId}) {
    _activelyViewedThreads.add(threadKeyFor(listingId, buyerId));
  }

  /// Call from dispose. Must be symmetric: a thread left in this set is a
  /// thread that never notifies again.
  void markScreenInactive(String listingId, {String? buyerId}) {
    _activelyViewedThreads.remove(threadKeyFor(listingId, buyerId));
  }

  // True only for the very first sweep this install ever performs, i.e.
  // before any thread has a stored signature. See _checkThreadForNewMessage.
  bool _primed = false;

  void start() {
    _timer?.cancel();
    unawaited(_seedUnreadFromCache());
    _timer = Timer.periodic(const Duration(seconds: 7), (_) => _checkAll());
    // Run once immediately rather than waiting for the first tick.
    _checkAll();
    _registerFcmTokenIfAvailable();
  }

  /// Sweep everything that happened while we weren't looking.
  ///
  /// Called from main.dart on AppLifecycleState.resumed, and safe to call
  /// at any time: _checkAll is already idempotent (a thread whose signature
  /// hasn't moved produces no notification) and already guards against
  /// overlapping runs.
  ///
  /// This is the WhatsApp behaviour the app was missing. The 7s timer only
  /// runs while the Dart VM is alive and the OS hasn't frozen it, so
  /// anything that arrived during a real offline stretch - backgrounded,
  /// no signal, phone asleep - was simply never swept. The user came back,
  /// the timer resumed from the current state of the world, and the
  /// messages and calls they'd missed produced nothing. Now the first thing
  /// that happens on resume is a full pass over every thread.
  Future<void> catchUp() => _checkAll();

  /// Best-effort - throws if Firebase isn't initialized (no real project
  /// configured yet, see FCM_SETUP_REMAINING.md), which main.dart's own
  /// guard around Firebase.initializeApp() already anticipates. Silently
  /// does nothing in that case, exactly like the rest of the app today.
  Future<void> _registerFcmTokenIfAvailable() async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) await ApiService.registerFcmToken(token);
    } catch (_) {}
    // iOS additionally needs its PushKit VoIP token registered - a
    // different token over a different transport (see CallKitService).
    // No-op on Android.
    try {
      await CallKitService.instance.registerVoipToken();
    } catch (_) {}
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _activelyViewedThreads.clear();
    _shownCallNotifications.clear();
    unreadTotal.value = 0;
  }

  Future<void> _seedUnreadFromCache() async {
    final cached = await LocalChatStore.load(LocalChatStore.inboxListScope);
    // Only if no sweep has answered yet - the cache is older than any sweep.
    if (cached.isNotEmpty && unreadTotal.value == 0) {
      unreadTotal.value = unreadIn(cached);
    }
  }

  bool _isOnScreen(Map<String, dynamic> thread) =>
      appInForeground &&
      _activelyViewedThreads.contains(
          threadKeyFor(thread['listing_id'] as String, thread['buyer_id'] as String?));

  Future<void> _checkAll() async {
    if (_checking) return; // avoid overlapping runs if one is slow
    if (ApiService.currentUserId == null) return;
    _checking = true;
    try {
      final threads = await ApiService.getInbox();
      // This service already fetches the full inbox every ~7s for
      // notification purposes - piggyback on that to keep InboxScreen's
      // offline cache warm too, so going offline no longer means "blank
      // error screen" unless the user has *never* had a connection since
      // installing. Previously this cache was only written from inside
      // InboxScreen itself, right after a successful load there - so it
      // stayed empty for the whole session if the user hadn't opened the
      // Inbox tab (with a connection) at least once, even if they'd been
      // actively chatting the whole time.
      unawaited(LocalChatStore.save(LocalChatStore.inboxListScope,
          threads.length > 300 ? threads.sublist(0, 300) : threads));
      // The thread on screen is being read as it arrives; its count is
      // about to be zero (the chat marks it read), so don't flash it.
      unreadTotal.value = unreadIn(threads.where(
          (t) => t['listing_id'] is String && !_isOnScreen(t)));
      final prefs = await SharedPreferences.getInstance();
      for (final thread in threads) {
        final listingId = thread['listing_id'] as String?;
        if (listingId == null) continue;
        if (_isOnScreen(thread)) {
          // Record the signature before skipping. A bare `continue` here
          // would leave the last message looking unseen, so closing the
          // screen would fire a notification for something already read -
          // trading a notification during reading for one just after it.
          await _recordSignatureOnly(thread, prefs);
          continue;
        }

        // The inbox sweep has just pulled this thread's latest message onto
        // the device. That is exactly what "delivered" means - the app has
        // it, the user hasn't necessarily looked - so record it here rather
        // than waiting for them to open the thread. Without this, a sender's
        // tick would sit on a single check until the recipient actually
        // opened the chat, which is precisely the ambiguity the delivered
        // state exists to remove.
        // Backend sends `unread`; it only started sending `unread_count`
        // alongside it in this change. Read both so this works against an
        // older backend too - previously it read only `unread_count`, got
        // null on every thread, and therefore never sent a single delivered
        // receipt from the poller. The whole "delivered" tick depended on
        // the recipient opening the thread, which is exactly the state
        // "delivered" exists to distinguish from.
        final unread = (thread['unread_count'] as int?) ??
                       (thread['unread'] as int?) ?? 0;
        if (unread > 0) {
          unawaited(ApiService.markThreadDelivered(
            listingId,
            buyerId: thread['buyer_id'] as String?,
          ));
        }

        await _checkThreadForNewMessage(thread, prefs);
        // BUG FIX (calling audit, 2026-09-14): this used to be gated on
        // `my_role == 'seller'`. GET /calls/pending/{listing_id} already
        // scopes its answer to the authenticated caller as CALLEE, whatever
        // role they hold - so the gate did nothing but guarantee that a
        // BUYER being called by a seller was never polled for at all.
        // Combined with FCM not yet being live (see FCM_SETUP_REMAINING.md),
        // that meant seller-to-buyer calls had no delivery mechanism
        // whatsoever: /calls/initiate happily created the session and
        // returned 200 to the seller, who then sat watching "Calling…"
        // while the buyer's phone never rang. negotiation_screen.dart's own
        // in-screen poller had this exact gate removed for this exact
        // reason in the V2 pass; this copy was missed.
        await _checkThreadForIncomingCall(thread);
      }
    } catch (_) {
      // Network hiccup or not logged in - just try again next tick.
    } finally {
      _checking = false;
    }
  }

  String _seenKeyFor(Map<String, dynamic> thread) {
    final listingId = thread['listing_id'];
    final buyerId   = thread['buyer_id'] ?? '';
    return 'global_poll_seen_${listingId}_$buyerId';
  }

  String _seenIdKeyFor(Map<String, dynamic> thread) {
    final listingId = thread['listing_id'];
    final buyerId   = thread['buyer_id'] ?? '';
    return 'global_poll_seen_id_${listingId}_$buyerId';
  }

  static String _textSignature(Map<String, dynamic> thread) =>
      '${thread['last_role'] ?? ''}|${thread['last_msg_type'] ?? 'text'}|'
      '${thread['last_message'] ?? ''}';

  /// Whether the thread's last message has already been dealt with
  /// (notified, or read on screen).
  ///
  /// By the message's id. It used to be by its text alone - so a second
  /// missed call from the same person ("buyer|call|cancelled" again), or a
  /// second "ok", looked like the one already announced and was never
  /// notified. The text is still the fallback: from a server that sends no
  /// id, and on the first sweep after updating, when no id has been
  /// recorded yet and every thread would otherwise announce its last
  /// message again.
  bool _alreadyHandled(Map<String, dynamic> thread, SharedPreferences prefs) {
    final id = thread['last_message_id'] as String?;
    if (id != null && id.isNotEmpty) {
      final seenId = prefs.getString(_seenIdKeyFor(thread));
      if (seenId != null) return seenId == id;
    }
    return prefs.getString(_seenKeyFor(thread)) == _textSignature(thread);
  }

  Future<void> _recordHandled(
    Map<String, dynamic> thread, SharedPreferences prefs,
  ) async {
    await prefs.setString(_seenKeyFor(thread), _textSignature(thread));
    final id = thread['last_message_id'] as String?;
    if (id != null && id.isNotEmpty) {
      await prefs.setString(_seenIdKeyFor(thread), id);
    }
  }

  /// Mark a thread as seen without notifying.
  ///
  /// Used for the thread on screen. Recording the signature is the whole
  /// point: if it were skipped, closing the screen would leave the last
  /// message looking "new" and the next sweep would notify about something
  /// the user read a minute ago.
  Future<void> _recordSignatureOnly(
    Map<String, dynamic> thread, SharedPreferences prefs,
  ) async {
    final lastMessage = thread['last_message'] as String? ?? '';
    if (lastMessage.isEmpty) return;
    await _recordHandled(thread, prefs);
  }

  /// Key recording that this install has completed at least one sweep.
  /// Distinct from the per-thread signature keys - see below.
  static const _primedKey = 'global_poll_primed_v1';

  Future<void> _checkThreadForNewMessage(
    Map<String, dynamic> thread, SharedPreferences prefs,
  ) async {
    final lastMessage = thread['last_message'] as String? ?? '';
    final lastRole     = thread['last_role'] as String? ?? '';
    final myRole       = thread['my_role'] as String? ?? 'buyer';
    final msgType      = thread['last_msg_type'] as String? ?? 'text';
    if (lastMessage.isEmpty) return;
    // Don't notify about our own most recent message.
    if (lastRole == myRole) return;

    if (_alreadyHandled(thread, prefs)) return; // already notified for this message
    await _recordHandled(thread, prefs);

    // Suppression is now per-INSTALL, not per-thread.
    //
    // This line used to be `if (lastSeenSignature == null) return;` - skip
    // the first time we ever see a given thread, to avoid announcing old
    // history when a thread first appears. The reasoning is sound and the
    // effect was the bug: "first time we've seen this thread" is exactly
    // what a thread looks like after the user has been offline long enough
    // for the app to be killed, after a reinstall, after clearing storage,
    // or simply when someone messages them on a listing they've never
    // opened. In every one of those cases the one notification that
    // mattered was the one thrown away.
    //
    // What the old check was actually protecting against is narrower: the
    // very first sweep this install performs, when every thread is
    // simultaneously "new" and firing one notification each would mean a
    // wall of them. So that is what is suppressed now - one flag, set once,
    // and after it every genuinely new thread notifies normally.
    if (!_primed) {
      _primed = prefs.getBool(_primedKey) ?? false;
      if (!_primed) {
        await prefs.setBool(_primedKey, true);
        _primed = true;
        return;
      }
    }

    final fromName = lastRole == 'broker'
        ? 'Zeno'
        : (thread['counterpart_name'] as String? ?? 'Someone');

    // A call-history row is not a message. Its content is the raw outcome
    // verb the backend stored ("missed", "declined", "cancelled",
    // "completed" - routers/calls.py), so rendering it as a chat preview
    // produced a notification whose entire body was the word "missed".
    //
    // Missed calls had no notification path at all before this.
    // _checkThreadForIncomingCall only ever fired for a call that is
    // ringing RIGHT NOW, so a call that came and went while the user was
    // offline left nothing behind - which is the single most conspicuous
    // gap against WhatsApp: you come back and there is no "1 missed call".
    if (msgType == 'call') {
      final outcome = lastMessage.trim().toLowerCase();
      // "completed" is a call that happened and both parties know about.
      // "declined" was the user's own deliberate act. Neither is news.
      if (outcome != 'missed' && outcome != 'cancelled') return;
      // Under the same tag as the server's missed-call push
      // (NotificationService.missedCallTag), so the two are one.
      await NotificationService.instance.showMissedCall(
        listingId:   thread['listing_id'] as String,
        buyerId:     thread['buyer_id'] as String?,
        myRole:      myRole,
        callerName:  fromName,
        isVideo:     (thread['last_call_type'] as String?) == 'video',
        listingName: thread['listing_name'] as String?,
      );
      return;
    }

    await NotificationService.instance.showNewMessage(
      fromName: fromName,
      preview: _previewFor(msgType, lastMessage),
      threadKey: 'thread_${thread['listing_id']}_${thread['buyer_id'] ?? ''}',
      payload: {
        'type':      'new_message',
        'listingId': thread['listing_id'],
        'buyerId':   thread['buyer_id'],
        'myRole':    myRole,
      },
    );
  }

  /// Non-text rows carry a placeholder or a URL as their content, neither of
  /// which belongs in a notification body.
  String _previewFor(String msgType, String raw) {
    switch (msgType) {
      case 'image': return '\u{1F4F7} Photo';
      case 'voice': return '\u{1F3A4} Voice message';
      case 'video': return '\u{1F3AC} Video';
      default:      return raw;
    }
  }

  Future<void> _checkThreadForIncomingCall(Map<String, dynamic> thread) async {
    final listingId = thread['listing_id'] as String?;
    if (listingId == null) return;
    try {
      final callInfo = await ApiService.checkIncomingCall(listingId);
      if (callInfo == null) {
        // No call pending any more. If we posted a ringing notification for
        // this listing earlier, take it down - otherwise a cancelled,
        // answered-elsewhere or timed-out call leaves a permanent
        // "Incoming call" sitting in the tray that does nothing when tapped.
        final stale = _shownCallNotifications.remove(listingId);
        if (stale != null) {
          await NotificationService.instance.cancelIncomingCall(stale);
        }
        return;
      }
      final roomId     = callInfo['room_id'] as String?;
      final callerName = callInfo['caller_name'] as String? ?? 'Buyer';
      final isVideo    = callInfo['call_type'] == 'video';
      // FIX (V2 hardening, 2026-09-03): caller_id is NOT always the buyer -
      // only true when I'm the seller being called. When I'm the buyer
      // being called (by the seller), the buyer is me, not the caller.
      final myRole  = thread['my_role'] as String? ?? 'buyer';
      final buyerId = myRole == 'seller'
          ? (callInfo['caller_id'] as String? ?? '')
          : (thread['buyer_id'] as String? ?? '');
      if (roomId == null) return;
      _shownCallNotifications[listingId] = roomId;
      await NotificationService.instance.showIncomingCall(
        roomId: roomId,
        callerName: callerName,
        listingName: thread['listing_name'] as String? ?? 'your listing',
        isVideo: isVideo,
        payload: {
          'type':      'incoming_call',
          'roomId':    roomId,
          'listingId': listingId,
          'buyerId':   buyerId,
        },
      );
    } catch (_) {}
  }
}
