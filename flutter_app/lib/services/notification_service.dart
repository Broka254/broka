// BROKA - Notification Service (local notifications + FCM foreground/tap handling)
//
// Uses flutter_local_notifications to surface heads-up notifications for:
//   • new negotiation/chat messages (detected by GlobalPollerService or the
//     in-app screen-level pollers)
//   • incoming VoIP calls (detected by GlobalPollerService, the seller's
//     in-screen call poller, or now an FCM data message - see
//     handleForegroundFcmMessage below and firebaseMessagingBackgroundHandler
//     in main.dart)
//
// FCM client integration is wired up (main.dart initializes Firebase,
// registers the background/foreground/tap handlers) but only takes effect
// once a real Firebase project + google-services.json exist - see
// FCM_SETUP_REMAINING.md for exactly what's still externally configurable.
// Until then, Firebase.initializeApp() throws, main.dart catches that, and
// this service works exactly as it always has: local notifications only,
// while the app process is alive (foreground or backgrounded).
//
// One shared call-routing mechanism regardless of source: local-notification
// taps, FCM message taps (onMessageOpenedApp/getInitialMessage), foreground
// FCM messages, and the pollers all ultimately go through
// navigateFromPayload/showIncomingCall below.

import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'api_service.dart';
import 'ringtone_service.dart';

class NotificationService {
  NotificationService._();
  static final NotificationService instance = NotificationService._();

  GlobalKey<NavigatorState>? navigatorKey;

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _ready = false;

  // Two channels so calls can be more intrusive (sound + high importance) than
  // ordinary message notifications.
  static const AndroidNotificationChannel _messageChannel =
      AndroidNotificationChannel(
    'broka_messages',
    'Messages',
    description: 'New negotiation and chat messages',
    importance: Importance.high,
  );

  // Channel ID for incoming calls. Bumped again ('..._v2' -> '..._v3')
  // for the same reason it was bumped the first time: Android channel
  // settings, sound included, are immutable once the channel exists on a
  // device. Changing the sound on an existing ID is silently ignored for
  // every install that already created it, so switching from the bundled
  // tone to the user's ringtone requires a new ID or nobody with the app
  // already installed would ever hear the change.
  static const String callChannelId = 'broka_calls_v3';

  // The user's own ringtone, as chosen in Settings > Sound > Phone
  // ringtone. content://settings/system/ringtone is the documented,
  // stable URI for it (Settings.System.DEFAULT_RINGTONE_URI), so this
  // needs no platform code and follows the user if they change it later.
  //
  // This covers the case the in-app player cannot: the app backgrounded or
  // killed, where the notification is the only thing that happens.
  static const String _systemRingtoneUri = 'content://settings/system/ringtone';

  static final AndroidNotificationChannel _callChannel =
      AndroidNotificationChannel(
    callChannelId,
    'Incoming Calls',
    description: 'Incoming BROKA in-app calls',
    importance: Importance.max,
    playSound: true,
    sound: const UriAndroidNotificationSound(_systemRingtoneUri),
    // Put it on the ring stream, not the notification stream, so it
    // follows ringer volume and silent mode the way a call should.
    audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
    enableVibration: true,
  );

  Future<void> initialize({
    required GlobalKey<NavigatorState> navKey,
  }) async {
    navigatorKey = navKey;

    const androidInit =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    const settings =
        InitializationSettings(android: androidInit, iOS: iosInit);

    try {
      await _plugin.initialize(
        settings,
        onDidReceiveNotificationResponse: _onTap,
      );

      // Register channels (Android 8+). No-op elsewhere.
      final android = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await android?.createNotificationChannel(_messageChannel);
      await android?.createNotificationChannel(_callChannel);
      // Android 13+ runtime permission.
      await android?.requestNotificationsPermission();

      _ready = true;
      debugPrint('[Notifications] Local notifications ready.');
    } catch (e) {
      debugPrint('[Notifications] init failed: $e');
    }
  }

  int _idFor(String key) => key.hashCode & 0x7fffffff;

