// How a push's delivery receipt tries again, and when it stops (2026-11-12).
//
// From a closed app nothing else reports the receipt until the app next
// runs, so one dropped request used to leave the sender on a single tick
// (background_delivery_receipt_test.dart has the flow itself).
//
//  * No answer, a timeout, a server error or "too many" is tried again, on
//    NotificationService.deliveryAckRetryDelays and within
//    deliveryAckBudget - Android may stop a push handler after about ten
//    seconds.
//  * A definite answer - 400, 401, 403, 404, 422 - is final.
//  * Whatever happens, a failed receipt is reported as failed or refused,
//    never as delivered, and nothing reads the conversation.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:broka/services/api_service.dart';
import 'package:broka/services/notification_service.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _token = 'eyJhbGciOiJIUzI1NiJ9.eyJ0eXBlIjoidGhyZWFkIn0.c2lnbmVk';
const _receipt = '/negotiate/notification/delivered';
const _sessionReceipt = '/negotiate/listing-1/mark-delivered';

http.Response _json(Object? body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final requests = <http.Request>[];
  final logs = <String>[];
  // One answer per request, in order; the last one repeats.
  var answers = <Object>[];
  final client = MockClient((req) async {
    requests.add(req);
    if (req.url.path != _receipt && req.url.path != _sessionReceipt) {
      return _json({'status': 'ok'});
    }
    final tries = requests.where((r) => r.url.path == req.url.path).length;
    final answer = answers[tries <= answers.length ? tries - 1 : answers.length - 1];
    if (answer is Exception) throw answer;
    return answer as http.Response;
  });
  final printer = debugPrint;
  final delays = NotificationService.deliveryAckRetryDelays;
  final budget = NotificationService.deliveryAckBudget;

  Future<T> withClient<T>(Future<T> Function() body) => http.runWithClient(body, () => client);

  setUp(() async {
    requests.clear();
    logs.clear();
    answers = [_json({'status': 'ok', 'advanced': true})];
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) logs.add(message);
    };
    NotificationService.deliveryAckRetryDelays =
        const [Duration.zero, Duration.zero, Duration.zero];
    NotificationService.deliveryAckBudget = const Duration(seconds: 20);
    // A closed app's push isolate: nobody signed in.
    SharedPreferences.setMockInitialValues({});
    await ApiService.loadSavedSession();
  });

  tearDown(() async {
    debugPrint = printer;
    NotificationService.deliveryAckRetryDelays = delays;
    NotificationService.deliveryAckBudget = budget;
    SharedPreferences.setMockInitialValues({});
    await ApiService.loadSavedSession();
  });

  Map<String, dynamic> push({String? threadToken = _token, String screen = 'chat',
      String directUnread = '1', String type = 'new_message'}) => {
        'type': type,
        'listingId': 'listing-1',
        'buyerId': 'buyer-1',
        'myRole': 'seller',
        'messageId': 'm-1',
        'screen': screen,
        'directUnread': directUnread,
        if (threadToken != null) 'threadToken': threadToken,
      };

  List<http.Request> to(String path) => requests.where((r) => r.url.path == path).toList();
  List<String> lines(String event) =>
      logs.where((l) => l.startsWith('[Push] $event ')).toList();
  bool anythingRead() => requests.any((r) =>
      r.url.path.endsWith('/mark-read') || r.url.path == '/negotiate/notification/read');

  Future<DeliveryAckOutcome> deliver(Map<String, dynamic> data, {bool background = true}) =>
      withClient(() => NotificationService.markDeliveredFromPush(data, restoreSession: background));

  test('no answer, a timeout or a server error is tried again until it gets through',
      () async {
    answers = [
      const SocketException('Network is unreachable'),
      TimeoutException('slow network'),
      _json({'detail': 'Bad gateway'}, 503),
      _json({'status': 'ok', 'advanced': true, 'last_delivered_at': '2026-11-12T09:00:00Z'}),
    ];
    expect(await deliver(push()), DeliveryAckOutcome.acknowledged);
    expect(to(_receipt), hasLength(4));
    final retries = lines('DELIVERY_ACK_RETRY');
    expect(retries, hasLength(3));
    expect(retries[0], contains('reason=no_answer:SocketException'));
    expect(retries[1], contains('reason=no_answer:TimeoutException'));
    expect(retries[2], contains('status=503'));
    expect(retries[2], contains('reason=server_error'));
    expect(lines('DELIVERY_ACK_SUCCESS').single, contains('attempt=4'));
    expect(lines('DELIVERY_ACK_FAILED'), isEmpty);
  });

  test('"too many" is tried again too', () async {
    answers = [
      _json({'detail': 'Slow down'}, 429),
      _json({'status': 'ok', 'advanced': true}),
    ];
    expect(await deliver(push()), DeliveryAckOutcome.acknowledged);
    expect(to(_receipt), hasLength(2));
  });

  test('it gives up after the last try - failed, never delivered', () async {
    answers = [_json({'detail': 'Server error'}, 500)];
    expect(await deliver(push()), DeliveryAckOutcome.failed);
    expect(to(_receipt), hasLength(NotificationService.deliveryAckRetryDelays.length + 1));
    final failed = lines('DELIVERY_ACK_FAILED').single;
    expect(failed, contains('final=true'));
    expect(failed, contains('reason=server_error'));
    expect(lines('DELIVERY_ACK_SUCCESS'), isEmpty);
    expect(lines('DELIVERY_WATERMARK_UPDATED'), isEmpty);
    expect(requests.where((r) => r.url.path.endsWith('/mark-delivered')), isEmpty,
        reason: 'not swapped for the session either');
    expect(anythingRead(), isFalse);
  });

  test('it stops when its time is up', () async {
    NotificationService.deliveryAckBudget = Duration.zero;
    answers = [const SocketException('Network is unreachable')];
    expect(await deliver(push()), DeliveryAckOutcome.failed);
    expect(to(_receipt), hasLength(1));
    expect(lines('DELIVERY_ACK_FAILED').single, contains('elapsed_ms='));
  });

  for (final status in [400, 401, 403, 404, 422]) {
    test('a definite $status is final', () async {
      answers = [_json({'detail': 'No'}, status)];
      expect(await deliver(push()), DeliveryAckOutcome.refused);
      expect(to(_receipt), hasLength(1));
      expect(lines('DELIVERY_ACK_RETRY'), isEmpty);
      expect(lines('DELIVERY_ACK_FAILED').single, contains('status=$status'));
    });
  }

  test("an older server's receipt, through the session, is tried again too", () async {
    SharedPreferences.setMockInitialValues(
        {'auth_token': 'access-seller-1', 'user_id': 'seller-1'});
    answers = [
      _json({'detail': 'Bad gateway'}, 502),
      _json({'status': 'ok', 'last_delivered_at': '2026-11-12T09:00:00Z'}),
    ];
    expect(await deliver(push(threadToken: null)), DeliveryAckOutcome.acknowledged);
    expect(to(_sessionReceipt), hasLength(2));
    expect(lines('DELIVERY_ACK_SUCCESS').single, contains('via=session'));
    expect(lines('DELIVERY_WATERMARK_UPDATED'), isEmpty,
        reason: 'an older server does not say whether the watermark moved');
  });

  test('with the app in front, too', () async {
    answers = [
      const SocketException('Connection reset'),
      _json({'status': 'ok', 'advanced': true}),
    ];
    expect(await deliver(push(), background: false), DeliveryAckOutcome.acknowledged);
    expect(to(_receipt), hasLength(2));
  });

  test('nothing to report is skipped, and sends nothing', () async {
    expect(await deliver(push(screen: 'zeno', directUnread: '0')), DeliveryAckOutcome.skipped);
    expect(await deliver(push(type: 'missed_call')), DeliveryAckOutcome.skipped);
    expect(await deliver({...push(), 'listingId': ''}), DeliveryAckOutcome.skipped);
    expect(requests, isEmpty);
  });

  test('a thread token is taken as the push carried it, unless it cannot be one', () {
    expect(NotificationService.usableThreadToken(_token), _token);
    expect(NotificationService.usableThreadToken(null), isNull);
    expect(NotificationService.usableThreadToken(''), isNull);
    expect(NotificationService.usableThreadToken('two words'), isNull);
    expect(NotificationService.usableThreadToken('line\nbreak'), isNull);
    expect(NotificationService.usableThreadToken('a' * 4096), isNotNull);
    expect(NotificationService.usableThreadToken('a' * 4097), isNull,
        reason: 'longer than the server takes');
  });
}
