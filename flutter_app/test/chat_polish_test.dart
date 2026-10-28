// Chat polish reported from a phone (2026-10-27):
//  * the Direct/Zeno switch ate a full-width row (and the Zeno orb
//    clipped its label) - now a compact centred pill;
//  * tapping a call icon waited on POST /calls/initiate before the call
//    screen appeared (3-5s of "is it working?") - the screen now opens
//    at once and the setup finishes inside it;
//  * sent / delivered / seen were one grey tick vs two, and no bubble
//    showed when it was sent - every own message now carries its time
//    and a receipt word.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:broka/main.dart' show BrokaColors;
import 'package:broka/models/listing.dart';
import 'package:broka/screens/negotiate_screen.dart';
import 'package:broka/screens/negotiation_screen.dart';
import 'package:broka/screens/voip_call_screen.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/widgets/chat_parts.dart';
import 'package:broka/widgets/message_receipt.dart';

import 'support/fake_api.dart';

void main() {
  setUpAll(() {
    installFakeApi();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final name in [
      'xyz.luan/audioplayers',
      'xyz.luan/audioplayers.global',
      'com.llfbandit.record/messages',
      'com.broka.app/call_service',
      'FlutterWebRTC.Event',
      'xyz.luan/audioplayers/events/broka_ringtone',
      'com.broka.app/ringtone',
    ]) {
      messenger.setMockMethodCallHandler(MethodChannel(name), (_) async => null);
    }
    messenger.setMockMethodCallHandler(
        const MethodChannel('FlutterWebRTC.Method'), (_) async => null);
    messenger.setMockMethodCallHandler(
        const MethodChannel('flutter.baseflow.com/permissions/methods'),
        (call) async {
      if (call.method == 'requestPermissions') {
        return {for (final p in (call.arguments as List).cast<int>()) p: 0};
      }
      return 0;
    });
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ApiService.currentUserId = 'buyer-1';
    ApiService.currentUserName = 'Amina Wanjiru';
    clearFakeRequests();
  });

  group('compact mode switch', () {
    testWidgets('hugs its labels instead of spanning the screen', (tester) async {
      var switched = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ChatModeSwitch(zenoActive: false, onSwitch: () => switched++),
        ),
      ));
      await tester.pump();

      final size = tester.getSize(find.byKey(const Key('chat-mode-switch')));
      expect(size.height, 34);
      expect(size.width, lessThan(300),
          reason: 'centred pill, not a full-width row');
      // Both rooms stay labelled - never icon-only.
      expect(find.text('Direct'), findsOneWidget);
      expect(find.text('Zeno'), findsOneWidget);

      await tester.tap(find.byKey(const Key('chat-mode-zeno')));
      expect(switched, 1);
    });

    testWidgets('badges the other room with its unread count', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: ChatModeSwitch(zenoActive: false, onSwitch: _noop, unread: 3),
        ),
      ));
      await tester.pump();
      expect(find.text('3'), findsOneWidget);
    });
  });

  group('message times', () {
    test('today is just the clock time', () {
      final now = DateTime(2026, 10, 27, 12, 0);
      expect(formatMessageTime(DateTime(2026, 10, 27, 9, 5), now: now), '09:05');
    });

    test('yesterday and older name the day', () {
      final now = DateTime(2026, 10, 27, 12, 0);
      expect(formatMessageTime(DateTime(2026, 10, 26, 9, 5), now: now),
          'Yesterday 09:05');
      expect(formatMessageTime(DateTime(2026, 10, 3, 9, 5), now: now),
          '3 Oct 09:05');
      expect(formatMessageTime(DateTime(2025, 12, 3, 9, 5), now: now),
          '3 Dec 2025 09:05');
      expect(formatMessageTime(null, now: now), '');
    });
  });

  group('receipts say what they mean', () {
    for (final (receipt, word) in [
      (MessageReceipt.sending, 'Sending'),
      (MessageReceipt.sent, 'Sent'),
      (MessageReceipt.delivered, 'Delivered'),
      (MessageReceipt.read, 'Seen'),
      (MessageReceipt.failed, 'Not sent'),
      (MessageReceipt.relayed, 'relayed'),
    ]) {
      testWidgets('$receipt shows "$word"', (tester) async {
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: MessageReceiptIcon(receipt: receipt)),
        ));
        expect(find.text(word), findsOneWidget);
      });
    }

    // The tick grammar itself: one tick = sent, dull double = received
    // but unread, purple double = received and read. The words beside
    // the ticks don't prove the glyphs say the same thing.
    testWidgets('one dull tick sent, dull double delivered, purple double read',
        (tester) async {
      Future<List<Icon>> ticksFor(MessageReceipt receipt) async {
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(body: MessageReceiptIcon(receipt: receipt)),
        ));
        return tester.widgetList<Icon>(find.byIcon(Icons.check_rounded)).toList();
      }

      final sent = await ticksFor(MessageReceipt.sent);
      expect(sent, hasLength(1), reason: 'sent is a single tick');
      expect(sent.single.color, BrokaColors.textMid, reason: 'the single tick is dull');

      final delivered = await ticksFor(MessageReceipt.delivered);
      expect(delivered, hasLength(2), reason: 'received is a double tick');
      expect(delivered.map((i) => i.color).toSet(), {BrokaColors.textMid},
          reason: 'received but unread stays dull');

      final read = await ticksFor(MessageReceipt.read);
      expect(read, hasLength(2), reason: 'read is a double tick');
      expect(read.map((i) => i.color).toSet(), {BrokaColors.neonPurple},
          reason: 'read is the purple double tick');
    });

    test('receiptFor still climbs the ladder', () {
      final sent = DateTime(2026, 10, 27, 10, 0);
      expect(receiptFor(sentAt: sent, counterpartDeliveredAt: null, counterpartReadAt: null),
          MessageReceipt.sent);
      expect(
          receiptFor(
              sentAt: sent,
              counterpartDeliveredAt: sent.add(const Duration(minutes: 1)),
              counterpartReadAt: null),
          MessageReceipt.delivered);
      expect(
          receiptFor(
              sentAt: sent,
              counterpartDeliveredAt: sent.add(const Duration(minutes: 1)),
              counterpartReadAt: sent.add(const Duration(minutes: 2))),
          MessageReceipt.read);
      expect(
          receiptFor(sentAt: sent, counterpartDeliveredAt: null, counterpartReadAt: null, failed: true),
          MessageReceipt.failed);
    });
  });

  group('instant call screen', () {
    testWidgets('the call screen is up while the server is still answering',
        (tester) async {
      final setup = Completer<Map<String, dynamic>?>();
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(navigatorKey: nav, home: const SizedBox()));
      nav.currentState!.push(MaterialPageRoute<void>(
        settings: RouteSettings(name: '/voip-call', arguments: {
          'roomId': '',
          'userId': 'buyer-1',
          'callToken': '',
          'callSetup': setup.future,
          'peerName': 'Xavier Bravin',
          'isCaller': true,
          'listingId': 'listing-1',
          'buyerId': 'buyer-1',
          'callerRole': 'buyer',
          'callType': 'audio',
        }),
        builder: (_) => const VoipCallScreen(animateBackground: false),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Before the server answers: the person, "Calling…", one End control.
      expect(find.text('Xavier Bravin'), findsOneWidget);
      expect(find.text('Calling…'), findsOneWidget);
      expect(find.text('End'), findsOneWidget);
      expect(find.text('Mute'), findsNothing);

      // The server could not place it: the screen says so, with a way out.
      setup.complete(null);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.textContaining('Could not start the call'), findsOneWidget);
      expect(find.text('Close'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets('tapping call in the direct chat opens the call screen at once',
        (tester) async {
      setFakeRoute((uri) {
        final p = uri.path;
        if (p == '/negotiate/listing-1/history') return <Object>[];
        if (p == '/calls/initiate') {
          return const FakeResponse(
            {'status': 'sent', 'room_id': 'room-1', 'call_token': 't'},
            delay: Duration(seconds: 5),
          );
        }
        if (p.endsWith('/read-status')) return <String, dynamic>{};
        return null;
      });
      final listing = Listing.fromJson({
        ...fakeListingJson(1),
        'listing_type': 'fixed',
        'status': 'active',
      });
      await tester.pumpWidget(MaterialApp(
        onGenerateRoute: (settings) => MaterialPageRoute(
          settings: settings.name == '/'
              ? RouteSettings(name: '/', arguments: {'listing': listing, 'role': 'buyer'})
              : settings,
          builder: (_) => switch (settings.name) {
            '/voip-call' => const Scaffold(body: Text('calling')),
            _ => const NegotiationScreen(animateBackground: false),
          },
        ),
      ));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      await tester.tap(find.byTooltip('Voice call'));
      await tester.pump();
      await tester.tap(find.text('Call Now'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // The initiate request is still 5s out, but the call screen is up.
      expect(fakeRequests.where((r) => r.uri.path == '/calls/initiate'), hasLength(1));
      expect(find.text('calling'), findsOneWidget);

      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('video call icon also opens the call screen at once', (tester) async {
      setFakeRoute((uri) {
        final p = uri.path;
        if (p == '/negotiate/listing-1/history') return <Object>[];
        if (p == '/calls/initiate') {
          return const FakeResponse(
            {'status': 'sent', 'room_id': 'room-2', 'call_token': 't'},
            delay: Duration(seconds: 5),
          );
        }
        if (p.endsWith('/read-status')) return <String, dynamic>{};
        return null;
      });
      final listing = Listing.fromJson({
        ...fakeListingJson(1),
        'listing_type': 'fixed',
        'status': 'active',
      });
      await tester.pumpWidget(MaterialApp(
        onGenerateRoute: (settings) => MaterialPageRoute(
          settings: settings.name == '/'
              ? RouteSettings(name: '/', arguments: {'listing': listing, 'role': 'buyer'})
              : settings,
          builder: (_) => switch (settings.name) {
            '/voip-call' => const Scaffold(body: Text('calling')),
            _ => const NegotiationScreen(animateBackground: false),
          },
        ),
      ));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.tap(find.byTooltip('Video call'));
      await tester.pump();
      await tester.tap(find.text('Call Now'));
      // Two frames only: the call screen must be painted long before the
      // 5-second server answer - that is the whole fix.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 32));
      expect(find.text('calling'), findsOneWidget);
      final sent = fakeRequests.singleWhere((r) => r.uri.path == '/calls/initiate');
      expect((sent.json as Map)['call_type'], 'video');
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('ending while the setup is pending cancels it', (tester) async {
      final setup = Completer<Map<String, dynamic>?>();
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(navigatorKey: nav, home: const SizedBox()));
      nav.currentState!.push(MaterialPageRoute<void>(
        settings: RouteSettings(name: '/voip-call', arguments: {
          'roomId': '',
          'userId': 'buyer-1',
          'callToken': '',
          'callSetup': setup.future,
          'peerName': 'Xavier Bravin',
          'isCaller': true,
          'listingId': 'listing-1',
          'buyerId': 'buyer-1',
          'callerRole': 'buyer',
          'callType': 'audio',
        }),
        builder: (_) => const VoipCallScreen(animateBackground: false),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Calling…'), findsOneWidget);

      await tester.tap(find.text('End'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Xavier Bravin'), findsNothing, reason: 'left the call screen');

      // A room created after the user left is recorded as cancelled.
      setup.complete({'room_id': 'room-9', 'call_token': 't'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      final logged = fakeRequests.where((r) => r.uri.path == '/calls/log-result');
      expect(logged, hasLength(1));
      expect((logged.single.json as Map)['outcome'], 'cancelled');
    });

    testWidgets('the pill toggles between the real chat and Zeno rooms', (tester) async {
      setFakeRoute((uri) {
        final p = uri.path;
        if (p == '/negotiate/listing-1/history') {
          return [
            {'role': 'seller', 'content': 'Is it still available?', 'id': 'm3'},
            {'role': 'broker', 'content': 'Welcome back.', 'id': 'm1'},
          ];
        }
        if (p.startsWith('/negotiate/deal-status')) return {'has_deal': false};
        if (p == '/negotiate/listing-1/read-status') return <String, dynamic>{};
        if (p == '/auth/user/seller-1') {
          return {'id': 'seller-1', 'name': 'Xavier Bravin', 'is_online': true};
        }
        return null;
      });
      final listing = Listing.fromJson({
        ...fakeListingJson(1),
        'listing_type': 'fixed',
        'status': 'active',
      });
      await tester.pumpWidget(MaterialApp(
        onGenerateRoute: (settings) => MaterialPageRoute(
          settings: settings.name == '/'
              ? RouteSettings(name: '/', arguments: {'listing': listing, 'role': 'buyer'})
              : settings,
          builder: (_) => switch (settings.name) {
            '/negotiate' => const NegotiateScreen(animateBackground: false),
            _ => const NegotiationScreen(animateBackground: false),
          },
        ),
      ));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(NegotiationScreen), findsOneWidget);

      // Direct -> Zeno through the pill itself.
      await tester.tap(find.byKey(const Key('chat-mode-zeno')));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(NegotiateScreen), findsOneWidget);
      expect(find.text('NEGOTIATION'), findsOneWidget);

      // Zeno -> Direct through the pill itself.
      await tester.tap(find.byKey(const Key('chat-mode-direct')));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.byType(NegotiationScreen), findsOneWidget);
      expect(find.text('Is it still available?'), findsOneWidget);
    });

    testWidgets('own messages show Seen, Delivered, Sent with their times', (tester) async {
      String iso(DateTime t) => t.toUtc().toIso8601String();
      String clock(DateTime t) =>
          '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
      final now = DateTime.now();
      final seenAt = now.subtract(const Duration(minutes: 30));
      final deliveredAt = now.subtract(const Duration(minutes: 20));
      final sentAt = now.subtract(const Duration(minutes: 10));
      setFakeRoute((uri) {
        final p = uri.path;
        if (p == '/negotiate/listing-1/history') {
          return [
            {'role': 'buyer', 'content': 'First one', 'id': 'a', 'created_at': iso(seenAt)},
            {'role': 'buyer', 'content': 'Second one', 'id': 'b', 'created_at': iso(deliveredAt)},
            {'role': 'buyer', 'content': 'Third one', 'id': 'c', 'created_at': iso(sentAt)},
          ];
        }
        if (p.endsWith('/read-status')) {
          return {
            'seller_last_delivered': iso(now.subtract(const Duration(minutes: 15))),
            'seller_last_read': iso(now.subtract(const Duration(minutes: 25))),
          };
        }
        return null;
      });
      final listing = Listing.fromJson({
        ...fakeListingJson(1),
        'listing_type': 'fixed',
        'status': 'active',
      });
      await tester.pumpWidget(MaterialApp(
        onGenerateRoute: (_) => MaterialPageRoute(
          settings: RouteSettings(arguments: {'listing': listing, 'role': 'buyer'}),
          builder: (_) => const NegotiationScreen(animateBackground: false),
        ),
      ));
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      // One word per state, each beside its own message's time.
      expect(find.text('Seen'), findsOneWidget);
      expect(find.text('Delivered'), findsOneWidget);
      expect(find.text('Sent'), findsOneWidget);
      expect(find.text(clock(seenAt.toLocal())), findsOneWidget);
      expect(find.text(clock(deliveredAt.toLocal())), findsOneWidget);
      expect(find.text(clock(sentAt.toLocal())), findsOneWidget);
      expect(find.byKey(const Key('message-time')), findsNWidgets(3));
    });
  });
}

void _noop() {}