  void _onTap(NotificationResponse response) {
    final raw = response.payload;
    if (raw == null || raw.isEmpty) return;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      navigateFromPayload(data);
    } catch (e) {
      debugPrint('[Notifications] payload decode failed: $e');
    }
  }

  /// Handles an FCM data message that arrived while the app was in the
  /// foreground (FirebaseMessaging.onMessage in main.dart). FCM never
  /// auto-displays anything on any platform while the app is frontmost, so
  /// without this the user would see nothing at all for a foreground
  /// incoming call. Deliberately reuses showIncomingCall - the same call
  /// the poller already makes - rather than a separate foreground-only
  /// code path, so behavior is identical no matter which mechanism
  /// detected the call.
  Future<void> handleForegroundFcmMessage(Map<String, dynamic> data) async {
    if (data['type'] != 'incoming_call') return;
    final roomId = data['roomId'] as String?;
    if (roomId == null) return;
    await showIncomingCall(
      roomId: roomId,
      callerName: data['callerName'] as String? ?? 'Someone',
      listingName: data['listingName'] as String? ?? 'your listing',
      isVideo: data['callType'] == 'video',
      payload: data,
    );
  }

  /// Shared navigation logic for local-notification taps AND real FCM
  /// message taps (onMessageOpenedApp / getInitialMessage in main.dart) -
  /// same payload shape, same destinations, one call-routing mechanism.
  Future<void> navigateFromPayload(Map<String, dynamic> data) async {
    final nav = navigatorKey?.currentState;
    if (nav == null) return;
    final type = data['type'] as String?;

    if (type == 'incoming_call') {
      final listingId = data['listingId'] as String?;
      final buyerId = data['buyerId'] as String? ?? '';
      final iAmBuyer = ApiService.currentUserId != null &&
          ApiService.currentUserId == buyerId;
      if (listingId == null) return;
      // This may be tapped long after it was posted (app backgrounded or
      // fully killed in between), so the payload itself only carries
      // enough to identify *which listing* - re-check the call's live
      // status here and get a fresh, still-valid room-scoped call token
      // the same way the in-app poller does, rather than trusting
      // anything time-sensitive that was baked in when the notification
      // was first shown. If it's no longer pending (already answered on
      // another device, missed, or cancelled by the time this is tapped),
      // land on the conversation instead of a dead call screen.
      final callInfo = await ApiService.checkIncomingCall(listingId);
      final roomId = callInfo?['room_id'] as String?;
      // Whatever happens next, this notification has served its purpose -
      // take it down so it can't be tapped again after the call is gone.
      final postedRoomId = data['roomId'] as String?;
      if (postedRoomId != null) await cancelIncomingCall(postedRoomId);
      if (callInfo == null || roomId == null) {
        nav.pushNamed('/direct-chat', arguments: {
          'listingId': listingId,
          'role':      iAmBuyer ? 'buyer' : 'seller',
          'buyer_id':  buyerId,
        });
        return;
      }
      nav.pushNamed('/voip-call', arguments: {
        'roomId':      roomId,
        'userId':      ApiService.currentUserId ?? '',
        'callToken':   callInfo['call_token'] as String? ?? '',
        'isCaller':    false,
        'peerName':    callInfo['caller_name'] as String? ?? 'Someone',
        'listingName': data['listingName'] as String? ?? 'your listing',
        'listingId':   listingId,
        'buyerId':     buyerId,
        'callerRole':  iAmBuyer ? 'seller' : 'buyer',
        'callType':    callInfo['call_type'] as String? ?? 'audio',
        // Tapping an incoming-call notification IS answering the call - the
        // user has already made that decision. Without this the VoIP screen
        // opened on its own Accept/Decline prompt, so answering took two
        // taps, and because the notification had already stopped ringing by
        // then, the second screen sat silent while the user wondered why
        // nothing was happening.
        'autoAccept':  true,
      });
      return;
    }
    if (type == 'new_message') {
      final role = data['myRole'] as String? ?? 'buyer';
      nav.pushNamed('/direct-chat', arguments: {
        'listingId': data['listingId'] as String?,
        'role':      role,
        'buyer_id':  data['buyerId'] as String?,
      });
      return;
    }
  }

  /// Show a notification for a newly received message in a thread.
  Future<void> showNewMessage({
    required String fromName,
    required String preview,
    String threadKey = 'chat',
    Map<String, dynamic>? payload,
  }) async {
    if (!_ready) return;
    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'broka_messages',
        'Messages',
        channelDescription: 'New negotiation and chat messages',
        importance: Importance.high,
        priority: Priority.high,
        icon: '@mipmap/ic_launcher',
      ),
      iOS: DarwinNotificationDetails(),
    );
    try {
      await _plugin.show(
        _idFor(threadKey),
        fromName,
        preview,
        details,
        payload: payload != null ? jsonEncode(payload) : null,
      );
    } catch (e) {
      debugPrint('[Notifications] showNewMessage failed: $e');
    }
  }

  /// Show an incoming-call notification (more intrusive channel).
  /// Post the incoming-call notification AND start the ring.
  ///
  /// Ringing is owned here rather than left to each caller, because it was
  /// previously done in both places at once: negotiation_screen.dart called
  /// showIncomingCall (one-shot channel sound) and RingtoneService.play
  /// (looping bundled tone) on the same event, so an incoming call arrived
  /// as two different sounds overlapping.
  ///
  /// It also fixes the opposite gap. GlobalPollerService only ever posted
  /// the notification, so a call that arrived while the user was anywhere
  /// other than the chat thread got a single notification chirp rather than
  /// a ring - Android notification sounds do not loop, which is exactly why
  /// an in-app looping player exists in the first place.
  ///
  /// The channel keeps its own sound as the fallback for the case Dart
  /// cannot cover: app killed, notification posted from an FCM background
  /// isolate where the ringtone platform channel does not exist. When the
  /// in-app ring did start, the notification is posted silent so the two
  /// cannot double up.
  Future<void> showIncomingCall({
    required String roomId,
    required String callerName,
    required String listingName,
    bool isVideo = false,
    Map<String, dynamic>? payload,
    Duration ringFor = const Duration(seconds: 45),
  }) async {
    if (!_ready) return;

    bool ringing = false;
    try {
      ringing = await RingtoneService.instance.play(autoStopAfter: ringFor);
    } catch (e) {
      debugPrint('[Notifications] ringtone start failed: $e');
    }

    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        callChannelId,
        'Incoming Calls',
        channelDescription: 'Incoming BROKA in-app calls',
        importance: Importance.max,
        priority: Priority.max,
        category: AndroidNotificationCategory.call,
        fullScreenIntent: true,
        // Silent when the in-app ringer took the call, so the channel's
        // one-shot sound cannot play over a looping ringtone.
        playSound: !ringing,
        enableVibration: !ringing,
        // FIX (calling audit, 2026-09-14): without this, every poll tick
        // that re-posted the SAME ringing call (GlobalPollerService runs
        // every ~7s, and a call rings for up to 45) re-fired the channel's
        // alert - so the ringtone restarted from the top roughly six times
        // per call, producing a stuttering, broken-sounding ring instead of
        // a continuous one. onlyAlertOnce keeps the notification itself
        // updated while alerting exactly once.
        onlyAlertOnce: true,
        // Android treats an ongoing call notification as non-dismissible;
        // it's taken down explicitly by cancelIncomingCall() below when the
        // call is answered, declined, or stops ringing.
        ongoing: true,
        // Per-notification sound must match the channel's, or Android
        // ignores it and uses the channel's anyway - stated here so the
        // two cannot drift apart silently.
        sound: const UriAndroidNotificationSound(_systemRingtoneUri),
        audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
        // Take the stale entry down by itself if every other teardown path
        // is missed, rather than leaving a dead "Incoming call" in the tray.
        timeoutAfter: ringFor.inMilliseconds + 5000,
        icon: '@mipmap/ic_launcher',
      ),
      // iOS cannot play the system ringtone from a local notification -
      // only CallKit can, and that path is wired separately in
      // CallKitService. Default notification sound here rather than the
      // bundled tone, which was never the user's ringtone either.
      iOS: DarwinNotificationDetails(
        presentSound: !ringing,
      ),
    );
    try {
      await _plugin.show(
        // Room-scoped, not a fixed constant - two different incoming calls
        // (rare, but possible: two different people calling in quick
        // succession) get distinct notification slots instead of the
        // second silently replacing the first. The *same* call detected
        // through more than one path (FCM data message, poller) still
        // correctly collapses into one, since both resolve to this same id.
        _idFor('call_$roomId'),
        isVideo
            ? '📹 Incoming video call from $callerName'
            : '📞 Incoming call from $callerName',
        'About: $listingName',
        details,
        payload: payload != null ? jsonEncode(payload) : null,
      );
    } catch (e) {
      debugPrint('[Notifications] showIncomingCall failed: $e');
    }
  }

  /// Take down the incoming-call notification for [roomId].
  ///
  /// FIX (calling audit, 2026-09-14): nothing anywhere cancelled these.
  /// Once shown, the notification stayed in the tray after the call was
  /// answered, declined, cancelled by the caller, or timed out - and
  /// tapping it later re-ran navigateFromPayload, which (correctly) found
  /// no live call and dumped the user into the chat thread instead. On a
  /// device that missed a few calls the tray filled up with stale,
  /// permanently useless "Incoming call" entries.
  Future<void> cancelIncomingCall(String roomId) async {
    // Before the _ready guard, and unconditional: if showIncomingCall
    // started a ring, this is the symmetric teardown and it must run even
    // when the plugin never initialised. A ringtone left playing because
    // the notification plugin was not ready is the worst outcome available
    // here.
    try {
      await RingtoneService.instance.stop();
    } catch (_) {}
    if (!_ready) return;
    try {
      await _plugin.cancel(_idFor('call_$roomId'));
    } catch (e) {
      debugPrint('[Notifications] cancelIncomingCall failed: $e');
    }
  }

  // Kept for backward-compatibility with existing callers. Now surfaces a real
  // local notification instead of being a no-op.
  Future<void> sendCallNotification({
    required String targetUserId,
    required String roomId,
    required String callerName,
    required String listingName,
  }) async {
    await showIncomingCall(roomId: roomId, callerName: callerName, listingName: listingName);
  }
}

