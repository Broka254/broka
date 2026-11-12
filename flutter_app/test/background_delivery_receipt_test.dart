// Delivered from a closed app: the phone a message push reaches tells the
// server it has the message - and only that (2026-11-12).
//
// Asked for: "Delivered" must mean the recipient's phone has the message,
// with the app in the background, closed, or the phone locked; a failed
// receipt must never pass for one; a notification arriving is never "Seen".
//
//  * The receipt goes with the push's thread token - no session needed, as
//    a closed app has none - and names the message the push announced, so
//    the server can tick that message and not whatever was written since.
//  * No answer at first (a phone just woken from Doze has no network for a
//    second or two) is tried again; a refusal is final.
//  * A refused token is not swapped for whoever is signed in now: with two
//    BROKA accounts on one phone, that is the other account.
//  * An older server's push (no token) is reported by the saved session,
//    only when it is the account the push was for, and never renewed there.
//  * Neither the notification shown with the app in front, nor the one drawn
//    again with Reply and Mark as read with it closed, waits on the receipt.
//  * Each step is logged - PUSH_RECEIVED to DELIVERY_ACK_SUCCESS - with
//    ids, never the token or the message's words.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:broka/services/active_call.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/services/notification_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A thread token as the server issues one. What is in it is the server's
/// business: the app sends it as it came.
const _token = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9'
    '.eyJzdWIiOiJzZWxsZXItMSIsInR5cGUiOiJ0aHJlYWQifQ'
    '.c2lnbmVkLWJ5LXRoZS1zZXJ2ZXI';

const _receipt = '/negotiate/notification/delivered';
const _sessionReceipt = '/negotiate/listing-1/mark-delivered';

