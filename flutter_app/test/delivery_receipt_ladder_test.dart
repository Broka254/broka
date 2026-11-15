// Sent, then Delivered, then Seen - on the sender's own screen (2026-11-15).
//
// Reported: a message sent to someone offline went from Sent straight to
// Seen, never showing Delivered, though the server logged MESSAGE_DELIVERED
// when their phone synced. The receipt reached the server; this screen
// missed it:
//
//  * A receipt frame goes out once, as the other phone acknowledges. One
//    sent while this chat's socket was down never arrived, and nothing
//    asked for it when the socket came back - the bubble sat on Sent until
//    the 30-second refresh, by when the message had often been read too.
//    The screen now asks for the ticks whenever its socket comes back (and
//    the server sends them to every socket as it connects).
//  * The open chat marked the thread read "up to now" every 30 seconds -
//    a message that had reached the server and not this phone included. It
//    now reads up to the newest of the other side's messages it shows.
//  * The ladder itself, in order, a stale answer never taking a step back,
//    for a listing chat and for a store chat's photo.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:broka/models/listing.dart';
import 'package:broka/screens/negotiation_screen.dart';
import 'package:broka/services/api_service.dart';
import 'package:broka/widgets/message_receipt.dart';

import 'support/fake_api.dart';
import 'support/fake_voice.dart' show FakeSocket;

String _iso(DateTime t) => t.toUtc().toIso8601String();

