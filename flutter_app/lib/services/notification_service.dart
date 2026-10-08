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
// FCM is the delivery path for a closed app (main.dart initializes Firebase
// and registers the handlers; NOTIFICATIONS.md has the whole design). The
// server pushes:
//   incoming_call  data-only; drawn here, rung insistently, acknowledged
//                  to the server so the caller's screen says "Ringing"
//   call_over      data-only; another phone answered or declined - stop
//   missed_call    a notification Android draws itself
//   new_message    a notification Android draws itself, one per
//                  conversation (tag thread_<listing>_<buyer>)
//   deal / auction alerts, drawn by Android on the Updates channel
// Without a google-services.json in the build, Firebase.initializeApp()
// throws, main.dart catches it, and this service still works on what
// GlobalPollerService finds while the app is alive.
//
// One shared call-routing mechanism regardless of source: local-notification
// taps, FCM message taps (onMessageOpenedApp/getInitialMessage), foreground
// FCM messages, and the pollers all ultimately go through
// navigateFromPayload/showIncomingCall below.

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' show DartPluginRegistrant, IsolateNameServer;
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'active_call.dart';
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

  // Deal, payment and auction alerts. The server used to name a channel
  // the app never created ("broka_deals"), which Android files as
  // "Miscellaneous" - impossible for anyone to find and tune.
  static const AndroidNotificationChannel _updatesChannel =
      AndroidNotificationChannel(
    'broka_updates',
    'Deals & updates',
    description: 'Payments, deliveries, auctions and other deal updates',
    importance: Importance.high,
  );

  /// White-on-transparent status-bar icon (res/drawable/ic_stat_broka.xml).
  /// The launcher icon is a full-colour square, which Android draws in the
  /// status bar as a white blob.
  static const String smallIcon = '@drawable/ic_stat_broka';
  static const Color _accent = Color(0xFF8B5CF6);

  /// Set by GlobalPollerService: whether this conversation is on screen
  /// right now, in which case its messages are being read as they arrive
  /// and a notification for them would be noise.
  bool Function(String listingId, String? buyerId)? isThreadOnScreen;

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

  // Rooms declined, answered or ended on this device live in ActiveCall
  // (its settled set), with the call on screen: the poller re-posts a
  // ringing call on every tick until the server stops reporting it, so
  // without that record a tick landing between a tap and the server
  // catching up put the call straight back up.

  // A call stopped ringing because it is over (the caller gave up, it was
  // answered or declined on another phone, nobody answered). The callee's
  // call screen, if it is open and still ringing, listens and closes -
  // before, nothing could tell it, and a dead "Incoming call" screen stayed
  // up with Accept and Decline until the user dismissed it.
  final StreamController<String> _ringEnded = StreamController<String>.broadcast();
  Stream<String> get ringEnded => _ringEnded.stream;

  // Accept pressed on the notification of a call whose screen is already
  // open (still ringing): that screen answers, instead of a second one
  // opening on top of it.
  final StreamController<String> _answerRequests = StreamController<String>.broadcast();
  Stream<String> get answerRequests => _answerRequests.stream;

  // Android's FLAG_INSISTENT: the notification's sound repeats until the
  // notification is cancelled or opened. Used only when no in-app ringer
  // is running (see showIncomingCall).
  static const int _flagInsistent = 4;

  /// [requestPermission] is false from the FCM background isolate: there
  /// is no Activity there to ask from.
  Future<void> initialize({
    required GlobalKey<NavigatorState> navKey,
    bool requestPermission = true,
  }) async {
    navigatorKey = navKey;

    const androidInit = AndroidInitializationSettings(smallIcon);
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

    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    try {
      await _plugin.initialize(
        settings,
        onDidReceiveNotificationResponse: _onTap,
        onDidReceiveBackgroundNotificationResponse:
            notificationActionBackgroundHandler,
      );

      // Register channels (Android 8+). No-op elsewhere.
      await android?.createNotificationChannel(_messageChannel);
      await android?.createNotificationChannel(_updatesChannel);
      await android?.createNotificationChannel(_callChannel);

      _ready = true;
      debugPrint('[Notifications] Local notifications ready.');
    } catch (e) {
      debugPrint('[Notifications] init failed: $e');
      return;
    }

    // Android 13+ runtime permission - asked only once the plugin is ready,
    // and a failure here leaves it ready. It used to sit inside the try
    // above, before _ready: in the FCM background isolate there is no
    // Activity, the plugin throws asking for the permission, and _ready
    // stayed false, so the incoming-call notification for an app that was
    // closed was never posted. Posting without the permission is harmless
    // (Android just doesn't show it), so nothing else depends on the answer.
    if (!requestPermission) return;
    try {
      await android?.requestNotificationsPermission();
    } catch (e) {
      debugPrint('[Notifications] permission request failed: $e');
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

  /// A tap on a notification or on one of its buttons.
  Future<void> handleResponse({String? actionId, String? payload}) async {
    final data = decodePayload(payload);
    if (data == null) return;
    if (actionId == callDeclineActionId) {
      await declineFromPayload(data);
      return;
    }
    await navigateFromPayload({
      ...data,
      'answer': actionId == callAcceptActionId,
    });
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
      // A message or missed-call notification the app posted itself opens
      // its conversation, as the server's own pushes do.
      final type = data?['type'];
      if (type == 'new_message' || type == 'missed_call') return data;
      if (type != 'incoming_call') return null;
      // Also how a locked phone's fullScreenIntent launches the app - only
      // Accept answers; see navigateFromPayload.
      return {...data!, 'answer': response.actionId == callAcceptActionId};
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
    await callEnded(roomId);
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
    if (data['type'] == 'missed_call') {
      // A notification push, which the phone draws by itself only while
      // the app is NOT in front - in front, it arrives here instead.
      await showMissedCallFromPush(data);
      return;
    }
    if (data['type'] == 'call_over') {
      final roomId = data['roomId'] as String?;
      if (roomId != null && roomId.isNotEmpty) await callEnded(roomId);
      return;
    }
    if (data['type'] == 'new_message') {
      await showMessageFromPush(data);
      return;
    }
    if (data['type'] != 'incoming_call') return;
    final roomId = data['roomId'] as String?;
    if (roomId == null) return;
    await _endReplacedCall(data);
    // On a call, or done with this one: nothing rings, and the server is
    // not told this phone is ringing.
    if (!ActiveCall.instance.shouldRing(roomId)) return;

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
      final live = await ApiService.checkIncomingCallStatus(listingId);
      // Only the server's answer ends the call here - "couldn't tell" rings.
      // The listing's ringing call is another room when the caller has
      // dialled again since: this push is for the replaced call.
      if (live.known && live.call?['room_id'] != roomId) {
        debugPrint('[Notifications] stale incoming-call push for $roomId - not ringing');
        await callEnded(roomId);
        return;
      }
      if (!live.known) {
        debugPrint('[Notifications] could not verify call $roomId - ringing anyway');
      }
    }

    await showIncomingCall(
      roomId: roomId,
      callerName: data['callerName'] as String? ?? 'Someone',
      listingName: data['listingName'] as String? ?? 'your listing',
      isVideo: data['callType'] == 'video',
      payload: data,
    );
    await acknowledgeIncomingCall(roomId, data['callToken'] as String?);
  }

  /// The caller dialled again while their first call was still ringing:
  /// the server ends that one (calls.py _finish_replaced) and names it in
  /// the new call's push. Its ring is taken down here, before the new one
  /// starts - the server's call_over push for it can arrive after this
  /// one, or not at all, and two rings for one caller is what users saw.
  Future<void> _endReplacedCall(Map<String, dynamic> data) async {
    final replaced = data['replacesRoomId'] as String?;
    if (replaced == null || replaced.isEmpty || replaced == data['roomId']) return;
    await callEnded(replaced);
  }

  /// Tell the server this phone is ringing (the caller's "Ringing"), and
  /// stop at once if it answers that the call is already over - a push
  /// that arrived late, or a call answered on another phone.
  Future<void> acknowledgeIncomingCall(String roomId, String? callToken) async {
    if (callToken == null || callToken.isEmpty) return;
    final result = await ApiService.reportCallAlerted(roomId, callToken);
    if (result == CallAlertResult.over) {
      debugPrint('[Notifications] call $roomId is over - not ringing');
      await callEnded(roomId);
    }
  }

  /// Every push that reaches the FCM background isolate - the app is in the
  /// background or not running at all. main.dart's
  /// firebaseMessagingBackgroundHandler hands them here; there is no
  /// navigator and no main-isolate state, only this service and the
  /// server.
  static Future<void> handleBackgroundMessage(Map<String, dynamic> data) async {
    final type = data['type'] as String?;
    final svc = NotificationService.instance;
    switch (type) {
      case 'missed_call':
      case 'call_over':
        // missed_call is drawn by Android itself; call_over draws nothing.
        // Either way the call's ringing notification, posted from the
        // incoming-call push, may still be up and ringing - and nothing
        // else can tell a closed app that the call stopped.
        if (type == 'missed_call') await recordMessageAnnounced(data);
        final roomId = data['roomId'] as String?;
        if (roomId == null || roomId.isEmpty) return;
        await svc.initialize(
            navKey: GlobalKey<NavigatorState>(), requestPermission: false);
        await svc.callEnded(roomId);
        return;
      case 'incoming_call':
        // A fresh, throwaway navigator key - nothing in this isolate ever
        // attaches a real Navigator to it, and nothing needs to: showing
        // the notification is all that happens here. A tap on it is
        // handled in the main isolate once the app is in front.
        final roomId = data['roomId'] as String? ?? '';
        await svc.initialize(
            navKey: GlobalKey<NavigatorState>(), requestPermission: false);
        await svc._endReplacedCall(data);
        // The app's call screen may be open (the app is only in the
        // background): never ring over a call under way, or for the call
        // already on screen. The main isolate saves which call that is.
        if (!await ActiveCall.savedAllowsRinging(roomId)) return;
        // Ring first: the acknowledgement is a network round trip, and a
        // call must never wait on one to start ringing.
        await svc.showIncomingCall(
          roomId: roomId,
          callerName: data['callerName'] as String? ?? 'Someone',
          listingName: data['listingName'] as String? ?? 'your listing',
          isVideo: data['callType'] == 'video',
          payload: data,
          // Nothing outside this isolate could stop a ringer started here -
          // see showIncomingCall's ringInApp.
          ringInApp: false,
        );
        await svc.acknowledgeIncomingCall(roomId, data['callToken'] as String?);
        return;
      case 'new_message':
        // Android drew it from the push already. Record it as announced,
        // so the app's own sweep doesn't announce it a second time when
        // the app next runs.
        await recordMessageAnnounced(data);
        return;
    }
  }

  /// The key GlobalPollerService keeps a thread's announced message ids
  /// under. Shared, so a message announced by a push is not announced
  /// again by the sweep, and the reverse.
  static String seenMessageKey(String listingId, String? buyerId) =>
      'global_poll_seen_id_${listingId}_${buyerId ?? ''}';

  /// How many of a thread's announced ids are kept. More than one, because
  /// a thread can have two things to announce at once - a missed call and
  /// the message before it - and with one slot each announcement erased
  /// the other, which was then announced again on the next sweep.
  static const int _seenIdsKept = 20;

  /// The ids announced for a thread, newest last. Stored comma-separated:
  /// a value written by an older build (one id, no comma) reads as a list
  /// of one.
  static List<String> announcedIds(
          SharedPreferences prefs, String listingId, String? buyerId) =>
      (prefs.getString(seenMessageKey(listingId, buyerId)) ?? '')
          .split(',')
          .where((id) => id.isNotEmpty)
          .toList();

  static bool wasAnnounced(SharedPreferences prefs, String listingId,
          String? buyerId, String id) =>
      announcedIds(prefs, listingId, buyerId).contains(id);

  static Future<void> markAnnounced(SharedPreferences prefs, String listingId,
      String? buyerId, String id) async {
    if (id.isEmpty) return;
    final ids = announcedIds(prefs, listingId, buyerId)..remove(id);
    ids.add(id);
    final kept = ids.length > _seenIdsKept
        ? ids.sublist(ids.length - _seenIdsKept)
        : ids;
    await prefs.setString(seenMessageKey(listingId, buyerId), kept.join(','));
  }

  /// A message or missed call a push announced - the phone drew it - is
  /// not announced again by the app's sweep.
  static Future<void> recordMessageAnnounced(Map<String, dynamic> data) async {
    final listingId = data['listingId'] as String?;
    final messageId = data['messageId'] as String?;
    if (listingId == null || messageId == null || messageId.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      // The other isolate may have written since this copy was loaded.
      await prefs.reload();
      await markAnnounced(
          prefs, listingId, data['buyerId'] as String?, messageId);
    } catch (_) {}
  }

  /// The server's message push with the app in front, where Android does
  /// not draw it: shown here, unless that conversation is on screen.
  Future<void> showMessageFromPush(Map<String, dynamic> data) async {
    final listingId = data['listingId'] as String?;
    if (listingId == null || listingId.isEmpty) return;
    final buyerId = data['buyerId'] as String?;
    final messageId = data['messageId'] as String?;
    final prefs = await SharedPreferences.getInstance();
    final onScreen = isThreadOnScreen?.call(listingId, buyerId) ?? false;
    if (!onScreen &&
        messageId != null &&
        wasAnnounced(prefs, listingId, buyerId, messageId)) {
      return; // the sweep got there first
    }
    if (messageId != null) {
      await markAnnounced(prefs, listingId, buyerId, messageId);
    }
    if (onScreen) return;

    final sender = data['senderName'] as String? ?? 'New message';
    final listingName = (data['listingName'] as String? ?? '').trim();
    final count = int.tryParse('${data['count'] ?? ''}') ?? 1;
    final preview = data['preview'] as String? ?? '';
    await showNewMessage(
      fromName: data['title'] as String? ??
          (listingName.isEmpty ? sender : '$sender · $listingName'),
      preview: data['body'] as String? ??
          (count > 1 ? '$count new messages · $preview' : preview),
      listingId: listingId,
      buyerId: buyerId,
      payload: {
        'type': 'new_message',
        'listingId': listingId,
        'buyerId': buyerId,
        'myRole': data['myRole'],
        if (data['screen'] == 'zeno') 'screen': 'zeno',
      },
    );
  }

  /// POST /calls/initiate refused a call (ApiService.initiateCall's
  /// {'refused': ...}): the person is on another call, or this user is.
  /// The server's reason is shown - it used to be "Couldn't start the
  /// call", or worse, a second call rang over the first. CALL_CROSSED is
  /// the person being called calling this user at the same moment: their
  /// call is answered instead, since both of them want to talk.
  Future<void> handleCallRefused(
    ScaffoldMessengerState? messenger, Map<String, dynamic> refused,
  ) async {
    final call = refused['call'];
    if (refused['code'] == 'CALL_CROSSED' && call is Map) {
      await navigateFromPayload({
        'type': 'incoming_call',
        'roomId': call['room_id'],
        'listingId': call['listing_id'],
        'buyerId': call['buyer_id'],
        'listingName': call['listing_name'],
        'answer': true,
      });
      return;
    }
    messenger?.showSnackBar(SnackBar(
      content: Text(refused['message'] as String? ??
          "They're on another call. Try again in a moment."),
    ));
  }

  /// Shared navigation logic for local-notification taps AND real FCM
  /// message taps (onMessageOpenedApp / getInitialMessage in main.dart) -
  /// same payload shape, same destinations, one call-routing mechanism.
  /// An incoming call is answered only when `data['answer']` is true: the
  /// user pressed Accept (here or in CallKit).
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
      final tappedRoom = data['roomId'] as String?;
      final active = ActiveCall.instance;
      if (tappedRoom != null && active.roomId == tappedRoom) {
        // That call's screen is already open. It used to open a second
        // time on top of itself - two call screens, two connections to one
        // call, each replacing the other's on the server. Accept on the
        // notification answers it on the screen that is there.
        await _cancelCallNotification(tappedRoom);
        if (data['answer'] == true) _answerRequests.add(tappedRoom);
        return;
      }
      if (active.onCall && active.answered) {
        // On another call: this one is not opened over it.
        if (tappedRoom != null) await _cancelCallNotification(tappedRoom);
        return;
      }
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
        'peerId':      callInfo['caller_id'] as String?,
        'listingName': data['listingName'] as String? ?? 'your listing',
        'listingId':   listingId,
        'buyerId':     buyerId,
        'callerRole':  iAmBuyer ? 'seller' : 'buyer',
        'callType':    callInfo['call_type'] as String? ?? 'audio',
        // Only the Accept button answers. A tap on the notification body
        // arrives here looking exactly like the notification's
        // fullScreenIntent, which Android fires by itself when a call
        // comes in on a locked phone - so answering on "tapped" answered
        // every such call with the microphone live before anyone touched
        // the phone. Otherwise the call screen opens ringing, with its own
        // Accept and Decline.
        'autoAccept':  data['answer'] == true,
      });
      return;
    }
    // "Deal Complete" (api/core/push_subscribers.py, on release) asks the
    // buyer for a review and names the review screen; it opened nothing.
    // The review screen fills in the seller and listing from the deal.
    if (type == 'deal_status' && data['screen'] == 'review') {
      final dealId = data['deal_id'] as String?;
      if (dealId == null || dealId.isEmpty) return;
      nav.pushNamed('/review', arguments: {'deal_id': dealId});
      return;
    }
    if (type == 'new_message' || type == 'missed_call') {
      final role = data['myRole'] as String? ?? 'buyer';
      // A message from Zeno is read in Zeno's room; everything else - the
      // other person's messages, a missed call - in the direct chat.
      final route = data['screen'] == 'zeno' ? '/negotiate' : '/direct-chat';
      nav.pushNamed(route, arguments: {
        'listingId': data['listingId'] as String?,
        'role':      role,
        'buyer_id':  data['buyerId'] as String?,
      });
      return;
    }
  }

  /// The tag a conversation's message notification is posted under - the
  /// same string the server's message push uses (api/core/message_push.py
  /// thread_tag). Android keys a notification on (tag, id), and FCM draws
  /// its tagged ones with id 0, so a conversation is one notification
  /// whether the push, the foreground handler or the sweep posted it, and
  /// each new message updates it rather than stacking another.
  static String threadTag(String listingId, String? buyerId) =>
      'thread_${listingId}_${buyerId ?? ''}';

  /// Show a notification for a newly received message in a thread.
  Future<void> showNewMessage({
    required String fromName,
    required String preview,
    required String listingId,
    String? buyerId,
    Map<String, dynamic>? payload,
  }) async {
    if (!_ready) return;
    final tag = threadTag(listingId, buyerId);
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        _messageChannel.id,
        _messageChannel.name,
        channelDescription: _messageChannel.description,
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.message,
        tag: tag,
        icon: smallIcon,
        color: _accent,
        styleInformation: BigTextStyleInformation(preview),
      ),
      iOS: DarwinNotificationDetails(threadIdentifier: tag),
    );
    try {
      await _plugin.show(
        // 0 with the tag: the pair FCM draws the server's push under.
        0,
        fromName,
        preview,
        details,
        payload: payload != null ? jsonEncode(payload) : null,
      );
    } catch (e) {
      debugPrint('[Notifications] showNewMessage failed: $e');
    }
  }

  /// Take a conversation's message notification down - it has been opened,
  /// so what it announced is being read.
  Future<void> cancelThread(String listingId, String? buyerId) async {
    if (!_ready) return;
    try {
      await _plugin.cancel(0, tag: threadTag(listingId, buyerId));
    } catch (e) {
      debugPrint('[Notifications] cancelThread failed: $e');
    }
  }

  /// The tag a thread's missed-call notification is posted under. The
  /// server's missed-call push (calls.py's _push_missed_call), which the
  /// phone draws by itself when the app is closed, uses the same tag - and
  /// Android replaces a notification with the same (tag, id) pair, FCM
  /// drawing its tagged ones with id 0. So a missed call is one
  /// notification whether the push, the foreground handler or the inbox
  /// poller noticed it, or all three.
  static String missedCallTag(String listingId, String? buyerId) =>
      'missed_${listingId}_${buyerId ?? ''}';

  /// "Missed call from Ann". Tapping it opens the chat, where the call
  /// card has a Call back button.
  Future<void> showMissedCall({
    required String listingId,
    required String? buyerId,
    required String myRole,
    required String callerName,
    bool isVideo = false,
    String? listingName,
    String? roomId,
  }) async {
    // A call that is over: its ringing notification, if one is still up
    // (an app that was closed has no other way to learn it stopped), goes.
    if (roomId != null && roomId.isNotEmpty) await callEnded(roomId);
    if (!_ready) return;
    final details = NotificationDetails(
      android: AndroidNotificationDetails(
        _messageChannel.id,
        _messageChannel.name,
        channelDescription: _messageChannel.description,
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.missedCall,
        tag: missedCallTag(listingId, buyerId),
        icon: smallIcon,
        color: _accent,
      ),
      iOS: const DarwinNotificationDetails(),
    );
    try {
      await _plugin.show(
        // 0 with the tag: the pair FCM draws the server's push under.
        0,
        'Missed ${isVideo ? 'video ' : ''}call from $callerName',
        (listingName != null && listingName.isNotEmpty)
            ? 'About: $listingName'
            : 'Tap to call back',
        details,
        payload: jsonEncode({
          'type': 'missed_call',
          'listingId': listingId,
          'buyerId': buyerId,
          'myRole': myRole,
        }),
      );
    } catch (e) {
      debugPrint('[Notifications] showMissedCall failed: $e');
    }
  }

  /// The server's missed-call push, when the app has to draw it itself.
  Future<void> showMissedCallFromPush(Map<String, dynamic> data) async {
    final listingId = data['listingId'] as String?;
    if (listingId == null || listingId.isEmpty) return;
    // Its call card, so the inbox sweep does not announce it again.
    await recordMessageAnnounced(data);
    await showMissedCall(
      listingId: listingId,
      buyerId: data['buyerId'] as String?,
      myRole: data['myRole'] as String? ?? 'buyer',
      callerName: data['callerName'] as String? ?? 'Someone',
      isVideo: data['callType'] == 'video',
      listingName: data['listingName'] as String?,
      roomId: data['roomId'] as String?,
    );
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
    // On a call, or done with this one (see ActiveCall.shouldRing). Every
    // path that rings comes through here.
    if (!ActiveCall.instance.shouldRing(roomId)) return;

    bool ringing = false;
    if (ringInApp) {
      try {
        ringing = await RingtoneService.instance
            .play(autoStopAfter: ringFor, roomId: roomId);
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
        icon: smallIcon,
        color: _accent,
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
    //
    // Only this call's ring, though: one ringer serves every call, and a
    // teardown for a call that ended used to silence the call ringing now.
    try {
      await RingtoneService.instance.stopFor(roomId);
    } catch (_) {}
    await _cancelCallNotification(roomId);
  }

  Future<void> _cancelCallNotification(String roomId) async {
    if (!_ready) return;
    try {
      await _plugin.cancel(_idFor('call_$roomId'));
    } catch (e) {
      debugPrint('[Notifications] cancelIncomingCall failed: $e');
    }
  }

  /// [roomId] has stopped ringing for good - over, declined, or answered
  /// elsewhere. Its notification and ring go, it never rings again on this
  /// phone, and a call screen still ringing for it closes (see [ringEnded]).
  Future<void> callEnded(String roomId) async {
    if (roomId.isEmpty) return;
    ActiveCall.instance.settle(roomId);
    await cancelIncomingCall(roomId);
    _ringEnded.add(roomId);
  }

  static const String _backgroundAskKey = 'asked_background_delivery_v1';

  /// Once per install, on Android, once pushes work: ask to leave BROKA out
  /// of battery optimisation, so a call rings and messages arrive with the
  /// app closed. On the Android builds common in Kenya (Tecno, Infinix,
  /// Xiaomi...) an optimised app that has been closed for a while often
  /// gets its pushes late or never. Explained first, in BROKA's words; the
  /// system dialog alone ("Let app always run in background?") reads like
  /// a battery drain with no reason given.
  Future<void> maybeAskForBackgroundDelivery() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(_backgroundAskKey) ?? false) return;
      if (await Permission.ignoreBatteryOptimizations.isGranted) {
        await prefs.setBool(_backgroundAskKey, true);
        return;
      }
      final nav = navigatorKey?.currentState;
      if (nav == null) return;
      // Never over a call, or before the user is past sign-in.
      String? route;
      nav.popUntil((r) {
        route = r.settings.name;
        return true;
      });
      if (route == '/voip-call' || route == '/splash' || route == '/auth') return;
      await prefs.setBool(_backgroundAskKey, true);
      final context = navigatorKey?.currentContext;
      if (context == null || !context.mounted) return;
      final allow = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Get calls when BROKA is closed'),
          content: const Text(
            'Let BROKA run in the background so calls ring and messages '
            'arrive even when the app is closed. It only wakes up when '
            'someone calls or writes to you.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Not now'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Allow'),
            ),
          ],
        ),
      );
      if (allow == true) await Permission.ignoreBatteryOptimizations.request();
    } catch (e) {
      debugPrint('[Notifications] background-delivery prompt failed: $e');
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