http.Response _json(Object? body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

http.Response _recorded() => _json({
      'status': 'ok',
      'last_delivered_at': '2026-11-12T09:00:00.123456Z',
      'advanced': true,
      'message_id': 'm-1',
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final shown = <Map<String, dynamic>>[];
  var active = <Map<String, Object?>>[];
  final requests = <http.Request>[];
  final logs = <String>[];
  late Future<http.Response> Function(http.Request) route;
  final client = MockClient((req) {
    requests.add(req);
    return route(req);
  });
  final printer = debugPrint;

  Future<T> withClient<T>(Future<T> Function() body) => http.runWithClient(body, () => client);

  Future<void> settle() async {
    for (var i = 0; i < 50; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

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
      if (call.method == 'getActiveNotifications') return active;
      if (call.method == 'areNotificationsEnabled') return true;
      return null;
    });
  });

  tearDownAll(() => debugDefaultTargetPlatformOverride = null);

  setUp(() async {
    shown.clear();
    requests.clear();
    logs.clear();
    active = [];
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) logs.add(message);
    };
    // A closed app's push isolate: nothing in memory, nobody signed in.
    SharedPreferences.setMockInitialValues({});
    await ApiService.loadSavedSession();
    ActiveCall.instance.reset();
    route = (_) async => _recorded();
    await NotificationService.instance.initialize(
        navKey: GlobalKey<NavigatorState>(), requestPermission: false);
  });

  tearDown(() async {
    debugPrint = printer;
    SharedPreferences.setMockInitialValues({});
    await ApiService.loadSavedSession();
  });

  /// A message push as the server sends it: Ann, the buyer, wrote to the
  /// seller of listing-1 (the phone's account).
  Map<String, dynamic> push({
    String? threadToken = _token,
    String messageId = 'm-1',
    String myRole = 'seller',
    String buyerId = 'buyer-1',
  }) => {
        'type': 'new_message',
        'listingId': 'listing-1',
        'buyerId': buyerId,
        'myRole': myRole,
        'messageId': messageId,
        'screen': 'chat',
        'senderName': 'Ann',
        'listingName': 'Samsung A54',
        'count': '1',
        'directUnread': '1',
        'preview': 'Still available?',
        'title': 'Ann · Samsung A54',
        'body': 'Still available?',
        if (threadToken != null) 'threadToken': threadToken,
      };

  List<http.Request> to(String path) => requests.where((r) => r.url.path == path).toList();

  bool anythingRead() => requests.any((r) =>
      r.url.path.endsWith('/mark-read') || r.url.path == '/negotiate/notification/read');

  List<String> pushLines() => logs.where((l) => l.startsWith('[Push] ')).toList();

  String? authorization(http.Request r) => r.headers['authorization'] ?? r.headers['Authorization'];

  group('with the app closed', () {
    test('the receipt goes with the thread token, names the message, and needs no session',
        () async {
      await withClient(() => NotificationService.handleBackgroundMessage(push()));
      final sent = to(_receipt).single;
      expect(jsonDecode(sent.body), {'thread_token': _token, 'message_id': 'm-1'},
          reason: 'the server ticks up to the message the push announced - no further');
      expect(authorization(sent), isNull,
          reason: 'a closed app has no live access token; the thread token is the proof');
      expect(requests.where((r) => r.url.path.endsWith('/mark-delivered')), isEmpty);
      expect(anythingRead(), isFalse, reason: 'a push arriving is not the chat being read');
    });

    test('every step is logged, with ids and never the token or the words', () async {
      final sentAt = DateTime.now().millisecondsSinceEpoch - 1500;
      await withClient(() => NotificationService.handleBackgroundMessage({
            ...push(),
            'fcmMessageId': '0:1731402000000%abc123',
            'fcmSentAt': '$sentAt',
          }));
      final events = pushLines().map((l) => l.split(' ')[1]).toList();
      expect(events, containsAllInOrder([
        'PUSH_RECEIVED',
        'DELIVERY_ACK_STARTED',
        'DELIVERY_ACK_SUCCESS',
        'DELIVERY_WATERMARK_UPDATED',
      ]));
      final received = pushLines().firstWhere((l) => l.contains('PUSH_RECEIVED'));
      expect(received, contains('thread=listing-1'));
      expect(received, contains('message=m-1'));
      expect(received, contains('role=seller'));
      expect(received, contains('transport=background'));
      expect(received, contains('has_token=true'));
      expect(received, contains('fcm_id=0:1731402000000%abc123'));
      expect(received, matches(RegExp(r'latency_ms=\d+')));
      expect(received, matches(RegExp(r'at=\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d')));
      final ok = pushLines().firstWhere((l) => l.contains('DELIVERY_ACK_SUCCESS'));
      expect(ok, contains('status=200'));
      expect(ok, contains('attempt=1'));
      expect(ok, contains('via=thread_token'));
      expect(pushLines().firstWhere((l) => l.contains('DELIVERY_WATERMARK_UPDATED')),
          contains('last_delivered_at=2026-11-12T09:00:00.123456Z'));
      for (final line in pushLines()) {
        expect(line, isNot(contains(_token)), reason: 'the token acts for the account');
        expect(line, isNot(contains('Still available?')), reason: 'nor what was written');
      }
      // The trace itself, into the test output: what the phone's logcat
      // shows for one push reaching a closed app.
      pushLines().forEach(printer);
    });

    test('a receipt with no answer the first time is sent again', () async {
      var tries = 0;
      route = (req) async {
        if (req.url.path != _receipt) return _json({'status': 'ok'});
        tries++;
        if (tries == 1) throw const SocketException('Network is unreachable');
        return _recorded();
      };
      await withClient(() => NotificationService.handleBackgroundMessage(push()));
      expect(to(_receipt), hasLength(2),
          reason: 'a phone just out of Doze often has no network for its first request');
      expect(pushLines().where((l) => l.contains('DELIVERY_ACK_RETRY')).single,
          contains('reason=no_answer:SocketException'));
      expect(pushLines().any((l) => l.contains('DELIVERY_ACK_SUCCESS') && l.contains('attempt=2')),
          isTrue);
    });

    test("a refused token is final, and another account's session does not answer for it",
        () async {
      // Two BROKA accounts on one phone: the push was for seller-1, and
      // buyer-9 has signed in on it since. The server refuses the token
      // (the phone is no longer seller-1's).
      SharedPreferences.setMockInitialValues(
          {'auth_token': 'access-buyer-9', 'user_id': 'buyer-9'});
      route = (req) async => req.url.path == _receipt
          ? _json({'detail': 'This phone is no longer signed in.'}, 401)
          : _json({'status': 'ok'});
      await withClient(() => NotificationService.handleBackgroundMessage(push()));
      expect(to(_receipt), hasLength(1), reason: 'a refusal is not tried again');
      expect(requests.where((r) => r.url.path.endsWith('/mark-delivered')), isEmpty,
          reason: "buyer-9's session would tick a delivery on a thread they never got");
      expect(
          pushLines().any((l) =>
              l.contains('DELIVERY_ACK_FAILED') && l.contains('status=401') &&
              l.contains('final=true')),
          isTrue);
    });

    test('a token that cannot be one is not sent, nor swapped for the session', () async {
      SharedPreferences.setMockInitialValues(
          {'auth_token': 'access-seller-1', 'user_id': 'seller-1'});
      await withClient(
          () => NotificationService.handleBackgroundMessage(push(threadToken: 'not a token')));
      expect(requests, isEmpty);
      expect(pushLines().any((l) => l.contains('reason=token_malformed')), isTrue);
    });

    test('the same push handed over twice at once sends one receipt', () async {
      final answer = Completer<http.Response>();
      route = (req) => req.url.path == _receipt ? answer.future : Future.value(_json({}));
      final first = withClient(
          () => NotificationService.markDeliveredFromPush(push(), restoreSession: true));
      final second = withClient(
          () => NotificationService.markDeliveredFromPush(push(), restoreSession: true));
      await settle();
      answer.complete(_recorded());
      await Future.wait([first, second]);
      expect(to(_receipt), hasLength(1));
    });

    test('Reply and Mark as read are drawn without waiting on the receipt', () async {
      // What Android drew from the push, which has no buttons.
      active = [
        {'id': 0, 'tag': 'thread_listing-1_buyer-1', 'channelId': 'broka_messages',
         'title': 'Ann · Samsung A54', 'body': 'Still available?'},
      ];
      final answer = Completer<http.Response>();
      route = (req) => req.url.path == _receipt ? answer.future : Future.value(_json({}));
      final handled = withClient(() => NotificationService.handleBackgroundMessage(push()));
      await settle();
      expect(shown, hasLength(1), reason: 'drawn again while the receipt is on its way');
      final actions = (shown.single['platformSpecifics'] as Map?)?['actions'] as List?;
      expect(actions, hasLength(2));
      answer.complete(_recorded());
      await handled;
      expect(to(_receipt), hasLength(1));
    });
  });

  group("an older server's push, which has no thread token", () {
    test('is reported by the saved session of the account it was for, never renewed',
        () async {
      SharedPreferences.setMockInitialValues({
        'auth_token': 'access-seller-1',
        'user_id': 'seller-1',
        'refresh_token': 'refresh-seller-1',
      });
      route = (req) async => req.url.path == _sessionReceipt
          ? _json({'detail': 'Token expired'}, 401)
          : _json({'status': 'ok'});
      await withClient(
          () => NotificationService.handleBackgroundMessage(push(threadToken: null)));
      final sent = to(_sessionReceipt).single;
      expect(authorization(sent), 'Bearer access-seller-1');
      expect(jsonDecode(sent.body), {'buyer_id': 'buyer-1'});
      expect(to('/auth/token/refresh'), isEmpty,
          reason: "renewing from the push isolate races the app's own renewal");
      expect(anythingRead(), isFalse);
    });

    test("is not reported by another account's session", () async {
      // A buyer's push, with a different buyer signed in.
      SharedPreferences.setMockInitialValues(
          {'auth_token': 'access-buyer-2', 'user_id': 'buyer-2'});
      await withClient(() => NotificationService.handleBackgroundMessage(
          push(threadToken: null, myRole: 'buyer', buyerId: 'buyer-1')));
      // A seller's push, with that conversation's buyer signed in.
      SharedPreferences.setMockInitialValues(
          {'auth_token': 'access-buyer-1', 'user_id': 'buyer-1'});
      await withClient(() => NotificationService.handleBackgroundMessage(
          push(threadToken: null, messageId: 'm-2')));
      expect(requests.where((r) => r.url.path.endsWith('/mark-delivered')), isEmpty);
      expect(pushLines().where((l) => l.contains('reason=other_account')), hasLength(2));
    });
  });

  group('with the app in front', () {
    test('the notification is shown without waiting on the receipt', () async {
      final answer = Completer<http.Response>();
      route = (req) => req.url.path == _receipt ? answer.future : Future.value(_json({}));
      final handled = withClient(
          () => NotificationService.instance.handleForegroundFcmMessage(push()));
      await settle();
      expect(shown, hasLength(1), reason: 'shown while the receipt is still on its way');
      expect(shown.single['title'], 'Ann · Samsung A54');
      answer.complete(_recorded());
      await handled;
      expect(jsonDecode(to(_receipt).single.body), {'thread_token': _token, 'message_id': 'm-1'});
      expect(pushLines().first, contains('transport=foreground'));
      expect(anythingRead(), isFalse);
    });
  });
}
