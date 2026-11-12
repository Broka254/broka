// Reply and Mark as read on a message notification (2026-11-11).
//
// Asked for: "when someone receives a sent message and sees it as a
// notification the notification should have the option of 'reply' which
// allows the user to reply without opening the app and option of 'mark as
// read' also without opening the app."
//
//  * The other person's message carries both buttons; Zeno's room and the
//    "your reply was not sent" note carry none.
//  * Reply sends what was typed into the notification, and Mark as read
//    reads the conversation, with the thread token the push carried - a
//    closed app's access token has usually expired by then, and renewing it
//    from a background isolate races the app's own renewal. Both take the
//    notification down.
//  * A reply that could not go comes back as a notification with its words
//    in it - never lost without a word.
//  * A pushed message is marked delivered with the same token: the dull
//    double tick no longer depends on a session the phone may not have.
import 'dart:convert';

import 'package:broka/services/active_call.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final shown = <Map<String, dynamic>>[];
  final cancelled = <Object?>[];
  final requests = <http.Request>[];
  late http.Response Function(http.Request) route;
  final client = MockClient((req) async {
    requests.add(req);
    return route(req);
  });

  Future<T> withClient<T>(Future<T> Function() body) => http.runWithClient(body, () => client);

  setUpAll(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    for (final name in ['xyz.luan/audioplayers', 'xyz.luan/audioplayers.global',
        'com.broka.app/ringtone']) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
    messenger.setMockMethodCallHandler(
        const MethodChannel('dexterous.com/flutter/local_notifications'), (call) async {
      if (call.method == 'initialize') return true;
      if (call.method == 'show') shown.add(Map<String, dynamic>.from(call.arguments as Map));
      if (call.method == 'cancel') cancelled.add(call.arguments);
      if (call.method == 'areNotificationsEnabled') return true;
      return null;
    });
  });

  tearDownAll(() => debugDefaultTargetPlatformOverride = null);

  setUp(() async {
    shown.clear();
    cancelled.clear();
    requests.clear();
    // Signed out in memory, as a closed app's background isolate starts.
    SharedPreferences.setMockInitialValues({});
    await ApiService.loadSavedSession();
    ActiveCall.instance.reset();
    route = (_) => _json({'status': 'ok'});
    await NotificationService.instance.initialize(
        navKey: GlobalKey<NavigatorState>(), requestPermission: false);
  });

  /// What a message notification's payload holds (the push's data, as
  /// NotificationService draws it).
  Map<String, dynamic> payload({String? threadToken = 'thread-token-1'}) => {
        'type': 'new_message',
        'listingId': 'listing-1',
        'buyerId': 'buyer-1',
        'myRole': 'seller',
        if (threadToken != null) 'threadToken': threadToken,
      };

  List<http.Request> posts(String action) => requests
      .where((r) => r.method == 'POST' && r.url.path == '/negotiate/notification/$action')
      .toList();

  String? tagOf(Object? cancelArgs) => (cancelArgs as Map?)?['tag'] as String?;

  group('the buttons', () {
    test("the other person's message has Reply and Mark as read", () {
      final details = NotificationService.messageDetails(tag: 't', preview: 'Still available?');
      final actions = details.android!.actions!;
      expect(actions.map((a) => a.id), [
        NotificationService.messageReplyActionId,
        NotificationService.messageReadActionId,
      ]);
      expect(actions.map((a) => a.title), ['Reply', 'Mark as read']);
      expect(actions.first.inputs, isNotEmpty, reason: 'the reply is typed into the notification');
      expect(actions.every((a) => !a.showsUserInterface), isTrue,
          reason: 'neither opens the app');
      expect(
          NotificationService.messageDetails(tag: 't', preview: 'p', actions: false)
              .android!
              .actions,
          isNull);
    });

    test("a conversation's notification has them; Zeno's room does not", () async {
      await NotificationService.instance.showNewMessage(
          fromName: 'Ann', preview: 'Still available?', listingId: 'listing-1',
          buyerId: 'buyer-1', payload: payload());
      await NotificationService.instance.showNewMessage(
          fromName: 'Zeno', preview: 'Ann offered KES 30,000', listingId: 'listing-1',
          buyerId: 'buyer-1', payload: {...payload(), 'screen': 'zeno'});
      List? actionsOf(Map<String, dynamic> n) =>
          (n['platformSpecifics'] as Map?)?['actions'] as List?;
      expect(actionsOf(shown[0]), hasLength(2));
      expect(actionsOf(shown[1]), anyOf(isNull, isEmpty),
          reason: "Zeno's messages are read in Zeno's room");
    });
  });

  group('Reply', () {
    test('sends what was typed, with the thread token, and takes the notification down',
        () async {
      await withClient(() => NotificationService.instance.handleResponse(
            actionId: NotificationService.messageReplyActionId,
            payload: jsonEncode(payload()),
            input: '  Yes, still available  ',
          ));
      final sent = posts('reply').single;
      final body = jsonDecode(sent.body) as Map<String, dynamic>;
      expect(body['thread_token'], 'thread-token-1');
      expect(body['content'], 'Yes, still available');
      expect((body['client_msg_id'] as String?) ?? '', isNotEmpty,
          reason: 'a retried reply is stored once');
      expect(sent.headers.containsKey('Authorization'), isFalse,
          reason: 'a closed app has no live access token - the thread token is the proof');
      expect(cancelled.map(tagOf), contains(NotificationService.threadTag('listing-1', 'buyer-1')));
      expect(shown, isEmpty, reason: 'it went - nothing to say');
    });

    test('a reply that could not go comes back with its words', () async {
      route = (req) => req.url.path == '/negotiate/notification/reply'
          ? _json({'detail': 'Server error'}, 503)
          : _json({'status': 'ok'});
      await withClient(() => NotificationService.instance.handleResponse(
            actionId: NotificationService.messageReplyActionId,
            payload: jsonEncode(payload()),
            input: 'Nitakuja kesho',
          ));
      final note = shown.single;
      expect(note['title'], 'Your reply was not sent');
      expect(note['body'], contains('Nitakuja kesho'));
      expect((note['platformSpecifics'] as Map?)?['actions'], anyOf(isNull, isEmpty),
          reason: 'a note about a reply is not a message to reply to');
    });

    test('an empty reply sends nothing', () async {
      await withClient(() => NotificationService.instance.handleResponse(
            actionId: NotificationService.messageReplyActionId,
            payload: jsonEncode(payload()),
            input: '   ',
          ));
      expect(posts('reply'), isEmpty);
      expect(shown, isEmpty);
    });

    test('a notification the app drew itself (no token) replies through the session',
        () async {
      SharedPreferences.setMockInitialValues(
          {'auth_token': 'test-token', 'user_id': 'seller-1'});
      await ApiService.loadSavedSession();
      try {
        await withClient(() => NotificationService.instance.handleResponse(
              actionId: NotificationService.messageReplyActionId,
              payload: jsonEncode(payload(threadToken: null)),
              input: 'Sawa',
            ));
        expect(posts('reply'), isEmpty);
        final direct = requests.singleWhere((r) => r.url.path == '/negotiate/direct-message');
        final body = jsonDecode(direct.body) as Map<String, dynamic>;
        expect(body['content'], 'Sawa');
        expect(body['listing_id'], 'listing-1');
        expect(body['sender_role'], 'seller');
        expect(requests.where((r) => r.url.path == '/negotiate/listing-1/mark-read'),
            hasLength(1),
            reason: 'nobody answers what they have not read');
      } finally {
        SharedPreferences.setMockInitialValues({});
        await ApiService.loadSavedSession();
      }
    });
  });

  group('Mark as read', () {
    test('reads the conversation with the thread token and takes the notification down',
        () async {
      // The app wires it to the poller (the Inbox's sweep).
      expect(GlobalPollerService.instance, isNotNull);
      expect(NotificationService.instance.onThreadRead, isNotNull);
      final wired = NotificationService.instance.onThreadRead;
      var nudged = 0;
      NotificationService.instance.onThreadRead = () => nudged++;
      try {
        await withClient(() => NotificationService.instance.handleResponse(
              actionId: NotificationService.messageReadActionId,
              payload: jsonEncode(payload()),
            ));
      } finally {
        NotificationService.instance.onThreadRead = wired;
      }
      final sent = posts('read').single;
      expect(jsonDecode(sent.body), {'thread_token': 'thread-token-1'});
      expect(cancelled.map(tagOf), contains(NotificationService.threadTag('listing-1', 'buyer-1')));
      expect(nudged, 1, reason: "the Inbox's unread count catches up at once");
    });

    test('a refused token falls back to the session when there is one', () async {
      route = (req) => req.url.path == '/negotiate/notification/read'
          ? _json({'detail': 'Sign in again'}, 401)
          : _json({'status': 'ok'});
      SharedPreferences.setMockInitialValues(
          {'auth_token': 'test-token', 'user_id': 'seller-1'});
      await ApiService.loadSavedSession();
      try {
        await withClient(() => NotificationService.instance.handleResponse(
              actionId: NotificationService.messageReadActionId,
              payload: jsonEncode(payload()),
            ));
        expect(requests.where((r) => r.url.path == '/negotiate/listing-1/mark-read'),
            hasLength(1));
      } finally {
        SharedPreferences.setMockInitialValues({});
        await ApiService.loadSavedSession();
      }
    });
  });

  group('delivered', () {
    test('a pushed message is marked delivered with the thread token, no session needed',
        () async {
      await withClient(() => NotificationService.markDeliveredFromPush({
            ...payload(),
            'messageId': 'm-1',
            'screen': 'chat',
          }, restoreSession: true));
      final sent = posts('delivered').single;
      expect(jsonDecode(sent.body), {'thread_token': 'thread-token-1', 'message_id': 'm-1'},
          reason: 'the receipt names the message the push announced');
      expect(requests.where((r) => r.url.path.endsWith('/mark-delivered')), isEmpty,
          reason: 'the token was enough');
    });

    test("Zeno's push still delivers the person's messages counted with it", () async {
      await withClient(() => NotificationService.markDeliveredFromPush({
            ...payload(),
            'screen': 'zeno',
            'directUnread': '2',
          }));
      expect(posts('delivered'), hasLength(1));
      requests.clear();
      await withClient(() => NotificationService.markDeliveredFromPush({
            ...payload(),
            'screen': 'zeno',
            'directUnread': '0',
          }));
      expect(requests, isEmpty, reason: "only Zeno's own news - nothing of theirs arrived");
    });
  });
}
