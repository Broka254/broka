// The incoming-call notification's Accept and Decline.
//
// The notification used to carry no buttons at all: a call could not be
// declined from the shade or the lock screen, and answering meant tapping
// the notification body. Decline now records "declined" the same way the
// call screen's Decline button does, which is also what hangs up the
// caller - so these check that it reaches the server, including from an
// app whose access token expired while it sat in the background.
import 'dart:convert';

import 'package:broka/services/api_service.dart';
import 'package:broka/services/notification_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response _json(Object body, int status) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Decline stops the ringer, and RingtoneService's player talks to
  // audioplayers' platform side as soon as it exists. Nothing rings here.
  setUpAll(() {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in ['xyz.luan/audioplayers', 'xyz.luan/audioplayers.global']) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
  });

  group('incoming-call notification', () {
    test('offers Decline and Accept', () {
      final details = NotificationService.incomingCallDetails(
        ringing: true, ringFor: const Duration(seconds: 45),
      );
      final actions = details.android!.actions!;
      expect(actions.map((a) => a.id), [
        NotificationService.callDeclineActionId,
        NotificationService.callAcceptActionId,
      ]);
      final decline = actions.first;
      final accept = actions.last;
      // Decline is handled without opening the app; Accept opens it.
      expect(decline.showsUserInterface, isFalse);
      expect(accept.showsUserInterface, isTrue);
      expect(decline.cancelNotification, isTrue);
      expect(accept.cancelNotification, isTrue);
      expect(details.iOS!.categoryIdentifier, isNotNull);
    });

    test('rings insistently only when nothing in the app is ringing', () {
      const ringFor = Duration(seconds: 45);
      final silent = NotificationService.incomingCallDetails(ringing: true, ringFor: ringFor);
      final alone = NotificationService.incomingCallDetails(ringing: false, ringFor: ringFor);
      expect(silent.android!.additionalFlags, isNull);
      expect(alone.android!.additionalFlags, [4]); // FLAG_INSISTENT
      expect(alone.android!.playSound, isTrue);
    });
  });

  group('Decline', () {
    late List<http.Request> requests;
    late Future<http.Response> Function(http.Request) handler;
    final mock = MockClient((req) async {
      requests.add(req);
      return handler(req);
    });

    setUp(() async {
      requests = [];
      SharedPreferences.setMockInitialValues({
        'auth_token': 'expired',
        'refresh_token': 'rt',
        'user_id': 'seller-1',
      });
      await ApiService.loadSavedSession();
    });

    String payload() => jsonEncode({
      'type': 'incoming_call',
      'roomId': 'room-1',
      'listingId': 'listing-1',
      'buyerId': 'buyer-1',
      'callType': 'video',
    });

    Iterable<Map<String, dynamic>> logResultBodies() => requests
        .where((r) => r.url.path.endsWith('/calls/log-result'))
        .map((r) => jsonDecode(r.body) as Map<String, dynamic>);

    test('records the call as declined', () async {
      handler = (req) async => _json({'status': 'logged'}, 200);
      await http.runWithClient(
        () => NotificationService.instance.handleResponse(
          actionId: NotificationService.callDeclineActionId,
          payload: payload(),
        ),
        () => mock,
      );
      final bodies = logResultBodies().toList();
      expect(bodies, hasLength(1));
      expect(bodies.single['room_id'], 'room-1');
      expect(bodies.single['outcome'], 'declined');
      expect(bodies.single['listing_id'], 'listing-1');
      // I'm the seller, so the buyer called.
      expect(bodies.single['caller_role'], 'buyer');
    });

    test('renews an expired session and still reaches the server', () async {
      handler = (req) async {
        if (req.url.path.endsWith('/auth/token/refresh')) {
          return _json({'access_token': 'fresh', 'refresh_token': 'rt2'}, 200);
        }
        return req.headers['Authorization'] == 'Bearer fresh'
            ? _json({'status': 'logged'}, 200)
            : _json({'detail': 'expired'}, 401);
      };
      await http.runWithClient(
        () => NotificationService.instance.handleResponse(
          actionId: NotificationService.callDeclineActionId,
          payload: payload(),
        ),
        () => mock,
      );
      final logCalls = requests.where((r) => r.url.path.endsWith('/calls/log-result')).toList();
      expect(logCalls, hasLength(2));
      expect(logCalls.last.headers['Authorization'], 'Bearer fresh');
    });

    test('Accept does not decline', () async {
      handler = (req) async => _json({'has_call': false}, 200);
      await http.runWithClient(
        () => NotificationService.instance.handleResponse(
          actionId: NotificationService.callAcceptActionId,
          payload: payload(),
        ),
        () => mock,
      );
      expect(logResultBodies(), isEmpty);
    });
  });

  test('notification action ids are stable', () {
    // Posted notifications outlive app updates; renaming an id would make
    // the buttons on an already-posted notification do nothing.
    expect(NotificationService.callDeclineActionId, 'call_decline');
    expect(NotificationService.callAcceptActionId, 'call_accept');
  });
}
