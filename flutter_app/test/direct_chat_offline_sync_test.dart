// An open conversation and the offline sync (2026-11-12).
//
// While a conversation is open its screen owns the cache - it rewrites it
// from what it shows - so the sync hands that conversation's messages to the
// screen (MessageSyncService.attach) rather than writing under it. The same
// message arriving by the chat's own history load and by the sync must be
// one bubble; and the sync acknowledges it only once the screen has it.
//
// With the chat open but not looked at (the app behind the home screen), the
// screen acknowledges the other side's messages by their ids - delivered,
// not read - where it used to post "delivered up to now" for the thread.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:broka/models/listing.dart';
import 'package:broka/screens/negotiation_screen.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/services/message_sync_service.dart';

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
    MessageSyncService.instance.reset();
    MessageSyncService.instance.start();
  });

  tearDown(() => MessageSyncService.instance.reset());

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

  Map<String, dynamic> synced(String id, String words, DateTime at) => {
        'id': id, 'role': 'seller', 'content': words, 'via_ai': false, 'msg_type': 'text',
        'created_at': _iso(at), 'deleted': false,
        'listing_id': 'listing-1', 'store_id': null, 'buyer_id': 'buyer-1',
        'thread_type': 'listing', 'my_role': 'buyer', 'room': 'direct',
        'delivery_status': 'PUSH_FAILED',
      };

  List<String> acked() => [
        for (final r in fakeRequests.where((r) => r.uri.path == '/negotiate/sync/ack'))
          ...((r.json as Map)['message_ids'] as List).cast<String>(),
      ];

  testWidgets('a message the history and the sync both bring is one bubble, acknowledged',
      (tester) async {
    final hello = DateTime.now().subtract(const Duration(hours: 3));
    final later = DateTime.now().subtract(const Duration(hours: 2));
    setFakeRoute((uri) {
      final p = uri.path;
      if (p == '/negotiate/listing-1/history') {
        return [
          {'role': 'seller', 'content': 'Sent while you were offline', 'id': 'm1',
           'created_at': _iso(hello)},
        ];
      }
      if (p == '/negotiate/sync') {
        return {
          'messages': [
            synced('m1', 'Sent while you were offline', hello),
            synced('m2', 'And this one too', later),
          ],
          'has_more': false, 'next_cursor': null,
        };
      }
      if (p == '/negotiate/sync/ack') return {'status': 'ok', 'delivered': ['m1', 'm2']};
      if (p.endsWith('/read-status')) return <String, dynamic>{};
      return null;
    });

    await tester.pumpWidget(chat());
    await _settle(tester);

    expect(find.text('Sent while you were offline'), findsOneWidget);
    expect(find.text('And this one too'), findsOneWidget,
        reason: 'the sync brought the message the open chat had not loaded');
    expect(acked(), containsAll(['m1', 'm2']));
    expect(
        fakeRequests.where((r) => r.uri.path == '/negotiate/sync').first
            .uri.queryParameters['trigger'],
        'open_conversation');
    await tester.pump(const Duration(seconds: 5));
    await _settle(tester);
  });

  testWidgets('behind the home screen, the chat acknowledges messages by id, not the thread',
      (tester) async {
    final at = DateTime.now().subtract(const Duration(minutes: 5));
    setFakeRoute((uri) {
      final p = uri.path;
      if (p == '/negotiate/listing-1/history') {
        return [
          {'role': 'seller', 'content': 'Are you still coming?', 'id': 'm7',
           'created_at': _iso(at)},
        ];
      }
      // A server with the offline sync, and nothing waiting in it.
      if (p == '/negotiate/sync') {
        return {'messages': [], 'has_more': false, 'next_cursor': null};
      }
      if (p == '/negotiate/sync/ack') return {'status': 'ok', 'delivered': ['m7']};
      if (p.endsWith('/read-status')) return <String, dynamic>{};
      return null;
    });

    await tester.pumpWidget(chat());
    await _settle(tester);
    // On screen, the chat read it.
    expect(fakeRequests.where((r) => r.uri.path == '/negotiate/listing-1/mark-read'),
        isNotEmpty);
    expect(acked(), isEmpty);
    clearFakeRequests();

    // With the app in the background, a receipt run says "delivered", by id.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    final dynamic state = tester.state(find.byType(NegotiationScreen));
    await state.debugSyncReadState();
    await _settle(tester);

    expect(acked(), ['m7']);
    final ack = fakeRequests.firstWhere((r) => r.uri.path == '/negotiate/sync/ack');
    expect((ack.json as Map)['source'], 'chat');
    expect(fakeRequests.where((r) => r.uri.path.endsWith('/mark-delivered')), isEmpty,
        reason: '"delivered up to now" would count what was sent after this load');
    expect(fakeRequests.where((r) => r.uri.path.endsWith('/mark-read')), isEmpty,
        reason: 'nobody is looking: delivered, not read');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 5));
    await _settle(tester);
  });
}

/// pumpAndSettle never returns (the constellation and typing dots animate).
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