Uint8List _png() {
  final image = img.Image(width: 120, height: 90);
  img.fill(image, color: img.ColorRgb8(40, 120, 200));
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  final sockets = <FakeSocket>[];
  late WebSocketChannel Function(Uri) realConnect;

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
    // The media vault and outbox live under the app documents directory.
    messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/path_provider'),
        (_) async => Directory.systemTemp.path);
    realConnect = NegotiationScreen.connectSocket;
  });

  tearDownAll(() => NegotiationScreen.connectSocket = realConnect);

  setUp(() async {
    // Signed in: the chat opens its socket only with a session.
    SharedPreferences.setMockInitialValues(
        {'auth_token': 'test-token', 'user_id': 'buyer-1'});
    await ApiService.loadSavedSession();
    ApiService.currentUserName = 'Amina Wanjiru';
    clearFakeRequests();
    sockets.clear();
    NegotiationScreen.connectSocket = (uri) {
      final socket = FakeSocket();
      sockets.add(socket);
      return socket;
    };
  });

  tearDown(() async {
    SharedPreferences.setMockInitialValues({});
    await ApiService.loadSavedSession();
  });

  Widget chat(Map<String, dynamic> arguments) => MaterialApp(
        onGenerateRoute: (_) => MaterialPageRoute(
          settings: RouteSettings(arguments: arguments),
          builder: (_) => const NegotiationScreen(animateBackground: false),
        ),
      );

  Widget listingChat() => chat({
        'listing': Listing.fromJson({
          ...fakeListingJson(1),
          'listing_type': 'fixed',
          'status': 'active',
        }),
        'role': 'buyer',
      });

  List<MessageReceipt> receipts(WidgetTester tester) => tester
      .widgetList<MessageReceiptIcon>(find.byType(MessageReceiptIcon))
      .map((w) => w.receipt)
      .toList();

  List<FakeRequest> reads() => fakeRequests
      .where((r) => r.method == 'POST' && r.uri.path.endsWith('/mark-read'))
      .toList();

  testWidgets('a message to a phone that was offline goes Sent, Delivered, Seen',
      (tester) async {
    final sentAt = DateTime.now().subtract(const Duration(minutes: 2));
    setFakeRoute((uri) {
      final p = uri.path;
      if (p == '/negotiate/listing-1/history') {
        return [
          {'role': 'buyer', 'content': 'Bado iko?', 'id': 'm1', 'created_at': _iso(sentAt)},
        ];
      }
      // Their phone is off: no receipt of any kind yet.
      if (p.endsWith('/read-status')) return <String, dynamic>{};
      return null;
    });
    await tester.pumpWidget(listingChat());
    await _settle(tester);
    expect(sockets, hasLength(1), reason: 'the chat is on its socket');
    expect(receipts(tester), [MessageReceipt.sent]);

    // Their phone is back and its sync acknowledged the message: the
    // server's delivered receipt, with no read time.
    sockets.last.emit({
      'type': 'receipt', 'role': 'seller', 'last_delivered': _iso(sentAt),
      'last_read': null, 'message_ids': ['m1'], 'up_to_message_id': 'm1',
    });
    await _settle(tester);
    expect(receipts(tester), [MessageReceipt.delivered]);
    expect(find.text('Delivered'), findsOneWidget);

    // An answer overtaken by a newer one - older ticks - takes nothing back.
    sockets.last.emit({
      'type': 'receipt', 'role': 'seller',
      'last_delivered': _iso(sentAt.subtract(const Duration(hours: 1))), 'last_read': null,
    });
    await _settle(tester);
    expect(receipts(tester), [MessageReceipt.delivered]);

    // They open the chat later.
    final readAt = sentAt.add(const Duration(minutes: 1));
    sockets.last.emit({
      'type': 'receipt', 'role': 'seller', 'last_delivered': _iso(readAt),
      'last_read': _iso(readAt), 'up_to_message_id': 'm1',
    });
    await _settle(tester);
    expect(receipts(tester), [MessageReceipt.read]);
    expect(find.text('Seen'), findsOneWidget);
  });

  testWidgets('a socket that comes back asks for the ticks it missed while it was down',
      (tester) async {
    final sentAt = DateTime.now().subtract(const Duration(minutes: 2));
    var theirPhoneHasIt = false;
    setFakeRoute((uri) {
      final p = uri.path;
      if (p == '/negotiate/listing-1/history') {
        return [
          {'role': 'buyer', 'content': 'Bado iko?', 'id': 'm1', 'created_at': _iso(sentAt)},
        ];
      }
      if (p.endsWith('/read-status')) {
        return theirPhoneHasIt
            ? {'seller_last_delivered': _iso(sentAt)}
            : <String, dynamic>{};
      }
      return null;
    });
    await tester.pumpWidget(listingChat());
    await _settle(tester);
    expect(receipts(tester), [MessageReceipt.sent]);

    // The socket drops. While it is down their phone acknowledges the
    // message - and the receipt for it reaches nobody.
    theirPhoneHasIt = true;
    sockets.last.closeWith(code: 1006);
    await _settle(tester);
    clearFakeRequests();

    // It comes back within seconds (2s, give or take a fifth).
    await tester.pump(const Duration(seconds: 3));
    await _settle(tester);
    expect(sockets, hasLength(2), reason: 'reconnected');
    expect(fakeRequests.where((r) => r.uri.path.endsWith('/read-status')), isNotEmpty,
        reason: 'what it missed is asked for as it comes back - not at the next '
            '30-second refresh, by when the message may be read as well');
    expect(receipts(tester), [MessageReceipt.delivered]);
  });

  testWidgets('the open chat reads up to the newest message of theirs it shows, '
      'not up to now', (tester) async {
    final at = DateTime.now().subtract(const Duration(minutes: 3));
    setFakeRoute((uri) {
      final p = uri.path;
      if (p == '/negotiate/listing-1/history') {
        return [
          {'role': 'seller', 'content': 'Iko', 'id': 's1', 'created_at': _iso(at)},
          {'role': 'seller', 'content': 'Bei ni 23k', 'id': 's2',
           'created_at': _iso(at.add(const Duration(seconds: 20)))},
          {'role': 'buyer', 'content': 'Sawa', 'id': 'b1',
           'created_at': _iso(at.add(const Duration(seconds: 40)))},
        ];
      }
      if (p.endsWith('/read-status')) return <String, dynamic>{};
      return null;
    });
    await tester.pumpWidget(listingChat());
    await _settle(tester);
    expect(reads(), isNotEmpty, reason: 'on screen: read');
    expect((reads().last.json as Map)['up_to_message_id'], 's2',
        reason: 'their newest on screen - my own reply after it is no part of it');

    // Their next message arrives on the socket and is on screen: read up to it.
    clearFakeRequests();
    sockets.last.emit({
      'type': 'message', 'id': 's3', 'role': 'seller', 'content': 'Uko?',
      'msg_type': 'text', 'created_at': _iso(DateTime.now()),
    });
    await _settle(tester);
    expect(reads(), isNotEmpty);
    expect((reads().last.json as Map)['up_to_message_id'], 's3');
  });

  testWidgets('with nothing of theirs on screen, nothing is marked read', (tester) async {
    final at = DateTime.now().subtract(const Duration(minutes: 3));
    setFakeRoute((uri) {
      final p = uri.path;
      if (p == '/negotiate/listing-1/history') {
        return [
          {'role': 'buyer', 'content': 'Habari', 'id': 'b1', 'created_at': _iso(at)},
        ];
      }
      if (p.endsWith('/read-status')) return <String, dynamic>{};
      return null;
    });
    await tester.pumpWidget(listingChat());
    await _settle(tester);
    // Thirty seconds on: the refresh that used to read "up to now".
    await tester.pump(const Duration(seconds: 31));
    await _settle(tester);
    expect(reads(), isEmpty,
        reason: '"read up to now" read whatever reached the server meanwhile');
  });

  testWidgets("a store chat's photo climbs the same ladder", (tester) async {
    final at = DateTime.now().subtract(const Duration(minutes: 2));
    setFakeRoute((uri) {
      final p = uri.path;
      if (p == '/negotiate/store/s1/history') {
        return [
          {
            'id': 'p1',
            'role': 'buyer',
            'content': '',
            'msg_type': 'image',
            'media_url': 'data:image/png;base64,${base64Encode(_png())}',
            'created_at': _iso(at),
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
      return null;
    });
    await tester.pumpWidget(chat(const {
      'storeId': 's1',
      'storeName': 'Clanix Electronics',
      'seller_id': 'owner-1',
      'role': 'buyer',
    }));
    await _settle(tester);
    expect(sockets.single, isNotNull);
    expect(receipts(tester), [MessageReceipt.sent]);

    sockets.last.emit({
      'type': 'receipt', 'role': 'seller', 'last_delivered': _iso(at),
      'last_read': null, 'message_ids': ['p1'], 'up_to_message_id': 'p1',
    });
    await _settle(tester);
    expect(receipts(tester), [MessageReceipt.delivered]);

    final readAt = at.add(const Duration(minutes: 1));
    sockets.last.emit({
      'type': 'receipt', 'role': 'seller', 'last_delivered': _iso(readAt),
      'last_read': _iso(readAt),
    });
    await _settle(tester);
    expect(receipts(tester), [MessageReceipt.read]);
  });
}

/// pumpAndSettle never returns (the constellation and typing dots animate).
Future<void> _settle(WidgetTester tester) async {
  for (int i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
