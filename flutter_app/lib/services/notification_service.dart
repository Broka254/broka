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
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' show DartPluginRegistrant, IsolateNameServer;
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'api_service.dart';
import 'ringtone_service.dart';

/// Runs when Decline is pressed on an incoming-call notification.
///
/// Android delivers every action that doesn't open the app to a separate
/// background isolate, even while the app is running - so this must be a
/// top-level entry point, and it shares no state with the app. Whatever is
/// ringing belongs to the main isolate (RingtoneService and the
/// ringtone platform channel only exist there), so if the main isolate is
/// alive the decline is handed to it: declining from here would tell the
/// caller but leave this phone ringing for the rest of the 45 seconds.
/// Only when there is no main isolate - the app was killed and the
/// notification was posted from an FCM background isolate, whose sound
/// stops with the notification - does this isolate decline by itself.
@pragma('vm:entry-point')
Future<void> notificationActionBackgroundHandler(NotificationResponse response) async {
  final port = IsolateNameServer.lookupPortByName(NotificationService.callActionsPortName);
  if (port != null) {
    port.send({'actionId': response.actionId, 'payload': response.payload});
    return;
  }
  if (response.actionId != NotificationService.callDeclineActionId) return;
  final data = NotificationService.decodePayload(response.payload);
  if (data == null) return;
  DartPluginRegistrant.ensureInitialized();
  // This isolate can outlive many calls, and SharedPreferences caches per
  // isolate - without a reload it would send whatever access token it read
  // the first time, long since rotated by the app.
  try {
    await (await SharedPreferences.getInstance()).reload();
  } catch (_) {}
  await ApiService.loadSavedSession();
  await NotificationService.instance.declineFromPayload(data);
}

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

  static const AndroidNotificationChannel _callChannel =
      AndroidNotificationChannel(
    callChannelId,
    'Incoming Calls',
    description: 'Incoming BROKA in-app calls',
    importance: Importance.max,
    playSound: true,
    sound: UriAndroidNotificationSound(_systemRingtoneUri),
    // Put it on the ring stream, not the notification stream, so it
    // follows ringer volume and silent mode the way a call should.
    audioAttributesUsage: AudioAttributesUsage.notificationRingtone,
    enableVibration: true,
  );

  // Buttons on the incoming-call notification. Without them the only thing
  // the notification could do was open the app, so a call could not be
  // declined from the shade or lock screen at all, and answering meant
  // finding and tapping the notification body.
  static const String callAcceptActionId = 'call_accept';
  static const String callDeclineActionId = 'call_decline';
  static const String _darwinCallCategoryId = 'broka_incoming_call';

  /// Where notificationActionBackgroundHandler finds the main isolate.
  static const String callActionsPortName = 'broka_call_actions';
  ReceivePort? _actionsPort;

  // Rooms declined from this device. The poller re-posts a ringing call on
  // every tick until the server has recorded the decline, so a tick landing
  // between the tap and that request would put the call straight back up.
  final Set<String> _declinedRooms = {};

  // Android's FLAG_INSISTENT: the notification's sound repeats until the
  // notification is cancelled or opened. Used only when no in-app ringer
  // is running (see showIncomingCall).
  static const int _flagInsistent = 4;

  Future<void> initialize({
    required GlobalKey<NavigatorState> navKey,
  }) async {
    navigatorKey = navKey;

    const androidInit =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    final iosInit = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
      notificationCategories: [
        DarwinNotificationCategory(
          _darwinCallCategoryId,
          actions: [
            DarwinNotificationAction.plain(
              callAcceptActionId, 'Accept',
              options: {DarwinNotificationActionOption.foreground},
            ),
            DarwinNotificationAction.plain(
              callDeclineActionId, 'Decline',
              options: {DarwinNotificationActionOption.destructive},
            ),
          ],
        ),
      ],
    );
    final settings =
        InitializationSettings(android: androidInit, iOS: iosInit);

    try {
      await _plugin.initialize(
        settings,
        onDidReceiveNotificationResponse: _onTap,
        onDidReceiveBackgroundNotificationResponse:
            notificationActionBackgroundHandler,
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

  /// Main isolate only: receive Decline (and any other background action)
  /// forwarded by notificationActionBackgroundHandler. Not part of
  /// initialize(), which also runs in the FCM background isolate - claiming
  /// the name there would route actions to an isolate that has no ringer
  /// to stop and no navigator to open.
  void listenForCallActions() {
    if (_actionsPort != null) return;
    final port = ReceivePort();
    // A previous main isolate (hot restart, or an engine Android tore down)
    // can leave its dead port registered; registering fails while it is.
    IsolateNameServer.removePortNameMapping(callActionsPortName);
    IsolateNameServer.registerPortWithName(port.sendPort, callActionsPortName);
    port.listen((message) {
      if (message is! Map) return;
      handleResponse(
        actionId: message['actionId'] as String?,
        payload: message['payload'] as String?,
      );
    });
    _actionsPort = port;
  }

  static Map<String, dynamic>? decodePayload(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (e) {
      debugPrint('[Notifications] payload decode failed: $e');
      return null;
    }
  }

  void _onTap(NotificationResponse response) =>
      handleResponse(actionId: response.actionId, payload: response.payload);

  /// A tap on a notification or on one of its buttons. Accept and a tap on
  /// the body are the same thing - navigateFromPayload already answers.
  Future<void> handleResponse({String? actionId, String? payload}) async {
    final data = decodePayload(payload);
    if (data == null) return;
    if (actionId == callDeclineActionId) {
      await declineFromPayload(data);
      return;
    }
    await navigateFromPayload(data);
  }

  /// The app was started by the user acting on one of our notifications
  /// (for an incoming call: a tap on it, or Accept). That launch never
  /// reaches _onTap, and FirebaseMessaging.getInitialMessage() only knows
  /// about notifications FCM drew itself - the call notification is posted
  /// locally from a data-only push - so without this, answering a call
  /// that arrived while the app was closed just opened the home screen.
  Future<Map<String, dynamic>?> launchCallPayload() async {
    if (!_ready) return null;
    try {
      final details = await _plugin.getNotificationAppLaunchDetails();
      final response = details?.notificationResponse;
      if (details?.didNotificationLaunchApp != true || response == null) return null;
      if (response.actionId == callDeclineActionId) return null;
      final data = decodePayload(response.payload);
      return data?['type'] == 'incoming_call' ? data : null;
    } catch (e) {
      debugPrint('[Notifications] launch details unavailable: $e');
      return null;
    }
  }

  /// Decline an incoming call from its notification: stop ringing, take
  /// the notification down and tell the server, which ends the caller's
  /// ring straight away (POST /calls/log-result with "declined" is what the
  /// call screen's own Decline button records, and it hangs up the
  /// caller's socket).
  Future<void> declineFromPayload(Map<String, dynamic> data) async {
    final roomId = data['roomId'] as String?;
    final listingId = data['listingId'] as String?;
    if (roomId == null || roomId.isEmpty) return;
    _declinedRooms.add(roomId);
    await cancelIncomingCall(roomId);
    if (listingId == null) return;
    final buyerId = data['buyerId'] as String? ?? '';
    final iAmBuyer = ApiService.currentUserId != null &&
        ApiService.currentUserId == buyerId;
    await ApiService.logCallResult(
      roomId:     roomId,
      listingId:  listingId,
      buyerId:    buyerId,
      outcome:    'declined',
      // The caller's role, and I'm the callee.
      callerRole: iAmBuyer ? 'seller' : 'buyer',
      callType:   data['callType'] as String? ?? 'audio',
    );
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

    // FIX (calling audit, 2026-09-18): verify the call is STILL RINGING
    // before making the phone ring.
    //
    // A push says "this was true when it was sent", never "this is true
    // now". Nothing here checked, so any late-delivered push rang the
    // phone for a call that was already over - the caller gave up, the
    // user answered on another device, the ring simply timed out. The
    // backend now gives incoming-call pushes a short TTL
    // (CALL_PUSH_TTL_SECONDS in api/routers/calls.py) so FCM discards
    // rather than delivers a stale one, which is the only defence
    // available for the terminated-app case; foregrounded, the app has a
    // live session and can just ask, so it does. The same GET the poller
    // uses, and it is authoritative: /calls/pending only answers for a
    // session that is still `initiating` or `ringing`.
    //
    // Deliberately fail OPEN: only a definite "no call" suppresses the
    // ring. A network blip must not swallow a real incoming call, which
    // would be a far worse failure than an occasional late ring.
    final listingId = data['listingId'] as String?;
    if (listingId != null) {
      try {
        final live = await ApiService.checkIncomingCall(listingId);
        if (live == null) {
          debugPrint('[Notifications] stale incoming-call push for $roomId - not ringing');
          await cancelIncomingCall(roomId);
          return;
        }
      } catch (e) {
        debugPrint('[Notifications] could not verify call $roomId ($e) - ringing anyway');
      }
    }

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
    // False from the FCM background isolate. A ring started there belongs
    // to that isolate's RingtoneService, which nothing in the app can
    // reach: answering, declining or the caller hanging up all stop the
    // main isolate's ringer, so that one played on for its full 45 seconds
    // - over the call itself when the user answered. Without it the
    // notification rings instead, insistently, and stops when cancelled.
    bool ringInApp = true,
  }) async {
    if (!_ready) return;
    if (_declinedRooms.contains(roomId)) return;

    bool ringing = false;
    if (ringInApp) {
      try {
        ringing = await RingtoneService.instance.play(autoStopAfter: ringFor);
      } catch (e) {
        debugPrint('[Notifications] ringtone start failed: $e');
      }
    }

    // Everything Decline needs travels in the payload, because Decline can
    // run in an isolate that has only this to go on. The poller's payload
    // lacks the call type; declining an audio/video call records the
    // session's own type server-side either way.
    final fullPayload = <String, dynamic>{
      ...?payload,
      'type': 'incoming_call',
      'roomId': roomId,
      if (payload?['callType'] == null) 'callType': isVideo ? 'video' : 'audio',
    };

    final details = incomingCallDetails(ringing: ringing, ringFor: ringFor);
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
        payload: jsonEncode(fullPayload),
      );
    } catch (e) {
      debugPrint('[Notifications] showIncomingCall failed: $e');
    }
  }

  /// What the incoming-call notification looks like - its buttons, sound
  /// and lifetime. Separate from showIncomingCall so it can be checked
  /// without a device.
  @visibleForTesting
  static NotificationDetails incomingCallDetails({
    required bool ringing,
    required Duration ringFor,
  }) {
    return NotificationDetails(
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
        // A channel sound plays once. When it is the only sound (no in-app
        // ringer), make it repeat like a ringtone until the notification
        // is answered, declined or cancelled.
        additionalFlags:
            ringing ? null : Int32List.fromList(const [_flagInsistent]),
        actions: const [
          // Handled without opening the app - see
          // notificationActionBackgroundHandler.
          AndroidNotificationAction(
            callDeclineActionId, 'Decline',
            titleColor: Color(0xFFEF4444),
            cancelNotification: true,
          ),
          AndroidNotificationAction(
            callAcceptActionId, 'Accept',
            titleColor: Color(0xFF10B981),
            showsUserInterface: true,
            cancelNotification: true,
          ),
        ],
      ),
      // iOS cannot play the system ringtone from a local notification -
      // only CallKit can, and that path is wired separately in
      // CallKitService. Default notification sound here rather than the
      // bundled tone, which was never the user's ringtone either.
      iOS: DarwinNotificationDetails(
        presentSound: !ringing,
        categoryIdentifier: _darwinCallCategoryId,
      ),
    );
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

