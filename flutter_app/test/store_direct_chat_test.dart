// Store conversations are direct chats, not a second messaging product.
//
// Buyers and shop owners must get the same composer, sockets, receipts,
// photos, voice notes and voice/video call buttons as every listing thread.
// Only the listing-specific Zeno and escrow panels stay out of a shop-wide
// conversation, and the message must ride the normal direct-message route
// with store_id instead of borrowing a listing.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:broka/main.dart' show BrokaColors;
import 'package:broka/screens/negotiation_screen.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/widgets/chat_parts.dart';

import 'support/fake_api.dart';

String _iso(DateTime t) => t.toUtc().toIso8601String();

void main() {
  final pushed = <RouteSettings>[];

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
    pushed.clear();
  });

  Map<String, dynamic>? lastSent() {
    final sent = fakeRequests.where((r) => r.uri.path == '/negotiate/direct-message');
    return sent.isEmpty ? null : sent.last.json as Map<String, dynamic>;
  }

  Future<void> expectThreadGuard(Future<dynamic> Function() call) async {
    await expectLater(call(), throwsA(isA<ArgumentError>()));
  }

  Widget chat({Map<String, dynamic>? arguments}) {
    final threadArgs = arguments ?? const {
      'storeId': 's1',
      'storeName': 'Clanix Electronics',
      'seller_id': 'owner-1',
      'role': 'buyer',
    };
    return MaterialApp(
        onGenerateRoute: (settings) {
          pushed.add(settings);
          if (settings.name == '/voip-call') {
            return MaterialPageRoute(
              settings: settings,
              builder: (_) => const Scaffold(body: Text('CALL SCREEN')),
            );
          }
          return MaterialPageRoute(
            settings: RouteSettings(arguments: threadArgs),
            builder: (_) => const NegotiationScreen(animateBackground: false),
          );
        },
      );
  }

  void backend() {
    setFakeRoute((uri) {
      final p = uri.path;
      if (p == '/negotiate/store/s1/history') {
        return [
          {
            'id': 'm1',
            'role': 'seller',
            'content': 'Welcome to Clanix',
            'msg_type': 'text',
            'created_at': _iso(DateTime.now().subtract(const Duration(minutes: 2))),
          },
        ];
      }
      if (p == '/negotiate/store/s1/read-status') return <String, dynamic>{};
      if (p == '/negotiate/store/s1/thread-info') {
        return {
          'store_id': 's1',
          'store_name': 'Clanix Electronics',
          'role': 'buyer',
          'buyer_id': 'buyer-1',
          'counterpart_id': 'owner-1',
        };
      }
      if (p == '/auth/user/owner-1') {
        return {'id': 'owner-1', 'name': 'Clanix Owner', 'is_online': true};
      }
      if (p == '/auth/user/buyer-7') {
        return {'id': 'buyer-7', 'name': 'Keen Buyer', 'is_online': true};
      }
      if (p == '/negotiate/direct-message') {
        final body = lastSent()!;
        return {
          'ok': true,
          'message': {
            'id': 'm2',
            'role': body['sender_role'],
            'content': body['content'],
            'msg_type': 'text',
            'created_at': _iso(DateTime.now()),
            'client_msg_id': body['client_msg_id'],
          },
        };
      }
      if (p == '/calls/initiate') {
        return {'status': 'sent', 'room_id': 'room-9', 'call_token': 't'};
      }
      return null;
    });
  }


  group('one thread identity', () {
    test('messages, uploads and calls reject both or neither identity',
        () async {
      await expectThreadGuard(() => ApiService.sendDirectMessage(
            listingId: 'l1',
            storeId: 's1',
            senderRole: 'buyer',
            senderId: 'buyer-1',
            content: 'Which thread?',
          ));
      await expectThreadGuard(() => ApiService.sendDirectMessage(
            senderRole: 'buyer',
            senderId: 'buyer-1',
            content: 'No thread',
          ));

      await expectThreadGuard(() => ApiService.uploadMedia(
            listingId: 'l1',
            storeId: 's1',
            senderRole: 'buyer',
            senderId: 'buyer-1',
            contentType: 'image',
            fileBytes: Uint8List(0),
            fileName: 'photo.jpg',
            mimeType: 'image/jpeg',
          ));
      await expectThreadGuard(() => ApiService.uploadMedia(
            senderRole: 'buyer',
            senderId: 'buyer-1',
            contentType: 'image',
            fileBytes: Uint8List(0),
            fileName: 'photo.jpg',
            mimeType: 'image/jpeg',
          ));

      await expectThreadGuard(() => ApiService.initiateCall(
            listingId: 'l1',
            storeId: 's1',
            listingName: 'Which thread?',
          ));
      await expectThreadGuard(() => ApiService.initiateCall(
            listingName: 'No thread',
          ));

      await expectThreadGuard(() => ApiService.logCallResult(
            roomId: 'room-1',
            listingId: 'l1',
            storeId: 's1',
            buyerId: 'buyer-1',
            outcome: 'completed',
            callerRole: 'buyer',
          ));
      await expectThreadGuard(() => ApiService.logCallResult(
            roomId: 'room-1',
            buyerId: 'buyer-1',
            outcome: 'completed',
            callerRole: 'buyer',
          ));

      await expectThreadGuard(() => ApiService.markThreadDelivered(
            'l1', storeId: 's1', buyerId: 'buyer-1'));
      await expectThreadGuard(() => ApiService.markThreadDelivered(null));
      await expectThreadGuard(() => ApiService.markThreadRead(
            'l1', storeId: 's1', buyerId: 'buyer-1'));
      await expectThreadGuard(() => ApiService.markThreadRead(null));
      await expectThreadGuard(() => ApiService.getReadStatus(
            'l1', storeId: 's1', buyerId: 'buyer-1'));
      await expectThreadGuard(() => ApiService.getReadStatus(null));
      await expectThreadGuard(() => ApiService.getUnreadCounts(
            'l1', storeId: 's1', buyerId: 'buyer-1'));
      await expectThreadGuard(() => ApiService.getUnreadCounts(null));
    });
  });

  testWidgets('a store thread uses direct chat, including calls, but not listing panels',
      (tester) async {
    backend();
    await tester.pumpWidget(chat());
    await _settle(tester);

    expect(find.text('Welcome to Clanix'), findsOneWidget);
    expect(find.byTooltip('Voice call'), findsOneWidget);
    expect(find.byTooltip('Video call'), findsOneWidget);
    expect(find.byKey(const Key('direct-chat-composer')), findsOneWidget);
    expect(find.byType(ChatModeSwitch), findsNothing);
    expect(find.byTooltip('Ask Zeno'), findsNothing);
    expect(find.byKey(const Key('pay-now')), findsNothing);
    expect(find.text('Get paid with escrow'), findsNothing);
  });

  testWidgets('storefront entry resolves and loads the owner presence',
      (tester) async {
    backend();
    await tester.pumpWidget(chat(arguments: const {
      'storeId': 's1',
      'storeName': 'Clanix Electronics',
      'role': 'buyer',
    }));
    await _settle(tester);

    expect(
        fakeRequests.any((r) => r.uri.path == '/negotiate/store/s1/thread-info'),
        isTrue,
        reason: 'the storefront route has no owner id to pass');
    expect(fakeRequests.any((r) => r.uri.path == '/auth/user/owner-1'), isTrue,
        reason: 'the resolved owner id must load their profile');
    final dot = tester.widget<Container>(
        find.byKey(const Key('direct-chat-presence-dot')));
    expect((dot.decoration as BoxDecoration).color, BrokaColors.neonGreen,
        reason: 'the owner is online and the chat must show it');
  });

  testWidgets('a route cannot open a store and a product conversation together',
      (tester) async {
    backend();
    await tester.pumpWidget(chat(arguments: const {
      'storeId': 's1',
      'storeName': 'Clanix Electronics',
      'role': 'buyer',
      'listing': {
        'id': 'l1',
        'name': 'Phone',
        'category': 'Electronics',
        'price': 25000,
        'listing_type': 'fixed',
        'status': 'active',
        'views': 0,
      },
    }));
    await _settle(tester);

    expect(find.byKey(const Key('invalid-chat-arguments')), findsOneWidget);
    expect(find.text('This chat opens both a store and a product.'),
        findsOneWidget);
    expect(fakeRequests.any((r) => r.uri.path == '/negotiate/store/s1/history'),
        isFalse,
        reason: 'an ambiguous route must not guess which thread to load');
  });

  testWidgets('sending posts to the normal direct-message route with store_id',
      (tester) async {
    backend();
    await tester.pumpWidget(chat());
    await _settle(tester);

    await tester.enterText(
        find.byKey(const Key('direct-chat-composer')), 'Do you deliver?');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await _settle(tester);

    final sent = lastSent()!;
    expect(sent['store_id'], 's1');
    expect(sent.containsKey('listing_id'), isFalse);
    expect(sent['content'], 'Do you deliver?');
    expect(find.text('Do you deliver?'), findsOneWidget);
  });

  testWidgets('the header call button places a store-keyed call', (tester) async {
    backend();
    await tester.pumpWidget(chat());
    await _settle(tester);

    await tester.tap(find.byTooltip('Voice call'));
    await _settle(tester);
    await tester.tap(find.text('Call Now'));
    await _settle(tester);

    final sent = fakeRequests.singleWhere((r) => r.uri.path == '/calls/initiate').json as Map;
    expect(sent['store_id'], 's1');
    expect(sent.containsKey('listing_id'), isFalse);
    final call = pushed.singleWhere((r) => r.name == '/voip-call').arguments as Map;
    expect(call['storeId'], 's1');
    expect(call.containsKey('listingId'), isFalse);
    expect(call['listingName'], 'Clanix Electronics');
  });

  testWidgets('the store owner replies to the buyer in the same store thread',
      (tester) async {
    ApiService.currentUserId = 'owner-1';
    ApiService.currentUserName = 'Clanix Owner';
    backend();
    await tester.pumpWidget(chat(arguments: const {
      'storeId': 's1',
      'storeName': 'Clanix Electronics',
      'seller_id': 'owner-1',
      'role': 'seller',
      'buyer_id': 'buyer-7',
    }));
    await _settle(tester);

    final history = fakeRequests.singleWhere(
        (r) => r.uri.path == '/negotiate/store/s1/history');
    expect(history.uri.queryParameters['buyer_id'], 'buyer-7');

    await tester.enterText(
        find.byKey(const Key('direct-chat-composer')), 'Yes, until 6pm.');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await _settle(tester);

    final sent = lastSent()!;
    expect(sent['store_id'], 's1');
    expect(sent['buyer_id'], 'buyer-7');
    expect(sent.containsKey('listing_id'), isFalse);

    await tester.tap(find.byTooltip('Voice call'));
    await _settle(tester);
    await tester.tap(find.text('Call Now'));
    await _settle(tester);
    final call = fakeRequests
        .singleWhere((r) => r.uri.path == '/calls/initiate').json as Map;
    expect(call['store_id'], 's1');
    expect(call['callee_id'], 'buyer-7');
    expect(call.containsKey('listing_id'), isFalse);
  });
}

/// pumpAndSettle never returns because the constellation and typing dots
/// animate indefinitely.
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
