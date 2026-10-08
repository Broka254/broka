// Missed calls and unread messages, as reported from a phone (2026-10-02):
// "notification for missed calls is not working", and nothing on Home said
// a message was waiting.
//
//  * The poller decided "already notified" by the last message's TEXT, so a
//    second missed call from the same person ("buyer|call|cancelled" again)
//    was never announced. It goes by the message's id now.
//  * A chat left open behind the phone's home screen silenced its thread's
//    notifications for as long as it stayed open.
//  * Nothing pushed a missed call to a closed app. The server does now, as a
//    notification Android draws itself, under the same tag as the app's own
//    missed-call notification - so one missed call is one notification.
import 'dart:convert';

import 'package:broka/services/api_service.dart';
import 'package:broka/services/global_poller_service.dart';
import 'package:broka/services/notification_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _json(Object? body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

Map<String, dynamic> _thread({
  required String lastId,
  String lastMessage = 'cancelled',
  String lastType = 'call',
  String lastRole = 'buyer',
  int unread = 0,
  String listingId = 'listing-1',
  String buyerId = 'buyer-1',
  Map<String, dynamic>? unreadMessage,
  Map<String, dynamic>? unreadMissedCall,
}) =>
    {
      'listing_id': listingId,
      'listing_name': 'Samsung A54',
      'buyer_id': buyerId,
      'my_role': 'seller',
      'counterpart_name': 'Ann',
      'last_message': lastMessage,
      'last_msg_type': lastType,
      'last_call_type': 'audio',
      'last_role': lastRole,
      'last_message_id': lastId,
      'unread': unread,
      'unread_message': unreadMessage,
      'unread_missed_call': unreadMissedCall,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final shown = <Map<String, dynamic>>[];
  final cancelled = <Object?>[];

  setUpAll(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    for (final name in ['xyz.luan/audioplayers', 'xyz.luan/audioplayers.global']) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
    messenger.setMockMethodCallHandler(
        const MethodChannel('dexterous.com/flutter/local_notifications'), (call) async {
      if (call.method == 'initialize') return true;
      if (call.method == 'show') {
        shown.add(Map<String, dynamic>.from(call.arguments as Map));
      }
      if (call.method == 'cancel') cancelled.add(call.arguments);
      return null;
    });
    await NotificationService.instance.initialize(
        navKey: GlobalKey<NavigatorState>(), requestPermission: false);
    debugDefaultTargetPlatformOverride = null;
  });

  late List<Map<String, dynamic>> inbox;
  final client = MockClient((req) async {
    if (req.url.path.startsWith('/negotiate/inbox/')) return _json(inbox);
    if (req.url.path.startsWith('/calls/pending/')) return _json({'detail': 'none'}, 404);
    return _json({'status': 'ok'});
  });

  setUp(() {
    shown.clear();
    cancelled.clear();
    // Past the first-ever sweep, which deliberately announces nothing.
    SharedPreferences.setMockInitialValues(
        {'global_poll_primed_v1': true, 'global_poll_hidden_primed_v1': true});
    ApiService.currentUserId = 'seller-1';
    GlobalPollerService.instance.appInForeground = true;
  });

  tearDown(() {
    GlobalPollerService.instance
        .markScreenInactive('listing-1', buyerId: 'buyer-1');
  });

  Future<void> sweep() =>
      http.runWithClient(() => GlobalPollerService.instance.catchUp(), () => client);

  String? tagOf(Map<String, dynamic> shownCall) =>
      (shownCall['platformSpecifics'] as Map?)?['tag'] as String?;

  test('a missed call is announced, under the tag the server push uses', () async {
    inbox = [_thread(lastId: 'call-1')];
    await sweep();
    expect(shown, hasLength(1));
    expect(shown.single['title'], 'Missed call from Ann');
    expect(shown.single['body'], 'About: Samsung A54');
    expect(shown.single['id'], 0);
    expect(tagOf(shown.single),
        NotificationService.missedCallTag('listing-1', 'buyer-1'));
    expect(tagOf(shown.single), 'missed_listing-1_buyer-1',
        reason: "the backend's _push_missed_call builds the same string");
  });

  test('a second missed call from the same person is announced too', () async {
    inbox = [_thread(lastId: 'call-1')];
    await sweep();
    inbox = [_thread(lastId: 'call-2')]; // same words: "cancelled"
    await sweep();
    expect(shown, hasLength(2));
    // And the same one is not announced twice.
    await sweep();
    expect(shown, hasLength(2));
  });

  test('the same words twice are two messages', () async {
    inbox = [_thread(lastId: 'm1', lastMessage: 'ok', lastType: 'text')];
    await sweep();
    inbox = [_thread(lastId: 'm2', lastMessage: 'ok', lastType: 'text')];
    await sweep();
    expect(shown.map((s) => s['body']), ['ok', 'ok']);
  });

  test('updating does not announce every last message again', () async {
    // What the previous build left behind: a text signature and no id.
    SharedPreferences.setMockInitialValues({
      'global_poll_primed_v1': true,
      'global_poll_seen_listing-1_buyer-1': 'buyer|text|see you',
    });
    inbox = [_thread(lastId: 'm7', lastMessage: 'see you', lastType: 'text')];
    await sweep();
    expect(shown, isEmpty);
  });

  test('a chat left open behind the home screen still notifies', () async {
    GlobalPollerService.instance.markScreenActive('listing-1', buyerId: 'buyer-1');
    GlobalPollerService.instance.appInForeground = false;
    inbox = [_thread(lastId: 'call-9')];
    await sweep();
    expect(shown, hasLength(1));
  });

  test('the chat on screen does not notify about itself', () async {
    GlobalPollerService.instance.markScreenActive('listing-1', buyerId: 'buyer-1');
    inbox = [_thread(lastId: 'm3', lastMessage: 'hi', lastType: 'text', unread: 1)];
    await sweep();
    expect(shown, isEmpty);
  });

  test("the unread total is every thread's unread count", () async {
    inbox = [
      _thread(lastId: 'a', lastType: 'text', lastMessage: 'x', unread: 2),
      _thread(lastId: 'b', lastType: 'text', lastMessage: 'y', unread: 3,
          listingId: 'listing-2', buyerId: 'buyer-2'),
      _thread(lastId: 'c', lastType: 'text', lastMessage: 'z', unread: 0,
          listingId: 'listing-3', buyerId: 'buyer-3'),
    ];
    await sweep();
    expect(GlobalPollerService.instance.unreadTotal.value, 5);
    GlobalPollerService.instance.stop();
    expect(GlobalPollerService.instance.unreadTotal.value, 0, reason: 'signed out');
  });

  test("the server's missed-call push in the foreground: one notification, ringing stopped",
      () async {
    await NotificationService.instance.handleForegroundFcmMessage({
      'type': 'missed_call',
      'roomId': 'room-1',
      'listingId': 'listing-1',
      'buyerId': 'buyer-1',
      'myRole': 'seller',
      'callType': 'video',
      'callerName': 'Ann',
      'listingName': 'Samsung A54',
    });
    expect(cancelled, isNotEmpty, reason: "the call's ringing notification comes down");
    expect(shown.single['title'], 'Missed video call from Ann');
    expect(tagOf(shown.single), 'missed_listing-1_buyer-1');
  });

  // Reported from phones (2026-10-07): "only missed call was displayed
  // despite there being an unread text message". The sweep announced each
  // thread's last row, and the call card hid the text before it.
  test('a missed call and the message before it are both announced', () async {
    inbox = [_thread(
      lastId: 'call-1', lastMessage: 'missed', unread: 2,
      unreadMessage: {'id': 'm1', 'content': 'Still available?', 'msg_type': 'text'},
      unreadMissedCall: {'id': 'call-1', 'call_type': 'voice'},
    )];
    await sweep();
    expect(shown.map((s) => s['title']), contains('Missed call from Ann'));
    expect(shown.map((s) => s['body']), contains('Still available?'));
    expect(shown, hasLength(2));
    await sweep();
    expect(shown, hasLength(2), reason: 'each announced once');
  });

  test('a message and the missed call before it are both announced', () async {
    inbox = [_thread(
      lastId: 'm2', lastMessage: 'Call me back', lastType: 'text', unread: 2,
      unreadMessage: {'id': 'm2', 'content': 'Call me back', 'msg_type': 'text'},
      unreadMissedCall: {'id': 'call-3', 'call_type': 'video'},
    )];
    await sweep();
    expect(shown.map((s) => s['body']), contains('Call me back'));
    expect(shown.map((s) => s['title']), contains('Missed video call from Ann'));
    expect(shown, hasLength(2));
    await sweep();
    expect(shown, hasLength(2));
  });

  test('what a push already announced is not announced again', () async {
    // Drawn by Android from the server's pushes while the app was away.
    await NotificationService.recordMessageAnnounced(
        {'listingId': 'listing-1', 'buyerId': 'buyer-1', 'messageId': 'm1'});
    await NotificationService.recordMessageAnnounced(
        {'listingId': 'listing-1', 'buyerId': 'buyer-1', 'messageId': 'call-1'});
    inbox = [_thread(
      lastId: 'call-1', lastMessage: 'missed', unread: 2,
      unreadMessage: {'id': 'm1', 'content': 'Still available?', 'msg_type': 'text'},
      unreadMissedCall: {'id': 'call-1', 'call_type': 'voice'},
    )];
    await sweep();
    expect(shown, isEmpty);
  });

  test("the first sweep of an install announces no thread's history", () async {
    SharedPreferences.setMockInitialValues({});
    inbox = [
      _thread(lastId: 'h1', lastMessage: 'old', lastType: 'text'),
      _thread(lastId: 'h2', lastMessage: 'older', lastType: 'text',
          listingId: 'listing-2', buyerId: 'buyer-2',
          unreadMissedCall: {'id': 'h3', 'call_type': 'voice'}),
    ];
    await sweep();
    expect(shown, isEmpty,
        reason: 'it silenced the first thread and announced the rest');
    inbox = [_thread(lastId: 'n1', lastMessage: 'new', lastType: 'text')];
    await sweep();
    expect(shown.map((s) => s['body']), ['new']);
  });

  // Review, 2026-10-08: the build before kept one id per thread (or, older
  // still, only the last message's text).
  test('after updating, a message handled by its text is not announced again',
      () async {
    SharedPreferences.setMockInitialValues({
      'global_poll_primed_v1': true,
      'global_poll_hidden_primed_v1': true,
      'global_poll_seen_listing-1_buyer-1': 'buyer|text|Call me back',
    });
    inbox = [_thread(
      lastId: 'm2', lastMessage: 'Call me back', lastType: 'text', unread: 2,
      unreadMessage: {'id': 'm2', 'content': 'Call me back', 'msg_type': 'text'},
      unreadMissedCall: {'id': 'c1', 'call_type': 'voice'},
    )];
    await sweep();
    await sweep();
    expect(shown.map((s) => s['title']), ['Missed call from Ann']);
  });

  test('after updating, a missed call the old build announced is not announced again',
      () async {
    // The old build announced c1, then m2, and kept only m2.
    SharedPreferences.setMockInitialValues({
      'global_poll_primed_v1': true,
      'global_poll_seen_id_listing-1_buyer-1': 'm2',
    });
    inbox = [_thread(
      lastId: 'm2', lastMessage: 'Call me back', lastType: 'text', unread: 2,
      unreadMissedCall: {'id': 'c1', 'call_type': 'voice'},
    )];
    await sweep();
    expect(shown, isEmpty);
    // A missed call after that is news.
    inbox = [_thread(
      lastId: 'm2', lastMessage: 'Call me back', lastType: 'text', unread: 3,
      unreadMissedCall: {'id': 'c2', 'call_type': 'voice'},
    )];
    await sweep();
    expect(shown.map((s) => s['title']), ['Missed call from Ann']);
  });

  test('an unread missed call is announced once however many messages follow',
      () async {
    for (var i = 0; i < 30; i++) {
      inbox = [_thread(
        lastId: 'm$i', lastMessage: 'message $i', lastType: 'text', unread: i + 2,
        unreadMissedCall: {'id': 'c1', 'call_type': 'voice'},
      )];
      await sweep();
    }
    expect(shown.where((s) => s['title'] == 'Missed call from Ann'), hasLength(1));
    expect(shown, hasLength(31));
  });

  test("an older message hidden behind Zeno's does not replace it", () async {
    inbox = [_thread(
      lastId: 'z1', lastMessage: 'Ann asks for the last price', lastType: 'text',
      lastRole: 'broker', unread: 1,
      unreadMessage: {'id': 'h1', 'content': 'Last price?', 'msg_type': 'text'},
    )];
    await sweep();
    expect(shown.map((s) => s['body']), ['Ann asks for the last price']);
  });

  testWidgets('tapping a missed call opens the chat with the buyer', (tester) async {
    final nav = GlobalKey<NavigatorState>();
    RouteSettings? opened;
    await tester.pumpWidget(MaterialApp(
      navigatorKey: nav,
      home: const SizedBox(),
      onGenerateRoute: (settings) {
        opened = settings;
        return MaterialPageRoute(settings: settings, builder: (_) => const SizedBox());
      },
    ));
    NotificationService.instance.navigatorKey = nav;
    await NotificationService.instance.navigateFromPayload({
      'type': 'missed_call',
      'listingId': 'listing-1',
      'buyerId': 'buyer-1',
      'myRole': 'seller',
    });
    await tester.pump();
    expect(opened?.name, '/direct-chat');
    expect(opened?.arguments, {
      'listingId': 'listing-1', 'role': 'seller', 'buyer_id': 'buyer-1',
    });
  });
}
