// The one-on-one chat, as reported from a phone (2026-10-02): the last two
// messages showed twice until the chat was reopened, a message the other
// side had read still showed one grey tick, and a send that failed said
// nothing.
//
//  * The poll (the chat socket closed itself after a minute of quiet, so
//    the poll was what ran) delivered the stored copy of a message while
//    its send was still answering - and the copy on screen had no id to
//    match it by. Each message now carries this phone's id for it, which
//    the server stores and hands back.
//  * One failed read-status request came back as "never read" and turned
//    every seen tick back to a single grey one.
//  * A failed send was swallowed: the bubble sat there as if sent.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:broka/models/listing.dart';
import 'package:broka/screens/negotiation_screen.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/widgets/message_receipt.dart';

import 'support/fake_api.dart';

String _iso(DateTime t) => t.toUtc().toIso8601String();

void main() {
  setUpAll(() {
    installFakeApi();
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in [
      'xyz.luan/audioplayers',
      'xyz.luan/audioplayers.global',
      'com.llfbandit.record/messages',
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiService.currentUserId = 'buyer-1';
    ApiService.currentUserName = 'Amina Wanjiru';
    clearFakeRequests();
  });

  Widget chat() => MaterialApp(
        onGenerateRoute: (_) => MaterialPageRoute(
          settings: RouteSettings(arguments: {
            'listing': Listing.fromJson({
              ...fakeListingJson(1),
              'listing_type': 'fixed',
              'status': 'active',
            }),
            'role': 'buyer',
          }),
          builder: (_) => const NegotiationScreen(animateBackground: false),
        ),
      );

  List<MessageReceipt> receipts(WidgetTester tester) => tester
      .widgetList<MessageReceiptIcon>(find.byType(MessageReceiptIcon))
      .map((w) => w.receipt)
      .toList();

  Map<String, dynamic>? lastSent() {
    final sent = fakeRequests.where((r) => r.uri.path == '/negotiate/direct-message');
    return sent.isEmpty ? null : sent.last.json as Map<String, dynamic>;
  }

  testWidgets('a message the poll brings back before its send answers shows once',
      (tester) async {
    final hello = DateTime.now().subtract(const Duration(minutes: 3));
    final sentAt = DateTime.now();
    setFakeRoute((uri) {
      final p = uri.path;
      if (p == '/negotiate/listing-1/history') {
        final mine = lastSent();
        return [
          {'role': 'seller', 'content': 'Rada', 'id': 'm1', 'created_at': _iso(hello)},
          // Stored as soon as the send reached the server - the poll sees
          // it while the send's own answer is still on its way.
          if (mine != null)
            {'role': 'buyer', 'content': 'Yooh', 'id': 'm2', 'created_at': _iso(sentAt),
             'client_msg_id': mine['client_msg_id']},
        ];
      }
      if (p == '/negotiate/direct-message') {
        final mine = lastSent()!;
        return FakeResponse({
          'ok': true,
          'message': {'id': 'm2', 'role': 'buyer', 'content': 'Yooh', 'msg_type': 'text',
                      'created_at': _iso(sentAt), 'client_msg_id': mine['client_msg_id']},
        }, delay: const Duration(seconds: 7));
      }
      if (p.endsWith('/read-status')) return <String, dynamic>{};
      return null;
    });

    await tester.pumpWidget(chat());
    await _settle(tester);
    expect(find.text('Rada'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('direct-chat-composer')), 'Yooh');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250)); // the send button scales in
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump();
    expect(lastSent()!['client_msg_id'], isNotEmpty, reason: 'sent with its own id');

    // The 4-second poll runs while the send is still answering.
    await tester.pump(const Duration(seconds: 5));
    expect(find.text('Yooh'), findsOneWidget);

    // The send answers; still one.
    await tester.pump(const Duration(seconds: 3));
    await _settle(tester);
    expect(find.text('Yooh'), findsOneWidget);
    expect(receipts(tester), [MessageReceipt.sent]);
  });

  testWidgets('a message the other side has read shows as seen, and stays seen',
      (tester) async {
    final sentAt = DateTime.now().subtract(const Duration(minutes: 10));
    var readStatusFails = false;
    setFakeRoute((uri) {
      final p = uri.path;
      if (p == '/negotiate/listing-1/history') {
        return [
          {'role': 'buyer', 'content': 'Nilikuwa nasema', 'id': 'm1', 'created_at': _iso(sentAt)},
        ];
      }
      if (p.endsWith('/read-status')) {
        if (readStatusFails) return const FakeResponse.error();
        return {
          'seller_last_delivered': _iso(sentAt.add(const Duration(minutes: 1))),
          'seller_last_read': _iso(sentAt.add(const Duration(minutes: 2))),
        };
      }
      return null;
    });

    await tester.pumpWidget(chat());
    await _settle(tester);
    expect(receipts(tester), [MessageReceipt.read]);

    // A read-status poll that fails must not take the tick back.
    readStatusFails = true;
    await tester.pump(const Duration(seconds: 13));
    await _settle(tester);
    expect(fakeRequests.where((r) => r.uri.path.endsWith('/read-status')).length,
        greaterThan(1), reason: 'it polled again');
    expect(receipts(tester), [MessageReceipt.read]);
  });

  testWidgets('a message that could not be sent says so and goes again with the same id',
      (tester) async {
    var serverDown = true;
    setFakeRoute((uri) {
      final p = uri.path;
      if (p == '/negotiate/listing-1/history') return <Object>[];
      if (p == '/negotiate/direct-message') {
        if (serverDown) return const FakeResponse.error(statusCode: 502);
        final mine = lastSent()!;
        return {
          'ok': true,
          'message': {'id': 'm9', 'role': 'buyer', 'content': 'Bado iko?', 'msg_type': 'text',
                      'created_at': _iso(DateTime.now()), 'client_msg_id': mine['client_msg_id']},
        };
      }
      if (p.endsWith('/read-status')) return <String, dynamic>{};
      return null;
    });

    await tester.pumpWidget(chat());
    await _settle(tester);
    await tester.enterText(find.byKey(const Key('direct-chat-composer')), 'Bado iko?');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250)); // the send button scales in
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await _settle(tester);

    expect(find.text('Not sent'), findsOneWidget);
    expect(find.text('Message not sent. Tap it to try again.'), findsOneWidget);
    final firstId = lastSent()!['client_msg_id'];

    serverDown = false;
    await tester.tap(find.byKey(const Key('unsent-bubble')));
    await _settle(tester);
    await tester.tap(find.text('Try again'));
    await _settle(tester);

    expect(find.text('Not sent'), findsNothing);
    expect(find.text('Bado iko?'), findsOneWidget);
    expect(receipts(tester), [MessageReceipt.sent]);
    final attempts = fakeRequests.where((r) => r.uri.path == '/negotiate/direct-message').toList();
    expect(attempts, hasLength(2));
    expect((attempts.last.json as Map)['client_msg_id'], firstId,
        reason: 'the same id, so the server keeps one copy if the first did arrive');
  });

  testWidgets('a message typed while the history loads is not lost', (tester) async {
    setFakeRoute((uri) {
      final p = uri.path;
      if (p == '/negotiate/listing-1/history') {
        return FakeResponse(<Object>[
          {'role': 'seller', 'content': 'Karibu', 'id': 'm1', 'created_at': _iso(DateTime.now())},
        ], delay: const Duration(seconds: 2));
      }
      if (p == '/negotiate/direct-message') {
        return const FakeResponse({'detail': 'slow'}, statusCode: 503,
            delay: Duration(seconds: 3));
      }
      if (p.endsWith('/read-status')) return <String, dynamic>{};
      return null;
    });
    await tester.pumpWidget(chat());
    await tester.pump();
    await tester.enterText(find.byKey(const Key('direct-chat-composer')), 'Niko hapa');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250)); // the send button scales in
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pump(const Duration(seconds: 2));
    await _settle(tester);
    // The history arrived and replaced the list - my message is still there.
    expect(find.text('Karibu'), findsOneWidget);
    expect(find.text('Niko hapa'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await _settle(tester);
  });
}

/// pumpAndSettle never returns (the constellation and typing dots animate).
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
